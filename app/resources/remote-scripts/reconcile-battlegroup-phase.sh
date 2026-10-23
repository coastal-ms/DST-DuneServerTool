#!/bin/sh
set -eu

# Query a structured field: the human-readable title can contain whitespace.
target=$(readlink -f /home/dune/.dune/bin/battlegroup)
test -f "$target"
temp=$(mktemp "${target}.dst-phase.XXXXXX")
trap 'rm -f "$temp"' EXIT HUP INT TERM
cp -p "$target" "$temp"
awk '
  /^[[:space:]]*phase=\$\(sudo kubectl get battlegroup / && /--no-headers/ && /awk/ {
    print "                phase=$(sudo kubectl get battlegroup \"$bgname\" -n \"$BATTLEGROUP_PREFIX$bgname\" -o jsonpath=\047{.status.phase}\047 2>/dev/null)"
    changed++
    next
  }
  { print }
  END { if (changed > 1) exit 42 }
' "$target" > "$temp"
if ! grep -F 'phase=$(sudo kubectl get battlegroup "$bgname" -n "$BATTLEGROUP_PREFIX$bgname" -o jsonpath=' "$temp" | grep -Fq '{.status.phase}'; then
  echo 'Unsupported battlegroup phase reader; original script left unchanged.' >&2
  exit 1
fi
bash -n "$temp"
if ! cmp -s "$target" "$temp"; then
  digest=$(sha256sum "$target" | cut -d ' ' -f 1)
  backup="${target}.dst-before-phase-${digest}"
  if [ ! -e "$backup" ]; then cp -p "$target" "$backup"; fi
  mv -f "$temp" "$target"
fi
echo DUNE_BATTLEGROUP_PHASE_OK
