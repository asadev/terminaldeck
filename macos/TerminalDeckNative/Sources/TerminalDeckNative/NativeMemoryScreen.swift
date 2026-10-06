import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Memory, drawn in Swift — src/renderer/memory/MemoryPage.tsx one for one: the
/// memories on the left grouped by whose they are, search (this memory / every
/// memory), notes or graph, and an open note with its editor, links, backlinks and
/// who wrote it — on the page's `memory:*` channels and its `memory:changed` event.
struct NativeMemoryScreen: View {
    @State private var model = MemoryScreenModel()

    var body: some View {
        MemoryBody(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(.background)
            .task { model.start(projectPath: DeckProject.current) }
            .onDisappear { model.stop() }
    }
}

// MARK: - Model

@MainActor
@Observable
final class MemoryScreenModel {
    enum Spaces: Equatable { case loading, failed, loaded([MemorySpace]) }
    enum Mode: String { case notes, graph }
    enum Provenance: Equatable { case none, reading, answer(MemoryAnswer<MemoryProvenance>) }
    struct Open: Equatable { var spaceId: String; var path: String }
    struct Message: Equatable { var text: String; var ok: Bool }

    private(set) var spaces: Spaces = .loading
    private(set) var selectedId: String?
    /// nil while it is being read.
    private(set) var notes: MemoryAnswer<MemoryNotes>?
    private(set) var mode: Mode = .notes
    private(set) var query = ""
    private(set) var everywhere = false
    /// nil while searching.
    private(set) var hits: [MemoryHit]?
    private(set) var open: Open?
    private(set) var read: MemoryAnswer<MemoryRead>?
    private(set) var provenance: Provenance = .none
    private(set) var busy = false
    private(set) var message: Message?

    @ObservationIgnored private var projectPath: String?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var changed: EngineSubscription?
    @ObservationIgnored private var notesRun = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    var spaceList: [MemorySpace] {
        if case .loaded(let list) = spaces { return list }
        return []
    }

    var selected: MemorySpace? { spaceList.first { $0.id == selectedId } }

    func start(projectPath: String?) {
        guard !started else { return }
        started = true
        self.projectPath = projectPath
        changed = EngineBridge.shared.on(MemoryWire.changed) { [weak self] args in
            guard let self, let id = args.first as? String, id == self.selectedId else { return }
            self.changesHappened()
        }
        Task { await loadSpaces(refresh: false) }
    }

    func stop() {
        changed?.cancel()
        changed = nil
        searchTask?.cancel()
    }

    private func call(_ channel: String, _ args: [Any?]) async throws -> Any {
        try await EngineBridge.shared.invoke(channel, args)
    }

    func loadSpaces(refresh: Bool) async {
        do {
            let found = MemoryWire.spaces(try await call(MemoryWire.spaces, [refresh]))
            spaces = .loaded(found)
            let current = selectedId
            let next = current != nil && found.contains(where: { $0.id == current })
                ? current : MemoryRules.firstSpace(found, projectPath: projectPath)?.id
            if next != selectedId {
                selectedId = next
                loadNotes()
            } else if notes == nil {
                loadNotes()
            }
        } catch {
            spaces = .failed
        }
        scheduleSearch()
    }

    private func loadNotes() {
        guard let id = selectedId else { return }
        notesRun += 1
        let run = notesRun
        Task {
            let answer: MemoryAnswer<MemoryNotes>
            do {
                answer = MemoryWire.notes(try await call(MemoryWire.notes, [id]))
            } catch {
                answer = .failed(deckMessage(error))
            }
            guard run == notesRun, id == selectedId else { return }
            notes = answer
        }
    }

    /// Something changed on disk (or Look again): read the notes and the search again.
    private func changesHappened() {
        loadNotes()
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty {
            hits = nil
            return
        }
        let ids = everywhere ? spaceList.map(\.id) : (selectedId.map { [$0] } ?? [])
        searchTask = Task {
            try? await Task.sleep(for: MemoryRules.searchDelay)
            guard !Task.isCancelled else { return }
            let found: [MemoryHit]
            do {
                found = MemoryWire.hits(try await call(MemoryWire.search, [words, ids]))
            } catch {
                found = []
            }
            guard !Task.isCancelled else { return }
            hits = found
        }
    }

    private func readNote(_ spaceId: String, _ path: String) async {
        let answer: MemoryAnswer<MemoryRead>
        do {
            answer = MemoryWire.read(try await call(MemoryWire.read, [spaceId, path]))
        } catch {
            answer = .failed(deckMessage(error))
        }
        guard open == Open(spaceId: spaceId, path: path) else { return }
        read = answer
    }

    // MARK: Actions (MemoryActions)

    func selectSpace(_ id: String) {
        selectedId = id
        notes = nil
        open = nil
        read = nil
        message = nil
        loadNotes()
        scheduleSearch()
    }

    func setMode(_ next: Mode) {
        mode = next
        if next == .graph { open = nil }
    }

    func setQuery(_ text: String) {
        // The last hits stay up while the next search runs, as on the page.
        query = text
        scheduleSearch()
    }

    func setEverywhere(_ on: Bool) {
        everywhere = on
        scheduleSearch()
    }

    func openNote(_ spaceId: String, _ path: String) {
        if spaceId != selectedId {
            selectedId = spaceId
            notes = nil
            loadNotes()
        }
        mode = .notes
        open = Open(spaceId: spaceId, path: path)
        read = nil
        provenance = .none
        message = nil
        Task { await readNote(spaceId, path) }
    }

    func closeNote() {
        open = nil
        read = nil
        provenance = .none
        message = nil
    }

    func save(_ text: String) {
        guard let open, case .ok(let current)? = read else { return }
        busy = true
        Task {
            do {
                let answer = MemoryWire.change(try await call(MemoryWire.save, [open.spaceId, open.path, text, current.version.wire]))
                switch answer {
                case .ok:
                    message = Message(text: "Saved.", ok: true)
                    await readNote(open.spaceId, open.path)
                case .failed(let why):
                    message = Message(text: why, ok: false)
                }
            } catch {
                message = Message(text: deckMessage(error), ok: false)
            }
            busy = false
        }
    }

    func remove(indexLine: Bool) {
        guard let open else { return }
        busy = true
        Task {
            do {
                let answer = MemoryWire.change(try await call(MemoryWire.delete, [open.spaceId, open.path, indexLine]))
                switch answer {
                case .ok(let change):
                    self.open = nil
                    read = nil
                    message = Message(text: MemoryRules.deletedMessage(indexLineRemoved: change.indexLineRemoved), ok: true)
                    changesHappened()
                case .failed(let why):
                    message = Message(text: why, ok: false)
                }
            } catch {
                message = Message(text: deckMessage(error), ok: false)
            }
            busy = false
        }
    }

    func askProvenance() {
        guard let open else { return }
        provenance = .reading
        Task {
            let answer: MemoryAnswer<MemoryProvenance>
            do {
                answer = MemoryWire.provenance(try await call(MemoryWire.provenance, [open.spaceId, open.path]))
            } catch {
                answer = .failed(deckMessage(error))
            }
            guard self.open == open else { return }
            provenance = .answer(answer)
        }
    }

    func refresh() {
        Task { await loadSpaces(refresh: true) }
        changesHappened()
    }
}

// MARK: - The page (MemoryPageBody)

private struct MemoryBody: View {
    let model: MemoryScreenModel

    var body: some View {
        switch model.spaces {
        case .loading:
            Color.clear
        case .failed:
            DeckPageEmpty(symbol: "brain.head.profile", title: "Memory could not be read",
                          message: "Terminal Deck did not answer. Reopen this page in a moment.")
        case .loaded(let spaces) where spaces.isEmpty:
            DeckPageEmpty(symbol: "brain.head.profile", title: "No agent has kept memory on this machine yet",
                          message: "Notes appear here once Claude Code, Codex or Hoot remembers something.",
                          actionLabel: "Look again", primary: false, action: model.refresh)
        case .loaded(let spaces):
            HStack(alignment: .top, spacing: 0) {
                SpaceList(model: model, spaces: spaces)
                    .frame(width: 260)
                    .padding(.leading, 36)
                    .padding(.top, 16)
                VStack(alignment: .leading, spacing: 14) {
                    MemoryTools(model: model)
                    MemoryMainPane(model: model)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

private struct MemoryTools: View {
    let model: MemoryScreenModel

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.everywhere ? "Search every memory…" : "Search this memory…",
                          text: Binding(get: { model.query }, set: { model.setQuery($0) }))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Search memory")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 8))
            .frame(maxWidth: 300)

            Picker("Where to search", selection: Binding(get: { model.everywhere }, set: { model.setEverywhere($0) })) {
                Text("This memory").tag(false)
                Text("Every memory").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Show", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Text("Notes").tag(MemoryScreenModel.Mode.notes)
                Text("Graph").tag(MemoryScreenModel.Mode.graph)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
        }
    }
}

private struct SpaceList: View {
    let model: MemoryScreenModel
    let spaces: [MemorySpace]

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedId }, set: { if let id = $0 { model.selectSpace(id) } })) {
                ForEach(MemoryRules.groups(spaces), id: \.kind) { group in
                    Section(MemoryRules.kindTitle(group.kind)) {
                        ForEach(group.spaces) { space in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(space.label).lineLimit(1).truncationMode(.tail)
                                if let place = MemoryRules.place(space) {
                                    Text(place).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                                if let shared = MemoryRules.sharedLine(space) {
                                    Text(shared).font(.caption).foregroundStyle(.secondary)
                                        .help(space.sharedWith.joined(separator: "\n"))
                                }
                            }
                            .padding(.vertical, 2)
                            .help(space.root)
                            .tag(space.id as String?)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Memories")
            Divider()
            HStack {
                Button("Look again", action: model.refresh)
                    .help("Find memory folders made since this page opened")
                Spacer()
            }
            .padding(10)
        }
    }
}

// MARK: Main pane

private struct MemoryMainPane: View {
    let model: MemoryScreenModel

    var body: some View {
        if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.open == nil {
            MemorySearchResults(model: model)
        } else if let selected = model.selected {
            if let open = model.open {
                NoteView(model: model, space: selected)
                    .id("\(open.spaceId)/\(open.path)")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SpaceHead(space: selected)
                        if let message = model.message { MessageLine(message: message) }
                        switch model.notes {
                        case nil:
                            MemoryQuiet("Reading…")
                        case .failed(let why)?:
                            ProblemLine(text: why)
                        case .ok(let found)?:
                            if model.mode == .graph {
                                GraphView(notes: found.notes, graph: found.graph) { model.openNote(selected.id, $0) }
                            } else {
                                NoteList(notes: found.notes, dangling: found.graph.dangling.count,
                                         open: { model.openNote(selected.id, $0) }, graph: { model.setMode(.graph) })
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
                }
            }
        } else {
            MemoryQuiet("Choose a memory on the left.")
        }
    }
}

private struct MemoryQuiet: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
}

private struct ProblemLine: View {
    let text: String
    var body: some View { Text(text).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
}

private struct MessageLine: View {
    let message: MemoryScreenModel.Message
    var body: some View {
        Text(message.text).font(.callout).foregroundStyle(message.ok ? Color.green : Color.red).textSelection(.enabled)
    }
}

private struct MemorySectionHead: View {
    let title: String
    var body: some View { Text(title).font(.system(size: 14, weight: .semibold)).padding(.top, 6) }
}

private struct SpaceHead: View {
    let space: MemorySpace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(space.label).font(.system(size: 18, weight: .semibold))
            Text(space.root).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            if let shared = MemoryRules.sharedLine(space) {
                Text("\(shared), through a link that is already on disk: \(space.sharedWith.joined(separator: ", ")). Notes written from any of them land here.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if space.accounts.count > 1 {
                MemoryQuiet("Read by the accounts \(space.accounts.joined(separator: ", ")).")
            }
        }
        .textSelection(.enabled)
    }
}

private struct LabelsView: View {
    let note: MemoryNoteRow
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(MemoryRules.labels(note).enumerated()), id: \.offset) { _, label in
                Text(MemoryRules.labelText(label))
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary.opacity(0.7), in: .capsule)
                    .help(label.key)
            }
        }
    }
}

/// One note row: title, labels and date; description; path.
private struct NoteRowButton: View {
    let title: String
    let trailing: String
    let description: String?
    let path: String
    var note: MemoryNoteRow?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.callout.weight(.medium))
                    if let note { LabelsView(note: note) }
                    Spacer(minLength: 8)
                    Text(trailing).font(.caption).foregroundStyle(.secondary)
                }
                if let description { Text(description).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading) }
                Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(MemoryRowStyle())
    }
}

private struct MemoryRowStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.primary.opacity(0.1) : hover ? Color.primary.opacity(0.05) : .clear,
                        in: .rect(cornerRadius: 8))
            .onHover { hover = $0 }
    }
}

private struct NoteList: View {
    let notes: [MemoryNoteRow]
    let dangling: Int
    let open: (String) -> Void
    let graph: () -> Void

    var body: some View {
        if notes.isEmpty {
            MemoryQuiet("No notes in this memory.")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes) { note in
                    NoteRowButton(title: note.title, trailing: MemoryRules.dateOf(note.modifiedAt), description: note.description,
                                  path: note.path, note: note) { open(note.path) }
                }
            }
            if dangling > 0 {
                HStack(spacing: 4) {
                    MemoryQuiet(MemoryRules.danglingLine(dangling))
                    Button("See which", action: graph).buttonStyle(.link)
                }
            }
        }
    }
}

private struct MemorySearchResults: View {
    let model: MemoryScreenModel

    var body: some View {
        if let hits = model.hits {
            if hits.isEmpty {
                MemoryQuiet("Nothing matches.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                            NoteRowButton(title: hit.title, trailing: MemoryRules.hitSource(hit, spaces: model.spaceList),
                                          description: hit.snippet, path: hit.path) { model.openNote(hit.spaceId, hit.path) }
                        }
                    }
                    .accessibilityLabel("Search results")
                }
            }
        } else {
            MemoryQuiet("Searching…")
        }
    }
}

// MARK: An open note

private struct NoteView: View {
    let model: MemoryScreenModel
    let space: MemorySpace
    @State private var confirming = false
    @State private var indexLine = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button("All notes", action: model.closeNote)
                switch model.read {
                case nil:
                    MemoryQuiet("Reading…")
                case .failed(let why)?:
                    ProblemLine(text: why)
                case .ok(let note)?:
                    opened(note)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder
    private func opened(_ note: MemoryRead) -> some View {
        let linked = note.links.filter { $0.to != nil }
        let nowhere = note.links.filter { $0.to == nil }
        VStack(alignment: .leading, spacing: 4) {
            Text(note.note.title).font(.system(size: 18, weight: .semibold))
            Text("\(space.label) · \(note.path)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            LabelsView(note: note.note)
            if let description = note.note.description { Text(description).font(.callout) }
        }
        .textSelection(.enabled)

        NativeFileEditor(label: note.note.title, text: note.text, problem: nil, effect: MemoryRules.saveEffect(space.kind),
                         saveBecause: note.truncated ? MemoryRules.saveBecause(truncated: true, dirty: true) : nil,
                         saving: model.busy, note: model.message.map { (text: $0.text, ok: $0.ok) }, onSave: model.save) {
            if !confirming {
                Button("Move to Trash", role: .destructive) { confirming = true }
                    .disabled(model.busy)
            }
        }

        if confirming {
            VStack(alignment: .leading, spacing: 8) {
                Text("Move “\(note.note.title)” to the Trash? You can put it back from the Trash.").font(.callout)
                if note.indexed {
                    Toggle("Also take its line out of MEMORY.md", isOn: $indexLine).toggleStyle(.checkbox)
                }
                HStack(spacing: 8) {
                    Button("Move to Trash", role: .destructive) { model.remove(indexLine: note.indexed && indexLine) }
                        .disabled(model.busy)
                    Button("Keep it") { confirming = false }.disabled(model.busy)
                }
            }
            .padding(12)
            .background(.red.opacity(0.07), in: .rect(cornerRadius: 8))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Move this note to the Trash")
        }

        VStack(alignment: .leading, spacing: 6) {
            MemorySectionHead(title: "Links")
            if linked.isEmpty && nowhere.isEmpty {
                MemoryQuiet("This note links to no other note.")
            } else {
                ForEach(Array(linked.enumerated()), id: \.offset) { _, link in
                    Button(link.to ?? "") { model.openNote(space.id, link.to ?? "") }.buttonStyle(.link)
                }
                ForEach(Array(nowhere.enumerated()), id: \.offset) { _, link in
                    Text("\(link.target)\(Text(" — reaches no note").foregroundStyle(.secondary))").font(.callout)
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            MemorySectionHead(title: "Linked from")
            if note.backlinks.isEmpty {
                MemoryQuiet("No note links here.")
            } else {
                ForEach(note.backlinks, id: \.self) { path in
                    Button(path) { model.openNote(space.id, path) }.buttonStyle(.link)
                }
            }
        }

        if space.kind == .claudeProject { ProvenanceView(model: model) }
    }
}

private struct ProvenanceView: View {
    let model: MemoryScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MemorySectionHead(title: "Written by")
            switch model.provenance {
            case .none:
                Button("Find the conversations that wrote it", action: model.askProvenance)
                    .help("Reads this folder’s recent conversations for the calls that wrote this note")
            case .reading:
                MemoryQuiet("Reading this folder’s conversations…")
            case .answer(.failed(let why)):
                ProblemLine(text: why)
            case .answer(.ok(let found)):
                if found.writes.isEmpty {
                    MemoryQuiet("None of the conversations read wrote this note.")
                } else {
                    ForEach(Array(found.writes.enumerated()), id: \.offset) { _, write in
                        HStack(spacing: 10) {
                            Text(MemoryRules.dateOf(write.at)).foregroundStyle(.secondary)
                            Text(MemoryRules.writeLine(write))
                            Text(write.folder).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .font(.callout)
                    }
                }
                MemoryQuiet(MemoryRules.readLine(found))
            }
        }
    }
}

// MARK: Graph

private struct GraphView: View {
    let notes: [MemoryNoteRow]
    let graph: MemoryGraph
    let open: (String) -> Void
    @State private var positions: [String: (x: Double, y: Double)] = [:]
    @State private var laidOut: MemoryGraph?

    var body: some View {
        let titles = Dictionary(notes.map { ($0.path, $0.title) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 14) {
            if graph.nodes.isEmpty {
                MemoryQuiet("No notes to draw.")
            } else {
                picture(titles)
            }
            VStack(alignment: .leading, spacing: 6) {
                MemorySectionHead(title: "Links that reach no note")
                if graph.dangling.isEmpty {
                    MemoryQuiet("Every link reaches a note.")
                } else {
                    ForEach(Array(graph.dangling.enumerated()), id: \.offset) { _, link in
                        HStack(spacing: 4) {
                            Button(titles[link.from] ?? link.from) { open(link.from) }.buttonStyle(.link)
                            Text("links to").foregroundStyle(.secondary)
                            Text(link.target)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .task(id: graph) {
            guard laidOut != graph else { return }
            let nodes = graph.nodes, edges = graph.edges
            let placed = await Task.detached {
                MemoryRules.layout(nodes: nodes, edges: edges, width: MemoryRules.graphWidth, height: MemoryRules.graphHeight, margin: 32)
                    .mapValues { [$0.x, $0.y] }
            }.value
            positions = placed.mapValues { ($0[0], $0[1]) }
            laidOut = graph
        }
    }

    @ViewBuilder
    private func picture(_ titles: [String: String]) -> some View {
        let degree = MemoryRules.degrees(graph)
        let labelled = graph.nodes.count <= MemoryRules.labelLimit
        GeometryReader { geometry in
            let scale = geometry.size.width / MemoryRules.graphWidth
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    var path = Path()
                    for edge in graph.edges {
                        guard let a = positions[edge.from], let b = positions[edge.to] else { continue }
                        path.move(to: CGPoint(x: a.x * scale, y: a.y * scale))
                        path.addLine(to: CGPoint(x: b.x * scale, y: b.y * scale))
                    }
                    context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1)
                }
                ForEach(graph.nodes, id: \.self) { node in
                    if let at = positions[node] {
                        let title = titles[node] ?? node
                        let r = MemoryRules.radius(degree: degree[node] ?? 0)
                        let right = at.x > MemoryRules.graphWidth / 2
                        Button { open(node) } label: {
                            Circle().fill(Color.accentColor).frame(width: r * 2, height: r * 2)
                        }
                        .buttonStyle(.plain)
                        .help(title)
                        .accessibilityLabel("Open \(title)")
                        .position(x: at.x * scale, y: at.y * scale)
                        if labelled {
                            Text(title)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: 0, alignment: right ? .trailing : .leading)
                                .offset(x: right ? -(r + 4) : r + 4)
                                .position(x: at.x * scale, y: at.y * scale)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .aspectRatio(MemoryRules.graphWidth / MemoryRules.graphHeight, contentMode: .fit)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How the notes link")
    }
}
