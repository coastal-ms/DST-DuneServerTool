# Rendezvous.ps1 -- zero-config remote identity + address publishing.
#
# Makes the mobile app "scan once, works forever" even though the free quick
# tunnel hands out a new https://<random>.trycloudflare.com URL on every restart.
#
# Three local, persistent secrets (created once, in %APPDATA%\DuneServer\
# remote-identity.json) decouple the phone from the changing address:
#
#   pairingId   -- stable, random public-ish id. The vendor rendezvous Worker
#                  maps it to the CURRENT tunnel URL. Put in the pairing QR.
#   publishKey  -- write secret. DST proves ownership of pairingId when it
#                  publishes a new URL (the Worker stores only sha256(publishKey)).
#                  Never leaves this PC.
#   remoteToken -- PERMANENT DST API token for remote callers. The per-launch
#                  DuneToken rotates every start (which is why a paired phone
#                  breaks on reboot today); this one is stable, so the phone keeps
#                  working across restarts. Delivered to the phone via the QR.
#
# The rendezvous Worker stores NO credentials -- only pairingId -> URL. A leaked
# or compromised rendezvous therefore exposes only a tunnel URL, which is useless
# without the remoteToken (DST rejects every /api/* call that lacks it).

# Vendor-run shared rendezvous. Overridable for forks via the DUNE_RENDEZVOUS_BASE
# env var or a RendezvousBase config key, but this default serves all hosts.
$script:DuneRendezvousDefaultBase = 'https://dst-rendezvous.dstdune.workers.dev'

function Get-DuneRendezvousBase {
    if ($env:DUNE_RENDEZVOUS_BASE) { return ([string]$env:DUNE_RENDEZVOUS_BASE).TrimEnd('/') }
    try {
        if (Get-Command Read-DuneConfig -ErrorAction SilentlyContinue) {
            $cfg = Read-DuneConfig
            if ($cfg -and $cfg.RendezvousBase) { return ([string]$cfg.RendezvousBase).TrimEnd('/') }
        }
    } catch {}
    return $script:DuneRendezvousDefaultBase
}

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
# @{ pairingId; publishKey; remoteToken }. The result is stable across launches.
function Get-DuneRemoteIdentity {
    $path = Get-DuneRemoteIdentityPath
    if (Test-Path -LiteralPath $path) {
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($obj.pairingId -and $obj.publishKey -and $obj.remoteToken) {
                    return @{
                        pairingId   = [string]$obj.pairingId
                        publishKey  = [string]$obj.publishKey
                        remoteToken = [string]$obj.remoteToken
                    }
                }
            }
        } catch {}
    }
    # Generate fresh and persist atomically (temp + Move-Item -Force).
    $identity = @{
        pairingId   = (New-DuneRandomToken -Bytes 16)   # ~22 chars
        publishKey  = (New-DuneRandomToken -Bytes 32)    # ~43 chars
        remoteToken = (New-DuneRandomToken -Bytes 32)    # ~43 chars
    }
    try {
        $tmp = "$path.tmp"
        ([ordered]@{
            pairingId   = $identity.pairingId
            publishKey  = $identity.publishKey
            remoteToken = $identity.remoteToken
            createdAt   = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $tmp -Encoding UTF8 -Force
        Move-Item -LiteralPath $tmp -Destination $path -Force
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Rendezvous: failed to persist remote identity: $($_.Exception.Message)" 'WARN'
        }
    }
    return $identity
}

# Just the permanent remote API token (used by Test-DuneToken to accept the phone).
function Get-DuneRemoteToken {
    try { return (Get-DuneRemoteIdentity).remoteToken } catch { return '' }
}

# Publish the CURRENT remote URL to the rendezvous so the phone can find this
# server by its stable pairingId. Best-effort: short timeout, never throws into
# the caller (tunnel start must not fail because the rendezvous is briefly down).
# Returns @{ ok; error? }.
function Publish-DuneRendezvous {
    param([Parameter(Mandatory)][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return @{ ok = $false; error = 'no url' } }
    try {
        $id = Get-DuneRemoteIdentity
        $base = Get-DuneRendezvousBase
        $body = @{ id = $id.pairingId; publishKey = $id.publishKey; url = $Url.TrimEnd('/') } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Method POST -Uri "$base/publish" -Body $body -ContentType 'application/json' -TimeoutSec 8 -ErrorAction Stop
        if ($resp -and $resp.ok) {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "Rendezvous: published $Url for id $($id.pairingId)"
            }
            return @{ ok = $true }
        }
        return @{ ok = $false; error = 'rendezvous rejected publish' }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "Rendezvous: publish failed: $($_.Exception.Message)" 'WARN'
        }
        return @{ ok = $false; error = $_.Exception.Message }
    }
}
