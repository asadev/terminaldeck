import Foundation
import TerminalDeckNativeCore

/// What the flow must remember across a restart: how far each session's own record has been
/// read into the diary, which helper jobs are still waiting, and the last runs. One small
/// JSON file in the app's data folder (it describes files on THIS Mac, so it does not move
/// with the memory folder). Written whole and atomically on every change.
public struct DeckMemoryFlowState: Sendable, Equatable, Codable {
    /// How far one session's CLI record has been copied into the diary.
    public struct Record: Sendable, Equatable, Codable {
        public var path: String
        /// Always at the start of a line.
        public var offset: Int64
        /// The file's identity, so a replaced file is read from its start.
        public var inode: UInt64
        /// Codex writes messages in one of two record shapes per file; the first seen is kept.
        public var family: String?
        /// Gemini rewrites its record in place: the last message id already in the diary.
        public var lastMessageID: String?
        public init(path: String, offset: Int64 = 0, inode: UInt64 = 0, family: String? = nil, lastMessageID: String? = nil) {
            self.path = path; self.offset = offset; self.inode = inode; self.family = family; self.lastMessageID = lastMessageID
        }
    }
    public var version = 1
    /// By the app's session id.
    public var records: [String: Record] = [:]
    /// Hoot: conversation id → the last event already in the diary.
    public var hoot: [String: Int] = [:]
    public var jobs: [DeckMemoryFlowJob] = []
    public var runs: [DeckMemoryFlowRun] = []
    /// Messages where the person seemed to correct something and the helper wrote no correction
    /// note: the nightly tidy-up looks at exactly these again, not at the whole day.
    public var missed: [Missed]?
    /// Short-lived helper seats whose last session closed, by session id → the seat's key: they fold
    /// back into their parent after that session's last read. Kept here so a restart never forgets one.
    public var folding: [String: String]?
    public init() {}

    public struct Missed: Sendable, Equatable, Codable {
        /// The seat's key.
        public var owner: String
        public var session: String
        /// Diary row ids, first...last.
        public var first: Int64
        public var last: Int64
        public var at: Double
        public init(owner: String, session: String, first: Int64, last: Int64, at: Double) {
            self.owner = owner; self.session = session; self.first = first; self.last = last; self.at = at
        }
    }
    public static let maximumMissed = 200
    public mutating func add(_ entry: Missed) {
        var list = missed ?? []
        list.append(entry)
        if list.count > Self.maximumMissed { list.removeFirst(list.count - Self.maximumMissed) }
        missed = list
    }

    public static let maximumRuns = 60
    public mutating func add(_ run: DeckMemoryFlowRun) {
        runs.insert(run, at: 0)
        if runs.count > Self.maximumRuns { runs.removeLast(runs.count - Self.maximumRuns) }
    }
}

/// Loads and saves the state file. A missing or unreadable file starts empty: nothing is
/// lost, because the diary keeps a key per source record and skips what it already has.
public struct DeckMemoryFlowStateFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> DeckMemoryFlowState {
        guard let data = try? Data(contentsOf: url), let state = try? JSONDecoder().decode(DeckMemoryFlowState.self, from: data) else {
            return DeckMemoryFlowState()
        }
        return state
    }
    public func save(_ state: DeckMemoryFlowState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
