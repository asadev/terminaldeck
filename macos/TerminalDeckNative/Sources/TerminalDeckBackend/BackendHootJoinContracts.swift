import Foundation
import TerminalDeckNativeCore

public enum BackendHootRegistrationSource: Equatable, Sendable { case window, island, catcher, unrelated }
/// Consult the real current app/window/panel authentication owner. A nativeApp
/// tag, attendance, caller-provided argument or a cached string is not identity.
public protocol BackendHootRegistrationAuthority: Sendable {
    func source(_ context: NativeRPCContext) throws -> BackendHootRegistrationSource
}
public enum BackendHootJoinCapability: String, CaseIterable, Hashable, Sendable {
    case sharedRawWriter, hiddenBeforeSpawn, measuredRecordsWrapper, managedRecordsAccount, bootTranscriptScope, quiescentShutdown
}
/// Read this receipt from the actual owners' installed supplier identities.
/// The root must not construct it from declared settings or assumed readiness.
public struct BackendHootJoinReceipt: Sendable {
    public let runtime: BackendCopilotSessionRuntime
    public let manager: BackendPTYManager
    public let mcpDoor: BackendCopilotSessionMCPDoor
    public let actionLog: BackendDeckCoreSecurityActionLog
    public let homeSink: any BackendHootJoinRawActionSink
    public let toolSink: any BackendHootJoinRawActionSink
    public let hidden: BackendRemoteServeSessionHidden
    public let homeScope: NativeTranscriptHomeScope
    public let capabilities: Set<BackendHootJoinCapability>
    public init(runtime: BackendCopilotSessionRuntime, manager: BackendPTYManager, mcpDoor: BackendCopilotSessionMCPDoor,
                actionLog: BackendDeckCoreSecurityActionLog, homeSink: any BackendHootJoinRawActionSink,
                toolSink: any BackendHootJoinRawActionSink, hidden: BackendRemoteServeSessionHidden,
                homeScope: NativeTranscriptHomeScope, capabilities: Set<BackendHootJoinCapability>) {
        self.runtime = runtime; self.manager = manager; self.mcpDoor = mcpDoor; self.actionLog = actionLog
        self.homeSink = homeSink; self.toolSink = toolSink; self.hidden = hidden; self.homeScope = homeScope; self.capabilities = capabilities
    }
}
public protocol BackendHootRegistrationGraphJoins: Sendable {
    /// Read-only check; no process/fence probes, writers or observers start.
    func installed() async throws -> BackendHootJoinReceipt
    /// Await pending actual assistant launches, stop the same desk/phone Hoot
    /// owner, and prove no assistant can still spawn. Never stop all fleet PTYs.
    func quiesceAndStopHoot() async throws
    /// Feed the genuine disconnected window to the existing consent/UI owner.
    func windowGone(_ context: NativeRPCContext) async throws
}
public struct BackendHootRegistrationUnavailableJoins: BackendHootRegistrationGraphJoins {
    public init() {}
    private func failure() -> NativeRPCError { .init(code: "unavailable", message: "The shared Hoot writer, measured launch, hidden-at-spawn and shutdown joins are unavailable.") }
    public func installed() async throws -> BackendHootJoinReceipt { throw failure() }
    public func quiesceAndStopHoot() async throws { throw failure() }
    public func windowGone(_ context: NativeRPCContext) async throws { throw failure() }
}

/// UI projection only, not a second session/state/identity owner. The existing
/// menu-bar dependencies read these cached actual runtime/lifecycle snapshots.
@MainActor public final class BackendHootJoinMenuSnapshot {
    public private(set) var hoot: BackendHootMenuSessionState
    public private(set) var sessions: [IslandSessionRow] = []
    public init(dataRoot: URL) { hoot = .init(status: "stopped", cwd: BackendCopilotHome.defaultHome(dataRoot.path)) }
    public func update(_ state: BackendCopilotSessionState, metadata: [BackendSessionLifecycleCoordinator.Metadata]) {
        let actual = metadata.first { $0.session.id == state.sessionId }?.session
        hoot = .init(status: state.status.rawValue, problem: state.problem, sessionID: state.sessionId,
            cwd: actual?.cwd ?? state.folder.runningIn ?? state.paths.root, agentSessionID: actual?.agentSessionId)
        sessions = metadata.map { .init(id: $0.session.id, label: $0.session.title, status: $0.status.rawValue) }
    }
}
