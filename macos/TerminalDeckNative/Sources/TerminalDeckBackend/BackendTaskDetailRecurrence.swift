import Foundation
import TerminalDeckNativeCore

/// task-detail-local.ts occurrence lifecycle. Calendar/rule validation is
/// exclusively BackendCrmRoutineRules; no second recurrence implementation.
extension BackendTaskDetailService {
    static let recurrenceFunctions: Set<String> = ["fetchRoutine", "saveRoutine", "stopRoutine", "pauseRoutine", "restartRoutine", "setTaskRecurrence"]
    func recurrenceCall(_ fn: String, arguments a: [NativeRPCValue], by: String) async throws -> NativeRPCValue {
        func arg(_ n: Int) -> NativeRPCValue { n < a.count ? a[n] : .missing }
        let asked = try await local.task(arg(0).requireString("task", nonempty: true)), resolved = try await resolveRepeat(asked), root = resolved.root
        var d = detail(root), rule = resolved.rule
        switch fn {
        case "fetchRoutine": return ok([("routine", try await repeatView(asked))])
        case "saveRoutine":
            if let version = arg(2).number, version != (d["routineVersion"].number ?? 0) { throw NativeRPCError.invalidArguments("This routine was changed since it was opened — reload and try again.") }
            if arg(1).isNullish { rule = nil }
            else {
                guard arg(1).fields != nil else { throw NativeRPCError.invalidArguments("Choose how often it repeats.") }
                if let refusal = BackendCrmRoutineRules.routineRefusal(BackendCrmWire.crm(arg(1)), today: today()) { throw NativeRPCError.invalidArguments(refusal) }
                guard var clean = BackendCrmRoutineRules.normalizeRoutine(BackendCrmWire.crm(arg(1))) else { throw NativeRPCError.invalidArguments("Choose how often it repeats.") }
                clean.anchor = clean.anchor ?? root.value["dueDate"].string ?? today(); clean.pausedAt = nil; clean.stoppedAt = nil; clean.rootTaskId = nil; rule = clean
            }
            try await writeRepeat(root, rule: rule, by: by); try await repeatError(root.id, message: nil)
            return ok([("rootTaskId", .string(root.id)), ("version", .number((d["routineVersion"].number ?? 0) + 1))])
        case "setTaskRecurrence":
            if arg(1).isNullish { rule = nil; d = d.setting("recurrenceRule", .null) }
            else { guard let frequency = arg(1).string, BackendCrmRecurrence.isTaskRecurrence(frequency) else { throw NativeRPCError.invalidArguments("Invalid recurrence") }; var legacy = BackendCrmRoutineRules.ruleFromLegacy(frequency); legacy.anchor = root.value["dueDate"].string ?? today(); rule = legacy; d = d.setting("recurrenceRule", arg(2).fields == nil ? .null : BackendCrmWire.native(BackendCrmTaskPage.normalizeRecurrenceRule(BackendCrmWire.crm(arg(2))))) }
            try await persist(root, d: d); try await writeRepeat(try await local.task(root.id), rule: rule, by: by); return ok()
        case "stopRoutine": guard var current = rule, current.stoppedAt == nil else { throw NativeRPCError.invalidArguments("This task does not repeat.") }; current.stoppedAt = iso(); try await writeRepeat(root, rule: current, by: by); return ok()
        case "pauseRoutine":
            guard var current = rule, current.stoppedAt == nil else { throw NativeRPCError.invalidArguments("This task does not repeat.") }; current.pausedAt = arg(1).bool == true ? iso() : nil
            d = d.setting("routine", BackendCrmWire.native(BackendCrmRoutineRules.serializeRoutine(current))).setting("routineVersion", .number((d["routineVersion"].number ?? 0) + 1)); try await persist(root, d: d); return ok()
        case "restartRoutine":
            guard let rule, BackendCrmRoutineRules.isActive(rule), rule.trigger == "status" else { throw NativeRPCError.invalidArguments("This routine cannot be restarted.") }
            guard root.value["archivedAt"].isNullish else { throw NativeRPCError.invalidArguments("This routine’s task is archived — restore it first.") }
            guard try await repeatStuck(root, rule: rule) != nil else { throw NativeRPCError.invalidArguments("This routine is not stuck: one of its tasks is still open.") }
            let history = repeatHistory(root), anchor = anchor(root, rule: rule, task: root), chain = try await repeatChain(root)
            let taken = Set(history.filter { $0["status"].string != "skipped" }.compactMap { $0["date"].string } + chain.compactMap { $0.value["dueDate"].string })
            let base = BackendCrmRoutineRules.nextMovesWithDue(rule) ? anchor : today(); var date = BackendCrmRoutineRules.nextAfter(base, rule: rule, after: today())
            for _ in 0..<5_000 { if !taken.contains(date) { break }; date = BackendCrmRoutineRules.nextAfter(base, rule: rule, after: date) }
            guard !BackendCrmRoutineRules.isPastEnd(rule, date, occurrencesSoFar: datesSoFar(root)) else { throw NativeRPCError.invalidArguments("This routine has ended.") }
            let nextID: String
            if !rule.createNew { try await appendOccurrence(root.id, date: date, person: nil, taskID: root.id); _ = try await store.update(root.id, patch: BackendTaskValues.object([("detail", detail(try await local.task(root.id)).setting("nextId", .null))])); try await bringBack(root, rule: rule, date: date, start: withLead(root, nextDue: date), by: by); nextID = root.id }
            else {
                nextID = try await makeOccurrence(rootID: root.id, source: root, rule: rule, date: date, start: withLead(root, nextDue: date), person: nil, by: by)
                for item in chain where item.id != nextID && detail(item)["nextId"].isNullish { let current = try await local.task(item.id); try await persist(current, d: detail(current).setting("nextId", .string(nextID))) }
            }
            let current = try await local.task(root.id); try await save(current, d: detail(current), by: by, kind: "recurrence", payload: BackendTaskValues.object([("restarted", .bool(true))])); try await repeatError(root.id, message: nil); return ok([("taskId", .string(nextID))])
        default: throw NativeRPCError.invalidArguments("Unknown task repeat operation")
        }
    }
    func resolveRepeat(_ task: BackendTaskRecord) async throws -> (root: BackendTaskRecord, rule: RoutineRule?) {
        var rule = BackendCrmRoutineRules.normalizeRoutine(BackendCrmWire.crm(detail(task)["routine"]))
        // The link is read as stored (task-detail-local.ts resolveRoutine): normalizeRoutine refuses ids with ":" such as "local:…".
        if rule != nil, let rootID = detail(task)["routine"]["rootTaskId"].string, !rootID.isEmpty, rootID != task.id {
            if let root = try await store.byID(rootID), root.isLocal { return (root, BackendCrmRoutineRules.normalizeRoutine(BackendCrmWire.crm(detail(root)["routine"]))) }
            rule?.rootTaskId = nil; if rule?.stoppedAt == nil { rule?.stoppedAt = iso() }; return (task, rule)
        }; rule?.rootTaskId = nil; return (task, rule)
    }
    func repeatHistory(_ root: BackendTaskRecord) -> [NativeRPCValue] { (detail(root)["occurrences"].elements ?? []).sorted { ($0["date"].string ?? "") > ($1["date"].string ?? "") } }
    func datesSoFar(_ root: BackendTaskRecord) -> Int { Set(repeatHistory(root).filter { $0["status"].string != "skipped" }.compactMap { $0["date"].string }).count }
    func today() -> String { BackendCrmTime.localToday(Date(timeIntervalSince1970: BackendTaskValues.time() / 1_000)) }
    func iso() -> String { BackendTaskOutbox.iso(BackendTaskValues.time()) }
    func finishedFor(_ task: BackendTaskRecord, rule: RoutineRule) -> Bool { task.value["crmStatus"].string == "Done" || (rule.trigger == "status" && task.value["crmStatus"].string == rule.triggerStatus) }
    func everyone(_ task: BackendTaskRecord) -> [String] { var ids = task.assigneeKind == "none" ? [] : [task.value["assignee"]["identity"].string ?? task.agentID]; for id in detail(task)["people"].elements?.compactMap(\.string) ?? [] where !ids.contains(id) { ids.append(id) }; return ids }
    func withLead(_ task: BackendTaskRecord, nextDue: String) -> String? { guard let start = task.value["startDate"].string else { return nil }; let lead = task.value["dueDate"].string.map { max(0, BackendCrmRoutineRules.daysBetween(start, $0)) } ?? 0; return BackendCrmRoutineRules.addDays(nextDue, -lead) }
    func anchor(_ root: BackendTaskRecord, rule: RoutineRule, task: BackendTaskRecord) -> String {
        BackendCrmRoutineRules.routineAnchor(rule, rootDue: root.value["dueDate"].string, oldest: repeatHistory(root).last?["date"].string, taskDue: task.value["dueDate"].string, today: today())
    }
    func scheduleAnchor(_ root: BackendTaskRecord, rule: RoutineRule) -> String { rule.anchor ?? repeatHistory(root).last?["date"].string ?? root.value["dueDate"].string ?? BackendCrmTime.localToday(Date(timeIntervalSince1970: (root.value["createdAt"].number ?? BackendTaskValues.time()) / 1_000)) }
    func repeatChain(_ root: BackendTaskRecord) async throws -> [BackendTaskRecord] { try await store.all().filter { $0.isLocal && ($0.id == root.id || $0.value["detail"]["routine"]["rootTaskId"].string == root.id) } }
    func repeatStuck(_ root: BackendTaskRecord, rule: RoutineRule?) async throws -> String? {
        guard let rule, BackendCrmRoutineRules.isActive(rule), rule.trigger == "status" else { return nil }; let chain = try await repeatChain(root)
        if chain.contains(where: { $0.value["archivedAt"].isNullish && !finishedFor($0, rule: rule) }) { return nil }
        if !chain.contains(where: { $0.value["archivedAt"].isNullish && detail($0)["nextId"].isNullish }), !chain.isEmpty { return nil }
        return "Nothing more will come: every task of this routine is finished and none brought the next one. Restart makes the next one."
    }
    func writeRepeat(_ task: BackendTaskRecord, rule: RoutineRule?, by: String) async throws {
        let current = try await local.task(task.id), active = rule?.stoppedAt == nil && rule != nil
        let d = detail(current).setting("routine", rule.map { BackendCrmWire.native(BackendCrmRoutineRules.serializeRoutine($0)) } ?? .null).setting("routineVersion", .number((detail(current)["routineVersion"].number ?? 0) + 1))
        _ = try await store.update(current.id, patch: BackendTaskValues.object([("recurrence", active ? .string(BackendCrmRoutineRules.legacyRecurrence(rule!)) : .null)]))
        try await save(current, d: d, by: by, kind: "recurrence", payload: BackendTaskValues.object([("to", active ? .string(BackendCrmRoutineRules.routineSummary(rule!)) : .null)]))
    }
    func repeatError(_ rootID: String, message: String?) async throws { let root = try await local.task(rootID); if message == nil && detail(root)["routineError"].isNullish { return }; try await persist(root, d: detail(root).setting("routineError", message.map { BackendTaskValues.object([("at", .string(iso())), ("message", .string($0))]) } ?? .null)) }
    @discardableResult func appendOccurrence(_ rootID: String, date: String, person: String?, taskID: String?, status: String = "open") async throws -> String {
        let root = try await local.task(rootID), id = UUID().uuidString.lowercased(), row = BackendTaskValues.object([("id", .string(id)), ("date", .string(date)), ("dueDate", .string(date)), ("person", person.map(NativeRPCValue.string) ?? .null), ("taskId", taskID.map(NativeRPCValue.string) ?? .null), ("status", .string(status)), ("completedAt", .null), ("completedBy", .null)])
        try await persist(root, d: detail(root).setting("occurrences", .array((detail(root)["occurrences"].elements ?? []) + [row]))); return id
    }
    func makeOccurrence(rootID: String, source: BackendTaskRecord, rule: RoutineRule, date: String, start: String?, person: String?, by: String) async throws -> String {
        let occurrenceID = try await appendOccurrence(rootID, date: date, person: person, taskID: nil)
        var input = BackendTaskValues.object([("title", source.value["title"]), ("instructions", source.value["instructions"]), ("project", .string(source.project)), ("assignee", .string(person ?? (source.assigneeKind == "none" ? "none" : source.value["assignee"]["identity"].string ?? source.agentID))), ("status", .string(rule.updateStatusTo)), ("startDate", start.map(NativeRPCValue.string) ?? .null), ("dueDate", .string(date))])
        for key in ["priority", "labels", "board", "taskType", "estimateMinutes"] { input = input.setting(key, source.value[key].isNullish ? (key == "labels" ? .array([]) : key == "taskType" ? .string("task") : .null) : source.value[key]) }
        let copy: BackendTaskRecord
        do { copy = try await local.create(input, by: by) }
        catch { let root = try await local.task(rootID); try await persist(root, d: detail(root).setting("occurrences", .array((detail(root)["occurrences"].elements ?? []).filter { $0["id"].string != occurrenceID }))); throw error }
        let root = try await local.task(rootID), records = (detail(root)["occurrences"].elements ?? []).map { $0["id"].string == occurrenceID ? $0.setting("taskId", .string(copy.id)) : $0 }; try await persist(root, d: detail(root).setting("occurrences", .array(records)))
        var childRule = rule; childRule.rootTaskId = rootID; var d = detail(copy).setting("routine", BackendCrmWire.native(BackendCrmRoutineRules.serializeRoutine(childRule)))
        let from = detail(source)
        if person == nil { d = d.setting("people", .array((from["people"].elements ?? []).filter { $0.string != copy.value["assignee"]["identity"].string })) }
        d = d.setting("subtasks", .array((from["subtasks"].elements ?? []).map { $0.setting("id", .string(UUID().uuidString.lowercased())).setting("done", .bool(false)) }))
        d = d.setting("checklists", .array((from["checklists"].elements ?? []).map { list in list.setting("id", .string(UUID().uuidString.lowercased())).setting("items", .array((list["items"].elements ?? []).map { $0.setting("id", .string(UUID().uuidString.lowercased())).setting("done", .bool(false)) })) }))
        _ = try await store.update(copy.id, patch: BackendTaskValues.object([("recurrence", root.value["recurrence"].string.map(NativeRPCValue.string) ?? .string(BackendCrmRoutineRules.legacyRecurrence(rule))), ("detail", d)])); return copy.id
    }
    func bringBack(_ task: BackendTaskRecord, rule: RoutineRule, date: String, start: String?, by: String) async throws { _ = try await local.update(task.id, input: BackendTaskValues.object([("status", .string(rule.updateStatusTo)), ("startDate", start.map(NativeRPCValue.string) ?? .null), ("dueDate", .string(date))]), by: by) }
    func afterStatus(_ taskID: String, by: String) async throws {
        guard let task = try await store.byID(taskID), task.isLocal else { return }; let resolved = try await resolveRepeat(task), root = resolved.root
        guard let rule = resolved.rule else { return }
        var d = detail(root), records = d["occurrences"].elements ?? []
        if let index = repeatHistory(root).first(where: { $0["taskId"].string == task.id })?["id"].string, let i = records.firstIndex(where: { $0["id"].string == index }) {
            if finishedFor(task, rule: rule), ["open", "missed"].contains(records[i]["status"].string ?? "") { records[i] = records[i].setting("status", .string("done")).setting("completedAt", .string(BackendTaskOutbox.iso(task.value["completedAt"].number ?? BackendTaskValues.time()))).setting("completedBy", .string(by)) }
            else if !finishedFor(task, rule: rule), records[i]["status"].string == "done" { records[i] = records[i].setting("status", .string("open")).setting("completedAt", .null).setting("completedBy", .null) }
            d = d.setting("occurrences", .array(records)); try await persist(root, d: d)
        }
        guard BackendCrmRoutineRules.isActive(rule), root.value["recurrence"].string != nil, root.value["archivedAt"].isNullish, rule.trigger == "status", task.value["crmStatus"].string == rule.triggerStatus, detail(task)["nextId"].isNullish else { return }
        let updatedRoot = try await local.task(root.id), rows = repeatHistory(updatedRoot), anchor = anchor(updatedRoot, rule: rule, task: task), own = rows.first { $0["taskId"].string == task.id && $0["status"].string != "skipped" }
        let date = BackendCrmRoutineRules.nextDateOnDone(rule, anchor: anchor, occurrence: own?["date"].string, due: task.value["dueDate"].string, today: today(), own: rows.filter { $0["taskId"].string == task.id }.compactMap { $0["date"].string })
        let newDate = !rows.contains { $0["date"].string == date && $0["status"].string != "skipped" }, count = datesSoFar(updatedRoot) - (newDate ? 0 : 1)
        guard !BackendCrmRoutineRules.isPastEnd(rule, date, occurrencesSoFar: count) else { return }
        if !rule.createNew {
            let occurrence = try await appendOccurrence(root.id, date: date, person: nil, taskID: task.id)
            do { try await bringBack(task, rule: rule, date: date, start: withLead(task, nextDue: date), by: by); try await repeatError(root.id, message: nil) }
            catch { let current = try await local.task(root.id); try await persist(current, d: detail(current).setting("occurrences", .array((detail(current)["occurrences"].elements ?? []).filter { $0["id"].string != occurrence }))); try await repeatError(root.id, message: "The next one (\(BackendCrmRoutineRules.shortDay(date))) could not be made: \(error.localizedDescription) Mark it done again to retry.") }; return
        }
        let persons: [String?] = rule.perAssignee ? (task.id == root.id ? everyone(updatedRoot).map(Optional.some) : [task.assigneeKind == "none" ? nil : task.value["assignee"]["identity"].string]) : [nil]
        var made: [String] = [], failed: [String] = []
        for person in persons.isEmpty ? [nil] : persons {
            if rows.contains(where: { $0["date"].string == date && $0["person"].string == person && $0["status"].string != "skipped" }) { continue }
            do { made.append(try await makeOccurrence(rootID: root.id, source: rule.perAssignee ? updatedRoot : task, rule: rule, date: date, start: withLead(task, nextDue: date), person: person, by: by)) }
            catch { failed.append("\(await personName(person)): \(error.localizedDescription)") }
        }
        if !failed.isEmpty { try await repeatError(root.id, message: "Not every copy was made (\(failed.count) of \(persons.count)): \(failed.joined(separator: "; ")) Mark it done again to retry — only the missing ones are made."); return }
        if let id = made.first { let current = try await local.task(task.id); try await persist(current, d: detail(current).setting("nextId", .string(id))); try await repeatError(root.id, message: nil) }
    }
    func personName(_ person: String?) async -> String { guard let person else { return "the task" }; return (try? await people.named(person))?["name"].string ?? person }
    func nextRepeatDue() async throws -> Double? {
        var dates: [Double] = []
        for task in try await store.all() where task.isLocal { guard let rule = BackendCrmRoutineRules.normalizeRoutine(BackendCrmWire.crm(detail(task)["routine"])), (detail(task)["routine"]["rootTaskId"].string ?? "").isEmpty, rule.trigger == "schedule", BackendCrmRoutineRules.isActive(rule), task.value["recurrence"].string != nil, task.value["archivedAt"].isNullish else { continue }
            let rows = repeatHistory(task), anchor = scheduleAnchor(task, rule: rule), next = BackendCrmRoutineRules.nextAfter(anchor, rule: rule, after: rows.first?["date"].string ?? anchor)
            guard !BackendCrmRoutineRules.isPastEnd(rule, next, occurrencesSoFar: datesSoFar(task)), let time = BackendCrmRoutineRules.localInstant(next, rule.timeOfDay) else { continue }; dates.append(time.timeIntervalSince1970 * 1_000)
        }; return dates.min()
    }
    func runRepeatSchedules(by: String = BackendTaskActor.current) async throws {
        for root in try await store.all() where root.isLocal {
            guard let rule = BackendCrmRoutineRules.normalizeRoutine(BackendCrmWire.crm(detail(root)["routine"])), (detail(root)["routine"]["rootTaskId"].string ?? "").isEmpty, rule.trigger == "schedule", BackendCrmRoutineRules.isActive(rule), root.value["recurrence"].string != nil, root.value["archivedAt"].isNullish else { continue }
            let rows = repeatHistory(root), anchor = scheduleAnchor(root, rule: rule), due = BackendCrmRoutineRules.dueScheduleDates(anchor: anchor, last: rows.first?["date"].string ?? anchor, rule: rule, now: Date(timeIntervalSince1970: BackendTaskValues.time() / 1_000), datesSoFar: datesSoFar(root))
            guard let date = due.latest else { continue }; var d = detail(root), history = d["occurrences"].elements ?? []
            for skipped in due.gap where !history.contains(where: { $0["date"].string == skipped }) { history.append(BackendTaskValues.object([("id", .string(UUID().uuidString.lowercased())), ("date", .string(skipped)), ("dueDate", .string(skipped)), ("person", .null), ("taskId", .null), ("status", .string("skipped")), ("completedAt", .null), ("completedBy", .null)])) }
            if rule.missedPolicy == "mark_missed" { for i in history.indices where history[i]["status"].string == "open" && (history[i]["date"].string ?? "") < date { history[i] = history[i].setting("status", .string("missed")); if let id = history[i]["taskId"].string, id != root.id, let copy = try await store.byID(id) { let labels = copy.value["labels"].elements?.compactMap(\.string) ?? []; if labels.count < 20, !labels.contains(where: { $0.lowercased() == "missed" }) { _ = try await store.update(id, patch: BackendTaskValues.object([("labels", .array((labels + ["Missed"]).map(NativeRPCValue.string)))])) } } } }
            d = d.setting("occurrences", .array(history)); try await persist(root, d: d)
            if !rule.createNew {
                if history.contains(where: { $0["date"].string == date && $0["person"].isNullish && $0["status"].string != "skipped" }) { continue }
                try await appendOccurrence(root.id, date: date, person: nil, taskID: root.id); let current = try await local.task(root.id); try await persist(current, d: detail(current).setting("nextId", .null))
                do { try await bringBack(root, rule: rule, date: date, start: withLead(root, nextDue: date), by: by); try await repeatError(root.id, message: nil) } catch { try await repeatError(root.id, message: "The one for \(BackendCrmRoutineRules.shortDay(date)) could not be made: \(error.localizedDescription)") }; continue
            }
            let persons: [String?] = rule.perAssignee ? everyone(root).map(Optional.some) : [nil]; var failures: [String] = []
            for person in persons.isEmpty ? [nil] : persons { if history.contains(where: { $0["date"].string == date && $0["person"].string == person && $0["status"].string != "skipped" }) { continue }; do { _ = try await makeOccurrence(rootID: root.id, source: root, rule: rule, date: date, start: withLead(root, nextDue: date), person: person, by: by) } catch { failures.append("\(await personName(person)): \(error.localizedDescription)") } }
            try await repeatError(root.id, message: failures.isEmpty ? nil : "The one for \(BackendCrmRoutineRules.shortDay(date)) was not made for \(failures.joined(separator: "; ")) It is tried again at the next time.")
        }
    }
    func repeatView(_ task: BackendTaskRecord) async throws -> NativeRPCValue {
        let resolved = try await resolveRepeat(task), root = resolved.root, rule = resolved.rule, rows = repeatHistory(root), stuck = try await repeatStuck(root, rule: rule)
        let anchor = rule.map { $0.trigger == "schedule" ? scheduleAnchor(root, rule: $0) : self.anchor(root, rule: $0, task: task) }, own = rows.first { $0["taskId"].string == task.id && $0["status"].string != "skipped" }
        var next: [String] = []
        if var active = rule, BackendCrmRoutineRules.isActive(active), stuck == nil { active.anchor = anchor; let from = active.trigger == "schedule" ? rows.first?["date"].string ?? anchor ?? today() : task.value["dueDate"].string ?? today(); next = BackendCrmRoutineRules.upcoming(from, rule: active, occurrencesSoFar: datesSoFar(root)) }
        var history: [CrmValue] = []
        for row in rows { let person = row["person"].string, name = try await person.asyncMap { try await self.people.named($0)["name"].string ?? $0 }; let occurrence = BackendCrmRoutineRules.OccurrenceRow(id: row["id"].string ?? "", occurrenceDate: row["date"].string ?? "", dueDate: row["dueDate"].string, assigneeUserId: person, spawnedTaskId: row["taskId"].string, status: row["status"].string ?? "open", completedAt: row["completedAt"].string, completedBy: row["completedBy"].string); history.append(BackendCrmWire.crm(BackendCrmWire.occurrence(occurrence, who: name, includeWho: true))) }
        let error = detail(root)["routineError"], lastError = error["at"].string.flatMap { at in error["message"].string.map { (at: at, message: $0) } }
        let view = RoutineView(rootTaskId: root.id, rootTitle: root.value["title"].string ?? "", isRoot: root.id == task.id, rule: rule.map(BackendCrmRoutineRules.serializeRoutine), canEdit: true, history: history, historyError: nil, lastError: lastError, next: next, peopleCount: everyone(root).count, version: detail(root)["routineVersion"].number ?? 0, stuck: stuck, canRestart: stuck != nil, anchor: anchor, occurrence: own?["date"].string, datesSoFar: datesSoFar(root))
        return BackendCrmWire.routine(view)
    }
}
