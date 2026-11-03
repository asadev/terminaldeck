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
    /// The inline --settings value that turns Claude Code's Ultracode on for the session.
    public static let ultracodeSettings = #"{"ultracode":true}"#
    /// The same --settings value without Ultracode (inline JSON), nil when nothing else is left; unchanged when unreadable.
    public static func removingUltracode(_ value: String) -> String? {
        if value == ultracodeSettings { return nil }
        let bytes: Data? = value.hasPrefix("{") ? Data(value.utf8) : try? BackendAccountFiles.boundedRead(URL(fileURLWithPath: value), maximum: 2 * 1024 * 1024)
        guard let bytes, let parsed = try? NativeRPCValue.parseJSON(bytes), parsed["ultracode"].bool == true else { return value }
        let rest = parsed.removing("ultracode")
        return rest.fields?.isEmpty == false ? rest.compact : nil
    }
    /// help must be the installed selected CLI's --help, not a caller-supplied value.
    /// knownServers is the full inventory from that account/project configuration.
    /// overridable: the servers a per-server override may name (Codex: those its config files or this launch define;
    /// nil = every known server). A plugin-provided Codex server cannot take one.
    public static func plan(_ settings: AGSAgentSettings, privateDirectory: URL, installedHelp: String,
                            knownServers: Set<String>, overridable: Set<String>? = nil, requestedOff: Set<String>? = nil) throws -> BackendAGSLaunchPlan {
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
            // Ultracode is a session setting, not an --effort level; the effort stays the CLI's own.
            let ultracode = settings.effort == AGSCapabilities.ultracode
            // 18 Oct (#531): the app's own default level is left out on a Claude Code too old to take --effort,
            // instead of refusing every launch; a different level the person picked still needs the flag.
            if !ultracode, let effort = settings.effort,
               effort != AGSCapabilities.defaultEffort(provider: "claude") || installedHelp.contains("--effort") {
                try flag("--effort"); args += ["--effort", effort]
            }
            if let mode = settings.permissionMode, mode != "default" { try flag("--permission-mode"); args += ["--permission-mode", mode] }
            if let allow = settings.allowedTools {
                try flag("--tools"); try flag("--allowedTools")
                args += ["--tools", allow.filter { !$0.hasPrefix("mcp__") }.joined(separator: ",")]
                if !allow.isEmpty { args += ["--allowedTools", allow.joined(separator: ",")] }
            }
            if !settings.deniedTools.isEmpty { try flag("--disallowedTools"); args += ["--disallowedTools", settings.deniedTools.joined(separator: ",")] }
            // INT2 passes only the resolved enabled servers to existing --mcp-config.
            if !settings.mcpServers.isEmpty || settings.allowedTools != nil { try flag("--strict-mcp-config"); args += ["--strict-mcp-config"] }
            // 18 Oct (#526): Claude Code keeps only one --settings, so Ultracode, hooks and Fast mode go in one.
            if !settings.hooks.isEmpty || settings.fastMode != nil {
                try flag("--settings"); let name = "ags-claude-settings.json"
                var fields: [NativeRPCValue.Field] = []
                if !settings.hooks.isEmpty { fields.append(.init("hooks", hooks)) }
                if let fast = settings.fastMode { fields.append(.init("fastMode", .bool(fast))) }
                if ultracode { fields.append(.init("ultracode", .bool(true))) }
                files[name] = try NativeRPCValue.object(fields).encodedJSON(pretty: true)
                args += ["--settings", privateDirectory.appendingPathComponent(name).path]
            } else if ultracode { try flag("--settings"); args += ["--settings", ultracodeSettings] }
        case "codex":
            try flag("--config")
            if let effort = settings.effort { args += ["-c", "model_reasoning_effort=" + quote(effort)] }
            if let window = settings.contextWindow { args += ["-c", "model_context_window=\(window)"] }
            if let mode = settings.permissionMode, mode != "default" {
                try flag("--sandbox"); try flag("--ask-for-approval")
                args += ["--sandbox", mode, "--ask-for-approval", mode == "danger-full-access" ? "never" : "on-request"]
            }
            // Codex documents MCP allow/deny filters, not an arbitrary builtin tool filter.
            // Never silently claim a builtin restriction took effect.
            let tools = (settings.allowedTools ?? []) + settings.deniedTools
            guard tools.allSatisfy({ name in
                knownServers.contains { name.hasPrefix("mcp__" + $0 + "__") && name.count > ("mcp__" + $0 + "__").count }
            }) else { throw unavailable("Codex supports these allow/deny lists for MCP tools. Built-in tool restrictions need a supported permission profile.") }
            for name in knownServers.sorted() {
                // L8 (11 Oct, real-app T11): a server a Codex PLUGIN provides is not in config.toml; an override
                // creates a half table for it and Codex quits ("invalid transport"). Never re-emit those. Turning
                // one off has to be done on the plugin, so a request to turn it off is refused plainly.
                if let overridable, !overridable.contains(name) {
                    // Refused only when the PERSON asked for it off (recheck of install 4: a plugin server that is
                    // merely off in Codex's own list is left as Codex has it, and the session starts).
                    if settings.mcpServers[name] == false, requestedOff?.contains(name) ?? true { throw unavailable("\(name) comes from a Codex plugin, so it cannot be turned off for one session. Turn the plugin off in Codex instead.") }
                    continue
                }
                // Codex's `-c` path is split on dots and does NOT read TOML quotes: `mcp_servers."x".…` names a new
                // server called `"x"` (quotes included) and Codex quits with "invalid transport" (measured on 0.159.3
                // with a copy of his config). So the name goes in bare, and only a name Codex can take bare is used.
                guard name.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                    throw unavailable("The MCP server name \(name) cannot be given to Codex for one session.")
                }
                if let on = settings.mcpServers[name] { args += ["-c", "mcp_servers.\(name).enabled=\(on)"] }
                let prefix = "mcp__\(name)__"
                if let allow = settings.allowedTools { args += ["-c", "mcp_servers.\(name).enabled_tools=" + array(allow.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) })] }
                let deny = settings.deniedTools.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                if !deny.isEmpty { args += ["-c", "mcp_servers.\(name).disabled_tools=" + array(deny)] }
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
