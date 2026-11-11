#!/bin/sh
# Invoked only by an already requested start/restart/update. Never by Save.
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
case "${1:-}" in --stopped|--maintenance) MODE=$1;; *) echo 'An explicit start or maintenance context is required.' >&2; exit 2;; esac
command -v jq >/dev/null || { echo 'jq is required to apply saved map files.' >&2; exit 1; }
umask 077
WORK=$(mktemp -d /tmp/dst-map-apply.XXXXXX)
trap 'rm -rf "$WORK"' EXIT HUP INT TERM
kubectl get battlegroups -A -o json > "$WORK/worlds.json"
jq -e '.items[0]' "$WORK/worlds.json" > "$WORK/original.json"
UID_VALUE=$(jq -r '.metadata.uid' "$WORK/original.json")
NS=$(jq -r '.metadata.namespace' "$WORK/original.json")
NAME=$(jq -r '.metadata.name' "$WORK/original.json")
STORE=dst-saved-map-settings-$(printf '%s' "$UID_VALUE" | sha256sum | cut -c1-20)
kubectl get configmap "$STORE" -n "$NS" --ignore-not-found -o json > "$WORK/store.json"
if [ ! -s "$WORK/store.json" ]; then echo DST_MAP_SETTINGS_UNCHANGED=0; exit 0; fi
jq -e --arg uid "$UID_VALUE" '.data.worldUid == $uid' "$WORK/store.json" >/dev/null || { echo 'Saved map files belong to another world.' >&2; exit 1; }
if [ "$(jq -r '.data.enabled // "true"' "$WORK/store.json")" != true ]; then echo DST_MAP_SETTINGS_UNCHANGED=0; exit 0; fi
jq -c '.data | to_entries[] | select(.key | test("^partition-[1-9][0-9]*\\.json$")) | . as $kv | (.value | fromjson) + {_storeKey:$kv.key}' "$WORK/store.json" > "$WORK/entries"
cp "$WORK/original.json" "$WORK/bg.json"
COUNT=0
while IFS= read -r ENTRY; do
    printf '%s' "$ENTRY" > "$WORK/entry.json"
    jq -e --arg uid "$UID_VALUE" '.schema == 1 and .worldUid == $uid and (.inherit|type)=="boolean" and (.raw|type)=="string" and (.partition|type)=="number" and .partition > 0 and (.partition|floor)==.partition and ._storeKey == ("partition-"+(.partition|tostring)+".json") and (.map|test("^(Survival|DeepDesert)_[1-9][0-9]*$")) and (.baseAppliedHash|test("^[a-f0-9]{64}$"))' "$WORK/entry.json" >/dev/null || { echo 'A saved map file is invalid.' >&2; exit 1; }
    PID_VALUE=$(jq -r '.partition' "$WORK/entry.json")
    EXISTS=$(jq --slurpfile e "$WORK/entry.json" '[.spec.database.template.spec.deployment.spec.worldPartitions[]? | select(.map == $e[0].map) | .partitions[]? | select(.id == $e[0].partition and .disable != true)] | length' "$WORK/bg.json")
    if [ "$EXISTS" = 0 ]; then echo "[dst] Ignoring saved settings for removed partition $PID_VALUE." >&2; continue; fi
    jq --slurpfile e "$WORK/entry.json" '.spec.serverGroup.template.spec.sets as $s | [range(0; $s|length) as $i | select($s[$i].map == $e[0].map and (($s[$i].partitions // [] | index($e[0].partition)) != null)) | $i] as $assigned | if ($assigned|length)>0 then $assigned else [range(0;$s|length) as $i | select($s[$i].map == $e[0].map and ($s[$i].partitions // [] | length)==0) | $i] end' "$WORK/bg.json" > "$WORK/sets.json"
    [ "$(jq 'length' "$WORK/sets.json")" = 1 ] || { echo "Ambiguous ServerSet for saved partition $PID_VALUE." >&2; exit 1; }
    INDEX=$(jq '.[0]' "$WORK/sets.json")
    jq --argjson i "$INDEX" --slurpfile e "$WORK/entry.json" '[.spec.serverGroup.template.spec.sets[$i].podSpecs[]? | select(.index == $e[0].partition)]' "$WORK/bg.json" > "$WORK/pods.json"
    [ "$(jq 'length' "$WORK/pods.json")" -le 1 ] || { echo 'Duplicate partition overrides.' >&2; exit 1; }
    jq --argjson id "$PID_VALUE" '.[0] // {index:$id}' "$WORK/pods.json" > "$WORK/pod.json"
    jq -e --slurpfile e "$WORK/entry.json" '(.map == null or .map == $e[0].map) and (.userIniConfig.mountPath == null or .userIniConfig.mountPath == "/home/dune/server/DuneSandbox/Saved/Config/LinuxServer")' "$WORK/pod.json" >/dev/null || { echo 'Map assignment or INI mount changed.' >&2; exit 1; }
    HAS_FILE=$(jq '.userIniConfig.files // {} | has("ServerCustomSettings.ini")' "$WORK/pod.json")
    if [ "$HAS_FILE" = true ]; then ACTUAL=$({ printf 'override:'; jq -j '.userIniConfig.files["ServerCustomSettings.ini"]' "$WORK/pod.json"; } | sha256sum | cut -d' ' -f1); else ACTUAL=$(printf inherit | sha256sum | cut -d' ' -f1); fi
    if [ "$(jq '.inherit' "$WORK/entry.json")" = true ]; then DESIRED=$(printf inherit | sha256sum | cut -d' ' -f1); else DESIRED=$({ printf 'override:'; jq -j '.raw' "$WORK/entry.json"; } | sha256sum | cut -d' ' -f1); fi
    if [ "$ACTUAL" = "$DESIRED" ]; then continue; fi
    [ "$ACTUAL" = "$(jq -r '.baseAppliedHash' "$WORK/entry.json")" ] || { echo "Partition $PID_VALUE was edited after its map file was saved. Refresh and review it before restarting." >&2; exit 1; }
    jq --slurpfile e "$WORK/entry.json" '.userIniConfig //= {mountPath:"/home/dune/server/DuneSandbox/Saved/Config/LinuxServer",files:{}} | .userIniConfig.files //= {} | if $e[0].inherit then del(.userIniConfig.files["ServerCustomSettings.ini"]) else .userIniConfig.files["ServerCustomSettings.ini"] = $e[0].raw end' "$WORK/pod.json" > "$WORK/newpod.json"
    jq --argjson i "$INDEX" --argjson id "$PID_VALUE" --slurpfile pod "$WORK/newpod.json" '.spec.serverGroup.template.spec.sets[$i].podSpecs = ((.spec.serverGroup.template.spec.sets[$i].podSpecs // []) | if any(.[]; .index == $id) then map(if .index == $id then $pod[0] else . end) else . + [$pod[0]] end)' "$WORK/bg.json" > "$WORK/next.json"
    mv "$WORK/next.json" "$WORK/bg.json"
    COUNT=$((COUNT+1))
done < "$WORK/entries"
if [ "$COUNT" = 0 ]; then echo DST_MAP_SETTINGS_UNCHANGED=0; exit 0; fi
if [ "$MODE" = --stopped ]; then
    jq -e '.spec.stop == true' "$WORK/original.json" >/dev/null || { echo 'Battlegroup is not stopped.' >&2; exit 1; }
    kubectl get pods -n "$NS" -l role=igw-server -o json > "$WORK/game-pods.json"
    [ "$(jq '.items|length' "$WORK/game-pods.json")" = 0 ] || { echo 'Wait for all game pods to stop.' >&2; exit 1; }
fi
kubectl get configmap "$STORE" -n "$NS" -o json > "$WORK/store-now.json"
[ "$(jq -r '.metadata.resourceVersion' "$WORK/store-now.json")" = "$(jq -r '.metadata.resourceVersion' "$WORK/store.json")" ] || { echo 'Saved map files changed during restart preparation.' >&2; exit 1; }
jq -n --slurpfile old "$WORK/original.json" --slurpfile new "$WORK/bg.json" '[{op:"test",path:"/metadata/uid",value:$old[0].metadata.uid},{op:"test",path:"/spec",value:$old[0].spec},{op:"add",path:"/spec/serverGroup/template/spec/sets",value:$new[0].spec.serverGroup.template.spec.sets}]' > "$WORK/patch.json"
kubectl patch battlegroup "$NAME" -n "$NS" --type=json --patch-file="$WORK/patch.json" >/dev/null
echo "DST_MAP_SETTINGS_APPLIED=$COUNT"
