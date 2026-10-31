import AppKit
import SwiftUI
import TerminalDeckNativeCore

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
                Button { collapsed.toggle() } label: {
                    HStack(spacing: 8) {
                Image(systemName: "chevron.down").rotationEffect(.degrees(collapsed ? -90 : 0)).foregroundStyle(.secondary)
                Text("Subtasks").font(.callout.weight(.semibold))
                if !rows.isEmpty {
                    Text("\(open) open").foregroundStyle(.secondary)
                    ProgressBarSmall(done: rows.count - open, total: rows.count)
                }
                if forMe > 0 {
                    Text("\(forMe) for me").font(.caption.weight(.medium)).foregroundStyle(TaskTone.accent)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(Capsule().fill(TaskTone.accent.opacity(0.12)))
                }
                Spacer()
                    }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(SIDEBARRowStyle())
                    .accessibilityLabel(collapsed ? "Expand subtasks" : "Collapse subtasks")
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
                                HStack { Text(label); Spacer(); if sort == key { Image(systemName: "checkmark").foregroundStyle(TaskTone.accent) } }
                                    .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 6).frame(width: 180)
                }
                Button { adding = true } label: { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle()) }
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

struct SubtaskLine: View {
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
            Button { model.deleteSubtask(row) } label: { Image(systemName: "xmark").font(.caption2).frame(width: 28, height: 28).contentShape(Rectangle()) }
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

struct AddSubtaskRow: View {
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
            Button("Save ↵", action: save).buttonStyle(.borderedProminent).tint(TaskTone.accent).controlSize(.small)
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
