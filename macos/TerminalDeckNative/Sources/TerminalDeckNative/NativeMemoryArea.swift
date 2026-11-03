import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The parts of an owner's memory. The left list shows the ones this owner has.
enum NativeMemoryPart: String, CaseIterable, Identifiable {
    case card, notes, diary, topics, playbook, board, helper, tidy, folder
    var id: String { rawValue }
    var title: String {
        switch self {
        case .card: "Card"; case .notes: "Notes"; case .diary: "Diary"; case .topics: "Topics"; case .playbook: "Playbook"
        case .board: "Board"; case .helper: "Helper"; case .tidy: "Tidy-up"; case .folder: "Folder"
        }
    }
    var symbol: String {
        switch self {
        case .card: "person.text.rectangle"; case .notes: "note.text"; case .diary: "book.closed"; case .topics: "mappin.and.ellipse"
        case .playbook: "tablecells"; case .board: "rectangle.3.group"
        case .helper: "wand.and.stars"; case .tidy: "sparkles"; case .folder: "folder"
        }
    }
    var blurb: String {
        switch self {
        case .card: "Who you are, the rules, one line per project. Given in full at the start of every desk."
        case .notes: "Decisions, preferences, corrections, results and open items, written as they happen."
        case .diary: "Every message in and out, word for word. Search by words or by meaning."
        case .topics: "The running “where we are” note for each open topic."
        case .playbook: "For each kind of job: which AI, model, effort and permission, and the standing instructions."
        case .board: "What every project, session, agent and task is doing, and what waits for you."
        case .helper: "The small AI job that writes the notes after each turn."
        case .tidy: "The nightly job that merges duplicates and asks you when it is unsure."
        case .folder: "Where this memory lives on your Mac."
        }
    }
    static func parts(for owner: DeckMemoryOwner) -> [NativeMemoryPart] {
        allCases.filter { $0 != .playbook || owner.hasPlaybook }
    }
    /// The part of a category template that switches this on. Tidy-up and Folder are always there.
    var templatePart: DeckMemoryPart? {
        switch self {
        case .card: .card; case .notes: .notes; case .diary: .diary; case .topics: .topics; case .playbook: .playbook
        case .board: .board; case .helper: .helper; case .tidy, .folder: nil
        }
    }
}

/// The Memory area of a profile: a seat's whole memory, visible and editable in place.
/// ONE view for all three categories (Orchestrator, Lead, Agent): which parts show comes from the
/// category template. Memory belongs to the seat, so a vacant seat still shows everything.
/// Give it the full tab area: it has its own left list and its own scrolling.
struct NativeMemoryArea: View {
    let owner: DeckMemoryOwner
    /// An optional narrowing by the host; the category template decides the rest.
    let allowed: [NativeMemoryPart]
    let name: String?
    /// Who sits in this seat now; nil = vacant (the memory stays).
    let filledBy: String?
    private let fixtureStore: NativeMemoryStore?
    @SceneStorage("NativeMemory.part") private var remembered = "card"
    @State private var fixturePart: String

    init(owner: DeckMemoryOwner, parts: [NativeMemoryPart]? = nil, name: String? = nil, filledBy: String? = nil,
         fixture: NativeMemoryStore? = nil, part: NativeMemoryPart = .card) {
        self.owner = owner; self.name = name; self.filledBy = filledBy; fixtureStore = fixture
        allowed = parts ?? NativeMemoryPart.allCases
        _fixturePart = State(initialValue: part.rawValue)
    }
    /// For hosts that hold the seat as a key ("hoot", "lead:<project>", "role:<project>/<role>").
    init(ownerKey: String, name: String? = nil, filledBy: String? = nil) {
        self.init(owner: DeckMemoryOwner(ownerKey) ?? .hoot, name: name, filledBy: filledBy)
    }
    /// The same, narrowed to some part ids.
    init(ownerKey: String, parts: [String], name: String? = nil, filledBy: String? = nil) {
        self.init(owner: DeckMemoryOwner(ownerKey) ?? .hoot, parts: parts.compactMap(NativeMemoryPart.init(rawValue:)), name: name, filledBy: filledBy)
    }
    /// What this seat shows: the host's narrowing, then what its category template switches on.
    private var parts: [NativeMemoryPart] {
        NativeMemoryPart.allCases.filter { part in
            guard allowed.contains(part), part != .playbook || owner.hasPlaybook else { return false }
            guard let template = store.template, let needs = part.templatePart else { return true }
            return template.parts.contains(needs)
        }
    }
    /// "Agent seat · iMatch · iOS · filled by Sam" / "… · vacant, memory kept".
    private var seatLine: String {
        var words: [String] = [owner.category.map { $0.title + " seat" } ?? "Project memory"]
        // M4b: the seat says its project once and its role by the role's own name ("CRM · Database engineer"),
        // never the host's composed name ("Crm db on CRM on CRM") or the slug.
        if owner == .hoot || owner.category == nil {
            if let name, !name.isEmpty { words.append(name) }
        } else {
            if let project = store.projectName(owner.projectID) { words.append(project) }
            if owner.roleID != nil {
                let row = AGTLeads.roster().first { $0.seat.owner == owner }
                words.append(row?.title ?? owner.roleID.map { AGTSeats.title(forRole: $0) } ?? "")
            }
        }
        if owner.category != nil, owner != .hoot { words.append(filledBy.map { "filled by " + $0 } ?? "vacant, memory kept") }
        return words.joined(separator: " · ")
    }

    private var store: NativeMemoryStore { fixtureStore ?? .of(owner) }
    private var selected: NativeMemoryPart {
        NativeMemoryPart(rawValue: fixtureStore == nil ? remembered : fixturePart).flatMap { parts.contains($0) ? $0 : nil } ?? parts.first ?? .card
    }
    private func select(_ part: NativeMemoryPart) { if fixtureStore == nil { remembered = part.rawValue } else { fixturePart = part.rawValue } }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 188)
            Rectangle().fill(DeckTokens.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(DeckTokens.page)
        .onAppear { store.start() }
        .onDisappear { store.stop() }
        .onChange(of: owner) { old, _ in
            guard fixtureStore == nil else { return }
            NativeMemoryStore.stop(old); store.start()
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(parts) { part in
                    Button { select(part) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: part.symbol).frame(width: 18).foregroundStyle(selected == part ? Color.accentColor : .secondary)
                            Text(part.title)
                            Spacer(minLength: 4)
                            if let count = count(part) { Text(count).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(selected == part ? DeckTokens.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(part.blurb)
                }
            }.padding(10)
        }
    }
    private func count(_ part: NativeMemoryPart) -> String? {
        switch part {
        case .card: return store.card.map { $0.overBy > 0 ? "over" : nil } ?? nil
        case .notes: return store.notes.isEmpty ? nil : "\(store.notes.count)"
        case .topics: let open = store.topics.filter(\.open).count; return open == 0 ? nil : "\(open)"
        case .board: let waiting = store.board.filter(\.isWaiting).count; return waiting == 0 ? nil : "\(waiting) wait"
        case .tidy: let open = store.questions.filter { $0.isOpen && ($0.owner == owner || owner == .hoot) }.count; return open == 0 ? nil : "\(open)"
        case .playbook: return store.playbook.map { $0.rows.isEmpty ? nil : "\($0.rows.count)" } ?? nil
        default: return nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: owner.category == .agent && filledBy == nil ? "chair" : "chair.fill").font(.caption).foregroundStyle(.secondary)
                Text(seatLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(selected.title).font(.system(size: 17, weight: .semibold))
            Text(selected.blurb).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var detail: some View {
        switch selected {
        case .card: NativeMemoryCardPart(store: store)
        case .notes: NativeMemoryNotesPart(store: store)
        case .diary: NativeMemoryDiaryPart(store: store, open: select)
        case .topics: NativeMemoryTopicsPart(store: store)
        case .playbook: NativeMemoryPlaybookPart(store: store)
        case .board: NativeMemoryBoardPart(store: store)
        case .helper: NativeMemoryHelperPart(store: store)
        case .tidy: NativeMemoryTidyPart(store: store)
        case .folder: NativeMemoryFolderPart(store: store)
        }
    }

    @ViewBuilder private var footer: some View {
        if let line = store.problem ?? store.status {
            HStack(spacing: 6) {
                Image(systemName: store.problem == nil ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(store.problem == nil ? DeckTokens.good : DeckTokens.warn)
                Text(line).font(.callout).lineLimit(2)
                Spacer()
                Button("Dismiss") { store.problem = nil; store.status = nil }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 20).frame(height: 34)
            .background(DeckTokens.card)
        }
    }
}

/// A scrolling column for a part, at reading width.
struct NativeMemoryColumn<Content: View>: View {
    var width: CGFloat = 820
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) { content() }
                .frame(maxWidth: width, alignment: .leading)
                .padding(.horizontal, 20).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A small coloured word: note types and board result states.
struct NativeMemoryTag: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).frame(height: 20)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }
    static func color(_ type: DeckMemoryNoteType) -> Color {
        switch type {
        case .decision: .blue; case .preference: .purple; case .correction: .orange; case .result: .green; case .openItem: .red; case .lesson: .teal
        default: .secondary
        }
    }
    static func color(_ state: DeckMemoryResultState?) -> Color {
        switch state { case .verified: .green; case .reported: .blue; case .attempted: .orange; default: .secondary }
    }
}
