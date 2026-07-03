# -----------------------------------------------------------------------------
# DbUtilAutoheal.ps1
#
# Self-heals a specific Funcom operator wedge that leaves the game battlegroup
# stuck starting after a `battlegroup start`, a `battlegroup restart`, an FLS
# token rotation, or (most commonly) a Funcom self-host update.
#
# The wedge:
#   The DatabaseDeployment CR's util pod (name pattern *-db-dbdepl-util-*) is a
#   BARE pod (restartPolicy=Never, ownerRefs->DatabaseDeployment with
#   controller:true). Its job is to psql the DB service and run schema
#   migrations. If it races the DB StatefulSet (Postgres still finishing WAL
#   recovery when util attempts its first connect) OR if it OOMs at startup, it
#   exits non-zero and NOTHING restarts it. The DatabaseDeployment controller
#   holds .status.phase = "Pending" indefinitely, and the BattleGroup CR shows
#   SERVERGROUP=Starting / DATABASE=Pending forever until someone runs
#   `kubectl delete pod <util>` — which the controller then re-creates, and it
#   connects fine on the second attempt.
#
# We've hit this at least twice in the wild:
#   - 2026-07-01 (murm) : OOMKilled with Swap:0. Fix: swap on + delete util.
#   - 2026-07-03        : Funcom operator drop 2019354 -> 2025705-0-shipping;
#                         util raced Postgres recovery by ~3s, exit 53
#                         ("connection refused"). Fix: delete util.
#
# Detection signature (single SSH round-trip via kubectl):
#   - DatabaseDeployment.status.phase != "Ready"
#   - The util pod exists
#   - Its terminated exitCode is non-empty and non-zero
#     (phase Failed OR container terminated with reason=Error/OOMKilled)
#
# When we heal we `kubectl delete pod <util>` once, log it, and let the DB
# operator recreate a fresh util pod on its next reconcile loop (a few seconds).
#
# Debounce: we won't delete the same util-pod name twice, and we won't delete
# ANY util pod more than once every $script:DuneDbUtilAutohealCooldownSec.
#
# Public entry points:
#   - Get-DuneDbUtilWedgeState              -> observability only (no action)
#   - Invoke-DuneDbUtilAutohealTick         -> scheduler-safe: scans + heals if
#                                              wedged. Never throws. Returns a
#                                              hashtable summarising what it did.
# -----------------------------------------------------------------------------

# Cooldown between heal attempts (any util pod). 90 s comfortably covers
# operator re-reconcile + pod pull + start, so we don't ping-pong deletes if the
# freshly-recreated pod happens to lose the race a second time in a row.
$script:DuneDbUtilAutohealCooldownSec = 90

# Last-action tracker: name of the pod we most recently deleted + when.
$script:DuneDbUtilAutohealLastAction = @{ pod = ''; at = [datetime]::MinValue }

# -----------------------------------------------------------------------------
# _Invoke-DbUtilShell: single kubectl round-trip that prints machine-readable
# k/v lines. Optionally deletes the util pod first when -Delete is set.
#
# We keep the remote script tiny and let PS parse the k/v pairs so a partial
# SSH truncation is easy to detect.
# -----------------------------------------------------------------------------
function _Invoke-DbUtilShell {
    param(
        [Parameter(Mandatory)][string]$Ip,
        [switch]$Delete,
        [string]$DeleteName = ''
    )
    $deleteBlock = ''
    if ($Delete -and $DeleteName) {
        # Safety guardrail: only ever accept a name that matches the exact
        # bare-pod pattern the DatabaseDeployment controller owns. If someone
        # feeds us a different name we no-op the delete rather than risk
        # deleting an unrelated pod.
        $deleteBlock = @"
if printf '%s' "$DeleteName" | grep -qE '^sh-[a-z0-9]+-[a-z0-9]+-db-dbdepl-util-[a-z0-9]+$'; then
  kubectl -n "`$NS" delete pod "$DeleteName" --wait=false --grace-period=0 --force >/dev/null 2>&1 && echo 'deleted=1' || echo 'deleted=0'
else
  echo 'deleted=0'
  echo 'delete_skipped=name-pattern-mismatch'
fi
"@
    }

    $script = @"
set -u
KUBECTL=/usr/local/bin/kubectl
[ -x `$KUBECTL ] || KUBECTL=kubectl
NS=`$(`$KUBECTL get ns -o name 2>/dev/null | grep -m1 '^namespace/funcom-seabass' | sed 's|namespace/||')
if [ -z "`$NS" ]; then
  echo 'ns='
  echo 'wedged=false'
  echo 'reason=no-funcom-ns'
  exit 0
fi
echo "ns=`$NS"

DBPHASE=`$(`$KUBECTL -n "`$NS" get databasedeployment -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
echo "dbPhase=`$DBPHASE"

UTIL=`$(`$KUBECTL -n "`$NS" get pods -o name 2>/dev/null | grep -m1 'db-dbdepl-util')
UTIL_NAME=`${UTIL#pod/}
echo "utilName=`$UTIL_NAME"

if [ -z "`$UTIL_NAME" ]; then
  echo 'wedged=false'
  echo 'reason=no-util-pod'
  exit 0
fi

UTILPHASE=`$(`$KUBECTL -n "`$NS" get "`$UTIL" -o jsonpath='{.status.phase}' 2>/dev/null)
UTILEXIT=`$(`$KUBECTL -n "`$NS" get "`$UTIL" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)
UTILREASON=`$(`$KUBECTL -n "`$NS" get "`$UTIL" -o jsonpath='{.status.containerStatuses[0].state.terminated.reason}' 2>/dev/null)
echo "utilPhase=`$UTILPHASE"
echo "utilExit=`$UTILEXIT"
echo "utilReason=`$UTILREASON"

# Wedge = DB not Ready AND util terminated with a non-zero exit code.
# We explicitly ignore Succeeded/exit=0 because that means the util pod did its
# job and the DB deployment is simply mid-reconcile.
if [ "`$DBPHASE" != "Ready" ] && [ -n "`$UTILEXIT" ] && [ "`$UTILEXIT" != "0" ]; then
  echo 'wedged=true'
else
  echo 'wedged=false'
fi
$deleteBlock
"@

    $r = Invoke-DuneBackupShell -Ip $Ip -Script $script -TimeoutSec 25
    $body = if ($r) { [string]$r.out } else { '' }
    $rc   = if ($r) { [int]$r.rc } else { -1 }

    $state = @{
        rc            = $rc
        raw           = $body
        ns            = ''
        dbPhase       = ''
        utilName      = ''
        utilPhase     = ''
        utilExit      = ''
        utilReason    = ''
        wedged        = $false
        deleted       = $false
        deleteSkipped = ''
        reason        = ''
    }
    foreach ($line in ($body -split "`n")) {
        $line = $line.Trim()
        if (-not $line) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $line.Substring(0, $eq).Trim()
        $v = $line.Substring($eq + 1).Trim()
        switch ($k) {
            'ns'             { $state.ns = $v }
            'dbPhase'        { $state.dbPhase = $v }
            'utilName'       { $state.utilName = $v }
            'utilPhase'      { $state.utilPhase = $v }
            'utilExit'       { $state.utilExit = $v }
            'utilReason'     { $state.utilReason = $v }
            'wedged'         { $state.wedged = ($v -eq 'true') }
            'reason'         { $state.reason = $v }
            'deleted'        { $state.deleted = ($v -eq '1') }
            'delete_skipped' { $state.deleteSkipped = $v }
        }
    }
    return $state
}

# -----------------------------------------------------------------------------
# Get-DuneDbUtilWedgeState : observability-only. Returns the parsed state
# hashtable (see _Invoke-DbUtilShell) without ever deleting anything. Callers
# who just want to know if we're wedged (e.g. a future status endpoint) use
# this.
# -----------------------------------------------------------------------------
function Get-DuneDbUtilWedgeState {
    if (-not (Get-Command Get-DuneBackupContext -ErrorAction SilentlyContinue)) {
        return @{ ok = $false; message = 'Get-DuneBackupContext unavailable' }
    }
    $ctx = Get-DuneBackupContext
    if (-not $ctx.ok) { return @{ ok = $false; message = $ctx.message } }
    try {
        $s = _Invoke-DbUtilShell -Ip $ctx.ip
        $s.ok = $true
        return $s
    } catch {
        return @{ ok = $false; message = "wedge probe failed: $($_.Exception.Message)" }
    }
}

# -----------------------------------------------------------------------------
# Invoke-DuneDbUtilAutohealTick : scheduler-safe entry. Called from the 30-s
# background loop in RestartSchedule.ps1 and (optionally) right after any
# DST-issued battlegroup restart. Behaviour:
#
#   1. If the VM is down / no funcom-seabass namespace / util pod healthy ->
#      no-op, return summary with acted=$false.
#   2. If wedged AND we're outside the cooldown AND we haven't just deleted
#      this exact util pod -> delete it, log INFO, return acted=$true.
#   3. If wedged but we're in cooldown -> log DEBUG once, return acted=$false.
#
# Never throws. Never blocks the caller for more than ~25 s (SSH timeout).
# -----------------------------------------------------------------------------
function Invoke-DuneDbUtilAutohealTick {
    try {
        if (-not (Get-Command Get-DuneBackupContext -ErrorAction SilentlyContinue)) {
            return @{ ok = $false; acted = $false; message = 'context helper unavailable' }
        }
        $ctx = Get-DuneBackupContext
        if (-not $ctx.ok) {
            return @{ ok = $false; acted = $false; message = $ctx.message }
        }
        $s = _Invoke-DbUtilShell -Ip $ctx.ip
        if (-not $s.wedged) {
            return @{ ok = $true; acted = $false; wedged = $false; dbPhase = $s.dbPhase }
        }

        # Wedged. Check debounce.
        $now = Get-Date
        $last = $script:DuneDbUtilAutohealLastAction
        $ageSec = ($now - $last.at).TotalSeconds
        if ($last.pod -eq $s.utilName -and $ageSec -lt $script:DuneDbUtilAutohealCooldownSec) {
            # Same pod, still cooling -> skip. The controller may not have had
            # time to reconcile our previous delete yet.
            return @{ ok = $true; acted = $false; wedged = $true; cooldown = $true; utilName = $s.utilName }
        }
        if ($ageSec -lt $script:DuneDbUtilAutohealCooldownSec) {
            # Different pod but we deleted very recently. Give the operator a
            # beat before we escalate.
            return @{ ok = $true; acted = $false; wedged = $true; cooldown = $true; utilName = $s.utilName }
        }

        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            $why = "phase=$($s.utilPhase) exit=$($s.utilExit) reason=$($s.utilReason)"
            Write-DuneLog "db-util autoheal: wedge detected ($why); deleting $($s.utilName)" 'INFO'
        }

        $s2 = _Invoke-DbUtilShell -Ip $ctx.ip -Delete -DeleteName $s.utilName
        $script:DuneDbUtilAutohealLastAction = @{ pod = $s.utilName; at = $now }

        if ($s2.deleted) {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                Write-DuneLog "db-util autoheal: deleted $($s.utilName); operator will recreate it" 'INFO'
            }
            return @{ ok = $true; acted = $true; wedged = $true; deleted = $true; utilName = $s.utilName; dbPhase = $s.dbPhase }
        } else {
            if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
                $why = if ($s2.deleteSkipped) { "delete skipped: $($s2.deleteSkipped)" } else { 'delete rc reported failure' }
                Write-DuneLog "db-util autoheal: $why" 'WARN'
            }
            return @{ ok = $true; acted = $true; wedged = $true; deleted = $false; utilName = $s.utilName; deleteSkipped = $s2.deleteSkipped }
        }
    } catch {
        if (Get-Command Write-DuneLog -ErrorAction SilentlyContinue) {
            try { Write-DuneLog "db-util autoheal tick error: $($_.Exception.Message)" 'WARN' } catch {}
        }
        return @{ ok = $false; acted = $false; message = $_.Exception.Message }
    }
}
