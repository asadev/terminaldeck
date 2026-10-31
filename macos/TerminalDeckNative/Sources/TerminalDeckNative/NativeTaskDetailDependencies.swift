import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Dependencies

    func addDependency(_ kind: DependencyKind, otherId: String, otherTitle: String) {
        let dep = TaskDependency(kind: kind, otherTaskId: otherId, otherTitle: otherTitle, otherDone: false)
        guard dependencies?.contains(where: { $0.id == dep.id }) == false else { return }
        dependencies = (dependencies ?? []) + [dep]
        Task {
            if !(await write("addTaskDependency", [taskId, otherId, kind.rawValue], label: "Linking \(q(otherTitle))")) {
                dependencies?.removeAll { $0.id == dep.id }
            }
        }
    }

    func removeDependency(_ dep: TaskDependency) {
        let before = dependencies
        dependencies?.removeAll { $0.id == dep.id }
        Task {
            if !(await write("removeTaskDependency", [taskId, dep.otherTaskId, dep.kind.rawValue], label: "Unlinking \(q(dep.otherTitle))")) {
                dependencies = before
            }
        }
    }

}
