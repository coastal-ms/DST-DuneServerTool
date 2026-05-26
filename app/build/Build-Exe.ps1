# Build-Exe.ps1 - Compiles app/DuneServer.ps1 into DuneServer.exe via ps2exe.
#
# Output: app/build/output/DuneServer.exe
#
# Requirements:
#   - PowerShell 7+ (pwsh)
#   - ps2exe module (auto-installed if missing)
#
# The compiled .exe (v6.1.2+):
#   - NO -requireAdmin manifest. Elevation is handled IN-SCRIPT after the
#     single-instance mutex check, so a second click on the desktop shortcut
#     just opens the existing portal URL in the browser without a UAC prompt.
#     (Hyper-V cmdlets still need admin; the first launch self-elevates.)
#   - Runs hidden (-noConsole) - server presents as a tray icon (NotifyIcon)
#     with menu: Open Portal / Copy URL / View Log / Quit
#   - STA apartment so WinForms (NotifyIcon, MessageBox) is safe
#   - Bundles the icon for taskbar / Alt-Tab / file explorer / tray
#   - Self-bootstraps the local HTTP server + opens the default browser
#
# v6.0.x was WPF noConsole; v6.1.0 briefly enabled the console for live logs;
# v6.1.2 went back to noConsole + tray icon AND dropped -requireAdmin in favor
# of in-script elevation (so the single-instance gate runs before UAC).
# Logs are written to: %LOCALAPPDATA%\DuneServer\dune-server.log

[CmdletBinding()]
param(
    [string]$Version = '6.1.5',
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

# Critical flags (v6.1.2):
#   -noConsole     : windowless EXE - tray icon is the only UI surface
#   -STA           : required for System.Windows.Forms.NotifyIcon / MessageBox
#   -iconFile      : taskbar / file explorer / tray icon
# NOTE: -requireAdmin INTENTIONALLY OMITTED. The script self-elevates after
# the single-instance mutex check so subsequent shortcut clicks just open the
# browser to the existing portal URL without prompting for UAC again.
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
    NoConsole      = $true
    STA            = $true
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
    Write-Host "  [x] No UAC manifest - self-elevates in-script after single-instance check" -ForegroundColor Green
    Write-Host "  [x] No console window (-noConsole), tray icon UI" -ForegroundColor Green
    Write-Host "  [x] STA apartment (WinForms NotifyIcon)" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next step:"
    Write-Host "  & '$PSScriptRoot\..\installer\Build-Installer.ps1'"
}
