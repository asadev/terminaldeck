import Foundation

/// Held inside one legacy writer's actor (or lock). It binds that owner to one Cloud account's ledger (design D3)
/// and runs the import protocol of design D1 around the owner's own write. Live records stay owned by the writer.
public struct CloudBrainAgentsArchive: Sendable {
  private let ownerDirectory: URL?
  private let namespace: String
  private let domains: Set<String>
  public private(set) var ledger: CloudBrainAgentsLedger?
  private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
  /// `ownerDirectory` nil keeps the ledger in memory (fixture-only owners).
  public init(ownerDirectory: URL?, namespace: String, domains: Set<String>) {
    self.ownerDirectory = ownerDirectory; self.namespace = namespace; self.domains = domains
  }
  public var attached: Bool { ledger != nil }
  /// Binds once per account. A second account must detach the first (sign-out) before it can attach.
  public mutating func attach(_ account: CloudBrainAgentsAccount) throws {
    if let ledger { guard ledger.account == account else { throw CloudFailure.unsafeConfiguration }; return }
    ledger = try CloudBrainAgentsLedger(account: account, domains: domains,
      directory: try ownerDirectory.map { try account.directory(owner: $0, namespace: namespace) })
  }
  public mutating func detach() {
    ledger = nil
    for listener in listeners.values { listener.finish() }
    listeners = [:]
  }
  private func bound() throws -> CloudBrainAgentsLedger { guard let ledger else { throw CloudFailure.gateClosed }; return ledger }

  /// Post-write capture: a no-op while no account is attached.
  @discardableResult
  public mutating func capture(_ records: [CloudBrainAgentsRecord], sourceID: String, complete: Bool,
                               scope: (String) -> Bool = { _ in true }, shape: CloudBrainAgentsShape = .identity) throws -> CloudBrainAgentsCapture {
    guard var ledger else { return .init(operations: [], refused: [:], foreign: 0) }
    defer { self.ledger = ledger }
    let result = try ledger.capture(records, sourceID: sourceID, at: CloudSyncBytes.now(), complete: complete, scope: scope, shape: shape)
    if !result.operations.isEmpty { notify() }
    return result
  }

  /// D1: retain → plan → owner validation → pending → owner write → finish → per-record results.
  /// `write` performs the owner's single write and returns the values actually stored per key (nil = absent),
  /// plus refusals from the owner's own validator. It must leave the owner unchanged when it throws.
  public mutating func importing(_ incoming: [CloudOperation], current: (String) throws -> NativeRPCValue?, shape: CloudBrainAgentsShape,
                                 validate: ([CloudBrainAgentsProjection]) throws -> [String: String] = { _ in [:] },
                                 write: ([CloudBrainAgentsProjection]) throws -> [String: NativeRPCValue?]) throws -> [CloudItemResult] {
    var ledger = try bound()
    // Whatever reached the log (retained revisions, pending intents) stays in memory too, even when the write fails.
    defer { self.ledger = ledger }
    let fresh = try ledger.retain(incoming)
    var keys = Set<String>()
    for op in incoming {
      if op.entityId.hasPrefix(CloudBrainAgentsLedger.partPrefix) {
        if let head = op.payload.raw["head"].string, let owner = ledger.operations[head] { keys.insert(CloudBrainAgentsLedger.key(owner)) }
      } else { keys.insert(CloudBrainAgentsLedger.key(op)) }
    }
    return try project(&ledger, keys: keys, current: current, shape: shape, validate: validate, write: write, incoming: incoming, fresh: fresh)
  }
  /// Re-evaluates every record whose Cloud head is not yet shown (vault unlocked, path mapped, parts complete).
  public mutating func refresh(current: (String) throws -> NativeRPCValue?, shape: CloudBrainAgentsShape,
                               validate: ([CloudBrainAgentsProjection]) throws -> [String: String] = { _ in [:] },
                               write: ([CloudBrainAgentsProjection]) throws -> [String: NativeRPCValue?]) throws -> Int {
    var ledger = try bound()
    defer { self.ledger = ledger }
    let keys = Set(ledger.keys.filter { key in
      let heads = ledger.heads(key)
      return heads.count == 1 && ledger.local[key]?.base != heads[0].opId
    })
    var applied = 0
    _ = try project(&ledger, keys: keys, current: current, shape: shape, validate: validate, write: { items in
      let stored = try write(items); applied = stored.count; return stored
    }, incoming: [], fresh: [])
    return applied
  }
  private func project(_ ledger: inout CloudBrainAgentsLedger, keys: Set<String>, current: (String) throws -> NativeRPCValue?, shape: CloudBrainAgentsShape,
                       validate: ([CloudBrainAgentsProjection]) throws -> [String: String],
                       write: ([CloudBrainAgentsProjection]) throws -> [String: NativeRPCValue?],
                       incoming: [CloudOperation], fresh: Set<String>) throws -> [CloudItemResult] {
    var planned = try ledger.plan(keys, current: current, shape: shape)
    let refusals = try validate(planned)
    for item in planned where refusals[item.key] != nil { ledger.refuse(item, reason: refusals[item.key]!) }
    planned = planned.filter { refusals[$0.key] == nil }
    try ledger.begin(planned)
    let stored = planned.isEmpty ? [:] : try write(planned)
    var finished: [CloudBrainAgentsProjection] = []
    for item in planned {
      guard let value = stored[item.key] else { ledger.refuse(item, reason: "not written on this Mac"); continue }
      finished.append(item.with(image: try value.map { try CloudBrainAgentsRecord(domain: item.domain, id: item.entityID, value: $0).persistedValue().raw }))
    }
    try ledger.finish(finished)
    return ledger.results(for: incoming, fresh: fresh, shown: Set(finished.map(\.key)))
  }

  public func retained(_ operations: [CloudOperation]) throws -> Bool { try bound().retained(operations) }
  public func ownChanges(after: String?, limit: Int) throws -> [CloudOperation] { try bound().ownOperations(after: after, limit: limit) }
  public func cursor() throws -> String? { try bound().cursor }
  public mutating func saveCursor(_ value: String) throws {
    guard var ledger else { throw CloudFailure.gateClosed }
    try ledger.saveCursor(value); self.ledger = ledger
  }
  public func ownOperations() throws -> [CloudOperation] { try bound().ownOperations }
  /// Every retained revision (own and imported), for read-only history views and tests.
  public func revisions() throws -> [CloudOperation] { try bound().operations.values.sorted { ($0.createdAt, $0.opId) < ($1.createdAt, $1.opId) } }
  public func attention() -> [String] { ledger?.attention() ?? [] }
  public mutating func notices() -> AsyncStream<Void> {
    let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    if ledger == nil { stream.continuation.finish() } else { listeners[UUID()] = stream.continuation }
    return stream.stream
  }
  private mutating func notify() {
    for (id, listener) in listeners { if case .terminated = listener.yield(()) { listeners[id] = nil } }
  }
}

public enum CloudBrainAgentsSupport {
  /// Counts what an owner holds now. Zero exported is never complete; ledger attention keeps it incomplete.
  public static func coverage(row: String, sourceID: String, records: [CloudBrainAgentsRecord], blocked: [String], attention: [String] = []) throws -> CloudCoverage {
    var bytes: Int64 = 0
    for record in records { bytes += Int64(try CloudSyncCanonical.encode(record.persistedValue()).count) }
    let reasons = blocked + attention + (records.isEmpty ? ["No records were exported; this source is not verified complete."] : [])
    return .init(sourceId: sourceID, inventoryRow: row, complete: reasons.isEmpty, items: records.count, bytes: bytes, blockedReasons: reasons)
  }
  /// Until composition attaches each owner's durable change feed, never advertise a working watcher.
  public static func unavailableChanges() -> AsyncThrowingStream<CloudOperation, Error> {
    AsyncThrowingStream { $0.finish(throwing: CloudFailure.unavailable) }
  }
  public static func selected(_ value: NativeRPCValue, keys: Set<String>) -> NativeRPCValue {
    .object((value.fields ?? []).filter { keys.contains($0.key) })
  }
}
