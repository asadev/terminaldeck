import Foundation

// MARK: - The mirror, local tasks, the page's lines

public enum TasksRules {
    /// The mirror shows only once there is something to mirror, or somewhere it would come from.
    public static func showMirror(_ state: TasksState?) -> Bool {
        guard let state else { return false }
        return !state.tasks.isEmpty || !state.connections.isEmpty
    }

    public static func processLabel(_ process: ProcessState) -> String {
        switch process {
        case .idle: ""
        case .running: "Running"
        case .exited: "Finished"
        case .queued: "Queued"
        }
    }

    /// Whole minutes left on a kept-open session, at least 1 while any is left; nil when none.
    public static func keptOpenMinutes(_ keepOpenUntil: Double?, now: Double) -> Int? {
        guard let until = keepOpenUntil, until > now else { return nil }
        return max(1, Int(((until - now) / 60_000).rounded(.up)))
    }

    /// The agents a picker offers: every one but the archived.
    public static func pickableAgents(_ agents: [AgentProfile]) -> [AgentProfile] {
        agents.filter { $0.status != .archived }
    }

    /// Who has a task: nobody, you, Hoot, then every task agent but the archived — a
    /// paused one is offered and says so.
    public static func assigneeChoices(_ agents: [AgentProfile]) -> [(id: String, label: String)] {
        [("none", "Unassigned"), ("me", "Me"), ("hoot", BRAND_ASSISTANT)]
            + pickableAgents(agents).map { ($0.id, $0.status == .paused ? "\($0.name) (paused)" : $0.name) }
    }

    /// Who has a task, as the row says it.
    public static func assigneeLabel(_ task: TaskRow, state: TasksState) -> String {
        assigneeChoices(state.agents).first { $0.id == task.assignee }?.label ?? task.agent
    }

    /// One line on each connection: which key, on or off, and whether it can take work yet.
    public static func connectionLine(_ state: TasksState) -> String? {
        guard !state.connections.isEmpty else { return nil }
        return state.connections.map { connection in
            let key = state.keys.first { $0.id == connection.keyId }?.name ?? "a removed key"
            if !connection.enabled { return "CRM on “\(key)” is off" }
            if connection.allowedSenders.isEmpty || connection.folders.isEmpty {
                return "CRM on “\(key)” is on, but needs an allowed sender and a project folder"
            }
            return "CRM on “\(key)” is on"
        }.joined(separator: " · ")
    }

    /// What has not reached the CRM yet, or nil when everything has.
    public static func outboxLine(_ state: TasksState) -> String? {
        var parts: [String] = []
        if state.outbox.pending > 0 {
            parts.append("\(state.outbox.pending) update\(state.outbox.pending == 1 ? "" : "s") on the way to the CRM")
        }
        if state.outbox.undelivered > 0 { parts.append("\(state.outbox.undelivered) could not be delivered") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Tasks page's header lines, in order.
    public static func facts(_ state: TasksState) -> [String] {
        let agents = state.agents.count
        return [
            connectionLine(state),
            "\(agents) task agent\(agents == 1 ? "" : "s")\(agents == 0 ? " — add one in Settings to give tasks to an agent" : "")",
            outboxLine(state),
        ].compactMap { $0 }
    }
}

/// A local task while it is being typed.
public struct LocalDraft: Equatable, Sendable {
    public var title: String
    public var instructions: String
    public var project: String
    /// `none`, `me`, `hoot`, or an agent's id.
    public var assignee: String
    public var status: String
    /// The goal it serves; empty for none.
    public var goalId: String

    public init(_ task: TaskRow?, statuses: [String]) {
        title = task?.title ?? ""
        instructions = task?.instructions ?? ""
        project = task?.project ?? ""
        assignee = task?.assignee ?? "none"
        status = task?.crmStatus ?? statuses.first ?? "To-Do"
        goalId = task?.goalId ?? ""
    }

    /// What `tasks:local-create` / `tasks:local-update` is sent, or what to fix first.
    public func payload(agents: [AgentProfile] = []) -> Result<[String: Any], TasksProblem> {
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .failure(TasksProblem("Give the task a title.")) }
        var project = self.project.trimmingCharacters(in: .whitespacesAndNewlines)
        let working = assignee != "none" && assignee != "me"
        if working && project.isEmpty { project = agents.first { $0.id == assignee }?.defaultProject ?? "" }
        if working && project.isEmpty { return .failure(TasksProblem("Choose the project folder the agent should work in.")) }
        return .success([
            "title": title,
            "instructions": instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            "project": project,
            "assignee": assignee,
            "status": status,
            "goalId": goalId,
        ])
    }
}
