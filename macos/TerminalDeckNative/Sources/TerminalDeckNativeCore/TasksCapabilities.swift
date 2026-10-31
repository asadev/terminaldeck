import Foundation

// MARK: - What each coding agent can keep (src/shared/agent-capabilities.ts)

public enum AgentSetting: String, Sendable, CaseIterable {
    case model, effort, instructions, toolAdvice, blockedTools, skillsOff, skillSelection, mcpConfig, resumeById
}

public enum AgentSupport: String, Sendable, CaseIterable {
    case enforced, advisory, unsupported

    /// The small label beside a field.
    public var tag: String {
        switch self {
        case .enforced: "Enforced"
        case .advisory: "Advice only"
        case .unsupported: "Not available"
        }
    }
}

public enum AgentCapabilities {
    public typealias Family = SharedAgentCapabilities.Family

    public static func family(_ provider: String?) -> Family { SharedAgentCapabilities.familyOf(provider) }

    public static func support(_ provider: String?, _ setting: AgentSetting) -> AgentSupport {
        SharedAgentCapabilities.capabilityFor(provider, setting: setting).support
    }

    public static func enforces(_ provider: String?, _ setting: AgentSetting) -> Bool {
        support(provider, setting) == .enforced
    }

    /// A provider as a sentence names it.
    public static func label(_ provider: String?) -> String {
        switch provider {
        case nil: "The app’s default coding agent"
        case "claude": "Claude Code"
        case "codex": "Codex CLI"
        case "gemini": "Gemini CLI"
        case "shell": "Shell"
        default: "An added agent"
        }
    }

    /// Said wherever an enforced limit meets an agent that cannot keep it.
    public static let enforceOnlyClaude = "Only Claude Code can block tools or turn skills off. Clear them, or choose Claude Code."
    /// With agent settings on, Codex and Gemini keep tool limits as well; turning every skill off stays Claude Code's.
    public static let skillsOffOnlyClaude = "Only Claude Code can turn every skill off. Clear it, or choose Claude Code."
    public static let toolLimitsNeedSupportedAgent = "Tools can be blocked for Claude Code, Codex or Gemini. Clear them, or choose one of those."
}
