import Foundation
import TerminalDeckNativeCore

/// A key may ask, never grant itself access. The exact keys-only read policy
/// requires an owner answer in the shared core gate before its handler runs.
public actor BackendTAGAccessScope {
    public static let minimumGapMilliseconds: Double = 60_000
    public static let windowMilliseconds: Double = 600_000
    public static let maximumRequests = 3
    private let keys: BackendDeckCoreSecurityAccessKeys
    private let now: @Sendable () -> Double
    private var attempts: [String: [Double]] = [:]
    private struct Prepared: Sendable { let keyID: String, scope: String; let at: Double }
    private var prepared: [String: Prepared] = [:]
    public init(keys: BackendDeckCoreSecurityAccessKeys, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) { self.keys = keys; self.now = now }

    public nonisolated func bundle() throws -> BackendDeckCoreCatalogueBundle {
        let policy = try policy()
        let metadata = BackendDeckCoreCatalogueMetadata(tool: policy.tool, title: "Ask for more access", audience: "keys")
        return try .init(metadata: [metadata], policies: [policy])
    }

    public nonisolated func policy() throws -> BackendDeckCoreSecurityToolPolicy {
        let string = NativeRPCValue.object([.init("type", .string("string"))])
        let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("scope", string.setting("enum", .array([.string("tasks"), .string("work"), .string("full")]))),
            .init("reason", string.setting("maxLength", .number(1_000)))])), .init("required", .array([.string("scope"), .string("reason")])), .init("additionalProperties", .bool(false))])
        let tool = try BackendMCPTool(id: "access.request_scope", wireName: "access_request_scope",
            description: "Ask the owner for more access for this key: tasks (Your tasks), work, or full control. Give the reason. The owner must tap Allow; this request never grants itself access. Available even when Your tasks is off. At most one request per minute and three per ten minutes.", inputSchema: schema, tier: .read)
        return BackendDeckCoreSecurityToolPolicy(tool: tool, audience: "keys", keyRequiresTasks: false,
            summary: { args, context in
                let input = try Self.input(args)
                return "\(context.caller.keyName ?? "This AI app") asks for \(Self.label(input.scope)): \(input.reason). Allow / Deny"
            }, precheckAsync: { [self] args, context in try await reserve(args, context: context) },
            ownerMustAnswer: { _ in true }, redactArgs: { args in args.setting("reason", .string(try Self.input(args).reason)) }, run: { [self] args, context in
                let view = try await grant(args, context: context)
                let scope = try Self.input(args).scope
                return .init(value: .object([.init("granted", .bool(true)), .init("scope", .string(scope)), .init("key", view)]),
                             summary: .object([.init("scope", .string(scope)), .init("granted", .bool(true))]))
            })
    }
    private nonisolated static func input(_ args: NativeRPCValue) throws -> (scope: String, reason: String) {
        guard let scope = args["scope"].string, ["tasks", "work", "full"].contains(scope) else { throw NativeRPCError.invalidArguments("Choose the scope: tasks, work or full.") }
        guard let raw = args["reason"].string else { throw NativeRPCError.invalidArguments("Give a reason for the access request.") }
        let reason = BackendGitHubSecretRedaction.redact(raw.replacingOccurrences(of: #"[\x00-\x1f\x7f]"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines), home: "")
        guard !reason.isEmpty, reason.utf16.count <= 1_000 else { throw NativeRPCError.invalidArguments("The access request reason has to be 1 to 1000 characters.") }
        return (scope, reason)
    }
    private nonisolated static func label(_ scope: String) -> String { ["tasks": "Your tasks", "work": "Work", "full": "Full control"][scope] ?? scope }
    private func reserve(_ args: NativeRPCValue, context: BackendDeckCoreSecurityCallContext) async throws {
        let input = try Self.input(args), caller = context.caller
        guard caller.kind == .key, let id = caller.keyID, let view = await keys.get(id: id) else { throw BackendDeckCoreSecurityRefusal(.notGranted, "Only a current access key can ask for its own access scope.") }
        let granted = Self.grantedScopes(view)
        guard !granted.contains(input.scope) else { throw NativeRPCError.invalidArguments("This key already has \(Self.label(input.scope)).") }
        let instant = now()
        prepared = prepared.filter { instant - $0.value.at <= Double(BackendDeckCoreSecurityConsentBroker.outsideAppTimeoutMilliseconds) }
        var hits = attempts[id] ?? []; hits.removeAll { $0 <= instant - Self.windowMilliseconds }
        guard hits.last.map({ instant - $0 >= Self.minimumGapMilliseconds }) ?? true, hits.count < Self.maximumRequests else {
            throw BackendDeckCoreSecurityRefusal(.rateLimited, "Too many access requests. Wait a minute between requests; at most three are allowed in ten minutes.")
        }
        hits.append(instant); attempts[id] = hits
        prepared[context.callID] = Prepared(keyID: id, scope: input.scope, at: instant)
    }
    private func grant(_ args: NativeRPCValue, context: BackendDeckCoreSecurityCallContext) async throws -> NativeRPCValue {
        let input = try Self.input(args)
        guard let request = prepared.removeValue(forKey: context.callID), request.keyID == context.caller.keyID, request.scope == input.scope,
              context.caller.kind == .key, !context.cancellation.isCancelled, now() - request.at <= Double(BackendDeckCoreSecurityConsentBroker.outsideAppTimeoutMilliseconds),
              let current = await keys.get(id: request.keyID) else { throw BackendDeckCoreSecurityRefusal(.callerGone, "This access request is no longer active. No scope was granted.") }
        // Only the gate's approved handler reaches this mutation. Existing
        // folders, ask-first, identity and notification settings are retained.
        switch input.scope {
        case "tasks": return try await keys.setTasks(id: request.keyID, on: .bool(true))
        case "work":
            if current["level"].string == "full" { return current }
            return try await keys.setLevel(id: request.keyID, level: .string("work"))
        default: return try await keys.setLevel(id: request.keyID, level: .string("full"))
        }
    }
    public nonisolated static func grantedScopes(_ view: NativeRPCValue) -> [String] {
        var scopes = ["look"]
        if ["work", "full"].contains(view["level"].string ?? "look") { scopes.append("work") }
        if view["level"].string == "full" { scopes.append("full") }
        if view["tasks"].bool == true { scopes.append("tasks") }
        return scopes
    }
}
