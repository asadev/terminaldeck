import Foundation
import TerminalDeckNativeCore

/// Three separate readers preserve usage-serve.ts's cost boundary. Plan never
/// reaches refresh; refresh reads the shared report after its operation settles.
public struct BackendRemoteServeUsageService: Sendable {
    public typealias Plan = @Sendable (String) async throws -> NativeRPCValue
    public typealias Refresh = @Sendable (String, Bool) async throws -> NativeRPCValue
    public typealias Context = @Sendable (String, NativeRPCContext) async throws -> NativeRPCValue
    private let plan: Plan, refresh: Refresh, context: Context
    /// The owner's own context: a phone's usage readings run under it, at Full control only (27 Oct, D3).
    private let owner: BackendRemoteOwnerScope.Owner?
    /// Pushes the context reading to the phones following a session (item 74); nil: answers only.
    public let push: BackendRemoteServeUsagePush?
    /// Hoot's own readings (`hoot`, `hoot:task:<id>`): late-bound, Hoot is installed after the remote serve.
    public typealias HootReader = @Sendable () async -> BackendHootUsage?
    private let hoot: HootReader
    public init(plan: @escaping Plan, refresh: @escaping Refresh, context: @escaping Context, owner: BackendRemoteOwnerScope.Owner? = nil,
                push: BackendRemoteServeUsagePush? = nil, hoot: @escaping HootReader = { nil }) {
        self.plan = plan; self.refresh = refresh; self.context = context; self.owner = owner; self.push = push; self.hoot = hoot
    }
    public init(usage: BackendUsageService, owner: BackendRemoteOwnerScope.Owner? = nil, push: BackendRemoteServeUsagePush? = nil,
                hoot: @escaping HootReader = { nil }) {
        self.owner = owner; self.push = push; self.hoot = hoot
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
            // Full control only, refused in plain words below it (27 Oct, D3); then read as this Mac's own screens read it.
            guard BackendRemoteOwnerScope.permits(host) else { return [try .error(code: "unauthorized", message: BackendRemoteOwnerScope.usageNeedsFull)] }
            let id = try message["id"].requireString("session id"), want = try message["want"].requireString("usage reading")
            if BackendHootUsage.owns(id) {
                // Hoot's own ring: not a session, so no session gate (the Full control rule above still holds).
                guard let reader = await hoot() else { return [try .error(code: "unknown-session", message: "Hoot is not running on this Mac yet.")] }
                if want == "context", let push { await push.follow(connection: host.connectionID, sessionID: id, caller: host.rpcContext) }
                let force = message["force"].bool == true
                let value = try await BackendRemoteOwnerScope.run(owner, fallback: host.rpcContext) { _ in try await reader.reading(id: id, want: want, force: force) }
                return [try .init(.usageReading, fields: [.init("rid", message["rid"]), .init("id", .string(id)), .init("want", .string(want)), .init("answer", .object([.init("reading", value)]))])]
            }
            guard await gate.visible(deviceID: host.deviceID, sessionID: id) else { return [try .error(code: "unknown-session", message: BackendRemoteServeSessionPolicy.noSuchSession(id))] }
            let force = message["force"].bool == true
            if want == "context", let push { await push.follow(connection: host.connectionID, sessionID: id, caller: host.rpcContext) }
            let value = try await BackendRemoteOwnerScope.run(owner, fallback: host.rpcContext) { rpc in
                try await reading(sessionID: id, want: want, force: force, rpcContext: rpc)
            }
            return [try .init(.usageReading, fields: [.init("rid", message["rid"]), .init("id", .string(id)), .init("want", .string(want)), .init("answer", .object([.init("reading", value)]))])]
        }
    }
    /// The pushed reading, read exactly as an answer is (the owner's scope first, else the phone's own).
    public func pushedContext(sessionID: String, caller: NativeRPCContext) async throws -> NativeRPCValue {
        if BackendHootUsage.owns(sessionID) {
            guard let reader = await hoot() else { throw NativeRPCError(code: "unavailable", message: "Hoot is not running on this Mac yet.") }
            return await reader.context(id: sessionID)
        }
        return try await BackendRemoteOwnerScope.run(owner, fallback: caller) { rpc in try await reading(sessionID: sessionID, want: "context", rpcContext: rpc) }
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
