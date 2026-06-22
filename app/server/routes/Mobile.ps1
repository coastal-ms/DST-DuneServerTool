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
        $cfClientId = ''
        $cfClientSecret = ''

        # Resolve the configured custom hostname (if any) and the mobile service
        # token (if any) up front.
        $hostUrl = $null
        try {
            if (Get-Command Get-DuneRemoteAcl -ErrorAction SilentlyContinue) {
                $acl = Get-DuneRemoteAcl
                if ($acl -and $acl.hostname) {
                    $h = [string]$acl.hostname
                    if ($h -notmatch '^https?://') { $h = "https://$h" }
                    $hostUrl = $h.TrimEnd('/')
                }
            }
        } catch {}
        $svc = $null
        try {
            if (Get-Command Get-DuneMobileServiceToken -ErrorAction SilentlyContinue) {
                $s = Get-DuneMobileServiceToken
                if ($s -and $s.clientId -and $s.clientSecret) { $svc = $s }
            }
        } catch {}

        # Preferred (reliable, no domain, no Cloudflare): Tailscale Funnel. A
        # stable public HTTPS URL the phone app + browser use directly. This is
        # the default remote transport now that anonymous quick tunnels proved
        # unreliable.
        try {
            if (Get-Command Get-DuneTailscaleFunnelUrl -ErrorAction SilentlyContinue) {
                $fu = Get-DuneTailscaleFunnelUrl
                if ($fu) { $url = $fu; $source = 'funnel' }
            }
        } catch {}

        # Next (stable): the custom domain reached past Cloudflare Access via the
        # service token (advanced, bring-your-own-domain).
        if (-not $url -and $hostUrl -and $svc) {
            $url = $hostUrl
            $source = 'domain-service-token'
            $cfClientId = $svc.clientId
            $cfClientSecret = $svc.clientSecret
        }
        # Otherwise the free quick tunnel (legacy; unreliable, kept as fallback).
        if (-not $url) {
            try {
                if (Get-Command Get-DuneQuickTunnelStatus -ErrorAction SilentlyContinue) {
                    $qt = Get-DuneQuickTunnelStatus
                    if ($qt -and $qt.running -and $qt.url) { $url = [string]$qt.url; $source = 'quicktunnel' }
                }
            } catch {}
        }
        # Last resort: the bare custom domain with NO service token. The browser
        # portal can still reach it (email login), but the app cannot pass Access
        # without the service token — kept so the UI can prompt the user.
        if (-not $url -and $hostUrl) {
            $url = $hostUrl
            $source = 'domain'
        }

        $bridge = $null
        if (Get-Command Get-DuneBridgeStatus -ErrorAction SilentlyContinue) {
            try { $bridge = Get-DuneBridgeStatus } catch {}
        }

        # Zero-config rendezvous identity: the phone stores the stable pairingId +
        # permanent remoteToken and resolves the CURRENT url from the rendezvous on
        # every use, so it keeps working after reboots / tunnel restarts with no
        # re-pairing. The per-launch token + url above remain for legacy/fallback.
        $rendezvousBase = ''
        $pairingId      = ''
        $remoteToken    = ''
        try {
            if (Get-Command Get-DuneRemoteIdentity -ErrorAction SilentlyContinue) {
                $ident = Get-DuneRemoteIdentity
                $pairingId   = [string]$ident.pairingId
                $remoteToken = [string]$ident.remoteToken
            }
            if (Get-Command Get-DuneRendezvousBase -ErrorAction SilentlyContinue) {
                $rendezvousBase = [string](Get-DuneRendezvousBase)
            }
        } catch {}

        Write-DuneJson -Response $res -Body @{
            token                = $script:DuneToken
            url                  = $url
            source               = $source
            port                 = $port
            bridge               = $bridge
            cfAccessClientId     = $cfClientId
            cfAccessClientSecret = $cfClientSecret
            rendezvousBase       = $rendezvousBase
            pairingId            = $pairingId
            remoteToken          = $remoteToken
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
