import Foundation
import TerminalDeckNativeCore

extension BackendTaskDetailService {
    static let extraFunctions: Set<String> = ["uploadTaskFile", "chooseTaskFiles", "openTaskFile", "attachExistingDocument", "detachTaskAttachment", "setLabelColor", "deleteLabelEverywhere", "searchTags", "chooseTaskProject", "duplicateTask", "mergeTaskInto", "convertToSubtask", "toggleCommentReaction"]
    func extraCall(_ fn: String, arguments a: [NativeRPCValue], by: String) async throws -> NativeRPCValue {
        func arg(_ n: Int) -> NativeRPCValue { n < a.count ? a[n] : .missing }
        func string(_ n: Int) throws -> String { try arg(n).requireString("argument", nonempty: true) }
        if fn == "setLabelColor" || fn == "deleteLabelEverywhere" {
            try loadLabels(); guard let name = BackendCrmTaskPage.normalizeLabels([BackendCrmWire.crm(arg(0))]).first else { throw NativeRPCError.invalidArguments("Invalid tag") }
            if fn == "setLabelColor" { guard let color = arg(1).string, BackendCrmMore.labelColors.contains(color) else { throw NativeRPCError.invalidArguments("Invalid colour") }; labelColors[name.lowercased()] = color; try saveLabels(); return ok() }
            var ids: [String] = []
            for task in try await store.all().filter(\.isLocal) {
                let labels = task.value["labels"].elements?.compactMap(\.string) ?? []; guard labels.contains(where: { $0.lowercased() == name.lowercased() }) else { continue }
                do { _ = try await local.update(task.id, input: BackendTaskValues.object([("labels", .array(labels.filter { $0.lowercased() != name.lowercased() }.map(NativeRPCValue.string)))]), by: by); ids.append(task.id) }
                catch { return BackendTaskValues.object([("ok", .bool(false)), ("error", .string("The tag was removed from \(ids.count) of your tasks, then stopped — try again.")), ("taskIds", .array(ids.map(NativeRPCValue.string)))]) }
            }
            labelColors[name.lowercased()] = nil; try saveLabels(); return ok([("removed", .number(Double(ids.count))), ("keptElsewhere", .number(0)), ("taskIds", .array(ids.map(NativeRPCValue.string)))])
        }
        if fn == "searchTags" {
            let area = try string(0), query = (arg(1).string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); guard query.utf16.count >= 2 else { return ok([("hits", .array([]))]) }
            var hits: [NativeRPCValue] = []
            if area == "person" {
                let agents = try await local.configuration.allAgents().filter { $0["status"].string != "archived" }, pairs = agents.compactMap { row in row["id"].string.map { (id: $0, name: row["name"].string ?? $0) } }
                for person in BackendCrmPeople.localPeople(pairs) where person.name.lowercased().contains(query) { hits.append(BackendTaskValues.object([("area", .string(area)), ("id", .string(person.id)), ("label", .string(person.name)), ("secondary", .string(person.id == "me" ? "You" : person.id == "hoot" ? "Hoot" : "Task agent")), ("href", .string("/people/" + encodeComponent(person.id)))])) }
            } else if area == "task" {
                for task in try await store.all().filter({ $0.isLocal && ($0.value["title"].string ?? "").lowercased().contains(query) }).sorted(by: { ($0.value["updatedAt"].number ?? 0) > ($1.value["updatedAt"].number ?? 0) }).prefix(20) { hits.append(BackendTaskValues.object([("area", .string(area)), ("id", .string(task.id)), ("label", task.value["title"]), ("secondary", task.value["board"].isNullish ? .null : task.value["board"]), ("status", task.value["crmStatus"]), ("href", .string("/tasks?task=" + encodeComponent(task.id)))])) }
            } else if area == "file" { for task in try await store.all().filter(\.isLocal) { for row in detail(task)["attachments"].elements ?? [] where row["kind"].string == "upload" && (row["fileName"].string ?? "").lowercased().contains(query) { guard let id = row["id"].string else { continue }; hits.append(BackendTaskValues.object([("area", .string(area)), ("id", .string(task.id + "/" + id)), ("label", row["fileName"]), ("secondary", task.value["title"]), ("href", .string("/files/" + encodeComponent(task.id) + "/" + encodeComponent(id)))])) } } }
            return ok([("hits", .array(area == "person" ? hits : Array(hits.prefix(20))))])
        }
        if fn == "detachTaskAttachment" {
            let id = try string(0); guard let task = try await store.all().first(where: { $0.isLocal && (detail($0)["attachments"].elements ?? []).contains { $0["id"].string == id } }), let row = (detail(task)["attachments"].elements ?? []).first(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("Attachment not found") }
            try await save(task, d: detail(task).setting("attachments", .array((detail(task)["attachments"].elements ?? []).filter { $0["id"].string != id })), by: by, kind: "attachment", payload: BackendTaskValues.object([("attachment_id", .string(id)), ("file_name", row["fileName"]), ("removed", .bool(true))]))
            if let file = row["file"].string, let files { let used = try await store.all(includeTrash: true).contains { ($0.value["detail"]["attachments"].elements ?? []).contains { $0["file"].string == file } }; if !used { try files.remove(file) } }; return ok()
        }
        let task = try await local.task(string(0))
        switch fn {
        case "uploadTaskFile":
            guard let files else { throw BackendSessionFailure.missingCapability("private task attachment storage") }
            let upload = arg(1); guard let name = upload["name"].string, case .bytes(let bytes) = upload["bytes"] else { throw NativeRPCError.invalidArguments("That file could not be read.") }
            let row = try files.upload(task, name: name, mime: upload["type"].string, bytes: bytes, actor: by)
            try await save(task, d: detail(task).setting("attachments", .array((detail(task)["attachments"].elements ?? []) + [row])), by: by, kind: "attachment", payload: BackendTaskValues.object([("attachment_id", row["id"]), ("file_name", row["fileName"]), ("removed", .bool(false))]))
            return ok([("attachment", try files.view(row))])
        case "chooseTaskFiles":
            guard let files, let desktop else { throw BackendSessionFailure.missingCapability("the native file chooser and private task storage") }
            let paths = try await desktop.chooseFiles(); var rows: [NativeRPCValue] = [], errors: [NativeRPCValue] = []
            for source in paths { do { let row = try await files.copy(task, source: source, actor: by), current = try await local.task(task.id); try await save(current, d: detail(current).setting("attachments", .array((detail(current)["attachments"].elements ?? []) + [row])), by: by, kind: "attachment", payload: BackendTaskValues.object([("attachment_id", row["id"]), ("file_name", row["fileName"]), ("removed", .bool(false))])); rows.append(try files.view(row)) } catch { errors.append(.string(error.localizedDescription)) } }
            return ok([("attachments", .array(rows)), ("errors", .array(errors))])
        case "openTaskFile":
            guard let files, let desktop else { throw BackendSessionFailure.missingCapability("the native task file opener") }
            guard let row = (detail(task)["attachments"].elements ?? []).first(where: { $0["id"].string == arg(1).string }), let file = row["file"].string else { throw NativeRPCError.invalidArguments("Attachment not found") }
            let path = try files.path(file), error = try await desktop.openPath(path); guard error.isEmpty else { throw NativeRPCError.invalidArguments("“\(row["fileName"].string ?? "file")” could not be opened: \(error)") }; return ok()
        case "attachExistingDocument":
            let document = try string(1); guard let cut = document.lastIndex(of: "/"), let source = try await store.byID(String(document[..<cut])), source.isLocal,
                  let row = (detail(source)["attachments"].elements ?? []).first(where: { $0["id"].string == String(document[document.index(after: cut)...]) }), row["file"].string != nil else { throw NativeRPCError.invalidArguments("That file is no longer attached to any of your tasks.") }
            if source.id == task.id || (detail(task)["attachments"].elements ?? []).contains(where: { $0["documentId"].string == document }) { return ok() }
            let id = UUID().uuidString.lowercased(), pointer = row.setting("id", .string(id)).setting("kind", .string("document")).setting("documentId", .string(document)).setting("uploadedBy", .string(by)).setting("at", .number(BackendTaskValues.time()))
            try await save(task, d: detail(task).setting("attachments", .array((detail(task)["attachments"].elements ?? []) + [pointer])), by: by, kind: "attachment", payload: BackendTaskValues.object([("attachment_id", .string(id)), ("file_name", pointer["fileName"]), ("removed", .bool(false))])); return ok([("id", .string(id))])
        case "chooseTaskProject":
            guard let desktop else { throw BackendSessionFailure.missingCapability("the native project folder chooser") }
            guard let folder = try await desktop.chooseFolder() else { return ok([("project", .string(task.project)), ("chosen", .bool(false))]) }
            let changed = try await local.update(task.id, input: BackendTaskValues.object([("project", .string(folder))]), by: by); return ok([("project", .string(changed.project)), ("chosen", .bool(true))])
        case "toggleCommentReaction":
            let id = try string(1), emoji = arg(2).string
            guard BackendCrmComments.isReactionEmoji(emoji) else { throw NativeRPCError.invalidArguments("That reaction is not offered") }
            guard try await comments(task).contains(where: { $0["id"].string == id }) else { throw NativeRPCError.invalidArguments("That comment is no longer on this task") }
            var d = detail(task), reactions = d["reactions"][id].elements ?? [], on = true
            if let i = reactions.firstIndex(where: { $0["emoji"].string == emoji }) { var users = reactions[i]["userIds"].elements ?? []; if users.contains(.string("me")) { users.removeAll { $0 == .string("me") }; on = false } else { users.append(.string("me")) }; reactions[i] = reactions[i].setting("userIds", .array(users)) }
            else { reactions.append(BackendTaskValues.object([("emoji", .string(emoji!)), ("userIds", .array([.string("me")]))])) }
            reactions.removeAll { ($0["userIds"].elements ?? []).isEmpty }; d = d.setting("reactions", d["reactions"].setting(id, .array(reactions))); try await persist(task, d: d); return ok([("on", .bool(on))])
        case "duplicateTask":
            let keep = ["human", "none"].contains(task.assigneeKind), title = BackendCrmInlineFiles.truncateVisible(BackendCrmInlineFiles.stripFileTokens(task.value["title"].string ?? "") + " (copy)")
            var input = taskCopyInput(task).setting("title", .string(title)).setting("assignee", keep ? task.value["assignee"]["identity"] : .string("me"))
            input = input.setting("status", task.value["crmStatus"]); let copy = try await local.create(input, by: by); let from = detail(task)
            var into = detail(copy), extras = from["people"].elements ?? []; if !keep { extras.append(task.value["assignee"]["identity"]) }; var seen = Set<String>()
            into = into.setting("people", .array(extras.filter { $0.string != copy.value["assignee"]["identity"].string && seen.insert($0.string ?? "").inserted })).setting("subtasks", .array((from["subtasks"].elements ?? []).map { $0.setting("id", .string(UUID().uuidString.lowercased())) })).setting("checklists", .array((from["checklists"].elements ?? []).map { row in row.setting("id", .string(UUID().uuidString.lowercased())).setting("items", .array((row["items"].elements ?? []).map { $0.setting("id", .string(UUID().uuidString.lowercased())) })) }))
            try await persist(copy, d: into); return ok([("id", .string(copy.id))])
        case "convertToSubtask":
            let target = try await local.task(string(1)); guard task.id != target.id else { throw NativeRPCError.invalidArguments("Pick another task") }; guard !isRepeating(task) else { throw NativeRPCError.invalidArguments("A repeating task cannot become a subtask — stop it repeating first.") }; guard task.sessionID == nil else { throw NativeRPCError.invalidArguments("An agent is working on this task — take it back before converting it.") }
            let title = BackendCrmInlineFiles.truncateVisible(BackendCrmInlineFiles.stripFileTokens(task.value["title"].string ?? "").components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled"), d = detail(target), rows = d["subtasks"].elements ?? [], row = BackendTaskValues.object([("id", .string(UUID().uuidString.lowercased())), ("title", .string(title.isEmpty ? "Untitled" : title)), ("done", .bool(task.value["crmStatus"].string == "Done")), ("sortOrder", .number((rows.compactMap { $0["sortOrder"].number }.max() ?? -1) + 1)), ("assigneeUserId", task.assigneeKind == "none" ? .null : task.value["assignee"]["identity"]), ("priority", .null), ("dueDate", .null)])
            try await save(target, d: d.setting("subtasks", .array(rows + [row])), by: by, kind: "subtask_added", payload: BackendTaskValues.object([("title", .string(title))])); try await local.remove(task.id, by: by); return ok()
        case "mergeTaskInto": return try await mergeTask(task, targetID: string(1), by: by)
        default: throw NativeRPCError.invalidArguments("Unknown task detail operation")
        }
    }
    func taskCopyInput(_ task: BackendTaskRecord) -> NativeRPCValue { var result = BackendTaskValues.object([("title", task.value["title"]), ("instructions", task.value["instructions"]), ("project", .string(task.project))]); for key in ["priority", "startDate", "dueDate", "startTime", "dueTime", "labels", "board", "taskType", "estimateMinutes"] { result = result.setting(key, task.value[key].isNullish ? (key == "labels" ? .array([]) : key == "taskType" ? .string("task") : .null) : task.value[key]) }; return result }
    func isRepeating(_ task: BackendTaskRecord) -> Bool { let raw = detail(task)["routine"]; return task.value["recurrence"].string != nil || (!raw.isNullish && raw["stoppedAt"].isNullish) }
    func mergeTask(_ source: BackendTaskRecord, targetID: String, by: String) async throws -> NativeRPCValue {
        let target = try await local.task(targetID); guard source.id != target.id else { throw NativeRPCError.invalidArguments("Pick another task") }
        guard !isRepeating(source), !isRepeating(target) else { throw NativeRPCError.invalidArguments("A repeating task cannot be merged — stop it repeating first.") }; guard source.sessionID == nil else { throw NativeRPCError.invalidArguments("An agent is working on this task — take it back before merging it.") }
        var from = detail(source), into = detail(target), added: [NativeRPCValue] = [], people = into["people"].elements ?? []
        for who in (source.assigneeKind == "none" ? [] : [source.value["assignee"]["identity"]]) + (from["people"].elements ?? []) where who != target.value["assignee"]["identity"] && !people.contains(who) { people.append(who); added.append(who) }; into = into.setting("people", .array(people))
        for key in ["subtasks", "checklists"] { let base = into[key].elements ?? [], start = (base.compactMap { $0["sortOrder"].number }.max() ?? -1) + 1, rows = (from[key].elements ?? []).enumerated().map { $0.element.setting("sortOrder", .number(start + Double($0.offset))) }; into = into.setting(key, .array(base + rows)) }
        for key in ["attachments", "comments", "time"] { into = into.setting(key, .array((into[key].elements ?? []) + (from[key].elements ?? []))) }
        for key in ["commentMeta", "reactions"] { into = into.setting(key, into[key].merging(from[key])) }
        var followers = into["followers"]; for field in from["followers"].fields ?? [] where !followers.has(field.key) { followers = followers.setting(field.key, field.value) }; into = into.setting("followers", followers)
        var fields = decodeFields(target), kept: [String] = []
        for var field in decodeFields(source) {
            if fields.contains(where: { BackendCrmFields.sameLabel($0.label, field.label) }) { if let value = BackendCrmFields.feedValue(BackendCrmFields.formatFieldValue(field)) { kept.append(field.label + ": " + value) }; continue }
            field.taskId = target.id; field.sortOrder = (fields.compactMap(\.sortOrder).max() ?? -1) + 1; fields.append(field)
        }; into = into.setting("fields", .array(fields.map(BackendCrmWire.field)))
        var dependencies = into["dependencies"].elements ?? []; for row in from["dependencies"].elements ?? [] where row["otherTaskId"].string != target.id { if !dependencies.contains(where: { $0["kind"] == row["kind"] && $0["otherTaskId"] == row["otherTaskId"] }) { dependencies.append(row) } }; into = into.setting("dependencies", .array(dependencies.filter { $0["otherTaskId"].string != target.id }))
        for task in try await store.all().filter(\.isLocal) where task.id != source.id && task.id != target.id {
            var d = detail(task), rows = d["dependencies"].elements ?? []; guard rows.contains(where: { $0["otherTaskId"].string == source.id }) else { continue }; rows = rows.map { $0["otherTaskId"].string == source.id ? $0.setting("otherTaskId", .string(target.id)) : $0 }; var seen = Set<String>(); rows = rows.filter { $0["otherTaskId"].string != task.id && seen.insert(($0["kind"].string ?? "") + ":" + ($0["otherTaskId"].string ?? "")).inserted }; d = d.setting("dependencies", .array(rows)); try await persist(task, d: d)
        }
        from = from.setting("attachments", .array([])).setting("dependencies", .array([])); var payload = BackendTaskValues.object([("title", source.value["title"]), ("people_added", .array(added)), ("fields_kept", .array(kept.prefix(20).map(NativeRPCValue.string)))]); if kept.count > 20 { payload = payload.setting("fields_kept_more", .number(Double(kept.count - 20))) }
        try await save(target, d: into, by: by, kind: "merged", payload: payload); try await persist(source, d: from); try await local.remove(source.id, by: by); return ok()
    }
    func loadLabels() throws { guard !labelsLoaded else { return }; if let raw = try settingsPersistence?.read("task-detail.json"), raw["v"].number == 1 { for field in raw["labelColors"].fields ?? [] { if let color = field.value.string, BackendCrmMore.labelColors.contains(color) { labelColors[field.key] = color } } }; labelsLoaded = true }
    func saveLabels() throws { try settingsPersistence?.write("task-detail.json", value: BackendTaskValues.object([("v", .number(1)), ("labelColors", .object(labelColors.map { .init($0.key, .string($0.value)) }))])) }
    func attachmentView(_ row: NativeRPCValue) throws -> NativeRPCValue {
        if let files { return try files.view(row) }
        return BackendTaskValues.object([("id", row["id"]), ("kind", row["kind"]), ("fileName", row["fileName"]), ("mimeType", row["mimeType"]), ("sizeBytes", row["sizeBytes"]), ("documentId", row["kind"].string == "document" ? row["documentId"] : .null), ("storagePath", row["kind"].string == "upload" ? row["file"] : .null), ("uploadedBy", row["uploadedBy"]), ("createdAt", .string(BackendTaskOutbox.iso(row["at"].number ?? 0))), ("previewUrl", .null)])
    }
    func encodeComponent(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? value }
}
