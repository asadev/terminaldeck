import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Lane S5. Ports src/main/session-restore.test.ts restoreOpenSessions / personalSessions cases and the behavioural half of the
// "restoring is wired to launch" block. Needs NIGHT-REQUESTS REQ S5-SESS-1; not compiled until `S5_RESTORE_SEAMS` is defined.

struct BackendFoundationTestsS5SessionsRefusal: LocalizedError, Sendable {
    var errorDescription: String? { "node-pty said no" }
}

actor BackendFoundationTestsS5SessionsStarter: BackendRestoreSessionStarting {
    private(set) var inputs: [BackendCreateSessionInput] = []
    private(set) var contexts: [BackendLaunchContext] = []
    private let failing: Set<String>
    init(failing: Set<String> = []) { self.failing = failing }
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool) async throws -> BackendSessionMeta {
        if failing.contains(input.cwd) { throw BackendFoundationTestsS5SessionsRefusal() }
        inputs.append(input); contexts.append(context)
        return BackendFoundationTestsSessionsFixtures.meta("session-\(inputs.count)", cwd: input.cwd, provider: input.provider ?? "claude")
    }
    func liveSessions() async -> [BackendSessionMeta] { [] }
}

final class BackendFoundationTestsS5SessionsEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var restoredValue: [[BackendSessionRestoreDecision]] = []
    private var heldValue = 0
    func record(_ event: BackendSessionLifecycleEvent) {
        lock.lock(); defer { lock.unlock() }
        if case .restored(let decisions) = event { restoredValue.append(decisions) }
        if case .held = event { heldValue += 1 }
    }
    var restored: [[BackendSessionRestoreDecision]] { lock.lock(); defer { lock.unlock() }; return restoredValue }
    var heldEvents: Int { lock.lock(); defer { lock.unlock() }; return heldValue }
}

struct BackendFoundationTestsS5SessionsCoordinatorWorld {
    let world: BackendFoundationTestsS5SessionsWorld
    let store: NativeStateStore
    let starter: BackendFoundationTestsS5SessionsStarter
    let sink = BackendFoundationTestsS5SessionsEvents()
    let coordinator: BackendSessionRestoreCoordinator

    /// `sessions` are written to the store before the ledger starts, as a previous run would have left them.
    init(_ world: BackendFoundationTestsS5SessionsWorld, sessions: [BackendSessionSaved], failing: Set<String> = [],
         excluded: [String] = [], restoreEnabled: Bool = true) async throws {
        self.world = world
        store = NativeStateStore(initialState: NativeStateStore.defaults)
        try await store.setOpenSessions(sessions.map(\.raw))
        try await store.startSessionLedger()
        if !restoreEnabled { _ = try await store.setPreferences(.object([.init("restoreSessions", .bool(false))])) }
        starter = BackendFoundationTestsS5SessionsStarter(failing: failing)
        let sink = self.sink
        let context = BackendSessionRestoreContext(readiness: .ready) { device, folder in .init(deviceKey: device, folder: folder) }
        coordinator = BackendSessionRestoreCoordinator(starter: starter, planner: world.planner, store: store, context: context,
            excludedAppWorkingDirectories: excluded, emit: { sink.record($0) })
    }
}

extension BackendFoundationTestsS5SessionsWorld {
    /// Saved tab with a unique stable key so the ledger migration leaves it alone.
    func tab(_ cwd: String, _ key: String, provider: String = "claude", profile: String? = nil, conversation: String? = nil,
             extra: [NativeRPCValue.Field] = []) throws -> BackendSessionSaved {
        var fields: [NativeRPCValue.Field] = [.init("tabKey", .string(key))] + extra
        if let conversation { fields.append(.init("agentSessionId", .string(conversation))) }
        return try saved(cwd, provider: provider, profile: profile, extra: fields)
    }
}

@Suite("S5 sessions: restore driver (session-restore.test.ts restoreOpenSessions)")
struct BackendFoundationTestsS5SessionsRestoreDriver {
    // TS session-restore.test.ts:578
    @Test func passesResumeOnlyForSessionsThePlanSaidToContinue() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let a = try world.tab(try world.folder("a"), "k-a", conversation: BackendFoundationTestsS5SessionsWorld.uuid1)
            let b = try world.tab(try world.folder("b"), "k-b", provider: "shell")
            try await world.transcript(for: a)
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [a, b])
            _ = try await run.coordinator.restore()
            let inputs = await run.starter.inputs
            #expect(inputs.map(\.cwd) == [a.cwd, b.cwd]); #expect(inputs.map { $0.resume == true } == [true, false])
        }
    }
    // TS session-restore.test.ts:590
    @Test func spawnsNothingForASkippedSession() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let gone = try world.tab("/no/such/folder-s5", "k-gone", provider: "shell")
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [gone])
            let result = try await run.coordinator.restore()
            #expect(await run.starter.inputs.isEmpty); #expect(result.started.isEmpty)
        }
    }
    // TS session-restore.test.ts:597 — the starter's returned metas are what the restore hands back (the announcement itself belongs to the lifecycle coordinator, not testable here).
    @Test func resultStartedIsEverySessionItStarted() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let a = try world.tab(try world.folder("a"), "k-a", provider: "shell"), b = try world.tab(try world.folder("b"), "k-b", provider: "shell")
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [a, b])
            let result = try await run.coordinator.restore()
            #expect(result.started.count == 2); #expect(result.started.map(\.cwd) == [a.cwd, b.cwd])
        }
    }
    // TS session-restore.test.ts:607
    @Test func eachTabComesBackAsTheTabItWas() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let cwd = try world.folder("w")
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world,
                sessions: [try world.tab(cwd, "k-left", provider: "shell"), try world.tab(cwd, "k-right", provider: "shell")])
            _ = try await run.coordinator.restore()
            #expect(await run.starter.inputs.map(\.tabKey) == ["k-left", "k-right"])
        }
    }
    // TS session-restore.test.ts:634
    @Test func profileAndTerminalSizeCarriedThrough() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let work = try await world.fixture.create("work", provider: "codex")
            let session = try world.tab(try world.folder("size"), "k-size", provider: "codex", profile: work.id,
                                        conversation: BackendFoundationTestsS5SessionsWorld.uuid1, extra: [.init("cols", .number(173)), .init("rows", .number(51))])
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [session])
            _ = try await run.coordinator.restore()
            let input = try #require(await run.starter.inputs.first)
            #expect(input.profileId == work.id); #expect(input.cols == 173); #expect(input.rows == 51); #expect(input.provider == "codex")
        }
    }
    // TS session-restore.test.ts:700
    @Test func spawnGetsTheDeviceToReconfineFor() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let session = try world.tab(try world.folder("dev"), "k-dev", provider: "shell", extra: [.init("confineDeviceId", .string("phone-7"))])
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [session])
            _ = try await run.coordinator.restore()
            #expect(await run.starter.contexts.first?.deviceBoundary?.deviceKey == "phone-7")
            let wire = try NativeRPCValue.parseJSON(JSONEncoder().encode(try #require(await run.starter.inputs.first)))
            #expect(!wire.has("confineDeviceId")); #expect(!wire.has("deviceId"))
        }
    }
    // TS session-restore.test.ts:715
    @Test func keyboardTabAsksForNoReconfinement() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [try world.tab(try world.folder("kb"), "k-kb", provider: "shell")])
            _ = try await run.coordinator.restore()
            #expect(await run.starter.contexts.first?.deviceBoundary == nil)
        }
    }
    // TS session-restore.test.ts:723 — TS has three resume tabs; Swift's start-clean shell tabs keep the test free of transcript fixtures.
    @Test func keepsGoingWhenOneSessionRefusesToStart() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let a = try world.folder("a"), broken = try world.folder("broken"), c = try world.folder("c")
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world,
                sessions: [try world.tab(a, "k-a", provider: "shell"), try world.tab(broken, "k-b", provider: "shell"), try world.tab(c, "k-c", provider: "shell")],
                failing: [broken])
            let result = try await run.coordinator.restore()
            #expect(result.started.count == 2)
            #expect(result.decisions.map(\.outcome) == [.fresh, .failed, .fresh])
            #expect(result.decisions[1].reason.contains("node-pty said no"))
        }
    }
    // TS session-restore.test.ts:738
    @Test func startsNothingWhenTheSettingIsOff() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world,
                sessions: [try world.tab(try world.folder("off"), "k-off", provider: "shell")], restoreEnabled: false)
            let result = try await run.coordinator.restore()
            #expect(await run.starter.inputs.isEmpty); #expect(run.sink.restored.isEmpty); #expect(result.started.isEmpty)
        }
    }
    // TS session-restore.test.ts:786
    @Test func reportsOnceWithEveryDecisionIncludingFailures() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let a = try world.folder("a"), broken = try world.folder("broken")
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world,
                sessions: [try world.tab(a, "k-a", provider: "shell"), try world.tab(broken, "k-b", provider: "shell")], failing: [broken])
            _ = try await run.coordinator.restore()
            #expect(run.sink.restored.count == 1); #expect(run.sink.restored[0].map(\.outcome) == [.fresh, .failed])
        }
    }
    // TS session-restore.test.ts:958 (behavioural half) — a skipped or failed session is held, not forgotten.
    @Test func sessionsThatDidNotComeBackAreHeld() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let gone = try world.tab("/no/such/folder-s5", "k-gone", provider: "shell")
            let broken = try world.tab(try world.folder("broken"), "k-broken", provider: "shell")
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [gone, broken], failing: [broken.cwd])
            _ = try await run.coordinator.restore()
            let held = try await run.store.heldSessions()
            #expect(Set(held.map { $0.saved["tabKey"].string }) == ["k-gone", "k-broken"])
        }
    }
    // TS session-restore.test.ts:979 (behavioural half) — the window is told on every restore, not only the first.
    @Test func windowToldAboutHeldOnEveryRestore() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [try world.tab("/no/such/folder-s5", "k-gone", provider: "shell")])
            _ = try await run.coordinator.restore(); _ = try await run.coordinator.restore()
            #expect(run.sink.heldEvents == 2)
        }
    }
    // TS session-restore.test.ts:899 (behavioural half) — Try again plans with the same questions: still-missing folder stays held, a reachable one starts and is released.
    @Test func tryAgainAsksTheSameQuestions() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let gone = try world.tab("/no/such/folder-s5", "k-gone", provider: "shell")
            let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: [gone])
            _ = try await run.coordinator.restore()
            let key = try #require(await run.store.heldSessions().first?.key)
            let remaining = try await run.coordinator.retryHeld(key)
            #expect(remaining.count == 1); #expect(await run.starter.inputs.isEmpty)
            let forgotten = try await run.coordinator.forgetHeld(key)
            #expect(forgotten.isEmpty)
        }
    }
}

@Suite("S5 sessions: copilot sessions are not restored as tabs (session-restore.test.ts personalSessions)")
struct BackendFoundationTestsS5SessionsPersonalSessions {
    private func restored(_ world: BackendFoundationTestsS5SessionsWorld, _ cwds: [String], excluded: [String]) async throws -> BackendSessionRestoreCoordinator.Result {
        let sessions = try cwds.enumerated().map { try world.tab($0.element, "k-\($0.offset)", provider: "shell") }
        let run = try await BackendFoundationTestsS5SessionsCoordinatorWorld(world, sessions: sessions, excluded: excluded)
        return try await run.coordinator.restore()
    }
    // TS session-restore.test.ts:462
    @Test func dropsTheCopilotsOwnSessionsHoweverManyThereAre() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let copilot = try world.folder("copilot"), project = try world.folder("project")
            let result = try await restored(world, [project, copilot, copilot], excluded: [copilot])
            #expect(result.decisions.map(\.session.cwd) == [project])
        }
    }
    // TS session-restore.test.ts:473
    @Test func dropsAnythingUnderThatFolder() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let copilot = try world.folder("copilot"); let memory = copilot + "/memory"
            try FileManager.default.createDirectory(atPath: memory, withIntermediateDirectories: true)
            #expect(try await restored(world, [memory], excluded: [copilot]).decisions.isEmpty)
        }
    }
    // TS session-restore.test.ts:479
    @Test func keepsEverySessionWhenNothingToExclude() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let a = try world.folder("a"), b = try world.folder("b"), copilot = try world.folder("copilot")
            #expect(try await restored(world, [a, b], excluded: []).decisions.count == 2)
            #expect(try await restored(world, [a, b], excluded: [copilot]).decisions.count == 2)
        }
    }
    // TS session-restore.test.ts:485 — a WSL path is not a Mac folder, so it is planned (and skipped as unreachable) rather than dropped.
    @Test func keepsASessionWhosePathResolvesNowhereNearTheExclusion() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let result = try await restored(world, ["/home/asad/ClaudeKiwi"], excluded: [try world.folder("copilot")])
            #expect(result.decisions.count == 1)
        }
    }
    // TS session-restore.test.ts:492
    @Test func neverWidensBeyondTheFoldersItIsGiven() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let workspace = try world.folder("workspace")
            #expect(try await restored(world, [workspace], excluded: [try world.folder("copilot")]).decisions.count == 1)
        }
    }
}
