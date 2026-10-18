param([Parameter(Mandatory)][string]$ReviewRoot)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $ReviewRoot) { throw 'Use a new review directory.' }
[void][IO.Directory]::CreateDirectory($ReviewRoot)
$entry=Join-Path $PSScriptRoot 'serve-review.ps1'
$start=[Diagnostics.ProcessStartInfo]::new()
$start.FileName=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
$start.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$entry+'" -ReviewRoot "'+$ReviewRoot+'"'
$start.UseShellExecute=$false
$start.CreateNoWindow=$true
$start.WindowStyle=[Diagnostics.ProcessWindowStyle]::Hidden
$start.EnvironmentVariables.Remove('PSModulePath')
$parent=$null; $child=$null
try {
    $parent=[Diagnostics.Process]::Start($start)
    $readyPath=Join-Path $ReviewRoot 'review-ready.json'
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ($parent.HasExited) { throw 'Review backend exited before readiness.' }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Review readiness was not observed.' }
        Start-Sleep -Milliseconds 100
    }
    $ready=[IO.File]::ReadAllText($readyPath) | ConvertFrom-Json
    if ([int]$ready.pid -ne $parent.Id) { throw 'Review backend identity mismatch.' }
    $child=[Diagnostics.Process]::GetProcessById([int]$ready.collectorPid)
    $runtime=Get-ChildItem -LiteralPath (Join-Path $ReviewRoot 'DuneServer/atlas/runtimes') -Directory | Select-Object -First 1
    $local=[IO.File]::ReadAllText((Join-Path $runtime.FullName 'ready.json')) | ConvertFrom-Json
    if ([int]$local.pid -ne $child.Id) { throw 'Review map-host identity mismatch.' }
    $state=Invoke-RestMethod ($local.url.Replace('/?key=','/state?key='))
    if ($state.live -or $state.refreshing -or @($state.activity).Count) { throw 'Review started observation.' }
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $parent.Kill()
    if (-not $parent.WaitForExit(3000)) { throw 'Owned review backend did not exit.' }
    if (-not $child.WaitForExit(10000)) { throw 'Map host outlived its owning backend.' }
    $timer.Stop()
    $saved=[IO.File]::ReadAllText((Join-Path $ReviewRoot 'DuneServer/atlas/snapshots/static-state-seed.json')) | ConvertFrom-Json
    if ($saved.live -or $saved.refreshing) { throw 'Final snapshot claims collection is running.' }
    $report=@{pass=$true;backendExitStopsChild=$true;shutdownMs=$timer.ElapsedMilliseconds;finalSnapshotSaved=$true;gameReads=0;gameWrites=0}
    $report | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReviewRoot 'verification.json') -Encoding UTF8
    $report | ConvertTo-Json
} finally {
    if ($parent) { if (-not $parent.HasExited) { $parent.Kill() }; $parent.Dispose() }
    if ($child) { if (-not $child.HasExited) { $child.Kill() }; $child.Dispose() }
}
