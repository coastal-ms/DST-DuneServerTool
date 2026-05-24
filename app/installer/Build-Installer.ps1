# Build-Installer.ps1 - Compiles app/installer/DuneServer.iss into DuneServerSetup.exe via Inno Setup.
#
# Output: app/installer/output/DuneServerSetup.exe
#
# Requirements:
#   - Inno Setup 6 (install via:  winget install --id JRSoftware.InnoSetup)
#   - Build-Exe.ps1 must have been run first (this script depends on DuneServer.exe)

[CmdletBinding()]
param(
    [switch]$SkipExeBuild,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'

$appRoot    = Split-Path -Parent $PSScriptRoot                          # ...\app
$iss        = Join-Path $appRoot 'installer\DuneServer.iss'
$exePath    = Join-Path $appRoot 'build\output\DuneServer.exe'
$outDir     = Join-Path $appRoot 'installer\output'
$installer  = Join-Path $outDir 'DuneServerSetup.exe'

# Locate ISCC.exe
$isccCandidates = @(
    'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    'C:\Program Files\Inno Setup 6\ISCC.exe',
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) {
    throw "ISCC.exe not found. Install Inno Setup 6: winget install --id JRSoftware.InnoSetup"
}

# Build the .exe first (unless skipped)
if (-not $SkipExeBuild) {
    Write-Host "Building DuneServer.exe first..." -ForegroundColor Cyan
    & (Join-Path $appRoot 'build\Build-Exe.ps1') -Quiet
    Write-Host ""
}

if (-not (Test-Path $exePath)) {
    throw "DuneServer.exe not found at $exePath - run Build-Exe.ps1 first (or omit -SkipExeBuild)"
}

# Ensure output dir
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

Write-Host "Compiling installer via $iscc ..." -ForegroundColor Cyan
$proc = Start-Process -FilePath $iscc -ArgumentList "`"$iss`"" -NoNewWindow -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "ISCC failed with exit code $($proc.ExitCode)"
}

if (-not (Test-Path $installer)) {
    throw "Installer not produced: $installer"
}

$size = [Math]::Round(((Get-Item $installer).Length / 1MB), 2)
Write-Host ""
Write-Host "  Built: $installer ($size MB)" -ForegroundColor Green
Write-Host ""
Write-Host "Admin requirements (all 3 layers):" -ForegroundColor Cyan
Write-Host "  [x] Setup itself: PrivilegesRequired=admin (writes to Program Files)" -ForegroundColor Green
Write-Host "  [x] DuneServer.exe: embedded UAC manifest via ps2exe -requireAdmin"   -ForegroundColor Green
Write-Host "  [x] dune-server.ps1: #Requires -RunAsAdministrator"                   -ForegroundColor Green

if ($Open) {
    Start-Process explorer.exe "/select,`"$installer`""
}
