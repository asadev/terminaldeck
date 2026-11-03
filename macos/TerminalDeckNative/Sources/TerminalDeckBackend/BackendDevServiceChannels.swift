import Foundation
import TerminalDeckNativeCore

public enum BackendDevServiceChannels {
    public struct Handle: Sendable { public let channels: [String]; public let stateListener: UUID; public let logListener: UUID? }
    /// Root supplies its actual authorized broadcast, not a global publication
    /// of private session logs. Forward PTY data/exit into the service separately.
    public static func register(registry: NativeChannelRegistry, ownerID: String, projects: BackendProjectService,
                                ports: BackendDevPortDiscovery, servers: BackendDevServers,
                                broadcastState: @escaping @Sendable (NativeRPCValue) async -> Void,
                                broadcastLog: (@Sendable (String, String) async -> Void)? = nil) async throws -> Handle {
        try await registry.register("dev:ports", ownerID: ownerID) { context, args in try context.require("dev.read"); return .array(try await ports.scan(force: context.argument(0, in: args).bool == true).map(\.wireValue)) }
        try await registry.register("dev:server:list", ownerID: ownerID) { context, _ in
            try context.require("dev.read"); var states: [NativeRPCValue] = []
            for project in await projects.list().elements ?? [] { if let folder = project["path"].string { states.append(try await servers.status(folder: folder, context: context)) } }
            return .array(states)
        }
        try await registry.register("dev:server:start", ownerID: ownerID) { context, args in
            try context.require("dev.start")
            guard let folder = context.argument(0, in: args).string, !folder.isEmpty, (try? await projects.requireKnown(folder)) != nil else { return .null }
            return try await servers.start(folder: folder, context: context)
        }
        let state = await servers.onChange(broadcastState)
        let logs: UUID?
        if let broadcastLog { logs = await servers.onLog(broadcastLog) } else { logs = nil }
        return Handle(channels: ["dev:ports", "dev:server:list", "dev:server:start"], stateListener: state, logListener: logs)
    }
    public static func unregister(_ handle: Handle, servers: BackendDevServers) async { await servers.removeListener(handle.stateListener); if let log = handle.logListener { await servers.removeListener(log) } }
}
