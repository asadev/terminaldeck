import Foundation

/// ipc.ts's two separately reference-counted endpoints. This wraps the real
/// reverse-forward implementation, and owns no caller token or credential.
public actor BackendServersWindowReachPool {
    private struct Key: Hashable { let server: String, kind: String }
    private struct OwnedResult: Sendable { let result: BackendServersWindowReachResult; let lease: BackendServersConnectionLease? }
    private struct Held: Sendable { var users: Int; let generation: UUID; let opening: Task<OwnedResult, Never>; var watcher: Task<Void, Never>? }
    private let connections: BackendServersConnections
    private let endpoint: @Sendable (BackendServersWindowReachKind) async -> BackendServersWindowLocalEnd?
    private var held: [Key: Held] = [:]
    private var stopped = false
    public init(connections: BackendServersConnections,
                endpoint: @escaping @Sendable (BackendServersWindowReachKind) async -> BackendServersWindowLocalEnd?) {
        self.connections = connections; self.endpoint = endpoint
    }
    public func reach(_ server: String, kind: BackendServersWindowReachKind) async -> BackendServersWindowReachResult {
        guard !stopped, let local = await endpoint(kind) else { return .refused(BackendServersWindowDriveReasons.endpoint) }
        guard !stopped else { return .refused(BackendServersWindowDriveReasons.endpoint) }
        let key = Key(server: server, kind: String(describing: kind))
        var entry: Held
        if let existing = held[key] { entry = existing; entry.users += 1 }
        else {
            let connections = self.connections
            let task = Task<OwnedResult, Never> {
                do {
                    let lease = try await connections.acquireLease(server)
                    do {
                        let opened = try await connections.withConnection(server) { connection in
                            await BackendServersWindowReachRules.open(connection: connection, local: local,
                                runScript: { script in try await connections.runScript(server, script: script) })
                        }
                        if case .refused = opened { await connections.release(lease); return .init(result: opened, lease: nil) }
                        return .init(result: opened, lease: lease)
                    } catch { await connections.release(lease); throw error }
                } catch { return .init(result: .refused(error.localizedDescription), lease: nil) }
            }
            entry = Held(users: 1, generation: UUID(), opening: task, watcher: nil)
        }
        held[key] = entry
        let owned = await entry.opening.value, result = owned.result
        guard held[key]?.generation == entry.generation, !stopped else {
            if case .opened(let value) = result { value.close() }
            return .refused(BackendServersWindowDriveReasons.endpoint)
        }
        if case .opened(let reach) = result {
            guard !reach.isClosed else { await dropped(key, generation: entry.generation); return .refused(BackendServersWindowDriveReasons.endpoint) }
            if held[key]?.watcher == nil {
                held[key]?.watcher = Task { [weak self] in await reach.waitForClosed(); await self?.dropped(key, generation: entry.generation) }
            }
        }
        if case .refused = result { await letGo(server, kind: kind) }
        return result
    }
    public func letGo(_ server: String, kind: BackendServersWindowReachKind) async {
        let key = Key(server: server, kind: String(describing: kind))
        guard var entry = held[key] else { return }
        entry.users -= 1
        if entry.users > 0 { held[key] = entry; return }
        held[key] = nil
        let owned = await entry.opening.value
        if case .opened(let reach) = owned.result { reach.close() }
        if let lease = owned.lease { await connections.release(lease) }
    }
    public func stop() async {
        stopped = true; let old = held; held = [:]
        for (key, entry) in old {
            entry.opening.cancel()
            let owned = await entry.opening.value
            if case .opened(let reach) = owned.result { reach.close() }
            if let lease = owned.lease { await connections.release(lease) }
        }
    }
    private func dropped(_ key: Key, generation: UUID) async {
        guard let entry = held[key], entry.generation == generation else { return }
        held[key] = nil
        let owned = await entry.opening.value
        if let lease = owned.lease { await connections.release(lease) }
    }
}
