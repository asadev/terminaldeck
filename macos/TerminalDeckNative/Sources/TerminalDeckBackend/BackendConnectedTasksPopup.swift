import Foundation
import TerminalDeckNativeCore

/// The task popup, opened on a connected system's task. The popup is a port of the
/// reference task module's own page, so it speaks that module's function names
/// (`fetchTaskDetailBundle`, `addTaskSubtask`, …). Each one is answered here by the
/// connected system's matching tool, called as the connected person, and its answer
/// is turned back into the shape the popup reads. A function with no matching tool
/// is refused in plain words; nothing is faked locally.
///
/// Writes pass the connection's gate: Read only refuses; Ask needs the owner's yes
/// (`confirmed`). Destructive ones (archive, merge, convert, delete, delete a tag
/// everywhere) always need `confirmed`, whatever the setting.
extension BackendConnectedTasksService {
    public static let popupReads: Set<String> = ["fetchTaskLinks", "fetchTaskDetailBundle", "fetchTaskPageExtras", "listTaskFields", "fetchRoutine", "fetchTaskMore",
        "listTaskComments", "fetchCommentExtras", "listTaskActivity", "fetchDescriptionHistory", "searchTags", "openTaskFile"]
    public static let popupDestructive: Set<String> = ["setArchived", "mergeTaskInto", "convertToSubtask", "deleteTask", "deleteLabelEverywhere"]
    static let readTTL: Double = 5_000
    static let uploadLimit = 10 * 1024 * 1024

    /// One popup call: `{ok: true, …}` or `{ok: false, error}`; `needsConfirmation: true` when the gate wants a yes.
    public func popup(_ id: String, function fn: String, arguments a: [NativeRPCValue], confirmed: Bool) async -> NativeRPCValue {
        do {
            let row = try connection(id)
            guard row["enabled"].bool != false else { throw NativeRPCError(code: "off", message: "This connection is switched off.") }
            let reading = Self.popupReads.contains(fn)
            if !reading {
                try gate(row, via: .app, confirmed: confirmed, what: Self.words(fn))
                if Self.popupDestructive.contains(fn), !confirmed {
                    throw NativeRPCError(code: "needs-confirmation", message: "\(Self.words(fn).capitalizedFirst) in \(row["name"].string ?? "the system")?")
                }
            }
            let answer = try await popupCall(id, row: row, fn: fn, a)
            if !reading { await changed() }
            return answer.setting("ok", .bool(true))
        } catch let error as NativeRPCError where error.code == "needs-confirmation" {
            return .object([.init("ok", .bool(false)), .init("error", .string(error.message)), .init("needsConfirmation", .bool(true))])
        } catch {
            return .object([.init("ok", .bool(false)), .init("error", .string(error.localizedDescription))])
        }
    }

    static func words(_ fn: String) -> String {
        switch fn {
        case "setTaskStatus": "change the status"
        case "updateTask": "change the task"
        case "setArchived": "archive or restore this task"
        case "mergeTaskInto": "merge this task into another"
        case "convertToSubtask": "turn this task into a subtask"
        case "deleteTask": "delete this task"
        case "deleteLabelEverywhere": "delete this tag from every task"
        case "addTaskComment", "addTaskCommentWith": "a comment"
        default: "changes made in this task"
        }
    }

    // MARK: Reads, shared by the popup's parallel loads

    func read(_ id: String, row: NativeRPCValue, _ tool: String, _ task: String, extra: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
        let key = id + "|" + tool + "|" + task
        if let hit = reads[key], now() - hit.at < Self.readTTL { return hit.value }
        let answer = try await client(id, row: row).call(tool, .object([.init("task_id", .string(task))] + extra))
        let at = now()
        reads = reads.filter { at - $0.value.at < Self.readTTL } // a read past its few seconds is never used again
        reads[key] = (at, answer.data)
        learn(id, task, answer.data)
        if tool == "get_task", let detail = BackendConnectedTasksMapping.detail(answer.data, me: row["me"]["id"].string) { keep(id, detail) }
        return answer.data
    }

    /// Remembers which task each sub-id belongs to, so id-only functions can find their task.
    func learn(_ id: String, _ task: String, _ data: NativeRPCValue) {
        var subs = (data["subtasks"].elements ?? []).compactMap { $0["id"].string }
        for list in data["checklists"].elements ?? [] {
            if let list = list["id"].string { subs.append(list) }
            subs += (list["items"].elements ?? []).compactMap { $0["id"].string }
        }
        subs += (data["fields"].elements ?? []).compactMap { $0["id"].string }
        subs += (data["attachments"].elements ?? []).compactMap { $0["id"].string }
        subs += (data["page"]["time_entries"].elements ?? []).compactMap { $0["id"].string }
        own(id, subs, task)
    }

    /// Files sub-ids under their task; that task becomes the newest, and the oldest past `ownersTasks` are dropped.
    func own(_ id: String, _ subs: [String], _ task: String) {
        guard !subs.isEmpty else { return }
        var known = owners[id] ?? [], ids = Set(subs)
        if let index = known.firstIndex(where: { $0.task == task }) { ids.formUnion(known.remove(at: index).ids) }
        known.append((task, ids))
        owners[id] = Array(known.suffix(Self.ownersTasks))
    }

    func ownerTask(_ id: String, _ sub: String) -> String? {
        owners[id]?.last { $0.ids.contains(sub) }?.task
    }

    func forget(_ id: String, _ task: String?) {
        if let task { reads = reads.filter { !$0.key.hasPrefix(id + "|") || !$0.key.hasSuffix("|" + task) } } else { reads = reads.filter { !$0.key.hasPrefix(id + "|") } }
    }

    func owner(_ id: String, _ sub: String) throws -> String {
        guard let task = ownerTask(id, sub) ?? draftLists[sub]?.task else { throw NativeRPCError.invalidArguments("That item is not on a task that was opened here. Reopen the task and try again.") }
        return task
    }

    // MARK: Shapes the popup reads

    func personWire(_ value: NativeRPCValue) -> NativeRPCValue {
        guard let id = value["id"].string else { return .null }
        let name = value["name"].string ?? teamName(id) ?? "Unknown"
        return BackendCrmWire.person(BackendCrmPeople.toAssignee(.init(id: id, name: name)))
    }
    func teamName(_ id: String) -> String? { nil }
    func idOfName(_ connection: String, _ name: String?) -> String? {
        guard let name else { return nil }
        return people[connection]?["people"].elements?.first { $0["name"].string == name }?["id"].string
    }

    static func iso(_ value: NativeRPCValue) -> NativeRPCValue { value.string.map(NativeRPCValue.string) ?? .null }

    func bundle(_ d: NativeRPCValue) -> NativeRPCValue {
        let subtasks = (d["subtasks"].elements ?? []).enumerated().map { i, s in
            NativeRPCValue.object([.init("id", s["id"]), .init("title", .string(s["title"].string ?? "")), .init("done", .bool(s["done"].bool == true)),
                                   .init("sortOrder", .number(Double(i))), .init("assigneeUserId", Self.iso(s["assignee"]["id"]))])
        }
        let lists = (d["checklists"].elements ?? []).enumerated().map { i, l in
            NativeRPCValue.object([.init("id", l["id"]), .init("title", .string(l["title"].string ?? "Checklist")), .init("sortOrder", .number(Double(i))),
                .init("items", .array((l["items"].elements ?? []).enumerated().map { j, item in
                    .object([.init("id", item["id"]), .init("title", .string(item["title"].string ?? "")), .init("done", .bool(item["done"].bool == true)),
                             .init("sortOrder", .number(Double(j))), .init("assigneeUserId", Self.iso(item["assignee"]["id"]))])
                }))])
        }
        let deps = (d["dependencies"].elements ?? []).compactMap { dep -> NativeRPCValue? in
            guard let kind = dep["kind"].string, let other = dep["task_id"].string else { return nil }
            return .object([.init("kind", .string(kind)), .init("otherTaskId", .string(other)), .init("otherTitle", .string(dep["title"].string ?? "Task")),
                            .init("otherDone", .bool(dep["done"].bool == true))])
        }
        let files = (d["attachments"].elements ?? []).map { f in
            NativeRPCValue.object([.init("id", f["id"]), .init("kind", .string(f["kind"].string ?? "upload")), .init("fileName", .string(f["file_name"].string ?? "file")),
                .init("mimeType", Self.iso(f["mime_type"])), .init("sizeBytes", f["size_bytes"].number.map(NativeRPCValue.number) ?? .null),
                .init("documentId", Self.iso(f["document_id"])), .init("storagePath", .null), .init("uploadedBy", Self.iso(f["uploaded_by"])),
                .init("createdAt", .string(f["created_at"].string ?? ""))])
        }
        let others = (d["people"]["others"].elements ?? []).map(personWire).filter { $0 != .null }
        return .object([.init("people", .object([.init("primary", personWire(d["people"]["main"])), .init("others", .array(others))])),
                        .init("subtasks", .array(subtasks)), .init("checklists", .array(lists)), .init("dependencies", .array(deps)), .init("attachments", .array(files))])
    }

    func timeEntry(_ e: NativeRPCValue, me: String?) -> NativeRPCValue {
        .object([.init("id", e["id"]), .init("userId", .string(e["by"]["id"].string ?? e["user_id"].string ?? me ?? "")), .init("startedAt", .string(e["started_at"].string ?? "")),
                 .init("endedAt", Self.iso(e["ended_at"])), .init("seconds", e["seconds"].number.map(NativeRPCValue.number) ?? .null),
                 .init("note", Self.iso(e["note"])), .init("billable", .bool(e["billable"].bool == true))])
    }

    func extras(_ d: NativeRPCValue, me: String?) -> NativeRPCValue {
        let page = d["page"]
        let meta = (d["subtasks"].elements ?? []).compactMap { s -> NativeRPCValue.Field? in
            guard let id = s["id"].string, s["priority"].string != nil || s["due_date"].string != nil else { return nil }
            return .init(id, .object([.init("priority", Self.iso(s["priority"])), .init("dueDate", Self.iso(s["due_date"]))]))
        }
        return .object([.init("taskType", .string(page["type"].string ?? "task")), .init("labels", page["labels"].elements.map(NativeRPCValue.array) ?? .array([])),
                        .init("estimateMinutes", page["time_estimate_minutes"].number.map(NativeRPCValue.number) ?? .null),
                        .init("recurrenceRule", page["recurrence_rule"].isNullish ? .null : page["recurrence_rule"]),
                        .init("timeEntries", .array((page["time_entries"].elements ?? []).map { timeEntry($0, me: me) })), .init("subtaskMeta", .object(meta))])
    }

    func fieldWire(_ f: NativeRPCValue, task: String) -> NativeRPCValue {
        var config = f["config"].fields != nil ? f["config"] : NativeRPCValue.object([])
        if let options = f["options"].elements, !config.has("options") { config = config.setting("options", .array(options)) }
        return .object([.init("id", f["id"]), .init("taskId", .string(task)), .init("label", .string(f["label"].string ?? "Field")),
                        .init("kind", .string(f["kind"].string ?? "text")), .init("config", config), .init("value", f["value"].isNullish ? .null : f["value"]),
                        .init("sortOrder", f["sort_order"].number.map(NativeRPCValue.number) ?? .null), .init("createdBy", .null),
                        .init("createdAt", .string(f["created_at"].string ?? "")), .init("updatedAt", Self.iso(f["updated_at"]))])
    }

    static let ruleKeys: [(String, String)] = [("frequency", "frequency"), ("interval", "interval"), ("unit", "unit"), ("weekdays", "weekdays"),
        ("monthly", "monthly"), ("trigger", "trigger"), ("trigger_status", "triggerStatus"), ("time_of_day", "timeOfDay"), ("ends", "ends"),
        ("create_new", "createNew"), ("update_status_to", "updateStatusTo"), ("sync_to_due", "syncToDue"), ("skip_weekends", "skipWeekends"),
        ("per_assignee", "perAssignee"), ("missed_policy", "missedPolicy"), ("paused_at", "pausedAt"), ("stopped_at", "stoppedAt"), ("starts", "anchor")]

    func routine(_ r: NativeRPCValue, connection: String) -> NativeRPCValue {
        var rule = NativeRPCValue.null
        if r["rule"].fields != nil {
            rule = .object(Self.ruleKeys.compactMap { snake, camel in r["rule"].has(snake) ? .init(camel, r["rule"][snake]) : nil })
        }
        let history: NativeRPCValue = r["history"].elements.map { rows in
            .array(rows.enumerated().map { i, h in
                .object([.init("id", .string(h["task_id"].string ?? "h\(i)")), .init("occurrenceDate", .string(h["date"].string ?? "")),
                         .init("dueDate", Self.iso(h["due_date"])), .init("assigneeUserId", Self.iso(h["who"]["id"])), .init("spawnedTaskId", Self.iso(h["task_id"])),
                         .init("status", .string(h["status"].string ?? "")), .init("completedAt", Self.iso(h["completed_at"])), .init("completedBy", .null),
                         .init("who", Self.iso(h["who"]["name"]))])
            })
        } ?? .null
        return .object([.init("rootTaskId", .string(r["task_id"].string ?? "")), .init("rootTitle", .string(r["title"].string ?? "")),
                        .init("isRoot", .bool(r["is_routine_task"].bool == true)), .init("rule", rule), .init("canEdit", .bool(r["can_edit"].bool == true)),
                        .init("history", history), .init("historyError", Self.iso(r["history_note"])),
                        .init("lastError", r["last_error"].fields != nil ? r["last_error"] : .null),
                        .init("next", r["next"].elements.map(NativeRPCValue.array) ?? .array([])), .init("peopleCount", .number(r["people_count"].number ?? 1)),
                        .init("version", r["version"].number.map(NativeRPCValue.number) ?? .null), .init("stuck", .null), .init("canRestart", .bool(false)),
                        .init("anchor", Self.iso(r["rule"]["starts"])), .init("occurrence", .null), .init("datesSoFar", .number(Double(r["history"].elements?.count ?? 0)))])
    }

    func more(_ m: NativeRPCValue) -> NativeRPCValue {
        .object([.init("followers", .array((m["followers"].elements ?? []).compactMap { f in
                    f["id"].string.map { NativeRPCValue.object([.init("userId", .string($0)), .init("since", Self.iso(f["since"]))]) } })),
                 .init("iFollow", .bool(m["i_follow"].bool == true)),
                 .init("reminders", .array((m["my_reminders"].elements ?? []).compactMap { r in
                    r["id"].string.map { NativeRPCValue.object([.init("id", .string($0)), .init("remindAt", .string(r["remind_at"].string ?? r["at"].string ?? "")), .init("note", Self.iso(r["note"]))]) } })),
                 .init("archivedAt", Self.iso(m["archived_at"])), .init("startTime", Self.iso(m["start_time"])), .init("dueTime", Self.iso(m["due_time"])),
                 .init("syncSubtaskDates", .bool(m["sync_subtask_dates"].bool == true)),
                 .init("labelColors", m["tag_colors"].fields != nil ? m["tag_colors"] : .object([])),
                 .init("entryTags", m["time_entry_tags"].fields != nil ? m["time_entry_tags"] : .object([])),
                 .init("remindersLive", .bool(m["reminders_available"].bool == true)), .init("canColorTags", .bool(m["can_color_tags"].bool == true)),
                 .init("canRemoveFollowers", .bool(m["can_remove_followers"].bool ?? false))])
    }

    func comments(_ c: NativeRPCValue, task: String) -> NativeRPCValue {
        .array((c["comments"].elements ?? []).compactMap { m in
            guard let id = m["id"].string else { return nil }
            let author = BackendCrmPeople.toAssignee(.init(id: m["by"]["id"].string ?? id, name: m["by"]["name"].string ?? "Someone"))
            return .object([.init("id", .string(id)), .init("taskId", .string(task)), .init("authorUserId", Self.iso(m["by"]["id"])),
                            .init("authorName", .string(author.name)), .init("authorInitials", .string(author.initials)), .init("authorColor", .string(author.color)),
                            .init("body", .string(m["body"].string ?? "")), .init("createdAt", .string(m["at"].string ?? ""))])
        })
    }

    func commentExtras(_ c: NativeRPCValue, connection: String) -> NativeRPCValue {
        var meta: [NativeRPCValue.Field] = [], reactions: [NativeRPCValue.Field] = []
        for m in c["comments"].elements ?? [] {
            guard let id = m["id"].string else { continue }
            var row: [NativeRPCValue.Field] = [.init("parentId", Self.iso(m["reply_to"])), .init("resolvedAt", Self.iso(m["resolved"]["at"])),
                .init("resolvedBy", Self.iso(m["resolved"]["by"]["id"])), .init("assigneeUserId", Self.iso(m["assigned_to"]["id"])),
                .init("scheduledFor", Self.iso(m["scheduled_for"]))]
            if m["withdrawn"].fields != nil { row.append(.init("withdrawn", m["withdrawn"])) }
            if m["status"].string == "waiting" { row.append(.init("deliveredAt", .null)) }
            meta.append(.init(id, .object(row)))
            let list = (m["reactions"].elements ?? []).compactMap { r -> NativeRPCValue? in
                guard let emoji = r["emoji"].string else { return nil }
                let ids = (r["people"].elements ?? []).compactMap { $0.string }.map { idOfName(connection, $0) ?? $0 }
                return .object([.init("emoji", .string(emoji)), .init("userIds", .array(ids.map(NativeRPCValue.string)))])
            }
            if !list.isEmpty { reactions.append(.init(id, .array(list))) }
        }
        return .object([.init("meta", .object(meta)), .init("reactions", .object(reactions))])
    }

    func activity(_ a: NativeRPCValue, task: String, connection: String) -> NativeRPCValue {
        let rows = (a["activity"].elements ?? []).enumerated().map { i, r -> NativeRPCValue in
            let byName = r["by"].string ?? r["by"]["name"].string
            let byID = r["by"]["id"].string ?? idOfName(connection, byName)
            let actor = byName.map { BackendCrmWire.person(BackendCrmPeople.toAssignee(.init(id: byID ?? $0, name: $0))) } ?? .null
            return .object([.init("id", .string("\(task)-a\(i)-\(r["at"].string ?? "")")), .init("taskId", .string(task)), .init("kind", .string(r["kind"].string ?? "changed")),
                            .init("payload", r["detail"].fields != nil ? r["detail"] : .object([])), .init("actor", actor),
                            .init("actorUserId", byID.map(NativeRPCValue.string) ?? .null), .init("createdAt", .string(r["at"].string ?? ""))])
        }.sorted { ($0["createdAt"].string ?? "") < ($1["createdAt"].string ?? "") }
        return .object([.init("rows", .array(rows)), .init("total", .number(a["total"].number ?? Double(rows.count)))])
    }

    // MARK: The functions

    func popupCall(_ id: String, row: NativeRPCValue, fn: String, _ a: [NativeRPCValue]) async throws -> NativeRPCValue {
        func arg(_ i: Int) -> NativeRPCValue { i < a.count ? a[i] : .missing }
        func text(_ i: Int) throws -> String { try arg(i).requireString("argument \(i + 1)", nonempty: true) }
        let me = row["me"]["id"].string, client = try client(id, row: row)
        func send(_ tool: String, _ args: [(String, NativeRPCValue)], task: String?) async throws -> NativeRPCValue {
            let answer = try await client.call(tool, .object(args.map { .init($0.0, $0.1) }))
            forget(id, task)
            return answer.data
        }
        func task(_ remote: String) async throws -> NativeRPCValue { try await read(id, row: row, "get_task", remote) }
        func result(_ pairs: [(String, NativeRPCValue)] = []) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
        func person(_ value: NativeRPCValue) -> NativeRPCValue { value.isNullish ? .null : value }
        func firstString(_ data: NativeRPCValue, _ keys: [String]) -> NativeRPCValue {
            for key in keys { if let value = data[key].string { return .string(value) } }
            return .null
        }

        switch fn {
        // Reads
        case "fetchTaskDetailBundle": return result([("bundle", bundle(try await task(try text(0))))])
        case "fetchTaskPageExtras": return result([("extras", extras(try await task(try text(0)), me: me))])
        case "listTaskFields":
            let remote = try text(0), d = try await task(remote)
            let fields = (d["fields"].elements ?? []).map { fieldWire($0, task: remote) }
            var named: [NativeRPCValue.Field] = []
            for p in people[id]?["people"].elements ?? [] { if let pid = p["id"].string { named.append(.init(pid, personWire(p))) } }
            let subtasks = d["subtasks"].elements ?? [], items = (d["checklists"].elements ?? []).flatMap { $0["items"].elements ?? [] }
            let auto = NativeRPCValue.object([.init("subtasks", .object([.init("done", .number(Double(subtasks.filter { $0["done"].bool == true }.count))), .init("total", .number(Double(subtasks.count)))])),
                                              .init("checklists", .object([.init("done", .number(Double(items.filter { $0["done"].bool == true }.count))), .init("total", .number(Double(items.count)))]))])
            return result([("fields", .array(fields)), ("people", .object(named)), ("auto", auto), ("viewerId", me.map(NativeRPCValue.string) ?? .null)])
        case "fetchRoutine": return result([("routine", routine(try await read(id, row: row, "get_routine", try text(0)), connection: id))])
        case "fetchTaskMore": return result([("more", more(try await read(id, row: row, "get_task_more", try text(0))))])
        case "listTaskComments":
            let remote = try text(0)
            return result([("comments", comments(try await read(id, row: row, "list_comments", remote), task: remote))])
        case "fetchCommentExtras": return result([("extras", commentExtras(try await read(id, row: row, "list_comments", try text(0)), connection: id))])
        case "listTaskActivity":
            let remote = try text(0)
            let a = try await read(id, row: row, "get_task_activity", remote, extra: [.init("limit", .number(500))])
            let shaped = activity(a, task: remote, connection: id)
            return result([("rows", shaped["rows"]), ("total", shaped["total"])])
        case "fetchDescriptionHistory":
            let h = try await read(id, row: row, "get_description_history", try text(0))
            return result([("versions", .array((h["versions"].elements ?? []).map { v in
                .object([.init("at", .string(v["at"].string ?? "")), .init("by", Self.iso(v["by"]["name"].isNullish ? v["by"] : v["by"]["name"])),
                         .init("from", Self.iso(v["from"])), .init("to", Self.iso(v["to"]))]) }))])
        case "fetchTaskLinks":
            let profile = try await relatedProfile(id)
            let d = try await task(try text(0))
            let links = (d["task"]["related"].elements ?? []).compactMap { l -> NativeRPCValue? in
                guard let area = l["area"].string, let rid = l["id"].string else { return nil }
                return .object([.init("area", .string(area)), .init("id", .string(rid)), .init("label", .string(l["label"].string ?? rid)), .init("href", .string(""))])
            }
            let areas = profile.relatedAreas.filter { profile.search[$0] != nil }
            return result([("links", .array(links)), ("areas", .array(areas.map(NativeRPCValue.string))),
                           ("supported", .bool(profile.relatedArgument != nil && d["task"].has("related")))])
        case "searchTags":
            let profile = try await relatedProfile(id), area = try text(0)
            let query = (arg(1).string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let tool = profile.search[area], query.count >= 2 else { return result([("hits", .array([]))]) }
            return result([("hits", .array(try await searchRecords(id, client: client, tool: tool, area: area, query: query)))])
        case "openTaskFile":
            let remote = try text(0), file = try text(1)
            let link = try await client.call("get_task_file_link", .object([.init("task_id", .string(remote)), .init("attachment_id", .string(file))])).data
            guard let address = firstString(link, ["url", "link", "signed_url"]).string, let url = URL(string: address), url.scheme == "https" else {
                throw NativeRPCError(code: "refused", message: "The system gave no link for that file.")
            }
            if let openURL { await openURL(url) }
            return result([("url", .string(address))])

        // The task itself
        case "setTaskStatus":
            let remote = try text(0)
            _ = try await send("set_task_status", [("task_id", .string(remote)), ("status", .string(try text(1)))], task: remote)
            _ = try? await task(remote); return result()
        case "updateTask":
            let remote = try text(0), body = try arg(1).requireObject("change")
            if body.has("recurrence") { throw NativeRPCError(code: "not-offered", message: "Change how it repeats in the Recurring panel.") }
            var args: [(String, NativeRPCValue)] = [("task_id", .string(remote))]
            for (from, to) in [("title", "text"), ("description", "description"), ("priority", "priority"), ("startDate", "start_date"), ("dueDate", "due_date")] where body.has(from) {
                args.append((to, from.hasSuffix("Date") ? .string(body[from].string ?? "") : body[from]))
            }
            _ = try await send("update_task", args, task: remote)
            _ = try? await task(remote); return result()
        case "assignTask":
            let remote = try text(0)
            _ = try await send("update_task", [("task_id", .string(remote)), ("assignee", .string(try text(1))), ("confirm", .bool(true))], task: remote)
            _ = try? await task(remote); return result()
        case "addTaskAssignee", "removeTaskAssignee":
            let remote = try text(0)
            _ = try await send(fn == "addTaskAssignee" ? "add_assignee" : "remove_assignee",
                               [("task_id", .string(remote)), ("person", .string(try text(1)))] + (fn == "removeTaskAssignee" ? [("confirm", .bool(true))] : []), task: remote)
            return result()
        case "setTaskType":
            let remote = try text(0); _ = try await send("set_task_type", [("task_id", .string(remote)), ("type", .string(try text(1)))], task: remote); return result()
        case "setTaskLabels":
            let remote = try text(0)
            _ = try await send("update_task", [("task_id", .string(remote)), ("labels", .array(try arg(1).requireArray("labels"))), ("confirm", .bool(true))], task: remote)
            _ = try? await task(remote); return result()
        case "setTaskLinks":
            let remote = try text(0)
            let related = try arg(1).requireArray("links").map { l in NativeRPCValue.object([.init("area", l["area"]), .init("id", l["id"]), .init("label", l["label"])]) }
            let argument = try await relatedProfile(id).relatedArgument ?? "related"
            _ = try await send("update_task", [("task_id", .string(remote)), (argument, .array(related)), ("confirm", .bool(true))], task: remote)
            _ = try? await task(remote); return result()
        case "moveTask":
            let remote = try text(0); _ = try await send("update_task", [("task_id", .string(remote)), ("board", .string(try text(1)))], task: remote)
            _ = try? await task(remote); return result()
        case "setTimeEstimate":
            let remote = try text(0)
            _ = try await send("update_task", [("task_id", .string(remote)), ("time_estimate_minutes", arg(1).number.map { .number($0.rounded()) } ?? .null)], task: remote); return result()
        case "setTaskTimes":
            let remote = try text(0), body = arg(1)
            var args: [(String, NativeRPCValue)] = [("task_id", .string(remote))]
            if body.has("startTime") { args.append(("start_time", body["startTime"].isNullish ? .null : body["startTime"])) }
            if body.has("dueTime") { args.append(("due_time", body["dueTime"].isNullish ? .null : body["dueTime"])) }
            _ = try await send("set_task_times", args, task: remote); return result()
        case "setSyncSubtaskDates":
            let remote = try text(0)
            _ = try await send("set_sync_subtask_dates", [("task_id", .string(remote)), ("on", .bool(arg(1).bool == true))], task: remote)
            let d = try await task(remote)
            return result([("startDate", Self.iso(d["task"]["start_date"])), ("dueDate", Self.iso(d["task"]["due_date"]))])
        case "setArchived":
            let remote = try text(0); _ = try await send("archive_task", [("task_id", .string(remote)), ("archived", .bool(arg(1).bool == true))], task: remote); return result()
        case "mergeTaskInto":
            let remote = try text(0)
            _ = try await send("merge_task", [("task_id", .string(remote)), ("into_task_id", .string(try text(1))), ("confirm", .bool(true))], task: remote); return result()
        case "convertToSubtask":
            let remote = try text(0)
            _ = try await send("convert_to_subtask", [("task_id", .string(remote)), ("parent_task_id", .string(try text(1))), ("confirm", .bool(true))], task: remote); return result()
        case "deleteTask":
            let remote = try text(0); _ = try await send("delete_task", [("task_id", .string(remote)), ("confirm", .bool(true))], task: remote); return result()
        case "duplicateTask":
            let remote = try text(0), data = try await send("duplicate_task", [("task_id", .string(remote))], task: nil)
            return result([("id", firstString(data, ["new_task_id", "task_id", "id", "copy_id"]))])

        // Subtasks
        case "addTaskSubtask":
            let remote = try text(0), data = try await send("add_subtask", [("task_id", .string(remote)), ("title", .string(try text(1)))], task: remote)
            let sub = firstString(data, ["subtask_id", "id"]); if let s = sub.string { own(id, [s], remote) }
            return result([("id", sub)])
        case "setTaskSubtaskDone":
            let remote = try text(0)
            _ = try await send("set_subtask_done", [("task_id", .string(remote)), ("subtask_id", .string(try text(1))), ("done", .bool(arg(2).bool == true))], task: remote); return result()
        case "deleteTaskSubtask", "setTaskSubtaskAssignee", "setSubtaskMeta":
            let remote = try text(0)
            var args: [(String, NativeRPCValue)] = [("task_id", .string(remote)), ("subtask_id", .string(try text(1)))]
            switch fn {
            case "deleteTaskSubtask": args += [("action", .string("delete")), ("confirm", .bool(true))]
            case "setTaskSubtaskAssignee": args += [("action", .string("assign")), ("person", person(arg(2)))]
            default:
                args.append(("action", .string("set_details")))
                if arg(2).has("priority") { args.append(("priority", person(arg(2)["priority"]))) }
                if arg(2).has("dueDate") { args.append(("due_date", person(arg(2)["dueDate"]))) }
            }
            _ = try await send("edit_subtask", args, task: remote); return result()

        // Checklists (the system makes a list together with its first item)
        case "addChecklist":
            let remote = try text(0), draft = "draft-list-" + UUID().uuidString.lowercased()
            let title = (arg(1).string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            draftLists[draft] = (remote, title.isEmpty ? "Checklist" : String(title.prefix(200)))
            return result([("id", .string(draft))])
        case "addChecklistItem":
            let list = try text(0), item = try text(1)
            var args: [(String, NativeRPCValue)] = [("text", .string(item))], remote: String
            if let draft = draftLists[list] {
                remote = draft.task; args += [("task_id", .string(remote)), ("new_checklist", .string(draft.title))]
            } else {
                remote = try owner(id, list); args += [("task_id", .string(remote)), ("checklist_id", .string(list))]
            }
            let data = try await send("add_checklist_item", args, task: remote)
            draftLists[list] = nil
            let itemID = firstString(data, ["item_id", "id"]); if let i = itemID.string { own(id, [i], remote) }
            if let made = data["checklist_id"].string { own(id, [made], remote) }
            return result([("id", itemID)])
        case "renameChecklist":
            let list = try text(0)
            if let draft = draftLists[list] { draftLists[list] = (draft.task, (arg(1).string ?? draft.title)); return result() }
            _ = try await send("edit_checklist", [("action", .string("rename")), ("checklist_id", .string(list)), ("title", .string(arg(1).string ?? "Checklist"))], task: ownerTask(id, list)); return result()
        case "deleteChecklist":
            let list = try text(0)
            if draftLists.removeValue(forKey: list) != nil { return result() }
            _ = try await send("edit_checklist", [("action", .string("delete")), ("checklist_id", .string(list)), ("confirm", .bool(true))], task: ownerTask(id, list)); return result()
        case "setChecklistItemDone":
            let item = try text(0); _ = try await send("set_checklist_item_done", [("item_id", .string(item)), ("done", .bool(arg(1).bool == true))], task: ownerTask(id, item)); return result()
        case "setChecklistItemAssignee":
            let item = try text(0)
            _ = try await send("edit_checklist", [("action", .string("assign_item")), ("item_id", .string(item)), ("person", person(arg(1)))], task: ownerTask(id, item)); return result()
        case "deleteChecklistItem":
            let item = try text(0)
            _ = try await send("edit_checklist", [("action", .string("delete_item")), ("item_id", .string(item)), ("confirm", .bool(true))], task: ownerTask(id, item)); return result()

        // Dependencies and files
        case "addTaskDependency", "removeTaskDependency":
            let remote = try text(0)
            _ = try await send("edit_dependency", [("task_id", .string(remote)), ("other_task_id", .string(try text(1))), ("kind", .string(try text(2))),
                                                   ("action", .string(fn == "addTaskDependency" ? "add" : "remove"))] + (fn == "removeTaskDependency" ? [("confirm", .bool(true))] : []), task: remote)
            return result()
        case "attachExistingDocument":
            let remote = try text(0); _ = try await send("attach_document", [("task_id", .string(remote)), ("document_id", .string(try text(1)))], task: remote); return result()
        case "detachTaskAttachment":
            let file = try text(0); _ = try await send("remove_attachment", [("attachment_id", .string(file)), ("confirm", .bool(true))], task: ownerTask(id, file)); return result()
        case "uploadTaskFile":
            let remote = try text(0), input = try arg(1).requireObject("file")
            guard let name = input["name"].string, let bytes = input["bytes"].bytesValue else { throw NativeRPCError.invalidArguments("The file could not be read.") }
            return result([("attachment", try await upload(id, client: client, task: remote, name: name, bytes: bytes))])
        case "chooseTaskFiles":
            let remote = try text(0)
            guard let chooseFiles else { throw NativeRPCError(code: "not-offered", message: "Files cannot be picked here.") }
            // Every pick is read and size-checked before any is sent, so one big file never leaves the rest half attached.
            let picked = try await chooseFiles().prefix(10).map { (name: $0.lastPathComponent, bytes: try Data(contentsOf: $0, options: .mappedIfSafe)) }
            let big = picked.filter { $0.bytes.count > Self.uploadLimit }.map(\.name)
            guard big.isEmpty else {
                throw NativeRPCError.invalidArguments(big.joined(separator: ", ") + (big.count == 1 ? " is" : " are") + " over 10 MB, so nothing was attached.")
            }
            var added: [NativeRPCValue] = []
            for file in picked {
                do { added.append(try await upload(id, client: client, task: remote, name: file.name, bytes: file.bytes)) }
                catch where !added.isEmpty {
                    let attached = picked.prefix(added.count).map(\.name).joined(separator: ", "), rest = picked.dropFirst(added.count).map(\.name).joined(separator: ", ")
                    throw NativeRPCError(code: (error as? NativeRPCError)?.code ?? "failed",
                                         message: "Attached \(attached); not attached: \(rest) (\(error.localizedDescription)).")
                }
            }
            return result([("attachments", .array(added))])

        // Comments
        case "addTaskComment", "addTaskCommentWith":
            let remote = try text(0), options = arg(2)
            var args: [(String, NativeRPCValue)] = [("task_id", .string(remote)), ("body", .string(try text(1)))]
            if let parent = options["parentId"].string { args.append(("reply_to", .string(parent))) }
            if let who = options["assigneeUserId"].string { args.append(("assign_to", .string(who))) }
            if let when = options["scheduledFor"].string { args.append(("schedule_for", .string(when))) }
            let data = try await send("add_comment", args, task: remote)
            return result([("id", firstString(data, ["comment_id", "id"]))])
        case "toggleCommentReaction", "setCommentResolved", "assignComment", "sendScheduledNow":
            let remote = try text(0), comment = try text(1)
            var args: [(String, NativeRPCValue)] = [("task_id", .string(remote)), ("comment_id", .string(comment))]
            switch fn {
            case "toggleCommentReaction": args += [("action", .string("react")), ("emoji", .string(try text(2)))]
            case "setCommentResolved": args.append(("action", .string(arg(2).bool == true ? "resolve" : "reopen")))
            case "assignComment": args += arg(2).isNullish ? [("action", .string("unassign"))] : [("action", .string("assign")), ("person", .string(try text(2)))]
            default: args.append(("action", .string("send_now")))
            }
            _ = try await send("comment_action", args, task: remote); return result()

        // Time
        case "startTaskTimer", "stopTaskTimer":
            let remote = try text(0)
            _ = try await send("task_timer", [("task_id", .string(remote)), ("action", .string(fn == "startTaskTimer" ? "start" : "stop"))], task: remote)
            let entries = (try await task(remote))["page"]["time_entries"].elements ?? []
            let mine = entries.filter { $0["by"]["id"].string == me }
            let entry = fn == "startTaskTimer" ? mine.last { $0["ended_at"].isNullish } : mine.filter { !$0["ended_at"].isNullish }.max { ($0["ended_at"].string ?? "") < ($1["ended_at"].string ?? "") }
            return result([("entry", entry.map { timeEntry($0, me: me) } ?? .null)])
        case "addTaskTimeEntry":
            let remote = try text(0), input = arg(1)
            let seconds = input["seconds"].number ?? input["seconds"].string.flatMap(Double.init) ?? 0
            guard seconds >= 60, seconds <= 86_400 else { throw NativeRPCError.invalidArguments("Enter a time between 1 minute and 24 hours") }
            let minutes = Int((seconds / 60).rounded())
            var args: [(String, NativeRPCValue)] = [("task_id", .string(remote)), ("duration", .string(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"))]
            if let day = input["date"].string { args.append(("date", .string(day))) }
            if let note = input["note"].string, !note.isEmpty { args.append(("note", .string(note))) }
            if let billable = input["billable"].bool { args.append(("billable", .bool(billable))) }
            let data = try await send("log_time", args, task: remote)
            let entryID = firstString(data, ["entry_id", "id"]).string
            let entries = (try await task(remote))["page"]["time_entries"].elements ?? []
            return result([("entry", entries.first { $0["id"].string == entryID }.map { timeEntry($0, me: me) } ?? .null)])
        case "deleteTaskTimeEntry":
            let remote = try text(0)
            _ = try await send("delete_time_entry", [("task_id", .string(remote)), ("entry_id", .string(try text(1))), ("confirm", .bool(true))], task: remote); return result()
        case "setTimeEntryTags":
            let remote = try text(0), tags = try arg(2).requireArray("tags")
            let data = try await send("set_time_entry_tags", [("task_id", .string(remote)), ("entry_id", .string(try text(1))), ("tags", .array(tags))], task: remote)
            return result([("tags", data["tags"].elements.map(NativeRPCValue.array) ?? .array(tags))])

        // Follow, remind, tags
        case "setFollowing":
            let remote = try text(0)
            _ = try await send("task_followers", [("task_id", .string(remote)), ("action", .string(arg(1).bool == true ? "follow" : "unfollow"))], task: remote); return result()
        case "addFollower", "removeFollower":
            let remote = try text(0)
            _ = try await send("task_followers", [("task_id", .string(remote)), ("action", .string(fn == "addFollower" ? "add" : "remove")), ("person", .string(try text(1)))]
                               + (fn == "removeFollower" ? [("confirm", .bool(true))] : []), task: remote); return result()
        case "setReminder":
            let remote = try text(0)
            let data = try await send("task_reminder", [("task_id", .string(remote)), ("action", .string("set")), ("remind_at", .string(try text(1)))], task: remote)
            return result([("id", firstString(data, ["reminder_id", "id"]))])
        case "clearReminder":
            let remote = try text(0)
            _ = try await send("task_reminder", [("task_id", .string(remote)), ("action", .string("clear")), ("reminder_id", .string(try text(1)))], task: remote); return result()
        case "setLabelColor":
            _ = try await send("set_label_color", [("label", .string(try text(0))), ("color", .string(try text(1)))], task: nil); return result()
        case "deleteLabelEverywhere":
            _ = try await send("delete_label_everywhere", [("label", .string(try text(0))), ("confirm", .bool(true))], task: nil); return result()

        // Routines
        case "saveRoutine":
            let remote = try text(0)
            if arg(1).isNullish {
                _ = try await send("stop_routine", [("task_id", .string(remote)), ("confirm", .bool(true))], task: remote); return result()
            }
            var args: [(String, NativeRPCValue)] = [("task_id", .string(remote)), ("version", arg(2).isNullish ? .null : arg(2))]
            for (snake, camel) in Self.ruleKeys where !["paused_at", "stopped_at", "starts"].contains(snake) && arg(1).has(camel) {
                args.append((snake, arg(1)[camel]))
            }
            _ = try await send("set_routine", args, task: remote); return result()
        case "pauseRoutine":
            let remote = try text(0); _ = try await send("pause_routine", [("task_id", .string(remote)), ("paused", .bool(arg(1).bool == true))], task: remote); return result()
        case "stopRoutine":
            let remote = try text(0); _ = try await send("stop_routine", [("task_id", .string(remote)), ("confirm", .bool(true))], task: remote); return result()

        // Fields
        case "createTaskField":
            let remote = try text(0), input = try arg(1).requireObject("field")
            var args: [(String, NativeRPCValue)] = [("task_id", .string(remote)), ("label", input["label"]), ("kind", input["kind"])]
            if input["config"].fields != nil { args.append(("config", input["config"])) }
            if !input["value"].isNullish { args.append(("value", input["value"])) }
            let data = try await send("create_field", args, task: remote)
            return result([("field", try await fieldAfter(id, row: row, task: remote, field: firstString(data, ["field_id", "id"]).string))])
        case "updateTaskFieldValue", "renameTaskField", "updateTaskFieldConfig", "deleteTaskField", "toggleTaskFieldVote", "pressTaskFieldButton":
            let field = try text(0), remote = try owner(id, field)
            switch fn {
            case "updateTaskFieldValue": _ = try await send("set_field_value", [("field_id", .string(field)), ("value", arg(1).isNullish ? .null : arg(1))], task: remote)
            case "renameTaskField": _ = try await send("edit_field", [("field_id", .string(field)), ("action", .string("rename")), ("task_id", .string(remote)), ("label", .string(try text(1)))], task: remote)
            case "updateTaskFieldConfig": _ = try await send("edit_field", [("field_id", .string(field)), ("action", .string("set_config")), ("task_id", .string(remote)), ("config", arg(1).isNullish ? .object([]) : arg(1))], task: remote)
            case "deleteTaskField":
                _ = try await send("edit_field", [("field_id", .string(field)), ("action", .string("delete")), ("task_id", .string(remote)), ("confirm", .bool(true))], task: remote)
                return result()
            case "toggleTaskFieldVote": _ = try await send("edit_field", [("field_id", .string(field)), ("action", .string("vote")), ("task_id", .string(remote))], task: remote)
            default: _ = try await send("edit_field", [("field_id", .string(field)), ("action", .string("press")), ("task_id", .string(remote))], task: remote)
            }
            return result([("field", try await fieldAfter(id, row: row, task: remote, field: field)), ("formulas", .array([]))])
        case "reorderTaskFields":
            let remote = try text(0)
            _ = try await send("reorder_fields", [("task_id", .string(remote)), ("field_ids", .array(try arg(1).requireArray("order")))], task: remote); return result()

        // Only for this Mac's own tasks
        case "setTaskProject", "chooseTaskProject":
            throw NativeRPCError(code: "not-offered", message: "Project folders belong to this Mac's own tasks; this one lives in \(row["name"].string ?? "the connected system").")
        case "restartRoutine", "setTaskRecurrence":
            throw NativeRPCError(code: "not-offered", message: "\(row["name"].string ?? "The system") does not offer that from outside; use the Recurring panel.")
        default:
            throw NativeRPCError(code: "not-offered", message: "\(row["name"].string ?? "The system") does not offer that from outside.")
        }
    }

    /// The profile with linked-record support known (a connection saved before it was discovered reads the tool list once).
    func relatedProfile(_ id: String) async throws -> BackendConnectedTasksProfile {
        let row = try connection(id), saved = profile(row)
        if saved.discoveredRelated { return saved }
        let fresh = BackendConnectedTasksProfile.discover(try await client(id, row: row).tools())
        var merged = saved
        merged.relatedArgument = fresh.relatedArgument; merged.relatedAreas = fresh.relatedAreas; merged.search = fresh.search; merged.discoveredRelated = true
        replaceProfile(id, merged)
        return merged
    }

    /// Records of one kind matching the words, as the popup's search shows them.
    func searchRecords(_ id: String, client: BackendConnectedTasksClient, tool: String, area: String, query: String) async throws -> [NativeRPCValue] {
        func hit(_ rid: String, _ label: String, _ secondary: String?) -> NativeRPCValue {
            .object([.init("area", .string(area)), .init("id", .string(rid)), .init("label", .string(String(label.prefix(200)))),
                     .init("secondary", secondary.map { .string($0) } ?? .missing), .init("href", .string(""))])
        }
        if area == "person" {
            let words = query.lowercased()
            var list = people[id]?["people"].elements ?? []
            if list.isEmpty { list = BackendConnectedTasksMapping.people(try await client.call(tool, .object([])).data).people }
            return list.filter { ($0["name"].string ?? "").lowercased().contains(words) }.prefix(12).compactMap { p in
                guard let pid = p["id"].string, let name = p["name"].string else { return nil }
                return hit(pid, name, nil)
            }
        }
        let data = try await client.call(tool, .object([.init("search", .string(String(query.prefix(128)))), .init("page_size", .number(12))])).data
        let rows = data[area + "s"].elements ?? BackendConnectedTasksMapping.rows(data)
        return rows.prefix(12).compactMap { r in
            guard let rid = r["id"].string else { return nil }
            let name = r["client"].string ?? r["name"].string ?? r["title"].string ?? r["reference"].string ?? rid
            let label = [r["reference"].string, area == "listing" ? r["title"].string : name].compactMap { $0 }.joined(separator: " · ")
            let second = [r["stage_label"].string, r["community"].string, r["price"].string, r["source"].string].compactMap { $0 }.joined(separator: " · ")
            return hit(rid, label.isEmpty ? name : label, second.isEmpty ? nil : second)
        }
    }

    func fieldAfter(_ id: String, row: NativeRPCValue, task: String, field: String?) async throws -> NativeRPCValue {
        let d = try await read(id, row: row, "get_task", task)
        guard let field, let f = d["fields"].elements?.first(where: { $0["id"].string == field }) else { return .null }
        return fieldWire(f, task: task)
    }

    func upload(_ id: String, client: BackendConnectedTasksClient, task: String, name: String, bytes: Data) async throws -> NativeRPCValue {
        guard bytes.count <= Self.uploadLimit else { throw NativeRPCError.invalidArguments("\(name) is over 10 MB.") }
        let data = try await client.call("upload_task_file", .object([.init("task_id", .string(task)), .init("file_name", .string(name)),
                                                                     .init("content_base64", .string(bytes.base64EncodedString()))])).data
        forget(id, task)
        let fileID = data["attachment_id"].string ?? data["id"].string ?? UUID().uuidString.lowercased()
        own(id, [fileID], task)
        return .object([.init("id", .string(fileID)), .init("kind", .string("upload")), .init("fileName", .string(data["file_name"].string ?? name)),
                        .init("mimeType", Self.iso(data["mime_type"])), .init("sizeBytes", .number(data["size_bytes"].number ?? Double(bytes.count))),
                        .init("documentId", .null), .init("storagePath", .null), .init("uploadedBy", .null), .init("createdAt", .string(ISO8601DateFormatter().string(from: Date())))])
    }
}

fileprivate extension NativeRPCValue {
    /// Bytes sent over the native seam (raw, or `{"$bytes": base64}` once re-encoded).
    var bytesValue: Data? {
        if case .bytes(let data) = self { return data }
        if let text = self["$bytes"].string { return Data(base64Encoded: text) }
        return nil
    }
}

fileprivate extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
