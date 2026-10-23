#!/bin/zsh
# Builds a Release Shiftio.app and packs it: dist/Shiftio.zip by default, plus dist/Shiftio.dmg with --dmg.
# The app downloads its extras (MP3 encoder, speech model) itself the first time it opens.
#
#   scripts/package-dmg.sh [--dmg]                 ad-hoc signed, runs on this Mac only
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/package-dmg.sh
#   ... plus NOTARY_PROFILE=<notarytool keychain profile> to notarize and staple
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD="${BUILD_DIR:-${TMPDIR:-/tmp}/shiftio-release}"
IDENTITY="${SIGN_IDENTITY:--}"

xcodegen generate >/dev/null
xcodebuild -scheme Shiftio -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$BUILD" CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual build | tail -1

APP="$BUILD/Build/Products/Release/Shiftio.app"
codesign --verify --deep --strict "$APP"

mkdir -p dist
rm -f dist/Shiftio.zip
ditto -c -k --keepParent "$APP" dist/Shiftio.zip
echo "dist/Shiftio.zip ($(du -h dist/Shiftio.zip | cut -f1))"
[[ "${1:-}" == "--dmg" ]] || exit 0

mkdir -p dist
scripts/make-dmg.sh "$APP" dist/Shiftio.dmg

if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp dist/Shiftio.dmg
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit dist/Shiftio.dmg --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple dist/Shiftio.dmg
  fi
fi
echo "dist/Shiftio.dmg ($(du -h dist/Shiftio.dmg | cut -f1))"
