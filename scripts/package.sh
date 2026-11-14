#!/bin/sh
# Packages Zetty into dist/Zetty-<version>.dmg for distribution: a Release build,
# Developer ID signed with the hardened runtime, notarized and stapled — the app
# first, then the DMG around it — so a downloaded copy opens with no Gatekeeper
# override and no network round-trip for its ticket.
#
# Signing reads nothing from this repo, secret or personal: the identity is the
# one "Developer ID Application" certificate in the keychain, found at run time,
# and notarytool authenticates through a keychain profile (created once with
# `xcrun notarytool store-credentials <profile>`). Override either with
# ZETTY_SIGN_IDENTITY (a name or SHA-1 hash) / ZETTY_NOTARY_PROFILE.
#
# Usage:
#   scripts/package.sh              sign, notarize, staple, verify
#   scripts/package.sh --preflight  only check the identity and notary profile
#   scripts/package.sh --adhoc      ad-hoc signed and NOT notarized: for a
#                                   machine without the certificate; never ship it
set -eu
cd "$(dirname "$0")/.."

SIGN_IDENTITY=
NOTARY_PROFILE=${ZETTY_NOTARY_PROFILE:-notary}

MODE=release
case "${1:-}" in
  "") ;;
  --preflight) MODE=preflight ;;
  --adhoc) MODE=adhoc ;;
  -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: scripts/package.sh [--preflight | --adhoc]" >&2; exit 2 ;;
esac

. scripts/signing-identity.sh

die() { printf '%s\n' "error: $*" >&2; exit 1; }

# Checked before anything builds: release.sh runs this ahead of its version
# bump, so a missing certificate or profile stops it before it pushes.
preflight() {
  resolve_sign_identity || die "$SIGN_IDENTITY_ERROR"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notary keychain profile '$NOTARY_PROFILE' is missing or rejected — run: xcrun notarytool store-credentials $NOTARY_PROFILE"
}

# Submits one file and waits. notarytool exits 0 for an Invalid verdict too, so
# the status is read from its JSON, and a rejection prints Apple's log.
notarize() {
  out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format json) || die "notarytool submit failed for $1"
  id=$(printf '%s' "$out" | plutil -extract id raw -o - -)
  status=$(printf '%s' "$out" | plutil -extract status raw -o - -)
  if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    die "notarization of $1 ended '$status' (submission $id)"
  fi
  echo "notarized $1 ($id)"
}

if [ "$MODE" = preflight ]; then
  preflight
  echo "signing ready: identity $SIGN_IDENTITY, notary profile '$NOTARY_PROFILE'"
  exit 0
fi
if [ "$MODE" = release ]; then preflight; fi

mise exec -- tuist generate --no-open
xcodebuild -project zetty.xcodeproj -scheme zetty -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath build build

APP=build/Build/Products/Release/zetty.app
PLIST="$APP/Contents/Info.plist"

# Every build carries the pinned zmx, and it has to run: a release whose
# helper is missing or broken would leave preserve-sessions with nothing.
ZMX_PIN=$(sed -n 's/^version=//p' scripts/zmx.pin | head -1)
ZMX_GOT=$("$APP/Contents/Helpers/zmx" version 2>/dev/null | awk '$1 == "zmx" { print $2; exit }')
[ "$ZMX_GOT" = "$ZMX_PIN" ] \
  || die "Contents/Helpers/zmx reports '${ZMX_GOT:-nothing}', scripts/zmx.pin says $ZMX_PIN"
lipo "$APP/Contents/Helpers/zmx" -verify_arch arm64 x86_64 \
  || die "Contents/Helpers/zmx is not universal (arm64 + x86_64)"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
COMMIT=$(/usr/libexec/PlistBuddy -c "Print :ZettyBuildCommit" "$PLIST")

if [ "$MODE" = release ]; then
  # Inside out: each nested framework or dylib first, the app last, since the
  # app's seal records the signatures of what it contains. Re-signing without
  # --entitlements also drops Xcode's get-task-allow, which notarization refuses.
  sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }
  for nested in "$APP"/Contents/Frameworks/*; do
    if [ -e "$nested" ]; then sign "$nested"; fi
  done
  # The bundled zmx (session preservation), before the app that seals it.
  sign --identifier co.webteractive.zetty.zmx "$APP/Contents/Helpers/zmx"
  sign "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"

  # The app is notarized and stapled on its own before the DMG is made, so the
  # copy a user drags out carries its ticket — and so does the copy the in-app
  # updater lifts out of the DMG.
  WORK=$(mktemp -d)
  ditto -c -k --keepParent "$APP" "$WORK/zetty.zip"
  notarize "$WORK/zetty.zip"
  rm -rf "$WORK"
  xcrun stapler staple "$APP"
  spctl -a -vvv -t exec "$APP"
fi

STAGE=$(mktemp -d)
ditto "$APP" "$STAGE/zetty.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Zetty-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Zetty $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

if [ "$MODE" = release ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi

# SHA-256 sidecar (bare lowercase hex) — the in-app self-updater verifies the
# download against this. Written LAST: stapling rewrites the DMG. Upload it
# alongside the DMG in the release.
SHA="$DMG.sha256"
shasum -a 256 "$DMG" | awk '{print $1}' > "$SHA"

if [ "$MODE" = adhoc ]; then
  echo "Packaged $DMG + $SHA (version $VERSION, commit $COMMIT) — AD-HOC, not notarized: do not ship"
else
  echo "Packaged $DMG + $SHA (version $VERSION, commit $COMMIT) — Developer ID signed, notarized, stapled"
fi
