import Foundation

@main struct Checks {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wink-plugin-checks-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("<!doctype html>".utf8).write(to: root.appendingPathComponent("index.html"))
    func manifest(_ changes: [String: Any] = [:]) throws {
      var value: [String: Any] = ["manifestVersion": 1, "id": "org.example.test", "name": "Test", "version": "1", "entry": "index.html", "permissions": ["storage"]]
      value.merge(changes) { _, new in new }
      try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent("manifest.json"))
    }
    var count = 0
    func check(_ condition: Bool) { precondition(condition); count += 1 }
    try manifest()
    let package = try PluginPackage(root: root)
    check(package.manifest.id == "org.example.test")
    check(try package.asset("index.html") == root.appendingPathComponent("index.html"))
    for path in ["../index.html", "/etc/passwd", "foo/../../index.html", "missing.html", "foo\\bar"] {
      check((try? package.asset(path)) == nil)
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.html"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
    check((try? package.asset("escape.html")) == nil)
    for changes: [String: Any] in [["manifestVersion": 2], ["id": "../oops"], ["permissions": ["shell"]], ["entry": "../index.html"], ["entry": "missing.html"], ["name": ""], ["entry": "app.js"]] {
      try manifest(changes)
      check((try? PluginPackage(root: root)) == nil)
    }
    print("PASS: \(count) plugin package checks. Fixtures retained: \(root.path)")
  }
}
