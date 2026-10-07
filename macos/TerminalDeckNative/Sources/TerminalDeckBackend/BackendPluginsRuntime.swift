import Foundation
import TerminalDeckNativeCore

/// The host owns permission/lifecycle decisions; the child owns pipes and RPC.
/// Tests supply a deterministic peer without launching a real program. The
/// default factory below is the same concrete native process used by the port.
public protocol BackendPluginsRunningProcess: Sendable {
    var alive: Bool { get async }
    var pid: Int32? { get async }
    func start() async throws
    func request(_ method: String, params: NativeRPCValue, timeoutMilliseconds: Int?) async throws -> NativeRPCValue
    func stop(_ why: String) async
    func kill(_ why: String) async
}
public extension BackendPluginsRunningProcess {
    func request(_ method: String, params: NativeRPCValue) async throws -> NativeRPCValue {
        try await request(method, params: params, timeoutMilliseconds: nil)
    }
}
extension BackendPluginsProcess: BackendPluginsRunningProcess {}

public struct BackendPluginsProcessLaunch: Sendable {
    public let command: String, arguments: [String], cwd: String, environment: [String: String]
    public let requestTimeoutMilliseconds: Int, maximumMessageBytes: Int
}
public typealias BackendPluginsProcessFactory = @Sendable (
    BackendPluginsProcessLaunch,
    @escaping BackendPluginsProcess.RequestHandler,
    @escaping @Sendable (String) async -> Void
) -> any BackendPluginsRunningProcess

public enum BackendPluginsRuntime {
    public static let native: BackendPluginsProcessFactory = { launch, request, exit in
        BackendPluginsProcess(command: launch.command, arguments: launch.arguments, cwd: launch.cwd,
            environment: launch.environment, timeoutMilliseconds: launch.requestTimeoutMilliseconds,
            maximumBytes: launch.maximumMessageBytes, onRequest: request, onExit: exit)
    }
}
