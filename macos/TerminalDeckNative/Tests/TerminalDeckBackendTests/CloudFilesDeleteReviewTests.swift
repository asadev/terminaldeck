import Foundation
import CryptoKit
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Review 15 Nov (files lane L2): every finding of the independent review, tested. The `…ThroughTheCore` tests send
/// through the REAL sync core (signing, the feed, parking, pack and one-by-one apply) and the real pump; the others
/// call the owner directly. Scratch folders only.

/// A gate whose answer the test sets: open for the first `openReads` reads, then whatever `open` says.
final class FilesGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var forced: Bool
    init(openReads: Int, then: Bool) { remaining = openReads; forced = then }
    func read() -> Bool { lock.withLock { if remaining > 0 { remaining -= 1; return true }; return forced } }
    func set(_ open: Bool) { lock.withLock { remaining = 0; forced = open } }
}

/// Holds what a sender's outbox wrapper set aside.
final class FilesOperationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [CloudOperation] = []
    func add(_ operation: CloudOperation) { lock.withLock { held.append(operation) } }
    var all: [CloudOperation] { lock.withLock { held } }
}

/// The sender's outbox, with the about-records changed (or set aside) on their way into the real sync core.
struct FilesTamperOutbox: CloudOutboxPort {
    let base: any CloudOutboxPort
    let change: @Sendable (CloudOperation) throws -> CloudOperation?
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        let sent = try operations.compactMap(change)
        let receipt = sent.isEmpty ? CloudLocalReceipt(operationIds: [], queued: 0, bytes: 0, savedAt: 0) : try await base.enqueue(sent, files: files)
        return .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: receipt.bytes, savedAt: receipt.savedAt)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { try await base.coverage(sourceId: sourceId) }
    func flush() async throws -> [CloudReceipt] { try await base.flush() }
    func restoreProgress() async throws -> CloudRestoreProgress { try await base.restoreProgress() }
    func contextReady(projectId: String) async throws -> CloudContextReady { try await base.contextReady(projectId: projectId) }
    func register(adapter: any CloudDomainAdapter) async throws { try await base.register(adapter: adapter) }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { try await base.bootstrap(snapshots) }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { try await base.bootstrap(sources: sources, cut: cut) }
    func pull() async throws -> [CloudImportReceipt] { try await base.pull() }
    func setPaused(_ paused: Bool) async throws { try await base.setPaused(paused) }
    func serviceTime() -> Int64? { base.serviceTime() }
}

extension CloudFileDeleteRecords {
    /// The same about-record with other fields, sealed again (a newer-format or damaged sender).
    static func resealedForTest(_ operation: CloudOperation, fields: [String: String]) throws -> CloudOperation {
        let about = try read(operation)
        let changed = About(operation: about.operation, place: about.place, mac: about.mac, at: about.at, fields: fields)
        let payload = CloudValue(try NativeRPCValue.parseJSON(JSONEncoder().encode(changed)))
        return CloudOperation(v: operation.v, opId: operation.opId, originDevice: operation.originDevice, domain: operation.domain,
            entityId: operation.entityId, revision: operation.revision, parents: operation.parents, kind: operation.kind,
            projectId: operation.projectId, rootId: operation.rootId, source: operation.source, createdAt: operation.createdAt,
            payload: payload, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(payload)))
    }
}

/// Three Macs (A, B, C), each with its own real sync core over one fake service.
struct FolderCoreRig {
    typealias U = CloudUpgradeFromShip0220Tests
    let f: CloudFolderFixture
    let service: CloudUpgradeFixtureService
    let deviceC: String
    let keys: [String: P256.Signing.PrivateKey]
    init(_ f: CloudFolderFixture) {
        self.f = f
        service = CloudUpgradeFixtureService(device: f.deviceA)
        let c = UUID().uuidString.lowercased()
        deviceC = c
        var made: [String: P256.Signing.PrivateKey] = [:]
        for id in [f.deviceA, f.deviceB, c] { made[id] = P256.Signing.PrivateKey() }
        keys = made
    }
    func engine(_ name: String, device: String) throws -> CloudSyncEngine {
        let slot = CloudTrustFixtureSlot()
        let entries = [f.deviceA, f.deviceB, deviceC].map { id -> BackendCloudTrustedList.Entry in
            let jwk = U.jwk(keys[id]!)
            return .init(deviceId: id, signKey: jwk, keyId: BackendCloudDeviceCode.keyId(jwk)!, name: id == f.deviceA ? "A" : (id == f.deviceB ? "B" : "C"),
                         trust: "trusted", how: id == device ? "self" : "click", trustedAt: 1)
        }
        slot.put(try CloudWire.canonical(BackendCloudTrustedList(subject: U.subject, revision: 1, devices: entries)))
        let store = try CloudSyncStore(root: f.base.appendingPathComponent(name + "/cloud/sync"), subject: U.subject)
        return try U.engine(store, service: service, deviceId: device, key: keys[device]!,
                            trust: BackendCloudTrustStore(subject: U.subject, slot: slot.port(), pressRefused: { false }),
                            domains: [CloudFolderFormat.domain])
    }
    /// Everything the owner journaled has been handed to its outbox by its pump.
    func pumped(_ owner: BackendCloudFolder) async throws -> Bool {
        let core = try await owner.core()
        return try await core.localChange(after: try await core.savedLocalCursor(scope: U.subjectHash)) == nil
    }
    /// Waits for the pump, then sends what `engine` holds, as `device`.
    func send(_ owner: BackendCloudFolder, _ engine: CloudSyncEngine, as device: String) async throws {
        for _ in 0..<200 {
            if try await pumped(owner) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await flush(engine, as: device)
    }
    func flush(_ engine: CloudSyncEngine, as device: String) async throws {
        await service.switchDevice(device)
        for _ in 0..<200 {
            _ = try? await engine.flush()
            if try await engine.restoreProgress().queued == 0 { return }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func receive(_ engine: CloudSyncEngine, as device: String) async throws {
        await service.switchDevice(device)
        _ = try await engine.pull()
    }
}

struct CloudFilesDeleteReviewTests {
    typealias U = CloudUpgradeFromShip0220Tests
    func item(_ path: String) -> CloudDeleteItem { .init(id: path, kind: BackendCloudFolder.kind, name: (path as NSString).lastPathComponent, place: path) }
    func actor(_ f: CloudFolderFixture) -> CloudDeleteActor {
        .init(by: .person, mac: f.deviceA, macName: "Mac mini", at: f.clock.ms, group: UUID().uuidString.lowercased())
    }

    // MARK: 3 and 4 — through the real sync core

    /// A removal whose about-record this Mac refuses (newer format, or damaged) is applied the safe way, and the feed goes on.
    func anAboutRecordThisMacCannotTakeKeepsTheFile(_ change: @escaping @Sendable ([String: String]) -> [String: String]) async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let rig = FolderCoreRig(f)
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, announced: true)
        await a.setDeleteRuleGate { true }; await b.setDeleteRuleGate { true }
        let engineA = try rig.engine("a", device: f.deviceA), engineB = try rig.engine("b", device: f.deviceB)
        let tamper = FilesTamperOutbox(base: engineA) { operation in
            guard CloudFileDeleteRecords.isAbout(operation) else { return operation }
            return try CloudFileDeleteRecords.resealedForTest(operation, fields: change(try CloudFileDeleteRecords.read(operation).fields))
        }
        try await a.start(outbox: tamper, subjectHash: U.subjectHash, watch: false)
        try await b.start(outbox: engineB, subjectHash: U.subjectHash, watch: false)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        #expect(f.text("b", "note.md") == "one")
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        #expect(f.text("a", "note.md") == nil)
        // Never Everywhere without proof: B keeps the file, marked Only on this Mac.
        #expect(f.text("b", "note.md") == "one")
        #expect(try await b.notHere().first { $0.item.id == "note.md" }?.mark == .onlyOnThisMac)
        // The pack went on and so does the feed: a later file still arrives.
        f.clock.advance(60_000); try f.write("a", "later.md", "later"); try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        #expect(f.text("b", "later.md") == "later")
        await a.stop(); await b.stop()
    }
    @Test func aNewerFormatAboutRecordIsRefusedThroughTheCoreAndItsFileIsKept() async throws {
        try await anAboutRecordThisMacCannotTakeKeepsTheFile { fields in var f = fields; f[CloudDeleteTravel.rule] = "2"; return f }
    }
    @Test func aDamagedAboutRecordIsSetAsideThroughTheCoreAndItsFileIsKept() async throws {
        try await anAboutRecordThisMacCannotTakeKeepsTheFile { fields in var f = fields; f[CloudDeleteTravel.group] = "not-a-group"; return f }
    }

    /// Several rows pressed "Cloud", one about-record refused on the way: no file is removed on any device.
    @Test func severalRowsPressedCloudWithOneAboutRefusedRemoveNoFileAnywhereThroughTheCore() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let rig = FolderCoreRig(f)
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, announced: true)
        await a.setDeleteRuleGate { true }; await b.setDeleteRuleGate { true }
        let engineA = try rig.engine("a", device: f.deviceA), engineB = try rig.engine("b", device: f.deviceB)
        let tamper = FilesTamperOutbox(base: engineA) { operation in
            guard CloudFileDeleteRecords.isAbout(operation), try CloudFileDeleteRecords.read(operation).place == "two.md" else { return operation }
            var fields = try CloudFileDeleteRecords.read(operation).fields
            fields[CloudDeleteTravel.rule] = "2"
            return try CloudFileDeleteRecords.resealedForTest(operation, fields: fields)
        }
        try await a.start(outbox: tamper, subjectHash: U.subjectHash, watch: false)
        try await b.start(outbox: engineB, subjectHash: U.subjectHash, watch: false)
        for name in ["one.md", "two.md", "three.md"] { try f.write("a", name, name) }
        try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        _ = try await a.deleteItems(["one.md", "two.md", "three.md"].map(item), scope: .cloud, by: actor(f))
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        for name in ["one.md", "two.md", "three.md"] {
            #expect(f.text("a", name) == name)
            #expect(f.text("b", name) == name)
        }
        #expect(try await b.notHere().filter { $0.mark == .onlyOnThisMac }.count == 3)
        await a.stop(); await b.stop()
    }

    // MARK: 5 — the verified signer

    /// C forges an about-record for A's removal (claiming A). The verified signer is C: it is refused, and A's removal,
    /// whose own about-record never arrived, is applied the safe way.
    @Test func aForgedAboutRecordFromAnotherSignerNeverMakesEverywhereThroughTheCore() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let rig = FolderCoreRig(f)
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, announced: true)
        let c = try await f.mac("c", device: rig.deviceC)
        await a.setDeleteRuleGate { true }; await b.setDeleteRuleGate { true }
        let engineA = try rig.engine("a", device: f.deviceA), engineB = try rig.engine("b", device: f.deviceB)
        let engineC = try rig.engine("c", device: rig.deviceC)
        let held = FilesOperationBox()
        // A's own about-records are set aside (never sent), so only the forged one can speak for A's removal.
        let drop = FilesTamperOutbox(base: engineA) { operation in
            guard CloudFileDeleteRecords.isAbout(operation) else { return operation }
            held.add(operation); return nil
        }
        try await a.start(outbox: drop, subjectHash: U.subjectHash, watch: false)
        try await b.start(outbox: engineB, subjectHash: U.subjectHash, watch: false)
        try await c.start(outbox: engineC, subjectHash: U.subjectHash, watch: false)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        for _ in 0..<200 { if try await rig.pumped(a) { break }; try await Task.sleep(for: .milliseconds(25)) }
        let forged = try #require(held.all.first)
        // The forged pack goes first in the feed, so the removal would find it already saved.
        _ = try await engineC.enqueue([forged], files: [])
        try await rig.flush(engineC, as: rig.deviceC)
        try await rig.flush(engineA, as: f.deviceA)
        try await rig.receive(engineB, as: f.deviceB)
        #expect(f.text("a", "note.md") == nil)
        #expect(f.text("b", "note.md") == "one")
        #expect(try await b.notHere().first { $0.item.id == "note.md" }?.mark == .onlyOnThisMac)
        await a.stop(); await b.stop(); await c.stop()
    }
    @Test func aForgedAboutRecordIsRefusedByItsVerifiedSigner() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, announced: true)
        await a.setDeleteRuleGate { true }
        try f.write("a", "note.md", "one"); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        let engine = try await a.core()
        var raw: [CloudOperation] = []
        while let change = try await engine.localChange(after: cursor) { raw.append(change.operation); cursor = change.cursor }
        let expanded = try await a.travelOperations(raw)
        let about = try #require(expanded.first(where: CloudFileDeleteRecords.isAbout))
        let removal = try #require(expanded.first { $0.kind == .archive })
        let other = UUID().uuidString.lowercased()
        let prepared = try await b.validateIncomingForTest([about])
        await #expect(throws: CloudRecordRefusal.self) { _ = try await b.applyPrepared(prepared, origin: .init(deviceId: other, sequence: .init(5))) }
        let alone = try await b.validateIncomingForTest([removal])
        _ = try await b.applyPrepared(alone, origin: .init(deviceId: f.deviceA, sequence: .init(6)))
        #expect(f.text("b", "note.md") == "one")
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
    }
    @Test func aDamagedAboutRecordIsARefusalOfThatOneRecordOnly() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, announced: true)
        await a.setDeleteRuleGate { true }
        try f.write("a", "note.md", "one"); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        let engine = try await a.core()
        var raw: [CloudOperation] = []
        while let change = try await engine.localChange(after: cursor) { raw.append(change.operation); cursor = change.cursor }
        let expanded = try await a.travelOperations(raw)
        let about = try #require(expanded.first(where: CloudFileDeleteRecords.isAbout))
        var fields = try CloudFileDeleteRecords.read(about).fields
        fields[CloudDeleteTravel.rule] = "2"
        let newer = try CloudFileDeleteRecords.resealedForTest(about, fields: fields)
        let removal = try #require(expanded.first { $0.kind == .archive })
        do { _ = try await b.validateIncomingForTest([newer, removal]); Issue.record("a newer about-record was taken") }
        catch let refusal as CloudRecordRefusal { #expect(refusal.operationIds == [newer.opId]) }
        _ = try await b.applyPrepared(try await b.validateIncomingForTest([removal]), origin: .init(deviceId: f.deviceA, sequence: .init(7)))
        #expect(f.text("b", "note.md") == "one")
    }
    @Test func aRemovalWithoutItsAboutRecordFromAnAnnouncedMacKeepsTheFile() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        // A's gate is closed (an older third Mac exists), so A sends the old form; B knows A announced the rule.
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, announced: true)
        try f.write("a", "note.md", "one"); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        let sent = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(!sent.contains(where: CloudFileDeleteRecords.isAbout))
        #expect(f.text("a", "note.md") == nil)
        #expect(f.text("b", "note.md") == "one")
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
    }

    // MARK: 6 — the gate again at send time

    /// Decision 6 as changed: the gate closes between the press and the send. "Everywhere" goes at once in the old
    /// compatible form (no about-record) and a later file of the same kind is sent right after it: nothing waits.
    @Test func aClosedGateAtSendTimeSendsEverywhereInTheOldFormAtOnceThroughTheCore() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let rig = FolderCoreRig(f)
        // Open for the press's one read, closed when the pump comes to send.
        let gate = FilesGateBox(openReads: 1, then: false)
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, announced: true)
        await b.setDeleteRuleGate { true }
        let engineA = try rig.engine("a", device: f.deviceA), engineB = try rig.engine("b", device: f.deviceB)
        try await a.start(outbox: engineA, subjectHash: U.subjectHash, watch: false)
        try await b.start(outbox: engineB, subjectHash: U.subjectHash, watch: false)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        await a.setDeleteRuleGate { gate.read() }
        let before = await rig.service.operationCount()
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        f.clock.advance(60_000); try f.write("a", "later.md", "later"); try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA)
        #expect(try await rig.pumped(a))
        // The removal and the later file, and no about-record.
        #expect(await rig.service.operationCount() == before + 2)
        try await rig.receive(engineB, as: f.deviceB)
        #expect(f.text("a", "note.md") == nil)
        #expect(f.text("b", "later.md") == "later")
        // B knows A announced the rule: an old-form removal from it is applied the safe way.
        #expect(f.text("b", "note.md") == "one")
        await a.stop(); await b.stop()
    }
    /// Decision 6 as changed: "Cloud" with the gate closed at send time is withdrawn, never held: nothing is removed from
    /// the Cloud, the file syncs normally again, the row says the one line, and a later file is not held behind it.
    @Test func aClosedGateAtSendTimeWithdrawsACloudRemovalAndTheFileSyncsAgainThroughTheCore() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let rig = FolderCoreRig(f)
        let gate = FilesGateBox(openReads: 3, then: false)
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, announced: true)
        await b.setDeleteRuleGate { true }
        let engineA = try rig.engine("a", device: f.deviceA), engineB = try rig.engine("b", device: f.deviceB)
        try await a.start(outbox: engineA, subjectHash: U.subjectHash, watch: false)
        try await b.start(outbox: engineB, subjectHash: U.subjectHash, watch: false)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        await a.setDeleteRuleGate { gate.read() }
        _ = try await a.deleteItems([item("note.md")], scope: .cloud, by: actor(f))
        for _ in 0..<200 { if try await rig.pumped(a) { break }; try await Task.sleep(for: .milliseconds(25)) }
        #expect(try await rig.pumped(a))
        f.clock.advance(60_000); try f.write("a", "later.md", "later"); try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        #expect(try await rig.pumped(a))
        #expect(f.text("b", "later.md") == "later")
        #expect(f.text("a", "note.md") == "one" && f.text("b", "note.md") == "one")
        #expect(try await a.notHere().isEmpty)
        #expect(try await b.notHere().isEmpty)
        #expect(try await a.bin().isEmpty)
        #expect(try await a.rowErrors()["note.md"] == CloudDeleteWords.cloudNeedsUpdatedMacs)
        // In sync again: an edit on A arrives on B.
        f.clock.advance(60_000); try f.write("a", "note.md", "two"); try await f.settle(a)
        try await rig.send(a, engineA, as: f.deviceA); try await rig.receive(engineB, as: f.deviceB)
        #expect(f.text("b", "note.md") == "two")
        await a.stop(); await b.stop()
    }
    @Test func aDeleteOfSeveralItemsNamesWhatWasNotRemoved() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        let group = try await a.deleteItems([item("note.md"), item("never-here.md")], scope: .everywhere, by: actor(f))
        #expect(group.items.map(\.id) == ["note.md"])
        #expect(try await a.rowErrors() == ["never-here.md": CloudFileDeleteRecords.notRemovedLine])
    }

    // MARK: 1 — intents

    @Test func aFailedPressThenAnEditThenALookDeletesNothing() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        try await a.blockMigrationSafety()
        await #expect(throws: (any Error).self) { _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f)) }
        #expect(f.text("a", "note.md") == "one")
        #expect(try await a.pendingDeleteIntent("note.md") == nil)
        try await a.unblockSafetyForTest()
        f.clock.advance(60_000); try f.write("a", "note.md", "two, edited after the error"); try await f.settle(a)
        f.clock.advance(60_000); try await f.settle(a)
        #expect(f.text("a", "note.md") == "two, edited after the error")
        #expect(try await CloudFolderFixture.journal(a).filter { $0.kind == .archive }.isEmpty)
        #expect(try await a.bin().isEmpty)
    }
    @Test func aLeftoverIntentNeverTurnsALaterByHandDeleteIntoATravellingOne() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        try await a.seedIntentForTest(.init(place: "note.md", scope: .everywhere, by: .ai, mac: f.deviceA, session: "Night", at: f.clock.ms,
                                           group: UUID().uuidString.lowercased()), binned: nil)
        try f.remove("a", "note.md"); try await f.settle(a); f.clock.advance(4_000); try await a.look()
        #expect(try await CloudFolderFixture.journal(a).filter { $0.kind == .archive }.isEmpty)
        #expect(try await a.notHere().map(\.item.id) == ["note.md"])
    }
    /// A crash right after the Bin step: the restart resumes it (once). The same crash, then an edit: dropped, kept.
    @Test func aCrashPastTheBinStepIsResumedOnceAndAnEditMadeSinceIsKept() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s"); try f.write("a", "gone.md", "gone"); try f.write("a", "edited.md", "v1"); try await f.settle(a)
        for path in ["gone.md", "edited.md"] { try await a.simulateCrashAfterBinForTest(path, intent: actor(f).intent(place: path, scope: .everywhere)) }
        try f.write("a", "edited.md", "v2 made after the crash")
        let reopened = try await f.mac("a", device: f.deviceA)
        try await f.settle(reopened); try await f.settle(reopened)
        let archives = try await CloudFolderFixture.journal(reopened).filter { $0.kind == .archive }
        #expect(archives.count == 1)
        #expect(archives.first?.source.recordId.hasSuffix("gone.md") == true)
        #expect(f.text("a", "gone.md") == nil)
        #expect(f.text("a", "edited.md") == "v2 made after the crash")
        #expect(try await reopened.bin().map(\.path) == ["gone.md"])
        #expect(try await reopened.pendingDeleteIntent("gone.md") == nil)
        #expect(try await reopened.pendingDeleteIntent("edited.md") == nil)
    }

    // MARK: 2 — one bad record never stops the look

    @Test func anIntentForAnItemNeverInTheCloudIsDroppedAndTheLookGoesOn() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s"); try await f.settle(a)
        for (path, binned) in [("ghost.md", nil), ("ghost-binned.md", String(repeating: "a", count: 64))] as [(String, String?)] {
            try await a.seedIntentForTest(.init(place: path, scope: .everywhere, by: .ai, mac: f.deviceA, session: "Night", at: f.clock.ms,
                                               group: UUID().uuidString.lowercased()), binned: binned)
        }
        try await a.seedHeadForTest(place: "never-here.md", at: f.clock.ms)
        try f.write("a", "new.md", "new"); try await f.settle(a)
        #expect(try await CloudFolderFixture.journal(a).contains { $0.kind == .put && $0.source.recordId.hasSuffix("new.md") })
        #expect(try await a.pendingDeleteIntent("ghost.md") == nil)
        #expect(try await a.pendingDeleteIntent("ghost-binned.md") == nil)
        #expect(try await a.headCountForTest() == 0)
    }

    // MARK: 7 — an arriving removal: copy and engine in one step

    @Test func aCrashBetweenTheCopyAndTheEngineNeverSendsAnExtraRemoval() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        await b.setCrashPointForTests { point in if point == "arrival:afterCopy" { throw CloudFailure.unavailable } }
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(f.text("b", "note.md") == nil)
        // The app stops here and starts again; the next thing that happens is an arrival (it reconciles first).
        let restarted = try await f.mac("b", device: f.deviceB)
        f.clock.advance(60_000); try f.write("a", "other.md", "other"); try await f.settle(a)
        try await f.send(a, device: f.deviceA, to: restarted, cursor: &cursor)
        try await f.settle(restarted)
        #expect(try await CloudFolderFixture.journal(restarted).filter { $0.kind == .archive }.isEmpty)
        #expect(try await restarted.bin().map(\.path) == ["note.md"])
        #expect(try await restarted.headCountForTest() == 0)
        #expect(f.text("b", "other.md") == "other")
    }

    // MARK: 8 — the migration

    @Test func aMigrationRerunAfterAHalfwayFailureChangesNothingASecondTime() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "gone.md", "gone"); try f.write("a", "held.md", "keep this"); try f.write("a", "stay.md", "s")
        try await f.settle(a)
        try f.remove("a", "gone.md")
        try await a.seedLegacyDeleteState(at: f.clock.ms)
        await a.setCrashPointForTests { point in if point == "migration:afterHeld" { throw CloudFailure.unavailable } }
        try await a.look()
        #expect(try await a.control("deleteRuleMigrated") == nil)
        let heldPuts = try await CloudFolderFixture.journal(a).filter { $0.kind == .put && $0.source.recordId.hasSuffix("held.md") }.count
        await a.setCrashPointForTests(nil)
        try await a.look()
        #expect(try await a.control("deleteRuleMigrated") == "1")
        #expect(try await CloudFolderFixture.journal(a).filter { $0.kind == .put && $0.source.recordId.hasSuffix("held.md") }.count == heldPuts)
        #expect(f.text("a", "held.md") == "keep this")
        #expect(try await a.notHere().map(\.item.id) == ["gone.md"])
    }

    // MARK: 9 — "Only on this Mac" only where the file is

    @Test func onlyOnThisMacIsNeverWrittenWithoutAFileAndANewFileThereSyncs() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.setDeleteRuleGate { true }; await b.setDeleteRuleGate { true }
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        try f.remove("b", "note.md"); try await f.settle(b); f.clock.advance(4_000); try await b.look()
        #expect(try await b.notHere().first?.mark == .notOnThisMac)
        _ = try await a.deleteItems([item("note.md")], scope: .cloud, by: actor(f))
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        // B has no file there: no mark at all (nothing is in the Cloud to bring back).
        #expect(try await b.notHere().isEmpty)
        let before = try await CloudFolderFixture.journal(b).count
        f.clock.advance(60_000); try f.write("b", "note.md", "B's new file"); try await f.settle(b)
        #expect(try await CloudFolderFixture.journal(b).count > before)
        // On A the kept file is later removed by hand: the stale mark goes, and a new file there syncs too.
        #expect(try await a.notHere().first?.mark == .onlyOnThisMac)
        try f.remove("a", "note.md"); try await f.settle(a)
        #expect(try await a.notHere().isEmpty)
    }

    /// Final look (MUST 1): "Cloud" on a file, then a branch switch takes it away and brings the same bytes back: it is
    /// still "Only on this Mac" and nothing is sent. Bytes never seen there are his new file and sync.
    @Test func aCloudChoiceSurvivesTheFileGoingAndComingBackWithTheSameBytes() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        await a.setDeleteRuleGate { true }
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        _ = try await a.deleteItems([item("note.md")], scope: .cloud, by: actor(f))
        #expect(try await a.notHere().first?.mark == .onlyOnThisMac)
        let before = try await CloudFolderFixture.journal(a).count
        try f.remove("a", "note.md"); try await f.settle(a)
        try f.write("a", "note.md", "one"); try await f.settle(a); f.clock.advance(4_000); try await f.settle(a)
        #expect(try await a.notHere().first { $0.item.id == "note.md" }?.mark == .onlyOnThisMac)
        #expect(try await CloudFolderFixture.journal(a).count == before)
        try f.remove("a", "note.md"); try await f.settle(a)
        f.clock.advance(60_000); try f.write("a", "note.md", "a brand new note"); try await f.settle(a); f.clock.advance(4_000); try await f.settle(a)
        let after = try await CloudFolderFixture.journal(a)
        #expect(after.count > before)
        #expect(after.dropFirst(before).contains { $0.kind == .put && $0.source.recordId.hasSuffix("note.md") })
        #expect(try await a.notHere().isEmpty)
    }

    // MARK: 10 — the returning file

    @Test func anErrorInTheMiddleOfTheReturningFileCheckKeepsTheMark() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "old A"); try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try f.remove("a", "note.md"); try await f.settle(a)
        f.clock.advance(120_000); try f.write("b", "note.md", "new B"); try await f.settle(b)
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        // An old checkout comes back with today's date; the check fails in the middle once.
        try f.write("a", "note.md", "old A", modified: f.clock.ms + 1_000)
        await a.setCrashPointForTests { point in if point == "j7:beforeWrite" { throw CloudFailure.unavailable } }
        try await a.look()
        #expect(try await a.notHere().map(\.item.id) == ["note.md"])
        await a.setCrashPointForTests(nil)
        let before = try await CloudFolderFixture.journal(a).count
        try await f.settle(a); f.clock.advance(4_000); try await f.settle(a)
        #expect(f.text("a", "note.md") == "new B")
        #expect(try await CloudFolderFixture.journal(a).count == before)
        #expect(try await a.notHere().isEmpty)
    }

    // MARK: 11 — Put back all

    @Test func putBackAllGoesOnPastAnItemThatFailsAndAnswersWhatCameBack() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s"); try f.write("a", "locked/x.md", "x"); try f.write("a", "y.md", "y"); try f.write("a", "z.md", "z")
        try await f.settle(a)
        let who = actor(f)
        let group = try await a.deleteItems(["locked/x.md", "y.md", "z.md"].map(item), scope: .everywhere, by: who)
        #expect(group.count == 3)
        let locked = f.folder("a").appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let back = try await a.putBackGroup(who.group)
        #expect(back.map(\.id).sorted() == ["y.md", "z.md"])
        #expect(f.text("a", "y.md") == "y" && f.text("a", "z.md") == "z")
        #expect(try await a.bin().map(\.path) == ["locked/x.md"])
    }

    // MARK: 12 — speed

    @Test func theReturningFileCheckAsksTheHistoryOnceAndTheMarkTablesAreMadeOnce() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s")
        for n in 0..<120 { try f.write("a", "f\(n).md", "v1 \(n)") }
        try await f.settle(a)
        for n in 0..<120 { try f.write("a", "f\(n).md", "v2 \(n)") }
        f.clock.advance(60_000); try await f.settle(a)
        for n in 0..<120 { try f.remove("a", "f\(n).md") }
        try await f.settle(a)
        #expect(try await a.notHere().count == 120)
        // A branch switch brings back the first versions of all of them at once.
        for n in 0..<120 { try f.write("a", "f\(n).md", "v1 \(n)") }
        let before = try await CloudFolderFixture.journal(a).count
        let started = Date()
        try await f.settle(a)
        #expect(Date().timeIntervalSince(started) < 20)
        #expect(try await CloudFolderFixture.journal(a).count == before)
        #expect(f.text("a", "f7.md") == "v2 7")
        #expect(try await a.deleteStateIsCachedForTest())
    }
}

extension BackendCloudFolder {
    func seedIntentForTest(_ intent: CloudDeleteIntent, binned: String?) throws {
        try deleteState().putIntent(intent)
        if let binned { try state().run("INSERT OR REPLACE INTO file_delete_binned(place,hash) VALUES (?,?)", [.text(intent.place), .text(binned)]) }
    }
    /// An arrived removal saved for a path this Mac never had in the Cloud.
    func seedHeadForTest(place: String, at: Int64) throws {
        try CloudFileDeleteRecords.saveHead(in: state(), place: place, version: UUID().uuidString.lowercased(), parents: [UUID().uuidString.lowercased()],
            at: at, mac: UUID().uuidString.lowercased(), travel: .olderVersion)
    }
    func headCountForTest() throws -> Int { Int(try state().first("SELECT COUNT(*) FROM file_delete_heads")?.int(0) ?? 0) }
    func unblockSafetyForTest() throws {
        let safety = stateRoot.appendingPathComponent("safety")
        try FileManager.default.removeItem(at: safety)
        try FileManager.default.moveItem(at: stateRoot.appendingPathComponent("earlier-safety"), to: safety)
    }
    /// The state a crash right after the Bin step of a press leaves (intent, Bin entry, the past-Bin marker).
    func simulateCrashAfterBinForTest(_ path: String, intent: CloudDeleteIntent) async throws {
        let engine = try core()
        guard let current = try await engine.currentVersion(sourceId: profile.sourceId, relative: path),
              case .file(let bytes) = CloudFolderDisk.read(copyRoot, path) else { throw CloudFailure.unavailable }
        try deleteState().putIntent(intent)
        try keeper().binPut(kind: profile.keeperKind, itemKey: itemKey(path), name: Self.name(path), place: Self.place(path), path: path,
                            removedAt: intent.at, device: intent.mac, content: bytes, shown: true, now: now())
        try CloudFileDeleteRecords.rememberBin(await group(intent, path: path), place: path, in: state())
        try state().run("INSERT OR REPLACE INTO file_delete_binned(place,hash) VALUES (?,?)", [.text(path), .text(current.rawHash)])
    }
    func deleteStateIsCachedForTest() throws -> Bool { _ = try deleteState(); return deleteStateMade != nil }
}

/// The same review findings for instruction files (CLAUDE.md, AGENTS.md, GEMINI.md and their folders).
struct BootFilesDeleteReviewTests {
    func item(_ place: BackendCloudBootFilesPlace, _ relative: String) -> CloudDeleteItem {
        .init(id: place.sourceId + "\n" + relative, kind: "boot", name: (relative as NSString).lastPathComponent)
    }
    @Test func aFailedPressThenAnEditDeletesNothing() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA)
        let first = try await CloudBootFilesFixture.local(a)
        // The safety copy cannot be made: the press fails.
        try Data("obstruction".utf8).write(to: f.files.url("a/cloud/boot-files/safety"))
        await #expect(throws: (any Error).self) { _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor()) }
        #expect(f.files.text("a/app/CLAUDE.md") == "rules")
        try FileManager.default.removeItem(at: f.files.url("a/cloud/boot-files/safety"))
        try f.files.write("a/app/CLAUDE.md", "rules, edited after the error")
        try await f.absentLooks(a); try await f.absentLooks(a)
        #expect(f.files.text("a/app/CLAUDE.md") == "rules, edited after the error")
        #expect(!(try await CloudBootFilesFixture.local(a, after: first.cursor).operations.contains { $0.kind == .archive }))
        #expect(try await a.binGroups().isEmpty)
    }
    @Test func anIntentForAFileNeverInTheCloudNeverStopsTheRefresh() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA)
        let first = try await CloudBootFilesFixture.local(a)
        let place = f.place("a")
        for key in [place.sourceId + "\nAGENTS.md", "project/unknown\nCLAUDE.md"] {
            try await a.seedBootIntentForTest(.init(place: key, scope: .everywhere, by: .ai, mac: f.files.deviceA, session: "Night",
                                                    at: f.clock.ms, group: UUID().uuidString.lowercased()))
        }
        try f.files.write("a/app/GEMINI.md", "new rules")
        try await a.refresh()
        #expect(try await CloudBootFilesFixture.local(a, after: first.cursor).operations.contains { $0.kind == .put && $0.source.recordId.hasSuffix("GEMINI.md") })
        #expect(try await a.bootIntentCountForTest() == 0)
    }
    @Test func putBackAllWithOneFailingProjectRestoresTheRest() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/p/CLAUDE.md", "p rules"); try f.files.write("a/q/CLAUDE.md", "q rules")
        let p = f.files.project("p", "a/p"), q = f.files.project("q", "a/q")
        let clock = f.clock
        let a = try BackendCloudBootFiles(deviceId: f.files.deviceA, stateRoot: f.files.url("a/cloud/boot-files"), now: { clock.ms })
        await a.setDeleteRuleGate { true }
        try await a.setPlaces([p, q])
        let who = f.actor()
        let group = try await a.deleteItems([item(p, "CLAUDE.md"), item(q, "CLAUDE.md")], scope: .everywhere, by: who)
        #expect(group.count == 2)
        // Project q is no longer on this Mac.
        try await a.setPlaces([p])
        let back = try await a.putBackGroup(who.group)
        #expect(back.map(\.id) == [item(p, "CLAUDE.md").id])
        #expect(f.files.text("a/p/CLAUDE.md") == "p rules")
        #expect(f.files.text("a/q/CLAUDE.md") == nil)
    }
    @Test func putBackAfterTheProjectFolderMovedLandsInItsNewFolder() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA)
        let who = f.actor()
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: who)
        try FileManager.default.moveItem(at: f.files.url("a/app"), to: f.files.url("a/moved"))
        try await a.setPlaces([f.files.project("p", "a/moved")])
        #expect(try await a.putBackGroup(who.group).count == 1)
        #expect(f.files.text("a/moved/CLAUDE.md") == "rules")
    }
    @Test func aLinkedClaudeFileOrClaudeFolderIsNeverFollowedByADelete() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/outside/real.md", "not an instruction file of this project")
        try f.files.write("a/outside-folder/commands/go.md", "outside command")
        try f.files.write("a/app/AGENTS.md", "rules")
        try f.files.folder("a/app")
        try FileManager.default.createSymbolicLink(at: f.files.url("a/app/CLAUDE.md"), withDestinationURL: f.files.url("a/outside/real.md"))
        try FileManager.default.createSymbolicLink(at: f.files.url("a/app/.claude"), withDestinationURL: f.files.url("a/outside-folder"))
        let a = try await f.mac("a", device: f.files.deviceA)
        await #expect(throws: (any Error).self) { _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor()) }
        await #expect(throws: (any Error).self) { _ = try await a.deleteItems([f.item(".claude/commands/go.md")], scope: .everywhere, by: f.actor()) }
        #expect(f.files.text("a/outside/real.md") == "not an instruction file of this project")
        #expect(f.files.text("a/outside-folder/commands/go.md") == "outside command")
        #expect(f.files.exists("a/app/CLAUDE.md") && f.files.exists("a/app/.claude"))
        #expect(try await a.binGroups().isEmpty)
        #expect(f.files.text("a/app/AGENTS.md") == "rules")
    }
    @Test func aCloudChoiceOnAnInstructionFileSurvivesABranchSwitch() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA)
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .cloud, by: f.actor())
        #expect(try await a.notHere().first?.mark == .onlyOnThisMac)
        let before = try await CloudBootFilesFixture.local(a)
        // A branch without CLAUDE.md, then back to the branch with it.
        try FileManager.default.removeItem(at: f.files.url("a/app/CLAUDE.md")); try await f.absentLooks(a)
        try f.files.write("a/app/CLAUDE.md", "rules"); try await f.absentLooks(a)
        #expect(try await a.notHere().first?.mark == .onlyOnThisMac)
        #expect(try await CloudBootFilesFixture.local(a, after: before.cursor).operations.isEmpty)
        // Rules never seen there are his new file and sync normally.
        try FileManager.default.removeItem(at: f.files.url("a/app/CLAUDE.md")); try await f.absentLooks(a)
        try f.files.write("a/app/CLAUDE.md", "new rules written today"); try await f.absentLooks(a)
        #expect(try await CloudBootFilesFixture.local(a, after: before.cursor).operations.contains { $0.kind == .put })
        #expect(try await a.notHere().isEmpty)
    }
    @Test func aCrashBetweenTheCopyAndTheEngineNeverSendsAnExtraRemoval() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        var cursor: String?
        try await f.send(a, to: b, cursor: &cursor)
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor())
        await b.setCrashPointForTests { point in if point == "arrival:afterCopy" { throw CloudFailure.unavailable } }
        try await f.send(a, to: b, cursor: &cursor)
        #expect(f.files.text("b/app/CLAUDE.md") == nil)
        let restarted = try await f.mac("b", device: f.files.deviceB)
        try await f.absentLooks(restarted)
        #expect(!(try await CloudBootFilesFixture.local(restarted).operations.contains { $0.kind == .archive }))
        #expect(try await restarted.binGroups().first?.count == 1)
    }
    @Test func aDamagedAboutRecordIsARefusalOfThatOneRecordAndTheFileIsKept() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB, announced: true)
        var cursor: String?
        try await f.send(a, to: b, cursor: &cursor)
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor())
        let local = try await CloudBootFilesFixture.local(a, after: cursor)
        let expanded = try await a.travelOperations(local.operations)
        let about = try #require(expanded.first(where: CloudFileDeleteRecords.isAbout))
        var fields = try CloudFileDeleteRecords.read(about).fields
        fields[CloudDeleteTravel.rule] = "2"
        let newer = try CloudFileDeleteRecords.resealedForTest(about, fields: fields)
        let removal = try #require(expanded.first { $0.kind == .archive })
        let refusal = await CloudBootFilesFixture.refusal(b, [newer, removal])
        #expect(refusal?.operationIds == [newer.opId])
        _ = try await CloudBootFilesFixture.apply(b, [removal], device: f.files.deviceA)
        #expect(f.files.text("b/app/CLAUDE.md") == "rules")
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
    }
}

extension BackendCloudBootFiles {
    func seedBootIntentForTest(_ intent: CloudDeleteIntent) throws { try deleteState().putIntent(intent) }
    func bootIntentCountForTest() throws -> Int { Int(try state().first("SELECT COUNT(*) FROM cloud_delete_intents")?.int(0) ?? 0) }
}
