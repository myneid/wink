import AppKit

// The Hosts menu: Blink's hosts, your ~/.ssh/config hosts, and the pieces
// that move config and keys between Wink and Blink.
final class HostsMenuController: NSObject, NSMenuDelegate {
  let menu = NSMenu(title: "Hosts")
  private var syncTimer: Timer?
  private var app: AppDelegate { NSApp.delegate as! AppDelegate }

  override init() {
    super.init()
    menu.delegate = self
  }

  func didLaunch() {
    rebuild()
    startSyncIfEnabled()
    if BlinkConfig.shared.source == nil, !UserDefaults.standard.bool(forKey: "didOfferBlinkImport") {
      UserDefaults.standard.set(true, forKey: "didOfferBlinkImport")
      DispatchQueue.main.async { self.offerBlinkAccess() }
    }
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    syncToBlinkIfEnabled()
    rebuild()
  }

  // MARK: - Building

  private func rebuild() {
    menu.removeAllItems()
    let blinkHosts = BlinkConfig.shared.hosts
    let blinkAliases = Set(blinkHosts.map(\.sshAlias))
    let localHosts = LocalSSHConfig.hostAliases().filter { !blinkAliases.contains($0) }

    header(BlinkConfig.shared.source == nil ? "Blink (not readable)" : "Blink")
    if blinkHosts.isEmpty && BlinkConfig.shared.source != nil { disabled("No hosts") }
    for h in blinkHosts {
      let tip = [h.user.map { "\($0)@" } ?? "", h.hostName ?? h.alias, h.port.map { ":\($0)" } ?? ""].joined()
      addHost(h, title: h.alias, tip: tip)
    }

    menu.addItem(.separator())
    header("~/.ssh/config")
    if localHosts.isEmpty { disabled("No hosts") }
    for alias in localHosts { addHost(BlinkHost(alias: alias), title: alias, tip: nil) }

    menu.addItem(.separator())
    disabled("Hold ⌥ to connect with mosh")
    item("Edit ~/.ssh/config", #selector(editLocalConfig(_:)), key: "e", mods: [.command, .shift])
    item("Show Generated ssh_config", #selector(revealSSHConfig(_:)))

    menu.addItem(.separator())
    let blink = NSMenu(title: "Blink")
    let blinkItem = NSMenuItem(title: "Blink", action: nil, keyEquivalent: "")
    blinkItem.submenu = blink
    menu.addItem(blinkItem)
    buildBlinkMenu(blink)
  }

  private func buildBlinkMenu(_ m: NSMenu) {
    func add(_ title: String, _ action: Selector?, _ target: AnyObject? = nil) -> NSMenuItem {
      let i = m.addItem(withTitle: title, action: action, keyEquivalent: "")
      i.target = target ?? self
      return i
    }
    m.addItem(withTitle: "From Blink", action: nil, keyEquivalent: "").isEnabled = false
    _ = add("Import Blink Config…", #selector(importBlinkConfig(_:)))
    _ = add("Reload Blink Config", #selector(reloadBlinkConfig(_:)))
    _ = add("Save Private Key from Clipboard…", #selector(saveKeyFromClipboard(_:)))
    if let src = BlinkConfig.shared.source {
      let from = src == BlinkConfig.snapshotDir ? "imported copy" : "Blink's folder"
      m.addItem(withTitle: "Source: \(from)", action: nil, keyEquivalent: "").isEnabled = false
    }

    m.addItem(.separator())
    m.addItem(withTitle: "To Blink", action: nil, keyEquivalent: "").isEnabled = false
    let share = add("Share ~/.ssh/config with Blink", #selector(toggleShare(_:)))
    share.state = Settings.shared.shareWithBlink ? .on : .off
    _ = add("Copy Blink Setup Command", #selector(copySetupCommand(_:)))

    let keysItem = NSMenuItem(title: "Copy Private Key for Blink", action: nil, keyEquivalent: "")
    let keysMenu = NSMenu()
    let exported = LocalSSHConfig.blinkExport().keys
    let all = LocalSSHConfig.localPrivateKeys().merging(exported) { _, e in e }
    for name in all.keys.sorted(by: { (exported[$0] != nil ? 0 : 1, $0) < (exported[$1] != nil ? 0 : 1, $1) }) {
      let i = keysMenu.addItem(withTitle: name, action: #selector(copyKeyForBlink(_:)), keyEquivalent: "")
      i.target = self
      i.representedObject = all[name]
      let inBlink = BlinkConfig.shared.blinkKeys[name] != nil
      i.toolTip = inBlink ? "Blink already has a key named \(name)" : all[name]?.path
      if inBlink { i.title = "\(name)  (in Blink)" }
    }
    if all.isEmpty { keysMenu.addItem(withTitle: "No private keys found", action: nil, keyEquivalent: "").isEnabled = false }
    keysItem.submenu = keysMenu
    m.addItem(keysItem)
  }

  private func header(_ title: String) {
    let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    i.isEnabled = false
    i.attributedTitle = NSAttributedString(string: title, attributes: [
      .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
      .foregroundColor: NSColor.secondaryLabelColor,
    ])
    menu.addItem(i)
  }

  private func disabled(_ title: String) {
    menu.addItem(withTitle: title, action: nil, keyEquivalent: "").isEnabled = false
  }

  private func item(_ title: String, _ action: Selector, key: String = "", mods: NSEvent.ModifierFlags = .command) {
    let i = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
    i.keyEquivalentModifierMask = mods
    i.target = self
  }

  private func addHost(_ h: BlinkHost, title: String, tip: String?) {
    let box = HostBox(h)
    let ssh = menu.addItem(withTitle: title, action: #selector(connectSSH(_:)), keyEquivalent: "")
    ssh.target = self
    ssh.representedObject = box
    ssh.toolTip = tip
    ssh.indentationLevel = 1
    let mosh = menu.addItem(withTitle: title + " (mosh)", action: #selector(connectMosh(_:)), keyEquivalent: "")
    mosh.target = self
    mosh.representedObject = box
    mosh.keyEquivalentModifierMask = .option
    mosh.isAlternate = true
    mosh.indentationLevel = 1
  }

  // MARK: - Connecting and editing

  @objc private func connectSSH(_ sender: NSMenuItem) {
    guard let h = (sender.representedObject as? HostBox)?.host else { return }
    app.open(TerminalWindowController(command: BlinkConfig.shared.sshCommand(for: h), title: h.alias), asTab: true)
  }

  @objc private func connectMosh(_ sender: NSMenuItem) {
    guard let h = (sender.representedObject as? HostBox)?.host else { return }
    app.open(TerminalWindowController(command: BlinkConfig.shared.moshCommand(for: h), title: h.alias + " (mosh)"),
             asTab: true)
  }

  @objc private func editLocalConfig(_ sender: Any?) {
    let fm = FileManager.default
    let url = LocalSSHConfig.configURL
    if !fm.fileExists(atPath: url.path) {
      try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])
      fm.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
    }
    let term = TerminalWindowController(
      command: ["sh", "-c", "exec ${EDITOR:-vi} \"$HOME/.ssh/config\""], title: "~/.ssh/config")
    term.onClose = { [weak self] in self?.syncToBlinkIfEnabled() }
    app.open(term, asTab: true)
  }

  @objc private func revealSSHConfig(_ sender: Any?) {
    try? BlinkConfig.writeLaunchConfig()
    NSWorkspace.shared.activateFileViewerSelecting([BlinkConfig.launchConfURL])
  }

  // MARK: - From Blink

  @objc private func reloadBlinkConfig(_ sender: Any?) {
    BlinkConfig.shared.reload()
    if BlinkConfig.shared.source == nil { offerBlinkAccess() }
  }

  private func offerBlinkAccess() {
    let alert = NSAlert()
    alert.messageText = "Use your Blink hosts and keys?"
    alert.informativeText = """
      \(BlinkConfig.shared.lastError ?? "Blink's config isn't readable.")

      Import: pick Blink's .blink folder once and Wink keeps a copy (re-import after changing hosts in Blink).

      Full Disk Access: Wink reads Blink's config live. Add Wink in System Settings, then relaunch it.
      """
    alert.addButton(withTitle: "Import…")
    alert.addButton(withTitle: "Open Full Disk Access")
    alert.addButton(withTitle: "Not Now")
    switch alert.runModal() {
    case .alertFirstButtonReturn: importBlinkConfig(nil)
    case .alertSecondButtonReturn:
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    default: break
    }
  }

  @objc private func importBlinkConfig(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.message = "Select Blink's “.blink” folder, then click Import."
    panel.prompt = "Import"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.showsHiddenFiles = true
    panel.treatsFilePackagesAsDirectories = true
    panel.directoryURL = BlinkConfig.liveBlinkDir
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try BlinkConfig.shared.importSnapshot(from: url)
      BlinkConfig.shared.reload()
      let alert = NSAlert()
      alert.messageText = "Imported \(BlinkConfig.shared.hosts.count) hosts from Blink"
      alert.informativeText = "They're in the Hosts menu. SSH config: \(BlinkConfig.launchConfURL.path)"
      alert.runModal()
    } catch {
      NSAlert(error: error).runModal()
    }
  }

  /// Saves a private key copied from Blink (Settings ▸ Keys ▸ key ▸ Copy
  /// Private Key) so ssh can use it for that key's hosts.
  @objc private func saveKeyFromClipboard(_ sender: Any?) {
    let pb = NSPasteboard.general
    guard let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
          text.hasPrefix("-----BEGIN"), text.contains("PRIVATE KEY-----") else {
      let alert = NSAlert()
      alert.messageText = "No private key on the clipboard"
      alert.informativeText = "In Blink, open Settings ▸ Keys, pick the key and choose Copy Private Key. Then try again."
      alert.runModal()
      return
    }

    let missing = BlinkConfig.shared.blinkKeys.keys.sorted().filter {
      !FileManager.default.fileExists(atPath: BlinkConfig.keysDir.appendingPathComponent($0).path)
    }
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
    field.stringValue = missing.first ?? "id_ed25519"
    let alert = NSAlert()
    alert.messageText = "Save private key"
    alert.informativeText = "Use the key's name in Blink so hosts that use it pick it up. Saved to \(BlinkConfig.keysDir.path)."
    alert.accessoryView = field
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    let name = field.stringValue.filter { $0.isLetter || $0.isNumber || "._-".contains($0) }
    guard !name.isEmpty else { return }
    let url = BlinkConfig.keysDir.appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: BlinkConfig.keysDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    try? FileManager.default.removeItem(at: url)
    guard FileManager.default.createFile(atPath: url.path, contents: Data((text + "\n").utf8),
                                         attributes: [.posixPermissions: 0o600]) else {
      NSAlert(error: CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])).runModal()
      return
    }
    pb.clearContents()

    var note = "Saved \(url.path)."
    if let derived = publicKey(of: url), let blinkPub = BlinkConfig.shared.blinkKeys[name] {
      note += blob(derived) == blob(blinkPub)
        ? " It matches Blink's “\(name)” key."
        : " Warning: it does NOT match Blink's “\(name)” key."
    }
    BlinkConfig.shared.reload()
    let done = NSAlert()
    done.messageText = "Key saved"
    done.informativeText = note + " The clipboard was cleared."
    done.runModal()
  }

  private func publicKey(of url: URL) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    p.arguments = ["-y", "-P", "", "-f", url.path] // fails quietly for passphrase-protected keys
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  }

  private func blob(_ pub: String) -> Substring? {
    let parts = pub.split(separator: " ")
    return parts.count >= 2 ? parts[1] : nil
  }

  // MARK: - To Blink

  @objc private func toggleShare(_ sender: Any?) {
    Settings.shared.shareWithBlink.toggle()
    if Settings.shared.shareWithBlink {
      do {
        let export = try LocalSSHConfig.writeBlinkExport()
        startSyncIfEnabled()
        showSetupInstructions(keys: export.keys.keys.sorted())
      } catch {
        Settings.shared.shareWithBlink = false
        NSAlert(error: error).runModal()
      }
    } else {
      syncTimer?.invalidate()
      syncTimer = nil
    }
  }

  private func showSetupInstructions(keys: [String]) {
    let missing = keys.filter { BlinkConfig.shared.blinkKeys[$0] == nil }
    var text = """
      Wink now keeps a Blink-friendly copy of your ~/.ssh/config in Blink's iCloud Drive (~/iCloud/wink/ssh_config in Blink). It updates whenever your config changes while Wink is running.

      One-time setup in Blink (on each device): run these two lines in a Blink shell. “Copy Setup Command” puts them on the clipboard.

        \(LocalSSHConfig.blinkSetupCommands.joined(separator: "\n  "))

      Hosts you define in Blink itself keep priority over the shared ones.
      """
    if !missing.isEmpty {
      text += "\n\nYour hosts use keys Blink doesn't have yet: \(missing.joined(separator: ", ")). "
        + "Use Blink ▸ Copy Private Key for Blink, then in Blink: Settings ▸ Keys ▸ + ▸ Import from Clipboard, with the same name."
    }
    let alert = NSAlert()
    alert.messageText = "Sharing ~/.ssh/config with Blink"
    alert.informativeText = text
    alert.addButton(withTitle: "Copy Setup Command")
    alert.addButton(withTitle: "Done")
    if alert.runModal() == .alertFirstButtonReturn { copySetupCommand(nil) }
  }

  static let setupCommand = LocalSSHConfig.blinkSetupCommands.joined(separator: "\n")

  @objc private func copySetupCommand(_ sender: Any?) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(Self.setupCommand, forType: .string)
  }

  @objc private func copyKeyForBlink(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL,
          let key = try? String(contentsOf: url, encoding: .utf8) else { return }
    let name = url.lastPathComponent
    let pb = NSPasteboard.general
    pb.clearContents()
    // Concealed: clipboard managers that honor this won't record the key.
    pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
    pb.setString(key, forType: .string)
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let change = pb.changeCount
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
      if pb.changeCount == change { pb.clearContents() }
    }

    let alert = NSAlert()
    alert.messageText = "Private key “\(name)” copied"
    alert.informativeText = """
      In Blink: Settings ▸ Keys ▸ + ▸ Import from Clipboard, and name it “\(name)” so your hosts' IdentityFile \(name) finds it. On an iPad, Universal Clipboard carries it over.

      The clipboard is cleared in 90 seconds.
      """
    alert.runModal()
  }

  // MARK: - Sync

  private func startSyncIfEnabled() {
    guard Settings.shared.shareWithBlink, syncTimer == nil else { return }
    syncToBlinkIfEnabled()
    syncTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      self?.syncToBlinkIfEnabled()
    }
  }

  private func syncToBlinkIfEnabled() {
    guard Settings.shared.shareWithBlink else { return }
    do { try LocalSSHConfig.writeBlinkExport() } catch { NSLog("wink: Blink export failed: \(error)") }
  }
}

private final class HostBox: NSObject {
  let host: BlinkHost
  init(_ host: BlinkHost) { self.host = host }
}
