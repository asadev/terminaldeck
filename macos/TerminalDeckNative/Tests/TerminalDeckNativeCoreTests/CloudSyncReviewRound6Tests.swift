import XCTest
import Foundation
@testable import TerminalDeckNativeCore

// Review round 6 regressions. Fixture-only data; no real account, Keychain or network.
extension CloudSyncTests {
  /// First-run risk: empty values bind as empty BLOBs, never NULL: an edit with an empty payload and no project
  /// is queued (the queue row's payload reference is empty) and a parked record without a project is kept.
  func testRound6EmptyValuesBindAsEmptyBlobsSoNothingIsDroppedSilently() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, adapter) = try await engine(root: scratch(), server: server)
    let payload = CloudValue(.object([]))
    let id = UUID().uuidString.lowercased()
    let empty = CloudOperation(v: 1, opId: id, originDevice: device, domain: "memory", entityId: "empty", revision: id, parents: [], kind: .put,
      projectId: nil, source: .init(sourceId: "fixture-source", recordId: id), createdAt: 1000, payload: payload,
      payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
    _ = try await client.enqueue([empty])
    XCTAssertEqual(try store.queuedCount(), 1)
    XCTAssertEqual(try store.rows("SELECT typeof(payloadRef) FROM outbox WHERE opId=?", [Data(id.utf8)]).first.map { String(decoding: $0[0], as: UTF8.self) }, "blob")
    let remote = try op(entity: "no-project", project: nil)
    _ = try await server.commit(reviewBrainSegment([remote]))
    await adapter.refuse([remote.opId])
    _ = try await client.pull()
    XCTAssertEqual(try store.rows("SELECT opId FROM parked_ops").count, 1, "a parked record without a project is kept")
  }
}

extension CloudSyncTests {
  /// M1: a coverage correction from a device that did not make the inventory is not adopted.
  func testRound6CoverageCorrectionFromAnotherDeviceIsNotAdopted() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (publisher, _, adapter) = try await engine(root: scratch(), server: server)
    await adapter.report(complete: false, gaps: ["Some notes could not be read."])
    let cut = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]),
      operations: [try op(entity: "with-a-gap")], files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: false, items: 1, bytes: 0, blockedReasons: ["Some notes could not be read."])])
    _ = try await publisher.bootstrap([cut])
    let corrected = CloudCoverage(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 1, bytes: 0, blockedReasons: [])
    let payload = CloudValue(try NativeRPCValue.parseJSON(CloudSyncCanonical.encode(corrected)))
    let id = UUID().uuidString.lowercased()
    let forged = CloudOperation(v: 1, opId: id, originDevice: "44444444-4444-4444-8444-444444444444", domain: CloudSyncEngine.coverageDomain,
      entityId: "fixture-source", revision: id, parents: [], kind: .put, source: .init(sourceId: "fixture-source", recordId: id), createdAt: 1000,
      payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
    _ = try await server.commit(reviewBrainSegment([forged]))
    let (reader, _, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    let coverage = try await reader.coverage(sourceId: "fixture-source")
    XCTAssertFalse(coverage.complete)
  }
}

extension CloudSyncTests {
  /// M2: a commit retried after a lost answer returns the first commit's old receipt; the service clock must not
  /// learn from it.
  func testRound6ServiceClockIgnoresAReplayedCommitReceipt() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, _) = try await engine(root: scratch(), server: server)
    _ = try await client.enqueue([op(entity: "lost-answer")])
    await server.setLostACK()
    do { _ = try await client.flush(); XCTFail("Lost answer missed") } catch {}
    // The first send's answer was lost: nothing learned yet. The retry gets the saved receipt back.
    XCTAssertNil(CloudSyncServiceClock.serviceTime(store))
    _ = try await client.flush()
    XCTAssertNil(CloudSyncServiceClock.serviceTime(store), "a replayed receipt teaches nothing")
    _ = try await client.enqueue([op(entity: "fresh-send")])
    _ = try await client.flush()
    XCTAssertNotNil(CloudSyncServiceClock.serviceTime(store), "a first send does")
  }
}

extension CloudSyncTests {
  /// M3: a record parked for an id conflict makes nothing wait: a later incoming version of that record applies,
  /// and a later local edit of it is sent.
  func testRound6ConflictParkMakesNothingWait() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let shared = UUID().uuidString.lowercased(), peer = "44444444-4444-4444-8444-444444444444"
    let local = try op(id: shared, entity: "copied", text: "this Mac")
    let remote = try op(id: shared, entity: "copied", text: "other Mac", origin: peer)
    let laterRemote = try op(entity: "copied", parents: [shared], text: "other Mac, later", origin: peer)
    _ = try await server.commit(reviewBrainSegment([remote]))
    _ = try await server.commit(reviewBrainSegment([laterRemote]))
    let (client, store, adapter) = try await engine(root: scratch(), server: server)
    _ = try await client.enqueue([local])
    _ = try await client.pull()
    let order = await adapter.appliedOrder()
    XCTAssertTrue(order.contains(laterRemote.opId), "the later incoming version applied")
    let laterLocal = try op(entity: "copied", parents: [shared], text: "this Mac, later")
    _ = try await client.enqueue([laterLocal])
    _ = try await client.flush()
    let sent = try await client.cloudReceipt(operationId: laterLocal.opId)
    XCTAssertNotNil(sent, "the later local edit was sent")
    XCTAssertEqual(try store.rows("SELECT opId FROM parked_ops WHERE conflict=1").count, 1)
  }
}

extension CloudSyncTests {
  /// S1: three refusals in a row pause sending with a timed retry (one minute doubling to six hours), not a
  /// block that needs a person. While paused nothing is sent; when the wait ends ONE more refusal pauses
  /// again for longer (nothing parked); once the service accepts, the pause and its reason are gone.
  func testRound6RefusalStopRetriesByItselfWithBackOff() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store) = try await round4TwoDomainClient(scratch(), server: server)
    func note(_ entity: String) throws -> CloudOperation {
      let base = try op(entity: entity)
      return .init(v: 1, opId: base.opId, originDevice: base.originDevice, domain: "notes", entityId: base.entityId, revision: base.revision,
        parents: [], kind: base.kind, projectId: base.projectId, source: base.source, createdAt: base.createdAt, payload: base.payload, payloadHash: base.payloadHash)
    }
    _ = try await client.enqueue([try op(entity: "memory-a"), try note("note-1"), try note("note-2")])
    await server.refusePacks(of: ["notes"])
    do { _ = try await client.flush(); XCTFail("Three refusals in a row did not stop") } catch {}
    let firstUntil: Int64 = try XCTUnwrap(try store.value("sendStoppedUntil"))
    XCTAssertGreaterThan(firstUntil, CloudSyncBytes.now() + 50_000, "about one minute")
    XCTAssertLessThanOrEqual(firstUntil, CloudSyncBytes.now() + 60_000)
    let reason: String? = try store.value("sendStopped")
    XCTAssertTrue(reason?.contains("retried automatically") == true)
    XCTAssertEqual(try store.queuedCount(), 1)
    let parkedBefore = try store.rows("SELECT opId FROM parked_sends").count
    // Paused: a flush sends nothing and does not throw.
    let paused = try await client.flush()
    XCTAssertTrue(paused.isEmpty)
    let pausedSegments = await server.segmentCount()
    XCTAssertEqual(pausedSegments, 1)
    XCTAssertNotNil(try store.value("sendStopped") as String?, "the reason stays while paused")
    // The wait ends (time moved on) and the service still refuses: one refusal stops again, for about two minutes.
    try store.set("sendStoppedUntil", Int64(1))
    do { _ = try await client.flush(); XCTFail("A refusal after the timed retry did not stop again") } catch {}
    let secondUntil: Int64 = try XCTUnwrap(try store.value("sendStoppedUntil"))
    XCTAssertGreaterThan(secondUntil, CloudSyncBytes.now() + 110_000)
    XCTAssertEqual(try store.rows("SELECT opId FROM parked_sends").count, parkedBefore, "a general refusal parks nothing more")
    XCTAssertEqual(try store.queuedCount(), 1)
    // The wait ends and the service accepts: the queued edit sends and the stop is gone.
    await server.refusePacks(of: [])
    try store.set("sendStoppedUntil", Int64(1))
    _ = try await client.flush()
    let after = await server.segmentCount()
    XCTAssertEqual(after, 2)
    XCTAssertEqual(try store.queuedCount(), 0)
    XCTAssertNil(try store.value("sendStopped") as String?)
    XCTAssertNil(try store.value("sendStoppedUntil") as Int64?)
    XCTAssertNil(try store.value("sendStopStreak") as Int?)
  }
}

extension CloudSyncTests {
  /// S2: a released (skeleton) record is marked once and later flushes and pulls do not read it again.
  /// Probe: the stubbed row's bytes are put back by hand while the mark stays; a later pass that re-read
  /// settled rows would stub them again, a pass that skips marked rows leaves them.
  func testRound6ReleasedRecordsAreMarkedAndNotReadAgain() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (publisher, _, _) = try await engine(root: scratch(), server: server)
    let baseline = try (0..<3).map { try op(entity: "baseline-\($0)", text: "content \($0)") }
    _ = try await publisher.bootstrap([snapshot(baseline)])
    let (reader, store, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertEqual(try store.rows("SELECT opId FROM record_stubs").count, 3, "each released record is marked")
    let full = try CloudSyncCanonical.encode(baseline[0])
    try store.execute("UPDATE records SET bytes=? WHERE opId=?", [full, Data(baseline[0].opId.utf8)])
    _ = try await reader.enqueue([try op(entity: "later")])
    _ = try await reader.flush()
    _ = try await reader.pull()
    XCTAssertEqual(try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(baseline[0].opId.utf8)]).first?[0], full,
      "a marked row is not read again")
    XCTAssertEqual(try store.rows("SELECT opId FROM record_stubs").count, 4, "the newly settled own record is marked once")
  }
}

extension CloudSyncTests {
  /// S7e: after an account reset, a Mac whose records were released can publish again: the adapter's setup page
  /// hands the full records, which replace the skeletons, and the inventory built from verified records (the
  /// path taken when the new account's feed already has a pack) carries full content.
  func testRound6FullRecordOverItsSkeletonRestoresContentForANewInventory() async throws {
    let first = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let record = try op(entity: "released-then-reset", text: "the content")
    let (client, store, _) = try await engine(root: root, server: first)
    _ = try await client.bootstrap([snapshot([record])])
    let stub = try store.rows("SELECT bytes FROM records WHERE opId=?", [Data(record.opId.utf8)]).first?[0] ?? Data()
    XCTAssertEqual(try JSONDecoder().decode(CloudOperation.self, from: stub), CloudSyncStore.skeleton(record))
    // Account reset: a new service whose feed already holds another device's pack.
    // Run 6 fix (test set-up): the reused store's feed cursor is 1 (its old first inventory took slot 1), so a
    // pack of the new account at slot 1 is never read; the engine has no account-reset signal (raised in the
    // channel). Slot 1 therefore holds this Mac's own record (already held here) and the other device's pack is
    // at slot 2, which the store reads. The guarantee checked is unchanged: both records reach a new device.
    let fresh = try CloudSyncFixtureServer(root: scratch(), device: device)
    _ = try await fresh.commit(reviewBrainSegment([record]))
    _ = try await fresh.commit(reviewBrainSegment([op(entity: "feed-first")]))
    let (again, againStore, _) = try await engine(root: root, server: fresh)
    _ = try await again.bootstrap([snapshot([record])])
    XCTAssertNil(try againStore.value("publishBlocked") as String?)
    let (reader, _, adapter) = try await engine(root: scratch(), server: fresh)
    _ = try await reader.pull()
    let applied = await adapter.count()
    XCTAssertEqual(applied, 2, "the new inventory carried the full record and the feed's pack")
  }
}

extension CloudSyncTests {
  /// S4: a saved-password setup file that no record names, refused during setup and still refused when setup
  /// ends, survives the end of setup and a relaunch, and is sent once the service accepts it (before: setup's
  /// staging rows went, the relaunch deleted the bytes as orphans and the send found nothing).
  func testRound6WaitingProtectedSetupFileSurvivesSetupEndAndRelaunch() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent(), root = try scratch()
    CloudSyncFullHTTP.registry.set(server)
    let file = try await round3ProtectedFile(protected)
    do {
      let (client, store, _) = try await round3ProtectedHTTPClient(root, server: server, protected: protected)
      let page = CloudDomainSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]),
        operations: [], files: [file], coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: 0, bytes: 0, blockedReasons: [])])
      // Run 7 fix (test set-up): setup tries the saved-password file twice (per page, then before publishing); a
      // single refusal let the second try upload it, so nothing was left waiting. Now every SAVED-PASSWORD upload
      // is refused during setup (memory uploads go through, as with the Worker), and saved passwords are locked
      // on this Mac when setup ends, so the end-of-setup flush cannot send it either.
      await server.refuseProtectedUploads(true)
      await protected.lock(true)
      _ = try await client.bootstrap([page])
      XCTAssertTrue(try store.rows("SELECT snapshotId FROM snapshot_files").isEmpty, "setup staging is gone")
      XCTAssertEqual(try store.value("protectedWaitingFiles") as [String]?, [file.blobId])
      await client.stop()
    }
    // Saved passwords open again; the service accepts; time moves past the protected back-off; the app relaunches.
    await server.refuseProtectedUploads(false)
    await protected.lock(false)
    let (client, store, _) = try await round3ProtectedHTTPClient(root, server: server, protected: protected)
    XCTAssertGreaterThan(try store.stagedBytes(), 0, "launch reconciliation kept the waiting file")
    try store.execute("DELETE FROM metadata WHERE key=?", [Data("protectedRetryAt".utf8)])
    _ = try await client.flush()
    let refs = try await server.readBlobs(ids: [file.blobId])
    XCTAssertEqual(refs.first?.blob.blobId, file.blobId)
    XCTAssertNil(try store.value("protectedWaitingFiles") as [String]?)
    XCTAssertNil(try store.value("protectedSendFailure") as String?)
    await client.stop()
  }
}

extension CloudSyncTests {
  /// S5: a file whose only record is parked for good (or retired) no longer counts against the staging bound:
  /// its bytes stay, and a new edit with a file is accepted (before: refused for space for ever).
  func testRound6BytesThatCanNeverLeaveDoNotCountAgainstTheBound() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (stuck, _) = try await sealedAttachment(root: scratch())
    let (client, store, _) = try await stagingEngine(scratch(), server: server,
      staging: .init(maximumStagedBytes: stuck.bytes + 64, freeBytes: { _ in nil }))
    let record = try referencing(stuck)
    _ = try await client.enqueue([record], files: [stuck])
    XCTAssertEqual(try store.stagedBytes(), stuck.bytes)
    // The record is parked for good (as after an id conflict).
    try store.execute("UPDATE outbox SET state='parked' WHERE opId=?", [Data(record.opId.utf8)])
    try store.execute("INSERT INTO parked_sends(opId,reason,parkedAt,attempts,nextAt,permanent) VALUES (?,?,1,1,0,1)", [Data(record.opId.utf8), Data("conflict".utf8)])
    XCTAssertEqual(try store.stagedBytes(), 0)
    XCTAssertEqual(try store.rows("SELECT bytes FROM objects WHERE blobId=? AND length(bytes)>0", [Data(stuck.blobId.utf8)]).count, 1, "the bytes stay")
    let (next, _) = try await sealedAttachment(root: scratch())
    _ = try await client.enqueue([referencing(next)], files: [next])
    XCTAssertEqual(try store.queuedCount(), 1)
  }
}

extension CloudSyncTests {
  /// S7d: an edit parked on the send side and then returned to the queue (its back-off row stays) does not keep
  /// restore progress "blocked".
  func testRound6EditBackInTheQueueDoesNotKeepProgressBlocked() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, _) = try await engine(root: scratch(), server: server)
    let edit = try op(entity: "returned")
    _ = try await client.enqueue([edit])
    try store.execute("INSERT INTO parked_sends(opId,reason,parkedAt,attempts,nextAt,permanent) VALUES (?,?,1,1,1,0)", [Data(edit.opId.utf8), Data("earlier refusal".utf8)])
    XCTAssertEqual(try store.queuedCount(), 1, "the edit is queued, not parked")
    let progress = try await client.restoreProgress()
    XCTAssertEqual(progress.blocked, 0)
  }
}
