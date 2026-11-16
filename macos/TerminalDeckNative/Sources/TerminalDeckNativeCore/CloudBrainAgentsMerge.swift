import Foundation

public enum CloudBrainMergeError: Error, Equatable, Sendable {
  /// A revision named by a head's history or a stamp is not held on this Mac: the record waits (slice-1a must-fix 6).
  case historyIncomplete([String])
  /// A payload from another device does not decode exactly (bad number, wrong shape): refused, never a crash (must-fix 7).
  case invalidPayload
}

/// When and by which revision a field (or a collection element) was last changed. The time is final when written:
/// the author's server-corrected clock, never earlier than a parent plus 1 ms (must-fix 5). Identical on every Mac.
public struct CloudBrainMergeStamp: Codable, Hashable, Sendable {
  public let time: Int64
  public let op: String
  public init(time: Int64, op: String) { self.time = time; self.op = op }
  var key: (Int64, String) { (time, op) }
}

public struct CloudBrainMergeElement: Sendable, Equatable {
  public let id: String
  public let value: NativeRPCValue
  public let stamp: CloudBrainMergeStamp
  public init(id: String, value: NativeRPCValue, stamp: CloudBrainMergeStamp) { self.id = id; self.value = value; self.stamp = stamp }
}

/// An other version of one field: the value of a losing revision. Identity is (field, revision), so the union over
/// heads is the same on every Mac (design v2 D1 step 6, C2).
public struct CloudBrainMergeConflict: Sendable, Hashable {
  public let field: String
  public let revision: String
  public let value: NativeRPCValue
  public let device: String
  public let time: Int64
  public init(field: String, revision: String, value: NativeRPCValue, device: String, time: Int64) {
    self.field = field; self.revision = revision; self.value = value; self.device = device; self.time = time
  }
  public static func == (a: Self, b: Self) -> Bool { a.field == b.field && a.revision == b.revision }
  public func hash(into hasher: inout Hasher) { hasher.combine(field); hasher.combine(revision) }
}

/// The payload of one revision: every travelling field with its last-changed stamp, collections by element id,
/// carried other versions. Names this app does not know are merged by where they sit and carried through untouched.
public struct CloudBrainMergeVersion: Sendable, Equatable {
  public var table: Int
  public var minTable: Int
  public var baseline: Bool
  public var fields: [String: NativeRPCValue]
  public var stamps: [String: CloudBrainMergeStamp]
  public var collections: [String: [String: CloudBrainMergeElement]]
  public var removed: [String: [String: CloudBrainMergeStamp]]
  public var conflicts: Set<CloudBrainMergeConflict>
  public init(table: Int, minTable: Int, baseline: Bool, fields: [String: NativeRPCValue] = [:], stamps: [String: CloudBrainMergeStamp] = [:],
              collections: [String: [String: CloudBrainMergeElement]] = [:], removed: [String: [String: CloudBrainMergeStamp]] = [:],
              conflicts: Set<CloudBrainMergeConflict> = []) {
    self.table = table; self.minTable = minTable; self.baseline = baseline; self.fields = fields; self.stamps = stamps
    self.collections = collections; self.removed = removed; self.conflicts = conflicts
  }
  public static func == (a: Self, b: Self) -> Bool { a.payload() == b.payload() }

  // MARK: payload (deterministic key order; the canonical encoder fixes the bytes)

  private static func stampValue(_ stamp: CloudBrainMergeStamp) -> NativeRPCValue { .array([.number(Double(stamp.time)), .string(stamp.op)]) }
  /// Exact integer or refusal (must-fix 7): never a trap on an out-of-range or non-finite number.
  static func exact(_ value: NativeRPCValue) throws -> Int64 {
    guard let number = value.number, let whole = Int64(exactly: number) else { throw CloudBrainMergeError.invalidPayload }
    return whole
  }
  private static func stamp(_ value: NativeRPCValue) throws -> CloudBrainMergeStamp {
    guard let pair = value.elements, pair.count == 2, let op = pair[1].string, !op.isEmpty else { throw CloudBrainMergeError.invalidPayload }
    return .init(time: try exact(pair[0]), op: op)
  }
  private static func sortedObject(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue {
    .object(pairs.sorted { $0.0 < $1.0 }.map { .init($0.0, $0.1) })
  }
  public func payload() -> NativeRPCValue {
    let collectionsValue = Self.sortedObject(collections.map { name, elements in
      (name, .array(elements.keys.sorted().map { id in
        let element = elements[id]!
        return Self.sortedObject([("id", .string(id)), ("value", element.value), ("stamp", Self.stampValue(element.stamp))])
      }))
    })
    let removedValue = Self.sortedObject(removed.map { name, ids in
      (name, .array(ids.keys.sorted().map { id in Self.sortedObject([("id", .string(id)), ("stamp", Self.stampValue(ids[id]!))]) }))
    })
    let conflictsValue = NativeRPCValue.array(conflicts.sorted { ($0.field, $0.revision) < ($1.field, $1.revision) }.map {
      Self.sortedObject([("field", .string($0.field)), ("revision", .string($0.revision)), ("value", $0.value),
        ("device", .string($0.device)), ("time", .number(Double($0.time)))])
    })
    return Self.sortedObject([("table", .number(Double(table))), ("minTable", .number(Double(minTable))), ("baseline", .bool(baseline)),
      ("fields", Self.sortedObject(fields.map { ($0.key, $0.value) })), ("stamps", Self.sortedObject(stamps.map { ($0.key, Self.stampValue($0.value)) })),
      ("collections", collectionsValue), ("removed", removedValue), ("conflicts", conflictsValue)])
  }
  public init(payload p: NativeRPCValue) throws {
    guard let baseline = p["baseline"].bool, let fields = p["fields"].fields, let stamps = p["stamps"].fields,
      let collections = p["collections"].fields, let removed = p["removed"].fields, let conflicts = p["conflicts"].elements else { throw CloudBrainMergeError.invalidPayload }
    let table = try Self.exact(p["table"]), minTable = try Self.exact(p["minTable"])
    guard (1...1_000_000).contains(table), (1...1_000_000).contains(minTable) else { throw CloudBrainMergeError.invalidPayload }
    self.table = Int(table); self.minTable = Int(minTable); self.baseline = baseline
    self.fields = Dictionary(fields.map { ($0.key, $0.value) }, uniquingKeysWith: { _, b in b })
    self.stamps = try Dictionary(stamps.map { ($0.key, try Self.stamp($0.value)) }, uniquingKeysWith: { _, b in b })
    guard Set(self.fields.keys) == Set(self.stamps.keys) else { throw CloudBrainMergeError.invalidPayload }
    var parsed: [String: [String: CloudBrainMergeElement]] = [:]
    for field in collections {
      var elements: [String: CloudBrainMergeElement] = [:]
      for row in field.value.elements ?? [] {
        guard let id = row["id"].string, !id.isEmpty, row.has("value") else { throw CloudBrainMergeError.invalidPayload }
        elements[id] = .init(id: id, value: row["value"], stamp: try Self.stamp(row["stamp"]))
      }
      parsed[field.key] = elements
    }
    self.collections = parsed
    var gone: [String: [String: CloudBrainMergeStamp]] = [:]
    for field in removed {
      var ids: [String: CloudBrainMergeStamp] = [:]
      for row in field.value.elements ?? [] {
        guard let id = row["id"].string, !id.isEmpty else { throw CloudBrainMergeError.invalidPayload }
        ids[id] = try Self.stamp(row["stamp"])
      }
      gone[field.key] = ids
    }
    self.removed = gone
    self.conflicts = Set(try conflicts.map { row in
      guard let field = row["field"].string, let revision = row["revision"].string, let device = row["device"].string, row.has("value") else {
        throw CloudBrainMergeError.invalidPayload
      }
      return CloudBrainMergeConflict(field: field, revision: revision, value: row["value"], device: device, time: try Self.exact(row["time"]))
    })
  }
  /// Every revision id this payload names: its stamps, element and removal stamps, carried other versions.
  var referenced: Set<String> {
    var ids = Set(stamps.values.map(\.op))
    for elements in collections.values { ids.formUnion(elements.values.map(\.stamp.op)) }
    for marks in removed.values { ids.formUnion(marks.values.map(\.op)) }
    ids.formUnion(conflicts.map(\.revision))
    return ids
  }
}

/// The small part of a revision, kept for every revision of a record (must-fix 8). Payloads are needed only for heads.
public struct CloudBrainMergeNode: Sendable, Equatable {
  public let opId: String
  public let parents: [String]
  public let device: String
  public let time: Int64
  public let baseline: Bool
  public init(opId: String, parents: [String], device: String, time: Int64, baseline: Bool) {
    self.opId = opId; self.parents = parents.sorted(); self.device = device; self.time = time; self.baseline = baseline
  }
}

/// A whole revision as written or received: the node plus its payload.
public struct CloudBrainMergeRevision: Sendable, Equatable {
  public let node: CloudBrainMergeNode
  public let version: CloudBrainMergeVersion
  public init(node: CloudBrainMergeNode, version: CloudBrainMergeVersion) { self.node = node; self.version = version }
  public var opId: String { node.opId }
  public var parents: [String] { node.parents }
  public var time: Int64 { node.time }
}

/// The nodes of one record known on this Mac. Every function is independent of insertion order.
public struct CloudBrainMergeGraph: Sendable {
  public private(set) var nodes: [String: CloudBrainMergeNode] = [:]
  public init(_ nodes: [CloudBrainMergeNode] = []) { for node in nodes { add(node) } }
  public mutating func add(_ node: CloudBrainMergeNode) { if nodes[node.opId] == nil { nodes[node.opId] = node } }
  public var heads: [String] {
    let parents = Set(nodes.values.flatMap(\.parents))
    return nodes.keys.filter { !parents.contains($0) }.sorted()
  }
  /// Revision ids on the history of `heads` that are not held here.
  public func missing(from heads: [String]) -> [String] {
    var queue = heads, seen = Set<String>(), missing = Set<String>(), index = 0
    while index < queue.count {
      let id = queue[index]; index += 1
      guard seen.insert(id).inserted else { continue }
      guard let node = nodes[id] else { missing.insert(id); continue }
      queue += node.parents
    }
    return missing.sorted()
  }
  /// True when `ancestor` is a strict ancestor of `descendant` (the view first checks the history is complete).
  public func isAncestor(_ ancestor: String, of descendant: String) -> Bool {
    guard ancestor != descendant else { return false }
    var queue = nodes[descendant]?.parents ?? [], seen = Set<String>(), index = 0
    while index < queue.count {
      let id = queue[index]; index += 1
      if id == ancestor { return true }
      guard seen.insert(id).inserted else { continue }
      queue += nodes[id]?.parents ?? []
    }
    return false
  }
  func seen(_ ancestor: String, by descendant: String) -> Bool { ancestor == descendant || isAncestor(ancestor, of: descendant) }
  public func isBaseline(_ op: String) -> Bool { nodes[op]?.baseline ?? false }
}

/// This Mac's clock corrected by the offset the sync core learned from the service's answers (server minus local).
/// Injected so tests drive it; until the sync core exposes the offset, composition passes 0.
public struct CloudBrainMergeClock: Sendable {
  public let read: @Sendable () -> Int64
  public init(read: @escaping @Sendable () -> Int64) { self.read = read }
  public static func corrected(offset: Int64, local: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) -> Self {
    .init { local() + offset }
  }
  /// The sync core's service clock (`CloudOutboxPort.serviceTime()`, contract 9f5aa3d2 on lane/cloud-sync): this Mac's
  /// clock plus the offset learned from authenticated commit receipts; nil until any commit was answered, then this
  /// Mac's own clock is used. Composition passes `{ engine.serviceTime() }`.
  public static func service(_ serviceTime: @escaping @Sendable () -> Int64?,
                             local: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) -> Self {
    .init { serviceTime() ?? local() }
  }
}

/// The shown record: a pure function of the head payloads and the graph (ruling a).
public struct CloudBrainMergeView: Sendable, Equatable {
  public let heads: [String]
  public let fields: [String: NativeRPCValue]
  public let stamps: [String: CloudBrainMergeStamp]
  public let collections: [String: [CloudBrainMergeElement]]
  public let removed: [String: [String: CloudBrainMergeStamp]]
  public let conflicts: [CloudBrainMergeConflict]
  public let minTable: Int
  public var exists: Bool { fields[CloudBrainMerge.existsField]?.bool ?? true }
  public static func == (a: Self, b: Self) -> Bool {
    a.heads == b.heads && a.stamps == b.stamps && a.removed == b.removed && a.minTable == b.minTable &&
      a.conflicts.map { [$0.field, $0.revision] } == b.conflicts.map { [$0.field, $0.revision] } && a.shown() == b.shown()
  }
  /// The record as an object: travelling fields (not `$exists`) and each collection as an ordered array of element values.
  public func shown() -> NativeRPCValue {
    var pairs = fields.filter { $0.key != CloudBrainMerge.existsField }.map { NativeRPCValue.Field($0.key, $0.value) }
    for (name, elements) in collections { pairs.append(.init(name, .array(elements.map(\.value)))) }
    return .object(pairs.sorted { $0.key < $1.key })
  }
}

public enum CloudBrainMerge {
  public static let existsField = "$exists"

  static func same(_ a: NativeRPCValue, _ b: NativeRPCValue) -> Bool { CloudValue(a) == CloudValue(b) }
  /// Element identity: its own `id`, otherwise `h:` + sha256 of its canonical bytes (C4).
  public static func elementID(_ element: NativeRPCValue) -> String {
    if let id = element["id"].string, !id.isEmpty { return id }
    return "h:" + CloudSyncBytes.hash((try? CloudSyncCanonical.encode(CloudValue(element))) ?? Data(element.compact.utf8))
  }
  /// Element order: its own `at` time when it is an exact integer, else its stamp time, then id (C4, must-fix 7).
  static func orderKey(_ value: NativeRPCValue, id: String, stamp: CloudBrainMergeStamp) -> (Int64, String) {
    (value["at"].number.flatMap { Int64(exactly: $0.rounded(.down)) } ?? stamp.time, id)
  }
  static func elementOrder(_ a: CloudBrainMergeElement, _ b: CloudBrainMergeElement) -> Bool {
    orderKey(a.value, id: a.id, stamp: a.stamp) < orderKey(b.value, id: b.id, stamp: b.stamp)
  }

  private struct Candidate { let value: NativeRPCValue; let stamp: CloudBrainMergeStamp; let head: String }
  /// Which value a field prefers among concurrent candidates, after rule J (Ruling 3 changes 4 and 5).
  private enum Preference { case none, truth, smallestPositive }
  private static func preference(_ name: String, table: CloudBrainMergeTable) -> Preference {
    if name == existsField { return .truth }
    switch table.fieldClass(name) {
    case .raise?: return .truth
    case .shrink?: return .smallestPositive
    default: return .none
    }
  }

  /// The n-way rule for one field: drop candidates whose stamping revision another candidate's had seen; then rule J
  /// (a baseline loses to any ordinary stamp) BEFORE "an edit beats a removal" (must-fix 3); among ordinary stamps the
  /// newest wins, among baselines the oldest.
  private static func pick(_ candidates: [Candidate], graph: CloudBrainMergeGraph, prefer: Preference = .none) -> (winner: Candidate, losers: [Candidate])? {
    var byOp: [String: Candidate] = [:]
    for candidate in candidates.sorted(by: { $0.head < $1.head }) where byOp[candidate.stamp.op] == nil { byOp[candidate.stamp.op] = candidate }
    let all = byOp.values.sorted { $0.stamp.op < $1.stamp.op }
    let undominated = all.filter { c in !all.contains { d in d.stamp.op != c.stamp.op && graph.isAncestor(c.stamp.op, of: d.stamp.op) } }
    let ordinary = undominated.filter { !graph.isBaseline($0.stamp.op) }
    var pool = ordinary.isEmpty ? undominated : ordinary
    var preferred: Candidate?
    switch prefer {
    case .truth:
      let trues = pool.filter { $0.value.bool == true }; if !trues.isEmpty { pool = trues }
    case .smallestPositive:
      // A limit only gets smaller: among concurrent values the smallest positive one wins (0 or none means no limit).
      preferred = pool.filter { ($0.value.number ?? 0) > 0 }.min { ($0.value.number!, $0.stamp.op) < ($1.value.number!, $1.stamp.op) }
    case .none:
      break
    }
    guard let winner = preferred ?? (ordinary.isEmpty ? pool.min(by: { $0.stamp.key < $1.stamp.key }) : pool.max(by: { $0.stamp.key < $1.stamp.key })) else { return nil }
    let losers = undominated.filter { $0.stamp.op != winner.stamp.op && !same($0.value, winner.value) }
    return (winner, losers)
  }

  /// The view over a head set. `payloads` needs only the heads. Throws `historyIncomplete` when a head, a parent on
  /// the history or a revision a stamp names is not held (must-fix 6), so the record waits instead of differing.
  public static func view(_ heads: [String], payloads: [String: CloudBrainMergeVersion], graph: CloudBrainMergeGraph,
                          table: CloudBrainMergeTable) throws -> CloudBrainMergeView {
    let ids = Array(Set(heads)).sorted()
    var missing = Set(graph.missing(from: ids))
    let versions = ids.compactMap { id -> (String, CloudBrainMergeVersion)? in
      guard let version = payloads[id] else { missing.insert(id); return nil }
      return (id, version)
    }
    for (_, version) in versions { missing.formUnion(version.referenced.filter { graph.nodes[$0] == nil }) }
    guard missing.isEmpty else { throw CloudBrainMergeError.historyIncomplete(missing.sorted()) }

    var fields: [String: NativeRPCValue] = [:], stamps: [String: CloudBrainMergeStamp] = [:], found: [CloudBrainMergeConflict] = []
    let names = Set(versions.flatMap { $0.1.fields.keys })
    var follows: [(String, CloudBrainMergeFollow)] = []
    for name in names.sorted() {
      if case .follows(let rule) = table.fieldClass(name) { follows.append((name, rule)); continue }
      let candidates: [Candidate] = versions.compactMap { pair in
        pair.1.stamps[name].map { Candidate(value: pair.1.fields[name] ?? .null, stamp: $0, head: pair.0) }
      }
      guard let result = pick(candidates, graph: graph, prefer: preference(name, table: table)) else { continue }
      fields[name] = result.winner.value; stamps[name] = result.winner.stamp
      for loser in result.losers {
        found.append(.init(field: name, revision: loser.stamp.op, value: loser.value, device: graph.nodes[loser.stamp.op]?.device ?? "", time: loser.stamp.time))
      }
    }
    for (name, rule) in follows {
      let holders = versions.filter { $0.1.stamps[name] != nil }
      func newestStamp(_ list: [(String, CloudBrainMergeVersion)]) -> (String, CloudBrainMergeVersion)? {
        list.max { ($0.1.stamps[name]!.key) < ($1.1.stamps[name]!.key) }
      }
      let chosen: (String, CloudBrainMergeVersion)?
      switch rule {
      case .newest, .touched:
        chosen = holders.filter { $0.1.fields[name]?.number != nil }.max { ($0.1.fields[name]!.number!, $0.0) < ($1.1.fields[name]!.number!, $1.0) }
      case .oldest:
        chosen = holders.filter { $0.1.fields[name]?.number != nil }.min { ($0.1.fields[name]!.number!, $0.0) < ($1.1.fields[name]!.number!, $1.0) }
      case .partner(let partner):
        // Among the heads holding the partner's shown stamp, the newest own stamp wins (must-fix 4).
        let agreeing = stamps[partner].map { winner in holders.filter { $0.1.stamps[partner] == winner } } ?? holders
        chosen = newestStamp(agreeing.isEmpty ? holders : agreeing)
      }
      // Last fallback (decision 6): nothing to compare, the lowest head id.
      if let chosen = chosen ?? holders.min(by: { $0.0 < $1.0 }) {
        fields[name] = chosen.1.fields[name] ?? .null; stamps[name] = chosen.1.stamps[name]
      }
    }
    // Collections: union by element id minus removals that had seen the element's last change; the shared cap keeps the newest N.
    var collections: [String: [CloudBrainMergeElement]] = [:], removed: [String: [String: CloudBrainMergeStamp]] = [:]
    let collectionNames = Set(versions.flatMap { Array($0.1.collections.keys) + Array($0.1.removed.keys) })
    for name in collectionNames.sorted() {
      let elementIDs = Set(versions.flatMap { Array(($0.1.collections[name] ?? [:]).keys) + Array(($0.1.removed[name] ?? [:]).keys) })
      var kept: [CloudBrainMergeElement] = [], gone: [String: CloudBrainMergeStamp] = [:]
      for id in elementIDs.sorted() {
        let candidates: [Candidate] = versions.compactMap { pair in
          pair.1.collections[name]?[id].map { Candidate(value: $0.value, stamp: $0.stamp, head: pair.0) }
        }
        let removals = Array(Set(versions.compactMap { $0.1.removed[name]?[id] })).sorted { $0.key < $1.key }
        let live = candidates.filter { candidate in !removals.contains { graph.seen(candidate.stamp.op, by: $0.op) } }
        if let result = pick(live, graph: graph) { kept.append(.init(id: id, value: result.winner.value, stamp: result.winner.stamp)) }
        else if let removal = removals.last { gone[id] = removal }
      }
      kept.sort(by: elementOrder)
      if case .collection(let limit)? = table.fieldClass(name), let cap = limit, kept.count > cap { kept = Array(kept.suffix(cap)) }
      collections[name] = kept
      if !gone.isEmpty { removed[name] = gone }
    }
    // Other versions. An entry clears when the shown value equals it, or when the revision that set the shown value had
    // seen it AND no head holding that winning stamp still carries it (a re-mark is not an edit; must-fix 2, C2).
    var conflicts = Set<CloudBrainMergeConflict>()
    for entry in versions.flatMap({ $0.1.conflicts }) + found {
      guard let winner = stamps[entry.field] else { continue }
      if let shown = fields[entry.field], same(shown, entry.value) { continue }
      if graph.seen(entry.revision, by: winner.op) {
        let stillCarried = versions.contains { $0.1.stamps[entry.field] == winner && $0.1.conflicts.contains(entry) }
        if !stillCarried { continue }
      }
      conflicts.insert(entry)
    }
    return .init(heads: ids, fields: fields, stamps: stamps, collections: collections, removed: removed,
      conflicts: conflicts.sorted { ($0.field, $0.revision) < ($1.field, $1.revision) },
      minTable: versions.map { $0.1.minTable }.max() ?? 1)
  }

  /// Owner-side rule for a value arriving from another device (Ruling 3 changes 4 and 5): may the store take `after`
  /// in place of `before`? `.raise` never turns off; `.shrink` takes only a positive value no larger than the current
  /// limit (none or 0 means no limit, so any positive value narrows it). Everything else is decided elsewhere (true).
  public static func mayApply(_ kind: CloudBrainMergeClass?, before: NativeRPCValue?, after: NativeRPCValue?) -> Bool {
    let old = before ?? .missing, new = after ?? .missing
    if same(old, new) { return true }
    switch kind {
    case .raise?:
      return new.bool == true
    case .shrink?:
      guard let value = new.number, value > 0 else { return false }
      guard let limit = old.number, limit > 0 else { return true }
      return value <= limit
    default:
      return true
    }
  }

  /// A new revision over `view`, deciding "changed here" against `image`, what this Mac last STORED for those heads
  /// (must-fix 1). `local` nil = removed here. `held` fields are sent with the view's value and stamp (C3). `chosen`
  /// fields are a deliberate pick ("use this one"): stamped now even when the value equals the image. `restore` is an
  /// explicit undo of a removal; without it a leftover of a removed record never makes a revision. Returns nil when
  /// nothing deliberate changed (a change to touched follows fields alone is no revision).
  public static func revision(over view: CloudBrainMergeView?, image: NativeRPCValue?, local: NativeRPCValue?, held: Set<String> = [],
                              chosen: Set<String> = [], restore: Bool = false, table: CloudBrainMergeTable, opId: String, device: String,
                              clock: CloudBrainMergeClock, baseline: Bool, graph: CloudBrainMergeGraph) -> CloudBrainMergeRevision? {
    let parents = baseline ? [] : (view?.heads ?? [])
    // Never earlier than a parent plus 1 ms, saturating: a version from elsewhere dated Int64.max cannot overflow this
    // (review round 2, B). Slice 1b refuses versions dated absurdly far ahead before they reach the merge.
    let newestParent = parents.compactMap { graph.nodes[$0]?.time }.max() ?? Int64.min
    let time = max(clock.read(), newestParent == Int64.max ? Int64.max : max(newestParent, Int64.min + 1) + 1)
    let stamp = CloudBrainMergeStamp(time: time, op: opId)
    var fields = view?.fields ?? [:], stamps = view?.stamps ?? [:]
    var collections = (view?.collections ?? [:]).mapValues { Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) }) }
    var removed = view?.removed ?? [:]
    var edited: Set<String> = []
    func set(_ name: String, _ value: NativeRPCValue, force: Bool = false) {
      if !force, let old = fields[name], same(old, value) { return }
      fields[name] = value; stamps[name] = stamp; edited.insert(name)
    }
    func finish() -> CloudBrainMergeRevision? {
      let touched = Set(table.classes.compactMap { $0.value == .follows(.touched) ? $0.key : nil })
      guard !edited.subtracting(touched).isEmpty else { return nil }
      // Every edit re-marks that the record exists (decision 1); the re-mark is not an edit of `$exists`.
      if !edited.contains(existsField) { fields[existsField] = .bool(true); stamps[existsField] = stamp }
      // Entries for fields deliberately set here are cleared (this revision saw them); a re-mark keeps them.
      let conflicts = Set((view?.conflicts ?? []).filter { !edited.contains($0.field) && !chosen.contains($0.field) })
      let introduced = edited.map { table.introduced[$0] ?? 1 }.max() ?? 1
      let version = CloudBrainMergeVersion(table: table.version, minTable: max(view?.minTable ?? 1, introduced), baseline: baseline,
        fields: fields, stamps: stamps, collections: collections, removed: removed, conflicts: conflicts)
      return .init(node: .init(opId: opId, parents: parents, device: device, time: time, baseline: baseline), version: version)
    }
    guard let local else {
      // Removed here: only a record this Mac held and the view still shows.
      guard image != nil, let view, view.exists else { return nil }
      set(existsField, .bool(false))
      return finish()
    }
    if let view, !view.exists {
      // A leftover (Trash, archived) of a record removed in the Cloud changes nothing unless the person restores it;
      // a joining Mac's own copy is captured as its baseline and listed (must-fix 3).
      guard restore || baseline else { return nil }
      set(existsField, .bool(true))
    } else if view == nil {
      set(existsField, .bool(true))
    }
    for name in chosen where !held.contains(name) {
      if name == existsField { set(existsField, .bool(true), force: true) }
      // Choosing "empty" is a real choice (review round 2, C): a field absent here is chosen as cleared.
      else { set(name, local.has(name) ? local[name] : .null, force: true) }
    }
    for (name, kind) in table.classes.sorted(by: { $0.key < $1.key }) where !held.contains(name) && !chosen.contains(name) {
      switch kind {
      case .thisMac:
        continue
      case .identity:
        if fields[name] == nil, local.has(name) { set(name, local[name]) }
      case .collection(let cap):
        guard local.has(name) else { continue }
        var current = collections[name] ?? [:]
        var mine: [String: NativeRPCValue] = [:]
        for element in local[name].elements ?? [] { mine[elementID(element)] = element }
        var stored: [String: NativeRPCValue]? = nil
        if let image, image.has(name) {
          var values: [String: NativeRPCValue] = [:]
          for element in image[name].elements ?? [] { values[elementID(element)] = element }
          stored = values
        }
        var touchedCollection = false
        for (id, element) in mine {
          // Changed here only against what this Mac stored; without an image, anything the view lacks or differs on.
          if let stored, let before = stored[id], same(before, element) { continue }
          if let existing = current[id], same(existing.value, element) { continue }
          current[id] = .init(id: id, value: element, stamp: stamp); removed[name]?[id] = nil; touchedCollection = true
        }
        if let stored {
          // Removed here: stored before, missing now, and among the newest `cap` of (stored ∪ mine); else the cap dropped it.
          var union = stored; for (id, value) in mine { union[id] = value }
          let newest: Set<String>? = cap.map { limit in
            Set(union.map { id, value in (orderKey(value, id: id, stamp: current[id]?.stamp ?? stamp), id) }.sorted { $0.0 < $1.0 }.suffix(limit).map { $0.1 })
          }
          for id in stored.keys.sorted() where mine[id] == nil && current[id] != nil {
            if let newest, !newest.contains(id) { continue }
            current[id] = nil; removed[name, default: [:]][id] = stamp; touchedCollection = true
          }
        }
        guard touchedCollection else { continue }
        if let cap {
          // The shared set keeps the newest `cap` elements and the newest `cap` removal marks; dropping is never a removal.
          let ordered = current.values.sorted(by: elementOrder)
          if ordered.count > cap { for element in ordered.prefix(ordered.count - cap) { current[element.id] = nil } }
          if let marks = removed[name], marks.count > cap {
            removed[name] = Dictionary(uniqueKeysWithValues: marks.sorted { $0.value.key < $1.value.key }.suffix(cap).map { ($0.key, $0.value) })
          }
        }
        collections[name] = current; edited.insert(name)
      default:
        if local.has(name) {
          // Unchanged here when it equals what this Mac stored, whatever the view says now (must-fix 1).
          if let image, image.has(name), same(image[name], local[name]) { continue }
          set(name, local[name])
        } else if let image, image.has(name), !image[name].isNullish {
          // Cleared here only when this Mac had stored a value; a store that never had the field says nothing.
          set(name, .null)
        }
      }
    }
    return finish()
  }
}
