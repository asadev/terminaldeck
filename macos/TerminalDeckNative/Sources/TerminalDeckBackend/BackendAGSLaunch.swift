import Foundation
import TerminalDeckNativeCore

/// Internal launch material only: never put this in UI, logs or tool output.
public struct BackendAGSLaunchPlan: Sendable {
    public let arguments: [String], environment: [String: String], privateFiles: [String: Data]
    public let workingFolder: String?, keepOpen: Bool
    /// Feed this map into the existing per-session MCP config/grant resolver.
    public let mcpServers: [String: Bool]
}
public enum BackendAGSLaunch {
    /// help must be the installed selected CLI's --help, not a caller-supplied value.
    /// knownServers is the full inventory from that account/project configuration.
    public static func plan(_ settings: AGSAgentSettings, privateDirectory: URL, installedHelp: String,
                            knownServers: Set<String>) throws -> BackendAGSLaunchPlan {
        try BackendAGSValidation.check(settings)
        guard privateDirectory.isFileURL, privateDirectory.path.hasPrefix("/"), !privateDirectory.path.contains("\0"),
              !installedHelp.isEmpty else { throw unavailable("The selected CLI has not been checked on this machine.") }
        guard Set(settings.mcpServers.keys).isSubset(of: knownServers) else { throw BackendAGSValidation.bad("An MCP server is no longer available.") }
        var args: [String] = [], env = settings.environment, files: [String: Data] = [:]
        func flag(_ name: String) throws { guard installedHelp.contains(name) else { throw unavailable("The installed CLI does not support \(name).") } }
        if let model = settings.model { try flag("--model"); args += ["--model", model] }
        let hooks = hooksJSON(settings)
        switch settings.provider {
        case "claude":
            if let effort = settings.effort { try flag("--effort"); args += ["--effort", effort] }
            if let mode = settings.permissionMode, mode != "default" { try flag("--permission-mode"); args += ["--permission-mode", mode] }
            if let allow = settings.allowedTools {
                try flag("--tools"); try flag("--allowedTools")
                args += ["--tools", allow.filter { !$0.hasPrefix("mcp__") }.joined(separator: ",")]
                if !allow.isEmpty { args += ["--allowedTools", allow.joined(separator: ",")] }
            }
            if !settings.deniedTools.isEmpty { try flag("--disallowedTools"); args += ["--disallowedTools", settings.deniedTools.joined(separator: ",")] }
            // INT2 passes only the resolved enabled servers to existing --mcp-config.
            if !settings.mcpServers.isEmpty || settings.allowedTools != nil { try flag("--strict-mcp-config"); args += ["--strict-mcp-config"] }
            if !settings.hooks.isEmpty {
                try flag("--settings"); let name = "ags-claude-settings.json"
                files[name] = try NativeRPCValue.object([.init("hooks", hooks)]).encodedJSON(pretty: true)
                args += ["--settings", privateDirectory.appendingPathComponent(name).path]
            }
        case "codex":
            try flag("--config")
            if let effort = settings.effort { args += ["-c", "model_reasoning_effort=" + quote(effort)] }
            if let mode = settings.permissionMode, mode != "default" {
                try flag("--sandbox"); try flag("--ask-for-approval")
                args += ["--sandbox", mode, "--ask-for-approval", "on-request"]
            }
            // Codex documents MCP allow/deny filters, not an arbitrary builtin tool filter.
            // Never silently claim a builtin restriction took effect.
            let tools = (settings.allowedTools ?? []) + settings.deniedTools
            guard tools.allSatisfy({ name in
                knownServers.contains { name.hasPrefix("mcp__" + $0 + "__") && name.count > ("mcp__" + $0 + "__").count }
            }) else { throw unavailable("Codex supports these allow/deny lists for MCP tools. Built-in tool restrictions need a supported permission profile.") }
            for name in knownServers.sorted() {
                if let on = settings.mcpServers[name] { args += ["-c", "mcp_servers.\(quote(name)).enabled=\(on)"] }
                let prefix = "mcp__\(name)__"
                if let allow = settings.allowedTools { args += ["-c", "mcp_servers.\(quote(name)).enabled_tools=" + array(allow.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })] }
                let deny = settings.deniedTools.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                if !deny.isEmpty { args += ["-c", "mcp_servers.\(quote(name)).disabled_tools=" + array(deny)] }
            }
            if !settings.hooks.isEmpty {
                // Inline CLI config is its own config layer and preserves account auth.
                // No CODEX_HOME switch and no global/project file writes. CLI trust stays on.
                files["ags-codex-hooks.json"] = try NativeRPCValue.object([.init("hooks", hooks)]).encodedJSON(pretty: true)
                for field in hooks.fields ?? [] { args += ["-c", "hooks.\(field.key)=" + toml(field.value)] }
            }
        case "gemini":
            if let mode = settings.permissionMode { try flag("--approval-mode"); args += ["--approval-mode", mode] }
            var config: NativeRPCValue = .object([.init("hooks", hooks)])
            var tools: NativeRPCValue = .object([.init("exclude", .array(settings.deniedTools.map(NativeRPCValue.string)))])
            if let allow = settings.allowedTools { tools = tools.setting("core", .array(allow.filter { !$0.hasPrefix("mcp__") }.map(NativeRPCValue.string))) }
            config = config.setting("tools", tools)
            var serverFilters: [NativeRPCValue.Field] = []
            for server in knownServers.sorted() {
                let prefix = "mcp__\(server)__"
                var filter: NativeRPCValue = .object([])
                if let allow = settings.allowedTools { filter = filter.setting("includeTools", .array(allow.filter { $0.hasPrefix(prefix) }.map { .string(String($0.dropFirst(prefix.count))) })) }
                let deny = settings.deniedTools.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                if !deny.isEmpty { filter = filter.setting("excludeTools", .array(deny.map(NativeRPCValue.string))) }
                if filter.fields?.isEmpty == false { serverFilters.append(.init(server, filter)) }
            }
            if !serverFilters.isEmpty { config = config.setting("mcpServers", .object(serverFilters)) }
            if !settings.mcpServers.isEmpty {
                // Restricts ambient MCP discovery without inventing an enabled field.
                let enabled = knownServers.filter { settings.mcpServers[$0] != false }.sorted()
                config = config.setting("mcp", .object([.init("allowed", .array(enabled.map(NativeRPCValue.string)))]))
            }
            if let effort = settings.effort {
                guard let model = settings.model, model.hasPrefix("gemini-3"), !model.contains("flash-lite") else { throw unavailable("Gemini thinking levels require an explicit compatible Gemini 3 model.") }
                config = config.setting("modelConfigs", .object([.init("customOverrides", .array([.object([
                    .init("match", .object([.init("model", .string(model))])),
                    .init("modelConfig", .object([.init("generateContentConfig", .object([.init("thinkingConfig", .object([.init("thinkingLevel", .string(effort.uppercased()))]))]))]))
                ])]))]))
            }
            let name = "ags-gemini-settings.json"; files[name] = try config.encodedJSON(pretty: true)
            // This is scoped to the child process. It never edits system/user settings.
            env["GEMINI_CLI_SYSTEM_SETTINGS_PATH"] = privateDirectory.appendingPathComponent(name).path
        default: throw unavailable("That CLI is unavailable.")
        }
        return .init(arguments: args, environment: env, privateFiles: files, workingFolder: settings.workingFolder,
                     keepOpen: settings.keepOpen, mcpServers: settings.mcpServers)
    }
    /// Called only after launch authorization, using the already-owned private session directory.
    public static func materialize(_ plan: BackendAGSLaunchPlan, persistence: BackendTaskPersistence) throws {
        for (name, bytes) in plan.privateFiles { try persistence.writeBytes(name, data: bytes) }
    }
    private static func hooksJSON(_ settings: AGSAgentSettings) -> NativeRPCValue {
        var groups: [String: [NativeRPCValue]] = [:]
        for hook in settings.hooks where hook.enabled {
            var entry: NativeRPCValue = .object([.init("hooks", .array([.object([
                .init("type", .string("command")), .init("command", .string(hook.command)),
                .init("timeout", .number(Double(hook.timeoutSeconds * (settings.provider == "gemini" ? 1000 : 1))))
            ])]))])
            if let matcher = hook.matcher { entry = entry.setting("matcher", .string(matcher)) }
            groups[hook.event, default: []].append(entry)
        }
        return .object(groups.keys.sorted().map { .init($0, .array(groups[$0]!)) })
    }
    private static func quote(_ text: String) -> String { NativeRPCValue.string(text).compact }
    private static func array(_ values: [String]) -> String { "[" + values.map(quote).joined(separator: ",") + "]" }
    private static func toml(_ value: NativeRPCValue) -> String {
        if let fields = value.fields { return "{" + fields.map { quote($0.key) + "=" + toml($0.value) }.joined(separator: ",") + "}" }
        if let elements = value.elements { return "[" + elements.map(toml).joined(separator: ",") + "]" }
        return value.compact
    }
    private static func unavailable(_ text: String) -> NativeRPCError { .init(code: "unavailable", message: text) }
}
