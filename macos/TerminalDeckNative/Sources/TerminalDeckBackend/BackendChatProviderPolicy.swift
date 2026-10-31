import Foundation
import TerminalDeckNativeCore

/// Effective policy comes only from correlated provider replies or scoped provider status events.
/// Requested launch settings, app consent and configuration files are never effective-policy proof.
public enum BackendChatProviderPolicy {
    public typealias Request = @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    public static let operations = ["policy/read", "policy/change"]
    public static let codexSandboxModes = ["read-only", "workspace-write", "danger-full-access"]
    public static let codexApprovalModes = ["untrusted", "on-request", "never"]
    public static let claudeModes = ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto"]
    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }

    /// Call after the adapter has matched a successful startup/resume response to its request.
    public static func resolvedSession(_ response: NativeRPCValue, provider: HootChatProvider, conversation: String,
                                       source: String, at: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue? {
        guard provider == .codex, ["thread/start", "thread/resume"].contains(source), !conversation.isEmpty,
              response["thread"]["id"].string == conversation, response["error"].isNullish, at.isFinite else { return nil }
        let sandbox = sandboxReceipt(response["sandbox"])
        var receipt = base(provider: provider, conversation: conversation, source: source, at: at)
            .setting("sandbox", sandbox).setting("approval", approvalReceipt(response["approvalPolicy"]))
            .setting("runtimeWorkspaceRoots", paths(response["runtimeWorkspaceRoots"]))
            .setting("cwd", text(response["cwd"]))
        if let reviewer = response["approvalsReviewer"].string, ["user", "auto_review", "guardian_subagent"].contains(reviewer) {
            receipt = receipt.setting("approvalsReviewer", .string(reviewer))
        }
        if let id = response["activePermissionProfile"]["id"].string, !id.isEmpty, id.utf8.count <= 512 {
            receipt = receipt.setting("activePermissionProfile", object([("id", .string(id)), ("extends", text(response["activePermissionProfile"]["extends"]))]))
        }
        // Never infer network access from dangerFullAccess or a profile name. Only the actual
        // returned networkAccess field is evidence; absent/defaulted-on-the-client fields stay unknown.
        if let enabled = sandbox["networkAccess"].bool { receipt = receipt.setting("network", object([("enabled", .bool(enabled))])) }
        else if let network = sandbox["networkAccess"].string, ["enabled", "restricted"].contains(network) {
            receipt = receipt.setting("network", object([("enabled", .bool(network == "enabled")), ("providerValue", .string(network))]))
        }
        return receipt
    }
    /// The provider's own list of instruction files loaded for this thread (Codex 0.159 `instructionSources`).
    /// Absent on older CLIs: then no receipt exists and nothing is inferred from files on disk.
    public static func instructionReceipt(_ response: NativeRPCValue, conversation: String, source: String,
                                          at: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue? {
        guard ["thread/start", "thread/resume", "thread/fork"].contains(source), !conversation.isEmpty,
              response["thread"]["id"].string == conversation, response["error"].isNullish, at.isFinite,
              let sources = response["instructionSources"].elements, sources.count <= 64 else { return nil }
        let paths = sources.compactMap(\.string)
        guard paths.count == sources.count, paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") }) else { return nil }
        return object([("provider", .string(HootChatProvider.codex.rawValue)), ("providerConversationId", .string(conversation)),
            ("source", .string(source)), ("authority", .string("provider-response")), ("reportedAt", .number(at)),
            ("paths", .array(paths.map(NativeRPCValue.string)))])
    }
    /// system/init and system/status report the effective permission mode, not a sandbox manifest.
    public static func resolvedClaude(_ row: NativeRPCValue, conversation: String,
                                      at: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue? {
        guard row["type"].string == "system", let subtype = row["subtype"].string, ["init", "status"].contains(subtype),
              row["session_id"].string == conversation, !conversation.isEmpty,
              let mode = row["permissionMode"].string, claudeModes.contains(mode), at.isFinite else { return nil }
        return base(provider: .claude, conversation: conversation, source: "system/" + subtype, at: at).setting("approval", .string(mode))
    }
    /// A successful set_permission_mode reply can be empty on other hosts. Empty is an
    /// acknowledgement only; it cannot confirm that the requested mode took effect.
    public static func resolvedClaudeMode(_ response: NativeRPCValue, conversation: String,
                                          at: Double = Date().timeIntervalSince1970 * 1000) -> NativeRPCValue? {
        guard !conversation.isEmpty, response["error"].isNullish, let mode = response["mode"].string, claudeModes.contains(mode), at.isFinite else { return nil }
        return base(provider: .claude, conversation: conversation, source: "set_permission_mode", at: at).setting("approval", .string(mode))
    }
    public static func invoke(operation: String, arguments: NativeRPCValue, provider: HootChatProvider,
                              conversation: String?, cwd: String, receipt: NativeRPCValue = .null,
                              busy: Bool = true, request: Request) async throws -> NativeRPCValue {
        guard operations.contains(operation) else { throw invalid("Choose a supported provider policy operation.") }
        let current = validated(receipt, provider: provider, conversation: conversation)
        var result = object([("provider", .string(provider.rawValue)), ("scope", .string("provider-current-session")),
            ("availability", .string(provider == .gemini ? "unavailable" : current.isNullish ? "unknown" : "reported")),
            ("effectivePolicy", current), ("appPermissionChoiceSeparate", .bool(true)),
            ("reason", .string("Only provider-reported fields are shown. Missing sandbox, approval, trust or network fields remain unknown. Saved app permission choices can apply again after a later process relaunch."))])
        if operation == "policy/read" { return result }
        guard provider != .gemini else { return result.setting("reason", .string("Gemini's current structured Chat protocol does not expose an authoritative effective policy manifest or a scoped policy change here.")) }
        guard !busy else { throw NativeRPCError(code: "busy", message: "Finish the current turn and background work, stop voice, and answer pending approvals before changing the provider policy.") }
        guard let conversation, !conversation.isEmpty else { throw invalid("A confirmed provider conversation is required.") }
        let allowed = provider == .codex ? ["sandbox", "approvalPolicy"] : ["mode"]
        guard arguments.fields != nil, !(arguments.fields ?? []).isEmpty,
              (arguments.fields ?? []).allSatisfy({ allowed.contains($0.key) }) else {
            return result.setting("availability", .string("unavailable"))
                .setting("reason", .string("This operation exposes only provider-owned sandbox and approval choices. Trust, network grants, app permissions and arbitrary configuration cannot be changed through it."))
        }
        let effective: NativeRPCValue?
        let confirmed: Bool
        if provider == .codex {
            var params = object([("threadId", .string(conversation)), ("excludeTurns", .bool(true))])
            if arguments.has("sandbox") {
                guard let mode = arguments["sandbox"].string, codexSandboxModes.contains(mode) else { throw invalid("Choose a supported Codex sandbox mode.") }
                params = params.setting("sandbox", .string(mode))
            }
            if arguments.has("approvalPolicy") {
                guard let mode = arguments["approvalPolicy"].string, codexApprovalModes.contains(mode) else { throw invalid("Choose a supported Codex approval policy.") }
                params = params.setting("approvalPolicy", .string(mode))
            }
            // thread/resume has no deferGoalContinuation field in the installed schema. Do not
            // restart automatic goal work as a side effect of changing a policy boundary.
            let goal = try await request("thread/goal/get", object([("threadId", .string(conversation))]))
            guard goal.has("goal"), goal["goal"] == .null || ["paused", "complete"].contains(goal["goal"]["status"].string ?? "") else {
                return result.setting("availability", .string("unavailable"))
                    .setting("reason", .string("Pause this provider goal before changing policy. Its resume API cannot defer automatic goal continuation."))
            }
            let response = try await request("thread/resume", params)
            guard response["thread"]["id"].string == conversation else { throw NativeRPCError(code: "provider-policy-unconfirmed", message: "The provider did not confirm the same thread after the policy request. No requested settings were recorded as effective.") }
            effective = resolvedSession(response, provider: provider, conversation: conversation, source: "thread/resume")
            let sandboxType = ["read-only": "readOnly", "workspace-write": "workspaceWrite", "danger-full-access": "dangerFullAccess"]
            let sandboxMatches = !arguments.has("sandbox") || effective?["sandbox"]["type"].string == sandboxType[arguments["sandbox"].string ?? ""]
            let approvalMatches = !arguments.has("approvalPolicy") || effective?["approval"].string == arguments["approvalPolicy"].string
            confirmed = sandboxMatches && approvalMatches
        } else {
            guard let mode = arguments["mode"].string, claudeModes.contains(mode) else { throw invalid("Choose a supported Claude permission mode.") }
            let response = try await request("set_permission_mode", object([("mode", .string(mode))]))
            effective = resolvedClaudeMode(response, conversation: conversation)
            confirmed = effective?["approval"].string == mode
        }
        result = result.setting("requested", .bool(true)).setting("changeScope", .string("provider-current-session"))
            .setting("changeConfirmed", .bool(confirmed)).setting("effectivePolicy", effective ?? .null)
            .setting("availability", .string(confirmed ? "reported" : "unconfirmed"))
        if !confirmed { result = result.setting("reason", .string("The provider acknowledged the request without confirming the requested effective settings. Inspect any returned receipt; requested choices have not been treated as effective proof.")) }
        return result
    }
    private static func base(provider: HootChatProvider, conversation: String, source: String, at: Double) -> NativeRPCValue {
        object([("provider", .string(provider.rawValue)), ("providerConversationId", .string(conversation)),
            ("source", .string(source)), ("authority", .string("provider-response")), ("reportedAt", .number(at)),
            ("scope", .string("provider-current-session")), ("sandbox", .null), ("approval", .null),
            ("workspaceTrust", .null), ("network", .null), ("activePermissionProfile", .null), ("approvalsReviewer", .null)])
    }
    private static func validated(_ receipt: NativeRPCValue, provider: HootChatProvider, conversation: String?) -> NativeRPCValue {
        guard let conversation, !conversation.isEmpty, receipt["provider"].string == provider.rawValue,
              receipt["providerConversationId"].string == conversation, receipt["authority"].string == "provider-response",
              receipt["reportedAt"].number != nil else { return .null }
        let sources = provider == .codex ? ["thread/start", "thread/resume"] : provider == .claude ? ["system/init", "system/status", "set_permission_mode"] : []
        guard sources.contains(receipt["source"].string ?? "") else { return .null }
        return receipt
    }
    private static func sandboxReceipt(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let type = value["type"].string, ["dangerFullAccess", "readOnly", "workspaceWrite", "externalSandbox"].contains(type) else { return .null }
        var result = object([("type", .string(type))])
        if let flag = value["networkAccess"].bool { result = result.setting("networkAccess", .bool(flag)) }
        else if let text = value["networkAccess"].string, ["restricted", "enabled"].contains(text) { result = result.setting("networkAccess", .string(text)) }
        for field in ["excludeSlashTmp", "excludeTmpdirEnvVar"] {
            if let flag = value[field].bool { result = result.setting(field, .bool(flag)) }
        }
        if value.has("writableRoots") { result = result.setting("writableRoots", paths(value["writableRoots"])) }
        return result
    }
    private static func approvalReceipt(_ value: NativeRPCValue) -> NativeRPCValue {
        if let mode = value.string, codexApprovalModes.contains(mode) { return .string(mode) }
        guard let fields = value["granular"].fields else { return .null }
        let allowed = ["mcp_elicitations", "request_permissions", "rules", "sandbox_approval", "skill_approval"]
        return object([("type", .string("granular"))] + fields.compactMap { field in
            allowed.contains(field.key) && field.value.bool != nil ? (field.key, field.value) : nil
        })
    }
    private static func text(_ value: NativeRPCValue) -> NativeRPCValue { value.string.map { .string(String($0.prefix(4096))) } ?? .null }
    private static func paths(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let values = value.elements else { return .null }
        return .array(values.prefix(100).compactMap { value in
            guard let path = value.string, path.hasPrefix("/"), path.utf8.count <= 4096 else { return nil }
            return .string(path)
        })
    }
    private static func invalid(_ message: String) -> NativeRPCError { .invalidArguments(message) }
}
