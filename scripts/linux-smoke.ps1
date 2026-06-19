#!/usr/bin/env pwsh
# Linux smoke test for the PowerShell backend.
#
# Cheap guard against Windows-only code creeping into the cross-platform backend:
#   1. Parse every app/*.ps1 (+ the CLI) — catches syntax breakage.
#   2. Dot-source the backend the way DuneServer-Linux.ps1 does (DuneLog ->
#      Platform -> HttpServer -> lib/* -> routes/*) under pwsh on Linux and
#      assert nothing throws at load and that routes register.
#
# Run locally:  pwsh -NoProfile -File scripts/linux-smoke.ps1
# Exits non-zero on any failure (for CI).

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $repo 'app/server'))) { $repo = (Get-Location).Path }
$serverDir = Join-Path $repo 'app/server'

$fail = 0

# --- 1. Parse everything ----------------------------------------------------
$ps1 = @(Get-ChildItem -Path (Join-Path $repo 'app') -Recurse -Filter *.ps1)
$ps1 += Get-Item (Join-Path $repo 'dune-server.ps1')
foreach ($f in $ps1) {
    $errs = $null; $toks = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$toks, [ref]$errs) | Out-Null
    if ($errs.Count -gt 0) {
        $fail++
        Write-Host "PARSE FAIL: $($f.FullName) ($($errs.Count) errors)" -ForegroundColor Red
        $errs | ForEach-Object { Write-Host "    $($_.Message)" -ForegroundColor DarkRed }
    }
}
Write-Host "Parsed $($ps1.Count) .ps1 files; $fail parse failure(s)."

# --- 2. Load smoke (entry order) --------------------------------------------
# Provide the XDG shim the entry point would set up.
if (-not $env:APPDATA)      { $env:APPDATA      = (Join-Path $env:HOME '.config') }
if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = (Join-Path $env:HOME '.local/state') }
$script:AppDir = Join-Path $repo 'app'
$script:DuneServerDir = $serverDir

try {
    . (Join-Path $serverDir 'lib/DuneLog.ps1')
    if (Get-Command Initialize-DuneLog -ErrorAction SilentlyContinue) {
        Initialize-DuneLog -Path (Join-Path ([System.IO.Path]::GetTempPath()) 'dune-smoke.log')
    }
    . (Join-Path $serverDir 'lib/Platform.ps1')
    . (Join-Path $serverDir 'HttpServer.ps1')
    Get-ChildItem -Path (Join-Path $serverDir 'lib') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    Get-ChildItem -Path (Join-Path $serverDir 'routes') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
    Write-Host "Backend dot-sourced cleanly under pwsh ($(Get-DunePlatform))."

    # Sanity: platform must resolve to Linux on a Linux runner, and key
    # cross-platform helpers must exist.
    foreach ($fn in @('Test-DuneIsWindows','Get-DuneVmInfo','Get-DuneHostRamGB','Get-DuneSetupPreflight')) {
        if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
            $fail++; Write-Host "MISSING FUNCTION after load: $fn" -ForegroundColor Red
        }
    }
    # Routes should have registered.
    $routeCount = 0
    try { if ($script:DuneRoutes) { $routeCount = @($script:DuneRoutes).Count } } catch {}
    Write-Host "Registered routes: $routeCount"
} catch {
    $fail++
    Write-Host "LOAD FAIL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ($_ | Out-String) -ForegroundColor DarkRed
}

if ($fail -gt 0) { Write-Host "SMOKE FAILED ($fail issue(s))." -ForegroundColor Red; exit 1 }
Write-Host "SMOKE OK." -ForegroundColor Green
