# Dune Server — entry point (v6.1 web portal)
#
# Bootstrap: pick a free port, start HttpListener, open default browser at the
# tokened localhost URL. The full UI is the React SPA in webui/dist/.

$ErrorActionPreference = 'Stop'

# ---------- v6.1.24: Process-scope ExecutionPolicy + emergency crash log -------
# Windows defaults non-server SKUs to ExecutionPolicy=Restricted, which blocks
# dot-sourcing our bundled (unsigned) .ps1 files. The launcher would die on the
# very first `. DuneLog.ps1` BEFORE Initialize-DuneLog could open a log file,
# producing the infamous "window opens and closes, no log, no popup" symptom.
#
# Force Bypass for THIS process only (no admin needed, no machine state change)
# so subsequent dot-sources always succeed regardless of machine policy.
try {
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
} catch {
    # Worst case: if even Set-ExecutionPolicy is blocked (group-policy lockdown)
    # we will surface a clear error via the emergency log below instead of
    # dying silently.
}

# Emergency crash log — writes to %LOCALAPPDATA%\DuneServer\dune-startup.log
# BEFORE we know whether the normal logger will load. Any exception in the
# bootstrap is appended here so users always have something to send us.
$script:DuneStartupLog = $null
try {
    $stateDir = Join-Path $env:LOCALAPPDATA 'DuneServer'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    $script:DuneStartupLog = Join-Path $stateDir 'dune-startup.log'
    $hdr = "==== $(Get-Date -Format 's')  DuneServer startup, pid=$PID, host=$($PSVersionTable.PSVersion), policy=$(Get-ExecutionPolicy -Scope Process) ===="
    Add-Content -LiteralPath $script:DuneStartupLog -Value $hdr -Encoding UTF8
} catch { }

function Write-DuneStartupLog {
    param([string]$Message)
    if (-not $script:DuneStartupLog) { return }
    try {
        Add-Content -LiteralPath $script:DuneStartupLog -Value "[$(Get-Date -Format 'HH:mm:ss')] $Message" -Encoding UTF8
    } catch { }
}

# Catch-all trap: any uncaught exception during bootstrap lands here, logs the
# full stack, AND shows a MessageBox so the user is never left wondering why
# the window opened and closed.
trap {
    $err = $_
    $msg = "Dune Server bootstrap failed.`r`n`r`n$($err.Exception.Message)`r`n`r`nFull error:`r`n$($err | Out-String)"
    Write-DuneStartupLog "BOOTSTRAP CRASH: $($err.Exception.Message)"
    Write-DuneStartupLog ($err | Out-String)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            $msg + "`r`n`r`nDetails written to:`r`n$script:DuneStartupLog",
            'Dune Server — startup failed', 'OK', 'Error') | Out-Null
    } catch {
        Write-Host $msg -ForegroundColor Red
    }
    exit 1
}

Write-DuneStartupLog 'Bootstrap entered'

# ---------- Minimize own console window IMMEDIATELY ----------------------------
# v6.1.7+: the EXE is built console-subsystem (NoConsole=$false in Build-Exe.ps1)
# so that child kubectl/ssh/git processes inherit a console and Windows doesn't
# allocate a flashy new console window for each one (the "popup window flash"
# users saw on every dashboard refresh in v6.1.2-v6.1.6). We don't actually
# want the console visible, so minimize it as the very first action.
#
# Detection rule: process name is the compiled EXE name (e.g. "DuneServer")
# when launched as the ps2exe build. When the script runs as plain .ps1
# inside an existing pwsh/powershell session, the process name is
# "pwsh" / "powershell" — leave that console alone (it's Neil's working shell).
#
# v6.1.7 hotfix: the previous `GetConsoleProcessList(count==1)` guard turned
# out to skip the minimize whenever the installer / auto-updater that
# launched the EXE was still attached to the same console at startup
# (count > 1), leaving the window full-size. Process-name detection is
# reliable in all those cases.
$script:DuneIsCompiledExe = $false
try {
    $procName = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName
    if ($procName -and $procName -notmatch '^(pwsh|powershell|powershell_ise)$') {
        $script:DuneIsCompiledExe = $true
    }
} catch { }

if ($script:DuneIsCompiledExe) {
    try {
        Add-Type -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsIconic(System.IntPtr hWnd);
'@ -Name 'DuneNativeWin' -Namespace 'DuneServer' -ErrorAction Stop

        # Retry loop: console may not be attached on the very first tick after
        # process start (especially when launched by Inno Setup's [Run] step
        # or by the in-app updater). Try for up to ~2s; bail as soon as we
        # see the window is iconic.
        $deadline = (Get-Date).AddSeconds(2)
        while ((Get-Date) -lt $deadline) {
            $hwnd = [DuneServer.DuneNativeWin]::GetConsoleWindow()
            if ($hwnd -ne [System.IntPtr]::Zero) {
                [void][DuneServer.DuneNativeWin]::ShowWindow($hwnd, 7)   # SW_SHOWMINNOACTIVE
                Start-Sleep -Milliseconds 50
                if ([DuneServer.DuneNativeWin]::IsIconic($hwnd)) { break }
            }
            Start-Sleep -Milliseconds 100
        }
    } catch {
        # Non-fatal: console just stays at normal size if Win32 isn't available.
    }
}

# Version (one of the 5 sync'd constants; see persistent-notes.md)
$script:DuneToolVersion = '10.0.5'

# ---------- Single-instance gate ----------------------------------------------
# Every click of the desktop shortcut runs DuneServer.exe again. Without a
# gate this spawns N independent servers (each on a fresh port), N tray icons,
# and N UAC prompts. Acquire a named mutex; if it's already held, just open
# the existing portal URL in the user's browser and exit — no elevation, no
# duplicate listener, no second tray icon.
$script:SingleInstanceMutex = $null
$script:SingleInstanceOwned = $false
try {
    $created = $false
    $script:SingleInstanceMutex = New-Object System.Threading.Mutex($true, 'Global\DuneServer-Portal-v6', [ref]$created)
    $script:SingleInstanceOwned = [bool]$created
} catch {
    # If the named mutex can't be created (locked-down session, etc.),
    # fall through and let the rest of startup decide.
    $script:SingleInstanceOwned = $true
}
if (-not $script:SingleInstanceOwned) {
    # Another instance is already running. Open its portal URL and exit.
    try {
        $urlFile = Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'
        if (Test-Path -LiteralPath $urlFile) {
            $u = (Get-Content -LiteralPath $urlFile -Raw).Trim()
            if ($u) { Start-Process $u | Out-Null }
        }
    } catch { }
    exit 0
}

# ---------- Self-elevate -------------------------------------------------------
# Hyper-V cmdlets (Get-VM etc.) require admin or Hyper-V Administrators group.
# We elevate in-script (rather than via a ps2exe -requireAdmin manifest) so the
# single-instance check above runs FIRST and subsequent shortcut clicks open
# the browser without a UAC prompt.
function Test-DuneIsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
function Show-DuneMessage {
    param([string]$Text, [string]$Title = 'Dune Server', [string]$Icon = 'Information')
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', $Icon) | Out-Null
    } catch {
        Write-Host $Text -ForegroundColor Yellow
    }
}
if (-not (Test-DuneIsAdmin)) {
    # Release the mutex BEFORE the elevated child starts, so the child can
    # acquire it. Without this the child would see "already running" and exit.
    try {
        if ($script:SingleInstanceMutex) {
            $script:SingleInstanceMutex.ReleaseMutex()
            $script:SingleInstanceMutex.Dispose()
            $script:SingleInstanceMutex = $null
            $script:SingleInstanceOwned = $false
        }
    } catch { }

    $exePath = $null
    try { $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    try {
        if ($exePath -and ($exePath -like '*.exe') -and ($exePath -notlike '*pwsh.exe') -and ($exePath -notlike '*powershell.exe')) {
            # We're the compiled EXE - relaunch ourselves (no visible console)
            Start-Process -FilePath $exePath -Verb RunAs | Out-Null
        } else {
            $selfPath = $PSCommandPath
            if (-not $selfPath) { $selfPath = $exePath }
            $launcher = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
            if (-not $launcher) { $launcher = 'powershell.exe' }
            Start-Process -FilePath $launcher `
                -ArgumentList @('-NoProfile','-WindowStyle','Minimized','-ExecutionPolicy','Bypass','-File',"`"$selfPath`"") `
                -Verb RunAs | Out-Null
        }
    } catch {
        Show-DuneMessage 'Dune Server needs administrator privileges to query Hyper-V VMs. Elevation was cancelled.' 'Dune Server' 'Warning'
    }
    exit 0
}

# ---------- Path resolution (works for ps2exe and plain pwsh) ------------------

if ($PSScriptRoot) {
    $script:AppDir = $PSScriptRoot
} elseif ($PSCommandPath) {
    $script:AppDir = Split-Path -Parent $PSCommandPath
} else {
    # ps2exe: $PSScriptRoot and $PSCommandPath are both $null
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $script:AppDir = Split-Path -Parent $exePath
}

# Repo layout — when running from source:
#   <repo>/app/DuneServer.ps1       (this file)
#   <repo>/webui/dist/              (built SPA)
# When installed:
#   C:\Program Files\Dune Server\DuneServer.exe
#   C:\Program Files\Dune Server\app\server\*
#   C:\Program Files\Dune Server\webui\dist\*
$script:RepoRoot = Split-Path -Parent $script:AppDir

# Walk upward from $AppDir looking for $Sub (a file or folder relative path).
# Handles three layouts:
#   installed:  C:\Program Files\Dune Server\DuneServer.exe + sibling subpath
#   source:     <repo>\app\DuneServer.ps1                   + sibling/parent subpath
#   built EXE:  <repo>\app\build\output\DuneServer.exe      + ancestor subpath
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

$script:DistRoot = Find-DuneSubpath 'webui\dist'
if (-not $script:DistRoot) {
    Show-DuneMessage "Could not locate webui\dist (searched upward from '$script:AppDir')." 'Dune Server' 'Error'
    exit 1
}

# ---------- Resolve pwsh.exe + dune-server.ps1 (for launching commands) -------

$script:PwshExe = $null
try {
    $script:PwshExe = (Get-Command pwsh.exe -ErrorAction Stop).Source
} catch {
    foreach ($p in @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe",
        "$env:LOCALAPPDATA\Microsoft\PowerShell\7\pwsh.exe"
    )) { if (Test-Path $p) { $script:PwshExe = $p; break } }
}
if (-not $script:PwshExe) {
    Show-DuneMessage 'pwsh.exe (PowerShell 7) not found. Install from https://aka.ms/PowerShell-Release' 'Dune Server' 'Error'
    exit 1
}

# dune-server.ps1 — the CLI script with the actual command implementations.
# Installed: <install-root>\dune-server.ps1     (sibling of DuneServer.exe)
# Source:    <repo-root>\dune-server.ps1        (two levels up from app\server\)
$script:MainScript = Find-DuneSubpath 'dune-server.ps1'
if (-not $script:MainScript) {
    Write-Host "WARNING: dune-server.ps1 not found near '$script:AppDir'. Command execution will fail." -ForegroundColor Yellow
}

# ---------- Load server + routes -----------------------------------------------

$serverDir = Find-DuneSubpath 'server'
if (-not $serverDir) {
    Show-DuneMessage "Could not locate server\ (HttpServer.ps1 + routes) near '$script:AppDir'." 'Dune Server' 'Error'
    exit 1
}

# Load DuneLog first so subsequent loaders + HttpServer can use Write-DuneLog
$duneLogFile = Join-Path $serverDir 'lib\DuneLog.ps1'
if (Test-Path -LiteralPath $duneLogFile) { . $duneLogFile }

$script:DuneLogFilePath = Join-Path $env:LOCALAPPDATA 'DuneServer\dune-server.log'
Initialize-DuneLog -Path $script:DuneLogFilePath

. (Join-Path $serverDir 'HttpServer.ps1')

# Web-portal lib modules (Config, Status, Ports, Characters, etc.)
$libDir = Join-Path $serverDir 'lib'
if (Test-Path $libDir) {
    Get-ChildItem -Path $libDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

# Auto-load all route files
$routesDir = Join-Path $serverDir 'routes'
if (Test-Path $routesDir) {
    Get-ChildItem -Path $routesDir -Filter '*.ps1' | ForEach-Object { . $_.FullName }
}

# ---------- Token --------------------------------------------------------------

$script:LaunchToken = [Guid]::NewGuid().ToString('N')

# ---------- Browser / app-window launch ---------------------------------------

# Open the portal in the user's default browser as a normal tab. We intentionally
# do NOT use Chromium app-mode (--app): app windows looked like a separate "app"
# popping up, and without an isolated profile they still couldn't be closed
# reliably. Normal tabs are familiar; the updater handles the stale tab by
# redirecting it to a clean "update installed - safe to close" page instead.
function Open-DuneInBrowser {
    param([string]$Url)
    try {
        Start-Process $Url | Out-Null
    } catch {
        Write-Host "Could not open browser automatically. Visit: $Url" -ForegroundColor Yellow
    }
}

# Locate the standalone DuneShell.exe (WebView2 app window). Installed layout
# ships it beside DuneServer.exe; dev/build layouts leave it under the project's
# bin output. Returns $null when it isn't present (e.g. dev box without a build).
function Get-DuneShellExePath {
    $candidate = Find-DuneSubpath 'DuneShell.exe'
    if ($candidate) { return $candidate }
    $devPaths = @(
        'app\desktop\DuneShell\bin\Release\net10.0-windows\win-x64\DuneShell.exe',
        'app\desktop\DuneShell\bin\Debug\net10.0-windows\win-x64\DuneShell.exe',
        'desktop\DuneShell\bin\Release\net10.0-windows\win-x64\DuneShell.exe'
    )
    foreach ($rel in $devPaths) {
        $p = Find-DuneSubpath $rel
        if ($p) { return $p }
    }
    return $null
}

# ---------- Start --------------------------------------------------------------

Write-DuneStartupLog "Bootstrap complete, handing off to Start-DuneHttpServer"
Write-DuneLog "Dune Server v$script:DuneToolVersion starting"
Write-DuneLog "Serving from: $script:DistRoot"

# Delete any stale last-url.txt from a previous run BEFORE starting the
# polling jobs. Otherwise the browserJob's first poll wins the race against
# Start-DuneHttpServer's write, opens the browser at the OLD url with the
# OLD token, and every /api call returns 401 "Invalid or missing token".
$urlFilePath = Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'
try {
    if (Test-Path -LiteralPath $urlFilePath) {
        Remove-Item -LiteralPath $urlFilePath -Force -ErrorAction Stop
    }
} catch {
    Write-DuneLog "Could not remove stale last-url.txt: $($_.Exception.Message)" 'WARN'
}

# Kick the portal open after the listener binds. Two paths:
#   * App window (default): launch DuneShell.exe, which polls last-url.txt itself
#     and renders the portal in a standalone WebView2 window with a native menu.
#   * Browser fallback: when the app window is disabled (OpenInAppWindow=false in
#     dune-server.config) or DuneShell.exe isn't present, poll last-url.txt here
#     and open the portal as a normal tab in the user's default browser.
$script:DuneShellExe = $null
$openInAppWindow = $false
try { $openInAppWindow = Get-DstOpenInAppWindow } catch { $openInAppWindow = $true }
if ($openInAppWindow) { $script:DuneShellExe = Get-DuneShellExePath }

$browserJob = $null
if ($openInAppWindow -and $script:DuneShellExe) {
    Write-DuneLog "Opening portal in app window: $script:DuneShellExe"
    try {
        Start-Process -FilePath $script:DuneShellExe | Out-Null
    } catch {
        Write-DuneLog "App window failed to launch ($($_.Exception.Message)); falling back to browser" 'WARN'
        $script:DuneShellExe = $null
    }
}

if (-not ($openInAppWindow -and $script:DuneShellExe)) {
    $browserJob = Start-Job -ArgumentList $urlFilePath -ScriptBlock {
        param($urlFile)
        for ($i = 0; $i -lt 50; $i++) {
            if (Test-Path -LiteralPath $urlFile) {
                $u = (Get-Content -LiteralPath $urlFile -Raw).Trim()
                if ($u) {
                    Start-Process $u
                    return
                }
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

try {
    Start-DuneHttpServer -DistRoot $script:DistRoot -PreferredPort 47823 -Token $script:LaunchToken
} catch {
    Write-DuneLog "HTTP server failed: $($_.Exception.Message)" 'ERROR'
    Show-DuneMessage "Dune Server failed to start: $($_.Exception.Message)" 'Dune Server' 'Error'
} finally {
    if ($browserJob) { Remove-Job -Job $browserJob -Force -ErrorAction SilentlyContinue }
    Stop-DuneHttpServer
    # Wipe last-url.txt so the next launch can't race-read a stale URL with
    # a token that no longer matches a running listener.
    try {
        $urlFile = Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'
        if (Test-Path -LiteralPath $urlFile) {
            Remove-Item -LiteralPath $urlFile -Force -ErrorAction SilentlyContinue
        }
    } catch { }
    # Release the single-instance mutex explicitly so the next click of the
    # desktop shortcut can acquire it immediately (rather than relying on
    # OS process-exit cleanup, which is racy under fast reopen).
    try {
        if ($script:SingleInstanceMutex) {
            if ($script:SingleInstanceOwned) {
                try { $script:SingleInstanceMutex.ReleaseMutex() } catch { }
            }
            $script:SingleInstanceMutex.Dispose()
            $script:SingleInstanceMutex = $null
        }
    } catch { }
    Write-DuneLog "Dune Server stopped"
}
