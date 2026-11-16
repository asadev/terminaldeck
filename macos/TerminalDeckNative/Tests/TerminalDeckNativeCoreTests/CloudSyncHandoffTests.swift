import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

extension CloudSyncTests {
  func sealedAttachment(root: URL, purpose: CloudPurpose = .brain) async throws -> (CloudLocalBlob, Data) {
    let id = UUID().uuidString.lowercased()
    let envelope = try await makeContent().seal(Data("fixture-only raw transcript\n".utf8), blobId: id,
      storageClass: .brain, purpose: purpose, epoch: 1, codec: .identity)
    let bytes = try CloudSyncCanonical.encode(envelope), ref = CloudSyncBytes.blob(bytes, envelope: envelope)
    let file = root.appendingPathComponent(id)
    try bytes.write(to: file)
    return (.init(blobId: id, sourceId: "fixture-source", localURL: file, bytes: ref.bytes, sha256: ref.sha256,
      md5: ref.md5, keyEpoch: ref.keyEpoch, storageClass: ref.storageClass, purpose: ref.purpose), bytes)
  }
  func referencing(_ file: CloudLocalBlob) throws -> CloudOperation {
    let id = UUID().uuidString.lowercased()
    let payload = CloudValue(try NativeRPCValue.parseJSON(CloudSyncCanonical.encode(file.reference)))
    return .init(v: 1, opId: id, originDevice: device, domain: "memory", entityId: id, revision: id, parents: [], kind: .append,
      source: .init(sourceId: "fixture-source", recordId: id), createdAt: 1000, payload: payload,
      payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
  }
  func testSealedFileReceiptSurvivesProducerDeletionAndRestart() async throws {
    let root = try scratch(), producer = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, bytes) = try await sealedAttachment(root: producer)
    let operation = try referencing(file)
    let (initial, store, _) = try await engine(root: root, server: server)
    let receipt = try await initial.enqueue([operation], files: [file])
    XCTAssertEqual(receipt.operationIds, [operation.opId])
    XCTAssertEqual(try store.rows("SELECT bytes FROM objects").first?[0], bytes)
    try FileManager.default.removeItem(at: file.localURL)
    let readerStore = try makeStore(root)
    let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("files-domain"), acceptsFiles: true)
    let reopened = try CloudSyncEngine(store: readerStore, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: readerStore),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in }, firstUpload: true)
    try await reopened.register(adapter: adapter)
    _ = try await reopened.flush()
    // Staging bound (round 4): the sealed bytes leave this Mac at the cloud's read-back receipt, and this Mac's
    // own record is not handed back to its adapter (that would mean downloading the file again).
    let copied = await adapter.fileBytes(file.blobId)
    XCTAssertNil(copied)
    XCTAssertEqual(try readerStore.rows("SELECT length(bytes) FROM objects WHERE blobId=?", [Data(file.blobId.utf8)]).first.map { String(decoding: $0[0], as: UTF8.self) }, "0")
    XCTAssertTrue(try readerStore.pending().isEmpty)
    let references = try await server.readBlobs(ids: [file.blobId])
    XCTAssertEqual(references.first?.blob, file.reference)
    let remote = try await server.download(try XCTUnwrap(references.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    XCTAssertEqual(remote, bytes)
    _ = try await reopened.enqueue([operation], files: [])
    let noMore = try await reopened.flush()
    XCTAssertTrue(noMore.isEmpty)
    let segmentCount = await server.segmentCount()
    XCTAssertEqual(segmentCount, 1)
  }
  func testSealedFileBadHashOrUnsealedInputAcknowledgesNothing() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store, _) = try await engine(root: scratch(), server: server)
    let (file, _) = try await sealedAttachment(root: root)
    try Data("not an envelope".utf8).write(to: file.localURL)
    do { _ = try await engine.enqueue([referencing(file)], files: [file]); XCTFail("Bad attachment accepted") }
    catch { XCTAssertEqual(error as? CloudFailure, .checksumMismatch) }
    XCTAssertTrue(try store.pending().isEmpty)
    XCTAssertTrue(try store.rows("SELECT blobId FROM objects").isEmpty)
  }
  func testFileFinalizeCrashNeverPublishesSegmentBeforeFiles() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, bytes) = try await sealedAttachment(root: scratch())
    let (initial, store, _) = try await engine(root: root, server: server, fault: { if $0 == .afterFinalize { throw CloudFailure.unavailable } })
    _ = try await initial.enqueue([referencing(file)], files: [file])
    do { _ = try await initial.flush(); XCTFail("Kill point missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 0)
    XCTAssertEqual(try store.pending().count, 1)
    let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("reopened"), acceptsFiles: true)
    let reopenedStore = try makeStore(root)
    let reopened = try CloudSyncEngine(store: reopenedStore, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: reopenedStore),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in }, firstUpload: true)
    try await reopened.register(adapter: adapter)
    _ = try await reopened.flush()
    // The file reached the cloud before the segment; this Mac's own record is not handed back (staging bound).
    let references = try await server.readBlobs(ids: [file.blobId])
    let remote = try await server.download(try XCTUnwrap(references.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    XCTAssertEqual(remote, bytes)
    XCTAssertTrue(try reopenedStore.pending().isEmpty)
  }
}

/// Test-only encrypted port. The engine can open the outer pack, but an attempt to open an inner record fails.
actor CloudSyncProtectedFixtureContent: CloudContentPort {
  let key = SymmetricKey(data: Data(repeating: 13, count: 32))
  var innerIds = Set<String>()
  var opened: [String] = []
  var available = true
  func lock(_ value: Bool) { available = !value }
  func markInner(_ id: String) { innerIds.insert(id) }
  func openedIds() -> [String] { opened }
  var epoch = 1
  func setEpoch(_ value: Int) { epoch = value }
  func state(storageClass: CloudStorageClass) async -> CloudContentState { .init(available: available && storageClass == .secrets, epoch: epoch) }
  func seal(_ bytes: Data, blobId: String, storageClass: CloudStorageClass, purpose: CloudPurpose, epoch: Int, codec: CloudContentCodec) async throws -> CloudContentEnvelope {
    guard available, storageClass == .secrets else { throw CloudFailure.secretsLocked }
    let box = try AES.GCM.seal(bytes, using: key)
    return .init(v: 1, suite: "A256GCM-HKDF-SHA256", storageClass: .secrets, purpose: purpose, epoch: epoch, blobId: blobId,
      codec: .identity, plainBytes: Int64(bytes.count), nonce: CloudSyncBytes.base64(Data(box.nonce)),
      ciphertext: CloudSyncBytes.base64(box.ciphertext), tag: CloudSyncBytes.base64(box.tag))
  }
  func open(_ envelope: CloudContentEnvelope) async throws -> Data {
    guard available, !innerIds.contains(envelope.blobId) else { throw CloudFailure.secretsLocked }
    opened.append(envelope.blobId)
    let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: CloudSyncBytes.unbase64(envelope.nonce)),
      ciphertext: CloudSyncBytes.unbase64(envelope.ciphertext), tag: CloudSyncBytes.unbase64(envelope.tag))
    return try AES.GCM.open(box, using: key)
  }
}

extension CloudSyncTests {
  func testProtectedSegmentsUseInjectedPortAndNeverOpenRecordPlaintext() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let innerId = UUID().uuidString.lowercased(), id = UUID().uuidString.lowercased()
    let sentinel = Data("fixture-only-secret-never-in-sync-store".utf8)
    let envelope = try await protected.seal(sentinel, blobId: innerId, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
    await protected.markInner(innerId)
    let payload = CloudValue(try NativeRPCValue.parseJSON(CloudSyncCanonical.encode(envelope)))
    let operation = CloudOperation(v: 1, opId: id, originDevice: device, domain: "api-key", entityId: id, revision: id, parents: [], kind: .put,
      source: .init(sourceId: "fixture-source", recordId: id), createdAt: 1000, payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
    func client(_ root: URL) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncFixtureAdapter) {
      let store = try makeStore(root), adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"), domain: "api-key")
      let engine = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
        subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], secretsDomains: ["api-key"], secretsContent: protected,
        signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in }, firstUpload: true)
      try await engine.register(adapter: adapter)
      return (engine, store, adapter)
    }
    let (sender, _, _) = try await client(scratch())
    _ = try await sender.enqueue([operation])
    _ = try await sender.flush()
    let page = try await server.changes(after: .zero, limit: 64)
    XCTAssertEqual(page.segments.first?.storageClass, .secrets)
    let (reader, store, adapter) = try await client(scratch())
    await protected.lock(true)
    _ = try await reader.pull()
    let locked = try await reader.restoreProgress()
    XCTAssertEqual(locked.secretsSeq, .zero)
    XCTAssertEqual(locked.blocked, 1)
    await protected.lock(false)
    _ = try await reader.pull()
    let progress = try await reader.restoreProgress(), count = await adapter.count()
    XCTAssertEqual(progress.secretsSeq, CloudSequence(1))
    XCTAssertEqual(count, 1)
    let opened = await protected.openedIds()
    XCTAssertFalse(opened.contains(innerId))
    XCTAssertEqual(try store.operations(), [operation])
    for row in try store.rows("SELECT bytes FROM records") { XCTAssertNil(row[0].range(of: sentinel)) }
    _ = try await reader.pull()
    let effects = await adapter.effectCount()
    XCTAssertEqual(effects, 1)
  }
}

private actor CloudSyncPagedFixtureAdapter: CloudDomainAdapter {
  nonisolated let inventoryRows = ["I01"]
  let adapter: CloudSyncFixtureAdapter
  let store: CloudSyncStore
  let operations: [CloudOperation]
  let changedCut: Bool
  var pagesRequested = 0
  var priorPageDurable = true
  init(adapter: CloudSyncFixtureAdapter, store: CloudSyncStore, operations: [CloudOperation], changedCut: Bool = false) {
    self.adapter = adapter; self.store = store; self.operations = operations; self.changedCut = changedCut
  }
  func sourceInventory() async throws -> [CloudSourceInventory] { try await adapter.sourceInventory() }
  func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot { throw CloudFailure.unsupportedFormat }
  func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
    let reader = CloudSyncPagedFixtureReader(owner: self, cut: cut)
    return AsyncThrowingStream(unfolding: { try await reader.next() })
  }
  func page(_ index: Int, cut: CloudSnapshotCut) throws -> CloudDomainSnapshot? {
    if index == operations.count { return nil }
    if index > 0 {
      let saved = try store.rows("SELECT opId FROM snapshot_records WHERE snapshotId=? AND opId=?", [Data(cut.snapshotId.utf8), Data(operations[index - 1].opId.utf8)])
      priorPageDurable = priorPageDurable && !saved.isEmpty
    }
    pagesRequested += 1
    let actualCut = CloudSnapshotCut(snapshotId: changedCut && index == 1 ? UUID().uuidString.lowercased() : cut.snapshotId,
      at: cut.at, watermarks: ["fixture-source": "fixture-watermark"])
    return .init(cut: actualCut, operations: [operations[index]], files: [], coverage: [
      .init(sourceId: "fixture-source", inventoryRow: "I01", complete: index == operations.count - 1, items: index + 1, bytes: 0, blockedReasons: [])])
  }
  func observed() -> (Int, Bool) { (pagesRequested, priorPageDurable) }
  func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> { await adapter.changes(after: after) }
  func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport { try await adapter.validateIncoming(operations, files: files) }
  func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt { try await adapter.applyPrepared(prepared, origin: origin) }
  func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification { try await adapter.verify(receipt) }
}
private actor CloudSyncPagedFixtureReader {
  let owner: CloudSyncPagedFixtureAdapter
  let cut: CloudSnapshotCut
  var index = 0
  init(owner: CloudSyncPagedFixtureAdapter, cut: CloudSnapshotCut) { self.owner = owner; self.cut = cut }
  func next() async throws -> CloudDomainSnapshot? {
    let page = try await owner.page(index, cut: cut); index += 1; return page
  }
}

extension CloudSyncTests {
  func testPagedBootstrapPersistsBeforeNextPageAndPublishesVerifiedCheckpoint() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store, domain) = try await engine(root: root, server: server, packLimit: 1400)
    let operations = try (0..<40).map { try op(entity: "page-\($0)", text: String(repeating: "p", count: 60)) }
    let source = CloudSyncPagedFixtureAdapter(adapter: domain, store: store, operations: operations)
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: [:])
    let receipt = try await engine.bootstrap(sources: [source], cut: cut)
    XCTAssertTrue(receipt.published)
    let observed = await source.observed()
    XCTAssertEqual(observed.0, operations.count)
    XCTAssertTrue(observed.1)
    XCTAssertEqual(try store.queuedCount(), 0)
    // Round 5 item B: each page was durable before the next one was asked for (observed.1); once setup finished,
    // its staging rows are removed (before: all 40 rows stayed for ever).
    XCTAssertTrue(try store.rows("SELECT opId FROM snapshot_records WHERE snapshotId=?", [Data(cut.snapshotId.utf8)]).isEmpty)
    let reopened = try makeStore(root)
    XCTAssertEqual(try reopened.value("brainSeq"), CloudSequence(1))
    let (reader, restored, adapter) = try await self.engine(root: scratch(), server: server)
    _ = try await reader.pull()
    let count = await adapter.count()
    XCTAssertEqual(count, operations.count)
    XCTAssertEqual(Set(try restored.operations().map(\.opId)), Set(operations.map(\.opId)))
  }
  func testPagedBootstrapRejectsChangedCutBeforeAnyUploadOrApply() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store, domain) = try await engine(root: scratch(), server: server)
    let source = try CloudSyncPagedFixtureAdapter(adapter: domain, store: store, operations: [op(), op(entity: "second")], changedCut: true)
    do {
      _ = try await engine.bootstrap(sources: [source], cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: [:]))
      XCTFail("Changed cut was accepted")
    } catch { XCTAssertEqual(error as? CloudFailure, .versionChanged) }
    let objects = await server.objectCount(), segments = await server.segmentCount(), effects = await domain.effectCount()
    XCTAssertEqual(objects, 0)
    XCTAssertEqual(segments, 0)
    XCTAssertEqual(effects, 0)
    XCTAssertNil(try store.value("brainSeq") as CloudSequence?)
  }
}

extension CloudSyncTests {
  func testPagedBootstrapRequiresCoverageForEveryDeclaredSource() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (engine, store, domain) = try await engine(root: scratch(), server: server)
    let source = CloudSyncPagedFixtureAdapter(adapter: domain, store: store, operations: [])
    do {
      _ = try await engine.bootstrap(sources: [source], cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: [:]))
      XCTFail("Missing coverage accepted")
    } catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    let objects = await server.objectCount(), segments = await server.segmentCount()
    XCTAssertEqual(objects, 0)
    XCTAssertEqual(segments, 0)
    XCTAssertNil(try store.value("brainSeq") as CloudSequence?)
  }
  func testSocketHelloAfterRestartCatchesUpFromDurableCursorWithoutChangedHint() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    let (sender, _, _) = try await engine(root: scratch(), server: server)
    _ = try await sender.enqueue([op(entity: "first")]); _ = try await sender.flush()
    let (initial, _, _) = try await engine(root: root, server: server)
    _ = try await initial.pull()
    _ = try await sender.enqueue([op(entity: "second")]); _ = try await sender.flush()
    let before = await server.cursors().count
    let (reopened, store, adapter) = try await engine(root: root, server: server)
    await reopened.startEvents()
    for _ in 0..<500 {
      let cursor: CloudSequence = try store.value("brainSeq") ?? .zero
      if cursor == CloudSequence(2) { break }
      try await Task.sleep(for: .milliseconds(2))
    }
    let count = await adapter.count(), cursors = await server.cursors()
    XCTAssertEqual(count, 2)
    XCTAssertEqual(cursors.dropFirst(before).first, CloudSequence(1))
    XCTAssertEqual(try store.value("brainSeq"), CloudSequence(2))
    XCTAssertEqual(try store.queuedCount(), 0)
    await reopened.stop()
  }
}

extension CloudSyncTests {
  func testInterruptedSnapshotCannotFlushPartialCutAfterRestart() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (first, store, domain) = try await engine(root: root, server: server)
    let operations = try [op(entity: "cut-first"), op(entity: "cut-second")]
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: [:])
    let source = CloudSyncPagedFixtureAdapter(adapter: domain, store: store, operations: operations, changedCut: true)
    do { _ = try await first.bootstrap(sources: [source], cut: cut); XCTFail("Cut mismatch accepted") }
    catch { XCTAssertEqual(error as? CloudFailure, .versionChanged) }
    let (reopened, reopenedStore, _) = try await engine(root: root, server: server)
    do { _ = try await reopened.flush(); XCTFail("Partial cut published") }
    catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    XCTAssertEqual(try reopenedStore.queuedCount(), 1)
    let progress = try await reopened.restoreProgress()
    XCTAssertEqual(progress.blocked, 1)
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 0)
    let complete = CloudSyncPagedFixtureAdapter(adapter: domain, store: reopenedStore, operations: operations)
    let receipt = try await reopened.bootstrap(sources: [complete], cut: cut)
    XCTAssertTrue(receipt.published)
    XCTAssertEqual(try reopenedStore.queuedCount(), 0)
    XCTAssertNil(try reopenedStore.value("bootstrapInProgress") as String?)
  }
}
