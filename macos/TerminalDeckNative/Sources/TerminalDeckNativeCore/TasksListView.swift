import Foundation

// The task list's pure rules (src/renderer/tasks/list-view.ts), ported from a CRM's
// My Work list: the grouping options, the due buckets, the row's relative dates, the
// fold of closed tasks, the filters and piles, and the week. Days are this Mac's own
// calendar.

public enum ListGroupBy: String, Equatable, Sendable, CaseIterable {
    case none, status, assignee, priority, tags, due, type, board, project

    public var label: String {
        switch self {
        case .none: "None"
        case .status: "Status"
        case .assignee: "Assignee"
        case .priority: "Priority"
        case .tags: "Tags"
        case .due: "Due date"
        case .type: "Task type"
        case .board: "Board"
        case .project: "Project"
        }
    }
}

/// What a "+ Add task" under a group pre-fills, so the new task lands in that group.
/// A key present with a nil value means "set it to nothing" (e.g. no due date).
public struct GroupDefaults: Equatable, Sendable {
    public var status: String?
    public var priority: String??
    public var dueDate: String??
    public var assignee: String?
    public var board: String??
    /// The project folder a task added under this group gets ("" for none) — "All projects" (lane TK).
    public var project: String?

    public init(status: String? = nil, priority: String?? = nil, dueDate: String?? = nil, assignee: String? = nil,
                board: String?? = nil, project: String? = nil) {
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.assignee = assignee
        self.board = board
        self.project = project
    }

    /// As the create call takes it (absent keys left out, nil sent as null).
    public var wire: [String: Any] {
        var out: [String: Any] = [:]
        if let status { out["status"] = status }
        if let priority { out["priority"] = priority ?? jsonNull }
        if let dueDate { out["dueDate"] = dueDate ?? jsonNull }
        if let assignee { out["assignee"] = assignee }
        if let board { out["board"] = board ?? jsonNull }
        if let project { out["project"] = project }
        return out
    }
}

public struct ListGroup: Equatable, Sendable, Identifiable {
    public enum Accent: String, Sendable { case overdue, today }
    public var key: String
    public var label: String
    public var accent: Accent?
    public var items: [TaskRow]
    public var defaults: GroupDefaults?
    /// Starts collapsed: the closed tasks' group.
    public var folded: Bool
    public var id: String { key }
}

public enum DueBucket: String, Sendable, CaseIterable {
    case overdue = "Overdue", today = "Today", next = "Next", later = "Later", unscheduled = "Unscheduled"
}

/// Everything, yours, your agents', nobody's, and the ones you starred.
public enum Pile: String, Equatable, Sendable, CaseIterable {
    case all, mine, agents, unassigned, favorites

    public var label: String {
        switch self {
        case .all: "All tasks"
        case .mine: "Assigned to me"
        case .agents: "With Hoot and agents"
        case .unassigned: "Unassigned"
        case .favorites: "Favorites"
        }
    }
}

public enum DueFilter: String, Equatable, Sendable, CaseIterable {
    case any, overdue, today, week, none

    public var label: String {
        switch self {
        case .any: "Any time"
        case .overdue: "Overdue"
        case .today: "Due today"
        case .week: "Next 7 days"
        case .none: "No due date"
        }
    }
}

public struct ListFilters: Equatable, Sendable {
    public var pile: Pile = .all
    public var search = ""
    public var statuses: [String] = []
    /// `none` stands for "no priority".
    public var priorities: [String] = []
    /// `none` stands for "no board".
    public var boards: [String] = []
    public var due: DueFilter = .any
    public var archived = false

    public init() {}

    /// Anything but the archived switch narrows the list.
    public var narrows: Bool {
        !statuses.isEmpty || !priorities.isEmpty || !boards.isEmpty || due != .any || !search.isEmpty || pile != .all
    }
}

public enum TaskList {
    public static let statusOrder = ["To-Do", "Working on it", "In Progress", "Stuck", "Done"]
    public static let priorityOrder: [String?] = ["Critical", "High", "Medium", "Low", nil]
    public static let priorities = ["Critical", "High", "Medium", "Low"]
    public static let monthShort = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    /// The one group you can drag to reorder: Today, in your own order.
    public static let reorderableGroupKey = "due:Today"

    // MARK: Days

    public static func isYmd(_ value: String?) -> Bool {
        guard let value, value.count == 10 else { return false }
        let chars = Array(value)
        for (i, c) in chars.enumerated() {
            if i == 4 || i == 7 { if c != "-" { return false } } else if !c.isASCII || !c.isNumber { return false }
        }
        return true
    }

    /// This Mac's calendar date for an instant (ms), "YYYY-MM-DD".
    public static func ymdOf(_ at: Double, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: at / 1000))
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// "HH:MM" on this Mac's clock.
    public static func hmOf(_ at: Double, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: at / 1000))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func parts(_ ymd: String) -> (y: Int, m: Int, d: Int) {
        let p = ymd.split(separator: "-").map { Int($0) ?? 0 }
        return (p.count > 0 ? p[0] : 0, p.count > 1 ? p[1] : 1, p.count > 2 ? p[2] : 1)
    }

    static func dayNumber(_ ymd: String) -> Int {
        let p = parts(ymd)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: p.y, month: p.m, day: p.d)) ?? Date(timeIntervalSince1970: 0)
        return Int((date.timeIntervalSince1970 / 86_400).rounded())
    }

    static func ymdOfDay(_ day: Int) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(day) * 86_400))
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// Whole days from `a` to `b`.
    public static func ymdDiff(_ a: String, _ b: String) -> Int { dayNumber(b) - dayNumber(a) }

    public static func ymdAddDays(_ ymd: String, _ days: Int) -> String { ymdOfDay(dayNumber(ymd) + days) }

    /// 0 = Sunday.
    public static func ymdWeekday(_ ymd: String) -> Int {
        // 1970-01-01 was a Thursday.
        ((dayNumber(ymd) % 7) + 7 + 4) % 7
    }

    /// The due cell: "Today" · "Tomorrow" · "Yesterday" · "15 Sep" (· 2027 when not this year).
    public static func relativeDue(_ ymd: String?, today: String) -> String {
        guard let ymd, isYmd(ymd), isYmd(today) else { return "" }
        let delta = ymdDiff(today, ymd)
        if delta == 0 { return "Today" }
        if delta == 1 { return "Tomorrow" }
        if delta == -1 { return "Yesterday" }
        let p = parts(ymd)
        let label = "\(p.d) \(monthShort[max(0, min(11, p.m - 1))])"
        return p.y == parts(today).y ? label : "\(label) \(p.y)"
    }

    /// Due today at a time that has come — the row's red due cell.
    public static func isDueTimePassed(_ dueDate: String?, _ dueTime: String?, today: String, nowHm: String?) -> Bool {
        guard let nowHm, !nowHm.isEmpty, let dueTime, !dueTime.isEmpty else { return false }
        return dueDate == today && dueTime <= nowHm
    }

    public static func isOverdue(_ task: TaskRow, today: String, nowHm: String?) -> Bool {
        guard task.crmStatus != "Done", let due = task.dueDate, isYmd(due) else { return false }
        return due < today || isDueTimePassed(due, task.dueTime, today: today, nowHm: nowHm)
    }

    /// "Date created": "Today" · "Yesterday" · "Sep 12" · "Sep 12, 2025".
    public static func createdLabel(_ at: Double, today: String) -> String {
        let ymd = ymdOf(at)
        let delta = ymdDiff(today, ymd)
        if delta == 0 { return "Today" }
        if delta == -1 { return "Yesterday" }
        let p = parts(ymd)
        let label = "\(monthShort[max(0, min(11, p.m - 1))]) \(p.d)"
        return p.y == parts(today).y ? label : "\(label), \(p.y)"
    }

    public static func dueBucket(_ dueDate: String?, today: String, dueTime: String? = nil, nowHm: String? = nil) -> DueBucket {
        guard let dueDate, isYmd(dueDate) else { return .unscheduled }
        if dueDate < today { return .overdue }
        if dueDate == today {
            return isDueTimePassed(dueDate, dueTime, today: today, nowHm: nowHm) ? .overdue : .today
        }
        let dow = (ymdWeekday(today) + 6) % 7 // Monday = 0
        return dueDate <= ymdAddDays(today, 13 - dow) ? .next : .later
    }

    /// Placed tasks first, lowest position on top; the rest keep the order they came in.
    public static func sortByPosition(_ items: [TaskRow]) -> [TaskRow] {
        let placed = items.filter { $0.position != nil }.enumerated()
            .sorted { ($0.element.position!, $0.offset) < ($1.element.position!, $1.offset) }.map(\.element)
        return placed + items.filter { $0.position == nil }
    }

    /// A drag in a filtered list moves only what you can see: the visible tasks swap
    /// among the slots they already held, so a hidden task keeps its place.
    public static func reorderWithinSlots(_ fullIds: [String], _ newVisibleIds: [String]) -> [String] {
        let inFull = Set(fullIds)
        let queue = newVisibleIds.filter { inFull.contains($0) }
        let moving = Set(queue)
        var next = 0
        return fullIds.map { id in
            guard moving.contains(id) else { return id }
            defer { next += 1 }
            return queue[next]
        }
    }

    /// Due date ascending, no date last — the order the CRM's server lists them in.
    static func byDue(_ a: TaskRow, _ b: TaskRow) -> Bool {
        let ad = a.dueDate ?? "9999-99-99", bd = b.dueDate ?? "9999-99-99"
        if ad != bd { return ad < bd }
        return (a.dueTime ?? "99:99") < (b.dueTime ?? "99:99")
    }

    static func stableSorted(_ tasks: [TaskRow], by less: (TaskRow, TaskRow) -> Bool) -> [TaskRow] {
        tasks.enumerated().sorted { l, r in
            if less(l.element, r.element) { return true }
            if less(r.element, l.element) { return false }
            return l.offset < r.offset
        }.map(\.element)
    }

    /// The last part of a folder path.
    static func folderName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// The list, grouped. Done tasks are pulled into one folded "Done" group at the
    /// bottom unless `showClosed` puts them back; grouped by Status, Done is its own
    /// group, folded the same way. Empty groups are left out.
    public static func group(_ tasks: [TaskRow], by: ListGroupBy, today: String, showClosed: Bool,
                             assigneeName: (String) -> String, nowHm: String? = nil) -> [ListGroup] {
        let sorted = stableSorted(tasks, by: byDue)
        let closed = sorted.filter { $0.crmStatus == "Done" }
        let pool = showClosed || by == .status ? sorted : sorted.filter { $0.crmStatus != "Done" }
        var groups: [ListGroup] = []
        func push(_ key: String, _ label: String, _ items: [TaskRow], accent: ListGroup.Accent? = nil,
                  defaults: GroupDefaults? = nil, folded: Bool = false) {
            if !items.isEmpty {
                groups.append(ListGroup(key: key, label: label, accent: accent, items: items, defaults: defaults, folded: folded))
            }
        }
        switch by {
        case .none:
            push("all", "\(pool.count) \(pool.count == 1 ? "Task" : "Tasks")", pool)
        case .status:
            for status in statusOrder {
                push("status:\(status)", status, pool.filter { $0.crmStatus == status },
                     defaults: GroupDefaults(status: status), folded: status == "Done" && !showClosed)
            }
        case .assignee:
            var ids: [String] = []
            for task in pool where !ids.contains(task.assignee) { ids.append(task.assignee) }
            ids.sort { a, b in
                if a == "none" { return false }
                if b == "none" { return true }
                return assigneeName(a).localizedCompare(assigneeName(b)) == .orderedAscending
            }
            for id in ids {
                push("assignee:\(id)", assigneeName(id), pool.filter { $0.assignee == id }, defaults: GroupDefaults(assignee: id))
            }
        case .priority:
            for priority in priorityOrder {
                push("priority:\(priority ?? "none")", priority ?? "No priority", pool.filter { $0.priority == priority },
                     defaults: GroupDefaults(priority: .some(priority)))
            }
        case .tags:
            // A task with two tags sits in both groups.
            var all: [String] = []
            for label in pool.flatMap(\.labels) where !all.contains(label) { all.append(label) }
            all.sort { $0.localizedCompare($1) == .orderedAscending }
            for label in all { push("tag:\(label)", label, pool.filter { $0.labels.contains(label) }) }
            push("tag:none", "No tags", pool.filter { $0.labels.isEmpty })
        case .due:
            for bucket in DueBucket.allCases {
                let inBucket = pool.filter { dueBucket($0.dueDate, today: today, dueTime: $0.dueTime, nowHm: nowHm) == bucket }
                let key = "due:\(bucket.rawValue)"
                push(key, bucket.rawValue, key == reorderableGroupKey ? sortByPosition(inBucket) : inBucket,
                     accent: bucket == .overdue ? .overdue : bucket == .today ? .today : nil,
                     defaults: bucket == .today ? GroupDefaults(dueDate: .some(today))
                         : bucket == .unscheduled ? GroupDefaults(dueDate: .some(nil)) : nil)
            }
        case .type:
            push("type:task", "Task", pool.filter { $0.taskType != "milestone" })
            push("type:milestone", "Milestone", pool.filter { $0.taskType == "milestone" })
        case .board:
            var boards: [String] = []
            for task in pool where !boards.contains(task.board ?? "") { boards.append(task.board ?? "") }
            boards.sort { a, b in a.isEmpty ? false : b.isEmpty ? true : a.localizedCompare(b) == .orderedAscending }
            for board in boards {
                push("board:\(board.isEmpty ? "none" : board)", board.isEmpty ? "No board" : board,
                     pool.filter { ($0.board ?? "") == board }, defaults: GroupDefaults(board: .some(board.isEmpty ? nil : board)))
            }
        case .project:
            var projects: [String] = []
            for task in pool where !projects.contains(task.project) { projects.append(task.project) }
            projects.sort { a, b in a.isEmpty ? false : b.isEmpty ? true : a.localizedCompare(b) == .orderedAscending }
            for project in projects {
                push("project:\(project.isEmpty ? "none" : project)", project.isEmpty ? "No project" : folderName(project),
                     pool.filter { $0.project == project })
            }
        }
        if !showClosed && by != .status {
            push("__closed", "Done", closed, defaults: GroupDefaults(status: "Done"), folded: true)
        }
        return groups
    }

    // MARK: Filters

    public static func filter(_ tasks: [TaskRow], _ filters: ListFilters, today: String, nowHm: String?,
                              favorites: Set<String> = []) -> [TaskRow] {
        let search = filters.search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tasks.filter { task in
            if (task.archivedAt != nil) != filters.archived { return false }
            if filters.pile == .favorites && !favorites.contains(task.id) { return false }
            if filters.pile == .mine && task.assignee != "me" { return false }
            if filters.pile == .agents && (task.assignee == "me" || task.assignee == "none") { return false }
            if filters.pile == .unassigned && task.assignee != "none" { return false }
            if !filters.statuses.isEmpty && !filters.statuses.contains(task.crmStatus) { return false }
            if !filters.priorities.isEmpty && !filters.priorities.contains(task.priority ?? "none") { return false }
            if !filters.boards.isEmpty && !filters.boards.contains(task.board ?? "none") { return false }
            if filters.due == .overdue && !isOverdue(task, today: today, nowHm: nowHm) { return false }
            if filters.due == .today && task.dueDate != today { return false }
            if filters.due == .week {
                guard let due = task.dueDate, isYmd(due), due >= today, due <= ymdAddDays(today, 7) else { return false }
            }
            if filters.due == .none && task.dueDate != nil { return false }
            if !search.isEmpty {
                let hay = "\(task.title) \(task.board ?? "") \(task.project) \(task.labels.joined(separator: " "))".lowercased()
                if !hay.contains(search) { return false }
            }
            return true
        }
    }

    /// The summary tiles: open, overdue, due today, done.
    public static func summary(_ tasks: [TaskRow], today: String, nowHm: String?) -> (open: Int, overdue: Int, today: Int, done: Int) {
        let live = tasks.filter { $0.archivedAt == nil }
        return (live.filter { $0.crmStatus != "Done" }.count,
                live.filter { isOverdue($0, today: today, nowHm: nowHm) }.count,
                live.filter { $0.crmStatus != "Done" && $0.dueDate == today }.count,
                live.filter { $0.crmStatus == "Done" }.count)
    }

    /// The status the ▸ arrow moves to: To-Do → Working on it → In Progress → Done;
    /// Stuck → In Progress; Done has none.
    public static func nextStatus(_ status: String) -> String? {
        switch status {
        case "To-Do": "Working on it"
        case "Working on it": "In Progress"
        case "In Progress": "Done"
        case "Stuck": "In Progress"
        default: nil
        }
    }

    /// The Monday-to-Sunday week holding `ymd`.
    public static func weekOf(_ ymd: String) -> [String] {
        let monday = ymdAddDays(ymd, -((ymdWeekday(ymd) + 6) % 7))
        return (0..<7).map { ymdAddDays(monday, $0) }
    }

    /// The tone a status ring and pill are drawn in.
    public static func statusTone(_ status: String) -> String {
        switch status {
        case "Done": "done"
        case "Stuck": "stuck"
        case "In Progress": "progress"
        case "Working on it": "working"
        default: "todo"
        }
    }

    /// Adds or removes one value.
    public static func toggled(_ list: [String], _ value: String) -> [String] {
        list.contains(value) ? list.filter { $0 != value } : list + [value]
    }
}
