import Foundation
import Darwin
import TerminalDeckNativeCore

/// Owns only a new Cloud archive directory under the account's Cloud folder. It never writes a provider transcript store.
/// Operations are kept in one append-only index, loaded once; chunk plaintext is kept once per immutable blob.
public actor BackendCloudConversationArchive {
  public nonisolated let subjectHash: String
  private let persistence: BackendTaskPersistence
  private let content: any CloudContentPort
  private let log: BackendCloudConversationLog
  private var loaded = false
  private var operations: [String: CloudOperation] = [:]
  /// Manifest and archive-marker ids per conversation file, and every id named as a parent.
  private var fileOperations: [String: [String]] = [:]
  private var referenced = Set<String>()
  public init(directory: URL, content: any CloudContentPort, subjectHash: String) throws {
    try BackendCloudConversationAccount.check(directory, subjectHash: subjectHash)
    self.subjectHash = subjectHash
    persistence = try .init(directory: directory, ownership: .exclusive); self.content = content
    log = try .init(directory: directory, name: "index.log")
  }
  private func load() throws {
    guard !loaded else { return }
    for line in try log.lines() { remember(try JSONDecoder().decode(CloudOperation.self, from: line)) }
    loaded = true
  }
  private func remember(_ op: CloudOperation) {
    operations[op.opId] = op
    if ["file", "archive"].contains(op.payload.raw["kind"].string ?? "") {
      fileOperations[op.entityId, default: []].append(op.opId)
      referenced.formUnion(op.parents)
    }
  }
  private func operation(_ id: String) throws -> CloudOperation? { try load(); return operations[id] }

  // MARK: Validation

  private static func hex64(_ value: String?) -> Bool { value.map { $0.count == 64 && $0.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) } ?? false }
  private static let manifestKeys: Set<String> = ["v", "kind", "provider", "profileId", "profileIds", "fileId", "relativePath", "relativePrefix",
                                                  "bytes", "chunks", "chunkBytes", "chunkDigest", "pages"]
  private static let markerKeys: Set<String> = ["v", "kind", "provider", "profileId", "profileIds", "fileId", "relativePath", "relativePrefix", "archivedRevision"]
  public static func validate(_ op: CloudOperation) throws {
    try CloudSyncPack.validate([op])
    let p = op.payload.raw
    guard p["v"].number == 1, let provider = p["provider"].string.flatMap(CloudConversationProvider.init(rawValue:)),
      op.domain == provider.domain, let file = p["fileId"].string, hex64(file), op.source.recordId == file else { throw CloudFailure.invalidRequest }
    let keys = Set((p.fields ?? []).map(\.key))
    switch p["kind"].string {
    case "chunk":
      guard op.kind == .append, op.parents.isEmpty, keys == ["v", "kind", "provider", "fileId", "offset", "length", "plainHash", "blob"] else { throw CloudFailure.invalidRequest }
      let entry = try CloudConversationChunkEntry.parse(.array([p["offset"], p["length"], p["plainHash"]]))
      guard op.opId == (try CloudConversationIdentity.chunkOperation(fileID: file, entry: entry)),
        op.entityId == CloudConversationIdentity.chunkEntity(fileID: file, entry: entry), op.source.offset == entry.offset else { throw CloudFailure.invalidRequest }
      let blob = try JSONDecoder().decode(CloudBlobRef.self, from: p["blob"].encodedJSON())
      let expected = try CloudConversationIdentity.blob(fileID: file, deviceID: op.originDevice, offset: entry.offset, plainHash: entry.hash)
      guard blob.storageClass == .brain, blob.purpose == .brain, blob.blobId == expected else { throw CloudFailure.invalidRequest }
    case "list":
      guard op.kind == .put, op.parents.isEmpty, keys == ["v", "kind", "provider", "fileId", "first", "entries"],
        let first = p["first"].number, first >= 0, first.rounded() == first, first < 1e15,
        Int(first) % CloudConversationIdentity.listPageEntries == 0,
        let rows = p["entries"].elements, (1...CloudConversationIdentity.listPageEntries).contains(rows.count) else { throw CloudFailure.invalidRequest }
      let entries = try rows.map(CloudConversationChunkEntry.parse)
      guard op.opId == (try CloudConversationIdentity.listOperation(fileID: file, first: Int(first), entries: entries)),
        op.entityId == file + "/l/" + op.opId else { throw CloudFailure.invalidRequest }
    case "file":
      guard op.entityId == file, keys == manifestKeys || keys == manifestKeys.union(["branch"]),
        (op.kind == .put && op.parents.isEmpty) || (op.kind == .supersede && op.parents.count == 1),
        let bytes = p["bytes"].string.flatMap(Int64.init), bytes >= 0, String(bytes) == p["bytes"].string,
        let count = p["chunks"].number, count >= 0, count.rounded() == count, count < 1e15,
        let chunkBytes = p["chunkBytes"].number, chunkBytes >= 1, chunkBytes <= Double(CloudWire.maximumPlainChunkBytes),
        let digest = p["chunkDigest"].string, let pages = p["pages"].elements,
        pages.count == (Int(count) + CloudConversationIdentity.listPageEntries - 1) / CloudConversationIdentity.listPageEntries,
        pages.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }),
        op.opId == (try CloudConversationIdentity.manifestOperation(fileID: file, digest: digest, bytes: bytes, parent: op.parents.first)) else { throw CloudFailure.invalidRequest }
      try names(p)
    case "archive":
      guard op.kind == .archive, op.entityId == file, keys == markerKeys || keys == markerKeys.union(["branch"]),
        let previous = p["archivedRevision"].string, op.parents == [previous],
        op.opId == (try CloudConversationIdentity.uuid(["conversation-archive", file, previous])) else { throw CloudFailure.invalidRequest }
      try names(p)
    default: throw CloudFailure.unsupportedFormat
    }
  }
  private static func names(_ p: NativeRPCValue) throws {
    guard let profile = p["profileId"].string, !profile.isEmpty, let profiles = p["profileIds"].elements,
      profiles.allSatisfy({ $0.string?.isEmpty == false }), profiles.contains(.string(profile)),
      let relative = p["relativePath"].string, CloudConversationEnumerator.safeRelative(relative),
      let prefix = p["relativePrefix"].string, prefix.isEmpty || CloudConversationEnumerator.safeRelative(prefix) else { throw CloudFailure.invalidRequest }
    if p.has("branch") { _ = try CloudConversationBranch.parse(p["branch"]) }
  }

  // MARK: Import

  /// Validate/decrypt one chunk at a time into unlisted staging files before publishing any operation.
  public func prepare(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> [String: URL] {
    try load()
    guard Set(files.map(\.blobId)).count == files.count else { throw CloudFailure.invalidRequest }
    let byID = Dictionary(uniqueKeysWithValues: files.map { ($0.blobId, $0) })
    var staged: [String: URL] = [:], used = Set<String>()
    for op in operations {
      try Self.validate(op)
      if let old = self.operations[op.opId] {
        guard old == op else { throw CloudFailure.idReused }
        if op.payload.raw["kind"].string == "chunk" { let id = try blobID(op); if byID[id] != nil { used.insert(id) } }
        continue
      }
      guard op.payload.raw["kind"].string == "chunk" else { continue }
      let ref = try JSONDecoder().decode(CloudBlobRef.self, from: op.payload.raw["blob"].encodedJSON())
      let length = Int(op.payload.raw["length"].number!), hash = op.payload.raw["plainHash"].string
      guard let file = byID[ref.blobId], file.reference == ref else { throw CloudFailure.invalidRequest }
      if let existing = try persistence.readOwnedBytes(ref.blobId + ".bytes", maximumBytes: CloudWire.maximumPlainChunkBytes),
         existing.count == length, CloudSyncBytes.hash(existing) == hash {
        staged[op.opId] = try persistence.file(ref.blobId + ".bytes"); used.insert(ref.blobId); continue
      }
      let reader = try BackendTaskPersistence(directory: file.localURL.deletingLastPathComponent())
      guard let sealed = try reader.readOwnedBytes(file.localURL.lastPathComponent, maximumBytes: CloudWire.maximumBlobBytes) else { throw CloudFailure.unavailable }
      try CloudSyncBytes.verify(sealed, ref: ref)
      let envelope = try JSONDecoder().decode(CloudContentEnvelope.self, from: sealed)
      guard envelope.storageClass == .brain, envelope.purpose == .brain, envelope.blobId == ref.blobId, envelope.epoch == ref.keyEpoch else { throw CloudFailure.invalidRequest }
      let plain = try await content.open(envelope)
      guard plain.count == length, CloudSyncBytes.hash(plain) == hash else { throw CloudFailure.checksumMismatch }
      let name = "prepared-" + ref.blobId + ".bytes"
      try put(plain, named: name)
      staged[op.opId] = try persistence.file(name); used.insert(ref.blobId)
    }
    guard used == Set(files.map(\.blobId)) else { throw CloudFailure.invalidRequest }
    return staged
  }
  public func apply(_ incoming: [CloudOperation], staged: [String: URL]) throws -> [CloudItemResult] {
    try load()
    let existing = Set(incoming.filter { operations[$0.opId] != nil }.map(\.opId))
    // Chunks, then their lists, then manifests, then markers; the result order still follows the input.
    func rank(_ op: CloudOperation) -> Int { switch op.payload.raw["kind"].string { case "chunk": 0; case "list": 1; case "file": 2; default: 3 } }
    for op in incoming.sorted(by: { (rank($0), $0.opId) < (rank($1), $1.opId) }) {
      try Self.validate(op)
      if let old = operations[op.opId] { guard old == op else { throw CloudFailure.idReused }; continue }
      switch op.payload.raw["kind"].string {
      case "chunk":
        let id = try blobID(op), stagedName = "prepared-" + id + ".bytes", activeName = id + ".bytes"
        let stagedURL = try persistence.file(stagedName), activeURL = try persistence.file(activeName)
        guard let file = staged[op.opId], file == stagedURL || file == activeURL,
          let bytes = try persistence.readOwnedBytes(file.lastPathComponent, maximumBytes: CloudWire.maximumPlainChunkBytes),
          bytes.count == Int(op.payload.raw["length"].number!), CloudSyncBytes.hash(bytes) == op.payload.raw["plainHash"].string else { throw CloudFailure.checksumMismatch }
        try put(bytes, named: activeName)
      case "file": _ = try entries(op)
      case "archive": try verifyArchive(op)
      default: break
      }
      try log.append([try JSONEncoder().encode(op)])
      remember(op)
    }
    guard try retained(incoming) else { throw CloudFailure.checksumMismatch }
    for file in Set(staged.values) where file.lastPathComponent.hasPrefix("prepared-") { try persistence.remove(file.lastPathComponent) }
    return incoming.map { .init(entityId: $0.entityId, status: existing.contains($0.opId) ? .alreadyPresent : .applied) }
  }
  public func retained(_ incoming: [CloudOperation]) throws -> Bool {
    try load()
    for op in incoming {
      guard operations[op.opId] == op else { return false }
      switch op.payload.raw["kind"].string {
      case "chunk":
        guard let data = try persistence.readOwnedBytes(try blobID(op) + ".bytes", maximumBytes: CloudWire.maximumPlainChunkBytes),
              CloudSyncBytes.hash(data) == op.payload.raw["plainHash"].string else { return false }
      case "file": _ = try entries(op)
      case "archive": try verifyArchive(op)
      default: break
      }
    }
    return true
  }
  private func put(_ bytes: Data, named name: String) throws {
    if let old = try persistence.readOwnedBytes(name, maximumBytes: max(CloudWire.maximumBlobBytes, bytes.count)) {
      guard old == bytes else { throw CloudFailure.idReused }; return
    }
    try persistence.writeBytes(name, data: bytes, replace: false)
  }
  private func blobID(_ operation: CloudOperation) throws -> String {
    try JSONDecoder().decode(CloudBlobRef.self, from: operation.payload.raw["blob"].encodedJSON()).blobId
  }
  /// The manifest's complete chunk list. Chunk bytes were hashed when written; here only presence and size are checked.
  private func entries(_ manifest: CloudOperation) throws -> [CloudConversationChunkEntry] {
    let p = manifest.payload.raw
    guard p["kind"].string == "file", let file = p["fileId"].string, let count = p["chunks"].number,
      let expected = p["bytes"].string.flatMap(Int64.init), let pages = p["pages"].elements else { throw CloudFailure.invalidRequest }
    var result: [CloudConversationChunkEntry] = []
    for (index, page) in pages.enumerated() {
      guard let id = page.string, let list = operations[id], list.payload.raw["kind"].string == "list", list.payload.raw["fileId"].string == file,
        list.payload.raw["first"].number == Double(index * CloudConversationIdentity.listPageEntries) else { throw CloudFailure.checksumMismatch }
      result += try (list.payload.raw["entries"].elements ?? []).map(CloudConversationChunkEntry.parse)
    }
    var offset: Int64 = 0
    for entry in result {
      guard entry.offset == offset, let chunk = operations[try CloudConversationIdentity.chunkOperation(fileID: file, entry: entry)],
        chunk.originDevice == manifest.originDevice, chunk.source.sourceId == manifest.source.sourceId else { throw CloudFailure.checksumMismatch }
      var info = stat()
      guard lstat(try persistence.file(try blobID(chunk) + ".bytes").path, &info) == 0, Int(info.st_size) == entry.length else { throw CloudFailure.checksumMismatch }
      offset += Int64(entry.length)
    }
    guard result.count == Int(count), offset == expected, CloudConversationIdentity.digest(result) == p["chunkDigest"].string else { throw CloudFailure.checksumMismatch }
    return result
  }
  private func verifyArchive(_ marker: CloudOperation) throws {
    guard let previousID = marker.payload.raw["archivedRevision"].string, let previous = operations[previousID],
      previous.entityId == marker.entityId, previous.domain == marker.domain, previous.source.sourceId == marker.source.sourceId else { throw CloudFailure.checksumMismatch }
    if previous.payload.raw["kind"].string == "file" { _ = try entries(previous) }
  }

  // MARK: Reading (never leases or launches anything)

  /// Current versions only: one row per conversation file (a file removed at its source shows its last version).
  public func manifests(provider: CloudConversationProvider? = nil, after: String? = nil, limit: Int = 50) throws -> [CloudOperation] {
    guard (1...200).contains(limit) else { throw CloudFailure.invalidRequest }
    try load()
    var result: [CloudOperation] = []
    for fileID in fileOperations.keys {
      for head in try heads(fileID: fileID) {
        let shown = head.kind == .archive ? head.payload.raw["archivedRevision"].string.flatMap { operations[$0] } : head
        guard let shown, shown.payload.raw["kind"].string == "file", provider == nil || shown.domain == provider?.domain else { continue }
        if let after, shown.opId <= after { continue }
        result.append(shown)
      }
    }
    return Array(result.sorted { $0.opId < $1.opId }.prefix(limit))
  }
  /// Heads of one file's version graph. More than one head means two kept versions.
  public func heads(fileID: String) throws -> [CloudOperation] {
    try load()
    return (fileOperations[fileID] ?? []).filter { !referenced.contains($0) }.compactMap { operations[$0] }.sorted { $0.opId < $1.opId }
  }
  public func history(fileID: String) throws -> [CloudOperation] {
    try load()
    return (fileOperations[fileID] ?? []).compactMap { operations[$0] }.sorted { $0.opId < $1.opId }
  }
  public func claudeSupport(mainManifestID: String, conversationID: String) throws -> [CloudOperation] {
    let main = try metadata(manifestID: mainManifestID)
    guard main.payload.raw["provider"].string == "claude", let relative = main.payload.raw["relativePath"].string,
      URL(fileURLWithPath: relative).lastPathComponent == conversationID + ".jsonl" else { throw CloudFailure.unsupportedFormat }
    let folder = relative.split(separator: "/").dropLast().joined(separator: "/")
    let prefix = folder.isEmpty ? "" : folder + "/"
    var result: [CloudOperation] = []
    for (fileID, ids) in fileOperations where fileID != main.entityId {
      guard let sample = ids.first.flatMap({ operations[$0] }), sample.source.sourceId == main.source.sourceId, sample.domain == main.domain,
        let path = sample.payload.raw["relativePath"].string,
        path.hasPrefix(prefix + conversationID + "/") || path == prefix + "sessions-index.json" else { continue }
      let heads = try heads(fileID: fileID)
      guard heads.count == 1 else { throw CloudFailure.versionChanged }
      if heads[0].kind == .archive {
        guard let id = heads[0].payload.raw["archivedRevision"].string else { throw CloudFailure.invalidRequest }
        result.append(try metadata(manifestID: id))
      } else { result.append(heads[0]) }
    }
    return result.sorted { $0.entityId < $1.entityId }
  }
  public func chunkAt(manifestID: String, index: Int) throws -> Data? {
    let manifest = try metadata(manifestID: manifestID)
    guard index >= 0 else { throw CloudFailure.invalidRequest }
    let list = try entries(manifest)
    guard index < list.count else { return nil }
    return try bytes(manifest, list[index])
  }
  private func bytes(_ manifest: CloudOperation, _ entry: CloudConversationChunkEntry) throws -> Data {
    let file = manifest.payload.raw["fileId"].string!
    guard let chunk = operations[try CloudConversationIdentity.chunkOperation(fileID: file, entry: entry)],
      let data = try persistence.readOwnedBytes(try blobID(chunk) + ".bytes", maximumBytes: CloudWire.maximumPlainChunkBytes),
      data.count == entry.length, CloudSyncBytes.hash(data) == entry.hash else { throw CloudFailure.checksumMismatch }
    return data
  }
  public func metadata(manifestID: String) throws -> CloudOperation {
    guard let op = try operation(manifestID), op.payload.raw["kind"].string == "file" else { throw CloudFailure.invalidRequest }
    try Self.validate(op)
    return op
  }
  public func read(manifestID: String, offset: Int64, limit: Int) throws -> Data {
    guard offset >= 0, (1...CloudWire.maximumPlainChunkBytes).contains(limit) else { throw CloudFailure.invalidRequest }
    let manifest = try metadata(manifestID: manifestID)
    var result = Data()
    for entry in try entries(manifest) where entry.offset + Int64(entry.length) > offset {
      let data = try bytes(manifest, entry)
      let from = Int(max(0, offset - entry.offset))
      result.append(data.subdata(in: from..<min(data.count, from + limit - result.count)))
      if result.count == limit { break }
    }
    return result
  }
}
