import Foundation

public enum BackendTAGLaunchArguments {
    /// --tools limits built-ins; --allowedTools also names MCP tools. A deny
    /// list is appended last and remains authoritative when a name overlaps.
    public static func arguments(_ input: BackendCreateSessionInput, provider: String) throws -> [String] {
        guard input.claudeAgent != nil || input.allowedTools != nil || input.permissionMode != nil else { return [] }
        guard provider == "claude" else { throw BackendSessionFailure.unsupported("Only Claude Code can use a Claude agent definition, allowed tool list or task permission mode.") }
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
    public static func removingPermissionOverride(_ arguments: [String]) -> [String] {
        var result: [String] = [], index = 0
        while index < arguments.count {
            let value = arguments[index]
            if value == "--permission-mode" { index += 2; continue }
            if value.hasPrefix("--permission-mode=") || value == "--dangerously-skip-permissions" { index += 1; continue }
            result.append(value); index += 1
        }
        return result
    }
}
