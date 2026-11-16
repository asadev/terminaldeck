import Foundation
@testable import TerminalDeckNativeCore

/// Fixture-only: an in-memory Cloud feed and object store for the upgrade test (the shapes of the core's own
/// `CloudSyncFixtureServer`, without its fault switches). Never reaches a network.
actor CloudUpgradeFixtureService: CloudTransportPort, CloudSyncObjectIO {
  /// MAC-NEXT-7 (5): retry back-offs on the fixture clock (100 times faster), never the real one.
  func backoff(milliseconds: Int64) async throws { try await Task.sleep(for: .milliseconds(max(1, milliseconds / 100))) }
    private(set) var head: UInt64 = 0
    private var segments: [String: CloudSegment] = [:]
    private var receipts: [String: CloudReceipt] = [:]
    private var segmentDevices: [String: String] = [:]
    private var objects: [String: Data] = [:]
    private var refs: [String: CloudBlobRef] = [:]
    private var staging: [String: Data] = [:]
    private var uploads: [String: CloudBlobUpload] = [:]
    private var device: String
    /// Every request this service answered (nothing at all reached it while the older build was stuck).
    private(set) var calls = 0
    init(device: String) { self.device = device }
    func switchDevice(_ id: String) { device = id }
    func segmentCount() -> Int { segments.count }
    func operationCount() -> Int { segments.values.reduce(0) { $0 + $1.descriptor.opCount } }
    /// Mac-next 2: packs in the order they were committed, and a commit that does not reach the service once.
    private(set) var committed: [CloudSegment] = []
    private var dropAfter: Int?
    /// After `count` more commits, the next one does not reach the service (once).
    func dropCommit(after count: Int) { dropAfter = count }
    private var loseAnswerAfter: Int?
    /// After `count` more commits, the next one IS stored but its answer is lost (once): the owner's 28th pack.
    func loseCommitAnswer(after count: Int) { loseAnswerAfter = count }

    func capabilities() async throws -> CloudGate { .init(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false) }
    func registerDevice(_ request: CloudDeviceRegistration) async throws -> CloudDeviceRegistrationReceipt {
        .init(deviceId: request.deviceId, status: .active, secretsApproved: false, headSeq: CloudSequence(head), vaultState: .unset)
    }
    func devices() async throws -> CloudDeviceList { .init(devices: [], receiverDeviceId: nil) }
    func state() async throws -> CloudRemoteState {
        calls += 1
        return .init(headSeq: CloudSequence(head), checkpoint: nil, devicesVersion: .zero, vaultState: .unset, vaultEpoch: 1, vaultVersion: .zero,
                     capabilities: try await capabilities(), budget: .init(day: "fixture", requestsLeft: 6000, writesLeft: 12000, bytesLeft: 20 * 1024 * 1024))
    }
    func commit(_ segment: CloudSegment) async throws -> CloudReceipt {
        if let n = dropAfter {
            if n == 0 { dropAfter = nil; throw URLError(.notConnectedToInternet) }
            dropAfter = n - 1
        }
        calls += 1
        let d = segment.descriptor
        let bytes = try CloudSyncBytes.unbase64(segment.ciphertext)
        guard bytes.count == d.bytes, CloudSyncBytes.hash(bytes) == d.sha256 else { throw CloudFailure.checksumMismatch }
        if let previous = segments[d.segmentId] {
            guard previous == segment, let receipt = receipts[d.segmentId] else { throw CloudFailure.idReused }
            return receipt
        }
        head += 1
        let receipt = CloudReceipt(segmentId: d.segmentId, seq: CloudSequence(head), headSeq: CloudSequence(head),
                                   receipt: .init(requestId: d.requestId, sha256: d.sha256, committedAt: 1000))
        segments[d.segmentId] = segment
        committed.append(segment)
        segmentDevices[d.segmentId] = device
        receipts[d.segmentId] = receipt
        if let n = loseAnswerAfter {
            if n == 0 { loseAnswerAfter = nil; throw URLError(.networkConnectionLost) }
            loseAnswerAfter = n - 1
        }
        return receipt
    }
    func changes(after: CloudSequence, limit: Int) async throws -> CloudChangePage {
        calls += 1
        let page = receipts.values.filter { $0.seq > after }.sorted { $0.seq < $1.seq }.prefix(limit)
        let entries = page.map { receipt -> CloudChangeEntry in
            let d = segments[receipt.segmentId]!.descriptor
            return .init(seq: receipt.seq, storageClass: d.storageClass, segmentId: d.segmentId, requestId: d.requestId,
                         purpose: d.purpose, domains: d.domains, keyEpoch: d.keyEpoch, sha256: d.sha256, bytes: d.bytes, opCount: d.opCount,
                         format: d.format, signature: d.signature, deviceId: segmentDevices[d.segmentId] ?? device, createdAt: 1000,
                         getUrl: URL(string: "https://cloud.test/v1/transfers/segments/" + d.segmentId)!, expiresAt: CloudSyncBytes.now() + 60_000)
        }
        let next = entries.last?.seq ?? after
        return .init(segments: entries, headSeq: CloudSequence(head), nextAfter: next, hasMore: receipts.values.contains { $0.seq > next })
    }
    func prepareBlobs(_ items: [CloudBlobUpload]) async throws -> [CloudBlobTicket] {
        calls += 1
        return items.map { item in
            uploads[item.uploadId] = item
            let exists = refs[item.blobId] != nil
            return .init(uploadId: item.uploadId, blobId: item.blobId,
                         putUrl: exists ? nil : URL(string: "https://cloud.test/v1/transfers/staging/" + item.uploadId),
                         headers: ["content-type": "application/octet-stream", "content-md5": item.md5],
                         ticket: "fixture-only:" + item.uploadId, expiresAt: CloudSyncBytes.now() + 300_000, alreadyPresent: exists)
        }
    }
    func upload(_ bytes: Data, ticket: CloudBlobTicket) async throws {
        guard ticket.putUrl?.host == "cloud.test", uploads[ticket.uploadId] != nil else { throw CloudFailure.invalidRequest }
        staging[ticket.uploadId] = bytes
    }
    func finalizeBlobs(_ items: [CloudBlobFinalize]) async throws -> [CloudBlobResult] {
        calls += 1
        return try items.map { item in
            guard let upload = uploads[item.uploadId], upload.blobId == item.blobId else { throw CloudFailure.invalidRequest }
            let ref = CloudBlobRef(blobId: item.blobId, sha256: upload.sha256, md5: upload.md5, bytes: upload.bytes,
                                   storageClass: upload.storageClass, purpose: upload.purpose, keyEpoch: upload.keyEpoch)
            if refs[item.blobId] == nil {
                guard let bytes = staging[item.uploadId] else { throw CloudFailure.unavailable }
                try CloudSyncBytes.verify(bytes, ref: ref)
                objects[item.blobId] = bytes
                refs[item.blobId] = ref
            }
            return .init(uploadId: item.uploadId, blob: refs[item.blobId])
        }
    }
    func readBlobs(ids: [String]) async throws -> [CloudBlobDownload] {
        try ids.map { id in
            guard let ref = refs[id] else { throw CloudFailure.invalidRequest }
            return .init(blob: ref, getUrl: URL(string: "https://cloud.test/v1/transfers/objects/" + id)!, expiresAt: CloudSyncBytes.now() + 60_000)
        }
    }
    func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        guard url.host == "cloud.test" else { throw CloudFailure.unsafeConfiguration }
        let id = url.lastPathComponent
        let bytes: Data
        if url.path.hasPrefix("/v1/transfers/segments/"), let segment = segments[id] { bytes = try CloudSyncBytes.unbase64(segment.ciphertext) }
        else if let object = objects[id] { bytes = object }
        else { throw CloudFailure.invalidRequest }
        guard bytes.count <= maximumBytes else { throw CloudFailure.invalidRequest }
        return bytes
    }
    // No first upload in this version: the service never holds an inventory.
    func publishCheckpoint(_ request: CloudCheckpointRequest) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func checkpoint() async throws -> CloudCheckpoint? { nil }
    func verifyCheckpoint(id: String, inventoryDigest: String, counts: CloudCounts) async throws -> [String] { throw CloudFailure.unsupportedFormat }
    func applied(brainSeq: CloudSequence, secretsSeq: CloudSequence, checkpointId: String?) async throws -> CloudAppliedReceipt {
        guard brainSeq <= CloudSequence(head) else { throw CloudFailure.invalidRequest }
        return .init(brainSeq: brainSeq, secretsSeq: secretsSeq)
    }
    func takeLease(_ request: CloudLeaseRequest) async throws -> CloudLease { throw CloudFailure.unsupportedFormat }
    func releaseLease(resourceId: String, generation: CloudSequence) async throws { throw CloudFailure.unsupportedFormat }
    func events() async -> AsyncThrowingStream<CloudEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func stop() async {}
}
