import Foundation
import Darwin
import TerminalDeckNativeCore

enum BackendCloudBrainFilesRace: Error { case exists }

/// One validated incoming operation. Only Sendable values.
struct BackendCloudBrainFilesPart: Sendable {
    let op: CloudOperation
    let operationBytes: Data
    let opHash: String
    let archive: Bool
    let storeId: String
    let key: String
    let version: String
    let index: Int
    let count: Int
    let bytes: Int64
    let resourceHash: String
    let parents: [String]
    let body: Data
    let sourceId: String
    let relative: String
}

extension BackendCloudBrainFiles {
    /// Operation links: the version-4 layout this build sends (13 Nov blocker), or the older version-5 one (which the
    /// sync core never packs, so it reaches here only from a local test or an old stored record).
    static func linksValid(_ op: CloudOperation, version: String, parents: [String], suffix: String) -> Bool {
        for make in [BackendCloudBrainMemoryHash.operationId, BackendCloudBrainMemoryHash.uuid] as [(String) -> String] {
            if op.revision == make(version + suffix) { return op.parents == parents.map { make($0 + suffix) } }
        }
        return false
    }
    static let partKeys: Set<String> = ["format","storeId","inventoryRow","key","version","resourceHash","bytes","index","count","parents","data"]
    static let markerKeys: Set<String> = ["format","storeId","inventoryRow","key","version","resourceHash","parents"]
    static func isHash(_ text: String) -> Bool { text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }

    /// Every field is checked against the operation identity before anything is staged.
    func check(_ op: CloudOperation) throws -> BackendCloudBrainFilesPart {
        guard op.v == 1, op.domain == domain, op.opId == op.revision, UUID(uuidString: op.originDevice) != nil, UUID(uuidString: op.opId) != nil else { throw CloudFailure.invalidRequest }
        let payload = try CloudWire.canonical(op.payload)
        guard BackendCloudBrainMemoryHash.bytes(payload) == op.payloadHash else { throw CloudFailure.checksumMismatch }
        let storeId: String, key: String, version: String, hash: String, parents: [String], index: Int, count: Int, total: Int64, body: Data
        let archive: Bool
        switch op.kind {
        case .put:
            let part = try CloudWire.decode(CloudBrainMemoryPart.self, from: payload, allowedKeys: Self.partKeys, maximumBytes: 65_536)
            guard part.format == "td-memory-part-1", part.inventoryRow == row, let size = Int64(part.bytes), size >= 0, String(size) == part.bytes,
                  size <= Int64(Int.max - CloudBrainFilesFormat.partBytes), let data = Data(base64Encoded: part.data) else { throw CloudFailure.invalidRequest }
            let partSize = CloudBrainFilesFormat.partBytes
            let expectedCount = max(1, (Int(size) + partSize - 1) / partSize)
            guard part.count == expectedCount, part.index >= 0, part.index < part.count,
                  data.count == min(partSize, max(0, Int(size) - part.index * partSize)) else { throw CloudFailure.invalidRequest }
            storeId = part.storeId; key = part.key; version = part.version; hash = part.resourceHash; parents = part.parents
            index = part.index; count = part.count; total = size; body = data; archive = false
            guard op.entityId == BackendCloudBrainMemoryHash.uuid(storeId + "\n" + key + "\n" + String(index)),
                  Self.linksValid(op, version: version, parents: parents, suffix: "\n" + String(index)) else { throw CloudFailure.invalidRequest }
        case .archive:
            let marker = try CloudWire.decode(CloudBrainFilesArchiveMarker.self, from: payload, allowedKeys: Self.markerKeys, maximumBytes: 65_536)
            guard marker.format == "td-file-archive-1", marker.inventoryRow == row else { throw CloudFailure.invalidRequest }
            storeId = marker.storeId; key = marker.key; version = marker.version; hash = marker.resourceHash; parents = marker.parents
            index = 0; count = 1; total = 0; body = Data(); archive = true
            guard op.entityId == BackendCloudBrainMemoryHash.uuid(storeId + "\n" + key + "\narchive"),
                  Self.linksValid(op, version: version, parents: parents, suffix: "\narchive") else { throw CloudFailure.invalidRequest }
        default: throw CloudFailure.unsupportedFormat
        }
        guard UUID(uuidString: storeId) != nil, UUID(uuidString: version) != nil, parents.allSatisfy({ UUID(uuidString: $0) != nil }),
              Set(parents).count == parents.count, Self.isHash(hash), op.source.recordId == key else { throw CloudFailure.invalidRequest }
        let (sourceId, relative) = try resolve(key: key)
        let operationBytes = try CloudWire.canonical(op)
        return .init(op: op, operationBytes: operationBytes, opHash: BackendCloudBrainMemoryHash.bytes(operationBytes), archive: archive, storeId: storeId, key: key,
                     version: version, index: index, count: count, bytes: total, resourceHash: hash, parents: parents, body: body, sourceId: sourceId, relative: relative)
    }

    /// `file/<sourceId>/<relative>`: the source must be one of this row's and the path one that source may hold.
    func resolve(key: String) throws -> (String, String) {
        guard key.hasPrefix("file/") else { throw CloudFailure.invalidRequest }
        var candidates = sources.filter { key.hasPrefix("file/" + $0.sourceId + "/") }
        if candidates.isEmpty, let dynamicSource {
            // Every leading folder sequence of the key is a possible source id; the owner recognises its own.
            let components = key.dropFirst(5).split(separator: "/", omittingEmptySubsequences: false)
            for length in 1..<max(1, components.count) {
                let id = components.prefix(length).joined(separator: "/")
                if BackendCloudBrainFilesSource.validSourceId(id), let made = dynamicSource(id), made.sourceId == id { candidates.append(made) }
            }
        }
        candidates.sort { $0.sourceId.count > $1.sourceId.count }
        for source in candidates {
            let relative = String(key.dropFirst(("file/" + source.sourceId + "/").count))
            if BackendCloudBrainFilesSource.safeRelative(relative), source.included(relative) { return (source.sourceId, relative) }
        }
        throw CloudFailure.invalidRequest
    }

    public func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
        guard files.isEmpty, !operations.isEmpty else { throw CloudFailure.unsupportedFormat }
        guard Set(operations.map(\.opId)).count == operations.count else { throw CloudFailure.idReused }
        let checked = try operations.map { try check($0) }
        let db = try database()
        // Durable staging: parts survive restart; the same id with different bytes is refused (S03).
        try db.transaction {
            for p in checked {
                if let old = try db.first("SELECT op_hash FROM parts WHERE op_id=?", [.text(p.op.opId)]) {
                    guard old.text(0) == p.opHash else { throw CloudFailure.idReused }
                    continue
                }
                try db.run("""
                    INSERT INTO parts(op_id,op_hash,operation,kind,store_id,key,version,part,total,bytes,resource_hash,parents,origin_device,created_at,project_id,root_id,body)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, [.text(p.op.opId),.text(p.opHash),.blob(p.operationBytes),.text(p.archive ? "archive" : "put"),.text(p.storeId),.text(p.key),.text(p.version),
                          .int(Int64(p.index)),.int(Int64(p.count)),.int(p.bytes),.text(p.resourceHash),.text(Self.json(p.parents)),.text(p.op.originDevice),
                          .int(p.op.createdAt),.optional(p.op.projectId),.optional(p.op.rootId),.blob(p.body)])
            }
        }
        let id = BackendCloudBrainMemoryHash.uuid(BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(operations)))
        return .init(preparationId: id, operations: operations, files: [])
    }

    private struct Assembled: Sendable {
        let part: BackendCloudBrainFilesPart
        let createdAt: Int64
    }

    public func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
        let again = try await validateIncoming(prepared.operations, files: prepared.files)
        guard again.preparationId == prepared.preparationId else { throw CloudFailure.idReused }
        let db = try database()
        if let saved = try db.first("SELECT body FROM receipts WHERE id=?", [.text(prepared.preparationId)])?.data(0) {
            return try JSONDecoder().decode(CloudImportReceipt.self, from: saved)
        }
        let parts = try prepared.operations.map { try check($0) }
        // Phase 1: every complete resource is assembled and its whole hash verified before anything is placed (S06).
        var ready: [String: Assembled] = [:], order: [String] = []
        for p in parts {
            let identity = p.storeId + "\n" + p.key + "\n" + p.version
            guard ready[identity] == nil, !order.contains(identity) else { continue }
            if try db.first("SELECT status FROM resources WHERE store_id=? AND key=? AND version=?", [.text(p.storeId),.text(p.key),.text(p.version)]) != nil { order.append(identity); continue }
            if p.archive { ready[identity] = .init(part: p, createdAt: p.op.createdAt); order.append(identity); continue }
            let rows = try db.rows("SELECT part,total,bytes,resource_hash FROM parts WHERE store_id=? AND key=? AND version=? AND kind='put' ORDER BY part",
                                   [.text(p.storeId),.text(p.key),.text(p.version)])
            guard rows.allSatisfy({ $0.int(1) == Int64(p.count) && $0.int(2) == p.bytes && $0.text(3) == p.resourceHash }) else { throw CloudFailure.checksumMismatch }
            order.append(identity)
            guard rows.count == p.count, rows.map({ Int($0.int(0)) }) == Array(0..<p.count) else { continue } // remaining parts arrive later
            try assemble(p)
            ready[identity] = .init(part: p, createdAt: p.op.createdAt)
        }
        // Phase 2: placement through the owner's projection; never over different bytes.
        var statuses: [String: (CloudApplyStatus, String?)] = [:], records = 0, written = 0, bytes: Int64 = 0
        for identity in order {
            if let done = try existingStatus(identity) { statuses[identity] = done; continue }
            guard let item = ready[identity] else { continue }
            let outcome = try await place(item.part)
            statuses[identity] = outcome.status
            records += 1; written += outcome.wrote ? 1 : 0; bytes += item.part.bytes
        }
        var results: [CloudItemResult] = []
        for p in parts {
            let identity = p.storeId + "\n" + p.key + "\n" + p.version
            if let status = statuses[identity] { results.append(.init(entityId: p.op.entityId, status: status.0, reason: status.1)) }
            else { results.append(.init(entityId: p.op.entityId, status: .applied, reason: "part_saved")) }
        }
        let receipt = CloudImportReceipt(preparationId: prepared.preparationId, inventoryRow: row, results: results,
                                         counts: .init(domains: 1, records: records, files: written, bytes: bytes, blocked: 0))
        try db.transaction {
            try db.run("INSERT OR IGNORE INTO receipts(id,body) VALUES (?,?)", [.text(prepared.preparationId),.blob(try CloudWire.canonical(receipt))])
            for identity in order where statuses[identity] != nil {
                let fields = identity.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                try db.run("INSERT OR IGNORE INTO receipt_resources(preparation,store_id,key,version) VALUES (?,?,?,?)",
                           [.text(prepared.preparationId),.text(fields[0]),.text(fields[1]),.text(fields[2])])
            }
        }
        if lean {
            // Lane L3 review (cost): the file is assembled (retained) and placed; its part bodies are not needed again.
            // The row stays (with its fingerprint), so the same record sent again is still known and still checked.
            try db.transaction {
                for identity in order {
                    guard let status = statuses[identity], status.1 != "retained_waiting" else { continue }
                    let fields = identity.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    guard fields.count == 3 else { continue }
                    try db.run("UPDATE parts SET body=X'',operation=X'' WHERE store_id=? AND key=? AND version=? AND kind='put'",
                               [.text(fields[0]),.text(fields[1]),.text(fields[2])])
                }
            }
        }
        _ = try await reproject(limit: 64)
        return receipt
    }

    private func existingStatus(_ identity: String) throws -> (CloudApplyStatus, String?)? {
        let fields = identity.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 3, let r = try database().first("SELECT status,reason FROM resources WHERE store_id=? AND key=? AND version=?",
                                                               [.text(fields[0]),.text(fields[1]),.text(fields[2])]) else { return nil }
        // Placed earlier (possibly by another preparation): this repeat is idempotent.
        return (r.text(0) == "kept_both" ? .keptBoth : .alreadyPresent, r.string(1))
    }

    /// Writes the verified raw bytes to the hash-named retained area. A wrong part or total applies nothing.
    private func assemble(_ p: BackendCloudBrainFilesPart) throws {
        let db = try database(), target = retainedURL(p.resourceHash)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try BackendCloudBrainMemoryHash.file(target) == p.resourceHash else { throw CloudFailure.checksumMismatch }
            return
        }
        let temporary = stateRoot.appendingPathComponent("assembling/" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CloudFailure.unavailable }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            var total: Int64 = 0
            do {
                for index in 0..<p.count {
                    guard let r = try db.first("SELECT body FROM parts WHERE store_id=? AND key=? AND version=? AND part=? AND kind='put'",
                                               [.text(p.storeId),.text(p.key),.text(p.version),.int(Int64(index))]), let body = r.data(0) else { throw CloudFailure.checksumMismatch }
                    try handle.write(contentsOf: body); total += Int64(body.count)
                }
                try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            guard total == p.bytes, try BackendCloudBrainMemoryHash.file(temporary) == p.resourceHash else { throw CloudFailure.checksumMismatch }
            if rename(temporary.path, target.path) != 0 { throw CloudFailure.unavailable }
            try BackendCloudBrainMemoryHash.synchronizeDirectory(target.deletingLastPathComponent())
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    private struct Outcome: Sendable { let status: (CloudApplyStatus, String?); let wrote: Bool }

    private func place(_ p: BackendCloudBrainFilesPart) async throws -> Outcome {
        let db = try database()
        func record(_ status: String, destination: String?, localHash: String?, reason: String?) throws {
            try db.run("""
                INSERT INTO resources(store_id,key,version,kind,source_id,relative,raw_hash,raw_bytes,parents,origin_device,created_at,project_id,root_id,status,destination,local_hash,reason)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(store_id,key,version) DO UPDATE SET status=excluded.status,destination=excluded.destination,
                local_hash=excluded.local_hash,reason=excluded.reason
                """, [.text(p.storeId),.text(p.key),.text(p.version),.text(p.archive ? "archive" : "put"),.text(p.sourceId),.text(p.relative),.text(p.resourceHash),
                      .int(p.bytes),.text(Self.json(p.parents)),.text(p.op.originDevice),.int(p.op.createdAt),.optional(p.op.projectId),.optional(p.op.rootId),
                      .text(status),.optional(destination),.optional(localHash),.optional(reason)])
        }
        if p.archive {
            // A removal elsewhere is history; nothing is deleted here (S15).
            try record("archived", destination: nil, localHash: nil, reason: "archive_marker_kept")
            return .init(status: (.applied, "archive_marker_kept"), wrote: false)
        }
        let raw = try Data(contentsOf: retainedURL(p.resourceHash))
        guard BackendCloudBrainMemoryHash.bytes(raw) == p.resourceHash else { throw CloudFailure.checksumMismatch }
        let source = try self.source(p.sourceId)
        let placement: BackendCloudBrainFilesPlacement
        switch source.projection {
        case .archiveOnly(let reason): placement = .archiveOnly(reason)
        case .createOnly(let transform):
            var projected = raw
            if let transform { projected = try transform(p.relative, raw) }
            placement = .write(source.root.appendingPathComponent(p.relative), projected)
        case .custom(let hook):
            placement = try await hook(.init(sourceId: p.sourceId, relative: p.relative, bytes: raw, projectId: p.op.projectId, rootId: p.op.rootId, originDevice: p.op.originDevice))
        }
        switch placement {
        case .archiveOnly(let reason):
            try record("archived", destination: nil, localHash: nil, reason: reason)
            return .init(status: (.applied, "retained_readable"), wrote: false)
        case .waiting(let reason):
            try record("waiting", destination: nil, localHash: nil, reason: reason)
            return .init(status: (.applied, "retained_waiting"), wrote: false)
        case .write(let destination, let bytes):
            return try write(p, destination: destination, bytes: bytes, record: record)
        }
    }

    /// Create-only placement with read-back. Different existing bytes stay; the incoming version is kept beside them (S05).
    private func write(_ p: BackendCloudBrainFilesPart, destination: URL, bytes: Data,
                       record: (String, String?, String?, String?) throws -> Void) throws -> Outcome {
        let db = try database(), fm = FileManager.default
        let target = destination.standardizedFileURL
        guard target.isFileURL, target.path.hasPrefix("/"), !target.path.contains("/../") else { throw CloudFailure.unsafeConfiguration }
        let localHash = BackendCloudBrainMemoryHash.bytes(bytes)
        let owner = sources.first { target.path.hasPrefix($0.root.standardizedFileURL.path + "/") && $0.included(String(target.path.dropFirst($0.root.standardizedFileURL.path.count + 1))) }
        let ownerRelative = owner.map { String(target.path.dropFirst($0.root.standardizedFileURL.path.count + 1)) }
        func remember(pending: Bool) throws {
            guard let owner, let ownerRelative else { return }
            // Recorded before the write so the owner's own watcher never echoes an import as a local edit.
            try db.run("""
                INSERT INTO files(source_id,path,hash,bytes,mtime,store_id,key,version,parents,created_at,raw_hash,raw_bytes,origin_device,imported,archived,pending,project_id,root_id)
                VALUES (?,?,?,?,0,?,?,?,?,?,?,?,?,1,0,?,?,?) ON CONFLICT(source_id,path) DO UPDATE SET hash=excluded.hash,bytes=excluded.bytes,mtime=0,store_id=excluded.store_id,
                key=excluded.key,version=excluded.version,parents=excluded.parents,created_at=excluded.created_at,raw_hash=excluded.raw_hash,raw_bytes=excluded.raw_bytes,
                origin_device=excluded.origin_device,imported=1,archived=0,pending=excluded.pending,project_id=excluded.project_id,root_id=excluded.root_id
                """, [.text(owner.sourceId),.text(ownerRelative),.text(localHash),.int(Int64(bytes.count)),.text(p.storeId),.text(p.key),.text(p.version),.text(Self.json(p.parents)),
                      .int(p.op.createdAt),.text(p.resourceHash),.int(p.bytes),.text(p.op.originDevice),.int(pending ? 1 : 0),.optional(p.op.projectId),.optional(p.op.rootId)])
        }
        var linked: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &linked) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            let existing: String? = linked.boolValue ? nil : (try? BackendCloudBrainMemoryHash.file(target))
            if existing == localHash {
                try remember(pending: false)
                try record("already_present", target.path, localHash, nil)
                return .init(status: (.alreadyPresent, nil), wrote: false)
            }
            // A sequential newer version over an unchanged older import: the replaced bytes are retained first, so nothing is lost.
            if let existing, let owner, let ownerRelative,
               let row = try db.first("SELECT hash,version,pending FROM files WHERE source_id=? AND path=?", [.text(owner.sourceId),.text(ownerRelative)]),
               row.text(0) == existing, row.int(2) == 0, p.parents.contains(row.text(1)) {
                try retain(target, hash: existing)
                try remember(pending: true)
                try replace(target, with: bytes, expecting: existing)
                try remember(pending: false)
                try record("applied", target.path, localHash, "newer_version")
                return .init(status: (.applied, "newer_version"), wrote: true)
            }
            let kept = stateRoot.appendingPathComponent("conflicts/" + p.version + "/" + target.lastPathComponent)
            try fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: kept.path) { try createOnly(kept, bytes: bytes) }
            let provenance: [String: String] = ["sourceId": p.sourceId, "relative": p.relative, "destination": target.path, "storeId": p.storeId, "key": p.key,
                                                "version": p.version, "originDevice": p.op.originDevice, "rawHash": p.resourceHash, "localHash": existing ?? ""]
            let provenanceFile = kept.deletingLastPathComponent().appendingPathComponent("provenance.json")
            if !fm.fileExists(atPath: provenanceFile.path) { try createOnly(provenanceFile, bytes: try JSONEncoder().encode(provenance)) }
            try record("kept_both", kept.path, localHash, "existing_file_kept")
            return .init(status: (.keptBoth, "existing_file_kept"), wrote: false)
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try remember(pending: true)
        do { try createOnly(target, bytes: bytes) }
        catch BackendCloudBrainFilesRace.exists {
            // Someone created it between the check and the link: their bytes win, ours are kept as a conflict on the next apply.
            try db.run("DELETE FROM files WHERE source_id=? AND path=? AND pending=1", [.text(owner?.sourceId ?? ""),.text(ownerRelative ?? "")])
            throw CloudFailure.versionChanged
        }
        try remember(pending: false)
        try record("applied", target.path, localHash, nil)
        return .init(status: (.applied, nil), wrote: true)
    }

    /// Temporary file + link(2): fails instead of replacing anything that appeared meanwhile.
    func createOnly(_ target: URL, bytes: Data) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".td-cloud-" + UUID().uuidString)
        try bytes.write(to: temporary, options: .withoutOverwriting)
        defer { unlink(temporary.path) }
        try BackendCloudBrainMemoryHash.synchronize(temporary)
        if link(temporary.path, target.path) != 0 {
            if errno == EEXIST { throw BackendCloudBrainFilesRace.exists }
            throw CloudFailure.unavailable
        }
        guard try BackendCloudBrainMemoryHash.file(target) == BackendCloudBrainMemoryHash.bytes(bytes) else { throw CloudFailure.checksumMismatch }
        try BackendCloudBrainMemoryHash.synchronizeDirectory(target.deletingLastPathComponent())
    }
    private func replace(_ target: URL, with bytes: Data, expecting: String) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".td-cloud-" + UUID().uuidString)
        try bytes.write(to: temporary, options: .withoutOverwriting)
        defer { unlink(temporary.path) }
        try BackendCloudBrainMemoryHash.synchronize(temporary)
        guard try BackendCloudBrainMemoryHash.file(target) == expecting else { throw CloudFailure.versionChanged }
        if rename(temporary.path, target.path) != 0 { throw CloudFailure.unavailable }
        try BackendCloudBrainMemoryHash.synchronizeDirectory(target.deletingLastPathComponent())
    }

    /// Retries placements that waited for a destination (for example after a project path is mapped).
    @discardableResult
    public func reproject(limit: Int = 256) async throws -> Int {
        let db = try database()
        var placed = 0
        for r in try db.rows("SELECT store_id,key,version FROM resources WHERE status='waiting' LIMIT ?", [.int(Int64(max(1, limit)))]) {
            guard let first = try db.first("SELECT operation FROM parts WHERE store_id=? AND key=? AND version=? ORDER BY part LIMIT 1", [.text(r.text(0)),.text(r.text(1)),.text(r.text(2))]),
                  let bytes = first.data(0) else { continue }
            let p = try check(try JSONDecoder().decode(CloudOperation.self, from: bytes))
            let outcome = try await place(p)
            if outcome.status.1 != "retained_waiting" { placed += 1 }
        }
        return placed
    }

    public func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification {
        let db = try database()
        guard let saved = try db.first("SELECT body FROM receipts WHERE id=?", [.text(receipt.preparationId)])?.data(0),
              try CloudWire.canonical(receipt) == saved else { return .init(verified: false, counts: receipt.counts, reasons: ["The saved import receipt differs."]) }
        var reasons: [String] = []
        for r in try db.rows("""
            SELECT r.raw_hash,r.status,r.destination,r.local_hash,r.kind FROM receipt_resources x JOIN resources r
            ON r.store_id=x.store_id AND r.key=x.key AND r.version=x.version WHERE x.preparation=?
            """, [.text(receipt.preparationId)]) {
            if r.text(4) == "archive" { continue }
            if (try? BackendCloudBrainMemoryHash.file(retainedURL(r.text(0)))) != r.text(0) { reasons.append("A retained copy is missing or changed."); continue }
            guard let destination = r.string(2), let hash = r.string(3) else { continue }
            if (try? BackendCloudBrainMemoryHash.file(URL(fileURLWithPath: destination))) != hash { reasons.append("A placed file does not match what was saved.") }
        }
        return .init(verified: reasons.isEmpty, counts: receipt.counts, reasons: reasons)
    }

    /// For the context-ready barrier: anything still waiting for a destination or for its remaining parts is not ready.
    public func readiness() async throws -> CloudVerification {
        let db = try database()
        let waiting = Int(try db.first("SELECT COUNT(*) FROM resources WHERE status='waiting'")?.int(0) ?? 0)
        let partial = Int(try db.first("""
            SELECT COUNT(*) FROM (SELECT p.store_id,p.key,p.version FROM parts p WHERE p.kind='put' AND NOT EXISTS (SELECT 1 FROM resources r WHERE r.store_id=p.store_id AND
            r.key=p.key AND r.version=p.version) GROUP BY p.store_id,p.key,p.version)
            """)?.int(0) ?? 0)
        let unplaced = Int(try db.first("SELECT COUNT(*) FROM files WHERE pending=1")?.int(0) ?? 0)
        let placed = Int(try db.first("SELECT COUNT(*) FROM resources WHERE status IN ('applied','already_present','kept_both','archived')")?.int(0) ?? 0)
        let blocked = waiting + partial + unplaced
        var reasons: [String] = []
        if waiting > 0 { reasons.append("\(waiting) saved file\(waiting == 1 ? " waits" : "s wait") for a folder on this Mac.") }
        if partial > 0 { reasons.append("\(partial) file\(partial == 1 ? " is" : "s are") still arriving.") }
        if unplaced > 0 { reasons.append("\(unplaced) file\(unplaced == 1 ? " is" : "s are") not placed yet.") }
        return .init(verified: blocked == 0, counts: .init(domains: 1, records: placed, files: placed, bytes: 0, blocked: blocked), reasons: reasons)
    }

    /// Readable archive: every retained version of one logical file, newest first. Opening history never launches anything.
    public func retainedVersions(key: String) throws -> [(version: String, rawHash: String, status: String)] {
        try database().rows("SELECT version,raw_hash,status FROM resources WHERE key=? ORDER BY created_at DESC", [.text(key)]).map { ($0.text(0), $0.text(1), $0.text(2)) }
    }
    public func readRetained(rawHash: String, offset: Int64, limit: Int) throws -> Data {
        guard Self.isHash(rawHash), offset >= 0, (1...1_048_576).contains(limit) else { throw CloudFailure.invalidRequest }
        let handle = try FileHandle(forReadingFrom: retainedURL(rawHash)); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: limit) ?? Data()
    }
}
