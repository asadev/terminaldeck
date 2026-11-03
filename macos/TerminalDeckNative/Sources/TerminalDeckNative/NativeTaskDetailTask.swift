import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: The task, with what this popup changed

    var task: CrmTask {
        var t = CrmTask(row, team: team)
        if let connected { t.createdBy = connected.createdBy }
        guard overridesAt == row.updatedAt else { return t }
        func has(_ key: String) -> Bool { overrides.keys.contains(key) }
        func value(_ key: String) -> String? { overrides[key] ?? nil }
        if let v = value("group") { t.group = v }
        if has("priority") { t.priority = value("priority") }
        if let v = value("startDate") { t.startDate = v }
        if let v = value("dueDate") { t.dueDate = v }
        if has("recurrence") { t.recurrence = value("recurrence") }
        if let v = value("title") { t.title = v }
        if let v = value("description") { t.description = v }
        if let v = value("board") { t.board = v }
        if has("assigneeUserId") {
            t.assigneeUserId = value("assigneeUserId")
            t.assignee = team.first { $0.id == t.assigneeUserId } ?? people?.primary
        }
        if has("archivedAt") { t.archivedAt = value("archivedAt") }
        return t
    }

    var canEditRow: Bool { task.assigneeUserId == me || task.createdBy == me }
    var meperson: CrmPerson? { team.first { $0.id == me } }

    /// Values shown at once; nil means "set to nothing".
    func patch(_ values: [String: String?]) {
        if overridesAt != row.updatedAt {
            overrides = [:]
            overridesAt = row.updatedAt
        }
        for (key, value) in values { overrides[key] = .some(value) }
    }

    /// The engine's newer state for this task (after any change, from anywhere).
    func update(row next: TaskRow, agents: [AgentProfile]) {
        let changed = next != row
        row = next
        commentAgentProfiles = agents
        team = connected?.team ?? CrmPeople.local(agents.map { ($0.id, $0.name) })
        guard changed else { return }
        // A change of the task's own fields shows in its activity a moment later.
        let print = fingerprint(task)
        if print != seen {
            seen = print
            activityTimer?.cancel()
            activityTimer = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await self?.loadActivity()
            }
        }
        Task { await loadWorkspace() }
    }

    func fingerprint(_ t: CrmTask) -> [String: String] {
        ["group": t.group, "priority": t.priority ?? "", "start": t.startDate, "due": t.dueDate, "title": t.title,
         "description": t.description, "board": t.board]
    }

}
