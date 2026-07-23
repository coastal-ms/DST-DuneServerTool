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
# remote path. Saving 'lan' requires a non-empty hostIp AND a saved host
# administrator credential that matches it (see /hyperv-lan/credential below) -
# every ongoing Hyper-V call (Get-DuneHyperVSplat) requires that credential, so
# enabling LAN mode without one would just defer today's "no such fallback"
# failure to the next VM status check instead of catching it here.
Register-DuneRoute -Method POST -Path '/api/setup/hyperv-lan' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not $body) { Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body.'; return }
        $mode   = [string]$body['mode']
        $hostIp = ([string]$body['hostIp']).Trim()
        if ($mode -match '^(?i:lan)$') {
            $mode = 'lan'
            if (-not $hostIp) { Write-DuneError -Response $res -Status 400 -Message 'A Hyper-V host IP is required to enable Hyper-V over LAN.'; return }
            $credInfo = Get-DuneHyperVLanCredentialInfo -HostIp $hostIp
            if (-not $credInfo.ok) { Write-DuneError -Response $res -Status 500 -Message $credInfo.error; return }
            if (-not $credInfo.exists -or -not $credInfo.matchesHost) {
                Write-DuneError -Response $res -Status 400 -Message "Save a host administrator credential for $hostIp first (Hyper-V host step / Settings - Hyper-V over LAN)."
                return
            }
        } else {
            $mode = 'local'
        }
        Save-DuneConfig -Config @{ VmHostMode = $mode; HyperVHostIp = $hostIp } | Out-Null
        Write-DuneJson -Response $res -Body @{ ok = $true; mode = (Get-DuneVmHostMode); hostIp = (Get-DuneHyperVHostIp) }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Test remote Hyper-V connectivity to a candidate host IP. If the request body
# carries a user/password, that credential is tested WITHOUT being saved (the
# Connect step's "Test" button, before the user has saved anything). Otherwise
# the saved credential for that host is used, so re-testing an already-
# configured host never re-prompts for credentials.
Register-DuneRoute -Method POST -Path '/api/setup/hyperv-lan/test' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $hostIp = if ($body) { ([string]$body['hostIp']).Trim() } else { '' }
        if (-not $hostIp) { $hostIp = (Get-DuneHyperVHostIp) }
        $user     = if ($body -and $body.Contains('user'))     { ([string]$body['user']).Trim() } else { '' }
        $password = if ($body -and $body.Contains('password')) { [string]$body['password'] } else { '' }
        Write-DuneJson -Response $res -Body (Test-DuneHyperVLan -HostIp $hostIp -User $user -Password $password)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Non-secret credential status for a host: whether one is saved, which user it
# was saved for, and whether it matches the given (or currently configured)
# host IP. Never returns the password. Lets the UI show "using saved
# credential for <user>" instead of re-prompting when one already exists.
Register-DuneRoute -Method GET -Path '/api/setup/hyperv-lan/credential' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $hostIp = (Get-DuneQ $req 'hostIp')
        if (-not $hostIp) { $hostIp = (Get-DuneHyperVHostIp) }
        Write-DuneJson -Response $res -Body (Get-DuneHyperVLanCredentialInfo -HostIp $hostIp)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Save (or replace) the host administrator credential used for every Hyper-V
# over LAN call. Persisted in Windows Credential Manager, scoped to the
# signed-in Windows user running DST - never written to dune-server.config, a
# log, or any API response. Callers should test the credential first (POST
# /hyperv-lan/test with user+password); this endpoint does not itself verify
# connectivity, so the wizard/Settings UI is expected to call test then save.
Register-DuneRoute -Method POST -Path '/api/setup/hyperv-lan/credential' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not $body) { Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body.'; return }
        $hostIp = ([string]$body['hostIp']).Trim(); if (-not $hostIp) { $hostIp = (Get-DuneHyperVHostIp) }
        $user   = ([string]$body['user']).Trim()
        $pass   = [string]$body['password']
        if (-not $hostIp -or -not $user -or -not $pass) { Write-DuneError -Response $res -Status 400 -Message 'Host IP, administrator username, and password are required.'; return }
        $r = Save-DuneHyperVLanCredential -HostIp $hostIp -User $user -Password $pass
        if (-not $r.ok) { Write-DuneError -Response $res -Status 500 -Message $r.error; return }
        Write-DuneJson -Response $res -Body @{ ok = $true }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Explicitly remove the saved credential (Settings/wizard "Remove credential"
# action). Disabling LAN mode alone never does this - only this endpoint does.
Register-DuneRoute -Method DELETE -Path '/api/setup/hyperv-lan/credential' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $r = Remove-DuneHyperVLanCredential
        if (-not $r.ok) { Write-DuneError -Response $res -Status 500 -Message $r.error; return }
        Write-DuneJson -Response $res -Body @{ ok = $true }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Probe the remote host (WinRM admin credential) for what the install step needs:
# drives with room, existing external switches, whether the VM already exists.
# If user/password are omitted, falls back to the saved Hyper-V LAN credential
# for hostIp (set in the Hyper-V host step) - so this step doesn't re-prompt
# when one is already configured. An explicit user/password here is used only
# for this call and is never persisted by this route.
Register-DuneRoute -Method POST -Path '/api/setup/hyperv-lan/host-resources' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not $body) { Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body.'; return }
        $hostIp = ([string]$body['hostIp']).Trim(); if (-not $hostIp) { $hostIp = (Get-DuneHyperVHostIp) }
        $user   = if ($body.Contains('user'))     { ([string]$body['user']).Trim() } else { '' }
        $pass   = if ($body.Contains('password')) { [string]$body['password'] } else { '' }
        if (-not $hostIp) { Write-DuneError -Response $res -Status 400 -Message 'A Hyper-V host IP is required.'; return }
        Write-DuneJson -Response $res -Body (Get-DuneHyperVLanHostResources -HostIp $hostIp -User $user -Password $pass)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Kick off the remote install (background). Returns immediately; the UI polls the
# status endpoint. User/password fall back to the saved Hyper-V LAN credential
# for hostIp when omitted (same as host-resources above); when explicitly
# provided they're passed to the worker in-memory only.
Register-DuneRoute -Method POST -Path '/api/setup/hyperv-lan/install' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not $body) { Write-DuneError -Response $res -Status 400 -Message 'Missing JSON body.'; return }
        $hostIp = ([string]$body['hostIp']).Trim(); if (-not $hostIp) { $hostIp = (Get-DuneHyperVHostIp) }
        $user   = if ($body.Contains('user'))     { ([string]$body['user']).Trim() } else { '' }
        $pass   = if ($body.Contains('password')) { [string]$body['password'] } else { '' }
        $drive  = ([string]$body['destDrive']).Trim()
        $switch = ([string]$body['switchName']).Trim()
        $vmPass = [string]$body['vmPassword']
        $memGB  = 0; [void][int]::TryParse("$($body['memoryGB'])", [ref]$memGB)
        $replace = $false; if ($body.Contains('replaceExisting')) { $replace = [bool]$body['replaceExisting'] }
        if (-not $hostIp) { Write-DuneError -Response $res -Status 400 -Message 'A Hyper-V host IP is required.'; return }
        if (-not $drive -or -not $switch -or $memGB -lt 1) { Write-DuneError -Response $res -Status 400 -Message 'Destination drive, external switch, and a memory size (GB) are required.'; return }
        $r = Start-DuneHyperVLanInstallAsync -HostIp $hostIp -User $user -Password $pass -DestDrive $drive -MemoryGB $memGB -SwitchName $switch -VmPassword $vmPass -ReplaceExisting $replace
        if (-not $r.ok) { Write-DuneError -Response $res -Status 409 -Message $r.error; return }
        Write-DuneJson -Response $res -Body $r
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Poll remote-install progress (phase, per-step status, guest IP, error).
Register-DuneRoute -Method GET -Path '/api/setup/hyperv-lan/install/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        Write-DuneJson -Response $res -Body (Get-DuneHyperVLanInstallStatus)
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
