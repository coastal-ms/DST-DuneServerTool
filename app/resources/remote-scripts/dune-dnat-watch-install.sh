#!/bin/sh
# Install / refresh the Dune Awakening DNAT self-heal watchdog on the VM.
#
# WHY THIS EXISTS
#   Two host iptables DNAT rules keep remote players connectable. Both go stale
#   whenever the mq-game pod IP, the public IP, or the game's bind changes
#   WITHOUT a host reboot -- e.g. a pod-only battlegroup restart:
#     * RabbitMQ login:  public:31982/tcp          -> <mq-game pod>:5672
#     * Game-UDP bridge: <vm-lan-ip>:7777-7810/udp  -> public IP
#   The boot script /etc/local.d/dune-iptables.start only re-derives these at
#   BOOT, so a pod restart leaves a rule pointing at a dead pod IP (RabbitMQ) or
#   drops the game bridge, and remote players hang forever on "Connecting" /
#   time out with P34 (observed 2026-06-23: a ~19h stale RabbitMQ rule because a
#   prior hardcoded-IP sync script only watched the OLD public IP). This watchdog
#   reconciles game listeners continuously and cluster-derived addresses in an
#   independent bounded worker. Newly-bound public ports target exact-port DNAT
#   within the listener cadence; field confirmation remains pending.
#
#   THE GAME-UDP BRIDGE IS BIND-DETECTED, NOT UNCONDITIONAL.
#   A remote player's game traffic is forwarded by their home router to the VM's
#   LAN IP (e.g. 192.168.23.219:7778). When the Funcom game pods run hostNetwork
#   and bind their UDP ports to the PUBLIC IP only (verified 2026-07-07 by
#   tcpdump: packets to <lan-ip>:7778 drew "ICMP udp port unreachable" -> P34),
#   nothing listens on the LAN IP, so the packet is black-holed. The bridge
#   rewrites its destination to the public IP (a local eth0 alias where the pod
#   listens), which fixes the join AND cannot black-hole a same-LAN / self join
#   because the rewrite lands on a live LOCAL listener, never a WAN hairpin.
#   BUT on a host whose game binds 0.0.0.0 or the LAN IP instead ("I can connect
#   on the LOCAL IP"), traffic to the LAN IP ALREADY works, and rewriting it to
#   the public IP would send it to a port nothing listens on -> black hole. That
#   is exactly the regression removed in v12.16.9. So the watchdog installs the
#   bridge whenever it positively detects a public listener for that exact port
#   (public wins over a separate LAN listener), actively REMOVES it for LAN-only
#   binding, and leaves rules untouched when binding is indeterminate (pods not
#   up yet) -- never tearing down a working rule on a guess. Detection is
#   IPv4-only (a dual-stack IPv6 `::` bind must not masquerade as a LAN bind).
#
# DEFENDER-SAFE DESIGN
#   All persistence logic (watchdog, OpenRC service, health-check cron) lives
#   here in POSIX sh and runs on the Linux VM. DST only stages-and-runs this over
#   SSH -- the same mechanism as dune-clear-partitions.start -- so the packaged
#   Windows app carries NO persistence-establishment code (that PowerShell
#   pattern is what tripped the Defender ML false positive in v11.0.1).
#
# Staged to /tmp by DST and run once with sudo on every Start / Restart.
# Installation is transactional and fails closed. Logged to the VM watchdog log.

set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
if [ -n "${DUNE_DNAT_PATH_PREFIX:-}" ]; then PATH="$DUNE_DNAT_PATH_PREFIX:$PATH"; fi
export PATH

WATCH="${DUNE_DNAT_INSTALL_WATCH:-/usr/local/bin/dune-dnat-watch.sh}"
SERVICE="${DUNE_DNAT_INSTALL_SERVICE:-/etc/init.d/dune-dnat-watch}"
LOG="${DUNE_DNAT_INSTALL_LOG:-/var/log/dune-dnat-watch.log}"
K3S_REQUIRED="${DUNE_DNAT_K3S:-/usr/local/bin/k3s}"
TXN="$$"
WATCH_STAGE="${WATCH}.new.${TXN}"
SERVICE_STAGE="${SERVICE}.new.${TXN}"
WATCH_BACKUP="${WATCH}.previous.${TXN}"
SERVICE_BACKUP="${SERVICE}.previous.${TXN}"
CRON_BACKUP="/tmp/dune-dnat-watch.cron.${TXN}"
CRON_FILTERED="/tmp/dune-dnat-watch.cron-filtered.${TXN}"
STATE_DIR="${DUNE_DNAT_STATE_DIR:-/run/dune-dnat-watch}"
OWNER_FILE="$STATE_DIR/owner"
LISTENER_HEARTBEAT="$STATE_DIR/listener.heartbeat"
MUTATION_LOCK="$STATE_DIR/mutation.lock"
OWNER_SNAPSHOT="/tmp/dune-dnat-watch.owner.${TXN}"
HEARTBEAT_SNAPSHOT="/tmp/dune-dnat-watch.heartbeat.${TXN}"
CUTOVER_MARKER="/tmp/dune-dnat-watch.cutover.${TXN}"
PRE_CUTOVER_OWNER=""
MIGRATION_STARTED=0
HAD_WATCH=0
HAD_SERVICE=0
HAD_CRONTAB=0
HAD_RUNLEVEL=0
PRIOR_SERVICE_RUNNING=0

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }
cleanup_transaction_files() {
    rm -f "$WATCH_STAGE" "$SERVICE_STAGE" "$WATCH_BACKUP" "$SERVICE_BACKUP" \
        "$CRON_BACKUP" "$CRON_FILTERED" "$OWNER_SNAPSHOT" \
        "$HEARTBEAT_SNAPSHOT" "$CUTOVER_MARKER"
}

watch_pids() {
    pgrep -f '[/]usr/local/bin/dune-dnat-watch[.]sh([[:space:]]|$)' 2>/dev/null || true
}

stop_watch_processes() {
    if [ -f "$SERVICE" ]; then rc-service dune-dnat-watch stop >/dev/null 2>&1 || true; fi
    _stop_wait=0
    while [ -n "$(watch_pids)" ] && [ "$_stop_wait" -lt 5 ]; do
        _stop_pids=$(watch_pids)
        [ -z "$_stop_pids" ] || kill $_stop_pids 2>/dev/null || true
        sleep 1
        _stop_wait=$((_stop_wait + 1))
    done
    _stop_pids=$(watch_pids)
    if [ -n "$_stop_pids" ]; then
        kill -9 $_stop_pids 2>/dev/null || true
        sleep 1
    fi
    [ -z "$(watch_pids)" ]
}

clear_runtime_state() {
    mkdir -p "$STATE_DIR" || return 1
    (
        flock -x 9 || exit 1
        rm -f "$OWNER_FILE" "$LISTENER_HEARTBEAT"
    ) 9>"$MUTATION_LOCK"
}

invalidate_runtime_state() {
    mkdir -p "$STATE_DIR" || return 1
    : > "$OWNER_SNAPSHOT" || return 1
    : > "$HEARTBEAT_SNAPSHOT" || return 1
    (
        flock -x 9 || exit 1
        if [ -r "$OWNER_FILE" ]; then cp -p "$OWNER_FILE" "$OWNER_SNAPSHOT" || exit 1; fi
        if [ -r "$LISTENER_HEARTBEAT" ]; then cp -p "$LISTENER_HEARTBEAT" "$HEARTBEAT_SNAPSHOT" || exit 1; fi
        rm -f "$OWNER_FILE" "$LISTENER_HEARTBEAT" || exit 1
        touch "$CUTOVER_MARKER" || exit 1
    ) 9>"$MUTATION_LOCK" || return 1
    PRE_CUTOVER_OWNER=$(cat "$OWNER_SNAPSHOT" 2>/dev/null)
    return 0
}

replacement_healthy() {
    [ -r "$OWNER_FILE" ] && [ -r "$LISTENER_HEARTBEAT" ] || return 1
    _replacement_owner=$(cat "$OWNER_FILE" 2>/dev/null) || return 1
    _replacement_heartbeat_owner=$(cat "$LISTENER_HEARTBEAT" 2>/dev/null) || return 1
    [ -n "$_replacement_owner" ] &&
        [ "$_replacement_owner" != "$PRE_CUTOVER_OWNER" ] &&
        [ "$_replacement_heartbeat_owner" = "$_replacement_owner" ] &&
        [ "$LISTENER_HEARTBEAT" -nt "$CUTOVER_MARKER" ] &&
        "$WATCH" --healthcheck >/dev/null 2>&1
}

restore_prior_state() {
    log "DNAT watchdog migration failed; restoring previous files and lifecycle state"
    stop_watch_processes || log "rollback warning: watchdog processes did not fully exit"
    clear_runtime_state || log "rollback warning: failed to clear cutover runtime state"

    if [ "$HAD_WATCH" -eq 1 ] && [ -f "$WATCH_BACKUP" ]; then
        mv -f "$WATCH_BACKUP" "$WATCH" || log "rollback warning: failed to restore $WATCH"
    else
        rm -f "$WATCH"
    fi
    if [ "$HAD_SERVICE" -eq 1 ] && [ -f "$SERVICE_BACKUP" ]; then
        mv -f "$SERVICE_BACKUP" "$SERVICE" || log "rollback warning: failed to restore $SERVICE"
    else
        rm -f "$SERVICE"
    fi

    if [ "$HAD_RUNLEVEL" -eq 1 ]; then
        rc-update add dune-dnat-watch default >/dev/null 2>&1 ||
            log "rollback warning: failed to restore OpenRC runlevel"
    else
        rc-update del dune-dnat-watch default >/dev/null 2>&1 || true
    fi

    if [ "$HAD_CRONTAB" -eq 1 ]; then
        crontab "$CRON_BACKUP" >/dev/null 2>&1 ||
            log "rollback warning: failed to restore prior crontab"
    else
        crontab -r >/dev/null 2>&1 || true
    fi

    if [ "$PRIOR_SERVICE_RUNNING" -eq 1 ] && [ "$HAD_SERVICE" -eq 1 ]; then
        rc-service dune-dnat-watch start >/dev/null 2>&1 ||
            log "rollback warning: failed to restart prior service"
    fi
}

fail() {
    _fail_message="$*"
    log "$_fail_message"
    if [ "$MIGRATION_STARTED" -eq 1 ]; then restore_prior_state; fi
    cleanup_transaction_files
    echo DUNE_DNAT_WATCH_FAILED
    exit 1
}

on_interrupt() {
    log "DNAT watchdog installer interrupted"
    if [ "$MIGRATION_STARTED" -eq 1 ]; then restore_prior_state; fi
    cleanup_transaction_files
    exit 1
}
trap on_interrupt HUP INT TERM

for _required in supervise-daemon rc-service rc-update crontab timeout stat flock pgrep; do
    command -v "$_required" >/dev/null 2>&1 || fail "required command missing: $_required"
done
[ -x "$K3S_REQUIRED" ] || fail "required command missing: $K3S_REQUIRED"

# ---------------------------------------------------------------------------
# 1. Write the watchdog. Quoted heredoc -> nothing is expanded at write time;
#    the watchdog resolves everything dynamically when it runs.
# ---------------------------------------------------------------------------
if ! cat > "$WATCH_STAGE" <<'WATCHEOF'
#!/bin/sh
# Dune DNAT self-heal watchdog. Reconciles the RabbitMQ DNAT rule and the
# bind-detected game-UDP bridge from the live k3s + socket state. The supervised
# listener loop targets one snapshot per second; k3s runs in a bounded worker.
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
if [ -n "${DUNE_DNAT_PATH_PREFIX:-}" ]; then PATH="$DUNE_DNAT_PATH_PREFIX:$PATH"; fi
export PATH

K3S="${DUNE_DNAT_K3S:-/usr/local/bin/k3s}"
LOG="${DUNE_DNAT_LOG:-/var/log/dune-dnat-watch.log}"
RABBIT_PORT=31982
GAME_PORTS=7777:7810
GAME_LO=7777
GAME_HI=7810
LOOP_SLEEP="${DUNE_DNAT_LOOP_SLEEP:-1}"
CLUSTER_SLEEP="${DUNE_DNAT_CLUSTER_SLEEP:-5}"
MAX_PASSES="${DUNE_DNAT_MAX_PASSES:-0}"
STATE_DIR="${DUNE_DNAT_STATE_DIR:-/run/dune-dnat-watch}"
CLUSTER_STATE="$STATE_DIR/cluster.state"
OWNER_FILE="$STATE_DIR/owner"
LISTENER_HEARTBEAT="$STATE_DIR/listener.heartbeat"
WORKER_HEARTBEAT="$STATE_DIR/worker.heartbeat"
MUTATION_LOCK="$STATE_DIR/mutation.lock"
FAILURE_LOG_STAMP="$STATE_DIR/failure-log.stamp"
WORKER_STALE_SEC=15
LISTENER_STALE_SEC=5

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }
is_ipv4() { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
kube() { timeout 3 "$K3S" kubectl --request-timeout=2s "$@"; }
file_age() {
    _age_file="$1"
    [ -r "$_age_file" ] || return 1
    _age_now=$(date +%s)
    _age_mtime=$(stat -c %Y "$_age_file" 2>/dev/null) || return 1
    _age_value=$((_age_now - _age_mtime))
    [ "$_age_value" -ge 0 ] || _age_value=0
    printf '%s\n' "$_age_value"
}

# IPv4-only UDP listener addresses ("addr:port" per line). Funcom game pods run
# hostNetwork so their binds are visible in the host net namespace. -4 / udp-only
# filtering keeps a dual-stack IPv6 `::` bind from looking like a LAN bind.
udp_listeners() {
    _out=""
    if command -v ss >/dev/null 2>&1; then
        _out=$(ss -H -u -l -n -4 2>/dev/null | awk '{print $4}')
    fi
    # Fall back to netstat if ss is absent or rejected `-H` on this image.
    [ -n "$_out" ] || _out=$(netstat -uln 2>/dev/null | awk '$1=="udp"{print $4}')
    printf '%s\n' "$_out"
}

# Classify one game UDP port:
#   pub  = public IP bound (including a dual bind) -> bridge needed
#   lan  = LAN IP / 0.0.0.0 bound without public  -> bridge not needed
#   none = no relevant listener visible           -> leave its rule unchanged
#
# Listener state is intentionally evaluated per port. Funcom can mix public-only
# and LAN-bound map ports within the dynamic range.
game_port_state() {
    _want_port="$1"
    _pub=0
    _lanwild=0
    for _e in $_udp_snapshot; do
        _port=${_e##*:}
        _addr=${_e%:*}
        [ "$_port" = "$_want_port" ] || continue
        case "$_addr" in
            "$PUB")                  _pub=1 ;;
            "$VM_IP"|0.0.0.0|'*'|'') _lanwild=1 ;;
        esac
    done

    # A public listener wins when separate game processes also bind the LAN IP.
    # Router-forwarded traffic otherwise reaches the wrong process and the map
    # handshake stalls. A LAN bind suppresses DNAT only when no public listener
    # exists for this exact port.
    if [ "$_pub" = 1 ]; then
        echo pub
    elif [ "$_lanwild" = 1 ]; then
        echo lan
    else
        echo none
    fi
}

# Restrict cleanup to UDP DNAT rules whose destination is this Dune VM. Do not
# touch unrelated DNAT rules that happen to use a game-range port.
game_bridge_rules() {
    iptables -t nat -S PREROUTING 2>/dev/null |
        grep -F -- "-d ${VM_IP}/32" |
        grep -F -- '-p udp' |
        grep -F -- '-j DNAT'
}

purge_legacy_game_bridge() {
    game_bridge_rules |
        grep -E -- "--dport[[:space:]]+${GAME_PORTS}([[:space:]]|$)" |
        sed 's/^-A/-D/' |
        while read -r _spec; do
            iptables -t nat $_spec 2>/dev/null &&
                log "removed legacy broad game-UDP DNAT rule: $_spec"
        done
}

purge_game_bridge_port() {
    _port="$1"
    game_bridge_rules |
        grep -E -- "--dport[[:space:]]+${_port}([[:space:]]|$)" |
        sed 's/^-A/-D/' |
        while read -r _spec; do
            iptables -t nat $_spec 2>/dev/null &&
                log "removed game-UDP DNAT rule for port ${_port}: $_spec"
        done
}

ensure_game_bridge_port() {
    _port="$1"
    if iptables -t nat -C PREROUTING -d "$VM_IP" -p udp --dport "$_port" -j DNAT --to-destination "$PUB" 2>/dev/null; then
        return 0
    fi

    purge_game_bridge_port "$_port"
    if iptables -t nat -I PREROUTING 1 -d "$VM_IP" -p udp --dport "$_port" -j DNAT --to-destination "$PUB" 2>/dev/null; then
        log "installed game-UDP bridge: ${VM_IP}:${_port} -> ${PUB}:${_port} (game binds public IP only)"
    else
        log_reconcile_failure "failed to install game-UDP bridge for port ${_port}"
    fi
}

PUB=""
VM_IP=""

log_reconcile_failure() {
    _failure_now=$(date +%s)
    _failure_last=0
    if [ -r "$FAILURE_LOG_STAMP" ]; then _failure_last=$(cat "$FAILURE_LOG_STAMP" 2>/dev/null); fi
    case "$_failure_last" in *[!0-9]*|'') _failure_last=0 ;; esac
    if [ "$_failure_last" -eq 0 ] || [ $((_failure_now - _failure_last)) -ge 60 ]; then
        log "$*"
        printf '%s\n' "$_failure_now" > "$FAILURE_LOG_STAMP"
    fi
}

load_cluster_state() {
    [ -r "$CLUSTER_STATE" ] || return 1
    _cached_state=$(cat "$CLUSTER_STATE" 2>/dev/null) || return 1
    set -- $_cached_state
    [ "$#" -eq 2 ] || return 1
    is_ipv4 "$1" && is_ipv4 "$2" || return 1
    PUB="$1"
    VM_IP="$2"
}

worker_owned() {
    [ -r "$OWNER_FILE" ] && [ "$(cat "$OWNER_FILE" 2>/dev/null)" = "$1" ]
}

publish_owner() {
    _publish_token="$1"
    (
        flock -x 9 || exit 1
        _publish_tmp="${OWNER_FILE}.$$"
        printf '%s\n' "$_publish_token" > "$_publish_tmp" &&
            mv -f "$_publish_tmp" "$OWNER_FILE"
    ) 9>"$MUTATION_LOCK"
}

write_cluster_state() {
    _state_pub="$1"
    _state_vm="$2"
    _state_token="$3"
    (
        flock -x 9 || exit 1
        worker_owned "$_state_token" || exit 0
        _state_tmp="${CLUSTER_STATE}.$$"
        if printf '%s\n%s\n' "$_state_pub" "$_state_vm" > "$_state_tmp" &&
           mv -f "$_state_tmp" "$CLUSTER_STATE"; then
            exit 0
        fi
        rm -f "$_state_tmp"
        exit 1
    ) 9>"$MUTATION_LOCK"
}

write_listener_heartbeat() {
    (
        flock -x 9 || exit 1
        # Owner publication uses this same lock, so the check remains valid
        # through the atomic rename.
        worker_owned "$_owner_token" || exit 1
        _listener_tmp="${LISTENER_HEARTBEAT}.$$"
        if printf '%s\n' "$_owner_token" > "$_listener_tmp" &&
           mv -f "$_listener_tmp" "$LISTENER_HEARTBEAT"; then
            exit 0
        fi
        rm -f "$_listener_tmp"
        exit 1
    ) 9>"$MUTATION_LOCK"
}

clear_owner() {
    _clear_token="$1"
    (
        flock -x 9 || exit 1
        if worker_owned "$_clear_token"; then rm -f "$OWNER_FILE"; fi
    ) 9>"$MUTATION_LOCK"
}

reconcile_rabbitmq() {
    _rabbit_pub="$1"
    _rabbit_pod="$2"
    _rabbit_token="$3"
    if ! is_ipv4 "$_rabbit_pub" || ! is_ipv4 "$_rabbit_pod"; then
        return
    fi

    (
        flock -x 9 || exit 1
        # Ownership is checked after acquiring the kernel-released mutation lock.
        worker_owned "$_rabbit_token" || exit 0
        if iptables -t nat -C PREROUTING -d "${_rabbit_pub}/32" -p tcp --dport "$RABBIT_PORT" -j DNAT --to-destination "${_rabbit_pod}:5672" 2>/dev/null; then
            exit 0
        fi
        iptables -t nat -S PREROUTING | grep -- "--dport ${RABBIT_PORT}" | grep -- "-j DNAT" | sed "s/^-A/-D/" | while read -r _spec; do
            iptables -t nat $_spec 2>/dev/null
        done
        if iptables -t nat -I PREROUTING 1 -d "${_rabbit_pub}/32" -p tcp --dport "$RABBIT_PORT" -j DNAT --to-destination "${_rabbit_pod}:5672"; then
            log "reconciled rabbitmq DNAT: ${_rabbit_pub}:${RABBIT_PORT} -> ${_rabbit_pod}:5672"
        else
            log_reconcile_failure "failed to install rabbitmq DNAT for endpoint ${_rabbit_pod}"
        fi
    ) 9>"$MUTATION_LOCK"
}

run_cluster_pass() {
    _pass_token="$1"
    _addresses=$(kube get nodes -o jsonpath='{range .items[0].status.addresses[*]}{.type}={.address}{"\n"}{end}' 2>/dev/null)
    _worker_pub=$(printf '%s\n' "$_addresses" | awk -F= '$1=="ExternalIP"{print $2; exit}')
    _worker_vm=$(printf '%s\n' "$_addresses" | awk -F= '$1=="InternalIP"{print $2; exit}')
    if is_ipv4 "$_worker_pub" && is_ipv4 "$_worker_vm" && worker_owned "$_pass_token"; then
        if write_cluster_state "$_worker_pub" "$_worker_vm" "$_pass_token"; then
            _last_cluster_problem=""
        else
            _problem="failed to update atomic cluster cache; preserving prior cache and rules"
            if [ "$_problem" != "$_last_cluster_problem" ]; then log "$_problem"; fi
            _last_cluster_problem="$_problem"
        fi
    else
        _problem="node addresses unavailable/invalid; preserving cached addresses and rules"
        if [ "$_problem" != "$_last_cluster_problem" ]; then log "$_problem"; fi
        _last_cluster_problem="$_problem"
    fi

    _worker_pod=$(kube get endpoints --all-namespaces 2>/dev/null | grep mq-game | awk '{print $3}' | cut -d, -f1 | cut -d: -f1 | head -1)
    if is_ipv4 "$_worker_pub" && is_ipv4 "$_worker_pod"; then
        reconcile_rabbitmq "$_worker_pub" "$_worker_pod" "$_pass_token"
        _last_rabbit_problem=""
    else
        _problem="rabbitmq endpoint unavailable/invalid; leaving rule intact"
        if [ "$_problem" != "$_last_rabbit_problem" ]; then log "$_problem"; fi
        _last_rabbit_problem="$_problem"
    fi
}

run_cluster_worker() {
    _worker_token="$1"
    _worker_parent="$2"
    _last_cluster_problem=""
    _last_rabbit_problem=""

    while kill -0 "$_worker_parent" 2>/dev/null && worker_owned "$_worker_token"; do
        run_cluster_pass "$_worker_token"
        worker_owned "$_worker_token" || return
        touch "$WORKER_HEARTBEAT"
        sleep "$CLUSTER_SLEEP"
    done
}

reconcile_game_udp() {
    _game_token="$1"
    # Invalid/indeterminate cached addresses must never remove a working bridge.
    load_cluster_state || return

    # Exactly one listener snapshot per pass. Public wins over LAN on each port.
    _udp_snapshot=$(udp_listeners)
    (
        flock -x 9 || exit 1
        # A superseded listener cannot mutate after replacement owns the service.
        worker_owned "$_game_token" || exit 0
        _legacy_reconciled=0
        _p="$GAME_LO"
        while [ "$_p" -le "$GAME_HI" ]; do
            _state=$(game_port_state "$_p")
            if [ "$_state" != none ] && [ "$_legacy_reconciled" = 0 ]; then
                purge_legacy_game_bridge
                _legacy_reconciled=1
            fi
            case "$_state" in
                pub)  ensure_game_bridge_port "$_p" ;;
                lan)  purge_game_bridge_port "$_p" ;;
                none) : ;; # inactive/indeterminate -> preserve any exact-port rule
            esac
            _p=$((_p + 1))
        done
    ) 9>"$MUTATION_LOCK"
}

start_cluster_worker() {
    touch "$WORKER_HEARTBEAT"
    "$0" --cluster-loop "$_owner_token" "$$" &
    _worker_pid=$!
}

stop_cluster_worker() {
    if [ -n "${_worker_pid:-}" ]; then
        if kill -0 "$_worker_pid" 2>/dev/null; then
            kill "$_worker_pid" 2>/dev/null || true
        fi
        wait "$_worker_pid" 2>/dev/null || true
    fi
}

cleanup_loop() {
    stop_cluster_worker
    clear_owner "$_owner_token"
}

ensure_cluster_worker() {
    _worker_age=$(file_age "$WORKER_HEARTBEAT" 2>/dev/null) || _worker_age=$((WORKER_STALE_SEC + 1))
    if ! kill -0 "$_worker_pid" 2>/dev/null || [ "$_worker_age" -gt "$WORKER_STALE_SEC" ]; then
        stop_cluster_worker
        start_cluster_worker
    fi
}

run_loop() {
    mkdir -p "$STATE_DIR" || exit 1
    _owner_token="$$-$(date +%s)"
    publish_owner "$_owner_token" || exit 1
    _worker_pid=""
    _passes=0
    trap cleanup_loop EXIT
    trap 'exit 0' HUP INT TERM
    start_cluster_worker

    while :; do
        # A newer supervisor instance atomically replaces ownership. An orphaned
        # old listener exits before it can overlap any reconciliation pass.
        worker_owned "$_owner_token" || return 0
        reconcile_game_udp "$_owner_token"
        if ! write_listener_heartbeat; then
            # Replacement can acquire ownership between the game pass and the
            # heartbeat lock. That is a clean handoff, not a service failure.
            worker_owned "$_owner_token" || return 0
            log "failed to update listener heartbeat; exiting for supervisor restart"
            cleanup_loop
            return 1
        fi
        ensure_cluster_worker
        _passes=$((_passes + 1))
        if [ "$MAX_PASSES" -gt 0 ] && [ "$_passes" -ge "$MAX_PASSES" ]; then
            return
        fi
        sleep "$LOOP_SLEEP"
    done
}

run_once() {
    healthcheck >/dev/null 2>&1 && return 0
    mkdir -p "$STATE_DIR" || return 1
    _owner_token="once-$$-$(date +%s)"
    publish_owner "$_owner_token" || return 1
    _last_cluster_problem=""
    _last_rabbit_problem=""
    run_cluster_pass "$_owner_token"
    reconcile_game_udp "$_owner_token"
    clear_owner "$_owner_token"
}

healthcheck() {
    _listener_age=$(file_age "$LISTENER_HEARTBEAT" 2>/dev/null) || return 1
    _listener_owner=$(cat "$LISTENER_HEARTBEAT" 2>/dev/null) || return 1
    worker_owned "$_listener_owner" &&
        [ "$_listener_age" -le "$LISTENER_STALE_SEC" ]
}

case "${1:-}" in
    --loop) run_loop ;;
    --cluster-loop) run_cluster_worker "$2" "$3" ;;
    --healthcheck) healthcheck ;;
    --once|'') run_once ;;
    *) echo "usage: $0 [--loop|--once|--healthcheck]" >&2; exit 2 ;;
esac
WATCHEOF
then
    fail "failed to stage $WATCH"
fi
chmod 0755 "$WATCH_STAGE" 2>/dev/null || fail "failed to chmod staged watchdog"
sh -n "$WATCH_STAGE" >/dev/null 2>&1 || fail "staged watchdog failed shell syntax validation"

# ---------------------------------------------------------------------------
# 2. Install an OpenRC service. supervise-daemon owns exactly one foreground
#    loop and respawns it after failure. No lock file exists, so a stale lock can
#    never disable reconciliation permanently.
# ---------------------------------------------------------------------------
if ! cat > "$SERVICE_STAGE" <<'SERVICEEOF'
#!/sbin/openrc-run
name="Dune DNAT listener reconciler"
description="Continuously reconciles Dune RabbitMQ and game UDP DNAT"

supervisor=supervise-daemon
command="/usr/local/bin/dune-dnat-watch.sh"
command_args="--loop"
respawn_delay=2
respawn_max=0
healthcheck_delay=5
healthcheck_timer=5

depend() {
    need localmount
    after k3s
}

healthcheck() {
    "$command" --healthcheck
}
SERVICEEOF
then
    fail "failed to stage $SERVICE"
fi
chmod 0755 "$SERVICE_STAGE" 2>/dev/null || fail "failed to chmod staged OpenRC service"
sh -n "$SERVICE_STAGE" >/dev/null 2>&1 || fail "staged OpenRC service failed shell syntax validation"

# Snapshot every prior lifecycle surface before changing live state.
if [ -f "$WATCH" ]; then cp -p "$WATCH" "$WATCH_BACKUP" || fail "failed to snapshot prior watchdog"; HAD_WATCH=1; fi
if [ -f "$SERVICE" ]; then cp -p "$SERVICE" "$SERVICE_BACKUP" || fail "failed to snapshot prior service"; HAD_SERVICE=1; fi
if crontab -l > "$CRON_BACKUP" 2>/dev/null; then
    HAD_CRONTAB=1
else
    : > "$CRON_BACKUP" || fail "failed to initialize crontab snapshot"
fi
if rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])dune-dnat-watch([[:space:]]|$)'; then HAD_RUNLEVEL=1; fi
if [ "$HAD_SERVICE" -eq 1 ] && rc-service dune-dnat-watch status >/dev/null 2>&1; then PRIOR_SERVICE_RUNNING=1; fi

MIGRATION_STARTED=1

# Quiesce cron first, then stop and verify every old watcher process exited.
grep -v -e dune-mq-dnat-sync -e dune-rabbitmq-dnat-watch -e dune-dnat-watch "$CRON_BACKUP" > "$CRON_FILTERED" 2>/dev/null || true
[ -f "$CRON_FILTERED" ] || fail "failed to prepare migration crontab"
crontab "$CRON_FILTERED" >/dev/null 2>&1 || fail "failed to quiesce prior DNAT watchdog cron"
stop_watch_processes || fail "prior DNAT watchdog processes did not fully exit"
invalidate_runtime_state || fail "failed to invalidate prior DNAT watchdog runtime state"

# Same-directory rename publishes each fully-validated staged file atomically.
mv -f "$WATCH_STAGE" "$WATCH" || fail "failed to publish staged watchdog"
mv -f "$SERVICE_STAGE" "$SERVICE" || fail "failed to publish staged OpenRC service"

rc-update add dune-dnat-watch default >/dev/null 2>&1 || fail "failed to enable dune-dnat-watch in OpenRC"
rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])dune-dnat-watch([[:space:]]|$)' ||
    fail "dune-dnat-watch missing from default OpenRC runlevel"

# ---------------------------------------------------------------------------
# 3. Restart onto the refreshed executable, then require a distinct owner and
#    heartbeat written after the cutover marker. Age alone cannot prove that the
#    replacement started because a SIGKILL fallback may leave fresh old files.
# ---------------------------------------------------------------------------
# Ensure second-resolution filesystems can order the replacement heartbeat
# strictly after the cutover marker.
sleep 1
rc-service dune-dnat-watch restart >/dev/null 2>&1 ||
    fail "failed to start supervised dune-dnat-watch service"
rc-service dune-dnat-watch status >/dev/null 2>&1 ||
    fail "dune-dnat-watch service did not remain running"
_health_wait=0
while ! replacement_healthy; do
    _health_wait=$((_health_wait + 1))
    [ "$_health_wait" -lt 6 ] || fail "replacement dune-dnat-watch did not publish a fresh owner and heartbeat"
    sleep 1
done

# ---------------------------------------------------------------------------
# 4. Cron is only a heartbeat health check. Install it after replacement health
#    is proven so cron cannot race the controlled service cutover.
# ---------------------------------------------------------------------------
CRON_LINE="* * * * * $WATCH --healthcheck >/dev/null 2>&1 || $SERVICE restart >/dev/null 2>&1"
if ! ( cat "$CRON_FILTERED"; echo "$CRON_LINE" ) | crontab -; then
    fail "failed to install dune-dnat-watch cron health check"
fi
_cron_count=$(crontab -l 2>/dev/null | grep -Fxc "$CRON_LINE")
[ "$_cron_count" -eq 1 ] || fail "canonical dune-dnat-watch cron health check missing or duplicated"
_other_dnat_cron=$(crontab -l 2>/dev/null | grep -F dune-dnat-watch | grep -Fvx "$CRON_LINE")
[ -z "$_other_dnat_cron" ] || fail "non-canonical dune-dnat-watch cron entry remains"

MIGRATION_STARTED=0
cleanup_transaction_files

# Retire the old hardcoded-public-IP helper only after the replacement service
# and lifecycle state are fully validated. A failed migration leaves it intact.
if [ -f /usr/local/sbin/dune-mq-dnat-sync.sh ]; then
    mv -f /usr/local/sbin/dune-mq-dnat-sync.sh "/usr/local/sbin/dune-mq-dnat-sync.sh.disabled.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    log "retired legacy /usr/local/sbin/dune-mq-dnat-sync.sh"
fi

log "dune-dnat-watch install/refresh done"
echo DUNE_DNAT_WATCH_OK
