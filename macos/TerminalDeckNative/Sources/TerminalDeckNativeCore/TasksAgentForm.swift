import Foundation

// MARK: - The agent form

/// An agent while it is being typed: every field as the input holds it.
public struct AgentDraft: Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var provider: String
    public var account: String
    public var model: String
    public var effort: String
    public var instructions: String
    public var instructionsFile: String?
    public var status: AgentStatus
    public var statusAt: Double?
    public var toolsPreferred: [String]
    public var toolsAvoided: [String]
    public var skills: [String]
    public var blockedTools: [String]
    public var skillsOff: Bool
    public var maxConcurrent: String
    public var maxRunMinutes: String
    public var keepAliveMinutes: String
    public var verifyCommand: String
    public var claudeAgent: String
    public var allowedTools: [String]?
    public var permissionMode: String
    public var keepAliveUntilClose: Bool
    public var defaultProject: String
    public var projectID: String?
    public var reviewerAgent: String
    public var sourceFile: String?
    public var sourceDirectory: String?
    public var syncedAt: Double?
    public var syncStatus: String?
    public var syncError: String?
    /// AGT: carried unchanged through the settings form (the Agents page edits them).
    public var icon: String?
    public var reportsTo: String?
    /// Deck Memory: its role (seat). Carried through every save, so changing its project or picture keeps it.
    public var toolUseRestrictions: NativeRPCValue?
    public var seat: String?

    public var agsSettings: AGSAgentSettings? = nil
    public var agsRevision: UInt64? = nil

    public init(_ agent: AgentProfile?) {
        id = agent?.id ?? ""
        name = agent?.name ?? ""
        role = agent?.role ?? ""
        provider = agent?.provider ?? ""
        account = agent?.account ?? ""
        model = agent?.model ?? ""
        effort = agent?.effort ?? ""
        instructions = agent?.instructions ?? ""
        instructionsFile = agent?.instructionsFile
        status = agent?.status ?? .active
        statusAt = agent?.statusAt
        toolsPreferred = agent?.toolsPreferred ?? []
        toolsAvoided = agent?.toolsAvoided ?? []
        skills = agent?.skills ?? []
        blockedTools = agent?.blockedTools ?? []
        skillsOff = agent?.skillsOff ?? false
        maxConcurrent = String(agent?.maxConcurrent ?? 0)
        maxRunMinutes = String(agent?.maxRunMinutes ?? TasksLimits.defaultRunMinutes)
        keepAliveMinutes = String(agent?.keepAliveMinutes ?? TasksLimits.defaultKeepAliveMinutes)
        verifyCommand = agent?.verifyCommand ?? ""
        claudeAgent = agent?.claudeAgent ?? ""
        allowedTools = agent?.allowedTools
        permissionMode = agent?.permissionMode ?? ""
        keepAliveUntilClose = agent?.keepAliveUntilClose == true
        defaultProject = agent?.defaultProject ?? ""
        projectID = agent?.hasExplicitProjectID == true ? agent?.projectID : nil
        reviewerAgent = agent?.reviewerAgent ?? ""
        sourceFile = agent?.sourceFile
        sourceDirectory = agent?.sourceDirectory
        syncedAt = agent?.syncedAt
        syncStatus = agent?.syncStatus
        syncError = agent?.syncError
        icon = agent?.icon
        reportsTo = agent?.reportsTo
        toolUseRestrictions = agent?.toolUseRestrictions
        seat = agent?.seat
    }
}

public enum AgentForm {
    /// A stable id from a name: lower case, letters, digits and dashes. Unique among `taken`.
    public static func slug(_ name: String, taken: [String] = []) -> String { TaskNames.agentID(name, taken: Set(taken)) }

    /// A whole number from a box, or the sentence that says why not. Empty takes the fallback.
    public static func whole(_ raw: String, field: String, min: Int, max: Int, fallback: Int) -> Result<Int, TasksProblem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(fallback) }
        guard let value = Double(trimmed), value == value.rounded(), value >= Double(min), value <= Double(max) else {
            return .failure(TasksProblem("\(field) has to be a whole number from \(min) to \(max)."))
        }
        return .success(Int(value))
    }

    /// Trimmed, blanks dropped, first of each kept.
    static func unique(_ values: [String]) -> [String] {
        var out: [String] = []
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty && !out.contains(value) {
            out.append(value)
        }
        return out
    }

    static func orNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What `tasks:agent-save` is sent, or the sentence that says what to fix first.
    /// A name no other agent has (the engine refuses a second agent with the same name): "Builder", else "Builder 2", "Builder 3"…
    public static func uniqueName(_ name: String, among agents: [AgentProfile]) -> String {
        let base = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let taken = Set(agents.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while true {
            let suffix = " \(n)", candidate = String(base.prefix(60 - suffix.count)) + suffix
            if !taken.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }

    public static func payload(_ draft: AgentDraft, agents: [AgentProfile]) -> Result<AgentProfile, TasksProblem> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(TasksProblem("Give the agent a name.")) }
        let maxConcurrent = whole(draft.maxConcurrent, field: "Tasks at once", min: 0, max: TasksLimits.maxConcurrent, fallback: 0)   // 0: no limit (PARALLEL-JOBS)
        let maxRun = whole(draft.maxRunMinutes, field: "Longest run", min: 0, max: TasksLimits.maxMinutes, fallback: TasksLimits.defaultRunMinutes)
        let keepAlive = whole(draft.keepAliveMinutes, field: "Keep open", min: 0, max: TasksLimits.maxMinutes,
                              fallback: TasksLimits.defaultKeepAliveMinutes)
        for value in [maxConcurrent, maxRun] {
            if case .failure(let problem) = value { return .failure(problem) }
        }
        if !draft.keepAliveUntilClose, case .failure(let problem) = keepAlive { return .failure(problem) }
        let provider = orNil(draft.provider)
        let claudeOnly = orNil(draft.claudeAgent) != nil || (!SourceNamespace.agentSettingsEnabled && (draft.allowedTools != nil || orNil(draft.permissionMode) != nil))
        if claudeOnly && AgentCapabilities.family(provider) != .claude {
            return .failure(TasksProblem("Claude Code agent, allowed tools and permission mode need Claude Code. Clear them, or choose Claude Code."))
        }
        if SourceNamespace.agentSettingsEnabled, AgentCapabilities.family(provider) == .codex {
            let tools = (draft.allowedTools ?? []) + draft.blockedTools
            if !tools.allSatisfy({ $0.range(of: #"^mcp__[A-Za-z0-9_-]{1,64}__[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }) {
                return .failure(TasksProblem("Codex tool lists need exact MCP tool names. Built-in tool restrictions need a supported permission mode."))
            }
        }
        let permissionModes = SourceNamespace.agentSettingsEnabled ? AGSCapabilities.permissionModes(provider: provider ?? "claude") : AGSCapabilities.permissionModes(provider: "claude")
        if !draft.permissionMode.isEmpty && !permissionModes.contains(draft.permissionMode) {
            return .failure(TasksProblem("Choose a permission mode from the list."))
        }
        if let project = orNil(draft.defaultProject), !project.hasPrefix("/") {
            return .failure(TasksProblem("Default project must be a full folder path starting with /, or empty."))
        }
        if !draft.reviewerAgent.isEmpty && (draft.reviewerAgent == draft.id || !agents.contains(where: { $0.id == draft.reviewerAgent && $0.status != .archived })) {
            return .failure(TasksProblem("Choose another available task agent as the reviewer."))
        }
        if SourceNamespace.agentSettingsEnabled {
            // Codex and Gemini keep tool limits too (agent settings); only "turn every skill off" is
            // Claude Code's alone. Each refusal says exactly that, in the engine's own words.
            if !unique(draft.blockedTools).isEmpty && !AGSCapabilities.providers.contains(provider ?? "claude") {
                return .failure(TasksProblem(AgentCapabilities.toolLimitsNeedSupportedAgent))
            }
            if draft.skillsOff && !AgentCapabilities.enforces(provider, .skillsOff) {
                return .failure(TasksProblem(AgentCapabilities.skillsOffOnlyClaude))
            }
        } else if (!unique(draft.blockedTools).isEmpty && !AgentCapabilities.enforces(provider, .blockedTools))
            || (draft.skillsOff && !AgentCapabilities.enforces(provider, .skillsOff)) {
            return .failure(TasksProblem(AgentCapabilities.enforceOnlyClaude))
        }
        // A setting the chosen agent cannot be given is refused, never saved to be dropped.
        if orNil(draft.model) != nil && !(SourceNamespace.agentSettingsEnabled && AGSCapabilities.providers.contains(provider ?? "claude")) && !AgentCapabilities.enforces(provider, .model) {
            return .failure(TasksProblem("\(AgentCapabilities.label(provider)) cannot be given a model by this app. Clear it, or choose Claude Code."))
        }
        let knownEffort = SourceNamespace.agentSettingsEnabled
            ? draft.effort == "auto" || AGSCapabilities.efforts(provider: provider ?? "claude").contains(draft.effort)
            : EFFORT_CHOICES.contains { $0.id == draft.effort }
        if !SourceNamespace.agentSettingsEnabled, !draft.effort.isEmpty, !AgentCapabilities.enforces(provider, .effort) {
            return .failure(TasksProblem("\(AgentCapabilities.label(provider)) cannot be given an effort level by this app. Clear it, or choose Claude Code."))
        }
        if SourceNamespace.agentSettingsEnabled, !draft.effort.isEmpty, !knownEffort {
            return .failure(TasksProblem("That saved effort is not supported by the selected coding agent. Review it before saving; it will not be silently replaced."))
        }
        let id = draft.id.isEmpty ? slug(name, taken: agents.map(\.id)) : draft.id
        let role = draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(AgentProfile(
            id: id, name: name, role: role.isEmpty ? "general" : role, provider: provider, account: orNil(draft.account),
            model: orNil(draft.model), effort: knownEffort ? draft.effort : nil,
            instructions: instructions.isEmpty ? nil : instructions, instructionsFile: draft.instructionsFile,
            toolsPreferred: unique(draft.toolsPreferred), toolsAvoided: unique(draft.toolsAvoided), skills: unique(draft.skills),
            blockedTools: unique(draft.blockedTools), skillsOff: draft.skillsOff,
            maxConcurrent: (try? maxConcurrent.get()) ?? 1, maxRunMinutes: (try? maxRun.get()) ?? TasksLimits.defaultRunMinutes,
            keepAliveMinutes: (try? keepAlive.get()) ?? TasksLimits.defaultKeepAliveMinutes,
            verifyCommand: orNil(draft.verifyCommand),
            // Sent as it is; the main process keeps an agent's status whatever a save carries.
            status: draft.status, statusAt: draft.statusAt,
            claudeAgent: orNil(draft.claudeAgent), allowedTools: draft.allowedTools.map(unique), permissionMode: orNil(draft.permissionMode),
            // An untouched legacy nil remains absent; explicitly turning an
            // existing on/off setting off still sends false.
            keepAliveUntilClose: draft.keepAliveUntilClose ? true : (agents.first { $0.id == id }?.keepAliveUntilClose).map { _ in false },
            defaultProject: orNil(draft.defaultProject), reviewerAgent: orNil(draft.reviewerAgent),
            sourceFile: draft.sourceFile, sourceDirectory: draft.sourceDirectory, syncedAt: draft.syncedAt,
            syncStatus: draft.syncStatus, syncError: draft.syncError, icon: draft.icon, reportsTo: draft.reportsTo, projectID: draft.projectID,
            seat: draft.seat, toolUseRestrictions: draft.toolUseRestrictions))
    }
}
