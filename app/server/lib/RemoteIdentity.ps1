# RemoteIdentity.ps1 -- persistent remote identity for the mobile app / browser
# portal over a stable public transport (Tailscale Funnel, or a Cloudflare
# named-tunnel + Access custom domain).
#
# Two local, persistent secrets live in %APPDATA%\DuneServer\remote-identity.json:
#
#   pairingId   -- stable, random public-ish id (kept for compatibility with
#                  already-paired devices; harmless if unused).
#   remoteToken -- PERMANENT DST API token for remote callers. The per-launch
#                  DuneToken rotates every start (which is why a paired phone
#                  would otherwise break on reboot); this one is stable, so the
#                  phone keeps working across restarts. Delivered to the phone
#                  via the pairing QR ({ url, token }).
#
# (The earlier anonymous Cloudflare quick-tunnel + rendezvous publishing was
# retired -- it proved unreliable; Tailscale Funnel and the named-tunnel domain
# give a STABLE url so no rendezvous indirection is needed. The permanent
# remoteToken below is the piece that path carried and that Funnel auth needs,
# so it is retained here.)

function Get-DuneRemoteIdentityPath {
    $dir = Join-Path $env:APPDATA 'DuneServer'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return (Join-Path $dir 'remote-identity.json')
}

# Cryptographically-random bytes -> URL-safe base64 (no padding). Worker ids/keys
# match [A-Za-z0-9_-]. Uses RandomNumberGenerator.Create().GetBytes so it works on
# BOTH Windows PowerShell 5.1 (.NET Framework, which has no RandomNumberGenerator.Fill)
# and PowerShell 7+.
function New-DuneRandomToken {
    param([int]$Bytes = 32)
    $buf = [byte[]]::new($Bytes)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buf) } finally { $rng.Dispose() }
    $b64 = [Convert]::ToBase64String($buf)
    return ($b64 -replace '\+','-' -replace '/','_' -replace '=','')
}

# Read the persisted identity, generating + saving it on first use. Returns
# @{ pairingId; remoteToken }. The result is stable across launches. Existing
# remote-identity.json files (which also carry a legacy publishKey) are read as-is
# so already-paired devices keep their remoteToken.
function Get-DuneRemoteIdentity {
    $path = Get-DuneRemoteIdentityPath
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($obj.pairingId -and $obj.remoteToken) {
                    return @{
                        pairingId   = [string]$obj.pairingId
                        remoteToken = [string]$obj.remoteToken
                    }
                }
            }
        } catch {}
    }
    # Generate fresh and persist atomically (temp + Move-Item -Force).
    $identity = @{
        pairingId   = (New-DuneRandomToken -Bytes 16)   # ~22 chars
        remoteToken = (New-DuneRandomToken -Bytes 32)    # ~43 chars
    }
    try {
        $tmp = "$path.tmp"
        ([ordered]@{
            pairingId   = $identity.pairingId
            remoteToken = $identity.remoteToken
            createdAt   = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $tmp -Encoding UTF8 -Force
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "RemoteIdentity: failed to persist remote identity: $($_.Exception.Message)" 'WARN'
        }
    }
    return $identity
}

# Just the permanent remote API token (used by Test-DuneToken to accept the phone).
function Get-DuneRemoteToken {
    try { return (Get-DuneRemoteIdentity).remoteToken } catch { return '' }
}

