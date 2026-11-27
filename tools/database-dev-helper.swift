import Foundation

// Development helper for the Database Workbench's browser dev host
// (wink-database/dev/mock-host.mjs). Runs the same MySQL client and session
// code as Wink and Blink, speaking JSON lines on stdin/stdout:
//   {"id":1,"op":"connect","connection":{"host","port","user","password","database","ssl","readOnly"}}
//   {"id":2,"op":"query","sql","params","maxRows","maxCell"}
//   {"id":3,"op":"execute","statements":[{"sql","params"}]}
//   {"id":4,"op":"kill"}            stops the running query from a second connection
// Build: swiftc -O tools/database-dev-helper.swift Sources/DatabaseURL.swift \
//          Sources/MySQLClient.swift Sources/DatabaseBridge.swift -parse-as-library -o …

@main struct DevHelper {
  static func main() async {
    let session = DatabaseSession()
    var readOnly = false
    func reply(_ object: [String: Any]) {
      let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"error":"unencodable reply"}"#.utf8)
      FileHandle.standardOutput.write(data + Data([0x0A]))
    }
    // Requests are handled in order, except kill, which must run while a query is busy.
    let lines = AsyncStream<String> { continuation in
      Thread {
        while let line = readLine() { continuation.yield(line) }
        continuation.finish()
      }.start()
    }
    var pending: Task<Void, Never>?
    for await line in lines {
      guard let data = line.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
      let id = request["id"] ?? NSNull()
      let op = request["op"] as? String ?? ""
      if op == "kill" {
        Task { reply(["id": id, "ok": await session.killRunningQuery()]) }
        continue
      }
      let previous = pending
      pending = Task {
        await previous?.value
        do {
          var result: [String: Any]
          switch op {
          case "connect":
            let c = request["connection"] as? [String: Any] ?? [:]
            var connection = DatabaseConnection()
            connection.host = c["host"] as? String ?? "127.0.0.1"
            connection.port = c["port"] as? Int ?? 3306
            connection.user = c["user"] as? String ?? ""
            connection.ssl = c["ssl"] as? Bool ?? false
            connection.readOnly = c["readOnly"] as? Bool ?? false
            readOnly = connection.readOnly
            let info = try await session.connect(.init(connection: connection, password: c["password"] as? String ?? "", tunnel: nil),
                                                 database: c["database"] as? String ?? "")
            result = ["version": info.version, "thread": info.thread, "database": info.database]
          case "query":
            let sql = request["sql"] as? String ?? ""
            let params = request["params"] as? [Any] ?? []
            let maxRows = request["maxRows"] as? Int ?? 1000, maxCell = request["maxCell"] as? Int ?? 65536
            let ro = readOnly
            result = try await session.perform { try session.query(sql, params: params, maxRows: maxRows, maxCell: maxCell, readOnly: ro) }
            result.removeValue(forKey: "_database")
          case "execute":
            let list = (request["statements"] as? [[String: Any]] ?? []).map { (sql: $0["sql"] as? String ?? "", params: $0["params"] as? [Any] ?? []) }
            let ro = readOnly
            result = try await session.perform { try session.execute(list, readOnly: ro) }
          default:
            throw DatabaseFailure("Unsupported operation.")
          }
          result["id"] = id
          reply(result)
        } catch {
          reply(["id": id, "error": error.localizedDescription])
          if op == "connect" { exit(1) }
        }
      }
    }
    await pending?.value
  }
}
