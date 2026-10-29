#!/bin/bash
# Builds HulkBin.app (a menu-bar-only app, no Dock icon of its own).
set -e
cd "$(dirname "$0")"
APP=HulkBin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 HulkBin.swift -o "$APP/Contents/MacOS/HulkBin"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>HulkBin</string>
  <key>CFBundleExecutable</key><string>HulkBin</string>
  <key>CFBundleIdentifier</key><string>dev.afti.hulkbin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
