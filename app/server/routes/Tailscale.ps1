# Tailscale.ps1 — LOCAL, read-only routes backing the portal's Tailscale page.
# Token-gated like the rest of /api/*. No mutating tailscale commands by
# design (see lib/Tailscale.ps1). The nav item is marked localOnly so remote
# (Cloudflare-tunnel) viewers don't see it.
#
#   GET  /api/tailscale/status        -> normalized `tailscale status --json`
#   POST /api/tailscale/open-console  -> open login.tailscale.com/admin in the
#                                        host's default browser

Register-DuneRoute -Method GET -Path '/api/tailscale/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $status = Get-DuneTailscaleStatus
        Write-DuneJson -Response $res -Body $status
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method POST -Path '/api/tailscale/open-console' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Open-DuneTailscaleConsole
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Opening Tailscale admin console failed: $($_.Exception.Message)"
    }
}
