import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Tasks, drawn in Swift: the page in the sidebar for your own tasks and the work a
/// CRM gives Hoot and the task agents (src/renderer/tasks/TasksPage.tsx) — the same
/// facts and buttons at the top, New task (the one create card) and the New goal form, Goals, Your tasks
/// (MyWork) and From your CRM, in that order, with the same empty, loading and
/// error states. Every read and change goes through `TasksStore` on the page's own
/// `tasks:*` channels.

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
        NativeSessionButton(title, action: action)
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
        NativeSessionTextEditor(text: Binding(get: { text }, set: { text = String($0.prefix(limit)) }))
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

// MARK: - Goals

/// Goals, on the Tasks page: what your tasks are for, each with how far its tasks
/// have got, drawn as a tree (src/renderer/tasks/Goals.tsx).

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
                NativeSessionTextField("What the work is for", text: Binding(get: { draft.title }, set: { draft.title = String($0.prefix(200)) }))
                    .textFieldStyle(.roundedBorder)
                    .sessionOnSubmit(save)
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
                NativeSessionButton(goal == nil ? "Add goal" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                NativeSessionButton("Cancel", action: onCancel)
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
                NativeSessionButton { TasksStore.shared.openTask(task.id) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                    Text(task.title).font(.body.weight(.medium)).multilineTextAlignment(.leading)
                    Text(task.createdAt > 0 ? "Created " + TaskList.createdLabel(task.createdAt, today: TaskList.ymdOf(now)) : "Creation date unavailable")
                        .font(.caption).foregroundStyle(.secondary)
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
                    if task.keepAliveUntilClose == true { Text("kept open until you close it") }
                    else if let minutes { Text("kept open for \(minutes) min") }
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
                    }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(SIDEBARRowStyle()).accessibilityHint("Opens the task")
                NativeTAGTaskLinks(task: task, tasks: TasksStore.shared.state?.tasks ?? state.tasks, compact: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if minutes != nil || task.keepAliveUntilClose == true, let onCloseSession {
                NativeSessionButton("Close session") { onCloseSession(task.id) }
                    .buttonStyle(.bordered)
                    .disabled(busy)
                    .help("Close the finished session now. Its conversation can still be resumed.")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .contextMenu {
            NativeSessionButton("Open task") { TasksStore.shared.openTask(task.id) }
            if minutes != nil || task.keepAliveUntilClose == true, let onCloseSession {
                NativeSessionButton("Close session") { onCloseSession(task.id) }.disabled(busy)
            }
        }
    }
}
