import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// A quiet control bar over the existing task renderers. No second task model,
/// persistence key, engine channel or agent implementation is introduced here.
struct NativeUIGTasksWorkView: View {
    let model: MyWorkModel
    let state: TasksState
    let now: Double
    var projects: TKTasksProjectScope = .shared
    @State private var filtersOpen = false
    @State private var bulkDueOpen = false
    @State private var bulkTagsOpen = false
    @State private var bulkTagsText = ""
    @State private var bulkTagsMode = "add"

    private var store: TasksStore { TasksStore.shared }

    var body: some View {
        let d = model.drawn(state, now: now, projects: projects)
        let selected = d.shown.map(\.id).filter { model.selected.contains($0) }
        VStack(alignment: .leading, spacing: 10) {
            toolbar(d)
            if !model.trashOpen && !selected.isEmpty { bulk(selected, drawn: d) }
            if model.trashOpen {
                ScrollView { TrashList(tasks: state.trash, now: now, busy: store.busy).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                switch model.view.tab {
                case .table:
                    if d.groups.isEmpty {
                        ScrollView { empty(d).frame(maxWidth: .infinity) }
                    } else {
                        // 13 Oct: the main list, one page of every task; it scrolls under the toolbar.
                        NativeTasksAllList(model: model, state: state, drawn: d, projects: projects) { group, target, dragged in
                            reorder(group: group, before: target, dragged: dragged, drawn: d)
                        }
                    }
                case .board:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if d.shown.isEmpty { emptyNote(d) }
                            if d.shown.contains(where: { !TaskList.statusOrder.contains($0.crmStatus) }) {
                                HStack(spacing: 8) {
                                    Text("Tasks with another status are in List.").foregroundStyle(.secondary)
                                    Button("Show List") { model.view.tab = .table }
                                }.font(.callout)
                            }
                            StageBoard(tasks: d.shown, today: d.today, nowHm: d.nowHm, busy: store.busy,
                                state: state, openId: model.open, archived: model.view.filters.archived,
                                onOpen: { model.open = $0 })
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .calendar:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if d.shown.isEmpty { emptyNote(d) }
                            else if UIGTasksPresentation.contentCount(d.shown, tab: .calendar, week: d.week) == 0 {
                                Text("No tasks are due this week. Tasks without a due date stay in List.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            // Seven days remain readable without pushing the whole page sideways.
                            ScrollView(.horizontal) {
                                WeekCalendar(tasks: d.shown, days: d.week, today: d.today, busy: store.busy,
                                    openId: model.open, onWeek: { model.week = $0 }, onOpen: { model.open = $0 })
                                    .frame(minWidth: 760)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.trashOpen ? "Task trash" : "My Work")
    }

    private func toolbar(_ drawn: MyWorkModel.Drawn) -> some View {
        NativeUIGTasksToolbar(model: model, tab: Binding(get: { model.view.tab }, set: { model.view.tab = $0 }),
            search: Binding(get: { model.view.filters.search }, set: { search in model.filter { $0.search = search } }),
            trashOpen: Binding(get: { model.trashOpen }, set: { model.trashOpen = $0 }), filtersOpen: $filtersOpen,
            groupBy: Binding(get: { model.view.groupBy }, set: { model.view.groupBy = $0 }),
            subtasks: Binding(get: { model.view.subtasks }, set: { model.view.subtasks = $0 }),
            sort: Binding(get: { model.view.sort }, set: { model.view.sort = $0 }),
            showClosed: Binding(get: { model.view.showClosed }, set: { model.view.showClosed = $0 }),
            me: Binding(get: { model.view.filters.pile == .mine }, set: { on in model.filter { $0.pile = on ? .mine : .all } }),
            filterCount: UIGTasksPresentation.filterCount(model.view.filters), matchingCount: drawn.shown.count,
            totalCount: drawn.local.count,
            contentCount: UIGTasksPresentation.contentCount(drawn.shown, tab: model.view.tab, week: drawn.week),
            trashCount: state.trash.count, projectSections: drawn.byProject) {
                TasksColumnsPanel(model: model)
            } filters: { filterPanel(drawn) }
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

    /// Selected tasks: change their status or priority together, mark them done, archive or delete them.
    private func bulk(_ selected: [String], drawn: MyWorkModel.Drawn) -> some View {
        let all = drawn.shown.map(\.id)
        return TasksFlow(spacing: 8, lineSpacing: 8) {
            Text("\(selected.count) selected").font(.callout.weight(.semibold))
            if selected.count < all.count {
                Button("Select all \(all.count)") { model.selected = Set(all) }
            }
            Menu("Status") {
                ForEach(TaskList.statusOrder, id: \.self) { status in
                    Button(status) { runBulk(selected) { await store.update($0, ["status": status]) } }
                }
            }
            .fixedSize()
            Menu("Priority") {
                ForEach(TaskList.priorities, id: \.self) { priority in
                    Button(priority) { runBulk(selected) { await store.update($0, ["priority": priority]) } }
                }
                Divider()
                Button("No priority") { runBulk(selected) { await store.update($0, ["priority": NSNull()]) } }
            }
            .fixedSize()
            Button("Due date") { bulkDueOpen = true }
                .popover(isPresented: $bulkDueOpen) {
                    DayPicker(ymd: nil) { date in
                        bulkDueOpen = false
                        runBulk(selected) { await store.update($0, ["dueDate": date ?? NSNull()]) }
                    }
                }
            Button("Tags") { bulkTagsText = ""; bulkTagsMode = "add"; bulkTagsOpen = true }
                .popover(isPresented: $bulkTagsOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tags for \(selected.count) tasks").font(.headline)
                        Picker("Action", selection: $bulkTagsMode) {
                            Text("Add").tag("add"); Text("Remove").tag("remove")
                            Text("Replace").tag("replace"); Text("Clear all").tag("clear")
                        }
                        if bulkTagsMode != "clear" { TextField("Tags, separated by commas", text: $bulkTagsText) }
                        HStack {
                            Button("Cancel") { bulkTagsOpen = false }
                            Spacer()
                            Button("Apply") {
                                let tags = bulkTagsText.components(separatedBy: ",")
                                let mode = bulkTagsMode
                                bulkTagsOpen = false
                                runBulk(selected) { id in
                                    let existing = drawn.shown.first { $0.id == id }?.labels ?? []
                                    return await store.update(id, ["labels": TasksBulkTags.apply(tags, to: existing, mode: mode)])
                                }
                            }.disabled(bulkTagsMode != "clear" && bulkTagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }.padding(16).frame(width: 320)
                }
            Button("Mark done") { runBulk(selected) { await store.update($0, ["status": "Done"]) } }
            Button(model.view.filters.archived ? "Restore" : "Archive") {
                let archived = !model.view.filters.archived
                runBulk(selected) { await store.update($0, ["archived": archived]) }
            }
            Button("Delete", role: .destructive) { runBulk(selected) { await store.remove($0) } }.foregroundStyle(.red)
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
