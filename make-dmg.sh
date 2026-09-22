#!/bin/bash
# Builds Wink.app and packages it as build/Wink-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
DMG="build/Wink-$VERSION.dmg"
STAGE=build/dmg

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Wink.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Wink $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
