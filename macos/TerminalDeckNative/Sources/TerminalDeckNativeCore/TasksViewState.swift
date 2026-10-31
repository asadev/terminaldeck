import Foundation

// How you left the task list (MyWork.tsx `ViewState`, `readView`): which view, the
// grouping, closed tasks shown or not, the columns and the filters — kept as the page
// kept it, the same JSON under the same key, so a view left in either is read back.

public enum TasksTab: String, Equatable, Sendable, CaseIterable {
    case table, board, calendar

    public var label: String {
        switch self {
        // The main list (13 Oct): named as the page it now is, a list of every task.
        case .table: "List"
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
    public var status = true
    public var order = ["assignee", "due", "priority", "status", "goal", "project", "created"]
    public var widths: [String: Double] = [:]

    public static let defaultWidths: [String: Double] = ["assignee": 150, "due": 104, "priority": 100, "status": 128, "goal": 132, "project": 120, "created": 92]
    public func width(_ name: String) -> Double { widths[name] ?? Self.defaultWidths[name] ?? 100 }
    public mutating func resize(_ name: String, to width: Double) {
        guard Self.defaultWidths[name] != nil, width.isFinite else { return }
        widths[name] = min(360, max(72, width))
    }
    public mutating func reorder(_ names: [String]) {
        var seen = Set<String>()
        order = (names + order).filter { Self.defaultWidths[$0] != nil && seen.insert($0).inserted }
    }

    public init() {}

    /// In the page's order, with the label each checkbox shows.
    public static var all: [(key: WritableKeyPath<TasksColumns, Bool>, name: String, label: String)] {
        [(\.assignee, "assignee", "Assignee"), (\.due, "due", "Due date"), (\.priority, "priority", "Priority"),
         (\.status, "status", "Status"), (\.created, "created", "Date created"), (\.project, "project", "Project"), (\.goal, "goal", "Goal")]
    }
}

public struct TasksViewState: Equatable, Sendable {
    public var tab: TasksTab = .table
    public var groupBy: ListGroupBy = .status
    public var showClosed = false
    /// Child tasks under their parent: folded until opened, or all open.
    public var subtasks: SubtaskDisplay = .collapsed
    public var sort: TasksListSort = .automatic
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
        if let sort = (r["sort"] as? String).flatMap(TasksListSort.init(rawValue:)) { view.sort = sort }
        view.showClosed = TasksJSON.isTrue(r["showClosed"])
        if let subtasks = (r["subtasks"] as? String).flatMap(SubtaskDisplay.init(rawValue:)) { view.subtasks = subtasks }
        if let columns = r["columns"] as? [String: Any] {
            for column in TasksColumns.all {
                if let on = TasksJSON.bool(columns[column.name]) { view.columns[keyPath: column.key] = on }
            }
        }
        if let order = r["columnOrder"] as? [String] { view.columns.reorder(order) }
        if let widths = r["columnWidths"] as? [String: Any] {
            for (name, raw) in widths { if let width = raw as? Double { view.columns.resize(name, to: width) } }
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
            "tab": tab.rawValue, "groupBy": groupBy.rawValue, "showClosed": showClosed, "subtasks": subtasks.rawValue, "sort": sort.rawValue,
            "columns": columnsOut, "columnOrder": columns.order, "columnWidths": columns.widths,
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
