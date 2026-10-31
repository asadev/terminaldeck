import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: The row

    func changeStatus(_ next: String) {
        let prev = task.group
        guard next != prev else { return }
        patch(["group": next])
        Task {
            if !(await write("setTaskStatus", [taskId, next], label: "Status")) { patch(["group": prev]) }
            await loadRoutine()
        }
    }

    func changePriority(_ next: String?) {
        let prev = task.priority
        guard next != prev else { return }
        patch(["priority": next])
        Task {
            if !(await write("updateTask", [taskId, ["priority": next ?? NSNull()] as [String: Any]], label: "Priority")) {
                patch(["priority": prev])
            }
        }
    }

    /// Start and due dates (and the old recurrence word); a cleared date takes its time with it.
    func saveDates(start: String, due: String, recurrence: String?? = nil) {
        let t = task
        var body: [String: Any] = [:]
        if start != t.startDate { body["startDate"] = start }
        if due != t.dueDate { body["dueDate"] = due }
        if let recurrence, recurrence != t.recurrence { body["recurrence"] = recurrence ?? NSNull() }
        guard !body.isEmpty else { return }
        let prev: [String: String?] = ["startDate": t.startDate, "dueDate": t.dueDate, "recurrence": t.recurrence]
        var next: [String: String?] = [:]
        for (k, v) in body { next[k] = .some(v as? String) }
        patch(next)
        Task {
            switch await call("updateTask", [taskId, body]) {
            case .failure(let problem):
                patch(prev)
                error = "Dates: \(problem.message)"
            case .success(let r):
                if let kept = r["warning"] as? String {
                    error = "Dates: \(kept)"
                } else if body["startDate"] as? String == "" || body["dueDate"] as? String == "" {
                    if body["startDate"] as? String == "" { more?.startTime = nil }
                    if body["dueDate"] as? String == "" { more?.dueTime = nil }
                }
            }
        }
    }

    func setTime(_ which: String, _ hm: String?) {
        guard more != nil else { return }
        if which == "start" { more?.startTime = hm } else { more?.dueTime = hm }
        let body: [String: Any] = which == "start" ? ["startTime": hm ?? NSNull()] : ["dueTime": hm ?? NSNull()]
        moreDo("Time") { await self.call("setTaskTimes", [self.taskId, body]) }
    }

    func moveBoard(_ board: String) {
        let prev = task.board
        patch(["board": board])
        Task { if !(await write("moveTask", [taskId, board], label: "Move")) { patch(["board": prev]) } }
    }

    func patchExtras(_ label: String, _ apply: (inout TaskPageExtras) -> Void, _ run: @escaping () async -> Bool) {
        guard var next = extras else { return }
        let prev = extras
        apply(&next)
        extras = next
        Task {
            if !(await run()) {
                extras = prev
            }
        }
        _ = label
    }

    func changeType(_ type: String) {
        patchExtras("Task type", { $0.taskType = type }) { await self.write("setTaskType", [self.taskId, type], label: "Task type") }
    }

    func changeLabels(_ labels: [String]) {
        patchExtras("Tags", { $0.labels = labels }) { await self.write("setTaskLabels", [self.taskId, labels], label: "Tags") }
    }

    func changeSubtaskMeta(_ subtaskId: String, priority: String?? = nil, dueDate: String?? = nil) {
        var body: [String: Any] = [:]
        if let priority { body["priority"] = priority ?? NSNull() }
        if let dueDate { body["dueDate"] = dueDate ?? NSNull() }
        patchExtras("Subtask", { x in
            var cur = x.subtaskMeta[subtaskId] ?? SubtaskMeta()
            if let priority { cur.priority = priority }
            if let dueDate { cur.dueDate = dueDate }
            x.subtaskMeta[subtaskId] = cur
        }) { await self.write("setSubtaskMeta", [self.taskId, subtaskId, body], label: "Subtask") }
    }

    func duplicate(onDuplicated: @escaping (String) -> Void) {
        Task {
            switch await call("duplicateTask", [taskId]) {
            case .failure(let problem): error = "Duplicate: \(problem.message)"
            case .success(let r): if let id = r["id"] as? String { onDuplicated(id) }
            }
        }
    }

    /// The task's text: one field (the heading is its first line or sentence).
    func saveTitle(_ text: String) async -> Bool {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if clean == task.title { return true }
        switch await call("updateTask", [taskId, ["title": clean]]) {
        case .failure(let problem):
            error = "Title: \(problem.message)"
            return false
        case .success:
            patch(["title": clean])
            return true
        }
    }

    func saveDescription(_ text: String) async {
        switch await call("updateTask", [taskId, ["description": text]]) {
        case .failure(let problem): error = "Description: \(problem.message)"
        case .success: patch(["description": text.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
    }

}
