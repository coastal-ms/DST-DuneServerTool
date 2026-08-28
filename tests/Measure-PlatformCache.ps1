[CmdletBinding()]
param(
    [string]$HelperPath,
    [ValidateRange(5,100)][int]$HydrateIterations = 30,
    [ValidateRange(5,100)][int]$ReplaceIterations = 20
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $HelperPath) {
    $HelperPath = Join-Path $repoRoot 'app\tools\DunePlatformStore\bin\Release\net10.0-windows\win-x64\publish\DunePlatformStore.exe'
}
if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    throw "Published DunePlatformStore.exe was not found: $HelperPath"
}

function Invoke-MeasuredHelper {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$Database,
        [string]$InputJson
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $HelperPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add('--command')
    $start.ArgumentList.Add($Command)
    $start.ArgumentList.Add('--database')
    $start.ArgumentList.Add($Database)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw 'DunePlatformStore did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if ($InputJson) { $process.StandardInput.Write($InputJson) }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw "DunePlatformStore $Command timed out."
        }
        $watch.Stop()
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) {
            throw "DunePlatformStore $Command failed: $stderr"
        }
        return [pscustomobject]@{
            elapsedMs = $watch.Elapsed.TotalMilliseconds
            peakWorkingSetBytes = [long]$process.PeakWorkingSet64
            output = $stdout
        }
    } finally {
        $process.Dispose()
    }
}

function Get-Distribution {
    param([double[]]$Samples)
    $sorted = @($Samples | Sort-Object)
    $middle = [Math]::Floor($sorted.Count / 2)
    $median = if ($sorted.Count % 2 -eq 0) {
        ($sorted[$middle - 1] + $sorted[$middle]) / 2
    } else {
        $sorted[$middle]
    }
    $p95Index = [Math]::Ceiling($sorted.Count * 0.95) - 1
    [ordered]@{
        n = $sorted.Count
        min = [Math]::Round($sorted[0], 2)
        median = [Math]::Round($median, 2)
        p95 = [Math]::Round($sorted[$p95Index], 2)
        max = [Math]::Round($sorted[-1], 2)
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) "dst-platform-benchmark-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root -Force | Out-Null
$priorSelfTest = $env:DST_PLATFORM_SELF_TEST
$env:DST_PLATFORM_SELF_TEST = '1'
try {
    $database = Join-Path $root 'platform-cache-v1.sqlite'
    $fixture = & $HelperPath --command create-test-fixture --database $database --history-rows 100000 --poi-rows 2000 |
        ConvertFrom-Json
    if (-not $fixture.ok) { throw 'The benchmark fixture was not created.' }

    $warmup = Invoke-MeasuredHelper -Command hydrate -Database $database
    $hydrated = $warmup.output | ConvertFrom-Json
    $snapshot = $hydrated.snapshot
    $request = [ordered]@{
        generation = 'benchmark-0'
        sources = @()
        maps = @($snapshot.maps)
        layers = @($snapshot.layers)
        activeSpiceCurrent = @($snapshot.activeSpice)
        activeSpiceHistory = @()
        publicPois = @($snapshot.publicPois)
    }

    $hydrateSamples = [Collections.Generic.List[double]]::new()
    $replaceSamples = [Collections.Generic.List[double]]::new()
    $hydrateWorkingSets = [Collections.Generic.List[long]]::new()
    $replaceWorkingSets = [Collections.Generic.List[long]]::new()
    $hydratePayloadBytes = [Text.Encoding]::UTF8.GetByteCount($warmup.output)
    for ($index = 0; $index -lt $HydrateIterations; $index++) {
        $sample = Invoke-MeasuredHelper -Command hydrate -Database $database
        $sampleResult = $sample.output | ConvertFrom-Json
        [void]$hydrateSamples.Add($sample.elapsedMs)
        [void]$hydrateWorkingSets.Add([long]$sampleResult.workingSetBytes)
    }
    for ($index = 0; $index -lt $ReplaceIterations; $index++) {
        $request.generation = "benchmark-$($index + 1)"
        $requestJson = $request | ConvertTo-Json -Depth 12 -Compress
        $sample = Invoke-MeasuredHelper -Command replace-generation -Database $database -InputJson $requestJson
        $sampleResult = $sample.output | ConvertFrom-Json
        [void]$replaceSamples.Add($sample.elapsedMs)
        [void]$replaceWorkingSets.Add([long]$sampleResult.workingSetBytes)
    }

    [ordered]@{
        helperBytes = (Get-Item -LiteralPath $HelperPath).Length
        databaseBytes = (Get-Item -LiteralPath $database).Length
        hydratePayloadBytes = $hydratePayloadBytes
        hydrate = Get-Distribution -Samples $hydrateSamples.ToArray()
        replace = Get-Distribution -Samples $replaceSamples.ToArray()
        hydrateWorkingSetBytes = ($hydrateWorkingSets | Measure-Object -Maximum).Maximum
        replaceWorkingSetBytes = ($replaceWorkingSets | Measure-Object -Maximum).Maximum
        oneShotProcessesRemaining = @(Get-Process -Name DunePlatformStore -ErrorAction SilentlyContinue).Count
    } | ConvertTo-Json -Depth 5
} finally {
    $env:DST_PLATFORM_SELF_TEST = $priorSelfTest
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
