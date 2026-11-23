import Foundation
import SQLite3
import Darwin

/// One connection, serialized transactions, FULL WAL durability. Never opens a domain's legacy store.
public final class CloudSyncStore: @unchecked Sendable {
  private let lock = NSRecursiveLock()
  private var transactionDepth = 0
  private let db: OpaquePointer
  public let root: URL
  public let subject: CloudSubject
  private let journalFault: CloudSyncFault
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  /// Device trust: how many refused packs and how many waiting devices are listed row by row; beyond that only a
  /// count and the lowest unlisted position are kept (CloudSyncTrustStore.swift). Changed only by tests.
  var refusedRowLimit = 1_000
  var heldRowLimit = 500

  public init(root: URL, subject: CloudSubject, journalFault: @escaping CloudSyncFault = { _ in }) throws {
    guard root.isFileURL else { throw CloudFailure.unsafeConfiguration }
    self.root = root
    self.subject = subject
    self.journalFault = journalFault
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var opened: OpaquePointer?
    guard sqlite3_open_v2(root.appendingPathComponent("sync.sqlite").path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened else {
      if let opened { sqlite3_close(opened) }
      throw CloudFailure.unavailable
    }
    db = opened
    do {
      sqlite3_busy_timeout(db, 5000)
      try execute("PRAGMA journal_mode=WAL")
      try execute("PRAGMA synchronous=FULL")
      try execute("PRAGMA fullfsync=ON")
      try execute("PRAGMA checkpoint_fullfsync=ON")
      try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS outbox (opId TEXT PRIMARY KEY, domain TEXT NOT NULL, entityId TEXT NOT NULL, parents BLOB NOT NULL, payloadRef BLOB NOT NULL, state TEXT NOT NULL)")
      // 0.23.4 (additive): only the records still waiting to go up, by kind. Counting or measuring the queue then
      // reads the waiting rows only, never every record this Mac ever sent (the outbox keeps those as history).
      try execute("CREATE INDEX IF NOT EXISTS outbox_queued_domain ON outbox(domain) WHERE state='queued'")
      // 0.23.4 CPU (23 Nov, additive): the send loop asks, for each record it may send, whether an earlier edit of the
      // same record is parked; without this the question walked every earlier row of the outbox, once per record.
      try execute("CREATE INDEX IF NOT EXISTS outbox_parked_entity ON outbox(domain,entityId) WHERE state='parked'")
      try execute("CREATE TABLE IF NOT EXISTS applied (segmentId TEXT PRIMARY KEY, seq TEXT NOT NULL UNIQUE, digest TEXT NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS checkpoint_applied (checkpointId TEXT PRIMARY KEY,seq TEXT NOT NULL,digest TEXT NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS entity_heads (domain TEXT NOT NULL, entityId TEXT NOT NULL, revision TEXT NOT NULL, PRIMARY KEY(domain,entityId,revision))")
      try execute("CREATE TABLE IF NOT EXISTS source_cursors (sourceId TEXT PRIMARY KEY, identity TEXT NOT NULL, offset TEXT, digest TEXT)")
      try execute("CREATE TABLE IF NOT EXISTS migrations (sourceId TEXT PRIMARY KEY, snapshotId TEXT NOT NULL, status TEXT NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS records (opId TEXT PRIMARY KEY, bytes BLOB NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS record_entities (opId TEXT PRIMARY KEY, domain TEXT NOT NULL, entityId TEXT NOT NULL)")
      try execute("CREATE INDEX IF NOT EXISTS record_entity_lookup ON record_entities(domain,entityId)")
      try execute("CREATE TABLE IF NOT EXISTS record_links (child TEXT NOT NULL, parent TEXT NOT NULL, PRIMARY KEY(child,parent))")
      try execute("CREATE INDEX IF NOT EXISTS record_parent_lookup ON record_links(parent)")
      try execute("CREATE TABLE IF NOT EXISTS operation_projects (opId TEXT PRIMARY KEY,projectId TEXT)")
      try execute("CREATE TABLE IF NOT EXISTS segment_bindings (segmentId TEXT PRIMARY KEY, deviceId TEXT NOT NULL, retired INTEGER NOT NULL DEFAULT 0)")
      try execute("CREATE TABLE IF NOT EXISTS segment_ops (segmentId TEXT NOT NULL, opId TEXT NOT NULL, PRIMARY KEY(segmentId,opId))")
      // 0.23.4 CPU (23 Nov, additive): "is this record already in a pack of another device?" by record, not a scan of
      // every pack's list for every record the send loop looks at.
      try execute("CREATE INDEX IF NOT EXISTS segment_ops_op ON segment_ops(opId)")
      try execute("CREATE TABLE IF NOT EXISTS verified_ops (opId TEXT PRIMARY KEY)")
      try execute("CREATE TABLE IF NOT EXISTS segments (segmentId TEXT PRIMARY KEY, bytes BLOB NOT NULL, operationIds BLOB NOT NULL, receipt BLOB)")
      try execute("CREATE TABLE IF NOT EXISTS prepare_journal (segmentId TEXT PRIMARY KEY, bytes BLOB NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS snapshot_records (snapshotId TEXT NOT NULL, opId TEXT NOT NULL, domain TEXT NOT NULL, bytes BLOB NOT NULL, UNIQUE(snapshotId,opId))")
      try execute("CREATE INDEX IF NOT EXISTS snapshot_domain_lookup ON snapshot_records(snapshotId,domain)")
      try execute("CREATE TABLE IF NOT EXISTS snapshot_entities (snapshotId TEXT NOT NULL, opId TEXT NOT NULL, domain TEXT NOT NULL, entityId TEXT NOT NULL, PRIMARY KEY(snapshotId,opId))")
      try execute("CREATE TABLE IF NOT EXISTS snapshot_links (snapshotId TEXT NOT NULL, child TEXT NOT NULL, parent TEXT NOT NULL, PRIMARY KEY(snapshotId,child,parent))")
      try execute("CREATE TABLE IF NOT EXISTS snapshot_sources (snapshotId TEXT NOT NULL,opId TEXT NOT NULL,sourceId TEXT NOT NULL,PRIMARY KEY(snapshotId,opId))")
      try execute("CREATE INDEX IF NOT EXISTS snapshot_source_lookup ON snapshot_sources(snapshotId,sourceId)")
      try execute("CREATE TABLE IF NOT EXISTS retained_files (blobId TEXT NOT NULL,sourceId TEXT NOT NULL,PRIMARY KEY(blobId,sourceId))")
      try execute("CREATE INDEX IF NOT EXISTS retained_file_source ON retained_files(sourceId)")
      try execute("CREATE TABLE IF NOT EXISTS snapshot_files (snapshotId TEXT NOT NULL, blobId TEXT NOT NULL, PRIMARY KEY(snapshotId,blobId))")
      try execute("CREATE TABLE IF NOT EXISTS outbox_files (opId TEXT NOT NULL, blobId TEXT NOT NULL, PRIMARY KEY(opId,blobId))")
      try execute("CREATE TABLE IF NOT EXISTS objects (blobId TEXT PRIMARY KEY, bytes BLOB NOT NULL, descriptor BLOB NOT NULL, receipt BLOB)")
      // Queued records that cannot be sent (too large, or refused for good by the service): kept, reported,
      // retried on request; they never block the records queued behind them.
      // Per-record cloud receipts (sequence and the service's commit time) for adapters' "uploaded" marks.
      // Round 6 S2: records whose content was released (skeleton only); the release pass skips them cheaply.
      try execute("CREATE TABLE IF NOT EXISTS record_stubs (opId TEXT PRIMARY KEY)")
      try execute("CREATE TABLE IF NOT EXISTS op_receipts (opId TEXT PRIMARY KEY, seq TEXT NOT NULL, committedAt INTEGER)")
      // Saved-password items of an older secrets key: never sent (no device could open them), kept and reported.
      try execute("CREATE TABLE IF NOT EXISTS retired_sends (opId TEXT PRIMARY KEY, reason TEXT NOT NULL, retiredAt INTEGER NOT NULL)")
      // Saved-password packs this Mac cannot open (an older or unknown key): the protected cursor moves on.
      // Saved-password packs sealed with a key the newer key replaced: no device can open them (round 6 S6).
      try execute("CREATE TABLE IF NOT EXISTS superseded_packs (seq TEXT PRIMARY KEY, keyEpoch INTEGER NOT NULL, recordedAt INTEGER NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS parked_packs (seq TEXT PRIMARY KEY, reason TEXT NOT NULL, attempts INTEGER NOT NULL, nextAt INTEGER NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS parked_sends (opId TEXT PRIMARY KEY, reason TEXT NOT NULL, parkedAt INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0, nextAt INTEGER NOT NULL DEFAULT 0, permanent INTEGER NOT NULL DEFAULT 0)")
      // Records a domain adapter could not apply (poison records): kept, reported, retried, never skipped.
      try execute("CREATE TABLE IF NOT EXISTS parked_ops (opId TEXT PRIMARY KEY, domain TEXT NOT NULL, entityId TEXT NOT NULL, sourceId TEXT NOT NULL, projectId TEXT NOT NULL, bytes BLOB NOT NULL, origin BLOB NOT NULL, reason TEXT NOT NULL, conflict INTEGER NOT NULL, attempts INTEGER NOT NULL, nextAt INTEGER NOT NULL, parkedAt INTEGER NOT NULL)")
      // Device trust. Packs this Mac refused (their signature does not check under the stored key of the trusted
      // device they are attributed to): recorded and reported, never applied, never a stall.
      // Device trust. HELD: one row per device that has sent something and is not trusted on this Mac, with its
      // first waiting feed position per class and the counts the service reported. Apart from parked_* (opened
      // content an adapter could not apply) and from the queue: nothing of a waiting pack is stored at all.
      // Named as in the design note, because "held" already means queued sends waiting for a file here.
      try execute("CREATE TABLE IF NOT EXISTS untrusted_devices (deviceId TEXT PRIMARY KEY, firstHeldSeq BLOB NOT NULL, firstHeldSecretsSeq BLOB NOT NULL, packs INTEGER NOT NULL, operations INTEGER NOT NULL, byDomain BLOB NOT NULL, firstSeenAt INTEGER NOT NULL, releasing INTEGER NOT NULL DEFAULT 0)")
      // T3: a store made before the release mark existed gains the column (CREATE TABLE IF NOT EXISTS leaves an
      // existing table as it was, and the index below would then fail and the store would not open).
      if try !rows("PRAGMA table_info(untrusted_devices)").contains(where: { String(decoding: $0[1], as: UTF8.self) == "releasing" }) {
        try execute("ALTER TABLE untrusted_devices ADD COLUMN releasing INTEGER NOT NULL DEFAULT 0")
      }
      // Rows whose release has begun are found without reading the others (a pull's cost does not grow with them).
      try execute("CREATE INDEX IF NOT EXISTS untrusted_releasing ON untrusted_devices(releasing) WHERE releasing=1")
      // N2: trusted packs of a kind this Mac does not take now, by position (applied once that kind is taken).
      try execute("CREATE TABLE IF NOT EXISTS kind_waiting_packs (seq TEXT PRIMARY KEY, class TEXT NOT NULL, deviceId TEXT NOT NULL, domains BLOB NOT NULL, waitingSince INTEGER NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS refused_packs (seq TEXT PRIMARY KEY, class TEXT NOT NULL, deviceId TEXT NOT NULL, reason TEXT NOT NULL, firstAt INTEGER NOT NULL, checks INTEGER NOT NULL)")
      try transaction {
        if let old: CloudSubject = try value("subject"), old != subject { throw CloudFailure.unsafeConfiguration }
        try set("subject", subject)
      }
      try splitCheckpointReceipts()
      try migrateGraphIndex()
      try collapseLocalOnlyHeads()
      let directory = Darwin.open(root.path, O_RDONLY)
      guard directory >= 0 else { throw CloudFailure.unavailable }
      defer { Darwin.close(directory) }
      guard Darwin.fsync(directory) == 0 else { throw CloudFailure.unavailable }
    } catch { sqlite3_close(db); throw error }
  }
  deinit { sqlite3_close(db) }

  func transaction<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    let depth = transactionDepth
    let savepoint = "cloud_sync_\(depth)"
    try execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT " + savepoint)
    transactionDepth += 1
    defer { transactionDepth -= 1 }
    do {
      let result = try body()
      try execute(depth == 0 ? "COMMIT" : "RELEASE SAVEPOINT " + savepoint)
      return result
    } catch {
      if depth == 0 { try? execute("ROLLBACK") }
      else { try? execute("ROLLBACK TO SAVEPOINT " + savepoint); try? execute("RELEASE SAVEPOINT " + savepoint) }
      throw error
    }
  }

  func execute(_ sql: String, _ args: [Data] = []) throws {
    _ = try rows(sql, args)
  }
  func rows(_ sql: String, _ args: [Data] = []) throws -> [[Data]] {
    lock.lock()
    defer { lock.unlock() }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CloudFailure.unavailable }
    defer { sqlite3_finalize(statement) }
    for (index, data) in args.enumerated() {
      // An empty value is bound explicitly as an empty BLOB, never as NULL (a NULL pointer to sqlite3_bind_blob
      // binds NULL, and NOT NULL columns with INSERT OR IGNORE would silently drop the row).
      let result = data.isEmpty ? sqlite3_bind_zeroblob(statement, Int32(index + 1), 0)
        : data.withUnsafeBytes { sqlite3_bind_blob(statement, Int32(index + 1), $0.baseAddress, Int32($0.count), transient) }
      guard result == SQLITE_OK else { throw CloudFailure.unavailable }
    }
    var result: [[Data]] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { return result }
      guard step == SQLITE_ROW else { throw CloudFailure.unavailable }
      result.append((0..<sqlite3_column_count(statement)).map { index in
        let length = Int(sqlite3_column_bytes(statement, index))
        guard length > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: length)
      })
    }
  }
  /// Metadata rows whose key starts with `prefix`, by range on the primary key (keys are stored as UTF-8 bytes).
  func prefixed(_ prefix: String) throws -> [(String, Data)] {
    var upper = Array(prefix.utf8); upper[upper.count - 1] += 1
    return try rows("SELECT key,value FROM metadata WHERE key>=? AND key<? ORDER BY key", [Data(prefix.utf8), Data(upper)]).map {
      (String(decoding: $0[0], as: UTF8.self), $0[1])
    }
  }
  func value<T: Decodable>(_ key: String) throws -> T? {
    guard let row = try rows("SELECT value FROM metadata WHERE key=?", [Data(key.utf8)]).first else { return nil }
    return try JSONDecoder().decode(T.self, from: row[0])
  }
  func set<T: Encodable>(_ key: String, _ value: T) throws {
    try execute("INSERT INTO metadata(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [Data(key.utf8), try CloudSyncCanonical.encode(value)])
  }
  public func saveCursor(sourceId: String, identity: String, offset: String?, digest: String?) throws {
    guard !sourceId.isEmpty, !identity.isEmpty else { throw CloudFailure.invalidRequest }
    try transaction {
      if let previous = try rows("SELECT identity FROM source_cursors WHERE sourceId=?", [Data(sourceId.utf8)]).first,
        previous[0] != Data(identity.utf8) { throw CloudFailure.versionChanged }
      try execute("INSERT INTO source_cursors(sourceId,identity,offset,digest) VALUES (?,?,?,?) ON CONFLICT(sourceId) DO UPDATE SET offset=excluded.offset,digest=excluded.digest",
        [Data(sourceId.utf8), Data(identity.utf8), Data((offset ?? "").utf8), Data((digest ?? "").utf8)])
    }
  }
  public func cursor(sourceId: String) throws -> (identity: String, offset: String, digest: String)? {
    guard let row = try rows("SELECT identity,offset,digest FROM source_cursors WHERE sourceId=?", [Data(sourceId.utf8)]).first else { return nil }
    return (String(decoding: row[0], as: UTF8.self), String(decoding: row[1], as: UTF8.self), String(decoding: row[2], as: UTF8.self))
  }
  public func operations() throws -> [CloudOperation] {
    try rows("SELECT bytes FROM records ORDER BY opId").map { try JSONDecoder().decode(CloudOperation.self, from: $0[0]) }
  }
  func checkIdentity(_ operations: [CloudOperation], snapshot: String? = nil) throws {
    try transaction {
      try CloudSyncPack.validate(operations)
      let incoming = Dictionary(operations.map { ($0.opId, $0) }, uniquingKeysWith: { first, _ in first })
      try execute("CREATE TEMP TABLE IF NOT EXISTS graph_probe (child BLOB NOT NULL,parent BLOB NOT NULL)")
      try execute("DELETE FROM graph_probe")
      if let snapshot { try execute("INSERT INTO graph_probe(child,parent) SELECT child,parent FROM snapshot_links WHERE snapshotId=?", [Data(snapshot.utf8)]) }
      for op in operations {
        // A settled record keeps only its skeleton (item B): the same record arrives with the same skeleton.
        if let old = try rows("SELECT bytes FROM records WHERE opId=?", [Data(op.opId.utf8)]).first,
          old[0] != (try CloudSyncCanonical.encode(op)), old[0] != (try CloudSyncCanonical.encode(Self.skeleton(op))) { throw CloudFailure.idReused }
        for parent in op.parents {
          if let other = incoming[parent] {
            guard other.domain == op.domain, other.entityId == op.entityId else { throw CloudFailure.invalidRequest }
          } else if let other = try rows("SELECT domain,entityId FROM record_entities WHERE opId=?", [Data(parent.utf8)]).first {
            guard other[0] == Data(op.domain.utf8), other[1] == Data(op.entityId.utf8) else { throw CloudFailure.invalidRequest }
          }
          if let snapshot, let other = try rows("SELECT domain,entityId FROM snapshot_entities WHERE snapshotId=? AND opId=?", [Data(snapshot.utf8), Data(parent.utf8)]).first {
            guard other[0] == Data(op.domain.utf8), other[1] == Data(op.entityId.utf8) else { throw CloudFailure.invalidRequest }
          }
          try execute("INSERT INTO graph_probe(child,parent) VALUES (?,?)", [Data(op.opId.utf8), Data(parent.utf8)])
        }
        for child in try rows("SELECT e.domain,e.entityId FROM record_links l JOIN record_entities e ON l.child=e.opId WHERE l.parent=?", [Data(op.opId.utf8)]) {
          guard child[0] == Data(op.domain.utf8), child[1] == Data(op.entityId.utf8) else { throw CloudFailure.invalidRequest }
        }
      }
      for op in operations {
        let cycles = try rows("WITH RECURSIVE edges(child,parent) AS (SELECT child,parent FROM record_links UNION SELECT child,parent FROM graph_probe), ancestry(id) AS (SELECT parent FROM edges WHERE child=? UNION SELECT edges.parent FROM edges JOIN ancestry ON edges.child=ancestry.id) SELECT id FROM ancestry WHERE id=? LIMIT 1", [Data(op.opId.utf8), Data(op.opId.utf8)])
        guard cycles.isEmpty else { throw CloudFailure.invalidRequest }
      }
      try execute("DELETE FROM graph_probe")
    }
  }
  func indexOperation(_ op: CloudOperation) throws {
    try execute("INSERT OR IGNORE INTO record_entities(opId,domain,entityId) VALUES (?,?,?)", [Data(op.opId.utf8), Data(op.domain.utf8), Data(op.entityId.utf8)])
    try execute("INSERT OR IGNORE INTO operation_projects(opId,projectId) VALUES (?,?)", [Data(op.opId.utf8), Data((op.projectId ?? "").utf8)])
    for parent in op.parents { try execute("INSERT OR IGNORE INTO record_links(child,parent) VALUES (?,?)", [Data(op.opId.utf8), Data(parent.utf8)]) }
  }
  func migrateGraphIndex() throws {
    if let ready: Bool = try value("graph-index-v2"), ready { return }
    try transaction {
      var cursor: Int64 = 0
      while true {
        let page = try rows("SELECT rowid,bytes FROM records WHERE rowid>CAST(? AS INTEGER) ORDER BY rowid LIMIT 64", [Data(String(cursor).utf8)])
        if page.isEmpty { break }
        for row in page {
          try indexOperation(JSONDecoder().decode(CloudOperation.self, from: row[1]))
          guard let next = Int64(String(decoding: row[0], as: UTF8.self)) else { throw CloudFailure.invalidRequest }; cursor = next
        }
      }
      try execute("DELETE FROM entity_heads")
      try execute("INSERT INTO entity_heads(domain,entityId,revision) SELECT domain,entityId,opId FROM record_entities WHERE NOT EXISTS (SELECT 1 FROM record_links WHERE parent=record_entities.opId)")
      cursor = 0
      while true {
        let page = try rows("SELECT rowid,segmentId,operationIds FROM segments WHERE rowid>CAST(? AS INTEGER) ORDER BY rowid LIMIT 64", [Data(String(cursor).utf8)])
        if page.isEmpty { break }
        for row in page {
          for id in try JSONDecoder().decode([String].self, from: row[2]) { try execute("INSERT OR IGNORE INTO segment_ops(segmentId,opId) VALUES (?,?)", [row[1], Data(id.utf8)]) }
          guard let next = Int64(String(decoding: row[0], as: UTF8.self)) else { throw CloudFailure.invalidRequest }; cursor = next
        }
      }
      try set("graph-index-v2", true)
    }
  }
  /// MAC-NEXT-8 (real check 4): an older build re-sent 115 received revisions of each of 3 board rows under its own
  /// device id, each a separate branch: 116 open heads per row on both Macs. The board no longer travels, so its
  /// records are history only: each entity keeps ONE head, its newest record (highest rowid). Sends nothing.
  func collapseLocalOnlyHeads(entity: (domain: String, entityId: String)? = nil) throws {
    for domain in CloudBrainMemoryFormat.localOnlyDomains {
      if let entity, entity.domain != domain { continue }
      let scope = entity == nil ? "" : " AND h.entityId=?2"
      let args = [Data(domain.utf8)] + (entity.map { [Data($0.entityId.utf8)] } ?? [])
      // A head goes when another head of the same entity is newer (later rowid; equal rowids: larger id wins).
      try execute("""
        DELETE FROM entity_heads WHERE rowid IN (SELECT h.rowid FROM entity_heads h JOIN records rh ON rh.opId=h.revision WHERE h.domain=?1\(scope)
        AND EXISTS (SELECT 1 FROM entity_heads o JOIN records ro ON ro.opId=o.revision
                    WHERE o.domain=h.domain AND o.entityId=h.entityId AND o.revision<>h.revision AND (ro.rowid>rh.rowid OR (ro.rowid=rh.rowid AND o.revision>h.revision))))
        """, args)
    }
  }
  /// Heads per entity of one domain (tests and diagnostics).
  public func headCounts(domain: String) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for row in try rows("SELECT entityId,COUNT(*) FROM entity_heads WHERE domain=? GROUP BY entityId", [Data(domain.utf8)]) {
      counts[String(decoding: row[0], as: UTF8.self), default: 0] = Int(String(decoding: row[1], as: UTF8.self)) ?? 0
    }
    return counts
  }
  func remember(_ operations: [CloudOperation]) throws {
    try checkIdentity(operations)
    for op in operations {
      let bytes = try CloudSyncCanonical.encode(op)
      try execute("INSERT OR IGNORE INTO records(opId,bytes) VALUES (?,?)", [Data(op.opId.utf8), bytes])
      // Round 6 S7e: the full record arriving over its released skeleton (an adapter's setup page after an
      // account reset) puts the content back, so this Mac can build an inventory from it again.
      let stub = try CloudSyncCanonical.encode(Self.skeleton(op))
      // 0.23.4: a piece released when the Cloud acknowledged it is not filled again when the feed brings it back
      // (that would write each piece twice); nothing builds an inventory from these rows in this version.
      if stub != bytes, !Self.releasedOnAcknowledge.contains(op.domain), try !rows("SELECT opId FROM records WHERE opId=? AND bytes=?", [Data(op.opId.utf8), stub]).isEmpty {
        try execute("UPDATE records SET bytes=? WHERE opId=?", [bytes, Data(op.opId.utf8)])
        try execute("DELETE FROM record_stubs WHERE opId=?", [Data(op.opId.utf8)])
      }
      try indexOperation(op)
    }
    for op in operations {
      let args = [Data(op.domain.utf8), Data(op.entityId.utf8)]
      try execute("DELETE FROM entity_heads WHERE domain=? AND entityId=?", args)
      try execute("INSERT INTO entity_heads(domain,entityId,revision) SELECT domain,entityId,opId FROM record_entities WHERE domain=? AND entityId=? AND NOT EXISTS (SELECT 1 FROM record_links WHERE parent=record_entities.opId)", args)
      if CloudBrainMemoryFormat.localOnlyDomains.contains(op.domain) { try collapseLocalOnlyHeads(entity: (op.domain, op.entityId)) }
    }
  }
  func hasPending(projectId: String, domains: Set<String>? = nil) throws -> Bool {
    let names = domains?.sorted()
    let predicate = names.map { " AND outbox.domain IN (" + $0.map { _ in "?" }.joined(separator: ",") + ")" } ?? ""
    return try !rows("SELECT outbox.opId FROM outbox JOIN operation_projects ON outbox.opId=operation_projects.opId WHERE outbox.state='queued' AND (operation_projects.projectId IS NULL OR length(operation_projects.projectId)=0 OR operation_projects.projectId=?)" + predicate + " LIMIT 1", [Data(projectId.utf8)] + (names ?? []).map { Data($0.utf8) }).isEmpty
  }
  func queuedCount() throws -> Int { Int(String(decoding: try rows("SELECT count(*) FROM outbox WHERE state='queued'")[0][0], as: UTF8.self)) ?? 0 }
  /// `snapshotPage` pages never fail on unattributed protected files: they are counted and reported
  /// under `unattributedProtectedFiles`, and bootstrap uploads them before any segment can need them.
  func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob] = [], associations: [CloudFileAssociation] = [], snapshotPage: String? = nil) throws -> CloudLocalReceipt {
    try CloudSyncPack.validate(operations)
    return try transaction {
      try remember(operations)
      for file in files { try retainFile(CloudSyncSealedFile(file)) }
      let unattributed = try linkDependencies(operations, files: files, associations: associations, strict: snapshotPage == nil)
      if let snapshotPage, !unattributed.isEmpty {
        try set("unattributedProtectedFiles:" + snapshotPage, unattributed)
      }
      for op in operations {
        let verified = try !rows("SELECT opId FROM verified_ops WHERE opId=?", [Data(op.opId.utf8)]).isEmpty
        let state = verified ? "acknowledged" : "queued"
        try execute("INSERT OR IGNORE INTO outbox(opId,domain,entityId,parents,payloadRef,state) VALUES (?,?,?,?,?,CAST(? AS TEXT))",
          [Data(op.opId.utf8), Data(op.domain.utf8), Data(op.entityId.utf8), try CloudSyncCanonical.encode(op.parents), Data(), Data(state.utf8)])
      }
      // Mac-next 2: setup pages discard this receipt; counting and summing the whole queue for each of thousands
      // of pages made the first saved copy quadratic.
      if snapshotPage != nil { return .init(operationIds: operations.map(\.opId), queued: 0, bytes: 0, savedAt: CloudSyncBytes.now()) }
      // 0.23.4 (fault 2): the same shortcut for every handover. Summing the bytes of the WHOLE queue at each call
      // read every waiting record (7 GB on the Mac mini) for each 16 project-folder pieces: 111 % CPU and a crawl.
      // `bytes` is now what THIS call queued (nobody reads the old total); `queued` is a count over the waiting
      // rows' own index.
      var mine = files.reduce(Int64(0)) { $0 + $1.bytes }
      for op in operations {
        mine += Int64(String(decoding: try rows("SELECT length(bytes) FROM records WHERE opId=?", [Data(op.opId.utf8)]).first?[0] ?? Data(), as: UTF8.self)) ?? 0
      }
      return .init(operationIds: operations.map(\.opId), queued: try queuedCount(), bytes: mine, savedAt: CloudSyncBytes.now())
    }
  }
  /// 0.23.4 (fault 1): bytes of `domain`'s records waiting to go up (every kind when nil), counted in pages only until
  /// they pass `stopAfter`: asking costs a bounded walk of the waiting rows, however long the queue is.
  func queuedBytes(domain: String?, stopAfter: Int64) throws -> Int64 {
    var total: Int64 = 0, after: Int64 = 0
    let scope = domain == nil ? "" : " AND o.domain=?"
    while total <= stopAfter {
      let page = try rows("SELECT o.rowid,length(r.bytes) FROM outbox o JOIN records r ON r.opId=o.opId WHERE o.state='queued'" + scope +
        " AND o.rowid>CAST(? AS INTEGER) ORDER BY o.rowid LIMIT 512", (domain.map { [Data($0.utf8)] } ?? []) + [Data(String(after).utf8)])
      for row in page { total += Int64(String(decoding: row[1], as: UTF8.self)) ?? 0 }
      guard page.count == 512, let last = page.last, let next = Int64(String(decoding: last[0], as: UTF8.self)) else { break }
      after = next
    }
    return total
  }
  /// `sendable` leaves out records handed over with a file that is not on this Mac: they stay queued (and are
  /// reported) until the file arrives, instead of failing every send of the queue behind them.
  func pending(limit: Int? = nil, domains: Set<String>? = nil, deviceId: String? = nil, sendable: Bool = false) throws -> [CloudOperation] {
    let query = try pendingQuery(limit: limit, domains: domains, deviceId: deviceId, sendable: sendable)
    return try rows(query.sql, query.args).map { try JSONDecoder().decode(CloudOperation.self, from: $0[0]) }
  }
  /// The send loop's read of the queue, in queue order. 0.23.4 CPU (23 Nov): `NOT INDEXED` keeps it a walk of the outbox
  /// in row order that stops after `limit` rows. The waiting-rows index (`outbox_queued_domain`) otherwise led SQLite to
  /// take EVERY waiting record of the named kinds (208,000 on the Mac mini), ask the parked and pack questions for each,
  /// and sort them all with their content (9 GB) to return 256: about 35-50 minutes of CPU per pack of 5 pieces.
  func pendingQuery(limit: Int? = nil, domains: Set<String>? = nil, deviceId: String? = nil, sendable: Bool = false) throws -> (sql: String, args: [Data]) {
    if let limit, !(1...256).contains(limit) { throw CloudFailure.invalidRequest }
    let names = domains?.sorted()
    let predicate = (names.map { " AND outbox.domain IN (" + $0.map { _ in "?" }.joined(separator: ",") + ")" } ?? "") +
      (sendable ? " AND NOT EXISTS (SELECT 1 FROM outbox_files f WHERE f.opId=outbox.opId AND NOT EXISTS (SELECT 1 FROM objects o WHERE o.blobId=f.blobId))" +
        // Round 5 S1: later edits of the same record wait behind one parked on the send side.
        // A permanent (id-conflict) park makes nothing wait (round 6 M3).
        " AND NOT EXISTS (SELECT 1 FROM outbox p WHERE p.state='parked' AND p.domain=outbox.domain AND p.entityId=outbox.entityId AND p.rowid<outbox.rowid AND NOT EXISTS (SELECT 1 FROM parked_sends ps WHERE ps.opId=p.opId AND ps.permanent=1))" : "")
    let ownership = deviceId == nil ? "" : " AND NOT EXISTS (SELECT 1 FROM segment_ops so LEFT JOIN segment_bindings sb ON so.segmentId=sb.segmentId WHERE so.opId=outbox.opId AND coalesce(sb.retired,0)=0 AND (sb.deviceId IS NULL OR sb.deviceId!=?))"
    // The queue names records; their content is the single copy in `records` (round 5 item B).
    return ("SELECT r.bytes FROM outbox NOT INDEXED JOIN records r ON r.opId=outbox.opId WHERE outbox.state='queued'" + predicate + ownership + " ORDER BY outbox.rowid" + (limit.map { " LIMIT \($0)" } ?? ""), (names ?? []).map { Data($0.utf8) } + (deviceId.map { [Data($0.utf8)] } ?? []))
  }
  func saveSegment(_ segment: CloudSegment, operationIds: [String], deviceId: String? = nil) throws {
    try transaction {
      let bytes = try CloudSyncCanonical.encode(segment)
      if let old = try rows("SELECT bytes FROM segments WHERE segmentId=?", [Data(segment.descriptor.segmentId.utf8)]).first {
        guard old[0] == bytes else { throw CloudFailure.idReused }
        return
      }
      try execute("INSERT INTO segments(segmentId,bytes,operationIds) VALUES (?,?,?)", [Data(segment.descriptor.segmentId.utf8), bytes, try CloudSyncCanonical.encode(operationIds)])
      if let deviceId { try execute("INSERT INTO segment_bindings(segmentId,deviceId) VALUES (?,?)", [Data(segment.descriptor.segmentId.utf8), Data(deviceId.utf8)]) }
      for id in operationIds { try execute("INSERT INTO segment_ops(segmentId,opId) VALUES (?,?)", [Data(segment.descriptor.segmentId.utf8), Data(id.utf8)]) }
    }
  }
  func bindDevice(_ device: String) throws {
    try transaction {
      let previous: String? = try value("activeOutboxDevice")
      if previous != device {
        if previous != nil { try set("changedOutboxRegistration", device) }
        if try queuedCount() > 0 { try set("deviceReconciliation", device) }
        try set("activeOutboxDevice", device)
      }
    }
  }
  func foreignSegments(device: String, offset: Int = 0) throws -> [(CloudSegment, [String])] {
    try rows("SELECT segments.bytes,operationIds FROM segments LEFT JOIN segment_bindings ON segments.segmentId=segment_bindings.segmentId WHERE receipt IS NULL AND (segment_bindings.deviceId IS NULL OR segment_bindings.deviceId!=?) AND coalesce(retired,0)=0 AND EXISTS (SELECT 1 FROM segment_ops JOIN outbox ON segment_ops.opId=outbox.opId WHERE segment_ops.segmentId=segments.segmentId AND outbox.state='queued') ORDER BY segments.rowid LIMIT 64 OFFSET \(offset)", [Data(device.utf8)]).map {
      (try JSONDecoder().decode(CloudSegment.self, from: $0[0]), try JSONDecoder().decode([String].self, from: $0[1]))
    }
  }
  func retireSegment(_ id: String) throws {
    try execute("INSERT INTO segment_bindings(segmentId,deviceId,retired) VALUES (?,CAST('legacy' AS BLOB),1) ON CONFLICT(segmentId) DO UPDATE SET retired=1", [Data(id.utf8)])
  }
  func unacknowledged(allowSecrets: Bool = true, deviceId: String? = nil) throws -> [(CloudSegment, [String])] {
    var offset = 0
    while true {
      let ownership = deviceId == nil ? "" : " AND EXISTS (SELECT 1 FROM segment_bindings own WHERE own.segmentId=segments.segmentId AND own.deviceId=?)"
      let page = try rows("SELECT bytes,operationIds FROM segments WHERE receipt IS NULL" + ownership + " AND NOT EXISTS (SELECT 1 FROM segment_bindings WHERE segment_bindings.segmentId=segments.segmentId AND retired=1) AND EXISTS (SELECT 1 FROM segment_ops JOIN outbox ON segment_ops.opId=outbox.opId WHERE segment_ops.segmentId=segments.segmentId AND outbox.state='queued') ORDER BY rowid LIMIT 64 OFFSET \(offset)", deviceId.map { [Data($0.utf8)] } ?? [])
      if page.isEmpty { return [] }
      for row in page {
        let segment = try JSONDecoder().decode(CloudSegment.self, from: row[0])
        if allowSecrets || segment.descriptor.storageClass == .brain {
          return [(segment, try JSONDecoder().decode([String].self, from: row[1]))]
        }
      }
      offset += page.count
    }
  }

  func acknowledge(_ segment: CloudSegment, ids: [String], receipt: CloudReceipt) throws {
    guard receipt.segmentId == segment.descriptor.segmentId, receipt.receipt.requestId == segment.descriptor.requestId,
      receipt.receipt.sha256 == segment.descriptor.sha256, receipt.seq > .zero, receipt.seq <= receipt.headSeq else { throw CloudFailure.checksumMismatch }
    try transaction {
      try execute("UPDATE segments SET receipt=? WHERE segmentId=?", [try CloudSyncCanonical.encode(receipt), Data(receipt.segmentId.utf8)])
      for id in ids {
        try execute("UPDATE outbox SET state='acknowledged' WHERE opId=?", [Data(id.utf8)])
        try recordReceipt(id, seq: receipt.seq, committedAt: receipt.receipt.committedAt)
      }
      // 0.23.4 (fault 4a): the engine acknowledges only after reading the committed pack back from the Cloud and
      // comparing it byte for byte (CloudSyncEngine flushQueue). Pieces of files that are kept on this Mac by their
      // own engine leave their content here at once instead of waiting for the feed to bring them back.
      // Never stops the acknowledgement: a release that fails is rolled back alone, said once in the log, and the
      // content stays until the feed's read-back releases it as before.
      do { try releaseAcknowledgedPack(segment, ids: ids) }
      catch { _ = CloudSyncDiagnostics.shared.report("space: releasing a sent pack's content", error) }
    }
  }
  func stage<T: Encodable>(_ id: String, _ journal: T) throws {
    let bytes = try CloudSyncCanonical.encode(journal)
    guard !bytes.isEmpty, bytes.count <= Int32.max else { throw CloudFailure.invalidRequest }
    try transaction {
      if let existing = try rows("SELECT bytes FROM prepare_journal WHERE segmentId=?", [Data(id.utf8)]).first {
        guard existing[0] == bytes else { throw CloudFailure.idReused }
        return
      }
      try execute("INSERT INTO prepare_journal(segmentId,bytes) VALUES (?,zeroblob(CAST(? AS INTEGER)))", [Data(id.utf8), Data(String(bytes.count).utf8)])
      guard let row = try rows("SELECT rowid FROM prepare_journal WHERE segmentId=?", [Data(id.utf8)]).first,
        let rowId = Int64(String(decoding: row[0], as: UTF8.self)) else { throw CloudFailure.unavailable }
      var opened: OpaquePointer?
      let result = sqlite3_blob_open(db, "main", "prepare_journal", "bytes", rowId, 1, &opened)
      guard result == SQLITE_OK, let blob = opened else {
        if let opened { sqlite3_blob_close(opened) }
        throw CloudFailure.unavailable
      }
      defer { sqlite3_blob_close(blob) }
      let first = max(1, bytes.count / 2)
      let firstResult = bytes.withUnsafeBytes { sqlite3_blob_write(blob, $0.baseAddress, Int32(first), 0) }
      guard firstResult == SQLITE_OK else { throw CloudFailure.unavailable }
      // This interruption is inside an unfinished BLOB write, before SQLite commits any journal receipt.
      try journalFault(.duringJournalWrite)
      if first < bytes.count {
        let rest = bytes.withUnsafeBytes { sqlite3_blob_write(blob, $0.baseAddress!.advanced(by: first), Int32(bytes.count - first), Int32(first)) }
        guard rest == SQLITE_OK else { throw CloudFailure.unavailable }
      }
    }
  }
  private func splitCheckpointReceipts() throws {
    if let ready: Bool = try value("split-checkpoint-receipts-v1"), ready { return }
    try transaction {
      let rows = try self.rows("SELECT applied.segmentId,applied.seq,applied.digest FROM applied JOIN metadata ON CAST(metadata.key AS TEXT)='checkpoint-identity:'||CAST(applied.segmentId AS TEXT)")
      for row in rows {
        try execute("INSERT OR IGNORE INTO checkpoint_applied(checkpointId,seq,digest) VALUES (?,?,?)", row)
        try execute("DELETE FROM applied WHERE segmentId=?", [row[0]])
      }
      if let id: String = try value("checkpointId"), let row = try self.rows("SELECT segmentId,seq,digest FROM applied WHERE segmentId=?", [Data(id.utf8)]).first {
        try execute("INSERT OR IGNORE INTO checkpoint_applied(checkpointId,seq,digest) VALUES (?,?,?)", row)
        try execute("DELETE FROM applied WHERE segmentId=?", [row[0]])
      }
      try set("split-checkpoint-receipts-v1", true)
    }
  }
  func checkpointApplied(id: String, seq: CloudSequence, digest: String) throws -> Bool {
    guard let row = try rows("SELECT seq,digest FROM checkpoint_applied WHERE checkpointId=?", [Data(id.utf8)]).first else { return false }
    guard row[0] == Data(seq.rawValue.utf8), row[1] == Data(digest.utf8) else { throw CloudFailure.idReused }
    return true
  }
  func applied(id: String, seq: CloudSequence, digest: String) throws -> Bool {
    if let previous = try rows("SELECT seq,digest FROM applied WHERE segmentId=?", [Data(id.utf8)]).first {
      guard previous[0] == Data(seq.rawValue.utf8), previous[1] == Data(digest.utf8) else { throw CloudFailure.idReused }
      return true
    }
    guard try rows("SELECT segmentId FROM applied WHERE seq=?", [Data(seq.rawValue.utf8)]).isEmpty else { throw CloudFailure.idReused }
    return false
  }
  /// `remembering` excludes records parked for an identity conflict (same id, different bytes), which cannot
  /// enter `records`; every other record of the pack, parked or applied, is kept as cloud-verified.
  /// The first receipt of a record wins (its own commit or the first feed/inventory that carried it).
  func recordReceipt(_ opId: String, seq: CloudSequence, committedAt: Int64?) throws {
    try execute("INSERT OR IGNORE INTO op_receipts(opId,seq,committedAt) VALUES (?,?," + (committedAt == nil ? "NULL" : "CAST(? AS INTEGER)") + ")",
      [Data(opId.utf8), Data(seq.rawValue.utf8)] + (committedAt.map { [Data(String($0).utf8)] } ?? []))
  }
  func finishApply(id: String, seq: CloudSequence, digest: String, operations: [CloudOperation], remembering: [CloudOperation]? = nil, committedAt: Int64? = nil, cursorKey: String = "brainSeq") throws {
    try transaction {
      try remember(remembering ?? operations)
      // Round 5 M1: records left out of `remembering` (identity conflicts) are NOT acknowledged, verified or
      // receipted: this Mac's own record with that id was never sent.
      for op in remembering ?? operations {
        try execute("UPDATE outbox SET state='acknowledged' WHERE opId=?", [Data(op.opId.utf8)])
        try execute("INSERT OR IGNORE INTO verified_ops(opId) VALUES (?)", [Data(op.opId.utf8)])
        try recordReceipt(op.opId, seq: seq, committedAt: committedAt)
      }
      try execute("INSERT OR IGNORE INTO applied(segmentId,seq,digest) VALUES (?,?,?)", [Data(id.utf8), Data(seq.rawValue.utf8), Data(digest.utf8)])
      // The contents page's "Received" time (CloudSyncContents.swift).
      try noteArrival(seq)
      // "none": a parked pack applied later must not move the cursor back.
      if cursorKey != "none" {
        guard ["brainSeq", "secretsSeq"].contains(cursorKey) else { throw CloudFailure.invalidRequest }
        try set(cursorKey, seq)
      }
      try execute("DELETE FROM prepare_journal WHERE segmentId=?", [Data(id.utf8)])
    }
  }
}
