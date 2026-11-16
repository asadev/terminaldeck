import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// The trust review's second pass (025d684b): N1, N2, T1 to T4.
extension CloudSyncTransportTests {
  /// N1: a saved-password route's "not there" goes back to the caller as its own answer and blocks nothing:
  /// no "sign in again", no back-off, memory goes on. Also for a bare 404 with no body.
  func testSecondPassSavedPasswordNotFoundGoesBackToTheCallerAndBlocksNothing() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSync-notfound-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let (transport, _, budget) = try fixtureTransport(root: root)
    for path in ["/secrets/gone", "/secrets/bare404"] {
      do { _ = try await transport.control(method: "POST", path: path, body: Data("{}".utf8), requestId: UUID().uuidString.lowercased()); XCTFail(path) }
      catch {
        XCTAssertTrue(CloudSyncTransport.isNotFound(error), "\(path): \(error)")
        guard case .remote(let detail)? = error as? CloudFailure else { XCTFail("\(error)"); continue }
        XCTAssertEqual(detail.code, "not_found")
      }
    }
    let state = try await budget.status()
    XCTAssertNil(state.blocked, "a missing approval is not a signed-out account")
    XCTAssertEqual(state.failures, 0)
    XCTAssertEqual(state.retryAt, 0)
    let page = try await transport.changes(after: CloudSequence(9_007_199_254_740_993), limit: 17)
    XCTAssertEqual(page.nextAfter.rawValue, "9007199254740993", "memory sync goes on")
    await transport.stop()
  }
}

extension CloudSyncTests {
  private struct SecondPassBaseline: Codable { let cut: String; let coverage: [CloudCoverage]; let lastRow: Int64; let total: Int }

  private func secondPassOp(domain: String, entity: String, origin: String) throws -> CloudOperation {
    let base = try op(entity: entity, origin: origin)
    return .init(v: base.v, opId: base.opId, originDevice: base.originDevice, domain: domain, entityId: base.entityId, revision: base.revision,
      parents: base.parents, kind: base.kind, projectId: base.projectId, rootId: base.rootId, source: base.source, createdAt: base.createdAt,
      payload: base.payload, payloadHash: base.payloadHash)
  }

  /// N2: a trusted Mac's pack of a kind this Mac knows but does not take (memory off here: the kind is in the
  /// engine, its adapter is not registered) WAITS. It is not refused or dropped, it does not stop the pull, and the
  /// trusted device's next pack of a kind this Mac takes applies. Once the kind is taken it applies, late.
  func testSecondPassAPackOfAKindThisMacDoesNotTakeWaitsAndStopsNothing() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac, x])
    let root = try scratch()
    let store = try makeStore(root)
    let memory = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"))
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: mac.deviceId, epoch: 1, brainDomains: ["memory", "tasks"],
      deviceSigner: { deviceId, payload in
        guard deviceId == mac.deviceId else { throw CloudFailure.unsafeConfiguration }
        return try mac.sign(payload)
      }, trust: list)
    try await engine.register(adapter: memory)                     // "tasks" has no adapter on this Mac
    let task = try secondPassOp(domain: "tasks", entity: "task-1", origin: x.deviceId)
    let note = try op(entity: "note-after", origin: x.deviceId)
    try await commit([task], as: x, on: server, then: mac)         // 1
    try await commit([note], as: x, on: server, then: mac)         // 2
    _ = try await engine.pull()                                    // must not throw
    let applied = await memory.appliedOrder()
    XCTAssertEqual(applied, [note.opId], "the pack behind it applied")
    let position: CloudSequence? = try store.value("brainSeq")
    XCTAssertEqual(position, CloudSequence(2), "the feed moved on")
    let waitingKind = try store.kindWaitingRows()
    XCTAssertEqual(waitingKind.map(\.seq), [CloudSequence(1)], "kept by position")
    let refused = try await engine.refusedPacks()
    XCTAssertTrue(refused.isEmpty, "never refused")
    let waitingDevices = try await engine.heldDevices()
    XCTAssertTrue(waitingDevices.isEmpty, "the device is trusted; nothing of it waits for a click")

    // The person switches the kind on: the adapter is registered and the pack applies as a late arrival.
    let tasks = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("tasks"), domain: "tasks")
    try await engine.register(adapter: tasks)
    _ = try await engine.pull()
    let tasksApplied = await tasks.appliedOrder()
    XCTAssertEqual(tasksApplied, [task.opId])
    let origin = await tasks.origin(of: task.opId)
    XCTAssertEqual(origin?.late, true)
    XCTAssertEqual(origin?.deviceId, x.deviceId)
    XCTAssertTrue(try store.kindWaitingRows().isEmpty)
  }

  /// T1: a Trust click that finds the engine busy (here: paused) is remembered durably, also for a device that
  /// has no row (its pack went past the list): the release runs first in the next pull, after a restart too.
  func testSecondPassABusyTrustClickIsRememberedAndActedOnAfterARestart() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let root = try scratch()
    let (engine, store, adapter) = try await trustEngine(root: root, server: server, identity: mac, trust: list)
    store.heldRowLimit = 0                                         // x gets no row: its pack is past the list
    let theirs = try op(entity: "busy-click", origin: x.deviceId)
    try await commit([theirs], as: x, on: server, then: mac)
    _ = try await engine.pull()
    XCTAssertNil(try store.heldRow(x.deviceId))
    try await list.trust(x)
    try await engine.setPaused(true)
    let now = try await engine.trustDevice(deviceId: x.deviceId, signKey: x.jwk())
    XCTAssertTrue(now.isEmpty, "busy: nothing released at the click")
    XCTAssertEqual(try store.releasingDevices(), [x.deviceId], "the click is remembered on disk")
    try await engine.setPaused(false)
    let (restarted, _, _) = try await trustEngine(root: root, server: server, identity: mac, trust: list, adapter: adapter)
    _ = try await restarted.pull()
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [theirs.opId])
    let origin = await adapter.origin(of: theirs.opId)
    XCTAssertEqual(origin?.late, true)
  }

  /// T2: at launch a refused pack that now verifies but cannot be opened does not fail the pull; it stays listed.
  func testSecondPassTheLaunchCheckOfARefusedPackThatCannotBeOpenedStopsNothing() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let wrong = CloudSyncTestIdentity(deviceId: secondMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let wrongKey = try wrong.jwk()
    await list.store(x.deviceId, key: wrongKey)
    let root = try scratch()
    let (engine, _, adapter) = try await trustEngine(root: root, server: server, identity: mac, trust: list)
    let theirs = try op(entity: "refused-unopenable", origin: x.deviceId)
    try await commit([theirs], as: x, on: server, then: mac)
    _ = try await engine.pull()
    let before = try await engine.refusedPacks()
    XCTAssertEqual(before.count, 1)
    try await list.trust(x)
    await server.setCorruption(Data([1, 2, 3]))                    // verifies now, but its bytes do not match
    let (restarted, _, _) = try await trustEngine(root: root, server: server, identity: mac, trust: list, adapter: adapter)
    _ = try await restarted.pull()                                 // must not throw
    _ = try await restarted.pull()                                 // and not on the next pull either
    let after = try await restarted.refusedPacks()
    XCTAssertEqual(after.map(\.sequence), before.map(\.sequence), "still listed")
    XCTAssertGreaterThan(after.first?.checks ?? 0, before.first?.checks ?? 0, "the check was counted")
    let applied = await adapter.count()
    XCTAssertEqual(applied, 0)
    await server.setCorruption(nil)
  }

  /// T3: a sync store made before the release mark existed opens with this build and the mark works.
  func testSecondPassAnOlderStoreFileWithoutTheReleaseMarkOpens() throws {
    let root = try scratch()
    do {
      let old = try makeStore(root)
      try old.execute("DROP INDEX untrusted_releasing")
      try old.execute("ALTER TABLE untrusted_devices DROP COLUMN releasing")
      try old.hold(deviceId: secondMac, seq: CloudSequence(1), storageClass: .brain, domains: ["memory"], operations: 1)
    }
    let reopened = try makeStore(root)
    XCTAssertNotNil(try reopened.heldRow(secondMac), "the waiting row survived")
    try reopened.setReleasing([secondMac], true)
    XCTAssertEqual(try reopened.releasingDevices(), [secondMac])
  }

  /// T4: the baseline's reason says when it waits for a person (sign in, a refusal, paused) and when it is
  /// retried by itself.
  func testSecondPassBaselineProgressSaysWhatItWaitsFor() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let (engine, store, _) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: list)
    try store.set("feedBaseline", SecondPassBaseline(cut: "cut", coverage: [], lastRow: 1_000_000, total: 3))
    let budget = CloudSyncBudget(store: store)
    func remote(_ code: String) -> CloudFailure { .remote(.init(code: code, message: "Fixture.", retryable: false, requestId: "fixture")) }

    try await budget.failed(remote("device_revoked"))
    var progress = try await engine.baselineProgress()
    XCTAssertEqual(progress?.reason, CloudSyncEngine.baselineSignInReason)
    XCTAssertNil(progress?.waitingUntil)
    try await budget.resume(networkOrWake: false, signedIn: true)

    try await budget.failed(remote("fixture_refused"))
    progress = try await engine.baselineProgress()
    XCTAssertEqual(progress?.reason, CloudSyncEngine.baselineRefusedReason)
    XCTAssertNil(progress?.waitingUntil)
    try await budget.resume(networkOrWake: false, userRetry: true)

    try await engine.setPaused(true)
    progress = try await engine.baselineProgress()
    XCTAssertEqual(progress?.reason, CloudSyncEngine.baselinePausedReason)
    try await engine.setPaused(false)

    try await budget.failed(CloudFailure.unavailable)
    progress = try await engine.baselineProgress()
    XCTAssertEqual(progress?.reason, "The Cloud did not answer. The upload is retried by itself.")
    XCTAssertNotNil(progress?.waitingUntil)
  }

  /// T4: on an engine without memory kinds a pending baseline does not settle unsent, and says why it waits.
  func testSecondPassAPendingBaselineDoesNotSettleOnAnEngineWithoutMemory() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let (engine, store, _) = try await trustProtectedEngine(root: scratch(), server: server, identity: mac, trust: list,
      content: CloudSyncProtectedFixtureContent(), memory: false)
    try store.set("feedBaseline", SecondPassBaseline(cut: "cut", coverage: [], lastRow: 1_000_000, total: 3))
    _ = try await engine.flush()
    let progress = try await engine.baselineProgress()
    XCTAssertNotNil(progress, "still pending")
    XCTAssertEqual(progress?.reason, CloudSyncEngine.baselineMemoryOffReason)
    let baseline: String? = try store.value("baseline")
    XCTAssertNotEqual(baseline, "feed")
  }
}
