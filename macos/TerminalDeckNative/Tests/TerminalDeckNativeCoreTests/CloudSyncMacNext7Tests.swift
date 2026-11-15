import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// MAC-NEXT-7 (13 Nov, independent review of 59d5a133).
/// 1: the launch check of refused packs catches exactly what the feed catches: no pack, refused or new, makes two
///    consecutive fetches fail for the same reason (receiving stopped while sending went on).
/// 2: "starting up" reaches the engine through the port (a protocol requirement, not an extension method), and a pause
///    by the person is only ever reported after `setPaused(true)`.
extension CloudSyncTests {
  private final class Lines7: @unchecked Sendable {
    private let lock = NSLock(); private var all: [String] = []
    func add(_ line: String) { lock.withLock { all.append(line) } }
    func snapshot() -> [String] { lock.withLock { all } }
  }

  func testMacNext7NoPackRefusedOrNewMakesTwoConsecutiveFetchesFailForTheSameReason() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), other = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, other])
    let root = try scratch()
    let (first, store, adapter) = try await trustEngine(root: root, server: server, identity: mac, trust: trust)
    // A pack this Mac cannot take, failing with an error that is neither the network's nor a content refusal.
    let odd = try op(entity: "fails-oddly-here", origin: other.deviceId)
    await adapter.failOddly([odd.entityId])
    try await commit([odd], as: other, on: server, then: mac)
    _ = try await first.pull()
    let listed = try await first.refusedPacks()
    XCTAssertEqual(listed.count, 1, "listed with its reason, the feed went on")
    await first.stop()

    // A restart: the launch check of refused packs meets the same failure; a new odd pack and a good one arrive too.
    let newOdd = try op(entity: "also-fails-oddly", origin: other.deviceId)
    let good = try op(entity: "arrives-after", origin: other.deviceId)
    await adapter.failOddly([odd.entityId, newOdd.entityId])
    try await commit([newOdd], as: other, on: server, then: mac)
    try await commit([good], as: other, on: server, then: mac)
    let (second, _, _) = try await trustEngine(root: root, server: server, identity: mac, trust: trust, adapter: adapter)
    var outcomes: [String] = []
    for _ in 0..<4 {
      do { _ = try await second.pull(); outcomes.append("ok") } catch { outcomes.append(String(describing: error)) }
    }
    for i in 1..<outcomes.count where outcomes[i] != "ok" {
      XCTAssertNotEqual(outcomes[i], outcomes[i - 1], "two consecutive fetches failed for the same reason: \(outcomes)")
    }
    XCTAssertEqual(outcomes.first, "ok", "the launch check never fails the fetch: \(outcomes)")
    let rows = await adapter.rows
    XCTAssertNotNil(rows[good.opId], "receiving went on past both packs")
    let refused = try await second.refusedPacks()
    XCTAssertEqual(refused.count, 2)
    XCTAssertTrue(refused.allSatisfy { $0.reason.contains("This Mac could not") }, "\(refused.map(\.reason))")
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, try store.value("headSeq") as CloudSequence?)
    await second.stop()
  }

  func testMacNext7StartingUpReachesTheEngineThroughThePortAndOnlyThePersonsPauseIsReportedAsOne() async throws {
    let lines = Lines7()
    CloudSyncDiagnostics.shared.setSink { lines.add($0) }
    defer { CloudSyncDiagnostics.shared.setSink(nil) }
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store) = try await stallEngine(root: scratch(), server: server)
    _ = try await engine.bootstrap([feedSetup([try incompressible("baseline")])])
    // The account wiring holds `any CloudOutboxPort`: the call must reach the engine's own version.
    let port: any CloudOutboxPort = engine
    try await port.holdForStartup()
    _ = try await port.enqueue([try incompressible("waits-for-start")], files: [])
    do { _ = try await port.flush(); XCTFail("held while starting up") } catch {}
    XCTAssertNotEqual(try store.value("paused") as Bool?, true, "starting up writes no pause")
    func said(_ text: String) async throws -> Bool {
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if lines.snapshot().contains(where: { $0.contains(text) }) { return true }
        try await Task.sleep(for: .milliseconds(20))
      }
      return false
    }
    await engine.startEvents()
    let startingUp = try await said("waiting: Cloud is starting up on this Mac")
    XCTAssertTrue(startingUp, "\(lines.snapshot())")
    XCTAssertFalse(lines.snapshot().contains { $0.contains("paused by the person") }, "\(lines.snapshot())")

    // Only the person's pause (the page's switch) is stored and named as one; nothing before it said so.
    XCTAssertNotEqual(try store.value("paused") as Bool?, true)
    try await port.setPaused(true)
    XCTAssertEqual(try store.value("paused") as Bool?, true, "the person's pause")
    await engine.stop()
  }
}
