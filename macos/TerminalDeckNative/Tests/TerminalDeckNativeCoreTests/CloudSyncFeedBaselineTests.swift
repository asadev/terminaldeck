import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// Lean first version, item 5 (cloud-lean-v1.md): NO first upload. `CloudSyncEngine.noFirstUploadInThisVersion`
/// is ON, so an engine built without `firstUpload: true` never publishes, fetches or imports a checkpoint.
extension CloudSyncTests {
  var secondMac: String { "44444444-4444-4444-8444-444444444444" }
  /// An engine as this version builds it: the first upload switched off (the default).
  func feedEngine(root: URL, server: CloudSyncFixtureServer, deviceId: String) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncFixtureAdapter) {
    let store = try makeStore(root)
    let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"))
    let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: deviceId, epoch: 1, brainDomains: ["memory"],
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in })
    try await engine.register(adapter: adapter)
    return (engine, store, adapter)
  }
  func feedSetup(_ operations: [CloudOperation], complete: Bool = true, gaps: [String] = []) -> CloudDomainSnapshot {
    .init(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]), operations: operations, files: [],
      coverage: [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: complete, items: operations.count, bytes: 0, blockedReasons: gaps)])
  }

  /// A FRESH account and no first upload at all: Mac A sets up, then Mac B. Each baseline travels as ordinary
  /// signed packs, each Mac reads the other's from the feed, both settle and are ready, and the service never
  /// receives a checkpoint or a coverage record.
  func testFeedFreshAccountSyncsTwoDevicesWithoutAFirstUpload() async throws {
    XCTAssertTrue(CloudSyncEngine.noFirstUploadInThisVersion)
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (macA, storeA, adapterA) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    let (macB, storeB, adapterB) = try await feedEngine(root: scratch(), server: server, deviceId: secondMac)
    let noteA = try op(entity: "note-a", text: "written on A"), noteB = try op(entity: "note-b", text: "written on B", origin: secondMac)

    let receiptA = try await macA.bootstrap([feedSetup([noteA])])
    XCTAssertFalse(receiptA.published)
    XCTAssertEqual(receiptA.checkpointId, "")
    await server.switchDevice(secondMac)
    let receiptB = try await macB.bootstrap([feedSetup([noteB])])
    XCTAssertFalse(receiptB.published)
    await server.switchDevice(device)
    _ = try await macA.pull()

    // The feed alone carried both baselines: two ordinary packs, no checkpoint, nothing else.
    let checkpoint = try await server.checkpoint()
    XCTAssertNil(checkpoint)
    let packs = await server.segmentCount(), objects = await server.objectCount()
    XCTAssertEqual(packs, 2)
    XCTAssertEqual(objects, 0)
    let onA = await adapterA.count(), onB = await adapterB.count()
    XCTAssertEqual(onA, 2)
    XCTAssertEqual(onB, 2)
    let originOnB = await adapterB.origin(of: noteA.opId)
    XCTAssertEqual(originOnB?.deviceId, device)

    // Both Macs settled without an inventory and are ready from their own setup statement.
    XCTAssertEqual(try storeA.value("baseline") as String?, "feed")
    XCTAssertEqual(try storeB.value("baseline") as String?, "feed")
    XCTAssertNil(try storeA.value("inventoryVerified") as Bool?)
    XCTAssertNil(try storeA.value("checkpointId") as String?)
    XCTAssertEqual(try storeA.queuedCount(), 0)
    XCTAssertEqual(try storeB.queuedCount(), 0)
    let readyA = try await macA.contextReady(projectId: "fixture-project")
    XCTAssertTrue(readyA.verified, "\(readyA.missingSources)")
    await server.switchDevice(secondMac)
    let readyB = try await macB.contextReady(projectId: "fixture-project")
    XCTAssertTrue(readyB.verified, "\(readyB.missingSources)")
    let coverageB = try await macB.coverage(sourceId: "fixture-source")
    XCTAssertTrue(coverageB.complete, "\(coverageB.blockedReasons)")

    // A live edit after setup travels the same way.
    let later = try op(entity: "note-b", parents: [noteB.opId], text: "edited on B", origin: secondMac)
    _ = try await macB.enqueue([later])
    _ = try await macB.flush()
    await server.switchDevice(device)
    _ = try await macA.pull()
    let afterEdit = await adapterA.count()
    XCTAssertEqual(afterEdit, 3)
  }

  /// With no first upload a source's published coverage is this Mac's own setup statement: a gap stated at setup
  /// keeps the Mac not ready, and once it heals this Mac corrects it here, sending no record.
  func testFeedOwnCoverageGapHealsWithoutSendingACorrection() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (mac, _, adapter) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    await adapter.report(complete: false, gaps: ["Some notes could not be read."])
    _ = try await mac.bootstrap([feedSetup([try op(entity: "with-a-gap")], complete: false, gaps: ["Some notes could not be read."])])
    let before = try await mac.coverage(sourceId: "fixture-source")
    XCTAssertFalse(before.complete)
    let notReady = try await mac.contextReady(projectId: "fixture-project")
    XCTAssertFalse(notReady.verified)
    await adapter.report(complete: true)
    try await mac.retryParked(domains: ["memory"])
    let after = try await mac.coverage(sourceId: "fixture-source")
    XCTAssertTrue(after.complete, "\(after.blockedReasons)")
    let ready = try await mac.contextReady(projectId: "fixture-project")
    XCTAssertTrue(ready.verified, "\(ready.missingSources)")
    let packs = await server.segmentCount()
    XCTAssertEqual(packs, 1, "only the baseline pack; no coverage record travels")
  }

  /// An account that already holds a first upload (made with the machinery this version switches off) does not
  /// stall a Mac of this version: slot 1 is passed over, nothing of the upload is fetched or applied, and the
  /// feed is read from position 2.
  func testFeedAccountWithAFirstUploadIsPassedOverNotImported() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (publisher, _, _) = try await engine(root: scratch(), server: server)
    let inInventory = try op(entity: "only-in-the-first-upload")
    _ = try await publisher.bootstrap([feedSetup([inInventory])])
    let published = try await server.checkpoint()
    let firstUpload = try XCTUnwrap(published)
    let (reader, store, adapter) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    // Only the first upload exists: the pull succeeds and the position moves over slot 1.
    _ = try await reader.pull()
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(1))
    XCTAssertEqual(try store.value("ignoredFirstUpload") as String?, firstUpload.checkpointId)
    let downloadsBefore = await server.objectDownloads
    let inFeed = try op(entity: "in-the-feed")
    _ = try await publisher.enqueue([inFeed])
    _ = try await publisher.flush()
    _ = try await reader.pull()
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(2))
    let rows = await adapter.appliedOrder()
    XCTAssertEqual(rows, [inFeed.opId], "the feed's pack applied; the first upload's record did not")
    XCTAssertNil(try store.value("inventoryVerified") as Bool?)
    let downloadsAfter = await server.objectDownloads
    XCTAssertEqual(downloadsAfter, downloadsBefore, "no inventory object was fetched")
  }

  /// A second Mac of this version reading a feed that starts at position 2 (first upload in slot 1) from scratch.
  func testFeedReaderStartsAtPositionTwoWhenSlotOneHoldsAFirstUpload() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (publisher, _, _) = try await engine(root: scratch(), server: server)
    _ = try await publisher.bootstrap([feedSetup([try op(entity: "only-in-the-first-upload")])])
    let inFeed = try op(entity: "in-the-feed")
    _ = try await publisher.enqueue([inFeed])
    _ = try await publisher.flush()
    let (reader, store, adapter) = try await feedEngine(root: scratch(), server: server, deviceId: device)
    _ = try await reader.pull()
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(2))
    let rows = await adapter.appliedOrder()
    XCTAssertEqual(rows, [inFeed.opId])
  }
}
