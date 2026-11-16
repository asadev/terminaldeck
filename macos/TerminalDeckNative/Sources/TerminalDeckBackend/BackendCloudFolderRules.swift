import Foundation
import Darwin
import TerminalDeckNativeCore

/// Lane L3, the Cloud folder (owner, 14 Nov: "local first with a Cloud folder"): a normal folder on each device
/// (`~/Terminal Deck Cloud`) that he and his AIs use at local speed; what is in it is on his other Macs too.
/// One record per file (the file engine's records, row I24, domain `cloud-folder`).
public enum CloudFolderFormat {
    public static let inventoryRow = "I24"
    public static var domain: String { CloudBrainFilesFormat.domain(inventoryRow) }
    public static let folderName = "Terminal Deck Cloud"
    /// The folder on this Mac: `~/Terminal Deck Cloud`.
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(folderName, isDirectory: true)
    }
    /// The largest file that travels. The service carries any size (a file goes as 32 KB parts inside uploads of at most
    /// 12 MiB), but today every version of every file counts for ever against the account's 10 GB (nothing is freed by a
    /// removal yet) and the service's free storage is 10 GB for ALL accounts together. PLAN section H: "drop first: files
    /// over 25 MB". A larger file stays on this Mac and the Cloud page says so in one line.
    public static let maximumFileBytes: Int64 = 25_000_000
    /// The folder as a whole: past 1 GB, new and changed files stay on this Mac (one line), nothing is removed.
    /// Review 14 Nov (cost): 1 GB, not 2 (the account's 10 GB is counted for life).
    public static let maximumFolderBytes: Int64 = 1_000_000_000
    /// Review 14 Nov (cost): the most this Mac sends of the Cloud folder in one day (Sync now does not pass it).
    public static let dailySendBytes: Int64 = 200_000_000
    /// Review 14 Nov (cost): at most 6 versions of one file a day; after that it waits until it has been still an hour.
    public static let versionsPerDay = 6
    public static let stillAfterLimit: Int64 = 3_600_000
    /// Review 14 Nov (cost): below 3 GB of room left in the account (the service's own answer) the folder sends nothing;
    /// memory and everything else keep travelling.
    public static let roomFloor: Int64 = 3_000_000_000
    /// Review 14 Nov (cost): below 2 GB free on this Mac no arrival is written or kept; it waits.
    public static let diskFloor: Int64 = 2_000_000_000
    /// The safety copy and the opened copies go after 30 days.
    public static let safetyKeptFor: Int64 = 30 * 86_400_000
    static let day: Int64 = 86_400_000
    public static let maximumFiles = 20_000
    public static let maximumDepth = 32
    /// A changed file is sent once it stayed the same for 3 s (an editor that writes in steps sends ONE version).
    public static let quiet: Int64 = 3_000
    /// A file that keeps changing (an AI rewriting it every second) is sent at most once a minute, and after three
    /// sends in a row at most once every 10 minutes, until it stays still for 10 minutes. Sync now sends it at once.
    public static let busyGap: Int64 = 60_000
    public static let busyLongGap: Int64 = 600_000
    public static let busyStreak = 3
    /// "This Mac understands Cloud folder records" (`DeckMemoryStore.cloudFeatureAnnounce`).
    public static let feature = "cloudfolder"
    public static let format = 1
    /// The line he reads for a file above the limit.
    public static func tooLargeLine(_ count: Int) -> String {
        count == 1 ? "1 file larger than 25 MB stays on this Mac (the Cloud folder carries files up to 25 MB)."
                   : "\(count) files larger than 25 MB stay on this Mac (the Cloud folder carries files up to 25 MB)."
    }
    /// Lane L3: every AI session is told where his Cloud folder is (only when it exists on this Mac), so AIs read and
    /// write it directly at local speed. Empty otherwise (and in tests, whose home has no such folder).
    public static func sessionLine(folder: URL = defaultFolder()) -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return "" }
        return "\n\nThe person's Cloud folder is " + folder.path + ": whatever is in it is on all their devices. Read and write files there " +
            "directly when they ask for something to be on all their devices (files up to 25 MB travel; hidden files, links, package folders " +
            "and key or sign-in files stay on this Mac). Never delete files there unless the person asked."
    }
    public static let folderFullLine = "Your Cloud folder holds more than 1 GB. New and changed files stay on this Mac until it is smaller."
    /// Lane L3 slice 2: the 200 MB a day is shared with artifacts, so the one line names both.
    public static let dayFullLine = "Your Cloud folder and artifacts sent 200 MB from this Mac today, the most for one day. Changed files wait until tomorrow."
    public static func busyLine(_ count: Int) -> String {
        count == 1 ? "1 file in your Cloud folder changed more than 6 times today. It is sent once it has been still for an hour."
                   : "\(count) files in your Cloud folder changed more than 6 times today. Each is sent once it has been still for an hour."
    }
    public static let roomLowLine = "Your Cloud account has less than 3 GB of room left, so your Cloud folder sends nothing more. Memory and everything else keep travelling."
    public static let diskLowLine = "This Mac has less than 2 GB free, so files from your other devices wait until there is more room."
    /// Names said on the page: at most three, then "and N more".
    static func names(_ list: [String]) -> String {
        let sorted = Array(Set(list)).sorted()
        let shown = sorted.prefix(3).joined(separator: ", ")
        return sorted.count > 3 ? shown + " and \(sorted.count - 3) more" : shown
    }
    public static func secretLine(_ names: [String]) -> String {
        (names.count == 1 ? "1 file stays on this Mac because its name is on the never-send list for keys, environment and sign-in files: "
                          : "\(names.count) files stay on this Mac because their names are on the never-send list for keys, environment and sign-in files: ")
            + Self.names(names) + "."
    }
    public static func spellingLine(_ names: [String]) -> String {
        (names.count == 1 ? "1 file stays on this Mac because its name is spelled with separate accent marks: "
                          : "\(names.count) files stay on this Mac because their names are spelled with separate accent marks: ")
            + Self.names(names) + ". Renaming it lets it travel."
    }
    public static func clashLine(_ names: [String]) -> String {
        (names.count == 1 ? "1 file stays apart because its name is a file on one Mac and a folder on another: "
                          : "\(names.count) files stay apart because their names are a file on one Mac and a folder on another: ")
            + Self.names(names) + "."
    }
    public static func gateLine(_ macs: [String]) -> String {
        "Your Cloud folder sends nothing yet: " + BackendCloudContentsWords.list(Array(Set(macs)).sorted())
            + (macs.count == 1 ? " has" : " have") + " not updated Terminal Deck or " + (macs.count == 1 ? "has" : "have") + " Cloud off."
    }
    /// Review 14 Nov (point 9): "plan (from MacBook Pro).md", then "plan (from MacBook Pro) 2.md".
    static func besideName(_ name: String, mac: String, number: Int) -> String {
        let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
        let safe = mac.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return stem + " (from " + safe + ")" + (number > 1 ? " \(number)" : "") + (ext.isEmpty ? "" : "." + ext)
    }
    /// What is left out on purpose, named (shown with coverage; never a gap).
    public static let exclusions = [
        "Hidden files, temporary files and links stay on this Mac.",
        "Keys, environment files and sign-in files never travel.",
        "Folders of installed packages and build output (node_modules, .build, DerivedData) stay on this Mac."
    ]
}

/// What never leaves this Mac from the Cloud folder, and why. Asked again for every path, in both directions: a record
/// that arrives for a refused path is kept unread and never written.
public enum CloudFolderSkip: String, Sendable, CaseIterable {
    case hidden, temporary, link, rebuildable, secret, tooLarge, name, notAFile
}

public enum CloudFolderRules {
    /// Package and build folders: rebuilt on each device, never carried.
    public static let rebuildableFolders: Set<String> = ["node_modules", ".build", "deriveddata", "__pycache__", "venv", ".venv", "pods", ".gradle"]
    static let temporaryEndings = ["~", ".tmp", ".temp", ".swp", ".swo", ".swx", ".part", ".partial", ".crdownload", ".download", ".icloud"]
    static let temporaryPrefixes = ["~$", ".~lock", "._", ".td-cloud-"]

    /// The app's own never-send list (the one Cloud uses for instruction files: keys, environment and sign-in files,
    /// by name; `CloudBootFilesRules.neverTravels`). Over-matching is the safe direction.
    public static func isSecret(_ name: String) -> Bool { CloudBootFilesRules.neverTravels(name) }

    /// nil when the file at `relative` (inside the Cloud folder) may travel. Sizes are checked by the walk.
    public static func refusal(_ relative: String) -> CloudFolderSkip? {
        guard CloudBootFilesRules.cleanRelative(relative), let parts = CloudBootFilesRules.parts(relative), parts.count <= CloudFolderFormat.maximumDepth else { return .name }
        for (index, name) in parts.enumerated() {
            let lower = name.lowercased()
            let last = index == parts.count - 1
            if !last, rebuildableFolders.contains(lower) { return .rebuildable }
            if temporaryPrefixes.contains(where: { lower.hasPrefix($0) }) { return .temporary }
            if name.utf8.first == UInt8(ascii: ".") { return .hidden }
            if last {
                if temporaryEndings.contains(where: { lower.hasSuffix($0) }) { return .temporary }
                if isSecret(lower) { return .secret }
            }
        }
        return nil
    }
}

/// One look at the Cloud folder: every file that may travel with its size and time, never following a link, and what
/// was left out by reason. `reliable` false = something could not be read: no removal is ever inferred from such a
/// look. `present` false = the folder itself is not there (a disk not connected, a restore): nothing is inferred.
struct CloudFolderWalk: Sendable {
    struct Entry: Sendable, Equatable { let bytes: Int64; let modified: Int64 }
    var files: [String: Entry] = [:]
    var skipped: [CloudFolderSkip: Int] = [:]
    /// Review 14 Nov (point 8): the files kept back by name, said on the page (never-send list; separate accent marks).
    var secretNames: [String] = []
    var spellingNames: [String] = []
    /// Paths that exist on disk but do not travel (so their absence from `files` is never a removal).
    var excludedPaths: Set<String> = []
    var bytes: Int64 = 0
    var present = true
    var reliable = true

    static func run(_ root: URL) -> CloudFolderWalk {
        var walk = CloudFolderWalk()
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { walk.present = false; walk.reliable = false; return walk }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        final class Problems: @unchecked Sendable { var count = 0 }
        let problems = Problems()
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in problems.count += 1; return true }) else {
            walk.reliable = false; return walk
        }
        let base = root.standardizedFileURL.path
        for case let url as URL in e {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { problems.count += 1; continue }
            let relative = String(path.dropFirst(base.count + 1))
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { problems.count += 1; continue }
            if values.isSymbolicLink == true {
                walk.skipped[.link, default: 0] += 1; walk.excludedPaths.insert(relative); continue
            }
            if values.isDirectory == true {
                let name = url.lastPathComponent.lowercased()
                if CloudFolderRules.rebuildableFolders.contains(name) { walk.skipped[.rebuildable, default: 0] += 1; e.skipDescendants(); walk.excludedPaths.insert(relative); continue }
                if name.hasPrefix(".") { walk.skipped[.hidden, default: 0] += 1; e.skipDescendants(); walk.excludedPaths.insert(relative); continue }
                continue
            }
            guard values.isRegularFile == true else { walk.skipped[.notAFile, default: 0] += 1; walk.excludedPaths.insert(relative); continue }
            if let why = CloudFolderRules.refusal(relative) {
                walk.skipped[why, default: 0] += 1; walk.excludedPaths.insert(relative)
                if why == .secret { walk.secretNames.append(url.lastPathComponent) }
                if why == .name, !relative.utf8.elementsEqual(relative.precomposedStringWithCanonicalMapping.utf8) {
                    walk.spellingNames.append(url.lastPathComponent.precomposedStringWithCanonicalMapping)
                }
                continue
            }
            let size = Int64(values.fileSize ?? 0)
            if size > CloudFolderFormat.maximumFileBytes { walk.skipped[.tooLarge, default: 0] += 1; walk.excludedPaths.insert(relative); continue }
            let modified = Int64(((values.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000).rounded(.down))
            walk.files[relative] = Entry(bytes: size, modified: modified)
            walk.bytes += size
            if walk.files.count > CloudFolderFormat.maximumFiles { walk.reliable = false; break }
        }
        if problems.count > 0 { walk.reliable = false }
        return walk
    }
}

/// Reading and writing one file of the folder (or of this Mac's private copy) safely: never through a link, never over
/// bytes that changed since they were read.
enum CloudFolderDisk {
    enum Read: Equatable { case absent, file(Data), blocked }
    /// Review 14 Nov (point 1): every folder on the way from `root` down to `relative`'s file, checked with `lstat`, one
    /// at a time from the root: each must be a real folder (never a link, never a file). `make`: a missing folder is
    /// made (one at a time, never through a link) and checked again. A link or a file
    /// on the way (`unsafe`); `missing` when a folder is not there and `make` is false.
    enum Parents { case ready, missing, unsafe }
    static func parents(_ root: URL, _ relative: String, make: Bool) -> Parents {
        guard let parts = CloudBootFilesRules.parts(relative), !parts.isEmpty else { return .unsafe }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return .unsafe }
        var at = root
        for name in parts.dropLast() {
            guard !name.isEmpty, name != ".", name != ".." else { return .unsafe }
            at = at.appendingPathComponent(name, isDirectory: true)
            if lstat(at.path, &info) != 0 {
                guard errno == ENOENT else { return .unsafe }
                guard make else { return .missing }
                if mkdir(at.path, 0o755) != 0, errno != EEXIST { return .unsafe }
                guard lstat(at.path, &info) == 0 else { return .unsafe }
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { return .unsafe }
        }
        return .ready
    }
    /// Review 14 Nov (point 9): the name on disk differs from `relative` only by capitals (`Plan.md` is there, `plan.md`
    /// is asked for). The disk treats them as one file; the Cloud folder never does.
    static func caseClash(_ root: URL, _ relative: String) -> Bool {
        guard let parts = CloudBootFilesRules.parts(relative) else { return false }
        var at = root
        for name in parts {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: at.path) else { return false }
            if names.contains(where: { $0.utf8.elementsEqual(name.utf8) }) { at = at.appendingPathComponent(name); continue }
            return names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        return false
    }
    /// Review 14 Nov (point 8): the path is a folder here, or one of its folders is a file here.
    static func fileFolderClash(_ root: URL, _ relative: String) -> Bool {
        var info = stat()
        if lstat(root.appendingPathComponent(relative).path, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
        return errno == ENOTDIR
    }
    /// Size and time of one file, read without following a link. nil when it is not a plain file.
    struct Stamp: Equatable { let bytes: Int64; let modified: Int64 }
    static func stamp(_ root: URL, _ relative: String) -> Stamp? {
        var info = stat()
        guard lstat(root.appendingPathComponent(relative).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Stamp(bytes: Int64(info.st_size), modified: Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000)
    }
    static func read(_ root: URL, _ relative: String) -> Read {
        let url = root.appendingPathComponent(relative)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { return .blocked }
            // Absent only when nothing on the way is a link or a file (a linked folder must never read as "write here").
            switch parents(root, relative, make: false) {
            case .ready, .missing: return .absent
            case .unsafe: return .blocked
            }
        }
        guard info.st_mode & S_IFMT == S_IFREG else { return .blocked }
        // No link anywhere on the way: the resolved parent must be the root's own resolved path plus the same names.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let expected = root.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(relative).deletingLastPathComponent().path
        guard parent == expected || parent + "/" == expected else { return .blocked }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return .blocked }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd() else { return .blocked }
        return .file(data)
    }
    static func modified(_ root: URL, _ relative: String) -> Int64? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(relative).path))?[.modificationDate] as? Date else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }
    static func setModified(_ root: URL, _ relative: String, _ at: Int64) {
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(at) / 1000)], ofItemAtPath: root.appendingPathComponent(relative).path)
    }
    /// Writes `bytes` at `relative`: a new file only when none is there (`expecting` nil), else only over exactly the
    /// bytes with fingerprint `expecting`. Temporary file beside it, then rename. Throws `versionChanged` otherwise.
    static func write(_ root: URL, _ relative: String, bytes: Data, expecting: String?) throws {
        let target = root.appendingPathComponent(relative)
        let folder = target.deletingLastPathComponent()
        // Review 14 Nov (point 1): never `createDirectory(withIntermediateDirectories:)`, which follows a linked folder.
        guard parents(root, relative, make: true) == .ready else { throw CloudFailure.unsafeConfiguration }
        let temporary = folder.appendingPathComponent(".td-cloud-" + UUID().uuidString)
        try bytes.write(to: temporary, options: .withoutOverwriting)
        defer { unlink(temporary.path) }
        try BackendCloudBrainMemoryHash.synchronize(temporary)
        switch read(root, relative) {
        case .absent:
            guard expecting == nil else { throw CloudFailure.versionChanged }
            if link(temporary.path, target.path) != 0 { throw CloudFailure.versionChanged }
        case .file(let held):
            guard let expecting, BackendCloudBrainMemoryHash.bytes(held) == expecting else { throw CloudFailure.versionChanged }
            if rename(temporary.path, target.path) != 0 { throw CloudFailure.unavailable }
        case .blocked:
            throw CloudFailure.unsafeConfiguration
        }
        try? BackendCloudBrainMemoryHash.synchronizeDirectory(folder)
    }
    /// Removes the file at `relative` only when it still holds exactly the bytes with fingerprint `expecting`. Empty
    /// folders it leaves behind inside `root` go too (never `root` itself).
    static func remove(_ root: URL, _ relative: String, expecting: String) throws {
        guard parents(root, relative, make: false) == .ready else { throw CloudFailure.unsafeConfiguration }
        guard case .file(let held) = read(root, relative), BackendCloudBrainMemoryHash.bytes(held) == expecting else { throw CloudFailure.versionChanged }
        let target = root.appendingPathComponent(relative)
        guard unlink(target.path) == 0 else { throw CloudFailure.unavailable }
        var folder = target.deletingLastPathComponent()
        let top = root.standardizedFileURL.path
        while folder.standardizedFileURL.path.hasPrefix(top + "/"), rmdir(folder.path) == 0 { folder = folder.deletingLastPathComponent() }
    }
}

public enum BackendCloudFolderWords {
    public static func waitingAnswer(_ answer: CloudFolderAnswer, from: String?) -> String? {
        answer.folderMissing ? "Your Cloud folder is not on this Mac" : nil
    }
    public static let makeItAgain = "Make it again"
}

/// Metadata around the existing file engine, never another engine or Bin. Old builds reject extra marker keys.
/// Sidecars precede their markers in the SAME ordered domain queue; they remain usable across pack boundaries.
/// Review 15 Nov (MUST 4): every removal has its OWN about-record (`about/<group>/<removal op id>`, its own entity), so a
/// record the sync core sets aside never makes the rest of a press wait behind it.
enum CloudFileDeleteRecords {
    struct About: Codable, Sendable, Equatable {
        let operation: String
        let place: String
        let mac: String
        let at: Int64
        let fields: [String: String]
        var travel: CloudDeleteTravelRemoval {
            get throws { try CloudDeleteTravel.read(fields, place: place, mac: mac, at: at) }
        }
    }
    struct Head: Codable, Sendable {
        let place: String
        let version: String
        let parents: [String]
        let at: Int64
        let mac: String
        let fields: [String: String]
        var travel: CloudDeleteTravelRemoval {
            get throws { try CloudDeleteTravel.read(fields, place: place, mac: mac, at: at) }
        }
    }
    /// The sync core's own terms for an about-record this Mac cannot take (review 15 Nov, MUST 3): a refusal of that one
    /// record, so the pack goes on. Its removal is applied the safe way (the file is kept).
    static let aboutRefusal = "Refused: a delete note this Mac cannot read (from a newer or damaged version). Its file is kept here."
    static let aboutSignerRefusal = "Refused: a delete note that speaks for another Mac. Its file is kept here."
    static func create(in db: BackendCloudBrainFilesDatabase) throws {
        try db.exec("""
        CREATE TABLE IF NOT EXISTS file_delete_about(operation TEXT PRIMARY KEY, body BLOB NOT NULL, signer TEXT NOT NULL DEFAULT '');
        CREATE TABLE IF NOT EXISTS file_delete_refused(id TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS file_delete_heads(place TEXT PRIMARY KEY, body BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS file_delete_bin(place TEXT PRIMARY KEY, body BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS file_delete_binned(place TEXT PRIMARY KEY, hash TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS file_delete_applying(place TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS file_delete_sending(place TEXT PRIMARY KEY, body BLOB NOT NULL, after_seq INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS file_delete_withdrawn(operation TEXT PRIMARY KEY, place TEXT NOT NULL, parents TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS file_delete_row_errors(place TEXT PRIMARY KEY, line TEXT NOT NULL, at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS file_delete_cleared(place TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS file_delete_undo(place TEXT PRIMARY KEY, scope TEXT NOT NULL, restore INTEGER NOT NULL);
        """)
        _ = try CloudDeleteState(files: db)
    }
    static func isAbout(_ operation: CloudOperation) -> Bool { operation.source.recordId.hasPrefix("about/") }
    /// The line a page shows on one row whose delete did not happen (names the row; the page reads `rowErrors()`).
    static let notRemovedLine = "This could not be removed. It is kept on every Mac."
    static func setRowError(_ place: String, _ line: String?, at: Int64, in db: BackendCloudBrainFilesDatabase) throws {
        if let line { try db.run("INSERT OR REPLACE INTO file_delete_row_errors(place,line,at) VALUES (?,?,?)", [.text(place), .text(line), .int(at)]) }
        else { try db.run("DELETE FROM file_delete_row_errors WHERE place=?", [.text(place)]) }
    }
    static func rowErrors(in db: BackendCloudBrainFilesDatabase) throws -> [String: String] {
        Dictionary(try db.rows("SELECT place,line FROM file_delete_row_errors").map { ($0.text(0), $0.text(1)) }, uniquingKeysWith: { first, _ in first })
    }
    /// Review 15 Nov, decision 6 as changed: with the gate CLOSED at send time a "Cloud" removal is withdrawn, never
    /// held (the queue never waits). Its removal is not sent; the owner puts the file back in sync at its next look.
    /// Final look 15 Nov (MUST 1): a place whose "Only on this Mac" mark a look cleared because the file was gone. A file
    /// that comes back there with bytes the place held before gets the mark back (his choice stands, nothing is sent);
    /// bytes never seen there are his new file. Forgotten when he or another Mac acts on the place.
    static func rememberCleared(_ place: String, in db: BackendCloudBrainFilesDatabase) throws {
        try db.run("INSERT OR REPLACE INTO file_delete_cleared(place) VALUES (?)", [.text(place)])
    }
    static func forgetCleared(_ place: String, in db: BackendCloudBrainFilesDatabase) throws {
        try db.run("DELETE FROM file_delete_cleared WHERE place=?", [.text(place)])
    }
    static func wasCleared(_ place: String, in db: BackendCloudBrainFilesDatabase) throws -> Bool {
        try db.first("SELECT 1 FROM file_delete_cleared WHERE place=?", [.text(place)]) != nil
    }
    /// An undo in progress (final look, point 2): its markers are cleared last, so a failure half-way is retried.
    static func undoPending(_ place: String, in db: BackendCloudBrainFilesDatabase) throws -> (scope: CloudDeleteScope, restore: Bool)? {
        guard let row = try db.first("SELECT scope,restore FROM file_delete_undo WHERE place=?", [.text(place)]),
              let scope = CloudDeleteScope(rawValue: row.text(0)) else { return nil }
        return (scope, row.int(1) == 1)
    }
    static func isWithdrawn(_ operation: CloudOperation, in db: BackendCloudBrainFilesDatabase) throws -> Bool {
        try db.first("SELECT 1 FROM file_delete_withdrawn WHERE operation=?", [.text(operation.opId)]) != nil
    }
    static func withdraw(_ operation: CloudOperation, place: String, parents: [String], in db: BackendCloudBrainFilesDatabase) throws {
        try db.run("INSERT OR IGNORE INTO file_delete_withdrawn(operation,place,parents) VALUES (?,?,?)",
                   [.text(operation.opId), .text(place), .text(BackendCloudBrainFiles.json(parents))])
    }
    static func aboutKey(group: String, removal: String) -> String { "about/" + group + "/" + removal }
    /// The one id an about-record for this removal can have.
    static func aboutId(for removal: String) -> String { BackendCloudBrainMemoryHash.operationId("delete-about\n" + removal) }
    static func operation(_ removal: CloudOperation, intent: CloudDeleteIntent) throws -> CloudOperation {
        var fields: [String: String] = [:]
        CloudDeleteTravel.write(intent, into: &fields)
        let about = About(operation: removal.opId, place: intent.place, mac: intent.mac, at: intent.at, fields: fields)
        let payload = CloudValue(try NativeRPCValue.parseJSON(JSONEncoder().encode(about)))
        let id = aboutId(for: removal.opId)
        let key = aboutKey(group: intent.group, removal: removal.opId)
        return CloudOperation(v: 1, opId: id, originDevice: removal.originDevice, domain: removal.domain,
            entityId: BackendCloudBrainMemoryHash.uuid(key), revision: id, parents: [], kind: .put,
            projectId: removal.projectId, rootId: removal.rootId,
            source: .init(sourceId: removal.source.sourceId, recordId: key), createdAt: removal.createdAt,
            payload: payload, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(payload)))
    }
    /// Any damaged, newer-format or misaddressed about-record is a `CloudRecordRefusal` of that one record.
    static func read(_ operation: CloudOperation) throws -> About {
        do { return try readStrict(operation) }
        catch { throw CloudRecordRefusal(operationIds: [operation.opId], reason: aboutRefusal) }
    }
    private static func readStrict(_ operation: CloudOperation) throws -> About {
        let bytes = try CloudWire.canonical(operation.payload)
        guard bytes.count <= 65_536 else { throw CloudDeleteRuleError.invalidTravelFields }
        let about = try JSONDecoder().decode(About.self, from: bytes)
        guard operation.v == 1, operation.kind == .put,
              BackendCloudBrainMemoryHash.bytes(bytes) == operation.payloadHash,
              UUID(uuidString: about.operation) != nil, operation.opId == aboutId(for: about.operation),
              about.mac.lowercased() == operation.originDevice.lowercased(),
              case .intent(let intent) = try about.travel,
              operation.revision == operation.opId, operation.parents.isEmpty,
              operation.source.recordId == aboutKey(group: intent.group, removal: about.operation),
              operation.entityId == BackendCloudBrainMemoryHash.uuid(aboutKey(group: intent.group, removal: about.operation))
        else { throw CloudDeleteRuleError.invalidTravelFields }
        return about
    }
    /// An about-record this Mac refused (its removal is then applied the safe way). Content refusals only.
    static func noteRefused(_ operation: CloudOperation, in db: BackendCloudBrainFilesDatabase) {
        _ = try? db.run("INSERT OR IGNORE INTO file_delete_refused(id) VALUES (?)", [.text(operation.opId)])
    }
    /// Review 15 Nov (MUST 5): `signer` is the VERIFIED signer of the pack (`CloudImportOrigin.deviceId`), never a field
    /// inside the record. An about-record may speak only for its signer.
    static func saveAbout(_ operation: CloudOperation, signer: String, in db: BackendCloudBrainFilesDatabase) throws {
        let about = try read(operation), bytes = try JSONEncoder().encode(about)
        guard about.mac.lowercased() == signer.lowercased() else {
            noteRefused(operation, in: db)
            throw CloudRecordRefusal(operationIds: [operation.opId], reason: aboutSignerRefusal)
        }
        if let old = try db.first("SELECT body FROM file_delete_about WHERE operation=?", [.text(about.operation)])?.data(0) {
            guard (try? JSONDecoder().decode(About.self, from: old)) == about else {
                noteRefused(operation, in: db)
                throw CloudRecordRefusal(operationIds: [operation.opId], reason: aboutRefusal)
            }
        }
        try db.run("INSERT OR REPLACE INTO file_delete_about(operation,body,signer) VALUES (?,?,?)",
                   [.text(about.operation), .blob(bytes), .text(signer.lowercased())])
    }
    /// Every about-record of an arriving pack, saved with its verified signer BEFORE any removal of the pack is read.
    /// The sender enqueues each about-record immediately before its removal in the same ordered queue, and the feed
    /// applies packs in order (one by one in pack order when a pack is split), so when a removal is read here its
    /// about-record has either been saved (same pack: this step; earlier pack: before) or refused. A late about-record
    /// cannot exist; a missing one is treated the safe way.
    static func takeAbouts(_ operations: [CloudOperation], signer: String, domain: String, in db: BackendCloudBrainFilesDatabase) throws {
        for operation in operations where isAbout(operation) {
            guard operation.domain == domain else {
                noteRefused(operation, in: db)
                throw CloudRecordRefusal(operationIds: [operation.opId], reason: aboutRefusal)
            }
            try saveAbout(operation, signer: signer, in: db)
        }
    }
    /// This Mac's own about-record for one of its journaled removals (sender side).
    static func intent(for operation: CloudOperation, place: String, in db: BackendCloudBrainFilesDatabase) throws -> CloudDeleteIntent? {
        guard let bytes = try db.first("SELECT body FROM file_delete_about WHERE operation=?", [.text(operation.opId)])?.data(0) else { return nil }
        let about = try JSONDecoder().decode(About.self, from: bytes)
        guard about.place == place, about.mac.lowercased() == operation.originDevice.lowercased(),
              case .intent(let intent) = try about.travel else { throw CloudDeleteRuleError.invalidTravelFields }
        return intent
    }
    /// Review 15 Nov (MUST 4): how an ARRIVING removal is applied here. Everywhere only with its own valid about-record from
    /// the same verified signer at the same place. A removal whose about-record is missing, refused or unreadable is
    /// applied the SAFE way (the file is kept and marked "Only on this Mac"), unless its signer has never announced the
    /// delete rule (an older build), whose removals are the old-format Everywhere.
    static func arrivedRemoval(_ operation: CloudOperation, place: String, signer: String, announced: Bool,
                               in db: BackendCloudBrainFilesDatabase) -> CloudDeleteTravelRemoval {
        let safe = CloudDeleteTravelRemoval.intent(safeIntent(operation, place: place, signer: signer))
        do {
            if let row = try db.first("SELECT body,signer FROM file_delete_about WHERE operation=?", [.text(operation.opId)]) {
                guard let bytes = row.data(0), let about = try? JSONDecoder().decode(About.self, from: bytes),
                      row.text(1) == signer.lowercased(), about.mac.lowercased() == signer.lowercased(), about.place == place,
                      case .intent(let intent)? = try? about.travel else { return safe }
                return .intent(intent)
            }
            if try db.first("SELECT 1 FROM file_delete_refused WHERE id=?", [.text(aboutId(for: operation.opId))]) != nil { return safe }
        } catch { return safe }
        return announced ? safe : .olderVersion
    }
    /// The Bin label of a removal applied the safe way: one group per Mac and day, as a person's removal on that Mac.
    static func safeIntent(_ operation: CloudOperation, place: String, signer: String) -> CloudDeleteIntent {
        .init(place: place, scope: .cloud, by: .person, mac: signer.lowercased(), at: operation.createdAt,
              group: BackendCloudBrainMemoryHash.uuid("delete-safe\n" + signer.lowercased() + "\n" + String(operation.createdAt / CloudFolderFormat.day)))
    }
    static func saveHead(in db: BackendCloudBrainFilesDatabase, place: String, version: String, parents: [String], at: Int64,
                         mac: String, travel: CloudDeleteTravelRemoval) throws {
        var fields: [String: String] = [:]
        if case .intent(let intent) = travel { CloudDeleteTravel.write(intent, into: &fields) }
        let head = Head(place: place, version: version, parents: parents, at: at, mac: mac, fields: fields)
        try db.run("INSERT OR REPLACE INTO file_delete_heads(place,body) VALUES (?,?)", [.text(place), .blob(try JSONEncoder().encode(head))])
    }
    /// Each saved removal on its own (review 15 Nov, MUST 2): one that cannot be read is dropped with one log line.
    static func heads(in db: BackendCloudBrainFilesDatabase, label: String) throws -> [Head] {
        var heads: [Head] = []
        for row in try db.rows("SELECT place,body FROM file_delete_heads") {
            if let head = try? JSONDecoder().decode(Head.self, from: row.data(1) ?? Data()) { heads.append(head); continue }
            try db.run("DELETE FROM file_delete_heads WHERE place=?", [.text(row.text(0))])
            CloudSyncDiagnostics.shared.info(label + " delete rule: an unreadable arrived removal was dropped; its file is kept")
        }
        return heads
    }
    static func head(place: String, in db: BackendCloudBrainFilesDatabase) throws -> Head? {
        guard let bytes = try db.first("SELECT body FROM file_delete_heads WHERE place=?", [.text(place)])?.data(0) else { return nil }
        return try? JSONDecoder().decode(Head.self, from: bytes)
    }
    static func dropHead(place: String, in db: BackendCloudBrainFilesDatabase) throws {
        try db.run("DELETE FROM file_delete_heads WHERE place=?", [.text(place)])
        try db.run("DELETE FROM file_delete_applying WHERE place=?", [.text(place)])
    }
    /// Past the Bin step of this Mac's own removal: the bytes that went into the Bin (MUST 1).
    static func binned(place: String, in db: BackendCloudBrainFilesDatabase) throws -> String? {
        try db.first("SELECT hash FROM file_delete_binned WHERE place=?", [.text(place)])?.string(0)
    }
    static func rememberBin(_ group: CloudBinGroup, place: String, in db: BackendCloudBrainFilesDatabase) throws {
        try db.run("INSERT OR REPLACE INTO file_delete_bin(place,body) VALUES (?,?)", [.text(place), .blob(try JSONEncoder().encode(group))])
    }
    static func group(place: String, in db: BackendCloudBrainFilesDatabase) throws -> CloudBinGroup? {
        guard let bytes = try db.first("SELECT body FROM file_delete_bin WHERE place=?", [.text(place)])?.data(0) else { return nil }
        return try JSONDecoder().decode(CloudBinGroup.self, from: bytes)
    }
    static func merge(_ groups: [CloudBinGroup]) -> [CloudBinGroup] {
        Dictionary(grouping: groups, by: \.id).values.compactMap { rows in
            guard let first = rows.first else { return nil }
            return CloudBinGroup(id: first.id, by: first.by, macName: first.macName, session: first.session, agent: first.agent,
                at: first.at, items: rows.flatMap(\.items), era: first.era)
        }.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
    }
    static func legacyGroupId(mac: String, at: Int64, era: CloudBinEra) -> String {
        BackendCloudBrainMemoryHash.uuid(era.rawValue + "\n" + mac + "\n" + String(at / CloudFolderFormat.day))
    }
    static func legacyGroup(item: CloudDeleteItem, mac: String, macName: String, at: Int64, era: CloudBinEra) -> CloudBinGroup {
        .init(id: legacyGroupId(mac: mac, at: at, era: era), by: .person, macName: macName, at: at, items: [item], era: era)
    }
    /// This is a person-only operation on the SAME keeper. Shared blobs stay while any version or Bin entry needs them.
    static func deleteForGood(_ keeper: BackendCloudVersionKeeper, itemKey: String) throws {
        guard let item = try keeper.bin(itemKey: itemKey) else { return }
        let db = try keeper.database()
        try db.run("DELETE FROM bin WHERE item_key=?", [.text(itemKey)])
        let needed = try db.first("SELECT 1 FROM bin WHERE kind=? AND sha256=? UNION ALL SELECT 1 FROM versions WHERE kind=? AND sha256=? LIMIT 1",
            [.text(item.kind), .text(item.sha256), .text(item.kind), .text(item.sha256)]) != nil
        if !needed { try? FileManager.default.removeItem(at: keeper.contentURL(kind: item.kind, sha256: item.sha256)) }
    }
}

/// Only the pump uses this narrow forwarding port. It adds attribution before the engine's unmodified removal.
/// The pump sees receipts for its OWN operations, after both metadata and removal have been durably enqueued.
struct CloudFileDeleteOutbox: CloudOutboxPort {
    let base: any CloudOutboxPort
    let expand: @Sendable ([CloudOperation]) async throws -> [CloudOperation]
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        let expanded = try await expand(operations)
        // Everything of this batch was withheld (a withdrawn "Cloud" removal): nothing to queue, the pump goes on.
        guard !expanded.isEmpty else { return .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: 0, savedAt: 0) }
        let receipt = try await base.enqueue(expanded, files: files)
        guard Set(receipt.operationIds) == Set(expanded.map(\.opId)) else { throw CloudFailure.checksumMismatch }
        return .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: receipt.bytes, savedAt: receipt.savedAt)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { try await base.coverage(sourceId: sourceId) }
    func flush() async throws -> [CloudReceipt] { try await base.flush() }
    func restoreProgress() async throws -> CloudRestoreProgress { try await base.restoreProgress() }
    func contextReady(projectId: String) async throws -> CloudContextReady { try await base.contextReady(projectId: projectId) }
    func register(adapter: any CloudDomainAdapter) async throws { try await base.register(adapter: adapter) }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { try await base.bootstrap(snapshots) }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { try await base.bootstrap(sources: sources, cut: cut) }
    func pull() async throws -> [CloudImportReceipt] { try await base.pull() }
    func setPaused(_ paused: Bool) async throws { try await base.setPaused(paused) }
    // Without these the protocol's defaults would answer for the real sync core (no service clock, no retry).
    func serviceTime() -> Int64? { base.serviceTime() }
    func refreshCoverage() async throws { try await base.refreshCoverage() }
    func retryParked(domains: Set<String>) async throws { try await base.retryParked(domains: domains) }
}

extension CloudFileDeleteRecords {
    static func prepare(_ operations: [CloudOperation], files: [CloudLocalBlob], engine: BackendCloudBrainFiles) async throws -> CloudPreparedImport {
        guard files.isEmpty, !operations.isEmpty, Set(operations.map(\.opId)).count == operations.count else { throw CloudFailure.invalidRequest }
        // A refusal of the one about-record, never a plain error (review 15 Nov, MUST 3).
        for operation in operations where isAbout(operation) { _ = try read(operation) }
        let engineOperations = operations.filter { !isAbout($0) }
        if !engineOperations.isEmpty { _ = try await engine.validateIncoming(engineOperations, files: []) }
        return .init(preparationId: BackendCloudBrainMemoryHash.uuid(BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(operations))), operations: operations, files: [])
    }
    static func apply(_ prepared: CloudPreparedImport, origin: CloudImportOrigin, engine: BackendCloudBrainFiles,
                      db: BackendCloudBrainFilesDatabase, row: String, isolation: isolated (any Actor)? = #isolation) async throws -> CloudImportReceipt {
        let again = try await prepare(prepared.operations, files: prepared.files, engine: engine)
        guard again.preparationId == prepared.preparationId else { throw CloudFailure.idReused }
        try db.exec("CREATE TABLE IF NOT EXISTS file_delete_receipts(id TEXT PRIMARY KEY, body BLOB NOT NULL, engine BLOB);")
        // The owner saved this pack's about-records first (`takeAbouts`, with the verified signer); saving again is a no-op.
        try takeAbouts(prepared.operations, signer: origin.deviceId, domain: CloudBrainFilesFormat.domain(row), in: db)
        let engineOperations = prepared.operations.filter { !isAbout($0) }
        var receipt: CloudImportReceipt?
        if !engineOperations.isEmpty {
            let enginePrepared = try await engine.validateIncoming(engineOperations, files: [])
            receipt = try await engine.applyPrepared(enginePrepared, origin: origin)
        }
        let results = (receipt?.results ?? []) + prepared.operations.filter(isAbout).map { CloudItemResult(entityId: $0.entityId, status: .applied) }
        let result = CloudImportReceipt(preparationId: prepared.preparationId, inventoryRow: row, results: results,
            counts: receipt?.counts ?? .init(domains: 1, records: results.count, files: 0, bytes: 0, blocked: 0))
        let engineBytes: DeckMemorySQL
        if let receipt { engineBytes = .blob(try JSONEncoder().encode(receipt)) } else { engineBytes = .null }
        try db.run("INSERT OR REPLACE INTO file_delete_receipts(id,body,engine) VALUES (?,?,?)",
            [.text(result.preparationId), .blob(try JSONEncoder().encode(result)), engineBytes])
        return result
    }
    static func verify(_ receipt: CloudImportReceipt, db: BackendCloudBrainFilesDatabase, engine: BackendCloudBrainFiles,
                       keeper: BackendCloudVersionKeeper, kind: String, isolation: isolated (any Actor)? = #isolation) async throws -> CloudVerification {
        guard let row = try db.first("SELECT body,engine FROM file_delete_receipts WHERE id=?", [.text(receipt.preparationId)]),
              let data = row.data(0), try JSONDecoder().decode(CloudImportReceipt.self, from: data) == receipt else {
            return .init(verified: false, counts: receipt.counts, reasons: ["The saved import receipt differs."])
        }
        if let bytes = row.data(1) {
            let engineReceipt = try JSONDecoder().decode(CloudImportReceipt.self, from: bytes)
            let checked = try await engine.verify(engineReceipt)
            if checked.verified { return checked }
            let hashes = try Set(keeper.binAll(kind: kind).compactMap { bin -> String? in
                keeper.content(kind: kind, sha256: bin.sha256) == nil ? nil : bin.sha256
            })
            return try await engine.verifyOwnedRemovalReceipt(engineReceipt, binnedHashes: hashes)
        }
        return .init(verified: true, counts: receipt.counts, reasons: [])
    }
}

extension BackendCloudBrainFiles {
    /// An owner may have moved an imported private copy into the keeper Bin later in this SAME pack. The ordinary
    /// verifier rightly rejects a missing destination; this narrow fallback proves the retained bytes and that exact
    /// archived version's keeper bytes instead. It never treats an arbitrary missing destination as verified.
    func verifyOwnedRemovalReceipt(_ receipt: CloudImportReceipt, binnedHashes: Set<String>) throws -> CloudVerification {
        let db = try database()
        guard let saved = try db.first("SELECT body FROM receipts WHERE id=?", [.text(receipt.preparationId)])?.data(0),
              try CloudWire.canonical(receipt) == saved else {
            return .init(verified: false, counts: receipt.counts, reasons: ["The saved import receipt differs."])
        }
        var reasons: [String] = []
        for row in try db.rows("""
            SELECT r.raw_hash,r.destination,r.local_hash,r.kind,r.source_id,r.relative
            FROM receipt_resources x JOIN resources r ON r.store_id=x.store_id AND r.key=x.key AND r.version=x.version
            WHERE x.preparation=?
            """, [.text(receipt.preparationId)]) {
            if row.text(3) == "archive" { continue }
            guard retainedBytes(row.text(0)) != nil else { reasons.append("A retained copy is missing or changed."); continue }
            guard let destination = row.string(1), let hash = row.string(2) else { continue }
            if (try? BackendCloudBrainMemoryHash.file(URL(fileURLWithPath: destination))) == hash { continue }
            let archived = try db.first("SELECT raw_hash FROM files WHERE source_id=? AND path=? AND archived=1",
                [.text(row.text(4)), .text(row.text(5))])?.string(0)
            guard archived == hash, binnedHashes.contains(hash) else {
                reasons.append("A placed file does not match what was saved."); continue
            }
        }
        return .init(verified: reasons.isEmpty, counts: receipt.counts, reasons: reasons)
    }
}

extension BackendCloudBrainFiles {
    /// Review 15 Nov (point 12): has this path ever held these bytes, in this Mac's own journal or in what arrived? One
    /// query per file (a branch switch can bring back hundreds of files at once).
    func knownVersion(sourceId: String, relative: String, rawHash: String) throws -> Bool {
        try database().first("""
            SELECT 1 FROM journal WHERE source_id=? AND path=? AND raw_hash=?
            UNION ALL SELECT 1 FROM resources WHERE source_id=? AND relative=? AND raw_hash=? LIMIT 1
            """, [.text(sourceId), .text(relative), .text(rawHash), .text(sourceId), .text(relative), .text(rawHash)]) != nil
    }
}

extension DeckMemoryStore {
    /// Review 15 Nov (MUST 4): has this device announced that it understands the delete rule (`v1`, or J-1's `none`)?
    /// A store that cannot be read answers yes: the safe reading (a removal without its about-record keeps the file).
    public func cloudDeleteRuleAnnounced(device: String) -> Bool {
        do {
            guard let raw = try setting(CloudDeleteGate.key(device: device), owner: nil) else { return false }
            return raw.hasPrefix("v1:") || raw == CloudDeleteGate.none
        } catch { return true }
    }
}
