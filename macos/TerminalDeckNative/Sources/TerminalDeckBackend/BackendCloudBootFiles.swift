import Foundation
import Darwin
import TerminalDeckNativeCore

/// One place boot files live on THIS Mac: the folder the person chose for a project, or the settings folder
/// ("home") of one AI account the app manages. Given by the wiring from the app's own project and account lists;
/// lane F finds no folder by itself.
public struct BackendCloudBootFilesPlace: Sendable, Equatable {
    public let kind: CloudBootFilesPlaceKind
    /// What travels: the project id, or the account home's identity. The same on every Mac. Never a path or a
    /// folder name.
    public let identity: String
    /// This Mac's folder. It never travels.
    public let root: URL
    /// For a project: true only when the person CHOSE `root` as this project's boot-file folder on this Mac (lane A2's
    /// project-to-folder mapping). Never "the project's first folder": the project list sorts its folders, so adding
    /// one could silently move where boot files land (security review S2). A project place without it is not used:
    /// its files wait, with the reason `no-chosen-folder`. Ignored for an AI account home.
    public let chosen: Bool
    public init(kind: CloudBootFilesPlaceKind, identity: String, root: URL, chosen: Bool = false) {
        self.kind = kind; self.identity = identity; self.root = root; self.chosen = chosen
    }
    public var sourceId: String { BackendCloudBootFiles.sourceId(kind: kind, identity: identity) }
}

/// Lean first version, item 8 (inventory row I09): boot files as records of lane A's file engine.
///
/// Lane A's engine is used for what it is good at: versions, the journal, the parts on the wire, checking and
/// keeping arrived bytes. It is NEVER given a folder the person owns. It reads and writes one private folder, this
/// Mac's copy of the Cloud's boot files (`copy/<place>/<path>` inside the signed-in identity's Cloud folder).
/// Everything between that copy and a real folder goes through `BackendCloudBootFilesDisk` and
/// `CloudBootFilesRules`, in both directions, one file at a time:
///
///     folder  --(read without following links; allow-list; text; size)-->  copy  --engine-->  Cloud
///     Cloud  --engine (refusals first)-->  copy  --(the decision below)-->  folder
///
/// The decision for one path uses three fingerprints (`CloudBootFilesRules.step`): the file in the folder, the
/// copy, and the bytes both last agreed on. Construction opens nothing; with Cloud off nothing here ever runs.
public actor BackendCloudBootFiles {
    public nonisolated let inventoryRows: [String]
    let deviceId: String
    let stateRoot: URL
    let now: @Sendable () -> Int64
    var places: [String: BackendCloudBootFilesPlace] = [:]
    var order: [String] = []
    var pump: BackendCloudBrainFilesPump?
    var outbox: (any CloudOutboxPort)?
    var subjectHash: String?
    private var built: BackendCloudBrainFiles?
    private var opened: BackendCloudBrainFilesDatabase?
    private var keeperMade: BackendCloudVersionKeeper?
    /// Where older versions are kept 30 days (the one rule). Beside this identity's other Cloud folders by default.
    let versionsRoot: URL
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// Paths seen absent once. A removal is recorded only when the file is still absent at the next look, so an
    /// editor that deletes and rewrites a file is not read as a removal.
    private var missing: [String: Int64] = [:]
    private var witness = CloudDeleteWitnessSlot.shared
    var deleteRuleOpen: @Sendable () async -> Bool = { false }
    var macName: @Sendable (String) async -> String? = { _ in nil }
    /// Review 15 Nov (MUST 4): has a device announced the delete rule? Until set, every device has (the safe reading).
    var deleteRuleAnnounced: @Sendable (String) async -> Bool = { _ in true }
    /// One `CloudDeleteState` per owner (its tables are made once, not at every file of every look).
    var deleteStateMade: CloudDeleteState?
    /// Tests only: a named point of a removal where a crash is simulated by throwing.
    var crashPointForTests: (@Sendable (String) throws -> Void)?
    func setCrashPointForTests(_ hook: (@Sendable (String) throws -> Void)?) { crashPointForTests = hook }
    public func setDeleteRuleGate(_ gate: @escaping @Sendable () async -> Bool) { deleteRuleOpen = gate }
    public func setDeleteRuleAnnounced(_ read: @escaping @Sendable (String) async -> Bool) { deleteRuleAnnounced = read }
    public func setMacName(_ read: @escaping @Sendable (String) async -> String?) { macName = read }
    func setDeleteWitness(_ slot: CloudDeleteWitnessSlot) { witness = slot }
    /// Places given to `setPlaces` and not used, with why (`no-chosen-folder`, `home-folder`). Their files wait.
    var refusedPlaces: [String: String] = [:]

    public static let waitingForFolder = "Waiting for a folder on this Mac."
    /// Owner, 13 Nov: with "Automatically, with my account" a file that can run a command or grant tools is applied
    /// without the Accept step, and listed under "Changed from your other devices" with "Put the earlier version
    /// back" like every other file applied by itself. In "Ask me for each new device" it waits for Accept as before.
    /// Off unless the composition turns it on; no tool reaches it.
    private(set) var autoAccept = false
    public func setAutoAccept(_ on: Bool) { autoAccept = on }
    /// Runs before each project place is looked at (`BackendAISetupKeeper.align(project:)` in the app).
    private(set) var setupKeeper: (@Sendable (URL) -> Void)?
    public func setSetupKeeper(_ keeper: (@Sendable (URL) -> Void)?) { setupKeeper = keeper }
    /// The daily sweep deletes only on the service clock: a Mac clock that jumps forward must not delete what is kept.
    /// Without a sync core there is no service clock; tests turn this on to sweep on their own clock.
    private(set) var sweepOnLocalClock = false
    func setSweepOnLocalClock(_ on: Bool) { sweepOnLocalClock = on }
    /// Proof 2 (13 Nov): told (outside this adapter's job, never awaited by it) after a pack from another device was
    /// applied here, so the Cloud page's list and the places are looked at again without a page visit.
    var arrivalNotice: (@Sendable () async -> Void)?
    public func setArrivalNotice(_ notice: (@Sendable () async -> Void)?) { arrivalNotice = notice }

    /// `now`: the sync core's service clock (`outbox.serviceTime()`), falling back to this Mac's clock.
    public init(deviceId: String, stateRoot: URL, versionsRoot: URL? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard UUID(uuidString: deviceId) != nil, stateRoot.isFileURL else { throw CloudFailure.invalidRequest }
        inventoryRows = [CloudBootFilesFormat.inventoryRow]
        self.deviceId = deviceId.lowercased(); self.stateRoot = stateRoot; self.now = now
        self.versionsRoot = versionsRoot ?? BackendCloudVersionKeeper.root(besideStateRoot: stateRoot)
    }

    /// The 30-day keeper of older versions (the one rule, first slice: instruction files).
    func keeper() -> BackendCloudVersionKeeper {
        if let keeperMade { return keeperMade }
        let made = BackendCloudVersionKeeper(root: versionsRoot)
        keeperMade = made
        return made
    }

    // MARK: Identity of a place (what the key is made of)

    /// `project/<project id>` or `home/<provider>/<home identity>`, each id as lane A's reversible token.
    /// A record's key is `file/<this>/<path relative to the place>`: never an absolute path, never a folder name.
    public static func sourceId(kind: CloudBootFilesPlaceKind, identity: String) -> String {
        let token = BackendCloudBrainFilesNames.token(identity)
        return kind == .project ? "project/" + token : "home/" + kind.rawValue + "/" + token
    }
    static func parse(sourceId: String) -> (kind: CloudBootFilesPlaceKind, token: String)? {
        let fields = sourceId.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        func token(_ text: String) -> Bool {
            !text.isEmpty && text.utf8.count <= 80 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || $0 == 104 }
        }
        if fields.count == 2, fields[0] == "project", token(fields[1]) { return (kind: CloudBootFilesPlaceKind.project, token: fields[1]) }
        if fields.count == 3, fields[0] == "home", let kind = CloudBootFilesPlaceKind(rawValue: fields[1]), kind != .project, token(fields[2]) {
            return (kind: kind, token: fields[2])
        }
        return nil
    }
    static func coverageId(_ sourceId: String) -> String { "files/" + CloudBootFilesFormat.inventoryRow + "/" + sourceId }

    // MARK: One job at a time

    func enter() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in waiters.append(continuation) }
    }
    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: State

    static let schema = """
        CREATE TABLE IF NOT EXISTS boot_base(source_id TEXT NOT NULL, path TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY(source_id, path));
        CREATE TABLE IF NOT EXISTS boot_accepted(source_id TEXT NOT NULL, path TEXT NOT NULL, hash TEXT NOT NULL, at INTEGER NOT NULL,
            PRIMARY KEY(source_id, path, hash));
        CREATE TABLE IF NOT EXISTS boot_origin(source_id TEXT NOT NULL, path TEXT NOT NULL, hash TEXT NOT NULL, origin TEXT NOT NULL,
            PRIMARY KEY(source_id, path, hash));
        CREATE TABLE IF NOT EXISTS boot_items(id TEXT PRIMARY KEY, kind TEXT NOT NULL, source_id TEXT NOT NULL, identity TEXT, path TEXT NOT NULL,
            hash TEXT NOT NULL, bytes INTEGER NOT NULL, origin TEXT NOT NULL, reasons TEXT NOT NULL, at INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS boot_items_path ON boot_items(source_id, path);
        CREATE TABLE IF NOT EXISTS boot_applied(seq INTEGER PRIMARY KEY AUTOINCREMENT, source_id TEXT NOT NULL, path TEXT NOT NULL, hash TEXT NOT NULL,
            origin TEXT NOT NULL, how TEXT NOT NULL, at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS boot_versions(source_id TEXT NOT NULL, path TEXT NOT NULL, version TEXT NOT NULL, hash TEXT NOT NULL,
            PRIMARY KEY(source_id, path, version));
        CREATE TABLE IF NOT EXISTS boot_meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS boot_replaced(seq INTEGER PRIMARY KEY, hash TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS boot_replaced_hash ON boot_replaced(hash);
        """

    /// Lane F's own small bookkeeping (what both sides last agreed on, what waits, what was accepted, what was
    /// written from another device). Its own file; it never opens lane A's database.
    func state() throws -> BackendCloudBrainFilesDatabase {
        if let opened { return opened }
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let db = try BackendCloudBrainFilesDatabase(path: stateRoot.appendingPathComponent("boot.db").path)
        try db.exec(Self.schema)
        try CloudFileDeleteRecords.create(in: db)
        try db.exec("CREATE TABLE IF NOT EXISTS boot_seen(place TEXT PRIMARY KEY, at INTEGER NOT NULL);")
        opened = db
        return db
    }

    var copyRoot: URL { stateRoot.appendingPathComponent("copy", isDirectory: true) }
    /// This Mac's copy of the Cloud's boot files for one place. Private to the app; no AI tool reads it.
    func copy(_ sourceId: String) -> URL { copyRoot.appendingPathComponent(sourceId, isDirectory: true) }

    /// Lane A's engine over the private copy. Built again whenever the set of places changes: a place this Mac
    /// has is a walked source; a place it does not have is a source whose records wait.
    func core() throws -> BackendCloudBrainFiles {
        if let built { return built }
        let fm = FileManager.default
        let idle = stateRoot.appendingPathComponent("copy-idle", isDirectory: true)
        try fm.createDirectory(at: idle, withIntermediateDirectories: true)
        var sources: [BackendCloudBrainFilesSource] = []
        for id in order {
            guard let place = places[id] else { continue }
            try fm.createDirectory(at: copy(id), withIntermediateDirectories: true)
            sources.append(Self.source(place, copy: copy(id)))
        }
        // The engine wants at least one source. This one matches nothing lane F accepts.
        sources.append(BackendCloudBrainFilesSource(sourceId: "idle", root: idle, include: ["idle"], projection: .archiveOnly("idle")))
        let made = try BackendCloudBrainFiles(inventoryRow: CloudBootFilesFormat.inventoryRow, deviceId: deviceId,
                                              stateRoot: stateRoot.appendingPathComponent("engine", isDirectory: true), sources: sources,
                                              dynamicSource: Self.elsewhere(idle.appendingPathComponent("not-on-this-mac", isDirectory: true)), now: now)
        built = made
        return made
    }

    static func source(_ place: BackendCloudBootFilesPlace, copy: URL) -> BackendCloudBrainFilesSource {
        let project: String? = place.kind == .project ? place.identity : nil
        return BackendCloudBrainFilesSource(
            sourceId: place.sourceId, root: copy, include: CloudBootFilesRules.patterns(place.kind), exclude: BackendCloudBrainFilesNames.locks,
            projection: .custom({ incoming in .write(copy.appendingPathComponent(incoming.relative), incoming.bytes) }),
            project: { _ in project.map { (projectId: $0, rootId: CloudBootFilesFormat.projectRoot) } },
            // The one rule: a version's time is when the person's file was changed, not when this Mac recorded it.
            modifiedAt: { [root = place.root] relative in BackendCloudBootFiles.modifiedTime(root: root, relative: relative) })
    }
    /// The modification time (ms) of the file at `relative` itself, never through a link at its last part.
    static func modifiedTime(root: URL, relative: String) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
    /// A place this Mac does not have: its records are checked and kept by the engine and WAIT. Nothing is written.
    static func elsewhere(_ placeholder: URL) -> @Sendable (String) -> BackendCloudBrainFilesSource? {
        { id in
            guard let parsed = BackendCloudBootFiles.parse(sourceId: id) else { return nil }
            return BackendCloudBrainFilesSource(sourceId: id, root: placeholder, include: CloudBootFilesRules.patterns(parsed.kind),
                                                exclude: BackendCloudBrainFilesNames.locks,
                                                projection: .custom({ _ in .waiting(BackendCloudBootFiles.waitingForFolder) }))
        }
    }

    // MARK: Places

    /// Folders a project's boot files must never land in or above (security review S3): this Mac's home folder and
    /// the standard settings folders of the AI tools in it. `setPlaces` adds every account home it is given.
    public static func defaultAccountHomes() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home] + [".claude", ".codex", ".gemini", ".agents"].map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// Why a place is not used, or nil. A project needs a folder the person chose (S2), and that folder may not be
    /// `/`, the home folder, an AI account home or a folder above one (S3): its `.claude/agents` would be the GLOBAL
    /// `~/.claude/agents` and its `CLAUDE.md` would be read for every project below it.
    public static func placeRefusal(_ place: BackendCloudBootFilesPlace, accountHomes: [URL]) -> String? {
        guard place.kind == .project else { return nil }
        guard place.chosen else { return "no-chosen-folder" }
        // Both spellings (as given and with links resolved); letter case ignored, as the disk ignores it.
        func forms(_ url: URL) -> [String] {
            [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path].map { $0.lowercased() }
        }
        let homes = accountHomes.flatMap(forms)
        for root in forms(place.root) {
            if root == "/" || root.isEmpty { return "home-folder" }
            let trimmed = root.hasSuffix("/") ? String(root.dropLast()) : root
            if homes.contains(where: { $0 == trimmed || $0.hasPrefix(trimmed + "/") }) { return "home-folder" }
        }
        return nil
    }

    /// The places boot files live on this Mac NOW. Call at start and whenever a project gets or loses its folder
    /// or an AI account is added or removed. Files that waited for one of these places are placed.
    /// A project is used only with the folder the person chose for it on this Mac (`chosen`), and never when that
    /// folder is the home folder or holds an AI account home (`accountHomes` adds to `defaultAccountHomes()`):
    /// such a project's files wait, listed with the reason. Neither is an error.
    public func setPlaces(_ next: [BackendCloudBootFilesPlace], accountHomes: [URL] = []) async throws {
        try await setPlacesHeld(next, accountHomes: accountHomes)
        await coverageChanged()
    }
    private func setPlacesHeld(_ next: [BackendCloudBootFilesPlace], accountHomes: [URL]) async throws {
        await enter()
        defer { leave() }
        var byId: [String: BackendCloudBootFilesPlace] = [:], ids: [String] = [], refused: [String: String] = [:]
        let own = stateRoot.standardizedFileURL.path
        let homes = Self.defaultAccountHomes() + accountHomes + next.filter { $0.kind != .project }.map { $0.root }
        for place in next {
            if let why = Self.placeRefusal(place, accountHomes: homes) {
                guard refused[place.sourceId] == nil, byId[place.sourceId] == nil else { throw CloudFailure.invalidRequest }
                refused[place.sourceId] = why
                continue
            }
            let root = place.root.standardizedFileURL.path
            // This Mac's own Cloud folder is never a boot-file folder and never sits inside a folder that travels.
            var inside = root == own || root.hasPrefix(own + "/")
            for folder in CloudBootFilesRules.folders(place.kind) {
                let listed = root + "/" + folder
                if own == listed || own.hasPrefix(listed + "/") { inside = true }
            }
            guard place.root.isFileURL, !place.identity.isEmpty, byId[place.sourceId] == nil, refused[place.sourceId] == nil, !inside,
                  BackendCloudBrainFilesSource.validSourceId(place.sourceId) else { throw CloudFailure.invalidRequest }
            byId[place.sourceId] = place
            ids.append(place.sourceId)
        }
        let rebuild = built == nil || Set(ids) != Set(order)
        places = byId
        order = ids
        refusedPlaces = refused
        // What already waits says why: no folder on this Mac, or a folder that is refused.
        let db = try state()
        try db.run("UPDATE boot_items SET reasons='no-folder' WHERE kind='waiting-folder'")
        for (id, why) in refused { try db.run("UPDATE boot_items SET reasons=? WHERE kind='waiting-folder' AND source_id=?", [.text(why), .text(id)]) }
        if rebuild {
            let running = pump
            pump = nil
            await running?.stop()
            built = nil
            let engine = try core()
            if let outbox, let subjectHash {
                let fresh = try BackendCloudBrainFilesPump(engine: engine, outbox: deleteOutbox(outbox), subjectHash: subjectHash)
                await fresh.start()
                pump = fresh
            }
            // Records that waited for one of these places now have somewhere to go in this Mac's copy.
            _ = try await engine.reproject(limit: 100_000)
        }
        try await refreshAll()
    }

    // MARK: Folder <-> copy

    /// Brings every place in step, both directions. Call when a watched folder changed, on wake and when the
    /// Cloud page opens. Reads only the listed files; writes only what `CloudBootFilesRules.step` allows.
    public func refresh() async throws {
        try await refreshHeld()
        await coverageChanged()
    }
    func refreshHeld() async throws {
        await enter()
        defer { leave() }
        try await refreshAll()
    }
    /// 13 Nov leftover: the Cloud page's Boot files row is the sync core's coverage of this adapter. After anything
    /// that changes what waits here outside a pull (a folder chosen, a file written, accepted or kept), the sync core
    /// is asked to take it again, so the row says what is true now. Called with no job of this adapter running.
    func coverageChanged() async {
        guard let outbox else { return }
        try? await outbox.refreshCoverage()
    }

    func refreshAll() async throws {
        let engine = try core()
        // An arrived removal half applied before a crash is finished before anything reconciles (MUST 7).
        await finishBootArrivals(engine: engine)
        try arrivalsHaveAFolder()
        // Each saved intent on its own; nothing here can stop the refresh (MUST 2).
        await recoverBootIntents(engine: engine)
        await withdrawBootCloudRemovals(engine: engine)
        for id in order {
            guard let place = places[id] else { continue }
            try await settlePlace(place, engine: engine)
        }
        // Versions "kept beside" before this build, and any an earlier pass could not settle, follow the one rule.
        try await resolveKeptBeside(engine)
        try sweepDaily()
    }

    func settlePlace(_ place: BackendCloudBootFilesPlace, engine: BackendCloudBrainFiles) async throws {
        // One setup for every AI (19 Nov): what arrived and what changed here is made the same for every AI first, so
        // the made files travel in this same look. Set by the composition (`BackendAISetupKeeper`); nil in tests.
        if place.kind == .project, let keeper = setupKeeper { keeper(place.root) }
        let walk = BackendCloudBootFilesDisk.walk(root: place.root, kind: place.kind)
        // A missing/unreadable/empty project or AI home is never evidence of a deletion.
        guard rootAvailable(place) else {
            missing = missing.filter { !$0.key.hasPrefix(place.sourceId + "\n") }
            return
        }
        // Release fix R3 (16 Nov): something in the place could not be read. The files that WERE read still travel both
        // ways; nothing the walk could not read is looked at, written over or taken as removed (no removal retry, no
        // "Only on this Mac" clean-up, no look for missing paths). The unreadable item stays a "could not be read" gap.
        guard walk.reliable else {
            missing = missing.filter { !$0.key.hasPrefix(place.sourceId + "\n") }
            for entry in walk.files {
                try state().run("INSERT OR REPLACE INTO boot_seen(place,at) VALUES (?,?)", [.text(place.sourceId + "\n" + entry.relative), .int(now())])
                _ = try await settle(place, entry.relative, engine: engine)
            }
            while try await engine.reconcile(sourceId: place.sourceId, limit: 4096).remaining {}
            try await recordJournal(engine)
            return
        }
        await retryBootRemovals(place, engine: engine)
        // Review 15 Nov (point 9): "Only on this Mac" lives only where this Mac has the file; a new file there later
        // syncs normally.
        let present = Set(walk.files.map(\.relative))
        for mark in try deleteState().marks() where mark.mark == .onlyOnThisMac && mark.place.hasPrefix(place.sourceId + "\n") {
            let relative = String(mark.place.dropFirst(place.sourceId.count + 1))
            if !present.contains(relative), !walk.present.contains(relative), case .absent = BackendCloudBootFilesDisk.read(root: place.root, relative: relative) {
                try deleteState().clearMark(at: mark.place)
                try CloudFileDeleteRecords.rememberCleared(mark.place, in: state())
            }
        }
        var seen: Set<String> = []
        for entry in walk.files {
            seen.insert(entry.relative)
            try state().run("INSERT OR REPLACE INTO boot_seen(place,at) VALUES (?,?)", [.text(place.sourceId + "\n" + entry.relative), .int(now())])
            _ = try await settle(place, entry.relative, engine: engine)
        }
        // Paths this Mac knows that the walk did not return: removed here, or arrived and not written yet.
        // A path that is still there but no longer a boot file (a link, too large, not text) is left alone.
        for relative in try known(place) where !seen.contains(relative) && !walk.present.contains(relative) {
            _ = try await settle(place, relative, engine: engine)
        }
        // The engine journals whatever changed in the copy (also what an interrupted earlier pass left).
        while try await engine.reconcile(sourceId: place.sourceId, limit: 4096).remaining {}
        try await recordJournal(engine)
    }

    /// Which bytes each of this Mac's own versions had: the engine's journal, each entry read once. Lane F needs
    /// it to tell "the next version of the bytes this Mac holds" from "another version" (see `successor`).
    func recordJournal(_ engine: BackendCloudBrainFiles) async throws {
        let db = try state()
        let start = try db.first("SELECT value FROM boot_meta WHERE key='journal'")?.int(0) ?? 0
        var sequence = start
        while let resource = try await engine.journalResource(after: sequence) {
            // A removal is remembered with the bytes it removed: a file made again after it follows those bytes.
            try db.run("INSERT OR REPLACE INTO boot_versions(source_id,path,version,hash) VALUES (?,?,?,?)",
                       [.text(resource.sourceId), .text(resource.relative), .text(resource.version), .text(resource.rawHash)])
            sequence = resource.sequence
        }
        if sequence != start {
            try db.run("INSERT INTO boot_meta(key,value) VALUES ('journal',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.int(sequence)])
        }
    }

    func settlePaths(_ place: BackendCloudBootFilesPlace, _ paths: [String], engine: BackendCloudBrainFiles) async throws {
        var changed = false
        for relative in paths {
            if try await settle(place, relative, engine: engine) { changed = true }
        }
        if changed {
            while try await engine.reconcile(sourceId: place.sourceId, paths: paths, limit: 4096).remaining {}
            try await recordJournal(engine)
        }
    }

    /// Every path this Mac holds for a place: what both sides agreed on, and what sits in the copy.
    func known(_ place: BackendCloudBootFilesPlace) throws -> [String] {
        var paths = try Set(state().rows("SELECT path FROM boot_base WHERE source_id=?", [.text(place.sourceId)]).map { $0.text(0) })
        for entry in BackendCloudBootFilesDisk.walk(root: copy(place.sourceId), kind: place.kind).files { paths.insert(entry.relative) }
        return paths.sorted()
    }

    /// The fingerprint the folder and the copy last agreed on for this path.
    func agreed(_ sourceId: String, _ relative: String) throws -> String? {
        try state().first("SELECT hash FROM boot_base WHERE source_id=? AND path=?", [.text(sourceId), .text(relative)])?.string(0)
    }
    func setBase(_ sourceId: String, _ relative: String, _ hash: String?) throws {
        let db = try state()
        if let hash {
            try db.run("INSERT OR REPLACE INTO boot_seen(place,at) VALUES (?,?)", [.text(sourceId + "\n" + relative), .int(now())])
            try db.run("INSERT INTO boot_base(source_id,path,hash) VALUES (?,?,?) ON CONFLICT(source_id,path) DO UPDATE SET hash=excluded.hash",
                       [.text(sourceId), .text(relative), .text(hash)])
        } else {
            try db.run("DELETE FROM boot_base WHERE source_id=? AND path=?", [.text(sourceId), .text(relative)])
        }
    }

    /// One path, both directions. True when this Mac's copy changed (the engine is then told).
    func settle(_ place: BackendCloudBootFilesPlace, _ relative: String, engine: BackendCloudBrainFiles) async throws -> Bool {
        // The rules are asked again for every path, whoever supplied it.
        guard CloudBootFilesRules.refusal(kind: place.kind, relative: relative) == nil else { return false }
        let id = place.sourceId, mirror = copy(id), key = id + "\n" + relative
        guard rootAvailable(place) else { missing.removeValue(forKey: key); return false }
        let copyBytes: Data?
        switch BackendCloudBootFilesDisk.read(root: mirror, relative: relative) {
        case .absent: copyBytes = nil
        case .file(let bytes): copyBytes = bytes
        case .blocked: missing.removeValue(forKey: key); return false
        }
        let copyHash = copyBytes.map { BackendCloudBrainMemoryHash.bytes($0) }
        let base = try agreed(id, relative)
        let localBytes: Data?
        switch BackendCloudBootFilesDisk.read(root: place.root, relative: relative) {
        case .absent: localBytes = nil
        case .file(let bytes):
            // Not text: not a boot file. Neither captured nor read as removed.
            guard CloudBootFilesRules.isText(bytes) else { return false }
            // A setup file holding a password or key: stays on this Mac (counted by the walk), never captured.
            guard !BackendCloudBootFilesDisk.setupHoldsSecret(kind: place.kind, relative: relative, bytes: bytes) else { return false }
            localBytes = bytes
        case .blocked(let reason):
            missing.removeValue(forKey: key)
            // A link, a twin or a folder stands where the file would be. Nothing is read through it or written over it.
            try obstructed(place, relative, reason: reason, copy: copyBytes, base: base)
            return false
        }
        let localHash = localBytes.map { BackendCloudBrainMemoryHash.bytes($0) }
        // Final look 15 Nov (MUST 1): his "Cloud" choice survives a branch switch. Bytes this place held before come back
        // as "Only on this Mac" and are never uploaded; bytes never seen here are his new file.
        if let localHash, try CloudFileDeleteRecords.wasCleared(key, in: state()), try deleteState().mark(at: key) == nil {
            let journaled = try await engine.knownVersion(sourceId: id, relative: relative, rawHash: localHash)
            let arrived = try state().first("SELECT 1 FROM boot_versions WHERE source_id=? AND path=? AND hash=? LIMIT 1", [.text(id), .text(relative), .text(localHash)]) != nil
            try CloudFileDeleteRecords.forgetCleared(key, in: state())
            if journaled || arrived {
                missing.removeValue(forKey: key)
                try deleteState().putMark(.init(place: key, mark: .onlyOnThisMac, at: now()))
                return false
            }
        }
        if let mark = try deleteState().mark(at: key) {
            if mark.mark == .onlyOnThisMac || localBytes == nil { return false }
            // J-7. Review 15 Nov (point 10): the mark is cleared only AFTER the check and its write succeeded.
            if let localHash, let localBytes, let copyBytes, let copyHash {
                // Point 12: one query per file over this Mac's journal and what arrived, plus the arrived list.
                let journaled = try await engine.knownVersion(sourceId: id, relative: relative, rawHash: localHash)
                let arrived = try state().first("SELECT 1 FROM boot_versions WHERE source_id=? AND path=? AND hash=? LIMIT 1", [.text(id), .text(relative), .text(localHash)]) != nil
                if localHash == copyHash || journaled || arrived {
                    if localHash != copyHash {
                        guard try ensureBootSafety(place) else { return false }
                        try keep(localBytes, hash: localHash, sourceId: id, relative: relative, device: deviceId, at: now())
                        try crashPointForTests?("j7:beforeWrite")
                        try BackendCloudBootFilesDisk.replace(root: place.root, relative: relative, bytes: copyBytes, expecting: localHash)
                    }
                    try setBase(id, relative, copyHash)
                    try deleteState().clearMark(at: key)
                    return false
                }
                try keep(copyBytes, hash: copyHash, sourceId: id, relative: relative, device: deviceId, at: now())
                try BackendCloudBootFilesDisk.replace(root: mirror, relative: relative, bytes: localBytes, expecting: copyHash)
                try setBase(id, relative, localHash)
                try deleteState().clearMark(at: key)
                return true
            }
            // A file at a marked place with nothing in the Cloud to compare: his new file, recorded by the steps below.
            try deleteState().clearMark(at: key)
        }
        // The one rule: both changed (the copy holds an arrived version, the folder an edit not recorded yet). The
        // newer one is used; which is decided from the two versions' times.
        var newest: CloudBootFilesNewest?, arrived: BackendCloudBrainFiles.VersionInfo?, localAt: Int64 = 0
        if localBytes != nil, let localHash, let copyHash, copyHash != base, localHash != base, localHash != copyHash,
           let info = try await engine.currentVersion(sourceId: id, relative: relative), info.rawHash == copyHash {
            let agreedAt = try await engine.latestTime(sourceId: id, relative: relative, versions: info.parents)
            let clock = now()
            let modified = Self.modifiedTime(root: place.root, relative: relative) ?? clock
            // The time this edit's version will carry when recorded (the same bounds the engine applies).
            localAt = CloudBootFilesRules.clamp(modified, agreedAt: agreedAt, now: clock)
            // Rule J: a file this Mac never agreed on with the Cloud is its first saved copy.
            newest = CloudBootFilesRules.newest(local: .init(at: localAt, device: deviceId, firstCopy: base == nil),
                                                arrived: .init(at: info.createdAt, device: info.originDevice, firstCopy: info.parents.isEmpty),
                                                now: clock)
            arrived = info
        }
        var runs: [String] = [], accepted = false
        if let copyBytes, let copyHash, copyHash != base, localHash == base || newest == .arrived {
            runs = CloudBootFilesRules.runReasons(relative: relative, bytes: copyBytes)
            if !runs.isEmpty { accepted = try isAccepted(id, relative, copyHash) }
        }
        let step: CloudBootFilesStep = localHash == nil && base != nil && copyHash != nil ? .captureRemoval
            : CloudBootFilesRules.step(local: localHash, copy: copyHash, base: base, runs: !runs.isEmpty, accepted: accepted, newest: newest)
        if step != .captureRemoval { missing.removeValue(forKey: key) }
        switch step {
        case .nothing:
            if base != localHash { try setBase(id, relative, localHash) }
            try inStep(place, relative, hash: localHash)
            return false
        case .captureLocal:
            guard let localBytes, let localHash else { return false }
            if let copyHash { try BackendCloudBootFilesDisk.replace(root: mirror, relative: relative, bytes: localBytes, expecting: copyHash) }
            else { try BackendCloudBootFilesDisk.create(root: mirror, relative: relative, bytes: localBytes) }
            try setBase(id, relative, localHash)
            try inStep(place, relative, hash: localHash)
            return true
        case .captureRemoval:
            guard copyHash != nil, rootAvailable(place) else { return false }
            // Two absent looks 3 s apart; no intent means ask the one witness exactly once per path.
            guard let since = missing[key] else { missing[key] = now(); return false }
            guard now() - since >= CloudFolderFormat.quiet else { return false }
            // Review 15 Nov (MUST 1): only the witness decides, never an intent left in the table.
            let last = try state().first("SELECT at FROM boot_seen WHERE place=?", [.text(key)])?.int(0) ?? since
            let answer = await witness.who(removed: place.root.appendingPathComponent(relative),
                lastSeen: Date(timeIntervalSince1970: Double(min(last, since)) / 1000),
                seenGoneAt: Date(timeIntervalSince1970: Double(since) / 1000))
            missing.removeValue(forKey: key)
            if case .ai(let session, let agent, _, let group) = answer, copyHash == base {
                let intent = CloudDeleteIntent(place: key, scope: .everywhere, by: .ai, mac: deviceId, session: session, agent: agent, at: now(), group: group)
                do { try await removeBoot(place, relative, intent: intent, engine: engine, wasHere: false); return true }
                catch { _ = CloudSyncDiagnostics.shared.report("instruction files", error) }
            }
            try deleteState().putMark(.init(place: key, mark: .notOnThisMac, at: now()))
            return false
        case .useLocal:
            // This Mac's edit is newer: it becomes the newest version and travels; the arrived one is kept 30 days.
            guard let localBytes, let localHash, let copyBytes, let copyHash, let arrived else { return false }
            try keep(copyBytes, hash: copyHash, sourceId: id, relative: relative, device: arrived.originDevice, at: arrived.createdAt)
            // Recorded BESIDE the arrived version (same parents), not on top of it: the other Mac then sees two versions
            // made apart, uses this newer one by the same rule, keeps its own and gets the one line.
            await engine.setNextParents(sourceId: id, relative: relative, parents: arrived.parents)
            try BackendCloudBootFilesDisk.replace(root: mirror, relative: relative, bytes: localBytes, expecting: copyHash)
            try setBase(id, relative, localHash)
            try inStep(place, relative, hash: localHash)
            return true
        case .write, .needsAccept, .keepBoth, .useArrived:
            guard let copyBytes, let copyHash else { return false }
            try arrive(place, relative, step: step, bytes: copyBytes, hash: copyHash, local: localHash, runs: runs, localAt: localAt,
                       arrivedAt: arrived?.createdAt)
            return false
        }
    }

    // MARK: Out (capture)

    /// What this Mac has of each place, in the sync core's shape.
    public func sourceInventory() async throws -> [CloudSourceInventory] {
        try await coverage().map {
            CloudSourceInventory(sourceId: $0.sourceId, inventoryRow: $0.inventoryRow, domain: CloudBootFilesFormat.domain, items: $0.items, bytes: $0.bytes,
                                 complete: $0.complete, blockedReasons: $0.blockedReasons, exclusions: $0.exclusions)
        }
    }

    public func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
        // Paged only, like the engine: a folder is never gathered into one unbounded page.
        throw CloudFailure.unsupportedFormat
    }
    public func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
        let reader = BackendCloudBootFilesPages(owner: self, cut: cut)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
    /// Folders are read first, so the snapshot is this Mac's files as they are now.
    func snapshotBegin() async throws -> (engine: BackendCloudBrainFiles, watermark: Int64) {
        // Called by the sync core itself: it is not asked back from here.
        try await refreshHeld()
        let engine = try core()
        let watermark = try await engine.snapshotBegin()
        return (engine, watermark)
    }
    public func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let engine = try await self.core()
                    for try await operation in await engine.changes(after: after) {
                        for record in try await self.travelOperations([operation]) { continuation.yield(record) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    /// The journal, one record at a time, as lane A's pump reads it.
    func localChange(after: String?) async throws -> BackendCloudBrainFilesLocalChange? {
        let engine = try core()
        return try await engine.localChange(after: after)
    }

    // MARK: Coverage lines

    static func count(_ count: Int, _ one: String, _ many: String) -> String { count == 1 ? "1 " + one : "\(count) " + many }

    /// Gaps: something that should be saved and is not.
    static func gapLines(_ walk: BackendCloudBootFilesDisk.Walk) -> [String] {
        var lines: [String] = []
        for code in walk.gaps.keys.sorted() {
            let number = walk.gaps[code] ?? 0
            switch code {
            case "unreachable": lines.append("This folder is not reachable on this Mac.")
            case "unreadable": lines.append(count(number, "item could not be read.", "items could not be read."))
            case "twin": lines.append(count(number, "name differs from another only in letter case and is not saved.", "names differ from another only in letter case and are not saved."))
            case "name": lines.append(count(number, "file has a name this version cannot carry.", "files have a name this version cannot carry."))
            case "too-many": lines.append("More than 2,000 boot files in this folder. Not saved: " + String(number) + ".")
            case "too-deep": lines.append(count(number, "folder is nested too deep to save.", "folders are nested too deep to save."))
            default: lines.append(count(number, "item is not saved.", "items are not saved."))
            }
        }
        return lines
    }
    /// Left out on purpose: the named rules, then what this folder holds of each.
    static func exclusionLines(_ walk: BackendCloudBootFilesDisk.Walk) -> [String] {
        var lines = CloudBootFilesRules.exclusions
        for code in walk.excluded.keys.sorted() {
            let number = walk.excluded[code] ?? 0
            switch code {
            case "link": lines.append(count(number, "linked item stays on this Mac.", "linked items stay on this Mac."))
            case "too-large": lines.append(count(number, "file larger than 1 MB stays on this Mac.", "files larger than 1 MB stay on this Mac."))
            case "not-text": lines.append(count(number, "file that is not text stays on this Mac.", "files that are not text stay on this Mac."))
            case "hidden": lines.append(count(number, "hidden item stays on this Mac.", "hidden items stay on this Mac."))
            case "never": lines.append(count(number, "settings, hooks or sign-in item stays on this Mac.", "settings, hooks or sign-in items stay on this Mac."))
            case "rebuildable": lines.append(count(number, "folder of installed packages stays on this Mac.", "folders of installed packages stay on this Mac."))
            case "secret": lines.append(count(number, "settings or guard file holds a password or key and stays on this Mac.", "settings or guard files hold a password or key and stay on this Mac."))
            default: break
            }
        }
        return lines
    }

    /// What travels (counted), what is left out on purpose (named), what waits and why: one line per place, plus
    /// one line for files whose place is not on this Mac.
    public func coverage() async throws -> [CloudCoverage] {
        var out: [CloudCoverage] = []
        for id in order {
            guard let place = places[id] else { continue }
            let walk = BackendCloudBootFilesDisk.walk(root: place.root, kind: place.kind)
            let gaps = try Self.gapLines(walk) + waitLines(id)
            out.append(CloudCoverage(sourceId: Self.coverageId(id), inventoryRow: CloudBootFilesFormat.inventoryRow, complete: gaps.isEmpty,
                                     items: walk.files.count, bytes: walk.bytes, blockedReasons: gaps, exclusions: Self.exclusionLines(walk)))
        }
        if let waiting = try notOnThisMac() { out.append(waiting) }
        return out
    }
}

/// The engine's snapshot, one record a page, ending with lane F's own coverage.
private actor BackendCloudBootFilesPages {
    private let owner: BackendCloudBootFiles
    private let cut: CloudSnapshotCut
    private var engine: BackendCloudBrainFiles?
    private var watermark: Int64 = 0
    private var rowid: Int64 = 0
    private var resource: BackendCloudBrainFilesResource?
    private var index = 0
    private var finished = false
    init(owner: BackendCloudBootFiles, cut: CloudSnapshotCut) { self.owner = owner; self.cut = cut }

    func next() async throws -> CloudDomainSnapshot? {
        guard !finished else { return nil }
        if engine == nil {
            let begun = try await owner.snapshotBegin()
            engine = begun.engine
            watermark = begun.watermark
        }
        guard let engine else { return nil }
        if resource == nil {
            guard let pair = try await engine.snapshotResource(after: rowid) else {
                finished = true
                let coverage = try await owner.coverage()
                return CloudDomainSnapshot(cut: CloudSnapshotCut(snapshotId: cut.snapshotId, at: cut.at,
                                                                 watermarks: ["files/" + CloudBootFilesFormat.inventoryRow: String(watermark)]),
                                           operations: [], files: [], coverage: coverage)
            }
            resource = pair.0
            rowid = pair.1
            index = 0
        }
        guard let current = resource else { return nil }
        let (operation, count) = try await engine.operation(current, index: index)
        index += 1
        if index >= count { resource = nil }
        return CloudDomainSnapshot(cut: cut, operations: [operation], files: [], coverage: [])
    }
}
