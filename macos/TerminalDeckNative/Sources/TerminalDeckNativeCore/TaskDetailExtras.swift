import Foundation

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
