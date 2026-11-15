import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

// Review round 4 regressions. Fixture-only data; no real account, Keychain or network.
extension CloudSyncTests {
  /// Round 4 S6 (coordinator SF5): when feed links expire part-way through a page, the rest of the page is
  /// renewed in one call, not one call per remaining pack.
  func testRound4ExpiredFeedLinksAreRenewedOncePerPage() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    for index in 0..<10 { _ = try await server.commit(reviewBrainSegment([op(entity: "link-\(index)")])) }
    let (reader, store, _) = try await engine(root: scratch(), server: server)
    await server.expireFeedLinks(afterDownloads: 1)
    _ = try await reader.pull()
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(10))
    let calls = await server.changesCalls()
    XCTAssertEqual(calls, 2, "one page read plus one renewal for the nine packs whose links expired")
  }
}

extension CloudSyncTests {
  /// Round 4 S2: on a non-empty account the missing-file check runs after catch-up, so a file that arrives
  /// with the feed is not called missing and setup completes.
  func testRound4MissingFileCheckRunsAfterCatchUp() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, _) = try await sealedAttachment(root: scratch()), record = try referencing(file)
    let (peer, _) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    _ = try await peer.enqueue([record], files: [file])
    _ = try await peer.flush()
    let (setup, store) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    let receipt = try await setup.bootstrap([snapshot([record])])
    XCTAssertTrue(receipt.published)
    XCTAssertTrue(try store.prefixed("bootstrapMissingFiles:").isEmpty)
    XCTAssertEqual(try store.value("inventoryVerified"), true)
  }
}

extension CloudSyncTests {
  /// Round 4 S3 (coordinator SF3): a MEMORY step refused as saved-password work is paced by the shared back-off
  /// (a failure, a retry time) and explained on memory coverage until a later flush succeeds.
  func testRound4MemoryStepRefusedAsProtectedIsPacedAndExplained() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    CloudSyncFullHTTP.registry.set(server)
    let (client, _, budget) = try await reviewHTTPFileClient(scratch(), server: server)
    _ = try await client.enqueue([op(entity: "memory-refused")])
    await server.refuseHTTPOnce("POST /v1/changes", status: 403, code: "secrets_locked")
    do { _ = try await client.flush(); XCTFail("Refusal hidden") } catch { XCTAssertEqual(error as? CloudFailure, .secretsLocked) }
    let state = try await budget.status()
    XCTAssertEqual(state.failures, 1)
    XCTAssertGreaterThan(state.retryAt, CloudSyncBytes.now())
    let waiting = try await client.coverage(sourceId: "fixture-source")
    XCTAssertFalse(waiting.complete)
    XCTAssertTrue(waiting.blockedReasons.contains { $0.hasPrefix("The service refused a memory upload") })
    try await budget.resume(networkOrWake: true, userRetry: true)
    _ = try await client.flush()
    let after = try await client.coverage(sourceId: "fixture-source")
    XCTAssertFalse(after.blockedReasons.contains { $0.hasPrefix("The service refused a memory upload") })
    await client.stop()
  }

  /// Round 4 S4a: after a protected refusal, the next flush does not try the saved-password pack again at once.
  func testRound4ProtectedRefusalIsPacedNotRetriedEveryFlush() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    CloudSyncFullHTTP.registry.set(server)
    let (client, store, _) = try await round3ProtectedHTTPClient(scratch(), server: server, protected: protected)
    let secret = try await reviewProtectedOperation(protected), file = try await round3ProtectedFile(protected)
    _ = try await client.enqueue([secret], files: [file], associations: [CloudFileAssociation(operationId: secret.opId, blobIds: [file.blobId])])
    await server.refuseHTTP("POST /v1/blobs/prepare", status: 403, code: "secrets_locked", times: 10)
    _ = try await client.flush()
    _ = try await client.flush()
    _ = try await client.flush()
    let prepares = await server.hits("POST /v1/blobs/prepare")
    XCTAssertEqual(prepares, 1)
    XCTAssertEqual(try store.queuedCount(), 1)
    await client.stop()
  }

  /// Round 4 S4b: a device refused for both the protected and the fallback applied report still finishes its pull.
  func testRound4DoubleRefusedAppliedReportDoesNotFailThePull() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    CloudSyncFullHTTP.registry.set(server)
    let (client, store, _) = try await round3ProtectedHTTPClient(scratch(), server: server, protected: protected)
    _ = try await server.commit(reviewBrainSegment([op(entity: "memory-to-apply")]))
    await server.refuseHTTP("POST /v1/applied", status: 403, code: "secrets_locked", times: 2)
    try store.set("secretsSeq", CloudSequence(1))
    _ = try await client.pull()
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(1))
    XCTAssertEqual(try store.value("blocked"), false)
    await client.stop()
  }

  /// Round 4 S4c: protected setup files refused during setup are sent at the next flush even when no
  /// protected pack is queued, and only then does the warning clear.
  func testRound4WaitingProtectedSetupFilesAreSentWithoutAProtectedPack() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    CloudSyncFullHTTP.registry.set(server)
    let (client, store, _) = try await round3ProtectedHTTPClient(scratch(), server: server, protected: protected)
    let file = try await round3ProtectedFile(protected)
    let page = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]),
      operations: [], files: [file], coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 0, bytes: 0, blockedReasons: [])])
    await server.refuseHTTPOnce("POST /v1/blobs/prepare", status: 403, code: "secrets_locked")
    _ = try await client.bootstrap([page])
    let refs = try await server.readBlobs(ids: [file.blobId])
    XCTAssertEqual(refs.first?.blob.blobId, file.blobId)
    XCTAssertNil(try store.value("protectedSnapshotFilesWaiting") as Bool?)
    XCTAssertNil(try store.value("protectedSendFailure") as String?)
    await client.stop()
  }
}

extension CloudSyncTests {
  /// Round 4 S5 (coordinator SF4): the socket's back-off is capped at 60 s, and a network-returned or wake
  /// signal ends a back-off wait at once instead of sitting it out.
  func testRound4NetworkReturnWakesTheSocketBackoff() async throws {
    let root = try scratch(), store = try makeStore(root), budget = CloudSyncBudget(store: store)
    struct Hello: Encodable {
      let socketId = "fixture-only-wake-socket"
      let headSeq = CloudSequence.zero
      let authExpiresAt = CloudSyncBytes.now() + 3_600_000
      let budget = CloudBudgetState(day: "fixture", requestsLeft: 6000, writesLeft: 12000, bytesLeft: 1024)
    }
    let hello = try CloudSyncCanonical.encode(CloudEvent(v: 1, type: "hello", id: UUID().uuidString.lowercased(),
      payload: .init(NativeRPCValue.parseJSON(CloudSyncCanonical.encode(Hello())))))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFullHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    // A 20 s base: without a wake the second connection could not come within the test's 5 s.
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: { _ in "" }, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration), fixtureSocketFactory: { _ in CloudSyncRound3DroppingSocket(hello: hello) },
      fixtureSocketRetryBase: .seconds(20))
    let capped = await transport.socketBackoff(30)
    XCTAssertLessThanOrEqual(capped, 60_000 + 10_000)
    let watchdog = Task { do { try await Task.sleep(for: .seconds(5)); await transport.stop() } catch {} }
    defer { watchdog.cancel() }
    var hellos = 0
    for try await event in await transport.events() where event.type == "hello" {
      hellos += 1
      if hellos == 2 { break }
      Task { try? await Task.sleep(for: .milliseconds(200)); await transport.networkOrWake() }
    }
    await transport.stop()
    XCTAssertEqual(hellos, 2, "the wake ended the 20 s back-off")
  }
}

extension CloudSyncTests {
  func round4Packs(_ operations: [CloudOperation], server: CloudSyncFixtureServer, size: Int = 100) async throws {
    for start in stride(from: 0, to: operations.count, by: size) {
      _ = try await server.commit(reviewBrainSegment(Array(operations[start..<min(start + size, operations.count)])))
    }
  }

  /// Round 4 3a: one record among 200 that the adapter cannot apply is parked with its reason; the other
  /// 199 apply, the feed advances, the source shows incomplete, and a later version of the same record
  /// waits behind it without the adapter being asked.
  func testRound4OneBadRecordAmong200IsParkedAndLaterVersionsWait() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let records = try (0..<200).map { try op(entity: "poison-\($0)") }, bad = records[137]
    let later = try op(entity: bad.entityId, parents: [bad.opId], text: "later version")
    try await round4Packs(records, server: server)
    _ = try await server.commit(reviewBrainSegment([later]))
    let (reader, store, adapter) = try await engine(root: scratch(), server: server)
    await adapter.refuse([bad.opId])
    _ = try await reader.pull()
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(3))
    let applied = await adapter.count()
    XCTAssertEqual(applied, 199)
    let validated = await adapter.validated()
    XCTAssertFalse(validated.contains(later.opId), "a later version waits behind the parked record")
    XCTAssertEqual(Set(try store.rows("SELECT opId FROM parked_ops").map { String(decoding: $0[0], as: UTF8.self) }), [bad.opId, later.opId])
    let coverage = try await reader.coverage(sourceId: "fixture-source")
    XCTAssertFalse(coverage.complete)
    XCTAssertTrue(coverage.blockedReasons.contains { $0.hasPrefix("2 records could not be applied on this Mac") })
    let progress = try await reader.restoreProgress()
    XCTAssertEqual(progress.blocked, 1)
    XCTAssertEqual(progress.applied, 199)
    let ready = try await reader.contextReady(projectId: "fixture-project")
    XCTAssertFalse(ready.verified)
  }

  /// Round 4 3a: parked records survive a restart, retry at launch, and apply in order once the adapter
  /// heals and reports the change; the source becomes complete again without setup.
  func testRound4ParkedRecordSurvivesRestartAndAppliesWhenTheAdapterHeals() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let base = try op(entity: "inventory-base")
    let (publisher, _, _) = try await engine(root: scratch(), server: server)
    _ = try await publisher.bootstrap([snapshot([base])])
    let bad = try op(entity: "heals-later"), later = try op(entity: bad.entityId, parents: [bad.opId], text: "second")
    _ = try await server.commit(reviewBrainSegment([bad]))
    _ = try await server.commit(reviewBrainSegment([later]))
    do {
      let (first, _, adapter) = try await engine(root: root, server: server)
      await adapter.refuse([bad.opId])
      _ = try await first.pull()
    }
    let (reopened, store, adapter) = try await engine(root: root, server: server)
    await adapter.refuse([bad.opId])
    _ = try await reopened.pull() // launch retry: still refused, still parked
    XCTAssertEqual(try store.rows("SELECT opId FROM parked_ops").count, 2)
    await adapter.heal()
    try await reopened.retryParked(domains: ["memory"])
    XCTAssertTrue(try store.rows("SELECT opId FROM parked_ops").isEmpty)
    let order = await adapter.appliedOrder()
    XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: bad.opId)), try XCTUnwrap(order.firstIndex(of: later.opId)))
    let coverage = try await reopened.coverage(sourceId: "fixture-source")
    XCTAssertFalse(coverage.blockedReasons.contains { $0.contains("could not be applied on this Mac") })
    let ready = try await reopened.contextReady(projectId: "fixture-project")
    XCTAssertTrue(ready.verified)
  }

  /// Round 4 3a: an inventory published while a record is parked still contains it; a reader whose adapter
  /// accepts it restores everything.
  func testRound4InventoryPublishedWhileARecordIsParkedKeepsIt() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let good = try op(entity: "kept-good"), bad = try op(entity: "kept-bad")
    _ = try await server.commit(reviewBrainSegment([good, bad]))
    let (publisher, _, adapter) = try await engine(root: scratch(), server: server)
    await adapter.refuse([bad.opId])
    let receipt = try await publisher.bootstrap([snapshot([try op(entity: "local-cut")])])
    XCTAssertTrue(receipt.published)
    let (reader, restored, readerAdapter) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertTrue(Set(try restored.operations().map(\.opId)).isSuperset(of: [good.opId, bad.opId]))
    let applied = await readerAdapter.count()
    XCTAssertEqual(applied, 3)
  }
}

extension CloudSyncTests {
  /// Round 4 3b: a first setup refused for ever (a record names a file this Mac never had) can be abandoned
  /// by A's wiring; a NEW cut then publishes, and the old cut's queue and records are kept.
  func testRound4AbandonedUnpublishedSetupAllowsANewCut() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, _) = try await sealedAttachment(root: scratch()), stuck = try referencing(file)
    let (client, store) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    let first = snapshot([stuck])
    do { _ = try await client.bootstrap([first]); XCTFail("Missing file not refused") } catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    let other = snapshot([try op(entity: "new-cut")])
    do { _ = try await client.bootstrap([other]); XCTFail("A new cut was accepted before abandoning") } catch { XCTAssertEqual(error as? CloudFailure, .versionChanged) }
    try await client.abandonUnpublishedSetup()
    XCTAssertNil(try store.value("bootstrapInProgress") as String?)
    XCTAssertTrue(try store.prefixed("bootstrapMissingFiles:").isEmpty)
    XCTAssertTrue(try store.operations().map(\.opId).contains(stuck.opId), "the old cut's records are kept")
    let receipt = try await client.bootstrap([other])
    XCTAssertTrue(receipt.published)
    XCTAssertNil(try store.value("bootstrapInProgress") as String?)
    // The old cut's record stays queued, held (not failing every send) until its file is handed over.
    XCTAssertEqual(try store.queuedCount(), 1)
    let coverage = try await client.coverage(sourceId: "fixture-source")
    XCTAssertTrue(coverage.blockedReasons.contains { $0.hasPrefix("1 records wait for a file that is not on this Mac") })
    _ = try await client.enqueue([op(entity: "after-setup")])
    _ = try await client.flush()
    XCTAssertEqual(try store.queuedCount(), 1)
  }

  /// Round 4 3b, changed by round 5 S2 (Decker): abandoning is allowed whenever THIS Mac's setup published
  /// nothing, also when another Mac's inventory exists (the old test expected a refusal there); the Mac then
  /// joins that inventory by a normal pull. It is refused once this Mac's own setup published.
  func testRound4AbandonIsRefusedOnlyAfterThisMacPublished() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, _) = try await sealedAttachment(root: scratch()), stuck = try referencing(file)
    let (client, store) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    do { _ = try await client.bootstrap([snapshot([stuck])]); XCTFail("Missing file not refused") } catch {}
    let (other, _, _) = try await engine(root: scratch(), server: server)
    _ = try await other.bootstrap([snapshot([try op(entity: "other-mac")])])
    try await client.abandonUnpublishedSetup()
    XCTAssertNil(try store.value("bootstrapInProgress") as String?)
    _ = try await client.pull()
    XCTAssertEqual(try store.value("inventoryVerified"), true, "joined the other Mac's inventory")
    // This Mac publishes, then its own import fails: the setup marker stays.
    // Round 6 S7a changed this expectation: old: abandoning was refused (`versionChanged`); new: it is allowed and
    // the Mac then joins its own published inventory through the normal pull. Why: with a cut that cannot be
    // replayed the old rule left that Mac stuck for good; abandoning loses nothing (queue and receipts stay).
    let empty = try CloudSyncFixtureServer(root: scratch(), device: device), publisherRoot = try scratch()
    let (publisher, _, _) = try await engine(root: publisherRoot, server: empty, fault: { if $0 == .duringApply { throw CloudFailure.unavailable } })
    do { _ = try await publisher.bootstrap([snapshot([try op(entity: "published")])]); XCTFail("Own import fault missed") } catch {}
    let published = try await empty.checkpoint()
    XCTAssertNotNil(published)
    try await publisher.abandonUnpublishedSetup()
    let (relaunched, publisherStore, publisherAdapter) = try await engine(root: publisherRoot, server: empty)
    XCTAssertNil(try publisherStore.value("bootstrapInProgress") as String?)
    _ = try await relaunched.pull()
    XCTAssertEqual(try publisherStore.value("inventoryVerified"), true, "joined its own published inventory")
    let applied = await publisherAdapter.count()
    XCTAssertEqual(applied, 1)
  }
}

extension CloudSyncTests {
  /// Round 4 3c: an intentional exclusion is reported in its own list and never makes the source incomplete
  /// or blocks readiness.
  func testRound4IntentionalExclusionNeverMakesASourceIncomplete() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, _, adapter) = try await engine(root: scratch(), server: server)
    await adapter.report(complete: true, exclusions: ["Build caches are left out on purpose."])
    let cut = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]),
      operations: [try op(entity: "kept")], files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 1, bytes: 0, blockedReasons: [],
        exclusions: ["Build caches are left out on purpose."])])
    _ = try await client.bootstrap([cut])
    let coverage = try await client.coverage(sourceId: "fixture-source")
    XCTAssertTrue(coverage.complete)
    XCTAssertEqual(coverage.exclusions, ["Build caches are left out on purpose."])
    XCTAssertTrue(coverage.blockedReasons.isEmpty)
    let ready = try await client.contextReady(projectId: "fixture-project")
    XCTAssertTrue(ready.verified)
    // A fresh reader gets the exclusion from the published inventory, still complete.
    let (reader, _, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    let restored = try await reader.coverage(sourceId: "fixture-source")
    XCTAssertTrue(restored.complete)
    XCTAssertEqual(restored.exclusions, ["Build caches are left out on purpose."])
  }

  /// Round 4 3c: a local gap that heals clears: `complete` returns to true without running setup again, and
  /// a restart with changed counts does not mark the source incomplete.
  func testRound4HealedGapClearsWithoutSetup() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let (client, _, adapter) = try await engine(root: root, server: server)
    await adapter.report(complete: false, gaps: ["Some notes could not be read."])
    _ = try await client.bootstrap([snapshot([try op(entity: "gap-source")])])
    let gap = try await client.coverage(sourceId: "fixture-source")
    XCTAssertFalse(gap.complete)
    XCTAssertTrue(gap.blockedReasons.contains("Some notes could not be read."))
    await adapter.report(complete: true)
    try await client.retryParked(domains: ["memory"])
    let healed = try await client.coverage(sourceId: "fixture-source")
    XCTAssertTrue(healed.complete)
    XCTAssertFalse(healed.blockedReasons.contains("Some notes could not be read."))
    // Restart: the local adapter's counts differ from the stored ones; the source stays complete.
    let (reopened, _, _) = try await engine(root: root, server: server)
    let after = try await reopened.coverage(sourceId: "fixture-source")
    XCTAssertTrue(after.complete)
  }
}

extension CloudSyncTests {
  /// Client cut 3: a reader asks for inventory objects up to 16 per `/blobs/read` call, not one call per leaf.
  func testRound4CheckpointObjectsAreReadSixteenPerCall() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let rows = try (0..<80).map { try op(entity: "batch-\($0)", text: String(repeating: "b", count: 200)) }
    let (sender, _, _) = try await engine(root: scratch(), server: server, packLimit: 1024)
    _ = try await sender.bootstrap([snapshot(rows)])
    let objects = await server.objectCount()
    XCTAssertGreaterThan(objects, 17, "a tree with nodes")
    let (reader, store, _) = try await engine(root: scratch(), server: server)
    let before = await server.readBlobCalls
    _ = try await reader.pull()
    let calls = await server.readBlobCalls - before
    XCTAssertEqual(Set(try store.operations().map(\.opId)), Set(rows.map(\.opId)))
    XCTAssertLessThanOrEqual(calls, 2 + (objects - 1 + 15) / 16, "root, then one call per node's children")
  }

  /// Client cut 5: the publisher imports its own first inventory from the copies it already read back, so every
  /// inventory object is downloaded exactly once (its upload read-back), not twice.
  func testRound4PublisherDoesNotDownloadItsOwnInventoryAgain() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let rows = try (0..<40).map { try op(entity: "own-\($0)", text: String(repeating: "c", count: 200)) }
    let (publisher, _, _) = try await engine(root: scratch(), server: server, packLimit: 1024)
    _ = try await publisher.bootstrap([snapshot(rows)])
    let objects = await server.objectCount(), downloads = await server.objectDownloads
    XCTAssertEqual(downloads, objects)
  }
}

extension CloudSyncTests {
  /// Client cut 1: files go up 16 per prepare and per finalize, each item's result handled on its own.
  func testRound4FilesArePreparedAndFinalizedSixteenPerCall() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    var files: [CloudLocalBlob] = [], records: [CloudOperation] = []
    for _ in 0..<20 {
      let (file, _) = try await sealedAttachment(root: scratch())
      files.append(file); records.append(try referencing(file))
    }
    _ = try await client.enqueue(records, files: files, associations: zip(records, files).map { CloudFileAssociation(operationId: $0.opId, blobIds: [$1.blobId]) })
    _ = try await client.flush()
    XCTAssertEqual(try store.queuedCount(), 0)
    // Round 5 S5 changed this from 2/2: batches now start at 4 files and double while uploads are fast
    // (4, then 8, then the remaining 8), so a slow uplink never starts with 16 files under one ticket set.
    let prepares = await server.prepareCalls, finalizes = await server.finalizeCalls
    XCTAssertEqual(prepares, 3)
    XCTAssertEqual(finalizes, 3)
    let present = try await server.readBlobs(ids: Array(files.prefix(16).map(\.blobId)))
    XCTAssertEqual(present.count, 16)
  }

  /// Client cut 1: one item refused at finalize (expired ticket) is repaired on its own; the other items of the
  /// batch are finalized and read back normally.
  func testRound4OneFailedItemInABatchIsRepairedAlone() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    var files: [CloudLocalBlob] = [], records: [CloudOperation] = []
    for _ in 0..<4 {
      let (file, _) = try await sealedAttachment(root: scratch())
      files.append(file); records.append(try referencing(file))
    }
    _ = try await client.enqueue(records, files: files, associations: zip(records, files).map { CloudFileAssociation(operationId: $0.opId, blobIds: [$1.blobId]) })
    await server.failFinalizationOnce(code: "code_expired", retryable: false)
    _ = try await client.flush()
    XCTAssertEqual(try store.queuedCount(), 0)
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1)
    let present = try await server.readBlobs(ids: files.map(\.blobId))
    XCTAssertEqual(present.count, 4)
  }
}

extension CloudSyncTests {
  /// Client cut 2: the pull right after a flush applies this Mac's own just-verified pack from its local copy.
  func testRound4OwnVerifiedPackIsNotDownloadedAgainOnPull() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, _) = try await engine(root: scratch(), server: server)
    _ = try await client.enqueue([op(entity: "own-pack")])
    _ = try await client.flush()
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(1))
    let downloads = await server.segmentDownloads
    XCTAssertEqual(downloads, 1, "only the read-back after commit")
  }

  /// Client cut 4: feed catch-up reads 128 entries per page.
  func testRound4FeedPagesCarry128Entries() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    for index in 0..<100 { _ = try await server.commit(reviewBrainSegment([op(entity: "page-\(index)")])) }
    let (reader, store, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(100))
    let calls = await server.changesCalls()
    XCTAssertEqual(calls, 1)
  }
}

extension CloudSyncTests {
  func round4TwoDomainClient(_ root: URL, server: CloudSyncFixtureServer) async throws -> (CloudSyncEngine, CloudSyncStore) {
    let store = try makeStore(root)
    let client = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory", "notes"],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in }, firstUpload: true)
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory")))
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("notes"), domain: "notes"))
    return (client, store)
  }
  func round4Many(parents count: Int) throws -> CloudOperation {
    let base = try op(entity: "many-parents")
    return .init(v: 1, opId: base.opId, originDevice: base.originDevice, domain: base.domain, entityId: base.entityId, revision: base.revision,
      parents: (0..<count).map { _ in UUID().uuidString.lowercased() }, kind: base.kind, projectId: base.projectId, source: base.source,
      createdAt: base.createdAt, payload: base.payload, payloadHash: base.payloadHash)
  }

  /// V's M2: enqueue refuses a record that could never be sent, with a typed error, and queues nothing.
  func testRound4EnqueueRefusesRecordsLargerThanOnePack() async throws {
    let (client, store, _) = try await engine(root: scratch(), server: CloudSyncFixtureServer(root: scratch(), device: device))
    let bigPayload = try op(entity: "big-payload", text: String(repeating: "x", count: CloudWire.maximumRecordPayloadBytes + 10))
    do { _ = try await client.enqueue([try op(entity: "fine"), bigPayload]); XCTFail("Oversized payload queued") }
    catch let error as CloudRecordTooLarge { XCTAssertEqual(error.operationId, bigPayload.opId); XCTAssertEqual(error.limit, CloudWire.maximumRecordPayloadBytes) }
    let wide = try round4Many(parents: 5_000)
    do { _ = try await client.enqueue([wide]); XCTFail("Oversized record queued") }
    catch let error as CloudRecordTooLarge { XCTAssertEqual(error.limit, CloudWire.maximumRecordBytes) }
    XCTAssertEqual(try store.queuedCount(), 0)
  }

  /// V's M3: an unsendable record already in the queue (too large, queued by an older build) is parked with a
  /// reason; the records behind it send.
  func testRound4OversizedQueuedRecordIsParkedAndDoesNotBlockTheQueue() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, _) = try await engine(root: scratch(), server: server)
    let wide = try round4Many(parents: 5_000)
    _ = try store.enqueue([wide]) // as an older build could have
    let behind = try op(entity: "behind-the-big-one")
    _ = try await client.enqueue([behind])
    _ = try await client.flush()
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1)
    XCTAssertEqual(try store.queuedCount(), 0)
    XCTAssertEqual(try store.rows("SELECT opId FROM parked_sends").count, 1)
    let coverage = try await client.coverage(sourceId: "fixture-source")
    XCTAssertTrue(coverage.blockedReasons.contains { $0.hasPrefix("1 edits could not be sent") })
    let progress = try await client.restoreProgress()
    XCTAssertEqual(progress.blocked, 1)
  }

  /// V's M3: a pack the service refuses for good is split; each refused record is parked and the rest send.
  /// A retry after the cause is fixed sends the parked records.
  func testRound4PackRefusedForGoodIsSplitAndRefusedRecordsParked() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store) = try await round4TwoDomainClient(scratch(), server: server)
    func note(_ entity: String) throws -> CloudOperation {
      let base = try op(entity: entity)
      return .init(v: 1, opId: base.opId, originDevice: base.originDevice, domain: "notes", entityId: base.entityId, revision: base.revision,
        parents: [], kind: base.kind, projectId: base.projectId, source: base.source, createdAt: base.createdAt, payload: base.payload, payloadHash: base.payloadHash)
    }
    _ = try await client.enqueue([try op(entity: "memory-a"), try note("note-1"), try note("note-2"), try op(entity: "memory-b")])
    await server.refusePacks(of: ["notes"])
    // Round 5 M3 changed this: the notes pack (refusal 1) is split, note-1 alone is refused (2) and parked,
    // note-2 alone is refused (3): three in a row stop the flush with an account failure and note-2 stays QUEUED
    // (before: both notes were parked and the flush went on, which parked a whole queue on a general refusal).
    do { _ = try await client.flush(); XCTFail("Three refusals in a row did not stop") }
    catch { guard case CloudFailure.remote(let detail) = error else { return XCTFail("refusal lost") }; XCTAssertEqual(detail.code, "unsupported_format") }
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1, "the memory pack")
    XCTAssertEqual(try store.rows("SELECT opId FROM parked_sends").count, 1)
    XCTAssertEqual(try store.queuedCount(), 1)
    await server.refusePacks(of: [])
    try await CloudSyncBudget(store: store).resume(networkOrWake: false, userRetry: true)
    try await client.retryParked(domains: ["notes"])
    _ = try await client.flush()
    let after = await server.segmentCount()
    XCTAssertEqual(after, 3)
    XCTAssertTrue(try store.rows("SELECT opId FROM parked_sends").isEmpty)
  }
}

extension CloudSyncTests {
  /// A2 agreement 1 / V M3 item 3: adapters get the service's commit time on apply, and a record's read-back
  /// receipt (with that time) by id once acknowledged; nil before. The outbox identity is stable.
  func testRound4CommitTimeReceiptsAndOutboxIdentity() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let remote = try op(entity: "from-feed")
    _ = try await server.commit(reviewBrainSegment([remote]))
    let (client, _, adapter) = try await engine(root: root, server: server)
    let local = try op(entity: "local-edit")
    _ = try await client.enqueue([local])
    let before = try await client.cloudReceipt(operationId: local.opId)
    XCTAssertNil(before)
    _ = try await client.flush()
    let own = try await client.cloudReceipt(operationId: local.opId)
    XCTAssertEqual(own?.committedAt, 1000)
    XCTAssertEqual(own?.sequence, CloudSequence(2))
    let origin = await adapter.origin(of: remote.opId)
    XCTAssertEqual(origin?.committedAt, 1000)
    let incoming = try await client.cloudReceipt(operationId: remote.opId)
    XCTAssertEqual(incoming?.sequence, CloudSequence(1))
    let identity = try await client.outboxIdentity()
    let (reopened, _, _) = try await engine(root: root, server: server)
    let again = try await reopened.outboxIdentity()
    XCTAssertEqual(identity, again)
    let (other, _, _) = try await engine(root: scratch(), server: server)
    let different = try await other.outboxIdentity()
    XCTAssertNotEqual(identity, different)
  }

  /// A2 agreement 3: narrow readiness looks only at the named sources of one project; an unrelated,
  /// not-yet-built source does not block it (while the account-wide readiness still says not ready).
  func testRound4NarrowReadinessIgnoresUnrelatedSources() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, _, _) = try await engine(root: scratch(), server: server)
    let cut = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]),
      operations: [try op(entity: "project-note")], files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 1, bytes: 0, blockedReasons: []),
        .init(sourceId: "unbuilt-source", inventoryRow: "I99", complete: false, items: 0, bytes: 0, blockedReasons: ["Not built yet."])])
    _ = try await client.bootstrap([cut])
    let wide = try await client.contextReady(projectId: "fixture-project")
    XCTAssertFalse(wide.verified)
    let narrow = try await client.contextReady(projectId: "fixture-project", sources: ["fixture-source"])
    XCTAssertTrue(narrow.verified)
    let missing = try await client.contextReady(projectId: "fixture-project", sources: ["fixture-source", "unbuilt-source"])
    XCTAssertFalse(missing.verified)
    XCTAssertEqual(missing.missingSources, ["unbuilt-source"])
  }

  /// A2 agreement 2: an exact replay of a setup page with files is accepted from the saved references alone,
  /// even though the adapter's staged file is gone; a page whose coverage number changed is refused.
  func testRound4SetupPageReplayAcceptsSavedFileReferences() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store) = try await reviewRegisteredClient(scratch(), server: server, registration: device, signatureByte: 7)
    let (file, _) = try await sealedAttachment(root: scratch()), record = try referencing(file)
    let page = snapshot([record])
    let withFile = CloudDomainSnapshot(cut: page.cut, operations: page.operations, files: [file], coverage: page.coverage)
    await server.setFailure(.unavailable)
    do { _ = try await client.bootstrap([withFile]); XCTFail("Network gate ignored") } catch {}
    await server.setFailure(nil)
    try FileManager.default.removeItem(at: file.localURL) // the adapter dropped its staged copy after the local receipt
    let changed = CloudDomainSnapshot(cut: page.cut, operations: page.operations, files: [file],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 99, bytes: 0, blockedReasons: [])])
    do { _ = try await client.bootstrap([changed]); XCTFail("Changed page accepted") } catch { XCTAssertEqual(error as? CloudFailure, .idReused) }
    let receipt = try await client.bootstrap([withFile])
    XCTAssertTrue(receipt.published)
    XCTAssertEqual(try store.queuedCount(), 0)
  }
}
