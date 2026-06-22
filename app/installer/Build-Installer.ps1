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

# ---------------------------------------------------------------------------
# Pre-flight: Windows PowerShell 5.1 parse-check of every .ps1 the installer
# will bundle.
#
# DuneServer.exe is compiled via PS2EXE, which produces a Windows PowerShell
# 5.1 host. PS 5.1 reads .ps1 files WITHOUT a UTF-8 BOM as the system ANSI
# codepage (Windows-1252 on en-US), not UTF-8. If a BOM-less file contains
# UTF-8 multi-byte characters (em-dash, ellipsis, right-arrow, etc.) the
# resulting byte stream can confuse PS 5.1's parser and produce bogus
# "Missing closing '}'" errors at runtime — even though PowerShell 7 (used
# during development) parses the file cleanly.
#
# This bit us in v11.4.0: Autostart.ps1 and ConsoleHost.ps1 shipped without
# BOMs and contained em-dashes/arrows, and DuneServer.exe failed to boot on
# every install. Catch it here, before the release ships.
# ---------------------------------------------------------------------------
$ps5Exe = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
if (Test-Path $ps5Exe) {
    $bundledPs1 = @()
    foreach ($d in @('server', 'lib', 'data', 'resources')) {
        $p = Join-Path $appRoot $d
        if (Test-Path $p) { $bundledPs1 += Get-ChildItem $p -Recurse -Filter '*.ps1' -File }
    }
    $bundledPs1 += Get-Item (Join-Path $appRoot 'DuneServer.ps1')

    # Stricter BOM check: any file containing non-ASCII bytes MUST have a
    # UTF-8 BOM, otherwise PS 5.1 (the runtime PS2EXE targets) decodes it
    # as Windows-1252 and produces silent mojibake (em-dash becomes â€",
    # the 0x94 byte terminates string literals early, etc.).
    #
    # The Parser::ParseFile check below is BOM-aware and won't catch this.
    # Only an actual dot-source under PS 5.1 (or this byte-level check)
    # will. We do the byte check here because it's near-instant.
    Write-Host "Checking UTF-8 BOM on non-ASCII .ps1 files..." -ForegroundColor Cyan
    $bomMissing = @()
    foreach ($f in $bundledPs1) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if ($hasBom) { continue }
        $hasNonAscii = $false
        foreach ($b in $bytes) { if ($b -gt 0x7F) { $hasNonAscii = $true; break } }
        if ($hasNonAscii) { $bomMissing += $f.FullName }
    }
    if ($bomMissing.Count -gt 0) {
        Write-Host "  BOM missing on these files (PS 5.1 would mojibake them at runtime):" -ForegroundColor Red
        foreach ($p in $bomMissing) { Write-Host "    $p" -ForegroundColor Red }
        throw "$($bomMissing.Count) .ps1 file(s) contain non-ASCII bytes without a UTF-8 BOM. Re-save them as UTF-8-with-BOM (in PowerShell: [IO.File]::WriteAllBytes(`$p, ([byte[]](0xEF,0xBB,0xBF)) + [IO.File]::ReadAllBytes(`$p)))."
    }
    Write-Host "  All non-ASCII .ps1 files carry a UTF-8 BOM." -ForegroundColor Green
    Write-Host ""

    $ps5ParseScript = @'
param([string[]]$Paths)
$exitCode = 0
foreach ($p in $Paths) {
  $errors = $null; $tokens = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    $exitCode = 1
    Write-Host ("FAIL: " + $p)
    foreach ($e in $errors) {
      Write-Host ("  L" + $e.Extent.StartLineNumber + " C" + $e.Extent.StartColumnNumber + ": " + $e.Message)
    }
  }
}
exit $exitCode
'@
    $ps5ScriptPath = Join-Path $env:TEMP "dune-ps5-parse-check-$([guid]::NewGuid().ToString('N')).ps1"
    Set-Content -LiteralPath $ps5ScriptPath -Value $ps5ParseScript -Encoding UTF8
    try {
        Write-Host "PS 5.1 parse pre-flight on $($bundledPs1.Count) .ps1 files..." -ForegroundColor Cyan
        $paths = $bundledPs1 | ForEach-Object { $_.FullName }
        & $ps5Exe -NoProfile -ExecutionPolicy Bypass -File $ps5ScriptPath -Paths $paths
        if ($LASTEXITCODE -ne 0) {
            throw "PS 5.1 parse pre-flight failed. PS2EXE compiles against PS 5.1; files that fail here will break DuneServer.exe at startup. Fix: add a UTF-8 BOM to any BOM-less .ps1 file containing non-ASCII characters."
        }
        Write-Host "  All .ps1 files parse under PS 5.1." -ForegroundColor Green
        Write-Host ""
    } finally {
        Remove-Item -LiteralPath $ps5ScriptPath -ErrorAction SilentlyContinue
    }
} else {
    Write-Warning "Windows PowerShell 5.1 not found at $ps5Exe — skipping PS 5.1 parse pre-flight. This is the runtime PS2EXE targets; missing the check means v11.4.0-class encoding bugs could ship undetected."
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

# Stage cloudflared.exe (powers the free Cloudflare quick tunnel) into
# installer\vendor so the .iss bundles it to {app}\cloudflared.exe. Source order:
# explicit override -> dev local-only tools -> official latest download.
$vendorDir = Join-Path $appRoot 'installer\vendor'
$cfVendor  = Join-Path $vendorDir 'cloudflared.exe'
if (-not (Test-Path $vendorDir)) { New-Item -ItemType Directory -Force -Path $vendorDir | Out-Null }
if (-not (Test-Path $cfVendor)) {
    $cfSource = $null
    foreach ($cand in @(
        $env:DUNE_CLOUDFLARED,
        (Join-Path $repoRoot 'local-only\tools\cloudflared.exe'),
        (Join-Path (Split-Path -Parent $repoRoot) 'local-only\tools\cloudflared.exe')
    )) {
        if ($cand -and (Test-Path -LiteralPath $cand)) { $cfSource = $cand; break }
    }
    if ($cfSource) {
        Write-Host "Staging cloudflared.exe from $cfSource ..." -ForegroundColor Cyan
        Copy-Item -LiteralPath $cfSource -Destination $cfVendor -Force
    } else {
        $cfUrl = 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe'
        Write-Host "Downloading cloudflared.exe from $cfUrl ..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $cfUrl -OutFile $cfVendor -UseBasicParsing
        } catch {
            throw "Could not stage cloudflared.exe (no local copy and download failed: $($_.Exception.Message)). Place cloudflared.exe at $cfVendor or set `$env:DUNE_CLOUDFLARED."
        }
    }
}
if (-not (Test-Path $cfVendor)) { throw "cloudflared.exe missing at $cfVendor" }
Write-Host ("  cloudflared staged ({0:N1} MB)." -f ((Get-Item $cfVendor).Length / 1MB)) -ForegroundColor Green
Write-Host ""

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
