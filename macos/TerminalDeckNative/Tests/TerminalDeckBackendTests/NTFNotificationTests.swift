import Foundation
import XCTest
import TerminalDeckNativeCore
#if NTF_STANDALONE
@testable import NTFBackend
#else
@testable import TerminalDeckBackend
#endif

/// Drives the real PTY, SwiftTerm viewport and shared banner/island rule.
/// Time advances ten minutes in the rule, without waiting ten real minutes.
final class NTFNotificationTests: XCTestCase, @unchecked Sendable {
    private final class Notices: @unchecked Sendable {
        private let lock = NSLock()
        private var previous: String? = "idle"
        private var firedAt: [String: Double] = [:]
        private var time: Double = 0
        private var enabled = true
        private var events: [BackendSessionEvent] = []
        private var notices: [String] = []
        func note(_ event: BackendSessionEvent) {
            lock.withLock {
                events.append(event)
                guard case .status(_, let status) = event else { return }
                let value = status.rawValue
                if BackendSharedNotifyRule.decide(status: value, previous: previous, enabled: enabled,
                    watching: false, lastFiredAt: firedAt[value], now: time,
                    cooldownMs: BackendSharedNotifyRule.cooldownMilliseconds) == .fire {
                    notices.append(value); firedAt[value] = time
                }
                previous = value
            }
        }
        func advance(_ milliseconds: Double) { lock.withLock { time += milliseconds } }
        func setEnabled(_ value: Bool) { lock.withLock { enabled = value } }
        #if !NTF_STANDALONE
        func noteLifecycle(_ event: BackendSessionLifecycleEvent) {
            if case .status(let id, let status, _) = event { note(.status(id: id, status: status)) }
        }
        #endif
        var fired: [String] { lock.withLock { notices } }
        var statuses: [BackendSessionStatus] { lock.withLock { events.compactMap { if case .status(_, let status) = $0 { return status }; return nil } } }
        var dataCount: Int { lock.withLock { events.filter { if case .data = $0 { return true }; return false }.count } }
    }

    private let script = #"""
    stty -echo
    printf '\033[2J\033[HDo you want to proceed? (y/n)'
    while IFS= read -r line; do
      case "$line" in
        repaint) printf '\033[HDo you want to proceed? (y/n)';;
        split) printf '\033[2J\033[H'; sleep 0.15; printf 'Do you want to proceed? (y/n)';;
        footer) printf '\033[2J\033[HDo you want to proceed? (y/n)\r\nUpdated 10 minutes ago';;
        controls) printf '\033[?25l\033[?25h';;
        work) printf '\033[2J\033[HThinking… (esc to interrupt)';;
        ask) printf '\033[2J\033[HDo you want to proceed? (y/n)';;
        quit) exit 0;;
      esac
    done
    """#

    private func started(_ notices: Notices) throws -> (BackendPTYManager, String) {
        let manager = BackendPTYManager(inheritedEnvironment: [:]) { notices.note($0) }
        let input = BackendCreateSessionInput(cwd: "/tmp", cols: 80, rows: 24, provider: "shell")
        let meta = try manager.create(input, spawn: .init(provider: "shell", command: "/bin/sh",
            args: ["-c", script], path: "/usr/bin:/bin"))
        return (manager, meta.id)
    }

    private func until(_ check: @escaping @Sendable () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(5)
        while !check(), ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(check(), "The stand-in PTY did not reach the expected state")
    }

    private func send(_ command: String, manager: BackendPTYManager, id: String, notices: Notices) async throws {
        let before = notices.dataCount
        try manager.write(id, data: command + "\n")
        try await until { notices.dataCount > before }
        // The production settle timer is 700 ms; await its negative result too.
        try await Task.sleep(for: .milliseconds(1_100))
    }

    #if !NTF_STANDALONE
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
    private func withLifecycle(_ notices: Notices,
        _ body: (BackendSessionLifecycleCoordinator, String) async throws -> Void) async throws {
        // Existing offline fixture: fake cipher and fake security runner, no real credentials.
        let runtime = try await BackendF4Runtime.wire()
        let manager = BackendPTYManager(inheritedEnvironment: [:]) { _ in }
        do {
            let ledger = try await BackendNativeLedger.activate(store: runtime.state, oldSessionOwnerDisabled: true)
            let launcher = BackendSessionLauncher(manager: manager, dependencies: try .init(providers: Providers(),
                accounts: runtime.adapter, confinement: Confinement(), instructions: Instructions(), ledger: ledger))
            let endpoint = BackendSuppliedMCPBridge(readiness: .ready, description: { nil }, catalogue: { [] },
                register: { _, _ in throw BackendAccountFailure("No tools in this test") }, bind: { _, _, _ in }, revoke: { _ in })
            let launch = try BackendCoordinatedSessionLaunch(launcher: launcher, providers: Providers(),
                sessionTools: try .init(endpoint: endpoint, userData: runtime.configuration.dataDirectory),
                projectTools: try .init(source: ProjectTools(), userData: runtime.configuration.dataDirectory, inheritedEnvironment: [:]),
                reach: BackendBrowserToolReachAdapter(readiness: .ready, reachesDeviceWindows: { _ in false }, hostHoldsWindows: { false }))
            let lifecycle = try BackendSessionLifecycleCoordinator(manager: manager, launch: launch, accounts: runtime.adapter,
                attribution: BackendAccountAttribution(configuration: runtime.configuration, profiles: await runtime.profiles),
                ledger: ledger, store: runtime.state, cleanup: .init(readiness: .ready, release: { _ in }), emit: { notices.noteLifecycle($0) })
            let meta = try manager.create(.init(cwd: runtime.root.path, provider: "shell"),
                spawn: .init(provider: "shell", command: "/bin/sh", args: ["-c", "stty -echo; cat >/dev/null"], path: "/usr/bin:/bin"))
            try await body(lifecycle, meta.id)
            manager.killAll(); _ = await manager.drain()
            await runtime.dispose(removeRoot: true)
        } catch {
            manager.killAll(); _ = await manager.drain()
            await runtime.dispose(removeRoot: true); throw error
        }
    }

    #endif

    func testSamePromptRedrawnTenMinutesLaterDoesNotAnnounceAgain() async throws {
        let notices = Notices(), (manager, id) = try started(notices)
        defer { manager.killAll() }
        try await until { notices.statuses.last == .input }
        XCTAssertEqual(notices.fired, ["input"])
        let screen = manager.screen(id)
        notices.advance(600_001)
        try await send("repaint", manager: manager, id: id, notices: notices)
        XCTAssertEqual(manager.screen(id), screen)
        XCTAssertEqual(notices.fired, ["input"], "An unchanged prompt is one event, even after the cooldown")
        notices.advance(600_001)
        try await send("repaint", manager: manager, id: id, notices: notices)
        XCTAssertEqual(notices.fired, ["input"])
        XCTAssertTrue(manager.scrollback(id).contains("\u{1b}[HDo you want"), "Raw output still reaches the terminal")
    }

    func testCursorOnlyOutputDoesNotReopenFinishedWork() async throws {
        let notices = Notices(), (manager, id) = try started(notices)
        defer { manager.killAll() }
        try await until { notices.statuses.last == .input }
        let before = notices.statuses
        notices.advance(600_001)
        try await send("controls", manager: manager, id: id, notices: notices)
        XCTAssertEqual(notices.statuses, before)
        XCTAssertEqual(notices.fired, ["input"])
    }

    func testSplitRedrawIsStillOneQuestion() async throws {
        let notices = Notices(), (manager, id) = try started(notices)
        defer { manager.killAll() }
        try await until { notices.statuses.last == .input }
        let screen = manager.screen(id)
        notices.advance(600_001)
        try await send("split", manager: manager, id: id, notices: notices)
        XCTAssertEqual(manager.screen(id), screen)
        XCTAssertEqual(notices.fired, ["input"])
    }

    func testRealWorkThenAnotherQuestionStillAnnounces() async throws {
        let notices = Notices(), (manager, id) = try started(notices)
        defer { manager.killAll() }
        try await until { notices.statuses.last == .input }
        notices.advance(600_001)
        try await send("work", manager: manager, id: id, notices: notices)
        XCTAssertEqual(notices.statuses.last, .working)
        try await send("ask", manager: manager, id: id, notices: notices)
        XCTAssertEqual(notices.fired, ["input", "input"])
    }

    func testChangingFooterDoesNotMakeAnOldQuestionNewWork() async throws {
        let notices = Notices(), (manager, id) = try started(notices)
        defer { manager.killAll() }
        try await until { notices.statuses.last == .input }
        notices.advance(600_001)
        try await send("footer", manager: manager, id: id, notices: notices)
        XCTAssertEqual(notices.fired, ["input"])
        XCTAssertEqual(notices.statuses.last, .input)
    }

    func testStoppedProcessNeverAnnouncesAgain() async throws {
        let notices = Notices(), (manager, id) = try started(notices)
        defer { manager.killAll() }
        try await until { notices.statuses.last == .input }
        notices.advance(600_001)
        try manager.write(id, data: "quit\n")
        try await until { manager.list().first { $0.id == id }?.exitCode != nil }
        notices.advance(600_001)
        manager.setWatched(false); manager.setWatched(true)
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(notices.statuses.last, .exited)
        XCTAssertEqual(notices.fired, ["input"])
        let drained = await manager.drain()
        XCTAssertTrue(drained)
    }

    #if !NTF_STANDALONE
    func testNotifyOnCompletePreferenceStillDecides() async throws {
        let store = NativeStateStore(), notices = Notices()
        _ = try await store.setPreferences(.object([.init("notifyOnComplete", .bool(false))]))
        let disabled = await store.getPreferences()
        notices.setEnabled(disabled["notifyOnComplete"].bool == true)
        try await withLifecycle(notices) { lifecycle, id in
            await lifecycle.noteHookStatus(sessionID: id, status: .working, receivedAt: Date())
            await lifecycle.noteHookStatus(sessionID: id, status: .completed, receivedAt: Date())
            XCTAssertTrue(notices.fired.isEmpty)
            _ = try await store.setPreferences(.object([.init("notifyOnComplete", .bool(true))]))
            let enabled = await store.getPreferences()
            notices.setEnabled(enabled["notifyOnComplete"].bool == true)
            await lifecycle.noteHookStatus(sessionID: id, status: .completed, receivedAt: Date())
            XCTAssertTrue(notices.fired.isEmpty, "Turning notifications on must not replay an old completion")
            await lifecycle.noteHookStatus(sessionID: id, status: .working, receivedAt: Date())
            await lifecycle.noteHookStatus(sessionID: id, status: .completed, receivedAt: Date())
            XCTAssertEqual(notices.fired, ["completed"])
        }
    }

    func testCompletedHookSurvivesRedrawAndRepeatedStopTenMinutesLater() async throws {
        let notices = Notices()
        try await withLifecycle(notices) { lifecycle, id in
            await lifecycle.noteSessionEvent(.status(id: id, status: .working))
            await lifecycle.noteHookStatus(sessionID: id, status: .completed, receivedAt: Date())
            XCTAssertEqual(notices.fired, ["completed"])
            notices.advance(600_001)
            await lifecycle.noteSessionEvent(.data(id: id, text: "\u{1b}[?25h"))
            await lifecycle.noteSessionEvent(.status(id: id, status: .working))
            await lifecycle.noteSessionEvent(.status(id: id, status: .waiting))
            let status = await lifecycle.status(sessionID: id)
            XCTAssertEqual(status, .completed, "A redraw is not a new turn after Stop")
            await lifecycle.noteHookStatus(sessionID: id, status: .completed, receivedAt: Date())
            XCTAssertEqual(notices.fired, ["completed"])
            XCTAssertEqual(notices.statuses, [.working, .completed])
        }
    }

    func testNewPromptRearmsCompletionButRepeatedHooksDoNot() async throws {
        let notices = Notices()
        try await withLifecycle(notices) { lifecycle, id in
            await lifecycle.noteHookStatus(sessionID: id, status: .working, receivedAt: Date())
            await lifecycle.noteHookStatus(sessionID: id, status: .completed, receivedAt: Date())
            notices.advance(600_001)
            await lifecycle.noteHookStatus(sessionID: id, status: .completed, receivedAt: Date())
            XCTAssertEqual(notices.statuses, [.working, .completed])
            try await lifecycle.write(sessionID: id, data: "next prompt\n")
            await lifecycle.noteSessionEvent(.status(id: id, status: .working))
            await lifecycle.noteHookStatus(sessionID: id, status: .completed, receivedAt: Date())
            XCTAssertEqual(notices.fired, ["completed", "completed"])
        }
    }

    func testLateStatusForStoppedSessionCannotAnnounce() async throws {
        let notices = Notices()
        try await withLifecycle(notices) { lifecycle, id in
            await lifecycle.noteSessionEvent(.status(id: id, status: .working))
            try await lifecycle.close(sessionID: id)
            await lifecycle.noteSessionEvent(.removed(id: id, reason: .stopped))
            notices.advance(600_001)
            await lifecycle.noteSessionEvent(.status(id: id, status: .input))
            await lifecycle.noteHookStatus(sessionID: id, status: .input, receivedAt: Date())
            XCTAssertTrue(notices.fired.isEmpty)
            XCTAssertEqual(notices.statuses, [.working])
        }
    }
    #endif
}

#if NTF_STANDALONE || NTF_FULL_STANDALONE
/// Same PTY tests, linked to the actual source subset while unrelated app areas cannot compile.
@main
struct NTFStandaloneRunner {
    static func main() {
        let suite = NTFNotificationTests.defaultTestSuite
        #if NTF_STANDALONE
        let expected = 6
        #else
        let expected = 10
        #endif
        guard suite.testCaseCount == expected else { fatalError("Expected \(expected) tests, got \(suite.testCaseCount)") }
        suite.run()
        guard let run = suite.testRun else { fatalError("The tests did not run") }
        print("NTF: \(run.executionCount) tests, \(run.totalFailureCount) failures")
        exit(run.hasSucceeded ? 0 : 1)
    }
}
#endif
