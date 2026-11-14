#!/bin/sh
# Builds Zetty for everyday use and for the isolated test app: signed with the
# Developer ID certificate in the keychain, hardened runtime, no debugger
# entitlement. That is the same identity a release carries, so macOS keeps
# Zetty's privacy grants (Screen Recording, folder access) and the Keychain
# "Always Allow" for its Tailscale sign-in from one build to the next. An
# ad-hoc build is a new app to macOS every time, and loses all of them.
#
# Without the certificate (a contributor's Mac) it builds ad-hoc and says so.
# ZETTY_SIGN_IDENTITY picks the identity (name or SHA-1 hash); ZETTY_ADHOC=1
# forces ad-hoc.
#
# Usage:
#   scripts/build.sh                              Debug, into Xcode's DerivedData
#   scripts/build.sh -configuration Release -derivedDataPath build
#                                                 extra arguments go to xcodebuild
set -eu
cd "$(dirname "$0")/.."
. scripts/signing-identity.sh

if [ "${ZETTY_ADHOC:-}" != 1 ] && resolve_sign_identity; then
  echo "build: signing with the Developer ID certificate"
  set -- CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    OTHER_CODE_SIGN_FLAGS=--timestamp=none "$@"
else
  reason=${SIGN_IDENTITY_ERROR:-ZETTY_ADHOC=1}
  echo "build: $reason; building ad-hoc signed. macOS will treat this build as a new app and ask for its permissions and Keychain access again." >&2
fi
exec xcodebuild -project zetty.xcodeproj -scheme zetty -destination 'platform=macOS' "$@" build
