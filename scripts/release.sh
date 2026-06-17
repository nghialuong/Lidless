#!/bin/bash
# Lidless release pipeline: archive → Developer ID export → notarize → DMG.
# Run on a Mac that has the Developer ID Application certificate + a notarytool
# keychain profile. Headless CI can't do this (no certs), so it's a manual step.
#
# Prereqs (one-time):
#   xcrun notarytool store-credentials lidless-notary \
#       --apple-id "you@example.com" --team-id TAFDRXJZSR --password <app-specific-pw>
#
# Usage:
#   ./scripts/release.sh                  # uses keychain profile "lidless-notary"
#   NOTARY_PROFILE=myprofile ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Lidless"
APP_NAME="Lidless"
BUILD="build/release"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
NOTARY_PROFILE="${NOTARY_PROFILE:-lidless-notary}"

command -v xcodegen >/dev/null || { echo "need xcodegen (brew install xcodegen)"; exit 1; }

echo "→ [1/5] generate project"
xcodegen generate

echo "→ [2/5] archive (Developer ID signed)"
rm -rf "$BUILD"
xcodebuild archive \
    -scheme "$SCHEME" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -configuration Release

echo "→ [3/5] export"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist ExportOptions.plist

APP="$EXPORT/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$BUILD/${APP_NAME}-${VERSION}.dmg"

# Notarize + staple the APP first, so the copy that ends up in the DMG carries
# its own stapled ticket (works even offline, dragged to /Applications).
echo "→ [4/6] notarize app"
ZIP="$BUILD/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "→ [5/6] staple app"
xcrun stapler staple "$APP"

echo "→ [6/6] build DMG ($DMG) from the stapled app"
STAGING="$BUILD/dmg"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "✓ Released: $DMG (v$VERSION) — app is notarized + stapled."
