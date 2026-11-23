import Foundation
import CryptoKit

private struct CloudSyncJournal: Codable {
  let id: String
  let seq: CloudSequence
  let digest: String
  let origin: CloudImportOrigin
  let prepared: [CloudPreparedImport]
  let domains: [String]
}

private struct CloudSyncManifestDomain: Codable {
  let domain: String
  let records: Int
  let children: [CloudBlobRef]
  let digest: String
}
private struct CloudSyncManifestCoverage: Codable {
  let sourceId: String
  let complete: Bool
  let items: Int
  let bytes: Int64
  let blockedReasons: [String]
  let cutoff: String?
  /// Intentional exclusions (contract CloudCoverage.exclusions); absent in older manifests.
  let exclusions: [String]?
}
private struct CloudSyncManifest: Codable {
  let v: Int
  let throughSeq: CloudSequence
  let createdAt: Int64
  let sourceSnapshotId: String
  let domains: [CloudSyncManifestDomain]
  let pathMaps: [CloudValue]
  let sourceCoverage: [CloudSyncManifestCoverage]
  let counts: CloudCounts
}

/// All domain data moves through registered adapters. No process, session, provider home or legacy DB access.
public actor CloudSyncEngine: CloudOutboxPort {
  private let store: CloudSyncStore
  private let transport: any CloudTransportPort
  private let objects: any CloudSyncObjectIO
  private let content: any CloudContentPort
  private let budget: CloudSyncBudget
  private let subject: String
  private var deviceId: String
  private let epoch: Int
  private let signer: CloudSyncDeviceSigner
  /// False for a signer fixed at creation: such an engine refuses an in-place re-registration.
  private let signerFollowsRegistration: Bool
  /// How an incoming pack's signer is judged. There is NO fallback: the app can only build `.list`.
  private enum Trust: Sendable {
    /// This Mac's own stored trusted list (lane A's wiring). The engine checks every signature itself, under the
    /// key that list supplies; never under a key from the service, never by a field inside the pack.
    case list(any CloudDeviceTrustPort)
    #if DEBUG
    /// Test seam, reachable only through the internal initialisers: a closure stands in for the list. It exists
    /// in debug builds only (the tests are compiled that way); a release build has no such case and no such code.
    case seam(CloudSyncSignatureVerifier)
    #endif
  }
  private let trust: Trust
  /// LEAN FIRST VERSION SWITCH (cloud-lean-v1.md item 5), ON: no Mac publishes, fetches or imports a first upload
  /// (checkpoint). Every Mac sends its baseline as ordinary signed packs and a new Mac reads the feed from
  /// position 1. The first-upload machinery below is switched off for this version, not deleted.
  public static let noFirstUploadInThisVersion = true
  /// True only where a test of the switched-off first-upload machinery asks for it (internal test seam).
  private let firstUpload: Bool
  private let maximumPackBytes: Int
  private let fault: CloudSyncFault
  private let brainDomains: Set<String>
  private let secretsDomains: Set<String>
  private let secretsContent: (any CloudContentPort)?
  private var adapters: [String: any CloudDomainAdapter] = [:]
  /// Domains whose adapter is never part of a first saved copy (`CloudDomainWithoutSetup`: boot files).
  private var withoutSetup: Set<String> = []
  private var busy = false
  /// MAC-NEXT-5 (13 Nov, two real Macs): steps that must not be refused while another step runs (the scheduler's own
  /// fetch/send and a first copy) wait here for the engine instead of failing "busy" and being dropped.
  private var busyWaiters: [CheckedContinuation<Void, Never>] = []
  private func endBusy() {
    busy = false
    let waiting = busyWaiters; busyWaiters = []
    for waiter in waiting { waiter.resume() }
  }
  private func waitUntilFree() async throws {
    guard busy else { return }
    // Busy is quiet; one line only when one wait lasts over 30 s.
    let watchdog = Task {
      try? await Task.sleep(for: .seconds(30))
      if !Task.isCancelled { CloudSyncDiagnostics.shared.info("waiting: another Cloud step on this Mac is still running after 30 s" + self.heldNote()) }
    }
    defer { watchdog.cancel() }
    while busy { await withCheckedContinuation { busyWaiters.append($0) } }
    try Task.checkCancellation()
  }
  /// X4 (13 Nov): no record waits silently. Every waiting line says how many of this Mac's records are not sent yet
  /// and, when some are parked, how many and why ("40 records held all day" were the MacBook's own first copy,
  /// prepared at 06:21 and sent only at 13:21 behind earlier builds' silent stops and then the whole download).
  func heldNote() -> String {
    let queued = (try? store.queuedCount()) ?? 0
    let parked = (try? store.rows("SELECT count(*),max(p.reason) FROM parked_sends p JOIN outbox o ON o.opId=p.opId WHERE o.state='parked'"))?.first
    let parkedCount = parked.flatMap { Int(String(decoding: $0[0], as: UTF8.self)) } ?? 0
    var parts: [String] = []
    if queued > 0 { parts.append("\(queued) records of this Mac wait to go up") }
    if parkedCount > 0, let reason = parked.map({ String(decoding: $0[1], as: UTF8.self) }) { parts.append("\(parkedCount) are held: " + reason) }
    return parts.isEmpty ? "" : " (" + parts.joined(separator: "; ") + ")"
  }
  /// Back-off of the local retry timer (2 s doubling to 60 s), reset by a step that succeeds.
  private var localRetryStreak = 0
  /// One `cloud sync:` line per state change (never per pack); the key of the last one written.
  private var lastStateKey = ""
  private func stateLine(_ key: String, _ text: String) {
    guard key != lastStateKey else { return }
    lastStateKey = key
    CloudSyncDiagnostics.shared.info(text)
  }
  private var pump: Task<Void, Never>?
  private var automatic = false
  private var sendRequested = false
  private var pullRequested = false
  private var sendTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?

  /// A signer fixed to `deviceId`. It never signs for another registration; re-register by creating a new engine.
  /// `trust` is this Mac's own stored trusted list. A pack is applied only if its signature checks under a key
  /// that list holds; there is no initialiser the app can reach without it, and none that takes a first upload.
  public init(store: CloudSyncStore, transport: any CloudTransportPort, objects: any CloudSyncObjectIO,
              content: any CloudContentPort, budget: CloudSyncBudget, subject: String, deviceId: String, epoch: Int, brainDomains: Set<String>, secretsDomains: Set<String> = [], secretsContent: (any CloudContentPort)? = nil,
              signer: @escaping CloudSyncSigner, trust: any CloudDeviceTrustPort,
              maximumPackBytes: Int = CloudWire.maximumPlainChunkBytes, staging: CloudSyncStaging = CloudSyncStaging(), fault: @escaping CloudSyncFault = { _ in }) throws {
    let bound = deviceId
    try self.init(store: store, transport: transport, objects: objects, content: content, budget: budget, subject: subject, deviceId: deviceId,
      epoch: epoch, brainDomains: brainDomains, secretsDomains: secretsDomains, secretsContent: secretsContent,
      signer: { device, payload in
        guard device == bound else { throw CloudFailure.unsafeConfiguration }
        return try await signer(payload)
      }, follows: false, trust: .list(trust), firstUpload: !CloudSyncEngine.noFirstUploadInThisVersion, maximumPackBytes: maximumPackBytes, staging: staging, fault: fault)
  }
  /// A signer that resolves the key of whichever registration the engine currently signs for. `trust` as above.
  public init(store: CloudSyncStore, transport: any CloudTransportPort, objects: any CloudSyncObjectIO,
              content: any CloudContentPort, budget: CloudSyncBudget, subject: String, deviceId: String, epoch: Int, brainDomains: Set<String>, secretsDomains: Set<String> = [], secretsContent: (any CloudContentPort)? = nil,
              deviceSigner: @escaping CloudSyncDeviceSigner, trust: any CloudDeviceTrustPort,
              maximumPackBytes: Int = CloudWire.maximumPlainChunkBytes, staging: CloudSyncStaging = CloudSyncStaging(), fault: @escaping CloudSyncFault = { _ in }) throws {
    try self.init(store: store, transport: transport, objects: objects, content: content, budget: budget, subject: subject, deviceId: deviceId,
      epoch: epoch, brainDomains: brainDomains, secretsDomains: secretsDomains, secretsContent: secretsContent,
      signer: deviceSigner, follows: true, trust: .list(trust), firstUpload: !CloudSyncEngine.noFirstUploadInThisVersion, maximumPackBytes: maximumPackBytes, staging: staging, fault: fault)
  }
  #if DEBUG
  /// TEST SEAM, debug builds only. Internal, so the app and the backend module cannot reach it, and absent from a
  /// release build, so nothing inside this module can ship a call to it: a closure stands in for the trusted
  /// list (returning means "trusted and verified", throwing stops the pull as it did before device trust), and
  /// the switched-off first upload can be asked for. Only the test target uses it.
  init(store: CloudSyncStore, transport: any CloudTransportPort, objects: any CloudSyncObjectIO,
       content: any CloudContentPort, budget: CloudSyncBudget, subject: String, deviceId: String, epoch: Int, brainDomains: Set<String>, secretsDomains: Set<String> = [], secretsContent: (any CloudContentPort)? = nil,
       signer: @escaping CloudSyncSigner, verifySignature: @escaping CloudSyncSignatureVerifier,
       firstUpload: Bool = !CloudSyncEngine.noFirstUploadInThisVersion,
       maximumPackBytes: Int = CloudWire.maximumPlainChunkBytes, staging: CloudSyncStaging = CloudSyncStaging(), fault: @escaping CloudSyncFault = { _ in }) throws {
    let bound = deviceId
    try self.init(store: store, transport: transport, objects: objects, content: content, budget: budget, subject: subject, deviceId: deviceId,
      epoch: epoch, brainDomains: brainDomains, secretsDomains: secretsDomains, secretsContent: secretsContent,
      signer: { device, payload in
        guard device == bound else { throw CloudFailure.unsafeConfiguration }
        return try await signer(payload)
      }, follows: false, trust: .seam(verifySignature), firstUpload: firstUpload, maximumPackBytes: maximumPackBytes, staging: staging, fault: fault)
  }
  /// TEST SEAM, as above, with a signer that follows the registration.
  init(store: CloudSyncStore, transport: any CloudTransportPort, objects: any CloudSyncObjectIO,
       content: any CloudContentPort, budget: CloudSyncBudget, subject: String, deviceId: String, epoch: Int, brainDomains: Set<String>, secretsDomains: Set<String> = [], secretsContent: (any CloudContentPort)? = nil,
       deviceSigner: @escaping CloudSyncDeviceSigner, verifySignature: @escaping CloudSyncSignatureVerifier,
       firstUpload: Bool = !CloudSyncEngine.noFirstUploadInThisVersion,
       maximumPackBytes: Int = CloudWire.maximumPlainChunkBytes, staging: CloudSyncStaging = CloudSyncStaging(), fault: @escaping CloudSyncFault = { _ in }) throws {
    try self.init(store: store, transport: transport, objects: objects, content: content, budget: budget, subject: subject, deviceId: deviceId,
      epoch: epoch, brainDomains: brainDomains, secretsDomains: secretsDomains, secretsContent: secretsContent,
      signer: deviceSigner, follows: true, trust: .seam(verifySignature), firstUpload: firstUpload, maximumPackBytes: maximumPackBytes, staging: staging, fault: fault)
  }
  #endif
  private init(store: CloudSyncStore, transport: any CloudTransportPort, objects: any CloudSyncObjectIO,
               content: any CloudContentPort, budget: CloudSyncBudget, subject: String, deviceId: String, epoch: Int, brainDomains: Set<String>, secretsDomains: Set<String>, secretsContent: (any CloudContentPort)?,
               signer: @escaping CloudSyncDeviceSigner, follows: Bool, trust: Trust, firstUpload: Bool,
               maximumPackBytes: Int, staging: CloudSyncStaging, fault: @escaping CloudSyncFault) throws {
    _ = try CloudSyncBytes.uuid(subject)
    // An unsigned first upload never meets the trusted list: that combination cannot be built.
    if case .list = trust, firstUpload { throw CloudFailure.unsafeConfiguration }
    guard store.subject.sub == subject else { throw CloudFailure.unsafeConfiguration }
    try CloudSyncBytes.transportID(deviceId)
    // No memory domains is allowed: saved passwords alone, or nothing switched on yet (see pullSavedPasswordsOnly).
    guard epoch > 0, brainDomains.isDisjoint(with: secretsDomains), secretsDomains.isEmpty || secretsContent != nil, (1...CloudWire.maximumPlainChunkBytes).contains(maximumPackBytes) else { throw CloudFailure.invalidRequest }
    self.store = store; self.transport = transport; self.objects = objects; self.content = content; self.budget = budget
    self.subject = subject; self.deviceId = deviceId; self.epoch = epoch; self.signer = signer; self.signerFollowsRegistration = follows
    self.trust = trust; self.firstUpload = firstUpload; self.fault = fault; self.brainDomains = brainDomains
    self.secretsDomains = secretsDomains; self.secretsContent = secretsContent
    self.maximumPackBytes = maximumPackBytes
    self.staging = staging
    try store.bindDevice(deviceId)
    // Launch reconciliation: sealed bytes left by a crash are kept only while something unfinished needs them.
    try store.reconcileStaging(keep: [])
    try store.stripSettledSegments()
    try Self.dropFinishedSetupNotes(store)
  }
  private let staging: CloudSyncStaging
  /// Inventory objects of the publication in progress, kept locally until this Mac imported its own inventory.
  private var keepBytes: Set<String> = []
  /// After each applied pack or inventory page: its handoff copies and downloaded sealed bytes go, so a long
  /// restore never accumulates them.
  private func releaseAfterApply() throws {
    store.removeHandoffs()
    try store.dropReceiptedBytes(except: keepBytes)
  }
  /// After an operation: handoffs removed, received bytes dropped, settled packs stripped, settled records'
  /// content released (item B).
  private func releaseSettled() throws {
    store.removeHandoffs()
    try store.dropReceiptedBytes(except: keepBytes)
    try store.stripSettledSegments()
    // 0.23.6 (CPU): this walk reads every record of the store (296,530 on the Mac mini, 10 GB: 48 s, read-only on his
    // data). Sends now end every minute to let the fetch run (`sendSliceMilliseconds`), so while records still wait to
    // go up it runs at most every 30 minutes; with nothing waiting it runs after every step, as before.
    let now = CloudSyncBytes.now()
    if try store.queuedCount() == 0 || now - lastSettledWalk >= Self.settledWalkGapMilliseconds {
      try store.stubSettledRecords()
      lastSettledWalk = now
    }
    // 0.23.4 (fault 4a): once, the project-folder pieces an earlier build left with their content after the Cloud
    // acknowledged them. Never stops a fetch or a send: a failure is said once and tried again after the next step.
    do { try store.releaseAcknowledgedBacklog() } catch { _ = CloudSyncDiagnostics.shared.report("space: releasing sent project-folder pieces", error) }
  }
  /// A finished setup's staging rows (the cut and any verified-inventory staging) are no longer needed.
  private func dropSetupStaging(_ cut: String) throws {
    try store.dropStaging(cut)
    for row in try store.rows("SELECT DISTINCT snapshotId FROM snapshot_records WHERE snapshotId>=? AND snapshotId<?", [Data(("verified:" + cut + ":").utf8), Data(("verified:" + cut + ";").utf8)]) {
      try store.dropStaging(String(decoding: row[0], as: UTF8.self))
    }
  }
  /// An own record whose sealed file bytes were already dropped (the cloud has them): this Mac produced it, its
  /// adapter holds it, so it is not handed to the adapter again (that would mean downloading the file back).
  private func ownWithDroppedFile(_ op: CloudOperation) throws -> Bool {
    guard try !store.rows("SELECT opId FROM outbox WHERE opId=?", [Data(op.opId.utf8)]).isEmpty else { return false }
    // Round 6 S7c: only the SAME record is this Mac's own. A record reusing the id with other content is not
    // skipped here; it goes through the identity check and is parked as a conflict.
    do { try store.checkIdentity([op]) }
    catch let failure as CloudFailure where failure == .idReused || failure == .invalidRequest { return false }
    let ids = Set(try CloudSyncSealedFile.references(in: [op]).map(\.blobId) + store.fileReferences(for: [op.opId]).map(\.blobId))
    for id in ids {
      if try !store.rows("SELECT blobId FROM objects WHERE blobId=? AND length(bytes)=0", [Data(id.utf8)]).isEmpty { return true }
    }
    return false
  }
  public func register(adapter: any CloudDomainAdapter) async throws {
    let sources = try await adapter.sourceInventory()
    guard sources.allSatisfy({ brainDomains.contains($0.domain) || secretsDomains.contains($0.domain) }) else { throw CloudFailure.unsupportedFormat }
    for domain in Set(sources.map(\.domain)) {
      guard adapters[domain] == nil else { throw CloudFailure.idReused }
    }
    // 13 Nov (two-copy proof): an adapter with nothing to list yet (boot files before a project folder is chosen on
    // this Mac) still owns its domain, so packs of that kind are applied (or wait inside it) instead of waiting
    // for a kind that never registers.
    let declared = (adapter as? any CloudDomainDeclaring)?.declaredDomains ?? []
    guard declared.allSatisfy({ brainDomains.contains($0) || secretsDomains.contains($0) }) else { throw CloudFailure.unsupportedFormat }
    for domain in declared.subtracting(sources.map(\.domain)) { guard adapters[domain] == nil else { throw CloudFailure.idReused } }
    // Known before its sources' coverage is first written below.
    if adapter is any CloudDomainWithoutSetup { withoutSetup.formUnion(declared) }
    for source in sources {
      try store.set("coverage-domain:" + source.sourceId, source.domain)
      guard adapter.inventoryRows.contains(source.inventoryRow) else { throw CloudFailure.invalidRequest }
      try setLocalCoverage(source)
      adapters[source.domain] = adapter
    }
    for domain in declared where adapters[domain] == nil { adapters[domain] = adapter }
    // N2: packs that waited for one of these kinds are read again at the next pull.
    if try store.kindWaitingCount() > 0 { pullRequested = true; scheduleSend() }
  }
  public func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
    try await enqueueOwned(operations, files: files, associations: [])
  }
  /// The contract's association call (CloudOutboxPort); replaces the refusing default for this outbox.
  public func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob], associations: [CloudFileAssociation]) async throws -> CloudLocalReceipt {
    try await enqueueOwned(operations, files: files, associations: associations)
  }
  private func enqueueOwned(_ operations: [CloudOperation], files: [CloudLocalBlob], associations: [CloudFileAssociation]) async throws -> CloudLocalReceipt {
    try Self.checkRecordSizes(operations)
    try validateClasses(operations)
    // 13 Nov blocker: a record that could never be packed (an id outside the version-4 layout, for one) is refused
    // here, where its producer hears it, instead of entering the queue and stopping every later send.
    try CloudSyncPack.validateStructure(operations)
    guard files.isEmpty || !operations.isEmpty else { throw CloudFailure.invalidRequest }
    if !files.isEmpty {
      // Live files are staged under the same bound and free-disk floor; the producer keeps its copy and retries.
      let incoming = files.reduce(Int64(0)) { $0 + $1.bytes }
      if let free = staging.freeBytes(store.root), free < staging.minimumFreeBytes {
        try store.set("stagingPaused", "Uploads are paused: this Mac is low on free disk space.")
        throw CloudFailure.unavailable
      }
      guard try store.stagedBytes() + incoming <= staging.maximumStagedBytes else {
        try store.set("stagingPaused", "Uploads are catching up: this Mac's staging limit is full.")
        sendRequested = true; scheduleSend()
        throw CloudFailure.unavailable
      }
    }
    let receipt = try store.enqueue(operations, files: files, associations: associations)
    try fault(.afterLocalWrite)
    sendRequested = true
    scheduleSend()
    return receipt
  }
  /// Nothing unsendable may enter the queue: a record must fit one live pack (contract CloudWire limits).
  private static func checkRecordSizes(_ operations: [CloudOperation]) throws {
    for op in operations {
      // The service refuses any pack whose domain breaks its name rule (round 5 item A): refuse at enqueue.
      guard CloudWire.isValidDomainName(op.domain) else { throw CloudDomainNameInvalid(domain: op.domain) }
      let payload = try CloudSyncCanonical.encode(op.payload).count
      guard payload <= CloudWire.maximumRecordPayloadBytes else { throw CloudRecordTooLarge(operationId: op.opId, bytes: payload, limit: CloudWire.maximumRecordPayloadBytes) }
      let whole = try CloudSyncCanonical.encode(op).count
      guard whole <= CloudWire.maximumRecordBytes else { throw CloudRecordTooLarge(operationId: op.opId, bytes: whole, limit: CloudWire.maximumRecordBytes) }
    }
  }
  private func validateClasses(_ operations: [CloudOperation]) throws {
    for op in operations {
      guard brainDomains.contains(op.domain) || secretsDomains.contains(op.domain) || op.domain == Self.coverageDomain else { throw CloudFailure.unsupportedFormat }
      if secretsDomains.contains(op.domain) {
        // This payload is already encrypted by V. Never ask V to open this inner envelope here.
        let envelope = try decodeEnvelope(CloudSyncCanonical.encode(op.payload))
        guard envelope.storageClass == .secrets, envelope.purpose.permits(.secrets), envelope.epoch > 0 else { throw CloudFailure.unsupportedFormat }
        try CloudSyncSealedFile.validate(CloudSyncCanonical.encode(envelope), reference: CloudSyncBytes.blob(CloudSyncCanonical.encode(envelope), envelope: envelope))
      }
    }
  }
  private func port(for storageClass: CloudStorageClass) throws -> any CloudContentPort {
    if storageClass == .brain { return content }
    guard let secretsContent else { throw CloudFailure.secretsLocked }
    return secretsContent
  }
  public func coverage(sourceId: String) async throws -> CloudCoverage {
    guard let coverage: CloudCoverage = try store.value("coverage:" + sourceId) else { throw CloudFailure.invalidRequest }
    return try reported(coverage, notes: unattributedNotes())
  }
  /// Stored coverage, read by key range on the metadata primary key (not a scan of all metadata).
  private func allCoverage() throws -> [CloudCoverage] {
    try store.prefixed("coverage:").map { try JSONDecoder().decode(CloudCoverage.self, from: $0.1) }
  }
  /// Coverage as reported through the port: protected warnings and unlinked-file notes appear as reasons
  /// on saved-password sources. They never change `complete`, so memory readiness is unaffected.
  private func reportedCoverage() throws -> [CloudCoverage] {
    let notes = try unattributedNotes()
    // 0.23.6 (CPU): the queue facts are read once per report, not once per source (25 sources on the Mac mini).
    let facts = try queueFacts()
    return try allCoverage().map { try reported($0, notes: notes, facts: facts) }
  }
  /// 0.23.6 (CPU, Mac mini 23 Nov): what holds queued or parked records back, per source. Read for each of the 25
  /// sources at every progress read (every 2 s while anything waits), the held-for-files walk alone took 1.0 s each
  /// over 201,528 waiting rows: 25 s of work every 27 s, on the sync core, which the sends then waited for.
  struct QueueFacts {
    var behindParked: [String: Int] = [:]
    var parked: [String: (count: Int, reason: String)] = [:]
    var parkedSends: [String: (count: Int, reason: String)] = [:]
    var held: [String: Int] = [:]
    var missing: [String: Int] = [:]
  }
  func queueFacts() throws -> QueueFacts {
    QueueFacts(behindParked: try waitingBehindParkedSends(), parked: try parkedBySource(), parkedSends: try sendParkedBySource(),
               held: try heldForFiles(), missing: try missingSetupFiles())
  }
  private func unattributedNotes() throws -> [String: Int] {
    var totals: [String: Int] = [:]
    for (_, value) in try store.prefixed("unattributedProtectedFiles:") {
      for (source, count) in try JSONDecoder().decode([String: Int].self, from: value) { totals[source, default: 0] += count }
    }
    return totals
  }
  static let heldForFilesQuery = "SELECT DISTINCT r.bytes FROM outbox_files f CROSS JOIN outbox ON outbox.opId=f.opId CROSS JOIN records r ON r.opId=outbox.opId WHERE outbox.state='queued' AND NOT EXISTS (SELECT 1 FROM objects o WHERE o.blobId=f.blobId)"
  /// Queued records held back because a file they were handed with is not on this Mac, per source.
  private func heldForFiles() throws -> [String: Int] {
    var totals: [String: Int] = [:]
    // 0.23.6 (CPU): from the file links first (CROSS JOIN keeps that order). Led by the waiting rows, SQLite read the
    // record of every one of them (201,528) to find none with a file: 1.0 s per call.
    for row in try store.rows(Self.heldForFilesQuery) {
      totals[try JSONDecoder().decode(CloudOperation.self, from: row[0]).source.sourceId, default: 0] += 1
    }
    return totals
  }
  /// Files named by setup records that are not on this Mac, per source (round 4 S2).
  private func missingSetupFiles() throws -> [String: Int] {
    var totals: [String: Int] = [:]
    for (_, value) in try store.prefixed("bootstrapMissingFiles:") {
      for (source, ids) in try JSONDecoder().decode([String: [String]].self, from: value) { totals[source, default: 0] += ids.count }
    }
    return totals
  }
  private func reported(_ coverage: CloudCoverage, notes: [String: Int], facts known: QueueFacts? = nil) throws -> CloudCoverage {
    let facts = try known ?? queueFacts()
    let domain: String? = try store.value("coverage-domain:" + coverage.sourceId)
    var reasons = coverage.blockedReasons
    var complete = coverage.complete
    if let paused: String = try store.value("stagingPaused") { reasons.append(paused); complete = false }
    if let paused: String = try store.value("downloadPaused") { reasons.append(paused); complete = false }
    // The service keeps refusing this Mac's clock (CloudSyncTransport, after one corrected retry).
    if let skew: String = try store.value("clockSkew") { reasons.append(skew); complete = false }
    if let blocked: String = try store.value("publishBlocked") { reasons.append(blocked); complete = false }
    if let stopped: String = try store.value("sendStopped"), let domain, brainDomains.contains(domain) || secretsDomains.contains(domain) { reasons.append(stopped); complete = false }
    if let waiting = facts.behindParked[coverage.sourceId], waiting > 0 {
      reasons.append("\(waiting) edits wait behind an earlier edit of the same record that could not be sent.")
      complete = false
    }
    if let parked = facts.parked[coverage.sourceId], parked.count > 0 {
      reasons.append("\(parked.count) records could not be applied on this Mac and are kept for retry: \(parked.reason)")
      complete = false
    }
    if let parkedSends = facts.parkedSends[coverage.sourceId], parkedSends.count > 0 {
      reasons.append("\(parkedSends.count) edits could not be sent and are kept here: \(parkedSends.reason)")
      complete = false
    }
    if let held = facts.held[coverage.sourceId], held > 0 {
      reasons.append("\(held) records wait for a file that is not on this Mac; they send once it is handed over.")
      complete = false
    }
    if let missing = facts.missing[coverage.sourceId], missing > 0 {
      reasons.append("\(missing) files named by records are not on this Mac, so setup cannot finish; hand them over or start setup again.")
      complete = false
    }
    if let count = notes[coverage.sourceId], count > 0 { reasons.append("\(count) saved-password files were not linked to a record; they upload with the setup snapshot.") }
    var exclusions = coverage.exclusions
    if let domain, secretsDomains.contains(domain) {
      for key in ["protectedSendFailure", "protectedFailure"] { if let text: String = try store.value(key) { reasons.append(text) } }
      let packs = Int(String(decoding: try store.rows("SELECT count(*) FROM parked_packs")[0][0], as: UTF8.self)) ?? 0
      if packs > 0 { reasons.append("\(packs) saved-password packs cannot be opened on this Mac yet; they are kept and retried."); complete = false }
      let retired = Int(String(decoding: try store.rows("SELECT count(*) FROM retired_sends JOIN outbox ON outbox.opId=retired_sends.opId WHERE outbox.domain=?", [Data(domain.utf8)])[0][0], as: UTF8.self)) ?? 0
      // Round 6 S6: a retired item may be the only copy of that change: a GAP until saved passwords re-save it
      // under the new key or confirm it is not needed (`confirmRetired`).
      if retired > 0 { reasons.append("\(retired) saved-password items were sealed with an older key and never uploaded; they wait to be saved again under the new key."); complete = false }
      let superseded = Int(String(decoding: try store.rows("SELECT count(*) FROM superseded_packs")[0][0], as: UTF8.self)) ?? 0
      if superseded > 0 { exclusions.append("\(superseded) saved-password packs were sealed with an older key that the new key replaced; no device can open them.") }
    }
    if let domain, brainDomains.contains(domain), let text: String = try store.value("memoryProtectedRefusal") {
      reasons.append(text); complete = false
    }
    guard reasons != coverage.blockedReasons || complete != coverage.complete || exclusions != coverage.exclusions else { return coverage }
    return .init(sourceId: coverage.sourceId, inventoryRow: coverage.inventoryRow, complete: complete, items: coverage.items,
      bytes: coverage.bytes, blockedReasons: Array(Set(reasons)).sorted(), exclusions: Array(Set(exclusions)).sorted())
  }
  /// X3: true from creation until the account tells whether the person paused sync. Steps wait, saying "starting up".
  private var startingUp = false
  public func holdForStartup() async throws { startingUp = true }
  public func setPaused(_ paused: Bool) async throws {
    startingUp = false
    try store.set("paused", paused)
    if !paused { sendRequested = true; pullRequested = true; scheduleSend() }
  }
  /// What readiness names as missing while the baseline is not settled.
  private var unsettledBaselineLabel: String { firstUpload ? "Verified cloud inventory" : "This Mac's setup" }
  /// The baseline is settled: an inventory was imported (first upload), or this Mac's setup finished without one
  /// (lean first version: baseline "feed", the feed itself is the baseline).
  private func baselineSettled() throws -> Bool {
    let imported: Bool = try store.value("inventoryVerified") ?? false
    let baseline: String? = try store.value("baseline")
    return imported || baseline == "feed"
  }
  private func scheduleSend() {
    // Also while this Mac's own baseline is still going up: that upload IS the ordinary send.
    let initialized = (try? baselineSettled()) == true || (try? store.value("feedBaseline") as FeedBaseline?) != nil
    guard automatic, (pullRequested || (sendRequested && initialized)), !busy, sendTask == nil else { return }
    let pullFirst = pullRequested
    let send = sendRequested && initialized
    pullRequested = false
    if send { sendRequested = false }
    sendTask = Task {
      var failed = false
      do {
        // MAC-NEXT-5: these WAIT for a step running alongside (never refused "busy"), and a long download is read
        // in slices with this Mac's own sends in between (a joining Mac's records do not wait for all of it).
        // X2 (13 Nov): this Mac's own queued records go FIRST (rule J makes an early send safe), then a slice of the
        // download, which yields after `scheduledSlice` seconds to any own work waiting, then whatever was queued
        // meanwhile. Before, the fetch ran first and a joining Mac's records waited behind 3.5 minutes of it.
        var sent = false
        if send, ((try? store.queuedCount()) ?? 0) > 0 { _ = try await flush(waiting: true); sent = true }
        if pullFirst { _ = try await pull(waiting: true, pageLimit: Self.scheduledFeedPages, slice: Self.scheduledSlice) }
        if send, !sent || ((try? store.queuedCount()) ?? 0) > 0 { _ = try await flush(waiting: true) }
        localRetryStreak = 0
      } catch {
        // MAC-NEXT-5 (two real Macs, 13 Nov): a step that ended without doing its work, for ANY reason (busy,
        // a local refusal such as idReused, cancelled), leaves its request pending and arms a timed retry. Before,
        // the request was cleared up front and only a counted network failure armed a timer: queued records then
        // waited, silently, for the next local change (244 s on the Mac mini; for ever on a joining MacBook).
        failed = true
        if pullFirst { pullRequested = true }
        if send { sendRequested = true }
        try? store.set("blocked", true)
      }
      // The timer is armed BEFORE this step counts as ended: there is no moment with queued records and neither.
      if failed { armRetryNow() }
      // 0.23.4 (fault 4c): a quiet moment (the step went well, no other step running) may give space back to the disk.
      else { await compactIfDue() }
      sendTask = nil
      if !failed { scheduleSend() }
      scheduleWake()
    }
  }
  /// Feed pages (of 128 packs) the scheduler reads before it lets this Mac's own sends go (it then reads on).
  static let scheduledFeedPages = 2
  /// 0.23.4 (fault 4c): `sync.sqlite` is rewritten without its empty pages only when they are worth it (at least 1 GB
  /// and half the file), the upload queue is down to the staging bound (what waited to go up has gone, so the space
  /// came free), the disk has twice the live data and the 5 GB floor besides, and no compaction ran in the last 7 days
  /// (in practice: once, after a backlog like the Mac mini's 7 GB of project folders went up).
  var compactMinimumFreeBytes: Int64 = 1 << 30
  /// Tests compact a small store.
  func setCompactMinimumFreeBytes(_ bytes: Int64) { compactMinimumFreeBytes = bytes }
  static let compactGapMilliseconds: Int64 = 7 * 86_400_000
  /// Returns true when the file was compacted.
  @discardableResult
  func compactIfDue() async -> Bool {
    // Quiet = no step running and none waiting for the engine. Sends asked for meanwhile wait the minute it takes
    // (the pump keeps asking while project folders go up, which would otherwise never leave a moment).
    guard !busy, busyWaiters.isEmpty else { return false }
    guard let space = try? store.fileSpace(), space.free >= compactMinimumFreeBytes, space.free * 2 >= space.file else { return false }
    if let at = (try? store.value("compactedAt") as Int64?).flatMap({ $0 }), CloudSyncBytes.now() - at < Self.compactGapMilliseconds { return false }
    // The rewrite needs about twice the live data (a temporary copy and the log) on top of the 5 GB floor (Decker, 21 Nov).
    let needed = 2 * (space.file - space.free) + staging.minimumFreeBytes
    guard let disk = staging.freeBytes(store.root), disk >= needed else {
      stateLine("compact:disk", "space: \(Self.gigabytes(space.free)) of sync.sqlite is empty; it is given back when the disk has \(Self.gigabytes(needed)) free")
      return false
    }
    guard let queued = try? store.queuedBytes(domain: nil, stopAfter: staging.maximumStagedBytes), queued <= staging.maximumStagedBytes else { return false }
    busy = true
    defer { endBusy() }
    // Said BEFORE it starts, so an app closed meanwhile leaves the reason in the log (SQLite keeps the old file whole).
    CloudSyncDiagnostics.shared.info("space: giving \(Self.gigabytes(space.free)) of empty space in sync.sqlite back to the disk")
    let root = store.root, started = Date()
    let result = await Task.detached(priority: .background) { Result { try CloudSyncStore.compact(root: root) } }.value
    let seconds = Int(Date().timeIntervalSince(started).rounded())
    switch result {
    case .success:
      let after = (try? store.fileSpace())?.file ?? space.file
      try? store.set("compactedAt", CloudSyncBytes.now())
      CloudSyncDiagnostics.shared.info("space: sync.sqlite went from \(Self.gigabytes(space.file)) to \(Self.gigabytes(after)) in \(seconds) s")
      return true
    case .failure(let error):
      // Not marked as done: the next quiet moment tries again. Nothing was lost (SQLite keeps the old file until done).
      _ = CloudSyncDiagnostics.shared.report("space", error)
      return false
    }
  }
  static func gigabytes(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1_000_000_000) }
  /// 0.23.4 (fault 1): see `CloudOutboxPort.queuedBytes`.
  public func queuedBytes(domain: String, stopAfter: Int64) async throws -> Int64? {
    try store.queuedBytes(domain: domain, stopAfter: stopAfter)
  }
  /// X2: seconds a download slice runs before this Mac's own waiting work (its records, its first copy) goes.
  static let scheduledSlice: TimeInterval = 10
  private var wakeTask: Task<Void, Never>?
  /// Slow timer for parked records and paced saved-password work: wakes a pull/flush when the earliest
  /// back-off is due (at least one second away), only while automatic sync runs.
  private func scheduleWake() {
    guard automatic, wakeTask == nil else { return }
    let parkedNext = (try? store.rows("SELECT min(nextAt) FROM parked_ops WHERE nextAt>0"))?.first.flatMap { Int64(String(decoding: $0[0], as: UTF8.self)) }
    let sendsNext = (try? store.rows("SELECT min(p.nextAt) FROM parked_sends p JOIN outbox o ON o.opId=p.opId WHERE o.state='parked' AND p.permanent=0"))?.first.flatMap { Int64(String(decoding: $0[0], as: UTF8.self)) }
    let protectedNext = try? store.value("protectedRetryAt") as Int64?
    let stoppedUntil = (try? store.value("sendStoppedUntil") as Int64?).flatMap { $0 }.flatMap { $0 > CloudSyncBytes.now() ? $0 : nil }
    // A "slow down" (13 Nov) resumes by itself, at its own short time. 14 Nov: there is no day's allowance wait.
    let allowanceNext = (try? store.value("budget") as CloudSyncBudgetSnapshot?).flatMap { $0 }.flatMap { state -> Int64? in
      // MAC-NEXT-12b: no block without a timer. A sign-in block (device_revoked) and a network pause are asked
      // again too: one signed status read; served, the block lifts (`CloudSyncBudget.served(deviceProven:)`).
      if state.blocked == "auth" { return CloudSyncBytes.now() + Int64(allowanceProbeSeconds * 1000) }
      if state.blocked == "network" { return state.retryAt > CloudSyncBytes.now() ? state.retryAt : CloudSyncBytes.now() + 1_000 }
      return state.blocked == "rate" && state.retryAt > CloudSyncBytes.now() ? state.retryAt : nil
    }
    guard let at = [parkedNext, sendsNext, protectedNext ?? nil, stoppedUntil, allowanceNext].compactMap({ $0 }).filter({ $0 > 0 }).min() else { return }
    let delay = max(min(1_000, Int64(allowanceProbeSeconds * 1000)), at - CloudSyncBytes.now())
    wakeTask = Task {
      do { try await Task.sleep(for: .milliseconds(delay)) } catch { wakeTask = nil; return }
      await probeAllowance()
      wakeTask = nil
      pullRequested = true; sendRequested = true
      scheduleSend()
    }
  }
  /// A wait with a name and its own end, or one only the person ends: no local retry timer is armed for these
  /// (the wake timer ends the timed ones). nil when nothing names the wait.
  private func namedWait(_ state: CloudSyncBudgetSnapshot?) -> (reason: String, until: Int64?)? {
    let now = CloudSyncBytes.now()
    if startingUp { return ("Cloud is starting up on this Mac", nil) }
    if (try? store.value("paused") as Bool?) == true { return ("sync is paused by the person", nil) }
    if let state {
      if state.blocked == "rate", state.retryAt > now { return ("Cloud asked this Mac to slow down", state.retryAt) }
      if state.blocked == "auth" { return ("Cloud needs a new sign-in on this Mac", nil) }
      if state.blocked == "remote" { return ("Cloud refused the upload; Try again sends it again", nil) }
    }
    if let stopped = (try? store.value("sendStoppedUntil") as Int64?).flatMap({ $0 }), stopped > now { return ("Cloud refused three uploads in a row", stopped) }
    return nil
  }
  /// MAC-NEXT-5: after ANY failed or refused step, a timed retry: the service's own back-off when it gave one,
  /// otherwise 2 s doubling to 60 s (reset by a step that succeeds). Not for a named wait (above): the wake timer
  /// ends a timed one, the person ends the others.
  /// The timer is armed at once, synchronously (MAC-NEXT-6: the invariant broke in the moments the old code spent
  /// awaiting the budget before arming it, and after clearing it before asking for the next step). Inside the timer:
  /// a named wait hands over to the wake timer or the person; otherwise it sleeps its delay and asks for a step.
  private func armRetryNow() {
    guard automatic, retryTask == nil else { return }
    retryTask = Task {
      let state = try? await budget.status()
      let now = CloudSyncBytes.now()
      if let wait = namedWait(state) {
        stateLine("waiting:" + wait.reason, "waiting: " + wait.reason + (wait.until.map { ", for \(max(1, ($0 - now + 999) / 1000)) s" } ?? "") + heldNote())
        retryTask = nil
        scheduleWake()
        return
      }
      let delay: Int64
      if let state, state.failures > 0, state.retryAt > now { delay = state.retryAt - now }
      else { delay = min(60_000, Int64(2_000) << Int64(min(localRetryStreak, 5))); localRetryStreak += 1 }
      stateLine("waiting:retry", "waiting: the last Cloud step did not finish; trying again in \(max(1, delay / 1000)) s" + heldNote())
      do {
        try await transport.backoff(milliseconds: max(1, delay))
        try Task.checkCancellation()
      } catch { retryTask = nil; return }
      // Five network failures in a row block sending until a wake; this timer is that check, now.
      if (try? await budget.status())?.blocked == "network" { try? await budget.resume(networkOrWake: true) }
      retryTask = nil
      pullRequested = true
      sendRequested = true
      scheduleSend()
    }
  }
  #if DEBUG
  /// Test seam: nil while the invariant holds (records queued and sync not paused and no named wait => a send is
  /// running or a timer is armed); otherwise what is wrong. `idle` is true when no step is running.
  func debugSyncInvariant() async -> (idle: Bool, broken: String?) {
    // The one suspension first: everything below is read at the same moment.
    let state = try? await budget.status()
    let idle = sendTask == nil && !busy
    let queued = (try? store.queuedCount()) ?? 0
    let blocked = ((try? store.value("blocked") as Bool?) ?? nil) ?? false
    if namedWait(state) != nil { return (idle, nil) }
    if sendTask != nil || busy || retryTask != nil || wakeTask != nil { return (idle, nil) }
    if queued > 0 { return (idle, "\(queued) records queued with no send running and no timer armed") }
    if blocked { return (idle, "blocked with no timer and no named wait") }
    return (idle, nil)
  }
  #endif
  private func refreshRegistration() async throws {
    guard let registration = transport as? any CloudSyncRegistrationPort else { return }
    let current = try await registration.currentDeviceId()
    try CloudSyncBytes.transportID(current)
    let owner: String? = try store.value("activeOutboxDevice")
    guard owner == deviceId || owner == current else { throw CloudFailure.unavailable }
    if current != deviceId {
      // A signer fixed to the old registration would sign new attempts with a key the service no longer accepts.
      guard signerFollowsRegistration else { throw CloudFailure.unsafeConfiguration }
      try store.bindDevice(current); deviceId = current
    }
    try await budget.registered(deviceId: current)
  }
  /// Claims the engine before touching the registration, so a rebind can never happen underneath a
  /// suspended flush, pull or bootstrap (which would spend the one-time sign-in reset and then fail).
  private func admit(bootstrap: Bool = false, waiting: Bool = false) async throws {
    if busy, waiting { try await waitUntilFree() }
    if launchAttemptPending { launchAttemptPending = false; try? await budget.resume(networkOrWake: false, launch: true) }
    // 13 Nov blocker: a refusal here sends nothing, so it names itself for the one log line.
    guard !busy else {
      CloudSyncDiagnostics.shared.noteBusy("this Mac's sync was busy with another step")
      // MAC-NEXT-5: the refused caller's work is not dropped: the scheduler fetches and sends once the step ends.
      pullRequested = true; sendRequested = true
      throw CloudFailure.unavailable
    }
    busy = true
    do {
      try await refreshRegistration()
      let active: String? = try store.value("activeOutboxDevice")
      guard active == deviceId else { CloudSyncDiagnostics.shared.noteLocal("another sign-in owns this Mac's queue"); throw CloudFailure.unavailable }
      let cut: String? = try store.value("bootstrapInProgress")
      if startingUp { CloudSyncDiagnostics.shared.noteLocal("Cloud is starting up on this Mac"); throw CloudFailure.unavailable }
      if try store.value("paused") ?? false { CloudSyncDiagnostics.shared.noteLocal("sync is paused by the person"); throw CloudFailure.unavailable }
      guard bootstrap || cut == nil else { CloudSyncDiagnostics.shared.noteBusy("the first saved copy is still being made"); throw CloudFailure.unavailable }
    } catch { endBusy(); throw error }
  }
  public func flush() async throws -> [CloudReceipt] { try await flush(waiting: false) }
  private func flush(waiting: Bool) async throws -> [CloudReceipt] {
    try await admit(waiting: waiting)
    defer { endBusy(); scheduleSend() }
    do {
      let result = try await flushOwned()
      if !result.isEmpty { _ = try await pullOwned(pageLimit: Self.scheduledFeedPages, slice: Self.scheduledSlice) }
      try await budget.succeeded()
      try store.set("blocked", false)
      localRetryStreak = 0
      if lastStateKey.hasPrefix("waiting:") { stateLine("resumed", "resumed") }
      try noteLevel()
      CloudSyncDiagnostics.shared.succeeded()
      try store.execute("DELETE FROM metadata WHERE key=?", [Data("memoryProtectedRefusal".utf8)])
      // The queue drained without a refusal stop (a paused flush sends nothing and keeps the reason).
      if ((try store.value("sendStoppedUntil") as Int64?) ?? 0) <= CloudSyncBytes.now() {
        for key in ["sendStopStreak", "sendStoppedUntil", "sendStopped"] { try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)]) }
      }
      // This Mac's own baseline settles once the last of it went up, by whichever send that was.
      try await settleFeedBaselineIfSent()
      try releaseSettled()
      if try store.stagedBytes() < staging.maximumStagedBytes, (try store.value("bootstrapInProgress") as String?) == nil {
        try store.execute("DELETE FROM metadata WHERE key=?", [Data("stagingPaused".utf8)])
      }
      return result
    }
    catch { throw try await recordFailure(error, "send") }
  }
  private func recordFailure(_ error: Error, _ what: String) async throws -> CloudFailure {
    // 13 Nov blocker: never silent. One plain line per failed step (CloudSyncDiagnostics).
    if !(error is CancellationError) { CloudSyncDiagnostics.shared.report(what, error) }
    try store.set("blocked", true)
    // MAC-NEXT-5: whatever failed, its work stays requested and a timed retry is armed (never a silent stop).
    pullRequested = true; sendRequested = true
    defer { armRetryNow() }
    if error is CloudSyncTransferFailure { try await budget.failed(error) }
    if error as? CloudFailure == .secretsLocked {
      // A saved-password refusal that reached here hit a MEMORY step (protected work is parked earlier).
      // Pace it with the shared back-off and retry timer, and say so on memory coverage.
      try await budget.failed(CloudFailure.unavailable)
      try store.set("memoryProtectedRefusal", "The service refused a memory upload as saved-password work; retrying with back-off.")
    }
    return error as? CloudFailure ?? .unavailable
  }
  /// Feed links live about a minute. On the first expired link, the rest of the page is read again in ONE call
  /// and every later entry uses its renewed link, instead of paying one renewal call per pack.
  private var renewedLinks: [String: CloudChangeEntry] = [:]
  private func downloadEntry(_ entry: CloudChangeEntry) async throws -> Data {
    // Client cut 2: a pack this Mac committed and already read back byte-for-byte is not downloaded again;
    // its local ciphertext is used only when the feed entry's sequence, pack id, hash and size all match.
    if let id = entry.segmentId, let row = try store.rows("SELECT bytes,receipt FROM segments WHERE segmentId=?", [Data(id.utf8)]).first, !row[1].isEmpty {
      let segment = try JSONDecoder().decode(CloudSegment.self, from: row[0])
      let receipt = try JSONDecoder().decode(CloudReceipt.self, from: row[1])
      let bytes = try CloudSyncBytes.unbase64(segment.ciphertext)
      if receipt.seq == entry.seq, segment.descriptor.sha256 == entry.sha256, Int64(bytes.count) == entry.bytes,
        CloudSyncBytes.hash(bytes) == entry.sha256 { return bytes }
    }
    let renewed = renewedLinks[entry.seq.rawValue].flatMap { sameEntry($0, entry) ? $0.getUrl : nil }
    guard let url = renewed ?? entry.getUrl else { throw CloudFailure.invalidRequest }
    do { return try await objects.download(url, maximumBytes: 262_144) }
    catch CloudSyncTransferFailure.readExpired {
      guard let seq = UInt64(entry.seq.rawValue), seq > 0 else { throw CloudFailure.invalidRequest }
      let page = try await transport.changes(after: CloudSequence(seq - 1), limit: Self.feedPageLimit)
      renewedLinks = [:]
      for fresh in page.segments { renewedLinks[fresh.seq.rawValue] = fresh }
      guard let fresh = renewedLinks[entry.seq.rawValue], sameEntry(fresh, entry), let freshURL = fresh.getUrl else { throw CloudFailure.checksumMismatch }
      return try await objects.download(freshURL, maximumBytes: 262_144)
    }
  }
  // X5: transfer reads are paced in the transport (CloudSyncTransferPacer), where the service limit lives.
  private func sameEntry(_ a: CloudChangeEntry, _ b: CloudChangeEntry) -> Bool {
    a.seq == b.seq && a.segmentId == b.segmentId && a.sha256 == b.sha256 && a.bytes == b.bytes
  }
  /// Client cut 4: the Worker allows 128 feed entries per page.
  static let feedPageLimit = 128
  private func reconcileDeviceAttempts() async throws {
    let target: String? = try store.value("deviceReconciliation")
    let foreign = try store.foreignSegments(device: deviceId)
    guard target == deviceId || !foreign.isEmpty else { return }
    // A lost ACK may already be in the feed. Verify/apply it before replacing any signed attempt.
    _ = try await pullOwned()
    var protectedWaiting = false, offset = 0
    while true {
      let old = try store.foreignSegments(device: deviceId, offset: offset)
      if old.isEmpty { break }
      var retired = 0
      for (segment, _) in old {
        if segment.descriptor.storageClass == .secrets {
          let state = await secretsContent?.state(storageClass: .secrets)
          let protectedCursor: CloudSequence = try store.value("secretsSeq") ?? .zero
          let reconciledHead: CloudSequence = try store.value("brainSeq") ?? .zero
          if state?.available != true || protectedCursor < reconciledHead { protectedWaiting = true; continue }
        }
        // Keep the old encrypted attempt for audit/recovery. Its immutable operation IDs remain queued.
        try store.retireSegment(segment.descriptor.segmentId)
        retired += 1
      }
      offset += old.count - retired
      if old.count < 64 { break }
    }
    if !protectedWaiting { try store.execute("DELETE FROM metadata WHERE key=?", [Data("deviceReconciliation".utf8)]) }
  }
  /// Snapshot files whose protected upload was refused during bootstrap may be unattributed to any
  /// operation (opaque producer pages). They go up before any protected segment can reference them.
  /// Round 6 S4: the waiting files are listed by id in `protectedWaitingFiles`, outside the setup's staging rows
  /// (which go when setup ends), and launch reconciliation keeps their bytes until they are sent.
  private func sendWaitingProtectedSnapshotFiles() async throws {
    guard (try store.value("protectedSnapshotFilesWaiting") as Bool?) == true else { return }
    let waiting: [String] = try store.value("protectedWaitingFiles") ?? []
    var refs: [CloudBlobRef] = []
    for id in waiting {
      if let row = try store.rows("SELECT descriptor FROM objects WHERE blobId=? AND (receipt IS NULL OR length(receipt)=0)", [Data(id.utf8)]).first {
        refs.append(try JSONDecoder().decode(CloudBlobRef.self, from: row[0]))
      }
    }
    try await sendObjects(refs.filter { $0.storageClass == .secrets })
    for key in ["protectedSnapshotFilesWaiting", "protectedWaitingFiles"] { try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)]) }
  }
  private func noteWaitingProtectedFiles(_ refs: [CloudBlobRef]) throws {
    let old: [String] = try store.value("protectedWaitingFiles") ?? []
    try store.set("protectedWaitingFiles", Array(Set(old).union(refs.filter { $0.storageClass == .secrets }.map(\.blobId))).sorted())
    try store.set("protectedSnapshotFilesWaiting", true)
    try store.set("protectedSendFailure", "Saved passwords are waiting to upload.")
  }
  /// A service refusal of saved-password work is paced: no protected attempt before `protectedRetryAt`,
  /// doubling from one minute to six hours per consecutive refusal; any protected success resets it.
  private func protectedRefused() throws {
    let streak = ((try store.value("protectedRetryStreak") as Int?) ?? 0) + 1
    try store.set("protectedRetryStreak", min(streak, 64))
    try store.set("protectedRetryAt", CloudSyncBytes.now() + min(21_600_000, Int64(60_000) << Int64(min(streak - 1, 20))))
    try store.set("protectedSendFailure", "Saved passwords are waiting to upload.")
  }
  private func protectedSucceeded() throws {
    for key in ["protectedRetryStreak", "protectedRetryAt"] { try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)]) }
  }
  private func protectedPaced() throws -> Bool {
    ((try store.value("protectedRetryAt") as Int64?) ?? 0) > CloudSyncBytes.now()
  }
  /// After "Start new saved passwords" elsewhere (a newer secrets epoch), saved-password work sealed under an
  /// older key can never be opened by any device: its packs are retired and its records leave the send queue
  /// (state 'retired', kept with a reason, reported), never sent and never blocking what is queued behind them.
  private func retireOlderEpochProtected(currentEpoch: Int) async throws {
    guard currentEpoch > 0, !secretsDomains.isEmpty else { return }
    for row in try store.rows("SELECT segments.segmentId,segments.bytes FROM segments LEFT JOIN segment_bindings b ON b.segmentId=segments.segmentId WHERE segments.receipt IS NULL AND coalesce(b.retired,0)=0") {
      let segment = try JSONDecoder().decode(CloudSegment.self, from: row[1])
      if segment.descriptor.storageClass == .secrets, segment.descriptor.keyEpoch < currentEpoch { try store.retireSegment(segment.descriptor.segmentId) }
    }
    var older: [CloudOperation] = []
    for row in try store.rows("SELECT r.bytes FROM outbox JOIN records r ON r.opId=outbox.opId WHERE outbox.state='queued' AND outbox.domain IN (" + secretsDomains.sorted().map { _ in "?" }.joined(separator: ",") + ")",
      secretsDomains.sorted().map { Data($0.utf8) }) {
      let op = try JSONDecoder().decode(CloudOperation.self, from: row[0])
      if try decodeEnvelope(CloudSyncCanonical.encode(op.payload)).epoch < currentEpoch { older.append(op) }
    }
    guard !older.isEmpty else { return }
    try store.transaction {
      for op in older {
        try store.execute("UPDATE outbox SET state='retired' WHERE opId=?", [Data(op.opId.utf8)])
        try store.execute("INSERT OR REPLACE INTO retired_sends(opId,reason,retiredAt) VALUES (?,?,CAST(? AS INTEGER))",
          [Data(op.opId.utf8), Data("Sealed with an older saved-password key; the new key replaces it.".utf8), Data(String(CloudSyncBytes.now()).utf8)])
      }
    }
  }
  /// Kinds every other record may name: sent first (G).
  static let sentFirstDomains: Set<String> = ["projects", "agents"]
  /// 0.23.6 (Asad, 23 Nov: "why its not syncing properly from this mac"): pieces of his project folders go up LAST.
  /// 0.23.3 queued 211,000 of them (9 GB) before his newer memory notes, chats, settings, tasks and saved passwords,
  /// and the queue goes in row order, so those waited days behind them. Everything else is sent first, every pack.
  static let sentLastDomains: Set<String> = [CloudBrainFilesFormat.domain("I26")]
  /// 0.23.6 (CPU): a project-folder piece is ~41 KB as queued, so a sealed pack holds about 5. Reading 256 of them for
  /// each pack decoded 10.6 MB of JSON to send 5; 16 are read first and the full 256 only when they are small.
  static let sentLastFirstRead = 16
  /// 0.23.6: one send step ends after a minute while more waits (it is asked again at once), so the fetch of his other
  /// devices' changes and every other Cloud step get their turn. Before, ONE step ran until the whole backlog was sent:
  /// the Mac mini fetched nothing from 20 Nov 04:32 on and "Sync now" said "busy with another Cloud step".
  static let sendSliceMilliseconds: Int64 = 60_000
  var sendSlice = CloudSyncEngine.sendSliceMilliseconds
  /// Tests end a send step after one pack.
  func setSendSlice(_ milliseconds: Int64) { sendSlice = milliseconds }
  /// 0.23.6: the whole-store walk of `stubSettledRecords` while records still wait to go up.
  static let settledWalkGapMilliseconds: Int64 = 30 * 60_000
  private var lastSettledWalk: Int64 = 0
  private var sentRecords = 0, sentPacks = 0
  /// 0.23.6: the last send step ended by its slice (more waits); the next one continues its log lines and counts.
  private var sendSliceEnded = false
  private var sendingSince = Date()
  private func flushOwned() async throws -> [CloudReceipt] {
    // Sending paused after three refusals in a row: wait for the timed retry (pulls go on).
    if ((try store.value("sendStoppedUntil") as Int64?) ?? 0) > CloudSyncBytes.now() { return [] }
    // C: one line when sending starts and one when it ends (numbers only); a step that goes on after its slice is
    // the same sending (0.23.6), so it writes no new pair of lines.
    let continuing = sendSliceEnded
    sendSliceEnded = false
    let queued = try store.queuedCount()
    if !continuing { sentRecords = 0; sentPacks = 0; sendingSince = Date() }
    if queued > 0, !continuing { stateLine("sending", "sending started: \(queued) records queued") }
    defer {
      if sentPacks > 0, !sendSliceEnded { stateLine("sent", "sending finished: \(sentRecords) records in \(sentPacks) packs, \(Int(Date().timeIntervalSince(sendingSince).rounded())) s") }
    }
    return try await flushQueue()
  }
  /// 0.23.6: the queue read of one pack: projects and agents, then everything else of his, then project folders.
  func nextPending(_ sendableDomains: Set<String>) throws -> [CloudOperation] {
    let firstKinds = sendableDomains.intersection(Self.sentFirstDomains)
    if !firstKinds.isEmpty {
      let first = try store.pending(limit: 256, domains: firstKinds, deviceId: deviceId, sendable: true)
      if !first.isEmpty { return first }
    }
    let lastKinds = sendableDomains.intersection(Self.sentLastDomains)
    guard !lastKinds.isEmpty else { return try store.pending(limit: 256, domains: sendableDomains, deviceId: deviceId, sendable: true) }
    let others = try store.pending(limit: 256, domains: sendableDomains.subtracting(lastKinds), deviceId: deviceId, sendable: true)
    if !others.isEmpty { return others }
    let few = try store.pending(limit: Self.sentLastFirstRead, domains: lastKinds, deviceId: deviceId, sendable: true)
    guard few.count == Self.sentLastFirstRead else { return few }
    // Small pieces (small files): read on so a pack is filled as before.
    let plain = try few.reduce(0) { $0 + (try CloudSyncCanonical.encode($1).count) }
    return plain >= 2 * Self.packSealedBytes ? few : try store.pending(limit: 256, domains: lastKinds, deviceId: deviceId, sendable: true)
  }
  private func flushQueue() async throws -> [CloudReceipt] {
    try await reconcileDeviceAttempts()
    try retryParkedSends(force: launchSendRetryPending)
    launchSendRetryPending = false
    // This Mac's own baseline still going up: its setup files first, then its records as the ordinary queue.
    try await sendFeedBaselineFiles()
    // After a timed stop, ONE more refusal stops again (longer wait) instead of parking a record that the
    // service would refuse for any record.
    var refusedInARow = ((try store.value("sendStopStreak") as Int?) ?? 0) > 0 ? 2 : 0
    if let state = await secretsContent?.state(storageClass: .secrets), state.available { try await retireOlderEpochProtected(currentEpoch: state.epoch) }
    var receipts: [CloudReceipt] = []
    var protectedWait = try protectedPaced()
    let sliceStarted = CloudSyncBytes.now()
    while true {
      let protectedState = await secretsContent?.state(storageClass: .secrets)
      let allowSecrets = protectedState?.available == true && !protectedWait
      if let (segment, ids) = try store.unacknowledged(allowSecrets: allowSecrets, deviceId: deviceId).first {
        // Retrying a sealed segment does not require opening its content again.
        let operations = try ids.map { id -> CloudOperation in
          guard let row = try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(id.utf8)]).first else { throw CloudFailure.unavailable }
          return try JSONDecoder().decode(CloudOperation.self, from: row[0])
        }
        let refs = try store.fileReferences(for: ids) + CloudSyncSealedFile.references(in: operations)
        var unique: [String: CloudBlobRef] = [:]
        for ref in refs {
          if let previous = unique[ref.blobId], previous != ref { throw CloudFailure.idReused }
          unique[ref.blobId] = ref
        }
        do {
          if segment.descriptor.storageClass == .secrets { try await sendWaitingProtectedSnapshotFiles() }
          let dependencies = unique.values.sorted(by: { $0.blobId < $1.blobId })
          for ref in dependencies {
            if try store.rows("SELECT blobId FROM objects WHERE blobId=?", [Data(ref.blobId.utf8)]).isEmpty { _ = try await sealedFile(ref, sourceId: operations.first?.source.sourceId ?? "") }
          }
          try await sendObjects(dependencies)
        } catch CloudFailure.secretsLocked where segment.descriptor.storageClass == .secrets {
          // Only saved-password work waits; memory segments behind it continue in this same flush.
          protectedWait = true
          try protectedRefused()
          continue
        }
        let receipt: CloudReceipt
        // Round 6 M2: the clock learns only from a pack's FIRST send. A retried commit (lost answer, crash) gets
        // the first commit's receipt back with its old time, which must not be taken as "now". The mark is
        // durable before the first attempt.
        let sentOnceKey = "sent-once:" + segment.descriptor.segmentId
        let firstSend = (try store.value(sentOnceKey) as Bool?) != true
        if firstSend { try store.set(sentOnceKey, true) }
        let sentAt = CloudSyncBytes.now()
        do { receipt = try await transport.commit(segment) }
        catch CloudFailure.secretsLocked where segment.descriptor.storageClass == .secrets {
          // The service refuses protected writes for this device right now; memory continues.
          protectedWait = true
          try protectedRefused()
          continue
        } catch CloudFailure.remote(let detail) where !detail.retryable && CloudSyncTransport.packOnlyCodes.contains(detail.code) {
          // The service refused this pack for good. Several records: send each alone to find the one it
          // refuses. One record: park it (kept, reported, retried later) so the records behind it go on.
          // Three refused packs in a row look like a general refusal (round 5 M3): stop, record an account
          // failure and leave everything else QUEUED, not parked.
          try store.retireSegment(segment.descriptor.segmentId)
          refusedInARow += 1
          if refusedInARow >= 3 {
            // Round 6 S1: the stop retries by itself, one minute doubling to six hours; no person needed.
            let streak = ((try store.value("sendStopStreak") as Int?) ?? 0) + 1
            try store.set("sendStopStreak", min(streak, 64))
            try store.set("sendStoppedUntil", CloudSyncBytes.now() + Self.parkedGap(streak - 1))
            try store.set("sendStopped", "The service refused three uploads in a row (\(detail.code)); sending paused, edits stay queued and are retried automatically.")
            throw CloudFailure.remote(detail)
          }
          if ids.count > 1 { for id in ids { try store.set("send-alone:" + id, true) } }
          else if let op = operations.first { try parkSend(op, reason: "The service refused this edit (\(detail.code)); it is kept here and retried later.") }
          continue
        }
        // The authenticated receipt states the service's commit time: learn the service clock from it.
        if firstSend { try CloudSyncServiceClock.observe(store, serverTime: receipt.receipt.committedAt, sentAt: sentAt, receivedAt: CloudSyncBytes.now()) }
        try fault(.afterCommit)
        // A cloud ACK alone is not byte-recovery proof. Read the immutable segment back first.
        // A receipt is never at sequence 0; refuse it instead of trapping on the subtraction.
        guard let committed = UInt64(receipt.seq.rawValue), committed > 0 else { throw CloudFailure.checksumMismatch }
        let prior = CloudSequence(committed - 1)
        let page = try await transport.changes(after: prior, limit: 1)
        guard let entry = page.segments.first, entry.segmentId == segment.descriptor.segmentId,
          entry.sha256 == segment.descriptor.sha256, let url = entry.getUrl else { throw CloudFailure.checksumMismatch }
        let bytes = try await downloadEntry(entry)
        guard bytes == (try CloudSyncBytes.unbase64(segment.ciphertext)) else { throw CloudFailure.checksumMismatch }
        try store.acknowledge(segment, ids: ids, receipt: receipt)
        sentRecords += ids.count; sentPacks += 1
        refusedInARow = 0
        for key in ["sendStopStreak", "sendStoppedUntil", "sendStopped"] { try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)]) }
        try store.transaction {
          try store.execute("DELETE FROM metadata WHERE key=?", [Data(sentOnceKey.utf8)])
          for id in ids {
            try store.execute("DELETE FROM parked_sends WHERE opId=?", [Data(id.utf8)])
            try store.execute("DELETE FROM metadata WHERE key=?", [Data(("send-alone:" + id).utf8)])
          }
        }
        if segment.descriptor.storageClass == .secrets { try protectedSucceeded() }
        try store.set("headSeq", receipt.headSeq)
        receipts.append(receipt)
        // 0.23.6: a minute of sending is one step; the rest is asked for again at once, after a fetch.
        if CloudSyncBytes.now() - sliceStarted >= sendSlice, try store.queuedCount() > 0 {
          sendSliceEnded = true; sendRequested = true; pullRequested = true
          return receipts
        }
        continue
      }
      let sendableDomains = (allowSecrets ? brainDomains.union(secretsDomains) : brainDomains).union([Self.coverageDomain])
      // G (13 Nov): projects and agents go up before anything else queued (memory names them): a joining Mac then
      // knows a project before its memory arrives, instead of keeping tens of thousands of rows waiting for it.
      // 0.23.6: project-folder pieces after everything else (`nextPending`).
      let pending = try nextPending(sendableDomains)
      if pending.isEmpty {
        guard !protectedWait, allowSecrets else { return receipts }
        // Setup files whose protected upload was refused go up even when no protected pack is queued.
        do { try await sendWaitingProtectedSnapshotFiles() }
        catch CloudFailure.secretsLocked { try protectedRefused(); return receipts }
        // Everything this flush could send went out, saved passwords included: the send warning is over.
        try store.execute("DELETE FROM metadata WHERE key=?", [Data("protectedSendFailure".utf8)])
        return receipts
      }
      // One domain per live segment gives the existing writer a single transactional unit.
      let first = pending[0]
      var batch: [CloudOperation] = []
      // A canonical array is 2 + sum(record bytes) + (n - 1) commas: keep a running total and encode the
      // pack once. Packs group one domain (Decker, round 4): order is exact WITHIN a domain; there is no
      // cross-domain order, and adapters resolve a reference that arrives before its target late.
      var batchBytes = 2
      // A record that can never be sent (larger than one pack, e.g. queued by an older build) is parked, not
      // retried at the head of the queue for ever.
      if try CloudSyncCanonical.encode(first).count > CloudWire.maximumRecordBytes {
        try parkSend(first, reason: "This edit is larger than one upload can carry; it is kept here.")
        continue
      }
      let firstAlone: Bool = try store.value("send-alone:" + first.opId) ?? false
      let storageClass: CloudStorageClass = secretsDomains.contains(first.domain) ? .secrets : .brain
      // Mac-next 2 (d): a memory pack is filled up to the service's own rule (256 records, 256 KiB sealed), measured
      // on the SEALED bytes after compression; the old 180,000 plain-byte cap made the owner's first copy ~800 packs
      // instead of ~225. Up to 180,000 plain bytes always fits sealed (the old guarantee), so a pack is only ever made
      // smaller than before when compression did not help. Saved-password packs keep the old plain cap.
      let plainCap = storageClass == .brain ? brainPackPlainCap : Self.compatiblePackPlainBytes
      var sizes: [Int] = []
      for op in pending where op.domain == first.domain {
        guard batch.count < 256, !(firstAlone && !batch.isEmpty) else { break }
        if !batch.isEmpty, (try store.value("send-alone:" + op.opId) as Bool?) == true { break }
        let added = try CloudSyncCanonical.encode(op).count + (batch.isEmpty ? 0 : 1)
        if batchBytes + added > plainCap { break }
        batch.append(op); batchBytes += added; sizes.append(added)
      }
      guard !batch.isEmpty, try CloudSyncPack.encode(batch).count == batchBytes else { throw CloudFailure.unsupportedFormat }
      var id = UUID().uuidString.lowercased()
      let request = UUID().uuidString.lowercased()
      try validateClasses(batch)
      let contentPort = try port(for: storageClass)
      let state = await contentPort.state(storageClass: storageClass)
      // A missing MEMORY key is this Mac's own state, not a service refusal (S8): no saved-password wording.
      guard state.available, state.epoch > 0 else { throw storageClass == .brain ? CloudFailure.unavailable : CloudFailure.secretsLocked }
      let purpose: CloudPurpose = storageClass == .brain ? .brain : try decodeEnvelope(CloudSyncCanonical.encode(first.payload)).purpose
      if storageClass == .secrets {
        guard try batch.allSatisfy({ try decodeEnvelope(CloudSyncCanonical.encode($0.payload)).purpose == purpose }) else { throw CloudFailure.unsupportedFormat }
      }
      let keyEpoch = storageClass == .brain ? epoch : state.epoch
      var envelope = try await contentPort.seal(CloudSyncPack.encode(batch), blobId: id, storageClass: storageClass, purpose: purpose, epoch: keyEpoch, codec: .gzip)
      var bytes = try CloudSyncCanonical.encode(envelope)
      while bytes.count > Self.packSealedBytes, batch.count > 1, batchBytes > Self.compatiblePackPlainBytes {
        // Too big once sealed: keep the share that fits (with a margin), never below what the old cap would hold.
        let keep = max(1, min(batch.count - 1, Int(Double(batch.count) * Double(Self.packSealedBytes) * 0.9 / Double(bytes.count))))
        batch = Array(batch.prefix(keep)); sizes = Array(sizes.prefix(keep)); batchBytes = 2 + sizes.reduce(0, +)
        guard try CloudSyncPack.encode(batch).count == batchBytes else { throw CloudFailure.unsupportedFormat }
        // 13 Nov (MAC-NEXT-4): a smaller pack is a NEW pack with its own id. The content port never seals one id
        // twice (`idReused`), so re-sealing under the first id stopped the owner's upload for good at its first
        // pack that compressed too little (his memory files). Nothing of the bigger attempt was saved or sent.
        id = UUID().uuidString.lowercased()
        envelope = try await contentPort.seal(CloudSyncPack.encode(batch), blobId: id, storageClass: storageClass, purpose: purpose, epoch: keyEpoch, codec: .gzip)
        bytes = try CloudSyncCanonical.encode(envelope)
      }
      guard bytes.count <= 262_144 else { throw CloudFailure.invalidRequest }
      let unsigned = CloudSegmentDescriptor(segmentId: id, requestId: request, storageClass: storageClass, purpose: purpose,
        domains: [first.domain], keyEpoch: keyEpoch, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count),
        opCount: batch.count, format: "td-ops-1", signature: "")
      let signature = try await signer(deviceId, unsigned.syncSigningBytes(subject: subject))
      guard try CloudSyncBytes.unbase64(signature).count == 64 else { throw CloudFailure.invalidRequest }
      let descriptor = CloudSegmentDescriptor(segmentId: id, requestId: request, storageClass: storageClass, purpose: purpose,
        domains: unsigned.domains, keyEpoch: keyEpoch, sha256: unsigned.sha256, bytes: unsigned.bytes,
        opCount: unsigned.opCount, format: unsigned.format, signature: signature)
      try await budget.reserve(packs: 1)
      try store.saveSegment(.init(descriptor: descriptor, ciphertext: CloudSyncBytes.base64(bytes)), operationIds: batch.map(\.opId), deviceId: deviceId)
    }
  }
  /// Mac-next 2 (d): the service takes a pack of up to 256 records and 262,144 sealed bytes (feed.ts). This Mac
  /// stays ~12 KB under the byte rule; a pack's plain bytes are bounded so opening one stays small.
  static let packSealedBytes = 250_000
  static let brainPackPlainBytes = 2_000_000
  /// The cap every earlier build used: 180,000 plain bytes always fit 262,144 sealed, even without compression.
  static let compatiblePackPlainBytes = 180_000
  /// Tests make an older build's small packs with `compatiblePackPlainBytes`.
  var brainPackPlainCap = CloudSyncEngine.brainPackPlainBytes
  func setBrainPackPlainCap(_ bytes: Int) { brainPackPlainCap = bytes }
  public func pull() async throws -> [CloudImportReceipt] { try await pull(waiting: false, pageLimit: nil) }
  /// "Sync now" (13 Nov): one attempt past a network pause or a refusal; the service's answer decides.
  public func syncNow() async throws {
    try await budget.resume(networkOrWake: false, userRetry: true)
    // Parked memory (14 Nov): the line promises "Sync now tries again", but parked arrivals waited for their back-off
    // (up to six hours). His press tries every parked arrival at once, like a launch does.
    launchRetryPending = true
    _ = try? await pull(waiting: true, pageLimit: nil)
    _ = try await flush(waiting: true)
  }
  /// The first step after launch tries once, whatever network pause an earlier run stored.
  private var launchAttemptPending = true
  /// While a sign-in block is stored, one cheap signed request every `allowanceProbeSeconds` asks the service again.
  private var allowanceProbeSeconds: Double = 600
  #if DEBUG
  func setAllowanceProbe(seconds: Double) { allowanceProbeSeconds = seconds }
  #endif
  /// The probe: the account state read (never blocked locally). Served, the block lifts (`CloudSyncBudget.served`).
  private func probeAllowance() async {
    guard let blocked = (try? await budget.status())?.blocked, ["auth", "network"].contains(blocked) else { return }
    // The status read is signed with this device's proof (account read): its answer proves session and device.
    if (try? await transport.state()) != nil { try? await budget.served(deviceProven: true) }
  }
  /// `pageLimit`: the scheduler reads a long feed in slices (then asks for the rest), so sends go in between.
  private func pull(waiting: Bool, pageLimit: Int?, slice: TimeInterval? = nil) async throws -> [CloudImportReceipt] {
    try await admit(waiting: waiting)
    defer { endBusy(); scheduleSend() }
    do {
      let result = try await pullOwned(pageLimit: pageLimit, slice: slice)
      if try store.queuedCount() == 0 { try await budget.succeeded() }
      try store.set("blocked", false)
      localRetryStreak = 0
      if lastStateKey.hasPrefix("waiting:") { stateLine("resumed", "resumed") }
      try noteLevel()
      try releaseSettled()
      return result
    }
    catch { throw try await recordFailure(error, "fetch") }
  }
  /// One line when this Mac is level with Cloud (nothing queued, every position read), once per change.
  private func noteLevel() throws {
    guard try store.queuedCount() == 0, let head: CloudSequence = try store.value("headSeq"),
      let seq: CloudSequence = try store.value("brainSeq"), seq == head else { return }
    stateLine("level", "level with Cloud at position " + head.rawValue)
  }
  /// X2 (13 Nov): a slice of the download ends after `slice` seconds when this Mac has its own work waiting (records
  /// queued, a first copy or another step waiting for the engine); the rest is fetched right after that work.
  private func ownWorkWaiting() -> Bool {
    !busyWaiters.isEmpty || sendRequested || ((try? store.queuedCount()) ?? 0) > 0
  }
  /// X1: packs this Mac could not apply, refused here and listed; they are judged again on this timer (and at launch).
  private var localRefusedRecheckAt: Int64?
  private var packOpenFailures: [String: Int] = [:]
  static let packOpenAttempts = 3
  private static func isServiceOrNetworkFailure(_ error: Error) -> Bool {
    if error is CancellationError || error is CloudSyncTransferFailure || error is CloudSyncTrustWithdrawn { return true }
    if (error as NSError).domain == NSURLErrorDomain { return true }
    if error is CloudFailure { return !isLocalContentFailure(error) }
    // Anything else is this Mac's own (a record it cannot decode, a local store refusal).
    return false
  }
  /// One pack from the feed. X1 (13 Nov): a pack that fails on THIS Mac (not the network, not the service) never
  /// stops the packs after it. Failing while it is applied (the content cannot be taken here), it is refused with its
  /// reason, listed and judged again later; failing while it is opened (download, hash, seal) it is tried again,
  /// and after three failed tries it is listed the same way. Nothing is passed over silently: the line names it.
  private func receiveInFeed(_ entry: CloudChangeEntry) async throws -> [CloudImportReceipt] {
    lastPackStageApplying = false
    do {
      let receipts = try await receive(entry, cursorKey: "brainSeq")
      packOpenFailures[entry.seq.rawValue] = nil
      return receipts
    } catch let error where !Self.isServiceOrNetworkFailure(error) {
      let tries = (packOpenFailures[entry.seq.rawValue] ?? 0) + 1
      packOpenFailures[entry.seq.rawValue] = tries
      let applying = lastPackStageApplying
      guard applying || tries >= Self.packOpenAttempts else { throw error }
      packOpenFailures[entry.seq.rawValue] = nil
      if let id = entry.segmentId { try store.dropPrepared(id) }
      let kind = CloudSyncDiagnostics.kind(error)
      try refuseEntry(entry, reason: "This Mac could not \(applying ? "apply" : "open") this pack (\(kind)). It is kept in the list and checked again.", cursorKey: "brainSeq")
      localRefusedRecheckAt = CloudSyncBytes.now() + Self.localRecheckGap
      CloudSyncDiagnostics.shared.info("fetch: pack at position \(entry.seq.rawValue) could not be \(applying ? "applied" : "opened") on this Mac (\(kind)); it is listed and checked again, the feed goes on")
      return []
    }
  }
  static let localRecheckGap: Int64 = 10 * 60_000
  /// Set by `applyJudged`: true once the pack was opened and its records are being applied.
  private var lastPackStageApplying = false
  private func pullOwned(pageLimit: Int? = nil, slice: TimeInterval? = nil) async throws -> [CloudImportReceipt] {
    let sliceEnd = slice.map { Date().addingTimeInterval($0) }
    // Device trust, R6: the release comes FIRST on every path. A release for devices trusted since the last pull
    // runs here, and one interrupted by a restart resumes here, before a parked pack or record is retried and
    // before anything newer is read below.
    var receipts: [CloudImportReceipt] = try await releaseTrustedHeld()
    receipts += try await retryParkedOwned()
    receipts += try await retryKindWaiting()
    // Refused packs are judged again once at each launch, a bounded number, least-checked first: a refusal that
    // was right when made (a key stored wrongly, a service fault) does not stay a silent gap until a click.
    if launchRefusedCheckPending, case .list = trust {
      receipts += try await recheckRefused(store.refusedRowsToCheck(limit: Self.refusedChecksAtLaunch))
      launchRefusedCheckPending = false
    } else if let at = localRefusedRecheckAt, at <= CloudSyncBytes.now() {
      localRefusedRecheckAt = nil
      receipts += try await recheckRefused(store.refusedRowsToCheck(limit: Self.refusedChecksAtLaunch))
    }
    if brainDomains.isEmpty { return try await pullSavedPasswordsOnly(receipts) }
    var cursor: CloudSequence = try store.value("brainSeq") ?? .zero
    // No first upload in this version (the switch): nothing below is fetched or imported.
    if firstUpload {
      if let checkpoint: CloudCheckpoint = try store.value("pendingCheckpoint") {
        receipts += try await importCheckpoint(checkpoint)
        cursor = try store.value("brainSeq") ?? checkpoint.throughSeq
      }
      // Until this Mac holds a verified inventory, the account's checkpoint is imported before more feed,
      // even when this cursor already moved (e.g. a first inventory that landed after an earlier pull).
      // Otherwise its operations would arrive only at a later bootstrap, after their own descendants.
      let verifiedInventory: Bool = try store.value("inventoryVerified") ?? false
      if cursor == .zero || !verifiedInventory, let checkpoint = try await transport.checkpoint() {
        receipts += try await importCheckpoint(checkpoint)
        cursor = try store.value("brainSeq") ?? checkpoint.throughSeq
      }
    }
    var pagesRead = 0, fetched = 0, fetchedForeign = 0
    var fetchSince: Date?
    var slicedOff = false
    while true {
      if let sliceEnd, pagesRead > 0, Date() >= sliceEnd, ownWorkWaiting() { pullRequested = true; break }
      if let pageLimit, pagesRead >= pageLimit {
        // The scheduler's slice is read: the rest is asked for again right after this Mac's own sends.
        pullRequested = true
        break
      }
      let page = try await transport.changes(after: cursor, limit: Self.feedPageLimit)
      pagesRead += 1
      if fetchSince == nil, !page.segments.isEmpty {
        fetchSince = Date()
        let left = (UInt64(page.headSeq.rawValue) ?? 0) &- (UInt64(cursor.rawValue) ?? 0)
        if page.segments.contains(where: { $0.deviceId != deviceId }) { stateLine("fetching", "fetching started: \(left) packs to fetch") }
      }
      fetched += page.segments.count
      fetchedForeign += page.segments.filter { $0.deviceId != deviceId }.count
      guard page.headSeq >= cursor, page.nextAfter >= cursor, page.nextAfter <= page.headSeq,
        !page.hasMore || !page.segments.isEmpty else { throw CloudFailure.invalidRequest }
      // The switch: a first upload that already sits in the account (slot 1, the only slot the service gives
      // one) is passed over, never imported, so it cannot stall this Mac at position 0.
      let firstUploadOnly = page.segments.isEmpty && !page.hasMore && page.headSeq == CloudSequence(1)
      if !firstUpload, cursor == .zero, page.segments.first?.seq == CloudSequence(2) || firstUploadOnly {
        cursor = try await passOverFirstUpload()
        if page.segments.isEmpty { continue }
      }
      for entry in page.segments {
        guard let previous = UInt64(cursor.rawValue), previous < UInt64.max,
          entry.seq == CloudSequence(previous + 1) else { throw CloudFailure.invalidRequest }
        if entry.storageClass == .secrets {
          // V owns protected application, whether this session can already see its descriptor or not.
          // Brain catch-up must remain usable while that separate cursor is waiting.
          try store.transaction {
            try store.set("brainSeq", entry.seq)
            try store.set("secretsPending", true)
          }
        } else {
          receipts += try await receiveInFeed(entry)
        }
        cursor = entry.seq
        if let sliceEnd, Date() >= sliceEnd, entry.seq != page.segments.last?.seq, ownWorkWaiting() { slicedOff = true; break }
      }
      if slicedOff {
        // X2: this Mac's own work goes now; the rest of the download is asked for again right after it.
        try store.set("headSeq", page.headSeq)
        pullRequested = true
        break
      }
      guard page.nextAfter == cursor else { throw CloudFailure.invalidRequest }
      try store.set("headSeq", page.headSeq)
      if !page.hasMore {
        guard cursor == page.headSeq else { throw CloudFailure.invalidRequest }
        break
      }
      // F: the position this Mac applied is reported as it goes (the service shows it for this device), not only
      // at the end of a long download.
      try await reportApplied(cursor)
    }
    if let fetchSince, fetchedForeign > 0 {
      stateLine("fetched", "fetching finished: \(fetched) packs in \(Int(Date().timeIntervalSince(fetchSince).rounded())) s")
    }
    do {
      receipts += try await pullSecretsOwned(through: cursor)
      if (try store.value("secretsPending") as Bool?) == false { try store.execute("DELETE FROM metadata WHERE key=?", [Data("protectedFailure".utf8)]) }
    } catch {
      // Protected restore has a separate cursor and warning. It cannot revoke verified brain context.
      try store.set("secretsPending", true)
      try store.set("protectedFailure", "Saved passwords are waiting to finish restoring.")
    }
    if !receipts.isEmpty || coverageRefreshRequested { try await refreshKnownCoverage() }
    try await reportApplied(cursor)
    return receipts
  }
  /// `reportedSeq`: the feed position last reported through POST /v1/applied. The service keeps it as this device's
  /// `appliedSeq` and shows it in the account's device list ("received", "receiving n items"). Advisory: a report
  /// that is refused or not answered leaves the pull done (what was applied stays applied) and is sent again later.
  private func reportApplied(_ cursor: CloudSequence) async throws {
    let previous: CloudSequence = try store.value("reportedSeq") ?? .zero
    let secrets: CloudSequence = try store.value("secretsSeq") ?? .zero
    let reportedSecrets: CloudSequence = try store.value("reportedSecretsSeq") ?? .zero
    guard cursor > previous || secrets > reportedSecrets else { return }
    let checkpointId: String? = try store.value("checkpointId")
    do {
      _ = try await transport.applied(brainSeq: cursor, secretsSeq: secrets, checkpointId: checkpointId)
      try store.set("reportedSecretsSeq", secrets)
      try store.set("reportedSeq", cursor)
    } catch CloudFailure.secretsLocked {
      // The protected position cannot be reported while this device is not approved; report memory alone.
      // A device that lost approval after reporting a protected position may be refused again: skip the report.
      do {
        _ = try await transport.applied(brainSeq: cursor, secretsSeq: reportedSecrets, checkpointId: checkpointId)
        try store.set("reportedSeq", cursor)
      } catch {}
    } catch let error as CancellationError { throw error }
    catch {}
  }
  /// An engine with NO memory domains (saved passwords alone, or nothing switched on yet). The memory feed is not
  /// consumed: its position stays where it is, so no memory pack is passed over, judged, counted or able to stop
  /// this Mac, and memory starts from that position once a memory kind is switched on. Saved passwords have their
  /// own position and go on. The applied position is not reported to the service meanwhile (it is advisory).
  private func pullSavedPasswordsOnly(_ earlier: [CloudImportReceipt]) async throws -> [CloudImportReceipt] {
    var receipts = earlier
    let position: CloudSequence = try store.value("secretsSeq") ?? .zero
    let page = try await transport.changes(after: position, limit: 1)
    guard page.headSeq >= position else { throw CloudFailure.invalidRequest }
    try store.set("headSeq", page.headSeq)
    guard !secretsDomains.isEmpty else { return receipts }
    if page.headSeq > position { try store.set("secretsPending", true) }
    do {
      receipts += try await pullSecretsOwned(through: page.headSeq)
      if (try store.value("secretsPending") as Bool?) == false { try store.execute("DELETE FROM metadata WHERE key=?", [Data("protectedFailure".utf8)]) }
    } catch {
      try store.set("secretsPending", true)
      try store.set("protectedFailure", "Saved passwords are waiting to finish restoring.")
    }
    if !receipts.isEmpty || coverageRefreshRequested { try await refreshKnownCoverage() }
    return receipts
  }
  /// Only slot 1, and only when the service states that a first upload exists: this Mac's position moves to 1
  /// and the feed is read from position 2. The upload is recorded by id for the screens; nothing of it is read.
  private func passOverFirstUpload() async throws -> CloudSequence {
    guard let checkpoint = try await transport.checkpoint() else { throw CloudFailure.invalidRequest }
    try store.transaction {
      try store.set("brainSeq", CloudSequence(1))
      try store.set("ignoredFirstUpload", checkpoint.checkpointId)
    }
    return CloudSequence(1)
  }
  // MARK: Device trust: the verdict for an incoming pack (cloud-device-trust-design.md section 3)

  /// Refusal reasons beside CloudPackVerdict's: a verified pack that repeats or contradicts an applied one.
  public static let repeatedPackReason = "repeated-pack"
  public static let packIdReusedReason = "pack-id-reused"
  public static let positionReusedReason = "position-reused"
  private enum Judged {
    /// The signature checks under the key this Mac's trusted list stores for `signer`.
    case apply(CloudSegmentDescriptor, signer: String)
    /// The device the service names is not trusted on this Mac.
    case held(device: String)
    case refused(reason: String)
  }
  /// The descriptor a feed entry states, or nil when a field is missing. Shape only; no judgement.
  private static func descriptor(of entry: CloudChangeEntry) -> CloudSegmentDescriptor? {
    guard entry.locked != true, let id = entry.segmentId, let request = entry.requestId, let purpose = entry.purpose,
      let domains = entry.domains, let epoch = entry.keyEpoch, let hash = entry.sha256, let size = entry.bytes,
      let count = entry.opCount, let format = entry.format, let signature = entry.signature else { return nil }
    return .init(segmentId: id, requestId: request, storageClass: entry.storageClass, purpose: purpose, domains: domains,
      keyEpoch: epoch, sha256: hash, bytes: size, opCount: count, format: format, signature: signature)
  }
  /// Asked for every feed entry BEFORE anything of it is downloaded. The device the service names for the entry
  /// selects the stored key; the signature under that key decides. No key on this Mac's list: the pack waits.
  /// "Own" is nothing special: an entry carrying this Mac's device id applies only if it checks under the key
  /// the list stores for that id. Nothing here asks the service, and no field inside the pack is read.
  private func judge(_ entry: CloudChangeEntry) async throws -> Judged {
    guard let device = entry.deviceId, (try? CloudSyncBytes.transportID(device)) != nil else {
      #if DEBUG
      if case .seam = trust { throw CloudFailure.unsupportedFormat }
      #endif
      return .refused(reason: CloudPackVerdict.noDevice)
    }
    switch trust {
    #if DEBUG
    case .seam:
      // Test seam: the closure is asked in `openPack`, at the point the old check ran.
      guard let descriptor = Self.descriptor(of: entry) else { throw CloudFailure.unsupportedFormat }
      return .apply(descriptor, signer: device)
    #endif
    case .list(let list):
      guard let key = await list.trustedSigningKey(deviceId: device) else { return .held(device: device) }
      guard let descriptor = Self.descriptor(of: entry) else { return .refused(reason: CloudPackVerdict.malformed) }
      switch descriptor.syncSignatureCheck(key: key, subject: subject) {
      case .valid:
        // A pack that verifies but repeats or contradicts what this Mac already applied (the same pack id at a
        // new position, a pack id with other bytes, another pack at an applied position) is refused with its
        // reason and the feed moves on. It used to stop the Mac for good.
        if let reason = try store.repeatedPackReason(id: descriptor.segmentId, seq: entry.seq, digest: descriptor.sha256) { return .refused(reason: reason) }
        return .apply(descriptor, signer: device)
      // The key stored for this device cannot be read. Nothing is wrong with the pack, so it WAITS; refused, it
      // would be passed over though the pack may be perfectly good once the key is right.
      case .badKey: return .held(device: device)
      case .badSignature: return .refused(reason: CloudPackVerdict.badSignature)
      }
    }
  }
  /// A pack whose signer was judged trusted: its remaining shape is checked, then it is downloaded, compared with
  /// its signed hash, opened and decoded. A failure here stops the pull and keeps the position, as before (S06):
  /// the signature was good, so nothing is passed over.
  private func openPack(_ entry: CloudChangeEntry, _ descriptor: CloudSegmentDescriptor, signer: String) async throws -> [CloudOperation] {
    guard descriptor.purpose.permits(entry.storageClass), !descriptor.domains.isEmpty, descriptor.keyEpoch > 0,
      descriptor.bytes > 0, descriptor.bytes <= 262_144, (1...256).contains(descriptor.opCount), descriptor.format == "td-ops-1",
      entry.getUrl != nil else { throw CloudFailure.unsupportedFormat }
    try CloudSyncBytes.transportID(descriptor.segmentId)
    try CloudSyncBytes.transportID(descriptor.requestId)
    guard try CloudSyncBytes.unbase64(descriptor.signature).count == 64 else { throw CloudFailure.checksumMismatch }
    #if DEBUG
    if case .seam(let verify) = trust { try await verify(descriptor, signer) }
    #endif
    let bytes = try await downloadEntry(entry)
    guard Int64(bytes.count) == descriptor.bytes, CloudSyncBytes.hash(bytes) == descriptor.sha256 else { throw CloudFailure.checksumMismatch }
    let envelope = try decodeEnvelope(bytes)
    guard envelope.blobId == descriptor.segmentId, envelope.epoch == descriptor.keyEpoch, envelope.storageClass == entry.storageClass,
      envelope.purpose == descriptor.purpose else { throw CloudFailure.checksumMismatch }
    let operations = try CloudSyncPack.decode(await port(for: entry.storageClass).open(envelope))
    try validateClasses(operations)
    guard operations.allSatisfy({ entry.storageClass == .brain ? (brainDomains.contains($0.domain) || $0.domain == Self.coverageDomain) : secretsDomains.contains($0.domain) }) else { throw CloudFailure.unsupportedFormat }
    guard operations.count == descriptor.opCount, Set(operations.map(\.domain)) == Set(descriptor.domains) else { throw CloudFailure.checksumMismatch }
    return operations
  }
  /// One feed entry, judged and then handled by its verdict. Whatever the verdict, the position named by
  /// `cursorKey` moves past the entry ("none": a position already passed is being read again).
  private func receive(_ entry: CloudChangeEntry, cursorKey: String) async throws -> [CloudImportReceipt] {
    switch try await judge(entry) {
    case .held(let device):
      try holdEntry(entry, device: device, cursorKey: cursorKey)
      return []
    case .refused(let reason):
      try refuseEntry(entry, reason: reason, cursorKey: cursorKey)
      return []
    case .apply(let descriptor, let signer):
      var receipts: [CloudImportReceipt] = []
      // R6: nothing of a device is applied while its older packs still wait here, whatever brought this pack up
      // (the feed, or a parked saved-password pack read again). Their release runs (or resumes) first. If trust
      // was withdrawn meanwhile, this pack waits with them. A pack read again ("none") is a late arrival.
      // A signer without a row may still have older packs past the list: once per signer its release reads the
      // feed again from the lowest unlisted position.
      let waitingHere = try store.heldRow(signer)?.first(entry.storageClass) != nil
      let pastTheList = try !waitingHere && !unlistedCleared.contains(signer) && store.unlistedHeldFirst(entry.storageClass) != nil
      if waitingHere || pastTheList {
        receipts += try await releaseTrustedHeld(only: [signer])
        if try store.heldRow(signer)?.first(entry.storageClass) != nil {
          try holdEntry(entry, device: signer, cursorKey: cursorKey)
          return receipts
        }
      }
      do { receipts += try await applyJudged(entry, descriptor, signer: signer, late: cursorKey == "none", cursorKey: cursorKey) }
      catch is CloudSyncTrustWithdrawn {
        // Stopped between prepare and apply: what was prepared is dropped and the pack waits like any other.
        try store.dropPrepared(descriptor.segmentId)
        try holdEntry(entry, device: signer, cursorKey: cursorKey)
      }
      return receipts
    }
  }
  /// A judged pack of a trusted signer: opened and applied. The origin handed to adapters is the verified signer,
  /// never the pack's own origin field; `late` marks an arrival out of feed order (its position and commit time
  /// stay the original ones).
  private func applyJudged(_ entry: CloudChangeEntry, _ descriptor: CloudSegmentDescriptor, signer: String, late: Bool, cursorKey: String) async throws -> [CloudImportReceipt] {
    // A position read again (release, check again) that was applied earlier: nothing is downloaded.
    if cursorKey == "none", try store.applied(id: descriptor.segmentId, seq: entry.seq, digest: descriptor.sha256) { return [] }
    // 0.23.4 (fault 4a): this Mac's own pack whose sealed copy left at its acknowledgement is settled without a download.
    // A failure here falls through to the ordinary path (download and apply), said once in the log.
    if signer.lowercased() == deviceId.lowercased() {
      do {
        if try store.settleOwnReleasedPack(seq: entry.seq, segmentId: descriptor.segmentId, sha256: descriptor.sha256,
                                           committedAt: entry.createdAt, cursorKey: cursorKey) { return [] }
      } catch { _ = CloudSyncDiagnostics.shared.report("fetch: settling this Mac's own sent pack without a download", error) }
    }
    // N2: a trusted pack of a kind this Mac does not take now (memory off here, or a kind this build does not
    // know) WAITS: nothing is downloaded, it is kept by position and applied as a late arrival once every kind it
    // names is taken here. It is never refused or passed over, and it stops nothing: the position moves on and
    // later packs (other kinds, other devices, saved passwords) go on. The kinds are the signed descriptor's.
    if !kindsNotTaken(descriptor.domains).isEmpty {
      try waitForKind(entry, device: signer, domains: descriptor.domains, cursorKey: cursorKey)
      return []
    }
    lastPackStageApplying = false
    let operations = try await openPack(entry, descriptor, signer: signer)
    lastPackStageApplying = true
    return try await apply(id: descriptor.segmentId, seq: entry.seq, digest: descriptor.sha256,
      origin: .init(deviceId: signer, sequence: entry.seq, committedAt: entry.createdAt, late: late ? true : nil),
      operations: operations, cursorKey: cursorKey)
  }

  // MARK: Device trust: read at the moment of applying; release (design 3.4, 3.5; review R6)

  /// Thrown inside an apply when the pack's device is no longer trusted at that moment.
  private struct CloudSyncTrustWithdrawn: Error {}
  /// Trust is read again at the moment of applying, and so also when a prepared pack is replayed from the
  /// journal after a restart: stopping a device takes effect for everything not yet applied.
  private func stillTrusted(_ deviceId: String) async -> Bool {
    guard case .list(let list) = trust else { return true }
    return await list.trustedSigningKey(deviceId: deviceId) != nil
  }
  /// Releases the waiting packs of every device this Mac's list trusts NOW (all waiting devices, or `named`).
  /// Called at the start of every pull, so a release starts by itself after a trust click and resumes first after
  /// a restart, and before a newer pack of such a device is applied (`receive`).
  private func releaseTrustedHeld(only named: Set<String>? = nil) async throws -> [CloudImportReceipt] {
    guard case .list(let list) = trust else { return [] }
    // Whom to ask the list about. Named devices (a trust click, or a pack of that signer about to apply); or, at
    // the start of a pull, the devices whose release already began (resumed first after a restart) plus a few
    // listed devices in rotation. So a pull's cost does not grow with the number of waiting rows, and a device
    // trusted without any call from the wiring is still found.
    var candidates: [String], resuming = Set<String>()
    if let named { candidates = Array(named) }
    else {
      candidates = try store.releasingDevices()
      resuming = Set(candidates)
      let page = try store.heldDeviceIds(after: releaseScanAfter, limit: Self.releaseScanPerPull)
      releaseScanAfter = page.count < Self.releaseScanPerPull ? "" : (page.last ?? "")
      candidates += page
    }
    var devices = Set<String>(), withdrawn = Set<String>()
    for device in Set(candidates) {
      guard await list.trustedSigningKey(deviceId: device) != nil else {
        if resuming.contains(device) { withdrawn.insert(device) }
        continue
      }
      // A named device without a row: packs past the list may be its own (adoptUnlisted).
      if named != nil, try !store.adoptUnlisted(device) { continue }
      if try store.heldRow(device) != nil { devices.insert(device) }
    }
    if !withdrawn.isEmpty { try store.setReleasing(withdrawn, false) }
    guard !devices.isEmpty else { return [] }
    try store.setReleasing(devices, true)
    unlistedCleared.formUnion(devices)
    var receipts: [CloudImportReceipt] = []
    // With no memory kind switched on here the memory feed is not read at all, so no memory pack is released.
    if !brainDomains.isEmpty { receipts += try await releasePass(devices, storageClass: .brain) }
    // Saved passwords have their own position; their pass runs once this Mac can open them.
    if let secretsContent, await secretsContent.state(storageClass: .secrets).available {
      receipts += try await releasePass(devices, storageClass: .secrets)
    }
    return receipts
  }
  /// Listed waiting devices asked about per pull, in rotation.
  static let releaseScanPerPull = 8
  private var releaseScanAfter = ""
  /// Trusted signers already released since packs went past the list (in memory; see `receive`).
  private var unlistedCleared: Set<String> = []
  /// ONE pass over the feed, in feed order, from the lowest first waiting position among `devices` up to this
  /// Mac's position for that class. Entries of other devices are passed over. Each waiting pack is judged under
  /// the stored key at that moment and applied with its ORIGINAL device, position and commit time, marked late;
  /// one that does not check is refused. The device's row moves forward pack by pack, so a restart resumes where
  /// the pass stopped; when the pass reaches this Mac's position the row's position is cleared. A device stopped
  /// during the pass keeps its remaining packs waiting. Nothing is recorded per pack: whatever verifies now is
  /// applied.
  private func releasePass(_ devices: Set<String>, storageClass: CloudStorageClass) async throws -> [CloudImportReceipt] {
    var active: [String: CloudSequence] = [:]
    for row in try store.heldRows() where devices.contains(row.deviceId) {
      if let first = row.first(storageClass) { active[row.deviceId] = first }
    }
    guard let start = active.values.min(), let from = UInt64(start.rawValue), from > 0 else { return [] }
    let end: CloudSequence = try store.value(storageClass == .brain ? "brainSeq" : "secretsSeq") ?? .zero
    var secretsEpoch = 0
    if storageClass == .secrets, let secretsContent { secretsEpoch = await secretsContent.state(storageClass: .secrets).epoch }
    var cursor = CloudSequence(from - 1), receipts: [CloudImportReceipt] = []
    scan: while cursor < end, !active.isEmpty {
      let page = try await transport.changes(after: cursor, limit: Self.feedPageLimit)
      guard !page.segments.isEmpty else { throw CloudFailure.invalidRequest }
      for entry in page.segments {
        guard let previous = UInt64(cursor.rawValue), previous < UInt64.max - 1, entry.seq == CloudSequence(previous + 1) else { throw CloudFailure.invalidRequest }
        if entry.seq > end { break scan }
        cursor = entry.seq
        // A saved-password pack the service now serves as locked names no device: it is parked (kept and
        // retried) as in the ordinary pull, and judged when it can be read with its descriptor.
        if storageClass == .secrets, entry.storageClass == .secrets, entry.locked == true {
          try parkPack(entry.seq, reason: "This saved-password pack cannot be opened on this Mac (an older or unknown key).")
          continue
        }
        guard entry.storageClass == storageClass, let device = entry.deviceId, let first = active[device], entry.seq >= first else { continue }
        var stopped = false
        if storageClass == .secrets, let older = entry.keyEpoch, older < secretsEpoch {
          // Sealed with a saved-password key the newer key replaced: recorded once, as in the ordinary pull.
          try supersedePack(entry.seq, keyEpoch: older)
        } else {
          switch try await judge(entry) {
          case .held:
            stopped = true
          case .refused(let reason):
            try refuseEntry(entry, reason: reason, cursorKey: "none")
          case .apply(let descriptor, let signer):
            do { receipts += try await applyJudged(entry, descriptor, signer: signer, late: true, cursorKey: "none") }
            catch is CloudSyncTrustWithdrawn {
              try store.dropPrepared(descriptor.segmentId)
              stopped = true
            }
            catch let failure as CloudFailure where failure == .checksumMismatch || failure == .unsupportedFormat {
              // A pack with a good signature that cannot be opened or does not match its hash (S06). It is not
              // passed over; the release of THIS device stops at it, its packs go on waiting in order, and the
              // pull goes on for everyone else instead of failing every time.
              stopped = true
            }
          }
        }
        if stopped {
          // Trust was removed during the pass: this pack and the device's later ones go on waiting.
          try store.setHeldPosition(deviceId: device, storageClass: storageClass, to: entry.seq)
          try store.setReleasing([device], false)
          active.removeValue(forKey: device)
        } else {
          try store.released(deviceId: device, storageClass: storageClass, next: CloudSequence(previous + 2),
            domains: entry.domains ?? [], operations: entry.opCount ?? 0)
        }
      }
    }
    // The pass reached this Mac's position: nothing of these devices waits in this class any more.
    for device in active.keys { try store.setHeldPosition(deviceId: device, storageClass: storageClass, to: nil) }
    return receipts
  }
  /// REFUSED: nothing is fetched or applied; the pack is recorded for the screens ("check again") and the
  /// position moves on in the same transaction. Never a stall.
  private func refuseEntry(_ entry: CloudChangeEntry, reason: String, cursorKey: String) throws {
    guard cursorKey == "none" || ["brainSeq", "secretsSeq"].contains(cursorKey) else { throw CloudFailure.invalidRequest }
    try store.transaction {
      try store.recordRefused(seq: entry.seq, storageClass: entry.storageClass, deviceId: entry.deviceId, reason: reason)
      if cursorKey != "none" { try store.set(cursorKey, entry.seq) }
    }
  }
  /// HELD: nothing is fetched, opened, merged or shown to an adapter. Only the device's waiting row changes (its
  /// first waiting position and the counts the service reported), and the position moves on in the same
  /// transaction, so the pack is counted once and never stops the feed or a trusted device's change behind it.
  /// A waiting pack is no gap: readiness, coverage and Continue never look at this table.
  private func holdEntry(_ entry: CloudChangeEntry, device: String, cursorKey: String) throws {
    guard cursorKey == "none" || ["brainSeq", "secretsSeq"].contains(cursorKey) else { throw CloudFailure.invalidRequest }
    let listed = try store.transaction { () throws -> Bool in
      // A pack prepared while its device was still trusted (a journal left by a restart) is dropped with it.
      if let id = entry.segmentId { try store.dropPrepared(id) }
      let listed = try store.hold(deviceId: device, seq: entry.seq, storageClass: entry.storageClass, domains: entry.domains ?? [], operations: entry.opCount ?? 0)
      if cursorKey != "none" { try store.set(cursorKey, entry.seq) }
      return listed
    }
    // Past the list (no row): if this device is trusted later, its release must read the feed again.
    if !listed { unlistedCleared.remove(device) }
  }
  /// The kinds named in a pack that no adapter on this Mac takes now (the engine's own coverage kind is taken).
  private func kindsNotTaken(_ domains: [String]) -> Set<String> {
    Set(domains.filter { $0 != Self.coverageDomain && adapters[$0] == nil })
  }
  /// N2: keeps a trusted pack whose kind this Mac does not take; the position moves on in the same transaction.
  private func waitForKind(_ entry: CloudChangeEntry, device: String, domains: [String], cursorKey: String) throws {
    guard cursorKey == "none" || ["brainSeq", "secretsSeq"].contains(cursorKey) else { throw CloudFailure.invalidRequest }
    try store.transaction {
      if let id = entry.segmentId { try store.dropPrepared(id) }
      try store.waitForKind(seq: entry.seq, storageClass: entry.storageClass, deviceId: device, domains: domains)
      if cursorKey != "none" { try store.set(cursorKey, entry.seq) }
    }
  }
  /// N2: packs that waited for a kind this Mac now takes are read again in feed order and judged afresh (trust is
  /// read again; a release of their device comes first, as for any late arrival). Rows whose kinds are still not
  /// taken are not touched. A pack that verifies but cannot be opened stays waiting and stops nothing.
  private func retryKindWaiting() async throws -> [CloudImportReceipt] {
    var receipts: [CloudImportReceipt] = []
    for row in try store.kindWaitingRows() where kindsNotTaken(row.domains).isEmpty {
      if row.storageClass == .secrets {
        guard let secretsContent, await secretsContent.state(storageClass: .secrets).available else { continue }
      }
      guard let n = UInt64(row.seq.rawValue), n > 0 else { try store.dropKindWaiting(row.seq); continue }
      guard let entry = try await transport.changes(after: CloudSequence(n - 1), limit: 1).segments.first, entry.seq == row.seq,
        entry.storageClass == row.storageClass else { continue }
      do {
        receipts += try await receive(entry, cursorKey: "none")
        // Applied, waiting for its device's trust, or refused: each is kept in its own place now.
        if kindsNotTaken(row.domains).isEmpty { try store.dropKindWaiting(row.seq) }
      } catch let failure as CloudFailure where failure == .checksumMismatch || failure == .unsupportedFormat {}
    }
    return receipts
  }
  private func decodeEnvelope(_ bytes: Data) throws -> CloudContentEnvelope {
    try CloudWire.decode(CloudContentEnvelope.self, from: bytes,
      allowedKeys: ["v", "suite", "class", "purpose", "epoch", "blobId", "codec", "plainBytes", "nonce", "ciphertext", "tag"], maximumBytes: CloudWire.maximumBlobBytes)
  }
  /// Applies one feed pack. If an adapter refuses records ("cannot apply these"), the pack is applied again one
  /// record at a time: refused records are parked durably with a reason (later versions wait behind them),
  /// everything else applies, and the feed position advances. Any other error stops the pack, as before.
  private func apply(id: String, seq: CloudSequence, digest: String, origin: CloudImportOrigin, operations: [CloudOperation], cursorKey: String = "brainSeq") async throws -> [CloudImportReceipt] {
    if try store.applied(id: id, seq: seq, digest: digest) { return [] }
    try validateClasses(operations)
    let parked = try await parkedIndex()
    if !operations.contains(where: { parked.blocks($0) != nil }) {
      do { return try await applyWhole(id: id, seq: seq, digest: digest, origin: origin, operations: operations, cursorKey: cursorKey) }
      catch let error where Self.isRecordRefusal(error) {}
    }
    let (receipts, conflicts) = try await applyIndividually(operations, origin: origin, journalPrefix: id)
    try store.finishApply(id: id, seq: seq, digest: digest, operations: operations,
      remembering: operations.filter { !conflicts.contains($0.opId) }, committedAt: origin.committedAt, cursorKey: cursorKey)
    try releaseAfterApply()
    return receipts
  }
  private func applyWhole(id: String, seq: CloudSequence, digest: String, origin: CloudImportOrigin, operations: [CloudOperation], cursorKey: String) async throws -> [CloudImportReceipt] {
    do { try store.checkIdentity(operations) }
    catch let failure as CloudFailure where failure == .idReused || failure == .invalidRequest { throw CloudSyncIdentityRefused() }
    // Device trust: read again before anything of the pack takes effect, a coverage correction included.
    guard await stillTrusted(origin.deviceId) else { throw CloudSyncTrustWithdrawn() }
    // Own records whose files already left this Mac are not handed back to the adapter (no download back);
    // coverage corrections are the engine's own records.
    try applyCoverageCorrections(operations, signer: origin.deviceId)
    let forAdapter = try operations.filter { try $0.domain != Self.coverageDomain && !ownWithDroppedFile($0) }
    var journal: CloudSyncJournal? = nil
    if let row = try store.rows("SELECT bytes FROM prepare_journal WHERE segmentId=?", [Data(id.utf8)]).first {
      let saved = try? JSONDecoder().decode(CloudSyncJournal.self, from: row[0])
      if let saved, saved.seq == seq, saved.digest == digest, saved.origin.deviceId == origin.deviceId, saved.origin.sequence == origin.sequence,
        Set(saved.prepared.flatMap(\.operations).map(\.opId)).isSubset(of: Set(operations.map(\.opId))) { journal = saved }
      // X1 (13 Nov): a journal that does not match this pack is not a reason to stop the feed: it is dropped and the
      // pack is prepared again from its own records.
      else { try store.execute("DELETE FROM prepare_journal WHERE segmentId=?", [Data(id.utf8)]) }
    }
    if journal == nil {
      var prepared: [CloudPreparedImport] = []
      let domains = Set(forAdapter.map(\.domain)).sorted()
      for domain in domains {
        guard let adapter = adapters[domain] else { throw CloudFailure.unsupportedFormat }
        let incoming = forAdapter.filter { $0.domain == domain }
        let files = try await incomingFiles(incoming)
        let plan = try await adapterStep(id) { try await adapter.validateIncoming(incoming, files: files) }
        guard plan.operations == incoming, plan.files == files else { throw CloudFailure.checksumMismatch }
        prepared.append(plan)
      }
      let fresh = CloudSyncJournal(id: id, seq: seq, digest: digest, origin: origin, prepared: prepared, domains: domains)
      try store.stage(id, fresh)
      journal = fresh
    }
    guard let journal else { throw CloudFailure.unavailable }
    var receipts: [CloudImportReceipt] = []
    for (domain, prepared) in zip(journal.domains, journal.prepared) {
      guard let adapter = adapters[domain] else { throw CloudFailure.unsupportedFormat }
      for file in prepared.files { _ = try await sealedFile(file.reference, sourceId: file.sourceId) }
      // Device trust: read again at the moment of applying (also when this journal is replayed after a restart).
      guard await stillTrusted(origin.deviceId) else { throw CloudSyncTrustWithdrawn() }
      let receipt = try await adapterStep(id) { try await adapter.applyPrepared(prepared, origin: origin) }
      try fault(.duringApply)
      guard receipt.preparationId == prepared.preparationId, receipt.results.map(\.entityId).sorted() == prepared.operations.map(\.entityId).sorted() else { throw CloudFailure.unavailable }
      if receipt.results.contains(where: { $0.status == .blocked }) || receipt.counts.blocked > 0 { throw CloudSyncItemsBlocked(reason: "") }
      let verification = try await adapter.verify(receipt)
      guard verification.verified, verification.counts == receipt.counts, verification.counts.blocked == 0 else { throw CloudFailure.checksumMismatch }
      receipts.append(receipt)
    }
    try store.finishApply(id: id, seq: seq, digest: digest, operations: operations, committedAt: origin.committedAt, cursorKey: cursorKey)
    try releaseAfterApply()
    // Coverage is refreshed once per pull (pullOwned), not per pack: an inventory walks every source.
    return receipts
  }

  // MARK: Poison records (contract: CloudRecordRefusal)

  private struct CloudSyncItemsBlocked: Error { let reason: String }
  private static let individualPreparation = "td-sync-individual"
  /// Journal marker for own records not handed back to the adapter (their files already left this Mac).
  private static let ownPreparation = "td-sync-own"
  private struct CloudSyncIdentityRefused: Error {}
  /// X1 (13 Nov, the owner's Mac mini stuck at 404 of 407): an adapter that cannot take records of a pack (its own
  /// identity or shape check, e.g. memory's `idReused` for a row another Mac re-sent under its own name) used to
  /// throw a plain CloudFailure out of the feed loop: the pack's journal replayed the same failure every minute and
  /// nothing after it, and nothing of this Mac's own, moved. Now it is a record refusal: the pack is applied record
  /// by record, the ones that cannot be taken are parked and listed, and the feed goes on.
  struct CloudSyncAdapterRefused: Error { let reason: String }
  static func isLocalContentFailure(_ error: Error) -> Bool {
    guard let failure = error as? CloudFailure else { return false }
    switch failure {
    case .idReused, .invalidRequest, .unsupportedFormat, .checksumMismatch, .versionChanged: return true
    default: return false
    }
  }
  /// Runs one adapter call; a content refusal of the adapter drops the pack's journal and becomes a record refusal.
  private func adapterStep<T>(_ journalKey: String, _ body: () async throws -> T) async throws -> T {
    do { return try await body() }
    catch let error where Self.isLocalContentFailure(error) {
      try store.execute("DELETE FROM prepare_journal WHERE segmentId=?", [Data(journalKey.utf8)])
      try store.dropPrepared(journalKey)
      throw CloudSyncAdapterRefused(reason: "This Mac could not take this record (\(CloudSyncDiagnostics.kind(error))). It is kept and tried again.")
    }
  }
  private static func isRecordRefusal(_ error: Error) -> Bool {
    error is CloudRecordRefusal || error is CloudSyncItemsBlocked || error is CloudSyncIdentityRefused || error is CloudSyncAdapterRefused
  }
  private struct ParkedRecord {
    let op: CloudOperation, origin: CloudImportOrigin, reason: String, conflict: Bool, attempts: Int, nextAt: Int64
    var parkedAt: Int64 = 0
  }
  private struct ParkedIndex {
    var ids: Set<String> = [], entities: Set<String> = []
    static func key(_ op: CloudOperation) -> String { op.domain + "\u{0}" + op.entityId }
    mutating func add(_ op: CloudOperation) { ids.insert(op.opId); entities.insert(Self.key(op)) }
    /// Why `op` must wait, if it must: it is parked itself, an earlier version of the same record is parked,
    /// or a record it depends on is parked.
    func blocks(_ op: CloudOperation) -> String? {
      if ids.contains(op.opId) { return "parked" }
      if entities.contains(Self.key(op)) { return "Waiting behind an earlier version of this record that could not be applied here." }
      if op.parents.contains(where: { ids.contains($0) }) { return "Waiting behind a record it depends on that could not be applied here." }
      return nil
    }
  }
  private func parkedRecords() throws -> [ParkedRecord] {
    try store.rows("SELECT bytes,origin,reason,conflict,attempts,nextAt,parkedAt FROM parked_ops ORDER BY parkedAt,rowid").map {
      .init(op: try JSONDecoder().decode(CloudOperation.self, from: $0[0]), origin: try JSONDecoder().decode(CloudImportOrigin.self, from: $0[1]),
        reason: String(decoding: $0[2], as: UTF8.self), conflict: String(decoding: $0[3], as: UTF8.self) == "1",
        attempts: Int(String(decoding: $0[4], as: UTF8.self)) ?? 0, nextAt: Int64(String(decoding: $0[5], as: UTF8.self)) ?? 0,
        parkedAt: Int64(String(decoding: $0[6], as: UTF8.self)) ?? 0)
    }
  }
  private func parkedIndex() async throws -> ParkedIndex {
    var index = ParkedIndex(), trusted: [String: Bool] = [:]
    // A conflict park makes nothing wait (round 6 M3): it can never heal, so waiting behind it would be for ever.
    for row in try store.rows("SELECT domain,entityId,opId,origin FROM parked_ops WHERE conflict=0") {
      // Device trust: a parked record of a device that is not trusted now is not retried, so it makes nothing
      // wait either; a trusted device's later change to the same record applies.
      if let origin = try? JSONDecoder().decode(CloudImportOrigin.self, from: row[3]) {
        if trusted[origin.deviceId] == nil { trusted[origin.deviceId] = await stillTrusted(origin.deviceId) }
        if trusted[origin.deviceId] == false { continue }
      }
      index.ids.insert(String(decoding: row[2], as: UTF8.self))
      index.entities.insert(String(decoding: row[0], as: UTF8.self) + "\u{0}" + String(decoding: row[1], as: UTF8.self))
    }
    return index
  }
  /// Waiting records (behind another parked record) are due as soon as their blocker clears; refused ones
  /// retry after a growing gap: one minute, doubling, at most six hours.
  private static func parkedGap(_ attempts: Int) -> Int64 { min(21_600_000, Int64(60_000) << Int64(min(attempts, 20))) }
  private func park(_ op: CloudOperation, origin: CloudImportOrigin, reason: String, conflict: Bool, waiting: Bool) throws {
    let now = CloudSyncBytes.now()
    try store.execute("INSERT OR IGNORE INTO parked_ops(opId,domain,entityId,sourceId,projectId,bytes,origin,reason,conflict,attempts,nextAt,parkedAt) VALUES (?,?,?,?,?,?,?,?,CAST(? AS INTEGER),0,CAST(? AS INTEGER),CAST(? AS INTEGER))", [
      Data(op.opId.utf8), Data(op.domain.utf8), Data(op.entityId.utf8), Data(op.source.sourceId.utf8), Data((op.projectId ?? "").utf8),
      try CloudSyncCanonical.encode(op), try CloudSyncCanonical.encode(origin), Data(reason.utf8), Data((conflict ? "1" : "0").utf8),
      Data(String(waiting ? 0 : now + Self.parkedGap(0)).utf8), Data(String(now).utf8)])
  }
  private func parkedAgain(_ op: CloudOperation, attempts: Int, reason: String) throws {
    try store.execute("UPDATE parked_ops SET attempts=CAST(? AS INTEGER),nextAt=CAST(? AS INTEGER),reason=? WHERE opId=?", [
      Data(String(attempts + 1).utf8), Data(String(CloudSyncBytes.now() + Self.parkedGap(attempts + 1)).utf8), Data(reason.utf8), Data(op.opId.utf8)])
  }
  /// One record through the adapter, with its own journal so an interrupted apply replays the same preparation.
  private func applyOne(_ op: CloudOperation, origin: CloudImportOrigin, journalKey: String) async throws -> CloudImportReceipt {
    guard let adapter = adapters[op.domain] else { throw CloudFailure.unsupportedFormat }
    let prepared: CloudPreparedImport
    if let row = try store.rows("SELECT bytes FROM prepare_journal WHERE segmentId=?", [Data(journalKey.utf8)]).first {
      let journal = try? JSONDecoder().decode(CloudSyncJournal.self, from: row[0])
      if let plan = journal?.prepared.first, plan.operations == [op] { prepared = plan }
      else {
        // X1: a journal that does not match is dropped and the record prepared again, never a stop.
        try store.execute("DELETE FROM prepare_journal WHERE segmentId=?", [Data(journalKey.utf8)])
        return try await applyOne(op, origin: origin, journalKey: journalKey)
      }
    } else {
      let files = try await incomingFiles([op])
      prepared = try await adapterStep(journalKey) { try await adapter.validateIncoming([op], files: files) }
      guard prepared.operations == [op], prepared.files == files else { throw CloudFailure.checksumMismatch }
      try store.stage(journalKey, CloudSyncJournal(id: journalKey, seq: origin.sequence, digest: op.payloadHash, origin: origin, prepared: [prepared], domains: [op.domain]))
    }
    let clearJournal = { try self.store.execute("DELETE FROM prepare_journal WHERE segmentId=?", [Data(journalKey.utf8)]) }
    for file in prepared.files { _ = try await sealedFile(file.reference, sourceId: file.sourceId) }
    // Device trust: read again at the moment of applying.
    guard await stillTrusted(origin.deviceId) else { try clearJournal(); throw CloudSyncTrustWithdrawn() }
    let receipt: CloudImportReceipt
    do { receipt = try await adapterStep(journalKey) { try await adapter.applyPrepared(prepared, origin: origin) } }
    catch let refusal as CloudRecordRefusal { try clearJournal(); throw refusal }
    try fault(.duringApply)
    guard receipt.preparationId == prepared.preparationId, receipt.results.map(\.entityId) == [op.entityId] else { throw CloudFailure.unavailable }
    if let blocked = receipt.results.first(where: { $0.status == .blocked }) {
      try clearJournal()
      throw CloudSyncItemsBlocked(reason: blocked.reason ?? "")
    }
    let verification = try await adapter.verify(receipt)
    guard verification.verified, verification.counts == receipt.counts, verification.counts.blocked == 0 else { throw CloudFailure.checksumMismatch }
    try clearJournal()
    return receipt
  }
  /// Round 5 M1: an incoming record whose id is already used here by DIFFERENT bytes is parked as a conflict:
  /// it is not acknowledged, verified or receipted, and it never enters `records`. If this Mac's own record
  /// with that id is still unsent, that one is parked on the send side too (never sent, never marked saved).
  /// While any conflict is parked this Mac publishes no inventory (it would carry the wrong version).
  private func parkConflict(_ op: CloudOperation, origin: CloudImportOrigin) throws {
    try park(op, origin: origin, reason: "Another device saved a different record under this record's id; both are kept and neither replaces the other.", conflict: true, waiting: false)
    guard let row = try store.rows("SELECT state FROM outbox WHERE opId=?", [Data(op.opId.utf8)]).first,
      ["queued", "parked"].contains(String(decoding: row[0], as: UTF8.self)),
      let local = try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(op.opId.utf8)]).first else { return }
    for segment in try store.rows("SELECT so.segmentId FROM segment_ops so JOIN segments s ON s.segmentId=so.segmentId WHERE so.opId=? AND s.receipt IS NULL", [Data(op.opId.utf8)]) {
      try store.retireSegment(String(decoding: segment[0], as: UTF8.self))
    }
    try parkSend(try JSONDecoder().decode(CloudOperation.self, from: local[0]),
      reason: "Another device saved a different record under this edit's id; this edit is kept here and not sent.", permanent: true)
  }
  private static func parkReason(_ error: Error) -> String {
    let text: String
    if let refusal = error as? CloudRecordRefusal { text = refusal.reason }
    else if let blocked = error as? CloudSyncItemsBlocked { text = blocked.reason }
    else if let refused = error as? CloudSyncAdapterRefused { text = refused.reason }
    else { text = "" }
    return text.isEmpty ? "This Mac could not apply this record." : text
  }
  /// Applies `operations` one at a time in order; parks refused ones and everything waiting behind them.
  /// Returns the receipts of applied records and the ids parked for an identity conflict.
  private func applyIndividually(_ operations: [CloudOperation], origin: CloudImportOrigin, journalPrefix: String) async throws -> ([CloudImportReceipt], Set<String>) {
    var index = try await parkedIndex(), receipts: [CloudImportReceipt] = [], conflicts = Set<String>()
    let existingConflicts = Set(try store.rows("SELECT opId FROM parked_ops WHERE conflict=1").map { String(decoding: $0[0], as: UTF8.self) })
    guard await stillTrusted(origin.deviceId) else { throw CloudSyncTrustWithdrawn() }
    try applyCoverageCorrections(operations, signer: origin.deviceId)
    for op in operations {
      if op.domain == Self.coverageDomain { continue }
      if try ownWithDroppedFile(op) { continue }
      let reason = index.blocks(op)
      if existingConflicts.contains(op.opId) { conflicts.insert(op.opId); continue }
      if reason == "parked" { continue }
      // The identity check comes first, also for records that would only wait (round 5 S6).
      var conflict = false
      do { try store.checkIdentity([op]) }
      catch let failure as CloudFailure where failure == .idReused || failure == .invalidRequest { conflict = true }
      if conflict {
        try parkConflict(op, origin: origin)
        conflicts.insert(op.opId); continue
      }
      if let reason {
        try park(op, origin: origin, reason: reason, conflict: false, waiting: true); index.add(op); continue
      }
      do { receipts.append(try await applyOne(op, origin: origin, journalKey: journalPrefix + ":rec:" + op.opId)) }
      catch let error where error is CloudRecordRefusal || error is CloudSyncItemsBlocked || error is CloudSyncAdapterRefused {
        try park(op, origin: origin, reason: Self.parkReason(error), conflict: false, waiting: false); index.add(op)
      }
    }
    return (receipts, conflicts)
  }
  private var launchRetryPending = true
  /// Parked arrivals already named in the log in this run (once each), and the age after which they are named.
  private var oldParkedSaid: Set<String> = []
  static let parkedOldAfter: Int64 = 86_400_000
  private var forcedParkedDomains: Set<String>? = nil
  /// Retries parked records, oldest first: at launch (all), when an adapter reports a change (its domains),
  /// and when their back-off is due. A record applies only once nothing earlier of the same record (or that
  /// it depends on) is still parked; success releases the records waiting behind it in order.
  private func retryParkedOwned() async throws -> [CloudImportReceipt] {
    let packs = try await retryParkedPacks(force: launchRetryPending || forcedParkedDomains?.isDisjoint(with: secretsDomains) == false)
    let records = try parkedRecords()
    guard !records.isEmpty else { launchRetryPending = false; forcedParkedDomains = nil; return packs }
    let forceAll = launchRetryPending, forced = forcedParkedDomains ?? []
    launchRetryPending = false; forcedParkedDomains = nil
    var remaining = ParkedIndex(), receipts: [CloudImportReceipt] = []
    let now = CloudSyncBytes.now()
    for record in records {
      let op = record.op
      // Parked memory (14 Nov): two arrivals sat parked on the MacBook all day and the log said nothing after the
      // morning. One plain line per run for an arrival parked more than a day, so a watch after an install sees it.
      if record.parkedAt > 0, now - record.parkedAt > Self.parkedOldAfter, oldParkedSaid.insert(op.opId).inserted {
        CloudSyncDiagnostics.shared.info("fetch: an arriving \(op.domain) record has waited on this Mac for more than a day (\(record.attempts) tries): \(record.reason)")
      }
      let waiting = remaining.entities.contains(ParkedIndex.key(op)) || op.parents.contains { remaining.ids.contains($0) }
      let due = forceAll || forced.isEmpty == false && (forced.contains(op.domain)) || record.nextAt <= now
      // A conflict cannot change by waiting (records are immutable): it stays parked and reported (S8).
      if record.conflict { continue }
      if waiting || !due { remaining.add(op); continue }
      // N2: a record of a kind this Mac does not take now stays parked (later versions wait behind it) and
      // stops nothing; it is retried once that kind is taken here.
      if adapters[op.domain] == nil { remaining.add(op); continue }
      // Device trust: a parked record of a device that is not trusted now is not retried; it stays parked.
      guard await stillTrusted(record.origin.deviceId) else { continue }
      do {
        let receipt = try await applyOne(op, origin: record.origin, journalKey: "parked:" + op.opId)
        try store.transaction {
          if record.conflict { try store.remember([op]) }
          try store.execute("DELETE FROM parked_ops WHERE opId=?", [Data(op.opId.utf8)])
        }
        receipts.append(receipt)
      } catch let error where Self.isRecordRefusal(error) {
        try parkedAgain(op, attempts: record.attempts, reason: Self.parkReason(error)); remaining.add(op)
      } catch is CloudSyncTrustWithdrawn {}
    }
    return packs + receipts
  }
  private func supersedePack(_ seq: CloudSequence, keyEpoch: Int) throws {
    try store.execute("INSERT OR IGNORE INTO superseded_packs(seq,keyEpoch,recordedAt) VALUES (?,CAST(? AS INTEGER),CAST(? AS INTEGER))",
      [Data(seq.rawValue.utf8), Data(String(keyEpoch).utf8), Data(String(CloudSyncBytes.now()).utf8)])
  }
  private func parkPack(_ seq: CloudSequence, reason: String) throws {
    try store.execute("INSERT OR IGNORE INTO parked_packs(seq,reason,attempts,nextAt) VALUES (?,?,0,CAST(? AS INTEGER))",
      [Data(seq.rawValue.utf8), Data(reason.utf8), Data(String(CloudSyncBytes.now() + Self.parkedGap(0)).utf8)])
  }
  /// Parked saved-password packs are read again (at launch, on retryParked, when due) and applied without moving
  /// the protected cursor back; still unreadable ones wait longer.
  private func retryParkedPacks(force: Bool) async throws -> [CloudImportReceipt] {
    guard let secretsContent, await secretsContent.state(storageClass: .secrets).available else { return [] }
    var receipts: [CloudImportReceipt] = []
    for row in try store.rows("SELECT seq,attempts,nextAt FROM parked_packs ORDER BY CAST(seq AS INTEGER)") {
      let seq = try CloudSequence(rawValue: String(decoding: row[0], as: UTF8.self))
      let attempts = Int(String(decoding: row[1], as: UTF8.self)) ?? 0
      guard force || (Int64(String(decoding: row[2], as: UTF8.self)) ?? 0) <= CloudSyncBytes.now(),
        let n = UInt64(seq.rawValue), n > 0 else { continue }
      let again = { try self.store.execute("UPDATE parked_packs SET attempts=CAST(? AS INTEGER),nextAt=CAST(? AS INTEGER) WHERE seq=?",
        [Data(String(attempts + 1).utf8), Data(String(CloudSyncBytes.now() + Self.parkedGap(attempts + 1)).utf8), row[0]]) }
      let current = await secretsContent.state(storageClass: .secrets).epoch
      guard let entry = try await transport.changes(after: CloudSequence(n - 1), limit: 1).segments.first, entry.seq == seq else { try again(); continue }
      if let older = entry.keyEpoch, older < current {
        try store.transaction { try supersedePack(seq, keyEpoch: older); try store.execute("DELETE FROM parked_packs WHERE seq=?", [row[0]]) }
        continue
      }
      guard entry.locked != true, entry.keyEpoch != nil else { try again(); continue }
      do {
        // Judged like any pack once it can be read with its descriptor (it may then wait or be refused).
        receipts += try await receive(entry, cursorKey: "none")
        try store.execute("DELETE FROM parked_packs WHERE seq=?", [row[0]])
      } catch let failure as CloudFailure where failure == .checksumMismatch || failure == .unsupportedFormat { try again() }
    }
    return receipts
  }
  /// Contract addition (device trust): packs this Mac refused, oldest first, at most 1,000.
  public func refusedPacks() async throws -> [CloudRefusedPack] { try store.refusedRows() }
  /// Contract addition (device trust): the person trusted `deviceId` in this Mac's window. The entry must already
  /// be on this Mac's trusted list with exactly `signKey` (the key captured when the sheet was drawn, R1): a list
  /// that holds another key, or none, releases nothing.
  public func trustDevice(deviceId: String, signKey: CloudPublicJWK) async throws -> [CloudImportReceipt] {
    guard case .list(let list) = trust else { throw CloudFailure.unsupportedFormat }
    guard await list.trustedSigningKey(deviceId: deviceId) == signKey else { throw CloudFailure.versionChanged }
    return try await releaseHeld(deviceIds: [deviceId])
  }
  /// Contract addition (device trust): one release pass now, in feed order, for the named devices the list trusts.
  public func releaseHeld(deviceIds: [String]) async throws -> [CloudImportReceipt] {
    guard case .list(let list) = trust else { throw CloudFailure.unsupportedFormat }
    // Busy, paused or in the middle of a setup: nothing is lost. The click is remembered durably (T1): each named
    // device the list trusts gets its release mark (a device without a row first gets one from the packs past the
    // list), so the release runs first in the next pull, before anything newer of these devices is applied.
    do { try await admit() } catch {
      var marked = Set<String>()
      for device in Set(deviceIds) where await list.trustedSigningKey(deviceId: device) != nil {
        if try store.adoptUnlisted(device) { marked.insert(device) }
      }
      if !marked.isEmpty { try store.setReleasing(marked, true) }
      pullRequested = true
      return []
    }
    defer { endBusy(); scheduleSend() }
    do {
      let receipts = try await releaseTrustedHeld(only: Set(deviceIds))
      try releaseSettled()
      return receipts
    } catch { throw try await recordFailure(error, "trust device") }
  }
  /// Contract addition (device trust), "Check again": the refused position (nil: every listed one) is read again
  /// and judged afresh. A pack that now checks is applied as a late arrival and leaves the list; anything else
  /// stays listed with one more check counted.
  public func checkRefusedAgain(sequence: CloudSequence?) async throws -> [CloudImportReceipt] {
    guard case .list = trust else { throw CloudFailure.unsupportedFormat }
    try await admit()
    defer { endBusy(); scheduleSend() }
    do {
      // The release comes first here too: no refused pack of a device is applied before its older waiting ones.
      var receipts: [CloudImportReceipt] = try await releaseTrustedHeld()
      // One position, or everything: a bounded number of listed rows per call (least-checked first, so repeated
      // calls go round), then the packs past the list.
      let rows: [CloudRefusedPack]
      if let sequence { rows = try store.refusedRows().filter { $0.sequence == sequence } }
      else { rows = try store.refusedRowsToCheck(limit: Self.refusedChecksPerCall) }
      receipts += try await recheckRefused(rows)
      if sequence == nil { receipts += try await rescanUnlistedRefused() }
      try releaseSettled()
      return receipts
    } catch { throw try await recordFailure(error, "check refused packs") }
  }
  static let refusedChecksAtLaunch = 16
  static let refusedChecksPerCall = 64
  private var launchRefusedCheckPending = true
  /// Contract addition (device trust): refused packs past the list (only counted; "Check again" reaches them).
  public func refusedBeyondList() async throws -> Int { try store.value("refusedBeyondList") ?? 0 }
  /// Reads each given refused position again and judges it afresh: one that checks now is applied as a late
  /// arrival and leaves the list; anything else stays listed with one more check counted.
  private func recheckRefused(_ rows: [CloudRefusedPack]) async throws -> [CloudImportReceipt] {
      var receipts: [CloudImportReceipt] = []
      for refused in rows {
        if refused.storageClass == .secrets {
          guard let secretsContent, await secretsContent.state(storageClass: .secrets).available else { continue }
        }
        var reason = refused.reason, applied = false
        if let n = UInt64(refused.sequence.rawValue), n > 0,
          let entry = try await transport.changes(after: CloudSequence(n - 1), limit: 1).segments.first, entry.seq == refused.sequence {
          // MAC-NEXT-7 (1): this check catches exactly what `receiveInFeed` catches. Any failure of THIS Mac's own
          // (not the network, not the service), whether judging, opening or applying, keeps the pack listed with its
          // reason and the next row, and the pull, go on. Before, an error that was neither a network nor a content
          // failure left this loop; the launch check stayed pending, so every later fetch failed the same way and
          // receiving stopped while sending went on.
          do {
            switch try await judge(entry) {
            case .held: break
            case .refused(let again): reason = again
            case .apply(let descriptor, let signer):
              // Older packs of this device still wait (their release did not finish): this one stays listed.
              if try store.heldRow(signer)?.first(entry.storageClass) != nil { break }
              lastPackStageApplying = false
              do {
                receipts += try await applyJudged(entry, descriptor, signer: signer, late: true, cursorKey: "none")
                applied = true
              } catch is CloudSyncTrustWithdrawn { try store.dropPrepared(descriptor.segmentId) }
              catch let failure where !Self.isServiceOrNetworkFailure(failure) {
                // T2/X1: verifies now but cannot be opened, does not match its hash, or holds something this Mac
                // cannot take: it stays listed (one more check counted).
                try? store.dropPrepared(descriptor.segmentId)
                reason = "This Mac could not \(lastPackStageApplying ? "apply" : "open") this pack (\(CloudSyncDiagnostics.kind(failure))). It is kept in the list and checked again."
              }
            }
          } catch let failure where !Self.isServiceOrNetworkFailure(failure) {
            reason = "This Mac could not check this pack (\(CloudSyncDiagnostics.kind(failure))). It is kept in the list and checked again."
          }
        }
        if applied { try store.dropRefused(seq: refused.sequence) }
        else { try store.recordRefused(seq: refused.sequence, storageClass: refused.storageClass, deviceId: refused.deviceId, reason: reason) }
      }
      return receipts
  }
  /// Past the refused list only a count and the lowest unlisted position are kept. "Check again" for everything
  /// reads the feed again from that position to this Mac's position and judges every pack there that is neither
  /// applied, listed, parked nor waiting. One that checks now is applied late; one that does not is listed if
  /// there is room again, else counted again; one that cannot be judged now keeps the position within reach.
  private func rescanUnlistedRefused() async throws -> [CloudImportReceipt] {
    guard let first: CloudSequence = try store.value("refusedBeyondFirst"), let from = UInt64(first.rawValue), from > 0 else { return [] }
    let end: CloudSequence = try store.value("brainSeq") ?? .zero
    let secretsEnd: CloudSequence = try store.value("secretsSeq") ?? .zero
    var secretsReadable = false, secretsEpoch = 0
    if let secretsContent {
      let state = await secretsContent.state(storageClass: .secrets)
      secretsReadable = state.available; secretsEpoch = state.epoch
    }
    try store.transaction {
      for key in ["refusedBeyondList", "refusedBeyondFirst"] { try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)]) }
    }
    var cursor = CloudSequence(from - 1), receipts: [CloudImportReceipt] = []
    scan: while cursor < end {
      let page = try await transport.changes(after: cursor, limit: Self.feedPageLimit)
      guard !page.segments.isEmpty else { throw CloudFailure.invalidRequest }
      for entry in page.segments {
        guard let previous = UInt64(cursor.rawValue), previous < UInt64.max, entry.seq == CloudSequence(previous + 1) else { throw CloudFailure.invalidRequest }
        if entry.seq > end { break scan }
        cursor = entry.seq
        if entry.locked == true { continue }
        if try store.positionSettled(entry.seq) { continue }
        if entry.storageClass == .secrets {
          if let older = entry.keyEpoch, older < secretsEpoch { continue }
          if entry.seq > secretsEnd { continue }
          if !secretsReadable { try store.noteUnlistedRefused(entry.seq); continue }
        }
        switch try await judge(entry) {
        case .held:
          continue
        case .refused(let reason):
          try refuseEntry(entry, reason: reason, cursorKey: "none")
        case .apply(let descriptor, let signer):
          if try store.heldRow(signer)?.first(entry.storageClass) != nil { try store.noteUnlistedRefused(entry.seq); continue }
          do { receipts += try await applyJudged(entry, descriptor, signer: signer, late: true, cursorKey: "none") }
          catch is CloudSyncTrustWithdrawn {
            try store.dropPrepared(descriptor.segmentId)
            try store.noteUnlistedRefused(entry.seq)
          }
        }
      }
    }
    return receipts
  }
  /// Contract addition (device trust): waiting packs of devices past the list of 500 (only counted).
  public func waitingBeyondList() async throws -> Int { try store.value("heldBeyondList") ?? 0 }
  /// Contract addition ("See what is in your Cloud"): what this Mac's store knows, from local state only.
  public func contents(limit: Int) async throws -> CloudSyncContents {
    try store.contents(thisDevice: deviceId, held: try await heldDevices(), limit: limit)
  }
  /// Contract addition (device trust): the devices whose packs wait on this Mac, oldest first.
  public func heldDevices() async throws -> [CloudHeldDevice] {
    let head: CloudSequence? = try store.value("headSeq")
    let position: CloudSequence = try store.value("brainSeq") ?? .zero
    // Counts may still grow while this Mac has not read the feed to the last head it knows.
    let counting = head.map { position < $0 } ?? true
    return try store.heldRows().map { row in
      CloudHeldDevice(deviceId: row.deviceId, firstHeldSeq: row.firstSeq, firstHeldSecretsSeq: row.firstSecretsSeq, packs: row.packs,
        operations: row.operations, byDomain: row.byDomain.keys.sorted().map { name in
          CloudHeldDomainCount(domain: name, packs: row.byDomain[name]?.first ?? 0, operations: row.byDomain[name]?.last ?? 0)
        }, firstSeenAt: row.firstSeenAt, counting: counting)
    }
  }
  /// Contract addition: the record's cloud receipt once its pack was committed and read back (own records),
  /// applied from the feed, or imported from an inventory; nil before that (queued, in flight, held, parked).
  public func cloudReceipt(operationId: String) async throws -> CloudOperationReceipt? {
    guard let row = try store.rows("SELECT seq,committedAt FROM op_receipts WHERE opId=?", [Data(operationId.utf8)]).first else { return nil }
    return .init(operationId: operationId, sequence: try CloudSequence(rawValue: String(decoding: row[0], as: UTF8.self)),
      committedAt: row[1].isEmpty ? nil : Int64(String(decoding: row[1], as: UTF8.self)))
  }
  /// Contract addition: the service's time as best this Mac knows it (see CloudSyncServiceClock); nil = unknown.
  public nonisolated func serviceTime() -> Int64? { CloudSyncServiceClock.serviceTime(store) }
  /// Contract addition: stable identity of this outbox; a lost or rebuilt sync.sqlite gets a new one.
  public func outboxIdentity() async throws -> String {
    if let id: String = try store.value("outboxIdentity") { return id }
    let id = UUID().uuidString.lowercased()
    try store.set("outboxIdentity", id)
    return id
  }
  /// Contract addition: narrow readiness for one project and its named sources (Continue, context barrier).
  public func contextReady(projectId: String, sources: Set<String>) async throws -> CloudContextReady {
    // An empty list names nothing to check narrowly: it is the account-wide question (S7).
    guard !sources.isEmpty else { return try await contextReady(projectId: projectId) }
    let reported = Dictionary(try reportedCoverage().map { ($0.sourceId, $0) }, uniquingKeysWith: { first, _ in first })
    let named = sources.sorted().map { (id: $0, coverage: reported[$0]) }
    let hasPending = try store.hasPending(projectId: projectId, domains: brainDomains)
    let projectParked = try !store.rows("SELECT opId FROM parked_ops WHERE projectId=? OR length(projectId)=0 LIMIT 1", [Data(projectId.utf8)]).isEmpty ||
      !store.rows("SELECT parked_sends.opId FROM parked_sends JOIN operation_projects p ON p.opId=parked_sends.opId WHERE p.projectId=? OR p.projectId IS NULL OR length(p.projectId)=0 LIMIT 1", [Data(projectId.utf8)]).isEmpty
    let budgetState = try await budget.status()
    let locallyBlocked: Bool = try store.value("blocked") ?? false
    let bootstrapCut: String? = try store.value("bootstrapInProgress")
    let brainBlocked = locallyBlocked || bootstrapCut != nil || budgetState.blocked != nil || budgetState.retryAt > CloudSyncBytes.now()
    let head: CloudSequence? = try store.value("headSeq")
    let brainSeq: CloudSequence = try store.value("brainSeq") ?? .zero
    let verifiedInventory = try baselineSettled()
    let paused: Bool = try store.value("paused") ?? false
    let missing = named.filter { $0.coverage?.complete != true }.map(\.id)
    let ready = verifiedInventory && head != nil && brainSeq == head && !hasPending && !projectParked && !brainBlocked && !paused && missing.isEmpty
    let counted = named.compactMap(\.coverage)
    return .init(projectId: projectId, throughSeq: brainSeq,
      sourceCounts: .init(domains: counted.count, records: counted.reduce(0) { $0 + $1.items }, files: 0, bytes: counted.reduce(0) { $0 + $1.bytes },
        blocked: brainBlocked || projectParked ? 1 : 0), verified: ready,
      missingSources: missing + (verifiedInventory ? [] : [unsettledBaselineLabel]))
  }
  /// Contract addition: an adapter reports it changed; its parked records retry at the next pull.
  /// Round 6 S6 contract addition: saved-password records retired here (older key), until lane V confirms them.
  public func retiredRecords() async throws -> [CloudRetiredRecord] {
    try store.rows("SELECT rs.opId,rs.reason,rs.retiredAt,r.bytes FROM retired_sends rs JOIN outbox o ON o.opId=rs.opId JOIN records r ON r.opId=rs.opId WHERE o.state='retired' ORDER BY rs.retiredAt,rs.opId").map { row in
      let op = try JSONDecoder().decode(CloudOperation.self, from: row[3])
      let epoch = (try? decodeEnvelope(CloudSyncCanonical.encode(op.payload)).epoch) ?? 0
      return .init(operationId: op.opId, domain: op.domain, sourceId: op.source.sourceId, recordId: op.source.recordId, keyEpoch: epoch,
        reason: String(decoding: row[1], as: UTF8.self), retiredAt: Int64(String(decoding: row[2], as: UTF8.self)) ?? 0)
    }
  }
  /// Round 6 S6 contract addition: lane V's final answer. The record leaves the gap list (outbox state
  /// 'superseded', kept for the record) and its unsent files, named by no other unsent record, are released.
  public func confirmRetired(operationIds: [String]) async throws {
    try store.transaction {
      for id in Set(operationIds).sorted() {
        let key = Data(id.utf8)
        guard try !store.rows("SELECT opId FROM retired_sends WHERE opId=?", [key]).isEmpty else { continue }
        try store.execute("DELETE FROM retired_sends WHERE opId=?", [key])
        try store.execute("UPDATE outbox SET state='superseded' WHERE opId=? AND state='retired'", [key])
        try store.execute("""
          DELETE FROM objects WHERE (receipt IS NULL OR length(receipt)=0) AND blobId IN (SELECT blobId FROM outbox_files WHERE opId=?)
            AND NOT EXISTS (SELECT 1 FROM outbox_files f JOIN outbox q ON q.opId=f.opId WHERE f.blobId=objects.blobId AND q.state IN ('queued','parked','retired'))
          """, [key])
      }
    }
  }
  public func retryParked(domains: Set<String>) async throws {
    forcedParkedDomains = (forcedParkedDomains ?? []).union(domains.isEmpty ? Set(adapters.keys) : domains)
    // The adapter's own inventory may have changed too (a healed gap, an ended exclusion).
    coverageRefreshRequested = true
    // Edits parked on the send side return to the queue for these domains (never an id conflict).
    try retryParkedSends(force: false, domains: domains.isEmpty ? Set(adapters.keys) : domains)
    // A person's retry ends a timed refusal stop now; the streak stays, so one more refusal stops again.
    try store.execute("DELETE FROM metadata WHERE key=?", [Data("sendStoppedUntil".utf8)])
    sendRequested = true
    pullRequested = true
    scheduleSend()
    if !automatic { _ = try await pull() }
  }
  /// Send-side park: a queued record the service refuses for good, or one too large to send. It leaves the
  /// queue (state 'parked'), is reported on its source, and returns to the queue on `retryParked(domains:)`.
  /// Send-side park. Retried by itself (round 5 M3): at launch, by the wake timer once its back-off is due
  /// (one minute doubling to six hours), and on retryParked; `permanent` (an id conflict) is never retried.
  private func parkSend(_ op: CloudOperation, reason: String, permanent: Bool = false) throws {
    try store.transaction {
      let attempts = (try store.rows("SELECT attempts FROM parked_sends WHERE opId=?", [Data(op.opId.utf8)]).first).flatMap { Int(String(decoding: $0[0], as: UTF8.self)) } ?? 0
      let now = CloudSyncBytes.now()
      try store.execute("UPDATE outbox SET state='parked' WHERE opId=?", [Data(op.opId.utf8)])
      try store.execute("INSERT OR REPLACE INTO parked_sends(opId,reason,parkedAt,attempts,nextAt,permanent) VALUES (?,?,CAST(? AS INTEGER),CAST(? AS INTEGER),CAST(? AS INTEGER),CAST(? AS INTEGER))", [
        Data(op.opId.utf8), Data(reason.utf8), Data(String(now).utf8), Data(String(attempts + 1).utf8),
        Data(String(permanent ? 0 : now + Self.parkedGap(attempts)).utf8), Data((permanent ? "1" : "0").utf8)])
    }
  }
  private var launchSendRetryPending = true
  /// Parked edits whose back-off is due (or all retryable ones at launch, or those of `domains`) go back to the
  /// queue; their attempt count stays, so a new refusal waits longer.
  private func retryParkedSends(force: Bool, domains: Set<String>? = nil) throws {
    let now = CloudSyncBytes.now()
    try store.transaction {
      for row in try store.rows("SELECT p.opId,o.domain,p.nextAt FROM parked_sends p JOIN outbox o ON o.opId=p.opId WHERE o.state='parked' AND p.permanent=0") {
        let due = force || (Int64(String(decoding: row[2], as: UTF8.self)) ?? 0) <= now || (domains?.contains(String(decoding: row[1], as: UTF8.self)) ?? false)
        if due { try store.execute("UPDATE outbox SET state='queued' WHERE opId=?", [row[0]]) }
      }
    }
  }
  /// Queued edits held behind an edit of the same record that is parked on the send side (round 5 S1).
  private func waitingBehindParkedSends() throws -> [String: Int] {
    var totals: [String: Int] = [:]
    // 0.23.6 (CPU): nothing parked on the send side (the usual case) holds nothing back; no walk of the waiting rows.
    guard try !store.rows("SELECT 1 FROM outbox WHERE state='parked' LIMIT 1").isEmpty else { return totals }
    for row in try store.rows("SELECT r.bytes FROM outbox o JOIN records r ON r.opId=o.opId WHERE o.state='queued' AND EXISTS (SELECT 1 FROM outbox p WHERE p.state='parked' AND p.domain=o.domain AND p.entityId=o.entityId AND p.rowid<o.rowid AND NOT EXISTS (SELECT 1 FROM parked_sends ps WHERE ps.opId=p.opId AND ps.permanent=1))") {
      totals[try JSONDecoder().decode(CloudOperation.self, from: row[0]).source.sourceId, default: 0] += 1
    }
    return totals
  }
  private func sendParkedBySource() throws -> [String: (count: Int, reason: String)] {
    var result: [String: (count: Int, reason: String)] = [:]
    for row in try store.rows("SELECT r.bytes,parked_sends.reason FROM parked_sends JOIN outbox ON outbox.opId=parked_sends.opId JOIN records r ON r.opId=outbox.opId WHERE outbox.state='parked'") {
      let source = try JSONDecoder().decode(CloudOperation.self, from: row[0]).source.sourceId
      result[source] = ((result[source]?.count ?? 0) + 1, String(decoding: row[1], as: UTF8.self))
    }
    return result
  }
  /// Parked records per source: count and the newest reason (reported as a gap).
  private func parkedBySource() throws -> [String: (count: Int, reason: String)] {
    var result: [String: (count: Int, reason: String)] = [:]
    for row in try store.rows("SELECT sourceId,count(*),max(reason) FROM parked_ops GROUP BY sourceId") {
      result[String(decoding: row[0], as: UTF8.self)] = (Int(String(decoding: row[1], as: UTF8.self)) ?? 0, String(decoding: row[2], as: UTF8.self))
    }
    return result
  }
  /// The domain reader can request nested sealed file references through this same bounded route.
  public func sealedFile(_ ref: CloudBlobRef, sourceId: String) async throws -> CloudLocalBlob {
    let bytes: Data
    let row = try store.rows("SELECT bytes,descriptor FROM objects WHERE blobId=?", [Data(ref.blobId.utf8)]).first
    if let row { guard try JSONDecoder().decode(CloudBlobRef.self, from: row[1]) == ref else { throw CloudFailure.idReused } }
    if let row, !row[0].isEmpty { bytes = row[0] }
    else {
      // Not here, or dropped after its cloud receipt: download again (handed over, then released after the operation).
      bytes = try await downloadObject(ref)
      try CloudSyncSealedFile.validate(bytes, reference: ref)
      if row != nil {
        try store.execute("UPDATE objects SET bytes=?,receipt=? WHERE blobId=?", [bytes, try CloudSyncCanonical.encode(ref), Data(ref.blobId.utf8)])
      } else {
        try store.execute("INSERT INTO objects(blobId,bytes,descriptor,receipt) VALUES (?,?,?,?)", [Data(ref.blobId.utf8), bytes,
          try CloudSyncCanonical.encode(ref), try CloudSyncCanonical.encode(ref)])
      }
    }
    if ref.storageClass == .brain { _ = try await content.open(decodeEnvelope(bytes)) }
    return try store.materialize(bytes, reference: ref, sourceId: sourceId)
  }
  private func incomingFiles(_ operations: [CloudOperation]) async throws -> [CloudLocalBlob] {
    var files: [CloudLocalBlob] = []
    let refs = try CloudSyncSealedFile.references(in: operations)
    try roomForDownloads(refs)
    for ref in refs {
      files.append(try await sealedFile(ref, sourceId: operations.first?.source.sourceId ?? ""))
    }
    return files
  }
  /// Round 6 S3: files are downloaded only within the staging bound and above the free-disk floor. Received bytes
  /// of earlier packs are released first; if the files still do not fit, the pull stops with a plain reason and
  /// is retried (nothing is applied half). A set of files larger than the whole bound is refused with its reason.
  private func roomForDownloads(_ refs: [CloudBlobRef]) throws {
    var needed: Int64 = 0
    for ref in refs {
      let present = try !store.rows("SELECT blobId FROM objects WHERE blobId=? AND length(bytes)>0", [Data(ref.blobId.utf8)]).isEmpty
      if !present { needed += ref.bytes }
    }
    guard needed > 0 else { return }
    guard needed <= staging.maximumStagedBytes else {
      try store.set("downloadPaused", "Some records' files are larger together than this Mac's staging limit, so they cannot be restored here yet.")
      throw CloudFailure.invalidRequest
    }
    if let free = staging.freeBytes(store.root), free - needed < staging.minimumFreeBytes {
      let floor = Double(staging.minimumFreeBytes) / 1_073_741_824
      try store.set("downloadPaused", "Downloads are paused: less than \(String(format: "%.0f", floor)) GB would be free on this Mac. They continue by themselves when space is free.")
      throw CloudFailure.unavailable
    }
    if try store.stagedBytes() + needed > staging.maximumStagedBytes {
      try store.dropReceiptedBytes(except: keepBytes)
      if try store.stagedBytes() + needed > staging.maximumStagedBytes {
        try store.set("downloadPaused", "Downloads are waiting: files staged on this Mac fill its staging limit.")
        throw CloudFailure.unavailable
      }
    }
    try store.execute("DELETE FROM metadata WHERE key=?", [Data("downloadPaused".utf8)])
  }
  private func verifyAbsentInitialProtectedSlot() async throws {
    // The switch: first uploads are passed over ENTIRELY in this version, for saved passwords as for memory.
    // Whatever sits in slot 1 (also a first upload that carries a saved-password part) is never read and nothing
    // waits on it; the feed, which starts at position 2, already shows that slot 1 holds no pack.
    guard firstUpload else { return }
    let verified: Bool = try store.value("inventoryVerified") ?? false
    guard verified, let checkpoint = try await transport.checkpoint(), checkpoint.secretsRoot == nil else {
      // An unsupported protected checkpoint must wait; it must never become an applied cursor.
      throw CloudFailure.unsupportedFormat
    }
  }
  private func pullSecretsOwned(through head: CloudSequence) async throws -> [CloudImportReceipt] {
    guard let secretsContent, await secretsContent.state(storageClass: .secrets).available else { return [] }
    let currentEpoch = await secretsContent.state(storageClass: .secrets).epoch
    var cursor: CloudSequence = try store.value("secretsSeq") ?? .zero
    var receipts: [CloudImportReceipt] = []
    while cursor < head {
      let page = try await transport.changes(after: cursor, limit: Self.feedPageLimit)
      guard page.headSeq >= head, page.nextAfter >= cursor, page.nextAfter <= page.headSeq else { throw CloudFailure.invalidRequest }
      if cursor == .zero, page.segments.isEmpty, head == CloudSequence(1), !page.hasMore {
        try await verifyAbsentInitialProtectedSlot()
        cursor = CloudSequence(1)
        try store.set("secretsSeq", cursor)
        break
      }
      guard !page.segments.isEmpty else { throw CloudFailure.invalidRequest }
      let before = cursor
      if cursor == .zero, page.segments.first?.seq == CloudSequence(2) {
        // The retained, authenticated feed proves that slot 1 has no segment.
        // A later checkpoint alone never provides that proof.
        try await verifyAbsentInitialProtectedSlot()
        cursor = CloudSequence(1)
        try store.set("secretsSeq", cursor)
      }
      for entry in page.segments where entry.seq <= head {
        guard let n = UInt64(cursor.rawValue), n < UInt64.max, entry.seq == CloudSequence(n + 1) else { throw CloudFailure.invalidRequest }
        if entry.storageClass == .secrets {
          // This Mac holds the current saved-password key (checked above). A pack it still cannot open (the
          // service hides an older-key pack as locked, or opening fails) is parked and retried, never a stall.
          // An integrity failure of a current-key pack still stops here (nothing unverified applies, S06).
          if let older = entry.keyEpoch, older < currentEpoch {
            // Round 6 S6: sealed with a key the new key replaced: no device can open it. Recorded ONCE as
            // superseded (an intentional exclusion), never parked and retried for ever.
            try supersedePack(entry.seq, keyEpoch: older)
          } else if entry.locked == true {
            try parkPack(entry.seq, reason: "This saved-password pack cannot be opened on this Mac (an older or unknown key).")
          } else {
            receipts += try await receive(entry, cursorKey: "secretsSeq")
          }
        }
        cursor = entry.seq
        try store.set("secretsSeq", cursor)
      }
      guard cursor > before, cursor >= head || page.hasMore, page.nextAfter > head || page.nextAfter == cursor else { throw CloudFailure.invalidRequest }
    }
    try store.set("secretsPending", false)
    return receipts
  }
  private func currentInventory() async throws -> [String: CloudSourceInventory] { try await askedInventory().sources }
  /// The sources the adapters list now, and the domains that were really ASKED. The loop awaits each adapter, so an
  /// adapter registered meanwhile (actor reentrancy: lane L3's settings adapter registers right after the tasks
  /// adapter, while a pull's coverage refresh is in this loop) is in `adapters` afterwards without having been asked.
  private func askedInventory() async throws -> (sources: [String: CloudSourceInventory], asked: Set<String>) {
    var result: [String: CloudSourceInventory] = [:], asked: Set<String> = []
    for (domain, adapter) in adapters {
      if secretsDomains.contains(domain) {
        guard let secretsContent, await secretsContent.state(storageClass: .secrets).available else { continue }
        do { for source in try await adapter.sourceInventory() { result[source.sourceId] = source } }
        catch { continue }
      } else {
        for source in try await adapter.sourceInventory() { result[source.sourceId] = source }
      }
      asked.insert(domain)
    }
    return (result, asked)
  }
  // MARK: Coverage: what the verified inventory says (published) and what this Mac's adapter says (local) are
  // kept apart and combined FRESH each time, so a gap that heals clears (complete returns to true without a
  // new setup) and an ended exclusion disappears. Gaps (`blockedReasons`) make a source incomplete;
  // intentional exclusions never do.

  private func setPublishedCoverage(_ coverage: CloudCoverage) throws {
    try store.set("coverage-published:" + coverage.sourceId, coverage)
    try recomputeCoverage(coverage.sourceId)
  }
  private func setLocalCoverage(_ source: CloudSourceInventory) throws {
    try store.set("coverage-local:" + source.sourceId, source)
    // A source an adapter lists only later (a boot-file folder chosen after sign-in) is known by its domain too.
    try store.set("coverage-domain:" + source.sourceId, source.domain)
    try recomputeCoverage(source.sourceId)
  }
  private func recomputeCoverage(_ sourceId: String) throws {
    let published: CloudCoverage? = try store.value("coverage-published:" + sourceId)
    let local: CloudSourceInventory? = try store.value("coverage-local:" + sourceId)
    // 13 Nov leftover: a source of a domain that is never in a first saved copy (boot files) has no verified snapshot
    // to wait for. With none published, this Mac's own statement is the whole of it.
    let domain: String? = try store.value("coverage-domain:" + sourceId)
    // 14 Nov (Mac mini): with no first upload a source's published coverage is only this Mac's own setup statement
    // (settleFeedBaselineIfSent), and this Mac owns it. When that statement is gone (lost to the registration race
    // fixed in dropVanishedCoverage), nothing can ever publish it again: this Mac's own statement is the whole of it,
    // never "Waiting for a verified snapshot." for good. A source still in an unsettled first copy is not owned yet.
    let ownFeedStatement = try published == nil && !firstUpload && (store.value("baseline") as String?) == "feed"
      && (store.value("coverage-owner:" + sourceId) as Bool?) == true
    let noSnapshot = published == nil && ((domain.map { withoutSetup.contains($0) } ?? false) || ownFeedStatement)
    let gaps = (published.map { $0.blockedReasons } ?? (noSnapshot ? [] : ["Waiting for a verified snapshot."])) +
      (local.map { $0.blockedReasons } ?? ["This source has not been inventoried here."])
    try store.set("coverage:" + sourceId, CloudCoverage(sourceId: sourceId, inventoryRow: local?.inventoryRow ?? published?.inventoryRow ?? "",
      complete: (published?.complete ?? noSnapshot) && local?.complete == true, items: local?.items ?? published?.items ?? 0,
      bytes: local?.bytes ?? published?.bytes ?? 0, blockedReasons: Array(Set(gaps)).sorted(),
      exclusions: Array(Set((published?.exclusions ?? []) + (local?.exclusions ?? []))).sorted()))
  }
  private func rememberCoverage(_ coverage: [CloudCoverage]) async throws {
    for source in coverage { try setPublishedCoverage(source) }
    try await refreshKnownCoverage()
  }
  private var coverageRefreshRequested = false
  private func refreshKnownCoverage() async throws {
    coverageRefreshRequested = false
    let (current, asked) = try await askedInventory()
    for source in current.values {
      try setLocalCoverage(source)
      try correctPublishedGapIfHealed(source)
    }
    try dropVanishedCoverage(listed: Set(current.keys), asked: asked)
  }
  /// Contract addition (13 Nov leftover): an adapter's sources changed outside a pull (boot files: a folder chosen and
  /// the waiting files written). The coverage the Cloud page reads is taken again now. Nothing is sent or fetched.
  public func refreshCoverage() async throws { try await refreshKnownCoverage() }
  /// 13 Nov leftover: a source its adapter no longer lists (boot files' "wait for a folder" line once every file has
  /// its folder) kept its last statement for ever, so the page said "2 boot files wait for a folder" after they were
  /// written. A registered adapter's word is the whole truth about its own sources: such a source leaves coverage.
  /// Saved-password sources are skipped (a locked vault lists nothing without the sources having gone). With a first
  /// upload, what the account's inventory published about the source stays and only this Mac's part goes.
  /// 14 Nov (Mac mini, "Settings: Not complete" for ever): only a domain whose adapter was ASKED in this pass may lose
  /// a source. Judged against the live adapter list, an adapter registered during the pass lost its first-copy coverage
  /// the moment it registered, and nothing ever wrote it again ("Waiting for a verified snapshot." for good).
  private func dropVanishedCoverage(listed: Set<String>, asked: Set<String>) throws {
    for (key, value) in try store.prefixed("coverage-local:") {
      let sourceId = String(key.dropFirst("coverage-local:".count))
      guard !listed.contains(sourceId), let local = try? JSONDecoder().decode(CloudSourceInventory.self, from: value),
        asked.contains(local.domain), adapters[local.domain] != nil, !secretsDomains.contains(local.domain) else { continue }
      try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)])
      let published: CloudCoverage? = try store.value("coverage-published:" + sourceId)
      if published != nil && firstUpload { try recomputeCoverage(sourceId); continue }
      for gone in ["coverage:", "coverage-published:"] { try store.execute("DELETE FROM metadata WHERE key=?", [Data((gone + sourceId).utf8)]) }
    }
  }

  // MARK: Coverage corrections (round 5 S3, Decker): no gap is permanent by construction.

  /// Engine-owned record kind carried in the feed: a source's corrected published coverage.
  static let coverageDomain = "sync-coverage"
  /// The Mac that healed a gap present in the published inventory publishes the correction: once its own source
  /// is complete and nothing of it is queued, held or parked, it queues a coverage record (once per published
  /// state). Every Mac, itself included, adopts it as that source's published coverage.
  private func correctPublishedGapIfHealed(_ local: CloudSourceInventory) throws {
    // Only the Mac that published the account's inventory may correct it: another Mac being complete locally
    // says nothing about what the publisher failed to upload (round 6 M1).
    let owner: Bool = try store.value("coverage-owner:" + local.sourceId) ?? false
    let maker: String? = try store.value("inventoryMaker")
    let baseline: String? = try store.value("baseline")
    // The switch: with no first upload a source's published coverage is this Mac's OWN setup statement. It never
    // travels, so this Mac corrects it here and sends no record.
    let ownStatement = !firstUpload && baseline == "feed"
    guard owner, ownStatement || maker == deviceId else { return }
    guard local.complete, local.blockedReasons.isEmpty, brainDomains.contains(local.domain),
      let published: CloudCoverage = try store.value("coverage-published:" + local.sourceId), !published.complete || !published.blockedReasons.isEmpty else { return }
    let marker = "coverage-correction:" + local.sourceId
    let state = CloudSyncBytes.hash(try CloudSyncCanonical.encode(published))
    guard (try store.value(marker) as String?) != state else { return }
    guard try store.rows("SELECT opId FROM parked_ops WHERE sourceId=? LIMIT 1", [Data(local.sourceId.utf8)]).isEmpty else { return }
    for row in try store.rows("SELECT r.bytes FROM outbox o JOIN records r ON r.opId=o.opId WHERE o.state IN ('queued','parked')") {
      if try JSONDecoder().decode(CloudOperation.self, from: row[0]).source.sourceId == local.sourceId { return }
    }
    let corrected = CloudCoverage(sourceId: local.sourceId, inventoryRow: local.inventoryRow, complete: true, items: local.items, bytes: local.bytes,
      blockedReasons: [], exclusions: Array(Set(published.exclusions + local.exclusions)).sorted())
    if ownStatement {
      try store.set(marker, state)
      try setPublishedCoverage(corrected)
      return
    }
    // Device trust: no coverage record is published while any pack waits on this Mac.
    guard try store.heldRows().isEmpty else { return }
    let payload = CloudValue(try NativeRPCValue.parseJSON(CloudSyncCanonical.encode(corrected)))
    let id = UUID().uuidString.lowercased()
    let op = CloudOperation(v: 1, opId: id, originDevice: deviceId, domain: Self.coverageDomain, entityId: local.sourceId, revision: id,
      parents: [], kind: .put, source: .init(sourceId: local.sourceId, recordId: id), createdAt: CloudSyncBytes.now(),
      payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
    _ = try store.enqueue([op])
    try store.set(marker, state)
    try setPublishedCoverage(corrected)
    sendRequested = true
  }
  /// A correction is adopted only from the account inventory's maker (round 6 M1), and under device trust only
  /// when the pack's VERIFIED signer is that maker: the record's own origin field can only narrow this, never
  /// grant it. With no first upload there is no maker and no correction is adopted. Any other device's
  /// correction is kept as a record, not adopted.
  private func applyCoverageCorrections(_ operations: [CloudOperation], signer: String) throws {
    let maker: String? = try store.value("inventoryMaker")
    for op in operations where op.domain == Self.coverageDomain {
      let corrected = try JSONDecoder().decode(CloudCoverage.self, from: CloudSyncCanonical.encode(op.payload))
      guard corrected.sourceId == op.entityId else { throw CloudFailure.checksumMismatch }
      guard let maker, signer == maker, op.originDevice == maker else { continue }
      try setPublishedCoverage(corrected)
    }
  }
  public func restoreProgress() async throws -> CloudRestoreProgress {
    let budgetState = try await budget.status()
    let locallyBlocked: Bool = try store.value("blocked") ?? false
    let protectedPending: Bool = try store.value("secretsPending") ?? false
    let bootstrapCut: String? = try store.value("bootstrapInProgress")
    let parked = Int(String(decoding: try store.rows("SELECT count(*) FROM parked_ops")[0][0], as: UTF8.self)) ?? 0
    // Round 6 S7d: only edits still parked; a parked_sends row of an edit back in the queue keeps its back-off only.
    let parkedSends = Int(String(decoding: try store.rows("SELECT count(*) FROM parked_sends p JOIN outbox o ON o.opId=p.opId WHERE o.state='parked'")[0][0], as: UTF8.self)) ?? 0
    // Round 6 S6: a saved-password pack this Mac cannot open stays a gap on saved-password sources; it does not
    // hold the account-wide flag (saved passwords never block memory).
    let blocked = locallyBlocked || protectedPending || bootstrapCut != nil || parked > 0 || parkedSends > 0
    // Parked records are kept as cloud-verified for inventories, but they are not applied here.
    let applied = max(0, (Int(String(decoding: try store.rows("SELECT count(*) FROM verified_ops")[0][0], as: UTF8.self)) ?? 0) - parked)
    return .init(queued: try store.queuedCount(), applied: applied,
      blocked: (blocked || budgetState.blocked != nil || budgetState.retryAt > CloudSyncBytes.now()) ? 1 : 0,
      brainSeq: try store.value("brainSeq") ?? .zero, secretsSeq: try store.value("secretsSeq") ?? .zero, coverage: try reportedCoverage())
  }
  public func contextReady(projectId: String) async throws -> CloudContextReady {
    let progress = try await restoreProgress()
    let sourceCoverage = try progress.coverage.filter { coverage in
      let domain: String? = try store.value("coverage-domain:" + coverage.sourceId)
      return domain.map { brainDomains.contains($0) } ?? true
    }
    let hasPending = try store.hasPending(projectId: projectId, domains: brainDomains)
    let budgetState = try await budget.status()
    let locallyBlocked: Bool = try store.value("blocked") ?? false
    let bootstrapCut: String? = try store.value("bootstrapInProgress")
    let brainBlocked = locallyBlocked || bootstrapCut != nil || budgetState.blocked != nil || budgetState.retryAt > CloudSyncBytes.now()
    let head: CloudSequence? = try store.value("headSeq")
    let verifiedInventory = try baselineSettled()
    let paused: Bool = try store.value("paused") ?? false
    // Round 5 M2: nothing parked, in or out, whatever source it belongs to (a source may have no row here).
    let nothingParked = try ["parked_ops", "parked_sends WHERE permanent IN (0,1) AND opId IN (SELECT opId FROM outbox WHERE state='parked')"].allSatisfy {
      try store.rows("SELECT 1 FROM " + $0 + " LIMIT 1").isEmpty
    }
    let ready = verifiedInventory && head != nil && progress.brainSeq == head && !hasPending && !brainBlocked &&
      !sourceCoverage.isEmpty && sourceCoverage.allSatisfy(\.complete) && !paused && nothingParked
    return .init(projectId: projectId, throughSeq: progress.brainSeq,
      sourceCounts: .init(domains: sourceCoverage.count, records: sourceCoverage.reduce(0) { $0 + $1.items }, files: 0,
        bytes: sourceCoverage.reduce(0) { $0 + $1.bytes }, blocked: brainBlocked ? 1 : 0), verified: ready,
      missingSources: sourceCoverage.filter { !$0.complete }.map(\.sourceId) + (verifiedInventory ? [] : [unsettledBaselineLabel]))
  }
  /// Seals and stores an inventory object; it is uploaded later in a batch (`sendObjects`), before publishing.
  private func persistObject(_ plain: Data, key base: String) async throws -> CloudBlobRef {
    // The content hash is part of the key: a retry whose bytes changed (e.g. live source counts moved
    // after a failed upload) seals a new object instead of reusing one that no longer matches its digest.
    let key = base + ":" + CloudSyncBytes.hash(plain)
    // Reuse needs either the sealed bytes or the cloud's receipt (launch reconciliation may have removed an
    // unsent, unreferenced object; then it is sealed again, under the same content key).
    if let id: String = try store.value(key), let row = try store.rows("SELECT descriptor,bytes,receipt FROM objects WHERE blobId=?", [Data(id.utf8)]).first,
      !row[1].isEmpty || !row[2].isEmpty {
      let ref = try JSONDecoder().decode(CloudBlobRef.self, from: row[0])
      inventoryObjects.append(ref)
      if !row[1].isEmpty { keepBytes.insert(ref.blobId) }
      return ref
    }
    let id = UUID().uuidString.lowercased()
    let envelope = try await content.seal(plain, blobId: id, storageClass: .brain, purpose: .brain, epoch: epoch, codec: .gzip)
    let bytes = try CloudSyncCanonical.encode(envelope)
    let ref = CloudSyncBytes.blob(bytes, envelope: envelope)
    // Never more than the staging bound: before staging this object, send what is sealed so far and let its
    // bytes go (the publisher then reads those leaves back from the cloud when it imports its own inventory).
    if try store.stagedBytes() + Int64(bytes.count) > staging.maximumStagedBytes, !inventoryObjects.isEmpty {
      try await sendObjects(inventoryObjects)
      keepBytes.subtract(inventoryObjects.map(\.blobId))
      try store.dropReceiptedBytes(inventoryObjects.map(\.blobId))
    }
    try store.transaction {
      try store.execute("INSERT INTO objects(blobId,bytes,descriptor) VALUES (?,?,?)", [Data(id.utf8), bytes, try CloudSyncCanonical.encode(ref)])
      try store.set(key, id)
    }
    inventoryObjects.append(ref)
    keepBytes.insert(ref.blobId)
    return ref
  }
  /// Objects sealed for the inventory being built; sent together (batched) just before it is published.
  private var inventoryObjects: [CloudBlobRef] = []
  /// Client cut 1: uploads up to 16 objects per prepare and per finalize (and a batch of at most 48 MiB, so every
  /// upload finishes well inside its five-minute ticket), then reads them back with one `/blobs/read` per batch.
  /// Each item's finalize result is handled on its own: an item with any error goes through the single-object
  /// path (`sendObject`), which keeps the repair, saved-password and failure rules.
  private func sendObjects(_ refs: [CloudBlobRef]) async throws {
    var batch: [(CloudBlobRef, Data)] = [], batchBytes: Int64 = 0, seen = Set<String>()
    for ref in refs where seen.insert(ref.blobId).inserted {
      guard let row = try store.rows("SELECT receipt,descriptor,bytes FROM objects WHERE blobId=?", [Data(ref.blobId.utf8)]).first else { throw CloudFailure.unavailable }
      guard try JSONDecoder().decode(CloudBlobRef.self, from: row[1]) == ref else { throw CloudFailure.idReused }
      if !row[0].isEmpty {
        guard try JSONDecoder().decode(CloudBlobRef.self, from: row[0]) == ref else { throw CloudFailure.idReused }
        continue
      }
      if batch.count >= uploadBatchLimit || (!batch.isEmpty && batchBytes + ref.bytes > Self.uploadBatchBytes) {
        try await sendBatch(batch); batch = []; batchBytes = 0
      }
      batch.append((ref, row[2])); batchBytes += ref.bytes
    }
    if !batch.isEmpty { try await sendBatch(batch) }
  }
  static let uploadBatchBytes: Int64 = 48 * 1024 * 1024
  /// Files per prepare/finalize: starts small and grows to 16 at the measured upload rate (round 5 S5).
  private var uploadBatchLimit = 4
  static func milliseconds(_ duration: Duration) -> Int64 {
    let parts = duration.components
    return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
  }
  private func sendBatch(_ batch: [(CloudBlobRef, Data)]) async throws {
    if batch.count == 1 { _ = try await sendObject(batch[0].0); return }
    var uploads: [CloudBlobUpload] = []
    for (ref, bytes) in batch {
      try CloudSyncSealedFile.validate(bytes, reference: ref)
      if ref.storageClass == .brain { _ = try await content.open(decodeEnvelope(bytes)) }
      let uploadKey = "upload:" + ref.blobId + ":device:" + deviceId
      let uploadId: String
      if let existing: String = try store.value(uploadKey) { uploadId = existing }
      else { uploadId = UUID().uuidString.lowercased(); try store.set(uploadKey, uploadId) }
      uploads.append(.init(uploadId: uploadId, blobId: ref.blobId, storageClass: ref.storageClass, purpose: ref.purpose,
        keyEpoch: ref.keyEpoch, bytes: ref.bytes, sha256: ref.sha256, md5: ref.md5))
    }
    let tickets = try await transport.prepareBlobs(uploads)
    guard tickets.count == uploads.count, zip(tickets, uploads).allSatisfy({ $0.uploadId == $1.uploadId && $0.blobId == $1.blobId }) else { throw CloudFailure.checksumMismatch }
    var finalize: [CloudBlobFinalize] = [], single: [CloudBlobRef] = [], deferred: [(CloudBlobRef, Data)] = []
    // Round 5 S5: finalize while the oldest ticket is still young. Once the upload window (default three
    // minutes) has passed since prepare, the remaining files go to a fresh batch instead of being uploaded
    // under tickets that would expire before finalize and then be uploaded a second time.
    let preparedAt = CloudSyncBytes.now()
    let window = Self.milliseconds(staging.uploadWindow)
    for ((ref, bytes), (ticket, upload)) in zip(batch, zip(tickets, uploads)) {
      if !ticket.alreadyPresent, !finalize.isEmpty, CloudSyncBytes.now() - preparedAt > window { deferred.append((ref, bytes)); continue }
      if !ticket.alreadyPresent {
        do { try await objects.upload(bytes, ticket: ticket) }
        catch CloudSyncTransferFailure.uploadExpired { single.append(ref); continue }
      }
      try fault(.afterUpload)
      finalize.append(.init(uploadId: upload.uploadId, blobId: ref.blobId, ticket: ticket.ticket))
    }
    var finalized: [CloudBlobRef] = []
    if !finalize.isEmpty {
      let results = try await transport.finalizeBlobs(finalize)
      guard results.count == finalize.count else { throw CloudFailure.checksumMismatch }
      for (item, result) in zip(finalize, results) {
        guard result.uploadId == item.uploadId, let ref = batch.first(where: { $0.0.blobId == item.blobId })?.0 else { throw CloudFailure.checksumMismatch }
        if result.error != nil { single.append(ref); continue }
        guard result.blob == ref else { throw CloudFailure.checksumMismatch }
        try fault(.afterFinalize)
        finalized.append(ref)
      }
    }
    // Finalized objects are read back before their publication or local receipt: one call for the batch.
    if !finalized.isEmpty {
      let links = try await transport.readBlobs(ids: finalized.map(\.blobId))
      for ref in finalized {
        guard let bytes = batch.first(where: { $0.0.blobId == ref.blobId })?.1 else { throw CloudFailure.unavailable }
        guard let link = links.first(where: { $0.blob.blobId == ref.blobId }), link.blob == ref else { throw CloudFailure.checksumMismatch }
        let remote: Data
        do { remote = try await objects.download(link.getUrl, maximumBytes: CloudWire.maximumBlobBytes) }
        catch CloudSyncTransferFailure.readExpired { remote = try await downloadObject(ref) }
        guard remote == bytes else { throw CloudFailure.checksumMismatch }
        try store.execute("UPDATE objects SET receipt=? WHERE blobId=?", [try CloudSyncCanonical.encode(ref), Data(ref.blobId.utf8)])
        // The cloud holds it with a read-back receipt: the sealed bytes leave this Mac (references stay).
        if !keepBytes.contains(ref.blobId) { try store.dropReceiptedBytes([ref.blobId]) }
      }
    }
    for ref in single { _ = try await sendObject(ref) }
    // Grow the batch while uploads finish well inside the window; halve it when files had to wait.
    if deferred.isEmpty, CloudSyncBytes.now() - preparedAt < window / 3 { uploadBatchLimit = min(16, uploadBatchLimit * 2) }
    else if !deferred.isEmpty { uploadBatchLimit = max(1, uploadBatchLimit / 2) }
    if !deferred.isEmpty { try await sendBatch(deferred) }
  }
  private func sendObject(_ ref: CloudBlobRef) async throws -> CloudBlobRef {
    guard let row = try store.rows("SELECT receipt,descriptor FROM objects WHERE blobId=?", [Data(ref.blobId.utf8)]).first else { throw CloudFailure.unavailable }
    guard try JSONDecoder().decode(CloudBlobRef.self, from: row[1]) == ref else { throw CloudFailure.idReused }
    if !row[0].isEmpty {
      guard try JSONDecoder().decode(CloudBlobRef.self, from: row[0]) == ref else { throw CloudFailure.idReused }
      return ref
    }
    guard let bytes = try store.rows("SELECT bytes FROM objects WHERE blobId=?", [Data(ref.blobId.utf8)]).first?[0] else { throw CloudFailure.unavailable }
    try CloudSyncSealedFile.validate(bytes, reference: ref)
    if ref.storageClass == .brain { _ = try await content.open(decodeEnvelope(bytes)) }
    let uploadId: String
    let uploadKey = "upload:" + ref.blobId + ":device:" + deviceId
    if let existing: String = try store.value(uploadKey) { uploadId = existing }
    else { uploadId = UUID().uuidString.lowercased(); try store.set(uploadKey, uploadId) }
    let upload = CloudBlobUpload(uploadId: uploadId, blobId: ref.blobId, storageClass: ref.storageClass, purpose: ref.purpose,
      keyEpoch: ref.keyEpoch, bytes: ref.bytes, sha256: ref.sha256, md5: ref.md5)
    var results: [CloudBlobResult] = []
    for attempt in 0..<2 {
      guard var ticket = try await transport.prepareBlobs([upload]).first, ticket.uploadId == uploadId, ticket.blobId == ref.blobId else { throw CloudFailure.checksumMismatch }
      if !ticket.alreadyPresent {
        do { try await objects.upload(bytes, ticket: ticket) }
        catch CloudSyncTransferFailure.uploadExpired {
          guard let renewed = try await transport.prepareBlobs([upload]).first, renewed.uploadId == uploadId, renewed.blobId == ref.blobId else { throw CloudFailure.checksumMismatch }
          ticket = renewed
          if !ticket.alreadyPresent { try await objects.upload(bytes, ticket: ticket) }
        }
      }
      try fault(.afterUpload)
      results = try await transport.finalizeBlobs([.init(uploadId: uploadId, blobId: ref.blobId, ticket: ticket.ticket)])
      guard results.count == 1, results[0].uploadId == uploadId else { throw CloudFailure.checksumMismatch }
      guard let detail = results[0].error else { break }
      // An expired ticket or a vanished staging copy is repaired here: re-prepare and re-upload once.
      if attempt == 0, Self.repairableFinalizeCodes.contains(detail.code) {
        // The service keeps its answer per request id. A fresh prepare gets a new ticket, so the repaired
        // finalize is a different request instead of a replay of the saved refusal.
        try store.set("refresh-upload:" + uploadId, true)
        continue
      }
      // Protected-only refusals wait with saved passwords; they never block brain sync for the account.
      if ref.storageClass == .secrets, Self.protectedFinalizeCodes.contains(detail.code) { throw CloudFailure.secretsLocked }
      let failure = CloudFailure.remote(.init(code: detail.code, message: "Cloud file finalization is waiting.", retryable: detail.retryable, requestId: uploadId))
      try await budget.failed(failure)
      throw failure
    }
    guard results.count == 1, results[0].error == nil, results[0].blob == ref else { throw CloudFailure.checksumMismatch }
    try fault(.afterFinalize)
    // Finalized object is independently read back before its publication or local receipt.
    let remote = try await downloadObject(ref)
    guard remote == bytes else { throw CloudFailure.checksumMismatch }
    try store.execute("UPDATE objects SET receipt=? WHERE blobId=?", [try CloudSyncCanonical.encode(ref), Data(ref.blobId.utf8)])
    if !keepBytes.contains(ref.blobId) { try store.dropReceiptedBytes([ref.blobId]) }
    return ref
  }
  private func downloadObject(_ ref: CloudBlobRef) async throws -> Data {
    guard let first = try await transport.readBlobs(ids: [ref.blobId]).first, first.blob == ref else { throw CloudFailure.checksumMismatch }
    do { return try await objects.download(first.getUrl, maximumBytes: CloudWire.maximumBlobBytes) }
    catch CloudSyncTransferFailure.readExpired {
      guard let renewed = try await transport.readBlobs(ids: [ref.blobId]).first, renewed.blob == ref else { throw CloudFailure.checksumMismatch }
      return try await objects.download(renewed.getUrl, maximumBytes: CloudWire.maximumBlobBytes)
    }
  }
  private func readObject(_ ref: CloudBlobRef) async throws -> Data {
    guard let plain = try await readObjects([ref]).first else { throw CloudFailure.checksumMismatch }
    return plain
  }
  /// Inventory objects, up to 16 per call (client cut 3): a copy this Mac already holds with a verified receipt
  /// (its own uploads after read-back, or earlier downloads) is used locally (cut 5: the publisher does not
  /// download its own leaves again); the rest are asked for in ONE `/blobs/read`, and if links expire part-way
  /// only the remaining ids are asked for again.
  private func readObjects(_ refs: [CloudBlobRef]) async throws -> [Data] {
    guard refs.count <= 16 else {
      var all: [Data] = []
      for start in stride(from: 0, to: refs.count, by: 16) { all += try await readObjects(Array(refs[start..<min(start + 16, refs.count)])) }
      return all
    }
    var sealed: [String: Data] = [:], remote: [CloudBlobRef] = []
    for ref in refs {
      guard ref.storageClass == .brain, ref.purpose == .brain, ref.keyEpoch > 0 else { throw CloudFailure.unsupportedFormat }
      if let row = try store.rows("SELECT bytes,receipt FROM objects WHERE blobId=?", [Data(ref.blobId.utf8)]).first,
        !row[0].isEmpty, !row[1].isEmpty, row[1] == (try CloudSyncCanonical.encode(ref)) { sealed[ref.blobId] = row[0] }
      else if !remote.contains(ref) { remote.append(ref) }
    }
    var stalled = 0
    while !remote.isEmpty {
      let links = try await transport.readBlobs(ids: remote.map(\.blobId))
      for ref in remote {
        guard let link = links.first(where: { $0.blob.blobId == ref.blobId }), link.blob == ref else { throw CloudFailure.checksumMismatch }
        do { sealed[ref.blobId] = try await objects.download(link.getUrl, maximumBytes: CloudWire.maximumBlobBytes) }
        catch CloudSyncTransferFailure.readExpired { break }
      }
      let left = remote.filter { sealed[$0.blobId] == nil }
      // Links live about a minute: renew only what is left; give up if a fresh link expires before any download.
      if left.count == remote.count { stalled += 1; if stalled >= 2 { throw CloudFailure.unavailable } } else { stalled = 0 }
      remote = left
    }
    var plain: [Data] = []
    for ref in refs {
      guard let bytes = sealed[ref.blobId] else { throw CloudFailure.checksumMismatch }
      plain.append(try await openObject(bytes, ref: ref))
    }
    return plain
  }
  private func openObject(_ bytes: Data, ref: CloudBlobRef) async throws -> Data {
    try CloudSyncBytes.verify(bytes, ref: ref)
    let envelope = try decodeEnvelope(bytes)
    guard envelope.blobId == ref.blobId, envelope.epoch == ref.keyEpoch, envelope.storageClass == ref.storageClass,
      envelope.purpose == ref.purpose else { throw CloudFailure.checksumMismatch }
    return try await content.open(envelope)
  }
  private var setupGateChecked: String?
  /// The switch (no first upload): an upload that cannot go right now (a slow-down, no network) does not
  /// fail the setup. The files stay staged, within the staging bound, and go up with the baseline; for the rest
  /// of that setup run nothing more is tried as it arrives. Making ROOM under the staging bound (waitForRoom)
  /// still needs the upload: a setup whose files exceed the bound cannot finish without the network.
  private var setupUploadsDeferred = false
  private func uploadSetupFilesAsTheyArrive(_ cut: String) async throws {
    guard !firstUpload else { return try await uploadSetupFiles(cut) }
    guard !setupUploadsDeferred else { return }
    do { try await uploadSetupFiles(cut) }
    catch let failure as CloudFailure where failure == .budgetPaused || failure == .unavailable { setupUploadsDeferred = true }
  }
  /// Mac-next 2: how far the first copy is prepared on this Mac (records stored, records the cut holds), while setup
  /// reads its pages; nil otherwise. Shown by `baselineProgress()` instead of "Sending is held up".
  private var preparing: (done: Int, total: Int)?
  public func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt {
    // MAC-NEXT-5: a first copy waits for a fetch running alongside (a joining Mac's download) instead of failing
    // "busy" and waiting for a retry nobody arms (projects and agents never started on the joining MacBook).
    try await admit(bootstrap: true, waiting: true)
    setupGateChecked = nil
    setupUploadsDeferred = false
    defer { endBusy(); preparing = nil; scheduleSend() }
    do {
      guard !sources.isEmpty else { throw CloudFailure.invalidRequest }
      try beginBootstrap(cut.snapshotId)
      var estimate: Int? = 0
      for source in sources {
        if let known = estimate, let counting = source as? any CloudDomainSetupEstimating, let more = await counting.setupEstimate(cut: cut) { estimate = known + more }
        else { estimate = nil }
      }
      if let estimate { preparing = (0, estimate) }
      // Proof 3 (13 Nov): one information line when preparing starts and one when it ends; never a failure line.
      let preparingSince = Date()
      var prepared = 0
      CloudSyncDiagnostics.shared.info("preparing the first copy: " + (estimate.map { "\($0) records" } ?? "records not counted yet"))
      var coverage: [String: CloudCoverage] = [:], watermarks = cut.watermarks
      var declaredSources = Set<String>(), operationSources = Set<String>()
      for (sourceIndex, source) in sources.enumerated() {
        let inventory = try await source.sourceInventory()
        guard inventory.allSatisfy({ source.inventoryRows.contains($0.inventoryRow) && (brainDomains.contains($0.domain) || secretsDomains.contains($0.domain)) }) else { throw CloudFailure.unsupportedFormat }
        declaredSources.formUnion(inventory.map(\.sourceId))
        for item in inventory { try store.set("coverage-domain:" + item.sourceId, item.domain) }
        var pageIndex = 0
        for try await page in await source.snapshotPages(cut: cut) {
          try Task.checkCancellation()
          guard page.cut.snapshotId == cut.snapshotId, page.cut.at == cut.at else { throw CloudFailure.versionChanged }
          for (id, watermark) in page.cut.watermarks {
            if let old = watermarks[id], old != watermark { throw CloudFailure.versionChanged }
            watermarks[id] = watermark
          }
          try Self.checkRecordSizes(page.operations)
          try CloudSyncPack.validate(page.operations)
          try validateClasses(page.operations)
          operationSources.formUnion(page.operations.map { $0.source.sourceId })
          let files = page.files
          let key = "snapshot-page:\(cut.snapshotId):\(sourceIndex):\(pageIndex)"
          let digest = try Self.replayDigest(page)
          // Back-pressure: the next page is not stored (nor the one after it asked for) until it fits the bound.
          if (try store.value(key) as String?) == nil { try await waitForRoom(files.reduce(Int64(0)) { $0 + $1.bytes }) }
          try store.transaction {
            if let old: String = try store.value(key) {
              // An exact replay of a page already stored is accepted from its saved references alone: the
              // adapter need not (and cannot) seal the same bytes again, and the bytes are already retained.
              guard old == digest else { throw CloudFailure.idReused }
              return
            }
            // Rows and sealed bytes are durable before the next adapter page is requested.
            _ = try store.enqueue(page.operations, files: files, associations: page.associations, snapshotPage: key)
            try store.retainSnapshot(cut.snapshotId, operations: page.operations, keepBytes: false)
            for file in files {
              try store.execute("INSERT OR IGNORE INTO snapshot_files(snapshotId,blobId) VALUES (?,?)", [Data(cut.snapshotId.utf8), Data(file.blobId.utf8)])
            }
            try store.set(key, digest)
          }
          // Uploaded as it arrives; the sealed bytes leave at each file's read-back receipt.
          try await uploadSetupFilesAsTheyArrive(cut.snapshotId)
          for item in page.coverage { coverage[item.sourceId] = item }
          pageIndex += 1
          // A record's first part starts at offset 0; its later parts are not counted again.
          let firstParts = page.operations.filter { ($0.source.offset ?? 0) == 0 }.count
          prepared += firstParts
          if let now = preparing { preparing = (now.done + firstParts, now.total) }
        }
        let countKey = "snapshot-pages:\(cut.snapshotId):\(sourceIndex)"
        if let old: Int = try store.value(countKey), old != pageIndex { throw CloudFailure.idReused }
        try store.set(countKey, pageIndex)
      }
      CloudSyncDiagnostics.shared.info("first copy prepared: \(prepared) records in \(Int(Date().timeIntervalSince(preparingSince).rounded())) s")
      // Prepared: from here the page shows the send's own progress, never "Preparing n of n" during a download.
      preparing = nil
      guard !coverage.isEmpty, declaredSources.isSubset(of: Set(coverage.keys)), operationSources.isSubset(of: Set(coverage.keys)) else { throw CloudFailure.invalidRequest }
      try store.linkSnapshotFiles(cut.snapshotId)
      let actualCut = CloudSnapshotCut(snapshotId: cut.snapshotId, at: cut.at, watermarks: watermarks)
      let receipt = try await bootstrapStaged(cut: actualCut, coverage: coverage.values.sorted { $0.sourceId < $1.sourceId })
      try store.execute("DELETE FROM metadata WHERE key=?", [Data("bootstrapInProgress".utf8)])
      try dropSetupStaging(cut.snapshotId)
      try releaseSettled()
      if !((try store.value("blocked") as Bool?) ?? false) { CloudSyncDiagnostics.shared.succeeded() }
      return receipt
    } catch { throw try await recordFailure(error, "first saved copy") }
  }
  public func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt {
    try await admit(bootstrap: true, waiting: true)
    setupUploadsDeferred = false
    defer { endBusy(); scheduleSend() }
    do {
      guard let first = snapshots.first else { throw CloudFailure.invalidRequest }
      try beginBootstrap(first.cut.snapshotId)
      let receipt = try await bootstrapOwned(snapshots)
      try store.execute("DELETE FROM metadata WHERE key=?", [Data("bootstrapInProgress".utf8)])
      try dropSetupStaging(first.cut.snapshotId)
      try releaseSettled()
      return receipt
    }
    catch { throw try await recordFailure(error, "first saved copy") }
  }
  /// Contract addition, lane A's wiring only: give up a first setup that never published, so a NEW snapshot id
  /// may be used. Keeps the queue, the records, retained files and receipts (records of the old cut stay queued
  /// and send as ordinary records later; adapters keep stable record ids). Allowed in every state (round 6 S7a).
  public func abandonUnpublishedSetup() async throws {
    try await admit(bootstrap: true)
    defer { endBusy(); scheduleSend() }
    guard let cut: String = try store.value("bootstrapInProgress") else { return }
    // Round 6 S7a: allowed in every state, also after THIS Mac published and its own import then failed (with a
    // cut that cannot be replayed it would be stuck). Nothing is lost: the queue and receipts stay, and the Mac
    // joins the account's inventory (its own, if it published one) through the normal pull.
    try store.transaction {
      try store.execute("DELETE FROM metadata WHERE key=?", [Data(("setupPublished:" + cut).utf8)])
      try store.execute("DELETE FROM metadata WHERE key=?", [Data("bootstrapInProgress".utf8)])
      try store.execute("DELETE FROM metadata WHERE key=?", [Data(("bootstrapMissingFiles:" + cut).utf8)])
      // S8: the abandoned cut's unlinked-file notes leave coverage with it.
      for (key, _) in try store.prefixed("unattributedProtectedFiles:snapshot-page:" + cut) + store.prefixed("unattributedProtectedFiles:snapshot:" + cut) {
        try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)])
      }
    }
  }
  /// What makes a setup page "the same page" on replay: the cut, its records, the REFERENCES of its files
  /// (id, hashes, size, class, purpose, epoch, source; not their local paths or bytes), its coverage numbers
  /// and its associations. A changed cut, record, file or coverage number is refused (idReused).
  private struct ReplayFile: Encodable { let reference: CloudBlobRef; let sourceId: String }
  private struct ReplayPage: Encodable {
    let cut: CloudSnapshotCut; let operations: [CloudOperation]; let files: [ReplayFile]
    let coverage: [CloudCoverage]; let associations: [CloudFileAssociation]
  }
  private static func replayDigest(_ page: CloudDomainSnapshot) throws -> String {
    CloudSyncBytes.hash(try CloudSyncCanonical.encode(ReplayPage(cut: page.cut, operations: page.operations,
      files: page.files.map { .init(reference: $0.reference, sourceId: $0.sourceId) }, coverage: page.coverage, associations: page.associations)))
  }
  // MARK: Staging bound and free-disk guard (setup pages, live files, inventory objects)

  /// Waits until `bytes` more sealed bytes fit: below the free-disk floor the setup pauses (reason in coverage)
  /// and resumes by itself; above the staging bound this cut's staged files are uploaded (and their bytes leave)
  /// first. A page larger than the bound, or staged bytes that cannot be uploaded now, stop the call with a reason.
  private func waitForRoom(_ bytes: Int64) async throws {
    guard bytes <= staging.maximumStagedBytes else {
      try store.set("stagingPaused", "A setup page is larger than the upload staging limit; the adapter must send smaller pages.")
      throw CloudFailure.invalidRequest
    }
    while true {
      if let free = staging.freeBytes(store.root), free < staging.minimumFreeBytes {
        let floor = Double(staging.minimumFreeBytes) / 1_073_741_824
        try store.set("stagingPaused", "Setup is paused: less than \(String(format: "%.0f", floor)) GB is free on this Mac. It continues by itself when space is free.")
        try await Task.sleep(for: staging.pauseInterval)
        continue
      }
      if try store.stagedBytes() + bytes <= staging.maximumStagedBytes { break }
      if let cut: String = try store.value("bootstrapInProgress") { try await uploadSetupFiles(cut) }
      try store.dropReceiptedBytes(except: keepBytes)
      if try store.stagedBytes() + bytes <= staging.maximumStagedBytes { break }
      try store.set("stagingPaused", "Uploads are waiting: files staged for upload fill this Mac's staging limit.")
      throw CloudFailure.unavailable
    }
    try store.execute("DELETE FROM metadata WHERE key=?", [Data("stagingPaused".utf8)])
  }
  /// Sends this cut's staged files that the cloud does not hold yet (saved-password files wait apart).
  private func uploadSetupFiles(_ cut: String) async throws {
    let refs = try store.rows("SELECT objects.descriptor FROM objects JOIN snapshot_files ON objects.blobId=snapshot_files.blobId WHERE snapshot_files.snapshotId=? AND length(objects.bytes)>0 AND (objects.receipt IS NULL OR length(objects.receipt)=0)",
      [Data(cut.utf8)]).map { try JSONDecoder().decode(CloudBlobRef.self, from: $0[0]) }
    guard !refs.isEmpty else { return }
    // Round 6 S7b: the gate is asked once per setup run, not once per page with files.
    if setupGateChecked != cut {
      let gate = try await transport.capabilities()
      guard gate.features.contains("cloud") else { throw CloudFailure.gateClosed }
      guard gate.storageEntitled == true else { throw CloudFailure.storageRequired }
      setupGateChecked = cut
    }
    try await sendObjects(refs.filter { $0.storageClass == .brain })
    do { try await sendObjects(refs.filter { $0.storageClass == .secrets }) }
    catch CloudFailure.secretsLocked { try noteWaitingProtectedFiles(refs) }
  }
  private func beginBootstrap(_ snapshot: String) throws {
    if let previous: String = try store.value("bootstrapInProgress"), previous != snapshot { throw CloudFailure.versionChanged }
    try store.set("bootstrapInProgress", snapshot)
  }
  private func bootstrapOwned(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt {
    guard let first = snapshots.first else { throw CloudFailure.invalidRequest }
    var watermarks = first.cut.watermarks, coverage: [String: CloudCoverage] = [:]
    let replay = try snapshots.map { try Self.replayDigest($0) }
    if let retained: [String] = try store.value("snapshot-replay:" + first.cut.snapshotId), retained != replay { throw CloudFailure.idReused }
    try store.set("snapshot-replay:" + first.cut.snapshotId, replay)
    for (pageIndex, snapshot) in snapshots.enumerated() {
      guard snapshot.cut.snapshotId == first.cut.snapshotId, snapshot.cut.at == first.cut.at else { throw CloudFailure.versionChanged }
      for (id, value) in snapshot.cut.watermarks {
        if let previous = watermarks[id], previous != value { throw CloudFailure.versionChanged }
        watermarks[id] = value
      }
      try Self.checkRecordSizes(snapshot.operations)
      try validateClasses(snapshot.operations)
      let files = snapshot.files
      let pageKey = "snapshot:\(first.cut.snapshotId):\(pageIndex)"
      if (try store.value("snapshot-page-stored:" + pageKey) as Bool?) != true { try await waitForRoom(files.reduce(Int64(0)) { $0 + $1.bytes }) }
      try store.transaction {
        if (try store.value("snapshot-page-stored:" + pageKey) as Bool?) == true { return }
        _ = try store.enqueue(snapshot.operations, files: files, associations: snapshot.associations, snapshotPage: pageKey)
        try store.set("snapshot-page-stored:" + pageKey, true)
        try store.retainSnapshot(first.cut.snapshotId, operations: snapshot.operations, keepBytes: false)
        for file in files { try store.execute("INSERT OR IGNORE INTO snapshot_files(snapshotId,blobId) VALUES (?,?)", [Data(first.cut.snapshotId.utf8), Data(file.blobId.utf8)]) }
      }
      try await uploadSetupFilesAsTheyArrive(first.cut.snapshotId)
      for item in snapshot.coverage { coverage[item.sourceId] = item }
    }
    try store.linkSnapshotFiles(first.cut.snapshotId)
    return try await bootstrapStaged(cut: .init(snapshotId: first.cut.snapshotId, at: first.cut.at, watermarks: watermarks), coverage: coverage.values.sorted { $0.sourceId < $1.sourceId })
  }
  private func bootstrapStaged(cut: CloudSnapshotCut, coverage: [CloudCoverage]) async throws -> CloudCheckpointReceipt {
    // The switch: no first upload. Setup ends once every page is stored on this Mac (beginFeedBaseline).
    if !firstUpload { return try await beginFeedBaseline(cut: cut, coverage: coverage) }
    let remote = try await transport.state()
    guard remote.capabilities.features.contains("cloud") else { throw CloudFailure.gateClosed }
    guard remote.capabilities.storageEntitled == true else { throw CloudFailure.storageRequired }
    // On a non-empty account catch up first: a file a record names may arrive with the feed.
    if remote.headSeq > .zero { _ = try await pullOwned() }
    let refs = try setupFileRefs(cut)
    try await sendObjects(refs.filter { $0.storageClass == .brain })
    do { try await sendObjects(refs.filter { $0.storageClass == .secrets }) }
    catch CloudFailure.secretsLocked {
      // A protected-only refusal must not hold the memory inventory; protected segments send it first.
      try noteWaitingProtectedFiles(refs)
    }
    if remote.headSeq > .zero { return try await importExistingBaseline(cut: cut, coverage: coverage) }
    return try await publishStagedInventory(cut: cut, coverage: coverage, staging: cut.snapshotId, through: .zero)
  }
  /// Every file the cut hands over AND every file its records name. All must be on this Mac before the setup can
  /// count those records as saved; a named file that is not here refuses the setup (a gap on its source).
  private func setupFileRefs(_ cut: CloudSnapshotCut) throws -> [CloudBlobRef] {
    var blobIds = Set(try store.rows("SELECT blobId FROM snapshot_files WHERE snapshotId=?", [Data(cut.snapshotId.utf8)]).map { String(decoding: $0[0], as: UTF8.self) })
    var sourceOf: [String: String] = [:]
    for row in try store.rows("SELECT DISTINCT outbox_files.blobId,snapshot_sources.sourceId FROM outbox_files JOIN snapshot_sources ON snapshot_sources.opId=outbox_files.opId WHERE snapshot_sources.snapshotId=?",
      [Data(cut.snapshotId.utf8)]) {
      let id = String(decoding: row[0], as: UTF8.self)
      blobIds.insert(id); sourceOf[id] = String(decoding: row[1], as: UTF8.self)
    }
    var refs: [CloudBlobRef] = [], missing: [String: [String]] = [:]
    for id in blobIds.sorted() {
      if let row = try store.rows("SELECT descriptor FROM objects WHERE blobId=?", [Data(id.utf8)]).first { refs.append(try JSONDecoder().decode(CloudBlobRef.self, from: row[0])) }
      else { missing[sourceOf[id] ?? "", default: []].append(id) }
    }
    guard missing.isEmpty else {
      // Reported as a gap on each record's source (coverage), until the file is handed over or setup is abandoned.
      try store.set("bootstrapMissingFiles:" + cut.snapshotId, missing)
      throw CloudFailure.invalidRequest
    }
    try store.execute("DELETE FROM metadata WHERE key=?", [Data(("bootstrapMissingFiles:" + cut.snapshotId).utf8)])
    return refs
  }

  // MARK: The baseline without a first upload: setup ends when its pages are stored; the upload resumes by itself

  /// This Mac's own baseline while it is still going up (key "feedBaseline"; its setup files under
  /// "feedBaselineFiles"). `lastRow` is the queue's last row when setup ended: the baseline is every memory
  /// record queued up to it.
  private struct FeedBaseline: Codable { let cut: String; let coverage: [CloudCoverage]; let lastRow: Int64; let total: Int }
  /// The switch `noFirstUploadInThisVersion`: setup ends WITHOUT a first upload, and as soon as every page is
  /// stored on this Mac. Its records were queued as ordinary records page by page; they go out as ordinary signed
  /// packs and every other Mac reads them from the feed. From here on nothing depends on the caller: the setup
  /// barrier ends (this Mac pulls and applies trusted devices' packs while its own baseline is still going up),
  /// and the upload continues by itself after a pause (a slow-down, no network) or a restart, through the
  /// ordinary send. Only when the baseline is in the Cloud does it settle (settleFeedBaselineIfSent).
  private func beginFeedBaseline(cut: CloudSnapshotCut, coverage: [CloudCoverage]) async throws -> CloudCheckpointReceipt {
    // The gate, asked once. "Not entitled" refuses the setup. No answer does not: every later request is judged
    // by the service anyway, and a setup must not depend on the network being there at this moment.
    do {
      let remote = try await transport.state()
      guard remote.capabilities.features.contains("cloud") else { throw CloudFailure.gateClosed }
      guard remote.capabilities.storageEntitled == true else { throw CloudFailure.storageRequired }
    }
    catch let failure as CloudFailure where failure == .gateClosed || failure == .storageRequired { throw failure }
    catch {}
    let files = try setupFileRefs(cut).map(\.blobId)
    let rows = try store.baselineRows(domains: brainDomains)
    try store.transaction {
      // A new setup over one still going up joins it: nothing of the earlier one is forgotten.
      let earlier: FeedBaseline? = try store.value("feedBaseline")
      let earlierFiles: [String] = try store.value("feedBaselineFiles") ?? []
      var joined = Dictionary((earlier?.coverage ?? []).map { ($0.sourceId, $0) }, uniquingKeysWith: { _, last in last })
      for item in coverage { joined[item.sourceId] = item }
      try store.set("feedBaseline", FeedBaseline(cut: cut.snapshotId, coverage: joined.values.sorted { $0.sourceId < $1.sourceId },
        lastRow: rows.last, total: rows.queued))
      try store.set("feedBaselineFiles", Array(Set(earlierFiles + files)).sorted())
      // Every page is stored: the setup barrier ends here.
      try store.execute("DELETE FROM metadata WHERE key=?", [Data("bootstrapInProgress".utf8)])
    }
    // A first go right away. If it cannot finish now, that is an ordinary sync failure (recorded, retried by
    // itself); the setup itself is done.
    do {
      // B (13 Nov, the joining MacBook): this Mac's own records go up FIRST. They are marked as its baseline and lose
      // to what Cloud already holds (rule J), so nothing needs the download first; before, a joining Mac's 56 records
      // waited behind its whole ~300-pack download (and for ever when that stalled).
      _ = try await flushOwned(); _ = try await pullOwned(pageLimit: Self.scheduledFeedPages, slice: Self.scheduledSlice); _ = try await flushOwned()
      try await budget.succeeded()
      try store.set("blocked", false)
    } catch { _ = try await recordFailure(error, "first saved copy (baseline)") }
    try await settleFeedBaselineIfSent()
    let through: CloudSequence = try store.value("brainSeq") ?? .zero
    return .init(checkpointId: "", throughSeq: through, verifiedBy: [], published: false)
  }
  /// The setup files of the baseline still going up that the Cloud does not hold yet.
  private func feedBaselineFilesWaiting() throws -> [CloudBlobRef] {
    let ids: [String] = try store.value("feedBaselineFiles") ?? []
    var refs: [CloudBlobRef] = []
    for id in ids {
      if let row = try store.rows("SELECT descriptor FROM objects WHERE blobId=? AND length(bytes)>0 AND (receipt IS NULL OR length(receipt)=0)", [Data(id.utf8)]).first {
        refs.append(try JSONDecoder().decode(CloudBlobRef.self, from: row[0]))
      }
    }
    return refs
  }
  /// Before its packs: the baseline's setup files go up (a file with no record of its own has no other way up).
  private func sendFeedBaselineFiles() async throws {
    let refs = try feedBaselineFilesWaiting()
    guard !refs.isEmpty else { return }
    try await sendObjects(refs.filter { $0.storageClass == .brain })
    do { try await sendObjects(refs.filter { $0.storageClass == .secrets }) }
    catch CloudFailure.secretsLocked { try noteWaitingProtectedFiles(refs) }
  }
  /// The baseline settles once it is in the Cloud: none of its memory records is queued any more and its memory
  /// files went up. What this Mac's setup stated about each source then becomes that source's published coverage
  /// on THIS Mac (no account-wide inventory states it), and this Mac is the one that corrects it later. Records
  /// the service keeps refusing are parked, not queued, and are reported on their source, as for any edit.
  private func settleFeedBaselineIfSent() async throws {
    guard let pending: FeedBaseline = try store.value("feedBaseline") else { return }
    // T4: an engine without memory kinds cannot tell what of the baseline is still queued ("nothing left" would be
    // true by definition): the baseline stays pending until memory is switched on again.
    guard !brainDomains.isEmpty, try store.baselineQueued(through: pending.lastRow, domains: brainDomains) == 0,
      try !feedBaselineFilesWaiting().contains(where: { $0.storageClass == .brain }) else { return }
    // T4: the settle and the coverage it publishes are one transaction, so a crash cannot leave one without the other.
    try store.transaction {
      try store.set("baseline", "feed")
      for item in pending.coverage { try store.set("coverage-owner:" + item.sourceId, true) }
      for item in pending.coverage { try setPublishedCoverage(item) }
      for key in ["feedBaseline", "feedBaselineFiles"] { try store.execute("DELETE FROM metadata WHERE key=?", [Data(key.utf8)]) }
    }
    try Self.dropFinishedSetupNotes(store)
    CloudSyncDiagnostics.shared.info("first copy sent: \(pending.total) records")
    try await refreshKnownCoverage()
  }
  /// E (13 Nov): a first copy's per-page notes (`snapshot-page:` and kin, 56,472 rows on the owner's Mac) only make
  /// a replay of an UNFINISHED setup exact. Once the first copy is complete they go: here, and once at launch for a
  /// store whose first copy completed under an earlier build. A replay after that re-stores pages idempotently.
  private static func dropFinishedSetupNotes(_ store: CloudSyncStore) throws {
    // The app's path (no first upload): the baseline went up through the feed.
    let settled = (try store.value("baseline") as String?) == "feed"
    guard (try store.value("bootstrapInProgress") as String?) == nil, settled else { return }
    for prefix in ["snapshot-page:", "snapshot-pages:", "snapshot-page-stored:", "snapshot-replay:"] {
      var upper = Array(prefix.utf8); upper[upper.count - 1] += 1
      try store.execute("DELETE FROM metadata WHERE key>=? AND key<?", [Data(prefix.utf8), Data(upper)])
    }
  }
  /// Why the baseline waits for a person (T4); these do not resume by themselves.
  /// A short "slow down" (429, or an old service's `budget_paused`); it ends by itself. 14 Nov: no daily allowance.
  public static let baselineRateReason = "Cloud asked this Mac to slow down for a moment. The upload goes on by itself in a few seconds."
  static let baselineSignInReason = "Sign in to Cloud again to finish the upload. It does not continue by itself."
  static let baselineRefusedReason = "The Cloud refused the upload. Press Try again on the Cloud page to send it again."
  static let baselinePausedReason = "Cloud sync is paused on this Mac. The upload continues when sync is switched on again."
  static let baselineMemoryOffReason = "Memory sync is switched off on this Mac. The upload continues when it is switched on again."
  static let baselineParkedReason = "Some records wait on this Mac: the Cloud refused them, or they wait behind one it refused. They are listed on their source."
  /// Contract addition: how far this Mac's own baseline has gone up; nil once it settled.
  public func baselineProgress() async throws -> CloudBaselineProgress? {
    if let preparing {
      return .init(total: max(preparing.total, preparing.done), sent: preparing.done, filesWaiting: 0, waitingUntil: nil, reason: nil, preparing: true)
    }
    guard let pending: FeedBaseline = try store.value("feedBaseline") else { return nil }
    // T4: with no memory kind in this engine the queue is counted over every kind but saved passwords; records
    // parked on the send side are not "sent".
    let left = try brainDomains.isEmpty ? store.baselineQueued(through: pending.lastRow, excluding: secretsDomains)
      : store.baselineQueued(through: pending.lastRow, domains: brainDomains)
    let parked = try store.baselineParked(through: pending.lastRow, excluding: secretsDomains)
    let files = try feedBaselineFilesWaiting().count
    let state = try await budget.status(), now = CloudSyncBytes.now()
    let stopped: Int64 = try store.value("sendStoppedUntil") ?? 0
    let paused: Bool = try store.value("paused") ?? false
    var waitingUntil: Int64? = nil, reason: String? = nil
    if state.blocked == "rate" {
      waitingUntil = state.retryAt > now ? state.retryAt : nil
      reason = Self.baselineRateReason
    } else if state.blocked == "auth" {
      reason = Self.baselineSignInReason
    } else if state.blocked == "remote" {
      reason = Self.baselineRefusedReason
    } else if paused {
      reason = Self.baselinePausedReason
    } else if brainDomains.isEmpty {
      reason = Self.baselineMemoryOffReason
    } else if stopped > now {
      waitingUntil = stopped
      reason = try store.value("sendStopped")
    } else if state.blocked != nil || state.retryAt > now {
      waitingUntil = state.retryAt > now ? state.retryAt : nil
      reason = "The Cloud did not answer. The upload is retried by itself."
    } else if parked > 0 {
      reason = Self.baselineParkedReason
    }
    return .init(total: pending.total, sent: max(0, pending.total - left - parked), filesWaiting: files, waitingUntil: waitingUntil, reason: reason)
  }
  private func publishStagedInventory(cut: CloudSnapshotCut, coverage: [CloudCoverage], staging: String, through: CloudSequence) async throws -> CloudCheckpointReceipt {
    guard try store.rows("SELECT opId FROM parked_ops WHERE conflict=1 LIMIT 1").isEmpty else {
      try store.set("publishBlocked", "Setup cannot publish this Mac's inventory while a record conflicts with another device's record of the same id.")
      throw CloudFailure.idReused
    }
    // Device trust: this Mac never builds on material it is holding. An inventory "through" a position would
    // cover packs this Mac never opened, so nothing is published while any pack waits (same guard as a conflict).
    guard try store.heldRows().isEmpty else {
      try store.set("publishBlocked", "Setup cannot publish this Mac's inventory while changes from a device that is not trusted on this Mac are waiting.")
      throw CloudFailure.unavailable
    }
    try store.execute("DELETE FROM metadata WHERE key=?", [Data("publishBlocked".utf8)])
    inventoryObjects = []
    let covered = through == .zero ? CloudSequence(1) : through
    var domains: [CloudSyncManifestDomain] = [], recordCount = 0, byteCount: Int64 = 2
    let names = try store.rows("SELECT DISTINCT domain FROM snapshot_records WHERE snapshotId=? ORDER BY domain", [Data(staging.utf8)]).map { String(decoding: $0[0], as: UTF8.self) }
    for domain in names where brainDomains.contains(domain) {
      let summary = try store.snapshotSummary(staging, domain: domain)
      if recordCount > 0 && summary.records > 0 { byteCount += 1 }
      recordCount += summary.records; byteCount += summary.bytes - 2
      domains.append(try await writeStagedDomain(domain: domain, cut: cut, staging: staging, through: covered))
    }
    let counts = CloudCounts(domains: domains.count, records: recordCount, files: 0, bytes: byteCount, blocked: coverage.filter { !$0.complete }.count)
    let manifest = CloudSyncManifest(v: 1, throughSeq: covered, createdAt: cut.at, sourceSnapshotId: cut.snapshotId,
      domains: domains, pathMaps: [], sourceCoverage: try coverage.filter { item in
        // A source with no known domain is left out of the brain manifest, never defaulted into it.
        let domain: String? = try store.value("coverage-domain:" + item.sourceId)
        return domain.map { brainDomains.contains($0) } ?? false
      }.map { .init(sourceId: $0.sourceId, complete: $0.complete, items: $0.items,
        bytes: $0.bytes, blockedReasons: $0.blockedReasons, cutoff: cut.watermarks[$0.sourceId],
        exclusions: $0.exclusions.isEmpty ? nil : $0.exclusions) }, counts: counts)
    let bytes = try CloudSyncCanonical.encode(manifest)
    let digest = CloudSyncBytes.hash(bytes)
    let key = "inventory:" + cut.snapshotId + ":" + through.rawValue
    let root = try await persistObject(bytes, key: key + ":root")
    let objectsToSend = inventoryObjects
    inventoryObjects = []
    try await sendObjects(objectsToSend)
    let request: CloudCheckpointRequest
    // A saved request is replayed only for exactly these manifest bytes; changed content is a new request.
    let requestKey = key + ":request:" + digest
    if let saved: CloudCheckpointRequest = try store.value(requestKey), saved.root == root, saved.inventoryDigest == digest { request = saved }
    else {
      request = .init(checkpointId: UUID().uuidString.lowercased(), throughSeq: through, root: root, inventoryDigest: digest, counts: counts)
      try store.set(requestKey, request)
    }
    let receipt: CloudCheckpointReceipt
    do { receipt = try await transport.publishCheckpoint(request) }
    catch CloudFailure.remote(let detail) where detail.code == "baseline_changed" { return try await importExistingBaseline(cut: cut, coverage: coverage) }
    // An unguarded Worker answers a raced first inventory with 0; importCheckpoint replays the feed after it.
    let racedInitial = through == .zero && receipt.throughSeq == .zero
    try store.set("setupPublished:" + cut.snapshotId, true)
    // This Mac published these sources' coverage: it is the one that may later correct a gap in it (S3).
    for item in coverage { try store.set("coverage-owner:" + item.sourceId, true) }
    guard receipt.published, receipt.checkpointId == request.checkpointId, receipt.throughSeq == covered || racedInitial,
      let current = try await transport.checkpoint(), current.root == root, current.inventoryDigest == request.inventoryDigest else { throw CloudFailure.checksumMismatch }
    _ = try await importCheckpoint(current)
    // Its own import done, the publisher no longer needs the inventory's sealed bytes.
    let published = keepBytes
    keepBytes = []
    try store.dropReceiptedBytes(Array(published))
    // Setup is complete once its inventory is published and imported. A send or pull failing afterwards is an
    // ordinary sync failure (recorded, retried); it must not leave this Mac behind the setup barrier.
    do {
      _ = try await flushOwned(); _ = try await pullOwned()
      try await budget.succeeded(); try store.set("blocked", false)
    } catch { _ = try await recordFailure(error, "first saved copy (baseline)") }
    try await rememberCoverage(coverage)
    return receipt
  }
  private func importExistingBaseline(cut: CloudSnapshotCut, coverage: [CloudCoverage]) async throws -> CloudCheckpointReceipt {
    // Catch up and drain; repeat a few times if edits keep arriving meanwhile, then publish at the
    // drained head anyway. Edits that are still queued send normally once the inventory exists.
    var rounds = 0
    while true {
      _ = try await pullOwned(); _ = try await flushOwned(); _ = try await pullOwned()
      if let checkpoint = try await transport.checkpoint() {
        _ = try await importCheckpoint(checkpoint)
        // Round 5 S2: the inventory is imported, so setup is complete; a pull failing afterwards is an ordinary
        // sync failure and must not keep this Mac behind the setup barrier.
        do { _ = try await pullOwned() } catch { _ = try await recordFailure(error, "first saved copy (catch-up)") }
        try await rememberCoverage(coverage)
        return .init(checkpointId: checkpoint.checkpointId, throughSeq: checkpoint.throughSeq, verifiedBy: checkpoint.verifiedBy, published: true)
      }
      rounds += 1
      if rounds >= Self.baselineDrainRounds { break }
      if try store.pending(limit: 1, domains: brainDomains, sendable: true).isEmpty { break }
    }
    // Ordinary commits may predate the first inventory. Capture only operations verified through this head.
    let head: CloudSequence = try store.value("brainSeq") ?? .zero
    guard head > .zero else { throw CloudFailure.versionChanged }
    // The first inventory after feed-first commits describes the merged, verified projection,
    // rather than repeating the losing device's original local-only source counts.
    let inventory = try await currentInventory()
    var merged = Dictionary(coverage.map { ($0.sourceId, $0) }, uniquingKeysWith: { _, last in last })
    for source in inventory.values where brainDomains.contains(source.domain) {
      merged[source.sourceId] = .init(sourceId: source.sourceId, inventoryRow: source.inventoryRow, complete: source.complete,
        items: source.items, bytes: source.bytes, blockedReasons: source.blockedReasons)
    }
    let staging = "verified:" + cut.snapshotId + ":" + head.rawValue
    try store.stageVerifiedInventory(staging)
    return try await publishStagedInventory(cut: cut, coverage: merged.values.sorted { $0.sourceId < $1.sourceId }, staging: staging, through: head)
  }
  static let baselineDrainRounds = 3
  static let repairableFinalizeCodes: Set<String> = ["code_expired", "checksum_mismatch"]
  static let protectedFinalizeCodes: Set<String> = ["secrets_locked", "rotation_required"]
  private struct StagedNode { let ref: CloudBlobRef; let after: Int64; let through: Int64 }
  private func writeStagedDomain(domain: String, cut: CloudSnapshotCut, staging: String, through: CloudSequence) async throws -> CloudSyncManifestDomain {
    var nodes: [StagedNode] = [], batch: [CloudOperation] = [], cursor: Int64 = 0, start: Int64 = 0
    // Staged rows are each record's canonical bytes, so a leaf's size is 2 + sum + (n - 1): a running
    // total replaces re-encoding the whole leaf for every record added. Each leaf is encoded once.
    var batchBytes = 2
    func leaf(_ batch: [CloudOperation], expected: Int) throws -> Data {
      let plain = try CloudSyncPack.encode(batch)
      guard plain.count == expected, plain.count <= maximumPackBytes else { throw CloudFailure.unsupportedFormat }
      return plain
    }
    while true {
      let page = try store.snapshotRows(staging, domain: domain, after: cursor)
      if page.isEmpty { break }
      for (index, bytes) in page {
        let operation = try JSONDecoder().decode(CloudOperation.self, from: bytes)
        // An inventory carries full records only: a skeleton (content released after settling) must never be
        // published as if it were the record. Without the content the inventory is not built.
        guard CloudSyncBytes.hash(try CloudSyncCanonical.encode(operation.payload)) == operation.payloadHash else {
          try store.set("publishBlocked", "An inventory cannot be built here: some records' content is no longer on this Mac.")
          throw CloudFailure.unavailable
        }
        if !batch.isEmpty && batchBytes + 1 + bytes.count > maximumPackBytes {
          let ref = try await persistObject(leaf(batch, expected: batchBytes), key: "inventory:\(staging):\(through.rawValue):\(domain):leaf:\(nodes.count)")
          nodes.append(.init(ref: ref, after: start, through: cursor)); start = cursor; batch = []; batchBytes = 2
        }
        guard 2 + bytes.count <= maximumPackBytes else { throw CloudFailure.unsupportedFormat }
        batchBytes += bytes.count + (batch.isEmpty ? 0 : 1)
        batch.append(operation); cursor = index
      }
    }
    if !batch.isEmpty {
      let ref = try await persistObject(leaf(batch, expected: batchBytes), key: "inventory:\(staging):\(through.rawValue):\(domain):leaf:\(nodes.count)")
      nodes.append(.init(ref: ref, after: start, through: cursor))
    }
    var level = 0
    while nodes.count > 16 {
      var parents: [StagedNode] = []
      for index in stride(from: 0, to: nodes.count, by: 16) {
        let children = Array(nodes[index..<min(index + 16, nodes.count)])
        let after = children[0].after, end = children[children.count - 1].through
        let summary = try store.snapshotSummary(staging, domain: domain, after: after, through: end)
        let nested = CloudSyncManifest(v: 1, throughSeq: through, createdAt: cut.at, sourceSnapshotId: cut.snapshotId,
          domains: [.init(domain: domain, records: summary.records, children: children.map(\.ref), digest: summary.digest)], pathMaps: [], sourceCoverage: [],
          counts: .init(domains: 1, records: summary.records, files: 0, bytes: summary.bytes, blocked: 0))
        let ref = try await persistObject(CloudSyncCanonical.encode(nested), key: "inventory:\(staging):\(through.rawValue):\(domain):node:\(level):\(parents.count)")
        parents.append(.init(ref: ref, after: after, through: end))
      }
      nodes = parents; level += 1
    }
    let summary = try store.snapshotSummary(staging, domain: domain)
    return .init(domain: domain, records: summary.records, children: nodes.map(\.ref), digest: summary.digest)
  }
  private func stageTree(_ ref: CloudBlobRef, preloaded: Data, domain: String, snapshotId: String, through: CloudSequence,
                         staging: String, visited: inout Set<String>, depth: Int = 0) async throws {
    guard depth < 64, visited.insert(ref.blobId).inserted else { throw CloudFailure.invalidRequest }
    let bytes = preloaded
    guard let raw = OrderedJSON.parse(bytes) else { throw CloudFailure.invalidRequest }
    if raw.array != nil {
      let operations = try CloudSyncPack.decode(bytes)
      guard operations.allSatisfy({ $0.domain == domain }) else { throw CloudFailure.checksumMismatch }
      for operation in operations {
        guard try store.rows("SELECT opId FROM snapshot_records WHERE snapshotId=? AND opId=?", [Data(staging.utf8), Data(operation.opId.utf8)]).isEmpty else { throw CloudFailure.idReused }
      }
      try store.retainSnapshot(staging, operations: operations)
      return
    }
    let manifest = try decodeManifest(bytes)
    guard manifest.throughSeq == through, manifest.sourceSnapshotId == snapshotId, manifest.domains.count == 1,
      manifest.domains[0].domain == domain, manifest.sourceCoverage.isEmpty, manifest.counts.blocked == 0,
      manifest.counts.domains == 1 else { throw CloudFailure.unsupportedFormat }
    let node = manifest.domains[0]
    guard (1...16).contains(node.children.count) else { throw CloudFailure.unsupportedFormat }
    let before = try store.rows("SELECT coalesce(max(rowid),0) FROM snapshot_records WHERE snapshotId=?", [Data(staging.utf8)])
    let start = Int64(String(decoding: before[0][0], as: UTF8.self)) ?? 0
    let childBytes = try await readObjects(node.children)
    for (child, plain) in zip(node.children, childBytes) { try await stageTree(child, preloaded: plain, domain: domain, snapshotId: snapshotId, through: through,
      staging: staging, visited: &visited, depth: depth + 1) }
    let summary = try store.snapshotSummary(staging, domain: domain, after: start)
    guard summary.records == node.records, summary.records == manifest.counts.records, summary.bytes == manifest.counts.bytes,
      summary.digest == node.digest else { throw CloudFailure.checksumMismatch }
  }
  private func decodeManifest(_ bytes: Data) throws -> CloudSyncManifest {
    let manifest = try CloudWire.decode(CloudSyncManifest.self, from: bytes,
      allowedKeys: ["v", "throughSeq", "createdAt", "sourceSnapshotId", "domains", "pathMaps", "sourceCoverage", "counts"], maximumBytes: CloudWire.maximumPlainChunkBytes)
    guard manifest.v == 1, manifest.pathMaps.isEmpty, manifest.counts.files == 0,
      manifest.counts.records >= 0, manifest.counts.bytes >= 0, manifest.counts.blocked >= 0,
      manifest.sourceCoverage.allSatisfy({ $0.items >= 0 && $0.bytes >= 0 }) else { throw CloudFailure.unsupportedFormat }
    return manifest
  }
  private func importCheckpoint(_ checkpoint: CloudCheckpoint) async throws -> [CloudImportReceipt] {
    if try store.checkpointApplied(id: checkpoint.checkpointId, seq: checkpoint.throughSeq, digest: checkpoint.inventoryDigest) { return [] }
    let identityKey = "checkpoint-identity:" + checkpoint.checkpointId
    if let old: CloudCheckpoint = try store.value(identityKey) {
      // verifiedBy may grow as other devices finish; all immutable checkpoint content must agree.
      guard old.root == checkpoint.root, old.secretsRoot == checkpoint.secretsRoot, old.throughSeq == checkpoint.throughSeq,
        old.inventoryDigest == checkpoint.inventoryDigest, old.counts == checkpoint.counts else { throw CloudFailure.idReused }
    } else { try store.set(identityKey, checkpoint) }
    let bytes = try await readObject(checkpoint.root)
    guard CloudSyncBytes.hash(bytes) == checkpoint.inventoryDigest else { throw CloudFailure.checksumMismatch }
    let manifest = try decodeManifest(bytes)
    // A Worker without the atomic zero-head guard records a raced first inventory at 0 while its
    // manifest names the reserved slot 1. Such an inventory covers no feed entry: import it at 0
    // and replay the whole feed after it, so neither racing device's data is skipped or rejected.
    let racedInitial = checkpoint.throughSeq == .zero && manifest.throughSeq == CloudSequence(1)
    guard manifest.throughSeq == checkpoint.throughSeq || racedInitial, manifest.counts == checkpoint.counts else { throw CloudFailure.unsupportedFormat }
    let staging = "import:" + checkpoint.checkpointId
    try store.transaction {
      for table in ["snapshot_records", "snapshot_entities", "snapshot_links"] {
        try store.execute("DELETE FROM " + table + " WHERE snapshotId=?", [Data(staging.utf8)])
      }
    }
    var visited: Set<String> = [checkpoint.root.blobId], records = 0
    var totalBytes: Int64 = 2
    guard Set(manifest.domains.map(\.domain)).count == manifest.domains.count else { throw CloudFailure.invalidRequest }
    // Fully validate the graph and stage all leaf rows before asking any domain writer to apply.
    for domain in manifest.domains {
      guard brainDomains.contains(domain.domain), domain.children.count <= 16 else { throw CloudFailure.unsupportedFormat }
      let childBytes = try await readObjects(domain.children)
      for (ref, plain) in zip(domain.children, childBytes) { try await stageTree(ref, preloaded: plain, domain: domain.domain, snapshotId: manifest.sourceSnapshotId,
        through: manifest.throughSeq, staging: staging, visited: &visited) }
      let summary = try store.snapshotSummary(staging, domain: domain.domain)
      guard summary.records == domain.records, summary.digest == domain.digest else { throw CloudFailure.checksumMismatch }
      if records > 0 && summary.records > 0 { totalBytes += 1 }
      records += summary.records; totalBytes += summary.bytes - 2
    }
    guard totalBytes == checkpoint.counts.bytes, manifest.domains.count == checkpoint.counts.domains, records == checkpoint.counts.records,
      checkpoint.counts.files == 0 else { throw CloudFailure.checksumMismatch }
    try store.set("pendingCheckpoint", checkpoint)
    // Round 6 S3: page by page. Each page is prepared (its files fetched once, within the staging bound and the
    // free-disk floor), applied and released before the next page is read; the journal survives interruption.
    // The whole inventory graph was validated above, before any page is applied.
    var planIndex = 0
    var receipts: [CloudImportReceipt] = []
    for domain in manifest.domains {
      guard let adapter = adapters[domain.domain] else { throw CloudFailure.unsupportedFormat }
      var cursor: Int64 = 0
      while true {
        let page = try store.snapshotRows(staging, domain: domain.domain, after: cursor)
        if page.isEmpty { break }
        let key = checkpoint.checkpointId + ":page:" + String(planIndex)
        planIndex += 1; cursor = page.last!.0
        let completedKey = "checkpoint-page-applied:" + key
        if let saved: CloudImportReceipt = try store.value(completedKey) { receipts.append(saved); continue }
        let operations = try page.map { try JSONDecoder().decode(CloudOperation.self, from: $0.1) }
        let origin = CloudImportOrigin(deviceId: "checkpoint", sequence: checkpoint.throughSeq)
        let journal: CloudSyncJournal
        if let row = try store.rows("SELECT bytes FROM prepare_journal WHERE segmentId=?", [Data(key.utf8)]).first {
          journal = try JSONDecoder().decode(CloudSyncJournal.self, from: row[0])
          guard Set(journal.prepared.flatMap(\.operations).map(\.opId)) == Set(operations.map(\.opId)), journal.digest == checkpoint.inventoryDigest else { throw CloudFailure.idReused }
        } else {
          // A page touching a parked record, or one an adapter or the identity check refuses, is applied
          // record by record (poison records are parked); the marker preparation says so durably.
          let parked = try await parkedIndex()
          // Own records whose files already left this Mac (the publisher's own inventory) are not handed back.
          let own = try operations.filter { try ownWithDroppedFile($0) }
          let ownIds = Set(own.map(\.opId))
          let forAdapter = operations.filter { !ownIds.contains($0.opId) }
          var prepared: CloudPreparedImport? = nil
          if !forAdapter.isEmpty, !forAdapter.contains(where: { parked.blocks($0) != nil }) {
            do {
              do { try store.checkIdentity(forAdapter, snapshot: staging) }
              catch let failure as CloudFailure where failure == .idReused || failure == .invalidRequest { throw CloudSyncIdentityRefused() }
              let files = try await incomingFiles(forAdapter)
              let plan = try await adapter.validateIncoming(forAdapter, files: files)
              guard plan.operations == forAdapter, plan.files == files else { throw CloudFailure.checksumMismatch }
              prepared = plan
            } catch let error where Self.isRecordRefusal(error) {}
          }
          journal = .init(id: key, seq: checkpoint.throughSeq, digest: checkpoint.inventoryDigest, origin: origin,
            prepared: [prepared ?? .init(preparationId: Self.individualPreparation, operations: forAdapter, files: [])] +
              (own.isEmpty ? [] : [.init(preparationId: Self.ownPreparation, operations: own, files: [])]), domains: [domain.domain])
          try store.stage(key, journal)
        }
        guard let plan = journal.prepared.first else { throw CloudFailure.unsupportedFormat }
        var pageReceipt: CloudImportReceipt? = nil, conflicts = Set<String>()
        if plan.preparationId != Self.individualPreparation {
          do {
            for file in plan.files { _ = try await sealedFile(file.reference, sourceId: file.sourceId) }
            let whole = try await adapter.applyPrepared(plan, origin: journal.origin)
            try fault(.duringApply)
            guard whole.preparationId == plan.preparationId, whole.results.map(\.entityId).sorted() == plan.operations.map(\.entityId).sorted() else { throw CloudFailure.unavailable }
            if whole.results.contains(where: { $0.status == .blocked }) || whole.counts.blocked > 0 { throw CloudSyncItemsBlocked(reason: "") }
            let verification = try await adapter.verify(whole)
            guard verification.verified, verification.counts == whole.counts, verification.counts.blocked == 0 else { throw CloudFailure.checksumMismatch }
            pageReceipt = whole
          } catch let error where Self.isRecordRefusal(error) {}
        }
        if pageReceipt == nil {
          let (applied, parkedConflicts) = try await applyIndividually(plan.operations, origin: journal.origin, journalPrefix: key)
          conflicts = parkedConflicts
          pageReceipt = .init(preparationId: Self.individualPreparation, inventoryRow: applied.first?.inventoryRow ?? "", results: applied.flatMap(\.results),
            counts: .init(domains: 1, records: applied.count, files: 0, bytes: 0, blocked: plan.operations.count - applied.count))
        }
        guard let receipt = pageReceipt else { throw CloudFailure.unavailable }
        let pageOperations = plan.operations + (journal.prepared.first(where: { $0.preparationId == Self.ownPreparation })?.operations ?? [])
        try store.transaction {
          try store.remember(pageOperations.filter { !conflicts.contains($0.opId) })
          for operation in pageOperations where !conflicts.contains(operation.opId) {
            try store.execute("INSERT OR IGNORE INTO verified_ops(opId) VALUES (?)", [Data(operation.opId.utf8)])
            try store.execute("UPDATE outbox SET state='acknowledged' WHERE opId=?", [Data(operation.opId.utf8)])
            // From an inventory: in Cloud as of its covered sequence; the original commit time is not carried.
            try store.recordReceipt(operation.opId, seq: checkpoint.throughSeq, committedAt: nil)
          }
          try store.set(completedKey, receipt)
        }
        try releaseAfterApply()
        receipts.append(receipt)
      }
    }
    let verified = try await transport.verifyCheckpoint(id: checkpoint.checkpointId, inventoryDigest: checkpoint.inventoryDigest, counts: checkpoint.counts)
    guard verified.contains(deviceId) else { throw CloudFailure.checksumMismatch }
    try store.transaction {
      try store.execute("INSERT OR IGNORE INTO checkpoint_applied(checkpointId,seq,digest) VALUES (?,?,?)", [Data(checkpoint.checkpointId.utf8), Data(checkpoint.throughSeq.rawValue.utf8), Data(checkpoint.inventoryDigest.utf8)])
      let previous: CloudSequence = try store.value("brainSeq") ?? .zero
      try store.set("brainSeq", max(previous, checkpoint.throughSeq))
      for index in 0..<planIndex {
        try store.execute("DELETE FROM prepare_journal WHERE segmentId=?", [Data((checkpoint.checkpointId + ":page:" + String(index)).utf8)])
      }
      try store.set("checkpointId", checkpoint.checkpointId)
      try store.set("inventoryVerified", true)
      // The inventory's maker: the first device in verifiedBy (the service records its creator first).
      if let maker = checkpoint.verifiedBy.first { try store.set("inventoryMaker", maker) }
      let knownHead: CloudSequence = try store.value("headSeq") ?? .zero
      try store.set("headSeq", max(knownHead, checkpoint.throughSeq))
      for source in manifest.sourceCoverage {
        let old: CloudCoverage? = try store.value("coverage:" + source.sourceId)
        try setPublishedCoverage(CloudCoverage(sourceId: source.sourceId, inventoryRow: old?.inventoryRow ?? "",
          complete: source.complete, items: source.items, bytes: source.bytes, blockedReasons: source.blockedReasons, exclusions: source.exclusions ?? []))
      }
      try store.execute("DELETE FROM metadata WHERE key=?", [Data("pendingCheckpoint".utf8)])
    }
    // The imported inventory's staging rows held downloaded content until it was applied; now they go.
    try store.dropStaging(staging)
    try await refreshKnownCoverage()
    return receipts
  }
  /// A owns lifecycle/watcher wiring. No polling; hello and changed trigger durable-cursor catch-up.
  /// Network returned or the Mac woke (round 5 S4): catch up, and restart the event stream if it had ended.
  private func wakeFromNetwork() {
    guard automatic else { return }
    pullRequested = true; sendRequested = true
    if pump == nil { startEvents() }
    scheduleSend()
  }
  public func startEvents() {
    let starting = !automatic
    automatic = true
    // MAC-NEXT-5: at launch what is queued goes by itself, whether or not the event stream ever says "hello".
    if starting { pullRequested = true; sendRequested = true; scheduleSend() }
    guard pump == nil else { return }
    pump = Task {
      if let wake = transport as? any CloudSyncWakePort { await wake.onWake { [weak self] in await self?.wakeFromNetwork() } }
      do {
        for try await event in await transport.events() {
          if Task.isCancelled { break }
          if event.type == "gate" { try await setPaused(true); break }
          eventsRetryStreak = 0
          if ["hello", "changed"].contains(event.type) { pullRequested = true; sendRequested = true; scheduleSend() }
        }
      } catch {
        // A: an event stream that failed is blocked only with a timer that reconnects it.
        try? store.set("blocked", true)
        pump = nil
        reconnectEvents()
        return
      }
      pump = nil
    }
  }
  /// A failed event stream reconnects after 2 s doubling to 60 s (reset by the next event), and catches up then.
  private var eventsRetryStreak = 0
  private var reconnectTask: Task<Void, Never>?
  private func reconnectEvents() {
    guard automatic, reconnectTask == nil else { return }
    let delay = min(60_000, Int64(2_000) << Int64(min(eventsRetryStreak, 5)))
    eventsRetryStreak += 1
    reconnectTask = Task {
      do { try await transport.backoff(milliseconds: delay) } catch { reconnectTask = nil; return }
      reconnectTask = nil
      guard automatic, pump == nil else { return }
      pullRequested = true; sendRequested = true
      startEvents()
      scheduleSend()
    }
  }
  public func stop() async {
    automatic = false; reconnectTask?.cancel(); reconnectTask = nil
    wakeTask?.cancel(); wakeTask = nil; retryTask?.cancel(); retryTask = nil; sendTask?.cancel(); sendTask = nil; pump?.cancel(); pump = nil
    await transport.stop()
  }
}
