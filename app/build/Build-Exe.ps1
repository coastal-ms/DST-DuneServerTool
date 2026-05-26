# Build-Exe.ps1 - Compiles app/DuneServer.ps1 into DuneServer.exe via ps2exe.
#
# Output: app/build/output/DuneServer.exe
#
# Requirements:
#   - PowerShell 7+ (pwsh)
#   - ps2exe module (auto-installed if missing)
#
# The compiled .exe (v6.1+):
#   - Embeds a UAC manifest (-requireAdmin) so launching always elevates
#     (Hyper-V cmdlets need admin, matching the v6.0.x WPF host behavior)
#   - Runs with a console window so server logs are visible to the user
#   - Bundles the icon for taskbar / Alt-Tab / file explorer
#   - Self-bootstraps the local HTTP server + opens the default browser
#
# v6.0.x was WPF (-NoConsole / -STA); v6.1 swapped to the web portal so we
# DO want the console window now — it acts as the live server log viewer.

[CmdletBinding()]
param(
    [string]$Version = '6.1.0',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

$appRoot   = Split-Path -Parent $PSScriptRoot   # ...\app  (this script lives in app\build\)
$src       = Join-Path $appRoot 'DuneServer.ps1'
$icon      = Join-Path $appRoot 'assets\icon.ico'
$outDir    = Join-Path $appRoot 'build\output'
$outExe    = Join-Path $outDir 'DuneServer.exe'

if (-not (Test-Path $src))  { throw "Source not found: $src" }
if (-not (Test-Path $icon)) { throw "Icon not found: $icon" }
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# Ensure ps2exe is available
if (-not (Get-Module -ListAvailable ps2exe)) {
    Write-Host "Installing ps2exe..." -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force

$verNum = "$Version.0"  # ps2exe wants 4-part version

Write-Host "Compiling DuneServer.exe (v$Version)..." -ForegroundColor Cyan

# Note: ps2exe needs splatting and explicit flags. Critical flags (v6.1):
#   -requireAdmin  : embeds UAC manifest -> always launches elevated
#   -iconFile      : taskbar / file explorer icon
# Removed in v6.1 (WPF-era flags):
#   -NoConsole, -STA, -NoOutput, -NoError — we now WANT the console window
#   to show live HTTP server logs while the React SPA runs in the browser.
$ps2exeArgs = @{
    InputFile      = $src
    OutputFile     = $outExe
    IconFile       = $icon
    Title          = 'Dune Server'
    Description    = 'Dune Awakening server management - web portal'
    Company        = 'Dune Awakening Self-Hosted Tool'
    Product        = 'Dune Server'
    Version        = $verNum
    Copyright      = '(c) 2026 Dune Awakening Self-Hosted Tool'
    RequireAdmin   = $true
}

Invoke-ps2exe @ps2exeArgs

if (-not (Test-Path $outExe)) {
    throw "Compilation failed - output not produced: $outExe"
}

$size = [Math]::Round(((Get-Item $outExe).Length / 1KB), 1)
Write-Host ""
Write-Host "  Built: $outExe ($size KB)" -ForegroundColor Green
Write-Host ""

if (-not $Quiet) {
    Write-Host "Admin requirements:" -ForegroundColor Cyan
    Write-Host "  [x] UAC manifest embedded (-requireAdmin)" -ForegroundColor Green
    Write-Host "  [x] Console window enabled (live server logs)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next step:"
    Write-Host "  & '$PSScriptRoot\..\installer\Build-Installer.ps1'"
}
