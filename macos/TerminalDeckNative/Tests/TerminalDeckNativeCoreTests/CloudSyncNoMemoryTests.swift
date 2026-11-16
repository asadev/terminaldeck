import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// An engine with NO memory domains: saved passwords alone, or nothing switched on yet (lane A's request, lean
/// first version). Real engine, trusted list, fixture service.
extension CloudSyncTests {
  /// Saved passwords run without memory. The other Mac has memory on: its memory pack neither stops this Mac nor
  /// is consumed by it. When memory is switched on here later, the memory feed is read from where it stood and
  /// nothing was lost.
  func testNoMemoryEngineRunsSavedPasswordsAndLeavesTheMemoryFeedUnread() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), other = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: other.deviceId), protected = CloudSyncProtectedFixtureContent()
    let secret = try await reviewProtectedOperation(protected)
    let otherList = try CloudSyncFixtureTrust([other])
    let (sender, _, _) = try await trustProtectedEngine(root: scratch(), server: server, identity: other, trust: otherList, content: protected)
    _ = try await sender.enqueue([secret])
    _ = try await sender.flush()                                              // position 1: saved passwords
    let note = try op(entity: "memory-note", origin: other.deviceId)
    try await commit([note], as: other, on: server, then: mac)                // position 2: memory

    let list = try CloudSyncFixtureTrust([mac, other])
    let root = try scratch()
    let (passwordsOnly, store, adapter) = try await trustProtectedEngine(root: root, server: server, identity: mac, trust: list, content: protected, memory: false)
    _ = try await passwordsOnly.pull()
    var applied = await adapter.count()
    XCTAssertEqual(applied, 1, "the saved-password pack applied")
    XCTAssertEqual(try store.value("secretsSeq") as CloudSequence?, CloudSequence(2))
    XCTAssertNil(try store.value("brainSeq") as CloudSequence?, "the memory feed was not consumed")
    XCTAssertTrue(try store.rows("SELECT 1 FROM untrusted_devices LIMIT 1").isEmpty)
    XCTAssertTrue(try store.rows("SELECT 1 FROM refused_packs LIMIT 1").isEmpty)
    let progress = try await passwordsOnly.restoreProgress()
    XCTAssertEqual(progress.blocked, 0)

    // Its own saved-password change goes out and comes back.
    let own = try await reviewProtectedOperation(protected)
    _ = try await passwordsOnly.enqueue([own])
    let sent = try await passwordsOnly.flush()
    XCTAssertEqual(sent.count, 1)
    applied = await adapter.count()
    XCTAssertEqual(applied, 2)

    // Memory is switched on later: a new engine on the same store, now with the memory domain.
    let (withMemory, _, _) = try await trustProtectedEngine(root: root, server: server, identity: mac, trust: list, content: protected, adapter: adapter)
    let memory = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory"))
    try await withMemory.register(adapter: memory)
    _ = try await withMemory.pull()
    let notes = await memory.appliedOrder()
    XCTAssertEqual(notes, [note.opId], "the memory pack was still there to read")
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(3))
    applied = await adapter.count()
    XCTAssertEqual(applied, 2, "saved passwords were not applied twice")
  }

  /// Nothing switched on at all: the engine still builds (it used to refuse), pulls and sends nothing, reads
  /// nothing of the feed, and reports an idle, unblocked state.
  func testNoMemoryEngineWithNothingSwitchedOnBuildsAndStaysIdle() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), other = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    try await commit([op(entity: "memory-note", origin: other.deviceId)], as: other, on: server, then: mac)
    let list = try CloudSyncFixtureTrust([mac])
    let store = try makeStore(scratch())
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: mac.deviceId, epoch: 1, brainDomains: [], signer: { payload in try mac.sign(payload) }, trust: list)
    let pulled = try await engine.pull(), sent = try await engine.flush()
    XCTAssertTrue(pulled.isEmpty)
    XCTAssertTrue(sent.isEmpty)
    XCTAssertNil(try store.value("brainSeq") as CloudSequence?)
    let progress = try await engine.restoreProgress(), waiting = try await engine.heldDevices()
    XCTAssertEqual(progress.blocked, 0)
    XCTAssertEqual(progress.queued, 0)
    XCTAssertTrue(waiting.isEmpty, "an unread memory pack is not counted as waiting")
    let downloads = await server.segmentDownloadLog
    XCTAssertTrue(downloads.isEmpty)
  }
}
