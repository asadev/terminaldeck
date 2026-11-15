import Foundation
import TerminalDeckNativeCore

/// The one rule for memory files (owner, 14 Nov: "the newest version is used everywhere; the replaced version is kept
/// for 30 days; it is said in one line; there is a Clean up button"). Lane memory-one-rule, notes in
/// `team/memory/notes/2026-11-14-memory-one-rule.md`.
///
/// - NEWER is decided ONLY by the Cloud's revision order (`DeckMemoryCloudMerge.winner`: a descendant wins, rule J,
///   then the version's own stamp, then opId), never by a file date. An edit this Mac has not made into a revision yet
///   stays in use and is decided by the same rule once it is one (pending, like M4 for rows).
/// - A REMOVAL travels as an ordinary memory part (the existing `.put` shape and keys): the resource gets a new version
///   whose bytes are a removal marker (`DeckMemoryRemoval`). No new socket field, no new record field.
/// - Kept texts and the Bin live in the one keeper (`BackendCloudVersionKeeper`, kind "memory", outside the memory
///   folder): never read or searched by the AIs, never uploaded.
struct DeckMemoryRemoval: Sendable, Equatable {
    /// The front-matter key that marks a removal. A note's labels never use it.
    static let marker = "td_removed"
    /// When it was removed (service clock, ms) and by which device (id; the page shows the name).
    let at: Int64
    let by: String
    /// Set when the item MOVED (archived, renamed, folded into another seat): its text lives on at this path.
    let movedTo: String?
    /// Phase 2 (review point 5): an AI removed it, not the owner. Never shown as his removal on any Mac.
    var byAI: Bool = false
    /// The six new fields stay inside the existing marker; absent fields mean an older Everywhere removal.
    var travel: [String: String] = [:]

    /// A complete memory file. It carries its own note id, so an older build that places it (as the text of the
    /// note) indexes it as it is and never rewrites it, and so never sends it back as an edit.
    func text(id: String, name: String) -> String {
        var file = DeckMemoryFile(body: "# Removed: " + name + "\n\n"
            + (movedTo == nil ? "This was removed from your devices on " : "This moved to another place in memory on ")
            + DeckMemoryFiles.day(Date(timeIntervalSince1970: Double(at) / 1000))
            + ". Terminal Deck keeps the earlier text for 30 days; update Terminal Deck on this Mac to see it in the Bin.\n")
        file.set("id", id)
        file.set("type", "removed")
        file.set("status", "removed")
        file.set(Self.marker, String(at))
        file.set("td_removed_by", by)
        file.set("td_moved_to", movedTo)
        file.set("td_removed_by_ai", byAI ? "1" : nil)
        for (key, value) in travel { file.set(key, value) }
        return file.text
    }
    static func parse(_ data: Data) -> DeckMemoryRemoval? {
        guard data.count < 16_384, data.starts(with: Data("---".utf8)), let text = String(data: data, encoding: .utf8) else { return nil }
        let file = DeckMemoryFile(text: text)
        guard let at = file.value(marker).flatMap(Int64.init) else { return nil }
        return .init(at: at, by: file.value("td_removed_by") ?? "", movedTo: file.value("td_moved_to"), byAI: file.value("td_removed_by_ai") == "1",
                     travel: Dictionary(uniqueKeysWithValues: CloudDeleteTravel.fields.compactMap { key in file.value(key).map { (key, $0) } }))
    }
}

/// A Cloud revision of a memory resource, for "is A newer than B". Never shown, never in a tool result.
public struct DeckMemoryVersionRef: Sendable, Hashable {
    public let storeId: String
    public let key: String
    public let version: String
    public init(storeId: String, key: String, version: String) { self.storeId = storeId; self.key = key; self.version = version }
}

/// One item in the memory Bin, as the file manager shows it (names and dates; `path` is the handle it passes back).
public struct DeckMemoryBinItem: Sendable, Equatable {
    public let path: String
    public let name: String
    /// The project id (the page turns it into the project's name); nil for Hoot's and the team's own memory.
    public let place: String?
    public let removedAt: Int64
    /// Device id of the Mac that removed it (the page shows the name).
    public let device: String
    public let bytes: Int64
    public let keptUntil: Int64
    /// Phase 2: an AI removed it (on `device`); the page never shows it as the owner's own removal.
    public var byAI: Bool = false
}

/// What the one-time settling did (round 3). Numbers and the safety copy's own folder only.
public struct DeckMemoryOneRuleReport: Sendable, Equatable {
    public let safetyCopy: String?
    public let safetyCopyBytes: Int64?
    public let copiesSettled: Int
    public let markersSettled: Int
    public let leftAsTheyAre: Int
    public let finished: Bool
    /// The phase switch: false = nothing about removals, moves or cleanups was sent.
    public let sending: Bool
    public let problem: String?
    /// Phase 2: the archived-notes settling (the only settling that sends anything), with its own safety copy.
    public var phase2SafetyCopy: String? = nil
    public var phase2SafetyCopyBytes: Int64? = nil
    public var archivedLookedAt = 0
    /// Old places of archived notes taken out of use on the other Macs (a move: the text stays at its archived place).
    public var movesSent = 0
    /// Old places sent NOTHING for: another Mac changed them after the archive (or their last text is not here to compare).
    public var archivedLeft = 0
    /// Replaced notes kept as earlier versions of the note that replaced them (this Mac only).
    public var archivedKept = 0
    public var phase2Finished = false
    static func megabytes(_ bytes: Int64?) -> String { bytes.map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "size unknown" }
    /// The one log line of the phase-1 settling. It never sends anything, in phase 1 or after.
    public var line: String {
        "memory one rule: safety copy " + (safetyCopy.map { $0 + " (" + Self.megabytes(safetyCopyBytes) + ")" } ?? "not made")
            + "; copies settled \(copiesSettled); markers settled \(markersSettled); left as they are \(leftAsTheyAre)"
            + (finished ? "; settling done" : "; settling not finished")
            + (problem.map { "; " + $0 } ?? "")
            + ". Nothing was removed or moved on your other devices."
    }
    /// The one log line of the phase-2 settling, once it is done: honestly what was sent. nil before it ran.
    public var phase2Line: String? {
        guard phase2Finished || movesSent > 0 else { return nil }
        return "memory one rule, phase 2: safety copy " + (phase2SafetyCopy.map { $0 + " (" + Self.megabytes(phase2SafetyCopyBytes) + ")" } ?? "not made")
            + "; archived notes looked at \(archivedLookedAt); earlier texts kept as versions on this Mac \(archivedKept)"
            + (phase2Finished ? "; settling done" : "; settling not finished")
            + ". Sent to your other devices: \(movesSent) old " + (movesSent == 1 ? "place" : "places")
            + " of archived notes removed from your devices (the text stays in the archived note; each sits in the Bin for 30 days)."
            + " Sent nothing for \(archivedLeft) old " + (archivedLeft == 1 ? "place" : "places") + " changed on another device after the archive."
    }
}

/// Compatibility DTO for the pages lane's old readers. This store no longer produces questions or held removals;
/// the pages lane removes these fields when adopting CloudDeleteOwning.
public struct DeckMemoryAnswer: Sendable, Equatable {
    public let missing: Int
    public let held: Int
    public let heldFrom: String?
    public init(missing: Int, held: Int, heldFrom: String?) { self.missing = missing; self.held = held; self.heldFrom = heldFrom }
}

/// What Put back did. `replacedAnother`: a DIFFERENT text was at that place; it is kept as a version, not lost.
public struct DeckMemoryPutBackResult: Sendable, Equatable {
    public let path: String
    public let name: String
    public let replacedAnother: Bool
}

/// One kept (older) text of a memory item. `id` is the handle "use this version" takes back.
public struct DeckMemoryKeptVersion: Sendable, Equatable {
    public let id: String
    public let at: Int64
    public let device: String
    public let bytes: Int64
    public let keptUntil: Int64
}

extension DeckMemoryStore {
    static let oneRuleKind = BackendCloudContents.Kind.memory.rawValue
    /// Shared memory settings (they travel in I05 like the others; an older build keeps unknown keys as history only,
    /// `isMachineLocal`). Their value is a time in ms: every Mac drops what was kept before it.
    static let cleanupVersionsKey = "cleanup.versions-before"
    static let cleanupBinKey = "cleanup.bin-before"

    // MARK: Keeper, clock, device

    func cloudKeeper() throws -> BackendCloudVersionKeeper {
        guard let state = cloudStateRoot else { throw CloudFailure.unavailable }
        let root = BackendCloudVersionKeeper.root(besideStateRoot: state)
        if let made = cloudKeeperMade, made.root.standardizedFileURL == root.standardizedFileURL { return made }
        let made = BackendCloudVersionKeeper(root: root)
        cloudKeeperMade = made
        return made
    }
    /// Service time when known (the stamp clock), else this Mac's clock.
    func cloudNowMs() -> Int64 { DeckMemoryCloudClocks.shared.now(for: self) ?? Int64(Date().timeIntervalSince1970 * 1000) }
    /// Set by the activation step: the device id written on removals and kept texts made here.
    public func cloudSetDevice(_ deviceId: String) { cloudDeviceId = deviceId.lowercased() }

    // MARK: Phase switch (review round 2, blocker 5; phase 2): no Mac ever receives a record it does not understand

    /// Every memory store of this build announces that it understands removal, move and cleanup records of THIS format:
    /// one shared memory setting per device (`onerule.understands.<device id>` = "v<format>:<service ms>"). That is the
    /// existing settings record shape; an older build keeps an unknown key as history only (`isMachineLocal`), proven by
    /// `machineLocalSettingsStayLocalAndNeverBlockReadiness_18`. The account's device list cannot tell (its `appVersion`
    /// is written at first sign-in only and never refreshed, service `user.ts:716-730`).
    ///
    /// Phase 2 (review: "the setting expires"): the value carries the format number and the time it was written, it is
    /// rewritten at every launch and every 12 hours while the app runs, and it counts only while it is at most 3 days
    /// old. A Mac rolled back to an older build stops renewing it, so sending switches itself OFF within 3 days; a Mac
    /// rolled back to the phase-1 build even rewrites it to "1" at once (phase 1 writes "1" whenever its own key is not
    /// "1"). Phase 1's plain "1" never counts.
    static let understandsPrefix = DeckMemoryCloudSchema.sharedSettingPrefix
    /// The format of this build's removal, move and cleanup records. A Mac counts only with a format at least this one.
    static let oneRuleFormat = 2
    static let understandsFreshFor: Int64 = 3 * 86_400_000
    static let understandsRenewAfter: Int64 = 12 * 3_600_000
    /// A time more than an hour ahead of the reader's service clock is a confused clock: it never counts.
    static let understandsAheadAllowed: Int64 = 3_600_000
    static func understandsValue(format: Int, at: Int64) -> String { "v\(format):\(at)" }
    static func parseUnderstands(_ raw: String?) -> (format: Int, at: Int64)? {
        guard let raw, raw.hasPrefix("v"), raw.utf8.count < 40, let colon = raw.firstIndex(of: ":"),
              let format = Int(raw[raw.index(after: raw.startIndex)..<colon]), let at = Int64(raw[raw.index(after: colon)...]),
              format > 0, at > 0 else { return nil }
        return (format, at)
    }
    /// Fresh = this format or newer, renewed within the last 3 days, not from the future.
    static func understandsFresh(_ raw: String?, now: Int64) -> Bool {
        guard let value = parseUnderstands(raw), value.format >= oneRuleFormat else { return false }
        return value.at <= now + understandsAheadAllowed && now - value.at <= understandsFreshFor
    }
    /// The account's Macs that keep memory, from the account's device list: active devices that hold a copy (never a
    /// phone or a browser: `isViewer`), without the stale earlier entries of a device that signed in again. nil while
    /// the list is not known (signed out, not read yet): then nothing is sent.
    public static func oneRuleAccountMacs(_ snapshot: CloudAccountSnapshot) -> [String]? {
        guard snapshot.phase == .signedIn || snapshot.phase == .paused, !snapshot.devices.isEmpty else { return nil }
        let stale = Set(snapshot.trust.filter(\.stale).map { $0.deviceId.lowercased() })
        return snapshot.devices.filter { $0.status == .active && !$0.isViewer && $0.supersededBy == nil && !stale.contains($0.deviceId.lowercased()) }
            .map { $0.deviceId.lowercased() }
    }
    /// Set by the account wiring each time it publishes the device list (`NativeCloudAccount`, one call); nil = not known.
    /// Phase 2 review, point 6: `generation` is the account's own count of published statuses; a list that arrives
    /// late (an older status) never overwrites a newer one. nil (tests) always sets.
    public func cloudOneRuleSetAccountMacs(_ deviceIds: [String]?, generation: UInt64? = nil) {
        if let generation {
            guard generation >= cloudAccountMacsGeneration else { return }
            cloudAccountMacsGeneration = generation
        }
        cloudAccountMacs = deviceIds.map { Set($0.map { $0.lowercased() }) }
    }
    /// Tests only: force sending on or off (nil = decide by the account).
    func cloudSetOneRuleSending(_ on: Bool?) { cloudOneRuleSendingForced = on }
    /// THE one switch, checked at every sending site (removals, moves, the settling's moves, cleanup times). Default OFF.
    /// On only while the account's list is known, holds this Mac, and EVERY Mac in it has a fresh "understands" of this
    /// format or newer. A new Mac on an old build, a stale setting, an unreadable list, a clock not known yet: off.
    /// Phase 2 review, blocker 4: also OFF until this Mac's phase-2 safety copy exists (`oneRule:safetyCopy2`, made by
    /// `cloudPrepareSendingCopy` as soon as every Mac understands); a copy that failed keeps sending off.
    func cloudOneRuleSends() -> Bool {
        if let forced = cloudOneRuleSendingForced { return forced }
        return cloudOneRuleEveryMacUnderstands() && cloudSafetyCopyReady()
    }
    /// The account's list is known, holds this Mac, and every Mac in it has a fresh "understands" of this format.
    func cloudOneRuleEveryMacUnderstands() -> Bool {
        guard cloudMemoryEnabled, let macs = cloudAccountMacs, !macs.isEmpty, let me = cloudDeviceId, macs.contains(me),
              let now = DeckMemoryCloudClocks.shared.now(for: self) else { return false }
        for id in macs where !Self.understandsFresh((try? setting(Self.understandsPrefix + id, owner: nil)) ?? nil, now: now) { return false }
        return true
    }
    static let sendingCopyKey = "oneRule:safetyCopy2"
    /// The phase-2 safety copy was made and its folder is still there.
    func cloudSafetyCopyReady() -> Bool {
        guard let made = (try? db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(Self.sendingCopyKey)]))?.string(0) else { return false }
        return FileManager.default.fileExists(atPath: made)
    }
    /// Phase 2 review, blocker 4: the safety copy is made as soon as every Mac understands (before anything is sent).
    /// A failed copy keeps sending off, says one plain line in the log, and is tried again an hour later.
    func cloudPrepareSendingCopy() throws {
        guard cloudOneRuleEveryMacUnderstands(), !cloudSafetyCopyReady() else { return }
        let now = cloudNowMs()
        if let tried = try db.first("SELECT value FROM cloud_memory_control WHERE key='oneRule:safetyCopy2TriedAt'")?.string(0).flatMap(Int64.init),
           now >= tried, now - tried < 3_600_000 { return }
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:safetyCopy2TriedAt',?)", [.text(String(now))])
        if !((try? cloudEnsureSafetyCopy(key: Self.sendingCopyKey)) ?? false) {
            CloudSyncDiagnostics.shared.info("memory one rule: the safety copy of memory could not be made, so removals and moves are not sent to your other devices yet. It tries again in an hour.")
        }
    }
    /// At every launch (the first step of this run) and every 12 hours: this Mac understands this format, as of now.
    /// Written as a shared memory setting (it travels in I05). Waits while the service clock is not known yet.
    func cloudAnnounceUnderstanding() throws {
        guard let id = cloudDeviceId, UUID(uuidString: id) != nil, let now = DeckMemoryCloudClocks.shared.now(for: self), now > 0 else { return }
        let key = Self.understandsPrefix + id
        if cloudAnnouncedThisRun, let held = Self.parseUnderstands(try setting(key, owner: nil)), held.format == Self.oneRuleFormat,
           held.at <= now, now - held.at < Self.understandsRenewAfter { return }
        try setSetting(Self.understandsValue(format: Self.oneRuleFormat, at: now), key: key, owner: nil)
        cloudAnnouncedThisRun = true
        post(.settings, nil, key)
    }
    /// Is the text at `movedTo` here the same text (same bytes, or the same words under different labels)? Only then may
    /// a move keep the old place's text out of sight; otherwise it goes to the VISIBLE Bin.
    func cloudIdenticalInUse(at movedTo: String?, bytes: Data) -> Bool {
        guard let movedTo, let url = try? DeckMemoryCloudSchema.safePath(movedTo, root: root), let there = try? Data(contentsOf: url) else { return false }
        if there == bytes { return true }
        guard let a = String(data: there, encoding: .utf8), let b = String(data: bytes, encoding: .utf8) else { return false }
        return DeckMemoryFile(text: a).body == DeckMemoryFile(text: b).body
    }
    static func oneRuleItemKey(_ path: String) -> String { "memory:" + path }
    func oneRuleName(_ path: String) -> String {
        if let title = try? db.first("SELECT title FROM notes WHERE path=? AND title IS NOT NULL AND title<>''", [.text(path)])?.string(0) { return title }
        if let title = try? db.first("SELECT title FROM handoffs WHERE path=? AND title IS NOT NULL AND title<>''", [.text(path)])?.string(0) { return title }
        let last = path.split(separator: "/").last.map(String.init) ?? path
        return last.lowercased().hasSuffix(".md") ? String(last.dropLast(3)) : last
    }
    static func oneRulePlace(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        return parts.count >= 3 && parts[0] == "projects" ? parts[1] : nil
    }

    // MARK: Revision order: the ONE "is A newer than B"

    /// True when `a` is newer than `b` by the Cloud's revision order (a descendant always wins; rule J; the version's
    /// own stamp; opId), the same answer on every Mac. nil when this Mac does not hold one of them. Never a file date.
    public func memoryIsNewer(_ a: DeckMemoryVersionRef, than b: DeckMemoryVersionRef) throws -> Bool? {
        guard cloudMemoryEnabled, let ra = try cloudRevision(storeId: a.storeId, key: a.key, version: a.version),
              let rb = try cloudRevision(storeId: b.storeId, key: b.key, version: b.version) else { return nil }
        if ra.version == rb.version { return false }
        return DeckMemoryCloudMerge.winner(ra, rb).version == ra.version
    }
    /// The revision the file at `path` is now. nil = an edit made here that is not a revision yet (it is the newest
    /// thing this Mac knows of; the rule decides once it is a revision) or a file the Cloud never had.
    public func memoryCurrentRef(path: String) throws -> DeckMemoryVersionRef? {
        guard cloudMemoryEnabled, let file = try? DeckMemoryCloudSchema.safePath(path, root: root), FileManager.default.fileExists(atPath: file.path) else { return nil }
        let current = try cloudHashFile(file)
        if case .known(let rev) = try cloudLocalSide(path: path, key: nil, current: current) {
            return .init(storeId: rev.storeId, key: try cloudKeyOfVersion(rev) ?? "file/" + path, version: rev.version)
        }
        return nil
    }
    private func cloudKeyOfVersion(_ rev: DeckMemoryCloudMerge.Revision) throws -> String? {
        try db.first("SELECT resource_key FROM cloud_memory_versions WHERE store_id=? AND revision=? LIMIT 1", [.text(rev.storeId), .text(rev.version)])?.string(0)
    }

    enum CloudLocalSide { case known(DeckMemoryCloudMerge.Revision), unrecorded }
    /// What the file at `path` holds, as a revision: the newest recorded version of `key` (or of the path's own
    /// origin) whose bytes are exactly the file's. `.unrecorded` = an edit made here that is not a revision yet.
    func cloudLocalSide(path: String, key: String?, current: String) throws -> CloudLocalSide {
        var keys: [String] = []
        if let key { keys.append(key) }
        if let origin = try db.first("SELECT resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(path)])?.string(0), !keys.contains(origin) { keys.append(origin) }
        if !keys.contains("file/" + path) { keys.append("file/" + path) }
        for k in keys {
            if let r = try db.first("SELECT store_id,revision FROM cloud_memory_versions WHERE resource_key=? AND (content_hash=? OR projected_hash=?) ORDER BY rowid DESC LIMIT 1",
                                    [.text(k), .text(current), .text(current)]),
               let rev = try cloudRevision(storeId: r.text(0), key: k, version: r.text(1)) { return .known(rev) }
        }
        return .unrecorded
    }
    /// The device that made a version (its first part's origin device), for the kept text's line. "" when unknown.
    func cloudVersionDevice(key: String, version: String) -> String {
        guard let bytes = try? db.first("SELECT operation FROM cloud_memory_parts WHERE resource_key=? AND revision=? AND part=0 ORDER BY op_id LIMIT 1", [.text(key), .text(version)])?.data(0),
              let op = try? JSONDecoder().decode(CloudOperation.self, from: bytes) else { return "" }
        return op.originDevice
    }

    // MARK: Keeping a text (never a second live file)

    /// Keeps `content` as an older version of the item at `path` for 30 days, with the revision it was when known.
    func cloudKeepText(path: String, content: Data, ref: DeckMemoryVersionRef?, at: Int64?, device: String?) throws {
        let keeper = try cloudKeeper(), item = Self.oneRuleItemKey(path), now = cloudNowMs()
        let rev = try ref.flatMap { try cloudRevision(storeId: $0.storeId, key: $0.key, version: $0.version) }
        try keeper.keep(kind: Self.oneRuleKind, itemKey: item, name: oneRuleName(path), place: Self.oneRulePlace(path), at: at ?? rev?.stamp ?? now,
                        device: device ?? ref.map { cloudVersionDevice(key: $0.key, version: $0.version) } ?? (cloudDeviceId ?? ""), content: content, now: now)
        if let ref { try keeper.setRevision(itemKey: item, sha256: BackendCloudBrainMemoryHash.bytes(content), storeId: ref.storeId, resourceKey: ref.key, revision: ref.version) }
    }
    /// The file at `path` as it is now, kept before it is replaced. Returns false when there was nothing to keep.
    @discardableResult
    func cloudKeepCurrent(_ path: String) throws -> Bool {
        let file = try DeckMemoryCloudSchema.safePath(path, root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        let bytes = try Data(contentsOf: file)
        var ref: DeckMemoryVersionRef?
        if case .known(let rev) = try cloudLocalSide(path: path, key: nil, current: BackendCloudBrainMemoryHash.bytes(bytes)) {
            ref = .init(storeId: rev.storeId, key: try cloudKeyOfVersion(rev) ?? "file/" + path, version: rev.version)
        }
        try cloudKeepText(path: path, content: bytes, ref: ref, at: nil, device: ref == nil ? cloudDeviceId : nil)
        return true
    }
    /// Bytes this Mac holds for a content hash (incoming/exported raw copies, or the capture's own copy).
    func cloudKnownBytes(hash: String, stores: [String]) -> Data? {
        guard hash.utf8.count == 64 else { return nil }
        var places: [URL] = []
        if let incoming = try? cloudIncomingFolder() { places += stores.map { incoming.appendingPathComponent($0 + "/" + hash) } }
        if let versions = try? cloudVersionsFolder() { places.append(versions.appendingPathComponent(hash)) }
        for url in places {
            if let data = try? Data(contentsOf: url), BackendCloudBrainMemoryHash.bytes(data) == hash { return data }
        }
        return nil
    }

    // MARK: Removals (the side table of removal markers this Mac made or received)

    func cloudRemovalsTable() throws -> String {
        try cloudSideTable("cloud_memory_removals", "hash TEXT PRIMARY KEY,path TEXT NOT NULL,at INTEGER NOT NULL,moved_to TEXT")
    }
    func cloudNoteRemoval(hash: String, path: String, at: Int64, movedTo: String?) throws {
        try db.run("INSERT OR IGNORE INTO \(try cloudRemovalsTable())(hash,path,at,moved_to) VALUES (?,?,?,?)", [.text(hash), .text(path), .int(at), .optional(movedTo)])
    }
    func cloudIsRemoval(hash: String) throws -> Bool {
        try db.first("SELECT 1 FROM \(try cloudRemovalsTable()) WHERE hash=?", [.text(hash)]) != nil
    }
    /// The head this Mac holds for a resource, when that head is a removal.
    func cloudRemovalHead(storeId: String, key: String) throws -> (version: String, hash: String)? {
        guard let head = try db.first("SELECT version,hash FROM cloud_memory_export_heads WHERE resource_key=?", [.text(storeId + ":" + key)]),
              try cloudIsRemoval(hash: head.text(1)) else { return nil }
        return (head.text(0), head.text(1))
    }

    /// A file captured here is gone from the folder: the removal travels as a new version of the same resource whose
    /// bytes are a removal marker. Its text goes into this Mac's Bin (or, for a move, is kept 30 days unlisted) from
    /// the last copy this Mac knows, unless Remove already put it there. Nothing is sent when the head is already a
    /// removal (the removal arrived from another device) or the row is not captured for this account.
    /// `onlyMove` (the archived-notes settling): sent only when it is a MOVE to a place holding the same text; a plain
    /// removal is never sent for it.
    ///
    /// Only an explicit intent or a proven move may travel. A missing file by itself is never a removal.
    @discardableResult
    func cloudJournalRemoval(path: String, lastHash: String?, onlyMove: Bool = false, knownBytes: Data? = nil) throws -> CloudRemovalSend {
        let state = try CloudDeleteState(memory: db)
        let intent = try state.intent(at: path)
        if intent?.scope == .cloud, !cloudDeleteRuleIsOpen() {
            throw DeckMemoryError(.invalid, CloudDeleteWords.cloudNeedsUpdatedMacs)
        }
        guard let inventory = try cloudFileInventoryRow(path, database: db) else { return .nothing }
        if let enabled = cloudEnabledRows, !enabled.contains(inventory) { return .nothing }
        let own = try cloudStoreId()
        let origin = try db.first("SELECT store_id,resource_key,version FROM cloud_memory_file_origins WHERE path=?", [.text(path)])
        let store = origin?.text(0) ?? own
        let key = origin.map { $0.text(1).hasPrefix("file/") ? $0.text(1) : "file/" + path } ?? "file/" + path
        if origin != nil, try cloudPlacementPath(String(key.dropFirst(5)), origin: store) != path { return .nothing }
        if let intent {
            if let raw = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("deleteRule:journaled:" + path)])?.string(0),
               (try? JSONDecoder().decode(CloudDeleteIntent.self, from: Data(raw.utf8))) == intent { return .nothing }
        } else {
            if try cloudRemovalHead(storeId: store, key: key) != nil { return .nothing }
            if let waiting = try db.first("SELECT hash FROM cloud_memory_journal WHERE resource_key=? ORDER BY seq DESC LIMIT 1", [.text(key)])?.string(0),
               try cloudIsRemoval(hash: waiting) { return .nothing }
        }
        let lastBytes = try knownBytes ?? cloudLastBytes(path: path, store: store, key: key, lastHash: lastHash)
        let movedTo = intent == nil ? try cloudMovedTo(path, lastBytes: lastBytes) : nil
        if onlyMove, movedTo == nil { return .nothing }
        guard intent != nil || movedTo != nil else { return .nothing }
        if movedTo != nil, !cloudOneRuleSends() { return .waitingForSwitch }
        // The existing safety-copy mechanism protects this Mac even while the compatibility gate is closed.
        guard try cloudEnsureSafetyCopy(key: Self.deleteRuleSafetyKey) else { throw CloudFailure.unavailable }
        let at = intent?.at ?? cloudNowMs(), by = intent?.mac ?? cloudDeviceId ?? ""
        let keeper = try cloudKeeper(), item = Self.oneRuleItemKey(path)
        let binned = try keeper.bin(itemKey: item)
        if binned == nil || lastBytes.map({ BackendCloudBrainMemoryHash.bytes($0) != binned?.sha256 }) == true {
            guard let bytes = lastBytes else { throw CloudFailure.unavailable }
            let saved = try keeper.binPut(kind: Self.oneRuleKind, itemKey: item, name: oneRuleName(path), place: Self.oneRulePlace(path), path: path,
                                          removedAt: at, device: Self.binDevice(by, byAI: intent?.by == .ai), content: bytes,
                                          shown: !cloudIdenticalInUse(at: movedTo, bytes: bytes), now: cloudNowMs())
            if let intent { try cloudRememberBin(saved, intent: intent, era: .current) }
        }
        var removal = DeckMemoryRemoval(at: at, by: by, movedTo: movedTo, byAI: intent?.by == .ai)
        // 5e1ecbae2 receives exactly its old marker while any older computer remains.
        if let intent, cloudDeleteRuleIsOpen() { CloudDeleteTravel.write(intent, into: &removal.travel) }
        let data = Data(removal.text(id: Self.newNoteID(now()), name: oneRuleName(path)).utf8)
        let hash = BackendCloudBrainMemoryHash.bytes(data)
        let copy = try cloudVersionsFolder().appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: copy.path) { try data.write(to: copy, options: .atomic); try BackendCloudBrainMemoryHash.synchronize(copy) }
        try cloudNoteRemoval(hash: hash, path: path, at: at, movedTo: movedTo)
        try db.run("INSERT INTO cloud_memory_journal(inventory,resource_key,file,hash,base_version,source_store) VALUES (?,?,?,?,?,?)",
                   [.text(inventory), .text(key), .text(copy.path), .text(hash), .optional(origin?.string(2)), .text(store)])
        if let intent {
            let raw = String(decoding: try JSONEncoder().encode(intent), as: UTF8.self)
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text("deleteRule:journaled:" + path), .text(raw)])
        }
        return .sent
    }
    enum CloudRemovalSend { case sent, nothing, waitingForSwitch }
    /// The text a gone file last had here: a byte copy, the Bin (Remove put it there first), or the resource's head
    /// parts when the head is that text. A removal sent long after the file went (blockers 2) still knows whether it
    /// was a move.
    func cloudLastBytes(path: String, store: String, key: String, lastHash: String?) throws -> Data? {
        guard let lastHash else { return nil }
        if let data = cloudKnownBytes(hash: lastHash, stores: [store, try cloudStoreId()]) { return data }
        let keeper = try cloudKeeper()
        if let binned = try keeper.bin(itemKey: Self.oneRuleItemKey(path)), binned.sha256 == lastHash,
           let data = keeper.content(kind: binned.kind, sha256: lastHash) { return data }
        if let head = try db.first("SELECT version,hash FROM cloud_memory_export_heads WHERE resource_key=?", [.text(store + ":" + key)]), head.text(1) == lastHash {
            return try cloudHeadBytes(path: path, store: store, key: key, version: head.text(0), hash: lastHash)
        }
        return nil
    }

    /// Where a gone file's text lives on, ONLY for a move the app itself made and recorded (lead, 15 Nov, review
    /// must-fix 1): an archive, restore or rename through the app or a tool (`cloudRecordMemoryMove`), or an archived
    /// note/hand-off the app's own archive wrote (`origin_path` plus the archived stamp it writes into the file, same note
    /// id). "The file is gone and the same text exists elsewhere" is NOT a move: a Finder duplicate he made days ago must
    /// never turn his hand delete into a travelling "moved". The target must still hold the same text (same bytes, or the
    /// same words: an archive changes only the labels). nil = not a move (a hand delete becomes a local mark).
    func cloudMovedTo(_ path: String, lastBytes: Data?) throws -> String? {
        guard let lastBytes else { return nil }
        var candidates: [String] = []
        if let recorded = try cloudRecordedMove(from: path) { candidates.append(recorded) }
        let id = String(data: lastBytes, encoding: .utf8).flatMap { DeckMemoryFile(text: $0).value("id") } ?? ""
        if !id.isEmpty {
            for table in ["notes", "handoffs"] {
                for row in try db.rows("SELECT path FROM \(table) WHERE origin_path=? AND id=? AND archived IS NOT NULL AND missing=0 AND path<>? ORDER BY updated DESC LIMIT 4",
                                       [.text(path), .text(id), .text(path)]) {
                    let archived = row.text(0)
                    guard let url = try? DeckMemoryCloudSchema.safePath(archived, root: root), let text = DeckMemoryFiles.read(url),
                          let stamp = DeckMemoryFile(text: text).value("archived"), !stamp.isEmpty else { continue }
                    candidates.append(archived)
                }
            }
        }
        return candidates.first { cloudIdenticalInUse(at: $0, bytes: lastBytes) }
    }
    static let moveRecordPrefix = "deleteRule:move:"
    /// The app made a move (archive, restore, rename through the app or a tool): the old place's removal may travel as a
    /// move once the old place is gone and `to` holds the same text. Cleared when the old place is seen again or when
    /// its removal was journaled.
    func cloudRecordMemoryMove(from: String, to: String) throws {
        // Without Cloud memory there is nothing to send; the move needs no record.
        guard from != to, cloudMemoryEnabled, (try? cloudAttached()) == true else { return }
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(Self.moveRecordPrefix + from), .text(to)])
    }
    /// A whole folder the app moved: every file now under `to` came from the same place under `from`.
    func cloudRecordFolderMove(from: String, to: String) throws {
        guard cloudMemoryEnabled, (try? cloudAttached()) == true else { return }
        for moved in try cloudScanSourceFiles(prefixes: [to]).paths where moved.hasPrefix(to + "/") {
            try cloudRecordMemoryMove(from: from + moved.dropFirst(to.count), to: moved)
        }
    }
    func cloudRecordedMove(from path: String) throws -> String? {
        try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(Self.moveRecordPrefix + path)])?.string(0)
    }
    func cloudForgetRecordedMove(_ path: String) throws {
        try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(Self.moveRecordPrefix + path)])
    }

    /// An arrived removal marker for the file at `path`. The rule decides by revision order against what this file is
    /// here; an edit made here that is not a revision yet stays and is decided once it is one.
    func cloudApplyRemoval(_ p: CloudBrainMemoryPart, _ removal: DeckMemoryRemoval, path: String) throws -> CloudApplyStatus {
        try cloudNoteRemoval(hash: p.resourceHash, path: path, at: removal.at, movedTo: removal.movedTo)
        let state = try CloudDeleteState(memory: db)
        // Lead's decision 2 (review must-fix 2): a badly formed removal (an unknown rule number, a group that is not a
        // uuid, a garbage scope or author, a "moved to" naming no memory place) never fails the batch and never stalls
        // memory sync: it is kept as a version, the file here is left alone, the item is answered, the batch goes on.
        let travel: CloudDeleteTravelRemoval
        do {
            if let movedTo = removal.movedTo {
                guard (try? DeckMemoryCloudSchema.safePath(movedTo, root: root)) != nil, DeckMemoryCloudSchema.fileRow(movedTo) != nil else {
                    throw CloudDeleteRuleError.invalidTravelFields
                }
            }
            travel = try CloudDeleteTravel.read(removal.travel, place: path, mac: removal.by, at: removal.at)
        } catch {
            CloudSyncDiagnostics.shared.info("memory: a removal from another device was in a form this Mac does not know, so the file here was left as it is and the removal was kept as history.")
            return try cloudKeepVersionForOneRule(p)
        }
        let intent: CloudDeleteIntent
        let era: CloudBinEra
        switch travel {
        case .intent(let value): intent = value; era = .current
        case .olderVersion:
            intent = .init(place: path, scope: .everywhere, by: removal.byAI ? .ai : .person, mac: removal.by,
                           at: removal.at, group: BackendCloudBrainMemoryHash.uuid("older-removal:" + removal.by + ":" + DeckMemoryFiles.day(Date(timeIntervalSince1970: Double(removal.at) / 1000))))
            era = .olderVersion
        }
        guard cloudMemoryRootAvailable() else { try cloudMarkPendingMerge(p); return try cloudKeepVersionForOneRule(p) }
        if try state.mark(at: path) != nil { return try cloudKeepVersionForOneRule(p) }
        let target = try DeckMemoryCloudSchema.safePath(path, root: root), fm = FileManager.default
        func takeRemoval() throws {
            try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(path)])
            try db.run("INSERT INTO cloud_memory_file_origins(path,store_id,resource_key,version) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET store_id=excluded.store_id,resource_key=excluded.resource_key,version=excluded.version",
                       [.text(path), .text(p.storeId), .text(p.key), .text(p.version)])
            try cloudWriteImportHead(p)
        }
        guard fm.fileExists(atPath: target.path) else {
            try takeRemoval()
            return try cloudKeepVersionForOneRule(p)
        }
        let current = try cloudHashFile(target)
        let wins: Bool?
        if try cloudUntouchedPredecessor(p) == path { wins = true }
        else if let incoming = try cloudRevision(storeId: p.storeId, key: p.key, version: p.version) {
            switch try cloudLocalSide(path: path, key: p.key, current: current) {
            case .known(let local):
                // A MOVE wins only over exactly the version it was made from (never by date: a move the settling sent
                // is dated when it was sent, not when the note moved). Phase 2 review, blocker 3: a plain removal wins
                // only over a text it was made on top of (the Cloud's revision ancestry, never the time stamp): an edit
                // made at the same time, even an earlier one, is never removed by it; the EDIT wins on every Mac.
                if removal.movedTo != nil { wins = p.parents.contains(local.version) }
                else { wins = p.parents.contains(local.version) || incoming.ancestors.contains(local.version) }
            case .unrecorded: wins = removal.movedTo != nil ? false : nil
            }
        } else { wins = false }
        guard let wins else {
            try cloudMarkPendingMerge(p); try cloudLookAtFilesOnce()
            return try cloudKeepVersionForOneRule(p)
        }
        guard wins else { return try cloudKeepVersionForOneRule(p) }
        let bytes = try Data(contentsOf: target)
        guard BackendCloudBrainMemoryHash.bytes(bytes) == current else { throw CloudFailure.versionChanged }
        var ref: DeckMemoryVersionRef?
        if case .known(let local) = try cloudLocalSide(path: path, key: p.key, current: current) { ref = .init(storeId: local.storeId, key: p.key, version: local.version) }
        let keeper = try cloudKeeper(), item = Self.oneRuleItemKey(path)
        let saved = try keeper.binPut(kind: Self.oneRuleKind, itemKey: item, name: oneRuleName(path), place: Self.oneRulePlace(path), path: path, removedAt: removal.at,
                                      device: Self.binDevice(removal.by.isEmpty ? cloudVersionDevice(key: p.key, version: p.version) : removal.by, byAI: intent.by == .ai), content: bytes,
                                      shown: !cloudIdenticalInUse(at: removal.movedTo, bytes: bytes), now: cloudNowMs())
        if removal.movedTo == nil { try cloudRememberBin(saved, intent: intent, era: era) }
        if let ref { try keeper.setRevision(itemKey: item, sha256: BackendCloudBrainMemoryHash.bytes(bytes), storeId: ref.storeId, resourceKey: ref.key, revision: ref.version) }
        try takeRemoval()
        if intent.scope == .cloud {
            try state.putMark(.init(place: path, mark: .onlyOnThisMac, at: intent.at))
            return try cloudKeepVersionForOneRule(p)
        }
        // The file must still be exactly what was kept (an edit a moment ago is never removed).
        guard try cloudHashFile(target) == current else { throw CloudFailure.versionChanged }
        try fm.removeItem(at: target)
        // The note's new place is indexed again too: a restore that arrived before this archive removal was held back
        // while the archived copy stood beside it.
        let again = (removal.movedTo.map { [$0] } ?? []) + Self.archiveOrigins(path).filter { FileManager.default.fileExists(atPath: url($0).path) }
        _ = try reindexNow(paths: [path] + again)
        return try cloudKeepVersionForOneRule(p)
    }
    /// An arrived version for a file that is NOT here because this Mac holds a removal as the resource's head.
    /// nil = place it (it is newer: a put back, or an edit made after the removal); else it was kept, not placed.
    func cloudAgainstRemoval(_ p: CloudBrainMemoryPart, path: String, assembled: URL) throws -> CloudApplyStatus? {
        var heads: [(String, String)] = [(p.storeId, p.key)]
        if let origin = try db.first("SELECT store_id,resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(path)]), origin.text(0) != p.storeId || origin.text(1) != p.key {
            heads.append((origin.text(0), origin.text(1)))
        }
        var found: (store: String, key: String, version: String)?
        for (s, k) in heads where found == nil {
            if let head = try cloudRemovalHead(storeId: s, key: k) { found = (s, k, head.version) }
        }
        // This Mac's own removal still waiting to be sent: it is not a revision yet, so the arrival waits for it.
        var removalWaiting = false
        for (_, k) in heads where !removalWaiting {
            if let waiting = try db.first("SELECT j.hash FROM cloud_memory_journal j WHERE j.resource_key=? AND NOT EXISTS (SELECT 1 FROM cloud_memory_seq_versions m WHERE m.seq=j.seq) ORDER BY j.seq DESC LIMIT 1", [.text(k)])?.string(0) {
                removalWaiting = try cloudIsRemoval(hash: waiting)
            }
        }
        if !removalWaiting { guard let found, found.version != p.version else { return nil } }
        let incomingWins: Bool?
        if removalWaiting { incomingWins = nil }
        else if let found, p.parents.contains(found.version) { incomingWins = true }
        else if let found {
            // The text moved on or was removed; an edit made elsewhere is never lost to a move or a removal (phase 2
            // review, blocker 3: never by time stamp, a removal made later than the edit included): it is placed,
            // unless the move or removal was made on top of it already (then it is older history).
            incomingWins = !((try cloudRevision(storeId: found.store, key: found.key, version: found.version))?.ancestors.contains(p.version) ?? false)
        } else { incomingWins = false }
        guard let incomingWins else {
            // This Mac's own removal is not a revision yet: decided once it is one.
            try cloudMarkPendingMerge(p)
            return try cloudKeepVersionForOneRule(p)
        }
        if incomingWins {
            // Back in use: it leaves this Mac's Bin (the Bin's text stays a kept version for its 30 days).
            try cloudKeeper().binTake(itemKey: Self.oneRuleItemKey(path), now: cloudNowMs())
            return nil
        }
        try cloudKeepText(path: path, content: Data(contentsOf: assembled), ref: .init(storeId: p.storeId, key: p.key, version: p.version), at: nil, device: nil)
        return try cloudKeepVersionForOneRule(p)
    }
    /// This Mac's own edit must become a revision: the reconcile looks at the files, without restarting a walk that
    /// is already under way (a pending item is looked at again on every maintenance step).
    func cloudLookAtFilesOnce() throws {
        guard try db.first("SELECT value FROM cloud_memory_control WHERE key='filesDirty'")?.text(0) != "1" else { return }
        try cloudMarkFilesDirty()
    }
    /// A version recorded but deliberately not placed (projection ""): history, never "unresolved".
    func cloudKeepVersionForOneRule(_ p: CloudBrainMemoryPart) throws -> CloudApplyStatus {
        try db.run("INSERT INTO cloud_memory_versions(store_id,resource_key,revision,content_hash,inventory,body,projection,projected_hash,parents) VALUES (?,?,?,?,?,?,'',NULL,?) ON CONFLICT(store_id,resource_key,revision) DO NOTHING",
                   [.text(p.storeId), .text(p.key), .text(p.version), .text(p.resourceHash), .text(p.inventoryRow), .blob(Data()), .blob(try CloudWire.canonical(p.parents))])
        return .applied
    }

    /// Two different texts for one file (neither descends from the other): the newer revision is the file in use,
    /// the other is kept 30 days. Replaces the "-cloud-<hash>" second live file and `archive/cloud-conflicts`.
    func cloudNewestFile(_ path: String, current: String, assembled: URL, p: CloudBrainMemoryPart) throws -> CloudApplyStatus {
        let incomingRef = DeckMemoryVersionRef(storeId: p.storeId, key: p.key, version: p.version)
        guard let incoming = try cloudRevision(storeId: p.storeId, key: p.key, version: p.version) else {
            try cloudKeepText(path: path, content: Data(contentsOf: assembled), ref: incomingRef, at: nil, device: nil)
            return try cloudKeepVersionForOneRule(p)
        }
        switch try cloudLocalSide(path: path, key: p.key, current: current) {
        case .known(let local):
            // His own text beats an untouched app default (Decker, 14 Nov): only between texts neither built on the other.
            let related = p.parents.contains(local.version) || incoming.ancestors.contains(local.version) || local.ancestors.contains(incoming.version)
            if !related, let incomingWins = try cloudDefaultRule(path, first: p.resourceHash, second: current) {
                if incomingWins { return try cloudReplace(path, with: assembled, p: p) }
                try cloudKeepText(path: path, content: Data(contentsOf: assembled), ref: incomingRef, at: incoming.stamp, device: nil)
                return try cloudKeepVersionForOneRule(p)
            }
            if p.parents.contains(local.version) || DeckMemoryCloudMerge.winner(incoming, local).version == incoming.version {
                return try cloudReplace(path, with: assembled, p: p)
            }
            try cloudKeepText(path: path, content: Data(contentsOf: assembled), ref: incomingRef, at: incoming.stamp, device: nil)
            return try cloudKeepVersionForOneRule(p)
        case .unrecorded:
            // This Mac's edit is not a revision yet: it stays in use; the arrival is kept now and decided by the same
            // rule once this Mac's edit is a revision (both Macs then compare the same two revisions).
            try cloudKeepText(path: path, content: Data(contentsOf: assembled), ref: incomingRef, at: incoming.stamp, device: nil)
            try cloudMarkPendingMerge(p); try cloudLookAtFilesOnce()
            return try cloudKeepVersionForOneRule(p)
        }
    }

    // MARK: Remove, put back, use this version, clean up (the file manager's store side)

    /// Compatibility entry point for the page and tools. Both now use the same intent-first path for every memory kind.
    public func memoryRemove(path: String, fromAI: Bool = false) async throws -> DeckMemoryBinItem {
        let actor = CloudDeleteActor(by: fromAI ? .ai : .person, mac: cloudDeviceId ?? "", macName: cloudMemoryMacName(cloudDeviceId ?? ""),
                                    at: cloudNowMs(), group: UUID().uuidString.lowercased())
        _ = try await deleteItems([cloudMemoryItem(path)], scope: .everywhere, by: actor)
        guard let saved = try cloudKeeper().bin(itemKey: Self.oneRuleItemKey(path)) else { throw CloudFailure.unavailable }
        return Self.binItem(saved)
    }
    /// Puts a Bin item back where it was, on every Mac: it becomes the newest version (a revision on top of the
    /// removal). A different text now at that place is kept as a version first, and the result says so.
    @discardableResult
    public func memoryPutBack(path: String) async throws -> DeckMemoryPutBackResult {
        let keeper = try cloudKeeper(), item = Self.oneRuleItemKey(path)
        guard let binned = try keeper.bin(itemKey: item), let content = keeper.content(kind: binned.kind, sha256: binned.sha256) else {
            throw missing("That item is not in the Bin any more.")
        }
        let replaced = try cloudWriteAsNewest(path: path, content: content)
        try keeper.binTake(itemKey: item, now: cloudNowMs())
        return .init(path: path, name: binned.name, replacedAnother: replaced)
    }
    /// "Put back everything removed since <time>": every Bin item (listed or kept for a move) this Mac put in the Bin
    /// at or after `since` returns. The way back from a mass removal. Returns what came back.
    @discardableResult
    public func memoryPutBackAll(since: Int64) async throws -> [DeckMemoryPutBackResult] {
        var back: [DeckMemoryPutBackResult] = [], failed = 0
        // The owner's only way back from a large removal: one item that cannot come back never stops the others.
        for item in try cloudKeeper().binAll(kind: Self.oneRuleKind) where item.keptUntil - CloudBootFilesRules.keptFor >= since {
            do { back.append(try await memoryPutBack(path: item.path)) } catch { failed += 1 }
        }
        if failed > 0 { CloudSyncDiagnostics.shared.info("memory: \(failed) Bin " + (failed == 1 ? "item" : "items") + " could not be put back; the others were.") }
        return back
    }
    /// Makes a kept text the one in use, on every Mac: it becomes the newest version; the text it replaces is kept.
    public func memoryUseVersion(path: String, versionId: String) async throws { try cloudUseKeptVersion(path: path, versionId: versionId) }
    /// The body of `memoryUseVersion`, for the one-time default repair (the step is not async).
    func cloudUseKeptVersion(path: String, versionId: String) throws {
        let keeper = try cloudKeeper(), item = Self.oneRuleItemKey(path)
        guard BackendCloudVersionKeeper.isSha(versionId), try keeper.version(itemKey: item, sha256: versionId) != nil,
              let content = keeper.content(kind: Self.oneRuleKind, sha256: versionId) else { throw missing("That version is not kept any more.") }
        _ = try cloudWriteAsNewest(path: path, content: content)
    }
    /// Writes `content` as this Mac's newest edit. Returns true when a DIFFERENT text was at that place (kept first).
    func cloudWriteAsNewest(path: String, content: Data) throws -> Bool {
        guard cloudMemoryEnabled else { throw DeckMemoryError(.invalid, "This works while Cloud is on for this Mac.") }
        let file = try DeckMemoryCloudSchema.safePath(path, root: root)
        var replaced = false
        if FileManager.default.fileExists(atPath: file.path) {
            if try Data(contentsOf: file) != content {
                try cloudKeepCurrent(path)
                replaced = true
            }
        }
        let state = try CloudDeleteState(memory: db)
        // An explicit restore authorizes this capture even when its parent is a Cloud-only removal.
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,'1')", [.text("deleteRule:returning:" + path)])
        try state.clearMark(at: path)
        try state.clearIntent(at: path)
        try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(path)])
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, options: .atomic)
        _ = try reindexNow(paths: [path])
        // An ordinary edit here: captured with the path's recorded version (a removal, for a put back) as its parent.
        try cloudCaptureChangedFiles(force: true, paths: [path])
        hub.post(.init(area: .index, at: now()))
        return replaced
    }
    /// The Bin (removals only, newest first).
    public func memoryBin() throws -> [DeckMemoryBinItem] {
        guard cloudStateRoot != nil else { return [] }
        // A note in use is never also in the Bin (round 3): whatever is back at its place leaves the list.
        return try cloudKeeper().binList(kind: Self.oneRuleKind).filter { item in
            guard let file = try? DeckMemoryCloudSchema.safePath(item.path, root: root) else { return true }
            return !FileManager.default.fileExists(atPath: file.path) || (try? CloudDeleteState(memory: db).mark(at: item.path)?.mark) == .onlyOnThisMac
        }.map(Self.binItem)
    }
    /// An item placed back in use (an edit from another device, a restore) leaves the Bin; its text stays a kept version.
    func cloudLeaveBin(_ path: String) throws {
        guard cloudStateRoot != nil else { return }
        let keeper = try cloudKeeper(), item = Self.oneRuleItemKey(path)
        if try keeper.bin(itemKey: item) != nil { try keeper.binTake(itemKey: item, now: cloudNowMs()) }
    }
    /// The kept older texts of one item, newest first.
    public func memoryVersions(path: String) throws -> [DeckMemoryKeptVersion] {
        guard cloudStateRoot != nil else { return [] }
        return try cloudKeeper().versions(itemKey: Self.oneRuleItemKey(path)).map {
            DeckMemoryKeptVersion(id: $0.sha256, at: $0.at, device: $0.device, bytes: $0.bytes, keptUntil: $0.keptUntil)
        }
    }
    /// How many kept texts "Clean up now" would delete here (for the owner's approval line).
    public func memoryCleanUpCount() throws -> Int {
        guard cloudStateRoot != nil else { return 0 }
        return try cloudKeeper().versions(kind: Self.oneRuleKind).count
    }
    /// A kept text, for Show.
    public func memoryVersionText(path: String, versionId: String) throws -> String? {
        let keeper = try cloudKeeper()
        guard try keeper.version(itemKey: Self.oneRuleItemKey(path), sha256: versionId) != nil || keeper.bin(itemKey: Self.oneRuleItemKey(path))?.sha256 == versionId else { return nil }
        return keeper.content(kind: Self.oneRuleKind, sha256: versionId).flatMap { String(data: $0, encoding: .utf8) }
    }
    /// "Clean up now": every kept older text goes for good, here and (when every Mac understands it) on every Mac.
    /// Texts in use and Bin items are untouched. OWNER ONLY: never on an AI's word, never auto-approved; the approval
    /// line states `memoryCleanUpCount()`. Returns how many went here.
    @discardableResult
    public func memoryCleanUpVersions() async throws -> Int { try cloudSetCleanup(Self.cleanupVersionsKey) }
    /// "Empty Bin": every Bin item goes for good, here and on every Mac. OWNER ONLY, like Clean up now; the approval
    /// line states `memoryBin().count`.
    @discardableResult
    public func memoryEmptyBin() async throws -> Int { try cloudSetCleanup(Self.cleanupBinKey) }
    /// A cleanup time is the SERVICE clock's now, never this Mac's own clock.
    private func cloudSetCleanup(_ key: String) throws -> Int {
        guard DeckMemoryCloudClocks.shared.injected(self), let at = DeckMemoryCloudClocks.shared.now(for: self), at > 0 else {
            throw DeckMemoryError(.invalid, "Cloud time is not known on this Mac yet. Try again in a moment.")
        }
        if cloudOneRuleSends() {
            try setSetting(String(at), key: key, owner: nil)
            post(.settings, nil, key)
        } else {
            // Phase 1: applied on this Mac only; nothing is sent until every Mac understands it.
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text("oneRule:local:" + key), .text(String(at))])
        }
        return try cloudApplyCleanups()
    }
    static func binItem(_ b: BackendCloudVersionKeeper.Binned) -> DeckMemoryBinItem {
        var item = DeckMemoryBinItem(path: b.path, name: b.name, place: b.place, removedAt: b.removedAt, device: binDeviceId(b.device), bytes: b.bytes, keptUntil: b.keptUntil)
        item.byAI = binByAI(b.device)
        return item
    }
    /// The keeper's `device` of a Bin item: the Mac's id, with "#ai" when an AI removed it (no new keeper column).
    static func binDevice(_ device: String, byAI: Bool) -> String { byAI ? device + "#ai" : device }
    static func binDeviceId(_ stored: String) -> String { stored.hasSuffix("#ai") ? String(stored.dropLast(3)) : stored }
    static func binByAI(_ stored: String) -> Bool { stored.hasSuffix("#ai") }
    /// The text of a Bin item, for Show on the page (the file is no longer in the memory folder).
    public func memoryBinText(path: String) throws -> String? {
        guard cloudStateRoot != nil, let binned = try cloudKeeper().bin(itemKey: Self.oneRuleItemKey(path)) else { return nil }
        return try memoryVersionText(path: path, versionId: binned.sha256)
    }
    /// Every place in this Mac's Bin (listed or kept for a move) whose file is not in the folder: for the page's
    /// "deleted places" (its Cloud record stays, the place is never a row in use again).
    public func memoryRemovedPlaces() -> Set<String> {
        guard cloudStateRoot != nil, let all = try? cloudKeeper().binAll(kind: Self.oneRuleKind) else { return [] }
        return Set(all.map(\.path).filter { path in
            guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root) else { return false }
            return !FileManager.default.fileExists(atPath: file.path)
        })
    }

    // MARK: The 30-day sweep and the shared cleanup times

    /// A cleanup time is honoured only when it is a plain number, positive, and NOT later than the service clock's now
    /// (a value from a confused device or a wrong clock is ignored, and looked at again later). Without the service
    /// clock nothing is applied. Kept texts and Bin items are kept until (put time + 30 days); "put at or before T" is
    /// "kept until before T + 30 days + 1 ms", so an item put in the Bin in this very step is never deleted by it.
    static func cloudCleanupBefore(_ raw: String?, serviceNow: Int64) -> Int64? {
        guard let raw, let value = Int64(raw), value > 0, value <= serviceNow else { return nil }
        let (sum, overflow) = value.addingReportingOverflow(CloudBootFilesRules.keptFor)
        return overflow ? nil : sum - 1
    }
    func cloudApplyCleanups() throws -> Int {
        guard cloudStateRoot != nil, DeckMemoryCloudClocks.shared.injected(self), let serviceNow = DeckMemoryCloudClocks.shared.now(for: self) else { return 0 }
        let keeper = try cloudKeeper()
        var removed = 0
        for (key, mark) in [(Self.cleanupVersionsKey, "oneRule:versionsBefore"), (Self.cleanupBinKey, "oneRule:binBefore")] {
            let shared = try setting(key, owner: nil)
            let local = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("oneRule:local:" + key)])?.string(0)
            let values = [shared, local].compactMap { $0 }.compactMap { raw -> (Int64, Int64)? in
                guard let before = Self.cloudCleanupBefore(raw, serviceNow: serviceNow), let value = Int64(raw) else { return nil }
                return (value, before)
            }
            guard let best = values.max(by: { $0.0 < $1.0 }) else { continue }
            let value = best.0, before = best.1
            let applied = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(mark)])?.string(0).flatMap(Int64.init) ?? Int64.min
            guard value > applied else { continue }
            if key == Self.cleanupVersionsKey { removed += try keeper.sweepVersions(kind: Self.oneRuleKind, keptUntilBefore: before) }
            else { removed += try keeper.sweepBin(kind: Self.oneRuleKind, keptUntilBefore: before) }
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(mark), .text(String(value))])
        }
        return removed
    }
    /// At most once a day, on the service clock only (a Mac whose clock is wrong never sweeps early): kept versions and
    /// Bin items whose 30 days are over go, and safety copies older than 30 days. Only the keeper's own copies are
    /// touched; a text in use never is.
    func cloudDailySweep() throws -> Int {
        guard DeckMemoryCloudClocks.shared.injected(self), let now = DeckMemoryCloudClocks.shared.now(for: self) else { return 0 }
        let last = try db.first("SELECT value FROM cloud_memory_control WHERE key='oneRule:sweptAt'")?.string(0).flatMap(Int64.init) ?? Int64.min
        guard last == Int64.min || now - last >= 24 * 3_600_000 || now < last else { return 0 }
        let keeper = try cloudKeeper()
        let removed = try keeper.sweepVersions(kind: Self.oneRuleKind, keptUntilBefore: now) + keeper.sweepBin(kind: Self.oneRuleKind, keptUntilBefore: now)
        cloudDropOldSafetyCopies(now: now)
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:sweptAt',?)", [.text(String(now))])
        return removed
    }

    func cloudJournalSize() throws -> Int { Int(try db.first("SELECT COUNT(*) FROM cloud_memory_journal")?.int(0) ?? 0) }

    // MARK: The safety copy (review round 2, item 6)

    /// `<dataRoot>/memory-safety/<yyyyMMdd-HHmmss>/` with `memory/` (every file of the memory folder except its own
    /// database backups, plus a consistent copy of memory.db) and `versions/` (the account's keeper). Outside anything
    /// that syncs. Made ONCE before the settling touches anything; the settling refuses to start without it.
    func cloudSafetyRoot() -> URL? { dataRoot?.appendingPathComponent("memory-safety", isDirectory: true) }
    /// Phase 2 (review point 7): the phase-2 settling gets its OWN fresh copy (`key` "oneRule:safetyCopy2"), made when
    /// phase 2 first becomes active on this Mac, so it holds everything the phase-1 settling and the weeks since left.
    func cloudEnsureSafetyCopy(key: String = "oneRule:safetyCopy") throws -> Bool {
        if let made = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(key)])?.string(0),
           FileManager.default.fileExists(atPath: made) { return true }
        guard let base = cloudSafetyRoot(), let state = cloudStateRoot else { return false }
        let fm = FileManager.default
        let keeperRoot = BackendCloudVersionKeeper.root(besideStateRoot: state)
        var files: [(URL, String)] = [], bytes: Int64 = 0
        func walk(_ folder: URL, as prefix: String, skip: (String) -> Bool) {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return }
            for case let file as URL in e {
                let rel = String(file.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                if skip(rel) { e.skipDescendants(); continue }
                guard let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]), v.isRegularFile == true, v.isSymbolicLink != true else { continue }
                files.append((file, prefix + rel)); bytes += Int64(v.fileSize ?? 0)
            }
        }
        walk(root, as: "memory/") { $0 == "archive/backups" || $0.hasPrefix("memory.db") || $0.hasPrefix(".cloud") }
        if fm.fileExists(atPath: keeperRoot.path) { walk(keeperRoot, as: "versions/") { _ in false } }
        bytes += (try? fm.attributesOfItem(atPath: root.appendingPathComponent("memory.db").path)[.size] as? NSNumber)?.int64Value ?? 0
        // Integration run (0220z): a copy that cannot even start (its folder cannot be made or read) is a failed copy:
        // false and one plain problem line, never an error out of the settling step. On his Macs `memory-safety` is
        // already a folder holding the phase-1 copy (one per second-stamped name), so a second copy never collides.
        let volume: URLResourceValues
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            volume = try base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        } catch {
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:problem',?)",
                       [.text("The safety copy of memory could not be made, so nothing is removed or sent to your other devices until it is. It tries again later.")])
            return false
        }
        guard (volume.volumeAvailableCapacityForImportantUsage ?? 0) > bytes + 256 * 1024 * 1024 else {
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:problem',?)",
                       [.text("There is not enough free disk space for a safety copy of memory, so nothing is removed or sent to your other devices until it is made. It tries again later.")])
            return false
        }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyyMMdd-HHmmss"
        var folder = base.appendingPathComponent(format.string(from: Date()), isDirectory: true)
        // Two copies in the same second (phase 1 and phase 2 on a first launch) never share a folder.
        var copyDate = Date()
        while fm.fileExists(atPath: folder.path) {
            copyDate = copyDate.addingTimeInterval(1)
            folder = base.appendingPathComponent(format.string(from: copyDate), isDirectory: true)
        }
        let staging = base.appendingPathComponent(".preparing-" + folder.lastPathComponent, isDirectory: true)
        try? fm.removeItem(at: staging)
        do {
            for (source, rel) in files {
                let target = staging.appendingPathComponent(rel)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
            }
            try fm.createDirectory(at: staging.appendingPathComponent("memory"), withIntermediateDirectories: true)
            try db.cloudBackup(to: staging.appendingPathComponent("memory/memory.db"))
            if try cloudAttached() { try db.cloudBackup(to: staging.appendingPathComponent("memory/memory-cloud.db"), schema: "cloud") }
            try fm.moveItem(at: staging, to: folder)
        } catch {
            try? fm.removeItem(at: staging)
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:problem',?)",
                       [.text("The safety copy of memory could not be made, so nothing is removed or sent to your other devices until it is. It tries again later.")])
            return false
        }
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(key), .text(folder.path)])
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(key + "Bytes"), .text(String(bytes))])
        try db.run("DELETE FROM cloud_memory_control WHERE key='oneRule:problem'")
        return true
    }
    /// Safety copies older than 30 days go (by their own dated name).
    func cloudDropOldSafetyCopies(now: Int64) {
        guard let base = cloudSafetyRoot() else { return }
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyyMMdd-HHmmss"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] {
            guard let made = format.date(from: name), Int64(made.timeIntervalSince1970 * 1000) + CloudBootFilesRules.keptFor < now else { continue }
            try? FileManager.default.removeItem(at: base.appendingPathComponent(name))
        }
    }
    /// Puts the memory folder back as the safety copy had it: every file of the copy that is missing or different here
    /// is written back; what is here now and differs is kept first (the keeper, 30 days). Nothing else is removed and
    /// memory.db is rebuilt from the files by the index. Returns how many files were written back.
    @discardableResult
    public func memoryRestoreSafetyCopy() async throws -> Int {
        guard let made = try db.first("SELECT value FROM cloud_memory_control WHERE key='oneRule:safetyCopy2'")?.string(0).flatMap({ FileManager.default.fileExists(atPath: $0) ? $0 : nil })
                ?? db.first("SELECT value FROM cloud_memory_control WHERE key='oneRule:safetyCopy'")?.string(0) else {
            throw missing("There is no safety copy of memory on this Mac.")
        }
        let copy = URL(fileURLWithPath: made, isDirectory: true).appendingPathComponent("memory", isDirectory: true), fm = FileManager.default
        var written: [String] = []
        guard let e = fm.enumerator(at: copy, includingPropertiesForKeys: [.isRegularFileKey]) else { return 0 }
        // Integrator: an NSEnumerator cannot be iterated in async code (Swift 6); take its list first (same files, same order).
        for case let file as URL in e.allObjects {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let rel = String(file.standardizedFileURL.path.dropFirst(copy.standardizedFileURL.path.count + 1))
            guard !rel.hasPrefix("memory.db"), let target = try? DeckMemoryCloudSchema.safePath(rel, root: root) else { continue }
            let saved = try Data(contentsOf: file)
            if fm.fileExists(atPath: target.path) {
                guard try Data(contentsOf: target) != saved else { continue }
                if cloudStateRoot != nil { try cloudKeepCurrent(rel) } else if keepVersion(of: rel) == nil { continue }
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try saved.write(to: target, options: .atomic)
            written.append(rel)
        }
        for offset in stride(from: 0, to: written.count, by: 200) { _ = try reindexNow(paths: Array(written[offset..<min(offset + 200, written.count)])) }
        if cloudMemoryEnabled, !written.isEmpty { try cloudCaptureChangedFiles(paths: written) }
        return written.count
    }

    // MARK: The one-time settling of what earlier builds left (twins, conflict copies, archived copies, markers)

    /// One bounded step, run by the pumps' maintenance before the reconcile (never inside a memory write). Safe to run
    /// twice and safe to stop anywhere: a safety copy of the whole folder is made first (the settling refuses to start
    /// without it), every item is copied into the keeper BEFORE anything is removed, and a marker (`convert:<path>`)
    /// keeps the capture from reading a half-done item as a removal. Phase 1 settles LOCAL copies only (twins, conflict
    /// copies, markers placed here); the archived-copy step sends moves and waits for `cloudOneRuleSends`.
    func cloudOneRuleStep(limit: Int = 32) throws -> Int {
        guard cloudMemoryEnabled, cloudStateRoot != nil, try cloudAttached() else { return 0 }
        var work = 0
        // Decision 11: an announcement that waited for the service clock (or this Mac's id) is written within minutes.
        try? cloudRetryPendingAnnouncements()
        guard try cloudMigrateDeleteRule() else { return 0 }
        if !cloudAnnouncedThisRun {
            // A deadline task belongs to a process, while the two-look observation survives a relaunch.
            try db.run("DELETE FROM cloud_memory_control WHERE key='deleteRule:recheckAt'")
            try cloudForgetRemovedFiles(prefixes: nil)
        }
        try cloudAnnounceUnderstanding()
        // Blocker 4: the phase-2 safety copy is made as soon as every Mac understands, before anything can be sent.
        try cloudPrepareSendingCopy()
        func done(_ key: String) throws -> Bool { try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(key)])?.string(0) == "done" }
        // Point 8: a Mac that ran a build older than phase 1 placed removal markers as note text (indexed as notes of
        // type "removed"). Once per run, when any is found, the marker settling runs again (behind its safety copy).
        if !cloudStubsCheckedThisRun {
            cloudStubsCheckedThisRun = true
            // Review point 7: seat cards, playbooks, topics and other files are not in the notes index; one walk of the
            // small non-note files finds a marker an older build wrote into them.
            if try done("oneRule:stubs"),
               try db.first("SELECT 1 FROM notes WHERE type='removed' AND missing=0 AND path NOT LIKE 'archive/%' LIMIT 1") != nil || cloudNonNoteMarkerExists() {
                try db.run("DELETE FROM cloud_memory_control WHERE key='oneRule:stubs'")
                cloudOneRuleList = nil
            }
        }
        let sends = cloudOneRuleSends()
        let phase1 = try !done("oneRule:twins") || !done("oneRule:stubs")
        if phase1, try cloudEnsureSafetyCopy() {
            if try !done("oneRule:twins") { work += try cloudSettleTwins(limit: limit) }
            else if try !done("oneRule:stubs") { work += try cloudSettleStubs(limit: limit) }
        } else if !phase1, try !done(Self.defaultRepairKey), try cloudEnsureSafetyCopy() {
            // Once per Mac after the update (Decker, 14 Nov): his own text back in use where the settling had put the
            // app's default over it. After the phase-1 safety copy; before anything else of phase 2.
            work += try cloudRepairDefaultInUse()
        } else if !phase1, sends, try !done("oneRule:archived"), try cloudEnsureSafetyCopy(key: Self.sendingCopyKey) {
            // Phase 2 (review point 7): a fresh safety copy, made when sending first switches on here, comes first.
            work += try cloudSettleArchived(limit: limit)
        }
        // Retry durable intents after an interrupted action; never infer a travelling delete from a last-seen row.
        try cloudRetryMemoryIntents()
        if try done("oneRule:twins"), try done("oneRule:stubs"), try !done("oneRule:reported") {
            CloudSyncDiagnostics.shared.info(try memoryOneRuleReport().line)
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:reported','done')")
        }
        if try done("oneRule:archived"), try !done("oneRule:reported2"), let line = try memoryOneRuleReport().phase2Line {
            CloudSyncDiagnostics.shared.info(line)
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:reported2','done')")
        }
        // Arrivals and conflicts kept while this Mac's own edit was not a revision yet: decided now if it is one.
        try db.transaction {
            try db.run("UPDATE cloud_memory_control SET value='1' WHERE key='importing'")
            defer { try? db.run("UPDATE cloud_memory_control SET value='0' WHERE key='importing'") }
            try cloudSettlePendingMerges(limit: limit)
        }
        work += try cloudApplyCleanups()
        _ = try cloudDailySweep()
        return work
    }
    func cloudCount(_ key: String) throws {
        let now = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(key)])?.string(0).flatMap(Int.init) ?? 0
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(key), .text(String(now + 1))])
    }
    /// What the one-time settling did on this Mac (numbers and its own folder only; never a title or a note's text).
    public func memoryOneRuleReport() throws -> DeckMemoryOneRuleReport {
        func value(_ key: String) throws -> String? { try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(key)])?.string(0) }
        func number(_ key: String) throws -> Int { try value(key).flatMap(Int.init) ?? 0 }
        let left = Int(try db.first("SELECT COUNT(*) FROM cloud_memory_control WHERE key LIKE 'oneRule:left:%'")?.int(0) ?? 0)
        var report = DeckMemoryOneRuleReport(safetyCopy: try value("oneRule:safetyCopy"), safetyCopyBytes: try value("oneRule:safetyCopyBytes").flatMap(Int64.init),
                     copiesSettled: try number("oneRule:settledCopies"), markersSettled: try number("oneRule:settledMarkers"), leftAsTheyAre: left,
                     finished: try value("oneRule:twins") == "done" && value("oneRule:stubs") == "done", sending: cloudOneRuleSends(),
                     problem: try value("oneRule:problem"))
        report.phase2SafetyCopy = try value("oneRule:safetyCopy2")
        report.phase2SafetyCopyBytes = try value("oneRule:safetyCopy2Bytes").flatMap(Int64.init)
        report.archivedLookedAt = try number("oneRule:archivedLooked")
        report.movesSent = try number("oneRule:archivedMoves")
        report.archivedLeft = try number("oneRule:archivedLeft")
        report.archivedKept = try number("oneRule:archivedKept")
        report.phase2Finished = try value("oneRule:archived") == "done"
        return report
    }
    func cloudConvertMarked(_ path: String) throws -> Bool {
        try db.first("SELECT 1 FROM cloud_memory_control WHERE key=?", [.text("convert:" + path)]) != nil
    }

    /// `<stem>-cloud-<16 hex>.md` (not under archive/) and `archive/cloud-conflicts/<store>/<hash>/<path>`: the second
    /// copies earlier builds kept beside a file. Returns (copy, the file it is a copy of).
    static func cloudTwinMain(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        if parts.count >= 5, parts[0] == "archive", parts[1] == "cloud-conflicts" { return parts.dropFirst(4).joined(separator: "/") }
        guard parts.first != "archive", path.hasSuffix(".md") else { return nil }
        let stem = String(path.dropLast(3))
        guard stem.count > 24, let dash = stem.range(of: "-cloud-", options: .backwards) else { return nil }
        let hex = stem[dash.upperBound...]
        guard hex.count == 16, hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return String(stem[..<dash.lowerBound]) + ".md"
    }
    private func cloudSettleTwins(limit: Int) throws -> Int {
        // Half-done items first (an earlier run stopped after its marker).
        var done = 0
        for row in try db.rows("SELECT key FROM cloud_memory_control WHERE key LIKE 'convert:%' LIMIT ?", [.int(Int64(limit))]) {
            let twin = String(row.text(0).dropFirst("convert:".count))
            if let main = Self.cloudTwinMain(twin) { try cloudSettleTwin(twin, main: main) } else { try cloudFinishConvert(twin) }
            done += 1
        }
        if cloudOneRuleList == nil {
            cloudOneRuleList = try cloudScanSourceFiles().paths.filter { Self.cloudTwinMain($0) != nil }
        }
        var list = cloudOneRuleList ?? []
        while done < limit, let twin = list.popLast() {
            if let main = Self.cloudTwinMain(twin) { try cloudSettleTwin(twin, main: main); done += 1 }
        }
        cloudOneRuleList = list
        if list.isEmpty, try db.first("SELECT 1 FROM cloud_memory_control WHERE key LIKE 'convert:%'") == nil {
            cloudOneRuleList = nil
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:twins','done')")
        }
        return max(done, 1)
    }
    /// One copy settled by revision order: the newer revision is the file in use, the other text is kept 30 days.
    /// Nothing is sent: both texts are already in the Cloud; the other Mac decides the same way.
    func cloudSettleTwin(_ twin: String, main: String) throws {
        let fm = FileManager.default
        let twinURL = try DeckMemoryCloudSchema.safePath(twin, root: root), mainURL = try DeckMemoryCloudSchema.safePath(main, root: root)
        guard fm.fileExists(atPath: twinURL.path) else {
            // Stopped after the copy left: finish its bookkeeping, so the capture never reads it as a removal (the
            // copy's origin is the OTHER Mac's resource: a removal sent for it would remove that Mac's note).
            try db.transaction {
                try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(twin)])
                try db.run("DELETE FROM cloud_memory_file_origins WHERE path=?", [.text(twin)])
            }
            try cloudFinishConvert(twin); _ = try reindexNow(paths: [twin]); return
        }
        let twinBytes = try Data(contentsOf: twinURL), twinHash = BackendCloudBrainMemoryHash.bytes(twinBytes)
        let twinRef = try db.first("SELECT store_id,resource_key,revision FROM cloud_memory_versions WHERE projection=? ORDER BY rowid DESC LIMIT 1", [.text(twin)])
            .map { DeckMemoryVersionRef(storeId: $0.text(0), key: $0.text(1), version: $0.text(2)) }
        // Round 3: a copy is settled only while it is EXACTLY the version it was recorded as. A copy with no recorded
        // version, or one edited since (an AI wrote to it), is left as it is and counted.
        let recordedMatches = try twinRef.map { ref in
            try db.first("SELECT 1 FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=? AND (content_hash=? OR projected_hash=?)",
                         [.text(ref.storeId), .text(ref.key), .text(ref.version), .text(twinHash), .text(twinHash)]) != nil
        } ?? false
        guard recordedMatches else {
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,'1')", [.text("oneRule:left:" + twin)])
            try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("convert:" + twin)])
            return
        }
        try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("oneRule:left:" + twin)])
        let twinRev = try twinRef.flatMap { try cloudRevision(storeId: $0.storeId, key: $0.key, version: $0.version) }
        let removal = DeckMemoryRemoval.parse(twinBytes)
        let mainExists = fm.fileExists(atPath: mainURL.path)
        let mainBytes: Data? = try mainExists ? Data(contentsOf: mainURL) : nil
        var twinWins = false, pending = false
        if let mainBytes {
            if mainBytes != twinBytes, let twinRev {
                switch try cloudLocalSide(path: main, key: twinRef?.key, current: BackendCloudBrainMemoryHash.bytes(mainBytes)) {
                case .known(let local):
                    // His own text beats an untouched app default (Decker, 14 Nov, the owner's one rule): between two
                    // texts neither built on the other, a shipped default never wins over a text that is not one. The
                    // Mac mini put the MacBook's default playbook and lead settings in use over his own on 14 Nov
                    // because the default's first-copy stamp was two minutes later.
                    if removal == nil, !twinRev.ancestors.contains(local.version), !local.ancestors.contains(twinRev.version),
                       let byDefault = try cloudDefaultRule(main, first: twinHash, second: BackendCloudBrainMemoryHash.bytes(mainBytes)) {
                        twinWins = byDefault
                    } else if removal?.movedTo != nil {
                        // A move wins only over exactly the version it was made from, never by date.
                        let parents = try twinRef.flatMap { try cloudStoredPart(storeId: $0.storeId, key: $0.key, version: $0.version) }?.parents ?? []
                        twinWins = parents.contains(local.version)
                    } else {
                        // A removal twin: ancestry only (an edit made at the same time wins, blocker 3); a text: the rule.
                        twinWins = twinRev.ancestors.contains(local.version)
                            || (removal == nil && DeckMemoryCloudMerge.winner(twinRev, local).version == twinRev.version)
                    }
                case .unrecorded: pending = true   // this Mac's own edit is not a revision yet: it stays, decided later
                }
            }
        } else if removal == nil {
            // Only the copy is left: it is the text in use unless this Mac holds a newer removal of the file.
            if let twinRef, let twinRev, let head = try cloudRemovalHead(storeId: twinRef.storeId, key: twinRef.key),
               let removed = try cloudRevision(storeId: twinRef.storeId, key: twinRef.key, version: head.version) {
                // The text stays unless the removal was made on top of it (blocker 3: never by time stamp).
                twinWins = !removed.ancestors.contains(twinRev.version)
            } else { twinWins = true }
        }
        // 1. Every text is in the keeper before anything moves.
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,'1')", [.text("convert:" + twin)])
        if twinWins, removal == nil, let mainBytes, mainBytes != twinBytes { try cloudKeepCurrentBytes(main, mainBytes) }
        if !twinWins, removal == nil { try cloudKeepText(path: main, content: twinBytes, ref: twinRef, at: twinRev?.stamp, device: nil) }
        // 2. The newer text becomes (or stays) the file in use.
        if twinWins {
            if let removal, let mainBytes {
                try cloudKeeper().binPut(kind: Self.oneRuleKind, itemKey: Self.oneRuleItemKey(main), name: oneRuleName(main), place: Self.oneRulePlace(main), path: main,
                                         removedAt: removal.at, device: removal.by, content: mainBytes,
                                         shown: !cloudIdenticalInUse(at: removal.movedTo, bytes: mainBytes), now: cloudNowMs())
                guard try cloudHashFile(mainURL) == BackendCloudBrainMemoryHash.bytes(mainBytes) else { throw CloudFailure.versionChanged }
                try fm.removeItem(at: mainURL)
            } else if mainBytes != twinBytes {
                if let mainBytes { guard try cloudHashFile(mainURL) == BackendCloudBrainMemoryHash.bytes(mainBytes) else { throw CloudFailure.versionChanged } }
                try fm.createDirectory(at: mainURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try twinBytes.write(to: mainURL, options: .atomic)
            }
        }
        if pending, let twinRef, let p = try cloudStoredPart(storeId: twinRef.storeId, key: twinRef.key, version: twinRef.version) { try cloudMarkPendingMerge(p) }
        // 3. The copy leaves memory; the bookkeeping says the main file is that revision now (nothing to send).
        try db.transaction {
            if twinWins, let twinRef {
                if removal != nil { try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(main)]) }
                else {
                    try db.run("INSERT INTO cloud_memory_file_origins(path,store_id,resource_key,version) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET store_id=excluded.store_id,resource_key=excluded.resource_key,version=excluded.version",
                               [.text(main), .text(twinRef.storeId), .text(twinRef.key), .text(twinRef.version)])
                    let info = DeckMemoryFiles.info(mainURL)
                    try db.run("INSERT INTO cloud_memory_files(path,hash,bytes,mtime) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET hash=excluded.hash,bytes=excluded.bytes,mtime=excluded.mtime",
                               [.text(main), .text(twinHash), .int(Int64(info?.bytes ?? twinBytes.count)), .real(info?.mtime ?? 0)])
                }
                if let p = try cloudStoredPart(storeId: twinRef.storeId, key: twinRef.key, version: twinRef.version) { try cloudWriteImportHead(p) }
                if let removal { try cloudNoteRemoval(hash: twinHash, path: main, at: removal.at, movedTo: removal.movedTo) }
            }
            try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(twin)])
            try db.run("DELETE FROM cloud_memory_file_origins WHERE path=?", [.text(twin)])
        }
        try? fm.removeItem(at: twinURL)
        try cloudFinishConvert(twin)
        try cloudCount("oneRule:settledCopies")
        _ = try reindexNow(paths: [twin, main])
    }
    private func cloudKeepCurrentBytes(_ path: String, _ bytes: Data) throws {
        var ref: DeckMemoryVersionRef?
        if case .known(let rev) = try cloudLocalSide(path: path, key: nil, current: BackendCloudBrainMemoryHash.bytes(bytes)) {
            ref = .init(storeId: rev.storeId, key: try cloudKeyOfVersion(rev) ?? "file/" + path, version: rev.version)
        }
        try cloudKeepText(path: path, content: bytes, ref: ref, at: nil, device: ref == nil ? cloudDeviceId : nil)
    }
    private func cloudFinishConvert(_ path: String) throws {
        try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("convert:" + path)])
        // Removing the empty conflict-copy folders is cosmetic; a folder that still holds anything stays.
        if path.hasPrefix("archive/cloud-conflicts/") {
            var folder = (path as NSString).deletingLastPathComponent
            while folder.hasPrefix("archive/cloud-conflicts/"), (try? FileManager.default.contentsOfDirectory(atPath: url(folder).path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: url(folder)); folder = (folder as NSString).deletingLastPathComponent
            }
        }
    }

    /// Archived moves retain their existing revision/identity checks and resumable cursor.
    enum ArchivedMove { case sent, left, nothing }

    /// Archived notes. (1) A note archived because a newer note REPLACED it (superseded or merged) is listed as a kept
    /// version of that newer note (copied into the keeper; its archive file stays where it is: memory history is never
    /// deleted by this step). (2) Its old live place: a move is sent for it ONLY when the old place's last Cloud text has
    /// the same words as the archived note (`cloudSettleArchivedMove`); when another Mac edited the old place after the
    /// archive, NOTHING is sent for it and the edit stays in use everywhere. Resumable by a cursor.
    private func cloudSettleArchived(limit: Int) throws -> Int {
        guard DeckMemoryCloudClocks.shared.now(for: self) != nil else { return 0 }
        func control(_ key: String) throws -> Int64? { try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(key)])?.string(0).flatMap(Int64.init) }
        func setControl(_ key: String, _ value: Int64) throws { try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(key), .text(String(value))]) }
        let cursor = try control("oneRule:archivedCursor") ?? 0
        let rows = try db.rows("SELECT rowid,id,path,origin_path,superseded_by,archive_reason FROM notes WHERE archived IS NOT NULL AND missing=0 AND origin_path IS NOT NULL AND rowid>? ORDER BY rowid LIMIT ?",
                               [.int(cursor), .int(Int64(limit))])
        var last: Int64?, looked = 0
        for row in rows {
            last = row.int(0); looked += 1
            try cloudCount("oneRule:archivedLooked")
            let archivedPath = row.text(2), origin = row.text(3)
            guard let archivedURL = try? DeckMemoryCloudSchema.safePath(archivedPath, root: root), let archivedBytes = try? Data(contentsOf: archivedURL) else { continue }
            if let newer = row.string(4), ["superseded", "merged"].contains(BackendCloudNoteIdentity.reasonWord(row.string(5)) ?? ""),
               let newerPath = try db.first("SELECT path FROM notes WHERE id=? AND missing=0 AND archived IS NULL", [.text(newer)])?.string(0) {
                let item = Self.oneRuleItemKey(newerPath), sha = BackendCloudBrainMemoryHash.bytes(archivedBytes)
                if try cloudKeeper().version(itemKey: item, sha256: sha) == nil {
                    let at = DeckMemoryFiles.date(DeckMemoryFile(text: String(decoding: archivedBytes, as: UTF8.self)).value("archived")).map { Int64($0.timeIntervalSince1970 * 1000) }
                    try cloudKeepText(path: newerPath, content: archivedBytes, ref: nil, at: at, device: "")
                    try cloudCount("oneRule:archivedKept")
                }
            }
            switch try cloudSettleArchivedMove(origin: origin, archivedPath: archivedPath, archivedBytes: archivedBytes) {
            case .sent: try cloudCount("oneRule:archivedMoves")
            case .left: try cloudCount("oneRule:archivedLeft")
            case .nothing: break
            }
        }
        if let last { try setControl("oneRule:archivedCursor", last) }
        if rows.count < limit, looked == rows.count {
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:archived','done')")
        }
        return max(looked, 1)
    }
    /// The bytes of a resource's head revision on this Mac: the file at its place when it IS that revision, a byte copy
    /// this Mac still holds, or the head's own parts (kept for every current head, `cloudPruneSupersededParts`). Every
    /// answer is checked against the head's hash. nil = this Mac cannot say what the old place's last text was.
    func cloudHeadBytes(path: String, store: String, key: String, version: String, hash: String) throws -> Data? {
        if let url = try? DeckMemoryCloudSchema.safePath(path, root: root), let data = try? Data(contentsOf: url), BackendCloudBrainMemoryHash.bytes(data) == hash { return data }
        if let data = cloudKnownBytes(hash: hash, stores: [store, try cloudStoreId()]) { return data }
        let parts = try db.rows("SELECT part,total,body FROM cloud_memory_parts WHERE store_id=? AND resource_key=? AND revision=? ORDER BY part", [.text(store), .text(key), .text(version)])
        guard let total = parts.first?.int(1), total > 0, Int64(parts.count) == total,
              parts.enumerated().allSatisfy({ $0.offset == Int($0.element.int(0)) }) else { return nil }
        var data = Data()
        for part in parts { data.append(part.data(2) ?? Data()) }
        return BackendCloudBrainMemoryHash.bytes(data) == hash ? data : nil
    }
    /// Same words (an archive changes only the labels), or the same bytes.
    static func sameWords(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard let x = String(data: a, encoding: .utf8), let y = String(data: b, encoding: .utf8) else { return false }
        return DeckMemoryFile(text: x).body == DeckMemoryFile(text: y).body
    }
    /// One archived note's old place. `.sent`: a move went (the old place leaves memory on every Mac; its text stays in
    /// the archived note). `.left`: NOTHING was sent because the old place's last Cloud text is not the archived text
    /// (another Mac edited it after the archive), or this Mac cannot compare it, or an arrival for it still waits here.
    /// `.nothing`: no old place in the Cloud, or it is already removed.
    func cloudSettleArchivedMove(origin: String, archivedPath: String, archivedBytes: Data) throws -> ArchivedMove {
        guard origin != archivedPath, let originURL = try? DeckMemoryCloudSchema.safePath(origin, root: root) else { return .nothing }
        let fm = FileManager.default, own = try cloudStoreId()
        let fileOrigin = try db.first("SELECT store_id,resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(origin)])
        let store = fileOrigin?.text(0) ?? own, key = fileOrigin?.text(1) ?? "file/" + origin
        // The old place's LAST Cloud text: the head this Mac holds for its resource.
        guard let head = try db.first("SELECT version,hash FROM cloud_memory_export_heads WHERE resource_key=?", [.text(store + ":" + key)]) else { return .nothing }
        let headHash = head.text(1)
        if try cloudIsRemoval(hash: headHash) { return .nothing }
        // A newer arrival for it that waits here (kept, decided later) may be the other Mac's edit: send nothing.
        if try db.first("SELECT 1 FROM \(try cloudPendingMergeTable()) WHERE resource_key=? LIMIT 1", [.text(key)]) != nil { return .left }
        guard let headBytes = try cloudHeadBytes(path: origin, store: store, key: key, version: head.text(0), hash: headHash), DeckMemoryRemoval.parse(headBytes) == nil,
              Self.sameWords(headBytes, archivedBytes),
              // The move must name the archived note as the place holding the same text (never a plain removal).
              try cloudMovedTo(origin, lastBytes: headBytes) != nil else { return .left }
        if fm.fileExists(atPath: originURL.path) {
            guard let live = try? Data(contentsOf: originURL), DeckMemoryRemoval.parse(live) == nil else { return .nothing }
            // The file here must BE that last Cloud text: an edit made here (not sent yet) stays in use and travels.
            guard BackendCloudBrainMemoryHash.bytes(live) == headHash else { return .left }
            guard case .known = try cloudLocalSide(path: origin, key: key, current: headHash) else { return .left }
            // Into the keeper first (a move of the same words: kept 30 days, not listed), then out of the folder.
            try cloudKeeper().binPut(kind: Self.oneRuleKind, itemKey: Self.oneRuleItemKey(origin), name: oneRuleName(origin), place: Self.oneRulePlace(origin),
                                     path: origin, removedAt: cloudNowMs(), device: cloudDeviceId ?? "", content: live,
                                     shown: !cloudIdenticalInUse(at: archivedPath, bytes: live), now: cloudNowMs())
            guard try cloudHashFile(originURL) == headHash else { return .left }
            try db.run("INSERT OR IGNORE INTO cloud_memory_files(path,hash) VALUES (?,?)", [.text(origin), .text(headHash)])
            try fm.removeItem(at: originURL)
            _ = try reindexNow(paths: [origin])
        }
        // Decision 1: the app's own archive is a recorded move, so the first look after sending switched on may already
        // have queued this very move (old place -> this archived note). It travels once; the settling counts it as sent
        // instead of reporting "nothing" for a move that is on its way.
        if try db.first("SELECT 1 FROM cloud_memory_journal j JOIN \(try cloudRemovalsTable()) r ON r.hash=j.hash WHERE j.resource_key=? AND r.path=? AND r.moved_to=? LIMIT 1",
                        [.text(key), .text(origin), .text(archivedPath)]) != nil {
            try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(origin)])
            return .sent
        }
        // A move keeps its existing compatibility gate; it never uses the deletion witness.
        let result = try db.transaction { () throws -> CloudRemovalSend in
            let result = try cloudJournalRemoval(path: origin, lastHash: headHash, onlyMove: true, knownBytes: headBytes)
            if result == .sent || result == .nothing { try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(origin)]) }
            return result
        }
        return result == .sent ? .sent : .nothing
    }

    /// Review point 7: a removal marker an older build wrote into a file the notes index does not hold (a seat card, a
    /// playbook, a topic, an instruction file). One walk of the folder, reading only small files outside archive/.
    func cloudNonNoteMarkerExists() throws -> Bool {
        for path in try cloudScanSourceFiles().paths where !path.hasPrefix("archive/") {
            if let kind = DeckMemoryFiles.classify(path)?.kind, case .note = kind { continue }
            guard let url = try? DeckMemoryCloudSchema.safePath(path, root: root),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size < 16_384,
                  let data = try? Data(contentsOf: url) else { continue }
            if DeckMemoryRemoval.parse(data) != nil { return true }
        }
        return false
    }
    /// Removal markers an older build placed as the text of a file it did not understand (a note, a seat card, a
    /// topic, any memory file): the file leaves memory, its earlier text goes into the Bin from the copy this Mac holds
    /// of the marker's parent version. Nothing is sent: the removal is already the Cloud's newest version. One walk of
    /// the small files (a marker is under 16 KB and starts with its label block).
    private func cloudSettleStubs(limit: Int) throws -> Int {
        let fm = FileManager.default
        if cloudOneRuleList == nil {
            cloudOneRuleList = try cloudScanSourceFiles().paths.filter { path in
                guard !path.hasPrefix("archive/"), let url = try? DeckMemoryCloudSchema.safePath(path, root: root),
                      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size < 16_384,
                      let data = try? Data(contentsOf: url) else { return false }
                return DeckMemoryRemoval.parse(data) != nil
            }
        }
        var list = cloudOneRuleList ?? [], done = 0, forged: [String] = []
        while done < limit, let path = list.popLast() {
            guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root), let bytes = try? Data(contentsOf: file),
                  let removal = DeckMemoryRemoval.parse(bytes) else { continue }
            let hash = BackendCloudBrainMemoryHash.bytes(bytes)
            // Marker-shaped text written locally has no delete authority. Preserve its bytes and the last real
            // text, remove only the local forged stub, and mark its place. Never copy its claimed attribution.
            let fromCloud = try db.first("SELECT 1 FROM cloud_memory_versions WHERE content_hash=? LIMIT 1", [.text(hash)]) != nil
            if !fromCloud {
                try cloudKeepText(path: path, content: bytes, ref: nil, at: nil, device: cloudDeviceId)
                if let last = try db.first("SELECT hash FROM cloud_memory_files WHERE path=?", [.text(path)]) {
                    let origin = try db.first("SELECT store_id,resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(path)])
                    let store = try origin?.text(0) ?? cloudStoreId(), key = origin?.text(1) ?? "file/" + path
                    if let text = try cloudLastBytes(path: path, store: store, key: key, lastHash: last.string(0)) {
                        try cloudKeepText(path: path, content: text, ref: nil, at: nil, device: cloudDeviceId)
                    }
                }
                try cloudMarkMemoryAbsent(path, at: cloudNowMs())
                forged.append(path)
                done += 1
                continue
            }
            if let version = try db.first("SELECT store_id,parents FROM cloud_memory_versions WHERE content_hash=? LIMIT 1", [.text(hash)]),
               let parent = (try? JSONDecoder().decode([String].self, from: version.data(1) ?? Data()))?.first,
               let earlier = try db.first("SELECT store_id,content_hash FROM cloud_memory_versions WHERE revision=? LIMIT 1", [.text(parent)]),
               let text = cloudKnownBytes(hash: earlier.text(1), stores: [earlier.text(0), version.text(0), try cloudStoreId()]) {
                try cloudKeeper().binPut(kind: Self.oneRuleKind, itemKey: Self.oneRuleItemKey(path), name: oneRuleName(path), place: Self.oneRulePlace(path), path: path,
                                         removedAt: removal.at, device: removal.by, content: text,
                                         shown: !cloudIdenticalInUse(at: removal.movedTo, bytes: text), now: cloudNowMs())
            }
            try cloudNoteRemoval(hash: hash, path: path, at: removal.at, movedTo: removal.movedTo)
            try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(path)])
            guard try cloudHashFile(file) == hash else { continue }
            try fm.removeItem(at: file)
            _ = try reindexNow(paths: [path])
            try cloudCount("oneRule:settledMarkers")
            done += 1
        }
        cloudOneRuleList = list
        if list.isEmpty {
            cloudOneRuleList = nil
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('oneRule:stubs','done')")
        }
        // Only local stubs go; the mark blocks every capture and automatic arrival at these places.
        var gone: [String] = []
        for path in forged {
            guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root), let bytes = try? Data(contentsOf: file),
                  DeckMemoryRemoval.parse(bytes) != nil else { continue }
            try fm.removeItem(at: file)
            gone.append(path)
        }
        if !gone.isEmpty {
            try cloudCaptureChangedFiles(paths: gone)
            _ = try reindexNow(paths: gone)
        }
        return max(done, 1)
    }
}

/// Attribution beside the existing keeper, not another Bin. The keeper alone owns content and expiry.
private struct MemoryBinAttribution: Codable {
    let intent: CloudDeleteIntent
    let macName: String
    let sha: String
    let era: CloudBinEra
}
/// One removed text of one group (decision 8): which text the group's "Put back all" brings back, until when.
private struct MemoryBinMember: Codable {
    let attribution: MemoryBinAttribution
    let path: String
    let name: String
    let device: String
    let removedAt: Int64
    let keptUntil: Int64
}

/// What "Put back all" did, by name (decision 8): what came back and what did not. Pages show `line`.
public struct DeckMemoryPutBackGroupResult: Sendable, Equatable {
    public let back: [CloudDeleteItem]
    public let notBack: [CloudDeleteItem]
    public var line: String {
        var text = back.isEmpty ? "Nothing was put back." : "Put back " + back.map(\.name).joined(separator: ", ") + "."
        if !notBack.isEmpty {
            text += " Could not put back " + notBack.map(\.name).joined(separator: ", ") + "; " + (notBack.count == 1 ? "it stays" : "they stay") + " in the Bin."
        }
        return text
    }
}

extension DeckMemoryStore {
    static let deleteRuleSafetyKey = "deleteRule:safetyCopy"
    static let deleteRuleMigrationKey = "deleteRule:migrated"

    func cloudMemoryItem(_ path: String) -> CloudDeleteItem {
        .init(id: Self.oneRuleItemKey(path), kind: Self.oneRuleKind, name: oneRuleName(path), place: path)
    }
    func cloudMemoryPath(_ item: CloudDeleteItem) throws -> String {
        guard item.kind == Self.oneRuleKind else { throw CloudFailure.invalidRequest }
        let path = item.place ?? (item.id.hasPrefix("memory:") ? String(item.id.dropFirst(7)) : item.id)
        _ = try DeckMemoryCloudSchema.safePath(path, root: root)
        guard !path.hasPrefix("archive/versions/"), DeckMemoryCloudSchema.fileRow(path) != nil else { throw CloudFailure.invalidRequest }
        return path
    }
    /// The account publishes its device list; names are display facts, never routing ids shown as names.
    public func cloudDeleteSetDevices(_ devices: [CloudDevice]) throws {
        guard cloudMemoryEnabled, try cloudAttached() else { return }
        for device in devices {
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)",
                       [.text("deleteRule:macName:" + device.deviceId.lowercased()), .text(device.shownName)])
        }
    }
    func cloudMemoryMacName(_ id: String) -> String {
        (try? db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("deleteRule:macName:" + id.lowercased())]))?.string(0) ?? "Another Mac"
    }
    func cloudRememberBin(_ saved: BackendCloudVersionKeeper.Binned, intent: CloudDeleteIntent, era: CloudBinEra, macName: String? = nil) throws {
        let value = MemoryBinAttribution(intent: intent, macName: macName ?? cloudMemoryMacName(intent.mac), sha: saved.sha256, era: era)
        let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text("deleteRule:bin:" + saved.path), .text(text)])
        // Decision 8: the same place removed twice within 30 days keeps EACH removed text reachable for its own group.
        // Metadata only: the bytes stay in the one keeper (the earlier Bin text becomes a kept version of the item for
        // 30 days from the second removal, `binPut`), and this row stops counting after its own 30 days.
        let member = MemoryBinMember(attribution: value, path: saved.path, name: saved.name, device: saved.device,
                                     removedAt: saved.removedAt, keptUntil: saved.keptUntil)
        let groupId = Self.binGroupId(era: era, intent: intent, device: saved.device, removedAt: saved.removedAt)
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)",
                   [.text(Self.binMemberKey(group: groupId, path: saved.path)), .text(String(decoding: try JSONEncoder().encode(member), as: UTF8.self))])
    }
    static let binMemberPrefix = "deleteRule:binof:"
    static func binMemberKey(group: String, path: String) -> String { binMemberPrefix + group + "|" + path }
    /// (group, path) of a member key. A group never holds "|" (a uuid, or before:<mac>:<day>); a path may.
    static func binMemberParts(_ key: String) -> (group: String, path: String)? {
        guard key.hasPrefix(binMemberPrefix) else { return nil }
        let rest = key.dropFirst(binMemberPrefix.count)
        guard let bar = rest.firstIndex(of: "|") else { return nil }
        return (String(rest[..<bar]), String(rest[rest.index(after: bar)...]))
    }
    static func binMemberPath(_ key: String) -> String? { binMemberParts(key)?.path }
    /// The routing id of a Bin group (never shown): the intent's group, or one group per Mac and day before the rule.
    static func binGroupId(era: CloudBinEra?, intent: CloudDeleteIntent?, device: String, removedAt: Int64) -> String {
        let legacy = "before:" + binDeviceId(device) + ":" + DeckMemoryFiles.day(Date(timeIntervalSince1970: Double(removedAt) / 1000))
        return era == .beforeNewRule ? legacy : (intent?.group ?? legacy)
    }
    /// The place is in use here again with exactly this text (never Only on this Mac): that Bin text is back.
    func cloudMemoryPlaceHolds(_ path: String, sha: String) -> Bool {
        guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root), FileManager.default.fileExists(atPath: file.path),
              (try? cloudHashFile(file)) == sha else { return false }
        return (try? CloudDeleteState(memory: db).mark(at: path)?.mark) != .onlyOnThisMac
    }
    /// One group's record of one place (a refused delete leaves no stale Bin entry behind).
    func cloudForgetBinMember(group: String, path: String) throws {
        try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(Self.binMemberKey(group: group, path: path))])
    }
    private func cloudBinAttribution(_ saved: BackendCloudVersionKeeper.Binned) throws -> MemoryBinAttribution? {
        guard let text = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("deleteRule:bin:" + saved.path)])?.string(0),
              let value = try? JSONDecoder().decode(MemoryBinAttribution.self, from: Data(text.utf8)), value.sha == saved.sha256,
              value.intent.at == saved.removedAt else { return nil }
        return value
    }
    /// Rule 7 is silent: neither marks, placement nor witness calls when the root is absent or unreadable.
    func cloudMemoryRootAvailable() -> Bool {
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              fm.isReadableFile(atPath: root.path), (try? fm.contentsOfDirectory(atPath: root.path)) != nil else { return false }
        return true
    }
    func cloudMarkMemoryAbsent(_ path: String, at: Int64) throws {
        try CloudDeleteState(memory: db).putMark(.init(place: path, mark: .notOnThisMac, at: at))
        // Keep the last-seen row: absence is local state, never a removal revision.
    }
    /// Resolves a witnessed absence on the actor after the asynchronous witness returns. Every observation is checked
    /// again: a relaunch, account switch, rewrite or arriving version cannot turn stale evidence into a delete.
    func cloudResolveMemoryGone(path: String, lastHash: String?, lastSeen: Date, goneAt: Date, answer: CloudDeleteWitnessAnswer) throws {
        guard !closed, cloudMemoryEnabled, try cloudAttached(), cloudMemoryRootAvailable(),
              let file = try? DeckMemoryCloudSchema.safePath(path, root: root), !FileManager.default.fileExists(atPath: file.path),
              let row = try db.first("SELECT hash FROM cloud_memory_files WHERE path=?", [.text(path)]), row.string(0) == lastHash else { return }
        let state = try CloudDeleteState(memory: db)
        guard try state.mark(at: path) == nil else { return }
        if try state.intent(at: path) != nil {
            try cloudFinishMemoryIntent(path)
            return
        }
        let at = Int64(goneAt.timeIntervalSince1970 * 1000)
        switch answer {
        case .notAI, .cannotKnow:
            try cloudMarkMemoryAbsent(path, at: at)
        case .ai(let session, let agent, _, let group):
            guard UUID(uuidString: group) != nil else { try cloudMarkMemoryAbsent(path, at: at); return }
            let intent = CloudDeleteIntent(place: path, scope: .everywhere, by: .ai, mac: cloudDeviceId ?? "", session: session,
                                           agent: agent, at: at, group: group)
            try state.putIntent(intent)
            try cloudFinishMemoryIntent(path)
        }
        try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("deleteRule:gone:" + path)])
    }
    /// What finishing an intent did. `.done`: removed (or marked Only on this Mac); `.keptNewer`: refused before it was
    /// journaled, the intent is gone and the file is an ordinary file again (the caller captures it as usual);
    /// `.capturedNewer`: the removal was journaled but his newer text was captured on top of it.
    enum CloudIntentFinish { case done, keptNewer, capturedNewer, none }
    func cloudIntentJournaled(_ path: String, _ intent: CloudDeleteIntent) throws -> Bool {
        guard let raw = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("deleteRule:journaled:" + path)])?.string(0) else { return false }
        return (try? JSONDecoder().decode(CloudDeleteIntent.self, from: Data(raw.utf8))) == intent
    }
    /// Durable intent recovery also covers a crash after the marker was journaled but before unlinking the file.
    /// Lead's decision 3 (review must-fix 3): handled one file at a time and never by throwing the same error forever.
    /// - The file changed after its removal was queued: his newer text wins. Not journaled yet: the intent goes and the
    ///   file stays an ordinary file. Journaled: the edit is captured on top of the removal (Everywhere), or the file
    ///   stays here as Only on this Mac (Cloud scope: he removed it from the Cloud and keeps working on his own copy).
    /// - Any refusal before the removal is journaled clears the intent, so a later edit is never deleted "anyway"; a
    ///   file already gone then counts as gone by hand (a local mark; nothing travels).
    @discardableResult
    func cloudFinishMemoryIntent(_ path: String) throws -> CloudIntentFinish {
        let state = try CloudDeleteState(memory: db)
        guard let intent = try state.intent(at: path) else { return .none }
        let file = try DeckMemoryCloudSchema.safePath(path, root: root)
        let live = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        let keeper = try cloudKeeper(), item = Self.oneRuleItemKey(path)
        if let live, try cloudChangedSinceIntent(path, file: file, live: live, intent: intent, keeper: keeper) {
            return try cloudNewerTextWins(path, intent: intent, journaled: try cloudIntentJournaled(path, intent))
        }
        func refused() throws {
            try state.clearIntent(at: path)
            if live == nil, try state.mark(at: path) == nil { try cloudMarkMemoryAbsent(path, at: intent.at) }
            if live != nil { try cloudLeaveBin(path) }
            try cloudForgetBinMember(group: intent.group, path: path)
            CloudSyncDiagnostics.shared.info("memory: a delete could not be finished on this Mac, so nothing was removed on your other devices.")
        }
        let hash = try live.map(BackendCloudBrainMemoryHash.bytes)
            ?? (db.first("SELECT hash FROM cloud_memory_files WHERE path=?", [.text(path)]))?.string(0)
        do { _ = try cloudJournalRemoval(path: path, lastHash: hash, knownBytes: live) }
        catch {
            if try !cloudIntentJournaled(path, intent) { try refused() }
            throw error
        }
        guard try cloudIntentJournaled(path, intent) else {
            // `.nothing` without a receipt: an unmanaged or disabled place, or another store's placement here.
            try refused()
            return live == nil ? .done : .keptNewer
        }
        // Only a durable Bin copy licenses an unlink.
        guard let binned = try keeper.bin(itemKey: item) else {
            if live != nil { return try cloudNewerTextWins(path, intent: intent, journaled: true) }
            try state.clearIntent(at: path)
            return .done
        }
        if intent.scope == .cloud {
            if live != nil { try state.putMark(.init(place: path, mark: .onlyOnThisMac, at: intent.at)) }
        } else if let live {
            guard BackendCloudBrainMemoryHash.bytes(live) == binned.sha256, try cloudHashFile(file) == binned.sha256 else {
                return try cloudNewerTextWins(path, intent: intent, journaled: true)
            }
            try FileManager.default.removeItem(at: file)
            _ = try reindexNow(paths: [path])
        }
        try state.clearIntent(at: path)
        if intent.scope == .everywhere { try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(path)]) }
        hub.post(.init(area: .index, at: now()))
        return .done
    }
    /// The live file is not the text the delete was asked for. With the intent's own Bin copy: a different fingerprint.
    /// Without one (stopped between the intent and its copy): changed since the last capture AND written after the
    /// intent was made; otherwise it is the very text he asked to delete.
    private func cloudChangedSinceIntent(_ path: String, file: URL, live: Data, intent: CloudDeleteIntent, keeper: BackendCloudVersionKeeper) throws -> Bool {
        let fingerprint = BackendCloudBrainMemoryHash.bytes(live)
        if let binned = try keeper.bin(itemKey: Self.oneRuleItemKey(path)) { return binned.sha256 != fingerprint }
        if try db.first("SELECT hash FROM cloud_memory_files WHERE path=?", [.text(path)])?.string(0) == fingerprint { return false }
        let written = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970 * 1000) } ?? Int64.max
        return written > intent.at
    }
    /// His newer text at a place whose removal was queued (decision 3).
    private func cloudNewerTextWins(_ path: String, intent: CloudDeleteIntent, journaled: Bool) throws -> CloudIntentFinish {
        let state = try CloudDeleteState(memory: db)
        try state.clearIntent(at: path)
        try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("deleteRule:journaled:" + path)])
        // The text in use is back at its place: it is no Bin item (its Bin text stays a kept version for 30 days). A
        // Cloud-scope removal that was already sent keeps its Bin item: the place stays out of the Cloud.
        if !(journaled && intent.scope == .cloud) {
            try cloudLeaveBin(path)
            try cloudForgetBinMember(group: intent.group, path: path)
        }
        guard journaled else {
            CloudSyncDiagnostics.shared.info("memory: a delete that had not finished was dropped because the file changed after it; the newer text stays.")
            return .keptNewer
        }
        if intent.scope == .cloud {
            try state.putMark(.init(place: path, mark: .onlyOnThisMac, at: intent.at))
            return .done
        }
        // Everywhere was already queued: the edit goes to the Cloud on top of the removal, as a put back does.
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,'1')", [.text("deleteRule:returning:" + path)])
        try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(path)])
        try cloudCaptureFile(path, force: true)
        _ = try reindexNow(paths: [path])
        return .capturedNewer
    }
    func cloudRetryMemoryIntents() throws {
        guard cloudMemoryRootAvailable() else { return }
        _ = try CloudDeleteState(memory: db)
        let paths = try db.rows("SELECT place FROM cloud.cloud_delete_intents").map { $0.text(0) }
        // One file at a time: a file that cannot be finished never stops the others.
        for path in paths {
            do { try cloudFinishMemoryIntent(path) }
            catch { CloudSyncDiagnostics.shared.info("memory: a delete will be finished later on this Mac; nothing else waits for it.") }
        }
    }
}

extension DeckMemoryStore: CloudDeleteOwning {
    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        guard cloudMemoryEnabled, cloudStateRoot != nil, try cloudAttached(), cloudMemoryRootAvailable() else { throw CloudFailure.unavailable }
        guard UUID(uuidString: actor.group) != nil else { throw CloudFailure.invalidRequest }
        if scope == .cloud, !cloudDeleteRuleIsOpen() { throw DeckMemoryError(.invalid, CloudDeleteWords.cloudNeedsUpdatedMacs) }
        guard try cloudMigrateDeleteRule(), try cloudEnsureSafetyCopy(key: Self.deleteRuleSafetyKey) else { throw CloudFailure.unavailable }
        let paths = try items.map { try cloudMemoryPath($0) }
        for path in paths {
            guard let inventory = try cloudFileInventoryRow(path, database: db), cloudEnabledRows?.contains(inventory) != false else { throw CloudFailure.unavailable }
        }
        let state = try CloudDeleteState(memory: db)
        var deleted: [CloudDeleteItem] = []
        // One press/tool call carries one actor/group, even when it spans cards, notes, playbooks and topics.
        for path in Set(paths).sorted() {
            let file = try DeckMemoryCloudSchema.safePath(path, root: root)
            guard let bytes = try? Data(contentsOf: file), DeckMemoryRemoval.parse(bytes) == nil else { throw missing("That item is not in memory any more.") }
            let intent = actor.intent(place: path, scope: scope)
            try state.putIntent(intent)
            let outcome: CloudIntentFinish
            do {
                let fingerprint = BackendCloudBrainMemoryHash.bytes(bytes)
                let saved = try cloudKeeper().binPut(kind: Self.oneRuleKind, itemKey: Self.oneRuleItemKey(path), name: oneRuleName(path),
                                                   place: Self.oneRulePlace(path), path: path, removedAt: intent.at,
                                                   device: Self.binDevice(actor.mac, byAI: actor.by == .ai), content: bytes, shown: true, now: cloudNowMs())
                if case .known(let ref) = try cloudLocalSide(path: path, key: nil, current: fingerprint), let key = try cloudKeyOfVersion(ref) {
                    try cloudKeeper().setRevision(itemKey: saved.itemKey, sha256: saved.sha256, storeId: ref.storeId, resourceKey: key, revision: ref.version)
                }
                try cloudRememberBin(saved, intent: intent, era: .current, macName: actor.macName)
                try db.run("INSERT OR IGNORE INTO cloud_memory_files(path,hash) VALUES (?,?)", [.text(path), .text(fingerprint)])
                guard try cloudHashFile(file) == fingerprint else { throw CloudFailure.versionChanged }
                outcome = try cloudFinishMemoryIntent(path)
            } catch {
                // Decision 3: refused before the removal was journaled, so the intent goes; a later edit of this file is
                // never deleted "anyway" after he saw the error. The file stays; it is no Bin item.
                if try !cloudIntentJournaled(path, intent) {
                    try? state.clearIntent(at: path)
                    try? cloudForgetBinMember(group: intent.group, path: path)
                    if FileManager.default.fileExists(atPath: file.path) { try? cloudLeaveBin(path) }
                }
                throw error
            }
            // The file changed while it was being deleted: his newer text won and stays in use.
            guard outcome == .done else { continue }
            deleted.append(cloudMemoryItem(path))
        }
        return .init(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent, at: actor.at, items: deleted)
    }
    public func notHere() async throws -> [CloudNotHereItem] {
        guard cloudMemoryEnabled, try cloudAttached() else { return [] }
        let state = try CloudDeleteState(memory: db)
        var out: [CloudNotHereItem] = []
        for mark in try state.marks() {
            // Decision 10: removed everywhere from another device since: nothing is left to bring back, so the mark goes
            // and the page never shows a dead "Bring back".
            if mark.mark == .notOnThisMac, try cloudMemoryRemovedEverywhere(mark.place) {
                try state.clearMark(at: mark.place)
                continue
            }
            out.append(.init(item: cloudMemoryItem(mark.place), mark: mark.mark, at: mark.at))
        }
        return out
    }
    /// The Cloud's newest version of this place is an Everywhere removal this Mac understands (never a Cloud-scope one,
    /// never one in a form it does not know).
    func cloudMemoryRemovedEverywhere(_ path: String) throws -> Bool {
        guard let head = try cloudNewestMemoryHead(path), try cloudIsRemoval(hash: head.hash),
              let bytes = try cloudMemoryHeadBytes(head, path: path), let removal = DeckMemoryRemoval.parse(bytes),
              let travel = try? CloudDeleteTravel.read(removal.travel, place: path, mac: removal.by, at: removal.at) else { return false }
        if case .intent(let intent) = travel, intent.scope == .cloud { return false }
        return true
    }
    public func bringBack(_ items: [CloudDeleteItem], to destination: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        guard cloudMemoryEnabled, try cloudAttached(), cloudMemoryRootAvailable() else { throw CloudFailure.unavailable }
        let state = try CloudDeleteState(memory: db)
        var back: [CloudDeleteItem] = []
        for item in items {
            let path = try cloudMemoryPath(item)
            guard let mark = try state.mark(at: path) else { continue }
            if destination == .cloud {
                guard mark.mark == .onlyOnThisMac else { throw CloudFailure.invalidRequest }
                let bytes = try Data(contentsOf: DeckMemoryCloudSchema.safePath(path, root: root))
                guard DeckMemoryRemoval.parse(bytes) == nil else { throw CloudFailure.invalidRequest }
                if let head = try cloudNewestMemoryHead(path) { try cloudAdoptMemoryHead(head, path: path) }
                _ = try cloudWriteAsNewest(path: path, content: bytes)
                try cloudLeaveBin(path)
            } else {
                // Decision 10: removed everywhere since: nothing to bring back; the mark goes.
                if mark.mark == .notOnThisMac, try cloudMemoryRemovedEverywhere(path) { try state.clearMark(at: path); continue }
                guard mark.mark == .notOnThisMac, let head = try cloudNewestMemoryHead(path), let bytes = try cloudMemoryHeadBytes(head, path: path),
                      DeckMemoryRemoval.parse(bytes) == nil else { continue }
                try cloudInstallMemoryHead(head, path: path, bytes: bytes)
                try state.clearMark(at: path)
            }
            cloudForgetDeleted([path])
            back.append(cloudMemoryItem(path))
        }
        return back
    }
    public func binGroups() async throws -> [CloudBinGroup] { try cloudBinGroupsDetailed().map(\.group) }
    /// Every Bin group with the text (fingerprint) each of its items brings back. Decision 8: an item already back in
    /// use is never listed (its group rows go), and a place removed twice within 30 days is listed in BOTH groups,
    /// each with its own removed text, until that text's own 30 days are over.
    func cloudBinGroupsDetailed() throws -> [(group: CloudBinGroup, shas: [String: String])] {
        guard cloudStateRoot != nil, try cloudAttached() else { return [] }
        struct Member { let group: String; let by: CloudDeleteBy; let mac: String; let macName: String?; let session: String?; let agent: String?
                        let at: Int64; let path: String; let name: String; let sha: String; let era: CloudBinEra }
        let keeper = try cloudKeeper(), now = cloudNowMs()
        var members: [Member] = [], taken = Set<String>()
        for binned in try keeper.binList(kind: Self.oneRuleKind) {
            // Back in use with THIS text (a put back, an arrival, a file he put back by hand): not listed. A different
            // file at the place leaves the item in its group. Listing never changes anything.
            if cloudMemoryPlaceHolds(binned.path, sha: binned.sha256) { continue }
            let metadata = try cloudBinAttribution(binned)
            let id = Self.binGroupId(era: metadata?.era ?? .beforeNewRule, intent: metadata?.intent, device: binned.device, removedAt: binned.removedAt)
            taken.insert(id + "|" + binned.path)
            members.append(.init(group: id, by: metadata?.intent.by ?? (Self.binByAI(binned.device) ? .ai : .person), mac: Self.binDeviceId(binned.device),
                                 macName: metadata?.macName, session: metadata?.intent.session, agent: metadata?.intent.agent, at: binned.removedAt,
                                 path: binned.path, name: binned.name, sha: binned.sha256, era: metadata?.era ?? .beforeNewRule))
        }
        // Earlier removals of a place removed again since: still reachable for their own group (the keeper holds the text).
        for row in try db.rows("SELECT key,value FROM cloud_memory_control WHERE substr(key,1,?)=?", [.int(Int64(Self.binMemberPrefix.count)), .text(Self.binMemberPrefix)]) {
            guard let parts = Self.binMemberParts(row.text(0)), !taken.contains(parts.group + "|" + parts.path) else { continue }
            guard let raw = row.string(1), let member = try? JSONDecoder().decode(MemoryBinMember.self, from: Data(raw.utf8)),
                  member.keptUntil > now, keeper.content(kind: Self.oneRuleKind, sha256: member.attribution.sha) != nil else { continue }
            if cloudMemoryPlaceHolds(parts.path, sha: member.attribution.sha) { continue }
            let intent = member.attribution.intent
            members.append(.init(group: parts.group, by: intent.by, mac: Self.binDeviceId(member.device), macName: member.attribution.macName,
                                 session: intent.session, agent: intent.agent, at: member.removedAt, path: member.path, name: member.name,
                                 sha: member.attribution.sha, era: member.attribution.era))
        }
        var groups: [String: (group: CloudBinGroup, shas: [String: String])] = [:]
        for m in members {
            let previous = groups[m.group]
            let name = cloudMemoryMacName(m.mac)
            let group = CloudBinGroup(id: m.group, by: m.by, macName: name == "Another Mac" ? (m.macName ?? name) : name, session: m.session,
                                      agent: m.agent, at: max(previous?.group.at ?? 0, m.at),
                                      items: (previous?.group.items ?? []) + [.init(id: Self.oneRuleItemKey(m.path), kind: Self.oneRuleKind, name: m.name, place: m.path)],
                                      era: m.era)
            var shas = previous?.shas ?? [:]
            shas[m.path] = m.sha
            groups[m.group] = (group, shas)
        }
        return groups.values.sorted { $0.group.at == $1.group.at ? $0.group.id < $1.group.id : $0.group.at > $1.group.at }
    }
    /// "Put back all", person UI only. Continues past an item that fails; when anything did not come back the error
    /// names what came back and what did not (`memoryPutBackGroup` gives both lists).
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] {
        let result = try await memoryPutBackGroup(group)
        if !result.notBack.isEmpty { throw DeckMemoryError(.invalid, result.line) }
        return result.back
    }
    /// Decision 8: the owner's ONLY recovery from a large AI delete. Every item of the group is tried; each one brings
    /// back the text removed in THIS group (also when the same place was removed again later).
    public func memoryPutBackGroup(_ group: String) async throws -> DeckMemoryPutBackGroupResult {
        guard let found = try cloudBinGroupsDetailed().first(where: { $0.group.id == group }) else { return .init(back: [], notBack: []) }
        var back: [CloudDeleteItem] = [], notBack: [CloudDeleteItem] = []
        for item in found.group.items {
            do {
                let path = try cloudMemoryPath(item)
                let keeper = try cloudKeeper(), key = Self.oneRuleItemKey(path)
                let wanted = found.shas[path]
                if let binned = try keeper.bin(itemKey: key), wanted == nil || binned.sha256 == wanted {
                    _ = try await memoryPutBack(path: path)
                } else if let wanted, let content = keeper.content(kind: Self.oneRuleKind, sha256: wanted) {
                    // A later removal of the same place keeps its own Bin item (a different text): only this group's text comes back.
                    _ = try cloudWriteAsNewest(path: path, content: content)
                } else {
                    throw missing("That item is not in the Bin any more.")
                }
                try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(Self.binMemberKey(group: group, path: path))])
                back.append(item)
            } catch {
                notBack.append(item)
            }
        }
        if !notBack.isEmpty { CloudSyncDiagnostics.shared.info("memory: put back all brought back \(back.count) and could not bring back \(notBack.count).") }
        return .init(back: back, notBack: notBack)
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        let keeper = try cloudKeeper(), database = try keeper.database()
        // Person-UI only. Delete just the selected Bin rows; a kept version with the same bytes retains its own date.
        for item in items {
            let path = try cloudMemoryPath(item), key = Self.oneRuleItemKey(path)
            guard let binned = try keeper.bin(itemKey: key) else { continue }
            try database.run("DELETE FROM bin WHERE item_key=? AND kind=?", [.text(key), .text(Self.oneRuleKind)])
            if try database.first("SELECT 1 FROM versions WHERE kind=? AND sha256=?", [.text(binned.kind), .text(binned.sha256)]) == nil,
               try database.first("SELECT 1 FROM bin WHERE kind=? AND sha256=?", [.text(binned.kind), .text(binned.sha256)]) == nil {
                try FileManager.default.removeItem(at: keeper.contentURL(kind: binned.kind, sha256: binned.sha256))
            }
            try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text("deleteRule:bin:" + path)])
            for row in try db.rows("SELECT key,value FROM cloud_memory_control WHERE substr(key,1,?)=?", [.int(Int64(Self.binMemberPrefix.count)), .text(Self.binMemberPrefix)])
            where Self.binMemberPath(row.text(0)) == path {
                let member = row.string(1).flatMap { try? JSONDecoder().decode(MemoryBinMember.self, from: Data($0.utf8)) }
                if member == nil || member?.attribution.sha == binned.sha256 { try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(row.text(0))]) }
            }
        }
    }
}

extension DeckMemoryStore {
    /// Lead's decision 5 (review must-fix 5): a removal queued by an older build counts as intended ONLY when this Mac's
    /// id is known and its Bin holds an entry for that place, removed by this Mac, with the SAME text fingerprint as the
    /// text last seen there and a date not before that text was last captured. Everything else becomes a local mark:
    /// never a removal he did not make (a newer note written at an old note's place and deleted by hand stays local).
    func cloudMigrationProvesIntent(_ path: String, keeper: BackendCloudVersionKeeper, me: String) throws -> BackendCloudVersionKeeper.Binned? {
        guard !me.isEmpty, UUID(uuidString: me) != nil,
              let saved = try keeper.bin(itemKey: Self.oneRuleItemKey(path)), saved.shown, Self.binDeviceId(saved.device) == me,
              let seen = try db.first("SELECT hash,mtime FROM cloud_memory_files WHERE path=?", [.text(path)]),
              seen.string(0) == saved.sha256, !seen.isNull(1) else { return nil }
        let capturedAt = Int64((seen.double(1) ?? 0) * 1000)   // not null: checked above
        return saved.removedAt >= capturedAt ? saved : nil
    }
    /// E1–5: one switch-over per Mac/account, after a fresh safety copy. It never removes a live file.
    @discardableResult
    func cloudMigrateDeleteRule() throws -> Bool {
        guard cloudMemoryEnabled, try cloudAttached(), cloudMemoryRootAvailable() else { return false }
        if try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(Self.deleteRuleMigrationKey)])?.text(0) == "done" { return true }
        guard try cloudEnsureSafetyCopy(key: Self.deleteRuleSafetyKey) else { return false }
        let state = try CloudDeleteState(memory: db), keeper = try cloudKeeper(), me = cloudDeviceId ?? ""
        var intended = 0, queuedMarks = 0, heldKept = 0, goneMarks = 0
        var recapture: [String] = []
        let bins = try keeper.binAll(kind: Self.oneRuleKind).count
        try db.transaction {
            for row in try db.rows("SELECT path,hash FROM cloud_memory_files") { try cloudMemoryRememberHash(row.text(1), path: row.text(0)) }
            for row in try db.rows("SELECT store_id,resource_key,content_hash FROM cloud_memory_versions WHERE resource_key LIKE 'file/%' UNION SELECT store_id,resource_key,content_hash FROM cloud_memory_parts WHERE resource_key LIKE 'file/%' UNION SELECT store_id,resource_key,projected_hash FROM cloud_memory_versions WHERE resource_key LIKE 'file/%' AND projected_hash IS NOT NULL") {
                if let path = try cloudPlacementPath(String(row.text(1).dropFirst(5)), origin: row.text(0)) { try cloudMemoryRememberHash(row.text(2), path: path) }
            }
            // These legacy keys are read only here and dropped. They never run a queue or a brake again.
            let queuedPrefix = "oneRule:queued:"
            for row in try db.rows("SELECT key FROM cloud_memory_control WHERE key LIKE 'oneRule:queued:%'") {
                let path = String(row.text(0).dropFirst(queuedPrefix.count))
                guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root), !FileManager.default.fileExists(atPath: file.path) else { continue }
                if let saved = try cloudMigrationProvesIntent(path, keeper: keeper, me: me) {
                    let intent = CloudDeleteIntent(place: path, scope: .everywhere, by: Self.binByAI(saved.device) ? .ai : .person,
                                                   mac: me, at: saved.removedAt, group: BackendCloudBrainMemoryHash.uuid("migrated:" + me + ":" + String(saved.removedAt / 86_400_000)))
                    try state.putIntent(intent)
                    try cloudRememberBin(saved, intent: intent, era: .beforeNewRule)
                    try cloudFinishMemoryIntent(path)
                    intended += 1
                } else {
                    try cloudMarkMemoryAbsent(path, at: cloudNowMs())
                    queuedMarks += 1
                }
            }
            let held = "cloud_memory_held_removals"
            if try db.first("SELECT 1 FROM cloud.sqlite_master WHERE type='table' AND name=?", [.text(held)]) != nil {
                for row in try db.rows("SELECT store_id,resource_key,revision,path FROM cloud.\(held)") {
                    let path = row.text(3)
                    guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root), let bytes = try? Data(contentsOf: file), DeckMemoryRemoval.parse(bytes) == nil else { continue }
                    if let p = try cloudStoredPart(storeId: row.text(0), key: row.text(1), version: row.text(2)) {
                        if let removal = DeckMemoryRemoval.parse(try Data(contentsOf: cloudAssemble(p))) {
                            try cloudNoteRemoval(hash: p.resourceHash, path: path, at: removal.at, movedTo: removal.movedTo)
                        }
                        try db.run("INSERT INTO cloud_memory_file_origins(path,store_id,resource_key,version) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET store_id=excluded.store_id,resource_key=excluded.resource_key,version=excluded.version",
                                   [.text(path), .text(p.storeId), .text(p.key), .text(p.version)])
                        try cloudWriteImportHead(p)
                        _ = try cloudKeepVersionForOneRule(p)
                    }
                    try state.clearMark(at: path)
                    try db.run("DELETE FROM cloud_memory_files WHERE path=?", [.text(path)])
                    recapture.append(path)
                    heldKept += 1
                }
                try db.exec("DROP TABLE cloud.\(held)")
            }
            for row in try db.rows("SELECT path FROM cloud_memory_files") {
                let path = row.text(0)
                guard let file = try? DeckMemoryCloudSchema.safePath(path, root: root), !FileManager.default.fileExists(atPath: file.path),
                      try state.mark(at: path) == nil, try state.intent(at: path) == nil, try !cloudConvertMarked(path) else { continue }
                if let saved = try cloudMigrationProvesIntent(path, keeper: keeper, me: me) {
                    // Old switch-off deletes had no queued:path key, only removalsWaiting plus this Mac's Remove copy.
                    let intent = CloudDeleteIntent(place: path, scope: .everywhere, by: Self.binByAI(saved.device) ? .ai : .person, mac: me,
                                                   at: saved.removedAt, group: BackendCloudBrainMemoryHash.uuid("migrated:" + me + ":" + String(saved.removedAt / 86_400_000)))
                    try state.putIntent(intent)
                    try cloudRememberBin(saved, intent: intent, era: .beforeNewRule)
                    try cloudFinishMemoryIntent(path)
                    intended += 1
                } else {
                    try cloudMarkMemoryAbsent(path, at: cloudNowMs())
                    goneMarks += 1
                }
            }
            try db.run("DELETE FROM cloud_memory_control WHERE key LIKE 'oneRule:queued:%' OR key IN ('oneRule:massMissing','oneRule:removalsWaiting','oneRule:sentWindowAt','oneRule:sentWindowCount','oneRule:appliedWindowAt','oneRule:appliedWindowCount')")
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,'done')", [.text(Self.deleteRuleMigrationKey)])
        }
        CloudSyncDiagnostics.shared.info("memory delete rule: safety copy made; queued intended \(intended); queued local marks \(queuedMarks); held files kept \(heldKept); earlier Bin items \(bins); gone local marks \(goneMarks). No live file was deleted by migration.")
        // A failed capture is retried by the normal dirty-file pass; there is never a reason to delete his kept text.
        if !recapture.isEmpty {
            try cloudMarkFilesDirty()
            try cloudCaptureChangedFiles(force: true, paths: recapture)
        }
        return true
    }
}
