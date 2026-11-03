#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

public protocol BackendHOSTSessionSwitching: Sendable {
    func subject(sessionID: String, accountID: String) async throws -> BackendSessionSwitchPlan
    func perform(sessionID: String, accountID: String, note: String) async throws -> BackendSessionSwitchCoordinator.Execution
    /// 18 Oct (#416): a cancel the session host refuses throws its reason; it never looks done.
    func cancel(sessionID: String) async throws
    func stop() async
    /// 13 Oct: the account an in-place switch has handed the session, until the agent's next request proves it.
    func pendingAccount(sessionID: String) async -> BackendAccountIdentity?
}
extension BackendHOSTSessionSwitching {
    public func perform(sessionID: String, accountID: String) async throws -> BackendSessionSwitchCoordinator.Execution {
        try await perform(sessionID: sessionID, accountID: accountID, note: "")
    }
}
extension BackendSessionSwitchCoordinator: BackendHOSTSessionSwitching {}
/// 12 Oct: the hosted app's switch, which offers a restart where the host cannot switch in place.
extension BackendSessionSwitchRestartFallback: BackendHOSTSessionSwitching {}
public protocol BackendHOSTSessionDeferring: Sendable {
    func arm(sessionID: String, accountID: String) async throws -> NativeRPCValue
    /// 18 Oct (#416): a list the session host cannot give throws, never reads as "nothing waiting".
    func list() async throws -> [BackendSessionSwitchDeferred.Armed]
    func cancel(sessionID: String) async throws
    func recoveryDraft(sessionID: String) async -> String?
    func stop() async
}
extension BackendSessionSwitchDeferred: BackendHOSTSessionDeferring {}
extension BackendSessionLifecycleRPC: BackendHOSTAccountChannelInvoking {}
extension BackendSessionHookRPC: BackendHOSTAccountChannelInvoking {}
public protocol BackendHOSTSessionHookObserving: Sendable {
    func observeAccepted(_ callback: @escaping @Sendable (BackendSessionHookEvent) async -> Void) async -> UUID
    func removeAcceptedObserver(_ id: UUID) async
    func stop() async
}
extension BackendSessionHookCoordinator: BackendHOSTSessionHookObserving {}
public struct BackendHOSTSuppliedSessionHookObserving: BackendHOSTSessionHookObserving {
    private let observe: @Sendable (@escaping @Sendable (BackendSessionHookEvent) async -> Void) async -> UUID
    private let remove: @Sendable (UUID) async -> Void
    private let close: @Sendable () async -> Void
    public init(observe: @escaping @Sendable (@escaping @Sendable (BackendSessionHookEvent) async -> Void) async -> UUID,
                remove: @escaping @Sendable (UUID) async -> Void, stop: @escaping @Sendable () async -> Void) {
        self.observe = observe; self.remove = remove; close = stop
    }
    public func observeAccepted(_ callback: @escaping @Sendable (BackendSessionHookEvent) async -> Void) async -> UUID { await observe(callback) }
    public func removeAcceptedObserver(_ id: UUID) async { await remove(id) }
    public func stop() async { await close() }
}

/// Typed operations supplied by the ACTUAL helper switch owner. There are no
/// success/default closures and no app-side pending-switch or broker state.
public struct BackendHOSTSuppliedSessionSwitching: BackendHOSTSessionSwitching {
    private let plan: @Sendable (String, String) async throws -> BackendSessionSwitchPlan
    private let run: @Sendable (String, String, String) async throws -> BackendSessionSwitchCoordinator.Execution
    private let cancelOwned: @Sendable (String) async throws -> Void
    private let stopOwned: @Sendable () async -> Void
    private let pendingOwned: @Sendable (String) async -> BackendAccountIdentity?
    public init(subject: @escaping @Sendable (String, String) async throws -> BackendSessionSwitchPlan,
                perform: @escaping @Sendable (String, String, String) async throws -> BackendSessionSwitchCoordinator.Execution,
                cancel: @escaping @Sendable (String) async throws -> Void, stop: @escaping @Sendable () async -> Void,
                pending: @escaping @Sendable (String) async -> BackendAccountIdentity? = { _ in nil }) {
        plan = subject; run = perform; cancelOwned = cancel; stopOwned = stop; pendingOwned = pending
    }
    public func subject(sessionID: String, accountID: String) async throws -> BackendSessionSwitchPlan { try await plan(sessionID, accountID) }
    public func perform(sessionID: String, accountID: String, note: String) async throws -> BackendSessionSwitchCoordinator.Execution { try await run(sessionID, accountID, note) }
    public func cancel(sessionID: String) async throws { try await cancelOwned(sessionID) }
    public func stop() async { await stopOwned() }
    public func pendingAccount(sessionID: String) async -> BackendAccountIdentity? { await pendingOwned(sessionID) }
}
public struct BackendHOSTSuppliedSessionDeferring: BackendHOSTSessionDeferring {
    private let request: @Sendable (String, String) async throws -> NativeRPCValue
    private let current: @Sendable () async throws -> [BackendSessionSwitchDeferred.Armed]
    private let cancelOwned: @Sendable (String) async throws -> Void
    private let draft: @Sendable (String) async -> String?
    private let stopOwned: @Sendable () async -> Void
    public init(arm: @escaping @Sendable (String, String) async throws -> NativeRPCValue,
                list: @escaping @Sendable () async throws -> [BackendSessionSwitchDeferred.Armed],
                cancel: @escaping @Sendable (String) async throws -> Void,
                recoveryDraft: @escaping @Sendable (String) async -> String?, stop: @escaping @Sendable () async -> Void) {
        request = arm; current = list; cancelOwned = cancel; draft = recoveryDraft; stopOwned = stop
    }
    public func arm(sessionID: String, accountID: String) async throws -> NativeRPCValue { try await request(sessionID, accountID) }
    public func list() async throws -> [BackendSessionSwitchDeferred.Armed] { try await current() }
    public func cancel(sessionID: String) async throws { try await cancelOwned(sessionID) }
    public func recoveryDraft(sessionID: String) async -> String? { await draft(sessionID) }
    public func stop() async { await stopOwned() }
}
/// These controls belong to real composition, not fabricated local actors.
/// closeAfterDrain must return the helper's actual Codex release result; keep
/// cannot call it because pending switches/files/accounts remain helper-owned.
public struct BackendHOSTAccountSessionControls: Sendable {
    public let switches: any BackendHOSTSessionSwitching
    public let deferred: any BackendHOSTSessionDeferring
    public let hooks: any BackendHOSTAccountChannelInvoking
    public let hookObservation: any BackendHOSTSessionHookObserving
    public let hookEndpoint: BackendSessionHookEndpoint
    public let detachForKeep: @Sendable () async throws -> Void
    public let closeAfterDrain: @Sendable () async throws -> [String: BackendAccountCodexLease.Release]
    public init(switches: any BackendHOSTSessionSwitching, deferred: any BackendHOSTSessionDeferring,
                hooks: any BackendHOSTAccountChannelInvoking, hookObservation: any BackendHOSTSessionHookObserving,
                hookEndpoint: BackendSessionHookEndpoint,
                detachForKeep: @escaping @Sendable () async throws -> Void,
                closeAfterDrain: @escaping @Sendable () async throws -> [String: BackendAccountCodexLease.Release]) {
        self.switches = switches; self.deferred = deferred; self.hooks = hooks; self.hookObservation = hookObservation; self.hookEndpoint = hookEndpoint
        self.detachForKeep = detachForKeep; self.closeAfterDrain = closeAfterDrain
    }
}
#endif
