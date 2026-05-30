#!/bin/bash
# dune-swap-doctor.sh
#
# Checks a Dune Awakening self-hosted server (Alpine + K3s) for the
# "experimental swap" misconfiguration that causes per-map pods to lag
# or get OOM-killed on transitions (red-bar / high ping when exiting
# Hagga Basin into Overland / Deep Desert, etc).
#
# Usage:
#   bash dune-swap-doctor.sh           # check only (read-only)
#   bash dune-swap-doctor.sh --fix     # check, then prompt before fixing
#   bash dune-swap-doctor.sh --fix -y  # check + fix without prompting (CAREFUL)
#
# What it checks:
#   1. Swap is OFF (no /swapfile, no swap line in fstab)
#   2. Kubelet is NOT using a swap-aware override config
#   3. Per-map memory limits match Funcom's world-template.yaml defaults
#
# What --fix does (only if problems found):
#   - Backs up live BG yaml, kubelet configs, /etc/fstab to ~/.dune/
#   - Stops k3s, swapoff -a, deletes /swapfile, strips fstab swap line,
#     removes swap from boot runlevel
#   - Deletes /etc/rancher/k3s/config.yaml + kubelet-config.yaml
#   - Restarts k3s, waits for Ready
#   - kubectl patches every map back to template defaults
#
# Does NOT touch networking, eth0:1, iptables, or DB. Safe to run multiple times.

set +e

ASSUME_YES=0
DO_FIX=0
for arg in "$@"; do
  case "$arg" in
    --fix) DO_FIX=1 ;;
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
  esac
done

# ------------------------------------------------------------------------------
# Template defaults (from Funcom's world-template.yaml, 2026-05 snapshot)
# ------------------------------------------------------------------------------
declare -A EXPECTED=(
  [Survival_1]=12Gi
  [Overmap]=2Gi
  [DeepDesert_1]=15Gi
  [SH_Arrakeen]=2Gi
  [SH_HarkoVillage]=2Gi
  [Story_ProcesVerbal]=6Gi
  [Story_ArtOfKanly]=3Gi
  [Story_Faction_Outpost_Atre]=3Gi
  [Story_Faction_Outpost_Hark]=3Gi
  [Story_HeighlinerDungeon]=3Gi
  [DLC_Story_LostHarvest_EcolabA]=5Gi
  [DLC_Story_LostHarvest_EcolabB]=5Gi
  [DLC_Story_LostHarvest_ForgottenLab]=5Gi
  [CB_Story_Hephaestus]=2Gi
  [CB_Story_Ecolab_Carthag]=2Gi
  [CB_Story_WaterFatManor]=2Gi
  [CB_Story_BanditFortress01]=2Gi
  [CB_Dungeon_Hephaestus]=3Gi
  [CB_Dungeon_OldCarthag]=3Gi
  [CB_Dungeon_ThePit]=2Gi
  [CB_Ecolab_Bronze_Green_089]=6Gi
  [CB_Ecolab_Bronze_Green_024]=3Gi
  [CB_Ecolab_Bronze_Green_136]=3Gi
  [CB_Ecolab_Bronze_Green_152]=3Gi
  [CB_Ecolab_Bronze_Green_195]=3Gi
  [CB_Overland_M_01]=3Gi
  [CB_Overland_S_04]=3Gi
  [CB_Overland_S_06]=3Gi
  [CB_Overland_S_07]=2Gi
  [CB_Overland_S_08]=2Gi
)

# Known swap-mode (bad) values that indicate experimental_swap.sh ran:
is_swap_mode_value() {
  case "$1" in
    1Gi|200Mi|10Gi) return 0 ;;
    *) return 1 ;;
  esac
}

# Convert a memory string like "2Gi", "200Mi", "1024Mi" to MiB integer.
# Returns 0 on parse failure.
to_mib() {
  local v="$1"
  case "$v" in
    *Gi) echo $(( ${v%Gi} * 1024 )) ;;
    *Mi) echo "${v%Mi}" ;;
    *Ki) echo $(( ${v%Ki} / 1024 )) ;;
    "")  echo 0 ;;
    *)   echo 0 ;;
  esac
}

# ------------------------------------------------------------------------------
banner() { echo; echo "============================================================"; echo "$1"; echo "============================================================"; }
ok()  { echo "  [OK]   $1"; }
bad() { echo "  [BAD]  $1"; PROBLEMS=$((PROBLEMS+1)); }
note(){ echo "         $1"; }

PROBLEMS=0
banner "Dune server health check ($(date))"
echo "Host: $(hostname)"

# 1. Swap
banner "1. Swap state"
SW=$(free -h | awk '/Swap:/ {print $2}')
echo "  free -h Swap total: $SW"
if [ "$SW" = "0B" ] || [ "$SW" = "0" ]; then
  ok "swap is OFF"
else
  bad "swap is ACTIVE ($SW) -- experimental-swap likely ON"
fi
if [ -f /swapfile ]; then
  bad "/swapfile exists ($(ls -lh /swapfile | awk '{print $5}'))"
else
  ok "no /swapfile"
fi
if grep -qE '^[^#].*\bswap\b' /etc/fstab 2>/dev/null; then
  bad "/etc/fstab has an active swap line"
else
  ok "/etc/fstab clean"
fi

# 2. Kubelet config
banner "2. Kubelet config"
if [ -f /etc/rancher/k3s/config.yaml ]; then
  bad "/etc/rancher/k3s/config.yaml exists (kubelet using custom config)"
  sed 's/^/         /' /etc/rancher/k3s/config.yaml
else
  ok "no /etc/rancher/k3s/config.yaml"
fi
if [ -f /etc/rancher/k3s/kubelet-config.yaml ]; then
  bad "/etc/rancher/k3s/kubelet-config.yaml exists (swap-mode kubelet)"
else
  ok "no kubelet-config.yaml"
fi

# 3. K3s node
banner "3. K3s node"
sudo kubectl get nodes 2>&1 | sed 's/^/  /'

# 4. Memory pressure
banner "4. Host memory"
free -h | sed 's/^/  /'

# 5. Per-map memory limits
banner "5. Per-map memory limits vs Funcom template defaults"
NS=$(sudo kubectl get battlegroup -A --no-headers 2>/dev/null | awk '{print $1}' | head -1)
BG=$(sudo kubectl get battlegroup -A --no-headers 2>/dev/null | awk '{print $2}' | head -1)
if [ -z "$BG" ]; then
  bad "no battlegroup found in cluster"
else
  echo "  Battlegroup: $BG  (namespace: $NS)"; echo
  printf "  %-40s %-10s %-10s %s\n" "MAP" "CURRENT" "EXPECTED" "STATUS"
  printf "  %-40s %-10s %-10s %s\n" "---" "-------" "--------" "------"
  MAP_PROBS=0
  PATCHES=()
  while IFS=$'\t' read -r MAP CUR IDX; do
    EXP="${EXPECTED[$MAP]}"
    if [ -z "$EXP" ]; then
      STAT="(unknown map, skipping)"
    elif [ "$CUR" = "$EXP" ]; then
      STAT="ok"
    elif is_swap_mode_value "$CUR"; then
      STAT="<-- SWAP-MODE (would patch to $EXP)"
      MAP_PROBS=$((MAP_PROBS+1))
      PATCHES+=("$IDX:$MAP:$EXP")
    else
      # Only flag for patching if CURRENT is BELOW expected (true downgrade
      # from swap-mode or other reduction). A value ABOVE expected means the
      # operator intentionally bumped it -- leave it alone.
      CUR_MIB=$(to_mib "$CUR")
      EXP_MIB=$(to_mib "$EXP")
      if [ "$CUR_MIB" -gt 0 ] && [ "$EXP_MIB" -gt 0 ] && [ "$CUR_MIB" -lt "$EXP_MIB" ]; then
        STAT="<-- below default (would patch to $EXP)"
        MAP_PROBS=$((MAP_PROBS+1))
        PATCHES+=("$IDX:$MAP:$EXP")
      else
        STAT="above default ($EXP), left as-is"
      fi
    fi
    printf "  %-40s %-10s %-10s %s\n" "$MAP" "$CUR" "${EXP:-?}" "$STAT"
  done < <(sudo kubectl get battlegroup -n "$NS" "$BG" -o json 2>/dev/null | \
           jq -r '.spec.serverGroup.template.spec.sets | to_entries[] |
                  "\(.value.map)\t\(.value.resources.limits.memory // "<none>")\t\(.key)"')
  if [ "$MAP_PROBS" -gt 0 ]; then
    bad "$MAP_PROBS map(s) need patching"
  else
    ok "all per-map memory limits match template"
  fi
fi

banner "Summary"
if [ "$PROBLEMS" -eq 0 ]; then
  echo "  No problems found. Server is configured like a normal (non-swap) deployment."
  echo
  exit 0
fi

echo "  $PROBLEMS issue(s) found."
echo
if [ "$DO_FIX" -ne 1 ]; then
  echo "  To fix automatically, re-run with:  bash $0 --fix"
  echo "  (script will back up everything before changing anything)"
  exit 1
fi

# ------------------------------------------------------------------------------
# FIX PATH
# ------------------------------------------------------------------------------
banner "FIX MODE"
echo "  This will:"
echo "    * Stop k3s briefly (BG offline ~2-5 min)"
echo "    * Disable swap and remove /swapfile"
echo "    * Delete /etc/rancher/k3s/config.yaml + kubelet-config.yaml"
echo "    * Restart k3s, wait for node Ready"
echo "    * kubectl patch each map back to template defaults"
echo
echo "  Backups go to ~/.dune/ before any change."
echo
if [ "$ASSUME_YES" -ne 1 ]; then
  printf "  Type 'yes' to proceed: "
  read CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "  Aborted. No changes made."
    exit 1
  fi
fi

TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="$HOME/.dune"
mkdir -p "$BACKUP_DIR"
echo "  Backup dir: $BACKUP_DIR (timestamp $TS)"

# Backup BG yaml
if [ -n "$BG" ]; then
  sudo kubectl get battlegroup -n "$NS" "$BG" -o yaml \
    > "$BACKUP_DIR/bg-pre-swap-disable-$TS.yaml" 2>/dev/null \
    && echo "  saved BG yaml -> $BACKUP_DIR/bg-pre-swap-disable-$TS.yaml"
fi
# Backup kubelet configs
for F in /etc/rancher/k3s/config.yaml /etc/rancher/k3s/kubelet-config.yaml; do
  if [ -f "$F" ]; then
    BN=$(basename "$F" .yaml)
    sudo cp -p "$F" "$BACKUP_DIR/${BN}-$TS.yaml" \
      && echo "  saved $F -> $BACKUP_DIR/${BN}-$TS.yaml"
  fi
done
# Backup fstab
sudo cp -p /etc/fstab "$BACKUP_DIR/fstab-$TS.bak" && echo "  saved /etc/fstab"

banner "Stopping k3s"
sudo rc-service k3s stop 2>&1 | sed 's/^/  /'
sleep 3

banner "Disabling swap"
sudo swapoff -a 2>&1 | sed 's/^/  /'
if [ -f /swapfile ]; then
  sudo rm -f /swapfile && echo "  removed /swapfile"
fi
# strip swap line from fstab (keeps a backup we just made)
sudo sed -i.swapdr -e '/\bswap\b/d' /etc/fstab && echo "  stripped swap line from /etc/fstab"
# remove from boot runlevel (alpine)
sudo rc-update del swap boot 2>/dev/null || true
echo "  removed swap from boot runlevel"

banner "Removing swap-mode kubelet configs"
sudo rm -f /etc/rancher/k3s/config.yaml /etc/rancher/k3s/kubelet-config.yaml
echo "  done"

banner "Starting k3s"
sudo rc-service k3s start 2>&1 | sed 's/^/  /'
echo "  waiting for node Ready..."
for i in $(seq 1 60); do
  sleep 2
  ST=$(sudo kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
  if [ "$ST" = "Ready" ]; then
    echo "  node Ready after ~$((i*2))s"
    break
  fi
done

banner "Patching per-map memory limits"
if [ "${#PATCHES[@]}" -eq 0 ]; then
  echo "  (nothing to patch)"
else
  for ENTRY in "${PATCHES[@]}"; do
    IDX="${ENTRY%%:*}"; REST="${ENTRY#*:}"
    MAP="${REST%%:*}";  NEW="${REST#*:}"
    PATCH=$(printf '[{"op":"replace","path":"/spec/serverGroup/template/spec/sets/%s/resources","value":{"limits":{"memory":"%s"}}}]' "$IDX" "$NEW")
    OUT=$(sudo kubectl patch battlegroup -n "$NS" "$BG" --type=json -p="$PATCH" 2>&1)
    if echo "$OUT" | grep -qE 'patched|configured'; then
      printf "  [OK]   %-40s -> %s\n" "$MAP" "$NEW"
    else
      printf "  [FAIL] %-40s -> %s  (%s)\n" "$MAP" "$NEW" "$OUT"
    fi
  done
fi

banner "Done"
echo "  Swap disabled and per-map limits reverted to Funcom template defaults."
echo "  Start the battlegroup via your Dune Server Tool to bring pods up fresh"
echo "  with the new limits. Test in-game by exiting Hagga -> Overland."
echo
echo "  Backups (in case you want to revert):"
ls -1 "$BACKUP_DIR"/*-"$TS"* 2>/dev/null | sed 's/^/    /'
