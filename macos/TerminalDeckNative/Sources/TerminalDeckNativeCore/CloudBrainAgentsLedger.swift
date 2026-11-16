import Foundation
import Darwin

/// The signed-in Cloud account an owner's ledger belongs to. Records never cross accounts (design D3).
public struct CloudBrainAgentsAccount: Sendable, Equatable, Hashable {
  public let subjectHash: String
  public let deviceID: String
  public init(subjectHash: String, deviceID: String) throws {
    guard subjectHash.utf8.count == 64, subjectHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CloudFailure.invalidRequest }
    try CloudSyncBytes.transportID(deviceID)
    self.subjectHash = subjectHash; self.deviceID = deviceID
  }
  /// `<owner folder>/cloud/<subjectHash>/<namespace>`: the account-scoped home of one owner's ledger.
  public func directory(owner: URL, namespace: String) throws -> URL {
    guard !namespace.isEmpty, namespace.utf8.count <= 64, namespace.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw CloudFailure.invalidRequest }
    return owner.standardizedFileURL.appendingPathComponent("cloud").appendingPathComponent(subjectHash).appendingPathComponent(namespace)
  }
}

/// How a shared value is shown on this Mac, and how a value stored here is shared back.
/// `show` may return nil for history that this Mac keeps without showing; it throws when this Mac's own
/// validator refuses the version (the version is still kept in history, design D1).
public struct CloudBrainAgentsShape {
  public var show: (CloudOperation, NativeRPCValue) throws -> NativeRPCValue?
  public var share: (NativeRPCValue) throws -> NativeRPCValue
  public init(show: @escaping (CloudOperation, NativeRPCValue) throws -> NativeRPCValue?,
              share: @escaping (NativeRPCValue) throws -> NativeRPCValue = { $0 }) {
    self.show = show; self.share = share
  }
  /// Computed, not a stored shared constant: the shape holds plain closures and is not Sendable (Swift 6).
  public static var identity: CloudBrainAgentsShape { CloudBrainAgentsShape(show: { _, value in value }) }
}

/// One record an import asks the owner to write through its own writer.
public struct CloudBrainAgentsProjection: Sendable, Equatable {
  public let key: String
  public let domain: String
  public let entityID: String
  public let operationID: String
  /// The exact local value the owner must store. nil means the record is absent here (an archive head with no local copy).
  public let image: NativeRPCValue?
  /// The value the owner actually stored, which becomes the local image of this revision.
  public func with(image: NativeRPCValue?) -> CloudBrainAgentsProjection {
    .init(key: key, domain: domain, entityID: entityID, operationID: operationID, image: image)
  }
}

public struct CloudBrainAgentsCapture: Sendable {
  public let operations: [CloudOperation]
  /// Records that could not be shared, with the reason (never part of the batch failure).
  public let refused: [String: String]
  /// Unchanged values this Mac received from another Cloud account; never captured into this one.
  public let foreign: Int
}

/// Append-only, account-scoped ledger owned by one legacy writer (design D1/D2).
/// Every line is one atomic unit; a torn final line is ignored and cut before the next append.
public struct CloudBrainAgentsLedger: Sendable {
  public static let partFormat = "td-record-part-1"
  public static let partsFormat = "td-record-parts-1"
  public static let partPrefix = "#part:"
  public static let partBytes = 32 * 1024
  public static let maximumParts = 1_500
  /// A canonical payload above this travels as bounded parts (§4.4 keeps every payload below 64 KiB).
  public static let inlineLimit = 60 * 1024

  public struct Local: Codable, Sendable, Equatable {
    public let base: String
    public let hash: String
    public let image: CloudValue?
  }
  private struct Line: Codable {
    var t: String
    var ops: [CloudOperation]? = nil
    var key: String? = nil
    var base: String? = nil
    var hash: String? = nil
    var image: CloudValue? = nil
    var cursor: String? = nil
  }

  public let account: CloudBrainAgentsAccount
  public let domains: Set<String>
  private let file: URL?
  private var validLength: off_t = 0
  public private(set) var operations: [String: CloudOperation] = [:]
  private var byKey: [String: [String]] = [:]
  private var referenced: Set<String> = []
  public private(set) var local: [String: Local] = [:]
  public private(set) var pending: [String: Local] = [:]
  public private(set) var ownOrder: [String] = []
  public private(set) var cursor: String?
  /// Revisions this Mac keeps as history by design (never shown here); not a "needs attention" item.
  public private(set) var historyOnly: [String: String] = [:]
  private var reasons: [String: String] = [:]
  public private(set) var refused: [String: String] = [:]
  public private(set) var foreignKeys: Set<String> = []
  public var foreignSkipped: Int { foreignKeys.count }
  private var foreign: [String: String] = [:]
  private var hashCache: [String: (value: NativeRPCValue, hash: String)] = [:]

  /// `directory` nil keeps the ledger in memory (fixture owners that never touch disk).
  public init(account: CloudBrainAgentsAccount, domains: Set<String>, directory: URL?) throws {
    guard !domains.isEmpty else { throw CloudFailure.invalidRequest }
    self.account = account; self.domains = domains
    guard let directory else { file = nil; return }
    let path = directory.standardizedFileURL
    guard path.path.contains("/cloud/" + account.subjectHash + "/") else { throw CloudFailure.unsafeConfiguration }
    file = path.appendingPathComponent("ledger.log")
    if let data = try Self.readAll(file!) {
      var end = data.lastIndex(of: 10).map { $0 + 1 } ?? data.startIndex
      if end < data.startIndex { end = data.startIndex }
      validLength = off_t(end - data.startIndex)
      for line in data[data.startIndex..<end].split(separator: 10) where !line.isEmpty {
        try replay(try JSONDecoder().decode(Line.self, from: Data(line)))
      }
    }
    // Values received from another account on this Mac (D3). Read only; a damaged sibling only blocks this account's
    // foreign check by being skipped, never by uploading its records.
    let accounts = path.deletingLastPathComponent().deletingLastPathComponent()
    let namespace = path.lastPathComponent
    for other in (try? FileManager.default.contentsOfDirectory(atPath: accounts.path)) ?? [] where other != account.subjectHash {
      guard let data = try? Self.readAll(accounts.appendingPathComponent(other).appendingPathComponent(namespace).appendingPathComponent("ledger.log")) else { continue }
      var sibling = Self(memoryAccount: account, domains: domains)
      for line in data.split(separator: 10) where !line.isEmpty {
        guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line)) else { continue }
        try? sibling.replay(decoded)
      }
      for (key, state) in sibling.local where !state.hash.isEmpty {
        if let op = sibling.operations[state.base], op.originDevice != account.deviceID { foreign[key] = state.hash }
      }
    }
  }
  private init(memoryAccount: CloudBrainAgentsAccount, domains: Set<String>) { account = memoryAccount; self.domains = domains; file = nil }

  // MARK: replay and append

  private mutating func replay(_ line: Line) throws {
    switch line.t {
    case "retain", "capture":
      for op in line.ops ?? [] {
        if let old = operations[op.opId] { guard old == op else { throw CloudFailure.idReused }; continue }
        operations[op.opId] = op
        byKey[Self.key(op), default: []].append(op.opId)
        referenced.formUnion(op.parents)
        if line.t == "capture" { ownOrder.append(op.opId) }
      }
      if line.t == "capture", let key = line.key, let base = line.base, let hash = line.hash {
        local[key] = .init(base: base, hash: hash, image: line.image); pending[key] = nil
      }
    case "pending":
      guard let key = line.key, let base = line.base, let hash = line.hash else { throw CloudFailure.invalidRequest }
      pending[key] = .init(base: base, hash: hash, image: line.image)
    case "local":
      guard let key = line.key, let base = line.base, let hash = line.hash else { throw CloudFailure.invalidRequest }
      local[key] = .init(base: base, hash: hash, image: line.image); pending[key] = nil
    case "clear":
      guard let key = line.key else { throw CloudFailure.invalidRequest }
      pending[key] = nil
    case "cursor":
      cursor = line.cursor
    case "history":
      guard let key = line.key, let base = line.base else { throw CloudFailure.invalidRequest }
      historyOnly[key] = base
    default:
      throw CloudFailure.unsupportedFormat
    }
  }
  private mutating func append(_ lines: [Line]) throws {
    var next = self
    for line in lines { try next.replay(line) }
    if let file {
      var bytes = Data()
      for line in lines { bytes.append(try JSONEncoder().encode(line)); bytes.append(10) }
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw CloudFailure.unavailable }
      defer { Darwin.close(descriptor) }
      var info = stat()
      guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw CloudFailure.unsafeConfiguration }
      // A torn line from a crash is cut before anything new follows it.
      if info.st_size != validLength { guard ftruncate(descriptor, validLength) == 0 else { throw CloudFailure.unavailable } }
      guard lseek(descriptor, validLength, SEEK_SET) == validLength else { throw CloudFailure.unavailable }
      try bytes.withUnsafeBytes { raw in
        var done = 0
        while done < raw.count {
          let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: done), raw.count - done)
          if count < 0 { if errno == EINTR { continue }; throw CloudFailure.unavailable }
          guard count > 0 else { throw CloudFailure.unavailable }
          done += count
        }
      }
      guard fsync(descriptor) == 0 else { throw CloudFailure.unavailable }
      next.validLength = validLength + off_t(bytes.count)
    }
    self = next
  }
  private static func readAll(_ file: URL) throws -> Data? {
    let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    if descriptor < 0 { if errno == ENOENT { return nil }; throw CloudFailure.unavailable }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CloudFailure.unsafeConfiguration }
    var data = Data()
    while true {
      let part = try CloudConversationFileAccess.read(descriptor, count: 1 << 20)
      if part.isEmpty { return data }
      data.append(part)
    }
  }

  // MARK: graph

  public static func key(_ op: CloudOperation) -> String { op.domain + ":" + op.entityId }
  public static func key(domain: String, entityID: String) -> String { domain + ":" + entityID }
  public static func hash(_ value: NativeRPCValue) throws -> String { CloudSyncBytes.hash(try CloudSyncCanonical.encode(CloudValue(value))) }
  public func heads(_ key: String) -> [CloudOperation] {
    (byKey[key] ?? []).filter { !referenced.contains($0) }.compactMap { operations[$0] }.sorted { $0.opId < $1.opId }
  }
  public func versions(_ key: String) -> [CloudOperation] { (byKey[key] ?? []).compactMap { operations[$0] } }
  public var keys: [String] { byKey.keys.filter { !Self.isPartKey($0) }.sorted() }
  public func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
    if ancestor == descendant { return true }
    var queue = [descendant], seen = Set<String>(), index = 0
    while index < queue.count {
      let id = queue[index]; index += 1
      for parent in operations[id]?.parents ?? [] where seen.insert(parent).inserted {
        if parent == ancestor { return true }
        queue.append(parent)
      }
    }
    return false
  }
  static func isPartKey(_ key: String) -> Bool { key.split(separator: ":", maxSplits: 1).last.map { $0.hasPrefix(partPrefix) } ?? false }
  public func retained(_ incoming: [CloudOperation]) -> Bool { incoming.allSatisfy { operations[$0.opId] == $0 } }

  /// The whole domain payload of a revision, assembled from its parts when it travelled in parts.
  public func payload(_ op: CloudOperation) throws -> NativeRPCValue? {
    let raw = op.payload.raw
    guard raw["format"].string == Self.partsFormat, op.kind != .archive else { return raw }
    guard let ids = raw["parts"].elements, let size = raw["bytes"].string.flatMap(Int.init), let hash = raw["hash"].string else { throw CloudFailure.invalidRequest }
    var bytes = Data()
    for (index, id) in ids.enumerated() {
      guard let id = id.string, let part = operations[id] else { return nil }
      let p = part.payload.raw
      guard p["format"].string == Self.partFormat, p["head"].string == op.opId, p["index"].number == Double(index),
        let text = p["data"].string, let data = Data(base64Encoded: text) else { throw CloudFailure.invalidRequest }
      bytes.append(data)
    }
    guard bytes.count == size, CloudSyncBytes.hash(bytes) == hash else { throw CloudFailure.checksumMismatch }
    return try NativeRPCValue.parseJSON(bytes)
  }

  // MARK: syntactic check (a failure here is a bad pack, never a domain refusal)

  public static func check(_ op: CloudOperation, domains: Set<String>) throws {
    try CloudSyncPack.validate([op])
    guard op.v == 1, domains.contains(op.domain), !op.entityId.isEmpty,
      !op.source.sourceId.isEmpty, !op.source.recordId.isEmpty,
      UUID(uuidString: op.opId) != nil, op.revision == op.opId,
      !op.parents.contains(op.revision), Set(op.parents).count == op.parents.count,
      CloudSyncBytes.hash(try CloudSyncCanonical.encode(op.payload)) == op.payloadHash else { throw CloudFailure.invalidRequest }
    let p = op.payload.raw
    if op.entityId.hasPrefix(partPrefix) {
      guard op.kind == .append, op.parents.isEmpty, p["format"].string == partFormat, let head = p["head"].string, UUID(uuidString: head) != nil,
        let index = p["index"].number, index >= 0, index.rounded() == index, index < Double(maximumParts),
        op.entityId == partPrefix + head + ":" + String(Int(index)),
        let text = p["data"].string, let data = Data(base64Encoded: text), data.count <= partBytes, data.base64EncodedString() == text,
        Set((p.fields ?? []).map(\.key)) == ["format", "head", "index", "data"] else { throw CloudFailure.invalidRequest }
    } else if p["format"].string == partsFormat, op.kind != .archive {
      guard let ids = p["parts"].elements, !ids.isEmpty, ids.count <= maximumParts,
        ids.allSatisfy({ $0.string.flatMap(UUID.init(uuidString:)) != nil }), Set(ids.compactMap(\.string)).count == ids.count,
        let size = p["bytes"].string.flatMap(Int.init), size > 0, size <= maximumParts * partBytes,
        let hash = p["hash"].string, hash.count == 64,
        Set((p.fields ?? []).map(\.key)) == ["format", "parts", "bytes", "hash"] else { throw CloudFailure.invalidRequest }
    } else if op.kind == .archive {
      guard let archived = p["archivedRevision"].string, op.parents == [archived] else { throw CloudFailure.invalidRequest }
    }
  }

  // MARK: capture (design D2): called only with values that the owner actually wrote

  /// `scope` limits which keys a complete capture may mark as removed: a part of a store that is still waiting
  /// for its own write is never treated as a removal.
  public mutating func capture(_ records: [CloudBrainAgentsRecord], sourceID: String, at: Int64, complete: Bool,
                               scope: (String) -> Bool = { _ in true }, shape: CloudBrainAgentsShape = .identity) throws -> CloudBrainAgentsCapture {
    guard Set(records.map(\.key)).count == records.count else { throw CloudFailure.idReused }
    var lines: [Line] = [], additions: [CloudOperation] = [], refusedNow: [String: String] = [:], foreignNow = 0, foreignNowKeys = Set<String>()
    var present = Set<String>()
    for record in records {
      let key = record.key
      present.insert(key)
      do {
        guard domains.contains(record.domain), !record.id.hasPrefix(Self.partPrefix), record.id.utf8.count <= 200 else { throw CloudFailure.invalidRequest }
        let value = try record.persistedValue().raw
        // Canonical hashing is the expensive step on the hot save path; an identical value reuses its hash (finding 17).
        let hash: String
        if let cached = hashCache[key], cached.value == value { hash = cached.hash } else { hash = try Self.hash(value); hashCache[key] = (value, hash) }
        lines += resolvePending(key, current: hash)
        let state = resolvedLocal(key, lines: lines)
        if state?.hash == hash { continue }
        if state == nil, foreign[key] == hash { foreignNow += 1; foreignNowKeys.insert(key); continue }
        var merged = value
        if let state, let base = operations[state.base], base.kind != .archive, let parent = try payload(base) {
          merged = Self.merge3(parent: parent, image: state.image?.raw ?? parent, current: value)
        }
        let shared = try CloudBrainAgentsRecord(domain: record.domain, id: record.id, value: try shape.share(merged)).persistedValue().raw
        let ops = try Self.makeOperations(for: record, payload: shared, parents: state.map { [$0.base] } ?? [], sourceID: sourceID, deviceID: account.deviceID, at: at)
        let head = ops.last!
        lines.append(.init(t: "capture", ops: ops, key: key, base: head.opId, hash: hash, image: shared == value ? nil : CloudValue(value)))
        additions += ops
      } catch {
        refusedNow[key] = Self.describe(error)
      }
    }
    if complete {
      for key in local.keys.sorted() where scope(key) && !present.contains(key) && !Self.isPartKey(key) {
        lines += resolvePending(key, current: "")
        guard let state = resolvedLocal(key, lines: lines), !state.hash.isEmpty, let old = operations[state.base] else { continue }
        let value = CloudValue(.object([.init("archivedRevision", .string(old.revision))]))
        let id = UUID().uuidString.lowercased()
        let op = CloudOperation(v: 1, opId: id, originDevice: account.deviceID, domain: old.domain, entityId: old.entityId, revision: id,
          parents: [old.revision], kind: .archive, projectId: old.projectId, rootId: old.rootId,
          source: .init(sourceId: sourceID, recordId: old.source.recordId), createdAt: at, payload: value,
          payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(value)))
        try Self.check(op, domains: [old.domain])
        lines.append(.init(t: "capture", ops: [op], key: key, base: id, hash: ""))
        additions.append(op)
      }
    }
    if !lines.isEmpty { try append(lines) }
    for key in Array(refused.keys) where present.contains(key) || (complete && scope(key)) { refused[key] = nil }
    refused.merge(refusedNow) { $1 }
    for key in present { foreignKeys.remove(key) }
    if complete { foreignKeys = foreignKeys.filter { !scope($0) } }
    foreignKeys.formUnion(foreignNowKeys)
    return .init(operations: additions, refused: refusedNow, foreign: foreignNow)
  }

  /// Field-level three-way merge: what changed here (current versus the image written for the parent) is applied
  /// on top of the parent's shared value; every untouched field keeps the parent's value (design D4).
  public static func merge3(parent: NativeRPCValue, image: NativeRPCValue, current: NativeRPCValue) -> NativeRPCValue {
    if current == image { return parent }
    guard let p = parent.fields, let i = image.fields, let c = current.fields else { return current }
    func lookup(_ fields: [NativeRPCValue.Field], _ key: String) -> NativeRPCValue { fields.last(where: { $0.key == key })?.value ?? .missing }
    var keys: [String] = [], seen = Set<String>()
    for key in c.map(\.key) + p.map(\.key) + i.map(\.key) where seen.insert(key).inserted { keys.append(key) }
    var result: [NativeRPCValue.Field] = []
    for key in keys {
      let cv = lookup(c, key), iv = lookup(i, key), pv = lookup(p, key)
      let next: NativeRPCValue
      if cv == iv { next = pv }
      else if cv.fields != nil, iv.fields != nil, pv.fields != nil { next = merge3(parent: pv, image: iv, current: cv) }
      else { next = cv }
      if next != .missing { result.append(.init(key, next)) }
    }
    return .object(result)
  }

  static func makeOperations(for record: CloudBrainAgentsRecord, payload: NativeRPCValue, parents: [String], sourceID: String,
                         deviceID: String, at: Int64) throws -> [CloudOperation] {
    let value = CloudValue(payload)
    let bytes = try CloudSyncCanonical.encode(value)
    let id = UUID().uuidString.lowercased()
    func make(_ id: String, entity: String, kind: CloudOperationKind, parents: [String], payload: CloudValue, recordID: String) throws -> CloudOperation {
      let op = CloudOperation(v: 1, opId: id, originDevice: deviceID, domain: record.domain, entityId: entity, revision: id,
        parents: parents, kind: kind, projectId: record.projectID, rootId: record.rootID, source: .init(sourceId: sourceID, recordId: recordID),
        createdAt: at, payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
      try check(op, domains: [record.domain]); return op
    }
    if bytes.count <= inlineLimit {
      return [try make(id, entity: record.id, kind: .put, parents: parents, payload: value, recordID: record.id)]
    }
    // Bounded parts carry the exact canonical bytes; the head names them in order and binds their hash (finding 2).
    let raw = try payload.encodedJSON()
    let count = (raw.count + partBytes - 1) / partBytes
    guard count <= maximumParts else { throw CloudFailure.unsupportedFormat }
    var parts: [CloudOperation] = []
    for index in 0..<count {
      let slice = raw.subdata(in: index * partBytes..<min(raw.count, (index + 1) * partBytes))
      let partValue = CloudValue(.object([.init("format", .string(partFormat)), .init("head", .string(id)),
        .init("index", .number(Double(index))), .init("data", .string(slice.base64EncodedString()))]))
      parts.append(try make(UUID().uuidString.lowercased(), entity: partPrefix + id + ":" + String(index), kind: .append, parents: [], payload: partValue, recordID: record.id))
    }
    let head = CloudValue(.object([.init("format", .string(partsFormat)), .init("parts", .array(parts.map { .string($0.opId) })),
      .init("bytes", .string(String(raw.count))), .init("hash", .string(CloudSyncBytes.hash(raw)))]))
    return parts + [try make(id, entity: record.id, kind: .put, parents: parents, payload: head, recordID: record.id)]
  }

  // MARK: import (design D1)

  /// Retain first; then decide per touched key whether the unique causal head can be shown here.
  /// `current` returns the value the owner currently stores for a key (nil = absent).
  public mutating func retain(_ incoming: [CloudOperation]) throws -> Set<String> {
    var fresh: [CloudOperation] = [], ids = Set<String>()
    for op in incoming {
      try Self.check(op, domains: domains)
      if let old = operations[op.opId] { guard old == op else { throw CloudFailure.idReused }; continue }
      guard ids.insert(op.opId).inserted else { continue }
      fresh.append(op)
    }
    // A revision may not join a graph from another entity.
    var all = operations
    for op in fresh { all[op.opId] = op }
    for op in fresh {
      for parent in op.parents { if let p = all[parent], Self.key(p) != Self.key(op) { throw CloudFailure.invalidRequest } }
    }
    // A causal cycle (S06) is refused before anything is kept.
    for key in Set(fresh.map(Self.key)) { _ = try CloudSyncPack.heads(versions(key) + fresh.filter { Self.key($0) == key }) }
    if !fresh.isEmpty { try append([.init(t: "retain", ops: fresh)]) }
    return Set(fresh.map(\.opId))
  }

  public mutating func plan(_ keys: Set<String>, current: (String) throws -> NativeRPCValue?, shape: CloudBrainAgentsShape) throws -> [CloudBrainAgentsProjection] {
    var projections: [CloudBrainAgentsProjection] = [], lines: [Line] = []
    for key in keys.sorted() where !Self.isPartKey(key) {
      let value = try current(key)
      let hash = try value.map(Self.hash) ?? ""
      lines += resolvePending(key, current: hash)
      let state = resolvedLocal(key, lines: lines)
      let heads = heads(key)
      reasons[key] = nil
      guard heads.count == 1 else {
        if heads.count > 1 { reasons[key] = "Two versions were made on different devices; both are kept." }
        continue
      }
      let head = heads[0]
      if state?.base == head.opId { continue }
      if let state, !isAncestor(state.base, of: head.opId) { reasons[key] = "This Mac shows a different version; both are kept."; continue }
      if let state, state.hash != hash { reasons[key] = "Changed on this Mac too; both versions are kept."; continue }
      if head.kind == .archive {
        if value == nil { projections.append(.init(key: key, domain: head.domain, entityID: head.entityId, operationID: head.opId, image: nil)) }
        else { reasons[key] = "Removed on another device; this Mac keeps its copy." }
        continue
      }
      do {
        guard let shared = try payload(head) else { reasons[key] = "Waiting for the rest of this record."; continue }
        guard let shown = try shape.show(head, shared) else {
          reasons[key] = "Kept in Cloud history; this kind of record is not shown on another device."
          if historyOnly[key] != head.opId { lines.append(.init(t: "history", key: key, base: head.opId)) }
          continue
        }
        let image = try CloudBrainAgentsRecord(domain: head.domain, id: head.entityId, value: shown).persistedValue().raw
        if state == nil, value != nil {
          // Identical content already here (made on both Macs): adopt the revision, nothing is written.
          if try Self.hash(image) == hash { lines.append(.init(t: "local", key: key, base: head.opId, hash: hash, image: CloudValue(image))); continue }
          reasons[key] = "A record with this id already exists here; it is kept and the Cloud version is in history."; continue
        }
        projections.append(.init(key: key, domain: head.domain, entityID: head.entityId, operationID: head.opId, image: image))
      } catch {
        reasons[key] = "Kept in history; this version cannot be shown on this Mac (" + Self.describe(error) + ")."
      }
    }
    if !lines.isEmpty { try append(lines) }
    return projections
  }
  /// A projection the owner's own validator refused stays in history with its reason (finding 15).
  public mutating func refuse(_ projection: CloudBrainAgentsProjection, reason: String) {
    reasons[projection.key] = "Kept in history; this version cannot be shown on this Mac (" + reason + ")."
  }
  /// Durable intent before the owner writes; a crash in between is resolved by comparing hashes later.
  public mutating func begin(_ projections: [CloudBrainAgentsProjection]) throws {
    guard !projections.isEmpty else { return }
    try append(try projections.map { item in
      .init(t: "pending", key: item.key, base: item.operationID, hash: try item.image.map(Self.hash) ?? "", image: item.image.map(CloudValue.init))
    })
  }
  public mutating func finish(_ projections: [CloudBrainAgentsProjection]) throws {
    guard !projections.isEmpty else { return }
    try append(try projections.map { item in
      .init(t: "local", key: item.key, base: item.operationID, hash: try item.image.map(Self.hash) ?? "", image: item.image.map(CloudValue.init))
    })
  }
  /// `applied` only when this Mac now shows the revision or a later one; anything retained but not shown is `kept_both` with its reason (finding 1).
  /// A repeated delivery is `already_present` unless this call is what finally showed it (a retry after a failed write).
  public func results(for incoming: [CloudOperation], fresh: Set<String>, shown: Set<String> = []) -> [CloudItemResult] {
    incoming.map { op in
      var target = op
      if op.entityId.hasPrefix(Self.partPrefix), let head = op.payload.raw["head"].string {
        guard let headOp = operations[head] else { return .init(entityId: op.entityId, status: .keptBoth, reason: "Part kept; waiting for its record.") }
        target = headOp
      }
      let key = Self.key(target)
      guard fresh.contains(op.opId) || shown.contains(key) else { return .init(entityId: op.entityId, status: .alreadyPresent) }
      if let base = local[key]?.base, isAncestor(target.opId, of: base) { return .init(entityId: op.entityId, status: .applied) }
      return .init(entityId: op.entityId, status: .keptBoth, reason: reasons[key] ?? "Kept in history; this Mac shows a different version.")
    }
  }

  private func resolvedLocal(_ key: String, lines: [Line]) -> Local? {
    for line in lines.reversed() where line.key == key && (line.t == "local" || line.t == "capture") {
      if let base = line.base, let hash = line.hash { return .init(base: base, hash: hash, image: line.image) }
    }
    return local[key]
  }
  /// An interrupted projection: finished if the owner holds the projected value, dropped otherwise (D1).
  private func resolvePending(_ key: String, current: String) -> [Line] {
    guard let intent = pending[key] else { return [] }
    if intent.hash == current { return [.init(t: "local", key: key, base: intent.base, hash: intent.hash, image: intent.image)] }
    return [.init(t: "clear", key: key)]
  }

  // MARK: change feed (own revisions only, D3)

  public func ownOperations(after: String?, limit: Int) throws -> [CloudOperation] {
    guard (1...256).contains(limit) else { throw CloudFailure.invalidRequest }
    var start = 0
    if let after {
      guard let index = ownOrder.firstIndex(of: after) else { throw CloudFailure.versionChanged }
      start = index + 1
    }
    return ownOrder.dropFirst(start).prefix(limit).compactMap { operations[$0] }
  }
  public var ownOperations: [CloudOperation] { ownOrder.compactMap { operations[$0] } }
  public mutating func saveCursor(_ value: String) throws {
    guard ownOrder.contains(value) else { throw CloudFailure.invalidRequest }
    if cursor != value { try append([.init(t: "cursor", cursor: value)]) }
  }

  // MARK: coverage

  /// Plain-language attention reasons: kept-both versions, history this Mac cannot show, refused records.
  public func attention() -> [String] {
    var result: [String] = []
    let conflicts = keys.filter { heads($0).count > 1 }.count
    if conflicts > 0 { result.append("\(conflicts) record(s) have two versions kept; choose one to continue editing.") }
    let hidden = keys.filter { key in
      let heads = heads(key)
      guard heads.count == 1, heads[0].kind != .archive, historyOnly[key] != heads[0].opId else { return false }
      return local[key]?.base != heads[0].opId && !(local[key].map { isAncestor(heads[0].opId, of: $0.base) } ?? false)
    }.count
    if hidden > 0 { result.append("\(hidden) Cloud record(s) are kept in history but not shown on this Mac.") }
    if !refused.isEmpty { result.append("\(refused.count) record(s) could not be shared from this Mac.") }
    if foreignSkipped > 0 { result.append("\(foreignSkipped) record(s) came from another Cloud account and are not uploaded to this one.") }
    return result
  }

  static func describe(_ error: Error) -> String {
    if let error = error as? NativeRPCError { return error.message }
    if let error = error as? CloudFailure {
      switch error {
      case .unsupportedFormat: return "unsupported format"
      case .invalidRequest: return "not valid here"
      case .checksumMismatch: return "content check failed"
      default: return "not readable here"
      }
    }
    return "not readable here"
  }
}
