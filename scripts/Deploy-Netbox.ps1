<#
.SYNOPSIS
    Deploys (or what-ifs) infra/main.bicep using the outputs of the foundation deployment.
.DESCRIPTION
    Custom domains get a managed certificate, which can only be issued after the host name is on
    the app. So a deployment that adds a host name adds it unbound and creates its certificate; this
    script then waits for the certificate to be issued and deploys a second time to bind it.

    The Entra client ID comes from the netbox-entra deployment (infra/entra.bicep). Until someone has
    stored the client secret with scripts/Set-NetboxLoginAccess.ps1, the script skips the deployment
    with a warning instead of failing, so the first pipeline run stays green.

    With redisMode 'managed', the Redis access key is only written to Key Vault when it differs from
    the stored one, so routine runs don't add secret versions.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $BaseImage,
    [Parameter(Mandatory)] [string] $RedisImage,
    [string] $InitialSuperuserUpn = '',
    [string] $FoundationDeploymentName = 'netbox-foundation',
    [string] $EntraDeploymentName = 'netbox-entra',
    [string] $ParameterFile = 'infra/environments/prod.bicepparam',
    [switch] $WhatIf
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# Same content-hash tag the Build stage built (or found) for this source
$ImageTag = & (Join-Path $PSScriptRoot 'Get-NetboxImageTag.ps1') -BaseImage $BaseImage
$deploymentSuffix = $env:BUILD_BUILDNUMBER ?? (Get-Date -Format 'yyyyMMdd-HHmmss')
Write-Host "Image tag: netbox:$ImageTag"

$outputs = az deployment group show -g $ResourceGroupName -n $FoundationDeploymentName --query properties.outputs -o json | ConvertFrom-Json

$EntraClientId = az deployment group show -g $ResourceGroupName -n $EntraDeploymentName --query properties.outputs.clientId.value -o tsv

$secretNames = @(az keyvault secret list --vault-name $outputs.keyVaultName.value --query '[].name' -o tsv)
if ($secretNames -notcontains 'entra-client-secret') {
    Write-Warning "Skipping: no 'entra-client-secret' in Key Vault yet. Run scripts/Set-NetboxLoginAccess.ps1 (see README), then run the pipeline again."
    if ($env:TF_BUILD) { Write-Host '##vso[task.complete result=SucceededWithIssues;]Waiting for the Entra client secret' }
    return
}

$subscriptionId = az account show --query id -o tsv

function Get-ManagedCertificateStates {
    # host name -> @{ Name; State } for every managed certificate in the environment
    $url = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/managedEnvironments/" +
        "$($outputs.containerAppsEnvironmentName.value)/managedCertificates?api-version=2024-03-01"
    $states = @{}
    foreach ($certificate in (az rest --method get --url $url --query value -o json | ConvertFrom-Json)) {
        $states[$certificate.properties.subjectName] = @{ Name = $certificate.name; State = $certificate.properties.provisioningState }
    }
    $states
}

function Get-CertificateArgument {
    # Issued certificates only, as a plain string: JSON doesn't survive the az.cmd wrapper on Windows
    $issued = (Get-ManagedCertificateStates).GetEnumerator() | Where-Object { $_.Value.State -eq 'Succeeded' }
    "existingCertificates=$(($issued | ForEach-Object { "$($_.Key)=$($_.Value.Name)" }) -join ';')"
}

function Wait-ManagedCertificates {
    param([string[]] $Domains, [int] $TimeoutMinutes = 20)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $states = Get-ManagedCertificateStates
        $failed = @($Domains | Where-Object { $states[$_].State -eq 'Failed' })
        if ($failed.Count -gt 0) {
            throw "Managed certificate failed for $($failed -join ', '). Check the CNAME and TXT records (see README), then run the pipeline again."
        }
        $pending = @($Domains | Where-Object { $states[$_].State -ne 'Succeeded' })
        if ($pending.Count -eq 0) { return }
        if ((Get-Date) -gt $deadline) {
            throw "Managed certificate not issued after $TimeoutMinutes minutes for $($pending -join ', '). Run the pipeline again once it is; it binds automatically."
        }
        Write-Host "Waiting for managed certificates: $(($pending | ForEach-Object { "$_ ($($states[$_].State ?? 'not created'))" }) -join ', ')"
        Start-Sleep -Seconds 30
    }
}

function Get-RedisKeyArgument {
    # Only rewrite the Key Vault copy of the managed Redis key when it is missing or differs.
    # The values stay in memory and are never printed.
    $redisId = az resource list -g $ResourceGroupName --resource-type Microsoft.Cache/redisEnterprise --query '[0].id' -o tsv
    if (-not $redisId) { return 'writeManagedRedisKey=true' }

    $PSNativeCommandUseErrorActionPreference = $false
    $stored = az keyvault secret show --vault-name $outputs.keyVaultName.value --name 'managed-redis-access-key' --query value -o tsv 2>$null
    $storedExists = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    if (-not $storedExists) { return 'writeManagedRedisKey=true' }

    $current = az rest --method post --url "$redisId/databases/default/listKeys?api-version=2025-07-01" --query primaryKey -o tsv
    $changed = $current -cne $stored
    if ($changed) { Write-Host 'Managed Redis access key differs from Key Vault; it will be updated.' }
    "writeManagedRedisKey=$($changed.ToString().ToLowerInvariant())"
}

$arguments = @(
    '--resource-group', $ResourceGroupName
    '--parameters', $ParameterFile
    '--parameters', "containerRegistryName=$($outputs.containerRegistryName.value)"
    '--parameters', "keyVaultName=$($outputs.keyVaultName.value)"
    '--parameters', "containerAppsEnvironmentName=$($outputs.containerAppsEnvironmentName.value)"
    '--parameters', "identityName=$($outputs.identityName.value)"
    '--parameters', "netboxImageTag=$ImageTag"
    '--parameters', "redisImage=$RedisImage"
    '--parameters', "entraClientId=$EntraClientId"
    '--parameters', "initialSuperuserUpn=$InitialSuperuserUpn"
    '--parameters', (Get-RedisKeyArgument)
)

if ($WhatIf) {
    az deployment group what-if @arguments --parameters (Get-CertificateArgument) --name "netbox-whatif-$deploymentSuffix"
    return
}

$result = az deployment group create @arguments --parameters (Get-CertificateArgument) --name "netbox-$deploymentSuffix" --query properties.outputs -o json | ConvertFrom-Json
$newDomains = @($result.newCertificateDomains.value)
if ($newDomains.Count -gt 0) {
    Wait-ManagedCertificates -Domains $newDomains
    Write-Host "Managed certificates issued for $($newDomains -join ', '); deploying again to bind them."
    $result = az deployment group create @arguments --parameters (Get-CertificateArgument) --name "netbox-$deploymentSuffix-bind" --query properties.outputs -o json | ConvertFrom-Json
}
$result | ConvertTo-Json -Depth 5
