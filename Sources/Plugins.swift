import AppKit
import WebKit

final class PluginsMenuController: NSObject, NSMenuDelegate {
  let menu = NSMenu(title: "Apps")
  private static let databaseRepository = "https://github.com/myneid/wink-database"
  private var installing = false
  private var updates: [String: PreparedPlugin] = [:]
  private var windows: [PluginWindowController] = []
  private var pluginsFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Wink/Plugins", isDirectory: true)
  }

  override init() { super.init(); menu.delegate = self }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    let manage = menu.addItem(withTitle: "Manage Apps…", action: #selector(manageApps), keyEquivalent: "")
    manage.target = self
    menu.addItem(.separator())
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
    let install = menu.addItem(withTitle: installing ? "Downloading App…" : "Install from GitHub…", action: installing ? nil : #selector(installFromGitHub), keyEquivalent: "")
    install.target = self
    if packages["org.blink.database"] == nil {
      let database = menu.addItem(withTitle: "Install Database Workbench…",
        action: installing ? nil : #selector(installDatabaseWorkbench), keyEquivalent: "")
      database.target = self
    }
    let folder = menu.addItem(withTitle: "Open Apps Folder…", action: #selector(openFolder), keyEquivalent: "")
    folder.target = self
  }

  private func packages() -> [PluginPackage] {
    var result: [String: PluginPackage] = [:]
    for root in [Bundle.main.resourceURL?.appendingPathComponent("Plugins"), pluginsFolder].compactMap({ $0 }) {
      for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
        if let package = try? PluginPackage(root: folder), result[package.manifest.id] == nil { result[package.manifest.id] = package }
      }
    }
    return result.values.sorted { $0.manifest.name < $1.manifest.name }
  }
  private func receipt(_ package: PluginPackage) -> [String: String]? {
    guard package.root.deletingLastPathComponent() == pluginsFolder.standardizedFileURL,
          let data = try? Data(contentsOf: package.root.appendingPathComponent(".wink-source.json")) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
  }
  @objc private func manageApps() {
    guard let package = packages().first(where: { $0.manifest.id == "org.blink.apps" }) else { return }
    let item = NSMenuItem(); item.representedObject = package; openApp(item)
  }
  @MainActor private func appsCall(_ method: String, _ args: [String: Any]) async throws -> Any {
    if method == "apps.list" {
      return packages().filter { $0.manifest.id != "org.blink.apps" }.map { package -> [String: Any] in
        let installed = receipt(package)
        let pending = updates[package.manifest.id]
        let bundledProjects = ["org.blink.spotify": "https://github.com/myneid/wink-spotify",
                               "org.blink.demo": "https://github.com/myneid/wink/tree/main/Resources/Plugins/org.blink.demo"]
        let repositoryURL = installed?["repository"].flatMap { try? GitHubPluginSource($0).repositoryURL }
          ?? (installed == nil ? bundledProjects[package.manifest.id] : nil) ?? ""
        return ["id":package.manifest.id, "name":package.manifest.name, "version":package.manifest.version,
                "source":installed?["repository"] ?? "Bundled with Wink", "repositoryURL":repositoryURL, "updatable":installed != nil,
                "updateVersion":pending?.package.manifest.version ?? "", "permissions":package.manifest.permissions]
      }
    }
    if method == "apps.install" { installFromGitHub(); return true }
    guard let id = args["id"] as? String, let package = packages().first(where: { $0.manifest.id == id }) else {
      throw PluginPackage.Failure.invalid("App not found")
    }
    if method == "apps.open" { let item = NSMenuItem(); item.representedObject = package; openApp(item); return true }
    guard let saved = receipt(package), let repository = saved["repository"] else {
      throw PluginPackage.Failure.invalid("Bundled apps update with Wink. Use Wink → Check for Updates.")
    }
    if method == "apps.check" {
      let path = saved["path"] ?? "", ref = saved["ref"] ?? ""
      // Older receipts omitted ref; follow the repository default branch for those installs.
      let link = ref.isEmpty && path.isEmpty ? repository : repository + "/tree/" + (ref.isEmpty ? "HEAD" : ref) + (path.isEmpty ? "" : "/" + path)
      let prepared = try await PluginInstaller().prepare(GitHubPluginSource(link), staging: pluginsFolder.deletingLastPathComponent().appendingPathComponent("PluginDownloads"))
      guard prepared.package.manifest.id == id else { throw PluginPackage.Failure.invalid("Publisher changed the app ID; update refused") }
      updates[id] = prepared.commit == saved["commit"] ? nil : prepared
      return updates[id] != nil
    }
    if method == "apps.update", let prepared = updates[id] {
      let alert = NSAlert(); alert.messageText = "Update \(package.manifest.name)?"
      alert.informativeText = "Version: \(package.manifest.version) → \(prepared.package.manifest.version)\nSource: \(prepared.source.repositoryURL)\nCommit: \(prepared.commit)\nPermissions: \(prepared.package.manifest.permissions.joined(separator: ", "))\n\nThe app tab will close. Its stored data and a backup of the previous package will be retained."
      alert.addButton(withTitle: "Update"); alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return false }
      try prepared.update(package, receipt: saved, backups: pluginsFolder.deletingLastPathComponent().appendingPathComponent("PluginBackups"))
      windows.first(where: { $0.package.manifest.id == id })?.close()
      updates[id] = nil
      return true
    }
    throw PluginPackage.Failure.invalid("Unsupported app operation; check for updates first")
  }

  @objc private func installDatabaseWorkbench() {
    promptGitHubInstall(prefill: Self.databaseRepository)
  }

  @objc private func installFromGitHub() { promptGitHubInstall(prefill: "") }

  private func promptGitHubInstall(prefill: String) {
    guard !installing else { return }
    let prompt = NSAlert()
    prompt.messageText = "Install App from GitHub"
    prompt.informativeText = "Paste a public repository or plugin-folder link. Wink will contact GitHub and download a pinned snapshot for review. No build scripts are run."
    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
    input.stringValue = prefill
    input.placeholderString = "https://github.com/owner/plugin"
    prompt.accessoryView = input
    prompt.addButton(withTitle: "Download for Review")
    prompt.addButton(withTitle: "Cancel")
    prompt.window.initialFirstResponder = input
    guard prompt.runModal() == .alertFirstButtonReturn else { return }
    do {
      let source = try GitHubPluginSource(input.stringValue)
      installing = true
      Task { @MainActor in
        defer { installing = false }
        do {
          let staging = pluginsFolder.deletingLastPathComponent().appendingPathComponent("PluginDownloads")
          let prepared = try await PluginInstaller().prepare(source, staging: staging)
          let manifest = prepared.package.manifest
          let review = NSAlert()
          review.messageText = "Install \(manifest.name)?"
          review.informativeText = "Version: \(manifest.version)\nID: \(manifest.id)\nSource: \(source.repositoryURL)\nCommit: \(prepared.commit)\nPermissions: \(manifest.permissions.isEmpty ? "none" : manifest.permissions.joined(separator: ", "))\n\nInstall only code from publishers you trust. Spotify permission is reserved for the bundled example; Database permission lets an app query only a connection you select in Wink. No app can access terminal sessions."
          review.addButton(withTitle: "Install")
          review.addButton(withTitle: "Cancel")
          guard review.runModal() == .alertFirstButtonReturn else { return }
          let bundledRoot = Bundle.main.resourceURL?.appendingPathComponent("Plugins")
          let bundled = bundledRoot.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
          let ids = Set(bundled.compactMap { try? PluginPackage(root: $0).manifest.id })
          let installed = try prepared.install(in: pluginsFolder, bundledIDs: ids)
          let item = NSMenuItem()
          item.representedObject = try PluginPackage(root: installed)
          openApp(item)
        } catch { NSAlert(error: error).runModal() }
      }
    } catch { NSAlert(error: error).runModal() }
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
    let host = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
      .first { $0.tabbingIdentifier == "wink" }
      ?? NSApp.orderedWindows.first { $0.isVisible && $0.tabbingIdentifier == "wink" }
    let controller = PluginWindowController(package: package)
    controller.appsHandler = { [weak self] method, args in
      guard let self else { throw PluginPackage.Failure.invalid("Apps manager closed") }
      return try await self.appsCall(method, args)
    }
    controller.onClose = { [weak self, weak controller] in self?.windows.removeAll { $0 === controller } }
    windows.append(controller)
    if let host, let tab = controller.window { host.addTabbedWindow(tab, ordered: .above) }
    controller.showWindow(nil)
    controller.window?.makeKeyAndOrderFront(nil)
  }
}

/// No shell or terminal authority. Spotify is a restricted bundled-host capability.
final class PluginWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
  let package: PluginPackage
  var onClose: (() -> Void)?
  var appsHandler: ((String, [String: Any]) async throws -> Any)?
  private var appsAllowed: Bool {
    guard package.manifest.id == "org.blink.apps", let root = Bundle.main.resourceURL?.appendingPathComponent("Plugins/org.blink.apps") else { return false }
    return package.root == root.resolvingSymlinksInPath().standardizedFileURL
  }
  @MainActor private lazy var database = DatabaseWorkbench(appName: package.manifest.name)
  private var databaseAllowed: Bool { package.manifest.permissions.contains("database") }
  private let webView: WKWebView
  private let content: WKUserContentController
  private var spotifyAllowed: Bool {
    guard package.manifest.id == "org.blink.spotify", package.manifest.permissions.contains("spotify"),
          let root = Bundle.main.resourceURL?.appendingPathComponent("Plugins/org.blink.spotify") else { return false }
    return package.root == root.resolvingSymlinksInPath().standardizedFileURL
  }
  private var storageKey: String { "plugin.v1." + package.manifest.id }

  init(package: PluginPackage) {
    self.package = package
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.mediaTypesRequiringUserActionForPlayback = []
    config.setURLSchemeHandler(PluginAssets(package: package), forURLScheme: "blink-plugin")
    content = config.userContentController
    content.addUserScript(WKUserScript(source: Self.sdk, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    webView = WKWebView(frame: .zero, configuration: config)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = package.manifest.name
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "wink"
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
    if spotifyAllowed { SpotifyService.shared.cancelLogin() }
    if databaseAllowed { database.close() }
    onClose?()
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    let url = action.request.url
    if spotifyAllowed, action.navigationType == .linkActivated, let url = url,
       url.scheme == "https", url.host == "open.spotify.com", url.user == nil, url.password == nil {
      NSWorkspace.shared.open(url)
    }
    if appsAllowed, action.navigationType == .linkActivated, let url,
       (try? GitHubPluginSource(url.absoluteString)) != nil {
      NSWorkspace.shared.open(url)
    }
    // Spotify's SDK runs its player in this exact HTTPS iframe. Never grant it the native bridge.
    if spotifyAllowed, action.targetFrame?.isMainFrame == false,
       let url, url.scheme == "https", url.host == "sdk.scdn.co", url.port == nil,
       url.user == nil, url.password == nil {
      decisionHandler(.allow); return
    }
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
    if method.hasPrefix("apps.") {
      guard appsAllowed, let handler = appsHandler else { replyHandler(nil, "Apps management requires the bundled Apps screen"); return }
      Task { @MainActor in
        do { replyHandler(try await handler(method, request), nil) }
        catch { replyHandler(nil, error.localizedDescription) }
      }
      return
    }
    if method.hasPrefix("database.") {
      guard databaseAllowed else { replyHandler(nil, "App has not declared the database permission"); return }
      Task { @MainActor in
        do { replyHandler(try await database.call(method, request), nil) }
        catch { replyHandler(nil, error.localizedDescription) }
      }
      return
    }
    if method.hasPrefix("spotify.") {
      guard spotifyAllowed else { replyHandler(nil, "Spotify requires the bundled Spotify plugin"); return }
      Task { @MainActor in
        do { replyHandler(try await SpotifyService.shared.call(method, request), nil) }
        catch { replyHandler(nil, error.localizedDescription) }
      }
      return
    }
    if method == "host.info" {
      replyHandler(["apiVersion": 1, "host": "wink", "platform": "macos", "pluginID": package.manifest.id,
                    "capabilities": ["host.info"] + (databaseAllowed ? ["database"] : []) + (spotifyAllowed ? ["spotify"] : []) + (package.manifest.permissions.contains("storage") ? ["storage.get", "storage.set"] : [])], nil)
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
      apps: Object.freeze({list: () => call('apps.list'), open: id => call('apps.open', {id}),
        check: id => call('apps.check', {id}), update: id => call('apps.update', {id}), install: () => call('apps.install')}),
      database: Object.freeze({connect: () => call('database.connect'), query: sql => call('database.query', {sql}),
        cancel: () => call('database.cancel')}),
      spotify: Object.freeze({status: () => call('spotify.status'), login: clientID => call('spotify.login', {clientID}),
        logout: () => call('spotify.logout'), streamingToken: () => call('spotify.streamingToken'), request: (verb, path, query = {}, body) => call('spotify.request', {verb, path, query, ...(body === undefined ? {} : {body})}),
        artwork: url => call('spotify.artwork', {url})}),
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
      var csp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"
      let bundled = Bundle.main.resourceURL?.appendingPathComponent("Plugins/org.blink.spotify").resolvingSymlinksInPath().standardizedFileURL
      if package.manifest.id == "org.blink.spotify", package.manifest.permissions.contains("spotify"), package.root == bundled {
        csp = "default-src 'none'; script-src 'self' https://sdk.scdn.co; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'none'; media-src blob:; frame-src https://sdk.scdn.co; object-src 'none'; base-uri 'none'; form-action 'none'"
      }
      let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
        "Content-Type": types[file.pathExtension] ?? "application/octet-stream",
        "Content-Security-Policy": csp, "X-Content-Type-Options": "nosniff"
      ])!
      task.didReceive(response); task.didReceive(data); task.didFinish()
    } catch { task.didFailWithError(error) }
  }
  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
