#!/bin/bash
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./scripts/build-app.sh "$VERSION"

DMG="build/Aegis-${VERSION}.dmg"
rm -f "$DMG"
create-dmg \
  --volname "Aegis" \
  --volicon "build/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 660 425 \
  --icon-size 120 \
  --icon "Aegis.app" 170 205 \
  --app-drop-link 490 205 \
  --hide-extension "Aegis.app" \
  --no-internet-enable \
  "$DMG" \
  "build/Aegis.app"

echo "==> Done: $DMG"
