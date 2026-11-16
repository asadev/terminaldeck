import XCTest
import Foundation
@testable import TerminalDeckNativeCore

// Saved-passwords review round 6 (R6-2): a new secrets epoch started on another device.
extension CloudSyncTests {
  /// Queued and already-packed saved-password items of an older key are retired from the send queue (kept with
  /// a reason, never sent) and never block the memory queued behind them.
  func testEpochChangeRetiresOlderKeySendsWithoutBlockingMemory() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let root = try scratch()
    let (client, store, _) = try await reviewProtectedClient(root, server: server, content: protected)
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory"), domain: "memory"))
    let packed = try await reviewProtectedOperation(protected)
    _ = try await client.enqueue([packed])
    await server.setFailure(.unavailable)
    do { _ = try await client.flush(); XCTFail("Commit failure missed") } catch {}
    await server.setFailure(nil)
    XCTAssertEqual(try store.rows("SELECT segmentId FROM segments WHERE receipt IS NULL").count, 1, "packed under the old key")
    let queued = try await reviewProtectedOperation(protected)
    _ = try await client.enqueue([queued])
    await protected.setEpoch(2) // "Start new saved passwords" on another device
    _ = try await client.enqueue([op(entity: "memory-behind")])
    _ = try await client.flush()
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1, "only the memory pack is sent")
    XCTAssertEqual(Set(try store.rows("SELECT opId FROM retired_sends").map { String(decoding: $0[0], as: UTF8.self) }), [packed.opId, queued.opId])
    XCTAssertEqual(try store.queuedCount(), 0)
  }

  /// A saved-password pack this Mac cannot open (the service lists it as locked: an older key) is parked and
  /// the protected cursor moves on; memory and later packs apply. When it can be opened, a retry applies it
  /// without moving the cursor back.
  func testUnopenableProtectedPackIsParkedNotAStall() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let sender = try await reviewProtectedOperation(protected)
    let id = UUID().uuidString.lowercased()
    let envelope = try await protected.seal(CloudSyncPack.encode([sender]), blobId: id, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
    let bytes = try CloudSyncCanonical.encode(envelope)
    _ = try await server.commit(.init(descriptor: .init(segmentId: id, requestId: UUID().uuidString.lowercased(), storageClass: .secrets,
      purpose: .secret, domains: ["api-key"], keyEpoch: 1, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count), opCount: 1,
      format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64))), ciphertext: CloudSyncBytes.base64(bytes)))
    _ = try await server.commit(reviewBrainSegment([op(entity: "memory-after")]))
    await server.lock(segments: [id])
    let root = try scratch()
    let (reader, store, protectedAdapter) = try await reviewProtectedClient(root, server: server, content: protected)
    try await reader.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory"), domain: "memory"))
    _ = try await reader.pull()
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(2))
    XCTAssertEqual(try store.value("secretsSeq"), CloudSequence(2))
    XCTAssertEqual(try store.rows("SELECT seq FROM parked_packs").count, 1)
    // Round 6 S6 changed this expectation: old `blocked == 1`, new `blocked == 0`. Why: a pack this Mac cannot
    // open may stay locked for good; it is kept, retried and reported as a gap on saved-password sources, but it
    // no longer holds the account-wide flag (saved passwords never block memory, round-1 rule).
    let progress = try await reader.restoreProgress()
    XCTAssertEqual(progress.blocked, 0)
    await server.lock(segments: [])
    try await reader.retryParked(domains: ["api-key"])
    XCTAssertTrue(try store.rows("SELECT seq FROM parked_packs").isEmpty)
    XCTAssertEqual(try store.value("secretsSeq"), CloudSequence(2))
    let applied = await protectedAdapter.count()
    XCTAssertEqual(applied, 1)
  }
}

extension CloudSyncTests {
  /// Round 6 S6: a saved-password item retired here (older key, never uploaded) is a GAP on its source, is listed
  /// for lane V with its ids and source, keeps its file across a relaunch, and leaves the list (file released)
  /// only on V's confirmation.
  func testRound6RetiredItemsAreAGapListedForSavedPasswordsUntilConfirmed() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent(), root = try scratch()
    let file = try await round3ProtectedFile(protected)
    let retired = try await reviewProtectedOperation(protected)
    do {
      let (client, store, _) = try await reviewProtectedClient(root, server: server, content: protected)
      _ = try await client.enqueue([retired], files: [file], associations: [CloudFileAssociation(operationId: retired.opId, blobIds: [file.blobId])])
      await protected.setEpoch(2) // "Start new saved passwords" on another device
      _ = try await client.flush()
      XCTAssertEqual(try store.rows("SELECT opId FROM retired_sends").count, 1)
    }
    let (client, store, _) = try await reviewProtectedClient(root, server: server, content: protected)
    XCTAssertEqual(try store.rows("SELECT blobId FROM objects WHERE blobId=? AND length(bytes)>0", [Data(file.blobId.utf8)]).count, 1,
      "the relaunch kept the retired item's file")
    try store.set("coverage:secret-source", CloudCoverage(sourceId: "secret-source", inventoryRow: "I01", complete: true, items: 1, bytes: 0, blockedReasons: []))
    try store.set("coverage-domain:secret-source", "api-key")
    let gap = try await client.coverage(sourceId: "secret-source")
    XCTAssertFalse(gap.complete)
    XCTAssertTrue(gap.blockedReasons.contains { $0.contains("never uploaded") })
    let listed = try await client.retiredRecords()
    XCTAssertEqual(listed.map(\.operationId), [retired.opId])
    XCTAssertEqual(listed.first?.recordId, retired.source.recordId)
    XCTAssertEqual(listed.first?.sourceId, retired.source.sourceId)
    XCTAssertEqual(listed.first?.domain, "api-key")
    XCTAssertEqual(listed.first?.keyEpoch, 1)
    try await client.confirmRetired(operationIds: [retired.opId, "unknown-id"])
    let after = try await client.retiredRecords()
    XCTAssertTrue(after.isEmpty)
    let healed = try await client.coverage(sourceId: "secret-source")
    XCTAssertTrue(healed.complete)
    XCTAssertTrue(try store.rows("SELECT blobId FROM objects WHERE blobId=?", [Data(file.blobId.utf8)]).isEmpty, "file released after confirmation")
  }

  /// Round 6 S6: a saved-password pack from the feed sealed with an older key (known epoch below the current one)
  /// is recorded ONCE as superseded (an exclusion), not parked and retried for ever; nothing stays blocked.
  func testRound6OlderKeyPackIsSupersededNotParked() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let sender = try await reviewProtectedOperation(protected)
    let id = UUID().uuidString.lowercased()
    let envelope = try await protected.seal(CloudSyncPack.encode([sender]), blobId: id, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
    let bytes = try CloudSyncCanonical.encode(envelope)
    _ = try await server.commit(.init(descriptor: .init(segmentId: id, requestId: UUID().uuidString.lowercased(), storageClass: .secrets,
      purpose: .secret, domains: ["api-key"], keyEpoch: 1, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count), opCount: 1,
      format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64))), ciphertext: CloudSyncBytes.base64(bytes)))
    _ = try await server.commit(reviewBrainSegment([op(entity: "memory-after")]))
    await protected.setEpoch(2)
    let root = try scratch()
    let (reader, store, protectedAdapter) = try await reviewProtectedClient(root, server: server, content: protected)
    try await reader.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory"), domain: "memory"))
    _ = try await reader.pull()
    XCTAssertEqual(try store.value("secretsSeq"), CloudSequence(2))
    XCTAssertEqual(try store.rows("SELECT seq FROM superseded_packs").count, 1)
    XCTAssertTrue(try store.rows("SELECT seq FROM parked_packs").isEmpty)
    let progress = try await reader.restoreProgress()
    XCTAssertEqual(progress.blocked, 0)
    try await reader.retryParked(domains: ["api-key"])
    let applied = await protectedAdapter.count()
    XCTAssertEqual(applied, 0, "an older-key pack is never opened")
  }
}
