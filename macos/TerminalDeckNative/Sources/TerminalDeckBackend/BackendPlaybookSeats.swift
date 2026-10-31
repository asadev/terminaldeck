import Foundation
import TerminalDeckNativeCore

/// Asad (12 Oct): "Agents placed in seats still use their own AI settings rather than the playbook choice… let's fix
/// that". One order for every agent job — a hand hired into a seat, an agent's task job, an agent a lead hired — on
/// every AI (Claude Code, Codex, Gemini):
///   1. the playbook row matching the job (the project lead's playbook; Hoot's where the project has no lead),
///   2. else the agent's own profile settings,
///   3. else the app defaults (Settings › Agents).
/// What one layer leaves empty falls through to the next. A model or effort set on the task itself stays on top.
/// The layer is decided once per task (stored as task["playbook"]), so every later launch, reply and reuse check of
/// that task sees the same choice.
public struct BackendPlaybookLayer: Sendable, Equatable {
    public var jobKind: String
    /// The app's id for the row's AI ("claude", "codex", "gemini"); nil = the row leaves the AI to the agent.
    public var provider: String?
    public var model: String?
    /// As written in the row; checked against the AI when applied.
    public var effort: String?
    /// The row's permission in the app's words (ask, plan, auto, bypass).
    public var permission: String?

    public init(jobKind: String, provider: String? = nil, model: String? = nil, effort: String? = nil, permission: String? = nil) {
        self.jobKind = jobKind; self.provider = provider; self.model = model; self.effort = effort; self.permission = permission
    }
    public init(row: DeckMemoryPlaybookRow) {
        func clean(_ text: String) -> String? { let value = text.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
        self.init(jobKind: row.jobKind, provider: BackendPlaybookFill.ai(row.ai), model: clean(row.model), effort: clean(row.effort), permission: clean(row.permission))
    }
    /// The stored form on a task; nil for null or anything unreadable.
    public init?(wire: NativeRPCValue) {
        guard wire.fields != nil, let job = wire["job"].string else { return nil }
        self.init(jobKind: job, provider: wire["ai"].string, model: wire["model"].string, effort: wire["effort"].string, permission: wire["permission"].string)
    }
    public var isEmpty: Bool { provider == nil && model == nil && effort == nil && permission == nil }
    public var wireValue: NativeRPCValue {
        func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
        return .object([.init("job", .string(jobKind)), .init("ai", text(provider)), .init("model", text(model)),
                        .init("effort", text(effort)), .init("permission", text(permission))])
    }

    /// The agent row a launch uses. The playbook's AI replaces the agent's own; with another AI, what the agent set for
    /// its own AI (model, effort, permission, account, Claude Code agent name) does not carry over: it falls through
    /// to the new AI's app defaults, and the account to that AI's own sign-in.
    public func agentRow(_ agent: NativeRPCValue) -> NativeRPCValue {
        guard let provider, provider != (agent["provider"].string ?? "") else { return agent }
        return agent.setting("provider", .string(provider)).setting("model", .null).setting("effort", .null)
            .setting("permissionMode", .null).setting("account", .null).setting("claudeAgent", .null).setting("agoptSettings", .null)
    }
    /// Over settings already resolved from the agent's own profile and the app defaults: the row's choices win.
    public func apply(to settings: AGSAgentSettings) -> AGSAgentSettings {
        var result = settings
        if let model { result.model = model }
        if let effort, let level = BackendPlaybookFill.effort(effort, provider: result.provider) { result.effort = level }
        if let mode = permission.flatMap(BackendPlaybookFill.permission), let cli = HootChatProvider(rawValue: result.provider) { result.permissionMode = mode.cliMode(provider: cli) }
        return result
    }
    /// Which of ai / model / effort / permission this row really decides on `provider`.
    public func decides(provider: String) -> Set<String> {
        var fields: Set<String> = []
        if self.provider != nil { fields.insert("ai") }
        if model != nil { fields.insert("model") }
        if let effort, BackendPlaybookFill.effort(effort, provider: provider) != nil { fields.insert("effort") }
        if permission.flatMap(BackendPlaybookFill.permission) != nil, HootChatProvider(rawValue: provider) != nil { fields.insert("permission") }
        return fields
    }

    /// An agent's profile carried to `provider` (the playbook's AI): its AI-specific choices are dropped (they fall
    /// through to that AI's defaults) and hooks the AI does not know are left out. Same AI: unchanged.
    public static func carried(_ profile: AGSAgentSettings, to provider: String) -> AGSAgentSettings {
        var next = profile
        if profile.provider != provider { next.provider = provider; next.model = nil; next.effort = nil; next.permissionMode = nil }
        let events = Set(AGSCapabilities.hookEvents(provider: provider))
        if !profile.hooks.allSatisfy({ events.contains($0.event) }) { next.hooks = profile.hooks.filter { events.contains($0.event) } }
        return next
    }

    /// Where each launched value came from, for the agent's profile ("playbook", "agent", "default", "task").
    /// `own`: the agent's own profile for the launched AI, before the app defaults.
    public static func sources(layer: BackendPlaybookLayer?, own: AGSAgentSettings?, launched: AGSAgentSettings, task: NativeRPCValue) -> NativeRPCValue {
        let decided = layer?.decides(provider: launched.provider) ?? []
        func source(_ field: String, own value: String?, taskChoice: String?) -> NativeRPCValue {
            if taskChoice != nil { return .string("task") }
            if decided.contains(field) { return .string("playbook") }
            if field == "ai" { return .string("agent") }
            return .string(value != nil ? "agent" : "default")
        }
        let sameAI = own?.provider == launched.provider
        return .object([.init("ai", source("ai", own: launched.provider, taskChoice: nil)),
                        .init("model", source("model", own: sameAI ? own?.model : nil, taskChoice: task["model"].string)),
                        .init("effort", source("effort", own: sameAI ? own?.effort : nil, taskChoice: task["effort"].string)),
                        .init("permission", source("permission", own: sameAI ? own?.permissionMode : nil, taskChoice: nil))])
    }
}
