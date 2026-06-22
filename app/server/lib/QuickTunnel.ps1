# QuickTunnel.ps1 -- manage a Cloudflare "quick tunnel" for free remote access.
#
# A quick tunnel runs `cloudflared tunnel --url http://127.0.0.1:<bridgePort>`
# and hands back an ephemeral https://<random>.trycloudflare.com URL that the
# mobile app (and a friend's browser) can reach over HTTPS with NO account, NO
# domain, and NO router port-forward. cloudflared connects OUT from this PC, so
# nothing inbound is exposed; the bridge it points at binds loopback only.
#
# This is the default, zero-config remote-access transport. Users who want a
# stable hostname + email gating can later upgrade to a named tunnel on their
# own domain (Settings -> Remote Access), which is a separate code path.
#
# Process model: API handlers run in a worker-pool runspace, so we cannot keep a
# live process handle in memory. We persist the cloudflared PID + assigned URL to
# %APPDATA%\DuneServer\quick-tunnel.json and reconcile by PID on every call.

function Get-DuneQuickTunnelStatePath {
    $dir = Join-Path $env:APPDATA 'DuneServer'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'quick-tunnel.json')
}

function Get-DuneQuickTunnelLogPath {
    $dir = Join-Path $env:APPDATA 'DuneServer\.logs'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'quick-tunnel.log')
}

# Resolve cloudflared.exe across dev override, bundled install layouts, and PATH.
function Get-DuneCloudflaredPath {
    if ($env:DUNE_CLOUDFLARED) {
        try { if (Test-Path -LiteralPath $env:DUNE_CLOUDFLARED) { return (Resolve-Path -LiteralPath $env:DUNE_CLOUDFLARED).Path } } catch {}
    }
    foreach ($cand in @(
        (Join-Path $PSScriptRoot '..\..\cloudflared.exe'),                      # installed: {app}\cloudflared.exe
        (Join-Path $PSScriptRoot '..\..\tools\cloudflared.exe'),                # installed: {app}\tools\cloudflared.exe
        (Join-Path $PSScriptRoot '..\..\..\local-only\tools\cloudflared.exe')   # dev checkout
    )) {
        try { return (Resolve-Path -LiteralPath $cand -ErrorAction Stop).Path } catch {}
    }
    try {
        $cmd = Get-Command 'cloudflared.exe' -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = Get-Command 'cloudflared' -ErrorAction SilentlyContinue }
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    } catch {}
    return $null
}

function Test-DuneCloudflaredAlive {
    param([int]$ProcessId)
    if (-not $ProcessId) { return $false }
    try {
        $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if (-not $p) { return $false }
        # Guard against PID reuse: a recycled PID would not be a cloudflared.
        if ($p.ProcessName -notlike 'cloudflared*') { return $false }
        return $true
    } catch { return $false }
}

function Read-DuneQuickTunnelState {
    $path = Get-DuneQuickTunnelStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) } catch { return $null }
}

function Write-DuneQuickTunnelState {
    param($State)
    $path = Get-DuneQuickTunnelStatePath
    $tmp = "$path.tmp"
    ($State | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8 -Force
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Clear-DuneQuickTunnelState {
    $path = Get-DuneQuickTunnelStatePath
    try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force } } catch {}
}

function Get-DuneQuickTunnelLastUrl {
    try {
        if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
            $cfg = Read-DuneConfig
            if ($cfg -and $cfg.QuickTunnelLastUrl) { return [string]$cfg.QuickTunnelLastUrl }
        }
    } catch {}
    return ''
}

# Scan cloudflared's redirected output for the assigned tunnel URL.
function Find-DuneQuickTunnelUrl {
    param([string[]]$Paths)
    foreach ($p in $Paths) {
        try {
            if (Test-Path -LiteralPath $p) {
                $text = Get-Content -LiteralPath $p -Raw -ErrorAction SilentlyContinue
                if ($text) {
                    $m = [regex]::Match($text, 'https://[a-z0-9-]+\.trycloudflare\.com')
                    if ($m.Success) { return $m.Value }
                }
            }
        } catch {}
    }
    return ''
}

# Live status snapshot. Reconciles the persisted PID against running processes so
# a crashed/killed tunnel reports as stopped (and self-cleans its state file).
function Get-DuneQuickTunnelStatus {
    $cfPath = Get-DuneCloudflaredPath
    $installed = [bool]$cfPath
    $version = ''
    if ($installed) {
        try {
            $vi = (Get-Item -LiteralPath $cfPath).VersionInfo
            if ($vi -and $vi.FileVersion) { $version = $vi.FileVersion }
        } catch {}
    }

    $running = $false; $url = ''; $procId = 0; $startedAt = ''; $target = ''
    $state = Read-DuneQuickTunnelState
    if ($state -and $state.pid) {
        $procId = [int]$state.pid
        if (Test-DuneCloudflaredAlive -ProcessId $procId) {
            $running = $true
            $url = [string]$state.url
            $startedAt = [string]$state.startedAt
            $target = [string]$state.target
        } else {
            Clear-DuneQuickTunnelState
            $procId = 0
        }
    }

    return @{
        running            = $running
        url                = $url
        pid                = $procId
        startedAt          = $startedAt
        target             = $target
        installed          = $installed
        cloudflaredPath    = if ($cfPath) { $cfPath } else { '' }
        cloudflaredVersion = $version
        lastUrl            = (Get-DuneQuickTunnelLastUrl)
    }
}

# Start a quick tunnel pointing at the local bridge port. Idempotent: returns the
# existing tunnel if one is already running. Returns @{ ok; url?; pid?; error?; status }.
function Start-DuneQuickTunnel {
    param(
        [int]$Port = 0,
        [int]$TimeoutSec = 25
    )

    $existing = Get-DuneQuickTunnelStatus
    if ($existing.running) {
        return @{ ok = $true; alreadyRunning = $true; url = $existing.url; pid = $existing.pid; status = $existing }
    }

    $cfPath = Get-DuneCloudflaredPath
    if (-not $cfPath) {
        return @{ ok = $false; error = 'cloudflared.exe was not found. It ships with Dune Server; reinstall, or install it from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/ and try again.' }
    }

    if (-not $Port -or $Port -le 0) {
        $Port = if (Get-Command Get-DuneMobileBridgePort -ErrorAction SilentlyContinue) { Get-DuneMobileBridgePort } else { 47900 }
    }
    $target = "http://127.0.0.1:$Port"

    $errLog = Get-DuneQuickTunnelLogPath
    $outLog = "$errLog.out"
    foreach ($f in @($errLog, $outLog)) { try { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } } catch {} }

    $argList = @('tunnel', '--no-autoupdate', '--url', $target)
    try {
        $proc = Start-Process -FilePath $cfPath -ArgumentList $argList -WindowStyle Hidden -PassThru `
            -RedirectStandardError $errLog -RedirectStandardOutput $outLog
    } catch {
        return @{ ok = $false; error = "Could not launch cloudflared: $($_.Exception.Message)" }
    }
    if (-not $proc) {
        return @{ ok = $false; error = 'cloudflared did not start.' }
    }

    $url = ''
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (-not (Test-DuneCloudflaredAlive -ProcessId $proc.Id)) { break }
        $url = Find-DuneQuickTunnelUrl -Paths @($errLog, $outLog)
        if ($url) { break }
    }

    if (-not $url) {
        try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
        return @{ ok = $false; error = "The Cloudflare tunnel did not report a URL within $TimeoutSec seconds. See $errLog for details." }
    }

    $state = @{
        pid       = $proc.Id
        url       = $url
        target    = $target
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-DuneQuickTunnelState -State $state

    try {
        if (Get-Command Save-DuneConfig -ErrorAction SilentlyContinue) {
            [void](Save-DuneConfig @{ QuickTunnelLastUrl = $url; RemoteAccessMode = 'quicktunnel' })
        }
    } catch {}

    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog "QuickTunnel: started $url (pid $($proc.Id)) -> $target"
    }

    return @{ ok = $true; url = $url; pid = $proc.Id; status = (Get-DuneQuickTunnelStatus) }
}

# Stop the quick tunnel we started (by persisted PID) and clear state.
function Stop-DuneQuickTunnel {
    $state = Read-DuneQuickTunnelState
    if ($state -and $state.pid) {
        $procId = [int]$state.pid
        if (Test-DuneCloudflaredAlive -ProcessId $procId) {
            try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    Clear-DuneQuickTunnelState
    if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
        Write-DuneLog 'QuickTunnel: stopped'
    }
    return @{ ok = $true; status = (Get-DuneQuickTunnelStatus) }
}
