#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
node Tests/SpotifyDefaultsChecks.cjs
node Tests/SpotifyBrowsingChecks.cjs
CHECK_DIR=$(mktemp -d /tmp/wink-plugin-checks.XXXXXX)
swiftc -D WINK_TESTING Sources/PluginPackage.swift Tests/PluginPackageChecks.swift -o "$CHECK_DIR/packages"
"$CHECK_DIR/packages"
swiftc -D WINK_TESTING Sources/PluginPackage.swift Sources/PluginInstaller.swift Tests/PluginInstallerChecks.swift -o "$CHECK_DIR/installer"
"$CHECK_DIR/installer"
swiftc -D WINK_TESTING Sources/PluginPackage.swift Sources/PluginInstaller.swift Sources/Plugins.swift Sources/SpotifyService.swift Sources/DatabaseWorkbench.swift Tests/PluginWebViewChecks/main.swift -o "$CHECK_DIR/webview"
"$CHECK_DIR/webview" "$PWD/Resources/Plugins/org.blink.demo"
swiftc -D WINK_TESTING Sources/PluginPackage.swift Sources/SpotifyService.swift Tests/SpotifyChecks.swift -o "$CHECK_DIR/spotify"
"$CHECK_DIR/spotify"
mkdir -p "$CHECK_DIR/SpotifyChecks.app/Contents/MacOS" "$CHECK_DIR/SpotifyChecks.app/Contents/Resources"
cp -R Resources/Plugins "$CHECK_DIR/SpotifyChecks.app/Contents/Resources/"
swiftc -D WINK_TESTING Sources/PluginPackage.swift Sources/PluginInstaller.swift Sources/Plugins.swift Sources/SpotifyService.swift Sources/DatabaseWorkbench.swift Tests/SpotifyWebViewChecks/main.swift -o "$CHECK_DIR/SpotifyChecks.app/Contents/MacOS/SpotifyChecks"
"$CHECK_DIR/SpotifyChecks.app/Contents/MacOS/SpotifyChecks"
echo "Check binaries retained at $CHECK_DIR"

swiftc -D WINK_TESTING Sources/PluginPackage.swift Sources/PluginInstaller.swift Sources/Plugins.swift Sources/SpotifyService.swift Sources/DatabaseWorkbench.swift Tests/AppsWebViewChecks/main.swift -o "$CHECK_DIR/SpotifyChecks.app/Contents/MacOS/SpotifyChecks"
"$CHECK_DIR/SpotifyChecks.app/Contents/MacOS/SpotifyChecks"

swiftc -D WINK_TESTING Sources/PluginPackage.swift Sources/PluginInstaller.swift Sources/Plugins.swift Sources/SpotifyService.swift Sources/DatabaseWorkbench.swift Tests/TUIWebViewChecks/main.swift -o "$CHECK_DIR/tui"
"$CHECK_DIR/tui" "$PWD/examples/hterm-tui"
