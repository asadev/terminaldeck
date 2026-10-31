import Foundation

// MARK: - Shapes

/// Terminal Deck's own states, never a CRM status.
public enum ProcessState: String, Equatable, Sendable {
    case queued, running, exited, idle
}

/// Taking work, paused (no new work), or archived (kept, offered nowhere).
public enum AgentStatus: String, Equatable, Sendable, CaseIterable {
    case active, paused, archived
}

/// What the lifecycle buttons send.
public enum AgentAction: String, Equatable, Sendable {
    case pause, resume, archive, restore
}

public struct AgentProfile: Equatable, Sendable, Identifiable {
    public var projectID: String
    public var projectId: String { projectID }
    public var hasExplicitProjectID: Bool
    public var id: String
    public var name: String
    public var role: String
    /// Which coding agent runs it; nil for the app's default.
    public var provider: String?
    public var account: String?
    public var model: String?
    /// One of `EFFORT_CHOICES`; nil leaves the agent's own.
    public var effort: String?
    /// Standing instructions, read from the agent's own file.
    public var instructions: String?
    public var instructionsFile: String?
    /// Asked of the agent in its brief — a preference, not an enforcement.
    public var toolsPreferred: [String]
    public var toolsAvoided: [String]
    public var skills: [String]
    /// Refused by Claude Code itself (`--disallowedTools`).
    public var blockedTools: [String]
    public var skillsOff: Bool
    public var maxConcurrent: Int
    /// 0: no limit.
    public var maxRunMinutes: Int
    /// 0: closed at once.
    public var keepAliveMinutes: Int
    /// Nil: Hoot checks the result.
    public var verifyCommand: String?
    public var status: AgentStatus
    public var statusAt: Double?
    public var claudeAgent: String?
    /// Nil uses Claude Code's tools; an empty list allows no tools.
    public var allowedTools: [String]?
    public var permissionMode: String?
    public var keepAliveUntilClose: Bool?
    public var defaultProject: String?
    public var reviewerAgent: String?
    public var sourceFile: String?
    public var sourceDirectory: String?
    public var syncedAt: Double?
    public var syncStatus: String?
    public var syncError: String?
    /// AGT: the agent's picture (`sf:<symbol>` or `emoji:<emoji>`); nil picks one from its role.
    public var icon: String?
    /// AGT: the profile id it reports to, `@hoot`, or nil (independent).
    public var reportsTo: String?
    /// Deck Memory: the role (seat) this agent was hired into, a slug; nil = the seat named after its own id.
    /// Memory belongs to the seat, so a new hire with the same `seat` in the same project inherits it.
    public var toolUseRestrictions: NativeRPCValue?
    public var seat: String?

    public init(id: String, name: String, role: String = "general", provider: String? = nil, account: String? = nil,
                model: String? = nil, effort: String? = nil, instructions: String? = nil, instructionsFile: String? = nil,
                toolsPreferred: [String] = [], toolsAvoided: [String] = [], skills: [String] = [], blockedTools: [String] = [],
                skillsOff: Bool = false, maxConcurrent: Int = 0, maxRunMinutes: Int = TasksLimits.defaultRunMinutes,
                keepAliveMinutes: Int = TasksLimits.defaultKeepAliveMinutes, verifyCommand: String? = nil,
                status: AgentStatus = .active, statusAt: Double? = nil,
                claudeAgent: String? = nil, allowedTools: [String]? = nil, permissionMode: String? = nil,
                keepAliveUntilClose: Bool? = nil, defaultProject: String? = nil, reviewerAgent: String? = nil,
                sourceFile: String? = nil, sourceDirectory: String? = nil, syncedAt: Double? = nil,
                syncStatus: String? = nil, syncError: String? = nil, icon: String? = nil, reportsTo: String? = nil, projectID: String? = nil,
                projectIdInferred: Bool = false, seat: String? = nil, toolUseRestrictions: NativeRPCValue? = nil) {
        self.projectID = PROJProjects.resolve(projectID: projectID, folder: sourceDirectory ?? sourceFile ?? defaultProject)
        self.hasExplicitProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && !projectIdInferred
        self.icon = icon
        self.reportsTo = reportsTo
        self.toolUseRestrictions = toolUseRestrictions
        self.seat = seat
        self.id = id
        self.name = name
        self.role = role
        self.provider = provider
        self.account = account
        self.model = model
        self.effort = effort
        self.instructions = instructions
        self.instructionsFile = instructionsFile
        self.toolsPreferred = toolsPreferred
        self.toolsAvoided = toolsAvoided
        self.skills = skills
        self.blockedTools = blockedTools
        self.skillsOff = skillsOff
        self.maxConcurrent = maxConcurrent
        self.maxRunMinutes = maxRunMinutes
        self.keepAliveMinutes = keepAliveMinutes
        self.verifyCommand = verifyCommand
        self.status = status
        self.statusAt = statusAt
        self.claudeAgent = claudeAgent
        self.allowedTools = allowedTools
        self.permissionMode = permissionMode
        self.keepAliveUntilClose = keepAliveUntilClose
        self.defaultProject = defaultProject
        self.reviewerAgent = reviewerAgent
        self.sourceFile = sourceFile
        self.sourceDirectory = sourceDirectory
        self.syncedAt = syncedAt
        self.syncStatus = syncStatus
        self.syncError = syncError
    }

    /// As `tasks:agent-save` takes it.
    public var wire: [String: Any] {
        [
            "id": id, "name": name, "role": role, "projectId": projectID,
            "projectIdInferred": !hasExplicitProjectID && PROJProjects.resolve(projectID: nil, folder: sourceDirectory ?? sourceFile ?? defaultProject) == PROJProjects.independentID,
            "provider": orNullValue(provider), "account": orNullValue(account), "model": orNullValue(model),
            "effort": orNullValue(effort), "instructions": orNullValue(instructions),
            "instructionsFile": orNullValue(instructionsFile),
            "toolsPreferred": toolsPreferred, "toolsAvoided": toolsAvoided, "skills": skills,
            "blockedTools": blockedTools, "skillsOff": skillsOff,
            "maxConcurrent": maxConcurrent, "maxRunMinutes": maxRunMinutes, "keepAliveMinutes": keepAliveMinutes,
            "verifyCommand": orNullValue(verifyCommand), "status": status.rawValue, "statusAt": orNullValue(statusAt),
            "claudeAgent": orNullValue(claudeAgent), "allowedTools": allowedTools.map { $0 as Any } ?? jsonNull,
            "permissionMode": orNullValue(permissionMode), "keepAliveUntilClose": keepAliveUntilClose.map { $0 as Any } ?? jsonNull,
            "defaultProject": orNullValue(defaultProject), "reviewerAgent": orNullValue(reviewerAgent),
            "sourceFile": orNullValue(sourceFile), "sourceDirectory": orNullValue(sourceDirectory),
            "syncedAt": orNullValue(syncedAt), "syncStatus": orNullValue(syncStatus), "syncError": orNullValue(syncError),
            "toolUseRestrictions": toolUseRestrictions?.foundation ?? jsonNull,
            "icon": orNullValue(icon), "reportsTo": orNullValue(reportsTo), "seat": orNullValue(seat),
        ]
    }
}

public struct StatusConfig: Equatable, Sendable {
    public var statuses: [String]
    public var initial: String
    public var completed: String
    public var onStarted: String?
    public var onVerified: String?
    public var onBlocked: String?

    public init(statuses: [String], initial: String, completed: String, onStarted: String?, onVerified: String?, onBlocked: String?) {
        self.statuses = statuses
        self.initial = initial
        self.completed = completed
        self.onStarted = onStarted
        self.onVerified = onVerified
        self.onBlocked = onBlocked
    }

    public var wire: [String: Any] {
        ["statuses": statuses, "initial": initial, "completed": completed,
         "onStarted": orNullValue(onStarted), "onVerified": orNullValue(onVerified), "onBlocked": orNullValue(onBlocked)]
    }
}

public struct CrmConnection: Equatable, Sendable, Identifiable {
    public var keyId: String
    /// The owner's name for this CRM; nil on one made before names.
    public var name: String?
    public var enabled: Bool
    public var eventsUrl: String?
    public var hasEventsSecret: Bool
    public var statuses: StatusConfig
    public var hootIdentity: String?
    /// CRM identity → agent id.
    public var identities: [String: String]
    /// The identities in the order the engine sent them (a dictionary has none).
    public var identityOrder: [String]
    public var allowedSenders: [String]
    public var folders: [String]
    public var maxHops: Int
    public var projectID: String = PROJProjects.independentID
    public var projectId: String { projectID }
    public var id: String { keyId }
}

public struct TaskStall: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable { case quiet, exited }
    public var at: Double
    public var reason: Reason
    public var text: String
}

public struct TaskNote: Equatable, Sendable {
    public var at: Double
    public var by: String
    public var kind: String
    public var text: String
}

public struct TaskRow: Equatable, Sendable, Identifiable {
    public var projectID: String
    public var projectId: String { projectID }
    public var hasExplicitProjectID: Bool
    public var id: String
    public var keyId: String
    public var externalTaskId: String
    public var title: String
    /// The agent's name, or Hoot.
    public var agent: String
    public var project: String
    public var crmStatus: String
    public var process: ProcessState
    public var keepOpenUntil: Double?
    public var keepAliveUntilClose: Bool?
    public var parentTaskId: String?
    public var parentExternalTaskId: String?
    public var reviewerTaskId: String?
    public var reviewOfTaskId: String?
    public var verified: Bool?
    public var updatedAt: Double
    /// Made here, with no CRM: editable on the Tasks page.
    public var local: Bool
    /// `none`, `me`, `hoot`, or an agent's id.
    public var assignee: String
    public var instructions: String
    /// The agent that handed it to you, while you have it.
    public var handedFrom: String?
    public var notes: [TaskNote]
    public var priority: String?
    public var startDate: String?
    public var dueDate: String?
    public var startTime: String?
    public var dueTime: String?
    public var labels: [String]
    public var board: String?
    /// `task` or `milestone`.
    public var taskType: String
    public var estimateMinutes: Double?
    public var archivedAt: Double?
    public var deletedAt: Double?
    public var completedAt: Double?
    public var position: Double?
    public var recurrence: String?
    public var goalId: String?
    public var useWorkspace: Bool
    public var stalled: TaskStall?
    public var waitingOn: [String]
    public var createdAt: Double

    public init(id: String, keyId: String = "", externalTaskId: String = "", title: String = "Untitled task",
                agent: String = "Hoot", project: String = "", crmStatus: String = "", process: ProcessState = .queued,
                keepOpenUntil: Double? = nil, verified: Bool? = nil, updatedAt: Double = 0, local: Bool = false,
                assignee: String = "none", instructions: String = "", handedFrom: String? = nil, notes: [TaskNote] = [],
                priority: String? = nil, startDate: String? = nil, dueDate: String? = nil, startTime: String? = nil,
                dueTime: String? = nil, labels: [String] = [], board: String? = nil, taskType: String = "task",
                estimateMinutes: Double? = nil, archivedAt: Double? = nil, deletedAt: Double? = nil,
                completedAt: Double? = nil, position: Double? = nil, recurrence: String? = nil, goalId: String? = nil,
                useWorkspace: Bool = false, stalled: TaskStall? = nil, waitingOn: [String] = [], createdAt: Double = 0,
                keepAliveUntilClose: Bool? = nil, parentTaskId: String? = nil, parentExternalTaskId: String? = nil,
                reviewerTaskId: String? = nil, reviewOfTaskId: String? = nil, projectID: String? = nil) {
        self.id = id
        self.keyId = keyId
        self.externalTaskId = externalTaskId
        self.projectID = PROJProjects.resolve(projectID: projectID, folder: project)
        self.hasExplicitProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        self.title = title
        self.agent = agent
        self.project = project
        self.crmStatus = crmStatus
        self.process = process
        self.keepOpenUntil = keepOpenUntil
        self.keepAliveUntilClose = keepAliveUntilClose
        self.parentTaskId = parentTaskId
        self.parentExternalTaskId = parentExternalTaskId
        self.reviewerTaskId = reviewerTaskId
        self.reviewOfTaskId = reviewOfTaskId
        self.verified = verified
        self.updatedAt = updatedAt
        self.local = local
        self.assignee = assignee
        self.instructions = instructions
        self.handedFrom = handedFrom
        self.notes = notes
        self.priority = priority
        self.startDate = startDate
        self.dueDate = dueDate
        self.startTime = startTime
        self.dueTime = dueTime
        self.labels = labels
        self.board = board
        self.taskType = taskType
        self.estimateMinutes = estimateMinutes
        self.archivedAt = archivedAt
        self.deletedAt = deletedAt
        self.completedAt = completedAt
        self.position = position
        self.recurrence = recurrence
        self.goalId = goalId
        self.useWorkspace = useWorkspace
        self.stalled = stalled
        self.waitingOn = waitingOn
        self.createdAt = createdAt
    }
}

public enum GoalStatus: String, Equatable, Sendable, CaseIterable {
    case planned, active, achieved, cancelled

    public var label: String {
        switch self {
        case .planned: "Planned"
        case .active: "Active"
        case .achieved: "Achieved"
        case .cancelled: "Cancelled"
        }
    }
}

public struct GoalProgress: Equatable, Sendable {
    public var total: Int
    public var done: Int
    public var verified: Int
    public var unverified: Int
    public var stalled: Int
    public var blocked: Int

    public init(total: Int = 0, done: Int = 0, verified: Int = 0, unverified: Int = 0, stalled: Int = 0, blocked: Int = 0) {
        self.total = total
        self.done = done
        self.verified = verified
        self.unverified = unverified
        self.stalled = stalled
        self.blocked = blocked
    }
}

/// One goal, and how far its tasks — its sub-goals' included — have got.
public struct GoalRow: Equatable, Sendable, Identifiable {
    public var projectID: String
    public var projectId: String { projectID }
    public var hasExplicitProjectID: Bool
    public var id: String
    public var title: String
    public var description: String
    public var status: GoalStatus
    public var parentId: String?
    public var project: String?
    public var progress: GoalProgress

    public init(id: String, title: String, description: String = "", status: GoalStatus = .active,
                parentId: String? = nil, project: String? = nil, progress: GoalProgress = GoalProgress(), projectID: String? = nil) {
        self.id = id
        self.title = title
        self.description = description
        self.projectID = PROJProjects.resolve(projectID: projectID, folder: project)
        self.hasExplicitProjectID = projectID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        self.status = status
        self.parentId = parentId
        self.project = project
        self.progress = progress
    }
}

/// An access key as the CRM picker sees it.
public struct TasksKey: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var crmOnly: Bool
    public var lastApp: String?
}

public struct TasksState: Equatable, Sendable {
    public var agents: [AgentProfile]
    public var connections: [CrmConnection]
    public var keys: [TasksKey]
    public var tasks: [TaskRow]
    /// Your deleted tasks, newest first — kept whole until restored.
    public var trash: [TaskRow]
    public var outbox: (pending: Int, undelivered: Int)
    /// The statuses a local task can have.
    public var localStatuses: [String]
    /// Your goals, oldest first.
    public var goals: [GoalRow]

    public init(agents: [AgentProfile] = [], connections: [CrmConnection] = [], keys: [TasksKey] = [], tasks: [TaskRow] = [],
                trash: [TaskRow] = [], outbox: (pending: Int, undelivered: Int) = (0, 0),
                localStatuses: [String] = DEFAULT_CRM_STATUSES.statuses, goals: [GoalRow] = []) {
        self.agents = agents
        self.connections = connections
        self.keys = keys
        self.tasks = tasks
        self.trash = trash
        self.outbox = outbox
        self.localStatuses = localStatuses
        self.goals = goals
    }

    public static func == (lhs: TasksState, rhs: TasksState) -> Bool {
        lhs.agents == rhs.agents && lhs.connections == rhs.connections && lhs.keys == rhs.keys && lhs.tasks == rhs.tasks
            && lhs.trash == rhs.trash && lhs.outbox.pending == rhs.outbox.pending
            && lhs.outbox.undelivered == rhs.outbox.undelivered && lhs.localStatuses == rhs.localStatuses
            && lhs.goals == rhs.goals
    }
}

public struct TasksResult: Equatable, Sendable {
    public var ok: Bool
    public var message: String?
    public var state: TasksState?
    /// A new signing secret, on the one answer that made it. Shown once.
    public var secret: String?
    /// A new CRM's own access key, on the one answer that made it. Shown once.
    public var key: String?

    public init(ok: Bool, message: String?, state: TasksState? = nil, secret: String? = nil, key: String? = nil) {
        self.ok = ok
        self.message = message
        self.state = state
        self.secret = secret
        self.key = key
    }

    public static func refused(_ message: String) -> TasksResult { TasksResult(ok: false, message: message) }
}

/// One thing a picker offers.
public struct InventoryChoice: Equatable, Sendable, Hashable {
    public var value: String
    public var label: String
    public var `where`: String
}

/// What is installed for an agent's Claude Code account.
public struct AgentInventory: Equatable, Sendable {
    public var account: String
    public var tools: [InventoryChoice]
    public var skills: [InventoryChoice]
}
