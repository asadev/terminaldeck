import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// Your own tasks, laid out the way a CRM's My Work lays them out
// (src/renderer/tasks/MyWork.tsx): summary tiles, the view bar, filters, a table
// grouped with the Done group folded, one row per task with the CRM's cells,
// "+ Add task" under every group, bulk actions, a Board of stages and a week
// Calendar, and the Trash.

// MARK: - The list's own state

/// The tasks you starred: the popup's ☆ and the list's Favorites pile, kept on this
/// Mac. Read once from the page's own storage the first time, so nothing starred
/// there is lost.
@MainActor
@Observable
final class TaskFavoritesStore {
    static let shared = TaskFavoritesStore()
    private(set) var ids: [String]
    @ObservationIgnored private var imported = false

    private init() {
        ids = TaskFavorites.read(UserDefaults.standard.array(forKey: TaskFavorites.storageKey))
        importFromPageOnce()
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        ids = TaskFavorites.toggled(ids, id)
        UserDefaults.standard.set(ids, forKey: TaskFavorites.storageKey)
    }

    private func importFromPageOnce() {
        let done = "td.tasks.favorites.imported"
        guard !UserDefaults.standard.bool(forKey: done) else { return }
        Task { @MainActor in
            // The page keeps them in its browser storage; ask it once it is up.
            for _ in 0..<120 where !AppModel.shared.pageReady { try? await Task.sleep(for: .milliseconds(500)) }
            guard AppModel.shared.pageReady,
                  let raw = try? await AppModel.shared.web.webView.evaluateJavaScript(
                    "localStorage.getItem('\(TaskFavorites.storageKey)')") as? String,
                  let data = raw.data(using: .utf8), let list = try? JSONSerialization.jsonObject(with: data) else {
                if AppModel.shared.pageReady { UserDefaults.standard.set(true, forKey: done) }
                return
            }
            let merged = ids + TaskFavorites.read(list).filter { !ids.contains($0) }
            ids = Array(merged.prefix(500))
            UserDefaults.standard.set(ids, forKey: TaskFavorites.storageKey)
            UserDefaults.standard.set(true, forKey: done)
        }
    }
}

/// What the table, board and calendar show, and which task is open — owned by the
/// Tasks screen, so the popup over the whole page can walk the list it came from.
@MainActor
@Observable
final class MyWorkModel {
    var view: TasksViewState { didSet { save() } }
    var selected: Set<String> = []
    var open: String?
    var trashOpen = false
    var unfolded: Set<String> = []
    var folded: Set<String> = []
    /// The week the calendar shows (any day in it); nil for this week.
    var week: String?

    init() {
        if let data = UserDefaults.standard.string(forKey: TasksViewState.storageKey)?.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) {
            view = TasksViewState.read(raw)
        } else {
            view = TasksViewState()
            importViewFromPage()
        }
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: view.json),
              let text = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(text, forKey: TasksViewState.storageKey)
    }

    /// The view as you left it in the page, the first time.
    private func importViewFromPage() {
        Task { @MainActor in
            for _ in 0..<120 where !AppModel.shared.pageReady { try? await Task.sleep(for: .milliseconds(500)) }
            guard UserDefaults.standard.string(forKey: TasksViewState.storageKey) == nil, AppModel.shared.pageReady,
                  let raw = try? await AppModel.shared.web.webView.evaluateJavaScript(
                    "localStorage.getItem('\(TasksViewState.storageKey)')") as? String,
                  let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) else { return }
            view = TasksViewState.read(json)
        }
    }

    func filter(_ change: (inout ListFilters) -> Void) { change(&view.filters) }

    func isFolded(_ key: String, startsFolded: Bool) -> Bool {
        folded.contains(key) || (startsFolded && !unfolded.contains(key))
    }

    func toggleFold(_ key: String, startsFolded: Bool) {
        if isFolded(key, startsFolded: startsFolded) {
            folded.remove(key)
            unfolded.insert(key)
        } else {
            folded.insert(key)
            unfolded.remove(key)
        }
    }

    // MARK: What is drawn

    struct Drawn {
        let local: [TaskRow]
        let shown: [TaskRow]
        let groups: [ListGroup]
        let today: String
        let nowHm: String
        let week: [String]
    }

    func drawn(_ state: TasksState, now: Double) -> Drawn {
        let today = TaskList.ymdOf(now)
        let nowHm = TaskList.hmOf(now)
        let local = state.tasks.filter(\.local)
        let shown = TaskList.filter(local, view.filters, today: today, nowHm: nowHm,
                                    favorites: Set(TaskFavoritesStore.shared.ids))
        let groups = TaskList.group(shown, by: view.groupBy, today: today, showClosed: view.showClosed,
                                    assigneeName: { MyWorkModel.name(of: $0, in: state) }, nowHm: nowHm)
        return Drawn(local: local, shown: shown, groups: groups, today: today, nowHm: nowHm, week: TaskList.weekOf(week ?? today))
    }

    /// The tasks in the order the open view draws them — the popup's ▲ ▼.
    func order(_ state: TasksState, now: Double) -> [String] {
        let d = drawn(state, now: now)
        switch view.tab {
        case .board: return TaskList.statusOrder.flatMap { status in d.shown.filter { $0.crmStatus == status } }.map(\.id)
        case .calendar: return d.week.flatMap { day in d.shown.filter { $0.dueDate == day } }.map(\.id)
        case .table: return d.groups.flatMap(\.items).map(\.id)
        }
    }

    /// An archived agent is not offered, but a task it has is still named by it.
    static func name(of id: String, in state: TasksState) -> String {
        TasksRules.assigneeChoices(state.agents).first { $0.id == id }?.label
            ?? state.agents.first { $0.id == id }?.name ?? id
    }
}

// MARK: - The list

struct MyWorkView: View {
    let model: MyWorkModel
    let state: TasksState
    let now: Double
    @State private var favorites = TaskFavoritesStore.shared
    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        let d = model.drawn(state, now: now)
        let busy = store.busy
        let pick = model.selected.filter { id in d.shown.contains { $0.id == id } }
        VStack(alignment: .leading, spacing: 12) {
            tiles(d)
            bar
            filters(d)
            if !pick.isEmpty { bulk(Array(pick), busy: busy) }
            if model.trashOpen {
                TrashList(tasks: state.trash, now: now, busy: busy)
            } else {
                switch model.view.tab {
                case .board:
                    StageBoard(tasks: d.shown, today: d.today, nowHm: d.nowHm, busy: busy, state: state, openId: model.open,
                               archived: model.view.filters.archived) { model.open = $0 }
                case .calendar:
                    WeekCalendar(tasks: d.shown, days: d.week, today: d.today, busy: busy, openId: model.open,
                                 onWeek: { model.week = $0 }, onOpen: { model.open = $0 })
                case .table:
                    if d.groups.isEmpty {
                        Text(d.local.isEmpty ? "No tasks yet. Add one below, or with New task." : "No tasks match these filters.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(d.groups) { group in groupView(group, d: d, busy: busy) }
                        }
                    }
                }
            }
        }
    }

    // MARK: Tiles

    private func tiles(_ d: MyWorkModel.Drawn) -> some View {
        let t = TaskList.summary(d.local, today: d.today, nowHm: d.nowHm)
        let f = model.view.filters
        return HStack(spacing: 8) {
            Tile(label: "Open", value: t.open, active: f.statuses.count == 4) {
                model.filter { $0.statuses = ["To-Do", "Working on it", "In Progress", "Stuck"]; $0.due = .any }
            }
            Tile(label: "Overdue", value: t.overdue, overdue: true, active: f.due == .overdue) {
                model.filter { $0.due = $0.due == .overdue ? .any : .overdue; $0.statuses = [] }
            }
            Tile(label: "Due today", value: t.today, active: f.due == .today) {
                model.filter { $0.due = $0.due == .today ? .any : .today; $0.statuses = [] }
            }
            Tile(label: "Done", value: t.done, active: f.statuses == ["Done"]) {
                model.view.showClosed = true
                model.filter { $0.statuses = ["Done"]; $0.due = .any }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your tasks at a glance")
    }

    // MARK: The bar

    private var bar: some View {
        TasksFlow(spacing: 10, lineSpacing: 8) {
            Picker("Views", selection: Binding(get: { model.view.tab }, set: { model.view.tab = $0 })) {
                ForEach(TasksTab.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Whose tasks", selection: Binding(get: { model.view.filters.pile }, set: { pile in model.filter { $0.pile = pile } })) {
                ForEach(Pile.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 170)
            TextField("Search tasks", text: Binding(get: { model.view.filters.search }, set: { text in model.filter { $0.search = text } }))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 260)
                .accessibilityLabel("Search tasks")
            if model.view.tab == .table {
                HStack(spacing: 6) {
                    Text("Group by").foregroundStyle(.secondary)
                    Picker("Group by", selection: Binding(get: { model.view.groupBy }, set: { model.view.groupBy = $0 })) {
                        ForEach(ListGroupBy.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Toggle("Show closed", isOn: Binding(get: { model.view.showClosed }, set: { model.view.showClosed = $0 }))
                    .toggleStyle(.checkbox)
            }
            Toggle("Archived", isOn: Binding(get: { model.view.filters.archived }, set: { on in model.filter { $0.archived = on } }))
                .toggleStyle(.checkbox)
            Toggle(state.trash.isEmpty ? "Trash" : "Trash (\(state.trash.count))",
                   isOn: Binding(get: { model.trashOpen }, set: { model.trashOpen = $0 }))
                .toggleStyle(.checkbox)
        }
    }

    // MARK: Filters

    private func filters(_ d: MyWorkModel.Drawn) -> some View {
        let f = model.view.filters
        let boards = Array(Set(d.local.compactMap(\.board))).sorted { $0.localizedCompare($1) == .orderedAscending }
        return TasksFlow(spacing: 6, lineSpacing: 6) {
            FilterLabel("Status")
            ForEach(TaskList.statusOrder, id: \.self) { status in
                Chip(title: status, on: f.statuses.contains(status)) { model.filter { $0.statuses = TaskList.toggled($0.statuses, status) } }
            }
            FilterLabel("Priority")
            ForEach(TaskList.priorities + ["none"], id: \.self) { priority in
                Chip(title: priority == "none" ? "No priority" : priority, on: f.priorities.contains(priority)) {
                    model.filter { $0.priorities = TaskList.toggled($0.priorities, priority) }
                }
            }
            if !boards.isEmpty {
                FilterLabel("Board")
                ForEach(boards + ["none"], id: \.self) { board in
                    Chip(title: board == "none" ? "No board" : board, on: f.boards.contains(board)) {
                        model.filter { $0.boards = TaskList.toggled($0.boards, board) }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Due").foregroundStyle(.secondary)
                Picker("Due", selection: Binding(get: { f.due }, set: { due in model.filter { $0.due = due } })) {
                    ForEach(DueFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            if model.view.tab == .table {
                Menu("Columns") {
                    ForEach(TasksColumns.all, id: \.name) { column in
                        Toggle(column.label, isOn: Binding(get: { model.view.columns[keyPath: column.key] },
                                                           set: { model.view.columns[keyPath: column.key] = $0 }))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if f.narrows {
                TasksLinkButton("Clear filters") {
                    let archived = model.view.filters.archived
                    model.view.filters = ListFilters()
                    model.view.filters.archived = archived
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    // MARK: Bulk

    private func bulk(_ pick: [String], busy: Bool) -> some View {
        let archived = model.view.filters.archived
        return HStack(spacing: 8) {
            Text("\(pick.count) selected")
            Button("Mark done") { runBulk(pick) { await store.update($0, ["status": "Done"]) } }
            Button(archived ? "Restore" : "Archive") { runBulk(pick) { await store.update($0, ["archived": !archived]) } }
            Button("Delete") { runBulk(pick) { await store.remove($0) } }
            TasksLinkButton("Clear") { model.selected = [] }
        }
        .buttonStyle(.bordered)
        .disabled(busy)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected tasks")
    }

    private func runBulk(_ ids: [String], _ work: @escaping (String) async -> TasksResult) {
        Task {
            for id in ids { await store.run { await work(id) } }
            model.selected = []
        }
    }

    // MARK: Groups

    private func groupView(_ group: ListGroup, d: MyWorkModel.Drawn, busy: Bool) -> some View {
        let isOpen = !model.isFolded(group.key, startsFolded: group.folded)
        let orderable = group.key == TaskList.reorderableGroupKey
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button {
                    model.toggleFold(group.key, startsFolded: group.folded)
                } label: {
                    Text("\(isOpen ? "▾" : "▸") \(group.label)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(group.accent == .overdue ? TaskTone.input : group.accent == .today ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isOpen ? "expanded" : "collapsed")
                Text("\(group.items.count)").font(.footnote).foregroundStyle(.tertiary)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.items) { task in
                        TaskRowView(task: task, state: state, today: d.today, nowHm: d.nowHm, busy: busy,
                                    columns: model.view.columns, selected: model.selected.contains(task.id),
                                    open: model.open == task.id, orderable: orderable,
                                    onSelect: { on in if on { model.selected.insert(task.id) } else { model.selected.remove(task.id) } },
                                    onOpen: { model.open = task.id },
                                    onDrop: { dragged in reorder(group: group, before: task.id, dragged: dragged, d: d) })
                    }
                    if !model.view.filters.archived {
                        AddTaskRow(defaults: group.defaults, busy: busy)
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.label)
    }

    /// A drop in the Today group: the visible order, swapped among the slots it held,
    /// written as positions.
    private func reorder(group: ListGroup, before target: String, dragged: String, d: MyWorkModel.Drawn) {
        guard dragged != target else { return }
        var visible = group.items.map(\.id).filter { $0 != dragged }
        visible.insert(dragged, at: visible.firstIndex(of: target) ?? visible.count)
        let inGroup = Set(group.items.map(\.id))
        let full = d.local.filter { inGroup.contains($0.id) || ($0.dueDate == d.today && $0.crmStatus != "Done") }.map(\.id)
        let ids = group.items.map(\.id) + full.filter { !inGroup.contains($0) }
        let order = TaskList.reorderWithinSlots(ids, visible)
        Task {
            for (index, id) in order.enumerated() {
                if let task = d.local.first(where: { $0.id == id }), task.position != Double(index) {
                    await store.run { await store.update(id, ["position": index]) }
                }
            }
        }
    }
}

private struct FilterLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.footnote).foregroundStyle(.tertiary) }
}

/// A summary tile; pressing it filters the list.
private struct Tile: View {
    let label: String
    let value: Int
    var overdue = false
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(value)")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(overdue && value > 0 ? TaskTone.input : .primary)
                Text(label).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// A filter chip (`.mw-chip`).
private struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.22) : Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().stroke(on ? Color.accentColor : Color(nsColor: .separatorColor)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - One task, in the CRM's order of cells

/// The ring before a title: marks it done or reopens it; a diamond for a milestone.
struct TaskRing: View {
    let task: TaskRow
    let busy: Bool
    let action: () -> Void

    var body: some View {
        let done = task.crmStatus == "Done"
        let tone = TaskTone.status(task.crmStatus)
        Button(action: action) {
            Group {
                if task.taskType == "milestone" {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(tone, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 2).fill(done ? tone : .clear))
                        .rotationEffect(.degrees(45))
                        .scaleEffect(0.85)
                } else {
                    Circle().strokeBorder(tone, lineWidth: 2).background(Circle().fill(done ? tone : .clear))
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(done ? "Done — click to reopen" : "Mark done")
        .accessibilityLabel(done ? "Reopen \(task.title)" : "Mark \(task.title) done")
    }
}

struct TaskRowView: View {
    let task: TaskRow
    let state: TasksState
    let today: String
    let nowHm: String
    let busy: Bool
    let columns: TasksColumns
    let selected: Bool
    let open: Bool
    let orderable: Bool
    let onSelect: (Bool) -> Void
    let onOpen: () -> Void
    let onDrop: (String) -> Void
    @State private var hovering = false
    @State private var dropTarget = false
    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                lead
                cells
            }
            VStack(alignment: .trailing, spacing: 4) {
                lead
                cells
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(open ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear))
        .overlay(alignment: .top) { if dropTarget { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard orderable, let dragged = items.first, dragged != task.id else { return false }
            onDrop(dragged)
            return true
        } isTargeted: { dropTarget = orderable && $0 }
    }

    private func update(_ patch: [String: Any]) {
        Task { await store.run { await store.update(task.id, patch) } }
    }

    private var lead: some View {
        let done = task.crmStatus == "Done"
        let tags = Array(task.labels.prefix(3))
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { selected }, set: onSelect))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Select \(task.title)")
            if orderable {
                Text("⋮⋮")
                    .foregroundStyle(.tertiary)
                    .help("Drag to reorder your Today")
                    .accessibilityLabel("Drag \(task.title) to reorder")
                    .draggable(task.id)
            }
            TaskRing(task: task, busy: busy) { update(["status": done ? "To-Do" : "Done"]) }
            Button(action: onOpen) {
                Text(task.title)
                    .lineLimit(2)
                    .strikethrough(done)
                    .foregroundStyle(done ? Color(nsColor: .tertiaryLabelColor) : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            .accessibilityHint("Opens the task")
            HStack(spacing: 4) {
                if !task.instructions.isEmpty { Badge(text: "¶", help: "Has details") }
                if let from = task.handedFrom { Badge(text: "from \(from)", attention: true, help: "\(from) handed this to you") }
                if let stalled = task.stalled {
                    Badge(text: stalled.reason == .exited ? "stopped early" : "stalled", attention: true, help: stalled.text)
                }
                if let first = task.waitingOn.first {
                    Badge(text: "waits for \(first)\(task.waitingOn.count > 1 ? " +\(task.waitingOn.count - 1)" : "")",
                          help: "Its agent starts when these are Done: \(task.waitingOn.joined(separator: ", "))")
                }
                ForEach(tags, id: \.self) { TagPill(text: $0) }
                if task.labels.count > 3 { TagPill(text: "+\(task.labels.count - 3)") }
            }
        }
    }

    private var cells: some View {
        let choices = TasksRules.assigneeChoices(state.agents)
        let goalChoices = Goals.options(state.goals)
        let assigneeName = MyWorkModel.name(of: task.assignee, in: state)
        let next = TaskList.nextStatus(task.crmStatus)
        return HStack(spacing: 8) {
            if columns.assignee {
                Picker("Who has \(task.title)", selection: Binding(get: { task.assignee }, set: { update(["assignee": $0]) })) {
                    if !choices.contains(where: { $0.id == task.assignee }) { Text(assigneeName).tag(task.assignee) }
                    ForEach(choices, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
                .help(assigneeName)
            }
            if columns.due {
                DueCell(task: task, today: today, nowHm: nowHm, busy: busy) { update(["dueDate": $0 ?? NSNull()]) }
            }
            if columns.priority {
                Picker("Priority of \(task.title)", selection: Binding(get: { task.priority ?? "" },
                                                                       set: { update(["priority": $0.isEmpty ? NSNull() : $0]) })) {
                    Text("No priority").tag("")
                    ForEach(TaskList.priorities, id: \.self) { Text("⚑ \($0)").tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 130)
                .tint(TaskTone.priority(task.priority))
            }
            if columns.goal && !goalChoices.isEmpty {
                Picker("Goal of \(task.title)", selection: Binding(get: { task.goalId ?? "" },
                                                                   set: { update(["goalId": $0.isEmpty ? NSNull() : $0]) })) {
                    Text("No goal").tag("")
                    ForEach(goalChoices, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
            }
            if columns.project && !task.project.isEmpty {
                Text(task.project.split(separator: "/").last.map(String.init) ?? task.project)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .help(task.project)
            }
            if columns.created {
                Text(TaskList.createdLabel(task.createdAt, today: today)).font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                Rectangle().fill(TaskTone.status(task.crmStatus)).frame(width: 3, height: 18)
                Picker("Status of \(task.title)", selection: Binding(get: { task.crmStatus }, set: { update(["status": $0]) })) {
                    if !TaskList.statusOrder.contains(task.crmStatus) { Text(task.crmStatus).tag(task.crmStatus) }
                    ForEach(TaskList.statusOrder, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            if let next {
                Button("▸") { update(["status": next]) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Move to \(next)")
                    .accessibilityLabel("Move \(task.title) to \(next)")
            }
            Button("×") { Task { await store.run { await store.remove(task.id) } } }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .opacity(hovering ? 1 : 0)
                .help("Delete")
                .accessibilityLabel("Delete \(task.title)")
        }
        .controlSize(.small)
        .disabled(busy)
    }
}

private struct Badge: View {
    let text: String
    var attention = false
    var help: String?

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(attention ? TaskTone.input : Color.secondary)
            .background(Capsule().fill((attention ? TaskTone.input : Color.secondary).opacity(0.14)))
            .help(help ?? "")
    }
}

struct TagPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(.secondary)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.14)))
    }
}

/// The due cell: "Tomorrow, 09:00", red when overdue; a click opens a calendar.
private struct DueCell: View {
    let task: TaskRow
    let today: String
    let nowHm: String
    let busy: Bool
    let onPick: (String?) -> Void
    @State private var picking = false

    var body: some View {
        let due = TaskList.relativeDue(task.dueDate, today: today)
        let overdue = TaskList.isOverdue(task, today: today, nowHm: nowHm)
        Button {
            picking = true
        } label: {
            Text(due.isEmpty ? "No date" : "\(due)\(task.dueTime.map { ", \($0)" } ?? "")")
                .font(.footnote)
                .foregroundStyle(overdue ? TaskTone.input : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(task.dueDate ?? "No due date")
        .accessibilityLabel("Due date of \(task.title)")
        .popover(isPresented: $picking) {
            DayPicker(ymd: task.dueDate) { picked in
                picking = false
                onPick(picked)
            }
        }
    }
}

/// A calendar for one day, with "No date".
struct DayPicker: View {
    let ymd: String?
    let onPick: (String?) -> Void
    @State private var date: Date

    init(ymd: String?, onPick: @escaping (String?) -> Void) {
        self.ymd = ymd
        self.onPick = onPick
        _date = State(initialValue: DayPicker.date(ymd) ?? Date())
    }

    static func date(_ ymd: String?) -> Date? {
        guard let ymd, TaskList.isYmd(ymd) else { return nil }
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("Due date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .onChange(of: date) { _, picked in onPick(TaskList.ymdOf(picked.timeIntervalSince1970 * 1000)) }
            HStack {
                Button("Today") { onPick(TaskList.ymdOf(Date().timeIntervalSince1970 * 1000)) }
                Spacer()
                Button("No date") { onPick(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
    }
}

/// "+ Add task" under a group: Enter saves and keeps the row open, pre-filled with
/// the group's own values; Esc stops.
struct AddTaskRow: View {
    let defaults: GroupDefaults?
    let busy: Bool
    @State private var adding = false
    @State private var title = ""
    @FocusState private var focused: Bool
    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        Group {
            if adding {
                TextField("Task name — Enter to add, Esc to stop", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .disabled(busy)
                    .onAppear { focused = true }
                    .onSubmit(save)
                    .onExitCommand {
                        adding = false
                        title = ""
                    }
                    .accessibilityLabel("New task title")
            } else {
                TasksLinkButton("+ Add task") { adding = true }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var input: [String: Any] = ["title": trimmed, "assignee": defaults?.assignee ?? "me"]
        input.merge(defaults?.wire ?? [:]) { old, _ in old }
        input["title"] = trimmed
        Task {
            if await store.run({ await store.create(input) }) {
                title = ""
                focused = true
            }
        }
    }
}

// MARK: - Board

/// Cards in stages: one column per status, in the CRM's order; dragging a card to
/// another column changes its status; "+ Add task" under a column makes one there.
private struct StageBoard: View {
    let tasks: [TaskRow]
    let today: String
    let nowHm: String
    let busy: Bool
    let state: TasksState
    let openId: String?
    let archived: Bool
    let onOpen: (String) -> Void
    @State private var over: String?
    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(TaskList.statusOrder, id: \.self) { status in column(status) }
            }
            .padding(.bottom, 6)
        }
        .accessibilityLabel("Stages")
    }

    private func column(_ status: String) -> some View {
        let cards = tasks.filter { $0.crmStatus == status }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(TaskTone.status(status)).frame(width: 8, height: 8)
                Text(status).font(.body.weight(.semibold))
                Text("\(cards.count)").font(.footnote).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(cards) { task in card(task) }
                if !archived { AddTaskRow(defaults: GroupDefaults(status: status), busy: busy) }
            }
            .frame(minHeight: 80, alignment: .top)
        }
        .padding(8)
        .frame(width: 240, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(over == status ? Color.accentColor : .clear, lineWidth: 2))
        .dropDestination(for: String.self) { items, _ in
            over = nil
            guard let id = items.first, let task = tasks.first(where: { $0.id == id }), task.crmStatus != status else { return false }
            Task { await store.run { await store.update(task.id, ["status": status]) } }
            return true
        } isTargeted: { targeted in
            if targeted { over = status } else if over == status { over = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status), \(cards.count)")
    }

    private func card(_ task: TaskRow) -> some View {
        let due = TaskList.relativeDue(task.dueDate, today: today)
        return VStack(alignment: .leading, spacing: 6) {
            Button { onOpen(task.id) } label: {
                Text((task.taskType == "milestone" ? "◆ " : "") + task.title)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !task.labels.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(task.labels.prefix(3)), id: \.self) { TagPill(text: $0) }
                    if task.labels.count > 3 { TagPill(text: "+\(task.labels.count - 3)") }
                }
            }
            TasksFlow(spacing: 8, lineSpacing: 4) {
                Text(MyWorkModel.name(of: task.assignee, in: state))
                if !due.isEmpty {
                    Text("\(due)\(task.dueTime.map { ", \($0)" } ?? "")")
                        .foregroundStyle(TaskList.isOverdue(task, today: today, nowHm: nowHm) ? TaskTone.input : Color.secondary)
                }
                if let priority = task.priority { Text("⚑ \(priority)").foregroundStyle(TaskTone.priority(priority)) }
                if let board = task.board { TagPill(text: board) }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            if let from = task.handedFrom { Badge(text: "from \(from)", attention: true) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(openId == task.id
            ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
        .draggable(task.id)
        .disabled(busy)
    }
}

// MARK: - Calendar

/// One Monday-to-Sunday week by due date. A click on a task opens it; its ring marks
/// it done or reopens it; "+ Add" puts a task on that day.
private struct WeekCalendar: View {
    let tasks: [TaskRow]
    let days: [String]
    let today: String
    let busy: Bool
    let openId: String?
    let onWeek: (String) -> Void
    let onOpen: (String) -> Void
    @State private var adding: String?
    @State private var title = ""
    @FocusState private var focused: Bool
    private var store: TasksStore { TasksStore.shared }

    private func label(_ ymd: String) -> String {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return "\(names[days.firstIndex(of: ymd) ?? 0]) \(p.count > 2 ? p[2] : 0)/\(p.count > 1 ? p[1] : 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("‹ Previous week") { onWeek(TaskList.ymdAddDays(days[0], -7)) }
                Button("This week") { onWeek(today) }
                Button("Next week ›") { onWeek(TaskList.ymdAddDays(days[0], 7)) }
            }
            .buttonStyle(.bordered)
            HStack(alignment: .top, spacing: 6) {
                ForEach(days, id: \.self) { day in dayColumn(day) }
            }
        }
    }

    private func dayColumn(_ day: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label(day)).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(tasks.filter { $0.dueDate == day }) { task in
                HStack(spacing: 4) {
                    TaskRing(task: task, busy: busy) {
                        Task { await store.run { await store.update(task.id, ["status": task.crmStatus == "Done" ? "To-Do" : "Done"]) } }
                    }
                    Button { onOpen(task.id) } label: {
                        Text(task.title)
                            .font(.callout)
                            .lineLimit(2)
                            .foregroundStyle(TaskTone.status(task.crmStatus) == TaskTone.completed ? Color.secondary : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(openId == task.id
                    ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear))
            }
            if adding == day {
                TextField("", text: $title)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .disabled(busy)
                    .onAppear { focused = true }
                    .onSubmit {
                        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        Task {
                            if await store.run({ await store.create(["title": trimmed, "dueDate": day, "assignee": "me"]) }) {
                                title = ""
                                adding = nil
                            }
                        }
                    }
                    .onExitCommand { adding = nil }
                    .accessibilityLabel("New task on \(label(day))")
            } else {
                TasksLinkButton("+ Add") {
                    title = ""
                    adding = day
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(day == today ? Color.accentColor : .clear, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label(day))
    }
}

// MARK: - Trash

/// Your deleted tasks — deleted, merged into another, or made a subtask — each kept
/// whole until you restore it. Nothing empties it.
private struct TrashList: View {
    let tasks: [TaskRow]
    let now: Double
    let busy: Bool
    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        if tasks.isEmpty {
            Text("The Trash is empty. A task you delete, merge or make a subtask waits here until you restore it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(tasks) { task in
                    HStack(spacing: 8) {
                        Text(task.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                        if let deleted = task.deletedAt {
                            Text("Deleted \(CrmMirror.relativeAgo(now - deleted))").font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Restore") { Task { await store.run { await store.restore(task.id) } } }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Trash")
        }
    }
}
