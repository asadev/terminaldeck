import Foundation

// Tasks, as the window reads them: the agents, the connections, your own tasks,
// the read-only mirror of a CRM's work, and your goals. A port of
// src/renderer/tasks/tasks-model.ts, read field by field from what the engine
// answers (never cast), so a malformed answer reads as nothing rather than a guess.
//
// Two words are kept apart on purpose. A **status** belongs to the CRM and is
// shown exactly as the CRM spells it. Queued, running and exited are this app's
// own **process states**; they are never called a status anywhere on screen.

// MARK: - Reading the engine's answers

/// Readers over the Foundation objects a JSON answer arrives as. Strict about type:
/// a JavaScript boolean is never a number here, nor a number a boolean.
public enum TasksJSON {
    public static func record(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    /// A non-empty string, else nil (the page's `text`).
    public static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// A finite number (not a boolean).
    public static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    public static func count(_ value: Any?, _ fallback: Double) -> Double { number(value) ?? fallback }

    public static func int(_ value: Any?, _ fallback: Int) -> Int {
        guard let double = number(value), abs(double) < 1e15 else { return fallback }
        return Int(double)
    }

    public static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    public static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    /// Only a literal `true`.
    public static func isTrue(_ value: Any?) -> Bool { bool(value) == true }
}

/// A JSON null for payloads.
var jsonNull: Any { NSNull() }
func orNullValue(_ value: String?) -> Any { value.map { $0 as Any } ?? jsonNull }
func orNullValue(_ value: Double?) -> Any { value.map { $0 as Any } ?? jsonNull }

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

    public init(id: String, name: String, role: String = "general", provider: String? = nil, account: String? = nil,
                model: String? = nil, effort: String? = nil, instructions: String? = nil, instructionsFile: String? = nil,
                toolsPreferred: [String] = [], toolsAvoided: [String] = [], skills: [String] = [], blockedTools: [String] = [],
                skillsOff: Bool = false, maxConcurrent: Int = 1, maxRunMinutes: Int = TasksLimits.defaultRunMinutes,
                keepAliveMinutes: Int = TasksLimits.defaultKeepAliveMinutes, verifyCommand: String? = nil,
                status: AgentStatus = .active, statusAt: Double? = nil,
                claudeAgent: String? = nil, allowedTools: [String]? = nil, permissionMode: String? = nil,
                keepAliveUntilClose: Bool? = nil, defaultProject: String? = nil, reviewerAgent: String? = nil,
                sourceFile: String? = nil, sourceDirectory: String? = nil, syncedAt: Double? = nil,
                syncStatus: String? = nil, syncError: String? = nil) {
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
            "id": id, "name": name, "role": role,
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
                reviewerTaskId: String? = nil, reviewOfTaskId: String? = nil) {
        self.id = id
        self.keyId = keyId
        self.externalTaskId = externalTaskId
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
    public var id: String
    public var title: String
    public var description: String
    public var status: GoalStatus
    public var parentId: String?
    public var project: String?
    public var progress: GoalProgress

    public init(id: String, title: String, description: String = "", status: GoalStatus = .active,
                parentId: String? = nil, project: String? = nil, progress: GoalProgress = GoalProgress()) {
        self.id = id
        self.title = title
        self.description = description
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

// MARK: - Limits and fixed lists

/// The main process's own limits (`task-config.ts`), so a form can say them first.
public enum TasksLimits {
    public static let maxAgents = 50
    public static let maxConcurrent = 5
    public static let maxMinutes = 24 * 60
    public static let defaultRunMinutes = 60
    public static let defaultKeepAliveMinutes = 30
    public static let maxHops = 5
    public static let defaultHops = 3
    /// The longest instructions file the main process saves.
    public static let maxInstructionsChars = 32_000
}

/// The effort levels a session's own control takes, and the label each shows.
public let EFFORT_CHOICES: [(id: String, label: String)] = [
    ("low", "Low"), ("medium", "Medium"), ("high", "High"), ("xhigh", "Extra high"),
    ("max", "Max"), ("ultracode", "Ultracode"), ("auto", "Auto"),
]

/// The reference CRM's five statuses, which a new connection starts with.
public let DEFAULT_CRM_STATUSES = StatusConfig(
    statuses: ["To-Do", "Working on it", "In Progress", "Done", "Stuck"],
    initial: "To-Do", completed: "Done", onStarted: "Working on it", onVerified: "Done", onBlocked: "Stuck")

/// The assistant's name (`BRAND.assistant`).
public let BRAND_ASSISTANT = "Hoot"

// MARK: - Decoding

public enum TasksDecode {
    private typealias J = TasksJSON

    public static func inventory(_ raw: Any?) -> AgentInventory? {
        guard let r = J.record(raw), let tools = r["tools"] as? [Any], let skills = r["skills"] as? [Any] else { return nil }
        func choices(_ list: [Any]) -> [InventoryChoice] {
            list.compactMap { entry in
                let e = J.record(entry)
                guard let value = J.text(e?["value"]) else { return nil }
                return InventoryChoice(value: value, label: J.text(e?["label"]) ?? value, where: J.text(e?["where"]) ?? "")
            }
        }
        return AgentInventory(account: J.text(r["account"]) ?? "Default", tools: choices(tools), skills: choices(skills))
    }

    static func agent(_ raw: Any?) -> AgentProfile? {
        guard let r = J.record(raw), let id = J.text(r["id"]), let name = J.text(r["name"]) else { return nil }
        let status: AgentStatus
        if r["status"] == nil {
            status = .active
        } else if let raw = r["status"] as? String, let known = AgentStatus(rawValue: raw) {
            status = known
        } else {
            // Never guessed into taking work: a status this build does not know reads as paused.
            status = .paused
        }
        return AgentProfile(
            id: id, name: name, role: J.text(r["role"]) ?? "general", provider: J.text(r["provider"]),
            account: J.text(r["account"]), model: J.text(r["model"]), effort: J.text(r["effort"]),
            instructions: J.text(r["instructions"]), instructionsFile: J.text(r["instructionsFile"]),
            toolsPreferred: J.strings(r["toolsPreferred"]), toolsAvoided: J.strings(r["toolsAvoided"]),
            skills: J.strings(r["skills"]), blockedTools: J.strings(r["blockedTools"]), skillsOff: J.isTrue(r["skillsOff"]),
            maxConcurrent: J.int(r["maxConcurrent"], 1), maxRunMinutes: J.int(r["maxRunMinutes"], TasksLimits.defaultRunMinutes),
            keepAliveMinutes: J.int(r["keepAliveMinutes"], TasksLimits.defaultKeepAliveMinutes),
            verifyCommand: J.text(r["verifyCommand"]), status: status, statusAt: J.number(r["statusAt"]),
            claudeAgent: J.text(r["claudeAgent"]), allowedTools: r["allowedTools"] is [Any] ? J.strings(r["allowedTools"]) : nil,
            permissionMode: J.text(r["permissionMode"]), keepAliveUntilClose: J.bool(r["keepAliveUntilClose"]),
            defaultProject: J.text(r["defaultProject"]), reviewerAgent: J.text(r["reviewerAgent"]),
            sourceFile: J.text(r["sourceFile"]), sourceDirectory: J.text(r["sourceDirectory"]), syncedAt: J.number(r["syncedAt"]),
            syncStatus: J.text(r["syncStatus"]), syncError: J.text(r["syncError"]))
    }

    static func statuses(_ raw: Any?) -> StatusConfig {
        let r = J.record(raw)
        let list = J.strings(r?["statuses"])
        guard r != nil, !list.isEmpty else { return DEFAULT_CRM_STATUSES }
        return StatusConfig(statuses: list, initial: J.text(r?["initial"]) ?? list[0],
                            completed: J.text(r?["completed"]) ?? list[list.count - 1],
                            onStarted: J.text(r?["onStarted"]), onVerified: J.text(r?["onVerified"]),
                            onBlocked: J.text(r?["onBlocked"]))
    }

    static func connection(_ raw: Any?) -> CrmConnection? {
        guard let r = J.record(raw), let keyId = J.text(r["keyId"]) else { return nil }
        var identities: [String: String] = [:]
        var order: [String] = []
        if let map = J.record(r["identities"]) {
            for (identity, agentId) in map.sorted(by: { $0.key < $1.key }) {
                if let agentId = agentId as? String {
                    identities[identity] = agentId
                    order.append(identity)
                }
            }
        }
        return CrmConnection(
            keyId: keyId, name: J.text(r["name"]),
            // Only a literal true draws it on: a connection that decides who can run
            // agents here must never be guessed into being switched on.
            enabled: J.isTrue(r["enabled"]), eventsUrl: J.text(r["eventsUrl"]), hasEventsSecret: J.isTrue(r["hasEventsSecret"]),
            statuses: statuses(r["statuses"]), hootIdentity: J.text(r["hootIdentity"]), identities: identities,
            identityOrder: order, allowedSenders: J.strings(r["allowedSenders"]), folders: J.strings(r["folders"]),
            maxHops: J.int(r["maxHops"], TasksLimits.defaultHops))
    }

    static func note(_ raw: Any?) -> TaskNote? {
        guard let r = J.record(raw), let text = r["text"] as? String else { return nil }
        return TaskNote(at: J.count(r["at"], 0), by: J.text(r["by"]) ?? "", kind: J.text(r["kind"]) ?? "progress", text: text)
    }

    static func stall(_ raw: Any?) -> TaskStall? {
        guard let r = J.record(raw), let text = r["text"] as? String else { return nil }
        return TaskStall(at: J.count(r["at"], 0), reason: (r["reason"] as? String) == "exited" ? .exited : .quiet, text: text)
    }

    public static func task(_ raw: Any?) -> TaskRow? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        let process: ProcessState = {
            switch r["process"] as? String {
            case "running": .running
            case "exited": .exited
            case "idle": .idle
            default: .queued
            }
        }()
        return TaskRow(
            id: id, keyId: J.text(r["keyId"]) ?? "", externalTaskId: J.text(r["externalTaskId"]) ?? "",
            title: J.text(r["title"]) ?? "Untitled task", agent: J.text(r["agent"]) ?? BRAND_ASSISTANT,
            project: J.text(r["project"]) ?? "", crmStatus: r["crmStatus"] as? String ?? "", process: process,
            keepOpenUntil: J.number(r["keepOpenUntil"]), verified: J.bool(r["verified"]),
            updatedAt: J.count(r["updatedAt"], 0), local: J.isTrue(r["local"]), assignee: J.text(r["assignee"]) ?? "none",
            instructions: r["instructions"] as? String ?? "", handedFrom: J.text(r["handedFrom"]),
            notes: (r["notes"] as? [Any] ?? []).compactMap(note), priority: J.text(r["priority"]),
            startDate: J.text(r["startDate"]), dueDate: J.text(r["dueDate"]), startTime: J.text(r["startTime"]),
            dueTime: J.text(r["dueTime"]), labels: J.strings(r["labels"]), board: J.text(r["board"]),
            taskType: (r["taskType"] as? String) == "milestone" ? "milestone" : "task",
            estimateMinutes: J.number(r["estimateMinutes"]), archivedAt: J.number(r["archivedAt"]),
            deletedAt: J.number(r["deletedAt"]), completedAt: J.number(r["completedAt"]), position: J.number(r["position"]),
            recurrence: J.text(r["recurrence"]), goalId: J.text(r["goalId"]), useWorkspace: J.isTrue(r["useWorkspace"]),
            stalled: stall(r["stalled"]), waitingOn: J.strings(r["waitingOn"]), createdAt: J.count(r["createdAt"], 0),
            keepAliveUntilClose: J.bool(r["keepAliveUntilClose"]), parentTaskId: J.text(r["parentTaskId"]),
            parentExternalTaskId: J.text(r["parentExternalTaskId"]), reviewerTaskId: J.text(r["reviewerTaskId"]),
            reviewOfTaskId: J.text(r["reviewOfTaskId"]))
    }

    static func goal(_ raw: Any?) -> GoalRow? {
        guard let r = J.record(raw), let id = J.text(r["id"]) else { return nil }
        let p = J.record(r["progress"]) ?? [:]
        let status = (r["status"] as? String).flatMap(GoalStatus.init(rawValue:)) ?? .active
        return GoalRow(
            id: id, title: J.text(r["title"]) ?? "Untitled goal", description: r["description"] as? String ?? "",
            status: status, parentId: J.text(r["parentId"]), project: J.text(r["project"]),
            progress: GoalProgress(total: J.int(p["total"], 0), done: J.int(p["done"], 0), verified: J.int(p["verified"], 0),
                                   unverified: J.int(p["unverified"], 0), stalled: J.int(p["stalled"], 0),
                                   blocked: J.int(p["blocked"], 0)))
    }

    public static func state(_ raw: Any?) -> TasksState? {
        guard let r = J.record(raw), let agents = r["agents"] as? [Any], let connections = r["connections"] as? [Any] else {
            return nil
        }
        let outbox = J.record(r["outbox"]) ?? [:]
        let localStatuses = J.strings(r["localStatuses"])
        return TasksState(
            agents: agents.compactMap(agent),
            connections: connections.compactMap(connection),
            keys: (r["keys"] as? [Any] ?? []).compactMap { key in
                let k = J.record(key)
                guard let id = J.text(k?["id"]) else { return nil }
                return TasksKey(id: id, name: J.text(k?["name"]) ?? id, crmOnly: J.isTrue(k?["crmOnly"]), lastApp: J.text(k?["lastApp"]))
            },
            tasks: (r["tasks"] as? [Any] ?? []).compactMap(task),
            trash: (r["trash"] as? [Any] ?? []).compactMap(task),
            outbox: (J.int(outbox["pending"], 0), J.int(outbox["undelivered"], 0)),
            localStatuses: localStatuses.isEmpty ? DEFAULT_CRM_STATUSES.statuses : localStatuses,
            goals: (r["goals"] as? [Any] ?? []).compactMap(goal))
    }

    public static func result(_ raw: Any?) -> TasksResult {
        let r = J.record(raw)
        let ok = J.isTrue(r?["ok"])
        return TasksResult(
            ok: ok,
            message: J.text(r?["message"]) ?? (ok ? nil : "That did not go through, and the app did not say why."),
            state: state(r?["state"]),
            secret: ok ? J.text(r?["secret"]) : nil,
            key: ok ? J.text(r?["key"]) : nil)
    }
}

// MARK: - Goals

/// A goal while it is being typed.
public struct GoalDraft: Equatable, Sendable {
    public var title: String
    public var description: String
    public var status: GoalStatus
    /// Empty for a top-level goal.
    public var parentId: String

    public init(_ goal: GoalRow?, parentId: String = "") {
        title = goal?.title ?? ""
        description = goal?.description ?? ""
        status = goal?.status ?? .active
        self.parentId = goal?.parentId ?? parentId
    }
}

public enum Goals {
    /// What `tasks:goal-save` is sent, or what to fix first.
    public static func payload(_ draft: GoalDraft, id: String?) -> Result<[String: Any], TasksProblem> {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .failure(TasksProblem("Give the goal a title.")) }
        var payload: [String: Any] = [
            "title": title,
            "description": draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            "status": draft.status.rawValue,
            "parentId": draft.parentId.isEmpty ? jsonNull : draft.parentId,
        ]
        if let id { payload["id"] = id }
        return .success(payload)
    }

    /// Goals in tree order — each followed by the ones under it — with how deep each sits.
    public static func tree(_ goals: [GoalRow]) -> [(goal: GoalRow, depth: Int)] {
        var out: [(goal: GoalRow, depth: Int)] = []
        let ids = Set(goals.map(\.id))
        func visit(_ parentId: String?, _ depth: Int) {
            for goal in goals {
                let parent = goal.parentId.flatMap { ids.contains($0) ? $0 : nil }
                if parent != parentId || out.contains(where: { $0.goal.id == goal.id }) { continue }
                out.append((goal, depth))
                visit(goal.id, depth + 1)
            }
        }
        visit(nil, 0)
        return out
    }

    /// The goals a goal may be put under: any but itself and those under it.
    public static func parentChoices(_ goals: [GoalRow], id: String?) -> [GoalRow] {
        guard let id else { return goals }
        var below: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for goal in goals where goal.parentId.map(below.contains) == true && !below.contains(goal.id) {
                below.insert(goal.id)
                grew = true
            }
        }
        return goals.filter { !below.contains($0.id) }
    }
}

/// A sentence that says what to fix.
public struct TasksProblem: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - The mirror, local tasks, the page's lines

public enum TasksRules {
    /// The mirror shows only once there is something to mirror, or somewhere it would come from.
    public static func showMirror(_ state: TasksState?) -> Bool {
        guard let state else { return false }
        return !state.tasks.isEmpty || !state.connections.isEmpty
    }

    public static func processLabel(_ process: ProcessState) -> String {
        switch process {
        case .idle: ""
        case .running: "Running"
        case .exited: "Finished"
        case .queued: "Queued"
        }
    }

    /// Whole minutes left on a kept-open session, at least 1 while any is left; nil when none.
    public static func keptOpenMinutes(_ keepOpenUntil: Double?, now: Double) -> Int? {
        guard let until = keepOpenUntil, until > now else { return nil }
        return max(1, Int(((until - now) / 60_000).rounded(.up)))
    }

    /// The agents a picker offers: every one but the archived.
    public static func pickableAgents(_ agents: [AgentProfile]) -> [AgentProfile] {
        agents.filter { $0.status != .archived }
    }

    /// Who has a task: nobody, you, Hoot, then every task agent but the archived — a
    /// paused one is offered and says so.
    public static func assigneeChoices(_ agents: [AgentProfile]) -> [(id: String, label: String)] {
        [("none", "Unassigned"), ("me", "Me"), ("hoot", BRAND_ASSISTANT)]
            + pickableAgents(agents).map { ($0.id, $0.status == .paused ? "\($0.name) (paused)" : $0.name) }
    }

    /// Who has a task, as the row says it.
    public static func assigneeLabel(_ task: TaskRow, state: TasksState) -> String {
        assigneeChoices(state.agents).first { $0.id == task.assignee }?.label ?? task.agent
    }

    /// One line on each connection: which key, on or off, and whether it can take work yet.
    public static func connectionLine(_ state: TasksState) -> String? {
        guard !state.connections.isEmpty else { return nil }
        return state.connections.map { connection in
            let key = state.keys.first { $0.id == connection.keyId }?.name ?? "a removed key"
            if !connection.enabled { return "CRM on “\(key)” is off" }
            if connection.allowedSenders.isEmpty || connection.folders.isEmpty {
                return "CRM on “\(key)” is on, but needs an allowed sender and a project folder"
            }
            return "CRM on “\(key)” is on"
        }.joined(separator: " · ")
    }

    /// What has not reached the CRM yet, or nil when everything has.
    public static func outboxLine(_ state: TasksState) -> String? {
        var parts: [String] = []
        if state.outbox.pending > 0 {
            parts.append("\(state.outbox.pending) update\(state.outbox.pending == 1 ? "" : "s") on the way to the CRM")
        }
        if state.outbox.undelivered > 0 { parts.append("\(state.outbox.undelivered) could not be delivered") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The Tasks page's header lines, in order.
    public static func facts(_ state: TasksState) -> [String] {
        let agents = state.agents.count
        return [
            connectionLine(state),
            "\(agents) task agent\(agents == 1 ? "" : "s")\(agents == 0 ? " — add one in Settings to give tasks to an agent" : "")",
            outboxLine(state),
        ].compactMap { $0 }
    }
}

/// A local task while it is being typed.
public struct LocalDraft: Equatable, Sendable {
    public var title: String
    public var instructions: String
    public var project: String
    /// `none`, `me`, `hoot`, or an agent's id.
    public var assignee: String
    public var status: String
    /// The goal it serves; empty for none.
    public var goalId: String

    public init(_ task: TaskRow?, statuses: [String]) {
        title = task?.title ?? ""
        instructions = task?.instructions ?? ""
        project = task?.project ?? ""
        assignee = task?.assignee ?? "none"
        status = task?.crmStatus ?? statuses.first ?? "To-Do"
        goalId = task?.goalId ?? ""
    }

    /// What `tasks:local-create` / `tasks:local-update` is sent, or what to fix first.
    public func payload(agents: [AgentProfile] = []) -> Result<[String: Any], TasksProblem> {
        let title = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return .failure(TasksProblem("Give the task a title.")) }
        var project = self.project.trimmingCharacters(in: .whitespacesAndNewlines)
        let working = assignee != "none" && assignee != "me"
        if working && project.isEmpty { project = agents.first { $0.id == assignee }?.defaultProject ?? "" }
        if working && project.isEmpty { return .failure(TasksProblem("Choose the project folder the agent should work in.")) }
        return .success([
            "title": title,
            "instructions": instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            "project": project,
            "assignee": assignee,
            "status": status,
            "goalId": goalId,
        ])
    }
}

// MARK: - What each coding agent can keep (src/shared/agent-capabilities.ts)

public enum AgentSetting: String, Sendable, CaseIterable {
    case model, effort, instructions, toolAdvice, blockedTools, skillsOff, skillSelection, mcpConfig, resumeById
}

public enum AgentSupport: String, Sendable {
    case enforced, advisory, unsupported

    /// The small label beside a field.
    public var tag: String {
        switch self {
        case .enforced: "Enforced"
        case .advisory: "Advice only"
        case .unsupported: "Not available"
        }
    }
}

public enum AgentCapabilities {
    public enum Family: String, Sendable { case claude, codex, gemini, shell, custom }

    public static func family(_ provider: String?) -> Family {
        switch provider {
        case nil, "claude": .claude
        case "codex": .codex
        case "gemini": .gemini
        case "shell": .shell
        default: .custom
        }
    }

    public static func support(_ provider: String?, _ setting: AgentSetting) -> AgentSupport {
        // The app's default agent: instructions go in the brief, as advice.
        if provider == nil && setting == .instructions { return .advisory }
        switch (family(provider), setting) {
        case (.claude, .toolAdvice), (.claude, .skillSelection): return .advisory
        case (.claude, _): return .enforced
        case (.codex, .instructions), (.codex, .resumeById): return .enforced
        case (.codex, .toolAdvice), (.codex, .skillSelection): return .advisory
        case (.codex, _): return .unsupported
        case (.gemini, .instructions), (.gemini, .toolAdvice), (.gemini, .skillSelection): return .advisory
        case (.gemini, _): return .unsupported
        case (.shell, _): return .unsupported
        case (.custom, .instructions), (.custom, .toolAdvice), (.custom, .skillSelection): return .advisory
        case (.custom, _): return .unsupported
        }
    }

    public static func enforces(_ provider: String?, _ setting: AgentSetting) -> Bool {
        support(provider, setting) == .enforced
    }

    /// A provider as a sentence names it.
    public static func label(_ provider: String?) -> String {
        switch provider {
        case nil: "The app’s default coding agent"
        case "claude": "Claude Code"
        case "codex": "Codex CLI"
        case "gemini": "Gemini CLI"
        case "shell": "Shell"
        default: "An added agent"
        }
    }

    /// Said wherever an enforced limit meets an agent that cannot keep it.
    public static let enforceOnlyClaude = "Only Claude Code can block tools or turn skills off. Clear them, or choose Claude Code."
}

// MARK: - The agent form

/// An agent while it is being typed: every field as the input holds it.
public struct AgentDraft: Equatable, Sendable {
    public var id: String
    public var name: String
    public var role: String
    public var provider: String
    public var account: String
    public var model: String
    public var effort: String
    public var instructions: String
    public var instructionsFile: String?
    public var status: AgentStatus
    public var statusAt: Double?
    public var toolsPreferred: [String]
    public var toolsAvoided: [String]
    public var skills: [String]
    public var blockedTools: [String]
    public var skillsOff: Bool
    public var maxConcurrent: String
    public var maxRunMinutes: String
    public var keepAliveMinutes: String
    public var verifyCommand: String
    public var claudeAgent: String
    public var allowedTools: [String]?
    public var permissionMode: String
    public var keepAliveUntilClose: Bool
    public var defaultProject: String
    public var reviewerAgent: String
    public var sourceFile: String?
    public var sourceDirectory: String?
    public var syncedAt: Double?
    public var syncStatus: String?
    public var syncError: String?

    public var agsSettings: AGSAgentSettings? = nil
    public var agsRevision: UInt64? = nil

    public init(_ agent: AgentProfile?) {
        id = agent?.id ?? ""
        name = agent?.name ?? ""
        role = agent?.role ?? ""
        provider = agent?.provider ?? ""
        account = agent?.account ?? ""
        model = agent?.model ?? ""
        effort = agent?.effort ?? ""
        instructions = agent?.instructions ?? ""
        instructionsFile = agent?.instructionsFile
        status = agent?.status ?? .active
        statusAt = agent?.statusAt
        toolsPreferred = agent?.toolsPreferred ?? []
        toolsAvoided = agent?.toolsAvoided ?? []
        skills = agent?.skills ?? []
        blockedTools = agent?.blockedTools ?? []
        skillsOff = agent?.skillsOff ?? false
        maxConcurrent = String(agent?.maxConcurrent ?? 1)
        maxRunMinutes = String(agent?.maxRunMinutes ?? TasksLimits.defaultRunMinutes)
        keepAliveMinutes = String(agent?.keepAliveMinutes ?? TasksLimits.defaultKeepAliveMinutes)
        verifyCommand = agent?.verifyCommand ?? ""
        claudeAgent = agent?.claudeAgent ?? ""
        allowedTools = agent?.allowedTools
        permissionMode = agent?.permissionMode ?? ""
        keepAliveUntilClose = agent?.keepAliveUntilClose == true
        defaultProject = agent?.defaultProject ?? ""
        reviewerAgent = agent?.reviewerAgent ?? ""
        sourceFile = agent?.sourceFile
        sourceDirectory = agent?.sourceDirectory
        syncedAt = agent?.syncedAt
        syncStatus = agent?.syncStatus
        syncError = agent?.syncError
    }
}

public enum AgentForm {
    /// A stable id from a name: lower case, letters, digits and dashes. Unique among `taken`.
    public static func slug(_ name: String, taken: [String] = []) -> String {
        let folded = name.lowercased().decomposedStringWithCompatibilityMapping
        var out = ""
        var dash = false
        for scalar in folded.unicodeScalars {
            let ascii = scalar.isASCII && (CharacterSet.lowercaseLetters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar))
            if ascii {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash {
                out += "-"
                dash = true
            }
        }
        var trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        trimmed = String(trimmed.prefix(36))
        let base = trimmed.isEmpty ? "agent" : trimmed
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// A whole number from a box, or the sentence that says why not. Empty takes the fallback.
    public static func whole(_ raw: String, field: String, min: Int, max: Int, fallback: Int) -> Result<Int, TasksProblem> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(fallback) }
        guard let value = Double(trimmed), value == value.rounded(), value >= Double(min), value <= Double(max) else {
            return .failure(TasksProblem("\(field) has to be a whole number from \(min) to \(max)."))
        }
        return .success(Int(value))
    }

    /// Trimmed, blanks dropped, first of each kept.
    static func unique(_ values: [String]) -> [String] {
        var out: [String] = []
        for value in values.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !value.isEmpty && !out.contains(value) {
            out.append(value)
        }
        return out
    }

    static func orNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// What `tasks:agent-save` is sent, or the sentence that says what to fix first.
    public static func payload(_ draft: AgentDraft, agents: [AgentProfile]) -> Result<AgentProfile, TasksProblem> {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(TasksProblem("Give the agent a name.")) }
        let maxConcurrent = whole(draft.maxConcurrent, field: "Tasks at once", min: 1, max: TasksLimits.maxConcurrent, fallback: 1)
        let maxRun = whole(draft.maxRunMinutes, field: "Longest run", min: 0, max: TasksLimits.maxMinutes, fallback: TasksLimits.defaultRunMinutes)
        let keepAlive = whole(draft.keepAliveMinutes, field: "Keep open", min: 0, max: TasksLimits.maxMinutes,
                              fallback: TasksLimits.defaultKeepAliveMinutes)
        for value in [maxConcurrent, maxRun] {
            if case .failure(let problem) = value { return .failure(problem) }
        }
        if !draft.keepAliveUntilClose, case .failure(let problem) = keepAlive { return .failure(problem) }
        let provider = orNil(draft.provider)
        if draft.id.isEmpty && agents.count >= TasksLimits.maxAgents {
            return .failure(TasksProblem("You can have at most \(TasksLimits.maxAgents) task agents."))
        }
        let claudeOnly = orNil(draft.claudeAgent) != nil || (!SourceNamespace.agentSettingsEnabled && (draft.allowedTools != nil || orNil(draft.permissionMode) != nil))
        if claudeOnly && AgentCapabilities.family(provider) != .claude {
            return .failure(TasksProblem("Claude Code agent, allowed tools and permission mode need Claude Code. Clear them, or choose Claude Code."))
        }
        if SourceNamespace.agentSettingsEnabled, AgentCapabilities.family(provider) == .codex {
            let tools = (draft.allowedTools ?? []) + draft.blockedTools
            if !tools.allSatisfy({ $0.range(of: #"^mcp__[A-Za-z0-9_-]{1,64}__[A-Za-z0-9_-]{1,64}$"#, options: .regularExpression) != nil }) {
                return .failure(TasksProblem("Codex tool lists need exact MCP tool names. Built-in tool restrictions need a supported permission mode."))
            }
        }
        let permissionModes = SourceNamespace.agentSettingsEnabled ? AGSCapabilities.permissionModes(provider: provider ?? "claude") : TAGAgentSettings.permissionModes
        if !draft.permissionMode.isEmpty && !permissionModes.contains(draft.permissionMode) {
            return .failure(TasksProblem("Choose a permission mode from the list."))
        }
        if let project = orNil(draft.defaultProject), !project.hasPrefix("/") {
            return .failure(TasksProblem("Default project must be a full folder path starting with /, or empty."))
        }
        if !draft.reviewerAgent.isEmpty && (draft.reviewerAgent == draft.id || !agents.contains(where: { $0.id == draft.reviewerAgent && $0.status != .archived })) {
            return .failure(TasksProblem("Choose another available task agent as the reviewer."))
        }
        if (!unique(draft.blockedTools).isEmpty && !(SourceNamespace.agentSettingsEnabled ? AGSCapabilities.providers.contains(provider ?? "claude") : AgentCapabilities.enforces(provider, .blockedTools)))
            || (draft.skillsOff && !AgentCapabilities.enforces(provider, .skillsOff)) {
            return .failure(TasksProblem(AgentCapabilities.enforceOnlyClaude))
        }
        // A setting the chosen agent cannot be given is refused, never saved to be dropped.
        if orNil(draft.model) != nil && !(SourceNamespace.agentSettingsEnabled && AGSCapabilities.providers.contains(provider ?? "claude")) && !AgentCapabilities.enforces(provider, .model) {
            return .failure(TasksProblem("\(AgentCapabilities.label(provider)) cannot be given a model by this app. Clear it, or choose Claude Code."))
        }
        let knownEffort = SourceNamespace.agentSettingsEnabled
            ? draft.effort == "auto" || AGSCapabilities.efforts(provider: provider ?? "claude").contains(draft.effort)
            : EFFORT_CHOICES.contains { $0.id == draft.effort }
        if !SourceNamespace.agentSettingsEnabled, !draft.effort.isEmpty, !AgentCapabilities.enforces(provider, .effort) {
            return .failure(TasksProblem("\(AgentCapabilities.label(provider)) cannot be given an effort level by this app. Clear it, or choose Claude Code."))
        }
        if SourceNamespace.agentSettingsEnabled, !draft.effort.isEmpty, !knownEffort {
            return .failure(TasksProblem("That saved effort is not supported by the selected coding agent. Review it before saving; it will not be silently replaced."))
        }
        let id = draft.id.isEmpty ? slug(name, taken: agents.map(\.id)) : draft.id
        let role = draft.role.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = draft.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(AgentProfile(
            id: id, name: name, role: role.isEmpty ? "general" : role, provider: provider, account: orNil(draft.account),
            model: orNil(draft.model), effort: knownEffort ? draft.effort : nil,
            instructions: instructions.isEmpty ? nil : instructions, instructionsFile: draft.instructionsFile,
            toolsPreferred: unique(draft.toolsPreferred), toolsAvoided: unique(draft.toolsAvoided), skills: unique(draft.skills),
            blockedTools: unique(draft.blockedTools), skillsOff: draft.skillsOff,
            maxConcurrent: (try? maxConcurrent.get()) ?? 1, maxRunMinutes: (try? maxRun.get()) ?? TasksLimits.defaultRunMinutes,
            keepAliveMinutes: (try? keepAlive.get()) ?? TasksLimits.defaultKeepAliveMinutes,
            verifyCommand: orNil(draft.verifyCommand),
            // Sent as it is; the main process keeps an agent's status whatever a save carries.
            status: draft.status, statusAt: draft.statusAt,
            claudeAgent: orNil(draft.claudeAgent), allowedTools: draft.allowedTools.map(unique), permissionMode: orNil(draft.permissionMode),
            // An untouched legacy nil remains absent; explicitly turning an
            // existing on/off setting off still sends false.
            keepAliveUntilClose: draft.keepAliveUntilClose ? true : (agents.first { $0.id == id }?.keepAliveUntilClose).map { _ in false },
            defaultProject: orNil(draft.defaultProject), reviewerAgent: orNil(draft.reviewerAgent),
            sourceFile: draft.sourceFile, sourceDirectory: draft.sourceDirectory, syncedAt: draft.syncedAt,
            syncStatus: draft.syncStatus, syncError: draft.syncError))
    }
}

// MARK: - The connection form

/// A connection while it is being typed. Lists are one entry per line.
public struct ConnectionDraft: Equatable, Sendable {
    public struct Identity: Equatable, Sendable {
        public var identity: String
        public var agentId: String
        public init(identity: String, agentId: String) {
            self.identity = identity
            self.agentId = agentId
        }
    }

    public var name: String
    public var eventsUrl: String
    public var hootIdentity: String
    public var allowedSenders: String
    public var folders: String
    public var maxHops: String
    public var identities: [Identity]
    public var statuses: String
    public var initial: String
    public var completed: String
    public var onStarted: String
    public var onVerified: String
    public var onBlocked: String

    public init(_ connection: CrmConnection) {
        let s = connection.statuses
        name = connection.name ?? ""
        eventsUrl = connection.eventsUrl ?? ""
        hootIdentity = connection.hootIdentity ?? ""
        allowedSenders = connection.allowedSenders.joined(separator: "\n")
        folders = connection.folders.joined(separator: "\n")
        maxHops = String(connection.maxHops)
        identities = connection.identityOrder.map { Identity(identity: $0, agentId: connection.identities[$0] ?? "") }
        statuses = s.statuses.joined(separator: "\n")
        initial = s.initial
        completed = s.completed
        onStarted = s.onStarted ?? ""
        onVerified = s.onVerified ?? ""
        onBlocked = s.onBlocked ?? ""
    }
}

public enum ConnectionForm {
    /// Lines of a list box: trimmed, blanks dropped, repeats dropped.
    public static func lines(_ raw: String) -> [String] {
        var out: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !out.contains(trimmed) { out.append(trimmed) }
        }
        return out
    }

    /// The statuses part of the patch, as `StatusConfig` (for tests and the wire).
    public struct Patch: Sendable {
        public var name: String?
        public var eventsUrl: String?
        public var hootIdentity: String?
        public var allowedSenders: [String]
        public var folders: [String]
        public var maxHops: Int
        public var identities: [String: String]
        public var statuses: StatusConfig

        public var wire: [String: Any] {
            ["name": orNullValue(name), "eventsUrl": orNullValue(eventsUrl), "hootIdentity": orNullValue(hootIdentity),
             "allowedSenders": allowedSenders, "folders": folders, "maxHops": maxHops, "identities": identities,
             "statuses": statuses.wire]
        }
    }

    /// The patch `tasks:connection-save` is sent for the form's fields, or what to fix first.
    public static func patch(_ draft: ConnectionDraft) -> Result<Patch, TasksProblem> {
        let maxHops: Int
        switch AgentForm.whole(draft.maxHops, field: "The hand-off limit", min: 1, max: TasksLimits.maxHops,
                               fallback: TasksLimits.defaultHops) {
        case .failure(let problem): return .failure(problem)
        case .success(let value): maxHops = value
        }
        let statuses = lines(draft.statuses)
        if statuses.isEmpty { return .failure(TasksProblem("Name at least one CRM status.")) }
        func pick(_ value: String, _ fallback: String) -> String { statuses.contains(value) ? value : fallback }
        func optional(_ value: String) -> String? { statuses.contains(value) ? value : nil }
        var identities: [String: String] = [:]
        for row in draft.identities {
            let identity = row.identity.trimmingCharacters(in: .whitespacesAndNewlines)
            if identity.isEmpty && row.agentId.isEmpty { continue }
            if identity.isEmpty { return .failure(TasksProblem("Each agent identity needs its CRM identity id.")) }
            if row.agentId.isEmpty { return .failure(TasksProblem("Choose which agent \(identity) is.")) }
            identities[identity] = row.agentId
        }
        return .success(Patch(
            name: AgentForm.orNil(draft.name), eventsUrl: AgentForm.orNil(draft.eventsUrl),
            hootIdentity: AgentForm.orNil(draft.hootIdentity), allowedSenders: lines(draft.allowedSenders),
            folders: lines(draft.folders), maxHops: maxHops, identities: identities,
            statuses: StatusConfig(statuses: statuses, initial: pick(draft.initial, statuses[0]),
                                   completed: pick(draft.completed, statuses[statuses.count - 1]),
                                   onStarted: optional(draft.onStarted), onVerified: optional(draft.onVerified),
                                   onBlocked: optional(draft.onBlocked))))
    }
}

// MARK: - Goals and the CRM mirror, as the page words them (Goals.tsx, CrmTasks.tsx, MyWork.tsx)

extension Goals {
    /// "3 of 5 done", then only the counts worth a look.
    public static func progressLine(_ progress: GoalProgress) -> String {
        if progress.total == 0 { return "No tasks yet" }
        var parts = ["\(progress.done) of \(progress.total) done"]
        if progress.verified > 0 { parts.append("\(progress.verified) verified") }
        if progress.unverified > 0 { parts.append("\(progress.unverified) to check") }
        if progress.stalled > 0 { parts.append("\(progress.stalled) stalled") }
        if progress.blocked > 0 { parts.append("\(progress.blocked) waiting") }
        return parts.joined(separator: " · ")
    }

    /// Done share, 0–100, rounded.
    public static func share(_ progress: GoalProgress) -> Int {
        progress.total == 0 ? 0 : Int((Double(progress.done) / Double(progress.total) * 100).rounded())
    }

    /// The goals as a picker offers them: tree order, indented.
    public static func options(_ goals: [GoalRow]) -> [(id: String, label: String)] {
        tree(goals).map { entry in
            (entry.goal.id, String(repeating: "\u{00a0}\u{00a0}", count: entry.depth) + (entry.depth > 0 ? "↳ " : "") + entry.goal.title)
        }
    }
}

public enum CrmMirror {
    /// Whether a finished task was checked: by its check command, or by Hoot.
    public static func checkLabel(_ verified: Bool?) -> String {
        guard let verified else { return "not finished" }
        return verified ? "finished and checked" : "finished, not checked yet"
    }

    /// "just now", "5 min ago", "3 h ago", "2 d ago".
    public static func agoLabel(_ at: Double, now: Double) -> String {
        let minutes = Int((max(now - at, 0) / 60_000).rounded(.down))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / (24 * 60)) d ago"
    }

    /// "2 running · 1 queued", or empty.
    public static func summary(_ tasks: [TaskRow]) -> String {
        let running = tasks.filter { $0.process == .running }.count
        let queued = tasks.filter { $0.process == .queued }.count
        return [running > 0 ? "\(running) running" : nil, queued > 0 ? "\(queued) queued" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The Trash's "Deleted …": "just now", "5 minutes ago", "3 hours ago", "2 days ago".
    public static func relativeAgo(_ ms: Double) -> String {
        let minutes = Int((max(0, ms) / 60_000).rounded(.down))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }
}
