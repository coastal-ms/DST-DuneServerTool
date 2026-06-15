#!/usr/bin/env pwsh
# Dune Server — Linux entry point (untested handoff scaffold).
#
# This is the Linux equivalent of app/DuneServer.ps1. It deliberately avoids
# the Windows-only bits the EXE entry needs:
#
#   * No Hyper-V self-elevation (no Hyper-V on Linux)
#   * No DuneShell / WebView2 launch (no native shell yet)
#   * No console minimize / tray P-Invoke (no Win32 API)
#   * No Task Scheduler autostart (use the systemd user unit instead)
#
# Status: UNTESTED. See LINUX-PORT-STATUS.md at the repo root for what works,
# what's stubbed, and what the recipient needs to wire up. The intent of this
# file is to give a Linux maintainer a believable starting point — not a
# fully-validated daemon.

$ErrorActionPreference = 'Stop'

# ---------- Sanity: pwsh on Linux ---------------------------------------------
if (-not $IsLinux -and -not $IsMacOS) {
    Write-Host 'DuneServer-Linux.ps1 is for Linux / macOS hosts. Use DuneServer.ps1 on Windows.' -ForegroundColor Yellow
    exit 1
}

# ---------- XDG compatibility shim --------------------------------------------
# The PowerShell codebase has dozens of  `Join-Path $env:APPDATA 'DuneServer'`
# and `Join-Path $env:LOCALAPPDATA 'DuneServer'` references that were written
# when the only target was Windows. Rather than refactor every one of them
# (high-risk for the Windows build), we map both env vars to XDG-equivalent
# locations under $HOME so the existing paths resolve to:
#
#   $env:APPDATA       -> $XDG_CONFIG_HOME or ~/.config       (writeable config)
#   $env:LOCALAPPDATA  -> $XDG_STATE_HOME  or ~/.local/state  (logs, last-url)
#
# The end result is:
#   ~/.config/DuneServer/dune-server.config
#   ~/.config/DuneServer/item-packages.json
#   ~/.local/state/DuneServer/dune-server.log
#   ~/.local/state/DuneServer/last-url.txt
#
# A clean handoff candidate would replace the env vars with proper helpers
# (Get-DuneConfigDir / Get-DuneStateDir) — left as future work.

function Initialize-DuneLinuxEnv {
    $home = $env:HOME
    if (-not $home) { $home = [System.Environment]::GetFolderPath('UserProfile') }
    if (-not $home) {
        Write-Host 'Cannot determine $HOME on this host.' -ForegroundColor Red
        exit 1
    }

    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $home '.config' }
    $stateHome  = if ($env:XDG_STATE_HOME)  { $env:XDG_STATE_HOME }  else { Join-Path $home '.local/state' }
    $cacheHome  = if ($env:XDG_CACHE_HOME)  { $env:XDG_CACHE_HOME }  else { Join-Path $home '.cache' }

    foreach ($d in @($configHome, $stateHome, $cacheHome,
                     (Join-Path $configHome 'DuneServer'),
                     (Join-Path $stateHome  'DuneServer'))) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }

    $env:APPDATA      = $configHome
    $env:LOCALAPPDATA = $stateHome
    # USERPROFILE is referenced in a few places (mostly diagnostics).
    if (-not $env:USERPROFILE) { $env:USERPROFILE = $home }
}

Initialize-DuneLinuxEnv

# ---------- Emergency crash log -----------------------------------------------
$script:DuneStartupLog = $null
try {
    $stateDir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    $script:DuneStartupLog = Join-Path $stateDir 'dune-startup.log'
    $hdr = "==== $(Get-Date -Format 's')  DuneServer-Linux startup, pid=$PID, host=$($PSVersionTable.PSVersion) ===="
    Add-Content -LiteralPath $script:DuneStartupLog -Value $hdr -Encoding UTF8
} catch { }

function Write-DuneStartupLog {
    param([string]$Message)
    if (-not $script:DuneStartupLog) { return }
    try { Add-Content -LiteralPath $script:DuneStartupLog -Value "[$(Get-Date -Format 'HH:mm:ss')] $Message" -Encoding UTF8 } catch { }
}

trap {
    $err = $_
    Write-DuneStartupLog "BOOTSTRAP CRASH: $($err.Exception.Message)"
    Write-DuneStartupLog ($err | Out-String)
    Write-Host "Dune Server bootstrap failed: $($err.Exception.Message)" -ForegroundColor Red
    Write-Host "Details: $script:DuneStartupLog" -ForegroundColor Red
    exit 1
}

Write-DuneStartupLog 'Bootstrap entered (Linux)'

# ---------- CLI args ----------------------------------------------------------
# --headless     : never try to open a browser
# --open-browser : explicitly request xdg-open on startup (default when stdout is a tty)
# --port <N>     : preferred starting port (default 8765)
$script:DuneHeadlessMode = $false
$script:DuneOpenBrowser  = $null   # null = auto-decide
$script:DunePreferredPort = 8765

for ($i = 0; $i -lt $args.Count; $i++) {
    switch -Regex ($args[$i]) {
        '^--?headless$'      { $script:DuneHeadlessMode = $true }
        '^--?open-browser$'  { $script:DuneOpenBrowser  = $true }
        '^--?no-browser$'    { $script:DuneOpenBrowser  = $false }
        '^--?port$'          { if ($i + 1 -lt $args.Count) { $script:DunePreferredPort = [int]$args[++$i] } }
    }
}
if ($null -eq $script:DuneOpenBrowser) {
    $script:DuneOpenBrowser = -not $script:DuneHeadlessMode
}

# ---------- Path resolution ---------------------------------------------------
if ($PSScriptRoot) {
    $script:AppDir = $PSScriptRoot
} elseif ($PSCommandPath) {
    $script:AppDir = Split-Path -Parent $PSCommandPath
} else {
    $script:AppDir = (Get-Location).Path
}
$script:RepoRoot = Split-Path -Parent $script:AppDir

function Find-DuneSubpath {
    param([string]$Sub, [int]$MaxLevels = 6)
    $probe = $script:AppDir
    for ($i = 0; $i -lt $MaxLevels -and $probe; $i++) {
        $candidate = Join-Path $probe $Sub
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        $parent = Split-Path -Parent $probe
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
    return $null
}

$script:DistRoot = Find-DuneSubpath 'webui/dist'
if (-not $script:DistRoot) {
    Write-Host "Could not locate webui/dist (searched upward from '$script:AppDir')." -ForegroundColor Red
    Write-Host 'Build it first: cd webui && npm ci && npm run build' -ForegroundColor Yellow
    exit 1
}

$serverDir = Find-DuneSubpath 'server'
if (-not $serverDir) {
    Write-Host "Could not locate server/ near '$script:AppDir'." -ForegroundColor Red
    exit 1
}
$script:DuneServerDir = $serverDir

# pwsh — on Linux it's just `pwsh` on PATH.
$script:PwshExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $script:PwshExe) {
    Write-Host 'pwsh (PowerShell 7) not found on PATH. Install from https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux' -ForegroundColor Red
    exit 1
}

$script:MainScript = Find-DuneSubpath 'dune-server.ps1'
if (-not $script:MainScript) {
    Write-Host "WARNING: dune-server.ps1 not found near '$script:AppDir'. Command execution will fail." -ForegroundColor Yellow
}

# ---------- Tool version (kept in sync with DuneServer.ps1) -------------------
# Mirrored manually for the scaffold. Build-Installer's version-sync check
# does NOT currently know about this file — see LINUX-PORT-STATUS.md.
$script:DuneToolVersion = '12.0.24'

# ---------- Load server + routes ----------------------------------------------
$duneLogFile = Join-Path $serverDir 'lib/DuneLog.ps1'
if (Test-Path -LiteralPath $duneLogFile) { . $duneLogFile }

$script:DuneLogFilePath = Join-Path $env:LOCALAPPDATA 'DuneServer/dune-server.log'
Initialize-DuneLog -Path $script:DuneLogFilePath

. (Join-Path $serverDir 'HttpServer.ps1')

$libDir = Join-Path $serverDir 'lib'
if (Test-Path $libDir) {
    Get-ChildItem -Path $libDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

$routesDir = Join-Path $serverDir 'routes'
if (Test-Path $routesDir) {
    Get-ChildItem -Path $routesDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

if (Get-Command Start-DuneGameplayBotScheduler -ErrorAction SilentlyContinue) {
    try { [void](Start-DuneGameplayBotScheduler -ServerDir $serverDir) } catch {}
}

# ---------- Token -------------------------------------------------------------
$script:LaunchToken = [Guid]::NewGuid().ToString('N')

# ---------- Clear stale last-url ----------------------------------------------
$urlFilePath = Join-Path $env:LOCALAPPDATA 'DuneServer/last-url.txt'
try {
    if (Test-Path -LiteralPath $urlFilePath) { Remove-Item -LiteralPath $urlFilePath -Force -ErrorAction Stop }
} catch {
    Write-DuneLog "Could not remove stale last-url.txt: $($_.Exception.Message)" 'WARN'
}

# ---------- Browser opener (async, after listener binds) ----------------------
# On Linux we use xdg-open. We poll last-url.txt (written by HttpServer.ps1
# once the listener binds) and hand the URL to xdg-open. No DuneShell, no
# WebView2 — the user's default browser is the UI surface.
$browserJob = $null
if ($script:DuneOpenBrowser) {
    $browserJob = Start-Job -ScriptBlock {
        param($urlFile)
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $urlFile) {
                try {
                    $url = (Get-Content -LiteralPath $urlFile -Raw).Trim()
                    if ($url) {
                        $opener = $null
                        foreach ($cmd in @('xdg-open', 'gio', 'wslview', 'open')) {
                            $resolved = Get-Command $cmd -ErrorAction SilentlyContinue
                            if ($resolved) { $opener = $resolved.Source; break }
                        }
                        if ($opener) {
                            Start-Process -FilePath $opener -ArgumentList $url -ErrorAction SilentlyContinue
                        } else {
                            Write-Host "No browser opener found. Visit: $url" -ForegroundColor Yellow
                        }
                    }
                } catch {}
                return
            }
            Start-Sleep -Milliseconds 250
        }
    } -ArgumentList $urlFilePath
}

# ---------- Start the listener (blocking) -------------------------------------
Write-DuneStartupLog 'Handing off to Start-DuneHttpServer'
Write-DuneLog "Dune Server (Linux) v$script:DuneToolVersion starting"
Write-DuneLog "Serving from: $script:DistRoot"
Write-DuneLog "Headless: $script:DuneHeadlessMode  OpenBrowser: $script:DuneOpenBrowser  PreferredPort: $script:DunePreferredPort"

try {
    Start-DuneHttpServer -DistRoot $script:DistRoot -PreferredPort $script:DunePreferredPort -Token $script:LaunchToken
} finally {
    if ($browserJob) {
        try { Stop-Job -Job $browserJob -ErrorAction SilentlyContinue } catch {}
        try { Remove-Job -Job $browserJob -ErrorAction SilentlyContinue } catch {}
    }
    Write-DuneLog 'Dune Server (Linux) exited'
}
