<#
.SYNOPSIS
    One-time role assignments that the pipeline identity is not allowed to make.
.DESCRIPTION
    The pipeline identity only has Contributor-style rights, so it cannot write role assignments.
    Run this once, after the pipeline's Foundation stage, as someone with Owner or Role Based Access
    Control Administrator on rg-netbox-prod (for example after PIM elevation):

      - id-netbox       -> AcrPull on the container registry
      - id-netbox       -> Key Vault Secrets User on the Key Vault
      - you (optional)  -> Key Vault Secrets Officer on the Key Vault, so you can run
                           scripts/New-NetboxLoginApp.ps1

    Safe to re-run: existing assignments are left alone.
.EXAMPLE
    ./scripts/Grant-NetboxAccess.ps1 -SubscriptionId <subscription-id> -ResourceGroupName rg-netbox-prod -IncludeCurrentUser
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [string] $FoundationDeploymentName = 'netbox-foundation',
    [switch] $IncludeCurrentUser
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

az account set --subscription $SubscriptionId

$outputs = az deployment group show -g $ResourceGroupName -n $FoundationDeploymentName --query properties.outputs -o json | ConvertFrom-Json
$registryId = $outputs.containerRegistryId.value
$keyVaultId = $outputs.keyVaultId.value
$identityPrincipalId = $outputs.identityPrincipalId.value

function Grant-Role {
    param([string] $PrincipalId, [string] $PrincipalType, [string] $Role, [string] $Scope)
    # Count in PowerShell: on Windows az is a .cmd file and cmd.exe chokes on JMESPath like length(@)
    $existing = @(az role assignment list --assignee $PrincipalId --role $Role --scope $Scope --include-inherited -o json | ConvertFrom-Json)
    if ($existing.Count -gt 0) {
        Write-Host "'$Role' already assigned on $(Split-Path $Scope -Leaf)."
        return
    }
    Write-Host "Assigning '$Role' on $(Split-Path $Scope -Leaf)."
    az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type $PrincipalType --role $Role --scope $Scope --output none
}

Grant-Role -PrincipalId $identityPrincipalId -PrincipalType ServicePrincipal -Role 'AcrPull' -Scope $registryId
Grant-Role -PrincipalId $identityPrincipalId -PrincipalType ServicePrincipal -Role 'Key Vault Secrets User' -Scope $keyVaultId

if ($IncludeCurrentUser) {
    $me = az ad signed-in-user show --query id -o tsv
    Grant-Role -PrincipalId $me -PrincipalType User -Role 'Key Vault Secrets Officer' -Scope $keyVaultId
}
