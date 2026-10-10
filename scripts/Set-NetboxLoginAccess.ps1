<#
.SYNOPSIS
    Assigns Entra groups to the NetBox app roles and stores the sign-in app's client secret in Key Vault.
.DESCRIPTION
    The app registration itself (redirect URIs, app roles, assignment required) is managed by
    infra/entra.bicep in the pipeline. This script covers what deliberately stays out of the pipeline:

      - Group assignments. Doing them from the pipeline would need the Graph permission
        AppRoleAssignment.ReadWrite.All, which can grant any app role in the tenant.
      - The client secret. Graph Bicep cannot create application passwords.

    Run it interactively (az login) as someone who can manage enterprise apps (Cloud Application
    Administrator) and has Key Vault Secrets Officer (scripts/Initialize-PipelineAccess.ps1
    -IncludeCurrentUser), after the pipeline's Foundation stage.

    A group has one role; assigning a different one replaces the previous assignment:
      netbox-admins  -> NetBox superuser                                   (-AdminGroupObjectId)
      netbox-editors -> create/edit/delete on the NetBox apps in use       (-EditorGroupObjectId)
      netbox-readers -> read-only on the NetBox apps in use                (-ReaderGroupObjectId)
.EXAMPLE
    ./scripts/Set-NetboxLoginAccess.ps1 -ResourceGroupName rg-netbox-prod -AdminGroupObjectId <admin-group-id>
.EXAMPLE
    ./scripts/Set-NetboxLoginAccess.ps1 -ResourceGroupName rg-netbox-prod -EditorGroupObjectId <network-team-group-id>
.EXAMPLE
    ./scripts/Set-NetboxLoginAccess.ps1 -ResourceGroupName rg-netbox-prod -RotateSecret
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $FoundationDeploymentName = 'netbox-foundation',

    [string] $EntraDeploymentName = 'netbox-entra',

    [Parameter(HelpMessage = 'Object ID of an Entra group whose members become NetBox superusers.')]
    [string] $AdminGroupObjectId,

    [Parameter(HelpMessage = 'Object ID of an Entra group whose members can edit, but not administer, NetBox.')]
    [string] $EditorGroupObjectId,

    [Parameter(HelpMessage = 'Object ID of an Entra group whose members get read-only access.')]
    [string] $ReaderGroupObjectId,

    [switch] $RotateSecret
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$foundation = az deployment group show -g $ResourceGroupName -n $FoundationDeploymentName --query properties.outputs -o json | ConvertFrom-Json
$entra = az deployment group show -g $ResourceGroupName -n $EntraDeploymentName --query properties.outputs -o json | ConvertFrom-Json
$keyVaultName = $foundation.keyVaultName.value
$appId = $entra.clientId.value
$spId = $entra.servicePrincipalId.value
Write-Host "Sign-in app '$($entra.displayName.value)' ($appId)"

$appRoles = @(az ad sp show --id $spId --query appRoles -o json | ConvertFrom-Json)
$roleIds = @{}
foreach ($role in $appRoles) { $roleIds[$role.value] = $role.id }

function Set-GroupRole {
    param([string] $GroupObjectId, [string] $RoleValue)
    $url = "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo"
    $assignments = @(az rest --method get --url $url --query 'value' -o json | ConvertFrom-Json |
        Where-Object principalId -eq $GroupObjectId)
    $roleId = $roleIds[$RoleValue]
    if (-not $roleId) { throw "App role '$RoleValue' not found. Has the pipeline deployed infra/entra.bicep?" }

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
    if ($RotateSecret) { Write-Host 'Restart the container app revision to pick up the new secret.' }
    else { Write-Host 'Run the pipeline again to deploy NetBox.' }
}
else {
    Write-Host "Secret 'entra-client-secret' already in Key Vault, use -RotateSecret to replace it."
}
