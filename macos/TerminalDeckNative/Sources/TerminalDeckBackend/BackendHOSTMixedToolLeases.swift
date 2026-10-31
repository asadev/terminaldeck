#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// Routing is not authorization. Original request/policy/grant checks remain
/// in the real local endpoint or helper. Missing route preserves in-app owner.
public enum BackendHOSTMixedLeaseRoute {
    @TaskLocal public static var hosted = false
    public static func eligible(_ input: BackendCreateSessionInput, _ context: BackendLaunchContext) -> Bool {
        // A chat session's AI runs in the app (as Hoot's does), never in the session helper.
        input.chat != true && (input.origin == nil || input.origin == .user) && input.taskID == nil && input.taskProject == nil &&
            input.originApp == nil && input.originRoutineId == nil && input.originRunId == nil &&
            context.deviceBoundary == nil && context.appFenceID == nil && !context.isAppComposed
    }
}
/// One dispatch table for actual original local leases and actual HOST proxies.
/// Never uses an all-ids list or reconstructs tokens/configs/grants.
public actor BackendHOSTMixedToolLeases: BackendHOSTOrdinaryToolLeaseOwner, BackendHOSTProjectToolLeaseOwner {
    public nonisolated let readiness: BackendLaunchReadiness
    private enum Owner: Hashable, Sendable { case localOrdinary, hostOrdinary, localProject, hostProject }
    private struct Bind: Sendable { let session: String, machine: String; let task: Task<Void, Error> }
    private struct Entry: Sendable { let owner: Owner; var bind: Bind? }
    private let localOrdinary: BackendSessionToolLeases, localProject: BackendProjectToolComposition
    private let hostOrdinary: BackendHOSTToolLeaseProxy, hostProject: BackendHOSTProjectToolProxy
    private var entries: [UUID: Entry] = [:]
    private var fileLeases: [UUID: BackendAGSLaunchFileLease] = [:]
    private var closed = false
    public init(localOrdinary: BackendSessionToolLeases, localProject: BackendProjectToolComposition,
                hostOrdinary: BackendHOSTToolLeaseProxy, hostProject: BackendHOSTProjectToolProxy) throws {
        guard localOrdinary.readiness == .ready, localProject.readiness == .ready,
              hostOrdinary.readiness == .ready, hostProject.readiness == .ready else { throw BackendHOSTFailure.unavailable }
        self.localOrdinary = localOrdinary; self.localProject = localProject; self.hostOrdinary = hostOrdinary; self.hostProject = hostProject
        readiness = .ready
    }
    public var count: Int { get async {
        let local = await localOrdinary.count
        let hosted = await hostOrdinary.count
        return local + hosted
    } }
    public func prepareOrdinary(restricting: [String]?, deniedTools: [String], taskID: String?, taskProject: String?) async throws -> BackendPreparedToolLease? {
        guard !closed else { throw BackendSessionFailure.closed }
        let host = BackendHOSTMixedLeaseRoute.hosted
        let value: BackendPreparedToolLease?
        if host { value = try await hostOrdinary.prepareOrdinary(restricting: restricting, deniedTools: deniedTools, taskID: taskID, taskProject: taskProject) }
        else { value = try await localOrdinary.prepareOrdinary(restricting: restricting, deniedTools: deniedTools, taskID: taskID, taskProject: taskProject) }
        if let value {
            entries[value.id] = .init(owner: host ? .hostOrdinary : .localOrdinary)
            guard !closed, !Task.isCancelled else { await abandon(value.id); throw BackendSessionFailure.closed }
        }
        return value
    }
    public func reserveAgentSettingsFiles() async throws -> BackendAGSLaunchFileLease {
        guard !closed else { throw BackendSessionFailure.closed }
        let host = BackendHOSTMixedLeaseRoute.hosted
        let value: BackendAGSLaunchFileLease
        if host { value = try await hostOrdinary.reserveAgentSettingsFiles() }
        else { value = try await localOrdinary.reserveAgentSettingsFiles() }
        entries[value.id] = .init(owner: host ? .hostOrdinary : .localOrdinary)
        fileLeases[value.id] = value
        guard !closed, !Task.isCancelled else { await abandon(value.id); throw BackendSessionFailure.closed }
        return .init(id: value.id, directory: value.directory, write: value.write, bind: { [weak self] session in
            guard let self else { throw BackendSessionFailure.closed }
            try await self.bindSettings(value.id, sessionID: session)
        }, abandon: { [weak self] in await self?.abandon(value.id) })
    }
    public func prepare(provider: String, cwd: String, loginPath: String, allowedTools: [String]?, deniedTools: [String], taskID: String?, taskProject: String?) async throws -> BackendPreparedProjectTools? {
        guard !closed else { throw BackendSessionFailure.closed }
        let host = BackendHOSTMixedLeaseRoute.hosted
        let value: BackendPreparedProjectTools?
        if host { value = try await hostProject.prepare(provider: provider, cwd: cwd, loginPath: loginPath, allowedTools: allowedTools,
            deniedTools: deniedTools, taskID: taskID, taskProject: taskProject) }
        else { value = try await localProject.prepare(provider: provider, cwd: cwd, loginPath: loginPath,
            allowedTools: allowedTools, deniedTools: deniedTools, taskID: taskID, taskProject: taskProject) }
        if let value {
            entries[value.id] = .init(owner: host ? .hostProject : .localProject)
            guard !closed, !Task.isCancelled else { await abandon(value.id); throw BackendSessionFailure.closed }
        }
        return value
    }
    public func agentSettingsServerName(provider: String, cwd: String, loginPath: String) async throws -> String? {
        guard !closed else { throw BackendSessionFailure.closed }
        if BackendHOSTMixedLeaseRoute.hosted { return try await hostProject.agentSettingsServerName(provider: provider, cwd: cwd, loginPath: loginPath) }
        return try await localProject.agentSettingsServerName(provider: provider, cwd: cwd, loginPath: loginPath)
    }
    public func agentSettingsConfiguration(_ id: UUID) async throws -> NativeRPCValue {
        guard let entry = entries[id] else { throw BackendSessionFailure.closed }
        switch entry.owner {
        case .localOrdinary: return try await localOrdinary.agentSettingsConfiguration(id)
        case .hostOrdinary: return try await hostOrdinary.agentSettingsConfiguration(id)
        case .localProject: return try await localProject.agentSettingsConfiguration(id)
        case .hostProject: return try await hostProject.agentSettingsConfiguration(id)
        }
    }
    public func bind(_ id: UUID, sessionID: String, machineID: String) async throws {
        guard !closed, var entry = entries[id] else { throw BackendSessionFailure.closed }
        if let existing = entry.bind {
            guard existing.session == sessionID, existing.machine == machineID else { throw BackendHOSTFailure.authentication }
            try await existing.task.value; return
        }
        let localOrdinary = localOrdinary, localProject = localProject, hostOrdinary = hostOrdinary, hostProject = hostProject, owner = entry.owner
        let task = Task<Void, Error> {
            switch owner {
            case .localOrdinary: try await localOrdinary.bind(id, sessionID: sessionID, machineID: machineID)
            case .hostOrdinary: try await hostOrdinary.bind(id, sessionID: sessionID, machineID: machineID)
            case .localProject: try await localProject.bind(id, sessionID: sessionID)
            case .hostProject: try await hostProject.bind(id, sessionID: sessionID)
            }
        }
        entry.bind = .init(session: sessionID, machine: machineID, task: task); entries[id] = entry
        do { try await task.value } catch { await abandon(id); throw error }
    }
    public func bind(_ id: UUID, sessionID: String) async throws { try await bind(id, sessionID: sessionID, machineID: "") }
    private func bindSettings(_ id: UUID, sessionID: String) async throws {
        guard !closed, var entry = entries[id], let lease = fileLeases[id] else { throw BackendSessionFailure.closed }
        if let existing = entry.bind {
            guard existing.session == sessionID else { throw BackendHOSTFailure.authentication }
            try await existing.task.value; return
        }
        // Call the original file lease closure. Its host implementation retains
        // the actual pre-exec machine identity rather than inventing one here.
        let task = Task<Void, Error> { try await lease.bind(sessionID) }
        entry.bind = .init(session: sessionID, machine: "", task: task); entries[id] = entry
        do { try await task.value } catch { await abandon(id); throw error }
    }
    public func abandon(_ id: UUID) async {
        guard let entry = entries.removeValue(forKey: id) else { return }
        fileLeases[id] = nil
        if let bind = entry.bind { _ = try? await bind.task.value }
        switch entry.owner {
        case .localOrdinary: await localOrdinary.abandon(id)
        case .hostOrdinary: await hostOrdinary.abandon(id)
        case .localProject: await localProject.abandon(id)
        case .hostProject: await hostProject.abandon(id)
        }
    }
    public func release(sessionID: String) async {
        let owned = entries.filter { $0.value.bind?.session == sessionID }
        for (id, entry) in owned {
            entries[id] = nil; fileLeases[id] = nil
            if let bind = entry.bind { _ = try? await bind.task.value }
        }
        // Session release is distinct from abandoned preparation. Delegate to
        // the original owner so HOST's once-only late-bind receipt survives.
        for owner in Set(owned.values.map(\.owner)) {
            switch owner {
            case .localOrdinary: await localOrdinary.release(sessionID: sessionID)
            case .hostOrdinary: await hostOrdinary.release(sessionID: sessionID)
            case .localProject: await localProject.release(sessionID: sessionID)
            case .hostProject: await hostProject.release(sessionID: sessionID)
            }
        }
    }
    public func stop() async {
        closed = true
        for entry in entries.values { if let bind = entry.bind { _ = try? await bind.task.value } }
        // Call only after original in-app processes are stopped. HOST proxy
        // stop detaches cache; it does not revoke helper callers/private files.
        await localOrdinary.stop(); await localProject.stop(); await hostOrdinary.stop(); await hostProject.stop()
        entries.removeAll(); fileLeases.removeAll()
    }
}
#endif
