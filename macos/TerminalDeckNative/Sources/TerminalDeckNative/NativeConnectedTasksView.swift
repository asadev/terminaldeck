import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Tasks → a connected task system's own section: its tasks as the connected person sees
/// them, in piles, with the system's name on every row. A click opens the task read
/// fresh from the system; changes go back to it.
struct NativeConnectedTasksSection: View {
    @State private var store = ConnectedTasksStore.shared
    @State private var chosen: String?
    /// The scoped project's own task source (project settings "Task source"); opened first when it is connected.
    @State private var projectSource: String?
    @State private var pile = ConnectedTasksPile.all
    @State private var statuses: Set<String> = []
    @State private var search = ""
    @State private var showDone = false
    var now = Date()

    init(now: Date = Date()) { self.now = now }

    private var system: ConnectedTaskSystem? {
        ConnectedTasksSource.pick(chosen: chosen, projectSource: projectSource, systems: store.systems)
    }

    var body: some View {
        Group {
            if let system {
                content(system)
            } else if store.loaded {
                NativePageEmpty(symbol: "link", title: "No task system connected",
                    action: PageEmptyAction(label: "Connect a task system", perform: { TasksSettingsLink.open() })) {
                    Text("Connect a CRM or tracker in Settings → Tasks to see and work on its tasks here.")
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            store.start()
            if let system { arrive(system) }
        }
        .onChange(of: system?.id) { _, id in
            guard let id, let system = store.systems.first(where: { $0.id == id }) else { return }
            arrive(system)
        }
        .onDisappear { store.visible = nil }
        // SETTINGS-TRUTH rows 43/45: a project's task source feeds that project's Tasks page.
        .task(id: TKTasksProjectScope.shared.selectedProjectID) {
            chosen = nil
            projectSource = await ConnectedTasksSource.load(projectID: TKTasksProjectScope.shared.selectedProjectID)
        }
    }

    /// Opening the section reads the system when the last read is old.
    private func arrive(_ system: ConnectedTaskSystem) {
        store.visible = system.id
        if system.enabled, store.isStale(system.id), !store.refreshing.contains(system.id) {
            Task { await store.refresh(system.id) }
        }
    }

    @ViewBuilder private func content(_ system: ConnectedTaskSystem) -> some View {
        let list = store.lists[system.id]
        let rows = list?.tasks ?? []
        let today = ConnectedTasksFilter.today(now)
        let shown = ConnectedTasksFilter.apply(rows, pile: pile, statuses: statuses, search: search, showDone: showDone,
                                               doneStatus: system.doneStatus, today: today)
        let counts = ConnectedTasksFilter.counts(rows, doneStatus: system.doneStatus)
        VStack(alignment: .leading, spacing: 12) {
            header(system, list: list)
            if let problem = system.problem ?? store.problem {
                ConnectedTasksNotice(text: problem, tone: .error)
            }
            controls(system, counts: counts)
            if rows.isEmpty {
                NativePageEmpty(symbol: "tray", title: list?.refreshedAt == nil ? "Not read yet" : "No tasks here") {
                    Text(list?.refreshedAt == nil ? "Refresh reads your tasks from \(system.name)." : "\(system.name) has no tasks for you right now.")
                }
            } else if shown.isEmpty {
                Text("Nothing matches these filters.").foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 36) }
                        Button { store.open = (system.id, row.id) } label: {
                            ConnectedTaskRowView(row: row, system: system, handoff: list?.handoff(row.id), today: today)
                                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SIDEBARRowStyle())
                        .contextMenu {
                            Button("Open task") { store.open = (system.id, row.id) }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
                if let total = list?.total, total > rows.count {
                    Text("Showing the first \(rows.count) of \(total) from \(system.name).").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: shown.map(\.id), initial: true) { _, ids in store.order = ids }
    }

    private func header(_ system: ConnectedTaskSystem, list: ConnectedTaskList?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ConnectedTasksOrigin(name: system.name, large: true)
            if store.systems.count > 1 {
                Picker("System", selection: Binding(get: { system.id }, set: { chosen = $0 })) {
                    ForEach(store.systems) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(system.me.map { "As \($0.name)" } ?? system.host).font(.callout)
                Text(system.host + " · " + system.changes.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(ConnectedTasksFilter.freshness(list?.refreshedAt ?? system.refreshedAt, now: now.timeIntervalSince1970 * 1000))
                .font(.caption).foregroundStyle(.secondary)
            if store.refreshing.contains(system.id) {
                ProgressView().controlSize(.small).accessibilityLabel("Reading tasks from \(system.name)")
            }
            Button { Task { await store.refresh(system.id) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(store.refreshing.contains(system.id) || !system.enabled)
                .help(system.enabled ? "Read the tasks from \(system.name) again" : "This connection is switched off in Settings → Tasks")
        }
        .controlSize(.small)
    }

    private func controls(_ system: ConnectedTaskSystem, counts: [ConnectedTasksPile: Int]) -> some View {
        HStack(spacing: 10) {
            Picker("Pile", selection: $pile) {
                ForEach(ConnectedTasksPile.allCases, id: \.self) { pile in
                    Text("\(pile.label) \(counts[pile] ?? 0)").tag(pile)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Menu {
                ForEach(system.statuses, id: \.self) { status in
                    Toggle(status, isOn: Binding(get: { statuses.contains(status) }, set: { on in
                        if on { statuses.insert(status) } else { statuses.remove(status) }
                    }))
                }
                if !statuses.isEmpty { Divider(); Button("Any status") { statuses = [] } }
            } label: {
                Text(statuses.isEmpty ? "Any status" : statuses.sorted().joined(separator: ", "))
            }
            .fixedSize()
            .disabled(system.statuses.isEmpty)
            Toggle("Show done", isOn: $showDone).toggleStyle(.checkbox).disabled(!statuses.isEmpty)
            Spacer(minLength: 8)
            TextField("Search \(system.name)", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
        }
        .controlSize(.small)
    }

}

/// The opened connected task, drawn over the whole Tasks page (not inside its scroll): the
/// same task popup as your own tasks, answered by the connected system, with a strip for
/// handing it to an agent, and the bar that asks before anything is sent.
struct NativeConnectedTaskOverlay: View {
    @State private var store = ConnectedTasksStore.shared

    var body: some View {
        ZStack {
            if let open = store.open, let system = store.systems.first(where: { $0.id == open.system }), let list = store.lists[system.id],
               let row = list.tasks.first(where: { $0.id == open.task }) {
                Color.black.opacity(0.25).ignoresSafeArea().onTapGesture { store.open = nil }
                VStack(spacing: 0) {
                    ConnectedTaskStrip(system: system, row: row, handoff: list.handoff(row.id))
                    Divider()
                    NativeTaskPopup(task: row.taskRow(connection: system.id, refreshedAt: list.refreshedAt),
                                    tasks: list.tasks.map { $0.taskRow(connection: system.id, refreshedAt: list.refreshedAt) },
                                    linkedTasks: list.tasks.map { $0.taskRow(connection: system.id, refreshedAt: list.refreshedAt) },
                                    siblings: store.order.contains(row.id) ? store.order : [row.id], agents: TasksStore.shared.state?.agents ?? [],
                                    onNavigate: { store.open = (system.id, $0) }, onClose: { store.open = nil },
                                    onDelete: { id in
                                        store.open = nil
                                        Task {
                                            let answer = await store.popupCall(system.id, "deleteTask", [.string(id)])
                                            if answer["ok"].bool != true { store.problem = answer["error"].string }
                                            await store.refresh(system.id)
                                        }
                                    },
                                    connected: .init(connection: system.id, me: system.me?.id ?? "", createdBy: row.createdBy ?? (row.raisedByMe ? system.me?.id : nil),
                                                     team: list.people.map { BackendCrmPeople.toAssignee(.init(id: $0.id, name: $0.name)) }, link: row.url))
                }
                .id(open.system + "/" + open.task)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                .padding(24)
                .transition(.opacity)
            }
            if let ask = store.asking {
                VStack {
                    Spacer()
                    ConnectedTasksAskBar(ask: ask)
                        .frame(maxWidth: 640)
                        .padding(.bottom, 32)
                }
                .id(ask.id)
            }
        }
    }
}

/// Above the popup: where the task lives, and handing it to one of your task agents.
struct ConnectedTaskStrip: View {
    let system: ConnectedTaskSystem
    let row: ConnectedTaskRow
    let handoff: ConnectedTaskHandoff?
    @State private var markDone = false
    @State private var busy = false
    @State private var problem: String?
    private var store: ConnectedTasksStore { .shared }

    var body: some View {
        let agents = (TasksStore.shared.state?.agents ?? []).filter { $0.status == .active }
        let working = handoff.map { !$0.closed && !$0.posted } ?? false
        HStack(spacing: 10) {
            ConnectedTasksOrigin(name: system.name)
            Text(system.changes == .off ? "Read only" : system.changes == .ask ? "Asks before sending changes" : "Changes are sent as you make them")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let handoff {
                Label(handoff.line, systemImage: handoff.posted ? "checkmark.bubble" : "person.crop.circle.badge.clock")
                    .font(.caption).foregroundStyle(handoff.closed && !handoff.posted ? TaskTone.input : TaskTone.working).lineLimit(1)
            }
            if let problem { Text(problem).font(.caption).foregroundStyle(TaskTone.input).lineLimit(2) }
            if system.can("comment") {
                if system.can("status"), let done = system.doneStatus {
                    Toggle("Mark \(done) when it finishes", isOn: $markDone).toggleStyle(.checkbox).font(.caption)
                }
                Menu {
                    if agents.isEmpty { Text("No task agents yet — add one in Settings → Tasks") }
                    ForEach(agents) { agent in Button { hand(agent) } label: { DeckRowLabel(agent.name, image: DeckRowIcon.agent(id: agent.id)) } }
                } label: { Label("Hand to an agent", systemImage: "person.crop.circle.badge.plus") }
                .fixedSize()
                .disabled(busy || working || system.changes == .off)
                .help("A Terminal Deck agent works on it; its answer is posted back here as a comment.")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { markDone = system.markDone }
    }

    private func hand(_ agent: AgentProfile) {
        Task {
            busy = true; problem = nil
            defer { busy = false }
            var input: [String: Any] = ["agent": agent.id, "markDone": markDone]
            if let project = agent.defaultProject { input["project"] = project }
            var confirmed = system.changes == .allow
            for _ in 0..<2 {
                switch await store.call("hand", [system.id, row.id, input, confirmed]) {
                case .success: await store.reload(); return
                case .failure(let error) where error.code == "needs-confirmation" && !confirmed:
                    let yes: Bool = await withCheckedContinuation { done in
                        store.requestYes("Hand it to \(agent.name)? When it finishes, its answer is posted to \(system.name) as a comment" + (markDone ? " and the task is marked \(system.doneStatus ?? "done")." : "."), system: system.name) { done.resume(returning: $0) }
                    }
                    guard yes else { return }
                    confirmed = true
                case .failure(let error): problem = error.message; return
                }
            }
        }
    }
}

struct ConnectedTasksAskBar: View {
    let ask: ConnectedTasksStore.Ask
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.sentence).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(ask.destructive ? "Yes, do it" : "Send") { ConnectedTasksStore.shared.answer(.send) }
                    .buttonStyle(.borderedProminent).tint(ask.destructive ? TaskTone.input : .accentColor).keyboardShortcut(.defaultAction)
                if !ask.destructive { Button("Send and stop asking") { ConnectedTasksStore.shared.answer(.always) } }
                Button("Cancel") { ConnectedTasksStore.shared.answer(.cancel) }.keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.bar))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .accessibilityElement(children: .contain).accessibilityLabel("Confirm sending to \(ask.system)")
    }
}

/// The system's name, on every row and on the opened task: where this task lives.
struct ConnectedTasksOrigin: View {
    let name: String
    var large = false
    var body: some View {
        Label(name, systemImage: "link")
            .font(large ? .callout.weight(.semibold) : .caption2.weight(.medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, large ? 8 : 6).padding(.vertical, large ? 4 : 2)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("From \(name)")
            .help("This task lives in \(name). Changes made here are sent there.")
    }
}

struct ConnectedTasksNotice: View {
    enum Tone { case error, info }
    let text: String
    var tone = Tone.info
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .error ? "exclamationmark.circle" : "info.circle").foregroundStyle(tone == .error ? TaskTone.input : Color.secondary)
            Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill((tone == .error ? TaskTone.input : Color.secondary).opacity(0.08)))
    }
}

struct ConnectedTaskRowView: View {
    let row: ConnectedTaskRow
    let system: ConnectedTaskSystem
    let handoff: ConnectedTaskHandoff?
    let today: String

    var body: some View {
        let done = ConnectedTasksFilter.isDone(row, doneStatus: system.doneStatus)
        let due = ConnectedTasksFilter.due(row, today: today, doneStatus: system.doneStatus)
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(TaskTone.status(row.status ?? ""))
                .font(.body)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).lineLimit(2).strikethrough(done).foregroundStyle(done ? Color.secondary : Color.primary)
                Text("Created " + (row.createdAt.map { Self.short(String($0.prefix(10))) } ?? "—"))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ConnectedTasksOrigin(name: system.name)
                    if let board = row.board { chip(board) }
                    ForEach(row.labels.prefix(3), id: \.self) { chip($0) }
                    if row.labels.count > 3 { chip("+\(row.labels.count - 3)") }
                    if let handoff {
                        Label(handoff.line, systemImage: handoff.posted ? "checkmark.bubble" : "person.crop.circle.badge.clock")
                            .font(.caption2).foregroundStyle(handoff.problem != nil && handoff.closed ? TaskTone.input : TaskTone.working)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(row.assigneeName ?? "Unassigned").font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .trailing)
            Text(dueText(due)).font(.caption.monospacedDigit()).foregroundStyle(due == .overdue ? TaskTone.input : Color.secondary)
                .frame(width: 84, alignment: .trailing)
            Image(systemName: row.priority == nil ? "flag" : "flag.fill").font(.caption)
                .foregroundStyle(TaskTone.priority(row.priority)).opacity(row.priority == nil ? 0.25 : 1)
                .help(row.priority.map { "Priority: \($0)" } ?? "No priority")
            Text(row.status ?? "—").font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(TaskTone.status(row.status ?? "").opacity(0.15)))
                .foregroundStyle(TaskTone.status(row.status ?? ""))
                .frame(width: 104, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func dueText(_ due: ConnectedTasksDue) -> String {
        guard let date = row.dueDate else { return "No date" }
        switch due {
        case .overdue: return "Overdue · " + Self.short(date)
        case .today: return "Today"
        default: return Self.short(date)
        }
    }

    private static let dayInput: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd"; format.locale = Locale(identifier: "en_US_POSIX")
        return format
    }()
    private static let dayOutput: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "d MMM"
        return format
    }()

    static func short(_ day: String) -> String {
        guard let date = dayInput.date(from: day) else { return day }
        return dayOutput.string(from: date)
    }
}

/// A project's task source (project settings › Tasks › "Task source", and the guide's): the connected system
/// whose tasks that project's Tasks page opens on.
enum ConnectedTasksSource {
    /// The system picked on the page, else the scoped project's own source, else the first.
    static func pick(chosen: String?, projectSource: String?, systems: [ConnectedTaskSystem]) -> ConnectedTaskSystem? {
        systems.first { $0.id == chosen } ?? systems.first { $0.id == projectSource } ?? systems.first
    }

    /// The saved source of a project, or nil (no project, none chosen, or no answer).
    @MainActor static func load(projectID: String?) async -> String? {
        guard let projectID, !projectID.isEmpty,
              let raw = try? await EngineBridge.shared.invoke("project-settings:get", [["projectId": projectID]]),
              let value = try? NativeRPCValue.fromFoundation(raw) else { return nil }
        let id = value["values"][PROJSetup.taskSystemKey].string ?? ""
        return id.isEmpty ? nil : id
    }
}

/// Project settings › Tasks: the same "Task source" choice as the New project guide (it was a free-text id).
struct TKTaskSourcePicker: View {
    let projectID: String
    let value: String
    let onChange: (String) -> Void
    @State private var tasks = ConnectedTasksStore.shared

    var body: some View {
        Picker("Task source", selection: Binding(get: { value }, set: { onChange($0) })) {
            Text("None").tag("")
            ForEach(tasks.systems) { Text($0.name).tag($0.id) }
            if !value.isEmpty, !tasks.systems.contains(where: { $0.id == value }) { Text(value).tag(value) }
        }
        .help("The connected task system this project's Tasks page opens on")
        .task { tasks.start() }
    }
}
