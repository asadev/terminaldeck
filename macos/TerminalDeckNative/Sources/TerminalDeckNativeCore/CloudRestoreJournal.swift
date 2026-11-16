import Foundation
import Darwin

/// Private device-local receipts; never a cloud payload or a tool result containing file names.
struct CloudRestoreJournal: Sendable {
  let directory: URL
  private func root() throws -> CloudBackupDirectory {
    guard directory.isFileURL else { throw CloudBackupError.unsafePath }
    let parent = try CloudBackupDirectory(path: directory.deletingLastPathComponent().path)
    let name = directory.lastPathComponent
    _ = try CloudBackupPaths.components(name)
    if mkdirat(parent.fd, name, 0o700) != 0 && errno != EEXIST { throw CloudBackupError.unsafePath }
    let root = try parent.directory(name)
    var info = stat()
    guard fstat(root.fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw CloudBackupError.unsafePath }
    return root
  }
  private func name(_ id: String, _ kind: String) throws -> String {
    guard UUID(uuidString: id)?.uuidString.lowercased() == id, ["plan", "stage", "receipt", "lock"].contains(kind) else { throw CloudBackupError.invalidManifest }
    return id + "." + kind
  }
  func read<T: Decodable>(_ type: T.Type, id: String, kind: String) throws -> T? {
    let name = try name(id, kind), root = try root()
    guard let info = try root.infoIfPresent(name) else { return nil }
    guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
      info.st_size <= 64 * 1024 * 1024 else { throw CloudBackupError.unsafePath }
    let fd = try root.file(name); defer { close(fd) }
    let data = try CloudBackupDirectory.readChunk(fd, maximum: 64 * 1024 * 1024 + 1)
    return try CloudWire.decode(type, from: data, maximumBytes: 64 * 1024 * 1024)
  }
  func write<T: Encodable>(_ value: T, id: String, kind: String) throws {
    let name = try name(id, kind), root = try root()
    let temp = id + "." + UUID().uuidString
    try root.writeNew(temp, bytes: CloudWire.canonical(value))
    if let old = try root.infoIfPresent(name) {
      guard old.st_mode & S_IFMT == S_IFREG, old.st_uid == getuid(), old.st_nlink == 1, old.st_mode & 0o077 == 0 else { throw CloudBackupError.unsafePath }
    }
    guard renameat(root.fd, temp, root.fd, name) == 0, fsync(root.fd) == 0 else { throw CloudBackupError.unavailable }
  }
  func lock(_ id: String) throws -> Int32 {
    let name = try name(id, "lock"), root = try root()
    let fd = openat(root.fd, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw CloudBackupError.unavailable }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
      info.st_mode & 0o077 == 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw CloudBackupError.unavailable }
    return fd
  }
}
