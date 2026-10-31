import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Goal rows keep the existing form and progress rules, with secondary actions
/// folded into one menu instead of several controls beside every title.
struct NativeUIGTasksGoalsView: View {
    let goals: [GoalRow]
    let busy: Bool
    let creating: Bool
    var onEditingChanged: (Bool) -> Void = { _ in }
    let onCreating: (Bool) -> Void
    @State private var editing: GoalRow?
    @State private var addingUnder: GoalRow?
    @State private var editingChoices: [GoalRow] = []
    @State private var removing: GoalRow?
    private var store: TasksStore { TasksStore.shared }
    private var editorOpen: Bool { creating || editing != nil || addingUnder != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if creating {
                form(nil, parent: "") { onCreating(false) }
            }
            if let goal = editing {
                form(goal, parent: goal.parentId ?? "", choices: editingChoices) { editing = nil }
            }
            if let parent = addingUnder {
                form(nil, parent: parent.id, choices: editingChoices) { addingUnder = nil }
            }
            ForEach(Goals.tree(goals), id: \.goal.id) { entry in
                if editing?.id != entry.goal.id {
                    row(entry.goal)
                        .padding(.leading, CGFloat(entry.depth) * 16)
                }
            }
        }
        .confirmationDialog(removing.map { "Remove \($0.title)?" } ?? "Remove goal?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible) {
            if let goal = removing {
                Button("Remove goal", role: .destructive) {
                    Task {
                        if await store.run({ await store.removeGoal(goal.id) }) { removing = nil }
                    }
                }
            }
            Button("Keep goal", role: .cancel) { removing = nil }
        } message: {
            Text("Its tasks and the goals under it move to the goal above it.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Goals")
        .onChange(of: editorOpen, initial: true) { _, open in onEditingChanged(open) }
    }

    private func row(_ goal: GoalRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Button { edit(goal) } label: {
                    Text(goal.title).font(.body.weight(.medium))
                        .strikethrough(goal.status == .cancelled)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit goal")
                .disabled(busy || editorOpen)
                if !goal.description.isEmpty {
                    Text(goal.description).font(.callout).foregroundStyle(.secondary)
                }
                Text("\(goal.status.label) · \(Goals.progressLine(goal.progress))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            GoalMeter(share: Goals.share(goal.progress))
                .accessibilityLabel("\(goal.title): \(Goals.progressLine(goal.progress))")
            Menu {
                Button("Edit goal") { edit(goal) }
                Button("Add a goal under it") {
                    onEditingChanged(true)
                    editingChoices = goals
                    editing = nil
                    addingUnder = goal
                }
                Menu("Status") {
                    ForEach(GoalStatus.allCases, id: \.self) { status in
                        Button {
                            Task { await store.run { await store.saveGoal(["id": goal.id, "status": status.rawValue]) } }
                        } label: {
                            if status == goal.status { Label(status.label, systemImage: "checkmark") }
                            else { Text(status.label) }
                        }
                    }
                }
                Divider()
                Button("Remove goal…", role: .destructive) { removing = goal }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(goal.title)")
            .disabled(busy || editorOpen)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func edit(_ goal: GoalRow) {
        onEditingChanged(true)
        editingChoices = goals
        addingUnder = nil
        editing = goal
    }

    private func form(_ goal: GoalRow?, parent: String, choices: [GoalRow]? = nil,
                      onFinished: @escaping () -> Void) -> some View {
        GoalForm(goal: goal, goals: choices ?? goals, parentId: parent, busy: busy) { draft in
            Task {
                switch Goals.payload(draft, id: goal?.id) {
                case .failure(let problem):
                    store.problem = problem.message
                case .success(let input):
                    if await store.run({ await store.saveGoal(input) }) { onFinished() }
                }
            }
        } onCancel: {
            onFinished()
            store.problem = nil
        }
    }
}
