# Reversible same-battlegroup world restart.
#
# The operation preserves the BattleGroup custom resource and all config. It
# replaces only the PostgreSQL StatefulSet storage, after creating and verifying
# a Funcom logical backup. Any failure after storage removal triggers an
# automatic import of that exact backup.

$script:DuneWorldRestartConfirm = 'RESTART WORLD'
$script:DuneWorldRollbackConfirm = 'ROLL BACK WORLD'
$script:DuneWorldRestartLockName = 'world-restart-admission'
$script:DuneWorldRestartMarkerPath = '/tmp/dst-world-restart-active'
$script:DuneWorldRestartRecoveryMarkerPath = '/var/lib/dune-server/dst-world-restart-recovery-required'

function Get-DuneWorldRestartStatePath {
    Join-Path $env:APPDATA 'DuneServer\world-restart-state.json'
}

function New-DuneWorldRestartIdleState {
    @{
        phase = 'idle'; running = $false; steps = @(); rollbackAvailable = $false
        recoveryRequired = $false
        updated = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Get-DuneWorldRestartProcessIdentity {
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    return @{ pid = $process.Id; startedTicks = $process.StartTime.ToUniversalTime().Ticks }
}

function Read-DuneWorldRestartState {
    $path = Get-DuneWorldRestartStatePath
    if (-not (Test-Path -LiteralPath $path)) { return (New-DuneWorldRestartIdleState) }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return (New-DuneWorldRestartIdleState) }
        return ($raw | ConvertFrom-Json)
    } catch {
        return (New-DuneWorldRestartIdleState)
    }
}

function Save-DuneWorldRestartState {
    param([Parameter(Mandatory)]$State)
    $path = Get-DuneWorldRestartStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $State.updated = (Get-Date).ToUniversalTime().ToString('o')
    $json = $State | ConvertTo-Json -Depth 10
    $tmp = "$path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -Force
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-DuneWorldRestartStatus {
    $state = Read-DuneWorldRestartState
    try {
        if ([bool]$state.running) {
            $identity = Get-DuneWorldRestartProcessIdentity
            if ([int]$state.ownerPid -ne $identity.pid -or [long]$state.ownerStartedTicks -ne $identity.startedTicks) {
                $state.running = $false
                $state.phase = 'error'
                $state.error = 'The DST process that owned this World Restart is no longer running.'
                Save-DuneWorldRestartState -State $state
            }
        }
    } catch {}
    return $state
}

function Test-DuneWorldRestartMaintenanceActive {
    $state = Get-DuneWorldRestartStatus
    $recoveryRequired = $false
    if ($state.PSObject.Properties['recoveryRequired']) {
        $recoveryRequired = [bool]$state.recoveryRequired
    }
    return ([bool]$state.running -or $recoveryRequired)
}

function Get-DuneWorldRestartContext {
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) { return $ctx }

    $bash = @'
set -e
NS=$(sudo kubectl get ns --no-headers -o custom-columns=N:.metadata.name | grep -E '^funcom-seabass-sh-' || true)
[ "$(printf '%s\n' "$NS" | sed '/^$/d' | wc -l)" -eq 1 ] || { echo "__WR_ERROR:Expected exactly one self-hosted battlegroup namespace."; exit 2; }
WORLD=${NS#funcom-seabass-}
DBDEP="$WORLD-db-dbdepl"
sudo kubectl get battlegroup "$WORLD" -n "$NS" >/dev/null
sudo kubectl get databasedeployment "$DBDEP" -n "$NS" >/dev/null
STS=$(sudo kubectl get sts -n "$NS" -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].name=="'"$DBDEP"'")]}{.metadata.name}{"\n"}{end}')
[ "$(printf '%s\n' "$STS" | sed '/^$/d' | wc -l)" -eq 1 ] || { echo "__WR_ERROR:Expected exactly one database StatefulSet owned by $DBDEP."; exit 3; }
case "$STS" in "$WORLD-db-dbdepl-sts") ;; *) echo "__WR_ERROR:Unexpected database StatefulSet name: $STS"; exit 4;; esac
PVCS=$(sudo kubectl get sts "$STS" -n "$NS" -o jsonpath='{range .spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{end}' | sed '/^$/d')
[ "$(printf '%s\n' "$PVCS" | sed '/^$/d' | wc -l)" -eq 1 ] || { echo "__WR_ERROR:Expected exactly one database PVC mounted by $STS."; exit 5; }
PVC=$(printf '%s\n' "$PVCS" | head -1)
[ "$PVC" = "$WORLD-db-pvc" ] || { echo "__WR_ERROR:Unexpected database PVC name: $PVC"; exit 6; }
PHASE=$(sudo kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
[ "$PHASE" = "Bound" ] || { echo "__WR_ERROR:Expected Bound database PVC $PVC; got ${PHASE:-missing}."; exit 7; }
PVCOWNER=$(sudo kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.metadata.ownerReferences[0].kind}|{.metadata.ownerReferences[0].name}' 2>/dev/null || true)
[ "$PVCOWNER" = "BattleGroup|$WORLD" ] || { echo "__WR_ERROR:Database PVC ownership did not match the current battlegroup."; exit 8; }
DBOP=$(sudo kubectl get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers | awk 'tolower($2) ~ /database.*operator|operator.*database/ {print $1 "/" $2}')
[ "$(printf '%s\n' "$DBOP" | sed '/^$/d' | wc -l)" -eq 1 ] || { echo "__WR_ERROR:Expected exactly one database operator deployment."; exit 9; }
BGPHASE=$(sudo kubectl get battlegroup "$WORLD" -n "$NS" -o jsonpath='{.status.phase}')
DBPHASE=$(sudo kubectl get databasedeployment "$DBDEP" -n "$NS" -o jsonpath='{.status.phase}')
echo "__WR_CONTEXT:$NS|$WORLD|$DBDEP|$STS|$PVC|$DBOP|$BGPHASE|$DBPHASE"
'@
    $result = Invoke-DuneBackupShell -Ip $ctx.ip -Script $bash -TimeoutSec 40
    if ($result.rc -ne 0) {
        $message = if ($result.out -match '__WR_ERROR:([^\r\n]+)') { $Matches[1] } else { "World restart preflight failed (rc=$($result.rc))." }
        return @{ ok = $false; status = 409; message = $message }
    }
    $match = [regex]::Match([string]$result.out, '__WR_CONTEXT:([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]+)\|([^|]*)\|([^\r\n]*)')
    if (-not $match.Success) {
        return @{ ok = $false; status = 502; message = 'Could not parse world restart preflight.' }
    }
    @{
        ok = $true; ip = $ctx.ip; namespace = $match.Groups[1].Value
        world = $match.Groups[2].Value; databaseDeployment = $match.Groups[3].Value
        statefulSet = $match.Groups[4].Value; pvcs = @($match.Groups[5].Value -split ',' | Where-Object { $_ })
        databaseOperator = $match.Groups[6].Value; battlegroupPhase = $match.Groups[7].Value
        databasePhase = $match.Groups[8].Value
    }
}

function Get-DuneWorldRollbackContext {
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) { return $ctx }

    $bash = @'
set -e
NS=$(sudo kubectl get ns --no-headers -o custom-columns=N:.metadata.name | grep -E '^funcom-seabass-sh-' || true)
[ "$(printf '%s\n' "$NS" | sed '/^$/d' | wc -l)" -eq 1 ] || { echo "__WR_ERROR:Expected exactly one self-hosted battlegroup namespace."; exit 70; }
WORLD=${NS#funcom-seabass-}
sudo kubectl get battlegroup "$WORLD" -n "$NS" >/dev/null
DBOP=$(sudo kubectl get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers | awk 'tolower($2) ~ /database.*operator|operator.*database/ {print $1 "/" $2}')
[ "$(printf '%s\n' "$DBOP" | sed '/^$/d' | wc -l)" -eq 1 ] || { echo "__WR_ERROR:Expected exactly one database operator deployment."; exit 71; }
BGPHASE=$(sudo kubectl get battlegroup "$WORLD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
echo "__WR_ROLLBACK_CONTEXT:$NS|$WORLD|$DBOP|$BGPHASE"
'@
    $result = Invoke-DuneBackupShell -Ip $ctx.ip -Script $bash -TimeoutSec 40
    if ($result.rc -ne 0) {
        $match = [regex]::Match([string]$result.out, '__WR_ERROR:([^\r\n]+)')
        $message = if ($match.Success) { $match.Groups[1].Value } else { "World rollback preflight failed (rc=$($result.rc))." }
        return @{ ok=$false; status=409; message=$message }
    }
    $match = [regex]::Match([string]$result.out, '__WR_ROLLBACK_CONTEXT:([^|]+)\|([^|]+)\|([^|]+)\|([^\r\n]*)')
    if (-not $match.Success) {
        return @{ ok=$false; status=502; message='Could not parse world rollback preflight.' }
    }
    return @{
        ok=$true; ip=$ctx.ip; namespace=$match.Groups[1].Value
        world=$match.Groups[2].Value; databaseOperator=$match.Groups[3].Value.Trim()
        battlegroupPhase=$match.Groups[4].Value.Trim()
    }
}

function Set-DuneWorldRestartStep {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('pending','running','done','failed','warning')][string]$Status,
        [string]$Detail = ''
    )
    $step = $State.steps | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($step) { $step.status = $Status; $step.detail = $Detail }
    Save-DuneWorldRestartState -State $State
}

function Get-DuneWorldRestartOnlinePlayerCount {
    param([Parameter(Mandatory)][string]$Ip)
    $sql = @"
SELECT COUNT(*)::bigint AS online_count
FROM encrypted_player_state eps
WHERE eps.online_status::text <> 'Offline'
  AND (
    to_regclass('dune.active_server_ids') IS NULL
    OR (eps.server_id IS NOT NULL
        AND eps.server_id IN (SELECT * FROM dune.active_server_ids))
  );
"@
    $raw = Invoke-DuneSqlRaw -Ip $Ip -Sql $sql -Csv -TimeoutSec 60
    $rows = @($raw | ConvertFrom-Csv)
    $count = [long]0
    if ($rows.Count -ne 1 -or -not [long]::TryParse(([string]$rows[0].online_count).Trim(), [ref]$count)) {
        throw "Could not verify that all players are offline: $raw"
    }
    return $count
}

function Invoke-DuneWorldRestartRollbackInternal {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [Parameter(Mandatory)][string]$BackupPath,
        [string]$ExpectedWorld = ''
    )
    $backupName = $BackupPath.Substring($BackupPath.LastIndexOf('/') + 1)
    if ($backupName -notmatch '^[A-Za-z0-9._-]+$') { throw 'Saved rollback backup name is invalid.' }
    if ($ExpectedWorld -notmatch '^sh-[A-Za-z0-9-]+$') { throw 'Saved rollback world identity is invalid.' }
    if ($ExpectedWorld -and $BackupPath -notlike "$script:DuneBackupDumpDir/$ExpectedWorld/*") {
        throw "Rollback backup does not belong to the current world '$ExpectedWorld'."
    }
    $bash = @"
set -e
mkdir -p /var/lib/dune-server
touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath $script:DuneWorldRestartRecoveryMarkerPath
/home/dune/.dune/bin/battlegroup stop
[ -s '$script:DuneBackupDumpDir/$ExpectedWorld/$backupName' ] || { echo '__WR_ERROR:Recorded rollback backup is missing or empty.'; exit 59; }
DBOP=`$(sudo kubectl get deploy -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers | awk 'tolower(`$2) ~ /database.*operator|operator.*database/ {print `$1 "/" `$2}')
[ "`$(printf '%s\n' "`$DBOP" | sed '/^`$/d' | wc -l)" -eq 1 ] || { echo '__WR_ERROR:Could not identify the database operator before rollback.'; exit 60; }
OPNS=`${DBOP%/*}
OPNAME=`${DBOP#*/}
WEBHOOK=`$(sudo kubectl get svc -n "`$OPNS" -o custom-columns=NAME:.metadata.name --no-headers | awk 'tolower(`$1) ~ /database.*webhook/ {print `$1}')
[ "`$(printf '%s\n' "`$WEBHOOK" | sed '/^`$/d' | wc -l)" -eq 1 ] || { echo '__WR_ERROR:Could not identify the database webhook before rollback.'; exit 61; }
REPLICAS=`$(sudo kubectl get deploy "`$OPNAME" -n "`$OPNS" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
if [ "`${REPLICAS:-0}" -lt 1 ]; then
  sudo kubectl scale deploy "`$OPNAME" -n "`$OPNS" --replicas=1 >/dev/null
fi
for i in `$(seq 1 120); do
  AVAILABLE=`$(sudo kubectl get deploy "`$OPNAME" -n "`$OPNS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
  ENDPOINTS=`$(sudo kubectl get endpoints "`$WEBHOOK" -n "`$OPNS" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{"\n"}{end}' 2>/dev/null | sed '/^`$/d' | wc -l)
  [ "`${AVAILABLE:-0}" -ge 1 ] && [ "`${ENDPOINTS:-0}" -ge 1 ] && break
  sleep 2
done
[ "`${AVAILABLE:-0}" -ge 1 ] && [ "`${ENDPOINTS:-0}" -ge 1 ] || { echo '__WR_ERROR:Database operator webhook did not become ready for rollback.'; exit 62; }
printf 'yes\n' | /home/dune/.dune/bin/battlegroup import '$backupName'
/home/dune/.dune/bin/battlegroup start
NS='funcom-seabass-$ExpectedWorld'
for i in `$(seq 1 120); do
  PHASE=`$(sudo kubectl get battlegroup '$ExpectedWorld' -n "`$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "`$PHASE" = 'Healthy' ] && { echo '__WR_ROLLBACK_HEALTH:Healthy'; exit 0; }
  touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath
  sleep 5
done
echo '__WR_ERROR:Battlegroup did not become Healthy after rollback.'
exit 63
"@
    $result = Invoke-DuneBackupShell -Ip $Ip -Script $bash -TimeoutSec 1800
    if ($result.rc -ne 0 -or [string]$result.out -notmatch '__WR_ROLLBACK_HEALTH:Healthy') {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            Write-DuneLog "World Restart rollback import failed (rc=$($result.rc)): $($result.out.Trim())" 'ERROR'
        }
        throw "World rollback failed health verification (rc=$($result.rc))."
    }
}

function Invoke-DuneWorldRestart {
    $identity = Get-DuneWorldRestartProcessIdentity
    $steps = @(
        [pscustomobject]@{ id='preflight'; label='Validate resources and players offline'; status='running'; detail='' }
        [pscustomobject]@{ id='backup'; label='Create and verify rollback backup'; status='pending'; detail='' }
        [pscustomobject]@{ id='stop'; label='Stop battlegroup'; status='pending'; detail='' }
        [pscustomobject]@{ id='reset'; label='Regenerate database storage'; status='pending'; detail='' }
        [pscustomobject]@{ id='database'; label='Wait for fresh database'; status='pending'; detail='' }
        [pscustomobject]@{ id='start'; label='Start same battlegroup'; status='pending'; detail='' }
        [pscustomobject]@{ id='verify'; label='Verify empty world and health'; status='pending'; detail='' }
    )
    $state = @{
        phase='running'; running=$true; operation='restart'; steps=$steps
        rollbackAvailable=$false; started=(Get-Date).ToUniversalTime().ToString('o')
        finished=$null; error=''; automaticRollback=$false
        recoveryRequired=$false
        ownerPid=$identity.pid; ownerStartedTicks=$identity.startedTicks
    }
    Save-DuneWorldRestartState -State $state

    $wiped = $false
    $maintenanceMarkerSet = $false
    $safeToReleaseMaintenance = $false
    $ctx = $null
    try {
        $ctx = Get-DuneWorldRestartContext
        if (-not $ctx.ok) { throw $ctx.message }
        $state.namespace = $ctx.namespace
        $state.world = $ctx.world
        $marker = Invoke-DuneBackupShell -Ip $ctx.ip -Script "mkdir -p /var/lib/dune-server; touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath" -TimeoutSec 30
        if ($marker.rc -ne 0) { throw 'Could not establish the World Restart maintenance guard.' }
        $maintenanceMarkerSet = $true
        $onlineCount = Get-DuneWorldRestartOnlinePlayerCount -Ip $ctx.ip
        if ($onlineCount -ne 0) {
            throw "$onlineCount player(s) are still online. Have everyone return from Deep Desert, log out, and retry."
        }
        Set-DuneWorldRestartStep -State $state -Id 'preflight' -Status done -Detail "World $($ctx.world); database resources matched and all players are offline."

        Set-DuneWorldRestartStep -State $state -Id 'backup' -Status running -Detail 'Running Funcom logical backup.'
        $backupStem = 'dst-pre-world-restart-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
        $backupScript = @"
set -e
touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath
/home/dune/.dune/bin/battlegroup backup '$backupStem'
FILE=`$(find '$script:DuneBackupDumpDir/$($ctx.world)' -maxdepth 1 -type f \( -name '$backupStem' -o -name '$backupStem.backup' \) -size +1024c | head -1)
[ -n "`$FILE" ] || { echo '__WR_ERROR:Backup file was not created or is too small.'; exit 20; }
sudo kubectl get battlegroup,databasedeployment,sts,pvc -n '$($ctx.namespace)' -o yaml > "`$FILE.world-restart-resources.yaml"
[ -s "`$FILE.world-restart-resources.yaml" ] || { echo '__WR_ERROR:Resource metadata snapshot was not created.'; exit 21; }
echo "__WR_BACKUP:`$FILE|`$(wc -c < "`$FILE")"
"@
        $backup = Invoke-DuneBackupShell -Ip $ctx.ip -Script $backupScript -TimeoutSec 900
        $backupMatch = [regex]::Match([string]$backup.out, '__WR_BACKUP:([^|]+)\|(\d+)')
        if ($backup.rc -ne 0 -or -not $backupMatch.Success) {
            throw "Rollback backup verification failed. $($backup.out.Trim())"
        }
        $state.backupPath = $backupMatch.Groups[1].Value
        $state.backupName = $state.backupPath.Substring($state.backupPath.LastIndexOf('/') + 1)
        $state.backupSizeBytes = [long]$backupMatch.Groups[2].Value
        $state.rollbackAvailable = $true
        Set-DuneWorldRestartStep -State $state -Id 'backup' -Status done -Detail "Verified rollback backup $($state.backupPath) ($($state.backupSizeBytes) bytes)."

        Set-DuneWorldRestartStep -State $state -Id 'stop' -Status running -Detail 'Confirming players remained offline before storage replacement.'
        $onlineCount = Get-DuneWorldRestartOnlinePlayerCount -Ip $ctx.ip
        if ($onlineCount -ne 0) {
            throw "$onlineCount player(s) reconnected during backup. Have everyone log out and retry."
        }
        Set-DuneWorldRestartStep -State $state -Id 'stop' -Status running -Detail 'Stopping gameplay workloads before storage replacement.'
        $stop = Invoke-DuneBackupShell -Ip $ctx.ip -Script "touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath; /home/dune/.dune/bin/battlegroup stop" -TimeoutSec 600
        if ($stop.rc -ne 0) { throw "Battlegroup stop failed: $($stop.out.Trim())" }
        Set-DuneWorldRestartStep -State $state -Id 'stop' -Status done -Detail 'Battlegroup stopped.'

        Set-DuneWorldRestartStep -State $state -Id 'reset' -Status running -Detail 'Pausing database operator and replacing only database PVC storage.'
        $pvcArgs = ($ctx.pvcs | ForEach-Object { "'$_'" }) -join ' '
        $resetScript = @"
set -e
touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath
NS='$($ctx.namespace)'
STS='$($ctx.statefulSet)'
DBOP='$($ctx.databaseOperator)'
OPNS=`${DBOP%/*}
OPNAME=`${DBOP#*/}
OLDUID=`$(sudo kubectl get sts "`$STS" -n "`$NS" -o jsonpath='{.metadata.uid}')
REPLICAS=`$(sudo kubectl get deploy "`$OPNAME" -n "`$OPNS" -o jsonpath='{.spec.replicas}')
[ "`$REPLICAS" -ge 1 ] || { echo '__WR_ERROR:Database operator is not running.'; exit 30; }
restore_operator() { sudo kubectl scale deploy "`$OPNAME" -n "`$OPNS" --replicas="`$REPLICAS"; }
trap 'restore_operator >/dev/null 2>&1 || true' EXIT
sudo kubectl scale deploy "`$OPNAME" -n "`$OPNS" --replicas=0 >/dev/null
for i in `$(seq 1 60); do
  AVAILABLE=`$(sudo kubectl get deploy "`$OPNAME" -n "`$OPNS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
  [ "`${AVAILABLE:-0}" -eq 0 ] && break
  sleep 2
done
AVAILABLE=`$(sudo kubectl get deploy "`$OPNAME" -n "`$OPNS" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
[ "`${AVAILABLE:-0}" -eq 0 ] || { echo '__WR_ERROR:Database operator did not stop.'; exit 31; }
mkdir -p /var/lib/dune-server
touch $script:DuneWorldRestartRecoveryMarkerPath
sudo kubectl delete sts "`$STS" -n "`$NS" --wait=true --timeout=180s
sudo kubectl delete pvc -n "`$NS" $pvcArgs --wait=true --timeout=180s
restore_operator >/dev/null
SPECREPLICAS=`$(sudo kubectl get deploy "`$OPNAME" -n "`$OPNS" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
[ "`${SPECREPLICAS:-0}" -ge 1 ] || { echo '__WR_ERROR:Database operator scale-up was not accepted.'; exit 32; }
trap - EXIT
echo "__WR_RESET:`$OLDUID"
"@
        # From this point onward, any ambiguous failure is rollback-worthy. The
        # SSH channel can disappear after PVC deletion but before its sentinel
        # reaches DST, so do not rely on the sentinel alone to decide whether
        # old storage may already be gone.
        $wiped = $true
        $state.recoveryRequired = $true
        Save-DuneWorldRestartState -State $state
        $reset = Invoke-DuneBackupShell -Ip $ctx.ip -Script $resetScript -TimeoutSec 600
        $resetMatch = [regex]::Match([string]$reset.out, '__WR_RESET:([^\r\n]+)')
        if ($reset.rc -ne 0 -or -not $resetMatch.Success) {
            throw "Database storage replacement failed. $($reset.out.Trim())"
        }
        $oldUid = $resetMatch.Groups[1].Value.Trim()
        Set-DuneWorldRestartStep -State $state -Id 'reset' -Status done -Detail 'Old database storage removed; operator resumed.'

        Set-DuneWorldRestartStep -State $state -Id 'database' -Status running -Detail 'Waiting for operator migrations on fresh storage.'
        $waitScript = @"
set -e
touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath $script:DuneWorldRestartRecoveryMarkerPath
NS='$($ctx.namespace)'
STS='$($ctx.statefulSet)'
DBDEP='$($ctx.databaseDeployment)'
OLDUID='$oldUid'
for i in `$(seq 1 120); do
  STSUID=`$(sudo kubectl get sts "`$STS" -n "`$NS" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  PHASE=`$(sudo kubectl get databasedeployment "`$DBDEP" -n "`$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  READY=`$(sudo kubectl get sts "`$STS" -n "`$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  if [ -n "`$STSUID" ] && [ "`$STSUID" != "`$OLDUID" ] && [ "`$PHASE" = 'Ready' ] && [ "`$READY" = '1' ]; then
    echo "__WR_DATABASE:`$STSUID"
    exit 0
  fi
  sleep 5
done
echo '__WR_ERROR:Fresh database did not become Ready within 10 minutes.'
exit 40
"@
        $wait = Invoke-DuneBackupShell -Ip $ctx.ip -Script $waitScript -TimeoutSec 660
        $databaseMatch = [regex]::Match([string]$wait.out, '__WR_DATABASE:([^\r\n]+)')
        if ($wait.rc -ne 0 -or -not $databaseMatch.Success) {
            throw "Fresh database readiness failed. $($wait.out.Trim())"
        }
        Set-DuneWorldRestartStep -State $state -Id 'database' -Status done -Detail 'Fresh database initialized and Ready.'

        Set-DuneWorldRestartStep -State $state -Id 'start' -Status running -Detail 'Starting preserved battlegroup configuration.'
        $start = Invoke-DuneBackupShell -Ip $ctx.ip -Script "touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath; /home/dune/.dune/bin/battlegroup start" -TimeoutSec 900
        if ($start.rc -ne 0) { throw "Battlegroup start failed: $($start.out.Trim())" }
        Set-DuneWorldRestartStep -State $state -Id 'start' -Status done -Detail "Same battlegroup $($ctx.world) started."

        Set-DuneWorldRestartStep -State $state -Id 'verify' -Status running -Detail 'Checking battlegroup health, database connectivity, and zero player records before reconnect.'
        $healthScript = @"
set -e
touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath
for i in `$(seq 1 120); do
  PHASE=`$(sudo kubectl get battlegroup '$($ctx.world)' -n '$($ctx.namespace)' -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "`$PHASE" = 'Healthy' ] && { echo '__WR_HEALTH:Healthy'; exit 0; }
  touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath
  sleep 5
done
echo '__WR_ERROR:Battlegroup did not become Healthy within 10 minutes.'
exit 50
"@
        $health = Invoke-DuneBackupShell -Ip $ctx.ip -Script $healthScript -TimeoutSec 660
        if ($health.rc -ne 0 -or [string]$health.out -notmatch '__WR_HEALTH:Healthy') {
            throw "Battlegroup health verification failed. $($health.out.Trim())"
        }
        $verifySql = "SELECT COUNT(*)::bigint AS player_count FROM dune.actors WHERE class ILIKE '%PlayerCharacter%';"
        $verify = Invoke-DuneSqlRaw -Ip $ctx.ip -Sql $verifySql -Csv -TimeoutSec 60
        $verifyRows = @($verify | ConvertFrom-Csv)
        $playerCount = [long]0
        if ($verifyRows.Count -ne 1 -or -not [long]::TryParse(([string]$verifyRows[0].player_count).Trim(), [ref]$playerCount)) {
            throw "Could not verify fresh player count: $verify"
        }
        if ($playerCount -ne 0) { throw "Fresh database verification found $playerCount player rows; expected 0." }
        Set-DuneWorldRestartStep -State $state -Id 'verify' -Status done -Detail 'Database connected with zero player records before anyone reconnects.'

        $state.phase = 'done'; $state.running = $false; $state.recoveryRequired = $false
        $state.finished = (Get-Date).ToUniversalTime().ToString('o')
        $safeToReleaseMaintenance = $true
        Save-DuneWorldRestartState -State $state
    } catch {
        $errorText = $_.Exception.Message
        $active = $state.steps | Where-Object { $_.status -eq 'running' } | Select-Object -First 1
        if ($active) { $active.status = 'failed'; $active.detail = $errorText }
        if ($wiped -and $state.backupPath -and $ctx -and $ctx.ip) {
            try {
                $state.phase = 'rollback'; $state.automaticRollback = $true
                Save-DuneWorldRestartState -State $state
                Invoke-DuneWorldRestartRollbackInternal -Ip $ctx.ip -BackupPath $state.backupPath -ExpectedWorld $ctx.world
                $state.rollbackAvailable = $false
                $state.recoveryRequired = $false
                $safeToReleaseMaintenance = $true
                $errorText += ' Automatic rollback completed using the pre-restart backup.'
            } catch {
                $errorText += " Automatic rollback also failed: $($_.Exception.Message)"
            }
        }
        $state.phase = 'error'; $state.running = $false; $state.error = $errorText
        if (-not $wiped) {
            $state.recoveryRequired = $false
            $safeToReleaseMaintenance = $true
        }
        $state.finished = (Get-Date).ToUniversalTime().ToString('o')
        Save-DuneWorldRestartState -State $state
    } finally {
        if ($maintenanceMarkerSet -and $safeToReleaseMaintenance -and $ctx -and $ctx.ip) {
            try {
                [void](Invoke-DuneBackupShell -Ip $ctx.ip -Script "rm -f $script:DuneWorldRestartMarkerPath $script:DuneWorldRestartRecoveryMarkerPath" -TimeoutSec 30)
            } catch {}
        }
    }
}

function Invoke-DuneWorldRollback {
    $state = Read-DuneWorldRestartState
    if (-not $state.backupPath) { throw 'No world-restart rollback backup is recorded.' }
    $ctx = Get-DuneWorldRollbackContext
    if (-not $ctx.ok) { throw $ctx.message }
    if ([string]$state.world -ne [string]$ctx.world) {
        throw "The recorded rollback belongs to world '$($state.world)', not current world '$($ctx.world)'."
    }
    $onlineCount = 0
    try {
        $onlineCount = Get-DuneWorldRestartOnlinePlayerCount -Ip $ctx.ip
    } catch {
        if ([string]$ctx.battlegroupPhase -ne 'Stopped') {
            throw 'Could not verify players are offline because the database is unavailable and the battlegroup is not stopped.'
        }
    }
    if ($onlineCount -ne 0) {
        throw "$onlineCount player(s) are still online. Have everyone log out before rolling back the world."
    }
    $state.recoveryRequired = $true
    Save-DuneWorldRestartState -State $state
    $marker = Invoke-DuneBackupShell -Ip $ctx.ip -Script "mkdir -p /var/lib/dune-server; touch /tmp/dst-restart-active $script:DuneWorldRestartMarkerPath $script:DuneWorldRestartRecoveryMarkerPath" -TimeoutSec 30
    if ($marker.rc -ne 0) {
        throw 'Could not establish the World Rollback recovery guard.'
    }
    Invoke-DuneWorldRestartRollbackInternal -Ip $ctx.ip -BackupPath ([string]$state.backupPath) -ExpectedWorld $ctx.world
    $state.phase = 'rolled-back'; $state.running = $false; $state.rollbackAvailable = $false
    $state.recoveryRequired = $false
    $state.finished = (Get-Date).ToUniversalTime().ToString('o')
    Save-DuneWorldRestartState -State $state
    try {
        [void](Invoke-DuneBackupShell -Ip $ctx.ip -Script "rm -f $script:DuneWorldRestartMarkerPath $script:DuneWorldRestartRecoveryMarkerPath" -TimeoutSec 30)
    } catch {}
}

function Start-DuneWorldRestartWorker {
    param([Parameter(Mandatory)][ValidateSet('restart','rollback')][string]$Operation, [string]$ServerDir)
    if (-not $ServerDir) { $ServerDir = $script:DuneServerDir }
    if (-not $ServerDir -or -not (Test-Path -LiteralPath $ServerDir)) {
        return @{ ok=$false; running=$false; error='Server directory is unavailable.' }
    }
    $claimLaunch = {
        $current = Get-DuneWorldRestartStatus
        if ([bool]$current.running) { return @{ ok=$false; running=$true; error='A world restart operation is already running.' } }
        $identity = Get-DuneWorldRestartProcessIdentity
        Save-DuneWorldRestartState -State @{
            phase='starting'; running=$true; operation=$Operation; steps=@()
            rollbackAvailable=if ($Operation -eq 'rollback') { [bool]$current.rollbackAvailable } else { $false }
            recoveryRequired=if ($Operation -eq 'rollback' -and $current.PSObject.Properties['recoveryRequired']) { [bool]$current.recoveryRequired } else { $false }
            backupPath=if ($Operation -eq 'rollback') { $current.backupPath } else { $null }
            world=if ($Operation -eq 'rollback') { $current.world } else { $null }
            ownerPid=$identity.pid; ownerStartedTicks=$identity.startedTicks
            started=(Get-Date).ToUniversalTime().ToString('o'); finished=$null; error=''
        }
        return @{ ok=$true }
    }
    try {
        $claimed = if (Get-Command Invoke-WithDuneLock -ErrorAction SilentlyContinue) {
            Invoke-WithDuneLock -Name $script:DuneWorldRestartLockName -TimeoutSec 5 -Script $claimLaunch
        } else {
            & $claimLaunch
        }
        if (-not $claimed.ok) { return $claimed }

        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'MTA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        $script:DuneWorldRestartRunspace = @{ ps=$ps; rs=$rs; handle=$null }
        [void]$ps.AddScript({
            param($ServerDir, $Operation)
            try {
                $boot = Join-Path $ServerDir 'lib\Bootstrap.ps1'
                if (Test-Path $boot) { . $boot }
                $http = Join-Path $ServerDir 'HttpServer.ps1'
                if (Test-Path $http) { . $http }
                Get-ChildItem (Join-Path $ServerDir 'lib') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
                    if ($_.Name -ieq 'Bootstrap.ps1') { return }
                    . $_.FullName
                }
                if ($Operation -eq 'restart') { Invoke-DuneWorldRestart } else { Invoke-DuneWorldRollback }
            } catch {
                try {
                    $st = Read-DuneWorldRestartState
                    $st.phase='error'; $st.running=$false; $st.error="World restart worker crashed: $($_.Exception.Message)"
                    Save-DuneWorldRestartState -State $st
                } catch {}
            }
        }).AddArgument($ServerDir).AddArgument($Operation)
        $script:DuneWorldRestartRunspace.handle = $ps.BeginInvoke()
        return @{ ok=$true; running=$true; operation=$Operation }
    } catch {
        $identity = Get-DuneWorldRestartProcessIdentity
        $failedState = Read-DuneWorldRestartState
        Save-DuneWorldRestartState -State @{
            phase='error'; running=$false; operation=$Operation; steps=@()
            rollbackAvailable=if ($Operation -eq 'rollback') { [bool]$failedState.rollbackAvailable } else { $false }
            recoveryRequired=if ($Operation -eq 'rollback' -and $failedState.PSObject.Properties['recoveryRequired']) { [bool]$failedState.recoveryRequired } else { $false }
            backupPath=if ($Operation -eq 'rollback') { $failedState.backupPath } else { $null }
            world=if ($Operation -eq 'rollback') { $failedState.world } else { $null }
            error="Could not start world restart worker: $($_.Exception.Message)"
            ownerPid=$identity.pid; ownerStartedTicks=$identity.startedTicks
            updated=(Get-Date).ToUniversalTime().ToString('o'); finished=(Get-Date).ToUniversalTime().ToString('o')
        }
        return @{ ok=$false; running=$false; error="Could not start world restart worker: $($_.Exception.Message)" }
    }
}
