import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Subtasks

    func q(_ s: String) -> String { "“\(s)”" }

    func addSubtask(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let draft = SubtaskRow(id: "draft-\(UUID().uuidString)", title: trimmed)
        subtasks = (subtasks ?? []) + [draft]
        Task {
            switch await call("addTaskSubtask", [taskId, trimmed]) {
            case .failure(let problem):
                subtasks?.removeAll { $0.id == draft.id }
                error = "Adding subtask \(q(trimmed)): \(problem.message)"
            case .success(let r):
                guard let id = r["id"] as? String else {
                    error = "Adding subtask \(q(trimmed)): saved, but the server returned no id"
                    return
                }
                if let i = subtasks?.firstIndex(where: { $0.id == draft.id }) { subtasks?[i].id = id }
            }
        }
    }

    func setSubtaskDone(_ row: SubtaskRow, _ done: Bool) {
        update(subtask: row.id) { $0.done = done }
        Task {
            if !(await write("setTaskSubtaskDone", [taskId, row.id, done], label: "\(done ? "Ticking" : "Unticking") \(q(row.title))")) {
                update(subtask: row.id) { $0.done = !done }
            }
        }
    }

    func setSubtaskAssignee(_ row: SubtaskRow, _ userId: String?) {
        let prev = row.assigneeUserId
        update(subtask: row.id) { $0.assigneeUserId = userId }
        joinLocally(userId)
        Task {
            if !(await write("setTaskSubtaskAssignee", [taskId, row.id, userId ?? NSNull()],
                             label: "\(userId != nil ? "Assigning" : "Unassigning") \(q(row.title))")) {
                update(subtask: row.id) { $0.assigneeUserId = prev }
            }
        }
    }

    func deleteSubtask(_ row: SubtaskRow) {
        let before = subtasks
        subtasks?.removeAll { $0.id == row.id }
        Task {
            if !(await write("deleteTaskSubtask", [taskId, row.id], label: "Removing subtask \(q(row.title))")) { subtasks = before }
        }
    }

    func update(subtask id: String, _ change: (inout SubtaskRow) -> Void) {
        guard let i = subtasks?.firstIndex(where: { $0.id == id }) else { return }
        change(&subtasks![i])
    }

}
