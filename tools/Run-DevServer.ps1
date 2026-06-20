#Requires -Version 7.0
<#
.SYNOPSIS
    Run the DST backend HTTP server directly from source — no PS2EXE build, no
    installer, no tray/app-window launcher.

.DESCRIPTION
    Dot-sources the same server files the installed app loads (DuneLog ->
    Bootstrap -> HttpServer -> lib/*.ps1 -> routes/*.ps1), then starts the HTTP
    listener on 127.0.0.1:<Port>. Uses the SHARED config at
    %APPDATA%\DuneServer\dune-server.config, so it talks to the same VM / SSH
    key the installed app does — you can test real flows (incl. Public IP apply)
    against your UAT VM without rebuilding the exe each time.

    Fast loop:
      * Backend change (*.ps1): Ctrl+C this script, re-run it (~2s).
      * Frontend change (*.tsx): run `npm run dev` in webui/ (vite HMR, proxies
        /api + /ws to this server). Or `npm run build` and reload.

    NOTE: launch from an **elevated** terminal if you want to test the Public IP
    apply end to end — its Windows host-route step needs admin. Without admin,
    everything up to that step still works (good for UI/flow testing).

.PARAMETER Port
    Preferred listen port (default 47823, matching webui/vite.config.ts proxy).

.PARAMETER Token
    Per-request token. Default '' (empty) = localhost dev escape hatch: the API
    is open with no token so `npm run dev` works without juggling a token.

.EXAMPLE
    pwsh tools\Run-DevServer.ps1
    # then open http://localhost:5173 (npm run dev) or http://127.0.0.1:47823
#>
[CmdletBinding()]
param(
    [int]$Port = 47823,
    [string]$Token = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$appDir    = Join-Path $repoRoot 'app'
$serverDir = Join-Path $appDir 'server'
$distRoot  = Join-Path $repoRoot 'webui\dist'

if (-not (Test-Path -LiteralPath $serverDir)) { throw "server dir not found: $serverDir" }
if (-not (Test-Path -LiteralPath $distRoot)) {
    Write-Warning "webui\dist not found. Run 'npm run build' in webui/ (or use 'npm run dev'). Serving API only."
}

# Context vars the server + handler pool read (mirrors DuneServer.ps1).
$script:AppDir          = $appDir
$script:DuneServerDir   = $serverDir
$script:MainScript      = Join-Path $repoRoot 'dune-server.ps1'
$script:PwshExe         = (Get-Process -Id $PID).Path
$script:DuneIsCompiledExe = $false

# Dot-source order: DuneLog first, then Bootstrap, then HttpServer, then the
# alphabetical lib loop (skipping those two), then routes.
. (Join-Path $serverDir 'lib\DuneLog.ps1')
$script:DuneLogFilePath = Join-Path $env:LOCALAPPDATA 'DuneServer\dune-server-dev.log'
Initialize-DuneLog -Path $script:DuneLogFilePath

. (Join-Path $serverDir 'lib\Bootstrap.ps1')
. (Join-Path $serverDir 'HttpServer.ps1')
$script:DuneServerDir = $serverDir   # re-assert after HttpServer.ps1 dot-source
Get-ChildItem -Path (Join-Path $serverDir 'lib') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    if ($_.Name -ieq 'DuneLog.ps1' -or $_.Name -ieq 'Bootstrap.ps1') { return }
    . $_.FullName
}
Get-ChildItem -Path (Join-Path $serverDir 'routes') -Filter '*.ps1' | Sort-Object Name | ForEach-Object { . $_.FullName }

$elevated = $false
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = ([Security.Principal.WindowsPrincipal]::new($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}

Write-Host ''
Write-Host '  DST dev server (from source)' -ForegroundColor Cyan
Write-Host "  elevated : $elevated $(if (-not $elevated) { '(Public IP apply host-route step will fail without admin)' })" -ForegroundColor $(if ($elevated) { 'Green' } else { 'Yellow' })
Write-Host "  token    : $(if ($Token) { 'set' } else { 'none (open localhost dev API)' })"
Write-Host "  webui    : http://localhost:5173  (run 'npm run dev' in webui/ for HMR)" -ForegroundColor Cyan
Write-Host '  Ctrl+C to stop. Re-run after a .ps1 change.' -ForegroundColor DarkGray
Write-Host ''

Start-DuneHttpServer -DistRoot $distRoot -PreferredPort $Port -Token $Token
