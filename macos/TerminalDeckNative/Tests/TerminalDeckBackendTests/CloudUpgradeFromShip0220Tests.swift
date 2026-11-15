import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 13 Nov (final Mac candidate): the owner's two Macs run the older build (lane/ship-0220 9ef04aa6). They are signed
/// in, "Use Cloud here" is yes, every device (five stale entries of their own earlier sign-ins included) is trusted by
/// press, and each holds a half-finished first saved copy: `bootstrapInProgress` set, `blocked` true, one memory part
/// saved with a version-5 operation id, and captured changes waiting in the journal (read-only findings,
/// notes/cloud-test-20261112/live-check/RESULT.md). The older state is made here the way the older build made it: its
/// first page carried version-5 ids and the sync core refused it before any request. This build is then started on
/// exactly that disk state and must finish and send the first copy by itself, send what was captured, end level with
/// the service, read the older trusted list and stop trusting (and never show) the five stale entries.
@Suite("Cloud — this build over the owner's older signed-in state", .serialized)
struct CloudUpgradeFromShip0220Tests {
    static let subject = CloudSubject(issuer: "https://identity.test", sub: "11111111-1111-4111-8111-111111111111")
    static let subjectHash = String(repeating: "f", count: 64)
    static let rootKey = Data(0..<32)
    /// `BackendCloudBrainMemoryActivation`'s saved cut, as the older build wrote it (`memory-cut.json`).
    struct SavedCut: Codable { let cut: CloudSnapshotCut; var done: Bool }

    static func jwk(_ key: P256.Signing.PrivateKey) -> CloudPublicJWK {
        let point = key.publicKey.x963Representation
        return CloudPublicJWK(kty: "EC", crv: "P-256", x: BackendCloudAccountIdentity.base64(Data(point[1..<33])),
                              y: BackendCloudAccountIdentity.base64(Data(point[33..<65])))
    }
    static func content() throws -> CloudSyncContent { let key = rootKey; return try .init(subject: subject.sub, epoch: 1, keyProvider: { _ in key }) }
    static var domains: Set<String> { Set(CloudBrainMemoryFormat.inventoryRows.map(CloudBrainMemoryFormat.domain)) }
    static func engine(_ store: CloudSyncStore, service: CloudUpgradeFixtureService, deviceId: String, key: P256.Signing.PrivateKey,
                       trust: BackendCloudTrustStore, domains: Set<String> = domains) throws -> CloudSyncEngine {
        try CloudSyncEngine(store: store, transport: service, objects: service, content: content(), budget: CloudSyncBudget(store: store),
                            subject: subject.sub, deviceId: deviceId, epoch: 1, brainDomains: domains,
                            signer: { payload in BackendCloudAccountIdentity.base64(try key.signature(for: payload).rawRepresentation) },
                            trust: trust)
    }

    @Test func theOlderHalfFinishedFirstCopyIsFinishedSentAndLevel() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        defer { try? FileManager.default.removeItem(at: f.base) }
        let rows = CloudBrainMemoryFormat.inventoryRows
        let syncRoot = f.base.appendingPathComponent("Data/cloud/" + Self.subjectHash, isDirectory: true)
        let service = CloudUpgradeFixtureService(device: f.deviceId)
        let mine = P256.Signing.PrivateKey()
        let slot = CloudTrustFixtureSlot()
        let olderList = BackendCloudTrustedList(subject: Self.subject, revision: 1, devices: [
            .init(deviceId: f.deviceId, signKey: Self.jwk(mine), keyId: BackendCloudDeviceCode.keyId(Self.jwk(mine))!, name: "imatch-mac-mini.local",
                  trust: "trusted", how: "self", trustedAt: 1_000)])
        slot.put(try CloudWire.canonical(olderList))
        let cutId = UUID().uuidString.lowercased()
        let cut = CloudSnapshotCut(snapshotId: cutId, at: 1_000_125, watermarks: [:])

        // 1. The older build's run: capture on, adapters registered, the cut saved, its first page refused locally.
        do {
            let store = try CloudSyncStore(root: syncRoot, subject: Self.subject)
            let trust = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
            let engine = try Self.engine(store, service: service, deviceId: f.deviceId, key: mine, trust: trust)
            try await f.store.cloudResumeCapture(stateRoot: f.stateRoot, rows: rows)
            let adapters = try rows.map { try f.adapter($0) }
            for adapter in adapters { try await engine.register(adapter: adapter) }
            try FileManager.default.createDirectory(at: f.stateRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(SavedCut(cut: cut, done: false)).write(to: f.stateRoot.appendingPathComponent("memory-cut.json"))
            try await f.store.cloudKeepOnlySnapshot(id: BackendCloudBrainMemoryHash.uuid(cutId))
            await #expect(throws: CloudFailure.invalidRequest) {
                _ = try await engine.bootstrap(sources: adapters.map { OlderBuildMemory($0) }, cut: cut)
            }
            // What the older build kept: its parts carry version-5 ids.
            #expect(try await f.store.cloudFixtureAgePartsToVersionFive() >= 1)
            // Work goes on after the stop: captured changes wait in the journal, nothing drains them.
            for n in 1...30 {
                try f.write("hoot/notes/upgrade-\(n).md", "---\nid: n-upgrade-\(n)\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Upgrade \(n)\nWritten while the first copy was stuck.\n")
            }
            _ = try await f.store.reindex()
            #expect(try await f.store.cloudFixtureJournalCount() > 0)
            await f.store.close()
        }
        // Exactly the owner's state on disk: no request ever reached the service.
        #expect(await service.calls == 0)
        let olderStore = try CloudSyncStore(root: syncRoot, subject: Self.subject)
        #expect((try olderStore.value("bootstrapInProgress") as String?) == cutId)
        #expect((try olderStore.value("blocked") as Bool?) == true)
        #expect(try olderStore.pending().isEmpty)

        // 2. This build starts on that state. Nothing is asked of the person.
        let memory = try DeckMemoryStore(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date() })
        let trust = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        let engine = try Self.engine(olderStore, service: service, deviceId: f.deviceId, key: mine, trust: trust)
        let activation = try BackendCloudBrainMemoryActivation(store: memory, deviceId: f.deviceId, subjectHash: Self.subjectHash,
                                                               stateRoot: f.stateRoot, rows: rows, now: { 2_000_000 }, retryDelays: [0.05, 0.05])
        try await activation.start(outbox: engine)
        // The same cut was finished (its version-5 parts made again) and the setup flag is gone.
        #expect((try olderStore.value("bootstrapInProgress") as String?) == nil)
        #expect(try await memory.cloudFixtureAgePartsCount() == 0)
        let saved = try JSONDecoder().decode(SavedCut.self, from: Data(contentsOf: f.stateRoot.appendingPathComponent("memory-cut.json")))
        #expect(saved.cut.snapshotId == cutId)
        #expect(saved.done)

        // 3. The first copy and every captured change go up; the journal is drained.
        let readers = try rows.map { try BackendCloudBrainMemory(store: memory, deviceId: f.deviceId, inventoryRow: $0, snapshotRoot: f.snapshotRoot) }
        func journalDrained() async throws -> Bool {
            for reader in readers {
                if try await reader.localChange(after: try await reader.savedLocalCursor(scope: Self.subjectHash)) != nil { return false }
            }
            return true
        }
        var level = false
        for _ in 0..<400 {
            _ = try? await engine.flush()
            if try await journalDrained(), try await engine.restoreProgress().queued == 0 { level = true; break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(level)
        _ = try await engine.pull()
        let progress = try await engine.restoreProgress()
        let head = await service.head
        #expect(head > 0)
        #expect(progress.queued == 0)
        #expect(progress.brainSeq == CloudSequence(head))
        #expect((try olderStore.value("blocked") as Bool?) == false)
        // The 30 notes written while stuck went up with the first copy.
        #expect(await service.operationCount() >= 30)
        await activation.stop()
        await memory.close()
    }

    /// The trusted list and the trust choice as the older build left them: read as they are, automatic trust by
    /// default, and the five stale entries of earlier sign-ins neither trusted nor shown, in either trust mode.
    @Test func theOlderTrustedListIsReadAndItsStaleEntriesStopAndVanish() async throws {
        let base = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("upgrade-trust-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // No trust choice was ever stored by the older build: no Keychain item, no `cloud/trust-mode` file.
        let mode = BackendCloudTrustModeStore(slot: CloudTrustFixtureSlot().port(), legacyFile: base.appendingPathComponent("cloud/trust-mode"))
        #expect(mode.load() == .account)

        let mini = "34b73ef2-dd15-45cb-8d95-000000000001", book = "eb6b96ac-6dd4-42be-8ca3-000000000002"
        let staleMini = ["c6d7e6ef-b4af-482f-843d-000000000003", "b2082a41-088e-443e-853d-000000000004"]
        let staleBook = ["e2759765-6e24-45fc-8b0c-000000000005", "f2f93419-217c-4f80-83c8-000000000006", "2d54fa85-1395-4d04-8a15-000000000007"]
        var keys: [String: CloudPublicJWK] = [:]
        for id in [mini, book] + staleMini + staleBook { keys[id] = Self.jwk(P256.Signing.PrivateKey()) }
        func device(_ id: String, _ name: String, added: Int64, seen: Int64) -> CloudDevice {
            .init(deviceId: id, label: name, platform: .macos, appVersion: "0.22.0", status: .active, secretsApproved: false,
                  lastSeenAt: seen, signPublicJwk: keys[id]!, wrapPublicJwk: keys[id]!, registeredAt: added)
        }
        // Tonight's sign-in attempts, one after the other; each earlier entry was last seen before the next was added.
        let devices = [device(staleBook[0], "asads-macbook-pro-21.local", added: 100, seen: 150),
                       device(staleMini[0], "imatch-mac-mini.local", added: 200, seen: 250),
                       device(staleBook[1], "asads-macbook-pro-21.local", added: 300, seen: 350),
                       device(staleMini[1], "imatch-mac-mini.local", added: 400, seen: 450),
                       device(staleBook[2], "asads-macbook-pro-21.local", added: 500, seen: 550),
                       device(mini, "imatch-mac-mini.local", added: 600, seen: 9_000),
                       device(book, "asads-macbook-pro-21.local", added: 700, seen: 9_000)]
        // The older build's list on the mini: its own identities by itself, every other entry by a press.
        let entries: [BackendCloudTrustedList.Entry] = ([mini] + staleMini).map {
            .init(deviceId: $0, signKey: keys[$0]!, keyId: BackendCloudDeviceCode.keyId(keys[$0]!)!, name: "imatch-mac-mini.local", trust: "trusted", how: "self", trustedAt: 1)
        } + ([book] + staleBook).map {
            .init(deviceId: $0, signKey: keys[$0]!, keyId: BackendCloudDeviceCode.keyId(keys[$0]!)!, name: "asads-macbook-pro-21.local", trust: "trusted", how: "click", trustedAt: 2)
        }
        let slot = CloudTrustFixtureSlot()
        slot.put(try CloudWire.canonical(BackendCloudTrustedList(subject: Self.subject, revision: 9, devices: entries)))
        let trust = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        #expect(try await trust.list().devices.count == 7)

        let stale = BackendCloudTrustRows.stale(devices: devices, thisDeviceId: mini)
        #expect(stale == Set(staleMini + staleBook))
        var active: [String: String] = [:]
        for d in devices { active[d.deviceId] = BackendCloudDeviceCode.keyId(d.signPublicJwk) }
        let settled = try await trust.settleStale(stale, activeKeys: active, thisDeviceId: mini)
        #expect(Set(settled.stopped) == stale)
        for id in stale { #expect(await trust.trustedSigningKey(deviceId: id) == nil) }
        #expect(await trust.trustedSigningKey(deviceId: mini) == keys[mini])
        #expect(await trust.trustedSigningKey(deviceId: book) == keys[book])
        // Asked again: nothing changes, nothing comes back.
        let again = try await trust.settleStale(stale, activeKeys: active, thisDeviceId: mini)
        #expect(again.stopped.isEmpty && again.restored.isEmpty)

        for automatic in [true, false] {
            let built = BackendCloudTrustRows.build(devices: devices, list: try await trust.list(), thisDeviceId: mini, thisKey: keys[mini],
                                                    markKeyChanges: automatic)
            #expect(Set(built.filter(\.stale).map(\.deviceId)) == stale)
            #expect(built.first { $0.deviceId == book }?.standing == .trusted)
            // Automatic trust never adds them back.
            if automatic { #expect(try await trust.trustByAccount(built).isEmpty) }
            var input = BackendCloudOverviewInput(snapshot: CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true),
                                                                                 displayName: "Owner", devices: devices, trust: built,
                                                                                 cloudHead: CloudSequence(3), fetched: CloudSequence(3)),
                                                  memory: .init(included: true))
            input.automaticTrust = automatic
            let page = try #require(BackendCloudOverviewBuilder.build(input))
            #expect(!page.waiting.contains { $0.id.hasPrefix("device:") || $0.id.hasPrefix("key:") || $0.id == "held-unlisted" })
            #expect(!page.waiting.contains { $0.text.contains("cannot be trusted right now") })
        }
    }

    @Test func aStaleEntryThatComesBackIsTrustedAgainWithItsStoredKeyOnly() async throws {
        let a = "10000000-0000-4000-8000-00000000000a", b = "10000000-0000-4000-8000-00000000000b"
        let keyA = Self.jwk(P256.Signing.PrivateKey()), keyB = Self.jwk(P256.Signing.PrivateKey())
        let slot = CloudTrustFixtureSlot()
        slot.put(try CloudWire.canonical(BackendCloudTrustedList(subject: Self.subject, revision: 1, devices: [
            .init(deviceId: a, signKey: keyA, keyId: BackendCloudDeviceCode.keyId(keyA)!, name: "Air", trust: "trusted", how: "click", trustedAt: 1)])))
        let trust = BackendCloudTrustStore(subject: Self.subject, slot: slot.port(), pressRefused: { false })
        #expect(try await trust.settleStale([a], activeKeys: [a: BackendCloudDeviceCode.keyId(keyA)!], thisDeviceId: b).stopped == [a])
        // Reported with another key: not trusted again.
        #expect(try await trust.settleStale([], activeKeys: [a: BackendCloudDeviceCode.keyId(keyB)!], thisDeviceId: b).restored.isEmpty)
        // MAC-NEXT-11: the same key, active and no longer stale, but it signed nothing new: it stays settled.
        #expect(try await trust.settleStale([], activeKeys: [a: BackendCloudDeviceCode.keyId(keyA)!], thisDeviceId: b).restored.isEmpty)
        // It signed a new pack after the settling: under automatic trust its stored key is trusted again.
        let signed = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        #expect(try await trust.settleStale([], activeKeys: [a: BackendCloudDeviceCode.keyId(keyA)!], thisDeviceId: b, alive: [a: signed]).restored == [a])
        #expect(await trust.trustedSigningKey(deviceId: a) == keyA)
    }
}

/// The older build's memory adapter for its first page: the operations it handed the sync core carried version-5 ids
/// (BackendCloudBrainMemoryHash.uuid), which the core refuses before sending anything.
private final class OlderBuildMemory: CloudDomainAdapter, @unchecked Sendable {
    let inner: BackendCloudBrainMemory
    var inventoryRows: [String] { inner.inventoryRows }
    init(_ inner: BackendCloudBrainMemory) { self.inner = inner }
    static func versionFive(_ id: String) -> String { var chars = Array(id); chars[14] = "5"; return String(chars) }
    static func aged(_ op: CloudOperation) -> CloudOperation {
        .init(v: op.v, opId: versionFive(op.opId), originDevice: op.originDevice, domain: op.domain, entityId: op.entityId,
              revision: versionFive(op.revision), parents: op.parents.map(versionFive), kind: op.kind, projectId: op.projectId, rootId: op.rootId,
              source: op.source, createdAt: op.createdAt, payload: op.payload, payloadHash: op.payloadHash)
    }
    func sourceInventory() async throws -> [CloudSourceInventory] { try await inner.sourceInventory() }
    func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot { try await inner.snapshot(cut: cut) }
    func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
        let pages = await inner.snapshotPages(cut: cut)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await page in pages {
                        continuation.yield(CloudDomainSnapshot(cut: page.cut, operations: page.operations.map(Self.aged), files: page.files,
                                                               coverage: page.coverage, associations: page.associations))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> { await inner.changes(after: after) }
    func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
        try await inner.validateIncoming(operations, files: files)
    }
    func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
        try await inner.applyPrepared(prepared, origin: origin)
    }
    func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification { try await inner.verify(receipt) }
}
