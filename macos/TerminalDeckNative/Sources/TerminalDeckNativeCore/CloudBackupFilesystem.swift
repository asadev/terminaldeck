import Foundation
import Darwin

/// Descriptor-relative traversal pins every directory; no path component is ever followed as a link.
final class CloudBackupDirectory {
  let fd: Int32
  init(path: String) throws {
    guard path.hasPrefix("/"), path.utf8.count <= 4096 else { throw CloudBackupError.unsafePath }
    var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard current >= 0 else { throw CloudBackupError.unsafePath }
    do {
      for part in path.split(separator: "/").map(String.init) {
        _ = try CloudBackupPaths.components(part)
        let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard next >= 0 else { throw CloudBackupError.unsafePath }
        close(current); current = next
      }
      fd = current
    } catch { close(current); throw error }
  }
  init(fd: Int32) { self.fd = fd }
  deinit { close(fd) }
  func directory(_ name: String) throws -> CloudBackupDirectory {
    _ = try CloudBackupPaths.components(name)
    guard !name.contains("/") else { throw CloudBackupError.unsafePath }
    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard child >= 0 else { throw CloudBackupError.unsafePath }
    return CloudBackupDirectory(fd: child)
  }
  func isWithin(_ ancestor: CloudBackupDirectory) throws -> Bool {
    var wanted = stat()
    guard fstat(ancestor.fd, &wanted) == 0 else { throw CloudBackupError.unavailable }
    var current = dup(fd)
    guard current >= 0 else { throw CloudBackupError.unavailable }
    defer { close(current) }
    for _ in 0..<256 {
      var here = stat()
      guard fstat(current, &here) == 0 else { throw CloudBackupError.unavailable }
      if here.st_dev == wanted.st_dev && here.st_ino == wanted.st_ino { return true }
      let parent = openat(current, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard parent >= 0 else { throw CloudBackupError.unsafePath }
      var above = stat()
      guard fstat(parent, &above) == 0 else { close(parent); throw CloudBackupError.unavailable }
      if here.st_dev == above.st_dev && here.st_ino == above.st_ino { close(parent); return false }
      close(current); current = parent
    }
    throw CloudBackupError.limitExceeded
  }
  func names() throws -> [String] {
    let copy = dup(fd)
    guard copy >= 0, let stream = fdopendir(copy) else { if copy >= 0 { close(copy) }; throw CloudBackupError.unavailable }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      var raw = entry.pointee.d_name
      let capacity = MemoryLayout.size(ofValue: raw)
      let name = withUnsafePointer(to: &raw) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) } }
      if name != "." && name != ".." { names.append(name) }
      errno = 0
    }
    guard errno == 0 else { throw CloudBackupError.unavailable }
    return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
  }
  func info(_ name: String) throws -> stat {
    var value = stat()
    guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw CloudBackupError.changedDuringRead }
    return value
  }
  func infoIfPresent(_ name: String) throws -> stat? {
    var value = stat()
    if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 { return value }
    guard errno == ENOENT else { throw CloudBackupError.unavailable }
    return nil
  }
  func link(_ name: String) throws -> String {
    var buffer = [UInt8](repeating: 0, count: 4097)
    let length = readlinkat(fd, name, &buffer, buffer.count)
    guard length > 0, length < buffer.count, let target = String(bytes: buffer.prefix(length), encoding: .utf8) else { throw CloudBackupError.unsafePath }
    return target
  }
  func file(_ name: String) throws -> Int32 {
    let result = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard result >= 0 else { throw CloudBackupError.unsafePath }
    var s = stat()
    guard fstat(result, &s) == 0, s.st_mode & S_IFMT == S_IFREG else { close(result); throw CloudBackupError.unsupportedFile }
    return result
  }
  func createDirectory(_ name: String) throws -> CloudBackupDirectory {
    guard mkdirat(fd, name, 0o700) == 0 else { throw CloudBackupError.alreadyExists }
    return try directory(name)
  }
  func parent(of relative: String, create: Bool = false) throws -> (CloudBackupDirectory, String) {
    let parts = try CloudBackupPaths.components(relative)
    var current = CloudBackupDirectory(fd: dup(fd))
    for part in parts.dropLast() {
      if create {
        if mkdirat(current.fd, part, 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
      }
      current = try current.directory(part)
    }
    return (current, parts.last!)
  }
  func writeNew(_ name: String, bytes: Data, mode: mode_t = 0o600) throws {
    let file = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard file >= 0 else { throw CloudBackupError.alreadyExists }
    defer { close(file) }
    try Self.writeAll(file, bytes)
    guard fsync(file) == 0 else { throw CloudBackupError.unavailable }
  }
  static func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { throw CloudBackupError.unavailable }
        offset += n
      }
    }
  }
  static func readChunk(_ fd: Int32, maximum: Int) throws -> Data {
    guard maximum > 0 else { return Data() }
    var info = stat()
    let position = lseek(fd, 0, SEEK_CUR)
    guard position >= 0, fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CloudBackupError.unsupportedFile }
    let available = max(Int64(0), Int64(info.st_size) - Int64(position))
    let count = min(maximum, Int(min(available, Int64(Int.max))))
    if count == 0 { return Data() }
    var bytes = [UInt8](repeating: 0, count: count)
    var offset = 0
    while offset < count {
      let n = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
      if n < 0 && errno == EINTR { continue }
      guard n >= 0 else { throw CloudBackupError.unavailable }
      if n == 0 { break }
      offset += n
    }
    return Data(bytes.prefix(offset))
  }
  static func fingerprint(_ s: stat) -> String {
    "\(s.st_dev):\(s.st_ino):\(s.st_size):\(s.st_mtimespec.tv_sec):\(s.st_mtimespec.tv_nsec):\(s.st_ctimespec.tv_sec):\(s.st_ctimespec.tv_nsec):\(s.st_mode)"
  }
}
