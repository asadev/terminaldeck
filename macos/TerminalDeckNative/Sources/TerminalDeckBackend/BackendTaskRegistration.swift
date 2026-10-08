import Foundation
import TerminalDeckNativeCore

/// Retained task area. Installing handlers starts no store, clock, HTTP post,
/// process or chooser. The existing composition root controls the cutover.
public struct BackendTaskRegistration: Sendable {
    public let invokes: [String], tools: [String]
    public let sends: [String] = [], events: [String] = ["tasks:changed"]
    public let ownerID: String
    private let registry: NativeChannelRegistry, server: BackendNativeMCPServer
    private let view: BackendTaskStateView
    private let engine: BackendTaskEngine, detail: BackendTaskDetailService, monitor: BackendTaskTurnMonitor, outbox: BackendTaskOutbox
    public static func install(registry: NativeChannelRegistry, server: BackendNativeMCPServer, ownerID: String,
                               view: BackendTaskStateView, local: BackendTaskLocalService, engine: BackendTaskEngine,
                               detail: BackendTaskDetailService, monitor: BackendTaskTurnMonitor, planning: BackendGoalPlanning,
                               api: BackendTaskAPI?, delegation: BackendTaskDelegation?, dependencies: BackendTaskChannelDependencies,
                               authority: BackendTaskToolAuthority, knowledge: BackendTaskKnowledgeAdapter?, indexed: Bool,
                               readAttachment: (@Sendable (BackendMCPCallContext, String) async throws -> (name: String, mime: String?, bytes: Data))?) async throws -> Self {
        do {
            let invokes = try await BackendTaskChannels.register(registry: registry, ownerID: ownerID, view: view, local: local, engine: engine, detail: detail, dependencies: dependencies)
            let tools = try await BackendTaskMCP.register(server: server, view: view, local: local, engine: engine, detail: detail, planning: planning, api: api, delegation: delegation, indexed: indexed, ownerID: ownerID, authority: authority, knowledge: knowledge, readAttachment: readAttachment)
            return Self(invokes: invokes, tools: tools, ownerID: ownerID, registry: registry, server: server, view: view, engine: engine, detail: detail, monitor: monitor, outbox: view.outbox)
        } catch { await registry.removeOwner(ownerID); await server.removeTools(ownerID: ownerID); throw error }
    }
    public func start() async throws {
        try await view.store.requireWritableOwnership(); try await view.store.start(); try await view.config.start(); try await view.goals.start()
        try await outbox.start()
        do { try await view.config.startImportWatchers(); await monitor.start(); try await engine.start(); try await detail.start() }
        catch { await monitor.stop(); await detail.stop(); try? await engine.stop(); try? await outbox.stop(); throw error }
    }
    public func stop() async throws {
        await view.config.stopImportWatchers(); await monitor.stop(); await detail.stop()
        var failure: (any Error)?
        do { try await engine.stop() } catch { failure = error }
        do { try await outbox.stop() } catch { if failure == nil { failure = error } }
        await registry.removeOwner(ownerID); await server.removeTools(ownerID: ownerID)
        if let failure { throw failure }
    }
    public func disconnect(ownerID: String) async { await registry.removeOwner(ownerID) }
}

/// Actual authorized-UI event fanout. Each private store's changed callback
/// should call changed(); the view/key/grant owner is bound after construction.
public actor BackendTaskChangeBus {
    private var publish: (@Sendable () async throws -> Void)?
    private let problem: @Sendable (String) async -> Void
    private var pending: Task<Void, Never>?, stopped = false
    public init(problem: @escaping @Sendable (String) async -> Void) { self.problem = problem }
    public func bind(registry: NativeChannelRegistry, view: BackendTaskStateView, recipients: @escaping @Sendable () async -> [String]) {
        publish = { let state = try await view.state(); for owner in await recipients() { try await registry.publish("tasks:changed", arguments: [state], ownerID: owner) } }
    }
    public func changed() {
        guard !stopped, pending == nil, publish != nil else { return }
        pending = Task { [weak self] in await Task.yield(); await self?.send() }
    }
    private func send() async { pending = nil; guard !stopped, let publish else { return }; do { try await publish() } catch { await problem(error.localizedDescription) } }
    public func stop() { stopped = true; pending?.cancel(); pending = nil; publish = nil }
}
