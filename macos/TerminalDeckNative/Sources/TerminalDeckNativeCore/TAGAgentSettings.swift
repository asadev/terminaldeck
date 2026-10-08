import Foundation

/// Pure presentation rules for task-agent settings and linked work.
public enum TAGAgentSettings {
    public static let permissionModes = ["default", "acceptEdits", "plan", "bypassPermissions"]

    public static func tools(from text: String) -> [String] {
        var values: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty && !values.contains(value) { values.append(value) }
        }
        return values
    }

    public static func syncLabel(_ agent: AgentProfile) -> String? {
        guard agent.sourceFile != nil else { return nil }
        switch agent.syncStatus {
        case "synced": return "Synced"
        case "missing": return "Source missing"
        case "error": return "Sync failed"
        default: return "Sync not confirmed"
        }
    }

    public static func reviewerLabel(_ agent: AgentProfile, agents: [AgentProfile]) -> String {
        if let reviewer = agent.reviewerAgent {
            return "Checked by: \(agents.first { $0.id == reviewer }?.name ?? reviewer)"
        }
        return agent.verifyCommand.map { "Checked by: \($0)" } ?? "\(BRAND_ASSISTANT) checks the result"
    }

    public static func parent(of task: TaskRow, in tasks: [TaskRow]) -> TaskRow? {
        if let id = task.parentTaskId { return tasks.first { $0.id == id && $0.id != task.id } }
        guard let external = task.parentExternalTaskId else { return nil }
        return tasks.first { $0.keyId == task.keyId && $0.externalTaskId == external && $0.id != task.id }
    }

    public static func children(of task: TaskRow, in tasks: [TaskRow]) -> [TaskRow] {
        tasks.filter { child in
            guard child.id != task.id else { return false }
            if let parent = child.parentTaskId { return parent == task.id }
            return !task.externalTaskId.isEmpty && child.keyId == task.keyId && child.parentExternalTaskId == task.externalTaskId
        }.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }
}
