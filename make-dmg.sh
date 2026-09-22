#!/bin/bash
# Builds Wink.app and packages it as build/Wink-<version>.dmg.
#
# With a "Developer ID Application" certificate in the keychain, the app is
# signed (hardened runtime) and notarized, and the ticket is stapled, so it
# opens without Gatekeeper warnings. Notarization uses a notarytool keychain
# profile if one exists (NOTARY_PROFILE, default "wink-notary"; that also
# signs and notarizes the DMG itself), and otherwise the account signed in
# to Xcode (the DMG then stays unsigned; the app inside is what's checked).
#
# Optional one-time setup of the profile:
#   xcrun notarytool store-credentials wink-notary --apple-id <you> --team-id <TEAMID>
set -euo pipefail
cd "$(dirname "$0")"

NOTARY_PROFILE=${NOTARY_PROFILE:-wink-notary}
IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
TEAM=$(sed -n 's/.*(\([A-Z0-9]*\))$/\1/p' <<<"$IDENTITY")

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Info.plist)
DMG="build/Wink-$VERSION.dmg"
APP=build/Wink.app

has_profile() { xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; }

# Notarizes $APP through Xcode's signed-in account and replaces it with the
# stapled copy Apple returns.
notarize_with_xcode() {
  local archive=build/Wink.xcarchive
  rm -rf "$archive" build/export build/notarized
  mkdir -p "$archive/Products/Applications"
  cp -R "$APP" "$archive/Products/Applications/"
  cat > "$archive/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>ApplicationProperties</key><dict>
    <key>ApplicationPath</key><string>Applications/Wink.app</string>
    <key>CFBundleIdentifier</key><string>sh.wink.Wink</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>SigningIdentity</key><string>$IDENTITY</string>
    <key>Team</key><string>$TEAM</string>
  </dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>Wink</string>
  <key>SchemeName</key><string>Wink</string>
</dict></plist>
EOF
  cat > build/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>destination</key><string>upload</string>
</dict></plist>
EOF
  echo "Uploading to Apple's notary service via Xcode..."
  xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist build/export.plist \
    -exportPath build/export -allowProvisioningUpdates >build/notarize.log 2>&1 \
    || { tail -5 build/notarize.log; exit 1; }
  echo "Waiting for notarization (usually a few minutes)..."
  for _ in $(seq 1 60); do
    if xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath build/notarized >>build/notarize.log 2>&1; then
      rm -rf "$APP" && cp -R build/notarized/Wink.app "$APP"
      xcrun stapler validate "$APP"
      return
    fi
    sleep 30
  done
  echo "Notarization didn't finish in 30 minutes; see build/notarize.log" >&2
  exit 1
}

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=1 "$APP"
  if ! has_profile; then notarize_with_xcode; fi
else
  echo "No Developer ID Application certificate found; app stays ad-hoc signed."
fi

STAGE=build/dmg
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Wink $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "$IDENTITY" ]]; then
  # Gatekeeper rejects a signed-but-unnotarized disk image, so only sign the
  # DMG when it can be notarized too. Otherwise it stays unsigned and
  # Gatekeeper checks the notarized, stapled app inside when it launches.
  if has_profile; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    echo "Notarizing DMG (usually a few minutes)..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
  spctl --assess --type execute --verbose=2 "$APP"
fi

echo "Built $DMG"
