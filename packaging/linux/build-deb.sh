#!/usr/bin/env bash
# Build a .deb for Dune Server (Linux). Run on a Debian/Ubuntu host with
# `dpkg-deb` and `npm` installed:
#
#     ./packaging/linux/build-deb.sh
#
# Output: ./packaging/linux/output/dune-server_<version>_all.deb
#
# Layout produced inside the .deb:
#   /opt/dune-server/
#       app/                       (PowerShell backend + entry)
#       webui/dist/                (built React SPA)
#       bin/dune-server            (launcher)
#       packaging/linux/systemd/   (the user unit template, copied for refs)
#       LINUX-PORT-STATUS.md
#       README.md
#       LICENSE
#       CHANGELOG.md
#   /usr/bin/dune-server -> /opt/dune-server/bin/dune-server   (symlink)
#
# This script does NOT build the Windows installer or DuneShell — those stay
# in app/build and app/installer for the Windows release path.
#
# Status: UNTESTED handoff scaffold. See LINUX-PORT-STATUS.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGING_DIR="$REPO_ROOT/packaging/linux"
OUTPUT_DIR="$PACKAGING_DIR/output"
DEBIAN_TEMPLATE="$PACKAGING_DIR/debian"

# ---------- Version from debian/control ---------------------------------------
VERSION="$(awk -F': ' '/^Version:/ { print $2; exit }' "$DEBIAN_TEMPLATE/control")"
if [ -z "$VERSION" ]; then
    echo "build-deb: could not read Version from $DEBIAN_TEMPLATE/control" >&2
    exit 1
fi
echo "build-deb: building dune-server v$VERSION"

# ---------- Build the web UI --------------------------------------------------
if [ ! -d "$REPO_ROOT/webui/dist" ] || [ "${REBUILD_WEBUI:-1}" = "1" ]; then
    echo "build-deb: building webui/ (set REBUILD_WEBUI=0 to skip)"
    pushd "$REPO_ROOT/webui" >/dev/null
    if [ ! -d node_modules ]; then npm ci; fi
    npm run build
    popd >/dev/null
fi
if [ ! -f "$REPO_ROOT/webui/dist/index.html" ]; then
    echo "build-deb: webui/dist/index.html missing after build" >&2
    exit 1
fi

# ---------- Stage payload -----------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

INSTALL_PREFIX="$STAGE/opt/dune-server"
mkdir -p "$INSTALL_PREFIX/app" \
         "$INSTALL_PREFIX/webui" \
         "$INSTALL_PREFIX/bin" \
         "$INSTALL_PREFIX/packaging/linux/systemd" \
         "$STAGE/usr/bin" \
         "$STAGE/DEBIAN"

# Backend (PowerShell + assets). Exclude the Windows-only build/ and
# installer/ directories, the WinForms shell, and any stray bin/obj output.
cp -r "$REPO_ROOT/app/server"   "$INSTALL_PREFIX/app/"
cp -r "$REPO_ROOT/app/lib"      "$INSTALL_PREFIX/app/" 2>/dev/null || true
cp -r "$REPO_ROOT/app/assets"   "$INSTALL_PREFIX/app/" 2>/dev/null || true
cp    "$REPO_ROOT/app/DuneServer-Linux.ps1" "$INSTALL_PREFIX/app/"
cp    "$REPO_ROOT/dune-server.ps1"          "$INSTALL_PREFIX/"

# Web UI
cp -r "$REPO_ROOT/webui/dist"  "$INSTALL_PREFIX/webui/"

# Launcher + systemd unit (reference copy)
cp    "$REPO_ROOT/bin/dune-server"                              "$INSTALL_PREFIX/bin/"
cp    "$PACKAGING_DIR/systemd/dune-server.service"              "$INSTALL_PREFIX/packaging/linux/systemd/"

# Top-level docs
for f in LINUX-PORT-STATUS.md README.md LICENSE CHANGELOG.md; do
    if [ -f "$REPO_ROOT/$f" ]; then cp "$REPO_ROOT/$f" "$INSTALL_PREFIX/"; fi
done

# Symlink in /usr/bin
ln -s /opt/dune-server/bin/dune-server "$STAGE/usr/bin/dune-server"

# Permissions
chmod 0755 "$INSTALL_PREFIX/bin/dune-server"
find "$INSTALL_PREFIX/app" -name '*.ps1' -exec chmod 0644 {} \;
chmod 0755 "$INSTALL_PREFIX/app/DuneServer-Linux.ps1"

# ---------- DEBIAN/ metadata --------------------------------------------------
cp "$DEBIAN_TEMPLATE/control"  "$STAGE/DEBIAN/control"
cp "$DEBIAN_TEMPLATE/postinst" "$STAGE/DEBIAN/postinst"
cp "$DEBIAN_TEMPLATE/prerm"    "$STAGE/DEBIAN/prerm"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

# ---------- Build the .deb ----------------------------------------------------
mkdir -p "$OUTPUT_DIR"
DEB_FILE="$OUTPUT_DIR/dune-server_${VERSION}_all.deb"
rm -f "$DEB_FILE"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB_FILE"

echo ""
echo "build-deb: wrote $DEB_FILE"
echo "build-deb: install with:  sudo apt install $DEB_FILE"
