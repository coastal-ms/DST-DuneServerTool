#!/bin/sh
# Reconcile DST's Hyper-V guest recovery and optional VM lifecycle integration.

set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

ACTION="${DUNE_HYPERV_ACTION:-recovery}"
MEMORY_ROOT="${DUNE_HYPERV_MEMORY_ROOT:-/sys/devices/system/memory}"
BOOT_HOOK="${DUNE_HYPERV_BOOT_HOOK:-/etc/local.d/dune-hyperv-memory-online.start}"
LOG="${DUNE_HYPERV_LOG:-/var/log/dune-hyperv-guest-recovery.log}"
RC_SERVICE="${DUNE_HYPERV_RC_SERVICE:-rc-service}"
RC_UPDATE="${DUNE_HYPERV_RC_UPDATE:-rc-update}"
PGREP="${DUNE_HYPERV_PGREP:-pgrep}"
KVP_SERVICE="${DUNE_HYPERV_KVP_SERVICE:-hv_kvp_daemon}"
KVP_PROCESS="${DUNE_HYPERV_KVP_PROCESS:-hv_kvp_daemon}"
FORCE_KVP_RESTART="${DUNE_HYPERV_FORCE_KVP_RESTART:-0}"
VMBUS_ROOT="${DUNE_HYPERV_VMBUS_ROOT:-/sys/bus/vmbus/devices}"
HV_UTILS_ROOT="${DUNE_HYPERV_HV_UTILS_ROOT:-/sys/module/hv_utils}"
HV_SHUTDOWN_GUID="0e0b6031-5213-4934-818b-38d90ced39db"
LIFECYCLE_BIN="${DUNE_HYPERV_LIFECYCLE_BIN:-/usr/local/sbin/dune-hyperv-lifecycle}"
LIFECYCLE_SERVICE="${DUNE_HYPERV_LIFECYCLE_SERVICE:-/etc/init.d/dune-hyperv-lifecycle}"
LIFECYCLE_NAME="${DUNE_HYPERV_LIFECYCLE_NAME:-dune-hyperv-lifecycle}"
LIFECYCLE_STATE_DIR="${DUNE_HYPERV_LIFECYCLE_STATE_DIR:-/var/lib/dune-hyperv-lifecycle}"
LIFECYCLE_STATE="${DUNE_HYPERV_LIFECYCLE_STATE:-$LIFECYCLE_STATE_DIR/state}"
LIFECYCLE_BACKUP_DIR="${DUNE_HYPERV_LIFECYCLE_BACKUP_DIR:-/var/lib/dune-hyperv-lifecycle-backup}"
LIFECYCLE_META="${DUNE_HYPERV_LIFECYCLE_META:-$LIFECYCLE_BACKUP_DIR/install.meta}"
K3S_BIN="${DUNE_HYPERV_K3S_BIN:-/usr/local/bin/k3s}"
K3S_SERVICE="${DUNE_HYPERV_K3S_SERVICE:-/etc/init.d/k3s}"
BG_BIN="${DUNE_HYPERV_BG_BIN:-/home/dune/.dune/bin/battlegroup}"
TIMEOUT="${DUNE_HYPERV_TIMEOUT:-timeout}"
STOP_TIMEOUT="${DUNE_HYPERV_STOP_TIMEOUT:-300}"
START_TIMEOUT="${DUNE_HYPERV_START_TIMEOUT:-900}"
TXN="$$"
BOOT_STAGE="${BOOT_HOOK}.new.${TXN}"
BIN_STAGE="${LIFECYCLE_BIN}.new.${TXN}"
SERVICE_STAGE="${LIFECYCLE_SERVICE}.new.${TXN}"
META_STAGE="${LIFECYCLE_META}.new.${TXN}"
TXN_DIR="${DUNE_HYPERV_TXN_DIR:-/run/dune-hyperv-lifecycle-${TXN}}"
INITIAL_START_SENTINEL="${LIFECYCLE_STATE_DIR}/.initial-install"
MUTATION_STARTED=0
TXN_CREATED=0
SENTINEL_CREATED=0
HAD_BIN=0
HAD_SERVICE=0
HAD_STATE=0
HAD_RUNLEVEL=0
PRIOR_SERVICE_STARTED=0
HAD_META=0

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }
bool() { if "$@"; then printf true; else printf false; fi; }

cleanup_transaction() {
    rm -f "$BOOT_STAGE" "$BIN_STAGE" "$SERVICE_STAGE" "$META_STAGE"
    if [ "$SENTINEL_CREATED" -eq 1 ]; then rm -f "$INITIAL_START_SENTINEL"; fi
    if [ "$TXN_CREATED" -eq 1 ]; then rm -rf "$TXN_DIR"; fi
}

runlevel_has_lifecycle() {
    "$RC_UPDATE" show default 2>/dev/null |
        grep -Eq "(^|[[:space:]])${LIFECYCLE_NAME}([[:space:]]|$)"
}

service_started() {
    "$RC_SERVICE" "$LIFECYCLE_NAME" status >/dev/null 2>&1
}

restore_transaction() {
    log "Hyper-V lifecycle reconciliation failed; restoring prior guest state"
    if [ "$PRIOR_SERVICE_STARTED" -eq 0 ]; then
        "$RC_SERVICE" "$LIFECYCLE_NAME" zap >/dev/null 2>&1 || true
    fi
    if [ "$HAD_BIN" -eq 1 ]; then
        cp -p "$TXN_DIR/bin" "$LIFECYCLE_BIN" || log "rollback warning: failed to restore lifecycle executable"
    else
        rm -f "$LIFECYCLE_BIN"
    fi
    if [ "$HAD_SERVICE" -eq 1 ]; then
        cp -p "$TXN_DIR/service" "$LIFECYCLE_SERVICE" || log "rollback warning: failed to restore OpenRC service"
    else
        rm -f "$LIFECYCLE_SERVICE"
    fi
    if [ "$HAD_STATE" -eq 1 ]; then
        mkdir -p "$(dirname "$LIFECYCLE_STATE")" 2>/dev/null || true
        cp -p "$TXN_DIR/state" "$LIFECYCLE_STATE" || log "rollback warning: failed to restore lifecycle state"
    else
        rm -f "$LIFECYCLE_STATE"
    fi
    if [ "$HAD_RUNLEVEL" -eq 1 ]; then
        "$RC_UPDATE" add "$LIFECYCLE_NAME" default >/dev/null 2>&1 ||
            log "rollback warning: failed to restore OpenRC runlevel"
    else
        "$RC_UPDATE" del "$LIFECYCLE_NAME" default >/dev/null 2>&1 || true
    fi
    if [ "$PRIOR_SERVICE_STARTED" -eq 1 ] && [ "$HAD_SERVICE" -eq 1 ]; then
        "$RC_SERVICE" "$LIFECYCLE_NAME" start >/dev/null 2>&1 ||
            log "rollback warning: failed to restart prior lifecycle service"
    fi
    if [ "$HAD_META" -eq 0 ]; then
        rm -rf "$LIFECYCLE_BACKUP_DIR"
    fi
}

fail() {
    _message="$*"
    log "$_message"
    if [ "$MUTATION_STARTED" -eq 1 ]; then restore_transaction; fi
    cleanup_transaction
    echo DUNE_HYPERV_GUEST_RECOVERY_FAILED
    exit 1
}

on_interrupt() {
    log "Hyper-V guest recovery installer interrupted"
    if [ "$MUTATION_STARTED" -eq 1 ]; then restore_transaction; fi
    cleanup_transaction
    exit 1
}
trap on_interrupt HUP INT TERM

shutdown_channel_present() {
    [ -d "$VMBUS_ROOT" ] || return 1
    for _class in "$VMBUS_ROOT"/*/class_id; do
        [ -r "$_class" ] || continue
        _id=$(tr -d '{}[:space:]' < "$_class" 2>/dev/null | tr 'A-F' 'a-f')
        [ "$_id" = "$HV_SHUTDOWN_GUID" ] && return 0
    done
    return 1
}

hv_utils_present() {
    [ -d "$HV_UTILS_ROOT" ] && return 0
    grep -Eq '^hv_utils[[:space:]]' /proc/modules 2>/dev/null
}

state_value() {
    _key="$1"
    [ -r "$LIFECYCLE_STATE" ] || return 0
    sed -n "s/^${_key}=//p" "$LIFECYCLE_STATE" 2>/dev/null | tail -n 1
}

lifecycle_managed() {
    [ -r "$LIFECYCLE_BIN" ] &&
        grep -Fq 'DUNE_HYPERV_LIFECYCLE_MANAGED=1' "$LIFECYCLE_BIN" 2>/dev/null &&
        [ -r "$LIFECYCLE_SERVICE" ] &&
        grep -Fq 'DUNE_HYPERV_LIFECYCLE_MANAGED=1' "$LIFECYCLE_SERVICE" 2>/dev/null
}

emit_lifecycle_status() {
    _supported=false
    _driver=false
    _channel=false
    _installed=false
    _runlevel=false
    _service=false
    hv_utils_present && _driver=true
    shutdown_channel_present && _channel=true
    [ "$_driver" = true ] && [ "$_channel" = true ] && _supported=true
    lifecycle_managed && _installed=true
    runlevel_has_lifecycle && _runlevel=true
    service_started && _service=true
    printf 'DUNE_HYPERV_LIFECYCLE_STATUS supported=%s hv_utils=%s shutdown_channel=%s installed=%s runlevel=%s service_started=%s desired=%s last_shutdown_result=%s last_shutdown_phase=%s last_shutdown_at=%s last_start_result=%s last_start_phase=%s last_start_at=%s\n' \
        "$_supported" "$_driver" "$_channel" "$_installed" "$_runlevel" "$_service" \
        "$(state_value DESIRED)" "$(state_value LAST_SHUTDOWN_RESULT)" \
        "$(state_value LAST_SHUTDOWN_PHASE)" "$(state_value LAST_SHUTDOWN_AT)" \
        "$(state_value LAST_START_RESULT)" "$(state_value LAST_START_PHASE)" \
        "$(state_value LAST_START_AT)"
}

online_memory() {
    [ -d "$MEMORY_ROOT" ] || {
        echo DUNE_HYPERV_GUEST_RECOVERY_NOT_APPLICABLE
        exit 0
    }
    [ -w "$MEMORY_ROOT/auto_online_blocks" ] ||
        fail "memory hot-add policy is not writable: $MEMORY_ROOT/auto_online_blocks"
    printf '%s\n' online > "$MEMORY_ROOT/auto_online_blocks" ||
        fail "failed to enable automatic memory onlining"
    for _state in "$MEMORY_ROOT"/memory*/state; do
        [ -f "$_state" ] || continue
        if [ "$(cat "$_state" 2>/dev/null)" = offline ]; then
            printf '%s\n' online > "$_state" ||
                fail "failed to online memory block: $_state"
        fi
    done
}

kvp_running() {
    "$PGREP" -f "(^|/)$KVP_PROCESS([[:space:]]|$)" >/dev/null 2>&1
}

ensure_kvp() {
    if [ "$FORCE_KVP_RESTART" = 1 ] || ! kvp_running; then
        "$RC_SERVICE" "$KVP_SERVICE" restart >/dev/null 2>&1 ||
            fail "failed to restart $KVP_SERVICE"
    fi
    _wait=0
    while ! kvp_running; do
        _wait=$((_wait + 1))
        [ "$_wait" -lt 6 ] || fail "$KVP_PROCESS is still absent after service restart"
        sleep 1
    done
}

install_memory_hook() {
    mkdir -p "$(dirname "$BOOT_HOOK")" || fail "failed to create boot-hook directory"
    if ! cat > "$BOOT_STAGE" <<'HOOKEOF'
#!/bin/sh
set -eu
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
MEMORY_ROOT=/sys/devices/system/memory

if [ -w "$MEMORY_ROOT/auto_online_blocks" ]; then
    printf '%s\n' online > "$MEMORY_ROOT/auto_online_blocks"
    for state in "$MEMORY_ROOT"/memory*/state; do
        [ -f "$state" ] || continue
        if [ "$(cat "$state" 2>/dev/null)" = offline ]; then
            printf '%s\n' online > "$state"
        fi
    done
fi

if ! pgrep -f '(^|/)hv_kvp_daemon([[:space:]]|$)' >/dev/null 2>&1; then
    rc-service hv_kvp_daemon restart >/dev/null 2>&1 || true
fi
HOOKEOF
    then
        fail "failed to stage Hyper-V memory boot hook"
    fi
    chmod 0755 "$BOOT_STAGE" || fail "failed to make memory boot hook executable"
    mv -f "$BOOT_STAGE" "$BOOT_HOOK" || fail "failed to publish memory boot hook"
    "$RC_UPDATE" add local default >/dev/null 2>&1 ||
        fail "failed to enable the OpenRC local service"
}

reconcile_recovery() {
    online_memory
    ensure_kvp
    install_memory_hook
    _offline=0
    for _state in "$MEMORY_ROOT"/memory*/state; do
        [ -f "$_state" ] || continue
        if [ "$(cat "$_state" 2>/dev/null)" = offline ]; then
            _offline=$((_offline + 1))
        fi
    done
    [ "$(cat "$MEMORY_ROOT/auto_online_blocks" 2>/dev/null)" = online ] ||
        fail "automatic memory onlining did not persist"
    [ "$_offline" -eq 0 ] || fail "$_offline memory block(s) remain offline"
    [ -x "$BOOT_HOOK" ] || fail "memory boot hook is missing or not executable"
    log "Hyper-V guest recovery reconciled: auto_online=online offline=0 kvp=running"
    echo "DUNE_HYPERV_GUEST_RECOVERY_OK auto_online=online offline=0 kvp=running"
}

stage_lifecycle_files() {
    mkdir -p "$(dirname "$LIFECYCLE_BIN")" "$(dirname "$LIFECYCLE_SERVICE")" ||
        fail "failed to create lifecycle directories"
    if ! cat > "$BIN_STAGE" <<'LIFEEOF'
#!/bin/sh
# DUNE_HYPERV_LIFECYCLE_MANAGED=1
set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

ACTION="${1:-status}"
K3S="${DUNE_HYPERV_K3S_BIN:-/usr/local/bin/k3s}"
BG_BIN="${DUNE_HYPERV_BG_BIN:-/home/dune/.dune/bin/battlegroup}"
STATE_DIR="${DUNE_HYPERV_LIFECYCLE_STATE_DIR:-/var/lib/dune-hyperv-lifecycle}"
STATE="${DUNE_HYPERV_LIFECYCLE_STATE:-$STATE_DIR/state}"
LOG="${DUNE_HYPERV_LOG:-/var/log/dune-hyperv-guest-recovery.log}"
TIMEOUT="${DUNE_HYPERV_TIMEOUT:-timeout}"
STOP_TIMEOUT="${DUNE_HYPERV_STOP_TIMEOUT:-300}"
START_TIMEOUT="${DUNE_HYPERV_START_TIMEOUT:-900}"

now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] lifecycle: $*" >> "$LOG" 2>/dev/null || true; }
safe_value() { printf '%s' "$1" | tr -cd 'A-Za-z0-9_.:+-'; }

get_state() {
    _key="$1"
    [ -r "$STATE" ] || return 0
    sed -n "s/^${_key}=//p" "$STATE" 2>/dev/null | tail -n 1
}

set_state() {
    _key="$1"
    _value=$(safe_value "$2")
    mkdir -p "$STATE_DIR" || return 1
    _tmp="${STATE}.new.$$"
    if [ -r "$STATE" ]; then
        sed "/^${_key}=/d" "$STATE" > "$_tmp" || { rm -f "$_tmp"; return 1; }
    else
        : > "$_tmp" || return 1
    fi
    printf '%s=%s\n' "$_key" "$_value" >> "$_tmp" || { rm -f "$_tmp"; return 1; }
    chmod 0600 "$_tmp" || { rm -f "$_tmp"; return 1; }
    mv -f "$_tmp" "$STATE"
}

set_result() {
    _which="$1"
    _result="$2"
    _phase="$3"
    set_state "LAST_${_which}_RESULT" "$_result" &&
        set_state "LAST_${_which}_PHASE" "$_phase" &&
        set_state "LAST_${_which}_AT" "$(now)"
}

pod_rows() {
    "$K3S" kubectl get pods -A --no-headers \
        -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.containerStatuses[*].ready,PHASE:.status.phase \
        2>/dev/null
}

active_bg_count() {
    _rows=$(pod_rows) || return 1
    printf '%s\n' "$_rows" |
        awk '$2 ~ /(-sg-|-mq-|-sgw-|-tr-|-bgd-)/ && $4 != "Succeeded" && $4 != "Failed" { count++ } END { print count+0 }'
}

wait_pods_gone() {
    while :; do
        _count=$(active_bg_count) || return 1
        [ "${_count:-0}" -gt 0 ] 2>/dev/null || return 0
        sleep 2
    done
}

k3s_ready() {
    "$K3S" kubectl get --raw=/readyz 2>/dev/null | grep -qx ok
}

db_ready() {
    _rows=$(pod_rows | awk '$2 ~ /(-db-|postgres|^pg-|-pg-)/ && $2 !~ /(dump|backup|fb-|migration|util|mon|pghero)/ && $4 !~ /(Succeeded|Failed)/ {print}')
    [ -n "$_rows" ] || return 1
    printf '%s\n' "$_rows" | awk '
        {
            n=split($3, ready, ",")
            for (i=1; i<=n; i++) if (ready[i] != "true") exit 1
            if ($4 != "Running") exit 1
        }
        END { if (NR == 0) exit 1 }'
}

operators_ready() {
    _rows=$("$K3S" kubectl get pods -n funcom-operators --no-headers \
        -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[*].ready,PHASE:.status.phase 2>/dev/null)
    [ -n "$_rows" ] || return 1
    printf '%s\n' "$_rows" | awk '
        {
            n=split($2, ready, ",")
            for (i=1; i<=n; i++) if (ready[i] != "true") exit 1
            if ($3 != "Running") exit 1
        }
        END { if (NR == 0) exit 1 }'
}

webhook_ready() {
    "$K3S" kubectl -n funcom-operators get endpoints battlegroupoperator-webhook-svc \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null |
        grep -Eq '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'
}

bg_ready() {
    _row=$("$K3S" kubectl get battlegroups -A \
        -o jsonpath='{range .items[0]}{.status.phase}{"|"}{.status.database.phase}{"|"}{.status.utilities.serverGateway.phase}{"|"}{.status.utilities.director.phase}{"|"}{range .status.servers[*]}{.phase}:{.ready},{end}{end}' \
        2>/dev/null)
    [ -n "$_row" ] || return 1
    _head=${_row%%|*}; _rest=${_row#*|}
    _db=${_rest%%|*}; _rest=${_rest#*|}
    _gw=${_rest%%|*}; _rest=${_rest#*|}
    _director=${_rest%%|*}; _servers=${_rest#*|}
    [ "$_head" = Healthy ] && [ "$_db" = Healthy ] &&
        [ "$_gw" = Running ] && [ "$_director" = Ready ] || return 1
    [ -n "$_servers" ] || return 1
    printf '%s' "$_servers" | tr ',' '\n' |
        awk -F: 'NF == 2 { seen=1; if ($1 != "Running" || $2 != "true") exit 1 } END { if (!seen) exit 1 }'
}

wait_for() {
    _phase="$1"
    shift
    set_state LAST_START_PHASE "$_phase" || return 1
    while ! "$@"; do sleep 2; done
}

stop_worker() {
    set_state LAST_SHUTDOWN_PHASE battlegroup-stop || exit 1
    "$BG_BIN" stop >> "$LOG" 2>&1 || exit 2
    set_state LAST_SHUTDOWN_PHASE pod-drain || exit 1
    wait_pods_gone
}

start_worker() {
    if bg_ready; then exit 0; fi
    wait_for k3s-api k3s_ready || exit 1
    wait_for database db_ready || exit 1
    wait_for operators operators_ready || exit 1
    wait_for webhook webhook_ready || exit 1
    set_state LAST_START_PHASE battlegroup-start || exit 1
    "$BG_BIN" start >> "$LOG" 2>&1 || exit 2
    wait_for battlegroup-ready bg_ready
}

case "$ACTION" in
    stop)
        _active=$(active_bg_count)
        _detect_rc=$?
        if [ "$_detect_rc" -ne 0 ]; then
            set_state DESIRED running || exit 1
            set_result SHUTDOWN running detect-unavailable || exit 1
            log "battlegroup state could not be read; conservatively attempting shutdown and preserving boot recovery"
        elif [ "${_active:-0}" -gt 0 ] 2>/dev/null; then
            set_state DESIRED running || exit 1
            set_result SHUTDOWN running detect || exit 1
        else
            set_state DESIRED stopped || exit 1
            set_result SHUTDOWN skipped battlegroup-stopped || exit 1
            log "battlegroup already stopped; no boot restore requested"
            exit 0
        fi
        if [ "$(get_state DESIRED)" = running ]; then
            if "$TIMEOUT" "$STOP_TIMEOUT" "$0" stop-worker; then
                set_result SHUTDOWN ok complete || exit 1
                log "graceful battlegroup shutdown completed"
            else
                _rc=$?
                set_result SHUTDOWN failed "timeout-or-exit-${_rc}" || true
                log "graceful battlegroup shutdown failed or timed out (exit $_rc); allowing OpenRC shutdown to continue"
            fi
        fi
        exit 0
        ;;
    stop-worker)
        stop_worker
        ;;
    start)
        if [ "$(get_state DESIRED)" != running ]; then
            set_result START skipped desired-stopped || exit 1
            log "boot reconciliation skipped because battlegroup was intentionally stopped"
            exit 0
        fi
        set_result START running detect || exit 1
        if "$TIMEOUT" "$START_TIMEOUT" "$0" start-worker; then
            set_result START ok complete || exit 1
            log "boot reconciliation completed; battlegroup healthy"
        else
            _rc=$?
            set_result START failed "timeout-or-exit-${_rc}" || true
            log "boot reconciliation failed or timed out (exit $_rc)"
        fi
        exit 0
        ;;
    start-worker)
        start_worker
        ;;
    status)
        printf 'desired=%s last_shutdown_result=%s last_shutdown_phase=%s last_shutdown_at=%s last_start_result=%s last_start_phase=%s last_start_at=%s\n' \
            "$(get_state DESIRED)" "$(get_state LAST_SHUTDOWN_RESULT)" \
            "$(get_state LAST_SHUTDOWN_PHASE)" "$(get_state LAST_SHUTDOWN_AT)" \
            "$(get_state LAST_START_RESULT)" "$(get_state LAST_START_PHASE)" \
            "$(get_state LAST_START_AT)"
        ;;
    *)
        echo "unsupported lifecycle action: $ACTION" >&2
        exit 64
        ;;
esac
LIFEEOF
    then
        fail "failed to stage Hyper-V lifecycle executable"
    fi

    if ! cat > "$SERVICE_STAGE" <<SERVICEEOF
#!/sbin/openrc-run
# DUNE_HYPERV_LIFECYCLE_MANAGED=1
description="Dune Hyper-V guest lifecycle reconciliation"
command="$LIFECYCLE_BIN"

depend() {
    need k3s
    after localmount
}

start() {
    ebegin "Reconciling Dune battlegroup after VM boot"
    if [ -f "$INITIAL_START_SENTINEL" ]; then
        rm -f "$INITIAL_START_SENTINEL"
    else
        "\$command" start
    fi
    eend 0
}

stop() {
    ebegin "Stopping Dune battlegroup before VM shutdown"
    "\$command" stop
    eend 0
}
SERVICEEOF
    then
        fail "failed to stage Hyper-V lifecycle OpenRC service"
    fi
    chmod 0755 "$BIN_STAGE" "$SERVICE_STAGE" ||
        fail "failed to make lifecycle files executable"
    sh -n "$BIN_STAGE" >/dev/null 2>&1 ||
        fail "staged lifecycle executable failed shell syntax validation"
    sh -n "$SERVICE_STAGE" >/dev/null 2>&1 ||
        fail "staged lifecycle service failed shell syntax validation"
}

snapshot_transaction() {
    mkdir "$TXN_DIR" || fail "failed to create exclusive lifecycle transaction directory"
    TXN_CREATED=1
    chmod 0700 "$TXN_DIR" || fail "failed to protect lifecycle transaction directory"
    if [ -f "$LIFECYCLE_BIN" ]; then cp -p "$LIFECYCLE_BIN" "$TXN_DIR/bin" || fail "failed to snapshot lifecycle executable"; HAD_BIN=1; fi
    if [ -f "$LIFECYCLE_SERVICE" ]; then cp -p "$LIFECYCLE_SERVICE" "$TXN_DIR/service" || fail "failed to snapshot lifecycle service"; HAD_SERVICE=1; fi
    if [ -f "$LIFECYCLE_STATE" ]; then cp -p "$LIFECYCLE_STATE" "$TXN_DIR/state" || fail "failed to snapshot lifecycle state"; HAD_STATE=1; fi
    [ -f "$LIFECYCLE_META" ] && HAD_META=1
    runlevel_has_lifecycle && HAD_RUNLEVEL=1
    service_started && PRIOR_SERVICE_STARTED=1
}

save_original_state() {
    [ -f "$LIFECYCLE_META" ] && return 0
    mkdir -p "$LIFECYCLE_BACKUP_DIR" || fail "failed to create lifecycle backup directory"
    if [ "$HAD_BIN" -eq 1 ]; then cp -p "$TXN_DIR/bin" "$LIFECYCLE_BACKUP_DIR/original.bin" || fail "failed to preserve original lifecycle executable"; fi
    if [ "$HAD_SERVICE" -eq 1 ]; then cp -p "$TXN_DIR/service" "$LIFECYCLE_BACKUP_DIR/original.service" || fail "failed to preserve original lifecycle service"; fi
    if [ "$HAD_STATE" -eq 1 ]; then cp -p "$TXN_DIR/state" "$LIFECYCLE_BACKUP_DIR/original.state" || fail "failed to preserve original lifecycle state"; fi
    cat > "$META_STAGE" <<METAEOF
HAD_BIN=$HAD_BIN
HAD_SERVICE=$HAD_SERVICE
HAD_STATE=$HAD_STATE
HAD_RUNLEVEL=$HAD_RUNLEVEL
PRIOR_SERVICE_STARTED=$PRIOR_SERVICE_STARTED
METAEOF
    chmod 0600 "$META_STAGE" || fail "failed to protect lifecycle install metadata"
    mv -f "$META_STAGE" "$LIFECYCLE_META" || fail "failed to publish lifecycle install metadata"
    chmod 0700 "$LIFECYCLE_BACKUP_DIR" || fail "failed to protect lifecycle backup directory"
}

install_metadata_valid() {
    [ -r "$LIFECYCLE_META" ] || return 1
    for _key in HAD_BIN HAD_SERVICE HAD_STATE HAD_RUNLEVEL PRIOR_SERVICE_STARTED; do
        _value=$(sed -n "s/^${_key}=//p" "$LIFECYCLE_META" 2>/dev/null | tail -n 1)
        [ "$_value" = 0 ] || [ "$_value" = 1 ] || return 1
    done
    [ "$(meta_value HAD_BIN)" -eq 0 ] || [ -f "$LIFECYCLE_BACKUP_DIR/original.bin" ] || return 1
    [ "$(meta_value HAD_SERVICE)" -eq 0 ] || [ -f "$LIFECYCLE_BACKUP_DIR/original.service" ] || return 1
    [ "$(meta_value HAD_STATE)" -eq 0 ] || [ -f "$LIFECYCLE_BACKUP_DIR/original.state" ] || return 1
}

initial_desired_state() {
    if ! _rows=$("$K3S_BIN" kubectl get pods -A --no-headers \
        -o custom-columns=NAME:.metadata.name,PHASE:.status.phase 2>/dev/null); then
        return 1
    fi
    _count=$(printf '%s\n' "$_rows" |
        awk '$1 ~ /(-sg-|-mq-|-sgw-|-tr-|-bgd-)/ && $2 != "Succeeded" && $2 != "Failed" { count++ } END { print count+0 }')
    if [ "${_count:-0}" -gt 0 ] 2>/dev/null; then printf running; else printf stopped; fi
}

install_lifecycle() {
    shutdown_channel_present || fail "Hyper-V shutdown VMBus channel is unavailable"
    hv_utils_present || fail "hv_utils is unavailable"
    [ -x "$K3S_BIN" ] || fail "required command missing: $K3S_BIN"
    [ -x "$K3S_SERVICE" ] || fail "required OpenRC service missing: $K3S_SERVICE"
    [ -x "$BG_BIN" ] || fail "required command missing: $BG_BIN"
    command -v "$TIMEOUT" >/dev/null 2>&1 || fail "required command missing: $TIMEOUT"
    for _required in awk grep sed tail tr; do command -v "$_required" >/dev/null 2>&1 || fail "required command missing: $_required"; done
    if [ -f "$LIFECYCLE_META" ]; then
        install_metadata_valid || fail "lifecycle install metadata or original backups are invalid"
    fi

    stage_lifecycle_files
    snapshot_transaction
    MUTATION_STARTED=1
    save_original_state

    mkdir -p "$LIFECYCLE_STATE_DIR" || fail "failed to create lifecycle state directory"
    if [ ! -f "$LIFECYCLE_STATE" ]; then
        _desired=$(initial_desired_state) ||
            fail "failed to inspect the current battlegroup state"
        printf 'DESIRED=%s\n' "$_desired" > "$LIFECYCLE_STATE" ||
            fail "failed to initialize lifecycle state"
        chmod 0600 "$LIFECYCLE_STATE" || fail "failed to protect lifecycle state"
    fi
    mv -f "$BIN_STAGE" "$LIFECYCLE_BIN" || fail "failed to publish lifecycle executable"
    mv -f "$SERVICE_STAGE" "$LIFECYCLE_SERVICE" || fail "failed to publish lifecycle OpenRC service"
    "$RC_UPDATE" add "$LIFECYCLE_NAME" default >/dev/null 2>&1 ||
        fail "failed to enable lifecycle OpenRC service"
    runlevel_has_lifecycle || fail "lifecycle service missing from default OpenRC runlevel"
    if ! service_started; then
        : > "$INITIAL_START_SENTINEL" || fail "failed to stage initial OpenRC start sentinel"
        SENTINEL_CREATED=1
        if ! "$RC_SERVICE" "$LIFECYCLE_NAME" start >/dev/null 2>&1; then
            rm -f "$INITIAL_START_SENTINEL"
            SENTINEL_CREATED=0
            fail "failed to start lifecycle OpenRC service"
        fi
        rm -f "$INITIAL_START_SENTINEL"
        SENTINEL_CREATED=0
    fi
    service_started || fail "lifecycle OpenRC service did not remain started"
    lifecycle_managed || fail "lifecycle files failed managed-artifact readback"

    MUTATION_STARTED=0
    cleanup_transaction
    log "Hyper-V lifecycle reconciled"
    emit_lifecycle_status
}

meta_value() {
    _key="$1"
    [ -r "$LIFECYCLE_META" ] || return 0
    sed -n "s/^${_key}=//p" "$LIFECYCLE_META" | tail -n 1
}

uninstall_lifecycle() {
    [ -r "$LIFECYCLE_META" ] || {
        lifecycle_managed || {
            echo DUNE_HYPERV_LIFECYCLE_UNINSTALL_OK changed=false
            exit 0
        }
        fail "lifecycle install metadata is missing; refusing to guess rollback state"
    }

    _had_bin=$(meta_value HAD_BIN)
    _had_service=$(meta_value HAD_SERVICE)
    _had_state=$(meta_value HAD_STATE)
    _had_runlevel=$(meta_value HAD_RUNLEVEL)
    _prior_started=$(meta_value PRIOR_SERVICE_STARTED)
    for _value in "$_had_bin" "$_had_service" "$_had_state" "$_had_runlevel" "$_prior_started"; do
        [ "$_value" = 0 ] || [ "$_value" = 1 ] ||
            fail "invalid lifecycle install metadata"
    done

    snapshot_transaction
    MUTATION_STARTED=1
    "$RC_SERVICE" "$LIFECYCLE_NAME" zap >/dev/null 2>&1 || true
    "$RC_UPDATE" del "$LIFECYCLE_NAME" default >/dev/null 2>&1 || true

    if [ "$_had_bin" -eq 1 ]; then
        [ -f "$LIFECYCLE_BACKUP_DIR/original.bin" ] || fail "original lifecycle executable backup is missing"
        cp -p "$LIFECYCLE_BACKUP_DIR/original.bin" "$LIFECYCLE_BIN" || fail "failed to restore original lifecycle executable"
    else
        rm -f "$LIFECYCLE_BIN"
    fi
    if [ "$_had_service" -eq 1 ]; then
        [ -f "$LIFECYCLE_BACKUP_DIR/original.service" ] || fail "original lifecycle service backup is missing"
        cp -p "$LIFECYCLE_BACKUP_DIR/original.service" "$LIFECYCLE_SERVICE" || fail "failed to restore original lifecycle service"
    else
        rm -f "$LIFECYCLE_SERVICE"
    fi
    if [ "$_had_state" -eq 1 ]; then
        [ -f "$LIFECYCLE_BACKUP_DIR/original.state" ] || fail "original lifecycle state backup is missing"
        mkdir -p "$(dirname "$LIFECYCLE_STATE")" || fail "failed to restore original lifecycle state directory"
        cp -p "$LIFECYCLE_BACKUP_DIR/original.state" "$LIFECYCLE_STATE" || fail "failed to restore original lifecycle state"
    else
        rm -f "$LIFECYCLE_STATE"
        rmdir "$LIFECYCLE_STATE_DIR" >/dev/null 2>&1 || true
    fi
    if [ "$_had_runlevel" -eq 1 ]; then
        "$RC_UPDATE" add "$LIFECYCLE_NAME" default >/dev/null 2>&1 ||
            fail "failed to restore original lifecycle runlevel"
    fi
    if [ "$_prior_started" -eq 1 ] && [ "$_had_service" -eq 1 ]; then
        "$RC_SERVICE" "$LIFECYCLE_NAME" start >/dev/null 2>&1 ||
            fail "failed to restart original lifecycle service"
    fi
    rm -rf "$LIFECYCLE_BACKUP_DIR"
    MUTATION_STARTED=0
    cleanup_transaction
    log "Hyper-V lifecycle integration uninstalled"
    echo DUNE_HYPERV_LIFECYCLE_UNINSTALL_OK changed=true
}

case "$ACTION" in
    recovery)
        reconcile_recovery
        ;;
    lifecycle-status)
        emit_lifecycle_status
        ;;
    lifecycle-install)
        install_lifecycle
        ;;
    lifecycle-uninstall)
        uninstall_lifecycle
        ;;
    *)
        fail "unsupported Hyper-V guest recovery action: $ACTION"
        ;;
esac
