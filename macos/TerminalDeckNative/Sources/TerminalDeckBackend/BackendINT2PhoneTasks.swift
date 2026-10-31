import Foundation
import TerminalDeckNativeCore

/**
 * The phone's task screens, made as iLoop's My Work and task page (Tasks seat, iOS batch 1, 27 Oct 2026).
 *
 * What the `tasks` panel adds for them, on top of the rows and actions it always sent:
 *  - every task row carries `meta`, the task's own words as data (status, priority, dates, who has it and what
 *    kind they are, tags, board, type, whether an agent works it), so the phone sorts, groups, filters and tints
 *    the list the way iLoop does without opening each task;
 *  - the list offers three quick actions on the panel itself — tick (`quick_status`), snooze (`quick_due`) and
 *    Trash (`quick_delete`) — each naming its task in a field, so two hundred rows do not each carry a form;
 *  - a task's own page (`scope: task:<id>`) is the task row with every action the page offers, then its parts as
 *    rows grouped by section: Subtasks, People, Checklists, Relationships, Fields, Files, Time, Activity, Comments.
 *
 * Every write goes through the task tools the Mac's own task page calls (`tasks.local_change`,
 * `tasks.local_parts`), under the device's own grant. Parts, Trash and the timer are offered at Full control
 * only: the Work level's gate (`BackendINT2PhonePanelScope.workOperation`) admits creating, editing, status and
 * assigning, and an offered control that is refused would not do what it says.
 *
 * Text on the wire: a form value may not carry a line break, so the phone sends U+2028 for one and this file
 * turns it back (comments, details, subtasks); lists (tags) travel joined by U+2028 the same way.
 */
public enum BackendINT2PhoneTasks {
    typealias V = NativeRPCValue

    /// A line break inside a form value (the wire refuses control characters).
    static let lineBreak = "\u{2028}"
    /// The most of each part one task page carries, so the page stays inside the 200 rows a panel answer may hold.
    static let pageLimits = (subtasks: 40, people: 10, checklistRows: 30, relationships: 15, fields: 15, files: 15, time: 10, activity: 20, comments: 44)
    static let priorities = ["Low", "Medium", "High", "Critical"]

    // MARK: - Small builders (the same wire shapes BackendINT2PhonePanels writes)

    static func object(_ fields: [(String, V)]) -> V { .object(fields.map { .init($0.0, $0.1) }) }

    static func field(_ id: String, _ label: String, value: String = "", required: Bool = false, choices: [(id: String, label: String)] = []) -> V {
        var row = object([("id", .string(id)), ("label", .string(label)), ("value", .string(value)), ("required", .bool(required))])
        if !choices.isEmpty {
            row = row.setting("choices", .array(choices.map { .string($0.id) }))
            row = row.setting("choiceLabels", .object(choices.map { .init($0.id, .string($0.label)) }))
        }
        return row
    }

    static func action(_ id: String, _ label: String, fields: [V] = [], confirm: String? = nil) -> V {
        var row = object([("id", .string(id)), ("label", .string(label)), ("fields", .array(fields))])
        if let confirm { row = row.setting("destructive", .bool(true)).setting("confirm", .string(confirm)) }
        return row
    }

    /// Text from the phone's form: U+2028 back to a line break, ends trimmed.
    static func text(_ raw: String?) -> String {
        (raw ?? "").replacingOccurrences(of: lineBreak, with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text for a prefilled form value: line breaks as U+2028, other control characters out.
    static func formValue(_ raw: String?) -> String {
        let joined = (raw ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: lineBreak)
        return String(String.UnicodeScalarView(joined.unicodeScalars.filter { $0.value >= 32 && !(127...159).contains($0.value) }))
    }

    // MARK: - The list

    /// Who holds a task, as a kind: you, Hoot, an agent, a project's lead seat, or nobody.
    static func kind(of assignee: String) -> String {
        switch assignee {
        case "me": return "human"
        case "hoot": return "hoot"
        case "", "none": return "none"
        default: return BackendAGTLeadSeats.isAddress(assignee) ? "seat" : "agent"
        }
    }

    /// One task's own words as data (`meta`): strings, and tags as a list. Only what the task has is written.
    static func meta(_ task: V) -> V {
        let assignee = task["assignee"].string ?? "none"
        var fields: [(String, V)] = [("status", .string(task["status"].string ?? "To-Do")), ("assignee", .string(assignee)),
                                     ("assigneeKind", .string(kind(of: assignee)))]
        if let name = task["assigneeName"].string { fields.append(("assigneeName", .string(name))) }
        for (key, wire) in [("priority", "priority"), ("startDate", "start"), ("dueDate", "due"), ("board", "board")] {
            if let value = task[key].string, !value.isEmpty { fields.append((wire, .string(value))) }
        }
        let tags = (task["labels"].elements ?? []).compactMap(\.string).filter { !$0.isEmpty }
        if !tags.isEmpty { fields.append(("tags", .array(tags.map(V.string)))) }
        if task["type"].string == "milestone" { fields.append(("type", .string("milestone"))) }
        if task["agentWorking"].bool == true { fields.append(("working", .string("1"))) }
        if !task["repeats"].isNullish { fields.append(("repeats", .string("1"))) }
        return object(fields)
    }

    /// Who a task can be given to, as on the Mac's own task page: you, Hoot, each working agent, or nobody.
    static func assignChoices(agents: [V]) -> [(id: String, label: String)] {
        var out: [(id: String, label: String)] = [("me", "You"), ("hoot", "Hoot")]
        for agent in agents where !["archived", "paused"].contains(agent["status"].string ?? "") {
            if let id = agent["id"].string, let name = agent["name"].string ?? agent["label"].string { out.append((id, name)) }
        }
        out.append(("none", "Unassigned"))
        return out
    }

    static func statusChoices(_ statuses: [String]) -> [(id: String, label: String)] {
        (statuses.isEmpty ? TaskStatuses.all : statuses).map { ($0, $0) }
    }

    static func priorityChoices() -> [(id: String, label: String)] { [("", "None")] + priorities.map { ($0, $0) } }

    /// The New task form's extra fields (iLoop's composer): status, priority, the two dates and who does it.
    static func createFields(statuses: [String], agents: [V]) -> [V] {
        [field("status", "Status", value: "To-Do", choices: statusChoices(statuses)),
         field("priority", "Priority", choices: priorityChoices()),
         field("due_date", "Due"), field("start_date", "Starts"),
         field("assignee", "Assign to", value: "me", choices: assignChoices(agents: agents))]
    }

    /// The list's quick actions, on the panel itself: each names its task in the `task` field.
    static func quickActions(statuses: [String], level: BackendINT2PhoneAccessLevel) -> [V] {
        guard level != .look else { return [] }
        var out = [action("quick_status", "Status", fields: [field("task", "Task", required: true), field("status", "Status", required: true, choices: statusChoices(statuses))]),
                   action("quick_due", "Due date", fields: [field("task", "Task", required: true), field("due_date", "Due")])]
        if level == .full { out.append(action("quick_delete", "Delete task", fields: [field("task", "Task", required: true)], confirm: "It moves to the Trash on the Mac.")) }
        return out
    }

    // MARK: - A task's own page

    /// The actions the task's page offers on top of the list row's own.
    static func pageActions(_ task: V, others: [V], level: BackendINT2PhoneAccessLevel, agents: [V], statuses: [String],
                            details: String, running: V?, siblings: [V]) -> [V] {
        guard level != .look else { return [] }
        let title = task["title"].string ?? "this task"
        var out: [V] = [
            action("status", "Status", fields: [field("status", "Status", value: task["status"].string ?? "To-Do", required: true, choices: statusChoices(statuses))]),
            action("priority", "Priority", fields: [field("priority", "Priority", value: task["priority"].string ?? "", choices: priorityChoices())]),
            action("dates", "Dates", fields: [field("start_date", "Starts", value: task["startDate"].string ?? ""), field("due_date", "Due", value: task["dueDate"].string ?? "")]),
            action("assign", "Assign", fields: [field("assignee", "Assign to", value: task["assignee"].string ?? "none", required: true, choices: assignChoices(agents: agents))]),
            action("tags", "Tags", fields: [field("tags", "Tags", value: (task["labels"].elements ?? []).compactMap(\.string).joined(separator: lineBreak))]),
        ]
        // The details travel in one form value (2,048 bytes on the wire): a longer description is edited on the Mac.
        let current = formValue(details)
        if current.utf8.count <= 2_000 { out.append(action("details", "Description", fields: [field("details", "Description", value: current)])) }
        guard level == .full else { return out }
        let onTask = Set([task["assignee"].string ?? ""] + others.compactMap { $0["id"].string })
        let people = assignChoices(agents: agents).filter { $0.id != "none" && !onTask.contains($0.id) }
        out += [action("subtask_add", "Add subtask", fields: [field("text", "Subtask", required: true)]),
                action("checklist_add", "Add checklist", fields: [field("text", "Checklist", value: "Checklist", required: true)]),
                action("time_add", "Log time", fields: [field("minutes", "Minutes", required: true), field("note", "What for")]),
                action("delete", "Delete task", confirm: "Move “\(title)” to the Trash on the Mac?")]
        if !people.isEmpty { out.append(action("person_add", "Add somebody", fields: [field("person", "Person", required: true, choices: people)])) }
        let others = siblings.compactMap { row -> (id: String, label: String)? in
            guard let id = row["task"].string, id != task["task"].string, let name = row["title"].string else { return nil }; return (id, name)
        }.prefix(50)
        if !others.isEmpty {
            out.append(action("dependency_add", "Add relationship", fields: [
                field("kind", "How", value: "blocked_by", required: true, choices: [("blocked_by", "Waiting on"), ("blocks", "Blocking"), ("linked", "Linked")]),
                field("other", "Task", required: true, choices: Array(others))]))
        }
        // The timer: started here, or stopped when one this phone started is running (the Mac stops only its caller's own).
        if let running {
            if startedHere(running) { out.append(action("time_stop", "Stop the timer")) }
        } else { out.append(action("time_start", "Start the timer")) }
        return out
    }

    /// A timer a phone started: by its device name now, by the older "app:" name before 27 Oct.
    static func startedHere(_ entry: V) -> Bool {
        let who = entry["userId"].string ?? ""
        return who.hasPrefix("device:") || who.hasPrefix("app:")
    }

    /// One activity line in the Mac's own words (the Activity column's sentences).
    static func activitySentence(_ row: V, names: [String: String]) -> (text: String, category: String?) {
        let payload = (row["payload"].fields ?? []).reduce(into: [String: CrmValue]()) { $0[$1.key] = BackendCrmWire.crm($1.value) }
        let actorName = row["actor"]["name"].string
        let actor = actorName.map { CrmPerson(id: row["actorUserId"].string ?? "", name: $0, initials: "", color: "") }
        let activity = TaskActivityRow(id: row["id"].string ?? "", taskId: row["taskId"].string ?? "", kind: row["kind"].string ?? "",
                                       payload: payload, actor: actor, actorUserId: row["actorUserId"].string, createdAt: row["createdAt"].string ?? "")
        let parts = ActivityFeedRules.describe(activity, viewer: "me", today: BackendCrmTime.localToday(), who: { id in id.flatMap { names[$0] } })
        return (ActivityFeedRules.partsText(parts), ActivityFeedRules.category(activity.kind)?.rawValue)
    }

    /// A field's value in a few words (the page shows it read-only, as iLoop does).
    static func fieldDisplay(_ value: V) -> String {
        switch value {
        case .string(let text): return text.isEmpty ? "—" : String(text.prefix(120))
        case .number(let number): return number.rounded() == number && abs(number) < 1e15 ? String(Int(number)) : String(number)
        case .bool(let on): return on ? "Yes" : "No"
        case .array(let items):
            let words = items.compactMap { $0.string ?? $0["label"].string ?? $0["name"].string }
            return words.isEmpty ? (items.isEmpty ? "—" : "\(items.count) items") : String(words.joined(separator: ", ").prefix(120))
        case .object:
            if let label = value["label"].string ?? value["text"].string ?? value["name"].string { return String(label.prefix(120)) }
            return "Set"
        default: return "—"
        }
    }

    /// An ISO instant, with or without fractional seconds.
    static func instant(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Seconds tracked on a task, and the entry running now (if any).
    static func tracked(_ entries: [V], now: Date = Date()) -> (seconds: Int, running: V?) {
        var total = 0.0, running: V?
        for entry in entries {
            if entry["endedAt"].isNullish, let started = entry["startedAt"].string.flatMap(instant) {
                total += max(0, now.timeIntervalSince(started)); if running == nil { running = entry }
            } else { total += entry["seconds"].number ?? 0 }
        }
        return (Int(total), running)
    }

    /**
     * One task's page: its row (with every action), then its parts, grouped. Failure to read the comments or the
     * activity is said on the page (`note`); the task itself must be readable.
     */
    static func page(_ id: String, request: BackendRemotePanelRequest, rpc: NativeRPCContext, scope: BackendINT2PhonePanelScope,
                     tasks: [V], rows: [V], agents: [V], statuses: [String], level: BackendINT2PhoneAccessLevel) async throws -> V {
        guard let base = rows.first(where: { $0["id"].string == id }), let task = tasks.first(where: { $0["task"].string == id }) else {
            throw NativeRPCError(code: "unavailable", message: "This task is no longer in this project.")
        }
        func read(_ verb: String) async throws -> V {
            try await scope.call("tasks.local", arguments: object([("do", .string(verb)), ("task", .string(id)), ("project", .string(request.path))]),
                                 rpc: rpc, domain: "tasks", projects: [request.path])
        }
        let full = try await read("get")
        var trouble: [String] = []
        let thread: V?, activity: V?
        do { thread = try await read("comments") } catch { thread = nil; trouble.append("The comments could not be read: \(error.localizedDescription)") }
        do { activity = try await read("activity") } catch { activity = nil; trouble.append("The activity could not be read: \(error.localizedDescription)") }
        return assemble(id, base: base, task: task, full: full, thread: thread, activity: activity, trouble: trouble, request: request,
                        tasks: tasks, agents: agents, statuses: statuses, level: level)
    }

    /// The page from what was read: kept apart from the reading so it can be checked without a Mac.
    static func assemble(_ id: String, base: V, task: V, full: V, thread: V?, activity: V?, trouble: [String], request: BackendRemotePanelRequest,
                         tasks: [V], agents: [V], statuses: [String], level: BackendINT2PhoneAccessLevel, now: Date = Date()) -> V {
        let full_ = level == .full
        let others = full["people"]["others"].elements ?? []
        let time = tracked(full["timeEntries"].elements ?? [], now: now)
        let details = full["details"].string ?? ""

        var names: [String: String] = ["me": "You", "hoot": "Hoot"]
        for agent in agents { if let agentID = agent["id"].string, let name = agent["name"].string { names[agentID] = name } }
        for person in [full["people"]["primary"]] + others { if let personID = person["id"].string, let name = person["name"].string { names[personID] = name } }

        // The task row: the list row, its words, its description and every action its page offers.
        var meta = Self.meta(task).setting("tracked", .string(String(time.seconds)))
        if let running = time.running, let since = running["startedAt"].string {
            meta = meta.setting("runningSince", .string(since)).setting("runningHere", .string(startedHere(running) ? "1" : ""))
        }
        let actions = (base["actions"].elements ?? []) + pageActions(task, others: others, level: level, agents: agents, statuses: statuses,
                                                                       details: details, running: time.running, siblings: tasks)
        var page: [V] = [base.setting("meta", meta).setting("actions", .array(actions)).setting("body", details.isEmpty ? .null : .string(details))]

        // Subtasks.
        for sub in (full["subtasks"].elements ?? []).prefix(pageLimits.subtasks) {
            guard let subID = sub["id"].string, let title = sub["title"].string else { continue }
            let done = sub["done"].bool == true
            var row = object([("id", .string("subtask:" + subID)), ("title", .string(title)), ("group", .string("Subtasks")), ("value", .string(done ? "done" : "open"))])
            if let who = sub["assigneeUserId"].string { row = row.setting("meta", object([("assignee", .string(who)), ("assigneeName", .string(names[who] ?? who))])) }
            if full_ { row = row.setting("actions", .array([done ? action("subtask_undo", "Reopen") : action("subtask_done", "Done"), action("subtask_remove", "Remove")])) }
            page.append(row)
        }
        // People: who it is for, then everyone else on it.
        let primary = full["people"]["primary"]
        var people: [V] = []
        if let personID = primary["id"].string {
            people.append(object([("id", .string("person:" + personID)), ("title", .string(primary["name"].string ?? names[personID] ?? personID)), ("group", .string("People")),
                                  ("value", .string("primary")), ("meta", object([("kind", .string(kind(of: personID)))]))]))
        }
        for person in others {
            guard let personID = person["id"].string else { continue }
            var row = object([("id", .string("person:" + personID)), ("title", .string(person["name"].string ?? names[personID] ?? personID)), ("group", .string("People")),
                              ("value", .string("other")), ("meta", object([("kind", .string(kind(of: personID)))]))])
            if full_ { row = row.setting("actions", .array([action("person_remove", "Take off")])) }
            people.append(row)
        }
        page += people.prefix(pageLimits.people)
        // Checklists, each followed by its items.
        var checklistRows: [V] = []
        for list in full["checklists"].elements ?? [] {
            guard let listID = list["id"].string else { continue }
            let items = list["items"].elements ?? []
            var row = object([("id", .string("checklist:" + listID)), ("title", .string(list["title"].string ?? "Checklist")), ("group", .string("Checklists")),
                              ("value", .string("\(items.filter { $0["done"].bool == true }.count)/\(items.count)"))])
            if full_ { row = row.setting("actions", .array([action("item_add", "Add an item", fields: [field("text", "Item", required: true)]),
                                                             action("checklist_remove", "Remove checklist", confirm: "Remove this checklist and its items?")])) }
            checklistRows.append(row)
            for item in items {
                guard let itemID = item["id"].string else { continue }
                let done = item["done"].bool == true
                var line = object([("id", .string("item:" + itemID)), ("title", .string(item["title"].string ?? item["text"].string ?? "Item")), ("group", .string("Checklists")),
                                   ("level", .number(1)), ("value", .string(done ? "done" : "open")), ("meta", object([("checklist", .string(listID))]))])
                if full_ { line = line.setting("actions", .array([done ? action("item_undo", "Untick") : action("item_done", "Tick"), action("item_remove", "Remove")])) }
                checklistRows.append(line)
            }
        }
        page += checklistRows.prefix(pageLimits.checklistRows)
        // Relationships.
        for dependency in (full["dependencies"].elements ?? []).prefix(pageLimits.relationships) {
            guard let other = dependency["otherTaskId"].string, let relation = dependency["kind"].string else { continue }
            let words = ["blocked_by": "Waiting on", "blocks": "Blocking"][relation] ?? "Linked"
            var row = object([("id", .string("dep:\(relation):\(other)")), ("title", .string(dependency["otherTitle"].string ?? "Another task")), ("group", .string("Relationships")),
                              ("value", .string(relation)), ("badge", .string(words)), ("meta", object([("done", .string(dependency["otherDone"].bool == true ? "1" : ""))]))])
            if full_ { row = row.setting("actions", .array([action("dependency_remove", "Unlink")])) }
            page.append(row)
        }
        // Custom fields, read-only.
        for entry in (full["fields"].elements ?? []).prefix(pageLimits.fields) {
            guard let fieldID = entry["id"].string, let label = entry["label"].string else { continue }
            page.append(object([("id", .string("field:" + fieldID)), ("title", .string(label)), ("group", .string("Fields")),
                                ("detail", .string(entry["kind"].string ?? "text")), ("value", .string(fieldDisplay(entry["value"])))]))
        }
        // Files on the task.
        for file in (full["attachments"].elements ?? []).prefix(pageLimits.files) {
            guard let fileID = file["id"].string else { continue }
            var row = object([("id", .string("file:" + fileID)), ("title", .string(file["fileName"].string ?? "File")), ("group", .string("Files")),
                              ("value", .string(file["kind"].string ?? "upload"))])
            if let bytes = file["sizeBytes"].number { row = row.setting("detail", .string(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))) }
            if full_ { row = row.setting("actions", .array([action("attachment_remove", "Remove", confirm: "Take this file off the task?")])) }
            page.append(row)
        }
        // Time entries, newest first.
        for entry in (full["timeEntries"].elements ?? []).reversed().prefix(pageLimits.time) {
            guard let entryID = entry["id"].string else { continue }
            let running = entry["endedAt"].isNullish
            var row = object([("id", .string("time:" + entryID)), ("title", .string(running ? "Running" : CrmTime.duration(entry["seconds"].number ?? 0))),
                              ("group", .string("Time")), ("value", .string(running ? "running" : ""))])
            if let note = entry["note"].string, !note.isEmpty { row = row.setting("detail", .string(note)) }
            if let at = entry["startedAt"].string { row = row.setting("meta", object([("at", .string(at))])) }
            page.append(row)
        }
        // The activity, newest last, in the Mac's own sentences.
        let lines = (activity?["activity"].elements ?? []).filter { $0["kind"].string != "comment" }.prefix(pageLimits.activity).reversed()
        for line in lines {
            guard let lineID = line["id"].string else { continue }
            let said = activitySentence(line, names: names)
            var row = object([("id", .string("activity:" + lineID)), ("title", .string(said.text)), ("group", .string("Activity"))])
            if let at = line["createdAt"].string { row = row.setting("detail", .string(at)) }
            if let category = said.category { row = row.setting("meta", object([("category", .string(category))])) }
            page.append(row)
        }
        // The comments, oldest first: who, when, what (the same rows the phone's first comment list read).
        for comment in (thread?["comments"].elements ?? []).suffix(pageLimits.comments) {
            guard let commentID = comment["id"].string,
                  let body = comment["body"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { continue }
            var line = object([("id", .string("comment:" + commentID)), ("title", .string(comment["authorName"].string ?? "Someone")),
                               ("group", .string("Comments")), ("body", .string(String(body.prefix(2_000))))])
            if let at = comment["createdAt"].string { line = line.setting("detail", .string(at)) }
            if let kind = comment["authorKind"].string { line = line.setting("value", .string(kind)) }
            if let author = comment["authorUserId"].string { line = line.setting("meta", object([("authorId", .string(author))])) }
            page.append(line)
        }
        var answer = object([("path", .string(request.path)), ("rows", .array(Array(page.prefix(200)))), ("actions", .array([])),
                             ("view", .string(request.scope ?? "task:" + id)), ("title", .string(task["title"].string ?? ""))])
        if !trouble.isEmpty { answer = answer.setting("note", .string(trouble.joined(separator: " "))) }
        return answer
    }

    // MARK: - Doing what the phone asked

    static func requireFields(_ request: BackendRemotePanelActionRequest, allowed: Set<String>) throws {
        guard Set(request.fields.keys).isSubset(of: allowed) else { throw NativeRPCError.invalidArguments("This action received a field it does not offer.") }
    }

    /// The task an action is about: the quick actions name it, a page action is on its page, a list row is it.
    static func taskID(_ request: BackendRemotePanelActionRequest) -> String? {
        if request.action.hasPrefix("quick_") { return request.fields["task"] }
        if let view = request.panel.scope, view.hasPrefix("task:") { return String(view.dropFirst("task:".count)) }
        return request.id
    }

    /// The part a page row names (`subtask:<id>` → `<id>`), checked against its kind.
    static func part(_ request: BackendRemotePanelActionRequest, _ prefix: String) throws -> String {
        guard let id = request.id, id.hasPrefix(prefix + ":") else { throw NativeRPCError.invalidArguments("Choose a current part of this task.") }
        return String(id.dropFirst(prefix.count + 1))
    }

    static let handled: Set<String> = ["add", "comment", "quick_status", "quick_due", "quick_delete", "status", "priority", "dates", "assign", "tags", "details",
                                       "delete", "subtask_add", "subtask_done", "subtask_undo", "subtask_remove", "person_add", "person_remove",
                                       "checklist_add", "checklist_remove", "item_add", "item_done", "item_undo", "item_remove", "dependency_add",
                                       "dependency_remove", "time_start", "time_stop", "time_add", "attachment_remove"]

    /**
     * Do one of this file's actions, or nil for an action the panel's own code handles (edit, move, run).
     * The registry has already checked the action was offered on that row (or the panel) for this device.
     */
    static func act(_ request: BackendRemotePanelActionRequest, rpc: NativeRPCContext, scope: BackendINT2PhonePanelScope,
                    read: @escaping @Sendable (BackendRemotePanelRequest, NativeRPCContext) async throws -> V) async throws -> V? {
        guard handled.contains(request.action) else { return nil }
        let path = request.panel.path
        if request.action == "add" {
            try requireFields(request, allowed: ["title", "details", "project", "status", "priority", "due_date", "start_date", "assignee"])
            let projects = try await scope.projects(rpc, domain: "tasks")
            let target = request.fields["project"] ?? path
            guard projects.contains(where: { $0["path"].string == target }) else {
                throw NativeRPCError(code: "access-denied", message: "Choose one of this device's currently authorized open projects.")
            }
            var args = object([("do", .string("create")), ("project", .string(target)), ("title", .string(text(request.fields["title"]))),
                               ("details", .string(text(request.fields["details"])))])
            for key in ["status", "priority", "due_date", "start_date", "assignee"] {
                if let value = request.fields[key], !value.isEmpty { args = args.setting(key, .string(value)) }
            }
            _ = try await scope.call("tasks.local_change", arguments: args, rpc: rpc, domain: "tasks", tier: .alter, projects: [path, target])
            return try await read(request.panel, rpc).setting("notice", .string("Task added."))
        }
        guard let id = taskID(request), !id.isEmpty else { throw NativeRPCError.invalidArguments("Choose a current task first.") }
        let listed = try await scope.call("tasks.local", arguments: object([("do", .string("list")), ("project", .string(path)), ("limit", .number(200))]),
                                          rpc: rpc, domain: "tasks", projects: [path])
        guard (listed["tasks"].elements ?? []).contains(where: { $0["task"].string == id && $0["project"].string == path }) else {
            throw NativeRPCError(code: "access-denied", message: "This task is no longer in the authorized project.")
        }
        func change(_ verb: String, _ fields: [(String, V)], tier: BackendMCPTier) async throws {
            let args = object([("do", .string(verb)), ("task", .string(id)), ("project", .string(path))] + fields)
            _ = try await scope.call("tasks.local_change", arguments: args, rpc: rpc, domain: "tasks", tier: tier, projects: [path])
        }
        func parts(_ verb: String, _ fields: [(String, V)], tier: BackendMCPTier = .act) async throws {
            let args = object([("do", .string(verb)), ("task", .string(id)), ("project", .string(path))] + fields)
            _ = try await scope.call("tasks.local_parts", arguments: args, rpc: rpc, domain: "tasks", tier: tier, projects: [path])
        }
        func date(_ key: String) throws -> V {
            let value = (request.fields[key] ?? "").trimmingCharacters(in: .whitespaces)
            guard value.isEmpty || value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("A date is written like 2026-10-27.") }
            return value.isEmpty ? .null : .string(value)
        }
        var notice = "Task updated.", removed = false
        switch request.action {
        case "quick_status", "status":
            try requireFields(request, allowed: request.action == "quick_status" ? ["task", "status"] : ["status"])
            try await change("status", [("status", .string(request.fields["status"] ?? ""))], tier: .act)
        case "quick_due":
            try requireFields(request, allowed: ["task", "due_date"])
            try await change("update", [("due_date", try date("due_date"))], tier: .alter)
        case "dates":
            try requireFields(request, allowed: ["start_date", "due_date"])
            var fields: [(String, V)] = []
            if request.fields["start_date"] != nil { fields.append(("start_date", try date("start_date"))) }
            if request.fields["due_date"] != nil { fields.append(("due_date", try date("due_date"))) }
            guard !fields.isEmpty else { throw NativeRPCError.invalidArguments("Choose a date first.") }
            try await change("update", fields, tier: .alter)
        case "priority":
            try requireFields(request, allowed: ["priority"])
            let value = request.fields["priority"] ?? ""
            guard value.isEmpty || priorities.contains(value) else { throw NativeRPCError.invalidArguments("Choose Low, Medium, High, Critical or none.") }
            try await change("update", [("priority", value.isEmpty ? .null : .string(value))], tier: .alter)
        case "assign":
            try requireFields(request, allowed: ["assignee"])
            let who = request.fields["assignee"] ?? ""
            guard assignChoices(agents: listed["agents"].elements ?? []).contains(where: { $0.id == who }) else {
                throw NativeRPCError.invalidArguments("Give it to yourself, Hoot, one of your task agents, or nobody.")
            }
            try await change("assign", [("assignee", .string(who))], tier: .alter)
        case "tags":
            try requireFields(request, allowed: ["tags"])
            let tags = (request.fields["tags"] ?? "").components(separatedBy: lineBreak).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            try await change("update", [("labels", .array(tags.map(V.string)))], tier: .alter)
        case "details":
            try requireFields(request, allowed: ["details"])
            try await change("update", [("details", .string(text(request.fields["details"])))], tier: .alter)
        case "quick_delete", "delete":
            try requireFields(request, allowed: request.action == "quick_delete" ? ["task"] : [])
            try await change("delete", [], tier: .alter); notice = "Moved to the Trash."; removed = true
        case "comment":
            try requireFields(request, allowed: ["comment"])
            let said = text(request.fields["comment"])
            guard !said.isEmpty else { throw NativeRPCError.invalidArguments("Write the comment first.") }
            try await change("comment", [("text", .string(said))], tier: .act); notice = "Comment posted."
        case "subtask_add":
            try requireFields(request, allowed: ["text"])
            let title = text(request.fields["text"]).replacingOccurrences(of: "\n", with: " ")
            guard !title.isEmpty else { throw NativeRPCError.invalidArguments("Give the subtask a title.") }
            try await parts("subtask_add", [("text", .string(title))])
        case "subtask_done", "subtask_undo":
            try requireFields(request, allowed: [])
            try await parts("subtask_done", [("item", .string(try part(request, "subtask"))), ("done", .bool(request.action == "subtask_done"))])
        case "subtask_remove":
            try requireFields(request, allowed: [])
            try await parts("subtask_remove", [("item", .string(try part(request, "subtask")))])
        case "person_add":
            try requireFields(request, allowed: ["person"])
            try await parts("person_add", [("person", .string(request.fields["person"] ?? ""))], tier: .alter)
        case "person_remove":
            try requireFields(request, allowed: [])
            try await parts("person_remove", [("person", .string(try part(request, "person")))], tier: .alter)
        case "checklist_add":
            try requireFields(request, allowed: ["text"])
            try await parts("checklist_add", [("text", .string(text(request.fields["text"]).isEmpty ? "Checklist" : text(request.fields["text"])))])
        case "checklist_remove":
            try requireFields(request, allowed: [])
            try await parts("checklist_remove", [("checklist", .string(try part(request, "checklist")))])
        case "item_add":
            try requireFields(request, allowed: ["text"])
            try await parts("checklist_item_add", [("checklist", .string(try part(request, "checklist"))), ("text", .string(text(request.fields["text"])))])
        case "item_done", "item_undo":
            try requireFields(request, allowed: [])
            try await parts("checklist_item_done", [("item", .string(try part(request, "item"))), ("done", .bool(request.action == "item_done"))])
        case "item_remove":
            try requireFields(request, allowed: [])
            try await parts("checklist_item_remove", [("item", .string(try part(request, "item")))])
        case "dependency_add":
            try requireFields(request, allowed: ["kind", "other"])
            try await parts("dependency_add", [("other", .string(request.fields["other"] ?? "")), ("kind", .string(request.fields["kind"] ?? "linked"))])
        case "dependency_remove":
            try requireFields(request, allowed: [])
            let pieces = try part(request, "dep").split(separator: ":", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { throw NativeRPCError.invalidArguments("Choose a current relationship.") }
            try await parts("dependency_remove", [("other", .string(pieces[1])), ("kind", .string(pieces[0]))])
        case "time_start", "time_stop":
            try requireFields(request, allowed: [])
            try await parts(request.action, [])
        case "time_add":
            try requireFields(request, allowed: ["minutes", "note"])
            guard let minutes = Int((request.fields["minutes"] ?? "").trimmingCharacters(in: .whitespaces)), minutes > 0, minutes <= 1_440 else {
                throw NativeRPCError.invalidArguments("Enter the minutes, from 1 to 1440.")
            }
            var fields: [(String, V)] = [("duration", .string("\(minutes)m"))]
            let note = text(request.fields["note"]); if !note.isEmpty { fields.append(("note", .string(note))) }
            try await parts("time_add", fields)
        case "attachment_remove":
            try requireFields(request, allowed: [])
            try await parts("attachment_remove", [("attachment", .string(try part(request, "file")))])
        default: return nil
        }
        return try await read(answering(request.panel, removed: removed), rpc).setting("notice", .string(notice))
    }

    /// What answers an action: the page it was taken on, or, when the task itself went to the Trash from its own page,
    /// the project's list (27 Oct walk, e: re-reading the trashed task's page answered "This task is no longer in this
    /// project." after the move had worked).
    static func answering(_ panel: BackendRemotePanelRequest, removed: Bool) -> BackendRemotePanelRequest {
        guard removed, let view = panel.scope, view.hasPrefix("task:") else { return panel }
        return BackendRemotePanelRequest(path: panel.path, scope: nil, query: panel.query)
    }
}
