import Foundation

// The main Tasks list as one page of every task (Asad, 13 Oct: "only the main page where we see all
// the tasks"). On All projects each project is a section with the chosen grouping inside it, so a
// project's work still reads by status. A child task (a TAG hand-off) sits under its parent when
// both are in the list, folded or open as the Subtasks setting says. Pure rules; the view draws them.

/// Whether child tasks start folded under their parent or open.
public enum SubtaskDisplay: String, Equatable, Sendable, CaseIterable {
    case collapsed, expanded

    public var label: String {
        switch self {
        case .collapsed: "Collapsed"
        case .expanded: "Expanded"
        }
    }
}

/// The order within each group. Default keeps the existing due-date and Today order.
public enum TasksListSort: String, CaseIterable, Sendable {
    case automatic, dueDate, priority, name, created
    public var label: String {
        switch self { case .automatic: "Default"; case .dueDate: "Due date"; case .priority: "Priority"; case .name: "Name"; case .created: "Date created" }
    }
    private func precedes(title a: String, due ad: String?, priority ap: String?, created ac: Double,
                          title b: String, due bd: String?, priority bp: String?, created bc: Double) -> Bool? {
        switch self {
        case .automatic: return nil
        case .dueDate:
            if ad != bd { return (ad ?? "9999-99-99") < (bd ?? "9999-99-99") }
        case .priority:
            let left = TaskList.priorityOrder.firstIndex(of: ap) ?? 4
            let right = TaskList.priorityOrder.firstIndex(of: bp) ?? 4
            if left != right { return left < right }
        case .name:
            let order = a.localizedCaseInsensitiveCompare(b)
            if order != .orderedSame { return order == .orderedAscending }
        case .created:
            if ac != bc { return ac < bc }
        }
        return nil
    }
    public func ordered(_ rows: [TaskRow]) -> [TaskRow] {
        rows.enumerated().sorted { a, b in
            precedes(title: a.element.title, due: a.element.dueDate, priority: a.element.priority, created: a.element.createdAt,
                     title: b.element.title, due: b.element.dueDate, priority: b.element.priority, created: b.element.createdAt) ?? (a.offset < b.offset)
        }.map(\.element)
    }
    /// Same order for tasks_list, after access and project filtering.
    public func ordered(_ rows: [NativeRPCValue]) -> [NativeRPCValue] {
        rows.enumerated().sorted { a, b in
            precedes(title: a.element["title"].string ?? "", due: a.element["dueDate"].string, priority: a.element["priority"].string, created: a.element["createdAt"].number ?? 0,
                     title: b.element["title"].string ?? "", due: b.element["dueDate"].string, priority: b.element["priority"].string, created: b.element["createdAt"].number ?? 0) ?? (a.offset < b.offset)
        }.map(\.element)
    }
}

/// One project's part of the list; `label` is nil when the list is one project only.
public struct TaskListSection: Equatable, Sendable, Identifiable {
    public var key: String
    public var label: String?
    public var count: Int
    public var groups: [ListGroup]
    public var id: String { key }

    public init(key: String, label: String?, count: Int, groups: [ListGroup]) {
        self.key = key
        self.label = label
        self.count = count
        self.groups = groups
    }
}

/// A drawn line of a group: a task, how deep it sits, and its children's fold.
public struct TaskListLine: Equatable, Sendable, Identifiable {
    public var task: TaskRow
    public var depth: Int
    public var childCount: Int
    public var open: Bool
    public var id: String { task.id }
}

/// Which tasks are someone's child here, and each parent's children in the order they were made.
public struct TaskNesting: Equatable, Sendable {
    public var children: [String: [TaskRow]] = [:]
    public var nested: Set<String> = []

    public init(children: [String: [TaskRow]] = [:], nested: Set<String> = []) {
        self.children = children
        self.nested = nested
    }
}

public enum TasksAllList {
    /// Deepest a child is drawn; anything deeper stays at that indent.
    public static let maxDepth = 4

    /// The list's sections. All projects: one section per project (its name and task count), the chosen
    /// grouping inside it, every group carrying the project so "+ Add Task" lands there. One project, or
    /// grouping by project: a single unnamed section, exactly the groups the list had before.
    public static func sections(_ tasks: [TaskRow], allProjects: Bool, projects: [PROJProject], by: ListGroupBy,
                                today: String, showClosed: Bool, assigneeName: (String) -> String,
                                nowHm: String? = nil) -> [TaskListSection] {
        if !allProjects {
            let groups = TaskList.group(tasks, by: by, today: today, showClosed: showClosed,
                                        assigneeName: assigneeName, nowHm: nowHm)
            return groups.isEmpty ? [] : [TaskListSection(key: "all", label: nil, count: tasks.count, groups: groups)]
        }
        if by == .project || by == .none {
            let groups = TaskProjects.groups(tasks, projects: projects, showClosed: showClosed)
            return groups.isEmpty ? [] : [TaskListSection(key: "all", label: nil, count: tasks.count, groups: groups)]
        }
        // Every task of a project, closed ones too: the inner grouping folds Done as it always has.
        let buckets = TaskProjects.groups(tasks, projects: projects, showClosed: true)
        return buckets.compactMap { bucket in
            let inner = TaskList.group(bucket.items, by: by, today: today, showClosed: showClosed,
                                       assigneeName: assigneeName, nowHm: nowHm)
            guard !inner.isEmpty else { return nil }
            let groups = inner.map { group -> ListGroup in
                var placed = group
                placed.key = "\(bucket.key)|\(group.key)"
                var defaults = group.defaults ?? GroupDefaults()
                defaults.project = bucket.defaults?.project
                defaults.projectID = bucket.defaults?.projectID
                placed.defaults = defaults
                return placed
            }
            return TaskListSection(key: bucket.key, label: bucket.label, count: bucket.items.count, groups: groups)
        }
    }

    /// Children whose parent is in the same list. A loop of parents nests nobody, so no task can vanish.
    public static func nesting(_ shown: [TaskRow]) -> TaskNesting {
        var byID: [String: TaskRow] = [:]
        var byExternal: [String: TaskRow] = [:]
        for task in shown {
            if byID[task.id] == nil { byID[task.id] = task }
            if !task.externalTaskId.isEmpty {
                let key = "\(task.keyId)\u{1}\(task.externalTaskId)"
                if byExternal[key] == nil { byExternal[key] = task }
            }
        }
        // The same rule as TAGAgentSettings.parent: the stored parent id wins; else the CRM's own id.
        func parent(_ task: TaskRow) -> TaskRow? {
            let found: TaskRow?
            if let id = task.parentTaskId { found = byID[id] }
            else if let external = task.parentExternalTaskId { found = byExternal["\(task.keyId)\u{1}\(external)"] }
            else { found = nil }
            return found?.id == task.id ? nil : found
        }
        func loops(_ task: TaskRow) -> Bool {
            var seen: Set<String> = [task.id]
            var current = task
            while let up = parent(current) {
                if seen.contains(up.id) { return true }
                seen.insert(up.id)
                current = up
            }
            return false
        }
        var out = TaskNesting()
        for task in shown {
            guard let up = parent(task), !loops(task) else { continue }
            out.children[up.id, default: []].append(task)
            out.nested.insert(task.id)
        }
        for (id, kids) in out.children {
            out.children[id] = kids.sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        }
        return out
    }

    /// A group's lines: its own tasks that are nobody's child here, each followed by its children
    /// when that parent is open.
    public static func lines(_ items: [TaskRow], nesting: TaskNesting, isOpen: (String) -> Bool) -> [TaskListLine] {
        var out: [TaskListLine] = []
        var drawn: Set<String> = []
        func add(_ task: TaskRow, depth: Int) {
            guard !drawn.contains(task.id) else { return }
            drawn.insert(task.id)
            let kids = nesting.children[task.id] ?? []
            let open = !kids.isEmpty && isOpen(task.id)
            out.append(TaskListLine(task: task, depth: min(depth, maxDepth), childCount: kids.count, open: open))
            if open { for kid in kids { add(kid, depth: depth + 1) } }
        }
        for task in items where !nesting.nested.contains(task.id) { add(task, depth: 0) }
        return out
    }
}
