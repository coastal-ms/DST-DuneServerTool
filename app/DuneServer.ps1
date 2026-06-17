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

# ---------- Headless mode (--headless) ----------------------------------------
# When launched by the scheduled task that backs the Help → "Run at Windows
# startup" toggle, we boot WITHOUT the DuneShell app window so the user isn't
# greeted at login by an unexpected window. The console is force-sent to the
# system tray (regardless of the saved ConsolePresence choice) so the operator
# always has SOME visible handle on the running server.
#
# Detection: scan the full process command line for --headless / -headless /
# /headless (case-insensitive). PS2EXE-compiled binaries expose CLI args via
# [Environment]::GetCommandLineArgs() reliably, including double-dash options.
$script:DuneHeadlessMode = $false
try {
    $rawArgs = @([Environment]::GetCommandLineArgs())
    foreach ($a in $rawArgs) {
        if (-not $a) { continue }
        if ($a -match '^(?:--|-|/)headless$') { $script:DuneHeadlessMode = $true; break }
    }
} catch {}
if ($script:DuneHeadlessMode) {
    Write-DuneStartupLog 'Headless mode requested (--headless): no DuneShell window will be opened by this process'
}

# Build the arg-list we need to forward through any in-script self-elevation
# (the "we need admin, relaunch ourselves with -Verb RunAs" branch) so that
# the elevated child stays in headless mode. Used in two places below.
$script:DuneRelaunchArgs = @()
if ($script:DuneHeadlessMode) { $script:DuneRelaunchArgs += '--headless' }

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
# "pwsh" / "powershell" — leave that console alone (it's the user's working shell).
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
$script:DuneToolVersion = '12.5.5'

# ---------- Restart-on-detach handoff -----------------------------------------
# When a prior "Web Portal" detach left the server running headless, the
# non-elevated second-instance branch wrote restart-requested.flag and
# elevated us. At this point we ARE the elevated child — we must stop the
# prior elevated DuneServer.exe (which still holds the single-instance mutex
# and is bound to port 47823) before our own mutex acquisition runs.
#
# We only act on the marker briefly after it was written, so a stale flag
# from a crash can't poison normal launches.
try {
    $restartMarker = Join-Path $env:LOCALAPPDATA 'DuneServer\restart-requested.flag'
    if (Test-Path -LiteralPath $restartMarker) {
        $stale  = $true
        $reqPid = 0
        try {
            $j = Get-Content -LiteralPath $restartMarker -Raw | ConvertFrom-Json
            $age = (Get-Date) - ([DateTime]$j.requestedAt)
            if ($age.TotalSeconds -lt 30) { $stale = $false }
            if ($j.requestedByPid) { $reqPid = [int]$j.requestedByPid }
        } catch { $stale = $true }

        if (-not $stale) {
            $self = $PID
            try {
                Get-Process -Name 'DuneServer' -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.Id -ne $self -and $_.Id -ne $reqPid) {
                        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
                    }
                }
            } catch { }
            # Wait for the listener port to free up + the prior mutex to be
            # released. Cheap polling; bail out after ~5s either way.
            $deadline = (Get-Date).AddSeconds(5)
            while ((Get-Date) -lt $deadline) {
                $alive = @(Get-Process -Name 'DuneServer' -ErrorAction SilentlyContinue |
                           Where-Object { $_.Id -ne $self -and $_.Id -ne $reqPid })
                if ($alive.Count -eq 0) { break }
                Start-Sleep -Milliseconds 200
            }
            # Also clear the detach marker — the prior server may have died
            # before its own Stop-DuneConsoleLifecycle ran.
            try {
                $detFlag = Join-Path $env:LOCALAPPDATA 'DuneServer\detached.flag'
                if (Test-Path -LiteralPath $detFlag) {
                    Remove-Item -LiteralPath $detFlag -Force -ErrorAction SilentlyContinue
                }
            } catch { }
            Write-DuneStartupLog "Restart-on-detach: stopped prior DuneServer processes, proceeding with fresh startup"
        }

        try { Remove-Item -LiteralPath $restartMarker -Force -ErrorAction SilentlyContinue } catch { }
    }
} catch {
    Write-DuneStartupLog "Restart-on-detach handler failed: $($_.Exception.Message)"
}

# ---------- Health probe for an already-running instance ----------------------
# A prior DuneServer can keep its process (and the single-instance mutex) alive
# while its HttpListener has silently stopped accepting - observed after a
# sleep/resume cycle, a network-stack reset, or http.sys dropping the URL
# registration. The log then shows the process still running but nothing bound
# to the port. Without a liveness check, every subsequent shortcut click just
# re-attaches the viewer to that dead backend, stranding the user forever on
# "Connecting to Dune Server Tool... (attempt N)".
#
# Probe the recorded portal URL: ANY HTTP-level response (200/302/401/404)
# proves the listener is accepting; a connection failure / timeout means it's a
# zombie. Used by the already-running branch below to decide focus-vs-restart.
function Test-DuneExistingServerHealthy {
    param([int]$TimeoutMs = 1500, [int]$Attempts = 3)
    $urlFile = Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'
    $u = ''
    try { if (Test-Path -LiteralPath $urlFile) { $u = (Get-Content -LiteralPath $urlFile -Raw).Trim() } } catch {}
    # No recorded URL -> there is no running server we can confirm is serving.
    if (-not $u) { return $false }
    $probe = $u
    try { $uri = [Uri]$u; $probe = "$($uri.Scheme)://$($uri.Authority)/" } catch {}
    for ($i = 0; $i -lt $Attempts; $i++) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($probe)
            $req.Timeout          = $TimeoutMs
            $req.Method           = 'GET'
            $req.AllowAutoRedirect = $false
            $resp = $req.GetResponse()
            try { $resp.Close() } catch {}
            return $true
        } catch [System.Net.WebException] {
            # A protocol error still carries an HTTP response => listener alive.
            if ($_.Exception.Response) { return $true }
            # ConnectFailure / Timeout / NameResolutionFailure => not serving.
        } catch {}
        Start-Sleep -Milliseconds 250
    }
    return $false
}

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
    # Headless second-instance is always a no-op: another DuneServer is already
    # running; we have no UI to surface (the user didn't click anything, the
    # logon trigger just fired again somehow) and we MUST NOT trip the
    # detached-restart branch below or we'd kill the running server during
    # routine logon. Just exit.
    if ($script:DuneHeadlessMode) {
        Write-DuneStartupLog 'Headless second-instance: another DuneServer is already running, exiting cleanly'
        try {
            if ($script:SingleInstanceMutex) {
                $script:SingleInstanceMutex.Dispose()
                $script:SingleInstanceMutex = $null
            }
        } catch {}
        exit 0
    }

    # Another instance is already running. Two scenarios:
    #
    #   * App window still alive (normal case): just surface the existing
    #     portal — focus the DuneShell window when enabled (default; DuneShell
    #     is itself single-instance, so this just focuses it), or reopen the
    #     URL in the browser otherwise.
    #
    #   * No DuneShell alive (= a prior "Web Portal" detach left the server
    #     running headless): the user clicked the shortcut to bring the app
    #     window back. Treat this as kill-and-restart — drop a flag, then
    #     elevate ourselves so the elevated child can Stop-Process the prior
    #     (also-elevated) DuneServer.exe and proceed with a normal first-
    #     instance startup (fresh listener, fresh token, fresh DuneShell).
    try {
        $detachedFlag = Join-Path $env:LOCALAPPDATA 'DuneServer\detached.flag'
        $isDetached   = $false
        try { $isDetached = (Test-Path -LiteralPath $detachedFlag) } catch {}

        # Detached state is only "real" while the prior server is actually up;
        # a stale flag from a crash shouldn't trigger a restart loop. Probe by
        # listing DuneShell.exe procs — a true detached console has none.
        $shellAlive = $false
        try {
            $shellAlive = @(Get-Process -Name 'DuneShell' -ErrorAction SilentlyContinue).Count -gt 0
        } catch { $shellAlive = $false }

        # Zombie guard: confirm the already-running instance is actually serving
        # HTTP. If it isn't (listener died but the process - typically a headless
        # keep-alive backend - lingers holding the mutex), adopting its portal
        # URL would strand the viewer on "Connecting..." forever. Treat a
        # non-responding backend exactly like a stale "Web Portal" detach: kill
        # it and start fresh, regardless of which flag (if any) was set.
        $serverHealthy = Test-DuneExistingServerHealthy
        if (-not $serverHealthy) {
            Write-DuneStartupLog 'Already-running instance is not serving HTTP (zombie listener) - forcing kill-and-restart'
        }

        if ((-not $serverHealthy) -or ($isDetached -and -not $shellAlive)) {
            # Tag the flag with our PID so the elevated child knows WHICH
            # DuneServer.exe to kill (everyone-named-DuneServer-except-self
            # is risky if the user has unrelated processes - though "DuneServer"
            # is specific enough that in practice we'd be fine).
            try {
                $marker = Join-Path $env:LOCALAPPDATA 'DuneServer\restart-requested.flag'
                $payload = @{
                    requestedAt    = (Get-Date).ToString('o')
                    requestedByPid = $PID
                } | ConvertTo-Json -Compress
                $markerDir = Split-Path -Parent $marker
                if (-not (Test-Path -LiteralPath $markerDir)) {
                    New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
                }
                Set-Content -LiteralPath $marker -Value $payload -Encoding UTF8 -Force
            } catch { }

            # Release the mutex BEFORE the elevated child starts, so the child
            # can acquire it after killing the prior detached server.
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
            } catch { }
            exit 0
        }

        # Normal "already running" path — surface the existing portal.
        $urlFile = Join-Path $env:LOCALAPPDATA 'DuneServer\last-url.txt'
        $u = if (Test-Path -LiteralPath $urlFile) { (Get-Content -LiteralPath $urlFile -Raw).Trim() } else { '' }

        $useApp = $true
        try {
            $cfgFile = Join-Path $env:APPDATA 'DuneServer\dune-server.config'
            if (Test-Path -LiteralPath $cfgFile) {
                $line = Get-Content -LiteralPath $cfgFile |
                        Where-Object { $_ -match '^\s*OpenInAppWindow\s*=' } | Select-Object -Last 1
                if ($line -and (($line -replace '^\s*OpenInAppWindow\s*=\s*','').Trim() -match '^(false|0|no|off)$')) {
                    $useApp = $false
                }
            }
        } catch { }

        $shellExe = $null
        if ($useApp) {
            try {
                $selfExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                if ($selfExe) {
                    $cand = Join-Path (Split-Path -Parent $selfExe) 'DuneShell.exe'
                    if (Test-Path -LiteralPath $cand) { $shellExe = $cand }
                }
            } catch { }
        }

        if ($shellExe) {
            Start-Process -FilePath $shellExe | Out-Null
        } elseif ($u) {
            Start-Process $u | Out-Null
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
            # We're the compiled EXE - relaunch ourselves (no visible console).
            # Forward --headless so the scheduled-task launch path stays headless
            # across the in-script self-elevation hop.
            if ($script:DuneRelaunchArgs -and $script:DuneRelaunchArgs.Count -gt 0) {
                Start-Process -FilePath $exePath -ArgumentList $script:DuneRelaunchArgs -Verb RunAs | Out-Null
            } else {
                Start-Process -FilePath $exePath -Verb RunAs | Out-Null
            }
        } else {
            $selfPath = $PSCommandPath
            if (-not $selfPath) { $selfPath = $exePath }
            $launcher = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
            if (-not $launcher) { $launcher = 'powershell.exe' }
            $argList = @('-NoProfile','-WindowStyle','Minimized','-ExecutionPolicy','Bypass','-File',"`"$selfPath`"")
            if ($script:DuneRelaunchArgs -and $script:DuneRelaunchArgs.Count -gt 0) {
                $argList += $script:DuneRelaunchArgs
            }
            Start-Process -FilePath $launcher `
                -ArgumentList $argList `
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
# Remember the server dir so HttpServer.ps1 can build the API handler pool's
# startup dot-sources (lib/*.ps1 + routes/*.ps1) for worker runspaces.
$script:DuneServerDir = $serverDir

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

# Start the native Market Bot ("Duke") scheduler in its own background runspace.
# It only acts when the bot is enabled in gameplay-bot.json, so this is safe to
# always start; it idles otherwise.
if (Get-Command Start-DuneGameplayBotScheduler -ErrorAction SilentlyContinue) {
    try { [void](Start-DuneGameplayBotScheduler -ServerDir $serverDir) } catch {}
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
$script:DuneAppProc = $null
$script:DuneConsoleMode = 'console'
$script:DuneIconPath = $null

# Process-lifetime flag: when true, closing the (manually-opened) DuneShell
# does NOT stop the listener. Set unconditionally in headless mode; the
# autostart toggle's "next launch" semantic means we don't flip this mid-run.
# Process-lifetime flag: when true, closing the (manually-opened) DuneShell
# does NOT stop the listener -- the backend keeps running and the user can
# re-attach by clicking the shortcut (the single-instance branch above
# spawns a fresh DuneShell against the live backend instead of restarting).
#
# True in two cases:
#   * --headless launch (the scheduled-task autostart path): no app window
#     is even launched; the tray icon is the only handle on the backend.
#   * Autostart task currently registered for this user: even when DST is
#     launched manually (shortcut click, not the scheduled-task path), the
#     user has opted into "background service" semantics by enabling Help
#     -> Run at Windows startup. Closing the DuneShell viewer should NOT
#     take the backend console down with it.
#
# Evaluated at startup only. Toggling Help -> Run at Windows startup mid-run
# does not flip this flag; the new semantic takes effect on the next launch.
#
# ASCII-only on purpose: this file is BOM-less and PS2EXE compiles against
# Windows PowerShell 5.1, which reads BOM-less files as Windows-1252. Adding
# em-dashes or right-arrows here would risk the v11.4.0-class parse breakage
# the v11.4.1 hotfix addressed.
$script:DuneAutostartRegistered = $false
try {
    if (Get-Command Test-DuneAutostartEnabled -ErrorAction SilentlyContinue) {
        $script:DuneAutostartRegistered = [bool](Test-DuneAutostartEnabled)
    }
} catch { $script:DuneAutostartRegistered = $false }
$script:DuneKeepAliveAfterShellClose = [bool]$script:DuneHeadlessMode -or $script:DuneAutostartRegistered
if ($script:DuneAutostartRegistered -and -not $script:DuneHeadlessMode) {
    Write-DuneLog "Autostart task registered for this user - closing the DuneShell window will leave the backend console running; click the shortcut again to re-open the viewer, or stop the backend explicitly via the tray / console window"
}
# Sync the on-disk keep-alive sentinel so DuneShell's FormClosing teardown
# knows to skip its /api/shutdown + DuneServer.exe sweep
# when keep-alive is active. Refreshed at runtime by Register-/Unregister-
# DuneAutostart so toggling the Help menu takes effect without restart.
if (Get-Command Update-DuneKeepAliveFlag -ErrorAction SilentlyContinue) {
    try { [void](Update-DuneKeepAliveFlag) } catch {}
}

$openInAppWindow = $false
try { $openInAppWindow = Get-DstOpenInAppWindow } catch { $openInAppWindow = $true }

# Headless mode: no DuneShell launch, no browser fallback, no app-window watcher.
# We still want a tray icon (the operator's only handle on the running server),
# so resolve the icon and force tray presentation regardless of the saved
# ConsolePresence choice — a minimized-console-without-tray would be a UX dead
# end since there's no app window to keep the user oriented.
if ($script:DuneHeadlessMode) {
    try { $script:DuneIconPath = Find-DuneSubpath 'assets\icon.ico' } catch {}
    if (-not $script:DuneIconPath) {
        try {
            $selfExeIco = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($selfExeIco -and ($selfExeIco -like '*.exe')) { $script:DuneIconPath = $selfExeIco }
        } catch {}
    }
    $script:DuneConsoleMode = 'tray'
    Write-DuneLog "Headless mode: skipping DuneShell launch, forcing tray presentation (operator can re-open the UI from the tray or by clicking the shortcut)"
} else {
    if ($openInAppWindow) { $script:DuneShellExe = Get-DuneShellExePath }
}

$browserJob = $null
if ((-not $script:DuneHeadlessMode) -and $openInAppWindow -and $script:DuneShellExe) {
    # Close any stale app window from a previous run (e.g. left over by an
    # in-app update, where the relauncher restarts DuneServer.exe but the old
    # WebView2 window keeps pointing at the now-dead server). Killing it here
    # means a fresh launch always ends with exactly ONE app window.
    Get-Process -Name DuneShell -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
    }

    # Decide how the console should present itself while the app window is open
    # (prompts once per version). Resolve an icon for the optional tray.
    try { $script:DuneIconPath = Find-DuneSubpath 'assets\icon.ico' } catch {}
    if (-not $script:DuneIconPath) {
        try {
            $selfExeIco = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($selfExeIco -and ($selfExeIco -like '*.exe')) { $script:DuneIconPath = $selfExeIco }
        } catch {}
    }
    if (Get-Command Resolve-DuneConsoleMode -ErrorAction SilentlyContinue) {
        try { $script:DuneConsoleMode = Resolve-DuneConsoleMode } catch { $script:DuneConsoleMode = 'console' }
    }

    Write-DuneLog "Opening portal in app window: $script:DuneShellExe (console mode: $script:DuneConsoleMode)"
    try {
        # Capture the app-window process so the lifecycle watcher can stop the
        # server when it closes. DuneShell is single-instance: if one somehow
        # already exists, the process we spawn focuses it and exits at once, so
        # adopt the real long-lived window process in that case.
        $script:DuneAppProc = Start-Process -FilePath $script:DuneShellExe -PassThru
        Start-Sleep -Milliseconds 700
        if ($script:DuneAppProc -and $script:DuneAppProc.HasExited) {
            $script:DuneAppProc = Get-Process -Name DuneShell -ErrorAction SilentlyContinue |
                                  Sort-Object StartTime -Descending | Select-Object -First 1
        }
    } catch {
        Write-DuneLog "App window failed to launch ($($_.Exception.Message)); falling back to browser" 'WARN'
        $script:DuneShellExe = $null
        $script:DuneAppProc = $null
    }
}

if ((-not $script:DuneHeadlessMode) -and -not ($openInAppWindow -and $script:DuneShellExe)) {
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
    if (Get-Command Stop-DuneConsoleLifecycle -ErrorAction SilentlyContinue) {
        try { Stop-DuneConsoleLifecycle } catch {}
    }
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
