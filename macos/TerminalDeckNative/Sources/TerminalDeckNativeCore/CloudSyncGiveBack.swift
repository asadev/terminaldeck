import Foundation
import SQLite3

/// 0.23.4 (Mac mini, 20-21 Nov): "project folders travel" filled `sync.sqlite` with 7+ GB of file pieces waiting to go up,
/// kept the content of pieces the Cloud already holds, and the file never gave the space back. This is the giving back.
extension CloudSyncStore {
  /// Kinds whose records are pieces of files kept on this Mac by their own engine (his project folders: the file and
  /// the engine's retained copy). Once the Cloud holds such a piece, read back and compared byte for byte before it is
  /// acknowledged, this Mac needs only its skeleton (id, parents, hashes).
  public static let releasedOnAcknowledge: Set<String> = [CloudBrainFilesFormat.domain("I26")]

  /// The same rule as `stubSettledRecords`: nothing is released while an inventory could still be built from these rows.
  func releaseAllowed() throws -> Bool {
    let imported: Bool = try value("inventoryVerified") ?? false
    let baseline: String? = try value("baseline")
    let setupRunning: String? = try value("bootstrapInProgress")
    return (imported || baseline == "feed") && setupRunning == nil
  }
  /// Leaves only the skeleton of these acknowledged records of `releasedOnAcknowledge` kinds. Queued, parked, held or
  /// retired records, records of other kinds and records already released are left as they are.
  func releaseAcknowledged(_ ids: [String]) throws {
    guard !ids.isEmpty, try releaseAllowed() else { return }
    let kinds = Self.releasedOnAcknowledge.sorted()
    let inKinds = "(" + kinds.map { _ in "?" }.joined(separator: ",") + ")"
    try transaction {
      for id in ids {
        guard let row = try rows("""
          SELECT r.bytes FROM records r JOIN outbox o ON o.opId=r.opId
          WHERE r.opId=? AND o.state='acknowledged' AND o.domain IN \(inKinds) AND length(r.bytes)>0
            AND NOT EXISTS (SELECT 1 FROM record_stubs m WHERE m.opId=r.opId)
            AND NOT EXISTS (SELECT 1 FROM parked_ops p WHERE p.opId=r.opId)
          """, [Data(id.utf8)] + kinds.map { Data($0.utf8) }).first else { continue }
        let op = try JSONDecoder().decode(CloudOperation.self, from: row[0])
        let stub = try CloudSyncCanonical.encode(Self.skeleton(op))
        if stub != row[0] { try execute("UPDATE records SET bytes=? WHERE opId=?", [stub, Data(id.utf8)]) }
        try execute("INSERT OR IGNORE INTO record_stubs(opId) VALUES (?)", [Data(id.utf8)])
      }
    }
  }
  /// A pack of released kinds only, just acknowledged: its records leave their content and the pack its sealed copy
  /// (the Cloud holds the same bytes; they were read back and compared before the acknowledgement). Without this, the
  /// sealed copy of every sent pack stayed until the feed brought it back, which a long upload never let happen.
  func releaseAcknowledgedPack(_ segment: CloudSegment, ids: [String]) throws {
    let kinds = Set(segment.descriptor.domains)
    guard !kinds.isEmpty, kinds.isSubset(of: Self.releasedOnAcknowledge), try releaseAllowed() else { return }
    // One savepoint: records and pack are released together or not at all.
    try transaction {
      try releaseAcknowledged(ids)
      if !segment.ciphertext.isEmpty {
        try execute("UPDATE segments SET bytes=? WHERE segmentId=?",
          [try CloudSyncCanonical.encode(CloudSegment(descriptor: segment.descriptor, ciphertext: "")), Data(segment.descriptor.segmentId.utf8)])
      }
    }
  }
  /// The feed brings back this Mac's own pack of released kinds whose sealed copy left at its acknowledgement: it is
  /// settled exactly as an applied pack would be (verified, receipted, position recorded) without downloading it
  /// again, because this Mac made it, the Cloud holds it byte for byte, and its records are here. false = not such a
  /// pack: the ordinary path opens and applies it.
  func settleOwnReleasedPack(seq: CloudSequence, segmentId: String, sha256: String, committedAt: Int64?, cursorKey: String) throws -> Bool {
    guard let row = try rows("SELECT bytes,receipt,operationIds FROM segments WHERE segmentId=?", [Data(segmentId.utf8)]).first, !row[1].isEmpty else { return false }
    let segment = try JSONDecoder().decode(CloudSegment.self, from: row[0])
    let receipt = try JSONDecoder().decode(CloudReceipt.self, from: row[1])
    let kinds = Set(segment.descriptor.domains)
    guard segment.ciphertext.isEmpty, !kinds.isEmpty, kinds.isSubset(of: Self.releasedOnAcknowledge),
      segment.descriptor.sha256 == sha256, receipt.seq == seq else { return false }
    let ids = try JSONDecoder().decode([String].self, from: row[2])
    for id in ids {
      if try rows("SELECT 1 FROM outbox WHERE opId=? AND state='acknowledged'", [Data(id.utf8)]).isEmpty { return false }
    }
    try transaction {
      for id in ids {
        try execute("INSERT OR IGNORE INTO verified_ops(opId) VALUES (?)", [Data(id.utf8)])
        try recordReceipt(id, seq: seq, committedAt: committedAt)
      }
      try execute("INSERT OR IGNORE INTO applied(segmentId,seq,digest) VALUES (?,?,?)", [Data(segmentId.utf8), Data(seq.rawValue.utf8), Data(sha256.utf8)])
      try noteArrival(seq)
      if cursorKey != "none" {
        guard ["brainSeq", "secretsSeq"].contains(cursorKey) else { throw CloudFailure.invalidRequest }
        try set(cursorKey, seq)
      }
    }
    return true
  }
  /// Once per store: the pieces an earlier build left with their content after the Cloud acknowledged them (10,407 on
  /// the Mac mini at 23:30 on 20 Nov). From 0.23.4 on, every acknowledgement releases at once, so this runs only once.
  /// Returns how many records it looked at.
  @discardableResult
  func releaseAcknowledgedBacklog() throws -> Int {
    if (try value("releasedAcknowledged-v1") as Bool?) == true { return 0 }
    guard try releaseAllowed() else { return 0 }
    let kinds = Self.releasedOnAcknowledge.sorted()
    let inKinds = "(" + kinds.map { _ in "?" }.joined(separator: ",") + ")"
    var cursor: Int64 = 0, seen = 0
    while true {
      let page = try rows("SELECT rowid,opId FROM outbox WHERE state='acknowledged' AND domain IN \(inKinds) AND rowid>CAST(? AS INTEGER) ORDER BY rowid LIMIT 256",
        kinds.map { Data($0.utf8) } + [Data(String(cursor).utf8)])
      guard let last = page.last, let next = Int64(String(decoding: last[0], as: UTF8.self)) else { break }
      try releaseAcknowledged(page.map { String(decoding: $0[1], as: UTF8.self) })
      seen += page.count; cursor = next
    }
    // Their packs' sealed copies too (acknowledged, still holding ciphertext, of released kinds only).
    var segmentCursor: Int64 = 0
    while true {
      let page = try rows("SELECT rowid,bytes,operationIds FROM segments WHERE receipt IS NOT NULL AND length(bytes)>4096 AND rowid>CAST(? AS INTEGER) ORDER BY rowid LIMIT 64",
        [Data(String(segmentCursor).utf8)])
      guard let last = page.last, let next = Int64(String(decoding: last[0], as: UTF8.self)) else { break }
      for row in page {
        let segment = try JSONDecoder().decode(CloudSegment.self, from: row[1])
        let ids = try JSONDecoder().decode([String].self, from: row[2])
        // Only when every record of the pack is acknowledged (a receipt always acknowledges them all together).
        guard try ids.allSatisfy({ try !rows("SELECT 1 FROM outbox WHERE opId=? AND state='acknowledged'", [Data($0.utf8)]).isEmpty }) else { continue }
        try transaction { try releaseAcknowledgedPack(segment, ids: ids) }
      }
      segmentCursor = next
    }
    try set("releasedAcknowledged-v1", true)
    return seen
  }

  /// The file's size and how much of it holds nothing (pages SQLite freed and keeps for reuse), in bytes.
  func fileSpace() throws -> (file: Int64, free: Int64) {
    func number(_ pragma: String) throws -> Int64 { Int64(String(decoding: try rows("PRAGMA " + pragma)[0][0], as: UTF8.self)) ?? 0 }
    let page = try number("page_size"), pages = try number("page_count"), free = try number("freelist_count")
    return (pages * page, free * page)
  }
  /// Rewrites `sync.sqlite` without its empty pages and gives them back to the disk (VACUUM, then a checkpoint that
  /// empties the write-ahead log). Runs on its OWN connection, so the store's lock (and every reader behind it, the
  /// service clock among them) is never held; the store's own writes wait up to 5 s and are retried as any busy write.
  /// Needs free disk of about twice the live data (a temporary copy and the log); the caller checks for that plus the
  /// 5 GB floor.
  public static func compact(root: URL) throws {
    var opened: OpaquePointer?
    guard sqlite3_open_v2(root.appendingPathComponent("sync.sqlite").path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let db = opened else {
      if let opened { sqlite3_close(opened) }
      throw CloudFailure.unavailable
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 30_000)
    for sql in ["PRAGMA synchronous=FULL", "PRAGMA fullfsync=ON", "PRAGMA checkpoint_fullfsync=ON", "VACUUM"] {
      guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw CloudSyncCompactFailure(step: sql, detail: String(cString: sqlite3_errmsg(db)))
      }
    }
    // The rewritten pages sit in the write-ahead log until a checkpoint copies them in and the file is cut to size.
    // A reader that holds an older snapshot makes this one partial: the store's own checkpoints finish it later.
    var logFrames: Int32 = 0, copied: Int32 = 0
    let checkpoint = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &copied)
    if checkpoint != SQLITE_OK {
      CloudSyncDiagnostics.shared.info("space: sync.sqlite was rewritten; its log file is emptied at a later checkpoint (\(String(cString: sqlite3_errmsg(db))))")
    }
  }
}

/// Which step of a compaction failed and what SQLite said (said in the log; the old file stays whole).
struct CloudSyncCompactFailure: Error, CustomStringConvertible {
  let step: String, detail: String
  var description: String { "compaction stopped at \(step): \(detail)" }
}
