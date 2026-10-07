import Foundation
import TerminalDeckNativeCore

/// Supply this existing-protocol adapter to BackendDeckToolsMachinesServers.
/// Its central environment MUST run the tool's policy before calling execute.
/// A key file read here stays inside that tool's add flow and is never returned
/// as a keys/details result. The caller table remains the MCP owner's table.
public struct BackendServersDeckToolsChannels: BackendDeckToolsMachinesChannels, Sendable {
    public let registry: NativeChannelRegistry
    public let other: any BackendDeckToolsMachinesChannels
    public init(registry: NativeChannelRegistry, other: any BackendDeckToolsMachinesChannels) { self.registry = registry; self.other = other }
    public func call(_ channel: String, _ arguments: [NativeRPCValue], context: BackendDeckToolsMachinesContext) async throws -> NativeRPCValue {
        guard channel.hasPrefix("servers:") else { return try await other.call(channel, arguments, context: context) }
        guard BackendServersIPC.channels.contains(channel) || BackendServersReachChannels.channels.contains(channel) else { throw NativeRPCError(code: "unavailable", message: "That native server operation is unavailable.") }
        guard context.actsAsOwner else { throw NativeRPCError(code: "not-permitted", message: "A paired device or remote session cannot manage an SSH server on this computer.") }
        let original = context.rpc
        var capabilities = original.capabilities
        if ["servers:add", "servers:key-read"].contains(channel) { capabilities.insert("servers:credential-input") }
        // This is an internal subcall of the authenticated tool, not a UI
        // request. ownerID still resolves its real local/key caller record.
        let rpc = NativeRPCContext(caller: .internalEngine, ownerID: original.ownerID, origin: original.origin, capabilities: capabilities)
        return try await registry.invoke(channel, context: rpc, arguments: arguments)
    }
}
