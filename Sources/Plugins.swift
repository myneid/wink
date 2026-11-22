import AppKit
import WebKit

final class PluginsMenuController: NSObject, NSMenuDelegate {
  let menu = NSMenu(title: "Apps")
  private var windows: [PluginWindowController] = []
  private var pluginsFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wink/Plugins", isDirectory: true)
  }

  override init() { super.init(); menu.delegate = self }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    var packages: [String: PluginPackage] = [:]
    let roots = [Bundle.main.resourceURL?.appendingPathComponent("Plugins"), pluginsFolder].compactMap { $0 }
    for root in roots {
      for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        do {
          let package = try PluginPackage(root: folder)
          guard packages[package.manifest.id] == nil else { continue }
          packages[package.manifest.id] = package
        } catch {
          let item = menu.addItem(withTitle: "Invalid app: \(folder.lastPathComponent)", action: nil, keyEquivalent: "")
          item.toolTip = error.localizedDescription
        }
      }
    }
    for package in packages.values.sorted(by: { $0.manifest.name < $1.manifest.name }) {
      let item = menu.addItem(withTitle: package.manifest.name, action: #selector(openApp(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = package
    }
    menu.addItem(.separator())
    let folder = menu.addItem(withTitle: "Open Apps Folder…", action: #selector(openFolder), keyEquivalent: "")
    folder.target = self
  }

  @objc private func openFolder() {
    do {
      try FileManager.default.createDirectory(at: pluginsFolder, withIntermediateDirectories: true)
      NSWorkspace.shared.open(pluginsFolder)
    } catch { NSAlert(error: error).runModal() }
  }

  @objc private func openApp(_ sender: NSMenuItem) {
    guard let package = sender.representedObject as? PluginPackage else { return }
    if let existing = windows.first(where: { $0.package.manifest.id == package.manifest.id }) {
      existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return
    }
    let controller = PluginWindowController(package: package)
    controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
    windows.append(controller)
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}

/// No terminal objects, file loading, shell access, or network authority is exposed here.
final class PluginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
  let package: PluginPackage
  var onClose: (() -> Void)?
  private let webView: WKWebView
  private let content: WKUserContentController
  private var storageKey: String { "plugin.v1." + package.manifest.id }

  init(package: PluginPackage) {
    self.package = package
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.setURLSchemeHandler(PluginAssets(package: package), forURLScheme: "blink-plugin")
    content = config.userContentController
    content.addUserScript(WKUserScript(source: Self.sdk, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    webView = WKWebView(frame: .zero, configuration: config)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = package.manifest.name
    window.tabbingMode = .disallowed
    window.contentView = webView
    super.init(window: window)
    window.delegate = self
    content.addScriptMessageHandler(self, contentWorld: .page, name: "blink")
    webView.navigationDelegate = self
    webView.uiDelegate = self
    var url = URLComponents()
    url.scheme = "blink-plugin"; url.host = package.manifest.id; url.path = "/" + package.manifest.entry
    webView.load(URLRequest(url: url.url!))
  }

  required init?(coder: NSCoder) { fatalError() }

  func windowWillClose(_ notification: Notification) {
    content.removeScriptMessageHandler(forName: "blink", contentWorld: .page)
    webView.stopLoading()
    onClose?()
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let url = action.request.url
    decisionHandler(url?.scheme == "blink-plugin" && url?.host == package.manifest.id && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                             replyHandler: @escaping (Any?, String?) -> Void) {
    guard message.frameInfo.isMainFrame,
          message.frameInfo.request.url?.scheme == "blink-plugin",
          message.frameInfo.request.url?.host == package.manifest.id,
          let request = message.body as? [String: Any], let method = request["method"] as? String else {
      replyHandler(nil, "Invalid request"); return
    }
    if method == "host.info" {
      replyHandler(["apiVersion": 1, "host": "wink", "platform": "macos", "pluginID": package.manifest.id,
                    "capabilities": ["host.info"] + (package.manifest.permissions.contains("storage") ? ["storage.get", "storage.set"] : [])], nil)
      return
    }
    guard package.manifest.permissions.contains("storage"),
          let key = request["key"] as? String, !key.isEmpty, key.utf8.count <= 256 else {
      replyHandler(nil, "Permission denied or invalid key"); return
    }
    var storage = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    switch method {
    case "storage.get": replyHandler(storage[key] ?? NSNull(), nil)
    case "storage.set":
      guard let value = request["value"] as? String else { replyHandler(nil, "Value must be a string"); return }
      storage[key] = value
      guard let data = try? JSONSerialization.data(withJSONObject: storage), data.count <= 65536 else {
        replyHandler(nil, "Storage quota exceeded (64 KiB)"); return
      }
      UserDefaults.standard.set(storage, forKey: storageKey)
      replyHandler(true, nil)
    default: replyHandler(nil, "Unsupported method")
    }
  }

  private static let sdk = """
  (() => {
    const call = (method, args = {}) => window.webkit.messageHandlers.blink.postMessage({method, ...args});
    Object.defineProperty(window, 'blink', {value: Object.freeze({
      apiVersion: 1,
      host: Object.freeze({info: () => call('host.info')}),
      storage: Object.freeze({get: key => call('storage.get', {key}), set: (key, value) => call('storage.set', {key, value})})
    }), writable: false, configurable: false});
  })();
  """
}

private final class PluginAssets: NSObject, WKURLSchemeHandler {
  let package: PluginPackage
  init(package: PluginPackage) { self.package = package }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    do {
      guard let url = task.request.url, url.host == package.manifest.id, task.request.httpMethod == "GET" else {
        throw PluginPackage.Failure.invalid("Invalid resource request")
      }
      let path = String(url.path.dropFirst())
      let file = try package.asset(path)
      let attributes = try file.resourceValues(forKeys: [.fileSizeKey])
      guard (attributes.fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw PluginPackage.Failure.invalid("Asset exceeds 8 MiB") }
      let data = try Data(contentsOf: file)
      let types = ["html": "text/html", "js": "text/javascript", "css": "text/css", "json": "application/json",
                   "png": "image/png", "jpg": "image/jpeg", "svg": "image/svg+xml", "woff2": "font/woff2"]
      let csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
        "Content-Type": types[file.pathExtension] ?? "application/octet-stream",
        "Content-Security-Policy": csp, "X-Content-Type-Options": "nosniff"
      ])!
      task.didReceive(response); task.didReceive(data); task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
