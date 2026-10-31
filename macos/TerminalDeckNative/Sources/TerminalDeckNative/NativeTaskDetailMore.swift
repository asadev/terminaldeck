import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Part 2 (more)

    /// Run a part-2 action; its refusal is shown, its success re-reads the part and the feed.
    func moreDo(_ label: String, _ run: @escaping () async -> Result<[String: Any], TasksProblem>,
                after: (([String: Any]) -> Void)? = nil) {
        Task {
            switch await run() {
            case .failure(let problem):
                error = "\(label): \(problem.message)"
                await loadMore()
            case .success(let r):
                after?(r)
                await loadMore()
                await loadActivity()
            }
        }
    }

    func remind(_ at: Date) {
        moreDo("Remind me") { await self.call("setReminder", [self.taskId, CrmTime.iso(at.timeIntervalSince1970 * 1000), NSNull()]) }
    }

    func clearReminder(_ id: String) {
        moreDo("Reminder") { await self.call("clearReminder", [self.taskId, id]) }
    }

    func setArchived(_ archived: Bool) {
        moreDo(archived ? "Archive" : "Restore", { await self.call("setArchived", [self.taskId, archived]) }) { _ in
            self.patch(["archivedAt": archived ? CrmTime.iso(Date().timeIntervalSince1970 * 1000) : nil])
        }
    }

    func merge(into target: String, onGone: @escaping (String?) -> Void) {
        moreDo("Merge", { await self.call("mergeTaskInto", [self.taskId, target]) }) { _ in onGone(target) }
    }

    func convert(toSubtaskOf parent: String, onGone: @escaping (String?) -> Void) {
        moreDo("Convert to subtask", { await self.call("convertToSubtask", [self.taskId, parent]) }) { _ in onGone(parent) }
    }

    func syncDates(_ on: Bool) {
        moreDo("Sync dates", { await self.call("setSyncSubtaskDates", [self.taskId, on]) }) { r in
            if let due = r["dueDate"] as? String {
                self.patch(["startDate": (r["startDate"] as? String) ?? self.task.startDate, "dueDate": due])
            }
        }
    }

    func setTypeFromMenu(_ type: String) {
        guard let prev = extras?.taskType else { return }
        extras?.taskType = type
        Task {
            if !(await write("setTaskType", [taskId, type], label: "Task type")) { extras?.taskType = prev }
        }
    }

    func setLabelColor(_ label: String, _ color: String) {
        moreDo("Tag colour") { await self.call("setLabelColor", [label, color]) }
    }

    func deleteLabelEverywhere(_ label: String) {
        moreDo("Delete tag", { await self.call("deleteLabelEverywhere", [label]) }) { _ in
            self.extras?.labels.removeAll { $0.lowercased() == label.lowercased() }
        }
    }

    func openDescriptionHistory() {
        historyOpen = true
        versions = nil
        Task {
            switch await call("fetchDescriptionHistory", [taskId]) {
            case .success(let r): versions = (r["versions"] as? [Any] ?? []).compactMap(CrmDecode.version)
            case .failure(let problem):
                historyOpen = false
                error = "Description history: \(problem.message)"
            }
        }
    }

}
