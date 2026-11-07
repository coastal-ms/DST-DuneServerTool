#!/bin/bash
# DST-owned reversible wrapper around the installed Funcom swap preset.
set -euo pipefail
umask 077
mode=${1:-}
case "$mode" in enable|disable) ;; *) echo 'Expected enable or disable.' >&2; exit 2;; esac
die() { echo "Swap change stopped: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die 'Root access is required.'
for tool in kubectl jq rc-service; do command -v "$tool" >/dev/null || die "Missing $tool."; done
root=/home/dune/.dune/dst-experimental-swap
active=$root/active
native=/home/dune/.dune/download/scripts/setup/experimental_swap.sh
files=(/etc/fstab /etc/rancher/k3s/config.yaml /etc/rancher/k3s/kubelet-config.yaml)
[ ! -L "$root" ] || die 'Snapshot directory must not be a symlink.'
mkdir -p "$root"
chmod 700 "$root"
mkdir /run/dst-experimental-swap.lock 2>/dev/null || die 'Another swap change is running; inspect it before retrying.'
trap 'rmdir /run/dst-experimental-swap.lock' EXIT
if ! current=$(kubectl get battlegroups -A -o json); then
  if [ "$mode" = disable ] && [ -f "$active/complete" ]; then
    echo 'K3s is unavailable after an earlier change; starting it to validate the saved battlegroup.'
    rc-service k3s start
    for ((i=0;i<30;i++)); do if current=$(kubectl get battlegroups -A -o json); then break; fi; sleep 2; done
  else die 'Cannot read the current battlegroup; no settings changed.'; fi
fi
[ "$(jq '.items|length' <<<"$current")" = 1 ] || die 'Exactly one battlegroup is required.'
bg=$(jq -r '.items[0].metadata.name' <<<"$current")
ns=$(jq -r '.items[0].metadata.namespace' <<<"$current")
uid=$(jq -r '.items[0].metadata.uid' <<<"$current")
jq -e '.items[0].spec.stop==true' <<<"$current" >/dev/null || die 'Stop the battlegroup in DST first; leave the VM running.'
live=$(kubectl get pods -n "$ns" -l role=igw-server -o json | jq '[.items[]|select(.status.phase!="Succeeded" and .status.phase!="Failed")]|length')
[ "$live" = 0 ] || die 'Wait for all map pods to stop before changing swap.'
if [ "$mode" = enable ]; then
  [ -f "$native" ] || die 'Installed Funcom swap script is missing.'
  [ ! -e /swapfile ] || die 'A swapfile already exists. No original settings will be overwritten.'
  [ "$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)" = 0 ] || die 'Swap is already configured; a pre-swap snapshot is required to reverse it.'
  # The inspected Funcom preset creates a 30 GiB file. Reject a changed size
  # instead of making an unverified disk-space promise after an upstream update.
  grep -Eq 'count=31457280([[:space:]]|$)' "$native" || die 'Funcom swap-file size changed; review the installed preset before proceeding.'
  free_k=$(df -Pk / | awk 'NR==2{print $4}')
  [ "$free_k" -ge 36700160 ] || die 'Need at least 35 GiB free on the VM root disk for the 30 GiB preset and 5 GiB headroom.'
  if [ -e "$active" ]; then
    [ -f "$active/status" ] && [ "$(cat "$active/status")" = disabled ] || die 'An earlier snapshot or incomplete change exists; preserve it and inspect before retrying.'
    mkdir -p "$root/history"
    mv "$active" "$root/history/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fi
  mkdir -m 700 "$active"
  jq '.items[0]|{uid:.metadata.uid,name:.metadata.name,namespace:.metadata.namespace,sets:[.spec.serverGroup.template.spec.sets[]|{map,resources,resourcesPresent:has("resources")} ]}' <<<"$current" > "$active/resources.json"
  for i in "${!files[@]}"; do
    if [ -e "${files[$i]}" ]; then cp -p "${files[$i]}" "$active/file-$i"; else touch "$active/absent-$i"; fi
  done
  if [ -L /etc/runlevels/boot/swap ]; then readlink /etc/runlevels/boot/swap > "$active/boot-link"; else touch "$active/boot-absent"; fi
  if [ -f /sys/fs/cgroup/openrc.k3s/memory.swap.max ]; then cat /sys/fs/cgroup/openrc.k3s/memory.swap.max > "$active/cgroup-swap-max"; fi
  sha256sum "$native" > "$active/native.sha256"
  printf 'enabling\n' > "$active/status"
  touch "$active/complete"
  echo 'Original configuration and exact map resources saved. Enabling swap; K3s will restart.'
  latest=$(kubectl get battlegroup -n "$ns" "$bg" -o json)
  jq -e --arg uid "$uid" --argjson spec "$(jq '.items[0].spec' <<<"$current")" '.metadata.uid==$uid and .spec==$spec' <<<"$latest" >/dev/null || die 'Battlegroup changed during preparation. Snapshot retained; review before proceeding.'
  if ! bash "$native" "$bg"; then die 'Funcom enable failed. Original snapshot retained; do not rerun Enable. Use Disable to restore, or inspect the failure.'; fi
  awk 'NR>1&&$1=="/swapfile"{found=1} END{exit !found}' /proc/swaps || die 'Swap activation was not confirmed. Snapshot retained.'
  printf 'enabled\n' > "$active/status"
  echo 'DUNE_SWAP_ENABLED: Start the battlegroup normally in DST when ready.'
else
  [ -f "$active/complete" ] && [ -f "$active/resources.json" ] || die 'No saved pre-swap configuration. DST will not guess original map limits; use a reviewed backup or support-assisted recovery.'
  [ "$(cat "$active/status")" != disabled ] || die 'Swap was already disabled; start the battlegroup normally in DST.'
  jq -e --arg uid "$uid" --arg bg "$bg" --arg ns "$ns" '.uid==$uid and .name==$bg and .namespace==$ns' "$active/resources.json" >/dev/null || die 'Saved snapshot belongs to another battlegroup.'
  jq -e --slurpfile old "$active/resources.json" '([.items[0].spec.serverGroup.template.spec.sets[].map]|sort)==([$old[0].sets[].map]|sort) and ([.items[0].spec.serverGroup.template.spec.sets[].map]|length)==([.items[0].spec.serverGroup.template.spec.sets[].map]|unique|length)' <<<"$current" >/dev/null || die 'Map scope changed; review the saved resources before restoring.'
  for i in "${!files[@]}"; do [ -f "$active/file-$i" ] || [ -f "$active/absent-$i" ] || die 'Configuration snapshot is incomplete.'; done
  [ ! -L /swapfile ] || die 'Swapfile path changed; refusing removal.'
  printf 'disabling\n' > "$active/status"
  # Match resources by map identity, never by a stale array index.
  jq --slurpfile old "$active/resources.json" '[{op:"test",path:"/metadata/resourceVersion",value:.items[0].metadata.resourceVersion},{op:"test",path:"/spec/stop",value:true}]+[.items[0].spec.serverGroup.template.spec.sets|to_entries[]|. as $now|($old[0].sets[]|select(.map==$now.value.map)) as $prior|if $prior.resourcesPresent then {op:"add",path:("/spec/serverGroup/template/spec/sets/"+($now.key|tostring)+"/resources"),value:$prior.resources} elif ($now.value|has("resources")) then {op:"remove",path:("/spec/serverGroup/template/spec/sets/"+($now.key|tostring)+"/resources")} else empty end]' <<<"$current" > "$active/restore-patch.json"
  kubectl patch battlegroup -n "$ns" "$bg" --type=json --patch-file="$active/restore-patch.json"
  echo 'Restoring original resources; disabling swap and restarting K3s. The battlegroup stays stopped.'
  rc-service k3s stop
  k3s-killall.sh
  if awk 'NR>1&&$1=="/swapfile"{found=1} END{exit !found}' /proc/swaps; then
    if ! swapoff /swapfile; then rc-service k3s start; die 'Could not disable swap. File and snapshot preserved; inspect memory use before retrying.'; fi
  fi
  for i in "${!files[@]}"; do
    if [ -f "$active/file-$i" ]; then cp -p "$active/file-$i" "${files[$i]}"; else rm -f "${files[$i]}"; fi
  done
  if [ -f "$active/boot-link" ]; then ln -sfn "$(cat "$active/boot-link")" /etc/runlevels/boot/swap; else rc-update del swap boot || true; fi
  [ ! -e /swapfile ] || rm /swapfile
  rc-service k3s start
  if [ -f "$active/cgroup-swap-max" ] && [ -f /sys/fs/cgroup/openrc.k3s/memory.swap.max ]; then cat "$active/cgroup-swap-max" > /sys/fs/cgroup/openrc.k3s/memory.swap.max; fi
  ready=0
  for ((i=0;i<60;i++)); do if kubectl get battlegroup -n "$ns" "$bg" >/dev/null 2>&1; then ready=1; break; fi; sleep 2; done
  [ "$ready" = 1 ] || die 'Original files restored but K3s is not yet reachable. Snapshot retained; battlegroup remains stopped.'
  restored=$(kubectl get battlegroup -n "$ns" "$bg" -o json)
  jq -e --slurpfile old "$active/resources.json" '([.spec.serverGroup.template.spec.sets[]|{map,resources,resourcesPresent:has("resources")}]|sort_by(.map))==($old[0].sets|sort_by(.map))' <<<"$restored" >/dev/null || die 'Map resource readback differs; snapshot retained.'
  [ "$(awk '/^SwapTotal:/{print $2}' /proc/meminfo)" = 0 ] || die 'Other swap remains active; review before reporting swap disabled.'
  for i in "${!files[@]}"; do
    if [ -f "$active/file-$i" ]; then cmp "$active/file-$i" "${files[$i]}"; else [ ! -e "${files[$i]}" ] || die 'Unexpected configuration file after restore.'; fi
  done
  printf 'disabled\n' > "$active/status"
  echo 'DUNE_SWAP_DISABLED: Original map resources and configuration verified. Check VM RAM before starting the battlegroup normally in DST.'
fi
