import Foundation
import TerminalDeckNativeCore

public enum BackendAGSValidation {
    public static func check(_ value: AGSAgentSettings) throws {
        guard AGSCapabilities.providers.contains(value.provider) else { throw bad("Choose Claude Code, Codex or Gemini.") }
        for text in [value.model, value.effort, value.permissionMode, value.workingFolder].compactMap({ $0 }) {
            guard !text.isEmpty, text.utf8.count <= 4_000, !text.contains("\0"), !text.contains("\n") else { throw bad("A setting is empty, too long or contains an invalid character.") }
        }
        if let effort = value.effort, !AGSCapabilities.efforts(provider: value.provider).contains(effort) { throw bad("That thinking level is unavailable for this CLI.") }
        if let mode = value.permissionMode, !AGSCapabilities.permissionModes(provider: value.provider).contains(mode) { throw bad("That permission mode is unavailable for this CLI.") }
        if let folder = value.workingFolder, !folder.hasPrefix("/") { throw bad("Choose a full working-folder path.") }
        for tools in [value.allowedTools ?? [], value.deniedTools] {
            guard tools.count <= 200, Set(tools).count == tools.count, tools.allSatisfy({ name in
                value.provider == "gemini" ? name.range(of: #"^[A-Za-z_][A-Za-z0-9_-]{0,199}$"#, options: .regularExpression) != nil : BackendSharedAgentTools.isToolName(name)
            }) else { throw bad("Use unique tool names, at most 200.") }
        }
        guard value.environment.count <= 100, value.mcpServers.count <= 100, value.hooks.count <= 50 else { throw bad("There are too many settings.") }
        for (key, text) in value.environment {
            guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,79}$"#, options: .regularExpression) != nil,
                  !["HOME", "PATH", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GEMINI_CLI_HOME", "GEMINI_CLI_SYSTEM_SETTINGS_PATH", "GEMINI_CLI_SYSTEM_DEFAULTS_PATH", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES"].contains(key),
                  !key.hasPrefix("CLAUDE_CODE_"), !key.hasPrefix("GEMINI_CLI_"), !text.contains("\0"), text.utf8.count <= 16_384 else { throw bad("That environment name or value cannot be used for an agent.") }
        }
        for server in value.mcpServers.keys { guard server.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil else { throw bad("Use an existing MCP server name.") } }
        guard Set(value.hooks.map(\.id)).count == value.hooks.count else { throw bad("Hook identifiers must be unique.") }
        for hook in value.hooks {
            try hookID(hook.id)
            guard AGSCapabilities.hookEvents(provider: value.provider).contains(hook.event) else { throw bad("That hook event is unavailable for this CLI.") }
            try command(hook.command); try timeout(hook.timeoutSeconds)
            if let matcher = hook.matcher { guard matcher.utf8.count <= 500, !matcher.contains("\0") else { throw bad("The hook matcher is too long.") }; if !matcher.isEmpty && matcher != "*" { _ = try NSRegularExpression(pattern: matcher) } }
            if value.provider == "codex", ["SessionEnd", "Interrupt"].contains(hook.event), hook.timeoutSeconds > 3 { throw bad("Codex end and interrupt hooks allow at most three seconds.") }
        }
    }
    public static func check(_ value: AGSDefaults) throws {
        guard value.providers.count <= 3, value.hooks.count <= 50, Set(value.hooks.map(\.id)).count == value.hooks.count else { throw bad("There are too many defaults or duplicate hooks.") }
        for (provider, settings) in value.providers { guard provider == settings.provider else { throw bad("Provider defaults do not match.") }; try check(settings) }
        for hook in value.hooks { try check(hook) }
    }
    public static func check(_ hook: AGSAppHook) throws {
        try hookID(hook.id); try timeout(hook.timeoutSeconds)
        guard AGSCapabilities.appEvents.contains(hook.event), (hook.command != nil) != (hook.webhook != nil) else { throw bad("Choose one supported event and either a command or a webhook.") }
        if let text = hook.command { try command(text) }
        if let text = hook.webhook {
            guard text.utf8.count <= 4_000, let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { throw bad("Use an HTTPS webhook address without a username or password.") }
        }
    }
    static func bad(_ message: String) -> NativeRPCError { .invalidArguments(message) }
    static func command(_ text: String) throws { guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.contains("\0"), text.utf8.count <= 8_000 else { throw bad("Enter a hook command, at most 8,000 bytes.") } }
    static func timeout(_ value: Int) throws { guard (1...120).contains(value) else { throw bad("Hook timeout must be from 1 to 120 seconds.") } }
    static func hookID(_ text: String) throws { guard UUID(uuidString: text) != nil else { throw bad("The hook identifier is invalid.") } }
}

public enum BackendAGSPolicy {
    /// Defaults supply scalar choices. Tool/server restrictions accumulate and deny wins.
    public static func resolve(defaults: AGSAgentSettings?, profile: AGSAgentSettings, session: AGSAgentSettings? = nil) throws -> AGSAgentSettings {
        var result = profile
        if let defaults {
            guard defaults.provider == profile.provider else { throw BackendAGSValidation.bad("Defaults belong to another CLI.") }
            result.model = profile.model ?? defaults.model; result.effort = profile.effort ?? defaults.effort
            result.permissionMode = profile.permissionMode ?? defaults.permissionMode
            result.allowedTools = intersect(defaults.allowedTools, profile.allowedTools)
            result.deniedTools = Array(Set(defaults.deniedTools + profile.deniedTools)).sorted()
            result.mcpServers = defaults.mcpServers.merging(profile.mcpServers) { $0 && $1 }
            result.hooks = defaults.hooks + profile.hooks
            result.environment = defaults.environment.merging(profile.environment) { _, new in new }
            result.workingFolder = profile.workingFolder ?? defaults.workingFolder
        }
        if let session {
            guard session.provider == profile.provider else { throw BackendAGSValidation.bad("Session settings belong to another CLI.") }
            result.model = session.model ?? result.model; result.effort = session.effort ?? result.effort
            result.permissionMode = session.permissionMode ?? result.permissionMode
            result.allowedTools = intersect(result.allowedTools, session.allowedTools)
            result.deniedTools = Array(Set(result.deniedTools + session.deniedTools)).sorted()
            result.mcpServers = result.mcpServers.merging(session.mcpServers) { $0 && $1 }
            // A session choice is the complete owner-native editor snapshot, including removals.
            result.hooks = session.hooks; result.environment = session.environment
            result.workingFolder = session.workingFolder ?? result.workingFolder; result.keepOpen = session.keepOpen
        }
        if let allow = result.allowedTools { result.allowedTools = allow.filter { tool in !result.deniedTools.contains { BackendTAGToolPolicy.covers($0, tool: tool) } } }
        try BackendAGSValidation.check(result); return result
    }
    /// Run alongside TAG's existing key preflight AND actor-current recheck.
    /// No key may inject executable code/secrets, broaden a folder or keep a session longer.
    public static func requireNarrowing(_ child: AGSAgentSettings, owner: AGSAgentSettings) throws {
        try BackendAGSValidation.check(child); try BackendAGSValidation.check(owner)
        guard child.provider == owner.provider, child.model == owner.model, child.effort == owner.effort,
              child.hooks == owner.hooks, child.environment == owner.environment,
              !child.keepOpen || owner.keepOpen else { throw refusal() }
        // "default" is an inherited CLI value, not a verified security rank.
        if child.permissionMode != owner.permissionMode, child.permissionMode == nil || child.permissionMode == "default" { throw refusal() }
        let ranks: [String: Int] = ["plan": 0, "read-only": 0, "default": 1, "workspace-write": 2, "acceptEdits": 2, "auto_edit": 2, "danger-full-access": 3, "bypassPermissions": 3, "yolo": 3]
        guard let ownerMode = owner.permissionMode, let childMode = child.permissionMode,
              let a = ranks[ownerMode], let b = ranks[childMode], b <= a else {
            if child.permissionMode != owner.permissionMode { throw refusal() }; return try otherNarrowing(child, owner: owner)
        }
        try otherNarrowing(child, owner: owner)
    }
    private static func otherNarrowing(_ child: AGSAgentSettings, owner: AGSAgentSettings) throws {
        if let list = owner.allowedTools { guard let next = child.allowedTools, next.allSatisfy({ tool in list.contains { BackendTAGToolPolicy.covers($0, tool: tool) } }) else { throw refusal() } }
        guard owner.deniedTools.allSatisfy({ tool in child.deniedTools.contains { BackendTAGToolPolicy.covers($0, tool: tool) } }) else { throw refusal() }
        for (name, on) in child.mcpServers where on { guard owner.mcpServers[name] == true else { throw refusal() } }
        for (name, on) in owner.mcpServers where !on { guard child.mcpServers[name] == false else { throw refusal() } }
        if let root = owner.workingFolder {
            guard let next = child.workingFolder else { throw refusal() }
            let base = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            let path = URL(fileURLWithPath: next).resolvingSymlinksInPath().standardizedFileURL.path
            guard path == base || path.hasPrefix(base == "/" ? "/" : base + "/") else { throw refusal() }
        }
    }
    private static func intersect(_ a: [String]?, _ b: [String]?) -> [String]? {
        guard let a else { return b }; guard let b else { return a }; return BackendTAGToolPolicy.intersection(a, b)
    }
    private static func refusal() -> NativeRPCError { .init(code: "not-permitted", message: "A key may only narrow its owner's agent settings.") }
}
