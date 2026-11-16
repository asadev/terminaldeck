import Foundation
import CryptoKit

extension CloudSyncStore {
  func snapshotRows(_ snapshot: String, domain: String, after: Int64 = 0, through: Int64 = Int64.max, limit: Int = 64) throws -> [(Int64, Data)] {
    guard (1...256).contains(limit) else { throw CloudFailure.invalidRequest }
    // A staging row without bytes refers to the record's single copy in `records` (round 5 item B).
    return try rows("SELECT s.rowid,CASE WHEN length(s.bytes)>0 THEN s.bytes ELSE r.bytes END FROM snapshot_records s LEFT JOIN records r ON r.opId=s.opId WHERE s.snapshotId=? AND s.domain=? AND s.rowid>CAST(? AS INTEGER) AND s.rowid<=CAST(? AS INTEGER) ORDER BY s.rowid LIMIT \(limit)",
      [Data(snapshot.utf8), Data(domain.utf8), Data(String(after).utf8), Data(String(through).utf8)]).map {
        guard let index = Int64(String(decoding: $0[0], as: UTF8.self)) else { throw CloudFailure.invalidRequest }
        return (index, $0[1])
      }
  }
  /// `keepBytes: false` for records that already sit in `records` (setup cut, verified inventory): the staging
  /// row then only names the record, so its content is stored once.
  func retainSnapshot(_ snapshot: String, operations: [CloudOperation], keepBytes: Bool = true) throws {
    for op in operations {
      try execute("INSERT OR IGNORE INTO snapshot_sources(snapshotId,opId,sourceId) VALUES (?,?,?)", [Data(snapshot.utf8), Data(op.opId.utf8), Data(op.source.sourceId.utf8)])
      try execute("INSERT OR IGNORE INTO snapshot_entities(snapshotId,opId,domain,entityId) VALUES (?,?,?,?)", [Data(snapshot.utf8), Data(op.opId.utf8), Data(op.domain.utf8), Data(op.entityId.utf8)])
      for parent in op.parents {
        try execute("INSERT OR IGNORE INTO snapshot_links(snapshotId,child,parent) VALUES (?,?,?)", [Data(snapshot.utf8), Data(op.opId.utf8), Data(parent.utf8)])
      }
      let bytes = try CloudSyncCanonical.encode(op)
      if let old = try rows("SELECT bytes FROM snapshot_records WHERE snapshotId=? AND opId=?", [Data(snapshot.utf8), Data(op.opId.utf8)]).first {
        guard old[0].isEmpty || old[0] == bytes else { throw CloudFailure.idReused }
      } else {
        // A reference-only row is allowed only while `records` holds this record's full content; if it holds
        // only the skeleton (settled earlier), the staging keeps the content the adapter just supplied.
        let stored = try rows("SELECT bytes FROM records WHERE opId=?", [Data(op.opId.utf8)]).first?[0]
        let single = !keepBytes && stored == bytes
        try execute("INSERT INTO snapshot_records(snapshotId,opId,domain,bytes) VALUES (?,?,?,?)", [Data(snapshot.utf8), Data(op.opId.utf8), Data(op.domain.utf8), single ? Data() : bytes])
      }
    }
  }
  func snapshotSummary(_ snapshot: String, domain: String, after: Int64 = 0, through: Int64 = Int64.max) throws -> (records: Int, bytes: Int64, digest: String) {
    var hash = SHA256(), count = 0, bytes: Int64 = 2, cursor = after
    hash.update(data: Data("[".utf8))
    while true {
      let page = try snapshotRows(snapshot, domain: domain, after: cursor, through: through)
      if page.isEmpty { break }
      for (index, row) in page {
        if count > 0 { hash.update(data: Data(",".utf8)); bytes += 1 }
        hash.update(data: row); bytes += Int64(row.count); count += 1; cursor = index
      }
    }
    hash.update(data: Data("]".utf8))
    return (count, bytes, hash.finalize().map { String(format: "%02x", $0) }.joined())
  }
  func stageVerifiedInventory(_ snapshot: String) throws {
    try transaction {
      try execute("INSERT OR IGNORE INTO snapshot_records(snapshotId,opId,domain,bytes) SELECT ?,records.opId,record_entities.domain,X'' FROM records JOIN verified_ops ON records.opId=verified_ops.opId JOIN record_entities ON records.opId=record_entities.opId ORDER BY records.rowid", [Data(snapshot.utf8)])
    }
  }
  func linkSnapshotFiles(_ snapshot: String) throws {
    // Decode bounded pages to walk actual references. There is no record/file cross product.
    var cursor: Int64 = 0
    while true {
      let page = try rows("SELECT s.rowid,CASE WHEN length(s.bytes)>0 THEN s.bytes ELSE r.bytes END FROM snapshot_records s LEFT JOIN records r ON r.opId=s.opId WHERE s.snapshotId=? AND s.rowid>CAST(? AS INTEGER) ORDER BY s.rowid LIMIT 64", [Data(snapshot.utf8), Data(String(cursor).utf8)])
      if page.isEmpty { break }
      for row in page {
        let operation = try JSONDecoder().decode(CloudOperation.self, from: row[1])
        try linkDependencies([operation], files: [], associations: [])
        guard let next = Int64(String(decoding: row[0], as: UTF8.self)) else { throw CloudFailure.invalidRequest }
        cursor = next
      }
    }
    // A producer can identify a specific operation or a source with exactly one root operation.
    try execute("INSERT OR IGNORE INTO outbox_files(opId,blobId) SELECT s.opId,f.blobId FROM snapshot_sources s JOIN retained_files f ON f.sourceId=s.opId JOIN snapshot_files sf ON sf.blobId=f.blobId AND sf.snapshotId=s.snapshotId WHERE s.snapshotId=?", [Data(snapshot.utf8)])
    try execute("INSERT OR IGNORE INTO outbox_files(opId,blobId) SELECT s.opId,f.blobId FROM (SELECT sourceId,min(opId) AS opId FROM snapshot_sources WHERE snapshotId=? GROUP BY sourceId HAVING count(*)=1) s JOIN retained_files f ON f.sourceId=s.sourceId JOIN snapshot_files sf ON sf.blobId=f.blobId WHERE sf.snapshotId=?", [Data(snapshot.utf8), Data(snapshot.utf8)])
  }
}

extension CloudSyncStore {
  /// Removes a finished staging (setup cut, verified inventory, imported inventory): its rows were only needed
  /// to build or check one inventory.
  func dropStaging(_ snapshot: String) throws {
    try transaction {
      for table in ["snapshot_records", "snapshot_entities", "snapshot_links", "snapshot_sources", "snapshot_files"] {
        try execute("DELETE FROM " + table + " WHERE snapshotId=?", [Data(snapshot.utf8)])
      }
    }
  }
  /// The identity-only form of a record: every field except the payload content, whose hash stays.
  static func skeleton(_ op: CloudOperation) -> CloudOperation {
    .init(v: op.v, opId: op.opId, originDevice: op.originDevice, domain: op.domain, entityId: op.entityId, revision: op.revision,
      parents: op.parents, kind: op.kind, projectId: op.projectId, rootId: op.rootId, source: op.source, createdAt: op.createdAt,
      payload: CloudValue(.null), payloadHash: op.payloadHash)
  }
  /// Round 5 item B: once a record is settled (this Mac's own record read back in Cloud, or another device's
  /// record applied), and this Mac holds an imported inventory (so it never builds an inventory from these rows),
  /// its content leaves `records`: the row keeps the skeleton (id, parents, author, source, hashes). Queued, held,
  /// parked, retired and unfinished-setup records keep their content.
  func stubSettledRecords() throws {
    // Lean first version: with no first upload ("feed" baseline) no inventory is ever built from these rows.
    let imported: Bool = try value("inventoryVerified") ?? false
    let baseline: String? = try value("baseline")
    guard imported || baseline == "feed", (try value("bootstrapInProgress") as String?) == nil else { return }
    var cursor: Int64 = 0
    while true {
      let page = try rows("""
        SELECT r.rowid,r.opId,r.bytes FROM records r JOIN verified_ops v ON v.opId=r.opId
        WHERE r.rowid>CAST(? AS INTEGER) AND length(r.bytes)>0
          AND NOT EXISTS (SELECT 1 FROM record_stubs m WHERE m.opId=r.opId)
          AND NOT EXISTS (SELECT 1 FROM parked_ops p WHERE p.opId=r.opId)
          AND NOT EXISTS (SELECT 1 FROM outbox o WHERE o.opId=r.opId AND o.state IN ('queued','parked','retired'))
        ORDER BY r.rowid LIMIT 256
        """, [Data(String(cursor).utf8)])
      if page.isEmpty { return }
      try transaction {
        for row in page {
          let op = try JSONDecoder().decode(CloudOperation.self, from: row[2])
          let stub = try CloudSyncCanonical.encode(Self.skeleton(op))
          if stub != row[2] { try execute("UPDATE records SET bytes=? WHERE opId=?", [stub, row[1]]) }
          // Marked once (round 6 S2): later passes do not read or decode this row again.
          try execute("INSERT OR IGNORE INTO record_stubs(opId) VALUES (?)", [row[1]])
        }
      }
      guard let last = page.last, let next = Int64(String(decoding: last[0], as: UTF8.self)) else { return }
      cursor = next
    }
  }
}

extension CloudSyncStore {
  /// The queue's last row, and how many memory records up to it are still queued: what a setup that ends without
  /// a first upload leaves to go up as ordinary packs (its baseline).
  func baselineRows(domains: Set<String>) throws -> (last: Int64, queued: Int) {
    let row = try rows("SELECT coalesce(max(rowid),0) FROM outbox")
    let last = Int64(String(decoding: row[0][0], as: UTF8.self)) ?? 0
    return (last, try baselineQueued(through: last, domains: domains))
  }
  func baselineQueued(through last: Int64, domains: Set<String>) throws -> Int {
    guard !domains.isEmpty else { return 0 }
    let names = domains.sorted()
    let row = try rows("SELECT count(*) FROM outbox WHERE state='queued' AND rowid<=CAST(? AS INTEGER) AND domain IN (" + names.map { _ in "?" }.joined(separator: ",") + ")",
      [Data(String(last).utf8)] + names.map { Data($0.utf8) })
    return Int(String(decoding: row[0][0], as: UTF8.self)) ?? 0
  }
  /// T4: the baseline's records still queued, of every kind except `excluding` (an engine without memory kinds).
  func baselineQueued(through last: Int64, excluding: Set<String>) throws -> Int {
    try baselineCount(state: "queued", through: last, excluding: excluding)
  }
  /// T4: the baseline's records parked on the send side (refused, or waiting behind a refused one): not sent.
  func baselineParked(through last: Int64, excluding: Set<String>) throws -> Int {
    try baselineCount(state: "parked", through: last, excluding: excluding)
  }
  private func baselineCount(state: String, through last: Int64, excluding: Set<String>) throws -> Int {
    let names = excluding.sorted()
    let filter = names.isEmpty ? "" : " AND domain NOT IN (" + names.map { _ in "?" }.joined(separator: ",") + ")"
    let row = try rows("SELECT count(*) FROM outbox WHERE state=? AND rowid<=CAST(? AS INTEGER)" + filter,
      [Data(state.utf8), Data(String(last).utf8)] + names.map { Data($0.utf8) })
    return Int(String(decoding: row[0][0], as: UTF8.self)) ?? 0
  }
}
