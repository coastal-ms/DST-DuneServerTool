#!/bin/sh
# ---------------------------------------------------------------------------
# dune-mem-pressure-probe.sh
#
# VM health probe for the Dune Server Tool. (Still named for its original
# memory-only job; v2 widened it to every VM-side signal DST could not see.)
#
# Staged over SSH and executed as root via `sudo bash`. It NEVER mutates the
# VM - it only reads state and prints stable key=value lines. The same output
# contract is parsed by BOTH callers, so keep it stable:
#   - app/server/lib/VmMemoryPressure.ps1  (Diagnostics bundle + status banner)
#   - dune-server.ps1                      (CLI Start-All WARNINGS)
#
# Why this exists: three real cases (murm ping-surge, Hagga per-map sizing, and
# Pat's off-schedule battlegroup restarts, 2026-07-07) were all the home-hosted
# VM thrashing for memory. The kubelet SIGKILLs the Funcom operators
# (*-controller-manager-*, exit 137 / OOMKilled, restart counts in the 30s) and
# evicts the Postgres pod when the node runs low on memory with Swap: 0. Today
# that can only be found by exporting logs and hand-reading them; this probe
# surfaces it in DST itself.
#
# v2 (2026-07-26) added the signals behind five more field cases where DST's
# board stayed green while the server was down or degraded:
#   - a stuck DatabaseOperation blocks every map pod from ever being created
#   - a full / DiskPressure'd node evicts pods with no mention of disk
#   - containerd retains every historical Funcom build (~4.8 GB each, forever)
#   - the per-port UDP DNAT bridge does not survive a Hyper-V host migration
#   - Funcom's experimental swap script crushes per-map memory limits silently
#
# Emitted keys:
#   probe=dune-mem-pressure/2
#   mem_total_k / mem_avail_k / swap_total_k / swap_free_k   (KiB, from /proc)
#   __FREE_H_BEGIN__ ... __FREE_H_END__                       (human free -h)
#   ns_operators=<ns|empty>   ns_seabass=<ns|empty>
#   op=<record>   (one per *-controller-manager-* operator pod)
#   db=<record>   (one per Postgres/database statefulset pod)
#   node_cond=<Type>=<Status>              (one per node condition)
#   disk_root_size_k / disk_root_used_k / disk_root_avail_k / disk_root_use_pct
#   bg_name=<battlegroup>   bg_database_phase=<phase>
#   dbop_total=<n>   dbop_open=<n>
#   dbop=<name>~PH:<phase>~CT:<creationTimestamp>   (one per NON-Succeeded op)
#   maplim=<map>~LIM:<memoryLimit>          (one per map in the BG spec)
#   pending_map=<pod>~REQ:<request>~LIM:<limit>~RSN:<reason>~MSG:<scheduler message>
#   img=<repo>~TAG:<tag>~SIZE:<human>       (one per retained seabass image)
#   dnat_udp_rules=<n>   dnat_udp_ports=<space-separated ports>
#   probe_done=1
#
# Pod record shape (~ is the field separator; lists are space-joined so a
# multi-container pod - manager + kube-rbac-proxy - is fully covered):
#   <name>~P:<phase>~PR:<podReason>~R:<restarts >~E:<exitCodes >~X:<termReasons >~W:<waitReasons >
#
# Portability note: the appliance is busybox. `df -h /` fails there ("can't
# find mount point") and `head -n N` / `tail -n N` can return "invalid number",
# so this script selects rows with awk instead.
# ---------------------------------------------------------------------------
set -u

KUBECTL=/usr/local/bin/kubectl
[ -x "$KUBECTL" ] || KUBECTL=kubectl

echo "probe=dune-mem-pressure/2"

# --- Node memory ----------------------------------------------------------
# /proc/meminfo is authoritative and universal (MemAvailable is present on
# every modern kernel); free -h is only for human display in the bundle.
if [ -r /proc/meminfo ]; then
  awk '
    /^MemTotal:/     { print "mem_total_k="$2 }
    /^MemAvailable:/ { print "mem_avail_k="$2 }
    /^SwapTotal:/    { print "swap_total_k="$2 }
    /^SwapFree:/     { print "swap_free_k="$2 }
  ' /proc/meminfo
else
  echo "meminfo_missing=1"
fi

echo "__FREE_H_BEGIN__"
free -h 2>/dev/null || free 2>/dev/null || echo "(free unavailable)"
echo "__FREE_H_END__"

# --- Pod records ----------------------------------------------------------
# jsonpath emits one line per pod; per-container fields are space-joined inside
# each field so the PS side can take the max restart count and scan the
# exit-code / termination-reason lists for 137 / OOMKilled / Error / Evicted.
JPATH='{range .items[*]}{.metadata.name}{"~P:"}{.status.phase}{"~PR:"}{.status.reason}{"~R:"}{range .status.containerStatuses[*]}{.restartCount}{" "}{end}{"~E:"}{range .status.containerStatuses[*]}{.lastState.terminated.exitCode}{" "}{end}{"~X:"}{range .status.containerStatuses[*]}{.lastState.terminated.reason}{" "}{end}{"~W:"}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}'

# Funcom operators live in a fixed namespace; only the four
# *-controller-manager-* pods matter (battlegroup / database / server /
# utilities controller-managers).
OPNS=funcom-operators
if "$KUBECTL" get ns "$OPNS" >/dev/null 2>&1; then
  echo "ns_operators=$OPNS"
  "$KUBECTL" get pods -n "$OPNS" -o jsonpath="$JPATH" 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *controller-manager*) echo "op=$line" ;;
    esac
  done
else
  echo "ns_operators="
fi

# The game/DB workloads live in funcom-seabass-<world>. The database pod is the
# Postgres statefulset member; exclude the transient dump/backup/util pods
# (terminal by design - a non-zero exit there is not a memory-pressure signal).
DBNS=$("$KUBECTL" get ns --no-headers -o custom-columns=N:.metadata.name 2>/dev/null | grep -m1 '^funcom-seabass-')
if [ -n "$DBNS" ]; then
  echo "ns_seabass=$DBNS"
  "$KUBECTL" get pods -n "$DBNS" -o jsonpath="$JPATH" 2>/dev/null | while IFS= read -r line; do
    [ -n "$line" ] || continue
    name=${line%%~*}
    case "$name" in
      *dump*|*backup*|*dbdepl-util*) continue ;;
    esac
    case "$name" in
      *-db-*|*-db|*database*) echo "db=$line" ;;
    esac
  done
else
  echo "ns_seabass="
fi

# --- Node conditions ------------------------------------------------------
# DiskPressure / MemoryPressure / PIDPressure are the kubelet's own verdict on
# the node. A DiskPressure node stops admitting pods and starts evicting them,
# which surfaces to the user as "my maps won't start" with nothing pointing at
# disk. Ready=False is equally worth seeing.
"$KUBECTL" get nodes -o jsonpath='{range .items[0].status.conditions[*]}{.type}{"="}{.status}{"\n"}{end}' 2>/dev/null |
  while IFS= read -r cond; do
    [ -n "$cond" ] || continue
    echo "node_cond=$cond"
  done

# --- Root filesystem ------------------------------------------------------
# busybox df: `df -h /` fails with "can't find mount point", so take POSIX
# 1K-block output for every filesystem and pick the row mounted on /.
df -P 2>/dev/null | awk '$NF=="/" {
    gsub(/%/, "", $5)
    print "disk_root_size_k=" $2
    print "disk_root_used_k=" $3
    print "disk_root_avail_k=" $4
    print "disk_root_use_pct=" $5
    exit
  }'

# --- Battlegroup: database phase, stuck operations, per-map limits --------
# A DatabaseOperation that never leaves Pending holds the database open, the
# battlegroup reports DATABASE=Operation instead of Ready, and the operator
# then creates NO map pods at all - so the server never starts and any restore
# also fails, from one cause. Deleting the record is the remedy; DST could not
# even see it before v2.
if [ -n "$DBNS" ]; then
  BGNAME=$("$KUBECTL" -n "$DBNS" get battlegroup -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$BGNAME" ] && echo "bg_name=$BGNAME"
  BGDBPHASE=$("$KUBECTL" -n "$DBNS" get battlegroup -o jsonpath='{.items[0].status.database.phase}' 2>/dev/null)
  echo "bg_database_phase=$BGDBPHASE"

  DBOPS=$("$KUBECTL" -n "$DBNS" get databaseoperations -o jsonpath='{range .items[*]}{.metadata.name}{"~PH:"}{.status.phase}{"~CT:"}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null)
  if [ -n "$DBOPS" ]; then
    echo "$DBOPS" | awk '
      NF {
        total++
        phase = $0
        sub(/^.*~PH:/, "", phase)
        sub(/~CT:.*$/, "", phase)
        if (phase != "Succeeded") { open++; print "dbop=" $0 }
      }
      END { print "dbop_total=" total+0; print "dbop_open=" open+0 }
    '
  else
    echo "dbop_total=0"
    echo "dbop_open=0"
  fi

  # Per-map memory limits. Funcom's experimental_swap.sh rewrites these to
  # crushed values (1Gi / 200Mi / 10Gi) and they survive a VM resize, so a
  # 49 GB machine can still be running Overland capped at 1Gi.
  "$KUBECTL" -n "$DBNS" get battlegroup -o jsonpath='{range .items[0].spec.serverGroup.template.spec.sets[*]}{.map}{"~LIM:"}{.resources.limits.memory}{"\n"}{end}' 2>/dev/null |
    while IFS= read -r lim; do
      [ -n "$lim" ] || continue
      echo "maplim=$lim"
    done

  # Pending game-map pods with the scheduler's own verdict. This catches the
  # Dynamic Memory boot-capacity case where MemAvailable looks healthy but the
  # node cannot admit a 16 GiB Hagga pod because kubelet registered less total
  # capacity at boot.
  PENDING_JPATH='{range .items[?(@.status.phase=="Pending")]}{.metadata.name}{"~REQ:"}{.spec.containers[0].resources.requests.memory}{"~LIM:"}{.spec.containers[0].resources.limits.memory}{"~RSN:"}{range .status.conditions[?(@.type=="PodScheduled")]}{.reason}{end}{"~MSG:"}{range .status.conditions[?(@.type=="PodScheduled")]}{.message}{end}{"\n"}{end}'
  "$KUBECTL" -n "$DBNS" get pods -o jsonpath="$PENDING_JPATH" 2>/dev/null |
    while IFS= read -r pending; do
      [ -n "$pending" ] || continue
      name=${pending%%~*}
      case "$name" in
        *-sg-*-pod-*) echo "pending_map=$pending" ;;
      esac
    done
fi

# --- Retained container images -------------------------------------------
# containerd keeps every historical Funcom build (~4.8 GB per build) with
# nothing pruning it. Report the retained seabass images so the growth is
# visible before kubelet's 85% image-GC watermark starts evicting.
CRICTL=/usr/local/bin/crictl
if [ ! -x "$CRICTL" ]; then
  if [ -x /usr/local/bin/k3s ]; then CRICTL="/usr/local/bin/k3s crictl"; else CRICTL=""; fi
fi
if [ -n "$CRICTL" ]; then
  $CRICTL images 2>/dev/null | awk 'tolower($0) ~ /seabass/ { print "img=" $1 "~TAG:" $2 "~SIZE:" $4 }'
fi

# --- UDP DNAT bridge ------------------------------------------------------
# The per-port game-UDP DNAT rules live on the VM (plus their maintaining
# cron), so they do NOT survive moving the VM to a different Hyper-V host.
# With a public IP configured AND game pods actually running, zero rules is an
# unambiguous fault state - players get P34 while every DST board stays green.
# Remedy: Settings -> Public IP / DDNS -> Apply.
#
# iptables lives in /sbin, which is NOT on the PATH of a non-interactive SSH
# session. Resolve it explicitly and emit NOTHING when it can't be found -
# printing dnat_udp_rules=0 because the binary was missing would raise a
# critical false alarm.
IPT=/sbin/iptables
[ -x "$IPT" ] || IPT=/usr/sbin/iptables
[ -x "$IPT" ] || IPT=$(command -v iptables 2>/dev/null)
if [ -n "$IPT" ] && [ -x "$IPT" ]; then
  DNATRAW=$("$IPT" -t nat -S PREROUTING 2>/dev/null | grep -- '-j DNAT' | grep -- '-p udp')
  if [ -n "$DNATRAW" ]; then
    echo "dnat_udp_rules=$(echo "$DNATRAW" | grep -c .)"
    echo "dnat_udp_ports=$(echo "$DNATRAW" | sed -n 's/.*--dport \([0-9][0-9]*\).*/\1/p' | tr '\n' ' ')"
  else
    echo "dnat_udp_rules=0"
    echo "dnat_udp_ports="
  fi
else
  echo "dnat_probe=unavailable"
fi

# Running game pods. A stopped battlegroup legitimately has no UDP DNAT rules
# (they are reconciled per bound listener), so the missing-bridge verdict must
# only apply when the game is actually up.
if [ -n "$DBNS" ]; then
  echo "game_pods_running=$("$KUBECTL" get pods -n "$DBNS" --no-headers 2>/dev/null | grep -E '(-sg-|-sgw-|-bgd-)' | grep -c Running)"
fi

echo "probe_done=1"
