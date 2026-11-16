import Foundation
import TerminalDeckNativeCore

/// The one rule (owner, 14 Nov: "the newest used everywhere"): when a newer version replaces an older one, the older
/// one is kept on this Mac for 30 days. Its full content plus what it was (which item, when, which Mac) lives here:
/// `<dataRoot>/cloud/<subjectHash>/archive/versions/versions.sqlite`, the content in `<kind>/<sha256>` beside it, one
/// copy per content. Costs no Cloud writes. Contracts file CLOUD-CONTRACTS-1114 section 2.
///
/// Instruction files (first slice) and memory files with their Bin (lane memory-one-rule). Saved passwords are a later
/// slice. Each owner actor (boot files, the memory store) holds its own connection; SQLite's lock (5 s wait) orders them.
final class BackendCloudVersionKeeper {
    /// One kept version. `itemKey` and `sha256` are never shown; `name`, `place`, `device` and the dates are.
    struct Kept: Sendable, Equatable {
        let itemKey: String
        let kind: String
        let name: String
        let place: String?
        let at: Int64
        /// The Mac that made this version (device id; the page turns it into a name).
        let device: String
        let bytes: Int64
        let sha256: String
        let keptUntil: Int64
    }

    static let instructionFiles = BackendCloudContents.Kind.instructionFiles.rawValue
    static let schema = """
        CREATE TABLE IF NOT EXISTS versions(item_key TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL, place TEXT, at INTEGER NOT NULL,
            device TEXT NOT NULL, bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, kept_until INTEGER NOT NULL, PRIMARY KEY(item_key, sha256));
        CREATE INDEX IF NOT EXISTS versions_until ON versions(kept_until);
        CREATE INDEX IF NOT EXISTS versions_content ON versions(kind, sha256);
        CREATE TABLE IF NOT EXISTS bin(item_key TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, place TEXT, path TEXT NOT NULL,
            removed_at INTEGER NOT NULL, device TEXT NOT NULL, bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, kept_until INTEGER NOT NULL, shown INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS bin_until ON bin(kept_until);
        CREATE TABLE IF NOT EXISTS revisions(item_key TEXT NOT NULL, sha256 TEXT NOT NULL, store_id TEXT NOT NULL, resource_key TEXT NOT NULL,
            revision TEXT NOT NULL, PRIMARY KEY(item_key, sha256));
        """

    let root: URL
    private var opened: BackendCloudBrainFilesDatabase?
    init(root: URL) { self.root = root }

    /// `archive/versions` beside a signed-in identity's other Cloud folders (`<identity>/boot-files` → `<identity>/archive/versions`).
    static func root(besideStateRoot stateRoot: URL) -> URL {
        stateRoot.deletingLastPathComponent().appendingPathComponent("archive", isDirectory: true).appendingPathComponent("versions", isDirectory: true)
    }

    func database() throws -> BackendCloudBrainFilesDatabase {
        if let opened { return opened }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try BackendCloudBrainFilesDatabase(path: root.appendingPathComponent("versions.sqlite").path, engineTables: false)
        try db.exec(Self.schema)
        opened = db
        return db
    }

    static func isSha(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    func contentURL(kind: String, sha256: String) -> URL {
        root.appendingPathComponent(kind, isDirectory: true).appendingPathComponent(sha256)
    }

    /// Keeps `content` (once per content) and indexes it until `at`'s keeping time runs out. Keeping the same content
    /// for the same item again only moves its date forward. Returns the date it is kept until.
    @discardableResult
    func keep(kind: String, itemKey: String, name: String, place: String?, at: Int64, device: String, content: Data, now: Int64) throws -> Int64 {
        let sha = BackendCloudBrainMemoryHash.bytes(content)
        try store(kind: kind, sha256: sha, content: content)
        let until = now + CloudBootFilesRules.keptFor
        try database().run("""
            INSERT INTO versions(item_key,kind,name,place,at,device,bytes,sha256,kept_until) VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(item_key,sha256) DO UPDATE SET kept_until=MAX(kept_until,excluded.kept_until)
            """, [.text(itemKey), .text(kind), .text(name), .optional(place), .int(at), .text(device), .int(Int64(content.count)), .text(sha), .int(until)])
        return until
    }

    /// The content file alone, checked by fingerprint; written to a temporary name and renamed into place.
    func store(kind: String, sha256: String, content: Data) throws {
        guard Self.isSha(sha256) else { throw CloudFailure.invalidRequest }
        let target = contentURL(kind: kind, sha256: sha256)
        if let held = try? Data(contentsOf: target), BackendCloudBrainMemoryHash.bytes(held) == sha256 { return }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: target, options: .atomic)
        try BackendCloudBrainMemoryHash.synchronize(target)
        // The copy is on disk and readable before any caller removes the original (memory-one-rule review, item 7).
        guard let back = try? Data(contentsOf: target), BackendCloudBrainMemoryHash.bytes(back) == sha256 else { throw CloudFailure.checksumMismatch }
    }

    /// The kept bytes, or nil when gone or no longer matching their fingerprint.
    func content(kind: String, sha256: String) -> Data? {
        guard Self.isSha(sha256), let held = try? Data(contentsOf: contentURL(kind: kind, sha256: sha256)),
              BackendCloudBrainMemoryHash.bytes(held) == sha256 else { return nil }
        return held
    }

    static func kept(_ row: DeckMemoryRow) -> Kept {
        Kept(itemKey: row.text(0), kind: row.text(1), name: row.text(2), place: row.string(3), at: row.int(4), device: row.text(5), bytes: row.int(6),
             sha256: row.text(7), keptUntil: row.int(8))
    }
    static let columns = "item_key,kind,name,place,at,device,bytes,sha256,kept_until"

    /// What is kept for one item, newest first.
    func versions(itemKey: String) throws -> [Kept] {
        try database().rows("SELECT \(Self.columns) FROM versions WHERE item_key=? ORDER BY at DESC, sha256", [.text(itemKey)]).map(Self.kept)
    }
    func version(itemKey: String, sha256: String) throws -> Kept? {
        try database().first("SELECT \(Self.columns) FROM versions WHERE item_key=? AND sha256=?", [.text(itemKey), .text(sha256)]).map(Self.kept)
    }

    /// The 30-day keeper: removes every version AND every Bin item kept until `before` or earlier, and each content
    /// nothing names any more. Returns how many versions and Bin items were removed.
    @discardableResult
    func sweep(before: Int64) throws -> Int {
        try sweepVersions(kind: nil, keptUntilBefore: before) + sweepBin(kind: nil, keptUntilBefore: before)
    }
    /// Kept versions only (`kind` nil = every kind). "Clean up now" passes the cleanup time + `keptFor`.
    @discardableResult
    func sweepVersions(kind: String?, keptUntilBefore before: Int64) throws -> Int {
        let db = try database()
        let filter = kind == nil ? "" : " AND kind=?"
        let args: [DeckMemorySQL] = [.int(before)] + (kind.map { [DeckMemorySQL.text($0)] } ?? [])
        let gone = try db.rows("SELECT item_key, kind, sha256 FROM versions WHERE kept_until<=?" + filter, args)
        try db.run("DELETE FROM versions WHERE kept_until<=?" + filter, args)
        for row in gone { try db.run("DELETE FROM revisions WHERE item_key=? AND sha256=?", [.text(row.text(0)), .text(row.text(2))]) }
        try dropUnnamedContent(gone.map { ($0.text(1), $0.text(2)) })
        return gone.count
    }
    /// Bin items only. "Empty bin" passes the cleanup time + `keptFor`.
    @discardableResult
    func sweepBin(kind: String?, keptUntilBefore before: Int64) throws -> Int {
        let db = try database()
        let filter = kind == nil ? "" : " AND kind=?"
        let args: [DeckMemorySQL] = [.int(before)] + (kind.map { [DeckMemorySQL.text($0)] } ?? [])
        let gone = try db.rows("SELECT item_key, kind, sha256 FROM bin WHERE kept_until<=?" + filter, args)
        try db.run("DELETE FROM bin WHERE kept_until<=?" + filter, args)
        try dropUnnamedContent(gone.map { ($0.text(1), $0.text(2)) })
        return gone.count
    }
    /// Lane L3 review (Cloud folder, cost): only the newest kept version of one item stays (the ONE 30-day version he
    /// can open); the others and their content (when nothing else names it) go. Used by the Cloud folder only.
    func keepNewestOnly(itemKey: String) throws {
        let db = try database()
        let all = try db.rows("SELECT kind, sha256 FROM versions WHERE item_key=? ORDER BY kept_until DESC, at DESC, sha256", [.text(itemKey)])
        guard all.count > 1 else { return }
        let gone = all.dropFirst().map { ($0.text(0), $0.text(1)) }
        for (_, sha) in gone {
            try db.run("DELETE FROM versions WHERE item_key=? AND sha256=?", [.text(itemKey), .text(sha)])
            try db.run("DELETE FROM revisions WHERE item_key=? AND sha256=?", [.text(itemKey), .text(sha)])
        }
        try dropUnnamedContent(Array(gone))
    }
    /// A content file goes only when neither a kept version nor a Bin item names it.
    private func dropUnnamedContent(_ pairs: [(String, String)]) throws {
        let db = try database()
        var seen = Set<String>()
        for (kind, sha) in pairs where seen.insert(kind + "/" + sha).inserted {
            guard try db.first("SELECT 1 FROM versions WHERE kind=? AND sha256=?", [.text(kind), .text(sha)]) == nil,
                  try db.first("SELECT 1 FROM bin WHERE kind=? AND sha256=?", [.text(kind), .text(sha)]) == nil else { continue }
            try? FileManager.default.removeItem(at: contentURL(kind: kind, sha256: sha))
        }
    }

    // MARK: Memory (slice 2 of the one rule): the Bin and the Cloud revision a kept text was

    struct Binned: Sendable, Equatable {
        let itemKey: String
        let kind: String
        let name: String
        let place: String?
        /// Where the item lived (relative to its folder). Never shown as a path; the page shows `name` and `place`.
        let path: String
        let removedAt: Int64
        let device: String
        let bytes: Int64
        let sha256: String
        let keptUntil: Int64
        /// false: a MOVE (archive, rename) whose old place is kept 30 days for safety; not listed in the Bin.
        let shown: Bool
    }
    static let binColumns = "item_key,kind,name,place,path,removed_at,device,bytes,sha256,kept_until,shown"
    static func binned(_ row: DeckMemoryRow) -> Binned {
        Binned(itemKey: row.text(0), kind: row.text(1), name: row.text(2), place: row.string(3), path: row.text(4), removedAt: row.int(5),
               device: row.text(6), bytes: row.int(7), sha256: row.text(8), keptUntil: row.int(9), shown: row.int(10) != 0)
    }
    /// Puts content in the Bin for 30 days from NOW (when this Mac put it there; `removedAt` is only shown). The same item removed again replaces its entry (the
    /// earlier content stays as a kept version of the item, so nothing goes before its own 30 days).
    @discardableResult
    func binPut(kind: String, itemKey: String, name: String, place: String?, path: String, removedAt: Int64, device: String, content: Data,
                shown: Bool, now: Int64) throws -> Binned {
        let sha = BackendCloudBrainMemoryHash.bytes(content)
        try store(kind: kind, sha256: sha, content: content)
        if let earlier = try bin(itemKey: itemKey), earlier.sha256 != sha, let held = self.content(kind: kind, sha256: earlier.sha256) {
            try keep(kind: kind, itemKey: itemKey, name: earlier.name, place: earlier.place, at: earlier.removedAt, device: earlier.device, content: held, now: now)
        }
        let until = now + CloudBootFilesRules.keptFor
        try database().run("""
            INSERT INTO bin(item_key,kind,name,place,path,removed_at,device,bytes,sha256,kept_until,shown) VALUES (?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(item_key) DO UPDATE SET name=excluded.name,place=excluded.place,path=excluded.path,removed_at=excluded.removed_at,
            device=excluded.device,bytes=excluded.bytes,sha256=excluded.sha256,kept_until=MAX(bin.kept_until,excluded.kept_until),shown=MAX(bin.shown,excluded.shown)
            """, [.text(itemKey), .text(kind), .text(name), .optional(place), .text(path), .int(removedAt), .text(device), .int(Int64(content.count)),
                  .text(sha), .int(until), .int(shown ? 1 : 0)])
        return try bin(itemKey: itemKey)!
    }
    func bin(itemKey: String) throws -> Binned? {
        try database().first("SELECT \(Self.binColumns) FROM bin WHERE item_key=?", [.text(itemKey)]).map(Self.binned)
    }
    /// The Bin as he sees it: removals only (moves are kept but not listed), newest first.
    func binList(kind: String) throws -> [Binned] {
        try database().rows("SELECT \(Self.binColumns) FROM bin WHERE kind=? AND shown=1 ORDER BY removed_at DESC, item_key", [.text(kind)]).map(Self.binned)
    }
    /// Takes an item out of the Bin (it was put back, or a newer edit brought it back). Its content stays as a kept
    /// version for its 30 days, so "put back" can never lose the text it replaces.
    func binTake(itemKey: String, now: Int64) throws {
        guard let item = try bin(itemKey: itemKey) else { return }
        if let held = content(kind: item.kind, sha256: item.sha256) {
            try keep(kind: item.kind, itemKey: itemKey, name: item.name, place: item.place, at: item.removedAt, device: item.device, content: held, now: now)
        }
        try database().run("DELETE FROM bin WHERE item_key=?", [.text(itemKey)])
    }
    /// The Cloud revision a kept text was (memory): lets "is A newer than B" use revision order, never file dates.
    func setRevision(itemKey: String, sha256: String, storeId: String, resourceKey: String, revision: String) throws {
        try database().run("INSERT OR REPLACE INTO revisions(item_key,sha256,store_id,resource_key,revision) VALUES (?,?,?,?,?)",
                           [.text(itemKey), .text(sha256), .text(storeId), .text(resourceKey), .text(revision)])
    }
    func revision(itemKey: String, sha256: String) throws -> (storeId: String, resourceKey: String, revision: String)? {
        guard let row = try database().first("SELECT store_id,resource_key,revision FROM revisions WHERE item_key=? AND sha256=?", [.text(itemKey), .text(sha256)]) else { return nil }
        return (row.text(0), row.text(1), row.text(2))
    }
    /// Every Bin item of one kind, listed or not (put back everything).
    func binAll(kind: String) throws -> [Binned] {
        try database().rows("SELECT \(Self.binColumns) FROM bin WHERE kind=? ORDER BY removed_at DESC, item_key", [.text(kind)]).map(Self.binned)
    }
    /// Every kept version of one kind (tests, and the count of what "Clean up now" would remove).
    func versions(kind: String) throws -> [Kept] {
        try database().rows("SELECT \(Self.columns) FROM versions WHERE kind=? ORDER BY at DESC, sha256", [.text(kind)]).map(Self.kept)
    }
}

/// The one line that tells him a newer version from another device replaced this Mac's (contracts section 2). Names and
/// dates only: never an id, a fingerprint or a path.
public struct CloudVersionReplacedLine: Sendable, Equatable {
    /// The other Mac's name.
    public let device: String
    /// The file's name ("CLAUDE.md", or "<skill> skill" for a skill's SKILL.md).
    public let name: String
    /// The project's name; nil for an AI account's own settings folder.
    public let project: String?
    /// When this Mac's version stops being kept (ms).
    public let keptUntil: Int64
    /// The line's own id on the page. Never shown.
    public let itemId: String
    public init(device: String, name: String, project: String?, keptUntil: Int64, itemId: String) {
        self.device = device; self.name = name; self.project = project; self.keptUntil = keptUntil; self.itemId = itemId
    }

    /// "14 Dec".
    public static func day(_ ms: Int64, timeZone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "d MMM"
        return format.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// "Mac mini's newer CLAUDE.md (iMatch) is in use; this Mac's version is kept until 14 Dec · Show"
    public func text(timeZone: TimeZone = .current) -> String {
        let place = project.map { " (" + $0 + ")" } ?? ""
        return device + "'s newer " + name + place + " is in use; this Mac's version is kept until " + Self.day(keptUntil, timeZone: timeZone) + " · Show"
    }
    /// The same without the trailing "· Show", for a page that draws Show as a button.
    public func sentence(timeZone: TimeZone = .current) -> String {
        let full = text(timeZone: timeZone)
        return full.hasSuffix(" · Show") ? String(full.dropLast(7)) : full
    }

    /// A file's shown name from its path inside its folder: the last part, or "<folder> skill" for a skill's SKILL.md.
    public static func fileName(_ relative: String) -> String {
        let parts = relative.split(separator: "/").map(String.init)
        guard let last = parts.last else { return relative }
        if last.lowercased() == "skill.md", parts.count >= 2 { return parts[parts.count - 2] + " skill" }
        return last
    }
}
