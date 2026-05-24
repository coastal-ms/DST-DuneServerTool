# Build-Exe.ps1 - Compiles app/DuneServer.ps1 into DuneServer.exe via ps2exe.
#
# Output: app/build/output/DuneServer.exe
#
# Requirements:
#   - PowerShell 7+ (pwsh)
#   - ps2exe module (auto-installed if missing)
#
# The compiled .exe:
#   - Embeds a UAC manifest (-requireAdmin) so launching always elevates
#   - Runs in -noConsole mode (WPF-only window, no black console flash)
#   - Uses STA threading (-sta) required for WPF
#   - Bundles the icon for taskbar / Alt-Tab / file explorer

[CmdletBinding()]
param(
    [string]$Version = '4.0.2',
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

# Note: ps2exe needs splatting and explicit flags. Critical flags:
#   -noConsole     : suppresses the console window (we use WPF only)
#   -requireAdmin  : embeds UAC manifest -> always launches elevated
#   -STA           : WPF must run on a single-threaded apartment
#   -noOutput      : compiled exe's Write-Output is suppressed (we use WPF for output)
#   -iconFile      : taskbar / file explorer icon
$ps2exeArgs = @{
    InputFile      = $src
    OutputFile     = $outExe
    IconFile       = $icon
    Title          = 'Dune Server'
    Description    = 'Dune Awakening server management - desktop app'
    Company        = 'Dune Awakening Self-Hosted Tool'
    Product        = 'Dune Server'
    Version        = $verNum
    Copyright      = '(c) 2025 Dune Awakening Self-Hosted Tool'
    NoConsole      = $true
    RequireAdmin   = $true
    STA            = $true
    NoOutput       = $true
    NoError        = $true
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
    Write-Host "  [x] STA threading enabled (WPF)"          -ForegroundColor Green
    Write-Host ""
    Write-Host "Next step:"
    Write-Host "  & '$PSScriptRoot\..\installer\Build-Installer.ps1'"
}
