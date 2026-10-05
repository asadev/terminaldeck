import AppIntents
import TerminalDeckNativeCore

// Siri / Shortcuts (lane R): the things an intent can name — projects,
// sessions, tasks, goals and the agents — each backed by the engine channel
// the window reads them from.

// MARK: - Projects (`projects:list`, named as the sidebar names them)

struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = ProjectQuery()

    /// The folder's full path.
    let id: String
    let name: String
    let place: String

    init(_ project: IntentProject, home: String) {
        id = project.path
        name = project.name
        place = IntentProjects.displayPath(project.path, home: home)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(place)", image: .init(systemName: "folder"))
    }
}

struct ProjectQuery: EntityStringQuery {
    /// A path is its own id: it resolves even before the engine is up.
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        let known = (try? await list()) ?? []
        return identifiers.filter { $0.hasPrefix("/") }.map { path in
            ProjectEntity(known.first(where: { $0.path == path })
                          ?? IntentProject(path: path, name: IntentProjects.folderName(path)), home: IntentsEngine.home)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ProjectEntity] {
        IntentProjects.match(string, in: try await list()).map { ProjectEntity($0, home: IntentsEngine.home) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ProjectEntity] {
        try await list().map { ProjectEntity($0, home: IntentsEngine.home) }
    }

    @MainActor
    private func list() async throws -> [IntentProject] {
        try await IntentsEngine.ready(IntentBudget(IntentDeadline.readBudget))
        return try await IntentsEngine.projects()
    }
}

// MARK: - Sessions (`session:list`, named and given status by the sidebar)

struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
    static let defaultQuery = SessionQuery()

    let id: String
    let title: String
    let project: String
    let status: String

    var displayRepresentation: DisplayRepresentation {
        let subtitle = status.isEmpty ? project : "\(project) · \(status)"
        return DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)", image: .init(systemName: "terminal"))
    }
}

struct SessionQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        let all = try await live()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    @MainActor
    func suggestedEntities() async throws -> [SessionEntity] {
        try await live()
    }

    /// Running sessions, in the sidebar's names when it has drawn them.
    @MainActor
    private func live() async throws -> [SessionEntity] {
        try await IntentsEngine.ready(IntentBudget(IntentDeadline.readBudget))
        let raw = try await IntentsEngine.invoke("session:list")
        let rows = IntentsEngine.model.sidebar?.allItems ?? []
        var out: [SessionEntity] = []
        for case let meta as [String: Any] in (raw as? [Any]) ?? [] {
            guard let id = meta["id"] as? String, !(meta["exitCode"] is NSNumber) else { continue }
            let cwd = meta["cwd"] as? String ?? ""
            let row = rows.first { $0.id == id }
            out.append(SessionEntity(
                id: id,
                title: row?.title ?? (meta["title"] as? String ?? "Session"),
                project: IntentProjects.folderName(cwd),
                status: row?.status ?? ""))
        }
        return out
    }
}

// MARK: - Tasks and goals (`tasks:state`, the Tasks page's own read)

struct TaskEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task"
    static let defaultQuery = TaskQuery()

    let id: String
    let title: String
    let detail: String

    init(_ task: IntentTaskSummary) {
        id = task.id
        title = task.title
        let place = task.project.isEmpty ? nil : IntentProjects.folderName(task.project)
        detail = [task.status.isEmpty ? nil : task.status, place, task.agent.isEmpty ? nil : task.agent]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)", image: .init(systemName: "checklist"))
    }
}

struct TaskQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [TaskEntity] {
        let tasks = try await IntentsReads.tasks()
        return identifiers.compactMap { id in tasks.first { $0.id == id }.map(TaskEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TaskEntity] {
        let wanted = IntentProjects.normalized(string)
        return try await IntentsReads.tasks()
            .filter { !$0.isGone && IntentProjects.normalized($0.title).contains(wanted) }
            .map(TaskEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [TaskEntity] {
        try await IntentsReads.tasks().filter(\.isOpen).prefix(50).map(TaskEntity.init)
    }
}

struct GoalEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Goal"
    static let defaultQuery = GoalQuery()

    let id: String
    let title: String
    let progress: String

    init(_ goal: IntentGoalSummary) {
        id = goal.id
        title = goal.title
        progress = goal.total == 0 ? "No tasks yet" : "\(goal.done) of \(goal.total) done"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(progress)", image: .init(systemName: "flag"))
    }
}

struct GoalQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [GoalEntity] {
        let goals = try await IntentsReads.goals()
        return identifiers.compactMap { id in goals.first { $0.id == id }.map(GoalEntity.init) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [GoalEntity] {
        let wanted = IntentProjects.normalized(string)
        return try await IntentsReads.goals()
            .filter { IntentProjects.normalized($0.title).contains(wanted) }
            .map(GoalEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [GoalEntity] {
        try await IntentsReads.goals().map(GoalEntity.init)
    }
}

@MainActor
enum IntentsReads {
    static func tasks() async throws -> [IntentTaskSummary] {
        try await IntentsEngine.ready(IntentBudget(IntentDeadline.readBudget))
        return try await IntentsEngine.tasksAndGoals().tasks
    }

    static func goals() async throws -> [IntentGoalSummary] {
        try await IntentsEngine.ready(IntentBudget(IntentDeadline.readBudget))
        return try await IntentsEngine.tasksAndGoals().goals
    }
}

// MARK: - Agents (every one a session can start with)

enum AgentOption: String, AppEnum {
    case claude, codex, gemini, shell

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Agent"
    static let caseDisplayRepresentations: [AgentOption: DisplayRepresentation] = [
        .claude: DisplayRepresentation(title: "Claude Code", synonyms: ["Claude"]),
        .codex: DisplayRepresentation(title: "Codex", synonyms: ["OpenAI Codex"]),
        .gemini: DisplayRepresentation(title: "Gemini CLI", synonyms: ["Gemini"]),
        .shell: DisplayRepresentation(title: "Plain shell", synonyms: ["Shell", "Terminal"]),
    ]

    var agent: IntentAgent { IntentAgent(rawValue: rawValue) ?? .claude }
}
