#!/bin/sh
# Install Hyper-V guest recovery for dynamic-memory hot-add and KVP health.

set -u
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export PATH

MEMORY_ROOT="${DUNE_HYPERV_MEMORY_ROOT:-/sys/devices/system/memory}"
BOOT_HOOK="${DUNE_HYPERV_BOOT_HOOK:-/etc/local.d/dune-hyperv-memory-online.start}"
LOG="${DUNE_HYPERV_LOG:-/var/log/dune-hyperv-guest-recovery.log}"
RC_SERVICE="${DUNE_HYPERV_RC_SERVICE:-rc-service}"
RC_UPDATE="${DUNE_HYPERV_RC_UPDATE:-rc-update}"
PGREP="${DUNE_HYPERV_PGREP:-pgrep}"
KVP_SERVICE="${DUNE_HYPERV_KVP_SERVICE:-hv_kvp_daemon}"
KVP_PROCESS="${DUNE_HYPERV_KVP_PROCESS:-hv_kvp_daemon}"
FORCE_KVP_RESTART="${DUNE_HYPERV_FORCE_KVP_RESTART:-0}"
TXN="$$"
BOOT_STAGE="${BOOT_HOOK}.new.${TXN}"

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }
fail() {
    rm -f "$BOOT_STAGE"
    log "$*"
    echo DUNE_HYPERV_GUEST_RECOVERY_FAILED
    exit 1
}

[ -d "$MEMORY_ROOT" ] || {
    echo DUNE_HYPERV_GUEST_RECOVERY_NOT_APPLICABLE
    exit 0
}
[ -w "$MEMORY_ROOT/auto_online_blocks" ] ||
    fail "memory hot-add policy is not writable: $MEMORY_ROOT/auto_online_blocks"

online_memory() {
    printf '%s\n' online > "$MEMORY_ROOT/auto_online_blocks" ||
        fail "failed to enable automatic memory onlining"
    for state in "$MEMORY_ROOT"/memory*/state; do
        [ -f "$state" ] || continue
        if [ "$(cat "$state" 2>/dev/null)" = offline ]; then
            printf '%s\n' online > "$state" ||
                fail "failed to online memory block: $state"
        fi
    done
}

ensure_kvp() {
    if [ "$FORCE_KVP_RESTART" = 1 ] ||
       ! "$PGREP" -x "$KVP_PROCESS" >/dev/null 2>&1; then
        "$RC_SERVICE" "$KVP_SERVICE" restart >/dev/null 2>&1 ||
            fail "failed to restart $KVP_SERVICE"
    fi
    wait_count=0
    while ! "$PGREP" -x "$KVP_PROCESS" >/dev/null 2>&1; do
        wait_count=$((wait_count + 1))
        [ "$wait_count" -lt 6 ] ||
            fail "$KVP_PROCESS is still absent after service restart"
        sleep 1
    done
    "$PGREP" -x "$KVP_PROCESS" >/dev/null 2>&1 ||
        fail "$KVP_PROCESS is still absent after service restart"
}

online_memory
ensure_kvp

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

if ! pgrep -x hv_kvp_daemon >/dev/null 2>&1; then
    rc-service hv_kvp_daemon restart >/dev/null 2>&1 || true
fi
HOOKEOF
then
    fail "failed to stage Hyper-V boot hook"
fi
chmod 0755 "$BOOT_STAGE" || fail "failed to make boot hook executable"
mv -f "$BOOT_STAGE" "$BOOT_HOOK" || fail "failed to publish boot hook"
"$RC_UPDATE" add local default >/dev/null 2>&1 ||
    fail "failed to enable the OpenRC local service"

offline=0
for state in "$MEMORY_ROOT"/memory*/state; do
    [ -f "$state" ] || continue
    if [ "$(cat "$state" 2>/dev/null)" = offline ]; then
        offline=$((offline + 1))
    fi
done
[ "$(cat "$MEMORY_ROOT/auto_online_blocks" 2>/dev/null)" = online ] ||
    fail "automatic memory onlining did not persist"
[ "$offline" -eq 0 ] || fail "$offline memory block(s) remain offline"
[ -x "$BOOT_HOOK" ] || fail "boot hook is missing or not executable"

log "Hyper-V guest recovery reconciled: auto_online=online offline=0 kvp=running"
echo "DUNE_HYPERV_GUEST_RECOVERY_OK auto_online=online offline=0 kvp=running"
