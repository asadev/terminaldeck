import Foundation
import TerminalDeckNativeCore

/// Native app close policy. Keeping sessions means retaining this Swift process
/// in the background; terminating it would falsely promise surviving PTYs.
public actor BackendSessionLifecycleQuit {
    public enum Decision: Sendable { case quit, confirm(liveSessions: Int), background(liveSessions: Int) }
    public enum Result: Sendable {
        case background(liveSessions: Int)
        case stopped(codexLeases: [String: BackendAccountCodexLease.Release])
        case blocked(String)
    }
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let switches: BackendSessionSwitchCoordinator
    private let deferred: BackendSessionSwitchDeferred
    private let accounts: BackendAccountLaunchAdapter
    private let store: NativeStateStore
    private let ledger: BackendNativeLedger
    private let hooks: BackendSessionHookServer
    public init(lifecycle: BackendSessionLifecycleCoordinator, switches: BackendSessionSwitchCoordinator, deferred: BackendSessionSwitchDeferred,
                accounts: BackendAccountLaunchAdapter, store: NativeStateStore, ledger: BackendNativeLedger, hooks: BackendSessionHookServer) {
        self.lifecycle = lifecycle; self.switches = switches; self.deferred = deferred; self.accounts = accounts; self.store = store; self.ledger = ledger; self.hooks = hooks
    }
    public func decision() async -> Decision {
        let live = lifecycle.manager.list().filter { $0.exitCode == nil }.count
        guard live > 0 else { return .quit }
        switch await store.getQuitBehavior() { case .ask: return .confirm(liveSessions: live); case .keep: return .background(liveSessions: live); case .stop: return .quit }
    }
    public func apply(keep: Bool) async -> Result {
        let live = lifecycle.manager.list().filter { $0.exitCode == nil }.count
        if keep && live > 0 {
            // Root cancels NSApplication termination, hides/closes its windows,
            // and keeps hooks, accounts, transports and the PTY owner alive.
            lifecycle.manager.setWatched(false)
            return .background(liveSessions: live)
        }
        await lifecycle.stopAccepting()
        await deferred.stop()
        await switches.stop()
        do { try await ledger.prepareForQuit() }
        catch { return .blocked("The recovery ledger could not be saved before shutdown: " + error.localizedDescription) }
        guard await lifecycle.stopProcesses() else { return .blocked("Owned session processes have not all exited. Their credential leases and stores remain open.") }
        let leases = await accounts.shutdown()
        hooks.stop()
        return .stopped(codexLeases: leases)
    }
    public func foreground() { lifecycle.manager.setWatched(true) }
}
