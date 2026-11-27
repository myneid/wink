import AppKit

/// Wink's side of the `database` capability: AppKit dialogs and SSH tunnels
/// (`ssh -L` with Wink's ssh config). The API itself, the MySQL client and
/// the saved connections live in the platform-neutral DatabaseBridge.swift,
/// MySQLClient.swift and DatabaseURL.swift, which Blink shares.
@MainActor final class DatabaseWorkbench: DatabaseHostUI {
  /// Hosts for the SSH menu and for matching URLs. Set by the app at launch.
  static var sshHosts: () -> [DatabaseSSHHost] = { [] }
  /// The `ssh -F` file Wink's connections use. Set by the app at launch.
  static var sshConfigPath: () -> String? = { nil }
  /// Tests point this at a fixture.
  static var storeOverride: URL?

  static var storeURL: URL {
    storeOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/wink/databases.json")
  }

  private let appName: String
  private var bridge: DatabaseBridge!

  init(appName: String, owner: String) {
    self.appName = appName
    let environment = DatabaseHostEnvironment(
      storeURL: Self.storeURL, keychainService: "Wink Database", sshHosts: { Self.sshHosts() },
      openTunnel: { destination in try await SSHTunnel.open(destination: destination, config: Self.sshConfigPath()) })
    bridge = DatabaseBridge(appName: appName, owner: owner, environment: environment, ui: self)
  }

  func call(_ method: String, _ args: [String: Any]) async throws -> Any { try await bridge.call(method, args) }

  func close() { bridge.close() }

  /// Ends every tunnel; call when Wink quits.
  static func terminateAll() { SSHTunnel.closeAll() }

  // MARK: - DatabaseHostUI

  func editConnection(_ draft: DatabaseConnection, password: String?, hasSavedPassword: Bool, title: String,
                      problem: String?, sshHosts: [DatabaseSSHHost]) async -> (connection: DatabaseConnection, password: String)? {
    let form = ConnectionForm(draft, password: password, hasSavedPassword: hasSavedPassword, sshHosts: sshHosts)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = problem.map { "⚠️ " + $0 } ?? "\(appName) can run queries on this connection while its tab is open."
    alert.accessoryView = form.view
    alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = draft.user.isEmpty && password == nil ? form.url : form.name
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    var edited = draft
    form.apply(to: &edited)
    return (edited, form.password.stringValue)
  }

  func askForURL(prefill: String, problem: String?) async -> String? {
    let alert = NSAlert()
    alert.messageText = "Import Connection from URL"
    alert.informativeText = problem ?? "Paste a MySQL or MariaDB URL, for example\nmysql://user:password@host:3306/database\nTablePlus mysql+ssh:// URLs and DATABASE_URL=… lines work too. Add ?ssh=alias to connect through one of your SSH hosts."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 460, height: 24))
    field.placeholderString = "mysql://user:password@host:3306/database"
    field.stringValue = prefill
    alert.accessoryView = field
    alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
  }

  func confirmRemove(_ connection: DatabaseConnection) async -> Bool {
    let alert = NSAlert()
    alert.messageText = "Delete “\(connection.title)”?"
    alert.informativeText = "The connection and its saved password are removed from Wink. The database itself is not touched."
    alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
    alert.buttons[0].hasDestructiveAction = true
    return alert.runModal() == .alertFirstButtonReturn
  }

  func askIncludePassword(_ connection: DatabaseConnection) async -> Bool? {
    let alert = NSAlert()
    alert.messageText = "Copy URL for “\(connection.title)”"
    alert.informativeText = "Anyone you share a URL with a password can sign in as \(connection.user)."
    alert.addButton(withTitle: "Copy Without Password")
    alert.addButton(withTitle: "Copy With Password")
    alert.addButton(withTitle: "Cancel")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return false
    case .alertSecondButtonReturn: return true
    default: return nil
    }
  }

  func setClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  func clipboard() -> String? { NSPasteboard.general.string(forType: .string) }
}

// MARK: - Connection form

@MainActor private final class ConnectionForm: NSObject, NSTextFieldDelegate {
  let url = NSTextField()
  let name = NSTextField()
  let environment = NSPopUpButton()
  let host = NSTextField()
  let port = NSTextField()
  let user = NSTextField()
  let password = NSSecureTextField()
  let database = NSTextField()
  let ssh = NSComboBox()
  let readOnly = NSButton(checkboxWithTitle: "Read-only (block writes in this session)", target: nil, action: nil)
  let ssl = NSButton(checkboxWithTitle: "Require SSL/TLS", target: nil, action: nil)
  let hint = NSTextField(labelWithString: "")
  let view: NSView
  private var color: String
  private let sshHosts: [DatabaseSSHHost]

  init(_ c: DatabaseConnection, password secret: String?, hasSavedPassword: Bool, sshHosts: [DatabaseSSHHost]) {
    self.sshHosts = sshHosts
    color = c.color
    url.placeholderString = "Paste mysql://user:password@host:3306/db to fill in"
    name.placeholderString = "Optional"
    name.stringValue = c.name
    environment.addItems(withTitles: ["None", "Local", "Development", "Testing", "Staging", "Production"])
    environment.selectItem(at: DatabaseConnection.environments.firstIndex(of: c.environment) ?? 0)
    host.stringValue = c.host
    host.placeholderString = "127.0.0.1"
    port.stringValue = String(c.port)
    user.stringValue = c.user
    password.stringValue = secret ?? ""
    password.placeholderString = hasSavedPassword ? "Saved in Keychain — leave blank to keep" : "None"
    database.stringValue = c.database
    database.placeholderString = "Optional — choose after connecting"
    ssh.addItems(withObjectValues: sshHosts.map(\.alias))
    ssh.stringValue = c.ssh
    ssh.placeholderString = "None — connect directly"
    ssh.completes = true
    ssh.numberOfVisibleItems = 14
    readOnly.state = c.readOnly ? .on : .off
    ssl.state = c.ssl ? .on : .off
    hint.textColor = .secondaryLabelColor
    hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    hint.stringValue = "With SSH, Host is as seen from the SSH server (usually 127.0.0.1)."
    let rows: [(String, NSView)] = [
      ("URL", url), ("Name", name), ("Environment", environment), ("Over SSH", ssh), ("Host", host), ("Port", port),
      ("User", user), ("Password", password), ("Database", database), ("", readOnly), ("", ssl), ("", hint)]
    let grid = NSGridView(views: rows.map { [NSTextField(labelWithString: $0.0), $0.1] })
    grid.rowSpacing = 6
    grid.column(at: 0).xPlacement = .trailing
    for (_, field) in rows where field is NSTextField && field !== hint || field is NSComboBox || field is NSPopUpButton {
      field.widthAnchor.constraint(equalToConstant: 320).isActive = true
    }
    grid.frame = NSRect(x: 0, y: 0, width: 420, height: grid.fittingSize.height)
    view = grid
    super.init()
    url.delegate = self
  }

  func controlTextDidChange(_ note: Notification) {
    guard (note.object as? NSTextField) === url else { return }
    let text = url.stringValue
    guard !text.isEmpty else { hint.stringValue = ""; return }
    do {
      let parsed = try DatabaseURL.parse(text, sshHosts: sshHosts)
      let c = parsed.connection
      if !c.name.isEmpty { name.stringValue = c.name }
      host.stringValue = c.host; port.stringValue = String(c.port)
      user.stringValue = c.user; database.stringValue = c.database
      ssh.stringValue = c.ssh
      if let p = parsed.password { password.stringValue = p }
      readOnly.state = c.readOnly ? .on : .off
      ssl.state = c.ssl ? .on : .off
      if !c.environment.isEmpty { environment.selectItem(at: DatabaseConnection.environments.firstIndex(of: c.environment) ?? 0) }
      if !c.color.isEmpty { color = c.color }
      hint.stringValue = "✓ Filled in from the URL" + (c.ssh.isEmpty ? "." : " (SSH via \(c.ssh)).")
      hint.textColor = .systemGreen
    } catch {
      hint.stringValue = error.localizedDescription
      hint.textColor = .systemOrange
    }
  }

  func apply(to c: inout DatabaseConnection) {
    let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    c.name = trim(name.stringValue)
    c.environment = DatabaseConnection.environments[max(0, environment.indexOfSelectedItem)]
    c.host = trim(host.stringValue).isEmpty ? "127.0.0.1" : trim(host.stringValue)
    c.port = Int(trim(port.stringValue)) ?? 0
    c.user = trim(user.stringValue)
    c.database = trim(database.stringValue)
    c.ssh = trim(ssh.stringValue)
    c.readOnly = readOnly.state == .on
    c.ssl = ssl.state == .on
    c.color = color
  }
}

// MARK: - SSH tunnel

/// `ssh -N -D` (a local SOCKS proxy) to a Wink/Blink host, using Wink's ssh config (so Blink's
/// hosts, keys and ProxyJump work). Lives as long as the tab's connection.
final class SSHTunnel: DatabaseTunnel, @unchecked Sendable {
  private static let lock = NSLock()
  private static var live: [ObjectIdentifier: Process] = [:]

  let localPort: Int
  private let process: Process
  private let errors: Pipe

  var isAlive: Bool { process.isRunning }

  /// A SOCKS5 CONNECT through the tunnel to host:port on the server's side.
  func openStream(host: String, port: Int) throws -> MySQLTransport {
    let socket = try SocketTransport(host: "127.0.0.1", port: localPort, timeout: 10)
    func send(_ bytes: [UInt8]) throws { try bytes.withUnsafeBytes { try socket.write($0) } }
    func receive(_ count: Int) throws -> [UInt8] {
      var out = [UInt8](repeating: 0, count: count)
      var got = 0
      while got < count {
        let n = try out.withUnsafeMutableBytes { try socket.read(UnsafeMutableRawBufferPointer(rebasing: $0[got...])) }
        if n == 0 { throw DatabaseFailure("The SSH tunnel closed.") }
        got += n
      }
      return out
    }
    let name = Array(host.utf8)
    guard !name.isEmpty, name.count < 256 else { throw DatabaseFailure("Invalid database host.") }
    try send([5, 1, 0])
    guard try receive(2) == [5, 0] else { throw DatabaseFailure("The SSH tunnel refused the connection.") }
    try send([5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xFF)])
    let reply = try receive(4)
    guard reply[1] == 0 else {
      socket.close()
      throw DatabaseFailure("The SSH server couldn't reach \(host):\(port) (SOCKS error \(reply[1])).")
    }
    switch reply[3] {
    case 1: _ = try receive(6)
    case 4: _ = try receive(18)
    default: _ = try receive(Int(try receive(1)[0]) + 2)
    }
    return socket
  }

  private init(process: Process, errors: Pipe, localPort: Int) {
    self.process = process; self.errors = errors; self.localPort = localPort
    Self.lock.withLock { Self.live[ObjectIdentifier(self)] = process }
  }

  deinit { close() }

  func close() {
    if process.isRunning { process.terminate() }
    Self.lock.withLock { _ = Self.live.removeValue(forKey: ObjectIdentifier(self)) }
  }

  static func closeAll() {
    lock.withLock { for p in live.values where p.isRunning { p.terminate() }; live = [:] }
  }

  static func open(destination: String, config: String?) async throws -> SSHTunnel {
    guard let target = DatabaseURL.sshDestination(destination) else {
      throw DatabaseFailure("Enter an SSH host alias or user@host[:port].")
    }
    let port = try freePort()
    var args: [String] = []
    if let config, FileManager.default.fileExists(atPath: config) { args += ["-F", config] }
    args += ["-N", "-T",
             "-o", "ExitOnForwardFailure=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
             "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
             "-o", "StrictHostKeyChecking=accept-new", "-o", "ClearAllForwardings=no",
             "-D", "127.0.0.1:\(port)"]
    if let p = target.port { args += ["-p", String(p)] }
    if let user = target.user { args += ["-l", user] }
    args += ["--", target.host]

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = args
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    try process.run()
    let tunnel = SSHTunnel(process: process, errors: errors, localPort: port)

    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if !process.isRunning {
        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("Warning: Permanently added") }
        var message = lines.suffix(3).joined(separator: " ")
        if message.isEmpty { message = "ssh exited with status \(process.terminationStatus)." }
        if message.contains("Permission denied") {
          message += " Wink's tunnels use your SSH keys or agent (password prompts aren't supported)."
        }
        tunnel.close()
        throw DatabaseFailure("SSH to \(destination) failed: \(message)")
      }
      if canConnect(port) { return tunnel }
      try await Task.sleep(for: .milliseconds(150))
    }
    tunnel.close()
    throw DatabaseFailure("SSH to \(destination) timed out.")
  }

  private static func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw DatabaseFailure("No free local port.") }
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
      }
    }
    guard ok else { throw DatabaseFailure("No free local port.") }
    return Int(UInt16(bigEndian: addr.sin_port))
  }

  private static func canConnect(_ port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = UInt16(port).bigEndian
    return withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
      }
    }
  }
}
