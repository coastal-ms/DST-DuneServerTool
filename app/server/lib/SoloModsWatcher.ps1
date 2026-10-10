param([string]$LoaderRoot, [string]$GameExe, [string]$RuntimeDll, [switch]$RestoreOnly, [switch]$SkipIntro)
# Dot-sourced by the HTTP library loader: do nothing until explicitly invoked.
if (-not $LoaderRoot) { return }
$ErrorActionPreference='Stop'
$journal=Join-Path $LoaderRoot 'session.json'
if(-not(Test-Path -LiteralPath $journal)){return}
try {
    if(-not $RestoreOnly){
        . (Join-Path $PSScriptRoot 'SoloMods.ps1')
        $launchSession=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
        $process=Start-Process -FilePath $GameExe -WorkingDirectory (Split-Path $GameExe) -ArgumentList (Get-DuneSoloLaunchArguments -SkipIntro:$SkipIntro -RuntimeDll $RuntimeDll -ExtraArguments ([string]$launchSession.soloArguments)) -PassThru
        $process.WaitForExit()
        while(Get-Process -Name DuneSandbox,DuneSandbox-Win64-Shipping -ErrorAction SilentlyContinue){Start-Sleep -Seconds 2}
    } elseif(Get-Process -Name DuneSandbox,DuneSandbox-Win64-Shipping -ErrorAction SilentlyContinue){throw 'Close Dune before restoring its launch files.'}
    $session=Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
    if($session.logPath -and (Test-Path $session.logPath)){Copy-Item -LiteralPath $session.logPath -Destination (Join-Path $LoaderRoot 'last-runtime.log') -Force}
    foreach($record in $session.files){
        if(-not $record.installed -or $record.restored){continue}
        if(Test-Path -LiteralPath $record.path){if((Get-FileHash -LiteralPath $record.path).Hash -ne $record.hash){throw "Launch file changed outside DST; preserved: $($record.path)"}}
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
