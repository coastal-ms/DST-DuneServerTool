#!/bin/bash
# Execute the generated Windows timezone rules with a controlled UTC clock.
set -eu
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin" "$root/state"
for file in "$1"/*.sh; do
  sed -e "s@/var/lib/dune-server@$root/state@g" \
      -e "s@/tmp/dst-daily-maintenance.lock@$root/lock@g" \
      -e "s@/tmp/dst-world-restart-active@$root/recovery-active@g" \
      -e "s@/tmp/dst-restart-active@$root/restart-active@g" \
      -e "s@/var/log/dst-daily-maintenance.log@$root/log@g" \
      -e "s@/home/dune/.dune/download@$root/download@g" \
      -e "s@/home/dune/.dune/bin/battlegroup@$root/bin/battlegroup@g" "$file" > "$root/$(basename "$file")"
done
cat > "$root/bin/date" <<'EOF'
#!/bin/bash
if [ "$1" = '+%s' ]; then echo "$TEST_EPOCH";
elif [ "$1" = '-d' ]; then /bin/date "$@";
else /bin/date -d "@$TEST_EPOCH" "$@"; fi
EOF
cat > "$root/bin/wget" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$root/bin/battlegroup" <<'EOF'
#!/bin/sh
echo "$1" >> "$TEST_ROOT/calls"
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" TEST_ROOT="$root"
export TZ=UTC0
check() {
  local name=$1 script=$2 instant=$3 expected=$4 reset=${5:-yes}
  if [ "$reset" = yes ]; then rm -f "$root/state/daily-maintenance-slot"; fi
  rm -f "$root/calls"
  TEST_EPOCH=$(/bin/date -u -d "$instant" +%s); export TEST_EPOCH
  bash "$root/$script.sh" --scheduled
  local calls=0
  if [ -f "$root/calls" ]; then calls=$(wc -l < "$root/calls" | tr -d ' '); fi
  if [ "$calls" != "$expected" ]; then echo "$name expected $expected runs; got $calls" >&2; exit 1; fi
  echo "$name passed"
}
check winter central '2026-11-10 20:00:00Z' 1
check winter-old-hour central '2026-11-10 19:00:00Z' 0
check summer central '2026-07-10 19:00:00Z' 1
check summer-old-hour central '2026-07-10 20:00:00Z' 0
check before-spring central '2026-03-07 20:00:00Z' 1
check after-spring central '2026-03-08 19:00:00Z' 1 no
check before-autumn central '2026-10-31 19:00:00Z' 1
check after-autumn central '2026-11-01 20:00:00Z' 1 no
check repeat-minute central '2026-11-01 20:00:30Z' 0 no
check first-autumn-hour repeated '2026-11-01 06:30:00Z' 1
check second-autumn-hour repeated '2026-11-01 07:30:00Z' 0 no
check next-day repeated '2026-11-02 07:30:00Z' 1 no
check new-slot-same-day central '2026-11-02 20:00:00Z' 1 no
check spring-gap-before skipped '2026-03-08 07:59:00Z' 0
check spring-gap-first-valid skipped '2026-03-08 08:00:00Z' 1 no
check spring-gap-following-minute skipped '2026-03-08 08:01:00Z' 0 no
check lord-howe-summer lordhowe '2026-01-10 03:00:00Z' 1
check lord-howe-winter lordhowe '2026-07-10 03:30:00Z' 1
check india-half-hour india '2026-11-10 08:30:00Z' 1
check utc utc '2026-11-10 14:00:00Z' 1
# UTC+05:30 local midnight crosses the UTC calendar date/year boundary.
check local-year-rollover midnight '2025-12-31 18:30:00Z' 1
check fixed-leap-before fixed '2028-02-28 12:00:00Z' 1
check fixed-leap-after fixed '2028-02-29 11:30:00Z' 1
check fixed-non-leap-after fixed '2027-02-28 11:30:00Z' 1
