<#
.SYNOPSIS
    Seeds the generated NetBox secrets into Key Vault. Existing secrets are never overwritten.
.DESCRIPTION
    Runs in the pipeline after foundation.bicep, which gives the pipeline identity Key Vault Secrets
    Officer on the vault. New vaults and role assignments can take a few minutes to become usable, so
    the first access is retried.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $KeyVaultName
)

$ErrorActionPreference = 'Stop'

function New-RandomSecret {
    param([int] $Length, [string] $Alphabet = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789')
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes($Length)
    -join ($bytes | ForEach-Object { $Alphabet[$_ % $Alphabet.Length] })
}

# Alphanumeric only for values that end up in connection strings or shell commands
$secrets = [ordered]@{
    'postgres-admin-password'   = { New-RandomSecret -Length 32 }
    'redis-password'            = { New-RandomSecret -Length 32 }
    'netbox-superuser-password' = { New-RandomSecret -Length 32 }
    'netbox-api-token-pepper'   = { New-RandomSecret -Length 64 }
    'netbox-secret-key'         = { New-RandomSecret -Length 64 -Alphabet 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^&*(-_=+)' }
}

function Get-ExistingSecretNames {
    for ($attempt = 1; $attempt -le 20; $attempt++) {
        $names = az keyvault secret list --vault-name $KeyVaultName --query '[].name' -o tsv 2>$null
        if ($LASTEXITCODE -eq 0) { return @($names) }
        Write-Host "Waiting for Key Vault access to propagate (attempt $attempt/20)..."
        Start-Sleep -Seconds 30
    }
    throw "Could not list secrets in Key Vault '$KeyVaultName'."
}

$existing = Get-ExistingSecretNames

foreach ($name in $secrets.Keys) {
    if ($existing -contains $name) {
        Write-Host "Secret '$name' already exists, leaving it unchanged."
        continue
    }
    Write-Host "Creating secret '$name'."
    $value = & $secrets[$name]
    $file = New-TemporaryFile
    try {
        # Pass the value via a file so it never appears on a command line
        Set-Content -Path $file -Value $value -NoNewline
        az keyvault secret set --vault-name $KeyVaultName --name $name --file $file --encoding utf-8 --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed to set secret '$name'." }
    }
    finally {
        Remove-Item $file -Force
    }
}

if ($existing -notcontains 'entra-client-secret') {
    Write-Warning "Secret 'entra-client-secret' is missing. Run scripts/Set-NetboxLoginAccess.ps1 before NetBox can be deployed."
}
