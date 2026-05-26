# Dune Server — entry point (v6.1 web portal)
#
# Bootstrap: pick a free port, start HttpListener, open default browser at the
# tokened localhost URL. The full UI is the React SPA in webui/dist/.

$ErrorActionPreference = 'Stop'

# Version (one of the 5 sync'd constants; see persistent-notes.md)
$script:DuneToolVersion = '6.1.0'

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

# ---------- Load server + routes -----------------------------------------------

$serverDir = Join-Path $script:AppDir 'server'
. (Join-Path $serverDir 'HttpServer.ps1')

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
