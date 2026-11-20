#!/usr/bin/env bash
# Builds build/ChromeProfileSwipe.app (background app, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ChromeProfileSwipe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/ChromeProfileSwipe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.chrome-profile-swipe</string>
  <key>CFBundleName</key><string>ChromeProfileSwipe</string>
  <key>CFBundleExecutable</key><string>ChromeProfileSwipe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force -s - "$APP"
echo "built $APP"
