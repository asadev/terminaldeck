import Foundation
import SQLite3
import CryptoKit
import Darwin

public struct CloudBackupDatabaseTableCount: Codable, Equatable, Sendable {
  public let name: String
  public let rows: Int64
}
public struct CloudBackupDatabaseProof: Codable, Equatable, Sendable {
  public let engine: String
  public let exporter: String
  public let consistentThrough: Int64
  public let tables: [CloudBackupDatabaseTableCount]
  public let bytes: Int64
  public let sha256: String
  public let storageClass: CloudStorageClass
}
public struct CloudBackupDatabaseReceipt: Sendable {
  public let file: URL
  public let proof: CloudBackupDatabaseProof
}
public enum CloudBackupDatabaseOutcome: Sendable {
  case snapshot(CloudBackupDatabaseReceipt)
  case blocked(engine: String, reason: String)
}

/// A consistent SQLite file is made under a private new name, checked, then published exclusively.
/// Managed Linux/container exporters belong to BackendAppsDataBackupRunner; they are not local file copies.
public enum CloudBackupDatabase {
  public static func snapshot(engine: String, source: URL, destination: URL,
                              storageClass: CloudStorageClass) throws -> CloudBackupDatabaseOutcome {
    guard engine.lowercased() == "sqlite" else {
      return .blocked(engine: engine, reason: "No consistent local exporter is connected for this database engine.")
    }
    guard source.isFileURL, destination.isFileURL else { throw CloudBackupError.unsafePath }
    let sourceParent = try CloudBackupDirectory(path: source.deletingLastPathComponent().path)
    let sourceFD = try sourceParent.file(source.lastPathComponent)
    defer { close(sourceFD) }
    var sourceInfo = stat()
    guard fstat(sourceFD, &sourceInfo) == 0 else { throw CloudBackupError.unavailable }
    let parent = try CloudBackupDirectory(path: destination.deletingLastPathComponent().path)
    let name = destination.lastPathComponent
    _ = try CloudBackupPaths.components(name)
    guard try parent.infoIfPresent(name) == nil else { throw CloudBackupError.alreadyExists }
    let stageName = ".cloud-sqlite-" + UUID().uuidString.lowercased()
    let stage = try parent.createDirectory(stageName)
    let stageURL = destination.deletingLastPathComponent().appendingPathComponent(stageName)
    let snapshot = stageURL.appendingPathComponent("snapshot.sqlite")
    var live: OpaquePointer?, copy: OpaquePointer?
    guard sqlite3_open_v2(source.path, &live, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let live else {
      if let live { sqlite3_close(live) }; throw CloudBackupError.incomplete
    }
    defer { sqlite3_close(live) }
    // Fresh connections never enable extension loading; Apple does not expose the loader API.
    sqlite3_busy_timeout(live, 1000)
    let through = Int64(Date().timeIntervalSince1970 * 1000)
    try execute(live, "BEGIN")
    defer { _ = sqlite3_exec(live, "ROLLBACK", nil, nil, nil) }
    _ = try rows(live, "PRAGMA schema_version")
    guard let pages = Int64(try rows(live, "PRAGMA page_count").first?.first ?? ""),
      let pageSize = Int64(try rows(live, "PRAGMA page_size").first?.first ?? ""), pages >= 0, pageSize > 0,
      pages <= (512 * 1024 * 1024) / pageSize else { throw CloudBackupError.limitExceeded }
    guard sqlite3_open_v2(snapshot.path, &copy, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let copy else {
      if let copy { sqlite3_close(copy) }; throw CloudBackupError.incomplete
    }
    var copyOpen = true
    defer { if copyOpen { sqlite3_close(copy) } }
    guard let backup = sqlite3_backup_init(copy, "main", live, "main") else { throw CloudBackupError.incomplete }
    var result = SQLITE_OK
    var waits = 0
    repeat {
      result = sqlite3_backup_step(backup, 256)
      if result == SQLITE_BUSY || result == SQLITE_LOCKED {
        waits += 1
        if waits > 20 { break }
        sqlite3_sleep(25)
      }
    } while result == SQLITE_OK || result == SQLITE_BUSY || result == SQLITE_LOCKED
    let finished = sqlite3_backup_finish(backup)
    guard result == SQLITE_DONE, finished == SQLITE_OK else { throw CloudBackupError.incomplete }
    // The portable snapshot is self-contained: no dependency on a WAL or shared-memory sidecar.
    guard try rows(copy, "PRAGMA journal_mode=DELETE") == [["delete"]] else { throw CloudBackupError.incomplete }
    let counts = try verify(copy)
    guard sqlite3_close(copy) == SQLITE_OK else { throw CloudBackupError.incomplete }
    copyOpen = false
    guard chmod(snapshot.path, 0o600) == 0 else { throw CloudBackupError.unavailable }
    let proof = try inspect(snapshot, storageClass: storageClass, consistentThrough: through)
    guard proof.tables == counts else { throw CloudBackupError.readbackFailed }
    // Check that the source name still denotes the database we opened; no source rename/path mapping is performed.
    let afterParent = try CloudBackupDirectory(path: source.deletingLastPathComponent().path)
    let after = try afterParent.info(source.lastPathComponent)
    guard after.st_dev == sourceInfo.st_dev, after.st_ino == sourceInfo.st_ino else { throw CloudBackupError.changedDuringRead }
    let snapshotFD = try stage.file("snapshot.sqlite")
    defer { close(snapshotFD) }
    guard fsync(snapshotFD) == 0, renameatx_np(stage.fd, "snapshot.sqlite", parent.fd, name, UInt32(RENAME_EXCL)) == 0,
      fsync(parent.fd) == 0 else { throw CloudBackupError.alreadyExists }
    _ = unlinkat(parent.fd, stageName, AT_REMOVEDIR)
    return .snapshot(.init(file: destination, proof: proof))
  }

  public static func inspect(_ file: URL, storageClass: CloudStorageClass, consistentThrough: Int64) throws -> CloudBackupDatabaseProof {
    let directory = try CloudBackupDirectory(path: file.deletingLastPathComponent().path)
    if let wal = try directory.infoIfPresent(file.lastPathComponent + "-wal"), wal.st_size > 0 { throw CloudBackupError.incomplete }
    let fd = try directory.file(file.lastPathComponent)
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_size <= 512 * 1024 * 1024 else { throw CloudBackupError.limitExceeded }
    var db: OpaquePointer?
    guard sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let db else {
      if let db { sqlite3_close(db) }; throw CloudBackupError.incomplete
    }
    defer { sqlite3_close(db) }
    let tables = try verify(db)
    var digest = SHA256(), count: Int64 = 0
    while true {
      let bytes = try CloudBackupDirectory.readChunk(fd, maximum: CloudWire.maximumPlainChunkBytes)
      if bytes.isEmpty { break }
      count += Int64(bytes.count)
      guard count <= info.st_size else { throw CloudBackupError.changedDuringRead }
      digest.update(data: bytes)
    }
    var after = stat()
    guard fstat(fd, &after) == 0, count == info.st_size, CloudBackupDirectory.fingerprint(info) == CloudBackupDirectory.fingerprint(after) else { throw CloudBackupError.changedDuringRead }
    return .init(engine: "sqlite", exporter: "sqlite3_backup/" + String(cString: sqlite3_libversion()), consistentThrough: consistentThrough,
      tables: tables, bytes: count, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(), storageClass: storageClass)
  }
  private static func verify(_ db: OpaquePointer) throws -> [CloudBackupDatabaseTableCount] {
    guard try rows(db, "PRAGMA integrity_check") == [["ok"]] else { throw CloudBackupError.readbackFailed }
    let names = try rows(db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT GLOB 'sqlite_*' ORDER BY name")
    var counts: [CloudBackupDatabaseTableCount] = []
    for row in names {
      guard let name = row.first, !name.utf8.contains(0) else { throw CloudBackupError.invalidManifest }
      let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
      guard let raw = try rows(db, "SELECT COUNT(*) FROM " + quoted).first?.first, let count = Int64(raw) else { throw CloudBackupError.readbackFailed }
      counts.append(.init(name: name, rows: count))
    }
    return counts
  }
  private static func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CloudBackupError.incomplete }
  }
  private static func rows(_ db: OpaquePointer, _ sql: String) throws -> [[String]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CloudBackupError.incomplete }
    defer { sqlite3_finalize(statement) }
    var rows: [[String]] = []
    while true {
      let state = sqlite3_step(statement)
      if state == SQLITE_DONE { return rows }
      guard state == SQLITE_ROW, rows.count < 100_000 else { throw CloudBackupError.incomplete }
      var values: [String] = []
      for column in 0..<sqlite3_column_count(statement) {
        guard let pointer = sqlite3_column_text(statement, column) else { values.append(""); continue }
        let size = Int(sqlite3_column_bytes(statement, column))
        guard size <= 1024 * 1024, let value = String(bytes: UnsafeBufferPointer(start: pointer, count: size), encoding: .utf8) else { throw CloudBackupError.invalidManifest }
        values.append(value)
      }
      rows.append(values)
    }
  }
}
