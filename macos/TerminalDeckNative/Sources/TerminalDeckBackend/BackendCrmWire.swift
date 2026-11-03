import Foundation
import TerminalDeckNativeCore

/// Shared CRM shapes on the native RPC seam. Uses Core's existing detail
/// models and keeps omitted optional keys distinct from explicit nulls.
public enum BackendCrmWire {
    public static func native(_ value: CrmValue) -> NativeRPCValue {
        switch value {
        case .null: .null
        case .string(let s): .string(s)
        case .number(let n): .number(n)
        case .bool(let b): .bool(b)
        case .array(let list): .array(list.map(native))
        case .object(let row): .object(row.keys.sorted().map { .init($0, native(row[$0]!)) })
        }
    }
    public static func crm(_ value: NativeRPCValue) -> CrmValue {
        switch value {
        case .missing, .null, .bytes: .null
        case .string(let s): .string(s)
        case .number(let n): .number(n)
        case .bool(let b): .bool(b)
        case .array(let list): .array(list.map(crm))
        case .object(let fields): .object(fields.reduce(into: [String: CrmValue]()) { row, field in
            if field.value != .missing { row[field.key] = crm(field.value) }
        })
        }
    }
    static func object(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { .init($0.0, $0.1) }) }
    static func nullable(_ value: String?) -> NativeRPCValue { value.map(NativeRPCValue.string) ?? .null }
    static func nullable(_ value: Double?) -> NativeRPCValue { value.map(NativeRPCValue.number) ?? .null }
    public static func person(_ p: CrmPerson) -> NativeRPCValue {
        object([("id", .string(p.id)), ("name", .string(p.name)), ("initials", .string(p.initials)), ("color", .string(p.color)), ("avatarUrl", nullable(p.avatarUrl))])
    }
    public static func people(_ p: TaskPeople) -> NativeRPCValue {
        object([("primary", p.primary.map(person) ?? .null), ("others", .array(p.others.map(person)))])
    }
    public static func subtask(_ s: SubtaskRow) -> NativeRPCValue {
        object([("id", .string(s.id)), ("title", .string(s.title)), ("done", .bool(s.done)), ("sortOrder", nullable(s.sortOrder)), ("assigneeUserId", nullable(s.assigneeUserId))])
    }
    public static func checklistItem(_ item: ChecklistItem) -> NativeRPCValue {
        object([("id", .string(item.id)), ("title", .string(item.title)), ("done", .bool(item.done)), ("sortOrder", nullable(item.sortOrder)), ("assigneeUserId", nullable(item.assigneeUserId))])
    }
    public static func checklist(_ list: Checklist) -> NativeRPCValue {
        object([("id", .string(list.id)), ("title", .string(list.title)), ("sortOrder", nullable(list.sortOrder)), ("items", .array(list.items.map(checklistItem)))])
    }
    public static func dependency(_ link: TaskDependency) -> NativeRPCValue {
        object([("kind", .string(link.kind.rawValue)), ("otherTaskId", .string(link.otherTaskId)), ("otherTitle", .string(link.otherTitle)), ("otherDone", .bool(link.otherDone))])
    }
    /// Supply the original optional-key object to retain explicit preview null
    /// versus omission; Core's String? intentionally collapses those two.
    public static func attachment(_ file: TaskAttachment, optionalMetadata: NativeRPCValue = .missing) -> NativeRPCValue {
        let preview = optionalMetadata.fields != nil ? optionalMetadata["previewUrl"] : file.previewUrl.map(NativeRPCValue.string) ?? .missing
        return object([("id", .string(file.id)), ("kind", .string(file.kind)), ("fileName", .string(file.fileName)), ("mimeType", nullable(file.mimeType)),
            ("sizeBytes", nullable(file.sizeBytes)), ("documentId", nullable(file.documentId)), ("storagePath", nullable(file.storagePath)),
            ("uploadedBy", nullable(file.uploadedBy)), ("createdAt", .string(file.createdAt)), ("previewUrl", preview)])
    }
    public static func bundle(_ detail: TaskDetailBundle, attachmentMetadata: [String: NativeRPCValue] = [:]) -> NativeRPCValue {
        object([("people", people(detail.people)), ("subtasks", .array(detail.subtasks.map(subtask))), ("checklists", .array(detail.checklists.map(checklist))),
            ("dependencies", .array(detail.dependencies.map(dependency))),
            ("attachments", .array(detail.attachments.map { attachment($0, optionalMetadata: attachmentMetadata[$0.id] ?? .missing) }))])
    }
    public static func timeEntry(_ entry: TimeEntry) -> NativeRPCValue {
        object([("id", .string(entry.id)), ("userId", .string(entry.userId)), ("startedAt", .string(entry.startedAt)), ("endedAt", nullable(entry.endedAt)),
            ("seconds", nullable(entry.seconds)), ("note", nullable(entry.note)), ("billable", .bool(entry.billable))])
    }
    public static func extras(_ page: TaskPageExtras) -> NativeRPCValue {
        let meta = page.subtaskMeta.keys.sorted().map { key -> NativeRPCValue.Field in
            let item = page.subtaskMeta[key]!
            return .init(key, object([("priority", nullable(item.priority)), ("dueDate", nullable(item.dueDate))]))
        }
        return object([("taskType", .string(page.taskType)), ("labels", .array(page.labels.map(NativeRPCValue.string))), ("estimateMinutes", nullable(page.estimateMinutes)),
            ("recurrenceRule", native(page.recurrenceRule)), ("timeEntries", .array(page.timeEntries.map(timeEntry))), ("subtaskMeta", .object(meta))])
    }
    /// Pass the original optional-key object when exact absent/false presence
    /// matters. A typed-only caller emits the booleans it actually holds.
    public static func more(_ detail: TaskMore, optionalMetadata: NativeRPCValue = .missing) -> NativeRPCValue {
        let color = optionalMetadata.fields != nil ? optionalMetadata["canColorTags"] : .bool(detail.canColorTags)
        let followers = optionalMetadata.fields != nil ? optionalMetadata["canRemoveFollowers"] : .bool(detail.canRemoveFollowers)
        return object([("followers", .array(detail.followers.map { object([("userId", .string($0.userId)), ("since", nullable($0.since))]) })),
            ("iFollow", .bool(detail.iFollow)), ("reminders", .array(detail.reminders.map { object([("id", .string($0.id)), ("remindAt", .string($0.remindAt)), ("note", nullable($0.note))]) })),
            ("archivedAt", nullable(detail.archivedAt)), ("startTime", nullable(detail.startTime)), ("dueTime", nullable(detail.dueTime)), ("syncSubtaskDates", .bool(detail.syncSubtaskDates)),
            ("labelColors", .object(detail.labelColors.keys.sorted().map { .init($0, .string(detail.labelColors[$0]!)) })),
            ("entryTags", .object(detail.entryTags.keys.sorted().map { .init($0, .array(detail.entryTags[$0]!.map(NativeRPCValue.string))) })),
            ("remindersLive", .bool(detail.remindersLive)), ("canColorTags", color), ("canRemoveFollowers", followers)])
    }
    public static func descriptionVersion(_ version: DescriptionVersion) -> NativeRPCValue {
        object([("at", .string(version.at)), ("by", nullable(version.by)), ("from", nullable(version.from)), ("to", nullable(version.to))])
    }
    public static func comment(_ comment: TaskComment, aiAgent: NativeRPCValue = .missing) -> NativeRPCValue {
        object([("id", .string(comment.id)), ("taskId", .string(comment.taskId)), ("authorUserId", nullable(comment.authorUserId)), ("authorName", .string(comment.authorName)),
            ("authorInitials", .string(comment.authorInitials)), ("authorColor", .string(comment.authorColor)), ("body", .string(comment.body)),
            ("createdAt", .string(comment.createdAt)), ("aiAgent", aiAgent)])
    }
    public static func commentMeta(_ meta: CommentMeta, optionalMetadata: NativeRPCValue = .missing) -> NativeRPCValue {
        let delivered: NativeRPCValue
        if let value = meta.deliveredAt { delivered = nullable(value) } else { delivered = .missing }
        return object([("parentId", nullable(meta.parentId)), ("resolvedAt", nullable(meta.resolvedAt)), ("resolvedBy", nullable(meta.resolvedBy)),
            ("assigneeUserId", nullable(meta.assigneeUserId)), ("scheduledFor", nullable(meta.scheduledFor)),
            ("withdrawn", optionalMetadata.fields != nil ? optionalMetadata["withdrawn"] : meta.withdrawn.map { object([("at", .string($0.at)), ("reason", .string($0.reason))]) } ?? .missing),
            ("deliveredAt", delivered)])
    }
    public static func commentExtras(_ extras: CommentExtras, metaMetadata: [String: NativeRPCValue] = [:]) -> NativeRPCValue {
        object([("meta", .object(extras.meta.keys.sorted().map { .init($0, commentMeta(extras.meta[$0]!, optionalMetadata: metaMetadata[$0] ?? .missing)) })),
            ("reactions", .object(extras.reactions.keys.sorted().map { key in .init(key, .array(extras.reactions[key]!.map {
                object([("emoji", .string($0.emoji)), ("userIds", .array($0.userIds.map(NativeRPCValue.string)))])
            })) }))])
    }
    public static func activity(_ activity: TaskActivityRow) -> NativeRPCValue {
        object([("id", .string(activity.id)), ("taskId", .string(activity.taskId)), ("kind", .string(activity.kind)), ("payload", native(.object(activity.payload))),
            ("actor", activity.actor.map(person) ?? .null), ("actorUserId", nullable(activity.actorUserId)), ("createdAt", .string(activity.createdAt))])
    }
    public static func routine(_ view: RoutineView) -> NativeRPCValue {
        object([("rootTaskId", .string(view.rootTaskId)), ("rootTitle", .string(view.rootTitle)), ("isRoot", .bool(view.isRoot)), ("rule", view.rule.map(native) ?? .null),
            ("canEdit", .bool(view.canEdit)), ("history", view.history.map { .array($0.map(native)) } ?? .null), ("historyError", nullable(view.historyError)),
            ("lastError", view.lastError.map { object([("at", .string($0.at)), ("message", .string($0.message))]) } ?? .null),
            ("next", .array(view.next.map(NativeRPCValue.string))), ("peopleCount", .number(Double(view.peopleCount))), ("version", nullable(view.version)),
            ("stuck", nullable(view.stuck)), ("canRestart", .bool(view.canRestart)), ("anchor", nullable(view.anchor)),
            ("occurrence", nullable(view.occurrence)), ("datesSoFar", .number(Double(view.datesSoFar)))])
    }
    public static func occurrence(_ row: BackendCrmRoutineRules.OccurrenceRow, who: String? = nil, includeWho: Bool = false) -> NativeRPCValue {
        object([("id", .string(row.id)), ("occurrenceDate", .string(row.occurrenceDate)), ("dueDate", nullable(row.dueDate)),
            ("assigneeUserId", nullable(row.assigneeUserId)), ("spawnedTaskId", nullable(row.spawnedTaskId)), ("status", .string(row.status)),
            ("completedAt", nullable(row.completedAt)), ("completedBy", nullable(row.completedBy)), ("who", includeWho ? nullable(who) : .missing)])
    }
    public static func field(_ field: TaskField) -> NativeRPCValue {
        object([("id", .string(field.id)), ("taskId", .string(field.taskId)), ("label", .string(field.label)), ("kind", .string(field.kind.rawValue)),
            ("config", native(field.config.crm(field.kind))), ("value", native(field.value)), ("sortOrder", nullable(field.sortOrder)),
            ("createdBy", nullable(field.createdBy)), ("createdAt", .string(field.createdAt)), ("updatedAt", nullable(field.updatedAt))])
    }
    public static func autoProgress(_ progress: AutoProgress) -> NativeRPCValue {
        object([("subtasks", object([("done", .number(Double(progress.subtasksDone))), ("total", .number(Double(progress.subtasksTotal)))])),
            ("checklists", object([("done", .number(Double(progress.checklistsDone))), ("total", .number(Double(progress.checklistsTotal)))]))])
    }
    /// All Task keys, with optional fields supplied by the task owner. The
    /// locally persisted record and the public CRM task have different shapes.
    public static func task(_ task: CrmTask, links: [BackendCrmTags.Hit] = [], metadata: NativeRPCValue = .missing) -> NativeRPCValue {
        var wire = object([("id", .string(task.id)), ("title", .string(task.title)), ("group", .string(task.group)), ("board", .string(task.board)),
            ("priority", nullable(task.priority)), ("startDate", .string(task.startDate)), ("dueDate", .string(task.dueDate)), ("recurrence", nullable(task.recurrence)),
            ("description", .string(task.description)), ("assigneeUserId", nullable(task.assigneeUserId)), ("assigneeName", .string(task.assignee?.name ?? "")),
            ("assigneeInitials", .string(task.assignee?.initials ?? "")), ("assigneeColor", .string(task.assignee?.color ?? "")), ("assigneeAvatarUrl", nullable(task.assignee?.avatarUrl)),
            ("createdBy", nullable(task.createdBy)), ("createdAt", task.createdAt.map(NativeRPCValue.string) ?? .missing), ("sortOrder", nullable(task.sortOrder)),
            ("links", .array(links.map(\.tagWire))), ("labels", .array(task.labels.map(NativeRPCValue.string))), ("taskType", .string(task.taskType)),
            ("archivedAt", nullable(task.archivedAt)), ("startTime", nullable(task.startTime)), ("dueTime", nullable(task.dueTime))])
        if metadata.fields != nil {
            for key in BackendCrmTasksData.optionalTaskKeys {
                wire = metadata.has(key) ? wire.setting(key, metadata[key]) : wire.removing(key)
            }
        }
        return wire
    }
    /// tasks-data.ts's basic TaskSubtask includes taskId and requires an order;
    /// the collaborative SubtaskRow above intentionally has neither constraint.
    public static func taskSubtask(_ subtask: SubtaskRow, taskID: String, sortOrder: Double) -> NativeRPCValue {
        object([("id", .string(subtask.id)), ("taskId", .string(taskID)), ("title", .string(subtask.title)), ("done", .bool(subtask.done)), ("sortOrder", .number(sortOrder))])
    }
}

extension BackendCrmTasksData {
    /// The source's create-dialog payload, which Core's backend task creation
    /// input does not model. The task owner translates it before persistence.
    public struct NewTaskInput: Sendable, Equatable {
        public var title: String, group: String, board: String, dueDate: String
        public var priority: String?, assigneeUserId: String?
        public var startDate: String?, recurrence: String?, routine: RoutineRule?, description: String?
        public var tags: [BackendCrmTags.Hit]?
        public init(title: String, group: String, board: String, dueDate: String, priority: String? = nil, assigneeUserId: String? = nil,
                    startDate: String? = nil, recurrence: String? = nil, routine: RoutineRule? = nil, description: String? = nil, tags: [BackendCrmTags.Hit]? = nil) {
            self.title = title; self.group = group; self.board = board; self.dueDate = dueDate; self.priority = priority; self.assigneeUserId = assigneeUserId
            self.startDate = startDate; self.recurrence = recurrence; self.routine = routine; self.description = description; self.tags = tags
        }
        public var wire: NativeRPCValue { wire(preservingOptional: .missing) }
        /// A raw optional-key bag can carry explicit null where the typed
        /// dialog input otherwise omits an unset optional value.
        public func wire(preservingOptional metadata: NativeRPCValue) -> NativeRPCValue {
            var result: NativeRPCValue = .object([.init("title", .string(title)), .init("group", .string(group)), .init("board", .string(board)), .init("dueDate", .string(dueDate)),
                .init("priority", priority.map(NativeRPCValue.string) ?? .null), .init("assigneeUserId", assigneeUserId.map(NativeRPCValue.string) ?? .null),
                .init("startDate", startDate.map(NativeRPCValue.string) ?? .missing), .init("recurrence", recurrence.map(NativeRPCValue.string) ?? .missing),
                .init("routine", routine.map { BackendCrmWire.native(BackendCrmRoutineRules.serializeRoutine($0)) } ?? .missing),
                .init("description", description.map(NativeRPCValue.string) ?? .missing), .init("tags", tags.map { .array($0.map(\.tagWire)) } ?? .missing)])
            if metadata.fields != nil {
                for key in ["startDate", "recurrence", "routine", "description", "tags"] {
                    result = metadata.has(key) ? result.setting(key, metadata[key]) : result.removing(key)
                }
            }
            return result
        }
    }
}
