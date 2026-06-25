# FlsToken.ps1 - routes for the FLS host-token rotation recovery tool.
#
# Recovers a self-hosted battlegroup that Funcom's FLS service has started
# rejecting with error 403002 ("Could not find service authorization
# information for Battlegroup"). The user regenerates their self-hosting token
# on the Dune account page and pastes it here; DST replaces it everywhere on the
# server and restarts. See app/server/lib/FlsToken.ps1 for the mechanism.
#
# Loopback-only: the token is a sensitive credential and the action restarts the
# game server, so a remote viewer (Tailscale / LAN) with a valid token must NOT
# be able to drive it. All endpoints reject non-loopback callers with 403.

function Test-DuneFlsLoopbackRequest {
    param($req)
    try {
        $remote = $req.RemoteEndPoint.Address
        if ($remote) { return [System.Net.IPAddress]::IsLoopback($remote) }
    } catch {}
    return $false
}

# GET /api/fls-token/world - probe the live battlegroup (namespace / world /
# HostId / phase) over SSH. Called on card mount and after a rotation; not on
# every poll (it does an SSH round-trip).
Register-DuneRoute -Method GET -Path '/api/fls-token/world' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneFlsLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Token rotation can only be managed from the host machine.'
            return
        }
        $w = Get-DuneFlsWorldContext
        Write-DuneJson -Response $res -Body @{
            ok        = [bool]$w.ok
            reachable = [bool]$w.reachable
            world     = $w.world
            hostId    = $w.hostId
            phase     = $w.phase
            error     = $w.error
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# GET /api/fls-token/status - fast (file-only) rotation progress for polling.
Register-DuneRoute -Method GET -Path '/api/fls-token/status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneFlsLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Token rotation can only be managed from the host machine.'
            return
        }
        Write-DuneJson -Response $res -Body (Get-DuneFlsRotateStatus)
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# POST /api/fls-token/rotate  body: { token: '<jwt>' }
# Validates the token + HostId match, then starts the rotation in the
# background. Returns immediately; the client polls /api/fls-token/status.
Register-DuneRoute -Method POST -Path '/api/fls-token/rotate' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        if (-not (Test-DuneFlsLoopbackRequest $req)) {
            Write-DuneError -Response $res -Status 403 -Message 'Token rotation can only be managed from the host machine.'
            return
        }
        $token = $null
        if ($body -is [System.Collections.IDictionary]) {
            if ($body.Contains('token')) { $token = [string]$body['token'] }
        } elseif ($body -and $body.PSObject.Properties['token']) {
            $token = [string]$body.token
        }
        $token = ([string]$token).Trim()
        if ([string]::IsNullOrWhiteSpace($token)) {
            Write-DuneError -Response $res -Status 400 -Message 'Paste your regenerated self-hosting token.'
            return
        }

        # Fast pre-flight so obvious mistakes return a clear 400 instead of a
        # background error the user has to poll for.
        $info = Get-DuneFlsTokenInfo -Jwt $token
        if (-not $info.valid) {
            Write-DuneError -Response $res -Status 400 -Message $info.error
            return
        }
        if ($info.expired) {
            Write-DuneError -Response $res -Status 400 -Message 'That token is already expired - generate a fresh one on the Dune account page.'
            return
        }

        $r = Start-DuneFlsRotateAsync -Jwt $token
        if (-not $r.ok) {
            $status = if ($r.running) { 409 } else { 500 }
            Write-DuneError -Response $res -Status $status -Message $r.error
            return
        }
        Write-DuneJson -Response $res -Body @{ ok = $true; running = $true; message = $r.message }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
