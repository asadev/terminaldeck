import Foundation
import TerminalDeckNativeCore

extension BackendTaskDetailService {
    static let fieldFunctions: Set<String> = ["listTaskFields", "createTaskField", "updateTaskFieldValue", "renameTaskField", "updateTaskFieldConfig", "reorderTaskFields", "deleteTaskField", "toggleTaskFieldVote", "pressTaskFieldButton"]
    func fieldCall(_ fn: String, arguments a: [NativeRPCValue], by: String) async throws -> NativeRPCValue {
        func arg(_ n: Int) -> NativeRPCValue { n < a.count ? a[n] : .missing }
        let id = try arg(0).requireString("task or field", nonempty: true)
        let task: BackendTaskRecord
        if ["listTaskFields", "createTaskField", "reorderTaskFields"].contains(fn) { task = try await local.task(id) }
        else {
            guard let found = try await store.all().first(where: { $0.isLocal && (detail($0)["fields"].elements ?? []).contains { $0["id"].string == id } }) else { throw NativeRPCError.invalidArguments("Field not found") }; task = found
        }
        var d = detail(task), fields = decodeFields(task), index = fields.firstIndex { $0.id == id }
        if fn == "listTaskFields" {
            var named = Set<String>(), rows = NativeRPCValue.object([])
            for field in fields {
                if field.kind.rawValue == "people" { for value in field.value.array ?? [] { if let id = value.string { named.insert(id) } } }
                if field.kind.rawValue == "signature", let who = field.value["by"]?.string { named.insert(who) }
                if field.kind.rawValue == "button", let who = field.value["lastBy"]?.string { named.insert(who) }
                if field.kind.rawValue == "voting" { for key in field.value["votes"]?.object?.keys ?? Dictionary<String, CrmValue>().keys { named.insert(key) } }
            }
            for who in named { rows = rows.setting(who, try await people.named(who)) }
            let auto = fields.contains { $0.kind.rawValue == "progress_auto" } ? BackendCrmWire.autoProgress(autoProgress(task)) : .null
            return ok([("fields", .array(BackendCrmFields.sortFields(fields).map(BackendCrmWire.field))), ("people", rows), ("auto", auto), ("viewerId", .string(BackendCrmDetailContract.meID))])
        }
        if fn == "createTaskField" {
            let input = try arg(1).requireObject("field"), label = try fieldResult(BackendCrmFields.normaliseFieldLabel(BackendCrmWire.crm(input["label"])))
            guard let kind = input["kind"].string.flatMap(FieldKind.init(rawValue:)) else { throw NativeRPCError.invalidArguments("Unknown field type") }
            guard fields.count < 100 else { throw NativeRPCError.invalidArguments("A task can hold 100 fields") }
            guard !fields.contains(where: { BackendCrmFields.sameLabel($0.label, label) }) else { throw NativeRPCError.invalidArguments("This task already has a field called “\(label)”") }
            let config = try fieldResult(BackendCrmFields.normaliseConfig(kind, input["config"].isNullish ? nil : BackendCrmWire.crm(input["config"]), siblings: fields))
            var value = CrmValue.null
            if !input["value"].isNullish, !BackendCrmFields.isComputedKind(kind), !BackendCrmFields.isActionOnlyKind(kind) { value = try await normalizedValue(task, kind: kind, config: config, raw: input["value"]) }
            let now = BackendTaskOutbox.iso(BackendTaskValues.time()), field = TaskField(id: UUID().uuidString.lowercased(), taskId: task.id, label: label, kind: kind, config: config, value: value, sortOrder: (fields.compactMap(\.sortOrder).max() ?? -1) + 1, createdBy: by, createdAt: now, updatedAt: now)
            fields.append(field); d = d.setting("fields", .array(fields.map(BackendCrmWire.field))); try await save(task, d: d, by: by, kind: "field", payload: BackendTaskValues.object([("action", .string("added")), ("field_id", .string(field.id)), ("label", .string(field.label)), ("kind", .string(kind.rawValue))])); return ok([("field", BackendCrmWire.field(field))])
        }
        if fn == "reorderTaskFields" {
            let order = try arg(1).requireArray("order").map { try $0.requireString("field id", nonempty: true) }
            guard Set(order).count == order.count else { throw NativeRPCError.invalidArguments("Invalid order") }
            guard Set(order) == Set(fields.map(\.id)) else { throw NativeRPCError.invalidArguments("The fields changed — reload and try again") }
            for i in fields.indices { fields[i].sortOrder = Double(order.firstIndex(of: fields[i].id)!) }; try await save(task, d: d.setting("fields", .array(fields.map(BackendCrmWire.field))), by: by); return ok()
        }
        guard let index else { throw NativeRPCError.invalidArguments("Field not found") }
        var field = fields[index], payload = BackendTaskValues.object([("field_id", .string(field.id)), ("label", .string(field.label))]), formulas: [TaskField] = []
        switch fn {
        case "updateTaskFieldValue":
            let old = BackendCrmFields.feedValue(BackendCrmFields.formatFieldValue(field)), value = try await normalizedValue(task, kind: field.kind, config: field.config, raw: arg(1))
            field.value = value; payload = payload.setting("action", .string("changed")).setting("from", old.map(NativeRPCValue.string) ?? .null).setting("to", BackendCrmFields.feedValue(BackendCrmFields.formatFieldValue(field)).map(NativeRPCValue.string) ?? .null)
        case "renameTaskField":
            let name = try fieldResult(BackendCrmFields.normaliseFieldLabel(BackendCrmWire.crm(arg(1)))), old = field.label
            if old == name { return ok([("field", BackendCrmWire.field(field)), ("formulas", .array([]))]) }
            guard !fields.contains(where: { $0.id != field.id && BackendCrmFields.sameLabel($0.label, name) }) else { throw NativeRPCError.invalidArguments("This task already has a field called “\(name)”") }
            field.label = name
            for i in fields.indices where fields[i].kind.rawValue == "formula" { if let expression = fields[i].config.expression, BackendCrmFields.formulaRefs(expression).contains(where: { BackendCrmFields.sameLabel($0, old) }) { fields[i].config.expression = BackendCrmFields.renameFormulaRefs(expression, from: old, to: name); formulas.append(fields[i]) } }
            payload = payload.setting("action", .string("renamed")).setting("label", .string(name)).setting("from", .string(old)).setting("to", .string(name))
        case "updateTaskFieldConfig":
            let config = try fieldResult(BackendCrmFields.normaliseConfig(field.kind, arg(1).isNullish ? nil : BackendCrmWire.crm(arg(1)), siblings: fields.filter { $0.id != field.id }))
            field.config = config; field.value = BackendCrmFields.reconcileValue(field.kind, config, field.value); payload = payload.setting("action", .string("options"))
        case "deleteTaskField":
            fields.remove(at: index); try await save(task, d: d.setting("fields", .array(fields.map(BackendCrmWire.field))), by: by, kind: "field", payload: payload.setting("action", .string("removed"))); return ok()
        case "toggleTaskFieldVote":
            guard field.kind.rawValue == "voting" else { throw NativeRPCError.invalidArguments("This field is not a vote") }
            var votes = field.value["votes"]?.object ?? [:]; let voted = votes[BackendCrmDetailContract.meID] != .bool(true)
            if voted { votes[BackendCrmDetailContract.meID] = .bool(true) } else { votes[BackendCrmDetailContract.meID] = nil }
            field.value = votes.isEmpty ? .null : .object(["votes": .object(votes)]); payload = payload.setting("action", .string("voted")).setting("to", .string(voted ? "voted" : "unvoted"))
        case "pressTaskFieldButton":
            guard field.kind.rawValue == "button" else { throw NativeRPCError.invalidArguments("This field is not a button") }
            guard let action = field.config.action else { throw NativeRPCError.invalidArguments("This button has no action — Edit options to choose one") }
            var target = NativeRPCValue.null, status = NativeRPCValue.null
            switch action {
            case .status(let value): _ = try await local.update(task.id, input: BackendTaskValues.object([("status", .string(value))]), by: by); status = .string(value)
            case .comment(let value): _ = try await addComment(task, body: .string(value), options: .object([]), by: by)
            case .field(let targetID, let value):
                guard fields.contains(where: { $0.id == targetID }) else { throw NativeRPCError.invalidArguments("The field this button sets is no longer on this task") }
                let reply = try await fieldCall("updateTaskFieldValue", arguments: [.string(targetID), BackendCrmWire.native(value)], by: by); target = reply["field"]
            }
            let current = try await local.task(task.id), latest = decodeFields(current); guard var button = latest.first(where: { $0.id == field.id }) else { throw NativeRPCError.invalidArguments("Field not found") }
            let now = BackendTaskOutbox.iso(BackendTaskValues.time()); button.value = .object(["count": .number((button.value["count"]?.number ?? 0) + 1), "lastBy": .string(by), "lastAt": .string(now)]); button.updatedAt = now
            let result = latest.map { $0.id == button.id ? button : $0 }; try await save(current, d: detail(current).setting("fields", .array(result.map(BackendCrmWire.field))), by: by, kind: "field", payload: payload.setting("action", .string("pressed")))
            return ok([("field", BackendCrmWire.field(button)), ("target", target), ("status", status)])
        default: throw NativeRPCError.invalidArguments("Unknown field operation")
        }
        field.updatedAt = BackendTaskOutbox.iso(BackendTaskValues.time()); fields[index] = field
        try await save(task, d: d.setting("fields", .array(fields.map(BackendCrmWire.field))), by: by, kind: "field", payload: payload)
        var reply = ok([("field", BackendCrmWire.field(field))]); if fn == "renameTaskField" { reply = reply.setting("formulas", .array(formulas.map(BackendCrmWire.field))) }; return reply
    }
    func decodeFields(_ task: BackendTaskRecord) -> [TaskField] {
        (detail(task)["fields"].elements ?? []).compactMap { row in
            var raw = BackendCrmWire.crm(row).object ?? [:]
            for (camel, snake) in [("taskId", "task_id"), ("sortOrder", "sort_order"), ("createdBy", "created_by"), ("createdAt", "created_at"), ("updatedAt", "updated_at")] { if raw[snake] == nil { raw[snake] = raw[camel] } }
            return BackendCrmFields.rowToField(.object(raw))
        }
    }
    func normalizedValue(_ task: BackendTaskRecord, kind: FieldKind, config: FieldConfig, raw: NativeRPCValue) async throws -> CrmValue {
        var input = BackendCrmWire.crm(raw), aliases: [String: String] = [:]
        if kind.rawValue == "people", let rows = input.array {
            var mapped: [CrmValue] = []
            for row in rows {
                guard let id = row.string else { mapped.append(row); continue }
                if try await people.known(id) { let alias = personAlias(id); aliases[alias] = id; mapped.append(.string(alias)) } else { mapped.append(row) }
            }; input = .array(mapped)
        }
        if kind.rawValue == "tasks", let rows = input.array {
            var mapped: [CrmValue] = []
            for row in rows { var value = row.object ?? [:]; if let id = value["id"]?.string, let record = try await store.byID(id) { value["id"] = BackendCrmWire.crm(record.value["externalTaskId"]) }; mapped.append(row.object == nil ? row : .object(value)) }; input = .array(mapped)
        }
        let value = try fieldResult(BackendCrmFields.normaliseValue(kind, config, input, ctx: ValueCtx(userId: BackendCrmDetailContract.meID, now: BackendTaskOutbox.iso(BackendTaskValues.time()))))
        if value == .null { return .null }
        if kind.rawValue == "people" { return .array(try (value.array ?? []).map { row in guard let key = row.string, let id = aliases[key] else { throw NativeRPCError.invalidArguments("A person is not one of yours") }; return .string(id) }) }
        if kind.rawValue == "tasks" {
            let all = try await store.all().filter(\.isLocal)
            return .array(try (value.array ?? []).map { row in guard let linked = all.first(where: { $0.value["externalTaskId"].string == row["id"]?.string }) else { throw NativeRPCError.invalidArguments("A linked task no longer exists") }; guard linked.id != task.id else { throw NativeRPCError.invalidArguments("A task cannot link to itself") }; return .object(["id": .string(linked.id), "label": BackendCrmWire.crm(linked.value["title"])]) })
        }
        if kind.rawValue == "files" {
            let attachments = detail(task)["attachments"].elements ?? []
            return .array(try (value.array ?? []).map { row in guard let id = row["id"]?.string, let file = attachments.first(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("A file is not attached to this task") }; return .object(["id": .string(id), "name": BackendCrmWire.crm(file["fileName"]), "mime": BackendCrmWire.crm(file["mimeType"])]) })
        }; return value
    }
    func autoProgress(_ task: BackendTaskRecord) -> AutoProgress {
        let d = detail(task), subtasks = d["subtasks"].elements ?? [], items = (d["checklists"].elements ?? []).flatMap { $0["items"].elements ?? [] }
        return AutoProgress(subtasksDone: subtasks.filter { $0["done"].bool == true }.count, subtasksTotal: subtasks.count, checklistsDone: items.filter { $0["done"].bool == true }.count, checklistsTotal: items.count)
    }
    func fieldResult<T>(_ result: FieldRes<T>) throws -> T { switch result { case .success(let value): return value; case .failure(let error): throw NativeRPCError.invalidArguments(error.error) } }
    func personAlias(_ id: String) -> String {
        func hash(_ text: String) -> String { var h: UInt32 = 5_381; for c in text.utf16 { h = (h &* 33) ^ UInt32(c) }; return String(format: "%08x", h) }
        return "00000000-0000-4000-8000-" + String((hash("p1:" + id) + hash("p2:" + id)).prefix(12))
    }
}
