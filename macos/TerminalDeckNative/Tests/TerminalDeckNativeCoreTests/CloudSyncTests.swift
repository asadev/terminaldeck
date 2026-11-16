import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

final class CloudSyncTests: XCTestCase, @unchecked Sendable {
  let device = "33333333-3333-4333-8333-333333333333"
  let subject = "11111111-1111-4111-8111-111111111111"
  let rootKey = Data(0..<32)
  var roots: [URL] = []
  override func tearDown() {
    for root in roots { try? FileManager.default.removeItem(at: root) }
    roots = []
    super.tearDown()
  }
  func scratch() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-fixture-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }
  func op(id: String = UUID().uuidString.lowercased(), entity: String = "note", parents: [String] = [], time: Int64 = 1000,
          text: String = "fixture", version: Int = 1, origin: String? = nil, project: String? = "fixture-project") throws -> CloudOperation {
    let payload = CloudValue(.object([.init("text", .string(text))]))
    return .init(v: version, opId: id, originDevice: origin ?? device, domain: "memory", entityId: entity, revision: id,
      parents: parents, kind: .put, projectId: project, source: .init(sourceId: "fixture-source", recordId: id),
      createdAt: time, payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
  }
  func makeStore(_ root: URL) throws -> CloudSyncStore {
    try .init(root: root, subject: .init(issuer: "https://identity.test", sub: subject))
  }
  func makeContent() throws -> CloudSyncContent { let key = rootKey; return try .init(subject: subject, epoch: 1, keyProvider: { _ in key }) }
  func engine(root: URL, server: CloudSyncFixtureServer, packLimit: Int = CloudWire.maximumPlainChunkBytes, fault: @escaping CloudSyncFault = { _ in }) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncFixtureAdapter) {
    let store = try makeStore(root)
    let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"))
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { descriptor, _ in
        guard descriptor.signature == CloudSyncBytes.base64(Data(repeating: 7, count: 64)) else { throw CloudFailure.checksumMismatch }
      }, firstUpload: true, maximumPackBytes: packLimit, fault: fault)
    try await engine.register(adapter: adapter)
    return (engine, store, adapter)
  }
  func testS02AcknowledgedBytesSurviveFixtureServerRestart() async throws {
    let serverRoot = try scratch(), clientRoot = try scratch()
    var server = try CloudSyncFixtureServer(root: serverRoot, device: device)
    let (engine, store, _) = try await self.engine(root: clientRoot, server: server)
    _ = try await engine.enqueue([op()])
    let receipts = try await engine.flush()
    XCTAssertEqual(receipts.count, 1)
    XCTAssertEqual(try store.pending().count, 0)
    server = try CloudSyncFixtureServer(root: serverRoot, device: device)
    let page = try await server.changes(after: .zero, limit: 64)
    XCTAssertEqual(page.segments.count, 1)
    let bytes = try await server.download(try XCTUnwrap(page.segments.first?.getUrl), maximumBytes: 262_144)
    XCTAssertEqual(CloudSyncBytes.hash(bytes), receipts[0].receipt.sha256)
    let row = try XCTUnwrap(store.rows("SELECT bytes FROM segments").first)
    let segment = try JSONDecoder().decode(CloudSegment.self, from: row[0])
    XCTAssertEqual(bytes, try CloudSyncBytes.unbase64(segment.ciphertext))
  }
  func testS03StableIDsApplyOnceAndChangedBytesRefused() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (sender, senderStore, _) = try await self.engine(root: scratch(), server: server)
    let first = try op()
    _ = try await sender.enqueue([first, first])
    _ = try await sender.flush()
    _ = try await sender.enqueue([first])
    let noMore = try await sender.flush()
    XCTAssertTrue(noMore.isEmpty)
    let (reader, store, adapter) = try await self.engine(root: scratch(), server: server)
    _ = try await reader.pull()
    _ = try await reader.pull()
    let effects = await adapter.effectCount()
    XCTAssertEqual(effects, 1)
    XCTAssertEqual(try store.operations(), [first])
    let echo = try await reader.enqueue([first])
    XCTAssertEqual(echo.queued, 0)
    do { _ = try await sender.enqueue([op(id: first.opId, text: "different")]); XCTFail("ID reuse was accepted") }
    catch { XCTAssertEqual(error as? CloudFailure, .idReused) }
    let row = try XCTUnwrap(senderStore.rows("SELECT bytes FROM segments").first)
    let segment = try JSONDecoder().decode(CloudSegment.self, from: row[0])
    let receipt = try await server.commit(segment)
    XCTAssertEqual(receipt.seq, CloudSequence(1))
    let changed = Data("changed fixture bytes".utf8)
    let d = segment.descriptor
    let conflicting = CloudSegment(descriptor: .init(segmentId: d.segmentId, requestId: d.requestId, storageClass: d.storageClass,
      purpose: d.purpose, domains: d.domains, keyEpoch: d.keyEpoch, sha256: CloudSyncBytes.hash(changed), bytes: Int64(changed.count),
      opCount: d.opCount, format: d.format, signature: d.signature), ciphertext: CloudSyncBytes.base64(changed))
    do { _ = try await server.commit(conflicting); XCTFail("Segment reuse was accepted") }
    catch { XCTAssertEqual(error as? CloudFailure, .idReused) }
  }
  func testS04ConcurrentSiblingsAndClockSkewRetainHistory() throws {
    let parent = try op(time: 99_999), left = try op(parents: [parent.opId], time: 1, text: "left")
    let right = try op(parents: [parent.opId], time: -99_999, text: "right", origin: "44444444-4444-4444-8444-444444444444")
    XCTAssertNotEqual(left.originDevice, right.originDevice)
    let store = try makeStore(scratch())
    _ = try store.enqueue([left, right, parent])
    XCTAssertEqual(Set(try CloudSyncPack.heads(store.operations()).map(\.opId)), [left.opId, right.opId])
    let resolution = try op(parents: [left.opId, right.opId], time: -999_999, text: "resolved")
    _ = try store.enqueue([resolution])
    XCTAssertEqual(try CloudSyncPack.heads(store.operations()).map(\.opId), [resolution.opId])
    XCTAssertEqual(try store.operations().count, 4)
    XCTAssertEqual(try store.operations().first { $0.opId == parent.opId }, parent)
  }
  func testS06TruncatedPackBadTagBadHashUnknownSchemaApplyNothing() async throws {
    let mutations = ["truncated", "tag", "hash", "schema"]
    for mutation in mutations {
      let server = try CloudSyncFixtureServer(root: scratch(), device: device)
      let content = try makeContent()
      let operation = try op(version: mutation == "schema" ? 2 : 1)
      let plain = try CloudSyncCanonical.encode([operation])
      let id = UUID().uuidString.lowercased()
      let envelope = try await content.seal(plain, blobId: id, storageClass: .brain, purpose: .brain, epoch: 1, codec: .identity)
      var bytes = try CloudSyncCanonical.encode(envelope)
      if mutation == "truncated" { bytes = bytes.dropLast(8) }
      if mutation == "tag" {
        let bad = CloudContentEnvelope(v: 1, suite: envelope.suite, storageClass: .brain, purpose: .brain, epoch: 1, blobId: id,
          codec: .identity, plainBytes: envelope.plainBytes, nonce: envelope.nonce, ciphertext: envelope.ciphertext,
          tag: CloudSyncBytes.base64(Data(repeating: 0, count: 16)))
        bytes = try CloudSyncCanonical.encode(bad)
      }
      let descriptor = CloudSegmentDescriptor(segmentId: id, requestId: UUID().uuidString.lowercased(), storageClass: .brain, purpose: .brain,
        domains: ["memory"], keyEpoch: 1, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count), opCount: 1,
        format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64)))
      _ = try await server.commit(.init(descriptor: descriptor, ciphertext: CloudSyncBytes.base64(bytes)))
      if mutation == "hash" { await server.setCorruption(Data("corrupt".utf8)) }
      let (reader, store, adapter) = try await self.engine(root: scratch(), server: server)
      do { _ = try await reader.pull(); XCTFail("Invalid \(mutation) imported") } catch { XCTAssertNotNil(error as? CloudFailure) }
      let count = await adapter.count()
      XCTAssertEqual(count, 0, mutation)
      let cursor: CloudSequence = try store.value("brainSeq") ?? .zero
      XCTAssertEqual(cursor, .zero, mutation)
      XCTAssertTrue(try store.operations().isEmpty, mutation)
    }
  }
  func testS07OfflineRestartAndLostACKUploadExactlyOnce() async throws {
    let root = try scratch(), serverRoot = try scratch()
    var server = try CloudSyncFixtureServer(root: serverRoot, device: device)
    let (first, _, _) = try await self.engine(root: root, server: server)
    _ = try await first.enqueue([op(), op(entity: "second", text: "same words")])
    await server.setLostACK()
    do { _ = try await first.flush(); XCTFail("Lost ACK should leave queue pending") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    server = try CloudSyncFixtureServer(root: serverRoot, device: device)
    let (reopened, store, _) = try await self.engine(root: root, server: server)
    XCTAssertEqual(try store.pending().count, 2)
    _ = try await reopened.flush()
    XCTAssertTrue(try store.pending().isEmpty)
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1)
    let (reader, _, adapter) = try await self.engine(root: scratch(), server: server)
    _ = try await reader.pull()
    let count = await adapter.count()
    XCTAssertEqual(count, 2)
    let progress = try await reader.restoreProgress()
    XCTAssertEqual(progress.applied, 2)
  }
  func testS20BudgetAndAuthFailuresStayQueuedAcrossRestart() async throws {
    for failure: CloudFailure in [.budgetPaused, .remote(.init(code: "token_expired", message: "Fixture auth expired.", retryable: false, requestId: UUID().uuidString.lowercased()))] {
      let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
      let (engine, store, _) = try await self.engine(root: root, server: server)
      _ = try await engine.enqueue([op()])
      await server.setFailure(failure)
      do { _ = try await engine.flush(); XCTFail("Failed transport returned success") } catch { XCTAssertEqual(error as? CloudFailure, failure) }
      let progress = try await engine.restoreProgress()
      XCTAssertEqual(progress.queued, 1)
      XCTAssertEqual(progress.blocked, 1)
      let ready = try await engine.contextReady(projectId: "fixture-project")
      XCTAssertFalse(ready.verified)
      XCTAssertEqual(try makeStore(root).pending().count, 1)
      let budget = CloudSyncBudget(store: store, now: { 86_400_000 })
      try await budget.failed(failure, httpStatus: failure == .budgetPaused ? 429 : 401)
      let reopenedBudget = CloudSyncBudget(store: try makeStore(root), now: { 86_400_000 })
      do { try await reopenedBudget.reserve(http: 1); XCTFail("Restart bypassed block") } catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
      try await reopenedBudget.resume(networkOrWake: true)
      if failure == .budgetPaused {
        do { try await reopenedBudget.reserve(http: 1); XCTFail("Wake bypassed the slow-down") } catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
      } else {
        // MAC-NEXT-12 + 14 Nov: an expired token is a timed retry, never a stored block, so a wake tries again (the
        // old build passed here only because its own local refusal was stored as a day's block).
        try await reopenedBudget.reserve(http: 1)
      }
    }
  }
  func testKillAfterLocalWriteBeforeReceiptPreservesOperations() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, _, _) = try await self.engine(root: root, server: server, fault: { if $0 == .afterLocalWrite { throw CloudFailure.unavailable } })
    let operation = try op()
    do { _ = try await engine.enqueue([operation]); XCTFail("Kill point missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let (reopened, store, _) = try await self.engine(root: root, server: server)
    XCTAssertEqual(try store.pending(), [operation])
    _ = try await reopened.enqueue([operation])
    _ = try await reopened.flush()
    let count = await server.segmentCount()
    XCTAssertEqual(count, 1)
  }
  func testKillDuringApplyReusesPreparationAndEffectsOnce() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (sender, _, _) = try await self.engine(root: scratch(), server: server)
    _ = try await sender.enqueue([op()]); _ = try await sender.flush()
    let (reader, store, adapter) = try await self.engine(root: root, server: server, fault: { if $0 == .duringApply { throw CloudFailure.unavailable } })
    do { _ = try await reader.pull(); XCTFail("Kill point missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let count = await adapter.count()
    XCTAssertEqual(count, 1)
    XCTAssertEqual(try store.rows("SELECT segmentId FROM prepare_journal").count, 1)
    let journalBytes = try XCTUnwrap(store.rows("SELECT bytes FROM prepare_journal").first)[0]
    let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: journalBytes) as? [String: Any])
    let oldPlan = try XCTUnwrap((journal["prepared"] as? [[String: Any]])?.first?["preparationId"] as? String)
    let cursor: CloudSequence = try store.value("brainSeq") ?? .zero
    XCTAssertEqual(cursor, .zero)
    let (reopened, _, restoredAdapter) = try await self.engine(root: root, server: server)
    let recovered = try await reopened.pull()
    XCTAssertEqual(recovered.first?.preparationId, oldPlan)
    let effects = await restoredAdapter.effectCount()
    XCTAssertEqual(effects, 0)
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(1))
    XCTAssertTrue(try store.rows("SELECT segmentId FROM prepare_journal").isEmpty)
  }
  func snapshot(_ operations: [CloudOperation]) -> CloudDomainSnapshot {
    .init(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "10"]), operations: operations, files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: operations.count, bytes: 0, blockedReasons: [])])
  }
  func testKillAfterUploadAndFinalizeResumesSameObjects() async throws {
    for point: CloudSyncKillPoint in [.afterUpload, .afterFinalize] {
      let root = try scratch(), serverRoot = try scratch(), snapshot = self.snapshot([try op()])
      var server = try CloudSyncFixtureServer(root: serverRoot, device: device)
      let (first, _, _) = try await self.engine(root: root, server: server, fault: { if $0 == point { throw CloudFailure.unavailable } })
      do { _ = try await first.bootstrap([snapshot]); XCTFail("Kill point missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
      server = try CloudSyncFixtureServer(root: serverRoot, device: device)
      let (reopened, store, _) = try await self.engine(root: root, server: server)
      let receipt = try await reopened.bootstrap([snapshot])
      XCTAssertTrue(receipt.published)
      XCTAssertTrue(try store.pending().isEmpty)
      let objects = await server.objectCount()
      XCTAssertEqual(objects, 2)
      let (other, otherStore, adapter) = try await self.engine(root: scratch(), server: server)
      _ = try await other.pull()
      let count = await adapter.count()
      XCTAssertEqual(count, 1)
      // Round 5 item B: after an imported inventory, a settled record keeps its skeleton (id, author, hashes),
      // not its content; the adapter holds the content (count above).
      XCTAssertEqual(try otherStore.operations(), snapshot.operations.map(CloudSyncStore.skeleton))
    }
  }
  func testKillAfterCommitBeforeLocalACKUsesIdenticalSegment() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (first, store, _) = try await self.engine(root: root, server: server, fault: { if $0 == .afterCommit { throw CloudFailure.unavailable } })
    _ = try await first.enqueue([op()])
    do { _ = try await first.flush(); XCTFail("Kill point missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let before = try store.unacknowledged().first?.0
    let (reopened, _, _) = try await self.engine(root: root, server: server)
    _ = try await reopened.flush()
    let count = await server.segmentCount()
    XCTAssertEqual(count, 1)
    let row = try XCTUnwrap(store.rows("SELECT bytes FROM segments").first)
    XCTAssertEqual(try JSONDecoder().decode(CloudSegment.self, from: row[0]), before)
    XCTAssertTrue(try store.pending().isEmpty)
  }
  func testBootstrapNonemptyImportsLocalVersionsWithoutReplacingCheckpoint() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (first, _, _) = try await self.engine(root: scratch(), server: server)
    let initial = try await first.bootstrap([snapshot([op(text: "cloud")])])
    let (second, store, adapter) = try await self.engine(root: scratch(), server: server)
    let imported = try await second.bootstrap([snapshot([op(text: "local")])])
    XCTAssertEqual(imported.checkpointId, initial.checkpointId)
    XCTAssertTrue(try store.pending().isEmpty)
    _ = try await second.pull()
    let count = await adapter.count()
    XCTAssertEqual(count, 2)
    XCTAssertEqual(try store.operations().count, 2)
    let readiness = try await second.contextReady(projectId: "fixture-project")
    XCTAssertTrue(readiness.verified)
    XCTAssertEqual(readiness.sourceCounts.records, 2)
  }
  func testSourceIdentityCannotBeReplacedOnRestart() throws {
    let root = try scratch(), store = try makeStore(root)
    try store.saveCursor(sourceId: "fixture", identity: "store-generation-one", offset: "20", digest: "hash")
    let reopened = try makeStore(root)
    XCTAssertEqual(try reopened.cursor(sourceId: "fixture")?.offset, "20")
    XCTAssertThrowsError(try reopened.saveCursor(sourceId: "fixture", identity: "different", offset: "0", digest: nil))
    XCTAssertEqual(try reopened.cursor(sourceId: "fixture")?.identity, "store-generation-one")
  }
  /// 14 Nov (owner: "remove this counter thing completely"): no daily ceiling and nothing counted; the five-failure
  /// pause stays, survives a restart and ends with a wake.
  func testPersistedHTTPFramePackCapsAndFiveFailureStop() async throws {
    let root = try scratch(), store = try makeStore(root)
    let budget = CloudSyncBudget(store: store, now: { 86_400_000 })
    try await budget.reserve(http: 50_000, frames: 50_000, packs: 50_000)
    let second = CloudSyncBudget(store: try makeStore(root), now: { 86_400_000 })
    try await second.reserve(http: 1, frames: 1, packs: 1)
    let state = try await second.status()
    XCTAssertEqual(state.http, 0); XCTAssertEqual(state.frames, 0); XCTAssertEqual(state.packs, 0)
    XCTAssertNil(state.blocked)
    try await second.reserve(http: 1)
    let nextDay = CloudSyncBudget(store: store, now: { 172_800_000 })
    try await nextDay.reserve(http: 1)
    for _ in 0..<5 { try await nextDay.failed(CloudFailure.unavailable) }
    let blocked = try await nextDay.status()
    XCTAssertEqual(blocked.blocked, "network")
    let reopened = CloudSyncBudget(store: try makeStore(root), now: { 172_800_000 })
    do { try await reopened.reserve(http: 1); XCTFail("Restart reset failures") } catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
    try await reopened.resume(networkOrWake: true)
    try await reopened.reserve(http: 1)
    let resumed = try await reopened.status()
    XCTAssertEqual(resumed.http, 0)
    XCTAssertNil(resumed.blocked)
  }
  func testBaselineChangedKeepsBothSnapshots() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (first, _, _) = try await self.engine(root: scratch(), server: server)
    let initial = try await first.bootstrap([snapshot([op(text: "winning snapshot")])])
    await server.pretendEmptyOnce()
    let (second, store, adapter) = try await self.engine(root: scratch(), server: server)
    let receipt = try await second.bootstrap([snapshot([op(text: "concurrent snapshot")])])
    XCTAssertEqual(receipt.checkpointId, initial.checkpointId)
    _ = try await second.pull()
    XCTAssertEqual(try store.operations().count, 2)
    let count = await adapter.count()
    XCTAssertEqual(count, 2)
    XCTAssertTrue(try store.pending().isEmpty)
  }

  func testDurabilityPragmasAndAtomicBatchRejection() throws {
    let store = try makeStore(scratch())
    XCTAssertEqual(String(decoding: try XCTUnwrap(store.rows("PRAGMA synchronous").first)[0], as: UTF8.self), "2")
    XCTAssertEqual(String(decoding: try XCTUnwrap(store.rows("PRAGMA fullfsync").first)[0], as: UTF8.self), "1")
    XCTAssertEqual(String(decoding: try XCTUnwrap(store.rows("PRAGMA journal_mode").first)[0], as: UTF8.self), "wal")
    let original = try op()
    _ = try store.enqueue([original])
    XCTAssertThrowsError(try store.enqueue([op(entity: "new"), op(id: original.opId, text: "conflict")]))
    XCTAssertEqual(try store.pending(), [original])
    XCTAssertEqual(try store.operations(), [original])
  }

  func testEventHintsCoalesceWithAutomaticLocalSends() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store, _) = try await self.engine(root: scratch(), server: server)
    // Automatic sends wait for a verified first inventory (review item 2); establish it first.
    _ = try await engine.bootstrap([snapshot([op(entity: "baseline")])])
    await engine.startEvents()
    for index in 0..<10 {
      _ = try await engine.enqueue([op(entity: "automatic-\(index)")])
      await server.hint()
    }
    let deadline = Date().addingTimeInterval(10)
    while !(try store.pending().isEmpty), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(try store.pending().isEmpty)
    XCTAssertEqual(try store.operations().count, 11)
    _ = try await engine.enqueue([op(entity: "after-burst")])
    await server.hint()
    let later = Date().addingTimeInterval(10)
    while !(try store.pending().isEmpty), Date() < later { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(try store.pending().isEmpty)
    XCTAssertEqual(try store.operations().count, 12)
    await engine.stop()
  }

  func testNestedCheckpointTreeKeepsEveryOperation() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let rows = try (0..<40).map { try op(entity: "tree-\($0)", text: String(repeating: "a", count: 100)) }
    let (sender, _, _) = try await self.engine(root: scratch(), server: server, packLimit: 1024)
    let receipt = try await sender.bootstrap([snapshot(rows)])
    XCTAssertTrue(receipt.published)
    let objects = await server.objectCount()
    XCTAssertGreaterThan(objects, 17)
    let (reader, store, adapter) = try await self.engine(root: scratch(), server: server)
    _ = try await reader.pull()
    let count = await adapter.count()
    XCTAssertEqual(count, 40)
    XCTAssertEqual(Set(try store.operations().map(\.opId)), Set(rows.map(\.opId)))
  }
  func testImportedOperationKeepsOriginalAuthorAndBytes() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let original = try op(origin: "44444444-4444-4444-8444-444444444444")
    let (sender, _, _) = try await self.engine(root: scratch(), server: server)
    _ = try await sender.enqueue([original])
    _ = try await sender.flush()
    let (reader, store, _) = try await self.engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertEqual(try store.operations(), [original])
    XCTAssertEqual(try store.operations().first?.originDevice, original.originDevice)
  }

  func testCatchupSettlesLostACKWithoutEchoingVerifiedOperations() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (first, _, _) = try await self.engine(root: root, server: server, fault: { if $0 == .afterCommit { throw CloudFailure.unavailable } })
    _ = try await first.enqueue([op()])
    do { _ = try await first.flush(); XCTFail("Kill point missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let (reader, store, _) = try await self.engine(root: root, server: server)
    _ = try await reader.pull()
    let calls = await server.calls
    let receipts = try await reader.flush()
    let after = await server.calls
    XCTAssertTrue(receipts.isEmpty)
    XCTAssertEqual(calls, after)
    XCTAssertTrue(try store.pending().isEmpty)
  }

  func testProtectedFeedDoesNotBlockBrainOrAdvanceProtectedCursor() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let opaque = Data("fixture-only protected content".utf8)
    let descriptor = CloudSegmentDescriptor(segmentId: UUID().uuidString.lowercased(), requestId: UUID().uuidString.lowercased(),
      storageClass: .secrets, purpose: .secret, domains: ["secrets/api"], keyEpoch: 1, sha256: CloudSyncBytes.hash(opaque),
      bytes: Int64(opaque.count), opCount: 1, format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64)))
    _ = try await server.commit(.init(descriptor: descriptor, ciphertext: CloudSyncBytes.base64(opaque)))
    let (brain, _, adapter) = try await self.engine(root: scratch(), server: server)
    _ = try await brain.enqueue([op()])
    _ = try await brain.flush()
    let progress = try await brain.restoreProgress()
    let count = await adapter.count()
    XCTAssertEqual(progress.brainSeq, CloudSequence(2))
    XCTAssertEqual(progress.secretsSeq, .zero)
    XCTAssertEqual(count, 1)
  }

  func testQueuedGlobalMemoryPreventsProjectReadiness() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, _, _) = try await self.engine(root: scratch(), server: server)
    _ = try await engine.bootstrap([snapshot([op()])])
    let before = try await engine.contextReady(projectId: "fixture-project")
    XCTAssertTrue(before.verified)
    _ = try await engine.enqueue([op(entity: "global-rule", project: nil)])
    let after = try await engine.contextReady(projectId: "fixture-project")
    XCTAssertFalse(after.verified)
  }

  /// One object whose upload link expires is renewed once; if the renewed link expires too, the send fails and
  /// the record stays queued. (Before the 16-per-batch uploads (8197a771) this went through a first inventory of
  /// two objects uploaded one after the other, so "the next two uploads expire" hit the same object twice; with
  /// batching the two expiries land on two different objects, each renewed once, and the setup rightly
  /// succeeds. The rule is now exercised with exactly one object: a live file.)
  func testExpiredUploadRenewsOnceAndKeepsQueueOnRepeatedExpiry() async throws {
    for expirations in [1, 2] {
      let server = try CloudSyncFixtureServer(root: scratch(), device: device)
      let (engine, store, _) = try await self.engine(root: scratch(), server: server)
      let (file, _) = try await sealedAttachment(root: scratch())
      _ = try await engine.enqueue([referencing(file)], files: [file])
      await server.expireUploads(expirations)
      do {
        _ = try await engine.flush()
        XCTAssertEqual(expirations, 1)
        XCTAssertTrue(try store.pending().isEmpty)
      } catch {
        XCTAssertEqual(expirations, 2)
        XCTAssertEqual(error as? CloudFailure, .unavailable)
        XCTAssertEqual(try store.pending().count, 1)
      }
      let attempts = await server.uploadAttempts
      XCTAssertEqual(attempts, 2, "the expired attempt and exactly one renewal")
    }
  }

  /// 13 Nov, the owner's first upload: one 429 rate_limited at GET /v1/changes left `blocked: rate` with a retry time
  /// three seconds later, and every send after that time was still refused here (`budgetPaused`) until a wake, a
  /// network change or a new sign-in. A slow-down is a short wait that ends by itself, with or without Retry-After.
  func testRateLimitIsAShortWaitThatEndsByItselfNeverADay() async throws {
    let root = try scratch(), store = try makeStore(root)
    final class Clock: @unchecked Sendable { var now: Int64 = 1_794_553_711_000 }
    let clock = Clock()
    let budget = CloudSyncBudget(store: store, now: { clock.now })
    let rate = CloudFailure.remote(.init(code: "rate_limited", message: "Fixture rate limit.", retryable: true,
      requestId: UUID().uuidString.lowercased()))
    // With the service's Retry-After (3 s): exactly that wait, then sending goes on with no wake, network change or press.
    try await budget.failed(rate, httpStatus: 429, retryAfter: clock.now + 3_000)
    var status = try await budget.status()
    XCTAssertEqual(status.blocked, "rate")
    XCTAssertEqual(status.retryAt, clock.now + 3_000)
    do { try await budget.reserve(packs: 1); XCTFail("sent inside the service's window") } catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
    clock.now += 3_000
    try await budget.reserve(packs: 1)
    status = try await budget.status()
    XCTAssertNil(status.blocked)
    // Without Retry-After: a back-off of seconds that grows, never the next day; a huge stated time is capped.
    try await budget.failed(rate, httpStatus: 429)
    status = try await budget.status()
    XCTAssertEqual(status.blocked, "rate")
    XCTAssertLessThanOrEqual(status.retryAt - clock.now, 10_000)
    for _ in 0..<20 { try await budget.failed(rate, httpStatus: 429) }
    status = try await budget.status()
    XCTAssertLessThanOrEqual(status.retryAt - clock.now, 300_500)
    try await budget.failed(rate, httpStatus: 429, retryAfter: clock.now + 86_400_000)
    status = try await budget.status()
    XCTAssertEqual(status.retryAt - clock.now, 900_000, "a slow-down is never a day's pause")
    XCTAssertNotEqual(status.blocked, "budget")
  }
  /// The exact state the owner's Mac was left in: `{"blocked":"rate",...,"retryAt":<past>}` read by a new build.
  func testAStoredPastSlowDownNoLongerRefusesSending() async throws {
    let root = try scratch(), store = try makeStore(root)
    var stored = CloudSyncBudgetSnapshot(day: 20770)
    stored.http = 200; stored.frames = 36; stored.packs = 28; stored.failures = 1
    stored.blocked = "rate"; stored.retryAt = 1_794_553_714_015
    try store.set("budget", stored)
    let budget = CloudSyncBudget(store: store, now: { 1_794_554_000_000 })
    try await budget.reserve(packs: 1)
    let status = try await budget.status()
    XCTAssertNil(status.blocked)
    XCTAssertEqual(status.packs, 0, "14 Nov: the old counters are dropped, nothing is counted")
  }
  /// The account's own reads never wait on the upload's local blocks: a slow-down refuses packs here, never the
  /// status read the Cloud page and the sign-in depend on. 14 Nov: a `budget_paused` answer is such a slow-down.
  func testAccountReadsNeverWaitOnTheUploadBudget() async throws {
    let root = try scratch(), store = try makeStore(root)
    let budget = CloudSyncBudget(store: store, now: { 86_400_000 })
    let rate = CloudFailure.remote(.init(code: "rate_limited", message: "Fixture rate limit.", retryable: true,
      requestId: UUID().uuidString.lowercased()))
    try await budget.failed(rate, httpStatus: 429, retryAfter: 86_460_000)
    try await budget.reserveAccount()
    try await budget.failed(CloudFailure.budgetPaused, httpStatus: 429)
    do { try await budget.reserve(http: 1); XCTFail("upload ran past the slow-down") } catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
    try await budget.reserveAccount()
    let status = try await budget.status()
    XCTAssertEqual(status.http, 0)
    XCTAssertEqual(status.blocked, "rate")
  }

  func testRateLimitRetryHonorsWindowWithoutResettingDailyCounters() async throws {
    let root = try scratch(), store = try makeStore(root)
    let budget = CloudSyncBudget(store: store, now: { 86_400_000 })
    try await budget.reserve(http: 4)
    try await budget.failed(CloudFailure.remote(.init(code: "rate_limited", message: "Fixture rate limit.", retryable: true,
      requestId: UUID().uuidString.lowercased())), httpStatus: 429, retryAfter: 86_410_000)
    try await budget.resume(networkOrWake: false, userRetry: true)
    do { try await budget.reserve(http: 1); XCTFail("Retry bypassed the server window") } catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
    let later = CloudSyncBudget(store: try makeStore(root), now: { 86_420_000 })
    try await later.resume(networkOrWake: false, userRetry: true)
    try await later.reserve(http: 1)
    let status = try await later.status()
    XCTAssertEqual(status.http, 0)
    XCTAssertNil(status.blocked)
  }

}
