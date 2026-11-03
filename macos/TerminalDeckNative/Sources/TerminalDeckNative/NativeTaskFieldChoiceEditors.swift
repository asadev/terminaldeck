import AppKit
import SwiftUI
import TerminalDeckNativeCore
import UniformTypeIdentifiers

// MARK: - Choice editors

struct DropdownEditor: View {
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

struct LabelsEditor: View {
    let field: TaskField
    let readOnly: Bool
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let options = field.config.options ?? []
        let picked = (field.value.array ?? []).compactMap(\.string)
        TasksFlow(spacing: 4, lineSpacing: 4) {
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

struct RatingEditor: View {
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

struct PeopleEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let ids = (field.value.array ?? []).compactMap(\.string)
        TasksFlow(spacing: 4, lineSpacing: 4) {
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
struct RecordSearch: View {
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

struct RelationshipEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let refs = field.value.array ?? []
        let configured = (field.config.areas ?? []).filter { TaskFields.isTagArea($0) }
        let areas = configured.isEmpty ? TaskFields.tagAreas.map(\.key) : configured
        TasksFlow(spacing: 4, lineSpacing: 4) {
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

struct TasksEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void
    @State private var open = false

    var body: some View {
        let refs = field.value.array ?? []
        let exclude = Set(refs.compactMap { $0["id"]?.string } + (ctx.taskId.map { [$0] } ?? []))
        TasksFlow(spacing: 4, lineSpacing: 4) {
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

struct FilesEditor: View {
    let field: TaskField
    let ctx: FieldCtx
    let onCommit: (CrmValue) -> Void

    var body: some View {
        let refs = field.value.array ?? []
        let busy = ctx.busy.contains(field.id)
        TasksFlow(spacing: 4, lineSpacing: 4) {
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
struct SignaturePad: View {
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

struct SignatureEditor: View {
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

struct ProgressManualEditor: View {
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
struct FieldDatePicker: View {
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

struct DateEditor: View {
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
