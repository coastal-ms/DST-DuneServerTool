#!/bin/bash
# Execute the shipped verifier against isolated files and fake Kubernetes tools.
set -eu
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
real_timeout=$(command -v timeout)
export REAL_TIMEOUT="$real_timeout"
sed "s@/funcom/artifacts/database-dumps@$root/dumps@g" "$1" > "$root/verify.sh"
if [ "$#" -gt 1 ]; then
  sed -e "s@/funcom/artifacts/database-dumps@$root/dumps@g" -e "s@/home/dune/.dune/bin/battlegroup@$root/bin/battlegroup@g" -e "s@/var/log/dune-backup.log@$root/output@g" -e "s@__RETENTION_MARKER__@$root/retained@g" "$2" > "$root/scheduled.sh"
fi
cat > "$root/bin/battlegroup" <<'EOF'
#!/bin/sh
cat "$TEST_ROOT/current-output"
EOF
cat > "$root/bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
EOF
cat > "$root/bin/timeout" <<'EOF'
#!/bin/sh
limit=$1; shift
if [ "$CASE" = stalled ]; then limit=1; fi
exec "$REAL_TIMEOUT" "$limit" "$@"
EOF
cat > "$root/bin/pg_restore" <<'EOF'
#!/bin/sh
# A catalog reader exits before consuming a large archive, like real pg_restore.
value=$(head -c 5)
[ "$value" = PGDMP ]
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
    echo dump >> "$TEST_ROOT/calls"
    if [ "$CASE" = dump-fail ]; then printf partial; exit 1; fi
    cat "$TEST_ROOT/archive" ;;
  *' -- sh -c '*)
    if [ "$CASE" = stalled ]; then sleep 20; exit 1; fi
    while [ "$1" != -- ]; do shift; done
    shift
    exec "$@" ;;
  *) echo "unexpected kubectl invocation: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" TEST_ROOT="$root"
printf PGDMP > "$root/archive"
head -c 2097152 /dev/zero >> "$root/archive"
for mode in manual ${2:+scheduled}; do
for CASE in absent stale empty existing dump-fail yaml-fail ambiguous corrupt no-path multiple-path stalled; do
  export CASE
  rm -rf "$root/dumps"
  : > "$root/calls"
  rm -f "$root/retained"
  mkdir -p "$root/dumps/older"
  printf 'older sentinel' > "$root/dumps/older/old.backup"
  printf 'older spec' > "$root/dumps/older/old.backup.yaml"
  _bk="Backup file (on this host): $root/dumps/current/current-20261002-010000.backup"
  case "$CASE" in
    empty)
      mkdir -p "$root/dumps/current"
      : > "$root/dumps/current/current-20261002-010000.backup" ;;
    existing|corrupt)
      mkdir -p "$root/dumps/current"
      printf 'kind: Battlegroup' > "$root/dumps/current/current-20261002-010000.backup.yaml"
      if [ "$CASE" = existing ]; then cat "$root/archive"; else printf corrupt; fi > "$root/dumps/current/current-20261002-010000.backup" ;;
    no-path) _bk='No backup path reported' ;;
    multiple-path) _bk="$_bk
Backup file (on this host): $root/dumps/current/another.backup" ;;
  esac
  printf '%s\n' "$_bk" > "$root/current-output"
  rc=0
  ( . "$root/$([ "$mode" = manual ] && echo verify || echo scheduled).sh" ) > "$root/output" 2>&1 || rc=$?
  case "$CASE" in
    absent|stale|empty|existing)
      [ "$rc" = 0 ] || { cat "$root/output"; exit 1; }
      cmp "$root/archive" "$root/dumps/current/current-20261002-010000.backup"
      test -s "$root/dumps/current/current-20261002-010000.backup.yaml"
      if [ "$mode" = scheduled ]; then test -s "$root/retained"; fi ;;
    *) [ "$rc" != 0 ] || { echo "$CASE falsely succeeded"; exit 1; }
       test ! -e "$root/retained" ;;
  esac
  [ "$(cat "$root/dumps/older/old.backup")" = 'older sentinel' ]
  if [ "$CASE" = existing ] || [ "$CASE" = corrupt ] || [ "$CASE" = ambiguous ] || [ "$CASE" = no-path ] || [ "$CASE" = multiple-path ]; then test ! -s "$root/calls"; fi
  if [ "$CASE" = dump-fail ] || [ "$CASE" = stalled ]; then test ! -e "$root/dumps/current/current-20261002-010000.backup"; fi
  if [ "$CASE" = corrupt ]; then [ "$(cat "$root/dumps/current/current-20261002-010000.backup")" = corrupt ]; fi
  echo "$CASE passed"
done
done
