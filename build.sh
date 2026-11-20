#!/usr/bin/env bash
# Builds build/ChromeProfileSwipe.app (background app, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ChromeProfileSwipe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/ChromeProfileSwipe"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.chrome-profile-swipe</string>
  <key>CFBundleName</key><string>ChromeProfileSwipe</string>
  <key>CFBundleDisplayName</key><string>Chrome Profile Swipe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ChromeProfileSwipe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# A stable identity keeps the Accessibility grant across rebuilds (ad-hoc
# signatures change every build, so macOS forgets the grant).
KC="$HOME/Library/Application Support/ChromeProfileSwipe/signing/signing.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p cps "$KC"
  # codesign only finds identities in the search list; add ours for this build.
  ORIG_KCS=$(security list-keychains -d user | tr -d '"')
  security list-keychains -d user -s $ORIG_KCS "$KC"
  trap 'security list-keychains -d user -s $ORIG_KCS' EXIT
  CERT_SHA1=$(security find-certificate -c "ChromeProfileSwipe Local Signing" -Z "$KC" | awk '/SHA-1/ {print $3}')
  codesign --force --keychain "$KC" -s "ChromeProfileSwipe Local Signing" \
    -r="designated => identifier \"io.github.chrome-profile-swipe\" and certificate leaf = H\"$CERT_SHA1\"" "$APP"
else
  codesign --force -s - "$APP"
fi
echo "built $APP"
