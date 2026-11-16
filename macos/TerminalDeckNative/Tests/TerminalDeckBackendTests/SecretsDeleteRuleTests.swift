import CryptoKit
import Darwin
import Foundation
import Testing
@testable import TerminalDeckBackend
@testable import TerminalDeckNativeCore

private final class SecretsDeleteClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_900_000_000_000
    private var open = true
    func now() -> Int64 { lock.withLock { value } }
    func advance(_ delta: Int64 = 3_001) { lock.withLock { value += delta } }
    func gate() -> Bool { lock.withLock { open } }
    func closeGate() { lock.withLock { open = false } }
    func openGate() { lock.withLock { open = true } }
}
private struct SecretsDeleteFixture: Sendable {
    let root: URL
    let projectId = "p-12345678"
    let shared = SymmetricKey(size: .bits256)
    let aKey = SymmetricKey(size: .bits256)
    let bKey = SymmetricKey(size: .bits256)
    let clock = SecretsDeleteClock()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("td-secrets-delete-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    func folder(_ mac: String) -> URL { root.appendingPathComponent(mac + "/Project") }
    func state(_ mac: String) -> URL { root.appendingPathComponent(mac + "/state") }
    func keys(_ mac: String) -> CloudSecretsStoreKeys { .init(epoch: 1, sharedKey: shared, local: mac == "A" ? aKey : bKey) }
    func actor(_ by: CloudDeleteBy = .person, group: String = UUID().uuidString) -> CloudDeleteActor {
        .init(by: by, mac: "a", macName: "Mac mini", session: by == .ai ? "Night work" : nil, agent: by == .ai ? "Worker" : nil, at: clock.now(), group: group)
    }
    func write(_ mac: String, _ text: String, path: String = ".env", mode: mode_t = 0o600) throws {
        let file = folder(mac).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file); chmod(file.path, mode)
    }
    func read(_ mac: String, path: String = ".env") -> Data? { try? Data(contentsOf: folder(mac).appendingPathComponent(path)) }
    /// `wallAhead`: this Mac's wall clock set forward by that much (the service clock stays right).
    func project(_ mac: String, witness: CloudDeleteWitnessSlot = .init(), wallAhead: Int64 = 0) async throws -> BackendProjectSecretFilesStore {
        // A real project folder is never empty (decision 11: an empty one counts as not on this Mac).
        try FileManager.default.createDirectory(at: folder(mac), withIntermediateDirectories: true)
        let readme = folder(mac).appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readme.path) { try Data("made-up project\n".utf8).write(to: readme) }
        let folder = folder(mac), id = projectId, clock = clock
        let made = BackendProjectSecretFilesStore(stateRoot: state(mac), projects: { [.init(id: id, name: "Shop", folders: [folder.path])] },
            deviceName: { mac == "A" ? "Mac mini" : "MacBook" }, gate: { .open }, home: root.appendingPathComponent("fake-home").path,
            walkReuse: 0, deleteGate: { clock.gate() }, deleteStamp: { clock.now() }, deleteDevice: { mac.lowercased() }, witness: witness,
            now: { clock.now() + wallAhead })
        await made.use(keys: keys(mac)); return made
    }
    func item(_ store: BackendProjectSecretFilesStore, path: String = ".env") async throws -> CloudDeleteItem {
        try #require(await store.deleteItem(projectId: projectId, folder: "", path: path))
    }
    func absent(_ mac: String, store: BackendProjectSecretFilesStore) async throws {
        try FileManager.default.removeItem(at: folder(mac).appendingPathComponent(".env"))
        _ = try await store.capture(); clock.advance(); _ = try await store.capture()
    }
    func saved(_ mac: String, values: SecretsDeleteValues) async -> BackendProjectSecretFilesSavedDeleteOwner {
        let clock = clock
        let owner = BackendProjectSecretFilesSavedDeleteOwner(store: values, stateRoot: state(mac), gate: { clock.gate() },
            name: { _ in "Example sign-in" }, remove: { await values.remove($0) }, now: { clock.now() })
        await owner.use(keys: keys(mac)); return owner
    }
}
private actor SecretsDeleteValues: CloudSecretsLogicalStore {
    nonisolated let sourceId = "servers"
    nonisolated let inventoryRow = "I14"
    nonisolated let domain = CloudSecretsDomain.server
    private var rows: [String: CloudSecretRecord] = [:]
    private var locked = false
    func lock(_ on: Bool) { locked = on }
    func set(_ value: String, id: String = "one") throws {
        rows[id] = try BackendCloudSecretsRecords.record(sourceId, id, domain, ["password": value])
    }
    func remove(_ record: CloudSecretRecord) -> Bool {
        guard rows[record.recordId] == record else { return false }
        rows[record.recordId] = nil; return true
    }
    func capture() -> [CloudSecretRecord] { Array(rows.values) }
    func validate(_ record: CloudSecretRecord) throws {
        guard !locked else { throw CloudFailure.secretsLocked }
        guard record.sourceId == sourceId, record.domain == domain.rawValue else { throw CloudFailure.invalidRequest }
    }
    func merge(_ record: CloudSecretRecord) -> CloudApplyStatus {
        if let current = rows[record.recordId] { return current == record ? .alreadyPresent : .keptBoth }
        rows[record.recordId] = record; return .applied
    }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) -> Bool {
        outcome == .keptBoth ? rows[record.recordId] != nil : rows[record.recordId] == record
    }
}
private struct SecretsDeleteAIWitness: CloudDeleteWitness {
    let group: String
    func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer {
        .ai(session: "Night work", agent: "Worker", command: lastSeen, group: group)
    }
}

@Suite(.serialized) struct SecretsDeleteRuleTests {
    @Test func projectEverywhereKeepsBytesBeforeUnlinkAndPutBackIs0600() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP_TOKEN=one", mode: 0o640)
        _ = try await a.capture()
        let item = try await f.item(a), actor = f.actor(.ai)
        let group = try await a.deleteItems([item], scope: .everywhere, by: actor)
        #expect(group.count == 1 && group.title == "Removed by an AI on Mac mini")
        #expect(group.session == "Night work" && f.read("A") == nil)
        #expect(try await a.binGroups().first?.id == actor.group)
        #expect(try await a.putBackGroup(group.id) == [item])
        #expect(f.read("A") == Data("MADE_UP_TOKEN=one".utf8))
        var info = stat(); #expect(lstat(f.folder("A").appendingPathComponent(".env").path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
    }
    @Test func aWholeActionHasOneGroupAndDeleteForGoodIsExplicit() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=one"); try f.write("A", "MADE_UP=two", path: ".env.local")
        _ = try await a.capture()
        let items = try await [f.item(a), f.item(a, path: ".env.local")]
        let group = try await a.deleteItems(items, scope: .everywhere, by: f.actor())
        #expect(group.count == 2)
        #expect(try await a.binGroups().count == 1)
        #expect(try await a.putBackGroup(group.id).count == 2)
        try await a.deleteForGood(items)
        #expect(try await a.binGroups().isEmpty)
    }
    @Test func aHandRemovalMarksLocallyAndNeverTravelsEvenWithNewerArrivals() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=old")
        let old = try #require(await a.capture().first)
        _ = try await b.merge(old); try await f.absent("B", store: b)
        #expect(try await b.notHere().first?.mark == .notOnThisMac)
        #expect(try await b.captureRemovals().isEmpty)
        try f.write("A", "MADE_UP=new")
        let new = try #require(await a.capture().first)
        _ = try await b.merge(new)
        #expect(f.read("B") == nil)
        #expect(try await b.notHere().count == 1)
        #expect(try await b.capture().isEmpty)
    }
    @Test func manyFilesGoneByHandAreMarksWithoutAQuestionOrLimit() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        for index in 0..<35 { try f.write("A", "MADE_UP=\(index)", path: ".env.\(index).local") }
        _ = try await a.capture()
        for index in 0..<35 { try FileManager.default.removeItem(at: f.folder("A").appendingPathComponent(".env.\(index).local")) }
        _ = try await a.capture(); f.clock.advance(); _ = try await a.capture()
        #expect(try await a.notHere().count == 35)
        #expect(try await a.captureRemovals().isEmpty)
    }
    @Test func witnessAIUsesEverywhereAndTheCommandGroup() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let slot = CloudDeleteWitnessSlot(), group = UUID().uuidString
        #expect(slot.installOnce(SecretsDeleteAIWitness(group: group)))
        let a = try await f.project("A", witness: slot)
        try f.write("A", "MADE_UP=gone"); _ = try await a.capture(); try await f.absent("A", store: a)
        let removal = try #require(await a.captureRemovals().first)
        #expect(removal.fields[CloudDeleteTravel.scope] == "everywhere")
        #expect(removal.fields[CloudDeleteTravel.by] == "ai" && removal.fields[CloudDeleteTravel.group] == group)
        #expect(try await a.binGroups().first?.session == "Night work")
    }
    @Test func missingRootIsNeverADeleteOrAMark() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let slot = CloudDeleteWitnessSlot(); _ = slot.installOnce(SecretsDeleteAIWitness(group: UUID().uuidString))
        let a = try await f.project("A", witness: slot)
        try f.write("A", "MADE_UP=kept"); _ = try await a.capture()
        try FileManager.default.moveItem(at: f.folder("A"), to: f.folder("A").appendingPathExtension("away"))
        _ = try await a.capture(); f.clock.advance(); _ = try await a.capture()
        #expect(try await a.notHere().isEmpty)
        #expect(try await a.captureRemovals().isEmpty)
    }
    @Test func twoLooksAvoidAnEditorDeleteAndRewrite() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=old"); _ = try await a.capture()
        try FileManager.default.removeItem(at: f.folder("A").appendingPathComponent(".env")); _ = try await a.capture()
        try f.write("A", "MADE_UP=new"); f.clock.advance(); _ = try await a.capture()
        #expect(try await a.notHere().isEmpty)
        #expect(try await a.captureRemovals().isEmpty)
    }
    @Test func reappearingOldVersionPlacesTheCloudNewestWithoutUploadingOldBytes() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=old"); let old = try #require(await a.capture().first)
        _ = try await b.merge(old); try await f.absent("B", store: b)
        try f.write("A", "MADE_UP=new"); _ = try await b.merge(#require(await a.capture().first))
        try f.write("B", "MADE_UP=old")
        #expect(try await b.capture().isEmpty)
        #expect(f.read("B") == Data("MADE_UP=new".utf8))
        #expect(try await b.notHere().isEmpty)
    }
    @Test func reappearingNewestClearsMarkWithoutANewVersion() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=same"); _ = try await a.capture(); try await f.absent("A", store: a)
        try f.write("A", "MADE_UP=same")
        #expect(try await a.capture().isEmpty)
        #expect(try await a.notHere().isEmpty)
    }
    @Test func reappearingOwnBytesAreBasedOnTheNewestCloudHead() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=old"); _ = try await b.merge(#require(await a.capture().first))
        try await f.absent("B", store: b)
        try f.write("A", "MADE_UP=new")
        let newest = try #require(await a.capture().first); _ = try await b.merge(newest)
        try f.write("B", "MADE_UP=own")
        let own = try #require(await b.capture().first)
        let value = try BackendCloudSecretsRecords.decode(BackendProjectSecretFileValue.self, own, source: "project-files", domain: .project)
        #expect(value.base == newest.payload.raw["mark"].string)
    }
    @Test func projectCloudScopeKeepsEveryFileAndPutInCloudAgainUsesThisMacBytes() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=kept"); _ = try await b.merge(#require(await a.capture().first))
        _ = try await a.deleteItems([f.item(a)], scope: .cloud, by: f.actor())
        let removal = try #require(await a.captureRemovals().first)
        #expect(try await b.mergeRemoval(removal) == .applied)
        #expect(f.read("A") != nil && f.read("B") != nil)
        #expect(try await a.capture().isEmpty)
        #expect(try await b.capture().isEmpty)
        try f.write("B", "MADE_UP=this-Mac")
        let item = try await f.item(b)
        _ = try await b.bringBack([item], to: .cloud)
        #expect(try await b.capture().first?.payload.raw["data"].string == Data("MADE_UP=this-Mac".utf8).base64EncodedString())
    }
    @Test func projectArrivalRemovesOnlyItsExactVersionAndBinsOnBothMacs() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=one"); _ = try await b.merge(#require(await a.capture().first))
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor(.ai))
        let removal = try #require(await a.captureRemovals().first)
        #expect(try await b.mergeRemoval(removal) == .applied)
        #expect(f.read("B") == nil)
        #expect(try await b.binGroups().count == 1)
        #expect(try await b.verifyRemoval(removal, outcome: .applied))
        #expect(try await b.mergeRemoval(removal) == .applied)
    }
    @Test func projectLaterLocalEditBeatsAnArrivingRemoval() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=old"); _ = try await b.merge(#require(await a.capture().first))
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        try f.write("B", "MADE_UP=later")
        #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .keptBoth)
        #expect(f.read("B") == Data("MADE_UP=later".utf8))
        #expect(try await b.binGroups().isEmpty)
    }
    @Test func arrivingRemovalCanRecognizeAnUnledgeredSameFile() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=same"); try f.write("B", "MADE_UP=same"); _ = try await a.capture()
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .applied)
        #expect(f.read("B") == nil)
    }
    @Test func sealedBinCannotOpenWithTheOtherMacKeyAndClosesOnSignOut() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP_SECRET_NO_PLAINTEXT"); _ = try await a.capture()
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        let root = f.state("A").appendingPathComponent("sealed-bin")
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: root.path).first { $0.hasSuffix(".sealed") })
        let data = try Data(contentsOf: root.appendingPathComponent(name))
        #expect(data.range(of: Data("MADE_UP_SECRET_NO_PLAINTEXT".utf8)) == nil)
        let box = try AES.GCM.SealedBox(combined: data)
        #expect(throws: (any Error).self) { try AES.GCM.open(box, using: f.bKey) }
        let encodedSecret = Data("MADE_UP_SECRET_NO_PLAINTEXT".utf8).base64EncodedString()
        #expect(try AES.GCM.open(box, using: f.aKey).range(of: Data(encodedSecret.utf8)) != nil)
        await a.use(keys: nil)
        await #expect(throws: (any Error).self) { try await a.binGroups() }
        #expect(await a.status() == nil)
    }
    /// Decision 7: while an older Mac exists neither scope can be honoured; nothing is removed under the name
    /// "Everywhere" on this Mac only, and the page can ask first.
    @Test func closedGateRefusesBothScopesAndThePageCanAskFirst() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=one"); _ = try await a.capture(); let item = try await f.item(a)
        #expect(await a.canDeleteEverywhere())
        f.clock.closeGate()
        #expect(!(await a.canDeleteEverywhere()))
        for scope in CloudDeleteScope.allCases {
            do { _ = try await a.deleteItems([item], scope: scope, by: f.actor()); Issue.record("Refused while an older Mac exists") }
            catch { #expect(error.localizedDescription == CloudDeleteWords.cloudNeedsUpdatedMacs) }
        }
        #expect(f.read("A") == Data("MADE_UP=one".utf8))
        #expect(try await a.captureRemovals().isEmpty)
        #expect(try await a.binGroups().isEmpty)
        let values = SecretsDeleteValues(); try await values.set("MADE_UP_PASSWORD")
        let saved = await f.saved("B", values: values); _ = try await saved.capture()
        #expect(!(await saved.canDeleteEverywhere()))
        let password = try #require(await saved.items().first)
        await #expect(throws: BackendCloudSecretsWaiting(reason: CloudDeleteWords.cloudNeedsUpdatedMacs)) {
            try await saved.deleteItems([password], scope: .everywhere, by: f.actor())
        }
        #expect(await values.capture().count == 1)
    }
    @Test func savedPasswordsBothScopesApplyAndLaterChangesWin() async throws {
        for scope in CloudDeleteScope.allCases {
            let f = try SecretsDeleteFixture(); defer { f.close() }
            let av = SecretsDeleteValues(), bv = SecretsDeleteValues()
            try await av.set("MADE_UP_PASSWORD"); try await bv.set("MADE_UP_PASSWORD")
            let a = await f.saved("A", values: av), b = await f.saved("B", values: bv)
            _ = try await a.capture(); _ = try await b.capture()
            let item = try #require(await a.items().first)
            _ = try await a.deleteItems([item], scope: scope, by: f.actor(.ai))
            let removal = try #require(await a.captureRemovals().first)
            #expect(try await b.mergeRemoval(removal) == .applied)
            #expect((await bv.capture()).isEmpty == (scope == .everywhere))
            #expect(try await b.binGroups().first?.count == 1)
            try await bv.set("MADE_UP_NEWER_PASSWORD")
            #expect(try await b.mergeRemoval(removal) == .keptBoth)
        }
    }
    @Test func savedPasswordPutBackDoesNotOverwriteNewerLocalWork() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let values = SecretsDeleteValues(); try await values.set("MADE_UP_OLD")
        let a = await f.saved("A", values: values); _ = try await a.capture()
        let group = try await a.deleteItems([#require(await a.items().first)], scope: .everywhere, by: f.actor())
        try await values.set("MADE_UP_NEW")
        #expect(try await a.putBackGroup(group.id).isEmpty)
        #expect(try await a.binGroups().count == 1)
    }
    @Test func savedPasswordBinSurvivesRestartButNotAWrongLocalKey() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let values = SecretsDeleteValues(); try await values.set("MADE_UP_PASSWORD")
        let a = await f.saved("A", values: values); _ = try await a.capture()
        _ = try await a.deleteItems([#require(await a.items().first)], scope: .everywhere, by: f.actor())
        await a.use(keys: nil)
        let restarted = await f.saved("A", values: values)
        #expect(try await restarted.binGroups().count == 1)
        await restarted.use(keys: nil)
        await restarted.use(keys: .init(epoch: 1, sharedKey: f.shared, local: f.bKey))
        // Decision 8: a Bin that cannot be opened never looks locked: it is set aside (kept on disk, never deleted)
        // and named with one fixed line; nothing of it can be read with the wrong key.
        #expect(try await restarted.binGroups().isEmpty)
        #expect(await restarted.binNotice() == BackendProjectSecretFilesWords.binDamaged)
        let bin = f.state("A").appendingPathComponent("sealed-bin")
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).contains { $0.contains(".sealed.unreadable-") })
    }
    /// Decision 8: 30 days from the removal, then the sealed copy is gone for good.
    @Test func aBinRowOlderThanThirtyDaysIsGoneForGood() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=kept"); _ = try await a.capture()
        let group = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor(.ai))
        f.clock.advance(CloudBinGroup.retentionMilliseconds - 10)
        #expect(try await a.binGroups().first?.id == group.id)
        f.clock.advance(20)
        _ = try await a.capture()
        #expect(try await a.binGroups().isEmpty)
        #expect(try await a.putBackGroup(group.id).isEmpty)
        #expect(f.read("A") == nil)
    }
    @Test func denyRulesCoverKeepersBinsAndSafetyWithoutPrompts() throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let rules = BackendMacConfinement.binDenyRules(f.root)
        for name in ["memory-safety", "project-secret-files", "cloud-mcp-pending", "sealed-bin", "archive|memory/versions", "/safety"] {
            #expect(rules.contains(name))
        }
        #expect(rules.components(separatedBy: "(deny file-read* file-write*").count - 1 == 5)
        #expect(BackendMacConfinement.recordsFenceProfile(f.root).hasSuffix(rules))
        #expect(!rules.contains("ask") && !rules.contains("prompt"))
    }
}

/// The existing saved-passwords test service and real content seal. Each Mac has its own key slot/device key,
/// both holding the same made-up account root. No live route or real protected store is reachable.
private struct SecretsDeletePacks {
    let a: CloudSecretsFixtureClient
    let b: CloudSecretsFixtureClient
    let av = SecretsDeleteValues()
    let bv = SecretsDeleteValues()
    let ao: BackendProjectSecretFilesSavedDeleteOwner
    let bo: BackendProjectSecretFilesSavedDeleteOwner
    let aa: CloudSecretsLogicalAdapter
    let ba: CloudSecretsLogicalAdapter
    let cut: CloudSnapshotCut
    init(_ f: SecretsDeleteFixture) async throws {
        let server = CloudSecretsFixtureServer()
        a = try await CloudSecretsFixtureClient(server: server); b = try await CloudSecretsFixtureClient(server: server)
        try await a.coordinator.setup()
        let key = try #require(await a.local.read())
        try await b.local.saveVerified(.init(subject: key.subject, deviceId: b.device.deviceId, epoch: key.epoch, version: key.version,
            root: key.root, recoveryPublicKey: key.recoveryPublicKey, acknowledged: true))
        let av = self.av, bv = self.bv, clock = f.clock
        ao = .init(store: av, stateRoot: f.state("A"), gate: { clock.gate() }, name: { _ in "Example sign-in" },
                   remove: { await av.remove($0) }, now: { clock.now() })
        bo = .init(store: bv, stateRoot: f.state("B"), gate: { clock.gate() }, name: { _ in "Example sign-in" },
                   remove: { await bv.remove($0) }, now: { clock.now() })
        let journal = CloudSecretsFixtureJournal()
        aa = .init(store: ao, content: a.content, policy: a.policy, deviceId: a.device.deviceId,
                   keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
        ba = .init(store: bo, content: b.content, policy: b.policy, deviceId: b.device.deviceId,
                   keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
        cut = .init(snapshotId: UUID().uuidString, at: CloudSecretsFixtureServer.now, watermarks: [:])
    }
    func seed() async throws {
        try await av.set("MADE_UP_PACK_SECRET")
        let put = try await aa.snapshot(cut: cut)
        _ = try await deliver(put, to: ba)
    }
    func deliver(_ snapshot: CloudDomainSnapshot, to adapter: CloudSecretsLogicalAdapter) async throws -> CloudImportReceipt {
        let prepared = try await adapter.validateIncoming(snapshot.operations, files: [])
        return try await adapter.applyPrepared(prepared, origin: .init(deviceId: a.device.deviceId, sequence: CloudSequence(1)))
    }
}

extension SecretsDeleteRuleTests {
    @Test func sealedTransferCarriesAllSixFieldsAndAppliesTheRemoval() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f); try await p.seed()
        _ = try await p.ao.deleteItems([#require(await p.ao.items().first)], scope: .everywhere, by: f.actor(.ai))
        let snapshot = try await p.aa.changedSnapshot(cut: p.cut)
        let operation = try #require(snapshot.operations.first)
        #expect(operation.kind == .archive)
        let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSecretsCanonical.encode(operation.payload))
        #expect(envelope.storageClass == .secrets && envelope.purpose == .secret)
        let plain = try await p.b.content.open(envelope)
        let removal = try CloudWire.decode(CloudSecretRemoval.self, from: plain)
        #expect(Set(CloudDeleteTravel.fields).isSubset(of: Set(removal.fields.keys)))
        let wire = try CloudSecretsCanonical.encode(snapshot)
        for hidden in ["MADE_UP_PACK_SECRET", "Night work", "Worker", "td_scope", "td_group"] {
            #expect(wire.range(of: Data(hidden.utf8)) == nil)
        }
        let receipt = try await p.deliver(snapshot, to: p.ba)
        #expect(receipt.results.first?.status == .applied)
        #expect(await p.bv.capture().isEmpty)
        #expect(try await p.bo.binGroups().count == 1)
    }
    @Test func aRemovalOutsideTheSavedPasswordsSealIsRefusedBeforeAnyWriter() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f); try await p.seed()
        _ = try await p.ao.deleteItems([#require(await p.ao.items().first)], scope: .everywhere, by: f.actor())
        let removal = try #require(await p.ao.captureRemovals().first)
        let payload = CloudValue(try NativeRPCValue.parseJSON(CloudSecretsCanonical.encode(removal)))
        let id = UUID().uuidString
        let plain = CloudOperation(v: 1, opId: id, originDevice: "a", domain: "server", entityId: "one", revision: id, parents: [], kind: .archive,
            source: .init(sourceId: "servers", recordId: "one"), createdAt: f.clock.now(), payload: payload,
            payloadHash: try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(payload)))
        // Decision 4: closed with a final "not applied" row (never a stall), and no writer ran.
        let receipt = try await p.deliver(.init(cut: p.cut, operations: [plain], files: [], coverage: []), to: p.ba)
        #expect(receipt.results == [CloudItemResult(entityId: "one", status: .alreadyPresent, reason: CloudSecretsLogicalAdapter.notAppliedWords)])
        #expect(await p.bv.capture().count == 1)
        #expect(try await p.bo.binGroups().isEmpty)
    }
    @Test func aBrainEnvelopeCannotAuthorizeASecretRemoval() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f); try await p.seed()
        _ = try await p.ao.deleteItems([#require(await p.ao.items().first)], scope: .everywhere, by: f.actor())
        let good = try #require(await p.aa.changedSnapshot(cut: p.cut).operations.first)
        // The envelope's wire key is "class" (CloudContentEnvelope.CodingKeys; CloudContractTests: "storageClass" never
        // appears on the wire). Setting "storageClass" only added an unknown key the decoder ignores, so the old forgery
        // was still the genuine saved-passwords envelope and rightly applied. Relabel the real field, and prove it took.
        let raw = try NativeRPCValue.parseJSON(CloudSecretsCanonical.encode(good.payload)).setting("class", .string("brain"))
        let payload = CloudValue(raw), id = UUID().uuidString
        #expect(try CloudWire.decode(CloudContentEnvelope.self, from: CloudSecretsCanonical.encode(payload)).storageClass == .brain)
        let bad = CloudOperation(v: 1, opId: id, originDevice: "a", domain: good.domain, entityId: good.entityId, revision: id,
            parents: [], kind: .archive, source: good.source, createdAt: good.createdAt, payload: payload,
            payloadHash: try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(payload)))
        let receipt = try await p.deliver(.init(cut: p.cut, operations: [bad], files: [], coverage: []), to: p.ba)
        #expect(receipt.results == [CloudItemResult(entityId: good.entityId, status: .alreadyPresent, reason: CloudSecretsLogicalAdapter.notAppliedWords)])
        #expect(await p.bv.capture().count == 1)
        #expect(try await p.bo.binGroups().isEmpty)
    }
    @Test func identicalBytesCanBeDeliberatelyPutInCloudAgainAndAnOldRemovalCannotUndoIt() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f); try await p.seed()
        let item = try #require(await p.ao.items().first)
        _ = try await p.ao.deleteItems([item], scope: .cloud, by: f.actor())
        let removed = try await p.aa.changedSnapshot(cut: p.cut)
        _ = try await p.deliver(removed, to: p.ba)
        _ = try await p.ao.bringBack([item], to: .cloud)
        let restored = try await p.aa.changedSnapshot(cut: p.cut)
        #expect(restored.operations.map(\.kind) == [.put])
        _ = try await p.deliver(restored, to: p.ba)
        #expect(try await p.bo.notHere().isEmpty)
        _ = try await p.deliver(removed, to: p.ba)
        #expect(try await p.bo.notHere().isEmpty)
        #expect(await p.bv.capture().count == 1)
    }
    @Test func savedPasswordsOffAndAdapterSealDropAllReadableBinState() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f); try await p.seed()
        _ = try await p.ao.deleteItems([#require(await p.ao.items().first)], scope: .everywhere, by: f.actor())
        #expect(try await p.ao.binGroups().count == 1)
        await p.aa.seal()
        await #expect(throws: (any Error).self) { try await p.ao.binGroups() }
        await p.b.gate.disableCloud()
        await #expect(throws: (any Error).self) { try await p.ba.exportRecords() }
        await #expect(throws: (any Error).self) { try await p.bo.binGroups() }
    }
    @Test func malformedAttributionAndForgedRemovedVersionCannotRemoveAnything() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=kept"); let record = try #require(await a.capture().first)
        let bad = CloudSecretRemoval(sourceId: "project-files", recordId: record.recordId, domain: "project", version: String(repeating: "0", count: 64),
            fields: [CloudDeleteTravel.rule: "1", CloudDeleteTravel.scope: "everywhere", CloudDeleteTravel.by: "ai", CloudDeleteTravel.group: "bad-group"],
            mac: "b", macName: "MacBook", at: f.clock.now(), removed: record)
        await #expect(throws: (any Error).self) { try await a.mergeRemoval(bad) }
        #expect(f.read("A") != nil)
    }
    @Test func statusToolAndErrorsNeverIncludeTheMadeUpSecret() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        let secret = "MADE_UP_SECRET_MUST_NOT_ESCAPE"
        try f.write("A", secret); _ = try await a.capture()
        let status = try #require(await a.status())
        #expect(!String(describing: status).contains(secret))
        let answer = BackendProjectSecretFilesTools.answer(status)
        #expect(!String(describing: answer).contains(secret))
        do {
            _ = try await a.deleteItems([.init(id: secret, kind: "project-secret-files", name: "Example")], scope: .everywhere, by: f.actor())
            Issue.record("Unknown target should be refused")
        } catch { #expect(!error.localizedDescription.contains(secret)) }
    }
}

private actor SecretsDeleteMCPCommand {
    let file: URL
    private var calls: [[String]] = []
    init(file: URL) { self.file = file }
    func arguments() -> [[String]] { calls }
    func run(_ command: String, _ args: [String]) throws -> BackendGitOutcome {
        calls.append(args)
        var root = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        if args.prefix(2) == ["mcp", "remove"], let name = args.last {
            root = root.setting("mcpServers", root["mcpServers"].removing(name))
        } else if args.prefix(2) == ["mcp", "add-json"], args.count >= 7 {
            let name = args[args.count - 2]
            let value = try NativeRPCValue.parseJSON(Data(args[args.count - 1].utf8))
            root = root.setting("mcpServers", root["mcpServers"].setting(name, value))
        } else { throw CloudFailure.invalidRequest }
        try root.encodedJSON().write(to: file, options: .atomic)
        return .init(ok: true, stdout: "", stderr: "", missing: false, exitCode: 0, timedOut: false)
    }
}
private extension SecretsDeleteFixture {
    func mcp(_ mac: String) async throws -> (owner: BackendProjectSecretFilesSavedDeleteOwner, command: SecretsDeleteMCPCommand, configuration: BackendMcpClientConfiguration) {
        let home = root.appendingPathComponent(mac + "/fake-cli-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = BackendMcpClientConfiguration(home: home.path, environment: [:])
        let definition = NativeRPCValue.object([.init("command", .string("example")), .init("env", .object([.init("TOKEN", .string("MADE_UP_MCP_TOKEN"))]))])
        let file = URL(fileURLWithPath: config.claudeJSONPath)
        try NativeRPCValue.object([.init("mcpServers", .object([.init("example", definition), .init("unrelated", .object([.init("command", .string("keep"))]))])),
                                   .init("unrelatedPreference", .bool(true))]).encodedJSON().write(to: file)
        let command = SecretsDeleteMCPCommand(file: file), local = mac == "A" ? aKey : bKey
        let cipher = BackendBrowserPasswordsCipher(available: { true }, decrypt: { bytes in
            String(decoding: try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: local), as: UTF8.self)
        }, encrypt: { text, _ in
            guard let bytes = try AES.GCM.seal(Data(text.utf8), using: local).combined else { throw CloudFailure.unavailable }
            return bytes
        })
        let pending = BackendCloudSecretsMCPPending(dataRoot: state(mac), cipher: cipher, requireWriter: {})
        let claude = BackendCloudSecretsClaudeMCP(configuration: config, loginPath: { "/made-up-cli-path" }, run: { name, args, _, _, _ in
            try await command.run(name, args)
        })
        let raw = try BackendCloudSecretsMCPStore.bound(sourceId: "mcp-user", configuration: config, scope: "user", project: nil,
            claude: claude, pending: pending, confirm: { _ in Issue.record("Bin put back must not add another question"); return false }, requireWriter: {})
        let clock = clock
        let wrapped = raw.deleteRuleStore(stateRoot: state(mac), gate: { clock.gate() }, now: { clock.now() })
        await wrapped.use(keys: keys(mac))
        return (wrapped, command, config)
    }
}
private actor SecretsDeleteEchoingStore: CloudSecretsLogicalStore {
    nonisolated let sourceId = "servers"
    nonisolated let inventoryRow = "I14"
    nonisolated let domain = CloudSecretsDomain.server
    func capture() throws -> [CloudSecretRecord] { throw NativeRPCError(code: "made-up", message: "MADE_UP_ECHOED_SECRET") }
    func validate(_ record: CloudSecretRecord) {}
    func merge(_ record: CloudSecretRecord) -> CloudApplyStatus { .alreadyPresent }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) -> Bool { true }
}
extension SecretsDeleteRuleTests {
    @Test func mcpArrivalUsesTheClickWriterAndBinPutBackRestoresWithoutAnotherQuestion() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.mcp("A"), b = try await f.mcp("B")
        _ = try await a.owner.capture(); _ = try await b.owner.capture()
        let item = try #require(await a.owner.items().first { $0.id == "example" })
        _ = try await a.owner.deleteItems([item], scope: .everywhere, by: f.actor(.ai))
        let removal = try #require(await a.owner.captureRemovals().first)
        #expect(try await b.owner.mergeRemoval(removal) == .applied)
        #expect(try b.configuration.cloudDefinitions(scope: "user", project: nil)["example"] == .missing)
        #expect(try b.configuration.cloudDefinitions(scope: "user", project: nil)["unrelated"] != .missing)
        let calls = await b.command.arguments()
        #expect(calls == [["mcp", "remove", "--scope", "user", "--", "example"]])
        #expect(!String(describing: calls).contains("MADE_UP_MCP_TOKEN"))
        let group = try #require(await b.owner.binGroups().first)
        #expect(try await b.owner.putBackGroup(group.id).count == 1)
        #expect(try b.configuration.cloudDefinitions(scope: "user", project: nil)["example"]["env"]["TOKEN"].string == "MADE_UP_MCP_TOKEN")
    }
    @Test func aPasswordOwnersEchoedErrorCannotBecomeAToolErrorOrLogLine() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let clock = f.clock
        let owner = BackendProjectSecretFilesSavedDeleteOwner(store: SecretsDeleteEchoingStore(), stateRoot: f.state("A"),
            gate: { true }, name: { _ in "Example sign-in" }, remove: { _ in false }, now: { clock.now() })
        await owner.use(keys: f.keys("A"))
        do { _ = try await owner.capture(); Issue.record("The made-up refusal should fail") }
        catch {
            #expect(!error.localizedDescription.contains("MADE_UP_ECHOED_SECRET"))
            #expect(!CloudSecretsLog.cause(error).contains("MADE_UP_ECHOED_SECRET"))
        }
    }
}

extension SecretsDeleteRuleTests {
    @Test func ordinaryReadAndBringBackCannotBeUsedAsABinDoor() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=private"); _ = try await a.capture()
        let item = try await f.item(a)
        _ = try await a.deleteItems([item], scope: .everywhere, by: f.actor(.ai))
        #expect(try await a.notHere().isEmpty)
        let status = try #require(await a.status())
        #expect(BackendProjectSecretFilesTools.answer(status)["projects"].elements?.isEmpty == true)
        await #expect(throws: (any Error).self) { try await a.bringBack([item], to: .thisMac) }
        #expect(try await a.binGroups().count == 1)
        let values = SecretsDeleteValues(); try await values.set("MADE_UP_PASSWORD")
        let saved = await f.saved("B", values: values); _ = try await saved.capture()
        let password = try #require(await saved.items().first)
        _ = try await saved.deleteItems([password], scope: .everywhere, by: f.actor(.ai))
        #expect(try await saved.notHere().isEmpty)
        await #expect(throws: (any Error).self) { try await saved.bringBack([password], to: .cloud) }
    }
    @Test func projectRemovalTravelsThroughTheActualSavedPasswordsAdapter() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f)
        let a = try await f.project("A"), b = try await f.project("B")
        let aa = CloudSecretsLogicalAdapter(store: a, content: p.a.content, policy: p.a.policy, deviceId: p.a.device.deviceId,
            keepConflicts: { _ in throw CloudFailure.unavailable }, retainIncomingConflict: { _ in })
        let ba = CloudSecretsLogicalAdapter(store: b, content: p.b.content, policy: p.b.policy, deviceId: p.b.device.deviceId,
            keepConflicts: { _ in throw CloudFailure.unavailable }, retainIncomingConflict: { _ in })
        try f.write("A", "MADE_UP_PROJECT_PACK_SECRET")
        _ = try await p.deliver(aa.snapshot(cut: p.cut), to: ba)
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor(.ai))
        let removed = try await aa.changedSnapshot(cut: p.cut)
        #expect(removed.operations.map(\.kind) == [.archive])
        _ = try await p.deliver(removed, to: ba)
        #expect(f.read("B") == nil)
        let group = try #require(await b.binGroups().first)
        #expect(try await b.putBackGroup(group.id).count == 1)
        #expect(f.read("B") == Data("MADE_UP_PROJECT_PACK_SECRET".utf8))
    }
    @Test func localMarksSurviveAStoreRestartAndNewCloudVersions() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=old"); _ = try await b.merge(#require(await a.capture().first))
        try await f.absent("B", store: b); await b.use(keys: nil)
        let restarted = try await f.project("B")
        #expect(try await restarted.notHere().first?.mark == .notOnThisMac)
        try f.write("A", "MADE_UP=new"); _ = try await restarted.merge(#require(await a.capture().first))
        #expect(f.read("B") == nil)
        #expect(try await restarted.captureRemovals().isEmpty)
    }
}

extension SecretsDeleteRuleTests {
    /// A leaked password must go everywhere: X, Y and back to X on Mac B is removed by an Everywhere delete of X on A.
    @Test func aValueThatWentXYXOnBIsRemovedByAnEverywhereDeleteOfX() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f); try await p.seed()
        let item = try #require(await p.ao.items().first)
        _ = try await p.ao.deleteItems([item], scope: .everywhere, by: f.actor())
        let oldRemoval = try #require(await p.ao.captureRemovals().first)
        try await p.bv.set("MADE_UP_DIFFERENT_PASSWORD")
        let second = try await p.ba.changedSnapshot(cut: p.cut)
        #expect(second.operations.count == 1)
        // Y really reaches the Cloud (queued, then read back). Without this the Cloud still holds X, and X again on B
        // is rightly no change (changedSnapshot compares with what the Cloud last confirmed).
        let journal = CloudSecretsFixtureJournal()
        try await p.ba.markPublished(second, receipt: journal.enqueue(second.operations))
        await p.ba.confirmed(operationIds: Set(second.operations.map(\.opId)))
        try await p.bv.set("MADE_UP_PACK_SECRET")
        let third = try await p.ba.changedSnapshot(cut: p.cut)
        #expect(third.operations.count == 1)
        #expect(try await p.bo.mergeRemoval(oldRemoval) == .applied)
        #expect(await p.bv.capture().isEmpty)
        #expect(try await p.bo.binGroups().count == 1)
    }
}

extension SecretsDeleteRuleTests {
    /// The owner's own compare-and-remove refused (the value changed under it, or its writer said no): his value
    /// stays, the removal closes as not applied (no stalled feed), and no Bin row or intent is left behind.
    @Test func aRefusedOwnerRemovalLeavesNoBinRowAndDoesNotStall() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let av = SecretsDeleteValues(), bv = SecretsDeleteValues()
        try await av.set("MADE_UP_PASSWORD"); try await bv.set("MADE_UP_PASSWORD")
        let a = await f.saved("A", values: av)
        let clock = f.clock
        let b = BackendProjectSecretFilesSavedDeleteOwner(store: bv, stateRoot: f.state("B"), gate: { clock.gate() },
            name: { _ in "Example sign-in" }, remove: { _ in false }, now: { clock.now() })
        await b.use(keys: f.keys("B"))
        _ = try await a.capture(); _ = try await b.capture()
        _ = try await a.deleteItems([#require(await a.items().first)], scope: .everywhere, by: f.actor(.ai))
        let removal = try #require(await a.captureRemovals().first)
        #expect(try await b.mergeRemoval(removal) == .keptBoth)
        #expect(await bv.capture().count == 1)
        #expect(try await b.binGroups().isEmpty)
        #expect(try await b.notHere().isEmpty)
        #expect(try await b.verifyRemoval(removal, outcome: .keptBoth))
    }
    /// A removal for a project secret file whose project folder is not on this Mac applies into the sealed Bin
    /// (nothing on disk to unlink) instead of stalling every other saved password behind it.
    @Test func aProjectRemovalWithItsFolderNotOnThisMacAppliesIntoTheBin() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=far"); _ = try await a.capture()
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        let removal = try #require(await a.captureRemovals().first)
        let clock = f.clock
        let b = BackendProjectSecretFilesStore(stateRoot: f.state("B"), projects: { [] }, deviceName: { "MacBook" }, gate: { .open },
            home: f.root.appendingPathComponent("fake-home").path, walkReuse: 0, deleteGate: { clock.gate() },
            deleteStamp: { clock.now() }, deleteDevice: { "b" }, witness: .init(), now: { clock.now() })
        await b.use(keys: f.keys("B"))
        #expect(try await b.mergeRemoval(removal) == .applied)
        #expect(try await b.verifyRemoval(removal, outcome: .applied))
        #expect(try await b.binGroups().first?.count == 1)
    }
}

/// A copy of `like` with another kind or payload (new operation id, payload hash of the new payload).
private func secretsDeleteOperation(like o: CloudOperation, kind: CloudOperationKind, payload: CloudValue) throws -> CloudOperation {
    let id = UUID().uuidString.lowercased()
    return CloudOperation(v: 1, opId: id, originDevice: o.originDevice, domain: o.domain, entityId: o.entityId, revision: id, parents: [],
        kind: kind, source: o.source, createdAt: o.createdAt, payload: payload,
        payloadHash: try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(payload)))
}

/// Review 15 Nov 2026 (the lead's decisions 1 to 12 on lane L3). Each test fails on 97a13cb63.
extension SecretsDeleteRuleTests {
    /// Decision 4: a damaged removal, an `append` and a removal with an absurd date each end with a final "not
    /// applied" line, and the next record in the same batch still applies.
    @Test func damagedAppendAndAbsurdlyDatedRecordsEndWithAFinalLineAndTheNextRecordApplies() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f); try await p.seed()
        _ = try await p.ao.deleteItems([#require(await p.ao.items().first)], scope: .everywhere, by: f.actor())
        let genuine = try #require(await p.aa.changedSnapshot(cut: p.cut).operations.first { $0.kind == .archive })
        let tampered = try NativeRPCValue.parseJSON(CloudSecretsCanonical.encode(genuine.payload))
            .setting("tag", .string(Data(repeating: 7, count: 16).base64EncodedString()))
        let damaged = try secretsDeleteOperation(like: genuine, kind: .archive, payload: CloudValue(tampered))
        let removal = try #require(await p.ao.captureRemovals().first)
        let late = CloudSecretRemoval(sourceId: removal.sourceId, recordId: removal.recordId, domain: removal.domain, version: removal.version,
            fields: removal.fields, mac: removal.mac, macName: removal.macName, at: Int64.max - 1, removed: removal.removed, removedDigest: removal.removedDigest)
        let epoch = await p.a.content.state(storageClass: .secrets).epoch
        let envelope = try await p.a.content.seal(CloudSecretsCanonical.encode(late), blobId: UUID().uuidString.lowercased(), storageClass: .secrets,
            purpose: .secret, epoch: epoch, codec: .identity)
        let absurd = try secretsDeleteOperation(like: genuine, kind: .archive, payload: CloudValue(try NativeRPCValue.parseJSON(JSONEncoder().encode(envelope))))
        try await p.av.set("MADE_UP_SECOND", id: "two")
        let put = try #require(await p.aa.changedSnapshot(cut: p.cut).operations.first { $0.kind == .put && $0.entityId == "two" })
        let append = try secretsDeleteOperation(like: put, kind: .append, payload: put.payload)
        let receipt = try await p.deliver(.init(cut: p.cut, operations: [damaged, append, absurd, put], files: [], coverage: []), to: p.ba)
        #expect(receipt.results.filter { $0.status == .alreadyPresent && $0.reason == CloudSecretsLogicalAdapter.notAppliedWords }.count == 3)
        #expect(receipt.results.contains { $0.entityId == "two" && $0.status == .applied })
        #expect(await p.bv.capture().count == 2)
        #expect(try await p.bo.binGroups().isEmpty)
    }
    /// Kept from the review's list: a Cloud-scope removal never deletes the file on B; an unknown rule is refused.
    @Test func aCloudScopeRemovalNeverDeletesTheFileOnBAndAnUnknownRuleIsRefused() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=both"); _ = try await b.merge(#require(await a.capture().first))
        _ = try await a.deleteItems([f.item(a)], scope: .cloud, by: f.actor(.ai))
        let removal = try #require(await a.captureRemovals().first)
        var fields = removal.fields; fields[CloudDeleteTravel.rule] = "2"
        let unknown = CloudSecretRemoval(sourceId: removal.sourceId, recordId: removal.recordId, domain: removal.domain, version: removal.version,
            fields: fields, mac: removal.mac, macName: removal.macName, at: removal.at, removed: removal.removed, removedDigest: removal.removedDigest)
        await #expect(throws: (any Error).self) { try await b.validateRemoval(unknown) }
        #expect(try await b.mergeRemoval(removal) == .applied)
        #expect(f.read("B") == Data("MADE_UP=both".utf8))
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
    }
    /// Decision 2: a delete whose sealed save failed leaves no intent; a later by-hand delete is only a mark.
    @Test func aFailedSealedSaveLeavesNoIntentAndALaterHandDeleteStaysAMark() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=kept"); _ = try await a.capture()
        let item = try await f.item(a)
        await a.failSavesForTesting(true)
        await #expect(throws: (any Error).self) { try await a.deleteItems([item], scope: .everywhere, by: f.actor(.ai)) }
        await a.failSavesForTesting(false)
        #expect(f.read("A") == Data("MADE_UP=kept".utf8))
        try await f.absent("A", store: a)
        #expect(try await a.captureRemovals().isEmpty)
        #expect(try await a.notHere().first?.mark == .notOnThisMac)
        #expect(try await a.binGroups().isEmpty)
    }
    /// Decision 1: Put back on A is written on B; a new file made on A after a removal reaches B.
    @Test func putBackOnAIsWrittenOnBAndANewFileAfterARemovalReachesB() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=back"); _ = try await b.merge(#require(await a.capture().first))
        let group = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .applied)
        #expect(f.read("B") == nil)
        #expect(try await a.putBackGroup(group.id).count == 1)
        let record = try #require(await a.capture().first)
        let version = try #require(await a.versionForUpload(record))
        let removalGroup = try await a.republication(recordId: record.recordId)
        #expect(removalGroup == group.id)
        #expect(try await b.mergeVersioned(record, version: version, removalGroup: removalGroup) == .applied)
        #expect(f.read("B") == Data("MADE_UP=back".utf8))
        // Gone again, then a different file made on A: it reaches B like any arrival.
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .applied)
        try f.write("A", "MADE_UP=newer")
        _ = try await b.merge(#require(await a.capture().first))
        #expect(f.read("B") == Data("MADE_UP=newer".utf8))
        #expect(try await b.notHere().isEmpty)
    }
    /// Decision 1 through the real saved-passwords adapter: Put back on A travels sealed and is written on B.
    @Test func putBackTravelsThroughTheAdapterAndIsWrittenOnB() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f)
        let a = try await f.project("A"), b = try await f.project("B")
        let aa = CloudSecretsLogicalAdapter(store: a, content: p.a.content, policy: p.a.policy, deviceId: p.a.device.deviceId,
            keepConflicts: { _ in throw CloudFailure.unavailable }, retainIncomingConflict: { _ in })
        let ba = CloudSecretsLogicalAdapter(store: b, content: p.b.content, policy: p.b.policy, deviceId: p.b.device.deviceId,
            keepConflicts: { _ in throw CloudFailure.unavailable }, retainIncomingConflict: { _ in })
        try f.write("A", "MADE_UP_PUT_BACK_SECRET")
        _ = try await p.deliver(aa.snapshot(cut: p.cut), to: ba)
        let group = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor(.ai))
        _ = try await p.deliver(aa.changedSnapshot(cut: p.cut), to: ba)
        #expect(f.read("B") == nil)
        #expect(try await a.putBackGroup(group.id).count == 1)
        _ = try await p.deliver(aa.changedSnapshot(cut: p.cut), to: ba)
        #expect(f.read("B") == Data("MADE_UP_PUT_BACK_SECRET".utf8))
        #expect(try await a.binGroups().isEmpty)
    }
    /// Decision 3 (J-7): the newer bytes are written first; a failed write keeps the mark and the old bytes are never
    /// captured as a new version over the newer one.
    @Test func aFailedJ7WriteKeepsTheNewerVersion() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=old"); _ = try await b.merge(#require(await a.capture().first))
        try await f.absent("B", store: b)
        try f.write("A", "MADE_UP=new"); _ = try await b.merge(#require(await a.capture().first))
        try f.write("B", "MADE_UP=old")
        chmod(f.folder("B").path, 0o500)
        let first = (try? await b.capture()) ?? []
        chmod(f.folder("B").path, 0o700)
        let second = try await b.capture()
        let old = Data("MADE_UP=old".utf8).base64EncodedString()
        #expect(!(first + second).contains { $0.payload.raw["data"].string == old })
        #expect(f.read("B") == Data("MADE_UP=new".utf8))
        #expect(try await b.notHere().isEmpty)
    }
    /// Decision 5: a file that runs programs, carried inside a removal, is never written by Put back all or Bring back.
    @Test func aProgramRunningFileInsideARemovalIsNeverWrittenFromTheBin() async throws {
        for scope in CloudDeleteScope.allCases {
            let f = try SecretsDeleteFixture(); defer { f.close() }
            let a = try await f.project("A"), b = try await f.project("B")
            try f.write("A", "registry=https://registry.example.invalid/\n", path: ".npmrc"); _ = try await a.capture()
            let item = try await f.item(a, path: ".npmrc")
            try f.write("A", "script-shell=/made/up/shell\n", path: ".npmrc")
            let group = try await a.deleteItems([item], scope: scope, by: f.actor(.ai))
            #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .applied)
            if scope == .everywhere {
                #expect(try await b.putBackGroup(group.id).isEmpty)
            } else {
                let kept = try #require(await b.notHere().first?.item)
                #expect(try await b.bringBack([kept], to: .thisMac).isEmpty)
            }
            #expect(f.read("B", path: ".npmrc") == nil)
            #expect(try await b.binGroups().count == 1)
            let named = try #require(await b.status()).projects.flatMap(\.files)
            #expect(named.contains { $0.path == ".npmrc" && $0.state == BackendProjectSecretFilesWords.putBackPrograms })
        }
    }
    /// Decision 5: the arrival caps hold for a copy coming out of the Bin (here: the project already has 40 files).
    @Test func aRemovedFileOverTheCapsIsNeverWrittenByPutBack() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        for index in 0..<40 { try f.write("B", "MADE_UP=\(index)", path: ".env.\(index).local") }
        #expect(try await b.capture().count == 40)
        try f.write("A", "MADE_UP=one-too-many"); _ = try await a.capture()
        let group = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .applied)
        #expect(try await b.putBackGroup(group.id).isEmpty)
        #expect(f.read("B") == nil)
        #expect(try await b.binGroups().count == 1)
    }
    /// Decision 6: with the gate open an ordinary upload is byte for byte the old form (an old-form reader reads it),
    /// and opening the gate uploads nothing again.
    @Test func withTheGateOpenAnOrdinaryUploadIsTheOldFormAndOpeningTheGateUploadsNothingAgain() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f)
        try await p.av.set("MADE_UP_PACK_SECRET")
        let put = try #require(await p.aa.snapshot(cut: p.cut).operations.first)
        let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSecretsCanonical.encode(put.payload))
        let plain = try await p.b.content.open(envelope)
        let record = try #require(await p.av.capture().first)
        #expect(plain == (try CloudSecretsCanonical.encode(record)))
        #expect(try CloudWire.decode(CloudSecretRecord.self, from: plain) == record)
        f.clock.closeGate()
        let first = try await p.aa.changedSnapshot(cut: p.cut)
        let ids = first.operations.map(\.opId)
        #expect(ids.count == 1)
        try await p.aa.markPublished(first, receipt: .init(operationIds: ids, queued: ids.count, bytes: 0, savedAt: 0))
        await p.aa.confirmed(operationIds: Set(ids))
        f.clock.openGate()
        #expect(try await p.aa.changedSnapshot(cut: p.cut).operations.isEmpty)
    }
    /// Decision 8: a damaged Bin file never makes project secret files or saved passwords look locked.
    @Test func aDamagedBinIsSetAsideWithOneLineAndNothingLooksLocked() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=one"); try f.write("A", "MADE_UP=two", path: ".env.local"); _ = try await a.capture()
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        let bin = f.state("A").appendingPathComponent("sealed-bin")
        for name in try FileManager.default.contentsOfDirectory(atPath: bin.path) where name.hasSuffix(".sealed") {
            try Data("made-up damage".utf8).write(to: bin.appendingPathComponent(name))
        }
        let again = try await f.project("A")
        #expect(try await again.capture().count == 1)
        #expect(try await again.binGroups().isEmpty)
        #expect(try #require(await again.status()).binNotice == BackendProjectSecretFilesWords.binDamaged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path).contains { $0.contains(".sealed.unreadable-") })
    }
    /// Decision 9: a removal arriving while the saved passwords' store is locked is retried and applies after unlock.
    @Test func aRemovalArrivingWhileLockedIsRetriedAndAppliesAfterUnlock() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let av = SecretsDeleteValues(), bv = SecretsDeleteValues()
        try await av.set("MADE_UP_PASSWORD"); try await bv.set("MADE_UP_PASSWORD")
        let a = await f.saved("A", values: av), b = await f.saved("B", values: bv)
        _ = try await a.capture(); _ = try await b.capture()
        _ = try await a.deleteItems([#require(await a.items().first)], scope: .everywhere, by: f.actor(.ai))
        let removal = try #require(await a.captureRemovals().first)
        await bv.lock(true)
        await #expect(throws: CloudFailure.secretsLocked) { try await b.validateRemoval(removal) }
        await #expect(throws: CloudFailure.secretsLocked) { try await b.mergeRemoval(removal) }
        await bv.lock(false)
        #expect(try await b.mergeRemoval(removal) == .applied)
        #expect(await bv.capture().isEmpty)
        #expect(try await b.binGroups().count == 1)
    }
    /// Decision 10: removed here, and he puts the same file back himself: his new version, it syncs.
    @Test func hisOwnPutBackByHandSyncsAsHisNewVersion() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A")
        try f.write("A", "MADE_UP=mine"); _ = try await a.capture()
        let group = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor(.ai))
        try f.write("A", "MADE_UP=mine")
        let records = try await a.capture()
        #expect(records.count == 1)
        #expect(f.read("A") == Data("MADE_UP=mine".utf8))
        let record = try #require(records.first)
        #expect(try await a.versionForUpload(record) != nil)
        #expect(try await a.republication(recordId: record.recordId) == group.id)
        #expect(try await a.notHere().isEmpty)
    }
    /// Decision 11: an empty project folder is like a missing one: no marks, nothing placed.
    @Test func anEmptyProjectFolderMarksNothingAndTakesNothing() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=only"); let record = try #require(await a.capture().first)
        for name in try FileManager.default.contentsOfDirectory(atPath: f.folder("A").path) {
            try FileManager.default.removeItem(at: f.folder("A").appendingPathComponent(name))
        }
        _ = try await a.capture(); f.clock.advance(); _ = try await a.capture()
        #expect(try await a.notHere().isEmpty)
        #expect(try await a.captureRemovals().isEmpty)
        try FileManager.default.removeItem(at: f.folder("B").appendingPathComponent("README.md"))
        _ = try await b.merge(record)
        #expect(f.read("B") == nil)
        // The waiting file IS placed once the folder has content.
        try Data("made-up project\n".utf8).write(to: f.folder("B").appendingPathComponent("README.md"))
        _ = try await b.capture()
        #expect(f.read("B") == Data("MADE_UP=only".utf8))
    }
}

/// The final look at 483a474a8 (15 Nov 2026): saved passwords never come back by themselves; the Bin never empties early.
extension SecretsDeleteRuleTests {
    /// A removed password value reappearing in the store on one Mac (a restore, a conversion, an adopted copy) is not sent
    /// and stays removed on the other.
    @Test func aRemovedPasswordReappearingInTheStoreIsNotSentAndStaysRemovedElsewhere() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let p = try await SecretsDeletePacks(f); try await p.seed()
        _ = try await p.ao.deleteItems([#require(await p.ao.items().first)], scope: .everywhere, by: f.actor())
        _ = try await p.deliver(p.aa.changedSnapshot(cut: p.cut), to: p.ba)
        #expect(await p.bv.capture().isEmpty)
        try await p.av.set("MADE_UP_PACK_SECRET")
        let after = try await p.aa.changedSnapshot(cut: p.cut)
        #expect(!after.operations.contains { $0.kind == .put })
        _ = try await p.deliver(after, to: p.ba)
        #expect(await p.bv.capture().isEmpty)
        #expect(try await p.ao.capture().isEmpty)
    }
    /// This Mac's wall clock set forward deletes nothing early: the Bin ages by the service clock only.
    @Test func aWallClockSetForwardDeletesNothingEarly() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A", wallAhead: 2 * CloudBinGroup.retentionMilliseconds)
        try f.write("A", "MADE_UP=kept"); _ = try await a.capture()
        let group = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        f.clock.advance(); _ = try await a.capture()
        #expect(try await a.binGroups().first?.id == group.id)
    }
    /// A Mac that was off for weeks and applies an old removal late still keeps it 30 days in its own Bin.
    @Test func anOldRemovalAppliedLateKeepsThirtyDaysHere() async throws {
        let f = try SecretsDeleteFixture(); defer { f.close() }
        let a = try await f.project("A"), b = try await f.project("B")
        try f.write("A", "MADE_UP=late"); _ = try await b.merge(#require(await a.capture().first))
        _ = try await a.deleteItems([f.item(a)], scope: .everywhere, by: f.actor())
        let removal = try #require(await a.captureRemovals().first)
        let day: Int64 = 24 * 60 * 60 * 1000
        f.clock.advance(40 * day)
        #expect(try await b.mergeRemoval(removal) == .applied)
        #expect(try await b.binGroups().count == 1)
        f.clock.advance(25 * day); _ = try await b.capture()
        #expect(try await b.binGroups().count == 1)
        f.clock.advance(6 * day); _ = try await b.capture()
        #expect(try await b.binGroups().isEmpty)
    }
}
