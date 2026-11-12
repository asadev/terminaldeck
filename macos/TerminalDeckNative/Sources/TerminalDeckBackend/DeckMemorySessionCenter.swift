import Foundation
import TerminalDeckNativeCore

/// L8 HOST · Deck Memory (11 Oct 2026): the app side of terminal-session memory.
///
/// - At launch every session gets its memory wiring (`launchArguments` / `launchEnvironment`), and the moment
///   it exists the app lays down its `start.md` / `prompt.md` (`started`).
/// - The hook program files one small JSON per hook call; this object watches that folder (a file-system
///   event, never a timer) and turns each into: context files kept fresh, a turn-end signal for M2 FLOW,
///   and the pre-compact safety net.
/// - The app never types into a session (Asad, 28 Oct 2026: the desk refresh that typed `/clear` or `/new` is gone,
///   for every session and every user). A new session, or one the person clears or compacts himself, gets its
///   memory from start.md through its SessionStart hook; nothing else changes the conversation.
public final class DeckMemorySessionCenter: @unchecked Sendable {
    // MARK: The one installed centre (composition installs it; the launcher asks it)
    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var installed: DeckMemorySessionCenter?
    public static var shared: DeckMemorySessionCenter? {
        get { sharedLock.withLock { installed } }
        set { sharedLock.withLock { installed = newValue } }
    }

    /// state.json written by older builds may still hold lastRefreshAt, lastRefreshReason and refreshWhenQuiet
    /// (the removed desk refresh): unknown keys are skipped when it is read.
    private struct Entry: Codable {
        var owner: DeckMemorySessionOwner = .plain
        var provider = ""
        var tabKey: String?
        var historyOwnerID: String?
        var transcriptPath: String?
        var conversationID: String?
        var lastPrompt: String?
        var lastTurnAt: Double?
        var largeWindow = false
        var working = false
        var lastPromptAt: Double?
        /// Reviewer MUST-FIX 1 (28 Oct): when the prompt.md on disk was made (taken just before its board lookup). A
        /// message is shown that file, so "changed since your last message" counts from here, not from the message.
        var promptBuiltAt: Double?
        // What the launch said about whose session this is (asked again when a lead is set or a session renamed).
        var agentProfileID: String?
        var agentInstructions: String?
        var claudeAgent: String?
        var taskID: String?
        var taskProject: String?
        var projectId: String?
    }
    private struct Event: Decodable {
        struct Input: Decodable { let session_id: String?; let transcript_path: String?; let source: String?; let prompt: String?; let trigger: String?; let last_assistant_message: String? }
        let event: String, session: String, name: String, at: Double
        let input: Input?
    }

    public let root: URL
    private let manager: BackendPTYManager
    private let lock = NSLock()
    private var services: DeckMemorySessionServices
    private var entries: [String: Entry] = [:]
    /// 28 Oct (CPU): sessions whose prompt lines wait for the board to settle, and the one flush that writes them.
    private var boardSettling = DeckMemoryBoardSettle()
    /// Seconds a board change waits for the next one before the prompt lines are written again.
    public static let boardSettle: Double = 2
    private var source: DispatchSourceFileSystemObject?
    private var pump: Task<Void, Never>?
    private var feed: AsyncStream<URL>.Continuation?
    private let queue = DispatchQueue(label: "dev.terminaldeck.deck-memory.sessions")
    /// Codex asks the person to trust new hooks once, so its inline hooks stay off unless turned on.
    public var codexHooks = false

    /// No way to write into a session is given on purpose: memory reads sessions, it never types into them.
    public init(dataRoot: URL, manager: BackendPTYManager, services: DeckMemorySessionServices) {
        root = DeckMemorySessionHook.root(dataRoot: dataRoot); self.manager = manager; self.services = services
    }
    /// M1 CORE / M2 FLOW / L4 AGENTS replace the file-based defaults with their own here.
    public func bind(_ change: (inout DeckMemorySessionServices) -> Void) { lock.withLock { change(&services) } }
    private var current: DeckMemorySessionServices { lock.withLock { services } }
    private static func now() -> Double { Date().timeIntervalSince1970 * 1000 }

    // MARK: Start / stop watching
    public func start() throws {
        try DeckMemorySessionHook.install(root: root)
        guard lock.withLock({ pump == nil }) else { return }
        let (stream, continuation) = AsyncStream<URL>.makeStream()
        let events = DeckMemorySessionHook.events(root)
        let descriptor = open(events.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeRPCError(code: "watch-failed", message: "The session memory folder could not be watched.") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write], queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { close(descriptor) }
        let pump = Task { [weak self] in for await file in stream { await self?.handle(file) } }
        lock.withLock { feed = continuation; self.source = source; self.pump = pump }
        source.resume()
        queue.async { [weak self] in self?.drain() }   // whatever arrived while the app was closed
        let root = root, live = Set(manager.list().map(\.id))
        Task.detached(priority: .utility) { Self.sweep(root: root, live: live) }
    }
    public func stop() {
        let (source, pump, feed) = lock.withLock { () -> (DispatchSourceFileSystemObject?, Task<Void, Never>?, AsyncStream<URL>.Continuation?) in
            defer { self.source = nil; self.pump = nil; self.feed = nil }
            return (self.source, self.pump, self.feed)
        }
        source?.cancel(); feed?.finish(); pump?.cancel()
    }
    private var handed: Set<String> = []
    /// On the watch queue: hand every new event file to the pump once, oldest first.
    private func drain() {
        let folder = DeckMemorySessionHook.events(root)
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let feed = lock.withLock { self.feed }
        for file in files where !handed.contains(file.lastPathComponent) {
            handed.insert(file.lastPathComponent); feed?.yield(file)
        }
        if handed.count > 4_096 { handed = Set(files.map(\.lastPathComponent)) }
    }

    // MARK: Launch wiring (called by BackendSessionLauncher)
    public func launchArguments(_ arguments: [String], input: BackendCreateSessionInput, provider: String) async -> [String] {
        switch provider {
        case "claude": return DeckMemorySessionHook.claudeArguments(arguments, root: root, taskSession: input.taskID != nil)
        case "codex":
            // Only an owner with memory is told to read its card; a plain Codex session is left as it is.
            let owner = await current.owner(input, provider)
            guard owner.hasDesk else { return arguments }
            return DeckMemorySessionHook.codexArguments(arguments, root: root, withHooks: codexHooks)
        default: return arguments
        }
    }
    public func launchEnvironment(_ environment: [String: String], provider: String) -> [String: String] {
        provider == "gemini" ? DeckMemorySessionHook.geminiEnvironment(existing: environment, root: root) : [:]
    }
    /// The session exists: remember whose it is and lay down what its hook will print.
    public func started(_ session: BackendSessionMeta, input: BackendCreateSessionInput) async {
        // L4 AGENTS' session-aware answer first: a lead is usually a session the person started himself.
        var owner: DeckMemorySessionOwner
        if let owners = BackendAGTMemoryOwners.shared { owner = await owners.owner(input, session: session) } else { owner = await current.owner(input, session.provider) }
        owner = await seated(owner, session: session, taskID: input.taskID)
        var entry = load(session.id) ?? Entry()
        entry.owner = owner; entry.provider = session.provider; entry.conversationID = session.agentSessionId ?? entry.conversationID
        entry.tabKey = session.tabKey ?? input.tabKey
        entry.historyOwnerID = session.homeProfileId ?? session.profileId
        entry.largeWindow = (input.model ?? "").contains("[1m]")
        entry.agentProfileID = input.agentProfileID; entry.agentInstructions = input.agentInstructions; entry.claudeAgent = input.claudeAgent; entry.taskID = input.taskID
        entry.taskProject = input.taskProject; entry.projectId = input.projectId
        save(session.id, entry)
        await rebuild(session, owner: owner, reason: "start", lastMessages: [])
    }

    /// A session was renamed, or the person made a session the lead of a project: ask again whose each
    /// running session is, and lay down the right card for the ones that changed.
    public func reassessOwners() async {
        guard let owners = BackendAGTMemoryOwners.shared else { return }
        for session in manager.list() where session.exitCode == nil {
            guard let entry = load(session.id) else { continue }
            var input = BackendCreateSessionInput(cwd: session.cwd, provider: session.provider)
            input.agentProfileID = entry.agentProfileID; input.agentInstructions = entry.agentInstructions; input.claudeAgent = entry.claudeAgent; input.taskID = entry.taskID
            input.taskProject = entry.taskProject; input.projectId = entry.projectId ?? session.projectId
            let owner = await seated(await owners.owner(input, session: session), session: session, taskID: entry.taskID)
            guard owner != entry.owner else { continue }
            _ = update(session.id) { $0.owner = owner }
            await rebuild(session, owner: owner, reason: "start", lastMessages: [])
            if owner.hasDesk, session.provider == "claude" {
                current.report("\(session.title) now has a memory card (\(owner.kind.rawValue)); it is laid down at its next clean desk.")
            }
        }
    }
    /// Spec 3b: a session that fills a seat takes a hand on it (same card and notes as every other hand, its
    /// own job and topic); one that fills none gives its hand back.
    private func seated(_ owner: DeckMemorySessionOwner, session: BackendSessionMeta, taskID: String?) async -> DeckMemorySessionOwner {
        var owner = owner
        guard owner.hasDesk else { await current.leaveHand(session.id); return owner }
        if let taken = await current.joinHand(session.id, owner, owner.job, taskID) { owner.hand = taken.hand; owner.job = taken.job ?? owner.job }
        if owner.job == nil, !session.title.isEmpty { owner.job = session.title }
        return owner
    }
    /// The session is gone: give its hand back and forget its in-memory state. U144 (#663): a session that was removed
    /// takes its folder with it (the diary keeps the history; nothing reads the folder again).
    public func sessionEnded(sessionID: String, removed: Bool = false) async {
        await current.leaveHand(sessionID)
        lock.withLock { entries[sessionID] = nil }
        if removed, !sessionID.isEmpty, !sessionID.contains("/"), sessionID != ".", sessionID != ".." { try? FileManager.default.removeItem(at: folder(sessionID)) }
    }
    /// Folders of sessions that are not running and have not changed for two weeks (removed before folders went
    /// with their session, or ended without being removed).
    static let staleFolderSeconds = 14.0 * 24 * 3_600
    static func sweep(root: URL, live: Set<String>, now: Date = Date()) {
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        for folder in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where !live.contains(folder.lastPathComponent) {
            let files = [folder] + ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            let newest = files.compactMap { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }.max()
            guard let newest, now.timeIntervalSince(newest) > staleFolderSeconds else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
    /// The memory changed (card, topics, notes, board): keep what the hooks will print current.
    /// Event-driven from M1's change feed; diary and index changes are ignored.
    public func memoryChanged(_ change: DeckMemoryChange) async {
        let areas: Set<DeckMemoryChange.Area> = [.card, .topics, .board, .folder]
        guard areas.contains(change.area) else { return }
        for session in manager.list() where session.exitCode == nil {
            guard let entry = lock.withLock({ entries[session.id] }), entry.owner.hasDesk else { continue }
            if let changed = change.owner, let mine = BackendAGTMemoryOwners.memoryOwner(entry.owner), change.area != .board, change.area != .folder {
                // Another owner's card or notes do not change this desk (a lead also reads its project's).
                if changed != mine, changed.projectID == nil || changed.projectID != mine.projectID { continue }
            }
            // 28 Oct (CPU): the board changes with every session's status (several times a turn); each change rewrote
            // every desk's prompt lines with a board query. They are written 2 s after the first change of a spell.
            if change.area == .board { scheduleBoardLines(session.id) }
            else { await rebuild(session, owner: entry.owner, reason: "start", lastMessages: []) }
        }
    }
    /// Notes a desk whose prompt lines are behind the board; the first note of a quiet spell books one flush.
    private func scheduleBoardLines(_ id: String) {
        guard lock.withLock({ boardSettling.note(id) }) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.boardSettle))
            await self?.flushBoardLines()
        }
    }
    private func flushBoardLines() async {
        let ids = lock.withLock { boardSettling.take() }
        let live = manager.list()
        for id in ids {
            guard let session = live.first(where: { $0.id == id && $0.exitCode == nil }),
                  let entry = lock.withLock({ entries[id] }), entry.owner.hasDesk else { continue }
            await writePromptLines(session, owner: entry.owner, services: current)
        }
    }
    /// The prompt lines with the moment they were made, written together; an older build that finishes after a newer
    /// one never replaces it. A plain session gets an empty file (its hook never waits and prints nothing).
    private func writePromptLines(_ session: BackendSessionMeta, owner: DeckMemorySessionOwner, services: DeckMemorySessionServices) async {
        let mark = Self.now()
        let text = owner.hasDesk ? await services.promptLines(owner, session) : ""
        guard (load(session.id)?.promptBuiltAt ?? 0) <= mark else { return }
        put(text, "prompt.md", session.id)
        _ = update(session.id) { if ($0.promptBuiltAt ?? 0) <= mark { $0.promptBuiltAt = mark } }
    }
    /// What "since the last message" counts from after a message: what that message was shown (the prompt.md made at
    /// `built`), never later than the message itself. A board change still waiting for the settle, or one the app
    /// did not write before it quit, is then in the next prompt lines.
    public static func shownSince(prompt: Double, built: Double?) -> Double { min(prompt, built ?? prompt) }
    public func lastPromptDate(sessionID: String) -> Date? { (load(sessionID)?.lastPromptAt).map { Date(timeIntervalSince1970: $0 / 1000) } }
    public func lastMessages(sessionID: String, count: Int = 6) -> [(role: String, text: String)] { Self.lastMessages(load(sessionID)?.transcriptPath, count: count) }

    /// 28 Oct (Sessions, bug A): before a session-helper restart, and once the kept sessions are attached at start,
    /// every running session whose own hook named a newer conversation than the one it was started with (a /clear
    /// before this was followed) is written down with that one. Only when that conversation's transcript is there.
    public func reconcileConversations() async {
        for session in manager.list() where session.exitCode == nil {
            guard let entry = load(session.id), let id = Self.reconciledConversation(named: entry.conversationID,
                    transcriptPath: entry.transcriptPath, current: session.agentSessionId,
                    exists: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            await current.conversationChanged(session.id, id)
        }
    }
    /// The conversation a session-start hook moved the session to, or nil when it is the one already written down
    /// (a compaction keeps its id) or not a usable id.
    public static func followedConversation(named: String?, current: String?) -> String? {
        guard let named, named.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil, named != current else { return nil }
        return named
    }
    /// 10 Nov: whether a hook's conversation id is the one the session is in: the one already written down, or one
    /// whose transcript (named after it) is on disk. A background session's id, with no transcript, is not.
    public static func believed(named: String?, transcriptPath: String?, current: String?, exists: (String) -> Bool) -> Bool {
        guard let named, !named.isEmpty else { return false }
        return named == current || reconciledConversation(named: named, transcriptPath: transcriptPath, current: nil, exists: exists) != nil
    }
    /// The newer conversation to write down for a running session, only when the hook's transcript of it exists.
    public static func reconciledConversation(named: String?, transcriptPath: String?, current: String?, exists: (String) -> Bool) -> String? {
        guard let id = followedConversation(named: named, current: current), let path = transcriptPath,
              URL(fileURLWithPath: path).lastPathComponent == id + ".jsonl", exists(path) else { return nil }
        return id
    }

    // MARK: Per-session files
    private func folder(_ id: String) -> URL { DeckMemorySessionHook.session(root, id) }
    private func load(_ id: String) -> Entry? {
        if let entry = lock.withLock({ entries[id] }) { return entry }
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("state.json")),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        lock.withLock { entries[id] = entry }
        return entry
    }
    private func save(_ id: String, _ entry: Entry) {
        lock.withLock { entries[id] = entry }
        let folder = folder(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: folder.appendingPathComponent("state.json"), options: .atomic) }
    }
    private func update(_ id: String, _ change: (inout Entry) -> Void) -> Entry {
        var entry = load(id) ?? Entry(); change(&entry); save(id, entry); return entry
    }
    private func put(_ text: String, _ name: String, _ id: String) {
        let folder = folder(id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(name)
        try? Data(text.utf8).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    /// A plain session gets empty files (so its hook never waits and prints nothing).
    private func rebuild(_ session: BackendSessionMeta, owner: DeckMemorySessionOwner, reason: String, lastMessages: [(role: String, text: String)]) async {
        let services = current
        let start = owner.hasDesk ? await services.startContext(owner, session, reason, lastMessages) : ""
        put(start, "start.md", session.id)
        await writePromptLines(session, owner: owner, services: services)
    }

    // MARK: Hook events
    private func handle(_ file: URL) async {
        guard let data = try? Data(contentsOf: file), data.count <= 4 * 1024 * 1024,
              let event = try? JSONDecoder().decode(Event.self, from: data) else { try? FileManager.default.removeItem(at: file); return }
        guard let session = manager.list().first(where: { $0.id == event.session }) else {
            // Right after the app starts, sessions kept alive by the session host may not be attached yet:
            // a recent event waits for the next look instead of being lost.
            if Date().timeIntervalSince1970 - event.at > 120 { try? FileManager.default.removeItem(at: file) }
            else { let name = file.lastPathComponent; queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.handed.remove(name); self?.drain() } }
            return
        }
        defer { try? FileManager.default.removeItem(at: file) }
        // 10 Nov (Sessions, Asad's Decker tab was lost): a hook can name a conversation the session is NOT in — Claude
        // Code's own background work (an idle compaction ran one a second after the real move) reports a session id
        // that never gets a transcript. Only a conversation whose transcript is on disk is believed: written down
        // here, and followed by the session's saved launch. A real /clear or /resume is followed at its first prompt
        // or answer, when its transcript exists.
        let named = event.input?.session_id.flatMap { $0.isEmpty ? nil : $0 }
        let proven = Self.believed(named: named, transcriptPath: event.input?.transcript_path, current: session.agentSessionId,
                                   exists: { FileManager.default.fileExists(atPath: $0) })
        var entry = update(session.id) { entry in
            if entry.provider.isEmpty { entry.provider = session.provider }
            guard proven || entry.conversationID == nil else { return }
            if let path = event.input?.transcript_path, path.hasPrefix("/") { entry.transcriptPath = path }
            if let named { entry.conversationID = named }
        }
        if proven, let id = Self.followedConversation(named: named, current: session.agentSessionId) {
            // 28 Oct (Sessions, bug A): after /clear or /resume the CLI is in another conversation; the session's
            // saved launch follows, or a restart would resume the old one (or find nothing and wait for a click).
            await current.conversationChanged(session.id, id)
        }
        switch event.event {
        case "session-start":
            // start.md was just printed. (After a compaction, or a clear the person typed himself, it is the fresh one.)
            break
        case "prompt":
            entry = update(session.id) {
                $0.lastPrompt = event.input?.prompt.map { String($0.prefix(20_000)) }; $0.working = true
                $0.lastPromptAt = Self.shownSince(prompt: event.at * 1000, built: $0.promptBuiltAt)
            }
            // The per-message lines for the NEXT message (the board moves on between messages).
            if entry.owner.hasDesk { await writePromptLines(session, owner: entry.owner, services: current) }
            await current.activity(session.id)
        case "stop":
            entry = update(session.id) { $0.working = false; $0.lastTurnAt = event.at * 1000 }
            await turnEnded(session, entry: entry, source: "hook", at: event.at * 1000, lastAnswer: event.input?.last_assistant_message.map { String($0.prefix(40_000)) })
        case "pre-compact":
            // Safety net: topics saved and a fresh start.md on disk BEFORE the CLI compacts; then let it go.
            if entry.owner.hasDesk {
                await current.saveTopics(entry.owner, session)
                await rebuild(session, owner: entry.owner, reason: "compact", lastMessages: Self.lastMessages(entry.transcriptPath))
            }
            put("", "ack-" + event.name, session.id)
        default: break
        }
    }
    /// Codex and Gemini (no trusted hooks): the session going from working to quiet is the turn end.
    /// Claude is skipped here: its own Stop hook already said so.
    public func statusChanged(sessionID: String, status: String) async {
        guard let session = manager.list().first(where: { $0.id == sessionID }), session.exitCode == nil, session.provider != "claude" else { return }
        let was = load(sessionID)?.working ?? false
        if status == "working" { if !was { _ = update(sessionID) { $0.working = true; if $0.provider.isEmpty { $0.provider = session.provider } } }; return }
        guard was, ["waiting", "idle", "completed"].contains(status) else { return }
        let at = Self.now()
        let entry = update(sessionID) { $0.working = false; $0.lastTurnAt = at }
        await turnEnded(session, entry: entry, source: "status", at: at, lastAnswer: nil)
    }
    /// M2 FLOW (or anyone who found the CLI's own record) can tell the centre where a session's transcript is.
    public func noteTranscript(sessionID: String, path: String) { _ = update(sessionID) { $0.transcriptPath = path } }

    /// Whose memory a running session belongs to (the same stamp the turn-end signal carries). Plain when unknown.
    public func owner(sessionID: String) -> DeckMemorySessionOwner { load(sessionID)?.owner ?? .plain }

    private func turnEnded(_ session: BackendSessionMeta, entry: Entry, source: String, at: Double, lastAnswer: String?) async {
        await current.turnEnded(.init(sessionID: session.id, provider: session.provider, owner: entry.owner, cwd: session.cwd,
            projectID: session.projectId, conversationID: entry.conversationID ?? session.agentSessionId,
            transcriptPath: entry.transcriptPath, prompt: entry.lastPrompt, lastAnswer: lastAnswer, title: session.title, at: at, source: source))
    }

    // MARK: How full a desk is (read only; the agent records show it)
    /// How full the desk is (0…1), read from the CLI's own record: the tokens the last turn held over the context window
    /// of the model that turn actually ran on (Claude: the model its record names, by the app's one model table, 1M when
    /// launched on a [1m] model, never less than what the turn already holds; Codex: the window it reports). Nil when it
    /// cannot be told: an unknown window is never assumed.
    public static func deskFill(provider: String, transcriptPath: String?, largeWindow: Bool) -> Double? {
        guard let path = transcriptPath, let tail = tail(path, bytes: 512 * 1024) else { return nil }
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: true).reversed()
        if provider == "claude" {
            for line in lines where line.contains("\"usage\"") {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], row["type"] as? String == "assistant",
                      row["isSidechain"] as? Bool != true, let message = row["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                let used = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0.0) { $0 + ((usage[$1] as? NSNumber)?.doubleValue ?? 0) }
                guard used > 0 else { continue }
                guard let window = claudeWindow(model: message["model"] as? String ?? "", launchedLarge: largeWindow, used: used) else { return nil }
                return min(1, used / window)
            }
        } else if provider == "codex" {
            for line in lines where line.contains("token_count") {
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let info = (row["payload"] as? [String: Any])?["info"] as? [String: Any],
                      let window = (info["model_context_window"] as? NSNumber)?.doubleValue, window > 0,
                      let used = ((info["last_token_usage"] as? [String: Any])?["total_tokens"] as? NSNumber)?.doubleValue else { continue }
                return min(1, used / window)
            }
        }
        return nil
    }
    /// The context window of the Claude model a turn ran on: the app's model table (the one the usage meter uses), 1M when
    /// the session was launched on a [1m] model, and never less than what the turn already holds. Nil when the record
    /// names no model and nothing else says how large the window is.
    public static func claudeWindow(model: String, launchedLarge: Bool, used: Double) -> Double? {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = !name.isEmpty && !name.hasPrefix("<")
        guard known || launchedLarge else { return nil }
        let base = launchedLarge || name.lowercased().hasSuffix("[1m]") ? 1_000_000 : BackendCostMath.contextWindow(name)
        if used <= base { return base }
        return [200_000.0, 1_000_000.0].first { $0 >= used } ?? used
    }

    static func tail(_ path: String, bytes: Int) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
    /// The last few things said, word for word, from Claude's own record (typed messages and answers only).
    public static func lastMessages(_ transcriptPath: String?, count: Int = 6, each: Int = 1_200) -> [(role: String, text: String)] {
        guard let path = transcriptPath, let tail = tail(path, bytes: 768 * 1024) else { return [] }
        var out: [(role: String, text: String)] = []
        for line in tail.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard out.count < count, let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = row["type"] as? String, type == "user" || type == "assistant", row["isMeta"] as? Bool != true,
                  row["isSidechain"] as? Bool != true, let message = row["message"] as? [String: Any] else { if out.count >= count { break }; continue }
            var text = ""
            if let content = message["content"] as? String { text = content }
            else if let blocks = message["content"] as? [[String: Any]] {
                text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<command-name>"), !text.hasPrefix("<local-command"), !text.hasPrefix("Caveat:") else { continue }
            out.append((type, text.count > each ? String(text.prefix(each)) + " …" : text))
        }
        return out.reversed()
    }

    /// One line for the app's own report (profile / log).
    public func say(_ text: String) { current.report(text) }
}

/// 28 Oct (CPU): the desks whose prompt lines wait for the board to settle. The first change of a quiet spell books
/// the one flush; every later change until that flush only adds its desk.
public struct DeckMemoryBoardSettle: Sendable {
    private var pending: Set<String> = []
    private var booked = false
    public init() {}
    /// Notes a desk; true when this change must book the flush.
    public mutating func note(_ id: String) -> Bool {
        pending.insert(id)
        guard !booked else { return false }
        booked = true; return true
    }
    /// The flush takes every waiting desk; the next change books a new one.
    public mutating func take() -> Set<String> {
        defer { pending = []; booked = false }
        return pending
    }
}
