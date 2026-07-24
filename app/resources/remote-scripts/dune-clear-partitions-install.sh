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
#   a player at boot"). A WARM map (MinServers>0) normally has pod(s), so the skip
#   meant the pin was never cleared and the only fix was the manual UI sequence:
#   force-close the map -> clear partitions -> let spin-up restore it. This
#   installs that fix as an autonomous VM-side heal so it works WITH DST CLOSED.
#
#   The SAME crash class also strands the CORE maps (Overmap / Survival_1 Hagga):
#   their pre-crash pod comes back as a stale server the operator DRAINS through
#   terminationGracePeriodSeconds (120s) before recreating it -- game phase
#   "Stopping" or "PreShutdown" (players see "preshutdown"), or the k8s pod
#   stuck Terminating -- so the map is unavailable for the whole grace window.
#   A BOOT-only pass here force-clears such a stale pod so the operator
#   recreates it immediately. Core maps keep a legitimate partition pin, so
#   that pass evicts the POD only and never touches partitions (that stays the
#   on-demand pass's job). FIELD-OBSERVED (2026-07-24): after a hard host
#   crash + VM reboot, 15-hour-old pre-crash core-map pods (pod AGE, i.e. time
#   since the pod was originally created -- NOT how long it sat stuck)
#   remained in game phase "PreShutdown" throughout the boot recovery pass and
#   through a subsequent 90s battlegroup-stop timeout; a manual battlegroup
#   restart eventually recreated them. The boot log for that run showed the
#   pass executing without taking any core-map action. Kubernetes readiness at
#   the moment of failure was not directly captured, but code inspection found
#   the pass had a readyReplicas/pod-Ready short-circuit and only matched game
#   phase "Stopping" (not "PreShutdown") -- either gap alone explains the
#   miss, and a mocked-kubectl reproduction with pod Ready=true + phase
#   PreShutdown confirmed that exact combination hits both gaps at once. The
#   boot pass therefore inspects every candidate pod's game phase directly
#   instead of trusting a serverset-level or pod-level Ready shortcut to mean
#   "nothing to do".
#
# WHAT IT DOES
#   1. Writes the heal script to /usr/local/bin/dune-clear-partitions.sh. It has
#      two passes: (a) BOOT-only stuck-server force-clear for any map that should
#      be up (replicas>=1) whose pod is stuck Terminating or draining "Stopping",
#      force-deleting that pod so the operator recreates it without the 120s
#      drain -- a Ready pod is never touched; and (b) the on-demand/warm map
#      partition heal that cycles a map (patch {replicas:0, partitions:[]}, which
#      evicts the zombie pod AND clears the pin; the director then restores a warm
#      floor) ONLY when the partition is pinned AND no pod is Ready.
#   2. Installs it as the OpenRC boot hook /etc/local.d/dune-clear-partitions.start
#      (mode=boot: aggressive, since no players can exist right after boot).
#   3. Installs a */15 cron entry (mode=cron: conservative, only cycles a clearly
#      stuck/zombie or pod-less map so it never races a legitimate spin-up; the
#      stuck-server force-clear runs in BOOT mode ONLY, never cron/manual, so it
#      cannot interrupt a legitimate scheduled-restart drain during live play).
#   4. Runs the heal once now in the mode given by $1 (default: cron). DST passes
#      'cron' for the automatic app-start sync (conservative -- never disturbs a
#      map that is only mid-spin-up while the app is launched during live play)
#      and 'manual' for the explicit Fix Partitions button (aggressive -- the
#      user is deliberately fixing a stuck map). Only the OpenRC boot hook above
#      uses the aggressive 'boot' mode, where no players can exist.
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
# Per-map marker dir: records a map first seen pinned-but-pod-less in cron mode,
# so we only cycle it if it is STILL pod-less on a LATER tick (spin-up guard). A
# legitimate on-demand spin-up gets its pod within seconds -- long before the
# next 15-min cron tick -- so it clears its marker below and is never cycled.
# Boot/manual modes ignore markers (aggressive by design); a demonstrably dead
# pod (Terminating / CrashLoop / image error) is still cycled immediately.
MARKER_DIR=/var/lib/dune-clear-partitions
mkdir -p "$MARKER_DIR" 2>/dev/null
marker_for() { echo "$MARKER_DIR/$(echo "$1" | tr -c 'A-Za-z0-9._-' '_').podless"; }
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

# ---------------------------------------------------------------------------
# BOOT-ONLY: stuck-server pod force-clear (core maps Overmap/Hagga + any map
# that is supposed to be up). See "WHY THIS EXISTS" above for the incident
# this addresses. Summary: the pre-crash server pod comes back as a stale
# server the Funcom server-operator DRAINS through terminationGracePeriodSeconds
# (120s on the serverset) before recreating a fresh pod -- game phase
# "Stopping" or "PreShutdown" (what players see as "preshutdown"), or the k8s
# pod stuck Terminating (deletionTimestamp set because the node was
# NotReady). This does NOT overlap the partition pass below: core maps keep a
# legitimate partition pin that must never be cleared -- the fix here is to
# evict the STALE POD, not touch partitions.
#
# At BOOT no players can be online, so force-deleting a demonstrably-stuck pod
# (--force --grace-period=0) is safe and lets the operator recreate immediately,
# skipping the drain. A normally-starting pod (Initializing / Starting, no
# deletion mark, no drain phase) is LEFT ALONE so a legitimate world-load is
# never interrupted. Boot mode ONLY -- never cron/manual, because during live
# play a "Stopping"/"PreShutdown" pod may be a legitimate scheduled-restart
# drain we must not kill.
#
# IMPORTANT: unlike the partition pass below, this pass does NOT treat k8s
# Ready (pod- or serverset-level) as proof the pod is healthy. A pod's k8s
# Ready condition and its GAME phase are reported by two different layers
# (kubelet vs. the Funcom server-operator) and can disagree -- so an early
# skip on readyReplicas>=replicas, or on the individual pod's Ready condition,
# could hide a pod whose game phase is "Stopping"/"PreShutdown". Every
# candidate pod's game phase / deletionTimestamp is inspected directly; Ready
# is only consulted afterward, purely for a "not stuck, still starting" log
# line.
force_clear_stuck_pods() {
  $KUBE get serverset --all-namespaces --no-headers 2>/dev/null | awk '{print $1"\t"$2}' \
    | while IFS="$(printf '\t')" read -r ns ss; do
    { [ -z "$ns" ] || [ -z "$ss" ]; } && continue
    # Only maps that are SUPPOSED to be up (replicas>=1). A cleanly shut-down
    # BG has every serverset at replicas=0 -> skipped -> we never start a map
    # the operator intends to keep down.
    rep=$($KUBE -n "$ns" get serverset "$ss" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    case "$rep" in ''|*[!0-9]*) continue ;; esac
    [ "$rep" -ge 1 ] || continue

    pods=$($KUBE -n "$ns" get pods --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep "^${ss}-pod-" || true)
    for p in $pods; do
      [ -z "$p" ] && continue
      del=$($KUBE -n "$ns" get pod "$p" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
      idx="${p##*-pod-}"
      gphase=""
      case "$idx" in
        ''|*[!0-9]*) : ;;
        *) gphase=$($KUBE -n "$ns" get serverset "$ss" -o jsonpath="{.status.pods[?(@.ordinalIndex==$idx)].phase}" 2>/dev/null) ;;
      esac

      # Force a DEMONSTRABLY-stuck pod: stuck Terminating (deletionTimestamp)
      # or draining (game phase "Stopping"/"PreShutdown") -- checked BEFORE any
      # Ready lookup, since k8s Ready can stay true throughout the drain.
      if [ -n "$del" ] || [ "$gphase" = "Stopping" ] || [ "$gphase" = "PreShutdown" ]; then
        reason="phase=${gphase:-?}${del:+,terminating}"
        if $KUBE -n "$ns" delete pod "$p" --force --grace-period=0 >>"$LOG" 2>&1; then
          log "$ns/$ss: force-cleared stuck pod $p ($reason) -> operator will recreate a fresh pod (skipped drain)"
        else
          log "$ns/$ss: ERROR force-deleting stuck pod $p ($reason)"
        fi
        continue
      fi

      # Not demonstrably stale. Only now does Ready matter: a genuinely Ready
      # pod is healthy (nothing to do); a not-yet-Ready pod is likely still
      # starting and is left to load normally.
      rdy=$($KUBE -n "$ns" get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [ "$rdy" != "True" ]; then
        log "$ns/$ss: pod $p not Ready (phase=${gphase:-?}) but not stuck (likely starting) -- leaving to load"
      fi
    done
  done
  return 0
}

if [ "$MODE" = "boot" ]; then
  # The operator can take a short while after boot to surface a stale pod as
  # Terminating/Stopping, so probe a few times over ~2 min. Idempotent: each
  # pass is a cheap no-op when nothing is stuck.
  fc=1
  while [ "$fc" -le 6 ]; do
    force_clear_stuck_pods
    [ "$fc" -lt 6 ] && sleep 20
    fc=$((fc + 1))
  done
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
          rm -f "$(marker_for "$name")" 2>/dev/null
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
        hard_stuck_pods=""
        draining_pods=""
        for p in $pods; do
          [ -z "$p" ] && continue
          pod_n=$((pod_n + 1))
          rdy=$($KUBE -n "$ns" get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
          [ "$rdy" = "True" ] && any_ready=1
          del=$($KUBE -n "$ns" get pod "$p" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
          idx="${p##*-pod-}"
          gphase=""
          case "$idx" in
            ''|*[!0-9]*) : ;;
            *) gphase=$($KUBE -n "$ns" get serverset "$ss_name" -o jsonpath="{.status.pods[?(@.ordinalIndex==$idx)].phase}" 2>/dev/null) ;;
          esac
          if [ -n "$del" ] || [ "$gphase" = "Stopping" ] || [ "$gphase" = "PreShutdown" ]; then
            any_stuck=1
            draining_pods="$draining_pods $p"
          fi
          wr=$($KUBE -n "$ns" get pod "$p" -o jsonpath='{.status.containerStatuses[*].state.waiting.reason}' 2>/dev/null)
          case "$wr" in
            *CrashLoopBackOff*|*Error*|*ImagePull*|*CreateContainerError*|*RunContainerError*)
              any_stuck=1
              case " $hard_stuck_pods " in *" $p "*) : ;; *) hard_stuck_pods="$hard_stuck_pods $p" ;; esac
              ;;
          esac
        done

        # A multi-partition ServerSet can have one healthy pod and one stuck pod.
        # Recover only the demonstrably-stuck pod; never clear the whole
        # partitions array while another partition is serving players.
        if [ "$any_ready" = "1" ]; then
          rm -f "$(marker_for "$name")" 2>/dev/null
          cleared=0
          recover_pods="$hard_stuck_pods"
          # A deletionTimestamp / Stopping / PreShutdown phase is normal during
          # live restarts. Only boot mode may treat a lingering drain as
          # stale; cron/manual preserve graceful shutdown and only clear hard
          # waiting failures.
          if [ "$MODE" = "boot" ]; then recover_pods="$recover_pods $draining_pods"; fi
          seen_recover_pods=""
          for p in $recover_pods; do
            [ -z "$p" ] && continue
            case " $seen_recover_pods " in *" $p "*) continue ;; esac
            seen_recover_pods="$seen_recover_pods $p"
            if $KUBE -n "$ns" delete pod "$p" --force --grace-period=0 >>"$LOG" 2>&1; then
              cleared=$((cleared + 1))
              log "$ns/$name: force-cleared stuck partition pod $p while preserving Ready sibling partition(s)"
            else
              log "$ns/$name: ERROR force-deleting stuck partition pod $p"
            fi
          done
          if [ "$cleared" = "0" ]; then
            log "$ns/$name: Ready pod(s) serving; no hard-stuck sibling eligible in mode=$MODE (draining pods are preserved outside boot)"
          fi
          break
        fi

        # Decide whether to cycle.
        do_cycle=0
        if [ "$MODE" = "boot" ] || [ "$MODE" = "manual" ]; then
          do_cycle=1
        else
          # cron: only the clearly-safe cases.
          if [ "$any_stuck" = "1" ]; then
            # Demonstrably dead pod (Terminating / CrashLoop / image error): cycle now.
            do_cycle=1
          elif [ "$pod_n" = "0" ]; then
            # Pinned but pod-less is AMBIGUOUS: either a genuinely stuck pin, or a
            # spin-up whose pod has not been scheduled yet. Spin-up guard: only
            # cycle if it was ALSO pod-less on a previous tick. A real spin-up
            # resolves in seconds and clears its marker (via the empty/ready/pod
            # branches) long before the next tick, so it is never cycled.
            mk="$(marker_for "$name")"
            if [ -f "$mk" ]; then
              do_cycle=1
            else
              : > "$mk" 2>/dev/null
              log "$ns/$name: pinned ($cur), pod-less first sighting -- waiting one tick before cycling (spin-up guard)"
              break
            fi
          fi
        fi

        if [ "$do_cycle" != "1" ]; then
          log "$ns/$name: pinned ($cur), pod present but not yet stuck (pods=$pod_n) in cron mode, leaving for now"
          break
        fi

        if $KUBE -n "$ns" patch igwsss "$name" --type=merge -p '{"spec":{"replicas":0,"partitions":[]}}' >>"$LOG" 2>&1; then
          rm -f "$(marker_for "$name")" 2>/dev/null
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
# 4. Run the heal once now. The caller ($1) chooses the mode: 'cron' for the
#    automatic app-start sync (conservative), 'manual' for the explicit Fix
#    Partitions button (aggressive, user intent). Defaults to conservative
#    'cron' so an unspecified/automatic run never disturbs a live map.
#    'none' / 'install-only' installs+refreshes the heal/hook/cron but does
#    NOT run it (used to update the automation on a live server without
#    touching any map this instant).
# ---------------------------------------------------------------------------
RUNMODE="${1:-cron}"
case "$RUNMODE" in
  boot|cron|manual)   DUNE_CLEAR_MODE="$RUNMODE" "$HEAL" 2>/dev/null ;;
  none|install-only)  log "install-only: heal + boot hook + cron refreshed, NOT run now ($RUNMODE)" ;;
  *)                  DUNE_CLEAR_MODE=cron "$HEAL" 2>/dev/null ;;
esac

log "dune-clear-partitions install/refresh done"
echo DUNE_CLEAR_PARTITIONS_OK
