param(
    [Parameter(Mandatory)][string]$RepoRoot,
    [Parameter(Mandatory)][string]$LocalAppData
)

$ErrorActionPreference = 'Stop'
$env:LOCALAPPDATA = $LocalAppData
. (Join-Path $RepoRoot 'app\server\lib\ApiContract.ps1')
. (Join-Path $RepoRoot 'app\server\lib\PlatformCache.ps1')
. (Join-Path $RepoRoot 'app\server\lib\PlatformRuntime.ps1')
. (Join-Path $RepoRoot 'app\server\lib\MapPlatform.ps1')
$result = Initialize-DunePlatformCache
if (-not $result.ok) { throw $result.message }
$snapshot = Get-DunePlatformSnapshot
if (-not $snapshot.available) { throw 'Windows PowerShell 5.1 did not hydrate the fixture.' }
if ([string]$snapshot.snapshot['generation'] -ne 'fixture-1') {
    throw 'Windows PowerShell 5.1 hydrated the wrong generation.'
}
$response = Get-DuneDeepDesertMapResponse -RequestId 'ps51-probe'
if ([int]$response.schemaVersion -ne 1 -or @($response.data.layers).Count -ne 2) {
    throw 'Windows PowerShell 5.1 could not invoke the Maps cache contract.'
}
[pscustomobject]@{
    ok = $true
    generation = [string]$snapshot.snapshot['generation']
    revision = [long]$snapshot.revision
    mapLayers = @($response.data.layers).Count
} | ConvertTo-Json -Compress
