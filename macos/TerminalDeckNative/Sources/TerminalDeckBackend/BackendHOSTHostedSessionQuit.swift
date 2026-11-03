#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
import Foundation
import TerminalDeckNativeCore

public protocol BackendHOSTSessionQuitting: Sendable {
    func decision() async -> BackendSessionLifecycleQuit.Decision
    func apply(keep: Bool) async -> BackendSessionLifecycleQuit.Result
    func foreground() async
}
extension BackendSessionLifecycleQuit: BackendHOSTSessionQuitting {}

/// No helper resource shutdown on keep. Stop returns the ACTUAL helper lease
/// result only after the existing manager confirms all process/descendant drain.
public actor BackendHOSTHostedSessionQuit: BackendHOSTSessionQuitting {
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let ledger: BackendNativeLedger
    private let store: NativeStateStore
    private let controls: BackendHOSTAccountSessionControls
    public init(lifecycle: BackendSessionLifecycleCoordinator, ledger: BackendNativeLedger, store: NativeStateStore,
                controls: BackendHOSTAccountSessionControls) {
        self.lifecycle = lifecycle; self.ledger = ledger; self.store = store; self.controls = controls
    }
    public func decision() async -> BackendSessionLifecycleQuit.Decision {
        let live = lifecycle.manager.list().filter { $0.exitCode == nil }.count
        guard live > 0 else { return .quit }
        switch await store.getQuitBehavior() { case .ask: return .confirm(liveSessions: live); case .keep: return .background(liveSessions: live); case .stop: return .quit }
    }
    public func apply(keep: Bool) async -> BackendSessionLifecycleQuit.Result {
        if keep, lifecycle.manager.localSessionCount() > 0 {
            lifecycle.manager.setWatched(false)
            return .background(liveSessions: lifecycle.manager.list().filter { $0.exitCode == nil }.count)
        }
        // 18 Oct (#111): a Stop quit pauses new sessions the same undoable way, so a recovery list that cannot be
        // saved leaves the app open AND able to start sessions, not open and refusing every new one until relaunch.
        let keepPause = await lifecycle.pauseForHostedKeep()
        do { try await ledger.prepareForQuit() }
        catch {
            await lifecycle.resumeAfterBlockedHostedKeep(keepPause)
            return .blocked("The original recovery ledger could not be saved: " + error.localizedDescription)
        }
        if keep {
            let live = lifecycle.manager.list().filter { $0.exitCode == nil }.count
            // L8 (11 Oct): Hoot's own CLI is an app-owned process holding an account lease in the session host.
            // While it lived the host answered "not safe to detach" and every close of the app failed this
            // hand-over. It cannot outlive the app anyway: end it (and its lease) first, then hand over.
            await BackendHOSTKeepDetachPreparation.run()
            do { try await controls.detachForKeep(); return .detached(liveSessions: live) }
            catch {
                await lifecycle.resumeAfterBlockedHostedKeep(keepPause)
                return .blocked("Actual hosted resource/claim readiness did not permit detach: " + error.localizedDescription)
            }
        }
        await controls.deferred.stop(); await controls.switches.stop()
        guard await lifecycle.stopProcesses() else { return .blocked("Hosted processes/descendants have not drained; account ownership remains in their helper.") }
        do { return .stopped(codexLeases: try await controls.closeAfterDrain()) }
        catch { return .blocked("The actual helper account cleanup could not be confirmed: " + error.localizedDescription) }
    }
    public func foreground() { lifecycle.manager.setWatched(true) }
}
#endif
