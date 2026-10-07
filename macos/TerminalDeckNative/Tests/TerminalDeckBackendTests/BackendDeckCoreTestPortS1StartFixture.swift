import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The fake behind start-account.test.ts and start-guards.test.ts.
///
/// It records every start and every write, and its screen echoes what is typed
/// at it the way a terminal does (`\r` commits and clears the line, anything
/// else lands in the composer). The brief writer and the delivery loop behind
/// it are the real ones: specs land on disk through `BackendDeckCoreBrief.writeSpec`,
/// and delivery runs `BackendDeckCoreBrief.deliver` on a clock that moves
/// instead of waiting.
final class BackendDeckCoreTestPortS1StartSurface: BackendDeckCoreCatalogueSurface, BackendDeckCoreBriefSurface, @unchecked Sendable {
    typealias V = NativeRPCValue
    /// `.lane` names a start like sessions-lane.fixture.ts (`new-<count+1>`);
    /// `.copilot` like start-guards.test.ts's rig (`copilot-<starts>`, title `work`).
    enum Naming: Sendable { case lane, copilot }
    var sessions: [V]
    var projects: [String]
    let stateRoot: String
    let homeRoot: String
    var accountRows: [V]?
    let naming: Naming
    var started: [V] = []
    var typed: [String] = []
    /// What the session's terminal shows; nil is "no screen at all".
    var screen: String? = "❯ "
    /// start-guards.test.ts's `onLook` hook: the newest session dies on every look.
    var exitOnLook = false
    private let instant = BackendDeckCoreSecurityTestBox(0.0)

    init(sessions: [V], projects: [String], stateRoot: String, homeRoot: String, accountRows: [V]? = nil, naming: Naming) {
        self.sessions = sessions; self.projects = projects; self.stateRoot = stateRoot; self.homeRoot = homeRoot
        self.accountRows = accountRows; self.naming = naming
    }

    static func session(_ id: String, cwd: String, title: String = "api", provider: String = "claude", exitCode: Double? = nil, createdAt: Double = 1_000) -> V {
        BackendDeckCoreTestPortSecurityValue.object([("id", .string(id)), ("cwd", .string(cwd)), ("title", .string(title)),
            ("provider", .string(provider)), ("exitCode", exitCode.map(V.number) ?? .null), ("createdAt", .number(createdAt))])
    }
    /// sessions-lane.fixture.ts `fakeSurface()`: two sessions the person started,
    /// two open folders, and no account chooser.
    static func lane() -> BackendDeckCoreTestPortS1StartSurface {
        BackendDeckCoreTestPortS1StartSurface(sessions: [session("s1", cwd: "/work/api"), session("s2", cwd: "/work/web", title: "web")],
            projects: ["/work/api", "/work/web"], stateRoot: "/state", homeRoot: "/state/copilot", naming: .lane)
    }

    /// The fake clock delivery runs on: `sleep` moves it, nothing waits.
    var clock: BackendDeckCoreBriefClock {
        let box = self.instant
        return BackendDeckCoreBriefClock(now: { box.get() }, sleep: { delta in box.edit { $0 += delta } })
    }

    private func typeInto(_ data: String) {
        typed.append(data)
        if screen != nil { screen = data == "\r" ? "❯ " : "❯ " + String(data.prefix(60)) }
    }
    private func look() -> String? {
        if exitOnLook, let last = sessions.indices.last { sessions[last] = sessions[last].setting("exitCode", .number(1)) }
        return screen
    }

    func listSessions() -> [V] { sessions }
    func listProjects() -> [V] { projects.map { BackendDeckCoreTestPortSecurityValue.object([("path", .string($0)), ("lastOpenedAt", .number(1))]) } }
    func sessionStatus(_ sessionID: String) -> V { .null }
    func appStateRoot() -> String { stateRoot }
    func copilotRoot() -> String { homeRoot }
    func accounts() -> [V]? { accountRows }
    func windows(sessionID: String) -> [V] { [] }
    func readSettings() -> V { .object([.init("settings", .object([])), .init("preferences", .object([]))]) }
    func startSession(input: V, forDevice: String?) async throws -> V {
        started.append(input)
        let cwd = input["cwd"].string ?? ""
        let meta: V
        switch naming {
        case .lane: meta = Self.session("new-\(sessions.count + 1)", cwd: cwd)
        case .copilot: meta = Self.session("copilot-\(started.count)", cwd: cwd, title: "work", provider: input["provider"].string ?? "claude", createdAt: 5_000)
        }
        sessions.append(meta); return meta
    }
    func writeToSession(_ sessionID: String, data: String) async throws { typeInto(data) }
    func sessionScreen(_ sessionID: String) async throws -> String? { look() }
    func killSession(_ sessionID: String) async throws {}
    func writeSpec(directory: String, input: V) throws -> V {
        try BackendDeckCoreBrief.writeSpec(directory: URL(fileURLWithPath: directory, isDirectory: true), input: input, ownership: .exclusive)
    }
    func deliverBrief(_ sessionID: String, line: String) async throws -> V {
        try await BackendDeckCoreBrief.deliver(surface: self, sessionID: sessionID, line: line, clock: clock)
    }
    // BackendDeckCoreBriefSurface: the same screen and the same keyboard.
    func sessionScreen(id: String) async throws -> String? { look() }
    func writeToSession(id: String, data: String) async throws { typeInto(data) }
}

enum BackendDeckCoreTestPortS1StartFixture {
    typealias V = NativeRPCValue
    /// start-guards.test.ts: `Date.parse('2026-08-17T09:42:00')`, a local wall-clock time.
    static let guardsNow: Double = {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 8; parts.day = 17; parts.hour = 9; parts.minute = 42; parts.second = 0
        return (Calendar(identifier: .gregorian).date(from: parts) ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000
    }()
    /// The person at this keyboard (LOCAL_CALLER), attended, with the
    /// copilot-owned set the context writes to when it starts something.
    static func context(callID: String, now: Double, owned: BackendDeckCoreSecurityTestBox<Set<String>>, limits: V = .missing) -> BackendDeckCoreSecurityCallContext {
        .init(native: BackendDeckCoreTestPortToolsFixture.caller(), caller: .local, callID: callID, attended: true, granted: nil, sessionLimits: limits,
              now: { now }, startedByCopilot: { owned.get().contains($0) }, noteStarted: { id in owned.edit { _ = $0.insert(id) } })
    }
    /// `sessions.start` out of the real catalogue, bound to this surface.
    static func start(_ surface: BackendDeckCoreTestPortS1StartSurface) throws -> BackendDeckCoreSecurityToolPolicy {
        let bundle = try BackendDeckCoreCatalogueBuiltins.tools(surface: surface)
        return try XCTUnwrap(bundle.policies.first { $0.tool.id == "sessions.start" })
    }
}
