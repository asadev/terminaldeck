import Foundation
import TerminalDeckNativeCore

struct DeckMemoryCloudCursor: Sendable { var database = 0; var table = 0; var rowId: Int64 = Int64.min; var file = 0 }

extension DeckMemoryStore {
    /// From persisted running counts, never a re-read of the store (finding 11): the resources this account has exported
    /// for the row (`cloud_memory_export_heads`). Complete only after the row's cut finished, with nothing waiting in the
    /// journal, no dirty files and no capture problem. Local database backups are an intentional exclusion, not a gap.
    func cloudInventory(row: String) throws -> CloudSourceInventory {
        let sourceId = "memory/" + row, domain = CloudBrainMemoryFormat.domain(row)
        // MAC-NEXT-8: the live board stays on each device: nothing to hold, nothing missing, nothing to say on a page.
        if CloudBrainMemoryFormat.localOnlyRows.contains(row) {
            return .init(sourceId: sourceId, inventoryRow: row, domain: domain, items: 0, bytes: 0, complete: true, blockedReasons: [])
        }
        if cloudCaptureLost {
            // M1: memory itself is saved; Cloud catches up after the account database works again.
            return .init(sourceId: sourceId, inventoryRow: row, domain: domain, items: 0, bytes: 0, complete: false,
                         blockedReasons: ["Cloud capture paused after a problem with its own database. Your memory is saved; Cloud catches up when it works again."])
        }
        guard cloudMemoryEnabled, try cloudAttached() else {
            return .init(sourceId: sourceId, inventoryRow: row, domain: domain, items: 0, bytes: 0, complete: false, blockedReasons: ["Cloud memory capture is not on for this Mac."])
        }
        let counted = try db.first("SELECT COUNT(*),COALESCE(SUM(bytes),0) FROM cloud_memory_export_heads WHERE inventory=?", [.text(row)])
        var reasons: [String] = []
        if try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("cutComplete:" + row)]) == nil { reasons.append("The first saved copy is not finished.") }
        if try db.first("SELECT 1 FROM cloud_memory_journal WHERE inventory=? LIMIT 1", [.text(row)]) != nil { reasons.append("Changes are waiting to be saved.") }
        if try db.first("SELECT value FROM cloud_memory_control WHERE key='filesDirty'")?.text(0) == "1" { reasons.append("Changed files are being checked.") }
        if let problem = try db.first("SELECT value FROM cloud_memory_control WHERE key='captureProblem'")?.string(0) {
            reasons.append(problem.hasPrefix("schema_mismatch:") ? "This memory database has a layout Cloud cannot read yet." : "A local change still needs to be captured.")
        }
        if try db.first("SELECT 1 FROM cloud_memory_control WHERE key='rowsReconcile'") != nil { reasons.append("Changes made while Cloud capture was off are being checked.") }
        let skipped = try cloudReconcileSkipped(row)
        if skipped > 0 { reasons.append("\(skipped) memory record\(skipped == 1 ? "" : "s") could not be read for Cloud and \(skipped == 1 ? "is" : "are") not saved there.") }
        // Intentional exclusions are named, never gaps (SYNC contract addition).
        var exclusions: [String] = []
        switch row {
        case "I01": exclusions = try cloudSavedFileExclusions()
        case "I05": exclusions = DeckMemoryCloudSchema.unknownSettingNotes(try db.rows("SELECT DISTINCT key FROM main.settings").map { $0.text(0) })
        default: if let note = DeckMemoryCloudSchema.intentionalExclusions[row] { exclusions = [note] }
        }
        return .init(sourceId: sourceId, inventoryRow: row, domain: domain, items: Int(counted?.int(0) ?? 0), bytes: counted?.int(1) ?? 0,
                     complete: reasons.isEmpty, blockedReasons: reasons, exclusions: exclusions)
    }
    /// One resource of the cut per call, read through one reused read connection. Files must already be copied into the
    /// snapshot (the page reader does that off this actor); a file missing at copy time is skipped with a marker.
    func cloudSnapshotResource(_ snapshot: DeckMemoryCloudSnapshot, row: String, cursor: DeckMemoryCloudCursor) throws -> (DeckMemoryCloudResource?, DeckMemoryCloudCursor) {
        var cursor = cursor
        if cursor.database == 0 {
            let db = try cloudSnapshotReader(snapshot)
            let tables = DeckMemoryCloudSchema.travellingTables.filter { $0.row == row }
            while cursor.table < tables.count {
                let t = tables[cursor.table]
                let columns = Set(try db.rows("PRAGMA main.table_info(\(t.name))").map { $0.text(1) })
                if columns.isEmpty { cursor.table += 1; cursor.rowId = Int64.min; continue }
                guard Set(t.columns).isSubset(of: columns) else { throw CloudFailure.unsupportedFormat }
                let filter = t.name == "meta" ? " AND " + DeckMemoryCloudSchema.metaFilter : (t.name == "settings" ? " AND " + DeckMemoryCloudSchema.machineLocalSettingFilter : "")
                var found: DeckMemoryCloudResource?
                while found == nil, let r = try db.first("SELECT rowid,\(t.columns.joined(separator: ",")) FROM main.\(t.name) WHERE rowid>?\(filter) ORDER BY rowid LIMIT 1", [.int(cursor.rowId)]) {
                    cursor.rowId = r.int(0)
                    let values = Array(r.values.dropFirst())
                    // MAC-NEXT-7 (4): the VALUES come from the cut; the ORIGIN of each item (and the versions this Mac
                    // received) from the same source the later syncs read, this store's own attached Cloud tables. A
                    // copy that lacks them (an older cut, a copy taken before they were attached) never makes an item
                    // that arrived from another device look like this Mac's own.
                    let resource = try cloudLogicalRow(t, values: values, database: self.db, storeId: snapshot.storeId, sequence: snapshot.watermark, row: row)
                    // Y3: the first copy is this Mac's OWN memory; what arrived from the Cloud unchanged is not in it.
                    if try cloudIsEcho(resource, table: t, values: values, database: self.db, storeId: snapshot.storeId) { continue }
                    found = resource
                }
                if let found { return (found, cursor) }
                cursor.table += 1; cursor.rowId = Int64.min
            }
            cursor.database = 1; cursor.table = 0; cursor.rowId = Int64.min
        }
        while cursor.file < snapshot.files.count {
            let path = snapshot.files[cursor.file]; cursor.file += 1
            let file = snapshot.root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: file.path) else { continue } // removed before it was copied: its journal keeps the history
            if path.hasPrefix("prior-roots/") {
                guard row == "I06" else { continue }
                let hash = try cloudHashFile(file)
                let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                return (.init(sequence: snapshot.watermark, row: row, key: "file/archive/" + path, hash: hash, bytes: bytes, data: nil, file: file), cursor)
            }
            // MAC-NEXT-7 (4): origins from this store's own Cloud tables, as for rows; an arrived file unchanged here
            // is not this Mac's own either.
            guard try cloudFileInventoryRow(path, database: self.db) == row else { continue }
            let resource = try cloudLogicalFile(path: path, file: file, database: self.db, storeId: snapshot.storeId, sequence: snapshot.watermark)
            if try cloudIsEcho(resource, table: nil, values: nil, database: self.db, storeId: snapshot.storeId) { continue }
            return (resource, cursor)
        }
        return (nil, cursor)
    }
    /// Mac-next 2: how many resources the cut holds for `row` (the same tables, filters and files the pages walk), for the
    /// Cloud page's "Preparing the first copy: X of Y". Takes the cut itself when it is not taken yet (the pages would).
    func cloudSnapshotEstimate(id: String, destination: URL, row: String) throws -> Int {
        let snapshot = try cloudBeginSnapshot(id: id, destination: destination)
        let db = try cloudSnapshotReader(snapshot)
        var count = 0
        for t in DeckMemoryCloudSchema.travellingTables where t.row == row {
            if try db.rows("PRAGMA main.table_info(\(t.name))").isEmpty { continue }
            let filter = t.name == "meta" ? " AND " + DeckMemoryCloudSchema.metaFilter : (t.name == "settings" ? " AND " + DeckMemoryCloudSchema.machineLocalSettingFilter : "")
            count += Int(try db.first("SELECT COUNT(*) FROM main.\(t.name) WHERE 1\(filter)")?.int(0) ?? 0)
        }
        for path in snapshot.files {
            if path.hasPrefix("prior-roots/") { if row == "I06" { count += 1 }; continue }
            if try cloudFileInventoryRow(path, database: self.db) == row { count += 1 }
        }
        return count
    }
    /// A journal row's version is minted ONCE: a re-read of the same journal sequence (a crash between queueing and the
    /// cursor save) replays exactly that version and parents and never moves the head, so the re-sent operation is
    /// byte-identical. Snapshot pages pass no sequence (their resources are not journal rows).
    func cloudExportVersion(key: String, hash: String, baseVersion: String? = nil, row: String? = nil, bytes: Int64? = nil, sequence: Int64? = nil) throws -> (version: String, parents: [String]) {
        if let sequence,
           let saved = try db.first("SELECT version,parents FROM cloud_memory_seq_versions WHERE seq=? AND resource_key=?", [.int(sequence), .text(key)]) {
            return (saved.text(0), try JSONDecoder().decode([String].self, from: saved.data(1) ?? Data()))
        }
        let minted = try cloudExportVersionFromHead(key: key, hash: hash, baseVersion: baseVersion, row: row, bytes: bytes, made: sequence != nil)
        if let sequence {
            try db.run("INSERT OR IGNORE INTO cloud_memory_seq_versions(seq,resource_key,inventory,version,parents) VALUES (?,?,?,?,?)",
                       [.int(sequence), .text(key), .optional(row), .text(minted.version), .blob(try CloudWire.canonical(minted.parents))])
        }
        return minted
    }
    /// The export head's version was received from another device (its stamp says own=0). Head keys are "<store>:<key>".
    private func cloudHeadIsReceived(key: String, version: String) throws -> Bool {
        guard let colon = key.firstIndex(of: ":") else { return false }
        let plain = String(key[key.index(after: colon)...])
        return try db.first("SELECT 1 FROM \(try cloudStampTable()) WHERE resource_key=? AND revision=? AND own=0", [.text(plain), .text(version)]) != nil
    }
    private func cloudExportVersionFromHead(key: String, hash: String, baseVersion: String?, row: String?, bytes: Int64?, made: Bool = false) throws -> (version: String, parents: [String]) {
        defer {
            // Running counts for the inventory (finding 11): what this account holds per row, updated as resources export.
            if row != nil || bytes != nil { try? db.run("UPDATE cloud_memory_export_heads SET inventory=COALESCE(?,inventory),bytes=COALESCE(?,bytes) WHERE resource_key=?", [.optional(row),.optional(bytes.map { Int($0) }),.text(key)]) }
        }
        if let r = try db.first("SELECT hash,version,parents,base_version FROM cloud_memory_export_heads WHERE resource_key=?", [.text(key)]) {
            // MAC-NEXT-8b: a journal row is a change made HERE. When its bytes equal a head this Mac RECEIVED (a record
            // removed here and made again with the same content), it is still this Mac's own new version, descending
            // from the received one: never a re-send of the other Mac's version under this Mac's name.
            if r.text(0) == hash, made, try cloudHeadIsReceived(key: key, version: r.text(1)) {
                let parents = [r.text(1)], version = BackendCloudBrainMemoryHash.uuid(parents[0] + "\n" + hash + "\nmade-here")
                try db.run("UPDATE cloud_memory_export_heads SET version=?,parents=?,base_version=? WHERE resource_key=?", [.text(version),.blob(try CloudWire.canonical(parents)),.optional(baseVersion),.text(key)])
                return (version, parents)
            }
            if r.text(0) == hash {
                if let baseVersion, baseVersion != r.text(1), let incoming = try db.first("SELECT content_hash,parents FROM cloud_memory_versions WHERE revision=? LIMIT 1", [.text(baseVersion)]), incoming.text(0) == hash {
                    let parents = try JSONDecoder().decode([String].self, from: incoming.data(1) ?? Data())
                    try db.run("UPDATE cloud_memory_export_heads SET version=?,parents=?,base_version=? WHERE resource_key=?", [.text(baseVersion),.blob(try CloudWire.canonical(parents)),.text(baseVersion),.text(key)])
                    return (baseVersion, parents)
                }
                return (r.text(1), try JSONDecoder().decode([String].self, from: r.data(2) ?? Data()))
            }
            let parents = [baseVersion != nil && r.string(3) != baseVersion ? baseVersion! : r.text(1)], version = BackendCloudBrainMemoryHash.uuid(parents[0] + "\n" + hash)
            try db.run("UPDATE cloud_memory_export_heads SET hash=?,version=?,parents=?,base_version=? WHERE resource_key=?", [.text(hash),.text(version),.blob(try CloudWire.canonical(parents)),.optional(baseVersion),.text(key)])
            return (version, parents)
        }
        var parents: [String] = baseVersion.map { [$0] } ?? []
        var version = BackendCloudBrainMemoryHash.uuid((baseVersion ?? key) + "\n" + hash)
        if let baseVersion, let previous = try db.first("SELECT content_hash,parents FROM cloud_memory_versions WHERE revision=? LIMIT 1", [.text(baseVersion)]), previous.text(0) == hash {
            version = baseVersion; parents = try JSONDecoder().decode([String].self, from: previous.data(1) ?? Data())
        }
        try db.run("INSERT INTO cloud_memory_export_heads(resource_key,hash,version,parents,base_version) VALUES (?,?,?,?,?)", [.text(key),.text(hash),.text(version),.blob(try CloudWire.canonical(parents)),.optional(baseVersion)])
        return (version, parents)
    }
}
