import Foundation
import XCTest
@testable import TerminalDeckNativeCore

private actor CloudRestoreFetchFixture {
  let outbox: CloudBackupFixtureOutbox
  var failOnSecond: Bool
  var calls: [String] = []
  init(outbox: CloudBackupFixtureOutbox, failOnSecond: Bool) { self.outbox = outbox; self.failOnSecond = failOnSecond }
  func fetch(_ ref: CloudBlobRef) async throws -> Data {
    calls.append(ref.blobId)
    if failOnSecond && calls.count == 2 { throw CloudFailure.unavailable }
    return try await outbox.read(ref)
  }
}
final class CloudRestoreResumeTests: XCTestCase, @unchecked Sendable {
  func testRestartReusesVerifiedChunksAndKeepsFailedStaging() async throws {
    let f = try CloudBackupFixture(); defer { f.clean() }
    var bytes = Data(repeating: 65, count: CloudWire.maximumPlainChunkBytes)
    bytes.append(Data(repeating: 66, count: CloudWire.maximumPlainChunkBytes))
    bytes.append(Data(repeating: 67, count: 17))
    try f.write("large.bin", bytes)
    let snapshot = try await f.engine().snapshot(f.root(), eventCursor: "1", at: 1)
    let failing = CloudRestoreFetchFixture(outbox: f.outbox, failOnSecond: true)
    let firstReader = CloudRestoreReader(fetch: { try await failing.fetch($0) }, brain: f.brain, secrets: f.secrets)
    let journal = f.base.appendingPathComponent("plans")
    let first = CloudRestorePlanner(reader: firstReader, journalDirectory: journal)
    let destination = f.base.appendingPathComponent("resumed")
    let plan = try await first.plan(manifest: snapshot.manifest, sourceManifestHash: snapshot.root.sha256, destination: destination)
    do { _ = try await first.restore(restoreId: plan.restoreId, planDigest: plan.digest); XCTFail("Injected interruption did not interrupt") }
    catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    let staged = try FileManager.default.contentsOfDirectory(at: f.base, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".cloud-restore-" + plan.restoreId + "-") }
    XCTAssertEqual(staged.count, 1)
    let partial = try Data(contentsOf: staged[0].appendingPathComponent("large.bin"))
    XCTAssertEqual(partial.count, CloudWire.maximumPlainChunkBytes)
    let healthy = CloudRestoreFetchFixture(outbox: f.outbox, failOnSecond: false)
    let reader = CloudRestoreReader(fetch: { try await healthy.fetch($0) }, brain: f.brain, secrets: f.secrets)
    let resumed = CloudRestorePlanner(reader: reader, journalDirectory: journal)
    let receipt = try await resumed.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    XCTAssertTrue(receipt.ready)
    XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("large.bin")), bytes)
    XCTAssertEqual(try Data(contentsOf: staged[0].appendingPathComponent("large.bin")), partial)
    let calls = await healthy.calls
    XCTAssertEqual(calls.count, 2)
    XCTAssertFalse(calls.contains(snapshot.manifest.entries[0].chunks[0].blob.blobId))
    let restarted = CloudRestorePlanner(reader: reader, journalDirectory: journal)
    let repeated = try await restarted.restore(restoreId: plan.restoreId, planDigest: plan.digest)
    XCTAssertEqual(repeated, receipt)
    let after = await healthy.calls
    XCTAssertEqual(after.count, 2)
  }
}
