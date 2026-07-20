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
#   reconciles both rules from the live cluster + socket state every minute, so a
#   pod restart self-heals in <=60s.
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
#   bridge ONLY when it positively detects public-only binding, actively REMOVES
#   it when it detects LAN/wildcard binding, and leaves the rules untouched when
#   binding is indeterminate (pods not up yet) -- never tearing down a working
#   rule on a guess. Detection is IPv4-only (a dual-stack IPv6 `::` bind must not
#   masquerade as a LAN bind and suppress a legitimately-needed bridge).
#
# DEFENDER-SAFE DESIGN
#   All persistence logic (writing the watchdog + the cron entry) lives here in
#   POSIX sh and runs on the Linux VM. DST only stages-and-runs this script over
#   SSH -- the same mechanism as dune-clear-partitions.start -- so the packaged
#   Windows app carries NO persistence-establishment code (that PowerShell
#   pattern is what tripped the Defender ML false positive in v11.0.1).
#
# Staged to /tmp by DST and run once with sudo on every Start / Restart.
# Idempotent and best-effort. Logged to /var/log/dune-dnat-watch.log.

set -u

WATCH=/usr/local/bin/dune-dnat-watch.sh
LOG=/var/log/dune-dnat-watch.log

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. Write the watchdog. Quoted heredoc -> nothing is expanded at write time;
#    the watchdog resolves everything dynamically when it runs.
# ---------------------------------------------------------------------------
cat > "$WATCH" <<'WATCHEOF'
#!/bin/sh
# Dune DNAT self-heal watchdog. Reconciles the RabbitMQ DNAT rule and the
# bind-detected game-UDP bridge from the live k3s + socket state. Idempotent;
# safe to run every minute. Installed + scheduled by dune-dnat-watch-install.sh.
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

KUBE="/usr/local/bin/k3s kubectl"
LOG=/var/log/dune-dnat-watch.log
RABBIT_PORT=31982
GAME_PORTS=7777:7810
GAME_LO=7777
GAME_HI=7810

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }
is_ipv4() { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

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
#   pub  = public IP bound, LAN/wildcard NOT bound -> bridge needed AND safe
#   lan  = LAN IP / 0.0.0.0 bound                  -> bridge would black-hole
#   none = no relevant listener visible            -> leave its rule unchanged
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

    if [ "$_lanwild" = 1 ]; then
        echo lan
    elif [ "$_pub" = 1 ]; then
        echo pub
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
        log "failed to install game-UDP bridge for port ${_port}"
    fi
}

NODE=$($KUBE get nodes --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -1 | tr -d ' ')
[ -z "$NODE" ] && exit 0

# Public IP = authoritative node ExternalIP (tracks IP changes, never hardcoded).
PUB=$($KUBE get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
# VM LAN IP = node InternalIP (the -d match for router-forwarded remote traffic).
VM_IP=$($KUBE get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
# Current mq-game pod IP from the service endpoints.
POD=$($KUBE get endpoints --all-namespaces 2>/dev/null | grep mq-game | awk '{print $3}' | cut -d, -f1 | cut -d: -f1 | head -1)

# PUB is the shared rewrite target for both rules -- without a valid one, never
# touch anything. A missing/`<none>` value must never delete a good rule.
if ! is_ipv4 "$PUB"; then log "node ExternalIP not a valid IPv4 ('$PUB'); leaving rules intact"; exit 0; fi

# --- RabbitMQ login: public:31982/tcp -> POD:5672 (needs a valid pod IP) ---
if is_ipv4 "$POD"; then
    if iptables -t nat -C PREROUTING -d "${PUB}/32" -p tcp --dport "$RABBIT_PORT" -j DNAT --to-destination "${POD}:5672" 2>/dev/null; then
        : # already correct
    else
        # Replacement IP validated above, so swapping the rule now is safe.
        iptables -t nat -S PREROUTING | grep -- "--dport ${RABBIT_PORT}" | grep -- "-j DNAT" | sed "s/^-A/-D/" | while read -r spec; do
            iptables -t nat $spec 2>/dev/null
        done
        iptables -t nat -I PREROUTING 1 -d "${PUB}/32" -p tcp --dport "$RABBIT_PORT" -j DNAT --to-destination "${POD}:5672"
        log "reconciled rabbitmq DNAT: ${PUB}:${RABBIT_PORT} -> ${POD}:5672"
    fi
else
    log "mq-game endpoint not a valid IPv4 ('$POD'); leaving rabbitmq rule intact"
fi

# --- Game-UDP bridge: <VM_IP>:7777-7810/udp -> PUB (needs a valid VM LAN IP) ---
if is_ipv4 "$VM_IP"; then
    _udp_snapshot=$(udp_listeners)
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
else
    log "node InternalIP not a valid IPv4 ('$VM_IP'); leaving game-UDP bridge intact"
fi

exit 0
WATCHEOF
chmod 0755 "$WATCH" 2>/dev/null

# ---------------------------------------------------------------------------
# 2. Retire the legacy hardcoded-public-IP sync script if present. It only
#    reconciled the OLD public IP's rule, which is exactly why the current-IP
#    rule went stale and broke remote "Connecting".
# ---------------------------------------------------------------------------
if [ -f /usr/local/sbin/dune-mq-dnat-sync.sh ]; then
    mv -f /usr/local/sbin/dune-mq-dnat-sync.sh "/usr/local/sbin/dune-mq-dnat-sync.sh.disabled.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    log "retired legacy /usr/local/sbin/dune-mq-dnat-sync.sh"
fi

# ---------------------------------------------------------------------------
# 3. Reconcile the root crontab: drop any prior DNAT watchdog/sync lines
#    (legacy or interim), then install the canonical every-minute entry.
# ---------------------------------------------------------------------------
( crontab -l 2>/dev/null | grep -v -e dune-mq-dnat-sync -e dune-rabbitmq-dnat-watch -e dune-dnat-watch ; echo "* * * * * $WATCH" ) | crontab -

# ---------------------------------------------------------------------------
# 4. Run once now so any current drift is fixed immediately, not in <=60s.
# ---------------------------------------------------------------------------
"$WATCH" 2>/dev/null

log "dune-dnat-watch install/refresh done"
echo DUNE_DNAT_WATCH_OK
