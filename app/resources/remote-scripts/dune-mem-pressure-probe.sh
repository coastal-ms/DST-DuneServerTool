#!/bin/sh
# ---------------------------------------------------------------------------
# dune-mem-pressure-probe.sh
#
# VM memory-pressure probe for the Dune Server Tool.
#
# Staged over SSH and executed as root via `sudo bash`. It NEVER mutates the
# VM - it only reads memory + pod state and prints stable key=value lines.
# The same output contract is parsed by BOTH callers, so keep it stable:
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
# Emitted keys:
#   probe=dune-mem-pressure/1
#   mem_total_k / mem_avail_k / swap_total_k / swap_free_k   (KiB, from /proc)
#   __FREE_H_BEGIN__ ... __FREE_H_END__                       (human free -h)
#   ns_operators=<ns|empty>   ns_seabass=<ns|empty>
#   op=<record>   (one per *-controller-manager-* operator pod)
#   db=<record>   (one per Postgres/database statefulset pod)
#   probe_done=1
#
# Pod record shape (~ is the field separator; lists are space-joined so a
# multi-container pod - manager + kube-rbac-proxy - is fully covered):
#   <name>~P:<phase>~PR:<podReason>~R:<restarts >~E:<exitCodes >~X:<termReasons >~W:<waitReasons >
# ---------------------------------------------------------------------------
set -u

KUBECTL=/usr/local/bin/kubectl
[ -x "$KUBECTL" ] || KUBECTL=kubectl

echo "probe=dune-mem-pressure/1"

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

echo "probe_done=1"
