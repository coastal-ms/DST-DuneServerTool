# Dune Server — entry point (v6.1 web portal)
#
# Bootstrap: pick a free port, start HttpListener, open default browser at the
# tokened localhost URL. The full UI is the React SPA in webui/dist/.

$ErrorActionPreference = 'Stop'

# Version (one of the 5 sync'd constants; see persistent-notes.md)
$script:DuneToolVersion = '6.1.3'

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
                -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$selfPath`"") `
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

# ---------- Browser launch -----------------------------------------------------

function Open-DuneInBrowser {
    param([string]$Url)
    try {
        Start-Process $Url | Out-Null
    } catch {
        Write-Host "Could not open browser automatically. Visit: $Url" -ForegroundColor Yellow
    }
}

# ---------- Start --------------------------------------------------------------

Write-DuneLog "Dune Server v$script:DuneToolVersion starting"
Write-DuneLog "Serving from: $script:DistRoot"

# Shared state hashtable used by the tray icon runspace.
$script:DuneTrayState = [hashtable]::Synchronized(@{
    Url           = ''
    LogPath       = $script:DuneLogFilePath
    QuitRequested = $false
    Listener      = $null
    Version       = $script:DuneToolVersion
    TrayReady     = $false
})

# Start tray icon (NotifyIcon runs on its own STA runspace + message loop).
$iconPath = Find-DuneSubpath 'app\assets\icon.ico'
if (-not $iconPath) { $iconPath = Find-DuneSubpath 'assets\icon.ico' }
if ($iconPath) {
    Start-DuneTrayIcon -State $script:DuneTrayState -IconPath $iconPath -Version $script:DuneToolVersion
    Write-DuneLog "Tray icon initialized ($iconPath)"
} else {
    Write-DuneLog "Tray icon disabled - icon.ico not found" 'WARN'
}

# Kick the browser open after the listener binds. Reads last-url.txt that
# Start-DuneHttpServer writes once it knows the actual bound port.
$browserJob = Start-Job -ScriptBlock {
    $urlFile = Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'
    for ($i = 0; $i -lt 50; $i++) {
        if (Test-Path -LiteralPath $urlFile) {
            $u = (Get-Content -LiteralPath $urlFile -Raw).Trim()
            if ($u) { Start-Process $u; return }
        }
        Start-Sleep -Milliseconds 200
    }
}

# Side-thread to publish the URL and listener to the tray state once bound.
$urlPublishJob = Start-Job -ArgumentList $script:DuneTrayState -ScriptBlock {
    param($state)
    $urlFile = Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'
    for ($i = 0; $i -lt 100; $i++) {
        if (Test-Path -LiteralPath $urlFile) {
            $u = (Get-Content -LiteralPath $urlFile -Raw).Trim()
            if ($u) { $state.Url = $u; return }
        }
        Start-Sleep -Milliseconds 200
    }
}

try {
    Start-DuneHttpServer -DistRoot $script:DistRoot -PreferredPort 47823 -Token $script:LaunchToken -TrayState $script:DuneTrayState
} catch {
    Write-DuneLog "HTTP server failed: $($_.Exception.Message)" 'ERROR'
    Show-DuneMessage "Dune Server failed to start: $($_.Exception.Message)" 'Dune Server' 'Error'
} finally {
    if ($browserJob)    { Remove-Job -Job $browserJob    -Force -ErrorAction SilentlyContinue }
    if ($urlPublishJob) { Remove-Job -Job $urlPublishJob -Force -ErrorAction SilentlyContinue }
    Stop-DuneHttpServer
    if (Get-Command Stop-DuneTrayIcon -ErrorAction SilentlyContinue) {
        Stop-DuneTrayIcon -State $script:DuneTrayState
    }
    Write-DuneLog "Dune Server stopped"
}
