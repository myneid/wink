import AppKit
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let package = try PluginPackage(root: URL(fileURLWithPath: CommandLine.arguments[1]))
let controller = PluginWindowController(package: package)
controller.showWindow(nil)
let web = controller.window!.contentView as! WKWebView
var attempts = 0
func verify() {
  attempts += 1
  web.evaluateJavaScript("document.querySelector('#host')?.textContent") { result, error in
    if let text = result as? String, text.contains("pluginID") {
      print("PASS: real WKWebView loaded example and promise bridge: \(text)")
      web.evaluateJavaScript("document.querySelector('#note').value = 'WKWebView smoke test'; document.querySelector('#save').click(); true") { _, error in
        if let error { print("FAIL: \(error)"); exit(1) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          web.evaluateJavaScript("document.querySelector('#status').textContent") { result, _ in
            guard (result as? String)?.contains("Saved.") == true else { print("FAIL: storage bridge \(String(describing: result))"); exit(1) }
            print("PASS: real WKWebView storage bridge and save interaction")
            web.callAsyncJavaScript("""
              const checks = [];
              const rejected = async fn => { try { await fn(); return false; } catch (_) { return true; } };
              checks.push(await rejected(() => blink.storage.set('oversized', 'x'.repeat(70000))));
              checks.push(await rejected(() => blink.storage.set('', 'bad')));
              checks.push(await rejected(() => window.webkit.messageHandlers.blink.postMessage({method: 'shell.exec', key: 'x'})));
              const script = document.createElement('script');
              script.textContent = 'window.inlineScriptExecuted = true';
              document.head.appendChild(script);
              checks.push(window.inlineScriptExecuted !== true);
              return checks;
              """, arguments: [:], in: nil, in: .page) { result in
                guard case .success(let value) = result, let checks = value as? [Bool], checks.count == 4, checks.allSatisfy({ $0 }) else {
                  print("FAIL: bridge/CSP boundaries: \(result)"); exit(1)
                }
                print("PASS: storage quota, invalid key, unsupported native command, inline-script CSP")
                controller.close()
                print("PASS: window close cleanup")
                exit(0)
              }
          }
        }
      }
    } else if attempts < 30 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { verify() }
    } else { print("FAIL: web app did not become ready: \(String(describing: result)), \(String(describing: error))"); exit(1) }
  }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { verify() }
app.run()
