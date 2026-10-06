import Foundation

// How you left the task list (MyWork.tsx `ViewState`, `readView`): which view, the
// grouping, closed tasks shown or not, the columns and the filters — kept as the page
// kept it, the same JSON under the same key, so a view left in either is read back.

public enum TasksTab: String, Equatable, Sendable, CaseIterable {
    case table, board, calendar

    public var label: String {
        switch self {
        case .table: "Table"
        case .board: "Board"
        case .calendar: "Calendar"
        }
    }
}

public struct TasksColumns: Equatable, Sendable {
    public var assignee = true
    public var due = true
    public var priority = true
    public var created = false
    public var project = true
    public var goal = true

    public init() {}

    /// In the page's order, with the label each checkbox shows.
    public static var all: [(key: WritableKeyPath<TasksColumns, Bool>, name: String, label: String)] {
        [(\.assignee, "assignee", "Assignee"), (\.due, "due", "Due date"), (\.priority, "priority", "Priority"),
         (\.created, "created", "Date created"), (\.project, "project", "Project"), (\.goal, "goal", "Goal")]
    }
}

public struct TasksViewState: Equatable, Sendable {
    public var tab: TasksTab = .table
    public var groupBy: ListGroupBy = .status
    public var showClosed = false
    public var columns = TasksColumns()
    public var filters = ListFilters()

    public init() {}

    /// The key the page keeps it under, in its own storage.
    public static let storageKey = "td.tasks.viewState.v1"

    /// Read back from its JSON; anything unknown takes the default.
    public static func read(_ raw: Any?) -> TasksViewState {
        var view = TasksViewState()
        guard let r = raw as? [String: Any] else { return view }
        if let tab = (r["tab"] as? String).flatMap(TasksTab.init(rawValue:)), tab != .table { view.tab = tab }
        if let by = (r["groupBy"] as? String).flatMap(ListGroupBy.init(rawValue:)) { view.groupBy = by }
        view.showClosed = TasksJSON.isTrue(r["showClosed"])
        if let columns = r["columns"] as? [String: Any] {
            for column in TasksColumns.all {
                if let on = TasksJSON.bool(columns[column.name]) { view.columns[keyPath: column.key] = on }
            }
        }
        if let f = r["filters"] as? [String: Any] {
            if let pile = (f["pile"] as? String).flatMap(Pile.init(rawValue:)) { view.filters.pile = pile }
            if let search = f["search"] as? String { view.filters.search = search }
            if f["statuses"] is [Any] { view.filters.statuses = TasksJSON.strings(f["statuses"]) }
            if f["priorities"] is [Any] { view.filters.priorities = TasksJSON.strings(f["priorities"]) }
            if f["boards"] is [Any] { view.filters.boards = TasksJSON.strings(f["boards"]) }
            if let due = (f["due"] as? String).flatMap(DueFilter.init(rawValue:)) { view.filters.due = due }
            if let archived = TasksJSON.bool(f["archived"]) { view.filters.archived = archived }
        }
        return view
    }

    /// Its JSON, as the page writes it.
    public var json: [String: Any] {
        var columnsOut: [String: Any] = [:]
        for column in TasksColumns.all { columnsOut[column.name] = columns[keyPath: column.key] }
        return [
            "tab": tab.rawValue, "groupBy": groupBy.rawValue, "showClosed": showClosed, "columns": columnsOut,
            "filters": [
                "pile": filters.pile.rawValue, "search": filters.search, "statuses": filters.statuses,
                "priorities": filters.priorities, "boards": filters.boards, "due": filters.due.rawValue,
                "archived": filters.archived,
            ] as [String: Any],
        ]
    }
}

/// The tasks you starred (page-header.tsx `readFavorites`): ids, in a JSON list.
public enum TaskFavorites {
    public static let storageKey = "td.tasks.favorites.v1"

    /// Strings only, at most 500, as the page reads them.
    public static func read(_ raw: Any?) -> [String] { Array(TasksJSON.strings(raw).prefix(500)) }

    /// Starred, or no longer.
    public static func toggled(_ ids: [String], _ id: String) -> [String] {
        ids.contains(id) ? ids.filter { $0 != id } : ids + [id]
    }
}
