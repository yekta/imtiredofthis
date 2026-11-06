#!/bin/sh
# Installs or updates Routey in /Applications from the latest GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/yekta/routey/main/scripts/install.sh | sh
#
set -eu

APP="/Applications/Routey.app"
ZIP_URL="https://github.com/yekta/routey/releases/latest/download/Routey.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Downloading Routey…"
curl -fsSL "$ZIP_URL" -o "$TMP/Routey.zip"
ditto -x -k "$TMP/Routey.zip" "$TMP"

killall Routey 2>/dev/null || true
rm -rf "$APP"
mv "$TMP/Routey.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "Installed in /Applications. Opening it…"
open "$APP"
