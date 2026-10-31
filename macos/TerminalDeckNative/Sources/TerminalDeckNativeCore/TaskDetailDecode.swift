import Foundation

// MARK: - Decoding

public enum CrmDecode {
    private typealias J = TasksJSON

    /// A call's answer: ok, or its refusal in words (`error`).
    public static func ok(_ raw: Any?) -> Result<[String: Any], TasksProblem> {
        guard let r = J.record(raw), let ok = J.bool(r["ok"]) else {
            return .failure(TasksProblem("Terminal Deck did not answer that."))
        }
        if ok { return .success(r) }
        return .failure(TasksProblem(r["error"] as? String ?? "failed"))
    }

    static func string(_ v: Any?) -> String? { v as? String }

    public static func person(_ raw: Any?) -> CrmPerson? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        let name = r["name"] as? String ?? "Unknown"
        return CrmPerson(id: id, name: name, initials: J.text(r["initials"]) ?? CrmPeople.deriveInitials(name),
                         color: J.text(r["color"]) ?? CrmPeople.avatarPalette[0], avatarUrl: J.text(r["avatarUrl"]))
    }

    public static func people(_ raw: Any?) -> TaskPeople {
        let r = J.record(raw)
        return TaskPeople(primary: person(r?["primary"]), others: (r?["others"] as? [Any] ?? []).compactMap(person))
    }

    public static func subtask(_ raw: Any?) -> SubtaskRow? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        return SubtaskRow(id: id, title: r["title"] as? String ?? "", done: J.isTrue(r["done"]),
                          sortOrder: J.number(r["sortOrder"]), assigneeUserId: J.text(r["assigneeUserId"]))
    }

    public static func checklist(_ raw: Any?) -> Checklist? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        let items: [ChecklistItem] = (r["items"] as? [Any] ?? []).compactMap { item in
            guard let i = J.record(item), let iid = J.text(i["id"]) else { return nil }
            return ChecklistItem(id: iid, title: i["title"] as? String ?? "", done: J.isTrue(i["done"]),
                                 sortOrder: J.number(i["sortOrder"]), assigneeUserId: J.text(i["assigneeUserId"]))
        }
        return Checklist(id: id, title: r["title"] as? String ?? "", sortOrder: J.number(r["sortOrder"]), items: items)
    }

    public static func dependency(_ raw: Any?) -> TaskDependency? {
        guard let r = J.record(raw), let other = J.text(r["otherTaskId"]),
              let kind = (r["kind"] as? String).flatMap(DependencyKind.init(rawValue:)) else { return nil }
        return TaskDependency(kind: kind, otherTaskId: other, otherTitle: r["otherTitle"] as? String ?? "",
                              otherDone: J.isTrue(r["otherDone"]))
    }

    public static func attachment(_ raw: Any?) -> TaskAttachment? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        return TaskAttachment(id: id, kind: (r["kind"] as? String) == "document" ? "document" : "upload",
                              fileName: r["fileName"] as? String ?? "", mimeType: J.text(r["mimeType"]),
                              sizeBytes: J.number(r["sizeBytes"]), documentId: J.text(r["documentId"]),
                              storagePath: J.text(r["storagePath"]), uploadedBy: J.text(r["uploadedBy"]),
                              createdAt: r["createdAt"] as? String ?? "", previewUrl: J.text(r["previewUrl"]))
    }

    public static func bundle(_ raw: Any?) -> TaskDetailBundle? {
        guard let r = J.record(raw) else { return nil }
        return TaskDetailBundle(
            people: people(r["people"]),
            subtasks: (r["subtasks"] as? [Any] ?? []).compactMap(subtask),
            checklists: (r["checklists"] as? [Any] ?? []).compactMap(checklist),
            dependencies: (r["dependencies"] as? [Any] ?? []).compactMap(dependency),
            attachments: (r["attachments"] as? [Any] ?? []).compactMap(attachment))
    }

    public static func timeEntry(_ raw: Any?) -> TimeEntry? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        return TimeEntry(id: id, userId: r["userId"] as? String ?? "", startedAt: r["startedAt"] as? String ?? "",
                         endedAt: J.text(r["endedAt"]), seconds: J.number(r["seconds"]), note: J.text(r["note"]),
                         billable: J.isTrue(r["billable"]))
    }

    public static func extras(_ raw: Any?) -> TaskPageExtras? {
        guard let r = J.record(raw) else { return nil }
        var meta: [String: SubtaskMeta] = [:]
        for (id, value) in J.record(r["subtaskMeta"]) ?? [:] {
            let m = J.record(value)
            meta[id] = SubtaskMeta(priority: J.text(m?["priority"]), dueDate: J.text(m?["dueDate"]))
        }
        return TaskPageExtras(taskType: (r["taskType"] as? String) == "milestone" ? "milestone" : "task",
                              labels: J.strings(r["labels"]), estimateMinutes: J.number(r["estimateMinutes"]),
                              recurrenceRule: CrmValue(r["recurrenceRule"]),
                              timeEntries: (r["timeEntries"] as? [Any] ?? []).compactMap(timeEntry), subtaskMeta: meta)
    }

    public static func more(_ raw: Any?) -> TaskMore? {
        guard let r = J.record(raw) else { return nil }
        var colors: [String: String] = [:]
        for (label, color) in J.record(r["labelColors"]) ?? [:] { if let c = color as? String { colors[label] = c } }
        var tags: [String: [String]] = [:]
        for (entry, list) in J.record(r["entryTags"]) ?? [:] { tags[entry] = J.strings(list) }
        return TaskMore(
            followers: (r["followers"] as? [Any] ?? []).compactMap { f in
                guard let f = J.record(f), let id = J.text(f["userId"]) else { return nil }
                return (id, J.text(f["since"]))
            },
            iFollow: J.bool(r["iFollow"]) ?? true,
            reminders: (r["reminders"] as? [Any] ?? []).compactMap { x in
                guard let x = J.record(x), let id = J.text(x["id"]) else { return nil }
                return TaskReminder(id: id, remindAt: x["remindAt"] as? String ?? "", note: J.text(x["note"]))
            },
            archivedAt: J.text(r["archivedAt"]), startTime: J.text(r["startTime"]), dueTime: J.text(r["dueTime"]),
            syncSubtaskDates: J.isTrue(r["syncSubtaskDates"]), labelColors: colors, entryTags: tags,
            remindersLive: J.isTrue(r["remindersLive"]), canColorTags: J.isTrue(r["canColorTags"]),
            canRemoveFollowers: J.isTrue(r["canRemoveFollowers"]))
    }

    public static func comment(_ raw: Any?) -> TaskComment? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        let name = r["authorName"] as? String ?? ""
        return TaskComment(id: id, taskId: r["taskId"] as? String ?? "", authorUserId: J.text(r["authorUserId"]),
                           authorName: name, authorInitials: J.text(r["authorInitials"]) ?? CrmPeople.deriveInitials(name),
                           authorColor: J.text(r["authorColor"]) ?? CrmPeople.avatarPalette[0], body: r["body"] as? String ?? "",
                           createdAt: r["createdAt"] as? String ?? "")
    }

    public static func commentExtras(_ raw: Any?) -> CommentExtras? {
        guard let r = J.record(raw) else { return nil }
        var meta: [String: CommentMeta] = [:]
        for (id, value) in J.record(r["meta"]) ?? [:] {
            guard let m = J.record(value) else { continue }
            let withdrawn = J.record(m["withdrawn"]).flatMap { w -> (at: String, reason: String)? in
                guard let at = w["at"] as? String else { return nil }
                return (at, w["reason"] as? String ?? "")
            }
            let delivered: String?? = m.keys.contains("deliveredAt") ? .some(J.text(m["deliveredAt"])) : .none
            meta[id] = CommentMeta(parentId: J.text(m["parentId"]), resolvedAt: J.text(m["resolvedAt"]),
                                   resolvedBy: J.text(m["resolvedBy"]), assigneeUserId: J.text(m["assigneeUserId"]),
                                   scheduledFor: J.text(m["scheduledFor"]), withdrawn: withdrawn, deliveredAt: delivered)
        }
        var reactions: [String: [CommentReaction]] = [:]
        for (id, list) in J.record(r["reactions"]) ?? [:] {
            reactions[id] = (list as? [Any] ?? []).compactMap { x in
                guard let x = J.record(x), let emoji = x["emoji"] as? String else { return nil }
                return CommentReaction(emoji: emoji, userIds: J.strings(x["userIds"]))
            }
        }
        return CommentExtras(meta: meta, reactions: reactions)
    }

    public static func activity(_ raw: Any?) -> TaskActivityRow? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        return TaskActivityRow(id: id, taskId: r["taskId"] as? String ?? "", kind: r["kind"] as? String ?? "",
                               payload: CrmValue(r["payload"]).object ?? [:], actor: person(r["actor"]),
                               actorUserId: J.text(r["actorUserId"]), createdAt: r["createdAt"] as? String ?? "")
    }

    public static func routine(_ raw: Any?) -> RoutineView? {
        guard let r = J.record(raw) else { return nil }
        let rule = CrmValue(r["rule"])
        let lastError = J.record(r["lastError"]).flatMap { e -> (at: String, message: String)? in
            guard let at = e["at"] as? String else { return nil }
            return (at, e["message"] as? String ?? "")
        }
        return RoutineView(rootTaskId: r["rootTaskId"] as? String ?? "", rootTitle: r["rootTitle"] as? String ?? "",
                           isRoot: J.isTrue(r["isRoot"]), rule: rule == .null ? nil : rule, canEdit: J.isTrue(r["canEdit"]),
                           history: (r["history"] as? [Any]).map { $0.map { CrmValue($0) } },
                           historyError: J.text(r["historyError"]), lastError: lastError, next: J.strings(r["next"]),
                           peopleCount: J.int(r["peopleCount"], 1), version: J.number(r["version"]), stuck: J.text(r["stuck"]),
                           canRestart: J.isTrue(r["canRestart"]), anchor: J.text(r["anchor"]),
                           occurrence: J.text(r["occurrence"]), datesSoFar: J.int(r["datesSoFar"], 0))
    }

    public static func version(_ raw: Any?) -> DescriptionVersion? {
        guard let r = J.record(raw) else { return nil }
        return DescriptionVersion(at: r["at"] as? String ?? "", by: J.text(r["by"]), from: r["from"] as? String,
                                  to: r["to"] as? String)
    }
}
