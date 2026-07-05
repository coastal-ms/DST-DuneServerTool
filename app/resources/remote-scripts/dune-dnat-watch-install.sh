#!/bin/sh
# Install / refresh the Dune Awakening DNAT self-heal watchdog on the VM.
#
# WHY THIS EXISTS
#   The host RabbitMQ DNAT rule that forwards external player-login traffic to
#   the in-cluster mq-game pod goes stale whenever the mq-game pod IP (or the
#   public IP) changes WITHOUT a host reboot -- e.g. a pod-only battlegroup
#   restart:
#     * RabbitMQ login:  public:31982/tcp -> <mq-game pod>:5672
#   The boot script /etc/local.d/dune-iptables.start only re-derives this at
#   BOOT, so a pod restart leaves the rule pointing at a dead pod IP and remote
#   players hang forever on "Connecting" (observed 2026-06-23: a ~19h stale rule
#   because a prior hardcoded-IP sync script only watched the OLD public IP).
#   This watchdog reconciles the rule from the live cluster state every minute,
#   so a pod restart self-heals in <=60s.
#
#   It only ever touches the RabbitMQ rule and only when it can resolve VALID
#   IPv4 addresses -- a missing/`<none>` endpoint must never cause it to tear
#   down a working rule. (A former game-port UDP rule that rewrote
#   VM_IP:7777-7810 -> public was removed: it never matched real internet
#   players and could hairpin a same-LAN / self-hosted admin's own join out to
#   the WAN IP and black-hole it. This installer also retires that rule on VMs
#   where a prior version left it behind -- see step 2b.)
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
# Dune DNAT self-heal watchdog. Reconciles the RabbitMQ DNAT rule from the live
# k3s cluster state. Idempotent; safe to run every minute.
# Installed + scheduled by dune-dnat-watch-install.sh (shipped with DST).
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

KUBE="/usr/local/bin/k3s kubectl"
LOG=/var/log/dune-dnat-watch.log
RABBIT_PORT=31982

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }
is_ipv4() { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }

NODE=$($KUBE get nodes --no-headers -o custom-columns=:metadata.name 2>/dev/null | head -1 | tr -d ' ')
[ -z "$NODE" ] && exit 0

# Public IP = authoritative node ExternalIP (tracks IP changes, never hardcoded).
PUB=$($KUBE get node "$NODE" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null)
# Current mq-game pod IP from the service endpoints.
POD=$($KUBE get endpoints --all-namespaces 2>/dev/null | grep mq-game | awk '{print $3}' | cut -d, -f1 | cut -d: -f1 | head -1)

# Only reconcile when BOTH addresses are valid IPv4. A missing/`<none>` endpoint
# (e.g. mq-game momentarily without ready addresses) previously slipped past a
# bare [ -z ] check as the literal string "<none>", which then deleted the good
# rule and failed to insert a replacement -- leaving players with no RabbitMQ
# path. Never tear down a working rule unless a valid replacement is in hand.
if ! is_ipv4 "$PUB"; then log "node ExternalIP not a valid IPv4 ('$PUB'); leaving rules intact"; exit 0; fi
if ! is_ipv4 "$POD"; then log "mq-game endpoint not a valid IPv4 ('$POD'); leaving rules intact"; exit 0; fi

# --- RabbitMQ login: public:31982/tcp -> POD:5672 ---
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
# 2b. Retire the game-port UDP DNAT rule a prior watchdog may have installed.
#     It rewrote VM_IP:7777-7810/udp -> public, which never matched real
#     internet players (they arrive on the public IP) and could hairpin a
#     same-LAN / self-hosted admin's own join out to the WAN IP and black-hole
#     it. Removing it here means updating DST fixes an affected VM immediately,
#     without waiting for a host reboot to flush the stale rule.
# ---------------------------------------------------------------------------
iptables -t nat -S PREROUTING 2>/dev/null | grep -- '--dport 7777:7810' | grep -- '-j DNAT' | sed 's/^-A/-D/' | while read -r spec; do
    if iptables -t nat $spec 2>/dev/null; then log "removed retired game-UDP DNAT rule: $spec"; fi
done

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
