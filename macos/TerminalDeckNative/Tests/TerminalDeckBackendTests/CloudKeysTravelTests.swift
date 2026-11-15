import CryptoKit
import Darwin
import Foundation
import Testing
@testable import TerminalDeckBackend
@testable import TerminalDeckNativeCore

/// Keys travel (Security seat, 15 Nov 2026): API keys, connected-task tokens, Receiver secrets and MCP servers ride the
/// saved-passwords engine from Mac A to Mac B, are usable there, are one item when both hold the same, are both kept when
/// they differ, follow the delete rule, and never show a value. Scratch stores only: no Keychain, no real settings.
@Suite struct CloudKeysTravelTests {
    static let keyA = "sk-made-up-key-aaaaaaaaaaaaaaaaaaaaaaaa"
    static let keyB = "sk-made-up-key-bbbbbbbbbbbbbbbbbbbbbbbb"
    static let idOne = "api-key-111111111111111111111111"
    static let idTwo = "api-key-222222222222222222222222"

    @Test func anAPIKeyTravelsAndItsAccountWorksOnTheOtherMac() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        let a = f.apiStore(f.apiA, "A"), b = f.apiStore(f.apiB, "B")
        let record = try #require(await a.capture().first)
        try await b.validate(record)
        #expect(try await b.merge(record) == .applied)
        #expect(try await b.verify(record, outcome: .applied))
        let made = try #require(await f.apiB.account(Self.idOne))
        #expect(made.name == "Work Claude" && made.key == Self.keyA && made.record.kind == .anthropic)
        #expect(try await b.merge(record) == .alreadyPresent)
    }

    @Test func theSameKeyOnBothMacsIsOneAccountAndOneIdInCloud() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        try await f.apiB.add(Self.idTwo, name: "Claude at home", key: Self.keyA)
        let a = f.apiStore(f.apiA, "A"), b = f.apiStore(f.apiB, "B")
        let record = try #require(await a.capture().first)
        #expect(try await b.merge(record) == .alreadyPresent)
        #expect(await f.apiB.count() == 1)
        // B now names its one account by the smaller id, so Cloud holds it once.
        #expect(try await b.capture().map(\.recordId) == [Self.idOne])
    }

    @Test func aDifferentKeyUnderTheSameAccountKeepsBothNamedByTheMac() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        try await f.apiB.add(Self.idOne, name: "Work Claude", key: Self.keyB)
        let a = f.apiStore(f.apiA, "A"), b = f.apiStore(f.apiB, "B")
        let record = try #require(await a.capture().first)
        #expect(try await b.merge(record) == .keptBoth)
        #expect(try await b.verify(record, outcome: .keptBoth))
        #expect(await f.apiB.account(Self.idOne)?.key == Self.keyB)   // his own is never replaced
        let all = await f.apiB.all()
        #expect(all.count == 2)
        #expect(all.contains { $0.name == "Work Claude (Mac A)" && $0.key == Self.keyA })
        // A retried arrival makes no second copy.
        #expect(try await b.merge(record) == .alreadyPresent)
        #expect(await f.apiB.count() == 2)
    }

    @Test func anAPIKeyRemovedByAnAIGoesEverywhereAndComesBackWithPutBack() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        let a = await f.wrap(f.apiStore(f.apiA, "A").deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let b = await f.wrap(f.apiStore(f.apiB, "B").deleteRuleStore(stateRoot: f.state("B"), gate: { true }, now: f.now), "B")
        let record = try #require(await a.capture().first)
        #expect(try await b.merge(record) == .applied)
        _ = try await b.capture()
        let item = try #require(await a.items().first)
        #expect(item.name == "Work Claude")
        _ = try await a.deleteItems([item], scope: .everywhere, by: f.actor(.ai))
        #expect(await f.apiA.count() == 0)
        let removal = try #require(await a.captureRemovals().first)
        #expect(try await b.mergeRemoval(removal) == .applied)
        #expect(await f.apiB.count() == 0)
        let group = try #require(await b.binGroups().first)
        #expect(group.items.map(\.name) == ["Work Claude"])
        #expect(try await b.putBackGroup(group.id).count == 1)
        #expect(await f.apiB.account(Self.idOne)?.key == Self.keyA)
    }

    @Test func aTaskTokenTravelsIntoTheSameConnectionAndFollowsTheDeleteRule() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let tokensA = KeysTokens(), tokensB = KeysTokens()
        tokensA.set("cts-crm", "made-up-task-token")
        let a = await f.wrap(BackendCloudKeysTasks.deleteRuleStore(f.taskStore(tokensA), stateRoot: f.state("A"), gate: { true },
            remove: { id, token in tokensA.removeIfSame(id, token) }, now: f.now), "A")
        let b = await f.wrap(BackendCloudKeysTasks.deleteRuleStore(f.taskStore(tokensB), stateRoot: f.state("B"), gate: { true },
            remove: { id, token in tokensB.removeIfSame(id, token) }, now: f.now), "B")
        let record = try #require(await a.capture().first)
        #expect(try await b.merge(record) == .applied)
        #expect(try tokensB.read("cts-crm") == "made-up-task-token")
        #expect(try await b.merge(record) == .alreadyPresent)
        _ = try await b.capture()
        let item = try #require(await a.items().first)
        #expect(item.name == "Example CRM")
        _ = try await a.deleteItems([item], scope: .everywhere, by: f.actor(.ai))
        #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .applied)
        #expect(try tokensB.read("cts-crm") == nil)
        #expect(try await b.binGroups().count == 1)
    }

    @Test func aReceiverSourceAndItsSecretTravelAndADifferentOneIsKept() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let storeA = BackendRCVStore(persistence: nil, cipher: nil), storeB = BackendRCVStore(persistence: nil, cipher: nil)
        try await storeA.start(); try await storeB.start()
        let source = KeysFixture.source("rcv-orders", "Orders")
        try await storeA.update { state in state.sources.append(source); state.secrets[source.id] = .init(secret: "made-up-receiver-secret") }
        let a = BackendCloudKeysReceiverStore(store: { storeA }), b = BackendCloudKeysReceiverStore(store: { storeB })
        let records = try await a.capture()
        for record in records { try await b.validate(record); _ = try await b.merge(record) }
        let state = try await storeB.read(), first = try await storeA.read()
        #expect(state.sources == [source])
        #expect(state.secrets[source.id]?.secret == "made-up-receiver-secret")
        #expect(state.receiverKey == first.receiverKey)   // a Receiver that never received anything takes the key
        for record in records { #expect(try await b.merge(record) == .alreadyPresent) }
        // A different secret for the same source on B: his stays.
        try await storeB.update { state in state.secrets[source.id] = .init(secret: "made-up-other-secret") }
        let sourceRecord = try #require(records.first { $0.recordId == "source/rcv-orders" })
        #expect(try await b.merge(sourceRecord) == .keptBoth)
        #expect(try await storeB.read().secrets[source.id]?.secret == "made-up-other-secret")
    }

    @Test func aReceiverSourceRemovedOnOneMacIsRemovedOnTheOther() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let storeA = BackendRCVStore(persistence: nil, cipher: nil), storeB = BackendRCVStore(persistence: nil, cipher: nil)
        try await storeA.start(); try await storeB.start()
        let source = KeysFixture.source("rcv-orders", "Orders")
        try await storeA.update { state in state.sources.append(source); state.secrets[source.id] = .init(secret: "made-up-receiver-secret") }
        let a = await f.wrap(BackendCloudKeysReceiverStore(store: { storeA }).deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let b = await f.wrap(BackendCloudKeysReceiverStore(store: { storeB }).deleteRuleStore(stateRoot: f.state("B"), gate: { true }, now: f.now), "B")
        for record in try await a.capture() { _ = try await b.merge(record) }
        _ = try await b.capture()
        let item = try #require(await a.items().first { $0.name == "Orders" })
        _ = try await a.deleteItems([item], scope: .everywhere, by: f.actor())
        #expect(try await b.mergeRemoval(#require(await a.captureRemovals().first)) == .applied)
        #expect(try await storeB.read().sources.isEmpty)
        #expect(try await storeB.read().secrets.isEmpty)
    }

    @Test func anMCPServerIsAddedWithNoClickAndADifferentOneIsAddedBeside() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN"]), b = try f.mcp("B", servers: [:])
        let record = try #require(await a.store.capture().first { $0.recordId == "example" })
        #expect(try await b.store.merge(record) == .applied)
        #expect(try b.configuration.cloudDefinitions(scope: "user", project: nil)["example"]["env"]["TOKEN"].string == "MADE_UP_MCP_TOKEN")
        #expect(try await b.store.merge(record) == .alreadyPresent)
        // A different server under the same name: his stays, the other Mac's is added as "<name>-<Mac>".
        let c = try f.mcp("C", servers: ["example": "MADE_UP_OTHER_TOKEN"])
        #expect(try await c.store.merge(record) == .keptBoth)
        let listed = try c.configuration.cloudDefinitions(scope: "user", project: nil)
        #expect(listed["example"]["env"]["TOKEN"].string == "MADE_UP_OTHER_TOKEN")
        #expect(listed["example-mac-a"]["env"]["TOKEN"].string == "MADE_UP_MCP_TOKEN")
        // The copy coming back to A is the same server A has: one (nothing added; A never takes the name as its own).
        let copy = try #require(await c.store.capture().first { $0.recordId == "example-mac-a" })
        #expect(try await a.store.merge(copy) == .keptBoth)
        #expect(try a.configuration.cloudDefinitions(scope: "user", project: nil)["example-mac-a"] == .missing)
    }

    @Test func anMCPServerRemovedOnOneMacIsRemovedOnTheOther() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN"]), b = try f.mcp("B", servers: [:])
        let ownerA = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let ownerB = await f.wrap(b.store.deleteRuleStore(stateRoot: f.state("B"), gate: { true }, now: f.now), "B")
        let record = try #require(await ownerA.capture().first)
        #expect(try await ownerB.merge(record) == .applied)
        _ = try await ownerB.capture()
        let item = try #require(await ownerA.items().first)
        _ = try await ownerA.deleteItems([item], scope: .everywhere, by: f.actor(.ai))
        #expect(try await ownerB.mergeRemoval(#require(await ownerA.captureRemovals().first)) == .applied)
        #expect(try b.configuration.cloudDefinitions(scope: "user", project: nil)["example"] == .missing)
    }

    @Test func noValueAppearsInNamesErrorsOrLogLines() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        let a = await f.wrap(f.apiStore(f.apiA, "A").deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let items = try await a.items()
        #expect(!String(describing: items).contains(Self.keyA))
        // A refused arrival names no value.
        let record = try #require(await a.capture().first)
        let broken = CloudSecretRecord(sourceId: record.sourceId, recordId: "not-an-api-id-" + Self.keyA, domain: record.domain, payload: record.payload)
        do { try await f.apiStore(f.apiB, "B").validate(broken); Issue.record("A bad id must be refused") }
        catch {
            #expect(!error.localizedDescription.contains(Self.keyA))
            #expect(!CloudSecretsLog.cause(error).contains(Self.keyA))
        }
        // The owner not ready yet: "locked", never a value.
        let late = BackendCloudKeysAPIStore(owner: BackendCloudKeysLateAPIOwner { nil }, stateRoot: nil, thisMac: { "Mac B" })
        await #expect(throws: CloudFailure.secretsLocked) { _ = try await late.capture() }
        await #expect(throws: CloudFailure.secretsLocked) { _ = try await late.merge(record) }
        // His phones list it by name; the value sits only in the sealed value piece.
        let listed = BackendCloudShelfSealed.items([record], projectNames: [:])[.savedPasswords] ?? []
        #expect(listed.map { $0.password?.name } == ["Work Claude"])
        #expect(!String(describing: listed.map(\.password)).contains(Self.keyA))
    }
}

// MARK: - 15 Nov fix: an API store "locked" at start goes up by itself once its owner is ready

extension CloudKeysTravelTests {
    @Test func aLockedAPIOwnerThatBecomesReadyPutsTheListUpBySelfWithinSeconds() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        let box = LateOwnerSlot()
        let late = BackendCloudKeysAPIStore(owner: BackendCloudKeysLateAPIOwner { box.owner }, stateRoot: nil, thisMac: { "Mac A" })
        let sealer = try CloudSecretsShelfSealer.make(root: Data(repeating: 4, count: 32), sub: CloudSecretsFixtureServer.sub, epoch: 1)
        let mcp = Array(CloudSecretsEverywhereTests.twoSources().dropFirst())
        let service = FakeSealedShelf()
        let putter = BackendCloudShelfSealedPutter(send: { try await service.handle($0, $1, $2) }, file: nil)
        let notes = SealedNotes(), clock = SealedClock()
        let round = BackendCloudShelfSealedRound(putter: putter, material: {
            var failed: [String: String] = [:], records = mcp
            do { records += try await late.capture() } catch { failed["api"] = BackendCloudShelfSealed.reason(error) }
            return .ready(sealer: sealer, records: records, projectNames: [:], failed: failed)
        }, note: { notes.add($0) }, clock: { clock.now })
        // At start the API accounts are not ready: "locked" means "ask again shortly", and the rest goes up anyway.
        #expect(await round.run(throughSeq: "1", from: nil, atLaunch: true, signal: ["1"]))
        #expect(await service.stored.count == 1)
        #expect(notes.lines.last?.contains("API keys (not ready yet on this Mac)") == true)
        // The owner becomes ready and says so (the app: NativeCloudKeysOwners): the next round runs now and the API key
        // joins the list at once, with no 30 s settle and no 10-minute wait.
        box.owner = f.apiA
        await round.soon()
        clock.now += 1_000
        #expect(await round.retryDue())
        #expect(await round.run(throughSeq: "1", from: nil, atLaunch: false, signal: ["1"]))
        #expect(await service.stored.count == 2)
        #expect(notes.lines.last == "cloud shelf: sealed: saved passwords: put 2; secret files: unchanged")
        #expect(!notes.lines.joined().contains(Self.keyA) && !notes.lines.joined().contains("Work Claude"))
    }

    @Test func thePasswordsLineSaysWhichKindIsNotInCloudYet() {
        #expect(BackendCloudSecretsWords.notInCloudYet(["API keys"]) == "API keys are not in Cloud yet from this Mac")
        #expect(BackendCloudSecretsWords.notInCloudYet(["The voice key"]) == "The voice key is not in Cloud yet from this Mac")
        #expect(BackendCloudSecretsWords.notInCloudYet(["API keys", "MCP servers", "The voice key"])
                == "API keys, MCP servers and the voice key are not in Cloud yet from this Mac")
        var page = BackendCloudSecretsPage()
        page.standing = .protected; page.gaps = ["Not saved to Cloud from this Mac: API keys."]; page.gapKinds = ["API keys"]
        #expect(BackendCloudSecretsWords.state(page) == "API keys are not in Cloud yet from this Mac")
    }
}

private final class LateOwnerSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var held: (any BackendCloudKeysAPIOwner)?
    var owner: (any BackendCloudKeysAPIOwner)? { get { lock.withLock { held } } set { lock.withLock { held = newValue } } }
}

// MARK: - Server keys from his SSH settings (scratch SSH folders made here, never the real one)

extension CloudKeysTravelTests {
    static let keyText = "-----BEGIN OPENSSH PRIVATE KEY-----\nMADE-UP-KEY-MATERIAL-NOT-A-REAL-KEY\n-----END OPENSSH PRIVATE KEY-----\n"

    @Test func aServersKeyAndSettingsTravelAndTheOtherMacConnectsWithTheAppsCopy() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.sshMac("A", ownEntry: true), b = try f.sshMac("B", ownEntry: false, servers: [])
        let record = try #require(await a.store.capture().first)
        try await b.store.validate(record)
        #expect(try await b.store.merge(record) == .applied)
        #expect(try await b.store.verify(record, outcome: .applied))
        #expect(b.servers.list().first?.sshAlias == "work-box")     // the server itself arrived, same id
        let copy = try #require(b.folder.travelled("srv-1"))
        #expect(copy.hostname == "192.0.2.10" && copy.user == "deploy" && copy.port == 2222)
        let choice = try #require(BackendServersSSH.chooseSSHSettings(alias: "work-box", own: nil, travelled: copy))
        #expect(choice.travelled && choice.identities.count == 1)
        let file = try #require(choice.identities.first)
        #expect(file.hasPrefix(b.folder.root.path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(Self.keyText.utf8))
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: b.folder.root.path)[.posixPermissions] as? Int == 0o700)
        #expect(choice.extraTrusted.map(\.algorithm) == ["ssh-ed25519"])
        // Nothing was written into B's SSH folder.
        #expect(!FileManager.default.fileExists(atPath: b.home.appendingPathComponent(".ssh").path))
        #expect(try await b.store.merge(record) == .alreadyPresent)
        // B keeps the copy in Cloud as the same one item.
        #expect(try await b.store.capture() == [record])
    }

    @Test func theOtherMacsOwnSSHEntryAlwaysWins() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.sshMac("A", ownEntry: true), b = try f.sshMac("B", ownEntry: true)
        let before = try f.sshFolderListing(b.home)
        let record = try #require(await a.store.capture().first)
        #expect(try await b.store.merge(record) == .keptBoth)
        #expect(b.folder.travelled("srv-1") == nil)
        let own = try await b.resolve("work-box")
        let choice = try #require(BackendServersSSH.chooseSSHSettings(alias: "work-box", own: own, travelled: b.folder.travelled("srv-1")))
        #expect(!choice.travelled && choice.hostname == "192.0.2.20")
        #expect(try f.sshFolderListing(b.home) == before)
    }

    @Test func removingAServerKeyRemovesOnlyTheAppsCopyNeverHisSSHFolder() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.sshMac("A", ownEntry: true), b = try f.sshMac("B", ownEntry: false, servers: [])
        let ownerA = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let ownerB = await f.wrap(b.store.deleteRuleStore(stateRoot: f.state("B"), gate: { true }, now: f.now), "B")
        let before = try f.sshFolderListing(a.home)
        #expect(try await ownerB.merge(#require(await ownerA.capture().first)) == .applied)
        _ = try await ownerB.capture()
        let item = try #require(await ownerA.items().first)
        #expect(item.name == "Server key · Work box")
        _ = try await ownerA.deleteItems([item], scope: .everywhere, by: f.actor(.ai))
        #expect(try f.sshFolderListing(a.home) == before)              // his SSH folder is never changed
        #expect(try await ownerA.capture().isEmpty)                      // and it stays out of Cloud
        #expect(try await ownerB.mergeRemoval(#require(await ownerA.captureRemovals().first)) == .applied)
        #expect(b.folder.travelled("srv-1") == nil)
        let group = try #require(await ownerB.binGroups().first)
        #expect(try await ownerB.putBackGroup(group.id).count == 1)
        #expect(b.folder.travelled("srv-1") != nil)
    }

    @Test func noKeyMaterialInNamesErrorsOrTheShelfList() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.sshMac("A", ownEntry: true)
        let owner = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let record = try #require(await owner.capture().first)
        #expect(!String(describing: try await owner.items()).contains("MADE-UP-KEY-MATERIAL"))
        let broken = CloudSecretRecord(sourceId: record.sourceId, recordId: "../" + Self.keyText, domain: record.domain, payload: record.payload)
        do { try await a.store.validate(broken); Issue.record("A bad id must be refused") }
        catch {
            #expect(!error.localizedDescription.contains("MADE-UP-KEY-MATERIAL"))
            #expect(!CloudSecretsLog.cause(error).contains("MADE-UP-KEY-MATERIAL"))
        }
        let listed = BackendCloudShelfSealed.items([record], projectNames: [:])[.savedPasswords] ?? []
        #expect(listed.map { $0.password?.name } == ["Server key · Work box"])
        #expect(!String(describing: listed.map(\.password)).contains("MADE-UP-KEY-MATERIAL"))
    }
}

// MARK: - Review fixes (15 Nov): removals stay removed, default keys, key changes, "Show"

extension CloudKeysTravelTests {
    @Test func aRemoveInTheAppGoesEverywhereAndTheCloudRecordNeverBringsItBack() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        let removals = BackendCloudKeysRemovals()
        let store = BackendCloudKeysAPIStore(owner: f.apiA, stateRoot: f.state("A"), thisMac: { "Mac A" }, removals: removals)
        let owner = await f.wrap(store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let record = try #require(await owner.capture().first)
        let actor = f.actor()
        removals.set { source, id in
            guard let item = try await owner.items().first(where: { $0.id == id }) else { return false }
            _ = try await owner.deleteItems([item], scope: .everywhere, by: actor)
            return true
        }
        #expect(try await removals.removeEverywhere(sourceId: "api", id: Self.idOne))
        #expect(await f.apiA.count() == 0)
        #expect(try await owner.captureRemovals().count == 1)        // it goes to his other devices
        #expect(try await owner.binGroups().count == 1)              // and sits in the Bin
        #expect(try await owner.merge(record) == .alreadyPresent)    // the Cloud record does not bring it back
        #expect(await f.apiA.count() == 0)
    }

    @Test func anMCPServerRemovedOutsideTheAppByAnAIGoesEverywhereAndStaysRemoved() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN"])
        let vanished = BackendCloudKeysVanished(who: { _, _, _ in .ai(session: "Night work", agent: "Worker", command: Date(), group: UUID().uuidString) },
                                                device: { "a" }, deviceName: { "Mac A" })
        let clock = f.now
        let owner = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, serviceClock: { clock() }, vanished: vanished, now: f.now), "A")
        let record = try #require(await owner.capture().first)
        try f.removeOutside(a.configuration, "example")
        #expect(try await owner.capture().isEmpty)
        #expect(try await owner.captureRemovals().count == 1)
        #expect(try await owner.binGroups().first?.session == "Night work")
        #expect(try await owner.merge(record) == .alreadyPresent)
        #expect(try a.configuration.cloudDefinitions(scope: "user", project: nil)["example"] == .missing)
    }

    @Test func anMCPServerRemovedByHisOwnHandStaysAwayHereOnly() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN"])
        let vanished = BackendCloudKeysVanished(who: { _, _, _ in .notAI }, device: { "a" }, deviceName: { "Mac A" })
        let owner = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, vanished: vanished, now: f.now), "A")
        let record = try #require(await owner.capture().first)
        try f.removeOutside(a.configuration, "example")
        #expect(try await owner.capture().isEmpty)
        #expect(try await owner.captureRemovals().isEmpty)              // this Mac only
        #expect(try await owner.notHere().map(\.mark) == [.notOnThisMac])
        #expect(try await owner.merge(record) == .alreadyPresent)      // sync never re-adds it here
        #expect(try a.configuration.cloudDefinitions(scope: "user", project: nil)["example"] == .missing)
        // "Bring back" puts it back on this Mac.
        let item = try #require(await owner.notHere().first?.item)
        #expect(try await owner.bringBack([item], to: .thisMac).count == 1)
        #expect(try a.configuration.cloudDefinitions(scope: "user", project: nil)["example"] != .missing)
    }

    @Test func aMacWithOnlyADefaultKeyStoresAndUsesTheArrivalAndSendsNothingOfItsOwn() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.sshMac("A", ownEntry: true), b = try f.sshMac("B", ownEntry: false, defaultKeyOnly: true)
        #expect(try await b.store.capture().isEmpty)                    // his default key is never sent
        let record = try #require(await a.store.capture().first)
        #expect(try await b.store.merge(record) == .applied)
        let own = try await b.resolve("work-box")
        let choice = try #require(BackendServersSSH.chooseSSHSettings(alias: "work-box", own: own, travelled: b.folder.travelled("srv-1")))
        #expect(choice.travelled && choice.hostname == "192.0.2.10")
        #expect(try await b.store.capture() == [record])                // the arrival, never B's default key
        #expect(!String(describing: try await b.store.capture()).contains("MADE-UP-DEFAULT-KEY"))
    }

    @Test func aKeyChangedTwiceOnOneMacEndsAsOneAccountWithTheNewestKey() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        let a = await f.wrap(f.apiStore(f.apiA, "A").deleteRuleStore(stateRoot: f.state("A"), gate: { true }, now: f.now), "A")
        let b = await f.wrap(f.apiStore(f.apiB, "B").deleteRuleStore(stateRoot: f.state("B"), gate: { true }, now: f.now), "B")
        #expect(try await b.merge(#require(await a.capture().first)) == .applied)
        let echo = try await b.capture()
        #expect(try await a.merge(#require(echo.first)) == .alreadyPresent)
        for key in [Self.keyB, "sk-made-up-key-cccccccccccccccccccccccc"] {
            await f.apiA.setKey(Self.idOne, key)
            #expect(try await b.merge(#require(await a.capture().first)) == .applied)
            _ = try await b.capture()
            #expect(await f.apiB.count() == 1)
            #expect(await f.apiB.account(Self.idOne)?.key == key)
        }
        // B sends nothing older back: its record is A's newest, unchanged.
        #expect(try await b.capture() == a.capture())
    }

    @Test func showOnAnMCPServerKeyOrReceiverRecordGivesNothing() {
        #expect(!BackendCloudSecretsGraph.revealable(sourceId: "mcp-user"))
        #expect(!BackendCloudSecretsGraph.revealable(sourceId: "ssh"))
        #expect(!BackendCloudSecretsGraph.revealable(sourceId: "receiver"))
        #expect(BackendCloudSecretsGraph.revealable(sourceId: "servers"))
    }
}

// MARK: - Review fixes 2 (15 Nov): empty reads, an AI's own remove command, the stale id

extension CloudKeysTravelTests {
    @Test func aMissingOrEmptySettingsFileChangesNothing() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN", "other": "MADE_UP_OTHER_TOKEN"])
        let vanished = BackendCloudKeysVanished(who: { _, _, _ in .ai(session: "Night work", agent: nil, command: Date(), group: UUID().uuidString) },
                                                device: { "a" }, deviceName: { "Mac A" })
        let clock = f.now
        let owner = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, serviceClock: { clock() }, vanished: vanished, now: f.now), "A")
        #expect(try await owner.capture().count == 2)
        let file = URL(fileURLWithPath: a.configuration.claudeJSONPath)
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)                     // missing
        #expect(try await owner.capture().isEmpty)
        try Data("{}".utf8).write(to: file)                              // no server list
        #expect(try await owner.capture().isEmpty)
        #expect(try await owner.captureRemovals().isEmpty)
        #expect(try await owner.notHere().isEmpty)
        #expect(try await owner.binGroups().isEmpty)
        try saved.write(to: file)
        #expect(try await owner.capture().count == 2)                    // and it goes on as before
    }

    @Test func onlyAnAIsOwnMCPRemoveCommandNamesTheServer() {
        func covers(_ tool: String, _ input: NativeRPCValue) -> [String] {
            BackendAIDeleteWitness.reading(tool: tool, input: input, cwd: "/made-up/project", home: "/made-up/home")?.covers.map(\.value) ?? []
        }
        func shell(_ command: String) -> [String] { covers("Bash", .object([.init("command", .string(command))])) }
        let path = BackendAIDeleteWitness.mcpUserServerPath("example")
        #expect(shell("claude mcp remove example") == [path])
        #expect(shell("claude mcp remove --scope user -- example") == [path])
        #expect(shell("claude mcp remove -s project example").isEmpty)  // another list, not his user list
        #expect(shell("claude mcp remove $NAME").isEmpty)               // not readable from the text
        #expect(shell("claude mcp list").isEmpty && shell("claude mcp add-json example '{}'").isEmpty)
        // A write to Claude Code's settings file is never a removal of a server.
        #expect(covers("Write", .object([.init("file_path", .string("/made-up/home/.claude.json")), .init("content", .string("{}"))])).isEmpty)
    }

    @Test func aStaleIdLeavesCloudSoANewMacGetsOneAccountWithTheNewestKey() async throws {
        let f = try KeysFixture(); defer { f.close() }
        try await f.apiA.add(Self.idOne, name: "Work Claude", key: Self.keyA)
        try await f.apiB.add(Self.idTwo, name: "Claude at home", key: Self.keyA)
        let clock = f.now
        func identity(_ mac: String) -> BackendCloudKeysVanished { .identityOnly(device: { mac }, deviceName: { "Mac " + mac }) }
        let a = await f.wrap(f.apiStore(f.apiA, "A").deleteRuleStore(stateRoot: f.state("A"), gate: { true }, serviceClock: { clock() },
                                                                    vanished: identity("a"), now: f.now), "A")
        let b = await f.wrap(f.apiStore(f.apiB, "B").deleteRuleStore(stateRoot: f.state("B"), gate: { true }, serviceClock: { clock() },
                                                                    vanished: identity("b"), now: f.now), "B")
        #expect(try await b.capture().map(\.recordId) == [Self.idTwo])  // B's own id went to Cloud first
        #expect(try await b.merge(#require(await a.capture().first)) == .alreadyPresent)
        let retired = try #require(await b.captureRemovals().first)
        #expect(retired.recordId == Self.idTwo)                          // B's old id leaves Cloud (Cloud only)
        #expect(try await b.capture().map(\.recordId) == [Self.idOne])
        #expect(await f.apiB.count() == 1)                               // nothing removed on B
        // A changes the key; a brand-new Mac C then gets the Cloud as it stands.
        await f.apiA.setKey(Self.idOne, Self.keyB)
        let apiC = KeysAPIOwner()
        let c = await f.wrap(f.apiStore(apiC, "C").deleteRuleStore(stateRoot: f.state("C"), gate: { true }, now: f.now), "C")
        #expect(try await c.merge(#require(await a.capture().first)) == .applied)
        _ = try await c.mergeRemoval(retired)
        #expect(await apiC.count() == 1)
        #expect(await apiC.account(Self.idOne)?.key == Self.keyB)
    }
}

// MARK: - Review fixes 4 (15 Nov): his LAST MCP server removed stays removed; a damaged or missing file changes nothing

extension CloudKeysTravelTests {
    @Test func theLastMCPServerRemovedByHisHandStaysAwayHereAndSyncNeverAddsItBack() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN", "other": "MADE_UP_OTHER_TOKEN"])
        let vanished = BackendCloudKeysVanished(who: { _, _, _ in .notAI }, device: { "a" }, deviceName: { "Mac A" })
        let owner = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, vanished: vanished, now: f.now), "A")
        let records = try await owner.capture()
        #expect(records.count == 2)
        try f.removeOutside(a.configuration, "other")
        #expect(try await owner.capture().map(\.recordId) == ["example"])
        try f.removeOutside(a.configuration, "example")                 // his last one: the list is now empty
        #expect(try await owner.capture().isEmpty)
        #expect(try await owner.captureRemovals().isEmpty)              // this Mac only
        #expect(Set(try await owner.notHere().map(\.item.id)) == ["example", "other"])
        for record in records { #expect(try await owner.merge(record) == .alreadyPresent) }   // sync never re-adds them
        #expect(try a.configuration.cloudDefinitions(scope: "user", project: nil).fields?.isEmpty == true)
        #expect(try await owner.capture().isEmpty)
    }

    @Test func theLastMCPServerRemovedByAnAIGoesEverywhere() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN"])
        let vanished = BackendCloudKeysVanished(who: { _, _, _ in .ai(session: "Night work", agent: "Worker", command: Date(), group: UUID().uuidString) },
                                                device: { "a" }, deviceName: { "Mac A" })
        let clock = f.now
        let owner = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, serviceClock: { clock() }, vanished: vanished, now: f.now), "A")
        let record = try #require(await owner.capture().first)
        // `claude mcp remove` of the last server may leave the list key out altogether: still his one removal.
        let file = URL(fileURLWithPath: a.configuration.claudeJSONPath)
        try NativeRPCValue.object([.init("numStartups", .number(3))]).encodedJSON().write(to: file, options: .atomic)
        #expect(try await owner.capture().isEmpty)
        #expect(try await owner.captureRemovals().map(\.recordId) == ["example"])
        #expect(try await owner.binGroups().first?.items.map(\.name) == ["example"])
        #expect(try await owner.merge(record) == .alreadyPresent)
        #expect(try a.configuration.cloudDefinitions(scope: "user", project: nil)["example"] == .missing)
    }

    @Test func twoMCPServersVanishingAtOnceWithAnEmptyListChangeNothing() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN", "other": "MADE_UP_OTHER_TOKEN"])
        let vanished = BackendCloudKeysVanished(who: { _, _, _ in .ai(session: "Night work", agent: nil, command: Date(), group: UUID().uuidString) },
                                                device: { "a" }, deviceName: { "Mac A" })
        let clock = f.now
        let owner = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, serviceClock: { clock() }, vanished: vanished, now: f.now), "A")
        #expect(try await owner.capture().count == 2)
        let file = URL(fileURLWithPath: a.configuration.claudeJSONPath)
        let saved = try Data(contentsOf: file)
        try NativeRPCValue.object([.init("mcpServers", .object([]))]).encodedJSON().write(to: file, options: .atomic)
        #expect(try await owner.capture().isEmpty)
        #expect(try await owner.captureRemovals().isEmpty)
        #expect(try await owner.notHere().isEmpty)
        #expect(try await owner.binGroups().isEmpty)
        try saved.write(to: file)
        #expect(try await owner.capture().count == 2)
    }

    @Test func aMissingOrInvalidMCPSettingsFileChangesNothingEvenForHisOnlyServer() async throws {
        let f = try KeysFixture(); defer { f.close() }
        let a = try f.mcp("A", servers: ["example": "MADE_UP_MCP_TOKEN"])
        let vanished = BackendCloudKeysVanished(who: { _, _, _ in .ai(session: "Night work", agent: nil, command: Date(), group: UUID().uuidString) },
                                                device: { "a" }, deviceName: { "Mac A" })
        let clock = f.now
        let owner = await f.wrap(a.store.deleteRuleStore(stateRoot: f.state("A"), gate: { true }, serviceClock: { clock() }, vanished: vanished, now: f.now), "A")
        #expect(try await owner.capture().count == 1)
        let file = URL(fileURLWithPath: a.configuration.claudeJSONPath)
        let saved = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file)                     // missing
        #expect(try await owner.capture().isEmpty)
        for broken in ["not json", "", "[]", "{\"mcpServers\": 5}"] {     // invalid: the read fails, nothing is judged
            try Data(broken.utf8).write(to: file)
            await #expect(throws: (any Error).self) { try await owner.capture() }
        }
        #expect(try await owner.captureRemovals().isEmpty)
        #expect(try await owner.notHere().isEmpty)
        #expect(try await owner.binGroups().isEmpty)
        try saved.write(to: file)
        #expect(try await owner.capture().count == 1)                    // and it goes on as before
    }
}

// MARK: - Scratch owners

private actor KeysAPIOwner: BackendCloudKeysAPIOwner {
    struct Held: Sendable { let record: BackendAPIAccountRecord; let name: String; let key: String }
    private var accounts: [String: Held] = [:]
    func add(_ id: String, name: String, key: String) throws {
        accounts[id] = .init(record: try Self.record(id, name: name, kind: .anthropic, baseURL: nil), name: name, key: key)
    }
    static func record(_ id: String, name: String, kind: BackendAPIAccountRecord.Kind, baseURL: String?, model: String? = nil, workspace: String? = nil) throws -> BackendAPIAccountRecord {
        let profile = BackendAccountProfile(id: id, name: name, provider: kind.provider, configDir: "/made-up/" + id, system: false, color: "--accent", createdAt: 0)
        return try BackendAPIAccountRecord(profile: profile, appName: "Made-up Deck", kind: kind, baseURL: baseURL, model: model, workspaceID: workspace)
    }
    func account(_ id: String) -> Held? { accounts[id] }
    func all() -> [Held] { Array(accounts.values) }
    func count() -> Int { accounts.count }
    func cloudAccounts() -> [BackendCloudKeysAPIAccount] { accounts.values.map { .init(record: $0.record, name: $0.name) } }
    func cloudKey(_ record: BackendAPIAccountRecord) -> String? { accounts[record.accountID]?.key }
    func cloudCreate(accountID: String, name: String, value: BackendCloudKeysAPIValue) throws {
        guard accounts[accountID] == nil, let kind = BackendAPIAccountRecord.Kind(rawValue: value.kind) else { throw CloudFailure.versionChanged }
        accounts[accountID] = .init(record: try Self.record(accountID, name: name, kind: kind, baseURL: value.baseURL, model: value.model, workspace: value.workspaceID),
                                    name: name, key: value.key)
    }
    func cloudRemove(accountID: String, expectingKey: String) -> Bool {
        guard let held = accounts[accountID] else { return true }
        guard held.key == expectingKey else { return false }
        accounts[accountID] = nil; return true
    }
    func cloudReplaceKey(accountID: String, key: String, expectingKey: String) -> Bool {
        guard let held = accounts[accountID], held.key == expectingKey else { return false }
        accounts[accountID] = .init(record: held.record, name: held.name, key: key); return true
    }
    func setKey(_ id: String, _ key: String) {
        guard let held = accounts[id] else { return }
        accounts[id] = .init(record: held.record, name: held.name, key: key)
    }
}

private final class KeysTokens: BackendConnectedTasksSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    func set(_ id: String, _ token: String) { lock.withLock { tokens[id] = token } }
    func read(_ connectionID: String) throws -> String? { lock.withLock { tokens[connectionID] } }
    func write(_ connectionID: String, token: String) throws { lock.withLock { tokens[connectionID] = token } }
    func remove(_ connectionID: String) throws { lock.withLock { tokens[connectionID] = nil } }
    func insertIfAbsent(_ id: String, _ token: String) -> CloudApplyStatus {
        lock.withLock {
            if let existing = tokens[id] { return existing == token ? .alreadyPresent : .keptBoth }
            tokens[id] = token; return .applied
        }
    }
    func removeIfSame(_ id: String, _ token: String) -> Bool {
        lock.withLock {
            guard let existing = tokens[id] else { return true }
            guard existing == token else { return false }
            tokens[id] = nil; return true
        }
    }
}

private actor KeysMCPCommand {
    let file: URL
    init(file: URL) { self.file = file }
    func run(_ args: [String]) throws -> BackendGitOutcome {
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

private final class KeysClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_900_000_000_000
    func now() -> Int64 { lock.withLock { value += 3_001; return value } }
}

private final class KeysServers: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [BackendServersStoredServer]
    init(_ rows: [BackendServersStoredServer]) { self.rows = rows }
    func list() -> [BackendServersStoredServer] { lock.withLock { rows } }
    func add(_ id: String, _ value: BackendCloudKeysSSHValue) {
        lock.withLock {
            guard !rows.contains(where: { $0.id == id }) else { return }
            rows.append(.init(id: id, name: value.server.name, address: value.hostname, port: value.port, username: value.user, sshAlias: value.alias))
        }
    }
}

private struct KeysSSHMac: Sendable {
    let store: BackendCloudKeysSSHStore
    let folder: BackendCloudKeysSSHFolder
    let servers: KeysServers
    let home: URL
    let resolve: @Sendable (String) async throws -> BackendDockerMCPServerSSHConfig.Resolution
}

extension KeysFixture {
    /// A scratch SSH folder for this Mac (inside the test's own temporary folder). With `ownEntry`, his settings name
    /// "work-box" with a key file; without, `ssh -G` has no entry for it here.
    func sshMac(_ mac: String, ownEntry: Bool, defaultKeyOnly: Bool = false,
                servers rows: [BackendServersStoredServer] = [.init(id: "srv-1", name: "Work box", address: "192.0.2.10", port: 2222, username: "deploy", sshAlias: "work-box")]) throws -> KeysSSHMac {
        let home = root.appendingPathComponent(mac + "/scratch-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var resolution: BackendDockerMCPServerSSHConfig.Resolution?
        if ownEntry {
            let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = ssh.appendingPathComponent("work_key")
            try Data((mac == "A" ? CloudKeysTravelTests.keyText : "MADE-UP-OTHER-KEY-OF-" + mac).utf8).write(to: key)
            chmod(key.path, 0o600)
            resolution = .init(hostname: mac == "A" ? "192.0.2.10" : "192.0.2.20", user: "deploy", port: 2222, identityFiles: [key.path])
        } else if defaultKeyOnly {
            // His SSH settings do not know the name: `ssh -G` answers with the name itself and a default key file.
            let ssh = home.appendingPathComponent(".ssh", isDirectory: true)
            try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = ssh.appendingPathComponent("id_ed25519")
            try Data("MADE-UP-DEFAULT-KEY-OF-\(mac)".utf8).write(to: key)
            chmod(key.path, 0o600)
            resolution = .init(hostname: "work-box", user: "me", port: 22, identityFiles: [key.path], fromDefaults: true)
        }
        let resolve: @Sendable (String) async throws -> BackendDockerMCPServerSSHConfig.Resolution = { [resolution] alias in
            guard alias == "work-box", let resolution else { throw CloudFailure.unavailable }
            return resolution
        }
        let servers = KeysServers(rows)
        let folder = BackendCloudKeysSSHFolder(root: state(mac).appendingPathComponent("ssh-travelled", isDirectory: true))
        let store = BackendCloudKeysSSHStore(servers: { servers.list() }, resolve: resolve,
            trusted: { host, _ in host == "192.0.2.10" ? [.init(algorithm: "ssh-ed25519", key: Data(repeating: 7, count: 51))] : [] },
            addServer: { id, value in servers.add(id, value) }, folder: folder)
        return .init(store: store, folder: folder, servers: servers, home: home, resolve: resolve)
    }
    func sshFolderListing(_ home: URL) throws -> [String: Data] {
        let ssh = home.appendingPathComponent(".ssh")
        guard FileManager.default.fileExists(atPath: ssh.path) else { return [:] }
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: ssh.path) { out[name] = try Data(contentsOf: ssh.appendingPathComponent(name)) }
        return out
    }
}

private struct KeysFixture: Sendable {
    let root: URL
    let shared = SymmetricKey(size: .bits256)
    let aKey = SymmetricKey(size: .bits256)
    let bKey = SymmetricKey(size: .bits256)
    let clock = KeysClock()
    let apiA = KeysAPIOwner(), apiB = KeysAPIOwner()
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("td-keys-travel-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func close() { try? FileManager.default.removeItem(at: root) }
    var now: @Sendable () -> Int64 { let clock = clock; return { clock.now() } }
    func state(_ mac: String) -> URL { root.appendingPathComponent(mac + "/state") }
    func keys(_ mac: String) -> CloudSecretsStoreKeys { .init(epoch: 1, sharedKey: shared, local: mac == "A" ? aKey : bKey) }
    func actor(_ by: CloudDeleteBy = .person) -> CloudDeleteActor {
        .init(by: by, mac: "a", macName: "Mac A", session: by == .ai ? "Night work" : nil, agent: by == .ai ? "Worker" : nil,
              at: clock.now(), group: UUID().uuidString)
    }
    func wrap(_ owner: BackendProjectSecretFilesSavedDeleteOwner, _ mac: String) async -> BackendProjectSecretFilesSavedDeleteOwner {
        await owner.use(keys: keys(mac)); return owner
    }
    func apiStore(_ owner: KeysAPIOwner, _ mac: String) -> BackendCloudKeysAPIStore {
        BackendCloudKeysAPIStore(owner: owner, stateRoot: state(mac), thisMac: { "Mac " + mac })
    }
    func taskStore(_ tokens: KeysTokens) -> BackendCloudSecretsTaskStore {
        BackendCloudSecretsTaskStore(sourceId: "tasks", tokens: tokens, connectionIds: { ["cts-crm"] },
            insertIfAbsent: { id, token in tokens.insertIfAbsent(id, token) }, names: { ["cts-crm": "Example CRM"] })
    }
    static func source(_ id: String, _ name: String) -> RCVSource {
        RCVSource(id: id, name: name, preset: "webhook", auth: RCVPresets.generic.auth, mapping: RCVPresets.generic.mapping, createdAt: 1_900_000_000_000)
    }
    /// Removes a server from the scratch settings file the way `claude mcp remove` would (outside the app).
    func removeOutside(_ configuration: BackendMcpClientConfiguration, _ name: String) throws {
        let file = URL(fileURLWithPath: configuration.claudeJSONPath)
        var root = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        root = root.setting("mcpServers", root["mcpServers"].removing(name))
        try root.encodedJSON().write(to: file, options: .atomic)
    }
    func mcp(_ mac: String, servers: [String: String]) throws -> (store: BackendCloudSecretsMCPStore, configuration: BackendMcpClientConfiguration) {
        let home = root.appendingPathComponent(mac + "/fake-cli-home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = BackendMcpClientConfiguration(home: home.path, environment: [:])
        let file = URL(fileURLWithPath: config.claudeJSONPath)
        let rows = servers.sorted { $0.key < $1.key }.map { name, token in
            NativeRPCValue.Field(name, .object([.init("command", .string("example")), .init("env", .object([.init("TOKEN", .string(token))]))]))
        }
        try NativeRPCValue.object([.init("mcpServers", .object(rows))]).encodedJSON().write(to: file)
        let command = KeysMCPCommand(file: file)
        let claude = BackendCloudSecretsClaudeMCP(configuration: config, loginPath: { "/made-up-cli-path" }, run: { _, args, _, _, _ in
            try await command.run(args)
        })
        return (try BackendCloudSecretsMCPStore.travelling(claude: claude, thisMac: { "Mac " + mac }, requireWriter: {}), config)
    }
}
