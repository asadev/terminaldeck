import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

// MARK: Diary

/// Every message in and out, word for word. Search by words and by meaning; a result opens the moment.
struct NativeMemoryDiaryPart: View {
    let store: NativeMemoryStore
    let open: (NativeMemoryPart) -> Void
    @State private var query = ""
    @State private var mode: DeckMemorySearchMode = .both
    @State private var everything = false
    @State private var result: DeckMemorySearchResult?
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var searchID = 0
    @State private var showRewound = false
    private var rewoundCount: Int { store.diary.filter(\.isRewound).count }
    private var rows: [DeckMemoryDiaryEntry] { showRewound ? store.diary : store.diary.filter { !$0.isRewound } }
    @State private var moment: Moment?
    @FocusState private var focused: Bool

    struct Moment: Identifiable { let id: Int64; let rows: [DeckMemoryDiaryEntry] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    NativeSessionTextField("Search what was said", text: $query).sessionFocused($focused).onSubmit(search).textFieldStyle(.plain)
                    if !query.isEmpty { NativeSessionButton { stopSearch(); query = ""; result = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DeckTokens.hairline))
                Picker("How", selection: $mode) {
                    Text("Words and meaning").tag(DeckMemorySearchMode.both)
                    Text("Exact words").tag(DeckMemorySearchMode.words)
                    Text("Meaning").tag(DeckMemorySearchMode.meaning)
                }.labelsHidden().fixedSize()
                if store.owner != .hoot {
                    Toggle("Everyone's", isOn: $everything).toggleStyle(.switch).help("Search every owner's diary, not only this one")
                }
                if rewoundCount > 0, result == nil {
                    Toggle("Show rewound (\(rewoundCount))", isOn: $showRewound).toggleStyle(.switch)
                        .help("Rows from before a rewind: kept as history, no longer part of the conversation")
                }
                NativeSessionButton("Search", action: search).buttonStyle(.borderedProminent).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
            }.padding(.horizontal, 20)
            if let notice = result?.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20) }
            if searching {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let result {
                if result.hits.isEmpty {
                    DeckEmpty(title: "Nothing found", message: "Try other words, or search by meaning.", symbol: "magnifyingglass").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    NativeMemoryColumn {
                        DeckCard(padding: 6) { VStack(spacing: 0) { ForEach(result.hits) { hit in NativeSessionButton { jump(hit) } label: { hitRow(hit) }.buttonStyle(DeckRowStyle()) } } }
                    }
                }
            } else if rows.isEmpty {
                DeckEmpty(title: "The diary is empty", message: "It fills by itself as messages go in and out.", symbol: "book.closed").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = rows, writers = Writers(shown)
                NativeMemoryColumn {
                    DeckCard(padding: 6) {
                        VStack(spacing: 0) {
                            ForEach(shown) { entry in
                                NativeSessionButton { openMoment(entry.id) } label: { entryRow(entry, strong: false, writers) }.buttonStyle(DeckRowStyle())
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $moment) { moment in momentSheet(moment) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AGFRAME.focusSearch"))) { _ in focused = true }
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !store.fixture else { return }
        // Return pressed again while a search runs: the newer one replaces it. Only the newest
        // search's answer is shown, and the spinner stays until that one has answered.
        let id = stopSearch()
        searching = true
        let owner: DeckMemoryOwner? = everything ? nil : store.owner
        let mode = mode
        searchTask = Task {
            let answer: Result<DeckMemorySearchResult, Error>
            do { answer = .success(try await DeckMemory.ready().search(.init(text, owner: owner, mode: mode, limit: 60))) }
            catch { answer = .failure(error) }
            guard id == searchID, !Task.isCancelled else { return }
            searching = false
            switch answer {
            case .success(let found): result = found
            case .failure(let error): store.problem = error.localizedDescription
            }
        }
    }
    /// Drops the running search's answer (a new search, or the field was cleared); the next search's number.
    @discardableResult
    private func stopSearch() -> Int {
        searchTask?.cancel(); searchTask = nil
        searching = false
        searchID += 1
        return searchID
    }
    private func jump(_ hit: DeckMemorySearchHit) {
        switch hit.kind {
        case .diary: if let id = Int64(hit.ref) { openMoment(id) }
        case .note: open(.notes)
        case .topic: open(.topics)
        case .card: open(.card)
        case .playbook: open(.playbook)
        }
    }
    private func openMoment(_ id: Int64) {
        guard !store.fixture else { return }
        Task {
            do { moment = Moment(id: id, rows: try await DeckMemory.ready().diary(around: id, before: 12, after: 12)) }
            catch { store.problem = error.localizedDescription }
        }
    }
    private func hitRow(_ hit: DeckMemorySearchHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            NativeMemoryTag(text: hit.kind == .diary ? "Diary" : hit.kind.rawValue.capitalized, color: hit.kind == .diary ? .blue : .purple).frame(width: 72, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title.isEmpty ? hit.snippet : hit.title).lineLimit(1)
                Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(NativeMemoryStore.day(hit.labels.date)).font(.caption).foregroundStyle(.secondary)
                Text(hit.matchedBy == .meaning ? "by meaning" : "by words").font(.caption2).foregroundStyle(.tertiary)
            }
        }.padding(.horizontal, 8).padding(.vertical, 2)
    }
    private func entryRow(_ entry: DeckMemoryDiaryEntry, strong: Bool, _ writers: Writers) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(who(entry, writers)).font(.caption.weight(.semibold)).foregroundStyle(entry.author == .person ? Color.accentColor : .secondary).lineLimit(1).frame(width: 84, alignment: .leading)
            Text(entry.text).font(.callout).lineLimit(strong ? nil : 2).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            if entry.isRewound { NativeMemoryTag(text: "Rewound", color: .gray).help(entry.rewoundAt.map { "Rewound " + NativeMemoryStore.when($0) } ?? "Rewound") }
            Text(NativeMemoryStore.day(entry.at)).font(.caption).foregroundStyle(.secondary)
        }
        .opacity(entry.isRewound ? 0.5 : 1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(strong ? Color.accentColor.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }
    /// The agents' and seats' names for the rows on show, looked up once per render, never per row (#73):
    /// a seat's diary of 160 agent rows rebuilt the agent list and the seat roster for every row on every redraw.
    struct Writers {
        private var agents: [String: String] = [:]
        private var seats: [DeckMemoryOwner: String] = [:]
        @MainActor init(_ rows: [DeckMemoryDiaryEntry]) {
            guard rows.contains(where: { $0.labels.agent != nil }) else { return }
            // First match wins for either key, the same agent `first(where:)` picked.
            for agent in AGTAgentsStore.shared.agents {
                if agents[agent.id] == nil { agents[agent.id] = agent.name }
                if let profile = agent.profileID, agents[profile] == nil { agents[profile] = agent.name }
            }
            guard rows.contains(where: { $0.labels.agent.map { agents[$0]?.isEmpty != false } == true }) else { return }
            for row in AGTLeads.roster() where seats[row.seat.owner] == nil { seats[row.seat.owner] = row.filledBy.first?.name ?? "" }
        }
        /// The agent's real name ("MT Builder"), never its slug with capitals ("Mt Builder").
        func name(_ entry: DeckMemoryDiaryEntry) -> String? {
            entry.labels.agent.map { id in
                if let name = agents[id], !name.isEmpty { return name }
                if let name = seats[entry.labels.owner], !name.isEmpty { return name }
                return id
            }
        }
    }
    /// Who really wrote the row (M1's author field); the role is only the fallback for old rows.
    private func who(_ entry: DeckMemoryDiaryEntry, _ writers: Writers) -> String {
        if entry.meta["source"] == DeckMemoryFlowNames.testSource { return "Builder test" }
        let seat = writers.name(entry)
        switch entry.author {
        case .person: return "You"
        case .orchestrator: return "Hoot"
        case .lead: return seat ?? "Lead"
        case .agent: return seat ?? "Agent"
        case .tool: return "Tool"
        case .app: return "App"
        case nil:
            switch entry.role { case .user: return "You"; case .assistant: return seat ?? (store.owner == .hoot ? "Hoot" : "AI"); case .tool: return "Tool"; case .system: return "App"; case .event: return "Event" }
        }
    }
    private func momentSheet(_ moment: Moment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("The moment").font(.headline)
                if let first = moment.rows.first(where: { $0.id == moment.id }) {
                    if let icon = store.projectIcon(first.labels.project) { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                    Text([store.projectName(first.labels.project), first.labels.session.map { "session " + $0.prefix(8) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    let writers = Writers(moment.rows)
                    VStack(spacing: 2) { ForEach(moment.rows) { entryRow($0, strong: $0.id == moment.id, writers).id($0.id) } }
                }.onAppear { proxy.scrollTo(moment.id, anchor: .center) }
            }
            HStack { Spacer(); NativeSessionButton("Done") { self.moment = nil }.keyboardShortcut(.defaultAction) }
        }.padding(20).frame(width: 720, height: 560)
    }
}

// MARK: Board

/// The shared board, filtered to this owner. Result state is shown as attempted / reported / verified.
struct NativeMemoryBoardPart: View {
    let store: NativeMemoryStore
    @State private var kind: DeckMemoryBoardKind?
    @State private var waitingOnly = false
    private var rows: [DeckMemoryBoardRow] {
        store.board.filter { $0.archivedAt == nil && (kind == nil || $0.kind == kind) && (!waitingOnly || $0.isWaiting) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Kind", selection: $kind) {
                    Text("Everything").tag(DeckMemoryBoardKind?.none)
                    ForEach(DeckMemoryBoardKind.allCases, id: \.self) { Text($0.rawValue.capitalized + "s").tag(DeckMemoryBoardKind?.some($0)) }
                }.labelsHidden().fixedSize()
                Toggle("Waiting for you only", isOn: $waitingOnly).toggleStyle(.switch)
                Spacer()
                if store.owner != .hoot {
                    Picker("Whose", selection: Binding(get: { store.boardEverything }, set: { store.boardEverything = $0; Task { await store.loadBoard() } })) {
                        Text("This one's").tag(false); Text("Whole board").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }.padding(.horizontal, 20)
            if rows.isEmpty {
                DeckEmpty(title: "Nothing on the board", message: "The app fills it from what sessions, agents and tasks really did.", symbol: "rectangle.3.group")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NativeMemoryColumn(width: 1100) {
                    DeckCard(padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Rectangle().fill(DeckTokens.hairline).frame(height: 1) }
                                boardRow(row)
                            }
                        }
                    }
                }
            }
        }
    }
    private func symbol(_ kind: DeckMemoryBoardKind) -> String {
        switch kind { case .project: "folder"; case .session: "terminal"; case .agent: "person.crop.square"; case .task: "checklist"; case .chat: "bubble.left" }
    }
    private func boardRow(_ row: DeckMemoryBoardRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(row.kind)).foregroundStyle(.secondary).frame(width: 20).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.title).fontWeight(.medium).lineLimit(1)
                    if let name = store.projectName(row.labels.project) {
                        if let icon = store.projectIcon(row.labels.project) { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
                        Text(name).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !row.doing.isEmpty { Text(row.doing).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
                if !row.lastResult.isEmpty { Text(row.lastResult).font(.callout).lineLimit(3) }
                if row.isWaiting {
                    Label(row.waitingForUser, systemImage: "hand.raised.fill").font(.callout).foregroundStyle(DeckTokens.warn).lineLimit(2)
                }
                if !row.proof.isEmpty { Text("Proof: " + row.proof).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                if let state = row.state { NativeMemoryTag(text: state.title, color: NativeMemoryTag.color(state)) }
                Text(NativeMemoryStore.when(row.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            NativeSessionButton { store.act("board", done: "Taken off the board") { _ = try await $0.archiveBoardRow(id: row.id); return nil } } label: {
                Image(systemName: "xmark.circle").frame(width: 24, height: 24).contentShape(.rect)
            }.buttonStyle(.borderless).foregroundStyle(.secondary).disabled(store.busy != nil || store.fixture)
                .help("Take off the board").accessibilityLabel("Take off the board")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contextMenu {
            NativeSessionButton("Take off the board") { store.act("board", done: "Taken off the board") { _ = try await $0.archiveBoardRow(id: row.id); return nil } }
        }
    }
}
