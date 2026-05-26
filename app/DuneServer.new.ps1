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
$script:DistRoot = $null
foreach ($candidate in @(
    (Join-Path $script:RepoRoot 'webui\dist'),    # installed layout
    (Join-Path (Split-Path -Parent $script:RepoRoot) 'webui\dist')  # dev fallback
)) {
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        $script:DistRoot = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}
if (-not $script:DistRoot) {
    Write-Host "ERROR: Could not locate webui\dist (looked under '$script:RepoRoot' and parent)." -ForegroundColor Red
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
# Installed layout: <install-root>\dune-server.ps1 (one level above app\)
# Dev layout:       <repo-root>\dune-server.ps1   (two levels above app\server\)
$script:MainScript = $null
foreach ($candidate in @(
    (Join-Path $script:RepoRoot 'dune-server.ps1'),
    (Join-Path (Split-Path -Parent $script:RepoRoot) 'dune-server.ps1')
)) {
    if (Test-Path -LiteralPath $candidate) {
        $script:MainScript = (Resolve-Path -LiteralPath $candidate).Path
        break
    }
}
if (-not $script:MainScript) {
    Write-Host "WARNING: dune-server.ps1 not found near '$script:RepoRoot'. Command execution will fail." -ForegroundColor Yellow
}

# ---------- Load server + routes -----------------------------------------------

$serverDir = Join-Path $script:AppDir 'server'
. (Join-Path $serverDir 'HttpServer.ps1')

# Lib modules (load before routes — routes call into them)
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

# Kick the browser open ~500ms after we start listening, so the listener is up first.
$url = "http://127.0.0.1:47823/?t=$script:LaunchToken"
Write-Host "  URL: $url" -ForegroundColor Green
Write-Host ""
$browserJob = Start-Job -ScriptBlock {
    param($u)
    Start-Sleep -Milliseconds 600
    Start-Process $u
} -ArgumentList $url

try {
    Start-DuneHttpServer -DistRoot $script:DistRoot -PreferredPort 47823 -Token $script:LaunchToken
} finally {
    if ($browserJob) { Remove-Job -Job $browserJob -Force -ErrorAction SilentlyContinue }
    Stop-DuneHttpServer
}
