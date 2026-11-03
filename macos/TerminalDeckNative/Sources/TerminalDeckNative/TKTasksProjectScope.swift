import Foundation
import Observation
import SwiftUI
import TerminalDeckNativeCore

// The Tasks page remembers its own project choice; it starts with All projects.
// Stable project IDs come from PROJ. Existing task operations still take folders.

/// Which project's tasks the screen shows, kept on this Mac.
@MainActor
@Observable
final class TKTasksProjectScope {
    static let shared = TKTasksProjectScope()

    private static let selectionKey = "td.tasks.selectedProjectID"
    @ObservationIgnored private let preferences: UserDefaults?
    private let fixtureProjects: [PROJProject]?
    var isRenderFixture: Bool { fixtureProjects != nil }
    var selectedProjectID: String? {
        didSet { preferences?.set(selectedProjectID, forKey: Self.selectionKey) }
    }
    private var suppliedProject: PROJProject?
    var registry: [PROJProject] {
        let projects = fixtureProjects ?? NativePROJLabels.shared.projects
        guard let suppliedProject, !projects.contains(where: { $0.id == suppliedProject.id }) else { return projects }
        return projects + [suppliedProject]
    }
    var registryProblem: String? { isRenderFixture ? nil : NativePROJLabels.shared.error }

    /// Retained for existing task views; arbitrary projects use their selected ID.
    var scope: TaskProjectScope {
        didSet { preferences?.set(scope.rawValue, forKey: TaskProjectScope.storageKey) }
    }

    private init(preferences: UserDefaults? = .standard, fixtureProjects: [PROJProject]? = nil) {
        self.preferences = preferences
        self.fixtureProjects = fixtureProjects
        let selected = preferences?.string(forKey: Self.selectionKey)
        self.selectedProjectID = selected
        self.scope = selected == nil ? .all : .this
    }

    #if DEBUG
    /// Explicit scratch rows; no UserDefaults, shared labels or AppModel access.
    static func renderFixture(projects: [PROJProject], selectedProjectID: String? = nil) -> TKTasksProjectScope {
        let fixture = TKTasksProjectScope(preferences: nil, fixtureProjects: projects)
        fixture.choose(selectedProjectID)
        return fixture
    }
    #endif

    /// The project the page's views are about (or the one a reminder just moved to).
    var current: String? {
        if let selectedProjectID {
            return registry.first { $0.id == selectedProjectID }?.folders.first
        }
        guard !isRenderFixture else { return nil }
        return AppModel.shared.sidebar?.project
    }

    /// A reminder or notification for a task was clicked. When the task lives in
    /// another open project the window moves there first (one of its sessions is
    /// selected, so the page's views follow), then the Tasks screen comes up to open it.
    func reveal(_ taskID: String, in state: TasksState?) {
        guard let task = state.flatMap({ s in (s.tasks + s.trash).first { $0.id == taskID } }) else { return }
        let projectID = TaskProjects.projectID(for: task, projects: registry)
        choose(projectID)
        guard !isRenderFixture else { return }
        let app = AppModel.shared
        let folders = registry.first { $0.id == projectID }?.folders ?? []
        let target = folders.first { TaskProjects.within(task.project, $0) } ?? folders.first
        if let target, let session = app.sidebar?.projects.first(where: { TaskProjects.clean($0.id) == TaskProjects.clean(target) })?
            .sessions.first(where: { $0.kind == .session && !$0.isHeld }) {
            app.select(session.id)
        }
        app.select("tasks")
    }
    /// The sidebar's open projects, in its order.
    var open: [TaskProject] {
        let registered = registry.flatMap { project in project.folders.map { TaskProject(path: $0, title: project.name) } }
        guard !isRenderFixture else { return registered }
        let sidebar = (AppModel.shared.sidebar?.projects ?? []).map { TaskProject(path: $0.id, title: $0.title) }
        return registered + sidebar.filter { row in !registered.contains { TaskProjects.clean($0.path) == TaskProjects.clean(row.path) } }
    }
    var hasCurrent: Bool { TaskProjects.effective(.this, current: current) == .this }
    var effective: TaskProjectScope { selectedProjectID == nil ? .all : .this }
    var currentName: String {
        selectedProjectID.map { PROJProjects.name(for: $0, projects: registry) } ?? "All projects"
    }
    /// A new task made on this screen gets the current project ("" when none is open).
    var newTaskProject: String { current.map(TaskProjects.clean) ?? "" }

    /// The tasks, Trash and goals the screen draws.
    func scoped(_ state: TasksState) -> TasksState {
        TaskProjects.scoped(state, projectID: selectedProjectID, projects: registry)
    }

    func choose(_ projectID: String?) {
        selectedProjectID = projectID
        scope = projectID == nil ? .all : .this
    }

    func selectProject(_ project: PROJProject) {
        suppliedProject = project
        choose(project.id)
    }

    func selectProject(project: PROJProject) { selectProject(project) }

    func loadRegistry() async {
        guard !isRenderFixture else { return }
        NativePROJLabels.shared.start()
    }
}

/// Shared ProjectPicker seam, shown at the top of the Tasks page.
struct TKTasksProjectBar: View {
    @State private var projects: TKTasksProjectScope

    init(projects: TKTasksProjectScope = .shared) {
        _projects = State(initialValue: projects)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .center, spacing: 12) {
            Text("Tasks")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            ProjectPicker(projects: projects.registry,
                          selection: Binding(get: { projects.selectedProjectID }, set: { projects.choose($0) }),
                          openProject: { if !projects.isRenderFixture { AppModel.shared.openProject() } })
                .help(projects.registryProblem ?? "Choose the projects whose tasks you want to see")
        }
        if let problem = projects.registryProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
        }
        }
        .task { await projects.loadRegistry() }
    }
}

/// "Move to Project ▸" on a task's right-click menu: every other open project, and
/// No project when nobody but you works on it.
struct TKMoveToProjectMenu: View {
    let task: TaskRow
    var projects: TKTasksProjectScope = .shared

    var body: some View {
        let targets = TaskProjects.moveTargets(for: task, open: projects.open)
        let clearable = TaskProjects.canClearProject(task)
        Menu("Move to Project") {
            ForEach(targets) { project in
                Button { move(project.path) } label: {
                    DeckRowLabel(TaskProjects.name(of: project.path, among: projects.open), image: DeckRowIcon.project(folder: project.path))
                }
            }
            if clearable {
                if !targets.isEmpty { Divider() }
                Button { move("") } label: { DeckRowLabel(TaskProjects.noProject, image: DeckRowIcon.independent) }
            }
            if targets.isEmpty && !clearable {
                Button("No other open project") {}.disabled(true)
            }
        }
    }

    private func move(_ path: String) {
        let store = TasksStore.shared
        Task { await store.run { await store.update(task.id, ["project": path]) } }
    }
}
