#!/usr/bin/env bash
# Builds build/ProfileSlide.app (background app, ad-hoc signed).
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)"
APP=build/ProfileSlide.app
MACOS_MIN_VERSION=26.0
APP_VERSION=$(plutil -extract version raw version.json)
BUILD_NUMBER=$(plutil -extract build raw version.json)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
swiftc -O -module-cache-path build/module-cache -target "$(uname -m)-apple-macosx${MACOS_MIN_VERSION}" Sources/*.swift -o "$APP/Contents/MacOS/ProfileSlide"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.profileslide</string>
  <key>CFBundleName</key><string>ProfileSlide</string>
  <key>CFBundleDisplayName</key><string>ProfileSlide</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ProfileSlide</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${APP_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>${MACOS_MIN_VERSION}</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Reads the tabs open in each Chrome profile so a profile can reopen with them.</string>
</dict>
</plist>
PLIST
BUNDLE_MIN=$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")
BINARY_MIN=$(xcrun vtool -show-build "$APP/Contents/MacOS/ProfileSlide" | awk '$1 == "minos" {print $2}')
if [[ "$BINARY_MIN" != "$BUNDLE_MIN" ]]; then
  echo "Deployment target mismatch: executable $BINARY_MIN, bundle $BUNDLE_MIN" >&2
  exit 1
fi
# A stable identity keeps the Accessibility grant across rebuilds (ad-hoc
# signatures change every build, so macOS forgets the grant).
SUPPORT="$HOME/Library/Application Support"
# Carry settings and the signing identity over from the old app name.
if [ -d "$SUPPORT/ChromeProfileSwipe" ] && [ ! -e "$SUPPORT/ProfileSlide" ]; then
  mv "$SUPPORT/ChromeProfileSwipe" "$SUPPORT/ProfileSlide"
fi
KC="$SUPPORT/ProfileSlide/signing/signing.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p cps "$KC"
  # codesign only finds identities in the search list; add ours for this build.
  ORIG_KCS=$(security list-keychains -d user | tr -d '"')
  security list-keychains -d user -s $ORIG_KCS "$KC"
  trap 'security list-keychains -d user -s $ORIG_KCS' EXIT
  # The certificate keeps the name it was created with under the old app name.
  CERT_SHA1=$(security find-certificate -c "ChromeProfileSwipe Local Signing" -Z "$KC" | awk '/SHA-1/ {print $3}')
  codesign --force --keychain "$KC" -s "ChromeProfileSwipe Local Signing" \
    -r="designated => identifier \"io.github.profileslide\" and certificate leaf = H\"$CERT_SHA1\"" "$APP"
else
  codesign --force -s - "$APP"
fi
echo "built $APP"
