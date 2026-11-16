import Foundation
import SQLite3
import TerminalDeckNativeCore

/// The file adapters' own small state database (one per inventory row, inside the signed-in identity's Cloud folder).
/// It never opens memory.db or any owner's database. Used only from inside its adapter actor.
final class BackendCloudBrainFilesDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private var depth = 0

    /// `engineTables: false` for a small database of its own that is not a file engine's (the versions table).
    init(path: String, engineTables: Bool = true) throws {
        var live: OpaquePointer?
        let status = sqlite3_open_v2(path, &live, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let live else {
            if let live { sqlite3_close(live) }
            throw CloudFailure.unavailable
        }
        handle = live
        sqlite3_busy_timeout(live, 5_000)
        try exec("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
        guard engineTables else { return }
        try exec("""
        CREATE TABLE IF NOT EXISTS control(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS files(source_id TEXT NOT NULL, path TEXT NOT NULL, hash TEXT NOT NULL, bytes INTEGER NOT NULL, mtime REAL NOT NULL,
            store_id TEXT NOT NULL, key TEXT NOT NULL, version TEXT NOT NULL, parents TEXT NOT NULL, created_at INTEGER NOT NULL, raw_hash TEXT NOT NULL,
            raw_bytes INTEGER NOT NULL, origin_device TEXT NOT NULL, imported INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
            pending INTEGER NOT NULL DEFAULT 0, project_id TEXT, root_id TEXT, PRIMARY KEY(source_id, path));
        CREATE TABLE IF NOT EXISTS journal(seq INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, source_id TEXT NOT NULL, path TEXT NOT NULL,
            store_id TEXT NOT NULL, key TEXT NOT NULL, version TEXT NOT NULL, parents TEXT NOT NULL, created_at INTEGER NOT NULL,
            raw_hash TEXT NOT NULL, raw_bytes INTEGER NOT NULL, project_id TEXT, root_id TEXT);
        CREATE TABLE IF NOT EXISTS parts(op_id TEXT PRIMARY KEY, op_hash TEXT NOT NULL, operation BLOB NOT NULL, kind TEXT NOT NULL,
            store_id TEXT NOT NULL, key TEXT NOT NULL, version TEXT NOT NULL, part INTEGER NOT NULL, total INTEGER NOT NULL, bytes INTEGER NOT NULL,
            resource_hash TEXT NOT NULL, parents TEXT NOT NULL, origin_device TEXT NOT NULL, created_at INTEGER NOT NULL,
            project_id TEXT, root_id TEXT, body BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS resources(store_id TEXT NOT NULL, key TEXT NOT NULL, version TEXT NOT NULL, kind TEXT NOT NULL,
            source_id TEXT NOT NULL, relative TEXT NOT NULL, raw_hash TEXT NOT NULL, raw_bytes INTEGER NOT NULL, parents TEXT NOT NULL,
            origin_device TEXT NOT NULL, created_at INTEGER NOT NULL, project_id TEXT, root_id TEXT, status TEXT NOT NULL,
            destination TEXT, local_hash TEXT, reason TEXT, PRIMARY KEY(store_id, key, version));
        CREATE TABLE IF NOT EXISTS receipts(id TEXT PRIMARY KEY, body BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS receipt_resources(preparation TEXT NOT NULL, store_id TEXT NOT NULL, key TEXT NOT NULL, version TEXT NOT NULL,
            PRIMARY KEY(preparation, store_id, key, version));
        CREATE TABLE IF NOT EXISTS cursors(scope TEXT PRIMARY KEY, value TEXT NOT NULL);
        """)
    }
    deinit { close() }
    func close() { if let handle { sqlite3_close(handle) }; handle = nil }

    func exec(_ sql: String) throws {
        guard let handle, sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CloudFailure.unavailable }
    }
    private func prepare(_ sql: String, _ args: [DeckMemorySQL]) throws -> OpaquePointer {
        guard let handle else { throw CloudFailure.unavailable }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CloudFailure.unavailable }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1), status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, index)
            case .int(let number): status = sqlite3_bind_int64(statement, index, number)
            case .real(let number): status = sqlite3_bind_double(statement, index, number)
            case .text(let text):
                guard text.utf8.count <= Int32.max else { sqlite3_finalize(statement); throw CloudFailure.invalidRequest }
                status = sqlite3_bind_text(statement, index, text, Int32(text.utf8.count), Self.transient)
            case .blob(let data):
                guard data.count <= Int32.max else { sqlite3_finalize(statement); throw CloudFailure.invalidRequest }
                // A nil base address would bind SQL NULL; an empty file part is an empty BLOB.
                if data.isEmpty { status = sqlite3_bind_zeroblob(statement, index, 0) }
                else { status = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient) } }
            }
            guard status == SQLITE_OK else { sqlite3_finalize(statement); throw CloudFailure.unavailable }
        }
        return statement
    }
    @discardableResult func run(_ sql: String, _ args: [DeckMemorySQL] = []) throws -> Int64 {
        let statement = try prepare(sql, args); defer { sqlite3_finalize(statement) }
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW { status = sqlite3_step(statement) }
        guard status == SQLITE_DONE else { throw CloudFailure.unavailable }
        return sqlite3_last_insert_rowid(handle)
    }
    func rows(_ sql: String, _ args: [DeckMemorySQL] = []) throws -> [DeckMemoryRow] {
        let statement = try prepare(sql, args); defer { sqlite3_finalize(statement) }
        var out: [DeckMemoryRow] = []
        let columns = sqlite3_column_count(statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw CloudFailure.unavailable }
            var values: [DeckMemorySQL] = []
            values.reserveCapacity(Int(columns))
            for column in 0..<columns {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values.append(.int(sqlite3_column_int64(statement, column)))
                case SQLITE_FLOAT: values.append(.real(sqlite3_column_double(statement, column)))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    if count == 0 { values.append(.text("")) }
                    else {
                        guard let pointer = sqlite3_column_text(statement, column) else { throw CloudFailure.unavailable }
                        values.append(.text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self)))
                    }
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
    /// All or nothing. Nested calls join the outer one.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if depth > 0 { return try body() }
        try exec("BEGIN IMMEDIATE"); depth += 1
        do { let value = try body(); depth -= 1; try exec("COMMIT"); return value }
        catch { depth -= 1; try? exec("ROLLBACK"); throw error }
    }
}
