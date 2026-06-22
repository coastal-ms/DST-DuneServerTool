# QuickTunnel.ps1 -- DuneToken-gated LOCAL routes for the free Cloudflare quick
# tunnel (Settings -> Mobile App / Remote Access). These live under
# /api/remote-access/* so the dispatcher gates them by DuneToken only and they
# are unreachable through the tunnel itself (the desktop portal sets the token).
#
#   GET  /api/remote-access/quick-tunnel/status  -> {running; url; pid; installed; ...}
#   POST /api/remote-access/quick-tunnel/start    -> {ok; url; pid; status}
#   POST /api/remote-access/quick-tunnel/stop     -> {ok; status}

Register-DuneRoute -Method GET -Path '/api/remote-access/quick-tunnel/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Get-Command Get-DuneQuickTunnelStatus -ErrorAction SilentlyContinue)) {
            Write-DuneError -Response $res -Status 500 -Message 'Quick tunnel support is unavailable in this build.'
            return
        }
        Write-DuneJson -Response $res -Body (Get-DuneQuickTunnelStatus)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/remote-access/quick-tunnel/start' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Get-Command Start-DuneQuickTunnel -ErrorAction SilentlyContinue)) {
            Write-DuneError -Response $res -Status 500 -Message 'Quick tunnel support is unavailable in this build.'
            return
        }
        $result = Start-DuneQuickTunnel
        if ($result.ok) {
            Write-DuneJson -Response $res -Body $result
        } else {
            Write-DuneError -Response $res -Status 409 -Message $result.error
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/remote-access/quick-tunnel/stop' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Get-Command Stop-DuneQuickTunnel -ErrorAction SilentlyContinue)) {
            Write-DuneError -Response $res -Status 500 -Message 'Quick tunnel support is unavailable in this build.'
            return
        }
        Write-DuneJson -Response $res -Body (Stop-DuneQuickTunnel)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
