import Foundation
import TerminalDeckNativeCore

extension DeckMemoryStore {
    /// Export physical ids as global source identities; imported ids never become unrelated new messages.
    func cloudLogicalRow(_ t: DeckMemoryCloudSchema.Table, values: [DeckMemorySQL], database: DeckMemoryDatabase,
                         storeId: String, sequence: Int64, row: String, baseVersion: String? = nil) throws -> DeckMemoryCloudResource {
        let enabled = try Self.cloudHasTable(database, "cloud_memory_origins")
        let nativeKey = try DeckMemoryCloudSchema.nativeKey(t, values)
        let origin = enabled ? try database.first("SELECT store_id,resource_key,original_keys,version FROM cloud_memory_origins WHERE table_name=? AND native_key=?", [.text(t.name),.text(nativeKey)]) : nil
        let sourceId = origin?.text(0) ?? storeId
        var logical = values, references: [String:CloudBrainMemoryReference] = [:]
        if let origin, let version = origin.string(3),
           let saved = try database.first("SELECT body,projection FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?", [.text(origin.text(0)),.text(origin.text(1)),.text(version)]),
           let raw = saved.data(0), let projection = saved.string(1),
           let original = try? JSONDecoder().decode(CloudBrainMemoryRow.self, from: raw),
           let mapped = try? JSONDecoder().decode(CloudBrainMemoryRow.self, from: Data(projection.utf8)),
           original.columns == t.columns, mapped.columns == t.columns {
            for i in values.indices where values[i] == (try DeckMemoryCloudSchema.sql(mapped.cells[i])) { logical[i] = try DeckMemoryCloudSchema.sql(original.cells[i]) }
        }
        if let encoded = origin?.data(2) {
            let keys = try JSONDecoder().decode([CloudBrainMemoryCell].self, from: encoded)
            guard keys.count == t.keys.count else { throw CloudFailure.invalidRequest }
            for (i,key) in t.keys.enumerated() { logical[t.columns.firstIndex(of: key)!] = try DeckMemoryCloudSchema.sql(keys[i]) }
        }
        for (column,target) in DeckMemoryCloudSchema.referenceColumns(t.name) {
            guard let i = t.columns.firstIndex(of: column), values[i] != .null else { continue }
            if t.name == "rewinds", column == "after_row", values[i] == .int(0) { continue }
            let key = String(decoding: try CloudWire.canonical([DeckMemoryCloudSchema.cell(values[i])]), as: UTF8.self)
            let targetOrigin = enabled ? try database.first("SELECT store_id,original_keys FROM cloud_memory_origins WHERE table_name=? AND native_key=?", [.text(target),.text(key)]) : nil
            let id: CloudBrainMemoryCell
            if let keys = targetOrigin?.data(1) { id = try JSONDecoder().decode([CloudBrainMemoryCell].self, from: keys)[0] }
            else { id = DeckMemoryCloudSchema.cell(values[i]) }
            references[column] = .init(storeId: targetOrigin?.text(0) ?? storeId, table: target, id: id)
            logical[i] = try DeckMemoryCloudSchema.sql(id)
        }
        if let i = t.columns.firstIndex(of: "path"), case .text(let path) = values[i] {
            let fileOrigin = enabled ? try database.first("SELECT store_id,resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(path)]) : nil
            let relative = fileOrigin.map { String($0.text(1).dropFirst(5)) } ?? path
            references["path"] = .init(storeId: fileOrigin?.text(0) ?? storeId, table: "file", id: .init(type: "text", value: relative))
            logical[i] = .text(relative)
        }
        let bytes = try CloudWire.canonical(CloudBrainMemoryRow(table: t.name, columns: t.columns, cells: logical.map(DeckMemoryCloudSchema.cell), references: references))
        let originalKey = try DeckMemoryCloudSchema.key(t, logical)
        return .init(sequence: sequence, row: row, key: origin?.text(1) ?? originalKey, hash: DeckMemoryFiles.hash(bytes), bytes: Int64(bytes.count), data: bytes, file: nil,
                     originStoreId: sourceId, baseVersion: baseVersion ?? origin?.string(3), physicalRow: try DeckMemoryCloudSchema.encodeRow(t, values))
    }
    /// Tables whose rows are labels re-derived from one memory file's front matter on every save and every index.
    static let cloudFileLabelTables: Set<String> = ["notes", "topics", "files", "handoffs"]
    /// Y3 (13 Nov, the echo): what arrived from the Cloud is never sent back by the Mac that received it unless the
    /// person or an agent on THIS Mac changed it afterwards. Proven on the joining MacBook: right after its merge it
    /// sent 439 records, 250 of pack 405's 251 with resource keys the Mac mini already had, under the MacBook's own
    /// store id. Two sources:
    /// 1. A label row of a file that ARRIVED (its path's file origin is another store). Placing the file re-indexes it,
    ///    which writes the label row with no origin of its own, so it was exported as this Mac's own new note (same
    ///    note id, new store and file reference: the Mac mini then refused the pack with `idReused`). The labels are
    ///    re-derived from the file on every Mac, and a real edit here changes the FILE, which travels under its own
    ///    origin; the label row itself is never this Mac's to send.
    /// 2. A row or file whose origin is another store and whose rebuilt value is exactly the version this Mac applied
    ///    (its export head, written at import, R5): nothing changed here.
    func cloudIsEcho(_ resource: DeckMemoryCloudResource, table t: DeckMemoryCloudSchema.Table?, values: [DeckMemorySQL]?,
                     database: DeckMemoryDatabase, storeId: String) throws -> Bool {
        if let t, let values, Self.cloudFileLabelTables.contains(t.name), let i = t.columns.firstIndex(of: "path"), case .text(let path) = values[i],
           try Self.cloudHasTable(database, "cloud_memory_file_origins"),
           let owner = try database.first("SELECT store_id FROM cloud_memory_file_origins WHERE path=?", [.text(path)])?.string(0), owner != storeId {
            return true
        }
        // Parked memory (14 Nov): a label row that arrived under one file's record but stands here at another place (a
        // second copy, `archive/cloud-conflicts/...`, whose file origin the one-rule settling removed with the copy)
        // rebuilds to a row whose record name and content disagree; every other Mac refuses it. It is this Mac's index
        // of a file that is gone, not a change of his: never sent.
        if let t, Self.cloudFileLabelTables.contains(t.name), resource.key.hasPrefix("row/"), let data = resource.data,
           let decoded = try? DeckMemoryCloudSchema.decodeRow(data), (try? DeckMemoryCloudSchema.key(t, decoded.1)) != resource.key {
            return true
        }
        guard let origin = resource.originStoreId, origin != storeId, try Self.cloudHasTable(database, "cloud_memory_versions"),
              try Self.cloudHasTable(database, "cloud_memory_stamps") else { return false }
        // MAC-NEXT-8b (review of MAC-NEXT-8): decided by IDENTITY, not by content. The version THIS physical row or file
        // stands at here (its origin's registered version: set when an import placed it, moved to this Mac's own
        // version when this Mac sent an edit, cleared when it was deleted here) must be one this Mac RECEIVED (stamp
        // own=0), and the bytes must still be exactly that version's: nothing was done here since. Any version this Mac
        // made goes, whatever its content (A received, B made, A made again: A goes; deleted then made again: it goes).
        // This also stops, at the queue, a kept older version (a "kept both" sibling row holds an older received version
        // under the same record) from going out as this Mac's own: it stands at its own received version.
        let registered: String?
        if let t, let values {
            guard try Self.cloudHasTable(database, "cloud_memory_origins") else { return false }
            registered = try database.first("SELECT version FROM cloud_memory_origins WHERE table_name=? AND native_key=? AND store_id=?",
                                            [.text(t.name), .text(try DeckMemoryCloudSchema.nativeKey(t, values)), .text(origin)])?.string(0)
        } else if let path = resource.projectionPath, try Self.cloudHasTable(database, "cloud_memory_file_origins") {
            registered = try database.first("SELECT version FROM cloud_memory_file_origins WHERE path=? AND store_id=?", [.text(path), .text(origin)])?.string(0)
        } else { registered = nil }
        guard let registered, !registered.isEmpty else { return false }
        return try database.first("""
            SELECT 1 FROM cloud_memory_versions v JOIN cloud_memory_stamps s ON s.resource_key=v.resource_key AND s.revision=v.revision AND s.own=0
            WHERE v.store_id=? AND v.resource_key=? AND v.revision=? AND v.content_hash=? LIMIT 1
            """, [.text(origin), .text(resource.key), .text(registered), .text(resource.hash)]) != nil
    }
    /// MAC-NEXT-7 (C), the one note that bounced once each way (13 Nov, "Local workbench lessons 2026-11-11 + session
    /// checkpoint"): a note placed from the Cloud without a helper-made short title was titled by THIS Mac's short-title
    /// helper seconds later, which rewrote its file, and the rewrite travelled as this Mac's edit; the other Mac's
    /// helper did the same. Notes whose file arrived from another store are left to the device that wrote them.
    public func cloudArrivedNoteIDs(_ ids: [String]) async -> Set<String> {
        guard cloudMemoryEnabled, (try? cloudAttached()) == true, !ids.isEmpty, let own = try? cloudStoreId(),
              (try? Self.cloudHasTable(db, "cloud_memory_file_origins")) == true else { return [] }
        var arrived: Set<String> = []
        for id in ids {
            guard let path = (try? noteRow(id))?.string(1),
                  let owner = (try? db.first("SELECT store_id FROM cloud_memory_file_origins WHERE path=?", [.text(path)]))?.string(0),
                  owner != own else { continue }
            arrived.insert(id)
        }
        return arrived
    }
    func cloudFileInventoryRow(_ path: String, database: DeckMemoryDatabase) throws -> String? {
        if try Self.cloudHasTable(database, "cloud_memory_file_origins"),
           let origin = try database.first("SELECT resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(path)])?.string(0),
           origin.hasPrefix("file/") {
            return DeckMemoryCloudSchema.fileRow(String(origin.dropFirst(5)))
        }
        return DeckMemoryCloudSchema.fileRow(path)
    }
    func cloudLogicalFile(path: String, file: URL, database: DeckMemoryDatabase, storeId: String, sequence: Int64) throws -> DeckMemoryCloudResource {
        let enabled = try Self.cloudHasTable(database, "cloud_memory_file_origins")
        let found = enabled ? try database.first("SELECT store_id,resource_key,version FROM cloud_memory_file_origins WHERE path=?", [.text(path)]) : nil
        // Retained database backups no longer travel (Decker, finding 8/21); an old origin of that kind is ignored.
        let origin = found.flatMap { $0.text(1).hasPrefix("file/") ? $0 : nil }
        var logical = file, hash = try cloudHashFile(file)
        let physicalHash = hash
        if let origin, let version = try database.first("SELECT content_hash,projected_hash FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?", [.text(origin.text(0)),.text(origin.text(1)),.text(origin.text(2))]), version.text(1) == hash {
            logical = try cloudIncomingFolder().appendingPathComponent(origin.text(0) + "/" + version.text(0))
            guard try cloudHashFile(logical) == version.text(0) else { throw CloudFailure.checksumMismatch }; hash = version.text(0)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: logical.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard let row = DeckMemoryCloudSchema.fileRow(origin.map { String($0.text(1).dropFirst(5)) } ?? path) else { throw CloudFailure.invalidRequest }
        return .init(sequence: sequence, row: row, key: origin?.text(1) ?? "file/" + path, hash: hash, bytes: size, data: nil, file: logical,
                     originStoreId: origin?.text(0) ?? storeId, baseVersion: origin?.text(2), projectionPath: path, physicalHash: physicalHash)
    }
    func cloudRecordExport(_ resource: DeckMemoryCloudResource, storeId: String, version: String, parents: [String]) throws {
        guard try db.first("SELECT 1 FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?", [.text(storeId),.text(resource.key),.text(version)]) == nil else { return }
        let p = CloudBrainMemoryPart(storeId: storeId, inventoryRow: resource.row, key: resource.key, version: version, resourceHash: resource.hash, bytes: String(resource.bytes), index: 0, count: 1, parents: parents, data: "")
        let original: Data
        let projection: String?
        if resource.key.hasPrefix("file/"), let file = resource.file {
            let raw = try cloudIncomingFolder().appendingPathComponent(storeId + "/" + resource.hash)
            try FileManager.default.createDirectory(at: raw.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: raw.path) { try FileManager.default.copyItem(at: file, to: raw); try BackendCloudBrainMemoryHash.synchronize(raw) }
            guard try cloudHashFile(raw) == resource.hash else { throw CloudFailure.checksumMismatch }
            original = Data(); projection = resource.projectionPath
            if let projection {
                try db.run("INSERT INTO cloud_memory_file_origins(path,store_id,resource_key,version) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET version=excluded.version", [.text(projection),.text(storeId),.text(resource.key),.text(version)])
            }
        } else {
            guard let data = resource.data else { throw CloudFailure.invalidRequest }
            original = data
            projection = resource.physicalRow.map { String(decoding: $0, as: UTF8.self) }
            if let physical = resource.physicalRow {
                let (t, projected) = try DeckMemoryCloudSchema.decodeRow(physical), (_, logical) = try DeckMemoryCloudSchema.decodeRow(data)
                try cloudRegisterRowOrigin(p, t: t, original: logical, projected: projected)
            }
        }
        try db.run("INSERT INTO cloud_memory_versions(store_id,resource_key,revision,content_hash,inventory,body,projection,projected_hash,parents) VALUES (?,?,?,?,?,?,?,?,?)", [.text(storeId),.text(resource.key),.text(version),.text(resource.hash),.text(resource.row),.blob(original),.optional(projection),.optional(resource.physicalHash),.blob(try CloudWire.canonical(parents))])
    }
    /// Works whether the Cloud tables live in `main` (older stores) or in the attached per-account database.
    static func cloudHasTable(_ database: DeckMemoryDatabase, _ name: String) throws -> Bool {
        try database.first("SELECT 1 FROM pragma_table_list WHERE name=?", [.text(name)]) != nil
    }
    func cloudRegisterRowOrigin(_ p: CloudBrainMemoryPart, t: DeckMemoryCloudSchema.Table, original: [DeckMemorySQL], projected: [DeckMemorySQL]) throws {
        let originalKeys = t.keys.map { DeckMemoryCloudSchema.cell(original[t.columns.firstIndex(of: $0)!]) }
        let native = try DeckMemoryCloudSchema.nativeKey(t, projected)
        if let existing = try db.first("SELECT store_id,resource_key FROM cloud_memory_origins WHERE table_name=? AND native_key=?", [.text(t.name),.text(native)]) {
            if existing.text(0) != p.storeId || existing.text(1) != p.key {
                if t.integerKey || t.name == "board" { throw CloudFailure.idReused }
                // A natural-key preference may be identical in two initial sources. Its logical versions remain distinct.
                return
            }
        }
        try db.run("INSERT INTO cloud_memory_origins(table_name,native_key,store_id,resource_key,original_keys,version) VALUES (?,?,?,?,?,?) ON CONFLICT(table_name,native_key) DO UPDATE SET version=excluded.version",
                   [.text(t.name),.text(native),.text(p.storeId),.text(p.key),.blob(try CloudWire.canonical(originalKeys)),.text(p.version)])
    }
    func cloudAllocateInteger(_ table: String) throws -> Int64 {
        let schema = try DeckMemoryCloudSchema.table(table)
        guard schema.integerKey else { throw CloudFailure.invalidRequest }
        let existing = try db.first("SELECT COALESCE(MAX(id),0) FROM \(table)")?.int(0) ?? 0
        let sequence = try db.first("SELECT seq FROM sqlite_sequence WHERE name=?", [.text(table)])?.int(0) ?? 0
        let maximum = max(existing, sequence)
        guard maximum < Int64.max else { throw CloudFailure.unavailable }
        let next = maximum + 1
        // Reserve foreign ids as well: the existing AUTOINCREMENT writer must not allocate them before their rows arrive.
        if try db.first("SELECT 1 FROM sqlite_sequence WHERE name=?", [.text(table)]) != nil {
            try db.run("UPDATE sqlite_sequence SET seq=? WHERE name=?", [.int(next),.text(table)])
        } else { try db.run("INSERT INTO sqlite_sequence(name,seq) VALUES (?,?)", [.text(table),.int(next)]) }
        return next
    }
    func cloudRewindBelongsToAnotherStore(_ id: Int64) throws -> Bool {
        guard cloudMemoryEnabled else { return false }
        let key = String(decoding: try CloudWire.canonical([CloudBrainMemoryCell(type: "integer", value: String(id))]), as: UTF8.self)
        if let source = try db.first("SELECT store_id FROM cloud_memory_origins WHERE table_name='rewinds' AND native_key=?", [.text(key)])?.string(0) {
            return source != (try cloudStoreId())
        }
        return false
    }
    func cloudResolveReference(_ reference: CloudBrainMemoryReference) throws -> DeckMemorySQL {
        guard UUID(uuidString: reference.storeId) != nil else { throw CloudFailure.invalidRequest }
        let t = try DeckMemoryCloudSchema.table(reference.table), original = try DeckMemoryCloudSchema.sql(reference.id)
        guard t.keys == ["id"] else { throw CloudFailure.unsupportedFormat }
        let originalKeys = try CloudWire.canonical([reference.id])
        let resourceKey = "row/" + t.name + "/" + DeckMemoryFiles.hash(originalKeys)
        if let existing = try db.first("SELECT native_key FROM cloud_memory_origins WHERE table_name=? AND store_id=? AND resource_key=? ORDER BY rowid DESC LIMIT 1", [.text(t.name),.text(reference.storeId),.text(resourceKey)])?.string(0) {
            let keys = try JSONDecoder().decode([CloudBrainMemoryCell].self, from: Data(existing.utf8))
            guard keys.count == 1 else { throw CloudFailure.invalidRequest }
            return try DeckMemoryCloudSchema.sql(keys[0])
        }
        let projected: DeckMemorySQL
        if reference.storeId == (try cloudStoreId()) { projected = original }
        else if case .int = original { projected = .int(try cloudAllocateInteger(t.name)) }
        else if case .text(let id) = original {
            // Board ids are machine-local session ids; globally unique note ids remain readable through their origin map.
            projected = .text(t.name == "board" ? "cloud:" + reference.storeId + ":" + id : id)
        } else { throw CloudFailure.invalidRequest }
        let native = String(decoding: try CloudWire.canonical([DeckMemoryCloudSchema.cell(projected)]), as: UTF8.self)
        if let existing = try db.first("SELECT store_id,resource_key FROM cloud_memory_origins WHERE table_name=? AND native_key=?", [.text(t.name),.text(native)]) {
            // Y1/Y3 (13 Nov): a note id is one global id (made once, on one Mac). The same text id already known here
            // under another store (this Mac had re-captured an arrived note as its own, or two Macs sent the same
            // note) is the SAME note, not a clash: the reference points at it. Before, this threw `idReused`, which
            // rolled back a whole release batch on the joining Mac and refused the other Mac's packs.
            if existing.text(0) != reference.storeId || existing.text(1) != resourceKey {
                guard case .text = original, t.name != "board", existing.text(1) == resourceKey else { throw CloudFailure.idReused }
            }
        } else {
            try db.run("INSERT INTO cloud_memory_origins(table_name,native_key,store_id,resource_key,original_keys) VALUES (?,?,?,?,?)", [.text(t.name),.text(native),.text(reference.storeId),.text(resourceKey),.blob(originalKeys)])
        }
        return projected
    }
}
