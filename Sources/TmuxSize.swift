import Foundation

// Finds the size of the tmux window shown in a tab, so the tab's window can
// be resized to fit it. When another, smaller client is attached to the same
// session, tmux shrinks the window to that client's size and the rest of the
// tab shows filler.
//
// The tmux client running in the tab is the tab's foreground process. We run
// that same tmux binary (Wink started from Finder doesn't have Homebrew on
// its PATH) with the client's -L/-S socket options and TMUX_TMPDIR, and ask
// the server about the client attached to this tab's tty.
enum TmuxSize {
  struct Size: Equatable { var cols: Int, rows: Int }

  enum Failure: Error {
    case noTmux(String) // what's in the foreground instead
    case query(String)
  }

  static func query(foregroundPID pid: pid_t, tty: String) -> Result<Size, Failure> {
    guard let path = executablePath(pid), (path as NSString).lastPathComponent == "tmux" else {
      return .failure(.noTmux(executablePath(pid).map { ($0 as NSString).lastPathComponent } ?? "nothing"))
    }
    let (argv, env) = argumentsAndEnvironment(pid) ?? ([], [:])

    // The client's server selection: -L name / -S path, possibly glued (-Lname).
    var serverArgs: [String] = []
    var i = 1
    while i < argv.count {
      let a = argv[i]
      if a == "-L" || a == "-S", i + 1 < argv.count {
        serverArgs += [a, argv[i + 1]]
        i += 2
        continue
      }
      if (a.hasPrefix("-L") || a.hasPrefix("-S")) && a.count > 2 {
        serverArgs += [String(a.prefix(2)), String(a.dropFirst(2))]
      } else if !a.hasPrefix("-") {
        break // the tmux command (new-session, attach, ...) starts here
      }
      i += 1
    }

    // Window size, plus the status line(s) tmux draws outside the window.
    let format = "#{window_width} #{window_height} #{status}"
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = serverArgs + ["display-message", "-p", "-c", tty, format]
    var environment = ProcessInfo.processInfo.environment
    if let tmpdir = env["TMUX_TMPDIR"] { environment["TMUX_TMPDIR"] = tmpdir }
    process.environment = environment
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
      try process.run()
    } catch {
      return .failure(.query(error.localizedDescription))
    }
    process.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
      let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      return .failure(.query(message.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    let parts = text.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard parts.count == 3, let cols = Int(parts[0]), let rows = Int(parts[1]) else {
      return .failure(.query("unexpected reply from tmux: \(text)"))
    }
    // `status` is off, on (one line) or a number of lines.
    let statusLines = parts[2] == "off" ? 0 : (Int(parts[2]) ?? 1)
    return .success(Size(cols: cols, rows: rows + statusLines))
  }

  private static func executablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }

  /// argv and environment of a process we own (KERN_PROCARGS2).
  private static func argumentsAndEnvironment(_ pid: pid_t) -> ([String], [String: String])? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    // Layout: argc (int32), exec path, NUL padding, argv[argc], environment.
    let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    var strings: [String] = []
    var start = 4
    var index = 4
    while index < size {
      if buffer[index] == 0 {
        if index > start {
          strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
        }
        start = index + 1
      }
      index += 1
    }
    guard strings.count >= 1 + argc else { return nil }
    let argv = Array(strings[1...argc])
    var env: [String: String] = [:]
    for entry in strings.dropFirst(1 + argc) {
      if let eq = entry.firstIndex(of: "=") {
        env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
      }
    }
    return (argv, env)
  }
}
