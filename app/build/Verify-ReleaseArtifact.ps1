[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ExecutablePath,
    [Parameter(Mandatory)][string]$ExpectedTag,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [switch]$ExpectedPrerelease
)

$ErrorActionPreference = 'Stop'
$helpers = Join-Path $PSScriptRoot 'BuildHelpers.ps1'
if (-not (Test-Path -LiteralPath $helpers -PathType Leaf)) {
    throw "Build helpers not found: $helpers"
}
. $helpers

$metadata = Get-DuneExecutableBuildMetadata -ExecutablePath $ExecutablePath
$null = Assert-DuneBuildMetadataMatches `
    -Metadata $metadata `
    -ExpectedTag $ExpectedTag `
    -ExpectedCommit $ExpectedCommit `
    -ExpectedPrerelease:$ExpectedPrerelease

Write-Host "Verified built DuneServer.exe identity: tag=$($metadata.tag), commit=$($metadata.commit), prerelease=$($metadata.prerelease)" -ForegroundColor Green
