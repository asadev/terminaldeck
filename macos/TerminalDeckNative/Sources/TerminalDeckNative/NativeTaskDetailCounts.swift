import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import TerminalDeckBackend
import TerminalDeckNativeCore

extension TaskDetailModel {
    // MARK: Counts for the top row

    var forMe: Int {
        guard let people else { return 0 }
        let subs = (subtasks ?? []).filter { !$0.done && people.assignee(for: $0.assigneeUserId).person?.id == me }.count
        let items = (checklists ?? []).flatMap(\.items).filter { !$0.done && people.assignee(for: $0.assigneeUserId).person?.id == me }.count
        return subs + items
    }

    /// Nobody but the viewer on it: the breadcrumb's 🔒.
    var personal: Bool {
        guard let people else { return false }
        let list = people.list
        return list.isEmpty || (list.count == 1 && list[0].id == me)
    }
}
