import Foundation
import TerminalDeckNativeCore

/// Permission door shared by advanced adapters and the existing host's fanout.
/// Checks current stores on every operation, including held remote handles.
public struct BackendRemoteServeSessionGate: Sendable {
    private let trust: BackendRemoteTrustStore
    private let manager: BackendPTYManager
    private let hidden: BackendRemoteServeSessionHidden
    public init(trust: BackendRemoteTrustStore, manager: BackendPTYManager, hidden: BackendRemoteServeSessionHidden = .shared) {
        self.trust = trust; self.manager = manager; self.hidden = hidden
    }
    public func visible(deviceID: String, sessionID: String) async -> Bool {
        guard let session = manager.list().first(where: { $0.id == sessionID }), !hidden.contains(sessionID),
              await trust.isApproved(deviceID), await trust.sessionShared(deviceID, session: sessionID) else { return false }
        return await trust.canReachFolder(deviceID, folder: session.cwd)
    }
}

/// One event subscription feeds the existing host; no second PTY, listener
/// collection, terminal screen, or scrollback owner is introduced.
public actor BackendRemoteServeSessionFanout {
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let host: BackendRemoteHost
    private let trust: BackendRemoteTrustStore
    private let report: @Sendable (String) -> Void
    private var observer: UUID?
    private var starting = false
    private var revision: UInt64 = 0
    public init(lifecycle: BackendSessionLifecycleCoordinator, host: BackendRemoteHost, trust: BackendRemoteTrustStore,
                report: @escaping @Sendable (String) -> Void = { _ in }) {
        self.lifecycle = lifecycle; self.host = host; self.trust = trust; self.report = report
    }
    public func start() async {
        guard observer == nil, !starting else { return }
        starting = true; revision &+= 1
        let generation = revision
        let installed = await lifecycle.observe { [weak self] event in await self?.note(event, generation: generation) }
        guard generation == revision else { await lifecycle.removeObserver(installed); return }
        starting = false; observer = installed
    }
    public func stop() async {
        revision &+= 1; starting = false
        let installed = observer; observer = nil
        if let installed { await lifecycle.removeObserver(installed) }
    }
    public func note(_ event: BackendSessionEvent) async {
        await host.noteSessionEvent(event)
        switch event {
        case .exit(let id, _), .removed(let id, _):
            do { try await trust.remoteServeDropSession(id) } catch { report("[remote] could not drop an ended session's remote grants: " + error.localizedDescription) }
        default: break
        }
    }
    private func note(_ event: BackendSessionEvent, generation: UInt64) async {
        guard generation == revision else { return }
        await note(event)
    }
}
