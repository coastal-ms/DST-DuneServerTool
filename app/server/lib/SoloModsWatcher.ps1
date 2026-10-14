param([string]$LoaderRoot, [string]$GameExe, [string]$RuntimeDll, [switch]$RestoreOnly, [switch]$SkipIntro)
# Dot-sourced by the HTTP library loader: do nothing until explicitly invoked.
if (-not $LoaderRoot) { return }
$ErrorActionPreference='Stop'
function Get-DuneSoloWatcherHash([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','') }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}
$journal=Join-Path $LoaderRoot 'session.json'
if(-not(Test-Path -LiteralPath $journal)){return}
try {
    if(-not $RestoreOnly){
        . (Join-Path $PSScriptRoot 'SoloMods.ps1')
        $launchSession=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
        $process=Start-Process -FilePath $GameExe -WorkingDirectory (Split-Path $GameExe) -ArgumentList (Get-DuneSoloLaunchArguments -SkipIntro:$SkipIntro -RuntimeDll $RuntimeDll -ExtraArguments ([string]$launchSession.soloArguments)) -PassThru
        $process.WaitForExit()
        while(Get-Process -Name DuneSandbox,DuneSandbox_BE,DuneSandbox-Win64-Shipping,DuneSandbox-WinGDK-Shipping,AppDuneAwakeningShipping -ErrorAction SilentlyContinue){Start-Sleep -Seconds 2}
    } elseif(Get-Process -Name DuneSandbox,DuneSandbox_BE,DuneSandbox-Win64-Shipping,DuneSandbox-WinGDK-Shipping,AppDuneAwakeningShipping -ErrorAction SilentlyContinue){throw 'Close Dune before restoring its launch files.'}
    $session=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
    if($session.logPath -and (Test-Path $session.logPath)){
        Copy-Item -LiteralPath $session.logPath -Destination (Join-Path $LoaderRoot 'last-runtime.log') -Force
        if (-not $RestoreOnly -and $session.runtimeVersion -and $session.runtimeVersion -ne '3.0.1-1140-gf58e8f84' -and
            (Test-DuneSoloRuntimeStartupFailure ([IO.File]::ReadAllText($session.logPath)))) {
            @{version='3.0.1-1140-gf58e8f84';reason='Current runtime failed initialization; use previous runtime for the next launch.'} |
                ConvertTo-Json | Set-Content -LiteralPath (Join-Path $LoaderRoot 'runtime-fallback.json') -Encoding utf8
        }
    }
    foreach($record in $session.files){
        if(-not $record.installed -or $record.restored){continue}
        if(Test-Path -LiteralPath $record.path){if((Get-DuneSoloWatcherHash $record.path) -ne $record.hash){throw "Launch file changed outside DST; preserved: $($record.path)"}}
        if(Test-Path -LiteralPath $record.backup){Copy-Item -LiteralPath $record.backup -Destination $record.path -Force}
        elseif(Test-Path -LiteralPath $record.path){Remove-Item -LiteralPath $record.path}
        $record.restored=$true
        $session | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $journal -Encoding utf8
    }
    Remove-Item -LiteralPath $journal
} catch {
    $_.Exception.Message | Set-Content (Join-Path $LoaderRoot 'launch-error.txt') -Encoding utf8
    throw
}
