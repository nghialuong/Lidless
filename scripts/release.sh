#!/bin/bash
# Lidless release pipeline: archive → Developer ID export → notarize → DMG →
# Sparkle appcast (EdDSA-signed) → publish to GitHub Releases + Pages.
# Run on a Mac that has the Developer ID Application certificate, a notarytool
# keychain profile, and the Sparkle EdDSA private key in the login keychain.
# Headless CI can't do this (no certs / no signing key), so it's a manual step.
#
# Prereqs (one-time):
#   xcrun notarytool store-credentials lidless-notary \
#       --apple-id "you@example.com" --team-id TAFDRXJZSR --password <app-specific-pw>
#   # Sparkle signing key (prints the base64 public key for Info.plist SUPublicEDKey):
#   "$(./scripts/release.sh --print-sparkle-tool generate_keys)"   # or run generate_keys directly
#
# Usage:
#   ./scripts/release.sh                  # uses keychain profile "lidless-notary"
#   NOTARY_PROFILE=myprofile ./scripts/release.sh
#   PUBLISH=0 ./scripts/release.sh        # build appcast locally but skip gh/Pages publish
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="Lidless"
APP_NAME="Lidless"
BUILD="build/release"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
NOTARY_PROFILE="${NOTARY_PROFILE:-lidless-notary}"
PUBLISH="${PUBLISH:-1}"

# Signing workspace: generate_appcast scans this directory and (re)writes
# appcast.xml covering every release archive present. Kept out of git (DMGs are
# large and live on GitHub Releases); only the resulting appcast.xml is published.
UPDATES_DIR="updates"
APPCAST="$UPDATES_DIR/appcast.xml"
# Where GitHub Pages serves the feed from. docs/ on the default branch is served
# at https://<user>.github.io/<repo>/, matching SUFeedURL .../Lidless/appcast.xml.
PAGES_APPCAST="docs/appcast.xml"
# Stable base URL the appcast enclosures point at (GitHub Release asset downloads).
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/nghialuong/Lidless/releases/latest/download}"

command -v xcodegen >/dev/null || { echo "need xcodegen (brew install xcodegen)"; exit 1; }

# --- Resolve a Sparkle CLI tool (generate_appcast / generate_keys / sign_update) ---
# Tries the SPM artifact cache (DerivedData), a vendored bin/, then the Homebrew
# cask. Echoes the absolute path or exits non-zero.
sparkle_tool() {
    local name="$1" hit
    hit=$(find ~/Library/Developer/Xcode/DerivedData -type f -name "$name" -path '*/artifacts/sparkle/Sparkle/bin/*' 2>/dev/null | head -n1 || true)
    [ -n "$hit" ] || hit=$(find . -type f -name "$name" -path '*/bin/*' 2>/dev/null | head -n1 || true)
    [ -n "$hit" ] || { [ -x "/Applications/Sparkle.app/Contents/MacOS/$name" ] && hit="/Applications/Sparkle.app/Contents/MacOS/$name"; }
    [ -n "$hit" ] || hit=$(command -v "$name" 2>/dev/null || true)
    [ -n "$hit" ] || { echo "could not find Sparkle tool '$name' (build once so SPM resolves it, vendor bin/, or 'brew install --cask sparkle')" >&2; return 1; }
    echo "$hit"
}

# Escape hatch: `./scripts/release.sh --print-sparkle-tool generate_keys`
if [ "${1:-}" = "--print-sparkle-tool" ]; then sparkle_tool "${2:?tool name}"; exit 0; fi

# Monotonic build number for CFBundleVersion. Sparkle orders releases by it, so it
# must strictly increase across releases. Commit count is monotonic on a linear
# history; override with BUILD_NUMBER=… if your history isn't linear.
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"

# Guard: refuse to ship a build number that isn't greater than the last shipped
# one (read from the committed, published feed — the durable source of truth).
if [ -f "$PAGES_APPCAST" ]; then
    LAST=$(/usr/bin/sed -n 's/.*sparkle:version="\([0-9][0-9]*\)".*/\1/p' "$PAGES_APPCAST" | sort -n | tail -n1)
    if [ -n "${LAST:-}" ] && [ "$BUILD_NUMBER" -le "$LAST" ]; then
        echo "✗ BUILD_NUMBER ($BUILD_NUMBER) must be > last shipped sparkle:version ($LAST). Override with BUILD_NUMBER=…" >&2
        exit 1
    fi
fi

echo "→ [1/7] generate project"
xcodegen generate

echo "→ [2/7] archive (Developer ID signed, build $BUILD_NUMBER)"
rm -rf "$BUILD"
xcodebuild archive \
    -scheme "$SCHEME" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -configuration Release \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

echo "→ [3/7] export"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist ExportOptions.plist

APP="$EXPORT/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="$BUILD/${APP_NAME}-${VERSION}.dmg"

# Notarize + staple the APP first, so the copy that ends up in the DMG carries
# its own stapled ticket (works even offline, dragged to /Applications).
echo "→ [4/7] notarize app"
ZIP="$BUILD/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "→ [5/7] staple app"
xcrun stapler staple "$APP"

echo "→ [6/7] build DMG ($DMG) from the stapled app"
STAGING="$BUILD/dmg"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

echo "→ [7/7] sign + generate Sparkle appcast"
GENERATE_APPCAST=$(sparkle_tool generate_appcast)
mkdir -p "$UPDATES_DIR"
cp "$DMG" "$UPDATES_DIR/"
# Sign every archive in UPDATES_DIR with the keychain private key and (re)write
# the appcast. --download-url-prefix points enclosures at the GitHub Release asset.
# Note: only archives still present in UPDATES_DIR are kept in the feed; on a
# fresh checkout this yields a latest-only feed, which Sparkle handles fine.
"$GENERATE_APPCAST" --download-url-prefix "$DOWNLOAD_URL_PREFIX/" "$UPDATES_DIR"
mkdir -p "$(dirname "$PAGES_APPCAST")"
cp "$APPCAST" "$PAGES_APPCAST"

echo "✓ Released: $DMG (v$VERSION, build $BUILD_NUMBER) — notarized + stapled; feed copied to $PAGES_APPCAST."

if [ "$PUBLISH" = "1" ]; then
    command -v gh >/dev/null || { echo "skip publish: need gh (brew install gh)"; exit 0; }
    TAG="v${VERSION}"
    echo "→ publish: GitHub Release $TAG (DMG asset) + appcast on Pages"
    # Create the release if absent, then upload the DMG (clobber to allow re-runs).
    gh release view "$TAG" >/dev/null 2>&1 || gh release create "$TAG" --title "$TAG" --notes "Lidless $VERSION (build $BUILD_NUMBER)"
    gh release upload "$TAG" "$DMG" --clobber
    echo "→ commit + push the published feed so GitHub Pages serves it at SUFeedURL:"
    echo "  git add $PAGES_APPCAST && git commit -m \"appcast: $VERSION (build $BUILD_NUMBER)\" && git push"
fi
