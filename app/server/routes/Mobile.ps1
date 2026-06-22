# Mobile.ps1 — Routes for pairing the mobile app and managing the loopback bridge
# that exposes the localhost DST API to the phone over a Cloudflare quick tunnel.

Register-DuneRoute -Method GET -Path '/api/mobile/pairing' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        # URL-based pairing: the phone stores a full base URL + token and calls
        # ${url}${path}. The URL is the active Cloudflare quick tunnel if running,
        # else the user's configured remote hostname, else null (the UI then
        # prompts the user to start the tunnel). The bridge port is returned only
        # for the LAN/manual fallback (http://<lan-ip>:<port>).
        $port = if (Get-Command Get-DuneMobileBridgePort -ErrorAction SilentlyContinue) {
            Get-DuneMobileBridgePort
        } else { 47900 }

        $url = $null
        $source = 'none'
        try {
            if (Get-Command Get-DuneQuickTunnelStatus -ErrorAction SilentlyContinue) {
                $qt = Get-DuneQuickTunnelStatus
                if ($qt -and $qt.running -and $qt.url) { $url = [string]$qt.url; $source = 'quicktunnel' }
            }
        } catch {}
        if (-not $url) {
            try {
                if (Get-Command Get-DuneRemoteAcl -ErrorAction SilentlyContinue) {
                    $acl = Get-DuneRemoteAcl
                    if ($acl -and $acl.hostname) {
                        $h = [string]$acl.hostname
                        if ($h -notmatch '^https?://') { $h = "https://$h" }
                        $url = $h.TrimEnd('/')
                        $source = 'domain'
                    }
                }
            } catch {}
        }

        $bridge = $null
        if (Get-Command Get-DuneBridgeStatus -ErrorAction SilentlyContinue) {
            try { $bridge = Get-DuneBridgeStatus } catch {}
        }

        Write-DuneJson -Response $res -Body @{
            token  = $script:DuneToken
            url    = $url
            source = $source
            port   = $port
            bridge = $bridge
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Health snapshot of the loopback mobile bridge (task, listener, live probe).
# Safe to call when DST is not elevated.
Register-DuneRoute -Method GET -Path '/api/mobile/bridge-status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Get-Command Get-DuneBridgeStatus -ErrorAction SilentlyContinue)) {
            Write-DuneError -Response $res -Status 500 -Message 'Bridge management is unavailable in this build.'
            return
        }
        Write-DuneJson -Response $res -Body (Get-DuneBridgeStatus)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# (Re)configure the bridge: registers the loopback listener's self-healing
# scheduled task. No admin/firewall needed (loopback bind).
Register-DuneRoute -Method POST -Path '/api/mobile/bridge-repair' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Get-Command Invoke-DuneBridgeRepair -ErrorAction SilentlyContinue)) {
            Write-DuneError -Response $res -Status 500 -Message 'Bridge management is unavailable in this build.'
            return
        }
        $result = Invoke-DuneBridgeRepair
        if ($result.ok) {
            Write-DuneJson -Response $res -Body $result
        } else {
            Write-DuneError -Response $res -Status 409 -Message $result.error
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
