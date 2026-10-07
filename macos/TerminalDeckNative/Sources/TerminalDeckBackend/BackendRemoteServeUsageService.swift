import Foundation
import TerminalDeckNativeCore

/// Three separate readers preserve usage-serve.ts's cost boundary. Plan never
/// reaches refresh; refresh reads the shared report after its operation settles.
public struct BackendRemoteServeUsageService: Sendable {
    public typealias Plan = @Sendable (String) async throws -> NativeRPCValue
    public typealias Refresh = @Sendable (String, Bool) async throws -> NativeRPCValue
    public typealias Context = @Sendable (String, NativeRPCContext) async throws -> NativeRPCValue
    private let plan: Plan, refresh: Refresh, context: Context
    public init(plan: @escaping Plan, refresh: @escaping Refresh, context: @escaping Context) { self.plan = plan; self.refresh = refresh; self.context = context }
    public init(usage: BackendUsageService) {
        plan = { try await usage.read(sessionID: $0).wireValue }
        refresh = { id, force in
            let result = try await usage.refresh(sessionID: id, force: force).wireValue
            let report = try await usage.read(sessionID: id).wireValue
            return result.setting("report", report)
        }
        context = { try await usage.contextWindow(sessionID: $0, context: $1) }
    }
    public func reading(sessionID: String, want: String, force: Bool = false, rpcContext: NativeRPCContext) async throws -> NativeRPCValue {
        switch want {
        case "plan": return try await plan(sessionID)
        case "refresh": return try await refresh(sessionID, force)
        case "context": return try await context(sessionID, rpcContext)
        default: throw NativeRPCError.invalidArguments("Unknown remote usage reading")
        }
    }
    public func feature(gate: BackendRemoteServeSessionGate) -> BackendRemoteHostFeature {
        .init(capability: "usage", messageTypes: ["usage.read"], policy: .grantedDevice) { message, host in
            let id = try message["id"].requireString("session id"), want = try message["want"].requireString("usage reading")
            guard await gate.visible(deviceID: host.deviceID, sessionID: id) else { return [try .error(code: "unknown-session", message: BackendRemoteServeSessionPolicy.noSuchSession(id))] }
            let value = try await reading(sessionID: id, want: want, force: message["force"].bool == true, rpcContext: host.rpcContext)
            return [try .init(.usageReading, fields: [.init("rid", message["rid"]), .init("id", .string(id)), .init("want", .string(want)), .init("answer", .object([.init("reading", value)]))])]
        }
    }
    /// Exact emptyUsageReading projection used by hidden-session wrappers.
    public static func empty(want: String, detail: String, now: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue {
        if want == "context" {
            return .object([.init("provider", .null), .init("state", .string("not-reported")), .init("tokens", .null), .init("window", .null), .init("percent", .null), .init("windowBasis", .null), .init("model", .null), .init("modelLabel", .null), .init("source", .null), .init("reportedAt", .number(0)), .init("observedAt", .number(now)), .init("detail", .string(detail))])
        }
        let report = NativeRPCValue.object([.init("sessionId", .null), .init("readings", .array([])), .init("reason", .string(detail)), .init("account", .null), .init("assembledAt", .number(now))])
        if want == "plan" { return report }
        return .object([.init("ok", .bool(false)), .init("outcome", .string("unwatched")), .init("detail", .string(detail)), .init("elapsedMs", .number(0)), .init("spawned", .bool(false)), .init("report", report)])
    }
}
