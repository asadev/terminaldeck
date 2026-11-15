import XCTest
import Foundation
@testable import TerminalDeckNativeCore

// Review round 5 regressions. Fixture-only data; no real account, Keychain or network.
extension CloudSyncTests {
  func round5Note(_ entity: String, id: String = UUID().uuidString.lowercased(), parents: [String] = [], text: String = "fixture") throws -> CloudOperation {
    let base = try op(id: id, entity: entity, parents: parents, text: text)
    return .init(v: 1, opId: base.opId, originDevice: base.originDevice, domain: "notes", entityId: base.entityId, revision: base.revision,
      parents: base.parents, kind: base.kind, projectId: base.projectId, source: base.source, createdAt: base.createdAt, payload: base.payload, payloadHash: base.payloadHash)
  }

  /// M1: an incoming record with the id of this Mac's own unsent record but different bytes is parked as a
  /// conflict; this Mac's record is NOT marked acknowledged or in Cloud, is parked unsent, shows as a gap, and
  /// a setup on this non-empty account refuses to publish an inventory.
  func testRound5IdConflictLeavesOwnRecordUnsentAndBlocksPublishing() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let shared = UUID().uuidString.lowercased()
    let local = try op(id: shared, entity: "copied-record", text: "this Mac's bytes")
    let remote = try op(id: shared, entity: "copied-record", text: "the other Mac's bytes", origin: "44444444-4444-4444-8444-444444444444")
    _ = try await server.commit(reviewBrainSegment([remote]))
    let (client, store, _) = try await engine(root: scratch(), server: server)
    _ = try await client.enqueue([local])
    _ = try await client.pull()
    let receipt = try await client.cloudReceipt(operationId: shared)
    XCTAssertNil(receipt, "never sent, so never in Cloud")
    XCTAssertTrue(try store.rows("SELECT opId FROM verified_ops WHERE opId=?", [Data(shared.utf8)]).isEmpty)
    XCTAssertEqual(try store.rows("SELECT state FROM outbox WHERE opId=?", [Data(shared.utf8)]).first.map { String(decoding: $0[0], as: UTF8.self) }, "parked")
    XCTAssertEqual(try store.rows("SELECT opId FROM parked_ops WHERE conflict=1").count, 1)
    let coverage = try await client.coverage(sourceId: "fixture-source")
    XCTAssertFalse(coverage.complete)
    do { _ = try await client.bootstrap([snapshot([try op(entity: "cut")])]); XCTFail("Published with a conflict parked") }
    catch { XCTAssertEqual(error as? CloudFailure, .idReused) }
    let published = try await server.checkpoint()
    XCTAssertNil(published)
  }

  /// M2: account-wide readiness is false while any record is parked, even one from a source this Mac has no
  /// coverage row for.
  func testRound5ReadinessIsFalseWhileARecordFromAnUnknownSourceIsParked() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (publisher, _, _) = try await engine(root: scratch(), server: server)
    _ = try await publisher.bootstrap([snapshot([try op(entity: "base")])])
    let base = try op(entity: "only-on-the-other-mac")
    let foreign = CloudOperation(v: 1, opId: base.opId, originDevice: base.originDevice, domain: "memory", entityId: base.entityId, revision: base.revision,
      parents: [], kind: base.kind, projectId: base.projectId, source: .init(sourceId: "files-other-mac", recordId: base.opId),
      createdAt: base.createdAt, payload: base.payload, payloadHash: base.payloadHash)
    _ = try await server.commit(reviewBrainSegment([foreign]))
    let (reader, _, adapter) = try await engine(root: scratch(), server: server)
    await adapter.refuse([foreign.opId])
    _ = try await reader.pull()
    let ready = try await reader.contextReady(projectId: "fixture-project")
    XCTAssertFalse(ready.verified)
  }

  /// M3: a parked edit is retried by itself (at launch here), with no retryParked call.
  func testRound5ParkedEditIsRetriedByItselfAtLaunch() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let note = try round5Note("note-alone")
    do {
      let (client, store) = try await round4TwoDomainClient(root, server: server)
      _ = try await client.enqueue([note])
      await server.refusePacks(of: ["notes"])
      _ = try await client.flush()
      XCTAssertEqual(try store.rows("SELECT opId FROM parked_sends").count, 1)
    }
    await server.refusePacks(of: [])
    let (reopened, store) = try await round4TwoDomainClient(root, server: server)
    _ = try await reopened.flush()
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1)
    XCTAssertEqual(try store.queuedCount(), 0)
    XCTAssertTrue(try store.rows("SELECT opId FROM parked_sends").isEmpty)
  }

  /// S1: a later edit of the same record waits behind an edit of it that is parked on the send side.
  func testRound5LaterEditWaitsBehindAParkedEditOfTheSameRecord() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store) = try await round4TwoDomainClient(try scratch(), server: server)
    let first = try round5Note("same-record", text: "part 3")
    _ = try await client.enqueue([first])
    await server.refusePacks(of: ["notes"])
    _ = try await client.flush()
    await server.refusePacks(of: [])
    let second = try round5Note("same-record", parents: [first.opId], text: "part 4")
    _ = try await client.enqueue([second, try op(entity: "memory-meanwhile")])
    _ = try await client.flush()
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1, "only the memory edit went out")
    XCTAssertEqual(try store.queuedCount(), 1, "the later edit waits")
    try await client.retryParked(domains: ["notes"])
    _ = try await client.flush()
    let after = await server.segmentCount()
    XCTAssertEqual(after, 2)
    XCTAssertEqual(try store.queuedCount(), 0)
  }
}

extension CloudSyncTests {
  /// S7: the narrow readiness query with no named source is the account-wide question, not "ready".
  func testRound5NarrowReadinessWithNoSourcesIsTheWideQuestion() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, _, _) = try await engine(root: scratch(), server: server)
    let cut = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]),
      operations: [try op(entity: "project-note")], files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 1, bytes: 0, blockedReasons: []),
        .init(sourceId: "unbuilt-source", inventoryRow: "I99", complete: false, items: 0, bytes: 0, blockedReasons: ["Not built yet."])])
    _ = try await client.bootstrap([cut])
    let wide = try await client.contextReady(projectId: "fixture-project")
    let empty = try await client.contextReady(projectId: "fixture-project", sources: [])
    XCTAssertFalse(wide.verified)
    XCTAssertEqual(empty.verified, wide.verified)
  }
}

/// Test-only counter of socket connections.
final class CloudSyncRound5Connections: @unchecked Sendable {
  private let lock = NSLock()
  private var opened = 0
  func open() { lock.withLock { opened += 1 } }
  func count() -> Int { lock.withLock { opened } }
}

extension CloudSyncTests {
  /// S4: after the five-failure pause the event stream ends; when the network returns the engine restarts it
  /// by itself (the network monitor and wake signal outlive the stream).
  func testRound5NetworkWakeRestartsTheEventStreamAfterItEnded() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    CloudSyncFullHTTP.registry.set(server)
    let root = try scratch(), store = try makeStore(root), budget = CloudSyncBudget(store: store)
    struct Hello: Encodable {
      let socketId = "fixture-only-wake-restart"
      let headSeq = CloudSequence.zero
      let authExpiresAt = CloudSyncBytes.now() + 3_600_000
      let budget = CloudBudgetState(day: "fixture", requestsLeft: 6000, writesLeft: 12000, bytesLeft: 1024)
    }
    let hello = try CloudSyncCanonical.encode(CloudEvent(v: 1, type: "hello", id: UUID().uuidString.lowercased(),
      payload: .init(NativeRPCValue.parseJSON(CloudSyncCanonical.encode(Hello())))))
    let connections = CloudSyncRound5Connections()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFullHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    let signer: CloudSyncSigner = { CloudSyncBytes.base64(try CloudSyncFixtureAuth.key.signature(for: $0).rawRepresentation) }
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: signer, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration),
      fixtureSocketFactory: { _ in connections.open(); return CloudSyncRound3DroppingSocket(hello: hello) }, fixtureSocketRetryBase: .seconds(30))
    let client = try CloudSyncEngine(store: store, transport: transport, objects: transport, content: makeContent(), budget: budget,
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], signer: signer, verifySignature: { _, _ in }, firstUpload: true)
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain")))
    // The first step after launch always tries once (it lifts a network pause); spend it before the pause, so the pause
    // is what the stream meets. 14 Nov: before, a local refusal was stored as a day's block and hid this.
    _ = try? await client.pull()
    // The network is really down during the pause: nothing reaches the service. (A device-proven answer ends a
    // network pause by design, f73841f4, so an always-answering fixture let the engine's own account read lift it
    // before the stream's turn; whether the stream connected then depended on order.)
    CloudSyncFullHTTP.registry.set(nil)
    // The five-failure pause, here one the service asked to last 15 minutes (Retry-After, the longest stored wait).
    // 14 Nov: with the plain 16 s pause the test raced the engine's own timer. The fixture transport runs every
    // back-off 100 times faster (`fixtureClock`), so the engine's retry timer (CloudSyncEngine.armRetryNow) ended the
    // 16 s pause BY DESIGN after about 160 ms, and the stream's 4th reconnect (20+40+80+160 ms) landed at about the
    // same 300 ms this test watched: green or red by a few milliseconds, red more often on a busy machine. The window
    // watched must lie inside the pause; a 15-minute pause puts that timer about 9 s away.
    for _ in 0..<4 { try await budget.failed(CloudFailure.unavailable) }
    try await budget.failed(CloudFailure.unavailable, retryAfter: CloudSyncBytes.now() + 900_000)
    await client.startEvents()
    try await Task.sleep(for: .milliseconds(300))
    let during = try await budget.status()
    XCTAssertEqual(during.blocked, "network", "the window watched lies inside the pause")
    XCTAssertEqual(connections.count(), 0, "paused: the stream ended without connecting")
    CloudSyncFullHTTP.registry.set(server)
    await transport.networkOrWake()
    let deadline = Date().addingTimeInterval(5)
    while connections.count() == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertGreaterThan(connections.count(), 0, "the engine restarted the event stream after the wake")
    await client.stop()
  }
}

extension CloudSyncTests {
  /// S5: on a slow uplink no file is uploaded twice: files that would start after the upload window go to a fresh
  /// batch, so every finalize happens while its tickets are still valid.
  func testRound5SlowUplinkNeverUploadsAFileTwice() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    await server.slowUplink(uploadDelay: .milliseconds(100), ticketLifetimeMilliseconds: 380)
    let (client, store, _) = try await stagingEngine(scratch(), server: server,
      staging: .init(freeBytes: { _ in nil }, uploadWindow: .milliseconds(250)))
    var files: [CloudLocalBlob] = [], records: [CloudOperation] = []
    for _ in 0..<4 {
      let (file, _) = try await sealedAttachment(root: scratch())
      files.append(file); records.append(try referencing(file))
    }
    _ = try await client.enqueue(records, files: files, associations: zip(records, files).map { CloudFileAssociation(operationId: $0.opId, blobIds: [$1.blobId]) })
    _ = try await client.flush()
    XCTAssertEqual(try store.queuedCount(), 0)
    let log = await server.uploadLog
    for file in files { XCTAssertEqual(log.filter { $0 == file.blobId }.count, 1, "uploaded exactly once") }
  }
}

extension CloudSyncTests {
  /// S3 (Decker): a gap present when the inventory was published clears on every Mac once the publishing Mac
  /// heals it: it publishes a coverage correction through the feed, which other Macs adopt.
  func testRound5PublishedGapClearsOnAnotherMacAfterHealing() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (publisher, _, adapter) = try await engine(root: scratch(), server: server)
    await adapter.report(complete: false, gaps: ["Some notes could not be read."])
    let cut = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]),
      operations: [try op(entity: "with-a-gap")], files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: false, items: 1, bytes: 0, blockedReasons: ["Some notes could not be read."])])
    _ = try await publisher.bootstrap([cut])
    let (reader, _, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    let before = try await reader.coverage(sourceId: "fixture-source")
    XCTAssertFalse(before.complete, "the gap was in the published inventory")
    // Round 6 M1: the reader is complete locally but did not publish: it sends no correction.
    let segmentsBefore = await server.segmentCount()
    XCTAssertEqual(segmentsBefore, 0)
    await adapter.report(complete: true)
    try await publisher.retryParked(domains: ["memory"])
    _ = try await publisher.flush()
    _ = try await reader.pull()
    let after = try await reader.coverage(sourceId: "fixture-source")
    XCTAssertTrue(after.complete)
    XCTAssertFalse(after.blockedReasons.contains("Some notes could not be read."))
  }
}

extension CloudSyncTests {
  /// Item A: a record whose domain breaks the service's name rule is refused at enqueue with a typed error and
  /// nothing queued; the fixture service refuses such a pack exactly like the Worker.
  func testRound5DomainNamesFollowTheServiceRule() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let store = try makeStore(try scratch())
    let client = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["brain/memory/I01"],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in }, firstUpload: true)
    let base = try op(entity: "upper-case-domain")
    let upper = CloudOperation(v: 1, opId: base.opId, originDevice: base.originDevice, domain: "brain/memory/I01", entityId: base.entityId, revision: base.revision,
      parents: [], kind: base.kind, projectId: base.projectId, source: base.source, createdAt: base.createdAt, payload: base.payload, payloadHash: base.payloadHash)
    do { _ = try await client.enqueue([upper]); XCTFail("Upper-case domain queued") }
    catch let error as CloudDomainNameInvalid { XCTAssertEqual(error.domain, "brain/memory/I01") }
    XCTAssertEqual(try store.queuedCount(), 0)
    XCTAssertTrue(CloudWire.isValidDomainName("brain/memory/i01"))
    XCTAssertFalse(CloudWire.isValidDomainName("/memory"))
    XCTAssertFalse(CloudWire.isValidDomainName(String(repeating: "a", count: 129)))
    let segment = try await reviewBrainSegment([upper])
    do { _ = try await server.commit(segment); XCTFail("Fixture accepted an invalid domain") }
    catch { guard case CloudFailure.remote(let detail) = error else { return XCTFail("wrong refusal") }; XCTAssertEqual(detail.code, "invalid_request") }
  }
}

extension CloudSyncTests {
  /// A2 merge review must-fix 5: the service clock. Unknown before any answer; learned from an authenticated
  /// answer; a jump of more than a day is not adopted from one answer but is from a second that agrees; persisted.
  func testRound5ServiceClockOffsetRules() async throws {
    let root = try scratch(), store = try makeStore(root)
    XCTAssertNil(CloudSyncServiceClock.serviceTime(store))
    try CloudSyncServiceClock.observe(store, serverTime: 10_000_000, sentAt: 9_000_000, receivedAt: 9_000_200)
    XCTAssertEqual(CloudSyncServiceClock.serviceTime(store, now: 9_000_100), 10_000_000)
    let twoDays: Int64 = 2 * 86_400_000
    try CloudSyncServiceClock.observe(store, serverTime: 10_000_000 + twoDays, sentAt: 9_000_000, receivedAt: 9_000_200)
    XCTAssertEqual(CloudSyncServiceClock.serviceTime(store, now: 9_000_100), 10_000_000, "one implausible answer is not adopted")
    try CloudSyncServiceClock.observe(store, serverTime: 10_000_500 + twoDays, sentAt: 9_000_500, receivedAt: 9_000_700)
    XCTAssertEqual(CloudSyncServiceClock.serviceTime(store, now: 9_000_100), 10_000_000 + twoDays, "a second agreeing answer is")
    let reopened = try makeStore(root)
    XCTAssertEqual(CloudSyncServiceClock.serviceTime(reopened, now: 9_000_100), 10_000_000 + twoDays, "persisted across a restart")
    // Through the engine: an authenticated commit receipt teaches the clock; the port answers without blocking.
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, _, _) = try await engine(root: scratch(), server: server)
    XCTAssertNil(client.serviceTime())
    _ = try await client.enqueue([op(entity: "clock")])
    _ = try await client.flush()
    XCTAssertNotNil(client.serviceTime())
  }
}

extension CloudSyncTests {
  /// Item B: record content is stored once while in flight and leaves the sync store once settled (own record
  /// read back in Cloud, or another device's record applied) after this Mac holds an imported inventory; queued
  /// records keep it; setup staging rows are gone after setup; the queue keeps no second copy.
  func testRound5SettledRecordContentLeavesTheSyncStore() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let big = String(repeating: "content ", count: 2_000)
    let (publisher, publisherStore, _) = try await engine(root: scratch(), server: server)
    let baseline = try (0..<5).map { try op(entity: "baseline-\($0)", text: big) }
    _ = try await publisher.bootstrap([snapshot(baseline)])
    XCTAssertTrue(try publisherStore.rows("SELECT opId FROM snapshot_records").isEmpty, "setup staging is gone")
    let (reader, store, adapter) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    let applied = await adapter.count()
    XCTAssertEqual(applied, 5, "the adapter holds the content")
    let local = try op(entity: "queued-here", text: big)
    _ = try await reader.enqueue([local])
    XCTAssertTrue(try store.rows("SELECT payloadRef FROM outbox WHERE length(payloadRef)>0").isEmpty, "the queue keeps no second copy")
    // Queued: content kept. Settled: skeleton only.
    let queued = try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(local.opId.utf8)]).first?[0] ?? Data()
    XCTAssertEqual(try JSONDecoder().decode(CloudOperation.self, from: queued), local)
    for record in baseline {
      let row = try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(record.opId.utf8)]).first?[0] ?? Data()
      XCTAssertEqual(try JSONDecoder().decode(CloudOperation.self, from: row), CloudSyncStore.skeleton(record))
      XCTAssertLessThan(row.count, 1_000)
    }
    _ = try await reader.flush()
    let sent = try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(local.opId.utf8)]).first?[0] ?? Data()
    XCTAssertEqual(try JSONDecoder().decode(CloudOperation.self, from: sent), CloudSyncStore.skeleton(local), "own record settled after its read-back")
    XCTAssertTrue(try store.rows("SELECT opId FROM snapshot_records").isEmpty, "import staging is gone")
  }
}

extension CloudSyncTests {
  /// Item B safety: an inventory is never built from skeletons. After this Mac's records settled (content released),
  /// a new setup on an emptied account takes the content the adapter supplies again in its cut; and the
  /// verified-records path refuses rather than publish a skeleton.
  func testRound5InventoryIsNeverBuiltFromSkeletons() async throws {
    let first = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let record = try op(entity: "settled-then-republished", text: "the content")
    let (client, store, _) = try await engine(root: root, server: first)
    _ = try await client.bootstrap([snapshot([record])])
    let stub = try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(record.opId.utf8)]).first?[0] ?? Data()
    XCTAssertEqual(try JSONDecoder().decode(CloudOperation.self, from: stub), CloudSyncStore.skeleton(record), "settled: content released")
    // The account is emptied (a new service); the adapter supplies its records again in a new cut.
    let fresh = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (again, _, _) = try await engine(root: root, server: fresh)
    _ = try await again.bootstrap([snapshot([record])])
    let (reader, restored, adapter) = try await engine(root: scratch(), server: fresh)
    _ = try await reader.pull()
    let applied = await adapter.count()
    XCTAssertEqual(applied, 1, "the new inventory carried the full record, not its skeleton")
    XCTAssertEqual(try restored.operations().map(\.opId), [record.opId])
  }
}
