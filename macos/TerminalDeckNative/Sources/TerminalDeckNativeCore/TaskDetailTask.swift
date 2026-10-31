import Foundation

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
