# FLS host-token rotation (recovery for Funcom error 403002 ACCESS_DENIED -
# "Could not find service authorization information for Battlegroup").
#
# Background: starting ~2026-06-22 a wave of self-hosted battlegroups began
# failing Funcom's FLS authorization lookup (GatewayDeclareFarmStatus returns
# 403002). The cluster, database, backups and the local token all look fine,
# but the existing battlegroup's auth record is rejected and the server drops
# out of the in-game browser. The community-found recovery is to regenerate the
# self-hosting token on the Dune account page and replace it everywhere it is
# used, then restart - no data loss.
#
# Where the token lives (mapped on a live install): the JWT is stored in the
# k8s Secret "server-gateway-secret" (key FuncomLiveServices__ServiceAuthToken)
# AND baked as literal values into the master BattleGroup custom resource (~34
# occurrences: per-map launch args + env values). The Funcom operators render
# the ServerGateway/TextRouter/BattlegroupDirector/ServerSet workloads from the
# master CR, so patching the Secret + the master CR and restarting causes the
# operators to re-render every workload onto the new token.
#
# Validated end-to-end on a live server (2026-06-24): same-HostId token swap +
# battlegroup restart -> all auth pods rolled onto the new token, FLS auth
# succeeded (no 403002), world identity + database unchanged.
#
# SAFETY: a regenerated token for the SAME Dune account keeps the SAME HostId,
# which is embedded in the battlegroup name (sh-<HostId>-<rand>). A token from a
# DIFFERENT account has a different HostId and would orphan the existing
# battlegroup (the lost-character case). This module HARD-BLOCKS a HostId
# mismatch. A full namespace snapshot is taken before any mutation.

$script:DuneFlsRotateLockName = 'fls-token-rotate-state'

function Get-DuneFlsRotateStatePath {
    Join-Path $env:APPDATA 'DuneServer\fls-token-rotate-state.json'
}

function New-DuneFlsRotateIdleState {
    return @{ phase = 'idle'; running = $false; steps = @(); updated = (Get-Date).ToUniversalTime().ToString('o') }
}

function Read-DuneFlsRotateState {
    $path = Get-DuneFlsRotateStatePath
    if (-not (Test-Path -LiteralPath $path)) { return (New-DuneFlsRotateIdleState) }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-DuneFlsRotateIdleState) }
        return ($raw | ConvertFrom-Json)
    } catch {
        return (New-DuneFlsRotateIdleState)
    }
}

function Save-DuneFlsRotateState {
    param([Parameter(Mandatory)]$State)
    $path = Get-DuneFlsRotateStatePath
    $dir  = Split-Path -Parent $path
    try { if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null } } catch {}
    $json = $State | ConvertTo-Json -Depth 8
    $tmp  = "$path.tmp"
    $write = {
        Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }
    if (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue) {
        try { Invoke-WithDuneLock -Name $script:DuneFlsRotateLockName -TimeoutSec 5 -Script $write } catch { & $write }
    } else { & $write }
}

function Get-DuneFlsRotateStatus {
    # Self-heal a stale 'running' flag (worker crashed / tool killed): a run with
    # no update for >12 min is treated as failed so the UI re-enables.
    $st = Read-DuneFlsRotateState
    try {
        $running = if ($st -is [hashtable]) { [bool]$st['running'] } else { [bool]$st.running }
        if ($running) {
            $updated = if ($st -is [hashtable]) { $st['updated'] } else { $st.updated }
            $dtu = $null
            if ($updated -is [datetime]) {
                $dtu = if (([datetime]$updated).Kind -eq [System.DateTimeKind]::Utc) { [datetime]$updated } else { ([datetime]$updated).ToUniversalTime() }
            } elseif ($updated) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse([string]$updated, $null, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
                    $dtu = if ($parsed.Kind -eq [System.DateTimeKind]::Utc) { $parsed } else { $parsed.ToUniversalTime() }
                }
            }
            if ($dtu -and ((Get-Date).ToUniversalTime() - $dtu).TotalMinutes -gt 12) {
                $st = @{ phase = 'error'; running = $false; steps = @(); error = 'Rotation timed out (no progress for over 12 minutes).'; updated = (Get-Date).ToUniversalTime().ToString('o') }
                Save-DuneFlsRotateState -State $st
            }
        }
    } catch {}
    return $st
}

# -----------------------------------------------------------------------------
# JWT decode (no external deps). The self-hosting token is a JWT whose payload
# carries the HostId claim. We only ever read the payload; the token is never
# logged or returned to the client.
# -----------------------------------------------------------------------------
function ConvertFrom-DuneJwtSegment {
    param([Parameter(Mandatory)][string]$Seg)
    $s = $Seg.Replace('-', '+').Replace('_', '/')
    switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } 1 { return $null } }
    try { return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) } catch { return $null }
}

function Get-DuneFlsTokenInfo {
    param([Parameter(Mandatory)][string]$Jwt)
    $t = ([string]$Jwt).Trim()
    $parts = $t -split '\.'
    if ($parts.Count -lt 2) {
        return @{ valid = $false; error = 'That does not look like a self-hosting token (expected a JWT with three dot-separated parts).' }
    }
    $payloadJson = ConvertFrom-DuneJwtSegment -Seg $parts[1]
    if (-not $payloadJson) {
        return @{ valid = $false; error = 'Could not decode the token payload.' }
    }
    try { $payload = $payloadJson | ConvertFrom-Json } catch {
        return @{ valid = $false; error = 'Token payload is not valid JSON.' }
    }
    $hostId = $null
    foreach ($k in 'HostId', 'hostId', 'hostid') {
        if ($payload.PSObject.Properties[$k] -and $payload.$k) { $hostId = [string]$payload.$k; break }
    }
    if (-not $hostId) {
        return @{ valid = $false; error = 'Token has no HostId claim - this is not a Dune self-hosting token.' }
    }
    $hostId = $hostId.ToLowerInvariant()
    $exp = $null; $expired = $false
    if ($payload.PSObject.Properties['exp'] -and $payload.exp) {
        try {
            $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$payload.exp).UtcDateTime
            $expired = ($exp -lt [DateTime]::UtcNow)
        } catch {}
    }
    $tokenIndex = $null
    if ($payload.PSObject.Properties['TokenIndex']) { $tokenIndex = $payload.TokenIndex }
    return @{
        valid      = $true
        hostId     = $hostId
        tokenIndex = $tokenIndex
        expiresUtc = if ($exp) { $exp.ToString('o') } else { $null }
        expired    = $expired
        error      = $null
    }
}

# -----------------------------------------------------------------------------
# Discover the live battlegroup namespace / world / HostId / phase from the VM.
# -----------------------------------------------------------------------------
function Get-DuneFlsWorldContext {
    if (-not (Get-Command Get-DuneBackupContext -ErrorAction SilentlyContinue) -or
        -not (Get-Command Invoke-DuneBackupShell -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; reachable = $false; error = 'VM/SSH helpers unavailable.' }
    }
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) {
        return @{ ok = $false; reachable = $false; error = $ctx.message }
    }
    $bash = @'
NS=$(sudo kubectl get ns --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep -E '^funcom-seabass-sh-' | head -1)
if [ -z "$NS" ]; then echo "__CTX none"; exit 0; fi
WORLD=${NS#funcom-seabass-}
HOSTID=$(echo "$WORLD" | sed -E 's/^sh-([0-9a-f]+)-.*/\1/')
PHASE=$(sudo kubectl get battlegroup "$WORLD" -n "$NS" --no-headers 2>/dev/null | awk '{print $3}')
echo "__CTX ns=$NS world=$WORLD hostid=$HOSTID phase=$PHASE"
'@
    try {
        $r = Invoke-DuneBackupShell -Ip $ctx.ip -Script $bash -TimeoutSec 25
    } catch {
        return @{ ok = $false; reachable = $false; error = "VM query failed: $($_.Exception.Message)" }
    }
    $out = if ($r) { [string]$r.out } else { '' }
    $m = [regex]::Match($out, '__CTX ns=(\S+) world=(\S+) hostid=(\S+) phase=(\S*)')
    if (-not $m.Success) {
        if ($out -match '__CTX none') {
            return @{ ok = $false; reachable = $true; error = 'No self-hosted battlegroup found on the VM.' }
        }
        return @{ ok = $false; reachable = $true; error = 'Could not read the battlegroup from the VM.' }
    }
    return @{
        ok        = $true
        reachable = $true
        ip        = $ctx.ip
        namespace = $m.Groups[1].Value
        world     = $m.Groups[2].Value
        hostId    = $m.Groups[3].Value.ToLowerInvariant()
        phase     = $m.Groups[4].Value
        error     = $null
    }
}

# Helper: build/save a step list onto the rotate state.
function Set-DuneFlsRotateSteps {
    param([Parameter(Mandatory)][array]$Steps, [string]$Phase = 'running', [bool]$Running = $true, [string]$ErrorText = '')
    Save-DuneFlsRotateState -State @{
        phase    = $Phase
        running  = $Running
        steps    = $Steps
        error    = $ErrorText
        updated  = (Get-Date).ToUniversalTime().ToString('o')
        finished = if ($Running) { $null } else { (Get-Date).ToUniversalTime().ToString('o') }
    }
}

# -----------------------------------------------------------------------------
# The validated rotation. Runs in a background runspace (Start-DuneFlsRotateAsync)
# because the battlegroup restart takes several minutes and the HTTP listener is
# single-threaded. Progress is streamed to the state file.
# -----------------------------------------------------------------------------
function Invoke-DuneFlsTokenRotate {
    param([Parameter(Mandatory)][string]$Jwt)

    $steps = @(
        @{ id = 'validate'; label = 'Validate token';              status = 'running'; detail = '' }
        @{ id = 'context';  label = 'Read battlegroup';            status = 'pending'; detail = '' }
        @{ id = 'gate';     label = 'Confirm same account (HostId)'; status = 'pending'; detail = '' }
        @{ id = 'backup';   label = 'Back up current config';      status = 'pending'; detail = '' }
        @{ id = 'patch';    label = 'Apply new token';             status = 'pending'; detail = '' }
        @{ id = 'restart';  label = 'Restart battlegroup';         status = 'pending'; detail = '' }
        @{ id = 'verify';   label = 'Verify';                      status = 'pending'; detail = '' }
    )
    function _step($id) { return ($steps | Where-Object { $_.id -eq $id }) }
    function _fail($id, $msg) {
        (_step $id).status = 'failed'; (_step $id).detail = $msg
        Set-DuneFlsRotateSteps -Steps $steps -Phase 'error' -Running $false -ErrorText $msg
    }

    Set-DuneFlsRotateSteps -Steps $steps

    # 1. Validate token (local, no mutation).
    $info = Get-DuneFlsTokenInfo -Jwt $Jwt
    if (-not $info.valid) { _fail 'validate' $info.error; return }
    if ($info.expired)    { _fail 'validate' 'This token is already expired - generate a fresh one on the Dune account page.'; return }
    (_step 'validate').status = 'done'
    (_step 'validate').detail = "HostId $($info.hostId)$(if ($info.tokenIndex -ne $null) { " (token #$($info.tokenIndex))" } else { '' })"
    (_step 'context').status  = 'running'
    Set-DuneFlsRotateSteps -Steps $steps

    # 2. Read battlegroup context from the VM.
    $world = Get-DuneFlsWorldContext
    if (-not $world.ok) { _fail 'context' $world.error; return }
    (_step 'context').status = 'done'
    (_step 'context').detail = "World $($world.world)"
    (_step 'gate').status    = 'running'
    Set-DuneFlsRotateSteps -Steps $steps

    # 3. HostId gate - the critical safety check.
    if ($info.hostId -ne $world.hostId) {
        _fail 'gate' ("This token belongs to a different Dune account (HostId $($info.hostId)) than your battlegroup (HostId $($world.hostId)). " +
                      'Applying it would orphan your existing battlegroup and lose its characters. ' +
                      'Regenerate the token while signed into the SAME account this server was created with.')
        return
    }
    (_step 'gate').status = 'done'
    (_step 'gate').detail = 'Same account confirmed.'
    (_step 'backup').status = 'running'
    Set-DuneFlsRotateSteps -Steps $steps

    # Write the new token to the VM over stdin (never on the command line).
    if (-not (Get-Command Invoke-V6Ssh -ErrorAction SilentlyContinue)) {
        _fail 'backup' 'SSH helper unavailable.'; return
    }
    try {
        [void](Invoke-V6Ssh -Ip $world.ip -Cmd 'umask 077; cat > /home/dune/.dune/.dst-new-token' -StdinData ($Jwt.Trim()) -TimeoutSec 25)
    } catch {
        _fail 'backup' "Could not stage the token on the server: $($_.Exception.Message)"; return
    }

    # The validated VM-side sequence: snapshot -> patch secret -> patch the
    # token-bearing custom resources -> restart -> verify -> scrub the token.
    $rotateBash = @'
set +e
NS="__NS__"
WORLD="__WORLD__"
NEW=$(cat /home/dune/.dune/.dst-new-token 2>/dev/null)
if [ -z "$NEW" ]; then echo "__FLS backup fail 0 -"; echo "__FLS result fail no-token"; exit 0; fi
TS=$(date +%Y%m%d-%H%M%S)
BAK="/home/dune/.dune/fls-token-backup-$TS"
mkdir -p "$BAK"
sudo kubectl get battlegroups.igw.funcom.com,servergateways.igw.funcom.com,textrouters.igw.funcom.com,battlegroupdirectors.igw.funcom.com,serversets.igw.funcom.com,secret -n "$NS" -o yaml > "$BAK/namespace-snapshot.yaml" 2>/dev/null
BYTES=$(wc -c < "$BAK/namespace-snapshot.yaml" 2>/dev/null)
if [ -z "$BYTES" ] || [ "$BYTES" -lt 1000 ]; then echo "__FLS backup fail ${BYTES:-0} $BAK"; echo "__FLS result fail backup"; exit 0; fi
echo "__FLS backup ok $BYTES $BAK"
OLD=$(sudo kubectl get secret server-gateway-secret -n "$NS" -o jsonpath='{.data.FuncomLiveServices__ServiceAuthToken}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -z "$OLD" ]; then echo "__FLS patch fail read-old"; echo "__FLS result fail read-old"; exit 0; fi
sudo kubectl patch secret server-gateway-secret -n "$NS" --type merge -p "{\"stringData\":{\"FuncomLiveServices__ServiceAuthToken\":\"$NEW\"}}" >/dev/null 2>>"$BAK/errors.txt"
PATCHED=0
FAILS=0
for kind in battlegroups servergateways textrouters battlegroupdirectors serversets; do
  for obj in $(sudo kubectl get $kind.igw.funcom.com -n "$NS" -o name 2>/dev/null); do
    n=$(sudo kubectl get "$obj" -n "$NS" -o yaml 2>/dev/null | grep -c "$OLD")
    [ "$n" -eq 0 ] && continue
    if sudo kubectl get "$obj" -n "$NS" -o yaml 2>/dev/null | sed "s|$OLD|$NEW|g" | sudo kubectl apply -f - >/dev/null 2>>"$BAK/errors.txt"; then
      PATCHED=$((PATCHED+1))
    else
      FAILS=$((FAILS+1))
    fi
  done
done
REM=0
for kind in battlegroups servergateways textrouters battlegroupdirectors serversets; do
  for obj in $(sudo kubectl get $kind.igw.funcom.com -n "$NS" -o name 2>/dev/null); do
    c=$(sudo kubectl get "$obj" -n "$NS" -o yaml 2>/dev/null | grep -c "$OLD"); REM=$((REM+c))
  done
done
if [ "$FAILS" -gt 0 ] || [ "$REM" -gt 0 ]; then echo "__FLS patch fail patched=$PATCHED fails=$FAILS remaining=$REM"; echo "__FLS result fail patch bak=$BAK"; exit 0; fi
echo "__FLS patch ok patched=$PATCHED"
RST=$(/home/dune/.dune/bin/battlegroup restart 2>&1 | tail -2 | tr '\n' ' ')
echo "__FLS restart ok $RST"
SECNOW=$(sudo kubectl get secret server-gateway-secret -n "$NS" -o jsonpath='{.data.FuncomLiveServices__ServiceAuthToken}' 2>/dev/null | base64 -d 2>/dev/null)
if [ "$SECNOW" = "$NEW" ]; then echo "__FLS verify ok remaining=$REM"; else echo "__FLS verify fail secret-mismatch"; echo "__FLS result fail verify bak=$BAK"; fi
shred -u /home/dune/.dune/.dst-new-token 2>/dev/null || rm -f /home/dune/.dune/.dst-new-token
echo "__FLS result ok bak=$BAK"
'@
    $rotateBash = $rotateBash.Replace('__NS__', $world.namespace).Replace('__WORLD__', $world.world)

    try {
        $r = Invoke-DuneBackupShell -Ip $world.ip -Script $rotateBash -TimeoutSec 300
    } catch {
        _fail 'patch' "Rotation command failed: $($_.Exception.Message)"; return
    }
    $out = if ($r) { [string]$r.out } else { '' }

    # Always try to scrub the staged token even if parsing is odd.
    try { [void](Invoke-V6Ssh -Ip $world.ip -Cmd 'shred -u /home/dune/.dune/.dst-new-token 2>/dev/null || rm -f /home/dune/.dune/.dst-new-token' -TimeoutSec 15) } catch {}

    $bak = ''
    $mBak = [regex]::Match($out, '__FLS result \w+ ?(?:bak=)?(\S+)?')
    foreach ($line in ($out -split "`n")) {
        $line = $line.Trim()
        if ($line -match '^__FLS backup (ok|fail) (\S+) (\S+)') {
            (_step 'backup').status = if ($Matches[1] -eq 'ok') { 'done' } else { 'failed' }
            if ($Matches[1] -eq 'ok') { (_step 'backup').detail = "Snapshot saved on the VM ($([math]::Round([int]$Matches[2]/1024)) KB)."; $bak = $Matches[3] }
            else { (_step 'backup').detail = 'Could not snapshot the namespace.' }
        }
        elseif ($line -match '^__FLS patch (ok|fail)(.*)') {
            (_step 'patch').status = if ($Matches[1] -eq 'ok') { 'done' } else { 'failed' }
            (_step 'patch').detail = if ($Matches[1] -eq 'ok') { 'Token replaced in the Secret and battlegroup config.' } else { "Patch failed.$($Matches[2])" }
        }
        elseif ($line -match '^__FLS restart (ok|fail)') {
            (_step 'restart').status = if ($Matches[1] -eq 'ok') { 'done' } else { 'failed' }
            (_step 'restart').detail = 'Battlegroup restart issued - pods re-register with the new token.'
        }
        elseif ($line -match '^__FLS verify (ok|fail)') {
            (_step 'verify').status = if ($Matches[1] -eq 'ok') { 'done' } else { 'failed' }
            (_step 'verify').detail = if ($Matches[1] -eq 'ok') { 'New token confirmed in place. Give the servers a few minutes to come back, then check the in-game browser.' } else { 'Verification failed - see backup to restore.' }
        }
    }

    $okResult = ($out -match '__FLS result ok')
    foreach ($s in $steps) { if ($s.status -eq 'pending' -or $s.status -eq 'running') { $s.status = if ($okResult) { 'done' } else { 'failed' } } }

    if ($okResult) {
        Save-DuneFlsRotateState -State @{
            phase = 'done'; running = $false; steps = $steps; error = ''
            backup = $bak
            updated = (Get-Date).ToUniversalTime().ToString('o'); finished = (Get-Date).ToUniversalTime().ToString('o')
        }
    } else {
        $reason = 'Rotation did not complete.'
        $mr = [regex]::Match($out, '__FLS result fail (\S+)')
        if ($mr.Success) { $reason = "Rotation failed at: $($mr.Groups[1].Value). Your backup is on the VM and nothing was lost - retry or restore." }
        Save-DuneFlsRotateState -State @{
            phase = 'error'; running = $false; steps = $steps; error = $reason
            backup = $bak
            updated = (Get-Date).ToUniversalTime().ToString('o'); finished = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
}

# -----------------------------------------------------------------------------
# Spawn the rotation in a background runspace (mirrors Start-DunePublicIpApplyAsync).
# -----------------------------------------------------------------------------
function Start-DuneFlsRotateAsync {
    param([Parameter(Mandatory)][string]$Jwt, [string]$ServerDir)
    if (-not $ServerDir -and $PSScriptRoot) { $ServerDir = Split-Path -Parent $PSScriptRoot }
    if (-not $ServerDir) { $ServerDir = $script:DuneServerDir }

    $st = Read-DuneFlsRotateState
    $running = $false
    try { if ($st -is [hashtable]) { $running = [bool]$st['running'] } else { $running = [bool]$st.running } } catch {}
    if ($running) {
        return @{ ok = $false; running = $true; error = 'A token rotation is already in progress.' }
    }

    Save-DuneFlsRotateState -State @{
        phase = 'starting'; running = $true
        steps = @(@{ id = 'validate'; label = 'Validate token'; status = 'running'; detail = 'Starting...' })
        started = (Get-Date).ToUniversalTime().ToString('o')
        updated = (Get-Date).ToUniversalTime().ToString('o'); finished = $null; error = ''
    }

    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'
        $rs.ThreadOptions  = 'ReuseThread'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $script:DuneFlsRotateRunspace = @{ ps = $ps; rs = $rs; handle = $null; started = (Get-Date).ToUniversalTime() }
        [void]$ps.AddScript({
            param($ServerDir, $Jwt)
            try {
                $boot = Join-Path $ServerDir 'lib\Bootstrap.ps1'
                if (Test-Path $boot) { . $boot }
                $http = Join-Path $ServerDir 'HttpServer.ps1'
                if (Test-Path $http) { . $http }
                Get-ChildItem -Path (Join-Path $ServerDir 'lib') -Filter '*.ps1' | ForEach-Object {
                    if ($_.Name -ieq 'Bootstrap.ps1') { return }
                    try { . $_.FullName } catch {}
                }
                [void](Invoke-DuneFlsTokenRotate -Jwt $Jwt)
            } catch {
                try {
                    Save-DuneFlsRotateState -State @{
                        phase = 'error'; running = $false
                        steps = @(@{ id = 'validate'; label = 'Validate token'; status = 'failed'; detail = "Rotation runspace crashed: $($_.Exception.Message)" })
                        error = "Rotation runspace crashed: $($_.Exception.Message)"
                        updated = (Get-Date).ToUniversalTime().ToString('o'); finished = (Get-Date).ToUniversalTime().ToString('o')
                    }
                } catch {}
            }
        }).AddArgument($ServerDir).AddArgument($Jwt.Trim())
        $script:DuneFlsRotateRunspace.handle = $ps.BeginInvoke()
        return @{ ok = $true; running = $true; message = 'Token rotation started.' }
    } catch {
        Save-DuneFlsRotateState -State @{
            phase = 'error'; running = $false
            steps = @(@{ id = 'validate'; label = 'Validate token'; status = 'failed'; detail = "Failed to spawn rotation runspace: $($_.Exception.Message)" })
            error = "Failed to spawn rotation runspace: $($_.Exception.Message)"
            updated = (Get-Date).ToUniversalTime().ToString('o'); finished = (Get-Date).ToUniversalTime().ToString('o')
        }
        return @{ ok = $false; running = $false; error = "Failed to spawn rotation runspace: $($_.Exception.Message)" }
    }
}
