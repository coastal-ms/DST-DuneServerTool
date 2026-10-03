# Retired Cloudflare compatibility guards and retained local ACL metadata.
# Existing credential files are left untouched; no Cloudflare authentication or service-token delivery remains.

function Get-DuneRemoteAclPath {
    $dir = Join-Path $env:APPDATA 'DuneServer'
    return (Join-Path $dir 'remote-acl.json')
}

function Get-DuneRemoteAuditLogPath {
    $dir = Join-Path $env:APPDATA 'DuneServer\.logs'
    return (Join-Path $dir 'remote-audit.log')
}



# ---------- ACL --------------------------------------------------------------

# Returns a hashtable with a disabled legacy Cloudflare portal even when the
# file is missing or unreadable so callers don't have to nil-check. NEVER writes to disk — a
# malformed file deliberately stays untouched so a transient parse error can't
# silently nuke the allowlist.
function Get-DuneRemoteAcl {
    $default = @{ owner = ''; admins = @(); hostname = ''; cloudflareTeamDomain = ''; cloudflareAudience = ''; legacyCloudflareEnabled = $false }
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
    # Only a JSON boolean true can enable the retired Cloudflare portal. Older,
    # missing, or malformed fields deliberately remain disabled.
    $legacyCloudflareEnabled = ($obj.PSObject.Properties.Name -contains 'legacyCloudflareEnabled') -and
        ($obj.legacyCloudflareEnabled -is [bool]) -and $obj.legacyCloudflareEnabled
    return @{
        owner = $owner
        admins = @($admins)
        hostname = $hostname
        cloudflareTeamDomain = $team
        cloudflareAudience = $audience
        legacyCloudflareEnabled = [bool]$legacyCloudflareEnabled
    }
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
    $legacyCloudflareEnabled = $false
    if ($Acl.ContainsKey('legacyCloudflareEnabled')) {
        if ($Acl.legacyCloudflareEnabled -isnot [bool]) {
            throw 'legacyCloudflareEnabled must be a boolean.'
        }
        $legacyCloudflareEnabled = $Acl.legacyCloudflareEnabled
    }

    $out = [ordered]@{
        owner = $owner
        admins = $admins
        hostname = $hostname
        cloudflareTeamDomain = $team
        cloudflareAudience = $audience
        legacyCloudflareEnabled = [bool]$legacyCloudflareEnabled
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

function Test-DuneLegacyCloudflarePortalEnabled { return $false }







function Test-DuneCloudflareAccessJwt { param($Request, $Acl) return @{ ok = $false; message = 'Cloudflare authentication has been retired.' } }

# ---------- Middleware -------------------------------------------------------

# Called by the listener BEFORE route matching for any /api/remote/* or
# /remote/* path. Returns:
#   @{ ok = $true;  email = '...'; role = 'owner'|'admin' }
#   @{ ok = $false; status = 401|403; message = '...' }
#
# Fail-closed cases (401, generic message — don't leak path validity):
#   * No valid Cf-Access-Jwt-Assertion header
#   * ACL missing, malformed, or not explicitly enabled for v15
#   * ACL owner unset
#   * ACL malformed (Get-DuneRemoteAcl returns the default)
# Forbidden case (403):
#   * Valid header but email not in owner+admins list
function Test-DuneRemoteRequest { param($Request) return @{ ok = $false; status = 401; message = 'Legacy Cloudflare remote access has been retired. Use the Browser Portal over Tailscale.' } }

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
