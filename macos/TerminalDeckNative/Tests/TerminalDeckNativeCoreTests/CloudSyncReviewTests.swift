import XCTest
import Foundation
import CryptoKit
@testable import TerminalDeckNativeCore

extension CloudSyncTests {
  func reviewProtectedOperation(_ content: CloudSyncProtectedFixtureContent) async throws -> CloudOperation {
    let inner = UUID().uuidString.lowercased(), id = UUID().uuidString.lowercased()
    let envelope = try await content.seal(Data("fixture-only protected record".utf8), blobId: inner, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
    await content.markInner(inner)
    let payload = CloudValue(try NativeRPCValue.parseJSON(CloudSyncCanonical.encode(envelope)))
    return .init(v: 1, opId: id, originDevice: device, domain: "api-key", entityId: id, revision: id, parents: [], kind: .put,
      source: .init(sourceId: "fixture-source", recordId: id), createdAt: 1000, payload: payload, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(payload)))
  }
  func reviewProtectedClient(_ root: URL, server: CloudSyncFixtureServer, content: CloudSyncProtectedFixtureContent) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncFixtureAdapter) {
    let store = try makeStore(root), adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("protected"), domain: "api-key")
    let client = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], secretsDomains: ["api-key"], secretsContent: content,
      signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in }, firstUpload: true)
    try await client.register(adapter: adapter)
    return (client, store, adapter)
  }
  func reviewEmptyCheckpoint(through: CloudSequence, server: CloudSyncFixtureServer) async throws -> CloudCheckpoint {
    let id = UUID().uuidString.lowercased()
    let counts = CloudCounts(domains: 0, records: 0, files: 0, bytes: 2, blocked: 0)
    let value = CloudValue(.object([.init("v", .number(1)), .init("throughSeq", .string(through.rawValue)), .init("createdAt", .number(1000)),
      .init("sourceSnapshotId", .string(UUID().uuidString.lowercased())), .init("domains", .array([])), .init("pathMaps", .array([])),
      .init("sourceCoverage", .array([])), .init("counts", try NativeRPCValue.parseJSON(CloudSyncCanonical.encode(counts)))]))
    let plain = try CloudSyncCanonical.encode(value)
    let envelope = try await makeContent().seal(plain, blobId: id, storageClass: .brain, purpose: .brain, epoch: 1, codec: .identity)
    let bytes = try CloudSyncCanonical.encode(envelope), ref = CloudSyncBytes.blob(bytes, envelope: envelope)
    let upload = CloudBlobUpload(uploadId: UUID().uuidString.lowercased(), blobId: id, storageClass: .brain, purpose: .brain, keyEpoch: 1,
      bytes: ref.bytes, sha256: ref.sha256, md5: ref.md5)
    let tickets = try await server.prepareBlobs([upload])
    let ticket = try XCTUnwrap(tickets.first)
    try await server.upload(bytes, ticket: ticket)
    _ = try await server.finalizeBlobs([.init(uploadId: upload.uploadId, blobId: id, ticket: ticket.ticket)])
    let checkpoint = CloudCheckpoint(checkpointId: UUID().uuidString.lowercased(), throughSeq: through, root: ref,
      inventoryDigest: CloudSyncBytes.hash(plain), counts: counts, verifiedBy: [device])
    try await server.installCheckpointForReview(checkpoint)
    return checkpoint
  }
  func testReview01LaterBrainCheckpointDoesNotSkipSecretSequenceOneAfterRestart() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), protected = CloudSyncProtectedFixtureContent()
    let operation = try await reviewProtectedOperation(protected)
    let (sender, _, _) = try await reviewProtectedClient(scratch(), server: server, content: protected)
    _ = try await sender.enqueue([operation]); _ = try await sender.flush()
    _ = try await reviewEmptyCheckpoint(through: CloudSequence(1), server: server)
    let root = try scratch()
    let (locked, lockedStore, _) = try await reviewProtectedClient(root, server: server, content: protected)
    await protected.lock(true)
    _ = try await locked.pull()
    XCTAssertEqual(try lockedStore.value("secretsSeq") as CloudSequence? ?? .zero, .zero)
    let (reopened, store, adapter) = try await reviewProtectedClient(root, server: server, content: protected)
    await protected.lock(false)
    _ = try await reopened.pull()
    let count = await adapter.count()
    XCTAssertEqual(count, 1)
    // Round 5 item B: the applied record keeps its skeleton in the sync store; its content is with the adapter.
    XCTAssertEqual(try store.operations(), [CloudSyncStore.skeleton(operation)])
    XCTAssertEqual(try store.value("secretsSeq"), CloudSequence(1))
    let page = try await server.changes(after: .zero, limit: 1)
    let applied = try XCTUnwrap(page.segments.first)
    XCTAssertTrue(try store.applied(id: XCTUnwrap(applied.segmentId), seq: applied.seq, digest: XCTUnwrap(applied.sha256)))
    XCTAssertEqual(try store.rows("SELECT checkpointId FROM checkpoint_applied").count, 1)
    _ = try await reopened.pull()
    let effects = await adapter.effectCount()
    XCTAssertEqual(effects, 1)
  }
}

extension CloudSyncTests {
  func reviewBrainSegment(_ operations: [CloudOperation]) async throws -> CloudSegment {
    let id = UUID().uuidString.lowercased()
    let envelope = try await makeContent().seal(CloudSyncPack.encode(operations), blobId: id, storageClass: .brain, purpose: .brain, epoch: 1, codec: .identity)
    let bytes = try CloudSyncCanonical.encode(envelope)
    return .init(descriptor: .init(segmentId: id, requestId: UUID().uuidString.lowercased(), storageClass: .brain, purpose: .brain,
      domains: Array(Set(operations.map(\.domain))).sorted(), keyEpoch: 1, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count),
      opCount: operations.count, format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64))), ciphertext: CloudSyncBytes.base64(bytes))
  }
  func testReview02RacingFirstSegmentMakesInitializationLoserImportBothVersions() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let peer = "44444444-4444-4444-8444-444444444444"
    let remote = try op(entity: "racing", text: "remote", origin: peer), local = try op(entity: "racing", text: "local")
    let segment = try await reviewBrainSegment([remote])
    await server.raceFirstCheckpoint(with: segment, deviceId: peer)
    CloudSyncFullHTTP.registry.set(server)
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let (loser, store, budget) = try await reviewHTTPFileClient(scratch(), server: server)
    let receipt = try await loser.bootstrap([snapshot([local])])
    XCTAssertTrue(receipt.published)
    XCTAssertNotEqual(remote.originDevice, local.originDevice)
    let feed = try await server.changes(after: .zero, limit: 64)
    XCTAssertEqual(feed.segments.first?.deviceId, peer)
    XCTAssertEqual(Set(try store.operations().map(\.opId)), [remote.opId, local.opId])
    let current = try await server.checkpoint()
    let checkpoint = try XCTUnwrap(current)
    XCTAssertGreaterThanOrEqual(checkpoint.throughSeq, CloudSequence(2))
    let (reader, restored, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertEqual(Set(try restored.operations().map(\.opId)), [remote.opId, local.opId])
    XCTAssertEqual(try CloudSyncPack.heads(restored.operations()).count, 2)
    let state = try await budget.status()
    XCTAssertEqual(state.failures, 0)
    XCTAssertNil(state.blocked)
    await loser.stop()
  }
  /// The current Worker lacks the atomic zero-head guard: the raced inventory is recorded at 0 while
  /// its manifest names slot 1. Neither the publisher nor a fresh reader may reject or skip anything.
  func testReview02UnguardedWorkerRacedCheckpointAtZeroStillRestoresBothVersions() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    await server.withoutZeroHeadGuard()
    let peer = "44444444-4444-4444-8444-444444444444"
    let remote = try op(entity: "racing", text: "remote", origin: peer), local = try op(entity: "racing", text: "local")
    let segment = try await reviewBrainSegment([remote])
    await server.raceFirstCheckpoint(with: segment, deviceId: peer)
    let (publisher, published, _) = try await engine(root: scratch(), server: server)
    let receipt = try await publisher.bootstrap([snapshot([local])])
    XCTAssertTrue(receipt.published)
    XCTAssertEqual(receipt.throughSeq, .zero)
    let current = try await server.checkpoint()
    XCTAssertEqual(try XCTUnwrap(current).throughSeq, .zero)
    XCTAssertEqual(Set(try published.operations().map(\.opId)), [remote.opId, local.opId])
    XCTAssertEqual(try published.queuedCount(), 0)
    XCTAssertNil(try published.value("bootstrapInProgress") as String?)
    let (reader, restored, adapter) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertEqual(Set(try restored.operations().map(\.opId)), [remote.opId, local.opId])
    XCTAssertEqual(try CloudSyncPack.heads(restored.operations()).count, 2)
    XCTAssertEqual(try restored.value("brainSeq"), CloudSequence(1))
    let effects = await adapter.effectCount()
    XCTAssertEqual(effects, 2)
    let ready = try await reader.contextReady(projectId: "fixture-project")
    XCTAssertTrue(ready.verified)
  }
}

extension CloudSyncTests {
  func reviewDevicePublicKey(_ seed: UInt8) throws -> Data {
    try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32)).publicKey.x963Representation
  }
  func reviewRegisteredClient(_ root: URL, server: CloudSyncFixtureServer, registration: String, signatureByte: UInt8,
                              fault: @escaping CloudSyncFault = { _ in }) async throws -> (CloudSyncEngine, CloudSyncStore) {
    let store = try makeStore(root), adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("registered"), acceptsFiles: true)
    let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: signatureByte, count: 32))
    let client = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: registration, epoch: 1, brainDomains: ["memory"],
      signer: { CloudSyncBytes.base64(try key.signature(for: $0).rawRepresentation) }, verifySignature: { _, _ in }, firstUpload: true, fault: fault)
    try await client.register(adapter: adapter)
    return (client, store)
  }
  func reviewFollowingClient(_ root: URL, server: CloudSyncFixtureServer, registration: String, keys: [String: UInt8]) async throws -> (CloudSyncEngine, CloudSyncStore) {
    let store = try makeStore(root), adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("registered"), acceptsFiles: true)
    let client = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: registration, epoch: 1, brainDomains: ["memory"],
      deviceSigner: { device, payload in
        guard let seed = keys[device] else { throw CloudFailure.unsafeConfiguration }
        let key = try P256.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        return CloudSyncBytes.base64(try key.signature(for: payload).rawRepresentation)
      }, verifySignature: { _, _ in }, firstUpload: true)
    try await client.register(adapter: adapter)
    return (client, store)
  }
  func testReview03NewDeviceReplacesUnfinishedUploadAndSignedAttemptWithoutChangingOperations() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, bytes) = try await sealedAttachment(root: scratch()), operation = try referencing(file)
    try await server.registration(device, publicKey: reviewDevicePublicKey(7))
    let (first, originalStore) = try await reviewRegisteredClient(root, server: server, registration: device, signatureByte: 7,
      fault: { if $0 == .afterUpload { throw CloudFailure.unavailable } })
    _ = try await first.enqueue([operation], files: [file])
    do { _ = try await first.flush(); XCTFail("Interruption missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let before = await server.uploadIds()
    try await CloudSyncBudget(store: originalStore).failed(CloudFailure.remote(.init(code: "bad_device_proof", message: "Fixture old key refused.", retryable: false, requestId: operation.opId)), httpStatus: 401)
    let replacement = "55555555-5555-4555-8555-555555555555"
    try await server.registration(replacement, publicKey: reviewDevicePublicKey(8))
    let (reopened, store) = try await reviewRegisteredClient(root, server: server, registration: replacement, signatureByte: 8)
    _ = try await reopened.flush()
    let after = await server.uploadIds(), count = await server.segmentCount()
    XCTAssertEqual(before.count, 1)
    XCTAssertEqual(after.count, 2)
    XCTAssertEqual(count, 1)
    XCTAssertEqual(try store.operations(), [operation])
    XCTAssertEqual(try store.queuedCount(), 0)
    XCTAssertEqual(try store.rows("SELECT segmentId FROM segment_bindings WHERE retired=1").count, 1)
    let refs = try await server.readBlobs(ids: [file.blobId])
    let remote = try await server.download(try XCTUnwrap(refs.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    XCTAssertEqual(remote, bytes)
  }
  func testReview03NewDeviceReconcilesCommittedLostACKBeforeRepacking() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device), operation = try op()
    try await server.registration(device, publicKey: reviewDevicePublicKey(7))
    let (first, _) = try await reviewRegisteredClient(root, server: server, registration: device, signatureByte: 7,
      fault: { if $0 == .afterCommit { throw CloudFailure.unavailable } })
    _ = try await first.enqueue([operation])
    do { _ = try await first.flush(); XCTFail("Lost ACK missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let replacement = "55555555-5555-4555-8555-555555555555"
    try await server.registration(replacement, publicKey: reviewDevicePublicKey(8))
    let (reopened, store) = try await reviewRegisteredClient(root, server: server, registration: replacement, signatureByte: 8)
    _ = try await reopened.flush()
    let count = await server.segmentCount()
    XCTAssertEqual(count, 1)
    XCTAssertEqual(try store.queuedCount(), 0)
    XCTAssertEqual(try store.operations(), [operation])
  }
}

extension CloudSyncTests {
  func testReview04NonemptyFeedWithoutCheckpointBuildsInventoryAndDrainsLaterEdits() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let remote = try op(entity: "remote-first"), local = try op(entity: "local-cut"), later = try op(entity: "local-later")
    _ = try await server.commit(reviewBrainSegment([remote]))
    let (client, store, _) = try await engine(root: scratch(), server: server)
    await server.beforeNextCheckpoint { [client, later] in _ = try await client.enqueue([later]) }
    let receipt = try await client.bootstrap([snapshot([local])])
    XCTAssertTrue(receipt.published)
    XCTAssertGreaterThanOrEqual(receipt.throughSeq, CloudSequence(2))
    XCTAssertEqual(try store.queuedCount(), 0)
    XCTAssertNil(try store.value("bootstrapInProgress") as String?)
    let published = try await server.checkpoint()
    let checkpoint = try XCTUnwrap(published)
    let refs = try await server.readBlobs(ids: [checkpoint.root.blobId])
    let rootBytes = try await server.download(try XCTUnwrap(refs.first?.getUrl), maximumBytes: CloudWire.maximumBlobBytes)
    let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: rootBytes)
    let manifest = try await makeContent().open(envelope)
    let sourceCounts = OrderedJSON.parse(manifest)?["sourceCoverage"]?.array
    XCTAssertEqual(sourceCounts?.first?["items"]?.number, 2)
    _ = try await client.enqueue([op(entity: "after-inventory")])
    _ = try await client.flush()
    let (reader, restored, _) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    XCTAssertEqual(try restored.operations().count, 4)
    XCTAssertTrue(Set(try restored.operations().map(\.opId)).isSuperset(of: [remote.opId, local.opId, later.opId]))
  }
}

extension CloudSyncTests {
  func reviewHTTPFileClient(_ root: URL, server: CloudSyncFixtureServer) async throws -> (CloudSyncEngine, CloudSyncStore, CloudSyncBudget) {
    let store = try makeStore(root), budget = CloudSyncBudget(store: store)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CloudSyncFullHTTP.self]
    let endpoint = try CloudSyncEndpoint(base: URL(string: "https://cloud.test/v1")!, environment: .test, objectHosts: ["cloud.test"])
    let signer: CloudSyncSigner = { CloudSyncBytes.base64(try CloudSyncFixtureAuth.key.signature(for: $0).rawRepresentation) }
    let transport = try CloudSyncTransport(fixtureEndpoint: endpoint, auth: CloudSyncFixtureAuth(), signer: signer, store: store,
      budget: budget, fixtureSession: URLSession(configuration: configuration))
    let client = try CloudSyncEngine(store: store, transport: transport, objects: transport, content: makeContent(), budget: budget,
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], signer: signer, verifySignature: { _, _ in }, firstUpload: true)
    try await client.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"), acceptsFiles: true))
    return (client, store, budget)
  }
  func testReview05HTTP200RetryableFinalizeItemKeepsQueueAndPersistsBackoff() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device), root = try scratch()
    CloudSyncFullHTTP.registry.set(server)
    defer { CloudSyncFullHTTP.registry.set(nil) }
    let (client, store, budget) = try await reviewHTTPFileClient(root, server: server)
    let (file, _) = try await sealedAttachment(root: scratch())
    _ = try await client.enqueue([referencing(file)], files: [file])
    await server.failFinalizationOnce()
    do { _ = try await client.flush(); XCTFail("Temporary finalize failure was hidden") }
    catch {
      guard case CloudFailure.remote(let detail) = error else { return XCTFail("Finalize error lost its meaning") }
      XCTAssertEqual(detail.code, "temporarily_unavailable")
      XCTAssertTrue(detail.retryable)
    }
    let state = try await budget.status()
    XCTAssertEqual(state.failures, 1)
    XCTAssertGreaterThan(state.retryAt, CloudSyncBytes.now())
    XCTAssertEqual(try store.queuedCount(), 1)
    let resumed = CloudSyncBudget(store: try makeStore(root))
    let persisted = try await resumed.status()
    XCTAssertEqual(persisted.retryAt, state.retryAt)
    try await budget.resume(networkOrWake: true, userRetry: true)
    _ = try await client.flush()
    XCTAssertEqual(try store.queuedCount(), 0)
    let segments = await server.segmentCount()
    XCTAssertEqual(segments, 1)
    await client.stop()
  }
}

extension CloudSyncTests {
  func testReview06LockedProtectedHistoryKeepsWarningButAllowsVerifiedBrainContext() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let memory = try op(entity: "restored-memory")
    let (client, _, _) = try await engine(root: scratch(), server: server)
    _ = try await client.bootstrap([snapshot([memory])])
    let protected = CloudSyncProtectedFixtureContent(), operation = try await reviewProtectedOperation(protected)
    let id = UUID().uuidString.lowercased()
    let envelope = try await protected.seal(CloudSyncPack.encode([operation]), blobId: id, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
    let bytes = try CloudSyncCanonical.encode(envelope)
    _ = try await server.commit(.init(descriptor: .init(segmentId: id, requestId: UUID().uuidString.lowercased(), storageClass: .secrets,
      purpose: .secret, domains: ["api-key"], keyEpoch: 1, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count), opCount: 1,
      format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64))), ciphertext: CloudSyncBytes.base64(bytes)))
    let (reader, _, adapter) = try await engine(root: scratch(), server: server)
    _ = try await reader.pull()
    let progress = try await reader.restoreProgress(), ready = try await reader.contextReady(projectId: "fixture-project")
    XCTAssertEqual(progress.secretsSeq, .zero)
    XCTAssertEqual(progress.blocked, 1)
    XCTAssertTrue(ready.verified)
    XCTAssertEqual(ready.sourceCounts.blocked, 0)
    let count = await adapter.count()
    XCTAssertEqual(count, 1)
  }
}

private struct CloudSyncReviewFilesSource: CloudDomainAdapter {
  let adapter: CloudSyncFixtureAdapter
  let files: [CloudLocalBlob]
  let operations: [CloudOperation]
  var inventoryRows: [String] { ["I01"] }
  func sourceInventory() async throws -> [CloudSourceInventory] { try await adapter.sourceInventory() }
  func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot { throw CloudFailure.unsupportedFormat }
  func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
    let reader = CloudSyncReviewFilesReader(files: files, operations: operations, cut: cut)
    return AsyncThrowingStream(unfolding: { await reader.next() })
  }
  func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> { await adapter.changes(after: after) }
  func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport { try await adapter.validateIncoming(operations, files: files) }
  func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt { try await adapter.applyPrepared(prepared, origin: origin) }
  func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification { try await adapter.verify(receipt) }
}
private actor CloudSyncReviewFilesReader {
  let files: [CloudLocalBlob], operations: [CloudOperation], cut: CloudSnapshotCut
  var sentFiles = false, offset = 0
  init(files: [CloudLocalBlob], operations: [CloudOperation], cut: CloudSnapshotCut) { self.files = files; self.operations = operations; self.cut = cut }
  func next() -> CloudDomainSnapshot? {
    if !sentFiles { sentFiles = true; return .init(cut: cut, operations: [], files: files, coverage: []) }
    if offset == operations.count { return nil }
    let page = Array(operations[offset..<min(offset + 64, operations.count)])
    offset += page.count
    return .init(cut: cut, operations: page, files: [], coverage: offset == operations.count ? [
      .init(sourceId: "fixture-source", inventoryRow: "I01", complete: true, items: operations.count, bytes: 0, blockedReasons: [])] : [])
  }
}

extension CloudSyncTests {
  func testReview07FileOnlyPagesAndManyRecordsCreateOnlyActualDependencyEdges() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, adapter) = try await engine(root: root, server: server)
    var files: [CloudLocalBlob] = []
    for _ in 0..<40 { files.append(try await sealedAttachment(root: scratch()).0) }
    let operations = try (0..<400).map { try referencing(files[$0 % files.count]) }
    let source = CloudSyncReviewFilesSource(adapter: adapter, files: files, operations: operations)
    // Since the staging bound (39515d62) setup uploads each page's files as the page arrives, so the old way of
    // stopping "at the first network call, after enumeration" now stops after the FIRST page (the file-only one),
    // before any record page: that is why 0 edges were seen. The setup now runs to completion and the edges,
    // which stay after sending, are checked: exactly one per record, never a record x file cross product.
    let receipt = try await client.bootstrap(sources: [source], cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: [:]))
    XCTAssertTrue(receipt.published)
    XCTAssertEqual(try store.rows("SELECT opId FROM outbox_files").count, operations.count)
    XCTAssertEqual(try store.rows("SELECT blobId FROM retained_files").count, files.count)
    XCTAssertEqual(try store.queuedCount(), 0)
    for operation in operations {
      let refs = try store.fileReferences(for: [operation.opId])
      XCTAssertEqual(refs, try CloudSyncSealedFile.references(in: [operation]))
    }
  }
  func testReview07BatchEnqueueDoesNotPairUnrelatedFilesWithEveryOperation() async throws {
    let (client, store, _) = try await engine(root: scratch(), server: CloudSyncFixtureServer(root: scratch(), device: device))
    let (first, _) = try await sealedAttachment(root: scratch()), (second, _) = try await sealedAttachment(root: scratch())
    let operations = try [referencing(first), referencing(second)]
    _ = try await client.enqueue(operations, files: [first, second])
    XCTAssertEqual(try store.rows("SELECT opId FROM outbox_files").count, 2)
    XCTAssertEqual(try store.fileReferences(for: [operations[0].opId]), [first.reference])
    XCTAssertEqual(try store.fileReferences(for: [operations[1].opId]), [second.reference])
  }
}

extension CloudSyncTests {
  func testReviewJournalInterruptionDuringPartialBlobWriteRollsBackAndReopensOnce() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device), operation = try op()
    _ = try await server.commit(reviewBrainSegment([operation]))
    let store = try CloudSyncStore(root: root, subject: .init(issuer: "https://identity.test", sub: subject),
      journalFault: { if $0 == .duringJournalWrite { throw CloudFailure.unavailable } })
    let adapter = try CloudSyncFixtureAdapter(root: root.appendingPathComponent("domain"))
    let interrupted = try CloudSyncEngine(store: store, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: store),
      subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in }, firstUpload: true)
    try await interrupted.register(adapter: adapter)
    do { _ = try await interrupted.pull(); XCTFail("Partial journal write was not interrupted") }
    catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    XCTAssertTrue(try store.rows("SELECT bytes FROM prepare_journal").isEmpty)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence? ?? .zero, .zero)
    let before = await adapter.effectCount()
    XCTAssertEqual(before, 0)
    let (reopened, restored, owner) = try await engine(root: root, server: server)
    _ = try await reopened.pull()
    let effects = await owner.effectCount()
    XCTAssertEqual(effects, 1)
    XCTAssertEqual(try restored.operations(), [operation])
    XCTAssertEqual(try restored.value("brainSeq"), CloudSequence(1))
    XCTAssertTrue(try restored.rows("SELECT bytes FROM prepare_journal").isEmpty)
  }
}

extension CloudSyncTests {
  func testReview03RegistrationChangeIsDetectedWithoutReconstructingTheEngine() async throws {
    let root = try scratch(), server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (file, _) = try await sealedAttachment(root: scratch()), operation = try referencing(file)
    try await server.registration(device, publicKey: reviewDevicePublicKey(7))
    let (first, _) = try await reviewRegisteredClient(root, server: server, registration: device, signatureByte: 7,
      fault: { if $0 == .afterUpload { throw CloudFailure.unavailable } })
    _ = try await first.enqueue([operation], files: [file])
    do { _ = try await first.flush(); XCTFail("Interruption missed") } catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let replacement = "55555555-5555-4555-8555-555555555555"
    // Production path: the engine is created for the OLD registration and asks for the current key per signature.
    let (existing, store) = try await reviewFollowingClient(root, server: server, registration: device, keys: [device: 7, replacement: 8])
    try await server.registration(replacement, publicKey: reviewDevicePublicKey(8))
    _ = try await existing.flush()
    XCTAssertEqual(try store.value("activeOutboxDevice") as String?, replacement)
    XCTAssertEqual(try store.queuedCount(), 0)
    let uploads = await server.uploadIds(), segments = await server.segmentCount()
    XCTAssertEqual(uploads.count, 2)
    XCTAssertEqual(segments, 1)
    XCTAssertEqual(try store.operations(), [operation])
  }
}

extension CloudSyncTests {
  func testReview07OpaqueProducerAssociationsRemainExactWithoutOpeningRecords() async throws {
    let protected = CloudSyncProtectedFixtureContent(), root = try scratch()
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (client, store, _) = try await reviewProtectedClient(root, server: server, content: protected)
    let first = try await reviewProtectedOperation(protected)
    let second = try await reviewProtectedOperation(protected)
    let operations = [first, second]
    var files: [CloudLocalBlob] = []
    for _ in 0..<2 {
      let id = UUID().uuidString.lowercased()
      let envelope = try await protected.seal(Data("fixture-only sealed file".utf8), blobId: id, storageClass: .secrets, purpose: .secret, epoch: 1, codec: .identity)
      let bytes = try CloudSyncCanonical.encode(envelope), ref = CloudSyncBytes.blob(bytes, envelope: envelope)
      let file = try scratch().appendingPathComponent(id)
      try bytes.write(to: file)
      files.append(.init(blobId: id, sourceId: "fixture-source", localURL: file, bytes: ref.bytes, sha256: ref.sha256, md5: ref.md5,
        keyEpoch: 1, storageClass: .secrets, purpose: .secret))
    }
    do { _ = try await client.enqueue(operations, files: files); XCTFail("Ambiguous opaque associations accepted") }
    catch { XCTAssertEqual(error as? CloudFailure, .invalidRequest) }
    _ = try await client.enqueue(operations, files: files, associations: [
      CloudFileAssociation(operationId: operations[0].opId, blobIds: [files[0].blobId]), CloudFileAssociation(operationId: operations[1].opId, blobIds: [files[1].blobId])])
    XCTAssertEqual(try store.rows("SELECT opId FROM outbox_files").count, 2)
    XCTAssertEqual(try store.fileReferences(for: [operations[0].opId]), [files[0].reference])
    XCTAssertEqual(try store.fileReferences(for: [operations[1].opId]), [files[1].reference])
    let opened = await protected.openedIds()
    XCTAssertTrue(opened.isEmpty)
  }
}

extension CloudSyncTests {
  func testReview05HTTP200QuotaAuthAndPermanentItemsKeepTheirDistinctBlockedStates() async throws {
    defer { CloudSyncFullHTTP.registry.set(nil) }
    for (code, retryable, expected) in [("budget_paused", true, "rate"), ("device_revoked", false, "auth"), ("invalid_blob", false, "remote")] {
      let server = try CloudSyncFixtureServer(root: scratch(), device: device)
      CloudSyncFullHTTP.registry.set(server)
      let (client, store, budget) = try await reviewHTTPFileClient(scratch(), server: server)
      let (file, _) = try await sealedAttachment(root: scratch())
      _ = try await client.enqueue([referencing(file)], files: [file])
      await server.failFinalizationOnce(code: code, retryable: retryable)
      do { _ = try await client.flush(); XCTFail("Finalize item failure was hidden") }
      catch {
        guard case CloudFailure.remote(let detail) = error else { return XCTFail("Finalize item code lost") }
        XCTAssertEqual(detail.code, code)
        XCTAssertEqual(detail.retryable, retryable)
      }
      let state = try await budget.status()
      XCTAssertEqual(state.blocked, expected)
      XCTAssertEqual(try store.queuedCount(), 1)
      let before = await server.calls
      do { _ = try await client.flush(); XCTFail("Blocked item retried automatically") }
      catch { XCTAssertEqual(error as? CloudFailure, .budgetPaused) }
      let after = await server.calls
      XCTAssertEqual(after, before)
      await client.stop()
    }
  }
}
