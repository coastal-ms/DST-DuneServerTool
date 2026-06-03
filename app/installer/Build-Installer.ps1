# Build-Installer.ps1 - Compiles app/installer/DuneServer.iss into DuneServerSetup.exe via Inno Setup.
#
# Output: app/installer/output/DuneServerSetup.exe
#
# Requirements:
#   - Inno Setup 6 (install via:  winget install --id JRSoftware.InnoSetup)
#   - Node.js + npm (build-time only) for `npm run build` in webui/
#   - Build-Exe.ps1 must have been run first (this script depends on DuneServer.exe)

[CmdletBinding()]
param(
    [switch]$SkipExeBuild,
    [switch]$SkipWebBuild,
    [switch]$SkipShellBuild,
    [switch]$SkipVersionCheck,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'

$appRoot    = Split-Path -Parent $PSScriptRoot                          # ...\app
$repoRoot   = Split-Path -Parent $appRoot                               # ...\<repo>
$webuiDir   = Join-Path $repoRoot 'webui'
$webuiDist  = Join-Path $webuiDir 'dist'
$iss        = Join-Path $appRoot 'installer\DuneServer.iss'
$exePath    = Join-Path $appRoot 'build\output\DuneServer.exe'
$outDir     = Join-Path $appRoot 'installer\output'
$installer  = Join-Path $outDir 'DuneServerSetup.exe'

# ---------------------------------------------------------------------------
# Pre-flight: version-stamp sync check.
#
# DST keeps the release version in FIVE files that must all match. Historically
# this was a manual procedure and at least once (v10.1.12) someone forgot to
# bump them, so the installer reported the prior version's number and the
# auto-updater couldn't deliver the release. Catch that before doing any of
# the long build steps below.
#
# If the stamps disagree, abort with a clear listing. To override (e.g. for
# a deliberate intermediate test build), pass `-SkipVersionCheck`.
# ---------------------------------------------------------------------------
$versionFiles = @(
    @{ Path = Join-Path $repoRoot 'dune-server.ps1';                 Pattern = '\$script:ToolVersion\s*=\s*"([0-9]+\.[0-9]+\.[0-9]+)"';     Label = '$script:ToolVersion' },
    @{ Path = Join-Path $appRoot  'DuneServer.ps1';                  Pattern = "\`$script:DuneToolVersion\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'"; Label = '$script:DuneToolVersion' },
    @{ Path = Join-Path $appRoot  'build\Build-Exe.ps1';             Pattern = "\[string\]\`$Version\s*=\s*'([0-9]+\.[0-9]+\.[0-9]+)'";     Label = 'Build-Exe.ps1 default $Version' },
    @{ Path = Join-Path $appRoot  'installer\DuneServer.iss';        Pattern = '#define\s+MyAppVersion\s+"([0-9]+\.[0-9]+\.[0-9]+)"';       Label = 'MyAppVersion' },
    @{ Path = Join-Path $appRoot  'desktop\DuneShell\DuneShell.csproj'; Pattern = '<Version>([0-9]+\.[0-9]+\.[0-9]+)</Version>';            Label = 'DuneShell <Version>' }
)
if (-not $SkipVersionCheck) {
    $stampReport = foreach ($vf in $versionFiles) {
        if (-not (Test-Path -LiteralPath $vf.Path)) {
            throw "Version-stamp file not found: $($vf.Path)"
        }
        $m = Select-String -Path $vf.Path -Pattern $vf.Pattern -List
        if (-not $m) {
            throw "Could not find version stamp in $($vf.Path) using pattern: $($vf.Pattern)"
        }
        [pscustomobject]@{
            File    = $vf.Path.Substring($repoRoot.Length + 1)
            Label   = $vf.Label
            Version = $m.Matches[0].Groups[1].Value
        }
    }
    $distinct = @($stampReport.Version | Sort-Object -Unique)
    Write-Host "Version-stamp check:" -ForegroundColor Cyan
    foreach ($r in $stampReport) {
        $marker = if ($distinct.Count -eq 1) { '[x]' } else { '[!]' }
        Write-Host ("  {0} {1,-32} {2}" -f $marker, $r.Label, $r.Version)
    }
    if ($distinct.Count -ne 1) {
        Write-Host ""
        throw "Version stamps disagree (found: $($distinct -join ', ')). Bump all 5 files to the same release version before building, or pass -SkipVersionCheck for a deliberate intermediate build."
    }
    Write-Host "  All 5 stamps match: $($distinct[0])" -ForegroundColor Green
    Write-Host ""
}

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

# Build the React SPA (writes webui/dist) — bundled into installer below.
if (-not $SkipWebBuild) {
    if (-not (Test-Path $webuiDir)) { throw "webui/ folder not found at $webuiDir" }
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $npm) { throw "npm not found in PATH. Install Node.js to build the web UI." }
    Write-Host "Building React SPA (npm run build)..." -ForegroundColor Cyan
    Push-Location $webuiDir
    try {
        & $npm.Source run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed (exit $LASTEXITCODE)" }
    } finally { Pop-Location }
    Write-Host ""
}
if (-not (Test-Path (Join-Path $webuiDist 'index.html'))) {
    throw "webui/dist/index.html not found - run 'npm run build' in $webuiDir (or omit -SkipWebBuild)"
}

# Build the .exe (unless skipped)
if (-not $SkipExeBuild) {
    Write-Host "Building DuneServer.exe first..." -ForegroundColor Cyan
    & (Join-Path $appRoot 'build\Build-Exe.ps1') -Quiet
    Write-Host ""
}

if (-not (Test-Path $exePath)) {
    throw "DuneServer.exe not found at $exePath - run Build-Exe.ps1 first (or omit -SkipExeBuild)"
}

# Build the standalone WebView2 app window (DuneShell.exe). Self-contained
# single-file publish; the .iss bundles it beside DuneServer.exe. Requires the
# .NET SDK (dotnet) on PATH.
$shellProj = Join-Path $appRoot 'desktop\DuneShell\DuneShell.csproj'
$shellExe  = Join-Path $appRoot 'desktop\DuneShell\bin\Release\net10.0-windows\win-x64\publish\DuneShell.exe'
if (-not $SkipShellBuild) {
    if (-not (Test-Path $shellProj)) { throw "DuneShell.csproj not found at $shellProj" }
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) { throw "dotnet SDK not found in PATH. Install .NET 10 SDK to build DuneShell." }
    Write-Host "Publishing DuneShell.exe (WebView2 app window)..." -ForegroundColor Cyan
    & $dotnet.Source publish $shellProj -c Release -r win-x64 -p:PublishSingleFile=true --self-contained true --nologo
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed for DuneShell (exit $LASTEXITCODE)" }
    Write-Host ""
}
if (-not (Test-Path $shellExe)) {
    throw "DuneShell.exe not found at $shellExe - run 'dotnet publish' for DuneShell (or omit -SkipShellBuild)"
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
Write-Host "  [x] DuneServer.exe: self-elevates in-script (after single-instance check)"   -ForegroundColor Green
Write-Host "  [x] dune-server.ps1: #Requires -RunAsAdministrator"                   -ForegroundColor Green

if ($Open) {
    Start-Process explorer.exe "/select,`"$installer`""
}
