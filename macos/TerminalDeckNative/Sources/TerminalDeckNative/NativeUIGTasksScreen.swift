import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Round-two Tasks layout. All reads, changes, project scope and task relations
/// still use the existing TasksStore, TK and TAG implementations.
struct NativeUIGTasksScreen: View {
    @State private var store = TasksStore.shared
    @State private var myWork = MyWorkModel.shared
    @AppStorage("page.tasks.section21") private var section = UIGTasksSection.work
    /// The one create card (NativeTaskPopupCreate), open over the page; nil when closed.
    @State private var creatingTask: TaskCreatePreset?
    @State private var creatingGoal = false
    @State private var editingGoal = false
    @State private var clock = Date()
    @State private var connected = ConnectedTasksStore.shared

    private var app: AppModel { AppModel.shared }
    private var ticking: Bool { store.state?.tasks.contains { $0.keepOpenUntil != nil } ?? false }
    private var hasOpenForm: Bool { creatingGoal || editingGoal }

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                NativeTAGTasksLoading()
            case .failed:
                NativePageEmpty(symbol: "checklist", title: "Tasks could not be read",
                    action: PageEmptyAction(label: "Try again", autoRetry: true, perform: { store.reload() })) {
                    Text("Terminal Deck did not answer. Try again in a moment.")
                }
            case .ready(let state):
                page(state)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .overlay { popup }
        .overlay { NativeConnectedTaskOverlay() }
        .taskCreatePopup($creatingTask)
        .task(id: app.canRun) { store.start(); connected.start() }
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
        // Connected task systems get their own section, named after the system when there is one.
        let sections = UIGTasksPresentation.sections(state) + (connected.systems.isEmpty ? [] : [.connected])
        return VStack(alignment: .leading, spacing: 12) {
            Text("Tasks created in Terminal Deck and tasks from connected systems.")
                .font(.callout).foregroundStyle(.secondary)
            TKTasksProjectBar()
                .disabled(hasOpenForm)
                .help(hasOpenForm ? "Save or cancel the open form before changing project scope." : "")
            navigation(sections: sections)
            Divider()
            if let problem = store.problem {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    Text(problem).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    Button { store.problem = nil } label: { Image(systemName: "xmark").frame(width: 28, height: 28).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss task error")
                }
                .accessibilityAddTraits(.updatesFrequently)
            }
            if section == .work {
                // 13 Oct: the main list scrolls under its own toolbar, so the controls stay in reach.
                NativeUIGTasksWorkView(model: myWork, state: state, now: now)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch section {
                    case .work:
                        EmptyView()
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
                    case .connected:
                        NativeConnectedTasksSection(now: max(clock, Date()))
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
        }
        .frame(maxWidth: 1120, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .top)
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
                    Text(destination == .connected && connected.systems.count == 1 ? connected.systems[0].name + " tasks" : destination.label)
                        .font(.callout.weight(section == destination ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .foregroundStyle(section == destination ? Color.primary : Color.secondary)
                        .background(RoundedRectangle(cornerRadius: 6).fill(section == destination
                            ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear))
                        .frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(hasOpenForm && section != destination)
                .help(hasOpenForm && section != destination ? "Save or cancel the open form before changing sections." : "")
                .accessibilityAddTraits(section == destination ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks sections")
        .nativePageDrag(ScreenRef(kind: .panel, id: "tasks"), title: "Tasks")
    }

    private var pageActions: some View {
        HStack(spacing: 8) {
            if store.busy { ProgressView().controlSize(.small).accessibilityLabel("Saving task changes") }
            if section == .work {
                Button("New task") { creatingTask = TaskCreateEntry.newTaskButton.preset }
                    .buttonStyle(.borderedProminent) // the page's one main action: blue
                    .disabled(store.busy)
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
            if section != .work { NativePagePopoutButton(ref: ScreenRef(kind: .panel, id: "tasks"), enabled: !hasOpenForm) }
        }
        .buttonStyle(.bordered)
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
