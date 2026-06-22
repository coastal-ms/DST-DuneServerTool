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
        'C:\Program Files\Tailscale\tailscale.exe',
        'X:\GH Projects\TailScale\tailscale.exe'                       # dev box
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
        $out = (& $ts funnel status 2>$null) -join "`n"
        $m = [regex]::Match($out, 'https://[a-z0-9.-]+\.ts\.net')
        if ($m.Success) { return $m.Value.TrimEnd('/') }
    } catch {}
    return ''
}

function Test-DuneTailscalePresent {
    return [bool](Get-DuneTailscalePath)
}
