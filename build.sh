#!/bin/bash
# Builds "Split.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="Split.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# One app for both kinds of Mac. Each Mac runs its own half, so Apple Silicon runs natively.
swiftc -O -swift-version 5 -target arm64-apple-macos13 Sources/*.swift -o "$WORK/Split-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macos13 Sources/*.swift -o "$WORK/Split-x86_64"
lipo -create "$WORK/Split-arm64" "$WORK/Split-x86_64" -output "$APP/Contents/MacOS/Split"

swiftc -swift-version 5 Tools/makeicon.swift -o "$WORK/makeicon"
"$WORK/makeicon" "$WORK/icon.png"
mkdir "$WORK/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/icon.png" --out "$WORK/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Split</string>
  <key>CFBundleDisplayName</key><string>Split</string>
  <key>CFBundleIdentifier</key><string>local.essaysplits</string>
  <key>CFBundleExecutable</key><string>Split</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
