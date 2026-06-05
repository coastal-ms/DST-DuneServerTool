<#
.SYNOPSIS
    Builds the DstFriendHelper.exe as a self-contained single-file Windows
    executable, ready to hand to a friend.

.DESCRIPTION
    Wraps `dotnet publish` with the publish-time properties locked in. Output
    lands in helper/friend/dist/. Drop DstFriendHelper.exe plus a populated
    config.json into the same folder on the friend's PC.

.PARAMETER Configuration
    Build configuration. Default Release.

.PARAMETER Runtime
    Runtime identifier. Default win-x64.
#>

[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = $PSScriptRoot
$proj = Join-Path $here 'DstFriendHelper.csproj'
$dist = Join-Path $here 'dist'

if (-not (Test-Path -LiteralPath $proj)) {
    throw "DstFriendHelper.csproj not found at $proj"
}

# Clean previous dist so single-file size doesn't accumulate stale baggage.
if (Test-Path -LiteralPath $dist) {
    Remove-Item -Recurse -Force -LiteralPath $dist
}
New-Item -ItemType Directory -Path $dist | Out-Null

Write-Host "Building DstFriendHelper ($Configuration / $Runtime) ..."

& dotnet publish $proj `
    --configuration $Configuration `
    --runtime $Runtime `
    --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true `
    --output $dist

if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

# Drop a config.json next to the .exe if one isn't already shipped — friend
# only needs to edit bridgeHost.
$cfg = Join-Path $dist 'config.json'
if (-not (Test-Path -LiteralPath $cfg)) {
    Copy-Item -Path (Join-Path $here 'config.sample.json') -Destination $cfg
}

Write-Host ""
Write-Host "Build complete." -ForegroundColor Green
Write-Host "  Output:  $dist"
Get-ChildItem $dist | Select-Object Name, Length | Format-Table -AutoSize
Write-Host "Hand the friend:"
Write-Host "  $dist\DstFriendHelper.exe"
Write-Host "  $dist\config.json   (edit bridgeHost to the host's Tailscale hostname first)"
