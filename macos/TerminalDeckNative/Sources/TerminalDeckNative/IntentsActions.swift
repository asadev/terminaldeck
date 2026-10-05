import AppIntents
import SwiftUI
import TerminalDeckNativeCore

// Siri / Shortcuts (lane R): what Siri, Shortcuts and Spotlight can ask
// Terminal Deck to do. Each runs in this app's process; with the app closed the
// system launches it in the background (the window opens behind whatever is in
// front) and the intent waits for the engine within its budget.

// MARK: - Ask Hoot

struct AskHootIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Hoot"
    static let description = IntentDescription("Asks Hoot, Terminal Deck's assistant, a question and tells you its answer.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Question", requestValueDialog: "What do you want to ask Hoot?")
    var question: String

    static var parameterSummary: some ParameterSummary {
        Summary("Ask Hoot \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        guard let text = IntentHoot.question(question) else {
            throw $question.needsValueError("What do you want to ask Hoot?")
        }
        let budget = IntentBudget(IntentDeadline.askBudget)
        let ask = HootAsk.start(question: text)
        guard let task = ask.task else { throw IntentError("Hoot couldn't be asked.") }
        switch await IntentDeadline.wait(for: task, upTo: budget.remaining()) {
        case .finished(.answer(let answer)):
            return .result(value: answer.detailText, dialog: "\(answer.spoken)", view: IntentDetailView(answer: answer))
        case .finished(.failed(let problem)):
            throw IntentError(problem)
        case .timedOut:
            ask.deferToNotification()
            let answer = IntentHoot.deferred(assistant: ask.assistant, asked: ask.asked)
            return .result(value: answer.detailText, dialog: "\(answer.spoken)", view: IntentDetailView(answer: answer))
        }
    }
}

// MARK: - What needs me

struct WhatNeedsMeIntent: AppIntent {
    static let title: LocalizedStringResource = "What Needs Me"
    static let description = IntentDescription("Tells you which sessions are waiting for your answer or have something new, which tasks stalled or were handed to you, and new alerts.")
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        let budget = IntentBudget(IntentDeadline.readBudget)
        try await IntentsEngine.ready(budget)
        // The sidebar the window draws: drawn shortly after the engine is up.
        var needs = await IntentsEngine.sidebar(within: budget.remaining(cap: .seconds(8)))
            .map(IntentNeeds.from(sidebar:)) ?? IntentNeeds(sessions: nil)
        needs.tasks = try? await IntentsEngine.tasksAndGoals().tasks
        let answer = needs.answer()
        return .result(value: answer.detailText, dialog: "\(answer.spoken)", view: IntentDetailView(answer: answer))
    }
}

// MARK: - Add a task

struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task to Terminal Deck's Tasks, optionally in a project.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Title", requestValueDialog: "What's the task?")
    var title: String

    @Parameter(title: "Project")
    var project: ProjectEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to Tasks") {
            \.$project
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<TaskEntity?> & ProvidesDialog {
        let payload: [String: String]
        switch IntentTasks.newTask(title: title, projectPath: project?.id) {
        case .success(let made): payload = made
        case .failure(.plain(let line)) where line == "The task needs a title.":
            throw $title.needsValueError("What's the task?")
        case .failure(let problem): throw IntentError(problem)
        }
        try await IntentsEngine.ready(IntentBudget(IntentDeadline.readBudget))
        // The Tasks page's own channel, with the Tasks page's own defaults.
        let answer = try await IntentsEngine.invoke("tasks:local-create", [payload])
        if let refusal = IntentTasks.refusal(answer) { throw IntentError(refusal) }
        let made = IntentTasks.created(title: payload["title"] ?? title, in: answer).map(TaskEntity.init)
        let said = IntentTasks.added(payload["title"] ?? title, projectName: project?.name)
        return .result(value: made, dialog: "\(said.spoken)")
    }
}

// MARK: - Start a session

struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Session"
    static let description = IntentDescription("Starts a new session in a project — with your default agent, or the one you pick.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Project", requestValueDialog: "Which project?")
    var project: ProjectEntity

    @Parameter(title: "Agent", description: "Leave empty for your default agent (Settings → General).")
    var agent: AgentOption?

    static var parameterSummary: some ParameterSummary {
        Summary("Start a session in \(\.$project)") {
            \.$agent
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SessionEntity> & ProvidesDialog {
        let budget = IntentBudget(IntentDeadline.readBudget)
        try await IntentsEngine.ready(budget)
        let model = IntentsEngine.model
        let path = project.id
        let name = project.name
        let defaultAgent = await IntentsEngine.defaultAgent()
        let chosen = agent?.agent

        // The default agent: exactly the sidebar's ＋ on the project's heading,
        // so the session opens as a tab in the main window.
        if chosen == nil || chosen == defaultAgent,
           await IntentsEngine.pageReady(within: budget.remaining(cap: .seconds(8))),
           let heading = model.sidebar?.projects.first(where: { $0.id == path }) {
            let before = Set(heading.sessions.map(\.id))
            model.newSession(in: path)
            IntentsEngine.bringForward()
            _ = await IntentDeadline.until(budget.remaining(cap: .seconds(10))) {
                await MainActor.run { StartSessionIntent.newSession(in: path, besides: before) != nil }
            }
            if let row = StartSessionIntent.newSession(in: path, besides: before), row.status != "held" {
                let who = (chosen ?? defaultAgent)?.spokenName
                let line = who.map { "Started \($0) in \(name)." } ?? "Started a session in \(name)."
                return .result(value: SessionEntity(id: row.id, title: row.title, project: name, status: row.status ?? ""),
                               dialog: "\(line)")
            }
            throw IntentError("The session in \(name) didn't start. Terminal Deck's sidebar says why.")
        }

        // A chosen agent: the same request the window sends, then the session on screen.
        var request: [String: Any] = ["cwd": path, "cols": 100, "rows": 30]
        if let provider = (chosen ?? defaultAgent)?.providerId { request["provider"] = provider }
        let raw = try await IntentsEngine.invoke("session:create", [request])
        guard let meta = raw as? [String: Any], let id = meta["id"] as? String else {
            throw IntentError("The session in \(name) didn't start.")
        }
        let title = meta["title"] as? String ?? name
        model.openScreenWindow(ScreenRef(kind: .session, id: id), title: title)
        IntentsEngine.bringForward()
        let who = (chosen ?? defaultAgent)?.spokenName ?? "a session"
        let line = "Started \(who) in \(name)."
        return .result(value: SessionEntity(id: id, title: title, project: name, status: ""), dialog: "\(line)")
    }

    @MainActor
    private static func newSession(in path: String, besides before: Set<String>) -> SidebarItem? {
        AppModel.shared.sidebar?.projects.first(where: { $0.id == path })?.sessions
            .first { $0.kind == .session && !before.contains($0.id) }
    }
}

// MARK: - Open a project / Open Terminal Deck

/// "Open <project> in Terminal Deck": the app in front, the project's newest
/// session shown (or its heading unfolded when it has none). On macOS 27 it is
/// the system's own Open action for a project (`.system.open`), so Siri and
/// Spotlight can open one by name; the schema does not exist on macOS 26.
///
/// Built with an older SDK (Swift 6.3 = Xcode 26, the release machine's, has no
/// `.system.open`) it is a plain intent with the same phrases, doing the same work.
#if compiler(>=6.4)
@available(macOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenProjectIntent: OpenIntent {
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Project")
    var target: ProjectEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await OpenProject.show(target)
        return .result()
    }
}
#else
struct OpenProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Project"
    static let description = IntentDescription("Shows a project's newest session in Terminal Deck.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @Parameter(title: "Project")
    var target: ProjectEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        try await OpenProject.show(target)
        return .result()
    }
}
#endif

/// The work of `OpenProjectIntent`, whichever SDK built it.
enum OpenProject {
    @MainActor
    static func show(_ target: ProjectEntity) async throws {
        let budget = IntentBudget(IntentDeadline.readBudget)
        IntentsEngine.bringForward()
        try await IntentsEngine.ready(budget)
        guard await IntentsEngine.pageReady(within: budget.remaining(cap: .seconds(8))) else {
            throw IntentError(.starting)
        }
        let model = IntentsEngine.model
        guard let heading = model.sidebar?.projects.first(where: { $0.id == target.id }) else {
            throw IntentError("\(target.name) isn't open in Terminal Deck. Add the folder in the app first.")
        }
        if !heading.expanded { model.setExpanded(heading.id, true) }
        if let session = heading.sessions.last(where: { $0.kind == .session }) {
            model.select(session.id)
        }
    }
}

struct OpenTerminalDeckIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Terminal Deck"
    static let description = IntentDescription("Brings Terminal Deck to the front.")
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentsEngine.bringForward()
        return .result()
    }
}

// MARK: - Goal status

struct GoalStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Goal Status"
    static let description = IntentDescription("Tells you how far a goal's tasks have got: done, stalled, blocked.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Goal", requestValueDialog: "Which goal?")
    var goal: GoalEntity

    static var parameterSummary: some ParameterSummary {
        Summary("How is \(\.$goal) going")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog & ShowsSnippetView {
        try await IntentsEngine.ready(IntentBudget(IntentDeadline.readBudget))
        let (tasks, goals) = try await IntentsEngine.tasksAndGoals()
        guard let found = goals.first(where: { $0.id == goal.id }) else {
            throw IntentError("That goal isn't in Terminal Deck any more.")
        }
        let answer = IntentTasks.goalAnswer(found, tasks: tasks)
        return .result(value: answer.detailText, dialog: "\(answer.spoken)", view: IntentDetailView(answer: answer))
    }
}

// MARK: - The lines under Siri's answer

struct IntentDetailView: View {
    let answer: IntentAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(answer.detail.prefix(20).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }
}
