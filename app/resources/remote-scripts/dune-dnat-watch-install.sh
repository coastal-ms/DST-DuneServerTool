#!/bin/sh
# Install / refresh the Dune Awakening DNAT self-heal watchdog on the VM.
#
# WHY THIS EXISTS
#   The host iptables DNAT rules that forward external player traffic to the
#   in-cluster pods go stale whenever the mq-game pod IP (or the public IP)
#   changes WITHOUT a host reboot -- e.g. a pod-only battlegroup restart.
#     * RabbitMQ login:  public:31982/tcp -> <mq-game pod>:5672
#     * Game servers:    <vm-ip>:7777-7810/udp -> public
#   The boot script /etc/local.d/dune-iptables.start only re-derives these at
#   BOOT, so a pod restart leaves the RabbitMQ rule pointing at a dead pod IP
#   and remote players hang forever on "Connecting" (observed 2026-06-23: a
#   ~19h stale rule because a prior hardcoded-IP sync script only watched the
#   OLD public IP). This watchdog reconciles both rules from the live cluster
#   state every minute, so a pod restart self-heals in <=60s.
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
# Dune DNAT self-heal watchdog. Reconciles the RabbitMQ + game-port DNAT rules
# from the live k3s cluster state. Idempotent; safe to run every minute.
# Installed + scheduled by dune-dnat-watch-install.sh (shipped with DST).
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

KUBE="/usr/local/bin/k3s kubectl"
LOG=/var/log/dune-dnat-watch.log
RABBIT_PORT=31982
GAME_PORTS=7777:7810

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }

NODE=$($KUBE get nodes --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -1 | tr -d ' ')
[ -z "$NODE" ] && exit 0

# Public IP = authoritative node ExternalIP (tracks IP changes, never hardcoded).
PUB=$($KUBE get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
VM_IP=$($KUBE get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
# Current mq-game pod IP from the service endpoints.
POD=$($KUBE get endpoints --all-namespaces 2>/dev/null | grep mq-game | awk '{print $3}' | cut -d, -f1 | cut -d: -f1 | head -1)

[ -z "$PUB" ] && { log "no node ExternalIP; skip"; exit 0; }
[ -z "$POD" ] && { log "no mq-game pod IP; skip"; exit 0; }

# --- RabbitMQ login: public:31982/tcp -> POD:5672 ---
if iptables -t nat -C PREROUTING -d "${PUB}/32" -p tcp --dport "$RABBIT_PORT" -j DNAT --to-destination "${POD}:5672" 2>/dev/null; then
    : # already correct
else
    iptables -t nat -S PREROUTING | grep -- "--dport ${RABBIT_PORT}" | grep -- "-j DNAT" | sed "s/^-A/-D/" | while read -r spec; do
        iptables -t nat $spec 2>/dev/null
    done
    iptables -t nat -I PREROUTING 1 -d "${PUB}/32" -p tcp --dport "$RABBIT_PORT" -j DNAT --to-destination "${POD}:5672"
    log "reconciled rabbitmq DNAT: ${PUB}:${RABBIT_PORT} -> ${POD}:5672"
fi

# --- Game servers: VM_IP:7777-7810/udp -> PUB ---
if [ -n "$VM_IP" ]; then
    if iptables -t nat -C PREROUTING -d "$VM_IP" -p udp --dport "$GAME_PORTS" -j DNAT --to-destination "$PUB" 2>/dev/null; then
        :
    else
        iptables -t nat -S PREROUTING | grep -- "--dport ${GAME_PORTS}" | grep -- "-j DNAT" | sed "s/^-A/-D/" | while read -r spec; do
            iptables -t nat $spec 2>/dev/null
        done
        iptables -t nat -I PREROUTING 1 -d "$VM_IP" -p udp --dport "$GAME_PORTS" -j DNAT --to-destination "$PUB"
        log "reconciled game UDP DNAT: ${VM_IP}:${GAME_PORTS} -> ${PUB}"
    fi
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
