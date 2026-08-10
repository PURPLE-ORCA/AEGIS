#!/bin/bash
set -euo pipefail

VERSION="${1:-0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Building CAESURA-ISLAND release binary (v$VERSION)"
swift build -c release

echo "==> Creating app icon"
mkdir -p build
rm -rf build/AppIcon.iconset
mkdir -p build/AppIcon.iconset
sips -s format png Resources/branding/AppIcon.svg --out build/AppIcon-1024.png >/dev/null
for size in 16 32 64 128 256 512; do
  sips -z "$size" "$size" build/AppIcon-1024.png --out "build/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128 256 512; do
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" build/AppIcon-1024.png --out "build/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

echo "==> Assembling app bundle"
APP="build/CAESURA-ISLAND.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp .build/release/CaesuraIsland "$APP/Contents/MacOS/CaesuraIsland"
cp .build/release/CaesuraIslandBridge "$APP/Contents/Helpers/CaesuraIslandBridge"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -d Resources/cli-icons ]; then
  cp -R Resources/cli-icons "$APP/Contents/Resources/cli-icons"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CaesuraIsland</string>
    <key>CFBundleIdentifier</key>
    <string>dev.caesura.island</string>
    <key>CFBundleDisplayName</key>
    <string>CAESURA-ISLAND</string>
    <key>CFBundleName</key>
    <string>CAESURA-ISLAND</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>LSUIElement</key>
    <true/>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "==> Done: $APP"
