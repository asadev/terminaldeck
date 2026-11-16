import Foundation
import SQLite3

/// One record of an owner store, as A2's bookkeeping names it.
public struct CloudBrainRecordKey: Hashable, Sendable {
  public let domain: String
  public let entity: String
  public init(domain: String, entity: String) throws {
    guard domain.utf8.count <= 128, domain.range(of: #"\A[a-z0-9][a-z0-9/_-]*\z"#, options: .regularExpression) != nil,
          !entity.isEmpty, entity.utf8.count <= 256, !entity.contains("\0") else { throw CloudFailure.invalidRequest }
    self.domain = domain; self.entity = entity
  }
}

public enum CloudBrainStoreError: Error, Equatable, Sendable {
  /// A version dated more than a day ahead of this Mac's service clock: a payload fault the sync core parks.
  case tooFarAhead(String)
  case unsafeLocation
  case unavailable(String)
}

/// One listed other version, read in bounded pages for Settings → Cloud.
public struct CloudBrainOtherVersionRow: Sendable, Equatable {
  public let key: CloudBrainRecordKey
  public let conflict: CloudBrainMergeConflict
}

/// Slice 1b: A2's per-account bookkeeping database (design v2 D8, revision 5). Exactly four tables:
/// `node` (every version, small), `payload` (contents of the current heads and of this Mac's own versions not yet
/// handed to the sync core), `record` (the image this Mac last stored, the heads it reflects, the crash intent, the hold
/// set), `other_version` (listed other versions, for bounded reads). Everything is read per record; nothing is held whole.
public final class CloudBrainAgentsStore: @unchecked Sendable {
  public enum Opening: Sendable, Equatable { case existing, fresh, replacedDamaged(URL) }
  public struct LoadStats: Sendable, Equatable {
    public var nodes = 0, nodeBytes = 0, payloads = 0, payloadBytes = 0
  }
  /// Review round 2, B: a version dated more than this far ahead of this Mac's service clock is refused.
  public static let maximumAhead: Int64 = 86_400_000
  static let schema: Int32 = 1, joiningSchema: Int32 = 2

  public let opening: Opening
  public let clock: CloudBrainMergeClock
  public let file: URL
  private var db: OpaquePointer?
  private let lock = NSLock()
  private let fault: (@Sendable (String) throws -> Void)?
  private var stats = LoadStats()
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  /// `directory` must be this account's folder (`<data>/cloud/<subjectHash>/…`), never a provider home or memory.db.
  /// A file that does not open or fails `integrity_check` is moved aside and a fresh database is opened in join mode.
  public init(directory: URL, account: CloudBrainAgentsAccount, clock: CloudBrainMergeClock,
              fault: (@Sendable (String) throws -> Void)? = nil) throws {
    let folder = directory.standardizedFileURL
    let path = folder.path
    guard path.contains("/cloud/" + account.subjectHash),
          !["/.claude/", "/.codex/", "/.gemini/", "/account-logins/"].contains(where: { path.contains($0) }) else { throw CloudBrainStoreError.unsafeLocation }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    file = folder.appendingPathComponent("a2.sqlite")
    self.clock = clock; self.fault = fault
    let existed = FileManager.default.fileExists(atPath: file.path)
    var opening: Opening = existed ? .existing : .fresh
    if existed, !Self.healthy(file) {
      let aside = folder.appendingPathComponent("a2.sqlite.damaged-\(Int64(Date().timeIntervalSince1970 * 1000))")
      for suffix in ["", "-wal", "-shm"] where FileManager.default.fileExists(atPath: file.path + suffix) {
        try FileManager.default.moveItem(atPath: file.path + suffix, toPath: aside.path + suffix)
      }
      opening = .replacedDamaged(aside)
    }
    self.opening = opening
    // Created 0600 before SQLite opens it, so its -wal and -shm files take the same mode.
    if !FileManager.default.fileExists(atPath: file.path) {
      guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
        throw CloudBrainStoreError.unavailable("The Cloud bookkeeping file could not be created.")
      }
    }
    db = try Self.open(file)
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA synchronous=FULL")
    try execute("""
      CREATE TABLE IF NOT EXISTS node(op_id TEXT PRIMARY KEY, domain TEXT NOT NULL, entity TEXT NOT NULL, parents TEXT NOT NULL,
        device TEXT NOT NULL, time INTEGER NOT NULL, baseline INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS node_record ON node(domain, entity);
      CREATE TABLE IF NOT EXISTS payload(op_id TEXT PRIMARY KEY, domain TEXT NOT NULL, entity TEXT NOT NULL, version BLOB NOT NULL,
        head INTEGER NOT NULL, unhanded INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS payload_record ON payload(domain, entity);
      CREATE TABLE IF NOT EXISTS record(domain TEXT NOT NULL, entity TEXT NOT NULL, heads TEXT NOT NULL, stored INTEGER NOT NULL,
        image BLOB, intent_heads TEXT, intent_image BLOB, intent_hash TEXT, held TEXT NOT NULL, PRIMARY KEY(domain, entity));
      CREATE TABLE IF NOT EXISTS other_version(domain TEXT NOT NULL, entity TEXT NOT NULL, field TEXT NOT NULL, revision TEXT NOT NULL,
        value BLOB NOT NULL, device TEXT NOT NULL, time INTEGER NOT NULL, PRIMARY KEY(domain, entity, field, revision));
      """)
    // A fresh database is not yet joining (the caller knows whether the Cloud already holds this account's records);
    // a damaged one replaced here is a lost database, which is a join (design v2 D8, rule J).
    if case .replacedDamaged = opening { try setUserVersion(Self.joiningSchema) }
    else if try userVersion() == 0 { try setUserVersion(Self.schema) }
  }
  deinit { if let db { sqlite3_close(db) } }

  private static func open(_ file: URL) throws -> OpaquePointer {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
          let handle else {
      if let handle { sqlite3_close(handle) }
      throw CloudBrainStoreError.unavailable("The Cloud bookkeeping file could not be opened.")
    }
    sqlite3_busy_timeout(handle, 5_000)
    return handle
  }
  private static func healthy(_ file: URL) -> Bool {
    var handle: OpaquePointer?
    // Read-write without create: a WAL left by a crash is recovered here instead of being taken for damage.
    guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let handle else {
      if let handle { sqlite3_close(handle) }
      return false
    }
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 5_000)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "PRAGMA integrity_check", -1, &statement, nil) == SQLITE_OK, let statement else { return false }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
    return String(cString: text) == "ok"
  }

  // MARK: SQL

  enum Value { case text(String), int(Int64), blob(Data), null }
  private func execute(_ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CloudBrainStoreError.unavailable(String(cString: sqlite3_errmsg(db))) }
  }
  @discardableResult
  private func run(_ sql: String, _ args: [Value] = []) throws -> [[Value]] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw CloudBrainStoreError.unavailable(String(cString: sqlite3_errmsg(db)))
    }
    defer { sqlite3_finalize(statement) }
    for (offset, arg) in args.enumerated() {
      let index = Int32(offset + 1), result: Int32
      switch arg {
      case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
      case .int(let number): result = sqlite3_bind_int64(statement, index, number)
      case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
      case .null: result = sqlite3_bind_null(statement, index)
      }
      guard result == SQLITE_OK else { throw CloudBrainStoreError.unavailable("bind") }
    }
    var rows: [[Value]] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw CloudBrainStoreError.unavailable(String(cString: sqlite3_errmsg(db))) }
      rows.append((0..<sqlite3_column_count(statement)).map { (column: Int32) -> Value in
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
        case SQLITE_TEXT: return .text(sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "")
        case SQLITE_BLOB:
          let count = Int(sqlite3_column_bytes(statement, column))
          guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
          return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
      })
    }
    return rows
  }
  /// One transaction per change; a fault (tests) or any error rolls the whole change back.
  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do { let value = try body(); try execute("COMMIT"); return value }
    catch { try? execute("ROLLBACK"); throw error }
  }
  private func step(_ name: String) throws { try fault?(name) }
  private func userVersion() throws -> Int32 {
    guard case .int(let value)? = try run("PRAGMA user_version").first?.first else { return 0 }
    return Int32(value)
  }
  private func setUserVersion(_ value: Int32) throws { try execute("PRAGMA user_version=\(value)") }
  private static func text(_ value: Value?) -> String? { if case .text(let text)? = value { return text }; return nil }
  private static func int(_ value: Value?) -> Int64? { if case .int(let number)? = value { return number }; return nil }
  private static func blob(_ value: Value?) -> Data? { if case .blob(let data)? = value { return data }; return nil }
  private static func json(_ strings: [String]) -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
    return (try? String(decoding: encoder.encode(strings.sorted()), as: UTF8.self)) ?? "[]"
  }
  private static func strings(_ text: String?) -> [String] { text.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? [] }
  private static func encode(_ value: NativeRPCValue) throws -> Data { try value.encodedJSON() }
  private static func decode(_ data: Data) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(data) }
  static func hash(_ value: NativeRPCValue?) throws -> String {
    guard let value else { return "absent" }
    return CloudSyncBytes.hash(try CloudSyncCanonical.encode(CloudValue(value)))
  }

  // MARK: join mode (rule J)

  /// True while captures without a stored image count as baseline even before the Cloud's heads arrive: a first
  /// sign-in on a Mac whose Cloud already holds records, or a lost or damaged database (design v2 D8).
  public var joining: Bool { lock.withLock { (try? userVersion()) == Self.joiningSchema } }
  public func beginJoin() throws { try lock.withLock { try setUserVersion(Self.joiningSchema) } }
  public func finishJoin() throws { try lock.withLock { try setUserVersion(Self.schema) } }

  // MARK: reads (per record, bounded)

  public var lastLoad: LoadStats { lock.withLock { stats } }
  private func loadGraph(_ key: CloudBrainRecordKey) throws -> CloudBrainMergeGraph {
    let rows = try run("SELECT op_id, parents, device, time, baseline FROM node WHERE domain=? AND entity=?", [.text(key.domain), .text(key.entity)])
    var graph = CloudBrainMergeGraph(), bytes = 0
    for row in rows {
      guard let op = Self.text(row[0]), let parents = Self.text(row[1]), let device = Self.text(row[2]), let time = Self.int(row[3]),
            let baseline = Self.int(row[4]) else { throw CloudBrainStoreError.unavailable("node") }
      bytes += op.utf8.count + parents.utf8.count + device.utf8.count + 16
      graph.add(.init(opId: op, parents: Self.strings(parents), device: device, time: time, baseline: baseline != 0))
    }
    stats.nodes = rows.count; stats.nodeBytes = bytes
    return graph
  }
  private func loadHeadPayloads(_ key: CloudBrainRecordKey) throws -> [String: CloudBrainMergeVersion] {
    let rows = try run("SELECT op_id, version FROM payload WHERE domain=? AND entity=? AND head=1", [.text(key.domain), .text(key.entity)])
    var result: [String: CloudBrainMergeVersion] = [:], bytes = 0
    for row in rows {
      guard let op = Self.text(row[0]), let data = Self.blob(row[1]) else { throw CloudBrainStoreError.unavailable("payload") }
      bytes += data.count
      result[op] = try CloudBrainMergeVersion(payload: try Self.decode(data))
    }
    stats.payloads = rows.count; stats.payloadBytes = bytes
    return result
  }
  private func loadView(_ key: CloudBrainRecordKey, table: CloudBrainMergeTable) throws -> (CloudBrainMergeGraph, CloudBrainMergeView?) {
    let graph = try loadGraph(key)
    let heads = graph.heads
    guard !heads.isEmpty else { return (graph, nil) }
    // A head without its payload (a settled record whose content this Mac never kept) makes the view report
    // "history incomplete": the record waits until the account's records are pulled again (design v2 D8).
    return (graph, try CloudBrainMerge.view(heads, payloads: try loadHeadPayloads(key), graph: graph, table: table))
  }
  public func graph(_ key: CloudBrainRecordKey) throws -> CloudBrainMergeGraph { try lock.withLock { try loadGraph(key) } }
  public func view(_ key: CloudBrainRecordKey, table: CloudBrainMergeTable) throws -> CloudBrainMergeView? {
    try lock.withLock { try loadView(key, table: table).1 }
  }
  private struct Row { var heads: [String]; var stored: Bool; var image: NativeRPCValue?; var intentHeads: [String]?; var intentImage: NativeRPCValue?; var intentHash: String?; var held: Set<String> }
  private func loadRow(_ key: CloudBrainRecordKey) throws -> Row? {
    guard let row = try run("SELECT heads, stored, image, intent_heads, intent_image, intent_hash, held FROM record WHERE domain=? AND entity=?",
      [.text(key.domain), .text(key.entity)]).first else { return nil }
    return .init(heads: Self.strings(Self.text(row[0])), stored: Self.int(row[1]) == 1, image: try Self.blob(row[2]).map(Self.decode),
      intentHeads: Self.text(row[3]).map { Self.strings($0) }, intentImage: try Self.blob(row[4]).map(Self.decode),
      intentHash: Self.text(row[5]), held: Set(Self.strings(Self.text(row[6]))))
  }
  private func saveRow(_ key: CloudBrainRecordKey, _ row: Row) throws {
    try run("""
      INSERT INTO record(domain, entity, heads, stored, image, intent_heads, intent_image, intent_hash, held) VALUES (?,?,?,?,?,?,?,?,?)
      ON CONFLICT(domain, entity) DO UPDATE SET heads=excluded.heads, stored=excluded.stored, image=excluded.image,
        intent_heads=excluded.intent_heads, intent_image=excluded.intent_image, intent_hash=excluded.intent_hash, held=excluded.held
      """, [.text(key.domain), .text(key.entity), .text(Self.json(row.heads)), .int(row.stored ? 1 : 0),
        try row.image.map { Value.blob(try Self.encode($0)) } ?? Value.null, row.intentHeads.map { Value.text(Self.json($0)) } ?? Value.null,
        try row.intentImage.map { Value.blob(try Self.encode($0)) } ?? Value.null, row.intentHash.map { Value.text($0) } ?? Value.null,
        .text(Self.json(Array(row.held)))])
  }
  /// What this Mac last stored for the record (`stored` false: never stored, so "changed here" has no image).
  public func image(_ key: CloudBrainRecordKey) throws -> (stored: Bool, value: NativeRPCValue?) {
    try lock.withLock { () throws -> (stored: Bool, value: NativeRPCValue?) in let row = try loadRow(key); return (stored: row?.stored ?? false, value: row?.image) }
  }
  public func held(_ key: CloudBrainRecordKey) throws -> Set<String> { try lock.withLock { try loadRow(key)?.held ?? [] } }
  public func setHeld(_ key: CloudBrainRecordKey, _ fields: Set<String>) throws {
    try lock.withLock {
      try transaction {
        var row = try loadRow(key) ?? Row(heads: [], stored: false, image: nil, intentHeads: nil, intentImage: nil, intentHash: nil, held: [])
        row.held = fields; try saveRow(key, row)
      }
    }
  }

  // MARK: other versions (bounded pages)

  private func refreshOthers(_ key: CloudBrainRecordKey, table: CloudBrainMergeTable) throws {
    let view: CloudBrainMergeView?
    do { view = try loadView(key, table: table).1 } catch CloudBrainMergeError.historyIncomplete { return }
    try run("DELETE FROM other_version WHERE domain=? AND entity=?", [.text(key.domain), .text(key.entity)])
    for entry in view?.conflicts ?? [] {
      try run("INSERT INTO other_version(domain, entity, field, revision, value, device, time) VALUES (?,?,?,?,?,?,?)",
        [.text(key.domain), .text(key.entity), .text(entry.field), .text(entry.revision), .blob(try Self.encode(entry.value)),
         .text(entry.device), .int(entry.time)])
    }
  }
  public func otherVersions(after: (CloudBrainRecordKey, String, String)? = nil, limit: Int = 50) throws -> [CloudBrainOtherVersionRow] {
    guard (1...200).contains(limit) else { throw CloudFailure.invalidRequest }
    return try lock.withLock {
      let rows: [[Value]]
      if let after {
        let (key, field, revision) = after
        rows = try run("""
          SELECT domain, entity, field, revision, value, device, time FROM other_version
          WHERE (domain, entity, field, revision) > (?,?,?,?) ORDER BY domain, entity, field, revision LIMIT ?
          """, [.text(key.domain), .text(key.entity), .text(field), .text(revision), .int(Int64(limit))])
      } else {
        rows = try run("SELECT domain, entity, field, revision, value, device, time FROM other_version ORDER BY domain, entity, field, revision LIMIT ?",
          [.int(Int64(limit))])
      }
      return try rows.map { (row: [Value]) -> CloudBrainOtherVersionRow in
        guard let domain = Self.text(row[0]), let entity = Self.text(row[1]), let field = Self.text(row[2]), let revision = Self.text(row[3]),
              let value = Self.blob(row[4]), let device = Self.text(row[5]), let time = Self.int(row[6]) else { throw CloudBrainStoreError.unavailable("other") }
        return .init(key: try CloudBrainRecordKey(domain: domain, entity: entity),
          conflict: .init(field: field, revision: revision, value: try Self.decode(value), device: device, time: time))
      }
    }
  }

  // MARK: writes

  /// Retains received versions. A version already known is skipped; a version that arrives after one of its children
  /// keeps only its node; a version dated more than a day ahead of the service clock is refused before anything is
  /// written (`tooFarAhead`, a payload fault).
  public func receive(_ key: CloudBrainRecordKey, _ revisions: [CloudBrainMergeRevision], table: CloudBrainMergeTable) throws {
    let limit = clock.read() &+ Self.maximumAhead
    if let ahead = revisions.first(where: { $0.time > limit }) { throw CloudBrainStoreError.tooFarAhead(ahead.opId) }
    try lock.withLock {
      try transaction {
        for revision in revisions { try insert(key, revision, own: false) }
        try step("receive.others")
        try refreshOthers(key, table: table)
      }
    }
  }
  private func insert(_ key: CloudBrainRecordKey, _ revision: CloudBrainMergeRevision, own: Bool) throws {
    guard try run("SELECT 1 FROM node WHERE op_id=?", [.text(revision.opId)]).isEmpty else { return }
    try run("INSERT INTO node(op_id, domain, entity, parents, device, time, baseline) VALUES (?,?,?,?,?,?,?)",
      [.text(revision.opId), .text(key.domain), .text(key.entity), .text(Self.json(revision.parents)), .text(revision.node.device),
       .int(revision.time), .int(revision.node.baseline ? 1 : 0)])
    try step("insert.node")
    // The id exactly as it is spelled inside a stored parents list.
    let quoted = String(Self.json([revision.opId]).dropFirst().dropLast())
    let isHead = try run("SELECT 1 FROM node WHERE domain=? AND entity=? AND instr(parents, ?) > 0 LIMIT 1",
      [.text(key.domain), .text(key.entity), .text(quoted)]).isEmpty
    if isHead || own {
      try run("INSERT OR REPLACE INTO payload(op_id, domain, entity, version, head, unhanded) VALUES (?,?,?,?,?,?)",
        [.text(revision.opId), .text(key.domain), .text(key.entity), .blob(try Self.encode(revision.version.payload())),
         .int(isHead ? 1 : 0), .int(own ? 1 : 0)])
    }
    try step("insert.payload")
    for parent in revision.parents {
      try run("UPDATE payload SET head=0 WHERE op_id=?", [.text(parent)])
      // Only the heads' contents are kept, plus this Mac's own versions until the sync core has them.
      try run("DELETE FROM payload WHERE op_id=? AND unhanded=0", [.text(parent)])
    }
  }

  /// Captures what this Mac's owner stored for a record (`local` nil = removed here): one transaction that resolves an
  /// interrupted show, builds the version over the view against the stored image (slice 1a) and keeps the new image.
  /// `baseline` nil decides rule J here: baseline only when this Mac never stored the record and either holds Cloud
  /// heads for it or is joining.
  @discardableResult
  public func capture(_ key: CloudBrainRecordKey, local: NativeRPCValue?, chosen: Set<String> = [], restore: Bool = false,
                      table: CloudBrainMergeTable, opId: String, device: String, baseline: Bool? = nil) throws -> CloudBrainMergeRevision? {
    try lock.withLock {
      try transaction {
        var row = try loadRow(key)
        if var current = row, current.intentHash != nil {
          // Crash between the intent and the owner write (D8): the owner either wrote the intended value or did not.
          // Field by field, a value equal to the intended one counts as written (so importing it is no edit); any other
          // value is judged against the image stored before, as an ordinary local change.
          if try Self.hash(local) == current.intentHash {
            current.image = current.intentImage
          } else {
            current.image = Self.resolve(before: current.image, intended: current.intentImage, local: local)
          }
          current.heads = current.intentHeads ?? current.heads; current.stored = true
          current.intentHeads = nil; current.intentImage = nil; current.intentHash = nil
          row = current
        }
        try step("capture.intent")
        let (graph, view) = try loadView(key, table: table)
        let joiningNow = try userVersion() == Self.joiningSchema
        let isBaseline = baseline ?? (row?.stored != true && (view != nil || joiningNow))
        let held = row?.held ?? []
        let revision = CloudBrainMerge.revision(over: view, image: isBaseline ? nil : row?.image, local: local, held: held, chosen: chosen,
          restore: restore, table: table, opId: opId, device: device, clock: clock, baseline: isBaseline, graph: graph)
        if let revision { try insert(key, revision, own: true) }
        try step("capture.record")
        var next = row ?? Row(heads: [], stored: false, image: nil, intentHeads: nil, intentImage: nil, intentHash: nil, held: [])
        next.image = local; next.stored = true
        next.heads = revision == nil ? (view?.heads ?? []) : try loadGraph(key).heads
        try saveRow(key, next)
        try refreshOthers(key, table: table)
        return revision
      }
    }
  }

  /// The image after an interrupted show whose owner value differs from the intended one (see `capture`).
  static func resolve(before: NativeRPCValue?, intended: NativeRPCValue?, local: NativeRPCValue?) -> NativeRPCValue? {
    guard let local, let intended, local.fields != nil, intended.fields != nil else { return local == intended ? intended : before }
    var names: [String] = []
    for name in (intended.fields ?? []).map(\.key) + (before?.fields ?? []).map(\.key) + (local.fields ?? []).map(\.key) where !names.contains(name) {
      names.append(name)
    }
    var fields: [NativeRPCValue.Field] = []
    for name in names {
      let value = local[name] == intended[name] ? intended[name] : (before?[name] ?? .missing)
      if value != .missing { fields.append(.init(name, value)) }
    }
    return .object(fields)
  }

  /// Before the owner writes the view: records the heads and the exact value it will store (crash intent, D8).
  public func beginShow(_ key: CloudBrainRecordKey, heads: [String], willStore value: NativeRPCValue?) throws {
    try lock.withLock {
      try transaction {
        var row = try loadRow(key) ?? Row(heads: [], stored: false, image: nil, intentHeads: nil, intentImage: nil, intentHash: nil, held: [])
        row.intentHeads = heads; row.intentImage = value; row.intentHash = try Self.hash(value)
        try saveRow(key, row)
      }
    }
  }
  /// After the owner wrote it: the intended value becomes the stored image for those heads.
  public func finishShow(_ key: CloudBrainRecordKey) throws {
    try lock.withLock {
      try transaction {
        guard var row = try loadRow(key), let heads = row.intentHeads else { return }
        row.heads = heads; row.image = row.intentImage; row.stored = true
        row.intentHeads = nil; row.intentImage = nil; row.intentHash = nil
        try saveRow(key, row)
      }
    }
  }

  /// The owner refused the write (it wrote nothing): the intent recorded by `beginShow` is withdrawn and the record is
  /// exactly as before it. Lane A2 lean, review should-fix 2.
  public func cancelShow(_ key: CloudBrainRecordKey) throws {
    try lock.withLock {
      try transaction {
        guard var row = try loadRow(key), row.intentHeads != nil || row.intentHash != nil else { return }
        row.intentHeads = nil; row.intentImage = nil; row.intentHash = nil
        try saveRow(key, row)
      }
    }
  }
  /// This Mac's own versions not yet handed to the sync core, oldest first (the pump of slice 2 reads these).
  public func ownUnhanded(limit: Int) throws -> [CloudBrainMergeRevision] {
    guard (1...256).contains(limit) else { throw CloudFailure.invalidRequest }
    return try lock.withLock {
      try run("""
        SELECT p.op_id, p.version, n.parents, n.device, n.time, n.baseline FROM payload p JOIN node n ON n.op_id=p.op_id
        WHERE p.unhanded=1 ORDER BY n.time, p.op_id LIMIT ?
        """, [.int(Int64(limit))]).map { (row: [Value]) -> CloudBrainMergeRevision in
        guard let op = Self.text(row[0]), let data = Self.blob(row[1]), let parents = Self.text(row[2]), let device = Self.text(row[3]),
              let time = Self.int(row[4]), let baseline = Self.int(row[5]) else { throw CloudBrainStoreError.unavailable("own") }
        return .init(node: .init(opId: op, parents: Self.strings(parents), device: device, time: time, baseline: baseline != 0),
          version: try CloudBrainMergeVersion(payload: try Self.decode(data)))
      }
    }
  }
  /// The sync core holds these now (its LocalReceipt): contents of versions that are no longer heads are dropped.
  public func markHanded(_ ids: [String]) throws {
    try lock.withLock {
      try transaction {
        for id in ids {
          try run("UPDATE payload SET unhanded=0 WHERE op_id=?", [.text(id)])
          try run("DELETE FROM payload WHERE op_id=? AND head=0", [.text(id)])
        }
      }
    }
  }

  // MARK: lean record adapter (reads only; added for `CloudBrainRecordAdapter`)

  /// This Mac's own versions of one domain not yet handed to the sync core, oldest first, each with its record.
  /// `offset`: how many of the oldest to skip (the adapter pages past versions it must hold back).
  public func ownUnhanded(domain: String, limit: Int, offset: Int = 0) throws -> [(key: CloudBrainRecordKey, revision: CloudBrainMergeRevision)] {
    guard (1...256).contains(limit), offset >= 0 else { throw CloudFailure.invalidRequest }
    return try lock.withLock {
      try run("""
        SELECT p.op_id, p.version, n.parents, n.device, n.time, n.baseline, p.entity FROM payload p JOIN node n ON n.op_id=p.op_id
        WHERE p.unhanded=1 AND p.domain=? ORDER BY n.time, p.op_id LIMIT ? OFFSET ?
        """, [.text(domain), .int(Int64(limit)), .int(Int64(offset))]).map { (row: [Value]) -> (key: CloudBrainRecordKey, revision: CloudBrainMergeRevision) in
        guard let op = Self.text(row[0]), let data = Self.blob(row[1]), let parents = Self.text(row[2]), let device = Self.text(row[3]),
              let time = Self.int(row[4]), let baseline = Self.int(row[5]), let entity = Self.text(row[6]) else { throw CloudBrainStoreError.unavailable("own") }
        let revision = CloudBrainMergeRevision(node: .init(opId: op, parents: Self.strings(parents), device: device, time: time, baseline: baseline != 0),
          version: try CloudBrainMergeVersion(payload: try Self.decode(data)))
        return (key: try CloudBrainRecordKey(domain: domain, entity: entity), revision: revision)
      }
    }
  }
  /// Records of one domain this Mac holds a stored value for (a record missing from its owner now was removed here).
  public func storedEntities(domain: String) throws -> [String] {
    try lock.withLock {
      try run("SELECT entity FROM record WHERE domain=? AND stored=1 AND image IS NOT NULL ORDER BY entity", [.text(domain)])
        .compactMap { (row: [Value]) -> String? in Self.text(row.first) }
    }
  }
  /// Records of one domain with fields this Mac deliberately does not show (the hold set), by record.
  public func heldEntities(domain: String) throws -> [String: Set<String>] {
    try lock.withLock {
      var result: [String: Set<String>] = [:]
      for row in try run("SELECT entity, held FROM record WHERE domain=? AND held<>'[]' ORDER BY entity", [.text(domain)]) {
        guard let entity = Self.text(row[0]) else { continue }
        let fields = Set(Self.strings(Self.text(row[1])))
        if !fields.isEmpty { result[entity] = fields }
      }
      return result
    }
  }
  /// How many other versions are listed for one domain ("N earlier versions kept").
  public func otherVersionCount(domain: String) throws -> Int {
    try lock.withLock { Int(Self.int(try run("SELECT count(*) FROM other_version WHERE domain=?", [.text(domain)]).first?.first) ?? 0) }
  }
  /// Other versions of one domain, by key order, at most 200.
  public func otherVersions(domain: String, limit: Int = 200) throws -> [CloudBrainOtherVersionRow] {
    guard (1...200).contains(limit) else { throw CloudFailure.invalidRequest }
    return try lock.withLock {
      try run("SELECT entity, field, revision, value, device, time FROM other_version WHERE domain=? ORDER BY entity, field, revision LIMIT ?",
        [.text(domain), .int(Int64(limit))]).map { (row: [Value]) -> CloudBrainOtherVersionRow in
        guard let entity = Self.text(row[0]), let field = Self.text(row[1]), let revision = Self.text(row[2]), let value = Self.blob(row[3]),
              let device = Self.text(row[4]), let time = Self.int(row[5]) else { throw CloudBrainStoreError.unavailable("other") }
        return .init(key: try CloudBrainRecordKey(domain: domain, entity: entity),
          conflict: .init(field: field, revision: revision, value: try Self.decode(value), device: device, time: time))
      }
    }
  }

  /// Tests only: how many versions and kept contents a record has.
  func countsForTesting(_ key: CloudBrainRecordKey) throws -> (nodes: Int, payloads: Int, others: Int) {
    try lock.withLock { () throws -> (nodes: Int, payloads: Int, others: Int) in
      func count(_ table: String) throws -> Int {
        Int(Self.int(try run("SELECT count(*) FROM \(table) WHERE domain=? AND entity=?", [.text(key.domain), .text(key.entity)]).first?.first) ?? 0)
      }
      return (nodes: try count("node"), payloads: try count("payload"), others: try count("other_version"))
    }
  }

  /// Tests only: an owner that stored a different value than the view (normalisation) without a capture.
  func setImageForTesting(_ key: CloudBrainRecordKey, _ value: NativeRPCValue?) throws {
    try lock.withLock {
      try transaction {
        var row = try loadRow(key) ?? Row(heads: [], stored: false, image: nil, intentHeads: nil, intentImage: nil, intentHash: nil, held: [])
        row.image = value; row.stored = true; try saveRow(key, row)
      }
    }
  }
}
