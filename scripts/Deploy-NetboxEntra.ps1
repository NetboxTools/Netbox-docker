<#
.SYNOPSIS
    Deploys infra/entra.bicep: the Entra app registration NetBox users sign in with.
.DESCRIPTION
    Runs in the pipeline's Foundation stage, after foundation.bicep. The redirect URIs come from the
    foundation's default FQDN and the customDomains in the app's parameter file, so they always match
    what the container app serves.

    The pipeline identity needs the Graph permission Application.ReadWrite.OwnedBy
    (scripts/Initialize-PipelineAccess.ps1 -GrantGraphPermission).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [string] $FoundationDeploymentName = 'netbox-foundation',
    [string] $EntraDeploymentName = 'netbox-entra',
    [string] $ParameterFile = 'infra/environments/entra.prod.bicepparam',
    [string] $AppParameterFile = 'infra/environments/prod.bicepparam'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$outputs = az deployment group show -g $ResourceGroupName -n $FoundationDeploymentName --query properties.outputs -o json | ConvertFrom-Json

# Read customDomains from the app's parameter file instead of keeping a second copy
$built = az bicep build-params --file $AppParameterFile --stdout | ConvertFrom-Json
$customDomains = @(($built.parametersJson | ConvertFrom-Json).parameters.customDomains.value)
Write-Host "Redirect URIs for: $((@($outputs.netboxFqdn.value) + $customDomains) -join ', ')"

$result = az deployment group create `
    --resource-group $ResourceGroupName `
    --name $EntraDeploymentName `
    --parameters $ParameterFile `
    --parameters "netboxFqdn=$($outputs.netboxFqdn.value)" `
    --parameters "customDomains=$($customDomains -join ',')" `
    --query properties.outputs -o json | ConvertFrom-Json

Write-Host "App registration '$($result.displayName.value)', client ID $($result.clientId.value)"

$secretNames = @(az keyvault secret list --vault-name $outputs.keyVaultName.value --query '[].name' -o tsv)
if ($secretNames -notcontains 'entra-client-secret') {
    Write-Warning "No client secret yet. Run scripts/Set-NetboxLoginAccess.ps1 once (see README); NetBox is deployed after that."
}
