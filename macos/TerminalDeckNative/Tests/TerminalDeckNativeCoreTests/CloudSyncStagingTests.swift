import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

// Staging bound (Asad's Mac: ~15 GB free, ~15 GB of transcripts). Fixture-only data and scratch folders.

/// Test-only: largest staged byte count seen at the probe points.
final class CloudSyncStagingProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var peak: Int64 = 0
  var store: CloudSyncStore?
  func sample() { lock.withLock { if let value = try? store?.stagedBytes() { peak = max(peak, value) } } }
  func maximum() -> Int64 { lock.withLock { peak } }
}
/// Test-only free-space switch.
final class CloudSyncFreeSpace: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: Int64
  init(_ bytes: Int64) { self.bytes = bytes }
  func set(_ value: Int64) { lock.withLock { bytes = value } }
  func get() -> Int64 { lock.withLock { bytes } }
}

/// A setup source that hands one page per file (one record naming it), sampling staged bytes before each page.
private struct CloudSyncStagingSource: CloudDomainAdapter {
  let adapter: CloudSyncFixtureAdapter
  let pages: [CloudDomainSnapshot]
  let probe: CloudSyncStagingProbe
  var inventoryRows: [String] { ["I01"] }
  func sourceInventory() async throws -> [CloudSourceInventory] { try await adapter.sourceInventory() }
  func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot { throw CloudFailure.unsupportedFormat }
  func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
    let reader = CloudSyncStagingReader(pages: pages, probe: probe)
    return AsyncThrowingStream(unfolding: { await reader.next() })
  }
  func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> { await adapter.changes(after: after) }
  func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport { try await adapter.validateIncoming(operations, files: files) }
  func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt { try await adapter.applyPrepared(prepared, origin: origin) }
  func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification { try await adapter.verify(receipt) }
}
private actor CloudSyncStagingReader {
  let pages: [CloudDomainSnapshot], probe: CloudSyncStagingProbe
  var index = 0
  init(pages: [CloudDomainSnapshot], probe: CloudSyncStagingProbe) { self.pages = pages; self.probe = probe }
  func next() -> CloudDomainSnapshot? {
    probe.sample()
    guard index < pages.count else { return nil }
    defer { index += 1 }
    return pages[index]
  }
}

extension CloudSyncTests {
  func stagingEngine(_ root: URL, server: CloudSyncFixtureServer, staging: CloudSyncStaging, probe: CloudSyncStagingProbe? = nil,
                     fault: @escaping CloudSyncFault = { _ in }) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncFixtureAdapter) {
    let store = try makeStore(root), adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("staging-domain"), acceptsFiles: true)
    probe?.store = store
    let client = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) },
      verifySignature: { _, _ in }, firstUpload: true, maximumPackBytes: 2048, staging: staging, fault: fault)
    try await client.register(adapter: adapter)
    return (client, store, adapter)
  }
  func stagingPages(_ count: Int, cut: CloudSnapshotCut) async throws -> ([CloudDomainSnapshot], [CloudLocalBlob]) {
    var pages: [CloudDomainSnapshot] = [], files: [CloudLocalBlob] = []
    for index in 0..<count {
      let (file, _) = try await sealedAttachment(root: scratch())
      let record = try referencing(file)
      files.append(file)
      pages.append(.init(cut: cut, operations: [record], files: [file],
        coverage: index == count - 1 ? [.init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: count, bytes: 0, blockedReasons: [])] : [],
        associations: [CloudFileAssociation(operationId: record.opId, blobIds: [file.blobId])]))
    }
    return (pages, files)
  }

  /// Rules 1 and 2: a first setup of many pages uploads each page as it arrives, drops its sealed bytes at the
  /// read-back receipt, and never holds more than the bound; nothing staged remains afterwards.
  func testStagingFirstSetupOfManyPagesNeverHoldsMoreThanTheBound() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), probe = CloudSyncStagingProbe()
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"])
    let (pages, files) = try await stagingPages(30, cut: cut)
    let bound = Int64(4096)
    XCTAssertGreaterThan(files.reduce(Int64(0)) { $0 + $1.bytes }, bound, "the whole setup is larger than the bound")
    let (client, store, adapter) = try await stagingEngine(scratch(), server: server, staging: .init(maximumStagedBytes: bound, freeBytes: { _ in nil }),
      probe: probe, fault: { if $0 == .afterUpload { probe.sample() } })
    let receipt = try await client.bootstrap(sources: [CloudSyncStagingSource(adapter: adapter, pages: pages, probe: probe)], cut: cut)
    XCTAssertTrue(receipt.published)
    XCTAssertLessThanOrEqual(probe.maximum(), bound)
    XCTAssertEqual(try store.stagedBytes(), 0)
    let present = try await server.readBlobs(ids: Array(files.prefix(16).map(\.blobId)))
    XCTAssertEqual(present.count, 16)
  }

  /// Rule 1 with a crash: setup is interrupted after some pages were uploaded; the adapter has deleted its
  /// staged copies of those pages. The resumed setup accepts them from their saved references, uploads only
  /// what was not acknowledged, and publishes.
  func testStagingCrashMidSetupResumesWithoutResealingUploadedPages() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"])
    let (pages, files) = try await stagingPages(10, cut: cut)
    let staging = CloudSyncStaging(maximumStagedBytes: 4096, freeBytes: { _ in nil })
    let trip = CloudSyncRound3Trip(.afterUpload, at: 6)
    do {
      let (first, _, adapter) = try await stagingEngine(root, server: server, staging: staging, fault: { try trip.check($0) })
      do { _ = try await first.bootstrap(sources: [CloudSyncStagingSource(adapter: adapter, pages: pages, probe: .init())], cut: cut); XCTFail("Crash missed") }
      catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    }
    // The adapter released its staging for every page the core had stored (its local receipt).
    for file in files.prefix(6) { try? FileManager.default.removeItem(at: file.localURL) }
    let fileIds = Set(files.map(\.blobId))
    let before = await server.uploadLog.filter { fileIds.contains($0) }.count
    let (resumed, store, adapter) = try await stagingEngine(root, server: server, staging: staging)
    let receipt = try await resumed.bootstrap(sources: [CloudSyncStagingSource(adapter: adapter, pages: pages, probe: .init())], cut: cut)
    XCTAssertTrue(receipt.published)
    let after = await server.uploadLog.filter { fileIds.contains($0) }.count
    XCTAssertEqual(after - before, 5, "only the interrupted file and the four pages not reached are uploaded")
    let present = try await server.readBlobs(ids: files.map(\.blobId))
    XCTAssertEqual(present.count, files.count)
    XCTAssertEqual(try store.stagedBytes(), 0)
  }

  /// Rule 3: below the free-disk floor setup pauses with a plain reason and continues by itself once space is free.
  func testStagingDiskFloorPausesAndResumesSetup() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), free = CloudSyncFreeSpace(1 << 30)
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"])
    let (pages, _) = try await stagingPages(3, cut: cut)
    let (client, _, adapter) = try await stagingEngine(scratch(), server: server,
      staging: .init(minimumFreeBytes: 5 << 30, pauseInterval: .milliseconds(20), freeBytes: { _ in free.get() }))
    let setup = Task { try await client.bootstrap(sources: [CloudSyncStagingSource(adapter: adapter, pages: pages, probe: .init())], cut: cut) }
    var sawPause = false
    for _ in 0..<200 {
      try await Task.sleep(for: .milliseconds(10))
      if let coverage = try? await client.coverage(sourceId: "fixture-source"), coverage.blockedReasons.contains(where: { $0.hasPrefix("Setup is paused: less than 5 GB is free") }) { sawPause = true; break }
    }
    XCTAssertTrue(sawPause)
    let staged = await server.uploadAttempts
    XCTAssertEqual(staged, 0, "nothing staged or uploaded while paused")
    free.set(10 << 30)
    let receipt = try await setup.value
    XCTAssertTrue(receipt.published)
    let coverage = try await client.coverage(sourceId: "fixture-source")
    XCTAssertFalse(coverage.blockedReasons.contains { $0.hasPrefix("Setup is paused") })
  }

  /// Rule 4: a live file's sealed bytes leave at its read-back receipt; the own record is not handed back (no
  /// second download); no handoff copy stays.
  func testStagingLiveFileBytesLeaveAtTheirCloudReceipt() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let (client, store, _) = try await stagingEngine(root, server: server, staging: .init(freeBytes: { _ in nil }))
    let (file, _) = try await sealedAttachment(root: scratch())
    _ = try await client.enqueue([referencing(file)], files: [file])
    XCTAssertGreaterThan(try store.stagedBytes(), 0)
    _ = try await client.flush()
    XCTAssertEqual(try store.stagedBytes(), 0)
    let downloads = await server.objectDownloads
    XCTAssertEqual(downloads, 1, "the read-back only")
    let handoffs = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sealed").path)) ?? []
    XCTAssertTrue(handoffs.isEmpty)
  }

  /// Rule 2 for live files: a file that would pass the bound (or arrives below the disk floor) is refused at
  /// enqueue with nothing queued; the producer keeps its copy and retries.
  func testStagingLiveEnqueueRespectsTheBoundAndTheFloor() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), free = CloudSyncFreeSpace(10 << 30)
    let (file, _) = try await sealedAttachment(root: scratch())
    let (client, store, _) = try await stagingEngine(scratch(), server: server,
      staging: .init(maximumStagedBytes: file.bytes - 1, freeBytes: { _ in free.get() }))
    do { _ = try await client.enqueue([referencing(file)], files: [file]); XCTFail("Bound ignored") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    XCTAssertEqual(try store.queuedCount(), 0)
    let (roomy, roomyStore, _) = try await stagingEngine(scratch(), server: server, staging: .init(freeBytes: { _ in free.get() }))
    free.set(1 << 30)
    do { _ = try await roomy.enqueue([referencing(file)], files: [file]); XCTFail("Floor ignored") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    XCTAssertEqual(try roomyStore.queuedCount(), 0)
  }

  /// Rule 5: on launch, bytes left by a crash are reconciled: received bytes and handoff copies go, an unsent
  /// object still referenced by a queued record stays, an unreferenced one is removed.
  func testStagingLaunchReconcilesBytesLeftByACrash() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let staging = CloudSyncStaging(freeBytes: { _ in nil })
    let (kept, keptBytes) = try await sealedAttachment(root: scratch())
    do {
      let (client, store, _) = try await stagingEngine(root, server: server, staging: staging)
      _ = try await client.enqueue([referencing(kept)], files: [kept])
      let (orphan, orphanBytes) = try await sealedAttachment(root: scratch())
      try store.execute("INSERT INTO objects(blobId,bytes,descriptor) VALUES (?,?,?)", [Data(orphan.blobId.utf8), orphanBytes, try CloudSyncCanonical.encode(orphan.reference)])
      let (received, receivedBytes) = try await sealedAttachment(root: scratch())
      try store.execute("INSERT INTO objects(blobId,bytes,descriptor,receipt) VALUES (?,?,?,?)", [Data(received.blobId.utf8), receivedBytes,
        try CloudSyncCanonical.encode(received.reference), try CloudSyncCanonical.encode(received.reference)])
      let handoffs = root.appendingPathComponent("sealed")
      try FileManager.default.createDirectory(at: handoffs, withIntermediateDirectories: true)
      try receivedBytes.write(to: handoffs.appendingPathComponent(received.blobId))
    }
    let (_, store, _) = try await stagingEngine(root, server: server, staging: staging)
    XCTAssertEqual(try store.rows("SELECT bytes FROM objects WHERE blobId=?", [Data(kept.blobId.utf8)]).first?[0], keptBytes)
    XCTAssertEqual(try store.stagedBytes(), Int64(keptBytes.count))
    XCTAssertEqual(try store.rows("SELECT blobId FROM objects").count, 2, "the orphan is removed; the received object keeps its references")
    let handoffs = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("sealed").path)) ?? []
    XCTAssertTrue(handoffs.isEmpty)
  }
}

extension CloudSyncTests {
  /// Round 6 S3: a restore of an inventory with files goes page by page: each page's files are fetched ONCE,
  /// applied and released before the next page (before: every page was prepared first, so files of later pages
  /// were released by the first page's clean-up and downloaded a second time).
  func testRound6RestoreWithFilesFetchesEachFileOncePageByPage() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"])
    let (pages, files) = try await stagingPages(70, cut: cut) // two import pages (64 + 6 records)
    let (publisher, _, publisherAdapter) = try await stagingEngine(scratch(), server: server, staging: .init(freeBytes: { _ in nil }))
    _ = try await publisher.bootstrap(sources: [CloudSyncStagingSource(adapter: publisherAdapter, pages: pages, probe: .init())], cut: cut)
    let pageBytes = files.prefix(64).reduce(Int64(0)) { $0 + $1.bytes }
    let (reader, store, adapter) = try await stagingEngine(scratch(), server: server,
      staging: .init(maximumStagedBytes: pageBytes + 4096, freeBytes: { _ in nil }))
    let before = await server.objectDownloadLog.count
    _ = try await reader.pull()
    let applied = await adapter.count()
    XCTAssertEqual(applied, 70)
    let log = await server.objectDownloadLog.dropFirst(before)
    let fileIds = Set(files.map(\.blobId))
    let fileDownloads = log.filter { fileIds.contains($0) }
    XCTAssertEqual(fileDownloads.count, 70, "each file fetched once")
    XCTAssertEqual(Set(fileDownloads), fileIds)
    XCTAssertNil(try store.value("downloadPaused") as String?)
  }

  /// Round 6 S3: below the free-disk floor a restore downloads nothing and says why, then continues once space
  /// is free; a page whose files can never fit the staging limit is refused with its reason, nothing applied.
  func testRound6RestoreDownloadsRespectTheFloorAndTheBound() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), free = CloudSyncFreeSpace(1 << 30)
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"])
    let (pages, files) = try await stagingPages(3, cut: cut)
    let (publisher, _, publisherAdapter) = try await stagingEngine(scratch(), server: server, staging: .init(freeBytes: { _ in nil }))
    _ = try await publisher.bootstrap(sources: [CloudSyncStagingSource(adapter: publisherAdapter, pages: pages, probe: .init())], cut: cut)
    let fileIds = Set(files.map(\.blobId))
    // The floor.
    let (low, lowStore, lowAdapter) = try await stagingEngine(scratch(), server: server, staging: .init(freeBytes: { _ in free.get() }))
    var start = await server.objectDownloadLog.count
    do { _ = try await low.pull(); XCTFail("Floor ignored") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    var log = await server.objectDownloadLog.dropFirst(start)
    XCTAssertTrue(log.filter { fileIds.contains($0) }.isEmpty, "nothing downloaded below the floor")
    let reason: String? = try lowStore.value("downloadPaused")
    XCTAssertTrue(reason?.hasPrefix("Downloads are paused: less than 5 GB") == true)
    var applied = await lowAdapter.count()
    XCTAssertEqual(applied, 0)
    free.set(10 << 30)
    _ = try await low.pull()
    applied = await lowAdapter.count()
    XCTAssertEqual(applied, 3)
    XCTAssertNil(try lowStore.value("downloadPaused") as String?)
    // The bound: three files never fit a limit of two.
    let (small, smallStore, smallAdapter) = try await stagingEngine(scratch(), server: server,
      staging: .init(maximumStagedBytes: files[0].bytes * 2, freeBytes: { _ in nil }))
    start = await server.objectDownloadLog.count
    do { _ = try await small.pull(); XCTFail("Bound ignored") } catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    log = await server.objectDownloadLog.dropFirst(start)
    XCTAssertTrue(log.filter { fileIds.contains($0) }.isEmpty)
    XCTAssertTrue((try smallStore.value("downloadPaused") as String?)?.contains("larger together than") == true)
    applied = await smallAdapter.count()
    XCTAssertEqual(applied, 0)
  }
}

extension CloudSyncTests {
  /// Round 6 S7b: setup asks the service gate once per run, not once per page with files: a three-page setup
  /// makes as many gate calls as a one-page setup.
  func testRound6SetupAsksTheGateOncePerRun() async throws {
    func calls(pages count: Int) async throws -> Int {
      let server = try CloudSyncFixtureServer(root: scratch(), device: device)
      let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"])
      let (pages, _) = try await stagingPages(count, cut: cut)
      let (client, _, adapter) = try await stagingEngine(scratch(), server: server, staging: .init(freeBytes: { _ in nil }))
      let receipt = try await client.bootstrap(sources: [CloudSyncStagingSource(adapter: adapter, pages: pages, probe: .init())], cut: cut)
      XCTAssertTrue(receipt.published)
      return await server.capabilityCalls
    }
    let one = try await calls(pages: 1), three = try await calls(pages: 3)
    XCTAssertEqual(three, one)
  }
}

extension CloudSyncTests {
  /// Round 6 S7c: a feed record reusing the id of this Mac's own sent record (whose file left this Mac) with other
  /// content is not skipped as "own": it is parked as a conflict and the rest of its pack applies (before: it was
  /// skipped, then stored with the pack and the id check stopped the whole pack).
  func testRound6RecordReusingAnOwnIdIsAConflictNotSkipped() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, adapter) = try await stagingEngine(scratch(), server: server, staging: .init(freeBytes: { _ in nil }))
    let (file, _) = try await sealedAttachment(root: scratch())
    let own = try referencing(file)
    _ = try await client.enqueue([own], files: [file])
    _ = try await client.flush()
    XCTAssertEqual(try store.stagedBytes(), 0, "the own file left this Mac")
    let impostor = try op(id: own.opId, entity: "impostor", text: "other content")
    let fine = try op(entity: "fine-neighbour")
    _ = try await server.commit(reviewBrainSegment([impostor, fine]))
    _ = try await client.pull()
    XCTAssertEqual(try store.rows("SELECT opId FROM parked_ops WHERE conflict=1").count, 1)
    let neighbour = await adapter.origin(of: fine.opId)
    XCTAssertNotNil(neighbour, "the rest of the pack applied")
  }
}
