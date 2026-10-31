import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Asad 11 Oct: "in hoot chat or tasks when i do @ its not showing properly clickable profiles
// of the agents to mention and awake them". The @ list as real profile rows: picture, name,
// project · role, and whether they are awake, in sections (Agents, Sessions, Pages, Devices,
// Apps). Typing filters, ↑ ↓ move, Return or a click picks, and it scrolls: nothing is cut off.
// Used by the Hoot message box and the Tasks comment box (both through HootComposer).

/// One row of the @ list, worked out from a mention and the app's own agents, seats and hands.
struct DeckMentionRow: Identifiable, Equatable {
    enum Section: Int, CaseIterable {
        case agents, sessions, pages, devices, apps, files
        var title: String {
            switch self { case .agents: "Agents"; case .sessions: "Sessions"; case .pages: "Pages"; case .devices: "Devices"; case .apps: "Apps"; case .files: "Project files" }
        }
    }
    enum Picture: Equatable {
        case hoot
        case agent(id: String, icon: AGTIcon, colour: String?)
        case project(PROJProject?, name: String)
        case symbol(String)
        case vacantSeat
    }
    enum State: Equatable {
        case working, waiting, awake, asleep, vacant, none
        var word: String {
            switch self {
            case .working: "Working"; case .waiting: "Waiting for you"; case .awake: "Awake"
            case .asleep: "Asleep"; case .vacant: "Vacant"; case .none: ""
            }
        }
        var colour: Color {
            switch self {
            case .working: .accentColor; case .waiting: .orange; case .awake: .green
            case .asleep, .vacant, .none: Color.secondary.opacity(0.6)
            }
        }
        /// Asleep and vacant are a ring, not a filled dot.
        var hollow: Bool { self == .asleep || self == .vacant }
    }

    let mention: HootMention
    var section: Section
    var picture: Picture
    var title: String
    /// "iMatch · Database fixer"
    var detail: String
    var isLead = false
    /// Sessions filling this seat right now (shown as ×3 from two up).
    var hands = 1
    var state: State = .none

    var id: String { mention.marker }
    var searchText: String { (title + " " + detail + " " + mention.name).lowercased() }
}

@MainActor
enum DeckMentionRows {
    private static let pageSymbols = ["agents-all": "person.3", "agents": "person.3", "tasks": "list.bullet", "artifacts": "doc.richtext",
                                      "servers": "server.rack", "devices": "laptopcomputer.and.iphone", "receiver": "antenna.radiowaves.left.and.right",
                                      "mcp": "puzzlepiece.extension", "store": "bag", "files": "folder", "git": "arrow.triangle.branch",
                                      "github": "arrow.triangle.pull", "overview": "square.grid.2x2", "readiness": "checkmark.seal"]

    /// The rows for these mentions, in section order (agents first), each section in the given order.
    static func rows(for mentions: [HootMention], agents: [AGTAgent], projects: [PROJProject],
                     hands: (AGTSeat) -> Int, seatTitle: (AGTSeat) -> String?, sessionStatus: (String) -> String?) -> [DeckMentionRow] {
        var seen = Set<String>()
        let rows = mentions.filter { seen.insert($0.marker).inserted }.map { mention -> DeckMentionRow in
            switch mention.kind {
            case .agent: agentRow(mention, agents: agents, projects: projects, hands: hands, seatTitle: seatTitle)
            case .session: sessionRow(mention, projects: projects, status: sessionStatus(mention.id))
            case .page: DeckMentionRow(mention: mention, section: .pages, picture: .symbol(pageSymbols[mention.id] ?? "doc"), title: mention.name, detail: "Page")
            case .simulator: DeckMentionRow(mention: mention, section: .devices, picture: .symbol("iphone"), title: mention.name,
                                            detail: mention.group.isEmpty ? "Phone or simulator" : mention.group)
            case .tool: DeckMentionRow(mention: mention, section: .apps, picture: .symbol("puzzlepiece.extension"), title: mention.name,
                                       detail: mention.group.isEmpty ? "Connected app" : mention.group)
            case .file, .folder: DeckMentionRow(mention: mention, section: .files, picture: .symbol(mention.symbol), title: mention.name, detail: mention.id)
            }
        }
        return DeckMentionRow.Section.allCases.flatMap { section in rows.filter { $0.section == section } }
    }

    private static func projectName(_ text: String, id: String?, projects: [PROJProject]) -> String {
        if let id, let found = projects.first(where: { $0.id == id }) { return found.id == PROJProjects.independentID ? "Independent" : found.name }
        if let found = projects.first(where: { $0.id == text }) { return found.id == PROJProjects.independentID ? "Independent" : found.name }
        return text
    }

    private static func state(_ live: AWWatchState?) -> DeckMentionRow.State {
        switch live {
        case .working, .queued: .working
        case .waiting: .waiting
        case .idle, .finished: .awake
        case .offline, .unknown, .none: .asleep
        }
    }

    private static func agentRow(_ mention: HootMention, agents: [AGTAgent], projects: [PROJProject],
                                 hands: (AGTSeat) -> Int, seatTitle: (AGTSeat) -> String?) -> DeckMentionRow {
        // A seat nobody sits in: "iMatch · Database fixer", vacant, has memory.
        if mention.id.hasPrefix(AGTDirectory.vacantSeatPrefix), let seat = AGTSeat(key: String(mention.id.dropFirst(AGTDirectory.vacantSeatPrefix.count))) {
            let project = seat.projectID.map { projectName($0, id: $0, projects: projects) }
            let role = seatTitle(seat) ?? seat.role.map(AGTSeats.title(forRole:)) ?? (seat.category == .lead ? "Lead" : mention.name)
            return DeckMentionRow(mention: mention, section: .agents, picture: .vacantSeat,
                                  title: [project, role].compactMap { $0 }.joined(separator: " · "), detail: "Vacant, has memory · asks the lead to fill it",
                                  isLead: seat.category == .lead, hands: 0, state: .vacant)
        }
        // L4-AGENTS: a project's lead seat filled by a session ("lead:<project id>"): awake while that session runs.
        if let lead = AGTLeads.sessionLead(address: mention.id) {
            return DeckMentionRow(mention: mention, section: .agents,
                                  picture: .agent(id: mention.id, icon: lead.running?.icon ?? .symbol("person.crop.circle"), colour: lead.running?.iconColour),
                                  title: lead.name, detail: lead.project.name + " · Lead", isLead: true, hands: 1,
                                  state: lead.running.map { state($0.live ?? .idle) } ?? .asleep)
        }
        let found = agents.first { $0.id == mention.id || $0.profileID == mention.id }
        if mention.id == CrmPeople.hoot || mention.id == AGTDirectory.hootID || found?.isHoot == true {
            return DeckMentionRow(mention: mention, section: .agents, picture: .hoot, title: mention.name.isEmpty ? "Hoot" : mention.name,
                                  detail: "Every project · Orchestrator", state: state(found?.live ?? .idle))
        }
        guard let agent = found else {
            let project = projectName(mention.project, id: nil, projects: projects)
            return DeckMentionRow(mention: mention, section: .agents, picture: .agent(id: mention.id, icon: .symbol("person.crop.circle"), colour: nil),
                                  title: mention.name, detail: project.isEmpty ? "Agent" : project, state: .asleep)
        }
        let agentID = agent.profileID ?? agent.id
        let seat = AGTSeats.seat(agentID: agentID, seat: agent.seat, projectID: agent.projectID, projects: projects)
        let project = projectName(mention.project, id: agent.projectID, projects: projects)
        let role = seat.category == .lead ? "Lead" : (agent.role.isEmpty ? (seatTitle(seat) ?? seat.role.map(AGTSeats.title(forRole:)) ?? "Agent") : agent.role)
        return DeckMentionRow(mention: mention, section: .agents,
                              picture: .agent(id: agentID, icon: agent.icon, colour: agent.iconColour),
                              title: agent.name, detail: [project.isEmpty ? "Independent" : project, role].joined(separator: " · "),
                              isLead: seat.category == .lead, hands: max(1, hands(seat)), state: state(agent.live))
    }

    private static func sessionRow(_ mention: HootMention, projects: [PROJProject], status: String?) -> DeckMentionRow {
        let project = projects.first { $0.id == mention.group && $0.id != PROJProjects.independentID }
        let name = project?.name ?? (mention.project.isEmpty ? "Independent" : mention.project)
        let state: DeckMentionRow.State
        switch StatusMeaning(status) {
        case .working: state = .working
        case .needsInput: state = .waiting
        case .ready, .completed: state = .awake
        case .exited, .failed: state = .asleep
        }
        return DeckMentionRow(mention: mention, section: .sessions, picture: .project(project, name: name), title: mention.name,
                              detail: name + " · Session", state: state)
    }

    /// The live rows: agents, seats and hands read from the app's own stores (never changed here).
    static func live(for mentions: [HootMention]) -> [DeckMentionRow] {
        let projects = SIDEBARProjectStore.shared.projects
        // Asad's decision (via L4): a seat nobody sits in that still holds memory is offered too,
        // greyed. Mentioning it asks the project's lead (or Hoot) to fill it.
        var mentions = mentions
        if mentions.contains(where: { $0.kind == .agent }) {
            mentions += AGTLeads.roster().filter(\.isVacantWithMemory).map {
                HootMention(id: AGTDirectory.vacantSeatPrefix + $0.seat.key, kind: .agent,
                            name: ($0.project.map { $0.name + " · " } ?? "") + $0.title, project: $0.project?.name ?? "")
            }
        }
        return rows(for: mentions, agents: AGTAgentsStore.shared.agents, projects: projects,
                    hands: { AGTHandsStore.shared.hands(on: $0.owner).count },
                    seatTitle: { AGTSeatsStore.shared.title(for: $0) },
                    sessionStatus: { AppModel.shared.sidebar?.item(id: $0)?.status })
    }
}

extension DeckMentionRows {
    /// How well a row answers what was typed: 0 its name starts with it, 1 a word of its name
    /// starts with it, 2 its name contains it, 3 only its role / project / description does.
    nonisolated static func rank(names: [String], other: String, needle: String) -> Int? {
        var best: Int?
        for name in names where !name.isEmpty {
            var found: Int?
            if name.hasPrefix(needle) { found = 0 } else {
                var wordStart = true, index = name.startIndex
                while index < name.endIndex {
                    if wordStart, name[index...].hasPrefix(needle) { found = 1; break }
                    wordStart = !(name[index].isLetter || name[index].isNumber)
                    index = name.index(after: index)
                }
                if found == nil, name.contains(needle) { found = 2 }
            }
            if let found, found < (best ?? 9) { best = found }
        }
        return best ?? (other.contains(needle) ? 3 : nil)
    }

    /// The rows for what was typed after "@", best first. EVERY name match comes before any match
    /// in a role, project or description (11 Oct: "@…helpers" took a real agent whose DESCRIPTION
    /// says "helpers" ahead of the agent NAMED "MT Helper", and Return picks the first row). Inside
    /// one group the list keeps its own order: sections, then as given.
    nonisolated static func ranked(_ rows: [DeckMentionRow], query: String) -> [DeckMentionRow] {
        let typed = String(query.drop(while: \.isWhitespace)).lowercased()
        guard !typed.isEmpty else { return rows }
        func sorted(_ needle: String) -> [DeckMentionRow] {
            rows.enumerated().compactMap { index, row -> (rank: Int, index: Int, row: DeckMentionRow)? in
                rank(names: [row.title.lowercased(), row.mention.name.lowercased()], other: row.searchText, needle: needle).map { ($0, index, row) }
            }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.row)
        }
        let exact = sorted(typed)
        if !exact.isEmpty { return exact }
        // "@MT " with nothing after the space yet: the space alone must not empty the list.
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        return trimmed == typed ? [] : sorted(trimmed)
    }

    /// The names the @ list would show for these candidates (a row's name can differ from its mention's).
    static func names(for mentions: [HootMention]) -> [String] {
        live(for: mentions).flatMap { [$0.title, $0.mention.name] }
    }
}

/// What counts as "still asking for the @ list" while the person types.
enum DeckMentionQuery {
    /// The text after the last "@" before the caret, or nil when the list should be closed.
    /// A name can have spaces ("MT Helper"): the list stays open across a space for as long as
    /// what was typed is still part of some NAME; it closes on a new line, on "@ " and once the
    /// text has run past every name (11 Oct: a space after "@MT" closed the list and Return then
    /// sent the half-typed message).
    static func open(before caret: String, names: () -> [String]) -> String? {
        guard let at = caret.range(of: "@", options: .backwards) else { return nil }
        let typed = String(caret[at.upperBound...])
        if typed.contains(where: \.isNewline) { return nil }
        guard typed.contains(where: \.isWhitespace) else { return typed }
        if typed.first?.isWhitespace == true { return nil }
        let needle = typed.lowercased()
        return names().contains { $0.lowercased().contains(needle) } ? typed : nil
    }
}

extension DeckMentionPicker {
    /// The row Return or Tab would take for this query, without the list being on screen. For the
    /// message box's own Return: with the list open (or about to open) Return picks, it never sends.
    @MainActor static func firstPick(candidates: [HootMention], query: String) -> HootMention? {
        DeckMentionRows.ranked(DeckMentionRows.live(for: candidates), query: query).first?.mention
    }
}

/// The @ list. Give it the candidates and what was typed after "@"; it calls `onPick`.
struct DeckMentionPicker: View {
    let candidates: [HootMention]
    let query: String
    let onPick: (HootMention) -> Void
    var onCancel: () -> Void = {}
    /// Fixed rows for offscreen pictures; nil reads the app's live agents, seats and hands.
    var fixtureRows: [DeckMentionRow]? = nil

    @State private var selected: String?
    @State private var keys = DeckMentionKeys()

    private var rows: [DeckMentionRow] {
        DeckMentionRows.ranked(fixtureRows ?? DeckMentionRows.live(for: candidates), query: query)
    }
    /// While something is typed the list is ONE ranked list (best match first, the row Return takes);
    /// with nothing typed it is grouped by kind.
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private func rowButton(_ row: DeckMentionRow, current: String?) -> some View {
        Button { onPick(row.mention) } label: {
            DeckMentionRowView(row: row, selected: row.id == current)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selected = row.id } }
        .id(row.id)
        .accessibilityLabel(accessibility(row))
    }

    var body: some View {
        let rows = rows
        let current = rows.contains { $0.id == selected } ? selected : rows.first?.id
        // Keep the key handler on this evaluation's query and rows.
        let _ = keys.handle = { code in handle(code) }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if rows.isEmpty {
                        Text(query.isEmpty ? "Nobody to mention yet" : "No one matches “\(query)”")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                    }
                    if searching {
                        ForEach(rows) { row in rowButton(row, current: current) }
                    } else {
                        ForEach(DeckMentionRow.Section.allCases, id: \.self) { section in
                            let members = rows.filter { $0.section == section }
                            if !members.isEmpty {
                                Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
                                ForEach(members) { row in rowButton(row, current: current) }
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(width: 360)
            .frame(height: min(380, CGFloat(rows.count) * 46 + CGFloat(searching ? 0 : Set(rows.map(\.section)).count) * 26 + (rows.isEmpty ? 44 : 14)))
            .onChange(of: current) { _, id in
                guard let id, keys.movedByKeyboard else { return }
                keys.movedByKeyboard = false
                proxy.scrollTo(id)
            }
        }
        .onAppear {
            if !AppModel.shared.isUITestFixture, fixtureRows == nil { AGTLeads.startSeatReads() }
            keys.install()
        }
        .onDisappear { keys.remove() }
        .onChange(of: query) { selected = nil }
        .background(DeckMentionAnchor(keys: keys))
    }

    private func accessibility(_ row: DeckMentionRow) -> String {
        [row.title, row.detail, row.isLead ? "Lead" : "", row.hands > 1 ? "\(row.hands) hands" : "", row.state.word]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// ↑ ↓ move, Return / Enter / Tab pick, Esc closes. The message box keeps the keyboard for typing.
    private func handle(_ code: UInt16) -> Bool {
        let rows = rows
        let index = rows.firstIndex { $0.id == selected } ?? (rows.isEmpty ? nil : 0)
        switch code {
        case 125, 126:
            guard !rows.isEmpty else { return true }
            let next = min(rows.count - 1, max(0, (index ?? 0) + (code == 125 ? 1 : -1)))
            keys.movedByKeyboard = true
            selected = rows[next].id
            return true
        case 36, 76, 48:
            // With the list open Return, Enter and Tab pick; they never reach the message box (where
            // Return sends). Nobody matches: the list closes and the key is still taken.
            if let index { onPick(rows[index].mention) } else { onCancel() }
            return true
        case 53:
            onCancel()
            return true
        default:
            return false
        }
    }
}

/// Keys go to the message box (it keeps typing); this watches for the few the list needs.
@MainActor
private final class DeckMentionKeys {
    var handle: ((UInt16) -> Bool)?
    var movedByKeyboard = false
    /// A view inside the list: once it has left its window the list is gone, and so is the watcher.
    weak var anchor: NSView?
    var attached = false
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                // The list has closed without telling us: stop watching, take nothing.
                if self.attached, self.anchor?.window?.isVisible != true { self.remove(); return false }
                // Never take a key from an input method that is still composing.
                if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
                return self.handle?(code) == true
            }
            return taken ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handle = nil
    }
}

private struct DeckMentionAnchor: NSViewRepresentable {
    let keys: DeckMentionKeys

    final class AnchorView: NSView {
        var onWindow: ((Bool) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onWindow?(window != nil) }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        keys.anchor = view
        view.onWindow = { [weak keys] inWindow in if inWindow { keys?.attached = true } }
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) {}
}

private struct DeckMentionRowView: View {
    let row: DeckMentionRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            picture.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if row.isLead { badge("Lead") }
                    if row.hands > 1 { badge("×\(row.hands)").help("\(row.hands) sessions are working in this role") }
                }
                Text(row.detail).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
            }
            Spacer(minLength: 6)
            if row.state != .none {
                HStack(spacing: 4) {
                    Group {
                        if row.state.hollow {
                            Circle().strokeBorder(selected ? Color.white.opacity(0.9) : row.state.colour, lineWidth: 1.5)
                        } else {
                            Circle().fill(selected ? Color.white : row.state.colour)
                        }
                    }
                    .frame(width: 8, height: 8)
                    Text(row.state.word).font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                }
                .fixedSize()
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .opacity(row.state == .vacant && !selected ? 0.6 : 1)   // a vacant seat reads as greyed
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(.rect)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(selected ? Color.white.opacity(0.25) : Color.primary.opacity(0.1), in: Capsule())
    }

    @ViewBuilder private var picture: some View {
        switch row.picture {
        case .hoot:
            AgentAvatar(icon: .symbol("bird"), size: 28, hoot: true)
        case .agent(let id, let icon, let colour):
            AgentAvatar(icon: icon, size: 28, id: id, colour: colour)
        case .project(let project, let name):
            ProjectLogoView(project: project, name: name, size: 28, onAccent: selected)
        case .symbol(let name):
            tile { Image(systemName: name).font(.system(size: 13)).foregroundStyle(selected ? Color.white : Color.secondary) }
        case .vacantSeat:
            tile { Image(systemName: "person.crop.circle.dashed").font(.system(size: 15)).foregroundStyle(selected ? Color.white : Color.secondary) }
        }
    }

    private func tile<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
            .overlay(content())
    }
}
