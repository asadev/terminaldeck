import XCTest
import Foundation
import SQLite3
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 28 Oct 2026 (CPU in Asad's app, install 7 sample): every session status change rewrites a few board rows, and after
/// each write the week trim walked the row's WHOLE week of history (63,000 entries for his busiest lead), reading every
/// entry's time from the table. About 0.4 s of CPU in every 5 s. The trim now reads one row's expired entries through
/// (row_id, at) and nothing else. These checks count SQLite's own steps, so they do not depend on how busy the Mac is.
final class BoardWriteCostTests: XCTestCase {
    private func folder() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("BoardWriteCost-" + UUID().uuidString + ".noindex")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }
    private func open(_ base: URL) async throws -> DeckMemoryStore {
        try await DeckMemoryStore.open(root: base.appendingPathComponent("memory"), dataRoot: base.appendingPathComponent("data"), embedder: nil, watch: false)
    }
    private func database(_ base: URL) -> String { base.appendingPathComponent("memory/memory.db").path }

    /// A second connection to the same file: to lay down a busy week, and to read SQLite's own counters.
    private final class Raw {
        private var handle: OpaquePointer?
        private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        init(_ path: String) throws {
            guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw NSError(domain: "raw", code: 1) }
            sqlite3_busy_timeout(handle, 5_000)
        }
        deinit { sqlite3_close(handle) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "raw: " + String(cString: sqlite3_errmsg(handle)), code: 2) }
        }
        func scalar(_ sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "raw", code: 3) }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int64(statement, 0) : 0
        }
        /// Runs one trim-shaped statement (row id, cut-off, newest id) and returns its virtual-machine steps and
        /// full-scan steps, as SQLite counts them.
        func cost(_ sql: String, row: String, before cutoff: Double, newest: Int64) throws -> (steps: Int32, fullScan: Int32) {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw NSError(domain: "raw: " + String(cString: sqlite3_errmsg(handle)), code: 4)
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, row, -1, Self.transient)
            sqlite3_bind_double(statement, 2, cutoff)
            sqlite3_bind_int64(statement, 3, newest)
            while sqlite3_step(statement) == SQLITE_ROW {}
            return (sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0), sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
        }
        func plan(_ sql: String) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "raw", code: 5) }
            defer { sqlite3_finalize(statement) }
            var lines: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW { lines.append(String(cString: sqlite3_column_text(statement, 3))) }
            return lines
        }
    }

    /// The guard: with a busy week on one row, the trim after a change reads only what it deletes, never the week.
    func testTheWeekTrimAfterABoardChangeReadsOnlyWhatItDeletes() async throws {
        let base = try folder(), store = try await open(base)
        let stamp = DeckMemoryStamp(owner: .lead("crm"), session: "s1")
        _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: stamp, doing: "Working"))
        let raw = try Raw(database(base))
        // 20,000 entries for this one row inside the week (the busiest row in Asad's memory had 63,000).
        let now = Date().timeIntervalSince1970, week = DeckMemoryStore.boardHistoryKept
        try raw.exec("""
            BEGIN; WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000)
            INSERT INTO board_history (row_id, at, fields, snapshot) SELECT 'session:s1', \(now - week + 3_600) + i, 'doing', '{}' FROM n; COMMIT;
            """)
        let newest = try raw.scalar("SELECT MAX(id) FROM board_history")

        let trim = try raw.cost(DeckMemoryStore.boardHistoryTrimSQL, row: "session:s1", before: now - week, newest: newest)
        XCTAssertEqual(trim.fullScan, 0, "no full scan")
        XCTAssertLessThan(trim.steps, 200, "the trim reads only the expired entries of one row, not its week (\(trim.steps) steps)")
        // The counter has teeth: the walk it replaced, over (row_id, id), takes steps for every entry of the week.
        let walk = try raw.cost("DELETE FROM board_history INDEXED BY board_history_row WHERE row_id = ? AND at < ? AND id < ?",
                                row: "session:s1", before: now - week, newest: newest)
        XCTAssertGreaterThan(walk.steps, 20_000, "the old walk visits every entry (\(walk.steps) steps)")
        // And the plan says so: a search on (row_id, at), never a scan.
        let plan = try raw.plan(DeckMemoryStore.boardHistoryTrimSQL)
        XCTAssertTrue(plan.contains { $0.contains("board_history_row_at") && $0.contains("row_id=? AND at<?") }, plan.joined(separator: " | "))
        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN") }, plan.joined(separator: " | "))

        // Through the real write: 50 flips on that busy row keep every entry of the week, as before.
        for flip in 0..<50 { _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: stamp, doing: flip % 2 == 0 ? "Idle" : "Working")) }
        XCTAssertEqual(try raw.scalar("SELECT COUNT(*) FROM board_history WHERE row_id = 'session:s1'"), 1 + 20_000 + 50)
        await store.close()
    }

    /// A write that changes nothing writes nothing: no board update, no history entry.
    func testAWriteThatChangesNothingAddsNoHistory() async throws {
        let base = try folder(), store = try await open(base)
        let stamp = DeckMemoryStamp(owner: .lead("crm"), session: "s1")
        _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: stamp, doing: "Working"))
        let before = try await store.boardChanges(since: .distantPast, owner: nil).count
        for _ in 0..<20 { _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: stamp, doing: "Working")) }
        let after = try await store.boardChanges(since: .distantPast, owner: nil).count
        XCTAssertEqual(after, before)
        await store.close()
    }

    /// A store made before the index gets it at its next opening, with every entry still there.
    func testAnOlderStoreGetsTheIndexAtItsNextOpening() async throws {
        let base = try folder()
        var store = try await open(base)
        let stamp = DeckMemoryStamp(owner: .lead("crm"), session: "s1")
        for flip in 0..<6 { _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: stamp, doing: flip % 2 == 0 ? "Working" : "Idle")) }
        await store.close()
        do {
            let raw = try Raw(database(base))
            try raw.exec("DROP INDEX board_history_row_at")
            XCTAssertEqual(try raw.scalar("SELECT COUNT(*) FROM sqlite_master WHERE name = 'board_history_row_at'"), 0)
        }
        store = try await open(base)
        let raw = try Raw(database(base))
        XCTAssertEqual(try raw.scalar("SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'board_history_row_at'"), 1)
        let changes = try await store.boardChanges(since: .distantPast, owner: nil)
        XCTAssertEqual(changes.map(\.row.doing), ["Working", "Idle", "Working", "Idle", "Working", "Idle"])
        _ = try await store.updateBoard(.init(id: "session:s1", kind: .session, stamp: stamp, doing: "Done"))
        let later = try await store.boardChanges(since: .distantPast, owner: nil)
        XCTAssertEqual(later.count, 7)
        await store.close()
    }
}
