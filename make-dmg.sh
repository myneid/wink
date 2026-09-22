#!/bin/bash
# Builds Wink.app and packages it as build/Wink-<version>.dmg.
#
# If a "Developer ID Application" certificate is in your keychain, the app and
# DMG are signed with it (hardened runtime). If a notarytool keychain profile
# exists (default name "wink-notary", override with NOTARY_PROFILE), the DMG
# is also notarized and stapled, so it opens without Gatekeeper warnings.
#
# One-time setup of the profile:
#   xcrun notarytool store-credentials wink-notary --apple-id <you> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE=${NOTARY_PROFILE:-wink-notary}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
DMG="build/Wink-$VERSION.dmg"
STAGE=build/dmg

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" build/Wink.app
  codesign --verify --strict --verbose=1 build/Wink.app
else
  echo "No Developer ID Application certificate found; app stays ad-hoc signed."
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Wink.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Wink $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "$IDENTITY" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Notarizing (usually a few minutes)..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  else
    echo "No notarytool profile '$NOTARY_PROFILE'; DMG is signed but not notarized."
  fi
fi

echo "Built $DMG"
