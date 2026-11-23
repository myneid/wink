import AppKit
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menu = PluginsMenuController()
menu.menuNeedsUpdate(menu.menu)
precondition(menu.menu.items.contains { $0.title == "Spotify" })
let package = try PluginPackage(root: Bundle.main.resourceURL!.appendingPathComponent("Plugins/org.blink.spotify"))
// Exercise the actual Apps-menu launch path alongside a terminal-compatible host.
let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
host.tabbingIdentifier = "wink"
host.tabbingMode = .preferred
host.makeKeyAndOrderFront(nil)
let index = menu.menu.items.firstIndex { $0.title == "Spotify" }!
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
    if (!document.querySelector('#login')) return false;
    if (document.querySelector('#client').value !== '824343e4193644aab4193e4574480d82' || document.querySelector('#client').type !== 'hidden') throw new Error('Missing bundled client configuration');
    if (document.querySelector('#searchtype').value !== 'artist' || !document.querySelector('#release-group') || !document.querySelector('#playalbum')) throw new Error('Missing artist/album browsing UI');
    const info = await blink.host.info();
    if (!info.capabilities.includes('spotify')) throw new Error('Missing Spotify capability');
    if (!document.querySelector('#login').textContent.includes('Connect')) throw new Error('Missing connect UI');
    if (!(await blink.spotify.status()).redirectURI.startsWith('http://127.0.0.1:')) throw new Error('Invalid redirect');
    let denied = false;
    try { await blink.spotify.request('GET', 'https://evil.test/'); } catch (_) { denied = true; }
    if (!denied) throw new Error('Unrestricted native request');
    return true;
    """, arguments: [:], in: nil, in: .page) { result in
    if case .success(let value) = result, (value as? Bool) == true {
      print("PASS: bundled Spotify menu, real WebView UI, capability, status and request allowlist (no network/login)")
      if CommandLine.arguments.contains("--streaming-probe") {
        web.callAsyncJavaScript("""
          await loadStreamingSDK();
          return await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('SDK iframe handshake timed out')), 15000);
            const probe = new Spotify.Player({name:'Wink test', getOAuthToken: () => {
              clearTimeout(timer); probe.disconnect(); resolve('SDK iframe handshake succeeded; no token supplied');
            }});
            probe.addListener('initialization_error', e => { clearTimeout(timer); reject(new Error(e.message)); });
            probe.connect();
          });
          """, arguments: [:], in: nil, in: .page) { result in
            print("Streaming probe: \(result)")
            if case .success = result { controller.close(); host.close(); exit(0) }
            exit(1)
          }
        return
      }
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
