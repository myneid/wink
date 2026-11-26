import AppKit
import WebKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let package = try PluginPackage(root: URL(fileURLWithPath: CommandLine.arguments[1]))
let controller = PluginWindowController(package: package)
controller.showWindow(nil)
let web = controller.window!.contentView as! WKWebView

func verify(attempt: Int) {
  web.callAsyncJavaScript("""
    const screen = () => document.querySelector('#terminal iframe')?.contentDocument?.body.textContent ?? '';
    if (!screen().includes('> [x] Draw the screen with ANSI')) return false;
    const frame = document.querySelector('#terminal iframe');
    const keyboard = frame.contentWindow;
    const press = keyCode => frame.contentDocument.body.dispatchEvent(
      new keyboard.KeyboardEvent('keydown', { bubbles: true, keyCode }));
    press(40);
    if (!screen().includes('> [ ] Handle arrows and Enter')) throw Error('Arrow Down failed');
    press(13);
    if (!screen().includes('> [x] Handle arrows and Enter')) throw Error('Enter failed');
    document.querySelector('[data-key="down"]').click();
    document.querySelector('[data-key="enter"]').click();
    if (!screen().includes('> [x] Try the touch controls')) throw Error('Touch controls failed');
    const initialSize = terminal.size();
    document.querySelector('#terminal').style.width = '180px';
    await new Promise(resolve => setTimeout(resolve, 300));
    if (terminal.size().cols >= initialSize.cols || !screen().includes('> [x] Try')) throw Error('Resize failed');
    return true;
    """, arguments: [:], in: nil, in: .page) { result in
      switch result {
      case .success(let value as Bool) where value:
        print("PASS: TUI paints actual hterm cells, handles keyboard and touch controls, and redraws on resize")
        controller.close()
        exit(0)
      case .success where attempt < 30:
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { verify(attempt: attempt + 1) }
      default:
        print("FAIL: \(result)")
        exit(1)
      }
    }
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { verify(attempt: 1) }
app.run()
