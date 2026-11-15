import Foundation
import TerminalDeckNativeCore

/// M4b: which of two versions of one shared value is shown. A PURE function of the two revisions, so every Mac picks
/// the same one; no local "now" is an input and the losing value is always kept as history.
///
/// Granularity (Decker: per FIELD where fields change independently, per row otherwise). Every memory table that
/// merges by this rule is decided PER ROW, because each of its rows is one value that changes as a whole:
/// - `settings`: one (owner, key) → value; the row IS the field.
/// - `notes`, `topics`, `handoffs`, `files`: index labels re-derived together from one file's front matter on each save;
///   the file itself merges as a whole resource.
/// KNOWN LIMIT (round 4, F): for `notes`, `topics`, `handoffs` and `files` the row is several labels. When two Macs change
/// DIFFERENT labels of one row at the same time (one closes a topic, the other renames it), the whole losing row is set
/// aside: one of the two changes shows on neither Mac (it stays in the account database as another version). The label
/// row and its file are also decided separately, so labels can come from one Mac and the file text from the other until
/// the file is next re-indexed. Per-label merging would need a stamp per column inside each version and a column-wise
/// merge and replay; not done in this round.
/// - `meta`: never travels (M3). Diary, board, board history, questions and rewinds never use this rule: two different
///   versions there are two kept rows.
enum DeckMemoryCloudMerge {
    struct Revision: Sendable, Equatable {
        let storeId: String
        let version: String
        /// The version's stamp: server-corrected milliseconds written once inside the revision when it was made.
        let stamp: Int64
        /// Rule J (lane A2 C1): made by a Mac that already held a Cloud version of this record, or could not know.
        let baseline: Bool
        /// The server's sequence for this version when known here. For display only: never an input to `winner`,
        /// because a Mac does not learn the sequence of its own versions and every Mac must decide a tie the same way.
        let sequence: CloudSequence?
        /// The service's commit time of this version when known here. For display only: never an input to `winner`
        /// (Decker: a stamp is final; nothing learned later changes the order).
        let committedAt: Int64?
        /// The opId of the revision's first part (lowest part index, then lowest opId: the same on every Mac).
        let opId: String
        /// Every earlier version this one descends from.
        let ancestors: Set<String>
    }
    /// THE single place that decides concurrent edits (Decker's M4b ruling, the same as lane A2's):
    /// 1. A causal descendant always wins over its ancestor.
    /// 2. Rule J, copied from lane A2 (design v2, D1.8, C1): "A captured revision is flagged baseline only when this Mac
    ///    already holds a Cloud head for that record at capture, or cannot know (a rebuild without the heads). A record the
    ///    Cloud does not have yet is an ordinary first revision, so the first Mac's own first upload is never baseline. In
    ///    the merge a baseline stamp loses to any non-baseline stamp of an unrelated revision, whatever the clocks say, and
    ///    its differing values become other versions; between two baseline stamps the older wins."
    /// 3. Otherwise the newer stamp wins. The stamp is the one written inside the version's first part (lowest part
    ///    index, then lowest opId), so twins published by two Macs from a copied store order the same everywhere.
    ///    Nothing learned later (commit time, receipt, another copy's stamp) is an input.
    /// 4. Equal stamps: the larger opId (never the server sequence: not every Mac knows it, so it could split a tie).
    static func winner(_ a: Revision, _ b: Revision) -> Revision {
        if a.version == b.version { return a }
        if a.ancestors.contains(b.version) { return a }
        if b.ancestors.contains(a.version) { return b }
        if a.baseline != b.baseline { return a.baseline ? b : a }
        if a.stamp != b.stamp {
            // Between two baselines the older wins; otherwise the newer.
            return (a.stamp > b.stamp) != a.baseline ? a : b
        }
        return a.opId > b.opId ? a : b
    }
}

/// M4b: the one injected clock for stamps: the sync owner's service time in milliseconds, or nil while its offset is
/// not known yet. With no clock injected (fixtures) this Mac's clock is used.
public typealias DeckMemoryCloudClock = @Sendable () -> Int64?

/// Run 14: a clock is kept beside its store under the store's identity, and that identity is the object's ADDRESS,
/// which is used again once a store is gone. Kept by the address alone, a new store took the clock a dead store had
/// left behind (a fixture's `{ 1_000 }`), so "service now minus this Mac's now" came out near minus today and a
/// snapshot file, a row and a live change were all stamped at about 0. Each clock is therefore held with a weak
/// reference to ITS store and answers only for that very store; what a dead store left is dropped.
final class DeckMemoryCloudClocks: @unchecked Sendable {
    static let shared = DeckMemoryCloudClocks()
    private struct Held { weak var store: DeckMemoryStore?; let clock: DeckMemoryCloudClock }
    private let lock = NSLock()
    private var clocks: [ObjectIdentifier: Held] = [:]
    func set(_ clock: DeckMemoryCloudClock?, for store: DeckMemoryStore) {
        lock.withLock {
            clocks = clocks.filter { $0.value.store != nil }
            clocks[ObjectIdentifier(store)] = clock.map { Held(store: store, clock: $0) }
        }
    }
    private func ownClock(of store: DeckMemoryStore) -> DeckMemoryCloudClock? {
        lock.withLock { () -> DeckMemoryCloudClock? in
            guard let held = clocks[ObjectIdentifier(store)], held.store === store else { return nil }
            return held.clock
        }
    }
    /// nil only while an injected service clock does not know its offset yet.
    func now(for store: DeckMemoryStore) -> Int64? {
        guard let injectedClock = ownClock(of: store) else { return Int64(Date().timeIntervalSince1970 * 1000) }
        return injectedClock()
    }
    func injected(_ store: DeckMemoryStore) -> Bool { ownClock(of: store) != nil }
}

/// Finding 26: memory scoped to a project from ANOTHER Mac is placed only under a local project the project list
/// confirms. The resolver answers "which local project id is this?" (nil = not matched yet: the memory waits).
/// Called inside the memory writer's transaction, so it is synchronous and must answer from data already in hand
/// (lane A2's published projectUid → local id table).
public typealias DeckMemoryCloudProjectResolver = @Sendable (_ incomingProjectId: String, _ originStoreId: String) -> String?

/// Y1 (13 Nov): what one release of waiting project memory did, for its one log line and for tests. Numbers and
/// project ids (the short names a project list shows, "terminal-deck") only: never content, paths or note ids.
public struct DeckMemoryCloudRelease: Sendable, Equatable {
    public var placed = 0
    /// Rows set aside in this run because they could not be placed, by plain reason.
    public var parked = 0
    public var parkedReasons: [String: Int] = [:]
    /// Every parked row on this Mac after the run (earlier runs included).
    public var parkedNow = 0
    /// Rows still waiting although their project IS on this Mac, by project id. 0 after a run that finished.
    public var waiting: [String: Int] = [:]
    /// Rows for projects that are on no device this Mac knows: they wait quietly, nothing for the person to do.
    public var waitingForAbsentProjects = 0
    public var absentProjects = 0
    /// 15 Nov: rows placed under a project this Mac holds only in its archive, and how many such projects.
    public var placedForArchived = 0
    public var archivedProjects = 0
    /// Index entries (notes, topics, files, handoffs labels) of an archived project whose file is not here: kept with
    /// the `history` mark, never shown as an entry that opens nothing, restored with their own labels once the file
    /// arrives (review M2).
    public var archivedIndexKeptAsHistory = 0
    /// This call found a release already running; that one takes this call's work (no line is written for it).
    public var joinedRunning = false
    public init() {}
    /// The one `cloud memory:` line.
    public var line: String {
        var parts = ["cloud memory: released \(placed)"]
        let still = waiting.values.reduce(0, +)
        if still > 0 {
            let named = waiting.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { "\($0.key) \($0.value)" }
            parts.append("still waiting \(still) for projects on this Mac (" + named.joined(separator: ", ") + ")")
        } else {
            parts.append("still waiting 0")
        }
        if parked > 0 || parkedNow > 0 {
            let reasons = parkedReasons.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.map { "\($0.value): \($0.key)" }
            parts.append("set aside \(parkedNow)" + (reasons.isEmpty ? "" : " (now: " + reasons.joined(separator: "; ") + ")") + ", tried again within 10 minutes")
        }
        if placedForArchived > 0 || archivedIndexKeptAsHistory > 0 {
            var said = "placed \(placedForArchived) for \(archivedProjects) archived project\(archivedProjects == 1 ? "" : "s")"
            if archivedIndexKeptAsHistory > 0 { said += " (\(archivedIndexKeptAsHistory) index entr\(archivedIndexKeptAsHistory == 1 ? "y" : "ies") kept until their files arrive)" }
            parts.append(said)
        }
        if waitingForAbsentProjects > 0 {
            // MAC-NEXT-7: said only for ids no project record of the account names (the release runs once this
            // Mac's project list is read, so a project whose record arrived is never counted here).
            parts.append("\(waitingForAbsentProjects) kept for \(absentProjects) project\(absentProjects == 1 ? "" : "s") that no signed-in device has")
        }
        return parts.joined(separator: "; ")
    }
}

/// Held like the clocks above, for the same reason (run 14): a new store must never answer with the project rule a
/// dead store left under the same address (the lean rule reads the DEAD store's memory folder).
final class DeckMemoryCloudProjects: @unchecked Sendable {
    static let shared = DeckMemoryCloudProjects()
    private struct Held { weak var store: DeckMemoryStore?; let resolver: DeckMemoryCloudProjectResolver }
    private let lock = NSLock()
    private var resolvers: [ObjectIdentifier: Held] = [:]
    func set(_ resolver: DeckMemoryCloudProjectResolver?, for store: DeckMemoryStore) {
        lock.withLock {
            resolvers = resolvers.filter { $0.value.store != nil }
            resolvers[ObjectIdentifier(store)] = resolver.map { Held(store: store, resolver: $0) }
        }
    }
    func resolver(for store: DeckMemoryStore) -> DeckMemoryCloudProjectResolver? {
        lock.withLock { () -> DeckMemoryCloudProjectResolver? in
            guard let held = resolvers[ObjectIdentifier(store)], held.store === store else { return nil }
            return held.resolver
        }
    }
}

extension DeckMemoryStore {
    static let cloudAppOwnedExcluded = "app_owned_help_file"
    static let cloudWaitingProject = "waiting_project_not_matched"

    /// The app writes these itself on every Mac (`writeStartHereFiles`); they never travel or import (M6).
    static func cloudIsAppOwnedFile(_ path: String) -> Bool {
        path == "START-HERE.md" || DeckMemoryFiles.pointers.contains { $0.file == path }
    }

    // MARK: Finding 26 — projects this Mac has not matched

    /// Sets (or clears) the resolver lane A2's project list supplies, then places any memory that was waiting for it.
    @discardableResult
    public func cloudSetProjectResolver(_ resolver: DeckMemoryCloudProjectResolver?) async throws -> Int {
        DeckMemoryCloudProjects.shared.set(resolver, for: self)
        guard cloudMemoryEnabled else { return 0 }
        return try await cloudRetryWaitingProjects()
    }
    /// The local project id for project-scoped memory, or nil when it must wait. Memory that originated on this Mac
    /// always keeps its own id.
    func cloudProjectTarget(_ incoming: String, origin: String) throws -> String? {
        try cloudProjectPlacement(incoming, origin: origin)?.id
    }
    /// Where project-scoped memory goes here: a project the project list confirms, or (15 Nov, the MacBook kept 80
    /// rows and the Mac mini 2 for good) a project this Mac holds in its ARCHIVE. An archived project is in no
    /// project list, so before this its rows from the other Mac (diary, notes, topics, file index) waited for a
    /// project record that never comes, while its files (paths under `archive/`) had already arrived: the MacBook
    /// showed none of 68 diary entries the Mac mini has. Now such rows go under the same archived id, exactly where
    /// this Mac's own rows of that project already are. Nothing is un-archived: no `projects/<id>` folder is made, so
    /// no project appears in any list (the lean rule reads `projects/` only). A project in neither place still waits.
    func cloudProjectPlacement(_ incoming: String, origin: String) throws -> (id: String, archived: Bool)? {
        if origin == (try cloudStoreId()) { return (incoming, false) }
        if let resolver = DeckMemoryCloudProjects.shared.resolver(for: self),
           let local = resolver(incoming, origin), !local.isEmpty, DeckMemoryOwner.folderName(local) == local { return (local, false) }
        // Review M1: project ids are name slugs, unique on ONE Mac only. Reaching here, no project record of the account
        // names this id on this Mac (the resolver answered nothing). The archive is used only when it is demonstrably
        // the SAME project as the other Mac's: an unrelated archived "website" here, or a live project whose record is
        // still on its way, keeps waiting as before.
        if cloudArchivedProjectHere(incoming), try cloudArchiveSharedWith(origin: origin, project: incoming) { return (incoming, true) }
        return nil
    }
    /// Review M1: this Mac's archive of `project` and the other Mac's memory of it are the same project when either
    /// (a) a FILE that this Mac placed under `archive/projects/<id>/` came from that very store (the MacBook: the Mac
    ///     mini's 16 archived files arrived under `archive/`, so the mini's rows of that id belong beside them), or
    /// (b) that store sent an INDEX ENTRY whose file is one of THIS Mac's own files under `archive/projects/<id>/` (the
    ///     Mac mini: the MacBook's two note entries name the mini's own archived files, so the MacBook holds them).
    /// Only these two kept facts are compared (store id plus the exact archive path prefix); never names or content.
    /// A yes is remembered for the store's life (it cannot become false: kept versions are never deleted); a no is
    /// asked again next time (the file may arrive later).
    func cloudArchiveSharedWith(origin: String, project: String) throws -> Bool {
        let memo = origin + "\n" + project
        if cloudArchiveShared.contains(memo) { return true }
        guard try cloudAttached() else { return false }
        let prefix = "archive/projects/" + project + "/", length = Int64(prefix.count)
        let ownStore = try cloudStoreId()
        let placedFromThem = try db.first("SELECT 1 FROM cloud_memory_versions WHERE store_id=? AND resource_key>='file/' AND resource_key<'file0' AND substr(projection,1,?)=? LIMIT 1",
                                          [.text(origin), .int(length), .text(prefix)]) != nil
        let theyNameOurs = placedFromThem ? true : try db.first("""
            SELECT 1 FROM cloud_memory_versions WHERE store_id=? AND resource_key>='row/' AND resource_key<'row0'
              AND json_extract(CAST(body AS TEXT),'$.references.path.table')='file'
              AND json_extract(CAST(body AS TEXT),'$.references.path.storeId')=?
              AND substr(json_extract(CAST(body AS TEXT),'$.references.path.id.value'),1,?)=? LIMIT 1
            """, [.text(origin), .text(ownStore), .int(length), .text(prefix)]) != nil
        guard placedFromThem || theyNameOurs else { return false }
        cloudArchiveShared.insert(memo)
        return true
    }
    /// This Mac's memory holds `archive/projects/<id>` as a folder (the same id, never matched by name or guess).
    func cloudArchivedProjectHere(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix("."), DeckMemoryOwner.folderName(id) == id else { return false }
        var directory: ObjCBool = false
        let folder = root.appendingPathComponent("archive", isDirectory: true).appendingPathComponent("projects", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory) && directory.boolValue
    }
    /// `projects/<id>/rest` mapped to this Mac's project, the same path when not project-scoped, nil when waiting.
    /// A project held here only in the archive takes the file into `archive/projects/<id>/rest`, beside its own
    /// archived files: a live `projects/<id>` folder would bring the archived project back.
    func cloudPlacementPath(_ logical: String, origin: String) throws -> String? {
        let parts = logical.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0] == "projects" else { return logical }
        guard let target = try cloudProjectPlacement(parts[1], origin: origin) else { return nil }
        return ((target.archived ? ["archive", "projects", target.id] : ["projects", target.id]) + parts.dropFirst(2)).joined(separator: "/")
    }
    /// An owner key moved to the confirmed local project ("project:x" → "project:y", "role:x/r" → "role:y/r").
    static func cloudRemapOwner(_ key: String, from: String, to: String) -> String {
        guard from != to, let owner = DeckMemoryOwner(key: key) else { return key }
        switch owner {
        case .project(let id) where id == from: return DeckMemoryOwner.project(to).key
        case .lead(let id) where id == from: return DeckMemoryOwner.lead(to).key
        case .role(let project?, let role) where project == from: return DeckMemoryOwner.role(project: to, role: role).key
        default: return key
        }
    }
    /// The per-account side table, created only in the attached Cloud database, never in memory.db.
    func cloudSideTable(_ name: String, _ columns: String) throws -> String {
        guard try cloudAttached() else { throw CloudFailure.unavailable }
        try db.exec("CREATE TABLE IF NOT EXISTS cloud.\(name)(\(columns))")
        return "cloud." + name
    }
    func cloudWaitingTable() throws -> String {
        let table = try cloudSideTable("cloud_memory_waiting_projects", "store_id TEXT NOT NULL,resource_key TEXT NOT NULL,revision TEXT NOT NULL,project_id TEXT NOT NULL,PRIMARY KEY(store_id,resource_key,revision)")
        // H: a project that becomes known releases its own rows by index, not by a walk of every waiting row.
        try db.exec("CREATE INDEX IF NOT EXISTS cloud.cloud_memory_waiting_by_project ON cloud_memory_waiting_projects(project_id,store_id)")
        return table
    }
    /// Retained durably, counted as "waiting: project not matched", never placed live; nothing local is touched.
    func cloudHoldForProject(_ p: CloudBrainMemoryPart, project: String, body: Data) throws -> CloudApplyStatus {
        let table = try cloudWaitingTable()
        try db.run("INSERT OR IGNORE INTO \(table)(store_id,resource_key,revision,project_id) VALUES (?,?,?,?)", [.text(p.storeId),.text(p.key),.text(p.version),.text(project)])
        try db.run("INSERT INTO cloud_memory_versions(store_id,resource_key,revision,content_hash,inventory,body,projection,projected_hash,parents) VALUES (?,?,?,?,?,?,NULL,NULL,?) ON CONFLICT(store_id,resource_key,revision) DO NOTHING",
                   [.text(p.storeId),.text(p.key),.text(p.version),.text(p.resourceHash),.text(p.inventoryRow),.blob(body),.blob(try CloudWire.canonical(p.parents))])
        return .applied
    }
    /// The waiting table for a READ (the Cloud pages, counts): nil when it does not exist yet. Creates nothing.
    func cloudWaitingTableForReading() throws -> String? {
        guard try cloudAttached() else { return nil }
        guard try db.first("SELECT 1 FROM cloud.sqlite_master WHERE type='table' AND name='cloud_memory_waiting_projects'") != nil else { return nil }
        return "cloud.cloud_memory_waiting_projects"
    }
    func cloudIsWaiting(_ p: CloudBrainMemoryPart) throws -> Bool {
        let table = try cloudWaitingTable()
        return try db.first("SELECT 1 FROM \(table) WHERE store_id=? AND resource_key=? AND revision=?", [.text(p.storeId),.text(p.key),.text(p.version)]) != nil
    }
    func cloudWaitingCount() throws -> Int {
        guard let table = try cloudWaitingTableForReading() else { return 0 }
        return Int(try db.first("SELECT COUNT(*) FROM \(table)")?.int(0) ?? 0)
    }
    /// Y1 (13 Nov): waiting rows by project, split into projects this Mac knows now (their rows are released by
    /// themselves) and projects that exist on no device this Mac knows (their rows wait quietly and are nothing the
    /// person has to do). Read only.
    func cloudWaitingByProject() throws -> (known: [String: Int], unknown: [String: Int]) {
        guard let table = try cloudWaitingTableForReading() else { return ([:], [:]) }
        var known: [String: Int] = [:], unknown: [String: Int] = [:]
        for g in try db.rows("SELECT project_id,store_id,COUNT(*) FROM \(table) GROUP BY project_id,store_id") {
            let project = g.text(0), number = Int(g.int(2))
            if try cloudProjectTarget(project, origin: g.text(1)) != nil { known[project, default: 0] += number }
            else { unknown[project, default: 0] += number }
        }
        return (known, unknown)
    }
    /// Rows still waiting although their project is on this Mac: what the release has not placed YET. Rows for projects
    /// that are nowhere here are not counted (they are nothing the person must do).
    func cloudReleasableCount() throws -> Int {
        try cloudWaitingByProject().known.values.reduce(0, +)
    }
    /// MAC-NEXT-7: 500 rows per transaction (was 2,000): the store is free for live memory writes about every 3 s
    /// instead of every 12 s while a long release runs.
    static let cloudReleaseBatch = 500
    /// A pass over at least this many rows says so when it starts, so minutes of work are explained in the log.
    static let cloudReleaseAnnounceRows = 1_000
    /// Y1: after this many row failures in a row that are database refusals, the database itself is in trouble, not a
    /// row: the pass stops (and says so) instead of parking every row behind it.
    static let cloudReleaseFailureStreak = 64
    /// A row that could not be placed is set aside here with its reason (kind of failure only, never content), out of
    /// the waiting table, so it never blocks the rows after it. Tried again at the first release of an opening, every
    /// 10 minutes and after a project or agent record was applied (MAC-NEXT-7).
    func cloudParkedTable() throws -> String {
        try cloudSideTable("cloud_memory_parked", "store_id TEXT NOT NULL,resource_key TEXT NOT NULL,revision TEXT NOT NULL,project_id TEXT NOT NULL,reason TEXT NOT NULL,at INTEGER NOT NULL,PRIMARY KEY(store_id,resource_key,revision)")
    }
    func cloudParkedCount() throws -> Int {
        guard try cloudAttached(), try db.first("SELECT 1 FROM cloud.sqlite_master WHERE type='table' AND name='cloud_memory_parked'") != nil else { return 0 }
        return Int(try db.first("SELECT COUNT(*) FROM cloud.cloud_memory_parked")?.int(0) ?? 0)
    }
    /// Places waiting project memory whose project is now on this Mac. Returns how many were placed.
    /// Kept for its callers and tests; the whole account of the pass is `cloudReleaseWaitingProjects()`.
    @discardableResult
    public func cloudRetryWaitingProjects() async throws -> Int {
        try await cloudReleaseWaitingProjects().placed
    }
    /// Y1 (13 Nov, the joining MacBook stopped after 8,000 of 47,334 rows). Cause, proven on a read-only copy of its
    /// store: every row of one batch shared ONE transaction, so one row that threw (`idReused` from
    /// `cloudResolveReference`, a note whose "supersedes" names a note this Mac had re-captured as its own, see Y3)
    /// rolled the whole batch back; the callers' `try?` hid it, and every later pass met the same row in its first
    /// batch and placed nothing. Now:
    /// - each row is placed inside its own savepoint: a row that fails is PARKED with its reason (out of the waiting
    ///   table, tried again once per opening) and the rows after it are placed;
    /// - the pass goes round again until nothing releasable is left: rows that arrived while it ran and calls that
    ///   landed meanwhile are taken in the same run (one run at a time);
    /// - it survives a restart: a row leaves the waiting table in the same transaction that places it, and every
    ///   opening releases again (activation, project list, Cloud page);
    /// - it never hides what happened: the result names what was placed, parked and still waiting, by project id
    ///   (never content), for one `cloud memory:` line.
    public func cloudReleaseWaitingProjects(announce: (@Sendable (String) async -> Void)? = nil) async throws -> DeckMemoryCloudRelease {
        guard cloudMemoryEnabled else { throw CloudFailure.unavailable }
        var total = DeckMemoryCloudRelease()
        guard !cloudReleaseRunning else {
            // The running pass takes whatever this call wanted released before it ends.
            cloudReleaseAgain = true
            total.joinedRunning = true
            return total
        }
        cloudReleaseRunning = true
        defer { cloudReleaseRunning = false }
        try cloudForgetLocalOnlyWaiting()
        if cloudParkedRetryAt.map({ now() >= $0 }) ?? true {
            cloudParkedRetryAt = now().addingTimeInterval(Self.cloudParkedRetryGap)
            try cloudUnparkAll()
        }
        var rounds = 0, archivedSeen: Set<String> = []
        cloudArchivedIndexKept = 0
        repeat {
            cloudReleaseAgain = false
            rounds += 1
            let pass = try await cloudReleaseOnce(announce: announce)
            total.placed += pass.placed; total.parked += pass.parked
            total.placedForArchived += pass.placedForArchived; archivedSeen.formUnion(pass.archivedProjects)
            for (reason, n) in pass.parkedReasons { total.parkedReasons[reason, default: 0] += n }
            // Re-armed: rows that arrived while this pass ran, or projects that became known meanwhile, go round again.
            if pass.queued == 0 && !cloudReleaseAgain { break }
            if pass.placed == 0 && pass.parked == 0 && !cloudReleaseAgain { break }
        } while rounds < 64
        let waiting = try cloudWaitingByProject()
        total.waiting = waiting.known
        total.waitingForAbsentProjects = waiting.unknown.values.reduce(0, +)
        total.absentProjects = waiting.unknown.count
        total.parkedNow = try cloudParkedCount()
        total.archivedProjects = archivedSeen.count
        total.archivedIndexKeptAsHistory = cloudArchivedIndexKept
        // Kept-as-history entries are counted as placed by the pass (they leave the waiting table); the line says them apart.
        total.placedForArchived -= min(total.placedForArchived, cloudArchivedIndexKept)
        if total.placed > 0 { noteFiles.removeAll(); hub.post(.init(area: .index, at: now())) }
        return total
    }
    /// MAC-NEXT-8: board rows an older build kept waiting (or set aside) for a project are another Mac's live status:
    /// never placed. Only the side tables' bookkeeping goes; the memory itself is untouched.
    func cloudForgetLocalOnlyWaiting() throws {
        let keys = DeckMemoryCloudSchema.tables.filter(DeckMemoryCloudSchema.isLocalOnly).map { "resource_key LIKE 'row/\($0.name)/%'" }.joined(separator: " OR ")
        guard !keys.isEmpty else { return }
        try db.run("DELETE FROM \(try cloudWaitingTable()) WHERE " + keys)
        if try cloudParkedCount() > 0 { try db.run("DELETE FROM \(try cloudParkedTable()) WHERE " + keys) }
    }
    /// MAC-NEXT-7 (3): the same gap as the sync core's check of packs it refused (`CloudSyncEngine.localRecheckGap`).
    static let cloudParkedRetryGap: TimeInterval = 10 * 60
    /// A project or agent record was applied: the next release tries every set-aside row again (what it waited for
    /// may be here now), with no restart and no 10-minute wait.
    public func cloudRetrySetAsideNow() { cloudParkedRetryAt = nil }
    /// When set-aside rows are next tried again by a release (nil: at the next release); nothing when none is set aside.
    public func cloudSetAsideRetryAt() throws -> Date? {
        guard try cloudParkedCount() > 0 else { return nil }
        return cloudParkedRetryAt
    }
    /// Parked rows go back to waiting: what failed may succeed now (a fix shipped, its file arrived).
    private func cloudUnparkAll() throws {
        guard try cloudParkedCount() > 0 else { return }
        let table = try cloudWaitingTable(), parked = try cloudParkedTable()
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO \(table)(store_id,resource_key,revision,project_id) SELECT store_id,resource_key,revision,project_id FROM \(parked)")
            try db.run("DELETE FROM \(parked)")
        }
    }
    private struct CloudReleasePass { var queued = 0, placed = 0, parked = 0, placedForArchived = 0; var parkedReasons: [String: Int] = [:]; var archivedProjects: Set<String> = [] }
    /// One walk over every waiting row whose project this Mac knows now, in batches of `cloudReleaseBatch`, each its
    /// own transaction (live memory writes are not held behind a release of 40,000 rows), each row its own savepoint.
    private func cloudReleaseOnce(announce: (@Sendable (String) async -> Void)? = nil) async throws -> CloudReleasePass {
        let table = try cloudWaitingTable(), parkedTable = try cloudParkedTable()
        var pass = CloudReleasePass()
        // H/G (13 Nov): only the projects this Mac knows are released; rows of a project still unknown are not read.
        var ready: [(String, String)] = [], archived: Set<String> = []
        for g in try db.rows("SELECT DISTINCT project_id,store_id FROM \(table)") {
            guard let target = try cloudProjectPlacement(g.text(0), origin: g.text(1)) else { continue }
            ready.append((g.text(0), g.text(1)))
            if target.archived { archived.insert(g.text(0)) }
        }
        guard !ready.isEmpty else { return pass }
        cloudReleaseWalks += 1
        var queue: [(String, String, String, String)] = []
        for (project, origin) in ready {
            // Review M2: a project's FILES first, then its rows, so an index entry finds its file placed.
            for w in try db.rows("SELECT store_id,resource_key,revision FROM \(table) WHERE project_id=? AND store_id=? ORDER BY (resource_key>='file/' AND resource_key<'file0') DESC, rowid", [.text(project),.text(origin)]) {
                queue.append((w.text(0), w.text(1), w.text(2), project))
            }
        }
        pass.queued = queue.count
        if queue.count >= Self.cloudReleaseAnnounceRows, let announce {
            let projects = Set(queue.map(\.3)).count
            await announce("cloud memory: placing \(queue.count) rows for \(projects) project\(projects == 1 ? "" : "s")")
        }
        var visited = 0, streak = 0
        defer { cloudRevisits += visited }
        var start = 0
        while start < queue.count {
            // Between batches the store is free for live memory writes (and anything else waiting on it).
            if start > 0 { await restBetweenBatches() }
            let batch = queue[start..<min(start + Self.cloudReleaseBatch, queue.count)]
            start += batch.count
            var placedHere = 0, placedArchivedHere = 0, archivedHere: Set<String> = [], parkedHere: [String: Int] = [:]
            try db.transaction {
                try db.run("UPDATE cloud_memory_control SET value='1' WHERE key='importing'")
                defer { try? db.run("UPDATE cloud_memory_control SET value='0' WHERE key='importing'") }
                for (storeId, key, revision, project) in batch {
                    visited += 1
                    let args: [DeckMemorySQL] = [.text(storeId),.text(key),.text(revision)]
                    // Another release may have placed it while this one yielded.
                    guard try db.first("SELECT 1 FROM \(table) WHERE store_id=? AND resource_key=? AND revision=?", args) != nil else { continue }
                    try db.exec("SAVEPOINT cloud_release_row")
                    do {
                        guard let p = try cloudStoredPart(storeId: storeId, key: key, version: revision) else {
                            // Its kept version is gone: nothing can ever place it, so it must not stay "waiting".
                            throw CloudReleaseRowProblem.versionMissing
                        }
                        try db.run("DELETE FROM \(table) WHERE store_id=? AND resource_key=? AND revision=?", args)
                        let raw = try cloudIncomingFolder().appendingPathComponent(p.storeId + "/" + p.resourceHash)
                        if p.key.hasPrefix("file/") {
                            _ = try cloudProjectFile(p, from: raw)
                            // Review M2: index entries kept for this file (arrived first) are restored now, as on import.
                            try cloudReconcileLabels(storeId: p.storeId, path: String(p.key.dropFirst(5)))
                        } else { _ = try cloudProjectRow(p, from: raw) }
                        try db.exec("RELEASE SAVEPOINT cloud_release_row")
                        if !(try cloudIsWaiting(p)) {
                            placedHere += 1
                            if archived.contains(project) { placedArchivedHere += 1; archivedHere.insert(project) }
                        }
                        streak = 0
                    } catch {
                        // Only this row is undone; the batch and the rows after it go on.
                        try db.exec("ROLLBACK TO SAVEPOINT cloud_release_row")
                        try db.exec("RELEASE SAVEPOINT cloud_release_row")
                        if error is DeckMemoryError {
                            streak += 1
                            if streak >= Self.cloudReleaseFailureStreak { throw error }
                        }
                        let reason = Self.cloudReleaseReason(error)
                        try db.run("DELETE FROM \(table) WHERE store_id=? AND resource_key=? AND revision=?", args)
                        try db.run("INSERT OR REPLACE INTO \(parkedTable)(store_id,resource_key,revision,project_id,reason,at) VALUES (?,?,?,?,?,?)",
                                   args + [.text(project), .text(reason), .int(Int64(now().timeIntervalSince1970 * 1000))])
                        parkedHere[reason, default: 0] += 1
                    }
                }
            }
            // Counted only once the batch is committed.
            pass.placed += placedHere
            pass.placedForArchived += placedArchivedHere; pass.archivedProjects.formUnion(archivedHere)
            for (reason, n) in parkedHere { pass.parked += n; pass.parkedReasons[reason, default: 0] += n }
        }
        return pass
    }
    enum CloudReleaseRowProblem: Error { case versionMissing }
    /// The kind of failure only: never a path, an id or content.
    static func cloudReleaseReason(_ error: any Error) -> String {
        if let failure = error as? CloudFailure {
            switch failure {
            case .idReused: return "the same id is used by another item here"
            case .checksumMismatch: return "its saved copy does not match"
            case .invalidRequest: return "it is not in a form this Mac reads"
            case .unsupportedFormat: return "it is in a form this Mac does not support"
            case .versionChanged: return "the file changed on this Mac while it was placed"
            default: return "the memory store refused it"
            }
        }
        if error is CloudReleaseRowProblem { return "its saved copy is missing" }
        if error is DeckMemoryError { return "the memory database refused it" }
        if (error as NSError).domain == NSCocoaErrorDomain { return "its file could not be read or written" }
        return "it could not be placed"
    }
    /// A whole kept version rebuilt as a single logical part (bytes are read from the account's incoming copy).
    func cloudStoredPart(storeId: String, key: String, version: String) throws -> CloudBrainMemoryPart? {
        guard let v = try db.first("SELECT inventory,parents,content_hash FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?", [.text(storeId),.text(key),.text(version)]) else { return nil }
        let raw = try cloudIncomingFolder().appendingPathComponent(storeId + "/" + v.text(2))
        let size = (try FileManager.default.attributesOfItem(atPath: raw.path)[.size] as? NSNumber)?.int64Value ?? 0
        return CloudBrainMemoryPart(storeId: storeId, inventoryRow: v.text(0), key: key, version: version, resourceHash: v.text(2), bytes: String(size),
                                    index: 0, count: 1, parents: try JSONDecoder().decode([String].self, from: v.data(1) ?? Data("[]".utf8)), data: "")
    }

    // MARK: M4 — revisions and values decided later

    /// A version as the merge rule sees it: its stamp, baseline flag and known server sequence (from the stamp table,
    /// else from its first part's payload), its first part's opId, and its ancestry.
    func cloudRevision(storeId: String, key: String, version: String) throws -> DeckMemoryCloudMerge.Revision? {
        // The same first part on every Mac: lowest part index, then lowest opId (copied stores publish twins).
        guard let bytes = try db.first("SELECT operation FROM cloud_memory_parts WHERE resource_key=? AND revision=? AND part=0 ORDER BY op_id LIMIT 1",
                                       [.text(key),.text(version)])?.data(0) else { return nil }
        let operation = try JSONDecoder().decode(CloudOperation.self, from: bytes)
        let part = try? JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(operation.payload))
        // The order inputs are exactly what that first part carries, identical on every Mac that holds it.
        let stamp = part?.stamp.flatMap { Int64($0) } ?? operation.createdAt, baseline = part?.baseline ?? false
        var sequence: CloudSequence?, committedAt: Int64?
        let table = try cloudStampTable()
        if let saved = try db.first("SELECT sequence,committed_at FROM \(table) WHERE resource_key=? AND revision=?", [.text(key),.text(version)]) {
            sequence = saved.string(0).flatMap { try? CloudSequence(rawValue: $0) }
            committedAt = saved.isNull(1) ? nil : saved.int(1)
        }
        // During first projection the incoming version is not in versions yet. Its first part already carries
        // the same parents, so ancestry must start there rather than silently lose the first generation.
        var ancestors = Set(part?.parents ?? []), frontier = Array(ancestors) + [version], steps = 0
        while let next = frontier.popLast(), steps < 4096 {
            steps += 1
            guard let parents = try db.first("SELECT parents FROM cloud_memory_versions WHERE resource_key=? AND revision=? UNION ALL SELECT parents FROM cloud_memory_parts WHERE resource_key=? AND revision=? AND part=0 LIMIT 1", [.text(key), .text(next), .text(key), .text(next)])?.data(0),
                  let list = try? JSONDecoder().decode([String].self, from: parents) else { continue }
            for parent in list where ancestors.insert(parent).inserted { frontier.append(parent) }
        }
        return .init(storeId: storeId, version: version, stamp: stamp, baseline: baseline, sequence: sequence, committedAt: committedAt, opId: operation.opId, ancestors: ancestors)
    }

    // MARK: M4b — stamps, written once

    /// Sets the stamp clock: the sync owner's service time in milliseconds, nil while its offset is not known.
    /// While it answers nil a new version is stamped from this Mac's clock (Decker); memory rows are kept off meanwhile
    /// by the wiring, which checks `cloudClockReady()`.
    public func cloudSetClock(_ now: @escaping @Sendable () -> Int64?) {
        DeckMemoryCloudClocks.shared.set(now, for: self)
    }
    /// True only when an injected service clock knows its offset now. A memory row is enabled only when this is true.
    public func cloudClockReady() -> Bool {
        DeckMemoryCloudClocks.shared.injected(self) && DeckMemoryCloudClocks.shared.now(for: self) != nil
    }
    func cloudStampTable() throws -> String {
        let table = try cloudSideTable("cloud_memory_stamps", "resource_key TEXT NOT NULL,revision TEXT NOT NULL,stamp INTEGER NOT NULL,baseline INTEGER NOT NULL,sequence TEXT,own INTEGER NOT NULL,committed_at INTEGER,PRIMARY KEY(resource_key,revision)")
        if try !db.rows("PRAGMA cloud.table_info(cloud_memory_stamps)").contains(where: { $0.text(1) == "committed_at" }) {
            try db.exec("ALTER TABLE cloud.cloud_memory_stamps ADD COLUMN committed_at INTEGER")
        }
        return table
    }
    /// Records a version's stamp. The first stored stamp is final: the same version reaching this Mac again (a copied
    /// store's twin) changes nothing that orders it; only display facts (sequence, commit time) are filled in.
    func cloudRecordStamp(key: String, version: String, stamp: Int64, baseline: Bool, sequence: CloudSequence?, own: Bool, committedAt: Int64? = nil) throws {
        let table = try cloudStampTable()
        try db.run("""
            INSERT INTO \(table)(resource_key,revision,stamp,baseline,sequence,own,committed_at) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(resource_key,revision) DO UPDATE SET sequence=COALESCE(sequence,excluded.sequence),own=MAX(own,excluded.own),
            committed_at=COALESCE(committed_at,excluded.committed_at)
            """, [.text(key),.text(version),.int(stamp),.int(baseline ? 1 : 0),.optional(sequence?.rawValue),.int(own ? 1 : 0),.optional(committedAt.map { Int($0) })])
    }
    /// Commit times of this Mac's own versions, from the outbox's read-back receipts (`cloudReceipt(operationId:)`).
    /// Recorded for display only: no stamp, order or version bytes change. Unknown operation ids are ignored.
    public func cloudRecordCommitTimes(_ receipts: [CloudOperationReceipt]) throws {
        guard try cloudAttached() else { return }
        let table = try cloudStampTable()
        for receipt in receipts {
            guard let committed = receipt.committedAt,
                  let part = try db.first("SELECT resource_key,revision FROM cloud_memory_parts WHERE op_id=?", [.text(receipt.operationId)]),
                  let saved = try db.first("SELECT stamp,baseline,own FROM \(table) WHERE resource_key=? AND revision=?", [.text(part.text(0)),.text(part.text(1))]) else { continue }
            try cloudRecordStamp(key: part.text(0), version: part.text(1), stamp: saved.int(0), baseline: saved.int(1) != 0, sequence: receipt.sequence,
                                 own: saved.int(2) != 0, committedAt: committed)
        }
    }
    /// The stamp of a version this Mac is about to publish for the first time: computed ONCE and then final (Decker,
    /// round 5): the moment this Mac CAPTURED the change, on the service clock when its offset is known (this Mac's clock
    /// until then), never earlier than its parents' stamps + 1 ms. Never a row's own `updated` or a file's modification
    /// time: a restore, a copy or `touch` can set those to anything.
    /// - A journaled change: its journal row's `captured_at`.
    /// - A snapshot-cut resource (no journal row): the cut time (`createdAt`, which the cut sets).
    /// Baseline per rule J.
    func cloudStampForExport(_ p: CloudBrainMemoryPart, createdAt: Int64) throws -> (stamp: Int64, baseline: Bool) {
        let table = try cloudStampTable()
        if let saved = try db.first("SELECT stamp,baseline FROM \(table) WHERE resource_key=? AND revision=?", [.text(p.key),.text(p.version)]) {
            return (saved.int(0), saved.int(1) != 0)
        }
        let captured = try db.first("SELECT j.captured_at FROM cloud_memory_seq_versions m JOIN cloud_memory_journal j ON j.seq=m.seq WHERE m.version=? AND j.captured_at IS NOT NULL ORDER BY m.seq LIMIT 1",
                                    [.text(p.version)])?.int(0)
        // offset = service now - this Mac's now while the service clock is known; 0 until then.
        let local = Int64(Date().timeIntervalSince1970 * 1000)
        let offset = DeckMemoryCloudClocks.shared.now(for: self).map { $0 - local } ?? 0
        var stamp = (captured ?? createdAt) + offset
        for parent in p.parents {
            if let r = try db.first("SELECT stamp FROM \(table) WHERE resource_key=? AND revision=?", [.text(p.key),.text(parent)]) { stamp = max(stamp, r.int(0) + 1) }
            else if let earlier = try cloudRevision(storeId: p.storeId, key: p.key, version: parent) { stamp = max(stamp, earlier.stamp + 1) }
        }
        // Review round 2: a version is never dated later than the service clock's now (a Mac whose clock ran fast while
        // it was offline cannot win by its clock); the parents' floor above still applies.
        if let serviceNow = DeckMemoryCloudClocks.shared.now(for: self), DeckMemoryCloudClocks.shared.injected(self) {
            var floor = Int64.min
            for parent in p.parents {
                if let r = try db.first("SELECT stamp FROM \(table) WHERE resource_key=? AND revision=?", [.text(p.key),.text(parent)]) { floor = max(floor, r.int(0) + 1) }
            }
            stamp = max(min(stamp, serviceNow), floor)
        }
        // Rule J: baseline only when this Mac already holds another Mac's Cloud version of this record. A record the Cloud
        // does not have yet is an ordinary first revision; a version with parents descends from what it saw.
        var baseline = false
        if p.parents.isEmpty {
            let importedStamp = try db.first("SELECT 1 FROM \(table) WHERE resource_key=? AND revision<>? AND own=0 LIMIT 1", [.text(p.key),.text(p.version)]) != nil
            let otherStore = try db.first("SELECT 1 FROM cloud_memory_versions WHERE resource_key=? AND revision<>? AND store_id<>? LIMIT 1", [.text(p.key),.text(p.version),.text(p.storeId)]) != nil
            baseline = importedStamp || otherStore
        }
        try cloudRecordStamp(key: p.key, version: p.version, stamp: stamp, baseline: baseline, sequence: nil, own: true)
        return (stamp, baseline)
    }

    func cloudPendingMergeTable() throws -> String {
        try cloudSideTable("cloud_memory_pending_merge", "store_id TEXT NOT NULL,resource_key TEXT NOT NULL,revision TEXT NOT NULL,PRIMARY KEY(store_id,resource_key,revision)")
    }
    /// This Mac's competing value has no revision yet; the same rule decides as soon as it has one, on both Macs.
    func cloudMarkPendingMerge(_ p: CloudBrainMemoryPart) throws {
        let table = try cloudPendingMergeTable()
        try db.run("INSERT OR IGNORE INTO \(table)(store_id,resource_key,revision) VALUES (?,?,?)", [.text(p.storeId),.text(p.key),.text(p.version)])
    }
    /// Re-decides values kept while this Mac's own edit had not travelled yet. Bounded per call; runs inside an import.
    func cloudSettlePendingMerges(limit: Int = 256) throws {
        guard try cloudAttached() else { return }
        let table = try cloudPendingMergeTable()
        for w in try db.rows("SELECT store_id,resource_key,revision FROM \(table) ORDER BY rowid LIMIT ?", [.int(Int64(limit))]) {
            try db.run("DELETE FROM \(table) WHERE store_id=? AND resource_key=? AND revision=?", [.text(w.text(0)),.text(w.text(1)),.text(w.text(2))])
            guard let p = try cloudStoredPart(storeId: w.text(0), key: w.text(1), version: w.text(2)) else { continue }
            // Re-running the projection either applies the winner, keeps the loser as history, or marks it pending again.
            let raw = try cloudIncomingFolder().appendingPathComponent(p.storeId + "/" + p.resourceHash)
            // The one rule: a file (or a removal) kept while this Mac's own edit was not a revision yet.
            if p.key.hasPrefix("file/") {
                // A newer version of the same resource arrived since: that one was decided on its own.
                if let head = try db.first("SELECT version FROM cloud_memory_export_heads WHERE resource_key=?", [.text(p.storeId + ":" + p.key)])?.string(0),
                   head != p.version, let headRev = try cloudRevision(storeId: p.storeId, key: p.key, version: head), headRev.ancestors.contains(p.version) { continue }
                _ = try cloudProjectFile(p, from: raw)
            } else { _ = try cloudProjectRow(p, from: raw) }
        }
    }

    // MARK: M6 — every shipped default counts as a seed

    /// Hashes of every text this app ever wrote on its own at `relative` (current and earlier versions).
    func cloudShippedSeedHashes(_ relative: String) throws -> Set<String> {
        var texts: [String] = []
        for category in DeckMemoryCategory.allCases where relative.hasPrefix(category.templateFolder + "/") {
            let fresh = Self.defaultTemplate(category), name = String(relative.dropFirst(category.templateFolder.count + 1))
            switch name {
            case "card.md": texts = [fresh.card] + Self.earlierShippedCards(category)
            // The flow engine replaces an empty or store-default checklist with its own default text.
            case "checklist.md": texts = [fresh.checklist, DeckMemoryFlowChecklist.defaultText]
            case "settings.md": texts = [Self.templateSettingsText(fresh), Self.cloudSettingsTextBefore28Oct(fresh)]
            default: break
            }
        }
        if texts.isEmpty, let found = DeckMemoryFiles.classify(relative) {
            let owner = found.owner
            switch found.kind {
            case .card where relative == owner.cardPath:
                texts = [Self.starterCard(owner, name: "")]
                if let title = try setting(DeckMemoryKeys.seatTitle, owner: owner) { texts.append(Self.starterCard(owner, name: title)) }
            case .playbook where relative == owner.playbookPath:
                texts = [DeckMemoryFiles.playbookText(preface: "", rows: [.init(jobKind: "default")], trailer: "")]
            default: break
            }
        }
        return Set(texts.flatMap { [DeckMemoryFiles.hash($0), DeckMemoryFiles.hash(DeckMemoryRedaction.redacted($0))] })
    }
    /// settings.md as shipped until 28 Oct 2026: the parts list still named "refresh" and a "refresh at: 0.5" line.
    static func cloudSettingsTextBefore28Oct(_ template: DeckMemoryTemplate) -> String {
        var parts = DeckMemoryPart.allCases.filter(template.parts.contains).map(\.rawValue)
        if let helper = parts.firstIndex(of: "helper") { parts.insert("refresh", at: helper) } else { parts.append("refresh") }
        let current = templateSettingsText(template)
        let currentParts = "- parts: " + DeckMemoryPart.allCases.filter(template.parts.contains).map(\.rawValue).joined(separator: ", ") + "\n"
        return current.replacingOccurrences(of: currentParts, with: "- parts: " + parts.joined(separator: ", ") + "\n- refresh at: 0.5\n")
    }
}

extension DeckMemoryStore {
    // MARK: D1 — a removal stays the record's current version

    /// Records a shared setting's removal as the record's current version (its origins row), so any version that
    /// arrives later for the same key is decided against the removal with `winner` instead of being re-inserted.
    func cloudRecordRemovalVersion(_ p: CloudBrainMemoryPart, table t: DeckMemoryCloudSchema.Table, values: [DeckMemorySQL], logical: [DeckMemorySQL]? = nil) throws {
        let native = try DeckMemoryCloudSchema.nativeKey(t, values)
        try db.run("UPDATE cloud_memory_origins SET version=? WHERE table_name=? AND native_key=?", [.text(p.version),.text(t.name),.text(native)])
        guard db.changes == 0 else { return }
        let source = logical ?? values
        let keys = t.keys.map { DeckMemoryCloudSchema.cell(source[t.columns.firstIndex(of: $0)!]) }
        try db.run("INSERT INTO cloud_memory_origins(table_name,native_key,store_id,resource_key,original_keys,version) VALUES (?,?,?,?,?,?)",
                   [.text(t.name),.text(native),.text(p.storeId),.text(p.key),.blob(try CloudWire.canonical(keys)),.text(p.version)])
    }
    /// The version this Mac last recorded for a natural-key record that has no local row now (removed), if any.
    func cloudRecordedVersion(table t: DeckMemoryCloudSchema.Table, values: [DeckMemorySQL]) throws -> String? {
        try db.first("SELECT version FROM cloud_memory_origins WHERE table_name=? AND native_key=?", [.text(t.name),.text(try DeckMemoryCloudSchema.nativeKey(t, values))])?.string(0)
    }

    // MARK: R5 — an imported version is this Mac's export head

    /// After an import makes the local record equal to an incoming version, that version is the export head for it,
    /// so the next reconcile does not journal every imported record once (review round 3, R5).
    func cloudWriteImportHead(_ p: CloudBrainMemoryPart) throws {
        try db.run("""
            INSERT INTO cloud_memory_export_heads(resource_key,hash,version,parents,base_version,inventory,bytes) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(resource_key) DO UPDATE SET hash=excluded.hash,version=excluded.version,parents=excluded.parents,base_version=excluded.base_version
            """, [.text(p.storeId + ":" + p.key),.text(p.resourceHash),.text(p.version),.blob(try CloudWire.canonical(p.parents)),.text(p.version),
                  .text(p.inventoryRow),.int(Int64(p.bytes) ?? 0)])
    }
}

extension DeckMemoryStore {
    struct MemoryCloudHead {
        let store: String
        let key: String
        let version: String
        let hash: String
    }
    /// Hash observations outlive local byte-cache pruning. J-7 must still recognise a restored old version after
    /// its 30-day kept copy expires; this is metadata only, not another content store or Bin.
    func cloudMemoryKnownHashesTable() throws -> String {
        try cloudSideTable("cloud_memory_known_hashes", "path TEXT NOT NULL,hash TEXT NOT NULL,PRIMARY KEY(path,hash)")
    }
    func cloudMemoryRememberHash(_ hash: String, path: String) throws {
        guard BackendCloudVersionKeeper.isSha(hash) else { return }
        try db.run("INSERT OR IGNORE INTO \(try cloudMemoryKnownHashesTable())(path,hash) VALUES (?,?)", [.text(path), .text(hash)])
    }
    /// Includes unplaced arrivals: a local mark must not freeze the Cloud's newest text at the last local capture.
    func cloudNewestMemoryHead(_ path: String, excluding: String? = nil) throws -> MemoryCloudHead? {
        var keys = Set(["file/" + path])
        if let origin = try db.first("SELECT resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(path)])?.string(0) { keys.insert(origin) }
        var winner: (head: MemoryCloudHead, revision: DeckMemoryCloudMerge.Revision)?
        for key in keys {
            let rows = try db.rows("""
                SELECT store_id,revision,content_hash FROM cloud_memory_versions WHERE resource_key=?
                UNION SELECT store_id,revision,content_hash FROM cloud_memory_parts WHERE resource_key=?
                GROUP BY store_id,revision,content_hash HAVING COUNT(DISTINCT part)=MAX(total)
                """, [.text(key), .text(key)])
            for row in rows {
                if row.text(1) == excluding { continue }
                let head = MemoryCloudHead(store: row.text(0), key: key, version: row.text(1), hash: row.text(2))
                try cloudMemoryRememberHash(head.hash, path: path)
                guard let revision = try cloudRevision(storeId: head.store, key: key, version: head.version) else { continue }
                if let current = winner {
                    // An unrelated edit beats a removal, irrespective of date (the existing ancestry rule).
                    let removing = try cloudIsRemoval(hash: head.hash), wasRemoving = try cloudIsRemoval(hash: current.head.hash)
                    let related = revision.ancestors.contains(current.revision.version) || current.revision.ancestors.contains(revision.version)
                    if !related, removing != wasRemoving {
                        if !removing { winner = (head, revision) }
                    } else if DeckMemoryCloudMerge.winner(revision, current.revision).version == revision.version { winner = (head, revision) }
                } else { winner = (head, revision) }
            }
        }
        return winner?.head
    }
    func cloudMemoryHeadBytes(_ head: MemoryCloudHead, path: String) throws -> Data? {
        try cloudHeadBytes(path: path, store: head.store, key: head.key, version: head.version, hash: head.hash)
    }
    func cloudMemoryHeadPart(_ head: MemoryCloudHead, path: String) throws -> CloudBrainMemoryPart? {
        guard let row = try db.first("SELECT inventory,parents FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=? UNION ALL SELECT inventory,parents FROM cloud_memory_parts WHERE store_id=? AND resource_key=? AND revision=? AND part=0 LIMIT 1",
                                     [.text(head.store), .text(head.key), .text(head.version), .text(head.store), .text(head.key), .text(head.version)]),
              let bytes = try cloudMemoryHeadBytes(head, path: path) else { return nil }
        return .init(storeId: head.store, inventoryRow: row.text(0), key: head.key, version: head.version, resourceHash: head.hash,
                     bytes: String(bytes.count), index: 0, count: 1, parents: try JSONDecoder().decode([String].self, from: row.data(1) ?? Data("[]".utf8)), data: "")
    }
    func cloudAdoptMemoryHead(_ head: MemoryCloudHead, path: String) throws {
        try db.run("INSERT INTO cloud_memory_file_origins(path,store_id,resource_key,version) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET store_id=excluded.store_id,resource_key=excluded.resource_key,version=excluded.version",
                   [.text(path), .text(head.store), .text(head.key), .text(head.version)])
        // Export needs the parent even when that Cloud revision was intentionally never placed on this Mac.
        if let part = try cloudMemoryHeadPart(head, path: path) { try cloudWriteImportHead(part) }
    }
    func cloudInstallMemoryHead(_ head: MemoryCloudHead, path: String, bytes: Data) throws {
        guard cloudMemoryRootAvailable(), DeckMemoryRemoval.parse(bytes) == nil,
              BackendCloudBrainMemoryHash.bytes(bytes) == head.hash else { throw CloudFailure.invalidRequest }
        let target = try DeckMemoryCloudSchema.safePath(path, root: root)
        if FileManager.default.fileExists(atPath: target.path) {
            let before = try cloudHashFile(target)
            if before != head.hash { try cloudKeepCurrent(path) }
            guard try cloudHashFile(target) == before else { throw CloudFailure.versionChanged }
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)
        try BackendCloudBrainMemoryHash.synchronize(target)
        // Index writes must not capture the file as this Mac's new edit before its origin is recorded.
        let importing = try db.first("SELECT value FROM cloud_memory_control WHERE key='importing'")?.text(0) ?? "0"
        try db.run("UPDATE cloud_memory_control SET value='1' WHERE key='importing'")
        defer { try? db.run("UPDATE cloud_memory_control SET value=? WHERE key='importing'", [.text(importing)]) }
        _ = try reindexNow(paths: [path])
        try cloudAdoptMemoryHead(head, path: path)
        let written = try cloudHashFile(target)
        try db.run("INSERT INTO cloud_memory_files(path,hash) VALUES (?,?) ON CONFLICT(path) DO UPDATE SET hash=excluded.hash,bytes=NULL,mtime=NULL", [.text(path), .text(written)])
        try cloudLeaveBin(path)
    }
    /// Decision J-7. true = consumed without capture; false = genuinely new bytes, capture above the newest head.
    func cloudMemoryReappeared(_ path: String, hash: String) throws -> Bool {
        let state = try CloudDeleteState(memory: db)
        guard let mark = try state.mark(at: path) else { return false }
        if mark.mark == .onlyOnThisMac { return true }
        guard let head = try cloudNewestMemoryHead(path), let newest = try cloudMemoryHeadBytes(head, path: path) else {
            // Without the Cloud's newest bytes we cannot mistake an older restored copy for a new edit.
            return true
        }
        if hash == head.hash {
            try cloudAdoptMemoryHead(head, path: path)
            try state.clearMark(at: path)
            try db.run("UPDATE cloud_memory_files SET hash=?,bytes=NULL,mtime=NULL WHERE path=?", [.text(hash), .text(path)])
            return true
        }
        let knownEarlier = try db.first("SELECT 1 FROM \(try cloudMemoryKnownHashesTable()) WHERE path=? AND hash=?", [.text(path), .text(hash)]) != nil || db.first("SELECT 1 FROM cloud_memory_versions WHERE resource_key=? AND (content_hash=? OR projected_hash=?) UNION ALL SELECT 1 FROM cloud_memory_parts WHERE resource_key=? AND content_hash=? LIMIT 1",
                                        [.text(head.key), .text(hash), .text(hash), .text(head.key), .text(hash)]) != nil
        if knownEarlier {
            if let removal = DeckMemoryRemoval.parse(newest) {
                // Reappearing old bytes do not undo a Cloud removal either; reuse its normal ancestry/Bin path.
                guard let part = try cloudMemoryHeadPart(head, path: path) else { return true }
                try state.clearMark(at: path)
                _ = try cloudApplyRemoval(part, removal, path: path)
            } else {
                try cloudInstallMemoryHead(head, path: path, bytes: newest)
                try state.clearMark(at: path)
            }
            return true
        }
        // His own new text descends from what the Cloud has now, never from the stale last-seen version.
        if DeckMemoryRemoval.parse(newest) == nil {
            try cloudKeepText(path: path, content: newest, ref: .init(storeId: head.store, key: head.key, version: head.version), at: nil, device: nil)
        }
        try cloudAdoptMemoryHead(head, path: path)
        try state.clearMark(at: path)
        try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(path)])
        return false
    }
    /// Called at the start of cloudProjectFile, before its identical/default/predecessor fast paths (integration hook).
    /// A mark blocks every automatic placement. Only a descendant edit of Cloud-only removal clears that mark.
    func cloudDeleteRuleArrival(_ p: CloudBrainMemoryPart, path: String, assembled: URL) throws -> CloudApplyStatus? {
        guard cloudMemoryRootAvailable() else {
            try cloudMarkPendingMerge(p)
            return try cloudKeepVersionForOneRule(p)
        }
        try cloudMemoryRememberHash(p.resourceHash, path: path)
        let state = try CloudDeleteState(memory: db)
        guard let mark = try state.mark(at: path) else { return nil }
        if mark.mark == .onlyOnThisMac {
            let data = try Data(contentsOf: assembled)
            if DeckMemoryRemoval.parse(data) == nil,
               let head = try cloudNewestMemoryHead(path, excluding: p.version), try cloudIsRemoval(hash: head.hash),
               let incoming = try cloudRevision(storeId: p.storeId, key: p.key, version: p.version),
               p.parents.contains(head.version) || incoming.ancestors.contains(head.version) {
                // Every Mac's differing local-only text is kept before the returning Cloud version replaces it.
                let target = try DeckMemoryCloudSchema.safePath(path, root: root)
                if FileManager.default.fileExists(atPath: target.path) { try cloudKeepCurrent(path) }
                try state.clearMark(at: path)
                let fresh = MemoryCloudHead(store: p.storeId, key: p.key, version: p.version, hash: p.resourceHash)
                _ = try cloudKeepVersionForOneRule(p)
                try cloudInstallMemoryHead(fresh, path: path, bytes: data)
                return .applied
            }
        }
        let arriving = try Data(contentsOf: assembled)
        // Lead's decision 10: "Not on this Mac", and the Cloud's newest version of the place is now another device's
        // Everywhere removal: nothing is left to bring back. The mark goes and the removal is applied as usual (the file
        // is not here, so it only records the removal), so the page never shows a dead "Bring back".
        if mark.mark == .notOnThisMac, DeckMemoryRemoval.parse(arriving) != nil,
           try cloudNewestMemoryHead(path)?.version == p.version, try cloudMemoryRemovedEverywhere(path) {
            try state.clearMark(at: path)
            return nil
        }
        // No origin change: the local text stays fixed, while all Cloud versions remain available for explicit Bring back.
        if let marker = DeckMemoryRemoval.parse(arriving) {
            try cloudNoteRemoval(hash: p.resourceHash, path: path, at: marker.at, movedTo: marker.movedTo)
        }
        return try cloudKeepVersionForOneRule(p)
    }
}
