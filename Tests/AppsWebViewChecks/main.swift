import AppKit
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menu = PluginsMenuController()
menu.menuNeedsUpdate(menu.menu)
precondition(menu.menu.items.contains { $0.title == "Manage Apps…" })
let package = try PluginPackage(root: Bundle.main.resourceURL!.appendingPathComponent("Plugins/org.blink.apps"))
// Exercise the actual Apps-menu launch path alongside a terminal-compatible host.
let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
host.tabbingIdentifier = "wink"
host.tabbingMode = .preferred
host.makeKeyAndOrderFront(nil)
let index = menu.menu.items.firstIndex { $0.title == "Manage Apps…" }!
menu.menu.performActionForItem(at: index)
guard let pluginTab = host.tabbedWindows?.first(where: { $0 !== host }),
      let controller = pluginTab.windowController as? PluginWindowController else {
  print("FAIL: Apps menu did not open Spotify in the current tab group"); exit(1)
}
menu.menu.performActionForItem(at: index)
precondition(host.tabbedWindows?.count == 2, "Reopening a plugin must reuse its tab")
print("PASS: Apps-menu launch joins current tab group; reopening reuses tab")
let web = controller.window!.contentView as! WKWebView
var tries = 0
func check() {
  tries += 1
  web.callAsyncJavaScript("""
    if (!document.querySelector('#apps')) return false;
    const apps = await blink.apps.list();
    if (!apps.some(app => app.id === 'org.blink.spotify' && !app.updatable)) throw new Error('Missing bundled metadata');
    if (!document.querySelector('#check') || !document.querySelector('#install')) throw new Error('Missing management controls');
    return true;
    """, arguments: [:], in: nil, in: .page) { result in
    if case .success(let value) = result, (value as? Bool) == true {
      print("PASS: Apps manager real WebView and trusted list bridge")
      controller.close()
      precondition(host.isVisible, "Closing a plugin must preserve its host tab")
      host.close(); exit(0)
    }
    if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { check() } }
    else { print("FAIL: Spotify WebView: \(result)"); exit(1) }
  }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { check() }
app.run()
