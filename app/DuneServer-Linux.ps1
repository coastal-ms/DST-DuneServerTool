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
    # NB: do NOT use $home here — it's a read-only automatic variable, and
    # assigning to it under $ErrorActionPreference='Stop' is a terminating error
    # that crashes the bootstrap before the logger is even defined.
    $userHome = $env:HOME
    if (-not $userHome) { $userHome = [System.Environment]::GetFolderPath('UserProfile') }
    if (-not $userHome) {
        Write-Host 'Cannot determine $HOME on this host.' -ForegroundColor Red
        exit 1
    }

    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $userHome '.config' }
    $stateHome  = if ($env:XDG_STATE_HOME)  { $env:XDG_STATE_HOME }  else { Join-Path $userHome '.local/state' }
    $cacheHome  = if ($env:XDG_CACHE_HOME)  { $env:XDG_CACHE_HOME }  else { Join-Path $userHome '.cache' }

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
    if (-not $env:USERPROFILE) { $env:USERPROFILE = $userHome }
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
$script:DuneToolVersion = '12.8.2'

# ---------- Load server + routes ----------------------------------------------
$duneLogFile = Join-Path $serverDir 'lib/DuneLog.ps1'
if (Test-Path -LiteralPath $duneLogFile) { . $duneLogFile }

# Platform predicates — available before the lib loop (re-loaded there too).
$dunePlatformFile = Join-Path $serverDir 'lib/Platform.ps1'
if (Test-Path -LiteralPath $dunePlatformFile) { . $dunePlatformFile }

$script:DuneLogFilePath = Join-Path $env:LOCALAPPDATA 'DuneServer/dune-server.log'
Initialize-DuneLog -Path $script:DuneLogFilePath

. (Join-Path $serverDir 'HttpServer.ps1')

# HttpServer.ps1 initializes $script:DuneServerDir = $null at load, which clobbers
# the assignment above. Re-set it so the API handler pool (Initialize-DuneApiPool)
# can find the server dir instead of falling back to single-threaded inline dispatch.
$script:DuneServerDir = $serverDir

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

# ---------- UI surface: native GTK shell, else browser ------------------------
# Preferred: the native desktop shell (app/desktop/linux/dune-shell.py — GTK3 +
# WebKit2GTK), the Linux counterpart to DuneShell.exe. It polls last-url.txt
# itself and renders the portal in its own window. Falls back to xdg-open (a
# normal browser tab) when the shell, python3, or the GTK/WebKit GIR bindings
# aren't present, or when OpenInAppWindow=false in config.
$script:DuneShellLaunched = $false

function Test-DuneGtkShellDeps {
    param([string]$Python)
    if (-not $Python) { return $false }
    try {
        & $Python -c "import gi; gi.require_version('Gtk','3.0'); gi.require_version('WebKit2','4.1')" 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

if ($script:DuneOpenBrowser) {
    $openInApp = $true
    try { if (Get-Command Get-DstOpenInAppWindow -ErrorAction SilentlyContinue) { $openInApp = [bool](Get-DstOpenInAppWindow) } } catch {}
    $hasDisplay = [bool]($env:DISPLAY -or $env:WAYLAND_DISPLAY)
    $shellScript = Find-DuneSubpath 'app/desktop/linux/dune-shell.py'
    $python = (Get-Command python3 -ErrorAction SilentlyContinue).Source
    if ($openInApp -and $hasDisplay -and $shellScript -and (Test-DuneGtkShellDeps -Python $python)) {
        try {
            # Detached: the shell is a sibling UI process; it polls last-url.txt
            # and asks the backend to shut down (POST /api/shutdown) on close.
            Start-Process -FilePath $python -ArgumentList @($shellScript) -ErrorAction Stop | Out-Null
            $script:DuneShellLaunched = $true
            Write-DuneLog "Opening portal in native GTK shell: $shellScript"
        } catch {
            Write-DuneLog "GTK shell failed to launch ($($_.Exception.Message)); falling back to browser" 'WARN'
        }
    }
}

# ---------- Browser opener (async, after listener binds) ----------------------
# Fallback when the native shell wasn't launched: poll last-url.txt (written by
# HttpServer.ps1 once the listener binds) and hand the URL to xdg-open.
$browserJob = $null
if ($script:DuneOpenBrowser -and -not $script:DuneShellLaunched) {
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
