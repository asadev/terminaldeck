import Foundation

/// One fixed-size slice of a file, at a fixed offset. Same (offset, length, hash) means the same chunk operation.
public struct CloudConversationChunkEntry: Codable, Sendable, Hashable {
  public let offset: Int64
  public let length: Int
  public let hash: String
  public init(offset: Int64, length: Int, hash: String) { self.offset = offset; self.length = length; self.hash = hash }
  public var value: NativeRPCValue { .array([.string(String(offset)), .number(Double(length)), .string(hash)]) }
  public static func parse(_ value: NativeRPCValue) throws -> CloudConversationChunkEntry {
    guard let parts = value.elements, parts.count == 3, let offset = parts[0].string.flatMap(Int64.init), offset >= 0,
      String(offset) == parts[0].string, let length = parts[1].number, length > 0, length.rounded() == length,
      length <= Double(CloudWire.maximumPlainChunkBytes), let hash = parts[2].string, hash.count == 64,
      hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw CloudFailure.invalidRequest }
    return .init(offset: offset, length: Int(length), hash: hash)
  }
}

/// What this Mac last sent for one source file. Only an enqueued page moves this state forward.
public struct CloudConversationFileState: Codable, Sendable, Equatable {
  public let fileID: String
  public let sourceID: String
  public var stamp: String
  public var device: Int64
  public var inode: UInt64
  public var size: Int64
  public var chunkBytes: Int
  public var entries: [CloudConversationChunkEntry]
  public var digest: String
  public var pages: [String]
  /// Current manifest or archive marker. Its payload names the file for a later marker.
  public var head: CloudOperation?
  public init(fileID: String, sourceID: String, stamp: String, device: Int64, inode: UInt64, size: Int64, chunkBytes: Int,
              entries: [CloudConversationChunkEntry], digest: String, pages: [String], head: CloudOperation?) {
    self.fileID = fileID; self.sourceID = sourceID; self.stamp = stamp; self.device = device; self.inode = inode; self.size = size
    self.chunkBytes = chunkBytes; self.entries = entries; self.digest = digest; self.pages = pages; self.head = head
  }
  public var archived: Bool { head?.kind == .archive }
}

/// Supplied by the durable reconciler. The exporter asks before reading a file and commits after the consumer took the page.
public protocol CloudConversationJournalPort: Sendable {
  func state(fileID: String) async throws -> CloudConversationFileState?
  func commit(_ state: CloudConversationFileState) async throws
  /// New disappearance markers for completely enumerated sources, plus any earlier ones the outbox has not accepted yet.
  func finish(completedSources: Set<String>, present: Set<String>, at: Int64) async throws -> [CloudOperation]
  func markSent(_ operationIDs: [String]) async throws
}

/// Owner-side state replayed from an append-only log. Only a successfully enumerated source may produce a disappearance marker.
public struct CloudConversationReconciliation: Sendable {
  public private(set) var files: [String: CloudConversationFileState] = [:]
  public private(set) var unsent: [String: CloudOperation] = [:]
  public init() {}

  /// A change line carries only the kept prefix length and the added entries, so one append writes O(new chunks) bytes.
  public struct Line: Codable, Sendable {
    public var t: String
    public var file: CloudConversationFileState?
    public var keep: Int?
    public var marker: CloudOperation?
    public var sent: [String]?
    public init(t: String, file: CloudConversationFileState? = nil, keep: Int? = nil, marker: CloudOperation? = nil, sent: [String]? = nil) {
      self.t = t; self.file = file; self.keep = keep; self.marker = marker; self.sent = sent
    }
  }
  public func line(for next: CloudConversationFileState) -> Line {
    let previous = files[next.fileID]?.entries ?? []
    var keep = 0
    while keep < previous.count, keep < next.entries.count, previous[keep] == next.entries[keep] { keep += 1 }
    var delta = next
    delta.entries = Array(next.entries[keep...])
    return .init(t: "f", file: delta, keep: keep, marker: nil, sent: nil)
  }
  public mutating func replay(_ line: Line) throws {
    switch line.t {
    case "f":
      guard var delta = line.file, let keep = line.keep, keep >= 0 else { throw CloudFailure.invalidRequest }
      let previous = files[delta.fileID]?.entries ?? []
      guard keep <= previous.count else { throw CloudFailure.invalidRequest }
      delta.entries = Array(previous.prefix(keep)) + delta.entries
      files[delta.fileID] = delta
    case "m":
      guard let marker = line.marker, marker.kind == .archive else { throw CloudFailure.invalidRequest }
      unsent[marker.opId] = marker
    case "x":
      for id in line.sent ?? [] { unsent[id] = nil }
    default: throw CloudFailure.unsupportedFormat
    }
  }
  /// Lines that rebuild this exact state; used to compact a long log in one atomic replace.
  public func compacted() -> [Line] {
    files.keys.sorted().map { Line(t: "f", file: files[$0], keep: 0, marker: nil, sent: nil) }
      + unsent.keys.sorted().map { Line(t: "m", file: nil, keep: nil, marker: unsent[$0], sent: nil) }
  }
  /// Markers are deterministic per archived revision, so a crash before the log line replays the same id.
  public func markers(completedSources: Set<String>, present: Set<String>, at: Int64) throws -> [(CloudConversationFileState, CloudOperation)] {
    var result: [(CloudConversationFileState, CloudOperation)] = []
    for id in files.keys.sorted() {
      guard var state = files[id], let previous = state.head, previous.kind != .archive,
            completedSources.contains(state.sourceID), !present.contains(id) else { continue }
      let opID = try CloudConversationIdentity.uuid(["conversation-archive", id, previous.opId])
      var payload = previous.payload.raw.setting("kind", .string("archive")).setting("archivedRevision", .string(previous.opId))
      for key in ["bytes", "chunks", "chunkBytes", "chunkDigest", "pages"] { payload = payload.removing(key) }
      let value = CloudValue(payload)
      let marker = CloudOperation(v: 1, opId: opID, originDevice: previous.originDevice, domain: previous.domain,
        entityId: previous.entityId, revision: opID, parents: [previous.opId], kind: .archive,
        projectId: previous.projectId, rootId: previous.rootId, source: .init(sourceId: previous.source.sourceId, recordId: previous.source.recordId),
        createdAt: at, payload: value, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(value)))
      try CloudSyncPack.validate([marker])
      state.head = marker
      result.append((state, marker))
    }
    return result
  }
}
