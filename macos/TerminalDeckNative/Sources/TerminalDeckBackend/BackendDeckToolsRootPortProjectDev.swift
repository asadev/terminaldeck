import Foundation
import TerminalDeckNativeCore

/// The three source dev-server operations, separated from their concrete
/// process/port owners so the standing parity tests can use fake processes.
/// App composition normally leaves this nil and reuses existing native owners.
public protocol BackendDeckToolsProjectDevAccess: Sendable {
    func list(context: NativeRPCContext) async throws -> [NativeRPCValue]
    func start(folder: String, context: NativeRPCContext) async throws -> NativeRPCValue
    func ports(force: Bool, context: NativeRPCContext) async throws -> NativeRPCValue
}
