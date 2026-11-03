import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Time

    /// Every call answers with the rows to show, or its reason.
    func timeStart() async -> String? {
        switch await call("startTaskTimer", [taskId]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            if let entry = CrmDecode.timeEntry(r["entry"]) {
                extras?.timeEntries.removeAll { $0.userId == me && $0.endedAt == nil }
                extras?.timeEntries.append(entry)
            }
            refreshActivity()
            return nil
        }
    }

    func timeStop() async -> String? {
        switch await call("stopTaskTimer", [taskId]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            if let done = CrmDecode.timeEntry(r["entry"]), let i = extras?.timeEntries.firstIndex(where: { $0.id == done.id }) {
                extras?.timeEntries[i] = done
            }
            refreshActivity()
            return nil
        }
    }

    func timeAdd(seconds: Double, date: String, note: String, billable: Bool, tags: [String]) async -> String? {
        let input: [String: Any] = ["seconds": seconds, "date": date, "note": note, "billable": billable, "tags": tags]
        switch await call("addTaskTimeEntry", [taskId, input]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            guard let entry = CrmDecode.timeEntry(r["entry"]) else { return nil }
            extras?.timeEntries.append(entry)
            if !tags.isEmpty {
                switch await call("setTimeEntryTags", [taskId, entry.id, tags]) {
                case .success(let t): more?.entryTags[entry.id] = TasksJSON.strings(t["tags"])
                case .failure(let problem): error = "Time tags: \(problem.message)"
                }
            }
            refreshActivity()
            return nil
        }
    }

    func timeDelete(_ entryId: String) async -> String? {
        switch await call("deleteTaskTimeEntry", [taskId, entryId]) {
        case .failure(let problem): return problem.message
        case .success:
            extras?.timeEntries.removeAll { $0.id == entryId }
            return nil
        }
    }

    func timeEstimate(_ minutes: Double?) async -> String? {
        switch await call("setTimeEstimate", [taskId, minutes ?? NSNull()]) {
        case .failure(let problem): return problem.message
        case .success:
            extras?.estimateMinutes = minutes
            refreshActivity()
            return nil
        }
    }

}
