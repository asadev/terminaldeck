import Foundation

/// Layout choices only. Task ownership, filtering, storage and changes stay with
/// the existing Tasks, TAG and TK models.
public enum UIGTasksSection: String, Equatable, Sendable, CaseIterable {
    case work, goals, crm

    public var label: String {
        switch self {
        case .work: "My Work"
        case .goals: "Goals"
        case .crm: "From your CRM"
        }
    }
}

public enum UIGTasksPresentation {
    /// CRM work gets a destination once there is a connection or a mirrored task.
    /// Goals stays available because it is also where the first goal is added.
    public static func sections(_ state: TasksState) -> [UIGTasksSection] {
        var result: [UIGTasksSection] = [.work, .goals]
        if !state.connections.isEmpty || state.tasks.contains(where: { !$0.local }) {
            result.append(.crm)
        }
        return result
    }

    /// Count the folded filter categories, rather than every checked choice.
    /// Search has its own visible field; grouping and columns are view settings.
    public static func filterCount(_ filters: ListFilters) -> Int {
        [filters.pile != .all, !filters.statuses.isEmpty, !filters.priorities.isEmpty,
         !filters.boards.isEmpty, filters.due != .any, filters.archived]
            .filter { $0 }.count
    }

    /// Clear the folded controls without losing the search or the chosen view.
    public static func resetFoldedFilters(_ view: TasksViewState) -> TasksViewState {
        var result = view
        result.filters = ListFilters()
        result.filters.search = view.filters.search
        return result
    }

    /// Match the existing board's statuses and the calendar's displayed days.
    /// The input is already scoped and filtered by MyWorkModel.
    public static func contentCount(_ tasks: [TaskRow], tab: TasksTab, week: [String]) -> Int {
        switch tab {
        case .table: tasks.count
        case .board: tasks.filter { TaskList.statusOrder.contains($0.crmStatus) }.count
        case .calendar:
            tasks.filter { task in task.dueDate.map { week.contains($0) } ?? false }.count
        }
    }
}
