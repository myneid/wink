import Foundation

// Reads image data for the kitty graphics protocol's local transmission
// mediums: t=f (file), t=t (temporary file, deleted after reading) and
// t=s (POSIX shared memory). The requests come from terminal output, which
// may be a remote or untrusted program, so every failure looks the same to
// it (nil) and only regular files outside device/proc paths are read.
enum ImageFiles {
  static let maxBytes = 400 * 1024 * 1024

  static func read(medium: String, path: String, offset: Int, size: Int) -> Data? {
    switch medium {
    case "f", "t": return readFile(path, offset: offset, size: size, deleteTemp: medium == "t")
    case "s": return readSharedMemory(path, offset: offset, size: size)
    default: return nil
    }
  }

  private static func readFile(_ path: String, offset: Int, size: Int, deleteTemp: Bool) -> Data? {
    guard path.hasPrefix("/") else { return nil }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    // Checked before opening: merely opening some files has side effects.
    for sensitive in ["/dev", "/proc", "/sys", "/private/var/run"]
    where resolved == sensitive || resolved.hasPrefix(sensitive + "/") {
      return nil
    }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved),
          attrs[.type] as? FileAttributeType == .typeRegular,
          let fileSize = attrs[.size] as? Int, fileSize <= maxBytes,
          let handle = FileHandle(forReadingAtPath: resolved) else { return nil }
    defer {
      try? handle.close()
      if deleteTemp, isTemporary(resolved) { unlink(resolved) }
    }
    guard offset >= 0, offset <= fileSize else { return nil }
    let length = size > 0 ? size : fileSize - offset
    guard length >= 0, offset + length <= fileSize else { return nil }
    do {
      try handle.seek(toOffset: UInt64(offset))
      let data = try handle.read(upToCount: length) ?? Data()
      return data.count == length ? data : nil
    } catch {
      return nil
    }
  }

  /// Per the spec, only files in a temp directory with this marker in their
  /// path may be deleted.
  private static func isTemporary(_ path: String) -> Bool {
    guard path.contains("tty-graphics-protocol") else { return false }
    let tmpdir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    return [tmpdir, "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/private/var/folders"]
      .contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
  }

  private static func readSharedMemory(_ name: String, offset: Int, size: Int) -> Data? {
    // POSIX names: one leading slash, no others.
    guard name.hasPrefix("/"), !name.dropFirst().contains("/"), name.count > 1 else { return nil }
    let fd = wink_shm_open_readonly(name)
    guard fd >= 0 else { return nil }
    defer {
      close(fd)
      shm_unlink(name) // the terminal owns it once sent
    }
    var st = stat()
    guard fstat(fd, &st) == 0, st.st_size > 0, st.st_size <= maxBytes else { return nil }
    let total = Int(st.st_size)
    let length = size > 0 ? size : total - offset
    guard offset >= 0, length > 0, offset + length <= total else { return nil }
    guard let base = mmap(nil, total, PROT_READ, MAP_SHARED, fd, 0), base != MAP_FAILED else { return nil }
    defer { munmap(base, total) }
    return Data(bytes: base.advanced(by: offset), count: length)
  }
}
