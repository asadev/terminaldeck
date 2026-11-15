import Foundation
import Darwin

public protocol CloudConversationChunkPort: Sendable {
  /// Cache by immutable id. The id binds the plain hash, so an existing id is reused without decrypting it.
  func seal(_ bytes: Data, blobID: String, sourceID: String) async throws -> CloudLocalBlob
}

public enum CloudConversationIdentity {
  /// Chunk-list pages hold at most this many entries, so every list and manifest payload stays far below 64 KiB.
  public static let listPageEntries = 256
  public static func uuid(_ fields: [String]) throws -> String {
    var hex = Array(CloudSyncBytes.hash(try CloudSyncCanonical.encode(CloudValue(.array(fields.map(NativeRPCValue.string))))).prefix(32))
    hex[12] = "4"; hex[16] = "8"
    return String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-" + String(hex[12..<16]) + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
  }
  /// The source id comes from the owner's stable home key, so moving or re-linking a home keeps every file identity.
  public static func file(provider: CloudConversationProvider, deviceID: String, sourceID: String, relativePath: String) throws -> String {
    CloudSyncBytes.hash(try CloudSyncCanonical.encode(CloudValue(.array([
      .string(provider.rawValue), .string(deviceID), .string(sourceID), .string(relativePath)
    ]))))
  }
  public static func blob(fileID: String, deviceID: String, offset: Int64, plainHash: String) throws -> String {
    try uuid(["conversation-content", deviceID, fileID, String(offset), plainHash])
  }
  public static func chain(previous: String, hash: String, offset: Int64, length: Int) -> String {
    CloudSyncBytes.hash(Data("\(previous):\(hash):\(offset):\(length)".utf8))
  }
  public static func digest(_ entries: [CloudConversationChunkEntry]) -> String {
    entries.reduce("") { chain(previous: $0, hash: $1.hash, offset: $1.offset, length: $1.length) }
  }
  public static func chunkOperation(fileID: String, entry: CloudConversationChunkEntry) throws -> String {
    try uuid(["conversation-chunk", fileID, String(entry.offset), String(entry.length), entry.hash])
  }
  public static func chunkEntity(fileID: String, entry: CloudConversationChunkEntry) -> String {
    fileID + "/c/" + String(entry.offset) + "/" + entry.hash
  }
  public static func listOperation(fileID: String, first: Int, entries: [CloudConversationChunkEntry]) throws -> String {
    try uuid(["conversation-list", fileID, String(first), CloudSyncBytes.hash(try CloudSyncCanonical.encode(CloudValue(.array(entries.map(\.value)))))])
  }
  public static func manifestOperation(fileID: String, digest: String, bytes: Int64, parent: String?) throws -> String {
    try uuid(["conversation-manifest", fileID, digest, String(bytes), parent ?? ""])
  }
}

/// One new chunk per pull, then the file's new list pages and manifest. Unchanged chunks, pages and files create nothing.
/// A changed/truncated file never receives a manifest. State moves forward only after the consumer asked for the next page,
/// which is the point where SYNC has made the previous page durable.
public actor CloudConversationExport {
  private struct Progress {
    let file: CloudConversationFile
    let fileID: String
    let descriptor: Int32
    let stamp: String
    let device: Int64
    let inode: UInt64
    let size: Int64
    let prior: CloudConversationFileState?
    let known: Set<CloudConversationChunkEntry>
    var offset: Int64
    var entries: [CloudConversationChunkEntry]
  }
  private enum Phase { case files, markers, coverage, done }
  private let enumerator: CloudConversationEnumerator
  private let chunks: any CloudConversationChunkPort
  private let journal: any CloudConversationJournalPort
  private let deviceID: String
  private let cut: CloudSnapshotCut
  private let chunkBytes: Int
  private var current: Progress?
  private var phase = Phase.files
  private var present = Set<String>()
  private var pendingCommit: CloudConversationFileState?
  private var pendingSent: [String] = []
  private var reading = false
  public init(roots: [CloudConversationRoot], chunks: any CloudConversationChunkPort, journal: any CloudConversationJournalPort,
              deviceID: String, cut: CloudSnapshotCut, chunkBytes: Int = 1024 * 1024) throws {
    guard (1...CloudWire.maximumPlainChunkBytes).contains(chunkBytes) else { throw CloudFailure.invalidRequest }
    try CloudSyncBytes.transportID(deviceID)
    enumerator = try .init(roots: roots); self.chunks = chunks; self.journal = journal
    self.deviceID = deviceID; self.cut = cut; self.chunkBytes = chunkBytes
  }
  deinit { if let current, current.descriptor >= 0 { Darwin.close(current.descriptor) } }

  public func next() async throws -> CloudDomainSnapshot? {
    guard !reading else { throw CloudFailure.versionChanged }
    reading = true; defer { reading = false }
    try await acknowledge()
    while true {
      try Task.checkCancellation()
      switch phase {
      case .done: return nil
      case .coverage:
        phase = .done
        return .init(cut: cut, operations: [], files: [], coverage: await enumerator.coverage())
      case .markers:
        phase = .coverage
        let markers = try await journal.finish(completedSources: await enumerator.completedSources(), present: present, at: cut.at)
          .filter { $0.originDevice == deviceID }
        if markers.isEmpty { continue }
        pendingSent = markers.map(\.opId)
        return .init(cut: cut, operations: markers, files: [], coverage: [])
      case .files:
        if current == nil {
          guard let file = try await enumerator.next() else { phase = .markers; continue }
          let opened = try await begin(file)
          if !opened { continue }
        }
        if let page = try await step() { return page }
      }
    }
  }
  /// The previous page was taken by the consumer; record what it carried.
  private func acknowledge() async throws {
    if let state = pendingCommit { try await journal.commit(state); pendingCommit = nil }
    if !pendingSent.isEmpty { try await journal.markSent(pendingSent); pendingSent = [] }
  }
  /// Returns false when the file needs no reading at all (same stamp) or could not be opened.
  private func begin(_ file: CloudConversationFile) async throws -> Bool {
    let fileID = try CloudConversationIdentity.file(provider: file.root.provider, deviceID: deviceID, sourceID: file.root.sourceID, relativePath: file.relativePath)
    present.insert(fileID)
    let prior = try await journal.state(fileID: fileID)
    if let prior, prior.stamp == file.stamp, prior.chunkBytes == chunkBytes, prior.head != nil, !prior.archived { return false }
    let descriptor: Int32
    do { descriptor = try CloudConversationFileAccess.open(root: file.root.directory, relativePath: file.relativePath) }
    catch { await enumerator.reportFailure(sourceID: file.root.sourceID); return false }
    do {
      let stamp = try CloudConversationFileAccess.stamp(descriptor)
      let identity = try CloudConversationFileAccess.identity(descriptor)
      var offset: Int64 = 0, entries: [CloudConversationChunkEntry] = []
      // Same file object that only grew: earlier full chunks are kept after the last known chunk is re-verified.
      // A replaced file (new inode), a shrink, an equal-size rewrite or a mismatch is read again from the start.
      if let prior, prior.chunkBytes == chunkBytes, prior.device == identity.device, prior.inode == identity.inode,
         identity.size > prior.size, let last = prior.entries.last {
        let check = try CloudConversationFileAccess.read(descriptor, at: last.offset, count: last.length)
        if check.count == last.length, CloudSyncBytes.hash(check) == last.hash {
          entries = Array(prior.entries.dropLast()); offset = last.offset
        }
      }
      try CloudConversationFileAccess.seek(descriptor, to: offset)
      current = .init(file: file, fileID: fileID, descriptor: descriptor, stamp: stamp, device: identity.device, inode: identity.inode,
        size: identity.size, prior: prior, known: Set(prior?.entries ?? []), offset: offset, entries: entries)
      return true
    } catch {
      Darwin.close(descriptor); await enumerator.reportFailure(sourceID: file.root.sourceID)
      if error is CancellationError { throw error }
      return false
    }
  }
  private func step() async throws -> CloudDomainSnapshot? {
    guard var progress = current else { return nil }
    do {
      let data = try CloudConversationFileAccess.read(progress.descriptor, count: chunkBytes)
      if !data.isEmpty {
        let entry = CloudConversationChunkEntry(offset: progress.offset, length: data.count, hash: CloudSyncBytes.hash(data))
        progress.entries.append(entry); progress.offset += Int64(data.count)
        current = progress
        if progress.known.contains(entry) { return nil }
        let blobID = try CloudConversationIdentity.blob(fileID: progress.fileID, deviceID: deviceID, offset: entry.offset, plainHash: entry.hash)
        let blob = try await chunks.seal(data, blobID: blobID, sourceID: progress.file.root.sourceID)
        let ref = try NativeRPCValue.parseJSON(JSONEncoder().encode(blob.reference))
        let payload: NativeRPCValue = .object([.init("v", .number(1)), .init("kind", .string("chunk")),
          .init("provider", .string(progress.file.root.provider.rawValue)), .init("fileId", .string(progress.fileID)),
          .init("offset", .string(String(entry.offset))), .init("length", .number(Double(entry.length))),
          .init("plainHash", .string(entry.hash)), .init("blob", ref)])
        let op = try operation(progress, id: try CloudConversationIdentity.chunkOperation(fileID: progress.fileID, entry: entry),
          entity: CloudConversationIdentity.chunkEntity(fileID: progress.fileID, entry: entry), payload: payload,
          kind: .append, parents: [], offset: entry.offset, createdAt: 0)
        return .init(cut: cut, operations: [op], files: [blob], coverage: [])
      }
      guard try CloudConversationFileAccess.stamp(progress.descriptor) == progress.stamp, progress.offset == progress.size else { throw CloudFailure.versionChanged }
      closeFile()
      return try await finishFile(progress)
    } catch {
      closeFile(); await enumerator.reportFailure(sourceID: progress.file.root.sourceID)
      if error is CancellationError { throw error }
      // Partial immutable chunks remain pending history. Without a manifest they cannot be read as a complete file.
      return nil
    }
  }
  private func finishFile(_ progress: Progress) async throws -> CloudDomainSnapshot? {
    let digest = CloudConversationIdentity.digest(progress.entries)
    var pages: [String] = [], lists: [CloudOperation] = []
    let known = Set(progress.prior?.pages ?? [])
    for first in stride(from: 0, to: progress.entries.count, by: CloudConversationIdentity.listPageEntries) {
      let slice = Array(progress.entries[first..<min(progress.entries.count, first + CloudConversationIdentity.listPageEntries)])
      let id = try CloudConversationIdentity.listOperation(fileID: progress.fileID, first: first, entries: slice)
      pages.append(id)
      if known.contains(id) { continue }
      let payload: NativeRPCValue = .object([.init("v", .number(1)), .init("kind", .string("list")),
        .init("provider", .string(progress.file.root.provider.rawValue)), .init("fileId", .string(progress.fileID)),
        .init("first", .number(Double(first))), .init("entries", .array(slice.map(\.value)))])
      lists.append(try operation(progress, id: id, entity: progress.fileID + "/l/" + id, payload: payload, kind: .put, parents: [], offset: nil, createdAt: 0))
    }
    var state = CloudConversationFileState(fileID: progress.fileID, sourceID: progress.file.root.sourceID, stamp: progress.stamp,
      device: progress.device, inode: progress.inode, size: progress.size, chunkBytes: chunkBytes, entries: progress.entries,
      digest: digest, pages: pages, head: progress.prior?.head)
    if let head = progress.prior?.head, head.kind != .archive, progress.prior?.digest == digest, progress.prior?.size == progress.size {
      // Touched but identical: nothing to send, only the new stamp is remembered.
      try await journal.commit(state)
      return nil
    }
    let parent = progress.prior?.head?.opId
    let root = progress.file.root
    var payload: NativeRPCValue = .object([.init("v", .number(1)), .init("kind", .string("file")),
      .init("provider", .string(root.provider.rawValue)), .init("profileId", .string(root.profileID)),
      .init("profileIds", .array(root.profileIDs.map(NativeRPCValue.string))), .init("fileId", .string(progress.fileID)),
      .init("relativePath", .string(progress.file.relativePath)), .init("relativePrefix", .string(root.relativePrefix)),
      .init("bytes", .string(String(progress.size))), .init("chunks", .number(Double(progress.entries.count))),
      .init("chunkBytes", .number(Double(chunkBytes))), .init("chunkDigest", .string(digest)),
      .init("pages", .array(pages.map(NativeRPCValue.string)))])
    if let branch = root.branch { payload = payload.setting("branch", branch.value) }
    let id = try CloudConversationIdentity.manifestOperation(fileID: progress.fileID, digest: digest, bytes: progress.size, parent: parent)
    let manifest = try operation(progress, id: id, entity: progress.fileID, payload: payload,
      kind: parent == nil ? .put : .supersede, parents: parent.map { [$0] } ?? [], offset: nil, createdAt: progress.file.modifiedAt)
    state.head = manifest
    pendingCommit = state
    return .init(cut: cut, operations: lists + [manifest], files: [], coverage: [])
  }
  private func operation(_ progress: Progress, id: String, entity: String, payload: NativeRPCValue, kind: CloudOperationKind,
                         parents: [String], offset: Int64?, createdAt: Int64) throws -> CloudOperation {
    let value = CloudValue(payload)
    let op = CloudOperation(v: 1, opId: id, originDevice: deviceID, domain: progress.file.root.provider.domain,
      entityId: entity, revision: id, parents: parents, kind: kind,
      source: .init(sourceId: progress.file.root.sourceID, recordId: progress.fileID, offset: offset),
      createdAt: createdAt, payload: value, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(value)))
    try CloudSyncPack.validate([op]); return op
  }
  private func closeFile() {
    if let current, current.descriptor >= 0 { Darwin.close(current.descriptor) }
    current = nil
  }
}
