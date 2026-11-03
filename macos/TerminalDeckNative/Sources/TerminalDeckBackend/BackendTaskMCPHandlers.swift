import Foundation
import TerminalDeckNativeCore

/// One entry point per task tool; shared checks live on the request.
enum BackendTaskMCPHandlers {
    typealias Operation = @Sendable (BackendTaskMCPRequest) async throws -> NativeRPCValue
    static let operations: [String: Operation] = [
        "crm.task": { try await $0.crmTask() },
        "tasks.agents": { try await $0.agents() },
        "tasks.agents_import": { try await $0.agentsImport() },
        "tasks.local": { try await $0.local() },
        "tasks.local_change": { try await $0.localChange() },
        "tasks.local_parts": { try await $0.localParts() },
        "tasks.local_schedule": { try await $0.localSchedule() },
        "tasks.plan": { try await $0.plan() },
        "tasks.delegate": { try await $0.delegate() },
        "tasks.progress": { try await $0.progress() },
        "tasks.goals": { try await $0.goals() },
        "hoot.island": { try await $0.island() },
        "tasks.retry": { try await $0.retry() },
        "tasks.reassign": { try await $0.reassign() },
        "tasks.review": { try await $0.review() },
        "tasks.claims": { try await $0.claims() },
        "tasks.list": { try await $0.list() },
        "tasks.get": { try await $0.get() },
        "tasks.comment": { try await $0.comment() },
        "tasks.verify": { try await $0.verify() },
        "tasks.set_status": { try await $0.setStatus() },
        "tasks.crm_sync": { try await $0.crmSync() }
    ]
}

extension BackendTaskMCPRequest {
    func crmTask() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let key = try await authority.crmKeyID!(caller), answer = try await api!.call(try args["op"].requireString("op"), keyID: key, input: args.removing("op"))
        guard answer.ok else { throw NativeRPCError(code: answer.code ?? "not-permitted", message: answer.message ?? "CRM task refused") }; value = answer.value
        return value
    }

    func agents() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        // The agents that exist before this save: whatever is new after it was hired by it (its seat is made below).
        var existingIDs = Set<String>()
        if ["save", "save-many"].contains(verb) { existingIDs = Set(try await view.config.allAgents().compactMap { $0["id"].string }) }
        let known = existingIDs
        func hired(_ rows: [NativeRPCValue]) async { await BackendAGTHire.seated(rows.filter { !known.contains($0["id"].string ?? "") }) }
        if verb == "list" { value = BackendTaskMCP.value([("agents", .array(try await view.config.allAgents()))]) }
        else if ["save", "save-many"].contains(verb), let profileKey {
            let plan = try await view.config.prepareAgentChanges(request: args, callerKeyID: profileKey, inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default", ownerReviewOrdinaryFields: reviewOrdinaryProfileFields)
            if plan["needsApproval"].bool == true {
                guard let approve = authority.authorizeProfileWidening else { throw NativeRPCError(code: "unavailable", message: "The exact owner approval for widening agent settings is not installed.") }
                try await approve(caller, args, plan["summary"].string ?? "change the reviewed agents")
                guard !caller.cancellation.isCancelled else { throw CancellationError() }
                try await authority.requireTasks(caller)
                guard try await authority.callerKeyID?(caller) == profileKey else { throw NativeRPCError(code: "not-granted", message: "The profile key changed while approval was open.") }
                for profileID in (plan["ids"].elements ?? []).compactMap(\.string) {
                    if let row = try await view.config.agent(profileID), let project = row["defaultProject"].string, !project.isEmpty { try await authority.project(caller, project) }
                }
                for input in (args["agents"].elements ?? [args["agent"]]) {
                    if let project = input["defaultProject"].string, !project.isEmpty { try await authority.project(caller, project) }
                }
                let rows = try await view.config.applyApprovedAgentChanges(planID: plan["planId"].requireString("reviewed change"), callerKeyID: profileKey)
                await hired(rows)
                value = BackendTaskMCP.value([("saved", verb == "save" ? rows.first ?? .null : .array(rows))])
            } else {
                var rows: [NativeRPCValue] = []; for profileID in (plan["ids"].elements ?? []).compactMap(\.string) { if let row = try await view.config.agent(profileID) { rows.append(row) } }
                await hired(rows)
                value = BackendTaskMCP.value([("saved", verb == "save" ? rows.first ?? .null : .array(rows))])
            }
        }
        else if verb == "save-many" {
            // No key (Hoot, a task or lead session): every agent in the request, new and existing, in one
            // all-or-nothing save under the one consent already given for this call.
            let rows = try await view.config.saveAgentsAsCaller(request: agentArgs, inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default", ownerMode: try await authority.widensAgents?(caller) ?? false)
            await hired(rows)
            value = BackendTaskMCP.value([("saved", .array(rows))])
        }
        else if verb == "save" {
            var input = try agentArgs["agent"].requireObject("agent"), existing: NativeRPCValue?
            if let id = input["id"].string { existing = try await view.config.agent(id) }
            if input["id"].string == nil { input = input.setting("id", .string(BackendTaskConfiguration.newID(name: input["name"].string, taken: Set(try await view.config.allAgents().compactMap { $0["id"].string })))) }
            let projected = (existing ?? .object([])).merging(input)
            if let project = projected["defaultProject"].string, !project.isEmpty { try await authority.project(caller, project) }
            // A new id is a hire (saved as the New Agent screen saves it); an existing agent narrows only,
            // except for Hoot and a project's lead, who may also widen it (as the owner can).
            let saved: NativeRPCValue
            if existing != nil, try await authority.widensAgents?(caller) ?? false {
                saved = try await view.config.saveAgentsAsCaller(request: .object([.init("do", .string("save")), .init("agent", input)]), inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default", ownerMode: true).first ?? .null
            } else {
                saved = try await view.config.saveAgentNarrowed(input, inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default", callerKeyID: try await authority.callerKeyID?(caller))
            }
            await hired([saved])
            value = BackendTaskMCP.value([("saved", saved)])
        } else if verb == "remove" { let agent = try args["id"].requireString("id", nonempty: true); try await view.config.removeAgent(agent); value = BackendTaskMCP.value([("removed", .string(agent))]) }
        else { let agent = try args["id"].requireString("id", nonempty: true), row = try await view.config.setStatus(agent, action: verb); value = BackendTaskMCP.value([("agent", .string(agent)), ("status", row["status"])]) }
        return value
    }

    func agentsImport() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        if args.has("batches") {
            value = try await BackendPROJAgentBatches.importBatches(configuration: view.config, request: args, projects: PROJProjects.defaults,
                narrowOnly: true, inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default",
                callerKeyID: try await authority.callerKeyID?(caller), authorizeProject: { try await authority.project(caller, $0) })
        } else {
            let folder = try args["folder"].requireString("folder", nonempty: true)
            try await authority.project(caller, folder)
            try await authority.project(caller, BackendTAGAgentImport.directory(folder).path)
            value = try await view.config.importAgents(folder: folder, narrowOnly: true, inheritedPermissionMode: await authority.inheritedPermissionMode?() ?? "default", callerKeyID: try await authority.callerKeyID?(caller), options: args["options"], authorizeProject: { try await authority.project(caller, $0) })
        }
        return value
    }

    func local() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        if verb == "list" || verb == "trash" {
            let rows = try await (verb == "trash" ? view.store.inTrash() : view.store.all()), agents = try await view.config.allAgents(), limit = min(max(Int(args["limit"].number ?? 200), 1), 200)
            var visible: [BackendTaskRecord] = []; let scope = try await listingScope()
            for row in rows where row.isLocal && BackendTaskProjectScope.includes(row, project: scope) { if try await authority.visible(caller, row), (verb == "trash" || ((!row.value["archivedAt"].isNullish) == (args["archived"].bool == true))), args["status"].string == nil || row.value["crmStatus"].string == args["status"].string, args["assignee"].string == nil || row.agentID == args["assignee"].string { visible.append(row) } }
            visible.sort { ($0.value["updatedAt"].number ?? 0) > ($1.value["updatedAt"].number ?? 0) }
            value = BackendTaskMCP.value([(verb == "trash" ? "trash" : "tasks", .array(visible.prefix(limit).map { BackendTaskMCP.taskView($0, agents: agents) })), ("more", .number(Double(max(0, visible.count - limit)))), ("statuses", .array(BackendTaskLocalService.statuses.map(NativeRPCValue.string))), ("agents", .array(agents.filter { $0["status"].string != "archived" })), ("showing", .string(scope.map { "project " + $0 } ?? "all projects"))])
        } else {
            let row = try await task(args["task"], localOnly: true), names = ["comments": "listTaskComments", "activity": "listTaskActivity", "get": "fetchTaskDetailBundle", "routine": "fetchRoutine"]
            guard let name = names[verb] else { throw NativeRPCError.invalidArguments("Unknown tasks_local verb") }
            let reply = await detail.call(name, arguments: [.string(row.id)], by: by); try BackendTaskMCP.checkDetail(reply)
            if verb == "get" {
                let fields = await detail.call("listTaskFields", arguments: [.string(row.id)], by: by), extras = await detail.call("fetchTaskPageExtras", arguments: [.string(row.id)], by: by), more = await detail.call("fetchTaskMore", arguments: [.string(row.id)], by: by)
                try BackendTaskMCP.checkDetail(fields); try BackendTaskMCP.checkDetail(extras); try BackendTaskMCP.checkDetail(more)
                value = BackendTaskMCP.taskView(row, agents: try await view.config.allAgents()).setting("details", row.value["instructions"]).merging(reply["bundle"]).setting("fields", fields["fields"]).setting("timeEntries", extras["extras"]["timeEntries"]).setting("reminders", more["more"]["reminders"])
            }
            else { value = verb == "activity" ? BackendTaskMCP.value([("activity", reply["rows"])]) : reply.removing("ok") }
        }
        return value
    }

    func localChange() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        var patch = BackendTaskMCP.rowPatch(args)
        if verb == "create", (patch["project"].string ?? "").isEmpty {
            let assignment = try await local.assignee(patch["assignee"])
            let defaultProject = try await local.projectFolder(.null, assignment: assignment)
            if !defaultProject.isEmpty { patch = patch.setting("project", .string(defaultProject)) }
        }
        if verb == "create" { patch = BackendTaskProjectScope.createPatch(patch, callerProject: try await home()) }
        if verb == "create" {
            if !patch.has("assignee") { patch = patch.setting("assignee", .string("me")) }
            let provisionalProject = patch["project"].string ?? "", key = try await authority.callerKeyID?(caller)
            if !provisionalProject.isEmpty { try await authority.project(caller, provisionalProject) }
            let provisionalID = UUID().uuidString.lowercased()
            let provisional = try BackendTaskRecord(BackendTaskMCP.value([("id", .string("local:" + provisionalID)), ("keyId", .string("local")), ("externalTaskId", .string(provisionalID)), ("project", .string(provisionalProject)), ("local", .bool(true)), ("notificationKeyId", key.map(NativeRPCValue.string) ?? .null)]))
            guard try await authority.visible(caller, provisional) else { throw NativeRPCError(code: "not-permitted", message: "This app is limited to some folders: give the task a project folder inside one of them.") }
            let made = try await local.create(patch, by: by, notificationKeyID: key)
            value = BackendTaskMCP.value([("created", BackendTaskMCP.taskView(made, agents: try await view.config.allAgents()))])
        }
        else {
            let row = try await task(args["task"], localOnly: true, trash: verb == "restore" || verb == "purge")
            if verb == "delete" { try await local.remove(row.id, by: by); value = BackendTaskMCP.value([("trashed", .string(row.id)), ("restore", .string("tasks_local_change do: restore"))]) }
            else if verb == "purge" { try await view.store.purgeTrash(row.id); value = BackendTaskMCP.value([("purged", .string(row.id))]) }
            else if verb == "restore" { value = BackendTaskMCP.value([("restored", BackendTaskMCP.taskView(try await local.restore(row.id, by: by), agents: try await view.config.allAgents()))]) }
            else if verb == "comment" { let reply = await detail.call("addTaskCommentWith", arguments: [.string(row.id), args["text"], BackendTaskMCP.value([("parentId", args["reply_to"])])], by: by); try BackendTaskMCP.checkDetail(reply); value = BackendTaskMCP.value([("comment", reply["id"]), ("warning", reply["warning"])]) }
            else { if verb == "reply" { _ = try await local.reply(row.id, text: args["text"].requireString("text", nonempty: true)) }
                else { if verb == "archive" || verb == "unarchive" { patch = BackendTaskMCP.value([("archived", .bool(verb == "archive"))]) }; guard !patch.spreadFields.isEmpty else { throw NativeRPCError.invalidArguments("update needs at least one field to change") }; _ = try await local.update(row.id, input: patch, by: by, notificationKeyID: try await authority.callerKeyID?(caller)) }
                value = BackendTaskMCP.value([("task", BackendTaskMCP.taskView(try await task(.string(row.id), localOnly: true), agents: try await view.config.allAgents()))]) }
        }
        return value
    }

    func localParts() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let row = try await task(args["task"], localOnly: true), mapping: [String: (String, [NativeRPCValue])]
        func own(_ key: String, list: String, item: Bool = false, kind: String? = nil) throws -> NativeRPCValue {
            let word = kind ?? key
            guard let id = args[key].string, !id.isEmpty else { throw NativeRPCError.invalidArguments("\(word) is required") }
            let rows = row.value["detail"][list].elements ?? [], found = item ? rows.contains { ($0["items"].elements ?? []).contains { $0["id"].string == id } } : rows.contains { $0["id"].string == id }
            guard found else { throw NativeRPCError.invalidArguments("task \(row.id) has no \(word) \(id)") }; return .string(id)
        }
        if id == "tasks.local_schedule" {
            mapping = ["reminder_set": ("setReminder", [.string(row.id), args["at"], args["note"]]), "reminder_clear": ("clearReminder", [.string(row.id), args["reminder"]]), "comment_schedule": ("addTaskCommentWith", [.string(row.id), args["text"], BackendTaskMCP.value([("scheduledFor", args["at"])])]), "comment_send_now": ("sendScheduledNow", [.string(row.id), args["comment"]]), "repeat_set": ("saveRoutine", [.string(row.id), args["rule"], .null]), "repeat_pause": ("pauseRoutine", [.string(row.id), .bool(true)]), "repeat_resume": ("pauseRoutine", [.string(row.id), .bool(false)]), "repeat_stop": ("stopRoutine", [.string(row.id)]), "repeat_restart": ("restartRoutine", [.string(row.id)])]
        } else {
            var m: [String: (String, [NativeRPCValue])] = ["subtask_add": ("addTaskSubtask", [.string(row.id), args["text"]]), "checklist_add": ("addChecklist", [.string(row.id), args["text"]]), "time_start": ("startTaskTimer", [.string(row.id)]), "time_stop": ("stopTaskTimer", [.string(row.id)])]
            if verb == "subtask_done" || verb == "subtask_remove" { m[verb] = (verb == "subtask_done" ? "setTaskSubtaskDone" : "deleteTaskSubtask", [.string(row.id), try own("item", list: "subtasks", kind: "subtask"), args["done"]]) }
            if verb == "checklist_remove" || verb == "checklist_item_add" { m[verb] = (verb == "checklist_remove" ? "deleteChecklist" : "addChecklistItem", [try own("checklist", list: "checklists"), args["text"]]) }
            if verb == "checklist_item_done" || verb == "checklist_item_remove" { m[verb] = (verb == "checklist_item_done" ? "setChecklistItemDone" : "deleteChecklistItem", [try own("item", list: "checklists", item: true), args["done"]]) }
            if verb == "dependency_add" || verb == "dependency_remove" { let other = try await task(args["other"], localOnly: true); m[verb] = (verb == "dependency_add" ? "addTaskDependency" : "removeTaskDependency", [.string(row.id), .string(other.id), args["kind"]]) }
            if verb == "time_add" { let text = try args["duration"].requireString("duration"); guard let seconds = BackendCrmTaskRules.parseDuration(text), seconds > 0 else { throw NativeRPCError.invalidArguments("duration must be like \"1h 20m\" or \"45m\"") }; m[verb] = ("addTaskTimeEntry", [.string(row.id), BackendTaskMCP.value([("seconds", .number(Double(seconds))), ("date", args["date"]), ("note", args["note"]), ("billable", .bool(false))])]) }
            if verb == "field_create" { m[verb] = ("createTaskField", [.string(row.id), BackendTaskMCP.value([("label", args["label"]), ("kind", args["kind"]), ("config", args["config"]), ("value", args["value"])])]) }
            if verb == "field_set" || verb == "field_remove" { m[verb] = (verb == "field_set" ? "updateTaskFieldValue" : "deleteTaskField", [try own("field", list: "fields"), args["value"].isNullish ? .null : args["value"]]) }
            if verb == "attachment_remove" { m[verb] = ("detachTaskAttachment", [try own("attachment", list: "attachments")]) }
            if verb == "attach_file" { guard let readAttachment else { throw BackendSessionFailure.missingCapability("this caller's actual scoped task attachment file reader") }; let file = try await readAttachment(caller, args["path"].requireString("path", nonempty: true)); m[verb] = ("uploadTaskFile", [.string(row.id), BackendTaskMCP.value([("name", .string(file.name)), ("type", file.mime.map(NativeRPCValue.string) ?? .string("")), ("bytes", .bytes(file.bytes))])]) }
            // The task popup's own calls (L5, Hoot tool audit): the same detail functions its buttons call.
            if verb == "person_add" || verb == "person_remove" { m[verb] = (verb == "person_add" ? "addTaskAssignee" : "removeTaskAssignee", [.string(row.id), .string(try args["person"].requireString("person", nonempty: true))]) }
            if verb == "subtask_assignee" { m[verb] = ("setTaskSubtaskAssignee", [.string(row.id), try own("item", list: "subtasks", kind: "subtask"), args["person"].isNullish ? .null : args["person"]]) }
            if verb == "checklist_item_assignee" { m[verb] = ("setChecklistItemAssignee", [try own("item", list: "checklists", item: true), args["person"].isNullish ? .null : args["person"]]) }
            if verb == "checklist_rename" { m[verb] = ("renameChecklist", [try own("checklist", list: "checklists"), .string(try args["text"].requireString("text", nonempty: true))]) }
            if verb == "comment_resolve" { m[verb] = ("setCommentResolved", [.string(row.id), .string(try args["comment"].requireString("comment", nonempty: true)), .bool(args["done"].bool ?? true)]) }
            if verb == "comment_react" { m[verb] = ("toggleCommentReaction", [.string(row.id), .string(try args["comment"].requireString("comment", nonempty: true)), .string(try args["emoji"].requireString("emoji", nonempty: true))]) }
            if verb == "task_duplicate" { m[verb] = ("duplicateTask", [.string(row.id)]) }
            if verb == "task_merge" || verb == "task_to_subtask" { let other = try await task(args["other"], localOnly: true); m[verb] = (verb == "task_merge" ? "mergeTaskInto" : "convertToSubtask", [.string(row.id), .string(other.id)]) }
            if verb == "label_color" { m[verb] = ("setLabelColor", [.string(try args["label"].requireString("label", nonempty: true)), .string(try args["value"].requireString("value", nonempty: true))]) }
            if verb == "label_delete" { m[verb] = ("deleteLabelEverywhere", [.string(try args["label"].requireString("label", nonempty: true))]) }
            if verb == "subtask_meta" { m[verb] = ("setSubtaskMeta", [.string(row.id), try own("item", list: "subtasks", kind: "subtask"), args["value"]]) }
            if verb == "field_rename" { m[verb] = ("renameTaskField", [try own("field", list: "fields"), .string(try args["text"].requireString("text", nonempty: true))]) }
            if verb == "field_settings" { m[verb] = ("updateTaskFieldConfig", [try own("field", list: "fields"), args["config"]]) }
            if verb == "field_order" { m[verb] = ("reorderTaskFields", [.string(row.id), args["value"]]) }
            if verb == "sync_dates" { m[verb] = ("setSyncSubtaskDates", [.string(row.id), .bool(args["done"].bool ?? true)]) }
            if verb == "description_history" { m[verb] = ("fetchDescriptionHistory", [.string(row.id)]) }
            if verb == "time_remove" { m[verb] = ("deleteTaskTimeEntry", [.string(row.id), try own("entry", list: "time")]) }; mapping = m
        }
        guard let call = mapping[verb] else { throw NativeRPCError.invalidArguments("Unknown task part/schedule verb") }; let reply = await detail.call(call.0, arguments: call.1, by: by); try BackendTaskMCP.checkDetail(reply); value = reply.removing("ok")
        return value
    }

    func plan() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        var result = try await planning.create(args, authorizeProject: { try await authority.project(caller, $0) })
        if let knowledge, let goalID = args["goal"].string, let goal = try await view.goals.byID(goalID), let known = await knowledge.goal(goal) { result = result.setting("knowledge", known) }; value = result
        return value
    }

    func delegate() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let row = try await task(args["task"]), project = args["project"].string ?? row.project
        if !project.isEmpty { try await authority.project(caller, project) }
        value = try await delegation!.delegate(taskID: row.id, agent: args["agent"].requireString("agent", nonempty: true), title: args["title"].requireString("title", nonempty: true), instructions: args["instructions"].requireString("instructions", nonempty: true), project: project, by: by, notificationKeyID: try await authority.callerKeyID?(caller))
        return value
    }

    func progress() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let tasks = try await view.store.all()
        if args.has("goal") {
            let goal = try await goalRow(args["goal"]); var report = try await view.goals.progress(goal["id"].string ?? "", tasks: tasks), named: [NativeRPCValue] = []
            for line in report["tasks"].elements ?? [] {
                let who = line["assignee"].string ?? "none"; let name: String
                if who == "hoot" { name = "Hoot" } else if who == "me" { name = "You" } else if who == "none" { name = "Nobody" } else { name = try await view.config.agent(who)?["name"].string ?? who }
                named.append(line.setting("assigneeName", .string(name)))
            }
            report = report.setting("tasks", .array(named)); value = report
        }
        else { var rows: [NativeRPCValue] = []; for goal in try await view.goals.all() { rows.append(try await goalView(goal)) }; value = BackendTaskMCP.value([("goals", .array(rows))]) }
        return value
    }

    func goals() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        if verb == "list" { var rows: [NativeRPCValue] = []; let scope = try await listingScope(); for goal in try await view.goals.all() where BackendTaskProjectScope.includes(goal: goal, project: scope) { rows.append(try await goalView(goal)) }; value = BackendTaskMCP.value([("goals", .array(rows))]) }
        else if verb == "create" || verb == "update" { if verb == "update" { _ = try await goalRow(args["goal"]) } else { guard let title = args["title"].string, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("title is required") } }; var fields = args.removing("do").removing("goal"); if args.has("parent") { fields = fields.setting("parentId", args["parent"]).removing("parent") }; if verb == "update" { fields = fields.setting("id", args["goal"]) }; value = BackendTaskMCP.value([(verb == "create" ? "created" : "updated", try await view.goals.save(fields))]) }
        else if verb == "link" { let row = try await task(args["task"], localOnly: true); if let wanted = args["goal"].string, !wanted.isEmpty { _ = try await goalRow(args["goal"]) }; _ = try await local.update(row.id, input: BackendTaskMCP.value([("goalId", args["goal"].string == "" || args["goal"].isNullish ? .null : args["goal"])]), by: by); value = BackendTaskMCP.value([("task", .string(row.id)), ("goal", args["goal"].isNullish ? .null : args["goal"])]) }
        else { let goal = try await goalRow(args["goal"]), goalID = goal["id"].string ?? ""; if verb == "get" { value = BackendTaskMCP.value([("goal", try await goalView(goal)), ("above", .array(Array(try await view.goals.chain(goalID).dropFirst()).map { BackendTaskMCP.value([("goal", $0["id"]), ("title", $0["title"]), ("status", $0["status"])]) })), ("below", .array(try await view.goals.all().filter { $0["parentId"].string == goalID }.map { BackendTaskMCP.value([("goal", $0["id"]), ("title", $0["title"]), ("status", $0["status"])]) }))]) } else if verb == "remove" { try await view.goals.remove(goalID, tasks: view.store); value = BackendTaskMCP.value([("removed", .string(goalID)), ("movedTo", goal["parentId"])]) } else { throw NativeRPCError.invalidArguments("Unknown goal verb") } }
        return value
    }

    func island() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        // local-task-tools.ts islandTool: the owner's one setting, shown or hidden.
        guard let island else { throw NativeRPCError(code: "not-permitted", message: "The island is not running on this computer right now.") }
        if verb == "set" { guard let on = args["enabled"].bool else { throw NativeRPCError.invalidArguments("enabled is required: true or false") }; value = BackendTaskMCP.value([("enabled", .bool(await island.set(on)))]) }
        else { value = BackendTaskMCP.value([("enabled", .bool(await island.get()))]) }
        return value
    }

    func taskControl() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let row = try await task(args["task"], localOnly: true)
        func optional(_ key: String) throws -> String {
            if args[key].isNullish { return "" }; guard let text = args[key].string else { throw NativeRPCError.invalidArguments("\(key) must be text") }; return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func agentRow() async throws -> NativeRPCValue {
            guard let name = args["agent"].string, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeRPCError.invalidArguments("agent is required: a task agent’s name or id") }
            guard let agent = try await view.config.agent(name.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw NativeRPCError.invalidArguments("there is no task agent called \(name.trimmingCharacters(in: .whitespacesAndNewlines)); tasks_agents lists them") }; return agent
        }
        if id == "tasks.retry" {
            let note = try optional("note")
            try await BackendTaskActor.withActor(by) { if let control { try await control.retry(row.id, note) } else { try await engine.retry(row.id, note: note) } }
            let current = try await task(.string(row.id), localOnly: true)
            value = BackendTaskMCP.value([("task", .string(row.id)), ("process", current.value["process"]), ("tries", .number(current.value["retry"]["count"].number ?? 1))])
        } else if id == "tasks.review" {
            guard let verdict = args["verdict"].string, ["pass", "fail"].contains(verdict) else { throw NativeRPCError.invalidArguments("verdict must be pass or fail") }
            let evidence: [String]
            if args["evidence"].isNullish { evidence = [] } else {
                guard let list = args["evidence"].elements, list.allSatisfy({ $0.string != nil }) else { throw NativeRPCError.invalidArguments("evidence must be a list of text") }
                evidence = list.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            let reasons = try optional("reasons")
            if verdict == "pass", evidence.isEmpty { throw NativeRPCError.invalidArguments("a pass must name its evidence: the files, commands or output you checked") }
            if verdict == "fail", reasons.isEmpty { throw NativeRPCError.invalidArguments("a fail must give reasons") }
            try await BackendTaskActor.withActor(by) { if let control { try await control.review(row.id, verdict == "pass", evidence, reasons) } else { try await engine.review(row.id, pass: verdict == "pass", evidence: evidence, reasons: reasons) } }
            let current = try await task(.string(row.id), localOnly: true)
            value = BackendTaskMCP.value([("task", .string(row.id)), ("status", current.value["crmStatus"]), ("verified", current.value["result"]["verified"].isNullish ? .bool(false) : current.value["result"]["verified"])])
        } else {
            let agent = try await agentRow(), name = agent["name"].string ?? ""
            guard !(row.assigneeKind == "agent" && row.agentID == agent["id"].string) else { throw NativeRPCError(code: "not-permitted", message: "\(name) already has it. To start it again with \(name), use tasks_retry.") }
            let note = try optional("note")
            if !note.isEmpty { try await view.store.note(row.id, by: by, kind: "progress", text: "Given to \(name): \(note)") }
            _ = try await local.update(row.id, input: BackendTaskMCP.value([("assignee", agent["id"])]), by: by)
            let current = try await task(.string(row.id), localOnly: true)
            value = BackendTaskMCP.value([("task", .string(row.id)), ("agent", .string(name)), ("process", current.value["process"])])
        }
        return value
    }

    func claims() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        // PARALLEL-JOBS: the claim list every job of an agent shares, and the jobs Hoot and leads can see.
        guard let jobs = await BackendParallelJobsBox.shared.jobs() else { throw NativeRPCError(code: "unavailable", message: "Parallel jobs are not running on this computer right now.") }
        let agentCaller = by.hasPrefix("taskagent:") ? String(by.dropFirst("taskagent:".count)) : nil
        if verb == "list" {
            value = try await jobs.jobs(agentID: agentCaller ?? args["agent"].string, store: view.store)
        } else {
            guard agentCaller != nil, !caller.sessionID.isEmpty, let mine = try await view.store.bySession(caller.sessionID) else { throw NativeRPCError(code: "not-permitted", message: "Only a task agent's own job claims files, for itself.") }
            let paths = (args["paths"].elements ?? []).compactMap(\.string)
            value = BackendTaskMCP.value([("task", .string(mine.id)), ("claims", .array(try await BackendParallelJobs.claim(mine.id, paths: paths, release: verb == "release", store: view.store).map(NativeRPCValue.string)))])
        }
        return value
    }

    func list() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let sort: TasksListSort
        if let raw = args["sort"].string {
            guard let choice = TasksListSort(rawValue: raw) else { throw NativeRPCError.invalidArguments("Unknown task sort.") }
            sort = choice
        } else { sort = .automatic }
        var rows: [NativeRPCValue] = []; let agents = try await view.config.allAgents(), scope = try await listingScope()
        for row in try await view.store.all() where BackendTaskProjectScope.includes(row, project: scope) { if try await authority.visible(caller, row) { rows.append(BackendTaskMCP.taskView(row, agents: agents).setting("createdAt", row.value["createdAt"]).setting("crmStatus", row.value["crmStatus"]).setting("process", row.value["process"]).setting("finished", .bool(!row.value["result"].isNullish)).setting("verified", row.value["result"].isNullish ? .null : row.value["result"]["verified"]).setting("parent", row.value["parentExternalTaskId"])) } }; value = BackendTaskMCP.value([("tasks", .array(sort.ordered(rows))), ("agents", .array(agents.filter { $0["status"].string != "archived" }))])
        return value
    }

    func get() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let row = try await task(args["task"])
        var children: [BackendTaskRecord] = []
        for child in try await view.store.all() where child.value["parentTaskId"].string == row.id || (child.value["keyId"] == row.value["keyId"] && child.value["parentExternalTaskId"] == row.value["externalTaskId"]) {
            if try await authority.visible(caller, child) { children.append(child) }
        }
        var result = BackendTaskMCP.value([("task", .string(row.id)), ("title", row.value["title"]), ("instructions", row.value["instructions"]), ("project", .string(row.project)), ("crmStatus", row.value["crmStatus"]), ("process", row.value["process"]), ("result", row.value["result"]), ("children", .array(children.map { BackendTaskMCP.value([("task", .string($0.id)), ("title", $0.value["title"]), ("crmStatus", $0.value["crmStatus"]), ("verified", $0.value["result"].isNullish ? .null : $0.value["result"]["verified"])]) }))])
        for key in ["parentTaskId", "reviewerTaskId", "reviewOfTaskId", "keepAliveUntilClose"] where !row.value[key].isNullish { result = result.setting(key, row.value[key]) }
        value = result.merging(BackendTaskMCP.efficiencyView(row))
        return value
    }

    func comment() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let row = try await task(args["task"])
        let kind = try args["kind"].requireString("kind")
        guard ["progress", "blocker", "question", "completion"].contains(kind) else { throw NativeRPCError.invalidArguments("Invalid task comment kind") }
        let identity: String?
        if by.hasPrefix("taskagent:") {
            guard ["agent", BackendAGTLeadSeats.kind].contains(row.assigneeKind), row.agentID == String(by.dropFirst("taskagent:".count)) else { throw NativeRPCError(code: "not-permitted", message: "A task agent may comment only on its own task.") }
            identity = row.isLocal ? row.agentID : row.value["assignee"]["identity"].string
        } else { identity = row.isLocal ? by : try await view.config.connection(row.value["keyId"].string ?? "")?["hootIdentity"].string }
        guard let identity else { throw NativeRPCError(code: "not-permitted", message: "This caller has no CRM identity on this connection.") }
        if !args["event_id"].isNullish {
            guard kind == "progress" else { throw NativeRPCError.invalidArguments("event_id is only for progress reports") }
            let created = try await engine.progressOnce(row.id, text: args["body"].requireString("body", nonempty: true), by: identity, eventID: args["event_id"].requireString("event_id", nonempty: true))
            if !created { return BackendTaskMCP.value([("posted", .bool(true)), ("replayed", .bool(true)), ("event_id", args["event_id"])]) }
        } else { try await engine.comment(row.id, kind: kind, text: args["body"].requireString("body", nonempty: true), by: identity) }
        // CRM-LINK: Hoot @mentioning an agent on a CRM task wakes that agent in the same thread.
        var asked: [String] = []
        if !row.isLocal, !by.hasPrefix("taskagent:") { asked = await BackendCrmLink.relayMentions(row, text: args["body"].string ?? "", local: local, config: view.config, store: view.store) }
        // L4-AGENTS: a lead seat's own words finish its question (or its task, kind completion).
        if row.assigneeKind == BackendAGTLeadSeats.kind, by.hasPrefix("taskagent:") { try await engine.seatSpoke(row.id, kind: kind, text: args["body"].string ?? "") }
        value = BackendTaskMCP.value([("posted", .bool(true))] + (asked.isEmpty ? [] : [("asked", .array(asked.map(NativeRPCValue.string)))]))
            .merging(args["event_id"].isNullish ? .object([]) : BackendTaskMCP.value([("event_id", args["event_id"]), ("replayed", .bool(false))]))
        return value
    }

    func verify() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let row = try await task(args["task"])
        guard let verified = args["verified"].bool else { throw NativeRPCError.invalidArguments("verified has to be true or false") }; try await BackendTaskActor.withActor(by) { try await engine.verify(row.id, verified: verified, note: args["note"].string ?? "") }; value = BackendTaskMCP.value([("crmStatus", try await task(.string(row.id)).value["crmStatus"])])
        return value
    }

    func setStatus() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let row = try await task(args["task"])
        try await engine.setStatus(row.id, status: args["status"].requireString("status", nonempty: true)); value = BackendTaskMCP.value([("crmStatus", try await task(.string(row.id)).value["crmStatus"])])
        return value
    }

    func crmSync() async throws -> NativeRPCValue {
        let value: NativeRPCValue
        let row = try await task(args["task"])
        value = try await BackendCrmLink.sync(row, on: args["on"].bool, store: view.store, outbox: view.outbox)
        return value
    }

    func localSchedule() async throws -> NativeRPCValue { try await localParts() }
    func retry() async throws -> NativeRPCValue { try await taskControl() }
    func reassign() async throws -> NativeRPCValue { try await taskControl() }
    func review() async throws -> NativeRPCValue { try await taskControl() }
}
