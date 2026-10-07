import Foundation
import TerminalDeckNativeCore

/// SDK metadata listing compiles schemas before a tools/call. The shared pool
/// can opt into that step without changing the existing validation protocol.
public protocol BackendMcpClientOutputPreparing: BackendMcpClientOutputValidating {
    func prepare(schema: NativeRPCValue) async throws
}

/// Preserve the SDK's call-time error envelope while the standalone validator
/// retains the underlying schema compiler's diagnostics for listing errors.
public struct BackendMcpClientJSONSchemaOutput: BackendMcpClientOutputPreparing, Sendable {
    private let validator = BackendMcpClientJSONSchemaValidator()
    public init() {}
    public func prepare(schema: NativeRPCValue) async throws { try validator.prepare(schema: schema) }
    public func validate(schema: NativeRPCValue, value: NativeRPCValue) async throws -> String? {
        do { return try await validator.validate(schema: schema, value: value) }
        catch let failure as BackendMcpClientRPCFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch { throw BackendMcpClientRPCFailure(code: -32602, message: "Failed to validate structured content: " + error.localizedDescription) }
    }
}

/// Native app composition uses this factory (or the explicit validator argument)
/// rather than leaving the existing pool's optional dependency unset. Other
/// workers' pool/service implementations remain the sole owners of MCP IO.
public enum BackendMcpClientJSONSchemaIntegration {
    public static func pool(
        configuration: BackendMcpClientConfiguration,
        loginPath: @escaping @Sendable () async throws -> String,
        timeouts: BackendMcpClientTimeouts = .init(),
        transportFactory: BackendMcpClientPool.Factory? = nil,
        scheduler: any BackendMcpClientDeadlineScheduling = BackendMcpClientDispatchScheduler(),
        onStatus: @escaping @Sendable (NativeRPCValue) async -> Void = { _ in }
    ) -> BackendMcpClientPool {
        BackendMcpClientPool(configuration: configuration, loginPath: loginPath,
            timeouts: timeouts, factory: transportFactory,
            outputValidator: BackendMcpClientJSONSchemaOutput(), scheduler: scheduler, onStatus: onStatus)
    }
}
