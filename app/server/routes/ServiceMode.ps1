# Service-mode routes - backs the "Stay online when signed out" toggle.
#
# Loopback-only: a remote viewer (Tailscale Funnel / Cloudflare domain / LAN)
# with a valid token must NOT be able to register an always-on, run-as-user
# scheduled task on the host - and must NEVER be the source of the Windows
# password. Both endpoints reject non-loopback callers with 403.
#
# SECURITY: enabling the service requires the host's Windows password (Task
# Scheduler stores it encrypted so the task can run "whether logged on or not"
# with the user profile loaded). The password is read from the request body,
# passed straight to Register-DuneServiceMode, and is NEVER persisted by DST or
# written to the log.

function Test-DuneServiceLoopbackRequest {
    param($req)
    try {
        $remote = $req.RemoteEndPoint.Address
        if ($remote) { return [System.Net.IPAddress]::IsLoopback($remote) }
    } catch {}
    return $false
}

# GET /api/service-mode - current state (no secrets).
Register-DuneRoute -Method GET -Path '/api/service-mode' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneServiceLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Service mode can only be managed from the host machine.'
            return
        }
        Write-DuneJson -Response $res -Body (Get-DuneServiceModeState)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/service-mode  body: { enabled: bool, password?: string }
# - enabled=true  requires password (the current user's Windows password).
# - enabled=false removes the task; no password needed.
Register-DuneRoute -Method POST -Path '/api/service-mode' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneServiceLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Service mode can only be managed from the host machine.'
            return
        }

        $enabled  = $null
        $password = $null
        if ($body -is [hashtable]) {
            if ($body.ContainsKey('enabled'))  { $enabled  = [bool]$body.enabled }
            if ($body.ContainsKey('password')) { $password = [string]$body.password }
        } elseif ($body) {
            if ($body.PSObject.Properties.Name -contains 'enabled')  { $enabled  = [bool]$body.enabled }
            if ($body.PSObject.Properties.Name -contains 'password') { $password = [string]$body.password }
        }

        if ($null -eq $enabled) {
            Write-DuneError -Response $res -Status 400 -Message "Missing required field 'enabled' (bool)."
            return
        }
        if (-not (Test-DuneAutostartAvailable)) {
            Write-DuneError -Response $res -Status 400 -Message 'Service mode is only available from the installed DuneServer.exe (not a dev pwsh build).'
            return
        }

        if ($enabled) {
            if ([string]::IsNullOrEmpty($password)) {
                Write-DuneError -Response $res -Status 400 -Message 'A Windows password is required to install the always-on service.'
                return
            }
            $result = Register-DuneServiceMode -Password $password
        } else {
            $result = Unregister-DuneServiceMode
        }
        # Drop the plaintext password reference promptly.
        $password = $null

        if (-not $result.ok) {
            Write-DuneError -Response $res -Status 500 -Message $result.error
            return
        }
        Write-DuneJson -Response $res -Body (Get-DuneServiceModeState)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
