import Foundation

// Device trust: the sync store's own rows for packs it did not apply. Trust itself is never stored here: the
// trusted list lives with lane A (CloudDeviceTrustPort) and is asked at the moment of applying.

extension CloudSyncStore {
  /// Counters are for the screen only and stop here.
  static let maximumHeldCount = 1_000_000
  /// Kinds of content listed per waiting device; further kinds are counted in the totals only.
  static let maximumHeldDomains = 64

  private func integer(_ data: Data) -> Int { Int(String(decoding: data, as: UTF8.self)) ?? 0 }
  private func sequence(_ data: Data) throws -> CloudSequence? {
    if data.isEmpty { return nil }
    return try CloudSequence(rawValue: String(decoding: data, as: UTF8.self))
  }

  // MARK: HELD (waiting) devices

  struct HeldRow: Sendable {
    let deviceId: String
    let firstSeq: CloudSequence?
    let firstSecretsSeq: CloudSequence?
    let packs: Int
    let operations: Int
    /// domain -> [packs, operations], as the service's feed entries reported them.
    let byDomain: [String: [Int]]
    let firstSeenAt: Int64
    func first(_ storageClass: CloudStorageClass) -> CloudSequence? { storageClass == .brain ? firstSeq : firstSecretsSeq }
  }
  private func heldRow(from row: [Data]) throws -> HeldRow {
    HeldRow(deviceId: String(decoding: row[0], as: UTF8.self), firstSeq: try sequence(row[1]), firstSecretsSeq: try sequence(row[2]),
      packs: integer(row[3]), operations: integer(row[4]), byDomain: (try? JSONDecoder().decode([String: [Int]].self, from: row[5])) ?? [:],
      firstSeenAt: Int64(String(decoding: row[6], as: UTF8.self)) ?? 0)
  }
  private static let heldColumns = "deviceId,firstHeldSeq,firstHeldSecretsSeq,packs,operations,byDomain,firstSeenAt"
  func heldRows() throws -> [HeldRow] {
    try rows("SELECT " + Self.heldColumns + " FROM untrusted_devices ORDER BY firstSeenAt,deviceId").map { try heldRow(from: $0) }
  }
  func heldRow(_ deviceId: String) throws -> HeldRow? {
    try rows("SELECT " + Self.heldColumns + " FROM untrusted_devices WHERE deviceId=?", [Data(deviceId.utf8)]).first.map { try heldRow(from: $0) }
  }
  private func writeHeld(_ row: HeldRow) throws {
    try execute("INSERT INTO untrusted_devices(" + Self.heldColumns + ") VALUES (?,?,?,CAST(? AS INTEGER),CAST(? AS INTEGER),?,CAST(? AS INTEGER)) ON CONFLICT(deviceId) DO UPDATE SET firstHeldSeq=excluded.firstHeldSeq,firstHeldSecretsSeq=excluded.firstHeldSecretsSeq,packs=excluded.packs,operations=excluded.operations,byDomain=excluded.byDomain", [
      Data(row.deviceId.utf8), Data((row.firstSeq?.rawValue ?? "").utf8), Data((row.firstSecretsSeq?.rawValue ?? "").utf8),
      Data(String(row.packs).utf8), Data(String(row.operations).utf8), try CloudSyncCanonical.encode(row.byDomain), Data(String(row.firstSeenAt).utf8)])
  }
  /// One more waiting pack of `deviceId` at feed position `seq`. Only the device's row changes: its first waiting
  /// position for that class and its counters. Nothing of the pack itself is stored. `domains` and `operations`
  /// are the service's words about an untrusted pack, so they are bounded here.
  /// At most `heldRowLimit` devices are listed. Past that a further unknown device gets no row: its pack is
  /// still never applied and the position still moves, and only a count and the lowest unlisted position per
  /// class are kept, from which a release for a device without a row reads the feed again. Returns false then.
  @discardableResult
  func hold(deviceId: String, seq: CloudSequence, storageClass: CloudStorageClass, domains: [String], operations: Int) throws -> Bool {
    try transaction { () throws -> Bool in
      let old = try heldRow(deviceId)
      if old == nil, try heldRowCount() >= heldRowLimit {
        let beyond: Int = try value("heldBeyondList") ?? 0
        try set("heldBeyondList", min(Self.maximumHeldCount, beyond + 1))
        let first: CloudSequence? = try value("heldBeyondFirst:" + storageClass.rawValue)
        try set("heldBeyondFirst:" + storageClass.rawValue, min(first ?? seq, seq))
        return false
      }
      let added = min(max(0, operations), Self.maximumHeldCount)
      var counts = old?.byDomain ?? [:]
      for domain in Set(domains.map({ CloudWire.isValidDomainName($0) ? $0 : "other" })) {
        if counts[domain] == nil, counts.count >= Self.maximumHeldDomains { continue }
        let before = counts[domain] ?? [0, 0]
        counts[domain] = [min(Self.maximumHeldCount, (before.first ?? 0) + 1), min(Self.maximumHeldCount, (before.last ?? 0) + added)]
      }
      var first = old?.firstSeq, firstSecrets = old?.firstSecretsSeq
      if storageClass == .brain { first = min(first ?? seq, seq) } else { firstSecrets = min(firstSecrets ?? seq, seq) }
      try writeHeld(HeldRow(deviceId: deviceId, firstSeq: first, firstSecretsSeq: firstSecrets,
        packs: min(Self.maximumHeldCount, (old?.packs ?? 0) + 1), operations: min(Self.maximumHeldCount, (old?.operations ?? 0) + added),
        byDomain: counts, firstSeenAt: old?.firstSeenAt ?? CloudSyncBytes.now()))
      return true
    }
  }
  func heldRowCount() throws -> Int { integer(try rows("SELECT count(*) FROM untrusted_devices")[0][0]) }
  /// A few listed devices after `deviceId`, in key order: the pull asks the trusted list about these, in rotation.
  func heldDeviceIds(after deviceId: String, limit: Int) throws -> [String] {
    try rows("SELECT deviceId FROM untrusted_devices WHERE deviceId>? ORDER BY deviceId LIMIT \(max(0, limit))", [Data(deviceId.utf8)]).map { String(decoding: $0[0], as: UTF8.self) }
  }
  /// Devices whose release has begun and not ended (found through the partial index, without the other rows).
  func releasingDevices() throws -> [String] {
    try rows("SELECT deviceId FROM untrusted_devices WHERE releasing=1").map { String(decoding: $0[0], as: UTF8.self) }
  }
  func setReleasing(_ devices: Set<String>, _ on: Bool) throws {
    try transaction {
      for device in devices { try execute("UPDATE untrusted_devices SET releasing=\(on ? 1 : 0) WHERE deviceId=?", [Data(device.utf8)]) }
    }
  }
  /// The lowest position of a waiting pack that got no row (past the list), per class.
  func unlistedHeldFirst(_ storageClass: CloudStorageClass) throws -> CloudSequence? { try value("heldBeyondFirst:" + storageClass.rawValue) }
  /// A device that has no row although packs past the list may be its own: it gets a row from the lowest
  /// unlisted positions, so its release reads the feed again from there and nothing of it is lost. False when
  /// nothing was ever past the list (then a device without a row has nothing waiting).
  func adoptUnlisted(_ deviceId: String) throws -> Bool {
    try transaction { () throws -> Bool in
      if try heldRow(deviceId) != nil { return true }
      let first = try unlistedHeldFirst(.brain), firstSecrets = try unlistedHeldFirst(.secrets)
      guard first != nil || firstSecrets != nil else { return false }
      try writeHeld(HeldRow(deviceId: deviceId, firstSeq: first, firstSecretsSeq: firstSecrets, packs: 0, operations: 0, byDomain: [:],
        firstSeenAt: CloudSyncBytes.now()))
      return true
    }
  }
  /// A release pass handled the device's pack just before `next`: its next waiting position for that class moves
  /// forward (so a restart resumes there) and its counters go down, never below zero.
  func released(deviceId: String, storageClass: CloudStorageClass, next: CloudSequence, domains: [String], operations: Int) throws {
    try transaction {
      guard let old = try heldRow(deviceId) else { return }
      let done = min(max(0, operations), Self.maximumHeldCount)
      var counts = old.byDomain
      for domain in Set(domains.map({ CloudWire.isValidDomainName($0) ? $0 : "other" })) {
        guard let before = counts[domain] else { continue }
        let left = [max(0, (before.first ?? 0) - 1), max(0, (before.last ?? 0) - done)]
        if left[0] == 0 { counts.removeValue(forKey: domain) } else { counts[domain] = left }
      }
      try writeHeld(HeldRow(deviceId: deviceId, firstSeq: storageClass == .brain ? next : old.firstSeq,
        firstSecretsSeq: storageClass == .secrets ? next : old.firstSecretsSeq, packs: max(0, old.packs - 1),
        operations: max(0, old.operations - done), byDomain: counts, firstSeenAt: old.firstSeenAt))
    }
  }
  /// Sets a device's first waiting position for one class (trust was removed in the middle of a pass), or clears
  /// it with nil (the pass reached this Mac's position). A row with no waiting position left is removed.
  func setHeldPosition(deviceId: String, storageClass: CloudStorageClass, to position: CloudSequence?) throws {
    try transaction {
      guard let old = try heldRow(deviceId) else { return }
      let first = storageClass == .brain ? position : old.firstSeq
      let firstSecrets = storageClass == .secrets ? position : old.firstSecretsSeq
      if first == nil, firstSecrets == nil {
        try execute("DELETE FROM untrusted_devices WHERE deviceId=?", [Data(deviceId.utf8)])
        return
      }
      try writeHeld(HeldRow(deviceId: deviceId, firstSeq: first, firstSecretsSeq: firstSecrets, packs: old.packs, operations: old.operations,
        byDomain: old.byDomain, firstSeenAt: old.firstSeenAt))
    }
  }
  /// Drops what was prepared for a pack (its journal and its per-record journals): the pack was prepared while
  /// its device was trusted and the device is not trusted at the moment of applying.
  func dropPrepared(_ segmentId: String) throws {
    guard (try? CloudSyncBytes.transportID(segmentId)) != nil else { return }
    try execute("DELETE FROM prepare_journal WHERE segmentId=? OR (segmentId>=? AND segmentId<?)",
      [Data(segmentId.utf8), Data((segmentId + ":").utf8), Data((segmentId + ";").utf8)])
  }

  // MARK: REFUSED packs

  /// Records a refused pack once per position; judging the same position again only counts the check.
  func recordRefused(seq: CloudSequence, storageClass: CloudStorageClass, deviceId: String?, reason: String) throws {
    try transaction {
      let key = Data(seq.rawValue.utf8)
      if try !rows("SELECT seq FROM refused_packs WHERE seq=?", [key]).isEmpty {
        try execute("UPDATE refused_packs SET checks=checks+1,reason=? WHERE seq=?", [Data(reason.utf8), key])
        return
      }
      let listed = try rows("SELECT count(*) FROM refused_packs")
      guard integer(listed[0][0]) < refusedRowLimit else {
        try noteUnlistedRefused(seq)
        return
      }
      try execute("INSERT INTO refused_packs(seq,class,deviceId,reason,firstAt,checks) VALUES (?,?,?,?,CAST(? AS INTEGER),1)",
        [key, Data(storageClass.rawValue.utf8), Data((deviceId ?? "").utf8), Data(reason.utf8), Data(String(CloudSyncBytes.now()).utf8)])
    }
  }
  /// Why a verified pack must not be applied because of what this Mac already applied, or nil. Nil also for the
  /// very same pack at its own position (it is simply applied already).
  func repeatedPackReason(id: String, seq: CloudSequence, digest: String) throws -> String? {
    if let previous = try rows("SELECT seq,digest FROM applied WHERE segmentId=?", [Data(id.utf8)]).first {
      if previous[0] == Data(seq.rawValue.utf8), previous[1] == Data(digest.utf8) { return nil }
      return previous[1] == Data(digest.utf8) ? CloudSyncEngine.repeatedPackReason : CloudSyncEngine.packIdReusedReason
    }
    let taken = try rows("SELECT segmentId FROM applied WHERE seq=?", [Data(seq.rawValue.utf8)])
    return taken.isEmpty ? nil : CloudSyncEngine.positionReusedReason
  }
  func refusedRows() throws -> [CloudRefusedPack] {
    try rows("SELECT seq,class,deviceId,reason,firstAt,checks FROM refused_packs ORDER BY CAST(seq AS INTEGER)").map { row in
      let device = String(decoding: row[2], as: UTF8.self)
      return CloudRefusedPack(sequence: try CloudSequence(rawValue: String(decoding: row[0], as: UTF8.self)),
        storageClass: CloudStorageClass(rawValue: String(decoding: row[1], as: UTF8.self)) ?? .brain,
        deviceId: device.isEmpty ? nil : device, reason: String(decoding: row[3], as: UTF8.self),
        firstAt: Int64(String(decoding: row[4], as: UTF8.self)) ?? 0, checks: integer(row[5]))
    }
  }
  /// Past the list only a count and the LOWEST unlisted position are kept: "Check again" for everything reads the
  /// feed again from that position, so no refused pack is out of reach for good.
  func noteUnlistedRefused(_ seq: CloudSequence) throws {
    try transaction {
      let beyond: Int = try value("refusedBeyondList") ?? 0
      try set("refusedBeyondList", beyond + 1)
      let first: CloudSequence? = try value("refusedBeyondFirst")
      try set("refusedBeyondFirst", min(first ?? seq, seq))
    }
  }
  /// The rows to judge again, least-checked first, a bounded number per call.
  func refusedRowsToCheck(limit: Int) throws -> [CloudRefusedPack] {
    let order = try rows("SELECT seq FROM refused_packs ORDER BY checks,CAST(seq AS INTEGER) LIMIT \(max(0, limit))").map { $0[0] }
    return try refusedRows().filter { row in order.contains(Data(row.sequence.rawValue.utf8)) }
  }
  /// A position this Mac already dealt with for good or keeps elsewhere: applied, listed as refused, or a
  /// saved-password pack parked or superseded.
  func positionSettled(_ seq: CloudSequence) throws -> Bool {
    let key = [Data(seq.rawValue.utf8)]
    for table in ["applied", "refused_packs", "parked_packs", "superseded_packs", "kind_waiting_packs"] {
      if try !rows("SELECT 1 FROM " + table + " WHERE seq=? LIMIT 1", key).isEmpty { return true }
    }
    return false
  }
  // MARK: Packs waiting for a kind this Mac does not take (N2)

  struct KindWaitingRow: Sendable {
    let seq: CloudSequence
    let storageClass: CloudStorageClass
    let deviceId: String
    let domains: [String]
  }
  /// Kept by position only; nothing of the pack itself is stored. Recording the same position again changes nothing.
  func waitForKind(seq: CloudSequence, storageClass: CloudStorageClass, deviceId: String, domains: [String]) throws {
    try execute("INSERT OR IGNORE INTO kind_waiting_packs(seq,class,deviceId,domains,waitingSince) VALUES (?,?,?,?,CAST(? AS INTEGER))",
      [Data(seq.rawValue.utf8), Data(storageClass.rawValue.utf8), Data(deviceId.utf8), try CloudSyncCanonical.encode(domains.sorted()),
       Data(String(CloudSyncBytes.now()).utf8)])
  }
  /// In feed order.
  func kindWaitingRows() throws -> [KindWaitingRow] {
    try rows("SELECT seq,class,deviceId,domains FROM kind_waiting_packs ORDER BY CAST(seq AS INTEGER)").map { row in
      KindWaitingRow(seq: try CloudSequence(rawValue: String(decoding: row[0], as: UTF8.self)),
        storageClass: CloudStorageClass(rawValue: String(decoding: row[1], as: UTF8.self)) ?? .brain,
        deviceId: String(decoding: row[2], as: UTF8.self), domains: (try? JSONDecoder().decode([String].self, from: row[3])) ?? [])
    }
  }
  func kindWaitingCount() throws -> Int { integer(try rows("SELECT count(*) FROM kind_waiting_packs")[0][0]) }
  func dropKindWaiting(_ seq: CloudSequence) throws {
    try execute("DELETE FROM kind_waiting_packs WHERE seq=?", [Data(seq.rawValue.utf8)])
  }
  func dropRefused(seq: CloudSequence) throws {
    try execute("DELETE FROM refused_packs WHERE seq=?", [Data(seq.rawValue.utf8)])
  }
}
