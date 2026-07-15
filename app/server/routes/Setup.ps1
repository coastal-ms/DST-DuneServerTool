# Setup Wizard — preflight + config summary.
# The actual install step (Step 3) dispatches `initial-setup` via the existing
# /api/commands/run/{name} route.

Register-DuneRoute -Method GET -Path '/api/setup/preflight' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $mode = (Get-DuneQ $req 'mode')
        if ($mode -notin @('existing','lan')) { $mode = 'fresh' }
        Write-DuneJson -Response $res -Body (Get-DuneSetupPreflight -Mode $mode)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Read the current Hyper-V-over-LAN settings (host location mode + LAN host IP).
Register-DuneRoute -Method GET -Path '/api/setup/hyperv-lan' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body @{
            mode   = (Get-DuneVmHostMode)
            hostIp = (Get-DuneHyperVHostIp)
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Save the Hyper-V-over-LAN settings. This is the routing toggle: mode='lan' +
# a host IP points every Hyper-V call at the remote host; mode='local' (or the
# checkbox unchecked) restores today's local behavior and fully bypasses the
# remote path. Saving 'lan' requires a non-empty hostIp.
Register-DuneRoute -Method POST -Path '/api/setup/hyperv-lan' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not $body) { Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body.'; return }
        $mode   = [string]$body['mode']
        $hostIp = ([string]$body['hostIp']).Trim()
        if ($mode -match '^(?i:lan)$') {
            $mode = 'lan'
            if (-not $hostIp) { Write-DuneError -Response $res -Status 400 -Message 'A Hyper-V host IP is required to enable Hyper-V over LAN.'; return }
        } else {
            $mode = 'local'
        }
        Save-DuneConfig -Config @{ VmHostMode = $mode; HyperVHostIp = $hostIp } | Out-Null
        Write-DuneJson -Response $res -Body @{ ok = $true; mode = (Get-DuneVmHostMode); hostIp = (Get-DuneHyperVHostIp) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Test remote Hyper-V connectivity to a candidate host IP WITHOUT saving it. The
# Connect step calls this before enabling the LAN option, so a bad IP / missing
# permissions is caught with an actionable message instead of failing later.
Register-DuneRoute -Method POST -Path '/api/setup/hyperv-lan/test' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $hostIp = if ($body) { ([string]$body['hostIp']).Trim() } else { '' }
        if (-not $hostIp) { $hostIp = (Get-DuneHyperVHostIp) }
        Write-DuneJson -Response $res -Body (Test-DuneHyperVLan -HostIp $hostIp)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/setup/config' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneSetupConfigSummary)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
