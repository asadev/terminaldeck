import Foundation

public struct AGSCLIHook: Codable, Sendable, Equatable, Identifiable {
    public var id: String, event: String, matcher: String?, command: String, timeoutSeconds: Int, enabled: Bool
    public init(id: String = UUID().uuidString, event: String = "SessionStart", matcher: String? = nil, command: String = "", timeoutSeconds: Int = 30, enabled: Bool = true) {
        self.id = id; self.event = event; self.matcher = matcher; self.command = command; self.timeoutSeconds = timeoutSeconds; self.enabled = enabled
    }
}
public struct AGSAppHook: Codable, Sendable, Equatable, Identifiable {
    public var id: String, event: String, command: String?, webhook: String?, enabled: Bool, timeoutSeconds: Int
    public init(id: String = UUID().uuidString, event: String = "session.started", command: String? = nil, webhook: String? = nil, enabled: Bool = false, timeoutSeconds: Int = 30) {
        self.id = id; self.event = event; self.command = command; self.webhook = webhook; self.enabled = enabled; self.timeoutSeconds = timeoutSeconds
    }
}
/// nil follows the app default; a zero token budget explicitly removes the limit.
public struct AGOPTEfficiencySettings: Codable, Sendable, Equatable {
    public var reuseContext: Bool?, completion: String?, addonsOff: Bool?
    public var agentTokenBudget: Int?, taskTokenBudget: Int?, warningPercent: Int?, serializeHeavyJobs: Bool?
    public var monthlyBudgetUSD: Double?, onExhaustion: String?
    public init(reuseContext: Bool? = nil, completion: String? = nil, addonsOff: Bool? = nil,
                agentTokenBudget: Int? = nil, taskTokenBudget: Int? = nil, warningPercent: Int? = nil,
                serializeHeavyJobs: Bool? = nil, monthlyBudgetUSD: Double? = nil, onExhaustion: String? = nil) {
        self.reuseContext = reuseContext; self.completion = completion; self.addonsOff = addonsOff
        self.agentTokenBudget = agentTokenBudget; self.taskTokenBudget = taskTokenBudget
        self.warningPercent = warningPercent; self.serializeHeavyJobs = serializeHeavyJobs
        self.monthlyBudgetUSD = monthlyBudgetUSD; self.onExhaustion = onExhaustion
    }
}
/// An extension to TAG's profile, also used by the session-start chooser.
/// nil means inherit; an empty allow list explicitly exposes no tools.
public struct AGSAgentSettings: Codable, Sendable, Equatable {
    public var provider: String, model: String?, effort: String?, permissionMode: String?
    public var allowedTools: [String]?, deniedTools: [String], mcpServers: [String: Bool]
    public var hooks: [AGSCLIHook], environment: [String: String], workingFolder: String?, keepOpen: Bool
    public var efficiency: AGOPTEfficiencySettings?
    /// Tokens of context to ask the CLI for (Codex `model_context_window`). Nil = the model's own size.
    public var contextWindow: Int?
    /// Claude Code's Fast mode (its `fastMode` setting, passed with --settings).
    public var fastMode: Bool?
    public init(provider: String = "claude", model: String? = nil, effort: String? = nil, permissionMode: String? = nil,
                allowedTools: [String]? = nil, deniedTools: [String] = [], mcpServers: [String: Bool] = [:], hooks: [AGSCLIHook] = [],
                environment: [String: String] = [:], workingFolder: String? = nil, keepOpen: Bool = false,
                efficiency: AGOPTEfficiencySettings? = nil, contextWindow: Int? = nil, fastMode: Bool? = nil) {
        self.provider = provider; self.model = model; self.effort = effort; self.permissionMode = permissionMode
        self.allowedTools = allowedTools; self.deniedTools = deniedTools; self.mcpServers = mcpServers; self.hooks = hooks
        self.environment = environment; self.workingFolder = workingFolder; self.keepOpen = keepOpen
        self.efficiency = efficiency; self.contextWindow = contextWindow; self.fastMode = fastMode
    }
}
public struct AGSDefaults: Codable, Sendable, Equatable {
    public var providers: [String: AGSAgentSettings], hooks: [AGSAppHook]
    public init(providers: [String: AGSAgentSettings] = [:], hooks: [AGSAppHook] = []) { self.providers = providers; self.hooks = hooks }
}
public enum AGSCapabilities {
    public static let claudeEffortOptions: [TerminalControlOption] = [
        .init(id: "low", label: "Low"), .init(id: "medium", label: "Medium"),
        .init(id: "high", label: "High"), .init(id: "xhigh", label: "Extra high"),
        .init(id: "max", label: "Max"), .init(id: "ultracode", label: "Ultracode"), .init(id: "auto", label: "Auto"),
    ]
    public static let providers = ["claude", "codex", "gemini"]
    public static let appEvents = ["session.started", "session.finished", "task.finished", "alert.raised", "receiver.event"]
    public static func efforts(provider: String) -> [String] {
        // Claude Code's own levels (`claude --effort`), then Ultracode: its top choice, launched
        // as the session setting {"ultracode":true} rather than an --effort value.
        switch provider { case "claude": claudeEffortOptions.map(\.id).filter { $0 != "auto" }
        case "codex": ["low", "medium", "high", "xhigh", "max", "ultra"]
        case "gemini": ["minimal", "low", "medium", "high"]
        default: [] }
    }
    /// Claude Code's Ultracode choice (dynamic workflows on every task).
    public static let ultracode = "ultracode"
    /// Asad's app default (14 Oct): Extra, where the provider offers it.
    public static func defaultEffort(provider: String) -> String? {
        efforts(provider: provider).contains("xhigh") ? "xhigh" : nil
    }
    /// The app's recommended starting effort; explicit choices still win.
    public static func recommendedEffort(provider: String, model: String?) -> String? {
        defaultEffort(provider: provider)
    }
    /// Environment names an agent may not set: the app's own launch and profile folders, and code
    /// injection. The agent window and the save check both read this one list (#517).
    public static let reservedEnvironmentNames: Set<String> = ["HOME", "PATH", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GEMINI_CLI_HOME",
        "GEMINI_CLI_SYSTEM_SETTINGS_PATH", "GEMINI_CLI_SYSTEM_DEFAULTS_PATH", "NODE_OPTIONS", "DYLD_INSERT_LIBRARIES"]
    public static let reservedEnvironmentPrefixes = ["CLAUDE_CODE_", "GEMINI_CLI_"]
    public static func isEnvironmentName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,79}$"#, options: .regularExpression) != nil
            && !reservedEnvironmentNames.contains(name) && !reservedEnvironmentPrefixes.contains(where: name.hasPrefix)
    }
    public static func permissionModes(provider: String) -> [String] {
        switch provider { case "claude": ["default", "acceptEdits", "plan", "bypassPermissions"]
        case "codex": ["default", "read-only", "workspace-write", "danger-full-access"]
        case "gemini": ["default", "auto_edit", "plan", "yolo"]
        default: [] }
    }
    public static func hookEvents(provider: String) -> [String] {
        switch provider {
        case "claude": ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop", "PreCompact", "Notification"]
        case "codex": ["SessionStart", "SessionEnd", "PreToolUse", "PostToolUse", "PermissionRequest", "UserPromptSubmit", "Stop", "Interrupt", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]
        case "gemini": ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeModel", "AfterModel", "BeforeToolSelection", "BeforeTool", "AfterTool", "PreCompress", "Notification"]
        default: [] }
    }
}

/// "Stop when done", one rule for the agent window and the AI tools (#520). On, the session is
/// parked when its work is done and nothing keeps it alive; off, it stays open until it is closed.
public enum AGSStopWhenDone {
    /// Read from the profile's keep-alive pair.
    public static func isOn(keepAliveUntilClose: Bool, keepAliveMinutes: Double) -> Bool { !keepAliveUntilClose && keepAliveMinutes == 0 }
    /// The profile's keep-alive pair for the switch.
    public static func keepAlive(_ stop: Bool) -> (untilClose: Bool, minutes: Int) { (!stop, 0) }
    /// The agent settings half: nothing keeps it open, and finishing parks it; off leaves the finishing rule as it was.
    public static func apply(_ stop: Bool, to settings: inout AGSAgentSettings) {
        settings.keepOpen = !stop
        guard stop else { return }
        var controls = settings.efficiency ?? .init()
        controls.completion = "park"
        settings.efficiency = controls
    }
}
