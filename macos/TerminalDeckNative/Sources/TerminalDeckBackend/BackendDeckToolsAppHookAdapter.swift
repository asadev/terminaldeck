import Foundation
import TerminalDeckNativeCore

/// Reuses the session worker's hook installation owner. Its current sync and
/// offer methods do not expose the source's full result contract, so the three
/// exact domain operations below are required rather than simulated here.
public struct BackendDeckToolsAppHookAdapter: BackendDeckToolsAppHookService, Sendable {
    public let providers = ["claude", "codex", "gemini"]
    private let installation: BackendSessionHookInstallation, access: BackendDeckToolsAppAccess
    private let listener: @Sendable () async throws -> NativeRPCValue
    private let synchronize: @Sendable (NativeRPCContext) async throws -> [NativeRPCValue]
    private let accept: @Sendable (NativeRPCContext) async throws -> [NativeRPCValue]
    private let decline: @Sendable (NativeRPCContext) async throws -> Void
    public init(installation: BackendSessionHookInstallation, access: BackendDeckToolsAppAccess,
                listener: @escaping @Sendable () async throws -> NativeRPCValue,
                synchronize: @escaping @Sendable (NativeRPCContext) async throws -> [NativeRPCValue],
                acceptOffer: @escaping @Sendable (NativeRPCContext) async throws -> [NativeRPCValue],
                declineOffer: @escaping @Sendable (NativeRPCContext) async throws -> Void) {
        self.installation = installation; self.access = access; self.listener = listener
        self.synchronize = synchronize; accept = acceptOffer; decline = declineOffer
    }
    public func status() async throws -> [NativeRPCValue] { await installation.allStatus().map(\.wireValue) }
    public func server() async throws -> NativeRPCValue { try await listener() }
    public func offer() async throws -> NativeRPCValue { await installation.offer() }
    private func write(_ provider: String, caller: BackendMCPCallContext, remove: Bool) async throws -> NativeRPCValue {
        let status: BackendSessionHookInstallation.Status
        do {
            let rpc = try await access.rpc(caller)
            if remove { status = try await installation.remove(provider, context: rpc) }
            else { status = try await installation.install(provider, context: rpc) }
            return BackendDeckToolsAppKit.object([("ok", .bool(status.state != "error")), ("message", .string(status.message)), ("status", status.wireValue)])
        } catch {
            let observed = await installation.status(provider)
            return BackendDeckToolsAppKit.object([("ok", .bool(false)), ("message", .string(error.localizedDescription)), ("status", observed.wireValue)])
        }
    }
    public func install(_ provider: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await write(provider, caller: caller, remove: false) }
    public func remove(_ provider: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue { try await write(provider, caller: caller, remove: true) }
    public func sync(_ caller: BackendMCPCallContext) async throws -> [NativeRPCValue] { try await synchronize(access.rpc(caller)) }
    public func acceptOffer(_ caller: BackendMCPCallContext) async throws -> [NativeRPCValue] { try await accept(access.rpc(caller)) }
    public func declineOffer(_ caller: BackendMCPCallContext) async throws { try await decline(access.rpc(caller)) }
}
