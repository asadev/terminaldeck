import Foundation

// Settings → Tasks in words (settings/sections/TasksSection.tsx's exported
// helpers), and the one plain sentence per agent and setting that says how this
// build applies it (shared/agent-capabilities.ts `how`).

extension AgentCapabilities {
    static let brief = "Written into the brief this agent is given. A request: nothing makes it follow it."

    /// How this build applies one setting for one coding agent, shown under the field.
    public static func how(_ provider: String?, _ setting: AgentSetting) -> String {
        if provider == nil && setting == .instructions {
            return "\(brief) Choose Claude Code or Codex to have them given at the start as standing instructions."
        }
        switch (family(provider), setting) {
        case (.claude, .model): return "Set in the session right after it starts, the way a person types /model."
        case (.claude, .effort): return "Set in the session right after it starts, the way a person types /effort."
        case (.claude, .instructions): return "Claude Code is started with the file added to its own system prompt, and the brief repeats it."
        case (.claude, .toolAdvice): return "\(brief) Claude Code’s own permission settings still decide."
        case (.claude, .blockedTools): return "Claude Code refuses these tools itself."
        case (.claude, .skillsOff): return "Claude Code starts with no skills at all."
        case (.claude, .skillSelection): return "\(brief) Claude Code cannot be limited to only these."
        case (.claude, .mcpConfig): return "Given its MCP servers on the command line."
        case (.claude, .resumeById): return "A reply continues the exact conversation, by its id."
        case (.codex, .model):
            return "Not set for Codex by this app yet: the model is changed by typing Claude Code’s command, which Codex does not take."
        case (.codex, .effort): return "Not set for Codex by this app yet."
        case (.codex, .instructions): return "Codex is started with the file’s text as its developer instructions, and the brief repeats it."
        case (.codex, .toolAdvice): return brief
        case (.codex, .blockedTools): return "Codex cannot refuse a named tool, so an agent with blocked tools is not started on it."
        case (.codex, .skillsOff): return "Not offered for Codex: switching every skill off could not be proven."
        case (.codex, .skillSelection): return "\(brief) Codex cannot be limited to only these."
        case (.codex, .mcpConfig): return "This app does not hand Codex an MCP configuration; it uses its own."
        case (.codex, .resumeById): return "A reply continues the exact conversation, by its id."
        case (.gemini, .model): return "Not set for Gemini by this app."
        case (.gemini, .effort): return "Gemini has no effort setting."
        case (.gemini, .instructions): return "\(brief) Gemini has no way to add standing instructions at the start."
        case (.gemini, .toolAdvice), (.gemini, .skillSelection): return brief
        case (.gemini, .blockedTools): return "Gemini cannot be started with tools refused, so an agent with blocked tools is not started on it."
        case (.gemini, .skillsOff): return "Not offered for Gemini."
        case (.gemini, .mcpConfig): return "This app does not hand Gemini an MCP configuration."
        case (.gemini, .resumeById): return "A reply after the session closed starts a new conversation."
        case (.shell, _): return "A shell reads no brief and takes no agent settings."
        case (.custom, .model), (.custom, .effort): return "Not set for an added agent."
        case (.custom, .instructions), (.custom, .toolAdvice), (.custom, .skillSelection): return brief
        case (.custom, .blockedTools): return "An added agent cannot be started with tools refused."
        case (.custom, .skillsOff): return "Not offered for an added agent."
        case (.custom, .mcpConfig): return "Not handed to an added agent."
        case (.custom, .resumeById): return "A reply after the session closed starts afresh."
        }
    }
}

public enum TasksSettingsText {
    /// The coding agents with a program to look up (agent-catalog.ts LOOKUP_AGENTS), in screen order.
    public static let lookupAgents: [(id: String, label: String)] = [("claude", "Claude Code"), ("codex", "Codex CLI"), ("gemini", "Gemini CLI")]

    /// Claude Code's own tools (agent-tools.ts CLAUDE_TOOLS).
    public static let claudeTools: [(name: String, label: String)] = [
        ("Bash", "Run commands"), ("Read", "Read files"), ("Write", "Write new files"), ("Edit", "Edit files"),
        ("MultiEdit", "Several edits at once"), ("NotebookEdit", "Edit notebooks"), ("Glob", "Find files by name"),
        ("Grep", "Search inside files"), ("WebFetch", "Open web pages"), ("WebSearch", "Search the web"),
        ("Task", "Start helper agents"), ("TodoWrite", "Keep a to-do list"),
    ]

    /// What the pickers offer for tools when nothing was read: Claude Code's own, for Claude Code only.
    public static func defaultTools(_ provider: String?) -> [InventoryChoice] {
        guard AgentCapabilities.family(provider) == .claude else { return [] }
        return claudeTools.map { InventoryChoice(value: $0.name, label: "\($0.name) — \($0.label)", where: "Claude Code") }
    }

    public static func providerName(_ provider: String?) -> String {
        guard let provider else { return "Default coding agent" }
        return lookupAgents.first { $0.id == provider }?.label ?? provider
    }

    /// The one line under an agent's name.
    public static func agentSummary(_ agent: AgentProfile) -> String {
        let run = agent.maxRunMinutes == 0 ? "no time limit" : "stops after \(agent.maxRunMinutes) min"
        let keep = agent.keepAliveMinutes == 0 ? "closes when done" : "stays open \(agent.keepAliveMinutes) min"
        let model = [agent.model, agent.effort.map { "\($0) effort" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return "\(providerName(agent.provider))\(model.isEmpty ? "" : " (\(model))") · \(agent.maxConcurrent) at once · \(run) · \(keep)"
    }

    /// The second line: what the agent is told besides the task, or nil.
    public static func agentStackSummary(_ agent: AgentProfile) -> String? {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        let atStart = agent.instructionsFile != nil && AgentCapabilities.enforces(agent.provider, .instructions)
        let told = [
            agent.instructions == nil || atStart ? nil : "instructions",
            agent.toolsPreferred.isEmpty ? nil : plural(agent.toolsPreferred.count, "preferred tool"),
            agent.toolsAvoided.isEmpty ? nil : plural(agent.toolsAvoided.count, "tool") + " to avoid",
            agent.skills.isEmpty ? nil : plural(agent.skills.count, "skill"),
        ].compactMap { $0 }
        let enforced = [
            atStart ? "standing instructions" : nil,
            agent.blockedTools.isEmpty ? nil : plural(agent.blockedTools.count, "tool") + " blocked",
            agent.skillsOff ? "skills off" : nil,
        ].compactMap { $0 }
        let lines = [told.isEmpty ? nil : "Told: \(told.joined(separator: " · "))",
                     enforced.isEmpty ? nil : "Enforced: \(enforced.joined(separator: " · "))"].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: " — ")
    }

    /// The badge beside a paused or archived agent's name.
    public static func statusBadge(_ status: AgentStatus) -> String? {
        switch status {
        case .paused: "Paused"
        case .archived: "Archived"
        case .active: nil
        }
    }

    /// The line under a paused or archived agent, saying what that means for its work.
    public static func statusLine(_ status: AgentStatus, at: Double?) -> String? {
        let since = at.map { " since \(Date(timeIntervalSince1970: $0 / 1000).formatted(.dateTime.year().month(.defaultDigits).day()))" } ?? ""
        switch status {
        case .paused: return "Paused\(since): takes no new work. What it is running carries on."
        case .archived: return "Archived\(since): kept, and offered nowhere until it is restored."
        case .active: return nil
        }
    }

    /// Under the instructions box: how they reach the agent, and where the file is.
    public static func instructionsHelp(_ provider: String?, file: String?) -> String {
        let h = AgentCapabilities.how(provider, .instructions)
        let how = AgentCapabilities.support(provider, .instructions) == .advisory
            ? "Given to this agent at the start of every task, and again when it picks a task back up. \(h)" : h
        guard let file else { return "\(how) Saved as a file of its own." }
        return "\(how) Kept in \(file); an edit made there is read back here."
    }

    /// Where the skills on offer were found, for the agent that will run them.
    public static func skillsHelp(_ provider: String?) -> String {
        if provider == "codex" { return "Skills in this Codex account’s, your home’s and your projects’ skill folders, named in its brief when they fit." }
        if let provider, provider != "claude" { return "Named in its brief when they fit." }
        return "Skills in this account’s and your projects’ skill folders, named in its brief when they fit. Claude Code’s built-in skills are not listed."
    }

    /// An existing key as the CRM picker names it: whose it is.
    public static func keyOption(_ key: TasksKey) -> String {
        if key.crmOnly { return "\(key.name) — a CRM key" }
        guard let app = key.lastApp else { return "\(key.name) — an AI-app key" }
        return "\(key.name) — an AI-app key, used by \(app)"
    }

    public static func keyHelp(_ key: TasksKey?) -> String {
        guard let key else { return "Recommended. It can send tasks and nothing else, and you confirm before it is made." }
        if key.crmOnly { return "A key made for a CRM: it can send tasks and nothing else." }
        return "An AI app’s key. The CRM would sign in as that app, and anyone with the key could send tasks."
    }

    /// Which key a connection signs in with, in words.
    public static func keyLine(_ key: TasksKey?, name: String) -> String {
        guard let key else { return "Signs in with \(name)" }
        return key.crmOnly ? "Signs in with its own key, \(key.name)" : "Signs in with \(key.name), an AI app’s key"
    }

    public static func connectionSummary(_ connection: CrmConnection) -> String {
        let senders = connection.allowedSenders.count
        let folders = connection.folders.count
        let who = senders == 0 ? "nobody allowed to send work" : "\(senders) allowed \(senders == 1 ? "sender" : "senders")"
        let where_ = folders == 0 ? "no project folders" : "\(folders) project \(folders == 1 ? "folder" : "folders")"
        return "\(who) · \(where_)"
    }
}
