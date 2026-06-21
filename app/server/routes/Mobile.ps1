# Mobile.ps1 — Routes for pairing the mobile app.

Register-DuneRoute -Method GET -Path '/api/mobile/pairing' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $port = ([uri]$script:DunePrefixUrl).Port
        $publicIpStatus = Get-DunePublicIpStatus
        $tailscaleStatus = Get-DuneTailscaleStatus

        Write-DuneJson -Response $res -Body @{
            token = $script:DuneToken
            port = $port
            publicIp = $publicIpStatus.publicIp
            tailscaleIp = if ($tailscaleStatus.installed -and $tailscaleStatus.available -and $tailscaleStatus.self.tailscaleIPs.Count -gt 0) { $tailscaleStatus.self.tailscaleIPs[0] } else { $null }
            hostname = $publicIpStatus.hostname
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
