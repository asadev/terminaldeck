import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor BackendCopilotSessionTestDriver: BackendCopilotSessionDriving {
    struct Call: Sendable { let input: BackendCreateSessionInput; let fence: BackendCopilotSessionFence?; let arguments: [String] }
    private var calls: [Call] = []
    private var alive: Set<String> = []
    private var stopped: [String] = []
    private var hasAgent = true
    private var launchedProvider = "claude"
    private var launchProblem: String?
    private var signedState = "signed-in"
    private var signInReads = 0
    private var profileID = "system"
    private var profileName = "Default"
    func configure(agent: Bool? = nil, provider: String? = nil, error: String? = nil, signIn: String? = nil, profileID: String? = nil) {
        if let agent { hasAgent = agent }; if let provider { launchedProvider = provider }; launchProblem = error
        if let signIn { signedState = signIn }; if let profileID { self.profileID = profileID; profileName = profileID == "system" ? "Default" : "Work" }
    }
    func hasClaude() async throws -> Bool { hasAgent }
    func resolveProfile(projectPath: String) async throws -> BackendAccountProfile {
        BackendAccountProfile(id: profileID, name: profileName, provider: "claude", configDir: "/synthetic/.claude", system: profileID == "system", color: "#000000", createdAt: 0, lastUsedAt: nil, loginStore: nil, keptSlots: nil)
    }
    func signIn(profile: BackendAccountProfile) async throws -> (state: String, account: String?, plan: String?) { signInReads += 1; return (signedState, "a@b.c", "max") }
    func start(_ input: BackendCreateSessionInput, fence: BackendCopilotSessionFence?, extraArguments: [String]) async throws -> BackendSessionMeta {
        calls.append(.init(input: input, fence: fence, arguments: extraArguments))
        if let launchProblem { throw NativeRPCError(code: "launch", message: launchProblem) }
        let meta = BackendSessionMeta(id: "session-\(calls.count)", input: input, spawn: .init(provider: launchedProvider, command: "/bin/echo", args: extraArguments, path: "/bin"), now: Date(timeIntervalSince1970: 1))
        alive.insert(meta.id); return meta
    }
    func isAlive(_ sessionID: String) async -> Bool { alive.contains(sessionID) }
    func stop(_ sessionID: String) async throws { stopped.append(sessionID); alive.remove(sessionID) }
    func die() { alive.removeAll() }
    func snapshot() -> (calls: [Call], stopped: [String], signInReads: Int) { (calls, stopped, signInReads) }
}
private actor BackendCopilotSessionTestRecords: BackendCopilotSessionRecordsProviding {
    let recordPaths: BackendCopilotLayerRecords
    var held = true
    var measureCount = 0
    init(_ root: URL) throws {
        recordPaths = try .init(paths: ["routines", "routine-state.json", "hoot-log", "remote/remote-device-kinds.json", "remote/remote-auth.json", "remote/access-keys.json", "plugin-grants.json"].map { root.appendingPathComponent($0).path })
    }
    func paths(userData: String) async throws -> BackendCopilotLayerRecords { recordPaths }
    func measure(userData: String) async -> BackendCopilotSessionFenceMeasurement { measureCount += 1; return .init(fence: held ? .init() : nil, reason: held ? nil : "no mechanism here") }
    func disable() { held = false }
    func measurements() -> Int { measureCount }
}
private actor BackendCopilotSessionTestSelection {
    var value: NativeRPCValue = .null
    func read() -> NativeRPCValue { value }
    func set(_ path: String) { value = .string(path) }
}
private actor BackendCopilotSessionTestTools: BackendCopilotSessionToolProviding {
    private var prepared = 0
    private var bound: [String] = []
    private var abandoned = 0
    private var released: [String] = []
    private var tool = "sessions_list"
    func prepare() async throws -> BackendCopilotSessionTools? {
        prepared += 1
        return .init(configPath: "/synthetic/run-\(prepared)/deck-control.json", tools: [.init(wire: tool, tier: "read", title: "List")], leaseID: UUID())
    }
    func bind(_ tools: BackendCopilotSessionTools, sessionID: String) async throws { bound.append(sessionID) }
    func abandon(_ tools: BackendCopilotSessionTools) async { abandoned += 1 }
    func release(sessionID: String) async { released.append(sessionID) }
    func changeCatalogue() { tool = "log_note" }
    func snapshot() -> (prepared: Int, bound: [String], abandoned: Int, released: [String]) { (prepared, bound, abandoned, released) }
}
final class BackendCopilotSessionTests: XCTestCase {
    private func fixture(tools: (any BackendCopilotSessionToolProviding)? = nil) throws -> (URL, BackendCopilotSessionRuntime, BackendCopilotSessionTestDriver, BackendCopilotSessionTestRecords, BackendCopilotSessionTestSelection) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotSession-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let driver = BackendCopilotSessionTestDriver(), records = try BackendCopilotSessionTestRecords(root), selection = BackendCopilotSessionTestSelection()
        let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: root.path, chosenFolder: { await selection.read() }, driver: driver, records: records, tools: tools))
        return (root, runtime, driver, records, selection)
    }
    func testConcurrentEnsuresShareOneFreshProfileLaunchWithAppLayerBeforeSpawn() async throws {
        let (root, runtime, driver, records, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        async let a = runtime.ensure(); async let b = runtime.ensure(); async let c = runtime.ensure()
        let states = try await [a, b, c]
        XCTAssertEqual(Set(states.compactMap(\.sessionId)).count, 1)
        let snapshot = await driver.snapshot(); XCTAssertEqual(snapshot.calls.count, 1)
        let call = try XCTUnwrap(snapshot.calls.first)
        XCTAssertEqual(call.input.cwd, BackendCopilotPaths(userData: root.path).root); XCTAssertEqual(call.input.provider, "claude")
        XCTAssertEqual(call.input.cols, 120); XCTAssertEqual(call.input.rows, 30); XCTAssertEqual(call.input.resume, false); XCTAssertEqual(call.input.profileId, "system")
        XCTAssertEqual(call.arguments, ["--append-system-prompt-file", BackendCopilotPaths(userData: root.path).layer.composed])
        XCTAssertEqual(call.fence?.id, BackendMacConfinement.recordsFenceID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: call.arguments[1])); XCTAssertFalse(call.arguments.contains { $0.contains("permission") || $0.contains("dangerously") })
        let measured = await records.measurements(); XCTAssertEqual(measured, 1)
        let state = try XCTUnwrap(states.first); XCTAssertEqual(state.status, .running); XCTAssertEqual(state.profile?.id, "system"); XCTAssertTrue(state.records.enforced)
        XCTAssertEqual(BackendCopilotInspect.readActionLog(state.paths).rows.map(\.action), ["home.created", "session.started"])
        let again = try await runtime.ensure(); XCTAssertEqual(again.sessionId, state.sessionId)
        let finalCalls = await driver.snapshot(); XCTAssertEqual(finalCalls.calls.count, 1)
    }
    func testDeathIdentityStopAndRestartFollowOneID() async throws {
        let (root, runtime, driver, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await runtime.ensure(), id = try XCTUnwrap(first.sessionId)
        let known = runtime.isCopilotSession(id), unknown = runtime.isCopilotSession("someone-else")
        XCTAssertTrue(known); XCTAssertFalse(unknown)
        await driver.die()
        let stale = runtime.isCopilotSession(id); XCTAssertTrue(stale)
        let dead = try await runtime.state(); XCTAssertEqual(dead.status, .stopped); XCTAssertFalse(dead.records.enforced); XCTAssertNil(dead.folder.runningIn)
        let second = try await runtime.ensure(); XCTAssertNotEqual(first.sessionId, second.sessionId)
        let old = runtime.isCopilotSession(id); XCTAssertFalse(old)
        let stopped = try await runtime.stop(); XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(BackendCopilotInspect.readActionLog(first.paths).rows.last?.action, "session.stopped")
        let calls = await driver.snapshot(); XCTAssertEqual(calls.stopped, [try XCTUnwrap(second.sessionId)])
    }
    func testRecordsFailOpenVisiblyAndRetainSevenPaths() async throws {
        let (root, runtime, _, records, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await records.disable()
        let state = try await runtime.ensure()
        XCTAssertEqual(state.status, .running); XCTAssertFalse(state.records.enforced); XCTAssertEqual(state.records.reason, "no mechanism here")
        XCTAssertEqual(state.records.paths.count, 7)
        let detail = try XCTUnwrap(BackendCopilotInspect.readActionLog(state.paths).rows.last?.detail)
        XCTAssertTrue(detail.contains("NOT held against it — no mechanism here")); XCTAssertTrue(detail.contains("no deck-control server is running"))
    }
    func testMissingAgentShellFallbackAndFailedSpawnReturnReadableStoppedState() async throws {
        let (root, runtime, driver, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        await driver.configure(agent: false)
        let missing = try await runtime.ensure(); XCTAssertEqual(missing.status, .stopped); XCTAssertEqual(missing.problem, "Hoot's claude CLI is not installed on this machine.")
        let noCalls = await driver.snapshot(); XCTAssertEqual(noCalls.calls.count, 0)
        await driver.configure(agent: true, provider: "shell")
        let fallback = try await runtime.ensure(); XCTAssertEqual(fallback.status, .stopped); XCTAssertEqual(fallback.problem, "Hoot started as a shell session rather than an agent.")
        let killed = await driver.snapshot(); XCTAssertEqual(killed.stopped.count, 1)
        await driver.configure(provider: "claude", error: "that folder does not exist")
        let failed = try await runtime.ensure(); XCTAssertEqual(failed.status, .stopped); XCTAssertEqual(failed.problem, "that folder does not exist")
        await driver.configure()
        let retry = try await runtime.ensure(); XCTAssertEqual(retry.status, .running); XCTAssertNil(retry.problem)
    }
    func testLayerFailureRefusesBeforeSpawn() async throws {
        let (root, runtime, driver, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = BackendCopilotPaths(userData: root.path)
        _ = BackendCopilotHome.scaffold(paths)
        try FileManager.default.createDirectory(atPath: paths.layer.composed, withIntermediateDirectories: false)
        let state = try await runtime.ensure(); XCTAssertEqual(state.status, .stopped); XCTAssertTrue(state.problem?.contains("instructions could not be prepared") == true)
        let calls = await driver.snapshot(); XCTAssertEqual(calls.calls.count, 0)
    }
    func testChosenWorkspaceIsUntouchedAndStateKeepsRunningFolderWhenSettingMoves() async throws {
        let (root, runtime, driver, _, selection) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        // Use a directory outside userData: folder guard intentionally refuses
        // other paths inside app data. A separate scratch sibling is the choice.
        let chosen = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotChosen-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: chosen) }
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: false)
        try Data("# someone else’s assistant\n".utf8).write(to: chosen.appendingPathComponent("CLAUDE.md"))
        try FileManager.default.createDirectory(at: chosen.appendingPathComponent("memory"), withIntermediateDirectories: false)
        try Data("# their index\n".utf8).write(to: chosen.appendingPathComponent("memory/MEMORY.md"))
        let before = try FileManager.default.subpathsOfDirectory(atPath: chosen.path).sorted()
        let started = try await runtime.ensure()
        await selection.set(chosen.path)
        let moved = try await runtime.state(); XCTAssertTrue(moved.folder.restartNeeded); XCTAssertEqual(moved.folder.runningIn, started.paths.root)
        _ = try await runtime.stop()
        let theirs = try await runtime.ensure(); XCTAssertEqual(theirs.paths.root, chosen.path); XCTAssertFalse(theirs.paths.ownFolder)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: chosen.path).sorted(), before)
        XCTAssertEqual(try BackendCopilotServiceFiles.readText(chosen.appendingPathComponent("CLAUDE.md").path), "# someone else’s assistant\n")
        let calls = await driver.snapshot(); XCTAssertEqual(calls.calls.last?.input.cwd, chosen.path)
        _ = workspace
    }
    func testSignInCacheIsProfileSpecificAndUnsupportedBecomesUnknown() async throws {
        let (root, runtime, driver, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await runtime.readSignIn(now: 1000), second = try await runtime.readSignIn(now: 1500)
        XCTAssertEqual(first.profileName, "Default"); XCTAssertEqual(second.checkedAt, first.checkedAt)
        let reads = await driver.snapshot(); XCTAssertEqual(reads.signInReads, 1)
        await driver.configure(signIn: "signed-out", profileID: "work")
        let changed = try await runtime.readSignIn(now: 1600); XCTAssertEqual(changed.profileId, "work"); XCTAssertEqual(changed.state, "signed-out")
        await driver.configure(signIn: "unsupported")
        let unknown = try await runtime.readSignIn(now: 100000); XCTAssertEqual(unknown.state, "unknown")
    }
    func testStrictPerRunMCPAttachmentBindReleaseRegenerateAndNoToolsBranch() async throws {
        let tools = BackendCopilotSessionTestTools()
        let (root, runtime, driver, _, _) = try fixture(tools: tools); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await runtime.ensure()
        let calls = await driver.snapshot()
        XCTAssertEqual(calls.calls.first?.arguments, ["--mcp-config", "/synthetic/run-1/deck-control.json", "--strict-mcp-config", "--append-system-prompt-file", first.paths.layer.composed])
        XCTAssertTrue(try BackendCopilotServiceFiles.readText(first.paths.layer.contract).contains("sessions_list"))
        await tools.changeCatalogue(); _ = try await runtime.stop(); _ = try await runtime.ensure()
        let text = try BackendCopilotServiceFiles.readText(first.paths.layer.contract)
        XCTAssertTrue(text.contains("log_note")); XCTAssertFalse(text.contains("sessions_list"))
        let leases = await tools.snapshot(); XCTAssertEqual(leases.prepared, 2); XCTAssertEqual(leases.bound.count, 2); XCTAssertEqual(leases.released.count, 1)
    }
    func testDeskHootIDIsHiddenInEveryRemoteRuleWithoutHidingAnOrdinarySameFolderSession() async throws {
        let (root, runtime, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let state = try await runtime.ensure(), hootID = try XCTUnwrap(state.sessionId)
        let input = BackendCreateSessionInput(cwd: state.paths.root, provider: "shell")
        let ordinary = BackendSessionMeta(id: "ordinary", input: input, spawn: .init(provider: "shell", command: "/bin/sh", args: [], path: "/bin"))
        let hoot = BackendSessionMeta(id: hootID, input: input, spawn: .init(provider: "claude", command: "/synthetic/claude", args: [], path: "/bin"))
        let hidden = BackendRemoteServeSessionHidden()
        hidden.hide(hootID)
        let predicate: @Sendable (String) throws -> Bool = { hidden.contains($0) || runtime.isCopilotSession($0) }
        // list, attach, input and resize must all use this exact eligibility
        // rule in the assembled host. Source tests here don't claim wiring.
        for _ in ["list", "attach", "input", "resize"] {
            XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "phone", session: hoot, hidden: predicate, reach: nil, shared: nil))
            XCTAssertTrue(BackendRemoteServeSessionPolicy.visible(deviceID: "phone", session: ordinary, hidden: predicate, reach: nil, shared: nil))
        }
        XCTAssertEqual(BackendRemoteServeSessionPolicy.offeredFolders([state.paths.root, "/other"], sessions: [hoot, ordinary], hidden: predicate), ["/other"])
        XCTAssertFalse(BackendRemoteServeSessionPolicy.visible(deviceID: "phone", session: nil, hidden: predicate, reach: nil, shared: nil))
    }
    func testLegacyHomeScopeExcludesForgedProjectRetainsHootAndPairedPhoneHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotForgery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = BackendCopilotSessionRuntime.homeScope(userData: root.path)
        let homes = root.appendingPathComponent("remote/device-home")
        let hootConfig = URL(fileURLWithPath: scope.home).appendingPathComponent(".claude")
        let phoneConfig = homes.appendingPathComponent("phone/.claude")
        let profileConfig = root.appendingPathComponent("profile/.claude")
        let victim = "/fake/somebody-elses-api"
        for config in [hootConfig, phoneConfig, profileConfig] {
            try FileManager.default.createDirectory(at: config.appendingPathComponent("projects"), withIntermediateDirectories: true)
        }
        func project(_ config: URL, _ cwd: String) -> String { config.appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(cwd)).path }
        let forged = project(hootConfig, victim), genuine = project(hootConfig, scope.folder), phone = project(phoneConfig, victim)
        for directory in [forged, genuine, phone] { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true) }
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: forged).appendingPathComponent("fabricated.jsonl"))
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: genuine).appendingPathComponent("real.jsonl"))
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: phone).appendingPathComponent("phone.jsonl"))
        let old = NativeTranscriptScope(configDirectory: profileConfig.path, deviceHomesRoot: homes.path)
        XCTAssertTrue(try NativeTranscriptPaths.projectDirectories(victim, scope: old).contains(forged))
        let scoped = NativeTranscriptScope(configDirectory: profileConfig.path, deviceHomesRoot: homes.path, homeScopes: [scope])
        let victimDirs = try NativeTranscriptPaths.projectDirectories(victim, scope: scoped)
        XCTAssertFalse(victimDirs.contains(forged)); XCTAssertTrue(victimDirs.contains(phone))
        XCTAssertTrue(try NativeTranscriptPaths.projectDirectories(scope.folder, scope: scoped).contains(genuine))
        XCTAssertTrue(try NativeTranscriptPaths.configDirectories(scoped).contains(hootConfig.path))
        XCTAssertEqual(try NativeTranscriptPaths.listTranscripts(phone, scope: scoped).map(\.sessionID), ["phone"])
    }
    func testExactChannelsAndLegacyHomeScopeSurviveRemovalOfOldJail() async throws {
        let (root, runtime, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let expected = ["copilot:ensure", "copilot:files", "copilot:read-composed", "copilot:read-contract", "copilot:read-folder-instructions", "copilot:read-instructions", "copilot:reset-instructions", "copilot:signin", "copilot:state", "copilot:stop", "copilot:write-folder-instructions", "copilot:write-instructions", "hoot:chat:read", "hoot:chat:say", "hoot:chat:stop", "hoot:chat:answer", "copilot:chat:read", "copilot:chat:say", "copilot:chat:stop", "copilot:chat:answer"]
        XCTAssertEqual(BackendCopilotSessionRuntime.channels.sorted(), expected.sorted())
        let scope = BackendCopilotSessionRuntime.homeScope(userData: root.path)
        XCTAssertEqual(scope.home, root.appendingPathComponent("remote/device-home/copilot").path)
        XCTAssertEqual(scope.folder, root.appendingPathComponent("hoot").path)
        let state = try await runtime.state(); XCTAssertEqual(state.status, .stopped); XCTAssertNil(state.profile); XCTAssertEqual(state.startupFiles.map(\.exists), [false, false, false])
        let legacyState = try await runtime.invoke("copilot:state", arguments: [])
        let canonicalState = try await runtime.invoke("hoot:state", arguments: [])
        XCTAssertEqual(canonicalState, legacyState)
        let files = try await runtime.invoke("copilot:files", arguments: [.string("arbitrary ignored path")])
        XCTAssertEqual(files.elements?.count, 3)
    }
}
