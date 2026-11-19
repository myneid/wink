import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Network

// The host picker: `Wink --hosts`, run in a terminal tab. Hosts are cards
// drawn with CoreGraphics and shown with the kitty graphics protocol, so it
// looks the same in Wink, kitty and Ghostty; anywhere else (or inside tmux)
// the cards are drawn with box characters. Picking a host execs ssh or mosh
// in place, so the tab becomes the connection.
//
// Hosts come from HostCatalog; edits are saved there too.

enum HostPicker {
  static func run() -> Never {
    guard isatty(0) == 1, isatty(1) == 1 else {
      for c in HostCatalog.load().hosts where !c.hidden { print(c.host.sshAlias) }
      exit(0)
    }
    let ui = PickerUI()
    ui.loop()
  }
}

// MARK: - Terminal

private final class Term {
  var cols = 80, rows = 24
  var cellW = 8.0, cellH = 17.0
  var graphics = false
  private var original = termios()
  private var out = ""
  private var pending: [UInt8] = []

  func enter() {
    tcgetattr(0, &original)
    var raw = original
    cfmakeraw(&raw)
    tcsetattr(0, TCSAFLUSH, &raw)
    emit("\u{1b}[?1049h\u{1b}[?25l\u{1b}[?1000h\u{1b}[?1006h")
    flush()
    updateSize()
    graphics = detectGraphics()
  }

  func leave() {
    emit("\u{1b}[?1000l\u{1b}[?1006l\u{1b}[0m\u{1b}[2J\u{1b}[?25h\u{1b}[?1049l")
    flush()
    tcsetattr(0, TCSAFLUSH, &original)
  }

  func updateSize() {
    var c: UInt16 = 0, r: UInt16 = 0, xp: UInt16 = 0, yp: UInt16 = 0
    guard wink_get_winsize(1, &c, &r, &xp, &yp) == 0, c > 0, r > 0 else { return }
    cols = Int(c); rows = Int(r)
    if xp > 0, yp > 0 {
      cellW = Double(xp) / Double(c)
      cellH = Double(yp) / Double(r)
    } else {
      cellW = 16; cellH = 34 // unknown: draw at 2x of a typical cell
    }
  }

  /// Asks the terminal whether it does kitty graphics. Terminals that don't
  /// still answer the DA1 query sent after it, so this never hangs.
  private func detectGraphics() -> Bool {
    let env = ProcessInfo.processInfo.environment
    if env["TMUX"] != nil || env["WINK_HOSTS_TEXT"] != nil { return false }
    emit("\u{1b}_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\u{1b}\\\u{1b}[c")
    flush()
    var reply = [UInt8]()
    let deadline = Date().addingTimeInterval(0.5)
    while Date() < deadline {
      guard let bytes = read(timeout: 50) else { continue }
      reply += bytes
      let text = String(decoding: reply, as: UTF8.self)
      if text.range(of: "\u{1b}\\[\\?[0-9;]*c", options: .regularExpression) != nil {
        return text.contains("i=31;OK")
      }
    }
    return false
  }

  func emit(_ s: String) { out += s }

  func flush() {
    var data = Array(out.utf8)
    out = ""
    var offset = 0
    while offset < data.count {
      let n = data.withUnsafeMutableBytes { Darwin.write(1, $0.baseAddress! + offset, $0.count - offset) }
      if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return }
      offset += n
    }
    data.removeAll()
  }

  /// Reads what's available on stdin, waiting up to `timeout` ms. Nil on timeout.
  func read(timeout: Int32, wake: Int32 = -1) -> [UInt8]? {
    var fds = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0)]
    if wake >= 0 { fds.append(pollfd(fd: wake, events: Int16(POLLIN), revents: 0)) }
    guard poll(&fds, nfds_t(fds.count), timeout) > 0 else { return nil }
    if fds.count > 1, fds[1].revents != 0 {
      var drain = [UInt8](repeating: 0, count: 64)
      _ = Darwin.read(wake, &drain, drain.count)
      if fds[0].revents == 0 { return [] }
    }
    var buf = [UInt8](repeating: 0, count: 4096)
    let n = Darwin.read(0, &buf, buf.count)
    return n > 0 ? Array(buf[0..<n]) : []
  }

  // MARK: Keys

  enum Key: Equatable {
    case char(String), enter, tab, backspace, esc, ctrl(Character)
    case up, down, left, right, pageUp, pageDown, home, end
    case click(col: Int, row: Int), wheelUp, wheelDown
  }

  /// Reads keys, waiting for input (or a wake-up, which returns []).
  func keys(wake: Int32) -> [Key] {
    guard let bytes = read(timeout: -1, wake: wake) else { return [] }
    pending += bytes
    // A lone ESC might be the start of a sequence still on its way.
    if pending == [0x1b], let more = read(timeout: 30) { pending += more }
    var keys: [Key] = []
    var i = 0
    let b = pending
    func at(_ j: Int) -> UInt8? { j < b.count ? b[j] : nil }
    while i < b.count {
      let c = b[i]
      if c == 0x1b {
        if at(i + 1) == nil { keys.append(.esc); i += 1; continue }
        if at(i + 1) == UInt8(ascii: "[") || at(i + 1) == UInt8(ascii: "O") {
          var j = i + 2
          while let x = at(j), !(0x40...0x7e).contains(x) { j += 1 }
          guard let final = at(j) else { break } // incomplete: wait for the rest
          let params = String(decoding: b[(i + 2)..<j], as: UTF8.self)
          i = j + 1
          switch (Character(UnicodeScalar(final)), params) {
          case ("A", _): keys.append(.up)
          case ("B", _): keys.append(.down)
          case ("C", _): keys.append(.right)
          case ("D", _): keys.append(.left)
          case ("H", _): keys.append(.home)
          case ("F", _): keys.append(.end)
          case ("Z", _): keys.append(.tab)
          case ("~", "5"): keys.append(.pageUp)
          case ("~", "6"): keys.append(.pageDown)
          case ("M", let p) where p.hasPrefix("<"):
            let n = p.dropFirst().split(separator: ";").compactMap { Int($0) }
            if n.count == 3 {
              if n[0] == 64 { keys.append(.wheelUp) } else if n[0] == 65 { keys.append(.wheelDown) }
              else if n[0] == 0 { keys.append(.click(col: n[1], row: n[2])) }
            }
          default: break // mouse releases, DA replies, and the rest
          }
          continue
        }
        if at(i + 1) == UInt8(ascii: "_") { // a graphics reply: skip to ST
          var j = i + 2
          while j + 1 < b.count, !(b[j] == 0x1b && b[j + 1] == UInt8(ascii: "\\")) { j += 1 }
          i = j + 2
          continue
        }
        if at(i + 1) == 0x0d { keys.append(.enter); i += 2; continue }
        keys.append(.esc); i += 1
        continue
      }
      switch c {
      case 0x0d, 0x0a: keys.append(.enter)
      case 0x09: keys.append(.tab)
      case 0x7f, 0x08: keys.append(.backspace)
      case 0x01...0x1a: keys.append(.ctrl(Character(UnicodeScalar(c + 0x60))))
      default:
        if c < 0x20 { break }
        // One UTF-8 character.
        let len = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : c >= 0xc0 ? 2 : 1
        guard i + len <= b.count else { pending = Array(b[i...]); return keys }
        keys.append(.char(String(decoding: b[i..<(i + len)], as: UTF8.self)))
        i += len
        continue
      }
      i += 1
    }
    pending = i < b.count ? Array(b[i...]) : []
    return keys
  }
}

// MARK: - Kitty graphics

private final class Graphics {
  private let term: Term
  private var ids: [String: UInt32] = [:]
  private var nextID: UInt32 = 0x57_0000 // "W", well away from ids other programs pick

  init(term: Term) { self.term = term }

  /// Uploads the image once per key, then places it at the cursor.
  func place(key: String, cols: Int, rows: Int, draw: () -> Data?) {
    let id: UInt32
    if let known = ids[key] {
      id = known
    } else {
      guard let png = draw() else { return }
      nextID += 1
      id = nextID
      ids[key] = id
      let b64 = Array(png.base64EncodedString().utf8)
      var offset = 0
      var first = true
      repeat {
        let end = min(offset + 4096, b64.count)
        let more = end < b64.count ? 1 : 0
        let head = first ? "a=t,f=100,i=\(id),q=2,m=\(more)" : "m=\(more),q=2"
        term.emit("\u{1b}_G\(head);\(String(decoding: b64[offset..<end], as: UTF8.self))\u{1b}\\")
        first = false
        offset = end
      } while offset < b64.count
      if ids.count > 300 { forgetAll() } // keep the terminal's memory in check
    }
    term.emit("\u{1b}_Ga=p,i=\(id),c=\(cols),r=\(rows),C=1,q=2\u{1b}\\")
  }

  func clearPlacements() { term.emit("\u{1b}_Ga=d,d=a,q=2\u{1b}\\") }

  func forgetAll() {
    for id in ids.values { term.emit("\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\") }
    ids = [:]
  }
}

// MARK: - Cards

private enum Reachability { case unknown, up, down, indirect }

private struct CardStyle {
  var selected = false
  var dimmed = false
  var reach = Reachability.unknown
}

private enum CardArt {
  static func png(_ c: CatalogHost, style: CardStyle, width: Int, height: Int, keyNames: Set<String>) -> Data? {
    guard width > 8, height > 8,
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let W = CGFloat(width), H = CGFloat(height)
    let h = c.host
    // Top-down coordinates.
    ctx.translateBy(x: 0, y: H)
    ctx.scaleBy(x: 1, y: -1)
    if style.dimmed { ctx.setAlpha(0.45) }

    // Card.
    let inset: CGFloat = style.selected ? max(2, H * 0.03) : max(1, H * 0.012)
    let radius = min(H * 0.2, 18)
    let card = CGRect(x: inset, y: inset, width: W - 2 * inset, height: H - 2 * inset)
    let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let top = style.selected ? rgb(0x15, 0x30, 0x33) : rgb(0x1c, 0x22, 0x2a)
    let bottom = style.selected ? rgb(0x0f, 0x21, 0x24) : rgb(0x14, 0x19, 0x1f)
    let fill = CGGradient(colorsSpace: nil, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H), options: [])
    ctx.restoreGState()
    ctx.addPath(path)
    ctx.setStrokeColor(style.selected ? rgb(0x2f, 0xd4, 0xc4) : rgb(0x2c, 0x34, 0x3e))
    ctx.setLineWidth(style.selected ? inset : max(1, H * 0.012))
    ctx.strokePath()

    // Avatar: initials on a gradient picked from the name.
    let pad = H * 0.17
    let d = H - 2 * pad
    let avatar = CGRect(x: inset + pad * 0.8, y: pad, width: d, height: d)
    let hue = CGFloat(stableHash(h.sshAlias) % 360) / 360
    ctx.saveGState()
    ctx.addEllipse(in: avatar)
    ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [hsb(hue, 0.55, 0.85), hsb(hue + 0.08, 0.7, 0.55)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: avatar.origin, end: CGPoint(x: avatar.maxX, y: avatar.maxY), options: [])
    ctx.restoreGState()
    let initials = Self.initials(h.alias)
    drawText(ctx, initials, font: font(d * 0.38, bold: true), color: rgb(255, 255, 255),
             center: CGPoint(x: avatar.midX, y: avatar.midY))

    // Text.
    let x = avatar.maxX + pad * 0.8
    let right = W - inset - pad * 0.8
    let dotR = max(2.5, H * 0.045)
    let titleSize = H * 0.22
    drawText(ctx, h.alias, font: font(titleSize, bold: true), color: rgb(0xe6, 0xed, 0xf3),
             at: CGPoint(x: x, y: pad - H * 0.02), maxWidth: right - x - dotR * 3)
    let subtitle: String = {
      if c.source == .sshConfig && h.hostName == nil { return "from ~/.ssh/config" }
      return (h.user.map { "\($0)@" } ?? "") + (h.hostName ?? h.alias) + (h.port.map { ":\($0)" } ?? "")
    }()
    drawText(ctx, subtitle, font: font(H * 0.14, mono: true), color: rgb(0x8b, 0x94, 0x9e),
             at: CGPoint(x: x, y: pad + titleSize * 1.12), maxWidth: right - x)

    // Chips along the bottom.
    var chips: [(String, CGColor)] = []
    switch c.source {
    case .blink: chips.append(("Blink", rgb(0x2f, 0xd4, 0xc4)))
    case .edited: chips.append(("Blink · edited", rgb(0xe3, 0xb3, 0x41)))
    case .wink: chips.append(("Wink", rgb(0xb3, 0x92, 0xf0)))
    case .sshConfig: chips.append(("ssh config", rgb(0x8b, 0x94, 0x9e)))
    }
    if c.hidden { chips.append(("hidden", rgb(0xf8, 0x51, 0x49))) }
    if let key = h.key, key != "None" {
      chips.append(("key \(key)", keyNames.contains(key) ? rgb(0x9e, 0xa7, 0xb3) : rgb(0xf8, 0x51, 0x49)))
    }
    if h.proxyJump != nil || h.proxyCommand != nil {
      chips.append(("via \(h.proxyJump ?? "proxy")", rgb(0x9e, 0xa7, 0xb3)))
    }
    let tunnels = h.tunnels.count
    if tunnels > 0 { chips.append(("\(tunnels) tunnel\(tunnels == 1 ? "" : "s")", rgb(0x58, 0xa6, 0xff))) }
    if h.forwardAgent { chips.append(("agent", rgb(0x9e, 0xa7, 0xb3))) }
    if h.moshServer != nil || h.moshPort != nil || h.moshStartup != nil { chips.append(("mosh", rgb(0x9e, 0xa7, 0xb3))) }
    let chipFont = font(H * 0.115, bold: true)
    let chipH = H * 0.2
    var cx = x
    let cy = H - pad - chipH + H * 0.03
    for (text, color) in chips {
      let w = textWidth(text, font: chipFont) + chipH * 0.9
      if cx + w > right { break }
      let r = CGRect(x: cx, y: cy, width: w, height: chipH)
      ctx.addPath(CGPath(roundedRect: r, cornerWidth: chipH / 2, cornerHeight: chipH / 2, transform: nil))
      ctx.setFillColor(color.copy(alpha: 0.16)!)
      ctx.fillPath()
      drawText(ctx, text, font: chipFont, color: color, center: CGPoint(x: r.midX, y: r.midY))
      cx += w + chipH * 0.35
    }

    // Reachability dot.
    let dotColor: CGColor
    switch style.reach {
    case .up: dotColor = rgb(0x3f, 0xb9, 0x50)
    case .down: dotColor = rgb(0xf8, 0x51, 0x49)
    case .indirect: dotColor = rgb(0x58, 0xa6, 0xff)
    case .unknown: dotColor = rgb(0x48, 0x50, 0x5a)
    }
    let dot = CGRect(x: right - dotR * 2, y: pad + titleSize * 0.35, width: dotR * 2, height: dotR * 2)
    if style.reach == .up {
      ctx.setFillColor(dotColor.copy(alpha: 0.25)!)
      ctx.fillEllipse(in: dot.insetBy(dx: -dotR * 0.7, dy: -dotR * 0.7))
    }
    ctx.setFillColor(dotColor)
    ctx.fillEllipse(in: dot)

    guard let image = ctx.makeImage() else { return nil }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest) ? data as Data : nil
  }

  static func initials(_ alias: String) -> String {
    let parts = alias.split(whereSeparator: { "-_. @".contains($0) }).filter { !$0.isEmpty }
    let letters = parts.count >= 2 ? [parts[0].first!, parts[1].first!] : Array(alias.prefix(2))
    return String(letters).uppercased()
  }

  static func stableHash(_ s: String) -> Int {
    var h: UInt32 = 2166136261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return Int(h % 100_000)
  }

  private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
  }

  private static func hsb(_ h: CGFloat, _ s: CGFloat, _ v: CGFloat) -> CGColor {
    let h = (h.truncatingRemainder(dividingBy: 1)) * 6
    let i = Int(h), f = h - CGFloat(i)
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    let (r, g, b): (CGFloat, CGFloat, CGFloat) = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i % 6]
    return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
  }

  private static func font(_ size: CGFloat, bold: Bool = false, mono: Bool = false) -> CTFont {
    if mono { return CTFontCreateWithName("Menlo" as CFString, size, nil) }
    let base = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)!
    return base
  }

  private static func line(_ s: String, font: CTFont, color: CGColor) -> CTLine {
    let attrs: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
  }

  private static func textWidth(_ s: String, font: CTFont) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(line(s, font: font, color: CGColor(gray: 1, alpha: 1)), nil, nil, nil))
  }

  /// Draws one line with its top at `at`, truncated with … to `maxWidth`.
  private static func drawText(_ ctx: CGContext, _ s: String, font: CTFont, color: CGColor,
                               at: CGPoint, maxWidth: CGFloat) {
    var l = line(s, font: font, color: color)
    if CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) > maxWidth {
      let dots = line("…", font: font, color: color)
      l = CTLineCreateTruncatedLine(l, Double(max(0, maxWidth)), .end, dots) ?? l
    }
    draw(ctx, l, baseline: CGPoint(x: at.x, y: at.y + CTFontGetAscent(font)))
  }

  private static func drawText(_ ctx: CGContext, _ s: String, font: CTFont, color: CGColor, center: CGPoint) {
    let l = line(s, font: font, color: color)
    let w = CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    let capHeight = CTFontGetCapHeight(font)
    draw(ctx, l, baseline: CGPoint(x: center.x - w / 2, y: center.y + capHeight / 2))
  }

  /// CoreText draws y-up; flip back locally for the line.
  private static func draw(_ ctx: CGContext, _ l: CTLine, baseline: CGPoint) {
    ctx.saveGState()
    ctx.translateBy(x: baseline.x, y: baseline.y)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textPosition = .zero
    CTLineDraw(l, ctx)
    ctx.restoreGState()
  }
}

// MARK: - Reachability

/// A TCP connect to each host's ssh port, a few at a time. Hosts behind a
/// jump host or proxy command aren't probed.
private final class Prober {
  private let lock = NSLock()
  private var results: [String: Reachability] = [:]
  private var started = Set<String>()
  private let queue = DispatchQueue(label: "wink.hosts.probe", attributes: .concurrent)
  private let limit = DispatchSemaphore(value: 8)
  var onChange: () -> Void = {}

  private var resolvedHosts: [String: BlinkHost] = [:]

  func state(_ h: BlinkHost) -> Reachability {
    let h = resolved(h)
    if h.proxyJump != nil || h.proxyCommand != nil { return .indirect }
    lock.lock(); defer { lock.unlock() }
    return results[h.sshAlias] ?? .unknown
  }

  /// ~/.ssh/config hosts only have a name; `ssh -G` fills in the rest.
  func resolved(_ h: BlinkHost) -> BlinkHost {
    lock.lock(); defer { lock.unlock() }
    return resolvedHosts[h.sshAlias] ?? h
  }

  func reset() { lock.lock(); results = [:]; started = []; resolvedHosts = [:]; lock.unlock() }

  func probe(_ h: BlinkHost, resolve: Bool = false) {
    guard h.proxyJump == nil, h.proxyCommand == nil else { return }
    lock.lock()
    let fresh = started.insert(h.sshAlias).inserted
    lock.unlock()
    guard fresh else { return }
    queue.async {
      self.limit.wait()
      var h = h
      if resolve, let r = Self.sshG(h.alias) {
        h = r
        self.lock.lock(); self.resolvedHosts[h.sshAlias] = r; self.lock.unlock()
        self.onChange()
      }
      guard h.proxyJump == nil, h.proxyCommand == nil,
            let port = NWEndpoint.Port(rawValue: UInt16(h.port ?? 22)) else { self.limit.signal(); return }
      let alias = h.sshAlias
      let host = h.hostName ?? h.alias
      let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
      var done = false
      let finish: (Reachability) -> Void = { r in
        self.lock.lock()
        let first = !done
        done = true
        if first { self.results[alias] = r }
        self.lock.unlock()
        guard first else { return }
        conn.cancel()
        self.limit.signal()
        self.onChange()
      }
      conn.stateUpdateHandler = { state in
        switch state {
        case .ready: finish(.up)
        case .failed, .waiting: finish(.down)
        default: break
        }
      }
      conn.start(queue: self.queue)
      self.queue.asyncAfter(deadline: .now() + 2.5) { finish(.down) }
    }
  }

  private static func sshG(_ alias: String) -> BlinkHost? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    p.arguments = ["-G", "--", alias]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    var h = BlinkHost(alias: alias)
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { continue }
      switch parts[0] {
      case "hostname": h.hostName = parts[1]
      case "user": h.user = parts[1]
      case "port": h.port = Int(parts[1]).flatMap { $0 == 22 ? nil : $0 }
      case "proxyjump" where parts[1] != "none": h.proxyJump = parts[1]
      case "proxycommand" where parts[1] != "none": h.proxyCommand = parts[1]
      default: break
      }
    }
    return h
  }
}

// MARK: - The picker

private final class PickerUI {
  let term = Term()
  lazy var gfx = Graphics(term: term)
  let prober = Prober()
  var wakeRead: Int32 = -1, wakeWrite: Int32 = -1
  var winch: DispatchSourceSignal?

  var catalog = HostCatalog.load()
  var query = ""
  var showHidden = false
  var useMosh = false
  var selected = 0
  var scrollRow = 0
  var message = ""
  var confirm: (prompt: String, action: () -> Void)?
  var editor: HostEditor?

  // Layout from the last draw, for mouse clicks.
  var gridCols = 1, cardW = 30, cardH = 4, gridLeft = 3, gridTop = 5
  let gapCols = 2, gapRows = 1

  init() {
    var fds: [Int32] = [0, 0]
    pipe(&fds)
    wakeRead = fds[0]; wakeWrite = fds[1]
    _ = fcntl(wakeRead, F_SETFL, O_NONBLOCK)
    prober.onChange = { [wakeWrite] in var b: UInt8 = 1; _ = write(wakeWrite, &b, 1) }
    signal(SIGWINCH, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    s.setEventHandler { [wakeWrite] in var b: UInt8 = 2; _ = write(wakeWrite, &b, 1) }
    s.resume()
    winch = s
  }

  var visible: [CatalogHost] {
    let base = catalog.hosts.filter { showHidden || !$0.hidden }
    let q = query.lowercased()
    guard !q.isEmpty else { return base }
    return base.compactMap { c -> (CatalogHost, Int)? in
      let alias = c.host.alias.lowercased()
      let rest = [c.host.hostName, c.host.user].compactMap { $0?.lowercased() }.joined(separator: " ")
      if alias.hasPrefix(q) { return (c, 0) }
      if alias.contains(q) { return (c, 1) }
      if isSubsequence(q, of: alias) { return (c, 2) }
      if rest.contains(q) { return (c, 3) }
      return nil
    }.sorted { $0.1 < $1.1 }.map(\.0)
  }

  func isSubsequence(_ q: String, of s: String) -> Bool {
    var it = s.makeIterator()
    return q.allSatisfy { ch in
      while let x = it.next() { if x == ch { return true } }
      return false
    }
  }

  func loop() -> Never {
    term.enter()
    while true {
      if let editor {
        editor.draw()
      } else {
        draw()
      }
      for key in term.keys(wake: wakeRead) {
        if let editor {
          if !editor.handle(key) { self.editor = nil; reload(select: editor.savedAlias) }
        } else {
          handle(key)
        }
      }
      term.updateSize()
    }
  }

  func reload(select alias: String? = nil) {
    catalog = HostCatalog.load()
    if let alias, let i = visible.firstIndex(where: { $0.host.sshAlias == alias }) { selected = i }
  }

  func quit(_ code: Int32) -> Never {
    if term.graphics { gfx.clearPlacements(); gfx.forgetAll() }
    term.leave()
    exit(code)
  }

  // MARK: Keys

  func handle(_ key: Term.Key) {
    let hosts = visible
    if let pending = confirm {
      confirm = nil
      if key == .char("y") || key == .char("Y") { pending.action() } else { message = "Cancelled." }
      return
    }
    message = ""
    switch key {
    case .char(let s): query += s; selected = 0; scrollRow = 0
    case .backspace: if !query.isEmpty { query.removeLast(); selected = 0 }
    case .ctrl("u"): query = ""; selected = 0
    case .left: selected = max(0, selected - 1)
    case .right: selected = min(max(0, hosts.count - 1), selected + 1)
    case .up: if selected - gridCols >= 0 { selected -= gridCols }
    case .down: selected = min(max(0, hosts.count - 1), selected + gridCols)
    case .wheelUp: if selected - gridCols >= 0 { selected -= gridCols }
    case .wheelDown: selected = min(max(0, hosts.count - 1), selected + gridCols)
    case .pageUp: selected = max(0, selected - gridCols * 3)
    case .pageDown: selected = min(max(0, hosts.count - 1), selected + gridCols * 3)
    case .home: selected = 0
    case .end: selected = max(0, hosts.count - 1)
    case .tab: useMosh.toggle()
    case .enter: if hosts.indices.contains(selected) { connect(hosts[selected].host) }
    case .esc: if query.isEmpty { quit(0) } else { query = ""; selected = 0 }
    case .ctrl("c"), .ctrl("q"): quit(0)
    case .ctrl("a"): showHidden.toggle(); selected = 0
    case .ctrl("r"): prober.reset(); reload(); message = "Reloaded."
    case .ctrl("n"):
      editor = HostEditor(ui: self, original: nil, draft: BlinkHost(alias: query.filter { !$0.isWhitespace }))
    case .ctrl("e"):
      guard hosts.indices.contains(selected) else { return }
      let c = hosts[selected]
      guard c.isEditable else { message = "This host is in ~/.ssh/config: edit it there (Hosts ▸ Edit ~/.ssh/config)."; return }
      editor = HostEditor(ui: self, original: c, draft: c.host)
    case .ctrl("x"):
      if hosts.indices.contains(selected) { remove(hosts[selected]) }
    case .click(let col, let row):
      if let i = index(atCol: col, row: row), i < hosts.count {
        if i == selected { connect(hosts[i].host) } else { selected = i }
      }
    default: break
    }
  }

  func index(atCol col: Int, row: Int) -> Int? {
    guard col >= gridLeft, row >= gridTop else { return nil }
    let cx = (col - gridLeft) / (cardW + gapCols), cy = (row - gridTop) / (cardH + gapRows)
    guard cx < gridCols, (col - gridLeft) % (cardW + gapCols) < cardW,
          (row - gridTop) % (cardH + gapRows) < cardH else { return nil }
    return (scrollRow + cy) * gridCols + cx
  }

  func remove(_ c: CatalogHost) {
    let alias = c.host.sshAlias
    var edits = HostCatalog.edits()
    switch c.source {
    case .sshConfig:
      message = "This host is in ~/.ssh/config: edit it there."
    case .wink:
      confirm = ("Delete \(alias)? (y/n)", { [self] in
        edits.hosts.removeAll { $0.sshAlias == alias }
        save(edits, "Deleted \(alias).")
      })
    case .edited:
      confirm = ("Drop your changes to \(alias) and use Blink's version? (y/n)", { [self] in
        edits.hosts.removeAll { $0.sshAlias == alias }
        save(edits, "\(alias) is back to Blink's version.")
      })
    case .blink where c.hidden:
      edits.hidden.removeAll { $0 == alias }
      save(edits, "\(alias) is shown again.")
    case .blink:
      confirm = ("Hide \(alias) in Wink and other terminals? It stays in Blink. (y/n)", { [self] in
        edits.hidden.append(alias)
        save(edits, "Hid \(alias). ^A shows hidden hosts.")
      })
    }
  }

  func save(_ edits: HostEdits, _ done: String) {
    do {
      try HostCatalog.save(edits)
      reload()
      selected = min(selected, max(0, visible.count - 1))
      message = done
    } catch {
      message = "Couldn't save: \(error.localizedDescription)"
    }
  }

  func connect(_ h: BlinkHost) -> Never {
    let cmd = useMosh ? BlinkConfig.shared.moshCommand(for: h) : BlinkConfig.shared.sshCommand(for: h)
    if term.graphics { gfx.clearPlacements(); gfx.forgetAll() }
    term.leave()
    // Name the tab after the host; ssh doesn't.
    print("\u{1b}]2;\(h.alias)\(useMosh ? " (mosh)" : "")\u{07}\u{1b}[2m\(cmd.joined(separator: " "))\u{1b}[0m")
    fflush(stdout)
    var argv = cmd.map { strdup($0) }
    argv.append(nil)
    execvp(cmd[0], argv)
    print("wink: couldn't run \(cmd[0]): \(String(cString: strerror(errno)))")
    exit(1)
  }

  // MARK: Drawing

  static let teal = "\u{1b}[38;2;47;212;196m"
  static let dim = "\u{1b}[38;2;139;148;158m"
  static let bright = "\u{1b}[38;2;230;237;243m"
  static let reset = "\u{1b}[0m"

  func draw() {
    let t = term
    let hosts = visible
    selected = min(selected, max(0, hosts.count - 1))

    // Grid geometry.
    let margin = 3
    let usable = max(20, t.cols - 2 * margin)
    gridCols = max(1, (usable + gapCols) / (34 + gapCols))
    cardW = min(52, (usable - (gridCols - 1) * gapCols) / gridCols)
    cardH = t.cellH > 0 && t.cellW / t.cellH > 0.62 ? 3 : 4
    let gridWidth = gridCols * cardW + (gridCols - 1) * gapCols
    gridLeft = max(1, (t.cols - gridWidth) / 2 + 1)
    gridTop = 5
    let rowsAvailable = max(1, (t.rows - gridTop - 1 + gapRows) / (cardH + gapRows))
    let selRow = selected / gridCols
    if selRow < scrollRow { scrollRow = selRow }
    if selRow >= scrollRow + rowsAvailable { scrollRow = selRow - rowsAvailable + 1 }

    t.emit("\u{1b}[?2026h")
    if t.graphics { gfx.clearPlacements() }
    t.emit("\u{1b}[0m\u{1b}[H\u{1b}[2J")

    // Header: title, mode and the search field.
    let mode = useMosh ? "mosh" : "ssh"
    t.emit("\u{1b}[2;\(gridLeft)H\u{1b}[1m\(Self.bright)Connect\(Self.reset)  \(Self.dim)with\(Self.reset) "
      + "\u{1b}[1m\(Self.teal)\(mode)\(Self.reset)\(Self.dim)  (⇥ switches)\(Self.reset)")
    let count = "\(hosts.count) host\(hosts.count == 1 ? "" : "s")" + (showHidden ? " · showing hidden" : "")
    t.emit("\u{1b}[2;\(max(1, gridLeft + gridWidth - count.count))H\(Self.dim)\(count)\(Self.reset)")
    let field = query.isEmpty ? "\(Self.dim)type to filter\(Self.reset)" : "\(Self.bright)\(query)\(Self.reset)"
    t.emit("\u{1b}[3;\(gridLeft)H\(Self.teal)›\(Self.reset) \(field)\(Self.teal)▏\(Self.reset)")

    if hosts.isEmpty {
      let note = catalog.hosts.isEmpty
        ? (catalog.blinkLoaded ? "No hosts yet. ^N adds one." : "No hosts yet. Open Wink once to load Blink's hosts, or ^N to add one.")
        : "No host matches “\(query)”. ^N adds it."
      t.emit("\u{1b}[\(gridTop + 1);\(gridLeft)H\(Self.dim)\(note)\(Self.reset)")
    }

    let keys = Set(catalog.keyNames)
    for row in 0..<rowsAvailable {
      for col in 0..<gridCols {
        let i = (scrollRow + row) * gridCols + col
        guard i < hosts.count else { break }
        var c = hosts[i]
        prober.probe(c.host, resolve: c.source == .sshConfig)
        if c.source == .sshConfig { c.host = prober.resolved(c.host) }
        let x = gridLeft + col * (cardW + gapCols)
        let y = gridTop + row * (cardH + gapRows)
        let style = CardStyle(selected: i == selected, dimmed: c.hidden, reach: prober.state(c.host))
        if t.graphics {
          t.emit("\u{1b}[\(y);\(x)H")
          let pw = Int(Double(cardW) * t.cellW), ph = Int(Double(cardH) * t.cellH)
          let key = "\(c.host)|\(c.source)|\(c.hidden)|\(style.selected)|\(style.reach)|\(pw)x\(ph)|\(keys.contains(c.host.key ?? ""))"
          gfx.place(key: key, cols: cardW, rows: cardH) {
            CardArt.png(c, style: style, width: pw, height: ph, keyNames: keys)
          }
        } else {
          drawTextCard(c, style: style, x: x, y: y)
        }
      }
    }

    // Footer.
    let footer: String
    if let confirm { footer = "\u{1b}[1m\(Self.bright)\(confirm.prompt)\(Self.reset)" }
    else if !message.isEmpty { footer = "\(Self.bright)\(message)\(Self.reset)" }
    else {
      footer = "\(Self.dim)↵ connect  ⇥ ssh/mosh  ^E edit  ^N new  ^X hide/delete  ^A hidden  ^R reload  esc quit\(Self.reset)"
    }
    t.emit("\u{1b}[\(t.rows);\(gridLeft)H\(footer)")
    t.emit("\u{1b}[?2026l")
    t.flush()
  }

  func drawTextCard(_ c: CatalogHost, style: CardStyle, x: Int, y: Int) {
    let t = term
    let border = style.selected ? Self.teal : Self.dim
    let inner = cardW - 2
    func clip(_ s: String, _ n: Int) -> String { s.count > n ? String(s.prefix(max(0, n - 1))) + "…" : s }
    func pad(_ s: String, _ n: Int) -> String { s + String(repeating: " ", count: max(0, n - s.count)) }
    let dot: String
    switch style.reach {
    case .up: dot = "\u{1b}[38;2;63;185;80m●"
    case .down: dot = "\u{1b}[38;2;248;81;73m●"
    case .indirect: dot = "\u{1b}[38;2;88;166;255m●"
    case .unknown: dot = "\(Self.dim)○"
    }
    let h = c.host
    let sub = (h.user.map { "\($0)@" } ?? "") + (h.hostName ?? (c.source == .sshConfig ? "~/.ssh/config" : h.alias))
    let source = [CatalogHost.Source.blink: "Blink", .edited: "Blink·edited", .wink: "Wink", .sshConfig: "ssh config"][c.source]!
    let title = clip(h.alias, inner - 4)
    t.emit("\u{1b}[\(y);\(x)H\(border)╭\(String(repeating: "─", count: inner))╮")
    t.emit("\u{1b}[\(y + 1);\(x)H\(border)│\(Self.reset) \(dot)\(Self.reset) \u{1b}[1m\(Self.bright)\(pad(title, inner - 4))\(Self.reset) \(border)│")
    if cardH >= 4 {
      t.emit("\u{1b}[\(y + 2);\(x)H\(border)│\(Self.reset)   \(Self.dim)\(pad(clip(sub, inner - 4), inner - 3))\(border)│")
    }
    let n = h.tunnels.count
    let label = clip(" \(source)\(n == 0 ? "" : " · \(n) tunnel\(n == 1 ? "" : "s")") ", inner - 2)
    t.emit("\u{1b}[\(y + cardH - 1);\(x)H\(border)╰─\(Self.reset)\(Self.dim)\(label)\(border)"
      + "\(String(repeating: "─", count: max(0, inner - 1 - label.count)))╯\(Self.reset)")
  }
}

// MARK: - Editing a host

private final class HostEditor {
  unowned let ui: PickerUI
  let original: CatalogHost?
  var d: BlinkHost
  var tunnels: [String]
  var extra: [String]
  var row = 0
  var top = 0
  var message = ""
  var confirmDiscard = false
  private(set) var savedAlias: String?

  struct Row {
    enum Kind { case section, text, choice, item, add }
    var kind: Kind
    var label: String
    var placeholder = ""
    var get: (HostEditor) -> String = { _ in "" }
    var set: (HostEditor, String) -> Void = { _, _ in }
    var cycle: (HostEditor, Int) -> Void = { _, _ in }
    var remove: ((HostEditor) -> Void)? = nil
    var add: ((HostEditor) -> Void)? = nil
  }

  init(ui: PickerUI, original: CatalogHost?, draft: BlinkHost) {
    self.ui = ui
    self.original = original
    d = draft
    tunnels = draft.tunnels
    extra = draft.extraLines
    row = rows.firstIndex { $0.kind != .section } ?? 0
  }

  static let predictions = ["adaptive", "always", "never", "experimental"]
  static let remoteIPs = ["default", "local", "remote"]

  private func text(_ label: String, _ kp: WritableKeyPath<BlinkHost, String?>, _ placeholder: String = "") -> Row {
    Row(kind: .text, label: label, placeholder: placeholder,
        get: { $0.d[keyPath: kp] ?? "" },
        set: { e, v in e.d[keyPath: kp] = v.isEmpty ? nil : v })
  }

  private func number(_ label: String, _ kp: WritableKeyPath<BlinkHost, Int?>, _ placeholder: String) -> Row {
    Row(kind: .text, label: label, placeholder: placeholder,
        get: { $0.d[keyPath: kp].map(String.init) ?? $0.pendingNumbers[label] ?? "" },
        set: { e, v in
          e.pendingNumbers[label] = v.isEmpty ? nil : v
          e.d[keyPath: kp] = Int(v)
        })
  }
  /// What's typed in number fields, so "60001:" can be on its way to "60001:60010".
  var pendingNumbers: [String: String] = [:]

  var rows: [Row] {
    var r: [Row] = [
      Row(kind: .section, label: "Host"),
      Row(kind: .text, label: "Name", placeholder: "what you type after ssh",
          get: { $0.d.alias }, set: { e, v in e.d.alias = v }),
      text("HostName", \.hostName, "address or DNS name"),
      text("User", \.user, "your login name"),
      number("Port", \.port, "22"),
      Row(kind: .choice, label: "Key", get: { $0.d.key ?? "None" }, cycle: { e, step in
        let names = ["None"] + e.ui.catalog.keyNames
        let i = names.firstIndex(of: e.d.key ?? "None") ?? 0
        let next = names[(i + step + names.count) % names.count]
        e.d.key = next == "None" ? nil : next
      }),
      Row(kind: .section, label: "Route"),
      text("ProxyJump", \.proxyJump, "jump host, e.g. bastion"),
      text("ProxyCommand", \.proxyCommand, "e.g. cloudflared access ssh --hostname %h"),
      Row(kind: .choice, label: "Forward agent", get: { $0.d.forwardAgent ? "yes" : "no" },
          cycle: { e, _ in e.d.forwardAgent.toggle() }),
      Row(kind: .section, label: "Tunnels"),
    ]
    for i in tunnels.indices {
      r.append(Row(kind: .item, label: "Tunnel", placeholder: "L 8080 localhost:80",
                   get: { $0.tunnels.indices.contains(i) ? $0.tunnels[i] : "" },
                   set: { e, v in e.tunnels[i] = v }, remove: { $0.tunnels.remove(at: i) }))
    }
    r.append(Row(kind: .add, label: "+ Add tunnel", add: { $0.tunnels.append("L ") }))
    r += [
      Row(kind: .section, label: "Mosh"),
      text("Server", \.moshServer, "mosh-server path, e.g. /opt/homebrew/bin/mosh-server"),
      Row(kind: .text, label: "UDP ports", placeholder: "60001 or 60001:60010",
          get: { e in e.pendingPorts ?? [e.d.moshPort.map(String.init), e.d.moshPortEnd.map(String.init)]
            .compactMap { $0 }.joined(separator: ":") },
          set: { e, v in
            e.pendingPorts = v
            let parts = v.split(separator: ":").map { Int($0) }
            e.d.moshPort = parts.first ?? nil
            e.d.moshPortEnd = parts.count > 1 ? parts[1] : nil
          }),
      Row(kind: .choice, label: "Prediction", get: { Self.predictions[min(3, max(0, $0.d.moshPrediction ?? 0))] },
          cycle: { e, step in e.d.moshPrediction = ((e.d.moshPrediction ?? 0) + step + 4) % 4 }),
      Row(kind: .choice, label: "Remote IP", get: { Self.remoteIPs[min(2, max(0, $0.d.moshExperimentalIP ?? 0))] },
          cycle: { e, step in e.d.moshExperimentalIP = ((e.d.moshExperimentalIP ?? 0) + step + 3) % 3 }),
      text("Startup", \.moshStartup, "command to run, e.g. tmux new -As main"),
      Row(kind: .section, label: "More ssh config"),
    ]
    for i in extra.indices {
      r.append(Row(kind: .item, label: "Line", placeholder: "ServerAliveInterval 30",
                   get: { $0.extra.indices.contains(i) ? $0.extra[i] : "" },
                   set: { e, v in e.extra[i] = v }, remove: { $0.extra.remove(at: i) }))
    }
    r.append(Row(kind: .add, label: "+ Add line", add: { $0.extra.append("") }))
    return r
  }
  var pendingPorts: String?

  var built: BlinkHost {
    var h = d
    h.setConfig(tunnels: tunnels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 },
                extra: extra.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    return h
  }

  var isDirty: Bool { original.map { built != $0.host } ?? true }

  /// Returns false when the editor is done.
  func handle(_ key: Term.Key) -> Bool {
    let rows = self.rows
    if confirmDiscard {
      confirmDiscard = false
      if key == .char("y") || key == .char("Y") { return false }
      message = ""
      return true
    }
    message = ""
    let current = rows.indices.contains(row) ? rows[row] : nil
    func move(_ step: Int) {
      var i = row + step
      while rows.indices.contains(i), rows[i].kind == .section { i += step }
      if rows.indices.contains(i) { row = i }
    }
    switch key {
    case .up: move(-1)
    case .down, .tab: move(1)
    case .wheelUp: move(-1)
    case .wheelDown: move(1)
    case .esc:
      if isDirty { confirmDiscard = true; message = "Discard your changes? (y/n)" } else { return false }
    case .ctrl("c"): return false
    case .ctrl("s"): return !save()
    case .ctrl("x"):
      if let current, let remove = current.remove { remove(self); move(0); if row >= self.rows.count { row = self.rows.count - 1 } }
    case .enter:
      if let current, current.kind == .add, let add = current.add { add(self) } else { move(1) }
    case .left, .right:
      if let current, current.kind == .choice { current.cycle(self, key == .left ? -1 : 1) }
    case .char(" ") where current?.kind == .choice:
      current?.cycle(self, 1)
    case .char(let s):
      if let current, current.kind == .text || current.kind == .item { current.set(self, current.get(self) + s) }
    case .backspace:
      if let current, current.kind == .text || current.kind == .item {
        var v = current.get(self)
        if !v.isEmpty { v.removeLast() }
        current.set(self, v)
      }
    case .ctrl("u"):
      if let current, current.kind == .text || current.kind == .item { current.set(self, "") }
    default: break
    }
    return true
  }

  // MARK: Saving

  func save() -> Bool {
    let h = built
    if let problem = validate(h) { message = problem; return false }
    guard isDirty else { savedAlias = h.sshAlias; return true }
    var edits = HostCatalog.edits()
    if let o = original, o.source != .blink { edits.hosts.removeAll { $0.sshAlias == o.host.sshAlias } }
    // Renaming a Blink host: the new name replaces it.
    if let o = original, o.source != .wink, o.host.sshAlias != h.sshAlias, !edits.hidden.contains(o.host.sshAlias) {
      edits.hidden.append(o.host.sshAlias)
      edits.hosts.removeAll { $0.sshAlias == o.host.sshAlias }
    }
    edits.hosts.removeAll { $0.sshAlias == h.sshAlias }
    edits.hosts.append(h)
    do {
      try HostCatalog.save(edits)
      savedAlias = h.sshAlias
      ui.message = "Saved \(h.alias)."
      return true
    } catch {
      message = "Couldn't save: \(error.localizedDescription)"
      return false
    }
  }

  func validate(_ h: BlinkHost) -> String? {
    let alias = h.alias
    if alias.isEmpty { return "Give the host a name." }
    if alias.contains(where: { $0.isWhitespace || "#\"'*?!,".contains($0) }) || alias.hasPrefix("-") {
      return "The name can't contain spaces, quotes, #, *, ?, ! or commas, or start with -."
    }
    let taken = ui.catalog.hosts.contains { $0.host.sshAlias == alias && $0.host.sshAlias != original?.host.sshAlias }
    if taken { return "There's already a host named \(alias)." }
    let fields = [h.hostName, h.user, h.proxyJump, h.proxyCommand, h.moshServer, h.moshStartup].compactMap { $0 }
      + tunnels + extra
    if fields.contains(where: { $0.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f } }) {
      return "Fields can't contain control characters."
    }
    if let v = pendingNumbers["Port"], h.port == nil || !(1...65535).contains(h.port!) || String(h.port!) != v {
      return "Port must be a number from 1 to 65535."
    }
    if let v = pendingPorts, !v.isEmpty,
       v.range(of: "^[0-9]{1,5}(:[0-9]{1,5})?$", options: .regularExpression) == nil {
      return "UDP ports are a port, or a range like 60001:60010."
    }
    for t in tunnels.map({ $0.trimmingCharacters(in: .whitespaces) }) where t.count > 1 {
      let parts = t.split(separator: " ").map(String.init)
      // A listen side is [address:]port or a socket path; a target is host:port or a socket path.
      func listen(_ s: String) -> Bool {
        s.hasPrefix("/") || s.range(of: "^(.+:)?[0-9]{1,5}$", options: .regularExpression) != nil
      }
      func target(_ s: String) -> Bool {
        s.hasPrefix("/") || s.range(of: "^.+:[0-9]{1,5}$", options: .regularExpression) != nil
      }
      switch parts.first?.uppercased() {
      case "L", "R":
        if parts.count != 3 || !listen(parts[1]) || !target(parts[2]) {
          return "Tunnel “\(t)”: use L or R, a port, then host:port (L 8080 localhost:80)."
        }
      case "D":
        if parts.count != 2 || !listen(parts[1]) { return "Tunnel “\(t)”: use D and a port (D 1080)." }
      default: return "Tunnel “\(t)”: start with L (local), R (remote) or D (SOCKS)."
      }
    }
    for line in extra where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      let (key, value) = LocalSSHConfig.split(line)
      if value.isEmpty || key.isEmpty || !key.allSatisfy(\.isLetter) {
        return "“\(line)” isn't an ssh config line (Keyword value)."
      }
      if ["host", "match", "include"].contains(key) { return "Host, Match and Include can't go inside a host." }
    }
    return nil
  }

  // MARK: Drawing

  func draw() {
    let t = ui.term
    let rows = self.rows
    let left = 4
    t.emit("\u{1b}[?2026h")
    if t.graphics { ui.gfx.clearPlacements() }
    t.emit("\u{1b}[0m\u{1b}[H\u{1b}[2J")

    // The card as it'll look, at the top.
    var y = 2
    let preview = CatalogHost(host: built, source: original?.source == .blink ? .edited : (original?.source ?? .wink))
    let cardCols = min(52, max(30, t.cols - 2 * left))
    let cardRows = 4
    if t.graphics {
      t.emit("\u{1b}[\(y);\(left)H")
      let pw = Int(Double(cardCols) * t.cellW), ph = Int(Double(cardRows) * t.cellH)
      let keys = Set(ui.catalog.keyNames)
      ui.gfx.place(key: "edit|\(preview.host)|\(pw)x\(ph)", cols: cardCols, rows: cardRows) {
        CardArt.png(preview, style: CardStyle(selected: true), width: pw, height: ph, keyNames: keys)
      }
      y += cardRows + 1
    } else {
      let title = original == nil ? "New host" : "Edit \(original!.host.alias)"
      t.emit("\u{1b}[\(y);\(left)H\u{1b}[1m\(PickerUI.bright)\(title)\(PickerUI.reset)")
      y += 2
    }

    // The form, scrolled so the current row shows.
    let height = max(3, t.rows - y - 1)
    if row < top { top = row }
    if row >= top + height { top = row - height + 1 }
    if top > 0, rows[top].kind != .section, rows.indices.contains(top - 1), rows[top - 1].kind == .section,
       row - (top - 1) < height { top -= 1 }
    let labelWidth = 15
    for (n, i) in (top..<min(rows.count, top + height)).enumerated() {
      let r = rows[i]
      let line = y + n
      let isCurrent = i == row
      t.emit("\u{1b}[\(line);\(left)H")
      switch r.kind {
      case .section:
        t.emit("\u{1b}[1m\(PickerUI.teal)\(r.label.uppercased())\(PickerUI.reset)")
      case .add:
        t.emit(isCurrent ? "\(PickerUI.teal)▌\u{1b}[1m \(r.label)\(PickerUI.reset)" : "\(PickerUI.dim)  \(r.label)\(PickerUI.reset)")
      default:
        let value = r.get(self)
        let label = r.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
        let shown: String
        if r.kind == .choice {
          shown = isCurrent ? "\(PickerUI.teal)‹ \(PickerUI.bright)\(value)\(PickerUI.teal) ›\(PickerUI.reset)" : "\(PickerUI.bright)\(value)\(PickerUI.reset)"
        } else if value.isEmpty {
          shown = (isCurrent ? "\(PickerUI.teal)▏\(PickerUI.reset)" : "") + "\(PickerUI.dim)\u{1b}[3m\(r.placeholder)\(PickerUI.reset)"
        } else {
          let maxLen = max(10, t.cols - left - labelWidth - 6)
          let v = value.count > maxLen ? "…" + value.suffix(maxLen - 1) : value
          shown = "\(PickerUI.bright)\(v)\(PickerUI.reset)" + (isCurrent ? "\(PickerUI.teal)▏\(PickerUI.reset)" : "")
        }
        let bar = isCurrent ? "\(PickerUI.teal)▌\(PickerUI.reset)" : " "
        t.emit("\(bar) \(isCurrent ? PickerUI.bright : PickerUI.dim)\(label)\(PickerUI.reset)\(shown)")
      }
    }

    let footer = !message.isEmpty ? "\u{1b}[1m\(PickerUI.bright)\(message)\(PickerUI.reset)"
      : "\(PickerUI.dim)↑↓ move  type to edit  ←→ change  ↵ next/add  ^X remove row  ^U clear  ^S save  esc cancel\(PickerUI.reset)"
    t.emit("\u{1b}[\(t.rows);\(left)H\(footer)")
    t.emit("\u{1b}[?2026l")
    t.flush()
  }
}
