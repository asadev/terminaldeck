import Foundation

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
