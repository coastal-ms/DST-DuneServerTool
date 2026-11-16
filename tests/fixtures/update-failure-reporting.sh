#!/bin/bash
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
cp "$2" "$root/state/update-failure-webhook"
cat > "$root/bin/wget" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  if [[ "$arg" == --post-data=* ]]; then
    printf '%s\n' "${arg#--post-data=}" >> "$TEST_ROOT/posts"
    exit 0
  fi
done
printf '%s\n' '{"public":{"buildid":"200"}}'
EOF
cat > "$root/bin/battlegroup" <<'EOF'
#!/bin/sh
echo "$1" >> "$TEST_ROOT/calls"
if [ "$1" = update ]; then
  case "$CASE" in
    success) exit 0 ;;
    steamcmd|restart-fail) echo "Error! App '4754530' state is 0x6 after update job." >&2 ;;
    other-app) echo "Error! App '896660' state is 0x6 after update job." >&2 ;;
    generic) echo 'Updater command could not complete' >&2 ;;
  esac
  exit 7
fi
[ "$CASE" != restart-fail ] || exit 9
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" TEST_ROOT="$root"
for CASE in steamcmd other-app generic restart-fail; do
  export CASE
  rm -f "$root/posts" "$root/calls"
  echo '"buildid" "100"' > "$root/download/steamapps/appmanifest_4754530.acf"
  rc=0; bash "$root/run.sh" || rc=$?
  [ "$rc" = 7 ]
  [ "$(wc -l < "$root/posts" | tr -d ' ')" = 1 ]
  grep -q '|7|100|200' "$root/state/daily-maintenance-result"
  grep -q '|sent' "$root/state/daily-update-failure-notice"
  if [ "$CASE" = steamcmd ] || [ "$CASE" = restart-fail ]; then
    grep -q '|steamcmd|0x6|100|200|' "$root/state/daily-update-failure"
    grep -q 'SteamCMD reported error 0x6' "$root/posts"
  else
    grep -q '|server-update||100|200|' "$root/state/daily-update-failure"
    grep -q 'cause not identified' "$root/posts"
  fi
  if [ "$CASE" = restart-fail ]; then grep -q 'fallback server restart also failed' "$root/posts";
  else grep -q 'Server restarted on the previous build' "$root/posts"; fi
  grep -q '1563393833197117510' "$root/posts"
  ! grep -q '__TIME__\|__RECOVERY__\|__CODE__' "$root/posts"
  echo "$CASE passed"
done
cp "$root/state/daily-update-failure" "$root/saved-failure"
sed 's/APPLY_UPDATES=1/APPLY_UPDATES=0/' "$root/run.sh" > "$root/restart.sh"
CASE=generic; export CASE
bash "$root/restart.sh"
cmp "$root/state/daily-update-failure" "$root/saved-failure"
echo 'ordinary-restart-retains-failure passed'
CASE=success; export CASE
bash "$root/run.sh"
[ ! -e "$root/state/daily-update-failure" ]
echo 'successful-update-clears-failure passed'
