#!/bin/sh
# Regenerates resources/AppIcon.icns from the orb renderer.
set -e
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
clang -fobjc-arc -framework Cocoa -I src scripts/make_icon.m src/orb.m -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o resources/AppIcon.icns
rm -rf "$TMP"
echo "Wrote resources/AppIcon.icns"
