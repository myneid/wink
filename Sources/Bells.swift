import Foundation
import Security

// Blink Bell, as a sender only.
//
// Bells are made in Blink (iOS, or Blink on this Mac), which holds their keys
// and receives their rings. Wink never talks to the relay's management API:
// it keeps the `BLINK_BELL` values you paste in, puts the right one into each
// tab, and answers the shell integration's in-band query with it. Anything
// holding that value can ring the bell; that's the protocol's sender model.
//
// The value is `<token>` or `<token>.<content secret>` (standard base64, 32
// bytes). It's kept in the Keychain; the bell's name, hosts and default flag
// live in UserDefaults.

struct Bell: Codable, Equatable {
  var id: String
  var name: String
  var hosts: [String]
  var isDefault: Bool
}

final class BellStore {
  static let shared = BellStore()
  private let defaultsKey = "bells"
  private let keychainService = "sh.wink.Wink.bells"

  private(set) var bells: [Bell] = []
  /// Values read once at launch: the shell integration gives up after ~50ms,
  /// and a first Keychain read alone can take most of that.
  private var values: [String: String] = [:]

  init() {
    if let data = UserDefaults.standard.data(forKey: defaultsKey),
       let saved = try? JSONDecoder().decode([Bell].self, from: data) {
      bells = saved
    }
    for bell in bells { values[bell.id] = readKeychain(bell.id) }
  }

  /// Relay for test rings; `defaults write sh.wink.Wink BellRelay URL` for a
  /// staging or local relay. Also exported to tabs as BLINK_BELL_RELAY.
  var relayURL: String {
    UserDefaults.standard.string(forKey: "BellRelay") ?? "https://bell.blink.sh"
  }
  var isCustomRelay: Bool { UserDefaults.standard.string(forKey: "BellRelay") != nil }

  // MARK: - Values

  /// Extracts a BLINK_BELL value from what people paste: `export BLINK_BELL='…'`,
  /// `BLINK_BELL=…`, or the bare value. Nil if it isn't one.
  static func parseValue(_ text: String) -> String? {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if let line = s.split(whereSeparator: \.isNewline).first(where: { $0.contains("BLINK_BELL=") }) {
      s = String(line)
    }
    if s.hasPrefix("export ") { s = String(s.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
    if s.hasPrefix("BLINK_BELL=") { s = String(s.dropFirst("BLINK_BELL=".count)) }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
    return isValidValue(s) ? s : nil
  }

  static func isValidValue(_ value: String) -> Bool {
    let parts = value.split(separator: ".", maxSplits: 1).map(String.init)
    guard let token = parts.first, token.hasPrefix("bell_"), token.count >= 20,
          token.dropFirst(5).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
    if parts.count == 2 { return Data(base64Encoded: parts[1])?.count == 32 }
    return true
  }

  static func token(of value: String) -> String {
    String(value.split(separator: ".", maxSplits: 1).first ?? "")
  }

  func value(of bell: Bell) -> String? {
    if let value = values[bell.id] { return value }
    let value = readKeychain(bell.id)
    values[bell.id] = value
    return value
  }

  private func readKeychain(_ id: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
      kSecAttrAccount as String: id, kSecReturnData as String: true,
    ]
    var out: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  // MARK: - Editing

  @discardableResult
  func add(name: String, value: String, hosts: [String], isDefault: Bool) -> Bool {
    let bell = Bell(id: UUID().uuidString, name: name, hosts: hosts, isDefault: isDefault)
    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
      kSecAttrAccount as String: bell.id, kSecAttrLabel as String: "Wink bell: \(name)",
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
    if isDefault { for i in bells.indices { bells[i].isDefault = false } }
    bells.append(bell)
    values[bell.id] = value
    save()
    return true
  }

  func update(_ bell: Bell) {
    guard let i = bells.firstIndex(where: { $0.id == bell.id }) else { return }
    if bell.isDefault { for j in bells.indices { bells[j].isDefault = false } }
    bells[i] = bell
    save()
  }

  func remove(_ bell: Bell) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
      kSecAttrAccount as String: bell.id,
    ]
    SecItemDelete(query as CFDictionary)
    values[bell.id] = nil
    bells.removeAll { $0.id == bell.id }
    save()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(bells) { UserDefaults.standard.set(data, forKey: defaultsKey) }
  }

  // MARK: - Choosing

  /// The bell for a host alias, else the default bell.
  func bell(forHost host: String?) -> Bell? {
    if let host = host?.lowercased(), !host.isEmpty,
       let match = bells.first(where: { $0.hosts.contains { $0.lowercased() == host } }) {
      return match
    }
    return bells.first(where: \.isDefault)
  }

  // MARK: - Test ring

  /// Sends a plain (unencrypted) loud message, the way `curl` does. Returns a
  /// short human answer. A bell set to require encryption refuses it (422).
  func testRing(_ bell: Bell, completion: @escaping (String) -> Void) {
    guard let value = value(of: bell), let url = URL(string: relayURL + "/r") else {
      completion("This bell's value is missing from the Keychain.")
      return
    }
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "POST"
    request.setValue("Bearer \(Self.token(of: value))", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let host = Host.current().localizedName ?? "this Mac"
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "title": "Wink test ring", "body": "Sent from Wink on \(host)", "state": "ok", "ring": true,
    ])
    URLSession.shared.dataTask(with: request) { data, response, error in
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      let message: String
      switch status {
      case 202:
        let delivered = reply?["delivered"].map { "\($0)" } ?? "?"
        message = "Rung. Devices reached: \(delivered)."
      case 404: message = "The relay doesn't know this bell: it was deleted, rekeyed or purged. Copy a fresh line from Blink."
      case 422: message = "The bell refused a plain message. It's probably set to require encryption, which Wink's test ring doesn't do."
      case 429: message = "The bell's message quota is used up; try again later."
      case 0: message = "Couldn't reach \(self.relayURL): \(error?.localizedDescription ?? "no response")."
      default: message = "The relay answered \(status)."
      }
      DispatchQueue.main.async { completion(message) }
    }.resume()
  }
}

// MARK: - Which host is a tab talking to?

enum BellHostDetection {
  /// The ssh/mosh destination of the foreground process, as typed (alias or
  /// host, without user@), or nil if the foreground isn't ssh or mosh.
  static func remoteHost(foregroundPID pid: pid_t) -> String? {
    guard let argv = ProcessArguments.of(pid), let exe = argv.first.map({ ($0 as NSString).lastPathComponent }) else {
      return nil
    }
    switch exe {
    case "ssh": return sshDestination(Array(argv.dropFirst()))
    case "mosh": return moshDestination(Array(argv.dropFirst()))
    case "mosh-client":
      // mosh hands its original arguments to mosh-client after -#.
      if let i = argv.firstIndex(of: "-#"), i + 1 < argv.count {
        return moshDestination(argv[i + 1].split(separator: " ").map(String.init))
      }
      return nil
    default: return nil
    }
  }

  /// ssh options that take a value (from ssh(1)).
  private static let sshValueOptions = Set("BbcDEeFIiJLlmOoPpQRSWw".map { "-\($0)" })

  static func sshDestination(_ args: [String]) -> String? {
    var i = 0
    while i < args.count {
      let a = args[i]
      if a == "--" { i += 1; break }
      if a.hasPrefix("-") && a.count > 1 {
        // "-p 22" takes the next word; "-p22" or "-vvv" don't.
        if a.count == 2, sshValueOptions.contains(a) { i += 2 } else { i += 1 }
        continue
      }
      return stripUser(a)
    }
    return i < args.count ? stripUser(args[i]) : nil
  }

  static func moshDestination(_ args: [String]) -> String? {
    for a in args where !a.hasPrefix("-") {
      return stripUser(a) // mosh options are --name=value, so the first word is the host
    }
    return nil
  }

  private static func stripUser(_ s: String) -> String {
    var host = s
    if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
    if host.hasPrefix("ssh://") { host = String(host.dropFirst(6)) }
    return host
  }
}
