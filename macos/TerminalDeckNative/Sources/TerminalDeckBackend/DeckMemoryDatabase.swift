import Foundation
import SQLite3
import TerminalDeckNativeCore

/// One value in or out of memory.db.
enum DeckMemorySQL: Equatable {
    case null, int(Int64), real(Double), text(String), blob(Data)
    static func optional(_ value: String?) -> DeckMemorySQL { value.map(DeckMemorySQL.text) ?? .null }
    static func optional(_ value: Date?) -> DeckMemorySQL { value.map { .real($0.timeIntervalSince1970) } ?? .null }
    static func date(_ value: Date) -> DeckMemorySQL { .real(value.timeIntervalSince1970) }
    static func bool(_ value: Bool) -> DeckMemorySQL { .int(value ? 1 : 0) }
    static func optional(_ value: Int?) -> DeckMemorySQL { value.map { .int(Int64($0)) } ?? .null }
}

struct DeckMemoryRow {
    let values: [DeckMemorySQL]
    func string(_ index: Int) -> String? { if case .text(let text) = values[index] { return text }; return nil }
    func text(_ index: Int) -> String { string(index) ?? "" }
    func int(_ index: Int) -> Int64 {
        switch values[index] {
        case .int(let number): return number
        case .real(let number): return Int64(number)
        default: return 0
        }
    }
    func double(_ index: Int) -> Double? {
        switch values[index] {
        case .real(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }
    func date(_ index: Int) -> Date? { double(index).map(Date.init(timeIntervalSince1970:)) }
    func data(_ index: Int) -> Data? { if case .blob(let data) = values[index] { return data }; return nil }
    func isNull(_ index: Int) -> Bool { values[index] == .null }
    func optionalInt(_ index: Int) -> Int? { isNull(index) ? nil : Int(int(index)) }
}

/// The system SQLite, one connection, used only from inside the store's actor.
final class DeckMemoryDatabase {
    private var handle: OpaquePointer?
    let path: String
    /// Full-text search (FTS5). False only if this Mac's SQLite lacks it; then search uses plain matching.
    private(set) var hasFTS = false
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let schemaVersion = 1

    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        var live: OpaquePointer?
        let status = sqlite3_open_v2(path, &live, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let live else {
            let message = live.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
            if let live { sqlite3_close(live) }
            throw DeckMemoryError(.io, "The memory database could not be opened: \(message)")
        }
        handle = live
        sqlite3_busy_timeout(live, readOnly ? 100 : 5_000)
        if readOnly { return }
        // A rollback journal, not WAL: the folder is visible and movable, so no side files stay behind.
        try exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
        try migrate()
    }
    deinit { close() }
    func close() { if let handle { sqlite3_close(handle) }; handle = nil }

    private func failure(_ what: String) -> DeckMemoryError {
        .init(.io, "The memory database refused \(what): " + (handle.map { String(cString: sqlite3_errmsg($0)) } ?? "it is closed"))
    }
    func exec(_ sql: String) throws {
        guard let handle else { throw failure("a command") }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure("a command") }
    }
    private func prepare(_ sql: String, _ args: [DeckMemorySQL]) throws -> OpaquePointer {
        guard let handle else { throw failure("a query") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure("a query") }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1), status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, index)
            case .int(let number): status = sqlite3_bind_int64(statement, index, number)
            case .real(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let text): status = sqlite3_bind_text(statement, index, text, -1, Self.transient)
            case .blob(let data):
                status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) }
            }
            guard status == SQLITE_OK else { sqlite3_finalize(statement); throw failure("a value") }
        }
        return statement
    }
    /// Runs a change. Returns the new row id for an insert.
    @discardableResult func run(_ sql: String, _ args: [DeckMemorySQL] = []) throws -> Int64 {
        let statement = try prepare(sql, args); defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw failure("a change") }
        return sqlite3_last_insert_rowid(handle)
    }
    var changes: Int { Int(sqlite3_changes(handle)) }
    func rows(_ sql: String, _ args: [DeckMemorySQL] = []) throws -> [DeckMemoryRow] {
        let statement = try prepare(sql, args); defer { sqlite3_finalize(statement) }
        var out: [DeckMemoryRow] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw failure("a read") }
            var values: [DeckMemorySQL] = []; values.reserveCapacity(Int(columns))
            for column in 0..<columns {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT: values.append(.text(String(cString: sqlite3_column_text(statement, column))))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    values.append(.blob(sqlite3_column_blob(statement, column).map { Data(bytes: $0, count: count) } ?? Data()))
                default: values.append(.null)
                }
            }
            out.append(DeckMemoryRow(values: values))
        }
        return out
    }
    func first(_ sql: String, _ args: [DeckMemorySQL] = []) throws -> DeckMemoryRow? { try rows(sql, args).first }
    private var depth = 0
    /// All or nothing. Nested calls join the outer one.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE"); depth += 1
        do { let value = try body(); depth -= 1; try exec("COMMIT"); return value }
        catch { depth -= 1; try? exec("ROLLBACK"); throw error }
    }

    /// Adds a column to a table that was made before the column existed. Does nothing when it is there.
    private func addColumn(_ table: String, _ column: String, _ type: String) throws {
        let has = try rows("PRAGMA table_info(\(table))").contains { $0.text(1) == column }
        if !has { try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
    }
    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS settings (owner TEXT NOT NULL DEFAULT '', key TEXT NOT NULL, value TEXT NOT NULL, updated REAL NOT NULL, PRIMARY KEY (owner, key));
        CREATE TABLE IF NOT EXISTS diary (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            owner TEXT NOT NULL, project TEXT, session TEXT, agent TEXT,
            role TEXT NOT NULL, text TEXT NOT NULL, conversation TEXT, turn TEXT, external_id TEXT UNIQUE,
            at REAL NOT NULL, saved REAL NOT NULL, meta TEXT NOT NULL DEFAULT '{}', hand INTEGER, job TEXT, author TEXT);
        CREATE INDEX IF NOT EXISTS diary_session ON diary(session, id);
        CREATE INDEX IF NOT EXISTS diary_conversation ON diary(conversation, id);
        CREATE INDEX IF NOT EXISTS diary_owner ON diary(owner, id);
        CREATE INDEX IF NOT EXISTS diary_at ON diary(at);
        CREATE TABLE IF NOT EXISTS board (
            id TEXT PRIMARY KEY, kind TEXT NOT NULL, title TEXT NOT NULL DEFAULT '',
            owner TEXT NOT NULL, project TEXT, session TEXT, agent TEXT,
            doing TEXT NOT NULL DEFAULT '', last_result TEXT NOT NULL DEFAULT '', waiting TEXT NOT NULL DEFAULT '',
            state TEXT, proof TEXT NOT NULL DEFAULT '', updated REAL NOT NULL, archived REAL, hand INTEGER, job TEXT);
        CREATE INDEX IF NOT EXISTS board_updated ON board(updated);
        CREATE TABLE IF NOT EXISTS board_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT, row_id TEXT NOT NULL, at REAL NOT NULL, fields TEXT NOT NULL, snapshot TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS board_history_at ON board_history(at);
        CREATE INDEX IF NOT EXISTS board_history_row ON board_history(row_id, id);
        -- 28 Oct 2026: the week trim after each board change reads only the expired entries of one row through this
        -- index (it walked the whole week of that row before: 63,000 entries for a busy lead). Added to older stores
        -- by this same statement at their next opening; nothing else changes.
        CREATE INDEX IF NOT EXISTS board_history_row_at ON board_history(row_id, at);
        CREATE TABLE IF NOT EXISTS notes (
            id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, title TEXT NOT NULL, type TEXT NOT NULL,
            owner TEXT NOT NULL, project TEXT, session TEXT, agent TEXT, date REAL NOT NULL,
            source TEXT NOT NULL DEFAULT '', supersedes TEXT, superseded_by TEXT,
            archived REAL, archive_reason TEXT, origin_path TEXT,
            mtime REAL NOT NULL, bytes INTEGER NOT NULL, hash TEXT NOT NULL, missing INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL,
            hand INTEGER, job TEXT, valid_from REAL, valid_until REAL, diary_first INTEGER, diary_last INTEGER, norm TEXT, author TEXT);
        CREATE INDEX IF NOT EXISTS notes_norm ON notes(owner, norm);
        CREATE INDEX IF NOT EXISTS notes_owner ON notes(owner, date);
        CREATE INDEX IF NOT EXISTS notes_project ON notes(project, date);
        CREATE TABLE IF NOT EXISTS topics (
            owner TEXT NOT NULL, id TEXT NOT NULL, title TEXT NOT NULL, path TEXT NOT NULL UNIQUE, open INTEGER NOT NULL DEFAULT 1,
            project TEXT, session TEXT, agent TEXT, date REAL NOT NULL,
            mtime REAL NOT NULL, bytes INTEGER NOT NULL, hash TEXT NOT NULL, missing INTEGER NOT NULL DEFAULT 0, hand INTEGER, job TEXT,
            PRIMARY KEY (owner, id));
        CREATE TABLE IF NOT EXISTS files (
            path TEXT PRIMARY KEY, kind TEXT NOT NULL, owner TEXT NOT NULL,
            mtime REAL NOT NULL, bytes INTEGER NOT NULL, hash TEXT NOT NULL, missing INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS questions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT NOT NULL, text TEXT NOT NULL, context TEXT NOT NULL DEFAULT '',
            refs TEXT NOT NULL DEFAULT '[]', asked REAL NOT NULL, answer TEXT, answered REAL, dismissed REAL);
        CREATE TABLE IF NOT EXISTS search_map (kind TEXT NOT NULL, ref TEXT NOT NULL, row INTEGER NOT NULL, PRIMARY KEY (kind, ref));
        CREATE TABLE IF NOT EXISTS embeddings (
            kind TEXT NOT NULL, ref TEXT NOT NULL, piece INTEGER NOT NULL DEFAULT 0, owner TEXT NOT NULL, project TEXT, session TEXT, agent TEXT,
            archived INTEGER NOT NULL DEFAULT 0, at REAL, model TEXT NOT NULL, vector BLOB NOT NULL, PRIMARY KEY (kind, ref, piece));
        CREATE TABLE IF NOT EXISTS embed_queue (kind TEXT NOT NULL, ref TEXT NOT NULL, PRIMARY KEY (kind, ref));
        """)
        // Columns that arrived after the first databases were made (the dev copy's is from 02:11 on 11 Oct).
        try addColumn("questions", "dismissed", "REAL")
        try addColumn("diary", "rewound", "REAL")
        try addColumn("diary", "rewind_id", "INTEGER")
        try exec("""
        CREATE TABLE IF NOT EXISTS handoffs (
            id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, owner TEXT NOT NULL, topic TEXT, title TEXT NOT NULL,
            project TEXT, session TEXT, agent TEXT, hand INTEGER, job TEXT, author TEXT, date REAL NOT NULL, updated REAL NOT NULL,
            archived REAL, archive_reason TEXT, origin_path TEXT,
            mtime REAL NOT NULL, bytes INTEGER NOT NULL, hash TEXT NOT NULL, missing INTEGER NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS handoffs_owner ON handoffs(owner, topic, date);
        CREATE TABLE IF NOT EXISTS rewinds (
            id INTEGER PRIMARY KEY AUTOINCREMENT, owner TEXT NOT NULL, conversation TEXT NOT NULL, after_row INTEGER NOT NULL,
            at REAL NOT NULL, rows INTEGER NOT NULL DEFAULT 0, notes TEXT NOT NULL DEFAULT '[]', topics TEXT NOT NULL DEFAULT '[]',
            undo TEXT NOT NULL DEFAULT '{}', undone REAL);
        """)
        // The search index: FTS5 when the system SQLite has it, a plain table with the same columns otherwise.
        if try first("SELECT 1 FROM sqlite_master WHERE name = 'search'") == nil {
            do {
                // archived: 0 current, 1 archived, 2 replaced (superseded or merged). at: when it was said or became true.
                try exec("CREATE VIRTUAL TABLE search USING fts5(kind UNINDEXED, ref UNINDEXED, owner UNINDEXED, project UNINDEXED, session UNINDEXED, agent UNINDEXED, archived UNINDEXED, title, body, at UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
            } catch {
                try exec("CREATE TABLE search (kind TEXT, ref TEXT, owner TEXT, project TEXT, session TEXT, agent TEXT, archived INTEGER, title TEXT, body TEXT, at REAL)")
            }
        }
        hasFTS = ((try first("SELECT sql FROM sqlite_master WHERE name = 'search'"))?.string(0) ?? "").lowercased().contains("fts5")
        try run("INSERT OR IGNORE INTO meta (key, value) VALUES ('schema', ?)", [.text(String(Self.schemaVersion))])
    }
}
