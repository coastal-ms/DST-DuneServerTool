# Embedded in dst-daily-maintenance.sh. No credentials are embedded here.
UPDATE_FAILURE=/var/lib/dune-server/daily-update-failure
UPDATE_NOTICE=/var/lib/dune-server/daily-update-failure-notice
UPDATE_NOTICE_CONFIG=/var/lib/dune-server/update-failure-webhook
UPDATE_SOURCE=server-update
UPDATE_CODE=''
UPDATE_ATTEMPT=0

record_update_failure() {
  [ "$UPDATE_ATTEMPT" = 1 ] || return 0
  if [ "$RC" = 0 ]; then
    rm -f "$UPDATE_FAILURE"
    return 0
  fi
  local stamp temporary
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  temporary=$(mktemp "${UPDATE_FAILURE}.XXXXXX") || return 0
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$stamp" "$UPDATE_SOURCE" "$UPDATE_CODE" "$INSTALLED" "$LATEST" "$ACTION" "$RC" > "$temporary"
  mv -f "$temporary" "$UPDATE_FAILURE"
  # The secret is deployed root-only when the operator enables Update notices.
  [ -f "$UPDATE_NOTICE_CONFIG" ] && [ ! -L "$UPDATE_NOTICE_CONFIG" ] || return 0
  local url payload template recovery
  url=$(sed -n '1p' "$UPDATE_NOTICE_CONFIG")
  printf '%s' "$url" | grep -Eq '^https://((canary|ptb)\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$' || return 0
  template=3
  [ "$UPDATE_SOURCE" != steamcmd ] || template=2
  payload=$(sed -n "${template}p" "$UPDATE_NOTICE_CONFIG" | base64 -d) || return 0
  recovery='The server was not automatically restarted; review its current status.'
  case "$ACTION" in
    update-failed-restart-ok) recovery='Server restarted on the previous build.' ;;
    update-failed-restart-failed) recovery='The fallback server restart also failed.' ;;
  esac
  payload=$(printf '%s' "$payload" | sed "s/__TIME__/$stamp/g; s/__CODE__/${UPDATE_CODE:-unknown}/g; s/__INSTALLED__/${INSTALLED:-unknown}/g; s/__LATEST__/${LATEST:-unknown}/g; s/__RECOVERY__/$recovery/g")
  # Record before POST. An uncertain HTTP outcome must not cause duplicate pings.
  printf '%s|attempted\n' "$stamp" > "$UPDATE_NOTICE"
  if wget -q -T 15 --header='Content-Type: application/json' --post-data="$payload" -O /dev/null "${url}?wait=true" 2>/dev/null; then
    printf '%s|sent\n' "$stamp" > "$UPDATE_NOTICE"
  else
    echo '[dst] Update failure webhook delivery was not confirmed; see the saved maintenance result.'
  fi
}
