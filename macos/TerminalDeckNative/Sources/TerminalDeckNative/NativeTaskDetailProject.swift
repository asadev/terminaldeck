import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Project folder and workspace choice (local only)

    func setProject(_ path: String) async -> String? {
        switch await call("setTaskProject", [taskId, path]) {
        case .failure(let problem): return problem.message
        case .success: return nil
        }
    }

    func chooseProject() async -> (project: String?, problem: String?) {
        switch await call("chooseTaskProject", [taskId]) {
        case .failure(let problem): return (nil, problem.message == "failed" ? nil : problem.message)
        case .success(let r): return (r["project"] as? String, nil)
        }
    }

    func setUseWorkspace(_ on: Bool) async -> String? {
        let result = await TasksStore.shared.call("tasks:local-update", [taskId, ["useWorkspace": on]])
        TasksStore.shared.adopt(result)
        return result.ok ? nil : result.message
    }

    /// The comments' read failed: its sentence.
    var commentsErrorText: String? { commentsError }
    /// The extras' read failed: its sentence.
    var extrasErrorText: String? { extrasError }
    /// Part 2's read failed: its sentence.
    var moreErrorText: String? { moreError }

}
