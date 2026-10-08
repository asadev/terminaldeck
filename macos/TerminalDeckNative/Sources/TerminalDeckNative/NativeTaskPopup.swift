import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TerminalDeckNativeCore

/// One of your own tasks, opened in the reference CRM's task page
/// (src/renderer/crm-task/LocalTaskPopup.tsx + task-detail-panel.tsx): the header,
/// the task (type, heading, properties, text, description, fields, routine,
/// subtasks, relationships, checklists, files), the rail, and Activity.
struct NativeTaskPopup: View {
    let task: TaskRow
    let tasks: [TaskRow]
    let linkedTasks: [TaskRow]
    let siblings: [String]
    let agents: [AgentProfile]
    let onNavigate: (String) -> Void
    let onClose: () -> Void
    let onDelete: (String) -> Void
    @State private var model: TaskDetailModel?

    var body: some View {
        Group {
            if let model, model.taskId == task.id {
                TaskPageView(model: model, tasks: tasks, linkedTasks: linkedTasks, siblings: siblings, onNavigate: onNavigate, onClose: onClose, onDelete: onDelete)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        // Opening a different task starts the page fresh for it.
        .onChange(of: task.id, initial: true) { _, _ in
            model?.flushRenames()
            model = TaskDetailModel(row: task, agents: agents)
        }
        .onChange(of: task) { _, row in model?.update(row: row, agents: agents) }
        .onDisappear { model?.flushRenames() }
    }
}

/// A slash command of the comment box (task-detail-panel.tsx `commands`).
struct SlashCommand: Identifiable {
    struct Option: Identifiable {
        let key: String
        let label: String
        var person: CrmPerson?
        let run: () -> Void
        var id: String { key }
    }

    let key: String
    let group: String
    let label: String
    let icon: String
    var run: (() -> Void)?
    var options: [Option] = []
    var id: String { key }
}

private struct TaskPageView: View {
    let model: TaskDetailModel
    let tasks: [TaskRow]
    let linkedTasks: [TaskRow]
    let siblings: [String]
    let onNavigate: (String) -> Void
    let onClose: () -> Void
    let onDelete: (String) -> Void
    @State private var editingTitle = false
    /// The properties column's width: two property pairs per row when they fit, one when they would overlap.
    @State private var gridWidth: CGFloat = 900
    @State private var titleDraft = ""
    @State private var savingTitle = false
    @State private var titleInsertion: TaskTextInsertion?
    @State private var dropping = false
    @State private var relateOpen = false
    @State private var lightbox: [NSImage]?
    @State private var lightboxIndex = 0

    private var boards: [String] {
        Array(Set(tasks.compactMap(\.board).filter { !$0.isEmpty })).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    private var taskOptions: [(id: String, title: String)] {
        tasks.filter { $0.id != model.taskId && $0.archivedAt == nil }.map { ($0.id, $0.title) }
    }

    var body: some View {
        let t = model.task
        VStack(spacing: 0) {
            TaskPageHeader(model: model, boards: boards, siblings: siblings, taskOptions: taskOptions,
                           onNavigate: onNavigate, onClose: onClose, onDelete: { onDelete(model.taskId) },
                           onGone: { open in if let open { onNavigate(open) } else { onClose() } },
                           onRelate: { kind in model.relate(kind) })
            VStack(alignment: .leading, spacing: 8) {
                NativeTAGTaskLinks(task: model.row, tasks: linkedTasks, onOpen: onNavigate)
                NativeTAGKeptSession(task: model.row)
            }.padding(.horizontal, 20)
            if model.more?.archivedAt != nil {
                banner(icon: "archivebox", text: "This task is archived — it is out of the list.", tone: TaskTone.waiting) {
                    if model.canEditRow {
                        Button("Restore") { model.setArchived(false) }.buttonStyle(.link).font(.caption.weight(.medium))
                    }
                }
            }
            if let error = model.error {
                banner(icon: "exclamationmark.circle", text: error, tone: TaskTone.input) {
                    Button { model.error = nil } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
            }
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        content(t, proxy: proxy)
                            .frame(maxWidth: 1000, alignment: .leading)
                            .padding(.leading, 56)
                            .padding(.trailing, 24)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .overlay(alignment: .topTrailing) { rail(proxy) }
                }
                .frame(minWidth: 360)
                if model.activityOpen {
                    Divider()
                    TaskActivityPane(model: model, commands: commands, onAttach: { urls in await model.upload(urls) })
                        .frame(minWidth: 320, idealWidth: 480, maxWidth: 560)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if dropping { dropOverlay } }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            Task { await dropped(providers) }
            return true
        }
        .environment(\.taskFileDoor, TaskFileDoor(attach: { urls in Task { await attach(urls) } }, hover: { dropping = $0 }))
        .background(TaskPasteDoorHost { urls in Task { await attach(urls) } })
        .onExitCommand { if !editingTitle { onClose() } }
        .sheet(isPresented: Binding(get: { model.historyOpen }, set: { model.historyOpen = $0 })) {
            DescriptionHistorySheet(model: model)
        }
        .sheet(isPresented: Binding(get: { lightbox != nil }, set: { if !$0 { lightbox = nil } })) {
            PhotoLightbox(photos: lightbox ?? [], index: lightboxIndex) { lightbox = nil }
        }
        .frame(maxWidth: model.full ? .infinity : 1440, maxHeight: model.full ? .infinity : 900)
    }

    private func banner<Trailing: View>(icon: String, text: String, tone: Color, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.caption)
            Text(text).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            trailing()
        }
        .foregroundStyle(tone)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(tone.opacity(0.1)))
        .padding(.horizontal, 20).padding(.top, 12)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
            .foregroundStyle(Color.accentColor)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
            .overlay(Label("Drop to attach", systemImage: "paperclip").font(.callout.weight(.medium)).foregroundStyle(Color.accentColor))
            .padding(8)
            .allowsHitTesting(false)
    }

    /// Files dropped anywhere on the page: attached, and placed in the text while it is being edited.
    private func dropped(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
               let file = URL(dataRepresentation: url, relativeTo: nil) {
                urls.append(file)
            }
        }
        await attach(urls)
    }

    /// Dropped or pasted files: onto the task, and into the heading while it is being written.
    private func attach(_ urls: [URL]) async {
        let done = await model.upload(urls)
        if editingTitle { for a in done { titleInsertion = .file(a.id) } }
    }

    // MARK: The column

    @ViewBuilder
    private func content(_ t: CrmTask, proxy: ScrollViewProxy) -> some View {
        let peopleRows = model.people?.list ?? []
        let split = CrmText.split(t.title)
        let isDone = t.group == "Done"
        VStack(alignment: .leading, spacing: 0) {
            // TOP ROW — Task ⌄ · ⚭ n · ☰ n · n for me
            HStack(spacing: 12) {
                if let extras = model.extras {
                    TypePill(value: extras.taskType, canEdit: model.canEditRow) { model.changeType($0) }
                }
                let subs = model.subtasks ?? []
                if !subs.isEmpty {
                    Label("\(subs.count)", systemImage: "arrow.triangle.branch").help("\(subs.count) subtasks")
                        .accessibilityLabel("\(subs.count) subtasks")
                }
                let items = (model.checklists ?? []).flatMap(\.items)
                if !items.isEmpty {
                    Label("\(items.count)", systemImage: "checklist").help("\(items.count) checklist items")
                        .accessibilityLabel("\(items.count) checklist items")
                }
                if model.forMe > 0, let me = model.meperson {
                    HStack(spacing: 4) { PersonAvatar(person: me); Text("\(model.forMe) for me") }.foregroundStyle(Color.purple)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(minHeight: 28)
            .padding(.bottom, 8)

            // THE HEADING — click to edit the whole text.
            if editingTitle {
                VStack(alignment: .trailing, spacing: 6) {
                    TaskTextEditor(text: $titleDraft, team: model.team, font: .systemFont(ofSize: 16),
                                   fileOf: fileOf, onMention: { model.invite($0) },
                                   onEscape: { editingTitle = false }, insertion: $titleInsertion)
                        .padding(8)
                        .frame(minHeight: 88, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.6)))
                        .accessibilityLabel("Task")
                    HStack(spacing: 8) {
                        Button("Cancel") { editingTitle = false }.disabled(savingTitle)
                        Button {
                            Task {
                                savingTitle = true
                                if await model.saveTitle(titleDraft) { editingTitle = false }
                                savingTitle = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if savingTitle { ProgressView().controlSize(.mini) }
                                Text("Save")
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(.purple)
                        .disabled(titleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || savingTitle)
                    }
                    .controlSize(.small)
                }
                .padding(.bottom, 12)
            } else {
                TaskRichText(text: .constant(split.heading), editable: false, font: .systemFont(ofSize: 26, weight: .bold),
                             color: isDone ? .tertiaryLabelColor : .labelColor, strike: isDone, fileOf: fileOf,
                             mentionNames: peopleRows.map(\.name),
                             onClickText: model.canEditRow ? { startTitleEdit() } : nil,
                             onClickFile: { openPicture($0) }, insertion: .constant(nil))
                    .help(model.canEditRow ? "Click to edit" : "")
                    .accessibilityLabel(model.canEditRow ? "Edit task" : t.title)
                    .padding(.bottom, 12)
            }

            properties(t)

            if let reason = model.extrasErrorText {
                Text(reason == "This isn't available yet."
                     ? "Task type, tags, time tracking, recurring options and subtask priority and due dates aren't available yet."
                     : "Task type, tags, time tracking, recurring options and subtask details couldn't be loaded — try again.")
                    .font(.caption2).foregroundStyle(TaskTone.waiting).padding(.top, 4)
            }
            HStack(spacing: 12) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                Button(model.hideEmpty ? "Show empty fields" : "Collapse empty fields") { model.hideEmpty.toggle() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.tertiary)
                    .accessibilityAddTraits(model.hideEmpty ? .isSelected : [])
            }
            .padding(.top, 8)

            // THE BODY — the rest of the task text, then the description.
            if !split.body.isEmpty && !editingTitle {
                TaskRichText(text: .constant(split.body), editable: false, font: .systemFont(ofSize: 13), fileOf: fileOf,
                             mentionNames: peopleRows.map(\.name),
                             onClickText: model.canEditRow ? { startTitleEdit() } : nil,
                             onClickFile: { openPicture($0) }, insertion: .constant(nil))
                    .accessibilityLabel(model.canEditRow ? "Edit task text" : split.body)
                    .padding(.top, 12)
            }
            DetailsBlock(model: model).padding(.top, 12)

            TaskFieldsSection(model: model, onNavigate: onNavigate).padding(.top, 12)

            if let routine = model.routine, let rule = Routine.normalize(routine.rule) {
                RoutineBlock(model: model, routine: routine, rule: rule,
                             onOpenRoot: routine.isRoot ? nil : { onNavigate(routine.rootTaskId) })
                    .padding(.top, 16)
            }

            sections(proxy: proxy).padding(.top, 16)
        }
    }

    private func startTitleEdit() {
        titleDraft = model.task.title
        editingTitle = true
    }

    private func fileOf(_ id: String) -> InlineFile? {
        guard let rows = model.attachments else { return InlineFile(image: nil, name: "Loading attachment…") }
        guard let a = rows.first(where: { $0.id == id }) else { return nil }
        let picture = CrmFiles.isImage(mime: a.mimeType, fileName: a.fileName) ? a.previewUrl.flatMap(AttachmentsSection.image) : nil
        return InlineFile(image: picture, name: a.fileName)
    }

    /// A picture in the text opens the big view; any other file opens in the Mac's own app.
    private func openPicture(_ id: String) {
        let pictures = CrmText.fileTokenIds(model.task.title).compactMap { fid -> (String, NSImage)? in
            guard let f = fileOf(fid), let image = f.image else { return nil }
            return (fid, image)
        }
        if let i = pictures.firstIndex(where: { $0.0 == id }) {
            lightboxIndex = i
            lightbox = pictures.map(\.1)
        } else {
            model.openFile(id)
        }
    }

    // MARK: The properties grid

    @ViewBuilder
    private func properties(_ t: CrmTask) -> some View {
        let timeEmpty = model.extras.map { $0.timeEntries.isEmpty && $0.estimateMinutes == nil } ?? false
        let tagsEmpty = model.extras.map { $0.labels.isEmpty } ?? false
        let unavailable = model.extrasErrorText
        let pair = GridItem(.flexible(), spacing: 0, alignment: .leading)
        let columns = gridWidth >= 640 ? [pair, pair] : [pair]
        VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                PropertyRow(icon: "circle.dashed", label: "Status") { StatusCell(model: model) }
                PropertyRow(icon: "person", label: "Assignees") { TaskPeopleField(model: model) }
            }
            PropertyRow(icon: "folder", label: "Project folder", wide: true) { ProjectCell(model: model) }
            if !model.row.project.isEmpty {
                PropertyRow(icon: "arrow.triangle.branch", label: "Workspace", wide: true) { WorkspaceField(model: model) }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                if !(model.hideEmpty && t.startDate.isEmpty && t.dueDate.isEmpty) {
                    PropertyRow(icon: "calendar", label: "Dates") {
                        if model.canEditRow {
                            TaskDatesField(model: model)
                        } else {
                            Text(summariseTimeline(t.startDate, t.dueDate) ?? "Empty").font(.system(size: 13)).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !(model.hideEmpty && t.priority == nil) {
                    PropertyRow(icon: "flag", label: "Priority") {
                        if model.canEditRow {
                            PriorityCell(value: t.priority) { model.changePriority($0) }
                        } else {
                            Text(t.priority ?? "Empty").font(.system(size: 13)).foregroundStyle(.tertiary)
                        }
                    }
                }
                if !(model.hideEmpty && timeEmpty) {
                    PropertyRow(icon: "timer", label: "Track time") {
                        if let unavailable {
                            UnavailableCell(reason: unavailable)
                        } else if let extras = model.extras {
                            TrackTimeCell(model: model, extras: extras)
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)).frame(width: 64, height: 20)
                        }
                    }
                }
                if !(model.hideEmpty && tagsEmpty) {
                    PropertyRow(icon: "tag", label: "Tags") {
                        if let unavailable {
                            UnavailableCell(reason: unavailable)
                        } else if let extras = model.extras {
                            TagsCell(model: model, labels: extras.labels)
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)).frame(width: 64, height: 20)
                        }
                    }
                }
            }
            if !model.hideEmpty {
                PropertyRow(icon: "link", label: "Related to", wide: true) {
                    UnavailableCell(reason: "Related records live in a CRM — local tasks cannot link to them.")
                }
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
    }

    // MARK: The sections and action rows

    @ViewBuilder
    private func sections(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.bundleState {
            case .loading:
                VStack(alignment: .leading, spacing: 8) {
                    ForEach([1.0, 0.8, 0.6], id: \.self) { share in
                        GeometryReader { g in RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)).frame(width: g.size.width * share) }
                            .frame(height: 36)
                    }
                }
                .accessibilityLabel("Loading the rest of this task")
            case .error(let message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text("Could not load the people, subtasks, checklists, dependencies and attachments: \(message)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.retryBundle() } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(.plain)
                }
                .font(.caption).foregroundStyle(TaskTone.input)
                .padding(10).background(RoundedRectangle(cornerRadius: 6).fill(TaskTone.input.opacity(0.1)))
            case .ready:
                if let people = model.people {
                    if model.shown.contains(.subtasks), let rows = model.subtasks {
                        SubtasksTable(model: model, rows: rows, people: people, justAdded: model.justAdded == .subtasks)
                    }
                    Group {
                        if model.shown.contains(.dependencies), let rows = model.dependencies {
                            DependenciesSection(model: model, rows: rows, justAdded: model.justAdded == .dependencies, initialKind: model.depKind)
                                .id(model.depKey)
                        }
                    }
                    .id("dependencies")
                    if model.shown.contains(.checklist), let lists = model.checklists {
                        ChecklistsBlock(model: model, lists: lists, people: people, justAdded: model.justAdded == .checklist)
                    }
                    if model.shown.contains(.attachments), let rows = model.attachments {
                        AttachmentsSection(model: model, rows: rows)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if !model.shown.contains(.subtasks) {
                            Button { model.reveal(.subtasks) } label: { actionLabel("Add subtask", "arrow.triangle.branch") }
                                .buttonStyle(ActionRowStyle())
                        }
                        Button { relateOpen.toggle() } label: { actionLabel("Relate items or add dependencies", "point.3.connected.trianglepath.dotted") }
                            .buttonStyle(ActionRowStyle())
                            .popover(isPresented: $relateOpen, arrowEdge: .bottom) {
                                VStack(alignment: .leading, spacing: 0) {
                                    relateRow("Relate a Task", "link", .linked, proxy)
                                    Divider().padding(.vertical, 4)
                                    relateRow("This task blocks…", "nosign", .blocks, proxy)
                                    relateRow("This task is blocked by…", "exclamationmark.triangle", .blockedBy, proxy)
                                }
                                .padding(.vertical, 4).frame(width: 260)
                            }
                        if !model.shown.contains(.checklist) {
                            Button { model.reveal(.checklist) } label: { actionLabel("Create checklist", "checklist") }
                                .buttonStyle(ActionRowStyle())
                        }
                        AttachFileRow(model: model)
                    }
                }
            }
        }
    }

    private func actionLabel(_ title: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tertiary).frame(width: 16)
            Text(title)
            Spacer()
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
    }

    private func relateRow(_ title: String, _ icon: String, _ kind: DependencyKind, _ proxy: ScrollViewProxy) -> some View {
        Button {
            relateOpen = false
            model.relate(kind)
            withAnimation { proxy.scrollTo("dependencies", anchor: .center) }
        } label: {
            Label(title, systemImage: icon).padding(.horizontal, 12).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: The rail

    private func rail(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 6) {
            railButton(model.activityOpen ? "chevron.right.2" : "chevron.left.2",
                       model.activityOpen ? "Collapse activity" : "Show activity",
                       help: model.activityOpen ? "Collapse" : "Show activity") { model.activityOpen.toggle() }
            railButton("bubble.left", "Activity", on: model.activityOpen) { model.activityOpen = true }
            railButton("point.3.connected.trianglepath.dotted", "Related items", help: "Related items") {
                model.reveal(.dependencies)
                withAnimation { proxy.scrollTo("dependencies", anchor: .center) }
            }
        }
        .padding(.top, 20)
        .padding(.trailing, 4)
        .frame(width: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task panels")
    }

    private func railButton(_ icon: String, _ label: String, on: Bool = false, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.secondary.opacity(0.2) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? Color.primary : Color.secondary)
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Slash commands

    private var commands: [SlashCommand] {
        let t = model.task
        let q = CrmTime.quickDates()
        var out: [SlashCommand] = []
        if let me = model.meperson {
            out.append(SlashCommand(key: "assign-me", group: "TASK ACTIONS", label: "Assign to me", icon: "person", run: { model.invite(me) }))
        }
        out.append(SlashCommand(key: "assign", group: "TASK ACTIONS", label: "Assign", icon: "person.badge.plus",
                                options: model.team.prefix(40).map { p in .init(key: p.id, label: p.name, person: p, run: { model.invite(p) }) }))
        if model.canEditRow {
            out.append(SlashCommand(key: "priority", group: "TASK ACTIONS", label: "Priority", icon: "flag",
                                    options: CrmText.priorities.reversed().map { p in .init(key: p, label: p, run: { model.changePriority(p) }) }
                                        + [.init(key: "clear", label: "Clear", run: { model.changePriority(nil) })]))
            out.append(SlashCommand(key: "due-today", group: "TASK ACTIONS", label: "Due Date to today", icon: "calendar.badge.clock",
                                    run: { model.saveDates(start: t.startDate, due: q.today) }))
            out.append(SlashCommand(key: "due", group: "TASK ACTIONS", label: "Due Date", icon: "calendar", options: [
                .init(key: "today", label: "Today", run: { model.saveDates(start: t.startDate, due: q.today) }),
                .init(key: "tomorrow", label: "Tomorrow", run: { model.saveDates(start: t.startDate, due: q.tomorrow) }),
                .init(key: "next-week", label: "Next week", run: { model.saveDates(start: t.startDate, due: q.nextMonday) }),
                .init(key: "2w", label: "2 weeks", run: { model.saveDates(start: t.startDate, due: q.twoWeeks) }),
                .init(key: "clear", label: "No due date", run: { model.saveDates(start: t.startDate, due: "") }),
            ]))
            out.append(SlashCommand(key: "start", group: "TASK ACTIONS", label: "Start Date", icon: "play.square", options: [
                .init(key: "today", label: "Today", run: { model.saveDates(start: q.today, due: t.dueDate) }),
                .init(key: "tomorrow", label: "Tomorrow", run: { model.saveDates(start: q.tomorrow, due: t.dueDate) }),
                .init(key: "next-week", label: "Next week", run: { model.saveDates(start: q.nextMonday, due: t.dueDate) }),
                .init(key: "clear", label: "No start date", run: { model.saveDates(start: "", due: t.dueDate) }),
            ]))
            out.append(SlashCommand(key: "status", group: "TASK ACTIONS", label: "Status", icon: "circle.dashed",
                                    options: CrmText.statuses.map { s in .init(key: s, label: CrmText.statusWord(s), run: { model.changeStatus(s) }) }))
            out.append(SlashCommand(key: "close", group: "TASK ACTIONS", label: "Close task", icon: "checkmark.circle", run: { model.changeStatus("Done") }))
            out.append(SlashCommand(key: "move", group: "TASK ACTIONS", label: "Move", icon: "folder",
                                    options: ([""] + boards).map { b in .init(key: b.isEmpty ? "none" : b, label: CrmText.boardLabel(b), run: { model.moveBoard(b) }) }))
        }
        out.append(SlashCommand(key: "subtask", group: "TASK ACTIONS", label: "Subtask", icon: "arrow.triangle.branch", run: { model.reveal(.subtasks) }))
        out.append(SlashCommand(key: "waiting", group: "TASK ACTIONS", label: "Waiting on", icon: "exclamationmark.triangle", run: { model.relate(.blockedBy) }))
        out.append(SlashCommand(key: "blocking", group: "TASK ACTIONS", label: "Blocking", icon: "nosign", run: { model.relate(.blocks) }))
        out.append(SlashCommand(key: "link", group: "TASK ACTIONS", label: "Link To", icon: "link", run: { model.relate(.linked) }))
        return out
    }
}

// MARK: - The description block

/// "Add description" → click → a box; leaving it saves when it changed; Escape puts it back.
private struct DetailsBlock: View {
    let model: TaskDetailModel
    @State private var editing = false
    @State private var value = ""
    @State private var saving = false
    @FocusState private var focused: Bool

    var body: some View {
        let saved = model.task.description
        let canEdit = model.canEditRow
        if !editing {
            if canEdit || !saved.isEmpty {
                Button {
                    if canEdit {
                        value = saved
                        editing = true
                    }
                } label: {
                    Group {
                        if saved.isEmpty {
                            Label("Add description", systemImage: "doc.text").foregroundStyle(.secondary)
                        } else {
                            Text(saved).multilineTextAlignment(.leading)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canEdit)
                .accessibilityLabel(saved.isEmpty ? "Add description" : "Edit details")
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: Binding(get: { value }, set: { value = String($0.prefix(5000)) }))
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: 80)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.purple.opacity(0.4)))
                    .overlay(alignment: .topLeading) {
                        if value.isEmpty { Text("Add details…").foregroundStyle(.tertiary).padding(10).allowsHitTesting(false) }
                    }
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, now in if !now { finish(saved) } }
                    .onExitCommand {
                        value = saved
                        editing = false
                    }
                    .accessibilityLabel("Description")
                if saving { Label("Saving…", systemImage: "text.alignleft").font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    private func finish(_ saved: String) {
        guard editing else { return }
        editing = false
        if value.trimmingCharacters(in: .whitespacesAndNewlines) != saved {
            saving = true
            let text = value
            Task {
                await model.saveDescription(text)
                saving = false
            }
        }
    }
}

// MARK: - The header

private struct TaskPageHeader: View {
    let model: TaskDetailModel
    let boards: [String]
    let siblings: [String]
    let taskOptions: [(id: String, title: String)]
    let onNavigate: (String) -> Void
    let onClose: () -> Void
    let onDelete: () -> Void
    let onGone: (String?) -> Void
    let onRelate: (DependencyKind) -> Void
    @State private var favorites = TaskFavoritesStore.shared
    @State private var moveOpen = false
    @State private var shareOpen = false
    @State private var moreOpen = false

    var body: some View {
        let at = siblings.firstIndex(of: model.taskId)
        let prev = at.flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
        let next = at.flatMap { $0 < siblings.count - 1 ? siblings[$0 + 1] : nil }
        let fav = favorites.contains(model.taskId)
        HStack(spacing: 2) {
            icon("chevron.up", "Previous task") { if let prev { onNavigate(prev) } }.disabled(prev == nil)
            icon("chevron.down", "Next task") { if let next { onNavigate(next) } }.disabled(next == nil)
            HStack(spacing: 6) {
                Image(systemName: "checklist").foregroundStyle(.secondary)
                Text(CrmText.boardLabel(model.task.board)).font(.callout.weight(.medium)).lineLimit(1)
                if model.personal {
                    Image(systemName: "lock").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Private — only you are on it")
                }
            }
            .padding(.leading, 6)
            if model.canEditRow {
                Divider().frame(height: 16).padding(.horizontal, 6)
                icon("folder.badge.plus", "Move task") { moveOpen.toggle() }
                    .popover(isPresented: $moveOpen, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Move to").font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6)
                            BoardList(board: model.task.board, boards: boards) { b in
                                moveOpen = false
                                if b != model.task.board { model.moveBoard(b) }
                            }
                        }
                        .frame(width: 220)
                    }
            }
            Spacer()
            if let created = model.task.createdAt {
                Text("Created \(CrmTime.monthDay(created))").font(.caption).foregroundStyle(.secondary).help(localStamp(created))
                    .padding(.trailing, 8)
            }
            Button { shareOpen.toggle() } label: { Label("Share", systemImage: "person.2") }
                .buttonStyle(.borderless)
                .padding(.trailing, 4)
                .popover(isPresented: $shareOpen, arrowEdge: .bottom) { SharePanel(model: model) { shareOpen = false } }
            icon("ellipsis", "More") { moreOpen.toggle() }
                .popover(isPresented: $moreOpen, arrowEdge: .bottom) {
                    MoreMenu(model: model, boards: boards, taskOptions: taskOptions, onClose: { moreOpen = false },
                             onDelete: onDelete, onGone: onGone, onRelate: onRelate,
                             onDuplicated: onNavigate, onShare: { shareOpen = true })
                }
            Button { favorites.toggle(model.taskId) } label: {
                Image(systemName: fav ? "star.fill" : "star").foregroundStyle(fav ? Color.yellow : Color.secondary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(fav ? "Remove from favorites" : "Favorite")
            .accessibilityLabel(fav ? "Remove from favorites" : "Favorite")
            icon(model.full ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                 model.full ? "Exit full screen" : "Full screen") { model.full.toggle() }
            icon("xmark", "Close", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The boards to move to: "No board", the ones in use, and a new name.
private struct BoardList: View {
    let board: String
    let boards: [String]
    let onPick: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach([""] + boards.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, id: \.self) { b in
                Button { onPick(b) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checklist").foregroundStyle(.tertiary)
                        Text(CrmText.boardLabel(b))
                        Spacer()
                        if b == board { Image(systemName: "checkmark").font(.caption).foregroundStyle(Color.purple) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(b == board ? .isSelected : [])
            }
            TextField("New board…", text: Binding(get: { name }, set: { name = String($0.prefix(40)) }))
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty { onPick(String(n.prefix(40))) }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .accessibilityLabel("New board")
        }
        .padding(.vertical, 4)
    }
}

/// "Share this task": invite by name, why there is no link, who it is shared with.
private struct SharePanel: View {
    let model: TaskDetailModel
    let onClose: () -> Void

    var body: some View {
        let everyone = model.people?.list
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Share this task").font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Close share")
            }
            HStack(spacing: 4) {
                Text("Sharing task").foregroundStyle(.secondary)
                Text(CrmText.plainHeading(model.task.title)).underline().lineLimit(1)
            }
            .font(.callout)
            PersonSearchList(team: model.team, isPicked: { model.people?.has($0) ?? false }, onPick: { model.invite($0) })
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                Text("No link to share: this task lives on this computer. It can be shared only with your agents here — never with anyone outside it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Share with").font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.top, 6)
            if let everyone {
                if everyone.isEmpty {
                    Text("Only you.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(everyone.enumerated()), id: \.element.id) { i, p in
                        HStack(spacing: 8) {
                            PersonAvatar(person: p)
                            Text(p.name).lineLimit(1)
                            Spacer()
                            if i == 0 { Text("MAIN").font(.system(size: 10)).foregroundStyle(.tertiary) }
                            Button { model.removeFromTask(p.id) } label: { Image(systemName: "xmark").font(.caption2) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Remove \(p.name)")
                        }
                        .font(.callout)
                    }
                }
            } else {
                Text("Loading…").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

// MARK: - ⋯ (more-menu.tsx)

private struct MoreMenu: View {
    let model: TaskDetailModel
    let boards: [String]
    let taskOptions: [(id: String, title: String)]
    let onClose: () -> Void
    let onDelete: () -> Void
    let onGone: (String?) -> Void
    let onRelate: (DependencyKind) -> Void
    let onDuplicated: (String) -> Void
    let onShare: () -> Void
    @State private var favorites = TaskFavoritesStore.shared
    @State private var sub: String?
    @State private var copied: String?
    @State private var arming: String?
    @State private var pick: (id: String, title: String)?
    @State private var query = ""
    @State private var custom = Date()
    /// The keyboard (more-menu.tsx): the first item takes focus on open; ↑ ↓ Home End walk the items, round.
    @FocusState private var focused: String?
    @State private var order: [String] = []

    var body: some View {
        let more = model.more
        let partTwo = more != nil
        let fav = favorites.contains(model.taskId)
        let rule = Routine.normalize(model.routine?.rule)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Button(copied == "link" ? "Copied" : "Copy link") {}
                        .disabled(true)
                        .help("A task on this computer has no link — nothing else can open it. Copy its ID instead.")
                        .frame(maxWidth: .infinity, minHeight: 28)
                    Divider()
                    Button(copied == "id" ? "Copied" : "Copy ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.taskId, forType: .string)
                        copied = "id"
                        Task {
                            try? await Task.sleep(for: .milliseconds(1500))
                            copied = nil
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.plain).font(.caption)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .padding(8)
                item(fav ? "Remove from Favorites" : "Favorite", fav ? "star.fill" : "star") { favorites.toggle(model.taskId) }
                if more?.remindersLive == true {
                    item("Remind me", "clock", chevron: true, count: more.map { $0.reminders.isEmpty ? nil : $0.reminders.count } ?? nil) { toggle("remind") }
                    if sub == "remind", let more { remind(more) }
                }
                Divider().padding(.vertical, 4)
                if model.canEditRow {
                    item("Move to", "folder", chevron: true) { toggle("move") }
                    if sub == "move" {
                        BoardList(board: model.task.board, boards: boards) { b in
                            onClose()
                            if b != model.task.board { model.moveBoard(b) }
                        }
                        .background(Color.secondary.opacity(0.05))
                    }
                }
                if model.canEditRow && partTwo {
                    item("Merge", "arrow.triangle.merge", chevron: true) { toggle("merge") }
                    if sub == "merge" { picker("Merge into") { model.merge(into: $0, onGone: onGone) } }
                }
                item("Duplicate", "plus.square.on.square") {
                    onClose()
                    model.duplicate(onDuplicated: onDuplicated)
                }
                if model.canEditRow && partTwo {
                    item("Convert to subtask", "arrow.left.arrow.right", chevron: true) { toggle("convert") }
                    if sub == "convert" { picker("Make a subtask of") { model.convert(toSubtaskOf: $0, onGone: onGone) } }
                }
                Divider().padding(.vertical, 4)
                if model.canEditRow {
                    item("Relationships", "point.3.connected.trianglepath.dotted", chevron: true) { toggle("relate") }
                    if sub == "relate" {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach([(DependencyKind.linked, "Relate a task"), (.blocks, "This task blocks…"), (.blockedBy, "This task is blocked by…")], id: \.1) { kind, label in
                                Button {
                                    onClose()
                                    onRelate(kind)
                                } label: {
                                    Text(label).padding(.horizontal, 16).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(Color.secondary.opacity(0.05))
                    }
                }
                item("Description history", "clock.arrow.circlepath") {
                    onClose()
                    model.openDescriptionHistory()
                }
                if model.canEditRow, let type = model.extras?.taskType {
                    item("Task Type", "diamond", chevron: true) { toggle("type") }
                    if sub == "type" {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach([("task", "Task (default)"), ("milestone", "Milestone")], id: \.0) { id, label in
                                Button {
                                    onClose()
                                    model.setTypeFromMenu(id)
                                } label: {
                                    HStack { Text(label); Spacer(); if type == id { Image(systemName: "checkmark").foregroundStyle(Color.purple) } }
                                        .padding(.horizontal, 16).padding(.vertical, 4).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(Color.secondary.opacity(0.05))
                    }
                }
                if model.canEditRow && partTwo {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary).frame(width: 16)
                        Text("Sync dates with subtasks")
                        Spacer()
                        Toggle("Sync dates with subtasks", isOn: Binding(get: { more?.syncSubtaskDates ?? false }, set: { model.syncDates($0) }))
                            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                if let rule, rule.stoppedAt == nil, model.routine?.canEdit == true {
                    if arming != "stop" {
                        item("Stop recurring", "repeat") { arming = "stop" }
                    } else {
                        HStack {
                            Button("Stop recurring?") {
                                onClose()
                                model.stopRoutine()
                            }
                            .buttonStyle(.borderedProminent).tint(TaskTone.input)
                            Button("Cancel") { arming = nil }
                        }
                        .controlSize(.small).padding(.horizontal, 8).padding(.vertical, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Confirm stop recurring")
                    }
                }
                Divider().padding(.vertical, 4)
                item("Print", "printer") {
                    onClose()
                    if let view = NSApp.keyWindow?.contentView { NSPrintOperation(view: view).run() }
                }
                Divider().padding(.vertical, 4)
                if model.canEditRow && partTwo {
                    item(more?.archivedAt != nil ? "Restore from archive" : "Archive", more?.archivedAt != nil ? "archivebox.fill" : "archivebox") {
                        let archived = more?.archivedAt == nil
                        onClose()
                        model.setArchived(archived)
                    }
                }
                if model.canEditRow {
                    if arming != "delete" {
                        Button { arming = "delete" } label: {
                            Label("Delete task", systemImage: "trash").foregroundStyle(TaskTone.input)
                                .padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack {
                            Button {
                                onClose()
                                onDelete()
                            } label: { Label("Delete?", systemImage: "trash") }
                                .buttonStyle(.borderedProminent).tint(TaskTone.input)
                            Button("Cancel") { arming = nil }
                        }
                        .controlSize(.small).padding(.horizontal, 8).padding(.vertical, 6)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Confirm delete")
                    }
                }
                if !partTwo, let note = model.moreErrorText {
                    Text(note).font(.caption2).foregroundStyle(TaskTone.waiting).padding(.horizontal, 12).padding(.vertical, 4)
                }
                Button {
                    onClose()
                    onShare()
                } label: {
                    Text("Sharing & Permissions").font(.callout.weight(.medium)).frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent).tint(.purple)
                .padding(8)
            }
        }
        .frame(width: 256)
        .frame(maxHeight: 720)
        .onKeyPress(keys: [.downArrow, .upArrow, .home, .end]) { press in
            guard !order.isEmpty else { return .ignored }
            let at = focused.flatMap { order.firstIndex(of: $0) } ?? -1
            let n = order.count
            switch press.key {
            case .downArrow: focused = order[(at + 1 + n) % n]
            case .upArrow: focused = order[(at < 0 ? n - 1 : at - 1 + n) % n]
            case .home: focused = order[0]
            default: focused = order[n - 1]
            }
            return .handled
        }
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            if focused == nil { focused = order.first }
        }
    }

    private func toggle(_ s: String) {
        sub = sub == s ? nil : s
        pick = nil
        query = ""
    }

    private func item(_ title: String, _ icon: String, chevron: Bool = false, count: Int? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(icon == "star.fill" ? Color.yellow : Color.secondary).frame(width: 16)
                Text(title)
                Spacer()
                if let count { Text("\(count)").font(.caption).foregroundStyle(Color.purple) }
                if chevron { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
            .background(focused == title ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused, equals: title)
        .onKeyPress(.return) { action(); return .handled }
        .onKeyPress(.space) { action(); return .handled }
        .onAppear { if !order.contains(title) { order.append(title) } }
        .onDisappear { order.removeAll { $0 == title } }
    }

    /// Pick another task in the list, then confirm.
    @ViewBuilder
    private func picker(_ verb: String, _ run: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pick {
                Text("\(verb) “\(pick.title)”? \(verb == "Merge into" ? "This task's comments, subtasks, checklists and time move there; this one goes to Trash." : "This task goes to Trash; its first line becomes the subtask.")")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(verb == "Merge into" ? "Merge" : "Convert") {
                        let id = pick.id
                        onClose()
                        run(id)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { self.pick = nil }
                }
                .controlSize(.small)
            } else {
                TextField("Search tasks…", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search tasks")
                let words = query.trimmingCharacters(in: .whitespaces).lowercased()
                let choices = Array(taskOptions.filter { words.isEmpty || $0.title.lowercased().contains(words) }.prefix(8))
                if choices.isEmpty {
                    Text("No other task in this list.").font(.caption).foregroundStyle(.tertiary)
                }
                ForEach(choices, id: \.id) { t in
                    Button { pick = t } label: {
                        Text(t.title.isEmpty ? "Untitled" : t.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.05))
    }

    /// In 1 hour, later today, tomorrow, next week — or a time of your own; then the reminders set.
    @ViewBuilder
    private func remind(_ more: TaskMore) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(reminderPresets(), id: \.key) { r in
                Button {
                    onClose()
                    model.remind(r.at)
                } label: {
                    HStack { Text(r.label); Spacer(); Text(hint(r.at)).font(.caption).foregroundStyle(.tertiary) }
                        .padding(.horizontal, 16).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 4) {
                DatePicker("Remind me at", selection: $custom, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                Button("Set") {
                    onClose()
                    model.remind(custom)
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
            ForEach(more.reminders) { r in
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.caption2).foregroundStyle(Color.purple)
                    Text(localStamp(r.remindAt)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.clearReminder(r.id) } label: { Image(systemName: "xmark").font(.caption2) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Cancel reminder")
                }
                .padding(.horizontal, 16).padding(.vertical, 2)
            }
        }
        .background(Color.secondary.opacity(0.05))
    }

    private func reminderPresets(now: Date = Date()) -> [(key: String, label: String, at: Date)] {
        let cal = Calendar.current
        let today = CrmTime.todayYmd(now)
        func at(_ ymd: String, _ h: Int) -> Date {
            let p = ymd.split(separator: "-").compactMap { Int($0) }
            return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: h)) ?? now
        }
        var out: [(String, String, Date)] = [("1h", "In 1 hour", now.addingTimeInterval(3600))]
        let evening = at(today, 18)
        if evening.timeIntervalSince(now) > 3600 { out.append(("later", "Later today", evening)) }
        out.append(("tomorrow", "Tomorrow", at(TaskList.ymdAddDays(today, 1), 9)))
        let toMonday = (8 - TaskList.ymdWeekday(today)) % 7
        out.append(("next-week", "Next week", at(TaskList.ymdAddDays(today, toMonday == 0 ? 7 : toMonday), 9)))
        return out.map { (key: $0.0, label: $0.1, at: $0.2) }
    }

    private func hint(_ date: Date) -> String {
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return "\(days[TaskList.ymdWeekday(CrmTime.todayYmd(date))]), \(CrmTime.clock(date))"
    }
}
