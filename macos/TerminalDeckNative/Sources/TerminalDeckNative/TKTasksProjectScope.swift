import Foundation
import Observation
import SwiftUI
import TerminalDeckNativeCore

// Tasks by project on the Tasks screen (lane TK, 7 Oct 2026): the current project's
// tasks by default, with its name at the top; a switch for every project's, grouped
// under each project's name; "Move to Project ▸" on a task's right-click menu. The
// current project and the open projects are the sidebar's (`activeProjectPath`, the
// "Open" section); the rules are `TaskProjects` in the core.

/// Which project's tasks the screen shows, kept on this Mac.
@MainActor
@Observable
final class TKTasksProjectScope {
    static let shared = TKTasksProjectScope()

    /// What was picked; "This project" falls back to every project while none is current.
    var scope: TaskProjectScope {
        didSet { UserDefaults.standard.set(scope.rawValue, forKey: TaskProjectScope.storageKey) }
    }

    private init() {
        scope = TaskProjectScope(rawValue: UserDefaults.standard.string(forKey: TaskProjectScope.storageKey) ?? "") ?? .this
    }

    /// Set when a reminder moved the Tasks screen to a project the page has not
    /// confirmed yet (or cannot: that project has no session to select); `base` is
    /// the page's project at that moment. Cleared once the page's project moves.
    @ObservationIgnored private var pinnedBase: String?
    private var pinned: String?

    /// The project the page's views are about (or the one a reminder just moved to).
    var current: String? {
        let page = AppModel.shared.sidebar?.project
        if let pinned, page == pinnedBase || page.map(TaskProjects.clean) == pinned { return pinned }
        return page
    }

    /// The page's project moved: a pin from a reminder has done its job.
    func pageProjectChanged() { pinned = nil; pinnedBase = nil }

    /// A reminder or notification for a task was clicked. When the task lives in
    /// another open project the window moves there first (one of its sessions is
    /// selected, so the page's views follow), then the Tasks screen comes up to open it.
    func reveal(_ taskID: String, in state: TasksState?) {
        guard let task = state.flatMap({ s in (s.tasks + s.trash).first { $0.id == taskID } }),
              let target = TaskProjects.revealTarget(for: task.project, current: current, open: open) else { return }
        let app = AppModel.shared
        pinnedBase = app.sidebar?.project
        pinned = target
        if let session = app.sidebar?.projects.first(where: { TaskProjects.clean($0.id) == target })?
            .sessions.first(where: { $0.kind == .session && !$0.isHeld }) {
            app.select(session.id)
        }
        app.select("tasks")
    }
    /// The sidebar's open projects, in its order.
    var open: [TaskProject] { (AppModel.shared.sidebar?.projects ?? []).map { TaskProject(path: $0.id, title: $0.title) } }
    var hasCurrent: Bool { TaskProjects.effective(.this, current: current) == .this }
    var effective: TaskProjectScope { TaskProjects.effective(scope, current: current) }
    var currentName: String { current.map { TaskProjects.name(of: $0, among: open) } ?? TaskProjects.noProject }
    /// A new task made on this screen gets the current project ("" when none is open).
    var newTaskProject: String { current.map(TaskProjects.clean) ?? "" }

    /// The tasks, Trash and goals the screen draws.
    func scoped(_ state: TasksState) -> TasksState {
        TaskProjects.scoped(state, scope: scope, current: current, open: open)
    }
}

/// The top of the Tasks screen: which project, and the This project / All projects switch.
struct TKTasksProjectBar: View {
    @State private var projects = TKTasksProjectScope.shared

    var body: some View {
        let all = projects.effective == .all
        HStack(alignment: .center, spacing: 12) {
            Label(all ? TaskProjectScope.all.label : projects.currentName, systemImage: all ? "square.stack" : "folder")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(all ? "Tasks from every project" : (projects.current ?? ""))
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(all ? "Tasks from all projects" : "Tasks for \(projects.currentName)")
            Spacer(minLength: 8)
            Picker("Show tasks from", selection: Binding(get: { projects.effective }, set: { projects.scope = $0 })) {
                ForEach(TaskProjectScope.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).nativeUIGGreyControl()
            .labelsHidden()
            .fixedSize()
            .disabled(!projects.hasCurrent)
            .help(projects.hasCurrent ? "Show this project's tasks, or every project's" : "Open a project in the sidebar to see only its tasks")
        }
        .onChange(of: AppModel.shared.sidebar?.project) { _, _ in projects.pageProjectChanged() }
    }
}

/// "Move to Project ▸" on a task's right-click menu: every other open project, and
/// No project when nobody but you works on it.
struct TKMoveToProjectMenu: View {
    let task: TaskRow

    var body: some View {
        let projects = TKTasksProjectScope.shared
        let targets = TaskProjects.moveTargets(for: task, open: projects.open)
        let clearable = TaskProjects.canClearProject(task)
        Menu("Move to Project") {
            ForEach(targets) { project in
                Button(TaskProjects.name(of: project.path, among: projects.open)) { move(project.path) }
            }
            if clearable {
                if !targets.isEmpty { Divider() }
                Button(TaskProjects.noProject) { move("") }
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
