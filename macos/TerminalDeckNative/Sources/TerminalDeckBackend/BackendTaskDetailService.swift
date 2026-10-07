import Foundation
import TerminalDeckNativeCore

public struct BackendTaskReminderDelivery: Sendable {
    public let delivered: Bool, reason: String?, retry: Bool
    public init(delivered: Bool, reason: String? = nil, retry: Bool = false) { self.delivered = delivered; self.reason = reason; self.retry = retry }
}
/// shared/crm's actual person-row shape is supplied by that domain's owner.
/// The detail store never invents uuid aliases or display attributes.
public struct BackendTaskDetailPeople: Sendable {
    public let named: @Sendable (String) async throws -> NativeRPCValue
    public let known: @Sendable (String) async throws -> Bool
    public init(named: @escaping @Sendable (String) async throws -> NativeRPCValue, known: @escaping @Sendable (String) async throws -> Bool) { self.named = named; self.known = known }
    public static func native(configuration: BackendTaskConfiguration) -> Self {
        Self(named: { id in
            if id == "me" { return BackendCrmWire.person(BackendCrmPeople.localPerson(id, "You")) }
            if id == "hoot" { return BackendCrmWire.person(BackendCrmPeople.localPerson(id, "Hoot")) }
            let name = try await configuration.agent(id)?["name"].string ?? BackendTaskActor.appActorName(id) ?? id
            return BackendCrmWire.person(BackendCrmPeople.localPerson(id, name))
        }, known: { id in if id == "me" || id == "hoot" { return true }; let row = try await configuration.agent(id); return row != nil && row?["status"].string != "archived" })
    }
}

/// Real native task-detail operations. Unknown future detail fields survive;
/// only implemented functions are registered. Shared recurrence/field rules,
/// files/pickers and notifications are separate actual dependencies.
public actor BackendTaskDetailService {
    public nonisolated static let functions = Set(BackendCrmDetailContract.functions)
    let store: BackendTaskStore, local: BackendTaskLocalService, people: BackendTaskDetailPeople
    let files: BackendTaskAttachments?, desktop: BackendTaskDetailDesktop?, settingsPersistence: BackendTaskPersistence?
    var labelColors: [String: String] = [:], labelsLoaded = false
    var recurrencePending: [(id: String, actor: String)] = [], recurrenceJob: Task<Void, Never>?
    private let notify: (@Sendable (String, String, String) async throws -> BackendTaskReminderDelivery)?
    private let problem: @Sendable (String) async -> Void
    var stopped = true
    private var timer: BackendTaskTimer?, dueJob: Task<Void, Never>?, busy = false, waiters: [CheckedContinuation<Void, Never>] = []
    public init(store: BackendTaskStore, local: BackendTaskLocalService, people: BackendTaskDetailPeople,
                notify: (@Sendable (String, String, String) async throws -> BackendTaskReminderDelivery)? = nil,
                files: BackendTaskAttachments? = nil, desktop: BackendTaskDetailDesktop? = nil, settingsPersistence: BackendTaskPersistence? = nil,
                problem: @escaping @Sendable (String) async -> Void) {
        self.store = store; self.local = local; self.people = people; self.notify = notify; self.files = files; self.desktop = desktop; self.settingsPersistence = settingsPersistence; self.problem = problem
    }
    public func start() async throws {
        try await store.requireWritableOwnership(); try await store.start(); stopped = false
        await local.setUpdateObserver { [weak self] before, after, notes, actor in
            do { try await self?.noteUpdated(before: before, after: after, notes: notes, by: actor) }
            catch { await self?.reportUpdateFailure(error) }
        }
        _ = await local.installEngineStatusObserver { [weak self] id, actor in await self?.noteStatus(id, by: actor) }
        await wake()
    }
    public func stop() async { stopped = true; await local.setUpdateObserver(nil); _ = await local.installEngineStatusObserver(nil); timer?.cancel(); timer = nil; dueJob?.cancel(); recurrenceJob?.cancel(); recurrencePending.removeAll(); if let dueJob { await dueJob.value }; if let recurrenceJob { await recurrenceJob.value }; self.recurrenceJob = nil; self.dueJob = nil }
    public func call(_ fn: String, arguments: [NativeRPCValue], by: String = BackendTaskActor.current) async -> NativeRPCValue {
        await enter(); defer { leave() }
        do {
            try Task.checkCancellation()
            guard BackendCrmDetailContract.isLocalDetailFn(fn) else { throw NativeRPCError.invalidArguments("That is not something the task popup can do.") }
            let answer: NativeRPCValue
            if Self.fieldFunctions.contains(fn) { answer = try await fieldCall(fn, arguments: arguments, by: by) }
            else if Self.recurrenceFunctions.contains(fn) { answer = try await recurrenceCall(fn, arguments: arguments, by: by) }
            else if Self.extraFunctions.contains(fn) { answer = try await extraCall(fn, arguments: arguments, by: by) }
            else { answer = try await dispatch(fn, arguments: arguments, by: by) }; await arm(); return answer
        } catch { return BackendTaskValues.object([("ok", .bool(false)), ("error", .string(error.localizedDescription))]) }
    }
    public func dependencies(_ task: BackendTaskRecord) async throws -> [NativeRPCValue] {
        let all = try await store.all().filter(\.isLocal), lookup = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        var raw = detail(task)["dependencies"].elements ?? []
        for other in all where other.id != task.id { for dep in detail(other)["dependencies"].elements ?? [] where dep["otherTaskId"].string == task.id { raw.append(dep.setting("kind", .string(Self.mirror(dep["kind"].string ?? "linked"))).setting("otherTaskId", .string(other.id))) } }
        var seen = Set<String>(), result: [NativeRPCValue] = []
        for row in raw.sorted(by: { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) }) {
            guard let id = row["otherTaskId"].string, let other = lookup[id], seen.insert((row["kind"].string ?? "") + ":" + id).inserted else { continue }
            result.append(BackendTaskValues.object([("kind", row["kind"]), ("otherTaskId", .string(id)), ("otherTitle", other.value["title"]), ("otherDone", .bool(other.value["crmStatus"].string == "Done"))]))
        }; return result
    }
    private func dispatch(_ fn: String, arguments a: [NativeRPCValue], by: String) async throws -> NativeRPCValue {
        func arg(_ i: Int) -> NativeRPCValue { i < a.count ? a[i] : .missing }
        func string(_ i: Int) throws -> String { guard let text = arg(i).string else { throw NativeRPCError.invalidArguments("That request was not understood.") }; return text }
        if ["setFollowing", "addFollower", "removeFollower"].contains(fn) { throw NativeRPCError.invalidArguments("Only you see tasks on this computer, so there is nobody else to follow this one — and nothing to unfollow.") }
        if fn == "setTaskLinks" { throw NativeRPCError.invalidArguments("Related records live in a CRM; local tasks cannot link to them.") }
        if ["renameChecklist", "deleteChecklist", "addChecklistItem", "setChecklistItemDone", "setChecklistItemAssignee", "deleteChecklistItem"].contains(fn) { return try await checklist(fn, id: string(0), argument: arg(1), by: by) }
        let task = try await local.task(string(0)), id = task.id
        switch fn {
        case "addTaskAssignee", "removeTaskAssignee":
            let personID = try string(1); var d = detail(task), others = d["people"].elements?.compactMap(\.string) ?? []
            if fn == "addTaskAssignee" {
                try await requirePerson(.string(personID)); if personID == task.value["assignee"]["identity"].string || others.contains(personID) { return ok() }
                others.append(personID); let named = try await people.named(personID)
                try await save(task, d: d.setting("people", .array(others.map(NativeRPCValue.string))), by: by, kind: "assigned", payload: BackendTaskValues.object([("user_id", .string(personID)), ("name", named["name"]), ("primary", .bool(false))]))
            } else {
                guard others.contains(personID) else { throw NativeRPCError.invalidArguments("That person is not on this task.") }; others.removeAll { $0 == personID }; d = d.setting("people", .array(others.map(NativeRPCValue.string)))
                try await save(task, d: d, by: by, kind: "unassigned", payload: BackendTaskValues.object([("user_id", .string(personID))]))
            }; return ok()
        case "setSyncSubtaskDates":
            let on = arg(1).bool == true, current = detail(task).setting("syncSubtaskDates", .bool(on)); try await save(task, d: current, by: by, kind: "dates", payload: BackendTaskValues.object([("sync", .bool(on))]))
            let span = on ? Self.span(current) : nil
            if let span { _ = try await local.update(id, input: BackendTaskValues.object([("startDate", .string(span.start)), ("dueDate", .string(span.due))]), by: by) }
            return ok([("startDate", span.map { .string($0.start) } ?? .null), ("dueDate", span.map { .string($0.due) } ?? .null)])
        case "fetchTaskMore":
            try loadLabels(); let d = detail(task), tags = NativeRPCValue.object((d["time"].elements ?? []).compactMap { row in guard let id = row["id"].string, !(row["tags"].elements ?? []).isEmpty else { return nil }; return .init(id, row["tags"]) })
            return ok([("more", BackendTaskValues.object([("followers", .array([BackendTaskValues.object([("userId", .string("me")), ("since", .string(BackendTaskOutbox.iso(task.value["createdAt"].number ?? 0)))])])), ("iFollow", .bool(true)), ("reminders", .array((d["reminders"].elements ?? []).filter { $0["sentAt"].isNullish }.map { BackendTaskValues.object([("id", $0["id"]), ("remindAt", $0["remindAt"]), ("note", $0["note"])]) })), ("archivedAt", task.value["archivedAt"].number.map { .string(BackendTaskOutbox.iso($0)) } ?? .null), ("entryTags", tags), ("remindersLive", .bool(notify != nil)), ("startTime", task.value["startTime"].isNullish ? .null : task.value["startTime"]), ("dueTime", task.value["dueTime"].isNullish ? .null : task.value["dueTime"]), ("syncSubtaskDates", .bool(d["syncSubtaskDates"].bool == true)), ("labelColors", .object(labelColors.map { .init($0.key, .string($0.value)) })), ("canColorTags", .bool(true)), ("canRemoveFollowers", .bool(false))]))])
        case "setTaskStatus": _ = try await local.update(id, input: BackendTaskValues.object([("status", .string(try string(1)))]), by: by); return ok()
        case "updateTask":
            // task-detail-local.ts updateTask: only these keys, a cleared date takes its time with it.
            let patch = arg(1).fields != nil ? arg(1) : NativeRPCValue.object([])
            var change = NativeRPCValue.object([])
            if let title = patch["title"].string { change = change.setting("title", .string(title)) }
            if patch.has("priority") { change = change.setting("priority", patch["priority"]) }
            if let text = patch["description"].string { change = change.setting("instructions", .string(text)) }
            for key in ["startDate", "dueDate"] { if let text = patch[key].string { change = change.setting(key, text.isEmpty ? .null : .string(text)) } }
            func timed(_ key: String) -> Bool { task.value[key].string.map { !$0.isEmpty } ?? false }
            if change.has("startDate"), change["startDate"] == .null, timed("startTime") { change = change.setting("startTime", .null) }
            if change.has("dueDate"), change["dueDate"] == .null, timed("dueTime") { change = change.setting("dueTime", .null) }
            let hasRecurrence = patch.has("recurrence")
            guard !change.spreadFields.isEmpty || hasRecurrence else { throw NativeRPCError.invalidArguments("Nothing to update") }
            if !change.spreadFields.isEmpty { _ = try await local.update(id, input: change, by: by) }
            if hasRecurrence { let r = try await recurrenceCall("setTaskRecurrence", arguments: [.string(id), patch["recurrence"].isNullish ? .null : patch["recurrence"], .null], by: by); if r["ok"].bool != true { return r } }
            return ok()
        case "assignTask":
            let who = try string(1); if who != "none" { try await requirePerson(.string(who)) }
            _ = try await local.update(id, input: BackendTaskValues.object([("assignee", .string(who))]), by: by)
            // The one put on as the main person is no longer one of the others (read fresh: the Activity line was just saved).
            let fresh = try await local.task(id), d = detail(fresh), others = d["people"].elements ?? []
            if others.contains(.string(who)) { try await save(fresh, d: d.setting("people", .array(others.filter { $0 != .string(who) })), by: by) }
            return ok()
        case "setTaskType":
            guard BackendCrmTaskPage.isTaskType(arg(1).string) else { throw NativeRPCError.invalidArguments("Invalid task type") }
            _ = try await local.update(id, input: BackendTaskValues.object([("taskType", arg(1))]), by: by); return ok()
        case "setTaskLabels":
            guard let list = arg(1).elements else { throw NativeRPCError.invalidArguments("Invalid tags") }
            _ = try await local.update(id, input: BackendTaskValues.object([("labels", .array(BackendCrmTaskPage.normalizeLabels(list.map(BackendCrmWire.crm)).map(NativeRPCValue.string)))]), by: by); return ok()
        case "moveTask":
            guard let board = arg(1).string else { throw NativeRPCError.invalidArguments("Invalid board") }
            _ = try await local.update(id, input: BackendTaskValues.object([("board", board.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .null : .string(board))]), by: by); return ok()
        case "setTimeEstimate":
            if arg(1) != .null { guard let minutes = arg(1).number, minutes == minutes.rounded(), minutes >= 0, minutes <= 100_000 else { throw NativeRPCError.invalidArguments("Invalid estimate") } }
            _ = try await local.update(id, input: BackendTaskValues.object([("estimateMinutes", arg(1))]), by: by); return ok()
        case "setArchived": _ = try await local.update(id, input: BackendTaskValues.object([("archived", .bool(arg(1).bool == true))]), by: by); return ok()
        case "setTaskTimes":
            var change = NativeRPCValue.object([])
            for key in ["startTime", "dueTime"] where arg(1).has(key) {
                let value = arg(1)[key]
                if value != .null { guard let text = value.string, text.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Invalid time") } }
                change = change.setting(key, value)
            }
            guard !change.spreadFields.isEmpty else { throw NativeRPCError.invalidArguments("Nothing to update") }
            _ = try await local.update(id, input: change, by: by); return ok()
        case "setTaskProject":
            guard let path = arg(1).string else { throw NativeRPCError.invalidArguments("Choose a folder.") }
            let after = try await local.update(id, input: BackendTaskValues.object([("project", .string(path))]), by: by); return ok([("project", .string(after.project))])
        case "fetchTaskDetailBundle":
            var d = detail(task), named: [NativeRPCValue] = []
            let primary = task.assigneeKind == "none" ? NativeRPCValue.null : try await people.named(task.value["assignee"]["identity"].string ?? task.agentID)
            for person in d["people"].elements?.compactMap(\.string) ?? [] where person != primary["id"].string { named.append(try await people.named(person)) }
            d = d.setting("people", BackendTaskValues.object([("primary", primary), ("others", .array(named))]))
            let attachments = try (d["attachments"].elements ?? []).map { row in try attachmentView(row) }
            return ok([("bundle", BackendTaskValues.object([("people", d["people"]), ("subtasks", .array(sorted(d["subtasks"]).elements!.map { BackendTaskValues.object([("id", $0["id"]), ("title", $0["title"]), ("done", $0["done"]), ("sortOrder", $0["sortOrder"]), ("assigneeUserId", $0["assigneeUserId"])]) })), ("checklists", sorted(d["checklists"])), ("dependencies", .array(try await dependencies(task))), ("attachments", .array(attachments))]))])
        case "listTaskComments": return ok([("comments", .array(try await comments(task)))])
        case "listTaskActivity":
            let stored = (detail(task)["activity"].elements ?? []) + noteActivity(task); var rows: [NativeRPCValue] = []
            for row in stored.sorted(by: { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }).prefix(500) { rows.append(BackendTaskValues.object([("id", row["id"]), ("taskId", .string(id)), ("kind", row["kind"]), ("payload", row["payload"]), ("actor", try await people.named(row["by"].string ?? "me")), ("actorUserId", row["by"]), ("createdAt", .string(BackendTaskOutbox.iso(row["at"].number ?? 0)))])) }
            return ok([("rows", .array(rows)), ("total", .number(Double(stored.count)))])
        case "fetchDescriptionHistory": return ok([("versions", .array((detail(task)["activity"].elements ?? []).filter { $0["kind"].string == "description" }.sorted { ($0["at"].number ?? 0) > ($1["at"].number ?? 0) }.map { BackendTaskValues.object([("at", .string(BackendTaskOutbox.iso($0["at"].number ?? 0))), ("by", $0["by"]), ("from", $0["payload"]["from"]), ("to", $0["payload"]["to"])]) }))])
        case "fetchCommentExtras":
            let d = detail(task); var meta = NativeRPCValue.object([]), reactions = NativeRPCValue.object([])
            for row in try await comments(task) { guard let id = row["id"].string else { continue }; meta = meta.setting(id, d["commentMeta"][id].isNullish ? Self.emptyMeta : Self.emptyMeta.merging(d["commentMeta"][id])); let sorted = (d["reactions"][id].elements ?? []).sorted { (BackendCrmComments.reactionEmoji.firstIndex(of: $0["emoji"].string ?? "") ?? 99) < (BackendCrmComments.reactionEmoji.firstIndex(of: $1["emoji"].string ?? "") ?? 99) }; if !sorted.isEmpty { reactions = reactions.setting(id, .array(sorted)) } }
            return ok([("extras", BackendTaskValues.object([("meta", meta), ("reactions", reactions)]))])
        case "fetchTaskPageExtras":
            let d = detail(task), meta = NativeRPCValue.object((d["subtasks"].elements ?? []).compactMap { row in row["id"].string.map { .init($0, BackendTaskValues.object([("priority", row["priority"]), ("dueDate", row["dueDate"])])) } })
            return ok([("extras", BackendTaskValues.object([("taskType", task.value["taskType"].isNullish ? .string("task") : task.value["taskType"]), ("labels", task.value["labels"].isNullish ? .array([]) : task.value["labels"]), ("estimateMinutes", task.value["estimateMinutes"].isNullish ? .null : task.value["estimateMinutes"]), ("recurrenceRule", BackendCrmWire.native(BackendCrmTaskPage.normalizeRecurrenceRule(BackendCrmWire.crm(d["recurrenceRule"])) )), ("timeEntries", .array((d["time"].elements ?? []).map { $0.removing("tags") })), ("subtaskMeta", meta)]))])
        case "addTaskSubtask":
            let title = (arg(1).string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.utf16.count <= 300 else { throw NativeRPCError.invalidArguments("Subtask title is required (max 300 chars)") }
            var d = detail(task), list = d["subtasks"].elements ?? []; let rowID = UUID().uuidString.lowercased()
            list.append(BackendTaskValues.object([("id", .string(rowID)), ("title", .string(title)), ("done", .bool(false)), ("sortOrder", .number((list.compactMap { $0["sortOrder"].number }.max() ?? -1) + 1)), ("assigneeUserId", .null), ("priority", .null), ("dueDate", .null)]))
            try await save(task, d: d.setting("subtasks", .array(list)), by: by, kind: "subtask_added", payload: BackendTaskValues.object([("subtask_id", .string(rowID)), ("title", .string(title))])); return ok([("id", .string(rowID))])
        case "addChecklist":
            let title = try Self.checklistTitle(arg(1))
            var d = detail(task), list = d["checklists"].elements ?? []; let rowID = UUID().uuidString.lowercased()
            list.append(BackendTaskValues.object([("id", .string(rowID)), ("title", .string(title)), ("sortOrder", .number((list.compactMap { $0["sortOrder"].number }.max() ?? -1) + 1)), ("items", .array([]))]))
            try await save(task, d: d.setting("checklists", .array(list)), by: by, kind: "checklist_added", payload: BackendTaskValues.object([("checklist_id", .string(rowID)), ("title", .string(title))])); return ok([("id", .string(rowID))])
        case "setTaskSubtaskDone", "deleteTaskSubtask", "setTaskSubtaskAssignee", "setSubtaskMeta":
            var d = detail(task), rows = d["subtasks"].elements ?? []; let subID = try string(1)
            guard let index = rows.firstIndex(where: { $0["id"].string == subID }) else { throw NativeRPCError.invalidArguments("Subtask not found") }
            var kind: String?, payload = NativeRPCValue.object([]), syncDates = false
            switch fn {
            case "deleteTaskSubtask": rows.remove(at: index)
            case "setTaskSubtaskDone":
                let done = arg(2).bool == true; rows[index] = rows[index].setting("done", .bool(done)); kind = "subtask_done"
                payload = BackendTaskValues.object([("subtask_id", rows[index]["id"]), ("title", rows[index]["title"]), ("done", .bool(done))])
            case "setTaskSubtaskAssignee":
                if !arg(2).isNullish { guard arg(2).string != nil else { throw NativeRPCError.invalidArguments("That request was not understood.") }; try await requirePerson(arg(2)) }
                rows[index] = rows[index].setting("assigneeUserId", arg(2).isNullish ? .null : arg(2)); if let who = arg(2).string { d = join(d, task: task, person: who) }
            default:
                let patch = arg(2).fields != nil ? arg(2) : NativeRPCValue.object([]); var touched = false
                if patch.has("priority") {
                    let value = patch["priority"]; guard value.isNullish || ["Low", "Medium", "High", "Critical"].contains(value.string ?? "") else { throw NativeRPCError.invalidArguments("Invalid priority") }
                    rows[index] = rows[index].setting("priority", value.isNullish ? .null : value); touched = true
                }
                if patch.has("dueDate") {
                    let value = patch["dueDate"]
                    if !value.isNullish, value.string != "" { guard let text = value.string, text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { throw NativeRPCError.invalidArguments("Invalid due date") } }
                    rows[index] = rows[index].setting("dueDate", (value.string ?? "").isEmpty ? .null : value); touched = true; syncDates = d["syncSubtaskDates"].bool == true
                }
                guard touched else { throw NativeRPCError.invalidArguments("Nothing to update") }
            }
            d = d.setting("subtasks", .array(rows)); try await save(task, d: d, by: by, kind: kind, payload: payload)
            if syncDates, let span = Self.span(d), task.value["startDate"].string != span.start || task.value["dueDate"].string != span.due { _ = try await local.update(id, input: BackendTaskValues.object([("startDate", .string(span.start)), ("dueDate", .string(span.due))]), by: by) }
            return ok()
        case "addTaskDependency", "removeTaskDependency":
            let otherID = try string(1)
            guard let kind = arg(2).string, ["blocks", "blocked_by", "linked"].contains(kind) else { throw NativeRPCError.invalidArguments("Invalid dependency kind") }
            var d = detail(task), list = d["dependencies"].elements ?? []
            if fn == "addTaskDependency" {
                guard otherID != id else { throw NativeRPCError.invalidArguments("A task cannot depend on itself") }
                guard let other = try await store.byID(otherID), other.isLocal else { throw NativeRPCError.invalidArguments("Other task not found or not yours") }
                if (try await dependencies(task)).contains(where: { $0["kind"].string == kind && $0["otherTaskId"].string == otherID }) { return ok() }
                list.append(BackendTaskValues.object([("kind", .string(kind)), ("otherTaskId", .string(otherID)), ("at", .number(BackendTaskValues.time()))]))
                try await save(task, d: d.setting("dependencies", .array(list)), by: by, kind: "dependency", payload: BackendTaskValues.object([("other_task_id", .string(otherID)), ("title", other.value["title"]), ("kind", .string(kind)), ("removed", .bool(false))])); return ok()
            }
            let had = list.count; list.removeAll { $0["kind"].string == kind && $0["otherTaskId"].string == otherID }; var removed = list.count != had
            let other = try await store.byID(otherID)
            if !removed, let other, other.isLocal {
                // The link was made from the other task: it is taken off there.
                let od = detail(other), mirrored = Self.mirror(kind), kept = (od["dependencies"].elements ?? []).filter { !($0["kind"].string == mirrored && $0["otherTaskId"].string == id) }
                if kept.count != (od["dependencies"].elements ?? []).count { removed = true; try await save(other, d: od.setting("dependencies", .array(kept)), by: by) }
            }
            guard removed else { throw NativeRPCError.invalidArguments("Dependency not found") }
            try await save(task, d: d.setting("dependencies", .array(list)), by: by, kind: "dependency", payload: BackendTaskValues.object([("other_task_id", .string(otherID)), ("title", other?.value["title"] ?? .null), ("kind", .string(kind)), ("removed", .bool(true))])); return ok()
        case "addTaskComment", "addTaskCommentWith": return try await addComment(task, body: arg(1), options: fn == "addTaskCommentWith" ? arg(2) : .object([]), by: by)
        case "setCommentResolved", "assignComment", "sendScheduledNow":
            let commentID = try string(1); guard try await comments(task).contains(where: { $0["id"].string == commentID }) else { throw NativeRPCError.invalidArguments("That comment is no longer on this task") }
            var d = detail(task), meta = d["commentMeta"][commentID].isNullish ? Self.emptyMeta : d["commentMeta"][commentID]
            if fn == "setCommentResolved" { meta = meta.setting("resolvedAt", arg(2).bool == true ? .string(BackendTaskOutbox.iso(BackendTaskValues.time())) : .null).setting("resolvedBy", arg(2).bool == true ? .string(by) : .null) }
            else if fn == "assignComment" { try await requirePerson(arg(2)); meta = meta.setting("assigneeUserId", arg(2).isNullish ? .null : arg(2)).setting("resolvedAt", .null).setting("resolvedBy", .null) /* a new assignment reopens it */ }
            else {
                guard let row = (d["comments"].elements ?? []).first(where: { $0["id"].string == commentID }), row["authorUserId"].string == by else { throw NativeRPCError.invalidArguments("Only the person who wrote it can send it now") }
                guard meta["scheduledFor"].string != nil else { throw NativeRPCError.invalidArguments("That comment is not scheduled") }
                guard meta["deliveredAt"].isNullish else { return ok([("alreadySent", .bool(true))]) }
                let now = BackendTaskOutbox.iso(BackendTaskValues.time()); meta = meta.setting("scheduledFor", .string(now)).setting("deliveredAt", .string(now))
            }
            d = d.setting("commentMeta", d["commentMeta"].setting(commentID, meta)); try await save(task, d: d, by: by, kind: fn == "sendScheduledNow" ? "comment" : nil, payload: BackendTaskValues.object([("comment_id", .string(commentID))]))
            if fn == "sendScheduledNow", let row = (d["comments"].elements ?? []).first(where: { $0["id"].string == commentID }), let body = row["body"].string { return try await deliveryReply(task, body: body, by: by, parentAuthor: meta["parentId"].string.flatMap { parent in (d["comments"].elements ?? []).first(where: { $0["id"].string == parent })?["authorUserId"].string }) }; return ok()
        case "startTaskTimer", "stopTaskTimer", "addTaskTimeEntry", "deleteTaskTimeEntry", "setTimeEntryTags": return try await time(fn, task: task, arg: arg(1), extra: arg(2), by: by)
        case "setReminder", "clearReminder":
            var d = detail(task), reminders = d["reminders"].elements ?? []
            if fn == "clearReminder" { let reminderID = try string(1); guard reminders.contains(where: { $0["id"].string == reminderID && $0["sentAt"].isNullish }) else { throw NativeRPCError.invalidArguments("Reminder not found") }; reminders.removeAll { $0["id"].string == reminderID }; try await save(task, d: d.setting("reminders", .array(reminders)), by: by); return ok() }
            guard notify != nil else { throw NativeRPCError.invalidArguments("Nothing on this computer delivers reminders.") }
            guard let when = arg(1).string.flatMap(Self.date) else { throw NativeRPCError.invalidArguments("Invalid time") }
            let at = when.timeIntervalSince1970 * 1_000
            guard at >= BackendTaskValues.time() - 60_000 else { throw NativeRPCError.invalidArguments("That time has already passed") }
            guard at <= BackendTaskValues.time() + 366 * 86_400_000 else { throw NativeRPCError.invalidArguments("Pick a time within a year") }
            let reminderID = UUID().uuidString.lowercased(); reminders.append(BackendTaskValues.object([("id", .string(reminderID)), ("remindAt", .string(BackendTaskOutbox.iso(at))), ("note", arg(2).string.flatMap { $0.isEmpty ? nil : NativeRPCValue.string(String($0.prefix(500))) } ?? .null), ("sentAt", .null), ("attempts", .number(0)), ("lastError", .null), ("retryAt", .null)]))
            d = d.setting("reminders", .array(reminders)); try await save(task, d: d, by: by); return ok([("id", .string(reminderID))])
        default: throw BackendSessionFailure.missingCapability("the native task popup function \(fn)")
        }
    }
    static func checklistTitle(_ raw: NativeRPCValue) throws -> String {
        // checklistTitle: nothing or blank is "Checklist"; not text or over 200 is refused.
        if raw.isNullish { return "Checklist" }
        guard let text = raw.string else { throw NativeRPCError.invalidArguments("Checklist name is too long (max 200)") }
        let title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Checklist" }
        guard title.utf16.count <= 200 else { throw NativeRPCError.invalidArguments("Checklist name is too long (max 200)") }
        return title
    }
    private func checklist(_ fn: String, id: String, argument: NativeRPCValue, by: String) async throws -> NativeRPCValue {
        let itemFunction = ["setChecklistItemDone", "setChecklistItemAssignee", "deleteChecklistItem"].contains(fn)
        var newTitle = "", itemTitle = ""
        if fn == "renameChecklist" { newTitle = try Self.checklistTitle(argument) }
        if fn == "addChecklistItem" {
            itemTitle = (argument.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !itemTitle.isEmpty, itemTitle.utf16.count <= 300 else { throw NativeRPCError.invalidArguments("Item is required (max 300 chars)") }
        }
        for task in try await store.all().filter(\.isLocal) {
            var d = detail(task), lists = d["checklists"].elements ?? []
            for li in lists.indices {
                if !itemFunction, lists[li]["id"].string == id {
                    if fn == "deleteChecklist" { lists.remove(at: li) }
                    else if fn == "renameChecklist" { lists[li] = lists[li].setting("title", .string(newTitle)) }
                    else {
                        let itemID = UUID().uuidString.lowercased(), rows = lists[li]["items"].elements ?? []
                        let row = BackendTaskValues.object([("id", .string(itemID)), ("title", .string(itemTitle)), ("done", .bool(false)), ("sortOrder", .number((rows.compactMap { $0["sortOrder"].number }.max() ?? -1) + 1)), ("assigneeUserId", .null)])
                        lists[li] = lists[li].setting("items", .array(rows + [row]))
                        try await save(task, d: d.setting("checklists", .array(lists)), by: by, kind: "checklist_item", payload: BackendTaskValues.object([("item_id", .string(itemID)), ("title", .string(itemTitle)), ("done", .null)])); return ok([("id", .string(itemID))])
                    }
                    try await save(task, d: d.setting("checklists", .array(lists)), by: by); return ok()
                }
                var rows = lists[li]["items"].elements ?? []
                if itemFunction, let ri = rows.firstIndex(where: { $0["id"].string == id }) {
                    var kind: String?, payload = NativeRPCValue.object([])
                    if fn == "deleteChecklistItem" { rows.remove(at: ri) }
                    else if fn == "setChecklistItemDone" {
                        let done = argument.bool == true; rows[ri] = rows[ri].setting("done", .bool(done)); kind = "checklist_item"
                        payload = BackendTaskValues.object([("item_id", rows[ri]["id"]), ("title", rows[ri]["title"]), ("done", .bool(done))])
                    } else {
                        if !argument.isNullish { guard argument.string != nil else { throw NativeRPCError.invalidArguments("That request was not understood.") }; try await requirePerson(argument) }
                        rows[ri] = rows[ri].setting("assigneeUserId", argument.isNullish ? .null : argument); if let person = argument.string { d = join(d, task: task, person: person) }
                    }
                    lists[li] = lists[li].setting("items", .array(rows)); try await save(task, d: d.setting("checklists", .array(lists)), by: by, kind: kind, payload: payload); return ok()
                }
            }
        }; throw NativeRPCError.invalidArguments(itemFunction ? "Checklist item not found" : "Checklist not found")
    }
    private func time(_ fn: String, task: BackendTaskRecord, arg: NativeRPCValue, extra: NativeRPCValue, by: String) async throws -> NativeRPCValue {
        if fn == "startTaskTimer" || fn == "stopTaskTimer" {
            var first = NativeRPCValue.null
            for row in try await store.all().filter({ $0.isLocal && (fn == "startTaskTimer" || $0.id == task.id) }) {
                var d = detail(row), entries = d["time"].elements ?? []
                for i in entries.indices where entries[i]["userId"].string == by && entries[i]["endedAt"].isNullish {
                    let now = BackendTaskValues.time(), started = Self.date(entries[i]["startedAt"].string ?? "")?.timeIntervalSince1970 ?? now / 1_000
                    entries[i] = entries[i].setting("endedAt", .string(BackendTaskOutbox.iso(now))).setting("seconds", .number(min(86_400, max(0, floor(now / 1_000 - started))))); if first == .null { first = entries[i] }
                }
                let ended = entries.filter { $0["userId"].string == by && $0["endedAt"].string == BackendTaskOutbox.iso(BackendTaskValues.time()) }
                d = d.setting("time", .array(entries)); try await save(row, d: d, by: by, kind: ended.isEmpty ? nil : "time_tracked", payload: BackendTaskValues.object([("seconds", ended.first?["seconds"] ?? .number(0)), ("on", .string(BackendCrmTime.localToday(Date(timeIntervalSince1970: BackendTaskValues.time() / 1_000))))]))
            }
            if fn == "stopTaskTimer" { return ok([("entry", first == .null ? .null : first.removing("tags"))]) }
        }
        let current = try await local.task(task.id); var d = detail(current), entries = d["time"].elements ?? []
        if fn == "deleteTaskTimeEntry" || fn == "setTimeEntryTags" {
            guard let id = arg.string, let i = entries.firstIndex(where: { $0["id"].string == id && $0["userId"].string == by }) else { throw NativeRPCError.invalidArguments("Time entry not found or not yours") }
            if fn == "deleteTaskTimeEntry" { entries.remove(at: i) } else { guard let list = extra.elements else { throw NativeRPCError.invalidArguments("Invalid tags") }; entries[i] = entries[i].setting("tags", .array(BackendCrmTaskPage.normalizeLabels(list.map(BackendCrmWire.crm)).prefix(10).map(NativeRPCValue.string))) }
            try await save(current, d: d.setting("time", .array(entries)), by: by); return fn == "setTimeEntryTags" ? ok([("tags", entries.first(where: { $0["id"] == arg })?["tags"] ?? .array([]))]) : ok()
        }
        let id = UUID().uuidString.lowercased(), now = BackendTaskValues.time(); var row = BackendTaskValues.object([("id", .string(id)), ("userId", .string(by)), ("startedAt", .string(BackendTaskOutbox.iso(now))), ("endedAt", .null), ("seconds", .null), ("note", .null), ("billable", .bool(false)), ("tags", .array([]))])
        if fn == "addTaskTimeEntry" {
            let rawSeconds = arg["seconds"].number ?? arg["seconds"].string.flatMap(Double.init) ?? .nan
            guard rawSeconds.isFinite, floor(rawSeconds) > 0, floor(rawSeconds) <= 86_400 else { throw NativeRPCError.invalidArguments("Enter a time between 1 minute and 24 hours") }; let seconds = Int(floor(rawSeconds))
            var ended = Date(timeIntervalSince1970: BackendTaskValues.time() / 1_000); if let day = arg["date"].string { let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false; guard let date = formatter.date(from: day), date.timeIntervalSince1970 * 1_000 <= BackendTaskValues.time() else { throw NativeRPCError.invalidArguments("That day has not happened yet") }; if !Calendar.current.isDate(date, inSameDayAs: Date(timeIntervalSince1970: BackendTaskValues.time() / 1_000)) { ended = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date)! } }
            row = row.setting("startedAt", .string(BackendTaskOutbox.iso((ended.timeIntervalSince1970 - Double(seconds)) * 1_000))).setting("endedAt", .string(BackendTaskOutbox.iso(ended.timeIntervalSince1970 * 1_000))).setting("seconds", .number(Double(seconds))).setting("note", arg["note"].string.map { .string(String($0.prefix(2_000))) } ?? .null).setting("billable", .bool(arg["billable"].bool == true))
        }
        entries.append(row); d = d.setting("time", .array(entries)); try await save(current, d: d, by: by, kind: fn == "addTaskTimeEntry" ? "time_tracked" : nil, payload: BackendTaskValues.object([("seconds", row["seconds"]), ("on", .string(arg["date"].string ?? BackendCrmTime.localToday(Date(timeIntervalSince1970: BackendTaskValues.time() / 1_000))))])); return ok([("entry", row.removing("tags"))])
    }
    func addComment(_ task: BackendTaskRecord, body: NativeRPCValue, options: NativeRPCValue, by: String) async throws -> NativeRPCValue {
        let text = (body.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines), id = UUID().uuidString.lowercased()
        guard !text.isEmpty, text.utf16.count <= 2_000 else { throw NativeRPCError.invalidArguments("Comment is required (max 2000 chars)") }
        var d = detail(task), rows = d["comments"].elements ?? [], meta = Self.emptyMeta
        let ask = options["scheduledFor"]
        if !(ask.isNullish || ask.string == "" || ask.bool == false || ask.number == 0) {
            guard let raw = ask.string, let date = Self.date(raw) else { throw NativeRPCError.invalidArguments("That time could not be read") }
            let at = date.timeIntervalSince1970 * 1_000
            guard at > BackendTaskValues.time() else { throw NativeRPCError.invalidArguments("Pick a time in the future") }
            guard at <= BackendTaskValues.time() + 366 * 86_400_000 else { throw NativeRPCError.invalidArguments("A comment can be scheduled up to a year ahead") }
            meta = meta.setting("scheduledFor", .string(BackendTaskOutbox.iso(at))).setting("deliveredAt", .null)
        }
        var parentAuthor: String?
        if let parent = options["parentId"].string, !parent.isEmpty { guard let comment = try await comments(task).first(where: { $0["id"].string == parent }) else { throw NativeRPCError.invalidArguments("That comment is no longer on this task") }; parentAuthor = comment["authorUserId"].string; meta = meta.setting("parentId", d["commentMeta"][parent]["parentId"].string.map(NativeRPCValue.string) ?? .string(parent)) }
        if let who = options["assigneeUserId"].string, !who.isEmpty { try await requirePerson(.string(who)); meta = meta.setting("assigneeUserId", .string(who)) }
        rows.append(BackendTaskValues.object([("id", .string(id)), ("authorUserId", .string(by)), ("body", .string(text)), ("at", .number(BackendTaskValues.time()))])); d = d.setting("comments", .array(Array(rows.suffix(1_000)))).setting("commentMeta", d["commentMeta"].setting(id, meta))
        try await save(task, d: d, by: by, kind: meta["scheduledFor"].isNullish ? "comment" : nil, payload: BackendTaskValues.object([("comment_id", .string(id))]))
        if meta["scheduledFor"].isNullish { let delivery = try await deliveryReply(task, body: text, by: by, parentAuthor: parentAuthor); return delivery.setting("id", .string(id)) }; return ok([("id", .string(id))])
    }
    private func deliveryReply(_ task: BackendTaskRecord, body: String, by: String, parentAuthor: String? = nil) async throws -> NativeRPCValue {
        // task-detail-local.ts listener(): the agent or Hoot holding the task (or who handed it back), named "@Name" or replied to.
        let candidates = (["agent", "hoot"].contains(task.assigneeKind) ? [task.agentID] : []) + (task.value["handedFrom"].string.map { [$0] } ?? [])
        let lower = body.lowercased(); var addressed = false
        for agent in candidates {
            let name: String?
            if agent == "hoot" { name = "Hoot" } else { name = try await local.configuration.agent(agent)?["name"].string }
            guard let name else { continue }
            let mention = "@" + name.lowercased()
            if let found = lower.range(of: mention) {
                let before = found.lowerBound == lower.startIndex || lower[lower.index(before: found.lowerBound)].isWhitespace
                let next: Character? = found.upperBound < lower.endIndex ? lower[found.upperBound] : nil
                if before && !(next?.isLetter == true || next?.isNumber == true) { addressed = true; break }
            }
            if parentAuthor == agent { addressed = true; break }
        }
        guard addressed else { return ok() }
        do { _ = try await local.reply(task.id, text: body); return ok() } catch { return ok([("warning", .string("Posted, but it could not reach the agent: " + error.localizedDescription))]) }
    }
    func comments(_ task: BackendTaskRecord) async throws -> [NativeRPCValue] {
        var rows = detail(task)["comments"].elements ?? []
        let mine = Set(rows.filter { $0["authorUserId"].string == "me" }.compactMap { $0["body"].string?.trimmingCharacters(in: .whitespacesAndNewlines) })
        for note in task.value["notes"].elements ?? [] {
            let kind = note["kind"].string ?? "", text = note["text"].string ?? ""
            if ["progress", "question", "blocker", "completion"].contains(kind) || (kind == "reply" && !mine.contains(text.trimmingCharacters(in: .whitespacesAndNewlines))) {
                rows.append(BackendTaskValues.object([("id", .string("note-\(Int(note["at"].number ?? 0))-\(Self.hash(kind + "|" + text))")), ("authorUserId", note["by"]), ("body", .string(text)), ("at", note["at"])]))
            }
        }
        var result: [NativeRPCValue] = []
        for row in rows.sorted(by: { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) }) { let who = try await people.named(row["authorUserId"].string ?? "me"); result.append(BackendTaskValues.object([("id", row["id"]), ("taskId", .string(task.id)), ("authorUserId", who["id"]), ("authorName", who["name"]), ("authorInitials", who["initials"]), ("authorColor", who["color"]), ("body", row["body"]), ("createdAt", .string(BackendTaskOutbox.iso(row["at"].number ?? 0)))])) }; return result
    }
    public func nextDueAt() async throws -> Double? {
        var dates: [Double] = []; if let repeatDue = try await nextRepeatDue() { dates.append(repeatDue) }
        for task in try await store.all(includeTrash: true) where task.isLocal {
            let d = detail(task)
            for row in d["reminders"].elements ?? [] where row["sentAt"].isNullish { if notify != nil, let at = Self.date(row["remindAt"].string ?? "") { dates.append(max(at.timeIntervalSince1970 * 1_000, row["retryAt"].number ?? 0)) } }
            if task.value["deletedAt"].isNullish { for row in d["commentMeta"].fields ?? [] where row.value["deliveredAt"].isNullish { if let at = Self.date(row.value["scheduledFor"].string ?? "") { dates.append(at.timeIntervalSince1970 * 1_000) } } }
        }; return dates.min()
    }
    public func poke() async { await arm() }
    public func wake() async {
        guard !stopped, dueJob == nil else { return }
        dueJob = Task { [weak self] in await self?.runDue(); await self?.completedDue() }
    }
    private func completedDue() async { dueJob = nil; await arm() }
    /// One due pass (reminders, scheduled comments, repeating tasks) that is finished when this returns: a receipt
    /// for callers and tests that cannot wait for the timer-driven `wake()`.
    public func runDueNow() async {
        while let running = dueJob { await running.value }
        let job = Task { [weak self] in await self?.runDue(force: true); await self?.completedDue() }; dueJob = job; await job.value
    }
    private func runDue(force: Bool = false) async {
        await enter(); defer { leave() }; guard force || !stopped else { return }
        do {
            try await runRepeatSchedules()
            for task in try await store.all(includeTrash: true) where task.isLocal {
                try Task.checkCancellation(); var d = detail(task), reminders = d["reminders"].elements ?? [], touched = false
                for index in reminders.indices where reminders[index]["sentAt"].isNullish {
                    let row = reminders[index]
                    guard let date = Self.date(row["remindAt"].string ?? ""), date.timeIntervalSince1970 * 1_000 <= BackendTaskValues.time(), (row["retryAt"].number ?? 0) <= BackendTaskValues.time(), let notify else { continue }
                    touched = true; reminders[index] = row.setting("sentAt", .string(BackendTaskOutbox.iso(BackendTaskValues.time()))).setting("lastError", .string("Delivery claimed; the outcome is not yet known.")); d = d.setting("reminders", .array(reminders)); try await persist(task, d: d)
                    if !task.value["deletedAt"].isNullish || !task.value["archivedAt"].isNullish { reminders[index] = reminders[index].setting("lastError", .string(task.value["deletedAt"].isNullish ? "skipped: the task is archived" : "skipped: the task was deleted")); continue }
                    let outcome: BackendTaskReminderDelivery
                    do {
                        // task-detail-local.ts runDue: the title's first line, file tokens stripped, 80 characters; a blank note says the default.
                        let line = BackendCrmInlineFiles.stripFileTokens((task.value["title"].string ?? "").components(separatedBy: "\n")[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let note = (row["note"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        outcome = try await notify(task.id, line.isEmpty ? "A task" : String(line.prefix(80)), note.isEmpty ? "You asked to be reminded about this task." : note)
                    }
                    catch is CancellationError { throw CancellationError() }
                    catch { outcome = BackendTaskReminderDelivery(delivered: false, reason: error.localizedDescription, retry: true) }
                    let attempts = Int(row["attempts"].number ?? 0) + 1; reminders[index] = reminders[index].setting("attempts", .number(Double(attempts)))
                    if outcome.delivered { reminders[index] = reminders[index].setting("lastError", .null).setting("retryAt", .null) }
                    else if outcome.retry && attempts < 5 { reminders[index] = reminders[index].setting("sentAt", .null).setting("lastError", .string(outcome.reason ?? "Delivery failed")).setting("retryAt", .number(BackendTaskValues.time() + Double(60_000 * attempts))) }
                    else { reminders[index] = reminders[index].setting("lastError", .string((outcome.retry ? "stopped after \(attempts) tries: " : "skipped: ") + (outcome.reason ?? "Delivery failed"))) }
                }
                d = d.setting("reminders", .array(reminders)); if touched { try await persist(task, d: d) }
                if task.value["deletedAt"].isNullish {
                    for row in d["comments"].elements ?? [] {
                        guard let id = row["id"].string else { continue }; var meta = d["commentMeta"][id]
                        guard meta["deliveredAt"].isNullish, let date = Self.date(meta["scheduledFor"].string ?? ""), date.timeIntervalSince1970 * 1_000 <= BackendTaskValues.time() else { continue }
                        meta = meta.setting("deliveredAt", .string(BackendTaskOutbox.iso(BackendTaskValues.time()))); d = d.setting("commentMeta", d["commentMeta"].setting(id, meta)); try await save(task, d: d, by: row["authorUserId"].string ?? "me", kind: "comment", payload: BackendTaskValues.object([("comment_id", .string(id))]))
                        _ = try await deliveryReply(task, body: row["body"].string ?? "", by: row["authorUserId"].string ?? "me")
                    }
                }
            }
        } catch is CancellationError {} catch { await problem(error.localizedDescription) }
    }
    private func arm() async {
        timer?.cancel(); timer = nil; guard !stopped else { return }
        do { if let due = try await nextDueAt() { timer = BackendTaskTimers.schedule(milliseconds: min(max(0, due - BackendTaskValues.time()), 3_600_000)) { [weak self] in await self?.wake() } } } catch { await problem(error.localizedDescription) }
    }
    func persist(_ task: BackendTaskRecord, d: NativeRPCValue) async throws {
        let patch = BackendTaskValues.object([("detail", d)])
        if task.value["deletedAt"].isNullish { _ = try await store.update(task.id, patch: patch) } else { try await store.updateInTrash(task.id, patch: patch) }
    }
    func save(_ task: BackendTaskRecord, d original: NativeRPCValue, by: String, kind: String? = nil, payload: NativeRPCValue = .object([])) async throws {
        var d = original
        if let kind { var activity = d["activity"].elements ?? []; activity.append(BackendTaskValues.object([("id", .string(UUID().uuidString.lowercased())), ("kind", .string(kind)), ("payload", payload), ("by", .string(by)), ("at", .number(BackendTaskValues.time()))])); d = d.setting("activity", .array(Array(activity.suffix(500)))) }
        try await persist(task, d: d)
    }
    func detail(_ task: BackendTaskRecord) -> NativeRPCValue {
        var d = task.value["detail"].fields == nil ? NativeRPCValue.object([]) : task.value["detail"]
        for key in ["people", "subtasks", "checklists", "dependencies", "attachments", "fields", "comments", "activity", "covered", "time", "reminders", "occurrences"] where d[key].isNullish { d = d.setting(key, .array([])) }
        for key in ["commentMeta", "reactions", "followers"] where d[key].isNullish { d = d.setting(key, .object([])) }
        for key in ["routine", "recurrenceRule", "routineError", "nextId"] where d[key].isNullish { d = d.setting(key, .null) }; if d["v"].isNullish { d = d.setting("v", .number(1)) }; if d["routineVersion"].isNullish { d = d.setting("routineVersion", .number(0)) }; if d["syncSubtaskDates"].isNullish { d = d.setting("syncSubtaskDates", .bool(false)) }; return d
    }
    private func requirePerson(_ value: NativeRPCValue) async throws { if value.isNullish { return }; guard let id = value.string, try await people.known(id) else { throw NativeRPCError.invalidArguments("That person is not one of yours: you, Hoot or one of your task agents.") } }
    private func join(_ d: NativeRPCValue, task: BackendTaskRecord, person: String) -> NativeRPCValue {
        var people = d["people"].elements ?? []; if person != task.value["assignee"]["identity"].string, !people.contains(.string(person)) { people.append(.string(person)) }; return d.setting("people", .array(people))
    }
    private static func span(_ d: NativeRPCValue) -> (start: String, due: String)? { let dates = (d["subtasks"].elements ?? []).compactMap { $0["dueDate"].string }.sorted(); guard let first = dates.first, let last = dates.last else { return nil }; return (first, last) }
    private func reportUpdateFailure(_ error: any Error) async { await problem("The task was changed, but its Activity record could not be saved: " + error.localizedDescription) }
    public func noteUpdated(before: BackendTaskRecord, after: BackendTaskRecord, notes: [NativeRPCValue], by: String) async throws {
        guard after.isLocal, let current = try await store.byID(after.id) else { return }; var d = detail(current), activity = d["activity"].elements ?? [], dates = NativeRPCValue.object([])
        func add(_ kind: String, _ payload: NativeRPCValue) { activity.append(BackendTaskValues.object([("id", .string(UUID().uuidString.lowercased())), ("kind", .string(kind)), ("payload", payload), ("by", .string(by)), ("at", .number(BackendTaskValues.time()))])) }
        let kinds = ["title": "title", "instructions": "description", "crmStatus": "status", "priority": "priority", "board": "moved", "taskType": "task_type", "estimateMinutes": "estimate"]
        for (key, kind) in kinds where before.value[key] != after.value[key] { add(kind, BackendTaskValues.object([("from", before.value[key].isNullish ? .null : before.value[key]), ("to", after.value[key].isNullish ? .null : after.value[key])])) }
        if before.project != after.project { add("field", BackendTaskValues.object([("action", .string("changed")), ("label", .string("Project folder")), ("from", .string(before.project)), ("to", .string(after.project))])) }
        if before.value["archivedAt"].isNullish != after.value["archivedAt"].isNullish { add("archived", BackendTaskValues.object([("on", .bool(!after.value["archivedAt"].isNullish))])) }
        if before.value["assignee"]["identity"] != after.value["assignee"]["identity"] { let who = after.value["assignee"]["identity"].string ?? "none"; if who == "none" { add("unassigned", BackendTaskValues.object([("user_id", before.value["assignee"]["identity"])])) } else { let person = try await people.named(who); add("assigned", BackendTaskValues.object([("user_id", .string(who)), ("name", person["name"]), ("primary", .bool(true))])) } }
        for (key, prefix) in [("startDate", "start"), ("dueDate", "due"), ("startTime", "start_time"), ("dueTime", "due_time")] where before.value[key] != after.value[key] { dates = dates.setting(prefix + "_from", before.value[key].isNullish ? .null : before.value[key]).setting(prefix + "_to", after.value[key].isNullish ? .null : after.value[key]) }
        if !dates.spreadFields.isEmpty { add("dates", dates) }
        let was = Set((before.value["labels"].elements?.compactMap(\.string) ?? []).map { $0.lowercased() }), now = Set((after.value["labels"].elements?.compactMap(\.string) ?? []).map { $0.lowercased() })
        for label in after.value["labels"].elements?.compactMap(\.string) ?? [] where !was.contains(label.lowercased()) { add("tags", BackendTaskValues.object([("added", .string(label)), ("removed", .null)])) }
        for label in before.value["labels"].elements?.compactMap(\.string) ?? [] where !now.contains(label.lowercased()) { add("tags", BackendTaskValues.object([("added", .null), ("removed", .string(label))])) }
        var covered = d["covered"].elements ?? []; for note in notes { covered.append(.string("\(Int(note["at"].number ?? 0))|\(note["kind"].string ?? "")|\(note["text"].string ?? "")")) }
        d = d.setting("activity", .array(Array(activity.suffix(500)))).setting("covered", .array(Array(covered.suffix(200)))); try await persist(current, d: d)
        if before.value["crmStatus"] != after.value["crmStatus"] { noteStatus(after.id, by: by) }
    }
    private func noteActivity(_ task: BackendTaskRecord) -> [NativeRPCValue] {
        let covered = Set(detail(task)["covered"].elements?.compactMap(\.string) ?? []); var rows: [NativeRPCValue] = [], status = NativeRPCValue.null
        for note in task.value["notes"].elements ?? [] {
            let kind = note["kind"].string ?? "", text = note["text"].string ?? "", key = "\(Int(note["at"].number ?? 0))|\(kind)|\(text)", id = "note-\(Int(note["at"].number ?? 0))-\(Self.hash(key))"
            func row(_ kind: String, payload: NativeRPCValue = .object([]), suffix: String = "") -> NativeRPCValue { BackendTaskValues.object([("id", .string(id + suffix)), ("kind", .string(kind)), ("payload", payload), ("by", note["by"]), ("at", note["at"])]) }
            if kind == "status" { let next = NativeRPCValue.string(text.replacingOccurrences(of: #"^Status:\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)); if !covered.contains(key) { rows.append(row("status", payload: BackendTaskValues.object([("from", status), ("to", next)]))) }; status = next; continue }
            if covered.contains(key) { continue }
            if kind == "assigned" { let name = text == "Handed to you." ? "You" : text.replacingOccurrences(of: #"^Assigned to\s*"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression); rows.append(row(name == "nobody" ? "unassigned" : "assigned", payload: BackendTaskValues.object([("user_id", name == "You" ? .string("me") : .null), ("name", .string(name)), ("primary", .bool(true))]))); continue }
            guard kind == "edited" else { continue }
            if text.hasPrefix("Created") { rows.append(row("created")) }
            else if text == "Archived." { rows.append(row("archived", payload: BackendTaskValues.object([("on", .bool(true))]))) }
            else if text.hasPrefix("Restored") { rows.append(row("archived", payload: BackendTaskValues.object([("on", .bool(false))]))) }
            else if text.hasPrefix("Changed the ") { let fields = text.dropFirst("Changed the ".count).trimmingCharacters(in: CharacterSet(charactersIn: ".")).components(separatedBy: ", "); if fields.contains("title") { rows.append(row("title", suffix: "-t")) }; if fields.contains("details") || fields.contains("instructions") { rows.append(row("description", suffix: "-d")) }; if fields.contains(where: { $0.range(of: "date|time", options: [.regularExpression, .caseInsensitive]) != nil }) { rows.append(row("dates", suffix: "-w")) } }
        }; return rows
    }
    private func sorted(_ rows: NativeRPCValue) -> NativeRPCValue { .array((rows.elements ?? []).sorted { ($0["sortOrder"].number ?? 0) < ($1["sortOrder"].number ?? 0) }) }
    func ok(_ pairs: [(String, NativeRPCValue)] = []) -> NativeRPCValue { BackendTaskValues.object([("ok", .bool(true))] + pairs) }
    private static var emptyMeta: NativeRPCValue { BackendTaskValues.object([("parentId", .null), ("resolvedAt", .null), ("resolvedBy", .null), ("assigneeUserId", .null), ("scheduledFor", .null)]) }
    private static func mirror(_ kind: String) -> String { kind == "blocks" ? "blocked_by" : kind == "blocked_by" ? "blocks" : "linked" }
    private static func date(_ text: String) -> Date? { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; if let date = formatter.date(from: text) { return date }; formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: text) }
    private static func hash(_ text: String) -> String { var h: UInt32 = 5_381; for char in text.utf16 { h = (h &* 33) ^ UInt32(char) }; return String(h, radix: 16) }
    func enter() async { if !busy { busy = true; return }; await withCheckedContinuation { waiters.append($0) } }
    func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }
    public func noteStatus(_ id: String, by: String = BackendTaskActor.current) {
        guard !stopped else { return }; recurrencePending.append((id, by))
        if recurrenceJob == nil { recurrenceJob = Task { [weak self] in await self?.runStatusQueue() } }
    }
    func runStatusQueue() async {
        await enter(); defer { leave() }
        while !stopped, !Task.isCancelled, !recurrencePending.isEmpty { let next = recurrencePending.removeFirst(); do { try await afterStatus(next.id, by: next.actor) } catch { await problem(error.localizedDescription) } }
        recurrenceJob = nil; await arm()
    }
    public func settled() async { while recurrenceJob != nil || dueJob != nil { if let job = recurrenceJob { await job.value } else if let job = dueJob { await job.value } } }
}
