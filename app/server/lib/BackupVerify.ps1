# Shared manual/scheduled verifier. _bk must contain this run's CLI output.
function New-DuneBackupVerifyScript {
    param([int]$DbPort = 15432)
    if ($DbPort -lt 1 -or $DbPort -gt 65535) { throw 'Invalid database port' }
    # pg_restore reads only the catalog. Drain the rest so kubectl can close stdin.
    # Keep shell comments out of the payload, which is flattened into one cron line.
    $shell = @'
_paths=$(printf '%s\n' "$_bk" | sed -n 's/^Backup file (on this host): //p' | tr -d '\r' | sort -u);
if [ "$(printf '%s\n' "$_paths" | grep -c .)" != 1 ] || ! printf '%s\n' "$_paths" | grep -Eq '^/funcom/artifacts/database-dumps/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+\.backup$'; then echo '[dst] backup verification FAILED: no unique current backup path'; false;
else
_bf=$_paths; _dir=$(dirname "$_bf"); _bg=$(basename "$_dir"); _ns=funcom-seabass-$_bg;
_pods=$(sudo kubectl get pods -n "$_ns" --no-headers 2>/dev/null | awk -v bg="$_bg" '$1 ~ ("^" bg "-db-dbdepl-sts-[0-9]+$") && $3 == "Running" {print $1}');
if [ "$(printf '%s\n' "$_pods" | grep -c .)" != 1 ]; then echo '[dst] backup verification FAILED: no unique running DB pod for current battlegroup'; false;
else
_pn=$_pods; _ok=1;
_dst_archive_readable() {
(set -o pipefail; sudo cat "$1" | sudo timeout 60 kubectl exec -i -n "$_ns" "$_pn" -- sh -c 'pg_restore --list >/dev/null; _rc=$?; cat >/dev/null; exit "$_rc"');
};
sudo mkdir -p "$_dir" || _ok=0;
if [ "$_ok" = 1 ] && ! sudo test -s "$_bf.yaml"; then
_yt=$(sudo mktemp "$_dir/.dst-spec-XXXXXX") || _ok=0;
if [ "$_ok" = 1 ]; then
if sudo sh -c 'kubectl get battlegroup "$1" -n "$2" -o yaml > "$3"' sh "$_bg" "$_ns" "$_yt" && sudo test -s "$_yt"; then sudo mv "$_yt" "$_bf.yaml" || _ok=0; else _ok=0; sudo rm -f "$_yt"; fi;
fi;
fi;
if [ "$_ok" = 1 ] && ! sudo test -s "$_bf"; then
_dt=$(sudo mktemp "$_dir/.dst-dump-XXXXXX") || _ok=0;
if [ "$_ok" = 1 ]; then
if sudo sh -c 'timeout 600 kubectl exec -n "$1" "$2" -- pg_dump -U dune -d dune -p __DBPORT__ -F custom --no-owner > "$3"' sh "$_ns" "$_pn" "$_dt" && sudo test -s "$_dt" && _dst_archive_readable "$_dt"; then sudo mv -n "$_dt" "$_bf" || _ok=0; else _ok=0; fi;
sudo rm -f "$_dt";
fi;
fi;
if [ "$_ok" = 1 ] && sudo test -s "$_bf.yaml" && _dst_archive_readable "$_bf"; then echo "[dst] current backup archive verified readable: $_bf"; else echo "[dst] backup verification FAILED: $_bf (archive or matching spec unavailable/unreadable; verification timeout 60s)"; false; fi;
fi;
fi
'@
    # A cron command is one line; escape percent at the cron serialization boundary.
    return (($shell -replace '__DBPORT__', $DbPort) -replace "`r", '')
}
