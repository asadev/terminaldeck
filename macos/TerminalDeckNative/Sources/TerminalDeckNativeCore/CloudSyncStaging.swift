import Foundation

/// Bounds on what the sync core keeps on this Mac's disk while it uploads (one place to configure).
/// Sealed bytes are staged in sync.sqlite only until the cloud has them with a read-back receipt.
public struct CloudSyncStaging: Sendable {
  /// Hard bound on sealed bytes staged at any moment (setup pages, live files, inventory objects).
  public var maximumStagedBytes: Int64
  /// No staging while the volume holding sync.sqlite has less free space than this; setup pauses.
  public var minimumFreeBytes: Int64
  /// How long a paused setup waits before looking at free space again.
  public var pauseInterval: Duration
  /// Free bytes on the volume holding `url` (nil when unknown, which never pauses).
  public var freeBytes: @Sendable (URL) -> Int64?
  /// How long after a batch's prepare its files may still start uploading; later files get a fresh batch, so no
  /// ticket (five minutes) expires before finalize.
  public var uploadWindow: Duration
  public init(maximumStagedBytes: Int64 = 256 * 1024 * 1024, minimumFreeBytes: Int64 = 5 * 1024 * 1024 * 1024,
              pauseInterval: Duration = .seconds(60), freeBytes: @escaping @Sendable (URL) -> Int64? = CloudSyncStaging.volumeFreeBytes,
              uploadWindow: Duration = .seconds(180)) {
    self.maximumStagedBytes = maximumStagedBytes
    self.minimumFreeBytes = minimumFreeBytes
    self.pauseInterval = pauseInterval
    self.freeBytes = freeBytes
    self.uploadWindow = uploadWindow
  }
  public static func volumeFreeBytes(_ url: URL) -> Int64? {
    (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
  }
}

extension CloudSyncStore {
  /// Sealed bytes currently held in `objects` (setup pages, live files, inventory objects, downloads).
  /// Round 6 S5: bytes that can never leave do not count against the bound: files named only by records that are
  /// retired (older saved-password key) or parked for good (an id conflict). They stay on disk, kept and reported
  /// with their records, but they no longer refuse new edits or setup pages.
  func stagedBytes() throws -> Int64 {
    Int64(String(decoding: try rows("""
      SELECT coalesce(sum(length(o.bytes)),0) FROM objects o WHERE NOT (
        EXISTS (SELECT 1 FROM outbox_files f WHERE f.blobId=o.blobId
          AND (f.opId IN (SELECT opId FROM retired_sends) OR f.opId IN (SELECT opId FROM parked_sends WHERE permanent=1)))
        AND NOT EXISTS (SELECT 1 FROM outbox_files f JOIN outbox q ON q.opId=f.opId WHERE f.blobId=o.blobId
          AND q.state IN ('queued','parked') AND q.opId NOT IN (SELECT opId FROM parked_sends WHERE permanent=1)))
      """)[0][0], as: UTF8.self)) ?? 0
  }
  /// Drops the sealed bytes of objects the cloud holds with a read-back receipt, keeping descriptor and receipt
  /// (the references and hashes exact replay and later reads need). `except` keeps objects still needed locally.
  func dropReceiptedBytes(_ blobIds: [String]? = nil, except keep: Set<String> = []) throws {
    let candidates = try rows("SELECT blobId FROM objects WHERE length(bytes)>0 AND receipt IS NOT NULL AND length(receipt)>0").map { String(decoding: $0[0], as: UTF8.self) }
    let wanted = blobIds.map(Set.init)
    try transaction {
      for id in candidates where !keep.contains(id) && (wanted?.contains(id) ?? true) {
        try execute("UPDATE objects SET bytes=X'' WHERE blobId=?", [Data(id.utf8)])
      }
    }
  }
  /// Handoff copies given to adapters during an apply; nothing may keep them after the operation returns.
  func removeHandoffs() {
    let directory = root.appendingPathComponent("sealed", isDirectory: true)
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
    for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
  }
  /// Launch reconciliation after a crash: received bytes are dropped; unsent sealed bytes are kept only while a
  /// queued or parked record, or the unfinished setup cut, still references them; anything else is removed.
  func reconcileStaging(keep: Set<String>) throws {
    removeHandoffs()
    try dropReceiptedBytes(except: keep)
    let unfinished: String? = try value("bootstrapInProgress")
    // Retired saved-password records keep their files until lane V confirms them (round 6 S6).
    var referenced = Set(try rows("SELECT DISTINCT f.blobId FROM outbox_files f JOIN outbox o ON o.opId=f.opId WHERE o.state IN ('queued','parked','retired')").map { String(decoding: $0[0], as: UTF8.self) })
    // Saved-password setup files whose upload was refused wait by id until sent (round 6 S4).
    referenced.formUnion((try value("protectedWaitingFiles") as [String]?) ?? [])
    // Setup files of a baseline that is still going up after its setup ended (no first upload).
    referenced.formUnion((try value("feedBaselineFiles") as [String]?) ?? [])
    if let unfinished {
      referenced.formUnion(try rows("SELECT blobId FROM snapshot_files WHERE snapshotId=?", [Data(unfinished.utf8)]).map { String(decoding: $0[0], as: UTF8.self) })
      // The unfinished setup's sealed inventory objects (leaves, nodes, root) are named by their content keys;
      // a crash between their upload and finalize must resume the SAME objects, not seal new ones.
      for (_, value) in try prefixed("inventory:") { if let id = try? JSONDecoder().decode(String.self, from: value) { referenced.insert(id) } }
    }
    let orphans = try rows("SELECT blobId FROM objects WHERE length(bytes)>0 AND (receipt IS NULL OR length(receipt)=0)").map { String(decoding: $0[0], as: UTF8.self) }
      .filter { !referenced.contains($0) && !keep.contains($0) }
    try transaction { for id in orphans { try execute("DELETE FROM objects WHERE blobId=?", [Data(id.utf8)]) } }
  }
  /// A pack this Mac committed, read back and applied back keeps its descriptor and receipt, not its ciphertext.
  func stripSettledSegments() throws {
    let settled = try rows("SELECT segmentId,bytes FROM segments WHERE receipt IS NOT NULL AND length(bytes)>4096 AND segmentId IN (SELECT segmentId FROM applied)")
    try transaction {
      for row in settled {
        let segment = try JSONDecoder().decode(CloudSegment.self, from: row[1])
        try execute("UPDATE segments SET bytes=? WHERE segmentId=?", [try CloudSyncCanonical.encode(CloudSegment(descriptor: segment.descriptor, ciphertext: "")), row[0]])
      }
    }
  }
}
