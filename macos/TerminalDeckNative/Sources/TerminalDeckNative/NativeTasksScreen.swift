import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Tasks, drawn in Swift: the page in the sidebar for your own tasks and the work a
/// CRM gives Hoot and the task agents (src/renderer/tasks/TasksPage.tsx) — the same
/// facts and buttons at the top, the New task and New goal forms, Goals, Your tasks
/// (MyWork) and From your CRM, in that order, with the same empty, loading and
/// error states. Every read and change goes through `TasksStore` on the page's own
/// `tasks:*` channels.
struct NativeTasksScreen: View {
    @State private var store = TasksStore.shared
    @State private var creating = false
    @State private var creatingGoal = false
    @State private var clock = Date()
    @State private var myWork = MyWorkModel()
    private var app: AppModel { AppModel.shared }

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                // The page draws nothing until the first read answers.
                Color.clear
            case .failed:
                ContentUnavailableView {
                    Label("Tasks could not be read", systemImage: "checklist")
                } description: {
                    Text("Terminal Deck did not answer. Reopen this page in a moment.")
                }
            case .ready(let state):
                page(state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay { popup }
        .task(id: app.canRun) { store.start() }
        .onChange(of: store.openRequest?.at, initial: true) { _, _ in
            // A reminder for a task was clicked: open it here.
            guard let request = store.openRequest else { return }
            myWork.open = request.id
            store.clearOpenRequest()
        }
        .task(id: ticking) {
            // A kept-open session's minutes move on while the page is open.
            guard ticking else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                clock = Date()
            }
        }
    }

    /// The open task's popup, over the whole page, as the page's popup sits over it.
    @ViewBuilder private var popup: some View {
        if let state = store.state, let id = myWork.open, let task = state.tasks.first(where: { $0.id == id && $0.local }) {
            let now = Date().timeIntervalSince1970 * 1000
            let order = myWork.order(TKTasksProjectScope.shared.scoped(state), now: now)
            ZStack {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { myWork.open = nil }
                NativeTaskPopup(
                    task: task,
                    tasks: state.tasks.filter(\.local),
                    siblings: order.contains(task.id) ? order : [task.id],
                    agents: state.agents,
                    onNavigate: { myWork.open = $0 },
                    onClose: { myWork.open = nil },
                    onDelete: { id in
                        myWork.open = nil
                        Task { await store.run { await store.remove(id) } }
                    })
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                .padding(24)
            }
            .transition(.opacity)
        }
    }

    private var ticking: Bool { store.state?.tasks.contains { $0.keepOpenUntil != nil } ?? false }

    private func page(_ all: TasksState) -> some View {
        // Lane TK: the current project's tasks, or every project's (TKTasksProjectScope).
        let state = TKTasksProjectScope.shared.scoped(all)
        let now = max(clock, Date()).timeIntervalSince1970 * 1000
        let crm = state.tasks.filter { !$0.local }
        var crmState = state
        crmState.tasks = crm
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                TKTasksProjectBar()
                header(state)
                if let problem = store.problem {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(TaskTone.input)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                if creating {
                    LocalTaskForm(state: state, busy: store.busy) { draft in
                        Task {
                            var input = (try? draft.payload().get()) ?? [:]
                            if input.isEmpty { input = ["title": draft.title] }
                            if await store.run({ await store.create(input) }) { creating = false }
                        }
                    } onCancel: {
                        creating = false
                        store.problem = nil
                    }
                }
                GoalsSection(goals: state.goals, busy: store.busy, creating: creatingGoal) { open in
                    creatingGoal = open
                    if !open { store.problem = nil }
                }
                VStack(alignment: .leading, spacing: 12) {
                    TasksHeading("Your tasks")
                    MyWorkView(model: myWork, state: state, now: now)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Your tasks")
                if !crm.isEmpty || !state.connections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        TasksHeading("From your CRM")
                        if crm.isEmpty {
                            Text("No tasks from your CRM yet. They appear here when it gives work to Hoot or an agent.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            CrmTasksBodyView(state: crmState, now: now, busy: store.busy, heading: nil, detailed: true) { id in
                                Task { await store.run { await store.closeSession(id) } }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("From your CRM")
                }
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ state: TasksState) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(TasksRules.facts(state), id: \.self) { fact in
                    Text(fact).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if !creating {
                    Button("New task") { creating = true }
                }
                if !creatingGoal {
                    Button("New goal") { creatingGoal = true }
                }
                Button("Agents and connections") { TasksSettingsLink.open() }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }
}

/// Opens Settings at the Tasks section, where agents and connections live — as the
/// page's "Agents and connections" does (`onOpenSettings('tasks')`).
@MainActor
enum TasksSettingsLink {
    static func open() {
        let app = AppModel.shared
        app.requestSettings()
        Task { @MainActor in
            // The Settings window loads its page first; then show the Tasks section.
            for _ in 0..<50 {
                if app.settingsReady {
                    app.selectSettingsSection("tasks")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - Pieces the Tasks screens share

/// The section heading, as `.tasks-page-heading` draws it.
struct TasksHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
}

/// The app's status colours (tokens.css), light and dark.
enum TaskTone {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let idle = dynamic(light: 0x666666, dark: 0x8F8F8F)
    static let working = dynamic(light: 0x1667C8, dark: 0x64A6E8)
    static let waiting = dynamic(light: 0x8F5800, dark: 0xDDB04A)
    static let input = dynamic(light: 0xB83C08, dark: 0xF0913F)
    static let completed = dynamic(light: 0x19714A, dark: 0x5FBF95)
    static let accent = Color.accentColor

    /// A status's ring and pill colour (MyWork.css `--mw-tone`).
    static func status(_ status: String) -> Color {
        switch TaskList.statusTone(status) {
        case "done": completed
        case "stuck": input
        case "progress": accent
        case "working": working
        default: idle
        }
    }

    /// A priority's flag colour (`--mw-flag`).
    static func priority(_ priority: String?) -> Color {
        switch priority {
        case "Critical": input
        case "High": waiting
        case "Medium": accent
        case "Low": idle
        default: .secondary
        }
    }
}

/// A row that wraps onto the next line when it runs out of room, as the page's
/// `flex-wrap` rows do.
struct TasksFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A text button in the accent colour, as `.mw-link` draws it.
struct TasksLinkButton: View {
    let title: String
    var help: String?
    let action: () -> Void

    init(_ title: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .help(help ?? "")
    }
}

/// A labelled field of the page's forms: the label above, the control under it.
struct TasksField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            content
        }
    }
}

/// A multi-line box with a placeholder, as the forms' `<textarea>`.
struct TasksTextArea: View {
    @Binding var text: String
    var placeholder = ""
    var limit = Int.max
    var minHeight: CGFloat = 64

    var body: some View {
        TextEditor(text: Binding(get: { text }, set: { text = String($0.prefix(limit)) }))
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(4)
            .frame(minHeight: minHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            .overlay(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.horizontal, 9).padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// The boxed forms (`.tasks-local-form`).
struct TasksFormBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

// MARK: - New task (LocalTaskForm)

/// New or edited: title, details, folder — and for a new one, who has it, its
/// status and the goal it serves.
struct LocalTaskForm: View {
    let state: TasksState
    let busy: Bool
    let task: TaskRow?
    let onSave: (LocalDraft) -> Void
    let onCancel: () -> Void
    @State private var draft: LocalDraft

    init(state: TasksState, busy: Bool, task: TaskRow? = nil, onSave: @escaping (LocalDraft) -> Void, onCancel: @escaping () -> Void) {
        self.state = state
        self.busy = busy
        self.task = task
        self.onSave = onSave
        self.onCancel = onCancel
        var initial = LocalDraft(task, statuses: state.localStatuses)
        if task == nil { initial.project = TKTasksProjectScope.shared.newTaskProject }
        _draft = State(initialValue: initial)
    }

    var body: some View {
        let fresh = task == nil
        let goals = Goals.options(state.goals)
        TasksFormBox {
            TasksField("Title") {
                TextField("", text: Binding(get: { draft.title }, set: { draft.title = String($0.prefix(300)) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityLabel("Title")
            }
            TasksField("Details") { TasksTextArea(text: $draft.instructions) }
            TasksField("Project folder") {
                TextField("Needed when an agent works on it, e.g. /Users/you/Projects/app", text: $draft.project)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit(save)
                    .accessibilityLabel("Project folder")
            }
            if fresh {
                HStack(alignment: .top, spacing: 12) {
                    TasksField("Assigned to") {
                        Picker("Assigned to", selection: $draft.assignee) {
                            ForEach(TasksRules.assigneeChoices(state.agents), id: \.id) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden()
                    }
                    TasksField("Status") {
                        Picker("Status", selection: $draft.status) {
                            ForEach(state.localStatuses, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
            }
            if fresh && !goals.isEmpty {
                TasksField("Goal") {
                    Picker("Goal", selection: $draft.goalId) {
                        Text("No goal").tag("")
                        ForEach(goals, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }
            HStack(spacing: 8) {
                Button(fresh ? "Add task" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .disabled(busy)
        // The form's name is the group's only; each control keeps its own (walk 5).
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fresh ? "New task" : "Edit \(task?.title ?? "")")
    }

    private func save() {
        guard !busy, !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(draft)
    }
}

// MARK: - Goals

/// Goals, on the Tasks page: what your tasks are for, each with how far its tasks
/// have got, drawn as a tree (src/renderer/tasks/Goals.tsx).
struct GoalsSection: View {
    let goals: [GoalRow]
    let busy: Bool
    let creating: Bool
    let onCreating: (Bool) -> Void
    /// Which goal's form is open: its id, or `under:<id>` for a new goal beneath one.
    @State private var editing: String?
    @State private var removing: String?
    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        if !goals.isEmpty || creating {
            VStack(alignment: .leading, spacing: 8) {
                TasksHeading("Goals")
                if creating {
                    GoalForm(goal: nil, goals: goals, parentId: "", busy: busy) { draft in
                        Task { if await save(draft, id: nil) { onCreating(false) } }
                    } onCancel: { onCreating(false) }
                }
                if !goals.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Goals.tree(goals), id: \.goal.id) { entry in
                            row(entry.goal, depth: entry.depth)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Goals")
        }
    }

    private func save(_ draft: GoalDraft, id: String?) async -> Bool {
        switch Goals.payload(draft, id: id) {
        case .failure(let problem):
            return await store.run { .refused(problem.message) }
        case .success(let payload):
            return await store.run { await store.saveGoal(payload) }
        }
    }

    private func row(_ goal: GoalRow, depth: Int) -> some View {
        let progress = goal.progress
        let line = Goals.progressLine(progress)
        return VStack(alignment: .leading, spacing: 6) {
            if editing == goal.id {
                GoalForm(goal: goal, goals: goals, parentId: goal.parentId ?? "", busy: busy) { draft in
                    Task { if await save(draft, id: goal.id) { editing = nil } }
                } onCancel: { editing = nil }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(goal.title)
                            .font(.body.weight(.medium))
                            .strikethrough(goal.status == .cancelled)
                            .foregroundStyle(goal.status == .achieved ? TaskTone.completed
                                : goal.status == .cancelled ? Color(nsColor: .tertiaryLabelColor)
                                : goal.status == .planned ? Color.secondary : Color.primary)
                        if !goal.description.isEmpty {
                            Text(goal.description).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(progress.stalled > 0 ? TaskTone.input : Color(nsColor: .tertiaryLabelColor))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    GoalMeter(share: Goals.share(progress))
                        .accessibilityLabel("\(goal.title): \(line)")
                    HStack(spacing: 8) {
                        Picker("Status of the goal \(goal.title)", selection: Binding(
                            get: { goal.status },
                            set: { status in Task { await store.run { await store.saveGoal(["id": goal.id, "status": status.rawValue]) } } }
                        )) {
                            ForEach(GoalStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(busy)
                        TasksLinkButton("Add a goal under it") { editing = "under:\(goal.id)" }.disabled(busy)
                        TasksLinkButton("Edit") { editing = goal.id }.disabled(busy)
                        if removing == goal.id {
                            Button("Remove it") {
                                removing = nil
                                Task { await store.run { await store.removeGoal(goal.id) } }
                            }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                            TasksLinkButton("Keep it") { removing = nil }
                        } else {
                            TasksLinkButton("Remove", help: "Its tasks and the goals under it move up to the goal above it.") {
                                removing = goal.id
                            }
                            .disabled(busy)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
            if editing == "under:\(goal.id)" {
                GoalForm(goal: nil, goals: goals, parentId: goal.id, busy: busy) { draft in
                    Task { if await save(draft, id: nil) { editing = nil } }
                } onCancel: { editing = nil }
            }
        }
        .padding(.leading, CGFloat(depth) * 20)
    }
}

/// The 6-point bar under a goal (`.goals-meter`), filled to the done share.
struct GoalMeter: View {
    let share: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(TaskTone.completed).frame(width: proxy.size.width * CGFloat(share) / 100)
            }
        }
        .frame(width: 120, height: 6)
        .accessibilityElement()
        .accessibilityValue("\(share)%")
    }
}

/// New or edited: title, description, status, and the goal it serves.
struct GoalForm: View {
    let goal: GoalRow?
    let goals: [GoalRow]
    let busy: Bool
    let onSave: (GoalDraft) -> Void
    let onCancel: () -> Void
    @State private var draft: GoalDraft

    init(goal: GoalRow?, goals: [GoalRow], parentId: String, busy: Bool, onSave: @escaping (GoalDraft) -> Void,
         onCancel: @escaping () -> Void) {
        self.goal = goal
        self.goals = goals
        self.busy = busy
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: GoalDraft(goal, parentId: parentId))
    }

    var body: some View {
        let parents = Goals.options(Goals.parentChoices(goals, id: goal?.id))
        TasksFormBox {
            TasksField("Goal") {
                TextField("What the work is for", text: Binding(get: { draft.title }, set: { draft.title = String($0.prefix(200)) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
            }
            TasksField("Description") {
                TasksTextArea(text: $draft.description,
                              placeholder: "Why it matters and what done looks like. Every agent working toward it reads this.",
                              limit: 4000)
            }
            HStack(alignment: .top, spacing: 12) {
                TasksField("Status") {
                    Picker("Status", selection: $draft.status) {
                        ForEach(GoalStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                }
                TasksField("Part of") {
                    Picker("Part of", selection: $draft.parentId) {
                        Text("No bigger goal").tag("")
                        ForEach(parents, id: \.id) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }
            HStack(spacing: 8) {
                Button(goal == nil ? "Add goal" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .disabled(busy)
        .accessibilityLabel(goal == nil ? "New goal" : "Edit the goal \(goal?.title ?? "")")
    }

    private func save() {
        guard !busy, !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        onSave(draft)
    }
}

// MARK: - From your CRM (dashboard/CrmTasks.tsx)

/// The read-only mirror of what this app is doing about each task a CRM sent
/// (dashboard/CrmTasks.tsx `CrmTasksBody`), drawn only on the Tasks page — the web
/// mounts it nowhere else.
struct CrmTasksBodyView: View {
    let state: TasksState
    let now: Double
    var busy = false
    var problem: String?
    /// Nil on a page that already has the title.
    var heading: String? = "CRM tasks"
    /// Each task's CRM id, project, check state and last change too — the Tasks page.
    var detailed = false
    var onCloseSession: ((String) -> Void)?

    var body: some View {
        let summary = CrmMirror.summary(state.tasks)
        VStack(alignment: .leading, spacing: 8) {
            if heading != nil || !summary.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let heading { TasksHeading(heading) }
                    if !summary.isEmpty { Text(summary).font(.callout).foregroundStyle(.secondary) }
                }
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(TaskTone.input)
            }
            if state.tasks.isEmpty {
                Text("No tasks from your CRM yet. They appear here as it sends them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(state.tasks) { task in row(task) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CRM tasks")
    }

    private func row(_ task: TaskRow) -> some View {
        let minutes = TasksRules.keptOpenMinutes(task.keepOpenUntil, now: now)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.body.weight(.medium))
                HStack(spacing: 10) {
                    Text(task.agent)
                    if !task.crmStatus.isEmpty {
                        Text(task.crmStatus)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .help("Status in the CRM")
                    }
                    let process = TasksRules.processLabel(task.process)
                    if !process.isEmpty {
                        Text(process).foregroundStyle(task.process == .running ? TaskTone.working : Color.secondary)
                    }
                    if let minutes { Text("kept open for \(minutes) min") }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                if detailed {
                    HStack(spacing: 10) {
                        Text(task.externalTaskId).help("The task’s id in the CRM")
                        Text(task.project).help("Project folder")
                        Text(CrmMirror.checkLabel(task.verified))
                        Text("changed \(CrmMirror.agoLabel(task.updatedAt, now: now))")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if minutes != nil, let onCloseSession {
                Button("Close session") { onCloseSession(task.id) }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .help("Close the finished session now. Its conversation can still be resumed.")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
