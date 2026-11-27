import AppKit

/// One database grant per app tab. Credentials never enter WebKit.
@MainActor final class DatabaseWorkbench {
  private struct Connection: Encodable {
    let port: Int
    let user: String
    let password: String
    let database: String
  }

  private let appName: String
  private var closed = false
  private var connection: Connection?
  private var running: Process?

  init(appName: String) { self.appName = appName }

  func close() {
    closed = true
    connection = nil
    cancel()
  }

  private func cancel() { if let running, running.isRunning { running.terminate() } }

  func call(_ method: String, _ args: [String: Any]) async throws -> Any {
    guard !closed else { throw failure("This app tab has closed.") }
    switch method {
    case "database.connect":
      guard running == nil else { throw failure("A query is already running.") }
      return try prompt()
    case "database.cancel":
      cancel()
      return true
    case "database.query":
      guard let connection else { throw failure("Choose a connection first.") }
      guard let sql = args["sql"] as? String, !sql.isEmpty, sql.utf8.count <= 32768 else {
        throw failure("Enter a query of up to 32 KiB.")
      }
      return try await query(connection, sql: sql)
    default:
      throw failure("Unsupported database method.")
    }
  }

  private func failure(_ reason: String) -> PluginPackage.Failure { .invalid(reason) }

  private func prompt() throws -> Bool {
    let alert = NSAlert()
    alert.messageText = "Allow \(appName) to query MySQL?"
    alert.informativeText = "Use a local MySQL server or an existing SSH forward on 127.0.0.1. The app can read query results until this tab closes. Use a MySQL account granted SELECT only."
    alert.addButton(withTitle: "Use Connection")
    alert.addButton(withTitle: "Cancel")
    let port = NSTextField(string: "3306")
    let user = NSTextField()
    let password = NSSecureTextField()
    let database = NSTextField()
    let fields: [(String, NSTextField)] = [("Local port", port), ("Database", database), ("User", user), ("Password", password)]
    let grid = NSGridView(views: fields.map { [NSTextField(labelWithString: $0.0), $0.1] })
    for (_, field) in fields { field.widthAnchor.constraint(equalToConstant: 220).isActive = true }
    alert.accessoryView = grid
    alert.window.initialFirstResponder = database
    guard alert.runModal() == .alertFirstButtonReturn else { return false }
    guard let number = Int(port.stringValue), (1...65535).contains(number),
          !user.stringValue.isEmpty,
          !database.stringValue.isEmpty,
          !database.stringValue.contains(where: { $0 == ";" || $0.isNewline || $0 == "\0" }) else {
      throw failure("Enter a valid port, database and user.")
    }
    guard !closed else { return false }
    connection = Connection(port: number, user: user.stringValue, password: password.stringValue, database: database.stringValue)
    return true
  }

  private func query(_ connection: Connection, sql: String) async throws -> Any {
    guard running == nil else { throw failure("A query is already running.") }
    let phpPaths = ["/opt/homebrew/bin/php", "/usr/local/bin/php",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Herd/bin/php").path]
    guard let php = phpPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
          let helper = Bundle.main.url(forResource: "database-query", withExtension: "php") else {
      throw failure("Wink needs PHP CLI with pdo_mysql (Homebrew or Herd).")
    }
    let request = try JSONEncoder().encode(Query(connection: connection, sql: sql))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: php)
    process.arguments = ["-d", "display_errors=stderr", helper.path]
    process.environment = ["PATH": "/usr/bin:/bin"]
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    running = process
    defer { running = nil }
    let timeout = Task {
      try await Task.sleep(for: .seconds(20))
      cancel()
    }
    defer { timeout.cancel() }
    let data = try await Task.detached {
      defer { process.waitUntilExit() }
      do { try input.fileHandleForWriting.write(contentsOf: request) }
      catch {
        try? input.fileHandleForWriting.close()
        throw error
      }
      try input.fileHandleForWriting.close()
      return output.fileHandleForReading.readDataToEndOfFile()
    }.value
    guard process.terminationStatus == 0,
          let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw failure("Query cancelled, timed out, or the database helper stopped.")
    }
    if let error = response["error"] as? String { throw failure(error) }
    return response
  }

  private struct Query: Encodable {
    let connection: Connection
    let sql: String
  }
}
