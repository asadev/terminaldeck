import Foundation

// Connected task systems, as the window and the MCP tools read them: the systems
// (never a token), their task rows, one opened task, and the piles and filters the
// Tasks page offers. Read field by field from the engine's answers; a malformed field
// reads as absent, never as a guess.

public struct ConnectedTaskPerson: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    init?(_ value: NativeRPCValue) {
        guard let id = value["id"].string, let name = value["name"].string else { return nil }
        self.init(id: id, name: name)
    }
}

public struct ConnectedTaskSystem: Equatable, Sendable, Identifiable {
    public enum Changes: String, Equatable, Sendable, CaseIterable {
        case ask, allow, off
        public var label: String {
            switch self {
            case .ask: "Ask each time"
            case .allow: "Send without asking"
            case .off: "Read only"
            }
        }
    }

    public var id: String
    public var name: String
    public var url: String
    public var host: String
    public var projectId: String
    public var projectIdInferred: Bool
    public var folder: String?
    public var projectID: String? { projectIdInferred ? nil : projectId }
    public var enabled: Bool
    public var changes: Changes
    public var markDone: Bool
    public var serverTitle: String?
    public var me: ConnectedTaskPerson?
    public var capabilities: [String]
    public var capabilityWords: [String]
    public var statuses: [String]
    public var doneStatus: String?
    public var tokenEnding: String?
    public var docsURL: String?
    /// Milliseconds since 1970 of the last list read; nil before the first.
    public var refreshedAt: Double?
    public var total: Int?
    public var taskCount: Int
    public var problem: String?

    public init?(_ value: NativeRPCValue) {
        guard let id = value["id"].string, let name = value["name"].string else { return nil }
        self.id = id; self.name = name
        folder = value["folder"].string ?? value["startIn"].string
        projectIdInferred = value["projectIdInferred"].bool == true || value["projectId"].string == nil
        projectId = PROJProjects.resolve(projectID: projectIdInferred ? nil : value["projectId"].string, folder: folder)
        url = value["url"].string ?? ""; host = value["host"].string ?? ""
        enabled = value["enabled"].bool != false
        changes = Changes(rawValue: value["changes"].string ?? "") ?? .ask
        markDone = value["markDone"].bool == true
        serverTitle = value["server"]["title"].string ?? value["server"]["name"].string
        me = ConnectedTaskPerson(value["me"])
        capabilities = (value["capabilities"].elements ?? []).compactMap(\.string)
        capabilityWords = (value["capabilityWords"].elements ?? []).compactMap(\.string)
        statuses = (value["statuses"].elements ?? []).compactMap(\.string)
        doneStatus = value["doneStatus"].string
        tokenEnding = value["tokenEnding"].string
        docsURL = value["docsUrl"].string
        refreshedAt = value["refreshedAt"].number
        total = value["total"].number.map { Int($0) }
        taskCount = value["taskCount"].number.map { Int($0) } ?? 0
        problem = value["problem"].string
    }

    public func can(_ capability: String) -> Bool { capabilities.contains(capability) }

    /// One line under the system's name in Settings.
    public var summary: String {
        var parts: [String] = []
        if let me { parts.append("Connected as \(me.name)") }
        if refreshedAt != nil { parts.append("\(taskCount) task\(taskCount == 1 ? "" : "s") read") }
        parts.append(changes.label)
        return parts.joined(separator: " · ")
    }
}

public struct ConnectedTaskRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var status: String?
    public var priority: String?
    public var startDate: String?
    public var dueDate: String?
    public var board: String?
    public var labels: [String]
    public var assignee: ConnectedTaskPerson?
    public var assigneeName: String?
    public var assignedToMe: Bool
    public var raisedByMe: Bool
    public var url: String?
    // Known once the task was opened (the list does not carry them).
    public var description: String?
    public var createdBy: String?
    public var createdAt: String?
    public var taskType: String?
    public var startTime: String?
    public var dueTime: String?
    public var archivedAt: String?
    /// When this copy was read (ms since 1970).
    public var readAt: Double?

    public init(id: String, title: String, status: String? = nil, priority: String? = nil, startDate: String? = nil,
                dueDate: String? = nil, board: String? = nil, labels: [String] = [], assignee: ConnectedTaskPerson? = nil,
                assigneeName: String? = nil, assignedToMe: Bool = false, raisedByMe: Bool = false, url: String? = nil) {
        self.id = id; self.title = title; self.status = status; self.priority = priority; self.startDate = startDate
        self.dueDate = dueDate; self.board = board; self.labels = labels; self.assignee = assignee
        self.assigneeName = assigneeName ?? assignee?.name; self.assignedToMe = assignedToMe; self.raisedByMe = raisedByMe; self.url = url
    }

    public init?(_ value: NativeRPCValue) {
        guard let id = value["id"].string else { return nil }
        self.init(id: id, title: value["title"].string ?? "Untitled task", status: value["status"].string,
                  priority: value["priority"].string, startDate: value["startDate"].string, dueDate: value["dueDate"].string,
                  board: value["board"].string, labels: (value["labels"].elements ?? []).compactMap(\.string),
                  assignee: ConnectedTaskPerson(value["assignee"]), assigneeName: value["assignee"]["name"].string,
                  assignedToMe: value["assignedToMe"].bool == true, raisedByMe: value["raisedByMe"].bool == true,
                  url: value["url"].string)
        description = value["description"].string
        createdBy = value["createdBy"].string
        createdAt = value["createdAt"].string
        taskType = value["taskType"].string
        startTime = value["startTime"].string
        dueTime = value["dueTime"].string
        archivedAt = value["archivedAt"].string
        readAt = value["readAt"].number
    }

    /// The same task as the task popup reads it (a row of Terminal Deck's task list).
    public func taskRow(connection: String, refreshedAt: Double?) -> TaskRow {
        let iso = ISO8601DateFormatter()
        func ms(_ text: String?) -> Double? {
            guard let text else { return nil }
            let clean = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            return iso.date(from: clean).map { $0.timeIntervalSince1970 * 1000 }
        }
        return TaskRow(id: id, keyId: "connected:" + connection, externalTaskId: id, title: title, agent: "", project: "", crmStatus: status ?? "",
                       process: .idle, updatedAt: readAt ?? refreshedAt ?? 0, local: true, assignee: assignee?.id ?? "none", instructions: description ?? "",
                       priority: priority, startDate: startDate, dueDate: dueDate, startTime: startTime, dueTime: dueTime, labels: labels, board: board,
                       taskType: taskType ?? "task", archivedAt: ms(archivedAt), createdAt: ms(createdAt) ?? 0)
    }
}

public struct ConnectedTaskHandoff: Equatable, Sendable {
    public var remoteID: String
    public var localTaskID: String
    public var agentName: String
    public var markDone: Bool
    public var posted: Bool
    public var closed: Bool
    public var problem: String?

    public init?(_ value: NativeRPCValue) {
        guard let remote = value["remoteId"].string, let local = value["localTaskId"].string else { return nil }
        remoteID = remote; localTaskID = local
        agentName = value["agentName"].string ?? value["agent"].string ?? "an agent"
        markDone = value["markDone"].bool == true
        posted = !value["postedAt"].isNullish
        closed = !value["closedAt"].isNullish
        problem = value["problem"].string
    }

    /// The badge on the task: still working, posted back, or not posted.
    public var line: String {
        if posted { return "\(agentName)’s answer was posted" }
        if let problem, closed { return problem }
        return "With \(agentName)"
    }
}

/// One system's tasks as last read.
public struct ConnectedTaskList: Equatable, Sendable {
    public var system: ConnectedTaskSystem
    public var tasks: [ConnectedTaskRow]
    public var people: [ConnectedTaskPerson]
    public var handoffs: [ConnectedTaskHandoff]
    public var refreshedAt: Double?
    public var total: Int?

    public init?(_ value: NativeRPCValue) {
        guard let system = ConnectedTaskSystem(value["connection"]) else { return nil }
        self.system = system
        tasks = (value["tasks"].elements ?? []).compactMap(ConnectedTaskRow.init)
        people = (value["people"].elements ?? []).compactMap(ConnectedTaskPerson.init)
        handoffs = (value["handoffs"].elements ?? []).compactMap(ConnectedTaskHandoff.init)
        refreshedAt = value["refreshedAt"].number
        total = value["total"].number.map { Int($0) }
    }

    public func handoff(_ remoteID: String) -> ConnectedTaskHandoff? { handoffs.last { $0.remoteID == remoteID } }
}

/// One opened task: the row plus everything its page shows.
public struct ConnectedTaskDetail: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var done: Bool
        public var assigneeName: String?
        public var dueDate: String?
    }
    public struct Checklist: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var items: [Item]
    }
    public struct Comment: Equatable, Sendable, Identifiable {
        public var id: String
        public var by: String
        public var at: String?
        public var body: String
    }
    public struct Activity: Equatable, Sendable, Identifiable {
        public var id: String
        public var at: String?
        public var by: String?
        public var text: String
    }

    public var row: ConnectedTaskRow
    public var description: String?
    public var people: [ConnectedTaskPerson]
    public var subtasks: [Item]
    public var checklists: [Checklist]
    public var comments: [Comment]
    public var activity: [Activity]
    public var handoff: ConnectedTaskHandoff?

    public init?(_ value: NativeRPCValue) {
        guard let row = ConnectedTaskRow(value) else { return nil }
        self.row = row
        description = value["description"].string
        people = (value["people"].elements ?? []).compactMap(ConnectedTaskPerson.init)
        subtasks = (value["subtasks"].elements ?? []).enumerated().map { index, item in
            Item(id: item["id"].string ?? "s\(index)", title: item["title"].string ?? "", done: item["done"].bool == true,
                 assigneeName: item["assignee"]["name"].string, dueDate: item["dueDate"].string)
        }
        checklists = (value["checklists"].elements ?? []).enumerated().map { index, list in
            Checklist(id: "c\(index)", title: list["title"].string ?? "Checklist",
                      items: (list["items"].elements ?? []).enumerated().map { offset, item in
                          Item(id: "c\(index)-\(offset)", title: item["title"].string ?? "", done: item["done"].bool == true, assigneeName: nil, dueDate: nil)
                      })
        }
        comments = (value["comments"].elements ?? []).enumerated().map { index, item in
            Comment(id: item["id"].string ?? "m\(index)", by: item["by"].string ?? "Someone", at: item["at"].string, body: item["body"].string ?? "")
        }
        activity = (value["activity"].elements ?? []).enumerated().map { index, item in
            Activity(id: "a\(index)", at: item["at"].string, by: item["by"].string, text: item["text"].string ?? item["kind"].string ?? "changed")
        }
        handoff = ConnectedTaskHandoff(value["handoff"])
    }
}

/// The piles, as the reference task module names them for one person.
public enum ConnectedTasksPile: String, Equatable, Sendable, CaseIterable {
    case all
    case assignedToMe = "assigned_to_me"
    case raisedByMe = "raised_by_me"
    case withOthers = "with_others"

    public var label: String {
        switch self {
        case .all: "All"
        case .assignedToMe: "Assigned to me"
        case .raisedByMe: "Raised by me"
        case .withOthers: "With others"
        }
    }
}

public enum ConnectedTasksDue: String, Equatable, Sendable {
    case overdue, today, upcoming, none
}

public enum ConnectedTasksFilter {
    public static let doneWords: Set<String> = ["done", "complete", "completed", "closed", "finished", "resolved"]

    public static func isDone(_ row: ConnectedTaskRow, doneStatus: String?) -> Bool {
        guard let status = row.status else { return false }
        if let doneStatus { return status == doneStatus }
        return doneWords.contains(status.lowercased())
    }

    public static func inPile(_ row: ConnectedTaskRow, _ pile: ConnectedTasksPile) -> Bool {
        switch pile {
        case .all: true
        case .assignedToMe: row.assignedToMe
        case .raisedByMe: row.raisedByMe
        case .withOthers: row.raisedByMe && !row.assignedToMe && row.assignee != nil
        }
    }

    /// Today as YYYY-MM-DD in the given time zone.
    public static func today(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    public static func due(_ row: ConnectedTaskRow, today: String, doneStatus: String?) -> ConnectedTasksDue {
        guard let due = row.dueDate else { return .none }
        if due < today { return isDone(row, doneStatus: doneStatus) ? .none : .overdue }
        return due == today ? .today : .upcoming
    }

    public static func matches(_ row: ConnectedTaskRow, pile: ConnectedTasksPile, statuses: Set<String>, search: String,
                               showDone: Bool, doneStatus: String?) -> Bool {
        guard inPile(row, pile) else { return false }
        if !statuses.isEmpty { guard let status = row.status, statuses.contains(status) else { return false } }
        else if !showDone, isDone(row, doneStatus: doneStatus) { return false }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            let haystack = ([row.title, row.board ?? "", row.assigneeName ?? "", row.status ?? ""] + row.labels).joined(separator: "\n").lowercased()
            guard haystack.contains(query) else { return false }
        }
        return true
    }

    /// Overdue first, then by due date, then undated; finished ones last; ties by title.
    public static func apply(_ rows: [ConnectedTaskRow], pile: ConnectedTasksPile = .all, statuses: Set<String> = [], search: String = "",
                             showDone: Bool = false, doneStatus: String? = nil, today: String) -> [ConnectedTaskRow] {
        rows.filter { matches($0, pile: pile, statuses: statuses, search: search, showDone: showDone, doneStatus: doneStatus) }
            .sorted { a, b in
                let doneA = isDone(a, doneStatus: doneStatus), doneB = isDone(b, doneStatus: doneStatus)
                if doneA != doneB { return !doneA }
                let dueA = a.dueDate ?? "9999-99-99", dueB = b.dueDate ?? "9999-99-99"
                if dueA != dueB { return dueA < dueB }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
    }

    public static func counts(_ rows: [ConnectedTaskRow], doneStatus: String?) -> [ConnectedTasksPile: Int] {
        var out: [ConnectedTasksPile: Int] = [:]
        for pile in ConnectedTasksPile.allCases {
            out[pile] = rows.filter { inPile($0, pile) && !isDone($0, doneStatus: doneStatus) }.count
        }
        return out
    }

    /// "Updated just now", "Updated 4 min ago", "Updated at 09:12".
    public static func freshness(_ refreshedAt: Double?, now: Double) -> String {
        guard let refreshedAt else { return "Not read yet" }
        let minutes = Int(max(0, now - refreshedAt) / 60_000)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let formatter = DateFormatter(); formatter.dateFormat = minutes < 24 * 60 ? "HH:mm" : "d MMM, HH:mm"
        return "Updated at " + formatter.string(from: Date(timeIntervalSince1970: refreshedAt / 1000))
    }
}
