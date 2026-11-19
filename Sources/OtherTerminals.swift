import Foundation

// Makes Blink's hosts work in every terminal (kitty, Ghostty, iTerm,
// Terminal), not just Wink's Hosts menu, by adding a marked block to the end
// of ~/.ssh/config that includes the file Wink generates from Blink's hosts.
//
// It goes at the end because ssh keeps the first value it sees: your own
// Host blocks still win over Blink's. `Match all` closes whatever block the
// file ended in, so the include applies to every host.
enum OtherTerminals {
  static let begin = "# >>> Wink: Blink hosts. Remove with Hosts ▸ Blink ▸ Use Blink Hosts in Other Terminals."
  static let end = "# <<< Wink"
  static let includeLine = "  Include ~/.config/wink/blink_hosts.conf"

  /// The real file, through a symlink if ~/.ssh/config is one (dotfiles).
  private static var configURL: URL { LocalSSHConfig.configURL.resolvingSymlinksInPath() }

  static var isEnabled: Bool {
    (try? String(contentsOf: configURL, encoding: .utf8))?.contains(begin) ?? false
  }

  static func enable() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                           attributes: [.posixPermissions: 0o700])
    var text = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    guard !text.contains(begin) else { return }
    if !text.isEmpty {
      // One backup of the file as it was before Wink first touched it.
      let backup = configURL.appendingPathExtension("before-wink")
      if !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: configURL, to: backup) }
      if !text.hasSuffix("\n") { text += "\n" }
      text += "\n"
    }
    text += [begin, "Match all", includeLine, end].joined(separator: "\n") + "\n"
    try write(text)
  }

  static func disable() throws {
    guard let text = try? String(contentsOf: configURL, encoding: .utf8), text.contains(begin) else { return }
    var lines: [String] = []
    var skipping = false
    for line in text.components(separatedBy: "\n") {
      if line == begin { skipping = true; continue }
      if skipping { if line == end { skipping = false }; continue }
      lines.append(line)
    }
    // Drop the blank line enable() put before the block.
    while lines.count >= 2, lines[lines.count - 1].isEmpty, lines[lines.count - 2].isEmpty { lines.removeLast() }
    try write(lines.joined(separator: "\n"))
  }

  private static func write(_ text: String) throws {
    let fm = FileManager.default
    let perms = (try? fm.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    try text.write(to: configURL, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: perms], ofItemAtPath: configURL.path)
  }
}
