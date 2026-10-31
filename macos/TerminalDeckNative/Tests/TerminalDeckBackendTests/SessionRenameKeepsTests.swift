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
