import Foundation
import Darwin
import TerminalDeckNativeCore

/// Only the root's absence is reported. Individual missing files are persistent local marks, never questions.
public struct CloudFolderAnswer: Sendable, Equatable {
    public let folderMissing: Bool
    public init(folderMissing: Bool) { self.folderMissing = folderMissing }
}

/// One file in the Cloud folder's Bin on this Mac (30 days), or one of its earlier versions. Names and dates only on screen.
public struct CloudFolderKept: Sendable, Equatable {
    public let path: String
    public let name: String
    public let place: String?
    public let at: Int64
    /// Device id of the Mac that made it (the page shows the Mac's name).
    public let device: String
    public let bytes: Int64
    public let keptUntil: Int64
    /// Never shown: which kept content this is.
    public let sha256: String
    public init(path: String, name: String, place: String?, at: Int64, device: String, bytes: Int64, keptUntil: Int64, sha256: String) {
        self.path = path; self.name = name; self.place = place; self.at = at; self.device = device; self.bytes = bytes
        self.keptUntil = keptUntil; self.sha256 = sha256
    }
}

/// Lane L3, slice 1: the Cloud folder (`~/Terminal Deck Cloud`) as records of the file engine (row I24, domain
/// `cloud-folder`).
///
/// Like instruction files (lane F), the engine is NEVER given his folder: it works on this Mac's private copy
/// (`<state>/copy`, APFS clones, so it costs no disk space for files that did not change). Everything between his folder
/// and the copy goes through this actor, one file at a time, by three fingerprints: the file in the folder, the copy,
/// and the bytes both last agreed on (`folder_base`).
///
///     folder --(rules; quiet 3 s; at most once a minute per busy file; removals: explicit intent or witnessed AI only)--> copy --engine--> Cloud
///     Cloud --engine (refusals first)--> copy --(the one rule; older bytes kept 30 days; removals to the Bin)--> folder
///
/// The safety law (memory seat, 14 Nov), for his files:
/// - Nothing in the folder is overwritten or removed by sync without a way back: the bytes replaced go to the 30-day
///   keeper (versions) and removed files to its Bin, BEFORE the folder is touched, and a safety copy of the folder is
///   made before the first such change on this Mac.
/// - Two different files with one name: the newer is used (Cloud revision order: a version made on top of another always
///   wins; two made apart: the later time, rule J first), the other is kept as a version he can open.
/// - By-hand disappearance is local-only. Explicit and witnessed AI removals travel, with no question or limit.
///   Arriving removals apply over the exact version removed, after keeper and safety copies.
/// - A Mac that joins sends nothing of its own until it has read the Cloud (`markCloudRead`), and the whole kind sends
///   nothing until every Mac of the account understands it (`everyMacUnderstands`), so an older build is never sent a
///   record it cannot take.
public actor BackendCloudFolder {
    public nonisolated let inventoryRows: [String]
    /// Lane L3 slice 2: which kind this owner carries (`.cloudFolder`, or `.artifacts` over the app's artifacts store).
    public nonisolated let profile: CloudFileKind
    /// His folder on this Mac (for artifacts: the app's own store of them).
    public nonisolated let folder: URL
    /// Where its paths live: `folder` alone, or many project folders (`CloudFileKind.projectFolders`).
    public nonisolated let roots: CloudFolderRoots
    let deviceId: String
    let stateRoot: URL
    let versionsRoot: URL
    let now: @Sendable () -> Int64
    /// The gate: every Mac of the account announced it understands Cloud folder records. Tests pass `{ true }`.
    private var everyMacUnderstands: @Sendable () async -> Bool
    /// Review 14 Nov (point 8): the names of the Macs that have not announced it yet (said on the page while closed).
    private var whoWaits: @Sendable () async -> [String] = { [] }
    /// Review 14 Nov (cost): the account's room left, as the service answered (`/state` budget `bytesLeft`); nil = not known.
    private var roomLeft: @Sendable () async -> Int64? = { nil }
    /// Review 14 Nov (cost): free space on this Mac's disk; nil = not known.
    let freeDisk: @Sendable () -> Int64?
    /// Review 14 Nov (point 9): a Mac's name by device id (for "plan (from MacBook Pro).md"); nil = not known.
    private var macName: @Sendable (String) async -> String? = { _ in nil }
    /// The account's room left was below the floor at the last look: this kind sends nothing.
    private var deleteRuleOpen: @Sendable () async -> Bool = { false }
    private var witness = CloudDeleteWitnessSlot.shared
    /// Review 15 Nov (MUST 4): has a device announced the delete rule? Until it is set, every device has (the safe reading:
    /// an arriving removal without its about-record keeps the file).
    var deleteRuleAnnounced: @Sendable (String) async -> Bool = { _ in true }
    /// One `CloudDeleteState` per owner (its tables are made once, not at every file of every look).
    var deleteStateMade: CloudDeleteState?
    /// Tests only: a named point of a removal where a crash is simulated by throwing.
    var crashPointForTests: (@Sendable (String) throws -> Void)?
    func setCrashPointForTests(_ hook: (@Sendable (String) throws -> Void)?) { crashPointForTests = hook }
    public func setDeleteRuleGate(_ gate: @escaping @Sendable () async -> Bool) { deleteRuleOpen = gate }
    public func setDeleteRuleAnnounced(_ read: @escaping @Sendable (String) async -> Bool) { deleteRuleAnnounced = read }
    func setDeleteWitness(_ slot: CloudDeleteWitnessSlot) { witness = slot }
    private var roomLow = false
    /// Lane L3 slice 2: the ONE daily budget shared by the file kinds of this Mac; nil = this owner's own count (slice 1).
    private var dayBudget: CloudDayBudget?
    /// Tests only: runs between reading a file's bytes and reading its size and time again (a writer still at work).
    var afterReadForTests: (@Sendable (String) -> Void)?
    func setAfterReadForTests(_ hook: (@Sendable (String) -> Void)?) { afterReadForTests = hook }
    var pump: BackendCloudBrainFilesPump?
    var outbox: (any CloudOutboxPort)?
    var subjectHash: String?
    private var built: BackendCloudBrainFiles?
    private var opened: BackendCloudBrainFilesDatabase?
    private var keeperMade: BackendCloudVersionKeeper?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var watcher: DeckMemoryWatcher?
    private var looper: Task<Void, Never>?
    /// Something changed in the folder since the last look (file events), or work waits (quiet time).
    private var dirty = true
    private var lastFullLook: Int64 = 0
    /// Sync now: busy files go at once.
    private var hurry = false

    static let sourceId = "folder"
    /// 0.23.6: the shortest time between two whole looks at project folders (see `lookIfDue`).
    static let manyRootsLookGap: Int64 = 60_000
    /// 0.23.6: a file's "seen at" in the look, keeping the newer time when the file was recorded meanwhile.
    static let presenceUpsert = "INSERT INTO folder_presence(path,at) VALUES (?,?) ON CONFLICT(path) DO UPDATE SET at=max(at,excluded.at)"
    /// The keeper's kind for this folder's versions and Bin (`BackendCloudContents.Kind.cloudFolder`).
    public static let kind = "cloudFolder"
    public static let engineRefusal = "Refused: the record does not match its own description."
    public static let notCarried = "Refused: this file does not travel in the Cloud folder."
    public static let diskLowRefusal = "Waiting: this Mac has less than 2 GB free. It is tried again later."

    /// - `folder`: his Cloud folder (`CloudFolderFormat.defaultFolder()`; a scratch folder in tests).
    /// - `stateRoot`: this identity's Cloud folder state (`<cloud>/<subject>/cloud-folder`), never inside `folder`.
    /// - `now`: the sync core's service clock, falling back to this Mac's clock.
    public init(deviceId: String, folder: URL, stateRoot: URL, versionsRoot: URL? = nil, kind: CloudFileKind = .cloudFolder, roots: CloudFolderRoots? = nil,
                everyMacUnderstands: @escaping @Sendable () async -> Bool,
                freeDisk: (@Sendable () -> Int64?)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard UUID(uuidString: deviceId) != nil, folder.isFileURL, stateRoot.isFileURL else { throw CloudFailure.invalidRequest }
        let state = stateRoot.standardizedFileURL.path, mine = folder.standardizedFileURL.path
        guard state != mine, !state.hasPrefix(mine + "/"), !mine.hasPrefix(state + "/") else { throw CloudFailure.unsafeConfiguration }
        self.deviceId = deviceId.lowercased(); self.folder = folder.standardizedFileURL; self.stateRoot = stateRoot.standardizedFileURL
        self.roots = roots ?? CloudFolderRoots(single: folder.standardizedFileURL)
        self.versionsRoot = versionsRoot ?? BackendCloudVersionKeeper.root(besideStateRoot: stateRoot)
        self.everyMacUnderstands = everyMacUnderstands; self.now = now
        self.profile = kind; self.inventoryRows = [kind.inventoryRow]
        let near = stateRoot
        self.freeDisk = freeDisk ?? { Self.freeBytes(near: near) }
    }
    public func setEveryMacUnderstands(_ check: @escaping @Sendable () async -> Bool) { everyMacUnderstands = check }
    public func setWhoWaits(_ names: @escaping @Sendable () async -> [String]) { whoWaits = names }
    public func setRoomLeft(_ read: @escaping @Sendable () async -> Int64?) { roomLeft = read }
    public func setMacName(_ read: @escaping @Sendable (String) async -> String?) { macName = read }
    public func setDayBudget(_ budget: CloudDayBudget?) { dayBudget = budget }
    /// Free bytes on the disk that holds `near` (or its nearest existing folder above it).
    static func freeBytes(near: URL) -> Int64? {
        var at = near.standardizedFileURL
        while !FileManager.default.fileExists(atPath: at.path), at.path != "/" { at = at.deletingLastPathComponent() }
        return (try? at.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: One job at a time

    func enter() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in waiters.append(continuation) }
    }
    func leave() { if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } }

    // MARK: State

    static let schema = """
        CREATE TABLE IF NOT EXISTS folder_base(path TEXT PRIMARY KEY, hash TEXT NOT NULL, bytes INTEGER NOT NULL, modified INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS folder_seen(path TEXT PRIMARY KEY, bytes INTEGER NOT NULL, modified INTEGER NOT NULL, changed_at INTEGER NOT NULL,
            sent_at INTEGER NOT NULL DEFAULT 0, streak INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS folder_gone(path TEXT PRIMARY KEY, since INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS folder_lines(path TEXT PRIMARY KEY, device TEXT NOT NULL, kept_until INTEGER NOT NULL, at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS folder_control(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS folder_arrived(path TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS folder_presence(path TEXT PRIMARY KEY, at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS folder_day(path TEXT PRIMARY KEY, day INTEGER NOT NULL, count INTEGER NOT NULL);
        """
    func state() throws -> BackendCloudBrainFilesDatabase {
        if let opened { return opened }
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let db = try BackendCloudBrainFilesDatabase(path: stateRoot.appendingPathComponent("folder.db").path, engineTables: false)
        try db.exec(Self.schema)
        try CloudFileDeleteRecords.create(in: db)
        opened = db
        return db
    }
    func control(_ key: String) throws -> String? { try state().first("SELECT value FROM folder_control WHERE key=?", [.text(key)])?.string(0) }
    func setControl(_ key: String, _ value: String?) throws {
        if let value { try state().run("INSERT OR REPLACE INTO folder_control(key,value) VALUES (?,?)", [.text(key), .text(value)]) }
        else { try state().run("DELETE FROM folder_control WHERE key=?", [.text(key)]) }
    }
    func keeper() -> BackendCloudVersionKeeper {
        if let keeperMade { return keeperMade }
        let made = BackendCloudVersionKeeper(root: versionsRoot)
        keeperMade = made
        return made
    }
    var copyRoot: URL { stateRoot.appendingPathComponent("copy", isDirectory: true) }

    struct Base: Equatable { let hash: String; let bytes: Int64; let modified: Int64 }
    func base(_ path: String) throws -> Base? {
        try state().first("SELECT hash,bytes,modified FROM folder_base WHERE path=?", [.text(path)]).map { Base(hash: $0.text(0), bytes: $0.int(1), modified: $0.int(2)) }
    }
    func setBase(_ path: String, _ value: Base?) throws {
        if let value {
            try state().run("INSERT OR REPLACE INTO folder_presence(path,at) VALUES (?,?)", [.text(path), .int(now())])
            try state().run("INSERT OR REPLACE INTO folder_base(path,hash,bytes,modified) VALUES (?,?,?,?)", [.text(path), .text(value.hash), .int(value.bytes), .int(value.modified)])
        } else {
            try state().run("DELETE FROM folder_base WHERE path=?", [.text(path)])
        }
    }

    /// The file engine over this Mac's private copy. Construction performs no I/O beyond making the copy folder.
    func core() throws -> BackendCloudBrainFiles {
        if let built { return built }
        try FileManager.default.createDirectory(at: copyRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = copyRoot, mine = roots, profile = self.profile
        let source = BackendCloudBrainFilesSource(
            sourceId: profile.sourceId, root: copy, include: ["**"], exclude: BackendCloudBrainFilesNames.locks, optional: false,
            projection: .custom({ incoming in
                // The rules are asked again for every arriving path: a refused one is kept unread, never written.
                guard profile.refusal(incoming.relative) == nil, Int64(incoming.bytes.count) <= profile.maximumFileBytes else {
                    return .archiveOnly("not-carried")
                }
                // Review 14 Nov (point 9): a name that differs only by capitals from a file here is never written over
                // it: the bytes stay retained and the owner keeps them BESIDE it under a plain new name.
                if CloudFolderDisk.caseClash(copy, incoming.relative) || CloudFolderDisk.caseClash(mine, incoming.relative) {
                    return .archiveOnly("case-clash")
                }
                return .write(copy.appendingPathComponent(incoming.relative), incoming.bytes)
            }),
            // The one rule: a version's time is when HIS file was changed (the copy carries the folder file's time).
            modifiedAt: { relative in CloudFolderDisk.modified(copy, relative) })
        let made = try BackendCloudBrainFiles(inventoryRow: profile.inventoryRow, deviceId: deviceId,
                                              stateRoot: stateRoot.appendingPathComponent("engine", isDirectory: true), sources: [source], lean: true, now: now)
        built = made
        return made
    }

    static func itemKey(_ path: String) -> String { kind + ":" + path }
    /// This owner's keeper key for one path (the Cloud folder's is `itemKey` above).
    func itemKey(_ path: String) -> String { profile.keeperKind + ":" + path }
    static func name(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }
    /// The folder inside the Cloud folder, said as names ("Plans › 2026"); nil at the top.
    static func place(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        return parts.count > 1 ? parts.dropLast().joined(separator: " › ") : nil
    }
    func folderPresent() -> Bool {
        var info = stat()
        if roots.isMany { return !roots.all.isEmpty }
        return lstat(folder.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    // MARK: Joining the sync core

    /// Registers this adapter and starts the pump (journal to outbox), the folder's file events and the 2-second look.
    /// Nothing of this Mac's own is recorded until `markCloudRead` (after the first pull) and the gate is open.
    public func start(outbox: any CloudOutboxPort, subjectHash: String, watch: Bool = true) async throws {
        guard pump == nil, self.outbox == nil else { return }
        self.outbox = outbox
        self.subjectHash = subjectHash
        do {
            try await outbox.register(adapter: self)
            let made = try BackendCloudBrainFilesPump(engine: try core(), outbox: CloudFileDeleteOutbox(base: outbox, expand: { [weak self] operations in
                guard let self else { throw CloudFailure.unavailable }; return try await self.travelOperations(operations)
            }), subjectHash: subjectHash, bound: pumpBound())
            await made.start()
            pump = made
        } catch {
            self.outbox = nil; self.subjectHash = nil
            throw error
        }
        guard watch else { return }
        if roots.isMany {
            watchRoots()
        } else {
            let base = folder.resolvingSymlinksInPath().path
            watcher = DeckMemoryWatcher(root: base) { [weak self] _, _ in Task { await self?.nudge() } }
        }
        let pause = profile.lookSeconds * 1_000_000_000
        // A large tree (project folders) is looked at on a low priority, so a first upload never slows the Mac.
        looper = Task(priority: roots.isMany ? .background : nil) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pause)
                guard let self else { return }
                await self.lookIfDue()
            }
        }
    }
    /// Sign-out or a closed gate: nothing is read, sent or written after this returns. Nothing is deleted.
    public func stop() async {
        looper?.cancel(); looper = nil
        watcher?.stop(); watcher = nil
        for one in rootWatchers { one.stop() }
        rootWatchers = []
        let running = pump
        pump = nil; outbox = nil; subjectHash = nil
        await running?.stop()
    }
    func nudge() { dirty = true }
    /// 0.23.4 (faults 1 and 3): project folders hand pieces to the upload queue only while that queue holds less than
    /// 256 MB of them, the disk has 5 GB free, and every Mac of the account said it understands them. The rest waits
    /// here (clones of his files) and goes at the owner's next look. Other kinds keep their own caps, as before.
    func pumpBound() -> BackendCloudBrainFilesPumpBound? {
        guard profile.inventoryRow == CloudProjectFoldersRules.inventoryRow else { return nil }
        let disk = freeDisk
        return .init(domain: profile.domain, freeDisk: disk, gateOpen: { [weak self] in await self?.gateOpen() ?? false })
    }
    func gateOpen() async -> Bool { await everyMacUnderstands() }
    /// Kinds that clone (project folders): the file to clone a new copy from, so the private copy takes no extra disk space.
    func cloneSource(folderFile path: String) -> URL? { profile.clonesCopies ? CloudFolderDisk.url(roots, path) : nil }
    func cloneSource(copyFile path: String) -> URL? { profile.clonesCopies ? copyRoot.appendingPathComponent(path) : nil }
    /// Project folders: one watcher per project folder on this Mac (file events only nudge the next look).
    private var rootWatchers: [DeckMemoryWatcher] = []
    private func watchRoots() {
        for one in rootWatchers { one.stop() }
        rootWatchers = roots.all.values.sorted { $0.path < $1.path }.compactMap { root in
            // Builds and checkouts (`code/`, `node_modules`, ...) change all the time and never travel: they never nudge a look.
            DeckMemoryWatcher(root: root.resolvingSymlinksInPath().path) { [weak self] paths, _ in
                let relevant = paths.isEmpty || paths.contains { path in
                    !path.split(separator: "/").contains { CloudProjectFoldersRules.neverFolders.contains($0.lowercased()) }
                }
                if relevant { Task { await self?.nudge() } }
            }
        }
    }
    /// Project folders: the projects on this Mac changed (added, moved, mapped). Their files are looked at next.
    public func setRoots(_ next: [String: URL]) {
        guard roots.isMany, next != roots.all else { return }
        roots.set(next)
        if outbox != nil { watchRoots() }
        dirty = true
    }
    /// The first pull after start has returned: this Mac has read the Cloud, so its own files may be recorded now.
    /// Kept: a Mac reads the Cloud first only once.
    public func markCloudRead() throws { try setControl("cloudRead", "1") }
    public func hasReadCloud() throws -> Bool { try control("cloudRead") == "1" }
    /// Sync now: everything waiting goes at once (busy files too).
    public func sendNow() async {
        hurry = true
        dirty = true
        await lookIfDue()
        hurry = false
    }

    func lookIfDue() async {
        // 0.23.4: a pump held back (queue full, disk low, gate closed) tries again at each look.
        if let pump { await pump.resumeIfHolding() }
        let t = now()
        let pending = ((try? state().first("SELECT 1 FROM folder_seen s LEFT JOIN folder_base b ON b.path=s.path WHERE b.path IS NULL OR b.bytes<>s.bytes OR b.modified<>s.modified LIMIT 1")) ?? nil) != nil
            || ((try? state().first("SELECT 1 FROM folder_gone LIMIT 1")) ?? nil) != nil
        // Review 14 Nov (cost): the daily sweep runs once a day (it was never called).
        let swept = ((try? control("sweptAt")) ?? nil).flatMap { Int64($0) }
        if swept.map({ t - $0 < 0 || t - $0 >= CloudFolderFormat.day }) ?? true {
            do { if try await sweepDaily() { try setControl("sweptAt", String(t)) } } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
        }
        guard dirty || pending || t - lastFullLook >= 300_000 else { return }
        // 0.23.6 (CPU): project folders (on the Mac mini 4 trees, 71,443 files) are walked whole at most once a minute.
        // A file being written keeps a look due every 10 s, and each look reads every file's details. "Sync now" still
        // looks at once; a change noted meanwhile stays noted for the next look.
        if roots.isMany, !hurry, lastFullLook > 0, t >= lastFullLook, t - lastFullLook < Self.manyRootsLookGap { return }
        dirty = false
        lastFullLook = t
        do { try await look() } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
    }

    // MARK: Folder -> copy (this Mac's own changes)

    /// One reliable look: record changes, mark by-hand absences and journal intended removals.
    public func look() async throws {
        await enter()
        defer { leave() }
        try await lookBody()
    }
    /// One look inside the owner's serialized job.
    func lookBody() async throws {
        guard try hasReadCloud() else { return }
        guard await everyMacUnderstands() else {
            let waiting = await whoWaits()
            try setControl("gateWaiting", waiting.isEmpty ? nil : waiting.joined(separator: "\n"))
            return
        }
        try setControl("gateWaiting", nil)
        let engine = try core()
        // An arrived removal half applied before a crash is finished before anything reconciles (MUST 7).
        await finishArrivedRemovals(engine: engine)
        let walk = CloudFolderWalk.run(roots, kind: profile)
        let db = try state(), t = now()
        // Each saved intent on its own; nothing here can stop the look (MUST 2).
        await recoverDeleteIntents(engine: engine)
        let hadFiles = try db.first("SELECT 1 FROM folder_base LIMIT 1") != nil
        // Project folders: an unreadable item in one folder never stops the others (removals still need a reliable look).
        let unavailable = roots.isMany ? (roots.all.isEmpty || (walk.files.isEmpty && hadFiles))
                                       : (!walk.present || !walk.reliable || (walk.files.isEmpty && hadFiles))
        try setControl("folderMissing", unavailable ? "1" : nil)
        guard !unavailable else {
            // The next reliable root starts a fresh pair of absent looks. Preserve old migration evidence until read.
            if try control("deleteRuleMigrated") == "1" { try db.run("DELETE FROM folder_gone") }
            return
        }
        await migrateDeleteRule(engine: engine)
        await retryRemovalHeads(engine: engine)
        await withdrawCloudRemovals(engine: engine)
        var captured: [String] = []
        let full = walk.bytes > profile.maximumFolderBytes
        try setControl("folderFull", full ? "1" : nil)
        try setControl("tooLarge", walk.skipped[.tooLarge].map(String.init))
        try setControl("secretNames", walk.secretNames.isEmpty ? nil : walk.secretNames.joined(separator: "\n"))
        try setControl("spellingNames", walk.spellingNames.isEmpty ? nil : walk.spellingNames.joined(separator: "\n"))
        try checkDisk()
        roomLow = profile.obeysRoomFloor ? ((await roomLeft()).map { $0 < CloudFolderFormat.roomFloor } ?? false) : false
        try setControl("roomLow", roomLow ? "1" : nil)
        _ = try daySent(at: t)
        let today = t / CloudFolderFormat.day
        var busy = 0
        // Paced (project folders): at most `bytesPerLook` recorded per look; the rest goes in the next looks.
        var recordedBytes: Int64 = 0
        // 0.23.6 (CPU, disk): every file's "seen at" is written in ONE transaction per look. One write per file, each its
        // own disk-synced transaction (this database uses journal_mode=DELETE, synchronous=FULL), was 71,443 synced
        // writes per look on the Mac mini, every 10 s while a file in his project folders changed.
        var present: [String] = []
        func notePresence() {
            guard !present.isEmpty else { return }
            let seen = present
            present = []
            do { try db.transaction { for path in seen { try db.run(Self.presenceUpsert, [.text(path), .int(t)]) } } }
            catch { _ = CloudSyncDiagnostics.shared.report(profile.label + ": noting the files seen", error) }
        }
        defer { notePresence() }
        for path in walk.files.keys.sorted() {
            if let pace = profile.bytesPerLook, recordedBytes >= pace { dirty = true; break }
            guard let entry = walk.files[path] else { continue }
            present.append(path)
            let mark = try deleteState().mark(at: path)
            if mark?.mark == .onlyOnThisMac { continue }
            if mark != nil {
                // A file back at a marked place: one path's error never stops the look (the mark stays; tried again).
                do { _ = try await settle(path, engine: engine) } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
                continue
            }
            let known = try base(path)
            if let known, known.bytes == entry.bytes, known.modified == entry.modified { continue }
            let seen = try db.first("SELECT bytes,modified,changed_at,sent_at,streak FROM folder_seen WHERE path=?", [.text(path)])
            if seen == nil || seen!.int(0) != entry.bytes || seen!.int(1) != entry.modified {
                try db.run("""
                    INSERT INTO folder_seen(path,bytes,modified,changed_at,sent_at,streak) VALUES (?,?,?,?,0,0)
                    ON CONFLICT(path) DO UPDATE SET bytes=excluded.bytes,modified=excluded.modified,changed_at=excluded.changed_at
                    """, [.text(path), .int(entry.bytes), .int(entry.modified), .int(t)])
                if !hurry { continue }
            } else if t - seen!.int(2) < CloudFolderFormat.quiet, !hurry { continue }
            // Fix 15 Nov: a file back at a place whose "Cloud" choice a look cleared is checked once it is still, BEFORE
            // the send limits below (busy gap, daily count, full folder): putting the mark back sends nothing, so it never
            // waits for them. Unknown bytes fall through to those limits as his new file.
            do { if try await cloudChoiceStands(path, engine: engine) { continue } }
            catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error); continue }
            let sentAt = seen?.int(3) ?? 0, streak = Int(seen?.int(4) ?? 0)
            let gap: Int64 = streak >= CloudFolderFormat.busyStreak ? CloudFolderFormat.busyLongGap : (streak >= 1 ? CloudFolderFormat.busyGap : 0)
            if !hurry, sentAt > 0, t - sentAt < gap { continue }
            // Past 1 GB, new and changed files stay here (nothing is removed; one line says so).
            if full { continue }
            // Review 14 Nov (cost): at most 6 versions of one file a day; then it waits until it has been still an hour.
            let versionsToday = try db.first("SELECT count FROM folder_day WHERE path=? AND day=?", [.text(path), .int(today)])?.int(0) ?? 0
            if versionsToday >= Int64(CloudFolderFormat.versionsPerDay), t - (seen?.int(2) ?? t) < CloudFolderFormat.stillAfterLimit { busy += 1; continue }
            let recorded: Bool
            // A path that is a file on one side and a folder on the other is skipped here (named on the page), never the look.
            do { recorded = try await settle(path, engine: engine) } catch CloudFailure.unsafeConfiguration { continue }
            if recorded {
                recordedBytes += entry.bytes
                try db.run("""
                    INSERT INTO folder_day(path,day,count) VALUES (?,?,1)
                    ON CONFLICT(path) DO UPDATE SET count=CASE WHEN day=excluded.day THEN count+1 ELSE 1 END, day=excluded.day
                    """, [.text(path), .int(today)])
                captured.append(path)
                // A file that keeps changing: each send within 10 minutes of the last one lengthens the gap.
                let next = sentAt > 0 && t - sentAt < CloudFolderFormat.busyLongGap ? streak + 1 : 1
                try db.run("UPDATE folder_seen SET sent_at=?,streak=? WHERE path=?", [.int(t), .int(Int64(next)), .text(path)])
            }
        }
        notePresence()
        try setControl("busyFiles", busy > 0 ? String(busy) : nil)
        try db.run("DELETE FROM folder_day WHERE day<?", [.int(today)])
        // Rows of files that stayed still for an hour are dropped (the gap starts afresh).
        try db.run("DELETE FROM folder_seen WHERE changed_at<? AND sent_at<?", [.int(t - 3_600_000), .int(t - 3_600_000)])
        // Review 15 Nov (point 9): "Only on this Mac" lives only where this Mac has the file. A kept file he later removed
        // by hand leaves no stale mark, so a new file he makes there syncs normally.
        for mark in try deleteState().marks() where mark.mark == .onlyOnThisMac && walk.files[mark.place] == nil && !walk.excludedPaths.contains(mark.place) {
            if case .absent = CloudFolderDisk.read(roots, mark.place) {
                try deleteState().clearMark(at: mark.place)
                try CloudFileDeleteRecords.rememberCleared(mark.place, in: state())
            }
        }
        try await removals(walk, engine: engine, at: t)
        while try await engine.reconcile(sourceId: profile.sourceId, limit: 4096).remaining {}
        try await placeArrivals(engine: engine)
    }

    // MARK: Cost (review 14 Nov)

    /// What this Mac sent of the Cloud folder today (bytes). A new day starts at 0.
    func daySent(at t: Int64) throws -> Int64 {
        let today = String(t / CloudFolderFormat.day)
        if try control("day") != today {
            try setControl("day", today); try setControl("daySent", "0"); try setControl("dayFull", nil)
            if dayBudget == nil { return 0 }
        }
        // Lane L3 slice 2: the budget shared with the other file kinds of this Mac, when there is one.
        if let dayBudget { return dayBudget.sent(day: t / CloudFolderFormat.day) }
        return try control("daySent").flatMap(Int64.init) ?? 0
    }
    /// May `bytes` more be recorded (and so sent) now? No while the account's room is low or today's budget would pass
    /// 200 MB (then one line says so). Sync now does not pass it.
    func mayRecord(_ bytes: Int64) throws -> Bool {
        if roomLow { return false }
        guard let cap = profile.dailySendBytes else { return true }
        if try daySent(at: now()) + bytes > cap { try setControl("dayFull", "1"); return false }
        return true
    }
    func spent(_ bytes: Int64) throws {
        if let dayBudget { _ = try daySent(at: now()); dayBudget.add(bytes, day: now() / CloudFolderFormat.day); return }
        let sent = try daySent(at: now())
        try setControl("daySent", String(sent + bytes))
    }
    /// Below 2 GB free: nothing that arrives is written or kept (one line). True while it is low.
    @discardableResult
    func checkDisk() throws -> Bool {
        let low = (freeDisk() ?? .max) < CloudFolderFormat.diskFloor
        try setControl("diskLow", low ? "1" : nil)
        return low
    }

    /// Final look 15 Nov (MUST 1): a place whose "Only on this Mac" mark a look cleared (the file was gone). Bytes this
    /// place held before get the mark back and are never uploaded (true); bytes never seen here are his new file (false,
    /// the memory goes). Without `localHash` the file is read here, and only a file whose size and time held still counts.
    func cloudChoiceStands(_ path: String, localHash known: String? = nil, engine: BackendCloudBrainFiles) async throws -> Bool {
        guard try CloudFileDeleteRecords.wasCleared(path, in: state()), try deleteState().mark(at: path) == nil else { return false }
        var localHash = known
        if localHash == nil {
            guard profile.refusal(path) == nil, !CloudFolderDisk.caseClash(roots, path), let before = CloudFolderDisk.stamp(roots, path),
                  case .file(let local) = CloudFolderDisk.read(roots, path),
                  CloudFolderDisk.stamp(roots, path) == before, Int64(local.count) == before.bytes else { return false }
            localHash = BackendCloudBrainMemoryHash.bytes(local)
        }
        guard let localHash else { return false }
        if try await engine.knownVersion(sourceId: profile.sourceId, relative: path, rawHash: localHash) {
            try deleteState().putMark(.init(place: path, mark: .onlyOnThisMac, at: now()))
            try CloudFileDeleteRecords.forgetCleared(path, in: state())
            return true
        }
        try CloudFileDeleteRecords.forgetCleared(path, in: state())
        return false
    }
    /// One path, folder to copy. True when the copy changed (the engine is told by the reconcile that follows).
    func settle(_ path: String, engine: BackendCloudBrainFiles) async throws -> Bool {
        // Review 14 Nov (point 7): its size and time are read before AND after its bytes; a file still being written waits.
        // A name that differs only by capitals from the file on disk is not that file (point 9).
        guard profile.refusal(path) == nil, !CloudFolderDisk.caseClash(roots, path), let before = CloudFolderDisk.stamp(roots, path),
              case .file(let local) = CloudFolderDisk.read(roots, path) else { return false }
        afterReadForTests?(path)
        guard CloudFolderDisk.stamp(roots, path) == before, Int64(local.count) == before.bytes,
              Int64(local.count) <= profile.maximumFileBytes else { return false }
        let localHash = BackendCloudBrainMemoryHash.bytes(local)
        // Final look 15 Nov (MUST 1): his "Cloud" choice survives a branch switch. Bytes this place held before come back
        // as "Only on this Mac" and are never uploaded; bytes never seen here are his new file.
        if try await cloudChoiceStands(path, localHash: localHash, engine: engine) { return false }
        if let mark = try deleteState().mark(at: path) {
            if mark.mark == .onlyOnThisMac { return false }
            // J-7: an old checkout must never publish a rollback over a newer Cloud version. Review 15 Nov (point 10): the
            // mark is cleared only AFTER the check and its write succeeded; an error in between leaves it, so the next look
            // decides again and can never send the old checkout as a new version.
            if try await wasCloudVersion(path, hash: localHash, engine: engine),
               case .file(let newest) = CloudFolderDisk.read(copyRoot, path) {
                let hash = BackendCloudBrainMemoryHash.bytes(newest)
                if hash != localHash {
                    guard try ensureSafetyCopy() else { return false }
                    try keepMine(path, at: now(), content: local, now: now())
                    try crashPointForTests?("j7:beforeWrite")
                    try CloudFolderDisk.write(roots, path, bytes: newest, expecting: localHash)
                }
                try setBase(path, Base(hash: hash, bytes: Int64(newest.count), modified: CloudFolderDisk.modified(roots, path) ?? now()))
                try deleteState().clearMark(at: path)
                return false
            }
            // Unknown bytes are the person's new version ON TOP of the latest Cloud head, regardless of file dates.
            guard try mayRecord(Int64(local.count)) else { return false }
            var expecting: String?
            if case .file(let bytes) = CloudFolderDisk.read(copyRoot, path) {
                expecting = BackendCloudBrainMemoryHash.bytes(bytes)
                try keepVersion(itemKey: itemKey(path), name: Self.name(path), place: Self.place(path), at: now(), device: deviceId, content: bytes, now: now())
            }
            try CloudFolderDisk.write(copyRoot, path, bytes: local, expecting: expecting, cloneFrom: cloneSource(folderFile: path))
            try spent(Int64(local.count))
            try setBase(path, Base(hash: localHash, bytes: Int64(local.count), modified: CloudFolderDisk.modified(roots, path) ?? now()))
            try deleteState().clearMark(at: path)
            return true
        }
        // The same reading of its time as the walk's (so an unchanged file is never looked at again).
        let modified = CloudFolderDisk.modified(roots, path) ?? before.modified
        let known = try base(path)
        let copy = CloudFolderDisk.read(copyRoot, path)
        if case .blocked = copy { return false }
        let copyHash: String? = { if case .file(let bytes) = copy { return BackendCloudBrainMemoryHash.bytes(bytes) }; return nil }()
        let mine = Base(hash: localHash, bytes: Int64(local.count), modified: modified)
        if localHash == known?.hash || localHash == copyHash {
            // Only its time changed, or the copy already holds these bytes: nothing to send.
            try setBase(path, mine)
            return false
        }
        if copyHash == nil || copyHash == known?.hash {
            guard try mayRecord(Int64(local.count)) else { return false }
            try CloudFolderDisk.write(copyRoot, path, bytes: local, expecting: copyHash, cloneFrom: cloneSource(folderFile: path))
            try spent(Int64(local.count))
            CloudFolderDisk.setModified(copyRoot, path, modified)
            try setBase(path, mine)
            try state().run("DELETE FROM folder_gone WHERE path=?", [.text(path)])
            // A file back at a place that was in the Bin is in use again (on the other Macs too, when it arrives).
            if copyHash == nil { try takeFromBin(itemKey(path), now: now()) }
            return true
        }
        // Both changed: the copy holds a version from another device not written here yet, the folder an edit not sent yet.
        return try await bothChanged(path, local: local, localHash: localHash, modified: modified, engine: engine)
    }

    /// The one rule for one path whose folder file and copy both changed since they last agreed. True when the copy changed.
    func bothChanged(_ path: String, local: Data, localHash: String, modified: Int64, engine: BackendCloudBrainFiles) async throws -> Bool {
        guard case .file(let copyBytes) = CloudFolderDisk.read(copyRoot, path) else { return false }
        let copyHash = BackendCloudBrainMemoryHash.bytes(copyBytes)
        guard let arrived = try await engine.currentVersion(sourceId: profile.sourceId, relative: path), arrived.rawHash == copyHash else { return false }
        let agreedAt = try await engine.latestTime(sourceId: profile.sourceId, relative: path, versions: arrived.parents)
        let t = now()
        let localAt = CloudBootFilesRules.clamp(modified, agreedAt: agreedAt, now: t)
        let pick = CloudBootFilesRules.newest(local: .init(at: localAt, device: deviceId, firstCopy: try base(path) == nil),
                                              arrived: .init(at: arrived.createdAt, device: arrived.originDevice, firstCopy: arrived.parents.isEmpty), now: t)
        let item = itemKey(path)
        if pick == .local {
            // His edit here is newer: it is recorded BESIDE the arrived version (same parents), so the other Mac sees two
            // versions made apart and uses this one by the same rule. The arrived one is kept 30 days here.
            // Review 14 Nov (cost): only within the day's budget and while the account has room; otherwise it waits.
            guard try mayRecord(Int64(local.count)) else { return false }
            try keepVersion(itemKey: item, name: Self.name(path), place: Self.place(path), at: arrived.createdAt,
                            device: arrived.originDevice, content: copyBytes, now: t)
            await engine.setNextParents(sourceId: profile.sourceId, relative: path, parents: arrived.parents)
            try CloudFolderDisk.write(copyRoot, path, bytes: local, expecting: copyHash, cloneFrom: cloneSource(folderFile: path))
            try spent(Int64(local.count))
            CloudFolderDisk.setModified(copyRoot, path, modified)
            try setBase(path, Base(hash: localHash, bytes: Int64(local.count), modified: modified))
            return true
        }
        // The arrived version is newer: his edit is kept 30 days (a version he can open), then the newer one is written.
        guard try ensureSafetyCopy() else { return false }
        // His own losing edit may exist nowhere else: kept under its own key, never trimmed, for its full 30 days.
        let until = try keepMine(path, at: localAt, content: local, now: t)
        try CloudFolderDisk.write(roots, path, bytes: copyBytes, expecting: localHash, cloneFrom: cloneSource(copyFile: path))
        CloudFolderDisk.setModified(roots, path, arrived.createdAt)
        try setBase(path, Base(hash: copyHash, bytes: Int64(copyBytes.count), modified: CloudFolderDisk.modified(roots, path) ?? arrived.createdAt))
        try state().run("INSERT OR REPLACE INTO folder_lines(path,device,kept_until,at) VALUES (?,?,?,?)", [.text(path), .text(arrived.originDevice), .int(until), .int(t)])
        return false
    }

    /// Two reliable looks at a nonempty root. An unknown witness is by hand and never travels.
    func removals(_ walk: CloudFolderWalk, engine: BackendCloudBrainFiles, at t: Int64) async throws {
        guard walk.present, walk.reliable, !walk.files.isEmpty else { return }
        let db = try state()
        for row in try db.rows("SELECT path,hash,modified FROM folder_base") {
            let path = row.text(0)
            if walk.files[path] != nil { try db.run("DELETE FROM folder_gone WHERE path=?", [.text(path)]); continue }
            if walk.excludedPaths.contains(path) { try db.run("DELETE FROM folder_gone WHERE path=?", [.text(path)]); continue }
            guard try deleteState().mark(at: path) == nil,
                  case .absent = CloudFolderDisk.read(roots, path) else { continue }
            guard let since = try db.first("SELECT since FROM folder_gone WHERE path=?", [.text(path)])?.int(0) else {
                try db.run("INSERT INTO folder_gone(path,since) VALUES (?,?)", [.text(path), .int(t)])
                continue
            }
            guard t - since >= CloudFolderFormat.quiet else { continue }
            // Review 15 Nov (MUST 1): only the witness decides here, never an intent left in the table, so a leftover can
            // never turn this by-hand delete into a travelling one.
            let answer = await witness.who(removed: CloudFolderDisk.url(roots, path) ?? folder.appendingPathComponent(path),
                lastSeen: Date(timeIntervalSince1970: Double(min(try db.first("SELECT at FROM folder_presence WHERE path=?", [.text(path)])?.int(0) ?? row.int(2), since)) / 1000),
                seenGoneAt: Date(timeIntervalSince1970: Double(since) / 1000))
            var travelled = false
            if case .ai(let session, let agent, _, let group) = answer,
               case .file(let copy) = CloudFolderDisk.read(copyRoot, path), BackendCloudBrainMemoryHash.bytes(copy) == row.text(1) {
                let intent = CloudDeleteIntent(place: path, scope: .everywhere, by: .ai, mac: deviceId, session: session, agent: agent, at: t, group: group)
                do { try await removeItem(path, intent: intent, engine: engine, wasHere: false); travelled = true }
                catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
            }
            // By hand, or a newer Cloud edit arrived while the file was absent (it wins), or the AI's removal could not be
            // recorded: the safe side, a local mark.
            if !travelled { try deleteState().putMark(.init(place: path, mark: .notOnThisMac, at: t)) }
            try db.run("DELETE FROM folder_gone WHERE path=?", [.text(path)])
        }
    }

    // MARK: Copy -> folder (what arrived from his other Macs)

    /// Every path an arrival touched (`folder_arrived`) whose copy holds bytes the folder has not agreed on yet is placed
    /// by the rules (new file, newer version over his unchanged one, or the one rule when both changed). A path that could
    /// not be placed now stays listed and is tried at the next look. Nothing is written while the folder is missing.
    func placeArrivals(engine: BackendCloudBrainFiles) async throws {
        // A root that vanished (or was emptied) is never silently filled by a pull.
        guard try !rootUnavailable(), try !checkDisk() else { return }
        let db = try state()
        var clashes: [String] = []
        defer { try? setControl("clashNames", clashes.isEmpty ? nil : clashes.joined(separator: "\n")) }
        for row in try db.rows("SELECT path FROM folder_arrived ORDER BY path LIMIT 2000") {
            let path = row.text(0)
            if try deleteState().mark(at: path) != nil { continue }
            guard profile.refusal(path) == nil, !CloudFolderDisk.caseClash(roots, path), case .file(let copyBytes) = CloudFolderDisk.read(copyRoot, path) else {
                try db.run("DELETE FROM folder_arrived WHERE path=?", [.text(path)]); continue
            }
            // Review 14 Nov (point 8): a name that is a folder here and a file there (or the other way) stays apart, named.
            if CloudFolderDisk.fileFolderClash(roots, path) { clashes.append(Self.name(path)); continue }
            let copyHash = BackendCloudBrainMemoryHash.bytes(copyBytes)
            if copyHash != (try base(path))?.hash {
                do { try await arrive(path, copy: copyBytes, copyHash: copyHash, known: try base(path), engine: engine) }
                catch { continue }
            }
            // Placed (or his newer edit is now the copy's): done. Otherwise it waits for the next look.
            if case .file(let held) = CloudFolderDisk.read(copyRoot, path), BackendCloudBrainMemoryHash.bytes(held) == (try base(path))?.hash {
                try db.run("DELETE FROM folder_arrived WHERE path=?", [.text(path)])
            }
        }
    }

    func arrive(_ path: String, copy copyBytes: Data, copyHash: String, known: Base?, engine: BackendCloudBrainFiles) async throws {
        let t = now()
        switch CloudFolderDisk.read(roots, path) {
        case .blocked:
            return
        case .absent:
            // A previously agreed file disappeared here: let the two-look witness decide before any placement.
            if known != nil { return }
            try CloudFolderDisk.write(roots, path, bytes: copyBytes, expecting: nil, cloneFrom: cloneSource(copyFile: path))
            if let at = try await engine.currentVersion(sourceId: profile.sourceId, relative: path)?.createdAt { CloudFolderDisk.setModified(roots, path, at) }
            try setBase(path, Base(hash: copyHash, bytes: Int64(copyBytes.count), modified: CloudFolderDisk.modified(roots, path) ?? t))
            try state().run("DELETE FROM folder_gone WHERE path=?", [.text(path)])
            try takeFromBin(itemKey(path), now: t)
        case .file(let local):
            let localHash = BackendCloudBrainMemoryHash.bytes(local)
            if localHash == copyHash {
                try setBase(path, Base(hash: copyHash, bytes: Int64(local.count), modified: CloudFolderDisk.modified(roots, path) ?? t))
                return
            }
            if let known, localHash == known.hash {
                // His file is the version both agreed on: the newer one replaces it; his is kept 30 days (a way back).
                guard try ensureSafetyCopy() else { return }
                // Bytes that never arrived from another device are HIS (an edit made here that lost to a newer one): kept
                // under his own key for their full 30 days. Bytes that came from another device: the one kept version.
                if try await engine.arrivedVersion(sourceId: profile.sourceId, relative: path, rawHash: localHash) == nil {
                    try keepMine(path, at: known.modified, content: local, now: t)
                } else {
                    try keepVersion(itemKey: itemKey(path), name: Self.name(path), place: Self.place(path),
                                    at: known.modified, device: deviceId, content: local, now: t)
                }
                try CloudFolderDisk.write(roots, path, bytes: copyBytes, expecting: localHash, cloneFrom: cloneSource(copyFile: path))
                if let at = try await engine.currentVersion(sourceId: profile.sourceId, relative: path)?.createdAt { CloudFolderDisk.setModified(roots, path, at) }
                try setBase(path, Base(hash: copyHash, bytes: Int64(copyBytes.count), modified: CloudFolderDisk.modified(roots, path) ?? t))
                return
            }
            // Both changed (or a file of the same name was here before he joined: rule J, his first copy loses and is kept).
            let modified = CloudFolderDisk.modified(roots, path) ?? t
            if try await bothChanged(path, local: local, localHash: localHash, modified: modified, engine: engine) {
                while try await engine.reconcile(sourceId: profile.sourceId, paths: [path], limit: 16).remaining {}
            }
        }
    }

    // MARK: Removals that arrive

    /// The engine retains a removal; the owner applies only over its exact parent, without questions or limits. The
    /// caller applies the saved heads once per pack (`retryRemovalHeads`).
    func removalArrived(path: String, version: String, parents: [String], createdAt: Int64, device: String,
                        travel: CloudDeleteTravelRemoval) throws {
        try CloudFileDeleteRecords.saveHead(in: state(), place: path, version: version, parents: parents,
            at: createdAt, mac: device, travel: travel)
    }

    public func waitingAnswer() throws -> CloudFolderAnswer? {
        try control("folderMissing") == "1" ? CloudFolderAnswer(folderMissing: true) : nil
    }
    /// Explicit root recreation, never performed by Sync. Restores Cloud bytes only on this person's press.
    public func makeFolderAgain() async throws {
        await enter(); defer { leave() }
        await finishArrivedRemovals(engine: try core())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try setControl("folderMissing", nil)
        for row in try state().rows("SELECT path FROM folder_base") {
            try state().run("INSERT OR IGNORE INTO folder_arrived(path) VALUES (?)", [.text(row.text(0))])
        }
        let engine = try core()
        for row in try state().rows("SELECT path FROM folder_arrived") {
            let path = row.text(0)
            guard try deleteState().mark(at: path) == nil,
                  case .absent = CloudFolderDisk.read(roots, path),
                  case .file(let bytes) = CloudFolderDisk.read(copyRoot, path) else { continue }
            try CloudFolderDisk.write(roots, path, bytes: bytes, expecting: nil)
            try setBase(path, Base(hash: BackendCloudBrainMemoryHash.bytes(bytes), bytes: Int64(bytes.count), modified: now()))
        }
        await retryRemovalHeads(engine: engine)
    }

    // MARK: The Bin, versions, the lines

    public func bin() throws -> [CloudFolderKept] {
        try keeper().binList(kind: profile.keeperKind).map {
            CloudFolderKept(path: $0.path, name: $0.name, place: $0.place, at: $0.removedAt, device: $0.device, bytes: $0.bytes, keptUntil: $0.keptUntil, sha256: $0.sha256)
        }
    }
    /// Every version kept of one file, newest first: the one kept arrival or replaced version, and ALL of his own
    /// losing edits (and files Put back displaced), each for its 30 days.
    public func versions(path: String) throws -> [CloudFolderKept] {
        let kept = try keeper().versions(itemKey: itemKey(path)) + keeper().versions(itemKey: mineKey(path))
        return kept.sorted { $0.at != $1.at ? $0.at > $1.at : $0.sha256 < $1.sha256 }.map {
            CloudFolderKept(path: path, name: $0.name, place: $0.place, at: $0.at, device: $0.device, bytes: $0.bytes, keptUntil: $0.keptUntil, sha256: $0.sha256)
        }
    }
    /// A kept version or Bin item as a file he can open (a copy in the app's own folder, named after the file).
    public func openable(path: String, sha256: String) throws -> URL? {
        guard let bytes = keeper().content(kind: profile.keeperKind, sha256: sha256) else { return nil }
        let target = stateRoot.appendingPathComponent("opened", isDirectory: true).appendingPathComponent(String(sha256.prefix(12)), isDirectory: true)
            .appendingPathComponent(Self.name(path))
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? Data(contentsOf: target)) != bytes { try bytes.write(to: target, options: .atomic) }
        return target
    }
    /// Put back from the Bin: the file is written where it was (a different file there now is kept as a version first)
    /// and the next look sends it, on top of the removal, so it comes back on his other Macs too.
    @discardableResult
    public func putBack(path: String) async throws -> Bool {
        await enter()
        let item = itemKey(path), t = now()
        do {
            guard let binned = try keeper().bin(itemKey: item), let bytes = keeper().content(kind: profile.keeperKind, sha256: binned.sha256), folderPresent() else { leave(); return false }
            switch CloudFolderDisk.read(roots, path) {
            case .blocked: leave(); return false
            case .absent: try CloudFolderDisk.write(roots, path, bytes: bytes, expecting: nil)
            case .file(let there):
                let hash = BackendCloudBrainMemoryHash.bytes(there)
                if hash != binned.sha256 {
                    // The file Put back displaces is his: kept under its own key for its full 30 days.
                    try keepMine(path, at: t, content: there, now: t)
                    try CloudFolderDisk.write(roots, path, bytes: bytes, expecting: hash)
                }
            }
            try deleteState().clearMark(at: path)
            try takeFromBin(item, now: t)
        } catch { leave(); throw error }
        leave()
        dirty = true
        return true
    }
    /// "<Mac>'s newer <file> is in use; this Mac's version is kept until <date> · Show", one per replaced file, newest first.
    public func replacedLines(names: [String: String]) throws -> [CloudVersionReplacedLine] {
        let t = now()
        return try state().rows("SELECT path,device,kept_until FROM folder_lines WHERE kept_until>? ORDER BY at DESC", [.int(t)]).map {
            CloudVersionReplacedLine(device: names[$0.text(1).lowercased()] ?? "Another of your devices", name: Self.name($0.text(0)),
                                     project: Self.place($0.text(0)), keptUntil: $0.int(2), itemId: itemKey($0.text(0)))
        }
    }
    /// The Cloud page's numbers: files in the Cloud folder that travel, and their size (what this Mac and the Cloud agree on).
    /// Delete rule (integration): every file the Cloud page counts, by its path relative to the folder; read only, for
    /// the AI tools' targets (`counts()`'s rows). No Bin entry is here.
    public func trackedPaths() throws -> [String] {
        try state().rows("SELECT path FROM folder_base ORDER BY path").map { $0.text(0) }
    }
    public func counts() throws -> (files: Int, bytes: Int64) {
        let row = try state().first("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM folder_base")
        return (Int(row?.int(0) ?? 0), row?.int(1) ?? 0)
    }
    /// The daily sweep: kept versions and Bin items older than 30 days, and opened copies, go. Review 14 Nov (cost):
    /// the safety copy goes after its 30 days, and the engine's retained copies no current file or unsent change needs.
    /// Only on the service clock (as instruction files, `BackendCloudBootFilesApply.sweepDaily`): a Mac clock that is
    /// ahead must never empty the Bin, the kept versions or the safety copy. Returns false when it did not run.
    @discardableResult
    public func sweepDaily() async throws -> Bool {
        await enter()
        defer { leave() }
        guard outbox?.serviceTime() != nil else { return false }
        let t = now()
        try keeper().sweepVersions(kind: profile.keeperKind, keptUntilBefore: t)
        try keeper().sweepBin(kind: profile.keeperKind, keptUntilBefore: t)
        try state().run("DELETE FROM folder_lines WHERE kept_until<=?", [.int(t)])
        try? FileManager.default.removeItem(at: stateRoot.appendingPathComponent("opened", isDirectory: true))
        try sweepSafetyCopies(at: t)
        _ = try await core().sweepRetained()
        return true
    }
    /// Safety copies made more than 30 days ago go (a new one is made before the next replace or removal).
    func sweepSafetyCopies(at t: Int64) throws {
        let fm = FileManager.default
        let base = stateRoot.appendingPathComponent("safety", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where !name.hasPrefix(".") {
            let made = Self.safetyStamp.date(from: name).map { Int64($0.timeIntervalSince1970 * 1000) }
            guard let made, t - made > CloudFolderFormat.safetyKeptFor else { continue }
            let url = base.appendingPathComponent(name, isDirectory: true)
            try? fm.removeItem(at: url)
            if try control("safetyCopy") == url.path { try setControl("safetyCopy", nil) }
        }
    }
    static var safetyStamp: DateFormatter {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyyMMdd-HHmmss"
        return format
    }
    /// A version kept for one file: only the newest stays (the ONE 30-day version he can open; review 14 Nov, cost).
    @discardableResult
    func keepVersion(itemKey: String, name: String, place: String?, at: Int64, device: String, content: Data, now: Int64) throws -> Int64 {
        let until = try keeper().keep(kind: profile.keeperKind, itemKey: itemKey, name: name, place: place, at: at, device: device, content: content, now: now)
        try keeper().keepNewestOnly(itemKey: itemKey)
        return until
    }
    /// His own work that sync set aside (an edit that lost to a newer one, a file Put back displaced): it may exist
    /// nowhere else, so it is kept under its own key (`<item>|mine`) that `keepNewestOnly` never touches; only the 30-day
    /// sweep removes it. Several pile up when several lose; all are kept.
    static func mineKey(_ path: String) -> String { itemKey(path) + "|mine" }
    func mineKey(_ path: String) -> String { itemKey(path) + "|mine" }
    @discardableResult
    func keepMine(_ path: String, at: Int64, content: Data, now: Int64) throws -> Int64 {
        try keeper().keep(kind: profile.keeperKind, itemKey: mineKey(path), name: Self.name(path), place: Self.place(path), at: at, device: deviceId,
                          content: content, now: now)
    }
    func keepBinnedHistory(_ path: String, replacingWith hash: String? = nil) throws {
        guard let old = try keeper().bin(itemKey: itemKey(path)), old.sha256 != hash,
              let bytes = keeper().content(kind: profile.keeperKind, sha256: old.sha256) else { return }
        // The normal single kept arrival may be trimmed; removed bytes keep their full 30 days under the existing
        // untrimmed own-history key, just like an edit displaced by Put back.
        try keeper().keep(kind: profile.keeperKind, itemKey: mineKey(path), name: old.name, place: old.place,
            at: old.removedAt, device: old.device, content: bytes, now: now())
    }
    func takeFromBin(_ itemKey: String, now: Int64) throws {
        let path = String(itemKey.dropFirst(profile.keeperKind.count + 1))
        try keepBinnedHistory(path)
        try keeper().binTake(itemKey: itemKey, now: now)
        try keeper().keepNewestOnly(itemKey: itemKey)
    }
    /// The Cloud page's lines for the Cloud folder, one per thing that holds files back or keeps them apart (names and
    /// plain words only). Empty when nothing does.
    public func pageLines() throws -> [String] {
        func names(_ key: String) throws -> [String] { try control(key).map { $0.split(separator: "\n").map(String.init) } ?? [] }
        var lines: [String] = []
        if try control("folderMissing") == "1" {
            lines.append(profile.keeperKind == Self.kind ? "Your Cloud folder is not on this Mac" : "Your artifacts folder is not on this Mac")
        }
        let waiting = try names("gateWaiting")
        let words = profile.words
        if !waiting.isEmpty { lines.append(words.gate(waiting)) }
        if try control("roomLow") == "1" { lines.append(words.roomLow) }
        if try control("folderFull") == "1" { lines.append(words.full) }
        if try control("dayFull") == "1", try control("day") == String(now() / CloudFolderFormat.day) { lines.append(words.dayFull) }
        if let busy = try control("busyFiles").flatMap(Int.init), busy > 0 { lines.append(words.busy(busy)) }
        if try control("diskLow") == "1" { lines.append(words.diskLow) }
        if let large = try control("tooLarge").flatMap(Int.init), large > 0 { lines.append(words.tooLarge(large)) }
        let secret = try names("secretNames"), spelling = try names("spellingNames"), clash = try names("clashNames")
        if !secret.isEmpty { lines.append(words.secret(secret)) }
        if !spelling.isEmpty { lines.append(words.spelling(spelling)) }
        if !clash.isEmpty { lines.append(words.clash(clash)) }
        return lines
    }

    // MARK: The safety copy

    /// Before the FIRST change that replaces or removes a file in his folder on this Mac: a copy of every file that
    /// travels, in the app's own folder (`<state>/safety/<date>`; APFS clones, so nearly free). Kept 30 days. A copy that
    /// cannot be made stops every replace and removal (one log line; tried again at the next look); new files still arrive.
    func ensureSafetyCopy() throws -> Bool {
        if let made = try control("safetyCopy"), FileManager.default.fileExists(atPath: made) { return true }
        let base = stateRoot.appendingPathComponent("safety", isDirectory: true)
        let target = base.appendingPathComponent(Self.safetyStamp.string(from: Date(timeIntervalSince1970: Double(now()) / 1000)), isDirectory: true)
        let staging = base.appendingPathComponent(".preparing", isDirectory: true)
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: staging)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for path in CloudFolderWalk.run(roots, kind: profile).files.keys {
                let to = staging.appendingPathComponent(path)
                try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let from = CloudFolderDisk.url(roots, path) else { continue }
                try fm.copyItem(at: from, to: to)
            }
            try fm.moveItem(at: staging, to: target)
        } catch {
            try? fm.removeItem(at: staging)
            CloudSyncDiagnostics.shared.info(profile.words.safetyCopyFailed)
            return false
        }
        try setControl("safetyCopy", target.path)
        return true
    }

    // MARK: Adding (the cloud.folder_add tool)

    /// Copies a file or folder into the top of the Cloud folder under a free name ("Name", "Name 2", ...). Returns the
    /// new path. Never the Cloud folder itself, anything inside it, or a folder that holds it.
    public func add(_ source: URL) throws -> URL {
        let from = source.resolvingSymlinksInPath().standardizedFileURL.path
        let mine = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard from != mine, !from.hasPrefix(mine + "/"), !mine.hasPrefix(from + "/"), FileManager.default.fileExists(atPath: from) else {
            throw NativeRPCError.invalidArguments("That cannot be copied into your Cloud folder (it is the folder itself, inside it, or not there).")
        }
        if !folderPresent() { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let name = URL(fileURLWithPath: from).lastPathComponent
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        for number in 1...99 {
            let candidate = number == 1 ? name : stem + " \(number)" + (ext.isEmpty ? "" : "." + ext)
            let target = folder.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: target.path) { continue }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: from), to: target)
            dirty = true
            return target
        }
        throw NativeRPCError.invalidArguments("Your Cloud folder already holds 99 items called “\(name)”.")
    }

    // MARK: A store the app fills itself (lane L3 slice 2: artifacts)

    /// Writes one file into this owner's folder (the app's artifacts store) inside a job, so it never races an arrival
    /// being placed: a new file only when none is there (`expecting` nil), else only over exactly the bytes with
    /// fingerprint `expecting`; every folder on the way checked, never through a link. The next look records it.
    public func storeWrite(_ relative: String, bytes: Data, modified: Int64?, expecting: String?) async throws {
        await enter()
        defer { leave() }
        guard profile.refusal(relative) == nil, Int64(bytes.count) <= profile.maximumFileBytes, !CloudFolderDisk.caseClash(roots, relative) else {
            throw CloudFailure.unsafeConfiguration
        }
        guard folderPresent(), try control("folderMissing") != "1", try deleteState().mark(at: relative) == nil else { throw CloudFailure.unavailable }
        if case .absent = CloudFolderDisk.read(roots, relative), try base(relative) != nil { throw CloudFailure.unavailable }
        try CloudFolderDisk.write(roots, relative, bytes: bytes, expecting: expecting)
        if let modified { CloudFolderDisk.setModified(roots, relative, modified) }
        dirty = true
    }
    /// Page remove is explicit Everywhere. Tools pass their AI actor through deleteItems instead.
    public func storeRemove(_ relative: String, expecting: String) async throws {
        let actor = await personActor()
        await enter(); defer { leave() }
        guard case .file(let bytes) = CloudFolderDisk.read(roots, relative), BackendCloudBrainMemoryHash.bytes(bytes) == expecting else {
            throw CloudFailure.versionChanged
        }
        try await removeItem(relative, intent: actor.intent(place: relative, scope: .everywhere), engine: core())
    }

}

// MARK: The sync core's adapter

extension BackendCloudFolder: CloudDomainAdapter {
    struct Incoming: Sendable {
        let operation: CloudOperation
        let archive: Bool
        let relative: String
        let hash: String
        let version: String
        let parents: [String]
    }
    /// Refusals before the engine stages a byte: another domain, an unreadable record, a key that is not
    /// `file/folder/<path>`, a path the Cloud folder never carries (secrets, hidden, links' names), a file over the limit.
    static func describe(_ operation: CloudOperation, kind: CloudFileKind = .cloudFolder) throws -> Incoming {
        func refuse(_ reason: String) -> CloudRecordRefusal { CloudRecordRefusal(operationIds: [operation.opId], reason: reason) }
        guard operation.domain == kind.domain else { throw refuse(notCarried) }
        let key: String, hash: String, size: Int64, archive: Bool, version: String, parents: [String]
        do {
            let payload = try CloudWire.canonical(operation.payload)
            switch operation.kind {
            case .put:
                let part = try CloudWire.decode(CloudBrainMemoryPart.self, from: payload, allowedKeys: BackendCloudBrainFiles.partKeys, maximumBytes: 65_536)
                guard let declared = Int64(part.bytes), declared >= 0 else { throw CloudFailure.invalidRequest }
                key = part.key; hash = part.resourceHash; size = declared; archive = false; version = part.version; parents = part.parents
            case .archive:
                let marker = try CloudWire.decode(CloudBrainFilesArchiveMarker.self, from: payload, allowedKeys: BackendCloudBrainFiles.markerKeys, maximumBytes: 65_536)
                key = marker.key; hash = marker.resourceHash; size = 0; archive = true; version = marker.version; parents = marker.parents
            default: throw CloudFailure.unsupportedFormat
            }
        } catch { throw refuse(engineRefusal) }
        let prefix = "file/" + kind.sourceId + "/"
        guard key.hasPrefix(prefix) else { throw refuse(notCarried) }
        let relative = String(key.dropFirst(prefix.count))
        guard kind.refusal(relative) == nil, size <= kind.maximumFileBytes else { throw refuse(notCarried) }
        return Incoming(operation: operation, archive: archive, relative: relative, hash: hash, version: version, parents: parents)
    }
    static func refusal(_ failure: CloudFailure) -> CloudRecordRefusal? {
        switch failure {
        case .invalidRequest, .unsupportedFormat, .checksumMismatch, .idReused: return CloudRecordRefusal(reason: engineRefusal)
        default: return nil
        }
    }

    public func sourceInventory() async throws -> [CloudSourceInventory] {
        try await coverage().map {
            CloudSourceInventory(sourceId: $0.sourceId, inventoryRow: $0.inventoryRow, domain: profile.domain, items: $0.items, bytes: $0.bytes,
                                 complete: $0.complete, blockedReasons: $0.blockedReasons, exclusions: $0.exclusions)
        }
    }
    /// What travels (counted), what waits (said plainly), and what is left out on purpose (named).
    public func coverage() async throws -> [CloudCoverage] {
        let counted = try counts()
        var gaps: [String] = []
        // Review 14 Nov: every line the page says (what holds files back, what stays behind, named).
        let large = try control("tooLarge").flatMap(Int.init) ?? 0
        gaps += try pageLines().filter { large == 0 || $0 != profile.words.tooLarge(large) }
        var exclusions = profile.words.exclusions
        if large > 0 { exclusions.append(profile.words.tooLarge(large)) }
        return [CloudCoverage(sourceId: "files/" + profile.inventoryRow + "/" + profile.sourceId, inventoryRow: profile.inventoryRow,
                              complete: gaps.isEmpty, items: counted.files, bytes: counted.bytes, blockedReasons: gaps, exclusions: exclusions)]
    }
    public func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot { throw CloudFailure.unsupportedFormat }
    public func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
        do { let engine = try core(); return await engine.snapshotPages(cut: cut) } catch {
            let failure = error
            return AsyncThrowingStream { $0.finish(throwing: failure) }
        }
    }
    public func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let engine = try await self.core()
                    for try await operation in await engine.changes(after: after) {
                        for record in try await travelOperations([operation]) { continuation.yield(record) }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    public func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
        var refused: [String] = [], reason: String?
        for operation in operations {
            do {
                if CloudFileDeleteRecords.isAbout(operation) {
                    // Review 15 Nov (MUST 3): a damaged, newer-format or misplaced about-record is a refusal of that one
                    // record (the sync core parks it and the pack goes on), and its removal is applied the safe way.
                    guard operation.domain == profile.domain else {
                        throw CloudRecordRefusal(operationIds: [operation.opId], reason: CloudFileDeleteRecords.aboutRefusal)
                    }
                    do { _ = try CloudFileDeleteRecords.read(operation) }
                    catch { CloudFileDeleteRecords.noteRefused(operation, in: try state()); throw error }
                    continue
                }
                _ = try Self.describe(operation, kind: profile)
            }
            catch let refusal as CloudRecordRefusal {
                if reason == nil { reason = refusal.reason }
                if refusal.reason == reason { refused += refusal.operationIds }
            }
        }
        if let reason { throw CloudRecordRefusal(operationIds: refused, reason: reason) }
        // Review 14 Nov (cost): below 2 GB free nothing that arrives is kept; the records wait (parked, tried again later)
        // and the page says why. Packs are one domain each, so memory and everything else keep arriving.
        if try checkDisk() { throw CloudRecordRefusal(operationIds: operations.map(\.opId), reason: Self.diskLowRefusal) }
        do { return try await CloudFileDeleteRecords.prepare(operations, files: files, engine: core()) }
        catch let failure as CloudFailure { if let refusal = Self.refusal(failure) { throw refusal }; throw failure }
    }
    /// The engine keeps the records and writes the copy; then each touched path is settled into his folder here.
    public func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
        await enter()
        defer { leave() }
        let engine = try core()
        // Review 15 Nov (MUST 4, 5): this pack's about-records are saved first, each checked against the VERIFIED signer
        // of the pack. A forged one is refused before anything of the pack takes effect.
        try CloudFileDeleteRecords.takeAbouts(prepared.operations, signer: origin.deviceId, domain: profile.domain, in: state())
        await finishArrivedRemovals(engine: engine)
        let incoming = try prepared.operations.filter { !CloudFileDeleteRecords.isAbout($0) }.map { try Self.describe($0, kind: profile) }
        let announced = await deleteRuleAnnounced(origin.deviceId.lowercased())
        var travels: [String: CloudDeleteTravelRemoval] = [:], cloudOnly: Set<String> = []
        for item in incoming where item.archive {
            let travel = CloudFileDeleteRecords.arrivedRemoval(item.operation, place: item.relative, signer: origin.deviceId,
                                                               announced: announced, in: try state())
            travels[item.operation.opId] = travel
            if case .intent(let intent) = travel, intent.scope == .cloud { cloudOnly.insert(item.relative) }
        }
        // His unsent edits are recorded first, so an arrival can never pass for a successor of an edit it never saw.
        if try hasReadCloud(), await everyMacUnderstands() {
            for path in Set(incoming.map(\.relative)) where !cloudOnly.contains(path) {
                do { _ = try await settle(path, engine: engine) } catch CloudFailure.unsafeConfiguration {}
            }
            while try await engine.reconcile(sourceId: profile.sourceId, limit: 4096).remaining {}
        }
        let receipt: CloudImportReceipt
        do { receipt = try await CloudFileDeleteRecords.apply(prepared, origin: origin, engine: engine, db: state(), row: profile.inventoryRow) }
        catch let failure as CloudFailure { if let refusal = Self.refusal(failure) { throw refusal }; throw failure }
        var seen: Set<String> = []
        for item in incoming where !item.archive {
            // A new version from another device: the place is in the Cloud again, its old "Cloud" choice is forgotten.
            try CloudFileDeleteRecords.forgetCleared(item.relative, in: state())
            // Review 14 Nov (point 9): kept beside under a plain new name; never placed over the other file, never a removal.
            if try deleteState().mark(at: item.relative) == nil, try await keptBesideByCapitals(item, engine: engine) { continue }
            try state().run("INSERT OR IGNORE INTO folder_arrived(path) VALUES (?)", [.text(item.relative)])
        }
        var removals = false
        for item in incoming where seen.insert(item.version + "\n" + item.relative).inserted {
            if item.archive {
                let travel = travels[item.operation.opId]
                    ?? .intent(CloudFileDeleteRecords.safeIntent(item.operation, place: item.relative, signer: origin.deviceId))
                try removalArrived(path: item.relative, version: item.version, parents: item.parents, createdAt: item.operation.createdAt,
                                   device: origin.deviceId.lowercased(), travel: travel)
                removals = true
                continue
            }
            if try deleteState().mark(at: item.relative)?.mark == .onlyOnThisMac,
               try await engine.currentVersion(sourceId: profile.sourceId, relative: item.relative)?.version == item.version {
                // A new put on top of a Cloud removal reunites every device. Preserve this device's differing bytes.
                if case .file(let local) = CloudFolderDisk.read(roots, item.relative), BackendCloudBrainMemoryHash.bytes(local) != item.hash {
                    try keepMine(item.relative, at: now(), content: local, now: now())
                    try setBase(item.relative, Base(hash: BackendCloudBrainMemoryHash.bytes(local), bytes: Int64(local.count), modified: now()))
                }
                try deleteState().clearMark(at: item.relative)
                try takeFromBin(itemKey(item.relative), now: now())
            }
            try await keptBeside(item, engine: engine)
        }
        // The removals of this pack, applied once (one walk of the folder, not one per removal). Never an error of the pack.
        if removals { await retryRemovalHeads(engine: engine) }
        try await placeArrivals(engine: engine)
        return receipt
    }
    /// A version the engine kept beside the copy (made apart from the copy's version): the newer of the two goes into
    /// the copy (and from there into his folder); the other is kept 30 days.
    func keptBeside(_ item: Incoming, engine: BackendCloudBrainFiles) async throws {
        guard let current = try await engine.currentVersion(sourceId: profile.sourceId, relative: item.relative), current.version != item.version,
              current.rawHash != item.hash, case .file(let copyBytes) = CloudFolderDisk.read(copyRoot, item.relative),
              BackendCloudBrainMemoryHash.bytes(copyBytes) == current.rawHash, let arrivedBytes = await engine.retainedBytes(item.hash) else { return }
        // Arrived on top of the copy's version: the engine already wrote it; nothing was kept beside.
        if item.parents.contains(current.version) { return }
        let t = now()
        let pick = CloudBootFilesRules.newest(local: .init(at: current.createdAt, device: current.originDevice, firstCopy: current.parents.isEmpty),
                                              arrived: .init(at: item.operation.createdAt, device: item.operation.originDevice, firstCopy: item.parents.isEmpty), now: t)
        let key = itemKey(item.relative)
        if pick == .local {
            try keepVersion(itemKey: key, name: Self.name(item.relative), place: Self.place(item.relative), at: item.operation.createdAt,
                              device: item.operation.originDevice, content: arrivedBytes, now: t)
            return
        }
        // The arrived one is newer: it becomes the copy's bytes, then reaches his folder. Echo fix (14 Nov): the copy's
        // row ADOPTS the arrived version (an import), so nothing is journaled or uploaded again: the other Mac picked the
        // same version by the same rule, and both now hold it under one version id.
        try CloudFolderDisk.write(copyRoot, item.relative, bytes: arrivedBytes, expecting: current.rawHash)
        CloudFolderDisk.setModified(copyRoot, item.relative, item.operation.createdAt)
        try await engine.adoptArrival(sourceId: profile.sourceId, relative: item.relative, version: item.version, parents: item.parents,
                                      createdAt: item.operation.createdAt, rawHash: item.hash, rawBytes: Int64(arrivedBytes.count),
                                      originDevice: item.operation.originDevice)
        // The one line: the other Mac's newer file is in use; this Mac's version is kept (placing it keeps the bytes).
        try state().run("INSERT OR REPLACE INTO folder_lines(path,device,kept_until,at) VALUES (?,?,?,?)",
                        [.text(item.relative), .text(item.operation.originDevice), .int(t + CloudBootFilesRules.keptFor), .int(t)])
        while try await engine.reconcile(sourceId: profile.sourceId, paths: [item.relative], limit: 16).remaining {}
    }
    /// A file that arrived under a name that differs only by capitals from one here ("plan.md" while "Plan.md" is
    /// here): the engine kept its bytes aside (`case-clash`); it is written beside the file here as
    /// "plan (from MacBook Pro).md" (once: the same bytes already beside it are not written again). True when handled.
    func keptBesideByCapitals(_ item: Incoming, engine: BackendCloudBrainFiles) async throws -> Bool {
        guard try await engine.currentVersion(sourceId: profile.sourceId, relative: item.relative) == nil,
              CloudFolderDisk.caseClash(copyRoot, item.relative) || CloudFolderDisk.caseClash(roots, item.relative) else { return false }
        guard let bytes = await engine.retainedBytes(item.hash), folderPresent() else { return true }
        let mac = await macName(item.operation.originDevice.lowercased()) ?? "another device"
        let parent = (item.relative as NSString).deletingLastPathComponent, name = Self.name(item.relative)
        for number in 1...99 {
            let besideName = CloudFolderFormat.besideName(name, mac: mac, number: number)
            let beside = parent.isEmpty ? besideName : parent + "/" + besideName
            guard profile.refusal(beside) == nil else { return true }
            switch CloudFolderDisk.read(roots, beside) {
            case .file(let there):
                if BackendCloudBrainMemoryHash.bytes(there) == item.hash { return true }
                continue
            case .blocked: continue
            case .absent:
                if CloudFolderDisk.caseClash(roots, beside) { continue }
                try CloudFolderDisk.write(roots, beside, bytes: bytes, expecting: nil)
                dirty = true
                return true
            }
        }
        return true
    }
    public func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification {
        try await CloudFileDeleteRecords.verify(receipt, db: state(), engine: core(), keeper: keeper(), kind: profile.keeperKind)
    }
}

/// The Cloud folder owns its domain from the start and never takes part in a first saved copy: its records travel as
/// ordinary packs only (like instruction files).
extension BackendCloudFolder: CloudDomainWithoutSetup {
    public nonisolated var declaredDomains: Set<String> { [profile.domain] }
}

extension BackendCloudFolder: CloudDeleteOwning {
    func deleteState() throws -> CloudDeleteState {
        if let deleteStateMade { return deleteStateMade }
        let made = try CloudDeleteState(files: state())
        deleteStateMade = made
        return made
    }
    public func localMark(path: String) throws -> CloudLocalMark? { try deleteState().mark(at: path)?.mark }
    func rootUnavailable() throws -> Bool {
        // Project folders: a whole walk per arrival would be costly; a project not on this Mac simply waits (`locate`).
        if roots.isMany { return roots.all.isEmpty }
        let walk = CloudFolderWalk.run(roots, kind: profile)
        let hadFiles = try state().first("SELECT 1 FROM folder_base LIMIT 1") != nil
        return !walk.present || !walk.reliable || (walk.files.isEmpty && hadFiles)
    }
    /// J-7: bytes this place held before (the copy now, this Mac's own journal, or what arrived). One query (point 12).
    func wasCloudVersion(_ path: String, hash: String, engine: BackendCloudBrainFiles) async throws -> Bool {
        if case .file(let bytes) = CloudFolderDisk.read(copyRoot, path), BackendCloudBrainMemoryHash.bytes(bytes) == hash { return true }
        return try await engine.knownVersion(sourceId: profile.sourceId, relative: path, rawHash: hash)
    }
    func deleteItem(_ path: String) -> CloudDeleteItem {
        .init(id: path, kind: profile.keeperKind, name: Self.name(path), place: path)
    }
    func personActor() async -> CloudDeleteActor {
        let name = await macName(deviceId) ?? "This Mac"
        return .init(by: .person, mac: deviceId, macName: name, at: now(), group: UUID().uuidString.lowercased())
    }
    func group(_ intent: CloudDeleteIntent, path: String) async -> CloudBinGroup {
        let name = await macName(intent.mac.lowercased()) ?? (intent.mac.lowercased() == deviceId ? "This Mac" : "Another of your devices")
        return .init(id: intent.group, by: intent.by, macName: name, session: intent.session, agent: intent.agent,
                     at: intent.at, items: [deleteItem(path)])
    }
    /// Durable metadata is kept until the engine's removal reaches the outbox; it is not consumed on reads. Review 15 Nov
    /// (decision 6 as changed): the gate is read again HERE, at send time, and the queue never waits for it. Closed: an
    /// "Everywhere" removal goes now in the old compatible form (no about-record); a "Cloud" removal is withdrawn (not
    /// sent; `withdrawCloudRemovals` puts the file back in sync). Nothing new-format ever reaches an older build.
    func travelOperations(_ operations: [CloudOperation]) async throws -> [CloudOperation] {
        var result: [CloudOperation] = []
        for operation in operations {
            if operation.kind == .archive {
                let path = String(operation.source.recordId.dropFirst(("file/" + profile.sourceId + "/").count))
                let intent = try CloudFileDeleteRecords.intent(for: operation, place: path, in: state())
                if intent == nil, try state().first("SELECT 1 FROM file_delete_sending WHERE place=?", [.text(path)]) != nil {
                    // Never attach a newer delete's intent to an older journal entry at the same path.
                    // The owner wakes this same pump again as soon as the exact operation id is bound.
                    throw CloudFailure.unavailable
                }
                if let intent {
                    if try CloudFileDeleteRecords.isWithdrawn(operation, in: state()) { continue }
                    if await deleteRuleOpen() { result.append(try CloudFileDeleteRecords.operation(operation, intent: intent)) }
                    else if intent.scope == .cloud {
                        let parents = (try? Self.describe(operation, kind: profile))?.parents ?? []
                        try CloudFileDeleteRecords.withdraw(operation, place: path, parents: parents, in: state())
                        dirty = true
                        continue
                    }
                }
            }
            result.append(operation)
        }
        return result
    }
    /// Record the journal's exact removal id before exposing it to the pump.
    func rememberRemovalMetadata(_ path: String, intent: CloudDeleteIntent, engine: BackendCloudBrainFiles) async throws {
        if let row = try state().first("SELECT body,after_seq FROM file_delete_sending WHERE place=?", [.text(path)]), let bytes = row.data(0) {
            let saved = try JSONDecoder().decode(CloudDeleteIntent.self, from: bytes)
            var sequence = row.int(1), found = false
            while let resource = try await engine.journalResource(after: sequence) {
                sequence = resource.sequence
                guard resource.relative == path, resource.kind == .archive else { continue }
                let (operation, _) = try await engine.operation(resource, index: 0)
                try CloudFileDeleteRecords.saveAbout(CloudFileDeleteRecords.operation(operation, intent: saved), signer: deviceId, in: state())
                found = true
                break
            }
            guard found else { throw CloudFailure.unavailable }
        }
        try state().run("DELETE FROM file_delete_sending WHERE place=?", [.text(path)])
        engine.hub.post()
    }

    /// The single-item removal (review 15 Nov, MUST 1). Its intent is written HERE and lives only inside this call: any
    /// failure before the engine has journaled the removal clears it and undoes what was done (the private copy and his
    /// file come back, the Bin entry goes), so a press that showed an error can never delete anything afterwards. Only a
    /// crash past the Bin step leaves an intent, and only such an intent is resumed after a restart.
    /// `wasHere`: his file was in the folder when the act began (false for a removal an AI already made in the folder).
    func removeItem(_ path: String, intent: CloudDeleteIntent, engine: BackendCloudBrainFiles, wasHere: Bool = true) async throws {
        guard profile.refusal(path) == nil, !CloudFolderDisk.caseClash(roots, path), !CloudFolderDisk.caseClash(copyRoot, path),
              try hasReadCloud(), await everyMacUnderstands() else { throw CloudFailure.unavailable }
        if intent.scope == .cloud, !(await deleteRuleOpen()) { throw NativeRPCError.invalidArguments(CloudDeleteWords.cloudNeedsUpdatedMacs) }
        try CloudFileDeleteRecords.forgetCleared(path, in: state())
        try deleteState().putIntent(intent)
        do {
            if intent.scope == .everywhere, case .file(let local) = CloudFolderDisk.read(roots, path) {
                try deleteState().clearMark(at: path)
                var copyHash: String?
                if case .file(let copy) = CloudFolderDisk.read(copyRoot, path) { copyHash = BackendCloudBrainMemoryHash.bytes(copy) }
                let hash = BackendCloudBrainMemoryHash.bytes(local)
                if hash != copyHash {
                    if case .file(let copy) = CloudFolderDisk.read(copyRoot, path) {
                        try keepVersion(itemKey: itemKey(path), name: Self.name(path), place: Self.place(path), at: now(), device: deviceId, content: copy, now: now())
                    }
                    try CloudFolderDisk.write(copyRoot, path, bytes: local, expecting: copyHash, cloneFrom: cloneSource(folderFile: path))
                }
                while try await engine.reconcile(sourceId: profile.sourceId, paths: [path], limit: 4096).remaining {}
            }
            try await journalRemoval(path, intent: intent, engine: engine)
        } catch {
            if try await engine.currentVersion(sourceId: profile.sourceId, relative: path) == nil, try CloudFileDeleteRecords.binned(place: path, in: state()) != nil {
                // The engine journaled the removal after all: it is done; only its bookkeeping is finished.
                await finishJournaled(path, intent: intent, engine: engine)
                return
            }
            await abandonRemoval(path, scope: intent.scope, engine: engine, restoreLocal: wasHere)
            throw error
        }
    }
    /// Undo an act that never reached the engine's journal: the intent and its markers go, the private copy comes back
    /// if it was removed, his file comes back if this act removed it, and a Bin entry for a file still here goes.
    /// Final look (point 2): its own markers are cleared LAST, after everything is put back; an undo that fails half-way
    /// (a disk error) stays recorded (`file_delete_undo`) and the next look's recovery runs it again, never the delete.
    func abandonRemoval(_ path: String, scope: CloudDeleteScope, engine: BackendCloudBrainFiles, restoreLocal: Bool) async {
        do {
            try state().run("INSERT OR REPLACE INTO file_delete_undo(place,scope,restore) VALUES (?,?,?)",
                            [.text(path), .text(scope.rawValue), .int(restoreLocal ? 1 : 0)])
            let binned = try CloudFileDeleteRecords.binned(place: path, in: state())
            if let binned, try await engine.currentVersion(sourceId: profile.sourceId, relative: path) != nil {
                let bytes = keeper().content(kind: profile.keeperKind, sha256: binned)
                if case .absent = CloudFolderDisk.read(copyRoot, path), let bytes { try CloudFolderDisk.write(copyRoot, path, bytes: bytes, expecting: nil) }
                if scope == .everywhere, restoreLocal, case .absent = CloudFolderDisk.read(roots, path), let bytes {
                    try CloudFolderDisk.write(roots, path, bytes: bytes, expecting: nil)
                }
                if case .file = CloudFolderDisk.read(roots, path), try keeper().bin(itemKey: itemKey(path))?.sha256 == binned {
                    try takeFromBin(itemKey(path), now: now())
                    try state().run("DELETE FROM file_delete_bin WHERE place=?", [.text(path)])
                }
            }
            try deleteState().clearIntent(at: path)
            try state().run("DELETE FROM file_delete_binned WHERE place=?", [.text(path)])
            try state().run("DELETE FROM file_delete_sending WHERE place=?", [.text(path)])
            try state().run("DELETE FROM file_delete_undo WHERE place=?", [.text(path)])
        } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
    }
    /// One removal of this Mac: Bin first, then his file (Everywhere), then the private copy, then the engine journals it.
    /// Everything up to the journal can throw (the caller undoes it); after the journal nothing shows an error.
    func journalRemoval(_ path: String, intent: CloudDeleteIntent, engine: BackendCloudBrainFiles) async throws {
        // Pin the format for this act. A gate change during an await must never turn Cloud into old Everywhere.
        let modern = await deleteRuleOpen()
        if intent.scope == .cloud, !modern { throw NativeRPCError.invalidArguments(CloudDeleteWords.cloudNeedsUpdatedMacs) }
        if let current = try await engine.currentVersion(sourceId: profile.sourceId, relative: path) {
            var retained: Data?
            if case .file(let bytes) = CloudFolderDisk.read(copyRoot, path) { retained = bytes }
            else if let binned = try keeper().bin(itemKey: itemKey(path)), binned.sha256 == current.rawHash {
                // A crash after the copy went, before the journal: the copy is made again from the Bin to finish.
                retained = keeper().content(kind: profile.keeperKind, sha256: binned.sha256)
                if let retained { try CloudFolderDisk.write(copyRoot, path, bytes: retained, expecting: nil) }
            }
            guard let bytes = retained, BackendCloudBrainMemoryHash.bytes(bytes) == current.rawHash else { throw CloudFailure.unavailable }
            let local = CloudFolderDisk.read(roots, path)
            if case .blocked = local { throw CloudFailure.unsafeConfiguration }
            if intent.scope == .everywhere, case .file(let data) = local, BackendCloudBrainMemoryHash.bytes(data) != current.rawHash { throw CloudFailure.versionChanged }
            guard try ensureSafetyCopy() else { throw CloudFailure.unavailable }
            try keepBinnedHistory(path, replacingWith: BackendCloudBrainMemoryHash.bytes(bytes))
            try keeper().binPut(kind: profile.keeperKind, itemKey: itemKey(path), name: Self.name(path), place: Self.place(path), path: path,
                                removedAt: intent.at, device: intent.mac, content: bytes, shown: profile.listed(path), now: now())
            try CloudFileDeleteRecords.rememberBin(await group(intent, path: path), place: path, in: state())
            // Past the Bin step: only from here does a crash leave an intent that a restart resumes.
            try state().run("INSERT OR REPLACE INTO file_delete_binned(place,hash) VALUES (?,?)", [.text(path), .text(current.rawHash)])
            try crashPointForTests?("press:afterBin")
            if intent.scope == .everywhere, case .file(let data) = local {
                try CloudFolderDisk.remove(roots, path, expecting: BackendCloudBrainMemoryHash.bytes(data))
            }
            // The pump can wake DURING reconcile. Persist attribution first, then bind its exact journal id.
            if modern {
                let after = try await engine.snapshotBegin()
                try state().run("INSERT OR REPLACE INTO file_delete_sending(place,body,after_seq) VALUES (?,?,?)",
                    [.text(path), .blob(try JSONEncoder().encode(intent)), .int(after)])
            }
            try CloudFolderDisk.remove(copyRoot, path, expecting: current.rawHash)
            try crashPointForTests?("press:afterCopy")
            while try await engine.reconcile(sourceId: profile.sourceId, paths: [path], limit: 4096).remaining {}
            guard try await engine.currentVersion(sourceId: profile.sourceId, relative: path) == nil else { throw CloudFailure.unavailable }
        } else {
            // Nothing in the Cloud to remove: only a journaled removal of this act (a crash before its bookkeeping) is
            // finished. An item that was never in the Cloud is refused (and its intent cleared by the caller).
            guard try CloudFileDeleteRecords.binned(place: path, in: state()) != nil else { throw CloudFailure.unavailable }
        }
        await finishJournaled(path, intent: intent, engine: engine)
    }
    /// After the engine journaled the removal: bind its about-record, then clear the act. Never an error for the person;
    /// what fails here stays for the next look's recovery (the intent is past the Bin step).
    func finishJournaled(_ path: String, intent: CloudDeleteIntent, engine: BackendCloudBrainFiles) async {
        do {
            try await rememberRemovalMetadata(path, intent: intent, engine: engine)
            try setBase(path, nil)
            // Point 9: "Only on this Mac" only where this Mac has the file.
            if intent.scope == .cloud, case .file = CloudFolderDisk.read(roots, path) {
                try deleteState().putMark(.init(place: path, mark: .onlyOnThisMac, at: intent.at))
            } else { try deleteState().clearMark(at: path) }
            try deleteState().clearIntent(at: path)
            try state().run("DELETE FROM file_delete_binned WHERE place=?", [.text(path)])
            try state().run("DELETE FROM folder_gone WHERE path=?", [.text(path)])
        } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
        dirty = true
    }
    /// One press or tool call: each item on its own, one group. An item that fails is named in the log and the rest go on
    /// (an AI working alone must not be stopped by one file); the group lists what was removed. Throws only when nothing
    /// could be removed.
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        await enter(); defer { leave() }
        let engine = try core()
        guard !items.isEmpty, Set(items.map(\.id)).count == items.count, items.allSatisfy({ profile.refusal($0.id) == nil }) else { throw CloudFailure.invalidRequest }
        if scope == .cloud, !(await deleteRuleOpen()) { throw NativeRPCError.invalidArguments(CloudDeleteWords.cloudNeedsUpdatedMacs) }
        await finishArrivedRemovals(engine: engine)
        var removed: [CloudDeleteItem] = [], failed: [String] = [], first: Error?
        for item in items {
            do {
                try CloudFileDeleteRecords.setRowError(item.id, nil, at: now(), in: state())
                try await removeItem(item.id, intent: actor.intent(place: item.id, scope: scope), engine: engine)
                removed.append(item)
            } catch {
                first = first ?? error
                failed.append(Self.name(item.id))
                // The answer names what was not removed: the page reads it per row from `rowErrors()`.
                try? CloudFileDeleteRecords.setRowError(item.id, CloudFileDeleteRecords.notRemovedLine, at: now(), in: state())
            }
        }
        if !failed.isEmpty {
            CloudSyncDiagnostics.shared.info("\(profile.label) delete: \(removed.count) removed, not removed: " + CloudFolderFormat.names(failed))
        }
        if removed.isEmpty, let first { throw first }
        return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at, items: removed)
    }
    public func notHere() async throws -> [CloudNotHereItem] {
        try deleteState().marks().filter { profile.listed($0.place) }.map { .init(item: deleteItem($0.place), mark: $0.mark, at: $0.at) }
    }
    /// The one line per row whose delete did not happen, by item id (a "Cloud" delete withdrawn because an older Mac
    /// appeared says `CloudDeleteWords.cloudNeedsUpdatedMacs`; an item that failed in a press says it was kept). The
    /// line goes when the person acts on that row again.
    public func rowErrors() throws -> [String: String] { try CloudFileDeleteRecords.rowErrors(in: state()) }
    /// Decision 6 as changed: a "Cloud" removal withdrawn at send time. Nothing was removed from the Cloud (the removal
    /// never left this Mac); this Mac's copy and engine come back on top of the version the other Macs hold, the "Only
    /// on this Mac" mark, Bin entry and intent go, and the file syncs normally again from the next reconcile.
    func withdrawCloudRemovals(engine: BackendCloudBrainFiles) async {
        do {
            for row in try state().rows("SELECT operation,place,parents FROM file_delete_withdrawn WHERE done=0") {
                let path = row.text(1)
                do {
                    if try await engine.currentVersion(sourceId: profile.sourceId, relative: path) == nil {
                        var bytes: Data?, here = false
                        if case .file(let local) = CloudFolderDisk.read(roots, path) { bytes = local; here = true }
                        else if let kept = try keeper().bin(itemKey: itemKey(path)) { bytes = keeper().content(kind: profile.keeperKind, sha256: kept.sha256) }
                        if let bytes {
                            if case .absent = CloudFolderDisk.read(copyRoot, path) { try CloudFolderDisk.write(copyRoot, path, bytes: bytes, expecting: nil) }
                            await engine.setNextParents(sourceId: profile.sourceId, relative: path, parents: BackendCloudBrainFiles.strings(row.text(2)))
                            try setBase(path, Base(hash: BackendCloudBrainMemoryHash.bytes(bytes), bytes: Int64(bytes.count),
                                                   modified: CloudFolderDisk.modified(roots, path) ?? now()))
                            // In the Cloud, not on this Mac when he has no file here; otherwise simply in sync.
                            if here { try deleteState().clearMark(at: path) }
                            else { try deleteState().putMark(.init(place: path, mark: .notOnThisMac, at: now())) }
                            while try await engine.reconcile(sourceId: profile.sourceId, paths: [path], limit: 4096).remaining {}
                        }
                        if try keeper().bin(itemKey: itemKey(path)) != nil { try takeFromBin(itemKey(path), now: now()) }
                        try state().run("DELETE FROM file_delete_bin WHERE place=?", [.text(path)])
                    }
                    try deleteState().clearIntent(at: path)
                    try state().run("DELETE FROM file_delete_binned WHERE place=?", [.text(path)])
                    try CloudFileDeleteRecords.setRowError(path, CloudDeleteWords.cloudNeedsUpdatedMacs, at: now(), in: state())
                    try state().run("UPDATE file_delete_withdrawn SET done=1 WHERE operation=?", [.text(row.text(0))])
                    dirty = true
                } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
            }
        } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        await enter(); defer { leave() }
        let engine = try core()
        guard folderPresent() else { throw CloudFailure.unavailable }
        await finishArrivedRemovals(engine: engine)
        var restored: [CloudDeleteItem] = []
        for item in items {
            let path = item.id
            guard profile.refusal(path) == nil else { throw CloudFailure.invalidRequest }
            try CloudFileDeleteRecords.setRowError(path, nil, at: now(), in: state())
            try CloudFileDeleteRecords.forgetCleared(path, in: state())
            if to == .cloud {
                guard case .file(let local) = CloudFolderDisk.read(roots, path) else { throw CloudFailure.unavailable }
                // A Cloud-scope removal archived the copy: fresh capture inherits that removal's version.
                if case .file(let old) = CloudFolderDisk.read(copyRoot, path) {
                    try CloudFolderDisk.remove(copyRoot, path, expecting: BackendCloudBrainMemoryHash.bytes(old))
                }
                try CloudFolderDisk.write(copyRoot, path, bytes: local, expecting: nil, cloneFrom: cloneSource(folderFile: path))
                try setBase(path, Base(hash: BackendCloudBrainMemoryHash.bytes(local), bytes: Int64(local.count), modified: CloudFolderDisk.modified(roots, path) ?? now()))
                let before = try await engine.currentVersion(sourceId: profile.sourceId, relative: path)?.version
                while try await engine.reconcile(sourceId: profile.sourceId, paths: [path], limit: 4096).remaining {}
                if try await engine.currentVersion(sourceId: profile.sourceId, relative: path)?.version == before {
                    _ = try await engine.resend(sourceId: profile.sourceId, relative: path)
                }
                try deleteState().clearMark(at: path)
            } else {
                guard case .file(let bytes) = CloudFolderDisk.read(copyRoot, path) else { throw CloudFailure.unavailable }
                let local = CloudFolderDisk.read(roots, path)
                var hash: String?
                if case .blocked = local { throw CloudFailure.unsafeConfiguration }
                if case .file(let held) = local {
                    guard try ensureSafetyCopy() else { throw CloudFailure.unavailable }
                    try keepMine(path, at: now(), content: held, now: now())
                    hash = BackendCloudBrainMemoryHash.bytes(held)
                }
                try CloudFolderDisk.write(roots, path, bytes: bytes, expecting: hash)
                try deleteState().clearMark(at: path)
                try setBase(path, Base(hash: BackendCloudBrainMemoryHash.bytes(bytes), bytes: Int64(bytes.count), modified: CloudFolderDisk.modified(roots, path) ?? now()))
            }
            try takeFromBin(itemKey(path), now: now())
            restored.append(item)
        }
        return restored
    }
    /// The group a Bin entry belongs to (its press, or one group per Mac and day for entries from before the rule).
    func binGroupId(_ kept: CloudFolderKept) throws -> String {
        try CloudFileDeleteRecords.group(place: kept.path, in: state())?.id
            ?? CloudFileDeleteRecords.legacyGroupId(mac: kept.device, at: kept.at, era: .beforeNewRule)
    }
    public func binGroups() async throws -> [CloudBinGroup] {
        var groups: [CloudBinGroup] = []
        for kept in try bin() where profile.listed(kept.path) {
            if let group = try CloudFileDeleteRecords.group(place: kept.path, in: state()) { groups.append(group) }
            else {
                let name = await macName(kept.device.lowercased()) ?? "Another of your devices"
                groups.append(CloudFileDeleteRecords.legacyGroup(item: deleteItem(kept.path), mac: kept.device,
                    macName: name, at: kept.at, era: .beforeNewRule))
            }
        }
        return CloudFileDeleteRecords.merge(groups)
    }
    /// "Put back all" (review 15 Nov, point 11): the owner's only way back from a large AI delete. Every Bin entry of the
    /// group comes back, an artifact's description too; one that fails is named in the log and the rest go on. Answers
    /// what came back (the page compares with the group for what did not).
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] {
        var restored: [CloudDeleteItem] = [], failed: [String] = []
        for kept in try bin() {
            guard try binGroupId(kept) == group else { continue }
            do {
                if try await putBack(path: kept.path) { if profile.listed(kept.path) { restored.append(deleteItem(kept.path)) } }
                else if profile.listed(kept.path) { failed.append(kept.name) }
            } catch { if profile.listed(kept.path) { failed.append(kept.name) } }
        }
        if !failed.isEmpty {
            CloudSyncDiagnostics.shared.info("\(profile.label) Put back all: \(restored.count) back, not back: " + CloudFolderFormat.names(failed))
        }
        return restored
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        await enter(); defer { leave() }
        for item in items {
            guard profile.refusal(item.id) == nil else { throw CloudFailure.invalidRequest }
            try CloudFileDeleteRecords.deleteForGood(keeper(), itemKey: itemKey(item.id))
            try state().run("DELETE FROM file_delete_bin WHERE place=?", [.text(item.id)])
        }
    }

    // MARK: Removals that arrived (review 15 Nov, MUST 2 and 7)

    /// Every saved arrived removal on its own: one that fails waits for the next look and stops nothing; one that can
    /// never apply (never in the Cloud here, unreadable, a path the folder never carries) is dropped with one log line.
    func retryRemovalHeads(engine: BackendCloudBrainFiles) async {
        do {
            let heads = try CloudFileDeleteRecords.heads(in: state(), label: profile.label)
            guard !heads.isEmpty, try !rootUnavailable() else { return }
            for head in heads {
                do { try await applyHead(head, engine: engine) }
                catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
            }
        } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
    }
    func dropHead(_ head: CloudFileDeleteRecords.Head, why: String) throws {
        try CloudFileDeleteRecords.dropHead(place: head.place, in: state())
        CloudSyncDiagnostics.shared.info("\(profile.label) delete rule: an arrived removal of \(Self.name(head.place)) was dropped (\(why)); nothing was removed")
    }
    func applyHead(_ head: CloudFileDeleteRecords.Head, engine: BackendCloudBrainFiles) async throws {
        let path = head.place
        guard profile.refusal(path) == nil else { return try dropHead(head, why: "this file does not travel") }
        guard let current = try await engine.currentVersion(sourceId: profile.sourceId, relative: path) else {
            return try dropHead(head, why: "it was never in the Cloud on this Mac")
        }
        // An edit made on top of the removed version wins (ancestry, never dates).
        guard head.parents.contains(current.version) else { return }
        let travel: CloudDeleteTravelRemoval
        do { travel = try head.travel } catch { return try dropHead(head, why: "it could not be read") }
        let local = CloudFolderDisk.read(roots, path)
        if case .blocked = local { return }
        var cloudScope = false
        if case .intent(let intent) = travel, intent.scope == .cloud { cloudScope = true }
        let binGroup: CloudBinGroup
        if case .intent(let intent) = travel { binGroup = await group(intent, path: path) }
        else {
            let name = await macName(head.mac.lowercased()) ?? "Another of your devices"
            binGroup = CloudFileDeleteRecords.legacyGroup(item: deleteItem(path), mac: head.mac, macName: name, at: head.at, era: .olderVersion)
        }
        if cloudScope {
            // Scope Cloud never touches a device's file, including a differing local edit. The Cloud copy goes to the Bin.
            if case .file(let bytes) = CloudFolderDisk.read(copyRoot, path) {
                guard try ensureSafetyCopy() else { return }
                try keepBinnedHistory(path, replacingWith: BackendCloudBrainMemoryHash.bytes(bytes))
                try keeper().binPut(kind: profile.keeperKind, itemKey: itemKey(path), name: Self.name(path), place: Self.place(path), path: path,
                    removedAt: head.at, device: head.mac, content: bytes, shown: profile.listed(path), now: now())
                try CloudFileDeleteRecords.rememberBin(binGroup, place: path, in: state())
            }
            // Point 9: "Only on this Mac" only where this Mac has the file; with no file there is nothing to bring back.
            if case .file = local { try deleteState().putMark(.init(place: path, mark: .onlyOnThisMac, at: head.at)) }
            else { try deleteState().clearMark(at: path) }
        } else {
            if case .file(let bytes) = local, BackendCloudBrainMemoryHash.bytes(bytes) != current.rawHash { return }
            guard try ensureSafetyCopy() else { return }
            let retained: Data?
            if case .file(let bytes) = local { retained = bytes }
            else { retained = await engine.retainedBytes(current.rawHash) }
            guard let bytes = retained else { return }
            try keepBinnedHistory(path, replacingWith: BackendCloudBrainMemoryHash.bytes(bytes))
            try keeper().binPut(kind: profile.keeperKind, itemKey: itemKey(path), name: Self.name(path), place: Self.place(path), path: path,
                removedAt: head.at, device: head.mac, content: bytes, shown: profile.listed(path), now: now())
            try CloudFileDeleteRecords.rememberBin(binGroup, place: path, in: state())
            if case .file = local { try CloudFolderDisk.remove(roots, path, expecting: current.rawHash) }
            try deleteState().clearMark(at: path)
        }
        // MUST 7: the private copy's removal and the engine's "removed" are one step. The marker below is read before
        // anything reconciles (`finishArrivedRemovals`), so a crash between them never journals a removal of this Mac.
        try state().run("INSERT OR REPLACE INTO file_delete_applying(place) VALUES (?)", [.text(path)])
        try crashPointForTests?("arrival:beforeCopy")
        if case .file(let copy) = CloudFolderDisk.read(copyRoot, path) {
            guard BackendCloudBrainMemoryHash.bytes(copy) == current.rawHash else {
                try state().run("DELETE FROM file_delete_applying WHERE place=?", [.text(path)]); return
            }
            try CloudFolderDisk.remove(copyRoot, path, expecting: current.rawHash)
        }
        try crashPointForTests?("arrival:afterCopy")
        try await finishHead(head, engine: engine)
    }
    func finishHead(_ head: CloudFileDeleteRecords.Head, engine: BackendCloudBrainFiles) async throws {
        try await engine.adoptRemoval(sourceId: profile.sourceId, relative: head.place, version: head.version,
            parents: head.parents, createdAt: head.at, originDevice: head.mac)
        try setBase(head.place, nil)
        try state().run("DELETE FROM folder_gone WHERE path=?", [.text(head.place)])
        try CloudFileDeleteRecords.dropHead(place: head.place, in: state())
    }
    /// Arrived removals whose private copy was being removed when the app stopped: finished (copy, then the engine's
    /// "removed") before anything can reconcile and read the missing copy as this Mac's own removal.
    func finishArrivedRemovals(engine: BackendCloudBrainFiles) async {
        do {
            for row in try state().rows("SELECT place FROM file_delete_applying") {
                let path = row.text(0)
                do {
                    guard let head = try CloudFileDeleteRecords.head(place: path, in: state()) else {
                        try state().run("DELETE FROM file_delete_applying WHERE place=?", [.text(path)]); continue
                    }
                    guard let current = try await engine.currentVersion(sourceId: profile.sourceId, relative: path) else {
                        // The engine already holds the removal: only the bookkeeping is left.
                        try setBase(path, nil)
                        try CloudFileDeleteRecords.dropHead(place: path, in: state())
                        continue
                    }
                    guard head.parents.contains(current.version) else {
                        try state().run("DELETE FROM file_delete_applying WHERE place=?", [.text(path)]); continue
                    }
                    if case .file(let copy) = CloudFolderDisk.read(copyRoot, path) {
                        guard BackendCloudBrainMemoryHash.bytes(copy) == current.rawHash else {
                            try state().run("DELETE FROM file_delete_applying WHERE place=?", [.text(path)]); continue
                        }
                        try CloudFolderDisk.remove(copyRoot, path, expecting: current.rawHash)
                    }
                    try await finishHead(head, engine: engine)
                } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
            }
        } catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
    }

    // MARK: This Mac's own removals after a restart (review 15 Nov, MUST 1 and 2)

    /// Resumes ONLY removals already past the Bin step (a crash in the middle of an act). An intent that never reached the
    /// Bin is dropped; one whose file or Cloud version changed since is dropped too (his newer bytes win, never applied
    /// later). Each on its own: none can stop the look.
    func recoverDeleteIntents(engine: BackendCloudBrainFiles) async {
        guard folderPresent() else { return }
        let rows: [DeckMemoryRow]
        do { rows = try state().rows("SELECT place FROM cloud_delete_intents") }
        catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error); return }
        for row in rows {
            let path = row.text(0)
            var scope = CloudDeleteScope.cloud
            do {
                guard let intent = try deleteState().intent(at: path) else { continue }
                scope = intent.scope
                // An undo that failed half-way is finished, never the delete it undoes.
                if let undo = try CloudFileDeleteRecords.undoPending(path, in: state()) {
                    await abandonRemoval(path, scope: undo.scope, engine: engine, restoreLocal: undo.restore); continue
                }
                if case .blocked = CloudFolderDisk.read(roots, path) { continue }
                guard profile.refusal(path) == nil, let binned = try CloudFileDeleteRecords.binned(place: path, in: state()) else {
                    try deleteState().clearIntent(at: path)
                    CloudSyncDiagnostics.shared.info("\(profile.label) delete rule: an unfinished delete of \(Self.name(path)) that never reached the Bin was dropped; nothing was removed")
                    continue
                }
                if let current = try await engine.currentVersion(sourceId: profile.sourceId, relative: path) {
                    var changed = current.rawHash != binned
                    if intent.scope == .everywhere, case .file(let local) = CloudFolderDisk.read(roots, path), BackendCloudBrainMemoryHash.bytes(local) != binned { changed = true }
                    if case .file(let copy) = CloudFolderDisk.read(copyRoot, path), BackendCloudBrainMemoryHash.bytes(copy) != binned { changed = true }
                    if changed {
                        await abandonRemoval(path, scope: intent.scope, engine: engine, restoreLocal: false)
                        CloudSyncDiagnostics.shared.info("\(profile.label) delete rule: an unfinished delete of \(Self.name(path)) was dropped because the file changed since; it is kept")
                        continue
                    }
                }
                try await journalRemoval(path, intent: intent, engine: engine)
            } catch {
                if (try? await engine.currentVersion(sourceId: profile.sourceId, relative: path)) == nil { continue }
                await abandonRemoval(path, scope: scope, engine: engine, restoreLocal: false)
                CloudSyncDiagnostics.shared.info("\(profile.label) delete rule: an unfinished delete of \(Self.name(path)) could not be finished and was dropped; nothing more was removed")
            }
        }
    }

    // MARK: The once-only switch-over (spec E; review 15 Nov, MUST 2 and 8)

    /// Never an error of the look: a migration that cannot run now (no safety copy yet) is tried at the next look.
    func migrateDeleteRule(engine: BackendCloudBrainFiles) async {
        do { try await migrateDeleteRuleBody(engine: engine) }
        catch { _ = CloudSyncDiagnostics.shared.report(profile.label, error) }
    }
    /// One-time switch-over. A failed safety copy leaves every old row untouched and retries later. Every old row is
    /// removed as soon as it is handled, so a re-run after a half-way failure never handles it a second time.
    func migrateDeleteRuleBody(engine: BackendCloudBrainFiles) async throws {
        guard try control("deleteRuleMigrated") == nil else { return }
        if try control("deleteMigrationSafety") == nil {
            try setControl("safetyCopy", nil)
            guard try ensureSafetyCopy() else { return }
            try setControl("deleteMigrationSafety", "1")
        }
        let db = try state()
        func exists(_ table: String) throws -> Bool { try db.first("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", [.text(table)]) != nil }
        let hasHeld = try exists("folder_held"), hasConfirmed = try exists("folder_confirmed")
        var intended = 0, marked = 0, held = 0, previouslyGone = 0
        let oldBinCount = try keeper().binAll(kind: profile.keeperKind).count
        let migrationWalk = CloudFolderWalk.run(roots, kind: profile)
        let mayMark = migrationWalk.present && migrationWalk.reliable && !migrationWalk.files.isEmpty
        // E1, intended: the old build's Remove press writes `folder_confirmed` (its storeRemove unlinked the file and the
        // next look would have sent it). Sent as Everywhere when the file is still gone and the copy still holds the
        // bytes both last agreed on; otherwise nothing travels.
        if hasConfirmed {
            for row in try db.rows("SELECT path FROM folder_confirmed") {
                let path = row.text(0)
                do {
                    if profile.refusal(path) == nil, case .absent = CloudFolderDisk.read(roots, path), let known = try base(path),
                       case .file(let copy) = CloudFolderDisk.read(copyRoot, path), BackendCloudBrainMemoryHash.bytes(copy) == known.hash {
                        let actor = await personActor()
                        try await removeItem(path, intent: actor.intent(place: path, scope: .everywhere), engine: engine, wasHere: false)
                        intended += 1
                    }
                } catch {
                    CloudSyncDiagnostics.shared.info("\(profile.label) delete rule: the earlier Remove of \(Self.name(path)) was not sent; the file is kept in the Cloud")
                }
                try db.run("DELETE FROM folder_confirmed WHERE path=?", [.text(path)])
                try db.run("DELETE FROM folder_gone WHERE path=?", [.text(path)])
            }
        }
        // E1, by hand: every other queued absence is a local mark.
        for row in try db.rows("SELECT path FROM folder_gone") {
            let path = row.text(0)
            if mayMark, case .absent = CloudFolderDisk.read(roots, path), try deleteState().mark(at: path) == nil {
                try deleteState().putMark(.init(place: path, mark: .notOnThisMac, at: now())); marked += 1
            }
            try db.run("DELETE FROM folder_gone WHERE path=?", [.text(path)])
        }
        if hasHeld {
            for row in try db.rows("SELECT path,version,parents,created_at,device FROM folder_held") {
                let path = row.text(0)
                if case .file(let bytes) = CloudFolderDisk.read(roots, path) {
                    var expecting: String?
                    if case .file(let copy) = CloudFolderDisk.read(copyRoot, path) { expecting = BackendCloudBrainMemoryHash.bytes(copy) }
                    try CloudFolderDisk.write(copyRoot, path, bytes: bytes, expecting: expecting)
                    // Adopt only the old removal's ancestry, with bytes untouched, then capture on TOP of it.
                    try await engine.adoptRemoval(sourceId: profile.sourceId, relative: path, version: row.text(1),
                        parents: BackendCloudBrainFiles.strings(row.text(2)), createdAt: row.int(3), originDevice: row.text(4))
                    while try await engine.reconcile(sourceId: profile.sourceId, paths: [path], limit: 4096).remaining {}
                    held += 1
                }
                // Done for this row: a re-run never adopts it again over the version just captured.
                try db.run("DELETE FROM folder_held WHERE path=?", [.text(path)])
            }
            try crashPointForTests?("migration:afterHeld")
        }
        // Root guard wins even during migration: an unavailable/empty root creates no inferred marks.
        let walk = CloudFolderWalk.run(roots, kind: profile)
        if walk.present, walk.reliable, !walk.files.isEmpty {
            for row in try db.rows("SELECT path FROM folder_base") {
                let path = row.text(0)
                if case .absent = CloudFolderDisk.read(roots, path), try deleteState().mark(at: path) == nil,
                   try deleteState().intent(at: path) == nil {
                    try deleteState().putMark(.init(place: path, mark: .notOnThisMac, at: now())); previouslyGone += 1
                }
            }
        }
        try db.exec("DROP TABLE IF EXISTS folder_held; DROP TABLE IF EXISTS folder_confirmed; DELETE FROM folder_gone;")
        for key in ["massMissing", "brake:sentAt", "brake:sentCount", "brake:appliedAt", "brake:appliedCount"] { try setControl(key, nil) }
        try setControl("deleteRuleMigrated", "1")
        CloudSyncDiagnostics.shared.info("\(profile.label) delete rule: \(intended) intended, \(marked) queued marks, \(held) held files kept, \(previouslyGone) previously absent marks, \(oldBinCount) existing Bin items kept")
    }
}
