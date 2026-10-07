import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// The task's "Fields" section (crm-task/task-fields-section.tsx): ClickUp's
// "+ Create new field" on one task — each field a row (icon · name · value), a
// searchable, filterable type picker, a short create form, and a ⋯ menu per row
// (Rename, Edit options, Move up/down, Delete). A value shows the moment it is
// chosen; a refusal puts the old value back and says why under the row.

// MARK: - The store

@MainActor
@Observable
final class FieldsStore {
    let taskId: String
    @ObservationIgnored private weak var model: TaskDetailModel?
    private(set) var ready = false
    private(set) var loadError: String?
    var fields: [TaskField] = []
    var people: [String: CrmPerson] = [:]
    private(set) var auto: AutoProgress?
    private(set) var viewerId: String?
    var errors: [String: String] = [:]
    var busy: Set<String> = []
    var sectionErr: String?

    init(model: TaskDetailModel) {
        taskId = model.taskId
        self.model = model
    }

    private func call(_ fn: String, _ args: [Any?]) async -> Result<[String: Any], TasksProblem> {
        guard let model else { return .failure(TasksProblem("This task is closed.")) }
        return await model.call(fn, args)
    }

    func load() async {
        switch await call("listTaskFields", [taskId]) {
        case .failure(let problem):
            loadError = problem.message
            fields = []
        case .success(let r):
            fields = TaskFields.sorted((r["fields"] as? [Any] ?? []).compactMap(TaskFields.decode))
            var faces: [String: CrmPerson] = [:]
            for (id, raw) in r["people"] as? [String: Any] ?? [:] {
                if let p = CrmDecode.person(raw) { faces[id] = p }
            }
            people = faces
            auto = TaskFields.decodeAuto(r["auto"])
            viewerId = r["viewerId"] as? String
        }
        ready = true
    }

    func field(_ id: String) -> TaskField? { fields.first { $0.id == id } }

    private func replace(_ f: TaskField) {
        fields = fields.map { $0.id == f.id ? f : $0 }
    }

    private func setValue(_ id: String, _ value: CrmValue) {
        fields = fields.map { f in
            guard f.id == id else { return f }
            var next = f
            next.value = value
            return next
        }
    }

    func remember(_ p: CrmPerson) {
        if people[p.id] == nil { people[p.id] = p }
    }

    /// A value: checked here first (the same rule the engine runs), shown at once,
    /// put back with the reason if the engine refuses it. People, Tasks and Files name
    /// this computer's own ids, which only the engine can carry across the rule's id
    /// check, so those go straight to it.
    func commitValue(_ field: TaskField, _ raw: CrmValue) async {
        var shown = raw
        if ![.people, .tasks, .files].contains(field.kind) {
            let ctx = ValueCtx(userId: viewerId ?? "", now: CrmTime.iso(Date().timeIntervalSince1970 * 1000))
            switch TaskFields.normaliseValue(field.kind, field.config, raw, ctx: ctx) {
            case .failure(let f):
                errors[field.id] = f.error
                return
            case .success(let v):
                shown = v
            }
        }
        let prev = self.field(field.id)?.value ?? field.value
        errors[field.id] = nil
        setValue(field.id, shown)
        switch await call("updateTaskFieldValue", [field.id, raw.any]) {
        case .failure(let problem):
            setValue(field.id, prev)
            errors[field.id] = problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { replace(f) }
        }
    }

    func vote(_ field: TaskField) async {
        busy.insert(field.id)
        errors[field.id] = nil
        let result = await call("toggleTaskFieldVote", [field.id])
        busy.remove(field.id)
        switch result {
        case .failure(let problem): errors[field.id] = problem.message
        case .success(let r): if let f = TaskFields.decode(r["field"]) { replace(f) }
        }
    }

    func press(_ field: TaskField) async {
        busy.insert(field.id)
        errors[field.id] = nil
        let result = await call("pressTaskFieldButton", [field.id])
        busy.remove(field.id)
        switch result {
        case .failure(let problem):
            errors[field.id] = problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { replace(f) }
            if let t = TaskFields.decode(r["target"]) { replace(t) }
            model?.refetchAll()
        }
    }

    /// Files from the Mac's chooser: each one onto the task, then into the field.
    func upload(_ field: TaskField, _ urls: [URL]) async {
        busy.insert(field.id)
        errors[field.id] = nil
        var added: [CrmValue] = []
        var refused: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            let data = (try? Data(contentsOf: url)) ?? Data()
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            switch await call("uploadTaskFile", [taskId, ["name": name, "type": type, "bytes": data] as [String: Any]]) {
            case .failure(let problem):
                refused.append(problem.message)
            case .success(let r):
                if let a = CrmDecode.attachment(r["attachment"]) {
                    added.append(.object(["id": .string(a.id), "name": .string(a.fileName), "mime": a.mimeType.map { .string($0) } ?? .null]))
                }
            }
        }
        busy.remove(field.id)
        if !added.isEmpty, let current = self.field(field.id) {
            await commitValue(current, .array((current.value.array ?? []) + added))
            model?.refetchAll()
        }
        if !refused.isEmpty { errors[field.id] = refused.joined(separator: " · ") }
    }

    /// Resolves to the refusal in words, or nil when renamed.
    func rename(_ field: TaskField, _ label: String) async -> String? {
        let prev = field.label
        var next = field
        next.label = label
        replace(next)
        errors[field.id] = nil
        switch await call("renameTaskField", [field.id, label]) {
        case .failure(let problem):
            if var back = self.field(field.id) {
                back.label = prev
                replace(back)
            }
            errors[field.id] = problem.message
            return problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { replace(f) }
            for raw in r["formulas"] as? [Any] ?? [] {
                if let f = TaskFields.decode(raw) { replace(f) }
            }
            return nil
        }
    }

    func saveConfig(_ field: TaskField, _ config: FieldConfig) async -> String? {
        switch await call("updateTaskFieldConfig", [field.id, config.crm(field.kind).any]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { replace(f) }
            return nil
        }
    }

    func move(_ field: TaskField, _ dir: Int) async {
        let before = fields
        guard let i = before.firstIndex(where: { $0.id == field.id }) else { return }
        let j = i + dir
        guard j >= 0, j < before.count else { return }
        var next = before
        next.swapAt(i, j)
        fields = next
        sectionErr = nil
        if case .failure(let problem) = await call("reorderTaskFields", [taskId, next.map(\.id)]) {
            fields = before
            sectionErr = problem.message
        }
    }

    func delete(_ field: TaskField) async {
        let before = fields
        fields.removeAll { $0.id == field.id }
        sectionErr = nil
        if case .failure(let problem) = await call("deleteTaskField", [field.id]) {
            fields = before
            sectionErr = "“\(field.label)” was not deleted: \(problem.message)"
        }
    }

    func create(label: String, kind: FieldKind, config: FieldConfig) async -> String? {
        let input: [String: Any] = ["label": label, "kind": kind.rawValue, "config": config.crm(kind).any]
        switch await call("createTaskField", [taskId, input]) {
        case .failure(let problem): return problem.message
        case .success(let r):
            if let f = TaskFields.decode(r["field"]) { fields.append(f) }
            return nil
        }
    }
}

// MARK: - The editing context

/// What every value editor needs: the task, its fields (formulas read them), the
/// faces, and what a vote, a press, an upload or a link does.
struct FieldCtx {
    var taskId: String?
    var fields: [TaskField] = []
    var people: [String: CrmPerson] = [:]
    var team: [CrmPerson] = []
    var auto: AutoProgress?
    var viewerId: String?
    var readOnly = false
    var busy: Set<String> = []
    var model: TaskDetailModel?
    var rememberPerson: (CrmPerson) -> Void = { _ in }
    var onVote: (TaskField) -> Void = { _ in }
    var onPress: (TaskField) -> Void = { _ in }
    var onFiles: (TaskField, [URL]) -> Void = { _, _ in }
    /// An address inside the app ("/tasks?task=…", "/files/…").
    var onOpen: (String) -> Void = { _ in }

    /// A throwaway context for the Button's "set a field to…" value.
    static func detached(team: [CrmPerson]) -> FieldCtx { FieldCtx(taskId: nil, team: team) }

    func face(_ id: String) -> CrmPerson? { people[id] ?? team.first { $0.id == id } }
}

// MARK: - The section

struct TaskFieldsSection: View {
    let model: TaskDetailModel
    var onNavigate: (String) -> Void = { _ in }
    @State private var store: FieldsStore?

    var body: some View {
        Group {
            if let store, store.taskId == model.taskId, store.ready {
                FieldsBody(model: model, store: store, onNavigate: onNavigate)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fields").font(.system(size: 13)).foregroundStyle(.secondary)
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)).frame(width: 192, height: 28)
                        .accessibilityLabel("Loading fields")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: model.taskId) {
            let next = FieldsStore(model: model)
            store = next
            await next.load()
        }
    }
}

private struct FieldsBody: View {
    let model: TaskDetailModel
    let store: FieldsStore
    let onNavigate: (String) -> Void
    @State private var creating = false

    var body: some View {
        let canEdit = model.canEditRow
        if canEdit || store.loadError != nil || !store.fields.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fields").font(.system(size: 13)).foregroundStyle(.secondary)
                if let error = store.loadError {
                    Text("Fields unavailable: \(error)").font(.caption).foregroundStyle(.tertiary)
                } else {
                    let ctx = context(readOnly: !canEdit)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.fields.enumerated()), id: \.element.id) { i, f in
                            FieldRow(field: f, ctx: ctx, first: i == 0, last: i == store.fields.count - 1, error: store.errors[f.id], store: store)
                        }
                    }
                    if let e = store.sectionErr {
                        Text(e).font(.caption).foregroundStyle(TaskTone.input).accessibilityAddTraits(.isStaticText)
                    }
                    if canEdit {
                        Button { creating.toggle() } label: {
                            Label("Create new field", systemImage: "plus")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10).frame(height: 28)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .popover(isPresented: $creating, arrowEdge: .bottom) {
                            CreateFieldPanel(siblings: store.fields, team: model.team, onCancel: { creating = false }) { label, kind, config in
                                let err = await store.create(label: label, kind: kind, config: config)
                                if err == nil { creating = false }
                                return err
                            }
                            .frame(width: 320)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func context(readOnly: Bool) -> FieldCtx {
        var ctx = FieldCtx(taskId: store.taskId, fields: store.fields, people: store.people, team: model.team, auto: store.auto,
                           viewerId: store.viewerId, readOnly: readOnly, busy: store.busy, model: model)
        let store = store
        let model = model
        let onNavigate = onNavigate
        ctx.rememberPerson = { store.remember($0) }
        ctx.onVote = { f in Task { await store.vote(f) } }
        ctx.onPress = { f in Task { await store.press(f) } }
        ctx.onFiles = { f, urls in Task { await store.upload(f, urls) } }
        ctx.onOpen = { href in
            if href.hasPrefix("/tasks?task="), let id = String(href.dropFirst("/tasks?task=".count)).removingPercentEncoding {
                onNavigate(id)
            } else if href.hasPrefix("/files/") {
                let parts = href.dropFirst("/files/".count).split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
                if parts.count == 2 { Task { _ = await model.call("openTaskFile", [parts[0], parts[1]]) } }
            }
        }
        return ctx
    }
}

// MARK: - Look

enum FieldPaint {
    static func hex(_ s: String?) -> Color {
        guard let s, s.count == 7, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else { return .accentColor }
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    static func hue(_ name: String) -> Color {
        switch name {
        case "emerald": hex("#10B981")
        case "sky": hex("#0EA5E9")
        case "amber": hex("#F59E0B")
        case "teal": hex("#14B8A6")
        case "violet": hex("#8B5CF6")
        case "fuchsia": hex("#D946EF")
        case "blue": hex("#3B82F6")
        case "indigo": hex("#6366F1")
        case "orange": hex("#F97316")
        case "rose": hex("#F43F5E")
        default: .secondary
        }
    }

    static func icon(_ kind: FieldKind) -> String {
        switch kind {
        case .dropdown: "chevron.down.circle"
        case .text: "textformat"
        case .date: "calendar"
        case .longText: "text.alignleft"
        case .number: "number"
        case .labels: "tag"
        case .checkbox: "checkmark.square"
        case .money: "banknote"
        case .website: "globe"
        case .formula: "sum"
        case .files: "paperclip"
        case .relationship: "point.3.connected.trianglepath.dotted"
        case .people: "person.2"
        case .progressAuto: "gauge.with.dots.needle.33percent"
        case .email: "envelope"
        case .phone: "phone"
        case .tasks: "checklist"
        case .location: "mappin.and.ellipse"
        case .progressManual: "slider.horizontal.3"
        case .rating: "star"
        case .voting: "hand.thumbsup"
        case .signature: "signature"
        case .button: "cursorarrow.click"
        }
    }
}

/// The coloured icon tile each type wears — in the picker and on every row.
struct FieldTypeIcon: View {
    let kind: FieldKind
    var size: CGFloat = 20

    var body: some View {
        let hue = FieldPaint.hue(TaskFields.info(kind).hue)
        Image(systemName: FieldPaint.icon(kind))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(hue)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 5).fill(hue.opacity(0.15)))
            .accessibilityHidden(true)
    }
}

/// An option's chip, tinted with its own colour.
private struct OptionChip: View {
    let option: FieldOption
    var onRemove: (() -> Void)?

    var body: some View {
        let c = FieldPaint.hex(option.color)
        HStack(spacing: 4) {
            Text(option.label).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove \(option.label)")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(c)
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.18)))
    }
}

/// A link-ish chip: a file, a record, a task.
private struct RefChip<Icon: View>: View {
    let label: String
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 4) {
            icon
            if let onOpen {
                Button(action: onOpen) { Text(label).lineLimit(1) }.buttonStyle(.plain)
            } else {
                Text(label).lineLimit(1)
            }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .accessibilityLabel("Remove \(label)")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8).frame(height: 24)
        .frame(maxWidth: 220, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
    }
}

/// A menu row inside a popover.
private struct FieldMenuRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .font(.system(size: 13))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.secondary.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct AddButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "plus").font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
            .help(label).accessibilityLabel(label)
    }
}

private struct EmptyPill: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Text(text).font(.system(size: 13)).padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(.tertiary)
    }
}

private struct LinkOut: View {
    let url: URL?
    let label: String

    var body: some View {
        Button { if let url { NSWorkspace.shared.open(url) } } label: {
            Image(systemName: "arrow.up.right.square").font(.system(size: 12)).frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
        .help(label).accessibilityLabel(label)
    }
}

private struct FieldChipToggle: View {
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.caption)
                .padding(.horizontal, 10).frame(height: 28)
                .background(Capsule().fill(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                .overlay(Capsule().stroke(on ? Color.accentColor.opacity(0.5) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Small editors

/// A text cell that saves on leaving it (and on Return for one line). Escape puts
/// the saved value back. While not being typed in it shows the SAVED value.
private struct FieldTextCell: View {
    let value: String
    var display: String?
    let onCommit: (String) -> Void
    let readOnly: Bool
    var multiline = false
    var placeholder = "Empty"
    let label: String
    var prefix: String?
    @State private var draft = ""
    @State private var cancel = false
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            if let prefix { Text(prefix).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 8) }
            Group {
                if multiline {
                    ZStack(alignment: .topLeading) {
                        if (focused ? draft : value).isEmpty {
                            Text(readOnly ? "—" : "Write something…").foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 1)
                        }
                        TextEditor(text: Binding(get: { focused ? draft : value }, set: { draft = $0 }))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 22, maxHeight: 160)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    TextField(readOnly ? "—" : placeholder, text: Binding(get: { focused ? draft : (display ?? value) }, set: { draft = $0 }))
                        .textFieldStyle(.plain)
                        .onSubmit { focused = false }
                }
            }
            .font(.system(size: 13))
            .focused($focused)
            .disabled(readOnly)
            .onExitCommand {
                cancel = true
                focused = false
            }
            .onChange(of: focused) { _, now in
                if now {
                    draft = value
                } else if cancel {
                    cancel = false
                } else if !readOnly && draft != value {
                    onCommit(draft)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(focused ? Color(nsColor: .textBackgroundColor) : hover && !readOnly ? Color.secondary.opacity(0.1) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Color.accentColor : .clear))
            .onHover { hover = $0 }
            .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ProgressBarField: View {
    let percent: Int
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(TaskTone.completed).frame(width: proxy.size.width * CGFloat(percent) / 100)
                }
            }
            .frame(minWidth: 60, maxWidth: .infinity).frame(height: 6)
            Text("\(percent)%").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(percent)%")
    }
}

// MARK: - Choice editors

private struct DropdownEditor: View {
    let field: TaskField
    let readOnly: Bool
    let onCommit: (CrmValue) -> Void
    @State private var open = false
    @State private var query = ""

    var body: some View {
        let options = field.config.options ?? []
        let current = options.first { $0.id == field.value.string }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = needle.isEmpty ? options : options.filter { $0.label.lowercased().contains(needle) }
        Button { open.toggle() } label: {
            Group {
                if let current { OptionChip(option: current) } else {
                    Text(readOnly ? "—" : "Select option").font(.system(size: 13)).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(readOnly)
        .accessibilityLabel("\(field.label): \(current?.label ?? "Empty")")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if options.count > 7 {
                    SearchField(placeholder: "Search…", text: $query, busy: false).accessibilityLabel("Search options")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if options.isEmpty {
                            Text("No options yet — use ⋯ › Edit options to add some.").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                        }
                        ForEach(shown) { o in
                            FieldMenuRow(action: {
                                open = false
                                onCommit(o.id == field.value.string ? .null : .string(o.id))
                            }) {
                                OptionChip(option: o)
                                Spacer()
                                if o.id == field.value.string { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                        if current != nil {
                            FieldMenuRow(action: {
                                open = false
                                onCommit(.null)
                            }) {
                                Label("Clear", systemImage: "xmark").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 240)
            }
            .frame(width: 240)
            .onDisappear { query = "" }
        }
    }
}

private struct LabelsEditor: View {
    let field: TaskField
    let readOnly: Bool
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let options = field.config.options ?? []
        let picked = (field.value.array ?? []).compactMap(\.string)
        FieldFlow {
            ForEach(picked, id: \.self) { id in
                if let o = options.first(where: { $0.id == id }) {
                    OptionChip(option: o, onRemove: readOnly ? nil : { toggle(id, picked) })
                }
            }
            if picked.isEmpty && readOnly { Text("—").font(.system(size: 13)).foregroundStyle(.tertiary) }
            if !readOnly {
                Group {
                    if picked.isEmpty { EmptyPill(text: "Select labels") { open.toggle() } } else { AddButton(label: "Add \(field.label)") { open.toggle() } }
                }
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if options.isEmpty {
                                Text("No labels yet — use ⋯ › Edit options to add some.").font(.caption).foregroundStyle(.secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                            }
                            ForEach(options) { o in
                                let on = picked.contains(o.id)
                                FieldMenuRow(action: { toggle(o.id, picked) }) {
                                    Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? Color.accentColor : .secondary)
                                    OptionChip(option: o)
                                }
                                .accessibilityAddTraits(on ? .isSelected : [])
                            }
                        }
                        .padding(4)
                    }
                    .frame(width: 240)
                    .frame(maxHeight: 240)
                }
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
    }

    private func toggle(_ id: String, _ picked: [String]) {
        let next = picked.contains(id) ? picked.filter { $0 != id } : picked + [id]
        onCommit(next.isEmpty ? .null : .array(next.map { .string($0) }))
    }
}

private struct RatingEditor: View {
    let field: TaskField
    let readOnly: Bool
    let onCommit: (CrmValue) -> Void
    @State private var hover = 0

    var body: some View {
        let max = field.config.max ?? 5
        let icon = field.config.icon ?? .star
        let value = Int(field.value.number ?? 0)
        let lit = hover > 0 ? hover : value
        let emoji = icon == .fire || icon == .thumb || icon == .smile
        HStack(spacing: 2) {
            ForEach(1...Swift.max(1, max), id: \.self) { n in
                Button { onCommit(n == value ? .null : .number(Double(n))) } label: {
                    Text(icon.glyph)
                        .font(.system(size: 15))
                        .foregroundStyle(n <= lit ? Color.orange : Color.secondary.opacity(0.35))
                        .saturation(emoji && n > lit ? 0 : 1)
                        .opacity(emoji && n > lit ? 0.35 : 1)
                        .scaleEffect(n == hover ? 1.1 : 1)
                }
                .buttonStyle(.plain)
                .disabled(readOnly)
                .onHover { inside in
                    if readOnly { return }
                    if inside { hover = n } else if hover == n { hover = 0 }
                }
                .accessibilityLabel("\(n) of \(max)")
                .accessibilityAddTraits(value == n ? .isSelected : [])
            }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(field.label)
    }
}

private struct PeopleEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let ids = (field.value.array ?? []).compactMap(\.string)
        FieldFlow {
            ForEach(ids, id: \.self) { id in
                let p = ctx.face(id)
                HStack(spacing: 4) {
                    if let p { PersonAvatar(person: p, size: 18) }
                    Text(p?.name ?? "Someone").lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                    if !ctx.readOnly {
                        Button { commit(ids.filter { $0 != id }) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                            .accessibilityLabel("Remove \(p?.name ?? "person")")
                    }
                }
                .font(.caption)
                .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                .help(p?.name ?? "Someone")
            }
            if ids.isEmpty && ctx.readOnly { Text("—").font(.system(size: 13)).foregroundStyle(.tertiary) }
            if !ctx.readOnly {
                Group {
                    if ids.isEmpty { EmptyPill(text: "Add people") { open.toggle() } } else { AddButton(label: "Add to \(field.label)") { open.toggle() } }
                }
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    PersonSearchList(team: ctx.team, isPicked: { ids.contains($0) }, onPick: { p in
                        ctx.rememberPerson(p)
                        commit(ids.contains(p.id) ? ids.filter { $0 != p.id } : ids + [p.id])
                    })
                    .frame(width: 260)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    private func commit(_ next: [String]) { onCommit(next.isEmpty ? .null : .array(next.map { .string($0) })) }
}

/// Search one or more areas and pick a record — Relationship and Tasks.
private struct RecordSearch: View {
    let model: TaskDetailModel
    let areas: [String]
    let exclude: Set<String>
    let onPick: (TagHit) -> Void
    @State private var search: TagSearch?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if areas.count > 1 {
                HStack(spacing: 4) {
                    ForEach(areas, id: \.self) { a in
                        FieldChipToggle(title: TaskFields.tagAreaLabel(a), on: search?.area == a) { search = TagSearch(area: a, model: model) }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 6)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Where to search")
            }
            if let search {
                SearchField(placeholder: "Search \(TaskFields.tagAreaLabel(search.area).lowercased())…",
                            text: Binding(get: { search.query }, set: { search.query = $0 }), busy: search.busy)
                SearchResults(search: search, none: "Nothing matches", exclude: exclude) { h in
                    FieldMenuRow(action: { onPick(h) }) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.label).lineLimit(1)
                            if let s = h.secondary { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 4)
                        if let status = h.status {
                            Text(status).font(.system(size: 10)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
            }
        }
        .onAppear { if search == nil { search = TagSearch(area: areas.first ?? "task", model: model) } }
    }
}

private struct RelationshipEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let refs = field.value.array ?? []
        let configured = (field.config.areas ?? []).filter { TaskFields.isTagArea($0) }
        let areas = configured.isEmpty ? TaskFields.tagAreas.map(\.key) : configured
        FieldFlow {
            ForEach(Array(refs.enumerated()), id: \.offset) { _, r in
                let area = r["area"]?.string ?? ""
                let href = r["href"]?.string ?? ""
                let opens = href.hasPrefix("/tasks?task=") || href.hasPrefix("/files/")
                RefChip(label: r["label"]?.string ?? "", onOpen: opens ? { ctx.onOpen(href) } : nil,
                        onRemove: ctx.readOnly ? nil : { commit(refs.filter { !($0["area"] == r["area"] && $0["id"] == r["id"]) }) }) {
                    Text(TaskFields.tagAreaLabel(area).uppercased()).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            if refs.isEmpty && ctx.readOnly { Text("—").font(.system(size: 13)).foregroundStyle(.tertiary) }
            if !ctx.readOnly, let model = ctx.model {
                Group {
                    if refs.isEmpty { EmptyPill(text: "Link a record") { open.toggle() } } else { AddButton(label: "Link to \(field.label)") { open.toggle() } }
                }
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    RecordSearch(model: model, areas: areas, exclude: Set(refs.compactMap { $0["id"]?.string })) { h in
                        commit(refs + [.object(["area": .string(h.area), "id": .string(h.id), "label": .string(h.label), "href": .string(h.href)])])
                    }
                    .frame(width: 300)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    private func commit(_ next: [CrmValue]) { onCommit(next.isEmpty ? .null : .array(next)) }
}

private struct TasksEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let refs = field.value.array ?? []
        let exclude = Set(refs.compactMap { $0["id"]?.string } + (ctx.taskId.map { [$0] } ?? []))
        FieldFlow {
            ForEach(Array(refs.enumerated()), id: \.offset) { _, r in
                let id = r["id"]?.string ?? ""
                RefChip(label: r["label"]?.string ?? "Task",
                        onOpen: { ctx.onOpen("/tasks?task=\(id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id)") },
                        onRemove: ctx.readOnly ? nil : { commit(refs.filter { $0["id"]?.string != id }) }) {
                    Image(systemName: "checklist").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if refs.isEmpty && ctx.readOnly { Text("—").font(.system(size: 13)).foregroundStyle(.tertiary) }
            if !ctx.readOnly, let model = ctx.model {
                Group {
                    if refs.isEmpty { EmptyPill(text: "Link a task") { open.toggle() } } else { AddButton(label: "Link a task to \(field.label)") { open.toggle() } }
                }
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    RecordSearch(model: model, areas: ["task"], exclude: exclude) { h in
                        commit(refs + [.object(["id": .string(h.id), "label": .string(h.label)])])
                    }
                    .frame(width: 300)
                }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    private func commit(_ next: [CrmValue]) { onCommit(next.isEmpty ? .null : .array(next)) }
}

private struct FilesEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void

    var body: some View {
        let refs = field.value.array ?? []
        let busy = ctx.busy.contains(field.id)
        FieldFlow {
            ForEach(Array(refs.enumerated()), id: \.offset) { _, f in
                let id = f["id"]?.string ?? ""
                RefChip(label: f["name"]?.string ?? "", onOpen: ctx.taskId == nil ? nil : { ctx.model?.openFile(id) },
                        onRemove: ctx.readOnly ? nil : { commit(refs.filter { $0["id"]?.string != id }) }) {
                    Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if refs.isEmpty && ctx.readOnly { Text("—").font(.system(size: 13)).foregroundStyle(.tertiary) }
            if busy { ProgressView().controlSize(.mini).accessibilityLabel("Uploading") }
            if !ctx.readOnly {
                Button {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = false
                    panel.message = "Upload to \(field.label)"
                    guard NativeFront.personActing else { return }
                    if panel.runModal() == .OK, !panel.urls.isEmpty { ctx.onFiles(field, panel.urls) } // front-ok: guarded by NativeFront.personActing
                } label: {
                    Label("Upload", systemImage: "arrow.up.doc").font(.caption).padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(busy)
                .accessibilityLabel("Upload to \(field.label)")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    private func commit(_ next: [CrmValue]) { onCommit(next.isEmpty ? .null : .array(next)) }
}

/// Draw with the trackpad or a mouse, or type a name. Stored as a PNG or the typed
/// text; WHO signed and WHEN are stamped by the engine.
private struct SignaturePad: View {
    let onSave: (CrmValue) -> Void
    let onCancel: () -> Void
    @State private var mode = "draw"
    @State private var text = ""
    @State private var strokes: [[CGPoint]] = []
    @State private var drawing = false
    @State private var padSize = CGSize(width: 296, height: 100)

    private var inked: Bool { strokes.contains { $0.count > 1 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                FieldChipToggle(title: "Draw", on: mode == "draw") { mode = "draw" }
                FieldChipToggle(title: "Type", on: mode == "type") { mode = "type" }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("How to sign")
            if mode == "draw" {
                Canvas { context, _ in
                    for s in strokes where !s.isEmpty {
                        var path = Path()
                        path.addLines(s)
                        context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    }
                }
                .frame(height: 100)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .onGeometryChange(for: CGSize.self) { $0.size } action: { padSize = $0 }
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    if !drawing {
                        strokes.append([g.location])
                        drawing = true
                    } else if !strokes.isEmpty {
                        strokes[strokes.count - 1].append(g.location)
                    }
                }.onEnded { _ in drawing = false })
                .accessibilityLabel("Draw your signature")
            } else {
                TextField("Type your full name", text: Binding(get: { text }, set: { text = String($0.prefix(80)) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 18, design: .serif).italic())
                    .accessibilityLabel("Type your signature")
            }
            HStack(spacing: 8) {
                if mode == "draw" { Button("Clear") { strokes = [] }.buttonStyle(.borderless) }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Sign") {
                    if mode == "type" {
                        onSave(.object(["mode": .string("typed"), "text": .string(text.trimmingCharacters(in: .whitespacesAndNewlines))]))
                    } else if let url = Self.png(strokes, from: padSize) {
                        onSave(.object(["mode": .string("drawn"), "dataUrl": .string(url)]))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(mode == "draw" ? !inked : text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
        .padding(8)
    }

    /// The strokes on a 560 × 200 transparent PNG, as a data address.
    static func png(_ strokes: [[CGPoint]], from size: CGSize) -> String? {
        let w = 560, h = 200
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let sx = CGFloat(w) / max(size.width, 1)
        let sy = CGFloat(h) / max(size.height, 1)
        NSColor.black.setStroke()
        for s in strokes where !s.isEmpty {
            let path = NSBezierPath()
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let at = { (p: CGPoint) in NSPoint(x: p.x * sx, y: CGFloat(h) - p.y * sy) }
            path.move(to: at(s[0]))
            for p in s.dropFirst() { path.line(to: at(p)) }
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + data.base64EncodedString()
    }
}

private struct SignatureEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let sig = field.value
        if sig.object != nil {
            let by = sig["by"]?.string ?? ""
            let who = ctx.people[by]?.name ?? (by == ctx.viewerId ? "you" : nil)
            let at = sig["at"]?.string ?? ""
            let when = at.isEmpty ? "" : TaskFields.formatDate(Self.localYmd(at), time: nil)
            HStack(spacing: 8) {
                if sig["mode"]?.string == "drawn", let image = sig["dataUrl"]?.string.flatMap(AttachmentsSection.image) {
                    Image(nsImage: image).resizable().scaledToFit().frame(height: 36)
                        .padding(.horizontal, 4).background(RoundedRectangle(cornerRadius: 4).fill(Color.white))
                        .accessibilityLabel("Signature")
                } else {
                    Text(sig["text"]?.string ?? "").font(.system(size: 15, design: .serif).italic())
                }
                Text([who.map { "by \($0)" }, when.isEmpty ? nil : when].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                Spacer()
                if !ctx.readOnly {
                    Button { onCommit(.null) } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .accessibilityLabel("Clear \(field.label)")
                }
            }
            .padding(.horizontal, 6)
        } else if ctx.readOnly {
            Text("—").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 8)
        } else {
            Button { open.toggle() } label: {
                Label("Sign", systemImage: "signature").font(.system(size: 13)).padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SignaturePad(onSave: { raw in
                    open = false
                    onCommit(raw)
                }, onCancel: { open = false })
                .frame(width: 320)
            }
        }
    }

    /// The local day an instant fell on.
    static func localYmd(_ iso: String) -> String {
        guard let d = CrmTime.date(iso) else { return String(iso.prefix(10)) }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}

private struct ProgressManualEditor: View {
    let field: TaskField
    let readOnly: Bool
    let onCommit: (CrmValue) -> Void
    @State private var drag: Double?

    var body: some View {
        let start = field.config.start ?? 0
        let end = Swift.max(field.config.end ?? 100, start + 1)
        let saved = field.value.number ?? start
        let shown = drag ?? saved
        let step = (end - start) / 100 >= 1 ? 1 : (end - start) / 100
        HStack(spacing: 8) {
            Slider(value: Binding(get: { shown }, set: { drag = $0 }), in: start...end, step: step, onEditingChanged: { editing in
                guard !editing else { return }
                if let d = drag, d != saved { onCommit(.number(d)) }
                drag = nil
            })
            .controlSize(.small)
            .tint(TaskTone.completed)
            .disabled(readOnly)
            .frame(minWidth: 80)
            .accessibilityLabel(field.label)
            Text("\(TaskFields.manualPercent(field.config, shown))%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 8)
    }
}

/// The date button (dd/mm/yyyy, or "Empty") and its calendar: a day click saves
/// and closes; Clear, Today and Cancel along the bottom (date-picker-input.tsx).
private struct FieldDatePicker: View {
    let value: String
    let label: String
    let onChange: (String) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Group {
                if value.isEmpty {
                    Label("Empty", systemImage: "calendar").foregroundStyle(.tertiary)
                } else {
                    Text(Self.display(value))
                }
            }
            .font(.caption)
            .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.isEmpty ? label : "\(label) — \(Self.display(value))")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 6) {
                DatePicker("Pick a date", selection: Binding(get: { Self.date(value) ?? Date() }, set: { d in
                    open = false
                    onChange(Self.ymd(d))
                }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                Divider()
                HStack(spacing: 2) {
                    Button("Clear") {
                        open = false
                        onChange("")
                    }
                    Button("Today") {
                        open = false
                        onChange(Self.ymd(Date()))
                    }
                    Spacer()
                    Button("Cancel") { open = false }.buttonStyle(.bordered)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .controlSize(.small)
            }
            .padding(8)
            .frame(width: 256)
        }
    }

    static func display(_ ymd: String) -> String {
        let p = ymd.split(separator: "-")
        return p.count == 3 ? "\(p[2])/\(p[1])/\(p[0])" : ymd
    }

    static func ymd(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ ymd: String) -> Date? {
        let p = ymd.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

private struct DateEditor: View {
    let field: TaskField
    let readOnly: Bool
    let onCommit: (CrmValue) -> Void
    @State private var time = ""
    @FocusState private var timeFocused: Bool

    var body: some View {
        let date = field.value["date"]?.string
        let t = field.value["time"]?.string
        if readOnly {
            Text(date.map { TaskFields.formatDate($0, time: t) } ?? "—").font(.system(size: 13))
                .foregroundStyle(date == nil ? .tertiary : .primary).padding(.horizontal, 8)
        } else {
            HStack(spacing: 6) {
                FieldDatePicker(value: date ?? "", label: field.label) { iso in
                    onCommit(iso.isEmpty ? .null : .object(["date": .string(iso), "time": t.map { .string($0) } ?? .null]))
                }
                if field.config.includeTime == true, let date {
                    TextField("--:--", text: $time)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13).monospacedDigit())
                        .frame(width: 60)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(timeFocused ? Color(nsColor: .textBackgroundColor) : Color.secondary.opacity(0.08)))
                        .focused($timeFocused)
                        .onAppear { time = t ?? "" }
                        .onChange(of: t) { _, now in time = now ?? "" }
                        .onSubmit { timeFocused = false }
                        .onChange(of: timeFocused) { _, now in
                            guard !now else { return }
                            let next = time.trimmingCharacters(in: .whitespaces)
                            if next != (t ?? "") { onCommit(.object(["date": .string(date), "time": next.isEmpty ? .null : .string(next)])) }
                        }
                        .accessibilityLabel("\(field.label) time")
                }
                if date != nil {
                    Button { onCommit(.null) } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                        .accessibilityLabel("Clear \(field.label)")
                }
            }
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - The value editor, per kind

struct FieldValueEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void

    var body: some View {
        let ro = ctx.readOnly
        let v = field.value
        let str = v.string ?? ""
        switch field.kind {
        case .text:
            FieldTextCell(value: str, onCommit: { onCommit(.string($0)) }, readOnly: ro, label: field.label)
        case .longText:
            FieldTextCell(value: str, onCommit: { onCommit(.string($0)) }, readOnly: ro, multiline: true, placeholder: "Write something…", label: field.label)
        case .number:
            let d = field.config.decimals ?? 2
            FieldTextCell(value: v.number.map(TaskFields.js) ?? "", display: v.number.map { TaskFields.formatNumber($0, d) } ?? "",
                          onCommit: { onCommit(.string($0)) }, readOnly: ro, label: field.label)
        case .money:
            let d = field.config.decimals ?? 2
            FieldTextCell(value: v.number.map(TaskFields.js) ?? "", display: v.number.map { TaskFields.formatNumber($0, d, fixed: true) } ?? "",
                          onCommit: { onCommit(.string($0)) }, readOnly: ro, label: field.label, prefix: field.config.currency ?? TaskFields.defaultCurrency)
        case .website, .email, .phone:
            ContactEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .location:
            HStack(spacing: 0) {
                FieldTextCell(value: v["text"]?.string ?? "", onCommit: { onCommit(.string($0)) }, readOnly: ro, placeholder: "Address or lat, lng", label: field.label)
                if v.object != nil { LinkOut(url: URL(string: TaskFields.mapHref(v)), label: "Open in Maps") }
            }
        case .checkbox:
            Toggle(field.label, isOn: Binding(get: { v == .bool(true) }, set: { onCommit(.bool($0)) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(ro)
                .padding(.horizontal, 8).frame(height: 28)
        case .date:
            DateEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .dropdown:
            DropdownEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .labels:
            LabelsEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .rating:
            RatingEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .people:
            PeopleEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .relationship:
            RelationshipEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .tasks:
            TasksEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .files:
            FilesEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .signature:
            SignatureEditor(field: field, ctx: ctx, onCommit: onCommit)
        case .progressManual:
            ProgressManualEditor(field: field, readOnly: ro, onCommit: onCommit)
        case .progressAuto:
            if ctx.taskId == nil {
                Text("Counted from subtasks and checklists once the task is saved").font(.system(size: 13)).foregroundStyle(.tertiary).padding(.horizontal, 8)
            } else {
                let p = TaskFields.autoProgress(field.config, ctx.auto)
                HStack(spacing: 0) {
                    ProgressBarField(percent: p.percent, label: field.label)
                    Text("\(p.done)/\(p.total)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary).padding(.trailing, 8)
                }
                .help("\(p.done) of \(p.total) done")
            }
        case .formula:
            FormulaValue(field: field, ctx: ctx)
        case .voting:
            VotingButton(field: field, ctx: ctx)
        case .button:
            PressButton(field: field, ctx: ctx)
        }
    }
}

private struct ContactEditor: View {
    let field: TaskField
    let readOnly: Bool
    let onCommit: (CrmValue) -> Void

    var body: some View {
        let str = field.value.string ?? ""
        let url: URL? = str.isEmpty ? nil : field.kind == .website ? URL(string: str)
            : field.kind == .email ? URL(string: "mailto:\(str)") : URL(string: "tel:\(str.filter { $0.isNumber || $0 == "+" })")
        let placeholder = field.kind == .website ? "https://" : field.kind == .email ? "name@example.com" : "+971 50 000 0000"
        let linkLabel = field.kind == .website ? "Open link" : field.kind == .email ? "Send email" : "Call"
        HStack(spacing: 0) {
            FieldTextCell(value: str, onCommit: { onCommit(.string($0)) }, readOnly: readOnly, placeholder: placeholder, label: field.label)
            if !str.isEmpty { LinkOut(url: url, label: linkLabel) }
        }
    }
}

private struct FormulaValue: View {
    let field: TaskField
    let ctx: FieldCtx

    var body: some View {
        let others = ctx.fields.filter { $0.id != field.id }
        switch TaskFields.computeFormula(field.config.expression, others) {
        case .failure(let f):
            Text(f.error).font(.caption).foregroundStyle(TaskTone.input).lineLimit(1).padding(.horizontal, 8)
                .help(field.config.expression ?? "")
        case .success(let n):
            let d = field.config.decimals ?? 2
            Text(field.config.currency.map { TaskFields.formatMoney(n, $0, d) } ?? TaskFields.formatNumber(n, d))
                .font(.system(size: 13)).monospacedDigit().padding(.horizontal, 8)
                .help(field.config.expression ?? "")
        }
    }
}

private struct VotingButton: View {
    let field: TaskField
    let ctx: FieldCtx

    var body: some View {
        let votes = Array((field.value["votes"]?.object ?? [:]).keys).sorted()
        let mine = ctx.viewerId.map { votes.contains($0) } ?? false
        let names = votes.map { id in ctx.people[id]?.name ?? (id == ctx.viewerId ? "You" : "Someone") }.joined(separator: ", ")
        Button { ctx.onVote(field) } label: {
            HStack(spacing: 6) {
                Image(systemName: mine ? "hand.thumbsup.fill" : "hand.thumbsup").font(.system(size: 12))
                Text("\(votes.count)").monospacedDigit()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(mine ? Color.accentColor : .secondary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(mine ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(ctx.readOnly || ctx.busy.contains(field.id))
        .help(names.isEmpty ? "No votes yet" : names)
        .accessibilityLabel("\(field.label): \(votes.count) votes")
        .accessibilityAddTraits(mine ? .isSelected : [])
        .padding(.horizontal, 6)
    }
}

private struct PressButton: View {
    let field: TaskField
    let ctx: FieldCtx

    var body: some View {
        let count = Int(field.value["count"]?.number ?? 0)
        let busy = ctx.busy.contains(field.id)
        HStack(spacing: 8) {
            Button { ctx.onPress(field) } label: {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.mini) }
                    Text(field.config.label ?? "Button")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(FieldPaint.hex(field.config.color)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(ctx.readOnly || ctx.taskId == nil || busy)
            .opacity(ctx.readOnly || ctx.taskId == nil || busy ? 0.5 : 1)
            .help(ctx.taskId == nil ? "Works once the task is created" : "")
            if count > 0 { Text("Pressed \(count)×").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 6)
    }
}

// MARK: - The type picker

/// ClickUp's list: a search box, "All" and the groups, then every type.
struct FieldTypePicker: View {
    let current: FieldKind?
    let onPick: (FieldKind) -> Void
    @State private var query = ""
    @State private var group: FieldGroup?
    @FocusState private var focused: Bool

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = TaskFields.types.filter { t in
            (group == nil || t.group == group) && (needle.isEmpty || t.name.lowercased().contains(needle) || t.hint.lowercased().contains(needle))
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { if let first = shown.first { onPick(first.kind) } }
                    .accessibilityLabel("Search field types")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            FieldFlow {
                FieldChipToggle(title: "All", on: group == nil) { group = nil }
                ForEach(FieldGroup.allCases, id: \.self) { g in
                    FieldChipToggle(title: g.label, on: group == g) { group = g }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filter field types")
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if shown.isEmpty {
                        Text("No field type matches “\(query.trimmingCharacters(in: .whitespaces))”.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    ForEach(shown, id: \.kind) { t in
                        FieldMenuRow(action: { onPick(t.kind) }) {
                            FieldTypeIcon(kind: t.kind)
                            Text(t.name).lineLimit(1)
                            Spacer()
                            if t.kind == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                        }
                        .accessibilityAddTraits(t.kind == current ? .isSelected : [])
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: 288)
            .accessibilityLabel("Field types")
        }
        .onAppear { focused = true }
    }
}

// MARK: - Type-specific settings

private struct FieldCaption: View {
    let text: String
    var required = false

    var body: some View {
        (Text(text) + (required ? Text(" *").foregroundColor(TaskTone.input) : Text("")))
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }
}

private struct OptionsEditor: View {
    @Binding var options: [FieldOption]
    let noun: String
    @State private var adding = ""
    @State private var palette: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldCaption(text: noun == "label" ? "Labels" : "Options")
            ForEach(Array(options.enumerated()), id: \.element.id) { i, o in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Button { palette = palette == o.id ? nil : o.id } label: { Circle().fill(FieldPaint.hex(o.color)).frame(width: 16, height: 16) }
                            .buttonStyle(.plain).accessibilityLabel("Colour of \(o.label)")
                        TextField("", text: Binding(get: { o.label }, set: { new in
                            options = options.map { $0.id == o.id ? FieldOption(id: $0.id, label: String(new.prefix(60)), color: $0.color) : $0 }
                        }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("\(noun) \(i + 1)")
                        Button { options.removeAll { $0.id == o.id } } label: { Image(systemName: "xmark").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Remove \(o.label)")
                    }
                    if palette == o.id {
                        HStack(spacing: 4) {
                            ForEach(TaskFields.colors, id: \.self) { c in
                                Button {
                                    options = options.map { $0.id == o.id ? FieldOption(id: $0.id, label: $0.label, color: c) : $0 }
                                    palette = nil
                                } label: {
                                    Circle().fill(FieldPaint.hex(c)).frame(width: 20, height: 20)
                                        .overlay { if o.color == c { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                                }
                                .buttonStyle(.plain).accessibilityLabel(c)
                                .accessibilityAddTraits(o.color == c ? .isSelected : [])
                            }
                        }
                        .padding(.leading, 22)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Colours for \(o.label)")
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(FieldPaint.hex(TaskFields.colors[options.count % TaskFields.colors.count])).opacity(0.5).frame(width: 16, height: 16)
                TextField("Add \(noun)…", text: Binding(get: { adding }, set: { adding = String($0.prefix(60)) }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .accessibilityLabel("New \(noun)")
            }
        }
        .onDisappear(perform: add)
    }

    private func add() {
        let label = adding.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !label.isEmpty, !options.contains(where: { TaskFields.sameLabel($0.label, label) }) else { return }
        options.append(FieldOption(id: String(TaskFields.newKey().prefix(36)), label: label, color: TaskFields.colors[options.count % TaskFields.colors.count]))
        adding = ""
    }
}

/// Everything a type can be told, before and after it is created ("Edit options").
struct FieldConfigForm: View {
    let kind: FieldKind
    @Binding var config: FieldConfig
    let siblings: [TaskField]
    var selfId: String?
    var team: [CrmPerson] = []

    private static let decimals = Array(0...6)

    var body: some View {
        switch kind {
        case .dropdown, .labels:
            OptionsEditor(options: Binding(get: { config.options ?? [] }, set: { config.options = $0 }), noun: kind == .labels ? "label" : "option")
        case .number:
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Decimals")
                decimalsPicker("Decimals", Self.decimals)
            }
        case .money:
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Currency")
                    Picker("Currency", selection: Binding(get: { config.currency ?? TaskFields.defaultCurrency }, set: { config.currency = $0 })) {
                        ForEach(TaskFields.currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Decimals")
                    decimalsPicker("Decimals", Array(0...4))
                }
            }
        case .date:
            Toggle("Include time", isOn: Binding(get: { config.includeTime == true }, set: { config.includeTime = $0 })).toggleStyle(.checkbox)
        case .rating:
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Out of")
                    Picker("Rating maximum", selection: Binding(get: { config.max ?? 5 }, set: { config.max = $0 })) {
                        ForEach(1...10, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Icon")
                    HStack(spacing: 4) {
                        ForEach(RatingIcon.allCases, id: \.self) { r in
                            let on = (config.icon ?? .star) == r
                            Button { config.icon = r } label: {
                                Text(r.glyph).foregroundStyle(Color.orange).frame(width: 32, height: 32)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(r.label)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Rating icon")
                }
            }
        case .progressManual:
            HStack(spacing: 8) {
                numberBox("Start", Binding(get: { config.start ?? 0 }, set: { config.start = $0 }))
                numberBox("End", Binding(get: { config.end ?? 100 }, set: { config.end = $0 }))
            }
        case .progressAuto:
            VStack(alignment: .leading, spacing: 6) {
                FieldCaption(text: "Count")
                Toggle("Subtasks", isOn: Binding(get: { config.subtasks != false }, set: { config.subtasks = $0 })).toggleStyle(.checkbox)
                Toggle("Checklist items", isOn: Binding(get: { config.checklists != false }, set: { config.checklists = $0 })).toggleStyle(.checkbox)
            }
        case .formula:
            FormulaSettings(config: $config, siblings: siblings, selfId: selfId)
        case .relationship:
            let areas = config.areas ?? []
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Link to")
                HStack(spacing: 4) {
                    ForEach(TaskFields.tagAreas, id: \.key) { a in
                        let on = areas.contains(a.key)
                        FieldChipToggle(title: a.label, on: on) { config.areas = on ? areas.filter { $0 != a.key } : areas + [a.key] }
                    }
                }
                Text(areas.isEmpty ? "None picked = anything in the CRM." : "Only these.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        case .button:
            ButtonSettings(config: $config, siblings: siblings, selfId: selfId, team: team)
        default:
            EmptyView()
        }
    }

    private func decimalsPicker(_ label: String, _ values: [Int]) -> some View {
        Picker(label, selection: Binding(get: { config.decimals ?? 2 }, set: { config.decimals = $0 })) {
            ForEach(values, id: \.self) { Text(TaskFields.decimalsLabel($0)).tag($0) }
        }
        .labelsHidden()
    }

    private func numberBox(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldCaption(text: label)
            TextField(label, value: value, format: .number).textFieldStyle(.roundedBorder).accessibilityLabel(label)
        }
    }
}

private struct FormulaSettings: View {
    @Binding var config: FieldConfig
    let siblings: [TaskField]
    let selfId: String?

    var body: some View {
        let others = siblings.filter { $0.id != selfId }
        let numeric = others.filter { [.number, .money, .rating, .progressManual, .checkbox].contains($0.kind) }
        let expression = config.expression ?? ""
        let preview: FieldRes<Double>? = expression.isEmpty ? nil : TaskFields.computeFormula(expression, others)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Formula")
                TextField("{Price} * {Quantity}", text: Binding(get: { expression }, set: { config.expression = String($0.prefix(500)) }), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel("Formula")
                Text("Fields in {braces} · + − * / % ( ) · round, min, max, abs, floor, ceil").font(.system(size: 11)).foregroundStyle(.tertiary)
                if !numeric.isEmpty {
                    FieldFlow {
                        ForEach(numeric) { s in
                            Button {
                                let base = expression.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                                let next = "\(base) {\(s.label)}"
                                config.expression = next.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
                            } label: {
                                Text("{\(s.label)}").font(.system(size: 11)).padding(.horizontal, 6).frame(height: 24)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.12)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                switch preview {
                case .success(let n)?:
                    Text("= \(TaskFields.formatNumber(n, config.decimals ?? 2))").font(.caption).foregroundStyle(.secondary)
                case .failure(let f)?:
                    Text(f.error).font(.caption).foregroundStyle(TaskTone.input)
                case nil:
                    EmptyView()
                }
            }
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Show as")
                    Picker("Show formula as", selection: Binding(get: { config.currency ?? "" }, set: { config.currency = $0.isEmpty ? nil : $0 })) {
                        Text("Number").tag("")
                        ForEach(TaskFields.currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Decimals")
                    Picker("Formula decimals", selection: Binding(get: { config.decimals ?? 2 }, set: { config.decimals = $0 })) {
                        ForEach(0...6, id: \.self) { Text(TaskFields.decimalsLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                }
            }
        }
    }
}

private struct ButtonSettings: View {
    @Binding var config: FieldConfig
    let siblings: [TaskField]
    let selfId: String?
    let team: [CrmPerson]

    var body: some View {
        let action = config.action ?? .status("Done")
        let targets = siblings.filter { $0.id != selfId && TaskFields.buttonTargetKinds.contains($0.kind) }
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Button label")
                TextField("Mark done", text: Binding(get: { config.label ?? "" }, set: { config.label = String($0.prefix(40)) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Button label")
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "Colour")
                HStack(spacing: 4) {
                    ForEach(TaskFields.colors, id: \.self) { c in
                        Button { config.color = c } label: {
                            Circle().fill(FieldPaint.hex(c)).frame(width: 20, height: 20)
                                .overlay { if config.color == c { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                        }
                        .buttonStyle(.plain).accessibilityLabel(c)
                        .accessibilityAddTraits(config.color == c ? .isSelected : [])
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Button colour")
            }
            VStack(alignment: .leading, spacing: 4) {
                FieldCaption(text: "When pressed")
                Picker("Button action", selection: Binding(get: { action.type }, set: { type in
                    switch type {
                    case "status": config.action = .status("Done")
                    case "comment": config.action = .comment("")
                    default: config.action = .field(fieldId: targets.first?.id ?? "", value: .null)
                    }
                })) {
                    Text("Set the status").tag("status")
                    Text("Set a field").tag("field")
                    Text("Add a comment").tag("comment")
                }
                .labelsHidden()
            }
            switch action {
            case .status(let status):
                Picker("Status the button sets", selection: Binding(get: { status }, set: { config.action = .status($0) })) {
                    ForEach(TaskFields.buttonStatuses, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            case .comment(let body):
                TextField("Comment to add…", text: Binding(get: { body }, set: { config.action = .comment(String($0.prefix(2000))) }), axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Comment the button adds")
            case .field(let fieldId, let value):
                if targets.isEmpty {
                    Text("Add a Text, Number, Money, Date, Checkbox, Dropdown, Labels, Rating, Progress, Website, Email, Phone or Location field first.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Field the button sets", selection: Binding(get: { fieldId }, set: { config.action = .field(fieldId: $0, value: .null) })) {
                        Text("Choose a field…").tag("")
                        ForEach(targets) { Text($0.label).tag($0.id) }
                    }
                    .labelsHidden()
                    if let target = targets.first(where: { $0.id == fieldId }) {
                        let shadow = TaskField(id: "btn-target-\(target.id)", taskId: "", label: "\(target.label) value", kind: target.kind,
                                               config: target.config, value: value)
                        FieldValueEditor(field: shadow, ctx: .detached(team: team)) { raw in
                            let n = TaskFields.normaliseValue(target.kind, target.config, raw, ctx: ValueCtx(userId: "", now: ""))
                            config.action = .field(fieldId: target.id, value: (try? n.get()) ?? raw)
                        }
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
                    }
                }
            }
        }
    }
}

// MARK: - The create form

/// Pick a type, then name it: ClickUp's two steps. The type switcher goes back to
/// the list without losing the name; × closes; Create waits for a valid name.
struct CreateFieldPanel: View {
    let siblings: [TaskField]
    var team: [CrmPerson] = []
    let onCancel: () -> Void
    /// Resolves to an error in words, or nil when the field was made.
    let onCreate: (String, FieldKind, FieldConfig) async -> String?
    @State private var picking = true
    @State private var kind: FieldKind = .text
    @State private var label = ""
    @State private var config = TaskFields.defaultConfig(.text)
    @State private var error: String?
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let nameOk = (try? TaskFields.normaliseLabel(label).get()) != nil
        if picking {
            FieldTypePicker(current: label.isEmpty ? nil : kind) { k in
                if k != kind { config = TaskFields.defaultConfig(k) }
                kind = k
                error = nil
                picking = false
            }
        } else {
            let info = TaskFields.info(kind)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button { picking = true } label: {
                        HStack(spacing: 6) {
                            FieldTypeIcon(kind: kind, size: 18)
                            Text(info.name).font(.system(size: 13, weight: .medium))
                            Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Field type: \(info.name). Change type")
                    Spacer()
                    Button(action: onCancel) { Image(systemName: "xmark").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Close")
                }
                VStack(alignment: .leading, spacing: 4) {
                    FieldCaption(text: "Field name", required: true)
                    TextField("Enter name…", text: Binding(get: { label }, set: { label = String($0.prefix(80)); error = nil }))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { if nameOk && !saving { create() } }
                        .accessibilityLabel("Field name")
                }
                FieldConfigForm(kind: kind, config: Binding(get: { config }, set: { config = $0; error = nil }), siblings: siblings, team: team)
                if let error { Text(error).font(.caption).foregroundStyle(TaskTone.input) }
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button { create() } label: {
                        HStack(spacing: 4) {
                            if saving { ProgressView().controlSize(.mini) }
                            Text("Create")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!nameOk || saving)
                }
            }
            .padding(12)
            .onAppear { nameFocused = true }
        }
    }

    private func create() {
        let name: String
        switch TaskFields.normaliseLabel(label) {
        case .failure(let f):
            error = f.error
            return
        case .success(let s):
            name = s
        }
        if siblings.contains(where: { TaskFields.sameLabel($0.label, name) }) {
            error = "This task already has a field called “\(name)”"
            return
        }
        let clean: FieldConfig
        switch TaskFields.normaliseConfig(kind, config.crm(kind), siblings: siblings) {
        case .failure(let f):
            error = f.error
            return
        case .success(let c):
            clean = c
        }
        saving = true
        error = nil
        Task {
            let err = await onCreate(name, kind, clean)
            saving = false
            if let err { error = err }
        }
    }
}

// MARK: - One row

private struct FieldRow: View {
    let field: TaskField
    let ctx: FieldCtx
    let first: Bool
    let last: Bool
    let error: String?
    let store: FieldsStore
    private enum Menu { case menu, options, delete }
    @State private var menu: Menu?
    @State private var renaming = false
    @State private var name = ""
    @State private var cfg = FieldConfig()
    @State private var menuErr: String?
    @State private var saving = false
    @State private var hover = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let info = TaskFields.info(field.kind)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                HStack(spacing: 6) {
                    FieldTypeIcon(kind: field.kind, size: 18)
                    if renaming {
                        TextField("Field name", text: Binding(get: { name }, set: { name = String($0.prefix(80)) }))
                            .textFieldStyle(.roundedBorder)
                            .focused($nameFocused)
                            .onAppear { nameFocused = true }
                            .onSubmit { nameFocused = false }
                            .onExitCommand {
                                name = field.label
                                renaming = false
                            }
                            .onChange(of: nameFocused) { _, now in if !now && renaming { commitRename() } }
                            .accessibilityLabel("Field name")
                    } else {
                        Text(field.label).lineLimit(1)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 170, height: 28, alignment: .leading)
                .help(info.name)
                FieldValueEditor(field: field, ctx: ctx) { v in Task { await store.commitValue(field, v) } }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                if !ctx.readOnly {
                    Button {
                        menuErr = nil
                        menu = menu == nil ? .menu : nil
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .opacity(hover || menu != nil ? 1 : 0)
                    .accessibilityLabel("More for \(field.label)")
                    .popover(isPresented: Binding(get: { menu != nil }, set: { if !$0 { menu = nil } }), arrowEdge: .bottom) {
                        menuContent.frame(width: menu == .options ? 320 : 200)
                    }
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.secondary.opacity(0.06) : .clear))
            .onHover { hover = $0 }
            if let error {
                Text(error).font(.caption).foregroundStyle(TaskTone.input).padding(.leading, 32).padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder private var menuContent: some View {
        switch menu {
        case .menu?:
            VStack(alignment: .leading, spacing: 0) {
                FieldMenuRow(action: {
                    menu = nil
                    name = field.label
                    renaming = true
                }) { Label("Rename", systemImage: "pencil") }
                if TaskFields.hasOptions(field.kind) {
                    FieldMenuRow(action: {
                        cfg = field.config
                        menuErr = nil
                        menu = .options
                    }) { Label("Edit options", systemImage: "gearshape") }
                }
                FieldMenuRow(action: {
                    menu = nil
                    Task { await store.move(field, -1) }
                }) { Label("Move up", systemImage: "arrow.up") }
                    .disabled(first).opacity(first ? 0.4 : 1)
                FieldMenuRow(action: {
                    menu = nil
                    Task { await store.move(field, 1) }
                }) { Label("Move down", systemImage: "arrow.down") }
                    .disabled(last).opacity(last ? 0.4 : 1)
                Divider().padding(.vertical, 4)
                FieldMenuRow(action: { menu = .delete }) { Label("Delete", systemImage: "trash").foregroundStyle(TaskTone.input) }
            }
            .padding(4)
        case .delete?:
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete “\(field.label)” and its value?").font(.system(size: 13))
                HStack {
                    Spacer()
                    Button("Cancel") { menu = nil }
                    Button("Delete field", role: .destructive) {
                        menu = nil
                        Task { await store.delete(field) }
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                }
                .controlSize(.small)
            }
            .padding(12)
        case .options?:
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    FieldTypeIcon(kind: field.kind, size: 18)
                    Text(field.label).font(.system(size: 13, weight: .medium))
                }
                FieldConfigForm(kind: field.kind, config: $cfg, siblings: ctx.fields.filter { $0.id != field.id }, selfId: field.id, team: ctx.team)
                if let menuErr { Text(menuErr).font(.caption).foregroundStyle(TaskTone.input) }
                HStack {
                    Spacer()
                    Button("Cancel") { menu = nil }
                    Button("Save") { saveOptions() }.buttonStyle(.borderedProminent).disabled(saving)
                }
            }
            .padding(12)
        case nil:
            EmptyView()
        }
    }

    private func commitRename() {
        let next = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        renaming = false
        guard !next.isEmpty, next != field.label else {
            name = field.label
            return
        }
        let original = field.label
        Task {
            if await store.rename(field, next) != nil { name = original }
        }
    }

    private func saveOptions() {
        let siblings = ctx.fields.filter { $0.id != field.id }
        switch TaskFields.normaliseConfig(field.kind, cfg.crm(field.kind), siblings: siblings) {
        case .failure(let f):
            menuErr = f.error
        case .success(let clean):
            saving = true
            Task {
                let err = await store.saveConfig(field, clean)
                saving = false
                if let err { menuErr = err } else { menu = nil }
            }
        }
    }
}

// MARK: - Layout

/// Chips that wrap onto the next line, like a flex-wrap row.
struct FieldFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
