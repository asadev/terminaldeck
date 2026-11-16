import Foundation

// Lane A2, lean first version (cloud-lean-v1.md item 7): the list of projects and the agents arrive on a second Mac.
// One adapter shape for every record kind, over the merge core (CloudBrainAgentsMerge) and the per-account store
// (CloudBrainAgentsStore) that are already built. Nothing here registers itself: lane A's wiring builds and starts it.

/// One kind of record of an owner store as it travels (design v2 Appendix A): how its record ids are spelled, its
/// signed field table, and the record that must have arrived before it (an agent after its instruction file).
public struct CloudBrainRecordKind: Sendable {
  public let prefix: String
  public let suffix: String
  public let table: CloudBrainMergeTable
  /// Fields whose old and new value may be shown in the "changed from your other devices" list (one plain line).
  public let listedValues: Set<String>
  /// Given the record's own id: the record id that must be on this Mac first; nil = none.
  public let requires: (@Sendable (String) -> String)?
  public init(prefix: String, suffix: String = "", table: CloudBrainMergeTable, listedValues: Set<String> = [],
              requires: (@Sendable (String) -> String)? = nil) {
    self.prefix = prefix; self.suffix = suffix; self.table = table; self.listedValues = listedValues; self.requires = requires
  }
  public func entity(_ id: String) -> String { prefix + id + suffix }
  /// The record's own id, or nil when `entity` is not of this kind.
  public func id(of entity: String) -> String? {
    guard entity.hasPrefix(prefix), suffix.isEmpty || entity.hasSuffix(suffix), entity.count > prefix.count + suffix.count else { return nil }
    return String(entity.dropFirst(prefix.count).dropLast(suffix.count))
  }
}

/// What this Mac does with the Cloud's merged value of one record. Made by the owner, written by nothing but
/// `cloudWrite`.
public struct CloudBrainRecordPlan: Sendable {
  /// The travelling value this Mac holds afterwards, exactly as the owner will store it; nil = no such record here.
  public var store: NativeRPCValue?
  /// Fields whose Cloud value is not shown here ("waiting on this Mac"), each with the reason in plain words.
  public var held: [String: String]
  /// The whole record waits (it is not created here), with the reason. Nothing is written then.
  public var waiting: String?
  /// One plain line the page shows once for this record while it holds (nothing waits and nothing is refused by it).
  public var note: String?
  public init(store: NativeRPCValue?, held: [String: String] = [:], waiting: String? = nil, note: String? = nil) {
    self.store = store; self.held = held; self.waiting = waiting; self.note = note
  }
}

/// What an owner store gives the record adapter. Every call is the owner's own narrow path: no event, no session,
/// no task, no routine and no notification may start from any of them (design v2 D11).
public enum CloudBrainRecordMissing: Sendable {
  case keep
  /// An intended removal only. Extra fields are supplied only when every Mac understands their table.
  case remove(metadata: NativeRPCValue?)
}

public protocol CloudBrainRecordOwner: Sendable {
  /// Every record stored on this Mac now: record id → its stored value (any keys; only signed fields travel).
  /// Throws while the saved list cannot be read whole: then nothing is captured and nothing counts as removed.
  func cloudRecords() async throws -> [String: NativeRPCValue]
  /// Decides what this Mac stores for `entity` given the Cloud's merged value (nil: removed in the Cloud). Writes
  /// nothing. Throws `CloudRecordRefusal` when this Mac cannot take the record right now (the sync core parks it and
  /// tries again); any other error means the owner is broken or shutting down.
  func cloudPlan(entity: String, cloud: NativeRPCValue?) async throws -> CloudBrainRecordPlan
  /// Stores exactly `value` (a plan's `store`) durably. `expecting` is the travelling value this Mac held when the
  /// plan was made (nil: none); when the record changed since, throw `CloudRecordRefusal` and write nothing.
  func cloudWrite(entity: String, value: NativeRPCValue, expecting: NativeRPCValue?) async throws
  /// After an import wrote these records: screens refresh. Display only: a signal no engine, routine or sweep listens
  /// to (not the task change hub, not the app-wide "tasks:changed" channel).
  func cloudImported(_ entities: [String]) async
  /// A short fingerprint of what this owner's plans depend on besides its own records (which projects are on this
  /// Mac, whether its trusted list can be read). When it changes, records that wait are looked at again at the next
  /// capture pass, so a record waiting for something outside its own row is never stuck. Read only.
  func cloudContext() async -> String
  func cloudMissing(entity: String, last: NativeRPCValue) async throws -> CloudBrainRecordMissing
  func cloudPendingRemovals() async throws -> [String]
  func cloudRemovalBase(entity: String) async throws -> NativeRPCValue?
  func cloudRemove(entity: String, expecting: NativeRPCValue?, removal: NativeRPCValue, device: String, at: Int64) async throws
  func cloudLocalOnly(entity: String) async throws -> Bool
  func cloudRestoring(entity: String) async throws -> Bool
  func cloudCaptured(entity: String, removed: Bool) async throws
  func cloudReceiving(entity: String, device: String, at: Int64) async
  func cloudTombstone(entity: String, removal: NativeRPCValue, device: String, at: Int64) async throws
}

extension CloudBrainRecordOwner {
  /// Owners whose plans depend on their own records only.
  public func cloudContext() async -> String { "" }
  public func cloudMissing(entity: String, last: NativeRPCValue) async throws -> CloudBrainRecordMissing { .keep }
  public func cloudPendingRemovals() async throws -> [String] { [] }
  public func cloudRemovalBase(entity: String) async throws -> NativeRPCValue? { nil }
  public func cloudRemove(entity: String, expecting: NativeRPCValue?, removal: NativeRPCValue, device: String, at: Int64) async throws {
    throw CloudRecordRefusal(reason: "This record's owner cannot apply a removal.")
  }
  public func cloudLocalOnly(entity: String) async throws -> Bool { false }
  public func cloudRestoring(entity: String) async throws -> Bool { false }
  public func cloudCaptured(entity: String, removed: Bool) async throws {}
  public func cloudReceiving(entity: String, device: String, at: Int64) async {}
  public func cloudTombstone(entity: String, removal: NativeRPCValue, device: String, at: Int64) async throws {}
}

/// Which Cloud account each record on this Mac came from (design v2 D9). One file for the Mac, outside every
/// account folder: `<cloud folder>/a2-origins.json`. A record that belongs to another account only does not exist
/// for this account's sync: it is never sent and never merged.
public final class CloudBrainRecordOrigins: @unchecked Sendable {
  static let unknownAccount = "unknown-account"
  private let file: URL
  private let lock = NSLock()
  private var rows: [String: Set<String>]
  /// The file was missing or unreadable while another account's folder exists on this Mac (D9.5): every record
  /// already here is then treated as another account's until the person decides.
  public let lostBesideAnotherAccount: Bool

  /// `fileName`: lane L3's tasks and settings keep their own file beside lane A2's in the same Cloud folder, so the
  /// check for another account's folder works for them too.
  public init(cloudFolder: URL, account: String, fileName: String = "a2-origins.json") throws {
    let folder = cloudFolder.standardizedFileURL
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let target = folder.appendingPathComponent(fileName)
    var loaded: [String: Set<String>]?
    if let data = try? Data(contentsOf: target) {
      loaded = (try? JSONDecoder().decode([String: [String]].self, from: data))?.mapValues { Set($0) }
      if loaded == nil {
        try? FileManager.default.moveItem(at: target, to: folder.appendingPathComponent(fileName + ".damaged-\(Int64(Date().timeIntervalSince1970 * 1000))"))
      }
    }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let others = names.contains { name in
      name != account && name.utf8.count == 64 && name.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    file = target
    lostBesideAnotherAccount = loaded == nil && others
    rows = loaded ?? [:]
  }
  private static func key(_ domain: String, _ entity: String) -> String { domain + "\n" + entity }
  public func accounts(domain: String, entity: String) -> Set<String> { lock.withLock { rows[Self.key(domain, entity)] ?? [] } }
  /// True when the record on this Mac came from other accounts only.
  public func belongsElsewhere(domain: String, entity: String, account: String) -> Bool {
    let known = accounts(domain: domain, entity: entity)
    return !known.isEmpty && !known.contains(account)
  }
  public func add(domain: String, entity: String, account: String) throws {
    try lock.withLock {
      let key = Self.key(domain, entity)
      if rows[key]?.contains(account) == true { return }
      rows[key, default: []].insert(account)
      try save()
    }
  }
  /// After a lost file beside another account (D9.5): every record already on this Mac without an origin is marked
  /// as another account's, once per domain. Records made or received later are unaffected.
  public func quarantine(domain: String, entities: [String]) throws {
    guard lostBesideAnotherAccount else { return }
    try lock.withLock {
      let marker = "\u{1}" + domain
      if rows[marker] != nil { return }
      for entity in entities where rows[Self.key(domain, entity)] == nil { rows[Self.key(domain, entity)] = [Self.unknownAccount] }
      rows[marker] = ["done"]
      try save()
    }
  }
  private func save() throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(rows.mapValues { $0.sorted() }).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}

/// What Settings → Cloud can show for one row, read-only: how many earlier versions are kept, what waits on this
/// Mac, and what changed here from other devices. No value that came from another device is in it, except the
/// one-line fields a kind lists (design v2 D1 "What the person sees", S6).
public struct CloudBrainRecordListing: Sendable, Equatable {
  public struct Kept: Sendable, Equatable {
    public let record: String, field: String, device: String
    public let time: Int64
    /// True when the kept value is this Mac's own; only then `preview` carries its first characters.
    public let mine: Bool
    public let preview: String?
  }
  public struct Waiting: Sendable, Equatable { public let record: String, field: String, reason: String }
  public struct Change: Codable, Sendable, Equatable {
    public let record: String, field: String, device: String
    public let time: Int64
    public let from: String?, to: String?
  }
  public let keptCount: Int
  public let kept: [Kept]
  public let waiting: [Waiting]
  public let changes: [Change]
  public let gaps: [String]
  /// One line per record whose accepted name also answers to another name's mentions, shown once.
  public let mentions: [String]
  /// Left out on purpose, in plain words: what never travels, and records kept here for another Cloud account only.
  public let notes: [String]
}

/// One domain of records of one owner store, between that owner and the sync core (design v2 D1, D2, D8, D9, D11).
/// Bound to one signed-in account when built; `stop()` is final (sign-out), deletes nothing and ends every capture.
/// Two error kinds only: `CloudRecordRefusal` ("cannot apply this record": the sync core parks it and the feed moves
/// on) and anything else ("broken or shutting down": the pack is tried again).
public actor CloudBrainRecordAdapter: CloudDomainAdapter {
  private struct State: Codable {
    var reasons: [String: [String: String]] = [:]
    var waiting: [String: String] = [:]
    var changes: [CloudBrainRecordListing.Change] = []
    /// One line per record, from its owner's last plan. Optional so a state file written before it still reads.
    var notes: [String: String]? = nil
  }
  private struct Parsed { let key: CloudBrainRecordKey; let kind: CloudBrainRecordKind; let id: String; let version: CloudBrainMergeVersion }

  public nonisolated let inventoryRows: [String]
  public nonisolated let domain: String
  public nonisolated let sourceId: String
  private let kinds: [CloudBrainRecordKind]
  private let store: CloudBrainAgentsStore
  private let account: CloudBrainAgentsAccount
  private let owner: any CloudBrainRecordOwner
  private let origins: CloudBrainRecordOrigins
  private let exclusions: [String]
  private let stateFile: URL
  private let setupFile: URL
  private var state: State
  private var stopped = false
  private var lastSeen: [String: NativeRPCValue] = [:]
  private var incomplete: Set<String> = []
  private var tooLarge = 0, elsewhere = 0, items = 0
  private var unreadable: String?
  private var retryWanted = false
  private var waitingFor: Set<String> = []
  private var reconsidered = false
  private var lastContext: String?
  private var locked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  /// `store` is this account's bookkeeping database; its folder also keeps this adapter's two small state files.
  public init(domain: String, inventoryRow: String, sourceId: String, kinds: [CloudBrainRecordKind], store: CloudBrainAgentsStore,
              account: CloudBrainAgentsAccount, owner: any CloudBrainRecordOwner, origins: CloudBrainRecordOrigins,
              exclusions: [String] = []) throws {
    let name = try CloudWire.domain(domain)
    guard !kinds.isEmpty, kinds.allSatisfy({ $0.table.domain == name && !$0.prefix.isEmpty }), !sourceId.isEmpty, !inventoryRow.isEmpty else {
      throw CloudFailure.invalidRequest
    }
    let folder = store.file.deletingLastPathComponent()
    let stem = "a2-" + name.replacingOccurrences(of: "/", with: "_")
    let saved = folder.appendingPathComponent(stem + "-state.json")
    var loaded = State()
    if let data = try? Data(contentsOf: saved), let decoded = try? JSONDecoder().decode(State.self, from: data) { loaded = decoded }
    self.domain = name; self.inventoryRows = [inventoryRow]; self.sourceId = sourceId; self.kinds = kinds; self.store = store
    self.account = account; self.owner = owner; self.origins = origins; self.exclusions = exclusions
    self.stateFile = saved; self.setupFile = folder.appendingPathComponent(stem + "-setup.json"); self.state = loaded
  }

  // MARK: small helpers

  private func live() throws { if stopped { throw CloudFailure.gateClosed } }
  /// Sign-out or a closed gate: final. Nothing is deleted; no capture, import, snapshot or hand-over runs after it.
  public func stop() { stopped = true }
  /// One capture or import at a time: a capture that read the owner before an import wrote must never run after it.
  private func enter() async {
    if locked { await withCheckedContinuation { waiters.append($0) } } else { locked = true }
  }
  private func leave() {
    if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() }
  }
  private func kindOf(_ entity: String) -> (kind: CloudBrainRecordKind, id: String)? {
    for kind in kinds { if let id = kind.id(of: entity) { return (kind, id) } }
    return nil
  }
  private func recordKey(_ entity: String) throws -> CloudBrainRecordKey { try CloudBrainRecordKey(domain: domain, entity: entity) }
  /// Only the signed fields travel: every other key of a stored row stays on this Mac (allow-list, design v2 D10.1).
  public static func travelling(_ value: NativeRPCValue, table: CloudBrainMergeTable) -> NativeRPCValue {
    .object(table.classes.keys.sorted().compactMap { name -> NativeRPCValue.Field? in
      guard table.classes[name] != .thisMac, value.has(name) else { return nil }
      return NativeRPCValue.Field(name, value[name])
    })
  }
  public static func equal(_ a: NativeRPCValue?, _ b: NativeRPCValue?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case (let left?, let right?): return CloudValue(left) == CloudValue(right)
    default: return false
    }
  }
  /// One field of a travelling value, with "absent" and "empty" read alike.
  private static func field(_ value: NativeRPCValue?, _ name: String) -> NativeRPCValue {
    guard let value, value.has(name), !value[name].isNullish else { return .null }
    return value[name]
  }
  private func saveState() throws {
    if state.changes.count > 200 { state.changes.removeFirst(state.changes.count - 200) }
    try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
  }

  // MARK: capture (this Mac → Cloud)

  /// One record through the store's capture. A record whose history is incomplete here waits: no version over it.
  @discardableResult
  private func capture(_ key: CloudBrainRecordKey, _ value: NativeRPCValue?, table: CloudBrainMergeTable, restore: Bool = false) throws -> Bool {
    do {
      _ = try store.capture(key, local: value, restore: restore, table: table, opId: UUID().uuidString.lowercased(), device: account.deviceID)
      incomplete.remove(key.entity)
      return true
    } catch CloudBrainMergeError.historyIncomplete { incomplete.insert(key.entity); return false }
  }
  /// A field stops waiting when this Mac's value has become the Cloud's value (the person set it here).
  private func release(_ key: CloudBrainRecordKey, _ value: NativeRPCValue, table: CloudBrainMergeTable) throws {
    let held = try store.held(key)
    guard !held.isEmpty, let view = try? store.view(key, table: table) else { return }
    let shown = NativeRPCValue.object(view.fields.map { NativeRPCValue.Field($0.key, $0.value) })
    let still = held.filter { !Self.equal(Self.field(shown, $0), Self.field(value, $0)) }
    guard still != held else { return }
    try store.setHeld(key, still)
    if var reasons = state.reasons[key.entity] {
      for name in held.subtracting(still) { reasons[name] = nil }
      state.reasons[key.entity] = reasons.isEmpty ? nil : reasons
      try saveState()
    }
  }
  /// The capture pass: every record the owner stores now is compared with what was last captured; a changed one
  /// becomes one version; a missing record travels only with its owner's explicit intent. True on changes.
  @discardableResult
  public func captureLocal() async throws -> Bool {
    try live()
    await enter(); defer { leave() }
    return try await captureLocked()
  }
  private func captureLocked() async throws -> Bool {
    try live()
    let records: [String: NativeRPCValue]
    do { records = try await owner.cloudRecords() }
    catch {
      unreadable = "This Mac's saved list could not be read whole, so nothing of it is sent until it can be."
      return false
    }
    try live()
    unreadable = nil
    try origins.quarantine(domain: domain, entities: records.keys.sorted())
    var changed = false, count = 0, foreign = 0
    for kind in kinds {
      for entity in records.keys.sorted() where kind.id(of: entity) != nil {
        guard let raw = records[entity] else { continue }
        if origins.belongsElsewhere(domain: domain, entity: entity, account: account.subjectHash) { foreign += 1; continue }
        if try await owner.cloudLocalOnly(entity: entity) { continue }
        count += 1
        let value = Self.travelling(raw, table: kind.table)
        if lastSeen[entity] == value { continue }
        let key = try recordKey(entity)
        let restoring = try await owner.cloudRestoring(entity: entity)
        guard try capture(key, value, table: kind.table, restore: restoring) else { continue }
        try await owner.cloudCaptured(entity: entity, removed: false)
        try origins.add(domain: domain, entity: entity, account: account.subjectHash)
        try release(key, value, table: kind.table)
        lastSeen[entity] = value; changed = true
      }
    }
    // Absence is not intent. Instruction-file witnesses and local marks belong to the backend owner;
    // Core cannot import that module. Every missing row asks its owner before capturing a tombstone.
    let pending = try await owner.cloudPendingRemovals()
    // A create followed by Delete before its first capture still needs its original version in the Cloud's
    // history. Required records are seeded first; none of these owner writes launch work on the receiving Mac.
    for kind in kinds {
      for entity in pending.sorted() where kind.id(of: entity) != nil {
        let key = try recordKey(entity)
        guard try store.graph(key).nodes.isEmpty, let base = try await owner.cloudRemovalBase(entity: entity),
              case .remove = try await owner.cloudMissing(entity: entity, last: base) else { continue }
        try capture(key, Self.travelling(base, table: kind.table), table: kind.table)
      }
    }
    let missing = Set(try store.storedEntities(domain: domain)).union(pending)
    for entity in missing.sorted() where records[entity] == nil {
      guard let found = kindOf(entity) else { continue }
      let key = try recordKey(entity)
      let view: CloudBrainMergeView?
      do { view = try store.view(key, table: found.kind.table) }
      catch CloudBrainMergeError.historyIncomplete { incomplete.insert(entity); continue }
      let image = try store.image(key).value
      let base = try await owner.cloudRemovalBase(entity: entity)
      guard let last = image ?? view?.shown() ?? base else { continue }
      if case .remove(let metadata) = try await owner.cloudMissing(entity: entity, last: last) {
        let restoring = view?.exists == false
        if let metadata {
          guard try capture(key, Self.travelling(last.merging(metadata), table: found.kind.table), table: found.kind.table, restore: restoring) else { continue }
        } else if view == nil || restoring {
          guard try capture(key, Self.travelling(last, table: found.kind.table), table: found.kind.table, restore: restoring) else { continue }
        }
        guard try capture(key, nil, table: found.kind.table) else { continue }
        try await owner.cloudCaptured(entity: entity, removed: true)
        lastSeen[entity] = nil; changed = true
      }
    }
    items = count; elsewhere = foreign
    // Waiting records are looked at again when this Mac's records changed, or when what their plans depend on outside
    // them did (review should-fix 1 and 3: an agent waiting for its project, or for the trusted list to be readable).
    let context = await owner.cloudContext()
    try live()
    if changed || !reconsidered || context != lastContext {
      reconsidered = true; lastContext = context
      try await reconsider(records)
    }
    return changed
  }
  /// Records that wait on this Mac, or hold fields back, are looked at again: the cause may have ended.
  private func reconsider(_ given: [String: NativeRPCValue]) async throws {
    let holding = try store.heldEntities(domain: domain)
    let entities = Set(state.waiting.keys).union(holding.keys)
    var written: [String] = [], records = given
    for entity in entities.sorted() {
      guard let found = kindOf(entity) else { continue }
      let mine = records[entity].map { Self.travelling($0, table: found.kind.table) }
      do {
        if try await show(try recordKey(entity), entity: entity, kind: found.kind, mine: mine, device: "", time: 0) != nil {
          written.append(entity)
          // A record placed now can make another one placeable (an agent, then its instructions): read the owner again
          // so the next record is compared with what this Mac holds now, not with what it held before this write.
          if let fresh = try? await owner.cloudRecords() { records = fresh }
        }
      } catch is CloudRecordRefusal { continue }
      try live()
    }
    if !written.isEmpty { await owner.cloudImported(written) }
  }

  // MARK: hand-over to the sync core

  private func operation(_ key: CloudBrainRecordKey, _ revision: CloudBrainMergeRevision) throws -> CloudOperation {
    let payload = CloudValue(revision.version.payload())
    return .init(v: 1, opId: revision.opId, originDevice: account.deviceID, domain: domain, entityId: key.entity, revision: revision.opId,
      parents: revision.parents, kind: .put, source: .init(sourceId: sourceId, recordId: key.entity), createdAt: revision.time,
      payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
  }
  /// This Mac's own versions not yet with the sync core, oldest first (within one moment a required record first).
  /// A version too large to send is held back together with every later version of the same record, and counted.
  /// Read in pages of 256 until `limit` sendable versions are found or none are left, so versions held back never hide
  /// later ones (review should-fix 5: 256 too-large versions used to block every later send).
  private func pending(limit: Int) throws -> [CloudOperation] {
    var rows: [(key: CloudBrainRecordKey, revision: CloudBrainMergeRevision)] = [], offset = 0
    while true {
      let page = try store.ownUnhanded(domain: domain, limit: 256, offset: offset)
      rows += page; offset += page.count
      let found = try sendable(rows, limit: limit)
      if page.count < 256 || found.operations.count >= limit {
        tooLarge = found.blocked
        return found.operations
      }
    }
  }
  private func sendable(_ rows: [(key: CloudBrainRecordKey, revision: CloudBrainMergeRevision)], limit: Int) throws -> (operations: [CloudOperation], blocked: Int) {
    func rank(_ entity: String) -> Int { kinds.firstIndex { $0.id(of: entity) != nil } ?? kinds.count }
    let sorted = rows.sorted { left, right in
      (left.revision.time, rank(left.key.entity), left.revision.opId) < (right.revision.time, rank(right.key.entity), right.revision.opId)
    }
    var blocked = Set<String>(), result: [CloudOperation] = []
    for row in sorted {
      let entity = row.key.entity
      if blocked.contains(entity) { continue }
      if let found = kindOf(entity), let needs = found.kind.requires?(found.id), blocked.contains(needs) { blocked.insert(entity); continue }
      let op = try operation(row.key, row.revision)
      guard let payload = try? CloudSyncCanonical.encode(op.payload), payload.count <= CloudWire.maximumRecordPayloadBytes,
            let whole = try? CloudSyncCanonical.encode(op), whole.count <= CloudWire.maximumRecordBytes else { blocked.insert(entity); continue }
      if result.count < limit { result.append(op) }
    }
    return (result, blocked.count)
  }
  /// Hands this Mac's own unsent versions to the sync core and marks them handed after its local receipt. Nothing
  /// is handed while a setup page is still open (the setup carries those versions itself). Returns how many went.
  @discardableResult
  public func handOver(to outbox: any CloudOutboxPort) async throws -> Int {
    try live()
    await enter(); defer { leave() }
    guard !FileManager.default.fileExists(atPath: setupFile.path) else { return 0 }
    var total = 0
    while true {
      try live()
      let operations = try pending(limit: 64)
      guard !operations.isEmpty else { break }
      _ = try await outbox.enqueue(operations, files: [])
      try store.markHanded(operations.map(\.opId))
      total += operations.count
    }
    return total
  }
  /// True once, after an import that may let a record parked for a missing record apply now.
  public func takeRetryWanted() -> Bool {
    let wanted = retryWanted
    retryWanted = false
    return wanted
  }

  // MARK: CloudDomainAdapter

  private func gapList() -> [String] {
    var gaps: [String] = []
    if stopped { gaps.append("Signed out of Cloud on this Mac.") }
    if let unreadable { gaps.append(unreadable) }
    if !incomplete.isEmpty { gaps.append("\(incomplete.count) records wait for earlier versions that have not arrived on this Mac.") }
    if tooLarge > 0 { gaps.append("\(tooLarge) records are too large to send in this version and stay on this Mac.") }
    return gaps
  }
  private func exclusionList() -> [String] {
    var left = exclusions
    if elsewhere > 0 { left.append("\(elsewhere) records came from another Cloud account and are kept on this Mac only.") }
    if !state.waiting.isEmpty { left.append("\(state.waiting.count) records from another device wait on this Mac.") }
    return left
  }
  public func sourceInventory() async throws -> [CloudSourceInventory] {
    let gaps = gapList()
    return [.init(sourceId: sourceId, inventoryRow: inventoryRows[0], domain: domain, items: items, bytes: 0, complete: gaps.isEmpty,
      blockedReasons: gaps, exclusions: exclusionList())]
  }
  /// The setup page: this Mac's records as they are now, each one version. The page is kept until the setup has
  /// finished, so a setup that is run again with the same cut gets exactly the same page.
  public func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
    try live()
    await enter(); defer { leave() }
    if let data = try? Data(contentsOf: setupFile), let saved = try? JSONDecoder().decode(CloudDomainSnapshot.self, from: data),
       saved.cut.snapshotId == cut.snapshotId, saved.cut.at == cut.at {
      return saved
    }
    _ = try await captureLocked()
    try live()
    let operations = try pending(limit: 256)
    let gaps = gapList()
    let page = CloudDomainSnapshot(cut: cut, operations: operations, files: [], coverage: [
      .init(sourceId: sourceId, inventoryRow: inventoryRows[0], complete: gaps.isEmpty, items: items, bytes: 0, blockedReasons: gaps, exclusions: exclusionList())])
    try JSONEncoder().encode(page).write(to: setupFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: setupFile.path)
    return page
  }
  /// After the sync core's setup returned: the page's versions are with it now.
  public func setupFinished() throws {
    guard let data = try? Data(contentsOf: setupFile) else { return }
    if let saved = try? JSONDecoder().decode(CloudDomainSnapshot.self, from: data) { try store.markHanded(saved.operations.map(\.opId)) }
    try FileManager.default.removeItem(at: setupFile)
  }
  public func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> { AsyncThrowingStream { $0.finish() } }

  private func parse(_ op: CloudOperation) throws -> Parsed {
    func refuse(_ reason: String) -> CloudRecordRefusal { .init(operationIds: [op.opId], reason: reason) }
    guard op.v == 1, op.domain == domain, op.kind == .put, op.revision == op.opId, let found = kindOf(op.entityId),
          let key = try? CloudBrainRecordKey(domain: domain, entity: op.entityId),
          let bytes = try? CloudSyncCanonical.encode(op.payload), CloudSyncBytes.hash(bytes) == op.payloadHash,
          let version = try? CloudBrainMergeVersion(payload: op.payload.raw) else {
      throw refuse("This record is not in a form this app reads.")
    }
    guard version.minTable <= found.kind.table.version else {
      throw refuse("This record was written by a newer version of the app than this Mac runs.")
    }
    if let named = version.fields["id"]?.string, named != found.id { throw refuse("This record names another record's id.") }
    // No stamp inside a version may be dated further ahead than the store accepts for the version itself.
    let limit = store.clock.read() &+ CloudBrainAgentsStore.maximumAhead
    var newest = op.createdAt
    for stamp in version.stamps.values { newest = max(newest, stamp.time) }
    for elements in version.collections.values { for element in elements.values { newest = max(newest, element.stamp.time) } }
    for marks in version.removed.values { for mark in marks.values { newest = max(newest, mark.time) } }
    guard newest <= limit else { throw refuse("This record is dated more than a day ahead of the Cloud's clock.") }
    return .init(key: key, kind: found.kind, id: found.id, version: version)
  }
  public func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
    try live()
    guard files.isEmpty else { throw CloudRecordRefusal(operationIds: operations.map(\.opId), reason: "Records of this kind carry no files.") }
    var refused: [String] = [], reason = ""
    for op in operations {
      do { _ = try parse(op) }
      catch let refusal as CloudRecordRefusal { refused.append(op.opId); if reason.isEmpty { reason = refusal.reason } }
    }
    guard refused.isEmpty else { throw CloudRecordRefusal(operationIds: refused, reason: reason) }
    return .init(preparationId: UUID().uuidString.lowercased(), operations: operations, files: files)
  }
  /// Shows the Cloud's merged view of one record on this Mac as its owner decides. Returns the value written, or nil
  /// when nothing was written (already the same, waiting, or its history is incomplete here).
  private struct Shown { let value: NativeRPCValue? }
  private func show(_ key: CloudBrainRecordKey, entity: String, kind: CloudBrainRecordKind, mine: NativeRPCValue?,
                    device: String, time: Int64) async throws -> Shown? {
    let view: CloudBrainMergeView?
    do { view = try store.view(key, table: kind.table) }
    catch CloudBrainMergeError.historyIncomplete { incomplete.insert(entity); return nil }
    incomplete.remove(entity)
    guard let view else { return nil }
    // A reconsidered old-format removal still names its author, never the Mac delivering the retry.
    let sourceStamp = view.stamps[domain == "tasks" && view.exists ? "place" : CloudBrainMerge.existsField]
    let source = try store.graph(key).nodes[sourceStamp?.op ?? ""]
    let sourceDevice = source?.device ?? device, sourceTime = sourceStamp?.time ?? time
    await owner.cloudReceiving(entity: entity, device: sourceDevice, at: sourceTime)
    if !view.exists { try await owner.cloudTombstone(entity: entity, removal: view.shown(), device: sourceDevice, at: sourceTime) }
    let plan = try await owner.cloudPlan(entity: entity, cloud: view.exists ? view.shown() : nil)
    try live()
    let reasons = plan.waiting == nil ? plan.held : [:]
    var dirty = false
    if state.waiting[entity] != plan.waiting { state.waiting[entity] = plan.waiting; dirty = true }
    if (state.reasons[entity] ?? [:]) != reasons { state.reasons[entity] = reasons.isEmpty ? nil : reasons; dirty = true }
    if try store.held(key) != Set(reasons.keys) { try store.setHeld(key, Set(reasons.keys)) }
    let line = plan.waiting == nil ? plan.note : nil
    if state.notes?[entity] != line {
      var lines = state.notes ?? [:]
      lines[entity] = line
      state.notes = lines.isEmpty ? nil : lines
      dirty = true
    }
    let next = plan.store
    guard plan.waiting == nil, !Self.equal(next, mine) else {
      if dirty { try saveState() }
      return nil
    }
    // Crash rule (design v2 D8): the intent first, then the owner's write, then the image.
    try store.beginShow(key, heads: view.heads, willStore: next)
    do {
      if let next { try await owner.cloudWrite(entity: entity, value: next, expecting: mine) }
      else { try await owner.cloudRemove(entity: entity, expecting: mine, removal: view.shown(), device: sourceDevice, at: sourceTime) }
    }
    catch let refusal as CloudRecordRefusal {
      // The owner wrote nothing: the intent is withdrawn, so the crash rule never later takes this record as shown
      // at these heads (review should-fix 2). The record is parked and tried again as a whole.
      try store.cancelShow(key)
      throw refusal
    }
    try store.finishShow(key)
    lastSeen[entity] = next.map { Self.travelling($0, table: kind.table) }
    if !device.isEmpty {
      for name in kind.table.classes.keys.sorted() where kind.table.classes[name] != .thisMac {
        let before = Self.field(mine, name), after = Self.field(next, name)
        guard !Self.equal(before, after) else { continue }
        let listed = kind.listedValues.contains(name)
        state.changes.append(.init(record: entity, field: name, device: device, time: time,
          from: listed ? before.string : nil, to: listed ? after.string : nil))
      }
      if mine == nil { state.changes.append(.init(record: entity, field: CloudBrainMerge.existsField, device: device, time: time, from: nil, to: nil)) }
    }
    try saveState()
    return Shown(value: next)
  }
  public func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
    try live()
    await enter(); defer { leave() }
    try live()
    var records: [String: NativeRPCValue]
    do { records = try await owner.cloudRecords() }
    catch {
      // This Mac's saved list cannot be read now: each record waits (parked), the feed moves on.
      throw CloudRecordRefusal(operationIds: prepared.operations.map(\.opId), reason: "This Mac's saved list cannot be read right now; these records wait.")
    }
    try live()
    var results: [CloudItemResult] = [], written: [String] = []
    do {
      for op in prepared.operations {
        let parsed = try parse(op)
        let entity = op.entityId, table = parsed.kind.table
        if origins.belongsElsewhere(domain: domain, entity: entity, account: account.subjectHash) {
          throw CloudRecordRefusal(operationIds: [op.opId], reason: "A record with this id on this Mac came from another Cloud account; the two are kept apart.")
        }
        if let needs = parsed.kind.requires?(parsed.id), needs != entity, try store.graph(try recordKey(needs)).nodes.isEmpty {
          waitingFor.insert(needs)
          throw CloudRecordRefusal(operationIds: [op.opId], reason: "Waiting for a record this one needs, which has not arrived on this Mac yet.")
        }
        let mine = records[entity].map { Self.travelling($0, table: table) }
        let stored = try store.image(parsed.key).stored
        // An edit made here before this delivery stays concurrent with it, so it is captured first.
        if stored {
          if let mine, !(try await owner.cloudLocalOnly(entity: entity)) {
            if try capture(parsed.key, mine, table: table, restore: try await owner.cloudRestoring(entity: entity)) {
              try await owner.cloudCaptured(entity: entity, removed: false)
            }
          } else if let last = try store.image(parsed.key).value,
                  case .remove(let metadata) = try await owner.cloudMissing(entity: entity, last: last) {
            let enriched = try metadata.map { try capture(parsed.key, last.merging($0), table: table) } ?? true
            if enriched, try capture(parsed.key, nil, table: table) { try await owner.cloudCaptured(entity: entity, removed: true) }
          }
        }
        let revision = CloudBrainMergeRevision(node: .init(opId: op.opId, parents: op.parents, device: origin.deviceId, time: op.createdAt,
          baseline: parsed.version.baseline), version: parsed.version)
        do { try store.receive(parsed.key, [revision], table: table) }
        catch CloudBrainStoreError.tooFarAhead {
          throw CloudRecordRefusal(operationIds: [op.opId], reason: "This record is dated more than a day ahead of the Cloud's clock.")
        }
        // A copy this Mac had and never synced joins as a baseline (rule J): the Cloud's version wins and this Mac's
        // differing values are kept as other versions.
        if !stored, let mine { try capture(parsed.key, mine, table: table) }
        try origins.add(domain: domain, entity: entity, account: account.subjectHash)
        do {
          if let next = try await show(parsed.key, entity: entity, kind: parsed.kind, mine: mine, device: origin.deviceId, time: op.createdAt) {
            records[entity] = next.value; written.append(entity)
          }
        } catch let refusal as CloudRecordRefusal {
          throw CloudRecordRefusal(operationIds: [op.opId], reason: refusal.reason)
        }
        if waitingFor.remove(entity) != nil { retryWanted = true }
        results.append(.init(entityId: entity, status: .applied))
        try live()
      }
    } catch {
      if !written.isEmpty { await owner.cloudImported(written) }
      throw error
    }
    if !written.isEmpty, !state.waiting.isEmpty, let fresh = try? await owner.cloudRecords() {
      // A record that waited for one just written (an agent's instructions for their agent) is placed now.
      try live()
      try await reconsider(fresh)
    }
    if !written.isEmpty { await owner.cloudImported(written) }
    return .init(preparationId: prepared.preparationId, inventoryRow: inventoryRows[0], results: results,
      counts: .init(domains: 1, records: prepared.operations.count, files: 0, bytes: 0, blocked: 0))
  }
  public func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification { .init(verified: true, counts: receipt.counts, reasons: []) }

  // MARK: the read-only list

  public func listing() throws -> CloudBrainRecordListing {
    // Signed out: nothing of the account is listed (design v2 D9.3); nothing was deleted.
    guard !stopped else { return .init(keptCount: 0, kept: [], waiting: [], changes: [], gaps: gapList(), mentions: [], notes: []) }
    let device = account.deviceID
    let kept = try store.otherVersions(domain: domain, limit: 200).map { row -> CloudBrainRecordListing.Kept in
      let mine = row.conflict.device == device
      return .init(record: row.key.entity, field: row.conflict.field, device: row.conflict.device, time: row.conflict.time, mine: mine,
        preview: mine ? row.conflict.value.string.map { String($0.prefix(80)) } : nil)
    }
    var waiting: [CloudBrainRecordListing.Waiting] = []
    for (entity, reason) in state.waiting.sorted(by: { $0.key < $1.key }) { waiting.append(.init(record: entity, field: "", reason: reason)) }
    let held = try store.heldEntities(domain: domain)
    for entity in held.keys.sorted() {
      for name in (held[entity] ?? []).sorted() {
        waiting.append(.init(record: entity, field: name, reason: state.reasons[entity]?[name] ?? "A change from another device is waiting on this Mac."))
      }
    }
    let count = try store.otherVersionCount(domain: domain)
    let lines = state.notes ?? [:]
    return .init(keptCount: count, kept: kept, waiting: waiting, changes: state.changes, gaps: gapList(),
      mentions: lines.keys.sorted().compactMap { lines[$0] }, notes: exclusionList())
  }
}

/// The one enabling step for lane A2's rows of one signed-in account (lean first version). Lane A's wiring builds it
/// and calls `start`; nothing else registers these adapters. Order: adapters registered → on this Mac's first setup
/// for the account: join mode on, one pull (what the Cloud already holds arrives before this Mac's own copies are
/// cut), the setup with its own saved cut → join mode off → the capture loop. `stop()` is final.
public actor CloudBrainRecordActivation {
  /// `store`: which bookkeeping file the finished setup belongs to (its file number and creation time).
  private struct SavedCut: Codable { let cut: CloudSnapshotCut; var done: Bool; var store: String? }
  private let adapters: [CloudBrainRecordAdapter]
  private let store: CloudBrainAgentsStore
  private let cutFile: URL
  private let interval: Duration?
  private var registered = false, running = false, stopped = false
  private var loop: Task<Void, Never>?

  /// `every`: how often this Mac's records are looked at for changes while signed in; nil = only when `sync` is called.
  public init(adapters: [CloudBrainRecordAdapter], store: CloudBrainAgentsStore, every interval: Duration? = .seconds(10)) throws {
    guard !adapters.isEmpty, Set(adapters.map { $0.domain }).count == adapters.count else { throw CloudFailure.invalidRequest }
    self.adapters = adapters; self.store = store; self.interval = interval
    cutFile = store.file.deletingLastPathComponent().appendingPathComponent("a2-setup-cut.json")
  }
  private func checkLive() throws { if stopped { throw CancellationError() } }
  private func persist(_ saved: SavedCut) throws {
    try JSONEncoder().encode(saved).write(to: cutFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cutFile.path)
  }
  public var isRunning: Bool { running }
  /// The bookkeeping file as it is on disk now. A file that was lost or replaced has another mark.
  private func storeMark() -> String {
    let attributes = (try? FileManager.default.attributesOfItem(atPath: store.file.path)) ?? [:]
    let number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return String(number) + "-" + String(Int64(created * 1000))
  }

  public func start(outbox: any CloudOutboxPort) async throws {
    try checkLive()
    guard !running else { return }
    if !registered {
      for adapter in adapters { try await outbox.register(adapter: adapter); try checkLive() }
      registered = true
    }
    var saved: SavedCut?
    if let data = try? Data(contentsOf: cutFile) { saved = try JSONDecoder().decode(SavedCut.self, from: data) }
    // A setup was finished here, but with another bookkeeping file: this one was lost or replaced (design v2 D8).
    // That is a join again, with a new cut. It is never "everything on this Mac is new".
    if let finished = saved, finished.done, finished.store != storeMark() { saved = nil }
    if saved == nil {
      // First setup on this Mac for this account: copies this Mac already has join as baselines (rule J), and what
      // the Cloud already holds is taken in before they are cut. No answer from the Cloud changes nothing.
      try store.beginJoin()
      _ = try? await outbox.pull()
      try checkLive()
      let first = SavedCut(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: store.clock.read(), watermarks: [:]), done: false, store: nil)
      try persist(first); saved = first
    }
    if var unfinished = saved, !unfinished.done {
      // The same cut on every retry; each adapter answers with the page it saved for it.
      _ = try await outbox.bootstrap(sources: adapters, cut: unfinished.cut)
      try checkLive()
      for adapter in adapters { try await adapter.setupFinished() }
      try store.finishJoin()
      unfinished.done = true; unfinished.store = storeMark(); try persist(unfinished)
    }
    running = true
    if let interval, loop == nil {
      loop = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: interval)
          guard let self, !Task.isCancelled else { return }
          _ = try? await self.sync(outbox: outbox)
        }
      }
    }
  }
  /// One pass now: this Mac's changed records are captured and handed to the sync core. Returns how many versions went.
  @discardableResult
  public func sync(outbox: any CloudOutboxPort) async throws -> Int {
    guard running, !stopped else { return 0 }
    var handed = 0
    for adapter in adapters {
      try await adapter.captureLocal()
      handed += try await adapter.handOver(to: outbox)
      if await adapter.takeRetryWanted() { try? await outbox.retryParked(domains: [adapter.domain]) }
    }
    return handed
  }
  /// Sign-out or a closed gate: final for this object. Nothing is deleted; every capture stops.
  public func stop() async {
    stopped = true; running = false
    loop?.cancel(); loop = nil
    for adapter in adapters { await adapter.stop() }
  }
}
