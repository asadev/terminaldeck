import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Making a task (Asad, 12 Oct, with ClickUp's "Task" dialog beside him): "the shape of creating
// a task should be a pop-up", with only the fields the app already had. Every place that makes a
// task opens this ONE centred card: the Tasks page's New task, "Add task" under a group or a board
// column, "+ Add" on a calendar day, and an agent's "Assign task".

/// Where a new task was asked for, and what that place already knows about it.
enum TaskCreateEntry: Equatable {
    /// The Tasks page's New task: nobody has it yet, the page's project.
    case newTaskButton
    /// "Add task" under a group of the table, or under a board column: that group's values, yours.
    case addTaskRow(GroupDefaults?)
    /// "+ Add" on a day of the week calendar: due that day, yours.
    case calendarDay(String)
    /// An agent's "Assign task": that agent, in its folder.
    case agent(id: String, name: String, project: String)

    var preset: TaskCreatePreset {
        switch self {
        case .newTaskButton:
            TaskCreatePreset(carried: GroupDefaults(), assignee: "none")
        case .addTaskRow(let defaults):
            TaskCreatePreset(carried: defaults ?? GroupDefaults(), assignee: defaults?.assignee ?? "me")
        case .calendarDay(let day):
            TaskCreatePreset(carried: GroupDefaults(dueDate: .some(day)), assignee: "me")
        case .agent(let id, let name, let project):
            TaskCreatePreset(carried: GroupDefaults(project: project), assignee: id, assigneeName: name)
        }
    }
}

/// What the card starts with: who has the task, and the values the place it came from gives it.
struct TaskCreatePreset: Equatable {
    var carried: GroupDefaults
    var assignee: String
    var assigneeName: String?
    /// A new opening is a new card, even with the same values.
    let opening = UUID()

    static func == (lhs: TaskCreatePreset, rhs: TaskCreatePreset) -> Bool {
        lhs.carried == rhs.carried && lhs.assignee == rhs.assignee && lhs.assigneeName == rhs.assigneeName
    }

    /// The form's first values: status and project from the place, else the first status and the page's project.
    func draft(statuses: [String], scopeProject: String) -> LocalDraft {
        var draft = LocalDraft(nil, statuses: statuses)
        draft.assignee = assignee
        if let status = carried.status { draft.status = status }
        draft.project = carried.project ?? scopeProject
        return draft
    }

    /// What `tasks:local-create` is sent: the form, plus what only the place knows (priority, due date,
    /// board, project id). The form's own fields win.
    func input(_ draft: LocalDraft, agents: [AgentProfile]) -> Result<[String: Any], TasksProblem> {
        switch draft.payload(agents: agents) {
        case .failure(let problem):
            return .failure(problem)
        case .success(var payload):
            var extra = carried.wire
            for key in ["status", "assignee", "project"] { extra.removeValue(forKey: key) }
            payload.merge(extra) { form, _ in form }
            return .success(payload)
        }
    }

    /// The values the card shows but has no field for: (symbol, text, why).
    func carriedChips(today: String) -> [(symbol: String, text: String, help: String)] {
        var chips: [(symbol: String, text: String, help: String)] = []
        if case .some(.some(let day)) = carried.dueDate {
            let label = TaskList.relativeDue(day, today: today)
            chips.append(("calendar", label.isEmpty ? day : label, "Due \(day)"))
        }
        if case .some(.some(let priority)) = carried.priority {
            chips.append(("flag", priority, "Priority"))
        }
        if case .some(.some(let board)) = carried.board {
            chips.append(("rectangle.split.3x1", board, "Board"))
        }
        return chips
    }
}

/// What the card reads from the rest of the app: the page's project, the person's projects, the lead seats.
/// A test hands it fixed answers, so the card is drawn without the app's model.
struct TaskCreateContext {
    var scopeProject: @MainActor () -> String
    var projects: @MainActor () -> [TaskProject]
    var withLeadSeats: @MainActor ([AgentProfile]) -> [AgentProfile]
    var startStore: @MainActor () -> Void

    @MainActor static var live: TaskCreateContext {
        TaskCreateContext(scopeProject: { TKTasksProjectScope.shared.newTaskProject }, projects: { TKTasksProjectScope.shared.open },
                          withLeadSeats: { AGTLeads.withLeadSeats($0) }, startStore: { TasksStore.shared.start() })
    }
}

/// Opens the screen's one create card. Read from the environment by every entry point.
struct TaskCreateOpener {
    let open: @MainActor (TaskCreateEntry) -> Void
}

extension EnvironmentValues {
    @Entry var openTaskCreate: TaskCreateOpener? = nil
}

@MainActor
extension View {
    /// The screen hosts the card: centred over it, with the page dimmed behind. Everything inside can open it.
    func taskCreatePopup(_ preset: Binding<TaskCreatePreset?>, context: TaskCreateContext = .live) -> some View {
        environment(\.openTaskCreate, TaskCreateOpener { preset.wrappedValue = $0.preset })
            .overlay {
                if let opened = preset.wrappedValue {
                    NativeTaskCreateOverlay(preset: opened, context: context) { preset.wrappedValue = nil }
                        .id(opened.opening)
                }
            }
    }
}

/// The page dimmed, and the card in the middle. A click beside it keeps what was typed.
struct NativeTaskCreateOverlay: View {
    let preset: TaskCreatePreset
    let context: TaskCreateContext
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            NativeTaskCreatePopup(preset: preset, context: context, onClose: onClose)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                .padding(24)
        }
        .transition(.opacity)
    }
}

/// The card: "Task" and ×; the project; the task's name; its description; who, status and goal; Create task.
struct NativeTaskCreatePopup: View {
    let preset: TaskCreatePreset
    let context: TaskCreateContext
    let onClose: () -> Void
    @State var store = TasksStore.shared
    @State var draft: LocalDraft
    @State var describing = false
    @State var typingFolder = false
    @State var saving = false
    @State var problem: String?
    @FocusState var focus: Field?

    enum Field: Hashable { case name, description, folder }
    /// The project menu's "Other folder…": a full path typed beside it.
    static let otherFolder = "\u{1}other-folder"

    init(preset: TaskCreatePreset, context: TaskCreateContext = .live, onClose: @escaping () -> Void) {
        self.preset = preset
        self.context = context
        self.onClose = onClose
        let draft = preset.draft(statuses: TasksStore.shared.state?.localStatuses ?? DEFAULT_CRM_STATUSES.statuses,
                                 scopeProject: context.scopeProject())
        _draft = State(initialValue: draft)
        let open = context.projects()
        let path = TaskProjects.clean(draft.project)
        _typingFolder = State(initialValue: !path.isEmpty && !open.contains { TaskProjects.clean($0.path) == path })
    }

    var state: TasksState { store.state ?? TasksState() }
    var agents: [AgentProfile] { context.withLeadSeats(state.agents) }
    var hasTitle: Bool { !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                projectRow
                nameField
                descriptionArea
                chips
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            Divider()
            footer
        }
        .frame(maxWidth: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(saving)
        .onExitCommand(perform: onClose)
        .background {
            // Esc closes the card wherever the focus is, as the New session dialog does.
            Button("") { onClose() }.keyboardShortcut(.cancelAction).hidden().accessibilityHidden(true)
        }
        .onAppear {
            focus = .name
            if store.state == nil { context.startStore() }
        }
        .task {
            // The card is mounted inside a page that just took the click: ask again once it is drawn.
            try? await Task.sleep(for: .milliseconds(80))
            if focus == nil { focus = .name }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New task")
    }

}
