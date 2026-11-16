import Foundation
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Sessions and chats in the Cloud, step 1, the Mac's driver (owner, 15 Nov 2026: every session and chat of his account
/// on every device, by account; one small tag with the machine's name; chats kept in the Cloud until he deletes them).
/// - Every 30 s: this Mac's list (the sessions its side panel lists, Hoot's chat included) and what each session's
///   chat added since, in ONE call (`BackendCloudChatsUploader.round`); nothing at all while nothing grew.
/// - In the background, at background priority, one piece every 2 s: old histories catch up, readable copies first.
/// - Every minute: the account's sessions of his OTHER machines, for the side panel (each with its machine's tag);
///   every 5 minutes: the closed sessions whose chats are kept ("Earlier chats").
/// Quiet: signed out, Cloud off on this Mac, Cloud paused, "Sessions and chats" off for this device, or the service part
/// not live (its routes missing): nothing is sent, no page shows an error, it is tried again at the next launch.
@MainActor @Observable
final class NativeCloudChats {
    static let shared = NativeCloudChats()

    /// THE one question "is this kind in sync on this device" for sessions and chats. Yes by default. The per-device
    /// sync choice ("Sessions and chats", lane/same-everywhere) connects its switch by setting this, once, at launch.
    static var sessionsAndChatsInSync: @MainActor () -> Bool = { true }

    /// Other machines' sessions of his account (never this Mac's own), newest use first.
    private(set) var others: [BackendCloudSessionsRead.Row] = []
    /// Closed sessions whose chat is kept, every machine's, by the project they were in ("" = Independent).
    private(set) var earlier: [String: [BackendCloudSessionsRead.Row]] = [:]
    /// Every open session of the account, this Mac's own included (the Your Cloud page lists them all).
    private(set) var open: [BackendCloudSessionsRead.Row] = []
    /// Every session and chat of the account the Cloud holds: open ones and earlier chats, newest use first.
    var all: [BackendCloudSessionsRead.Row] {
        var seen = Set<String>()
        return (open + earlier.values.flatMap { $0 }).filter { seen.insert($0.ref).inserted }.sorted { ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0) }
    }
    /// The account's machines by ref, with their current names and on/off.
    private(set) var machines: [String: BackendCloudSessionsRead.Machine] = [:]

    @ObservationIgnored private var uploader: BackendCloudChatsUploader?
    /// The delete rule's owner of chats (the Your Cloud page's "Sessions and chats" and an AI's `cloud.delete`).
    @ObservationIgnored private(set) var deleteOwner: BackendCloudChatsDeleteOwner?
    @ObservationIgnored private var send: BackendCloudChatsUploader.Send?
    @ObservationIgnored private var list: (@Sendable () async -> [BackendCloudChatsListedSession])?
    @ObservationIgnored private var locator: BackendCloudChatsLocator?
    @ObservationIgnored private var hootID: String?
    @ObservationIgnored private var salt: String?
    @ObservationIgnored private var knownNames: (@Sendable () async -> [String: String])?
    /// Earlier chats: Terminal Deck's own past histories on this Mac are looked for at launch and every 6 hours.
    @ObservationIgnored private var scannedAt: Int64 = 0
    static let scanEveryMs: Int64 = 6 * 3_600_000
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var catchUp: Task<Void, Never>?
    @ObservationIgnored private var listed: [BackendCloudChats.Listed] = []
    @ObservationIgnored private var othersAt: Int64 = 0
    @ObservationIgnored private var earlierAt: Int64 = 0
    @ObservationIgnored var tick: Duration = .seconds(30)
    static let othersEveryMs: Int64 = 60_000
    static let earlierEveryMs: Int64 = 300_000

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // Step 2, "Switch to this Mac" (NativeCloudChatsMove.swift's part of this class).
    /// The moves this Mac takes part in, by the session's ref (the page's one line and its button).
    private(set) var moves: [String: BackendCloudSessionMoveEntry] = [:]
    /// A refusal that started nothing (no sign-in for that AI here, another Mac's move under way): its one line.
    var moveNotes: [String: String] = [:]
    /// The done line of a move, by the session it started here: shown ONCE on that session's own bar, then gone.
    var arrivals: [String: String] = [:]
    @ObservationIgnored private var arrived: Set<String> = []
    @ObservationIgnored var mover: BackendCloudSessionMove?
    /// The app's own close, create and AI logins (the composition, once).
    @ObservationIgnored var moveHooks: NativeCloudMoveHooks?
    /// Each listed session as last seen, by its Cloud id (the old Mac's flush needs it after the close).
    @ObservationIgnored var seenMeta: [String: BackendSessionMeta] = [:]
    /// When this Mac last backed a project up (its list rows' `codeAt`); the Code page's actions, once.
    nonisolated(unsafe) static var codeAt: @Sendable (String) async -> Int64? = { _ in nil }
    func noteMove(_ entry: BackendCloudSessionMoveEntry) {
        moves[entry.ref] = entry
        if entry.role == .taker, entry.step == .done, let id = entry.launchedID, let line = entry.line, arrived.insert(entry.moveId).inserted {
            arrivals[id] = line
        }
        // A finished move changes where the session runs: the lists are read again at once.
        if entry.finished { refreshSoon() }
    }
    var listReader: (@Sendable () async -> [BackendCloudChatsListedSession])? { list }
    var chatsLocator: BackendCloudChatsLocator? { locator }

    /// Called once the identity's sync core exists (beside the shelf): one uploader per identity.
    func attach(send: @escaping BackendCloudChatsUploader.Send, directory: URL, deviceId: String) {
        detach()
        let uploader = BackendCloudChatsUploader(send: send, directory: directory)
        self.uploader = uploader
        self.send = send
        deleteOwner = BackendCloudChatsDeleteOwner(bin: { ref, session, action in
            let done = await uploader.bin(session: session, ref: ref, action: action)
            // The lists show the change at once (a binned chat leaves every list; a restored one comes back).
            await MainActor.run { NativeCloudChats.shared.refreshSoon() }
            return done
        }, file: directory.appendingPathComponent("bin.json"))
        // Hoot's chat: one per machine, under an id no other machine can have.
        hootID = "hoot-" + String(BackendCloudChats.hex(Data(deviceId.utf8)).prefix(24))
        salt = deviceId
        attachMove(send: send, uploader: uploader, file: directory.deletingLastPathComponent().appendingPathComponent("cloud-moves.json"))
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.round(uploader)
                try? await Task.sleep(for: self?.tick ?? .seconds(30))
            }
        }
        catchUp = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                guard let self, self.uploader === uploader else { return }
                let listed = self.listed
                let sent = self.ready && !listed.isEmpty ? await uploader.catchUpStep(listed) : false
                try? await Task.sleep(for: sent ? .seconds(2) : .seconds(60))
            }
        }
    }
    /// The session list's reader and where histories live (the app's composition, once).
    func bind(list: @escaping @Sendable () async -> [BackendCloudChatsListedSession], names: (@Sendable () async -> [String: String])? = nil,
              locator: BackendCloudChatsLocator) {
        self.list = list
        self.knownNames = names
        self.locator = locator
    }
    /// Sign-out: nothing more is read or sent for that identity; the other machines' rows leave the side panel.
    func detach() {
        loop?.cancel(); loop = nil
        catchUp?.cancel(); catchUp = nil
        uploader = nil; deleteOwner = nil; send = nil; hootID = nil; salt = nil; listed = []; scannedAt = 0
        mover = nil; moves = [:]; moveNotes = [:]; seenMeta = [:]
        others = []; open = []; earlier = [:]; machines = [:]; othersAt = 0; earlierAt = 0
    }

    /// Signed in, Cloud on here ("Use Cloud on this Mac"), not paused, and this kind in sync on this device.
    var ready: Bool {
        let account = NativeCloudAccount.shared
        let snapshot = account.snapshot
        return uploader != nil && snapshot.visible(at: Self.now()) && account.memoryIncluded != false
            && snapshot.phase != .paused && Self.sessionsAndChatsInSync()
    }

    func round(_ uploader: BackendCloudChatsUploader) async {
        guard self.uploader === uploader, ready, let list, let locator else { return }
        if await uploader.missing { return }
        let sessions = await list()
        let projects = SIDEBARProjectStore.shared.projects.isEmpty ? PROJProjects.defaults : SIDEBARProjectStore.shared.projects
        // The side panel's own title for each session (a name he gave, else its title), as the phones get it.
        let names = Dictionary(sessions.map { item -> (String, String) in
            let meta = item.meta
            return (meta.id, SIDEBARSessionLine.title(given: NativeSessionNames.shared.names[meta.id], own: SIDEBARProjectStore.shared.sessionTitles[meta.id],
                                                       rail: meta.title, folder: meta.cwd))
        }, uniquingKeysWith: { first, _ in first })
        let hootID = self.hootID
        // Finding the files reads directories only; off the main thread at low priority.
        let made: [BackendCloudChats.Listed] = await Task.detached(priority: .utility) {
            var rows = sessions.map { item in
                BackendCloudChats.Listed(row: BackendCloudChats.row(item, name: names[item.meta.id], projects: projects), source: locator.source(item.meta))
            }
            // Step 2: when each project was last backed up here ("the code here is from <time>" on the Mac that takes it).
            for index in rows.indices { if let project = rows[index].row.project { rows[index].row.codeAt = await NativeCloudChats.codeAt(project.cloudRef) } }
            if let hootID, let source = locator.hootSource(), let file = source.snap,
               let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                rows.append(.init(row: .init(sessionId: hootID, name: "Hoot", lastUsedAt: Int64(changed.timeIntervalSince1970 * 1000),
                                             ai: source.provider?.rawValue, kind: "hoot", status: "idle"), source: source))
            }
            return rows
        }.value
        guard self.uploader === uploader, ready else { return }
        listed = made
        for item in sessions { seenMeta[BackendCloudChats.cloudID(item.meta)] = item.meta }
        if await uploader.round(made) == .missing { return }
        await scanEarlier(uploader, listed: made, projects: projects)
        await readOthers()
    }

    /// Earlier chats: every past history in Terminal Deck's own AI login folders and every saved app chat no longer
    /// open, found once per launch (and every 6 hours), handed to the uploader, which copies them after the listed
    /// sessions' catch-up. Folders and first lines only; in the background.
    func scanEarlier(_ uploader: BackendCloudChatsUploader, listed: [BackendCloudChats.Listed], projects: [PROJProject]) async {
        guard let locator, let salt, Self.now() - scannedAt >= Self.scanEveryMs else { return }
        scannedAt = Self.now()
        var skip = await uploader.archiveSkip()
        for item in listed {
            for url in [item.source.raw, item.source.snap].compactMap({ $0 }) + item.source.tools { skip.insert(url.path) }
        }
        let names = await knownNames?() ?? [:]
        let frozen = skip
        let found = await Task.detached(priority: .background) {
            BackendCloudChatsArchive.scan(homes: locator.ownHomes(), chats: locator.chats, skip: frozen, knownNames: names)
        }.value
        guard self.uploader === uploader else { return }
        await uploader.addArchive(found, salt: salt, projects: projects)
    }

    /// Other machines' sessions (every minute) and the kept chats of closed sessions (every 5 minutes).
    func readOthers() async {
        guard let send, let uploader, ready, !(await uploader.missing) else { return }
        let now = Self.now()
        if now - othersAt >= Self.othersEveryMs {
            othersAt = now
            if let read = await BackendCloudSessionsRead.list(send, earlier: false) {
                machines = Dictionary(read.machines.compactMap { machine in machine.ref.map { ($0, machine) } }, uniquingKeysWith: { first, _ in first })
                open = read.rows.sorted { ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0) }
                others = open.filter { $0.mine != true }
                // Step 2's fallback to the socket: a session of this Mac another Mac asked for.
                for row in open where row.mine == true && row.move != nil { Task { await self.mover?.hint(ref: row.ref) } }
            }
        }
        if now - earlierAt >= Self.earlierEveryMs {
            earlierAt = now
            if let read = await BackendCloudSessionsRead.list(send, earlier: true) {
                // Newest use first, by the history's own date (an earlier chat copied today is not "today").
                earlier = Dictionary(grouping: read.rows.sorted { ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0) }) { $0.project?.cloudRef ?? "" }
            }
        }
    }

    /// The next look reads the account's lists again (after a chat went to the Bin or came back).
    func refreshSoon() {
        othersAt = 0; earlierAt = 0
        Task { [weak self] in await self?.readOthers() }
    }
    /// The delete door's targets: every chat of the account the Cloud holds, named as the page names it.
    func deleteTargets() -> [BackendCloudDeleteDoor.Target] {
        BackendCloudChatsContents.items(all).flatMap { item in
            item.deleteItems.map { BackendCloudDeleteDoor.Target(item: $0, placeName: item.place) }
        }
    }

    /// One page of a session's readable copy, for the read-only view (nil: not readable now).
    func chat(ref: String, before: Int? = nil, after: Int? = nil) async -> BackendCloudSessionsRead.ChatPage? {
        guard let send, ready else { return nil }
        return await BackendCloudSessionsRead.chat(send, ref: ref, before: before, after: after)
    }
    func row(ref: String) -> BackendCloudSessionsRead.Row? {
        others.first { $0.ref == ref } ?? open.first { $0.ref == ref } ?? earlier.values.lazy.flatMap { $0 }.first { $0.ref == ref }
    }

    /// `cloud.status`'s `sessions`: how many sessions this Mac lists and how far their chats are up. Read only.
    func wire() async -> NativeRPCValue? {
        guard let uploader else { return nil }
        var value = await uploader.wire()
        value = value.setting("otherMachinesSessions", .number(Double(others.count)))
        return value
    }

    // MARK: Words

    /// The one line on top of another machine's chat.
    static func runsOn(_ machine: String, on: Bool, closed: Bool = false) -> String {
        if closed { return "Ran on " + machine }
        return on ? "Runs on " + machine : "Runs on " + machine + ", which is off"
    }
    static let earlierTitle = "Earlier chats"
}

/// Where other machines' sessions sit in the side panel's session list (pure, tested): each one right after the last
/// of this Mac's own sessions in the same project, so a project's sessions stay together whichever Mac runs them; a
/// project with no session here gets its other machines' sessions at the end, newest use first. This Mac's own rows
/// keep exactly their order. "Earlier chats" is one quiet row after the last session of a project whose closed
/// sessions' chats are kept; when no listed project has any, one such row ends the list.
enum SIDEBARCloudRows {
    static let sessionPrefix = "cloud-session:"
    static let earlierPrefix = "cloud-earlier:"

    enum Entry: Identifiable, Equatable {
        case own(String)
        case other(BackendCloudSessionsRead.Row)
        case earlier(String)
        var id: String {
            switch self {
            case .own(let id): return id
            case .other(let row): return SIDEBARCloudRows.sessionPrefix + row.ref
            case .earlier(let project): return SIDEBARCloudRows.earlierPrefix + project
            }
        }
    }

    /// `own`: this Mac's rows in drawn order with their project ids (nil: Independent). `others`: other machines' rows.
    /// `earlier`: project ids ("" = Independent) with kept chats of closed sessions.
    static func merge(own: [(id: String, project: String?)], others: [BackendCloudSessionsRead.Row], earlier: Set<String>) -> [Entry] {
        var entries = own.map { Entry.own($0.id) }
        var keys = own.map { $0.project ?? "" }
        let grouped = Dictionary(grouping: others) { $0.project?.cloudRef ?? "" }
        let order = grouped.keys.sorted { a, b in
            let x = grouped[a]?.map { $0.lastUsedAt ?? 0 }.max() ?? 0, y = grouped[b]?.map { $0.lastUsedAt ?? 0 }.max() ?? 0
            return x == y ? a < b : x > y
        }
        for key in order {
            let rows = (grouped[key] ?? []).sorted { ($0.lastUsedAt ?? 0) > ($1.lastUsedAt ?? 0) }
            let at = keys.lastIndex(of: key).map { $0 + 1 } ?? entries.count
            entries.insert(contentsOf: rows.map(Entry.other), at: at)
            keys.insert(contentsOf: Array(repeating: key, count: rows.count), at: at)
        }
        // Earlier chats: after each project's last row; the later positions first so the earlier ones stay put.
        let places = earlier.compactMap { key in keys.lastIndex(of: key).map { (key, $0 + 1) } }.sorted { $0.1 > $1.1 }
        for (key, at) in places { entries.insert(.earlier(key), at: at); keys.insert(key, at: at) }
        if places.isEmpty, !earlier.isEmpty { entries.append(.earlier("")) }
        return entries
    }
}
