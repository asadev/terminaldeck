import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

/// Fixture-only: defined in the test target, so production cannot construct it.
actor CloudSyncFixtureServer: CloudTransportPort, CloudSyncObjectIO, CloudSyncRegistrationPort {
  /// MAC-NEXT-7 (5): retry back-offs on the fixture clock (100 times faster), never the real one.
  func backoff(milliseconds: Int64) async throws { try await Task.sleep(for: .milliseconds(max(1, milliseconds / 100))) }
  struct Disk: Codable {
    var head: UInt64 = 0
    var segments: [String: CloudSegment] = [:]
    var receipts: [String: CloudReceipt] = [:]
    var objects: [String: Data] = [:]
    var refs: [String: CloudBlobRef] = [:]
    var staging: [String: Data] = [:]
    var uploads: [String: CloudBlobUpload] = [:]
    var uploadDevices: [String: String] = [:]
    var segmentDevices: [String: String] = [:]
    var checkpoint: CloudCheckpoint?
  }
  let url: URL
  var device: String
  var registeredSigningKey: P256.Signing.PublicKey?
  func registration(_ device: String, publicKey: Data) throws { self.device = device; registeredSigningKey = try P256.Signing.PublicKey(x963Representation: publicKey) }
  func uploadIds() -> [String] { Array(disk.uploads.keys) }
  func switchDevice(_ id: String) { device = id }
  func currentDeviceId() async throws -> String { device }
  var disk: Disk
  var calls = 0
  var requestedCursors: [CloudSequence] = []
  func cursors() -> [CloudSequence] { requestedCursors }
  var lostACK = false
  var uploadExpirations = 0
  var uploadAttempts = 0
  var uploadLog: [String] = []
  var temporaryFinalizeFailures = 0
  var finalizationError = CloudBlobError(code: "temporarily_unavailable", retryable: true)
  func failFinalizationOnce(code: String = "temporarily_unavailable", retryable: Bool = true) { temporaryFinalizeFailures = 1; finalizationError = .init(code: code, retryable: retryable) }
  func expireUploads(_ count: Int) { uploadExpirations = count }
  var baselineRace = false
  var commitBeforeCheckpoint: CloudSegment?
  var racingDevice: String?
  var checkpointInterleave: (@Sendable () async throws -> Void)?
  func beforeNextCheckpoint(_ action: @escaping @Sendable () async throws -> Void) { checkpointInterleave = action }
  func raceFirstCheckpoint(with segment: CloudSegment, deviceId: String? = nil) { commitBeforeCheckpoint = segment; racingDevice = deviceId }
  func pretendEmptyOnce() { baselineRace = true }
  // Like the Worker, every prepare signs a new ticket (new expiry), so a re-prepared finalize is a new body.
  var ticketSerial = 0
  func nextTicket() -> Int { ticketSerial += 1; return ticketSerial }
  var ticketIssued: [String: Int64] = [:]
  var ticketLifetime: Int64? = nil
  var uploadDelay: Duration? = nil
  /// Real-clock ticket lifetime (like the Worker's five minutes, shortened) and a per-upload delay (slow uplink).
  func slowUplink(uploadDelay: Duration, ticketLifetimeMilliseconds: Int64) { self.uploadDelay = uploadDelay; ticketLifetime = ticketLifetimeMilliseconds }
  func issueTicket(_ uploadId: String) -> String {
    let ticket = "fixture-only:" + uploadId + ":" + String(nextTicket())
    ticketIssued[ticket] = CloudSyncBytes.now()
    return ticket
  }
  // HTTP-only emulation of Worker behaviour (CloudSyncTransportTests http()).
  var httpRefusals: [String: (status: Int, code: String, times: Int)] = [:]
  var routeHits: [String: Int] = [:]
  /// Like the Worker for a device refused saved-password writes: every SAVED-PASSWORD upload prepare is refused
  /// with secrets_locked while on; memory uploads go through.
  var refuseSecretsPrepares = false
  func refuseProtectedUploads(_ on: Bool) { refuseSecretsPrepares = on }
  func refuseHTTPOnce(_ route: String, status: Int, code: String) { refuseHTTP(route, status: status, code: code, times: 1) }
  func refuseHTTP(_ route: String, status: Int, code: String, times: Int) { httpRefusals[route] = (status, code, times) }
  func hits(_ route: String) -> Int { routeHits[route] ?? 0 }
  func takeHTTPRefusal(_ route: String) -> (status: Int, code: String)? {
    routeHits[route, default: 0] += 1
    guard let refusal = httpRefusals[route] else { return nil }
    if refusal.times <= 1 { httpRefusals.removeValue(forKey: route) } else { httpRefusals[route] = (refusal.status, refusal.code, refusal.times - 1) }
    return (refusal.status, refusal.code)
  }
  var replaySavedAnswers = false
  var savedAnswers: [String: (status: Int, bytes: Data)] = [:]
  var replayedAnswers = 0
  func replayAnswersByRequestId() { replaySavedAnswers = true }
  var linkGeneration = 0
  var segmentDownloads = 0
  /// Every pack download by pack id (device trust: a held or refused pack is never downloaded).
  var segmentDownloadLog: [String] = []
  var expireLinksAfter = 0
  /// After `downloads` pack downloads, every feed link issued so far expires.
  func expireFeedLinks(afterDownloads downloads: Int) { expireLinksAfter = segmentDownloads + downloads }
  func changesCalls() -> Int { requestedCursors.count }
  var lockedSegments: Set<String> = []
  func lock(segments: Set<String>) { lockedSegments = segments }
  var refusedDomains: Set<String> = []
  func refusePacks(of domains: Set<String>) { refusedDomains = domains }
  var zeroReceiptOnce = false
  func answerNextCommitAtZero() { zeroReceiptOnce = true }
  var zeroHeadGuard = true
  func withoutZeroHeadGuard() { zeroHeadGuard = false }
  var corrupt: Data?
  var failure: CloudFailure?
  var eventStreams: [AsyncThrowingStream<CloudEvent, Error>.Continuation] = []
  init(root: URL, device: String) throws {
    url = root.appendingPathComponent("fixture-server.json")
    self.device = device
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: url.path) { disk = try JSONDecoder().decode(Disk.self, from: Data(contentsOf: url)) }
    else { disk = Disk() }
  }
  func persist() throws { try JSONEncoder().encode(disk).write(to: url, options: .atomic) }
  func admit() throws { calls += 1; if let failure { throw failure } }
  func setLostACK() { lostACK = true }
  func setFailure(_ value: CloudFailure?) { failure = value }
  func setCorruption(_ value: Data?) { corrupt = value }
  func segmentCount() -> Int { disk.segments.count }
  func objectCount() -> Int { disk.objects.count }
  func installCheckpointForReview(_ checkpoint: CloudCheckpoint) throws {
    guard checkpoint.throughSeq <= CloudSequence(disk.head), disk.refs[checkpoint.root.blobId] == checkpoint.root else { throw CloudFailure.invalidRequest }
    disk.checkpoint = checkpoint
    try persist()
  }
  var capabilityCalls = 0
  func capabilities() async throws -> CloudGate { capabilityCalls += 1; return .init(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false) }
  func registerDevice(_ request: CloudDeviceRegistration) async throws -> CloudDeviceRegistrationReceipt {
    .init(deviceId: request.deviceId, status: .active, secretsApproved: false, headSeq: CloudSequence(disk.head), vaultState: .unset)
  }
  /// Device trust: the sync core must never ask the service for a key; this counts every device-list request.
  var deviceListCalls = 0
  func devices() async throws -> CloudDeviceList { deviceListCalls += 1; return .init(devices: [], receiverDeviceId: nil) }
  func state() async throws -> CloudRemoteState {
    try admit()
    let pretend = baselineRace
    baselineRace = false
    return .init(headSeq: pretend ? .zero : CloudSequence(disk.head), checkpoint: pretend ? nil : disk.checkpoint, devicesVersion: .zero, vaultState: .unset,
      vaultEpoch: 1, vaultVersion: .zero, capabilities: try await capabilities(),
      budget: .init(day: "fixture", requestsLeft: 6000, writesLeft: 12000, bytesLeft: 20 * 1024 * 1024))
  }
  /// An old service saying "wait" to one device: after `left` more packs it refuses that device's commits.
  var allowance: (device: String, left: Int)?
  func pauseAllowance(of device: String, afterCommits left: Int?) { allowance = left.map { (device, $0) } }
  /// X2: the order of this fixture's commits and feed reads, by device ("commit:<device>", "changes:<device>").
  var requestLog: [String] = []
  func log() -> [String] { requestLog }
  func commit(_ segment: CloudSegment) async throws -> CloudReceipt {
    requestLog.append("commit:" + device)
    try admit()
    if let allowance, allowance.device == device, allowance.left <= 0, disk.segments[segment.descriptor.segmentId] == nil { throw CloudFailure.budgetPaused }
    let d = segment.descriptor
    if let registeredSigningKey {
      let proof = try P256.Signing.ECDSASignature(rawRepresentation: CloudSyncBytes.unbase64(d.signature))
      guard registeredSigningKey.isValidSignature(proof, for: try d.syncSigningBytes(subject: "11111111-1111-4111-8111-111111111111")) else {
        throw CloudFailure.remote(.init(code: "bad_device_proof", message: "Fixture proof refused.", retryable: false, requestId: d.requestId))
      }
    }
    let bytes = try CloudSyncBytes.unbase64(segment.ciphertext)
    guard bytes.count == d.bytes, CloudSyncBytes.hash(bytes) == d.sha256 else { throw CloudFailure.checksumMismatch }
    // Exactly the Worker's rule (feed.ts:91): every domain name must match ^[a-z0-9][a-z0-9/_-]*$ (<=128).
    guard d.domains.allSatisfy({ $0.range(of: CloudWire.domainNamePattern, options: .regularExpression) != nil && $0.utf8.count <= 128 }) else {
      throw CloudFailure.remote(.init(code: "invalid_request", message: "Fixture refuses this domain name.", retryable: false, requestId: d.requestId))
    }
    if !refusedDomains.isDisjoint(with: d.domains) {
      throw CloudFailure.remote(.init(code: "unsupported_format", message: "Fixture refuses this pack for good.", retryable: false, requestId: d.requestId))
    }
    if let previous = disk.segments[d.segmentId] {
      guard previous == segment else { throw CloudFailure.idReused }
      return disk.receipts[d.segmentId]!
    }
    guard !disk.segments.values.contains(where: { $0.descriptor.requestId == d.requestId }) else { throw CloudFailure.idReused }
    if zeroReceiptOnce { zeroReceiptOnce = false; return CloudReceipt(segmentId: d.segmentId, seq: .zero, headSeq: .zero, receipt: .init(requestId: d.requestId, sha256: d.sha256, committedAt: 1000)) }
    disk.head += 1
    let receipt = CloudReceipt(segmentId: d.segmentId, seq: CloudSequence(disk.head), headSeq: CloudSequence(disk.head),
      receipt: .init(requestId: d.requestId, sha256: d.sha256, committedAt: 1000))
    disk.segments[d.segmentId] = segment
    if let now = allowance, now.device == device { allowance = (now.device, now.left - 1) }
    disk.segmentDevices[d.segmentId] = device
    disk.receipts[d.segmentId] = receipt
    try persist()
    if lostACK { lostACK = false; throw CloudFailure.unavailable }
    return receipt
  }
  /// A service that serves a pack it already served again, at a new feed position (same id, same bytes).
  func repeatPack(_ segmentId: String) throws {
    guard let old = disk.receipts[segmentId] else { throw CloudFailure.invalidRequest }
    disk.head += 1
    disk.receipts["repeat:" + String(disk.head)] = CloudReceipt(segmentId: segmentId, seq: CloudSequence(disk.head), headSeq: CloudSequence(disk.head), receipt: old.receipt)
    try persist()
  }
  func changes(after: CloudSequence, limit: Int) async throws -> CloudChangePage {
    requestedCursors.append(after)
    requestLog.append("changes:" + device)
    try admit()
    let receipts = disk.receipts.values.filter { $0.seq > after }.sorted { $0.seq < $1.seq }.prefix(limit)
    let entries = receipts.map { receipt -> CloudChangeEntry in
      let d = disk.segments[receipt.segmentId]!.descriptor
      // Like the Worker: a saved-password pack this device may not read (e.g. an older key) is listed as locked.
      if lockedSegments.contains(d.segmentId) { return CloudChangeEntry(seq: receipt.seq, storageClass: .secrets, locked: true) }
      return .init(seq: receipt.seq, storageClass: d.storageClass, segmentId: d.segmentId, requestId: d.requestId,
        purpose: d.purpose, domains: d.domains, keyEpoch: d.keyEpoch, sha256: d.sha256, bytes: d.bytes, opCount: d.opCount,
        format: d.format, signature: d.signature, deviceId: disk.segmentDevices[d.segmentId] ?? device, createdAt: 1000,
        getUrl: URL(string: "https://cloud.test/v1/transfers/segments/" + d.segmentId + "?g=" + String(linkGeneration))!, expiresAt: CloudSyncBytes.now() + 60_000)
    }
    let next = entries.last?.seq ?? after
    // Like the Worker (feed.ts:226): "more to come" only when packs exist beyond the returned page, never merely
    // because the head lies further on (a first upload in slot 1 is not a pack).
    return .init(segments: entries, headSeq: CloudSequence(disk.head), nextAfter: next, hasMore: disk.receipts.values.contains { $0.seq > next })
  }
  var prepareCalls = 0, finalizeCalls = 0
  func prepareBlobs(_ items: [CloudBlobUpload]) async throws -> [CloudBlobTicket] {
    try admit()
    prepareCalls += 1
    guard (1...16).contains(items.count) else { throw CloudFailure.invalidRequest }
    var tickets: [CloudBlobTicket] = []
    for item in items {
      if let owner = disk.uploadDevices[item.uploadId], owner != device { throw CloudFailure.idReused }
      if let old = disk.uploads[item.uploadId], old != item { throw CloudFailure.idReused }
      let ref = CloudBlobRef(blobId: item.blobId, sha256: item.sha256, md5: item.md5, bytes: item.bytes,
        storageClass: item.storageClass, purpose: item.purpose, keyEpoch: item.keyEpoch)
      if let old = disk.refs[item.blobId], old != ref { throw CloudFailure.idReused }
      disk.uploads[item.uploadId] = item
      disk.uploadDevices[item.uploadId] = device
      let exists = disk.refs[item.blobId] != nil
      tickets.append(.init(uploadId: item.uploadId, blobId: item.blobId,
        putUrl: exists ? nil : URL(string: "https://cloud.test/v1/transfers/staging/" + item.uploadId), headers: ["content-type": "application/octet-stream", "content-md5": item.md5],
        ticket: issueTicket(item.uploadId), expiresAt: CloudSyncBytes.now() + 300_000, alreadyPresent: exists))
    }
    try persist()
    return tickets
  }
  func upload(_ bytes: Data, ticket: CloudBlobTicket) async throws {
    try admit()
    uploadAttempts += 1
    if let upload = disk.uploads[ticket.uploadId] { uploadLog.append(upload.blobId) }
    if let uploadDelay { try await Task.sleep(for: uploadDelay) }
    if uploadExpirations > 0 { uploadExpirations -= 1; throw CloudSyncTransferFailure.uploadExpired }
    guard ticket.putUrl?.host == "cloud.test", disk.uploads[ticket.uploadId] != nil else { throw CloudFailure.invalidRequest }
    disk.staging[ticket.uploadId] = bytes
    try persist()
  }
  func finalizeBlobs(_ items: [CloudBlobFinalize]) async throws -> [CloudBlobResult] {
    try admit()
    finalizeCalls += 1
    var result: [CloudBlobResult] = []
    for item in items {
      if temporaryFinalizeFailures > 0 {
        temporaryFinalizeFailures -= 1
        result.append(.init(uploadId: item.uploadId, error: finalizationError))
        continue
      }
      if let ticketLifetime, let issued = ticketIssued[item.ticket], CloudSyncBytes.now() - issued > ticketLifetime {
        result.append(.init(uploadId: item.uploadId, error: .init(code: "code_expired", retryable: false)))
        continue
      }
      guard item.ticket.hasPrefix("fixture-only:" + item.uploadId), let upload = disk.uploads[item.uploadId], upload.blobId == item.blobId else { throw CloudFailure.invalidRequest }
      let ref = CloudBlobRef(blobId: item.blobId, sha256: upload.sha256, md5: upload.md5, bytes: upload.bytes,
        storageClass: upload.storageClass, purpose: upload.purpose, keyEpoch: upload.keyEpoch)
      if disk.refs[item.blobId] == nil {
        guard let bytes = disk.staging[item.uploadId] else { throw CloudFailure.unavailable }
        try CloudSyncBytes.verify(bytes, ref: ref)
        disk.objects[item.blobId] = bytes
        disk.refs[item.blobId] = ref
      }
      result.append(.init(uploadId: item.uploadId, blob: disk.refs[item.blobId]))
    }
    try persist()
    return result
  }
  var readBlobCalls = 0, objectDownloads = 0
  /// Every object download by id (round 6 S3: each restored file is fetched once).
  var objectDownloadLog: [String] = []
  func readBlobs(ids: [String]) async throws -> [CloudBlobDownload] {
    try admit()
    readBlobCalls += 1
    return try ids.map { id in
      guard let ref = disk.refs[id] else { throw CloudFailure.invalidRequest }
      return .init(blob: ref, getUrl: URL(string: "https://cloud.test/v1/transfers/objects/" + id)!, expiresAt: CloudSyncBytes.now() + 60_000)
    }
  }
  func download(_ url: URL, maximumBytes: Int) async throws -> Data {
    try admit()
    guard url.host == "cloud.test" else { throw CloudFailure.unsafeConfiguration }
    if let corrupt { return corrupt }
    let id = url.lastPathComponent
    let bytes: Data
    if url.path.hasPrefix("/v1/transfers/segments/"), let segment = disk.segments[id] {
      // Feed links expire like the Worker's (60 s): a link from an older generation is refused.
      let generation = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "g" }?.value.flatMap(Int.init) ?? linkGeneration
      guard generation >= linkGeneration else { throw CloudSyncTransferFailure.readExpired }
      bytes = try CloudSyncBytes.unbase64(segment.ciphertext)
      segmentDownloads += 1
      segmentDownloadLog.append(id)
      if expireLinksAfter > 0, segmentDownloads == expireLinksAfter { linkGeneration += 1 }
    }
    else if let object = disk.objects[id] { bytes = object; objectDownloads += 1; objectDownloadLog.append(id) }
    else { throw CloudFailure.invalidRequest }
    guard bytes.count <= maximumBytes else { throw CloudFailure.invalidRequest }
    return bytes
  }
  func publishCheckpoint(_ request: CloudCheckpointRequest) async throws -> CloudCheckpointReceipt {
    try admit()
    if let old = disk.checkpoint, old.checkpointId == request.checkpointId {
      guard old.root == request.root, old.counts == request.counts, old.inventoryDigest == request.inventoryDigest else { throw CloudFailure.idReused }
      return .init(checkpointId: old.checkpointId, throughSeq: old.throughSeq, verifiedBy: old.verifiedBy, published: true)
    }
    if let action = checkpointInterleave {
      checkpointInterleave = nil
      try await action()
    }
    if let segment = commitBeforeCheckpoint {
      commitBeforeCheckpoint = nil
      let recipient = device
      if let racingDevice { device = racingDevice }
      do { _ = try await commit(segment) }
      catch { device = recipient; throw error }
      device = recipient
    }
    // throughSeq zero is an atomic empty-head comparison, also required of the real Worker.
    // `zeroHeadGuard = false` reproduces the current Worker, which lacks it and records the raced inventory at 0.
    guard !(zeroHeadGuard && request.throughSeq == .zero && disk.head != 0), request.throughSeq <= CloudSequence(disk.head),
      request.parentCheckpointId == disk.checkpoint?.checkpointId else {
      throw CloudFailure.remote(.init(code: "baseline_changed", message: "Fixture baseline changed.", retryable: false, requestId: request.checkpointId))
    }
    guard disk.refs[request.root.blobId] == request.root else { throw CloudFailure.invalidRequest }
    let published = disk.head == 0 ? CloudSequence(1) : request.throughSeq
    if disk.head == 0 { disk.head = 1 }
    disk.checkpoint = .init(checkpointId: request.checkpointId, throughSeq: published, root: request.root,
      inventoryDigest: request.inventoryDigest, counts: request.counts, verifiedBy: [device])
    try persist()
    return .init(checkpointId: request.checkpointId, throughSeq: published, verifiedBy: [device], published: true)
  }
  func checkpoint() async throws -> CloudCheckpoint? { try admit(); return disk.checkpoint }
  func verifyCheckpoint(id: String, inventoryDigest: String, counts: CloudCounts) async throws -> [String] {
    try admit()
    guard let cp = disk.checkpoint, cp.checkpointId == id, cp.inventoryDigest == inventoryDigest, cp.counts == counts else { throw CloudFailure.checksumMismatch }
    return [device]
  }
  func applied(brainSeq: CloudSequence, secretsSeq: CloudSequence, checkpointId: String?) async throws -> CloudAppliedReceipt {
    try admit()
    guard brainSeq <= CloudSequence(disk.head), secretsSeq <= brainSeq else { throw CloudFailure.invalidRequest }
    return .init(brainSeq: brainSeq, secretsSeq: secretsSeq)
  }
  func takeLease(_ request: CloudLeaseRequest) async throws -> CloudLease { throw CloudFailure.unsupportedFormat }
  func releaseLease(resourceId: String, generation: CloudSequence) async throws { throw CloudFailure.unsupportedFormat }
  func events() async -> AsyncThrowingStream<CloudEvent, Error> {
    AsyncThrowingStream { continuation in
      eventStreams.append(continuation)
      continuation.yield(.init(v: 1, type: "hello", id: UUID().uuidString.lowercased(), payload: .init(.object([]))))
    }
  }
  func hint() {
    for stream in eventStreams { stream.yield(.init(v: 1, type: "changed", id: UUID().uuidString.lowercased(), payload: .init(.object([])))) }
  }
  func stop() async { for stream in eventStreams { stream.finish() }; eventStreams = [] }
}

actor CloudSyncFixtureAdapter: CloudDomainAdapter {
  nonisolated let inventoryRows = ["I01"]
  let root: URL
  var rows: [String: CloudOperation]
  var effects = 0
  var order: [String] = []
  var reject = false
  let domain: String
  let acceptsFiles: Bool
  var receivedFiles: [String: Data] = [:]
  init(root: URL, domain: String = "memory", acceptsFiles: Bool = false) throws {
    self.domain = domain; self.acceptsFiles = acceptsFiles
    self.root = root
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("fixture-domain.json")
    rows = (try? JSONDecoder().decode([String: CloudOperation].self, from: Data(contentsOf: file))) ?? [:]
  }
  var inventoryCalls = 0
  func sourceInventory() async throws -> [CloudSourceInventory] {
    inventoryCalls += 1
    return [.init(sourceId: "fixture-source", inventoryRow: "I01", domain: domain, items: rows.count, bytes: 0, complete: localComplete,
      blockedReasons: localGaps, exclusions: localExclusions)]
  }
  /// What this adapter reports about its own source: gaps (incomplete) and intentional exclusions.
  var localComplete = true, localGaps: [String] = [], localExclusions: [String] = []
  func report(complete: Bool, gaps: [String] = [], exclusions: [String] = []) { localComplete = complete; localGaps = gaps; localExclusions = exclusions }
  /// Setup through the paged call the app uses (`bootstrap(sources:cut:)`): these records, with this adapter's own
  /// statement about its source.
  var setupOperations: [CloudOperation]?
  func setUp(with operations: [CloudOperation]) { setupOperations = operations }
  func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
    guard let setupOperations else { return .init(cut: cut, operations: Array(rows.values), files: [], coverage: []) }
    return .init(cut: cut, operations: setupOperations, files: [], coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01",
      complete: localComplete, items: setupOperations.count, bytes: 0, blockedReasons: localGaps, exclusions: localExclusions)])
  }
  func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> { AsyncThrowingStream { $0.finish() } }
  /// Records this adapter "cannot apply" (poison records), refused with CloudRecordRefusal until healed.
  var refusedOps: Set<String> = []
  var validatedOps: [String] = []
  func refuse(_ ids: Set<String>) { refusedOps = ids }
  func heal() { refusedOps = [] }
  func validated() -> [String] { validatedOps }
  func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
    validatedOps += operations.map(\.opId)
    let refused = operations.map(\.opId).filter { refusedOps.contains($0) }
    if !refused.isEmpty { throw CloudRecordRefusal(operationIds: refused, reason: "Fixture adapter cannot apply this record.") }
    guard !reject, acceptsFiles || files.isEmpty else { throw CloudFailure.invalidRequest }
    try CloudSyncPack.validate(operations)
    // Device trust tests: something happens between "prepared" and "applied" (e.g. the person stops the device).
    if let hook = validationHook { validationHook = nil; await hook() }
    return .init(preparationId: UUID().uuidString.lowercased(), operations: operations, files: files)
  }
  var validationHook: (@Sendable () async -> Void)?
  func afterNextValidation(_ action: @escaping @Sendable () async -> Void) { validationHook = action }
  var origins: [String: CloudImportOrigin] = [:]
  func origin(of opId: String) -> CloudImportOrigin? { origins[opId] }
  /// X1: entities this adapter cannot take (like memory's `idReused` for a row another Mac re-sent under its own name).
  var idReusedEntities: Set<String> = []
  func refuseWithIdReused(_ entities: Set<String>) { idReusedEntities = entities }
  /// MAC-NEXT-7: entities this adapter fails on with an error that is neither a network nor a content failure.
  var oddEntities: Set<String> = []
  func failOddly(_ entities: Set<String>) { oddEntities = entities }
  struct OddFailure: Error {}
  func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
    if prepared.operations.contains(where: { oddEntities.contains($0.entityId) }) { throw OddFailure() }
    if prepared.operations.contains(where: { idReusedEntities.contains($0.entityId) }) { throw CloudFailure.idReused }
    for op in prepared.operations { origins[op.opId] = origin }
    for file in prepared.files {
      let sealed = try CloudSyncSealedFile(file)
      receivedFiles[file.blobId] = sealed.bytes
    }
    var results: [CloudItemResult] = []
    for op in prepared.operations {
      if let old = rows[op.opId] {
        guard old == op else { throw CloudFailure.idReused }
        results.append(.init(entityId: op.entityId, status: .alreadyPresent))
      } else {
        effects += 1
        order.append(op.opId)
        rows[op.opId] = op
        results.append(.init(entityId: op.entityId, status: .applied))
      }
    }
    try JSONEncoder().encode(rows).write(to: root.appendingPathComponent("fixture-domain.json"), options: .atomic)
    return .init(preparationId: prepared.preparationId, inventoryRow: "I01", results: results,
      counts: .init(domains: 1, records: prepared.operations.count, files: prepared.files.count, bytes: 0, blocked: 0))
  }
  func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification { .init(verified: true, counts: receipt.counts, reasons: []) }
  func count() -> Int { rows.count }
  func effectCount() -> Int { effects }
  func appliedOrder() -> [String] { order }
  /// A local change with no operation behind it (e.g. a tidy-up): only the live source count moves.
  func addLocalRowWithoutOperation(_ op: CloudOperation) { rows[op.opId] = op }
  func fileBytes(_ id: String) -> Data? { receivedFiles[id] }
}
