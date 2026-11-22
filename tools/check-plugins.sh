#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK_DIR=$(mktemp -d /tmp/wink-plugin-checks.XXXXXX)
swiftc Sources/PluginPackage.swift Tests/PluginPackageChecks.swift -o "$CHECK_DIR/packages"
"$CHECK_DIR/packages"
swiftc Sources/PluginPackage.swift Sources/Plugins.swift Tests/PluginWebViewChecks/main.swift -o "$CHECK_DIR/webview"
"$CHECK_DIR/webview" "$PWD/Resources/Plugins/org.blink.demo"
echo "Check binaries retained at $CHECK_DIR"
