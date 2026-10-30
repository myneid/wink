import Foundation

/// Arguments of processes running in our tabs, for finding which tmux or
/// ssh a tab is running.
enum ProcessArguments {
  static func of(_ pid: pid_t) -> [String]? {
    withEnvironment(pid)?.0
  }

  /// argv and environment of a process we own (KERN_PROCARGS2).
  static func withEnvironment(_ pid: pid_t) -> ([String], [String: String])? {
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
