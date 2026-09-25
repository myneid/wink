import AppKit
import WebKit

// One terminal = one window (shown as a native tab) = one PTY + one hterm.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
  private let webView: WKWebView
  private let command: [String]?
  private let initialTitle: String

  private var pid: pid_t = 0
  private var masterFD: Int32 = -1
  private var readSource: DispatchSourceRead?
  private var exitSource: DispatchSourceProcess?
  private let ioQueue = DispatchQueue(label: "wink.pty")

  // Output coalescing and flow control (accessed on ioQueue).
  private var outBuffer = Data()
  private var flushScheduled = false
  private var inFlight = 0
  private var readPaused = false
  private static let maxInFlight = 4

  private var titleObservation: NSKeyValueObservation?
  private var ready = false
  private var exited = false

  static var all: [TerminalWindowController] = []

  /// Called after the tab closes (e.g. to pick up an edited config).
  var onClose: (() -> Void)?

  /// `command` nil = user's login shell; otherwise run via `$SHELL -l -c`.
  init(command: [String]? = nil, title: String? = nil) {
    self.command = command
    initialTitle = title ?? (Self.userShell as NSString).lastPathComponent

    let config = WKWebViewConfiguration()
    config.preferences.setValue(true, forKey: "developerExtrasEnabled")
    webView = WKWebView(frame: .zero, configuration: config)
    webView.setValue(false, forKey: "drawsBackground")

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 460),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
    window.tabbingMode = .preferred
    window.tabbingIdentifier = "wink"
    window.title = initialTitle
    window.contentView = webView
    window.backgroundColor = NSColor(calibratedWhite: 0.063, alpha: 1)
    window.setFrameAutosaveName("WinkTerminal")
    super.init(window: window)

    window.delegate = self
    config.userContentController.add(WeakScriptHandler(self), name: "wink")
    webView.navigationDelegate = self
    titleObservation = webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
      guard let self, let t = wv.title, !t.isEmpty else { return }
      self.window?.title = t
    }

    let res = Bundle.main.resourceURL!
    webView.loadFileURL(res.appendingPathComponent("term.html"), allowingReadAccessTo: res)
    Self.all.append(self)
  }

  required init?(coder: NSCoder) { fatalError() }

  // MARK: - JS bridge

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    let s = Settings.shared
    let opts: [String: Any] = [
      "fontFamily": s.fontFamily,
      "fontSize": s.fontSize,
      "optionIsMeta": s.optionIsMeta,
      "theme": s.themeSource,
    ]
    call("wink.init", opts)
  }

  fileprivate func handle(_ body: [String: Any]) {
    switch body["op"] as? String {
    case "ready":
      let cols = body["cols"] as? Int ?? 80, rows = body["rows"] as? Int ?? 24
      if !ready {
        ready = true
        spawn(cols: cols, rows: rows)
      }
      if window?.isKeyWindow == true { focusTerminal() }
    case "input":
      if let s = body["data"] as? String { write(Data(s.utf8)) }
    case "resize":
      if masterFD >= 0, let c = body["cols"] as? Int, let r = body["rows"] as? Int {
        wink_pty_resize(masterFD, UInt16(c), UInt16(r))
      }
    case "openURL":
      // Only schemes a click on terminal text should reach; output is untrusted.
      if let s = body["url"] as? String, let url = URL(string: s),
         ["http", "https", "ftp", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") {
        NSWorkspace.shared.open(url)
      }
    case "background":
      if let css = body["color"] as? String, let c = NSColor(css: css) {
        window?.backgroundColor = c
      }
    default:
      break
    }
  }

  func call(_ fn: String, _ args: Any..., completion: (() -> Void)? = nil) {
    let json = args.map { arg -> String in
      let data = try! JSONSerialization.data(withJSONObject: [arg], options: [.fragmentsAllowed])
      return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }.joined(separator: ",")
    webView.evaluateJavaScript("\(fn)(\(json))") { _, err in
      if let err { NSLog("wink js error: \(err)") }
      completion?()
    }
  }

  func focusTerminal() {
    window?.makeFirstResponder(webView)
    call("wink.focus")
  }

  // MARK: - PTY

  static var userShell: String {
    if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
      return String(cString: sh)
    }
    return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
  }

  private func spawn(cols: Int, rows: Int) {
    let shell = Self.userShell
    let shellName = (shell as NSString).lastPathComponent
    var argv: [String]
    if let command {
      let line = command.map(shellQuote).joined(separator: " ")
      argv = [shellName, "-l", "-c", line]
    } else {
      argv = ["-" + shellName] // leading dash = login shell
    }

    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["COLORTERM"] = "truecolor"
    env["TERM_PROGRAM"] = "Wink"
    env["SHELL"] = shell
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    env.removeValue(forKey: "__CFBundleIdentifier")
    let envp = env.map { "\($0.key)=\($0.value)" }

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var fd: Int32 = -1
    pid = withCStrings(argv) { cargv in
      withCStrings(envp) { cenv in
        wink_pty_spawn(shell, cargv, cenv, home, UInt16(cols), UInt16(rows), &fd)
      }
    }
    guard pid > 0 else {
      call("wink.write", Data("\r\nwink: failed to start \(shell): \(String(cString: strerror(errno)))\r\n".utf8).base64EncodedString())
      return
    }
    masterFD = fd
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

    let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
    rs.setEventHandler { [weak self] in self?.readAvailable(fd) }
    rs.setCancelHandler { Darwin.close(fd) }
    rs.resume()
    readSource = rs

    let es = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    es.setEventHandler { [weak self] in self?.childExited() }
    es.resume()
    exitSource = es
  }

  private func readAvailable(_ fd: Int32) {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = read(fd, &buf, buf.count)
      if n > 0 {
        outBuffer.append(buf, count: n)
        if n < buf.count { break }
      } else {
        if n == 0 || (errno != EAGAIN && errno != EINTR) { readSource?.cancel() }
        break
      }
    }
    scheduleFlush()
  }

  private func scheduleFlush() {
    guard !flushScheduled, !outBuffer.isEmpty else { return }
    if inFlight >= Self.maxInFlight {
      // Let the web view catch up before reading more (e.g. `cat hugefile`).
      if !readPaused { readPaused = true; readSource?.suspend() }
      return
    }
    flushScheduled = true
    DispatchQueue.main.async { [weak self] in self?.flush() }
  }

  private func flush() {
    let chunk: Data = ioQueue.sync {
      flushScheduled = false
      let d = outBuffer
      outBuffer.removeAll(keepingCapacity: true)
      if !d.isEmpty { inFlight += 1 }
      return d
    }
    guard !chunk.isEmpty else { return }
    call("wink.write", chunk.base64EncodedString()) { [weak self] in
      guard let self else { return }
      self.ioQueue.async {
        self.inFlight -= 1
        if self.readPaused, self.inFlight < Self.maxInFlight {
          self.readPaused = false
          self.readSource?.resume()
        }
        self.scheduleFlush()
      }
    }
  }

  private func write(_ data: Data) {
    guard masterFD >= 0 else { return }
    ioQueue.async { [fd = masterFD] in
      data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
          let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
          if n > 0 { off += n }
          else if errno == EAGAIN || errno == EINTR { usleep(1000) }
          else { break }
        }
      }
    }
  }

  private func childExited() {
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    exited = true
    exitSource?.cancel()
    // Drain whatever the process printed last before deciding what to do.
    ioQueue.async { [weak self, fd = masterFD] in
      guard let self else { return }
      if fd >= 0, self.readSource?.isCancelled == false { self.readAvailable(fd) }
      DispatchQueue.main.async {
        let code = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        if code == 0 {
          self.window?.close()
        } else {
          let msg = "\r\n\u{1b}[2m[process exited with code \(code) — ⌘W to close]\u{1b}[0m\r\n"
          self.call("wink.write", Data(msg.utf8).base64EncodedString())
        }
      }
    }
  }

  /// True if something other than the shell itself is in the foreground.
  var hasRunningJob: Bool {
    guard masterFD >= 0, !exited else { return false }
    let fg = tcgetpgrp(masterFD)
    return fg > 0 && fg != pid && command == nil
  }

  private func terminate() {
    guard pid > 0 else { return }
    if !exited { kill(-pid, SIGHUP); kill(pid, SIGHUP) }
    ioQueue.sync {
      if readPaused { readPaused = false; readSource?.resume() }
      readSource?.cancel() // closes the master fd
    }
    masterFD = -1
    if !exited {
      let p = pid
      DispatchQueue.global().async { var s: Int32 = 0; waitpid(p, &s, 0) }
    }
    exitSource?.cancel()
  }

  // MARK: - NSWindowDelegate

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard hasRunningJob else { return true }
    let alert = NSAlert()
    alert.messageText = "Close this tab?"
    alert.informativeText = "A process is still running in this terminal and will be terminated."
    alert.addButton(withTitle: "Close")
    alert.addButton(withTitle: "Cancel")
    alert.beginSheetModal(for: sender) { resp in
      if resp == .alertFirstButtonReturn { sender.close() }
    }
    return false
  }

  func windowWillClose(_ notification: Notification) {
    terminate()
    titleObservation = nil
    webView.configuration.userContentController.removeScriptMessageHandler(forName: "wink")
    Self.all.removeAll { $0 === self }
    onClose?()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    if ready { focusTerminal() }
  }

  func windowDidResignKey(_ notification: Notification) {
    if ready { call("wink.blur") }
  }
}

// MARK: - helpers

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
  weak var target: TerminalWindowController?
  init(_ target: TerminalWindowController) { self.target = target }
  func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
    if let body = message.body as? [String: Any] { target?.handle(body) }
  }
}

private func shellQuote(_ s: String) -> String {
  if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@,+".contains($0) }) { return s }
  return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
  var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
  ptrs.append(nil)
  defer { ptrs.forEach { free($0) } }
  return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
}

extension NSColor {
  /// Parses the CSS colors hterm reports: #rgb, #rrggbb, rgb(), rgba().
  convenience init?(css: String) {
    let s = css.trimmingCharacters(in: .whitespaces).lowercased()
    if s.hasPrefix("#") {
      var hex = String(s.dropFirst())
      if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
      guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
      self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: 1)
      return
    }
    guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
    let parts = s[s.index(after: open)..<close].split(separator: ",")
      .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count >= 3 else { return nil }
    self.init(srgbRed: parts[0] / 255, green: parts[1] / 255, blue: parts[2] / 255,
              alpha: parts.count > 3 ? parts[3] : 1)
  }
}
