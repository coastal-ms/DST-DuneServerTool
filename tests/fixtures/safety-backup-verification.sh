#!/bin/bash
# Isolated execution of the actual generated safety script; no server access.
set -eu
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
sed -e "s@/funcom/artifacts/database-dumps@$root/dumps@g" -e "s@/home/dune/.dune/bin/battlegroup@$root/bin/battlegroup@g" "$1" > "$root/safety.sh"
cat > "$root/bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
cat > "$root/bin/battlegroup" <<'EOF'
#!/bin/sh
echo cli >> "$TEST_ROOT/calls"
[ "$1" = backup ] && [ "$2" = dst-testing-stations-fixture.backup ] || exit 98
if [ "$CASE" = cli-fail ]; then exit 1; fi
path="$TEST_ROOT/dumps/current/$2"
case "$CASE" in
  existing|corrupt|small)
    mkdir -p "$(dirname "$path")"
    if [ "$CASE" = existing ]; then cat "$TEST_ROOT/archive"; elif [ "$CASE" = small ]; then printf PGDMP; else printf corrupt; fi > "$path" ;;
  wrong-world) path="$TEST_ROOT/dumps/other/$2" ;;
  wrong-name) path="$TEST_ROOT/dumps/current/older.backup" ;;
esac
echo "Backup file (on this host): $path"
if [ "$CASE" = multiple-path ]; then echo "Backup file (on this host): $TEST_ROOT/dumps/other/other.backup"; fi
if [ "$CASE" = no-path ]; then exit 0; fi
EOF
cat > "$root/bin/pg_restore" <<'EOF'
#!/bin/sh
[ "$(head -c 5)" = PGDMP ]
EOF
cat > "$root/bin/kubectl" <<'EOF'
#!/bin/sh
case "$*" in
  'get pods -n funcom-seabass-current --no-headers')
    echo 'current-db-dbdepl-sts-0 1/1 Running'
    if [ "$CASE" = ambiguous ]; then echo 'current-db-dbdepl-sts-1 1/1 Running'; fi ;;
  'get battlegroup current -n funcom-seabass-current -o yaml')
    if [ "$CASE" = yaml-fail ]; then exit 1; fi
    echo 'kind: Battlegroup' ;;
  *' -- pg_dump '*)
    echo "$*" >> "$TEST_ROOT/dump-calls"
    if [ "$CASE" = dump-fail ]; then printf partial; exit 1; fi
    cat "$TEST_ROOT/archive" ;;
  *' -- sh -c '*)
    while [ "$1" != -- ]; do shift; done
    shift
    exec "$@" ;;
  *) echo "unexpected kubectl: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" TEST_ROOT="$root"
printf PGDMP > "$root/archive"
head -c 2097152 /dev/zero >> "$root/archive"
for CASE in absent stale existing corrupt small dump-fail yaml-fail ambiguous wrong-world wrong-name multiple-path cli-fail preexisting; do
  export CASE
  rm -rf "$root/dumps"
  mkdir -p "$root/dumps/current"
  printf 'older sentinel' > "$root/dumps/current/older.backup"
  : > "$root/calls"
  : > "$root/dump-calls"
  if [ "$CASE" = preexisting ]; then cat "$root/archive" > "$root/dumps/current/dst-testing-stations-fixture.backup"; fi
  rc=0
  bash "$root/safety.sh" > "$root/output" 2>&1 || rc=$?
  case "$CASE" in
    absent|stale|existing)
      [ "$rc" = 0 ] || { cat "$root/output"; exit 1; }
      grep -Eq "^DST_TESTING_STATIONS_BACKUP=$root/dumps/current/dst-testing-stations-fixture.backup\|[0-9]+$" "$root/output"
      cmp "$root/archive" "$root/dumps/current/dst-testing-stations-fixture.backup"
      test -s "$root/dumps/current/dst-testing-stations-fixture.backup.yaml"
      if [ "$CASE" != existing ]; then grep -q -- '-p 15433 -F custom' "$root/dump-calls"; fi ;;
    *) [ "$rc" != 0 ] || { echo "$CASE falsely succeeded"; exit 1; }
       if grep -q '^DST_TESTING_STATIONS_BACKUP=' "$root/output"; then echo "$CASE emitted false proof"; exit 1; fi ;;
  esac
  [ "$(cat "$root/dumps/current/older.backup")" = 'older sentinel' ]
  case "$CASE" in
    corrupt) [ "$(cat "$root/dumps/current/dst-testing-stations-fixture.backup")" = corrupt ]; test ! -s "$root/dump-calls" ;;
    wrong-world|wrong-name|multiple-path|cli-fail|ambiguous) test ! -s "$root/dump-calls" ;;
    preexisting) test ! -s "$root/calls" ;;
  esac
  echo "$CASE passed"
done
