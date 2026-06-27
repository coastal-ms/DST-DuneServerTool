#!/bin/sh
# Install / refresh the Dune Awakening on-demand-map partition self-heal on the VM.
#
# WHY THIS EXISTS
#   On-demand + warm (spin-up) maps (DeepDesert / SH_Arrakeen / SH_HarkoVillage)
#   can come back from an UNCLEAN host crash + VM reboot with their
#   igwsss.spec.partitions still pinned at [N] while the pod is a stuck
#   post-shutdown zombie (Terminating / CrashLoop / Pending, never Ready). The
#   director then refuses to (re)spawn the map and players can't enter.
#
#   The old clear pass skipped ANY ServerSet that had a pod present ("don't kick
#   a player at boot"). A WARM map (MinServers=1) ALWAYS has a pod, so the skip
#   meant the pin was never cleared and the only fix was the manual UI sequence:
#   force-close the map -> clear partitions -> let spin-up restore it. This
#   installs that fix as an autonomous VM-side heal so it works WITH DST CLOSED.
#
# WHAT IT DOES
#   1. Writes the heal script to /usr/local/bin/dune-clear-partitions.sh. The
#      heal cycles a map (patch {replicas:0, partitions:[]}, which evicts the
#      zombie pod AND clears the pin; the director then restores a warm floor)
#      ONLY when the partition is pinned AND no pod is Ready -- so a live player
#      session (Ready pod) is never kicked.
#   2. Installs it as the OpenRC boot hook /etc/local.d/dune-clear-partitions.start
#      (mode=boot: aggressive, since no players can exist right after boot).
#   3. Installs a */15 cron entry (mode=cron: conservative, only cycles a clearly
#      stuck/zombie or pod-less map so it never races a legitimate spin-up).
#   4. Runs the heal once now in boot mode.
#
# DEFENDER-SAFE DESIGN
#   All persistence logic (writing the heal + boot hook + cron) lives here in
#   POSIX sh and runs on the Linux VM. DST only stages-and-runs this script over
#   SSH -- the same mechanism as dune-dnat-watch-install.sh -- so the packaged
#   Windows app carries NO persistence-establishment code.
#
# Staged to /tmp by DST and run once with sudo. Idempotent and best-effort.
# Logged to /var/log/dune-clear-partitions.log.

set -u

HEAL=/usr/local/bin/dune-clear-partitions.sh
BOOT=/etc/local.d/dune-clear-partitions.start
LOG=/var/log/dune-clear-partitions.log

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 1. Write the heal script. Quoted heredoc -> nothing is expanded at write
#    time; the heal resolves everything dynamically when it runs.
# ---------------------------------------------------------------------------
cat > "$HEAL" <<'HEALEOF'
#!/bin/sh
# Dune on-demand/warm map partition self-heal.
# Clears a drifted igwsss.spec.partitions pin that blocks DeepDesert /
# SH_Arrakeen / SH_HarkoVillage from launching, WITHOUT kicking a live player.
# Installed + scheduled by dune-clear-partitions-install.sh (shipped with DST).
#
# MODE (DUNE_CLEAR_MODE): boot | cron | manual  (default: manual)
#   boot/manual = aggressive: cycle any pinned map with no Ready pod (safe at
#                 boot -- no players yet -- and manual = explicit user intent).
#   cron        = conservative: only cycle a pinned map that is pod-less OR has
#                 a clearly stuck pod (Terminating / CrashLoop / image error),
#                 so it never races a map that is legitimately spinning up.
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
set -u

MODE="${DUNE_CLEAR_MODE:-manual}"
LOG=/var/log/dune-clear-partitions.log
MAP_SUFFIXES="-deepdesert-1 -sh-arrakeen -sh-harkovillage"
KUBE="/usr/local/bin/k3s kubectl"
# Only do the long boot races in boot mode; cron/manual probe briefly.
if [ "$MODE" = "boot" ]; then WAIT_ATTEMPTS="${DUNE_CLEAR_ATTEMPTS:-60}"; else WAIT_ATTEMPTS=1; fi

ts() { date "+%Y-%m-%d %H:%M:%S"; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null; }

log "dune-clear-partitions: start (mode=$MODE)"

# Wait for k3s API + igwsss CRD (boot: up to 5 min; cron/manual: single probe).
i=1
while [ "$i" -le "$WAIT_ATTEMPTS" ]; do
  if $KUBE get igwsss --all-namespaces >/dev/null 2>&1; then break; fi
  sleep 5
  i=$((i + 1))
done
if ! $KUBE get igwsss --all-namespaces >/dev/null 2>&1; then
  log "k3s API / igwsss CRD not reachable, nothing to do (mode=$MODE)"
  exit 0
fi

# Return non-empty if at least one igwsss matches one of our map suffixes.
has_expected_match() {
  $KUBE get igwsss --all-namespaces --no-headers 2>/dev/null | awk '{print $2}' | while read -r n; do
    for suffix in $MAP_SUFFIXES; do
      case "$n" in *"$suffix") echo "y"; return ;; esac
    done
  done
}

# In boot mode, wait for at least one expected map object to actually exist
# (CRD can be reachable before the server-operator has reconciled the maps).
if [ "$MODE" = "boot" ]; then
  i=1
  while [ "$i" -le "$WAIT_ATTEMPTS" ]; do
    if [ -n "$(has_expected_match)" ]; then break; fi
    sleep 5
    i=$((i + 1))
  done
fi

matches=$($KUBE get igwsss --all-namespaces --no-headers 2>/dev/null | awk '{print $1"\t"$2}')
if [ -z "$matches" ]; then
  log "no igwsss objects found; nothing to do"
  exit 0
fi
if [ -z "$(has_expected_match)" ]; then
  log "no on-demand map igwsss matched ($MAP_SUFFIXES); nothing to do"
  exit 0
fi

echo "$matches" | while IFS="$(printf '\t')" read -r ns name; do
  { [ -z "$ns" ] || [ -z "$name" ]; } && continue
  for suffix in $MAP_SUFFIXES; do
    case "$name" in
      *"$suffix")
        cur=$($KUBE -n "$ns" get igwsss "$name" -o jsonpath="{.spec.partitions}" 2>/dev/null)
        if [ "$cur" = "[]" ] || [ -z "$cur" ]; then
          log "$ns/$name: partitions already empty ($cur), no change"
          break
        fi

        # Pinned. Inspect the ServerSet's pods.
        # Pod name pattern: <bg-id>-sg<suffix>-pod-<n>
        ss_name="${name%$suffix}-sg${suffix}"
        pods=$($KUBE -n "$ns" get pods --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep "^${ss_name}-pod-" || true)

        pod_n=0
        any_ready=0
        any_stuck=0
        for p in $pods; do
          [ -z "$p" ] && continue
          pod_n=$((pod_n + 1))
          rdy=$($KUBE -n "$ns" get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
          [ "$rdy" = "True" ] && any_ready=1
          del=$($KUBE -n "$ns" get pod "$p" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
          [ -n "$del" ] && any_stuck=1
          wr=$($KUBE -n "$ns" get pod "$p" -o jsonpath='{.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null)
          case "$wr" in
            *CrashLoopBackOff*|*Error*|*ImagePull*|*CreateContainerError*|*RunContainerError*) any_stuck=1 ;;
          esac
        done

        # Never disturb a live session.
        if [ "$any_ready" = "1" ]; then
          log "$ns/$name: pinned ($cur) but a Ready pod is serving players, skipping"
          break
        fi

        # Decide whether to cycle.
        do_cycle=0
        if [ "$MODE" = "boot" ] || [ "$MODE" = "manual" ]; then
          do_cycle=1
        else
          # cron: only the clearly-safe cases (no pod, or a demonstrably stuck pod).
          if [ "$pod_n" = "0" ] || [ "$any_stuck" = "1" ]; then do_cycle=1; fi
        fi

        if [ "$do_cycle" != "1" ]; then
          log "$ns/$name: pinned ($cur), pod present but not yet stuck (pods=$pod_n) in cron mode, leaving for now"
          break
        fi

        if $KUBE -n "$ns" patch igwsss "$name" --type=merge -p '{"spec":{"replicas":0,"partitions":[]}}' >>"$LOG" 2>&1; then
          log "$ns/$name: cycled (was partitions=$cur, pods=$pod_n, stuck=$any_stuck, mode=$MODE) -> director will restore the floor"
        else
          log "$ns/$name: ERROR patching"
        fi
        break
        ;;
    esac
  done
done

log "dune-clear-partitions: done (mode=$MODE)"
exit 0
HEALEOF
chmod 0755 "$HEAL" 2>/dev/null

# ---------------------------------------------------------------------------
# 2. Install the OpenRC boot hook (runs the heal in aggressive boot mode at VM
#    startup -- the unclean-crash-recovery case). /etc/local.d is executed by
#    the OpenRC `local` service; the file must end in .start and be executable.
# ---------------------------------------------------------------------------
mkdir -p /etc/local.d 2>/dev/null
cat > "$BOOT" <<BOOTEOF
#!/bin/sh
# Dune partition self-heal -- boot pass. Installed by DST.
DUNE_CLEAR_MODE=boot $HEAL
BOOTEOF
chmod 0755 "$BOOT" 2>/dev/null
# Make sure the OpenRC local service is enabled so the boot hook actually fires.
rc-update add local default >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 3. Reconcile the root crontab: drop any prior partition-clear lines, then
#    install the canonical every-15-min conservative pass.
# ---------------------------------------------------------------------------
( crontab -l 2>/dev/null | grep -v -e dune-clear-partitions ; echo "*/15 * * * * DUNE_CLEAR_MODE=cron $HEAL" ) | crontab -

# ---------------------------------------------------------------------------
# 4. Run once now (boot mode) so any current drift is fixed immediately.
# ---------------------------------------------------------------------------
DUNE_CLEAR_MODE=boot "$HEAL" 2>/dev/null

log "dune-clear-partitions install/refresh done"
echo DUNE_CLEAR_PARTITIONS_OK
