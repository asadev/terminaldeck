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
/// An extension to TAG's profile, also used by the session-start chooser.
/// nil means inherit; an empty allow list explicitly exposes no tools.
public struct AGSAgentSettings: Codable, Sendable, Equatable {
    public var provider: String, model: String?, effort: String?, permissionMode: String?
    public var allowedTools: [String]?, deniedTools: [String], mcpServers: [String: Bool]
    public var hooks: [AGSCLIHook], environment: [String: String], workingFolder: String?, keepOpen: Bool
    public init(provider: String = "claude", model: String? = nil, effort: String? = nil, permissionMode: String? = nil,
                allowedTools: [String]? = nil, deniedTools: [String] = [], mcpServers: [String: Bool] = [:], hooks: [AGSCLIHook] = [],
                environment: [String: String] = [:], workingFolder: String? = nil, keepOpen: Bool = false) {
        self.provider = provider; self.model = model; self.effort = effort; self.permissionMode = permissionMode
        self.allowedTools = allowedTools; self.deniedTools = deniedTools; self.mcpServers = mcpServers; self.hooks = hooks
        self.environment = environment; self.workingFolder = workingFolder; self.keepOpen = keepOpen
    }
}
public struct AGSDefaults: Codable, Sendable, Equatable {
    public var providers: [String: AGSAgentSettings], hooks: [AGSAppHook]
    public init(providers: [String: AGSAgentSettings] = [:], hooks: [AGSAppHook] = []) { self.providers = providers; self.hooks = hooks }
}
public enum AGSCapabilities {
    public static let providers = ["claude", "codex", "gemini"]
    public static let appEvents = ["session.started", "session.finished", "task.finished", "alert.raised", "receiver.event"]
    public static func efforts(provider: String) -> [String] {
        switch provider { case "claude": ["low", "medium", "high", "xhigh", "max"]
        case "codex": ["low", "medium", "high", "xhigh", "max", "ultra"]
        case "gemini": ["minimal", "low", "medium", "high"]
        default: [] }
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
