#!/usr/bin/env bash
# Builds dist/Pocket.app and dist/Pocket-macOS.zip without needing Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Pocket"
BUNDLE_ID="local.pocket.daw"
DIST="dist"
APP="$DIST/$APP_NAME.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$APP_NAME</string>
	<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
	<key>CFBundleName</key><string>$APP_NAME</string>
	<key>CFBundleDisplayName</key><string>$APP_NAME</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>LSApplicationCategoryType</key><string>public.app-category.music</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSMicrophoneUsageDescription</key><string>Pocket records audio from the selected input onto an armed track.</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHumanReadableCopyright</key><string>Pocket</string>
</dict>
</plist>
PLIST

# Finder metadata and stale xattrs make codesign refuse the bundle, so strip them first.
find "$DIST" -name '.DS_Store' -delete 2>/dev/null || true
xattr -cr "$APP" 2>/dev/null || true

codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed, app will still run locally"
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 && echo "signature: verified" || echo "warning: signature did not verify"
# Do not use --sequesterRsrc: it reattaches FinderInfo to the .app, which makes strict
# code-signature verification fail after packaging.
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent "$APP" "$DIST/$APP_NAME-macOS.zip"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$APP" >/dev/null 2>&1 && echo "final signature: verified" || echo "warning: final signature did not verify"

echo "app: $APP"
echo "zip: $DIST/$APP_NAME-macOS.zip"
du -sh "$APP" "$DIST/$APP_NAME-macOS.zip"
