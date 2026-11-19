import AppKit
import Security

// Keeps Wink up to date from its GitHub releases.
//
// Once a day (if Check for Updates Automatically is on) Wink asks GitHub for
// the latest release. A newer one is downloaded, its app copied out of the
// DMG and checked: signed by Wink's Developer ID team, notarized, the right
// bundle id and the version the release claims. Then it waits.
//
// A running app can't replace itself, so the swap happens when Wink quits:
// a small shell script waits for Wink to exit, moves the new app into place
// and, for Restart to Update, opens it again. Wink never restarts on its own,
// because restarting ends the shells in its tabs. With Install Updates
// Automatically on, an update is downloaded without asking and goes in the
// next time you quit.
final class Updater: NSObject, NSMenuItemValidation {
  static let shared = Updater()

  static let repo = "myneid/wink"
  static let teamID = "CQ7H5G2XUN"
  static let bundleID = "sh.wink.Wink"

  struct Release {
    var version: String
    var notes: String
    var page: URL
    var dmg: URL
  }

  enum State {
    case idle
    case checking(userInitiated: Bool)
    case downloading(Release)
    case ready(Release, app: URL)
  }

  private(set) var state = State.idle { didSet { refreshMenu() } }
  /// Set by Restart to Update: open the new Wink after installing it.
  private var relaunch = false
  private var timer: Timer?
  private let d = UserDefaults.standard

  var currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
  var appURL = Bundle.main.bundleURL

  let checkItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkNow(_:)), keyEquivalent: "")
  let restartItem = NSMenuItem(title: "Restart to Update", action: #selector(restartToUpdate(_:)), keyEquivalent: "")
  let autoCheckItem = NSMenuItem(title: "Check for Updates Automatically", action: #selector(toggleAutoCheck(_:)),
                                 keyEquivalent: "")
  let autoInstallItem = NSMenuItem(title: "Install Updates Automatically", action: #selector(toggleAutoInstall(_:)),
                                   keyEquivalent: "")

  // MARK: - Settings

  var checkAutomatically: Bool {
    get { d.object(forKey: "updateCheck") as? Bool ?? true }
    set { d.set(newValue, forKey: "updateCheck") }
  }

  var installAutomatically: Bool {
    get { d.bool(forKey: "updateInstall") }
    set { d.set(newValue, forKey: "updateInstall") }
  }

  private var lastCheck: Date? {
    get { d.object(forKey: "updateLastCheck") as? Date }
    set { d.set(newValue, forKey: "updateLastCheck") }
  }

  /// A version you chose to skip in an update alert.
  private var skipped: String? {
    get { d.string(forKey: "updateSkip") }
    set { d.set(newValue, forKey: "updateSkip") }
  }

  static var updatesDir: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent(bundleID).appendingPathComponent("Updates")
  }

  // MARK: - Lifecycle

  func start() {
    for item in [checkItem, restartItem, autoCheckItem, autoInstallItem] { item.target = self }
    refreshMenu()
    // Anything left from a session that never installed it.
    try? FileManager.default.removeItem(at: Self.updatesDir)
    // Hourly, so a Mac that slept through the day still checks soon after waking.
    timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
  }

  /// Called from applicationWillTerminate: installs a downloaded update.
  func willTerminate() {
    guard case .ready(_, let app) = state, installBlocker == nil else { return }
    launchInstaller(staged: app, relaunch: relaunch)
  }

  private func checkIfDue() {
    guard checkAutomatically, case .idle = state else { return }
    if let last = lastCheck, Date().timeIntervalSince(last) < 23 * 3600 { return }
    check(userInitiated: false)
  }

  // MARK: - Menu

  @objc func checkNow(_ sender: Any?) {
    switch state {
    case .ready(let release, _): offerRestart(release)
    case .idle: check(userInitiated: true)
    default: break
    }
  }

  @objc func restartToUpdate(_ sender: Any?) {
    guard case .ready = state else { return }
    relaunch = true
    NSApp.terminate(nil)
  }

  @objc func toggleAutoCheck(_ sender: Any?) {
    checkAutomatically.toggle()
    checkIfDue()
  }

  @objc func toggleAutoInstall(_ sender: Any?) {
    installAutomatically.toggle()
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(checkNow(_:)):
      if case .ready = state { return true }
      if case .idle = state { return true }
      return false
    case #selector(toggleAutoCheck(_:)):
      item.state = checkAutomatically ? .on : .off
    case #selector(toggleAutoInstall(_:)):
      item.state = installAutomatically ? .on : .off
      return checkAutomatically
    default: break
    }
    return true
  }

  private func refreshMenu() {
    switch state {
    case .idle: checkItem.title = "Check for Updates…"
    case .checking: checkItem.title = "Checking for Updates…"
    case .downloading(let r): checkItem.title = "Downloading Wink \(r.version)…"
    case .ready(let r, _): checkItem.title = "Wink \(r.version) Is Ready to Install…"
    }
    if case .ready(let r, _) = state {
      restartItem.title = "Restart to Update to Wink \(r.version)"
      restartItem.isHidden = false
    } else {
      restartItem.isHidden = true
    }
  }

  // MARK: - Checking

  private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
      var name: String
      var browser_download_url: URL
    }
    var tag_name: String
    var body: String?
    var html_url: URL
    var draft: Bool
    var prerelease: Bool
    var assets: [Asset]
  }

  /// The latest published release, from GitHub.
  func fetchLatest(_ done: @escaping (Result<Release, Error>) -> Void) {
    var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("Wink/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    req.timeoutInterval = 30
    URLSession.shared.dataTask(with: req) { data, response, error in
      done(Result {
        if let error { throw error }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let data else {
          throw UpdateError("GitHub answered with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let gh = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !gh.draft, !gh.prerelease else { throw UpdateError("The latest release is a draft.") }
        let version = gh.tag_name.hasPrefix("v") ? String(gh.tag_name.dropFirst()) : gh.tag_name
        guard let dmg = gh.assets.first(where: { $0.name.hasPrefix("Wink") && $0.name.hasSuffix(".dmg") }) else {
          throw UpdateError("Wink \(version) has no disk image to download.")
        }
        return Release(version: version, notes: gh.body ?? "", page: gh.html_url, dmg: dmg.browser_download_url)
      })
    }.resume()
  }

  func check(userInitiated: Bool) {
    state = .checking(userInitiated: userInitiated)
    fetchLatest { result in
      DispatchQueue.main.async { self.handle(result, userInitiated: userInitiated) }
    }
  }

  private func handle(_ result: Result<Release, Error>, userInitiated: Bool) {
    state = .idle
    let release: Release
    switch result {
    case .failure(let error):
      if userInitiated { showError("Couldn't check for updates", error) }
      return
    case .success(let r):
      release = r
    }
    lastCheck = Date()
    guard Self.isNewer(release.version, than: currentVersion) else {
      if userInitiated {
        alert("Wink is up to date", "You have Wink \(currentVersion), the latest version.")
      }
      return
    }
    if !userInitiated && skipped == release.version { return }
    if !userInitiated && installAutomatically && installBlocker == nil {
      download(release, relaunchWhenDone: false, userInitiated: false)
      return
    }
    offer(release, userInitiated: userInitiated)
  }

  private func offer(_ release: Release, userInitiated: Bool) {
    let a = NSAlert()
    a.messageText = "Wink \(release.version) is available"
    var info = "You have Wink \(currentVersion)."
    let notes = Self.plainNotes(release.notes)
    if !notes.isEmpty { info += "\n\n" + notes }

    if let blocker = installBlocker {
      a.informativeText = info + "\n\n" + blocker
      a.addButton(withTitle: "Download")
      a.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
      if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.page) }
      return
    }

    a.informativeText = info + "\n\nRestarting ends the shells in Wink's tabs (tmux sessions keep running), "
      + "so you can also install it the next time you quit Wink."
    // Return installs on quit, so a stray keypress never restarts Wink.
    a.addButton(withTitle: "Install When I Quit")
    a.addButton(withTitle: "Install and Restart")
    a.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
    a.addButton(withTitle: "Release Notes")
    if !userInitiated {
      a.showsSuppressionButton = true
      a.suppressionButton?.title = "Skip this version"
    }
    let answer = a.runModal()
    if a.suppressionButton?.state == .on { skipped = release.version }
    switch answer {
    case .alertFirstButtonReturn: download(release, relaunchWhenDone: false, userInitiated: true)
    case .alertSecondButtonReturn: download(release, relaunchWhenDone: true, userInitiated: true)
    case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
      NSWorkspace.shared.open(release.page)
    default: break
    }
  }

  private func offerRestart(_ release: Release) {
    let a = NSAlert()
    a.messageText = "Wink \(release.version) is ready to install"
    a.informativeText = "It installs the next time you quit Wink. Restarting now ends the shells in Wink's tabs "
      + "(tmux sessions keep running)."
    a.addButton(withTitle: "Restart Now")
    a.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
    if a.runModal() == .alertFirstButtonReturn { restartToUpdate(nil) }
  }

  // MARK: - Downloading

  private func download(_ release: Release, relaunchWhenDone: Bool, userInitiated: Bool) {
    state = .downloading(release)
    stage(release) { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let app):
          self.state = .ready(release, app: app)
          if relaunchWhenDone { self.restartToUpdate(nil) }
        case .failure(let error):
          self.state = .idle
          if userInitiated { self.showError("Couldn't update Wink", error) }
          else { NSLog("Wink update to %@ failed: %@", release.version, "\(error)") }
        }
      }
    }
  }

  /// Downloads the release's DMG and copies the checked app out of it.
  func stage(_ release: Release, _ done: @escaping (Result<URL, Error>) -> Void) {
    URLSession.shared.downloadTask(with: release.dmg) { tmp, response, error in
      // The temporary file only lasts until this closure returns.
      let result = Result<URL, Error> {
        if let error { throw error }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let tmp else {
          throw UpdateError("The download failed with status \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        let fm = FileManager.default
        let dir = Self.updatesDir.appendingPathComponent("Wink-\(release.version)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dmg = dir.appendingPathComponent("Wink.dmg")
        try fm.moveItem(at: tmp, to: dmg)
        return dmg
      }
      DispatchQueue.global(qos: .utility).async {
        done(result.flatMap { dmg in Result { try self.unpack(dmg, version: release.version) } })
      }
    }.resume()
  }

  private func unpack(_ dmg: URL, version: String) throws -> URL {
    let fm = FileManager.default
    let mount = fm.temporaryDirectory.appendingPathComponent("wink-update-\(UUID().uuidString)")
    try fm.createDirectory(at: mount, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: mount) }
    try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-noautoopen", "-readonly",
                                      "-mountpoint", mount.path])
    defer { _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
    let source = mount.appendingPathComponent("Wink.app")
    guard fm.fileExists(atPath: source.path) else { throw UpdateError("The disk image has no Wink.app.") }
    let app = dmg.deletingLastPathComponent().appendingPathComponent("Wink.app")
    try Self.run("/usr/bin/ditto", [source.path, app.path])
    try? fm.removeItem(at: dmg)
    try Self.verify(app, version: version)
    return app
  }

  /// Signed by Wink's Developer ID team, notarized, and the version expected.
  static func verify(_ app: URL, version: String) throws {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
      throw UpdateError("The update isn't a signed app.")
    }
    var requirement: SecRequirement?
    let text = """
      anchor apple generic and identifier "\(bundleID)" \
      and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
      and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
      and certificate leaf[subject.OU] = "\(teamID)"
      """
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
      throw UpdateError("Couldn't build the signature check.")
    }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    let status = SecStaticCodeCheckValidity(code, flags, requirement)
    guard status == errSecSuccess else {
      throw UpdateError("The update isn't signed by Wink's developer (error \(status)).")
    }
    // Notarized: Gatekeeper accepts it.
    do { try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) } catch {
      throw UpdateError("The update isn't notarized by Apple.")
    }
    let found = Bundle(url: app)?.infoDictionary?["CFBundleShortVersionString"] as? String
    guard found == version else {
      throw UpdateError("The update is Wink \(found ?? "?"), not \(version).")
    }
  }

  // MARK: - Installing

  /// Why Wink can't replace itself, if it can't.
  var installBlocker: String? {
    let path = appURL.path
    if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
      return "Wink is running from the disk image. Move it to your Applications folder to update it from here."
    }
    let parent = appURL.deletingLastPathComponent().path
    let fm = FileManager.default
    if !fm.isWritableFile(atPath: parent) || !fm.isWritableFile(atPath: path) {
      return "Wink can't write to \(parent), so download the update and install it yourself."
    }
    return nil
  }

  /// Starts a script that waits for Wink (this process) to exit, then swaps
  /// the staged app in, keeping the old one if anything fails.
  func launchInstaller(staged: URL, relaunch: Bool, waitFor pid: Int32 = getpid()) {
    let script = #"""
      pid=$1 src=$2 dest=$3 relaunch=$4
      while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
      new="$dest.update-$$" old="$dest.old-$$"
      if /usr/bin/ditto "$src" "$new"; then
        if mv "$dest" "$old"; then
          if mv "$new" "$dest"; then rm -rf "$old"; else mv "$old" "$dest"; fi
        fi
      fi
      rm -rf "$new" "$(dirname "$src")"
      [ "$relaunch" = 1 ] && /usr/bin/open "$dest"
      exit 0
      """#
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", script, "wink-update", String(pid), staged.path, appURL.path, relaunch ? "1" : "0"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { NSLog("Couldn't start the Wink updater: %@", "\(error)") }
  }

  // MARK: - Helpers

  struct UpdateError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }

  /// 0.10.0 is newer than 0.9.2.
  static func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }
    let y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
      let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
      if p != q { return p > q }
    }
    return false
  }

  /// Release notes without Markdown noise, short enough for an alert.
  static func plainNotes(_ markdown: String) -> String {
    var text = markdown.replacingOccurrences(of: "\r", with: "")
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "`", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if text.count > 800 { text = String(text.prefix(800)) + "…" }
    return text
  }

  @discardableResult
  static func run(_ tool: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    guard p.terminationStatus == 0 else {
      throw UpdateError("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return text
  }

  private func alert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.runModal()
  }

  private func showError(_ title: String, _ error: Error) {
    alert(title, error.localizedDescription)
  }
}
