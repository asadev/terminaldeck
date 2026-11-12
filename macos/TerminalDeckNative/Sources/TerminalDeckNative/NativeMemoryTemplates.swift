import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Opens the Templates screen. The same button (and the same sheet) is used on Hoot's profile,
/// on the Agents page and beside every "shared by all …" part of a seat's memory.
struct NativeMemoryTemplatesButton: View {
    var title = "Templates…"
    var category: DeckMemoryCategory = .agent
    var prominent = false
    @State private var open = false
    var body: some View {
        Group {
            if prominent { NativeSessionButton(title) { open = true }.buttonStyle(.borderedProminent) }
            else { NativeSessionButton(title) { open = true } }
        }
        .help("The three templates: Orchestrator, Lead and Agent. A change applies to everyone in the category.")
        .sheet(isPresented: $open) { NativeMemoryTemplatesView(category: category, onClose: { open = false }) }
    }
}

/// The three category templates, each editable. One template applies to every member of its
/// category now, and to every future hire: nothing here is set per individual.
struct NativeMemoryTemplatesView: View {
    var onClose: () -> Void = {}
    @State private var category: DeckMemoryCategory
    @State private var saved: [DeckMemoryCategory: DeckMemoryTemplate] = [:]
    @State private var draft: [DeckMemoryCategory: DeckMemoryTemplate] = [:]
    @State private var problem: String?
    @State private var status: String?
    @State private var busy = false
    @State private var counts: [DeckMemoryCategory: Int] = [:]
    @State private var confirmClose = false
    private var brain: ROUTINESHootBrainModel { .shared }
    /// Offscreen pictures pass ready templates and never touch the store.
    private let fixture: [DeckMemoryCategory: DeckMemoryTemplate]?

    init(category: DeckMemoryCategory = .agent, onClose: @escaping () -> Void = {}, fixture: [DeckMemoryCategory: DeckMemoryTemplate]? = nil) {
        self.onClose = onClose; self.fixture = fixture
        _category = State(initialValue: category)
        if let fixture { _saved = State(initialValue: fixture); _draft = State(initialValue: fixture) }
    }

    private var dirty: Bool { draft[category] != saved[category] }
    /// Every category with edits not saved yet, including ones on another tab of the window.
    private var unsaved: [DeckMemoryCategory] { Self.unsaved(saved: saved, draft: draft) }
    static func unsaved(saved: [DeckMemoryCategory: DeckMemoryTemplate], draft: [DeckMemoryCategory: DeckMemoryTemplate]) -> [DeckMemoryCategory] {
        DeckMemoryCategory.allCases.filter { draft[$0] != saved[$0] }
    }
    /// "Agent", "Lead and Agent", "Orchestrator, Lead and Agent".
    static func names(_ categories: [DeckMemoryCategory]) -> String {
        let titles = categories.map(\.title)
        guard let last = titles.last else { return "" }
        return titles.count == 1 ? last : titles.dropLast().joined(separator: ", ") + " and " + last
    }
    static func closeWarning(_ categories: [DeckMemoryCategory]) -> String {
        "Changes to the \(names(categories)) template\(categories.count == 1 ? " are" : "s are") not saved yet. Closing throws them away."
    }
    private func bind<T>(_ path: WritableKeyPath<DeckMemoryTemplate, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { draft[category]?[keyPath: path] ?? fallback }, set: { draft[category]?[keyPath: path] = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Templates").font(.system(size: 17, weight: .semibold))
                Spacer()
                GlassSwitch(selection: $category, items: DeckMemoryCategory.allCases.map { .init(id: $0, title: $0.title, symbol: $0 == .orchestrator ? "bird" : $0 == .lead ? "person.2" : "person") })
                Spacer()
                // Done and Escape never throw away an unsaved edit silently, even one on another tab.
                NativeSessionButton("Done") { if unsaved.isEmpty { onClose() } else { confirmClose = true } }.keyboardShortcut(.cancelAction).disabled(busy)
            }.padding(.horizontal, 20).padding(.vertical, 12)
            HStack(spacing: 8) {
                Image(systemName: "person.3.fill").foregroundStyle(Color.accentColor)
                Text(applies).font(.callout)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 36)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            if draft[category] == nil {
                VStack(spacing: 8) {
                    if let problem { Text(problem).foregroundStyle(.secondary) } else { ProgressView().controlSize(.small); Text("Memory is starting…").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Shared card").font(.headline)
                        Text("Rules, the report form and how to use memory. It comes first in every \(category.title.lowercased()) seat's card.").font(.caption).foregroundStyle(.secondary)
                        editor(bind(\.card, "")).frame(height: 230)
                        Text("\((draft[category]?.card.count ?? 0).formatted()) characters of the \((draft[category]?.cardLimit ?? 0).formatted()) a whole card may be")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Helper checklist").font(.headline).padding(.top, 6)
                        Text("What the helper looks for when it writes notes. Your corrections are added here.").font(.caption).foregroundStyle(.secondary)
                        editor(bind(\.checklist, "")).frame(height: 170)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 12) { settings }.frame(width: 290)
                }.padding(20)
                }
            }
            Divider()
            HStack(spacing: 10) {
                if let line = problem ?? status { Text(line).font(.callout).foregroundStyle(problem == nil ? Color.secondary : DeckTokens.warn).lineLimit(2) }
                else if !unsaved.isEmpty {
                    Text(unsaved == [category] ? "Not saved yet" : "Not saved yet: \(Self.names(unsaved))").font(.callout).foregroundStyle(DeckTokens.warn)
                }
                Spacer()
                NativeSessionButton("Revert") { draft[category] = saved[category] }.disabled(!dirty || busy)
                NativeSessionButton(busy ? "Saving…" : "Save for \(category.everyone)") { save() }
                    .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command).disabled(!dirty || busy)
            }.padding(.horizontal, 20).frame(height: 48)
        }
        .frame(width: 900, height: 640)
        .background(DeckTokens.page)
        .interactiveDismissDisabled(!unsaved.isEmpty)
        .confirmationDialog("Close without saving?", isPresented: $confirmClose) {
            NativeSessionButton("Close Without Saving", role: .destructive) { onClose() }
            // Back to the window, on the tab that holds the unsaved edit.
            NativeSessionButton("Keep Editing", role: .cancel) { if !unsaved.contains(category), let first = unsaved.first { category = first } }
        } message: { Text(Self.closeWarning(unsaved)) }
        .task { await load() }
    }

    private var applies: String {
        let n = counts[category]
        if category == .orchestrator { return "This template applies to Hoot, the one Orchestrator." }
        let today = n.map { " (\($0) seat\($0 == 1 ? "" : "s") today)" } ?? ""
        return "A change here applies to \(category.everyone) at once\(today) and to every future hire. Nothing is set per person."
    }

    private func editor(_ text: Binding<String>) -> some View {
        NativeSessionTextEditor(text: text).font(.system(size: 12.5, design: .monospaced)).scrollContentBackground(.hidden)
            .padding(8).background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeckTokens.hairline))
    }

    @ViewBuilder private var settings: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Memory parts").font(.headline)
                Text("What every \(category.title.lowercased()) seat gets.").font(.caption).foregroundStyle(.secondary)
                // FINAL-CONNECT (row 95): only parts a seat really goes without when off. Notes and the diary
                // are always kept (switching them off only hid a tab), so they have no switch.
                ForEach(DeckMemoryPart.allCases.filter { ![.notes, .diary].contains($0) }, id: \.self) { part in
                    HStack {
                        Text(part.title)
                        Spacer()
                        Toggle(part.title, isOn: Binding(get: { draft[category]?.parts.contains(part) ?? false }, set: { on in
                            if on { draft[category]?.parts.insert(part) } else { draft[category]?.parts.remove(part) }
                        })).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    }
                    .disabled(part == .playbook && category == .agent)
                    .help(part == .playbook && category == .agent ? "Only the Orchestrator and Leads keep a playbook" : part.title)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        DeckCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Helper").font(.headline)
                let ai = draft[category]?.helperAI ?? "claude"
                Picker("AI", selection: Binding(get: { ai }, set: { draft[category]?.helperAI = $0; draft[category]?.helperModel = "" })) {
                    ForEach(NativeMemoryPlaybookPart.ais, id: \.0) { DeckRowLabel.provider($0.1, id: $0.0).tag($0.0) }
                }.pickerStyle(.segmented).labelsHidden()
                let list = brain.catalogs[ai] ?? [], model = draft[category]?.helperModel ?? ""
                Picker("Model", selection: bind(\.helperModel, "")) {
                    Text("That AI's small model").tag("")
                    ForEach(list, id: \.id) { Text($0.name).tag($0.id) }
                    if !model.isEmpty, !list.contains(where: { $0.id == model }) { Text(model).tag(model) }
                }.labelsHidden()
                Divider()
                Stepper("Card limit \((draft[category]?.cardLimit ?? 6000).formatted())", value: bind(\.cardLimit, 6000), in: 1000...20000, step: 500)
                Text("Template plus the seat's own part. The app warns; it never cuts.").font(.caption).foregroundStyle(.secondary)
                if category == .agent {
                    Divider()
                    Stepper("Sessions on one seat at once: \(draft[category]?.handsPerSeat ?? 3)", value: bind(\.handsPerSeat, 3), in: 1...12)
                    Stepper("Agent sessions per project: \(draft[category]?.handsPerProject ?? 12)", value: bind(\.handsPerProject, 12), in: 1...60)
                    Text("Several sessions can work one role at the same time; they share the role's memory.").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func load() async {
        guard fixture == nil else { return }
        brain.load()
        do {
            let memory = await DeckMemory.ready()
            for each in DeckMemoryCategory.allCases {
                let template = try await memory.template(each)
                saved[each] = template
                if draft[each] == nil { draft[each] = template }
            }
            let owners = try await memory.owners()
            for each in DeckMemoryCategory.allCases { counts[each] = owners.filter { $0.owner.category == each }.count }
        } catch { problem = error.localizedDescription }
    }
    private func save() {
        guard fixture == nil, let next = draft[category] else { return }
        busy = true; problem = nil; status = nil
        let which = category
        Task {
            defer { busy = false }
            do {
                let stored = try await DeckMemory.ready().saveTemplate(next)
                saved[which] = stored; draft[which] = stored
                status = "Saved for \(which.everyone)."
            } catch { problem = error.localizedDescription }
        }
    }
}
