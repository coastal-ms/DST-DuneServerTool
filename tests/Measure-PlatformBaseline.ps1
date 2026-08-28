[CmdletBinding()]
param(
    [int] $WebBuildRuns = 3,
    [int] $BackendLoadRuns = 5,
    [int] $SshLaunchRuns = 10
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

function Get-Median {
    param([double[]] $Values)
    $sorted = @($Values | Sort-Object)
    return $sorted[[math]::Floor($sorted.Count / 2)]
}

$routeDir = Join-Path $repo 'app\server\routes'
$routes = @(
    Get-ChildItem $routeDir -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
        $file = $_
        [regex]::Matches(
            (Get-Content $file.FullName -Raw),
            "Register-DuneRoute\s+-Method\s+(?<method>[A-Z]+)\s+-Path\s+'(?<path>[^']+)'"
        ) | ForEach-Object {
            [pscustomobject]@{
                file = $file.Name
                method = $_.Groups['method'].Value
                path = $_.Groups['path'].Value
            }
        }
    }
)

$webBuildMs = @()
Push-Location (Join-Path $repo 'webui')
try {
    for ($i = 0; $i -lt $WebBuildRuns; $i++) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        & $env:ComSpec /d /c 'npm run build --silent >nul 2>&1'
        if ($LASTEXITCODE -ne 0) { throw "WebUI build $($i + 1) failed." }
        $timer.Stop()
        $webBuildMs += [math]::Round($timer.Elapsed.TotalMilliseconds)
    }
    $index = Get-Content 'dist\index.html' -Raw
    $entryName = [regex]::Match($index, 'src="/assets/(?<name>[^"]+\.js)"').Groups['name'].Value
    $entry = Get-Item (Join-Path 'dist\assets' $entryName)
    $jsCount = @(Get-ChildItem 'dist\assets' -Filter '*.js').Count
} finally {
    Pop-Location
}

$backendLoadMs = @()
for ($i = 0; $i -lt $BackendLoadRuns; $i++) {
    $measurement = & pwsh -NoProfile -Command @"
`$env:DST_REPO_ROOT = '$repo'
. '$repo\tests\_TestHelpers.ps1'
Register-DstStubs
`$timer = [Diagnostics.Stopwatch]::StartNew()
Get-ChildItem '$repo\app\server\lib' -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . `$_.FullName }
. '$repo\app\server\HttpServer.ps1'
Get-ChildItem '$repo\app\server\routes' -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . `$_.FullName }
`$timer.Stop()
[math]::Round(`$timer.Elapsed.TotalMilliseconds)
"@
    if ($LASTEXITCODE -ne 0) { throw "Backend load $($i + 1) failed." }
    $backendLoadMs += [double]($measurement | Select-Object -Last 1)
}

$sshLaunchMs = @()
for ($i = 0; $i -lt $SshLaunchRuns; $i++) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $priorErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        & ssh -V 2>$null
        $sshExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $priorErrorActionPreference
    }
    if ($sshExitCode -ne 0) { throw "SSH process launch $($i + 1) failed." }
    $timer.Stop()
    $sshLaunchMs += [math]::Round($timer.Elapsed.TotalMilliseconds, 1)
}

$mapData = Get-Content (Join-Path $repo 'webui\src\data\wickmaps.json') -Raw | ConvertFrom-Json
$mapContracts = @(
    foreach ($seed in $mapData.seeds) {
        $normalized = @(
            $seed.pois | ForEach-Object {
                [ordered]@{ sector = [string]$_.sector; subx = [int]$_.subx; suby = [int]$_.suby; type = [string]$_.type }
            }
        ) | ConvertTo-Json -Compress -Depth 4
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($normalized))
        } finally {
            $sha256.Dispose()
        }
        $digest = -join @($hashBytes | ForEach-Object { $_.ToString('x2') })
        [ordered]@{
            seed = $seed.seed
            poiCount = $seed.poiCount
            markersSha256 = $digest
        }
    }
)

[ordered]@{
    sourceCommit = (& git -C $repo rev-parse HEAD)
    webuiBuild = [ordered]@{
        runsMs = $webBuildMs
        medianMs = Get-Median $webBuildMs
        initialEntryJsBytes = $entry.Length
        javascriptAssetCount = $jsCount
        routeChunkCount = [math]::Max(0, $jsCount - 1)
    }
    backendLoad = [ordered]@{
        runsMs = $backendLoadMs
        medianMs = Get-Median $backendLoadMs
    }
    sshProcessLaunch = [ordered]@{
        runsMs = $sshLaunchMs
        medianMs = Get-Median $sshLaunchMs
    }
    routes = [ordered]@{
        httpCount = $routes.Count
        byMethod = @($routes | Group-Object method | Sort-Object Name | ForEach-Object {
            [ordered]@{ method = $_.Name; count = $_.Count }
        })
    }
    deepDesertStaticMaps = $mapContracts
} | ConvertTo-Json -Depth 8
