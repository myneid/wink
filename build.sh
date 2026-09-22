#!/bin/bash
# Builds Wink.app into ./build. Usage: ./build.sh [--install]
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Wink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

clang -c -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=13.0 Sources/pty.c -o build/obj/pty.o
swiftc -O -swift-version 5 \
  -target arm64-apple-macos13.0 -import-objc-header Sources/pty.h \
  Sources/*.swift build/obj/pty.o -o build/obj/Wink-arm64
swiftc -O -swift-version 5 \
  -target x86_64-apple-macos13.0 -import-objc-header Sources/pty.h \
  Sources/*.swift build/obj/pty.o -o build/obj/Wink-x86_64
lipo -create build/obj/Wink-arm64 build/obj/Wink-x86_64 -output "$APP/Contents/MacOS/Wink"

cp Info.plist "$APP/Contents/"
cp -R Resources/ "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/Wink.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Wink.app"
fi
