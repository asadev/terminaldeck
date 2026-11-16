import XCTest
import Foundation
@testable import TerminalDeckNativeCore

// Lane V, round-7 review R7-2: refused saved-password items through the REAL
// sync engine (CloudSyncEngine from lane SYNC, its fixture server and store),
// not V's own fixture outbox. Fixture keys and records only.

/// The local key slot, swapped between epochs by the test.
private actor CloudSecretsEngineKey: CloudSecretsLocalKeyPort {
    var key: CloudSecretsLocalKey?
    func set(_ value: CloudSecretsLocalKey) { key = value }
    func read() -> CloudSecretsLocalKey? { key }
    func saveVerified(_ value: CloudSecretsLocalKey) { key = value }
    func archive(_ value: CloudSecretsLocalKey) {}
    func archived(epoch: Int) -> CloudSecretsLocalKey? { nil }
    func seenCloudEpoch() -> Int? { nil }
    func saveSeenCloudEpoch(_ epoch: Int) {}
}
/// Records what reached the owner: applied values and listed removals.
private actor CloudSecretsEngineStore: CloudSecretsLogicalStore, CloudSecretsRemovalListing {
    nonisolated let sourceId = "engine-secrets"
    nonisolated let inventoryRow = "I13"
    nonisolated let domain = CloudSecretsDomain.app
    var applied: [String] = []
    var removals: [String] = []
    func capture() -> [CloudSecretRecord] { [] }
    func validate(_ record: CloudSecretRecord) {}
    func merge(_ record: CloudSecretRecord) -> CloudApplyStatus {
        if applied.contains(record.recordId) { return .alreadyPresent }
        applied.append(record.recordId); return .applied
    }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) -> Bool { applied.contains(record.recordId) }
    func listRemoval(recordId: String) { if !removals.contains(recordId) { removals.append(recordId) } }
}

extension CloudSyncTests {
    func testSecretsOlderEpochItemAndRemovalAreClosedByTheRealEngineNotParked() async throws {
        let now: Int64 = 1_800_000_000_000
        let policy = CloudSecretsPolicy(capabilities: { .init(features: ["cloud"], storageEntitled: true, aiSubscriptionsEnabled: false, expiresAt: now + 300_000) },
                                        now: { now })
        let cloudSubject = CloudSubject(issuer: CloudWire.issuer, sub: subject)
        let recovery = try CloudRecoveryKeys(entropy: Data(repeating: 6, count: 32), sub: subject).publicKey
        let keys = CloudSecretsEngineKey()
        func key(_ epoch: Int, _ byte: UInt8) -> CloudSecretsLocalKey {
            .init(subject: cloudSubject, deviceId: device, epoch: epoch, version: CloudSequence(UInt64(epoch)),
                  root: Data(repeating: byte, count: 32), recoveryPublicKey: recovery)
        }
        let content = CloudSecretsContent(subject: cloudSubject, deviceId: device, local: keys, policy: policy)
        let store = CloudSecretsEngineStore()
        let adapter = CloudSecretsLogicalAdapter(store: store, content: content, policy: policy, deviceId: device,
            keepConflicts: { _ in throw CloudFailure.unavailable }, retainIncomingConflict: { _ in })
        func record(_ id: String, _ value: String = "") -> CloudSecretRecord {
            .init(sourceId: "engine-secrets", recordId: id, domain: "app", payload: .init(.object([.init("value", .string("fixture-" + id + value))])))
        }
        let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:])
        // An item sealed under the old key (epoch 1)...
        await keys.set(key(1, 3))
        let old = try await adapter.snapshot(records: [record("old")], cut: cut).operations[0]
        // ...then "Start new saved passwords": this Mac holds epoch 2.
        await keys.set(key(2, 5))
        let good = try await adapter.snapshot(records: [record("good")], cut: cut).operations[0]
        let gone = try await adapter.snapshot(records: [record("gone")], cut: cut).operations[0]
        let removalId = UUID().uuidString.lowercased()
        let removal = CloudOperation(v: 1, opId: removalId, originDevice: gone.originDevice, domain: gone.domain,
            entityId: gone.entityId, revision: removalId, parents: [], kind: .archive, source: gone.source,
            createdAt: gone.createdAt, payload: gone.payload, payloadHash: gone.payloadHash)
        // The same record "old" again, re-uploaded under the new key.
        let renewed = try await adapter.snapshot(records: [record("old", "-new")], cut: cut).operations[0]
        let server = try CloudSyncFixtureServer(root: scratch(), device: device)
        func commit(_ operations: [CloudOperation]) async throws {
            let id = UUID().uuidString.lowercased()
            let envelope = try await content.seal(CloudSyncPack.encode(operations), blobId: id, storageClass: .secrets,
                                                  purpose: .secret, epoch: 2, codec: .identity)
            let bytes = try CloudSyncCanonical.encode(envelope)
            _ = try await server.commit(.init(descriptor: .init(segmentId: id, requestId: UUID().uuidString.lowercased(), storageClass: .secrets,
                purpose: .secret, domains: ["app"], keyEpoch: 2, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count),
                opCount: operations.count, format: "td-ops-1", signature: CloudSyncBytes.base64(Data(repeating: 7, count: 64))),
                ciphertext: CloudSyncBytes.base64(bytes)))
        }
        try await commit([old, removal, good])
        try await commit([renewed])
        _ = try await server.commit(reviewBrainSegment([op(entity: "memory-after")]))
        let root = try scratch()
        let storeDB = try makeStore(root)
        let reader = try CloudSyncEngine(store: storeDB, transport: server, objects: server, content: makeContent(), budget: CloudSyncBudget(store: storeDB),
            subject: subject, deviceId: device, epoch: 1, brainDomains: ["memory"], secretsDomains: ["app"], secretsContent: content,
            signer: { _ in CloudSyncBytes.base64(Data(repeating: 7, count: 64)) }, verifySignature: { _, _ in })
        try await reader.register(adapter: adapter)
        try await reader.register(adapter: CloudSyncFixtureAdapter(root: root.appendingPathComponent("memory"), domain: "memory"))
        _ = try await reader.pull()
        // Restore moved past everything; memory after it applied.
        XCTAssertEqual(try storeDB.value("brainSeq"), CloudSequence(3))
        XCTAssertEqual(try storeDB.value("secretsSeq"), CloudSequence(3))
        // Nothing parked: the older-epoch item and the removal were closed, not held.
        XCTAssertTrue(try storeDB.rows("SELECT opId FROM parked_ops").isEmpty)
        // The good item applied, and the newer version of "old" was not held back.
        let applied = await store.applied
        XCTAssertEqual(applied, ["good", "old"])
        let removals = await store.removals
        XCTAssertEqual(removals, []) // L3: a removal that is not a typed, sealed removal is closed, never listed or applied
        let notes = await adapter.notices()
        XCTAssertEqual(notes[CloudSecretsLogicalAdapter.olderEpochWords], 1)
        XCTAssertEqual(notes[CloudSecretsLogicalAdapter.notAppliedWords], 1)
        print("CloudSecretsSyncEngineTests real-engine assertions=8")
    }
}
