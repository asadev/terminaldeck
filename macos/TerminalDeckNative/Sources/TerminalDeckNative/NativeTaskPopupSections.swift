import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The popup's sections, in the CRM's order: subtasks (page/subtasks-table.tsx),
// relationships (dependencies-section.tsx), checklists (page/checklists-block.tsx),
// files (detail-attachments.tsx, attachment-chips.tsx, attach-button.tsx, the
// lightbox), then the routine (page/routine-block.tsx) and description history.

// MARK: - Record search (use-tag-search.ts → searchTags)

struct TagHit: Identifiable, Equatable {
    let area: String
    let id: String
    let label: String
    let secondary: String?
    let status: String?
    var href: String = ""
}

/// The CRM's record search, answered from your tasks, people and files: at least two
/// characters, a quarter of a second after typing stops.
@MainActor
@Observable
final class TagSearch {
    let area: String
    private(set) var hits: [TagHit]?
    private(set) var failed: String?
    private(set) var busy = false
    var query = "" { didSet { schedule() } }
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private weak var model: TaskDetailModel?

    init(area: String, model: TaskDetailModel) {
        self.area = area
        self.model = model
    }

    var tooShort: Bool { query.trimmingCharacters(in: .whitespaces).count < 2 }

    private func schedule() {
        pending?.cancel()
        hits = nil
        failed = nil
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            busy = false
            return
        }
        busy = true
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, let model = self.model else { return }
            let result = await model.call("searchTags", [self.area, q])
            guard !Task.isCancelled else { return }
            self.busy = false
            switch result {
            case .failure: self.failed = "Could not search just now. Try again."
            case .success(let r):
                self.hits = (r["hits"] as? [Any] ?? []).compactMap { raw in
                    guard let h = raw as? [String: Any], let id = h["id"] as? String else { return nil }
                    return TagHit(area: h["area"] as? String ?? self.area, id: id, label: h["label"] as? String ?? id,
                                  secondary: h["secondary"] as? String, status: h["status"] as? String,
                                  href: h["href"] as? String ?? "")
                }
            }
        }
    }
}

/// The search results' states: too short, searching, none, or the hits.
struct SearchResults<Row: View>: View {
    let search: TagSearch
    let none: String
    var exclude: Set<String> = []
    @ViewBuilder let row: (TagHit) -> Row

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let failed = search.failed {
                    note(failed, TaskTone.input)
                } else if search.tooShort {
                    note("Type at least 2 characters.")
                } else if let found = search.hits {
                    let hits = found.filter { !exclude.contains($0.id) }
                    if hits.isEmpty { note("\(none) “\(search.query.trimmingCharacters(in: .whitespaces))”.") }
                    ForEach(hits) { row($0) }
                } else {
                    note("Searching…")
                }
            }
            .padding(4)
        }
        .frame(maxHeight: 176)
    }

    private func note(_ text: String, _ color: Color = .secondary) -> some View {
        Text(text).font(.caption).foregroundStyle(color).frame(maxWidth: .infinity).padding(.vertical, 12)
    }
}

/// A search box with its magnifier and spinner.
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    let busy: Bool
    var onEscape: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { focused = true }
                .onExitCommand { onEscape?() }
                .accessibilityLabel(placeholder)
            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Subtasks

/// The little done bar after "n open".
struct ProgressBarSmall: View {
    let done: Int
    let total: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(TaskTone.completed).frame(width: total == 0 ? 0 : proxy.size.width * CGFloat(done) / CGFloat(total))
            }
        }
        .frame(width: 48, height: 4)
        .accessibilityHidden(true)
    }
}

struct SubtasksTable: View {
    let model: TaskDetailModel
    let rows: [SubtaskRow]
    let people: TaskPeople
    @State private var collapsed = false
    @State private var sort = "manual"
    @State private var adding: Bool
    @State private var sortOpen = false

    init(model: TaskDetailModel, rows: [SubtaskRow], people: TaskPeople, justAdded: Bool) {
        self.model = model
        self.rows = rows
        self.people = people
        _adding = State(initialValue: justAdded && rows.isEmpty)
    }

    private var sorts: [(String, String, Bool)] {
        [("manual", "Manual", false), ("name", "Name", false), ("status", "Status", false), ("assignee", "Assignee", false),
         ("priority", "Priority", true), ("due", "Due date", true)]
    }

    private var sorted: [SubtaskRow] {
        let meta = model.extras?.subtaskMeta
        let order = ["Critical", "High", "Medium", "Low"]
        func name(_ id: String?) -> String { id.flatMap { i in model.team.first { $0.id == i }?.name } ?? "" }
        func stable(_ less: (SubtaskRow, SubtaskRow) -> Bool) -> [SubtaskRow] {
            rows.enumerated().sorted { l, r in less(l.element, r.element) || (!less(r.element, l.element) && l.offset < r.offset) }.map(\.element)
        }
        switch sort {
        case "name": return stable { $0.title.localizedCompare($1.title) == .orderedAscending }
        case "status": return stable { !$0.done && $1.done }
        case "assignee": return stable { name($0.assigneeUserId).localizedCompare(name($1.assigneeUserId)) == .orderedAscending }
        case "priority":
            func rank(_ r: SubtaskRow) -> Int { meta?[r.id]?.priority.flatMap { order.firstIndex(of: $0) } ?? -1 }
            return stable { rank($0) < rank($1) }
        case "due": return stable { (meta?[$0.id]?.dueDate ?? "9999") < (meta?[$1.id]?.dueDate ?? "9999") }
        default: return rows
        }
    }

    var body: some View {
        let open = rows.filter { !$0.done }.count
        let forMe = rows.filter { !$0.done && people.assignee(for: $0.assigneeUserId).person?.id == model.me }.count
        let withMeta = model.extras != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { collapsed.toggle() } label: { Image(systemName: "chevron.down").rotationEffect(.degrees(collapsed ? -90 : 0)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(collapsed ? "Expand subtasks" : "Collapse subtasks")
                Text("Subtasks").font(.callout.weight(.semibold))
                if !rows.isEmpty {
                    Text("\(open) open").foregroundStyle(.secondary)
                    ProgressBarSmall(done: rows.count - open, total: rows.count)
                }
                if forMe > 0 {
                    Text("\(forMe) for me").font(.caption.weight(.medium)).foregroundStyle(Color.purple)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(Color.purple.opacity(0.12)))
                }
                Spacer()
                Button { sortOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                        if sort != "manual" { Text(sorts.first { $0.0 == sort }?.1 ?? "") }
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Sort").accessibilityLabel("Sort subtasks")
                .popover(isPresented: $sortOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Sort by").font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
                        ForEach(sorts.filter { withMeta || !$0.2 }, id: \.0) { key, label, _ in
                            Button {
                                sort = key
                                sortOpen = false
                            } label: {
                                HStack { Text(label); Spacer(); if sort == key { Image(systemName: "checkmark").foregroundStyle(Color.purple) } }
                                    .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 6).frame(width: 180)
                }
                Button { adding = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Add subtask").accessibilityLabel("New subtask")
            }
            .font(.callout)
            .frame(height: 36)
            if !collapsed {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Assignee").frame(width: 96, alignment: .leading)
                        if withMeta {
                            Text("Priority").frame(width: 72, alignment: .leading)
                            Text("Due date").frame(width: 104, alignment: .leading)
                        }
                        Color.clear.frame(width: 28)
                    }
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).frame(height: 32)
                    Divider()
                    ForEach(sorted) { r in SubtaskLine(model: model, row: r, people: people, withMeta: withMeta) }
                    if adding {
                        AddSubtaskRow(onAdd: { model.addSubtask($0) }, onCancel: { adding = false })
                    } else {
                        Button { adding = true } label: {
                            Label("Add Task", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 35, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 8)
                        .accessibilityLabel("Add subtask")
                    }
                }
                .font(.callout)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subtasks")
    }
}

private struct SubtaskLine: View {
    let model: TaskDetailModel
    let row: SubtaskRow
    let people: TaskPeople
    let withMeta: Bool
    @State private var hovering = false
    @State private var priorityOpen = false
    @State private var dueOpen = false

    var body: some View {
        let meta = model.extras?.subtaskMeta[row.id]
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { model.setSubtaskDone(row, !row.done) } label: {
                    if row.done {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(TaskTone.completed)
                    } else {
                        Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \"\(row.title)\" \(row.done ? "not done" : "done")")
                Text(row.title).lineLimit(1).strikethrough(row.done)
                    .foregroundStyle(row.done ? Color(nsColor: .tertiaryLabelColor) : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RowAssignButton(value: row.assigneeUserId, people: people, team: model.team, what: "subtask \"\(row.title)\"") {
                model.setSubtaskAssignee(row, $0)
            }
            .frame(width: 96, alignment: .leading)
            if withMeta {
                Button { priorityOpen.toggle() } label: {
                    Image(systemName: meta?.priority != nil ? "flag.fill" : "flag")
                        .foregroundStyle(meta?.priority != nil ? CrmColor.flag(meta?.priority) : Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .frame(width: 72, alignment: .leading)
                .accessibilityLabel("Priority of \"\(row.title)\": \(meta?.priority ?? "none")")
                .popover(isPresented: $priorityOpen, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(["Critical", "High", "Medium", "Low"], id: \.self) { p in
                            Button {
                                priorityOpen = false
                                model.changeSubtaskMeta(row.id, priority: .some(p))
                            } label: {
                                Label(p, systemImage: "flag.fill").foregroundStyle(.primary)
                                    .padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        if meta?.priority != nil {
                            Divider()
                            Button {
                                priorityOpen = false
                                model.changeSubtaskMeta(row.id, priority: .some(nil))
                            } label: {
                                Text("Clear").foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4).frame(width: 180)
                }
                Button { dueOpen.toggle() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        if let due = meta?.dueDate { Text(relativeDay(due)) }
                    }
                    .font(.caption)
                    .foregroundStyle(meta?.dueDate != nil ? Color.primary : Color(nsColor: .tertiaryLabelColor))
                }
                .buttonStyle(.plain)
                .frame(width: 104, alignment: .leading)
                .accessibilityLabel("Due date of \"\(row.title)\"")
                .popover(isPresented: $dueOpen) {
                    DayPicker(ymd: meta?.dueDate) { picked in
                        dueOpen = false
                        model.changeSubtaskMeta(row.id, dueDate: .some(picked))
                    }
                }
            }
            Button { model.deleteSubtask(row) } label: { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(.plain).foregroundStyle(.tertiary).opacity(hovering ? 1 : 0)
                .frame(width: 28, alignment: .trailing)
                .accessibilityLabel("Remove subtask \"\(row.title)\"")
        }
        .padding(.horizontal, 8)
        .frame(height: 35)
        .background(hovering ? Color.secondary.opacity(0.06) : .clear)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .onHover { hovering = $0 }
    }
}

private struct AddSubtaskRow: View {
    let onAdd: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dashed").foregroundStyle(.quaternary)
            TextField("Task Name or type '/' for commands", text: Binding(get: { text }, set: { text = String($0.prefix(300)) }))
                .textFieldStyle(.plain)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit(save)
                .onExitCommand(perform: onCancel)
                .accessibilityLabel("Add subtask")
            Button("Cancel", action: onCancel).controlSize(.small)
            Button("Save ↵", action: save).buttonStyle(.borderedProminent).tint(.purple).controlSize(.small)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 8)
        .frame(height: 35)
    }

    private func save() {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        onAdd(t)
        text = ""
    }
}

// MARK: - Checklists

struct ChecklistsBlock: View {
    let model: TaskDetailModel
    let lists: [Checklist]
    let people: TaskPeople
    let justAdded: Bool
    @State private var collapsed = false

    var body: some View {
        let items = lists.flatMap(\.items)
        let open = items.filter { !$0.done }.count
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { collapsed.toggle() } label: { Image(systemName: "chevron.down").rotationEffect(.degrees(collapsed ? -90 : 0)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(collapsed ? "Expand checklists" : "Collapse checklists")
                Text("Checklists").font(.callout.weight(.semibold))
                if !items.isEmpty {
                    Text("\(open) open").foregroundStyle(.secondary)
                    ProgressBarSmall(done: items.count - open, total: items.count)
                }
                Spacer()
                Button(action: addList) { Image(systemName: "plus") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Add checklist").accessibilityLabel("New checklist")
            }
            .font(.callout)
            .frame(height: 36)
            if !collapsed {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(lists.enumerated()), id: \.element.id) { li, list in
                        ChecklistCard(model: model, list: list, people: people, autoOpen: justAdded && li == 0 && list.items.isEmpty)
                    }
                    Button(action: addList) { Label("Add checklist", systemImage: "plus").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Checklists")
    }

    private func addList() {
        Task { await model.addChecklist(title: lists.isEmpty ? "Checklist" : "Checklist \(lists.count + 1)") }
    }
}

private struct ChecklistCard: View {
    let model: TaskDetailModel
    let list: Checklist
    let people: TaskPeople
    let autoOpen: Bool
    @State private var title = ""
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TextField("", text: Binding(get: { list.title }, set: { model.renameChecklist(list.id, String($0.prefix(120))) }))
                    .textFieldStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .accessibilityLabel("Checklist name")
                Button { model.deleteChecklist(list) } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Remove checklist \"\(list.title)\"")
            }
            .frame(height: 28)
            ForEach(list.items) { item in
                HStack(spacing: 10) {
                    Button { model.setItemDone(item, !item.done) } label: {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.done ? TaskTone.completed : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mark \"\(item.title)\" \(item.done ? "not done" : "done")")
                    Text(item.title).lineLimit(1).strikethrough(item.done)
                        .foregroundStyle(item.done ? Color(nsColor: .tertiaryLabelColor) : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    RowAssignButton(value: item.assigneeUserId, people: people, team: model.team, what: "item \"\(item.title)\"") {
                        model.setItemAssignee(item, $0)
                    }
                    Button { model.deleteItem(item) } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).opacity(hovered == item.id ? 1 : 0)
                        .accessibilityLabel("Remove item \"\(item.title)\"")
                }
                .font(.callout)
                .padding(.horizontal, 4)
                .frame(height: 35)
                .onHover { hovered = $0 ? item.id : nil }
            }
            InlineAdd(label: "Add item", placeholder: "Item name", autoOpen: autoOpen) { model.addChecklistItem(list, $0) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor).opacity(0.7)))
    }
}

/// "+ Add …" that becomes a text box; Enter adds and keeps it open, Escape closes it.
struct InlineAdd: View {
    let label: String
    let placeholder: String
    var autoOpen = false
    let onAdd: (String) -> Void
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing || autoOpen && text.isEmpty && !dismissed {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit {
                        let t = text.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        onAdd(t)
                        text = ""
                    }
                    .onExitCommand {
                        editing = false
                        dismissed = true
                    }
            } else {
                Button {
                    editing = true
                } label: { Label(label, systemImage: "plus").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    @State private var dismissed = false
}

// MARK: - Dependencies

struct DependenciesSection: View {
    let model: TaskDetailModel
    let rows: [TaskDependency]
    @State private var kind: DependencyKind
    @State private var adding: Bool
    @State private var search: TagSearch
    @State private var hovered: String?

    init(model: TaskDetailModel, rows: [TaskDependency], justAdded: Bool, initialKind: DependencyKind?) {
        self.model = model
        self.rows = rows
        _kind = State(initialValue: initialKind ?? .blockedBy)
        _adding = State(initialValue: initialKind != nil || (justAdded && rows.isEmpty))
        _search = State(initialValue: TagSearch(area: "task", model: model))
    }

    var body: some View {
        let taken = Set(rows.map(\.id))
        CrmSectionBox(title: "Dependencies", aside: rows.isEmpty ? nil : String(rows.count)) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { r in
                    HStack(spacing: 8) {
                        Text(r.kind.label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.4)
                            .foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                        Text(r.otherTitle).lineLimit(1).strikethrough(r.otherDone)
                            .foregroundStyle(r.otherDone ? Color(nsColor: .tertiaryLabelColor) : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.removeDependency(r) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).opacity(hovered == r.id ? 1 : 0)
                            .accessibilityLabel("Remove dependency on \"\(r.otherTitle)\"")
                    }
                    .font(.callout)
                    .padding(4)
                    .onHover { hovered = $0 ? r.id : nil }
                }
                if !adding {
                    Button { adding = true } label: { Label("Add dependency", systemImage: "link").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            ForEach(DependencyKind.allCases, id: \.self) { k in
                                Button(k.label) { kind = k }
                                    .buttonStyle(.plain)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .foregroundStyle(kind == k ? Color(nsColor: .windowBackgroundColor) : .secondary)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(kind == k ? Color.primary : .clear))
                                    .accessibilityAddTraits(kind == k ? .isSelected : [])
                            }
                            Spacer()
                            Button {
                                adding = false
                                search.query = ""
                            } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Stop adding dependencies")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        Divider()
                        SearchField(placeholder: "Search your tasks", text: $search.query, busy: search.busy)
                        Divider()
                        SearchResults(search: search, none: "No task matches") { h in
                            let already = taken.contains("\(kind.rawValue):\(h.id)")
                            Button { model.addDependency(kind, otherId: h.id, otherTitle: h.label) } label: {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(h.label).lineLimit(1)
                                        if let s = h.secondary { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    }
                                    Spacer()
                                    if let status = h.status {
                                        Text(status).font(.system(size: 10)).padding(.horizontal, 6)
                                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                                    }
                                    if already { Text("Added").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(already)
                            .opacity(already ? 0.45 : 1)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                }
            }
        }
    }
}

/// A bordered section with a small title and a counter (section-shell.tsx).
struct CrmSectionBox<Content: View>: View {
    let title: String
    var aside: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                if let aside { Text(aside).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            content.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Files

struct AttachmentsSection: View {
    let model: TaskDetailModel
    let rows: [TaskAttachment]
    @State private var lightbox: Int?
    @State private var search: TagSearch

    init(model: TaskDetailModel, rows: [TaskAttachment]) {
        self.model = model
        self.rows = rows
        _search = State(initialValue: TagSearch(area: "file", model: model))
    }

    private var photos: [(id: String, image: NSImage)] {
        rows.compactMap { r in
            guard CrmFiles.isImage(mime: r.mimeType, fileName: r.fileName), let url = r.previewUrl, let image = Self.image(url) else { return nil }
            return (r.id, image)
        }
    }

    static func image(_ dataURL: String) -> NSImage? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    var body: some View {
        if !rows.isEmpty || !model.pending.isEmpty || model.linking {
            VStack(alignment: .leading, spacing: 6) {
                TasksFlow(spacing: 6, lineSpacing: 6) {
                    ForEach(rows) { r in chip(r) }
                    ForEach(model.pending) { p in
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(p.fileName).lineLimit(1)
                            Text("Uploading… \(fmtSize(p.sizeBytes))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .font(.caption).padding(.horizontal, 6).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                        .opacity(0.6)
                        .help("Uploading \(p.fileName)")
                    }
                }
                .accessibilityLabel("Attachments")
                if model.linking { linkFromFiles }
            }
            .sheet(isPresented: Binding(get: { lightbox != nil }, set: { if !$0 { lightbox = nil } })) {
                PhotoLightbox(photos: photos.map(\.image), index: lightbox ?? 0) { lightbox = nil }
            }
        }
    }

    private func fmtSize(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(Int((Double(n) / 1024).rounded())) KB" }
        return String(format: "%.1f MB", Double(n) / (1024 * 1024))
    }

    private func chip(_ r: TaskAttachment) -> some View {
        let image = CrmFiles.isImage(mime: r.mimeType, fileName: r.fileName) ? r.previewUrl.flatMap(Self.image) : nil
        let size = r.kind == "document" && r.documentId != nil ? "in Files" : r.sizeBytes.map { fmtSize(Int($0)) }
        return AttachmentChip(name: r.fileName, image: image, isImage: CrmFiles.isImage(mime: r.mimeType, fileName: r.fileName), size: size,
                              onOpen: {
                                  if image != nil, let i = photos.firstIndex(where: { $0.id == r.id }) { lightbox = i } else { model.openFile(r.id) }
                              },
                              onRemove: { model.detach(r) })
    }

    private var linkFromFiles: some View {
        let linked = Set(rows.compactMap(\.documentId))
        return VStack(spacing: 0) {
            HStack {
                SearchField(placeholder: "Search Files", text: $search.query, busy: search.busy) { model.linking = false }
                Button { model.linking = false } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).padding(.trailing, 8).accessibilityLabel("Close Files search")
            }
            Divider()
            SearchResults(search: search, none: "No document matches") { h in
                let already = linked.contains(h.id)
                Button { model.attachDocument(id: h.id, fileName: h.label) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text").foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.label).lineLimit(1)
                            if let s = h.secondary { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer()
                        if already { Text("Added").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(already).opacity(already ? 0.45 : 1)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
    }
}

struct AttachmentChip: View {
    let name: String
    let image: NSImage?
    let isImage: Bool
    let size: String?
    let onOpen: () -> Void
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 3))
                    } else {
                        Image(systemName: isImage ? "photo" : "doc.text").font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .windowBackgroundColor)))
                    }
                    Text(name).lineLimit(1)
                    if hovering, let size { Text(size).font(.caption2).foregroundStyle(.secondary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(image != nil ? "\(name) — click for the big view" : name)
            .accessibilityLabel("Open \(name)")
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 8)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hovering ? 1 : 0)
                    .accessibilityLabel("Remove attachment \"\(name)\"")
            }
        }
        .font(.caption)
        .padding(.leading, 4).padding(.trailing, 4)
        .frame(maxWidth: 256, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(hovering ? 0.2 : 0.12)))
        .onHover { hovering = $0 }
    }
}

/// The photo viewer: the picture, n / N, ‹ › and ← →, × or Esc to close.
struct PhotoLightbox: View {
    let photos: [NSImage]
    @State var index: Int
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea().onTapGesture(perform: onClose)
            if photos.indices.contains(index) {
                Image(nsImage: photos[index]).resizable().scaledToFit().padding(40)
            } else {
                Text("Image unavailable").foregroundStyle(.white.opacity(0.7))
            }
            VStack {
                HStack {
                    Spacer()
                    if photos.count > 1 {
                        Text("\(index + 1) / \(photos.count)").font(.caption.weight(.medium)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 4).background(Capsule().fill(.white.opacity(0.1)))
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 16)
            HStack {
                if photos.count > 1 { round("chevron.left", "Previous photo") { go(-1) } }
                Spacer()
                if photos.count > 1 { round("chevron.right", "Next photo") { go(1) } }
            }
            .padding(.horizontal, 12)
            VStack {
                HStack {
                    Spacer()
                    round("xmark", "Close photo viewer", action: onClose)
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onExitCommand(perform: onClose)
        .accessibilityLabel("Photo viewer")
    }

    private func go(_ step: Int) {
        guard !photos.isEmpty else { return }
        index = (index + step + photos.count) % photos.count
    }

    private func round(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).foregroundStyle(.white).frame(width: 48, height: 48)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// "Attach file": Upload from device, or Link from Files.
struct AttachFileRow: View {
    let model: TaskDetailModel
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("Attach file", systemImage: "paperclip").frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(ActionRowStyle())
        .help("Attach a file")
        .accessibilityLabel("Attach a file")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                menuRow("Upload from device", "arrow.up.doc") {
                    open = false
                    Task { _ = await model.chooseFromDevice() }
                }
                menuRow("Link from Files", "doc.text") {
                    open = false
                    model.reveal(.attachments)
                    model.linking = true
                }
            }
            .padding(.vertical, 4)
            .frame(width: 220)
        }
    }

    private func menuRow(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.callout.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One of the action rows under the sections ("Add subtask", "Create checklist" …).
struct ActionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ActionRowBody(configuration: configuration)
    }

    private struct ActionRowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.callout)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.secondary.opacity(0.08) : .clear))
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - The routine

struct RoutineBlock: View {
    let model: TaskDetailModel
    let routine: RoutineView
    let rule: RoutineRule
    var onOpenRoot: (() -> Void)?
    @State private var all = false
    @State private var arming = false

    private struct Row: Identifiable {
        let id: String, occurrenceDate: String, who: String?, completedBy: String?, completedAt: String?, state: Routine.HistoryState
    }

    var body: some View {
        let today = CrmTime.todayYmd()
        let state = rule.stoppedAt != nil ? "Stopped" : rule.pausedAt != nil ? "Paused" : "Running"
        let rows: [Row] = (routine.history ?? []).compactMap { h in
            guard let o = h.object, let id = o["id"]?.string, let day = o["occurrenceDate"]?.string else { return nil }
            return Row(id: id, occurrenceDate: day, who: o["who"]?.string, completedBy: o["completedBy"]?.string,
                       completedAt: o["completedAt"]?.string,
                       state: Routine.historyState(status: o["status"]?.string ?? "open", completedAt: o["completedAt"]?.string,
                                                   dueDate: o["dueDate"]?.string, occurrenceDate: day, today: today))
        }
        let monthAgo = TaskList.ymdAddDays(today, -30)
        let recent = rows.filter { $0.occurrenceDate >= monthAgo && $0.occurrenceDate <= today }
        let counts = Dictionary(grouping: recent, by: \.state).mapValues(\.count)
        let visible = all ? rows : Array(rows.prefix(14))
        let editable = routine.canEdit && rule.stoppedAt == nil
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "repeat").foregroundStyle(Color.purple)
                Text("Routine").font(.callout.weight(.medium))
                Text(Routine.summary(Routine.running(rule))).font(.callout).lineLimit(2)
                Text(state).font(.caption2.weight(.medium))
                    .foregroundStyle(state == "Running" ? TaskTone.completed : state == "Paused" ? TaskTone.waiting : Color.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill((state == "Running" ? TaskTone.completed : state == "Paused" ? TaskTone.waiting : Color.secondary).opacity(0.12)))
                if state == "Running", let next = routine.next.first {
                    Text("next \(Routine.shortDay(next))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if editable {
                    Button {
                        model.pauseRoutine(rule.pausedAt == nil)
                    } label: { Label(rule.pausedAt != nil ? "Resume" : "Pause", systemImage: rule.pausedAt != nil ? "play.fill" : "pause.fill") }
                        .controlSize(.small)
                    if !arming {
                        Button { arming = true } label: { Label("Stop recurring", systemImage: "stop.fill").foregroundStyle(TaskTone.input) }
                            .controlSize(.small)
                    } else {
                        HStack(spacing: 8) {
                            Button("Stop recurring?") {
                                arming = false
                                model.stopRoutine()
                            }
                            .buttonStyle(.borderedProminent).tint(TaskTone.input).controlSize(.small)
                            Button("Cancel") { arming = false }.controlSize(.small)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Confirm stop recurring")
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if !routine.isRoot {
                HStack(spacing: 4) {
                    Text("One occurrence of the routine on")
                    if let onOpenRoot {
                        Button(routine.rootTitle, action: onOpenRoot).buttonStyle(.link)
                    } else {
                        Text(routine.rootTitle).fontWeight(.medium)
                    }
                    Text("— changes to the routine are made there.")
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
            }
            if let err = routine.lastError {
                Text("\(err.message) · \(localStamp(err.at))").font(.caption).foregroundStyle(TaskTone.waiting)
                    .padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TaskTone.waiting.opacity(0.1))
                Divider()
            }
            if let error = routine.historyError {
                Text("History unavailable: \(error)").font(.caption).foregroundStyle(TaskTone.waiting).padding(12)
            } else if rows.isEmpty {
                Text("No occurrences yet\(routine.next.first.map { " — the first is \(Routine.shortDay($0))" } ?? "").")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            } else {
                Text("Last 30 days: \(counts[.onTime] ?? 0) on time · \(counts[.late] ?? 0) late · \(counts[.missed] ?? 0) missed\((counts[.overdue] ?? 0) > 0 ? " · \(counts[.overdue] ?? 0) overdue" : "")")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 8)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Date"); Text("Who"); Text("Status")
                    }
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(visible) { r in
                        let who = r.who.flatMap { id in model.team.first { $0.id == id } }
                        let by = r.completedBy.flatMap { b in b != r.who ? model.team.first { $0.id == b } : nil }
                        GridRow {
                            Text(Routine.shortDay(r.occurrenceDate))
                            if let who {
                                HStack(spacing: 6) { PersonAvatar(person: who); Text(who.name) }
                            } else {
                                Text("—").foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 6) {
                                Text(r.state.label).font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Capsule().fill(historyTone(r.state).opacity(0.14)))
                                    .foregroundStyle(historyTone(r.state))
                                if (r.state == .onTime || r.state == .late), let at = r.completedAt, let date = CrmTime.date(at) {
                                    Text("\(r.state == .late ? "\(Routine.shortDay(CrmTime.todayYmd(date))) " : "")\(CrmTime.clock(date))\(by.map { " by \($0.name)" } ?? "")")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .font(.system(size: 13))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .accessibilityLabel("Routine history")
                if rows.count > 14 {
                    Button(all ? "Show fewer" : "Show all \(rows.count)") { all.toggle() }
                        .buttonStyle(.link).font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Routine")
    }

    private func historyTone(_ s: Routine.HistoryState) -> Color {
        switch s {
        case .onTime: TaskTone.completed
        case .late: TaskTone.waiting
        case .missed, .overdue: TaskTone.input
        case .open, .skipped: Color.secondary
        }
    }
}

/// "7 Oct 2026, 3:05 pm".
func localStamp(_ iso: String) -> String {
    guard let date = CrmTime.date(iso) else { return "" }
    let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
    return "\(c.day ?? 1) \(TaskList.monthShort[(c.month ?? 1) - 1]) \(c.year ?? 1970), \(CrmTime.clock(date))"
}

// MARK: - Description history

struct DescriptionHistorySheet: View {
    let model: TaskDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                Text("Description history").font(.callout.weight(.semibold))
                Spacer()
                Button { model.historyOpen = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Close description history")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let versions = model.versions {
                        if versions.isEmpty {
                            Text("The description has not been changed yet.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(versions.enumerated()), id: \.offset) { _, v in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(localStamp(v.at)) · \(v.by.flatMap { id in model.team.first { $0.id == id }?.name } ?? "Someone")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let to = v.to {
                                    Text(to).textSelection(.enabled)
                                } else if v.from != nil {
                                    Text("Cleared.").italic().foregroundStyle(.secondary)
                                } else {
                                    Text("Changed — the text was not kept. History starts from when this feature was switched on.")
                                        .italic().foregroundStyle(.tertiary)
                                }
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                        }
                    } else {
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 560, height: 480)
        .onExitCommand { model.historyOpen = false }
    }
}
