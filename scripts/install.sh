#!/bin/sh
# Installs or updates imtiredofthis in /Applications from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/yekta/imtiredofthis/main/scripts/install.sh | sh
#
set -eu

APP="/Applications/imtiredofthis.app"
ZIP_URL="https://github.com/yekta/imtiredofthis/releases/latest/download/imtiredofthis.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading imtiredofthis…"
curl -fsSL "$ZIP_URL" -o "$TMP/imtiredofthis.zip"
ditto -x -k "$TMP/imtiredofthis.zip" "$TMP"

killall imtiredofthis 2>/dev/null || true
rm -rf "$APP"
mv "$TMP/imtiredofthis.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "Installed in /Applications. Opening it…"
open "$APP"
