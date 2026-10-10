<#
.SYNOPSIS
    One-time setup of what the pipeline identity may do. Run once, before the first pipeline run.
.DESCRIPTION
    Run as Owner (or User Access Administrator) of the subscription or resource group, for example
    after PIM elevation. Safe to re-run: existing assignments are updated, not duplicated.

    On the resource group (created if missing), the pipeline identity gets:
      - Contributor                                  to deploy resources
      - Role Based Access Control Administrator      with a condition: it may only assign or remove
                                                     AcrPull, Key Vault Secrets User and Key Vault
                                                     Secrets Officer, and only for service principals.
                                                     foundation.bicep uses this for id-netbox and for
                                                     the pipeline's own Key Vault access.

    -GrantGraphPermission also grants the Microsoft Graph application permission
    Application.ReadWrite.OwnedBy, so infra/entra.bicep can create and update the sign-in app (and only
    apps the pipeline owns). Granting it needs Privileged Role Administrator or Global Administrator.

    -IncludeCurrentUser gives you Key Vault Secrets Officer on the resource group, which
    scripts/Set-NetboxLoginAccess.ps1 needs to store the client secret.
.EXAMPLE
    ./scripts/Initialize-PipelineAccess.ps1 -SubscriptionId <subscription-id> -ResourceGroupName rg-netbox-prod `
        -Location swedencentral -PipelineClientId <service-connection-client-id> -GrantGraphPermission -IncludeCurrentUser
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $Location,
    [Parameter(Mandatory, HelpMessage = 'Client (application) ID of the service connection identity.')]
    [string] $PipelineClientId,
    [switch] $GrantGraphPermission,
    [switch] $IncludeCurrentUser
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

az account set --subscription $SubscriptionId

# Built-in role definition IDs (the same in every tenant). The three delegable roles must match foundation.bicep.
$contributor = 'b24988ac-6180-42a0-ab9b-4f2ad1ae7e3f'
$rbacAdministrator = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
$keyVaultSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
$delegableRoles = @(
    '7f951dda-4ed3-4680-a7ca-43fe172d538d'   # AcrPull
    '4633458b-17de-408a-b874-0445c86b69e6'   # Key Vault Secrets User
    $keyVaultSecretsOfficer
)

$pipelineObjectId = az ad sp show --id $PipelineClientId --query id -o tsv
Write-Host "Pipeline service principal: $pipelineObjectId"

$PSNativeCommandUseErrorActionPreference = $false
$scope = az group show --name $ResourceGroupName --query id -o tsv 2>$null
$PSNativeCommandUseErrorActionPreference = $true
if (-not $scope) {
    Write-Host "Creating resource group '$ResourceGroupName' in $Location."
    $scope = az group create --name $ResourceGroupName --location $Location --query id -o tsv
}

function Set-RoleAssignment {
    param(
        [string] $PrincipalId, [string] $PrincipalType, [string] $RoleId, [string] $Description,
        [string] $Condition
    )
    # Reuse an existing assignment of this role to this principal, so a re-run updates the condition
    $existing = @(az role assignment list --scope $scope --role $RoleId -o json | ConvertFrom-Json |
        Where-Object { $_.principalId -eq $PrincipalId -and $_.scope -eq $scope })
    $name = $existing ? $existing[0].name : [guid]::NewGuid().ToString()

    $properties = [ordered]@{
        roleDefinitionId = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/$RoleId"
        principalId      = $PrincipalId
        principalType    = $PrincipalType
        description      = $Description
    }
    if ($Condition) {
        $properties.condition = $Condition
        $properties.conditionVersion = '2.0'
    }
    # Through a file: the condition's quotes and braces don't survive the az.cmd wrapper on Windows
    $file = New-TemporaryFile
    try {
        Set-Content -Path $file -Value (@{ properties = $properties } | ConvertTo-Json -Depth 5) -NoNewline
        az rest --method put --url "$scope/providers/Microsoft.Authorization/roleAssignments/${name}?api-version=2022-04-01" `
            --body "@$file" --output none
    }
    finally {
        Remove-Item $file -Force
    }
    Write-Host "$($existing ? 'Updated' : 'Created'): $Description"
}

Set-RoleAssignment -PrincipalId $pipelineObjectId -PrincipalType ServicePrincipal -RoleId $contributor `
    -Description 'NetBox pipeline: deploy resources'

# Writes and deletes of role assignments are allowed only for the delegable roles and service principals
$roleList = $delegableRoles -join ', '
$condition = @"
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}
  AND
  @Request[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
 )
)
AND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
 )
 OR
 (
  @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}
  AND
  @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] ForAnyOfAnyValues:StringEqualsIgnoreCase {'ServicePrincipal'}
 )
)
"@
Set-RoleAssignment -PrincipalId $pipelineObjectId -PrincipalType ServicePrincipal -RoleId $rbacAdministrator `
    -Description 'NetBox pipeline: assign AcrPull and Key Vault secret roles to service principals only' -Condition $condition

if ($IncludeCurrentUser) {
    $me = az ad signed-in-user show --query id -o tsv
    Set-RoleAssignment -PrincipalId $me -PrincipalType User -RoleId $keyVaultSecretsOfficer `
        -Description 'NetBox: store the Entra client secret (Set-NetboxLoginAccess.ps1)'
}

if ($GrantGraphPermission) {
    $graph = az ad sp show --id 00000003-0000-0000-c000-000000000000 -o json | ConvertFrom-Json
    # Look the role up by name instead of hard-coding its ID
    $roleId = ($graph.appRoles | Where-Object value -eq 'Application.ReadWrite.OwnedBy').id
    $assigned = @(az rest --method get --url "https://graph.microsoft.com/v1.0/servicePrincipals/$pipelineObjectId/appRoleAssignments" `
            --query value -o json | ConvertFrom-Json | Where-Object { $_.resourceId -eq $graph.id -and $_.appRoleId -eq $roleId })
    if ($assigned.Count -gt 0) {
        Write-Host 'Graph permission Application.ReadWrite.OwnedBy already granted.'
    }
    else {
        $file = New-TemporaryFile
        try {
            Set-Content -Path $file -Value (@{ principalId = $pipelineObjectId; resourceId = $graph.id; appRoleId = $roleId } | ConvertTo-Json) -NoNewline
            az rest --method post --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($graph.id)/appRoleAssignedTo" `
                --headers 'Content-Type=application/json' --body "@$file" --output none
        }
        finally {
            Remove-Item $file -Force
        }
        Write-Host 'Granted Graph permission Application.ReadWrite.OwnedBy.'
    }
}
