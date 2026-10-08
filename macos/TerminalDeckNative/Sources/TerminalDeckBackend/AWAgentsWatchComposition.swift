import Foundation
import TerminalDeckNativeCore

public extension BackendCompositionRoot {
    /// DKA calls this with the existing task/session/HOOT owners after binding
    /// their authority. Registration itself starts no stream or file watcher.
    func installAgentsWatch(source: any AWAgentsWatchSource) async throws {
        let owner = "native-composition:agents-watch"
        let service = AWAgentsWatchService(source: source)
        try await AWAgentsWatchRegistration.install(registry: registry, server: mcp, service: service, ownerID: owner)
        do {
            try await retain(.init(name: "agents-watch", domains: ["agents-watch"], ownerID: owner,
                invokes: Set(AWAgentsWatchRegistration.operations.map { "agents-watch:" + $0 }), sends: [], events: ["agents-watch:changed"],
                stop: { [registry, mcp] in await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner) }))
        } catch {
            await registry.removeOwner(owner); await mcp.removeTools(ownerID: owner); throw error
        }
    }
}
