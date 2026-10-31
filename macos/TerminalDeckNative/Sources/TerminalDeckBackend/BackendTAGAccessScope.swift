import Foundation
import TerminalDeckNativeCore

/// A key may ask, never grant itself access. Terminal Deck does not ask the owner on an
/// app's behalf (Asad, 11 Oct): a checked, rate-limited request is always refused here.
public actor BackendTAGAccessScope {
    /// A key asking for MORE access than it was granted is refused, never asked.
    public nonisolated static let refusal = "access.request_scope was refused: Terminal Deck does not ask for more access on an app's behalf. The person changes this app's access in Settings → AI apps on their Mac. Nothing was changed, so do not retry: say what you would need."
    public static let minimumGapMilliseconds: Double = 60_000
    public static let windowMilliseconds: Double = 600_000
    public static let maximumRequests = 3
    private let keys: BackendDeckCoreSecurityAccessKeys
    private let now: @Sendable () -> Double
    private var attempts: [String: [Double]] = [:]
    private nonisolated let servers: BackendDockerMCPServerStoreReference
    private nonisolated let serverScopeEnabled: Bool
    public init(keys: BackendDeckCoreSecurityAccessKeys, serverStore: BackendDockerMCPServerStoreReference = .init(),
                serverScopeEnabled: Bool = BackendDockerMCPServerKeyScope.enabled,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.keys = keys; self.servers = serverStore; self.serverScopeEnabled = serverScopeEnabled; self.now = now }
    public func setServerStore(_ store: BackendServersStore) throws { try servers.install(store) }

    public nonisolated func bundle() throws -> BackendDeckCoreCatalogueBundle {
        let policy = try policy()
        let metadata = BackendDeckCoreCatalogueMetadata(tool: policy.tool, title: "Ask for more access", audience: "keys")
        return try .init(metadata: [metadata], policies: [policy])
    }

    public nonisolated func policy() throws -> BackendDeckCoreSecurityToolPolicy {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let scopes = ["tasks", "work", "full"] + (serverScopeEnabled ? ["server"] : [])
        var schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("scope", string.setting("enum", .array(scopes.map(NativeRPCValue.string)))),
            .init("reason", string.setting("maxLength", .number(1_000)))])), .init("required", .array([.string("scope"), .string("reason")])), .init("additionalProperties", .bool(false))])
        if serverScopeEnabled {
            schema = schema.setting("properties", schema["properties"].setting("serverId", string.setting("maxLength", .number(200))))
        }
        let tool = try BackendMCPTool(id: "access.request_scope", wireName: "access_request_scope",
            description: serverScopeEnabled
                ? "Ask the owner for tasks, work, full, or server with its serverId. Server access allows only that saved server and does not raise global tier. Terminal Deck does not ask the owner on your behalf (Asad, 11 Oct): this is refused, and only the person changes a key's access, in Settings → AI apps. Tell them what you need and why. At most one request per minute and three per ten minutes."
                : "Ask the owner for more access for this key: tasks (Your tasks), work, or full control. Terminal Deck does not ask the owner on your behalf (Asad, 11 Oct): this is refused, and only the person changes a key's access, in Settings → AI apps. Tell them what you need and why. Available even when Your tasks is off. At most one request per minute and three per ten minutes.", inputSchema: schema, tier: .read)
        return BackendDeckCoreSecurityToolPolicy(tool: tool, audience: "keys", keyRequiresTasks: false,
            summary: { [servers, serverScopeEnabled] args, context in
                let input = try Self.input(args, serverScopeEnabled: serverScopeEnabled)
                if let id = input.serverID {
                    let name = try servers.get()?.get(id)?.name ?? id
                    return "\(context.caller.keyName ?? "This AI app") asks to use server \(name): \(input.reason)"
                }
                return "\(context.caller.keyName ?? "This AI app") asks for \(Self.label(input.scope)): \(input.reason)"
            }, precheckAsync: { [self] args, context in try await reserve(args, context: context) },
            redactArgs: { [serverScopeEnabled] args in args.setting("reason", .string(try Self.input(args, serverScopeEnabled: serverScopeEnabled).reason)) },
            run: { _, _ in throw BackendDeckCoreSecurityRefusal(.notGranted, Self.refusal) })
    }
    private nonisolated static func input(_ args: NativeRPCValue, serverScopeEnabled: Bool) throws -> (scope: String, reason: String, serverID: String?) {
        guard let scope = args["scope"].string, ["tasks", "work", "full", "server"].contains(scope) else { throw NativeRPCError.invalidArguments("Choose the scope: tasks, work, full or server.") }
        let server = args["serverId"].string
        if scope == "server" {
            guard serverScopeEnabled else { throw NativeRPCError(code: "unavailable", message: "Per-server key access is not available in this build.") }
            guard let server, !server.isEmpty, server.utf16.count <= 200 else { throw NativeRPCError.invalidArguments("Choose the saved server for this access request.") }
        } else if args["serverId"] != .missing { throw NativeRPCError.invalidArguments("serverId is only used with server scope.") }
        guard let raw = args["reason"].string else { throw NativeRPCError.invalidArguments("Give a reason for the access request.") }
        let reason = BackendGitHubSecretRedaction.redact(raw.replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines), home: "")
        guard !reason.isEmpty, reason.utf16.count <= 1_000 else { throw NativeRPCError.invalidArguments("The access request reason has to be 1 to 1000 characters.") }
        return (scope, reason, server)
    }
    private nonisolated static func label(_ scope: String) -> String { ["tasks": "Your tasks", "work": "Work", "full": "Full control"][scope] ?? scope }
    private func reserve(_ args: NativeRPCValue, context: BackendDeckCoreSecurityCallContext) async throws {
        let input = try Self.input(args, serverScopeEnabled: serverScopeEnabled), caller = context.caller
        guard caller.kind == .key, let id = caller.keyID, let view = await keys.get(id: id) else { throw BackendDeckCoreSecurityRefusal(.notGranted, "Only a current access key can ask for its own access scope.") }
        let granted = Self.grantedScopes(view)
        guard !granted.contains(input.scope) else { throw NativeRPCError.invalidArguments("This key already has \(Self.label(input.scope)).") }
        if let server = input.serverID {
            guard let store = servers.get(), let row = try store.get(server) else { throw NativeRPCError.invalidArguments("That server is not saved in this app.") }
            guard row.aiKeyIDs?.contains(id) != true else { throw NativeRPCError.invalidArguments("This key already has access to that server.") }
        }
        let instant = now()
        var hits = attempts[id] ?? []; hits.removeAll { $0 <= instant - Self.windowMilliseconds }
        guard hits.last.map({ instant - $0 >= Self.minimumGapMilliseconds }) ?? true, hits.count < Self.maximumRequests else {
            throw BackendDeckCoreSecurityRefusal(.rateLimited, "Too many access requests. Wait a minute between requests; at most three are allowed in ten minutes.")
        }
        hits.append(instant); attempts[id] = hits
    }
    public nonisolated static func grantedScopes(_ view: NativeRPCValue) -> [String] {
        var scopes = ["look"]
        if ["work", "full"].contains(view["level"].string ?? "look") { scopes.append("work") }
        if view["level"].string == "full" { scopes.append("full") }
        if view["tasks"].bool == true { scopes.append("tasks") }
        return scopes
    }
}
