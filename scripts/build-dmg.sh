#!/bin/bash
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./scripts/build-app.sh "$VERSION"

DMG="build/CAESURA-ISLAND-${VERSION}.dmg"
rm -f "$DMG"
create-dmg \
  --volname "CAESURA-ISLAND" \
  --volicon "build/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 660 425 \
  --icon-size 120 \
  --icon "CAESURA-ISLAND.app" 170 205 \
  --app-drop-link 490 205 \
  --hide-extension "CAESURA-ISLAND.app" \
  --no-internet-enable \
  "$DMG" \
  "build/CAESURA-ISLAND.app"

echo "==> Done: $DMG"
