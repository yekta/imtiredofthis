#!/usr/bin/env bash
# Prints the version of the commit being built: VERSION's two numbers, and as the third how many
# commits lead up to this one, so that every push to main is a newer version than the last. It
# needs the whole history (`fetch-depth: 0`).
set -euo pipefail
cd "$(dirname "$0")/.."

echo "$(tr -d '[:space:]' < VERSION).$(git rev-list --count HEAD 2>/dev/null || echo 0)"
