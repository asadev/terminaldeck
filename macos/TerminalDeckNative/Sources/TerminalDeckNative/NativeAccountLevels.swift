import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

// ACCOUNTS-SPEC (Asad, 11 Oct): "accounts management will be one place in settings, there we
// can just switch what to assign to who". The "Who uses what" table: Whole Terminal Deck, Hoot,
// each project and its roles, one picker each ("Same as above" or an account), the account in
// effect and where it comes from, and Switch now. Only account ids are handled here; logins never
// leave the app's own store and are never read, shown or logged by this file.

/// One row of "Who uses what".
struct NativeAccountLevelRow: Identifiable, Equatable {
    enum Kind: Equatable { case app, hoot, project, lead, role }
    let id: String
    var kind: Kind
    var title: String
    /// "Lead" / "×3 working now"…
    var detail: String = ""
    var project: PROJProject?
    /// The stored level(s) this row writes: one per project folder; one for a seat; one for the app.
    var levels: [[String: String]]
    /// Sessions that fill this seat right now (a seat row only).
    var seatSessions: Set<String> = []
    var indented: Bool { kind == .lead || kind == .role }
}

/// A running session, as much as the switch needs.
struct NativeAccountSession: Identifiable, Equatable {
    let id: String
    var title: String
    var cwd: String
    var projectID: String?
    var provider: String
    /// The account it uses now (nil = that AI's own login on this Mac).
    var accountID: String?
}

/// What "Switch now" would do, before it does it.
struct NativeAccountSwitchPlan: Identifiable, Equatable {
    struct Move: Identifiable, Equatable {
        let id: String
        var title: String
        var target: String
        var targetName: String
        /// Chosen for this one session (kept unless he ticks the box).
        var individual: Bool
        var result: String?
        var failed = false
    }
    let id = UUID()
    var rowTitle: String
    var moves: [Move]
    var alreadyThere: Int
    var includeIndividual = false
    var running = false
    var finished = false

    var toMove: [Move] { moves.filter { includeIndividual || !$0.individual } }
    var kept: [Move] { includeIndividual ? [] : moves.filter(\.individual) }
}

@MainActor @Observable
final class NativeAccountLevelsModel {
    static let shared = NativeAccountLevelsModel()

    var provider = "claude"
    var search = ""
    var problem: String?
    var plan: NativeAccountSwitchPlan?
    private(set) var app: [String: String] = [:]
    private(set) var projects: [String: [String: String]] = [:]
    private(set) var seats: [String: [String: String]] = [:]
    private(set) var sessions: [NativeAccountSession] = []
    /// account id → "5 h 12% · week 40%"
    private(set) var usage: [String: String] = [:]
    private(set) var loaded = false
    /// The background helper that keeps sessions running is from before this update: it knows the old
    /// default and per-folder defaults only, so the table shows those and nothing can be changed yet.
    private(set) var olderHelper = false
    static let olderHelperLine = "This background helper cannot change account assignments. To use a different account now, open New session and choose it in Login. Running sessions keep their current accounts."
    static let olderHelperSignIn = "Open Add account and press Sign in. Terminal Deck can sign you in while this background helper keeps your sessions running."
    /// The helper's own refusal, whichever wording that build used.
    static func saysOlderHelper(_ text: String) -> Bool {
        text.contains("session host that comes with this version") || text.contains("Unknown private account read view") || text.contains("does not handle this channel")
    }
    /// Offscreen pictures: fixed data, nothing read or written.
    var fixture = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    /// What each session inherited before the last change made here (to tell "following" from "chosen").
    @ObservationIgnored private var inheritedBefore: [String: String] = [:]

    // MARK: Sessions he moved one by one (the chip): they keep their choice on a level switch.

    private static let chosenKey = "accounts.sessionsChosenIndividually"
    static func markChosen(sessionID: String) {
        var ids = UserDefaults.standard.stringArray(forKey: chosenKey) ?? []
        if !ids.contains(sessionID) { ids.append(sessionID); UserDefaults.standard.set(Array(ids.suffix(500)), forKey: chosenKey) }
    }
    private static func unmarkChosen(_ sessionID: String) {
        let ids = (UserDefaults.standard.stringArray(forKey: chosenKey) ?? []).filter { $0 != sessionID }
        UserDefaults.standard.set(ids, forKey: chosenKey)
    }
    private static var chosen: Set<String> { Set(UserDefaults.standard.stringArray(forKey: chosenKey) ?? []) }

    // MARK: Loading

    func start() {
        guard !fixture else { return }
        if subscriptions.isEmpty {
            for event in ["session:created", "session:exit", "session:removed", "session:switched", "project-registry:changed"] {
                subscriptions.append(EngineBridge.shared.on(event) { [weak self] _ in Task { await self?.reload() } })
            }
            SIDEBARProjectStore.shared.start(); AGTLeads.startSeatReads()
        }
        Task { await reload(); await reloadUsage() }
    }

    #if DEBUG
    func setFixture(app: [String: String], projects: [String: [String: String]], seats: [String: [String: String]],
                    sessions: [NativeAccountSession], usage: [String: String], olderHelper: Bool = false) {
        fixture = true; self.app = app; self.projects = projects; self.seats = seats; self.sessions = sessions; self.usage = usage; loaded = true
        self.olderHelper = olderHelper
    }
    #endif

    func reload() async {
        guard !fixture else { return }
        do {
            let raw = try await EngineBridge.shared.invoke("profiles:levels") as? [String: Any] ?? [:]
            func nested(_ value: Any?) -> [String: [String: String]] {
                (value as? [String: Any] ?? [:]).compactMapValues { $0 as? [String: String] }
            }
            olderHelper = raw["olderHelper"] as? Bool ?? false
            app = raw["app"] as? [String: String] ?? [:]
            projects = nested(raw["projects"]); seats = nested(raw["seats"])
            let rows = try await EngineBridge.shared.invoke("session:list") as? [[String: Any]] ?? []
            sessions = rows.compactMap { row in
                guard let id = row["id"] as? String, let provider = row["provider"] as? String,
                      row["exitCode"] == nil || row["exitCode"] is NSNull else { return nil }
                return NativeAccountSession(id: id, title: row["title"] as? String ?? id, cwd: row["cwd"] as? String ?? "",
                                            projectID: row["projectId"] as? String, provider: provider, accountID: row["profileId"] as? String)
            }
            loaded = true; problem = nil
        } catch { problem = Self.readProblem(error) }
    }

    /// A session helper started before an update keeps running until its sessions end, and it does
    /// not know the levels yet. Say that in plain words, not its internal answer.
    static func readProblem(_ error: Error) -> String {
        let text = CodingAIErrorText.from(error, fallback: "")
        if saysOlderHelper(text) { return olderHelperLine }
        return "Couldn’t read who uses which account. " + text
    }

    func reloadUsage() async {
        guard !fixture, let raw = try? await EngineBridge.shared.invoke("usage:read") as? [String: Any] else { return }
        var five: [String: Double] = [:], week: [String: Double] = [:]
        for reading in raw["readings"] as? [[String: Any]] ?? [] {
            guard let account = reading["account"] as? [String: Any], let provider = account["provider"] as? String,
                  let used = reading["used"] as? [String: Any], used["kind"] as? String == "reported",
                  let fraction = used["fraction"] as? Double else { continue }
            let id = account["id"] as? String ?? Self.systemID(provider)
            switch reading["window"] as? String {
            case "five-hour": five[id] = max(five[id] ?? 0, fraction)
            case "weekly": week[id] = max(week[id] ?? 0, fraction)
            default: break
            }
        }
        var lines: [String: String] = [:]
        for id in Set(five.keys).union(week.keys) {
            var parts: [String] = []
            if let value = five[id] { parts.append("5 hours \(Int((value * 100).rounded()))%") }
            if let value = week[id] { parts.append("week \(Int((value * 100).rounded()))%") }
            lines[id] = parts.joined(separator: " · ")
        }
        usage = lines
    }

    static func systemID(_ provider: String) -> String { provider == "claude" ? "system" : "system:" + provider }
    /// The picker's tag for a project whose folders disagree; never written.
    static let mixedID = "mixed"

    /// For a project's settings: "Claude Code: Work · set on this project" (display only).
    static func projectLine(folder: String?) async -> String? {
        guard let folder, !folder.isEmpty,
              let raw = try? await EngineBridge.shared.invoke("profiles:effective", [["provider": "claude", "projectPath": folder]]) as? [String: Any],
              let name = raw["name"] as? String else { return nil }
        let from: String
        switch raw["source"] as? String {
        case "project": from = "set on this project"
        case "app": from = "from the Terminal Deck default"
        default: from = "this Mac’s own login (nothing is set)"
        }
        return CodingAICatalog.label("claude") + ": " + name + " · " + from
    }

    /// For the places that only show an account (the session chip): where it comes from, in plain words.
    static func sourceLine(provider: String?, cwd: String?, current: String?, sessionID: String? = nil) async -> String? {
        guard let provider, ["claude", "codex", "gemini"].contains(provider) else { return nil }
        var input: [String: Any] = ["provider": provider]
        if let cwd, !cwd.isEmpty { input["projectPath"] = cwd }
        // A session that fills a seat (Hoot's, a lead's, a role's) follows that seat's row.
        AGTLeads.startSeatReads()
        if let sessionID, let seat = AGTLeads.roster().first(where: { sessionsFilling($0).contains(sessionID) }) { input["seat"] = seat.seat.key }
        guard let raw = try? await EngineBridge.shared.invoke("profiles:effective", [input]) as? [String: Any],
              let inherited = raw["accountId"] as? String else { return nil }
        let now = current ?? systemID(provider)
        if now != inherited { return "This session uses an account chosen just for it." }
        switch raw["source"] as? String {
        case "project":
            let folder = (raw["sourceKey"] as? String).map { ($0 as NSString).lastPathComponent } ?? "its project"
            return "From the project in " + folder + "."
        case "seat": return raw["sourceKey"] as? String == AGTSeat.orchestrator.key ? "From Hoot’s row in Settings." : "From its role."
        case "app": return "From the Terminal Deck default."
        default: return "This Mac’s own " + CodingAICatalog.label(provider) + " login (nothing is set in Settings)."
        }
    }

    // MARK: Rows

    /// The running sessions that fill a seat: whoever holds it, plus every extra hand on it.
    static func sessionsFilling(_ seat: AGTSeatRow) -> Set<String> {
        Set(seat.filledBy.flatMap { $0.liveIDs + [$0.sessionID].compactMap { $0 } } + AGTHandsStore.shared.hands(on: seat.seat.owner).map(\.sessionID))
    }

    /// Whole Terminal Deck, Hoot, then each project with its lead seat and roles (L4's roster:
    /// every seat with who fills it, vacant ones that still hold memory included).
    func liveRows() -> [NativeAccountLevelRow] {
        let registry = SIDEBARProjectStore.shared.projects, roster = AGTLeads.roster()
        func filling(_ seat: AGTSeatRow) -> Set<String> { Self.sessionsFilling(seat) }
        func row(_ seat: AGTSeatRow) -> NativeAccountLevelRow {
            let lead = seat.seat.category == .lead
            var detail: [String] = []
            if lead { if !seat.isVacant { detail.append("Lead") } }
            else if let name = seat.filledBy.first?.name, name != seat.title { detail.append(name) }
            if seat.isVacant { detail.append(seat.memory == nil ? "Vacant" : "Vacant, has memory") }
            if seat.hands > 1 { detail.append("×\(seat.hands)") }
            let title = lead ? (seat.filledBy.first?.name ?? "Lead") : seat.title
            return .init(id: "seat:" + seat.seat.key, kind: lead ? .lead : .role, title: title, detail: detail.joined(separator: " · "),
                         project: seat.project, levels: [["kind": "seat", "key": seat.seat.key]], seatSessions: filling(seat))
        }
        var out: [NativeAccountLevelRow] = [.init(id: "app", kind: .app, title: "Whole Terminal Deck", levels: [["kind": "app"]])]
        let hoot = roster.first { $0.seat == .orchestrator }
        out.append(.init(id: "seat:orchestrator", kind: .hoot, title: "Hoot", detail: "Every project",
                         levels: [["kind": "seat", "key": AGTSeat.orchestrator.key]], seatSessions: hoot.map(filling) ?? []))
        for project in registry where project.id != PROJProjects.independentID {
            out.append(.init(id: "project:" + project.id, kind: .project, title: project.name, project: project,
                             levels: project.folders.map { ["kind": "project", "path": $0] }))
            let seats = roster.filter { $0.project?.id == project.id && $0.seat != .orchestrator }
            out += seats.filter { $0.seat.category == .lead }.map(row) + seats.filter { $0.seat.category != .lead }.map(row)
        }
        // Roles that belong to no project sit at the end, straight under the whole-app choice.
        out += roster.filter { $0.project == nil && $0.seat != .orchestrator && $0.seat.category != .lead }.map(row)
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return out }
        // A match keeps its project row above it so the list still reads as a tree.
        let hits = Set(out.filter { ($0.title + " " + $0.detail + " " + ($0.project?.name ?? "")).lowercased().contains(needle) }.map(\.id))
        return out.filter { row in hits.contains(row.id) || (row.kind == .project && out.contains { hits.contains($0.id) && $0.project?.id == row.project?.id }) }
    }

    // MARK: What is stored, what is in effect, and where it comes from

    /// The account set on a row; nil when nothing is set, or when its folders do not agree (see `mixed`).
    func assigned(_ row: NativeAccountLevelRow) -> String? {
        let choices = row.levels.map(stored)
        return Set(choices).count == 1 ? choices.first ?? nil : nil
    }

    /// 18 Oct (#143): a project whose folders use different accounts (an older per-folder choice). The row says
    /// so instead of showing only its first folder's choice.
    func mixed(_ row: NativeAccountLevelRow) -> Bool { Set(row.levels.map(stored)).count > 1 }

    private func stored(_ level: [String: String]) -> String? {
        switch level["kind"] {
        case "app": return app[provider]
        case "project": return level["path"].flatMap { projects[Self.canonical($0)]?[provider] }
        default: return level["key"].flatMap { seats[$0]?[provider] }
        }
    }

    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }
    /// The page's one folder rule (#530): the row, Switch now and the session list standardize both
    /// paths the same way, then ask "the same folder or inside it".
    static func within(_ path: String, _ folder: String) -> Bool {
        let path = canonical(path), folder = canonical(folder)
        return path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// The account a row would use with nothing set on it, and the words for where that comes from.
    func inherited(_ row: NativeAccountLevelRow) -> (id: String, from: String) {
        if row.kind == .lead || row.kind == .role, let project = row.project,
           let id = project.folders.lazy.compactMap({ self.projects[Self.canonical($0)]?[self.provider] }).first {
            return (id, project.name + " project")
        }
        if row.kind != .app, let id = app[provider] { return (id, "Terminal Deck default") }
        return (Self.systemID(provider), "this Mac’s own " + CodingAICatalog.label(provider) + " login")
    }

    func effective(_ row: NativeAccountLevelRow) -> (id: String, from: String) {
        if let id = assigned(row) { return (id, "set here") }
        if mixed(row) { return (Self.mixedID, "a different account in each folder") }
        return inherited(row)
    }

    /// The account a running session follows when it has no choice of its own.
    private func target(for session: NativeAccountSession, rows: [NativeAccountLevelRow]) -> String {
        if let row = rows.first(where: { $0.seatSessions.contains(session.id) }) { return effective(row).id }
        var best: (length: Int, id: String)?
        for (folder, choices) in projects {
            guard let id = choices[session.provider], Self.within(session.cwd, folder) else { continue }
            let length = Self.canonical(folder).count
            if length > (best?.length ?? -1) { best = (length, id) }
        }
        return best?.id ?? app[session.provider] ?? Self.systemID(session.provider)
    }

    private func sessions(under row: NativeAccountLevelRow) -> [NativeAccountSession] {
        sessions.filter { session in
            guard session.provider == provider else { return false }
            switch row.kind {
            case .app: return true
            case .project:
                guard let project = row.project else { return false }
                return session.projectID == project.id || project.folders.contains { Self.within(session.cwd, $0) }
            case .hoot, .lead, .role: return row.seatSessions.contains(session.id)
            }
        }
    }

    // MARK: Set (for everything started from now on)

    func set(_ row: NativeAccountLevelRow, account: String?, rows: [NativeAccountLevelRow]) {
        guard !fixture else { return }
        // Remember what the sessions under this row follow now, so a later Switch now can tell
        // "was following this row" from "chosen one by one".
        for session in sessions(under: row) { inheritedBefore[session.id] = target(for: session, rows: rows) }
        let provider = provider, before = row.levels.map { (level: $0, account: stored($0)) }
        Task {
            do {
                try await Self.setAll(before, to: account) { level, account in
                    _ = try await EngineBridge.shared.invoke("profiles:set-level", [level, provider, account ?? NSNull()] as [Any])
                }
                problem = nil
                NativeCodingAIPages.announceAccountsChanged()
            } catch {
                let text = CodingAIErrorText.from(error, fallback: "Could not change that account.")
                if Self.saysOlderHelper(text) { olderHelper = true; problem = nil } else { problem = text }
            }
            await reload()
        }
    }

    /// 18 Oct (#515): every folder of a row gets the new account, or none does: a failure halfway puts back the
    /// folders already written, so a project is never left half on the new account and half on the old one.
    static func setAll(_ levels: [(level: [String: String], account: String?)], to account: String?,
                       write: ([String: String], String?) async throws -> Void) async throws {
        var written: [(level: [String: String], account: String?)] = []
        do {
            for entry in levels { try await write(entry.level, account); written.append(entry) }
        } catch {
            for entry in written.reversed() { try? await write(entry.level, entry.account) }
            throw error
        }
    }

    // MARK: Switch now (also moves what is already running, in place)

    func planSwitch(_ row: NativeAccountLevelRow, rows: [NativeAccountLevelRow], names: [String: String]) {
        let chosen = Self.chosen
        var moves: [NativeAccountSwitchPlan.Move] = [], already = 0
        for session in sessions(under: row) {
            let now = session.accountID ?? Self.systemID(session.provider)
            let wanted = target(for: session, rows: rows)
            if now == wanted { already += 1; continue }
            let before = inheritedBefore[session.id]
            let individual = chosen.contains(session.id) || (before != nil && now != before)
            moves.append(.init(id: session.id, title: session.title, target: wanted, targetName: names[wanted] ?? wanted, individual: individual))
        }
        plan = NativeAccountSwitchPlan(rowTitle: row.title, moves: moves, alreadyThere: already)
    }

    func runPlan() {
        guard var current = plan, !current.running, !fixture else { return }
        current.running = true; plan = current
        let moving = current.toMove.map(\.id), keeping = Set(current.kept.map(\.id))
        Task {
            for id in moving {
                guard var live = plan, let index = live.moves.firstIndex(where: { $0.id == id }) else { continue }
                do {
                    // The same in-place switch the session's own chip uses: same terminal, same conversation, no restart.
                    _ = try await EngineBridge.shared.invoke("session:switch-account", [id, live.moves[index].target])
                    live.moves[index].result = "Switched"
                    Self.unmarkChosen(id); inheritedBefore[id] = nil
                } catch {
                    live.moves[index].result = CodingAIErrorText.from(error, fallback: "Could not switch this session.")
                    live.moves[index].failed = true
                }
                plan = live
            }
            if var live = plan {
                for index in live.moves.indices where keeping.contains(live.moves[index].id) { live.moves[index].result = "Kept its own account" }
                live.running = false; live.finished = true; plan = live
            }
            await reload()
        }
    }
}

/// The "Who uses what" section of Settings › Coding AIs.
struct NativeAccountLevelsSection: View {
    let accounts: [CodingAIAccount]
    var signIns: [String: CodingAISignIn] = [:]
    /// Accounts that are signed out or expired: a row that uses one offers "Sign in again".
    var signedOut: Set<String> = []
    /// The page's own default (an account row's "Use by default" writes the Whole Terminal Deck row).
    var defaultID: String? = nil
    var model = NativeAccountLevelsModel.shared
    /// Offscreen pictures pass fixed rows.
    var fixtureRows: [NativeAccountLevelRow]? = nil

    private var providers: [String] {
        let owned = Set(accounts.compactMap(\.provider))
        return ["claude", "codex", "gemini"].filter { owned.contains($0) }
    }
    private func choices() -> [CodingAIAccount] { CodingAILogins.oneRowPerEmail(accounts, signIn: signIns).filter { ($0.provider ?? "claude") == model.provider } }
    private func displayedSelection(_ id: String?) -> String {
        guard let id else { return "" }
        let original = CodingAILogins.duplicates(accounts, signIn: signIns)[id]
            ?? accounts.first { $0.id == id }
        guard let original, !original.system else { return "" }
        return original.id
    }
    private var names: [String: String] {
        Dictionary(accounts.map { ($0.id, $0.system ? $0.name + " (this Mac’s own login)" : $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        @Bindable var model = model
        let rows = fixtureRows ?? model.liveRows()
        Section {
            if model.olderHelper { NativeCodingAINotice(tone: .info, text: NativeAccountLevelsModel.olderHelperLine) }
            else if let problem = model.problem { NativeCodingAINotice(tone: .error, text: problem) }
            if providers.count > 1 {
                Picker("AI", selection: $model.provider) {
                    ForEach(providers, id: \.self) { DeckRowLabel.provider(CodingAICatalog.label($0), id: $0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            if rows.count > 8 || !model.search.isEmpty {
                TextField("Find a project or role", text: $model.search).textFieldStyle(.roundedBorder)
            }
            ForEach(rows) { row in rowView(row, rows: rows) }
        } header: {
            HStack {
                Text("Who uses what")
                Spacer()
                Button("Switch everything now") {
                    if let app = rows.first(where: { $0.kind == .app }) { model.planSwitch(app, rows: rows, names: names) }
                }
                .controlSize(.small)
                .disabled(model.olderHelper)
                .help("Move every running session to the account set for it here, without restarting any of them")
            }
        } footer: {
            Text("An account set here is used for everything started from now on. Switch now also moves what is already running, in place: same terminal, same conversation.")
        }
        .task { model.start() }
        // An account added, removed, renamed or made the default from the list above shows here at once.
        .onChange(of: accounts) { _, _ in Task { await model.reload() } }
        .onChange(of: defaultID) { _, _ in Task { await model.reload() } }
        .sheet(item: $model.plan) { _ in NativeAccountSwitchSheet(model: model) }
    }

    private func rowView(_ row: NativeAccountLevelRow, rows: [NativeAccountLevelRow]) -> some View {
        let effective = model.effective(row), inherited = model.inherited(row)
        return HStack(spacing: 10) {
            picture(row).frame(width: 22, height: 22).padding(.leading, row.indented ? 22 : 0)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.title).fontWeight(row.indented ? .regular : .medium).lineLimit(1)
                    if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Text(effective.id == NativeAccountLevelsModel.mixedID ? "Uses " + effective.from : "Uses \(names[effective.id] ?? effective.id) · \(effective.from)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if signedOut.contains(effective.id), let account = accounts.first(where: { $0.id == effective.id }) {
                    // Signing in again keeps everything assigned to this account as it is.
                    Button("\(account.name) is signed out. Sign in again") {
                        if NativeAccountSignInModel.canDrive(account.provider), !account.system { NativeAccountSignInModel.shared.start(account: account) }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            Spacer(minLength: 8)
            Picker("Account for \(row.title)", selection: Binding(get: { model.mixed(row) ? NativeAccountLevelsModel.mixedID : displayedSelection(model.assigned(row)) },
                                                                    set: { if $0 != NativeAccountLevelsModel.mixedID { model.set(row, account: $0.isEmpty ? nil : $0, rows: rows) } })) {
                if model.mixed(row) {
                    DeckRowLabel("Different in each folder", image: DeckRowIcon.symbolIcon("square.split.2x1")).tag(NativeAccountLevelsModel.mixedID)
                }
                DeckRowLabel(row.kind == .app ? "This Mac’s own login" : "Same as above · " + (names[inherited.id] ?? inherited.id),
                             image: DeckRowIcon.symbolIcon(row.kind == .app ? "laptopcomputer" : "arrow.turn.left.up")).tag("")
                ForEach(choices().filter { !$0.system }) { account in
                    DeckRowLabel(account.name, image: DeckRowIcon.provider(model.provider)).tag(account.id)
                }
            }
            .labelsHidden().fixedSize()
            .disabled(model.olderHelper)
            Button("Switch now") { model.planSwitch(row, rows: rows, names: names) }
                .controlSize(.small)
                .disabled(model.olderHelper)
                .help("Also move the sessions already running under \(row.title)")
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder private func picture(_ row: NativeAccountLevelRow) -> some View {
        switch row.kind {
        case .app: Image(systemName: "macwindow").foregroundStyle(.secondary)
        case .hoot: HootMark(size: 20, animated: false)
        case .project: ProjectLogoView(project: row.project, name: row.title, size: 22)
        case .lead: Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(.secondary)
        case .role: Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
        }
    }
}

/// "Switch now": exactly what will move, the tick for individually set ones, then each result.
struct NativeAccountSwitchSheet: View {
    @Bindable var model: NativeAccountLevelsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let plan = model.plan {
            VStack(alignment: .leading, spacing: 12) {
                Text("Switch \(plan.rowTitle) now").font(.headline)
                if plan.moves.isEmpty {
                    Text(plan.alreadyThere == 0 ? "Nothing is running here, so there is nothing to move."
                         : "All \(plan.alreadyThere) running sessions here already use the account set for them.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(summary(plan)).fixedSize(horizontal: false, vertical: true)
                    if plan.moves.contains(where: \.individual), !plan.finished {
                        Toggle("Also change the ones set individually", isOn: Binding(get: { plan.includeIndividual },
                                                                                       set: { model.plan?.includeIndividual = $0 }))
                            .disabled(plan.running)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(plan.moves) { move in
                                HStack(spacing: 8) {
                                    Image(systemName: move.failed ? "exclamationmark.triangle" : move.result == "Switched" ? "checkmark.circle" : "terminal")
                                        .foregroundStyle(move.failed ? Color.orange : move.result == "Switched" ? Color.green : Color.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(move.title).lineLimit(1)
                                        Text(move.result ?? (move.individual && !plan.includeIndividual ? "Keeps its own account" : "Moves to \(move.targetName)"))
                                            .font(.caption).foregroundStyle(move.failed ? Color.orange : Color.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                HStack {
                    Spacer()
                    if plan.finished || plan.moves.isEmpty {
                        Button("Done") { model.plan = nil; dismiss() }.keyboardShortcut(.defaultAction)
                    } else {
                        Button("Cancel") { model.plan = nil; dismiss() }.disabled(plan.running)
                        Button(plan.running ? "Switching…" : "Switch now") { model.runPlan() }
                            .buttonStyle(.borderedProminent).disabled(plan.running || plan.toMove.isEmpty)
                    }
                }
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private func summary(_ plan: NativeAccountSwitchPlan) -> String {
        let moving = plan.toMove.count, kept = plan.kept.count
        var text = "\(moving) running session" + (moving == 1 ? "" : "s") + " will move, without restarting."
        if kept > 0 { text += " \(kept) keep" + (kept == 1 ? "s its" : " their") + " own choice." }
        if plan.alreadyThere > 0 { text += " \(plan.alreadyThere) already there." }
        return text
    }
}

/// "5 hours 12% · week 40%" for one account, where the app has a reading.
struct NativeAccountUsageLine: View {
    let accountID: String
    var model = NativeAccountLevelsModel.shared

    var body: some View {
        if let line = model.usage[accountID], !line.isEmpty {
            Label(line, systemImage: "gauge.with.dots.needle.33percent").font(.caption).foregroundStyle(.secondary)
        }
    }
}
