import Foundation

// Reads Blink Shell's configuration (hosts, public keys, appearance) from its
// App Group container and translates it into plain OpenSSH config files that
// the system `ssh` / `mosh` understand.
//
// Blink keeps private keys and passwords in its own keychain access group,
// which other apps cannot read. We export public keys so ssh can pick the
// matching key out of an agent, and prefer a private key file if you've put
// one at ~/.config/wink/keys/<name> or ~/.ssh/<name>.

struct BlinkHost {
  var alias: String
  var hostName: String?
  var port: Int?
  var user: String?
  var key: String?
  var proxyCommand: String?
  var proxyJump: String?
  var sshConfigAttachment: String?
  var forwardAgent = false
  var moshServer: String?
  var moshPort: Int?
  var moshPortEnd: Int?
  var moshStartup: String?
  var moshPrediction: Int?
  var moshExperimentalIP: Int?

  /// The name used on the ssh command line; ssh host names can't contain spaces.
  var sshAlias: String {
    alias.split(whereSeparator: \.isWhitespace).joined(separator: "-")
  }
}

struct BlinkAppearance {
  var themeName: String?
  var fontName: String?
  var fontSize: Int?
}

// NSCoding shims that stand in for Blink's archived classes.

@objc(WinkBKHosts)
private final class ArchivedHost: NSObject, NSCoding {
  var host: BlinkHost

  init?(coder c: NSCoder) {
    func s(_ k: String) -> String? {
      guard let v = c.decodeObject(forKey: k) as? String, !v.isEmpty else { return nil }
      return v
    }
    func n(_ k: String) -> Int? { (c.decodeObject(forKey: k) as? NSNumber)?.intValue }
    guard let alias = s("host") else { return nil }
    host = BlinkHost(alias: alias)
    host.hostName = s("hostName")
    host.port = n("port")
    host.user = s("user")
    host.key = s("key")
    host.proxyCommand = s("proxyCmd")
    host.proxyJump = s("proxyJump")
    host.sshConfigAttachment = s("sshConfigAttachment")
    host.forwardAgent = (n("agentForwardPrompt") ?? 0) > 0
    host.moshServer = s("moshServer")
    host.moshPort = n("moshPort")
    host.moshPortEnd = n("moshPortEnd")
    host.moshStartup = s("moshStartup")
    host.moshPrediction = n("prediction")
    host.moshExperimentalIP = n("moshExperimentalIP")
  }

  func encode(with coder: NSCoder) {}
}

@objc(WinkBKPubKey)
private final class ArchivedKey: NSObject, NSCoding {
  let id: String
  let publicKey: String?

  init?(coder c: NSCoder) {
    guard let id = c.decodeObject(forKey: "ID") as? String else { return nil }
    self.id = id
    publicKey = c.decodeObject(forKey: "publicKey") as? String
  }

  func encode(with coder: NSCoder) {}
}

@objc(WinkBLKDefaults)
private final class ArchivedDefaults: NSObject, NSCoding {
  let appearance: BlinkAppearance

  init?(coder c: NSCoder) {
    appearance = BlinkAppearance(
      themeName: c.decodeObject(forKey: "themeName") as? String,
      fontName: c.decodeObject(forKey: "fontName") as? String,
      fontSize: (c.decodeObject(forKey: "fontSize") as? NSNumber)?.intValue)
  }

  func encode(with coder: NSCoder) {}
}

final class BlinkConfig {
  static let shared = BlinkConfig()

  private(set) var hosts: [BlinkHost] = []
  private(set) var appearance = BlinkAppearance()
  private(set) var customThemes: [String: URL] = [:]
  /// Blink key name -> OpenSSH public key.
  private(set) var blinkKeys: [String: String] = [:]
  private(set) var lastError: String?

  static let winkDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/wink")
  static let hostsConfURL = winkDir.appendingPathComponent("blink_hosts.conf")
  static let launchConfURL = winkDir.appendingPathComponent("ssh_config")
  static let keysDir = winkDir.appendingPathComponent("keys")

  static let liveBlinkDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Group Containers/group.Com.CarlosCabanero.BlinkShell/home/.blink")
  /// Copy made by "Import Blink Config…", used when the live folder isn't readable.
  static let snapshotDir = winkDir.appendingPathComponent("blink-snapshot")
  static let snapshotFiles = ["hosts", "keys", "defaults", "Themes"]

  /// Where the config was last loaded from (nil if nowhere).
  private(set) var source: URL?

  /// Candidate `.blink` directories, best first. Override with
  /// `defaults write sh.wink.Wink BlinkConfigPath /path/to/.blink`.
  private var candidates: [URL] {
    if let custom = UserDefaults.standard.string(forKey: "BlinkConfigPath") {
      return [URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)]
    }
    return [Self.liveBlinkDir, Self.snapshotDir]
  }

  func reload() {
    lastError = nil
    source = nil
    var readErr: Error?
    for c in candidates {
      do {
        _ = try Data(contentsOf: c.appendingPathComponent("hosts"))
        source = c
        break
      } catch {
        readErr = readErr ?? error
      }
    }
    guard let dir = source else {
      NSLog("wink: can't read Blink hosts: \(readErr.map { "\($0)" } ?? "-")")
      hosts = []
      lastError = "macOS doesn't let other apps read Blink's data by default."
      return
    }

    hosts = (unarchive(dir.appendingPathComponent("hosts"),
                       classes: ["BKHosts": ArchivedHost.self]) as? [ArchivedHost] ?? [])
      .map(\.host)
      .sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }

    let keys = unarchive(dir.appendingPathComponent("keys"),
                         classes: ["BKPubKey": ArchivedKey.self]) as? [ArchivedKey] ?? []

    if let d = unarchive(dir.appendingPathComponent("defaults"),
                         classes: ["BLKDefaults": ArchivedDefaults.self,
                                   "BKDefaults": ArchivedDefaults.self]) as? ArchivedDefaults {
      appearance = d.appearance
    }

    customThemes = [:]
    let themesDir = dir.appendingPathComponent("Themes")
    for url in (try? FileManager.default.contentsOfDirectory(at: themesDir, includingPropertiesForKeys: nil)) ?? []
    where url.pathExtension == "js" {
      customThemes[url.deletingPathExtension().lastPathComponent] = url
    }

    do {
      try writeSSHConfig(keys: keys)
    } catch {
      lastError = "Failed to write \(Self.hostsConfURL.path): \(error.localizedDescription)"
      NSLog("wink: \(lastError!)")
    }
    NSLog("wink: loaded \(hosts.count) Blink hosts, \(keys.count) keys, theme \(appearance.themeName ?? "-")")
  }

  /// Copies the files Wink needs out of a `.blink` folder the user picked.
  func importSnapshot(from dir: URL) throws {
    let fm = FileManager.default
    guard fm.fileExists(atPath: dir.appendingPathComponent("hosts").path) else {
      throw NSError(domain: "Wink", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "\(dir.path) doesn't look like Blink's .blink folder (no hosts file)."])
    }
    try? fm.removeItem(at: Self.snapshotDir)
    try fm.createDirectory(at: Self.snapshotDir, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])
    for name in Self.snapshotFiles {
      let src = dir.appendingPathComponent(name)
      if fm.fileExists(atPath: src.path) {
        try fm.copyItem(at: src, to: Self.snapshotDir.appendingPathComponent(name))
      }
    }
  }

  private func unarchive(_ url: URL, classes: [String: AnyClass]) -> Any? {
    guard let data = try? Data(contentsOf: url),
          let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    u.requiresSecureCoding = false
    for (name, cls) in classes { u.setClass(cls, forClassName: name) }
    defer { u.finishDecoding() }
    return u.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
  }

  // MARK: - ssh config generation

  private func writeSSHConfig(keys: [ArchivedKey]) throws {
    let fm = FileManager.default
    blinkKeys = [:]
    try fm.createDirectory(at: Self.keysDir, withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])

    var pubs: [String: String] = [:]
    for key in keys {
      guard let pub = key.publicKey, !pub.isEmpty else { continue }
      pubs[key.id] = pub
      blinkKeys[key.id] = pub
      let url = Self.keysDir.appendingPathComponent(key.id + ".pub")
      try (pub.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
        .write(to: url, atomically: true, encoding: .utf8)
    }

    var out = "# Generated by Wink from Blink Shell's hosts. Regenerated on every launch;\n"
    out += "# edit your hosts in Blink (or put overrides in ~/.ssh/config).\n\n"
    for h in hosts {
      out += "Host \(h.sshAlias)\n"
      if let v = h.hostName { out += "  HostName \(v)\n" }
      if let v = h.user { out += "  User \(quote(v))\n" }
      if let v = h.port { out += "  Port \(v)\n" }
      if let key = h.key, key != "None", let path = identityPath(for: key, blinkPub: pubs[key]) {
        out += "  IdentityFile \(quote(path))\n"
      }
      if let v = h.proxyCommand { out += "  ProxyCommand \(v)\n" }
      if let v = h.proxyJump { out += "  ProxyJump \(v)\n" }
      if h.forwardAgent { out += "  ForwardAgent yes\n" }
      for line in (h.sshConfigAttachment ?? "").split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !trimmed.hasPrefix("#") { out += "  \(trimmed)\n" }
      }
      out += "\n"
    }
    try out.write(to: Self.hostsConfURL, atomically: true, encoding: .utf8)

    try Self.writeLaunchConfig()
  }

  /// The file `ssh -F` gets for Hosts menu connections: your ~/.ssh/config
  /// first (ssh keeps the first value it sees, so local edits win), then
  /// Blink's hosts.
  static func writeLaunchConfig() throws {
    try FileManager.default.createDirectory(at: winkDir, withIntermediateDirectories: true)
    let launch = """
      # Generated by Wink. Used by the Hosts menu.
      Include ~/.ssh/config

      Match all
        Include \(hostsConfURL.path)

      """
    try launch.write(to: launchConfURL, atomically: true, encoding: .utf8)
  }

  private func identityPath(for keyName: String, blinkPub: String?) -> String? {
    let fm = FileManager.default
    let sshKey = fm.homeDirectoryForCurrentUser.appendingPathComponent(".ssh").appendingPathComponent(keyName)
    // ~/.ssh/<name> only counts if it's the same key Blink has under that name.
    let sshKeyMatches: Bool = {
      guard fm.fileExists(atPath: sshKey.path) else { return false }
      guard let blinkPub else { return true }
      let local = (try? String(contentsOf: sshKey.appendingPathExtension("pub"), encoding: .utf8)) ?? ""
      return keyBlob(local) != nil && keyBlob(local) == keyBlob(blinkPub)
    }()
    let candidates = [
      Self.keysDir.appendingPathComponent(keyName),
      sshKeyMatches ? sshKey : nil,
      Self.keysDir.appendingPathComponent(keyName + ".pub"), // resolved via ssh-agent
    ].compactMap { $0 }
    return candidates.first { fm.fileExists(atPath: $0.path) }?.path
  }

  private func keyBlob(_ pub: String) -> Substring? {
    let parts = pub.split(separator: " ")
    return parts.count >= 2 ? parts[1] : nil
  }

  private func quote(_ s: String) -> String {
    s.contains(where: { $0 == " " || $0 == "\t" }) ? "\"\(s)\"" : s
  }

  // MARK: - commands

  func sshCommand(for host: BlinkHost) -> [String] {
    try? Self.writeLaunchConfig()
    return ["ssh", "-F", Self.launchConfURL.path, host.sshAlias]
  }

  func moshCommand(for host: BlinkHost) -> [String] {
    try? Self.writeLaunchConfig()
    var cmd = ["mosh", "--ssh=ssh -F \(Self.launchConfURL.path)"]
    if let server = host.moshServer { cmd.append("--server=\(server)") }
    if let port = host.moshPort {
      cmd.append("--port=\(port)" + (host.moshPortEnd.map { ":\($0)" } ?? ""))
    }
    switch host.moshPrediction {
    case 1: cmd.append("--predict=always")
    case 2: cmd.append("--predict=never")
    case 3: cmd.append("--predict=experimental")
    default: break
    }
    switch host.moshExperimentalIP {
    case 1: cmd.append("--experimental-remote-ip=local")
    case 2: cmd.append("--experimental-remote-ip=remote")
    default: break
    }
    cmd.append(host.sshAlias)
    if let startup = host.moshStartup {
      cmd += ["--", "sh", "-c", startup]
    }
    return cmd
  }
}
