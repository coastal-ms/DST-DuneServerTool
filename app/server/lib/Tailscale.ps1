# Tailscale.ps1 — read-only wrapper around the local Tailscale CLI so the
# desktop portal can surface the tailnet (devices, IPs, online state) IN-APP
# instead of sending the admin to login.tailscale.com. Same LOCAL execution
# model as the rest of the desktop backend.
#
# By design this exposes NO mutating commands (no `tailscale up/down/logout`):
# the page must never be able to drop the admin's own Tailscale access to the
# Dune VM. Management actions stay on the official admin console (one click
# away via Open-DuneTailscaleConsole / the page's button).

$script:DuneTailscaleAdminUrl = 'https://login.tailscale.com/admin/machines'

function Get-DuneTailscaleExe {
    $cmd = Get-Command 'tailscale.exe' -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command 'tailscale' -ErrorAction SilentlyContinue }
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Tailscale\tailscale.exe')
    )
    foreach ($p in $candidates) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

function Test-DuneTailscalePresent {
    $result = @{ installed = $false; path = ''; version = '' }
    try {
        $exe = Get-DuneTailscaleExe
        if ($exe) {
            $result.installed = $true
            $result.path = $exe
            try {
                $vi = (Get-Item -LiteralPath $exe).VersionInfo
                if ($vi -and $vi.FileVersion) { $result.version = $vi.FileVersion }
            } catch {}
        }
    } catch {}
    return $result
}

function ConvertTo-DuneTailscaleNode {
    param($n)
    if (-not $n) { return $null }
    $ips = @()
    if ($n.TailscaleIPs) { $ips = @($n.TailscaleIPs | ForEach-Object { [string]$_ }) }
    $dns = [string]$n.DNSName
    if ($dns) { $dns = $dns.TrimEnd('.') }
    return [ordered]@{
        id           = [string]$n.ID
        name         = [string]$n.HostName
        dnsName      = $dns
        os           = [string]$n.OS
        tailscaleIPs = $ips
        online       = [bool]$n.Online
        exitNode     = [bool]$n.ExitNode
        lastSeen     = [string]$n.LastSeen
    }
}

function Get-DuneTailscaleStatus {
    $out = [ordered]@{
        available    = $false
        installed    = $false
        path         = ''
        backendState = ''
        tailnetName  = ''
        self         = $null
        peers        = @()
        adminUrl     = $script:DuneTailscaleAdminUrl
        error        = ''
    }

    $present = Test-DuneTailscalePresent
    $out.installed = $present.installed
    $out.path      = $present.path
    if (-not $present.installed) {
        $out.error = 'Tailscale CLI not found on this PC. Install Tailscale to see your tailnet here.'
        return $out
    }

    try {
        $raw  = & $present.path 'status' '--json' 2>&1
        $text = ($raw | Out-String)
        $json = $null
        try {
            $json = $text | ConvertFrom-Json
        } catch {
            $out.error = ("Could not parse `tailscale status --json`: " + $text).Trim()
            return $out
        }

        $out.backendState = [string]$json.BackendState
        if ($json.CurrentTailnet -and $json.CurrentTailnet.Name) {
            $out.tailnetName = [string]$json.CurrentTailnet.Name
        }
        $out.self = ConvertTo-DuneTailscaleNode $json.Self

        $peers = New-Object System.Collections.Generic.List[object]
        if ($json.Peer) {
            foreach ($prop in $json.Peer.PSObject.Properties) {
                $node = ConvertTo-DuneTailscaleNode $prop.Value
                if ($node) { $peers.Add($node) }
            }
        }
        # Online devices first, then alphabetical by name.
        $out.peers = @($peers | Sort-Object @{ Expression = { -not $_.online } }, @{ Expression = { $_.name } })
        $out.available = ($out.backendState -eq 'Running')
        if (-not $out.available -and -not $out.error) {
            $out.error = "Tailscale is installed but not connected (state: $($out.backendState))."
        }
    } catch {
        $out.error = "tailscale status failed: $($_.Exception.Message)"
    }
    return $out
}

function Open-DuneTailscaleConsole {
    Start-Process $script:DuneTailscaleAdminUrl
    return @{ ok = $true; url = $script:DuneTailscaleAdminUrl }
}
