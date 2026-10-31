import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// MARK: Card

/// The card. Two clearly marked parts: what the category template gives every seat (read-only here,
/// "Edit template…" opens the Templates screen) and this seat's own additions (edited here).
/// The size meter counts both; too long still saves and the meter says "over by N".
struct NativeMemoryCardPart: View {
    let store: NativeMemoryStore
    @State private var text = ""
    /// The saved card this editor last took; text that still equals it has not been typed in.
    @State private var base = ""
    private var saved: String { store.card?.text ?? "" }
    private var dirty: Bool { text != saved }
    private var category: DeckMemoryCategory? { store.owner.category }
    private var shared: String { store.template?.card ?? "" }
    private var limit: Int { store.template?.cardLimit ?? store.card?.limit ?? DeckMemoryCard.defaultLimit }
    private var total: Int { (category == nil ? 0 : shared.count) + text.count }
    private var over: Int { max(0, total - limit) }
    /// The template's top rules, then this seat's own, each once.
    private var allRules: [String] {
        var rules: [String] = []
        for rule in DeckMemoryCard.topRules(in: category == nil ? "" : shared) + DeckMemoryCard.topRules(in: text) where !rules.contains(rule) { rules.append(rule) }
        return rules
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                meter
                Spacer(minLength: 8)
                Button("Revert") { text = saved }.disabled(!dirty)
                Button("Save card") { let body = text; store.act("card", done: "Card saved") { _ = try await $0.saveCard(store.owner, text: body); return nil } }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command).disabled(!dirty || store.busy != nil)
            }
            if let category {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.3.fill").foregroundStyle(.secondary)
                        Text("Shared by \(category.everyone) (template)").font(.callout.weight(.semibold))
                        Text("\(shared.count.formatted()) characters · read-only here").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        NativeMemoryTemplatesButton(title: "Edit template…", category: category)
                    }
                    ScrollView {
                        Text(shared.isEmpty ? "The \(category.title) template has no shared card text yet." : shared)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 130)
                }
                .padding(10).background(DeckTokens.selection, in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 8) {
                    Image(systemName: "chair.fill").foregroundStyle(Color.accentColor)
                    Text(category == .orchestrator ? "Hoot's own" : "This role's own").font(.callout.weight(.semibold))
                    Text("Only this seat. It stays with the seat when the agent in it changes.").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextEditor(text: $text)
                .font(.system(size: 12.5, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(10).background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(over > 0 ? DeckTokens.bad.opacity(0.5) : DeckTokens.hairline))
                .accessibilityLabel("This seat's own card")
            NativeMemoryRuleList(rules: allRules, titles: store.ruleTitles)
            HStack(spacing: 14) {
                let rules = allRules.count
                Label(rules == 0 ? "No “## Top rules” section yet: those lines go with every message" : "\(rules) top rules go with every message", systemImage: "list.bullet")
                Spacer()
                if let at = store.card?.updatedAt { Text("Saved " + NativeMemoryStore.when(at)) }
                if dirty { Text("Not saved yet").foregroundStyle(DeckTokens.warn) }
            }.font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.bottom, 16)
        .onAppear { adopt() }
        .onChange(of: store.card?.updatedAt) { _, _ in adopt() }
        .onChange(of: store.card?.text) { _, _ in adopt() }
    }
    /// Takes the saved card when nothing is being typed (an outside edit never overwrites a draft).
    private func adopt() {
        guard let card = store.card else { return }
        text = Self.adopting(text: text, base: base, saved: card.text)
        base = card.text
    }
    /// An untouched editor takes the saved card; text typed before the card arrived, or while it
    /// changed elsewhere, is kept (and shows "Not saved yet").
    static func adopting(text: String, base: String, saved: String) -> String { text == base ? saved : text }
    private var meter: some View {
        HStack(spacing: 8) {
            ProgressView(value: min(1, Double(total) / Double(max(1, limit))))
                .tint(over > 0 ? DeckTokens.bad : Color.accentColor).frame(width: 160)
            if over > 0 {
                Text("over by \(over.formatted())").font(.callout.weight(.semibold)).foregroundStyle(DeckTokens.bad)
            } else {
                Text("\(total.formatted()) of \(limit.formatted()) characters" + (category == nil ? "" : " (template + own)"))
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

/// The top rules by their short titles; a click shows the whole rule (Asad, 12 Oct).
struct NativeMemoryRuleList: View {
    let rules: [String]
    let titles: [String: String]
    @State private var opened: Set<String> = []
    var body: some View {
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Top rules").font(.callout.weight(.semibold)).padding(.bottom, 4)
                ForEach(rules, id: \.self) { rule in
                    let open = opened.contains(rule)
                    Button {
                        withAnimation(.snappy(duration: 0.16)) { if open { opened.remove(rule) } else { opened.insert(rule) } }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.seal").foregroundStyle(.secondary).font(.caption)
                                Text(DeckMemoryShortTitles.title(forRule: rule, in: titles)).lineLimit(1)
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                            }
                            if open {
                                Text(rule.hasPrefix("- ") || rule.hasPrefix("* ") ? String(rule.dropFirst(2)) : rule)
                                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 22)
                            }
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(DeckMemoryShortTitles.title(forRule: rule, in: titles) + (open ? ", shown whole" : ""))
                }
            }
            .padding(8).background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DeckTokens.hairline))
        }
    }
}

// MARK: Notes

struct NativeMemoryNotesPart: View {
    let store: NativeMemoryStore
    @State private var type: DeckMemoryNoteType?
    @State private var project = ""
    @State private var archived = false
    /// ONE sheet per view (new or an existing note): two sheets hung on one view did not open reliably.
    @State private var sheet: NativeMemorySheetItem<DeckMemoryNote>?
    /// Notes shown whole (Asad, 12 Oct: the list shows the short title; a click shows the whole rule).
    @State private var opened: Set<String> = []

    private var source: [DeckMemoryNote] { archived ? store.archivedNotes : store.notes }
    private var shown: [DeckMemoryNote] {
        source.filter { (type == nil || $0.type == type) && (project.isEmpty || $0.labels.project == project) }
    }
    private var types: [DeckMemoryNoteType] {
        let extra = Set(source.map(\.type)).subtracting(DeckMemoryNoteType.standard).sorted { $0.rawValue < $1.rawValue }
        return DeckMemoryNoteType.standard.filter { t in t != .note || source.contains { $0.type == t } } + extra
    }
    private var projects: [String] { Array(Set(source.compactMap(\.labels.project))).sorted() }

    // M6/M8 (11 Oct): the editor opens IN the part, not as a sheet: the sheet never appeared, even on a real
    // click with the app in front. In place it cannot fail, and Back returns to the list.
    var body: some View {
        if let item = sheet { NativeMemoryNoteSheet(store: store, note: item.value, close: { sheet = nil }).id(item.id) } else { listBody }
    }
    private var listBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        chip("All", source.count, type == nil) { type = nil }
                        ForEach(types, id: \.self) { t in chip(t.title, source.filter { $0.type == t }.count, type == t) { type = t } }
                    }
                }
                if !projects.isEmpty {
                    Picker("Project", selection: $project) {
                        Text("Every project").tag("")
                        ForEach(projects, id: \.self) { DeckRowLabel(store.projectName($0) ?? $0, image: DeckRowIcon.project(id: $0, in: NativePROJLabels.shared.projects)).tag($0) }
                    }.labelsHidden().fixedSize()
                }
                Picker("Show", selection: $archived) { Text("Current").tag(false); Text("Archived").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { sheet = .init(id: "new", value: nil) } label: { Label("New note", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20)
            if shown.isEmpty {
                DeckEmpty(title: archived ? "Nothing archived" : "No notes yet",
                          message: archived ? "Archived and replaced notes are kept here. Nothing is ever deleted." : "The helper writes them after each turn. You can add one too.",
                          symbol: "note.text").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeMemoryColumn {
                    DeckCard(padding: 6) {
                        VStack(spacing: 0) {
                            ForEach(shown) { note in
                                Button {
                                    withAnimation(.snappy(duration: 0.16)) { if opened.contains(note.id) { opened.remove(note.id) } else { opened.insert(note.id) } }
                                } label: { row(note) }.buttonStyle(DeckRowStyle())
                                    .accessibilityLabel(note.listTitle + (opened.contains(note.id) ? ", shown whole" : ""))
                                    .contextMenu {
                                        Button("Open") { sheet = .init(id: note.id, value: note) }
                                        if note.isArchived { Button("Restore") { store.act("restore", done: "Note restored") { _ = try await $0.restoreNote(id: note.id); return nil } } }
                                        else { Button("Archive") { store.act("archive", done: "Note archived") { _ = try await $0.archiveNote(id: note.id, reason: "archived by you", replacedBy: nil); return nil } } }
                                        Button("Show in Finder") { NativeMemoryFolderPart.reveal(note.path) }
                                    }
                                if opened.contains(note.id) { whole(note) }
                            }
                        }
                    }
                }
            }
        }
    }
    /// The whole rule under its short title, with Edit.
    private func whole(_ note: DeckMemoryNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if note.title != note.listTitle { Text(note.title).font(.callout.weight(.semibold)).textSelection(.enabled) }
            if !note.body.isEmpty {
                Text(note.body).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Edit") { sheet = .init(id: note.id, value: note) }.controlSize(.small)
            }
        }
        .padding(.leading, 114).padding(.trailing, 10).padding(.bottom, 8)
    }
    private func chip(_ title: String, _ count: Int, _ on: Bool, _ pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(spacing: 5) { Text(title); Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
                .font(.callout).padding(.horizontal, 10).frame(height: 26)
                .background(on ? DeckTokens.selection : .clear, in: Capsule())
                .overlay(Capsule().strokeBorder(DeckTokens.hairline))
        }.buttonStyle(.plain)
    }
    private func row(_ note: DeckMemoryNote) -> some View {
        HStack(spacing: 10) {
            NativeMemoryTag(text: note.type.title, color: NativeMemoryTag.color(note.type)).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.listTitle).lineLimit(1)
                HStack(spacing: 6) {
                    Text(NativeMemoryStore.day(note.labels.date))
                    if let name = store.projectName(note.labels.project) { Text("·"); if let icon = store.projectIcon(note.labels.project) { Image(nsImage: icon).resizable().frame(width: 13, height: 13) }; Text(name) }
                    if let job = note.labels.job, !job.isEmpty { Text("·"); Text((note.labels.hand.map { "hand \($0) · " } ?? "") + job) }
                    if note.supersedes != nil { Text("·"); Text("replaced an older note") }
                    if let reason = note.archiveReason, note.isArchived { Text("·"); Text(reason) }
                }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(note.source).font(.caption).foregroundStyle(.tertiary)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(opened.contains(note.id) ? 90 : 0))
        }.padding(.horizontal, 8).padding(.vertical, 6)
    }
}

/// Open, edit, archive or restore one note, and see what it replaced.
struct NativeMemoryNoteSheet: View {
    let store: NativeMemoryStore
    let note: DeckMemoryNote?
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismissSheet
    private func dismiss() { if let close { close() } else { dismissSheet() } }
    @State private var title = ""
    @State private var text = ""
    @State private var type: DeckMemoryNoteType = .note
    @State private var history: [DeckMemoryNote] = []
    @State private var viewing: DeckMemoryNote?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(note == nil ? "New note" : note!.isArchived ? "Archived note" : "Note").font(.headline)
                Spacer()
                if let note {
                    Text(NativeMemoryStore.day(note.labels.date) + " · written by " + note.source).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                Picker("Type", selection: $type) {
                    ForEach(DeckMemoryNoteType.standard, id: \.self) { Text($0.title).tag($0) }
                    if !DeckMemoryNoteType.standard.contains(type) { Text(type.title).tag(type) }
                }.labelsHidden().fixedSize()
            }
            TextEditor(text: $text).font(.system(size: 12.5, design: .monospaced))
                .padding(6).background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeckTokens.hairline))
                .frame(minHeight: 200)
            if !history.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replaced these older notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(history) { old in
                        Button { viewing = old } label: {
                            HStack { Text(NativeMemoryStore.day(old.labels.date)).foregroundStyle(.secondary); Text(old.title).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.caption2) }
                                .font(.callout).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                if let note {
                    if note.isArchived {
                        Button("Restore") { if store.act("restore", done: "Note restored", { _ = try await $0.restoreNote(id: note.id); return nil }) { dismiss() } }
                            .disabled(store.busy != nil)
                    } else {
                        Button("Archive") { if store.act("archive", done: "Note archived", { _ = try await $0.archiveNote(id: note.id, reason: "archived by you", replacedBy: nil); return nil }) { dismiss() } }
                            .disabled(store.busy != nil)
                    }
                    Button("Show in Finder") { NativeMemoryFolderPart.reveal(note.path) }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                // Another memory change still running: Save waits (it would be refused and the text lost).
                Button(note == nil ? "Add note" : "Save") { if save() { dismiss() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || note?.isArchived == true || store.busy != nil)
            }
        }
        .padding(20).frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if let note { title = note.title; text = note.body; type = note.type }
            guard let note, !store.fixture else { return }
            Task { history = ((try? await DeckMemory.ready().history(ofNote: note.id)) ?? []).filter { $0.id != note.id } }
        }
        // An older version opens over the editor, in place (no second sheet).
        .overlay {
            if let old = viewing {
                VStack(alignment: .leading, spacing: 10) {
                    Text(old.title).font(.headline)
                    ScrollView { Text(old.body).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    HStack { Spacer(); Button("Done") { viewing = nil }.keyboardShortcut(.defaultAction) }
                }.padding(20).background(DeckTokens.page)
            }
        }
    }
    private func save() -> Bool {
        let t = title, b = text, kind = type, owner = store.owner
        if let note {
            return store.act("note", done: "Note saved") { _ = try await $0.updateNote(id: note.id, title: t, body: b, type: kind); return nil }
        } else {
            return store.act("note", done: "Note added") {
                _ = try await $0.addNote(.init(title: t, body: b, type: kind, stamp: .init(owner: owner, project: owner.projectID), source: "user")); return nil
            }
        }
    }
}

/// What one sheet shows: an existing thing, or nil for a new one.
struct NativeMemorySheetItem<Value>: Identifiable {
    let id: String
    let value: Value?
}

// MARK: Topics

struct NativeMemoryTopicsPart: View {
    let store: NativeMemoryStore
    @State private var sheet: NativeMemorySheetItem<DeckMemoryTopic>?
    // M6/M8 (11 Oct): the editor opens IN the part, not as a sheet: the sheet never appeared, even on a real
    // click with the app in front. In place it cannot fail, and Back returns to the list.
    var body: some View {
        if let item = sheet { NativeMemoryTopicSheet(store: store, topic: item.value, close: { sheet = nil }).id(item.id) } else { listBody }
    }
    private var listBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(store.topics.filter(\.open).count) open").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { sheet = .init(id: "new", value: nil) } label: { Label("New topic", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 20)
            if store.topics.isEmpty {
                DeckEmpty(title: "No topics yet", message: "A topic is the running “where we are” note for something still open.", symbol: "mappin.and.ellipse")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeMemoryColumn {
                    ForEach(store.topics) { topic in
                        DeckCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(topic.title).font(.headline).foregroundStyle(topic.open ? .primary : .secondary)
                                    if let job = topic.job, !job.isEmpty { NativeMemoryTag(text: "job: " + job, color: .blue) }
                                    if !topic.open { NativeMemoryTag(text: "Closed") }
                                    Spacer()
                                    Text("Updated " + NativeMemoryStore.when(topic.updatedAt)).font(.caption).foregroundStyle(.secondary)
                                    Toggle("Open", isOn: Binding(get: { topic.open }, set: { open in
                                        store.act("topic", done: open ? "Topic reopened" : "Topic closed") { _ = try await $0.setTopic(store.owner, id: topic.id, open: open); return nil }
                                    })).toggleStyle(.switch).labelsHidden().help(topic.open ? "Open: it goes on every clean desk" : "Closed: kept, not sent")
                                    Button("Edit") { sheet = .init(id: topic.id, value: topic) }
                                }
                                Text(topic.body).font(.callout).foregroundStyle(.secondary).lineLimit(5).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct NativeMemoryTopicSheet: View {
    let store: NativeMemoryStore
    let topic: DeckMemoryTopic?
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismissSheet
    private func dismiss() { if let close { close() } else { dismissSheet() } }
    @State private var title = ""
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(topic == nil ? "New topic" : "Where we are").font(.headline)
            TextField("Topic", text: $title).textFieldStyle(.roundedBorder).disabled(topic != nil)
            TextEditor(text: $text).font(.system(size: 12.5, design: .monospaced))
                .padding(6).background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeckTokens.hairline))
            HStack {
                if let topic { Button("Show in Finder") { NativeMemoryFolderPart.reveal(topic.path) } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let t = title, b = text, owner = store.owner
                    if store.act("topic", done: "Topic saved", { _ = try await $0.updateTopic(owner, title: t, body: b, stamp: .init(owner: owner, project: owner.projectID)); return nil }) {
                        dismiss()
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || store.busy != nil)
            }
        }
        .padding(20).frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { if let topic { title = topic.title; text = topic.body } }
    }
}
