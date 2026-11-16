import CryptoKit
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// UNBUILT L4 coverage. Every store is scratch, every delivery uses the real records adapter/merge/store.
/// No app, session, service, installed identity, provider configuration or Keychain is involved.
@Suite("Records delete rule", .serialized)
struct RecordsDeleteRuleTests {
    struct TaskSide {
        let mac: CloudLeanFixtureMac
        let store: BackendTaskStore
        let owner: BackendCloudKindsTasks
        let adapter: CloudBrainRecordAdapter
    }
    struct AgentSide {
        let mac: CloudLeanFixtureMac
        let config: BackendTaskConfiguration
        let owner: BackendCloudLeanAgents
        let adapter: CloudBrainRecordAdapter
    }
    struct ProjectSide {
        let mac: CloudLeanFixtureMac
        let registry: BackendPROJRegistry
        let owner: BackendCloudLeanProjects
        let adapter: CloudBrainRecordAdapter
    }
    static func mac(_ device: String, _ clock: CloudLeanFixture.Clock) throws -> CloudLeanFixtureMac {
        // The fixture's own scratch folder: the system temp folder sits behind a link (/var), and the records store
        // opens its database with no link allowed on the way.
        return try CloudLeanFixture.mac(device, clock: clock, root: CloudLeanFixture.folder())
    }
    static func tasks(_ device: String, _ clock: CloudLeanFixture.Clock, open: Bool = true) async throws -> TaskSide {
        let mac = try Self.mac(device, clock)
        let store = BackendTaskStore(persistence: try .init(directory: mac.root.appendingPathComponent("remote"), ownership: .exclusive))
        try await store.start()
        let owner = BackendCloudKindsTasks(store: store, projects: { [] })
        owner.configureDeleteRule(gate: { open }, macNames: { $0 == CloudLeanFixture.deviceA ? "Mac mini" : "MacBook Pro" })
        return .init(mac: mac, store: store, owner: owner, adapter: try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins))
    }
    static func agents(_ device: String, _ clock: CloudLeanFixture.Clock, open: Bool = true,
                       witness: CloudDeleteWitnessSlot = .init(), now: @escaping @Sendable () -> Date = { Date() }) async throws -> AgentSide {
        let mac = try Self.mac(device, clock)
        let config = try BackendTaskConfiguration(persistence: .init(directory: mac.root.appendingPathComponent("remote"), ownership: .exclusive))
        try await config.start()
        let owner = BackendCloudLeanAgents(config: config, historyFile: mac.root.appendingPathComponent("names.json"),
            fullAccess: { true }, projects: { [] }, witness: witness, now: now)
        owner.configureDeleteRule(gate: { open }, macNames: { $0 == CloudLeanFixture.deviceA ? "Mac mini" : "MacBook Pro" })
        return .init(mac: mac, config: config, owner: owner, adapter: try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins))
    }
    static func projects(_ device: String, _ clock: CloudLeanFixture.Clock, open: Bool = true) throws -> ProjectSide {
        let mac = try Self.mac(device, clock)
        let registry = BackendPROJRegistry(fileURL: mac.root.appendingPathComponent("projects.json"))
        // The registry's own entry-only writers (lead decision 3), exactly as the integrator connects them.
        let owner = BackendCloudLeanProjects(registry: registry, fullAccess: { true },
            removeEntry: { id in try await registry.cloudDeleteEntryOnly(id) },
            restoreEntry: { project in try await registry.cloudPutBackEntryOnly(project) })
        owner.configureDeleteRule(gate: { open }, macNames: { $0 == CloudLeanFixture.deviceA ? "Mac mini" : "MacBook Pro" })
        return .init(mac: mac, registry: registry, owner: owner, adapter: try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins))
    }
    static func task(_ id: String) -> NativeRPCValue {
        CloudKindsTests.task(id, title: "Review the patch").setting("sessionId", .null).setting("process", .string("stopped"))
    }
    static func agent(_ id: String = "reviewer") -> NativeRPCValue {
        CloudLeanAgentsTests.agent(id, "Reviewer", [("instructions", .string("Read every changed line."))])
    }
    static func actor(_ mac: CloudLeanFixtureMac, _ clock: CloudLeanFixture.Clock, by: CloudDeleteBy = .ai) -> CloudDeleteActor {
        .init(by: by, mac: mac.device, macName: mac.device == CloudLeanFixture.deviceA ? "Mac mini" : "MacBook Pro",
            session: "Night work", agent: "Reviewer", at: clock.read(), group: UUID().uuidString.lowercased())
    }
    static func item(_ kind: String, _ id: String) -> CloudDeleteItem { .init(id: kind + ":" + id, kind: kind, name: "Review") }

    @Test func aiTaskDeleteIsTheExistingTrashOnBothMacsAndIgnoresCloudScope() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.tasks(CloudLeanFixture.deviceA, clock), b = try await Self.tasks(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.store.put(Self.task("one"))
        let firstA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(firstA.sent, from: a.mac.device, to: b.adapter)
        let who = Self.actor(a.mac, clock)
        let group = try await a.owner.deleteItems([Self.item("task", "local:one")], scope: .cloud, by: who)
        #expect(group.id == who.group && group.count == 1)
        let sent = try await CloudLeanFixture.sync(firstA.activation, on: a.mac)
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.adapter)
        for store in [a.store, b.store] {
            #expect(try await store.byID("local:one") == nil)
            let rows = try await store.inTrash()
            #expect(rows.count == 1)
            #expect(rows.first?.value["deletedBy"].string == "ai")
            #expect(rows.first?.value["deletedOn"].string == a.mac.device)
            #expect(rows.first?.value["deletedGroup"].string == who.group)
            #expect(rows.first?.value["deletedScope"].string == "everywhere")
            #expect(rows.first?.value["deletedSession"].string == "Night work")
            #expect(rows.first?.value["deletedAgent"].string == "Reviewer")
        }
        let groups = try await b.owner.binGroups()
        #expect(groups.first?.macName == "Mac mini" && groups.first?.agent == "Reviewer")
    }

    @Test func taskDeleteForGoodTravelsAndAnArrivingPurgeApplies() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.tasks(CloudLeanFixture.deviceA, clock), b = try await Self.tasks(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.store.put(Self.task("one"))
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        _ = try await a.owner.deleteItems([Self.item("task", "local:one")], scope: .everywhere, by: Self.actor(a.mac, clock))
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(first.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        try await a.owner.deleteForGood([Self.item("task", "local:one")])
        let purge = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        #expect(purge.contains { $0.payload.raw["fields"][CloudBrainMerge.existsField].bool == false })
        try await CloudLeanFixture.deliver(purge, from: a.mac.device, to: b.adapter)
        #expect(try await a.store.inTrash().isEmpty)
        #expect(try await b.store.inTrash().isEmpty)
    }

    @Test func taskPutBackAllRestoresOneNamedGroupOnBothMacs() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.tasks(CloudLeanFixture.deviceA, clock), b = try await Self.tasks(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        for id in ["one", "two"] { _ = try await a.store.put(Self.task(id)) }
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        let who = Self.actor(a.mac, clock, by: .person)
        _ = try await a.owner.deleteItems([Self.item("task", "local:one"), Self.item("task", "local:two")], scope: .everywhere, by: who)
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(first.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        let restored = try await a.owner.putBackGroup(who.group)
        #expect(restored.count == 2)
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(first.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        #expect(try await b.store.all().count == 2)
        #expect(try await b.owner.binGroups().isEmpty)
    }

    @Test func aiAgentDeleteBinsTheRowAndTextOnBothMacsAndIgnoresCloudScope() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock), b = try await Self.agents(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        let who = Self.actor(a.mac, clock)
        _ = try await a.owner.deleteItems([Self.item("agent", "reviewer")], scope: .cloud, by: who)
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(first.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        for side in [a, b] {
            #expect(try await side.config.agent("reviewer") == nil)
            let rows = try side.config.recordDeletes.binRows(kind: "agent")
            #expect(rows.count == 1 && rows.first?.item.id == "agent:reviewer")
            #expect(rows.first?.value["row"]["name"].string == "Reviewer")
            #expect(rows.first?.value["text"].string == "Read every changed line.")
            #expect(rows.first?.actor.by == .ai && rows.first?.actor.group == who.group)
        }
        #expect(try await b.owner.putBackGroup(who.group).count == 1)
        #expect(try await b.config.agent("reviewer")?["instructions"].string == "Read every changed line.")
    }

    @Test func aConcurrentAgentEditWinsTheRemovalByAncestry() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock), b = try await Self.agents(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        let firstA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let firstB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(firstA.sent, from: a.mac.device, to: b.adapter)
        _ = try await a.owner.deleteItems([Self.item("agent", "reviewer")], scope: .everywhere, by: Self.actor(a.mac, clock))
        let removal = try await CloudLeanFixture.sync(firstA.activation, on: a.mac)
        // B has not seen A's removal: this is an edit on the original parent, not a timestamp-based restore.
        _ = try await b.config.saveAgent(Self.agent().setting("role", .string("Keeps the edit")))
        let edit = try await CloudLeanFixture.sync(firstB.activation, on: b.mac)
        try await CloudLeanFixture.deliver(edit, from: b.mac.device, to: a.adapter)
        try await CloudLeanFixture.deliver(removal, from: a.mac.device, to: b.adapter)
        #expect(try await a.config.agent("reviewer")?["role"].string == "Keeps the edit")
        #expect(try await b.config.agent("reviewer")?["role"].string == "Keeps the edit")
        #expect(try await a.adapter.listing().waiting.isEmpty)
        #expect(try await a.config.agent("reviewer")?["instructions"].string == "Read every changed line.")
        #expect(try await b.config.agent("reviewer")?["instructions"].string == "Read every changed line.")
    }

    @Test func anUnintendedMissingAgentRowDoesNotTravel() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        _ = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let result = try await a.owner.cloudMissing(entity: "agent:reviewer", last: Self.agent())
        if case .keep = result {} else { Issue.record("Absence without intent must never travel") }
    }

    struct Witness: CloudDeleteWitness {
        let answer: CloudDeleteWitnessAnswer
        func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer { answer }
    }
    @Test func anUnknownInstructionRemovalIsMarkedAndSurvivesSync() async throws {
        let time = CloudLeanFixture.Box(Date(timeIntervalSince1970: 1_760_000_000)), clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock, now: { time.value })
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let path = try #require(try await a.config.cloudLeanInstructionURL("reviewer"))
        try FileManager.default.removeItem(at: path)
        #expect(try await CloudLeanFixture.sync(first.activation, on: a.mac).isEmpty)
        time.value = time.value.addingTimeInterval(4)
        #expect(try await CloudLeanFixture.sync(first.activation, on: a.mac).isEmpty)
        let marks = try await a.owner.notHere()
        #expect(marks.count == 1 && marks.first?.mark == .notOnThisMac)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(try await CloudLeanFixture.sync(first.activation, on: a.mac).isEmpty)
        _ = try await a.owner.bringBack(marks.map(\.item), to: .thisMac)
        #expect(FileManager.default.fileExists(atPath: path.path))
        #expect(try await a.owner.notHere().isEmpty)
    }

    @Test func aWitnessedAIInstructionDeleteTravelsIntoBothKeeperBins() async throws {
        let clock = CloudLeanFixture.Clock(), time = CloudLeanFixture.Box(Date(timeIntervalSince1970: 1_760_000_000))
        let slot = CloudDeleteWitnessSlot(), group = UUID().uuidString.lowercased()
        #expect(slot.installOnce(Witness(answer: .ai(session: "Night work", agent: "Reviewer", command: time.value, group: group))))
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock, witness: slot, now: { time.value })
        let b = try await Self.agents(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        let path = try #require(try await a.config.cloudLeanInstructionURL("reviewer"))
        try FileManager.default.removeItem(at: path)
        _ = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        time.value = time.value.addingTimeInterval(4)
        let sent = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.adapter)
        for side in [a, b] {
            let rows = try side.config.recordDeletes.binRows(kind: "agent")
            #expect(rows.first?.item.id == "instruction:reviewer.md")
            #expect(rows.first?.actor.by == .ai && rows.first?.actor.group == group)
            #expect(try await side.config.agent("reviewer") != nil)
        }
    }

    @Test func aMissingInstructionRootIsNeverAWitnessedDelete() async throws {
        let clock = CloudLeanFixture.Clock(), time = CloudLeanFixture.Box(Date(timeIntervalSince1970: 1_760_000_000))
        let slot = CloudDeleteWitnessSlot()
        #expect(slot.installOnce(Witness(answer: .ai(session: "Night work", agent: nil, command: time.value, group: UUID().uuidString))))
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock, witness: slot, now: { time.value })
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let path = try #require(try await a.config.cloudLeanInstructionURL("reviewer"))
        try FileManager.default.moveItem(at: path.deletingLastPathComponent(), to: a.mac.root.appendingPathComponent("unplugged"))
        time.value = time.value.addingTimeInterval(10)
        #expect(try await CloudLeanFixture.sync(first.activation, on: a.mac).isEmpty)
        time.value = time.value.addingTimeInterval(10)
        #expect(try await CloudLeanFixture.sync(first.activation, on: a.mac).isEmpty)
        #expect(try await a.owner.notHere().isEmpty)
        #expect(try await a.owner.binGroups().isEmpty)
    }

    @Test func projectEverywhereRemovesOnlyEntriesAndNeverTouchesFolderFiles() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.projects(CloudLeanFixture.deviceA, clock), b = try Self.projects(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        for side in [a, b] {
            let folder = side.mac.root.appendingPathComponent("own-project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("User source stays".utf8).write(to: folder.appendingPathComponent("code.swift"))
            _ = try await side.registry.save(PROJProject(id: "review", name: "Review", folders: [folder.path]))
        }
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        _ = try await a.owner.deleteItems([Self.item("project", "review")], scope: .everywhere, by: Self.actor(a.mac, clock))
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(first.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        for side in [a, b] {
            #expect(try await side.registry.projects().allSatisfy { $0.id != "review" })
            #expect(try Data(contentsOf: side.mac.root.appendingPathComponent("own-project/code.swift")) == Data("User source stays".utf8))
            #expect(try await side.owner.binGroups().first?.count == 1)
        }
    }

    @Test func projectCloudKeepsEachEntryOnlyOnItsOwnMacAndCanBeRepublished() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.projects(CloudLeanFixture.deviceA, clock), b = try Self.projects(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "review", name: "Review"))
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let startedB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        _ = try await a.owner.deleteItems([Self.item("project", "review")], scope: .cloud, by: Self.actor(a.mac, clock, by: .person))
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(first.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        for side in [a, b] {
            #expect(try await side.registry.projects().contains { $0.id == "review" })
            #expect(try await side.owner.notHere().first?.mark == .onlyOnThisMac)
        }
        #expect(try await CloudLeanFixture.sync(startedB.activation, on: b.mac).isEmpty)
        _ = try await b.owner.bringBack([Self.item("project", "review")], to: .cloud)
        let put = try await CloudLeanFixture.sync(startedB.activation, on: b.mac)
        try await CloudLeanFixture.deliver(put, from: b.mac.device, to: a.adapter)
        #expect(try await b.owner.notHere().isEmpty)
        #expect(try await a.owner.notHere().isEmpty)
    }

    @Test func removeFromThisMacSendsNothingAndBringBackRestoresTheFolderMap() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.projects(CloudLeanFixture.deviceA, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        let folder = a.mac.root.appendingPathComponent("untouched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = try await a.registry.save(PROJProject(id: "review", name: "Review", folders: [folder.path]))
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        try await a.owner.removeFromThisMac("review")
        #expect(try await CloudLeanFixture.sync(first.activation, on: a.mac).isEmpty)
        #expect(try await a.owner.notHere().first?.mark == .notOnThisMac)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        _ = try await a.owner.bringBack([Self.item("project", "review")], to: .thisMac)
        #expect(try await a.registry.projects().first(where: { $0.id == "review" })?.folders == [folder.path])
        #expect(try await CloudLeanFixture.sync(first.activation, on: a.mac).isEmpty)
    }

    @Test func closedGateUsesOnlyV1FieldsAndRefusesProjectCloud() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.tasks(CloudLeanFixture.deviceA, clock, open: false)
        let p = try Self.projects(CloudLeanFixture.deviceB, clock, open: false)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: p.mac.root) }
        _ = try await a.store.put(Self.task("one"))
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await a.owner.deleteItems([Self.item("task", "local:one")], scope: .cloud, by: Self.actor(a.mac, clock))
        let sent = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        for op in first.sent + sent {
            let version = try CloudBrainMergeVersion(payload: op.payload.raw)
            #expect(version.minTable == 1)
            #expect(CloudBrainMergeTables.recordDeleteFields.allSatisfy { version.fields[$0] == nil })
            #expect(CloudSyncBytes.hash(try CloudSyncCanonical.encode(op.payload)) == op.payloadHash)
        }
        _ = try await p.registry.save(PROJProject(id: "review", name: "Review"))
        do {
            _ = try await p.owner.deleteItems([Self.item("project", "review")], scope: .cloud, by: Self.actor(p.mac, clock))
            Issue.record("Cloud scope must refuse while an older Mac exists")
        } catch let error as NativeRPCError { #expect(error.message == CloudDeleteWords.cloudNeedsUpdatedMacs) }
        #expect(try await p.registry.projects().contains { $0.id == "review" })
    }

    @Test func oldRecordCanonicalBytesAndSignatureStillVerify() throws {
        // The v1 encoder/schema from installed 5e1ecbae2: minTable, payload hash and signature coverage are unchanged.
        let stamp = CloudBrainMergeStamp(time: 1_760_000_000_000, op: "v1-record")
        let version = CloudBrainMergeVersion(table: 1, minTable: 1, baseline: false,
            fields: ["id": .string("reviewer"), "name": .string("Reviewer"), CloudBrainMerge.existsField: .bool(true)],
            stamps: ["id": stamp, "name": stamp, CloudBrainMerge.existsField: stamp])
        let bytes = try CloudSyncCanonical.encode(CloudValue(version.payload()))
        let redecoded = try CloudBrainMergeVersion(payload: NativeRPCValue.parseJSON(bytes))
        #expect(try CloudSyncCanonical.encode(CloudValue(redecoded.payload())) == bytes)
        let key = P256.Signing.PrivateKey()
        let descriptor = CloudSegmentDescriptor(segmentId: "old-segment", requestId: "old-request", storageClass: .brain, purpose: .brain,
            domains: ["agents"], keyEpoch: 1, sha256: CloudSyncBytes.hash(bytes), bytes: Int64(bytes.count), opCount: 1, format: "v1", signature: "")
        let signed = try descriptor.syncSigningBytes(subject: "fixture-account")
        let signature = try key.signature(for: signed)
        #expect(key.publicKey.isValidSignature(signature, for: try descriptor.syncSigningBytes(subject: "fixture-account")))
        #expect(redecoded.minTable <= BackendCloudLeanAgents.agentKind.table.version)
        #expect(CloudBrainMergeTables.agent.version == 1)
    }

    @Test func malformedNewRemovalIsRefusedRatherThanTreatedAsEverywhere() throws {
        do {
            try RecordsDeleteLedger.validate(.object([.init("deletedScope", .string("somewhere"))]))
            Issue.record("A malformed new removal must not delete an entry")
        } catch is CloudRecordRefusal {}
    }

    @Test func retentionIsThirtyDaysAndTasksKeepTheirExistingTrash() {
        #expect(BackendTaskStore.trashDays == 30)
        #expect(CloudBinGroup.retentionMilliseconds == 30 * 86_400_000)
    }
    @Test func oldFormatAgentRemovalAppliesIntoTheKeeperWithOlderVersionNames() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock, open: false)
        let b = try await Self.agents(CloudLeanFixture.deviceB, clock, open: false)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        _ = try await a.owner.deleteItems([Self.item("agent", "reviewer")], scope: .cloud, by: Self.actor(a.mac, clock))
        let sent = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        for op in sent {
            let version = try CloudBrainMergeVersion(payload: op.payload.raw)
            #expect(version.minTable == 1)
            #expect(CloudBrainMergeTables.recordDeleteFields.allSatisfy { version.fields[$0] == nil })
        }
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.adapter)
        #expect(try await b.config.agent("reviewer") == nil)
        let groups = try await b.owner.binGroups()
        #expect(groups.first?.era == .olderVersion)
        #expect(groups.first?.macName == "Mac mini")
        #expect(try b.config.recordDeletes.binRows(kind: "agent").first?.value["text"].string == "Read every changed line.")
    }

    @Test func anAgentCreatedAndDeletedBeforeItsFirstCaptureStillTravelsAsADeletion() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock), b = try await Self.agents(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        _ = try await a.owner.deleteItems([Self.item("agent", "reviewer")], scope: .everywhere, by: Self.actor(a.mac, clock))
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        #expect(try await b.config.agent("reviewer") == nil)
        #expect(try await b.owner.binGroups().first?.count == 1)
    }

    @Test func everywhereAfterProjectCloudAlsoRemovesTheRetainedEntries() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try Self.projects(CloudLeanFixture.deviceA, clock), b = try Self.projects(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.registry.save(PROJProject(id: "review", name: "Review"))
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        _ = try await a.owner.deleteItems([Self.item("project", "review")], scope: .cloud, by: Self.actor(a.mac, clock))
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(first.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        _ = try await a.owner.deleteItems([Self.item("project", "review")], scope: .everywhere, by: Self.actor(a.mac, clock))
        let everywhere = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        #expect(!everywhere.isEmpty)
        try await CloudLeanFixture.deliver(everywhere, from: a.mac.device, to: b.adapter)
        #expect(try await b.registry.projects().allSatisfy { $0.id != "review" })
        #expect(try await b.owner.notHere().isEmpty)
    }

    @Test func aMarkedInstructionReappearingAsAnOlderVersionUsesTheNewestWithoutUploadingTheOldText() async throws {
        let clock = CloudLeanFixture.Clock(), time = CloudLeanFixture.Box(Date(timeIntervalSince1970: 1_760_000_000))
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock, now: { time.value })
        let b = try await Self.agents(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        let firstA = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        let firstB = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(firstA.sent, from: a.mac.device, to: b.adapter)
        let path = try #require(try await a.config.cloudLeanInstructionURL("reviewer"))
        try FileManager.default.removeItem(at: path)
        _ = try await CloudLeanFixture.sync(firstA.activation, on: a.mac)
        time.value = time.value.addingTimeInterval(4)
        _ = try await CloudLeanFixture.sync(firstA.activation, on: a.mac)
        _ = try await b.config.saveAgent(Self.agent().setting("instructions", .string("Keep the newest instruction.")))
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(firstB.activation, on: b.mac), from: b.mac.device, to: a.adapter)
        #expect(!FileManager.default.fileExists(atPath: path.path))
        try Data("Read every changed line.\n".utf8).write(to: path)
        let returned = try await CloudLeanFixture.sync(firstA.activation, on: a.mac)
        #expect(returned.isEmpty)
        #expect(try String(contentsOf: path, encoding: .utf8) == "Keep the newest instruction.\n")
        #expect(try await a.owner.notHere().isEmpty)
    }

    @Test func agentDeleteForGoodOnlyEmptiesTheExistingKeeperItem() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        _ = try await a.owner.deleteItems([Self.item("agent", "reviewer")], scope: .everywhere, by: Self.actor(a.mac, clock))
        #expect(try await a.owner.binGroups().count == 1)
        try await a.owner.deleteForGood([Self.item("agent", "reviewer")])
        #expect(try await a.owner.binGroups().isEmpty)
        #expect(try await a.config.agent("reviewer") == nil)
    }

    @Test func anOfflineAgentBinMovesToTheExistingAccountKeeperOnceAfterASafetyCopy() async throws {
        let clock = CloudLeanFixture.Clock()
        let mac = try Self.mac(CloudLeanFixture.deviceA, clock)
        defer { try? FileManager.default.removeItem(at: mac.root) }
        let remote = mac.root.appendingPathComponent("remote")
        let config = try BackendTaskConfiguration(persistence: .init(directory: remote, ownership: .exclusive))
        try await config.start()
        _ = try await config.saveAgent(Self.agent())
        try await config.removeAgent("reviewer", deletedBy: Self.actor(mac, clock))
        let owner = BackendCloudLeanAgents(config: config)
        _ = try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins)
        #expect(try await owner.binGroups().count == 1)
        let canonical = mac.root.appendingPathComponent("cloud/" + mac.subject + "/archive/versions/versions.sqlite")
        #expect(FileManager.default.fileExists(atPath: canonical.path))
        let archive = remote.appendingPathComponent("archive")
        let copies = try FileManager.default.contentsOfDirectory(atPath: archive.path).filter { $0.hasPrefix("versions-before-records-") }
        #expect(copies.count == 1)
        try await owner.deleteForGood([Self.item("agent", "reviewer")])
        _ = try owner.adapter(store: mac.store, account: mac.account, origins: mac.origins)
        #expect(try await owner.binGroups().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.path).filter { $0.hasPrefix("versions-before-records-") }.count == 1)
    }

    // MARK: after the review (lead decisions 1 to 6)

    /// Decision 1 (review A1): a delete that lands while a capture pass runs is never read as a put back.
    @Test func aDeleteDuringASyncPassKeepsItsBinCopyAndTravels() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock), b = try await Self.agents(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        let who = Self.actor(a.mac, clock, by: .person), fired = CloudLeanFixture.Box(false), config = a.config
        await a.owner.setAfterRosterRead {
            guard !fired.value else { return }
            fired.value = true
            try? await config.removeAgent("reviewer", deletedBy: who)
        }
        let during = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        await a.owner.setAfterRosterRead(nil)
        #expect(fired.value)
        #expect(try await a.config.agent("reviewer") == nil)
        #expect(try a.config.recordDeletes.binRows(kind: "agent").first { $0.item.id == "agent:reviewer" }?.actor.group == who.group)
        let after = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        #expect((during + after).contains { $0.entityId == "agent:reviewer" && $0.payload.raw["fields"][CloudBrainMerge.existsField].bool == false })
        try await CloudLeanFixture.deliver(during + after, from: a.mac.device, to: b.adapter)
        #expect(try await b.config.agent("reviewer") == nil)
        #expect(try b.config.recordDeletes.binRows(kind: "agent").first { $0.item.id == "agent:reviewer" }?.actor.group == who.group)
        // The Bin copy is still there on the deleting Mac after the removal was sent.
        #expect(try a.config.recordDeletes.binRows(kind: "agent").contains { $0.item.id == "agent:reviewer" })
    }

    /// Decision 2 (review A2): Trash ageing is each Mac's own, by the service clock only, and never travels.
    @Test func aClockAheadAgesOnlyItsOwnTrashAndAgeingWaitsForTheServiceClock() async throws {
        let clock = CloudLeanFixture.Clock(), ahead = CloudLeanFixture.Box(Int64(0))
        let a = try await Self.tasks(CloudLeanFixture.deviceA, clock), b = try await Self.tasks(CloudLeanFixture.deviceB, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root); try? FileManager.default.removeItem(at: b.mac.root) }
        a.owner.configureDeleteRule(gate: { true }, macNames: { $0 == CloudLeanFixture.deviceA ? "Mac mini" : "MacBook Pro" },
            serviceTime: { clock.read() + ahead.value })
        _ = try await a.store.put(Self.task("one"))
        let first = try await CloudLeanFixture.start([a.adapter], on: a.mac)
        _ = try await CloudLeanFixture.start([b.adapter], on: b.mac)
        try await CloudLeanFixture.deliver(first.sent, from: a.mac.device, to: b.adapter)
        _ = try await a.owner.deleteItems([Self.item("task", "local:one")], scope: .everywhere, by: Self.actor(a.mac, clock, by: .person))
        try await CloudLeanFixture.deliver(CloudLeanFixture.sync(first.activation, on: a.mac), from: a.mac.device, to: b.adapter)
        #expect(try await b.store.inTrash().count == 1)
        // Mac A's clock runs 31 days fast: it ages its OWN Trash only.
        ahead.value = 31 * 86_400_000
        _ = try await a.store.put(Self.task("two"))
        #expect(try await a.store.inTrash().isEmpty)
        let sent = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        #expect(!sent.contains { $0.entityId == "task:local:one" && $0.payload.raw["fields"][CloudBrainMerge.existsField].bool == false })
        try await CloudLeanFixture.deliver(sent, from: a.mac.device, to: b.adapter)
        #expect(try await b.store.inTrash().map(\.id) == ["local:one"])
        // Mac B has no service clock yet: nothing ages, although its own clock is far past the 30 days.
        _ = try await b.store.put(Self.task("three"))
        #expect(try await b.store.inTrash().map(\.id) == ["local:one"])
        // The aged copy is not placed back into Mac A's Trash by a later pass.
        _ = try await CloudLeanFixture.sync(first.activation, on: a.mac)
        #expect(try await a.store.inTrash().isEmpty)
    }

    /// Decision 3: the registry's entry writers add or remove the list ENTRY only.
    @Test func theRegistryEntryWritersTouchOnlyTheEntry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("records-delete-registry-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("scratch-project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        let files = [folder.appendingPathComponent("notes.md"), folder.appendingPathComponent("src/main.swift")]
        try Data("His own notes".utf8).write(to: files[0])
        try Data("print(1)".utf8).write(to: files[1])
        // A made-up running session working in that folder, as a session list would hold it.
        let sessions = root.appendingPathComponent("sessions.json")
        try Data(#"{"sessions":[{"id":"made-up-session","title":"Night work","cwd":"\#(folder.path)","status":"running"}]}"#.utf8).write(to: sessions)
        func bytes() throws -> [Data] { try (files + [sessions]).map { try Data(contentsOf: $0) } }
        let before = try bytes()
        let notices = CloudLeanFixture.Counter()
        let registry = BackendPROJRegistry(fileURL: root.appendingPathComponent("projects.json"), changed: { _ in notices.bump() })
        let project = PROJProject(id: "review", name: "Review", folders: [folder.path])
        _ = try await registry.save(project)
        _ = try await registry.setLead(projectID: "review", lead: "session:made-up-session", leadName: "Night work")
        let kept = try #require(try await registry.projects().first { $0.id == "review" })
        let heard = notices.count

        try await registry.cloudDeleteEntryOnly("review")
        #expect(try await registry.projects().allSatisfy { $0.id != "review" })
        #expect(try bytes() == before)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(notices.count == heard)

        try await registry.cloudPutBackEntryOnly(kept)
        let back = try #require(try await registry.projects().first { $0.id == "review" })
        #expect(!back.folders.isEmpty && back.folders == kept.folders)
        #expect(back.lead == "session:made-up-session")
        #expect(try bytes() == before)
        #expect(notices.count == heard)
        do {
            try await registry.cloudDeleteEntryOnly(PROJProjects.independentID)
            Issue.record("Independent is never removed")
        } catch {}
    }

    /// Decision 4 (review A6): Put back restores what the delete cleared; Put back all continues past a failure.
    @Test func anAgentPutBackGetsItsLinksBackAndPutBackAllContinuesPastAFailure() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.agents(CloudLeanFixture.deviceA, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        _ = try await a.config.saveAgent(Self.agent())
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("writer", "Writer", [("reportsTo", .string("reviewer"))]))
        _ = try await a.config.saveAgent(CloudLeanAgentsTests.agent("planner", "Planner", [("instructions", .string("Plan the night."))]))
        _ = try await a.config.saveConnection("k1", input: .object([.init("identities", .object([.init("u-reviewer", .string("reviewer"))]))]))
        let who = Self.actor(a.mac, clock)
        _ = try await a.owner.deleteItems([Self.item("agent", "reviewer"), Self.item("agent", "planner")], scope: .everywhere, by: who)
        #expect(try await a.config.agent("writer")?["reportsTo"].isNullish == true)
        #expect(try await a.config.connection("k1")?["identities"]["u-reviewer"].isNullish == true)
        // Planner's instructions cannot be written back (a folder now stands where its file was): that item fails.
        let blocked = try #require(try await a.config.cloudLeanInstructionURL("planner"))
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)

        let answer = try await a.owner.putBackAll(who.group)
        #expect(answer.restored.map(\.name) == ["Reviewer"])
        #expect(answer.notRestored.map(\.name) == ["Planner"])
        #expect(answer.line == "Put back: Reviewer. Not put back: Planner.")
        #expect(try await a.config.agent("reviewer") != nil)
        #expect(try await a.config.agent("writer")?["reportsTo"].string == "reviewer")
        #expect(try await a.config.connection("k1")?["identities"]["u-reviewer"].string == "reviewer")
        // The failed item stays in the Bin for another try.
        #expect(try await a.owner.binGroups().first { $0.id == who.group }?.items.map(\.name) == ["Planner"])
    }

    /// Decision 6 (review A8): one Trash row that does not read never hides the rest.
    @Test func anUnreadableTrashRowIsLeftOutAndTheRestShows() async throws {
        let clock = CloudLeanFixture.Clock()
        let a = try await Self.tasks(CloudLeanFixture.deviceA, clock)
        defer { try? FileManager.default.removeItem(at: a.mac.root) }
        for id in ["one", "two"] { _ = try await a.store.put(Self.task(id)) }
        let good = Self.actor(a.mac, clock), bad = Self.actor(a.mac, clock)
        _ = try await a.owner.deleteItems([Self.item("task", "local:one")], scope: .everywhere, by: good)
        _ = try await a.owner.deleteItems([Self.item("task", "local:two")], scope: .everywhere, by: bad)
        let row = try #require(try await a.store.inTrash().first { $0.id == "local:two" })
        try await a.store.cloudKindsWrite(row.value.setting("deletedBy", .string("someone else")), trash: true)
        let groups = try await a.owner.binGroups()
        #expect(groups.map(\.id) == [good.group])
        #expect(groups.first?.items.map(\.id) == ["task:local:one"])
    }

}
