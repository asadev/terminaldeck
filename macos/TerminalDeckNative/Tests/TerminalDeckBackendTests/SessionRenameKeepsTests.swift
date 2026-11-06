import Foundation
import Testing
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Asad, 12 Oct (install 18): "I can't rename sessions like before. If I edit and apply, it does not work."
// A name given to a session lives on the session (and in the helper that runs it) and in its saved launch, so an
// app restart, a helper crash or a restore brings the session back under the same name.

/// Records the name each restored start was asked to carry.
actor SessionRenameRecordingStarter: BackendRestoreSessionStarting {
    private(set) var names: [String?] = []
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool) async throws -> BackendSessionMeta {
        try await create(input, context: context, holdOnFailure: holdOnFailure, named: nil)
    }
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool, named: String?) async throws -> BackendSessionMeta {
        names.append(named)
        return BackendFoundationTestsSessionsFixtures.meta("restored-\(names.count)", cwd: input.cwd, provider: input.provider ?? "claude")
    }
    func liveSessions() async -> [BackendSessionMeta] { [] }
}

@Suite("Session rename: a restore keeps the name")
struct SessionRenameRestoreTests {
    private func coordinator(_ world: BackendFoundationTestsS5SessionsWorld, _ sessions: [BackendSessionSaved])
        async throws -> (BackendSessionRestoreCoordinator, SessionRenameRecordingStarter, NativeStateStore) {
        let store = NativeStateStore(initialState: NativeStateStore.defaults)
        try await store.setOpenSessions(sessions.map(\.raw))
        try await store.startSessionLedger()
        let starter = SessionRenameRecordingStarter()
        let context = BackendSessionRestoreContext(readiness: .ready) { device, folder in .init(deviceKey: device, folder: folder) }
        let coordinator = BackendSessionRestoreCoordinator(starter: starter, planner: world.planner, store: store, context: context,
            excludedAppWorkingDirectories: [], emit: { _ in })
        return (coordinator, starter, store)
    }

    @Test func aRestartStartsEachTabUnderTheNameItWasGiven() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let named = try world.tab(try world.folder("a"), "k-a", provider: "shell", extra: [.init("title", .string("API work"))])
            let plain = try world.tab(try world.folder("b"), "k-b", provider: "shell")
            #expect(named.title == "API work"); #expect(plain.title == nil)
            let (restore, starter, _) = try await coordinator(world, [named, plain])
            _ = try await restore.restore()
            #expect(await starter.names == ["API work", nil])
        }
    }

    @Test func aSessionTheHelperTookStartsAgainUnderItsName() async throws {
        try await BackendFoundationTestsS5SessionsWithWorld { world in
            let named = try world.tab(try world.folder("c"), "k-c", provider: "shell", extra: [.init("title", .string("Release notes"))])
            let (restore, starter, store) = try await coordinator(world, [])
            // Crash recovery puts the lost session on hold from its saved launch, then starts it again.
            let held = try await store.holdSession(named.raw, reason: "the session helper stopped; starting it again")
            _ = try await restore.retryHeld(held.key)
            #expect(await starter.names == ["Release notes"])
        }
    }
}

/// The real lifecycle owner over a real PTY and the real saved-launch ledger.
final class SessionRenameLifecycleTests: XCTestCase, @unchecked Sendable {
    private struct Providers: BackendProviderLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func loginPath() async throws -> String { "/usr/bin:/bin" }
        func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
            .init(id: "shell", command: "/bin/sh", args: ["-c", "cat >/dev/null"], resumeArgs: [])
        }
    }
    private struct Confinement: BackendConfinementLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(command: String, args: [String], input: BackendCreateSessionInput,
            account: BackendAccountLaunch, context: BackendLaunchContext) async throws -> BackendConfinedLaunch {
            .init(command: command, args: args)
        }
    }
    private struct Instructions: BackendInstructionLaunchResolver {
        let readiness: BackendLaunchReadiness = .ready
        func arguments(_ input: BackendCreateSessionInput, provider: BackendProviderSpec,
            context: BackendLaunchContext) async throws -> [String] { [] }
    }
    private struct ProjectTools: BackendProjectMCPSource {
        let readiness: BackendLaunchReadiness = .ready
        func resolve(cwd: String, provider: String, loginPath: String) async throws -> BackendProjectMCPDefinition? { nil }
    }
    private final class Announced: @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String] = []
        func note(_ event: BackendSessionLifecycleEvent) { if case .created(let meta) = event { lock.withLock { titles.append(meta.title) } } }
        var created: [String] { lock.withLock { titles } }
    }

    private func withLifecycle(_ body: (BackendSessionLifecycleCoordinator, BackendPTYManager, BackendF4Runtime, Announced) async throws -> Void) async throws {
        let runtime = try await BackendF4Runtime.wire()
        let manager = BackendPTYManager(inheritedEnvironment: [:]) { _ in }
        let announced = Announced()
        do {
            let ledger = try await BackendNativeLedger.activate(store: runtime.state)
            let launcher = BackendSessionLauncher(manager: manager, dependencies: try .init(providers: Providers(),
                accounts: runtime.adapter, confinement: Confinement(), instructions: Instructions(), ledger: ledger))
            let endpoint = BackendTestMCPEndpoint(readiness: .ready, description: { nil }, catalogue: { [] },
                register: { _, _ in throw BackendAccountFailure("No tools in this test") }, bind: { _, _, _ in }, revoke: { _ in })
            let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: Providers(),
                sessionTools: try .init(endpoint: endpoint, userData: runtime.configuration.dataDirectory),
                projectTools: try .init(source: ProjectTools(), userData: runtime.configuration.dataDirectory, inheritedEnvironment: [:]),
                reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
            let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch, accounts: runtime.adapter,
                attribution: BackendAccountAttribution(configuration: runtime.configuration, profiles: await runtime.profiles),
                ledger: ledger, store: runtime.state, cleanup: .init(readiness: .ready, release: { _ in }), emit: { announced.note($0) })
            try await body(lifecycle, manager, runtime, announced)
            manager.killAll(); _ = await manager.drain()
            await runtime.dispose(removeRoot: true)
        } catch {
            manager.killAll(); _ = await manager.drain()
            await runtime.dispose(removeRoot: true); throw error
        }
    }

    func testFix29PeerDirectoryCannotWriteRenameOrCancelSwitchAtFinalBoundary() async throws {
        try await withLifecycle { lifecycle, manager, runtime, _ in
            let profiles = await runtime.profiles
            let attribution = BackendAccountAttribution(configuration: runtime.configuration, profiles: profiles)
            let restoreContext = BackendSessionRestoreContext(readiness: .ready) { device, folder in .init(deviceKey: device, folder: folder) }
            let planner = BackendSessionRestorePlanner(accounts: runtime.adapter, providers: Providers(), context: restoreContext)
            let restore = BackendSessionRestoreCoordinator(lifecycle: lifecycle, planner: planner, store: runtime.state,
                context: restoreContext, excludedAppWorkingDirectories: [], emit: { _ in })
            let switches = try await BackendSessionSwitchCoordinator.start(lifecycle: lifecycle, accounts: runtime.adapter,
                attribution: attribution, planner: planner, store: runtime.state, apiCredentialAvailable: { _ in false }, emit: { _ in })
            let deferred = await BackendSessionSwitchDeferred.start(lifecycle: lifecycle, switches: switches, emit: { _ in })
            let rpc = BackendSessionLifecycleRPC(lifecycle: lifecycle, switches: switches, restore: restore, deferred: deferred,
                store: runtime.state, authorizeMutation: { _ in })
            let files = BackendFilesystemService(authority: BackendFilesystemAuthority { _ in .init(readRoots: [runtime.root], writeRoots: [runtime.root]) })
            let projects = try BackendProjectService(store: runtime.state, files: files, home: runtime.root.path,
                appDataRoot: runtime.configuration.dataDirectory, liveSessions: { [] })
            let cost = BackendCostService(projects: projects, scopeProvider: { _, _ in throw BackendAccountFailure("No transcripts in this fixture") }, push: { _, _, _ in })
            let writes = BackendF4Box<[String]>([])
            for (id, folder) in [("decker", "/deck"), ("commander", "/imatch")] {
                var input = BackendCreateSessionInput(cwd: folder, provider: "codex"); input.chat = true
                let meta = BackendSessionMeta(id: id, input: input, spawn: .init(provider: "codex", command: "/never-run", args: [], path: "/usr/bin"))
                try manager.registerChat(meta, controls: .init(send: { text in writes.update { $0.append(text) } }, stop: {}, text: { "" }, pid: { nil }))
            }
            let rows = manager.list().map { meta in BackendSessionDirectory.row(meta, owner: .init(kind: .lead, id: meta.id, name: meta.id, project: meta.id)) }
            let caller = BackendDeckCoreSecurityCaller(kind: .session, tiers: [.read, .act, .alter], sessionID: "decker")
            let peer = try XCTUnwrap(rows.first { $0["id"].string == "commander" })
            XCTAssertTrue(BackendSessionDirectory.permits(peer, rows: rows, caller: caller, directory: true))
            XCTAssertTrue(BackendSessionDirectory.permits(peer, rows: rows, caller: caller, message: true))
            let checked = BackendF4Box<[String]>([])
            let cancelled = BackendF4Box(0)
            let surface = BackendDeckToolsSessionsNativeSurface(lifecycle: lifecycle, rpc: rpc, profiles: profiles,
                cost: cost, search: BackendSessionSearchService(cost: cost, projects: projects), insights: BackendInsightsService(cost: cost),
                context: { _ in .init(caller: .nativeApp, ownerID: "fix29") }, statusRecord: { _, _ in nil }, planLimits: { _, _ in .null },
                announceRenamed: { _, _ in }, tellSwitched: { _, _, _ in }, sessionView: { id, _ in
                    checked.update { $0.append(id) }
                    guard let row = rows.first(where: { $0["id"].string == id }), BackendSessionDirectory.permits(row, rows: rows, caller: caller) else {
                        throw NativeRPCError(code: "access-denied", message: BackendSessionDirectory.accessRefusal)
                    }
                    return row
                }, cancelArmed: { _, _ in cancelled.update { $0 += 1 }; return true }, launchContext: { _, _, _ in .init() })
            let context = BackendDeckToolsSessionsPortValues.context(sessionID: "decker")
            do { try await surface.write(sessionID: "commander", data: "escape", context: context); XCTFail("Peer keys accepted") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
            do { _ = try await surface.rename(sessionID: "commander", title: "stolen", context: context); XCTFail("Peer rename accepted") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
            do { _ = try await surface.cancelSwitch(sessionID: "commander", context: context); XCTFail("Peer switch cancellation accepted") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
            do { _ = try await surface.switchAccount(sessionID: "commander", profileID: "never-used", context: context); XCTFail("Peer account switch accepted") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
            do { _ = try await surface.switchLater(sessionID: "commander", profileID: "never-used", context: context); XCTFail("Peer deferred switch accepted") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
            do { _ = try await surface.accountPlan(sessionID: "commander", profileID: "never-used", context: context); XCTFail("Peer account plan accepted") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
            do { _ = try await surface.account(sessionID: "commander", context: context); XCTFail("Peer account details accepted") }
            catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
            XCTAssertEqual(checked.value, Array(repeating: "commander", count: 7))
            XCTAssertEqual(writes.value, [])
            XCTAssertEqual(cancelled.value, 0)
            XCTAssertNotEqual(manager.list().first { $0.id == "commander" }?.title, "stolen")
            // Ordinary access still works through these same final boundaries.
            try await surface.write(sessionID: "decker", data: "own input", context: context)
            let title = try await surface.rename(sessionID: "decker", title: "own title", context: context)
            XCTAssertEqual(title, "own title")
            XCTAssertEqual(writes.value, ["own input"])
            await deferred.stop(); await switches.stop()
        }
    }

    func testRenameNamesTheSessionAndItsSavedLaunch() async throws {
        try await withLifecycle { lifecycle, manager, runtime, _ in
            let folder = runtime.root.path
            let meta = try manager.create(.init(cwd: folder, provider: "shell"),
                spawn: .init(provider: "shell", command: "/bin/sh", args: ["-c", "cat >/dev/null"], path: "/usr/bin:/bin"))
            try await runtime.state.ledgerNote(meta.id, saved: .object([.init("cwd", .string(folder)), .init("provider", .string("shell")),
                                                                         .init("tabKey", .string("tab-1"))]))
            let renamed = try await lifecycle.rename(sessionID: meta.id, title: "  API work  ")
            XCTAssertTrue(renamed)
            XCTAssertEqual(manager.list().first { $0.id == meta.id }?.title, "API work")
            let saved = try await runtime.state.ledgerGet(meta.id)
            XCTAssertEqual(saved["title"].string, "API work", "the saved launch carries the name for a restart")
            XCTAssertEqual(saved["tabKey"].string, "tab-1")

            // A blank (only a tool or a phone sends one) puts the folder's name back and forgets the saved name.
            let reset = try await lifecycle.rename(sessionID: meta.id, title: " ")
            XCTAssertTrue(reset)
            XCTAssertEqual(manager.list().first { $0.id == meta.id }?.title, URL(fileURLWithPath: folder).lastPathComponent)
            let forgotten = try await runtime.state.ledgerGet(meta.id)
            XCTAssertNil(forgotten["title"].string)

            let missing = try await lifecycle.rename(sessionID: "no-such-session", title: "x")
            XCTAssertFalse(missing)
        }
    }

    func testARestartedSessionIsAnnouncedUnderItsSavedName() async throws {
        try await withLifecycle { lifecycle, manager, runtime, announced in
            let input = BackendCreateSessionInput(cwd: runtime.root.path, cols: 80, rows: 24, provider: "shell")
            let meta = try await lifecycle.create(input, context: BackendLaunchContext(rememberTab: true), holdOnFailure: false,
                                                  announce: true, named: "Release notes")
            XCTAssertEqual(meta.title, "Release notes")
            XCTAssertEqual(manager.list().first { $0.id == meta.id }?.title, "Release notes")
            XCTAssertEqual(announced.created, ["Release notes"], "the first announcement already carries the name")
            let saved = try await runtime.state.ledgerGet(meta.id)
            XCTAssertEqual(saved["title"].string, "Release notes")
        }
    }
}
