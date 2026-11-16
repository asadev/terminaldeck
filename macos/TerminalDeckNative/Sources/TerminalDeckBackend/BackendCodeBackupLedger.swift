import Foundation
import CryptoKit
import Darwin

/// L5 slice 2: how each project's code is backed up (owner, 13-14 Nov: "the code is the person's choice per project").
public enum BackendCodeBackupMode: String, Codable, Sendable, CaseIterable, Equatable {
    case automatic, manual, off
    public var word: String { switch self { case .automatic: "Automatic"; case .manual: "Manual"; case .off: "Off" } }
}

/// What one backup of uncommitted work covered: the working state it was taken from (`fingerprint`), the set-aside
/// changes (stash commits) it carried, when, and the files it left out on purpose.
public struct BackendCodeBackupCoverage: Codable, Sendable, Equatable {
    public struct LeftOut: Codable, Sendable, Equatable {
        public let name: String
        public let reason: String
        public init(name: String, reason: String) { self.name = name; self.reason = reason }
    }
    public var fingerprint: String
    public var stashes: [String]
    public var at: Int64
    public var leftOut: [LeftOut]
    /// Correction 14 Nov: his branches as last kept in the private backup references (branch -> commit), so his
    /// commits there count as backed up even though they are not on his real GitHub branches.
    public var heads: [String: String]?
    public init(fingerprint: String, stashes: [String], at: Int64, leftOut: [LeftOut], heads: [String: String]? = nil) {
        self.fingerprint = fingerprint; self.stashes = stashes; self.at = at; self.leftOut = leftOut; self.heads = heads
    }

    /// The working state of a repository as `status` sees it, plus each listed file's size and modification time, so
    /// an edit to a file that was already changed is a new state. Nothing is written; one `lstat` per listed file.
    public static func fingerprint(head: String, status: String, top: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data((head + "\n").utf8))
        hasher.update(data: Data(status.utf8))
        for name in BackendCodeBackupGitReader.statusNames(status) {
            var info = stat()
            let mark = lstat(top + "/" + name, &info) == 0 ? "\(info.st_size).\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)" : "-"
            hasher.update(data: Data(("\0" + name + "\0" + mark).utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A "Get the code" that started and has not finished: where the download waits beside the project's folder.
public struct BackendCodeBackupGetting: Codable, Sendable, Equatable {
    public var home: String
    public var folder: String
    public var temporary: String
    public var startedAt: Int64
    public init(home: String, folder: String, temporary: String, startedAt: Int64) {
        self.home = home; self.folder = folder; self.temporary = temporary; self.startedAt = startedAt
    }
}

/// This Mac's own record for the Code page's actions (`<dataRoot>/code-backup.json`): the mode chosen per project,
/// each project's GitHub home as this Mac knows it, what the last backup of uncommitted work covered (per repository),
/// "Get the code" runs still open, and the files a "Get the code" kept because his own differed. Never sent anywhere.
public final class BackendCodeBackupLedger: @unchecked Sendable {
    public static let fileName = "code-backup.json"
    struct Saved: Codable, Equatable {
        var modes: [String: BackendCodeBackupMode] = [:]
        var homes: [String: String] = [:]
        var covered: [String: BackendCodeBackupCoverage] = [:]
        var getting: [String: BackendCodeBackupGetting] = [:]
        var kept: [String: [String]] = [:]
        /// Homes ("owner/name", lower case) that Terminal Deck itself made: real branch and tag names may be used there.
        var made: [String] = []
        /// Made homes that later showed a workflow, a webhook, a deploy key, Pages or an app with access to every
        /// repository: from then on they are treated like his other homes (private references only), for good.
        var loud: [String] = []
        /// 14 Nov (lead): a "Back up now" finished successfully on this Mac. Until then every project is Manual here.
        var firstBackupDone = false
        /// A random id for this Mac's backup area, only when the hardware id cannot be read.
        var spareID: String?
        /// Mac tidy (15 Nov): when this Mac last sent a backup of each project (ms), for "from which Mac".
        var sent: [String: Int64] = [:]
        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modes = try c.decodeIfPresent([String: BackendCodeBackupMode].self, forKey: .modes) ?? [:]
            homes = try c.decodeIfPresent([String: String].self, forKey: .homes) ?? [:]
            covered = try c.decodeIfPresent([String: BackendCodeBackupCoverage].self, forKey: .covered) ?? [:]
            getting = try c.decodeIfPresent([String: BackendCodeBackupGetting].self, forKey: .getting) ?? [:]
            kept = try c.decodeIfPresent([String: [String]].self, forKey: .kept) ?? [:]
            made = try c.decodeIfPresent([String].self, forKey: .made) ?? []
            loud = try c.decodeIfPresent([String].self, forKey: .loud) ?? []
            firstBackupDone = try c.decodeIfPresent(Bool.self, forKey: .firstBackupDone) ?? false
            spareID = try c.decodeIfPresent(String.self, forKey: .spareID)
            sent = try c.decodeIfPresent([String: Int64].self, forKey: .sent) ?? [:]
        }
    }
    private let file: URL?
    private let lock = NSLock()
    private var saved: Saved

    /// `file` nil keeps everything in memory (tests, previews).
    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(Saved.self, from: data) { saved = value }
        else { saved = Saved() }
    }

    private func change(_ edit: (inout Saved) -> Void) {
        let snapshot: Saved = lock.withLock { edit(&saved); return saved }
        guard let file else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// The folder this record lives in (nil for an in-memory record).
    public var folder: URL? { file?.deletingLastPathComponent() }
    public func mode(_ projectID: String) -> BackendCodeBackupMode? { lock.withLock { saved.modes[projectID] } }
    public func setMode(_ projectID: String, _ mode: BackendCodeBackupMode) { change { $0.modes[projectID] = mode } }
    public func home(_ projectID: String) -> String? { lock.withLock { saved.homes[projectID] } }
    public func setHome(_ projectID: String, _ home: String) { change { $0.homes[projectID] = home } }
    public func coverage(_ gitDir: String) -> BackendCodeBackupCoverage? { lock.withLock { saved.covered[gitDir] } }
    public func setCoverage(_ gitDir: String, _ coverage: BackendCodeBackupCoverage) { change { $0.covered[gitDir] = coverage } }
    public func getting(_ projectID: String) -> BackendCodeBackupGetting? { lock.withLock { saved.getting[projectID] } }
    public var allGetting: [String: BackendCodeBackupGetting] { lock.withLock { saved.getting } }
    public func setGetting(_ projectID: String, _ value: BackendCodeBackupGetting?) { change { $0.getting[projectID] = value } }
    /// Correction 14 Nov: which kind of home this is. Real branch and tag names only for a home Terminal Deck made that
    /// has never shown anything that reacts to a push.
    public func usesRealNames(_ home: String) -> Bool {
        let key = home.lowercased()
        return lock.withLock { saved.made.contains(key) && !saved.loud.contains(key) }
    }
    public func isMade(_ home: String) -> Bool { lock.withLock { saved.made.contains(home.lowercased()) } }
    public func madeHome(_ home: String) { change { if !$0.made.contains(home.lowercased()) { $0.made.append(home.lowercased()) } } }
    public func markLoud(_ home: String) { change { if !$0.loud.contains(home.lowercased()) { $0.loud.append(home.lowercased()) } } }
    public var firstBackupDone: Bool { lock.withLock { saved.firstBackupDone } }
    public func sentAt(_ projectID: String) -> Int64? { lock.withLock { saved.sent[projectID] } }
    public func setSent(_ projectID: String, at: Int64) { change { $0.sent[projectID] = at } }
    public func setFirstBackupDone() { if !firstBackupDone { change { $0.firstBackupDone = true } } }
    /// This Mac's spare id (made once, kept): used only when the hardware id cannot be read.
    public func spareID() -> String {
        if let kept = lock.withLock({ saved.spareID }) { return kept }
        let made = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        change { if $0.spareID == nil { $0.spareID = made } }
        return lock.withLock { saved.spareID } ?? made
    }
    public func kept(_ projectID: String) -> [String] { lock.withLock { saved.kept[projectID] ?? [] } }
    public func setKept(_ projectID: String, _ names: [String]) { change { $0.kept[projectID] = names.isEmpty ? nil : names } }
}
