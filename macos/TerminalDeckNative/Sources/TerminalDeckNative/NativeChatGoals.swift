import SwiftUI
import TerminalDeckNativeCore

enum NativeChatGoals {
    static func context(_ goal: GoalRow) -> String {
        "App goal: \(goal.title)\nGoal ID: \(goal.id)\nStatus: \(goal.status.label)\nTask progress: \(Goals.progressLine(goal.progress))\n\(goal.description)\nThis is saved app goal context, not a provider goal budget or an instruction to change its status."
    }
    static func wire(_ goals: [GoalRow]) -> NativeRPCValue {
        .object([.init("scope", .string("Mac owner's saved app goals; task-based progress")), .init("providerGoal", .null),
            .init("managementTools", .string("tasks_goals / tasks_progress")), .init("goals", .array(goals.map { goal in
                .object([.init("id", .string(goal.id)), .init("title", .string(goal.title)), .init("description", .string(goal.description)), .init("status", .string(goal.status.rawValue)), .init("projectID", .string(goal.projectID)), .init("progress", .string(Goals.progressLine(goal.progress))), .init("totalTasks", .number(Double(goal.progress.total))), .init("doneTasks", .number(Double(goal.progress.done)))])
            }))])
    }
}
extension NativeHootChatModel {
    func goalTool(_ action: String, request: String?, goals: [GoalRow]? = nil) throws -> NativeRPCValue {
        if action == "read", goals == nil { TasksStore.shared.start() }
        if action == "open" {
            if request == "manage" {
                UserDefaults.standard.set(UIGTasksSection.goals.rawValue, forKey: "page.tasks.section21")
                AppModel.shared.select("tasks"); chatGoalsVisible = false
            } else { chatGoalsVisible = true; TasksStore.shared.start() }
        }
        if action == "close" { chatGoalsVisible = false }
        guard let goals = goals ?? TasksStore.shared.state?.goals else {
            if action == "insert" { throw NativeRPCError.invalidArguments("Goals are still loading or unavailable. Open Goals to read them.") }
            return NativeChatGoals.wire([]).setting("ready", .bool(false)).setting("status", .string("Goals are loading or unavailable; read again after opening Goals."))
        }
        if action == "insert" {
            guard let goal = goals.first(where: { $0.id == request }) else { throw NativeRPCError.invalidArguments("Choose a saved app goal ID.") }
            let text = NativeChatGoals.context(goal)
            try setDraftText(composerDraft.text.isEmpty ? text : composerDraft.text + "\n\n" + text)
        }
        return NativeChatGoals.wire(goals).setting("ready", .bool(true))
    }
}
struct NativeChatGoalsPopover: View {
    @Bindable var model: NativeHootChatModel
    @State private var problem: String?
    private var store: TasksStore { .shared }
    var body: some View {
        Color.clear
            .popover(isPresented: $model.chatGoalsVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved app goals").font(.headline)
                    Text("Progress comes from linked app tasks. Provider goal budgets and pause/resume are not reported by this Chat service.").font(.caption).foregroundStyle(.secondary)
                    switch store.phase {
                    case .loading: ProgressView("Reading saved goals…")
                    case .failed: Text("Goals could not be read."); Button("Try again") { store.reload() }
                    case .ready(let state):
                        ScrollView { LazyVStack(alignment: .leading, spacing: 12) {
                            if state.goals.isEmpty { Text("No saved goals yet.").foregroundStyle(.secondary) }
                            ForEach(state.goals) { goal in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(goal.title).font(.headline)
                                    Text("\(goal.status.label) · \(Goals.progressLine(goal.progress))").font(.caption)
                                    if !goal.description.isEmpty { Text(goal.description).font(.callout).lineLimit(4) }
                                    Button("Add goal context to draft") { run("insert", goal.id) }
                                        .disabled(model.readOnly || model.loading || model.changingConversation)
                                }
                            }
                        } }.frame(maxHeight: 320)
                    }
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    Button("Manage goals and linked tasks") { run("open", "manage") }
                }.padding(16).frame(width: 520)
            }
    }
    private func run(_ action: String, _ request: String) { do { _ = try model.goalTool(action, request: request); problem = nil } catch { problem = error.localizedDescription } }
}
