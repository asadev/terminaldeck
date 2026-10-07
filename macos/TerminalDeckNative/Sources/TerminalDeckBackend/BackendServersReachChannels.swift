import Foundation
import TerminalDeckNativeCore

/// reach.ts owns these three additional invokes. They use the same server
/// identity, native socket owner and own-ports ledger as the main facade.
public struct BackendServersReachChannels: Sendable {
    public static let channels = ["servers:ports", "servers:reach", "servers:reach:close"]
    public let room: BackendServersCoordinator
    public let reach: BackendServersReach
    public let resolve: @Sendable (NativeRPCContext) async throws -> BackendServersCaller
    public init(room: BackendServersCoordinator, reach: BackendServersReach,
                resolve: @escaping @Sendable (NativeRPCContext) async throws -> BackendServersCaller) {
        self.room = room; self.reach = reach; self.resolve = resolve
    }
    public func register(on registry: NativeChannelRegistry, ownerID: String) async throws {
        var installed: [String] = []
        do {
            for channel in Self.channels {
                try await registry.register(channel, ownerID: ownerID) { context, args in
                    try await invoke(channel, arguments: args, context: context)
                }; installed.append(channel)
            }
        } catch { for channel in installed { await registry.removeHandler(channel, ownerID: ownerID) }; throw error }
    }
    public func invoke(_ channel: String, arguments: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.channels.contains(channel) else { throw NativeRPCError.invalidArguments("No such server reach operation.") }
        let caller = try await resolve(context)
        guard caller.context.ownerID == context.ownerID else { throw NativeRPCError(code: "not-permitted", message: "The server caller identity does not match its authenticated surface.") }
        let closes = channel == "servers:reach:close"
        func refused(_ message: String) -> NativeRPCValue { .object([.init("ok", .bool(false)), .init("message", .string(message))]) }
        guard let id = context.argument(0, in: arguments).string else { return closes ? .bool(false) : refused(channel == "servers:ports" ? "That is not a server." : "That is not a server and a port.") }
        try await room.check(caller, .init(operation: channel, serverId: id, tier: channel == "servers:ports" ? .read : .act))
        if channel == "servers:ports" { return await reach.ports(id) }
        guard let raw = context.argument(1, in: arguments).number else { return closes ? .bool(false) : refused("That is not a server and a port.") }
        guard raw.isFinite, raw.rounded(.towardZero) == raw, (1...65535).contains(raw) else { return closes ? .bool(false) : refused("That is not a port this app can open.") }
        return closes ? .bool(await reach.closeReach(id, port: Int(raw))) : await reach.reach(id, port: Int(raw))
    }
}
