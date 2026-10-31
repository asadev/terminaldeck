import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The main Tasks list (Asad, 13 Oct, with an all-tasks page of another tracker beside him: "only the
// main page where we see all the tasks"). Patterns, written here: a dense list; each group's header
// carries the column titles and stays on top while its rows scroll by; cells read as quiet text and
// open their menu on a click; a row shows its checkbox and ⋯ while the pointer is on it; "+ Add Task"
// ends every group and opens the one create card with that group's values; child tasks fold under
// their parent. Rows are drawn lazily, so a long list stays quick. Task data, changes and the task
// popup are the existing ones.

/// Which columns fit beside the name, and how wide each is.
struct TasksListColumns: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case assignee, due, priority, status, goal, project, created
        var id: String { rawValue }

        var width: CGFloat {
            switch self {
            case .assignee: 150
            case .due: 104
            case .priority: 100
            case .status: 128
            case .goal: 132
            case .project: 120
            case .created: 92
            }
        }

        var title: String {
            switch self {
            case .assignee: "Assignee"
            case .due: "Due date"
            case .priority: "Priority"
            case .status: "Status"
            case .goal: "Goal"
            case .project: "Project"
            case .created: "Date created"
            }
        }
    }

    /// The checkbox gutter on the left and the hover ⋯ on the right.
    static let lead: CGFloat = 26
    static let trail: CGFloat = 30
    /// Below this the name stops being readable, so columns give way from the right.
    static let minName: CGFloat = 240
    static let rowHeight: CGFloat = 48

    let shown: [Kind]
    var nameWidth: CGFloat = 240
    var widths: [String: Double] = [:]
    func width(_ kind: Kind) -> CGFloat { CGFloat(widths[kind.rawValue] ?? Double(kind.width)) }

    /// The person's columns, in the list's order. Status shows only when the groups are not statuses,
    /// and Project only when the list is not already in project sections. Columns drop, least needed
    /// first, until the name has room; Due date always stays.
    static func fitting(width: CGFloat, columns: TasksColumns, statusGroups: Bool, projectSections: Bool,
                        hasGoals: Bool) -> TasksListColumns {
        var wanted: [Kind] = []
        if columns.assignee { wanted.append(.assignee) }
        if columns.due { wanted.append(.due) }
        if columns.priority { wanted.append(.priority) }
        if columns.status && !statusGroups { wanted.append(.status) }
        if columns.goal && hasGoals { wanted.append(.goal) }
        if columns.project && !projectSections { wanted.append(.project) }
        if columns.created { wanted.append(.created) }
        wanted = columns.order.compactMap(Kind.init(rawValue:)).filter { wanted.contains($0) }
        let room = width - lead - trail - 16
        for kind in [Kind.created, .project, .goal, .status, .priority, .assignee]
        where room - wanted.reduce(0, { $0 + CGFloat(columns.width($1.rawValue)) }) < minName {
            wanted.removeAll { $0 == kind }
        }
        return TasksListColumns(shown: wanted, nameWidth: max(120, room - wanted.reduce(0, { $0 + CGFloat(columns.width($1.rawValue)) })), widths: columns.widths)
    }
}

/// The list itself: project sections (All projects), pinned group headers, lazy rows.
struct NativeTasksAllList: View {
    let model: MyWorkModel
    let state: TasksState
    let drawn: MyWorkModel.Drawn
    var projects: TKTasksProjectScope = .shared
    let onReorder: (ListGroup, String, String) -> Void
    @State private var width: CGFloat = 900
    private var store: TasksStore { TasksStore.shared }

    private var statusGroups: Bool { model.view.groupBy == .status }

    var body: some View {
        let columns = TasksListColumns.fitting(width: width, columns: model.view.columns, statusGroups: statusGroups,
                                               projectSections: drawn.byProject, hasGoals: !state.goals.isEmpty)
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(drawn.sections) { section in
                    if let label = section.label { sectionHeading(section, label: label) }
                    if section.label == nil || !model.isFolded("section:\(section.key)", startsFolded: false) {
                        ForEach(section.groups) { group in groupSection(group, columns: columns) }
                    }
                }
            }
            .padding(.bottom, 32)
        }
        .scrollIndicators(.automatic)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task list")
    }

    // MARK: A project's heading (All projects)

    private func sectionHeading(_ section: TaskListSection, label: String) -> some View {
        let key = "section:\(section.key)"
        let open = !model.isFolded(key, startsFolded: false)
        return Button { model.toggleFold(key, startsFolded: false) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(label).font(.headline).lineLimit(1)
                Text("\(section.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(section.count) tasks")
        .accessibilityValue(open ? "expanded" : "collapsed")
    }

    // MARK: A group: pinned header, its lines, Add Task

    private func groupSection(_ group: ListGroup, columns: TasksListColumns) -> some View {
        let open = !model.isFolded(group.key, startsFolded: group.folded)
        let lines = open ? TasksAllList.lines(group.items, nesting: drawn.nesting, isOpen: model.isParentOpen) : []
        let orderable = model.view.sort == .automatic && (group.key == TaskList.reorderableGroupKey || group.key.hasSuffix("|" + TaskList.reorderableGroupKey))
        let selecting = !model.selected.isEmpty
        return Section {
            ForEach(lines) { line in
                TasksListRow(line: line, state: state, columns: columns, today: drawn.today, nowHm: drawn.nowHm,
                    busy: store.busy, selected: model.selected.contains(line.task.id), selecting: selecting,
                    open: model.open == line.task.id, orderable: orderable && line.depth == 0,
                    onSelect: { on in if on { model.selected.insert(line.task.id) } else { model.selected.remove(line.task.id) } },
                    onOpen: { model.open = line.task.id },
                    onToggleChildren: { model.toggleParent(line.task.id) },
                    onDrop: { onReorder(group, line.task.id, $0) }, projects: projects)
            }
            if open && !model.view.filters.archived {
                TasksListAddRow(defaults: group.defaults, busy: store.busy)
            }
            if open { Color.clear.frame(height: 10) }
        } header: {
            TasksListGroupHeader(group: group, columns: columns, open: open, statusPill: isStatusGroup(group),
                                 adding: !model.view.filters.archived, onResize: { kind, width in
                model.view.columns.resize(kind.rawValue, to: Double(width))
            }) {
                model.toggleFold(group.key, startsFolded: group.folded)
            }
        }
    }

    private func isStatusGroup(_ group: ListGroup) -> Bool {
        group.key.hasSuffix("__closed") || group.key.hasPrefix("status:") || group.key.contains("|status:")
    }
}

/// A group's header: fold, the group as a coloured pill (statuses) or its name, the count, a "+" on
/// hover, then the column titles over their cells. Opaque, because it stays on top while rows scroll.
struct TasksListGroupHeader: View {
    let group: ListGroup
    let columns: TasksListColumns
    let open: Bool
    let statusPill: Bool
    let adding: Bool
    var onResize: (TasksListColumns.Kind, CGFloat) -> Void = { _, _ in }
    let onFold: () -> Void
    @State private var hovering = false
    @Environment(\.openTaskCreate) private var openTaskCreate

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onFold) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    if statusPill {
                        TasksStatusPill(status: group.label, prominent: true)
                    } else {
                        Text(group.label)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(group.accent == .overdue ? TaskTone.input : group.accent == .today ? Color.accentColor : .primary)
                            .lineLimit(1)
                    }
                    Text("\(group.items.count)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.label), \(group.items.count) tasks")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if adding {
                Button { openTaskCreate?.open(.addTaskRow(group.defaults)) } label: {
                    Image(systemName: "plus").font(.caption.weight(.semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
                .opacity(hovering ? 1 : 0)
                .disabled(openTaskCreate == nil)
                .help("Add a task to \(group.label)")
                .accessibilityLabel("Add a task to \(group.label)")
            }
            Spacer(minLength: 8)
            if open {
                ForEach(columns.shown) { kind in
                    TasksColumnTitle(kind: kind, width: columns.width(kind)) { onResize(kind, $0) }
                }
            }
            Color.clear.frame(width: TasksListColumns.trail)
        }
        .padding(.leading, 8 + TasksListColumns.lead - 14)
        .padding(.trailing, 8)
        .frame(height: 36)
        .background(.background)
        .onHover { hovering = $0 }
    }
}

/// A status as a small tinted pill: the colour of its ring, in capitals on the group header.
struct TasksStatusPill: View {
    let status: String
    var prominent = false

    var body: some View {
        let tone = TaskTone.status(status)
        Text(prominent ? status.uppercased() : status)
            .font(.caption.weight(.semibold))
            .tracking(prominent ? 0.4 : 0)
            .lineLimit(1)
            .foregroundStyle(tone)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tone.opacity(0.16)))
    }
}

/// One task line.
struct TasksListRow: View {
    let line: TaskListLine
    let state: TasksState
    let columns: TasksListColumns
    let today: String
    let nowHm: String
    let busy: Bool
    let selected: Bool
    /// Some task is selected: every checkbox stays visible.
    let selecting: Bool
    let open: Bool
    let orderable: Bool
    let onSelect: (Bool) -> Void
    let onOpen: () -> Void
    let onToggleChildren: () -> Void
    let onDrop: (String) -> Void
    var projects: TKTasksProjectScope = .shared
    @State private var hovering = false
    @State private var dropTarget = false
    @State private var renaming = false
    @State private var editingTags = false
    @State private var titleDraft = ""
    @State private var tagsDraft = ""
    private var store: TasksStore { TasksStore.shared }
    private var task: TaskRow { line.task }
    private var done: Bool { task.crmStatus == "Done" }

    var body: some View {
        HStack(spacing: 0) {
            Toggle("", isOn: Binding(get: { selected }, set: { onSelect($0) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: TasksListColumns.lead, alignment: .leading)
                .opacity(hovering || selected || selecting ? 1 : 0)
                .accessibilityLabel("Select \(task.title)")
            Color.clear.frame(width: CGFloat(line.depth) * 20)
            disclosure
            TaskRing(task: task, busy: busy) { update(["status": done ? "To-Do" : "Done"]) }
                .padding(.trailing, 8)
            name
            ForEach(columns.shown) { kind in
                cell(kind).frame(width: columns.width(kind), alignment: .leading)
            }
            moreMenu
        }
        .padding(.horizontal, 8)
        .frame(height: TasksListColumns.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(alignment: .top) { if dropTarget { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            guard orderable, let dragged = items.first, dragged != task.id else { return false }
            onDrop(dragged)
            return true
        } isTargeted: { dropTarget = orderable && $0 }
        .contextMenu {
            Button("Rename") { beginRename() }
            Button("Edit tags") { beginTags() }
            TKMoveToProjectMenu(task: task, projects: projects)
        }
        .popover(isPresented: $renaming) { editTitle }
        .popover(isPresented: $editingTags) { editTags }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.title)
    }

    private var fill: Color {
        if open { return Color(nsColor: .unemphasizedSelectedContentBackgroundColor) }
        if selected { return Color.accentColor.opacity(0.12) }
        if hovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    private func update(_ patch: [String: Any]) {
        Task { await store.run { await store.update(task.id, patch) } }
    }

    @ViewBuilder private var disclosure: some View {
        if line.childCount > 0 {
            Button(action: onToggleChildren) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .rotationEffect(.degrees(line.open ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(line.open ? "Hide its child tasks" : "Show its child tasks")
            .accessibilityLabel(line.open ? "Hide child tasks of \(task.title)" : "Show child tasks of \(task.title)")
        } else if orderable {
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 16)
                .opacity(hovering ? 1 : 0)
                .help("Drag to reorder your Today")
                .accessibilityLabel("Drag \(task.title) to reorder")
                .draggable(task.id)
        } else {
            Color.clear.frame(width: 16)
        }
    }

    // MARK: Name, cues and tags

    private var name: some View {
        let compact = columns.nameWidth < 360
        let tags = Array(task.labels.prefix(compact ? 0 : columns.nameWidth < 500 ? 1 : 2))
        return HStack(spacing: 6) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .lineLimit(1).truncationMode(.tail).strikethrough(done)
                        .foregroundStyle(done ? Color(nsColor: .tertiaryLabelColor) : .primary)
                    if !columns.shown.contains(.created) {
                        Text(task.createdAt > 0 ? "Created " + TaskList.createdLabel(task.createdAt, today: today) : "Creation date unavailable")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(task.title)
            .accessibilityHint("Opens the task")
            .layoutPriority(1)
            if line.childCount > 0 {
                Button(action: onToggleChildren) {
                    Label("\(line.childCount)", systemImage: "arrow.turn.down.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("\(line.childCount) child \(line.childCount == 1 ? "task" : "tasks")")
            }
            if !task.instructions.isEmpty {
                Image(systemName: "text.alignleft").font(.caption2).foregroundStyle(.tertiary).help("Has details")
            }
            if compact { compactCues } else { cues }
            ForEach(tags, id: \.self) { tag in
                TagPill(text: tag).lineLimit(1).frame(maxWidth: 110).fixedSize(horizontal: true, vertical: false).help(tag)
            }
            if task.labels.count > tags.count {
                Label("\(task.labels.count - tags.count)", systemImage: "tag")
                    .font(.caption).foregroundStyle(.secondary).fixedSize()
                    .help(task.labels.joined(separator: ", "))
            }
            Spacer(minLength: 8)
            if hovering {
                Button { beginTags() } label: { Image(systemName: "tag").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).disabled(busy).help("Edit tags").accessibilityLabel("Edit tags for \(task.title)")
                Button { beginRename() } label: { Image(systemName: "pencil").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).disabled(busy).help("Rename").accessibilityLabel("Rename \(task.title)")
            }
        }
        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
    }

    private func beginRename() { titleDraft = task.title; renaming = true }
    private func beginTags() { tagsDraft = task.labels.joined(separator: ", "); editingTags = true }
    private var editTitle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rename task").font(.headline)
            TextField("Task name", text: $titleDraft).textFieldStyle(.roundedBorder).onSubmit { saveTitle() }
            HStack { Button("Cancel") { renaming = false }; Spacer(); Button("Save") { saveTitle() }
                    .disabled(busy || titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(16).frame(width: 320)
    }
    private func saveTitle() {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !busy else { return }
        renaming = false; update(["title": title])
    }
    private var editTags: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit tags").font(.headline)
            TextField("Tags, separated by commas", text: $tagsDraft).textFieldStyle(.roundedBorder).onSubmit { saveTags() }
            Text("Separate tags with commas. Clear the box to remove them.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Cancel") { editingTags = false }; Spacer(); Button("Save") { saveTags() }.disabled(busy) }
        }.padding(16).frame(width: 320)
    }
    private func saveTags() {
        guard !busy else { return }
        var seen = Set<String>()
        let tags = tagsDraft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        editingTags = false; update(["labels": tags])
    }

    /// In a narrow list the same work cues use small marks, leaving the task's name readable.
    @ViewBuilder private var compactCues: some View {
        if let stalled = task.stalled {
            Image(systemName: "exclamationmark.circle").foregroundStyle(TaskTone.input).help(stalled.text)
        } else if let from = task.handedFrom {
            Image(systemName: "arrow.turn.down.left").foregroundStyle(TaskTone.input).help("\(from) handed this to you")
        } else if let first = task.waitingOn.first {
            Image(systemName: "hourglass").foregroundStyle(.secondary).help("Waits for \(first)")
        } else if task.assignee != "me", task.assignee != "none", !done {
            if task.process == .running {
                Image(systemName: "bolt.fill").foregroundStyle(.secondary).help("Its agent is working")
            } else if task.process == .queued {
                Image(systemName: "clock").foregroundStyle(.secondary).help("Waiting to start")
            }
        }
    }

    /// The cues the old rows had, as small tinted words: who is working, what it waits for, trouble.
    @ViewBuilder private var cues: some View {
        if let from = task.handedFrom { TasksListCue(text: "from \(from)", attention: true, help: "\(from) handed this to you") }
        if let stalled = task.stalled {
            TasksListCue(text: stalled.reason == .exited ? "stopped early" : "stalled", attention: true, help: stalled.text)
        }
        // FORK-TASKS (11 Oct): whoever holds it, an agent or Hoot, shows the same cue while it works and waits.
        if task.assignee != "me", task.assignee != "none", !done {
            if task.process == .running {
                TasksListCue(text: "working", help: "\(MyWorkModel.name(of: task.assignee, in: state)) is working on this now")
            } else if task.process == .queued {
                TasksListCue(text: "waiting to start", help: "\(MyWorkModel.name(of: task.assignee, in: state)) has it and starts as soon as it is free")
            }
        }
        if let first = task.waitingOn.first {
            TasksListCue(text: "waits for \(first)\(task.waitingOn.count > 1 ? " +\(task.waitingOn.count - 1)" : "")",
                         help: "Its agent starts when these are Done: \(task.waitingOn.joined(separator: ", "))")
        }
    }

    // MARK: Cells: quiet text, a menu on click

    @ViewBuilder private func cell(_ kind: TasksListColumns.Kind) -> some View {
        switch kind {
        case .assignee: assigneeCell
        case .due:
            TasksListDueCell(task: task, today: today, nowHm: nowHm, busy: busy, hovering: hovering) {
                update(["dueDate": $0 ?? NSNull()])
            }
        case .priority: priorityCell
        case .status: statusCell
        case .goal: goalCell
        case .project:
            Text(task.project.split(separator: "/").last.map(String.init) ?? task.project)
                .font(.callout).foregroundStyle(.secondary).lineLimit(1).help(task.project)
        case .created:
            Text(task.createdAt > 0 ? TaskList.createdLabel(task.createdAt, today: today) : "—").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var assigneeCell: some View {
        // Use this list's project snapshot, including in scratch renders. Reading choices must not start the app.
        let existing = Set(state.agents.map(\.id))
        let leads = AGTLeads.sessionLeadSeats(projects.registry).filter { !existing.contains($0.id) }
        let choices = TasksRules.assigneeChoices(state.agents + leads)
        let name = MyWorkModel.name(of: task.assignee, in: state)
        return Menu {
            ForEach(choices, id: \.id) { choice in
                Button { update(["assignee": choice.id]) } label: {
                    DeckRowLabel(choice.label, image: DeckRowIcon.assignee(choice.id))
                }
            }
        } label: {
            if task.assignee == "none" {
                Image(systemName: "person.crop.circle.badge.plus")
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0.5)
            } else {
                HStack(spacing: 6) {
                    Image(nsImage: DeckRowIcon.assignee(task.assignee))
                    Text(name).font(.callout).lineLimit(1)
                }
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(busy)
        .help(task.assignee == "none" ? "Nobody has it yet. Choose who has it" : "\(name) has it")
        .accessibilityLabel("Who has \(task.title): \(task.assignee == "none" ? "nobody" : name)")
    }

    private var priorityCell: some View {
        Menu {
            ForEach(TaskList.priorities, id: \.self) { priority in
                Button { update(["priority": priority]) } label: { Label(priority, systemImage: "flag.fill") }
            }
            Divider()
            Button("No priority") { update(["priority": NSNull()]) }
        } label: {
            if let priority = task.priority {
                HStack(spacing: 5) {
                    Image(systemName: "flag.fill").foregroundStyle(TaskTone.priority(priority))
                    Text(priority).font(.callout).lineLimit(1)
                }
            } else {
                Image(systemName: "flag").foregroundStyle(.tertiary).opacity(hovering ? 1 : 0.5)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(busy)
        .help(task.priority.map { "Priority: \($0)" } ?? "No priority. Choose one")
        .accessibilityLabel("Priority of \(task.title): \(task.priority ?? "none")")
    }

    private var statusCell: some View {
        Menu {
            if !TaskList.statusOrder.contains(task.crmStatus) { Text(task.crmStatus) }
            ForEach(TaskList.statusOrder, id: \.self) { status in
                Button(status) { update(["status": status]) }
            }
        } label: {
            TasksStatusPill(status: task.crmStatus)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(busy)
        .accessibilityLabel("Status of \(task.title): \(task.crmStatus)")
    }

    private var goalCell: some View {
        let choices = Goals.options(state.goals)
        let current = choices.first { $0.id == task.goalId }?.label
        return Menu {
            Button("No goal") { update(["goalId": NSNull()]) }
            Divider()
            ForEach(choices, id: \.id) { goal in Button(goal.label) { update(["goalId": goal.id]) } }
        } label: {
            if let current {
                Text(current).font(.callout).lineLimit(1)
            } else {
                Image(systemName: "target").foregroundStyle(.tertiary).opacity(hovering ? 1 : 0.5)
            }
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .disabled(busy)
        .accessibilityLabel("Goal of \(task.title): \(current ?? "none")")
    }

    // MARK: The row's ⋯

    private var moreMenu: some View {
        let next = TaskList.nextStatus(task.crmStatus)
        return Menu {
            Button("Open task") { onOpen() }
            if let next { Button("Move to \(next)") { update(["status": next]) } }
            Button(done ? "Reopen" : "Mark done") { update(["status": done ? "To-Do" : "Done"]) }
            TKMoveToProjectMenu(task: task, projects: projects)
            Divider()
            Button("Delete", role: .destructive) { Task { await store.run { await store.remove(task.id) } } }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: TasksListColumns.trail, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .opacity(hovering ? 1 : 0)
        .disabled(busy)
        .help("More for this task")
        .accessibilityLabel("More for \(task.title)")
    }
}

/// A small tinted word beside a task's name.
struct TasksListCue: View {
    let text: String
    var attention = false
    var help: String?

    var body: some View {
        Text(text)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(attention ? TaskTone.input : Color.secondary)
            .background(Capsule().fill((attention ? TaskTone.input : Color.secondary).opacity(0.14)))
            .fixedSize()
            .help(help ?? "")
    }
}

/// The due cell: "Today", "Tomorrow", "15 Oct", red when overdue; empty shows a calendar on hover.
struct TasksListDueCell: View {
    let task: TaskRow
    let today: String
    let nowHm: String
    let busy: Bool
    let hovering: Bool
    let onPick: (String?) -> Void
    @State private var picking = false

    var body: some View {
        let due = TaskList.relativeDue(task.dueDate, today: today)
        let overdue = TaskList.isOverdue(task, today: today, nowHm: nowHm)
        Button { picking = true } label: {
            if due.isEmpty {
                Image(systemName: "calendar").foregroundStyle(.tertiary).opacity(hovering ? 1 : 0.5)
            } else {
                Text("\(due)\(task.dueTime.map { ", \($0)" } ?? "")")
                    .font(.callout)
                    .foregroundStyle(overdue ? TaskTone.input : Color.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help(overdue ? "Overdue: \(task.dueDate ?? "")" : task.dueDate ?? "No due date. Choose one")
        .accessibilityLabel("Due date of \(task.title): \(due.isEmpty ? "none" : due)")
        .popover(isPresented: $picking) {
            DayPicker(ymd: task.dueDate) { picked in
                picking = false
                onPick(picked)
            }
        }
    }
}

/// "+ Add Task" at the end of a group: opens the one create card with the group's values.
struct TasksListAddRow: View {
    let defaults: GroupDefaults?
    let busy: Bool
    @State private var hovering = false
    @Environment(\.openTaskCreate) private var openTaskCreate

    var body: some View {
        Button { openTaskCreate?.open(.addTaskRow(defaults)) } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.caption.weight(.semibold))
                Text("Add Task").font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.leading, 8 + TasksListColumns.lead + 16)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.05) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(busy || openTaskCreate == nil)
        .accessibilityLabel("Add task")
    }
}

/// A wide enough edge to grab without interfering with the title.
private struct TasksColumnTitle: View {
    let kind: TasksListColumns.Kind
    let width: CGFloat
    let resize: (CGFloat) -> Void
    @State private var start: CGFloat?
    var body: some View {
        Text(kind.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .frame(width: width, alignment: .leading)
            .overlay(alignment: .trailing) {
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1, height: 14)
                    .frame(width: 10, height: 26).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if start == nil { start = width }
                            resize((start ?? width) + value.translation.width)
                        }.onEnded { _ in start = nil })
                    .help("Drag to resize \(kind.title)")
                    .accessibilityLabel("Resize \(kind.title)")
                    .accessibilityAdjustableAction { direction in resize(width + (direction == .increment ? 12 : -12)) }
            }
    }
}
