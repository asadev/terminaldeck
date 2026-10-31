import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Lane S5. Ports src/main/session-restore.test.ts planRestore / conversationOnDisk cases.
// Needs NIGHT-REQUESTS REQ S5-SESS-1 (planner init taking the profile store); not compiled until `S5_RESTORE_SEAMS` is defined.

struct BackendFoundationTestsS5SessionsResolver: BackendProviderLaunchResolver {
    var readiness: BackendLaunchReadiness { .ready }
    func loginPath() async throws -> String { "/usr/bin" }
    func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
        let provider = input.provider ?? "claude"
        let canContinue = provider == "claude" || provider == "codex"
        return BackendProviderSpec(id: provider, command: "/fixture/" + provider, args: [], resumeArgs: canContinue ? ["--continue"] : [])
    }
}

struct BackendFoundationTestsS5SessionsWorld {
    let fixture: BackendFoundationTestsAccountsFixture
    let planner: BackendSessionRestorePlanner
    static let uuid1 = "11111111-1111-4111-8111-111111111111"
    static let uuid2 = "22222222-2222-4222-8222-222222222222"

    init(_ fixture: BackendFoundationTestsAccountsFixture) {
        self.fixture = fixture
        let context = BackendSessionRestoreContext(readiness: .ready) { device, folder in .init(deviceKey: device, folder: folder) }
        planner = BackendSessionRestorePlanner(profiles: fixture.profiles, providers: BackendFoundationTestsS5SessionsResolver(), context: context)
    }
    /// A real folder under the scratch root.
    func folder(_ name: String) throws -> String {
        let url = fixture.root.resolvingSymlinksInPath().appendingPathComponent("work-" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
    func saved(_ cwd: String, provider: String = "claude", profile: String? = nil, lastSeen: Double = 1_000,
               extra: [NativeRPCValue.Field] = []) throws -> BackendSessionSaved {
        try BackendSessionSaved(.object([.init("cwd", .string(cwd)), .init("provider", .string(provider)),
            .init("profileId", profile.map(NativeRPCValue.string) ?? .null), .init("cols", .number(100)), .init("rows", .number(30)),
            .init("lastSeenAt", .number(lastSeen))] + extra))
    }
    /// A transcript in the config directory the planner will use for this session.
    @discardableResult
    func transcript(for session: BackendSessionSaved, id: String = uuid1, body: String = "{\"type\":\"user\"}\n") async throws -> String {
        let config = try await planner.configDirectory(session)
        try writeTranscript(config: config, cwd: session.cwd, id: id, body: body)
        return config
    }
    func writeTranscript(config: String, cwd: String, id: String, body: String) throws {
        let dir = URL(fileURLWithPath: config).appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(cwd))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: dir.appendingPathComponent(id + ".jsonl"))
    }
    /// Legacy "continue the latest" planning, which is what the TS planRestore does.
    func plan(_ sessions: [BackendSessionSaved]) async -> [BackendSessionRestoreDecision] { await planner.plan(sessions, exact: false) }
}

func BackendFoundationTestsS5SessionsWithWorld(_ body: (BackendFoundationTestsS5SessionsWorld) async throws -> Void) async throws {
    try await BackendFoundationTestsAccountsWithFixture { fixture in try await body(BackendFoundationTestsS5SessionsWorld(fixture)) }
}

@Suite("S5 sessions: restore plan (session-restore.test.ts planRestore)")
struct BackendFoundationTestsS5SessionsRestorePlan {
    private func outcomes(_ plan: [BackendSessionRestoreDecision]) -> [BackendSessionRestoreDecision.Outcome] { plan.map(\.outcome) }

    // TS session-restore.test.ts:78
    @Test func continuesSessionWhoseConversationIsOnDisk() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let session = try world.saved(try world.folder("one")); try await world.transcript(for: session)
            #expect(outcomes(await world.plan([session])) == [.resume])
        }
    }
    // TS session-restore.test.ts:97
    @Test func carriesWhatTheDiskSaidOnlyWhenAsked() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("carry")
            let found = try world.saved(cwd); try await world.transcript(for: found)
            #expect(await world.plan([found])[0].conversation == .found)
            let empty = try world.saved(try world.folder("empty"))
            #expect(await world.plan([empty])[0].conversation == BackendSessionRestoreDecision.Conversation.none)
            let codex = try world.saved(cwd, provider: "codex")
            #expect(await world.plan([codex])[0].conversation == .unknown)
            let gone = try world.saved("/no/such/folder-s5")
            #expect(await world.plan([gone])[0].conversation == nil)
            let shell = try world.saved(cwd, provider: "shell")
            #expect(await world.plan([shell])[0].conversation == nil)
        }
    }
    // TS session-restore.test.ts:114
    @Test func startsCleanWhenTheConversationIsGone() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let plan = await world.plan([try world.saved(try world.folder("clean"))])
            #expect(outcomes(plan) == [.fresh])
        }
    }
    // TS session-restore.test.ts:114 (reason half)
    @Test func cleanStartReasonWording() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let plan = await world.plan([try world.saved(try world.folder("clean2"))])
            #expect(plan[0].reason.contains("no earlier conversation"))
        }
    }
    // TS session-restore.test.ts:126
    @Test func noTabForAFolderThatIsGone() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let plan = await world.plan([try world.saved("/no/such/folder-s5")])
            #expect(outcomes(plan) == [.skip]); #expect(plan[0].reason.contains("folder"))
        }
    }
    // TS session-restore.test.ts:132 — the TS probe spy is not observable; the observable half is that a gone folder with a transcript elsewhere never reports a conversation.
    @Test func foldersAreAskedAboutFirst() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let live = try world.saved(try world.folder("first")); try await world.transcript(for: live)
            let gone = try world.saved("/no/such/folder-s5-first")
            let plan = await world.plan([gone])
            #expect(plan[0].outcome == .skip); #expect(plan[0].conversation == nil)
        }
    }
    // TS session-restore.test.ts:142
    @Test func providerWithNoContinueFlagStartsCleanNotFailed() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let plan = await world.plan([try world.saved(try world.folder("shell"), provider: "shell")])
            #expect(outcomes(plan) == [.fresh]); #expect(plan[0].reason.contains("no way to continue"))
        }
    }
    // TS session-restore.test.ts:151
    @Test func agentWithUnreadableHistoryIsTakenAtItsWord() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let codexSession = try world.saved(try world.folder("codex"), provider: "codex")
            let codexPlan = await world.plan([codexSession])
            #expect(outcomes(codexPlan) == [.resume])
        }
    }
    // TS session-restore.test.ts:162
    @Test func onlyOneTabPerFolderAndItIsTheOneUsedLast() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("same")
            let older = try world.saved(cwd, lastSeen: 10), newer = try world.saved(cwd, lastSeen: 20)
            try await world.transcript(for: older)
            let plan = await world.plan([older, newer])
            #expect(outcomes(plan) == [.fresh, .resume]); #expect(plan[1].session == newer)
        }
    }
    // TS session-restore.test.ts:175
    @Test func tabOrderKeptWhenContinuingTabIsNotFirst() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let a = try world.folder("a"), b = try world.folder("b")
            let first = try world.saved(a, lastSeen: 5), second = try world.saved(b, lastSeen: 50), third = try world.saved(a, lastSeen: 9)
            try await world.transcript(for: first); try await world.transcript(for: second)
            let plan = await world.plan([first, second, third])
            #expect(plan.map(\.session) == [first, second, third]); #expect(outcomes(plan) == [.fresh, .resume, .resume])
        }
    }
    // TS session-restore.test.ts:184
    @Test func everyFolderContinuesItsOwnConversation() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            var sessions: [BackendSessionSaved] = []
            for name in ["a", "b", "c"] { let s = try world.saved(try world.folder(name)); try await world.transcript(for: s); sessions.append(s) }
            #expect(outcomes(await world.plan(sessions)) == [.resume, .resume, .resume])
        }
    }
    // TS session-restore.test.ts:200
    @Test func shellTabCannotTakeAClaimItCannotUse() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("shellclaim")
            let shell = try world.saved(cwd, provider: "shell", lastSeen: 100), claude = try world.saved(cwd, lastSeen: 50)
            try await world.transcript(for: claude)
            let plan = await world.plan([shell, claude])
            #expect(outcomes(plan) == [.fresh, .resume]); #expect(plan[1].session == claude)
        }
    }
    // TS session-restore.test.ts:215
    @Test func twoAgentsInOneFolderEachContinueTheirOwn() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("agents")
            let claude = try world.saved(cwd, lastSeen: 10), codex = try world.saved(cwd, provider: "codex", lastSeen: 20)
            try await world.transcript(for: claude)
            #expect(outcomes(await world.plan([claude, codex])) == [.resume, .resume])
        }
    }
    // TS session-restore.test.ts:229
    @Test func twoProfilesInOneFolderEachContinueTheirOwn() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let work = try await world.fixture.create("work"), personal = try await world.fixture.create("personal")
            let cwd = try world.folder("profiles")
            let a = try world.saved(cwd, profile: work.id, lastSeen: 10), b = try world.saved(cwd, profile: personal.id, lastSeen: 20)
            try await world.transcript(for: a); try await world.transcript(for: b, id: BackendFoundationTestsS5SessionsWorld.uuid2)
            #expect(outcomes(await world.plan([a, b])) == [.resume, .resume])
        }
    }
    // TS session-restore.test.ts:242
    @Test func stillOnlyOneTabWhenTheStoreIsShared() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let work = try await world.fixture.create("work"); let cwd = try world.folder("shared")
            let a = try world.saved(cwd, profile: work.id, lastSeen: 10), b = try world.saved(cwd, profile: work.id, lastSeen: 20)
            try await world.transcript(for: a)
            #expect(outcomes(await world.plan([a, b])) == [.fresh, .resume])
        }
    }
    // TS session-restore.test.ts:256 — observable half: a conversation only in the profile's own directory is found.
    @Test func asksInTheDirectoryTheSessionActuallyUses() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let work = try await world.fixture.create("work"); let cwd = try world.folder("ownstore")
            let session = try world.saved(cwd, profile: work.id)
            let config = try await world.transcript(for: session)
            #expect(NativeTranscriptPaths.canonical(config) == NativeTranscriptPaths.canonical(work.configDir))
            #expect(outcomes(await world.plan([session])) == [.resume])
            let plain = try world.saved(cwd)
            #expect(outcomes(await world.plan([plain])) == [.fresh])
        }
    }
    // TS session-restore.test.ts:276
    @Test func carriesTheStoreItAskedAbout() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let work = try await world.fixture.create("work")
            let plan = await world.plan([try world.saved(try world.folder("store"), profile: work.id), try world.saved("/gone-s5"),
                                         try world.saved(try world.folder("storeshell"), provider: "shell")])
            #expect(plan[0].configDirectory == work.configDir)
            #expect(plan[1].configDirectory == nil); #expect(plan[2].configDirectory == nil)
        }
    }
    // TS session-restore.test.ts:299 (length half)
    @Test func everyDecisionHasAReadableReason() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let plan = await world.plan([try world.saved("/gone-s5"), try world.saved(try world.folder("here")), try world.saved(try world.folder("sh"), provider: "shell")])
            for decision in plan { #expect(decision.reason.count > 12) }
        }
    }
    // TS session-restore.test.ts:299 (/^[a-z]/ half)
    @Test func reasonsStartLowerCase() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let plan = await world.plan([try world.saved("/gone-s5"), try world.saved(try world.folder("here2"))])
            for decision in plan { #expect(decision.reason.range(of: "^[a-z]", options: .regularExpression) != nil) }
        }
    }
}

@Suite("S5 sessions: conversation on disk (session-restore.test.ts conversationOnDisk)")
struct BackendFoundationTestsS5SessionsConversationOnDisk {
    // TS session-restore.test.ts:322 — TS names the transcript a1b2c3d4.jsonl.
    @Test func findsTranscriptNamedLikeTheTSFixture() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let session = try world.saved(try world.folder("tsname"))
            let config = world.fixture.root.appendingPathComponent("claude-config").path
            try world.writeTranscript(config: config, cwd: session.cwd, id: "a1b2c3d4", body: "{\"type\":\"user\"}\n")
            #expect(try await world.planner.conversation(session, config: config) == .found)
        }
    }
    // TS session-restore.test.ts:322 — same case with a UUID-named transcript.
    @Test func findsARealTranscript() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let session = try world.saved(try world.folder("real"))
            let config = world.fixture.root.appendingPathComponent("claude-config").path
            try world.writeTranscript(config: config, cwd: session.cwd, id: BackendFoundationTestsS5SessionsWorld.uuid1, body: "{\"type\":\"user\"}\n")
            #expect(try await world.planner.conversation(session, config: config) == .found)
        }
    }
    // TS session-restore.test.ts:331
    @Test func doesNotCountATranscriptNeverWrittenTo() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let session = try world.saved(try world.folder("emptyfile"))
            let config = world.fixture.root.appendingPathComponent("claude-config-empty").path
            try world.writeTranscript(config: config, cwd: session.cwd, id: BackendFoundationTestsS5SessionsWorld.uuid1, body: "")
            #expect(try await world.planner.conversation(session, config: config) == BackendSessionRestoreDecision.Conversation.none)
        }
    }
    // TS session-restore.test.ts:342
    @Test func noneForAFolderNeverUsed() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let session = try world.saved(try world.folder("never"))
            let config = world.fixture.root.appendingPathComponent("claude-config-missing").path
            #expect(try await world.planner.conversation(session, config: config) == BackendSessionRestoreDecision.Conversation.none)
        }
    }
    // TS session-restore.test.ts:348
    @Test func refusesToGuessForAnAgentWhoseHistoryItCannotRead() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let config = world.fixture.root.appendingPathComponent("claude-config").path, cwd = try world.folder("guess")
            #expect(try await world.planner.conversation(try world.saved(cwd, provider: "codex"), config: config) == .unknown)
            #expect(try await world.planner.conversation(try world.saved(cwd, provider: "shell"), config: config) == .unknown)
        }
    }
    // TS session-restore.test.ts:354
    @Test func readsTheProfileItIsGivenNotTheDefaultInstall() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("profiled"), session = try world.saved(cwd)
            let profileDir = world.fixture.root.appendingPathComponent("profile-work").path
            let defaultDir = world.fixture.root.appendingPathComponent("profile-default").path
            try world.writeTranscript(config: profileDir, cwd: cwd, id: BackendFoundationTestsS5SessionsWorld.uuid1, body: "{\"type\":\"user\"}\n")
            try FileManager.default.createDirectory(atPath: defaultDir + "/projects/" + NativeTranscriptPaths.encodeProjectPath(cwd), withIntermediateDirectories: true)
            #expect(try await world.planner.conversation(session, config: profileDir) == .found)
            #expect(try await world.planner.conversation(session, config: defaultDir) == BackendSessionRestoreDecision.Conversation.none)
        }
    }
}
