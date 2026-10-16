#!/usr/bin/env bash
# Builds NotchBuddy.app into ./build. Signs with $NB_SIGN_IDENTITY, else the first
# "Developer ID Application" / "Apple Development" identity found, else ad-hoc.
# A stable identity matters: macOS ties the Accessibility grant to the signature, so
# ad-hoc builds need re-approval after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
APP="build/NotchBuddy.app"

swift build -c "$CONFIG" --product NotchBuddy
BIN="$(swift build -c "$CONFIG" --show-bin-path)/NotchBuddy"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NotchBuddy"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset
  swift scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${NB_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning | grep -Eo '"(Developer ID Application|Apple Development)[^"]*"' | head -1 | tr -d '"' || true)"
fi
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --entitlements Resources/NotchBuddy.entitlements --sign "$IDENTITY" "$APP"
else
  echo "No signing identity found; signing ad-hoc (Accessibility must be re-granted after each rebuild)."
  codesign --force --options runtime --entitlements Resources/NotchBuddy.entitlements --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP"
