import Foundation
import Darwin
import TerminalDeckNativeCore

/// Every conversation store this lane writes lives under the signed-in account's own folder, `D/cloud/<subjectHash>/…`.
/// A different account therefore never reads, replays or re-sends another account's journal (§5.1).
public enum BackendCloudConversationAccount {
  public static func check(_ directory: URL, subjectHash: String) throws {
    guard subjectHash.utf8.count == 64, subjectHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CloudFailure.invalidRequest }
    let parts = directory.standardizedFileURL.pathComponents
    guard directory.isFileURL, parts.indices.dropLast().contains(where: { parts[$0] == "cloud" && parts[$0 + 1] == subjectHash }) else {
      throw CloudFailure.unsafeConfiguration
    }
  }
}

/// Append-only, fsynced line log. A torn last line from a crash is ignored and cut before the next append.
public struct BackendCloudConversationLog: Sendable {
  public let file: URL
  public init(directory: URL, name: String) throws {
    guard !name.isEmpty, !name.contains("/") else { throw CloudFailure.invalidRequest }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw CloudFailure.unsafeConfiguration }
    file = directory.appendingPathComponent(name)
  }
  public func lines() throws -> [Data] {
    let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 { if errno == ENOENT { return [] }; throw CloudFailure.unavailable }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CloudFailure.unavailable }
    var bytes = Data()
    while true {
      let part = try CloudConversationFileAccess.read(descriptor, count: 1024 * 1024)
      if part.isEmpty { break }; bytes.append(part)
    }
    var result = bytes.split(separator: 10, omittingEmptySubsequences: true).map { Data($0) }
    if let last = bytes.last, last != 10, !result.isEmpty {
      result.removeLast()
      // Cut the torn tail so the next append starts on a line boundary.
      let keep = bytes.lastIndex(of: 10).map { $0 + 1 } ?? 0
      guard truncate(file.path, off_t(keep)) == 0 else { throw CloudFailure.unavailable }
    }
    return result
  }
  public func append(_ lines: [Data]) throws {
    guard !lines.isEmpty else { return }
    var data = Data()
    for line in lines { guard !line.contains(10) else { throw CloudFailure.invalidRequest }; data.append(line); data.append(10) }
    let descriptor = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw CloudFailure.unavailable }
    defer { Darwin.close(descriptor) }
    try data.withUnsafeBytes { raw in
      var done = 0
      while done < raw.count {
        let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: done), raw.count - done)
        if count < 0 { if errno == EINTR { continue }; throw CloudFailure.unavailable }
        guard count > 0 else { throw CloudFailure.unavailable }; done += count
      }
    }
    guard fsync(descriptor) == 0 else { throw CloudFailure.unavailable }
  }
  /// Atomic replace used only for compaction; content is the same state in fewer lines.
  public func replace(_ lines: [Data]) throws {
    var data = Data()
    for line in lines { data.append(line); data.append(10) }
    let temporary = file.deletingLastPathComponent().appendingPathComponent("." + file.lastPathComponent + "." + UUID().uuidString + ".tmp")
    let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw CloudFailure.unavailable }
    defer { Darwin.close(descriptor); Darwin.unlink(temporary.path) }
    try data.withUnsafeBytes { raw in
      var done = 0
      while done < raw.count {
        let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: done), raw.count - done)
        if count < 0 { if errno == EINTR { continue }; throw CloudFailure.unavailable }
        guard count > 0 else { throw CloudFailure.unavailable }; done += count
      }
    }
    guard fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else { throw CloudFailure.unavailable }
  }
}

/// Metadata-only reconciliation journal under the account's Cloud folder, never under a provider home.
/// Loaded once; each change appends one line; nothing is written when nothing changed.
public actor BackendCloudConversationReconciler: CloudConversationJournalPort {
  public nonisolated let subjectHash: String
  private let log: BackendCloudConversationLog
  private var state: CloudConversationReconciliation?
  public init(directory: URL, subjectHash: String) throws {
    try BackendCloudConversationAccount.check(directory, subjectHash: subjectHash)
    self.subjectHash = subjectHash
    log = try .init(directory: directory, name: "journal.log")
  }
  private func load() throws -> CloudConversationReconciliation {
    if let state { return state }
    var value = CloudConversationReconciliation()
    let lines = try log.lines()
    for line in lines { try value.replay(JSONDecoder().decode(CloudConversationReconciliation.Line.self, from: line)) }
    // A long history of small appends is folded into one line per file, atomically.
    if lines.count > max(10_000, 8 * (value.files.count + value.unsent.count)) {
      try log.replace(value.compacted().map { try JSONEncoder().encode($0) })
    }
    state = value; return value
  }
  public func state(fileID: String) throws -> CloudConversationFileState? { try load().files[fileID] }
  public func commit(_ next: CloudConversationFileState) throws {
    var value = try load()
    guard value.files[next.fileID] != next else { return }
    let line = value.line(for: next)
    try log.append([try JSONEncoder().encode(line)])
    try value.replay(line); state = value
  }
  public func finish(completedSources: Set<String>, present: Set<String>, at: Int64) throws -> [CloudOperation] {
    var value = try load()
    var lines: [CloudConversationReconciliation.Line] = []
    for (file, marker) in try value.markers(completedSources: completedSources, present: present, at: at) {
      lines.append(value.line(for: file)); try value.replay(lines.last!)
      lines.append(.init(t: "m", file: nil, keep: nil, marker: marker, sent: nil)); try value.replay(lines.last!)
    }
    try log.append(try lines.map { try JSONEncoder().encode($0) })
    state = value
    // Only markers the outbox has not accepted yet; accepted ones are never offered again.
    return value.unsent.values.sorted { $0.opId < $1.opId }
  }
  public func markSent(_ operationIDs: [String]) throws {
    var value = try load()
    let ids = operationIDs.filter { value.unsent[$0] != nil }
    guard !ids.isEmpty else { return }
    let line = CloudConversationReconciliation.Line(t: "x", file: nil, keep: nil, marker: nil, sent: ids)
    try log.append([try JSONEncoder().encode(line)])
    try value.replay(line); state = value
  }
  /// Size of the durable journal, for the bounded-growth check.
  public func journalBytes() throws -> Int64 {
    var info = stat()
    guard lstat(log.file.path, &info) == 0 else { return 0 }
    return Int64(info.st_size)
  }
}
