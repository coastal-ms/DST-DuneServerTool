#!/bin/bash
# Run the generated script with isolated paths and a fake update/restart CLI.
set -eu
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/download/steamapps" "$root/state"
sed -e "s@/var/lib/dune-server@$root/state@g" \
    -e "s@/tmp/dst-daily-maintenance.lock@$root/lock@g" \
    -e "s@/tmp/dst-world-restart-active@$root/recovery-active@g" \
    -e "s@/tmp/dst-restart-active@$root/restart-active@g" \
    -e "s@/var/log/dst-daily-maintenance.log@$root/log@g" \
    -e "s@/home/dune/.dune/download@$root/download@g" \
    -e "s@/home/dune/.dune/bin/battlegroup@$root/bin/battlegroup@g" "$1" > "$root/run.sh"
cat > "$root/bin/wget" <<'EOF'
#!/bin/sh
printf '%s\n' '{"public":{"buildid":"200"}}'
EOF
cat > "$root/bin/battlegroup" <<'EOF'
#!/bin/sh
echo "$1" >> "$TEST_ROOT/calls"
if [ "$1" = update ]; then
  if [ "$CASE" = success ]; then exit 0; fi
  if [ "$CASE" = changed ]; then echo '"buildid" "200"' > "$TEST_ROOT/download/steamapps/appmanifest_4754530.acf"; fi
  if [ "$CASE" = missing ]; then rm "$TEST_ROOT/download/steamapps/appmanifest_4754530.acf"; fi
  if [ "$CASE" = recovery ]; then touch "$TEST_ROOT/state/dst-world-restart-recovery-required"; fi
  exit 1
fi
if [ "$CASE" = restart-fail ]; then exit 9; fi
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" TEST_ROOT="$root"
for CASE in success download-fail restart-fail changed missing recovery restart-only; do
  export CASE
  rm -f "$root/state/dst-world-restart-recovery-required" "$root/calls"
  echo '"buildid" "100"' > "$root/download/steamapps/appmanifest_4754530.acf"
  cp "$root/run.sh" "$root/current.sh"
  if [ "$CASE" = restart-only ]; then sed 's/APPLY_UPDATES=1/APPLY_UPDATES=0/' "$root/run.sh" > "$root/current.sh"; fi
  rc=0
  bash "$root/current.sh" || rc=$?
  result=$(cat "$root/state/daily-maintenance-result")
  calls=$(tr '\n' ',' < "$root/calls")
  case "$CASE" in
    success) [ "$rc" = 0 ]; [ "$calls" = update, ]; [[ "$result" = *'|update|0|100|200' ]] ;;
    download-fail) [ "$rc" = 1 ]; [ "$calls" = update,restart, ]; [[ "$result" = *'|update-failed-restart-ok|1|100|200' ]] ;;
    restart-fail) [ "$rc" = 1 ]; [ "$calls" = update,restart, ]; [[ "$result" = *'|update-failed-restart-failed|1|100|200' ]] ;;
    changed|missing|recovery) [ "$rc" = 1 ]; [ "$calls" = update, ]; [[ "$result" = *'|update|1|100|200' ]] ;;
    restart-only) [ "$rc" = 0 ]; [ "$calls" = restart, ]; [[ "$result" = *'|restart|0|100|200' ]] ;;
  esac
  echo "$CASE passed"
done
