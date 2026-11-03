import XCTest
import Foundation
import Darwin
import SQLite3
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 2 Nov 2026 (disk writes in Asad's app: 0.8 to 2.2 MB/s into memory.db, 1.9 GB in 69 minutes): a busy agent session
/// goes Working, then Idle 70 ms later, every 1 to 4 s, and every flip wrote three board rows (session, project, seat)
/// and three history entries, each its own fully synced transaction. The board now keeps a working/idle state only once
/// it has held 3 s, writes one moment's rows in one transaction, and the old flip history is settled once at start.
final class BoardSettleTests: XCTestCase {
    typealias Clock = DeckMemoryFlowTests.Clock
    private var base: URL!
    override func setUp() {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BoardSettle-" + UUID().uuidString + ".noindex")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: base) }
    private var memory: URL { base.appendingPathComponent("memory") }
    private var database: String { memory.appendingPathComponent("memory.db").path }

    private func open(_ clock: Clock? = nil) async throws -> DeckMemoryStore {
        let now: @Sendable () -> Date
        if let clock { now = { Date(timeIntervalSince1970: clock.now() / 1000) } } else { now = { Date() } }
        let store = try await DeckMemoryStore.open(root: memory, dataRoot: base.appendingPathComponent("data"), embedder: nil, watch: false, now: now)
        // The nightly tidy-up off: it would write on its own when the engine goes quiet.
        try await store.setValue("0", key: DeckMemoryFlowKeys.tidyOn, owner: nil)
        return store
    }
    /// The engine on the REAL store, the app's own adapter between them.
    private func engine(_ store: DeckMemoryStore, _ clock: any BackendDeckCoreEventsClock, lead: Bool = true) -> DeckMemoryFlowEngine {
        var dependencies = DeckMemoryFlowEngine.Dependencies(store: { DeckMemoryFlowStoreAdapter(store) }, clock: clock,
            stateFile: .init(url: base.appendingPathComponent("flow-\(UUID().uuidString).json")), runner: DeckMemoryFlowTests.Runner([]),
            installedAIs: { ["claude"] })
        dependencies.stamp = { id in
            lead ? DeckMemoryStamp(owner: .lead("imatch"), project: "imatch", session: id, agent: "claude") : DeckMemoryStamp(owner: .project("imatch"), project: "imatch", session: id)
        }
        return DeckMemoryFlowEngine(dependencies)
    }
    private func history(_ store: DeckMemoryStore) async throws -> [DeckMemoryBoardChange] { try await store.boardChanges(since: .distantPast, owner: nil) }
    /// SQLite's file change counter (header bytes 24 to 27): one more for every write transaction that committed.
    private func commits() throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: database)); defer { try? handle.close() }
        try handle.seek(toOffset: 24)
        let bytes = [UInt8](try handle.read(upToCount: 4) ?? Data())
        return bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    // MARK: The settled writer

    func testWorkingIdleFlipsInsideThreeSecondsWriteNothingAndAHeldStateIsWrittenOnceInOneTransaction() async throws {
        let clock = Clock(), store = try await open(clock), engine = engine(store, clock)
        await engine.start()
        engine.post(.sessionSeen(.init(id: "s1", title: "Website", provider: "terminal", project: "imatch")))
        engine.post(.sessionStatus(id: "s1", status: "working"))      // from Started: written at once
        await engine.settle()
        var rows = try await store.board(.init(limit: 50))
        XCTAssertEqual(rows.first { $0.id == "session:s1" }?.doing, "Working")
        XCTAssertEqual(rows.first { $0.id == "project:imatch" }?.doing, "1 session working")
        XCTAssertEqual(rows.first { $0.id.hasPrefix("agent:") }?.doing, "Working in “Website”")
        let entries = try await history(store).count, commitsBefore = try commits()

        // The busy agent: Idle, Working 70 ms later, Idle again... never holding 3 s (and inside the 30 s a row may wait).
        for _ in 0..<15 {
            engine.post(.sessionStatus(id: "s1", status: "idle")); await engine.settle(); clock.advance(1_500)
            engine.post(.sessionStatus(id: "s1", status: "working")); await engine.settle(); clock.advance(70)
        }
        await engine.settle()
        let afterFlips = try await history(store).count
        XCTAssertEqual(afterFlips, entries, "15 flips that never held 3 s: no history entry")
        XCTAssertEqual(try commits(), commitsBefore, "and not one write to memory.db")
        rows = try await store.board(.init(limit: 50))
        XCTAssertEqual(rows.first { $0.id == "session:s1" }?.doing, "Working", "the stored board still says what last held")

        // Working, Idle, Working inside the window: it came back to what is stored, so nothing is written even after it holds.
        clock.advance(3_100); await engine.settle()
        XCTAssertEqual(try commits(), commitsBefore, "Working held again: the same as stored, nothing written")

        // Idle that holds: the three rows in ONE transaction, three history entries.
        engine.post(.sessionStatus(id: "s1", status: "idle")); await engine.settle()
        clock.advance(2_900); await engine.settle()
        XCTAssertEqual(try commits(), commitsBefore, "not yet: 2.9 s")
        clock.advance(200); await engine.settle()
        XCTAssertEqual(try commits(), commitsBefore + 1, "one transaction for the session, its project and its seat")
        let changes = try await history(store)
        XCTAssertEqual(changes.count, entries + 3)
        XCTAssertEqual(Set(changes.suffix(3).map(\.row.doing)), ["Idle", "Quiet", "Idle in “Website”"])
        await engine.stop(); await store.close()
    }

    func testAskingThePersonIsWrittenAtOnceAndReplacesWhatWaitedToSettle() async throws {
        let clock = Clock(), store = try await open(clock), engine = engine(store, clock)
        await engine.start()
        engine.post(.sessionSeen(.init(id: "s1", title: "Website", provider: "terminal", project: "imatch")))
        engine.post(.sessionStatus(id: "s1", status: "working"))
        engine.post(.sessionStatus(id: "s1", status: "idle"))          // waits to settle
        engine.post(.sessionStatus(id: "s1", status: "input"))         // asks the person: at once
        await engine.settle()
        var session = try await store.board(.init(session: "s1")).first { $0.id == "session:s1" }
        XCTAssertEqual(session?.doing, "Waiting for you")
        XCTAssertFalse(session?.waitingForUser.isEmpty ?? true)
        clock.advance(5_000); await engine.settle()
        session = try await store.board(.init(session: "s1")).first { $0.id == "session:s1" }
        XCTAssertEqual(session?.doing, "Waiting for you", "the Idle that waited was older than the question: it is never written")
        let idle = try await history(store).contains { $0.row.id == "session:s1" && $0.row.doing == "Idle" }
        XCTAssertFalse(idle)
        // Leaving the question clears the app's own line at once, even into a working/idle state.
        engine.post(.sessionStatus(id: "s1", status: "working")); await engine.settle()
        session = try await store.board(.init(session: "s1")).first { $0.id == "session:s1" }
        XCTAssertEqual(session?.doing, "Working"); XCTAssertEqual(session?.waitingForUser, "")
        await engine.stop(); await store.close()
    }

    func testARowThatNeverHoldsIsStillWrittenEveryThirtySecondsAndStopWritesWhatWaited() async throws {
        let clock = Clock(), store = try await open(clock), engine = engine(store, clock, lead: false)
        await engine.start()
        engine.post(.sessionSeen(.init(id: "s1", title: "Website", provider: "terminal", project: "imatch")))
        engine.post(.sessionStatus(id: "s1", status: "idle"))          // from Started: at once
        await engine.settle()
        let start = try commits()
        // Working 1 s, finished 1 s, for 40 s: nothing ever holds 3 s, and neither is the Idle that is stored.
        for flip in 0..<40 {
            engine.post(.sessionStatus(id: "s1", status: flip % 2 == 0 ? "working" : "completed")); await engine.settle(); clock.advance(1_000); await engine.settle()
        }
        let written = try commits() - start
        XCTAssertGreaterThanOrEqual(written, 1, "the stored board follows at least every 30 s")
        XCTAssertLessThanOrEqual(written, 2, "but never once per flip (\(written) writes for 40 flips)")
        engine.post(.sessionStatus(id: "s1", status: "working")); await engine.settle()
        await engine.stop()
        let closed = try await store.board(.init(session: "s1")).first { $0.id == "session:s1" }
        XCTAssertEqual(closed?.doing, "Working", "closing writes what waited")
        await store.close()
    }

    func testOneBatchIsOneTransactionAndChangesNothingWhenNothingChanged() async throws {
        let store = try await open()
        let stamp = DeckMemoryStamp(owner: .lead("crm"), project: "crm", session: "s1")
        let updates: [DeckMemoryBoardUpdate] = [
            .init(id: "session:s1", kind: .session, stamp: stamp, title: "One", doing: "Working"),
            .init(id: "project:crm", kind: .project, stamp: .init(owner: .project("crm"), project: "crm"), title: "crm", doing: "1 session working"),
            .init(id: "agent:lead:crm", kind: .agent, stamp: stamp, title: "Lead", doing: "Working in “One”")]
        var before = try commits()
        try await store.writeBoard(updates, archive: [])
        XCTAssertEqual(try commits(), before + 1, "three rows, one transaction")
        before = try commits()
        try await store.writeBoard(updates, archive: [])
        XCTAssertEqual(try commits(), before, "the same again: no transaction at all")
        // A refused update is left out; the others are still written.
        var refused = updates[0]; refused.state = .verified; refused.lastResult = "Shipped"
        var next = updates[1]; next.doing = "Quiet"
        do { try await store.writeBoard([refused, next], archive: ["session:s1"]); XCTFail("verified without proof is refused") }
        catch let error as DeckMemoryError { XCTAssertEqual(error.code, .proofRequired) }
        let rows = try await store.board(.init(includeArchived: true, limit: 10))
        XCTAssertEqual(rows.first { $0.id == "project:crm" }?.doing, "Quiet")
        XCTAssertNotNil(rows.first { $0.id == "session:s1" }?.archivedAt, "and the row leaving the board left it in the same transaction")
        XCTAssertEqual(rows.first { $0.id == "session:s1" }?.lastResult, "", "the refused result was not written")
        await store.close()
    }

    // MARK: The one-time settle of the old history

    /// A second connection, to lay down an old store's history.
    private func raw(_ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw NSError(domain: "raw", code: 1) }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5_000)
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "raw: " + String(cString: sqlite3_errmsg(handle)), code: 2) }
    }
    private func scalar(_ sql: String) throws -> Int64 {
        var handle: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(database, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw NSError(domain: "raw", code: 1) }
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "raw", code: 3) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
    }
    private func text(_ sql: String) throws -> String {
        var handle: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(database, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw NSError(domain: "raw", code: 1) }
        defer { sqlite3_finalize(statement); sqlite3_close(handle) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "raw: " + String(cString: sqlite3_errmsg(handle)), code: 3) }
        return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "" : ""
    }
    private func entry(_ row: String, _ at: Double, _ fields: String, _ doing: String, waiting: String = "") -> String {
        let snapshot = "{\"id\":\"\(row)\",\"doing\":\"\(doing)\",\"waitingForUser\":\"\(waiting)\"}"
        return "INSERT INTO board_history (row_id, at, fields, snapshot) VALUES ('\(row)', \(at), '\(fields)', '\(snapshot)');"
    }
    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: memory.appendingPathComponent("archive/backups").path)) ?? []).filter { $0.hasSuffix(".db") }.sorted()
    }

    func testTheOldFlipHistoryIsSettledOnceAfterACopyAndNothingElseIsTouched() async throws {
        var store = try await open()
        _ = try await store.addNote(.init(title: "Release name", body: "The release is named Harbour Lantern.", type: .decision, stamp: .init(owner: .hoot)))
        _ = try await store.appendDiary(.init(stamp: .init(owner: .hoot, session: "s1"), role: .user, text: "Name the release."))
        _ = try await store.updateTopic(.hoot, title: "Where we are", body: "Naming the release.")
        await store.close()
        XCTAssertTrue(backups().isEmpty, "a new store has nothing to settle and makes no copy")

        // An old store: the mark is gone and the history is full of flips, as in Asad's memory.
        let t = Date().timeIntervalSince1970 - 3_600     // inside the week the history keeps
        var sql = "BEGIN; DELETE FROM settings WHERE key = 'board.history.settled'; DELETE FROM board_history;"
        sql += "INSERT INTO board (id, kind, title, owner, updated) VALUES ('session:s1', 'session', 'Website', 'hoot', \(t)), ('project:imatch', 'project', 'imatch', 'project:imatch', \(t));"
        sql += entry("session:s1", t, "created,title,doing", "Started")
        sql += entry("session:s1", t + 1, "doing", "Working")                       // 0.07 s, then Idle: goes
        sql += entry("session:s1", t + 1.07, "doing", "Idle")                       // 2 s: goes
        sql += entry("session:s1", t + 3.07, "doing", "Working")                    // 0.07 s: goes
        sql += entry("session:s1", t + 3.14, "doing", "Idle")                       // held 10 s: stays
        sql += entry("session:s1", t + 13.14, "doing", "Working")                   // 0.07 s: goes
        sql += entry("session:s1", t + 13.21, "doing", "Idle")                      // held, but already Idle: goes
        sql += entry("session:s1", t + 20, "doing,waitingForUser", "Waiting for you", waiting: "Pick a name")   // stays: a waiting line
        sql += entry("session:s1", t + 20.5, "doing", "Working")                    // 0.5 s but next is not doing-only: stays
        sql += entry("session:s1", t + 21, "lastResult", "Working")                 // stays
        sql += entry("session:s1", t + 21.05, "doing", "Idle")                      // the row's newest: stays
        sql += entry("project:imatch", t, "created,title,doing", "Quiet")
        sql += entry("project:imatch", t + 1, "doing", "1 session working")         // goes
        sql += entry("project:imatch", t + 1.07, "doing", "Quiet")                  // newest: stays
        sql += "COMMIT;"
        try raw(sql)
        let diary = try scalar("SELECT COUNT(*) FROM diary"), notes = try scalar("SELECT COUNT(*) FROM notes"), topics = try scalar("SELECT COUNT(*) FROM topics")
        let search = try scalar("SELECT COUNT(*) FROM search")

        store = try await open()
        func kept(_ row: String) throws -> String {
            try text("SELECT group_concat(json_extract(snapshot, '$.doing') || ' [' || fields || ']', ' | ') FROM (SELECT * FROM board_history WHERE row_id = '\(row)' ORDER BY id)")
        }
        XCTAssertEqual(try kept("session:s1"), "Started [created,title,doing] | Idle [doing] | Waiting for you [doing,waitingForUser] | Working [doing] | Working [lastResult] | Idle [doing]")
        XCTAssertEqual(try kept("project:imatch"), "Quiet [created,title,doing] | Quiet [doing]", "every row keeps its newest entry")
        let lines = await store.openingReport()
        XCTAssertEqual(lines.count, 1); XCTAssertTrue(lines.first?.contains("14 entries -> 8") == true, lines.joined())
        XCTAssertEqual(backups().count, 1, "a copy of memory.db first")
        let copy = memory.appendingPathComponent("archive/backups/" + (backups().first ?? "")).path
        var handle: OpaquePointer?, statement: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(copy, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM board_history", -1, &statement, nil); sqlite3_step(statement)
        XCTAssertEqual(sqlite3_column_int64(statement, 0), 14, "the copy has the history as it was")
        sqlite3_finalize(statement); sqlite3_close(handle)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM diary"), diary); XCTAssertEqual(try scalar("SELECT COUNT(*) FROM notes"), notes)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM topics"), topics); XCTAssertEqual(try scalar("SELECT COUNT(*) FROM search"), search)
        await store.close()

        // Once: the next opening changes nothing and makes no copy. And run again by hand, it finds nothing to drop.
        store = try await open()
        let again = await store.openingReport()
        XCTAssertTrue(again.isEmpty); XCTAssertEqual(backups().count, 1)
        try raw("DELETE FROM settings WHERE key = 'board.history.settled'")
        await store.close()
        store = try await open()
        let third = await store.openingReport()
        XCTAssertTrue(third.isEmpty, "idempotent: nothing left to settle")
        XCTAssertEqual(backups().count, 1, "and no copy when nothing changes")
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM board_history"), 8)
        await store.close()
    }

    // MARK: Measure (by hand, on a COPY of a memory folder)

    /// Bytes this process has written to disk so far (what macOS's disk-writes report counts), no root needed.
    private func bytesWritten() -> UInt64 {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? info.ri_diskio_byteswritten : 0
    }
    private func fileSize(_ path: String) -> Int64 { ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.int64Value ?? 0 }

    /// The real writer path, timed like the busy session in Asad's app (Working, Idle 70 ms later, the next Working
    /// 1 to 4 s after that), on a COPY of a memory folder:
    ///   TD_BOARD_WRITES_MEASURE=<copy of a memory folder> [TD_BOARD_WRITES_SECONDS=120] swift test --filter testMeasure
    /// before: the old writer (each update its own transaction, at once), with synchronous=FULL and then =NORMAL;
    /// settle: the one-time history settle at opening; after: the settled engine on the settled store.
    func testMeasureBoardWritesOnACopy() async throws {
        guard let path = ProcessInfo.processInfo.environment["TD_BOARD_WRITES_MEASURE"], !path.isEmpty else {
            throw XCTSkip("Only run by hand, on a COPY of a memory folder.")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        XCTAssertFalse(root.path.contains("/Library/Application Support/terminaldeck/"), "never the real memory folder")
        let seconds = Double(ProcessInfo.processInfo.environment["TD_BOARD_WRITES_SECONDS"] ?? "") ?? 120
        let file = root.appendingPathComponent("memory.db").path
        func rawExec(_ sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(file, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw NSError(domain: "raw", code: 1) }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "raw: " + String(cString: sqlite3_errmsg(handle)), code: 2) }
        }
        func count(_ sql: String) -> Int64 {
            var handle: OpaquePointer?, statement: OpaquePointer?
            guard sqlite3_open_v2(file, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return -1 }
            defer { sqlite3_finalize(statement); sqlite3_close(handle) }
            sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : -1
        }
        var seed: UInt64 = 20261102
        func nextGap() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return 1.0 + Double(seed >> 11) / Double(1 << 53) * 3.0 }
        @Sendable func stamp(_ id: String) -> DeckMemoryStamp { DeckMemoryStamp(owner: .lead("deck-dev"), project: "deck-dev", session: id, agent: "claude") }
        var report: [String] = []
        func line(_ name: String, bytes: UInt64, elapsed: Double, growth: Int64, entries: Int64) {
            let text = "\(name): \(bytes / 1024) KB in \(String(format: "%.0f", elapsed)) s = \(String(format: "%.1f", Double(bytes) / 1024 / elapsed)) KB/s; memory.db \(growth >= 0 ? "+" : "")\(growth / 1024) KB; history entries \(entries >= 0 ? "+" : "")\(entries)"
            report.append(text); print("MEASURE " + text)
        }

        // BEFORE: the old writer, exactly as `write` was: every update of a status change written on its own, at once.
        // The copy keeps its old history for this part (the settle mark is set by hand first).
        try rawExec("INSERT INTO settings (owner, key, value, updated) VALUES ('', 'board.history.settled', '1', 0) ON CONFLICT(owner, key) DO UPDATE SET value = '1'")
        for synchronous in ["FULL", "NORMAL"] {
            let store = try await DeckMemoryStore.open(root: root, dataRoot: base, embedder: nil, watch: false)
            if synchronous == "NORMAL" { try await store.measureExec("PRAGMA synchronous=NORMAL") }
            var board = DeckMemoryFlowBoard()
            _ = board.sessionSeen(.init(id: "measure-1", title: "Decker", provider: "claude", stamp: stamp("measure-1")))
            let entries = count("SELECT COUNT(*) FROM board_history"), size = fileSize(file), written = bytesWritten(), started = Date()
            while Date().timeIntervalSince(started) < seconds {
                for (status, pause) in [("working", 0.07), ("idle", nextGap())] {
                    let changes = board.sessionStatus(id: "measure-1", status: status)
                    for update in changes.updates { _ = try await store.updateBoard(update) }
                    try await Task.sleep(nanoseconds: UInt64(pause * 1e9))
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            await store.close()
            line("before (old writer, synchronous=\(synchronous))", bytes: bytesWritten() - written, elapsed: elapsed, growth: fileSize(file) - size,
                 entries: count("SELECT COUNT(*) FROM board_history") - entries)
        }

        // SETTLE: the one-time history settle, as the first opening of the new app does it.
        try rawExec("DELETE FROM settings WHERE key = 'board.history.settled'")
        let entries = count("SELECT COUNT(*) FROM board_history"), size = fileSize(file), written = bytesWritten(), started = Date()
        let store = try await DeckMemoryStore.open(root: root, dataRoot: base, embedder: nil, watch: false)
        let opened = Date().timeIntervalSince(started), settleBytes = bytesWritten() - written
        report += await store.openingReport()
        line("settle once at opening (with its copy)", bytes: settleBytes, elapsed: opened, growth: fileSize(file) - size, entries: count("SELECT COUNT(*) FROM board_history") - entries)

        // AFTER: the settled engine on the settled store, the same timing.
        let clock = BackendDeckCoreEventsRealClock()
        var dependencies = DeckMemoryFlowEngine.Dependencies(store: { DeckMemoryFlowStoreAdapter(store) }, clock: clock,
            stateFile: .init(url: base.appendingPathComponent("measure-flow.json")), runner: DeckMemoryFlowTests.Runner([]), installedAIs: { ["claude"] })
        dependencies.stamp = { id in DeckMemoryStamp(owner: .lead("deck-dev"), project: "deck-dev", session: id, agent: "claude") }
        let engine = DeckMemoryFlowEngine(dependencies)
        try await store.setValue("0", key: DeckMemoryFlowKeys.tidyOn, owner: nil)   // the nightly tidy-up stays out of the numbers
        await engine.start()
        engine.post(.sessionSeen(.init(id: "measure-2", title: "Decker", provider: "terminal", project: "deck-dev")))
        await engine.settle()
        let afterEntries = count("SELECT COUNT(*) FROM board_history"), afterSize = fileSize(file), afterWritten = bytesWritten(), afterStarted = Date()
        while Date().timeIntervalSince(afterStarted) < seconds {
            for (status, pause) in [("working", 0.07), ("idle", nextGap())] {
                engine.post(.sessionStatus(id: "measure-2", status: status))
                try await Task.sleep(nanoseconds: UInt64(pause * 1e9))
            }
        }
        await engine.settle()
        let afterElapsed = Date().timeIntervalSince(afterStarted)
        line("after (settled engine)", bytes: bytesWritten() - afterWritten, elapsed: afterElapsed, growth: fileSize(file) - afterSize,
             entries: count("SELECT COUNT(*) FROM board_history") - afterEntries)
        await engine.stop(); await store.close()
        let out = ProcessInfo.processInfo.environment["TD_BOARD_WRITES_REPORT"] ?? base.appendingPathComponent("measure.txt").path
        try report.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}

extension DeckMemoryStore {
    /// For the measurement only: a PRAGMA on the store's own connection.
    func measureExec(_ sql: String) throws { try db.exec(sql) }
}
