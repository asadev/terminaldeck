import Foundation

// The session's own controls on its bar — model, effort, fast mode and connectors
// (`shell/SessionControls.tsx`, `useSessionControls.ts`, `agent-presence.ts` and
// the words in `chat/controls/catalog.ts`), as rules a native view can draw.

public extension TerminalControlCatalog {
    /// The controls on the bar, in order (`CHROME_CONTROLS`). Fast mode is nested
    /// at the foot of the model menu on the row, and is a section in the panel.
    static let chromeControls = ["model", "effort", "fast"]
    /// What has a chip of its own on the row (`ROW_CONTROLS`).
    static let rowControls = ["model", "effort"]

    static let fast: [TerminalControlOption] = [.init(id: "off", label: "Off"), .init(id: "on", label: "On")]

    /// `optionsForRow`.
    static func options(_ control: String) -> [TerminalControlOption] {
        switch control {
        case "model": return models + earlierModels
        case "effort": return effort
        case "fast": return fast
        default: return []
        }
    }

    /// `controlName`.
    static func name(_ control: String) -> String {
        switch control {
        case "model": return "Model"
        case "effort": return "Effort"
        case "fast": return "Fast mode"
        default: return "Permission"
        }
    }

    /// `describeControl`.
    static func describe(_ control: String) -> String {
        switch control {
        case "model": return "Which model answers in this session."
        case "effort": return "How much reasoning the model spends before it answers."
        case "fast": return "The same model, answering faster. Switching to another model turns it off."
        default: return "What the agent may do without stopping to ask you first."
        }
    }

    /// `controlNote`: only fast mode keeps its description, behind the ⓘ.
    static func note(_ control: String) -> String? {
        control == "fast" ? describe(control) : nil
    }

    /// `reachOf`.
    static func reach(_ control: String) -> String? {
        switch control {
        case "permission": return "This session only"
        case "fast": return "Stays on until you turn it off — new sessions too"
        default: return "This session — and your default too, if the CLI says so when it confirms"
        }
    }

    /// `sourceNote`.
    static func sourceNote(_ source: String?) -> String {
        switch source {
        case "screen": return "read from this session"
        case "transcript": return "from the last reply"
        case "settings": return "from Claude settings"
        case "env": return "set by CLAUDE_CODE_EFFORT_LEVEL"
        default: return "not known"
        }
    }

    /// `unreadLabel` / `displayValue`.
    static func value(_ reading: TerminalControlReading?, control: String) -> String {
        guard let label = reading?.label else { return control == "permission" ? "Not reported" : "Unknown" }
        return label
    }

    /// `unreadNote`.
    static func unreadNote(_ control: String) -> String? {
        guard control == "permission" else { return nil }
        return "Claude prints the permission mode only when it changes, and no default is set in your Claude settings — so this session has not said which one it is in. Pick one and it will."
    }

    /// `toggleUnreadBrief`: why a two-state control has no switch yet.
    static func toggleUnreadBrief(_ control: String) -> String {
        "\(name(control)) is read from this session’s own screen, and it has not drawn one yet — so there is no position to show."
    }

    /// A chip's hover label: the refusal, or `name: value — where it was read`.
    static func chipHelp(_ control: String, reading: TerminalControlReading?, busy: Bool, blocked: String?) -> String {
        if let blocked { return blocked }
        let shown = busy ? "Working…" : value(reading, control: control)
        let note = reading?.isUnread ?? true ? (unreadNote(control) ?? sourceNote(nil)) : sourceNote(reading?.source)
        return "\(name(control)): \(shown) — \(note)"
    }

    /// `contentsSentence`: "Model, effort and fast mode" (and connectors).
    static func contentsSentence(withConnectors: Bool) -> String {
        let names = chromeControls.map(name) + (withConnectors ? ["Connectors"] : [])
        let words = names.enumerated().map { $0.offset == 0 ? $0.element : $0.element.lowercased() }
        guard words.count > 1 else { return words.first ?? "" }
        return words.dropLast().joined(separator: ", ") + " and " + words.last!
    }

    /// `summaryLabel`: the folded chip's hover label.
    static func summaryLabel(model: String, effort: String, withConnectors: Bool) -> String {
        "\(contentsSentence(withConnectors: withConnectors)) — model \(model), effort \(effort)"
    }

    /// `foreignAgentNote`: Codex and Gemini have their own commands this build has not been shown.
    static func foreignAgentNote(_ provider: String?) -> String? {
        guard provider == "codex" || provider == "gemini" else { return nil }
        let agent = provider == "codex" ? "Codex" : "Gemini"
        return "These work by typing one CLI’s own commands into the session. \(agent) has its own, and this build has not been shown what they are — so nothing is offered here rather than a button that types the wrong thing."
    }

    static let notWired = "Model, effort and fast mode are not wired into this build."
    static let mcpUninstalled = "The MCP servers view is not installed in this build, so there is nowhere for this to open."
}

/// Whether an agent is running in a session, and which (`agent-presence.ts`).
public enum SessionPresence {
    /// `presenceFromSession`: settled from the record, or nil to read the screen
    /// (a shell, where an agent may have been started by hand).
    public static func fromSession(provider: String?, exited: Bool) -> Bool? {
        if exited { return false }
        if let provider, provider != "shell" { return true }
        return nil
    }

    /// `settle`: a screen that stops showing an agent it showed a moment ago is
    /// "not sure", not "gone" — a redraw is not a quit.
    public static func settle(previous: Bool?, reading: Bool?, seenAgent: Bool) -> Bool? {
        guard reading == false, seenAgent else { return reading }
        return previous == true ? nil : reading
    }

    /// `runningProvider`: a shell with an agent in it is "an agent, which one unknown".
    public static func runningProvider(_ provider: String?, agentRunning: Bool?) -> String? {
        if provider == "shell", agentRunning == true { return nil }
        return provider
    }
}

/// The effort a fresh Claude Code session is given once (`preferredEffort`).
public enum SessionEffortMemory {
    public static let key = "session-controls.effort.v1"
    public static let defaultEffort = "xhigh"

    /// What to apply, or nil for nothing (`auto` means "apply nothing").
    public static func preferred(stored: String?) -> String? {
        guard let stored else { return defaultEffort }
        if stored == "auto" { return nil }
        return TerminalControlCatalog.effort.contains { $0.id == stored } ? stored : defaultEffort
    }

    /// Whether the default should be typed now: a local Claude Code session, readings
    /// in, nothing busy, effort unread and not refused, the session typeable, and
    /// not already done for this session.
    public static func shouldApply(want: String?, local: Bool, provider: String?, readings: TerminalControls?,
                                   busy: Bool, alreadyDefaulted: Bool) -> Bool {
        guard want != nil, local, provider == "claude", let readings, !busy, !alreadyDefaulted else { return false }
        guard readings.effort.label == nil, readings.effort.unavailableReason == nil else { return false }
        return readings.canType
    }
}

// MARK: - The page's feature switches (`features.v2`)

/// What the session bar obeys of the page's feature store: the usage bar
/// (`controlOn('chrome.usage')`, feature `usage`) and the Connectors chip's door
/// (`panelOn('mcp')`). A feature the store says nothing about, or says something
/// unreadable about, is at its default — both default on.
public struct SessionFeatures: Equatable, Sendable {
    public static let storageKey = "features.v2"
    public static let defaults = SessionFeatures(usageOn: true, mcpOn: true)

    public var usageOn: Bool
    public var mcpOn: Bool

    public init(usageOn: Bool, mcpOn: Bool) {
        self.usageOn = usageOn
        self.mcpOn = mcpOn
    }

    /// From the stored JSON (`{ id: "on" | "off" | "uninstalled" }`), or nil for none stored.
    public static func decode(_ json: String?) -> SessionFeatures {
        let stored = DashboardRules.featureState(json)
        return SessionFeatures(usageOn: (stored["usage"] ?? "on") == "on", mcpOn: (stored["mcp"] ?? "on") == "on")
    }
}

extension TerminalControlCatalog {
    /// The Connectors door when the MCP servers view is switched off: still drawn, disabled.
    public static let connectorsUnavailable = "Not available in this build"
}
