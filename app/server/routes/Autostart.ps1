# Autostart routes — backs the Help → "Run at Windows startup" toggle.
#
# Loopback-only: a remote viewer (Tailscale / LAN) with a valid token must NOT
# be able to register a per-user scheduled task on the host machine. Both
# endpoints reject non-loopback callers with 403.

function Test-DuneAutostartLoopbackRequest {
    param($req)
    try {
        $remote = $req.RemoteEndPoint.Address
        if ($remote) { return [System.Net.IPAddress]::IsLoopback($remote) }
    } catch {}
    return $false
}

# GET /api/autostart — current state.
Register-DuneRoute -Method GET -Path '/api/autostart' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneAutostartLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Autostart can only be managed from the host machine.'
            return
        }
        $state = Get-DuneAutostartState
        Write-DuneJson -Response $res -Body $state
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/autostart  body: { enabled: bool }
Register-DuneRoute -Method POST -Path '/api/autostart' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneAutostartLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Autostart can only be managed from the host machine.'
            return
        }

        $enabled = $null
        if ($body -is [hashtable]) {
            if ($body.ContainsKey('enabled')) { $enabled = [bool]$body.enabled }
        } elseif ($body -and $body.PSObject.Properties.Name -contains 'enabled') {
            $enabled = [bool]$body.enabled
        }
        if ($null -eq $enabled) {
            Write-DuneError -Response $res -Status 400 -Message "Missing required field 'enabled' (bool)."
            return
        }

        if (-not (Test-DuneAutostartAvailable)) {
            Write-DuneError -Response $res -Status 400 -Message 'Autostart is only available from the installed DuneServer.exe (not a dev pwsh build).'
            return
        }

        $result = if ($enabled) { Register-DuneAutostart } else { Unregister-DuneAutostart }
        if (-not $result.ok) {
            Write-DuneError -Response $res -Status 500 -Message $result.error
            return
        }

        $state = Get-DuneAutostartState
        Write-DuneJson -Response $res -Body $state
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
