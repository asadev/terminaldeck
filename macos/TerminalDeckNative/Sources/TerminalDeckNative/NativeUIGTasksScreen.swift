import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Round-two Tasks layout. All reads, changes, project scope and task relations
/// still use the existing TasksStore, TK and TAG implementations.
struct NativeUIGTasksScreen: View {
    @State private var store = TasksStore.shared
    @State private var myWork = MyWorkModel()
    @State private var section = UIGTasksSection.work
    @State private var creatingTask = false
    @State private var creatingGoal = false
    @State private var editingGoal = false
    @State private var clock = Date()

    private var app: AppModel { AppModel.shared }
    private var ticking: Bool { store.state?.tasks.contains { $0.keepOpenUntil != nil } ?? false }
    private var hasOpenForm: Bool { creatingTask || creatingGoal || editingGoal }

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                NativeTAGTasksLoading()
            case .failed:
                NativePageEmpty(symbol: "checklist", title: "Tasks could not be read",
                    action: PageEmptyAction(label: "Try again", perform: { store.reload() })) {
                    Text("Terminal Deck did not answer. Try again in a moment.")
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
            guard let request = store.openRequest else { return }
            myWork.open = request.id
            if let task = store.state?.tasks.first(where: { $0.id == request.id }) {
                // Keep an unfinished form mounted while linked work opens over it.
                if !hasOpenForm { section = task.local ? .work : .crm }
                myWork.trashOpen = false
            }
            store.clearOpenRequest()
        }
        .task(id: ticking) {
            // Only the visible kept-open countdown needs time-based refreshes.
            guard ticking else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                clock = Date()
            }
        }
    }

    private func page(_ all: TasksState) -> some View {
        let state = TKTasksProjectScope.shared.scoped(all)
        let now = max(clock, Date()).timeIntervalSince1970 * 1000
        let sections = UIGTasksPresentation.sections(state)
        return VStack(alignment: .leading, spacing: 12) {
            TKTasksProjectBar()
                .disabled(hasOpenForm)
                .help(hasOpenForm ? "Save or cancel the open form before changing project scope." : "")
            navigation(sections: sections)
            Divider()
            if let problem = store.problem {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    Text(problem).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.problem = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss task error")
                }
                .accessibilityAddTraits(.updatesFrequently)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case .work:
                        if creatingTask { taskForm(state) }
                        NativeUIGTasksWorkView(model: myWork, state: state, now: now)
                    case .goals:
                        if state.goals.isEmpty && !creatingGoal && !editingGoal {
                            NativePageEmpty(symbol: "target", title: "No goals yet") {
                                Text("Use New goal to add one, then link the tasks that help you finish it.")
                            }
                        } else {
                            NativeUIGTasksGoalsView(goals: state.goals, busy: store.busy, creating: creatingGoal,
                                onEditingChanged: { editingGoal = $0 }) {
                                creatingGoal = $0
                                if !$0 { store.problem = nil }
                            }
                        }
                    case .crm:
                        crmContent(state, now: now)
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .onChange(of: sections) { _, offered in
            if !offered.contains(section) { section = .work }
        }
    }

    private func navigation(sections: [UIGTasksSection]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sectionButtons(sections)
                Spacer(minLength: 8)
                pageActions
            }
            VStack(alignment: .leading, spacing: 8) {
                sectionButtons(sections)
                HStack { Spacer(minLength: 8); pageActions }
            }
        }
        .controlSize(.small)
    }

    private func sectionButtons(_ sections: [UIGTasksSection]) -> some View {
        HStack(spacing: 4) {
            ForEach(sections, id: \.self) { destination in
                Button { section = destination } label: {
                    Text(destination.label)
                        .font(.callout.weight(section == destination ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(section == destination ? Color.primary : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(section == destination
                            ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear))
                }
                .buttonStyle(.plain)
                .disabled(hasOpenForm && section != destination)
                .help(hasOpenForm && section != destination ? "Save or cancel the open form before changing sections." : "")
                .accessibilityAddTraits(section == destination ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks sections")
    }

    private var pageActions: some View {
        HStack(spacing: 8) {
            if store.busy { ProgressView().controlSize(.small).accessibilityLabel("Saving task changes") }
            if section == .work && !creatingTask {
                Button("New task") { creatingTask = true }.disabled(store.busy)
            } else if section == .goals && !creatingGoal {
                Button("New goal") { creatingGoal = true }.disabled(store.busy || editingGoal)
            }
            Menu {
                Button("Agents and connections") { TasksSettingsLink.open() }
                Button("Refresh tasks") { store.reload() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Tasks options")
        }
        .buttonStyle(.bordered)
    }

    private func taskForm(_ state: TasksState) -> some View {
        LocalTaskForm(state: state, busy: store.busy) { draft in
            Task {
                switch draft.payload(agents: state.agents) {
                case .failure(let problem):
                    store.problem = problem.message
                case .success(let input):
                    if await store.run({ await store.create(input) }) { creatingTask = false }
                }
            }
        } onCancel: {
            creatingTask = false
            store.problem = nil
        }
    }

    @ViewBuilder private func crmContent(_ state: TasksState, now: Double) -> some View {
        let tasks = state.tasks.filter { !$0.local }
        if tasks.isEmpty {
            NativePageEmpty(symbol: "tray", title: "No tasks from your CRM yet",
                action: PageEmptyAction(label: "Agents and connections", perform: { TasksSettingsLink.open() })) {
                Text("They appear here when your CRM gives work to Hoot or an agent.")
            }
        } else {
            let crmState: TasksState = {
                var result = state
                result.tasks = tasks
                return result
            }()
            CrmTasksBodyView(state: crmState, now: now, busy: store.busy, heading: nil, detailed: true) { id in
                Task { await store.run { await store.closeSession(id) } }
            }
        }
    }

    @ViewBuilder private var popup: some View {
        if let state = store.state, let id = myWork.open, let task = state.tasks.first(where: { $0.id == id }) {
            let order = myWork.order(TKTasksProjectScope.shared.scoped(state),
                                     now: Date().timeIntervalSince1970 * 1000)
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { myWork.open = nil }
                Group {
                    if task.local {
                        NativeTaskPopup(task: task, tasks: state.tasks.filter(\.local), linkedTasks: state.tasks,
                            siblings: order.contains(task.id) ? order : [task.id], agents: state.agents,
                            onNavigate: { store.openTask($0) }, onClose: { myWork.open = nil },
                            onDelete: { id in
                                myWork.open = nil
                                Task { await store.run { await store.remove(id) } }
                            })
                    } else {
                        NativeTAGExternalTaskDetail(task: task, tasks: state.tasks,
                                                   onOpen: { store.openTask($0) }, onClose: { myWork.open = nil })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                .padding(24)
            }
            .transition(.opacity)
        }
    }
}
