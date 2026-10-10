<#
.SYNOPSIS
    Returns the netbox image tag for the current source: <base tag>-<content hash>.
.DESCRIPTION
    The image only depends on the Dockerfile, the files in app/ and the base image, so the tag is a
    hash of exactly those. The same source always gives the same tag, which lets the pipeline skip
    building an image that already exists and leaves the container app unchanged when nothing
    changed. Line endings are normalised so Windows and Linux checkouts hash the same.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaseImage,
    [string] $RepositoryRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'

$files = @(Get-Item (Join-Path $RepositoryRoot 'Dockerfile')) +
    @(Get-ChildItem (Join-Path $RepositoryRoot 'app') -File -Recurse | Where-Object FullName -notmatch '__pycache__') |
    Sort-Object { [System.IO.Path]::GetRelativePath($RepositoryRoot, $_.FullName).Replace('\', '/') }

$builder = [System.Text.StringBuilder]::new()
[void] $builder.Append("base=$BaseImage`n")
foreach ($file in $files) {
    $relative = [System.IO.Path]::GetRelativePath($RepositoryRoot, $file.FullName).Replace('\', '/')
    $content = [System.IO.File]::ReadAllText($file.FullName).Replace("`r`n", "`n")
    [void] $builder.Append("file=$relative`n$content`n")
}

$bytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
$hash = [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).Substring(0, 12).ToLowerInvariant()

# Docker tags allow [A-Za-z0-9_.-]
$baseTag = ($BaseImage -split ':')[-1] -replace '[^A-Za-z0-9_.-]', '-'
"$baseTag-$hash"
