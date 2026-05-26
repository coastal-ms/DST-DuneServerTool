# Dune Server — entry point (v6.1 web portal)
#
# Bootstrap: pick a free port, start HttpListener, open default browser at the
# tokened localhost URL. The full UI is the React SPA in webui/dist/.

$ErrorActionPreference = 'Stop'

# Version (one of the 5 sync'd constants; see persistent-notes.md)
$script:DuneToolVersion = '6.1.0'

# ---------- Self-elevate -------------------------------------------------------
# Hyper-V cmdlets (Get-VM etc.) require admin or Hyper-V Administrators group.
# Matches the v6.0.x WPF .exe behavior (requireAdmin manifest).
function Test-DuneIsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}
if (-not (Test-DuneIsAdmin)) {
    Write-Host "  Re-launching elevated (Hyper-V cmdlets require admin)..." -ForegroundColor Yellow
    $selfPath = $PSCommandPath
    if (-not $selfPath) {
        $selfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    }
    $launcher = (Get-Command pwsh.exe -ErrorAction SilentlyContinue).Source
    if (-not $launcher) { $launcher = 'powershell.exe' }
    try {
        Start-Process -FilePath $launcher `
            -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$selfPath`"") `
            -Verb RunAs | Out-Null
    } catch {
        Write-Host "  Elevation cancelled. Dune Server needs admin to query Hyper-V VMs." -ForegroundColor Red
        Read-Host "Press Enter to exit"
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
    Write-Host "ERROR: Could not locate webui\dist (searched upward from '$script:AppDir')." -ForegroundColor Red
    Read-Host "Press Enter to exit"
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
    Write-Host "ERROR: pwsh.exe (PowerShell 7) not found. Install from https://aka.ms/PowerShell-Release" -ForegroundColor Red
    Read-Host "Press Enter to exit"
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
    Write-Host "ERROR: Could not locate server\ (HttpServer.ps1 + routes) near '$script:AppDir'." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
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

Write-Host ""
Write-Host "  Dune Server v$script:DuneToolVersion" -ForegroundColor Yellow
Write-Host "  Serving from: $script:DistRoot" -ForegroundColor DarkGray
Write-Host ""

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

try {
    Start-DuneHttpServer -DistRoot $script:DistRoot -PreferredPort 47823 -Token $script:LaunchToken
} finally {
    if ($browserJob) { Remove-Job -Job $browserJob -Force -ErrorAction SilentlyContinue }
    Stop-DuneHttpServer
}
