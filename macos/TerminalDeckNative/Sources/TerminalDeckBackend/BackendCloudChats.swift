import CryptoKit
import Foundation
import zlib
import TerminalDeckNativeCore

/// Sessions and chats in the Cloud, step 1, the Mac part (owner, 15 Nov 2026: "every session and chat of his account is
/// listed on every device, by account and not by machine"; "chat histories live in the Cloud and are kept until he
/// deletes them, however big"). Design: Sessions seat note `2026-11-15-sessions-in-the-cloud.md`; contract: Servers
/// note `2026-11-15-cloud-chats.md`, "Contract for the Mac" (its decisions win).
///
/// This Mac puts ITS OWN list of sessions (what the side panel lists) and each session's chat as it grows:
/// - `raw`: the AI's own history file, exact to the byte (step 2 continues it on another machine), plus each Claude
///   `tool-results` file as its own `tool:<name>` stream;
/// - `read`: the readable messages as the event lines the phones already draw (`BackendCloudChatsReadable`);
/// - `snap`: an app chat's / Hoot's saved `chat.json` (runtime fields left out), when it has been quiet 2 minutes.
/// Only what was added goes up, about every 30 s while something grew, nothing at all while idle. Old histories catch up
/// in the background as closed pieces (`backfill`), readable copies first, newest-used first, one call per 2 s,
/// resumable; a 439 MB history goes up in 4 MiB pieces, never loaded whole.
/// Never deletes anything: closing a session only takes it off the list (its chat stays). The Bin is by hand
/// (`bin(...)`, the Cloud page's two Bin buttons); no AI tool reaches it.
public enum BackendCloudChats {
    /// Contract: close `raw` at 4 MiB raw, `read` at 1 MiB raw.
    public static let rawPieceBytes = 4 * 1_048_576
    public static let readPieceBytes = 1_048_576
    /// The most raw bytes ONE tick part carries (more waits for the next tick, or is sent as pieces).
    public static let partRawBytes = 4 * 1_048_576
    /// The base64 bytes one tick body carries at most (contract: 8 MiB a call).
    public static let tickBodyBytes = 6 * 1_048_576
    /// A tail is closed into a piece after 64 ticks or 10 minutes without growth.
    public static let tailPartsMax = 64
    public static let quietCloseMs: Int64 = 600_000
    /// The list goes up when it changed, at most once per 15 s, inside the tick.
    public static let listEveryMs: Int64 = 15_000
    /// An app chat's saved file goes up 2 minutes after it last changed.
    public static let snapQuietMs: Int64 = 120_000
    /// Gemini rewrites its chat file whole: its raw copy goes up once it has been quiet 10 minutes (one generation per
    /// quiet spell, not one per message).
    public static let geminiQuietMs: Int64 = 600_000
    /// A last history line with no newline counts as whole once the file has not grown for a minute.
    public static let lineQuietMs: Int64 = 60_000
    /// Contract ceilings: 8 MiB raw a part/piece/snap, 2 KB a list row, 512 streams a session.
    public static let maximumRawBytes = 8 * 1_048_576
    public static let toolStreamsMax = 256
    public static let tailCheckBytes = 4_096

    // MARK: The list row (contract §1, the Mac's own list)

    public struct Project: Codable, Sendable, Equatable {
        public var cloudRef: String
        public var name: String
        public init(cloudRef: String, name: String) { self.cloudRef = cloudRef; self.name = name }
    }
    /// One row of this Mac's list: exactly the contract's keys (an unknown key would drop the row), nil keys left out.
    public struct Row: Codable, Sendable, Equatable {
        public var sessionId: String
        public var name: String
        public var lastUsedAt: Int64
        public var project: Project?
        public var cwd: String?
        public var ai: String?
        public var login: String?
        public var kind: String?
        public var status: String?
        public var startedAt: Int64?
        public var conversationId: String?
        /// Step 2: when this Mac last backed the session's project up (ms), "the code here is from <time>" on the Mac
        /// that takes it while this one is off. A key the service's list accepts (as-built contract §6).
        public var codeAt: Int64?
        public var v: Int?
        public init(sessionId: String, name: String, lastUsedAt: Int64, project: Project? = nil, cwd: String? = nil, ai: String? = nil,
                    login: String? = nil, kind: String? = nil, status: String? = nil, startedAt: Int64? = nil, conversationId: String? = nil,
                    codeAt: Int64? = nil) {
            self.sessionId = sessionId; self.name = name; self.lastUsedAt = lastUsedAt; self.project = project; self.cwd = cwd
            self.ai = ai; self.login = login; self.kind = kind; self.status = status; self.startedAt = startedAt
            self.conversationId = conversationId; self.codeAt = codeAt; v = 1
        }
    }
    /// Where a session's chat is read from on this Mac. A plain terminal has none ("A terminal, nothing to read").
    public struct Source: Sendable, Equatable {
        public var raw: URL?
        public var tools: [URL]
        public var readable: BackendCloudChatsReadable.Format?
        public var snap: URL?
        public var provider: HootChatProvider?
        public init(raw: URL? = nil, tools: [URL] = [], readable: BackendCloudChatsReadable.Format? = nil, snap: URL? = nil, provider: HootChatProvider? = nil) {
            self.raw = raw; self.tools = tools; self.readable = readable; self.snap = snap; self.provider = provider
        }
        public static let none = Source()
    }
    public struct Listed: Sendable, Equatable {
        public var row: Row
        public var source: Source
        public init(row: Row, source: Source) { self.row = row; self.source = source }
    }

    /// The side panel's states in the contract's words (BackendRemoteHost's phone status).
    public static func status(_ phone: String) -> String {
        switch phone {
        case "working": return "running"
        case "input": return "needsYou"
        case "exited": return "ended"
        default: return "idle"
        }
    }
    /// The Cloud's id for a session: its tab key, which survives an app or keeper restart (a process's own id does
    /// not), so a restored session keeps ONE chat in the Cloud instead of starting a second copy.
    public static func cloudID(_ meta: BackendSessionMeta) -> String {
        let key = meta.tabKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? meta.id : key
    }
    /// The id join (15 Nov, live use): the `tab` a live session row carries to phones and the web, the same id as
    /// `cloudID`; nil when the session has no saved tab (its Cloud id is then its own id, the clients' fallback).
    public static func liveTab(_ meta: BackendSessionMeta) -> String? {
        let key = meta.tabKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }
    /// The id the Cloud's session rows name a machine by (their `machine`): the service's own rule, first 32 hex of
    /// SHA-256("TD-CHATS-MACHINE-1\n" + account subject + "\n" + machine), machine = its machineId, else its device id.
    public static func machineRef(subject: String, machine: String) -> String {
        String(SHA256.hash(data: Data(("TD-CHATS-MACHINE-1\n" + subject + "\n" + machine).utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }
}

/// This Mac's `machine` ref while it is signed in (set at Cloud attach, cleared at detach), for the live session list's
/// header so phones and the web match machines by id. Nil = not signed in: the field is left out.
public final class BackendCloudChatsMachine: @unchecked Sendable {
    public static let shared = BackendCloudChatsMachine()
    private let lock = NSLock()
    private var ref: String?
    public var current: String? { lock.withLock { ref } }
    public func set(_ value: String?) { lock.withLock { ref = value?.isEmpty == true ? nil : value } }
}

extension BackendCloudChats {
    /// This Mac's row for one session it lists. `name`: the side panel's own title for it when known.
    public static func row(_ listed: BackendCloudChatsListedSession, name: String?, projects: [PROJProject]) -> Row {
        let meta = listed.meta
        let projectID = PROJProjects.resolve(projectID: meta.projectId, folder: meta.cwd, projects: projects)
        let project = projectID == PROJProjects.independentID ? nil
            : projects.first { $0.id == projectID }.map { Project(cloudRef: clip($0.id, 128) ?? $0.id, name: clip($0.name, 120) ?? "") }
        let kind: String
        if meta.chat == true { kind = "chat" }
        else if meta.origin == .copilot || meta.origin == .app || meta.originRunId != nil || meta.profileId != nil { kind = "agent" }
        else { kind = "terminal" }
        let title = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? meta.title
        return Row(sessionId: cloudID(meta), name: clip(title, 200) ?? "Session", lastUsedAt: Int64(listed.lastUsedAt),
                   project: project, cwd: clip(meta.cwd, 512), ai: clip(meta.provider, 32), login: clip(meta.profileName, 120),
                   kind: kind, status: status(listed.status), startedAt: Int64(meta.createdAt), conversationId: clip(meta.agentSessionId, 128))
    }
    static func clip(_ text: String?, _ limit: Int) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.count <= limit ? text : String(text.prefix(limit))
    }
    /// What makes a list put: everything on the rows (a status or a real use moving is a change; at most every 15 s).
    public static func fingerprint(_ rows: [Row]) -> String {
        let sorted = rows.sorted { $0.sessionId < $1.sessionId }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return hex((try? encoder.encode(sorted)) ?? Data())
    }

    // MARK: Bytes

    public static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// gzip of `bytes` (one member). nil only when zlib refuses.
    public static func gzip(_ bytes: Data) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        var output = Data(count: Int(deflateBound(&stream, uLong(bytes.count))) + 64)
        let capacity = output.count
        let result: Int32 = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(bytes.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(capacity)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { return nil }
        output.count = Int(stream.total_out)
        return output
    }
    /// The bytes of a gzip member, at most `limit` of them (tests and the read-only view of a raw piece).
    public static func gunzip(_ bytes: Data, limit: Int = maximumRawBytes) -> Data? {
        var stream = z_stream()
        guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var output = Data(count: limit + 1)
        let result: Int32 = bytes.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(bytes.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(limit + 1)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END, Int(stream.total_out) <= limit else { return nil }
        output.count = Int(stream.total_out)
        return output
    }
    /// A file's size and change time; nil for anything that is not a plain file.
    static func look(_ url: URL) -> (size: Int64, mtime: Double)? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              (values[.type] as? FileAttributeType) == .typeRegular, let size = (values[.size] as? NSNumber)?.int64Value else { return nil }
        return (size, (values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
    /// `count` bytes from `offset` (fewer at the end), read through a handle: a history is never loaded whole.
    static func read(_ url: URL, from offset: Int64, count: Int) -> Data? {
        guard count >= 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, offset)))
            return try handle.read(upToCount: count) ?? Data()
        } catch { return nil }
    }
}

/// One session the side panel lists, as the phones get it (BackendRemoteHost.cloudListed).
public struct BackendCloudChatsListedSession: Sendable {
    public let meta: BackendSessionMeta
    public let status: String
    public let lastUsedAt: Double
    public init(meta: BackendSessionMeta, status: String, lastUsedAt: Double) { self.meta = meta; self.status = status; self.lastUsedAt = lastUsedAt }
}

/// Finds each session's history file on this Mac: sizes and paths only; a file is opened only to copy what was added.
public final class BackendCloudChatsLocator: @unchecked Sendable {
    public let claudeHomes: [String]
    public let codexHomes: [String]
    public let geminiHome: String
    /// `<data>/session-chats` (the app's chats) and `<data>/hoot` (Hoot's chat).
    public let chats: URL
    public let hoot: URL
    /// Terminal Deck's own AI login folders' parents (`<data>/account-logins`, `<data>/agent-homes`): earlier chats.
    public let ownRoots: [URL]
    private let lock = NSLock()
    private var codexFound: [String: (url: URL?, at: Date)] = [:]
    private var geminiFound: [String: (url: URL?, at: Date)] = [:]
    public init(claudeHomes: [String], codexHomes: [String], geminiHome: String, chats: URL, hoot: URL, ownRoots: [URL] = []) {
        self.claudeHomes = claudeHomes; self.codexHomes = codexHomes; self.geminiHome = geminiHome; self.chats = chats; self.hoot = hoot
        self.ownRoots = ownRoots
    }
    /// Each AI login home Terminal Deck made on this Mac (never the plain `~/.claude`, `~/.codex`, `~/.gemini`).
    public func ownHomes() -> [URL] {
        ownRoots.flatMap { root in
            ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
    }

    public func source(_ meta: BackendSessionMeta) -> BackendCloudChats.Source {
        if meta.chat == true {
            let folder = BackendSessionChats.tabFolder(chats, key: meta.tabKey ?? meta.id)
            guard let file = Self.newestChat(in: folder) else { return .none }
            return .init(readable: .appChat, snap: file, provider: HootChatProvider(rawValue: meta.provider))
        }
        guard let id = meta.agentSessionId, id.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil else { return .none }
        switch meta.provider {
        case "claude":
            let folder = String(meta.cwd.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
            var best: (URL, Double)?
            for home in claudeHomes {
                let file = URL(fileURLWithPath: home).appendingPathComponent("projects/\(folder)/\(id).jsonl")
                if let seen = BackendCloudChats.look(file), seen.mtime >= (best?.1 ?? -1) { best = (file, seen.mtime) }
            }
            guard let raw = best?.0 else { return .none }
            let side = raw.deletingPathExtension().appendingPathComponent("tool-results", isDirectory: true)
            let tools = ((try? FileManager.default.contentsOfDirectory(at: side, includingPropertiesForKeys: nil)) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                .prefix(BackendCloudChats.toolStreamsMax)
            return .init(raw: raw, tools: Array(tools), readable: .claude, provider: .claude)
        case "codex":
            guard let raw = cached(&codexFound, id, find: {
                for home in codexHomes {
                    if let thread = try? BackendSessionSwitchCodexCarry.find(home: home, cwd: meta.cwd, startedAt: meta.createdAt, knownID: id) { return thread.file }
                }
                return nil
            }) else { return .none }
            return .init(raw: raw, readable: .codex, provider: .codex)
        case "gemini":
            guard let raw = cached(&geminiFound, id, find: { Self.geminiFile(home: geminiHome, id: id) }) else { return .none }
            return .init(raw: raw, readable: .gemini, provider: .gemini)
        default:
            return .none
        }
    }
    /// Hoot's chat on this Mac: its newest saved file (`chat.json`, `chat-codex.json`, `chat-gemini.json`).
    public func hootSource() -> BackendCloudChats.Source? {
        guard let file = Self.newestChat(in: hoot) else { return nil }
        let name = file.deletingPathExtension().lastPathComponent
        let provider: HootChatProvider = name == "chat" ? .claude : HootChatProvider(rawValue: String(name.dropFirst(5))) ?? .claude
        return .init(readable: .appChat, snap: file, provider: provider)
    }
    static func newestChat(in folder: URL) -> URL? {
        let names = ["chat.json", "chat-codex.json", "chat-gemini.json"]
        return names.compactMap { name -> (URL, Double)? in
            let file = folder.appendingPathComponent(name)
            return BackendCloudChats.look(file).map { (file, $0.mtime) }
        }.max { $0.1 < $1.1 }?.0
    }
    /// Gemini names its chat files `session-<time>-<first 8 of the id>.json` under `tmp/<project>/chats/`.
    static func geminiFile(home: String, id: String) -> URL? {
        let tmp = URL(fileURLWithPath: home).appendingPathComponent("tmp", isDirectory: true)
        let short = String(id.prefix(8))
        for project in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? [] {
            let chats = project.appendingPathComponent("chats", isDirectory: true)
            for file in (try? FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil)) ?? []
                where file.pathExtension == "json" && file.lastPathComponent.contains(short) {
                if let head = BackendCloudChats.read(file, from: 0, count: 4_096), String(decoding: head, as: UTF8.self).contains(id) { return file }
            }
        }
        return nil
    }
    /// A found file is kept; a miss is looked for again after 10 minutes (the AI may not have written it yet).
    private func cached(_ table: inout [String: (url: URL?, at: Date)], _ id: String, find: () -> URL?) -> URL? {
        lock.lock()
        if let hit = table[id], hit.url != nil || Date().timeIntervalSince(hit.at) < 600 {
            lock.unlock()
            if let url = hit.url, BackendCloudChats.look(url) != nil { return url }
            if hit.url == nil { return nil }
            lock.lock(); table[id] = nil; lock.unlock()
        } else { lock.unlock() }
        let found = find()
        lock.lock(); table[id] = (found, Date()); lock.unlock()
        return found
    }
}

/// The uploader: this Mac's list and its sessions' streams, with what the service holds of each, kept beside this
/// identity's sync store so a crash or a quit resumes where it was (`chats/state.json`; the readable copy's open tail in
/// `chats/tails/`). Every call goes through the transport's own chats door, never sync's back-off.
public actor BackendCloudChatsUploader {
    public typealias Send = @Sendable (_ method: String, _ path: String, _ body: Data) async throws -> (status: Int, data: Data)

    /// One stream of one session, as far as the service holds it (this generation).
    public struct Stream: Codable, Sendable, Equatable {
        public var gen = 1
        /// Bytes of this stream the service holds.
        public var length: Int64 = 0
        /// Of those, bytes in closed pieces, and how many pieces.
        public var pieced: Int64 = 0
        public var pieces = 0
        /// The open tail's parts (raw lengths), oldest first.
        public var tail: [Int] = []
        /// The file this stream copies (`raw`, `tool:`) or reads (`read`); another file starts a new generation.
        public var source: String?
        /// `read`: how far the source was read (bytes of a line history; messages of a Gemini file; the last event
        /// sequence of an app chat), the event lines written, the conversation of this generation.
        public var sourceOffset: Int64 = 0
        public var events = 0
        public var conversation: String?
        /// `raw`/`tool:`: sha256 of the last <= 4 KiB the service holds (a rewound or rewritten file no longer matches).
        public var tailSha: String?
        public var grewAt: Int64 = 0
        public var seenSize: Int64 = 0
        public var seenMtime: Double = 0
        /// `read` of a whole-file history (Gemini, an app chat): changed since it was last read through.
        public var dirty = false
        public init() {}
    }
    public struct Session: Codable, Sendable, Equatable {
        public var streams: [String: Stream] = [:]
        public var snapSha: String?
        public var snapMtime: Double = 0
        public var snapChangedAt: Int64?
        /// The service said `binned`: never uploaded again by itself. `notYours`: another machine owns that id.
        public var binned = false
        public var notYours = false
        public var noTools = false
        public init() {}
    }
    public struct State: Codable, Sendable, Equatable {
        public var sessions: [String: Session] = [:]
        public var listFingerprint: String?
        public var listAt: Int64 = 0
        public var listed = 0
        /// Earlier chats (Terminal Deck's own past sessions on this Mac), by their Cloud id.
        public var archive: [String: Archived] = [:]
        public init() {}
    }
    /// One earlier chat: found on this Mac, put in the list ONCE so the service knows its name, project and dates, taken
    /// off the list again at the next list put (so it is a closed session's chat, "Earlier chats", never a row of the
    /// list), then copied in the background, then done.
    public struct Archived: Codable, Sendable, Equatable {
        public enum Stage: String, Codable, Sendable { case waiting, introduced, closed, done }
        public var found: BackendCloudChatsArchive.Found
        public var row: BackendCloudChats.Row
        public var stage: Stage
        public var bytes: Int64
        public init(found: BackendCloudChatsArchive.Found, row: BackendCloudChats.Row, stage: Stage = .waiting, bytes: Int64) {
            self.found = found; self.row = row; self.stage = stage; self.bytes = bytes
        }
        public var listed: BackendCloudChats.Listed { .init(row: row, source: BackendCloudChatsArchive.source(found)) }
    }
    /// Earlier chats are introduced to the service at most this many per list put.
    public static let archiveBatch = 200
    public enum Outcome: Sendable, Equatable {
        /// Nothing grew and the list did not change: nothing was sent.
        case idle
        case sent(parts: Int, list: Bool)
        /// The service part is not live (404): silent until the next launch.
        case missing
        /// Not now (lost connection, 429, `chats_full`): tried again later.
        case later
    }

    let send: Send
    let directory: URL?
    public private(set) var state: State
    public private(set) var missing = false
    /// `chats_full` (a cap the service was given): nothing more goes up until the next launch. Never silent on the
    /// service's side; here it only stops trying.
    public private(set) var full = false
    var headChecked = false
    var needsHead: Set<String> = []
    /// Streams a call is under way for ("session|stream"): the live tick and the catch-up never touch the same one.
    var busy: Set<String> = []
    /// Streams the service asked to close first (`piece_needed`).
    var closeSoon: Set<String> = []
    /// A tick whose answer was lost: sent again, same id and bytes, before anything new.
    var pendingTick: (body: Data, plans: [Plan], list: String?, introduce: [String], close: [String])?
    /// Files the catch-up still has to send (for the status line), by the last look.
    public private(set) var sourceBytes: Int64 = 0
    let clock: @Sendable () -> Int64
    /// Step 2: an upload answered `not_yours` (the session moved to another Mac, its name when the service says it).
    var moved: (@Sendable (_ sessionId: String, _ machine: String?) async -> Void)?
    public func onMoved(_ handler: (@Sendable (_ sessionId: String, _ machine: String?) async -> Void)?) { moved = handler }
    func movedAway(_ session: String, _ machine: String?) {
        guard let moved else { return }
        Task { await moved(session, machine) }
    }

    public init(send: @escaping Send, directory: URL?, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.send = send
        self.directory = directory
        self.clock = clock
        if let file = directory?.appendingPathComponent("state.json"), let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved } else { state = State() }
    }

    // MARK: Wire

    struct PartBody: Encodable { let session: String; let stream: String; let gen: Int; let from: Int64; let rawLen: Int; let sha256: String; let gz: String }
    struct TickBody: Encodable { let tickId: String; let sessions: [BackendCloudChats.Row]?; let parts: [PartBody] }
    struct PieceBody: Encodable { let session: String; let stream: String; let gen: Int; let index: Int; let rawFrom: Int64; let rawLen: Int; let sha256: String; let gz: String }
    struct SnapBody: Encodable { let session: String; let rawLen: Int; let sha256: String; let gz: String }
    struct TickAnswer: Decodable {
        struct Part: Decodable { let session: String; let stream: String; let ok: Bool?; let gen: Int?; let have: Int64?; let code: String?; let movedTo: String? }
        struct Sessions: Decodable { let accepted: Bool?; let count: Int?; let dropped: Int?; let notYours: [String]? }
        let parts: [Part]?
        let sessions: Sessions?
    }
    struct PieceAnswer: Decodable { let ok: Bool?; let gen: Int?; let index: Int?; let pieced: Int64?; let have: Int64?; let pieces: Int?; let code: String? }
    struct HeadAnswer: Decodable {
        struct StreamHead: Decodable { let gen: Int?; let length: Int64?; let pieced: Int64?; let pieces: Int?; let tailParts: [Int]? }
        struct SessionHead: Decodable { let session: String; let binned: Bool?; let streams: [String: StreamHead]? }
        let sessions: [SessionHead]?
    }
    struct Failure: Decodable { struct Detail: Decodable { let code: String? }; let error: Detail? }

    enum Answer { case ok(Data), refused(status: Int, code: String?, data: Data), lost }
    func call(_ method: String, _ path: String, _ body: Data = Data()) async -> Answer {
        guard !missing else { return .refused(status: 404, code: "not_found", data: Data()) }
        guard let answered = try? await send(method, path, body) else { return .lost }
        if (200..<300).contains(answered.status) { return .ok(answered.data) }
        if answered.status == 404, path == "/chats/head" || path == "/chats/tick" {
            // The routes are not there yet (or switched off): quiet until the next launch.
            let code = (try? JSONDecoder().decode(Failure.self, from: answered.data))?.error?.code
            if code == nil || code == "not_found" { missing = true }
        }
        return .refused(status: answered.status, code: (try? JSONDecoder().decode(Failure.self, from: answered.data))?.error?.code, data: answered.data)
    }
    func save() {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic) }
    }

    // MARK: The readable copy's open tail (kept on disk until it is closed into a piece)

    func spool(_ session: String) -> URL? {
        directory?.appendingPathComponent("tails", isDirectory: true).appendingPathComponent(String(BackendCloudChats.hex(Data(session.utf8)).prefix(32)) + ".read")
    }
    func spoolAppend(_ session: String, _ bytes: Data) {
        guard let file = spool(session) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: bytes)
        } else { try? bytes.write(to: file, options: .atomic) }
    }
    func spoolClear(_ session: String) { if let file = spool(session) { try? FileManager.default.removeItem(at: file) } }

    // MARK: Resume

    /// Once per launch: what the service holds of this machine's streams. A stream it holds differently is taken as
    /// the service has it (a crash between its answer and this Mac's save); a readable copy that differs starts again.
    public func resume() async {
        guard !headChecked, !missing else { return }
        guard case .ok(let data) = await call("GET", "/chats/head") else { return }
        headChecked = true
        adopt(data)
    }
    func adopt(_ data: Data) {
        guard let head = try? JSONDecoder().decode(HeadAnswer.self, from: data) else { return }
        for held in head.sessions ?? [] {
            var session = state.sessions[held.session] ?? Session()
            if held.binned == true { session.binned = true }
            for (name, stream) in held.streams ?? [:] {
                var mine = session.streams[name] ?? Stream()
                let gen = stream.gen ?? mine.gen, length = stream.length ?? 0
                guard gen != mine.gen || length != mine.length || (stream.tailParts ?? []) != mine.tail || (stream.pieces ?? 0) != mine.pieces else { continue }
                if name == "read" {
                    // Derived from the history: written again from its start in a new generation.
                    mine = Stream(); mine.gen = max(gen, session.streams[name]?.gen ?? 1) + 1
                    spoolClear(held.session)
                } else {
                    mine.gen = gen; mine.length = length; mine.pieced = stream.pieced ?? 0; mine.pieces = stream.pieces ?? 0
                    mine.tail = stream.tailParts ?? []
                    mine.tailSha = mine.source.flatMap { Self.tailSha(URL(fileURLWithPath: $0), length: length) }
                }
                session.streams[name] = mine
            }
            state.sessions[held.session] = session
        }
        save()
    }
    func refreshHead(_ session: String) async {
        guard let query = session.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))),
              case .ok(let data) = await call("GET", "/chats/head?session=" + query) else { return }
        needsHead.remove(session)
        adopt(data)
    }
    static func tailSha(_ url: URL, length: Int64) -> String? {
        let start = max(0, length - Int64(BackendCloudChats.tailCheckBytes))
        guard let bytes = BackendCloudChats.read(url, from: start, count: Int(length - start)), bytes.count == Int(length - start) else { return nil }
        return BackendCloudChats.hex(bytes)
    }

    // MARK: Planning one stream

    struct Plan: Sendable {
        let session: String
        let stream: String
        let gen: Int
        let from: Int64
        let bytes: Data
        /// `read`: where the source stands once these bytes are held, and how many event lines they are.
        var sourceOffset: Int64?
        var events = 0
        var conversation: String?
    }
    enum Look { case nothing, part(Plan), catchUp, closeNow }

    func key(_ session: String, _ stream: String) -> String { session + "|" + stream }
    func stream(_ session: String, _ name: String) -> Stream { state.sessions[session]?.streams[name] ?? Stream() }
    func setStream(_ session: String, _ name: String, _ value: Stream) {
        var held = state.sessions[session] ?? Session()
        held.streams[name] = value
        state.sessions[session] = held
    }
    /// A new generation from byte 0 (the file shrank, was rewound, rewritten or replaced). Older ones stay in the Cloud.
    func restart(_ session: String, _ name: String, source: String?, above: Int = 0) {
        var next = Stream()
        next.gen = max(stream(session, name).gen, above) + 1
        next.source = source
        next.dirty = true
        setStream(session, name, next)
        if name == "read" { spoolClear(session) }
    }

    /// A copied file (`raw`, `tool:`): what was added since the service's length, when it is little enough for a tick.
    func lookFile(_ session: String, _ name: String, _ url: URL, quietMs: Int64 = 0, now: Int64) -> Look {
        guard let seen = BackendCloudChats.look(url) else { return .nothing }
        var held = stream(session, name)
        if held.source != url.path {
            if held.source != nil { restart(session, name, source: url.path) }
            else {
                // First look, or what the service holds was taken over after this Mac's own record was lost: the file
                // is checked against it by its tail, below.
                held.source = url.path
                if held.length > 0 { held.tailSha = Self.tailSha(url, length: held.length) }
                setStream(session, name, held)
            }
            held = stream(session, name)
        }
        if seen.size != held.seenSize || seen.mtime != held.seenMtime {
            held.seenSize = seen.size; held.seenMtime = seen.mtime; held.grewAt = now; setStream(session, name, held)
            // Same length, same tail bytes: a rewrite that changed nothing before the end is caught by the tail check.
            if seen.size < held.length || (held.length > 0 && Self.tailSha(url, length: held.length) != held.tailSha) {
                restart(session, name, source: url.path)
                held = stream(session, name); held.seenSize = seen.size; held.seenMtime = seen.mtime; held.grewAt = now
                setStream(session, name, held)
            }
        }
        let backlog = seen.size - held.length
        guard backlog > 0 else { return .nothing }
        if quietMs > 0, now - held.grewAt < quietMs { return .nothing }
        if backlog > Int64(BackendCloudChats.partRawBytes) { return held.tail.isEmpty ? .catchUp : .closeNow }
        guard let bytes = BackendCloudChats.read(url, from: held.length, count: Int(backlog)), bytes.count == Int(backlog) else { return .nothing }
        return .part(Plan(session: session, stream: name, gen: held.gen, from: held.length, bytes: bytes))
    }

    /// The readable copy: the event lines for what was added to the history since it was last read.
    func lookRead(_ session: String, _ listed: BackendCloudChats.Listed, now: Int64, catchUp: Bool) -> Look {
        guard let format = listed.source.readable, let file = format == .appChat ? listed.source.snap : listed.source.raw,
              let seen = BackendCloudChats.look(file) else { return .nothing }
        var held = stream(session, "read")
        if held.source != file.path {
            if held.source != nil || held.length > 0 { restart(session, "read", source: file.path) } else { held.source = file.path; setStream(session, "read", held) }
            held = stream(session, "read")
        }
        let moved = seen.size != held.seenSize || seen.mtime != held.seenMtime
        if moved { held.seenSize = seen.size; held.seenMtime = seen.mtime; held.grewAt = now; setStream(session, "read", held) }
        let limit = catchUp ? BackendCloudChats.readPieceBytes : BackendCloudChats.readPieceBytes
        let provider = listed.source.provider ?? .claude
        let conversation = listed.row.conversationId ?? session
        switch format {
        case .claude, .codex:
            if seen.size < held.sourceOffset { restart(session, "read", source: file.path); held = stream(session, "read") }
            let backlog = seen.size - held.sourceOffset
            guard backlog > 0 else { return .nothing }
            if !catchUp, backlog > Int64(BackendCloudChats.partRawBytes) { return held.tail.isEmpty ? .catchUp : .closeNow }
            if catchUp, !held.tail.isEmpty { return .closeNow }
            // Up to 64 MiB of history read per look (8 MiB windows) to find about one piece of readable lines.
            var lines = Data(), events = 0, offset = held.sourceOffset, scanned: Int64 = 0
            let window = 8 * 1_048_576
            while offset < seen.size, lines.count < limit, scanned < 64 * 1_048_576 {
                guard let bytes = BackendCloudChats.read(file, from: offset, count: min(window, Int(seen.size - offset))), !bytes.isEmpty else { break }
                let quiet = now - Int64(seen.mtime * 1000) >= BackendCloudChats.lineQuietMs && offset + Int64(bytes.count) >= seen.size
                let made = BackendCloudChatsReadable.window(bytes, format: format, conversation: conversation, provider: provider,
                                                            nextSequence: held.events + events + 1, maxOutput: limit - lines.count, atEnd: quiet)
                if made.consumed == 0 {
                    // One line longer than the window (a huge tool result): passed over, it is never a message.
                    guard bytes.count == window, let skip = Self.nextLine(file, from: offset + Int64(bytes.count), end: seen.size) else { break }
                    scanned += skip - offset; offset = skip; continue
                }
                lines.append(made.lines); events += made.events
                offset += Int64(made.consumed); scanned += Int64(made.consumed)
            }
            if lines.isEmpty {
                // Nothing readable in what was added (tool traffic): read on, nothing to send.
                if offset != held.sourceOffset { held = stream(session, "read"); held.sourceOffset = offset; setStream(session, "read", held) }
                return .nothing
            }
            return .part(Plan(session: session, stream: "read", gen: held.gen, from: held.length, bytes: lines,
                              sourceOffset: offset, events: events, conversation: conversation))
        case .gemini, .appChat:
            if moved { held = stream(session, "read"); held.dirty = true; setStream(session, "read", held) }
            guard held.dirty else { return .nothing }
            func settled() { var done = stream(session, "read"); done.dirty = false; setStream(session, "read", done) }
            guard seen.size <= 512 * 1_048_576, let data = BackendCloudChats.read(file, from: 0, count: Int(seen.size)) else { settled(); return .nothing }
            if format == .gemini {
                guard let parsed = BackendCloudChatsReadable.gemini(data) else { settled(); return .nothing }
                let gemConversation = parsed.conversation.isEmpty ? conversation : parsed.conversation
                if Int64(parsed.messages.count) < held.sourceOffset || (held.conversation != nil && held.conversation != gemConversation) {
                    restart(session, "read", source: file.path); held = stream(session, "read")
                }
                var lines = Data(), events = 0
                for message in parsed.messages.dropFirst(Int(held.sourceOffset)) {
                    guard let line = BackendCloudChatsReadable.line(message, conversation: gemConversation, sequence: held.events + events + 1, provider: .gemini) else { continue }
                    if lines.count + line.count > BackendCloudChats.partRawBytes { break }
                    lines.append(line); events += 1
                }
                guard events > 0 else { settled(); return .nothing }
                return .part(Plan(session: session, stream: "read", gen: held.gen, from: held.length, bytes: lines,
                                  sourceOffset: held.sourceOffset + Int64(events), events: events, conversation: gemConversation))
            }
            guard let parsed = BackendCloudChatsReadable.appChat(data) else { settled(); return .nothing }
            let newest = Int64(parsed.events.last?.sequence ?? 0)
            if newest < held.sourceOffset || (held.conversation != nil && held.conversation != parsed.conversation) {
                restart(session, "read", source: file.path); held = stream(session, "read")
            }
            var lines = Data(), events = 0, last = held.sourceOffset
            for event in parsed.events where Int64(event.sequence) > held.sourceOffset {
                if lines.count + event.line.count > BackendCloudChats.partRawBytes { break }
                lines.append(event.line); events += 1; last = Int64(event.sequence)
            }
            guard events > 0 else { settled(); return .nothing }
            return .part(Plan(session: session, stream: "read", gen: held.gen, from: held.length, bytes: lines,
                              sourceOffset: last, events: events, conversation: parsed.conversation))
        }
    }
    /// The byte after the next newline at or after `from` (nil: none before `end`).
    static func nextLine(_ url: URL, from: Int64, end: Int64) -> Int64? {
        var offset = from
        while offset < end {
            guard let bytes = BackendCloudChats.read(url, from: offset, count: min(1_048_576, Int(end - offset))), !bytes.isEmpty else { return nil }
            if let newline = bytes.firstIndex(of: 0x0a) { return offset + Int64(newline - bytes.startIndex) + 1 }
            offset += Int64(bytes.count)
        }
        return nil
    }

    /// A stream's accepted bytes: the service holds them now.
    func commit(_ plan: Plan, have: Int64?) {
        var held = stream(plan.session, plan.stream)
        guard held.gen == plan.gen, held.length == plan.from else { return }
        held.length = have ?? (plan.from + Int64(plan.bytes.count))
        held.tail.append(plan.bytes.count)
        if plan.stream == "read" {
            spoolAppend(plan.session, plan.bytes)
            if let offset = plan.sourceOffset { held.sourceOffset = offset }
            held.events += plan.events
            if let conversation = plan.conversation { held.conversation = conversation }
        } else {
            let tail = plan.bytes.suffix(BackendCloudChats.tailCheckBytes)
            held.tailSha = tail.count == BackendCloudChats.tailCheckBytes || plan.from == 0
                ? BackendCloudChats.hex(Data(tail)) : held.source.flatMap { Self.tailSha(URL(fileURLWithPath: $0), length: held.length) }
        }
        held.grewAt = clock()
        setStream(plan.session, plan.stream, held)
    }

    // MARK: The live tick

    /// One look at every listed session (about every 30 s): ONE call carries this Mac's list when it changed (at most
    /// every 15 s, and once at launch) and every stream's new bytes; then tails due are closed and quiet app chats'
    /// files go up. Nothing grew and the list is the same: nothing is sent.
    public func round(_ listed: [BackendCloudChats.Listed]) async -> Outcome {
        guard !missing else { return .missing }
        guard !full else { return .later }
        await resume()
        guard !missing else { return .missing }
        for session in needsHead { await refreshHead(session) }
        let now = clock()
        if let pending = pendingTick {
            // The last tick's answer was lost: the same tick again (the service answers it once, never stores twice).
            pendingTick = nil
            return await sendTick(pending.body, plans: pending.plans, list: pending.list, introduce: pending.introduce, close: pending.close)
        }
        // Earlier chats waiting to be introduced ride along with this Mac's list, a batch at a time; the ones introduced
        // by the last put are left out of this one, which makes them closed sessions' chats on the service.
        let introduce = state.archive.values.filter { $0.stage == .waiting }.sorted { $0.row.lastUsedAt > $1.row.lastUsedAt }
            .prefix(Self.archiveBatch).map(\.row)
        let closing = state.archive.filter { $0.value.stage == .introduced }.map(\.key)
        let rows = listed.map(\.row) + introduce
        let fingerprint = BackendCloudChats.fingerprint(rows)
        let listDue = fingerprint != state.listFingerprint && now - state.listAt >= BackendCloudChats.listEveryMs
        var plans: [(plan: Plan, gz: String)] = [], closeNow: [(String, String)] = [], budget = BackendCloudChats.tickBodyBytes
        var total: Int64 = 0
        enum Job { case read, file(String, URL, Int64) }
        for item in listed {
            let id = item.row.sessionId
            let session = state.sessions[id] ?? Session()
            guard !session.binned, !session.notYours else { continue }
            var jobs: [(String, Job)] = []
            if item.source.readable != nil { jobs.append(("read", .read)) }
            if let raw = item.source.raw {
                total += BackendCloudChats.look(raw)?.size ?? 0
                jobs.append(("raw", .file("raw", raw, item.source.readable == .gemini ? BackendCloudChats.geminiQuietMs : 0)))
            }
            if !session.noTools {
                for tool in item.source.tools { jobs.append(("tool:" + tool.lastPathComponent, .file("tool:" + tool.lastPathComponent, tool, 0))) }
            }
            for (name, job) in jobs where !busy.contains(key(id, name)) {
                let look: Look
                switch job {
                case .read: look = lookRead(id, item, now: now, catchUp: false)
                case .file(let stream, let url, let quiet): look = lookFile(id, stream, url, quietMs: quiet, now: now)
                }
                switch look {
                case .part(let plan):
                    // Each part gzip-compressed on its own; the body stays under the service's 8 MiB a call.
                    guard let gz = BackendCloudChats.gzip(plan.bytes)?.base64EncodedString(), gz.utf8.count + 512 <= budget else { continue }
                    budget -= gz.utf8.count + 512
                    plans.append((plan, gz))
                case .closeNow: closeNow.append((id, name))
                case .nothing, .catchUp: continue
                }
            }
        }
        sourceBytes = total
        var outcome = Outcome.idle
        if !plans.isEmpty || listDue {
            let parts = plans.map { PartBody(session: $0.plan.session, stream: $0.plan.stream, gen: $0.plan.gen, from: $0.plan.from,
                                             rawLen: $0.plan.bytes.count, sha256: BackendCloudChats.hex($0.plan.bytes), gz: $0.gz) }
            let body = TickBody(tickId: UUID().uuidString.lowercased(), sessions: listDue ? rows : nil, parts: parts)
            guard let data = try? JSONEncoder().encode(body) else { return .later }
            outcome = await sendTick(data, plans: plans.map(\.plan), list: listDue ? fingerprint : nil,
                                     introduce: listDue ? introduce.map(\.sessionId) : [], close: listDue ? closing : [])
            if outcome == .missing { return .missing }
        }
        state.listed = listed.count
        // Tails due: 4 MiB raw (1 MiB readable), 64 parts, 10 minutes without growth, or a big addition waiting.
        for item in listed {
            let id = item.row.sessionId
            for (name, held) in state.sessions[id]?.streams ?? [:] where !held.tail.isEmpty && !busy.contains(key(id, name)) {
                let size = held.tail.reduce(0, +)
                let due = size >= (name == "read" ? BackendCloudChats.readPieceBytes : BackendCloudChats.rawPieceBytes)
                    || held.tail.count >= BackendCloudChats.tailPartsMax || now - held.grewAt >= BackendCloudChats.quietCloseMs
                    || closeNow.contains { $0 == (id, name) } || closeSoon.contains(key(id, name))
                if due, await close(id, name, item) { closeSoon.remove(key(id, name)) }
            }
        }
        // Quiet app chats: their saved file, 2 minutes after it last changed.
        for item in listed where item.source.snap != nil {
            await snap(item, now: now)
        }
        save()
        return outcome
    }

    func sendTick(_ data: Data, plans: [Plan], list: String?, introduce: [String] = [], close: [String] = []) async -> Outcome {
        for plan in plans { busy.insert(key(plan.session, plan.stream)) }
        defer { for plan in plans { busy.remove(key(plan.session, plan.stream)) } }
        switch await call("POST", "/chats/tick", data) {
        case .lost:
            pendingTick = (data, plans, list, introduce, close)
            return .later
        case .refused(let status, let code, _):
            if status == 404 { return .missing }
            if code == "chats_full" { full = true }
            return .later
        case .ok(let answer):
            let decoded = try? JSONDecoder().decode(TickAnswer.self, from: answer)
            if let list {
                state.listFingerprint = list; state.listAt = clock()
                for id in decoded?.sessions?.notYours ?? [] { var held = state.sessions[id] ?? Session(); held.notYours = true; state.sessions[id] = held }
                for id in introduce { state.archive[id]?.stage = .introduced }
                for id in close where state.archive[id]?.stage == .introduced { state.archive[id]?.stage = .closed }
                for id in decoded?.sessions?.notYours ?? [] { state.archive[id]?.stage = .done }
            }
            for part in decoded?.parts ?? [] {
                guard let plan = plans.first(where: { $0.session == part.session && $0.stream == part.stream }) else { continue }
                if part.ok == true { commit(plan, have: part.have); continue }
                switch part.code {
                case "chat_offset", "old_gen":
                    if plan.stream == "read" { restart(plan.session, "read", source: stream(plan.session, "read").source, above: part.gen ?? 0) }
                    else { needsHead.insert(plan.session) }
                case "binned": var held = state.sessions[plan.session] ?? Session(); held.binned = true; state.sessions[plan.session] = held
                case "not_yours":
                    var held = state.sessions[plan.session] ?? Session(); held.notYours = true; state.sessions[plan.session] = held
                    movedAway(plan.session, part.movedTo)
                case "too_many_streams": var held = state.sessions[plan.session] ?? Session(); held.noTools = true; state.sessions[plan.session] = held
                case "piece_needed": closeSoon.insert(key(plan.session, plan.stream))
                case "chats_full": full = true
                default: continue // bad_bytes or a code this build does not know: the same bytes are planned again next tick
                }
            }
            save()
            return .sent(parts: plans.count, list: list != nil)
        }
    }

    // MARK: Pieces

    /// Closes a stream's open tail into ONE piece: the tail's bytes again, read from the history (`raw`, `tool:`) or
    /// from the kept tail (`read`). The service then drops the covered tail parts.
    func close(_ session: String, _ name: String, _ item: BackendCloudChats.Listed?) async -> Bool {
        let held = stream(session, name)
        let size = held.tail.reduce(0, +)
        guard size > 0, !busy.contains(key(session, name)) else { return false }
        let bytes: Data?
        if name == "read" {
            bytes = spool(session).flatMap { try? Data(contentsOf: $0) }
            guard bytes?.count == size else {
                // The kept tail is gone (a cleaned folder): the readable copy starts again.
                restart(session, "read", source: held.source); return false
            }
        } else {
            bytes = held.source.flatMap { BackendCloudChats.read(URL(fileURLWithPath: $0), from: held.pieced, count: size) }
            guard bytes?.count == size else { needsHead.insert(session); return false }
        }
        guard let bytes else { return false }
        return await piece(session, name, held: held, bytes: bytes, extra: nil)
    }

    /// One piece call. `extra`: a catch-up piece (no tail), with what the source stands at after it.
    func piece(_ session: String, _ name: String, held: Stream, bytes: Data, extra: Plan?) async -> Bool {
        guard bytes.count <= BackendCloudChats.maximumRawBytes, let gz = BackendCloudChats.gzip(bytes) else { return false }
        let body = PieceBody(session: session, stream: name, gen: held.gen, index: held.pieces, rawFrom: held.pieced, rawLen: bytes.count,
                             sha256: BackendCloudChats.hex(bytes), gz: gz.base64EncodedString())
        guard let data = try? JSONEncoder().encode(body) else { return false }
        busy.insert(key(session, name))
        let answer = await call("POST", "/chats/piece", data)
        busy.remove(key(session, name))
        var now = stream(session, name)
        guard now.gen == held.gen, now.pieces == held.pieces, now.pieced == held.pieced else { return false }
        switch answer {
        case .ok(let reply):
            let decoded = try? JSONDecoder().decode(PieceAnswer.self, from: reply)
            now.pieced = decoded?.pieced ?? (held.pieced + Int64(bytes.count))
            now.pieces = (decoded?.index).map { $0 + 1 } ?? (held.pieces + 1)
            if let extra {
                // A catch-up piece: it appended (no tail existed).
                now.length = decoded?.have ?? now.pieced
                if let offset = extra.sourceOffset { now.sourceOffset = offset }
                now.events += extra.events
                if let conversation = extra.conversation { now.conversation = conversation }
                if name != "read" { now.tailSha = BackendCloudChats.hex(Data(bytes.suffix(BackendCloudChats.tailCheckBytes))) }
            } else {
                now.tail = []
                if name == "read" { spoolClear(session) }
            }
            setStream(session, name, now)
            save()
            return true
        case .refused(_, let code, _):
            switch code {
            case "binned": var s = state.sessions[session] ?? Session(); s.binned = true; state.sessions[session] = s
            case "not_yours": var s = state.sessions[session] ?? Session(); s.notYours = true; state.sessions[session] = s; movedAway(session, nil)
            case "chats_full": full = true
            case "piece_boundary", "piece_mismatch", "chat_offset", "old_gen":
                if name == "read" { restart(session, "read", source: now.source) } else { needsHead.insert(session) }
            default: break
            }
            save()
            return false
        case .lost:
            return false
        }
    }

    // MARK: Catch-up (old histories, in the background)

    /// ONE catch-up piece: the readable copies of every listed session first, then the histories themselves, newest
    /// used first. The caller waits 2 s between steps, at background priority. False: nothing is left to catch up.
    public func catchUpStep(_ listed: [BackendCloudChats.Listed], earlier: Bool = true) async -> Bool {
        guard !missing, !full, headChecked else { return false }
        let now = clock()
        let order = listed.sorted { $0.row.lastUsedAt > $1.row.lastUsedAt }
        for item in order where item.source.readable == .claude || item.source.readable == .codex {
            let id = item.row.sessionId
            guard let session = state.sessions[id], !session.binned, !session.notYours, !busy.contains(key(id, "read")),
                  let file = item.source.raw, let seen = BackendCloudChats.look(file) else { continue }
            let held = stream(id, "read")
            guard held.source == file.path, seen.size - held.sourceOffset > Int64(BackendCloudChats.partRawBytes) else { continue }
            let before = held.sourceOffset
            switch lookRead(id, item, now: now, catchUp: true) {
            case .part(let plan): return await piece(id, "read", held: stream(id, "read"), bytes: plan.bytes, extra: plan)
            case .closeNow: return await close(id, "read", item)
            case .nothing:
                // Read on through tool traffic (nothing to send); the next step goes on from there.
                if stream(id, "read").sourceOffset != before { return true }
            case .catchUp: continue
            }
        }
        for item in order {
            let id = item.row.sessionId
            guard let session = state.sessions[id], !session.binned, !session.notYours else { continue }
            var files: [(String, URL)] = []
            if let raw = item.source.raw, item.source.readable != .gemini { files.append(("raw", raw)) }
            for tool in item.source.tools where !session.noTools { files.append(("tool:" + tool.lastPathComponent, tool)) }
            for (name, url) in files where !busy.contains(key(id, name)) {
                let held = stream(id, name)
                guard held.source == url.path, let seen = BackendCloudChats.look(url), seen.size - held.length > Int64(BackendCloudChats.partRawBytes) else { continue }
                if !held.tail.isEmpty { return await close(id, name, item) }
                let count = BackendCloudChats.rawPieceBytes
                guard let bytes = BackendCloudChats.read(url, from: held.length, count: count), bytes.count == count else { continue }
                // The tail check needs the length the service holds to keep matching the file.
                return await piece(id, name, held: held, bytes: bytes, extra: Plan(session: id, stream: name, gen: held.gen, from: held.length, bytes: Data()))
            }
        }
        // Then the earlier chats (Terminal Deck's own past sessions), newest first, once each is a closed session's.
        guard earlier else { return false }
        let closed = state.archive.values.filter { $0.stage == .closed }.sorted { $0.row.lastUsedAt > $1.row.lastUsedAt }
        for entry in closed {
            if let sent = await archivedStep(entry.listed) { return sent }
            state.archive[entry.row.sessionId]?.stage = .done
            save()
        }
        return false
    }

    /// One piece of an earlier chat: its readable copy first, then the history; the whole history goes as pieces (no
    /// tick, it does not grow any more), the last one shorter. nil: nothing left of it.
    func archivedStep(_ item: BackendCloudChats.Listed) async -> Bool? {
        let id = item.row.sessionId, now = clock()
        let session = state.sessions[id] ?? Session()
        guard !session.binned, !session.notYours else { return nil }
        if item.source.readable != nil, !busy.contains(key(id, "read")) {
            let before = stream(id, "read")
            switch lookRead(id, item, now: now, catchUp: true) {
            case .part(let plan): return await piece(id, "read", held: stream(id, "read"), bytes: plan.bytes, extra: plan)
            case .closeNow: return await close(id, "read", item)
            case .nothing:
                let after = stream(id, "read")
                if after.sourceOffset != before.sourceOffset || after.gen != before.gen { return true }
            case .catchUp: break
            }
        }
        if let raw = item.source.raw, !busy.contains(key(id, "raw")) {
            switch lookFile(id, "raw", raw, now: now) {
            case .part(let plan): return await piece(id, "raw", held: stream(id, "raw"), bytes: plan.bytes, extra: plan)
            case .catchUp:
                let held = stream(id, "raw"), count = BackendCloudChats.rawPieceBytes
                guard let bytes = BackendCloudChats.read(raw, from: held.length, count: count), bytes.count == count else { return false }
                return await piece(id, "raw", held: held, bytes: bytes, extra: Plan(session: id, stream: "raw", gen: held.gen, from: held.length, bytes: Data()))
            case .closeNow: return await close(id, "raw", item)
            case .nothing: break
            }
        }
        if item.source.snap != nil, state.sessions[id]?.snapSha == nil { return await snapNow(item) }
        return nil
    }

    /// Earlier chats found on this Mac: each new one (by its file) gets its Cloud id and waits to be introduced.
    /// `salt`: this machine's own id, so two Macs never give one id to two histories.
    public func addArchive(_ found: [BackendCloudChatsArchive.Found], salt: String, projects: [PROJProject]) {
        let known = archiveSkip()
        for item in found where !known.contains(item.path) {
            let id = "hist-" + String(BackendCloudChats.hex(Data((salt + "\n" + item.path).utf8)).prefix(24))
            guard state.archive[id] == nil else { continue }
            state.archive[id] = Archived(found: item, row: BackendCloudChatsArchive.row(item, id: id, projects: projects),
                                         bytes: BackendCloudChats.look(URL(fileURLWithPath: item.path))?.size ?? 0)
        }
        save()
    }
    /// Files already copied (any stream's source) or already known as earlier chats: a scan passes them over.
    public func archiveSkip() -> Set<String> {
        var paths = Set(state.archive.values.map(\.found.path))
        for session in state.sessions.values { for stream in session.streams.values { if let source = stream.source { paths.insert(source) } } }
        return paths
    }

    // MARK: Snapshots of the app's chats

    func snap(_ item: BackendCloudChats.Listed, now: Int64) async {
        let id = item.row.sessionId
        var session = state.sessions[id] ?? Session()
        guard let file = item.source.snap, let seen = BackendCloudChats.look(file), !session.binned, !session.notYours else { return }
        if seen.mtime != session.snapMtime { session.snapMtime = seen.mtime; session.snapChangedAt = now; state.sessions[id] = session; return }
        guard let changed = session.snapChangedAt, now - changed >= BackendCloudChats.snapQuietMs,
              seen.size <= Int64(BackendCloudChats.maximumRawBytes) * 4,
              let raw = BackendCloudChats.read(file, from: 0, count: Int(seen.size)) else { return }
        // Runtime fields (busy, pids, queued messages) stay on this Mac, as the Cloud's chat copies already do (I20).
        let bytes = (try? BackendCloudBrainAppChats.neutralise(file.lastPathComponent, raw)) ?? raw
        let sha = BackendCloudChats.hex(bytes)
        guard sha != session.snapSha else { session.snapChangedAt = nil; state.sessions[id] = session; return }
        // Bigger than one call: the readable copy and the history carry it; the saved file is not sent.
        guard bytes.count <= BackendCloudChats.maximumRawBytes, let gz = BackendCloudChats.gzip(bytes), gz.count <= 6 * 1_048_576,
              let data = try? JSONEncoder().encode(SnapBody(session: id, rawLen: bytes.count, sha256: sha, gz: gz.base64EncodedString())) else {
            session.snapChangedAt = nil; state.sessions[id] = session; return
        }
        switch await call("POST", "/chats/snap", data) {
        case .ok:
            var after = state.sessions[id] ?? Session(); after.snapSha = sha; after.snapChangedAt = nil; state.sessions[id] = after
        case .refused(_, let code, _):
            var after = state.sessions[id] ?? Session()
            if code == "binned" { after.binned = true }
            if code == "not_yours" { after.notYours = true; movedAway(id, nil) }
            if code == "chats_full" { full = true }
            state.sessions[id] = after
        case .lost: break
        }
    }

    /// An earlier app chat's saved file, at once (it is quiet by now). True when something was done with it.
    func snapNow(_ item: BackendCloudChats.Listed) async -> Bool {
        let id = item.row.sessionId
        guard let file = item.source.snap, let seen = BackendCloudChats.look(file), seen.size <= Int64(BackendCloudChats.maximumRawBytes) * 4,
              let raw = BackendCloudChats.read(file, from: 0, count: Int(seen.size)) else { return false }
        let bytes = (try? BackendCloudBrainAppChats.neutralise(file.lastPathComponent, raw)) ?? raw
        let sha = BackendCloudChats.hex(bytes)
        var session = state.sessions[id] ?? Session()
        guard bytes.count <= BackendCloudChats.maximumRawBytes, let gz = BackendCloudChats.gzip(bytes), gz.count <= 6 * 1_048_576,
              let data = try? JSONEncoder().encode(SnapBody(session: id, rawLen: bytes.count, sha256: sha, gz: gz.base64EncodedString())) else {
            // Bigger than one call: its readable copy carries it.
            session.snapSha = sha; state.sessions[id] = session; save(); return true
        }
        guard case .ok = await call("POST", "/chats/snap", data) else { return false }
        var after = state.sessions[id] ?? Session(); after.snapSha = sha; state.sessions[id] = after; save()
        return true
    }

    // MARK: The Bin (by hand only)

    /// The Cloud page's Bin buttons (by the person's own press; no AI tool calls this): `bin` moves a session's chat to
    /// the Bin for 30 days, `restore` brings it back, `remove` removes a binned one now. Closing a session never calls it.
    public func bin(session: String? = nil, ref: String? = nil, action: String) async -> Bool {
        guard ["bin", "restore", "remove"].contains(action), session != nil || ref != nil else { return false }
        var body: [String: String] = ["action": action]
        if let ref { body["ref"] = ref } else if let session { body["session"] = session }
        guard let data = try? JSONEncoder().encode(body), case .ok = await call("POST", "/chats/bin", data) else { return false }
        if let session {
            var held = state.sessions[session] ?? Session()
            held.binned = action == "bin" || action == "remove"
            state.sessions[session] = held
            save()
        }
        return true
    }

    // MARK: Step 2: switching a session to another Mac

    /// The old Mac, after the session was closed: everything its chat added goes up now (big backlogs as pieces, the
    /// rest in ticks that carry no list), then every open tail is closed into a piece. Answers the length the service
    /// holds of each stream's current generation (what `release` names); nil when the session is not this Mac's.
    public func flush(_ item: BackendCloudChats.Listed) async -> [String: Int64]? {
        let id = item.row.sessionId
        await resume()
        guard !missing else { return nil }
        if needsHead.contains(id) { await refreshHead(id) }
        for _ in 0..<10_000 { guard await catchUpStep([item], earlier: false) else { break } }
        for _ in 0..<64 {
            guard state.sessions[id]?.notYours != true, !full else { return nil }
            if let pending = pendingTick {
                pendingTick = nil
                _ = await sendTick(pending.body, plans: pending.plans, list: pending.list, introduce: pending.introduce, close: pending.close)
                continue
            }
            let now = clock()
            var plans: [(plan: Plan, gz: String)] = []
            var jobs: [(String, URL?)] = []
            if item.source.readable != nil { jobs.append(("read", nil)) }
            if let raw = item.source.raw { jobs.append(("raw", raw)) }
            if state.sessions[id]?.noTools != true { for tool in item.source.tools { jobs.append(("tool:" + tool.lastPathComponent, tool)) } }
            for (name, url) in jobs where !busy.contains(key(id, name)) {
                let look = url.map { lookFile(id, name, $0, now: now) } ?? lookRead(id, item, now: now + BackendCloudChats.lineQuietMs, catchUp: false)
                if case .part(let plan) = look, let gz = BackendCloudChats.gzip(plan.bytes)?.base64EncodedString() { plans.append((plan, gz)) }
            }
            guard !plans.isEmpty else { break }
            let parts = plans.map { PartBody(session: $0.plan.session, stream: $0.plan.stream, gen: $0.plan.gen, from: $0.plan.from,
                                             rawLen: $0.plan.bytes.count, sha256: BackendCloudChats.hex($0.plan.bytes), gz: $0.gz) }
            guard let data = try? JSONEncoder().encode(TickBody(tickId: UUID().uuidString.lowercased(), sessions: nil, parts: parts)) else { return nil }
            if await sendTick(data, plans: plans.map(\.plan), list: nil) != .sent(parts: plans.count, list: false) { return nil }
        }
        for (name, held) in state.sessions[id]?.streams ?? [:] where !held.tail.isEmpty { _ = await close(id, name, item) }
        save()
        guard let streams = state.sessions[id]?.streams, state.sessions[id]?.notYours != true else { return nil }
        return streams.mapValues(\.length)
    }

    /// After a session moved away from this Mac while it still ran here: what it holds goes up as this Mac's OWN
    /// session `<id>~left`, "<name> (left on <Mac>)", introduced once and then a closed session's chat (Earlier
    /// chats). The moved session itself is never written to again from here.
    public func keepLeft(_ item: BackendCloudChats.Listed, machine: String) {
        guard let path = (item.source.raw ?? item.source.snap)?.path, let format = item.source.readable else { return }
        let id = item.row.sessionId + "~left"
        let found = BackendCloudChatsArchive.Found(path: path, format: format, provider: item.row.ai ?? item.source.provider?.rawValue ?? "claude",
                                                   conversation: item.row.conversationId, cwd: item.row.cwd,
                                                   name: item.row.name + " (left on " + machine + ")",
                                                   startedAt: item.row.startedAt, lastUsedAt: clock())
        var row = item.row
        row.sessionId = id; row.name = String(found.name.prefix(200)); row.lastUsedAt = clock(); row.status = "ended"; row.codeAt = nil
        let archived = Archived(found: found, row: row, bytes: BackendCloudChats.look(URL(fileURLWithPath: path))?.size ?? 0)
        if let before = state.archive[id], before.found.path == path, before.stage != .done { return }
        state.archive[id] = archived
        state.sessions[id] = nil
        save()
    }

    /// This Mac took the session over: an earlier `not_yours` (it ran elsewhere before) no longer holds it back.
    public func owned(_ sessionId: String) {
        guard var held = state.sessions[sessionId], held.notYours else { return }
        held.notYours = false
        state.sessions[sessionId] = held
        save()
    }

    // MARK: Status

    /// What is held in the Cloud of the histories this Mac lists, against their size here.
    public func progress() -> (listed: Int, held: Int64, total: Int64) {
        let held = state.sessions.values.reduce(Int64(0)) { sum, session in sum + (session.streams["raw"]?.length ?? 0) }
        let earlier = state.archive.values.filter { $0.found.format != .appChat }.reduce(Int64(0)) { $0 + $1.bytes }
        return (state.listed, held, max(sourceBytes + earlier, held))
    }
    /// `cloud.status`'s one line for agents: how many sessions are listed and how far the chat upload is. Read only.
    public func wire() -> NativeRPCValue {
        let progress = progress()
        let percent = progress.total == 0 ? 100 : Int((Double(progress.held) / Double(progress.total) * 100).rounded(.down))
        let line: String
        if missing { line = "Sessions in the Cloud are not live yet" }
        else if progress.held >= progress.total { line = "\(progress.listed) sessions listed; chats are up to date" }
        else { line = "\(progress.listed) sessions listed; chats \(percent)% uploaded (\(Self.size(progress.held)) of \(Self.size(progress.total)))" }
        return .object([.init("listed", .number(Double(progress.listed))), .init("uploadedBytes", .number(Double(progress.held))),
                        .init("historyBytes", .number(Double(progress.total))), .init("percent", .number(Double(percent))),
                        .init("earlierChats", .number(Double(state.archive.count))),
                        .init("earlierChatsDone", .number(Double(state.archive.values.filter { $0.stage == .done }.count))),
                        .init("live", .bool(!missing)), .init("line", .string(line))])
    }
    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

// MARK: Reading the account's sessions (other machines, Earlier chats, a chat's readable copy)

/// The phone routes, which this Mac's side panel reads too (contract §7: `self:false` rows are other machines').
public enum BackendCloudSessionsRead {
    public struct Machine: Decodable, Sendable, Equatable {
        public let ref: String?
        public let name: String?
        public let on: Bool?
        public let listed: Bool?
    }
    public struct Row: Codable, Sendable, Equatable, Identifiable {
        public let ref: String
        public let sessionId: String?
        public let name: String?
        public let lastUsedAt: Double?
        public let project: BackendCloudChats.Project?
        public let ai: String?
        public let kind: String?
        public let status: String?
        public let machine: String?
        public let machineName: String?
        public let machineOn: Bool?
        /// The service's `self`: a session of this very machine.
        public let mine: Bool?
        public let readable: Bool?
        public let closedAt: Double?
        /// Step 2: what the session needs to continue on another Mac (the owner's list row), and its move.
        public var cwd: String?
        public var login: String?
        public var conversationId: String?
        public var startedAt: Double?
        public var codeAt: Int64?
        /// Only while another Mac's ask is open (as-built contract §6).
        public var move: Move?
        /// After a hand-over: the machine it came from, and when.
        public var movedFrom: String?
        public var movedAt: Double?
        public var id: String { ref }
        public struct Move: Codable, Sendable, Equatable {
            public let id: String
            public let to: String?
            public let toName: String?
            public let from: String?
            public let fromName: String?
            public let at: Double?
            public init(id: String, to: String?, toName: String?, from: String?, fromName: String?, at: Double?) {
                self.id = id; self.to = to; self.toName = toName; self.from = from; self.fromName = fromName; self.at = at
            }
        }
        enum CodingKeys: String, CodingKey {
            case ref, sessionId, name, lastUsedAt, project, ai, kind, status, machine, machineName, machineOn, readable, closedAt
            case cwd, login, conversationId, startedAt, codeAt, move, movedFrom, movedAt
            case mine = "self"
        }
        public init(ref: String, name: String, lastUsedAt: Double, project: BackendCloudChats.Project?, ai: String?, kind: String? = nil,
                    status: String? = nil, machineName: String, machineOn: Bool, mine: Bool = false, closedAt: Double? = nil, sessionId: String? = nil) {
            self.ref = ref; self.sessionId = sessionId; self.name = name; self.lastUsedAt = lastUsedAt; self.project = project; self.ai = ai; self.kind = kind
            self.status = status; machine = nil; self.machineName = machineName; self.machineOn = machineOn; self.mine = mine
            readable = true; self.closedAt = closedAt
        }
    }
    public struct Page: Decodable, Sendable {
        public let machines: [Machine]?
        public let sessions: [Row]?
        public let next: String?
    }
    /// One page of a readable copy: its events (an unreadable line comes as null and is left out), where it starts.
    public struct ChatPage: Sendable, Equatable {
        public let gen: Int
        public let total: Int
        public let first: Int
        public let count: Int
        public let events: [HootChatEvent]
        public init(gen: Int, total: Int, first: Int, count: Int, events: [HootChatEvent]) {
            self.gen = gen; self.total = total; self.first = first; self.count = count; self.events = events
        }
        public init?(_ data: Data) {
            guard let value = try? NativeRPCValue.parseJSON(data, maximumBytes: 4 * 1_048_576), value.fields != nil else { return nil }
            let events = (value["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }
            self.init(gen: Int(value["gen"].number ?? 1), total: Int(value["total"].number ?? Double(events.count)),
                      first: Int(value["first"].number ?? 0), count: Int(value["count"].number ?? Double(events.count)), events: events)
        }
    }
    /// The account's sessions, every page (at most 10 pages of 500). `earlier`: the closed sessions whose chat is kept.
    public static func list(_ send: BackendCloudChatsUploader.Send, earlier: Bool) async -> (machines: [Machine], rows: [Row])? {
        var machines: [Machine] = [], rows: [Row] = [], after: String?
        for _ in 0..<10 {
            var path = "/sessions?limit=500" + (earlier ? "&earlier=1" : "")
            if let after, let query = after.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) { path += "&after=" + query }
            guard let answer = try? await send("GET", path, Data()), answer.status == 200,
                  let page = try? JSONDecoder().decode(Page.self, from: answer.data) else { return rows.isEmpty ? nil : (machines, rows) }
            if machines.isEmpty { machines = page.machines ?? [] }
            rows += page.sessions ?? []
            guard let next = page.next, !next.isEmpty else { break }
            after = next
        }
        return (machines, rows)
    }
    /// One page of a session's readable copy: the newest (`before` nil) or the one before event `before`; `after`: new
    /// events since (polling while it is open).
    public static func chat(_ send: BackendCloudChatsUploader.Send, ref: String, before: Int? = nil, after: Int? = nil) async -> ChatPage? {
        guard let query = ref.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) else { return nil }
        var path = "/chats/read?session=" + query
        if let before { path += "&before=\(before)&limit=200" } else if let after { path += "&after=\(after)&limit=200" } else { path += "&last=200" }
        guard let answer = try? await send("GET", path, Data()), answer.status == 200 else { return nil }
        return ChatPage(answer.data)
    }
}
