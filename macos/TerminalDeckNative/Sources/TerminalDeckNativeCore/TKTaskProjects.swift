import Foundation

// Tasks by project (lane TK, 7 Oct 2026). Every task belongs to the project folder
// it was made in (its `project`; "" for none, which is also what an old record
// without the field reads as). The Tasks screen shows the current project's tasks,
// or every project's grouped under each project's name. Pure rules only: the screen
// supplies the current project and the open projects from the sidebar.

/// What the Tasks screen shows: the current project's tasks, or every project's.
public enum TaskProjectScope: String, Equatable, Sendable, CaseIterable {
    case this, all

    public var label: String { self == .this ? "This project" : "All projects" }

    /// Where the choice is kept on this Mac.
    public static let storageKey = "td.tasks.projectScope"
}

/// An open project, as the sidebar's "Open" section lists it.
public struct TaskProject: Equatable, Sendable, Identifiable {
    /// The project's folder path.
    public let path: String
    public let title: String
    public var id: String { path }

    public init(path: String, title: String) {
        self.path = path
        self.title = title
    }
}

public enum TaskProjects {
    /// The heading for tasks with no project folder.
    public static let noProject = "No project"

    /// A folder path as compared here: trimmed, without a trailing slash.
    public static func clean(_ path: String) -> String {
        var out = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// The folder is the project folder itself or inside it.
    public static func within(_ folder: String, _ project: String) -> Bool {
        let folder = clean(folder), project = clean(project)
        guard !folder.isEmpty, !project.isEmpty else { return false }
        return folder == project || folder.hasPrefix(project == "/" ? "/" : project + "/")
    }

    /// The open project a folder belongs to: the deepest open project holding it.
    public static func owner(of folder: String, among open: [TaskProject]) -> TaskProject? {
        open.filter { within(folder, $0.path) }.max { clean($0.path).count < clean($1.path).count }
    }

    /// Does a task in this folder show under this project? It does when the folder
    /// is inside the project and not inside a deeper open project of its own.
    public static func belongs(_ folder: String, to project: String, among open: [TaskProject]) -> Bool {
        guard within(folder, project) else { return false }
        let all = open.contains { clean($0.path) == clean(project) } ? open : open + [TaskProject(path: project, title: "")]
        return owner(of: folder, among: all).map { clean($0.path) == clean(project) } ?? false
    }

    /// "This project" needs a current project; with none, everything shows.
    public static func effective(_ scope: TaskProjectScope, current: String?) -> TaskProjectScope {
        guard let current, !clean(current).isEmpty else { return .all }
        return scope
    }

    /// A project's name: the sidebar's title for an open one, else its folder's name.
    public static func name(of path: String, among open: [TaskProject]) -> String {
        let path = clean(path)
        if path.isEmpty { return noProject }
        if let match = open.first(where: { clean($0.path) == path }), !match.title.isEmpty { return match.title }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The state the Tasks screen draws. In "This project" only the current project's
    /// tasks and Trash show, and only goals that are that project's or have no project.
    public static func scoped(_ state: TasksState, scope: TaskProjectScope, current: String?, open: [TaskProject]) -> TasksState {
        guard effective(scope, current: current) == .this, let current else { return state }
        var out = state
        out.tasks = state.tasks.filter { belongs($0.project, to: current, among: open) }
        out.trash = state.trash.filter { belongs($0.project, to: current, among: open) }
        out.goals = state.goals.filter { goal in
            guard let project = goal.project, !clean(project).isEmpty else { return true }
            return belongs(project, to: current, among: open)
        }
        return out
    }

    /// The heading a task is listed under in "All projects": its open project's path,
    /// else its own folder, else "" (no project).
    public static func groupPath(of folder: String, among open: [TaskProject]) -> String {
        owner(of: folder, among: open).map { clean($0.path) } ?? clean(folder)
    }

    /// "All projects": one group per project — the open projects in sidebar order,
    /// then other folders by name — and "No project" last; closed tasks fold into one
    /// Done group at the bottom unless `showClosed`, as the other groupings do.
    public static func groups(_ tasks: [TaskRow], open: [TaskProject], showClosed: Bool) -> [ListGroup] {
        let sorted = TaskList.stableSorted(tasks, by: TaskList.byDue)
        let closed = sorted.filter { $0.crmStatus == "Done" }
        let pool = showClosed ? sorted : sorted.filter { $0.crmStatus != "Done" }
        var paths: [String] = []
        for task in pool {
            let path = groupPath(of: task.project, among: open)
            if !paths.contains(path) { paths.append(path) }
        }
        let openOrder = open.map { clean($0.path) }
        paths.sort { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            let ai = openOrder.firstIndex(of: a), bi = openOrder.firstIndex(of: b)
            switch (ai, bi) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return name(of: a, among: open).localizedCompare(name(of: b, among: open)) == .orderedAscending
            }
        }
        var groups: [ListGroup] = []
        for path in paths {
            let items = pool.filter { groupPath(of: $0.project, among: open) == path }
            groups.append(ListGroup(key: "project:\(path.isEmpty ? "none" : path)", label: name(of: path, among: open),
                                    accent: nil, items: items, defaults: GroupDefaults(project: path), folded: false))
        }
        if !showClosed && !closed.isEmpty {
            groups.append(ListGroup(key: "__closed", label: "Done", accent: nil, items: closed,
                                    defaults: GroupDefaults(status: "Done"), folded: true))
        }
        return groups
    }

    /// A reminder for a task was clicked: the open project the window must move to
    /// first, or nil when the task is already in the current one (or in no open project).
    public static func revealTarget(for folder: String, current: String?, open: [TaskProject]) -> String? {
        guard let owner = owner(of: folder, among: open).map({ clean($0.path) }) else { return nil }
        return owner == current.map(clean) ? nil : owner
    }

    /// Where "Move to Project" can send a task: every open project but its own.
    public static func moveTargets(for task: TaskRow, open: [TaskProject]) -> [TaskProject] {
        let own = groupPath(of: task.project, among: open)
        return open.filter { clean($0.path) != own }
    }

    /// A task can be left with no project only when no agent or Hoot works on it.
    public static func canClearProject(_ task: TaskRow) -> Bool {
        !clean(task.project).isEmpty && (task.assignee == "me" || task.assignee == "none")
    }
}
