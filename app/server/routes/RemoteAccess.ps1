# RemoteAccess.ps1 — DuneToken-gated LOCAL management routes (issue #74).
#
# These routes back the desktop portal's Settings → Remote Access card.
# They live under /api/remote-access/* (NOT /api/remote/*) so the dispatcher
# can branch on prefix alone — /api/remote-access/* is gated by DuneToken
# only (same as the rest of /api/*), and is unreachable through the
# Cloudflare tunnel by design (the desktop portal sets the token; the
# remote SPA does not).
#
#   GET  /api/remote-access/acl                    -> {owner; admins[]; hostname}
#   PUT  /api/remote-access/acl                    body: {owner; admins[]; hostname}
#   GET  /api/remote-access/audit-log?lines=N      -> {lines: [parsed entries...]}
#   GET  /api/remote-access/cloudflared-status     -> {installed; path; version}

Register-DuneRoute -Method GET -Path '/api/remote-access/acl' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $acl = Get-DuneRemoteAcl
        Write-DuneJson -Response $res -Body @{
            owner    = $acl.owner
            admins   = $acl.admins
            hostname = $acl.hostname
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method PUT -Path '/api/remote-access/acl' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $owner = ''
        $admins = @()
        $hostname = ''
        if ($body -is [hashtable]) {
            if ($body.ContainsKey('owner'))    { $owner    = [string]$body['owner'] }
            if ($body.ContainsKey('admins'))   { $admins   = @($body['admins']) }
            if ($body.ContainsKey('hostname')) { $hostname = [string]$body['hostname'] }
        } elseif ($null -ne $body) {
            if ($body.PSObject.Properties.Name -contains 'owner')    { $owner    = [string]$body.owner }
            if ($body.PSObject.Properties.Name -contains 'admins')   { $admins   = @($body.admins) }
            if ($body.PSObject.Properties.Name -contains 'hostname') { $hostname = [string]$body.hostname }
        }
        $saved = Save-DuneRemoteAcl -Acl @{ owner = $owner; admins = $admins; hostname = $hostname }
        Write-DuneJson -Response $res -Body @{
            owner    = $saved.owner
            admins   = $saved.admins
            hostname = $saved.hostname
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Save failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method GET -Path '/api/remote-access/mobile-service-token' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $st = Get-DuneMobileServiceToken
        Write-DuneJson -Response $res -Body @{
            configured = ([bool]$st.clientId -and [bool]$st.clientSecret)
            clientId   = $st.clientId
        }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

# Save or clear the mobile Cloudflare Access service token. An empty clientId AND
# clientSecret clears it. The secret is write-only from the UI's perspective: it
# is accepted here but never echoed back by the GET route.
Register-DuneRoute -Method PUT -Path '/api/remote-access/mobile-service-token' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $clientId = ''
        $clientSecret = ''
        if ($body -is [hashtable]) {
            if ($body.ContainsKey('clientId'))     { $clientId     = [string]$body['clientId'] }
            if ($body.ContainsKey('clientSecret')) { $clientSecret = [string]$body['clientSecret'] }
        } elseif ($null -ne $body) {
            if ($body.PSObject.Properties.Name -contains 'clientId')     { $clientId     = [string]$body.clientId }
            if ($body.PSObject.Properties.Name -contains 'clientSecret') { $clientSecret = [string]$body.clientSecret }
        }
        $clientId = $clientId.Trim()
        $clientSecret = $clientSecret.Trim()

        if (-not $clientId -and -not $clientSecret) {
            Clear-DuneMobileServiceToken
            Write-DuneJson -Response $res -Body @{ configured = $false; clientId = '' }
            return
        }
        if (-not $clientId -or -not $clientSecret) {
            Write-DuneError -Response $res -Status 400 -Message 'Both Client ID and Client Secret are required.'
            return
        }
        $saved = Save-DuneMobileServiceToken -ClientId $clientId -ClientSecret $clientSecret
        Write-DuneJson -Response $res -Body @{ configured = $true; clientId = $saved.clientId }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message "Save failed: $($_.Exception.Message)"
    }
}

Register-DuneRoute -Method GET -Path '/api/remote-access/audit-log' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $lines = 50
        try {
            if ($req -and $req.QueryString -and $req.QueryString['lines']) {
                $lines = [int]$req.QueryString['lines']
            }
        } catch {}
        $raw = Get-DuneRemoteAuditTail -Lines $lines
        $entries = @()
        foreach ($ln in @($raw)) {
            if (-not $ln) { continue }
            $parts = $ln -split "`t", 7
            $entries += @{
                ts     = if ($parts.Count -gt 0) { $parts[0] } else { '' }
                role   = if ($parts.Count -gt 1) { $parts[1] } else { '' }
                email  = if ($parts.Count -gt 2) { $parts[2] } else { '' }
                method = if ($parts.Count -gt 3) { $parts[3] } else { '' }
                path   = if ($parts.Count -gt 4) { $parts[4] } else { '' }
                status = if ($parts.Count -gt 5) { $parts[5] } else { '' }
                note   = if ($parts.Count -gt 6) { $parts[6] } else { '' }
                raw    = $ln
            }
        }
        Write-DuneJson -Response $res -Body @{ entries = $entries; count = $entries.Count }
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}

Register-DuneRoute -Method GET -Path '/api/remote-access/cloudflared-status' -Handler {
    param($req, $res, $routeParams, $body)
    try {
        $status = Test-DuneCloudflaredPresent
        Write-DuneJson -Response $res -Body $status
    } catch {
        Write-DuneError -Response $res -Status 500 -Message $_.Exception.Message
    }
}
