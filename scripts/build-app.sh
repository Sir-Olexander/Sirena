#!/bin/bash
# Builds Sirena with SwiftPM and assembles a signed Sirena.app bundle in ./build.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Sirena.app"

echo "▸ swift build ($CONFIG)"
# Per-file optimization: the whole-module optimizer of Swift 6.2 hangs on this code base.
EXTRA=()
[ "$CONFIG" = "release" ] && EXTRA=(-Xswiftc -no-whole-module-optimization)
swift build -c "$CONFIG" --product Sirena "${EXTRA[@]}" 2>&1 | grep -Ev '^\[|^Compiling|^Build complete|^Fetching|^Creating' || true
BIN=".build/$CONFIG/Sirena"
[ -x "$BIN" ] || { echo "build failed: $BIN missing"; exit 1; }

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sirena"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# Sign with the same identity every time so macOS keeps the permission grants across rebuilds.
IDENTITY="${SIRENA_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E 'Apple Development|Developer ID Application' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)"
fi
if [ -z "$IDENTITY" ]; then
  echo "▸ no signing identity found, using ad-hoc signature (permissions will reset on each rebuild)"
  IDENTITY="-"
else
  echo "▸ signing with: $IDENTITY"
fi
codesign --force --sign "$IDENTITY" --entitlements Resources/Sirena.entitlements --timestamp=none "$APP"
codesign --verify --deep --strict "$APP" && echo "▸ signature OK"
echo "▸ built $APP"
