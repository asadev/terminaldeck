import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

/// Test-only fault switch: throws at the n-th hit of one kill point, once.
final class CloudSyncRound3Trip: @unchecked Sendable {
  private let lock = NSLock()
  private let point: CloudSyncKillPoint
  private let at: Int
  private var hits = 0
  init(_ point: CloudSyncKillPoint, at: Int) { self.point = point; self.at = at }
  func check(_ value: CloudSyncKillPoint) throws {
    lock.lock(); defer { lock.unlock() }
    guard value == point else { return }
    hits += 1
    if hits == at { throw CloudFailure.unavailable }
  }
}

// Review round 3 regressions. Fixture-only data; no real account, Keychain or network.
extension CloudSyncTests {
  /// Finding 1: the first inventory's root upload fails, the live source counts change with no
  /// operation behind them, and setup is retried at the same feed position. The published inventory
  /// must still match its digest so the publisher and a fresh reader can import it.
  func testRound3RetriedInventoryWithChangedCountsNeverPairsOldRootWithNewDigest() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    _ = try await server.commit(reviewBrainSegment([op(entity: "feed-first")]))
    // Upload 1 is the single inventory leaf; upload 2 is the root.
    let trip = CloudSyncRound3Trip(.afterUpload, at: 2)
    let (client, store, adapter) = try await engine(root: root, server: server, fault: { try trip.check($0) })
    let cut = snapshot([try op(entity: "local-cut")])
    do { _ = try await client.bootstrap([cut]); XCTFail("Root upload interruption missed") }
    catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let none = try await server.checkpoint()
    XCTAssertNil(none)
    await adapter.addLocalRowWithoutOperation(try op(entity: "tidy-up-only"))
    let receipt = try await client.bootstrap([cut])
    XCTAssertTrue(receipt.published)
    XCTAssertEqual(try store.value("inventoryVerified"), true)
    let published = try await server.checkpoint()
    let checkpoint = try XCTUnwrap(published)
    let refs = try await server.readBlobs(ids: [checkpoint.root.blobId])
    let sealed = try await server.download(try XCTUnwrap(refs.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    let manifest = try await makeContent().open(CloudWire.decode(CloudContentEnvelope.self, from: sealed))
    XCTAssertEqual(CloudSyncBytes.hash(manifest), checkpoint.inventoryDigest)
    XCTAssertEqual(OrderedJSON.parse(manifest)?["sourceCoverage"]?.array?.first?["items"]?.number, 3)
    let (reader, restored, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertEqual(try restored.value("inventoryVerified"), true)
    XCTAssertEqual(try restored.operations().count, 2)
  }
}

extension CloudSyncTests {
  func round3ProtectedHTTPClient(_ root: URL, server: CloudSyncFixtureServer, protected: CloudSyncProtectedFixtureContent) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncBudget) {
    let store = try makeStore(root), budget = CloudSyncBudget(store: store)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFullHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    let signer: CloudSyncSigner = { CloudSyncBytes.base64(try CloudSyncFixtureAuth.key.signature(for: $0).rawRepresentation) }
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: signer, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration))
    let client = try CloudSyncEngine(store: store, transport: transport, objects: transport, content: makeContent(), budget: budget,
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], secretsDomains: ["api-key"], secretsContent: protected,
      signer: signer, verifySignature: { _, _ in }, firstUpload: true)
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory"), acceptsFiles: true))
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("protected"), domain: "api-key"))
    return (client, store, budget)
  }
  func round3ProtectedFile(_ protected: CloudSyncProtectedFixtureContent) async throws -> CloudLocalBlob {
    let id = UUID().uuidString.lowercased()
    let envelope = try await protected.seal(Data("fixture-only sealed file".utf8), blobId: id, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
    let sealed = try CloudSyncCanonical.encode(envelope), ref = CloudSyncBytes.blob(sealed, envelope: envelope)
    let path = try scratch().appendingPathComponent(id)
    try sealed.write(to: path)
    return .init(blobId: id, sourceId: "fixture-source", localURL: path, bytes: ref.bytes, sha256: ref.sha256, md5: ref.md5,
      keyEpoch: 1, storageClass: .secrets, purpose: .secret)
  }

  /// Finding 2: the Worker refuses protected writes with HTTP 403/409 at prepare, at the upload itself
  /// and at commit. Each refusal leaves only the saved-password edit queued; memory sends and no
  /// account-wide block or failure is recorded.
  func testRound3ProtectedHTTPRefusalsAtEveryWriteStepLeaveMemorySyncing() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let routes: [(String, Int, String)] = [("POST /v1/blobs/prepare", 403, "secrets_locked"), ("PUT /v1/transfers/staging", 403, "secrets_locked"),
      ("POST /v1/changes", 409, "rotation_required")]
    for (route, status, code) in routes {
      let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
      CloudSyncFullHTTP.registry.set(server)
      let (client, store, budget) = try await round3ProtectedHTTPClient(scratch(), server: server, protected: protected)
      let secret = try await reviewProtectedOperation(protected), file = try await round3ProtectedFile(protected)
      _ = try await client.enqueue([secret], files: [file], associations: [CloudFileAssociation(operationId: secret.opId, blobIds: [file.blobId])])
      _ = try await client.enqueue([op(entity: "memory-\(code)")])
      await server.refuseHTTPOnce(route, status: status, code: code)
      _ = try await client.flush()
      let segments = await server.segmentCount()
      XCTAssertEqual(segments, 1, route)
      XCTAssertEqual(try store.queuedCount(), 1, route)
      XCTAssertEqual(try store.value("blocked"), false, route)
      let state = try await budget.status()
      XCTAssertNil(state.blocked, route)
      XCTAssertEqual(state.failures, 0, route)
      // Since 457d4dea the refused saved-password work waits for its not-before time (simulated as passed here).
      try store.set("protectedRetryAt", Int64(0))
      _ = try await client.flush()
      XCTAssertEqual(try store.queuedCount(), 0, route)
      await client.stop()
    }
  }

  /// Finding 2: the applied report is refused for the protected position; memory's position is still
  /// reported and nothing blocks.
  func testRound3ProtectedRefusalOfAppliedReportStillReportsMemory() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    CloudSyncFullHTTP.registry.set(server)
    let (client, store, budget) = try await round3ProtectedHTTPClient(scratch(), server: server, protected: protected)
    _ = try await client.enqueue([try await reviewProtectedOperation(protected)])
    _ = try await client.flush()
    let reportedSecrets: CloudSequence = try store.value("reportedSecretsSeq") ?? .zero
    _ = try await client.enqueue([op(entity: "memory-after")])
    try store.set("secretsSeq", CloudSequence(2))
    await server.refuseHTTPOnce("POST /v1/applied", status: 403, code: "secrets_locked")
    _ = try await client.flush()
    XCTAssertEqual(try store.value("reportedSeq"), CloudSequence(2))
    XCTAssertEqual(try store.value("reportedSecretsSeq") ?? .zero, reportedSecrets)
    let state = try await budget.status()
    XCTAssertNil(state.blocked)
    XCTAssertEqual(try store.value("blocked"), false)
    await client.stop()
  }

  /// Finding 3: against the Worker's saved answer per request id, a finalize `checksum_mismatch` is
  /// repaired by a fresh prepare (new ticket, new request) and is never answered by the saved refusal.
  func testRound3ChecksumRepairUsesAFreshRequestNotTheSavedRefusal() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    CloudSyncFullHTTP.registry.set(server)
    await server.replayAnswersByRequestId()
    let (client, store, budget) = try await reviewHTTPFileClient(scratch(), server: server)
    let (file, bytes) = try await sealedAttachment(root: scratch())
    _ = try await client.enqueue([referencing(file)], files: [file])
    await server.failFinalizationOnce(code: "checksum_mismatch", retryable: false)
    _ = try await client.flush()
    XCTAssertEqual(try store.queuedCount(), 0)
    let replays = await server.replayedAnswers
    XCTAssertEqual(replays, 0, "The repaired finalize must not be a repeat of the refused request")
    let state = try await budget.status()
    XCTAssertNil(state.blocked)
    let refs = try await server.readBlobs(ids: [file.blobId])
    let remote = try await server.download(try XCTUnwrap(refs.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    XCTAssertEqual(remote, bytes)
    await client.stop()
  }
}

extension CloudSyncTests {
  /// Finding 4, sequence A: a record with a file was queued before setup (sends held, file local only);
  /// the setup page repeats the record but not the file. The inventory must not count the record as
  /// saved before its file is in Cloud: a fresh reader imports both.
  func testRound4FirstInventoryUploadsEveryFileItsRecordsName() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, bytes) = try await sealedAttachment(root: scratch()), record = try referencing(file)
    let (publisher, _) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    _ = try await publisher.enqueue([record], files: [file])
    let receipt = try await publisher.bootstrap([snapshot([record])])
    XCTAssertTrue(receipt.published)
    let refs = try await server.readBlobs(ids: [file.blobId])
    let remote = try await server.download(try XCTUnwrap(refs.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    XCTAssertEqual(remote, bytes)
    let (reader, restored) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    _ = try await reader.pull()
    XCTAssertEqual(try restored.value("inventoryVerified"), true)
    // Round 5 item B: settled records keep their skeleton; the content went to the adapter.
    XCTAssertEqual(try restored.operations(), [CloudSyncStore.skeleton(record)])
  }

  /// Finding 4, sequence B: a record names a file that was never handed to this Mac. Nothing is published.
  func testRound4FirstInventoryRefusesARecordWhoseFileIsMissing() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, _) = try await sealedAttachment(root: scratch()), record = try referencing(file)
    let (publisher, store) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    let cut = snapshot([record])
    do { _ = try await publisher.bootstrap([cut]); XCTFail("Published a record whose file is not in Cloud") }
    catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    let published = try await server.checkpoint()
    XCTAssertNil(published)
    XCTAssertEqual(try store.value("bootstrapMissingFiles:" + cut.cut.snapshotId), ["fixture-source": [file.blobId]])
    // Round 4 S2: the reason is shown on the record's source as a gap.
    let coverage = try await publisher.coverage(sourceId: "fixture-source")
    XCTAssertFalse(coverage.complete)
    XCTAssertTrue(coverage.blockedReasons.contains { $0.hasPrefix("1 files named by records are not on this Mac") })
  }
}

extension CloudSyncTests {
  /// Finding 5: leaves are cut by a running byte total. The result must be exactly the greedy cut the
  /// old whole-pack re-encoding produced (same leaf count, every leaf within the limit) and restore fully.
  func testRound5RunningTotalCutsTheSameLeavesAsFullReEncoding() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), limit = 1024
    let rows = try (0..<60).map { try op(entity: "cut-\($0)", text: String(repeating: "x", count: 40 + ($0 * 37) % 160)) }
    let (sender, _, _) = try await engine(root: scratch(), server: server, packLimit: limit)
    _ = try await sender.bootstrap([snapshot(rows)])
    // Reference: the previous algorithm, in staging (rowid) order, which is the snapshot order here.
    var leaves = 0, batch: [CloudOperation] = []
    for row in rows {
      if try CloudSyncCanonical.encode(batch + [row]).count > limit { leaves += 1; batch = [] }
      batch.append(row)
    }
    if !batch.isEmpty { leaves += 1 }
    var nodes = 0, level = leaves
    while level > 16 { level = (level + 15) / 16; nodes += level }
    let objects = await server.objectCount()
    XCTAssertEqual(objects, leaves + nodes + 1, "leaves + tree nodes + root")
    let (reader, store, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertEqual(Set(try store.operations().map(\.opId)), Set(rows.map(\.opId)))
  }

  /// Round 4 S1 (decided): live packs group by domain; order is exact within a domain, none across domains.
  /// Alternating records of two domains make one pack per domain, not one pack per record.
  func testRound8aLivePacksGroupByDomainAndKeepOrderWithinADomain() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let store = try makeStore(root)
    let client = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory", "notes"],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in }, firstUpload: true)
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory")))
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("notes"), domain: "notes"))
    let first = try op(entity: "a1"), second = try op(entity: "b1"), third = try op(entity: "a2")
    let other = CloudOperation(v: 1, opId: second.opId, originDevice: second.originDevice, domain: "notes", entityId: second.entityId, revision: second.revision,
      parents: [], kind: second.kind, projectId: second.projectId, source: second.source, createdAt: second.createdAt, payload: second.payload, payloadHash: second.payloadHash)
    _ = try await client.enqueue([first]); _ = try await client.enqueue([other]); _ = try await client.enqueue([third])
    _ = try await client.flush()
    let feed = try await server.changes(after: .zero, limit: 64)
    XCTAssertEqual(feed.segments.map { $0.domains ?? [] }, [["memory"], ["notes"]])
    let segmentId = try XCTUnwrap(feed.segments.first?.segmentId)
    let stored = await server.disk.segments[segmentId]
    let pack = try XCTUnwrap(stored)
    let sealed = try CloudSyncBytes.unbase64(pack.ciphertext)
    let opened = try await makeContent().open(CloudWire.decode(CloudContentEnvelope.self, from: sealed))
    XCTAssertEqual(try CloudSyncPack.decode(opened).map(\.opId), [first.opId, third.opId])
  }
}

extension CloudSyncTests {
  /// Finding 6: applying many packs in one pull walks each source's inventory once, not once per pack.
  func testRound6OnePullRefreshesCoverageOnceNotPerPack() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    for index in 0..<10 { _ = try await server.commit(reviewBrainSegment([op(entity: "pack-\(index)")])) }
    let (reader, store, adapter) = try await engine(root: scratch(), server: server)
    let before = await adapter.inventoryCalls
    _ = try await reader.pull()
    let after = await adapter.inventoryCalls
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(10))
    XCTAssertEqual(after - before, 1)
  }
}

extension CloudSyncTests {
  /// Finding 7: a caller holding the contract port reaches the engine's association call (not the
  /// refusing default), and setup pages honour `CloudDomainSnapshot.associations`.
  func testRound7ContractAssociationsReachTheEngineAndSetupPages() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let (client, store, _) = try await reviewProtectedClient(try scratch(), server: server, content: protected)
    let port: any CloudOutboxPort = client
    let live = try await reviewProtectedOperation(protected), liveFile = try await round3ProtectedFile(protected)
    _ = try await port.enqueue([live], files: [liveFile], associations: [CloudFileAssociation(operationId: live.opId, blobIds: [liveFile.blobId])])
    XCTAssertEqual(try store.fileReferences(for: [live.opId]), [liveFile.reference])
    let first = try await reviewProtectedOperation(protected), second = try await reviewProtectedOperation(protected)
    let firstFile = try await round3ProtectedFile(protected), secondFile = try await round3ProtectedFile(protected)
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "10"])
    let page = CloudDomainSnapshot(cut: cut, operations: [first, second], files: [firstFile, secondFile],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 2, bytes: 0, blockedReasons: [])],
      associations: [CloudFileAssociation(operationId: first.opId, blobIds: [firstFile.blobId]), CloudFileAssociation(operationId: second.opId, blobIds: [secondFile.blobId])])
    _ = try await client.bootstrap([page])
    XCTAssertEqual(try store.fileReferences(for: [first.opId]), [firstFile.reference])
    XCTAssertEqual(try store.fileReferences(for: [second.opId]), [secondFile.reference])
    XCTAssertNil(try store.value("unattributedProtectedFiles:snapshot:\(cut.snapshotId):0") as [String: Int]?)
  }
}

/// Test-only socket: says hello, then drops.
final class CloudSyncRound3DroppingSocket: CloudSyncSocketConnection, @unchecked Sendable {
  private let lock = NSLock()
  private var hello: Data?
  init(hello: Data) { self.hello = hello }
  func start() {}
  func cancel() {}
  func send(_ text: String) async throws {}
  func receive() async throws -> Data {
    let next: Data? = lock.withLock { let value = hello; hello = nil; return value }
    if let next { return next }
    throw CloudFailure.unavailable
  }
}

extension CloudSyncTests {
  /// Finding 8c: a socket that opens, says hello and drops backs off on its own persisted streak, even
  /// though each hello's pull succeeds and resets the shared HTTP failure count; drops never block HTTP.
  func testRound8cFlappingSocketBacksOffDespiteSuccessfulPulls() async throws {
    let root = try scratch(), store = try makeStore(root), budget = CloudSyncBudget(store: store)
    struct Hello: Encodable {
      let socketId = "fixture-only-flap-socket"
      let headSeq = CloudSequence.zero
      let authExpiresAt = CloudSyncBytes.now() + 3_600_000
      let budget = CloudBudgetState(day: "fixture", requestsLeft: 6000, writesLeft: 12000, bytesLeft: 1024)
    }
    let hello = try CloudSyncCanonical.encode(CloudEvent(v: 1, type: "hello", id: UUID().uuidString.lowercased(),
      payload: .init(NativeRPCValue.parseJSON(CloudSyncCanonical.encode(Hello())))))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFullHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration), fixtureSocketFactory: { _ in CloudSyncRound3DroppingSocket(hello: hello) },
      fixtureSocketRetryBase: .milliseconds(2))
    let watchdog = Task { do { try await Task.sleep(for: .seconds(20)); await transport.stop() } catch {} }
    defer { watchdog.cancel() }
    var hellos = 0
    for try await event in await transport.events() where event.type == "hello" {
      hellos += 1
      try await budget.succeeded() // what each hello's successful pull does
      if hellos == 6 { break }
    }
    await transport.stop()
    let streak: Int? = try store.value("socketStreak")
    XCTAssertGreaterThanOrEqual(streak ?? 0, 5)
    let state = try await budget.status()
    XCTAssertNil(state.blocked)
    XCTAssertEqual(state.failures, 0)
  }
}

extension CloudSyncTests {
  /// Finding 8b: a commit receipt at sequence 0 is refused as a mismatch; it never traps the app.
  func testRound8bReceiptAtSequenceZeroIsRefusedNotATrap() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, _) = try await engine(root: scratch(), server: server)
    _ = try await client.enqueue([op(entity: "zero-receipt")])
    await server.answerNextCommitAtZero()
    do { _ = try await client.flush(); XCTFail("A receipt at sequence 0 was accepted") }
    catch { XCTAssertEqual(error as? CloudFailure, .checksumMismatch) }
    XCTAssertEqual(try store.queuedCount(), 1)
  }

  /// Finding 8d: answered requests leave no saved request id behind, and status reads count by query.
  func testRound8dStatusReadsDoNotGrowWithRequestHistory() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    CloudSyncFullHTTP.registry.set(server)
    let (client, store, _) = try await reviewHTTPFileClient(scratch(), server: server)
    for index in 0..<5 { _ = try await client.enqueue([op(entity: "history-\(index)")]); _ = try await client.flush() }
    XCTAssertTrue(try store.prefixed("request:").isEmpty)
    let progress = try await client.restoreProgress()
    XCTAssertEqual(progress.applied, 5)
    XCTAssertEqual(progress.coverage.map(\.sourceId), ["fixture-source"])
    await client.stop()
  }

  /// Finding 8e: the protected send warning is reported through coverage of the saved-password source
  /// while it lasts, without changing `complete`, and disappears once the upload succeeds.
  func testRound8eProtectedWarningIsReportedInCoverageAndCleared() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let (client, store, _) = try await reviewProtectedClient(try scratch(), server: server, content: protected)
    let before = try await client.coverage(sourceId: "fixture-source")
    let secret = try await reviewProtectedOperation(protected), file = try await round3ProtectedFile(protected)
    _ = try await client.enqueue([secret], files: [file], associations: [CloudFileAssociation(operationId: secret.opId, blobIds: [file.blobId])])
    await server.failFinalizationOnce(code: "secrets_locked", retryable: false)
    _ = try await client.flush()
    let waiting = try await client.coverage(sourceId: "fixture-source")
    XCTAssertTrue(waiting.blockedReasons.contains("Saved passwords are waiting to upload."))
    XCTAssertEqual(waiting.complete, before.complete)
    // Paced since 457d4dea: within the not-before window the warning stays; once it passed, the upload clears it.
    _ = try await client.flush()
    let stillWaiting = try await client.coverage(sourceId: "fixture-source")
    XCTAssertTrue(stillWaiting.blockedReasons.contains("Saved passwords are waiting to upload."))
    try store.set("protectedRetryAt", Int64(0))
    _ = try await client.flush()
    let done = try await client.coverage(sourceId: "fixture-source")
    XCTAssertFalse(done.blockedReasons.contains("Saved passwords are waiting to upload."))
  }

  /// Finding 8f: coverage for a source with no known domain is not put into the brain manifest.
  func testRound8fUnregisteredSourceCoverageStaysOutOfTheBrainManifest() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, _, _) = try await engine(root: scratch(), server: server)
    let cut = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]),
      operations: [try op(entity: "known")], files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 1, bytes: 0, blockedReasons: []),
        .init(sourceId: "ghost-source", inventoryRow: "I01", complete: false, items: 9, bytes: 0, blockedReasons: ["not registered"])])
    _ = try await client.bootstrap([cut])
    let published = try await server.checkpoint()
    let checkpoint = try XCTUnwrap(published)
    let refs = try await server.readBlobs(ids: [checkpoint.root.blobId])
    let sealed = try await server.download(try XCTUnwrap(refs.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    let manifest = try await makeContent().open(CloudWire.decode(CloudContentEnvelope.self, from: sealed))
    let sources = OrderedJSON.parse(manifest)?["sourceCoverage"]?.array?.compactMap { $0["sourceId"]?.string }
    XCTAssertEqual(sources, ["fixture-source"])
  }
}
