import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// A quiet control bar over the existing task renderers. No second task model,
/// persistence key, engine channel or agent implementation is introduced here.
struct NativeUIGTasksWorkView: View {
    let model: MyWorkModel
    let state: TasksState
    let now: Double
    @State private var filtersOpen = false
    @State private var tableWidth: CGFloat = 600

    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        let d = model.drawn(state, now: now)
        let selected = d.shown.map(\.id).filter { model.selected.contains($0) }
        VStack(alignment: .leading, spacing: 12) {
            toolbar(d)
            if !model.trashOpen && !selected.isEmpty { bulk(selected) }
            if model.trashOpen {
                TrashList(tasks: state.trash, now: now, busy: store.busy)
            } else {
                switch model.view.tab {
                case .table:
                    if d.groups.isEmpty {
                        empty(d)
                    } else {
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(d.groups) { group in groupView(group, drawn: d) }
                            }
                            .frame(width: max(600, tableWidth), alignment: .leading)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tableWidth = $0 }
                    }
                case .board:
                    if d.shown.isEmpty { emptyNote(d) }
                    if d.shown.contains(where: { !TaskList.statusOrder.contains($0.crmStatus) }) {
                        HStack(spacing: 8) {
                            Text("Tasks with another status are in Table.").foregroundStyle(.secondary)
                            Button("Show Table") { model.view.tab = .table }
                        }.font(.callout)
                    }
                    StageBoard(tasks: d.shown, today: d.today, nowHm: d.nowHm, busy: store.busy,
                        state: state, openId: model.open, archived: model.view.filters.archived,
                        onOpen: { model.open = $0 })
                case .calendar:
                    if d.shown.isEmpty { emptyNote(d) }
                    else if UIGTasksPresentation.contentCount(d.shown, tab: .calendar, week: d.week) == 0 {
                        Text("No tasks are due this week. Tasks without a due date stay in Table.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    // Seven days remain readable without pushing the whole page sideways.
                    ScrollView(.horizontal) {
                        WeekCalendar(tasks: d.shown, days: d.week, today: d.today, busy: store.busy,
                            openId: model.open, onWeek: { model.week = $0 }, onOpen: { model.open = $0 })
                            .frame(minWidth: 760)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.trashOpen ? "Task trash" : "My Work")
    }

    private func toolbar(_ drawn: MyWorkModel.Drawn) -> some View {
        NativeUIGTasksToolbar(tab: Binding(get: { model.view.tab }, set: { model.view.tab = $0 }),
            search: Binding(get: { model.view.filters.search }, set: { search in model.filter { $0.search = search } }),
            trashOpen: Binding(get: { model.trashOpen }, set: { model.trashOpen = $0 }), filtersOpen: $filtersOpen,
            filterCount: UIGTasksPresentation.filterCount(model.view.filters), matchingCount: drawn.shown.count,
            totalCount: drawn.local.count,
            contentCount: UIGTasksPresentation.contentCount(drawn.shown, tab: model.view.tab, week: drawn.week),
            trashCount: state.trash.count) { filterPanel(drawn) }
    }

    private func emptyNote(_ drawn: MyWorkModel.Drawn) -> some View {
        HStack(spacing: 8) {
            Text(drawn.local.isEmpty && !model.view.filters.archived ? "No tasks yet. Add one with New task."
                : "No tasks match this search and filters.")
                .foregroundStyle(.secondary)
            if model.view.filters.narrows || model.view.filters.archived {
                Button("Clear search and filters") { model.view.filters = ListFilters() }
            }
        }
        .font(.callout)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func filterPanel(_ drawn: MyWorkModel.Drawn) -> some View {
        let boards = Array(Set(drawn.local.compactMap(\.board) + model.view.filters.boards))
            .filter { $0 != "none" }
            .sorted { $0.localizedCompare($1) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Filters").font(.callout.weight(.semibold))
                Spacer()
                Button("Done") { filtersOpen = false }.buttonStyle(.bordered)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Whose tasks", selection: Binding(get: { model.view.filters.pile }, set: { pile in
                        model.filter { $0.pile = pile }
                    })) {
                        ForEach(Pile.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    selectionMenu("Status", values: TaskList.statusOrder, selected: model.view.filters.statuses) { status in
                        model.filter { $0.statuses = TaskList.toggled($0.statuses, status) }
                    } onClear: { model.filter { $0.statuses = [] } }
                    selectionMenu("Priority", values: TaskList.priorities + ["none"], selected: model.view.filters.priorities,
                        noneLabel: "No priority") { priority in
                        model.filter { $0.priorities = TaskList.toggled($0.priorities, priority) }
                    } onClear: { model.filter { $0.priorities = [] } }
                    if !boards.isEmpty || !model.view.filters.boards.isEmpty {
                        selectionMenu("Board", values: boards + ["none"], selected: model.view.filters.boards,
                            noneLabel: "No board") { board in
                            model.filter { $0.boards = TaskList.toggled($0.boards, board) }
                        } onClear: { model.filter { $0.boards = [] } }
                    }
                    Picker("Due", selection: Binding(get: { model.view.filters.due }, set: { due in
                        model.filter { $0.due = due }
                    })) {
                        ForEach(DueFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle("Archived tasks", isOn: Binding(get: { model.view.filters.archived }, set: { archived in
                        model.filter { $0.archived = archived }
                    }))
                    .toggleStyle(.checkbox)
                    if model.view.tab == .table {
                        Divider()
                        Text("Table layout").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        let byProject = TKTasksProjectScope.shared.effective == .all
                        Picker("Group by", selection: Binding(get: { byProject ? .project : model.view.groupBy }, set: {
                            model.view.groupBy = $0
                        })) {
                            ForEach(ListGroupBy.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .disabled(byProject)
                        if byProject {
                            Text("All projects groups tasks under each project's name.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Show closed tasks", isOn: Binding(get: { model.view.showClosed }, set: { model.view.showClosed = $0 }))
                            .toggleStyle(.checkbox)
                        Menu("Columns") {
                            ForEach(TasksColumns.all, id: \.name) { column in
                                Toggle(column.label, isOn: Binding(get: { model.view.columns[keyPath: column.key] },
                                    set: { model.view.columns[keyPath: column.key] = $0 }))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 460)
            Divider()
            Button("Reset filters") { model.view = UIGTasksPresentation.resetFoldedFilters(model.view) }
                .disabled(UIGTasksPresentation.filterCount(model.view.filters) == 0)
                .help("Clear these filters. Search and table layout stay as you left them.")
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .padding(16)
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task filters and layout")
    }

    private func selectionMenu(_ label: String, values: [String], selected: [String], noneLabel: String = "None",
                               onToggle: @escaping (String) -> Void, onClear: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Menu {
                Button("Any") { onClear() }
                Divider()
                ForEach(values, id: \.self) { value in
                    Toggle(value == "none" ? noneLabel : value, isOn: Binding(
                        get: { selected.contains(value) }, set: { _ in onToggle(value) }))
                }
            } label: {
                Text(selected.isEmpty ? "Any" : selected.count == 1
                    ? (selected[0] == "none" ? noneLabel : selected[0]) : "\(selected.count) selected")
                    .lineLimit(1)
            }
            .frame(maxWidth: 200)
        }
    }

    @ViewBuilder private func empty(_ drawn: MyWorkModel.Drawn) -> some View {
        if drawn.local.isEmpty && !model.view.filters.archived {
            NativePageEmpty(symbol: "checklist", title: "No tasks yet") {
                Text("Use New task to add work for yourself, Hoot or a task agent.")
            }
        } else {
            NativePageEmpty(symbol: "line.3.horizontal.decrease", title: "No tasks match",
                action: PageEmptyAction(label: "Clear search and filters", perform: {
                    model.view.filters = ListFilters()
                })) {
                Text("Try another search or change the filters.")
            }
        }
    }

    private func bulk(_ selected: [String]) -> some View {
        TasksFlow(spacing: 8, lineSpacing: 8) {
            Text("\(selected.count) selected").font(.callout)
            Button("Mark done") { runBulk(selected) { await store.update($0, ["status": "Done"]) } }
            Button(model.view.filters.archived ? "Restore" : "Archive") {
                let archived = !model.view.filters.archived
                runBulk(selected) { await store.update($0, ["archived": archived]) }
            }
            Button("Delete") { runBulk(selected) { await store.remove($0) } }
            Button("Clear selection") { model.selected = [] }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(store.busy)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected task actions")
    }

    private func runBulk(_ ids: [String], _ work: @escaping (String) async -> TasksResult) {
        Task {
            for id in ids {
                guard await store.run({ await work(id) }) else { return }
                model.selected.remove(id)
            }
        }
    }

    private func groupView(_ group: ListGroup, drawn: MyWorkModel.Drawn) -> some View {
        let expanded = !model.isFolded(group.key, startsFolded: group.folded)
        let orderable = group.key == TaskList.reorderableGroupKey
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { model.toggleFold(group.key, startsFolded: group.folded) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption)
                        Text(group.label).font(.callout.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "expanded" : "collapsed")
                Text("\(group.items.count)").font(.caption).foregroundStyle(.secondary)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.items) { task in
                        TaskRowView(task: task, state: state, today: drawn.today, nowHm: drawn.nowHm, busy: store.busy,
                            columns: model.view.columns, selected: model.selected.contains(task.id),
                            open: model.open == task.id, orderable: orderable,
                            onSelect: { if $0 { model.selected.insert(task.id) } else { model.selected.remove(task.id) } },
                            onOpen: { model.open = task.id },
                            onDrop: { reorder(group: group, before: task.id, dragged: $0, drawn: drawn) })
                    }
                    if !model.view.filters.archived { AddTaskRow(defaults: group.defaults, busy: store.busy) }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(group.label)
    }

    private func reorder(group: ListGroup, before target: String, dragged: String, drawn: MyWorkModel.Drawn) {
        guard dragged != target, !store.busy,
              group.items.contains(where: { $0.id == dragged }) else { return }
        var visible = group.items.map(\.id).filter { $0 != dragged }
        visible.insert(dragged, at: visible.firstIndex(of: target) ?? visible.count)
        let inGroup = Set(group.items.map(\.id))
        let full = drawn.local.filter { inGroup.contains($0.id) || ($0.dueDate == drawn.today && $0.crmStatus != "Done") }.map(\.id)
        let ids = group.items.map(\.id) + full.filter { !inGroup.contains($0) }
        let order = TaskList.reorderWithinSlots(ids, visible)
        Task {
            for (position, id) in order.enumerated() {
                if let task = drawn.local.first(where: { $0.id == id }), task.position != Double(position) {
                    guard await store.run({ await store.update(id, ["position": position]) }) else { return }
                }
            }
        }
    }
}
