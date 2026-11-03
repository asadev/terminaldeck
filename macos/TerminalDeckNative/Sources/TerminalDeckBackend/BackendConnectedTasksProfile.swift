import Foundation
import TerminalDeckNativeCore

/// What a connected task system can do, discovered from its tool list: which tool
/// lists, opens, moves, comments on and edits a task, and the argument names each
/// takes. Matching is by the common names (`list_tasks`, `get_task`, …, with or
/// without a `tasks_` prefix) and by what the input schema accepts. A capability the
/// system does not offer is simply absent — never guessed.
public struct BackendConnectedTasksProfile: Sendable, Equatable {
    public struct Tool: Sendable, Equatable {
        public var name: String
        /// The argument that names the task (`task_id`, `id`, `taskId`).
        public var idArgument: String?
        public init(name: String, idArgument: String? = nil) { self.name = name; self.idArgument = idArgument }
    }

    public var list: Tool?
    public var listLimit: String?
    public var listIncludeDone: String?
    public var get: Tool?
    public var status: Tool?
    public var statusArgument: String?
    /// The system's own status words, in its order.
    public var statuses: [String]
    public var comment: Tool?
    public var commentBody: String?
    public var update: Tool?
    public var dueArgument: String?
    public var assigneeArgument: String?
    public var confirmArgument: String?
    public var people: Tool?
    /// The update tool's argument for linked records (`related`), the record kinds it takes,
    /// and, per kind, the tool that searches them (a `list_<kind>s` tool with a `search` argument).
    public var relatedArgument: String?
    public var relatedAreas: [String] = []
    public var search: [String: String] = [:]
    /// False on a profile saved before linked records were discovered (read again on first use).
    public var discoveredRelated = true

    public init(list: Tool? = nil, listLimit: String? = nil, listIncludeDone: String? = nil, get: Tool? = nil, status: Tool? = nil,
                statusArgument: String? = nil, statuses: [String] = [], comment: Tool? = nil, commentBody: String? = nil,
                update: Tool? = nil, dueArgument: String? = nil, assigneeArgument: String? = nil, confirmArgument: String? = nil,
                people: Tool? = nil) {
        self.list = list; self.listLimit = listLimit; self.listIncludeDone = listIncludeDone; self.get = get; self.status = status
        self.statusArgument = statusArgument; self.statuses = statuses; self.comment = comment; self.commentBody = commentBody
        self.update = update; self.dueArgument = dueArgument; self.assigneeArgument = assigneeArgument
        self.confirmArgument = confirmArgument; self.people = people
    }

    public enum Capability: String, Sendable, CaseIterable {
        case list, read, status, comment, dueDate = "due-date", assignee, people
        public var words: String {
            switch self {
            case .list: "list your tasks"
            case .read: "open a task (details, subtasks, checklists, comments, activity)"
            case .status: "change status"
            case .comment: "add comments"
            case .dueDate: "change due dates"
            case .assignee: "change who it is assigned to"
            case .people: "list the people tasks can go to"
            }
        }
    }

    public var capabilities: [Capability] {
        var out: [Capability] = []
        if list != nil { out.append(.list) }
        if get != nil { out.append(.read) }
        if status != nil, statusArgument != nil { out.append(.status) }
        if comment != nil, commentBody != nil { out.append(.comment) }
        if update != nil, dueArgument != nil { out.append(.dueDate) }
        if update != nil, assigneeArgument != nil { out.append(.assignee) }
        if people != nil { out.append(.people) }
        return out
    }

    public func can(_ capability: Capability) -> Bool { capabilities.contains(capability) }

    /// The system's word for finished, when it has one.
    public var doneStatus: String? {
        statuses.first { ["done", "complete", "completed", "closed", "finished", "resolved"].contains($0.lowercased()) }
    }

    // MARK: Discovery

    static let idNames = ["task_id", "taskId", "id", "task"]

    public static func discover(_ tools: [BackendConnectedTasksRemoteTool]) -> BackendConnectedTasksProfile {
        let byName = Dictionary(tools.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func find(_ names: [String]) -> BackendConnectedTasksRemoteTool? {
            for name in names {
                for candidate in [name, "tasks_" + name, "task_" + name, "tasks." + name] { if let tool = byName[candidate] { return tool } }
            }
            return nil
        }
        func pick(_ tool: BackendConnectedTasksRemoteTool, _ names: [String]) -> String? {
            let properties = tool.properties
            return names.first { properties.contains($0) }
        }
        func withID(_ tool: BackendConnectedTasksRemoteTool?) -> Tool? {
            guard let tool, let id = pick(tool, idNames) else { return nil }
            return Tool(name: tool.name, idArgument: id)
        }
        var profile = BackendConnectedTasksProfile()
        if let list = find(["list_tasks", "list_my_tasks", "tasks_list"]) {
            profile.list = Tool(name: list.name)
            profile.listLimit = pick(list, ["limit", "max", "max_results", "page_size"])
            profile.listIncludeDone = pick(list, ["include_done", "includeDone", "include_closed", "includeCompleted", "include_completed"])
        }
        profile.get = withID(find(["get_task", "read_task", "open_task", "task_get", "tasks_get"]))
        if let status = find(["set_task_status", "update_task_status", "change_task_status", "set_status", "move_task", "tasks_set_status"]), let tool = withID(status) {
            profile.status = tool
            profile.statusArgument = pick(status, ["status", "state", "to", "group"])
            if let argument = profile.statusArgument {
                profile.statuses = (status.property(argument)["enum"].elements ?? []).compactMap(\.string)
            }
        }
        if let comment = find(["add_comment", "add_task_comment", "comment_on_task", "create_comment", "tasks_comment"]), let tool = withID(comment) {
            profile.comment = tool
            profile.commentBody = pick(comment, ["body", "text", "comment", "content", "message"])
        }
        if let update = find(["update_task", "edit_task", "patch_task", "tasks_update"]), let tool = withID(update) {
            profile.update = tool
            profile.dueArgument = pick(update, ["due_date", "dueDate", "due", "due_on"])
            profile.assigneeArgument = pick(update, ["assignee", "assignee_id", "assigneeId", "assigned_to", "owner"])
            profile.confirmArgument = pick(update, ["confirm"])
        }
        if let people = find(["list_team", "list_people", "list_users", "list_members"]) { profile.people = Tool(name: people.name) }
        if let update = find(["update_task", "edit_task", "patch_task", "tasks_update"]), let related = pick(update, ["related", "links", "related_records"]) {
            profile.relatedArgument = related
            profile.relatedAreas = (update.property(related)["items"]["properties"]["area"]["enum"].elements ?? []).compactMap(\.string)
            for area in profile.relatedAreas where area != "person" {
                if let tool = byName["list_" + area + "s"], tool.properties.contains("search") { profile.search[area] = tool.name }
            }
            if profile.people != nil, profile.relatedAreas.contains("person") { profile.search["person"] = profile.people!.name }
        }
        if profile.statuses.isEmpty, let list = find(["list_tasks", "list_my_tasks", "tasks_list"]) {
            let statusProperty = list.property("status")
            profile.statuses = ((statusProperty["items"]["enum"].elements ?? statusProperty["enum"].elements) ?? []).compactMap(\.string)
        }
        return profile
    }

    // MARK: Saved form

    public var wire: NativeRPCValue {
        func tool(_ value: Tool?) -> NativeRPCValue {
            guard let value else { return .null }
            return .object([.init("name", .string(value.name)), .init("id", value.idArgument.map(NativeRPCValue.string) ?? .null)])
        }
        func text(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
        return .object([
            .init("list", tool(list)), .init("listLimit", text(listLimit)), .init("listIncludeDone", text(listIncludeDone)),
            .init("get", tool(get)), .init("status", tool(status)), .init("statusArgument", text(statusArgument)),
            .init("statuses", .array(statuses.map(NativeRPCValue.string))),
            .init("comment", tool(comment)), .init("commentBody", text(commentBody)),
            .init("update", tool(update)), .init("dueArgument", text(dueArgument)), .init("assigneeArgument", text(assigneeArgument)),
            .init("confirmArgument", text(confirmArgument)), .init("people", tool(people)),
            .init("relatedArgument", text(relatedArgument)), .init("relatedAreas", .array(relatedAreas.map(NativeRPCValue.string))),
            .init("search", .object(search.keys.sorted().map { .init($0, .string(search[$0]!)) })),
        ])
    }

    public init(wire: NativeRPCValue) {
        func tool(_ value: NativeRPCValue) -> Tool? {
            guard let name = value["name"].string, !name.isEmpty else { return nil }
            return Tool(name: name, idArgument: value["id"].string)
        }
        self.init(list: tool(wire["list"]), listLimit: wire["listLimit"].string, listIncludeDone: wire["listIncludeDone"].string,
                  get: tool(wire["get"]), status: tool(wire["status"]), statusArgument: wire["statusArgument"].string,
                  statuses: (wire["statuses"].elements ?? []).compactMap(\.string), comment: tool(wire["comment"]),
                  commentBody: wire["commentBody"].string, update: tool(wire["update"]), dueArgument: wire["dueArgument"].string,
                  assigneeArgument: wire["assigneeArgument"].string, confirmArgument: wire["confirmArgument"].string,
                  people: tool(wire["people"]))
        relatedArgument = wire["relatedArgument"].string
        relatedAreas = (wire["relatedAreas"].elements ?? []).compactMap(\.string)
        for field in wire["search"].fields ?? [] { if let tool = field.value.string { search[field.key] = tool } }
        discoveredRelated = wire.has("relatedAreas")
    }
}

/// Reading a system's answers into Terminal Deck's task fields. Tolerant about names
/// (`due_date`/`dueDate`, `title`/`name`), strict about types: what is not there, or
/// not the right kind, reads as absent.
public enum BackendConnectedTasksMapping {
    public static let maximumRows = 500

    static func text(_ value: NativeRPCValue, _ keys: [String]) -> NativeRPCValue {
        for key in keys {
            if let string = value[key].string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .string(string) }
            if let number = value[key].number { return .string(number.rounded() == number ? String(Int(number)) : String(number)) }
        }
        return .null
    }

    /// A date-only value (YYYY-MM-DD) from a date or a date-time.
    static func day(_ value: NativeRPCValue, _ keys: [String]) -> NativeRPCValue {
        guard let raw = text(value, keys).string else { return .null }
        let prefix = String(raw.prefix(10))
        return prefix.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil ? .string(prefix) : .null
    }

    static func person(_ value: NativeRPCValue) -> NativeRPCValue {
        if let name = value.string, !name.isEmpty { return .object([.init("id", .null), .init("name", .string(name))]) }
        guard value.fields != nil else { return .null }
        let id = text(value, ["id", "user_id", "userId"]), name = text(value, ["name", "display_name", "displayName", "email"])
        if id == .null && name == .null { return .null }
        return .object([.init("id", id), .init("name", name)])
    }

    static func strings(_ value: NativeRPCValue) -> [String] {
        (value.elements ?? []).compactMap { $0.string ?? $0["name"].string ?? $0["label"].string }.filter { !$0.isEmpty }
    }

    /// The task rows in a list answer: `tasks`, `items`, `results`, `data`, or a bare array.
    public static func rows(_ data: NativeRPCValue) -> [NativeRPCValue] {
        if let rows = data.elements { return rows }
        for key in ["tasks", "items", "results", "data", "rows"] { if let rows = data[key].elements { return rows } }
        return []
    }

    /// One task in Terminal Deck's words. Nil when it has no id.
    public static func task(_ raw: NativeRPCValue, me: String?) -> NativeRPCValue? {
        guard let id = text(raw, ["id", "task_id", "taskId", "key"]).string else { return nil }
        let assignee = person(raw["assignee"].isNullish ? (raw["assigned_to"].isNullish ? raw["owner"] : raw["assigned_to"]) : raw["assignee"])
        let assigneeID = assignee["id"].string
        let creator = text(raw, ["created_by", "createdBy", "creator_id", "raised_by"]).string
        let toMe = raw["assigned_to_me"].bool ?? raw["assignedToMe"].bool ?? (me != nil && assigneeID == me)
        let byMe = raw["raised_by_me"].bool ?? raw["raisedByMe"].bool ?? (me != nil && creator == me)
        var labels = strings(raw["labels"]); if labels.isEmpty { labels = strings(raw["tags"]) }
        if labels.isEmpty { labels = strings(raw["page"]["labels"]) }
        return .object([
            .init("id", .string(id)),
            .init("title", text(raw, ["title", "name", "text", "summary"]).string.map { .string(String($0.prefix(500))) } ?? .string("Untitled task")),
            .init("status", text(raw, ["status", "state", "group", "stage"])),
            .init("priority", text(raw, ["priority"])),
            .init("startDate", day(raw, ["start_date", "startDate", "start"])),
            .init("dueDate", day(raw, ["due_date", "dueDate", "due", "due_on"])),
            .init("board", text(raw, ["board", "list", "project", "category"])),
            .init("labels", .array(labels.prefix(20).map(NativeRPCValue.string))),
            .init("assignee", assignee),
            .init("assignedToMe", .bool(toMe)),
            .init("raisedByMe", .bool(byMe)),
            .init("url", text(raw, ["url", "link", "web_url", "webUrl"])),
            .init("createdAt", text(raw, ["created_at", "createdAt"])),
            .init("createdBy", text(raw, ["created_by", "createdBy", "creator_id"])),
        ])
    }

    /// An opened task: the row plus everything its page shows.
    public static func detail(_ data: NativeRPCValue, me: String?) -> NativeRPCValue? {
        let base = data["task"].fields != nil ? data["task"] : data
        guard var row = task(base, me: me) else { return nil }
        if row["labels"].elements?.isEmpty != false {
            let labels = strings(data["page"]["labels"]); if !labels.isEmpty { row = row.setting("labels", .array(labels.map(NativeRPCValue.string))) }
        }
        let description = text(base, ["description", "details", "body", "notes"])
        var people: [NativeRPCValue] = []
        if data["people"]["main"].fields != nil { people.append(person(data["people"]["main"])) }
        people += (data["people"]["others"].elements ?? data["people"].elements ?? []).map(person).filter { $0 != .null }
        let subtasks = (data["subtasks"].elements ?? base["subtasks"].elements ?? []).prefix(200).map { item in
            NativeRPCValue.object([.init("id", text(item, ["id"])), .init("title", text(item, ["title", "name", "text"])),
                                   .init("done", .bool(item["done"].bool ?? item["completed"].bool ?? false)),
                                   .init("assignee", person(item["assignee"])), .init("dueDate", day(item, ["due_date", "dueDate"]))])
        }
        let checklists = (data["checklists"].elements ?? base["checklists"].elements ?? []).prefix(50).map { list in
            NativeRPCValue.object([.init("title", text(list, ["title", "name"])),
                                   .init("items", .array((list["items"].elements ?? []).prefix(200).map { item in
                                       .object([.init("title", text(item, ["title", "name", "text"])), .init("done", .bool(item["done"].bool ?? false))])
                                   }))])
        }
        let comments = (data["comments"].elements ?? base["comments"].elements ?? []).suffix(100).map { item in
            NativeRPCValue.object([.init("id", text(item, ["id"])),
                                   .init("by", item["by"].fields != nil ? text(item["by"], ["name"]) : text(item, ["by", "author", "authorName", "author_name"])),
                                   .init("at", text(item, ["at", "created_at", "createdAt"])),
                                   .init("body", .string(String((text(item, ["body", "text", "content"]).string ?? "").prefix(4000))))])
        }
        let activity = (data["activity"].elements ?? base["activity"].elements ?? []).suffix(100).map { item in
            NativeRPCValue.object([.init("at", text(item, ["at", "created_at", "createdAt"])),
                                   .init("kind", text(item, ["kind", "type", "action"])),
                                   .init("by", item["by"].fields != nil ? text(item["by"], ["name"]) : text(item, ["by", "actor"])),
                                   .init("text", activityWords(item))])
        }
        if let type = data["page"]["type"].string ?? base["task_type"].string { row = row.setting("taskType", .string(type)) }
        return row
            .setting("description", description.string.map { .string(String($0.prefix(20_000))) } ?? .null)
            .setting("people", .array(people))
            .setting("subtasks", .array(Array(subtasks)))
            .setting("checklists", .array(Array(checklists)))
            .setting("comments", .array(Array(comments)))
            .setting("activity", .array(Array(activity)))
    }

    /// One plain line for an activity entry: its kind and what it changed.
    static func activityWords(_ item: NativeRPCValue) -> NativeRPCValue {
        if let line = text(item, ["text", "summary", "message"]).string { return .string(line) }
        let kind = (text(item, ["kind", "type", "action"]).string ?? "changed").replacingOccurrences(of: "_", with: " ")
        let detail = item["detail"]
        if let from = text(detail, ["from"]).string, let to = text(detail, ["to"]).string { return .string("\(kind): \(from) → \(to)") }
        if let to = text(detail, ["to", "name", "value"]).string { return .string("\(kind): \(to)") }
        return .string(kind)
    }

    /// The people a task can go to, and who "you" are, from a people answer.
    public static func people(_ data: NativeRPCValue) -> (me: String?, people: [NativeRPCValue]) {
        let list = data["people"].elements ?? data["team"].elements ?? data["users"].elements ?? data.elements ?? []
        let people = list.prefix(2_000).map(person).filter { $0["id"].string != nil && $0["name"].string != nil }
        let me = text(data, ["you", "me", "self", "current_user_id"]).string ?? data["you"]["id"].string
        return (me, Array(people))
    }
}
