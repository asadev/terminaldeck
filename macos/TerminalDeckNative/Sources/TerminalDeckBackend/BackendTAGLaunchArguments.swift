import Foundation
import TerminalDeckNativeCore

public enum BackendTAGLaunchArguments {
    public static func newSessionPermission(provider: String) -> String? {
        switch provider {
        case "claude": "bypassPermissions"
        case "codex": "danger-full-access"
        case "gemini": "yolo"
        default: nil
        }
    }

    static func bypassing(_ arguments: [String], provider: String) -> [String] {
        let result = removingPermissionOverride(arguments, provider: provider)
        switch provider {
        case "claude": return result + ["--permission-mode", "bypassPermissions"]
        case "codex": return result + ["--sandbox", "danger-full-access", "--ask-for-approval", "never"]
        case "gemini": return result + ["--yolo"]
        default: return arguments
        }
    }

    /// --tools limits built-ins; --allowedTools also names MCP tools. A deny
    /// list is appended last and remains authoritative when a name overlaps.
    public static func arguments(_ input: BackendCreateSessionInput, provider: String) throws -> [String] {
        guard input.claudeAgent != nil || input.allowedTools != nil || input.permissionMode != nil else { return [] }
        if provider != "claude" {
            guard input.claudeAgent == nil, input.allowedTools == nil else { throw BackendSessionFailure.unsupported("Only Claude Code can use a Claude agent definition or allowed tool list.") }
            guard let mode = input.permissionMode, AGSCapabilities.permissionModes(provider: provider).contains(mode) else { throw BackendSessionFailure.invalidInput("The saved permission mode is invalid for this AI.") }
            if mode == "default" { return [] }
            if provider == "codex" { return ["--sandbox", mode, "--ask-for-approval", mode == "danger-full-access" ? "never" : "on-request"] }
            if provider == "gemini" { return ["--approval-mode", mode] }
            throw BackendSessionFailure.unsupported("This AI has no saved permission launch argument.")
        }
        var arguments: [String] = []
        if let name = input.claudeAgent {
            guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$"#, options: .regularExpression) != nil else { throw BackendSessionFailure.invalidInput("The Claude Code agent name is invalid.") }
            arguments += ["--agent", name]
        }
        if let allowed = input.allowedTools {
            guard allowed.count <= 200, allowed.allSatisfy(BackendSharedAgentTools.isToolName) else { throw BackendSessionFailure.invalidInput("An allowed tool name is invalid.") }
            arguments += ["--tools", allowed.filter { !$0.hasPrefix("mcp__") }.joined(separator: ",")]
            if !allowed.isEmpty { arguments += ["--allowedTools", allowed.joined(separator: ",")] }
            // Ambient project/user MCP config must not bypass the app's narrowed
            // per-session server grants.
            arguments += ["--strict-mcp-config"]
        }
        if let mode = input.permissionMode {
            guard BackendTAGAgentProfile.permissionModes.contains(mode) else { throw BackendSessionFailure.invalidInput("The task permission mode is invalid.") }
            // The installed CLI does not accept a literal 'default' value.
            if mode != "default" { arguments += ["--permission-mode", mode] }
        }
        return arguments
    }
    public static func removingPermissionOverride(_ arguments: [String], provider: String? = nil) -> [String] {
        removingOverrides(arguments, provider: provider, scalars: false)
    }

    /// All launch paths share the permission rules. AGS also owns model, effort
    /// and tool scalars; provider context distinguishes Gemini's boolean -s
    /// from Codex's sandbox/value pair.
    static func removingOverrides(_ arguments: [String], provider: String?, scalars: Bool) -> [String] {
        var pairs: Set<String> = ["--permission-mode", "--sandbox", "--ask-for-approval", "--approval-mode"]
        let switches: Set<String> = ["--dangerously-skip-permissions", "--dangerously-bypass-approvals-and-sandbox", "--yolo", "-y", "--full-auto"]
        var configurationKeys = ["approval_policy=", "sandbox_mode="]
        if provider == "codex" || provider == nil { pairs.formUnion(["-s", "-a"]) }
        if scalars {
            pairs.formUnion(["--model", "--effort", "--tools", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools"])
            configurationKeys += ["model_reasoning_effort=", "model="]
        }
        let codexConfiguration = provider == "codex" || provider == nil || scalars
        var result: [String] = [], index = 0
        while index < arguments.count {
            let value = arguments[index]
            if provider == "gemini", ["--sandbox", "-s"].contains(value) { index += 1; continue }
            if pairs.contains(value) { index += 2; continue }
            if pairs.contains(where: { value.hasPrefix($0 + "=") }) || switches.contains(value) { index += 1; continue }
            if codexConfiguration {
                if ["-c", "--config"].contains(value), index + 1 < arguments.count,
                   configurationKeys.contains(where: arguments[index + 1].hasPrefix) { index += 2; continue }
                let inline = value.hasPrefix("--config=") ? String(value.dropFirst(9)) : value.hasPrefix("-c") && value.count > 2 ? String(value.dropFirst(2)) : nil
                if let inline, configurationKeys.contains(where: inline.hasPrefix) { index += 1; continue }
            }
            result.append(value); index += 1
        }
        return result
    }
}
