#!/bin/sh
# Packages Zetty into dist/Zetty-<version>.dmg for distribution.
#
# The build is ad-hoc signed (no Developer ID yet), so downloaded copies are
# quarantined by Gatekeeper — recipients must run:
#   xattr -d com.apple.quarantine /Applications/zetty.app
# See README "Download" section. Swap in Developer ID signing + notarization
# here when an Apple Developer account is available.
set -eu
cd "$(dirname "$0")/.."

mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build build

APP=build/Build/Products/Release/zetty.app
PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
COMMIT=$(/usr/libexec/PlistBuddy -c "Print :ZettyBuildCommit" "$PLIST")

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/zetty.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Zetty-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Zetty $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# SHA-256 sidecar (bare lowercase hex) — the in-app self-updater verifies the
# download against this. Upload it alongside the DMG in the release.
SHA="$DMG.sha256"
shasum -a 256 "$DMG" | awk '{print $1}' > "$SHA"

echo "Packaged $DMG + $SHA (version $VERSION, commit $COMMIT)"
