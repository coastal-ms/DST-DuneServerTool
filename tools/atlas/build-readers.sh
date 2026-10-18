#!/bin/sh
# Rebuild owned static Linux x86_64 readers with GNU binutils; no guest compiler.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../../app/tools/DuneAtlas" && pwd)
work=$(mktemp -d)
trap 'rm -f "$work/scan.o" "$work/scan" "$work/bulk.o" "$work/bulk"; rmdir "$work"' EXIT HUP INT TERM
for entry in scan:reader bulk:bulk-reader; do
    name=${entry%%:*}; source=${entry#*:}
    as --64 "$root/$source.s" -o "$work/$name.o"
    ld -s --build-id=none "$work/$name.o" -o "$work/$name"
    base64 -w 0 "$work/$name" > "$root/reader-$name.b64"
    printf '\n' >> "$root/reader-$name.b64"
    sha256sum "$work/$name"
done
