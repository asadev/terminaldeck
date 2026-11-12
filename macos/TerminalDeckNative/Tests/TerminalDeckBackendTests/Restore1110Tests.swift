import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// 10 Nov (Asad, after a Mac restart: "this all should not happen, fix all"). One test per rule of the restore and
// account fix on lane/restore-1110.

actor Restore1110Starter: BackendRestoreSessionStarting {
    private(set) var inputs: [BackendCreateSessionInput] = []
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool) async throws -> BackendSessionMeta {
        inputs.append(input)
        return BackendFoundationTestsSessionsFixtures.meta("restored-\(inputs.count)", cwd: input.cwd, provider: input.provider ?? "claude")
    }
    func liveSessions() async -> [BackendSessionMeta] { [] }
}

struct Restore1110Run {
    let store: NativeStateStore
    let starter = Restore1110Starter()
    let coordinator: BackendSessionRestoreCoordinator
    /// `stamps` nil: a state.json from before the rule (the one-time clean-up runs).
    init(_ world: BackendFoundationTestsS5SessionsWorld, rows: [NativeRPCValue], stamps: [String: Double]?,
         hint: BackendSessionRestoreCoordinator.ConversationHint? = nil) async throws {
        var state = NativeStateStore.defaults.setting("openSessions", .array(rows))
        if let stamps { state = state.setting(NativeStateStore.openTabsKey, .object(stamps.map { .init($0.key, .number($0.value)) })) }
        store = NativeStateStore(initialState: state, clock: { now })
        try await store.startSessionLedger()
        let context = BackendSessionRestoreContext(readiness: .ready) { device, folder in .init(deviceKey: device, folder: folder) }
        coordinator = BackendSessionRestoreCoordinator(starter: starter, planner: world.planner, store: store, context: context,
            excludedAppWorkingDirectories: [], emit: { _ in })
        await coordinator.setConversationHint(hint)
    }
}

private func row(_ cwd: String, _ key: String, provider: String = "shell", extra: [NativeRPCValue.Field] = []) -> NativeRPCValue {
    var value = NativeRPCValue.object([.init("cwd", .string(cwd)), .init("provider", .string(provider)), .init("profileId", .null), .init("cols", .number(100)),
             .init("rows", .number(30)), .init("lastSeenAt", .number(1_000)), .init("tabKey", .string(key))])
    for field in extra { value = value.setting(field.key, field.value) }
    return value
}
private let now: Double = 1_800_000_000_000
private let hour: Double = 3_600_000

@Suite("Restore 1110: exactly the tabs open at quit")
struct Restore1110OpenTabsTests {
    @Test func aTabNotOpenAtTheLastQuitLeavesTheListInsteadOfComingBackOrBeingHeld() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let open = row(try world.folder("open"), "k-open"), old = row(try world.folder("old"), "k-old")
            let run = try await Restore1110Run(world, rows: [open, old], stamps: ["k-open": now, "k-old": now - 73 * hour])
            let result = try await run.coordinator.restore()
            #expect(await run.starter.inputs.map(\.tabKey) == ["k-open"])
            #expect(try await run.store.heldSessions().isEmpty)
            #expect(!(await run.store.getOpenSessions()).contains { $0["tabKey"].string == "k-old" })
            #expect(result.dropped.count == 1 && result.dropped[0].contains("not open at the last quit"))
        }
    }
    @Test func aHeldTabStaysOpenUntilRecoveryInsteadOfAgingOut() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let gone = row("/no/such/folder-1110", "k-gone"), open = row(try world.folder("open"), "k-open")
            let run = try await Restore1110Run(world, rows: [gone, open], stamps: ["k-gone": now - hour, "k-open": now])
            _ = try await run.coordinator.restore()
            #expect(try await run.store.heldSessions().map { $0.saved["tabKey"].string } == ["k-gone"])
            #expect(await run.store.getState()[NativeStateStore.openTabsKey]["k-gone"].number == now)
        }
    }
    @Test func theOneTimeCleanUpKeepsACopyAndOnlyTabsThatReallyRanLately() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let recent = row(try world.folder("recent"), "k-recent", extra: [.init(NativeOpenSessionLedger.activityKey, .number(now - 24 * hour))])
            let newest = row(try world.folder("newest"), "k-newest", extra: [.init(NativeOpenSessionLedger.activityKey, .number(now))])
            let stale = row(try world.folder("stale"), "k-stale")   // no activity ever recorded: closed long ago
            let file = world.fixture.root.appendingPathComponent("cleanup-state/state.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try NativeStateStore.defaults.setting("openSessions", .array([recent, newest, stale])).encodedJSON().write(to: file)
            let store = try NativeStateStore(file: file, ownership: .exclusive, clock: { now })
            try await store.startSessionLedger()
            let context = BackendSessionRestoreContext(readiness: .ready) { device, folder in .init(deviceKey: device, folder: folder) }
            let starter = Restore1110Starter()
            let coordinator = BackendSessionRestoreCoordinator(starter: starter, planner: world.planner, store: store, context: context,
                excludedAppWorkingDirectories: [], emit: { _ in })
            let result = try await coordinator.restore()
            #expect(Set(await starter.inputs.compactMap(\.tabKey)) == ["k-recent", "k-newest"])
            let copy = try #require(result.cleanUpCopy)
            #expect(copy.hasSuffix("state.json." + BackendSessionRestoreCoordinator.cleanUpCopySuffix))
            #expect((try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: copy)))["openSessions"].elements ?? []).count == 3)
            #expect(try await store.ledgerStampsReady())
            await store.close()
        }
    }
    @Test func anEmptyAITabNobodyUsedSinceItStartedDoesNotComeBackAgain() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let started = now - 50 * hour
            let unused = row(try world.folder("imatch"), "k-unused", provider: "codex", extra: [
                .init(NativeOpenSessionLedger.startedAtKey, .number(started)), .init(NativeOpenSessionLedger.activityKey, .number(started + 5_000))])
            let used = row(try world.folder("imatch-ios"), "k-used", provider: "codex", extra: [
                .init(NativeOpenSessionLedger.startedAtKey, .number(started)), .init(NativeOpenSessionLedger.activityKey, .number(started + 10 * 60_000))])
            let run = try await Restore1110Run(world, rows: [unused, used], stamps: ["k-unused": now, "k-used": now])
            let result = try await run.coordinator.restore()
            #expect(await run.starter.inputs.map(\.tabKey) == ["k-used"])
            #expect(result.dropped.contains { $0.contains("nobody used") })
        }
    }
}

@Suite("Restore 1110: a live tab comes back in its own conversation, never dropped")
struct Restore1110ConversationTests {
    @Test func aLostConversationIdFallsBackToTheNewestEarlierOneOnDisk() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("deck")
            let saved = row(cwd, "k-decker", provider: "claude", extra: [.init("agentSessionId", .string(BackendFoundationTestsS5SessionsWorld.uuid2)),
                .init(NativeOpenSessionLedger.knownConversationsKey, .array([.string(BackendFoundationTestsS5SessionsWorld.uuid1)])),
                .init("agentProfileID", .string("decker")), .init("profileId", .string("system"))])
            try world.writeTranscript(config: try await world.planner.configDirectory(try BackendSessionSaved(saved)), cwd: cwd,
                                      id: BackendFoundationTestsS5SessionsWorld.uuid1, body: "{\"type\":\"user\"}\n")
            let run = try await Restore1110Run(world, rows: [saved], stamps: ["k-decker": now])
            _ = try await run.coordinator.restore()
            let input = try #require(await run.starter.inputs.first)
            #expect(input.resume == true); #expect(input.resumeConversationId == BackendFoundationTestsS5SessionsWorld.uuid1)
            #expect(input.agentProfileID == "decker")
        }
    }
    @Test func aTabWhoseConversationIsGoneStaysHeldWithItsSavedConversation() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let saved = row(try world.folder("lost"), "k-lost", provider: "claude", extra: [
                .init("agentSessionId", .string(BackendFoundationTestsS5SessionsWorld.uuid2)), .init("agentProfileID", .string("decker"))])
            let run = try await Restore1110Run(world, rows: [saved], stamps: ["k-lost": now])
            _ = try await run.coordinator.restore()
            #expect(await run.starter.inputs.isEmpty)
            let held = try #require(try await run.store.heldSessions().first)
            #expect(held.pick)
            #expect(held.saved["agentSessionId"] == saved["agentSessionId"])
            #expect((await run.store.getOpenSessions()).contains { $0["tabKey"].string == "k-lost" })
        }
    }
    @Test func theSessionMemoryHintBringsBackTheConversationTheTabWasReallyIn() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("hint")
            let saved = row(cwd, "k-hint", provider: "claude", extra: [.init("agentSessionId", .string(BackendFoundationTestsS5SessionsWorld.uuid2)),
                .init("agentProfileID", .string("decker")), .init("profileId", .string("system"))])
            try world.writeTranscript(config: try await world.planner.configDirectory(try BackendSessionSaved(saved)), cwd: cwd,
                                      id: BackendFoundationTestsS5SessionsWorld.uuid1, body: "{\"type\":\"user\"}\n")
            let run = try await Restore1110Run(world, rows: [saved], stamps: ["k-hint": now],
                                               hint: { saved, claimed, config in
                guard !claimed.contains(BackendFoundationTestsS5SessionsWorld.uuid1) else { return nil }
                return BackendRestoreConversationHint.Candidate(conversationID: BackendFoundationTestsS5SessionsWorld.uuid1,
                    sessionID: "linked", tabKey: saved.tabKey, historyOwnerID: "system",
                    transcriptPath: URL(fileURLWithPath: config).appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(cwd) + "/" + BackendFoundationTestsS5SessionsWorld.uuid1 + ".jsonl").path)
            })
            _ = try await run.coordinator.restore()
            let input = try #require(await run.starter.inputs.first)
            #expect(input.resume == true); #expect(input.resumeConversationId == BackendFoundationTestsS5SessionsWorld.uuid1)
        }
    }
    @Test func theHintReadsTheNewestMatchingSessionMemoryRecordWithATranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("restore1110-hint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = "/Users/someone/Deck Dev", folder = NativeTranscriptPaths.encodeProjectPath(cwd)
        func record(_ name: String, id: String, agent: String?, at: Double, transcript: Bool) throws {
            let dir = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = root.appendingPathComponent("projects/\(folder)/\(id).jsonl")
            if transcript { try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("x\n".utf8).write(to: path) }
            var fields: [String: Any] = ["provider": "claude", "conversationID": id, "transcriptPath": path.path, "lastTurnAt": at, "tabKey": "k", "historyOwnerID": "system"]
            if let agent { fields["agentProfileID"] = agent }
            try JSONSerialization.data(withJSONObject: fields).write(to: dir.appendingPathComponent("state.json"))
        }
        try record("a", id: "older-real", agent: "decker", at: 1, transcript: true)
        try record("b", id: "newer-gone", agent: "decker", at: 3, transcript: false)
        try record("c", id: "other-agent", agent: "alex", at: 5, transcript: true)
        let saved = try BackendSessionSaved(row(cwd, "k", provider: "claude", extra: [.init("agentProfileID", .string("decker")), .init("profileId", .string("system"))]))
        #expect(BackendRestoreConversationHint.best(in: root, for: saved, claimed: [], configDirectory: root.path)?.conversationID == "older-real")
        #expect(BackendRestoreConversationHint.best(in: root, for: saved, claimed: ["older-real"], configDirectory: root.path) == nil)
    }
    @Test func onlyAConversationWithItsTranscriptOnDiskIsFollowed() {
        // Asad's Decker tab: Claude's idle compaction reported a background session id that never got a transcript.
        #expect(!DeckMemorySessionCenter.believed(named: "bogus", transcriptPath: "/p/bogus.jsonl", current: "real", exists: { _ in false }))
        #expect(DeckMemorySessionCenter.believed(named: "real", transcriptPath: nil, current: "real", exists: { _ in false }))
        #expect(DeckMemorySessionCenter.believed(named: "cleared", transcriptPath: "/p/cleared.jsonl", current: "real", exists: { _ in true }))
        #expect(!DeckMemorySessionCenter.believed(named: "cleared", transcriptPath: "/p/other.jsonl", current: "real", exists: { _ in true }))
    }
    @Test func theLedgerRemembersEarlierConversationsAndWhoOpenedTheTab() throws {
        var ledger = try NativeOpenSessionLedger(saved: [])
        let first = row("/w", "k", provider: "claude", extra: [.init("agentSessionId", .string("c1")), .init(NativeOpenSessionLedger.openedByKey, .string("restore")),
            .init(NativeOpenSessionLedger.startedAtKey, .number(5))])
        try ledger.note("s1", saved: first)
        try ledger.update("s1", patch: .object([.init("agentSessionId", .string("c2"))]))
        var saved = try #require(ledger.get("s1"))
        #expect(saved[NativeOpenSessionLedger.knownConversationsKey].elements == [.string("c1")])
        // The same process noted again (an app start re-notes the keeper's sessions): who opened it stays.
        try ledger.note("s1", saved: saved.setting(NativeOpenSessionLedger.openedByKey, .string("person")))
        saved = try #require(ledger.get("s1"))
        #expect(saved[NativeOpenSessionLedger.openedByKey].string == "restore")
        #expect(saved[NativeOpenSessionLedger.firstOpenedByKey].string == "restore")
        // A new process for the tab: the new opener, the first one kept.
        try ledger.note("s2", saved: saved.setting(NativeOpenSessionLedger.openedByKey, .string("person")).setting(NativeOpenSessionLedger.startedAtKey, .number(9)))
        let next = try #require(ledger.get("s2"))
        #expect(next[NativeOpenSessionLedger.openedByKey].string == "person"); #expect(next[NativeOpenSessionLedger.firstOpenedByKey].string == "restore")
    }
}

@Suite("Restore 1110: each tab on its own account, agent and project")
struct Restore1110AccountTests {
    @Test func aSavedTabRecordsItsProjectWhoOpenedItAndWhenItStarted() {
        var input = BackendCreateSessionInput(cwd: "/w/imatch", provider: "claude"); input.projectId = "imatch"; input.origin = .copilot
        let meta = BackendFoundationTestsSessionsFixtures.meta("s1", cwd: "/w/imatch")
        let saved = BackendNativeLedger.savedLaunch(meta, input: input, deviceKey: nil)
        #expect(saved["projectId"].string == "imatch")
        #expect(saved[NativeOpenSessionLedger.openedByKey].string == "hoot")
        #expect(saved[NativeOpenSessionLedger.startedAtKey].number == meta.createdAt)
        #expect(BackendNativeLedger.openedBy(BackendCreateSessionInput(cwd: "/w", provider: "claude"), restoring: true) == "restore")
        #expect(BackendNativeLedger.openedBy(BackendCreateSessionInput(cwd: "/w", provider: "claude"), restoring: false) == "person")
        var app = BackendCreateSessionInput(cwd: "/w", provider: "claude"); app.origin = .app
        #expect(BackendNativeLedger.openedBy(app, restoring: false) == "agent")
    }
    @Test func aSessionThatSwitchedAccountWhileRunningIsSavedOnThatAccount() async throws {
        let store = NativeStateStore(initialState: NativeStateStore.defaults)
        let ledger = try await BackendNativeLedger.activate(store: store)
        try await store.ledgerNote("s1", saved: row("/w", "k1", provider: "claude", extra: [.init("profileId", .string("asad"))]))
        var meta = BackendFoundationTestsSessionsFixtures.meta("s1", cwd: "/w"); meta.profileId = "imatch"; meta.homeProfileId = "asad"
        await ledger.followAccount(meta)
        let saved = try await store.ledgerGet("s1")
        #expect(saved["profileId"].string == "imatch"); #expect(saved["homeProfileId"].string == "asad")
    }
    @Test func aSwitchedTabComesBackOnItsLoginAccountsOwnFolderWhenItsChatIsVisibleThere() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let work = try await world.fixture.create("work")
            let cwd = try world.folder("switched")
            try world.writeTranscript(config: work.configDir, cwd: cwd, id: BackendFoundationTestsS5SessionsWorld.uuid1, body: "{\"type\":\"user\"}\n")
            let saved = try BackendSessionSaved(row(cwd, "k-sw", provider: "claude", extra: [.init("profileId", .string(work.id)),
                .init("homeProfileId", .string("system")), .init("agentSessionId", .string(BackendFoundationTestsS5SessionsWorld.uuid1))]))
            let decision = try #require(await world.planner.plan([saved]).first)
            #expect(decision.outcome == .resume); #expect(decision.session.homeProfileID == nil)
            #expect(decision.configDirectory == work.configDir)
        }
    }
    @Test func aDeletedAccountLeavesTheRememberedLastAccounts() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let one = try await fixture.create("one"), two = try await fixture.create("two")
            try await fixture.profiles.markUsed(id: one.id, projectPath: "/w/a"); try await fixture.profiles.markUsed(id: two.id, projectPath: "/w/b")
            #expect(try fixture.disk()["lastClaudeAccounts"]["/w/a"].string == one.id)
            _ = try await fixture.profiles.removeMetadata(id: one.id)
            #expect(try fixture.disk()["lastClaudeAccounts"]["/w/a"] == .missing)
            #expect(try fixture.disk()["lastClaudeAccounts"]["/w/b"].string == two.id)
        }
    }
}

@Suite("Restore 1110: one chat history across account folders")
struct Restore1110SharedHistoryTests {
    @Test func accountFoldersJoinTheOneHistoryMergingWithoutLosingAFile() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let a = try await fixture.create("a"), busy = try await fixture.create("busy")
            let root = URL(fileURLWithPath: fixture.configuration.systemDirectory("claude")).appendingPathComponent("projects/-w")
            let own = URL(fileURLWithPath: a.configDir).appendingPathComponent("projects/-w")
            for dir in [root, own, URL(fileURLWithPath: busy.configDir).appendingPathComponent("projects/-w")] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try Data("old\n".utf8).write(to: root.appendingPathComponent("x.jsonl"))
            try Data("newer\n".utf8).write(to: own.appendingPathComponent("x.jsonl"))
            try Data("only-mine\n".utf8).write(to: own.appendingPathComponent("y.jsonl"))
            try Data("same\n".utf8).write(to: root.appendingPathComponent("z.jsonl")); try Data("same\n".utf8).write(to: own.appendingPathComponent("z.jsonl"))
            let day: TimeInterval = 86_400
            for name in ["y.jsonl", "z.jsonl"] {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-day)], ofItemAtPath: own.appendingPathComponent(name).path)
            }
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * day)], ofItemAtPath: root.appendingPathComponent("x.jsonl").path)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-day)], ofItemAtPath: own.appendingPathComponent("x.jsonl").path)
            // A folder written a minute ago is in use by something outside the app's sessions: it waits.
            let recent = try await fixture.create("recent")
            try FileManager.default.createDirectory(atPath: recent.configDir + "/projects/-w", withIntermediateDirectories: true)
            try Data("now\n".utf8).write(to: URL(fileURLWithPath: recent.configDir + "/projects/-w/r.jsonl"))
            #expect(await BackendSharedHistoryJoin.joinAll([recent], configuration: fixture.configuration, managed: { _ in true }, inUse: []).skipped.count == 1)
            let outcome = await BackendSharedHistoryJoin.joinAll([a, busy], configuration: fixture.configuration, managed: { _ in true }, inUse: [busy.id])
            #expect(outcome.joined == [a.id]); #expect(outcome.keptBeside == 1)
            #expect(outcome.skipped.contains { $0.hasPrefix(busy.id) && $0.contains("in use") })
            let link = try FileManager.default.destinationOfSymbolicLink(atPath: a.configDir + "/projects")
            #expect(URL(fileURLWithPath: link).standardizedFileURL.path == root.deletingLastPathComponent().standardizedFileURL.path)
            #expect(try String(contentsOf: root.appendingPathComponent("x.jsonl"), encoding: .utf8) == "newer\n")
            let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("x.jsonl.kept-") }
            #expect(kept.count == 1)
            #expect(try String(contentsOf: root.appendingPathComponent(kept[0]), encoding: .utf8) == "old\n")
            #expect(try String(contentsOf: root.appendingPathComponent("y.jsonl"), encoding: .utf8) == "only-mine\n")
            var isLink = false
            if let type = try? FileManager.default.attributesOfItem(atPath: busy.configDir + "/projects")[.type] as? FileAttributeType { isLink = type == .typeSymbolicLink }
            #expect(!isLink)
            // A second start finds it joined and changes nothing.
            #expect(await BackendSharedHistoryJoin.joinAll([a], configuration: fixture.configuration, managed: { _ in true }, inUse: []).already == [a.id])
        }
    }
    @Test func aFolderThePersonPointedTheAppAtIsLeftAlone() async throws {
        try await BackendFoundationTestsAccountsWithFixture { fixture in
            let a = try await fixture.create("outside")
            let outcome = await BackendSharedHistoryJoin.joinAll([a], configuration: fixture.configuration, managed: { _ in false }, inUse: [])
            #expect(outcome.joined.isEmpty); #expect(outcome.skipped.count == 1)
        }
    }
}
