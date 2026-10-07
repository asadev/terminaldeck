import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Lane S6 / cluster C4: src/main/host-core*.test.ts, ported against the Swift
// launch path (BackendSessionLauncher + BackendNativeLedger + the real
// BackendNativeInstructions / BackendNativeProviders). Provider, account and
// confinement resolvers are fakes. The only processes are inert `sleep`/`echo`
// children behind the real PTY manager, killed at the end of every case.

private struct S6C4Call: Sendable {
    let command: String
    let args: [String]
    let boundary: BackendDeviceBoundary?
    let fence: String?
}

private final class S6C4Confinement: BackendConfinementLaunchResolver, @unchecked Sendable {
    let readiness: BackendLaunchReadiness = .ready
    private let lock = NSLock()
    private var recorded: [S6C4Call] = []
    private var enforcing = true
    private var failure: (any Error)?
    var calls: [S6C4Call] { lock.withLock { recorded } }
    func set(enforcing: Bool) { lock.withLock { self.enforcing = enforcing } }
    func set(failure: (any Error)?) { lock.withLock { self.failure = failure } }
    func resolve(command: String, args: [String], input: BackendCreateSessionInput, account: BackendAccountLaunch,
                 context: BackendLaunchContext) async throws -> BackendConfinedLaunch {
        let (enforce, error) = lock.withLock { () -> (Bool, (any Error)?) in
            recorded.append(S6C4Call(command: command, args: args, boundary: context.deviceBoundary, fence: context.appFenceID))
            return (enforcing, failure)
        }
        if let error { throw error }
        let confined = context.deviceBoundary != nil || context.appFenceID != nil
        return BackendConfinedLaunch(command: command, args: args, hostCwd: nil,
            deviceKey: context.deviceBoundary?.deviceKey, enforcedBoundary: enforce && confined)
    }
}

private final class S6C4Accounts: BackendAccountLaunchResolver, @unchecked Sendable {
    let readiness: BackendLaunchReadiness = .ready
    private let lock = NSLock()
    private var identity: BackendAccountIdentity?
    private var abandoned = 0
    var abandonCount: Int { lock.withLock { abandoned } }
    func set(profile: BackendAccountIdentity?) { lock.withLock { identity = profile } }
    func resolve(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, loginPath: String,
                 context: BackendLaunchContext) async throws -> BackendAccountLaunch {
        BackendAccountLaunch(profile: lock.withLock { identity }, environment: [:], path: "/usr/bin:/bin")
    }
    func continuingConversationID(_ input: BackendCreateSessionInput, account: BackendAccountLaunch,
                                  live: [BackendSessionMeta]) async throws -> String? { nil }
    func bind(_ account: BackendAccountLaunch, session: BackendSessionMeta) async throws {}
    func abandon(_ account: BackendAccountLaunch) async { lock.withLock { abandoned += 1 } }
    func exited(sessionID: String) async {}
}

private struct S6C4Providers: BackendProviderLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    let table: [String: BackendProviderSpec]
    func loginPath() async throws -> String { "/usr/bin:/bin" }
    func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
        guard let id = input.provider, let spec = table[id] else { throw BackendSessionFailure.providerMismatch }
        return spec
    }
    /// Inert children: a shell that sleeps, or echo that exits at once.
    static var standard: S6C4Providers {
        let sleeper = ["-c", "sleep 30"]
        return S6C4Providers(table: [
            "shell": BackendProviderSpec(id: "shell", command: "/bin/sh", args: sleeper, resumeArgs: []),
            "claude": BackendProviderSpec(id: "claude", command: "/bin/sh", args: sleeper, resumeArgs: ["--continue"]),
            "codex": BackendProviderSpec(id: "codex", command: "/bin/sh", args: sleeper, resumeArgs: []),
            "custom:echo": BackendProviderSpec(id: "custom:echo", command: "/bin/echo", args: ["hello"], resumeArgs: []),
        ])
    }
}

private struct S6C4NoInstructions: BackendInstructionLaunchResolver {
    let readiness: BackendLaunchReadiness = .ready
    func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec, context: BackendLaunchContext) async throws -> [String] { [] }
}

private final class S6C4Rig: @unchecked Sendable {
    let root: URL
    let store = NativeStateStore()
    let manager: BackendPTYManager
    let confinement = S6C4Confinement()
    let accounts = S6C4Accounts()
    let launcher: BackendSessionLauncher

    init(instructions: any BackendInstructionLaunchResolver = S6C4NoInstructions()) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("S6C4-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:]) { _ in }
        self.manager = manager
        let ledger = try await BackendNativeLedger.activate(store: store, oldSessionOwnerDisabled: true)
        let dependencies = try BackendSessionLaunchDependencies(providers: S6C4Providers.standard, accounts: accounts,
            confinement: confinement, instructions: instructions, ledger: ledger)
        launcher = BackendSessionLauncher(manager: manager, dependencies: dependencies)
    }
    deinit { manager.killAll(); try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }
    func input(_ cwd: String, _ provider: String, cols: Int = 80, rows: Int = 24) -> BackendCreateSessionInput {
        BackendCreateSessionInput(cwd: cwd, cols: cols, rows: rows, provider: provider)
    }
    /// Every record currently written into openSessions.
    func remembered() async -> [NativeRPCValue] { await store.getOpenSessions() }
    func rememberedIn(_ cwd: String) async -> [NativeRPCValue] { await remembered().filter { $0["cwd"].string == cwd } }
}

final class BackendFoundationTestsS6C4HostCore: XCTestCase {
    private let composed = ["--mcp-config", "/state/copilot/deck-control.json", "--strict-mcp-config"]

    // MARK: host-core.agents.test.ts

    // host-core.agents.test.ts:154
    func testAddedAgentRunsAsThatAgentNotAShell() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let meta = try await rig.launcher.create(rig.input(try rig.folder("a"), "custom:echo"))
        XCTAssertEqual(meta.provider, "custom:echo"); XCTAssertNotEqual(meta.provider, "shell")
    }
    // host-core.agents.test.ts:185
    func testUnknownAgentIsRefusedAndNoSessionIsHandedBack() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let before = rig.manager.list().count
        do { _ = try await rig.launcher.create(rig.input(try rig.folder("a"), "custom:never-existed")); XCTFail("starting an agent that cannot run must not hand back a session") }
        catch {}
        XCTAssertEqual(rig.manager.list().count, before)
        XCTAssertTrue(rig.confinement.calls.isEmpty, "nothing may reach the spawn path")
    }
    // host-core.agents.test.ts:203
    // EXPECTED PARITY FAILURE: BackendNativeProviders.resolve throws the generic
    // providerMismatch sentence for an unknown custom agent; the TS sentence names
    // the agent, says "on this machine" and says it was "not started" (see
    // NIGHT-REQUESTS S6-C4-1).
    func testRefusalNamesTheAgentAndWhereItLooked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("S6C4-providers-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let providers = try BackendNativeProviders(store: NativeStateStore(), dataRoot: root, inheritedEnvironment: [:], home: root.path, runner: BackendCommandRunner())
        do {
            _ = try await providers.resolve(.init(cwd: root.path, provider: "custom:never-existed"), loginPath: root.path)
            XCTFail("expected a refusal")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("custom:never-existed"), message)
            XCTAssertTrue(message.contains("on this machine"), message)
            XCTAssertNotNil(message.range(of: "not started"), "the sentence has to say that nothing was started: " + message)
        }
    }
    // host-core.agents.test.ts:228
    func testShellStillStartsWhenAShellIsAsked() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let meta = try await rig.launcher.create(rig.input(try rig.folder("a"), "shell"))
        XCTAssertEqual(meta.provider, "shell")
    }
    // host-core.agents.test.ts (extra flags case, unlisted line): the launch's flags reach the process argv.
    func testExtraLaunchFlagsReachTheProcessItself() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        _ = try await rig.launcher.create(rig.input(try rig.folder("a"), "custom:echo"),
            context: BackendLaunchContext(extraArguments: composed, rememberTab: false))
        XCTAssertEqual(rig.confinement.calls.last?.args, ["hello"] + composed)
    }
    // host-core.agents.test.ts:273
    func testOrdinarySessionAddsNothingToItsArguments() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        _ = try await rig.launcher.create(rig.input(try rig.folder("a"), "custom:echo"))
        XCTAssertEqual(rig.confinement.calls.last?.args, ["hello"])
        XCTAssertFalse(rig.confinement.calls.last?.args.contains("--mcp-config") ?? true)
    }
    // host-core.agents.test.ts:287
    func testNoAccountIsRecordedWhenNoneWasIsolated() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let meta = try await rig.launcher.create(rig.input(try rig.folder("a"), "custom:echo"))
        XCTAssertNil(meta.profileId); XCTAssertNil(meta.profileName)
    }

    // MARK: host-core.remembered-account.test.ts

    // host-core.remembered-account.test.ts:17 (what the ledger is handed is the resolved account, not the empty request)
    func testRememberedTabCarriesTheAccountTheSessionResolvedTo() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        rig.accounts.set(profile: BackendAccountIdentity(id: "work", name: "Work"))
        let folder = try rig.folder("work-tab")
        _ = try await rig.launcher.create(rig.input(folder, "claude"))
        let record = await rig.rememberedIn(folder).first
        XCTAssertEqual(record?["profileId"].string, "work")
        rig.accounts.set(profile: BackendAccountIdentity(id: "system", name: "System"))
        let second = try rig.folder("system-tab")
        _ = try await rig.launcher.create(rig.input(second, "claude"))
        let secondRecord = await rig.rememberedIn(second).first
        XCTAssertEqual(secondRecord?["profileId"].string, "system")
        // A session with no account at all (a shell) keeps the request as it was: null.
        rig.accounts.set(profile: nil)
        let third = try rig.folder("shell-tab")
        _ = try await rig.launcher.create(rig.input(third, "shell"))
        let thirdRecord = await rig.rememberedIn(third).first
        XCTAssertEqual(thirdRecord?["profileId"], NativeRPCValue.null)
    }

    // MARK: host-core.copilot.test.ts

    // host-core.copilot.test.ts:86 and :117 (the launch decision input: composed flags or a fence mark the launch app-composed)
    func testLaunchesCarryingComposedArgumentsOrAFenceAreAppComposed() {
        XCTAssertTrue(BackendLaunchContext(extraArguments: composed).isAppComposed)
        XCTAssertTrue(BackendLaunchContext(appFenceID: "copilot-fence").isAppComposed)
        XCTAssertFalse(BackendLaunchContext().isAppComposed)
    }
    // host-core.copilot.test.ts:86
    func testAppComposedLaunchIsNotWrittenDownAsASessionSomebodyHadOpen() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let home = try rig.folder("copilot")
        _ = try await rig.launcher.create(rig.input(home, "shell"), context: BackendLaunchContext(extraArguments: composed, rememberTab: false))
        let remembered = await rig.rememberedIn(home)
        XCTAssertTrue(remembered.isEmpty, "a launch carrying flags the app composed was remembered as a tab")
    }
    // host-core.copilot.test.ts:103
    func testOrdinarySessionInTheSameFolderIsStillRemembered() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let shared = try rig.folder("copilot")
        _ = try await rig.launcher.create(rig.input(shared, "shell"))
        let remembered = await rig.rememberedIn(shared)
        XCTAssertEqual(remembered.count, 1)
    }
    // host-core.copilot.test.ts:117
    func testFencedLaunchIsNotWrittenDownEither() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let fenced = try rig.folder("fenced")
        _ = try await rig.launcher.create(rig.input(fenced, "shell"), context: BackendLaunchContext(appFenceID: "copilot-fence", rememberTab: false))
        let remembered = await rig.rememberedIn(fenced)
        XCTAssertTrue(remembered.isEmpty)
    }
    // host-core.copilot.test.ts:135
    func testSessionsThatDidNotComeBackAreWrittenBeforeTheOnesThatDid() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let live = try rig.folder("live-project")
        _ = try await rig.launcher.create(rig.input(live, "shell"))
        _ = try await rig.store.holdSession(heldRecord("/home/asad/ClaudeKiwi"), reason: "it could not be started again")
        let list = await rig.remembered()
        XCTAssertEqual(list.first?["cwd"].string, "/home/asad/ClaudeKiwi")
        // Written as the agent that was asked for, never downgraded to a shell.
        XCTAssertEqual(list.first?["provider"].string, "claude")
        XCTAssertTrue(list.contains { $0["cwd"].string == live })
    }
    // host-core.copilot.test.ts:166
    func testHeldSessionIsWrittenBackTheMomentItIsHeld() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        _ = try await rig.store.holdSession(heldRecord("/home/asad/ClaudeSpace"), reason: "it could not be started again")
        let list = await rig.remembered()
        XCTAssertTrue(list.contains { $0["cwd"].string == "/home/asad/ClaudeSpace" })
    }
    private func heldRecord(_ cwd: String) -> NativeRPCValue {
        .object([.init("cwd", .string(cwd)), .init("provider", .string("claude")), .init("profileId", .null),
                 .init("cols", .number(100)), .init("rows", .number(30)), .init("lastSeenAt", .number(1))])
    }
    // host-core.copilot.test.ts:204
    func testTabNameIsMintedPerSessionSoIdenticalSiblingsAreTwoTabs() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("two-tabs")
        let left = try await rig.launcher.create(rig.input(folder, "shell"))
        let right = try await rig.launcher.create(rig.input(folder, "shell"))
        let leftKey = try XCTUnwrap(left.tabKey), rightKey = try XCTUnwrap(right.tabKey)
        XCTAssertFalse(leftKey.isEmpty); XCTAssertFalse(rightKey.isEmpty); XCTAssertNotEqual(leftKey, rightKey)
        let keys = await rig.rememberedIn(folder).map { $0["tabKey"].string }
        XCTAssertEqual(keys, [leftKey, rightKey])
    }
    // host-core.copilot.test.ts:220
    func testTabNameIsTheOneItWasToldWhenARestoreIsPuttingATabBack() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("restored")
        var input = rig.input(folder, "shell"); input.tabKey = "k-from-last-launch"
        let meta = try await rig.launcher.create(input)
        XCTAssertEqual(meta.tabKey, "k-from-last-launch")
        let keys = await rig.rememberedIn(folder).map { $0["tabKey"].string }
        XCTAssertEqual(keys, ["k-from-last-launch"])
    }
    // host-core.copilot.test.ts:237 and host-core.restore-confined.test.ts:114 (replaces inherits the outgoing tab's name)
    func testTabNameFollowsTheTabThroughAnAccountSwitch() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("two-tabs")
        let before = try await rig.launcher.create(rig.input(folder, "shell"))
        var next = rig.input(folder, "shell"); next.replaces = before.id
        let after = try await rig.launcher.create(next)
        XCTAssertEqual(after.tabKey, before.tabKey)
    }
    // host-core.copilot.test.ts:258
    func testAppComposedSessionHasNoTabName() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let meta = try await rig.launcher.create(rig.input(try rig.folder("copilot"), "shell"),
            context: BackendLaunchContext(extraArguments: composed, rememberTab: false))
        XCTAssertNil(meta.tabKey)
        let wire = try NativeRPCValue.parseJSON(JSONEncoder().encode(meta))
        XCTAssertFalse(wire.has("tabKey"))
    }

    // MARK: host-core.restore-confined.test.ts (restorableTab / spawnReconfined)

    private func boundary(_ folder: String, _ key: String = "phone-7") -> BackendDeviceBoundary { BackendDeviceBoundary(deviceKey: key, folder: folder) }

    // restore-confined:31
    func testConfinedDeviceSessionGetsATabNameAndTheDeviceToReConfineFor() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("granted")
        let meta = try await rig.launcher.create(rig.input(folder, "claude"), context: BackendLaunchContext(deviceBoundary: boundary(folder)))
        XCTAssertFalse((meta.tabKey ?? "").isEmpty, "a confined session with no tab name is a session that cannot come back")
        let record = await rig.rememberedIn(folder).first
        XCTAssertEqual(record?["tabKey"].string, meta.tabKey)
        XCTAssertEqual(record?["confineDeviceId"].string, "phone-7")
    }
    // restore-confined:49
    func testLaunchTheAppComposedForItselfStillGetsNoNameAndNoDevice() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("fenced")
        let meta = try await rig.launcher.create(rig.input(folder, "claude"), context: BackendLaunchContext(appFenceID: "copilot", rememberTab: false))
        XCTAssertNil(meta.tabKey)
        let records = await rig.rememberedIn(folder)
        XCTAssertTrue(records.isEmpty)
    }
    // restore-confined:65, empty-id half (a confined session with absent id cannot be built in Swift: the boundary always has a key).
    // EXPECTED PARITY FAILURE: BackendNativeLedger.started writes a confineDeviceId of "" (NIGHT-REQUESTS S6-C4-2).
    func testConfinedSessionWithABlankDeviceIdIsNotRemembered() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("blank-device")
        _ = try await rig.launcher.create(rig.input(folder, "claude"), context: BackendLaunchContext(deviceBoundary: boundary(folder, "")))
        let records = await rig.rememberedIn(folder)
        XCTAssertTrue(records.isEmpty, "a confined session with deviceId \"\" must not be remembered")
    }
    // restore-confined:86
    func testTabOpenedAtTheKeyboardWithNoBoundaryIsRemembered() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("keyboard")
        let meta = try await rig.launcher.create(rig.input(folder, "claude"))
        XCTAssertFalse((meta.tabKey ?? "").isEmpty)
        let record = await rig.rememberedIn(folder).first
        XCTAssertEqual(record?["confineDeviceId"], NativeRPCValue.missing, "a session started here has nothing to re-confine")
    }
    // restore-confined:99
    func testRestoreReusesTheNameItIsHandedRatherThanMintingANewOne() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("granted")
        var input = rig.input(folder, "claude"); input.tabKey = "k-from-last-launch"
        let meta = try await rig.launcher.create(input, context: BackendLaunchContext(deviceBoundary: boundary(folder)))
        XCTAssertEqual(meta.tabKey, "k-from-last-launch")
        let record = await rig.rememberedIn(folder).first
        XCTAssertEqual(record?["confineDeviceId"].string, "phone-7")
    }
    // restore-confined:165 (the boundary is rebuilt and handed to the sandbox, not a bare command)
    func testReconfinedSpawnHandsTheSandboxTheBoundary() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let folder = try rig.folder("granted")
        let meta = try await rig.launcher.create(rig.input(folder, "claude"), context: BackendLaunchContext(deviceBoundary: boundary(folder)))
        XCTAssertEqual(rig.manager.list().map(\.id), [meta.id])
        XCTAssertEqual(rig.confinement.calls.count, 1)
        XCTAssertEqual(rig.confinement.calls.first?.boundary?.deviceKey, "phone-7")
        XCTAssertEqual(rig.confinement.calls.first?.boundary?.folder, folder)
        XCTAssertEqual(rig.accounts.abandonCount, 0)
    }
    // restore-confined:202
    func testRefusesBeforeSpawningWhenTheMachineHasNoBoundaryRightNow() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        rig.confinement.set(enforcing: false)
        let folder = try rig.folder("granted")
        do { _ = try await rig.launcher.create(rig.input(folder, "claude"), context: BackendLaunchContext(deviceBoundary: boundary(folder))); XCTFail("must refuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("enforced folder boundary"), error.localizedDescription) }
        XCTAssertTrue(rig.manager.list().isEmpty, "a session with no boundary must never be spawned")
        let records = await rig.rememberedIn(folder)
        XCTAssertTrue(records.isEmpty)
    }
    // restore-confined:230
    func testSandboxsOwnRefusalPropagatesAndNothingIsLeftBehind() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        rig.confinement.set(failure: BackendSessionFailure.unsupported("This session could not be confined to its folder: unshare denied"))
        let folder = try rig.folder("granted")
        do { _ = try await rig.launcher.create(rig.input(folder, "claude"), context: BackendLaunchContext(deviceBoundary: boundary(folder))); XCTFail("must refuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("could not be confined"), error.localizedDescription) }
        XCTAssertEqual(rig.accounts.abandonCount, 1, "the credential allocation outlived a spawn that never happened")
        XCTAssertTrue(rig.manager.list().isEmpty)
    }

    // MARK: host-core.pick-conversation.test.ts

    // pick-conversation:83 (argv half; the ledger keeps the old id so cancelling the list loses nothing)
    func testPickingStartsResumeWithNoIdBesideALiveTabAndKeepsEverythingTheTabHad() async throws {
        let rig = try await S6C4Rig(); defer { rig.manager.killAll() }
        let work = try rig.folder("work"), old = "44444444-4444-4444-8444-444444444444"
        _ = try await rig.launcher.create(rig.input(work, "claude"))
        var input = rig.input(work, "claude", cols: 100, rows: 30)
        input.resume = true; input.pickConversation = true; input.resumeConversationId = old
        input.tabKey = "kept-tab"; input.model = "sonnet"; input.deniedTools = ["WebFetch"]; input.noSkills = true
        let meta = try await rig.launcher.create(input)
        let args = try XCTUnwrap(rig.confinement.calls.last?.args)
        let index = try XCTUnwrap(args.firstIndex(of: "--resume"))
        XCTAssertTrue(index + 1 >= args.count || args[index + 1] != old)
        XCTAssertFalse(args.contains(old)); XCTAssertFalse(args.contains("--continue")); XCTAssertFalse(args.contains("--session-id"))
        XCTAssertNil(meta.agentSessionId)
        let record = try await rig.store.ledgerGet(meta.id)
        XCTAssertEqual(record["agentSessionId"].string, old); XCTAssertEqual(record["cwd"].string, work)
        XCTAssertEqual(record["model"].string, "sonnet"); XCTAssertEqual(record["deniedTools"], .array([.string("WebFetch")]))
        XCTAssertEqual(record["noSkills"].bool, true); XCTAssertEqual(record["tabKey"].string, "kept-tab")
    }

    // MARK: host-core.agent-instructions.test.ts (real BackendNativeInstructions)

    private func instructionRig() async throws -> S6C4Rig {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("S6C4-instructions-" + UUID().uuidString).resolvingSymlinksInPath()
        let directory = storage.appendingPathComponent("agent-instructions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Work on a branch.\nRun the tests before you finish.\n".utf8).write(to: directory.appendingPathComponent("builder.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: storage) }
        let rig = try await S6C4Rig(instructions: BackendNativeInstructions(storageRoot: storage))
        instructionStorage = storage
        return rig
    }
    private var instructionStorage: URL?
    // agent-instructions:102
    func testInstructionsReachClaudeBesideBlockedToolsAndAreRememberedForTheNextStart() async throws {
        let rig = try await instructionRig(); defer { rig.manager.killAll() }
        let project = try rig.folder("project")
        var input = rig.input(project, "claude"); input.deniedTools = ["WebFetch"]; input.agentInstructions = "builder"
        let tab = try await rig.launcher.create(input)
        let args = try XCTUnwrap(rig.confinement.calls.last?.args)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--disallowedTools")) + 1], "WebFetch")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--append-system-prompt-file")) + 1],
            try XCTUnwrap(instructionStorage).appendingPathComponent("agent-instructions/builder.md").path)
        let record = try await rig.store.ledgerGet(tab.id)
        XCTAssertEqual(record["deniedTools"], .array([.string("WebFetch")])); XCTAssertEqual(record["agentInstructions"].string, "builder")
    }
    // agent-instructions:118
    func testInstructionsReachCodexAsDeveloperInstructions() async throws {
        let rig = try await instructionRig(); defer { rig.manager.killAll() }
        var input = rig.input(try rig.folder("project"), "codex"); input.agentInstructions = "builder"
        _ = try await rig.launcher.create(input)
        let args = try XCTUnwrap(rig.confinement.calls.last?.args)
        // TS host-core.agent-instructions.test.ts:123 reads the `-c` after the agent's own arguments; this rig's
        // stand-in agent is `/bin/sh -c "sleep 30"`, so its own `-c` comes first and the instructions' is the last one.
        XCTAssertEqual(args[try XCTUnwrap(args.lastIndex(of: "-c")) + 1], #"developer_instructions="Work on a branch.\nRun the tests before you finish.\n""#)
        XCTAssertFalse(args.contains("--append-system-prompt-file"))
    }
    // agent-instructions:130. The refusal wording is asserted exactly as the TS test does; BackendFoundationTestsAgentsInstructions
    // already records the native wording differences as parity failures.
    func testInstructionsAreRefusedForAnAgentThatCannotTakeThemAndForAMissingFileWithNothingSpawned() async throws {
        let rig = try await instructionRig(); defer { rig.manager.killAll() }
        let project = try rig.folder("project")
        for (provider, id, text) in [("shell", "builder", "cannot be given standing instructions"), ("claude", "nobody", "missing or empty"), ("claude", "../remote", "not a task agent id")] {
            var input = rig.input(project, provider); input.agentInstructions = id
            do { _ = try await rig.launcher.create(input); XCTFail("expected refusal for " + id) }
            catch { XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription) }
        }
        XCTAssertTrue(rig.confinement.calls.isEmpty); XCTAssertTrue(rig.manager.list().isEmpty)
    }
    // agent-instructions:148
    func testInstructionsAreNeverAddedToASessionThatDidNotAsk() async throws {
        let rig = try await instructionRig(); defer { rig.manager.killAll() }
        _ = try await rig.launcher.create(rig.input(try rig.folder("project"), "claude"))
        XCTAssertFalse((rig.confinement.calls.last?.args ?? []).contains { $0.hasPrefix("--append-system-prompt") })
    }
}
