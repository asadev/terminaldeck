import Foundation
import TerminalDeckNativeCore

/// The flow that fills Deck Memory. Everything here starts from a signal the app already
/// receives (a turn ended, a session changed state, Hoot's stream moved, a task changed);
/// the only clock use is a one-shot pause after a turn end and the one daily tidy-up slot.
///   1. Diary: every message in and out, copied word for word by the app, no AI.
///   2. Board: session, task, agent and project rows straight from app state, no AI.
///   3. Helper: after a turn end and a short pause, a small AI job reads ONLY the new diary
///      part of that one session and writes the board's result lines and short notes. The
///      app stamps who and what project; the AI never does.
///   4. Tidy-up: once a day when the app is quiet, per owner.
public actor DeckMemoryFlowEngine {
    public struct SessionInfo: Sendable, Equatable {
        public var id: String, title: String, provider: String, cwd: String, project: String
        /// Milliseconds since 1970.
        public var createdAt: Double
        public var status: String?
        public init(id: String, title: String, provider: String, cwd: String = "", project: String = "", createdAt: Double = 0, status: String? = nil) {
            self.id = id; self.title = title; self.provider = provider; self.cwd = cwd; self.project = project
            self.createdAt = createdAt; self.status = status
        }
    }
    public struct Dependencies: Sendable {
        /// Waits until the memory store is open.
        public var store: @Sendable () async -> any DeckMemoryFlowStore
        public var clock: any BackendDeckCoreEventsClock
        public var stateFile: DeckMemoryFlowStateFile
        public var runner: any DeckMemoryFlowHelperRunning
        /// Which of claude / codex / gemini are installed on this Mac.
        public var installedAIs: @Sendable () async -> [String]
        /// The AI Hoot runs on now (the helper uses the same one unless the person chose).
        public var hootAI: @Sendable () async -> String?
        public var session: @Sendable (String) async -> SessionInfo?
        public var sessions: @Sendable () async -> [SessionInfo]
        /// Who a session is, as the app knows it (the seat it fills, or its project).
        public var stamp: @Sendable (String) async -> DeckMemoryStamp?
        /// Where the session's own conversation record is (second argument: the path its turn-end hook named).
        public var locate: @Sendable (String, String?) async -> DeckMemoryFlowRecordTarget?
        /// Hoot's events after a position (nil = from the start), as its chat store answers.
        public var hootRead: @Sendable (Int?) async -> NativeRPCValue?
        public var projectName: @Sendable (String) -> String?
        /// Who is on the "user" side of this session when the app cannot tell message by message:
        /// the person for a session they started themselves, the orchestrator for one Hoot started.
        public var userSide: @Sendable (String) async -> DeckMemoryAuthor = { _ in .person }
        /// The project a task belongs to: the id it carries, else the project its folder lies in.
        public var projectOf: @Sendable (_ projectID: String?, _ folder: String) -> String = { PROJProjects.resolve(projectID: $0, folder: $1) }
        /// The folder the helper's own runs work in. Nothing from there is ever captured.
        public var helperFolder: String?
        public var report: @Sendable (String) -> Void
        public var changed: @Sendable () -> Void
        public var calendar: Calendar
        /// The helper's wording. Swappable without touching anything else.
        public var prompts = DeckMemoryFlowPrompts.standard
        public init(store: @escaping @Sendable () async -> any DeckMemoryFlowStore, clock: any BackendDeckCoreEventsClock,
                    stateFile: DeckMemoryFlowStateFile, runner: any DeckMemoryFlowHelperRunning,
                    installedAIs: @escaping @Sendable () async -> [String] = { ["claude"] },
                    hootAI: @escaping @Sendable () async -> String? = { nil },
                    session: @escaping @Sendable (String) async -> SessionInfo? = { _ in nil },
                    sessions: @escaping @Sendable () async -> [SessionInfo] = { [] },
                    stamp: @escaping @Sendable (String) async -> DeckMemoryStamp? = { _ in nil },
                    locate: @escaping @Sendable (String, String?) async -> DeckMemoryFlowRecordTarget? = { _, _ in nil },
                    hootRead: @escaping @Sendable (Int?) async -> NativeRPCValue? = { _ in nil },
                    projectName: @escaping @Sendable (String) -> String? = { _ in nil },
                    report: @escaping @Sendable (String) -> Void = { _ in },
                    changed: @escaping @Sendable () -> Void = {}, calendar: Calendar = .current) {
            self.store = store; self.clock = clock; self.stateFile = stateFile; self.runner = runner
            self.installedAIs = installedAIs; self.hootAI = hootAI; self.session = session; self.sessions = sessions
            self.stamp = stamp; self.locate = locate; self.hootRead = hootRead; self.projectName = projectName
            self.report = report; self.changed = changed; self.calendar = calendar
        }
    }
    /// Everything the engine reacts to, in the order it happened.
    public enum Event: Sendable {
        case signal(DeckMemoryFlowInbox.Signal)
        case sessionSeen(SessionInfo)
        case sessionStatus(id: String, status: String)
        case sessionExit(id: String, code: Int)
        case sessionRemoved(id: String)
        case sessionRenamed(id: String, title: String)
        case tasks([NativeRPCValue])
        /// Who is hired into which seat right now (seat key → name), from the app's own agent list.
        case hires([String: String])
        case hootWake
        case tidySlot
        /// A board row's working/idle state may have held long enough to be written.
        case boardSettle
        /// Something went quiet (a job finished): the tidy-up may be able to start.
        case idle
        /// For checks: answers when everything posted before it has been handled.
        case probe
    }
    /// For the whole app.
    struct Settings: Sendable, Equatable {
        var helperOn = true, pause = 20.0, parallel = 1, tidyOn = true, tidyHour = 3
    }
    /// From the category's one template (orchestrator, lead or agent): the same for every member.
    struct Helper: Sendable, Equatable {
        var on = true, ai = "claude", model = "", checklist = DeckMemoryFlowChecklist.defaultText
        var problem: String?
    }
    struct TurnOutcome: Sendable {
        var result: DeckMemoryFlowJobResult
        var rows = 0, notes = 0, topics = 0
        /// Another reader is on this session right now.
        var busy = false
        var message: String
    }
    struct TidyOutcome: Sendable { var result: DeckMemoryFlowJobResult; var message: String }

    private let deps: Dependencies
    private nonisolated let events: AsyncStream<Event>.Continuation
    private let stream: AsyncStream<Event>
    private nonisolated let hootPending = DeckMemoryFlowFlag()
    private var consumer: Task<Void, Never>?
    private var store: (any DeckMemoryFlowStore)?
    private var queue: DeckMemoryFlowQueue?
    private var state = DeckMemoryFlowState()
    private var board: DeckMemoryFlowBoard
    private var hootReader: DeckMemoryFlowHootReader?
    private var hootBusy = false
    private var turns: [String: DeckMemoryFlowTurn] = [:]
    /// Sessions the task engine started for a task, from the app's own task list: the task's title and who gave it.
    private var taskSessions: [String: TaskSession] = [:]
    struct TaskSession: Sendable, Equatable { var title: String; var givenBy: String? }
    /// How long a job may wait for the turn end of a session that looks busy. A turn end or a quieter
    /// state brings it forward; without either it still runs when this is over (never stranded).
    static let workingHold: Double = 900_000
    /// Until when a session's diary came from turn-end signals only (no record was found).
    private var signalOnlyUntil: [String: Double] = [:]
    private var active = Set<String>()
    private var freeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var tidyRunning = false
    private var tidyTimer: UUID?
    /// Board rows whose working/idle state waits to hold before it is written, by row id (see `write`).
    private var settling: [String: Settling] = [:]
    private struct Settling { var update: DeckMemoryBoardUpdate; var since: Double; var first: Double }
    private var settleTimer: UUID?
    /// A row that flips all the time without ever holding is still written this often (milliseconds), so the
    /// stored board is never far behind.
    static let settleAtMost: Double = 30_000
    private var problem: String?
    private var started = false

    public init(_ dependencies: Dependencies) {
        deps = dependencies
        let pair = AsyncStream<Event>.makeStream()
        stream = pair.stream; events = pair.continuation
        board = DeckMemoryFlowBoard(projectName: dependencies.projectName, projectOf: dependencies.projectOf)
    }

    /// Never blocks and never throws: the caller is a hook, a status change or a stream.
    public nonisolated func post(_ event: Event) { events.yield(event) }
    /// Hoot's stream moved. Many moves while one is waiting to be read count as one.
    public nonisolated func hootChanged() { if hootPending.raise() { events.yield(.hootWake) } }

    // MARK: Start and stop

    public func start() async {
        guard !started else { return }
        started = true
        state = deps.stateFile.load()
        let store = await deps.store()
        self.store = store
        let settings = await settings()
        let changed = deps.changed
        let queue = DeckMemoryFlowQueue(jobs: state.jobs, clock: deps.clock, parallel: settings.parallel,
            run: { [weak self] job in await self?.run(job) ?? .failed("The app is closing.") },
            persist: { [weak self] jobs in await self?.persist(jobs) },
            changed: { [weak self] in changed(); self?.post(.idle) })
        self.queue = queue
        // A helper seat still waiting to fold back when the app closed: if its session's read is no
        // longer queued it folds back now; otherwise the revived read folds it when it ends.
        for session in (state.folding ?? [:]).keys where !state.jobs.contains(where: { $0.id == DeckMemoryFlowJob.turnID(session) }) {
            await foldBack(after: session)
        }
        // A category whose template has no checklist of the person's own yet (none, or only the store's
        // starter text) gets the default one, visible and editable there. Text the person wrote is never replaced.
        for category in DeckMemoryCategory.allCases {
            guard var template = try? await store.template(category) else { continue }
            let current = template.checklist.trimmingCharacters(in: .whitespacesAndNewlines)
            let starter = DeckMemoryStore.defaultTemplate(category).checklist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current.isEmpty || (current == starter && current != DeckMemoryFlowChecklist.defaultText.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            template.checklist = DeckMemoryFlowChecklist.defaultText
            try? await store.saveTemplate(template)
        }
        consumer = Task { [weak self, stream] in
            for await event in stream { guard let self else { return }; await self.handle(event) }
        }
        DeckMemoryFlowInbox.attach { [weak self] signal in self?.post(.signal(signal)) }
        DeckMemoryFlowInbox.attachCatchUp { [weak self] session, timeout in await self?.catchUp(session: session, timeout: timeout) ?? false }
        // Sessions that ran while the app was closed: the board learns them, and what their own
        // records gained meanwhile is read into the diary (the diary skips what it already has).
        for info in await deps.sessions() {
            post(.sessionSeen(info))
            post(.signal(.sessionActivity(sessionID: info.id, at: deps.clock.now())))
        }
        hootChanged()
        await queue.start(revivingAfter: settings.pause * 1000)
        armTidy(settings)
        deps.changed()
    }

    public func stop() async {
        guard started else { return }
        started = false
        DeckMemoryFlowInbox.detach()
        events.finish()
        await consumer?.value; consumer = nil
        if let tidyTimer { deps.clock.cancel(tidyTimer) }
        tidyTimer = nil
        // What still waited to settle is the board as it is now: written before the app closes.
        await flushSettling(all: true)
        if let settleTimer { deps.clock.cancel(settleTimer) }
        settleTimer = nil
        await queue?.stop()
    }

    /// For checks: every event posted so far has been handled and every job has finished.
    public func settle() async {
        for _ in 0..<3 {
            let probe = AsyncStream<Void>.makeStream()
            probes.append(probe.continuation); events.yield(.probe)
            for await _ in probe.stream { break }
            await queue?.settle()
        }
    }
    private var probes: [AsyncStream<Void>.Continuation] = []

    // MARK: Events

    private func handle(_ event: Event) async {
        guard let store else { return }
        switch event {
        case .signal(.sessionTurnEnded(let turn)):
            // The helper's own runs are never a conversation: no diary rows, no board row, no next run.
            if let folder = deps.helperFolder, !folder.isEmpty, turn.cwd == folder || turn.cwd.hasPrefix(folder + "/") { return }
            turns[turn.sessionID] = turn
            await see(turn.sessionID, turn: turn)
            await capture(turn.sessionID, turn: turn)
            let settings = await settings()
            if settings.helperOn, turn.owner.memoryOn {
                await queue?.submit(.init(id: DeckMemoryFlowJob.turnID(turn.sessionID), kind: .turn, subject: turn.sessionID,
                    title: board.sessions[turn.sessionID]?.title ?? turn.title, dueAt: nil, createdAt: deps.clock.now()), after: settings.pause * 1000)
                deps.changed()
            }
        case .signal(.sessionActivity(let id, _)):
            // A new message went in: the job waits for that turn's end, with a last moment it runs at anyway.
            await queue?.hold(DeckMemoryFlowJob.turnID(id), atMost: Self.workingHold)
            await capture(id, turn: nil)
        case .signal(.correction(let text, let ownerKey, let at)):
            await addCorrection(text, ownerKey: ownerKey, at: Date(timeIntervalSince1970: at / 1000))
        case .sessionSeen(let info):
            await see(info.id, info: info)
        case .sessionStatus(let id, let status):
            await see(id)
            await write(board.sessionStatus(id: id, status: status))
            if status == "working" { await queue?.hold(DeckMemoryFlowJob.turnID(id), atMost: Self.workingHold) }
            else {
                // It stopped to ask, finished or went idle: what it said so far goes into the diary now.
                await capture(id, turn: nil)
                // A job held because the session looked busy runs after the usual pause now. Without this a
                // "working" sign that arrives after the turn end left the job waiting for a turn end that never came.
                if await queue?.contains(DeckMemoryFlowJob.turnID(id)) == true {
                    await queue?.release(DeckMemoryFlowJob.turnID(id), after: (await settings()).pause * 1000)
                }
                await quiet()
            }
        case .sessionExit(let id, let code):
            await see(id)
            await write(board.sessionExited(id: id, code: code))
            // Its last words, then its job no longer waits for a turn end that will not come.
            await capture(id, turn: nil, final: true)
            if await queue?.contains(DeckMemoryFlowJob.turnID(id)) == true {
                await queue?.submit(.init(id: DeckMemoryFlowJob.turnID(id), kind: .turn, subject: id, dueAt: nil, createdAt: deps.clock.now()),
                                    after: (await settings()).pause * 1000)
            }
            await quiet()
        case .sessionRemoved(let id):
            let seat = board.sessions[id]?.stamp.owner
            await write(board.sessionRemoved(id: id))
            if state.records.removeValue(forKey: id) != nil { save() }
            turns[id] = nil; signalOnlyUntil[id] = nil; taskSessions[id] = nil
            DeckMemoryFlowInbox.forgetTyped(sessionID: id)
            if let seat { await closed(session: id, seat: seat) }
        case .sessionRenamed(let id, let title):
            await write(board.sessionRenamed(id: id, title: displayTitle(id, stamp: board.sessions[id]?.stamp, names: [title])))
        case .tasks(let views):
            // A session the task engine started is known by its task: its title, and who gave the task.
            for view in views {
                guard let session = view["sessionId"].string, !session.isEmpty else { continue }
                let next = TaskSession(title: view["title"].string ?? "", givenBy: Self.giver(view))
                guard taskSessions[session] != next else { continue }
                taskSessions[session] = next
                if let known = board.sessions[session] {
                    await write(board.sessionRenamed(id: session, title: displayTitle(session, stamp: known.stamp, names: [known.title])))
                }
            }
            await write(board.tasksChanged(views))
        case .hires(let hires):
            await write(board.hired(hires))
        case .hootWake:
            hootPending.lower()
            await readHoot()
        case .tidySlot:
            tidyTimer = nil
            let settings = await settings()
            armTidy(settings)
            await quiet()
        case .boardSettle:
            settleTimer = nil
            await flushSettling()
        case .idle:
            await quiet()
        case .probe:
            let waiting = probes; probes = []
            for probe in waiting { probe.yield(); probe.finish() }
        }
    }

    /// Makes sure the board knows the session, with the app's own stamp for it.
    private func see(_ id: String, info given: SessionInfo? = nil, turn: DeckMemoryFlowTurn? = nil) async {
        let known = board.sessions[id]
        if known != nil, given == nil, turn == nil { return }
        var info = given
        if info == nil { info = await deps.session(id) }
        // A session the app does not list (Hoot's own hidden one) has no row.
        if known == nil, info == nil, turn == nil { return }
        let provider = turn?.provider ?? info?.provider ?? known?.provider ?? ""
        let stamp = await stamp(id, turn: turn, info: info)
        let title = displayTitle(id, stamp: stamp, names: [turn?.title, info?.title, known?.title])
        await learnSeat(stamp.owner)
        if known == nil {
            await write(board.sessionSeen(.init(id: id, title: title, provider: provider, stamp: stamp, status: info?.status ?? "started")))
        } else {
            await write(board.sessionStamped(id: id, stamp: stamp))
            await write(board.sessionRenamed(id: id, title: title))
        }
    }

    /// What the person would call this session: the job it was given (a task agent's session is
    /// "MT job B", never the app's inner "crm-<task id>"), else the session's own name.
    private func displayTitle(_ id: String, stamp: DeckMemoryStamp?, names: [String?]) -> String {
        if let job = stamp?.job?.trimmingCharacters(in: .whitespacesAndNewlines), !job.isEmpty { return job }
        if let task = taskSessions[id]?.title.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty { return task }
        return names.compactMap { $0 }.first { !$0.isEmpty } ?? id
    }
    /// The seat's own title (the role's name as the person gave it), read once from the store.
    private func learnSeat(_ owner: DeckMemoryOwner) async {
        guard owner.isSeat, owner != .hoot, board.seatName(owner) == nil, let store,
              let info = try? await store.owners().first(where: { $0.owner == owner }) else { return }
        let name = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { await write(board.named(owner, name)) }
    }
    /// Who gave a task, in the diary's words: the person, the orchestrator, or the agent that handed it on.
    static func giver(_ task: NativeRPCValue) -> String? {
        guard let raw = (task["requestedBy"].string ?? task["creator"].string)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "me", "owner", "person", "user": return DeckMemoryAuthor.person.rawValue
        case "hoot", "copilot", "orchestrator": return DeckMemoryAuthor.orchestrator.rawValue
        default: return "agent:" + raw
        }
    }

    private func stamp(_ id: String, turn: DeckMemoryFlowTurn?, info: SessionInfo?) async -> DeckMemoryStamp {
        if let stamp = await deps.stamp(id) { return stamp }
        if let turn { return turn.owner.stamp(session: id, provider: turn.provider) }
        if let known = board.sessions[id]?.stamp { return known }
        let project = info?.project ?? ""
        return DeckMemoryStamp(owner: project.isEmpty ? .hoot : .project(project), project: project.isEmpty ? nil : project,
                               session: id, agent: info?.provider)
    }

    /// Writes what the board learned, all of one moment in ONE store transaction.
    /// 2 Nov 2026 (disk writes, Asad's app: 0.8 to 2.2 MB/s into memory.db): a busy agent session goes Working, then Idle
    /// 70 ms later, every 1 to 4 s, and each flip wrote three rows (the session, its project, its seat) and three history
    /// entries, each fully synced on its own. Now a working/idle change waits until the state has held
    /// `DeckMemoryStore.boardSettleSeconds`; Working, Idle, Working inside that time writes nothing at all. Everything else
    /// (asking the person, stopping, a new title, a task, a seat) is written at once. Whoever shows the board reads the
    /// store and hears its change notice, which now comes when a state has held: never more than about 3 s behind.
    private func write(_ changes: DeckMemoryFlowBoard.Changes) async {
        guard let store else { return }
        if changes.settle, changes.archive.isEmpty, changes.updates.allSatisfy({ $0.waitingForUser == nil }) {
            let now = deps.clock.now()
            for update in changes.updates { settling[update.id] = .init(update: update, since: now, first: settling[update.id]?.first ?? now) }
            armSettle()
            return
        }
        // A row's newer change says what it is doing now: what waited to settle for it is dropped. A row leaving the board
        // first gets what it was last doing.
        for update in changes.updates { settling[update.id] = nil }
        let leaving = changes.archive.compactMap { settling.removeValue(forKey: $0)?.update }
        guard !changes.updates.isEmpty || !changes.archive.isEmpty else { return }
        do { try await store.writeBoard(leaving + changes.updates, archive: changes.archive) }
        catch { deps.report("The board could not be updated: " + error.localizedDescription) }
    }
    /// Writes, in one transaction, every waiting row whose state has held (or that has waited `settleAtMost`).
    private func flushSettling(all: Bool = false) async {
        let now = deps.clock.now(), hold = DeckMemoryStore.boardSettleSeconds * 1000
        let due = settling.filter { all || min($0.value.since + hold, $0.value.first + Self.settleAtMost) <= now }
            .sorted { ($0.value.since, $0.key) < ($1.value.since, $1.key) }
        for (id, _) in due { settling[id] = nil }
        if !due.isEmpty, let store {
            // A state that came back to what is stored already writes nothing (the store compares before it writes).
            do { try await store.writeBoard(due.map(\.value.update), archive: []) }
            catch { deps.report("The board could not be updated: " + error.localizedDescription) }
        }
        if !all { armSettle() }
    }
    /// One timer for all waiting rows, at the soonest one's moment.
    private func armSettle() {
        guard settleTimer == nil, started else { return }
        let hold = DeckMemoryStore.boardSettleSeconds * 1000
        guard let due = settling.values.map({ min($0.since + hold, $0.first + Self.settleAtMost) }).min() else { return }
        settleTimer = deps.clock.schedule(after: max(1, due - deps.clock.now())) { [weak self] in self?.post(.boardSettle) }
    }

    // MARK: Diary capture (no AI)

    /// Copies what the session's own record gained since the last read into the diary.
    private func capture(_ id: String, turn: DeckMemoryFlowTurn?, final: Bool = false) async {
        guard let store else { return }
        let info = await deps.session(id)
        let provider = turn?.provider ?? info?.provider ?? board.sessions[id]?.provider ?? ""
        guard ["claude", "codex", "gemini"].contains(provider) else { return }
        // Gemini rewrites a message while it is still answering: read it once the turn is over.
        if provider == "gemini", turn == nil, !final { return }
        let stamp = await stamp(id, turn: turn, info: info)
        var pieces: [DeckMemoryFlowPiece] = [], record: DeckMemoryFlowState.Record?, conversation = turn?.conversationID ?? id
        if var target = await deps.locate(id, turn?.transcriptPath) {
            conversation = target.conversation
            let floor = max((info?.createdAt ?? 0) - 5_000, signalOnlyUntil[id] ?? 0)
            target.notBefore = floor > 0 ? floor : nil
            let earlier = state.records[id], fixed = target
            do {
                let read = try await Task.detached(priority: .utility) { try DeckMemoryFlowTranscripts.readNew(fixed, record: earlier) }.value
                pieces = read.pieces; record = read.record
            } catch { deps.report("A session's conversation could not be read into the diary: " + error.localizedDescription) }
        }
        if record == nil, let turn {
            // No record to read: keep what the turn-end signal itself carried.
            pieces = DeckMemoryFlowTranscripts.fromSignal(turn)
            if !pieces.isEmpty { signalOnlyUntil[id] = turn.at }
        }
        if !pieces.isEmpty {
            // "user" in a session's record is not always the person: the app says who typed it when it
            // knows (Hoot's sessions.send), otherwise who usually sits on that side of this session.
            var side = await deps.userSide(id)
            // A session the task engine started is typed into by the APP (the brief, a comment passed on),
            // whoever gave the task: Hoot wrote a message only when Hoot really did (the inbox says so).
            let task = taskSessions[id]
            if task != nil, side == .orchestrator { side = .app }
            let drafts = pieces.map { piece -> DeckMemoryDiaryDraft in
                var author = piece.author, meta = ["ai": provider]
                if piece.role == .user {
                    if let typed = DeckMemoryFlowInbox.typedSender(sessionID: id, text: piece.text) {
                        author = typed.author
                        if let giver = typed.givenBy ?? (typed.author == .app ? task?.givenBy : nil) { meta[DeckMemoryFlowNames.givenByKey] = giver }
                    } else {
                        author = side
                        if side == .app, let giver = task?.givenBy { meta[DeckMemoryFlowNames.givenByKey] = giver }
                    }
                }
                return DeckMemoryDiaryDraft(stamp: stamp, role: piece.role, text: piece.text, conversation: conversation, externalID: piece.key,
                                            at: piece.at, meta: meta, author: author)
            }
            do { _ = try await store.appendDiary(drafts) }
            catch {
                // The position is not moved: the same lines are read again at the next signal.
                deps.report("The diary could not be written: " + error.localizedDescription); return
            }
        }
        if let record, record != state.records[id] { state.records[id] = record; save() }
    }

    /// Hoot's own stream: its events after the last one already in the diary.
    private func readHoot() async {
        guard let store else { return }
        var turnEnded = false, first = false, lastRow: Int64?
        for _ in 0..<400 {
            guard let answer = await deps.hootRead(hootReader?.position),
                  let conversation = answer["conversationId"].string else { return }
            if hootReader?.conversation != conversation {
                // Another conversation is on Hoot's desk (first read, a new chat, another AI):
                // read it again from where this conversation was left.
                first = state.hoot[conversation] == nil
                hootReader = DeckMemoryFlowHootReader(conversation: conversation, cursor: state.hoot[conversation] ?? 0)
                continue
            }
            let events = (answer["events"].elements ?? []).compactMap { try? HootChatEvent(wire: $0) }
            let busy = answer["busy"].bool == true || !(answer["pending"].elements ?? []).isEmpty
            guard var reader = hootReader else { return }
            let output = reader.take(events, busy: busy)
            hootReader = reader
            if !output.pieces.isEmpty {
                let drafts = output.pieces.map { item -> DeckMemoryDiaryDraft in
                    // A message the app itself put into Hoot's chat (a task brief, a routine's report) is not the person's:
                    // its own context says so, or whoever sent it told the inbox just before.
                    var author = item.piece.author
                    if item.piece.role == .user, author == .person,
                       let sender = DeckMemoryFlowInbox.typedAuthor(sessionID: DeckMemoryFlowNames.hootSession, text: item.piece.text) { author = sender }
                    // A row of a task turn carries the task as its job, so its notes and its "where we are" topic stay with the task.
                    let stamp = DeckMemoryStamp(owner: .hoot, session: DeckMemoryFlowNames.hootSession, agent: "hoot", job: item.job)
                    return DeckMemoryDiaryDraft(stamp: stamp, role: item.piece.role, text: item.piece.text,
                        conversation: conversation, turn: item.turn.isEmpty ? nil : item.turn, externalID: item.piece.key, at: item.piece.at,
                        meta: item.source.isEmpty ? ["ai": item.provider] : ["ai": item.provider, "source": item.source], author: author)
                }
                do { lastRow = try await store.appendDiary(drafts).last?.id ?? lastRow }
                catch {
                    // Start over from the remembered position at the next move of the stream.
                    deps.report("Hoot's diary could not be written: " + error.localizedDescription)
                    hootReader = nil; return
                }
                if output.pieces.contains(where: { $0.piece.role == .user }) {
                    await queue?.hold(DeckMemoryFlowJob.turnID(DeckMemoryFlowNames.hootSession), atMost: Self.workingHold)
                }
            }
            if state.hoot[conversation] != output.cursor { state.hoot[conversation] = output.cursor; save() }
            hootBusy = output.busy
            await write(board.hoot(busy: output.busy, waiting: output.waiting))
            turnEnded = turnEnded || output.turnEnded
            if answer["hasMore"].bool != true { break }
        }
        // A chat that was there before the memory existed is kept in the diary, not sent to the helper.
        let cursorKey = DeckMemoryKeys.helperCursor + "." + DeckMemoryFlowNames.hootSession
        if first, let lastRow, (try? await store.value(cursorKey, owner: nil)) == nil {
            try? await store.setValue(String(lastRow), key: cursorKey, owner: nil)
            turnEnded = false
        }
        if turnEnded {
            let settings = await settings()
            if settings.helperOn {
                await queue?.submit(.init(id: DeckMemoryFlowJob.turnID(DeckMemoryFlowNames.hootSession), kind: .turn,
                    subject: DeckMemoryFlowNames.hootSession, title: "Hoot", dueAt: nil, createdAt: deps.clock.now()), after: settings.pause * 1000)
                deps.changed()
            }
        }
        if !hootBusy { await quiet() }
    }

    // MARK: Settings and checklist

    func settings() async -> Settings {
        var settings = Settings()
        guard let store else { return settings }
        func read(_ key: String) async -> String? { (try? await store.value(key, owner: nil))?.trimmingCharacters(in: .whitespaces) }
        settings.helperOn = await read(DeckMemoryFlowKeys.helperOn) != "0"
        settings.tidyOn = await read(DeckMemoryFlowKeys.tidyOn) != "0"
        if let pause = await read(DeckMemoryFlowKeys.helperPause).flatMap(Double.init) { settings.pause = min(600, max(3, pause)) }
        if let parallel = await read(DeckMemoryFlowKeys.helperParallel).flatMap(Int.init) { settings.parallel = min(2, max(1, parallel)) }
        if let hour = await read(DeckMemoryFlowKeys.tidyHour).flatMap(Int.init) { settings.tidyHour = min(23, max(0, hour)) }
        return settings
    }

    /// The helper as this seat's CATEGORY has it: which AI and model, the checklist, and whether the
    /// category uses the helper at all. One template per category; nothing is set per seat or per hire.
    func helperSettings(for owner: DeckMemoryOwner) async -> Helper {
        var helper = Helper()
        let template = try? await store?.template(owner.category ?? .agent)
        if let template {
            helper.on = template.has(.helper)
            if !template.checklist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { helper.checklist = template.checklist }
        }
        let chosen = (template?.helperAI ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let installed = await deps.installedAIs()
        var ai = chosen
        if !["claude", "codex", "gemini"].contains(ai) { ai = await deps.hootAI() ?? "" }
        if !installed.contains(ai) {
            if let other = ["claude", "codex", "gemini"].first(where: installed.contains) {
                if ["claude", "codex", "gemini"].contains(chosen) {
                    helper.problem = "\(DeckMemoryFlowCLIRunner.names[chosen] ?? chosen) is not installed here, so the note helper uses \(DeckMemoryFlowCLIRunner.names[other] ?? other)."
                }
                ai = other
            } else {
                ai = ai.isEmpty ? "claude" : ai
                helper.problem = "The note helper needs Claude Code, Codex or Gemini installed and signed in. The diary and the board keep filling without it."
            }
        }
        helper.ai = ai
        // A model belongs to the AI it was chosen for ("sonnet" given to Codex would fail every run).
        helper.model = DeckMemoryFlowCLIRunner.model(template?.helperModel ?? "", for: ai)
        return helper
    }

    /// "You should have noted X", said by the person: added to the checklist of that seat's category
    /// (or of all three when no seat was named), so it holds for every member and every future hire.
    @discardableResult
    public func addCorrection(_ text: String, ownerKey: String? = nil, at: Date? = nil) async -> Bool {
        guard let store else { return false }
        let categories: [DeckMemoryCategory] = ownerKey.flatMap { DeckMemoryOwner($0) }.map { [$0.category ?? .agent] } ?? DeckMemoryCategory.allCases
        let day = at ?? Date(timeIntervalSince1970: deps.clock.now() / 1000)
        var added = false
        for category in categories {
            do {
                var template = try await store.template(category)
                let current = template.checklist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? DeckMemoryFlowChecklist.defaultText : template.checklist
                guard let next = DeckMemoryFlowChecklist.appending(text, to: current, on: day, calendar: deps.calendar) else { continue }
                template.checklist = next
                try await store.saveTemplate(template)
                added = true
            } catch { deps.report("The checklist could not be saved: " + error.localizedDescription) }
        }
        return added
    }

    /// A session left. When it was the last hand on a short-lived helper seat, that seat's notes and
    /// topics fold back into its parent, after the helper has read the session's last words.
    private func closed(session: String, seat: DeckMemoryOwner) async {
        guard let store, seat.isSeat, !board.sessions.values.contains(where: { $0.stamp.owner == seat }),
              let info = try? await store.owners().first(where: { $0.owner == seat }), info.isHelper else { return }
        if (await settings()).helperOn, await queue?.contains(DeckMemoryFlowJob.turnID(session)) == true {
            state.folding = (state.folding ?? [:]).merging([session: seat.key]) { $1 }
            save()
            await queue?.runNow(DeckMemoryFlowJob.turnID(session))
        } else {
            do { try await store.foldBack(seat) } catch { deps.report("A closed helper seat's notes were not folded back: " + error.localizedDescription) }
        }
    }

    /// The fold waiting on this session's last read, done now and taken off the list.
    private func foldBack(after session: String) async {
        guard let key = state.folding?.removeValue(forKey: session) else { return }
        save()
        guard let seat = DeckMemoryOwner(key: key) else { return }
        do { try await store?.foldBack(seat) } catch { deps.report("A closed helper seat's notes were not folded back: " + error.localizedDescription) }
    }

    // MARK: Jobs

    private func run(_ job: DeckMemoryFlowJob) async -> DeckMemoryFlowJobResult {
        switch job.kind {
        case .turn:
            let result = await runTurn(session: job.subject, title: job.title).result
            // The seat folds back after the last read, and also when the helper gives up on that read
            // (signed out, at its limit: its last try failed and the job rests), so it is never stranded.
            var gaveUp = false
            if case .failed = result { gaveUp = job.attempts + 1 > DeckMemoryFlowQueue.retryDelays.count }
            if result == .done || gaveUp { await foldBack(after: job.subject) }
            return result
        case .tidy:
            guard let owner = DeckMemoryOwner(key: job.subject) else { return .done }
            let outcome = await runTidy(owner)
            await tidyFinished(job.id)
            return outcome.result
        }
    }

    /// The helper reads ONLY this session's diary rows after the last one it read.
    func runTurn(session: String, title: String = "") async -> TurnOutcome {
        guard let store else { return .init(result: .failed("Memory is still starting."), message: "Memory is still starting.") }
        // Someone else (a catch-up) is reading this session right now.
        if active.contains(session) { return .init(result: .again(afterMilliseconds: 5_000), busy: true, message: "Already being read.") }
        active.insert(session)
        defer {
            active.remove(session)
            for waiter in freeWaiters.removeValue(forKey: session) ?? [] { waiter.resume() }
        }
        guard (await settings()).helperOn else { return .init(result: .done, message: "The note helper is switched off.") }
        let cursorKey = DeckMemoryKeys.helperCursor + "." + session
        let started = deps.clock.now()
        let name = title.isEmpty ? (session == DeckMemoryFlowNames.hootSession ? "Hoot" : board.sessions[session]?.title ?? turns[session]?.title ?? session) : title
        var helper = Helper()
        func failed(_ reason: String) -> TurnOutcome {
            record(.init(kind: .turn, subject: session, title: name, at: started, ok: false, summary: reason, ai: helper.ai,
                         model: helper.model, milliseconds: deps.clock.now() - started))
            return .init(result: .failed(reason), message: reason)
        }
        do {
            let cursor = (try await store.value(cursorKey, owner: nil)).flatMap(Int64.init) ?? 0
            let found = try await store.diary(.init(session: session, after: cursor, limit: 400))
            guard let newest = found.last else { return .init(result: .done, message: "Nothing new to read.") }
            // A builder's test message and everything said in answer to it are not the person's conversation:
            // the diary keeps them, the helper never reads them.
            let entries = Self.withoutTests(found)
            guard !entries.isEmpty else {
                try await store.setValue(String(newest.id), key: cursorKey, owner: nil)
                return .init(result: .done, rows: 0, message: "Only test or handoff messages since the last read: nothing was noted from them.")
            }
            var slice = DeckMemoryFlowHelperPrompt.slice(entries)
            // Everything real was read: the position also passes the test rows left out after it.
            if !slice.more { slice.lastID = newest.id }
            let part = Array(entries.prefix(slice.rows))
            guard let first = part.first, let last = part.last else { return .init(result: .done, message: "Nothing new to read.") }
            // No AI is asked when nothing was said: only app lines and tool lines since the last read.
            guard part.contains(where: { $0.role == .user || $0.role == .assistant }) else {
                try await store.setValue(String(slice.lastID), key: cursorKey, owner: nil)
                return .init(result: slice.more ? .again(afterMilliseconds: 500) : .done, rows: slice.rows, message: "Nothing was said since the last read.")
            }
            // The app's own labels on the rows decide where the notes go: the seat, its project, the hand and the job.
            let stamp = last.labels.stamp, owner = stamp.owner
            helper = await helperSettings(for: owner)
            problem = helper.problem
            guard helper.on else {
                try await store.setValue(String(slice.lastID), key: cursorKey, owner: nil)
                return .init(result: slice.more ? .again(afterMilliseconds: 500) : .done, rows: slice.rows,
                             message: "This seat's category does not use the note helper (its template says so).")
            }
            // Only what the PERSON typed can become a preference, a correction or a rule.
            let personal = part.filter { DeckMemoryFlowRules.author($0) == DeckMemoryAuthor.person.rawValue }
            // A cheap, no-AI sign that the person is correcting something makes the helper look for it.
            let correcting = personal.contains { DeckMemoryFlowRules.correctionSignal($0.text) }
            // For reference only: the few rows just before the new ones.
            let before = ((try? await store.diary(.init(session: session, before: first.id, limit: DeckMemoryFlowHelperPrompt.referenceRows, newestFirst: true))) ?? [])
                .sorted { $0.id < $1.id }
            // Already stored, found by the app (no AI): the seat's notes most like what was just said. Shown as numbers only.
            let said = part.filter { $0.role == .user || $0.role == .assistant }.map(\.text).joined(separator: "\n")
            let stored = Array(((try? await store.similarNotes(owner: owner, text: said, limit: 10)) ?? []).prefix(10))
            // A "where we are" topic belongs to the piece of work: a hand sees its own job's, never another hand's.
            let topics = (try? await store.topics(owner, job: stamp.job)) ?? []
            let who = describe(session: session, name: name, stamp: stamp, ai: last.meta["ai"])
            let request = DeckMemoryFlowHelperRequest(ai: helper.ai, model: helper.model, system: deps.prompts.helperSystem,
                prompt: DeckMemoryFlowHelperPrompt.turn(who: who, part: slice.text, before: DeckMemoryFlowHelperPrompt.reference(before), stored: stored,
                                                        topics: topics, checklist: helper.checklist, correcting: correcting, prompts: deps.prompts))
            let answer: DeckMemoryFlowHelperAnswer, reply: DeckMemoryFlowHelperReply
            // A failed or unreadable answer is a failure, never "nothing to remember": the position does not move.
            do { reply = try await deps.runner.run(request); answer = try DeckMemoryFlowHelperPrompt.parse(reply.text) }
            catch { return failed(error.localizedDescription) }
            let isHoot = session == DeckMemoryFlowNames.hootSession
            // The AI proposed; the app's one rule function decides what is written, under the app's own labels.
            let writes = DeckMemoryFlowRules.turn(answer, stamp: stamp,
                boardRow: isHoot ? DeckMemoryFlowNames.hootBoardRow : DeckMemoryFlowNames.sessionRow(session), boardKind: isHoot ? .chat : .session,
                asking: board.sessions[session]?.status == "input", at: last.at, personSpoke: !personal.isEmpty, stored: stored, rows: first.id...last.id)
            var written = 0, corrected = false
            for draft in writes.notes {
                let note = try await store.addNote(draft)
                // The store answers honestly when the same words were already in the seat: nothing was written.
                if note.duplicateOf == nil { written += 1 }
                if draft.type == .correction || draft.type == .preference { corrected = true }
            }
            for topic in writes.topics { try await store.updateTopic(owner, title: topic.title, body: topic.text, stamp: stamp) }
            if let update = writes.board { try await store.updateBoard(update) }
            // The person seemed to correct something and no correction came out: the nightly tidy-up looks at exactly these rows again.
            if correcting, !corrected { state.add(DeckMemoryFlowState.Missed(owner: owner.key, session: session, first: first.id, last: last.id, at: started)) }
            // Only now, after every write succeeded, does the position move.
            try await store.setValue(String(slice.lastID), key: cursorKey, owner: nil)
            var wrote: [String] = []
            if written > 0 { wrote.append(written == 1 ? "1 note" : "\(written) notes") }
            if !writes.topics.isEmpty { wrote.append(writes.topics.count == 1 ? "1 topic updated" : "\(writes.topics.count) topics updated") }
            if writes.board?.lastResult != nil { wrote.append("the board's result line") }
            var summary = wrote.isEmpty ? "Read \(slice.rows) messages, nothing worth a note." : "Read \(slice.rows) messages, wrote " + wrote.joined(separator: ", ") + "."
            if !writes.refused.isEmpty { summary += " Left out: " + writes.refused.joined(separator: " ") }
            record(.init(kind: .turn, subject: session, title: name, at: started, ok: true, summary: summary, ai: helper.ai, model: helper.model,
                         milliseconds: deps.clock.now() - started, inputTokens: reply.inputTokens, outputTokens: reply.outputTokens))
            try? await store.setValue(Self.when(started, calendar: deps.calendar) + ": " + summary, key: DeckMemoryKeys.helperLastRun, owner: owner)
            return .init(result: slice.more ? .again(afterMilliseconds: 1_000) : .done, rows: slice.rows, notes: written,
                         topics: writes.topics.count, message: summary)
        } catch { return failed(error.localizedDescription) }
    }

    /// The diary rows without the turns that are no one's conversation: a builder's test, a handoff Hoot was asked
    /// to write (the marked row and every row of the same turn).
    static func withoutTests(_ entries: [DeckMemoryDiaryEntry]) -> [DeckMemoryDiaryEntry] {
        func skipped(_ entry: DeckMemoryDiaryEntry) -> Bool { entry.meta["source"].map(DeckMemoryFlowNames.skippedSources.contains) ?? false }
        let marked = entries.filter(skipped)
        guard !marked.isEmpty else { return entries }
        let turns = Set(marked.compactMap(\.turn))
        return entries.filter { !skipped($0) && !($0.turn.map(turns.contains) ?? false) }
    }

    private func describe(session: String, name: String, stamp: DeckMemoryStamp, ai: String?) -> String {
        if session == DeckMemoryFlowNames.hootSession {
            return "The person and Hoot, the orchestrator that runs their AI agents and sessions. PERSON is the person; HOOT is the AI."
        }
        let app = ai.flatMap { DeckMemoryFlowCLIRunner.names[$0] } ?? "an AI coding agent"
        var text = "\(app) at work in the session “\(name)”"
        if let project = stamp.project, !project.isEmpty { text += ", project “\(deps.projectName(project) ?? project)”" }
        return text + ". Each row says who wrote it: PERSON is the person; HOOT and LEAD are AIs handing out the work, not the person; AI is the agent itself."
    }

    private func record(_ run: DeckMemoryFlowRun) {
        state.add(run); save(); deps.changed()
    }
    private func persist(_ jobs: [DeckMemoryFlowJob]) { state.jobs = jobs; save() }
    private func save() {
        do { try deps.stateFile.save(state) } catch { deps.report("The memory flow's own state could not be saved: " + error.localizedDescription) }
    }
    static func when(_ milliseconds: Double, calendar: Calendar) -> String {
        let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_GB_POSIX"); format.dateFormat = "d MMM HH:mm"
        return format.string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    // MARK: Catch-up and "Run now"

    /// Bring this session's notes and topics up to date now.
    public func catchUp(session: String, timeout: Double) async -> Bool {
        guard started, store != nil, (await settings()).helperOn else { return false }
        let once = DeckMemoryFlowOnce()
        let work = Task { [weak self] in
            guard let self else { once.finish(false); return }
            once.finish(await self.catchUpWork(session))
        }
        let timer = deps.clock.schedule(after: timeout * 1000) { once.finish(false) }
        let done = await once.value()
        deps.clock.cancel(timer)
        _ = work
        return done
    }
    private func catchUpWork(_ session: String) async -> Bool {
        if session == DeckMemoryFlowNames.hootSession { await readHoot() } else { await capture(session, turn: turns[session]) }
        for _ in 0..<20 {
            let outcome = await runTurn(session: session)
            switch outcome.result {
            case .done:
                await queue?.remove(DeckMemoryFlowJob.turnID(session)); return true
            case .failed: return false
            case .again:
                // More to read, or the queue's own job is on it: wait for that one, then look again.
                if outcome.busy { await untilFree(session) }
            }
        }
        return false
    }
    private func untilFree(_ session: String) async {
        guard active.contains(session) else { return }
        await withCheckedContinuation { freeWaiters[session, default: []].append($0) }
    }

    /// The profile's "Run helper now" for one owner. Answers with one plain sentence.
    public func runHelperNow(ownerKey: String) async -> String {
        guard let store else { return "Memory is still starting. Try again in a moment." }
        guard (await settings()).helperOn else { return "The note helper is switched off." }
        guard let owner = DeckMemoryOwner(key: ownerKey) else { return "That owner is not known." }
        var sessions: [String] = []
        if owner == .hoot { await readHoot(); sessions.append(DeckMemoryFlowNames.hootSession) }
        let since = Date(timeIntervalSince1970: deps.clock.now() / 1000 - 14 * 86_400)
        let recent = (try? await store.diary(.init(owner: owner, since: since, limit: 1_000, newestFirst: true))) ?? []
        for entry in recent { if let id = entry.labels.session, !sessions.contains(id) { sessions.append(id) } }
        for (id, known) in board.sessions where known.stamp.owner == owner && !sessions.contains(id) { sessions.append(id) }
        guard !sessions.isEmpty else { return "Nothing has been said here yet, so there is nothing to read." }
        var read = 0, notes = 0, topics = 0, failure: String?
        for session in sessions.prefix(24) {
            if session != DeckMemoryFlowNames.hootSession { await capture(session, turn: turns[session]) }
            var readThis = false
            for _ in 0..<10 {
                let outcome = await runTurn(session: session)
                readThis = readThis || outcome.rows > 0; notes += outcome.notes; topics += outcome.topics
                if case .failed(let reason) = outcome.result { failure = reason }
                if case .again = outcome.result, !outcome.busy { continue }
                break
            }
            if readThis { read += 1 }
            if failure == nil { await queue?.remove(DeckMemoryFlowJob.turnID(session)) }
        }
        if let failure, notes == 0 { return failure }
        if read == 0 { return "Nothing new to read." }
        var parts = ["Read \(read == 1 ? "1 conversation" : "\(read) conversations")"]
        parts.append(notes == 0 ? "nothing worth a note" : "wrote \(notes == 1 ? "1 note" : "\(notes) notes")")
        if topics > 0 { parts.append("updated \(topics == 1 ? "1 topic" : "\(topics) topics")") }
        return parts.joined(separator: ", ") + "."
    }

    // MARK: Tidy-up

    private func armTidy(_ settings: Settings) {
        if let tidyTimer { deps.clock.cancel(tidyTimer) }
        tidyTimer = nil
        guard settings.tidyOn else { return }
        let now = Date(timeIntervalSince1970: deps.clock.now() / 1000)
        let next = DeckMemoryFlowTidy.nextOpening(after: now, hour: settings.tidyHour, calendar: deps.calendar)
        tidyTimer = deps.clock.schedule(after: max(1_000, next.timeIntervalSince(now) * 1000)) { [weak self] in self?.post(.tidySlot) }
    }

    /// Called whenever something went quiet. The tidy-up starts only when the whole app is.
    private func quiet() async {
        guard started, let store, !tidyRunning else { return }
        let settings = await settings()
        guard settings.tidyOn, settings.helperOn else { return }
        let now = Date(timeIntervalSince1970: deps.clock.now() / 1000)
        let slot = DeckMemoryFlowTidy.slot(now: now, hour: settings.tidyHour, calendar: deps.calendar)
        let last = try? await store.value(DeckMemoryFlowKeys.tidyLastDay, owner: nil)
        guard last != slot else { return }
        // Busy now: every later quiet() works the slot out again, so the tidy-up still runs today.
        guard !board.anyWorking, !hootBusy, await queue?.isBusy != true else { return }
        tidyRunning = true
        // Reads that failed five times were left for this pass: they get a fresh start now.
        await queue?.reviveResting()
        // No AI: a copy of the database first, so a tidy-up can always be looked behind.
        do { try await store.backup() } catch { deps.report("The memory backup did not run: " + error.localizedDescription) }
        try? await store.setValue(slot, key: DeckMemoryFlowKeys.tidyLastDay, owner: nil)
        let owners = ((try? await store.owners()) ?? []).map(\.owner)
        var queued = 0
        for owner in owners {
            let id = DeckMemoryFlowJob.tidyID(owner.key, day: slot)
            tidyJobs.insert(id); queued += 1
            await queue?.submit(.init(id: id, kind: .tidy, subject: owner.key, title: "Tidy-up", day: slot, dueAt: nil, createdAt: deps.clock.now()), after: 0)
        }
        if queued == 0 { await tidyFinished(nil) }
        deps.changed()
    }
    private var tidyJobs = Set<String>()
    private func tidyFinished(_ id: String?) async {
        if let id { tidyJobs.remove(id) }
        guard tidyJobs.isEmpty, tidyRunning else { return }
        tidyRunning = false
        // No AI: the index follows the files once more after the last owner.
        do { try await store?.reindex() } catch { deps.report("The memory index was not refreshed: " + error.localizedDescription) }
        deps.changed()
    }

    /// One seat's tidy-up, over the notes written since its last one (MEMORY-LESSONS.md change 10).
    func runTidy(_ owner: DeckMemoryOwner) async -> TidyOutcome {
        guard let store else { return .init(result: .failed("Memory is still starting."), message: "Memory is still starting.") }
        let helper = await helperSettings(for: owner)
        let started = deps.clock.now(), now = Date(timeIntervalSince1970: started / 1000)
        let lastKey = DeckMemoryFlowKeys.tidyLastDay + ".at"
        func failed(_ reason: String) -> TidyOutcome {
            record(.init(kind: .tidy, subject: owner.key, title: "Tidy-up", at: started, ok: false, summary: reason, ai: helper.ai,
                         model: helper.model, milliseconds: deps.clock.now() - started))
            return .init(result: .failed(reason), message: reason)
        }
        var used: DeckMemoryFlowHelperReply?
        func finished(_ summary: String) async -> TidyOutcome {
            try? await store.setValue(String(started), key: lastKey, owner: owner)
            try? await store.setValue(Self.when(started, calendar: deps.calendar) + ": " + summary, key: DeckMemoryKeys.tidyLastRun, owner: owner)
            // A tidy-up that asked no AI names none: no model, no tokens, no time spent.
            record(.init(kind: .tidy, subject: owner.key, title: "Tidy-up", at: started, ok: true, summary: summary, ai: used == nil ? "" : helper.ai,
                         model: used == nil ? "" : helper.model, milliseconds: used == nil ? 0 : deps.clock.now() - started,
                         inputTokens: used?.inputTokens, outputTokens: used?.outputTokens))
            return .init(result: .done, message: summary)
        }
        do {
            let since = (try await store.value(lastKey, owner: owner)).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? now.addingTimeInterval(-86_400)
            var fresh = Array(try await store.notes(.init(owner: owner, since: since, limit: 500))
                .filter { !$0.isArchived && $0.labels.date >= since }.sorted { ($0.labels.date, $0.id) < ($1.labels.date, $1.id) }
                .prefix(DeckMemoryFlowTidy.maximumNew))
            var same = 0, merged = 0, replaced = 0, closed = 0, added = 0, asked = 0
            /// Archives one note unless the person changed it since this job read it (then it waits for tomorrow).
            func archive(_ id: String, as known: DeckMemoryNote?, replacedBy: String?, reason: String) async throws -> Bool {
                guard let current = try await store.note(id: id), !current.isArchived, known == nil || current.updatedAt == known?.updatedAt else { return false }
                try await store.archiveNote(id: id, reason: reason, replacedBy: replacedBy)
                return true
            }
            // 1. No AI: notes of this seat that say exactly the same thing. The older one stays.
            var gone = Set<String>()
            for step in DeckMemoryFlowRules.exactDuplicates(fresh) {
                guard case .archive(let id, let replacedBy, let reason) = step else { continue }
                if try await archive(id, as: fresh.first { $0.id == id }, replacedBy: replacedBy, reason: reason) { gone.insert(id); same += 1 }
            }
            fresh.removeAll { gone.contains($0.id) }
            // 2. Each new note beside the older notes most like it (found by the app, no AI).
            var shown = fresh
            for note in fresh where shown.count < DeckMemoryFlowTidy.maximumShown {
                let like = (try? await store.similarNotes(owner: owner, text: note.title + "\n" + note.body, limit: DeckMemoryFlowTidy.similarPerNote)) ?? []
                for old in like where !shown.contains(where: { $0.id == old.id }) && shown.count < DeckMemoryFlowTidy.maximumShown { shown.append(old) }
            }
            // 3. The diary is looked at again ONLY where the person seemed to correct something and no correction was noted.
            let misses = (state.missed ?? []).filter { $0.owner == owner.key }
            var missedLines: [String] = []
            for miss in misses.suffix(12) {
                let rows = (try? await store.diary(.init(session: miss.session, after: miss.first - 1, limit: 60, authors: [.person]))) ?? []
                for row in rows where row.id <= miss.last && missedLines.count < 40 {
                    missedLines.append(DeckMemoryFlowHelperPrompt.line(row, cap: 1_500, format: DeckMemoryFlowHelperPrompt.stamp()))
                }
            }
            // A card over its size is never cut or rewritten by the app: it becomes a question.
            var steps: [DeckMemoryFlowRules.TidyStep] = []
            if owner.isSeat, let card = try? await store.assembledCard(owner), card.overBy > 0 {
                steps.append(.ask(text: "This card is over its size. Which parts can move into notes?",
                                  context: "It is \(card.overBy) characters over its limit of \(card.limit). The app never cuts or rewrites a card by itself.", refs: [owner.cardPath]))
            }
            let worthAsking = helper.on && (shown.count >= 2 || !missedLines.isEmpty)
            if worthAsking {
                let request = DeckMemoryFlowHelperRequest(ai: helper.ai, model: helper.model, system: deps.prompts.tidySystem,
                    prompt: DeckMemoryFlowTidy.prompt(owner: ownerName(owner), notes: shown, fresh: fresh.count, missed: missedLines.joined(separator: "\n"),
                                                      checklist: helper.checklist, prompts: deps.prompts),
                    timeoutMilliseconds: 240_000)
                let plan: DeckMemoryFlowTidy.Plan
                do { let reply = try await deps.runner.run(request); used = reply; plan = try DeckMemoryFlowTidy.parse(reply.text) }
                catch { return failed(error.localizedDescription) }
                // The AI proposed a plan in numbers; the app's one rule function decides the steps.
                steps += DeckMemoryFlowRules.tidy(plan, notes: shown, fresh: fresh.count, canAddMissed: !missedLines.isEmpty, calendar: deps.calendar)
            }
            // Carried out. Nothing is deleted: a note is archived, linked to what stays.
            let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for step in steps {
                switch step {
                case .archive(let id, let replacedBy, let reason):
                    guard try await archive(id, as: byID[id], replacedBy: replacedBy, reason: reason) else { continue }
                    if reason == "merged" || reason == "duplicate" { merged += 1 } else if reason.hasPrefix("done") { closed += 1 } else { replaced += 1 }
                case .add(let type, let title, let text):
                    // A missed correction is taken only from rows the person wrote, so it holds the person's words;
                    // it points back at those diary rows (so a rewind of that stretch takes the note with it).
                    let shownMisses = misses.suffix(12)
                    let rows: ClosedRange<Int64>? = shownMisses.map(\.first).min().flatMap { low in shownMisses.map(\.last).max().map { low...max(low, $0) } }
                    let note = try await store.addNote(.init(title: title, body: text, type: type, stamp: DeckMemoryStamp(owner: owner), source: "tidy-up",
                                                             diaryRange: rows, author: .person))
                    if note.duplicateOf == nil { added += 1 }
                case .ask: continue
                }
            }
            // Questions: never one that was asked before (answered, dismissed or still open), never more than a handful open.
            let existing = (try? await store.questions(owner: owner)) ?? []
            for step in DeckMemoryFlowRules.questionsToAsk(steps, existing: existing) {
                guard case .ask(let text, let context, let refs) = step else { continue }
                try await store.addQuestion(owner: owner, text: text, context: context, refs: refs)
                asked += 1
            }
            if !misses.isEmpty, worthAsking { state.missed?.removeAll { $0.owner == owner.key }; save() }
            var parts: [String] = []
            if same > 0 { parts.append(same == 1 ? "1 exact duplicate put away" : "\(same) exact duplicates put away") }
            if merged > 0 { parts.append(merged == 1 ? "1 note merged into a fuller one" : "\(merged) notes merged into fuller ones") }
            if replaced > 0 { parts.append(replaced == 1 ? "1 note replaced" : "\(replaced) notes replaced") }
            if closed > 0 { parts.append(closed == 1 ? "1 open item closed" : "\(closed) open items closed") }
            if added > 0 { parts.append(added == 1 ? "1 missed correction noted" : "\(added) missed corrections noted") }
            if asked > 0 { parts.append(asked == 1 ? "1 question for you" : "\(asked) questions for you") }
            if parts.isEmpty { parts.append(fresh.isEmpty ? "Nothing new to tidy" : "Looked at \(fresh.count == 1 ? "1 new note" : "\(fresh.count) new notes"), nothing to change") }
            return await finished(parts.joined(separator: ", ") + ".")
        } catch { return failed(error.localizedDescription) }
    }

    private func ownerName(_ owner: DeckMemoryOwner) -> String {
        let project = owner.projectID.map { "“" + (deps.projectName($0) ?? $0) + "”" }
        switch owner.category {
        case .orchestrator: return "Hoot, the orchestrator"
        case .lead: return "the lead of project " + (project ?? "")
        case .agent: return "the agent role “" + (owner.roleID ?? owner.key) + "”" + (project.map { " in project " + $0 } ?? "")
        case nil: return "project " + (project ?? owner.key) + " (its shared notes)"
        }
    }

    /// The profile's "Run tidy-up now" for one owner. Answers with one plain sentence.
    public func runTidyNow(ownerKey: String) async -> String {
        guard let owner = DeckMemoryOwner(key: ownerKey) else { return "That owner is not known." }
        guard (await settings()).helperOn else { return "The note helper is switched off, and the tidy-up needs it." }
        await queue?.reviveResting()
        if let store { do { try await store.backup() } catch { deps.report("The memory backup did not run: " + error.localizedDescription) } }
        let outcome = await runTidy(owner)
        try? await store?.reindex()
        if case .failed = outcome.result { return outcome.message }
        return "Tidy-up finished: " + outcome.message
    }

    // MARK: Status

    public func status() async -> DeckMemoryFlowStatus {
        let settings = await settings()
        var last: String?
        if let store { last = try? await store.value(DeckMemoryFlowKeys.tidyLastDay, owner: nil) }
        // The orchestrator's template is the one shown; a lead's or an agent's may name another AI or model.
        let helper = await helperSettings(for: .hoot)
        return DeckMemoryFlowStatus(running: started && store != nil, helperOn: settings.helperOn, helperAI: helper.ai, helperModel: helper.model,
            pauseSeconds: Int(settings.pause), parallel: settings.parallel, waiting: await queue?.waiting() ?? [],
            runningJobs: await queue?.runningJobs() ?? [], lastRuns: state.runs, tidyOn: settings.tidyOn, tidyHour: settings.tidyHour,
            tidyLastDay: last, tidyRunning: tidyRunning, problem: helper.problem ?? problem)
    }
    /// The profile changed the helper's settings: the queue follows at once.
    public func settingsChanged() async {
        let settings = await settings()
        await queue?.setParallel(settings.parallel)
        armTidy(settings)
        deps.changed()
    }
}

/// "At most one waiting": raise() is true only for the first raise since the last lower().
final class DeckMemoryFlowFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() -> Bool { lock.withLock { if raised { return false }; raised = true; return true } }
    func lower() { lock.withLock { raised = false } }
}

/// A result that is given once: by the work, or by the time limit, whichever is first.
final class DeckMemoryFlowOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Bool?
    private var waiter: CheckedContinuation<Bool, Never>?
    func finish(_ value: Bool) {
        let resume: CheckedContinuation<Bool, Never>? = lock.withLock {
            guard result == nil else { return nil }
            result = value
            defer { waiter = nil }
            return waiter
        }
        resume?.resume(returning: value)
    }
    func value() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready: Bool? = lock.withLock {
                if let result { return result }
                waiter = continuation; return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

extension DeckMemoryStamp {
    func with(session: String) -> DeckMemoryStamp { var copy = self; copy.session = session; return copy }
}
