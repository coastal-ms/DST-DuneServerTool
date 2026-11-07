#!/bin/sh
# Run as an ordinary user on Alpine/OpenRC; all state and commands are fixtures.
set -eu
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
ROOT=$(mktemp -d)
export ROOT
trap 'if [ -f "$ROOT/worker" ]; then kill "$(cat "$ROOT/worker")" 2>/dev/null || :; fi; rm -rf "$ROOT"' EXIT
extract() { awk -v begin="$2" -v end="$3" 'index($0,begin){on=1;next} on && $0==end{exit} on{print}' "$1"; }
extract "$1" "<<'LIFEEOF'" LIFEEOF > "$ROOT/lifecycle"
extract "$1" '<<SERVICEEOF' SERVICEEOF > "$ROOT/service.in"
export DUNE_HYPERV_LIFECYCLE_STATE_DIR="$ROOT/state"
export DUNE_HYPERV_LIFECYCLE_STATE="$ROOT/state/state"
export DUNE_HYPERV_K3S_BIN="$ROOT/k3s"
export DUNE_HYPERV_BG_BIN="$ROOT/bg"
export DUNE_HYPERV_LOG="$ROOT/log"
export DUNE_HYPERV_START_TIMEOUT=20
mkdir "$ROOT/state"
cat > "$ROOT/k3s" <<'EOF'
#!/bin/sh
case "$*" in
 *spec.stop*) cat "$ROOT/stopped" ;;
 *'get battlegroups -A'*)
   if [ "$(cat "$ROOT/mode")" = ready ]; then echo 'Running|Ready|Healthy|Healthy|Running:true,'; else echo 'Starting|Ready|Healthy|Healthy|Starting:false,'; fi ;;
 *readyz*) echo ok ;;
 *'get pods -n funcom-operators'*) echo 'controller true Running' ;;
 *'get endpoints'*) echo 10.0.0.2 ;;
 *'get pods -A'*) echo 'default dune-db-0 true Running' ;;
 *) exit 1 ;;
esac
EOF
cat > "$ROOT/bg" <<'EOF'
#!/bin/sh
echo "$1" >> "$ROOT/bg-calls"
EOF
chmod +x "$ROOT/lifecycle" "$ROOT/k3s" "$ROOT/bg"
# Render only the install-time substitutions; leave service runtime variables.
sed -e "s|\$LIFECYCLE_BIN|$ROOT/lifecycle|g" -e "s|\$INITIAL_START_SENTINEL|$ROOT/initial|g" -e 's/\\\$/\$/g' "$ROOT/service.in" > "$ROOT/service"
sh -n "$ROOT/lifecycle"
sh -n "$ROOT/service"
echo DESIRED=running > "$ROOT/state/state"
echo waiting > "$ROOT/mode"
echo false > "$ROOT/stopped"
cat > "$ROOT/start-service" <<'EOF'
#!/bin/sh
ebegin() { :; }
eend() { return "$1"; }
. "$ROOT/service"
start
echo returned > "$ROOT/returned"
EOF
# The real OpenRC daemon launcher must return while the worker is still waiting.
timeout 3 sh "$ROOT/start-service"
test -f "$ROOT/returned"
i=0
while ! grep -q LAST_START_PHASE=battlegroup-ready "$ROOT/state/state"; do i=$((i+1)); test "$i" -lt 40; sleep .1; done
echo 'PASS boot service returns before map readiness'
echo true > "$ROOT/stopped"
i=0
while ! grep -q LAST_START_PHASE=intentional-stop "$ROOT/state/state"; do i=$((i+1)); test "$i" -lt 50; sleep .1; done
grep -q LAST_START_RESULT=skipped "$ROOT/state/state"
echo 'PASS intentional BG stop cancels boot readiness wait'
"$ROOT/lifecycle" stop
grep -q DESIRED=stopped "$ROOT/state/state"
grep -q LAST_SHUTDOWN_RESULT=skipped "$ROOT/state/state"
echo 'PASS already stopped BG needs no shutdown drain'
"$ROOT/lifecycle" start
grep -q LAST_START_PHASE=desired-stopped "$ROOT/state/state"
echo 'PASS intentionally stopped boot does not restart BG'
echo DESIRED=running > "$ROOT/state/state"
echo ready > "$ROOT/mode"
"$ROOT/lifecycle" start
grep -q LAST_START_RESULT=ok "$ROOT/state/state"
echo 'PASS normal healthy recovery still succeeds'
# Execute the actual generated partition boot hook with a slow mock heal.
extract "$2" '<<BOOTEOF' BOOTEOF | sed "s|\$HEAL|$ROOT/heal|g" > "$ROOT/partition-hook"
printf '#!/bin/sh\nsleep 2\necho done > "$ROOT/healed"\n' > "$ROOT/heal"
chmod +x "$ROOT/heal"
timeout 1 sh "$ROOT/partition-hook"
i=0
while [ ! -f "$ROOT/healed" ]; do i=$((i+1)); test "$i" -lt 40; sleep .1; done
echo 'PASS partition boot hook returns while heal continues'
# Delayed networking hook must also release the boot runlevel immediately.
extract "$3" "<<'DUNEBOOT'" DUNEBOOT > "$ROOT/network-hook"
sh -n "$ROOT/network-hook"
# Replace its delay with a marker and exit, retaining the actual async wrapper.
sed 's/^sleep 30$/echo done > "$ROOT\/networked"; exit 0/' "$ROOT/network-hook" > "$ROOT/network-test"
timeout 1 sh "$ROOT/network-test"
i=0
while [ ! -f "$ROOT/networked" ]; do i=$((i+1)); test "$i" -lt 40; sleep .1; done
echo 'PASS delayed network boot hook is asynchronous'
