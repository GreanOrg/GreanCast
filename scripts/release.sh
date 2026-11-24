#!/bin/bash
# Release build: universal binary, Developer ID signature with hardened runtime and secure
# timestamp, notarization, stapled DMG in dist/. Requires a "Developer ID Application"
# certificate and a notarytool keychain profile, created once with:
#   xcrun notarytool store-credentials greancast --apple-id <apple-id> --team-id <TEAM> --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
NOTARY_PROFILE="${NOTARY_PROFILE:-greancast}"
[ -n "$SIGN_ID" ] || { echo "No 'Developer ID Application' certificate found." >&2; exit 1; }
TEAM_ID="$(echo "$SIGN_ID" | sed -E 's/.*\(([A-Z0-9]{10})\).*/\1/')"

make clean
make CONFIGURATION=Release SIGN_ARGS="CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=\"$SIGN_ID\" DEVELOPMENT_TEAM=$TEAM_ID OTHER_CODE_SIGN_FLAGS=--timestamp" \
  EXTRA_ARGS="ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/GreanCast.app/Contents/Info.plist)"
mkdir -p dist
DMG="dist/GreanCast-$VERSION.dmg"
hdiutil create -volname "GreanCast" -srcfolder build/GreanCast.app -ov -format UDZO "$DMG"
codesign --sign "$SIGN_ID" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
shasum -a 256 "$DMG"
echo "Release ready: $DMG"
