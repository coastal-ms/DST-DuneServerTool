#!/usr/bin/env bash
set -euo pipefail
for name in WEBSITE_HOST WEBSITE_PORT WEBSITE_USER WEBSITE_ROOT WEBSITE_SSH_KEY WEBSITE_KNOWN_HOSTS; do
  if [[ -z "${!name:-}" ]]; then echo "Missing deployment setting: $name" >&2; exit 1; fi
done
[[ "$WEBSITE_ROOT" == /* && "$WEBSITE_ROOT" != / ]] || { echo 'Expected an absolute hosting directory'; exit 1; }
key_dir=$(mktemp -d)
trap 'rm -rf "$key_dir"' EXIT
printf '%s\n' "$WEBSITE_SSH_KEY" > "$key_dir/key"
printf '%s\n' "$WEBSITE_KNOWN_HOSTS" > "$key_dir/known_hosts"
chmod 600 "$key_dir/key" "$key_dir/known_hosts"
export WEBSITE_DEPLOY_KEY="$key_dir/key" WEBSITE_DEPLOY_HOSTS="$key_dir/known_hosts"
cat > "$key_dir/ssh" <<'SSH'
#!/usr/bin/env bash
exec ssh -i "$WEBSITE_DEPLOY_KEY" -p "$WEBSITE_PORT" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$WEBSITE_DEPLOY_HOSTS" "$@"
SSH
chmod 700 "$key_dir/ssh"
# Assets first; preserve older assets for visitors with cached HTML. No remote deletion.
rsync -rlt --delay-updates --exclude='*.html' -e "$key_dir/ssh" site/dist/ "$WEBSITE_USER@$WEBSITE_HOST:$WEBSITE_ROOT/"
rsync -rlt --delay-updates --include='*/' --include='*.html' --exclude='*' -e "$key_dir/ssh" site/dist/ "$WEBSITE_USER@$WEBSITE_HOST:$WEBSITE_ROOT/"
curl --fail --silent --show-error --retry 3 https://duneservertool.com/install > "$key_dir/install.html"
if [[ -n "${EXPECTED_RELEASE:-}" ]]; then
  grep -F "https://github.com/coastal-ms/DST-DuneServerTool/releases/download/$EXPECTED_RELEASE/DuneServerSetup.exe" "$key_dir/install.html" > /dev/null || { echo 'Live installer link does not match the release'; exit 1; }
fi
echo 'Website upload completed and live install page verified.'
