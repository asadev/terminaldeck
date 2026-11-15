import Foundation
import TerminalDeckNativeCore

/// One inventory row, one existing writer. No database connection or provider home is opened by construction.
public actor BackendCloudBrainMemory: CloudDomainAdapter {
    public nonisolated let inventoryRows: [String]
    let store: DeckMemoryStore
    let deviceId: String
    let snapshotRoot: URL
    let row: String
    public init(store: DeckMemoryStore, deviceId: String, inventoryRow: String, snapshotRoot: URL) throws {
        guard UUID(uuidString: deviceId) != nil, CloudBrainMemoryFormat.inventoryRows.contains(inventoryRow), snapshotRoot.isFileURL else { throw CloudFailure.invalidRequest }
        self.store = store; self.deviceId = deviceId; self.row = inventoryRow; self.inventoryRows = [inventoryRow]; self.snapshotRoot = snapshotRoot
    }
    public func sourceInventory() async throws -> [CloudSourceInventory] { [try await store.cloudInventory(row: row)] }
    public func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
        // A large store must never be silently truncated or accumulated into one unbounded array by an old caller.
        throw CloudFailure.unsupportedFormat
    }
    public func snapshotPages(cut: CloudSnapshotCut) async -> AsyncThrowingStream<CloudDomainSnapshot, Error> {
        let reader = BackendCloudBrainMemoryPages(store: store, deviceId: deviceId, row: row, root: snapshotRoot, cut: cut)
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
    public func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> {
        // Subscribe before reading the journal, so the empty-journal → wait boundary cannot drop a notification.
        let reader = BackendCloudBrainMemoryChanges(store: store, deviceId: deviceId, row: row, after: after, notices: store.cloudChanges())
        return AsyncThrowingStream(unfolding: { try await reader.next() })
    }
    public func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
        guard files.isEmpty else { throw CloudFailure.unsupportedFormat }
        guard Set(operations.map(\.opId)).count == operations.count else { throw CloudFailure.idReused }
        for op in operations { _ = try await store.cloudValidatePart(op, row: row) }
        let id = BackendCloudBrainMemoryHash.uuid(BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(operations)))
        return .init(preparationId: id, operations: operations, files: [])
    }
    public func applyPrepared(_ prepared: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
        let checked = try await validateIncoming(prepared.operations, files: prepared.files)
        guard checked.preparationId == prepared.preparationId else { throw CloudFailure.idReused }
        return try await store.cloudApply(prepared, row: row, origin: origin)
    }
    public func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification { try await store.cloudVerify(receipt) }
}

/// Mac-next 2: the record count of this row's first copy, for "Preparing the first copy: X of Y".
extension BackendCloudBrainMemory: CloudDomainSetupEstimating {
    public func setupEstimate(cut: CloudSnapshotCut) async -> Int? {
        let id = BackendCloudBrainMemoryHash.uuid(cut.snapshotId)
        return try? await store.cloudSnapshotEstimate(id: id, destination: snapshotRoot.appendingPathComponent(id), row: row)
    }
}

private actor BackendCloudBrainMemoryPages {
    let store: DeckMemoryStore, deviceId: String, row: String, root: URL, cut: CloudSnapshotCut
    var snapshot: DeckMemoryCloudSnapshot?
    var cursor = DeckMemoryCloudCursor()
    var part: BackendCloudBrainMemoryParts?
    var items = 0, bytes: Int64 = 0, finished = false, materialized = false
    init(store: DeckMemoryStore, deviceId: String, row: String, root: URL, cut: CloudSnapshotCut) {
        self.store = store; self.deviceId = deviceId; self.row = row; self.root = root; self.cut = cut
    }
    func next() async throws -> CloudDomainSnapshot? {
        guard !finished else { return nil }
        if snapshot == nil {
            let id = BackendCloudBrainMemoryHash.uuid(cut.snapshotId)
            snapshot = try await store.cloudBeginSnapshot(id: id, destination: root.appendingPathComponent(id))
        }
        let snapshot = snapshot!
        if !materialized {
            // File bytes are copied into the cut here, on this reader, never on the memory actor (finding 9). Idempotent:
            // a retry of the same cut reuses the copies, so its pages are byte-identical.
            let liveRoot = await store.cloudRootURL()
            try BackendCloudBrainMemorySnapshotFiles.materialize(snapshot, liveRoot: liveRoot)
            materialized = true
        }
        if part == nil {
            let (resource, nextCursor) = try await store.cloudSnapshotResource(snapshot, row: row, cursor: cursor)
            cursor = nextCursor
            guard let resource else {
                finished = true
                try await store.cloudFinishSnapshot(snapshot, row: row)
                return .init(cut: .init(snapshotId: cut.snapshotId, at: cut.at, watermarks: ["memory/" + row: String(snapshot.watermark)]), operations: [], files: [],
                             coverage: [.init(sourceId: "memory/" + row, inventoryRow: row, complete: true, items: items, bytes: bytes, blockedReasons: [],
                                              exclusions: snapshot.exclusions?[row] ?? [])])
            }
            let revision = try await store.cloudExportVersion(key: (resource.originStoreId ?? snapshot.storeId) + ":" + resource.key, hash: resource.hash, baseVersion: resource.baseVersion, row: row, bytes: resource.bytes)
            try await store.cloudRecordExport(resource, storeId: resource.originStoreId ?? snapshot.storeId, version: revision.version, parents: revision.parents)
            part = try BackendCloudBrainMemoryParts(resource: resource, storeId: resource.originStoreId ?? snapshot.storeId, deviceId: deviceId, version: revision.version, parents: revision.parents, createdAt: cut.at)
            items += 1; bytes += resource.bytes
        }
        let proposed = try part!.next()
        let operation = try await store.cloudCanonicalExportOperation(proposed, row: row)
        if part!.finished { part = nil }
        return .init(cut: cut, operations: [operation], files: [], coverage: [])
    }
}

private struct BackendCloudBrainMemoryParts: Sendable {
    let resource: DeckMemoryCloudResource, storeId: String, deviceId: String, version: String, parents: [String], createdAt: Int64
    var index = 0
    let count: Int
    var finished: Bool { index == count }
    init(resource: DeckMemoryCloudResource, storeId: String, deviceId: String, version: String, parents: [String], createdAt: Int64) throws {
        guard resource.bytes >= 0, resource.bytes <= Int64(Int.max - CloudBrainMemoryFormat.partBytes) else { throw CloudFailure.unsupportedFormat }
        self.resource = resource; self.storeId = storeId; self.deviceId = deviceId; self.version = version; self.parents = parents; self.createdAt = createdAt
        count = max(1, (Int(resource.bytes) + CloudBrainMemoryFormat.partBytes - 1) / CloudBrainMemoryFormat.partBytes)
    }
    mutating func next() throws -> CloudOperation {
        guard !finished else { throw CloudFailure.invalidRequest }
        let offset = index * CloudBrainMemoryFormat.partBytes
        let bytes: Data
        if let file = resource.file {
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset)); bytes = try handle.read(upToCount: CloudBrainMemoryFormat.partBytes) ?? Data()
        } else if let data = resource.data { bytes = data.subdata(in: offset..<min(offset + CloudBrainMemoryFormat.partBytes, data.count)) }
        else { throw CloudFailure.unavailable }
        let payload = CloudBrainMemoryPart(storeId: storeId, inventoryRow: resource.row, key: resource.key, version: version, resourceHash: resource.hash, bytes: String(resource.bytes), index: index, count: count, parents: parents, data: bytes.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let entity = BackendCloudBrainMemoryHash.uuid(storeId + "\n" + resource.key + "\n" + String(index))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n" + String(index))
        let op = CloudOperation(v: 1, opId: revision, originDevice: deviceId,
                               domain: CloudBrainMemoryFormat.domain(resource.row), entityId: entity, revision: revision,
                               parents: parents.map { BackendCloudBrainMemoryHash.uuid($0 + "\n" + String(index)) }, kind: .put,
                               source: .init(sourceId: "memory/" + resource.row, recordId: resource.key, offset: Int64(offset), rawHash: resource.hash),
                               createdAt: createdAt, payload: value, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
        index += 1; return op
    }
}

private actor BackendCloudBrainMemoryChanges {
    let store: DeckMemoryStore, deviceId: String, row: String
    var notices: AsyncStream<DeckMemoryChange>.Iterator
    var sequence: Int64 = 0
    var part: BackendCloudBrainMemoryParts?
    var invalidCursor = false
    init(store: DeckMemoryStore, deviceId: String, row: String, after: String?, notices: AsyncStream<DeckMemoryChange>) {
        self.store = store; self.deviceId = deviceId; self.row = row; self.notices = notices.makeAsyncIterator()
        if let after { if let n = Int64(after), n >= 0 { sequence = n } else { invalidCursor = true } }
    }
    func next() async throws -> CloudOperation? {
        if invalidCursor { throw CloudFailure.invalidRequest }
        while !Task.isCancelled {
            if part == nil, let resource = try await store.cloudJournal(after: sequence, row: row) {
                let storeId = try await store.cloudStoreId(), revision = try await store.cloudExportVersion(key: (resource.originStoreId ?? storeId) + ":" + resource.key, hash: resource.hash, baseVersion: resource.baseVersion, row: row, bytes: resource.bytes, sequence: resource.sequence)
                try await store.cloudRecordExport(resource, storeId: resource.originStoreId ?? storeId, version: revision.version, parents: revision.parents)
                part = try .init(resource: resource, storeId: resource.originStoreId ?? storeId, deviceId: deviceId, version: revision.version, parents: revision.parents, createdAt: Int64(Date().timeIntervalSince1970 * 1000))
            }
            if var current = part {
                let proposed = try current.next()
                let operation = try await store.cloudCanonicalExportOperation(proposed, row: row)
                if current.finished { sequence = current.resource.sequence; part = nil } else { part = current }
                return operation
            }
            // Iterator is local while awaiting; no concurrent next() calls are permitted on a pull-driven stream.
            var iterator = notices
            guard let _ = await iterator.next(isolation: self) else { return nil }
            notices = iterator
        }
        return nil
    }
}

public struct BackendCloudBrainMemoryLocalChange: Sendable {
    public let operation: CloudOperation
    public let cursor: String
}

public extension BackendCloudBrainMemory {
    /// Local cursor is deliberately outside immutable cloud operation bytes: retries replay the same operation.
    func localChange(after: String?) async throws -> BackendCloudBrainMemoryLocalChange? {
        let fields = (after ?? "0:0").split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, let sequence = Int64(fields[0]), sequence >= 0, let nextPart = Int(fields[1]), nextPart >= 0 else { throw CloudFailure.invalidRequest }
        var resource = try await store.cloudJournal(after: sequence == 0 ? 0 : sequence - 1, row: row)
        var index = resource?.sequence == sequence ? nextPart : 0
        while let current = resource {
            let storeId = try await store.cloudStoreId(), sourceId = current.originStoreId ?? storeId
            let revision = try await store.cloudExportVersion(key: sourceId + ":" + current.key, hash: current.hash, baseVersion: current.baseVersion, row: row, bytes: current.bytes, sequence: current.sequence)
            var parts = try BackendCloudBrainMemoryParts(resource: current, storeId: sourceId, deviceId: deviceId, version: revision.version, parents: revision.parents, createdAt: Int64(Date().timeIntervalSince1970 * 1000))
            guard index <= parts.count else { throw CloudFailure.invalidRequest }
            if index == parts.count { resource = try await store.cloudJournal(after: current.sequence, row: row); index = 0; continue }
            parts.index = index
            try await store.cloudRecordExport(current, storeId: sourceId, version: revision.version, parents: revision.parents)
            let proposed = try parts.next(), operation = try await store.cloudCanonicalExportOperation(proposed, row: row)
            // A finished resource moves the cursor past its journal row ("next:0"), so the prune after queueing removes
            // that row too; otherwise the last queued row stayed in the journal for ever and the reconcile's R1 wait
            // ("nothing of this row still waiting") could never be met on a quiet Mac.
            return .init(operation: operation, cursor: parts.finished ? String(current.sequence + 1) + ":0" : String(current.sequence) + ":" + String(parts.index))
        }
        return nil
    }
    func savedLocalCursor(scope: String) async throws -> String? { try await store.cloudLocalCursor(scope: scope, row: row) }
    /// Saves the cursor, then drops journal rows that are now durably in SYNC's outbox (finding 8).
    func saveLocalCursor(_ cursor: String, scope: String) async throws {
        try await store.cloudSaveLocalCursor(cursor, scope: scope, row: row)
        if let sequence = cursor.split(separator: ":").first.flatMap({ Int64($0) }) { try await store.cloudPruneJournal(row: row, before: sequence) }
    }
    /// One bounded maintenance step (store-wide): notice/heal a dropped capture (M1) and advance the rows and files
    /// reconcile, so watchers and saves never scan the folder themselves.
    func reconcileFiles(limit: Int = 64) async throws -> Int { try await store.cloudMaintenanceStep(limit: limit) }
    func localPumpProblem(_ failed: Bool, scope: String) async throws { try await store.cloudPumpProblem(failed, scope: scope, row: row) }
    nonisolated func localNotices() -> AsyncStream<DeckMemoryChange> { store.cloudChanges() }
}


/// Copies a cut's files into its snapshot folder off the memory actor, once each. A file removed before it was copied
/// gets a marker so a retry of the same cut never picks up later bytes; a file that changes while being copied is retried.
enum BackendCloudBrainMemorySnapshotFiles {
    static func materialize(_ snapshot: DeckMemoryCloudSnapshot, liveRoot: URL) throws {
        let fm = FileManager.default
        for path in snapshot.files {
            let target = try DeckMemoryCloudSchema.safePath(path, root: snapshot.root)
            let missing = snapshot.root.appendingPathComponent(".cloud-missing/" + BackendCloudBrainMemoryHash.uuid(path))
            if fm.fileExists(atPath: target.path) || fm.fileExists(atPath: missing.path) { continue }
            let source: URL
            if path.hasPrefix("prior-roots/") {
                let parts = path.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, let base = snapshot.sources?[String(parts[0]) + "/" + String(parts[1])] else { throw CloudFailure.invalidRequest }
                source = try DeckMemoryCloudSchema.safePath(String(parts[2]), root: URL(fileURLWithPath: base, isDirectory: true))
            } else {
                // M5: a file that became a link after the cut is skipped like a removed one; it never aborts the cut.
                do { source = try DeckMemoryCloudSchema.safePath(path, root: liveRoot) }
                catch CloudFailure.unsafeConfiguration {
                    try fm.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data().write(to: missing, options: .atomic); continue
                }
            }
            guard fm.fileExists(atPath: source.path), (try? fm.destinationOfSymbolicLink(atPath: source.path)) == nil else {
                try fm.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: missing, options: .atomic); continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var copied = false
            for _ in 0..<3 where !copied {
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".cloud-copy-" + UUID().uuidString)
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: source, to: temporary)
                try BackendCloudBrainMemoryHash.synchronize(temporary)
                if try BackendCloudBrainMemoryHash.file(temporary) == BackendCloudBrainMemoryHash.file(source) {
                    try fm.moveItem(at: temporary, to: target); copied = true
                }
            }
            guard copied else { throw CloudFailure.versionChanged }
        }
    }
}
