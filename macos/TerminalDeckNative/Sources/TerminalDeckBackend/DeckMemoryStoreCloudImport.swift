import Foundation
import TerminalDeckNativeCore

extension DeckMemoryStore {
    func cloudValidatePart(_ op: CloudOperation, row: String) throws -> CloudBrainMemoryPart {
        guard op.v == 1, op.domain == CloudBrainMemoryFormat.domain(row), op.kind == .put,
              UUID(uuidString: op.opId) != nil, UUID(uuidString: op.originDevice) != nil,
              DeckMemoryFiles.hash(try CloudWire.canonical(op.payload)) == op.payloadHash else { throw CloudFailure.checksumMismatch }
        let data = try CloudWire.canonical(op.payload)
        let p = try CloudWire.decode(CloudBrainMemoryPart.self, from: data,
                                    allowedKeys: ["format","storeId","inventoryRow","key","version","resourceHash","bytes","index","count","parents","data","stamp","baseline"])
        guard p.format == "td-memory-part-1", p.inventoryRow == row, UUID(uuidString: p.storeId) != nil,
              let size = Int64(p.bytes), size >= 0, size <= Int64(Int.max - CloudBrainMemoryFormat.partBytes), String(size) == p.bytes,
              UUID(uuidString: p.version) != nil,
              p.count == max(1, Int((size + Int64(CloudBrainMemoryFormat.partBytes) - 1) / Int64(CloudBrainMemoryFormat.partBytes))),
              p.index >= 0, p.index < p.count, p.resourceHash.count == 64,
              p.resourceHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              p.parents.count <= 2, p.parents.allSatisfy({ UUID(uuidString: $0) != nil && $0 != p.version }),
              let bytes = Data(base64Encoded: p.data), bytes.base64EncodedString() == p.data,
              bytes.count == Int(min(Int64(CloudBrainMemoryFormat.partBytes), size - Int64(p.index * CloudBrainMemoryFormat.partBytes))),
              op.opId == op.revision, p.stamp.map({ Int64($0) != nil && String(Int64($0)!) == $0 }) ?? true,
              Self.cloudOperationLinksValid(op, p),
              op.source.sourceId == "memory/" + row, op.source.recordId == p.key,
              op.source.offset == Int64(p.index * CloudBrainMemoryFormat.partBytes), op.source.rawHash == p.resourceHash,
              op.entityId == BackendCloudBrainMemoryHash.uuid(p.storeId + "\n" + p.key + "\n" + String(p.index)) else { throw CloudFailure.invalidRequest }
        if p.key.hasPrefix("file/") {
            let path = String(p.key.dropFirst(5))
            _ = try DeckMemoryCloudSchema.safePath(path, root: root)
            // M6: the app's own help files are written by every Mac itself; an incoming one is ignored, never refused.
            if Self.cloudIsAppOwnedFile(path) { return p }
            guard DeckMemoryCloudSchema.fileRow(path) == row,
                  !(path.hasPrefix("archive/backups/") && path.hasSuffix(".db")) else { throw CloudFailure.unsupportedFormat }
        } else if p.key.hasPrefix("row/") {
            let parts = p.key.split(separator: "/")
            guard parts.count == 3, try DeckMemoryCloudSchema.table(String(parts[1])).row == row else { throw CloudFailure.invalidRequest }
        } else if p.key.hasPrefix("backup/"), row == "I06" {
            guard !p.key.contains(".."), p.key.contains("/row/") else { throw CloudFailure.invalidRequest }
        } else { throw CloudFailure.unsupportedFormat }
        return p
    }
    /// Two id forms are valid (record-id rule in DeckMemoryStoreCloudExport.swift): the older `uuid(version \n index)` with
    /// parents derived from the parent versions, and the current `uuid(version \n index \n originDevice)` whose parents are
    /// the real operation ids of the parent versions' parts (at most one per parent version, never itself).
    static func cloudOperationLinksValid(_ op: CloudOperation, _ p: CloudBrainMemoryPart) -> Bool {
        if op.revision == BackendCloudBrainMemoryHash.uuid(p.version + "\n" + String(p.index)) {
            return op.parents == p.parents.map { BackendCloudBrainMemoryHash.uuid($0 + "\n" + String(p.index)) }
        }
        guard op.revision == cloudOperationId(version: p.version, index: p.index, device: op.originDevice) else { return false }
        return op.parents.count <= p.parents.count && Set(op.parents).count == op.parents.count
            && op.parents.allSatisfy { UUID(uuidString: $0) != nil && $0 != op.revision }
    }
    /// Staging/receipts live inside the existing memory database transaction; no second memory writer exists.
    func cloudApply(_ prepared: CloudPreparedImport, row: String, origin: CloudImportOrigin) throws -> CloudImportReceipt {
        guard cloudMemoryEnabled else { throw CloudFailure.unavailable }
        if let saved = try db.first("SELECT body FROM cloud_memory_receipts WHERE id=?", [.text(prepared.preparationId)])?.data(0) {
            return try JSONDecoder().decode(CloudImportReceipt.self, from: saved)
        }
        let parts = try prepared.operations.map { try cloudValidatePart($0, row: row) }
        let fingerprints = try prepared.operations.map { DeckMemoryFiles.hash(try CloudWire.canonical($0)) }
        var results: [CloudItemResult] = [], files = 0, records = 0, bytes: Int64 = 0
        try db.transaction {
            try db.run("UPDATE cloud_memory_control SET value='1' WHERE key='importing'")
            defer { try? db.run("UPDATE cloud_memory_control SET value='0' WHERE key='importing'") }
            for (i, op) in prepared.operations.enumerated() {
                let p = parts[i]
                // Retained memory.db backups are local safety copies and never travel (Decker, findings 8/21):
                // an incoming one from an older build stages nothing, writes nothing and does not block the batch.
                // MAC-NEXT-8: another Mac's live board (older builds still send it) is acknowledged and ignored.
                if DeckMemoryCloudSchema.isLocalOnlyKey(p.key) {
                    results.append(.init(entityId: op.entityId, status: .alreadyPresent, reason: Self.cloudLocalOnlyIgnored)); continue
                }
                if p.key.hasPrefix("backup/") {
                    results.append(.init(entityId: op.entityId, status: .alreadyPresent, reason: Self.cloudBackupExcluded)); continue
                }
                if p.key.hasPrefix("file/"), Self.cloudIsAppOwnedFile(String(p.key.dropFirst(5))) {
                    results.append(.init(entityId: op.entityId, status: .alreadyPresent, reason: Self.cloudAppOwnedExcluded)); continue
                }
                if let r = try db.first("SELECT op_hash FROM cloud_memory_parts WHERE op_id=?", [.text(op.opId)]) {
                    guard r.text(0) == fingerprints[i] else { throw CloudFailure.idReused }
                    results.append(.init(entityId: op.entityId, status: .alreadyPresent)); continue
                }
                if let same = try db.first("SELECT body,total,bytes,parents,content_hash FROM cloud_memory_parts WHERE store_id=? AND resource_key=? AND revision=? AND part=?", [.text(p.storeId),.text(p.key),.text(p.version),.int(Int64(p.index))]) {
                    guard same.data(0) == Data(base64Encoded: p.data), same.int(1) == p.count, same.int(2) == Int64(p.bytes), same.data(3) == (try CloudWire.canonical(p.parents)), same.text(4) == p.resourceHash else { throw CloudFailure.idReused }
                    // A re-registered device may replay the same logical part with its own signed provenance.
                }
                if p.index == 0 {
                    // M4b: the stamp travels inside the revision (older parts: their build time); the server's sequence breaks ties.
                    let stamp = p.stamp.flatMap { Int64($0) } ?? op.createdAt
                    try cloudRecordStamp(key: p.key, version: p.version, stamp: stamp, baseline: p.baseline ?? false, sequence: origin.sequence, own: false,
                                         committedAt: origin.committedAt)
                }
                try db.run("INSERT INTO cloud_memory_parts(op_id,op_hash,operation,entity_id,parents,store_id,inventory,resource_key,revision,content_hash,part,total,bytes,body) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                           [.text(op.opId),.text(fingerprints[i]),.blob(try CloudWire.canonical(op)),.text(op.entityId),.blob(try CloudWire.canonical(p.parents)),.text(p.storeId),.text(row),.text(p.key),.text(p.version),.text(p.resourceHash),.int(Int64(p.index)),.int(Int64(p.count)),.int(Int64(p.bytes)!),.blob(Data(base64Encoded: p.data)!)])
                let total = try db.first("SELECT COUNT(DISTINCT part) FROM cloud_memory_parts WHERE store_id=? AND resource_key=? AND revision=?", [.text(p.storeId),.text(p.key),.text(p.version)])?.int(0) ?? 0
                if total == p.count {
                    if try db.first("SELECT 1 FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?", [.text(p.storeId),.text(p.key),.text(p.version)]) != nil {
                        results.append(.init(entityId: op.entityId, status: .alreadyPresent)); continue
                    }
                    let assembled = try cloudAssemble(p)
                    let status: CloudApplyStatus
                    if p.key.hasPrefix("file/") {
                        status = try cloudProjectFile(p, from: assembled)
                        try cloudReconcileLabels(storeId: p.storeId, path: String(p.key.dropFirst(5)))
                        files += 1
                    } else {
                        status = try cloudProjectRow(p, from: assembled); records += 1
                    }
                    bytes += Int64(p.bytes)!
                    // Finding 26: retained here, counted as waiting until the project list confirms its project.
                    let waiting = try cloudIsWaiting(p)
                    results.append(.init(entityId: op.entityId, status: status, reason: waiting ? Self.cloudWaitingProject : nil))
                } else {
                    // This acknowledges durable staging only. Coverage/context remain incomplete until all parts arrive.
                    results.append(.init(entityId: op.entityId, status: .applied, reason: "part_saved"))
                }
            }
            // M4: values kept while this Mac's own edit had no revision yet are decided now by the same rule.
            try cloudSettlePendingMerges()
            let receipt = CloudImportReceipt(preparationId: prepared.preparationId, inventoryRow: row, results: results,
                                             counts: .init(domains: 1, records: records, files: files, bytes: bytes, blocked: 0))
            for (ordinal, op) in prepared.operations.enumerated() {
                try db.run("INSERT INTO cloud_memory_receipt_ops(preparation,ordinal,op_id) VALUES (?,?,?)", [.text(prepared.preparationId),.int(Int64(ordinal)),.text(op.opId)])
            }
            let encoded = try CloudWire.canonical(receipt)
            if let old = try db.first("SELECT body FROM cloud_memory_receipts WHERE id=?", [.text(prepared.preparationId)])?.data(0) {
                // A retry can return different per-part 'already present' statuses, but the original receipt is authoritative.
                let saved = try JSONDecoder().decode(CloudImportReceipt.self, from: old)
                guard saved.inventoryRow == row, saved.results.map(\.entityId) == results.map(\.entityId) else { throw CloudFailure.idReused }
            } else { try db.run("INSERT INTO cloud_memory_receipts(id,body) VALUES (?,?)", [.text(prepared.preparationId),.blob(encoded)]) }
        }
        noteFiles.removeAll()
        hub.post(.init(area: .index, at: now()))
        let saved = try db.first("SELECT body FROM cloud_memory_receipts WHERE id=?", [.text(prepared.preparationId)])!.data(0)!
        return try JSONDecoder().decode(CloudImportReceipt.self, from: saved)
    }
    static let cloudBackupExcluded = "local_database_backup_kept_on_this_mac"
    static let cloudLocalOnlyIgnored = "live_board_stays_on_each_mac"
    func cloudAssemble(_ p: CloudBrainMemoryPart) throws -> URL {
        let destination = try cloudIncomingFolder().appendingPathComponent(p.storeId + "/" + p.resourceHash)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            guard try cloudHashFile(destination) == p.resourceHash else { throw CloudFailure.checksumMismatch }; return destination
        }
        let temporary = destination.appendingPathExtension(UUID().uuidString + ".partial")
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw CloudFailure.unavailable }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            var size: Int64 = 0
            for i in 0..<p.count {
                guard let r = try db.first("SELECT body,total,bytes,parents,content_hash FROM cloud_memory_parts WHERE store_id=? AND resource_key=? AND revision=? AND part=?", [.text(p.storeId),.text(p.key),.text(p.version),.int(Int64(i))]),
                      r.int(1) == p.count, r.int(2) == Int64(p.bytes), r.data(3) == (try CloudWire.canonical(p.parents)), r.text(4) == p.resourceHash, let part = r.data(0) else { throw CloudFailure.invalidRequest }
                try handle.write(contentsOf: part); size += Int64(part.count)
            }
            try handle.synchronize(); try handle.close()
            guard size == Int64(p.bytes), try cloudHashFile(temporary) == p.resourceHash else { throw CloudFailure.checksumMismatch }
            try fm.moveItem(at: temporary, to: destination)
            try BackendCloudBrainMemoryHash.synchronize(destination)
            return destination
        } catch { try? handle.close(); try? fm.removeItem(at: temporary); throw error }
    }
    func cloudProjectFile(_ p: CloudBrainMemoryPart, from assembled: URL) throws -> CloudApplyStatus {
        let logical = String(p.key.dropFirst(5)), fm = FileManager.default
        // Finding 26: another Mac's project memory goes only under a project this Mac's project list confirmed.
        guard let path = try cloudPlacementPath(logical, origin: p.storeId) else {
            return try cloudHoldForProject(p, project: logical.split(separator: "/").map(String.init)[1], body: Data())
        }
        // Delete rule (memory lane, lead's decision 6): a local mark holds on every arrival, before any fast path below.
        if let handled = try cloudDeleteRuleArrival(p, path: path, assembled: assembled) { return handled }
        let target = try DeckMemoryCloudSchema.safePath(path, root: root)
        // The one rule (lane memory-one-rule): a removal travels as a version whose bytes are a removal marker.
        if (Int64(p.bytes) ?? Int64.max) < 16_384 {
            let small = try Data(contentsOf: assembled)
            if let marker = DeckMemoryRemoval.parse(small) { return try cloudApplyRemoval(p, marker, path: path) }
        }
        if fm.fileExists(atPath: target.path) {
            let current = try cloudHashFile(target)
            // Finding 14: identical bytes are the same thing. Record the version; never fight another store over the path.
            if current == p.resourceHash { return try cloudKeepVersion(p, projection: path, bytes: Data(), status: .alreadyPresent, claim: .ifUnowned) }
            // A causal Cloud descendant replaces its untouched predecessor (the path, or (finding 17) an earlier copy).
            if let prior = try cloudUntouchedPredecessor(p) {
                return try cloudReplace(prior, with: assembled, p: p)
            }
            // Finding 19: a file still byte-identical to what this app ships (a seed) is not the person's edit.
            if try cloudShippedSeedHashes(path).contains(current) { return try cloudReplace(path, with: assembled, p: p) }
            // The one rule: the newer revision is the file in use on every Mac; the other text is kept 30 days.
            // Never a second live "-cloud-<hash>" file, never `archive/cloud-conflicts` (topics, cards, playbooks,
            // templates and notes alike).
            return try cloudNewestFile(path, current: current, assembled: assembled, p: p)
        }
        // Not here: placed, unless this Mac holds a NEWER removal of it (then it is kept, not placed).
        if let decided = try cloudAgainstRemoval(p, path: path, assembled: assembled) { return decided }
        // Back in use here: never also listed in the Bin (round 3; a phase-1 Remove holds no removal head).
        let placed = try cloudPlace(path, from: assembled, p: p, status: .applied)
        try cloudLeaveBin(path)
        return placed
    }
    /// A topic (a `.md` file in a `topics` folder) is ONE live file on every Mac (now true of every memory file).
    static func cloudIsTopicFile(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        return path.lowercased().hasSuffix(".md") && parts.dropLast().contains("topics") && parts.first != "archive"
    }
    /// The managed projection of a parent version that is still exactly as this Mac last wrote it, if any.
    func cloudUntouchedPredecessor(_ p: CloudBrainMemoryPart) throws -> String? {
        guard !p.parents.isEmpty else { return nil }
        let marks = p.parents.map { _ in "?" }.joined(separator: ",")
        let args: [DeckMemorySQL] = [.text(p.storeId), .text(p.key)] + p.parents.map(DeckMemorySQL.text)
        let rows = try db.rows("SELECT content_hash,projection,projected_hash FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision IN (" + marks + ") AND projection IS NOT NULL AND projection<>''", args)
        let state = try CloudDeleteState(memory: db)
        for row in rows {
            let projection = row.text(1)
            // Delete rule (decision 6): a marked place is never "the untouched predecessor", so an arrival never
            // overwrites a file at a different "Only on this Mac" (or "Not on this Mac") place.
            if try state.mark(at: projection) != nil { continue }
            let url = try DeckMemoryCloudSchema.safePath(projection, root: root)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let current = try cloudHashFile(url)
            // The index may rewrite a kept sibling's id after placing it; the recorded projected hash covers that.
            if current == row.text(0) { return projection }
            if let projected = row.string(2), current == projected { return projection }
        }
        return nil
    }
    /// Same writer, the old bytes kept first (the one keeper, 30 days; the memory folder's own archive/versions only when
    /// the keeper cannot be reached), then an atomic replacement rechecked just before writing.
    func cloudReplace(_ relative: String, with assembled: URL, p: CloudBrainMemoryPart) throws -> CloudApplyStatus {
        let target = try DeckMemoryCloudSchema.safePath(relative, root: root)
        let before = try cloudHashFile(target)
        let kept = (try? cloudKeepCurrent(relative)) == true || keepVersion(of: relative) != nil
        guard kept else { throw CloudFailure.unavailable }
        guard try cloudHashFile(target) == before else { throw CloudFailure.versionChanged }
        let bytes = try Data(contentsOf: assembled, options: .mappedIfSafe)
        try bytes.write(to: target, options: .atomic)
        try BackendCloudBrainMemoryHash.synchronize(target)
        _ = try reindexNow(paths: [relative])
        let written = try cloudHashFile(target)
        try db.run("INSERT INTO cloud_memory_files(path,hash) VALUES (?,?) ON CONFLICT(path) DO UPDATE SET hash=excluded.hash", [.text(relative),.text(written)])
        return try cloudKeepVersion(p, projection: relative, bytes: Data(), status: .applied, claim: .take)
    }
    /// Places bytes at a free path, or recognises this very placement left by an interrupted earlier attempt.
    private func cloudPlace(_ relative: String, from assembled: URL, p: CloudBrainMemoryPart, status: CloudApplyStatus) throws -> CloudApplyStatus {
        let fm = FileManager.default, target = try DeckMemoryCloudSchema.safePath(relative, root: root)
        // Finding 16: the placement marker survives a rolled-back batch, so a retry recognises its own earlier file even
        // after the index rewrote that file's id. A file nobody placed for this exact content is never taken over.
        let marker = try cloudIncomingFolder().deletingLastPathComponent().appendingPathComponent("placed/" + DeckMemoryFiles.hash(relative))
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            let current = try cloudHashFile(target)
            if current != p.resourceHash {
                let placed = try? String(contentsOf: marker, encoding: .utf8)
                guard placed == p.resourceHash else { throw CloudFailure.idReused }
            }
        } else {
            try fm.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(p.resourceHash.utf8).write(to: marker, options: .atomic)
            try BackendCloudBrainMemoryHash.synchronize(marker)
            try fm.copyItem(at: assembled, to: target); try BackendCloudBrainMemoryHash.synchronize(target)
        }
        // The raw copy remains immutable under the account's incoming folder even if the established index adds labels to a projection.
        _ = try reindexNow(paths: [relative])
        let written = try cloudHashFile(target)
        try db.run("INSERT INTO cloud_memory_files(path,hash) VALUES (?,?) ON CONFLICT(path) DO UPDATE SET hash=excluded.hash", [.text(relative),.text(written)])
        return try cloudKeepVersion(p, projection: relative, bytes: Data(), status: status, claim: .take)
    }
    /// True only while the local file is still exactly one of the texts this app ever shipped there (M6: every version).
    func cloudIsShippedSeed(_ relative: String) throws -> Bool {
        let file = url(relative)
        guard FileManager.default.fileExists(atPath: file.path) else { return false }
        return try cloudShippedSeedHashes(relative).contains(cloudHashFile(file))
    }
    enum CloudPathClaim { case take, ifUnowned }
    /// `take`: this import placed these bytes at the path, so later local edits descend from it.
    /// `ifUnowned`: identical bytes already there; another store's (or this Mac's own) claim stays untouched (finding 14).
    private func cloudKeepVersion(_ p: CloudBrainMemoryPart, projection: String?, bytes: Data, status: CloudApplyStatus, claim: CloudPathClaim = .take) throws -> CloudApplyStatus {
        if p.key.hasPrefix("file/"), let projection, !projection.isEmpty {
            let existing = try db.first("SELECT store_id,resource_key FROM cloud_memory_file_origins WHERE path=?", [.text(projection)])
            let ownedElsewhere = existing.map { $0.text(0) != p.storeId || $0.text(1) != p.key } ?? false
            if claim == .take || !ownedElsewhere {
                try db.run("INSERT INTO cloud_memory_file_origins(path,store_id,resource_key,version) VALUES (?,?,?,?) ON CONFLICT(path) DO UPDATE SET store_id=excluded.store_id,resource_key=excluded.resource_key,version=excluded.version", [.text(projection),.text(p.storeId),.text(p.key),.text(p.version)])
                // R5: the file at this path is this version now, so a reconcile has nothing to send for it.
                try cloudWriteImportHead(p)
            }
        }
        var projectedHash: String?
        if p.key.hasPrefix("file/"), let projection, !projection.isEmpty { projectedHash = try cloudHashFile(DeckMemoryCloudSchema.safePath(projection, root: root)) }
        try db.run("INSERT INTO cloud_memory_versions(store_id,resource_key,revision,content_hash,inventory,body,projection,projected_hash,parents) VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(store_id,resource_key,revision) DO UPDATE SET projection=COALESCE(excluded.projection,cloud_memory_versions.projection),projected_hash=COALESCE(excluded.projected_hash,cloud_memory_versions.projected_hash)", [.text(p.storeId),.text(p.key),.text(p.version),.text(p.resourceHash),.text(p.inventoryRow),.blob(bytes),.optional(projection),.optional(projectedHash),.blob(try CloudWire.canonical(p.parents))])
        return status
    }
    /// X2 (13 Nov, the joining MacBook fetched 2 packs a minute for its first 3 minutes): this ran for every arrived
    /// memory FILE and walked every label row of the store still waiting for ITS file (about 1,700 notes then), so a
    /// pack of 150 files took 20 to 35 s. Only the labels of the file that just arrived can be placed by it: they are
    /// the ones walked now.
    /// Review M2: the projection of an archived project's index entry kept until its file arrives (not NULL, so it is
    /// never counted "unresolved"; not "", so the label reconcile still finds it).
    static let cloudLabelAwaitingArchivedFile = "history"
    func cloudReconcileLabels(storeId: String, path: String) throws {
        var last: Int64 = 0
        // H (13 Nov, the joining MacBook): rows kept waiting for a project are NOT label rows waiting for a file; they
        // are placed when their project is known (cloudRetryWaitingProjects). Walking them again for every arrived
        // file re-read and re-held all of them each time: 40,728 rows per file, one file per 20 s, fetching stalled.
        let waiting = try cloudWaitingTable()
        while let r = try db.first("SELECT rowid,resource_key,revision,inventory,body,parents,content_hash FROM cloud_memory_versions v WHERE store_id=? AND (projection IS NULL OR projection='\(Self.cloudLabelAwaitingArchivedFile)') AND resource_key LIKE 'row/%' AND inventory IN ('I04','I05') AND rowid>? AND json_extract(CAST(v.body AS TEXT),'$.references.path.id.value')=? AND NOT EXISTS (SELECT 1 FROM \(waiting) w WHERE w.store_id=v.store_id AND w.resource_key=v.resource_key AND w.revision=v.revision) ORDER BY rowid LIMIT 1", [.text(storeId),.int(last),.text(path)]) {
            last = r.int(0)
            cloudRevisits += 1
            guard let body = r.data(4) else { throw CloudFailure.invalidRequest }
            let p = CloudBrainMemoryPart(storeId: storeId, inventoryRow: r.text(3), key: r.text(1), version: r.text(2), resourceHash: r.text(6), bytes: String(body.count), index: 0, count: 1,
                                         parents: try JSONDecoder().decode([String].self, from: r.data(5) ?? Data()), data: "")
            let assembled = try cloudIncomingFolder().appendingPathComponent(storeId + "/" + r.text(6))
            _ = try cloudProjectRow(p, from: assembled)
        }
    }
    func cloudProjectRow(_ p: CloudBrainMemoryPart, from assembled: URL) throws -> CloudApplyStatus {
        let body = try Data(contentsOf: assembled), (t, original) = try DeckMemoryCloudSchema.decodeRow(body)
        let expectedKey = try DeckMemoryCloudSchema.key(t, original)
        guard expectedKey == p.key else {
            // Parked memory (14 Nov, the MacBook's two parked "files" rows): the one-rule settling on another device took
            // away a second copy (`archive/cloud-conflicts/...`) whose list entry had arrived under the FIRST file's
            // record. Its re-indexed entry went out under that record's name with the copy's place inside, so the
            // record's name and its content disagree. A label row (notes, topics, files, handoffs) is only the index of
            // a file and is rebuilt from the file on every Mac; such a row is kept as history, never placed, and never
            // refused (refused, it parked here for good and the line said "refused"). Any other table: still refused.
            guard Self.cloudFileLabelTables.contains(t.name) else { throw CloudFailure.invalidRequest }
            CloudSyncDiagnostics.shared.info("memory: an index entry of the \(t.name) list arrived under another file's name (a second copy another Mac settled); kept as history only, nothing changes here")
            return try cloudKeepVersion(p, projection: "", bytes: body, status: .alreadyPresent)
        }
        // Finding 18: settings about the other Mac (its backup time, migrations, index model) are kept as history only.
        // An empty projection marks a version that was deliberately not applied, so it never counts as unresolved.
        if DeckMemoryCloudSchema.isMachineLocal(t, original) { return try cloudKeepVersion(p, projection: "", bytes: body, status: .alreadyPresent) }
        let tombstone = DeckMemoryCloudSchema.isSettingTombstone(t, original)
        var values = original
        func index(_ name: String) -> Int? { t.columns.firstIndex(of: name) }
        // Finding 26: rows owned by another Mac's project (or a seat in it) wait until the project is confirmed here.
        var archivedOnly = false
        if let oi = index("owner"), case .text(let ownerKey) = original[oi], let owned = DeckMemoryOwner(key: ownerKey)?.projectID {
            guard let target = try cloudProjectPlacement(owned, origin: p.storeId) else { return try cloudHoldForProject(p, project: owned, body: body) }
            let local = target.id
            archivedOnly = target.archived
            values[oi] = .text(Self.cloudRemapOwner(ownerKey, from: owned, to: local))
            if let pi = index("project"), case .text(let project) = original[pi], project == owned { values[pi] = .text(local) }
        }
        let logical = try JSONDecoder().decode(CloudBrainMemoryRow.self, from: body)
        let localStore = try cloudStoreId()
        if t.integerKey, let i = index("id") {
            var parentId: DeckMemorySQL?
            for parent in p.parents {
                if let projection = try db.first("SELECT projection FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?", [.text(p.storeId),.text(p.key),.text(parent)])?.string(0),
                   let row = try? DeckMemoryCloudSchema.decodeRow(Data(projection.utf8)), row.0.name == t.name { parentId = row.1[i]; break }
            }
            if let parentId { values[i] = parentId }
            else { values[i] = try cloudResolveReference(.init(storeId: p.storeId, table: t.name, id: DeckMemoryCloudSchema.cell(original[i]))) }
        }
        let referenceColumns = DeckMemoryCloudSchema.referenceColumns(t.name)
        for (column, reference) in logical.references where column != "path" {
            guard referenceColumns[column] == reference.table, let i = index(column), DeckMemoryCloudSchema.cell(original[i]) == reference.id else { throw CloudFailure.invalidRequest }
            values[i] = try cloudResolveReference(reference)
        }
        for (column,_) in referenceColumns {
            if let i = index(column), original[i] != .null, !(t.name == "rewinds" && column == "after_row" && original[i] == .int(0)), logical.references[column] == nil { throw CloudFailure.invalidRequest }
        }
        if t.name == "diary", p.storeId != localStore, let i = index("external_id"), case .text(let external) = values[i] {
            values[i] = .text("cloud:" + p.storeId + ":" + external)
        }
        if t.name == "board", let i = index("id"), case .text(let id) = values[i] {
            if p.storeId != localStore { values[i] = .text("cloud:" + p.storeId + ":" + id) }
            if let doing = index("doing"), p.storeId != localStore { values[doing] = .text("Stopped on another device") }
        }
        // File-backed labels must join the actual kept file rather than create a second file writer.
        if let pi = index("path"), case .text(let originalPath) = original[pi] {
            let fileKey = "file/" + originalPath
            guard let reference = logical.references["path"], reference.table == "file", reference.id == DeckMemoryCloudSchema.cell(original[pi]), UUID(uuidString: reference.storeId) != nil else { throw CloudFailure.invalidRequest }
            if let mapped = try db.first("SELECT projection FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND projection IS NOT NULL ORDER BY rowid DESC LIMIT 1", [.text(reference.storeId),.text(fileKey)])?.string(0) { values[pi] = .text(mapped) }
            else if archivedOnly {
                // 15 Nov: an archived project's index entry whose file is not here (the Mac mini's 8 file and 2 topic
                // entries point to files that exist on no Mac; or the file is still on its way). Kept with the
                // `history` mark: never an entry that opens nothing, never "unresolved", and (review M2) restored with
                // its own date, kind and links by the label reconcile the moment its file arrives.
                cloudArchivedIndexKept += 1
                return try cloudKeepVersion(p, projection: Self.cloudLabelAwaitingArchivedFile, bytes: body, status: .alreadyPresent)
            }
            else {
                // Labels can precede files in a segment: retain them durably, then reconcile when the file arrives.
                return try cloudKeepVersion(p, projection: nil, bytes: body, status: .applied)
            }
        }
        let whereSQL = t.keys.map { "\($0)=?" }.joined(separator: " AND ")
        let keyValues = t.keys.map { values[t.columns.firstIndex(of: $0)!] }
        let existing: DeckMemoryRow?
        if ["notes","topics","files","handoffs"].contains(t.name), let pi = index("path") {
            existing = try db.first("SELECT \(t.columns.joined(separator: ",")) FROM \(t.name) WHERE path=?", [values[pi]])
            // The file index may have assigned a distinct id to a kept sibling; retain that local association.
            if let existing, let i = index("id") { values[i] = existing.values[i] }
        } else { existing = try db.first("SELECT \(t.columns.joined(separator: ",")) FROM \(t.name) WHERE \(whereSQL)", keyValues) }
        var status = CloudApplyStatus.applied
        if let existing {
            if existing.values == values {
                return try cloudKeepRowVersion(p, table: t, original: original, projected: Array(values.prefix(t.columns.count)), projection: String(decoding: try DeckMemoryCloudSchema.encodeRow(t, values), as: UTF8.self), bytes: body, status: .alreadyPresent)
            }
            var mayUpdate = false
            for parent in p.parents {
                if let previous = try db.first("SELECT projection FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?", [.text(p.storeId),.text(p.key),.text(parent)])?.string(0),
                   Data(previous.utf8) == (try DeckMemoryCloudSchema.encodeRow(t, existing.values)) { mayUpdate = true }
            }
            // The existing file index is derivative, and can receive its source labels only while its imported file is unchanged.
            if let pi = index("path"), case .text(let originalPath) = original[pi], case .text(let mappedPath) = values[pi],
               let imported = try db.first("SELECT projected_hash FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND projection=? ORDER BY rowid DESC LIMIT 1", [.text(p.storeId),.text("file/" + originalPath),.text(mappedPath)]),
               try cloudHashFile(DeckMemoryCloudSchema.safePath(mappedPath, root: root)) == imported.text(0) { mayUpdate = true }
            let localKeys = t.keys.map { existing.values[t.columns.firstIndex(of: $0)!] }
            if !mayUpdate, Self.cloudLastWriterTables.contains(t.name) {
                // Shared values: last writer by revision wins, the other stays in history and never blocks later versions.
                let localEncoded = String(decoding: try DeckMemoryCloudSchema.encodeRow(t, existing.values), as: UTF8.self)
                // M4: this Mac's value has no revision yet (not exported): it is decided by the same rule once it has one.
                guard let local = try db.first("SELECT store_id,revision FROM cloud_memory_versions WHERE resource_key=? AND projection=? ORDER BY rowid DESC LIMIT 1", [.text(p.key),.text(localEncoded)]),
                      let localRevision = try cloudRevision(storeId: local.text(0), key: p.key, version: local.text(1)),
                      let incomingRevision = try cloudRevision(storeId: p.storeId, key: p.key, version: p.version) else {
                    try cloudMarkPendingMerge(p)
                    return try cloudKeepVersion(p, projection: "", bytes: body, status: .keptBoth)
                }
                // The single replaceable rule; the loser is kept as history either way.
                guard DeckMemoryCloudMerge.winner(incomingRevision, localRevision) == incomingRevision else {
                    return try cloudKeepVersion(p, projection: "", bytes: body, status: .keptBoth)
                }
                mayUpdate = true
            }
            if mayUpdate, tombstone {
                // Finding 22: a deleted or reset shared setting travels as a removal.
                try db.run("DELETE FROM \(t.name) WHERE " + whereSQL, localKeys)
                // D1: the removal stays the record's current version, so a later concurrent edit is decided against it.
                try cloudRecordRemovalVersion(p, table: t, values: existing.values, logical: original)
                return try cloudKeepVersion(p, projection: "", bytes: body, status: .applied)
            }
            if mayUpdate {
                let keys = localKeys
                try db.run("UPDATE \(t.name) SET " + t.columns.map { "\($0)=?" }.joined(separator: ",") + " WHERE " + whereSQL, values + keys)
                if t.name == "diary", let id = index("id"), case .int(let localId) = values[id] { try cloudReindexDiary(localId) }
                return try cloudKeepRowVersion(p, table: t, original: original, projected: Array(values.prefix(t.columns.count)), projection: String(decoding: try DeckMemoryCloudSchema.encodeRow(t, values), as: UTF8.self), bytes: body, status: .applied)
            }
            status = .keptBoth
            if t.integerKey, let i = index("id") {
                values[i] = .int(try cloudAllocateInteger(t.name))
                // diary.external_id is UNIQUE: the kept sibling of a message edited on both Macs needs its own marked id,
                // otherwise the insert fails, the import rolls back and every retry fails the same way.
                if t.name == "diary", let e = index("external_id"), case .text(let external) = values[e] {
                    values[e] = .text(external + ":cloud-" + String(p.resourceHash.prefix(16)))
                }
            } else if t.name == "board", let i = index("id"), case .text(let id) = values[i] {
                values[i] = .text(id + ":" + p.resourceHash)
            } else {
                // Any other natural-key conflict keeps both exact versions as history; it never blocks later versions.
                return try cloudKeepVersion(p, projection: "", bytes: body, status: status)
            }
        }
        // D1: no local row for a merging record. If this Mac recorded a version for it (for example its removal), the
        // incoming one is placed only when it wins against that version; otherwise it is kept as history.
        if existing == nil, Self.cloudLastWriterTables.contains(t.name), let recorded = try cloudRecordedVersion(table: t, values: values), recorded != p.version {
            guard let incomingRevision = try cloudRevision(storeId: p.storeId, key: p.key, version: p.version),
                  let recordedRevision = try cloudRevision(storeId: p.storeId, key: p.key, version: recorded) else {
                try cloudMarkPendingMerge(p)
                return try cloudKeepVersion(p, projection: "", bytes: body, status: .keptBoth)
            }
            guard DeckMemoryCloudMerge.winner(incomingRevision, recordedRevision) == incomingRevision else {
                return try cloudKeepVersion(p, projection: "", bytes: body, status: .keptBoth)
            }
        }
        if tombstone {
            if existing == nil { try cloudRecordRemovalVersion(p, table: t, values: values, logical: original) }
            return try cloudKeepVersion(p, projection: "", bytes: body, status: .alreadyPresent)
        }
        var columns = t.columns
        // These are local index facts, rebuilt from files; never uploaded.
        for name in ["mtime", "bytes", "hash", "missing"] where !columns.contains(name) {
            if ["notes","topics","files","handoffs"].contains(t.name) { columns.append(name); values.append(name == "hash" ? .text("") : .int(0)) }
        }
        try db.run("INSERT INTO \(t.name)(\(columns.joined(separator: ","))) VALUES (\(columns.map { _ in "?" }.joined(separator: ",")))", values)
        if t.name == "diary", let id = index("id"), case .int(let localId) = values[id] { try cloudReindexDiary(localId) }
        return try cloudKeepRowVersion(p, table: t, original: original, projected: Array(values.prefix(t.columns.count)), projection: String(decoding: try DeckMemoryCloudSchema.encodeRow(t, Array(values.prefix(t.columns.count))), as: UTF8.self), bytes: body, status: status)
    }
    /// Natural-key rows whose newest value wins (settings, labels); messages, board rows and history keep both instead.
    static let cloudLastWriterTables: Set<String> = ["settings", "meta", "topics", "files", "notes", "handoffs"]
    private func cloudKeepRowVersion(_ p: CloudBrainMemoryPart, table: DeckMemoryCloudSchema.Table, original: [DeckMemorySQL], projected: [DeckMemorySQL], projection: String, bytes: Data, status: CloudApplyStatus) throws -> CloudApplyStatus {
        let keys = table.keys.map { projected[table.columns.firstIndex(of: $0)!] }
        guard let back = try db.first("SELECT \(table.columns.joined(separator: ",")) FROM \(table.name) WHERE " + table.keys.map { "\($0)=?" }.joined(separator: " AND "), keys), back.values == projected else { throw CloudFailure.checksumMismatch }
        try cloudRegisterRowOrigin(p, t: table, original: original, projected: projected)
        // R5: the local row now equals this version, so a reconcile has nothing to send for it.
        try cloudWriteImportHead(p)
        return try cloudKeepVersion(p, projection: projection, bytes: bytes, status: status)
    }
    private func cloudReindexDiary(_ id: Int64) throws {
        if let r = try db.first("SELECT \(Self.diaryColumns) FROM diary WHERE id=?", [.int(id)]) {
            let entry = diaryEntry(r)
            try setSearch(kind: .diary, ref: String(id), labels: entry.labels, archived: entry.rewoundAt != nil, title: "", body: entry.text)
        }
    }
    func cloudVerify(_ receipt: CloudImportReceipt) throws -> CloudVerification {
        guard let saved = try db.first("SELECT body FROM cloud_memory_receipts WHERE id=?", [.text(receipt.preparationId)])?.data(0),
              try CloudWire.canonical(receipt) == saved else { return .init(verified: false, counts: receipt.counts, reasons: ["The saved import receipt differs."]) }
        var checked = Set<String>()
        for ordinal in receipt.results.indices {
            if [Self.cloudBackupExcluded, Self.cloudAppOwnedExcluded, Self.cloudLocalOnlyIgnored].contains(receipt.results[ordinal].reason) { continue }
            guard let r = try db.first("SELECT p.operation,p.op_hash,p.body,p.store_id,p.resource_key,p.revision,p.content_hash FROM cloud_memory_receipt_ops r JOIN cloud_memory_parts p ON p.op_id=r.op_id WHERE r.preparation=? AND r.ordinal=?", [.text(receipt.preparationId),.int(Int64(ordinal))]),
                  let original = r.data(0), DeckMemoryFiles.hash(original) == r.text(1) else { throw CloudFailure.checksumMismatch }
            let operation = try JSONDecoder().decode(CloudOperation.self, from: original)
            let part = try cloudValidatePart(operation, row: receipt.inventoryRow)
            guard operation.entityId == receipt.results[ordinal].entityId, Data(base64Encoded: part.data) == r.data(2) else { throw CloudFailure.checksumMismatch }
            let identity = r.text(3) + ":" + r.text(4) + ":" + r.text(5)
            if checked.insert(identity).inserted,
               let version = try db.first("SELECT body FROM cloud_memory_versions WHERE store_id=? AND resource_key=? AND revision=?", [.text(r.text(3)),.text(r.text(4)),.text(r.text(5))]) {
                if r.text(4).hasPrefix("file/") {
                    let raw = try cloudIncomingFolder().appendingPathComponent(r.text(3) + "/" + r.text(6))
                    guard try cloudHashFile(raw) == r.text(6) else { throw CloudFailure.checksumMismatch }
                } else { guard DeckMemoryFiles.hash(version.data(0) ?? Data()) == r.text(6) else { throw CloudFailure.checksumMismatch } }
            }
        }
        return .init(verified: true, counts: receipt.counts, reasons: [])
    }
    public func cloudMemoryReadiness() throws -> CloudVerification {
        guard cloudMemoryEnabled else { throw CloudFailure.unavailable }
        let partial = try db.first("SELECT COUNT(*) FROM (SELECT store_id,resource_key,revision FROM cloud_memory_parts GROUP BY store_id,resource_key,revision HAVING COUNT(DISTINCT part)<MAX(total))")?.int(0) ?? 0
        // Y1: a row kept for its project (waiting or set aside) is counted below by that rule, not as an unresolved label.
        let waitingTable = try cloudWaitingTableForReading()
        let notWaiting = waitingTable.map { " AND NOT EXISTS (SELECT 1 FROM \($0) w WHERE w.store_id=v.store_id AND w.resource_key=v.resource_key AND w.revision=v.revision)" } ?? ""
        let notParked = try cloudParkedCount() > 0 ? " AND NOT EXISTS (SELECT 1 FROM cloud.cloud_memory_parked k WHERE k.store_id=v.store_id AND k.resource_key=v.resource_key AND k.revision=v.revision)" : ""
        // MAC-NEXT-8b: versions of the live board (kept by older builds, never placed) are not unfinished imports.
        let notLocalOnly = DeckMemoryCloudSchema.tables.filter(DeckMemoryCloudSchema.isLocalOnly).map { " AND resource_key NOT LIKE 'row/\($0.name)/%'" }.joined()
        let unresolved = try db.first("SELECT COUNT(*) FROM cloud_memory_versions v WHERE resource_key LIKE 'row/%' AND projection IS NULL" + notLocalOnly + notWaiting + notParked)?.int(0) ?? 0
        let captured = (try cloudCaptureFailure() ? 1 : 0) + Int(try db.first("SELECT COUNT(*) FROM cloud_memory_control WHERE key LIKE 'pumpProblem:%'")?.int(0) ?? 0)
        var documentConflicts = 0
        for row in try db.rows("SELECT resource_key,projection,content_hash,store_id FROM cloud_memory_versions WHERE resource_key LIKE 'file/%' AND projection IS NOT NULL AND projection<>''") {
            let logical = String(row.text(0).dropFirst(5)), projection = row.text(1)
            // A project-mapped placement (finding 26) is where this file belongs here, not a kept conflict.
            let placed = try cloudPlacementPath(logical, origin: row.text(3)) ?? logical
            guard placed != projection else { continue }
            let activeRule: Bool
            if DeckMemoryFiles.templateCategory(logical) != nil { activeRule = true }
            else if let kind = DeckMemoryFiles.classify(logical)?.kind {
                switch kind { case .card, .playbook: activeRule = true; default: activeRule = false }
            } else { activeRule = false }
            guard activeRule else { continue }
            let current = try DeckMemoryCloudSchema.safePath(placed, root: root)
            if (try? cloudHashFile(current)) != row.text(2) { documentConflicts += 1 }
        }
        // These saved bytes must not be called active AI context while an existing card/template still masks them.
        // Finding 26: project memory not matched to a local project is retained and named, never placed.
        // Y1: only rows whose project IS on this Mac (the release places them by itself) and rows set aside count.
        // Rows for a project that is on no device here wait quietly: nothing the person has to do.
        let waitingProjects = try cloudReleasableCount() + cloudParkedCount()
        let blocked = Int(partial + unresolved) + captured + documentConflicts + waitingProjects
        let records = Int(try db.first("SELECT COUNT(*) FROM cloud_memory_versions WHERE resource_key NOT LIKE 'file/%'")?.int(0) ?? 0)
        let files = Int(try db.first("SELECT COUNT(*) FROM cloud_memory_versions WHERE resource_key LIKE 'file/%'")?.int(0) ?? 0)
        return .init(verified: blocked == 0, counts: .init(domains: 6, records: records, files: files, bytes: 0, blocked: blocked),
                     reasons: blocked == 0 ? [] : ["Memory still has unfinished imports or kept conflicts to check."]
                        + (waitingProjects > 0 ? [DeckMemoryCloudLeanProjects.waitingLine(waitingProjects)] : []))
    }
}
