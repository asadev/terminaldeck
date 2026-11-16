import Foundation
import Darwin
import TerminalDeckNativeCore

/// One exported or imported file version, as Sendable values only.
struct BackendCloudBrainFilesResource: Sendable {
    let sequence: Int64
    let kind: CloudOperationKind
    let sourceId: String
    let relative: String
    let storeId: String
    let key: String
    let version: String
    let parents: [String]
    let createdAt: Int64
    let rawHash: String
    let rawBytes: Int64
    let originDevice: String
    let projectId: String?
    let rootId: String?
    /// Imported unchanged resources replay the exact original operation bytes.
    let originalOperations: [CloudOperation]?
}

public struct BackendCloudBrainFilesReconcile: Sendable, Equatable {
    public let journaled: Int
    public let archived: Int
    public let remaining: Bool
    public let blocked: [String]
}

public struct BackendCloudBrainFilesLocalChange: Sendable {
    public let operation: CloudOperation
    public let cursor: String
}

/// Wakes change readers after a journal append. Holds no data.
final class BackendCloudBrainFilesHub: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    func stream() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) } }
        }
    }
    func post() { lock.withLock { Array(continuations.values) }.forEach { $0.yield(()) } }
}

/// The shared engine for file-shaped brain rows. One instance per inventory row; one existing owner folder per source.
/// Construction performs no I/O. Its state lives only under `stateRoot` (inside the signed-in identity's Cloud folder).
public actor BackendCloudBrainFiles: CloudDomainAdapter {
    public nonisolated let inventoryRows: [String]
    let row: String
    let deviceId: String
    let stateRoot: URL
    let sources: [BackendCloudBrainFilesSource]
    let pendingCategories: [String]
    /// Incoming records for a folder this Mac does not have (another AI account, an unmapped project) get a
    /// non-walked source from the owner so they are retained and wait for a destination instead of failing the import.
    let dynamicSource: (@Sendable (String) -> BackendCloudBrainFilesSource?)?
    let now: @Sendable () -> Int64
    /// Lane L3 review (14 Nov, cost): `lean` (the Cloud folder only): a received file's part bodies are dropped once it
    /// is assembled and placed, and `sweepRetained` may drop copies no current file or unsent change needs. Every other
    /// row keeps today's behaviour (false).
    let lean: Bool
    nonisolated let hub = BackendCloudBrainFilesHub()
    private var opened: BackendCloudBrainFilesDatabase?
    /// The one rule: parents for the next recorded version of a path ("<source>\n<path>"), used once.
    private var nextParents: [String: [String]] = [:]
    var domain: String { CloudBrainFilesFormat.domain(row) }

    public init(inventoryRow: String, deviceId: String, stateRoot: URL, sources: [BackendCloudBrainFilesSource], pendingCategories: [String] = [],
                dynamicSource: (@Sendable (String) -> BackendCloudBrainFilesSource?)? = nil, lean: Bool = false,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) throws {
        guard CloudBrainFilesFormat.engineRows.contains(inventoryRow), UUID(uuidString: deviceId) != nil, stateRoot.isFileURL, !sources.isEmpty,
              Set(sources.map(\.sourceId)).count == sources.count,
              sources.allSatisfy({ BackendCloudBrainFilesSource.validSourceId($0.sourceId) && $0.root.isFileURL && !$0.include.isEmpty }) else { throw CloudFailure.invalidRequest }
        // The state folder must never sit inside a folder it exports (its retained copies would export themselves).
        let state = stateRoot.standardizedFileURL.path
        guard !sources.contains(where: { state == $0.root.standardizedFileURL.path || state.hasPrefix($0.root.standardizedFileURL.path + "/") }) else { throw CloudFailure.unsafeConfiguration }
        inventoryRows = [inventoryRow]; row = inventoryRow; self.deviceId = deviceId.lowercased(); self.stateRoot = stateRoot
        self.sources = sources; self.pendingCategories = pendingCategories; self.dynamicSource = dynamicSource; self.now = now; self.lean = lean
    }

    func database() throws -> BackendCloudBrainFilesDatabase {
        if let opened { return opened }
        let fm = FileManager.default
        for folder in ["", "retained", "assembling", "conflicts"] {
            try fm.createDirectory(at: stateRoot.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
        }
        let db = try BackendCloudBrainFilesDatabase(path: stateRoot.appendingPathComponent("state.db").path)
        if try db.first("SELECT value FROM control WHERE key='storeId'") == nil {
            try db.run("INSERT INTO control(key,value) VALUES ('storeId',?)", [.text(UUID().uuidString.lowercased())])
        }
        opened = db
        return db
    }
    func storeId() throws -> String { try database().first("SELECT value FROM control WHERE key='storeId'")?.text(0) ?? "" }
    func retainedURL(_ hash: String) -> URL { stateRoot.appendingPathComponent("retained/" + hash) }
    func source(_ id: String) throws -> BackendCloudBrainFilesSource {
        if let found = sources.first(where: { $0.sourceId == id }) { return found }
        guard BackendCloudBrainFilesSource.validSourceId(id), let made = dynamicSource?(id), made.sourceId == id else { throw CloudFailure.invalidRequest }
        return made
    }
    static func json(_ values: [String]) -> String { String(decoding: (try? JSONEncoder().encode(values)) ?? Data("[]".utf8), as: UTF8.self) }
    static func strings(_ text: String) -> [String] { (try? JSONDecoder().decode([String].self, from: Data(text.utf8))) ?? [] }

    // MARK: Inventory

    public func sourceInventory() async throws -> [CloudSourceInventory] {
        var out: [CloudSourceInventory] = []
        for source in sources {
            let walk = BackendCloudBrainFilesWalk.run(source)
            out.append(.init(sourceId: "files/" + row + "/" + source.sourceId, inventoryRow: row, domain: domain, items: walk.files.count,
                             bytes: walk.bytes, complete: walk.blocked.isEmpty, blockedReasons: walk.blocked))
        }
        if !pendingCategories.isEmpty {
            // Source categories of this row that are not built yet keep the row visibly incomplete; never a silent zero.
            out.append(.init(sourceId: "files/" + row + "/not-built", inventoryRow: row, domain: domain, items: 0, bytes: 0,
                             complete: false, blockedReasons: pendingCategories))
        }
        return out
    }

    // MARK: Local capture

    /// Bounded reconciliation against stored hashes. Called by existing file watchers, wake and overflow handling
    /// (with `paths` when the watcher knows them). Hashes at most `limit` changed files per call.
    @discardableResult
    public func reconcile(sourceId: String? = nil, paths: [String]? = nil, limit: Int = 512) async throws -> BackendCloudBrainFilesReconcile {
        guard limit > 0 else { throw CloudFailure.invalidRequest }
        let db = try database()
        var journaled = 0, archived = 0, remaining = false, blocked: [String] = []
        for source in sources where sourceId == nil || source.sourceId == sourceId {
            let walk = BackendCloudBrainFilesWalk.run(source)
            blocked += walk.blocked
            let present = Set(walk.files)
            for relative in walk.files where paths == nil || paths!.contains(relative) {
                if journaled >= limit { remaining = true; break }
                if try capture(source, relative: relative, db: db) { journaled += 1 }
            }
            // Removal is inferred only from a complete, reliable walk; an unreadable or missing folder never archives anything.
            guard !remaining, walk.reliable else { continue }
            for r in try db.rows("SELECT path,store_id,key,version,raw_hash,project_id,root_id FROM files WHERE source_id=? AND archived=0 AND pending=0", [.text(source.sourceId)]) {
                let relative = r.text(0)
                guard !present.contains(relative), paths == nil || paths!.contains(relative) else { continue }
                // A file that is still there but now excluded (for example it became binary in a text-only row) is not a removal.
                if FileManager.default.fileExists(atPath: source.root.appendingPathComponent(relative).path) { continue }
                let version = UUID().uuidString.lowercased(), at = now()
                try db.transaction {
                    try db.run("INSERT INTO journal(kind,source_id,path,store_id,key,version,parents,created_at,raw_hash,raw_bytes,project_id,root_id) VALUES ('archive',?,?,?,?,?,?,?,?,0,?,?)",
                               [.text(source.sourceId),.text(relative),.text(r.text(1)),.text(r.text(2)),.text(version),.text(Self.json([r.text(3)])),.int(at),.text(r.text(4)),.optional(r.string(5)),.optional(r.string(6))])
                    try db.run("UPDATE files SET archived=1,version=?,parents=?,created_at=?,imported=0,origin_device=? WHERE source_id=? AND path=?",
                               [.text(version),.text(Self.json([r.text(3)])),.int(at),.text(deviceId),.text(source.sourceId),.text(relative)])
                }
                archived += 1
            }
        }
        if journaled + archived > 0 { hub.post() }
        return .init(journaled: journaled, archived: archived, remaining: remaining, blocked: blocked)
    }

    /// Retains an immutable copy before journaling. Returns true when a new version was journaled.
    private func capture(_ source: BackendCloudBrainFilesSource, relative: String, db: BackendCloudBrainFilesDatabase) throws -> Bool {
        let url = source.root.appendingPathComponent(relative)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let previous = try db.first("SELECT hash,bytes,mtime,version,store_id,key,archived,pending,created_at FROM files WHERE source_id=? AND path=?", [.text(source.sourceId),.text(relative)])
        if let previous, previous.int(7) == 1 {
            // An import is still being placed here. Its own bytes are not a local edit.
            if (try? BackendCloudBrainMemoryHash.file(url)) == previous.text(0) {
                try db.run("UPDATE files SET pending=0,bytes=?,mtime=? WHERE source_id=? AND path=?", [.int(size),.real(mtime),.text(source.sourceId),.text(relative)])
            }
            return false
        }
        if let previous, previous.int(6) == 0, previous.int(1) == size, previous.double(2) == mtime { return false }
        let hash = try BackendCloudBrainMemoryHash.file(url)
        if let previous, previous.int(6) == 0, previous.text(0) == hash {
            try db.run("UPDATE files SET bytes=?,mtime=? WHERE source_id=? AND path=?", [.int(size),.real(mtime),.text(source.sourceId),.text(relative)])
            return false
        }
        try retain(url, hash: hash)
        // An external editor writing during the copy must not produce a mixed version.
        guard try BackendCloudBrainMemoryHash.file(url) == hash else { throw CloudFailure.versionChanged }
        let version = UUID().uuidString.lowercased()
        var at = now()
        if let modified = source.modifiedAt?(relative) {
            at = CloudBootFilesRules.clamp(modified, agreedAt: previous.map { $0.int(8) }, now: at)
        }
        // The one rule: a version recorded beside the one this copy holds (both made apart) names that one's parents.
        let parents = nextParents.removeValue(forKey: source.sourceId + "\n" + relative) ?? previous.map { [$0.text(3)] } ?? []
        let store: String
        if let previous { store = previous.text(4) } else { store = try storeId() }
        let key = previous?.text(5) ?? "file/" + source.sourceId + "/" + relative
        let identity = source.project?(relative)
        try db.transaction {
            try db.run("INSERT INTO journal(kind,source_id,path,store_id,key,version,parents,created_at,raw_hash,raw_bytes,project_id,root_id) VALUES ('put',?,?,?,?,?,?,?,?,?,?,?)",
                       [.text(source.sourceId),.text(relative),.text(store),.text(key),.text(version),.text(Self.json(parents)),.int(at),.text(hash),.int(size),
                        .optional(identity?.projectId),.optional(identity?.rootId)])
            try db.run("""
                INSERT INTO files(source_id,path,hash,bytes,mtime,store_id,key,version,parents,created_at,raw_hash,raw_bytes,origin_device,imported,archived,pending,project_id,root_id)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,0,0,0,?,?) ON CONFLICT(source_id,path) DO UPDATE SET hash=excluded.hash,bytes=excluded.bytes,mtime=excluded.mtime,
                store_id=excluded.store_id,key=excluded.key,version=excluded.version,parents=excluded.parents,created_at=excluded.created_at,raw_hash=excluded.raw_hash,
                raw_bytes=excluded.raw_bytes,origin_device=excluded.origin_device,imported=0,archived=0,pending=0,project_id=excluded.project_id,root_id=excluded.root_id
                """, [.text(source.sourceId),.text(relative),.text(hash),.int(size),.real(mtime),.text(store),.text(key),.text(version),.text(Self.json(parents)),.int(at),
                      .text(hash),.int(size),.text(deviceId),.optional(identity?.projectId),.optional(identity?.rootId)])
        }
        return true
    }

    /// Hash-named immutable copy; written to a temporary name, synchronised, verified, then renamed into place.
    func retain(_ file: URL, hash: String) throws {
        let target = retainedURL(hash)
        if FileManager.default.fileExists(atPath: target.path) {
            guard try BackendCloudBrainMemoryHash.file(target) == hash else { throw CloudFailure.checksumMismatch }
            return
        }
        let temporary = stateRoot.appendingPathComponent("assembling/" + UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: temporary)
        do {
            try BackendCloudBrainMemoryHash.synchronize(temporary)
            guard try BackendCloudBrainMemoryHash.file(temporary) == hash else { throw CloudFailure.versionChanged }
            if rename(temporary.path, target.path) != 0 { throw CloudFailure.unavailable }
            try BackendCloudBrainMemoryHash.synchronizeDirectory(target.deletingLastPathComponent())
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    // MARK: Versions (the one rule)

    /// Parents for the next version recorded of a path, in place of "the version the copy holds". Used once.
    func setNextParents(sourceId: String, relative: String, parents: [String]) { nextParents[sourceId + "\n" + relative] = parents }

    /// Sends this Mac's current version of a path again as a new version on top of itself, with the SAME bytes and the
    /// SAME time, so another Mac that no longer lists the clash decides it again by the one rule. false when none.
    @discardableResult
    func resend(sourceId: String, relative: String) throws -> Bool {
        let db = try database()
        guard let r = try db.first("""
            SELECT store_id,key,version,created_at,raw_hash,raw_bytes,project_id,root_id FROM files WHERE source_id=? AND path=? AND archived=0 AND pending=0
            """, [.text(sourceId), .text(relative)]) else { return false }
        let version = UUID().uuidString.lowercased(), parents = Self.json([r.text(2)])
        try db.transaction {
            try db.run("INSERT INTO journal(kind,source_id,path,store_id,key,version,parents,created_at,raw_hash,raw_bytes,project_id,root_id) VALUES ('put',?,?,?,?,?,?,?,?,?,?,?)",
                       [.text(sourceId),.text(relative),.text(r.text(0)),.text(r.text(1)),.text(version),.text(parents),.int(r.int(3)),.text(r.text(4)),.int(r.int(5)),
                        .optional(r.string(6)),.optional(r.string(7))])
            try db.run("UPDATE files SET version=?,parents=?,imported=0,origin_device=? WHERE source_id=? AND path=?",
                       [.text(version),.text(parents),.text(deviceId),.text(sourceId),.text(relative)])
        }
        hub.post()
        return true
    }

    /// One version of one path as this engine holds it: this Mac's current one, or one that arrived.
    struct VersionInfo: Sendable, Equatable {
        let version: String
        let parents: [String]
        let createdAt: Int64
        let rawHash: String
        let originDevice: String
    }
    /// The version this Mac's copy holds now for a path (nil when none, or removed).
    func currentVersion(sourceId: String, relative: String) throws -> VersionInfo? {
        try database().first("SELECT version,parents,created_at,raw_hash,origin_device FROM files WHERE source_id=? AND path=? AND archived=0",
                             [.text(sourceId), .text(relative)]).map {
            VersionInfo(version: $0.text(0), parents: Self.strings($0.text(1)), createdAt: $0.int(2), rawHash: $0.text(3), originDevice: $0.text(4))
        }
    }
    /// Lane L3 (Cloud folder): a removal that ARRIVED was applied here by its owner (the copy's file is gone). The path's
    /// row takes the removal's version and is marked removed, so the next look never sends a removal of its own for it
    /// (no echo) and a file made at that path later is recorded on top of the removal (a put back). false when none.
    @discardableResult
    func adoptRemoval(sourceId: String, relative: String, version: String, parents: [String], createdAt: Int64, originDevice: String) throws -> Bool {
        let db = try database()
        guard try db.first("SELECT 1 FROM files WHERE source_id=? AND path=? AND archived=0", [.text(sourceId), .text(relative)]) != nil else { return false }
        try db.run("UPDATE files SET archived=1,version=?,parents=?,created_at=?,imported=1,origin_device=? WHERE source_id=? AND path=?",
                   [.text(version), .text(Self.json(parents)), .int(createdAt), .text(originDevice.lowercased()), .text(sourceId), .text(relative)])
        return true
    }
    /// The bytes of a version this engine holds (retained after capture or arrival), or nil when not held here.
    func retainedBytes(_ rawHash: String) -> Data? {
        guard Self.isHash(rawHash), let data = try? Data(contentsOf: retainedURL(rawHash)), BackendCloudBrainMemoryHash.bytes(data) == rawHash else { return nil }
        return data
    }
    /// The newest arrived version of a path with these bytes (kept beside or applied).
    func arrivedVersion(sourceId: String, relative: String, rawHash: String) throws -> VersionInfo? {
        try database().first("""
            SELECT version,parents,created_at,raw_hash,origin_device FROM resources WHERE source_id=? AND relative=? AND raw_hash=? AND kind='put'
            ORDER BY created_at DESC LIMIT 1
            """, [.text(sourceId), .text(relative), .text(rawHash)]).map {
            VersionInfo(version: $0.text(0), parents: Self.strings($0.text(1)), createdAt: $0.int(2), rawHash: $0.text(3), originDevice: $0.text(4))
        }
    }
    /// The latest stamp among these versions of a path, from this Mac's own journal and what arrived. nil when none is held.
    func latestTime(sourceId: String, relative: String, versions: [String]) throws -> Int64? {
        let db = try database()
        var latest: Int64?
        for version in Set(versions) {
            let own = try db.first("SELECT MAX(created_at) FROM journal WHERE source_id=? AND path=? AND version=?", [.text(sourceId), .text(relative), .text(version)])
            let came = try db.first("SELECT MAX(created_at) FROM resources WHERE source_id=? AND relative=? AND version=?", [.text(sourceId), .text(relative), .text(version)])
            for row in [own, came].compactMap({ $0 }) where !row.isNull(0) { latest = max(latest ?? row.int(0), row.int(0)) }
        }
        return latest
    }

    // MARK: Export

    func journalResource(after sequence: Int64) throws -> BackendCloudBrainFilesResource? {
        guard let r = try database().first("SELECT seq,kind,source_id,path,store_id,key,version,parents,created_at,raw_hash,raw_bytes,project_id,root_id FROM journal WHERE seq>? ORDER BY seq LIMIT 1", [.int(sequence)]) else { return nil }
        return .init(sequence: r.int(0), kind: r.text(1) == "archive" ? .archive : .put, sourceId: r.text(2), relative: r.text(3), storeId: r.text(4), key: r.text(5),
                     version: r.text(6), parents: Self.strings(r.text(7)), createdAt: r.int(8), rawHash: r.text(9), rawBytes: r.int(10), originDevice: deviceId,
                     projectId: r.string(11), rootId: r.string(12), originalOperations: nil)
    }
    /// Brings the local state current (no hashing limit) and returns the journal watermark of the cut.
    func snapshotBegin() async throws -> Int64 {
        while try await reconcile(limit: 4096).remaining {}
        return try database().first("SELECT COALESCE(MAX(seq),0) FROM journal")?.int(0) ?? 0
    }
    func snapshotResource(after rowid: Int64) throws -> (BackendCloudBrainFilesResource, Int64)? {
        let db = try database()
        guard let r = try db.first("SELECT rowid,source_id,path,store_id,key,version,parents,created_at,raw_hash,raw_bytes,origin_device,imported,project_id,root_id FROM files WHERE rowid>? AND archived=0 AND pending=0 ORDER BY rowid LIMIT 1", [.int(rowid)]) else { return nil }
        var original: [CloudOperation]?
        if r.int(11) == 1 {
            let bodies = try db.rows("SELECT operation FROM parts WHERE store_id=? AND key=? AND version=? ORDER BY part", [.text(r.text(3)),.text(r.text(4)),.text(r.text(5))])
            // Lean engines only (the Cloud folder): the bodies were dropped after placing, so the operations are made
            // again from the retained copy. Every other row takes the unchanged path below.
            if lean, bodies.contains(where: { ($0.data(0) ?? Data()).isEmpty }) { original = nil }
            else { original = try bodies.map { try JSONDecoder().decode(CloudOperation.self, from: $0.data(0) ?? Data()) } }
            if original?.isEmpty == true { original = nil }
        }
        return (.init(sequence: 0, kind: .put, sourceId: r.text(1), relative: r.text(2), storeId: r.text(3), key: r.text(4), version: r.text(5), parents: Self.strings(r.text(6)),
                      createdAt: r.int(7), rawHash: r.text(8), rawBytes: r.int(9), originDevice: r.text(10), projectId: r.string(12), rootId: r.string(13), originalOperations: original), r.int(0))
    }
    func coverage() async throws -> [CloudCoverage] {
        try await sourceInventory().map { .init(sourceId: $0.sourceId, inventoryRow: $0.inventoryRow, complete: $0.complete, items: $0.items, bytes: $0.bytes, blockedReasons: $0.blockedReasons) }
    }
    /// Deterministic: the same version always yields the same operation bytes, so retries and re-snapshots deduplicate by id.
    func operation(_ resource: BackendCloudBrainFilesResource, index: Int) throws -> (CloudOperation, Int) {
        if let original = resource.originalOperations {
            guard original.indices.contains(index) else { throw CloudFailure.invalidRequest }
            return (original[index], original.count)
        }
        if resource.kind == .archive {
            let marker = CloudBrainFilesArchiveMarker(storeId: resource.storeId, inventoryRow: row, key: resource.key, version: resource.version,
                                                      resourceHash: resource.rawHash, parents: resource.parents)
            let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(marker))
            let revision = BackendCloudBrainMemoryHash.operationId(resource.version + "\narchive")
            let op = CloudOperation(v: 1, opId: revision, originDevice: resource.originDevice, domain: domain,
                                    entityId: BackendCloudBrainMemoryHash.uuid(resource.storeId + "\n" + resource.key + "\narchive"), revision: revision,
                                    parents: resource.parents.map { BackendCloudBrainMemoryHash.operationId($0 + "\narchive") }, kind: .archive,
                                    projectId: resource.projectId, rootId: resource.rootId,
                                    source: .init(sourceId: "files/" + row + "/" + resource.sourceId, recordId: resource.key, offset: nil, rawHash: resource.rawHash),
                                    createdAt: resource.createdAt, payload: value, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
            return (op, 1)
        }
        let size = CloudBrainFilesFormat.partBytes
        guard resource.rawBytes >= 0, resource.rawBytes <= Int64(Int.max - size) else { throw CloudFailure.unsupportedFormat }
        let count = max(1, (Int(resource.rawBytes) + size - 1) / size)
        guard index >= 0, index < count else { throw CloudFailure.invalidRequest }
        let handle = try FileHandle(forReadingFrom: retainedURL(resource.rawHash)); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(index * size))
        let bytes = try handle.read(upToCount: size) ?? Data()
        guard bytes.count == min(size, Int(resource.rawBytes) - index * size) || (resource.rawBytes == 0 && bytes.isEmpty) else { throw CloudFailure.checksumMismatch }
        let part = CloudBrainMemoryPart(storeId: resource.storeId, inventoryRow: row, key: resource.key, version: resource.version, resourceHash: resource.rawHash,
                                        bytes: String(resource.rawBytes), index: index, count: count, parents: resource.parents, data: bytes.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(part))
        let revision = BackendCloudBrainMemoryHash.operationId(resource.version + "\n" + String(index))
        let op = CloudOperation(v: 1, opId: revision, originDevice: resource.originDevice, domain: domain,
                                entityId: BackendCloudBrainMemoryHash.uuid(resource.storeId + "\n" + resource.key + "\n" + String(index)), revision: revision,
                                parents: resource.parents.map { BackendCloudBrainMemoryHash.operationId($0 + "\n" + String(index)) }, kind: .put,
                                projectId: resource.projectId, rootId: resource.rootId,
                                source: .init(sourceId: "files/" + row + "/" + resource.sourceId, recordId: resource.key, offset: Int64(index * size), rawHash: resource.rawHash),
                                createdAt: resource.createdAt, payload: value, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
        return (op, count)
    }

    public func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
        // A large owner folder must never be accumulated into one unbounded page.
        throw CloudFailure.unsupportedFormat
    }
    public func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
        let reader = BackendCloudBrainFilesPages(engine: self, cut: cut)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
    public func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> {
        // Subscribe before the first journal read, so a change between read and wait still wakes the reader.
        let reader = BackendCloudBrainFilesChanges(engine: self, after: after, notices: hub.stream())
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
    /// Pump support: the cursor (`sequence:nextPart`) stays outside immutable operation bytes.
    public func localChange(after: String?) async throws -> BackendCloudBrainFilesLocalChange? {
        let fields = (after ?? "0:0").split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let sequence = Int64(fields[0]), sequence >= 0, let nextPart = Int(fields[1]), nextPart >= 0 else { throw CloudFailure.invalidRequest }
        var resource = try journalResource(after: sequence == 0 ? 0 : sequence - 1)
        var index = resource?.sequence == sequence ? nextPart : 0
        while let current = resource {
            let (_, count) = try operation(current, index: 0)
            guard index <= count else { throw CloudFailure.invalidRequest }
            if index == count { resource = try journalResource(after: current.sequence); index = 0; continue }
            let (op, _) = try operation(current, index: index)
            return .init(operation: op, cursor: String(current.sequence) + ":" + String(index + 1))
        }
        return nil
    }
    /// Lane L3 review (cost, lean engines only): drops retained copies nothing needs any more: not the bytes of a
    /// current file, not a change still to be handed to the outbox (journal at or after the saved cursor), and not a
    /// version that arrived since the previous sweep (so an import's verification always finds its copy). Kept-beside
    /// copies (`conflicts/`) of versions placed before the previous sweep go too. Returns how many copies were dropped.
    @discardableResult
    func sweepRetained() throws -> Int {
        guard lean else { return 0 }
        let db = try database(), fm = FileManager.default
        var keep = Set(try db.rows("SELECT raw_hash FROM files WHERE archived=0").map { $0.text(0) })
        let cursors = try db.rows("SELECT value FROM cursors").compactMap { Int64($0.text(0).split(separator: ":").first ?? "") }
        let from = cursors.min() ?? 0
        keep.formUnion(try db.rows("SELECT raw_hash FROM journal WHERE seq>=?", [.int(from)]).map { $0.text(0) })
        let watermark = Int64(try db.first("SELECT value FROM control WHERE key='leanSweptRowid'")?.text(0) ?? "0") ?? 0
        keep.formUnion(try db.rows("SELECT raw_hash FROM resources WHERE rowid>? OR status='waiting'", [.int(watermark)]).map { $0.text(0) })
        var dropped = 0
        let retained = stateRoot.appendingPathComponent("retained", isDirectory: true)
        for name in (try? fm.contentsOfDirectory(atPath: retained.path)) ?? [] where Self.isHash(name) && !keep.contains(name) {
            if (try? fm.removeItem(at: retained.appendingPathComponent(name))) != nil { dropped += 1 }
        }
        let conflicts = stateRoot.appendingPathComponent("conflicts", isDirectory: true).standardizedFileURL.path
        for row in try db.rows("SELECT destination FROM resources WHERE status='kept_both' AND rowid<=? AND destination IS NOT NULL", [.int(watermark)]) {
            let kept = URL(fileURLWithPath: row.text(0)).standardizedFileURL
            guard kept.path.hasPrefix(conflicts + "/") else { continue }
            try? fm.removeItem(at: kept.deletingLastPathComponent())
        }
        let top = try db.first("SELECT COALESCE(MAX(rowid),0) FROM resources")?.int(0) ?? 0
        try db.run("INSERT OR REPLACE INTO control(key,value) VALUES ('leanSweptRowid',?)", [.text(String(top))])
        return dropped
    }
    /// Lean engines only (the Cloud folder): the owner put an ARRIVED version into its source itself (the newer of two
    /// versions made apart). The path's row takes that version as an import, so the next reconcile finds the same bytes
    /// and journals nothing: an arrival is never captured as a local change (no echo, no upload). false when not lean,
    /// or the bytes there are not that version's.
    @discardableResult
    func adoptArrival(sourceId: String, relative: String, version: String, parents: [String], createdAt: Int64, rawHash: String,
                      rawBytes: Int64, originDevice: String) throws -> Bool {
        guard lean, let source = sources.first(where: { $0.sourceId == sourceId }) else { return false }
        let url = source.root.appendingPathComponent(relative)
        guard (try? BackendCloudBrainMemoryHash.file(url)) == rawHash,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? rawBytes
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let db = try database()
        guard try db.first("SELECT 1 FROM files WHERE source_id=? AND path=?", [.text(sourceId), .text(relative)]) != nil else { return false }
        try db.run("""
            UPDATE files SET hash=?,bytes=?,mtime=?,version=?,parents=?,created_at=?,raw_hash=?,raw_bytes=?,origin_device=?,imported=1,archived=0,pending=0
            WHERE source_id=? AND path=?
            """, [.text(rawHash), .int(size), .real(mtime), .text(version), .text(Self.json(parents)), .int(createdAt), .text(rawHash), .int(rawBytes),
                  .text(originDevice.lowercased()), .text(sourceId), .text(relative)])
        return true
    }
    /// Tests: what the part table still holds (bodies and operations), in bytes.
    func storedPartBytes() throws -> Int64 {
        try database().first("SELECT COALESCE(SUM(length(body)+length(operation)),0) FROM parts WHERE kind='put'")?.int(0) ?? 0
    }
    public func savedLocalCursor(scope: String) throws -> String? {
        try database().first("SELECT value FROM cursors WHERE scope=?", [.text(scope)])?.string(0)
    }
    public func saveLocalCursor(_ cursor: String, scope: String) throws {
        try database().run("INSERT INTO cursors(scope,value) VALUES (?,?) ON CONFLICT(scope) DO UPDATE SET value=excluded.value", [.text(scope),.text(cursor)])
    }
    public nonisolated func localNotices() -> AsyncStream<Void> { hub.stream() }
}

private actor BackendCloudBrainFilesPages {
    let engine: BackendCloudBrainFiles, cut: CloudSnapshotCut
    var watermark: Int64?
    var rowid: Int64 = 0
    var resource: BackendCloudBrainFilesResource?
    var index = 0
    var finished = false
    init(engine: BackendCloudBrainFiles, cut: CloudSnapshotCut) { self.engine = engine; self.cut = cut }
    func next() async throws -> CloudDomainSnapshot? {
        guard !finished else { return nil }
        if watermark == nil { watermark = try await engine.snapshotBegin() }
        if resource == nil {
            guard let pair = try await engine.snapshotResource(after: rowid) else {
                finished = true
                let row = engine.inventoryRows[0]
                return .init(cut: .init(snapshotId: cut.snapshotId, at: cut.at, watermarks: ["files/" + row: String(watermark ?? 0)]),
                             operations: [], files: [], coverage: try await engine.coverage())
            }
            resource = pair.0; rowid = pair.1; index = 0
        }
        let current = resource!
        let (op, count) = try await engine.operation(current, index: index)
        index += 1
        if index >= count { resource = nil }
        return .init(cut: cut, operations: [op], files: [], coverage: [])
    }
}

private actor BackendCloudBrainFilesChanges {
    let engine: BackendCloudBrainFiles
    var notices: AsyncStream<Void>.Iterator
    var sequence: Int64 = 0
    var resource: BackendCloudBrainFilesResource?
    var index = 0
    var invalidCursor = false
    init(engine: BackendCloudBrainFiles, after: String?, notices: AsyncStream<Void>) {
        self.engine = engine; self.notices = notices.makeAsyncIterator()
        if let after { if let n = Int64(after), n >= 0 { sequence = n } else { invalidCursor = true } }
    }
    func next() async throws -> CloudOperation? {
        if invalidCursor { throw CloudFailure.invalidRequest }
        while !Task.isCancelled {
            if resource == nil, let found = try await engine.journalResource(after: sequence) { resource = found; index = 0 }
            if let current = resource {
                let (op, count) = try await engine.operation(current, index: index)
                index += 1
                if index >= count { sequence = current.sequence; resource = nil }
                return op
            }
            var iterator = notices
            guard await iterator.next(isolation: self) != nil else { return nil }
            notices = iterator
        }
        return nil
    }
}

/// Moves the engine's durable journal into SYNC's durable outbox; no network, scheduler or second data writer.
public actor BackendCloudBrainFilesPump {
    private let engine: BackendCloudBrainFiles
    private let outbox: any CloudOutboxPort
    private let scope: String
    private var task: Task<Void, Never>?
    private var draining = false
    public init(engine: BackendCloudBrainFiles, outbox: any CloudOutboxPort, subjectHash: String) throws {
        guard subjectHash.utf8.count == 64, subjectHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CloudFailure.invalidRequest }
        self.engine = engine; self.outbox = outbox; scope = subjectHash
    }
    /// Advances the source cursor only after every returned operation has a durable LocalReceipt.
    @discardableResult public func drainOnce(limit: Int = 16) async throws -> Int {
        guard !draining else { throw CloudFailure.unavailable }
        draining = true; defer { draining = false }
        guard (1...128).contains(limit) else { throw CloudFailure.invalidRequest }
        var cursor = try await engine.savedLocalCursor(scope: scope), operations: [CloudOperation] = []
        while operations.count < limit, let change = try await engine.localChange(after: cursor) {
            operations.append(change.operation); cursor = change.cursor
        }
        guard !operations.isEmpty, let cursor else { return 0 }
        let receipt = try await outbox.enqueue(operations, files: [])
        guard Set(receipt.operationIds) == Set(operations.map(\.opId)) else { throw CloudFailure.checksumMismatch }
        try await engine.saveLocalCursor(cursor, scope: scope)
        return operations.count
    }
    public func start() {
        guard task == nil else { return }
        let notices = engine.localNotices()
        task = Task {
            var iterator = notices.makeAsyncIterator()
            while !Task.isCancelled {
                do { while try await drainOnce() > 0 { try Task.checkCancellation(); await Task.yield() } }
                catch {}
                // No retry loop on failure: the next owner change, wake or explicit Retry tries again.
                if await iterator.next(isolation: self) == nil { break }
            }
        }
    }
    public func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
