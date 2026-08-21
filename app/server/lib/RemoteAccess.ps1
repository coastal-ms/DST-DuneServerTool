# RemoteAccess.ps1 — Cloudflare-Access-gated remote portal subset (issue #74).
#
# DST today is loopback + per-launch DuneToken. The remote portal lets the host and
# 1..3 trusted admins reach a mobile-friendly read+safe-write subset via a
# Cloudflare Tunnel + Cloudflare Access policy. This file owns:
#
#   * The ACL file (%APPDATA%\DuneServer\remote-acl.json) — schema:
#       { "owner": "you@example.com", "admins": ["friend@example", ...] }
#     Empty "owner" == remote portal disabled (fail-closed).
#
#   * The middleware (Test-DuneRemoteRequest) called by the listener for any
#     /api/remote/* or /remote/* path BEFORE route matching. Validates the
#     signed Cloudflare Access JWT (issuer, audience, lifetime, signature),
#     then applies the email ACL and returns an email + role or a denial.
#
#   * The audit log (%APPDATA%\DuneServer\.logs\remote-audit.log) — one line
#     per write attempt (success or failure) and one line per auth denial,
#     so revoking a misbehaving admin is a single Settings-card edit.
#
# Public functions:
#   Get-DuneRemoteAclPath
#   Get-DuneRemoteAcl                    -> hashtable {owner; admins[]}
#   Save-DuneRemoteAcl -Acl <ht>         atomic write (temp + Move-Item -Force)
#   Get-DuneRemoteRole -Email <e>        -> 'owner' | 'admin' | $null
#   Test-DuneRemoteRequest -Request <r>  -> @{ok=$true; email; role}
#                                          | @{ok=$false; status; message}
#   Write-DuneRemoteAudit -Role -Email -Method -Path -Status [-Note]
#   Get-DuneRemoteAuditTail -Lines N     -> string[] last N lines (newest last)
#   Test-DuneCloudflaredPresent          -> @{installed; path; version}
#
# Isolation guarantee (see plan.md): this file is intentionally NOT imported
# anywhere — every lib/*.ps1 is dot-sourced into every API-pool runspace by
# Initialize-DuneApiPool, so any function is reachable from any handler.
# The real isolation boundary is the dispatcher prefix in Invoke-DuneContext
# plus the code-review rule that routes/Remote.ps1 calls only the allow-list
# of helpers documented in plan.md.

# ---------- Paths ------------------------------------------------------------

function Get-DuneRemoteAclPath {
    $dir = Join-Path $env:APPDATA 'DuneServer'
    return (Join-Path $dir 'remote-acl.json')
}

function Get-DuneRemoteAuditLogPath {
    $dir = Join-Path $env:APPDATA 'DuneServer\.logs'
    return (Join-Path $dir 'remote-audit.log')
}

function Get-DuneMobileServiceTokenPath {
    $dir = Join-Path $env:APPDATA 'DuneServer'
    return (Join-Path $dir 'mobile-service-token.json')
}

# ---------- Mobile Cloudflare Access service token ---------------------------
#
# The mobile app reaches the stable custom domain (which sits behind Cloudflare
# Access) by sending a Cloudflare Access SERVICE TOKEN — a non-interactive
# Client ID + Client Secret pair the host creates in the Cloudflare Zero Trust
# dashboard. The app sends them as CF-Access-Client-Id / CF-Access-Client-Secret
# headers; Cloudflare validates them at the edge and lets the request through to
# the tunnel without an email login. DST itself still gates on the per-launch
# DuneToken, so the service token only proves "this request is allowed past the
# Access gate" — it is NOT a DST credential.
#
# Stored locally in %APPDATA%\DuneServer\mobile-service-token.json. The secret
# is a Cloudflare credential, not a DST one, but it is still sensitive: it is
# handed to the phone via the pairing QR and is never returned by the GET route
# (only a `configured` flag + the non-secret Client ID).

# Returns @{ clientId=''; clientSecret='' }. Never writes to disk; a missing or
# malformed file yields the empty default so callers don't have to nil-check.
function Get-DuneMobileServiceToken {
    $default = @{ clientId = ''; clientSecret = '' }
    $path = Get-DuneMobileServiceTokenPath
    if (-not (Test-Path -LiteralPath $path)) { return $default }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        try {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "mobile-service-token.json malformed; ignored. $($_.Exception.Message)" 'WARN'
            }
        } catch {}
        return $default
    }
    $clientId = ''
    if ($obj.PSObject.Properties.Name -contains 'clientId' -and $obj.clientId) {
        $clientId = ([string]$obj.clientId).Trim()
    }
    $clientSecret = ''
    if ($obj.PSObject.Properties.Name -contains 'clientSecret' -and $obj.clientSecret) {
        $clientSecret = ([string]$obj.clientSecret).Trim()
    }
    return @{ clientId = $clientId; clientSecret = $clientSecret }
}

# Atomic write (temp + Move-Item -Force), same crash-safety pattern as the ACL.
function Save-DuneMobileServiceToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ClientSecret
    )
    $out = [ordered]@{
        clientId     = $ClientId.Trim()
        clientSecret = $ClientSecret.Trim()
    }
    $path = Get-DuneMobileServiceTokenPath
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$path.tmp"
    $json = ($out | ConvertTo-Json -Depth 4)
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $out
}

# Remove the stored service token (disables stable-domain app access; pairing
# then falls back to the quick tunnel). Idempotent.
function Clear-DuneMobileServiceToken {
    $path = Get-DuneMobileServiceTokenPath
    try {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    } catch {}
}

# ---------- ACL --------------------------------------------------------------

# Returns a hashtable {owner=''; admins=@()} even when the file is missing or
# unreadable so callers don't have to nil-check. NEVER writes to disk — a
# malformed file deliberately stays untouched so a transient parse error can't
# silently nuke the allowlist.
function Get-DuneRemoteAcl {
    $default = @{ owner = ''; admins = @(); hostname = ''; cloudflareTeamDomain = ''; cloudflareAudience = '' }
    $path = Get-DuneRemoteAclPath
    if (-not (Test-Path -LiteralPath $path)) { return $default }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Malformed JSON → fail closed without touching the file. The caller
        # (middleware) will deny the request; Get-DuneRemoteAuditTail still
        # works on the (separate) audit log so the operator can investigate.
        try {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "remote-acl.json malformed; remote portal denied. $($_.Exception.Message)" 'WARN'
            }
        } catch {}
        return $default
    }

    $owner = ''
    if ($obj.PSObject.Properties.Name -contains 'owner' -and $obj.owner) {
        $owner = ([string]$obj.owner).Trim().ToLowerInvariant()
    }
    $admins = @()
    if ($obj.PSObject.Properties.Name -contains 'admins' -and $obj.admins) {
        foreach ($a in @($obj.admins)) {
            $norm = ([string]$a).Trim().ToLowerInvariant()
            if ($norm) { $admins += $norm }
        }
        $admins = $admins | Select-Object -Unique
    }
    $hostname = ''
    if ($obj.PSObject.Properties.Name -contains 'hostname' -and $obj.hostname) {
        $hostname = ([string]$obj.hostname).Trim()
    }
    $team = ''
    if ($obj.PSObject.Properties.Name -contains 'cloudflareTeamDomain' -and $obj.cloudflareTeamDomain) {
        $team = ([string]$obj.cloudflareTeamDomain).Trim().ToLowerInvariant()
        $team = $team -replace '^https?://', '' -replace '/.*$', ''
    }
    $audience = ''
    if ($obj.PSObject.Properties.Name -contains 'cloudflareAudience' -and $obj.cloudflareAudience) {
        $audience = ([string]$obj.cloudflareAudience).Trim()
    }
    return @{ owner = $owner; admins = @($admins); hostname = $hostname; cloudflareTeamDomain = $team; cloudflareAudience = $audience }
}

# Atomic write: temp + Move-Item -Force. A SIGKILL between Set-Content and
# Move-Item leaves the previous ACL intact (instead of half-written / empty),
# so a crash can never silently lock the owner out.
function Save-DuneRemoteAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Acl)

    $owner = ''
    if ($Acl.ContainsKey('owner') -and $Acl.owner) {
        $owner = ([string]$Acl.owner).Trim().ToLowerInvariant()
    }
    $admins = @()
    if ($Acl.ContainsKey('admins') -and $Acl.admins) {
        foreach ($a in @($Acl.admins)) {
            $norm = ([string]$a).Trim().ToLowerInvariant()
            if ($norm) { $admins += $norm }
        }
        $admins = @($admins | Select-Object -Unique)
    }
    $hostname = ''
    if ($Acl.ContainsKey('hostname') -and $Acl.hostname) {
        $hostname = ([string]$Acl.hostname).Trim()
    }
    $team = ''
    if ($Acl.ContainsKey('cloudflareTeamDomain') -and $Acl.cloudflareTeamDomain) {
        $team = ([string]$Acl.cloudflareTeamDomain).Trim().ToLowerInvariant()
        $team = $team -replace '^https?://', '' -replace '/.*$', ''
    }
    $audience = ''
    if ($Acl.ContainsKey('cloudflareAudience') -and $Acl.cloudflareAudience) {
        $audience = ([string]$Acl.cloudflareAudience).Trim()
    }

    $out = [ordered]@{
        owner = $owner
        admins = $admins
        hostname = $hostname
        cloudflareTeamDomain = $team
        cloudflareAudience = $audience
    }

    $path = Get-DuneRemoteAclPath
    $dir  = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = "$path.tmp"
    $json = ($out | ConvertTo-Json -Depth 4)
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $out
}

function Get-DuneRemoteRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Email)
    $e = $Email.Trim().ToLowerInvariant()
    if (-not $e) { return $null }
    $acl = Get-DuneRemoteAcl
    if (-not $acl.owner) { return $null }       # remote disabled
    if ($e -eq $acl.owner) { return 'owner' }
    if ($acl.admins -contains $e) { return 'admin' }
    return $null
}

function ConvertFrom-DuneBase64Url {
    param([Parameter(Mandatory)][string]$Value)
    $s = $Value.Replace('-', '+').Replace('_', '/')
    while (($s.Length % 4) -ne 0) { $s += '=' }
    return [Convert]::FromBase64String($s)
}

function Get-DuneCloudflareCertificate {
    param([string]$TeamDomain, [string]$Kid)
    if (-not $script:DuneCloudflareCertCache) { $script:DuneCloudflareCertCache = @{} }
    $cacheKey = "$TeamDomain|$Kid"
    $cached = $script:DuneCloudflareCertCache[$cacheKey]
    if ($cached -and $cached.expires -gt (Get-Date).ToUniversalTime()) { return $cached.cert }

    $uri = "https://$TeamDomain/cdn-cgi/access/certs"
    $document = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 10 -UseBasicParsing
    $entry = @($document.public_certs | Where-Object { [string]$_.kid -eq $Kid } | Select-Object -First 1)[0]
    if (-not $entry -or -not $entry.cert) { return $null }
    $base64 = ([string]$entry.cert) -replace '-----BEGIN CERTIFICATE-----', '' -replace '-----END CERTIFICATE-----', '' -replace '\s', ''
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,[Convert]::FromBase64String($base64))
    $script:DuneCloudflareCertCache[$cacheKey] = @{ cert = $cert; expires = (Get-Date).ToUniversalTime().AddHours(6) }
    return $cert
}

function Test-DuneCloudflareAccessJwt {
    param([Parameter(Mandatory)]$Request, [Parameter(Mandatory)][hashtable]$Acl)
    if (-not $Acl.cloudflareTeamDomain -or -not $Acl.cloudflareAudience) {
        return @{ ok = $false; message = 'Cloudflare Access JWT settings are incomplete.' }
    }
    if ([string]$Acl.cloudflareTeamDomain -notmatch '^[a-z0-9][a-z0-9-]*\.cloudflareaccess\.com$') {
        return @{ ok = $false; message = 'Cloudflare Access team domain is invalid.' }
    }
    $assertion = ''
    try { $assertion = [string]$Request.Headers['Cf-Access-Jwt-Assertion'] } catch {}
    if (-not $assertion) { return @{ ok = $false; message = 'Cloudflare Access assertion required.' } }
    try {
        $parts = $assertion.Split('.')
        if ($parts.Count -ne 3) { throw 'JWT shape' }
        $header = [Text.Encoding]::UTF8.GetString((ConvertFrom-DuneBase64Url $parts[0])) | ConvertFrom-Json
        $payload = [Text.Encoding]::UTF8.GetString((ConvertFrom-DuneBase64Url $parts[1])) | ConvertFrom-Json
        if ([string]$header.alg -ne 'RS256' -or -not $header.kid) { throw 'JWT algorithm' }
        $expectedIssuer = "https://$($Acl.cloudflareTeamDomain)"
        if (([string]$payload.iss).TrimEnd('/') -ne $expectedIssuer.TrimEnd('/')) { throw 'JWT issuer' }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ([long]$payload.exp -le $now -or ($payload.nbf -and [long]$payload.nbf -gt ($now + 60))) { throw 'JWT lifetime' }
        if (@($payload.aud) -notcontains [string]$Acl.cloudflareAudience) { throw 'JWT audience' }
        $email = ([string]$payload.email).Trim().ToLowerInvariant()
        if (-not $email) { throw 'JWT email' }
        $cert = Get-DuneCloudflareCertificate -TeamDomain ([string]$Acl.cloudflareTeamDomain) -Kid ([string]$header.kid)
        if (-not $cert) { throw 'JWT signing certificate' }
        $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
        try {
            $data = [Text.Encoding]::ASCII.GetBytes("$($parts[0]).$($parts[1])")
            $signature = ConvertFrom-DuneBase64Url $parts[2]
            $valid = $rsa.VerifyData(
                $data,
                $signature,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
            )
        } finally { if ($rsa) { $rsa.Dispose() } }
        if (-not $valid) { throw 'JWT signature' }
        return @{ ok = $true; email = $email }
    } catch {
        return @{ ok = $false; message = 'Cloudflare Access authentication failed.' }
    }
}

# ---------- Middleware -------------------------------------------------------

# Called by the listener BEFORE route matching for any /api/remote/* or
# /remote/* path. Returns:
#   @{ ok = $true;  email = '...'; role = 'owner'|'admin' }
#   @{ ok = $false; status = 401|403; message = '...' }
#
# Fail-closed cases (401, generic message — don't leak path validity):
#   * No valid Cf-Access-Jwt-Assertion header
#   * ACL missing or owner unset (remote disabled)
#   * ACL malformed (Get-DuneRemoteAcl returns the default)
# Forbidden case (403):
#   * Valid header but email not in owner+admins list
function Test-DuneRemoteRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request)

    $acl = Get-DuneRemoteAcl
    if (-not $acl.owner) {
        # Remote portal explicitly off (default for fresh installs). We deny
        # with 401 (not 403) so a misconfigured tunnel does not advertise
        # which paths are gated by which ACL.
        return @{ ok = $false; status = 401; message = 'Remote portal not enabled.' }
    }
    $identity = Test-DuneCloudflareAccessJwt -Request $Request -Acl $acl
    if (-not $identity.ok) {
        return @{ ok = $false; status = 401; message = 'Authentication required.' }
    }
    $email = [string]$identity.email

    if ($email -eq $acl.owner) {
        return @{ ok = $true; email = $email; role = 'owner' }
    }
    if ($acl.admins -contains $email) {
        return @{ ok = $true; email = $email; role = 'admin' }
    }
    return @{ ok = $false; status = 403; message = 'Not authorized for remote portal.' }
}

# ---------- Audit log --------------------------------------------------------

# Append a single line to %APPDATA%\DuneServer\.logs\remote-audit.log.
# Schema (tab-separated for easy splitting; UTC ISO-8601 timestamp):
#
#   2026-06-05T12:34:56Z\towner\tyou@example.com\tPOST\t/api/remote/maps/spin-up/deepdesert\t200\t<note>
#
# Note is optional — used by the listener to record the reason for an auth
# denial ('no-header', 'unknown-email', 'remote-disabled', 'pool-saturated').
function Write-DuneRemoteAudit {
    [CmdletBinding()]
    param(
        [string]$Role    = '',
        [string]$Email   = '',
        [string]$Method  = '',
        [string]$Path    = '',
        [int]   $Status  = 0,
        [string]$Note    = ''
    )

    $path = Get-DuneRemoteAuditLogPath
    $dir  = Split-Path -Parent $path
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # 1 MB rollover (same pattern as Initialize-DuneLog).
        if (Test-Path -LiteralPath $path) {
            $sz = (Get-Item -LiteralPath $path).Length
            if ($sz -gt 1MB) {
                $bak = "$path.old"
                if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
                Move-Item -LiteralPath $path -Destination $bak -Force
            }
        }
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $r  = if ($Role)   { $Role }   else { '-' }
        $e  = if ($Email)  { $Email }  else { '-' }
        $m  = if ($Method) { $Method } else { '-' }
        $p  = if ($Path)   { $Path }   else { '-' }
        $s  = if ($Status -gt 0) { $Status.ToString() } else { '-' }
        $n  = if ($Note)   { $Note }   else { '' }
        $line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}" -f $ts, $r, $e, $m, $p, $s, $n
        Add-Content -LiteralPath $path -Value $line -Encoding UTF8
    } catch {
        # Audit-log write failure must NOT take down the request — log to the
        # main DST log if available, otherwise swallow silently.
        try {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "remote-audit write failed: $($_.Exception.Message)" 'WARN'
            }
        } catch {}
    }
}

# Returns the last N lines of the audit log (newest LAST — same order as the
# file on disk) as an array of strings. Returns @() when the log is absent.
function Get-DuneRemoteAuditTail {
    [CmdletBinding()]
    param([int]$Lines = 50)
    if ($Lines -lt 1)   { $Lines = 1 }
    if ($Lines -gt 500) { $Lines = 500 }
    $path = Get-DuneRemoteAuditLogPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        return @(Get-Content -LiteralPath $path -Tail $Lines -Encoding UTF8 -ErrorAction Stop)
    } catch {
        return @()
    }
}

# ---------- cloudflared detection (status pill, NEVER runs it) ---------------

# The Settings card surfaces an "installed / not installed" pill so the user
# knows whether they still need to install cloudflared per the setup guide.
# We DELIBERATELY do not run `cloudflared --version` here — we resolve the
# command via Get-Command and read the file version off the .exe so we don't
# spawn a process every time Settings loads.
function Test-DuneCloudflaredPresent {
    $result = @{ installed = $false; path = ''; version = '' }
    try {
        $cmd = Get-Command 'cloudflared.exe' -ErrorAction SilentlyContinue
        if (-not $cmd) { $cmd = Get-Command 'cloudflared' -ErrorAction SilentlyContinue }
        if ($cmd -and $cmd.Source) {
            $result.installed = $true
            $result.path = $cmd.Source
            try {
                $vi = (Get-Item -LiteralPath $cmd.Source).VersionInfo
                if ($vi -and $vi.FileVersion) { $result.version = $vi.FileVersion }
            } catch {}
        }
    } catch {}
    return $result
}
