import Foundation

private final class FixtureProtocol: URLProtocol {
  static var responses: [String: Data] = [:]
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let url = request.url, let data = Self.responses[url.absoluteString] else {
      client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
    }
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@main struct Checks {
  static func main() async throws {
    var count = 0
    func check(_ result: Bool) { precondition(result); count += 1 }
    for bad in ["http://github.com/a/b", "https://github.com.evil/a/b", "https://user@github.com/a/b", "https://github.com/a/b?x=1", "https://github.com/a/b/issues/1", "https://github.com/a/b/tree/main/../escape", "https://github.com/a/b/tree/main/%2e%2e", "https://github.com:443/a/b"] {
      check((try? GitHubPluginSource(bad)) == nil)
    }
    let source = try GitHubPluginSource("https://github.com/example/plugin/tree/main/app")
    check(source.path == "app" && source.ref == "main")
    check(try GitHubPluginSource("https://github.com/example/plugin.git").repository == "plugin")
    let sha = String(repeating: "a", count: 40)
    let manifest = Data("{\"manifestVersion\":1,\"id\":\"org.example.fixture\",\"name\":\"Fixture\",\"version\":\"1\",\"entry\":\"index.html\",\"permissions\":[\"storage\"]}".utf8)
    let html = Data("<!doctype html><h1>Fixture</h1>".utf8)
    let api = "https://api.github.com/repos/example/plugin/"
    let raw = "https://raw.githubusercontent.com/example/plugin/\(sha)/app/"
    FixtureProtocol.responses = [
      String(api.dropLast()): Data("{\"default_branch\":\"main\"}".utf8),
      api + "commits/main": Data("{\"sha\":\"\(sha)\",\"commit\":{\"tree\":{\"sha\":\"\(sha)\"}}}".utf8),
      raw + "manifest.json": manifest, raw + "index.html": html
    ]
    let treeURL = api + "git/trees/\(sha)?recursive=1"
    func tree(mode: String = "100644", truncated: Bool = false, path: String = "app/index.html", size: Int? = nil) throws {
      let entries: [[String: Any]] = [
        ["path": "app/manifest.json", "mode": "100644", "type": "blob", "size": manifest.count],
        ["path": path, "mode": mode, "type": "blob", "size": size ?? html.count]]
      FixtureProtocol.responses[treeURL] = try JSONSerialization.data(withJSONObject: ["truncated": truncated, "tree": entries])
    }
    try tree()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [FixtureProtocol.self]
    let installer = PluginInstaller(session: URLSession(configuration: config))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wink-installer-fixtures-" + UUID().uuidString)
    let prepared = try await installer.prepare(source, staging: root.appendingPathComponent("staging"))
    check(prepared.commit == sha)
    check(try Data(contentsOf: prepared.package.asset("index.html")) == html)
    let plugins = root.appendingPathComponent("Plugins")
    let installed = try prepared.install(in: plugins, bundledIDs: [])
    check(try PluginPackage(root: installed).manifest.id == "org.example.fixture")
    check(FileManager.default.fileExists(atPath: installed.appendingPathComponent(".wink-source.json").path))
    let duplicate = try await installer.prepare(source, staging: root.appendingPathComponent("staging"))
    check((try? duplicate.install(in: plugins, bundledIDs: [])) == nil)
    check((try? duplicate.install(in: root.appendingPathComponent("other"), bundledIDs: ["org.example.fixture"])) == nil)
    let current = try PluginPackage(root: installed)
    let receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent(".wink-source.json"))) as! [String: String]
    var wrong = receipt; wrong["repository"] = "https://github.com/other/repo"
    let backups = root.appendingPathComponent("backups")
    check((try? duplicate.update(current, receipt: wrong, backups: backups)) == nil)
    try duplicate.update(current, receipt: receipt, backups: backups)
    check(try PluginPackage(root: installed).manifest.id == current.manifest.id)
    check(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).count == 1)
    let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: installed.appendingPathComponent(".wink-source.json"))) as! [String: String]
    check(updated["ref"] == "main" && updated["commit"] == sha)
    for kind in 0..<5 {
      switch kind {
      case 0: try tree(mode: "120000")
      case 1: try tree(truncated: true)
      case 2: try tree(path: "app/../escape.html")
      case 3: try tree(size: 9 * 1024 * 1024)
      default: try tree(size: html.count + 1)
      }
      do { _ = try await installer.prepare(source, staging: root); fatalError("Accepted invalid tree \(kind)") }
      catch { count += 1 }
    }
    print("PASS: \(count) offline GitHub installer checks (URL parsing, pinned snapshot, install, collisions, traversal, symlinks, limits, size integrity). Fixtures: \(root.path)")
  }
}
