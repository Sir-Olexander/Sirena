#!/bin/bash
# Rebuilds Resources/AppIcon.icns from Resources/Logo.svg. Run after changing the logo.
# Usage: scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "▸ rendering Resources/Logo.svg"
swift scripts/make-icon.swift Resources/Logo.svg "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
echo "▸ wrote Resources/AppIcon.icns"
