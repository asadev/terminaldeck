import Foundation
import TerminalDeckNativeCore

/// "Switch to this Mac", step 2 of sessions in the Cloud, the Mac part (owner, 15 Nov 2026: "Every session with the
/// same account should be visible everywhere ... switch it to my MacBook ... always living in the cloud"). Plan and
/// the service's as-built contract: `macos/night/codex/switch-to-this-mac-plan.md` (section 6 wins).
///
/// The service's `owner` of a session is the only truth about which Mac runs it. One route changes it:
/// `POST /v1/sessions/move {ref, action}`: `ask` (this Mac wants it; the service makes the move's id), `wait` (the
/// owner: "busy, a reply is being written"; 2 more minutes each, at most 15 from the ask), `release` (the owner hands
/// it over with the exact lengths the Cloud holds), `take` (the asker: after a release, or the owner off, or 2 minutes
/// without a sign), `cancel`, `look`.
///
/// THIS MAC (the one he clicked on), in order:
/// 1. the AI account first: none for that AI here = nothing is asked, nothing stops anywhere;
/// 2. `ask`; then wait for the old Mac (it finishes a reply, stops, sends its last bytes, backs up and releases);
///    off, or silent for 2 minutes: `take` (the service decides; a reply in progress keeps it waiting by `wait`);
/// 3. only once an answer says `owner.self`: the chat comes down to `last.held` (each piece's sha checked);
/// 4. its own folder is backed up, its own unsaved changes are put aside in Git, the old Mac's exact code is laid in
///    (split histories: on a branch of its own; his branch here untouched);
/// 5. the AI starts resumed through the app's normal launcher, with the same Cloud id, ONCE (a launch id is kept in
///    the journal before it starts).
/// THE OLD MAC: told over the live socket (`sessions`, "look") or by its once-a-minute read; sends `wait` while a
/// reply is being written (up to 10 minutes), closes the session the app's normal way, sends its last bytes, backs up,
/// releases. An old Mac that finds the session moved while it still runs it stops it; what it did there goes up as its
/// OWN session `<id>~left` ("<name> (left on <Mac>)", an Earlier chat) plus its own code backup; nothing is merged by
/// itself. NO session host change: stop = the app's close, start = the app's create.
public enum BackendCloudSessionMoveWire {
    public struct Who: Codable, Sendable, Equatable {
        public var ref: String?
        public var name: String?
        public var mine: Bool?
        enum CodingKeys: String, CodingKey { case ref, name, mine = "self" }
        public init(ref: String?, name: String?, mine: Bool?) { self.ref = ref; self.name = name; self.mine = mine }
    }
    /// An open ask.
    public struct Pending: Codable, Sendable, Equatable {
        public var id: String
        public var to: Who?
        public var from: Who?
        public var at: Int64?
        public var heardAt: Int64?
        public init(id: String, to: Who?, from: Who?, at: Int64?, heardAt: Int64? = nil) {
            self.id = id; self.to = to; self.from = from; self.at = at; self.heardAt = heardAt
        }
    }
    /// What the old Mac sent with its release.
    public struct Release: Codable, Sendable, Equatable {
        public var lengths: [String: Int64]?
        public var codeAt: Int64?
        public var branch: String?
        public var headSha: String?
        public var workSha: String?
        public init(lengths: [String: Int64]? = nil, codeAt: Int64? = nil, branch: String? = nil, headSha: String? = nil, workSha: String? = nil) {
            self.lengths = lengths; self.codeAt = codeAt; self.branch = branch; self.headSha = headSha; self.workSha = workSha
        }
    }
    public struct HeldStream: Codable, Sendable, Equatable {
        public var gen: Int?
        public var length: Int64?
        public init(gen: Int?, length: Int64?) { self.gen = gen; self.length = length }
    }
    /// What the Cloud held when the move was done.
    public struct Held: Codable, Sendable, Equatable {
        public var streams: [String: HeldStream]?
        public var chatAt: Int64?
        public var snapAt: Int64?
        public var codeAt: Int64?
        public init(streams: [String: HeldStream]?, chatAt: Int64? = nil, snapAt: Int64? = nil, codeAt: Int64? = nil) {
            self.streams = streams; self.chatAt = chatAt; self.snapAt = snapAt; self.codeAt = codeAt
        }
    }
    /// The last finished move of the session.
    public struct Done: Codable, Sendable, Equatable {
        public var id: String
        public var from: Who?
        public var to: Who?
        public var at: Int64?
        public var doneAt: Int64?
        public var forced: Bool?
        /// released | off | no_answer
        public var why: String?
        public var release: Release?
        public var held: Held?
        public init(id: String, from: Who?, to: Who?, at: Int64? = nil, doneAt: Int64? = nil, forced: Bool?, why: String?, release: Release?, held: Held?) {
            self.id = id; self.from = from; self.to = to; self.at = at; self.doneAt = doneAt; self.forced = forced; self.why = why
            self.release = release; self.held = held
        }
    }
    /// The route's answer (200 `ok:true`; 409 `ok:false, code` with the same keys).
    public struct Answer: Codable, Sendable, Equatable {
        public var ok: Bool?
        public var code: String?
        public var retryAfterMs: Int64?
        public var ref: String?
        public var sessionId: String?
        public var owner: Who?
        public var move: Pending?
        public var last: Done?
        public var codeAt: Int64?
        /// `release_lengths`: what the Cloud holds now.
        public var held: Held?
        public init(ok: Bool? = true, code: String? = nil, retryAfterMs: Int64? = nil, ref: String?, sessionId: String?, owner: Who?,
                    move: Pending?, last: Done?, codeAt: Int64? = nil, held: Held? = nil) {
            self.ok = ok; self.code = code; self.retryAfterMs = retryAfterMs; self.ref = ref; self.sessionId = sessionId; self.owner = owner
            self.move = move; self.last = last; self.codeAt = codeAt; self.held = held
        }
        public var ownedHere: Bool { owner?.mine == true }
    }
    struct Body: Encodable {
        let ref: String
        let action: String
        var id: String?
        var lengths: [String: Int64]?
        var codeAt: Int64?
        var branch: String?
        var headSha: String?
        var workSha: String?
    }
    struct Failure: Decodable { struct Detail: Decodable { let code: String? }; let error: Detail?; let code: String? }
    /// `GET /chats/raw`: one stored unit of a stream (or `done` past its end).
    struct Raw: Decodable {
        let gen: Int?
        let length: Int64?
        let done: Bool?
        let from: Int64?
        let rawLen: Int?
        let sha256: String?
        let next: Int64?
        let gz: String?
    }
    public enum Outcome: Sendable, Equatable {
        /// 200, or a 409 that carries the state (`answer.code`).
        case answer(Answer)
        /// Any other refusal (404 `not_found`, 403, 400).
        case refused(code: String?)
        case lost
    }
    static func query(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.")))
    }
    /// One call of the move route. `ask` and `look` carry only the ref (the contract refuses any other key).
    public static func call(_ send: BackendCloudChatsUploader.Send, ref: String, action: String, id: String? = nil,
                            release: Release? = nil) async -> Outcome {
        var body = Body(ref: ref, action: action, id: action == "ask" || action == "look" ? nil : id)
        if action == "release" {
            let release = release ?? Release()
            body.lengths = release.lengths ?? [:]; body.codeAt = release.codeAt; body.branch = release.branch
            body.headSha = release.headSha; body.workSha = release.workSha
        }
        guard let data = try? JSONEncoder().encode(body) else { return .lost }
        guard let answered = try? await send("POST", "/sessions/move", data) else { return .lost }
        if (200..<300).contains(answered.status) || answered.status == 409,
           let answer = try? JSONDecoder().decode(Answer.self, from: answered.data), answer.ref != nil || answer.owner != nil {
            return .answer(answer)
        }
        let failure = try? JSONDecoder().decode(Failure.self, from: answered.data)
        return .refused(code: failure?.code ?? failure?.error?.code)
    }
    /// Copies one stream from the Cloud into `file`, appending from what the file already holds (a cut-off download
    /// continues), every unit's bytes checked against its sha. Answers the length held here, or nil when it stopped.
    public static func download(_ send: BackendCloudChatsUploader.Send, ref: String, stream: String, gen: Int?, into file: URL)
        async -> (length: Int64, gen: Int?)? {
        guard let session = query(ref), let name = query(stream) else { return nil }
        let manager = FileManager.default
        try? manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !manager.fileExists(atPath: file.path) { guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return nil } }
        guard let handle = try? FileHandle(forWritingTo: file) else { return nil }
        defer { try? handle.close() }
        var offset = Int64((try? handle.seekToEnd()) ?? 0)
        var generation = gen
        for _ in 0..<200_000 {
            var path = "/chats/raw?session=\(session)&stream=\(name)&from=\(offset)"
            if let generation { path += "&gen=\(generation)" }
            guard let answered = try? await send("GET", path, Data()), answered.status == 200,
                  let raw = try? JSONDecoder().decode(Raw.self, from: answered.data) else { return nil }
            if generation == nil { generation = raw.gen }
            if raw.done == true { return (offset, generation) }
            guard let gz = raw.gz.flatMap({ Data(base64Encoded: $0) }), let from = raw.from, let count = raw.rawLen,
                  let bytes = BackendCloudChats.gunzip(gz, limit: max(count, 1)), bytes.count == count,
                  BackendCloudChats.hex(bytes) == raw.sha256, from <= offset, offset - from <= Int64(count) else { return nil }
            let fresh = bytes.dropFirst(Int(offset - from))
            do { try handle.write(contentsOf: fresh) } catch { return nil }
            offset += Int64(fresh.count)
            if fresh.isEmpty { return (offset, generation) }
        }
        return nil
    }
}

// MARK: The journal (`<data>/cloud-moves.json`): a crash half-way resumes the step it was on.

public struct BackendCloudSessionMoveEntry: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case taker, giver, stopped }
    public enum Step: String, Codable, Sendable {
        /// Taker: asked and waiting; then the service named this Mac the owner; chat; code; launching.
        case asked, owner, chat, code, launching
        /// Giver (and a woken old Mac): waiting for the reply to end, then stopping and releasing.
        case waiting, releasing
        case done, cancelled, failed
    }
    public var ref: String
    public var sessionId: String
    public var role: Role
    public var step: Step
    public var moveId: String
    /// The other machine's name ("MacBook Air").
    public var other: String
    public var startedAt: Int64
    /// Taker: the finished move as the service answered it (forced or released, what it held).
    public var last: BackendCloudSessionMoveWire.Done?
    public var codeAt: Int64?
    public var rawGen: Int?
    /// Set BEFORE the AI starts; the started session's id after. Never two launches for one move.
    public var launchId: String?
    public var launchedID: String?
    public var line: String?
    public var lineAt: Int64?
    public var cancelAsked = false
    /// The code step's stash name and his commit while it runs (cleared at its end): a crash in it is undone next start.
    public var codePending: BackendCodeBackupTakeCode.Pending?
    public init(ref: String, sessionId: String, role: Role, step: Step, moveId: String, other: String, startedAt: Int64) {
        self.ref = ref; self.sessionId = sessionId; self.role = role; self.step = step; self.moveId = moveId; self.other = other
        self.startedAt = startedAt
    }
    public var finished: Bool { [.done, .cancelled, .failed].contains(step) }
    public var forced: Bool { last?.forced == true }
}

// MARK: The machines

public actor BackendCloudSessionMove {
    /// One session of this Mac, as the side panel lists it (fresh at each look).
    public struct Local: Sendable, Equatable {
        public var id: String
        public var sessionId: String
        /// "running" (a reply in progress), "needsYou", "idle", "ended".
        public var status: String
        public var kind: String
        public var cwd: String
        public var provider: String?
        public var conversationId: String?
        public var projectID: String?
        public var name: String
        public init(id: String, sessionId: String, status: String, kind: String, cwd: String, provider: String?, conversationId: String?,
                    projectID: String?, name: String) {
            self.id = id; self.sessionId = sessionId; self.status = status; self.kind = kind; self.cwd = cwd; self.provider = provider
            self.conversationId = conversationId; self.projectID = projectID; self.name = name
        }
    }
    /// The AI account this Mac would continue with: the same login, another of the same AI, or none (nothing stops).
    public enum Account: Sendable, Equatable {
        case same(profileID: String?, home: String)
        case other(profileID: String?, name: String, home: String)
        case none
    }
    /// What the old Mac's code backup named for the hand-over.
    public struct CodeHandOver: Sendable, Equatable {
        public var ok: Bool
        public var codeAt: Int64?
        public var branch: String?
        public var headSha: String?
        public var workSha: String?
        public init(ok: Bool, codeAt: Int64?, branch: String?, headSha: String?, workSha: String?) {
            self.ok = ok; self.codeAt = codeAt; self.branch = branch; self.headSha = headSha; self.workSha = workSha
        }
    }
    /// Where the project lives on this Mac (made from his Cloud project when it was not here).
    public struct Folder: Sendable, Equatable {
        public var path: String
        public var projectID: String?
        /// The folder was made just now (nothing of his was in it).
        public var made: Bool
        public init(path: String, projectID: String?, made: Bool) { self.path = path; self.projectID = projectID; self.made = made }
    }
    public struct TakeRequest: Sendable, Equatable {
        public var folder: Folder
        public var named: BackendCodeBackupTakeCode.Named
        /// A code step stopped half-way earlier (from the journal): undone first.
        public var pending: BackendCodeBackupTakeCode.Pending?
    }
    public typealias CodeRecord = @Sendable (BackendCodeBackupTakeCode.Pending?) async -> Void
    public struct PlaceRequest: Sendable, Equatable {
        public var downloaded: URL
        public var tools: [String: URL]
        public var provider: String
        public var conversationId: String
        public var oldCwd: String
        public var newCwd: String
        public var home: String
        public var startedAt: Int64
    }
    public struct LaunchRequest: Sendable, Equatable {
        public var launchId: String
        public var sessionId: String
        public var name: String
        public var cwd: String
        public var provider: String
        public var terminal: Bool
        public var chat: Bool
        public var profileID: String?
        public var conversationId: String?
        public var projectID: String?
    }
    public struct Ports: Sendable {
        public var send: BackendCloudChatsUploader.Send
        /// A fresh read of one of the account's sessions (`/v1/sessions`).
        public var row: @Sendable (_ ref: String) async -> BackendCloudSessionsRead.Row?
        public var local: @Sendable (_ sessionId: String) async -> Local?
        public var close: @Sendable (_ localID: String) async throws -> Void
        /// Everything the session's chat added goes up and every open tail is closed; the lengths the service holds of
        /// each stream's current generation (what `release` names).
        public var flush: @Sendable (_ local: Local) async -> [String: Int64]?
        /// After the move: this Mac's copy of the chat goes up as its OWN session `<id>~left`, "<name> (left on <Mac>)".
        public var keepLeft: @Sendable (_ local: Local) async -> Void
        public var handOver: @Sendable (_ projectID: String?, _ folder: String) async -> CodeHandOver?
        /// This Mac's own folder backed up (true: done or nothing to do).
        public var ownBackup: @Sendable (_ projectID: String?, _ folder: String) async -> Bool
        public var folder: @Sendable (_ row: BackendCloudSessionsRead.Row) async -> Folder?
        /// `record`: the code step's stash name and his commit, written into the journal BEFORE anything changes.
        public var takeCode: @Sendable (_ request: TakeRequest, _ record: @escaping CodeRecord) async -> BackendCodeBackupTakeCode.Result
        public var account: @Sendable (_ provider: String, _ login: String?) async -> Account
        public var place: @Sendable (_ request: PlaceRequest) async throws -> Void
        public var launch: @Sendable (_ request: LaunchRequest) async throws -> String
        public var changed: @Sendable (_ entry: BackendCloudSessionMoveEntry) async -> Void
        public var sleep: @Sendable (_ milliseconds: Int) async throws -> Void
        public var now: @Sendable () -> Int64
        public init(send: @escaping BackendCloudChatsUploader.Send,
                    row: @escaping @Sendable (String) async -> BackendCloudSessionsRead.Row?, local: @escaping @Sendable (String) async -> Local?,
                    close: @escaping @Sendable (String) async throws -> Void, flush: @escaping @Sendable (Local) async -> [String: Int64]?,
                    keepLeft: @escaping @Sendable (Local) async -> Void, handOver: @escaping @Sendable (String?, String) async -> CodeHandOver?,
                    ownBackup: @escaping @Sendable (String?, String) async -> Bool, folder: @escaping @Sendable (BackendCloudSessionsRead.Row) async -> Folder?,
                    takeCode: @escaping @Sendable (TakeRequest, @escaping CodeRecord) async -> BackendCodeBackupTakeCode.Result,
                    account: @escaping @Sendable (String, String?) async -> Account, place: @escaping @Sendable (PlaceRequest) async throws -> Void,
                    launch: @escaping @Sendable (LaunchRequest) async throws -> String,
                    changed: @escaping @Sendable (BackendCloudSessionMoveEntry) async -> Void = { _ in },
                    sleep: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64(max(0, $0)) * 1_000_000) },
                    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
            self.send = send; self.row = row; self.local = local; self.close = close; self.flush = flush
            self.keepLeft = keepLeft; self.handOver = handOver; self.ownBackup = ownBackup; self.folder = folder
            self.takeCode = takeCode; self.account = account; self.place = place; self.launch = launch; self.changed = changed
            self.sleep = sleep; self.now = now
        }
    }

    /// Decided (lead, 15 Nov): a reply still being written on the old Mac is waited for up to 10 minutes.
    public static let replyWaitMs: Int64 = 600_000
    /// The old Mac says `wait` at least this often while busy (the contract: at least every 60 s).
    public static let waitEveryMs: Int64 = 45_000
    /// The taker looks every 3 s and asks to take every 15 s (the service says when it may).
    public static let lookMs = 3_000
    public static let takeEveryMs: Int64 = 15_000
    /// Past 15 minutes from the ask the service refuses `wait`; the taker gives up looking a little after.
    public static let giveUpMs: Int64 = 16 * 60_000
    /// A release refused for lengths is sent again after the rest went up, this many times.
    public static let releaseTries = 5

    let ports: Ports
    let file: URL?
    let directory: URL?
    public private(set) var entries: [String: BackendCloudSessionMoveEntry] = [:]
    private var running: Set<String> = []
    /// Tests drive each step themselves (`driveForTesting`); the app runs them in the background.
    let autoStart: Bool

    /// `file`: `<data>/cloud-moves.json`; the chat comes down into `<data>/cloud-moves/`.
    public init(ports: Ports, file: URL?, autoStart: Bool = true) {
        self.ports = ports
        self.file = file
        self.autoStart = autoStart
        directory = file?.deletingLastPathComponent().appendingPathComponent("cloud-moves", isDirectory: true)
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: BackendCloudSessionMoveEntry].self, from: data) {
            entries = saved
        }
    }

    func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
    func set(_ entry: BackendCloudSessionMoveEntry) async {
        entries[entry.ref] = entry
        save()
        await ports.changed(entry)
    }
    func say(_ entry: inout BackendCloudSessionMoveEntry, _ line: String?) async {
        entry.line = line; entry.lineAt = ports.now()
        await set(entry)
    }
    public func entry(ref: String) -> BackendCloudSessionMoveEntry? { entries[ref] }
    public func entry(sessionId: String) -> BackendCloudSessionMoveEntry? {
        entries.values.filter { $0.sessionId == sessionId }.max { $0.startedAt < $1.startedAt }
    }

    // MARK: This Mac takes it

    /// The button (and the tool): starts the move and returns at once with the first line; the rest runs on.
    @discardableResult
    public func switchHere(ref: String) async -> String {
        if let current = entries[ref], !current.finished, current.role == .taker { return current.line ?? BackendCloudSessionMoveWords.moving(current.other) }
        guard let row = await ports.row(ref) else { return BackendCloudSessionMoveWords.notFound }
        if row.mine == true { return BackendCloudSessionMoveWords.alreadyHere }
        if row.closedAt != nil { return BackendCloudSessionMoveWords.earlier }
        let other = BackendCloudSessionMoveWords.machine(row.machineName)
        let terminal = BackendCloudSessionMoveWords.isTerminal(row)
        // 1. The AI account first: with none for that AI here, nothing is asked and nothing stops anywhere.
        if !terminal, case .none = await ports.account(row.ai ?? "claude", row.login) {
            return BackendCloudSessionMoveWords.signIn(row.ai)
        }
        let answer: BackendCloudSessionMoveWire.Answer
        switch await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "ask") {
        case .lost: return BackendCloudSessionMoveWords.noAnswer
        case .refused(let code): return BackendCloudSessionMoveWords.refused(code, other: other)
        case .answer(let got): answer = got
        }
        if answer.code == "move_busy" { return BackendCloudSessionMoveWords.refused("move_busy", other: answer.move?.to?.name ?? "another Mac") }
        if answer.ownedHere, answer.move == nil { return BackendCloudSessionMoveWords.alreadyHere }
        guard let move = answer.move, move.to?.mine == true else { return BackendCloudSessionMoveWords.refused(answer.code, other: other) }
        var entry = BackendCloudSessionMoveEntry(ref: ref, sessionId: answer.sessionId ?? row.sessionId ?? ref, role: .taker, step: .asked,
                                                 moveId: move.id, other: BackendCloudSessionMoveWords.machine(move.from?.name ?? row.machineName),
                                                 startedAt: move.at ?? ports.now())
        await say(&entry, BackendCloudSessionMoveWords.moving(entry.other))
        start(ref)
        return entry.line ?? ""
    }
    /// Cancel: before the service names this Mac the owner, the move is called off and nothing changed anywhere (the
    /// old Mac keeps running it). After that the old Mac has already stopped: the move finishes here.
    @discardableResult
    public func cancel(ref: String) async -> String {
        guard var entry = entries[ref], !entry.finished, entry.role == .taker else { return BackendCloudSessionMoveWords.nothingToCancel }
        guard entry.step == .asked else { return BackendCloudSessionMoveWords.tooLateToCancel }
        if running.contains(ref) {
            entry.cancelAsked = true
            await set(entry)
            return BackendCloudSessionMoveWords.cancelled
        }
        return await cancelNow(&entry)
    }
    @discardableResult
    func cancelNow(_ entry: inout BackendCloudSessionMoveEntry) async -> String {
        switch await BackendCloudSessionMoveWire.call(ports.send, ref: entry.ref, action: "cancel", id: entry.moveId) {
        case .answer(let answer) where answer.code == "move_done" || answer.ownedHere:
            // Too late: it was handed over meanwhile. The move finishes here (nothing is half-done).
            entry.cancelAsked = false; entry.last = answer.last; entry.codeAt = answer.codeAt; entry.step = .owner
            await set(entry)
            start(entry.ref)
            return BackendCloudSessionMoveWords.tooLateToCancel
        case .answer:
            entry.step = .cancelled
            await say(&entry, BackendCloudSessionMoveWords.cancelled)
            return BackendCloudSessionMoveWords.cancelled
        case .refused, .lost:
            entry.cancelAsked = false
            await set(entry)
            return BackendCloudSessionMoveWords.noAnswer
        }
    }

    /// Runs (or resumes) one move's remaining steps, one run at a time per session.
    func start(_ ref: String) {
        guard autoStart, !running.contains(ref) else { return }
        running.insert(ref)
        Task { await self.drive(ref); self.finish(ref) }
    }
    func finish(_ ref: String) { running.remove(ref) }

    /// After a launch or a crash: every unfinished move goes on from the step it was on.
    public func resume() {
        for (ref, entry) in entries where !entry.finished { start(ref) }
    }

    /// For tests: runs the remaining steps here and returns when they are over.
    public func driveForTesting(_ ref: String) async {
        running.insert(ref)
        await drive(ref)
        running.remove(ref)
    }

    func drive(_ ref: String) async {
        guard let entry = entries[ref] else { return }
        switch entry.role {
        case .taker: await take(ref)
        case .giver: await give(ref)
        case .stopped: await stopWoken(ref)
        }
    }

    func take(_ ref: String) async {
        guard var entry = entries[ref] else { return }
        if entry.step == .asked {
            // 2. Waiting for the old Mac; the service decides when a take is allowed.
            var triedAt: Int64 = 0
            while entry.step == .asked {
                if entries[ref]?.cancelAsked == true { await cancelNow(&entry); return }
                guard case .answer(let look) = await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "look") else {
                    do { try await ports.sleep(Self.lookMs) } catch { return }
                    continue
                }
                if look.ownedHere, let last = look.last, last.id == entry.moveId {
                    entry.last = last; entry.codeAt = look.codeAt; entry.step = .owner; break
                }
                if look.move?.id != entry.moveId {
                    // The ask is gone (cancelled by the old Mac's side, or the session moved elsewhere): nothing changed here.
                    entry.step = .cancelled
                    await say(&entry, BackendCloudSessionMoveWords.notMoved(entry.other)); return
                }
                let now = ports.now()
                if now - triedAt >= Self.takeEveryMs {
                    triedAt = now
                    if case .answer(let taken) = await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "take", id: entry.moveId) {
                        if taken.ownedHere, let last = taken.last, last.id == entry.moveId {
                            entry.last = last; entry.codeAt = taken.codeAt; entry.step = .owner; break
                        }
                        if taken.code == "move_changed" { continue }
                    }
                }
                if now - entry.startedAt > Self.giveUpMs {
                    await cancelNow(&entry); return
                }
                // A `wait` from the old Mac (heardAt) means a reply is being written there.
                let replying = (look.move?.heardAt ?? 0) > (look.move?.at ?? .max)
                let line = replying ? BackendCloudSessionMoveWords.replying(entry.other) : BackendCloudSessionMoveWords.moving(entry.other)
                if entry.line != line { await say(&entry, line) }
                do { try await ports.sleep(Self.lookMs) } catch { return }
            }
            await set(entry)
        }
        guard let row = await ports.row(ref) else { await fail(&entry, BackendCloudSessionMoveWords.noAnswer, keep: true); return }
        let terminal = BackendCloudSessionMoveWords.isTerminal(row)
        var account = BackendCloudSessionMove.Account.none
        if !terminal {
            account = await ports.account(row.ai ?? "claude", row.login)
            if case .none = account { await fail(&entry, BackendCloudSessionMoveWords.signIn(row.ai), keep: true); return }
        }
        // 3. The chat: what the Cloud held when it was handed over (or taken), never less.
        var raw: URL?, tools: [String: URL] = [:]
        let held = entry.last?.held?.streams ?? [:]
        if !terminal, entry.step == .owner || entry.step == .chat {
            entry.step = .chat; await set(entry)
            guard let folder = moveFolder(ref) else { await fail(&entry, BackendCloudSessionMoveWords.noAnswer, keep: true); return }
            if let wanted = held["raw"], (wanted.length ?? 0) > 0 {
                let file = folder.appendingPathComponent("raw")
                guard let got = await BackendCloudSessionMoveWire.download(ports.send, ref: ref, stream: "raw", gen: wanted.gen ?? entry.rawGen, into: file),
                      got.length >= (wanted.length ?? 0) else {
                    await fail(&entry, BackendCloudSessionMoveWords.chatNotHeld, keep: true); return
                }
                entry.rawGen = got.gen
                raw = file
            }
            for (stream, wanted) in held.sorted(by: { $0.key < $1.key }) where stream.hasPrefix("tool:") {
                let name = String(stream.dropFirst(5))
                guard name.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil, !name.hasPrefix(".") else { continue }
                let tool = folder.appendingPathComponent("tools", isDirectory: true).appendingPathComponent(name)
                if let got = await BackendCloudSessionMoveWire.download(ports.send, ref: ref, stream: stream, gen: wanted.gen, into: tool),
                   got.length >= (wanted.length ?? 0) { tools[name] = tool }
            }
            entry.step = .code; await set(entry)
        } else if entry.step == .owner { entry.step = .code; await set(entry) }
        if raw == nil, !terminal, let folder = moveFolder(ref), FileManager.default.fileExists(atPath: folder.appendingPathComponent("raw").path) {
            raw = folder.appendingPathComponent("raw")
        }
        // 4. The code: this Mac's own folder backed up, its own changes put aside in Git, the old Mac's code laid in.
        var code: BackendCodeBackupTakeCode.Result?
        let place = await ports.folder(row)
        if entry.step == .code {
            if let place {
                if !place.made { _ = await ports.ownBackup(place.projectID, place.path) }
                let release = entry.last?.release
                let named = BackendCodeBackupTakeCode.Named(branch: release?.branch, headSha: release?.headSha, workSha: release?.workSha,
                                                            fromMac: entry.other, codeAt: entry.codeAt ?? release?.codeAt ?? row.codeAt)
                code = await ports.takeCode(.init(folder: place, named: named, pending: entry.codePending)) { pending in
                    await self.recordCode(ref, pending)
                }
                entry.codePending = entries[ref]?.codePending
            }
            entry.step = .launching; await set(entry)
        }
        // 5. The AI resumed through the app's normal launcher, ONCE.
        guard entry.step == .launching else { return }
        if entry.launchedID == nil {
            if entry.launchId != nil, let already = await ports.local(entry.sessionId) {
                entry.launchedID = already.id
            } else {
                let cwd = place?.path ?? row.cwd ?? NSHomeDirectory()
                var profileID: String?
                switch account {
                case .same(let id, let home), .other(let id, _, let home):
                    profileID = id
                    if let raw, let conversation = row.conversationId {
                        do {
                            try await ports.place(.init(downloaded: raw, tools: tools, provider: row.ai ?? "claude", conversationId: conversation,
                                                        oldCwd: row.cwd ?? cwd, newCwd: cwd, home: home,
                                                        startedAt: Int64(row.startedAt ?? row.lastUsedAt ?? 0)))
                        } catch { await fail(&entry, BackendCloudSessionMoveWords.chatNotPlaced, keep: true); return }
                    }
                case .none: break
                }
                entry.launchId = entry.launchId ?? UUID().uuidString.lowercased()
                await set(entry)
                let request = LaunchRequest(launchId: entry.launchId!, sessionId: entry.sessionId, name: row.name ?? "Session", cwd: cwd,
                                            provider: terminal ? "shell" : (row.ai ?? "claude"), terminal: terminal,
                                            chat: row.kind == "chat", profileID: profileID,
                                            conversationId: terminal ? nil : row.conversationId, projectID: place?.projectID)
                do { entry.launchedID = try await ports.launch(request) }
                catch { await fail(&entry, BackendCloudSessionMoveWords.notStarted, keep: true); return }
            }
        }
        entry.step = .done
        await say(&entry, BackendCloudSessionMoveWords.moved(entry: entry, row: row, terminal: terminal, account: account, code: code, folder: place))
        if let folder = moveFolder(ref) { try? FileManager.default.removeItem(at: folder) }
    }

    /// The code step's own record, saved at once (the stash is made only after this returns).
    func recordCode(_ ref: String, _ pending: BackendCodeBackupTakeCode.Pending?) async {
        guard var entry = entries[ref] else { return }
        entry.codePending = pending
        await set(entry)
    }

    /// `keep`: the move stays in the journal at its step and is tried again at the next launch (this Mac owns it).
    func fail(_ entry: inout BackendCloudSessionMoveEntry, _ line: String, keep: Bool = false) async {
        if !keep { entry.step = .failed }
        await say(&entry, line)
    }
    func moveFolder(_ ref: String) -> URL? {
        directory?.appendingPathComponent(String(BackendCloudChats.hex(Data(ref.utf8)).prefix(24)), isDirectory: true)
    }

    // MARK: The old Mac hands it over

    /// The socket's `sessions` hint or the minute's read: the session may have an open ask. `look` says.
    public func hint(ref: String) async {
        if let current = entries[ref], !current.finished { start(ref); return }
        guard case .answer(let look) = await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "look") else { return }
        guard look.ownedHere, let move = look.move, move.to?.mine != true else { return }
        if let current = entries[ref], current.moveId == move.id { return }
        let entry = BackendCloudSessionMoveEntry(ref: ref, sessionId: look.sessionId ?? ref, role: .giver, step: .waiting, moveId: move.id,
                                                 other: BackendCloudSessionMoveWords.machine(move.to?.name), startedAt: ports.now())
        await set(entry)
        start(ref)
    }

    func give(_ ref: String) async {
        guard var entry = entries[ref] else { return }
        var local = await ports.local(entry.sessionId)
        if entry.step == .waiting {
            // R3: a reply being written finishes first (up to 10 minutes), the service told by `wait` so the other Mac
            // does not take it half-way; a cancel from the other Mac ends the wait and nothing stops here.
            var saidAt: Int64 = 0
            while let now = local, now.status == "running", ports.now() - entry.startedAt < Self.replyWaitMs {
                if ports.now() - saidAt >= Self.waitEveryMs {
                    saidAt = ports.now()
                    if case .answer(let answer) = await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "wait", id: entry.moveId),
                       answer.code == "move_changed" {
                        if answer.ownedHere { entry.step = .cancelled; await say(&entry, nil); return }
                        // Taken already: this copy stops and keeps what it did.
                        entry.role = .stopped; await set(entry); await stopWoken(ref); return
                    }
                }
                do { try await ports.sleep(Self.lookMs) } catch { return }
                local = await ports.local(entry.sessionId)
            }
            if case .answer(let look) = await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "look"), look.move?.id != entry.moveId {
                if look.ownedHere { entry.step = .cancelled; await say(&entry, nil); return }
                entry.role = .stopped; await set(entry); await stopWoken(ref); return
            }
            if local != nil { _ = await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "wait", id: entry.moveId) }
            entry.step = .releasing; await set(entry)
        }
        guard entry.step == .releasing else { return }
        var release = BackendCloudSessionMoveWire.Release(lengths: [:])
        if let session = local {
            // The app's own close (never the host directly), then its last bytes, then the code backup.
            try? await ports.close(session.id)
            release.lengths = await ports.flush(session) ?? [:]
            _ = await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "wait", id: entry.moveId)
            if let code = await ports.handOver(session.projectID, session.cwd) {
                release.codeAt = code.codeAt; release.branch = code.branch; release.headSha = code.headSha; release.workSha = code.workSha
            }
        }
        for _ in 0..<Self.releaseTries {
            switch await BackendCloudSessionMoveWire.call(ports.send, ref: ref, action: "release", id: entry.moveId, release: release) {
            case .answer(let answer) where answer.code == nil && !answer.ownedHere:
                entry.step = .done
                await say(&entry, BackendCloudSessionMoveWords.handedOver(entry.other))
                return
            case .answer(let answer) where answer.code == "release_lengths":
                // The Cloud does not hold exactly what was named: the rest goes up, then the release again.
                let before = release.lengths ?? [:]
                if let session = local, let lengths = await ports.flush(session) { release.lengths = lengths }
                if release.lengths == before {
                    // No progress: where the Cloud holds at least as much as this Mac named (or the stream is only the
                    // readable copy, made again from the history), its own length is named. The history itself (`raw`)
                    // is never handed over shorter than this Mac has it.
                    let held = (answer.held?.streams ?? [:]).compactMapValues(\.length)
                    var named = before
                    for (stream, mine) in before {
                        let theirs = held[stream] ?? 0
                        if theirs >= mine || stream != "raw" { named[stream] = theirs }
                    }
                    release.lengths = named
                }
            case .answer(let answer) where answer.code == "move_changed" && !answer.ownedHere:
                // Taken already (this Mac was quiet too long): what it did is kept, never merged by itself.
                if let session = local { await ports.keepLeft(session) }
                entry.step = .done
                await say(&entry, BackendCloudSessionMoveWords.movedAway(entry.other, at: answer.last?.doneAt ?? ports.now()))
                return
            case .answer(let answer) where answer.code == "move_changed":
                // The ask was cancelled after this Mac had stopped the session: it stays stopped here, nothing lost
                // (its chat and code are in the Cloud); he starts it again from the side panel.
                entry.step = .cancelled
                await say(&entry, nil)
                return
            default:
                // Lost, or a refusal this build does not know: the journal keeps the step; tried again at the next hint.
                return
            }
        }
    }

    /// R1: an upload for a session another Mac now owns was answered `not_yours`: the copy here stops by itself
    /// (after a reply in progress) and what it did goes up as its own session (`~left`) plus its own code backup.
    public func movedAway(sessionId: String, to machine: String?) async {
        if let current = entry(sessionId: sessionId) {
            // A move of this session under way here (either side) handles it; a session this Mac has just taken is never
            // stopped by an answer that was on its way before the hand-over.
            if !current.finished { start(current.ref); return }
            if current.role == .taker, current.step == .done, ports.now() - (current.lineAt ?? 0) < 120_000 { return }
        }
        guard await ports.local(sessionId) != nil else { return }
        let ref = "stopped:" + sessionId
        if let done = entries[ref], done.finished, ports.now() - done.startedAt < 60_000 { return }
        let entry = BackendCloudSessionMoveEntry(ref: ref, sessionId: sessionId, role: .stopped, step: .waiting, moveId: UUID().uuidString.lowercased(),
                                                 other: BackendCloudSessionMoveWords.machine(machine), startedAt: ports.now())
        await set(entry)
        start(ref)
    }

    func stopWoken(_ ref: String) async {
        guard var entry = entries[ref] else { return }
        var local = await ports.local(entry.sessionId)
        while let now = local, now.status == "running", ports.now() - entry.startedAt < Self.replyWaitMs {
            do { try await ports.sleep(Self.lookMs) } catch { return }
            local = await ports.local(entry.sessionId)
        }
        if let session = local {
            try? await ports.close(session.id)
            await ports.keepLeft(session)
            _ = await ports.ownBackup(session.projectID, session.cwd)
        }
        entry.step = .done
        await say(&entry, BackendCloudSessionMoveWords.movedAway(entry.other, at: ports.now()))
    }

    /// The tool's `status`: the moves under way and the last line of each. Read only.
    public func wire() -> NativeRPCValue {
        .array(entries.values.sorted { $0.startedAt > $1.startedAt }.prefix(20).map { entry in
            .object([.init("role", .string(entry.role.rawValue)), .init("step", .string(entry.step.rawValue)),
                     .init("otherMachine", .string(entry.other)), .init("line", entry.line.map(NativeRPCValue.string) ?? .null)])
        })
    }
}

// MARK: The words he can meet (each once, as the grey line under the title; never a dialog)

public enum BackendCloudSessionMoveWords {
    public static let button = "Switch to this Mac"
    public static let cancelButton = "Cancel"
    public static let notFound = "This session is not in your Cloud any more."
    public static let alreadyHere = "This session already runs on this Mac."
    public static let earlier = "An earlier chat is kept in your Cloud; it does not run anywhere to move."
    public static let noAnswer = "Your Cloud did not answer; nothing moved. Try again in a moment."
    public static let nothingToCancel = "Nothing is moving."
    public static let tooLateToCancel = "The other Mac has already stopped it; the move finishes here."
    public static let cancelled = "Not moved. It runs where it was."
    public static let chatNotHeld = "The chat is still coming down from your Cloud; the move goes on by itself."
    public static let chatNotPlaced = "The chat could not be put in place here; it is tried again."
    public static let notStarted = "The session could not start here; it is tried again."

    static func machine(_ name: String?) -> String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "the other Mac" : trimmed
    }
    static func isTerminal(_ row: BackendCloudSessionsRead.Row) -> Bool {
        row.kind == "terminal" || row.ai == nil || row.ai == "shell"
    }
    static func aiName(_ ai: String?) -> String {
        switch ai {
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        default: return "Claude"
        }
    }
    public static func moving(_ other: String) -> String { "Moving from \(other)…" }
    public static func replying(_ other: String) -> String { "\(other) is finishing its reply; it moves when the reply is done." }
    public static func signIn(_ ai: String?) -> String { "Sign in to \(aiName(ai)) on this Mac to move this chat." }
    public static func notMoved(_ other: String) -> String { "Not moved. It runs on \(other) as before." }
    public static func refused(_ code: String?, other: String) -> String {
        switch code {
        case "move_busy": return "This session is already moving to \(other)."
        case "not_found": return notFound
        default: return noAnswer
        }
    }
    public static func handedOver(_ to: String) -> String { "Moved to \(to). Its code was backed up first." }
    static func clock(_ at: Int64) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(at) / 1000))
    }
    public static func movedAway(_ to: String, at: Int64) -> String {
        "This session moved to \(to) at \(clock(at)). What was done here after that is kept: the code in Code backup, the chat in Earlier chats."
    }
    /// The one line once the session runs here.
    static func moved(entry: BackendCloudSessionMoveEntry, row: BackendCloudSessionsRead.Row, terminal: Bool,
                      account: BackendCloudSessionMove.Account, code: BackendCodeBackupTakeCode.Result?,
                      folder: BackendCloudSessionMove.Folder?) -> String {
        let other = entry.other
        var parts: [String] = []
        if terminal {
            parts.append("Moved. A new terminal opened here in the same folder; programs that were running on \(other) did not move.")
        } else if entry.forced {
            // "The chat is from <time>" = when the Cloud copy last grew; "the code" = the old Mac's last backup.
            let chatAt = (entry.last?.held?.chatAt ?? row.lastUsedAt.map { Int64($0) }).map(clock)
            var line = "\(other) is off."
            if let chatAt { line += " The chat is from \(chatAt)" }
            if let codeAt = code?.codeAt ?? entry.codeAt ?? row.codeAt {
                line += (chatAt == nil ? " The code here is from " : " and the code here is from ") + clock(codeAt) + " (its last backup)."
            } else {
                line += (chatAt == nil ? "" : ".") + " The code here is this Mac's own; \(other) never backed this project up."
            }
            parts.append(line)
        } else {
            parts.append("Moved from \(other). Its code was backed up first.")
        }
        if case .other(_, let name, _) = account { parts.append("Continued with your \(aiName(row.ai)) account \(name).") }
        if let code {
            switch code.kind {
            case .notConnected:
                parts = parts.map { $0.hasPrefix("Moved from") ? "Moved." : $0 }
                parts.append("Connect GitHub to bring its code.")
            case .gotCode: parts.append("The project and its code came down from GitHub.")
            case .ownBranch(let branch): parts.append("Its code is on the branch \(branch); your branch here is as it was.")
            case .failed(let why): parts.append("Its code did not come down: \(why).")
            case .otherProject: parts.append(BackendCodeBackupTakeCode.refusedOtherProject)
            default: break
            }
            if let resumed = code.resumed { parts.insert(resumed, at: 0) }
            if let kept = code.keptAside, code.bringBack == nil, !code.isFailure { parts.append("Your unsaved changes here were put aside in Git (\(kept)).") }
            if !code.keptIgnored.isEmpty, let folder = code.keptIgnoredFolder {
                let names = code.keptIgnored.prefix(3).joined(separator: ", ") + (code.keptIgnored.count > 3 ? " and \(code.keptIgnored.count - 3) more" : "")
                parts.append("Files Git ignores here that its work changes were copied first to \(folder): \(names).")
            }
        } else if folder == nil, !terminal {
            parts.append("The project is not on this Mac.")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: The AI tool (every feature ships with its tool): the same move for Hoot and agents, the same refusals.

public enum BackendCloudSessionMoveTools {
    public static let owner = "cloud-session-move"
    public static func definitions() throws -> [BackendMCPTool] {
        let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([
            .init("session", .object([.init("type", .string("string")),
                                      .init("description", .string("The session to move, by its name as the side panel shows it (a session of another Mac)."))])),
            .init("action", .object([.init("type", .string("string")), .init("enum", .array([.string("switch"), .string("cancel"), .string("status")])),
                                     .init("description", .string("switch (default): move it to this Mac; cancel: call off a move that has not started here yet; status: read the moves under way."))]))
        ])), .init("required", .array([])), .init("additionalProperties", .bool(false))])
        return [try .init(id: "sessions.switch_to_this_mac", wireName: "sessions_switch_to_this_mac",
            description: "Move a session that runs on another of his Macs to this Mac (\"Switch to this Mac\"). The other Mac finishes a reply in progress, stops the session, backs up its code and hands the chat over; when it is off, this Mac takes the Cloud copy and says how old the code is. Refuses, and nothing stops, when this Mac has no sign-in for that AI. His unsaved changes on this Mac are put aside in Git first; split code histories go on a branch of their own. `status` reads only.",
            inputSchema: schema, tier: .act)]
    }
    /// `find`: a session of another machine by name or ref (nil: none, or more than one with that name).
    public static func registrations(find: @escaping @Sendable (String) async -> String?,
                                     move: @escaping @Sendable () async -> BackendCloudSessionMove?) throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        try definitions().map { spec in
            (spec, { _, arguments in
                guard let mover = await move() else {
                    return .value(.object([.init("available", .bool(false)), .init("line", .string("Sessions in the Cloud are not on for this Mac."))]))
                }
                let action = arguments["action"].string ?? "switch"
                if action == "status" { return .value(.object([.init("moves", await mover.wire())])) }
                guard let wanted = arguments["session"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty else {
                    return .value(.object([.init("ok", .bool(false)), .init("line", .string("Name the session to move."))]))
                }
                guard let ref = await find(wanted) else {
                    return .value(.object([.init("ok", .bool(false)), .init("line", .string("No session of another Mac is called \"\(wanted)\" (or several are)."))]))
                }
                let line = action == "cancel" ? await mover.cancel(ref: ref) : await mover.switchHere(ref: ref)
                return .value(.object([.init("ok", .bool(true)), .init("line", .string(line))]))
            })
        }
    }
}

// MARK: Putting the chat where the AI on this Mac resumes it

/// The chat that came down from the Cloud, laid into the chosen AI login's own folder under the name that AI looks
/// for when it resumes (the folder named in it changed line by line from the old Mac's to this Mac's; the Cloud copy is
/// never changed). A file already there with other bytes is kept beside it (`.before-move-<time>`), never replaced
/// without a copy.
public enum BackendCloudSessionMovePlace {
    public static func target(_ request: BackendCloudSessionMove.PlaceRequest) -> URL? {
        guard request.conversationId.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
              request.home.hasPrefix("/"), request.newCwd.hasPrefix("/") else { return nil }
        let home = URL(fileURLWithPath: request.home, isDirectory: true)
        switch request.provider {
        case "claude":
            return home.appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(request.newCwd) + "/" + request.conversationId + ".jsonl")
        case "codex":
            let date = Date(timeIntervalSince1970: TimeInterval(max(request.startedAt, 0)) / 1000)
            let day = DateFormatter(), stamp = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX"); stamp.locale = day.locale
            day.dateFormat = "yyyy/MM/dd"; stamp.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
            return home.appendingPathComponent("sessions/" + day.string(from: date) + "/rollout-" + stamp.string(from: date) + "-" + request.conversationId + ".jsonl")
        case "gemini":
            let date = Date(timeIntervalSince1970: TimeInterval(max(request.startedAt, 0)) / 1000)
            let stamp = DateFormatter(); stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.dateFormat = "yyyy-MM-dd'T'HH-mm"
            return home.appendingPathComponent("tmp/" + CloudSyncBytes.hash(Data(request.newCwd.utf8)) + "/chats/session-" + stamp.string(from: date)
                                               + "-" + String(request.conversationId.prefix(8)) + ".json")
        default:
            return nil
        }
    }

    @discardableResult
    public static func place(_ request: BackendCloudSessionMove.PlaceRequest, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> URL {
        guard let target = target(request), let provider = CloudConversationProvider(rawValue: request.provider) else { throw CloudFailure.unsupportedFormat }
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = target.deletingLastPathComponent().appendingPathComponent("." + target.lastPathComponent + ".moving-" + UUID().uuidString.lowercased())
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CloudFailure.unavailable }
        do {
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            try BackendCloudConversationProjectionWriter.rewrite(source: request.downloaded, into: output, provider: provider,
                                                                 conversationID: request.conversationId, oldPath: request.oldCwd, newPath: request.newCwd)
            try output.synchronize()
        } catch { try? manager.removeItem(at: temporary); throw error }
        try settle(temporary, at: target, now: now)
        if provider == .claude {
            let side = target.deletingPathExtension().appendingPathComponent("tool-results", isDirectory: true)
            for (name, file) in request.tools.sorted(by: { $0.key < $1.key }) {
                try manager.createDirectory(at: side, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let copy = side.appendingPathComponent("." + name + ".moving-" + UUID().uuidString.lowercased())
                try manager.copyItem(at: file, to: copy)
                try settle(copy, at: side.appendingPathComponent(name), now: now)
            }
        }
        return target
    }

    /// The new file takes the name; one already there with other bytes is kept beside it first.
    static func settle(_ fresh: URL, at target: URL, now: Int64) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: target.path) {
            if manager.contentsEqual(atPath: fresh.path, andPath: target.path) { try? manager.removeItem(at: fresh); return }
            try manager.copyItem(at: target, to: target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".before-move-\(now)"))
        }
        guard rename(fresh.path, target.path) == 0 else { try? manager.removeItem(at: fresh); throw CloudFailure.unavailable }
    }
}
