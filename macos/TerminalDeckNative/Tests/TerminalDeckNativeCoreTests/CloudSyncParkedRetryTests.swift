import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// Parked memory (14 Nov, the owner's MacBook): two arriving records sat parked all day ("This Mac could not take this
/// record") with a growing back-off. The line said "Sync now tries again", he pressed it seven times, and nothing was
/// tried: only a launch or the back-off retried them. And after the morning the log said nothing about them.
extension CloudSyncTests {
  private final class ParkedLines: @unchecked Sendable {
    private let lock = NSLock(); private var all: [String] = []
    func add(_ line: String) { lock.withLock { all.append(line) } }
    func snapshot() -> [String] { lock.withLock { all } }
  }
  private func parkedCount(_ store: CloudSyncStore) throws -> Int {
    Int(String(decoding: try store.rows("SELECT count(*) FROM parked_ops")[0][0], as: UTF8.self)) ?? 0
  }

  func testSyncNowRetriesParkedArrivalsAtOnceAndAnArrivalParkedOverADayIsNamedInTheLog() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (mini, miniStore, miniAdapter) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    _ = try await mini.bootstrap([feedSetup([try incompressible("mini-0")])])

    // The other Mac sends one record that lands and two this Mac cannot take yet.
    await server.switchDevice(secondMac)
    let (book, _, _) = try await feedEngine(root: scratch(), server: server, deviceId: secondMac)
    let fine = try incompressible("book-fine", origin: secondMac)
    let refused = try (0..<2).map { try incompressible("book-refused-\($0)", origin: secondMac) }
    _ = try await book.bootstrap([feedSetup([fine])])
    _ = try await book.enqueue(refused)
    _ = try await book.flush()
    await book.stop()

    await server.switchDevice(device)
    await miniAdapter.refuseWithIdReused(Set(refused.map(\.entityId)))
    _ = try await mini.pull()
    XCTAssertEqual(try parkedCount(miniStore), 2, "the two are parked, the feed went on")
    let landed = await miniAdapter.rows
    XCTAssertNotNil(landed[fine.opId])

    // The cause is gone (a fixed build), but the back-off has not run out: an ordinary pass leaves them parked.
    await miniAdapter.refuseWithIdReused([])
    _ = try await mini.pull()
    XCTAssertEqual(try parkedCount(miniStore), 2, "an ordinary pass keeps the back-off")

    // Parked since two days: one plain line names the kind and the reason.
    try miniStore.execute("UPDATE parked_ops SET parkedAt=parkedAt-172800000")
    let lines = ParkedLines()
    CloudSyncDiagnostics.shared.setSink { lines.add($0) }
    defer { CloudSyncDiagnostics.shared.setSink(nil) }

    // His press: every parked arrival is tried at once, whatever its back-off.
    try await mini.syncNow()
    XCTAssertEqual(try parkedCount(miniStore), 0, "Sync now tried the parked arrivals at once")
    let rows = await miniAdapter.rows
    for record in refused { XCTAssertNotNil(rows[record.opId], record.entityId) }
    let said = lines.snapshot().filter { $0.contains("has waited on this Mac for more than a day") }
    XCTAssertEqual(said.count, 2, "\(lines.snapshot())")
    XCTAssertTrue(said.allSatisfy { $0.contains(refused[0].domain) }, "the line names the kind")
    await mini.stop()
  }
}
