import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

// Your own tasks, laid out the way a CRM's My Work lays them out
// (src/renderer/tasks/MyWork.tsx): summary tiles, the view bar, filters, a table
// grouped with the Done group folded, one row per task with the CRM's cells,
// "Add task" under every group (it opens the one create card), bulk actions, a Board of stages and a week
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
    static let shared = MyWorkModel()
    static let savedViewsKey = "td.tasks.savedViews.v1"
    static let activeViewKey = "td.tasks.activeView.v1"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fixtureFavorites: [String]?
    var savedViews: [TasksSavedView] = []
    var activeViewID: String?

    var view: TasksViewState { didSet { save() } }
    var selected: Set<String> = []
    var open: String?
    var trashOpen = false
    var unfolded: Set<String> = []
    var folded: Set<String> = []
    /// Parents opened (Subtasks: Collapsed) or closed (Subtasks: Expanded) by hand.
    var openParents: Set<String> = []
    var closedParents: Set<String> = []
    /// The week the calendar shows (any day in it); nil for this week.
    var week: String?

    init(defaults: UserDefaults = .standard, importPage: Bool = true, fixtureFavorites: [String]? = nil) {
        self.defaults = defaults
        self.fixtureFavorites = fixtureFavorites
        let saved = TasksSavedView.read(defaults.array(forKey: Self.savedViewsKey))
        let active = defaults.string(forKey: Self.activeViewKey)
        savedViews = saved
        activeViewID = saved.contains(where: { $0.id == active }) ? active : nil
        if let data = defaults.string(forKey: TasksViewState.storageKey)?.data(using: .utf8),
           let raw = try? JSONSerialization.jsonObject(with: data) {
            view = TasksViewState.read(raw)
        } else {
            view = TasksViewState()
            if importPage { importViewFromPage() }
        }
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: view.json),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: TasksViewState.storageKey)
        // U26 (#94): what you try in an open saved view stays in this working copy; the saved view changes only on Update view.
        defaults.set(savedViews.map(\.json), forKey: Self.savedViewsKey)
        defaults.set(activeViewID, forKey: Self.activeViewKey)
    }

    func saveView(named name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let saved = TasksSavedView(name: name, view: view)
        savedViews.append(saved); activeViewID = saved.id; save()
    }
    func selectView(_ id: String) {
        guard let saved = savedViews.first(where: { $0.id == id }) else { return }
        activeViewID = id; view = saved.view; selected = []; trashOpen = false
    }
    func selectTab(_ tab: TasksTab) { activeViewID = nil; view.tab = tab; selected = [] }
    /// The open saved view has filters or columns tried since it was saved or last updated.
    var activeViewChanged: Bool { savedViews.first(where: { $0.id == activeViewID }).map { $0.view != view } ?? false }
    /// Update view: the open saved view keeps what is on screen now.
    func resaveView(_ id: String) {
        guard id == activeViewID, let index = savedViews.firstIndex(where: { $0.id == id }) else { return }
        savedViews[index].view = view; save()
    }
    /// Revert to saved: the open saved view goes back to how it was saved.
    func revertView(_ id: String) {
        guard id == activeViewID, let saved = savedViews.first(where: { $0.id == id }) else { return }
        view = saved.view; selected = []
    }
    func renameView(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = savedViews.firstIndex(where: { $0.id == id }) else { return }
        savedViews[index].name = name; save()
    }
    func deleteView(_ id: String) {
        savedViews.removeAll { $0.id == id }
        if activeViewID == id { activeViewID = nil }
        save()
    }

    /// The view as you left it in the page, the first time.
    private func importViewFromPage() {
        Task { @MainActor in
            for _ in 0..<120 where !AppModel.shared.pageReady { try? await Task.sleep(for: .milliseconds(500)) }
            guard defaults.string(forKey: TasksViewState.storageKey) == nil, AppModel.shared.pageReady,
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

    func isParentOpen(_ id: String) -> Bool {
        view.subtasks == .expanded ? !closedParents.contains(id) : openParents.contains(id)
    }

    func toggleParent(_ id: String) {
        if view.subtasks == .expanded {
            if closedParents.contains(id) { closedParents.remove(id) } else { closedParents.insert(id) }
        } else {
            if openParents.contains(id) { openParents.remove(id) } else { openParents.insert(id) }
        }
    }

    // MARK: What is drawn

    struct Drawn {
        let local: [TaskRow]
        let shown: [TaskRow]
        /// The list's sections: one per project on All projects (13 Oct), else one unnamed.
        let sections: [TaskListSection]
        /// Every group of every section, in order.
        let groups: [ListGroup]
        let nesting: TaskNesting
        let byProject: Bool
        let today: String
        let nowHm: String
        let week: [String]
    }

    func drawn(_ state: TasksState, now: Double, projects: TKTasksProjectScope = .shared) -> Drawn {
        let today = TaskList.ymdOf(now)
        let nowHm = TaskList.hmOf(now)
        let local = state.tasks.filter(\.local)
        let shown = TaskList.filter(local, view.filters, today: today, nowHm: nowHm,
                                    favorites: Set(fixtureFavorites ?? TaskFavoritesStore.shared.ids))
        // Lane TK: "All projects" lists every task under its project's name; inside each project the
        // chosen grouping (13 Oct: a project's work still reads by status, like one page of all tasks).
        let byProject = projects.effective == .all
        var sections = TasksAllList.sections(shown, allProjects: byProject, projects: projects.registry, by: view.groupBy,
                                             today: today, showClosed: view.showClosed,
                                             assigneeName: { MyWorkModel.name(of: $0, in: state) }, nowHm: nowHm)
        for section in sections.indices {
            for group in sections[section].groups.indices {
                sections[section].groups[group].items = view.sort.ordered(sections[section].groups[group].items)
            }
        }
        var nesting = TasksAllList.nesting(shown)
        if view.sort != .automatic {
            for id in Array(nesting.children.keys) { nesting.children[id] = view.sort.ordered(nesting.children[id] ?? []) }
        }
        return Drawn(local: local, shown: shown, sections: sections, groups: sections.flatMap(\.groups),
                     nesting: nesting, byProject: byProject,
                     today: today, nowHm: nowHm, week: TaskList.weekOf(week ?? today))
    }

    /// The tasks in the order the open view draws them — the popup's ▲ ▼.
    func order(_ state: TasksState, now: Double) -> [String] {
        let d = drawn(state, now: now)
        switch view.tab {
        case .board: return TaskList.statusOrder.flatMap { status in d.shown.filter { $0.crmStatus == status } }.map(\.id)
        case .calendar: return d.week.flatMap { day in d.shown.filter { $0.dueDate == day } }.map(\.id)
        case .table:
            var seen: Set<String> = []
            return d.groups.flatMap { TasksAllList.lines($0.items, nesting: d.nesting, isOpen: isParentOpen) }
                .map(\.task.id).filter { seen.insert($0).inserted }
        }
    }

    /// An archived agent is not offered, but a task it has is still named by it.
    static func name(of id: String, in state: TasksState) -> String {
        TasksRules.assigneeChoices(state.agents).first { $0.id == id }?.label
            ?? state.agents.first { $0.id == id }?.name ?? AGTLeads.sessionLead(address: id)?.name ?? id
    }
}

// MARK: - The list

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

/// "Add task" under a group or a board column: opens the one create card
/// (NativeTaskPopupCreate) with the group's own values already in it.
struct AddTaskRow: View {
    let defaults: GroupDefaults?
    let busy: Bool
    @Environment(\.openTaskCreate) private var openTaskCreate

    var body: some View {
        Button("Add task") { openTaskCreate?.open(.addTaskRow(defaults)) }
            .buttonStyle(.borderedProminent).controlSize(.small) // the screen's one main action: blue
            .disabled(busy || openTaskCreate == nil)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

// MARK: - Board

/// Cards in stages: one column per status, in the CRM's order; dragging a card to
/// another column changes its status; "+ Add task" under a column makes one there.
struct StageBoard: View {
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
            Text(task.createdAt > 0 ? "Created " + TaskList.createdLabel(task.createdAt, today: today) : "Creation date unavailable")
                .font(.caption).foregroundStyle(.secondary)
            NativeTAGTaskLinks(task: task, tasks: TasksStore.shared.state?.tasks ?? state.tasks, compact: true)
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
            if let from = task.handedFrom { TasksListCue(text: "from \(from)", attention: true) }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(openId == task.id
            ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
        .draggable(task.id)
        .contextMenu { TKMoveToProjectMenu(task: task) }
        .disabled(busy)
    }
}

// MARK: - Calendar

/// One Monday-to-Sunday week by due date. A click on a task opens it; its ring marks
/// it done or reopens it; "+ Add" puts a task on that day.
struct WeekCalendar: View {
    let tasks: [TaskRow]
    let days: [String]
    let today: String
    let busy: Bool
    let openId: String?
    let onWeek: (String) -> Void
    let onOpen: (String) -> Void
    @Environment(\.openTaskCreate) private var openTaskCreate
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title).font(.callout).lineLimit(2)
                                .foregroundStyle(TaskTone.status(task.crmStatus) == TaskTone.completed ? Color.secondary : Color.primary)
                            Text(task.createdAt > 0 ? "Created " + TaskList.createdLabel(task.createdAt, today: today) : "Creation date unavailable")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(openId == task.id
                    ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear))
            }
            TasksLinkButton("+ Add") { openTaskCreate?.open(.calendarDay(day)) }
                .disabled(busy || openTaskCreate == nil)
                .accessibilityLabel("New task on \(label(day))")
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
struct TrashList: View {
    let tasks: [TaskRow]
    let now: Double
    let busy: Bool
    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        if tasks.isEmpty {
            Text("The Trash is empty. A task you delete, merge or make a subtask waits here for 30 days, until you restore it.")
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
