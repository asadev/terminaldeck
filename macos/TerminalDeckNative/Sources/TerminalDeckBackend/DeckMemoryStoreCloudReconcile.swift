import Foundation
import TerminalDeckNativeCore

/// THE RECONCILE (review rounds 2 and 3: M1, M2, M7, M9, R1-R5).
/// Capture is sometimes off: between a launch and the account's activation (M2: capture is never switched on from a
/// local file), after the capture guard dropped the triggers because the side database failed (M1), after a crash,
/// a sign-out or a pause. The reconcile catches up what was not journaled meanwhile, instead of a new full cut.
/// - Which pass (R4): a FULL pass only after an unclean shutdown, a dropped capture (gap marker) or a change of the
///   captured columns. Otherwise a TAIL pass, or the saved position of an unfinished pass is resumed.
/// - Rows, append-only tables (diary, board history): a tail pass sends every row above the highest row id already
///   covered (by the cut, an earlier pass, or a clean close while capture was on), without comparing; old diary rows
///   that a rewind marked are sent with that rewind. A full pass compares them like the rest.
/// - Rows, every other captured table (small and keyed: board, handoffs, rewinds, settings, questions, notes, topics,
///   files): each row is rebuilt as an export would build it (`cloudLogicalRow`) and its content hash compared with this
///   account's export head; missing or different gives one journal row, the body the trigger writes. A shared setting
///   exported earlier and now gone gives a tombstone. Other deletions are history and send nothing (S15).
/// - R1: a table is compared only when its inventory row has nothing waiting in the journal, so an older queued value
///   can never be sent after a row was changed back. A tail pass appends, so it never needs to wait.
/// - R3: a row that cannot be encoded is skipped, counted and named in coverage; the pass goes on.
/// - Files: size and modification time against `cloud_memory_files`, a hash only when those differ; listed once per
///   pass and consumed from a saved position (M9).
/// - Cost: steps of `limit` rows or files, run by the journal pumps on their own slow tick until idle (R2), never on a
///   memory write. The position is saved by table NAME, so a build that enables another row resumes correctly.
extension DeckMemoryStore {
    static let cloudAppendOnlyTables: Set<String> = ["diary", "board_history"]

    /// The captured tables of enabled rows, in schema order (`meta` never travels).
    func cloudReconcileTables() -> [DeckMemoryCloudSchema.Table] {
        DeckMemoryCloudSchema.travellingTables.filter { $0.name != "meta" && (cloudEnabledRows?.contains($0.row) ?? true) }
    }

    func cloudStartReconcile(full: Bool = true) throws {
        guard cloudMemoryEnabled, let first = cloudReconcileTables().first else { return }
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('rowsReconcile',?)",
                   [.text(first.name + ":" + String(Int64.min) + ":" + (full ? "full" : "tail"))])
        try db.run("DELETE FROM cloud_memory_control WHERE key LIKE 'reconcileSkipped:%'")
        try cloudMarkFilesDirty()
    }
    func cloudReconcilePending() throws -> Bool {
        try db.first("SELECT 1 FROM cloud_memory_control WHERE key IN ('rowsReconcile','filesDirty','tailFirst') LIMIT 1") != nil
    }

    /// R4, decided at activation: full only after an unclean shutdown, a dropped capture or a schema change; otherwise
    /// an unfinished pass resumes where it stopped, or a tail pass starts.
    func cloudPlanReconcile() throws {
        guard cloudMemoryEnabled, let state = cloudStateRoot else { return }
        let clean = try db.first("SELECT value FROM cloud_memory_control WHERE key='cleanClose'")?.text(0) == "1"
        let gap = FileManager.default.fileExists(atPath: state.appendingPathComponent("capture-gap").path)
        let schema = try cloudCaptureSchemaFingerprint()
        let sameSchema = try db.first("SELECT value FROM cloud_memory_control WHERE key='captureSchema'")?.string(0) == schema
        try db.run("DELETE FROM cloud_memory_control WHERE key='cleanClose'")
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('captureSchema',?)", [.text(schema)])
        let mode: String
        if !clean || gap || !sameSchema { mode = "full"; try cloudStartReconcile(full: true) }
        else if try db.first("SELECT 1 FROM cloud_memory_control WHERE key='rowsReconcile'") != nil {
            // R6: the resumed pass may already be past the append-only tables, and rows were written there before this
            // activation (capture off). Those tables get a tail from their marks FIRST, before any mark can move.
            mode = "resume"
            if let first = cloudReconcileTables().first(where: { Self.cloudAppendOnlyTables.contains($0.name) }) {
                try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('tailFirst',?)", [.text(first.name + ":" + String(Int64.min))])
            }
            try cloudMarkFilesDirty()
        }
        else { mode = "tail"; try cloudStartReconcile(full: false) }
        // What this activation chose, for coverage diagnostics and tests.
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('reconcileMode',?)", [.text(mode)])
    }
    /// The live columns of every captured table; a later release that changes them forces one full pass.
    func cloudCaptureSchemaFingerprint() throws -> String {
        var parts: [String] = []
        for t in cloudReconcileTables() {
            let columns = try db.rows("PRAGMA main.table_info(\(t.name))").map { $0.text(1) }.sorted()
            parts.append(t.name + "(" + columns.joined(separator: ",") + ")")
        }
        return DeckMemoryFiles.hash(parts.joined(separator: ";"))
    }
    /// Called when the store closes normally while capture is on and healthy: every write of this run was journaled.
    /// Records that, and (when no pass is unfinished) moves the append-only high-water marks to the current end.
    func cloudCleanClose() {
        guard cloudMemoryEnabled, !cloudCaptureLost, db.captureLost == nil, (try? cloudAttached()) == true else { return }
        if (try? db.first("SELECT 1 FROM cloud_memory_control WHERE key IN ('rowsReconcile','tailFirst') LIMIT 1")) == nil {
            for t in cloudReconcileTables() where Self.cloudAppendOnlyTables.contains(t.name) { cloudRecordHighWater(t.name) }
        }
        try? db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('cleanClose','1')")
    }
    func cloudRecordHighWater(_ table: String, database: DeckMemoryDatabase? = nil) {
        guard Self.cloudAppendOnlyTables.contains(table),
              let top = try? (database ?? db).first("SELECT MAX(rowid) FROM main.\(table)"), !top.isNull(0) else { return }
        try? db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text("reconciledRowid:" + table), .text(String(top.int(0)))])
    }

    /// One bounded step of the rows reconcile. Returns how many rows were looked at; 0 means nothing to do now.
    func cloudReconcileRows(limit: Int = 256) throws -> Int {
        guard cloudMemoryEnabled else { return 0 }
        let tailFirst = try cloudReconcileTailFirst(limit: limit)
        if tailFirst > 0 { return tailFirst }
        guard let saved = try db.first("SELECT value FROM cloud_memory_control WHERE key='rowsReconcile'")?.string(0) else { return 0 }
        let tables = cloudReconcileTables()
        let fields = saved.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 3, var after = Int64(fields[1]) else {
            try db.run("DELETE FROM cloud_memory_control WHERE key='rowsReconcile'"); return 0
        }
        let full = fields[2] == "full"
        // A table that is no longer captured: start that pass again from the first table (by name, never by index).
        let named = tables.firstIndex(where: { $0.name == String(fields[0]) })
        var index = named ?? 0
        if named == nil { after = Int64.min }
        let storeId = try cloudStoreId()
        let waiting = Set(try db.rows("SELECT DISTINCT inventory FROM cloud_memory_journal").map { $0.text(0) })
        var looked = 0
        while looked < max(1, limit), index < tables.count {
            let t = tables[index]
            let tail = !full && Self.cloudAppendOnlyTables.contains(t.name)
            // R1: never compare while an older value of this inventory may still be queued; the pumps drain it first.
            if !tail, waiting.contains(t.row) { break }
            var floor = after
            if tail, after == Int64.min,
               let mark = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("reconciledRowid:" + t.name)])?.string(0), let high = Int64(mark) { floor = high }
            let filter = t.name == "settings" ? " AND " + DeckMemoryCloudSchema.travellingSettingCondition() : ""
            let page = try db.rows("SELECT rowid,\(t.columns.joined(separator: ",")) FROM main.\(t.name) WHERE rowid>?\(filter) ORDER BY rowid LIMIT ?",
                                   [.int(floor), .int(Int64(max(1, limit) - looked))])
            if page.isEmpty {
                if t.name == "settings" { try cloudReconcileSettingTombstones(storeId: storeId) }
                cloudRecordHighWater(t.name)
                index += 1; after = Int64.min; continue
            }
            for r in page {
                after = r.int(0); looked += 1
                let values = Array(r.values.dropFirst())
                do {
                    // A tail journals without comparing; an arrived row it picks up is dropped when the journal is read (Y3).
                    if tail { try cloudJournalRow(t, values: values); continue }
                    let resource = try cloudLogicalRow(t, values: values, database: db, storeId: storeId, sequence: 0, row: t.row)
                    // Y3: what arrived from the Cloud and was not changed here is not this Mac's to send.
                    if try cloudIsEcho(resource, table: t, values: values, database: db, storeId: storeId) { continue }
                    let headKey = (resource.originStoreId ?? storeId) + ":" + resource.key
                    if try db.first("SELECT hash FROM cloud_memory_export_heads WHERE resource_key=?", [.text(headKey)])?.string(0) == resource.hash { continue }
                    try cloudJournalRow(t, values: values)
                    if t.name == "rewinds" { try cloudJournalRowsMarked(byRewind: values) }
                } catch let failure as DeckMemoryError {
                    // A database failure (the side database refusing a write, for example) is not an unreadable row:
                    // the step stops, the pump reports it and the same position is tried again later.
                    throw failure
                } catch {
                    // R3: a row that cannot be rebuilt or encoded is skipped, counted and named; the rest is still checked.
                    try cloudCountReconcileSkip(t.row)
                }
            }
        }
        if index >= tables.count { try db.run("DELETE FROM cloud_memory_control WHERE key='rowsReconcile'") }
        else {
            try db.run("UPDATE cloud_memory_control SET value=? WHERE key='rowsReconcile'",
                       [.text(tables[index].name + ":" + String(after) + ":" + (full ? "full" : "tail"))])
        }
        return looked
    }

    /// The same journal row the capture trigger writes for this physical row.
    private func cloudJournalRow(_ t: DeckMemoryCloudSchema.Table, values: [DeckMemorySQL]) throws {
        let body = try DeckMemoryCloudSchema.encodeRow(t, values), nativeKey = try DeckMemoryCloudSchema.nativeKey(t, values)
        try db.run("INSERT INTO cloud_memory_journal(inventory,resource_key,body,hash,base_version) VALUES (?,?,?,'',(SELECT version FROM cloud_memory_origins WHERE table_name=? AND native_key=?))",
                   [.text(t.row), .text("row/" + t.name), .blob(body), .text(t.name), .text(nativeKey)])
    }
    /// A rewind changed while capture was off (marked, or undone): the diary rows it covers are sent with it, since tail
    /// passes do not re-read old diary rows (R7). Covered: rows still carrying its id, and every row of the same owner
    /// and conversation above `after_row`, so an undo (marks cleared) travels too.
    private func cloudJournalRowsMarked(byRewind values: [DeckMemorySQL]) throws {
        guard cloudEnabledRows?.contains("I02") ?? true, let rewinds = try? DeckMemoryCloudSchema.table("rewinds"),
              let idIndex = rewinds.columns.firstIndex(of: "id"), case .int(let id) = values[idIndex] else { return }
        let diary = try DeckMemoryCloudSchema.table("diary")
        var sql = "SELECT \(diary.columns.joined(separator: ",")) FROM main.diary WHERE rewind_id=?"
        var args: [DeckMemorySQL] = [.int(id)]
        if let ownerIndex = rewinds.columns.firstIndex(of: "owner"), let conversationIndex = rewinds.columns.firstIndex(of: "conversation"),
           let afterIndex = rewinds.columns.firstIndex(of: "after_row"), case .int(let afterRow) = values[afterIndex] {
            sql += " OR (owner=? AND conversation IS ? AND id>?)"
            args += [values[ownerIndex], values[conversationIndex], .int(afterRow)]
        }
        for r in try db.rows(sql + " ORDER BY rowid", args) {
            do { try cloudJournalRow(diary, values: r.values) }
            catch let failure as DeckMemoryError { throw failure }
            catch { try cloudCountReconcileSkip(diary.row) }
        }
    }
    /// R6: before a resumed pass continues, the append-only tables get a tail from their high-water marks, journaling
    /// rows written before this activation while capture was off. No mark moves while it is pending.
    private func cloudReconcileTailFirst(limit: Int) throws -> Int {
        guard let saved = try db.first("SELECT value FROM cloud_memory_control WHERE key='tailFirst'")?.string(0) else { return 0 }
        let tables = cloudReconcileTables().filter { Self.cloudAppendOnlyTables.contains($0.name) }
        let fields = saved.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, var after = Int64(fields[1]), var index = tables.firstIndex(where: { $0.name == String(fields[0]) }) else {
            try db.run("DELETE FROM cloud_memory_control WHERE key='tailFirst'"); return 0
        }
        var looked = 0
        while looked < max(1, limit), index < tables.count {
            let t = tables[index]
            var floor = after
            if after == Int64.min,
               let mark = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("reconciledRowid:" + t.name)])?.string(0), let high = Int64(mark) { floor = high }
            let page = try db.rows("SELECT rowid,\(t.columns.joined(separator: ",")) FROM main.\(t.name) WHERE rowid>? ORDER BY rowid LIMIT ?",
                                   [.int(floor), .int(Int64(max(1, limit) - looked))])
            if page.isEmpty { index += 1; after = Int64.min; continue }
            for r in page {
                after = r.int(0); looked += 1
                do { try cloudJournalRow(t, values: Array(r.values.dropFirst())) }
                catch let failure as DeckMemoryError { throw failure }
                catch { try cloudCountReconcileSkip(t.row) }
            }
        }
        if index >= tables.count { try db.run("DELETE FROM cloud_memory_control WHERE key='tailFirst'") }
        else { try db.run("UPDATE cloud_memory_control SET value=? WHERE key='tailFirst'", [.text(tables[index].name + ":" + String(after))]) }
        return max(looked, index >= tables.count ? 1 : 0)
    }
    private func cloudCountReconcileSkip(_ row: String) throws {
        try db.run("INSERT INTO cloud_memory_control(key,value) VALUES (?, '1') ON CONFLICT(key) DO UPDATE SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT)",
                   [.text("reconcileSkipped:" + row)])
    }
    /// R3: how many records of this row the last pass could not check (named as a gap in coverage).
    func cloudReconcileSkipped(_ row: String) throws -> Int {
        Int(try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("reconcileSkipped:" + row)])?.string(0) ?? "0") ?? 0
    }

    /// A shared setting this account exported that no longer exists here travels as a removal (findings 18/22).
    private func cloudReconcileSettingTombstones(storeId: String) throws {
        let t = try DeckMemoryCloudSchema.table("settings")
        guard let valueIndex = t.columns.firstIndex(of: "value"), let updatedIndex = t.columns.firstIndex(of: "updated") else { return }
        for head in try db.rows("SELECT resource_key,version FROM cloud_memory_export_heads WHERE resource_key LIKE '%:row/settings/%'") {
            let fields = head.text(0).split(separator: ":", maxSplits: 1)
            guard fields.count == 2,
                  let body = try db.first("SELECT body FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?",
                                          [.text(String(fields[0])), .text(String(fields[1])), .text(head.text(1))])?.data(0),
                  let row = try? JSONDecoder().decode(CloudBrainMemoryRow.self, from: body), row.table == "settings", row.columns == t.columns else { continue }
            var values = try row.cells.map(DeckMemoryCloudSchema.sql)
            guard values[valueIndex] != .null, case .text(let owner) = values[0], case .text(let key) = values[1],
                  !DeckMemoryCloudSchema.isMachineLocalSetting(key) else { continue }
            if try db.first("SELECT 1 FROM main.settings WHERE owner=? AND key=?", [.text(owner), .text(key)]) != nil { continue }
            values[valueIndex] = .null; values[updatedIndex] = .real(now().timeIntervalSince1970)
            do { try cloudJournalRow(t, values: values) } catch { try cloudCountReconcileSkip(t.row) }
        }
    }

    /// M1: the connection's guard dropped capture (triggers gone, side database detached) after the side database made a
    /// memory write fail; the write itself was retried and succeeded. Capture is now off, the gap is recorded in the
    /// account folder (which needs no database), and coverage shows it until the heal and the reconcile have caught up.
    func cloudNoticeCaptureLoss() {
        guard let reason = db.takeCaptureLoss() else { return }
        cloudMemoryEnabled = false
        cloudCaptureLost = true
        if let state = cloudStateRoot {
            Self.cloudMarkGap(stateRoot: state)
            try? Data(("capture_lost: " + reason + "\n").utf8).write(to: state.appendingPathComponent("capture-problem"), options: .atomic)
        }
        try? db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('captureProblem','capture_lost')")
    }

    /// Capture comes back only when the account's own database is attached again and takes a write; triggers first,
    /// then a full reconcile (a dropped capture is one of the three reasons for one), so nothing is missed.
    func cloudHealCapture() throws -> Bool {
        guard cloudCaptureLost, let state = cloudStateRoot,
              FileManager.default.fileExists(atPath: state.appendingPathComponent("memory-cloud.db").path) else { return false }
        let attached = try cloudAttached()
        if !attached { try cloudAttach(stateRoot: state) }
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES ('healthProbe',?)", [.text(String(now().timeIntervalSince1970))])
        try cloudInstallCapture()
        cloudMemoryEnabled = true
        cloudCaptureLost = false
        try cloudStartReconcile(full: true)
        try db.run("DELETE FROM cloud_memory_control WHERE key='captureProblem' AND value='capture_lost'")
        try? FileManager.default.removeItem(at: state.appendingPathComponent("capture-problem"))
        return true
    }

    /// One bounded maintenance step, run by the journal pumps between drains (never inside a memory write):
    /// notice a dropped capture, heal it when possible, then advance the rows and files reconcile.
    /// Returns the amount of work done; 0 means idle (or waiting for the journal to drain, R1).
    func cloudMaintenanceStep(limit: Int = 64) throws -> Int {
        if db.captureLost != nil { cloudNoticeCaptureLoss() }
        if cloudCaptureLost { return (try? cloudHealCapture()) == true ? 1 : 0 }
        guard cloudMemoryEnabled else { return 0 }
        // The one rule first (settling second copies, sweeping after 30 days, cleanup times): before the reconcile, so
        // the reconcile never reads a half-settled copy.
        // A failure here never stops the reconcile or the queue; it is said once and tried again next step.
        var oneRule = 0
        do { oneRule = try cloudOneRuleStep(limit: 32) } catch { _ = CloudSyncDiagnostics.shared.report("memory one rule step", error) }
        let rows = try cloudReconcileRows(limit: max(1, limit) * 4)
        let files = try cloudReconcileFiles(limit: limit)
        let pending = try cloudReconcilePending()
        if rows == 0, files == 0, !pending, let state = cloudStateRoot {
            try? FileManager.default.removeItem(at: state.appendingPathComponent("capture-gap"))
        }
        return rows + files + oneRule
    }
}
