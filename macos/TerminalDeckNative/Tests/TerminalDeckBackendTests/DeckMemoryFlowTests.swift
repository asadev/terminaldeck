import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// M2 FLOW: the queue, the debounce, the label and author stamping, the "new part only"
/// slicing, and the rules that decide what a helper's answer may write.
/// A hand-moved clock, an in-memory store and a canned helper: no AI call, no real time.
final class DeckMemoryFlowTests: XCTestCase, @unchecked Sendable {
    func testFinishedHopsAreReleasedWithoutSettling() async {
        let hops = DeckMemoryFlowHops()
        for _ in 0..<100 { hops.add {} }
        for task in hops.take() { await task.value }
        XCTAssertEqual(hops.count, 0)
    }

    // MARK: Fakes

    final class Clock: BackendDeckCoreEventsClock, @unchecked Sendable {
        private let lock = NSLock()
        private var time: Double
        private var timers: [UUID: (at: Double, order: Int, run: @Sendable () -> Void)] = [:]
        private var made = 0
        init(_ start: Double = 1_791_700_000_000) { time = start }   // 11 Oct 2026, 06:26 UTC
        func now() -> Double { lock.withLock { time } }
        func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID {
            let id = UUID()
            lock.withLock { made += 1; timers[id] = (time + max(0, milliseconds), made, run) }
            return id
        }
        func cancel(_ handle: UUID) { lock.withLock { timers[handle] = nil } }
        func advance(_ milliseconds: Double) {
            let due: [@Sendable () -> Void] = lock.withLock {
                time += milliseconds
                let ready = timers.filter { $0.value.at <= time }.sorted { ($0.value.at, $0.value.order) < ($1.value.at, $1.value.order) }
                for entry in ready { timers[entry.key] = nil }
                return ready.map(\.value.run)
            }
            for run in due { run() }
        }
    }

    actor Gate {
        private var held: [String: CheckedContinuation<Void, Never>] = [:]
        private var watchers: [CheckedContinuation<Void, Never>] = []
        private(set) var arrived: [String] = []
        func enter(_ id: String) async {
            arrived.append(id)
            let waiting = watchers; watchers = []
            for watcher in waiting { watcher.resume() }
            await withCheckedContinuation { held[id] = $0 }
        }
        func arrivals(_ count: Int) async {
            while arrived.count < count { await withCheckedContinuation { watchers.append($0) } }
        }
        func release(_ id: String) { held.removeValue(forKey: id)?.resume() }
    }
    actor Counter { var count = 0; func next() -> Int { count += 1; return count } }
    actor Log { var ids: [String] = []; func add(_ id: String) { ids.append(id) } }
    actor Saved { var jobs: [DeckMemoryFlowJob] = []; func set(_ next: [DeckMemoryFlowJob]) { jobs = next } }

    actor Store: DeckMemoryFlowStore {
        var rows: [DeckMemoryDiaryEntry] = []
        var notes: [DeckMemoryNote] = []
        var archived: [String: (reason: String, replacedBy: String?)] = [:]
        var board: [DeckMemoryBoardUpdate] = []
        var boardArchived: [String] = []
        var values: [String: String] = [:]
        var asked: [DeckMemoryQuestion] = []
        var topicUpdates: [(owner: DeckMemoryOwner, title: String, job: String?)] = []
        var templates: [DeckMemoryCategory: DeckMemoryTemplate] = [:]
        var similar: [DeckMemoryNote] = []
        var folded: [DeckMemoryOwner] = []
        var helpers: [DeckMemoryOwner: DeckMemoryOwner] = [:]
        var backups = 0, reindexes = 0
        let now: @Sendable () -> Date
        init(now: @escaping @Sendable () -> Date) { self.now = now }
        func set(_ value: String, _ key: String) { values[key] = value }
        func put(_ note: DeckMemoryNote) { notes.append(note) }
        func put(_ template: DeckMemoryTemplate) { templates[template.category] = template }
        func offer(_ notes: [DeckMemoryNote]) { similar = notes }
        func helper(_ seat: DeckMemoryOwner, under parent: DeckMemoryOwner) { helpers[seat] = parent }

        func appendDiary(_ drafts: [DeckMemoryDiaryDraft]) async throws -> [DeckMemoryDiaryEntry] {
            drafts.map { draft in
                if let key = draft.externalID, let existing = rows.first(where: { $0.externalID == key }) { return existing }
                let entry = DeckMemoryDiaryEntry(id: Int64(rows.count + 1), labels: .init(stamp: draft.stamp, date: draft.at ?? now(), type: draft.role.rawValue),
                    role: draft.role, text: draft.text, conversation: draft.conversation, turn: draft.turn, externalID: draft.externalID, meta: draft.meta,
                    author: draft.author)
                rows.append(entry); return entry
            }
        }
        func diary(_ query: DeckMemoryDiaryQuery) async throws -> [DeckMemoryDiaryEntry] {
            var found = rows.filter { row in
                (query.session == nil || row.labels.session == query.session) && (query.owner == nil || row.labels.owner == query.owner)
                    && (query.after == nil || row.id > query.after!) && (query.before == nil || row.id < query.before!)
                    && (query.roles == nil || query.roles!.contains(row.role)) && (query.authors == nil || row.author.map(query.authors!.contains) == true)
                    && (query.since == nil || row.at >= query.since!) && (query.until == nil || row.at <= query.until!)
            }
            if query.newestFirst { found.reverse() }
            return Array(found.prefix(query.limit))
        }
        func updateBoard(_ update: DeckMemoryBoardUpdate) async throws { board.append(update) }
        func archiveBoardRow(id: String) async throws { boardArchived.append(id) }
        func addNote(_ draft: DeckMemoryNoteDraft) async throws -> DeckMemoryNote {
            let date = draft.date ?? now()
            let note = DeckMemoryNote(id: "n-\(notes.count + 1)", title: draft.title, body: draft.body, type: draft.type,
                labels: .init(stamp: draft.stamp, date: date, type: draft.type.rawValue), path: "notes/n-\(notes.count + 1).md",
                supersedes: draft.supersedes, source: draft.source, updatedAt: date, validFrom: draft.validFrom, diaryRange: draft.diaryRange,
                author: draft.author)
            if let old = draft.supersedes { archived[old] = ("superseded", note.id) }
            notes.append(note); return note
        }
        func note(id: String) async throws -> DeckMemoryNote? {
            guard var note = notes.first(where: { $0.id == id }) else { return nil }
            if archived[id] != nil { note.archivedAt = now() }
            return note
        }
        func notes(_ query: DeckMemoryNoteQuery) async throws -> [DeckMemoryNote] {
            notes.filter { (query.owner == nil || $0.labels.owner == query.owner) && archived[$0.id] == nil }
        }
        func similarNotes(owner: DeckMemoryOwner, text: String, limit: Int) async throws -> [DeckMemoryNote] {
            Array(similar.filter { $0.labels.owner == owner && archived[$0.id] == nil }.prefix(limit))
        }
        func archiveNote(id: String, reason: String, replacedBy: String?) async throws { archived[id] = (reason, replacedBy) }
        func assembledCard(_ owner: DeckMemoryOwner) async throws -> DeckMemoryAssembledCard { .init(owner: owner, shared: "", own: "", limit: 6_000) }
        func template(_ category: DeckMemoryCategory) async throws -> DeckMemoryTemplate {
            templates[category] ?? DeckMemoryTemplate(category: category, card: "", checklist: "", parts: Set(DeckMemoryPart.allCases))
        }
        func saveTemplate(_ template: DeckMemoryTemplate) async throws { templates[template.category] = template }
        var seatTitles: [DeckMemoryOwner: String] = [:]
        func title(_ seat: DeckMemoryOwner, _ name: String) { seatTitles[seat] = name }
        func owners() async throws -> [DeckMemoryOwnerInfo] {
            [.init(owner: .hoot, name: "Hoot", folder: "hoot", hasCard: true, notes: notes.count, topics: 0)]
                + helpers.map { .init(owner: $0.key, name: "Helper", folder: $0.key.folder, hasCard: false, notes: 0, topics: 0, parent: $0.value) }
                + seatTitles.map { .init(owner: $0.key, name: $0.value, folder: $0.key.folder, hasCard: true, notes: 0, topics: 0) }
        }
        func foldBack(_ helper: DeckMemoryOwner) async throws { folded.append(helper) }
        func addQuestion(owner: DeckMemoryOwner, text: String, context: String, refs: [String]) async throws {
            asked.append(.init(id: Int64(asked.count + 1), owner: owner, text: text, context: context, refs: refs, askedAt: now()))
        }
        func questions(owner: DeckMemoryOwner) async throws -> [DeckMemoryQuestion] { asked.filter { $0.owner == owner } }
        func value(_ key: String, owner: DeckMemoryOwner?) async throws -> String? { values[key + "|" + (owner?.key ?? "")] ?? (owner == nil ? values[key] : nil) }
        func setValue(_ value: String?, key: String, owner: DeckMemoryOwner?) async throws { values[key + "|" + (owner?.key ?? "")] = value }
        func topics(_ owner: DeckMemoryOwner, job: String?) async throws -> [DeckMemoryTopic] { [] }
        func updateTopic(_ owner: DeckMemoryOwner, title: String, body: String, stamp: DeckMemoryStamp?) async throws { topicUpdates.append((owner, title, stamp?.job)) }
        func backup() async throws { backups += 1 }
        func reindex() async throws { reindexes += 1 }
    }

    final class Runner: DeckMemoryFlowHelperRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Result<String, NativeRPCError>]
        private var requests: [DeckMemoryFlowHelperRequest] = []
        init(_ answers: [Result<String, NativeRPCError>]) { self.answers = answers }
        var asked: [DeckMemoryFlowHelperRequest] { lock.withLock { requests } }
        func run(_ request: DeckMemoryFlowHelperRequest) async throws -> DeckMemoryFlowHelperReply {
            let next: Result<String, NativeRPCError> = lock.withLock {
                requests.append(request)
                return answers.isEmpty ? .success("{\"notes\": []}") : answers.removeFirst()
            }
            return .init(text: try next.get(), inputTokens: 2_400, outputTokens: 180)
        }
    }

    private var folder: URL!
    private let utc: Calendar = { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }()

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("m2flow-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder); DeckMemoryFlowInbox.resetForTesting() }

    private func job(_ session: String, at clock: Clock) -> DeckMemoryFlowJob {
        .init(id: DeckMemoryFlowJob.turnID(session), kind: .turn, subject: session, dueAt: nil, createdAt: clock.now())
    }
    private func day(_ hour: Int, day: Int = 11) -> Date { utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))! }
    private func note(_ id: String, _ text: String, hour: Int, day: Int = 11, type: DeckMemoryNoteType = .decision, source: String = "helper",
                      validFrom: Date? = nil, owner: DeckMemoryOwner = .hoot) -> DeckMemoryNote {
        let date = self.day(hour, day: day)
        return .init(id: id, title: text, body: text, type: type, labels: .init(owner: owner, date: date, type: type.rawValue), path: "hoot/notes/\(id).md",
                     source: source, updatedAt: date, validFrom: validFrom)
    }

    // MARK: The queue

    func testATurnEndingAgainPushesTheSameJobBackAndItRunsOnce() async {
        let clock = Clock(), ran = Log()
        let queue = DeckMemoryFlowQueue(clock: clock, run: { job in await ran.add(job.id); return .done })
        await queue.start(revivingAfter: 0)
        await queue.submit(job("s1", at: clock), after: 20_000)
        clock.advance(10_000)
        await queue.submit(job("s1", at: clock), after: 20_000)      // the session's next turn ended 10 s later
        clock.advance(15_000); await queue.settle()                   // 25 s: the first pause is over, the second is not
        let early = await ran.ids
        XCTAssertEqual(early, [], "The helper must wait for quiet, not for the first turn end.")
        clock.advance(5_001); await queue.settle()
        let late = await ran.ids
        XCTAssertEqual(late, ["turn:s1"], "One job for the session, run once.")
        let left = await queue.waiting()
        XCTAssertTrue(left.isEmpty)
    }

    func testOnlyOneJobRunsAtATimeAndTheOtherWaits() async {
        let clock = Clock(), gate = Gate()
        let queue = DeckMemoryFlowQueue(clock: clock, parallel: 1, run: { job in await gate.enter(job.id); return .done })
        await queue.start(revivingAfter: 0)
        await queue.submit(job("a", at: clock), after: 1_000)
        await queue.submit(job("b", at: clock), after: 1_000)
        clock.advance(1_000)
        await gate.arrivals(1)
        let running = await queue.runningJobs(), waiting = await queue.waiting()
        XCTAssertEqual(running.count, 1); XCTAssertEqual(waiting.count, 1)
        await gate.release(running[0].id)
        await gate.arrivals(2)
        let second = await queue.runningJobs()
        XCTAssertEqual(second.map(\.id), [waiting[0].id])
        await gate.release(waiting[0].id)
        await queue.settle()
        let done = await queue.waiting()
        XCTAssertTrue(done.isEmpty)
        let order = await gate.arrived
        XCTAssertEqual(Set(order), ["turn:a", "turn:b"])
    }

    func testTwoJobsMayRunTogetherWhenThePersonAllowsTwo() async {
        let clock = Clock(), gate = Gate()
        let queue = DeckMemoryFlowQueue(clock: clock, parallel: 2, run: { job in await gate.enter(job.id); return .done })
        await queue.start(revivingAfter: 0)
        for name in ["a", "b", "c"] { await queue.submit(job(name, at: clock), after: 0) }
        clock.advance(1)
        await gate.arrivals(2)
        let running = await queue.runningJobs()
        XCTAssertEqual(running.count, 2, "Never more than two.")
        for id in ["turn:a", "turn:b"] { await gate.release(id) }
        await gate.arrivals(3)
        await gate.release("turn:c"); await queue.settle()
    }

    func testAJobSurvivesARestart() async {
        let clock = Clock(), saved = Saved()
        let first = DeckMemoryFlowQueue(clock: clock, run: { _ in .done }, persist: { await saved.set($0) })
        await first.start(revivingAfter: 0)
        await first.submit(job("s1", at: clock), after: 20_000)
        await first.stop()                                            // the app quits before the pause is over
        let onDisk = await saved.jobs
        XCTAssertEqual(onDisk.map(\.id), ["turn:s1"])
        clock.advance(3_600_000)                                      // and is opened again an hour later

        let ran = Log()
        let second = DeckMemoryFlowQueue(jobs: onDisk, clock: clock, run: { job in await ran.add(job.id); return .done }, persist: { await saved.set($0) })
        await second.start(revivingAfter: 5_000)
        clock.advance(4_000); await second.settle()
        let tooEarly = await ran.ids
        XCTAssertEqual(tooEarly, [], "Not the instant the app opens.")
        clock.advance(1_000); await second.settle()
        let ids = await ran.ids
        XCTAssertEqual(ids, ["turn:s1"])
        let after = await saved.jobs
        XCTAssertTrue(after.isEmpty, "Done jobs leave the file.")
    }

    func testAFailedJobIsKeptWithItsReasonTriedAgainLaterAndRestsAfterFiveTries() async {
        let clock = Clock(), runs = Counter()
        let queue = DeckMemoryFlowQueue(clock: clock, run: { _ in _ = await runs.next(); return .failed("Claude Code is not signed in.") })
        await queue.start(revivingAfter: 0)
        await queue.submit(job("s1", at: clock), after: 0)
        clock.advance(1); await queue.settle()
        var kept = await queue.waiting()
        XCTAssertEqual(kept.first?.attempts, 1)
        XCTAssertEqual(kept.first?.lastError, "Claude Code is not signed in.")
        clock.advance(59_000); await queue.settle()
        var count = await runs.count
        XCTAssertEqual(count, 1, "Not before the first wait is over.")
        for wait in DeckMemoryFlowQueue.retryDelays { clock.advance(wait + 1); await queue.settle() }
        count = await runs.count
        XCTAssertEqual(count, 6, "The first try and five more.")
        kept = await queue.waiting()
        XCTAssertNil(kept.first?.dueAt, "Then it rests: nothing is lost, the diary has it.")
        clock.advance(86_400_000); await queue.settle()
        count = await runs.count
        XCTAssertEqual(count, 6)
        await queue.reviveResting()                                   // the nightly pass, or "Run now"
        clock.advance(1); await queue.settle()
        count = await runs.count
        XCTAssertEqual(count, 7)
    }

    func testAWorkingSessionHoldsItsJobUntilItsNextTurnEnd() async {
        let clock = Clock(), runs = Counter()
        let queue = DeckMemoryFlowQueue(clock: clock, run: { _ in _ = await runs.next(); return .done })
        await queue.start(revivingAfter: 0)
        await queue.submit(job("s1", at: clock), after: 20_000)
        await queue.hold("turn:s1", atMost: 900_000)                  // the person answered: it is working again
        clock.advance(60_000); await queue.settle()
        var count = await runs.count
        XCTAssertEqual(count, 0)
        await queue.submit(job("s1", at: clock), after: 20_000)
        clock.advance(20_000); await queue.settle()
        count = await runs.count
        XCTAssertEqual(count, 1)
    }

    /// The real app, 11 Oct: a job sat "waiting" with no due time after its turn had ended, until Run now was pressed.
    func testAHeldJobIsNeverLeftWithoutADueTimeAndRunsWhenItsLongWaitIsOver() async {
        let clock = Clock(), runs = Counter()
        let queue = DeckMemoryFlowQueue(clock: clock, run: { _ in _ = await runs.next(); return .done })
        await queue.start(revivingAfter: 0)
        await queue.submit(job("s1", at: clock), after: 20_000)
        await queue.hold("turn:s1", atMost: 900_000)                  // a sign of work, and then nothing more ever comes
        let held = await queue.waiting()
        XCTAssertEqual(held.first?.dueAt, clock.now() + 900_000, "Held is later, never 'no time at all'.")
        await queue.hold("turn:s1", atMost: 60_000)
        let still = await queue.waiting()
        XCTAssertEqual(still.first?.dueAt, clock.now() + 900_000, "A hold only ever pushes later.")
        clock.advance(899_000); await queue.settle()
        var count = await runs.count
        XCTAssertEqual(count, 0)
        clock.advance(1_001); await queue.settle()
        count = await runs.count
        XCTAssertEqual(count, 1, "No turn end came: it runs anyway when the long wait is over.")
    }

    func testAQuietSessionBringsAHeldJobForwardButNotOneWaitingAfterAFailure() async {
        let clock = Clock(), runs = Counter()
        let queue = DeckMemoryFlowQueue(clock: clock, run: { job in
            _ = await runs.next()
            return job.subject == "bad" ? .failed("Not signed in.") : .done
        })
        await queue.start(revivingAfter: 0)
        await queue.submit(job("s1", at: clock), after: 20_000)
        await queue.hold("turn:s1", atMost: 900_000)
        await queue.release("turn:s1", after: 20_000)                 // the session went quiet again
        let due = await queue.waiting().first?.dueAt
        XCTAssertEqual(due, clock.now() + 20_000)
        await queue.release("turn:s1", after: 600_000)
        let same = await queue.waiting().first?.dueAt
        XCTAssertEqual(same, clock.now() + 20_000, "A release only ever pulls sooner.")
        clock.advance(20_001); await queue.settle()
        var count = await runs.count
        XCTAssertEqual(count, 1)
        // A job waiting for its next try after a failure keeps that wait: a quiet session must not hammer a broken helper.
        await queue.submit(job("bad", at: clock), after: 0)
        clock.advance(1); await queue.settle()
        let failed = await queue.waiting().first
        XCTAssertEqual(failed?.attempts, 1)
        await queue.release("turn:bad", after: 1_000)
        let after = await queue.waiting().first
        XCTAssertEqual(after?.dueAt, failed?.dueAt)
        count = await runs.count
        XCTAssertEqual(count, 2)
    }

    // MARK: The engine: labels, authors and "new part only"

    private func makeEngine(_ store: Store, _ clock: Clock, _ runner: Runner, session: DeckMemoryFlowEngine.SessionInfo? = nil,
                            userSide: DeckMemoryAuthor = .person) -> DeckMemoryFlowEngine {
        var dependencies = DeckMemoryFlowEngine.Dependencies(store: { store }, clock: clock,
            stateFile: .init(url: folder.appendingPathComponent("flow-state.json")), runner: runner,
            installedAIs: { ["claude"] }, session: { id in session.map { var copy = $0; copy.id = id; return copy } }, calendar: utc)
        dependencies.userSide = { _ in userSide }
        dependencies.helperFolder = "/data/deck-memory/helper"
        return DeckMemoryFlowEngine(dependencies)
    }
    private func turn(_ session: String, prompt: String, answer: String, at clock: Clock) -> DeckMemoryFlowTurn {
        .init(sessionID: session, provider: "claude", owner: .init(kind: "agent", id: "ios", name: "Sam", project: "imatch"), projectID: "imatch",
              conversationID: "conv-" + session, prompt: prompt, lastAnswer: answer, title: "iOS login", at: clock.now(), source: "hook")
    }
    private func newPart(_ prompt: String) -> String {
        guard let start = prompt.range(of: "PART 1."), let end = prompt.range(of: "PART 2.") else { return "" }
        return String(prompt[start.upperBound..<end.lowerBound])
    }
    private let seat = DeckMemoryOwner.role(project: "imatch", role: "ios")

    func testTheAppStampsDiaryNotesAndBoardAndTheHelperCannotChooseWhereANoteGoes() async throws {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) })
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        // The AI tries to file its note under another owner and project. Those fields do not exist for the app.
        let runner = Runner([.success("""
        Here you go:
        ```json
        {"owner": "hoot", "project": "crm", "board": {"result": "Login fixed.", "state": "verified", "proof": "", "waiting": "Pick a build number"},
         "notes": [{"type": "decision", "title": "Ship Mac first", "text": "The Mac app ships before the phone app.", "owner": "role:other", "project": "crm"}]}
        ```
        """)])
        let engine = makeEngine(store, clock, runner, session: .init(id: "", title: "iOS login", provider: "claude", project: "imatch"))
        await engine.start()
        engine.post(.signal(.sessionTurnEnded(turn("s1", prompt: "Ship the Mac app first.", answer: "Done, login is fixed.", at: clock))))
        await engine.settle()

        let rows = await store.rows
        XCTAssertEqual(rows.map(\.text), ["Ship the Mac app first.", "Done, login is fixed."], "Word for word.")
        XCTAssertEqual(rows.map(\.role), [.user, .assistant])
        XCTAssertEqual(rows.map(\.author), [.person, .agent], "Who really wrote each row.")
        for row in rows {
            XCTAssertEqual(row.labels.owner, seat, "The seat, never the hire."); XCTAssertEqual(row.labels.project, "imatch")
            XCTAssertEqual(row.labels.session, "s1"); XCTAssertEqual(row.labels.agent, "Sam", "The hire's name is only a detail.")
            XCTAssertEqual(row.conversation, "conv-s1"); XCTAssertEqual(row.meta["ai"], "claude")
        }
        XCTAssertTrue(runner.asked.isEmpty, "No AI before the pause is over.")

        clock.advance(20_001); await engine.settle()
        let notes = await store.notes
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].labels.owner, seat, "The app's label, not the AI's.")
        XCTAssertEqual(notes[0].labels.project, "imatch"); XCTAssertEqual(notes[0].labels.session, "s1")
        XCTAssertEqual(notes[0].source, "helper"); XCTAssertEqual(notes[0].type, .decision)
        XCTAssertEqual(notes[0].diaryRange, 1...2, "A note points back at the diary rows it came from.")
        XCTAssertEqual(notes[0].validFrom, rows[1].at, "True from when it was said, not from when the helper ran.")
        let result = await store.board.last { $0.lastResult != nil }
        XCTAssertEqual(result?.id, "session:s1"); XCTAssertEqual(result?.stamp.owner, seat)
        XCTAssertEqual(result?.state, .reported, "Verified without proof is only reported.")
        XCTAssertEqual(result?.waitingForUser, "Pick a build number")
        let template = try await store.template(.agent)
        XCTAssertTrue(template.checklist.contains("Write a note when"), "The category's template got the default checklist.")
        XCTAssertTrue(runner.asked[0].prompt.contains("A correction from the person"), "And the helper was given it.")
        XCTAssertEqual(runner.asked[0].model, "sonnet")
        let status = await engine.status()
        XCTAssertEqual(status.lastRuns.first?.inputTokens, 2_400, "What the run used is kept with it."); XCTAssertEqual(status.lastRuns.first?.outputTokens, 180)
        await engine.stop()
    }

    func testTheHelperReadsOnlyTheNewPartOfThatOneSession() async throws {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) })
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let runner = Runner([])
        let engine = makeEngine(store, clock, runner, session: .init(id: "", title: "t", provider: "claude", project: "imatch"))
        await engine.start()
        engine.post(.signal(.sessionTurnEnded(turn("s1", prompt: "FIRST-QUESTION", answer: "FIRST-ANSWER", at: clock))))
        engine.post(.signal(.sessionTurnEnded(turn("s2", prompt: "OTHER-SESSION", answer: "OTHER-ANSWER", at: clock))))
        await engine.settle()
        clock.advance(20_001); await engine.settle()
        clock.advance(60_000)
        engine.post(.signal(.sessionTurnEnded(turn("s1", prompt: "SECOND-QUESTION", answer: "SECOND-ANSWER", at: clock))))
        await engine.settle()
        clock.advance(20_001); await engine.settle()

        let asked = runner.asked.map(\.prompt)
        XCTAssertEqual(asked.count, 3, "One question per session and stretch.")
        let first = try XCTUnwrap(asked.first { newPart($0).contains("FIRST-QUESTION") })
        XCTAssertFalse(first.contains("OTHER-SESSION"), "Another session's words are never in it.")
        let second = try XCTUnwrap(asked.first { newPart($0).contains("SECOND-QUESTION") })
        XCTAssertTrue(newPart(second).contains("SECOND-ANSWER"))
        XCTAssertFalse(newPart(second).contains("FIRST-QUESTION"), "What was read once is not in the new part again.")
        XCTAssertFalse(newPart(second).contains("FIRST-ANSWER"))
        XCTAssertTrue(second.contains("FIRST-ANSWER"), "The rows just before are shown, marked as reference only.")
        XCTAssertFalse(second.contains("OTHER-SESSION"))
        XCTAssertTrue(newPart(second).contains("PERSON: SECOND-QUESTION")); XCTAssertTrue(newPart(second).contains("AI: SECOND-ANSWER"))
        // Nothing new: no question at all.
        let before = runner.asked.count
        let outcome = await engine.runTurn(session: "s1")
        XCTAssertEqual(outcome.result, .done); XCTAssertEqual(runner.asked.count, before)
        await engine.stop()
    }

    func testAFailedHelperLosesNothingAndReadsTheSamePartNextTime() async throws {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) })
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let runner = Runner([.failure(NativeRPCError(code: "failed", message: "Claude Code is not signed in, so the note helper could not run.")),
                             .success("{\"notes\": [{\"type\": \"result\", \"title\": \"Kept\", \"text\": \"It was kept.\"}]}")])
        let engine = makeEngine(store, clock, runner, session: .init(id: "", title: "t", provider: "claude", project: "imatch"))
        await engine.start()
        engine.post(.signal(.sessionTurnEnded(turn("s1", prompt: "KEEP-ME", answer: "KEPT", at: clock))))
        await engine.settle()
        clock.advance(20_001); await engine.settle()
        var notes = await store.notes
        XCTAssertTrue(notes.isEmpty)
        var status = await engine.status()
        XCTAssertEqual(status.lastRuns.first?.ok, false)
        XCTAssertEqual(status.lastRuns.first?.summary, "Claude Code is not signed in, so the note helper could not run.", "The reason is logged.")
        XCTAssertEqual(status.waiting.first?.attempts, 1, "The job waits for a later try.")
        let cursor = try await store.value(DeckMemoryKeys.helperCursor + ".s1", owner: nil)
        XCTAssertNil(cursor, "The position moves only after the notes were written.")
        clock.advance(60_001); await engine.settle()
        notes = await store.notes
        XCTAssertEqual(notes.map(\.title), ["Kept"])
        XCTAssertTrue(newPart(runner.asked.last?.prompt ?? "").contains("KEEP-ME"), "The same part is read again.")
        status = await engine.status()
        XCTAssertTrue(status.waiting.isEmpty)
        await engine.stop()
    }

    func testMemoryOffKeepsTheDiaryAndAsksNoAI() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let engine = makeEngine(store, clock, runner, session: .init(id: "", title: "t", provider: "claude", project: "imatch"))
        await engine.start()
        var off = turn("s1", prompt: "Hello", answer: "Hi", at: clock); off.owner.memoryOn = false
        engine.post(.signal(.sessionTurnEnded(off)))
        await engine.settle(); clock.advance(60_000); await engine.settle()
        let rows = await store.rows
        XCTAssertEqual(rows.count, 2); XCTAssertTrue(runner.asked.isEmpty)
        await engine.stop()
    }

    func testTheHelpersOwnRunIsNeverCapturedSoItCannotTriggerItself() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let engine = makeEngine(store, clock, runner, session: .init(id: "", title: "t", provider: "claude", project: "imatch"))
        await engine.start()
        var own = turn("helper-run", prompt: "You keep the long-term notes…", answer: "{\"notes\": []}", at: clock)
        own.cwd = "/data/deck-memory/helper"
        engine.post(.signal(.sessionTurnEnded(own)))
        await engine.settle(); clock.advance(60_000); await engine.settle()
        let rows = await store.rows, status = await engine.status()
        XCTAssertTrue(rows.isEmpty, "No diary rows."); XCTAssertTrue(status.waiting.isEmpty, "No next run."); XCTAssertTrue(runner.asked.isEmpty)
        XCTAssertEqual(DeckMemoryFlowCLIRunner.arguments(.init(ai: "claude", model: "sonnet", system: "s", prompt: "p"), answerFile: "/x")?.arguments.contains("--tools"), true)
        let arguments = DeckMemoryFlowCLIRunner.arguments(.init(ai: "claude", model: "sonnet", system: "s", prompt: "p"), answerFile: "/x")?.arguments ?? []
        XCTAssertEqual(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] }, "", "The helper has no tools.")
        XCTAssertTrue(arguments.contains("--no-session-persistence")); XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertEqual(arguments.firstIndex(of: "--setting-sources").map { arguments[$0 + 1] }, "", "No settings, so no hooks.")
        await engine.stop()
    }

    func testOnlyThePersonsOwnWordsCanBecomeAPreferenceOrACorrection() async throws {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) })
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let answer = "{\"notes\": [{\"type\": \"preference\", \"title\": \"Short answers\", \"text\": \"Answers must be short.\"}, {\"type\": \"result\", \"title\": \"Login\", \"text\": \"The login screen was rebuilt.\"}]}"
        let runner = Runner([.success(answer), .success(answer)])
        // A session Hoot started: the "user" side is Hoot, not the person.
        let engine = makeEngine(store, clock, runner, session: .init(id: "", title: "t", provider: "claude", project: "imatch"), userSide: .orchestrator)
        await engine.start()
        engine.post(.signal(.sessionTurnEnded(turn("s1", prompt: "Always answer in short sentences.", answer: "Done, login rebuilt.", at: clock))))
        await engine.settle(); clock.advance(20_001); await engine.settle()
        var rows = await store.rows, notes = await store.notes
        XCTAssertEqual(rows.first?.author, .orchestrator)
        XCTAssertEqual(notes.map(\.type), [.result], "Hoot's words do not become the person's preference.")
        XCTAssertTrue(newPart(runner.asked[0].prompt).contains("HOOT (the orchestrator): Always answer"))
        let status = await engine.status()
        XCTAssertTrue(status.lastRuns.first?.summary.contains("Left out") == true, "And the run says what it left out.")

        // The same session, but this message the app saw Hoot type; the next one the person typed themselves.
        clock.advance(60_000)
        DeckMemoryFlowInbox.typedByOrchestrator(sessionID: "s2", text: "Rebuild the  login screen", at: clock.now())
        XCTAssertEqual(DeckMemoryFlowInbox.typedAuthor(sessionID: "s2", text: "Rebuild the login screen\n"), .orchestrator)
        XCTAssertNil(DeckMemoryFlowInbox.typedAuthor(sessionID: "s2", text: "Rebuild the login screen"), "One typed text answers for one message.")
        let person = makeEngine(store, clock, runner, session: .init(id: "", title: "t", provider: "claude", project: "imatch"), userSide: .person)
        await engine.stop(); await person.start()
        person.post(.signal(.sessionTurnEnded(turn("s3", prompt: "Always answer in short sentences, please.", answer: "Understood.", at: clock))))
        await person.settle(); clock.advance(20_001); await person.settle()
        rows = await store.rows; notes = await store.notes
        XCTAssertEqual(rows.first { $0.labels.session == "s3" }?.author, .person)
        XCTAssertEqual(notes.filter { $0.labels.session == "s3" }.map(\.type), [.preference, .result])
        await person.stop()
    }

    func testABuildersTestMessageIsKeptInTheDiaryButNeverReadByTheHelper() async throws {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let engine = makeEngine(store, clock, runner)
        await engine.start()
        let stamp = DeckMemoryStamp(owner: .hoot, session: "hoot", agent: "hoot")
        _ = try await store.appendDiary([
            .init(stamp: stamp, role: .user, text: "Build-lane check: always answer OK.", turn: "t1", externalID: "k1", meta: ["source": "dev-test"], author: .tool),
            .init(stamp: stamp, role: .assistant, text: "OK", turn: "t1", externalID: "k2", author: .orchestrator),
        ])
        let only = await engine.runTurn(session: "hoot")
        XCTAssertEqual(only.result, .done); XCTAssertTrue(runner.asked.isEmpty, "No AI is asked about a test turn.")
        let cursor = try await store.value(DeckMemoryKeys.helperCursor + ".hoot", owner: nil)
        XCTAssertEqual(cursor, "2", "And it is not looked at again.")
        _ = try await store.appendDiary([
            .init(stamp: stamp, role: .user, text: "Ship on Monday.", turn: "t2", externalID: "k3", author: .person),
            .init(stamp: stamp, role: .user, text: "Second test: say OK.", turn: "t3", externalID: "k4", meta: ["source": "dev-test"], author: .tool),
            .init(stamp: stamp, role: .assistant, text: "OK again", turn: "t3", externalID: "k5", author: .orchestrator),
        ])
        _ = await engine.runTurn(session: "hoot")
        XCTAssertEqual(runner.asked.count, 1)
        XCTAssertTrue(newPart(runner.asked[0].prompt).contains("Ship on Monday.")); XCTAssertFalse(runner.asked[0].prompt.contains("OK again"))
        XCTAssertFalse(runner.asked[0].prompt.contains("Second test"))
        await engine.stop()
    }

    actor Busy { var now = 0, most = 0; func enter() { now += 1; most = max(most, now) }; func leave() { now -= 1 } }
    final class SlowRunner: DeckMemoryFlowHelperRunning, @unchecked Sendable {
        let busy = Busy()
        private let lock = NSLock(); private var count = 0
        var runs: Int { lock.withLock { count } }
        func run(_ request: DeckMemoryFlowHelperRequest) async throws -> DeckMemoryFlowHelperReply {
            lock.withLock { count += 1 }
            await busy.enter()
            for _ in 0..<200 { await Task.yield() }     // long enough for any other job to start, if the queue let it
            await busy.leave()
            return .init(text: "{\"notes\": []}")
        }
    }

    func testManySessionsFinishingAtOnceNeverRunMoreHelperJobsThanTheCap() async {
        for (setting, cap) in [(nil, 1), ("2", 2), ("9", 2)] as [(String?, Int)] {
            let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = SlowRunner()
            await store.set("0", DeckMemoryFlowKeys.tidyOn)
            if let setting { await store.set(setting, DeckMemoryFlowKeys.helperParallel) }
            var dependencies = DeckMemoryFlowEngine.Dependencies(store: { store }, clock: clock,
                stateFile: .init(url: folder.appendingPathComponent("cap-\(cap)-\(setting ?? "default").json")), runner: runner, installedAIs: { ["claude"] },
                session: { id in .init(id: id, title: "t", provider: "claude", project: "imatch") }, calendar: utc)
            dependencies.helperFolder = "/data/deck-memory/helper"
            let engine = DeckMemoryFlowEngine(dependencies)
            await engine.start()
            for number in 1...12 { engine.post(.signal(.sessionTurnEnded(turn("s\(number)", prompt: "Question \(number)", answer: "Answer \(number)", at: clock)))) }
            await engine.settle()
            clock.advance(20_001); await engine.settle(); await engine.settle()
            let most = await runner.busy.most
            XCTAssertEqual(runner.runs, 12, "Every session is read, one after another.")
            XCTAssertLessThanOrEqual(most, cap, "Twelve sessions finishing at once, helper.parallel = \(setting ?? "not set"): never more than \(cap) at a time.")
            XCTAssertGreaterThanOrEqual(most, 1)
            await engine.stop()
        }
    }

    func testWithTheHelperSwitchedOffNoAIIsAskedAtAllAndTheDiaryStillFills() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.helperOn)                 // tidy-up left ON: it needs the helper, so it must stay quiet too
        let engine = makeEngine(store, clock, runner, session: .init(id: "", title: "t", provider: "claude", project: "imatch"))
        await engine.start()
        for number in 1...3 { engine.post(.signal(.sessionTurnEnded(turn("s\(number)", prompt: "No, I said blue \(number).", answer: "Done \(number).", at: clock)))) }
        engine.post(.sessionStatus(id: "s1", status: "idle")); engine.post(.tidySlot); engine.post(.idle)
        await engine.settle()
        clock.advance(86_400_000); await engine.settle(); await engine.settle()   // a whole day, past the tidy-up's hour
        let rows = await store.rows, status = await engine.status(), backups = await store.backups
        XCTAssertEqual(rows.count, 6, "The diary keeps every word.")
        XCTAssertTrue(runner.asked.isEmpty, "No helper run, no tidy-up run: nothing AI-side at all.")
        XCTAssertTrue(status.waiting.isEmpty && status.runningJobs.isEmpty, "And nothing is queued for later.")
        XCTAssertFalse(status.helperOn); XCTAssertEqual(backups, 0)
        let caught = await engine.catchUp(session: "s1", timeout: 1), helper = await engine.runHelperNow(ownerKey: "hoot"), tidy = await engine.runTidyNow(ownerKey: "hoot")
        XCTAssertFalse(caught); XCTAssertEqual(helper, "The note helper is switched off."); XCTAssertTrue(tidy.contains("switched off"))
        XCTAssertTrue(runner.asked.isEmpty)
        // Only the tidy-up off: turns are still read, the nightly pass never starts.
        await store.set("1", DeckMemoryFlowKeys.helperOn); await store.set("0", DeckMemoryFlowKeys.tidyOn)
        engine.post(.signal(.sessionTurnEnded(turn("s9", prompt: "Ship on Monday.", answer: "Noted.", at: clock))))
        await engine.settle(); clock.advance(20_001); await engine.settle()
        engine.post(.tidySlot); await engine.settle(); clock.advance(86_400_000); await engine.settle()
        XCTAssertEqual(runner.asked.count, 1, "One helper read, no tidy-up question.")
        let after = await store.backups
        XCTAssertEqual(after, 0)
        await engine.stop()
    }

    func testCodexChatDropsFlowCarriesChatCompletionToTheStoredBoard() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let engine = makeEngine(store, clock, runner)
        await engine.start()
        engine.post(.sessionSeen(.init(id: "codex-job", title: "Scratch chat", provider: "codex", project: "imatch", chat: true)))
        engine.post(.sessionStatus(id: "codex-job", status: "input"))
        engine.post(.sessionExit(id: "codex-job", code: 0))
        engine.post(.sessionStatus(id: "codex-job", status: "completed"))
        await engine.settle()
        let rows = await store.board.filter { $0.id == "session:codex-job" }
        XCTAssertEqual(rows.last?.doing, "Finished")
        XCTAssertEqual(rows.last?.waitingForUser, "")
        await engine.stop()
    }

    func testTheBoardFollowsSessionEventsWithoutAnyAI() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let engine = makeEngine(store, clock, runner)
        await engine.start()
        engine.post(.sessionSeen(.init(id: "s1", title: "Website", provider: "claude", project: "imatch")))
        engine.post(.sessionStatus(id: "s1", status: "working"))
        engine.post(.sessionStatus(id: "s1", status: "input"))
        engine.post(.sessionExit(id: "s1", code: 2))
        engine.post(.sessionRemoved(id: "s1"))
        await engine.settle()
        let mine = await store.board.filter { $0.id == "session:s1" }
        XCTAssertEqual(mine.map(\.doing), ["Started", "Working", "Waiting for you", "Stopped with an error (code 2)"])
        XCTAssertNil(mine[1].waitingForUser, "Working again does not wipe a waiting line the helper wrote.")
        XCTAssertNotEqual(mine[2].waitingForUser ?? "", ""); XCTAssertEqual(mine[3].waitingForUser, "", "The app takes away only its own line.")
        XCTAssertEqual(mine[0].stamp.owner, .project("imatch"))
        let project = await store.board.filter { $0.id == "project:imatch" }.compactMap(\.doing)
        XCTAssertEqual(project.first, "Quiet"); XCTAssertTrue(project.contains("1 session working")); XCTAssertTrue(project.contains("1 waiting for you"))
        let gone = await store.boardArchived
        XCTAssertEqual(gone, ["session:s1"], "A closed session leaves the board, never the database.")
        XCTAssertTrue(runner.asked.isEmpty)
        await engine.stop()
    }

    func testSeveralHandsOnOneSeatShareItsRowAndAClosedHelperSeatFoldsBack() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let helperSeat = DeckMemoryOwner.role(project: "imatch", role: "db-fixer--helper-1")
        await store.helper(helperSeat, under: .role(project: "imatch", role: "db-fixer"))
        var dependencies = DeckMemoryFlowEngine.Dependencies(store: { store }, clock: clock,
            stateFile: .init(url: folder.appendingPathComponent("flow-state.json")), runner: runner, installedAIs: { ["claude"] }, calendar: utc)
        let seat = self.seat
        dependencies.stamp = { id in
            id == "h1" ? DeckMemoryStamp(owner: helperSeat, project: "imatch", session: id, agent: "Tmp", hand: 1, job: "Fix index")
                : DeckMemoryStamp(owner: seat, project: "imatch", session: id, agent: "Sam", hand: id == "a" ? 1 : 2, job: id == "a" ? "Login" : "Signup")
        }
        let engine = DeckMemoryFlowEngine(dependencies)
        await engine.start()
        for id in ["a", "b", "h1"] { engine.post(.sessionSeen(.init(id: id, title: "Hand " + id, provider: "claude", project: "imatch"))) }
        engine.post(.sessionStatus(id: "a", status: "working"))
        engine.post(.sessionRemoved(id: "h1"))
        await engine.settle()
        let rows = await store.board
        XCTAssertEqual(rows.first { $0.id == "session:b" }?.stamp.hand, 2, "One row per hand, stamped with its hand and job.")
        XCTAssertEqual(rows.first { $0.id == "session:b" }?.stamp.job, "Signup")
        XCTAssertEqual(rows.last { $0.id == "agent:" + seat.key }?.doing, "2 hands, 1 working")
        let folded = await store.folded
        XCTAssertEqual(folded, [helperSeat], "Its notes go back to the seat it worked under.")
        await engine.stop()
    }

    /// The helper AI is signed out when a short-lived helper seat's last hand closes, and the app restarts
    /// meanwhile: the seat still folds back once the helper has given up, never stranded in its own space.
    func testAClosedHelperSeatFoldsBackWhenTheHelperGivesUpEvenAcrossARestart() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) })
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let helperSeat = DeckMemoryOwner.role(project: "imatch", role: "db-fixer--helper-1")
        await store.helper(helperSeat, under: .role(project: "imatch", role: "db-fixer"))
        let signedOut = NativeRPCError(code: "failed", message: "Claude Code is not signed in, so the note helper could not run.")
        let runner = Runner(Array(repeating: .failure(signedOut), count: 20))
        let stateFile = folder.appendingPathComponent("fold-state.json")
        func engine() -> DeckMemoryFlowEngine {
            var dependencies = DeckMemoryFlowEngine.Dependencies(store: { store }, clock: clock, stateFile: .init(url: stateFile), runner: runner,
                installedAIs: { ["claude"] }, session: { id in .init(id: id, title: "t", provider: "claude", project: "imatch") }, calendar: utc)
            dependencies.helperFolder = "/data/deck-memory/helper"
            dependencies.stamp = { id in DeckMemoryStamp(owner: helperSeat, project: "imatch", session: id, agent: "Tmp", hand: 1, job: "Fix index") }
            return DeckMemoryFlowEngine(dependencies)
        }
        let first = engine()
        await first.start()
        first.post(.sessionSeen(.init(id: "h1", title: "Hand", provider: "claude", project: "imatch")))
        first.post(.signal(.sessionTurnEnded(turn("h1", prompt: "Fix the index.", answer: "Fixed it.", at: clock))))
        first.post(.sessionRemoved(id: "h1"))
        await first.settle()
        var folded = await store.folded
        XCTAssertEqual(runner.asked.count, 1, "The last read is asked for at once.")
        XCTAssertEqual(folded, [], "It waits while the helper may still read the session's last words.")
        await first.stop()                                            // the app quits after the first failed try

        let second = engine()
        await second.start()
        for _ in DeckMemoryFlowQueue.retryDelays { clock.advance(DeckMemoryFlowQueue.retryDelays.max()! + 60_000); await second.settle() }
        folded = await store.folded
        XCTAssertEqual(runner.asked.count, 1 + DeckMemoryFlowQueue.retryDelays.count, "Every try was made, across the restart.")
        XCTAssertEqual(folded, [helperSeat], "After the last try its notes go back to the seat it worked under.")
        await second.stop()
        XCTAssertNil(DeckMemoryFlowStateFile(url: stateFile).load().folding?["h1"], "Nothing is left waiting.")
    }

    // MARK: What the real app showed on 11 Oct

    /// A "working" sign that arrives AFTER the turn end left the job waiting for a turn end that never came.
    func testASignOfWorkAfterTheTurnEndNeverStrandsTheHelpersJob() async {
        for quietAgain in [true, false] {
            let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
            await store.set("0", DeckMemoryFlowKeys.tidyOn)
            var dependencies = DeckMemoryFlowEngine.Dependencies(store: { store }, clock: clock,
                stateFile: .init(url: folder.appendingPathComponent("strand-\(quietAgain).json")), runner: runner, installedAIs: { ["claude"] },
                session: { id in .init(id: id, title: "t", provider: "claude", project: "imatch") }, calendar: utc)
            dependencies.helperFolder = "/data/deck-memory/helper"
            let engine = DeckMemoryFlowEngine(dependencies)
            await engine.start()
            engine.post(.sessionSeen(.init(id: "s1", title: "t", provider: "claude", project: "imatch")))
            engine.post(.signal(.sessionTurnEnded(turn("s1", prompt: "Name the release.", answer: "It is named Harbour Lantern.", at: clock))))
            engine.post(.sessionStatus(id: "s1", status: "working"))          // the screen reader is a moment behind the hook
            await engine.settle()
            var status = await engine.status()
            XCTAssertNotNil(status.waiting.first?.dueAt, "A waiting job always says when it will run.")
            if quietAgain { engine.post(.sessionStatus(id: "s1", status: "waiting")); await engine.settle() }
            clock.advance(20_001); await engine.settle()
            if quietAgain {
                XCTAssertEqual(runner.asked.count, 1, "The session is quiet again: the helper reads after the usual pause.")
            } else {
                XCTAssertTrue(runner.asked.isEmpty, "Still looks busy: not yet.")
                clock.advance(DeckMemoryFlowEngine.workingHold); await engine.settle()
                XCTAssertEqual(runner.asked.count, 1, "No turn end and no quieter state ever came: it is read anyway.")
            }
            status = await engine.status()
            XCTAssertTrue(status.waiting.isEmpty)
            await engine.stop()
        }
    }

    /// The task engine types the brief: it is the APP's line, with who gave the task. Hoot only when Hoot wrote it.
    func testABriefTypedByTheAppIsTheAppsWithWhoGaveTheTask() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        // Every session the task engine starts is marked as started for Hoot, whoever gave the task.
        let engine = makeEngine(store, clock, runner, session: .init(id: "", title: "crm-0000", provider: "claude", project: "imatch"), userSide: .orchestrator)
        await engine.start()
        func task(_ id: String, _ session: String, _ title: String, by: String) -> NativeRPCValue {
            .object([.init("id", .string(id)), .init("title", .string(title)), .init("sessionId", .string(session)), .init("requestedBy", .string(by)),
                     .init("project", .string("/work/imatch")), .init("status", .string("Working on it"))])
        }
        engine.post(.tasks([task("local:1", "s1", "Name the release", by: "me"), task("local:2", "s2", "Roll call", by: "hoot")]))
        engine.post(.signal(.sessionTurnEnded(turn("s1", prompt: "Read /data/remote/task-briefs/1.md and do exactly what it says.", answer: "Harbour Lantern.", at: clock))))
        engine.post(.signal(.sessionTurnEnded(turn("s2", prompt: "Read /data/remote/task-briefs/2.md and do exactly what it says.", answer: "Present.", at: clock))))
        // A session Hoot started itself with a brief of its own: Hoot wrote that one.
        engine.post(.signal(.sessionTurnEnded(turn("s3", prompt: "Please rebuild the login screen.", answer: "Done.", at: clock))))
        // And a line the task engine said it typed, carrying the person's comment.
        DeckMemoryFlowInbox.typed(sessionID: "s4", text: "[Terminal Deck] The owner wrote on your task: Any news?", by: .app, givenBy: "person", at: clock.now())
        engine.post(.signal(.sessionTurnEnded(turn("s4", prompt: "[Terminal Deck] The owner wrote on your task: Any news?", answer: "Nearly done.", at: clock))))
        await engine.settle()
        let rows = await store.rows
        func user(_ session: String) -> DeckMemoryDiaryEntry? { rows.first { $0.labels.session == session && $0.role == .user } }
        XCTAssertEqual(user("s1")?.author, .app, "The app typed the brief.")
        XCTAssertEqual(user("s1")?.meta[DeckMemoryFlowNames.givenByKey], "person", "For a task the person made.")
        XCTAssertEqual(user("s2")?.author, .app); XCTAssertEqual(user("s2")?.meta[DeckMemoryFlowNames.givenByKey], "orchestrator", "Hoot gave this one; the app still typed it.")
        XCTAssertEqual(user("s3")?.author, .orchestrator, "No task behind it: Hoot's own words.")
        XCTAssertNil(user("s3")?.meta[DeckMemoryFlowNames.givenByKey])
        XCTAssertEqual(user("s4")?.author, .app); XCTAssertEqual(user("s4")?.meta[DeckMemoryFlowNames.givenByKey], "person")
        XCTAssertEqual(rows.first { $0.labels.session == "s1" && $0.role == .assistant }?.author, .agent)
        // The board names the session by its job, never by the app's inner name.
        let named = await store.board.last { $0.id == "session:s1" }
        XCTAssertEqual(named?.title, "Name the release")
        let status = await engine.status()
        XCTAssertEqual(status.waiting.first { $0.subject == "s1" }?.title, "Name the release", "And so does the helper's waiting line.")
        XCTAssertEqual(DeckMemoryFlowEngine.giver(.object([.init("requestedBy", .string("ios-engineer"))])), "agent:ios-engineer")
        await engine.stop()
    }

    func testATaskIsFiledUnderItsProjectNeverUnderItsFolderPath() { PROJMadeUp.with {   // L4: the made-up registered projects
        var board = DeckMemoryFlowBoard()
        func task(_ id: String, folder: String, project: String? = nil) -> NativeRPCValue {
            var fields: [NativeRPCValue.Field] = [.init("id", .string(id)), .init("title", .string("T " + id)), .init("project", .string(folder)), .init("status", .string("Open"))]
            if let project { fields.append(.init("projectId", .string(project))) }
            return .object(fields)
        }
        let changes = board.tasksChanged([
            task("old", folder: "/work/imatch"),                     // made before tasks carried a project id
            task("sub", folder: "/work/imatch/ios"),
            task("own", folder: "/work/imatch", project: "crm"),     // its own id wins over the folder
            task("else", folder: "/Users/someone/elsewhere"),
            .object([.init("id", .string("none")), .init("title", .string("No folder"))]),
        ])
        func owner(_ id: String) -> DeckMemoryOwner? { changes.updates.first { $0.id == "task:" + id }?.stamp.owner }
        XCTAssertEqual(owner("old"), .project("imatch"), "The same project its sessions are under.")
        XCTAssertEqual(owner("sub"), .project("imatch")); XCTAssertEqual(owner("own"), .project("crm"))
        XCTAssertEqual(owner("else"), .project(PROJProjects.independentID)); XCTAssertEqual(owner("none"), .hoot)
        XCTAssertEqual(changes.updates.first { $0.id == "task:old" }?.stamp.project, "imatch")
        XCTAssertFalse(changes.updates.contains { $0.stamp.owner.key.contains("users-imatch") }, "No row is filed under a folder path.")
        // The live list of projects decides when the app has one.
        var live = DeckMemoryFlowBoard(projectOf: { id, folder in id ?? (folder.hasPrefix("/work/shop") ? "shop" : PROJProjects.independentID) })
        let placed = live.tasksChanged([task("a", folder: "/work/shop/site")])
        XCTAssertEqual(placed.updates.first?.stamp.owner, .project("shop"))
    } }

    func testASeatIsNamedAsThePersonNamedItAndIsNeverVacantWhileSomeoneIsHired() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        let role = DeckMemoryOwner.role(project: nil, role: "mt-builder-role")
        await store.title(role, "MT Builder role")
        var dependencies = DeckMemoryFlowEngine.Dependencies(store: { store }, clock: clock,
            stateFile: .init(url: folder.appendingPathComponent("seat.json")), runner: runner, installedAIs: { ["claude"] }, calendar: utc)
        dependencies.stamp = { id in DeckMemoryStamp(owner: role, session: id, agent: "MT Builder", hand: 1, job: "MT job B release name") }
        let engine = DeckMemoryFlowEngine(dependencies)
        await engine.start()
        engine.post(.hires([role.key: "MT Builder"]))
        engine.post(.sessionSeen(.init(id: "s1", title: "crm-6cb87890-411f-49a7-840b-81213957775a", provider: "claude")))
        engine.post(.sessionStatus(id: "s1", status: "idle"))
        await engine.settle()
        var seat = await store.board.last { $0.id == "agent:" + role.key }
        XCTAssertEqual(seat?.title, "MT Builder role", "The seat's own name, not its slug.")
        XCTAssertEqual(seat?.doing, "Idle in “MT job B release name”", "And the session by its job, not “crm-…”.")
        let session = await store.board.last { $0.id == "session:s1" }
        XCTAssertEqual(session?.title, "MT job B release name")
        engine.post(.sessionRemoved(id: "s1")); await engine.settle()
        seat = await store.board.last { $0.id == "agent:" + role.key }
        XCTAssertEqual(seat?.doing, "Filled by MT Builder, idle", "Hired, with no session open: filled and idle, never vacant.")
        engine.post(.hires([:])); await engine.settle()                           // the agent was archived
        seat = await store.board.last { $0.id == "agent:" + role.key }
        XCTAssertEqual(seat?.doing, "Vacant (its memory is kept)", "Only a seat nobody holds is vacant.")
        XCTAssertEqual(DeckMemoryFlowBoard.seatTitle(.role(project: "imatch", role: "ios-engineer")), "Ios engineer", "A seat nobody named yet: plain words, never the key.")
        await engine.stop()
    }

    func testATidyUpThatAskedNoAINamesNoModelAndNoTokens() async {
        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        await store.put(note("n-1", "The release is named Harbour Lantern.", hour: 6))
        let engine = makeEngine(store, clock, runner)
        await engine.start()
        let said = await engine.runTidyNow(ownerKey: "hoot")
        XCTAssertTrue(said.contains("1 new note"), said)
        XCTAssertTrue(runner.asked.isEmpty, "One new note and nothing like it: no AI is asked.")
        let run = await engine.status().lastRuns.first
        XCTAssertEqual(run?.kind, .tidy); XCTAssertEqual(run?.ai, "", "No AI was asked, so none is named.")
        XCTAssertEqual(run?.model, ""); XCTAssertNil(run?.inputTokens); XCTAssertNil(run?.outputTokens); XCTAssertEqual(run?.milliseconds, 0)
        await engine.stop()
    }

    /// Proof for `design-2026-10-10/cleanup-real-test-leftovers.py`: a COPY of the memory folder, after the script,
    /// opens in the real store and reads back as it should. Runs only when the copy is named:
    ///   M2_CLEANUP_PROOF_MEMORY=<the cleaned copy> swift test --filter testACleanedCopyOfTheMemoryFolder
    func testACleanedCopyOfTheMemoryFolderOpensInTheRealStoreAndReadsBackRight() async throws {
        guard let path = ProcessInfo.processInfo.environment["M2_CLEANUP_PROOF_MEMORY"], !path.isEmpty else {
            throw XCTSkip("Only run by hand, against a copy of the memory folder the clean-up script has been through.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        XCTAssertFalse(root.standardizedFileURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Terminal Deck Memory").path),
                       "Never the real memory folder: a copy.")
        let store = try await DeckMemoryStore.open(root: root, dataRoot: folder, embedder: nil, watch: false)
        let seat = DeckMemoryOwner.role(project: nil, role: "mt-builder-role")
        let owners = try await store.owners()
        XCTAssertFalse(owners.contains { $0.owner == seat }, "The scratch seat is no longer listed.")
        XCTAssertTrue(owners.contains { $0.owner == .hoot })
        let live = try await store.notes(.init(limit: 500))
        XCTAssertFalse(live.contains { $0.labels.owner == seat }, "None of its notes is live.")
        XCTAssertEqual(live.filter { $0.labels.owner == .hoot }.count, 2, "Hoot's two copied notes are untouched.")
        let put = try await store.notes(.init(owner: seat, archivedOnly: true, limit: 500))
        XCTAssertEqual(put.count, 5, "Its five notes are archived, not gone.")
        XCTAssertTrue(put.allSatisfy { $0.archiveReason == "test" }, "With the reason: \(put.map { $0.archiveReason ?? "nil" })")
        XCTAssertTrue(put.allSatisfy { $0.path.hasPrefix("archive/roles/mt-builder-role/") }, "\(put.map(\.path))")
        let topics = try await store.topics(seat, job: nil, includeClosed: false)
        XCTAssertTrue(topics.isEmpty, "No open topic is left for the seat.")
        let board = try await store.board(.init(limit: 500))
        XCTAssertFalse(board.contains { $0.labels.owner == seat || $0.title.hasPrefix("MT ") || $0.title.hasPrefix("crm-") }, "\(board.map(\.title))")
        XCTAssertTrue(board.contains { $0.id == "chat:hoot" })
        let test = try await store.diary(.init(owner: seat, limit: 500))
        XCTAssertEqual(test.map(\.id), Array(58...76), "The diary keeps every row of the test.")
        XCTAssertTrue(test.allSatisfy { $0.meta["source"] == DeckMemoryFlowNames.testSource }, "Every row of the test is marked as one.")
        XCTAssertEqual(test.filter { $0.role == .user }.map(\.author), [.tool, .tool, .tool], "What the test sent is a builder's, not Hoot's.")
        XCTAssertEqual(test.filter { $0.role == .assistant }.map(\.author), [.agent, .agent, .agent, .agent], "What the agent answered is still the agent's.")
        XCTAssertEqual(DeckMemoryFlowEngine.withoutTests(test), [], "So the helper never reads them.")
        let moment = try await store.diary(around: 59, before: 2, after: 2)
        XCTAssertTrue(moment.contains { $0.id == 59 }, "And a moment in it can still be opened.")
        let his = try await store.diary(.init(owner: .project("imatch"), limit: 500))
        XCTAssertEqual(his.count, 57); XCTAssertEqual(his.filter { $0.author == .person }.count, 7)
        XCTAssertFalse(his.contains { $0.meta["source"] != nil }, "His own rows are as they were.")
        await store.close()
        print("CLEANUP PROOF: owners \(owners.map(\.owner.key)); live notes \(live.count); archived for the seat \(put.count) (reason test); board rows \(board.count); his diary rows \(his.count)")
    }

    /// The second test pass's clean-up (its seats moved to archive/, its diary rows marked, its board rows archived),
    /// opened by the real store the way the app opens it at launch. Only run by hand, on a COPY.
    func testTheSecondCleanedCopyOfTheMemoryFolderOpensInTheRealStoreAndReadsBackRight() async throws {
        guard let path = ProcessInfo.processInfo.environment["M2_CLEANUP_PROOF_MEMORY_2"], !path.isEmpty else {
            throw XCTSkip("Only run by hand, against a copy of the memory folder the second clean-up has been through.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        XCTAssertFalse(root.standardizedFileURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Terminal Deck Memory").path),
                       "Never the real memory folder: a copy.")
        let store = try await DeckMemoryStore.open(root: root, dataRoot: folder, embedder: nil, watch: false)
        let scratch: [DeckMemoryOwner] = [.project("td-memory-test"), .lead("td-memory-test"), .role(project: "td-memory-test", role: "builder"),
                                          .role(project: "td-memory-test", role: "mt-builder"), .role(project: "td-memory-test", role: "helper"),
                                          .role(project: nil, role: "builder"), .role(project: nil, role: "helper"), .role(project: nil, role: "codex-worker"),
                                          .role(project: nil, role: "mt-builder-role")]
        let owners = try await store.owners()
        XCTAssertEqual(owners.map(\.owner.key), ["hoot"], "No scratch seat is listed any more.")
        // The seats' cards moved to archive/, which the index leaves out, and the test's rows left the index:
        // a search for their words finds nothing of a scratch seat (other rows may share a word such as "test").
        var searched = 0
        for word in ["AMBER-OTTER-27", "Memory Test", "Codex worker", "MT Builder", "MT Helper", "job K done"] {
            let found = try await store.search(.init(word, mode: .words, limit: 50))
            searched += found.hits.count
            XCTAssertFalse(found.hits.contains { scratch.contains($0.labels.owner) }, "\(word): \(found.hits.map { $0.kind.rawValue + ":" + $0.ref + " " + $0.labels.owner.key })")
        }
        let board = try await store.board(.init(limit: 500))
        XCTAssertFalse(board.contains { row in scratch.contains(row.labels.owner) || row.title.hasPrefix("MT ") || row.title.contains("MT job") || row.title == "Memory Test" },
                       "\(board.map(\.title))")
        XCTAssertTrue(board.contains { $0.id == "chat:hoot" })
        var marked = 0
        for seat in [DeckMemoryOwner.role(project: "td-memory-test", role: "builder"), .role(project: "td-memory-test", role: "helper")] {
            let rows = try await store.diary(.init(owner: seat, limit: 500))
            marked += rows.count
            XCTAssertFalse(rows.isEmpty, "The diary keeps the test's rows of \(seat.key).")
            XCTAssertTrue(rows.allSatisfy { $0.meta["source"] == DeckMemoryFlowNames.testSource }, "Every row of \(seat.key) is marked as a builder's test.")
            XCTAssertTrue(rows.filter { $0.role == .user }.allSatisfy { $0.author == .tool && $0.meta[DeckMemoryFlowNames.givenByKey] == nil },
                          "What the test sent is a tool's, given by nobody: \(rows.filter { $0.role == .user }.map { "\($0.id) \(String(describing: $0.author)) \($0.meta)" })")
            XCTAssertTrue(rows.filter { $0.role == .assistant }.allSatisfy { $0.author == .agent }, "What the agents answered is still theirs.")
            XCTAssertTrue(rows.allSatisfy { $0.writerName() == "Builder test" }, "The diary list calls every one of them a builder's test.")
            XCTAssertEqual(DeckMemoryFlowEngine.withoutTests(rows), [], "So the helper never reads them.")
        }
        let his = try await store.diary(.init(owner: .project("imatch"), limit: 500))
        XCTAssertEqual(his.count, 57); XCTAssertEqual(his.filter { $0.author == .person }.count, 7)
        XCTAssertFalse(his.contains { $0.meta["source"] != nil }, "His own rows are as they were.")
        let hoot = try await store.diary(.init(owner: .hoot, limit: 500))
        XCTAssertFalse(hoot.isEmpty); XCTAssertFalse(hoot.contains { $0.meta["source"] == DeckMemoryFlowNames.testSource }, "Hoot's rows are as they were.")
        let notes = try await store.notes(.init(limit: 500))
        XCTAssertEqual(notes.filter { $0.labels.owner == .hoot }.count, 2, "Hoot's two notes are untouched.")
        await store.close()
        print("CLEANUP PROOF 2: owners \(owners.map(\.owner.key)); search hits for the scratch words \(searched), none of a scratch seat; board rows \(board.count); test rows marked \(marked); his diary rows \(his.count); Hoot rows \(hoot.count); live notes \(notes.count)")
    }

    // MARK: Reading a session's own record: only what was added

    func testAClaudeRecordIsReadFromWhereItWasLeftAndNeverMidLine() throws {
        let file = folder.appendingPathComponent("c1.jsonl")
        let user = #"{"type":"user","uuid":"u1","timestamp":"2026-10-11T08:00:00.000Z","sessionId":"c1","cwd":"/x","message":{"role":"user","content":"Ship the Mac app first."}}"#
        let agent = #"{"type":"assistant","uuid":"a1","timestamp":"2026-10-11T08:00:05.000Z","sessionId":"c1","message":{"id":"msg_1","role":"assistant","model":"claude-sonnet-5-5","content":[{"type":"text","text":"Done. It is shipped."},{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"npm test"}}]}}"#
        let result = #"{"type":"user","uuid":"u2","timestamp":"2026-10-11T08:00:06.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}"#
        try Data((user + "\n" + agent + "\n" + result + "\n").utf8).write(to: file)
        let target = DeckMemoryFlowRecordTarget(path: file.path, roots: [folder.path], provider: "claude", conversation: "c1")
        let first = try DeckMemoryFlowTranscripts.readNew(target, record: nil)
        XCTAssertEqual(first.pieces.map(\.role), [.user, .assistant, .tool])
        XCTAssertEqual(first.pieces.map(\.text), ["Ship the Mac app first.", "Done. It is shipped.", "Bash: npm test"])
        XCTAssertEqual(first.pieces.map(\.author), [.person, .agent, .tool])
        XCTAssertEqual(Set(first.pieces.map(\.key)).count, 3)

        let again = try DeckMemoryFlowTranscripts.readNew(target, record: first.record)
        XCTAssertTrue(again.pieces.isEmpty, "Nothing new, nothing read.")

        // Half a line is on disk: it is not taken until it is whole.
        let next = #"{"type":"user","uuid":"u3","timestamp":"2026-10-11T08:01:00.000Z","message":{"role":"user","content":"And the phone app next week."}}"#
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data(next.prefix(60).utf8))
        let half = try DeckMemoryFlowTranscripts.readNew(target, record: first.record)
        XCTAssertTrue(half.pieces.isEmpty); XCTAssertEqual(half.record.offset, first.record.offset)
        try handle.write(contentsOf: Data((String(next.dropFirst(60)) + "\n").utf8)); try handle.close()
        let whole = try DeckMemoryFlowTranscripts.readNew(target, record: half.record)
        XCTAssertEqual(whole.pieces.map(\.text), ["And the phone app next week."])

        // A resumed conversation: lines older than the app's session are history, not diary.
        var late = target; late.notBefore = 1_791_705_630_000   // 08:00:30 UTC
        let fresh = try DeckMemoryFlowTranscripts.readNew(late, record: nil)
        XCTAssertEqual(fresh.pieces.map(\.text), ["And the phone app next week."])

        // A record outside the account's own folder is refused.
        let outside = DeckMemoryFlowRecordTarget(path: file.path, roots: [folder.appendingPathComponent("elsewhere").path], provider: "claude", conversation: "c1")
        XCTAssertThrowsError(try DeckMemoryFlowTranscripts.readNew(outside, record: nil))
    }

    func testACodexRecordGivesThePersonAndTheAgentInEitherOfItsTwoShapes() throws {
        let file = folder.appendingPathComponent("rollout-1.jsonl")
        let lines = [
            #"{"timestamp":"2026-10-11T08:00:00.000Z","type":"session_meta","payload":{"id":"t1"}}"#,
            #"{"timestamp":"2026-10-11T08:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>noise</environment_context>"}]}}"#,
            #"{"timestamp":"2026-10-11T08:00:01.500Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"i0","content":[{"type":"text","text":"<environment_context>cwd: /x</environment_context>"}]}}}"#,
            #"{"timestamp":"2026-10-11T08:00:02.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"i1","content":[{"type":"text","text":"Fix the database index."}]}}}"#,
            #"{"timestamp":"2026-10-11T08:00:09.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","id":"i2","content":[{"type":"Text","text":"Index rebuilt."}]}}}"#,
            #"{"timestamp":"2026-10-11T08:00:09.500Z","type":"event_msg","payload":{"type":"agent_message","message":"Index rebuilt."}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let target = DeckMemoryFlowRecordTarget(path: file.path, roots: [folder.path], provider: "codex", conversation: "t1")
        let read = try DeckMemoryFlowTranscripts.readNew(target, record: nil)
        XCTAssertEqual(read.pieces.map(\.text), ["Fix the database index.", "Index rebuilt."],
                       "Codex's own context block is not something anyone said, and the second shape of a message is not stored again.")
        XCTAssertEqual(read.pieces.map(\.role), [.user, .assistant]); XCTAssertEqual(read.record.family, "items")
    }

    // MARK: Hoot's stream

    private func event(_ sequence: Int, _ kind: HootChatKind, id: String = "", turn: String = "t1", _ value: NativeRPCValue = .null) -> HootChatEvent {
        .init(conversationID: "c", turnID: turn, sequence: sequence, provider: .claude, record: .init(kind, id: id, value: value), at: 1_791_700_000_000 + Double(sequence))
    }
    private func text(_ value: String) -> NativeRPCValue { .object([.init("text", .string(value))]) }

    func testHootsStreamedReplyIsWrittenOnceWholeAndTheTurnEndsWhenItStops() {
        var reader = DeckMemoryFlowHootReader(conversation: "c")
        let streaming = reader.take([event(1, .user, id: "t1", text("Start the iOS session.")), event(2, .textDelta, id: "m1", text("On ")),
                                     event(3, .textDelta, id: "m1", text("it."))], busy: true)
        XCTAssertEqual(streaming.pieces.map(\.piece.text), ["Start the iOS session."], "The person's message at once; the reply not while it is still streaming.")
        XCTAssertEqual(streaming.pieces.map(\.piece.author), [.person])
        XCTAssertEqual(streaming.cursor, 1, "A restart reads the unfinished reply again.")
        XCTAssertFalse(streaming.turnEnded)
        let finished = reader.take([event(4, .message, id: "m1", text("On it.")), event(5, .toolCall, id: "tool1", .object([.init("name", .string("sessions_start")), .init("input", .object([]))])),
                                    event(6, .toolCall, id: "tool1", .object([.init("name", .string("sessions_start")), .init("input", .object([.init("prompt", .string("Fix login"))]))])),
                                    event(7, .toolResult, id: "tool1", .object([])), event(8, .completed)], busy: false)
        XCTAssertEqual(finished.pieces.map(\.piece.text), ["On it.", "sessions_start: Fix login"])
        XCTAssertEqual(finished.pieces.map(\.piece.role), [.assistant, .tool])
        XCTAssertEqual(finished.pieces.map(\.piece.author), [.orchestrator, .tool])
        XCTAssertTrue(finished.turnEnded); XCTAssertEqual(finished.cursor, 8)
        let replay = reader.take([event(4, .message, id: "m1", text("On it.")), event(8, .completed)], busy: false)
        XCTAssertTrue(replay.pieces.isEmpty, "The same events again write nothing."); XCTAssertFalse(replay.turnEnded)
        // A message a routine put into Hoot's chat is the app's, not the person's.
        let routine = reader.take([event(9, .user, id: "t2", turn: "t2", .object([.init("text", .string("Nightly check ran.")),
            .init("context", .object([.init("source", .object([.init("kind", .string("routine"))]))]))]))], busy: true)
        XCTAssertEqual(routine.pieces.map(\.piece.author), [.app])
        // A builder's test message through the dev copy's test door is a tool's, never the person's.
        let test = reader.take([event(10, .user, id: "t3", turn: "t3", .object([.init("text", .string("Build-lane memory check: reply OK.")),
            .init("context", .object([.init("source", .object([.init("kind", .string("dev-test"))]))]))]))], busy: true)
        XCTAssertEqual(test.pieces.map(\.piece.author), [.tool]); XCTAssertEqual(test.pieces.map(\.source), ["dev-test"])
        // Something the person attached to their own message (a page they captured) does not make it the app's.
        let attached = reader.take([event(11, .user, id: "t4", turn: "t4", .object([.init("text", .string("No, make this button blue.")),
            .init("context", .object([.init("source", .object([.init("kind", .string("browser")), .init("url", .string("https://example.com"))]))]))]))], busy: true)
        XCTAssertEqual(attached.pieces.map(\.piece.author), [.person])
    }

    func testATaskTurnInHootsChatIsTheAppsAndTheTasksNeverThePersons() {
        var reader = DeckMemoryFlowHootReader(conversation: "c")
        let turn = "task:local:2de355f0:9f0c"
        let task = NativeRPCValue.object([.init("text", .string("Working on task “test”")),
            .init("task", .object([.init("id", .string("local:2de355f0")), .init("title", .string("test")), .init("brief", .string("CRM task “test”: say hi. Always answer in French."))]))])
        let output = reader.take([event(1, .message, turn: turn, task), event(2, .message, id: "m1", turn: turn, text("Bonjour.")), event(3, .completed, turn: turn)], busy: false)
        XCTAssertEqual(output.pieces.map(\.piece.text), ["CRM task “test”: say hi. Always answer in French.", "Bonjour."], "The whole brief, not the short visible line.")
        XCTAssertEqual(output.pieces.map(\.piece.author), [.app, .orchestrator], "No row of a task turn is the person's.")
        XCTAssertEqual(output.pieces.map(\.job), ["local:2de355f0", "local:2de355f0"], "Stamped with the task as its job.")
        XCTAssertTrue(output.turnEnded)
        XCTAssertNil(DeckMemoryFlowHootReader.job(ofTurn: "t1"))
    }

    func testHootIsNotFinishedWhileItIsStillWorkingInTheBackground() {
        var reader = DeckMemoryFlowHootReader(conversation: "c")
        let stillBusy = reader.take([event(1, .user, id: "t1", text("Go")), event(2, .message, id: "m1", text("Started.")), event(3, .completed)], busy: true)
        XCTAssertFalse(stillBusy.turnEnded)
        let quiet = reader.take([], busy: false)
        XCTAssertTrue(quiet.turnEnded)
    }

    // MARK: Checklist, tidy-up slot, rules

    func testACorrectionIsAddedToTheChecklistOnceAndGoesToTheCategorysTemplate() async throws {
        let moment = Date(timeIntervalSince1970: 1_791_700_000)
        let once = try XCTUnwrap(DeckMemoryFlowChecklist.appending("You should have noted\nthe build number.", to: DeckMemoryFlowChecklist.defaultText, on: moment, calendar: utc))
        XCTAssertTrue(once.contains("- 2026-10-11: You should have noted the build number."))
        XCTAssertTrue(once.contains("## Do not write a note for"), "The rest of the checklist stays.")
        XCTAssertNil(DeckMemoryFlowChecklist.appending("you should have noted the build number.", to: once, on: moment, calendar: utc), "Not twice.")
        let custom = try XCTUnwrap(DeckMemoryFlowChecklist.appending("Note prices.", to: "# Mine\n- only decisions\n", on: moment, calendar: utc))
        XCTAssertTrue(custom.hasPrefix("# Mine\n- only decisions\n")); XCTAssertTrue(custom.contains(DeckMemoryFlowChecklist.correctionsHeading))

        let clock = Clock(), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) }), runner = Runner([])
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        await store.put(DeckMemoryTemplate(category: .lead, card: "", checklist: "# The lead's own list\n", parts: Set(DeckMemoryPart.allCases)))
        let engine = makeEngine(store, clock, runner)
        await engine.start()
        let added = await engine.addCorrection("Note every build number.", ownerKey: "lead:imatch")
        XCTAssertTrue(added)
        let lead = try await store.template(.lead), agent = try await store.template(.agent)
        XCTAssertTrue(lead.checklist.hasPrefix("# The lead's own list\n"), "A checklist that is there is never overwritten.")
        XCTAssertTrue(lead.checklist.contains("Note every build number."))
        XCTAssertFalse(agent.checklist.contains("Note every build number."), "One template per category: only the lead's changed.")
        await engine.stop()
    }

    func testTheTidyUpIsDueOncePerDayAfterItsHourAndAMissedDayIsMadeUp() {
        XCTAssertEqual(DeckMemoryFlowTidy.slot(now: day(2), hour: 3, calendar: utc), "2026-10-10", "Before the hour it is still yesterday's.")
        XCTAssertEqual(DeckMemoryFlowTidy.slot(now: day(4), hour: 3, calendar: utc), "2026-10-11")
        XCTAssertFalse(DeckMemoryFlowTidy.isDue(now: day(9), lastSlot: "2026-10-11", hour: 3, calendar: utc))
        XCTAssertTrue(DeckMemoryFlowTidy.isDue(now: day(9, day: 13), lastSlot: "2026-10-11", hour: 3, calendar: utc), "The app was closed for a day.")
        XCTAssertEqual(DeckMemoryFlowTidy.nextOpening(after: day(4), hour: 3, calendar: utc), day(3, day: 12))
        XCTAssertEqual(DeckMemoryFlowTidy.nextOpening(after: day(1), hour: 3, calendar: utc), day(3))
    }

    func testANoteIsReplacedOnlyByOneThatBecameTrueLaterAndNeverThePersonsByAnAgents() throws {
        // 1 = Friday (said 8:00), 2 = Monday (said 15:00), 3 = the person's own rule, 4 = an agent's result,
        // 5 = written LAST but about an EARLIER state (an import, or the nightly second look).
        let notes = [note("n-1", "Ship on Friday.", hour: 8), note("n-2", "Ship on Monday.", hour: 15),
                     note("n-3", "Main buttons are blue.", hour: 9, type: .preference), note("n-4", "Buttons were made grey.", hour: 16, type: .result),
                     note("n-5", "Ship on Wednesday.", hour: 20, validFrom: day(7))]
        let plan = try DeckMemoryFlowTidy.parse("""
        {"replace": [{"newer": 2, "older": 1, "why": "the date moved"}, {"newer": 4, "older": 3, "why": "grey now"},
                     {"newer": 5, "older": 2, "why": "written last"}, {"newer": 9, "older": 1, "why": "invented"}],
         "questions": [{"text": "Is Monday final?", "context": "Two dates were given.", "notes": [1, 2, 77]}]}
        """)
        let steps = DeckMemoryFlowRules.tidy(plan, notes: notes, fresh: 5, canAddMissed: false, calendar: utc)
        XCTAssertEqual(steps, [
            .archive(id: "n-1", replacedBy: "n-2", reason: "superseded: the date moved"),
            .ask(text: "Is Monday final?", context: "Two dates were given.", refs: ["n-1", "n-2"]),
        ], "Not the person's rule by an agent's note, not a later state by an earlier one, not an invented number.")

        // The same rule when one turn's answer names a stored note to replace.
        var answer = DeckMemoryFlowHelperAnswer()
        answer.notes = [.init(type: .decision, title: "Ship on Tuesday", text: "The ship date is Tuesday.", replaces: 2),
                        .init(type: .result, title: "Grey", text: "Buttons are grey now.", replaces: 3),
                        .init(type: .decision, title: "Out of range", text: "Nothing to replace.", replaces: 40)]
        let stamp = DeckMemoryStamp(owner: .hoot, session: "hoot", agent: "hoot")
        let late = DeckMemoryFlowRules.turn(answer, stamp: stamp, boardRow: "chat:hoot", boardKind: .chat, asking: false, at: day(10),
                                            personSpoke: false, stored: notes, rows: 5...9)
        XCTAssertEqual(late.notes.map(\.supersedes), [nil, nil, nil], "Said at 10:00, it cannot replace what became true at 15:00; nor the person's rule.")
        XCTAssertEqual(late.refused.count, 2)
        let later = DeckMemoryFlowRules.turn(answer, stamp: stamp, boardRow: "chat:hoot", boardKind: .chat, asking: false, at: day(18),
                                             personSpoke: true, stored: notes, rows: 5...9)
        XCTAssertEqual(later.notes.map(\.supersedes), ["n-2", "n-3", nil], "An explicit replacement, later in time, with the person in the conversation.")
        XCTAssertEqual(later.notes.map(\.validFrom), [day(18), day(18), day(18)]); XCTAssertEqual(later.notes.first?.diaryRange, 5...9)

        // "What waits for you": an AI's turn alone never clears it; the person's answer does.
        var quiet = DeckMemoryFlowHelperAnswer(); quiet.waiting = ""
        XCTAssertNil(DeckMemoryFlowRules.turn(quiet, stamp: stamp, boardRow: "chat:hoot", boardKind: .chat, asking: false, at: day(18),
                                              personSpoke: false, stored: []).board)
        XCTAssertEqual(DeckMemoryFlowRules.turn(quiet, stamp: stamp, boardRow: "chat:hoot", boardKind: .chat, asking: false, at: day(18),
                                                personSpoke: true, stored: []).board?.waitingForUser, "")
    }

    func testDuplicatesKeepTheFullerNoteAndQuestionsAreNeverAskedTwice() throws {
        let notes = [note("n-1", "Use blue buttons.", hour: 9), note("n-2", "Main buttons are blue.", hour: 10), note("n-3", "An old note.", hour: 1, day: 9),
                     note("n-4", "Reply to the client.", hour: 11, type: .openItem), note("n-5", "The client was answered.", hour: 12, type: .result)]
        let plan = try DeckMemoryFlowTidy.parse(#"{"duplicates": [{"a": 1, "b": 2}, {"a": 3, "b": 3}], "close": [{"item": 4, "by": 5, "why": "answered"}, {"item": 1, "by": 5, "why": "not an open item"}]}"#)
        XCTAssertEqual(DeckMemoryFlowRules.tidy(plan, notes: notes, fresh: 2, canAddMissed: false, calendar: utc), [
            .archive(id: "n-1", replacedBy: "n-2", reason: "merged"),
            .archive(id: "n-4", replacedBy: "n-5", reason: "done: answered"),
        ])
        XCTAssertEqual(DeckMemoryFlowRules.exactDuplicates([note("n-b", "Ship  on Friday.", hour: 9), note("n-a", "ship on friday.", hour: 8)]),
                       [.archive(id: "n-b", replacedBy: "n-a", reason: "duplicate")], "The older one stays.")

        let before = [DeckMemoryQuestion(id: 1, owner: .hoot, text: "Is  Monday final?", askedAt: day(1), answer: "dismissed", answeredAt: day(2))]
        let wanted: [DeckMemoryFlowRules.TidyStep] = [.ask(text: "is monday final?", context: "", refs: [])]
            + (1...8).map { .ask(text: "Question \($0)?", context: "", refs: []) }
        let asked = DeckMemoryFlowRules.questionsToAsk(wanted, existing: before)
        XCTAssertEqual(asked.count, DeckMemoryFlowRules.maximumOpenQuestions, "Never more than a handful open.")
        XCTAssertFalse(asked.contains(.ask(text: "is monday final?", context: "", refs: [])), "A question that was waved away is not asked again.")
        XCTAssertTrue(DeckMemoryFlowRules.correctionSignal("no, I said use blue")); XCTAssertFalse(DeckMemoryFlowRules.correctionSignal("Looks good, thanks"))
    }

    func testTheTidyUpNeverDeletesAndAsksWhenUnsure() async throws {
        let notes = [note("n-a", "Ship on Friday.", hour: 8), note("n-c", "Use blue buttons.", hour: 9), note("n-d", "Main buttons are blue.", hour: 10),
                     note("n-b", "Ship on Monday.", hour: 15)]
        let clock = Clock(1_791_740_000_000), store = Store(now: { Date(timeIntervalSince1970: clock.now() / 1000) })   // 17:33 UTC, after the notes
        for item in notes { await store.put(item) }
        // Numbered in the order written: 1 Friday, 2 "Use blue buttons", 3 "Main buttons are blue", 4 Monday.
        let runner = Runner([.success("""
        {"duplicates": [{"a": 2, "b": 3}], "replace": [{"newer": 4, "older": 1, "why": "the date moved"}],
         "questions": [{"text": "Is Monday final?", "context": "Two dates were given.", "notes": [1, 4]}]}
        """)])
        let engine = makeEngine(store, clock, runner)
        await store.set("0", DeckMemoryFlowKeys.tidyOn)
        await store.set(String(1_791_600_000_000), DeckMemoryFlowKeys.tidyLastDay + ".at|hoot")
        await engine.start()
        let said = await engine.runTidyNow(ownerKey: "hoot")
        XCTAssertTrue(said.hasPrefix("Tidy-up finished: "), said)
        let all = await store.notes, archived = await store.archived, questions = await store.asked
        XCTAssertEqual(all.count, 4, "Nothing was removed.")
        XCTAssertEqual(archived["n-a"]?.replacedBy, "n-b", "The older note is archived and points at the one that replaced it.")
        XCTAssertEqual(archived["n-c"]?.replacedBy, "n-d", "The fuller of two that say the same stays.")
        XCTAssertNil(archived["n-b"]); XCTAssertNil(archived["n-d"])
        XCTAssertEqual(questions.map(\.text), ["Is Monday final?"]); XCTAssertEqual(questions.first?.refs, ["n-a", "n-b"])
        let backups = await store.backups, reindexes = await store.reindexes
        XCTAssertEqual(backups, 1); XCTAssertEqual(reindexes, 1)
        XCTAssertEqual(runner.asked.count, 1); XCTAssertTrue(runner.asked[0].prompt.contains("1. NEW · decision"))
        XCTAssertFalse(runner.asked[0].prompt.contains("n-a"), "The helper sees numbers, never real ids.")
        // A second run right after: nothing new, no AI question.
        let again = await engine.runTidy(.hoot)
        XCTAssertEqual(again.message, "Nothing new to tidy."); XCTAssertEqual(runner.asked.count, 1)
        await engine.stop()
    }

    func testTheHelpersAnswerIsReadLenientlyAndItsLabelsAreNotTrusted() throws {
        let answer = try DeckMemoryFlowHelperPrompt.parse("Sure!\n```json\n{\"board\": {\"result\": \"Built.\", \"state\": \"verified\", \"proof\": \"\"}, \"notes\": [{\"type\": \"Open Item\", \"title\": \"\", \"text\": \"Waiting for the logo.\", \"replaces\": 2}, {\"type\": \"how-to\", \"text\": \"Run npm test.\"}, {\"type\": \"x\", \"text\": \"\"}]}\n```")
        XCTAssertEqual(answer.state, .reported); XCTAssertNil(answer.waiting)
        XCTAssertEqual(answer.notes.map(\.type), [.openItem, .howTo]); XCTAssertEqual(answer.notes[0].title, "Waiting for the logo.")
        XCTAssertEqual(answer.notes[0].replaces, 2)
        XCTAssertThrowsError(try DeckMemoryFlowHelperPrompt.parse("I could not do that."), "No answer is a failure, never \"nothing to remember\".")
        XCTAssertEqual(DeckMemoryFlowPrompts.fill("a {{x}} b {{y}}", ["x": "{{y}}", "y": "Y"]), "a {{y}} b Y", "A value is never scanned for markers.")
        XCTAssertEqual(DeckMemoryFlowCLIRunner.model("sonnet", for: "codex"), "", "A Claude model name is not handed to Codex.")
        XCTAssertEqual(DeckMemoryFlowCLIRunner.model("", for: "claude"), "sonnet")
    }

    func testOnlyTheNewRowsWithinTheBudgetGoIntoOneQuestionAndTheCutFallsBetweenTurns() {
        let stamp = DeckMemoryStamp(owner: .hoot, session: "hoot", agent: "hoot"), date = Date(timeIntervalSince1970: 1_791_700_000)
        var rows: [DeckMemoryDiaryEntry] = []
        for number in 1...5 {
            let person = number % 2 == 1
            let labels = DeckMemoryLabels(stamp: stamp, date: date, type: "row")
            let words: String = String(repeating: "x", count: 400) + " row" + String(number)
            let role: DeckMemoryDiaryRole = person ? .user : .assistant
            let author: DeckMemoryAuthor = person ? .person : .orchestrator
            rows.append(DeckMemoryDiaryEntry(id: Int64(number), labels: labels, role: role, text: words, author: author))
        }
        let two = DeckMemoryFlowHelperPrompt.slice(rows, budget: 1_000)
        XCTAssertEqual(two.rows, 2); XCTAssertEqual(two.lastID, 2); XCTAssertTrue(two.more, "The rest is read by the next job.")
        XCTAssertTrue(two.text.contains("row2")); XCTAssertFalse(two.text.contains("row3"))
        let three = DeckMemoryFlowHelperPrompt.slice(rows, budget: 1_400)
        XCTAssertEqual(three.rows, 2, "Row 3 would fit, but its answer would not: a turn is never cut in two.")
        let all = DeckMemoryFlowHelperPrompt.slice(rows)
        XCTAssertEqual(all.lastID, 5); XCTAssertFalse(all.more)
        XCTAssertTrue(all.text.contains("PERSON: x")); XCTAssertTrue(all.text.contains("HOOT (the orchestrator): x"))
        let unsigned = DeckMemoryDiaryEntry(id: 9, labels: .init(stamp: stamp, date: date, type: "user"), role: .user, text: "Who said this?")
        XCTAssertFalse(DeckMemoryFlowHelperPrompt.slice([unsigned]).text.contains("PERSON"), "A row the app did not sign is never taken for the person's.")
    }

    // #660: an imported or hand-edited note was never cleaned on the way in; its secrets and private parts stay home.
    func testStoredNotesTopicsAndTheTidyListReachTheHelperWithoutSecrets() {
        let npm = "npm_" + String(repeating: "Ab3", count: 12), gitlab = "glpat-" + String(repeating: "xY7_", count: 5)
        let imported = note("n-1", "Deploy with \(npm) and \(gitlab) <private>pin 4321</private>", hour: 9)
        let topic = DeckMemoryTopic(id: "deploy", owner: .hoot, title: "Deploy", body: "GitLab key \(gitlab)", open: true, path: "hoot/topics/deploy.md",
                                    labels: .init(owner: .hoot, date: day(9), type: "topic"), updatedAt: day(9))
        let turn = DeckMemoryFlowHelperPrompt.turn(who: "the person", part: "Ship it.", before: "", stored: [imported], topics: [topic], checklist: "", correcting: false)
        let tidy = DeckMemoryFlowTidy.prompt(owner: "Hoot", notes: [imported], fresh: 1, missed: "", checklist: "")
        for prompt in [turn, tidy] {
            XCTAssertFalse(prompt.contains(npm)); XCTAssertFalse(prompt.contains(gitlab)); XCTAssertFalse(prompt.contains("4321"))
            XCTAssertTrue(prompt.contains(DeckMemoryRedaction.marker))
        }
    }
}
