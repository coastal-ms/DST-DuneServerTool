#!/bin/bash
# Execute the shipped verifier against isolated files and fake Kubernetes tools.
set -eu
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/bin"
sed "s@/funcom/artifacts/database-dumps@$root/dumps@g" "$1" > "$root/verify.sh"
cat > "$root/bin/sudo" <<'EOF'
#!/bin/sh
exec "$@"
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
    printf PGDMP_fixture ;;
  *' -- pg_restore --list')
    value=$(cat)
    case "$value" in PGDMP_fixture) exit 0 ;; *) exit 1 ;; esac ;;
  *) echo "unexpected kubectl invocation: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH" TEST_ROOT="$root"
for CASE in absent stale existing dump-fail yaml-fail ambiguous corrupt no-path multiple-path; do
  export CASE
  rm -rf "$root/dumps"
  : > "$root/calls"
  mkdir -p "$root/dumps/older"
  printf 'older sentinel' > "$root/dumps/older/old.backup"
  printf 'older spec' > "$root/dumps/older/old.backup.yaml"
  _bk="Backup file (on this host): $root/dumps/current/current-20261002-010000.backup"
  case "$CASE" in
    existing|corrupt)
      mkdir -p "$root/dumps/current"
      printf 'kind: Battlegroup' > "$root/dumps/current/current-20261002-010000.backup.yaml"
      if [ "$CASE" = existing ]; then printf PGDMP_fixture; else printf corrupt; fi > "$root/dumps/current/current-20261002-010000.backup" ;;
    no-path) _bk='No backup path reported' ;;
    multiple-path) _bk="$_bk
Backup file (on this host): $root/dumps/current/another.backup" ;;
  esac
  rc=0
  ( . "$root/verify.sh" ) > "$root/output" 2>&1 || rc=$?
  case "$CASE" in
    absent|stale|existing)
      [ "$rc" = 0 ] || { cat "$root/output"; exit 1; }
      [ "$(cat "$root/dumps/current/current-20261002-010000.backup")" = PGDMP_fixture ]
      test -s "$root/dumps/current/current-20261002-010000.backup.yaml" ;;
    *) [ "$rc" != 0 ] || { echo "$CASE falsely succeeded"; exit 1; } ;;
  esac
  [ "$(cat "$root/dumps/older/old.backup")" = 'older sentinel' ]
  if [ "$CASE" = existing ] || [ "$CASE" = corrupt ] || [ "$CASE" = ambiguous ] || [ "$CASE" = no-path ] || [ "$CASE" = multiple-path ]; then test ! -s "$root/calls"; fi
  if [ "$CASE" = dump-fail ]; then test ! -e "$root/dumps/current/current-20261002-010000.backup"; fi
  if [ "$CASE" = corrupt ]; then [ "$(cat "$root/dumps/current/current-20261002-010000.backup")" = corrupt ]; fi
  echo "$CASE passed"
done
