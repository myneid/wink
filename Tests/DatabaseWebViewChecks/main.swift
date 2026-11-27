import AppKit
import WebKit

// Loads the Database Workbench app (path in argv[1]) in a real plugin window,
// with Wink's CSP and bridge, and drives it against MySQL. Skipped unless
// WINK_TEST_MYSQL=host:port is set (root without a password, fixture loaded).
guard let target = ProcessInfo.processInfo.environment["WINK_TEST_MYSQL"], CommandLine.arguments.count > 1,
      FileManager.default.fileExists(atPath: CommandLine.arguments[1] + "/manifest.json") else {
  print("SKIP: Database Workbench WebView checks (set WINK_TEST_MYSQL and pass the app folder)"); exit(0)
}
let parts = target.split(separator: ":")
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wink-db-webview-" + UUID().uuidString)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let store = dir.appendingPathComponent("databases.json")
MainActor.assumeIsolated {
  DatabaseWorkbench.storeOverride = store
}
var c = DatabaseConnection()
c.id = "webview"; c.owner = "org.blink.database"; c.name = "Fixture"; c.host = String(parts[0])
c.port = Int(parts.count > 1 ? parts[1] : "3306")!; c.user = "root"; c.database = "shop"; c.environment = "local"
try JSONEncoder().encode([c]).write(to: store)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let package = try PluginPackage(root: URL(fileURLWithPath: CommandLine.arguments[1]))
let controller = PluginWindowController(package: package)
controller.showWindow(nil)
let web = controller.window!.contentView as! WKWebView

let script = """
  const wait = async (test, label, ms = 8000) => {
    const end = Date.now() + ms;
    while (Date.now() < end) { const v = test(); if (v) return v; await new Promise(r => setTimeout(r, 100)); }
    throw new Error('timed out: ' + label + ' — status: ' + (document.querySelector('#status')?.textContent || document.querySelector('#home-status')?.textContent));
  };
  const violations = [];
  document.addEventListener('securitypolicyviolation', e => {
    // WebKit's own <select> internals report style-src-attr when created from script; not app code.
    if (e.violatedDirective === 'style-src-attr' && e.target?.tagName === 'SELECT') return;
    violations.push(e.violatedDirective + ' ' + e.sourceFile + ':' + e.lineNumber + ' ' + (e.target?.outerHTML || '').slice(0, 120));
  });
  await wait(() => document.querySelector('.connection'), 'connection list');
  const out = {};
  out.css = getComputedStyle(document.querySelector('.connection')).display;
  out.stripe = document.querySelector('.connection .stripe').style.background;
  await connect('webview');
  await wait(() => [...document.querySelectorAll('#objects button')].some(b => b.textContent.includes('customers')), 'sidebar');
  openTable('customers');
  await wait(() => document.querySelectorAll('.grid tbody tr').length === 3, 'table rows');
  const tab = activeTab();
  tab.grid.setValue(2, 1, 'Grace H');
  await tab.commit();
  const check = await blink.database.query("SELECT name FROM customers WHERE email = 'grace@example.com'");
  out.committed = check.rows[0][0];
  const q = newQuery("SELECT COUNT(*) AS n FROM orders; SELECT 'x' AS y;");
  await q.run(true);
  out.results = q.results.map(r => r.r.rows[0][0]);
  out.highlighted = document.querySelectorAll('.editor pre .t-keyword').length > 0;
  out.violations = violations;
  return out;
  """
DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
  web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
    guard case .success(let value) = result, let out = value as? [String: Any] else { print("FAIL: \(result)"); exit(1) }
    guard out["css"] as? String == "grid", (out["stripe"] as? String)?.isEmpty == false else { print("FAIL: styles under CSP: \(out)"); exit(1) }
    guard out["committed"] as? String == "Grace H" else { print("FAIL: commit through bridge: \(out)"); exit(1) }
    guard let results = out["results"] as? [String], results == ["1200", "x"] else { print("FAIL: query tab: \(out)"); exit(1) }
    guard out["highlighted"] as? Bool == true, (out["violations"] as? [Any])?.isEmpty == true else { print("FAIL: editor/CSP: \(out)"); exit(1) }
    print("PASS: Database Workbench in a real plugin window: list, connect, browse, edit + commit, SQL tab, no CSP violations")
    controller.close()
    try? FileManager.default.removeItem(at: dir)
    exit(0)
  }
}
app.run()
