# Tailscale.ps1 -- detect a running Tailscale Funnel so pairing can hand the phone
# a STABLE public HTTPS URL (https://<machine>.<tailnet>.ts.net) instead of an
# ephemeral Cloudflare quick-tunnel URL. Funnel is the reliable, no-domain,
# no-Cloudflare remote transport: the host installs Tailscale + enables Funnel on
# the bridge port, and everyone else (phone app + browser) just uses the URL.

# Resolve tailscale.exe across the bundled/installed layouts, common install, PATH.
function Get-DuneTailscalePath {
    foreach ($cand in @(
        (Join-Path $PSScriptRoot '..\..\tailscale\tailscale.exe'),   # installed: {app}\tailscale\tailscale.exe
        (Join-Path $PSScriptRoot '..\..\tailscale.exe'),             # installed: {app}\tailscale.exe
        'C:\Program Files\Tailscale\tailscale.exe'
    )) {
        try { if ($cand -and (Test-Path -LiteralPath $cand)) { return (Resolve-Path -LiteralPath $cand).Path } } catch {}
    }
    try {
        $cmd = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    } catch {}
    return $null
}

# Returns the public Funnel URL (https://....ts.net) if a Funnel is active, else ''.
function Get-DuneTailscaleFunnelUrl {
    $ts = Get-DuneTailscalePath
    if (-not $ts) { return '' }
    try {
        # A rename can leave obsolete hosts in the local Serve configuration.
        # Only advertise the current node DNS name, never the OS HostName or
        # the first URL in human-readable output.
        $statusText = (& $ts status --json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return '' }
        $status = $statusText | ConvertFrom-Json -ErrorAction Stop
        $dns = ([string]$status.Self.DNSName).TrimEnd('.').ToLowerInvariant()
        if ($status.BackendState -ne 'Running' -or $dns -notmatch '^[a-z0-9-]+(?:\.[a-z0-9-]+)+\.ts\.net$') { return '' }
        $configText = (& $ts funnel status --json 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return '' }
        $config = $configText | ConvertFrom-Json -ErrorAction Stop
        $bridgePort = if (Get-Command Get-DuneMobileBridgePort -ErrorAction SilentlyContinue) { Get-DuneMobileBridgePort } else { 47900 }
        foreach ($entry in $config.AllowFunnel.PSObject.Properties | Sort-Object @{Expression={ if ($_.Name -eq "${dns}:443") { 0 } else { 1 } }},Name) {
            if ($entry.Value -ne $true -or $entry.Name -notmatch ('^' + [regex]::Escape($dns) + ':(\d+)$')) { continue }
            $port = [int]$Matches[1]
            if ($port -lt 1 -or $port -gt 65535) { continue }
            $web = $config.Web.PSObject.Properties[$entry.Name].Value
            $proxy = [string]$web.Handlers.PSObject.Properties['/'].Value.Proxy
            $tcp = $config.TCP.PSObject.Properties[[string]$port].Value
            if ($tcp.HTTPS -ne $true -or $proxy -notin @("http://127.0.0.1:$bridgePort", "http://localhost:$bridgePort")) { continue }
            return 'https://' + $dns + $(if ($port -eq 443) { '' } else { ':' + $port })
        }
    } catch {}
    return ''
}

function Test-DuneTailscalePresent {
    return [bool](Get-DuneTailscalePath)
}
