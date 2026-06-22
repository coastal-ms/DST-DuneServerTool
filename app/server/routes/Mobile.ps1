# Mobile.ps1 — Routes for pairing the mobile app and managing the bridge that
# exposes the localhost DST API to the phone over Tailscale.

Register-DuneRoute -Method GET -Path '/api/mobile/pairing' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        # The phone connects to the BRIDGE port over Tailscale, NOT DST's dynamic
        # loopback port ($script:DunePrefixUrl is 127.0.0.1-only). Returning the
        # loopback port made every paired phone unreachable.
        $port = if (Get-Command Get-DuneMobileBridgePort -ErrorAction SilentlyContinue) {
            Get-DuneMobileBridgePort
        } else { 47900 }

        $publicIpStatus = Get-DunePublicIpStatus
        $tailscaleStatus = Get-DuneTailscaleStatus

        $bridge = $null
        if (Get-Command Get-DuneBridgeStatus -ErrorAction SilentlyContinue) {
            try { $bridge = Get-DuneBridgeStatus } catch {}
        }

        Write-DuneJson -Response $res -Body @{
            token = $script:DuneToken
            port = $port
            publicIp = $publicIpStatus.publicIp
            tailscaleIp = if ($tailscaleStatus.installed -and $tailscaleStatus.available -and $tailscaleStatus.self.tailscaleIPs.Count -gt 0) { $tailscaleStatus.self.tailscaleIPs[0] } else { $null }
            hostname = $publicIpStatus.hostname
            bridge = $bridge
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Health snapshot of the mobile bridge (firewall rule, task, listener, Tailscale,
# live probe). Safe to call when DST is not elevated.
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

# (Re)configure the bridge: URL ACL + Tailscale-scoped firewall rule + background
# task. Requires DST to be elevated; returns an actionable error otherwise.
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
