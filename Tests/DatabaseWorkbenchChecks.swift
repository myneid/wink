import Foundation

// Integration checks for the database bridge against a real MySQL server.
// Skipped unless WINK_TEST_MYSQL is set:
//   WINK_TEST_MYSQL=127.0.0.1:33061 (user root, no password, database shop)
//   WINK_TEST_SSH=localhost         (optional: also test SSH tunnels)
@main struct Checks {
  @MainActor static func main() async throws {
    guard let target = ProcessInfo.processInfo.environment["WINK_TEST_MYSQL"] else {
      print("SKIP: database bridge checks (set WINK_TEST_MYSQL=host:port)"); return
    }
    let parts = target.split(separator: ":")
    let host = String(parts[0]), port = Int(parts.count > 1 ? parts[1] : "3306")!
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wink-db-checks-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    DatabaseWorkbench.storeOverride = dir.appendingPathComponent("databases.json")

    var count = 0
    func check(_ condition: Bool, _ note: @autoclosure () -> String = "", line: Int = #line) {
      if !condition { print("FAIL line \(line): \(note())"); exit(1) }
      count += 1
    }
    func rows(_ reply: Any) -> [[Any]] { (reply as? [String: Any])?["rows"] as? [[Any]] ?? [] }

    var direct = DatabaseConnection()
    direct.id = "direct"; direct.owner = "org.example.dbcheck"; direct.host = host; direct.port = port
    direct.user = "root"; direct.database = "shop"
    var other = direct; other.id = "other-app"; other.owner = "org.example.else"
    var readOnly = direct; readOnly.id = "ro"; readOnly.readOnly = true
    var tunneled = direct; tunneled.id = "ssh"; tunneled.ssh = ProcessInfo.processInfo.environment["WINK_TEST_SSH"] ?? ""
    tunneled.host = "127.0.0.1"
    var badSSH = direct; badSSH.id = "badssh"; badSSH.ssh = "nobody@127.0.0.1:1"
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([direct, other, readOnly, tunneled, badSSH]).write(to: DatabaseWorkbench.storeOverride!)

    let db = DatabaseWorkbench(appName: "Checks", owner: "org.example.dbcheck")

    // Apps see only their own connections, and never a password.
    let list = try await db.call("database.connections", [:]) as! [[String: Any]]
    check(list.count == 4 && !list.contains { $0["id"] as? String == "other-app" }, "\(list)")
    check(list.allSatisfy { $0["password"] == nil })
    do { _ = try await db.call("database.open", ["id": "other-app"]); check(false, "opened another app's connection") }
    catch { check("\(error.localizedDescription)".contains("no longer exists")) }
    do { _ = try await db.call("database.query", ["sql": "SELECT 1"]); check(false) }
    catch { check(error.localizedDescription.contains("Open a connection")) }

    // Open, query with params, session state.
    let opened = try await db.call("database.open", ["id": "direct"]) as! [String: Any]
    check((opened["version"] as? String)?.isEmpty == false && opened["database"] as? String == "shop", "\(opened)")
    var r = try await db.call("database.query", ["sql": "SELECT email FROM customers WHERE name = ?", "params": ["Linus"]])
    check(rows(r).first?.first as? String == "linus@example.com", "\(r)")
    _ = try await db.call("database.query", ["sql": "SET @wink_check = 42"])
    r = try await db.call("database.query", ["sql": "SELECT @wink_check"])
    check(rows(r).first?.first as? String == "42", "session variables persist")
    _ = try await db.call("database.query", ["sql": "CREATE TEMPORARY TABLE wink_tmp (id INT PRIMARY KEY, v VARCHAR(10))"])

    // Transactions are all-or-nothing.
    let good: [[String: Any]] = [["sql": "INSERT INTO wink_tmp VALUES (?, ?)", "params": ["1", "a"]],
                                 ["sql": "INSERT INTO wink_tmp VALUES (?, ?)", "params": ["2", NSNull()]]]
    let exec = try await db.call("database.execute", ["statements": good]) as! [String: Any]
    check(exec["affected"] as? [Int] == [1, 1], "\(exec)")
    do {
      _ = try await db.call("database.execute", ["statements": [["sql": "UPDATE wink_tmp SET v = 'z' WHERE id = 1"], ["sql": "INSERT INTO wink_tmp VALUES (1, 'dup')"]]])
      check(false, "duplicate key should fail")
    } catch { check(error.localizedDescription.contains("Statement 2"), error.localizedDescription) }
    r = try await db.call("database.query", ["sql": "SELECT v FROM wink_tmp ORDER BY id"])
    check(rows(r).first?.first as? String == "a" && rows(r).last?.first is NSNull, "rolled back: \(r)")

    // USE is tracked, so a reconnect returns to the same database.
    _ = try await db.call("database.query", ["sql": "USE analytics"])
    let status = try await db.call("database.status", [:]) as! [String: Any]
    check(status["database"] as? String == "analytics", "\(status)")

    // Cancel stops a long statement on the server, and the session continues.
    let started = Date()
    async let slow: Any = db.call("database.query", ["sql": "SELECT SLEEP(20)"])
    try await Task.sleep(for: .milliseconds(600))
    _ = try await db.call("database.cancel", [:])
    let slowResult = try? await slow
    check(Date().timeIntervalSince(started) < 8, "cancel took \(Date().timeIntervalSince(started))s")
    // SLEEP returns 1 when interrupted instead of erroring; either outcome is fine.
    check(slowResult == nil || rows(slowResult!).first?.first as? String == "1", "\(String(describing: slowResult))")
    r = try await db.call("database.query", ["sql": "SELECT DATABASE()"])
    check(rows(r).first?.first as? String == "analytics", "session kept after cancel: \(r)")

    // Overlapping calls are queued, not rejected.
    async let first: Any = db.call("database.query", ["sql": "SELECT SLEEP(0.3), 1"])
    async let second: Any = db.call("database.query", ["sql": "SELECT 2"])
    let (a, b) = try await (first, second)
    check(rows(a).first?.last as? String == "1" && rows(b).first?.first as? String == "2", "queued: \(a) \(b)")

    // A session the server drops is replaced on the next query, in the same database.
    let thread = ((try await db.call("database.query", ["sql": "SELECT CONNECTION_ID()"])) as! [String: Any])
    let admin = try MySQLClient(transport: SocketTransport(host: host, port: port),
                                options: MySQLConnectOptions(host: host, user: "root", password: "", database: "", ssl: false))
    _ = try admin.query("KILL CONNECTION \(rows(thread).first!.first as! String)")
    admin.quit()
    do { _ = try await db.call("database.query", ["sql": "SELECT 1"]); check(false, "query on a killed session") }
    catch { check(error.localizedDescription.contains("reconnects"), error.localizedDescription) }
    r = try await db.call("database.query", ["sql": "SELECT DATABASE()"])
    check((r as! [String: Any])["reconnected"] as? Bool == true && rows(r).first?.first as? String == "analytics", "\(r)")

    // TLS, and caching_sha2_password both with TLS and with the server's RSA key.
    if let appPassword = ProcessInfo.processInfo.environment["WINK_TEST_APP_PASSWORD"] {
      var tls = direct; tls.id = "tls"; tls.ssl = true; tls.user = "app"
      var rsa = direct; rsa.id = "rsa"; rsa.user = "app"
      let keychain = DatabaseKeychain(service: "Wink Database")
      try keychain.set(appPassword, for: "tls")
      try keychain.set(appPassword, for: "rsa")
      defer { keychain.delete("tls"); keychain.delete("rsa") }
      try encoder.encode([direct, other, readOnly, tunneled, badSSH, tls, rsa]).write(to: DatabaseWorkbench.storeOverride!)
      _ = try await db.call("database.open", ["id": "tls"])
      r = try await db.call("database.query", ["sql": "SHOW SESSION STATUS LIKE 'Ssl_cipher'"])
      check((rows(r).first?.last as? String)?.isEmpty == false, "TLS cipher: \(r)")
      _ = try await db.call("database.open", ["id": "rsa"])
      r = try await db.call("database.query", ["sql": "SELECT CURRENT_USER()"])
      check((rows(r).first?.first as? String)?.hasPrefix("app@") == true, "\(r)")
      print("PASS: TLS and caching_sha2_password (RSA) sign-in")
    }

    // Read-only connections block writes and attempts to lift it.
    _ = try await db.call("database.open", ["id": "ro"])
    for sql in ["UPDATE tags SET color = color", "SET SESSION TRANSACTION READ WRITE"] {
      do { _ = try await db.call("database.query", ["sql": sql]); check(false, sql) }
      catch { check(error.localizedDescription.lowercased().contains("read"), error.localizedDescription) }
    }

    // SSH tunnels.
    if !tunneled.ssh.isEmpty {
      let t = try await db.call("database.open", ["id": "ssh"]) as! [String: Any]
      check(t["database"] as? String == "shop", "\(t)")
      r = try await db.call("database.query", ["sql": "SELECT COUNT(*) FROM orders"])
      check(Int(rows(r).first?.first as? String ?? "") ?? 0 > 0, "\(r)")
      SSHTunnel.closeAll()
      try await Task.sleep(for: .milliseconds(300))
      r = try await db.call("database.query", ["sql": "SELECT 1"])
      check((r as! [String: Any])["reconnected"] as? Bool == true, "tunnel reopened: \(r)")
      print("PASS: SSH tunnel through \(tunneled.ssh)")
    }
    do { _ = try await db.call("database.open", ["id": "badssh"]); check(false) }
    catch { check(error.localizedDescription.hasPrefix("SSH to nobody@127.0.0.1:1 failed"), error.localizedDescription) }

    db.close()
    do { _ = try await db.call("database.connections", [:]); check(false) }
    catch { check(error.localizedDescription.contains("closed")) }
    try? FileManager.default.removeItem(at: dir)
    print("PASS: \(count) database bridge checks against \(target).")
  }
}
