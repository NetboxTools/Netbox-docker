<#
.SYNOPSIS
    Creates (or updates) the Entra app registration that NetBox users sign in with, its app roles,
    and stores its client secret in the NetBox Key Vault.
.DESCRIPTION
    Run this interactively (az login) as someone who can create app registrations and assign
    enterprise apps (Cloud Application Administrator), after the pipeline has deployed the
    foundation stage. The pipeline service connection cannot do this itself because it has no
    Microsoft Graph permissions.

    User assignment is required on the enterprise app, so only assigned groups can sign in.
    The app role a group is assigned becomes a NetBox group on every sign-in (one role per group):
      netbox-admins  -> NetBox superuser                        (-AdminGroupObjectId)
      netbox-editors -> create/edit/delete on the NetBox apps in use, no administration
                                                                (-EditorGroupObjectId)
      netbox-readers -> read-only on the NetBox apps in use     (-ReaderGroupObjectId)
    Safe to re-run; assigning a group a different role replaces its previous one.

    The sign-in callback of the default host name and of every -CustomDomain is registered as a
    redirect URI. Redirect URIs that are already registered are kept.
.EXAMPLE
    ./scripts/New-NetboxLoginApp.ps1 -ResourceGroupName rg-netbox-prod -AdminGroupObjectId <operations-group-id>
.EXAMPLE
    ./scripts/New-NetboxLoginApp.ps1 -ResourceGroupName rg-netbox-prod -EditorGroupObjectId <network-team-group-id>
.EXAMPLE
    ./scripts/New-NetboxLoginApp.ps1 -ResourceGroupName rg-netbox-prod -ReaderGroupObjectId <developers-group-id>
.EXAMPLE
    ./scripts/New-NetboxLoginApp.ps1 -ResourceGroupName rg-netbox-prod -CustomDomain netbox.contoso.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $DisplayName = 'app-netbox-prod-login',

    [string] $FoundationDeploymentName = 'netbox-foundation',

    [Parameter(HelpMessage = 'Object ID of an Entra group whose members become NetBox superusers.')]
    [Alias('AssignGroupObjectId')]
    [string] $AdminGroupObjectId,

    [Parameter(HelpMessage = 'Object ID of an Entra group whose members can edit, but not administer, NetBox.')]
    [string] $EditorGroupObjectId,

    [Parameter(HelpMessage = 'Object ID of an Entra group whose members get read-only access.')]
    [string] $ReaderGroupObjectId,

    [Parameter(HelpMessage = 'Custom host names of NetBox (customDomains in the bicepparam file).')]
    [string[]] $CustomDomain = @(),

    [switch] $RotateSecret
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$outputs = az deployment group show -g $ResourceGroupName -n $FoundationDeploymentName --query properties.outputs -o json | ConvertFrom-Json
$keyVaultName = $outputs.keyVaultName.value
$redirectUris = @($outputs.netboxFqdn.value) + $CustomDomain | ForEach-Object { "https://$_/.auth/login/aad/callback" }

$appId = az ad app list --display-name $DisplayName --query '[0].appId' -o tsv
if (-not $appId) {
    Write-Host "Creating app registration '$DisplayName'."
    $appId = az ad app create `
        --display-name $DisplayName `
        --sign-in-audience AzureADMyOrg `
        --web-redirect-uris @redirectUris `
        --enable-id-token-issuance true `
        --query appId -o tsv
}
else {
    # --web-redirect-uris replaces the list, so keep what is already registered
    $existingUris = @(az ad app show --id $appId --query 'web.redirectUris' -o json | ConvertFrom-Json)
    $redirectUris = @($existingUris) + @($redirectUris) | Sort-Object -Unique
    Write-Host "App registration '$DisplayName' exists ($appId), setting redirect URIs: $($redirectUris -join ', ')"
    az ad app update --id $appId --web-redirect-uris @redirectUris --enable-id-token-issuance true
}

# Microsoft Graph User.Read (delegated) for sign-in
az ad app permission add --id $appId --api 00000003-0000-0000-c000-000000000000 --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope

$spId = az ad sp list --filter "appId eq '$appId'" --query '[0].id' -o tsv
if (-not $spId) {
    $spId = az ad sp create --id $appId --query id -o tsv
}
az ad sp update --id $spId --set appRoleAssignmentRequired=true

# App roles; their values must match the NetBox groups used in infra/main.bicep.
# Existing role IDs are kept so current assignments stay valid.
$roleDefinitions = @(
    @{ value = 'netbox-admins'; displayName = 'NetBox Admin'; description = 'Full NetBox administration (superuser).' }
    @{ value = 'netbox-editors'; displayName = 'NetBox Editor'; description = 'Create, edit and delete NetBox data, without administration.' }
    @{ value = 'netbox-readers'; displayName = 'NetBox Reader'; description = 'Read-only access to NetBox.' }
)
$existingRoles = @(az ad app show --id $appId --query appRoles -o json | ConvertFrom-Json)
$appRoles = foreach ($definition in $roleDefinitions) {
    $existing = $existingRoles | Where-Object value -eq $definition.value
    [ordered]@{
        allowedMemberTypes = @('User')
        description        = $definition.description
        displayName        = $definition.displayName
        id                 = $existing ? $existing.id : [guid]::NewGuid().ToString()
        isEnabled          = $true
        value              = $definition.value
    }
}
# Keep any roles not managed here
$appRoles = @($appRoles) + @($existingRoles | Where-Object { $_.value -notin $roleDefinitions.value })
$rolesFile = New-TemporaryFile
try {
    Set-Content -Path $rolesFile -Value (ConvertTo-Json -InputObject $appRoles -Depth 5) -NoNewline
    az ad app update --id $appId --app-roles "@$rolesFile"
}
finally {
    Remove-Item $rolesFile -Force
}
$roleIds = @{}
foreach ($role in $appRoles) { $roleIds[$role.value] = $role.id }

function Set-GroupRole {
    param([string] $GroupObjectId, [string] $RoleValue)
    $url = "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo"
    $assignments = @(az rest --method get --url $url --query 'value' -o json | ConvertFrom-Json |
        Where-Object principalId -eq $GroupObjectId)
    $roleId = $roleIds[$RoleValue]

    if ($assignments.appRoleId -notcontains $roleId) {
        Write-Host "Assigning role '$RoleValue' to group $GroupObjectId."
        $body = @{ principalId = $GroupObjectId; resourceId = $spId; appRoleId = $roleId } | ConvertTo-Json -Compress
        $bodyFile = New-TemporaryFile
        try {
            Set-Content -Path $bodyFile -Value $body -NoNewline
            az rest --method post --url $url --headers 'Content-Type=application/json' --body "@$bodyFile" --output none
        }
        finally {
            Remove-Item $bodyFile -Force
        }
    }
    else {
        Write-Host "Group $GroupObjectId already has role '$RoleValue'."
    }

    # One role per group: drop a role-less "Default Access" assignment and any other NetBox role
    foreach ($other in $assignments | Where-Object appRoleId -ne $roleId) {
        $otherRole = ($appRoles | Where-Object id -eq $other.appRoleId).value ?? 'Default Access'
        Write-Host "Removing previous assignment '$otherRole' for group $GroupObjectId."
        az rest --method delete --url "$url/$($other.id)" --output none
    }
}

if ($AdminGroupObjectId) { Set-GroupRole -GroupObjectId $AdminGroupObjectId -RoleValue 'netbox-admins' }
if ($EditorGroupObjectId) { Set-GroupRole -GroupObjectId $EditorGroupObjectId -RoleValue 'netbox-editors' }
if ($ReaderGroupObjectId) { Set-GroupRole -GroupObjectId $ReaderGroupObjectId -RoleValue 'netbox-readers' }

$secretNames = @(az keyvault secret list --vault-name $keyVaultName --query '[].name' -o tsv)
if ($secretNames -notcontains 'entra-client-secret' -or $RotateSecret) {
    Write-Host "Creating client secret and storing it in Key Vault '$keyVaultName'."
    $secret = az ad app credential reset --id $appId --display-name 'netbox-easyauth' --years 1 --append --query password -o tsv
    $file = New-TemporaryFile
    try {
        Set-Content -Path $file -Value $secret -NoNewline
        az keyvault secret set --vault-name $keyVaultName --name 'entra-client-secret' --file $file --encoding utf-8 --output none
    }
    finally {
        Remove-Item $file -Force
    }
}
else {
    Write-Host "Secret 'entra-client-secret' already in Key Vault, use -RotateSecret to replace it."
}

Write-Host ''
Write-Host "Set EntraClientId in pipelines/variables/prod.yml to: $appId"
Write-Host "NetBox URL: https://$(@($CustomDomain)[0] ?? $outputs.netboxFqdn.value)"
