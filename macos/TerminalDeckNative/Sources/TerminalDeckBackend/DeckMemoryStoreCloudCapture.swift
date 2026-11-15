import Foundation
import TerminalDeckNativeCore

/// Cloud capture never adds a persistent object to memory.db (review finding 2, Decker 12 Nov).
/// Every Cloud table lives in `<stateRoot>/memory-cloud.db`, attached to the store's own connection as `cloud`;
/// capture uses TEMP triggers that vanish when the connection closes. Nothing here runs unless an account
/// enabled a memory row: the only always-on step is the launch sweep (one sqlite_master query).
extension DeckMemoryStore {
    static let cloudCaptureFile = "memory-capture.json"
    private struct CapturePointer: Codable { let stateRoot: String }

    /// Where the "capture was on for this account" pointer lives. Only inside an existing `D/cloud` folder.
    var cloudCapturePointer: URL? { dataRoot?.appendingPathComponent("cloud", isDirectory: true).appendingPathComponent(Self.cloudCaptureFile) }

    /// Runs first in `start()`, before any write. Removes persistent Cloud triggers an earlier build left in memory.db
    /// (no other change to main) and a stale pointer of a signed-out folder. It never switches capture on (M2): only the
    /// activation step of a live, signed-in account does; what was written meanwhile is caught up by the reconcile.
    func cloudLaunchSweep() {
        if let names = try? db.rows("SELECT name FROM main.sqlite_master WHERE type='trigger' AND name LIKE 'cloud_memory_%'").map({ $0.text(0) }) {
            for name in names where Self.cloudSafeIdentifier(name) { try? db.exec("DROP TRIGGER IF EXISTS main.\(name)") }
        }
        guard let pointer = cloudCapturePointer, FileManager.default.fileExists(atPath: pointer.path) else { return }
        // A data folder whose account signed out (or whose gate closed) keeps no pointer (AM8).
        if FileManager.default.fileExists(atPath: pointer.deletingLastPathComponent().appendingPathComponent("signed-out").path) {
            try? FileManager.default.removeItem(at: pointer)
        }
    }

    static func cloudSafeIdentifier(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    /// True when the per-account database is attached to this connection.
    func cloudAttached() throws -> Bool {
        try db.rows("PRAGMA database_list").contains { $0.text(1) == "cloud" }
    }

    /// Attach the account's own Cloud database and make its tables. Never touches main.
    func cloudAttach(stateRoot: URL) throws {
        guard let dataRoot else { throw CloudFailure.unsafeConfiguration }
        let cloudFolder = dataRoot.appendingPathComponent("cloud", isDirectory: true).standardizedFileURL.path
        let state = stateRoot.standardizedFileURL
        guard state.path.hasPrefix(cloudFolder + "/"), !state.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw CloudFailure.unsafeConfiguration }
        if try cloudAttached() {
            guard cloudStateRoot?.standardizedFileURL == state else { throw CloudFailure.idReused }
            return
        }
        // Unqualified names in TEMP trigger bodies must resolve to the attached tables; leftovers from an earlier test
        // build in main would shadow them, so refuse rather than write into main.
        guard try db.first("SELECT 1 FROM main.sqlite_master WHERE type='table' AND name LIKE 'cloud_memory_%'") == nil else { throw CloudFailure.unsafeConfiguration }
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try db.run("ATTACH DATABASE ? AS cloud", [.text(state.appendingPathComponent("memory-cloud.db").path)])
        do {
            try db.exec("PRAGMA cloud.journal_mode=DELETE; PRAGMA cloud.synchronous=FULL;")
            try db.transaction {
                try db.exec("""
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_control(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                INSERT OR IGNORE INTO cloud.cloud_memory_control(key,value) VALUES ('importing','0');
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_journal(seq INTEGER PRIMARY KEY AUTOINCREMENT,inventory TEXT NOT NULL,resource_key TEXT NOT NULL,body BLOB,file TEXT,hash TEXT NOT NULL,base_version TEXT,source_store TEXT,captured_at INTEGER DEFAULT (CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)));
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_files(path TEXT PRIMARY KEY,hash TEXT NOT NULL,bytes INTEGER,mtime REAL);
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_parts(op_id TEXT PRIMARY KEY,op_hash TEXT NOT NULL,operation BLOB NOT NULL,entity_id TEXT NOT NULL,parents BLOB NOT NULL,store_id TEXT NOT NULL,inventory TEXT NOT NULL,resource_key TEXT NOT NULL,revision TEXT NOT NULL,content_hash TEXT NOT NULL,part INTEGER NOT NULL,total INTEGER NOT NULL,bytes INTEGER NOT NULL,body BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_versions(store_id TEXT NOT NULL,resource_key TEXT NOT NULL,revision TEXT NOT NULL,content_hash TEXT NOT NULL,inventory TEXT NOT NULL,body BLOB NOT NULL,projection TEXT,projected_hash TEXT,parents BLOB NOT NULL,PRIMARY KEY(store_id,resource_key,revision));
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_export_heads(resource_key TEXT PRIMARY KEY,hash TEXT NOT NULL,version TEXT NOT NULL,parents BLOB NOT NULL,base_version TEXT,inventory TEXT,bytes INTEGER);
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_origins(table_name TEXT NOT NULL,native_key TEXT NOT NULL,store_id TEXT NOT NULL,resource_key TEXT NOT NULL,original_keys BLOB NOT NULL,version TEXT,PRIMARY KEY(table_name,native_key));
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_file_origins(path TEXT PRIMARY KEY,store_id TEXT NOT NULL,resource_key TEXT NOT NULL,version TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_receipt_ops(preparation TEXT NOT NULL,ordinal INTEGER NOT NULL,op_id TEXT NOT NULL,PRIMARY KEY(preparation,ordinal));
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_receipts(id TEXT PRIMARY KEY,body BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_receipt_wait(seq INTEGER PRIMARY KEY AUTOINCREMENT,op_id TEXT NOT NULL UNIQUE);
                CREATE TABLE IF NOT EXISTS cloud.cloud_memory_seq_versions(seq INTEGER NOT NULL,resource_key TEXT NOT NULL,inventory TEXT,version TEXT NOT NULL,parents BLOB NOT NULL,PRIMARY KEY(seq,resource_key));
                CREATE INDEX IF NOT EXISTS cloud.cloud_memory_parts_version ON cloud_memory_parts(resource_key,revision,part);
                CREATE INDEX IF NOT EXISTS cloud.cloud_memory_versions_key ON cloud_memory_versions(resource_key);
                CREATE INDEX IF NOT EXISTS cloud.cloud_memory_versions_revision ON cloud_memory_versions(revision);
                CREATE INDEX IF NOT EXISTS cloud.cloud_memory_seq_versions_version ON cloud_memory_seq_versions(version);
                """)
                // Mac-next 2 (13 Nov): the owner's first copy of ~7,500 records took over ten minutes at one full core.
                // Each exported record looked up its parts, versions and journal versions by columns no key covered,
                // so every record read the whole (growing) table: quadratic. These indexes make each lookup direct.
                // Round 5: every journal row records when it was captured (this Mac's clock, milliseconds); the stamp of the
                // version it becomes is that moment on the service clock. An older side database gains the column (rows
                // captured before it have none and fall back to the moment of first publish).
                if try !db.rows("PRAGMA cloud.table_info(cloud_memory_journal)").contains(where: { $0.text(1) == "captured_at" }) {
                    try db.exec("ALTER TABLE cloud.cloud_memory_journal ADD COLUMN captured_at INTEGER")
                }
                _ = try cloudStoreId()
            }
        } catch { try? db.exec("DETACH DATABASE cloud"); throw error }
        cloudStateRoot = state
    }

    /// Checks every captured column on the LIVE tables before installing anything (finding 13). Returns the mismatches.
    func cloudSchemaMismatches() throws -> [String] {
        var problems: [String] = []
        for t in DeckMemoryCloudSchema.tables where cloudEnabledRows?.contains(t.row) ?? true {
            let live = Set(try db.rows("PRAGMA main.table_info(\(t.name))").map { $0.text(1) })
            if live.isEmpty { problems.append(t.name) }
            else if !Set(t.columns).isSubset(of: live) { problems.append(t.name) }
        }
        return problems
    }

    /// TEMP triggers only, rebuilt from the checked columns at every activation (finding 13: no stale trigger survives
    /// a release that adds a column). A mismatch installs nothing, leaves capture off and is reported; memory writes never fail.
    func cloudInstallCapture() throws {
        try cloudDropCaptureTriggers()
        let mismatches = try cloudSchemaMismatches()
        guard mismatches.isEmpty else {
            try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('captureProblem',?)", [.text("schema_mismatch:" + mismatches.joined(separator: ","))])
            cloudMemoryEnabled = false
            throw CloudFailure.unsupportedFormat
        }
        try db.transaction {
            // Only the tables of enabled rows are captured, so nothing piles up for a row no pump drains.
            for t in DeckMemoryCloudSchema.travellingTables where cloudEnabledRows?.contains(t.row) ?? true {
                for (event, prefix) in [("INSERT", "NEW"), ("UPDATE", "NEW"), ("DELETE", "OLD")] {
                    try db.exec(Self.cloudTriggerSQL(t, event: event, prefix: prefix))
                }
            }
        }
        try db.run("DELETE FROM cloud_memory_control WHERE key='captureProblem' AND value LIKE 'schema_mismatch:%'")
        // R4: the captured columns at the first activation, so a later layout change forces one full pass.
        try db.run("INSERT OR IGNORE INTO cloud_memory_control(key,value) VALUES ('captureSchema',?)", [.text(try cloudCaptureSchemaFingerprint())])
        // M1: from here a failed memory write drops these triggers and is retried without them.
        db.captureGuard = true
    }

    /// The journal's mark for a row removed here (rows otherwise carry an empty hash).
    static let cloudJournalRemoved = "delete"
    static func cloudTriggerSQL(_ t: DeckMemoryCloudSchema.Table, event: String, prefix: String) -> String {
        let tombstone = t.name == "settings" && event == "DELETE"
        let cells = t.columns.map { c -> String in
            // A deleted shared setting travels as a tombstone: value null, updated = removal time (findings 18/22).
            if tombstone, c == "value" { return "json_object('type','null','value',NULL)" }
            if tombstone, c == "updated" { return "json_object('type','real','value',printf('%!.17g',(julianday('now')-2440587.5)*86400.0))" }
            return "json_object('type',typeof(\(prefix).\(c)),'value',CASE WHEN \(prefix).\(c) IS NULL THEN NULL WHEN typeof(\(prefix).\(c))='real' THEN printf('%!.17g',\(prefix).\(c)) ELSE CAST(\(prefix).\(c) AS TEXT) END)"
        }.joined(separator: ",")
        let columns = t.columns.map { "'" + $0 + "'" }.joined(separator: ",")
        let body = "json_object('table','\(t.name)','columns',json_array(\(columns)),'cells',json_array(\(cells)))"
        let name = "cloud_memory_" + t.name + "_" + event.lowercased()
        let nativeKey = "json_array(" + t.keys.map { c in "json_object('type',typeof(\(prefix).\(c)),'value',CASE WHEN \(prefix).\(c) IS NULL THEN NULL ELSE CAST(\(prefix).\(c) AS TEXT) END)" }.joined(separator: ",") + ")"
        var filter = ""
        // M3: only allow-listed shared settings are journaled; `meta` is local bookkeeping and is never journaled.
        if t.name == "meta" { filter = " AND 0" }
        if t.name == "settings" { filter = " AND " + DeckMemoryCloudSchema.travellingSettingCondition(prefix + ".") }
        // MAC-NEXT-8b: a removal here is marked in the journal ('delete') and leaves the record standing at no version, so
        // the same content made again later is this Mac's own new version (identity, not content, decides the echo).
        let removed = event == "DELETE"
        let after = removed ? " UPDATE cloud_memory_origins SET version=NULL WHERE table_name='\(t.name)' AND native_key=\(nativeKey);" : ""
        return """
        CREATE TEMP TRIGGER IF NOT EXISTS \(name) AFTER \(event) ON \(t.name)
        WHEN (SELECT value FROM cloud_memory_control WHERE key='importing')='0'\(filter)
        BEGIN INSERT INTO cloud_memory_journal(inventory,resource_key,body,hash,base_version)
        VALUES ('\(t.row)','row/\(t.name)',CAST(\(body) AS BLOB),'\(removed ? Self.cloudJournalRemoved : "")',(SELECT version FROM cloud_memory_origins WHERE table_name='\(t.name)' AND native_key=\(nativeKey)));\(after) END;
        """
    }

    func cloudDropCaptureTriggers() throws {
        db.captureGuard = false
        let names = try db.rows("SELECT name FROM sqlite_temp_master WHERE type='trigger' AND name LIKE 'cloud_memory_%'").map { $0.text(0) }
        for name in names where Self.cloudSafeIdentifier(name) { try db.exec("DROP TRIGGER IF EXISTS temp.\(name)") }
    }

    /// Re-establishes capture for one account: attach, column check, TEMP triggers, persisted pointer.
    /// Any failure leaves capture OFF with nothing installed.
    public func cloudResumeCapture(stateRoot: URL) throws { try cloudResumeCapture(stateRoot: stateRoot, rows: nil) }
    /// As above, capturing only the tables of `rows` (nil = all).
    public func cloudResumeCapture(stateRoot: URL, rows: [String]?) throws {
        if let rows { cloudEnabledRows = Set(rows) }
        do {
            try cloudAttach(stateRoot: stateRoot)
            try cloudInstallCapture()
            cloudMemoryEnabled = true
            cloudCaptureLost = false
            if let pointer = cloudCapturePointer {
                let bytes = try JSONEncoder().encode(CapturePointer(stateRoot: stateRoot.standardizedFileURL.path))
                if (try? Data(contentsOf: pointer)) != bytes {
                    try FileManager.default.createDirectory(at: pointer.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try bytes.write(to: pointer, options: .atomic)
                }
            }
        } catch {
            cloudMemoryEnabled = false
            try? cloudDropCaptureTriggers()
            throw error
        }
    }

    /// After a memory-folder move reopens the connection, the attachment and TEMP triggers are gone; put them back.
    func cloudReattachAfterReopen() {
        guard cloudMemoryEnabled, let state = cloudStateRoot else { return }
        cloudStateRoot = nil
        do { try cloudResumeCapture(stateRoot: state) }
        catch { cloudMemoryEnabled = false; cloudStateRoot = nil }
    }

    /// Marks capture as interrupted for this account: the next activation runs the reconcile (rows edited meanwhile were not journaled).
    static func cloudMarkGap(stateRoot: URL) {
        try? FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try? Data("gap\n".utf8).write(to: stateRoot.appendingPathComponent("capture-gap"), options: .atomic)
    }
}
