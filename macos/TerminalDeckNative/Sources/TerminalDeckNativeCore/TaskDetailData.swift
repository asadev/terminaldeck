import Foundation

// The task popup's data and rules — the reference CRM's task page, as the
// window copied it (src/shared/crm/*.ts, src/renderer/crm-task/task-collab-draft.ts,
// LocalTaskPopup.tsx). Every value arrives as JSON from `tasks:local-detail`
// and is read field by field.

// MARK: - A JSON value, kept whole (activity payloads, routine rules)

public indirect enum CrmValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([CrmValue])
    case object([String: CrmValue])

    public init(_ any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let string as String: self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let array as [Any]: self = .array(array.map { CrmValue($0) })
        case let dict as [String: Any]: self = .object(dict.mapValues { CrmValue($0) })
        default: self = .null
        }
    }

    /// Back to Foundation objects, for the wire.
    public var any: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: Double? { if case .number(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var array: [CrmValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: CrmValue]? { if case .object(let o) = self { o } else { nil } }
    public subscript(key: String) -> CrmValue? { object?[key] }
}

// MARK: - People

/// One person a task can name: you, Hoot, or one of your task agents.
public struct CrmPerson: Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var initials: String
    /// A palette name (`bg-blue-500` …), as the CRM stores it.
    public var color: String
    public var avatarUrl: String?

    public init(id: String, name: String, initials: String, color: String, avatarUrl: String? = nil) {
        self.id = id
        self.name = name
        self.initials = initials
        self.color = color
        self.avatarUrl = avatarUrl
    }
}

public enum CrmPeople {
    public static let me = "me"
    public static let hoot = "hoot"

    public static let avatarPalette = [
        "bg-blue-500", "bg-violet-500", "bg-emerald-500", "bg-amber-500", "bg-rose-500",
        "bg-sky-500", "bg-indigo-500", "bg-teal-500", "bg-orange-500", "bg-fuchsia-500",
    ]

    /// JavaScript's `(h * 31 + charCode) | 0` over UTF-16, then |h| mod n.
    public static func hashStringToIndex(_ s: String, _ modulo: Int) -> Int {
        var h: Int32 = 0
        for unit in s.utf16 { h = h &* 31 &+ Int32(unit) }
        return Int(abs(Int64(h)) % Int64(modulo))
    }

    public static func deriveInitials(_ name: String?) -> String {
        let safe = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.isEmpty { return "?" }
        let parts = safe.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.isEmpty { return "?" }
        if parts.count == 1 { return String(parts[0].prefix(2)).uppercased() }
        return (String(parts[0].prefix(1)) + String(parts[1].prefix(1))).uppercased()
    }

    public static func person(_ id: String, _ name: String) -> CrmPerson {
        CrmPerson(id: id, name: name, initials: id == me ? "ME" : deriveInitials(name),
                  color: avatarPalette[hashStringToIndex(id, avatarPalette.count)])
    }

    /// Everyone a local task can name: you, Hoot, then your task agents in their own order.
    public static func local(_ agents: [(id: String, name: String)]) -> [CrmPerson] {
        [person(me, "You"), person(hoot, "Hoot")] + agents.map { person($0.id, $0.name) }
    }
}

/// Who is on a task: the main person, then the others.
public struct TaskPeople: Equatable, Sendable {
    public var primary: CrmPerson?
    public var others: [CrmPerson]

    public init(primary: CrmPerson?, others: [CrmPerson] = []) {
        self.primary = primary
        self.others = others
    }

    public var list: [CrmPerson] { (primary.map { [$0] } ?? []) + others }
    public func has(_ id: String) -> Bool { primary?.id == id || others.contains { $0.id == id } }

    public func adding(_ person: CrmPerson) -> TaskPeople {
        if has(person.id) { return self }
        if primary == nil { return TaskPeople(primary: person, others: others) }
        return TaskPeople(primary: primary, others: others + [person])
    }

    /// Taking the main person off promotes the next face.
    public func removing(_ id: String) -> TaskPeople {
        if primary?.id == id { return TaskPeople(primary: others.first, others: Array(others.dropFirst())) }
        return TaskPeople(primary: primary, others: others.filter { $0.id != id })
    }

    /// An item's own person if they are on the task, else the task's main person (inherited).
    public func assignee(for itemAssignee: String?) -> (person: CrmPerson?, inherited: Bool) {
        if let id = itemAssignee, let own = list.first(where: { $0.id == id }) { return (own, false) }
        return (primary, true)
    }
}

// MARK: - The task, as the CRM's `Task`

public struct CrmTask: Equatable, Sendable {
    public var id: String
    public var title: String
    /// The status (`group` in the CRM).
    public var group: String
    public var board: String
    public var priority: String?
    public var startDate: String
    public var dueDate: String
    public var recurrence: String?
    public var description: String
    public var assigneeUserId: String?
    public var assignee: CrmPerson?
    public var createdBy: String?
    /// ISO time.
    public var createdAt: String?
    public var sortOrder: Double?
    public var labels: [String]
    public var taskType: String
    public var archivedAt: String?
    public var startTime: String?
    public var dueTime: String?

    /// Your task as the CRM's `Task` (`crmTaskOf`): details are the description, the
    /// board is the CRM's board, the person at this Mac is `me`.
    public init(_ row: TaskRow, team: [CrmPerson]) {
        let person = row.assignee == "none" ? nil : team.first { $0.id == row.assignee }
        id = row.id
        title = row.title
        group = row.crmStatus
        board = row.board ?? ""
        priority = row.priority
        startDate = row.startDate ?? ""
        dueDate = row.dueDate ?? ""
        recurrence = row.recurrence
        description = row.instructions
        assigneeUserId = row.assignee == "none" ? nil : row.assignee
        assignee = person
        createdBy = CrmPeople.me
        createdAt = CrmTime.iso(row.createdAt)
        sortOrder = row.position
        labels = row.labels
        taskType = row.taskType
        archivedAt = row.archivedAt.map(CrmTime.iso)
        startTime = row.startTime
        dueTime = row.dueTime
    }
}

// MARK: - The bundle

public struct SubtaskRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var done: Bool
    public var sortOrder: Double?
    public var assigneeUserId: String?
    public init(id: String, title: String, done: Bool = false, sortOrder: Double? = nil, assigneeUserId: String? = nil) {
        self.id = id
        self.title = title
        self.done = done
        self.sortOrder = sortOrder
        self.assigneeUserId = assigneeUserId
    }
}

public struct ChecklistItem: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var done: Bool
    public var sortOrder: Double?
    public var assigneeUserId: String?

    public init(id: String, title: String, done: Bool, sortOrder: Double?, assigneeUserId: String?) {
        self.id = id
        self.title = title
        self.done = done
        self.sortOrder = sortOrder
        self.assigneeUserId = assigneeUserId
    }
}

public struct Checklist: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var sortOrder: Double?
    public var items: [ChecklistItem]

    public init(id: String, title: String, sortOrder: Double?, items: [ChecklistItem]) {
        self.id = id
        self.title = title
        self.sortOrder = sortOrder
        self.items = items
    }

    public var progress: (done: Int, total: Int) { (items.filter(\.done).count, items.count) }
}

public enum DependencyKind: String, Equatable, Sendable, CaseIterable {
    case blockedBy = "blocked_by", blocks, linked

    public var label: String {
        switch self {
        case .blockedBy: "Blocked by"
        case .blocks: "Blocks"
        case .linked: "Linked"
        }
    }
}

public struct TaskDependency: Equatable, Sendable, Identifiable {
    public var kind: DependencyKind
    public var otherTaskId: String
    public var otherTitle: String
    public var otherDone: Bool
    public var id: String { "\(kind.rawValue):\(otherTaskId)" }

    public init(kind: DependencyKind, otherTaskId: String, otherTitle: String, otherDone: Bool) {
        self.kind = kind
        self.otherTaskId = otherTaskId
        self.otherTitle = otherTitle
        self.otherDone = otherDone
    }
}

public struct TaskAttachment: Equatable, Sendable, Identifiable {
    public var id: String
    /// `upload` or `document`.
    public var kind: String
    public var fileName: String
    public var mimeType: String?
    public var sizeBytes: Double?
    public var documentId: String?
    public var storagePath: String?
    public var uploadedBy: String?
    public var createdAt: String
    /// A picture's own preview (a data: address).
    public var previewUrl: String?
}

public struct TaskDetailBundle: Equatable, Sendable {
    public var people: TaskPeople
    public var subtasks: [SubtaskRow]
    public var checklists: [Checklist]
    public var dependencies: [TaskDependency]
    public var attachments: [TaskAttachment]
}

// MARK: - Page extras, more, comments, activity

public struct TimeEntry: Equatable, Sendable, Identifiable {
    public var id: String
    public var userId: String
    public var startedAt: String
    public var endedAt: String?
    public var seconds: Double?
    public var note: String?
    public var billable: Bool
}

public struct SubtaskMeta: Equatable, Sendable {
    public var priority: String?
    public var dueDate: String?
    public init(priority: String? = nil, dueDate: String? = nil) {
        self.priority = priority
        self.dueDate = dueDate
    }
}

public struct TaskPageExtras: Equatable, Sendable {
    public var taskType: String
    public var labels: [String]
    public var estimateMinutes: Double?
    public var recurrenceRule: CrmValue
    public var timeEntries: [TimeEntry]
    public var subtaskMeta: [String: SubtaskMeta]
}

public struct TaskReminder: Equatable, Sendable, Identifiable {
    public var id: String
    public var remindAt: String
    public var note: String?
}

public struct TaskMore: Equatable, Sendable {
    public var followers: [(userId: String, since: String?)]
    public var iFollow: Bool
    public var reminders: [TaskReminder]
    public var archivedAt: String?
    public var startTime: String?
    public var dueTime: String?
    public var syncSubtaskDates: Bool
    public var labelColors: [String: String]
    public var entryTags: [String: [String]]
    public var remindersLive: Bool
    public var canColorTags: Bool
    public var canRemoveFollowers: Bool

    public static func == (a: TaskMore, b: TaskMore) -> Bool {
        a.followers.map(\.userId) == b.followers.map(\.userId) && a.iFollow == b.iFollow && a.reminders == b.reminders
            && a.archivedAt == b.archivedAt && a.startTime == b.startTime && a.dueTime == b.dueTime
            && a.syncSubtaskDates == b.syncSubtaskDates && a.labelColors == b.labelColors && a.entryTags == b.entryTags
            && a.remindersLive == b.remindersLive && a.canColorTags == b.canColorTags && a.canRemoveFollowers == b.canRemoveFollowers
    }
}

public struct DescriptionVersion: Equatable, Sendable {
    public var at: String
    public var by: String?
    public var from: String?
    public var to: String?
}

public struct TaskComment: Equatable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var authorUserId: String?
    public var authorName: String
    public var authorInitials: String
    public var authorColor: String
    public var body: String
    public var createdAt: String
}

public struct CommentMeta: Equatable, Sendable {
    public var parentId: String?
    public var resolvedAt: String?
    public var resolvedBy: String?
    public var assigneeUserId: String?
    public var scheduledFor: String?
    public var withdrawn: (at: String, reason: String)?
    /// Absent (nil outer) when the read did not say; `.some(nil)` when not delivered yet.
    public var deliveredAt: String??

    public init(parentId: String? = nil, resolvedAt: String? = nil, resolvedBy: String? = nil, assigneeUserId: String? = nil,
                scheduledFor: String? = nil, withdrawn: (at: String, reason: String)? = nil, deliveredAt: String?? = nil) {
        self.parentId = parentId
        self.resolvedAt = resolvedAt
        self.resolvedBy = resolvedBy
        self.assigneeUserId = assigneeUserId
        self.scheduledFor = scheduledFor
        self.withdrawn = withdrawn
        self.deliveredAt = deliveredAt
    }

    public static func == (a: CommentMeta, b: CommentMeta) -> Bool {
        a.parentId == b.parentId && a.resolvedAt == b.resolvedAt && a.resolvedBy == b.resolvedBy
            && a.assigneeUserId == b.assigneeUserId && a.scheduledFor == b.scheduledFor
            && a.withdrawn?.at == b.withdrawn?.at && a.withdrawn?.reason == b.withdrawn?.reason && a.deliveredAt == b.deliveredAt
    }
}

public struct CommentReaction: Equatable, Sendable {
    public var emoji: String
    public var userIds: [String]

    public init(emoji: String, userIds: [String]) {
        self.emoji = emoji
        self.userIds = userIds
    }
}

public struct CommentExtras: Equatable, Sendable {
    public var meta: [String: CommentMeta]
    public var reactions: [String: [CommentReaction]]
}

public struct TaskActivityRow: Equatable, Sendable, Identifiable {
    public var id: String
    public var taskId: String
    public var kind: String
    public var payload: [String: CrmValue]
    public var actor: CrmPerson?
    public var actorUserId: String?
    public var createdAt: String

    public init(id: String, taskId: String, kind: String, payload: [String: CrmValue], actor: CrmPerson?,
                actorUserId: String?, createdAt: String) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.payload = payload
        self.actor = actor
        self.actorUserId = actorUserId
        self.createdAt = createdAt
    }
}

/// The routine a task belongs to (`RoutineView`); its rule kept whole for the
/// routine panel and block.
public struct RoutineView: Equatable, Sendable {
    public var rootTaskId: String
    public var rootTitle: String
    public var isRoot: Bool
    public var rule: CrmValue?
    public var canEdit: Bool
    public var history: [CrmValue]?
    public var historyError: String?
    public var lastError: (at: String, message: String)?
    public var next: [String]
    public var peopleCount: Int
    public var version: Double?
    public var stuck: String?
    public var canRestart: Bool
    public var anchor: String?
    public var occurrence: String?
    public var datesSoFar: Int

    public init(rootTaskId: String, rootTitle: String, isRoot: Bool, rule: CrmValue?, canEdit: Bool, history: [CrmValue]?,
                historyError: String?, lastError: (at: String, message: String)?, next: [String], peopleCount: Int,
                version: Double?, stuck: String?, canRestart: Bool, anchor: String?, occurrence: String?, datesSoFar: Int) {
        self.rootTaskId = rootTaskId
        self.rootTitle = rootTitle
        self.isRoot = isRoot
        self.rule = rule
        self.canEdit = canEdit
        self.history = history
        self.historyError = historyError
        self.lastError = lastError
        self.next = next
        self.peopleCount = peopleCount
        self.version = version
        self.stuck = stuck
        self.canRestart = canRestart
        self.anchor = anchor
        self.occurrence = occurrence
        self.datesSoFar = datesSoFar
    }

    public static func == (a: RoutineView, b: RoutineView) -> Bool {
        a.rootTaskId == b.rootTaskId && a.rootTitle == b.rootTitle && a.isRoot == b.isRoot && a.rule == b.rule
            && a.canEdit == b.canEdit && a.history == b.history && a.historyError == b.historyError
            && a.lastError?.at == b.lastError?.at && a.lastError?.message == b.lastError?.message && a.next == b.next
            && a.peopleCount == b.peopleCount && a.version == b.version && a.stuck == b.stuck && a.canRestart == b.canRestart
            && a.anchor == b.anchor && a.occurrence == b.occurrence && a.datesSoFar == b.datesSoFar
    }
}

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

// MARK: - Text rules (task-page.ts, inline-files.ts)

public enum CrmText {
    public static let headingMax = 80
    public static let chipChar: Character = "\u{FFFC}"

    public enum Part: Equatable, Sendable {
        case text(String)
        case file(String)
    }

    /// `[[file:<id>]]` tokens and the text between them.
    public static func splitInlineFiles(_ text: String) -> [Part] {
        var out: [Part] = []
        var rest = Substring(text)
        while let open = rest.range(of: "[[file:") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "]]") else { break }
            let id = String(afterOpen[..<close.lowerBound])
            let valid = !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":") }
                && (id.hasPrefix("draft:") ? id.dropFirst(6).allSatisfy { $0 != ":" } : !id.contains(":"))
            if valid {
                if open.lowerBound > rest.startIndex { out.append(.text(String(rest[..<open.lowerBound]))) }
                out.append(.file(id))
                rest = afterOpen[close.upperBound...]
            } else {
                out.append(.text(String(rest[..<open.upperBound])))
                rest = afterOpen
            }
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        // Merge neighbouring text parts.
        var merged: [Part] = []
        for part in out {
            if case .text(let t) = part, case .text(let previous)? = merged.last {
                merged[merged.count - 1] = .text(previous + t)
            } else {
                merged.append(part)
            }
        }
        return merged
    }

    public static func fileToken(_ id: String) -> String { "[[file:\(id)]]" }

    public static func fileTokenIds(_ text: String) -> [String] {
        splitInlineFiles(text).compactMap { if case .file(let id) = $0 { id } else { nil } }
    }

    /// Tokens as one chip character each (the text field's own form).
    public static func toFlat(_ text: String) -> String {
        splitInlineFiles(text).map { part in
            switch part {
            case .text(let t): t
            case .file: String(chipChar)
            }
        }.joined()
    }

    /// The chips back as tokens, in order.
    public static func fromFlat(_ flat: String, ids: [String]) -> String {
        var k = 0
        var out = ""
        for ch in flat {
            if ch == chipChar {
                if k < ids.count { out += fileToken(ids[k]) }
                k += 1
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// The heading (the first line or sentence, at most 80 visible characters) and
    /// the rest. Cut mid-way, the two halves carry an ellipsis.
    public static func split(_ text: String) -> (heading: String, body: String, cut: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Each visible character with where it starts in the stored text (UTF-16, as JS slices).
        var storage: [Int] = []
        var chars: [Character?] = []
        var visible: [Int] = []
        var s = 0, v = 0
        for part in splitInlineFiles(trimmed) {
            switch part {
            case .file(let id):
                storage.append(s); visible.append(v); chars.append(nil)
                s += fileToken(id).utf16.count
            case .text(let t):
                for ch in t {
                    storage.append(s); visible.append(v); chars.append(ch)
                    s += String(ch).utf16.count
                    v += 1
                }
            }
        }
        let utf = Array(trimmed.utf16)
        func slice(_ a: Int, _ b: Int? = nil) -> String {
            let end = b ?? utf.count
            return String(decoding: utf[max(0, min(a, utf.count))..<max(0, min(end, utf.count))], as: UTF16.self)
        }
        func at(_ i: Int) -> Int { i < storage.count ? storage[i] : utf.count }
        let ws = CharacterSet.whitespacesAndNewlines
        func t(_ x: String) -> String { x.trimmingCharacters(in: ws) }
        let visibleTotal = v
        let nl = chars.firstIndex { $0 == "\n" } ?? -1
        if nl > 0 && visible[nl] <= headingMax {
            return (t(slice(0, at(nl))), t(slice(at(nl) + 1)), false)
        }
        if chars.count > 1 {
            for i in 0..<(chars.count - 1) {
                if visible[i] >= headingMax { break }
                if let c = chars[i], c == "." || c == "?" || c == "!", chars[i + 1] == " " {
                    let end = at(i + 1)
                    let rest = t(slice(end))
                    if !rest.isEmpty { return (t(slice(0, end)), rest, false) }
                }
            }
        }
        if visibleTotal <= headingMax && nl < 0 { return (trimmed, "", false) }
        if visibleTotal <= headingMax { return (t(slice(0, at(nl))), t(slice(at(nl) + 1)), false) }
        var cut = (0..<chars.count).first { visible[$0] >= headingMax && chars[$0] != nil } ?? 0
        var i = cut
        while i > 0 {
            if chars[i] == " " || chars[i] == "\n" { cut = i; break }
            i -= 1
        }
        let end = at(cut)
        return ("\(t(slice(0, end)))…", "…\(t(slice(end)))", true)
    }

    /// The display heading for a title: the heading without file tokens.
    public static func plainHeading(_ title: String) -> String {
        var out = ""
        for part in splitInlineFiles(split(title).heading) { if case .text(let t) = part { out += t } }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A task link inside the popup (`task:<id>`, or the CRM's `/tasks?task=<id>`), as the id it names.
    public static func linkedTaskId(_ href: String) -> String? {
        if href.hasPrefix("task:") { return String(href.dropFirst(5)).removingPercentEncoding }
        guard href.hasPrefix("/tasks"), let range = href.range(of: "task=") else { return nil }
        let before = href[..<range.lowerBound].last
        guard before == "?" || before == "&" else { return nil }
        let value = href[range.upperBound...].prefix { $0 != "&" && $0 != "#" }
        return value.isEmpty ? nil : String(value).removingPercentEncoding
    }

    /// Labels: trimmed, spaces collapsed, at most 40 characters, case-insensitively once, at most 20.
    public static func normalizeLabels(_ input: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for x in input {
            let t = String(x.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(40))
            if t.isEmpty || seen.contains(t.lowercased()) { continue }
            seen.insert(t.lowercased())
            out.append(t)
            if out.count >= 20 { break }
        }
        return out
    }

    /// The status pill's word.
    public static func statusWord(_ status: String) -> String {
        switch status {
        case "To-Do": "TO DO"
        case "Working on it": "WORKING ON IT"
        case "In Progress": "IN PROGRESS"
        case "Done": "DONE"
        case "Stuck": "STUCK"
        default: status.uppercased()
        }
    }

    public static func boardLabel(_ board: String) -> String {
        board.trimmingCharacters(in: .whitespaces).isEmpty ? "No board" : board
    }

    public static let statuses = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"]
    public static let priorities = ["Low", "Medium", "High", "Critical"]

    /// The ▸ beside the status pill: the CRM's flow; Stuck → In Progress.
    public static func nextStatus(_ status: String) -> String? {
        if status == "Stuck" { return "In Progress" }
        let flow = ["To-Do", "Working on it", "In Progress", "Done"]
        guard let i = flow.firstIndex(of: status), i < flow.count - 1 else { return nil }
        return flow[i + 1]
    }
}

// MARK: - Files (task-rules.ts, attachment-rules.ts)

public enum CrmFiles {
    public static let maxUploadBytes = 25 * 1024 * 1024
    static let allowed: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "csv", "ppt", "pptx", "txt", "rtf", "odt", "ods", "odp", "md",
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
        "mp3", "m4a", "wav", "ogg", "mp4", "mov", "webm", "zip",
    ]
    static let images: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff"]

    public static func fileExtension(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = n.lastIndex(of: "."), dot != n.startIndex, n.index(after: dot) != n.endIndex else { return "" }
        return n[n.index(after: dot)...].lowercased()
    }

    /// The upload rule: a name, not empty, at most 25 MB, a known kind of file.
    public static func checkUpload(name: String, size: Int) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "The file has no name." }
        if size <= 0 { return "The file is empty." }
        if size > maxUploadBytes { return "“\(n)” is too big — the limit is 25 MB." }
        let ext = fileExtension(n)
        if ext.isEmpty { return "“\(n)” has no file extension, so its type cannot be checked." }
        if !allowed.contains(ext) { return ".\(ext) files cannot be attached to a task. Documents, images, recordings and zips can." }
        return nil
    }

    public static func isImage(mime: String?, fileName: String) -> Bool {
        if let mime, mime.lowercased().hasPrefix("image/") { return true }
        return images.contains(fileExtension(fileName))
    }

    public static func href(taskId: String, attachmentId: String, download: Bool = false) -> String {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.!~*'()"))) ?? s }
        let base = "task-file:\(enc(taskId))/\(enc(attachmentId))"
        return download ? "\(base)?download=1" : base
    }

    public static func parseHref(_ href: String) -> (taskId: String, attachmentId: String)? {
        guard href.hasPrefix("task-file:") else { return nil }
        let path = href.dropFirst("task-file:".count).split(separator: "?", maxSplits: 1).first ?? ""
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map { String($0).removingPercentEncoding ?? String($0) }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// "1.2 MB", "340 KB".
    public static func sizeLabel(_ bytes: Double?) -> String {
        guard let bytes, bytes > 0 else { return "" }
        if bytes >= 1024 * 1024 { return String(format: "%.1f MB", bytes / (1024 * 1024)) }
        if bytes >= 1024 { return "\(Int((bytes / 1024).rounded())) KB" }
        return "\(Int(bytes)) B"
    }
}

// MARK: - Time (local-time.ts, task-rules.ts, task-page.ts)

public enum CrmTime {
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    /// Milliseconds as an ISO time.
    public static func iso(_ ms: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// An ISO time (with or without fractions), or a plain day, as a date.
    public static func date(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: iso) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: iso) { return d }
        if TaskList.isYmd(iso) {
            let p = iso.split(separator: "-").compactMap { Int($0) }
            return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
        }
        return nil
    }

    struct Parts { let y, m, d, weekday, hh, mm: Int; let ymd: String }

    static func parts(_ date: Date) -> Parts {
        let c = Calendar.current.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let ymd = String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
        return Parts(y: c.year ?? 1970, m: c.month ?? 1, d: c.day ?? 1, weekday: (c.weekday ?? 1) - 1, hh: c.hour ?? 0,
                     mm: c.minute ?? 0, ymd: ymd)
    }

    /// "3:05 pm" (or "3:05 PM").
    public static func clock(_ date: Date, upper: Bool = false) -> String {
        let p = parts(date)
        let s = "\(p.hh % 12 == 0 ? 12 : p.hh % 12):\(String(format: "%02d", p.mm)) \(p.hh < 12 ? "am" : "pm")"
        return upper ? s.uppercased() : s
    }

    /// "09:30" → "9:30 am".
    public static func hmLabel(_ hm: String?) -> String {
        guard let hm, hm.count >= 5 else { return "" }
        let p = hm.prefix(5).split(separator: ":").compactMap { Int($0) }
        guard p.count == 2 else { return "" }
        return "\(p[0] % 12 == 0 ? 12 : p[0] % 12):\(String(format: "%02d", p[1])) \(p[0] < 12 ? "am" : "pm")"
    }

    public static func todayYmd(_ now: Date = Date()) -> String { parts(now).ymd }

    public static func quickDates(_ now: Date = Date()) -> (today: String, tomorrow: String, nextMonday: String, twoWeeks: String) {
        let today = todayYmd(now)
        let toMonday = (8 - TaskList.ymdWeekday(today)) % 7
        return (today, TaskList.ymdAddDays(today, 1), TaskList.ymdAddDays(today, toMonday == 0 ? 7 : toMonday),
                TaskList.ymdAddDays(today, 14))
    }

    /// The feed's time: "Just now", "5 mins", "3 hours", "Yesterday at 9:05 am", "Sep 3 at …", "Sep 3, 2025".
    public static func activityTime(_ iso: String, now: Date = Date()) -> String {
        guard let date = date(iso) else { return "" }
        let ms = date.timeIntervalSince1970 * 1000
        let s = max(0, Int(((now.timeIntervalSince1970 * 1000 - ms) / 1000).rounded()))
        if s < 60 { return "Just now" }
        let m = Int((Double(s) / 60).rounded())
        if m < 60 { return "\(m) min\(m == 1 ? "" : "s")" }
        let h = Int((Double(m) / 60).rounded())
        let startToday = Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000
        if ms >= startToday { return "\(h) hour\(h == 1 ? "" : "s")" }
        if ms >= startToday - 86_400_000 { return "Yesterday at \(clock(date))" }
        let t = parts(date)
        if t.y == parts(now).y { return "\(months[t.m - 1]) \(t.d) at \(clock(date))" }
        return "\(months[t.m - 1]) \(t.d), \(t.y)"
    }

    /// "Sep 3 at 9:05 am".
    public static func stamp(_ iso: String) -> String {
        guard let date = date(iso) else { return "" }
        let t = parts(date)
        return "\(months[t.m - 1]) \(t.d) at \(clock(date))"
    }

    /// "Sep 3".
    public static func monthDay(_ iso: String) -> String {
        guard let date = date(iso) else { return "" }
        let t = parts(date)
        return "\(months[t.m - 1]) \(t.d)"
    }

    public static func ymdMonthDay(_ ymd: String) -> String {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), p[2] > 0 else { return "" }
        return "\(months[p[1] - 1]) \(p[2])"
    }

    /// "1h 30m", "45m", "2h", "0h".
    public static func duration(_ seconds: Double) -> String {
        let mins = Int(max(0, seconds) / 60)
        let h = mins / 60, m = mins % 60
        if h > 0 && m > 0 { return "\(h)h \(m)m" }
        if h > 0 { return "\(h)h" }
        if m > 0 { return "\(m)m" }
        return "0h"
    }

    /// "1:05:09".
    public static func clockDuration(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return "\(s / 3600):\(String(format: "%02d", (s % 3600) / 60)):\(String(format: "%02d", s % 60))"
    }

    /// "1:30", "90", "1.5h", "2h 15m", "45m" → seconds; nil when not a time (or over a day).
    public static func parseDuration(_ input: String) -> Double? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if s.isEmpty { return nil }
        var secs: Double?
        if let m = s.wholeMatch(of: /(\d{1,2}):(\d{2})/) {
            secs = (Double(m.1) ?? 0) * 3600 + (Double(m.2) ?? 0) * 60
        } else if let m = s.wholeMatch(of: /(\d+(?:\.\d+)?)/) {
            secs = ((Double(m.1) ?? 0) * 60).rounded()
        } else if let m = s.wholeMatch(of: /(?:(\d+(?:\.\d+)?)\s*h(?:ours?|rs?)?)?\s*(?:(\d+)\s*m?(?:in(?:ute)?s?)?)?/),
                  m.1 != nil || m.2 != nil {
            secs = ((Double(m.1 ?? "0") ?? 0) * 3600).rounded() + (Double(m.2 ?? "0") ?? 0) * 60
        }
        guard let secs, secs.isFinite, secs > 0, secs <= 24 * 3600 else { return nil }
        return secs
    }

    /// Seconds tracked, a running entry counted up to now.
    public static func totalTracked(_ entries: [TimeEntry], now: Date = Date()) -> Double {
        entries.reduce(0) { total, e in
            if let seconds = e.seconds { return total + seconds }
            if e.endedAt == nil, let start = date(e.startedAt) { return total + max(0, (now.timeIntervalSince(start)).rounded(.down)) }
            return total
        }
    }
}

// MARK: - Comments (task-comments.ts)

public enum CrmComments {
    public static let reactions = ["👍", "❤️", "😂", "🎉", "👀", "🙏", "✅", "🔥"]

    /// A scheduled comment not delivered yet.
    public static func isPending(_ meta: CommentMeta?, now: Date = Date()) -> Bool {
        guard let meta, let scheduled = meta.scheduledFor, meta.withdrawn == nil else { return false }
        if let delivered = meta.deliveredAt { return delivered == nil }
        return (CrmTime.date(scheduled)?.timeIntervalSince(now) ?? 0) > 0
    }

    /// A pending comment is only its author's.
    public static func visible(_ comment: TaskComment, _ meta: CommentMeta?, viewer: String, now: Date = Date()) -> Bool {
        !isPending(meta, now: now) || comment.authorUserId == viewer
    }

    /// Top-level comments, and the replies under each.
    public static func thread(_ comments: [TaskComment], meta: [String: CommentMeta]) -> (top: [TaskComment], replies: [String: [TaskComment]]) {
        let ids = Set(comments.map(\.id))
        var top: [TaskComment] = []
        var replies: [String: [TaskComment]] = [:]
        for c in comments {
            if let parent = meta[c.id]?.parentId, ids.contains(parent) {
                replies[parent, default: []].append(c)
            } else {
                top.append(c)
            }
        }
        return (top, replies)
    }

    /// "Send later" choices: in 20 minutes, in 2 hours, tomorrow, in 2 days, next week (8 am).
    public static func schedulePresets(now: Date = Date()) -> [(key: String, label: String, at: Date, hint: String)] {
        let today = CrmTime.todayYmd(now)
        func day(_ n: Int) -> Date {
            let p = TaskList.ymdAddDays(today, n).split(separator: "-").compactMap { Int($0) }
            return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 8)) ?? now
        }
        let toMonday = (8 - TaskList.ymdWeekday(today)) % 7
        let presets: [(String, String, Date)] = [
            ("20m", "In 20 minutes", now.addingTimeInterval(20 * 60)),
            ("2h", "In 2 hours", now.addingTimeInterval(2 * 3600)),
            ("tomorrow", "Tomorrow", day(1)),
            ("2d", "In 2 days", day(2)),
            ("next-week", "Next week", day(toMonday == 0 ? 7 : toMonday)),
        ]
        return presets.map { key, label, at in
            let hint = key == "20m" || key == "2h" ? CrmTime.clock(at, upper: true)
                : "\(CrmTime.days[CrmTime.parts(at).weekday]), \(CrmTime.clock(at, upper: true))"
            return (key, label, at, hint)
        }
    }

    /// "Today at 3:05 PM", "Tomorrow at …", "Wed, Sep 3 at …".
    public static func formatScheduled(_ iso: String, now: Date = Date()) -> String {
        guard let date = CrmTime.date(iso) else { return "" }
        let p = CrmTime.parts(date)
        let diff = TaskList.ymdDiff(CrmTime.todayYmd(now), p.ymd)
        let when = diff == 0 ? "Today" : diff == 1 ? "Tomorrow" : "\(CrmTime.days[p.weekday]), \(CrmTime.months[p.m - 1]) \(p.d)"
        return "\(when) at \(CrmTime.clock(date, upper: true))"
    }
}
