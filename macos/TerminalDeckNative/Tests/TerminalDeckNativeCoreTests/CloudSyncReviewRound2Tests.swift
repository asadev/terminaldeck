import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

// Review round 2 regressions. Fixture-only data; no real account, Keychain or network.
extension CloudSyncTests {
  /// Must-fix 2: a reader whose cursor moved before the raced first inventory landed imports that
  /// inventory before the publisher's later child edit, never after it.
  func testRound2ReaderPastZeroImportsLateFirstInventoryBeforeItsChildren() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    await server.withoutZeroHeadGuard()
    let early = try op(entity: "reader-early"), base = try op(entity: "shared", text: "base")
    let (reader, readerStore, readerAdapter) = try await engine(root: scratch(), server: server)
    _ = try await reader.enqueue([early])
    _ = try await reader.flush()
    XCTAssertEqual(try readerStore.value("brainSeq"), CloudSequence(1))
    XCTAssertNotEqual(try readerStore.value("inventoryVerified") as Bool?, true)
    let (publisher, _, _) = try await engine(root: scratch(), server: server)
    await server.pretendEmptyOnce()
    let receipt = try await publisher.bootstrap([snapshot([base])])
    XCTAssertEqual(receipt.throughSeq, .zero)
    let child = try op(entity: "shared", parents: [base.opId], text: "edited")
    _ = try await publisher.enqueue([child])
    _ = try await publisher.flush()
    _ = try await reader.pull()
    let order = await readerAdapter.appliedOrder()
    let baseIndex = try XCTUnwrap(order.firstIndex(of: base.opId)), childIndex = try XCTUnwrap(order.firstIndex(of: child.opId))
    XCTAssertLessThan(baseIndex, childIndex)
    XCTAssertEqual(Set(order), [early.opId, base.opId, child.opId])
    XCTAssertEqual(order.count, 3)
    XCTAssertEqual(try readerStore.value("inventoryVerified"), true)
    XCTAssertEqual(try CloudSyncPack.heads(readerStore.operations().filter { $0.entityId == "shared" }).map(\.opId), [child.opId])
  }

  /// Must-fix 1: a second Mac whose feed cursor already moved holds its edit only until another Mac
  /// publishes the first inventory; the next hint then imports it and the edit sends automatically.
  func testRound2SecondMacEditSendsAutomaticallyAfterAnotherMacPublishesFirstInventory() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    _ = try await server.commit(reviewBrainSegment([op(entity: "feed-first")]))
    let (second, store, _) = try await engine(root: scratch(), server: server)
    await second.startEvents()
    let caughtUp = Date().addingTimeInterval(10)
    while (try store.value("brainSeq") as CloudSequence?) != CloudSequence(1), Date() < caughtUp { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(1))
    let edit = try op(entity: "second-mac-edit")
    _ = try await second.enqueue([edit])
    try await Task.sleep(for: .milliseconds(200))
    let held = await server.segmentCount()
    XCTAssertEqual(held, 1, "No inventory yet: the edit stays queued")
    let (first, _, _) = try await engine(root: scratch(), server: server)
    let receipt = try await first.bootstrap([snapshot([op(entity: "first-mac")])])
    XCTAssertTrue(receipt.published)
    await server.hint()
    let deadline = Date().addingTimeInterval(10)
    while !(try store.pending().isEmpty), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertTrue(try store.pending().isEmpty)
    XCTAssertEqual(try store.value("inventoryVerified"), true)
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 3)
    await second.stop()
  }
}

extension CloudSyncTests {
  /// Should-fix 4: a public pull that arrives while a bootstrap is suspended is refused before it can
  /// read or rebind the registration, so the one-time sign-in reset is never spent underneath it.
  func testRound2RegistrationIsNotRefreshedUnderASuspendedOperation() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, _) = try await engine(root: scratch(), server: server)
    let replacement = "55555555-5555-4555-8555-555555555555"
    let outcome = CloudSyncRound2Box()
    await server.beforeNextCheckpoint { [client, server, device] in
      await server.switchDevice(replacement)
      do { _ = try await client.pull(); await outcome.set("accepted") }
      catch { await outcome.set(error as? CloudFailure == .unavailable ? "refused" : "other") }
      await server.switchDevice(device)
    }
    let receipt = try await client.bootstrap([snapshot([op()])])
    XCTAssertTrue(receipt.published)
    let result = await outcome.value
    XCTAssertEqual(result, "refused")
    XCTAssertEqual(try store.value("activeOutboxDevice") as String?, device)
    XCTAssertNil(try store.value("changedOutboxRegistration") as String?)
  }
}

actor CloudSyncRound2Box {
  var value: String?
  func set(_ new: String) { value = new }
}

/// Test-only edit source: adds one new local edit every time a feed segment is applied.
final class CloudSyncRound2EditFeeder: @unchecked Sendable {
  private let lock = NSLock()
  private var edits: [CloudOperation]
  private(set) var used = 0
  var store: CloudSyncStore?
  init(_ edits: [CloudOperation]) { self.edits = edits }
  func feed() throws {
    lock.lock(); defer { lock.unlock() }
    guard let store, used < edits.count else { return }
    _ = try store.enqueue([edits[used]])
    used += 1
  }
  func count() -> Int { lock.lock(); defer { lock.unlock() }; return used }
}

extension CloudSyncTests {
  /// Should-fix 7: while edits keep arriving, the feed-first inventory still publishes after a few
  /// catch-up rounds instead of re-entering catch-up for as long as edits arrive.
  func testRound2FeedFirstInventoryPublishesWhileEditsKeepArriving() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    _ = try await server.commit(reviewBrainSegment([op(entity: "feed-first")]))
    let feeder = CloudSyncRound2EditFeeder(try (0..<60).map { try op(entity: "steady-\($0)") })
    let (client, store, _) = try await engine(root: scratch(), server: server, fault: { if $0 == .duringApply { try feeder.feed() } })
    feeder.store = store
    let receipt = try await client.bootstrap([snapshot([op(entity: "local-cut")])])
    XCTAssertTrue(receipt.published)
    XCTAssertGreaterThan(receipt.throughSeq, .zero)
    XCTAssertNil(try store.value("bootstrapInProgress") as String?)
    XCTAssertEqual(try store.value("inventoryVerified"), true)
    // Bounded: about two edits per round over three rounds plus the post-publish drain, never the whole stream.
    XCTAssertLessThan(feeder.count(), 30)
  }
}

extension CloudSyncTests {
  /// Should-fix 3a: an expired finalize ticket is repaired inline (re-prepare, re-upload once), with no
  /// account-wide block and no recorded failure.
  func testRound2ExpiredFinalizeTicketIsRepairedOnceWithoutBlocking() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let (client, store) = try await reviewRegisteredClient(root, server: server, registration: device, signatureByte: 7)
    let (file, bytes) = try await sealedAttachment(root: scratch())
    _ = try await client.enqueue([referencing(file)], files: [file])
    await server.failFinalizationOnce(code: "code_expired", retryable: false)
    _ = try await client.flush()
    XCTAssertEqual(try store.queuedCount(), 0)
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1)
    let state = try await CloudSyncBudget(store: store).status()
    XCTAssertNil(state.blocked)
    XCTAssertEqual(state.failures, 0)
    let refs = try await server.readBlobs(ids: [file.blobId])
    let remote = try await server.download(try XCTUnwrap(refs.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    XCTAssertEqual(remote, bytes)
  }

  /// Should-fix 3b: a protected-only finalize refusal leaves the saved-password segment queued and
  /// reported, while memory edits behind it still send and nothing blocks the account.
  func testRound2ProtectedOnlyFinalizeRefusalWaitsWithoutBlockingMemory() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let root = try scratch()
    let (client, store, _) = try await reviewProtectedClient(root, server: server, content: protected)
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory"), domain: "memory"))
    let secret = try await reviewProtectedOperation(protected)
    let id = UUID().uuidString.lowercased()
    let envelope = try await protected.seal(Data("fixture-only sealed file".utf8), blobId: id, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
    let sealed = try CloudSyncCanonical.encode(envelope), ref = CloudSyncBytes.blob(sealed, envelope: envelope)
    let path = try scratch().appendingPathComponent(id)
    try sealed.write(to: path)
    let file = CloudLocalBlob(blobId: id, sourceId: "fixture-source", localURL: path, bytes: ref.bytes, sha256: ref.sha256, md5: ref.md5,
      keyEpoch: 1, storageClass: .secrets, purpose: .secret)
    _ = try await client.enqueue([secret], files: [file], associations: [CloudFileAssociation(operationId: secret.opId, blobIds: [id])])
    let memory = try op(entity: "memory-behind-secret")
    _ = try await client.enqueue([memory])
    await server.failFinalizationOnce(code: "secrets_locked", retryable: false)
    _ = try await client.flush()
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1, "Only the memory segment is committed")
    XCTAssertEqual(try store.queuedCount(), 1, "The saved-password edit stays queued")
    XCTAssertEqual(try store.value("blocked"), false)
    XCTAssertNotNil(try store.value("protectedSendFailure") as String?)
    let state = try await CloudSyncBudget(store: store).status()
    XCTAssertNil(state.blocked)
    // Since the round-4 pacing (457d4dea) a refused saved-password upload is not retried before its not-before
    // time: an immediate flush leaves it queued; once that time has passed (simulated) it sends.
    _ = try await client.flush()
    let paced = await server.segmentCount()
    XCTAssertEqual(paced, 1)
    XCTAssertEqual(try store.queuedCount(), 1)
    try store.set("protectedRetryAt", Int64(0))
    _ = try await client.flush()
    let after = await server.segmentCount()
    XCTAssertEqual(after, 2)
    XCTAssertEqual(try store.queuedCount(), 0)
  }
}

extension CloudSyncTests {
  /// Should-fix 5: an engine whose signer was fixed at creation refuses an in-place re-registration
  /// instead of signing new attempts with the old key; nothing is rebound, sent or lost.
  func testRound2FixedSignerRefusesInPlaceReRegistrationWithoutStaleSignatures() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device), operation = try op()
    try await server.registration(device, publicKey: reviewDevicePublicKey(7))
    let (client, store) = try await reviewRegisteredClient(root, server: server, registration: device, signatureByte: 7)
    _ = try await client.enqueue([operation])
    let replacement = "55555555-5555-4555-8555-555555555555"
    try await server.registration(replacement, publicKey: reviewDevicePublicKey(8))
    do { _ = try await client.flush(); XCTFail("A fixed signer signed for a new registration") }
    catch { XCTAssertEqual(error as? CloudFailure, .unsafeConfiguration) }
    XCTAssertEqual(try store.value("activeOutboxDevice") as String?, device)
    XCTAssertNil(try store.value("changedOutboxRegistration") as String?)
    XCTAssertEqual(try store.queuedCount(), 1)
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 0)
    // The following signer resolves the replacement's key per signature and sends the same operation.
    let (following, reopened) = try await reviewFollowingClient(root, server: server, registration: device, keys: [device: 7, replacement: 8])
    _ = try await following.flush()
    XCTAssertEqual(try reopened.queuedCount(), 0)
    XCTAssertEqual(try reopened.operations(), [operation])
    let after = await server.segmentCount()
    XCTAssertEqual(after, 1)
  }
}

extension CloudSyncTests {
  /// Should-fix 6: a protected setup page with several records and files but no associations is kept,
  /// reported and uploaded; it no longer throws inside bootstrap and so never stalls all sync.
  func testRound2UnattributedProtectedSnapshotFilesAreQueuedReportedAndUploaded() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let root = try scratch()
    let (client, store, _) = try await reviewProtectedClient(root, server: server, content: protected)
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory"), domain: "memory"))
    let firstRecord = try await reviewProtectedOperation(protected), secondRecord = try await reviewProtectedOperation(protected)
    let records = [firstRecord, secondRecord]
    var files: [CloudLocalBlob] = []
    for _ in 0..<2 {
      let id = UUID().uuidString.lowercased()
      let envelope = try await protected.seal(Data("fixture-only sealed file".utf8), blobId: id, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
      let sealed = try CloudSyncCanonical.encode(envelope), ref = CloudSyncBytes.blob(sealed, envelope: envelope)
      let path = try scratch().appendingPathComponent(id)
      try sealed.write(to: path)
      files.append(.init(blobId: id, sourceId: "fixture-source", localURL: path, bytes: ref.bytes, sha256: ref.sha256, md5: ref.md5,
        keyEpoch: 1, storageClass: .secrets, purpose: .secret))
    }
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "10"])
    let page = CloudDomainSnapshot(cut: cut, operations: records, files: files,
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 2, bytes: 0, blockedReasons: [])])
    let receipt = try await client.bootstrap([page])
    XCTAssertTrue(receipt.published)
    XCTAssertNil(try store.value("bootstrapInProgress") as String?)
    XCTAssertEqual(try store.value("unattributedProtectedFiles:snapshot:\(cut.snapshotId):0"), ["fixture-source": 2])
    let reported = try await client.coverage(sourceId: "fixture-source")
    XCTAssertTrue(reported.blockedReasons.contains { $0.hasPrefix("2 saved-password files were not linked") })
    let uploaded = try await server.readBlobs(ids: files.map(\.blobId))
    XCTAssertEqual(Set(uploaded.map(\.blob.blobId)), Set(files.map(\.blobId)))
    XCTAssertEqual(try store.queuedCount(), 0)
    // Ordinary sync continues for the whole account.
    _ = try await client.enqueue([op(entity: "after-protected-setup")])
    _ = try await client.flush()
    XCTAssertEqual(try store.queuedCount(), 0)
  }
}
