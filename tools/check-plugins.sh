#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d /tmp/wink-plugin-checks.XXXXXX)
swiftc Sources/PluginPackage.swift Tests/PluginPackageChecks.swift -o "$CHECK_DIR/packages"
"$CHECK_DIR/packages"
swiftc Sources/PluginPackage.swift Sources/PluginInstaller.swift Tests/PluginInstallerChecks.swift -o "$CHECK_DIR/installer"
"$CHECK_DIR/installer"
swiftc Sources/PluginPackage.swift Sources/PluginInstaller.swift Sources/Plugins.swift Sources/SpotifyService.swift Tests/PluginWebViewChecks/main.swift -o "$CHECK_DIR/webview"
"$CHECK_DIR/webview" "$PWD/Resources/Plugins/org.blink.demo"
swiftc Sources/PluginPackage.swift Sources/SpotifyService.swift Tests/SpotifyChecks.swift -o "$CHECK_DIR/spotify"
"$CHECK_DIR/spotify"
mkdir -p "$CHECK_DIR/SpotifyChecks.app/Contents/MacOS" "$CHECK_DIR/SpotifyChecks.app/Contents/Resources"
cp -R Resources/Plugins "$CHECK_DIR/SpotifyChecks.app/Contents/Resources/"
swiftc Sources/PluginPackage.swift Sources/PluginInstaller.swift Sources/Plugins.swift Sources/SpotifyService.swift Tests/SpotifyWebViewChecks/main.swift -o "$CHECK_DIR/SpotifyChecks.app/Contents/MacOS/SpotifyChecks"
"$CHECK_DIR/SpotifyChecks.app/Contents/MacOS/SpotifyChecks"
echo "Check binaries retained at $CHECK_DIR"
