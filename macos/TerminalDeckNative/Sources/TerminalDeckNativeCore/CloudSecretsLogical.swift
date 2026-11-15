import Foundation

public protocol CloudSecretsLogicalStore: Sendable {
    var sourceId: String { get }
    var inventoryRow: String { get }
    var domain: CloudSecretsDomain { get }
    func capture() async throws -> [CloudSecretRecord]
    func validate(_ record: CloudSecretRecord) async throws
    /// Must atomically keep an existing different local value. Conflict bytes
    /// remain in the encrypted incoming operation; they are never discarded.
    func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool
}

/// A store that lists removals made on another device instead of applying them.
public protocol CloudSecretsRemovalListing: Sendable {
    func listRemoval(recordId: String) async throws
}

/// Delete metadata is carried only inside the existing saved-passwords seal. `version` names exactly the
/// removed logical edit (an opaque UUID; a keyed fingerprint for an unversioned local value), never a date. The backend uses CloudDeleteTravel's six fields.
public struct CloudSecretRemoval: Codable, Equatable, Sendable {
    public let sourceId: String
    public let recordId: String
    public let domain: String
    public let version: String
    public let removedDigest: String?
    public let fields: [String: String]
    public let mac: String
    public let macName: String
    public let at: Int64
    /// Lets a newly joined Mac identify the destination and compare its file without an earlier ledger. Still
    /// entirely inside the saved-passwords pack; an erased local Bin may retain only the opaque tombstone.
    public let removed: CloudSecretRecord?
    public init(sourceId: String, recordId: String, domain: String, version: String, fields: [String: String], mac: String, macName: String, at: Int64, removed: CloudSecretRecord? = nil, removedDigest: String? = nil) {
        self.sourceId = sourceId; self.recordId = recordId; self.domain = domain; self.version = version
        self.fields = fields; self.mac = mac; self.macName = macName; self.at = at; self.removed = removed; self.removedDigest = removedDigest
    }
}

/// A deliberate Put back / Put in Cloud again must be distinguishable from replaying the old put. This
/// wrapper exists only inside the saved-passwords seal; ordinary puts keep their old wire form ALWAYS, also while
/// the gate is open (decision 6): an owner returns a version only for a deliberate Put back made on this Mac.
private struct CloudSecretVersionedPut: Codable {
    let record: CloudSecretRecord
    let version: String
    let removalGroup: String?
}

/// Only owners with a sealed local Bin may opt in. No inference from an absent record happens in the adapter.
public protocol CloudSecretsDeletingStore: CloudSecretsLogicalStore, CloudSecretsKeyedStore {
    func versionForUpload(_ record: CloudSecretRecord) async throws -> String?
    func mergeVersioned(_ record: CloudSecretRecord, version: String, removalGroup: String?) async throws -> CloudApplyStatus
    func republication(recordId: String) async throws -> String?
    func mergeReintroduced(_ record: CloudSecretRecord, removalGroup: String) async throws -> CloudApplyStatus
    func captureRemovals() async throws -> [CloudSecretRemoval]
    func validateRemoval(_ removal: CloudSecretRemoval) async throws
    func mergeRemoval(_ removal: CloudSecretRemoval) async throws -> CloudApplyStatus
    func verifyRemoval(_ removal: CloudSecretRemoval, outcome: CloudApplyStatus) async throws -> Bool
}

/// One source owner per adapter; a payload cannot rename itself to another domain.
public actor CloudSecretsLogicalAdapter: CloudDomainAdapter {
    public nonisolated let inventoryRows: [String]
    public nonisolated let sourceId: String
    public nonisolated let domain: CloudSecretsDomain
    private let store: any CloudSecretsLogicalStore
    private let content: any CloudContentPort
    private let policy: CloudSecretsPolicy
    private let deviceId: String
    private let retainIncomingConflict: @Sendable (CloudOperation) async throws -> Void
    private let keepConflicts: @Sendable ([CloudOperation]) async throws -> CloudLocalReceipt
    private var preparedDigests: [String: String] = [:]
    private var verified: [String: CloudVerification] = [:]
    private var busy = false
    // Keyed fingerprints (root-derived HMAC of the record id and of the record)
    // remain local and are never part of an operation. With a known store they
    // survive restarts, so an app start uploads only what changed (L7).
    private var known: [String: String] = [:]
    private var knownEpoch: Int?
    private var importing: [String: String] = [:]
    private var importingEpoch: Int?
    private var outgoing: [String: (record: String, key: String, digest: String, epoch: Int, queue: String?)] = [:]
    private let knownStore: (any CloudSecretsKnownStore)?
    private var knownSlot: String?
    private var knownDirty = false
    private var knownQueue: String?
    // Queued but not yet confirmed by the cloud (round-6 review: the mark is
    // written only on the cloud's read-back receipt). In memory only: after a
    // restart an unconfirmed record is simply queued once more.
    private var inFlight: [String: (key: String, digest: String, epoch: Int, queue: String?)] = [:]
    // The outbox's identity, set by the service before anything is queued.
    private var queueId: String?
    // Per record: left on this Mac because it is too large to send. Kept until
    // that record changes or disappears.
    private var tooLarge: [String: String] = [:]
    // Records whose sealed size a snapshot has measured exactly.
    private var measured: Set<String> = []
    // Plain reasons, with counts, for incoming items closed without applying.
    private var notes: [String: Int] = [:]
    public func notices() -> [String: Int] { notes }
    /// The person has seen them.
    public func clearNotices() { notes.removeAll() }
    private var watchers: [UUID: AsyncThrowingStream<CloudOperation, Error>.Continuation] = [:]
    public init(store: any CloudSecretsLogicalStore, content: any CloudContentPort, policy: CloudSecretsPolicy, deviceId: String,
                keepConflicts: @escaping @Sendable ([CloudOperation]) async throws -> CloudLocalReceipt,
                retainIncomingConflict: @escaping @Sendable (CloudOperation) async throws -> Void,
                known knownStore: (any CloudSecretsKnownStore)? = nil) {
        self.store = store; self.content = content; self.policy = policy; self.deviceId = deviceId; self.keepConflicts = keepConflicts; self.retainIncomingConflict = retainIncomingConflict
        self.knownStore = knownStore
        inventoryRows = [store.inventoryRow]; sourceId = store.sourceId; domain = store.domain
    }
    private struct Digest {
        let keyed: CloudSecretsFingerprinter?
        func id(_ recordId: String) -> String { mark(Data("id\n".utf8) + Data(recordId.utf8)) }
        func slot(_ sourceId: String) -> String { mark(Data("source\n".utf8) + Data(sourceId.utf8)) }
        func record(_ plain: Data) -> String { mark(Data("record\n".utf8) + plain) }
        private func mark(_ bytes: Data) -> String { keyed.map { $0(bytes) } ?? CloudSecretsCrypto.hash(bytes) }
    }
    /// The outbox's identity (`CloudOutboxPort.outboxIdentity()`); nil when it
    /// cannot state one, and then no mark is kept across restarts.
    public func useOutbox(queue: String?) {
        queueId = queue.flatMap { $0.isEmpty ? nil : $0 }
    }
    /// Plain words for records left on this Mac.
    public func gaps() -> [String] { Array(Set(tooLarge.values)).sorted() }
    /// The sync core's own record limits (CloudWire, set by the sync owner), for
    /// every caller of this adapter: capture, bootstrap pages, "keep both".
    static func fits(_ operation: CloudOperation) throws -> Bool {
        try CloudSecretsCanonical.encode(operation.payload).count <= CloudWire.maximumRecordPayloadBytes
            && CloudSecretsCanonical.encode(operation).count <= CloudWire.maximumRecordBytes
    }
    /// Operations queued but not yet confirmed by the cloud.
    public func pendingOperationIds() -> [String] { Array(inFlight.keys) }
    /// The cloud read these back: only now is "already uploaded" written.
    public func confirmed(operationIds: Set<String>) async {
        for id in operationIds {
            guard let saved = inFlight.removeValue(forKey: id) else { continue }
            knownDirty = true
            if knownEpoch == saved.epoch, knownQueue == saved.queue { setKnown(saved.key, saved.digest) }
        }
        await persistKnown()
    }
    static func tooLargeWords(_ domain: CloudSecretsDomain) -> String {
        let item: String
        switch domain {
        case .apiKey: item = "An API key"
        case .server: item = "A server password or key"
        case .ssh: item = "An SSH file"
        case .mcp: item = "An MCP server"
        case .taskConnection: item = "A task connection token"
        case .receiver: item = "The Receiver's secrets"
        case .browserCookies: item = "A browser sign-in"
        case .browserPassword: item = "A saved browser password"
        case .project: item = "A project's secret settings"
        case .app: item = "An app sign-in"
        case .aiSubscription: item = "An AI subscription sign-in"
        }
        return item + " is too large to save in Cloud. It stays on this Mac."
    }
    private func digest(epoch: Int) async throws -> Digest {
        guard let secrets = content as? CloudSecretsContent else { return Digest(keyed: nil) }
        let label = queueId.map { sourceId + "\nqueue:" + $0 } ?? sourceId
        return Digest(keyed: try await secrets.fingerprinter(label: label, epoch: epoch))
    }
    /// Switch to `epoch` and the current queue: load their durable marks. Marks
    /// persist only with a queue identity, so a lost or rebuilt queue (new
    /// identity, or none) never leaves an unchanged secret skipped. A failed
    /// load only means some records upload again.
    private func useKnown(epoch: Int, marks: Digest) async {
        guard knownEpoch != epoch || knownQueue != queueId else { return }
        knownEpoch = epoch; knownQueue = queueId
        known = [:]; knownDirty = false; inFlight = [:]
        knownSlot = marks.keyed == nil || queueId == nil ? nil : marks.slot(sourceId)
        guard let knownStore, let knownSlot else { return }
        if let saved = try? await knownStore.load(slot: knownSlot, epoch: epoch) {
            known = saved.entries
            for (operation, value) in saved.pending {
                let parts = value.split(separator: "\n", omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                inFlight[operation] = (String(parts[0]), String(parts[1]), epoch, queueId)
            }
        }
    }
    private func setKnown(_ key: String, _ value: String?) {
        guard known[key] != value else { return }
        known[key] = value; knownDirty = true
    }
    private func persistKnown() async {
        // Only keyed fingerprints are written, and only when something changed.
        guard knownDirty, let knownStore, let knownEpoch, let knownSlot else { return }
        let pending = inFlight.mapValues { $0.key + "\n" + $0.digest }
        if (try? await knownStore.save(slot: knownSlot, epoch: knownEpoch, entries: known, pending: pending)) != nil { knownDirty = false }
    }
    public func check(_ record: CloudSecretRecord, stage: CloudSecretsStage) async throws {
        try await policy.require(domain.purpose, stage: stage)
        guard record.sourceId == sourceId, record.domain == domain.rawValue, !record.recordId.isEmpty else { throw CloudFailure.invalidRequest }
        try await store.validate(record)
    }
    /// A keyed store (project secret files) gets this generation's keys before it captures or judges a record; nil
    /// while the key is not here, so it can neither name nor accept anything.
    private func provideKeys() async {
        guard let keyed = store as? any CloudSecretsKeyedStore else { return }
        let state = await content.state(storageClass: .secrets)
        guard state.available, let secrets = content as? CloudSecretsContent else { await keyed.use(keys: nil); return }
        await keyed.use(keys: try? await secrets.storeKeys(label: sourceId, epoch: state.epoch))
    }
    private func encodedRecord(_ record: CloudSecretRecord) async throws -> Data {
        if let owner = store as? any CloudSecretsDeletingStore, let version = try await owner.versionForUpload(record) {
            let group = try await owner.republication(recordId: record.recordId)
            return try CloudSecretsCanonical.encode(CloudSecretVersionedPut(record: record, version: version, removalGroup: group))
        }
        return try CloudSecretsCanonical.encode(record)
    }
    public func exportRecords() async throws -> [CloudSecretRecord] {
        await provideKeys()
        try await policy.require(domain.purpose, stage: .capture)
        guard await content.state(storageClass: .secrets).available else { throw CloudFailure.secretsLocked }
        let records = try await store.capture()
        guard Set(records.map(\.recordId)).count == records.count else { throw CloudFailure.idReused }
        for record in records { try await check(record, stage: .export) }
        return records
    }
    public func sourceInventory() async throws -> [CloudSourceInventory] {
        let all = try await exportRecords()
        tooLarge = tooLarge.filter { id, _ in all.contains { $0.recordId == id } }
        // Right after a start nothing has been measured yet: judge each record
        // by an upper estimate of its sealed size (base64 of the ciphertext plus
        // the envelope), so a too-large one is never counted as saved before a
        // capture measures it exactly (round-7 S-1).
        // A record whose mark shows the cloud already has it is never flagged
        // (round-8 S-1): no capture would ever measure it again to clear it.
        // Locked or no key: no marks to compare, so the estimate alone decides.
        let state = await content.state(storageClass: .secrets)
        var marks: Digest?
        if state.available { marks = try? await self.digest(epoch: state.epoch) }
        if let marks, knownEpoch != state.epoch || knownQueue != queueId { await useKnown(epoch: state.epoch, marks: marks) }
        for record in all where !measured.contains(record.recordId) && tooLarge[record.recordId] == nil {
            let plain = try await encodedRecord(record)
            if let marks, knownEpoch == state.epoch, let mark = known[marks.id(record.recordId)], mark == marks.record(plain) { continue }
            if (plain.count + 2) / 3 * 4 + 1024 > CloudWire.maximumRecordPayloadBytes { tooLarge[record.recordId] = Self.tooLargeWords(domain) }
        }
        // A record left on this Mac is not counted as saved, and the source is
        // not complete while any is left.
        let records = all.filter { tooLarge[$0.recordId] == nil }
        let bytes = try records.reduce(Int64(0)) { try $0 + Int64(CloudSecretsCanonical.encode($1).count) }
        return [.init(sourceId: sourceId, inventoryRow: store.inventoryRow, domain: domain.rawValue,
                      items: records.count, bytes: bytes, complete: tooLarge.isEmpty, blockedReasons: gaps())]
    }
    public func snapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
        let records = try await exportRecords()
        return try await snapshotWithRemovals(records: records, cut: cut)
    }
    public func changedSnapshot(cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
        let rows = try await exportRecords()
        let state = await content.state(storageClass: .secrets)
        guard state.available else { throw CloudFailure.secretsLocked }
        let marks = try await self.digest(epoch: state.epoch)
        if knownEpoch != state.epoch || knownQueue != queueId { outgoing.removeAll(); await useKnown(epoch: state.epoch, marks: marks) }
        tooLarge = tooLarge.filter { id, _ in rows.contains { $0.recordId == id } }
        let waiting = Set(inFlight.values.filter { $0.epoch == state.epoch && $0.queue == queueId }.map { $0.key + "\n" + $0.digest })
        var changed: [CloudSecretRecord] = []
        for record in rows {
            let key = marks.id(record.recordId), value = marks.record(try await encodedRecord(record))
            if known[key] != value, !waiting.contains(key + "\n" + value),
               !(importingEpoch == state.epoch && importing[key] == value) { changed.append(record) }
        }
        return try await snapshotWithRemovals(records: changed, cut: cut)
    }
    public func markPublished(_ snapshot: CloudDomainSnapshot, receipt: CloudLocalReceipt) async throws {
        guard Set(receipt.operationIds) == Set(snapshot.operations.map(\.opId)) else { throw CloudFailure.checksumMismatch }
        for operation in snapshot.operations {
            guard let saved = outgoing[operation.opId], saved.record == operation.entityId else { throw CloudFailure.invalidRequest }
            if (knownEpoch == nil || saved.epoch > knownEpoch!) && saved.queue == queueId {
                let marks = try await digest(epoch: saved.epoch)
                await useKnown(epoch: saved.epoch, marks: marks)
            }
            // Queued is not uploaded: wait for the cloud's receipt. A record
            // queued for another queue or epoch is dropped and uploads again.
            if knownEpoch == saved.epoch, knownQueue == saved.queue {
                inFlight[operation.opId] = (saved.key, saved.digest, saved.epoch, saved.queue); knownDirty = true
            }
            outgoing[operation.opId] = nil
        }
        await persistKnown()
    }
    private func snapshotWithRemovals(records: [CloudSecretRecord], cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
        let puts = try await snapshot(records: records, cut: cut)
        guard let owner = store as? any CloudSecretsDeletingStore else { return puts }
        let state = await content.state(storageClass: .secrets)
        guard state.available else { throw CloudFailure.secretsLocked }
        let marks = try await digest(epoch: state.epoch)
        let waiting = Set(inFlight.values.map { $0.key + "\n" + $0.digest })
        var operations = puts.operations
        for removal in try await owner.captureRemovals() {
            try await owner.validateRemoval(removal)
            let plain = try CloudSecretsCanonical.encode(removal)
            let key = marks.id(removal.recordId), value = marks.record(plain)
            guard known[key] != value, !waiting.contains(key + "\n" + value) else { continue }
            try await policy.require(domain.purpose, stage: .upload)
            let envelope = try await content.seal(plain, blobId: UUID().uuidString.lowercased(), storageClass: .secrets,
                purpose: domain.purpose, epoch: state.epoch, codec: .identity)
            let payload = CloudValue(try NativeRPCValue.parseJSON(JSONEncoder().encode(envelope)))
            let id = UUID().uuidString.lowercased()
            let operation = CloudOperation(v: 1, opId: id, originDevice: deviceId, domain: domain.rawValue,
                entityId: removal.recordId, revision: id, parents: [], kind: .archive,
                source: .init(sourceId: sourceId, recordId: removal.recordId), createdAt: cut.at,
                payload: payload, payloadHash: try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(payload)))
            guard try Self.fits(operation) else { throw CloudFailure.invalidRequest }
            outgoing[id] = (removal.recordId, key, value, state.epoch, queueId)
            operations.append(operation)
        }
        return .init(cut: cut, operations: operations, files: [], coverage: puts.coverage)
    }
    public func snapshot(records: [CloudSecretRecord], cut: CloudSnapshotCut) async throws -> CloudDomainSnapshot {
        for record in records { try await check(record, stage: .export) }
        let state = await content.state(storageClass: .secrets)
        guard state.available else { throw CloudFailure.secretsLocked }
        var operations: [CloudOperation] = []
        var bytes: Int64 = 0
        let marks = try await self.digest(epoch: state.epoch)
        var kept = 0
        for record in records {
            try await check(record, stage: .upload)
            let plain = try await encodedRecord(record)
            bytes += Int64(plain.count)
            let envelope = try await content.seal(plain, blobId: UUID().uuidString.lowercased(), storageClass: .secrets,
                purpose: domain.purpose, epoch: state.epoch, codec: .identity)
            let value = CloudValue(try NativeRPCValue.parseJSON(JSONEncoder().encode(envelope)))
            let operationId = UUID().uuidString.lowercased()
            let operation = CloudOperation(v: 1, opId: operationId, originDevice: deviceId,
                // The sync core requires revision == opId (CloudSyncSupport.validate).
                domain: domain.rawValue, entityId: record.recordId, revision: operationId, parents: [], kind: .put,
                source: .init(sourceId: sourceId, recordId: record.recordId), createdAt: cut.at,
                payload: value, payloadHash: try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(value)))
            // Measured against the sync core's own record limits, for every
            // caller. Over them: not queued, not marked, reported.
            measured.insert(record.recordId)
            guard try Self.fits(operation) else { tooLarge[record.recordId] = Self.tooLargeWords(domain); continue }
            tooLarge[record.recordId] = nil
            outgoing[operationId] = (record.recordId, marks.id(record.recordId), marks.record(plain), state.epoch, queueId)
            operations.append(operation)
            kept += 1
        }
        return .init(cut: cut, operations: operations, files: [], coverage: [.init(sourceId: sourceId,
            inventoryRow: store.inventoryRow, complete: tooLarge.isEmpty, items: kept, bytes: bytes, blockedReasons: gaps())])
    }
    public func changes(after: String?) async -> AsyncThrowingStream<CloudOperation, Error> {
        // Durable replay belongs to the shared outbox. An old observer cursor
        // requires a source snapshot rather than silently skipping missed changes.
        guard after == nil else { return AsyncThrowingStream { $0.finish(throwing: CloudFailure.unavailable) } }
        let id = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            watchers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.removeWatcher(id) } }
        }
    }
    public func seal() async {
        await (store as? any CloudSecretsKeyedStore)?.use(keys: nil)
        preparedDigests.removeAll(); verified.removeAll()
        known.removeAll(); importing.removeAll(); outgoing.removeAll(); knownEpoch = nil; importingEpoch = nil; knownQueue = nil
        inFlight.removeAll(); tooLarge.removeAll(); measured.removeAll(); notes.removeAll()
        for continuation in watchers.values { continuation.finish(throwing: CloudFailure.gateClosed) }
        watchers.removeAll()
    }
    private func removeWatcher(_ id: UUID) { watchers[id] = nil }
    public func publishChanged(_ snapshot: CloudDomainSnapshot) {
        for (id, continuation) in watchers {
            for operation in snapshot.operations {
                switch continuation.yield(operation) {
                case .dropped: continuation.finish(throwing: CloudFailure.unavailable); watchers[id] = nil
                case .terminated: watchers[id] = nil
                case .enqueued: break
                @unknown default: continuation.finish(throwing: CloudFailure.unavailable); watchers[id] = nil
                }
            }
        }
    }
    static let olderEpochWords = "Items saved before \"Start new saved passwords\" were skipped. They belong to the older archive."
    static let notAppliedWords = "A removal from another device could not be checked, so nothing was removed here."
    /// Opens incoming records. A record sealed under an epoch older than this
    /// Mac's key belongs to the archive kept by "Start new saved passwords":
    /// nobody in the current epoch can open it, so it is skipped and counted,
    /// never a failure that stalls restore (round-6 review R6-2).
    /// Older epochs receive a final skipped result. A removal instead needs its own valid saved-passwords
    /// envelope and an opted-in owner with a sealed Bin; a put relabelled as an archive is never authority.
    private func decodeIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> (pairs: [(CloudSecretRecord, CloudOperation)], removals: [(CloudSecretRemoval, CloudOperation)], versioned: [String: CloudSecretVersionedPut], refused: [CloudItemResult]) {
        await provideKeys()
        try await policy.require(domain.purpose, stage: .download)
        guard files.isEmpty else { throw CloudFailure.invalidRequest }
        let current = await content.state(storageClass: .secrets)
        var versioned: [String: CloudSecretVersionedPut] = [:]
        var pairs: [(CloudSecretRecord, CloudOperation)] = [], removals: [(CloudSecretRemoval, CloudOperation)] = [], refused: [CloudItemResult] = []
        for operation in operations {
            guard operation.v == 1, operation.domain == domain.rawValue, operation.source.sourceId == sourceId,
                  operation.entityId == operation.source.recordId,
                  try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(operation.payload)) == operation.payloadHash else { throw CloudFailure.invalidRequest }
            guard operation.kind == .put else {
                // Review 15 Nov (decision 4, R8-3): every other kind (`append`, `supersede`) and EVERY failure while
                // opening a removal (its envelope, class, purpose, seal, decoding, checks, an absurd date) ends with a
                // FINAL "not applied" row: no writer runs and the feed never stalls. Only "locked right now" retries.
                // A removal is only ever authority when it opens under the saved-passwords key as a typed removal of
                // this source, for an owner with a sealed Bin.
                guard operation.kind == .archive, let owner = store as? any CloudSecretsDeletingStore else {
                    refused.append(.init(entityId: operation.entityId, status: .alreadyPresent, reason: Self.notAppliedWords)); continue
                }
                do {
                    let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSecretsCanonical.encode(operation.payload), maximumBytes: CloudWire.maximumBlobBytes)
                    guard envelope.storageClass == .secrets, envelope.purpose == domain.purpose else { throw CloudFailure.invalidRequest }
                    if current.available, envelope.epoch < current.epoch {
                        refused.append(.init(entityId: operation.entityId, status: .alreadyPresent, reason: Self.olderEpochWords)); continue
                    }
                    let plain = try await content.open(envelope)
                    let removal = try CloudWire.decode(CloudSecretRemoval.self, from: plain, maximumBytes: CloudWire.maximumPlainChunkBytes)
                    guard removal.sourceId == sourceId, removal.domain == domain.rawValue, removal.recordId == operation.entityId else { throw CloudFailure.invalidRequest }
                    try await owner.validateRemoval(removal)
                    removals.append((removal, operation))
                } catch CloudFailure.secretsLocked {
                    throw CloudFailure.secretsLocked
                } catch {
                    refused.append(.init(entityId: operation.entityId, status: .alreadyPresent, reason: Self.notAppliedWords))
                }
                continue
            }
            let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSecretsCanonical.encode(operation.payload), maximumBytes: CloudWire.maximumBlobBytes)
            guard envelope.storageClass == .secrets, envelope.purpose == domain.purpose else { throw CloudFailure.invalidRequest }
            if current.available, envelope.epoch < current.epoch {
                refused.append(.init(entityId: operation.entityId, status: .alreadyPresent, reason: Self.olderEpochWords)); continue
            }
            let plain = try await content.open(envelope)
            let record: CloudSecretRecord
            if let put = try? CloudWire.decode(CloudSecretVersionedPut.self, from: plain, maximumBytes: CloudWire.maximumPlainChunkBytes) {
                guard store is any CloudSecretsDeletingStore, UUID(uuidString: put.version) != nil,
                      put.removalGroup.map({ UUID(uuidString: $0) != nil }) ?? true else {
                    refused.append(.init(entityId: operation.entityId, status: .alreadyPresent, reason: Self.notAppliedWords)); continue
                }
                record = put.record; versioned[operation.opId] = put
            } else {
                record = try CloudWire.decode(CloudSecretRecord.self, from: plain, maximumBytes: CloudWire.maximumPlainChunkBytes)
            }
            guard record.recordId == operation.entityId else { throw CloudFailure.invalidRequest }
            try await check(record, stage: .importRecords)
            pairs.append((record, operation))
        }
        return (pairs, removals, versioned, refused)
    }
    public func validateIncoming(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudPreparedImport {
        _ = try await decodeIncoming(operations, files: files)
        let id = UUID().uuidString.lowercased()
        let preparation = CloudPreparedImport(preparationId: id, operations: operations, files: [])
        preparedDigests[id] = try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(preparation))
        return preparation
    }
    public func applyPrepared(_ preparation: CloudPreparedImport, origin: CloudImportOrigin) async throws -> CloudImportReceipt {
        guard !busy, UUID(uuidString: preparation.preparationId) != nil else { throw CloudFailure.invalidRequest }
        busy = true; defer { busy = false; importing.removeAll(); importingEpoch = nil }
        let digest = try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(preparation))
        if let expected = preparedDigests[preparation.preparationId], expected != digest { throw CloudFailure.checksumMismatch }
        // SYNC persists the ciphertext preparation. Reopen and validate every
        // record after restart; a process-local cache is never the authority.
        let decoded = try await decodeIncoming(preparation.operations, files: preparation.files)
        let pairs = decoded.pairs, records = pairs.map { $0.0 }
        // Revalidate the exact ciphertext preparation before any writer runs.
        for (record, operation) in pairs {
            guard operation.domain == domain.rawValue, operation.entityId == record.recordId,
                  try CloudSecretsCrypto.hash(CloudSecretsCanonical.encode(operation.payload)) == operation.payloadHash else { throw CloudFailure.checksumMismatch }
            let envelope = try CloudWire.decode(CloudContentEnvelope.self, from: CloudSecretsCanonical.encode(operation.payload), maximumBytes: CloudWire.maximumBlobBytes)
            let expected: Data
            if let put = decoded.versioned[operation.opId] {
                expected = try CloudSecretsCanonical.encode(put)
            } else { expected = try CloudSecretsCanonical.encode(record) }
            guard try await content.open(envelope) == expected else { throw CloudFailure.checksumMismatch }
            try await check(record, stage: .importRecords)
        }
        let importState = await content.state(storageClass: .secrets)
        guard importState.available else { throw CloudFailure.secretsLocked }
        let marks = try await self.digest(epoch: importState.epoch)
        if knownEpoch != importState.epoch || knownQueue != queueId { outgoing.removeAll(); await useKnown(epoch: importState.epoch, marks: marks) }
        importingEpoch = importState.epoch
        for (record, operation) in pairs {
            let plain = try decoded.versioned[operation.opId].map { try CloudSecretsCanonical.encode($0) } ?? CloudSecretsCanonical.encode(record)
            importing[marks.id(record.recordId)] = marks.record(plain)
        }
        var settled: Set<String> = []
        var results: [CloudItemResult] = [], count = 0
        for (record, operation) in pairs {
            try await check(record, stage: .importRecords)
            let outcome: CloudApplyStatus
            if let put = decoded.versioned[operation.opId], let owner = store as? any CloudSecretsDeletingStore {
                outcome = try await owner.mergeVersioned(record, version: put.version, removalGroup: put.removalGroup)
            } else { outcome = try await store.merge(record) }
            guard outcome != .blocked, try await store.verify(record, outcome: outcome) else { throw CloudFailure.checksumMismatch }
            if outcome == .keptBoth {
                // Retain the incoming encrypted value independently of SYNC's
                // replay journal before acknowledging a successful conflict.
                try await retainIncomingConflict(operation)
                try await policy.require(domain.purpose, stage: .capture)
                let captured = try await store.capture()
                var localRows: [CloudSecretRecord] = []
                for local in captured where local.recordId == record.recordId {
                    if known[marks.id(local.recordId)] != marks.record(try await encodedRecord(local)) { localRows.append(local) }
                }
                if !localRows.isEmpty {
                    let local = try await snapshot(records: localRows, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: policy.now(), watermarks: [:]))
                    try await policy.require(domain.purpose, stage: .upload)
                    let saved = try await keepConflicts(local.operations)
                    try await markPublished(local, receipt: saved)
                }
            } else if knownEpoch == importingEpoch {
                setKnown(marks.id(record.recordId), importing[marks.id(record.recordId)])
                settled.insert(record.recordId)
            }
            count += 1
            results.append(.init(entityId: record.recordId, status: outcome))
        }
        // Only reached after opening this source's saved-passwords envelope. SYNC admits these domains only
        // through its secrets-pack path; a plain/brain tombstone fails decodeIncoming before any owner runs.
        var closed: [CloudItemResult] = []
        for (removal, _) in decoded.removals {
            settled.remove(removal.recordId)
            guard let owner = store as? any CloudSecretsDeletingStore else { throw CloudFailure.invalidRequest }
            // Decision 4: a removal that cannot be applied here (any failure but "locked right now") is closed with a
            // final "not applied" row, so the next record still applies. Locked: retried when the store opens (decision 9).
            let outcome: CloudApplyStatus
            do {
                outcome = try await owner.mergeRemoval(removal)
                guard outcome != .blocked, try await owner.verifyRemoval(removal, outcome: outcome) else { throw CloudFailure.checksumMismatch }
            } catch CloudFailure.secretsLocked {
                throw CloudFailure.secretsLocked
            } catch {
                closed.append(.init(entityId: removal.recordId, status: .alreadyPresent, reason: Self.notAppliedWords)); continue
            }
            setKnown(marks.id(removal.recordId), try marks.record(CloudSecretsCanonical.encode(removal)))
            count += 1
            results.append(.init(entityId: removal.recordId, status: outcome))
        }
        // An owner may store an imported value in its own normal form (Claude
        // Code adds a default "type" to an MCP server). Remember what is now on
        // this Mac, so that form is not uploaded back as a "change"; an entry that
        // is gone is forgotten, so it is never treated as already uploaded.
        if !settled.isEmpty, knownEpoch == importingEpoch {
            let rows = try await store.capture()
            let local = Dictionary(rows.map { ($0.recordId, $0) }, uniquingKeysWith: { first, _ in first })
            for id in settled {
                if let row = local[id] {
                    let mark = marks.record(try await encodedRecord(row))
                    setKnown(marks.id(id), mark)
                }
                else if !(store is any CloudSecretsDeletingStore) { setKnown(marks.id(id), nil) }
            }
        }
        await persistKnown()
        let finalRows = decoded.refused + closed
        results += finalRows
        for reason in finalRows.compactMap(\.reason) { notes[reason, default: 0] += 1 }
        let counts = CloudCounts(domains: 1, records: count, files: 0, bytes: 0, blocked: 0)
        let reasons = Array(Set(finalRows.compactMap(\.reason))).sorted()
        verified[preparation.preparationId] = .init(verified: true, counts: counts, reasons: reasons)
        preparedDigests[preparation.preparationId] = nil
        return .init(preparationId: preparation.preparationId, inventoryRow: store.inventoryRow, results: results, counts: counts)
    }
    public func verify(_ receipt: CloudImportReceipt) async throws -> CloudVerification {
        guard let result = verified[receipt.preparationId], result.counts == receipt.counts else { throw CloudFailure.invalidRequest }
        return result
    }
}

public actor CloudSecretsService: CloudSecretsPort {
    private let recovery: CloudRecoveryCoordinator
    private let policy: CloudSecretsPolicy
    private let content: any CloudContentPort
    private let outbox: any CloudOutboxPort
    private let adapters: [String: CloudSecretsLogicalAdapter]
    private let prepareSynchronization: @Sendable () async throws -> Void
    private let restoreLocalStores: @Sendable () async throws -> Void
    public init(recovery: CloudRecoveryCoordinator, policy: CloudSecretsPolicy, content: any CloudContentPort,
                outbox: any CloudOutboxPort, adapters: [CloudSecretsLogicalAdapter],
                prepareSynchronization: @escaping @Sendable () async throws -> Void,
                restoreLocalStores: @escaping @Sendable () async throws -> Void) throws {
        guard Set(adapters.map(\.sourceId)).count == adapters.count else { throw CloudFailure.idReused }
        self.recovery = recovery; self.policy = policy; self.content = content; self.outbox = outbox
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.sourceId, $0) })
        self.prepareSynchronization = prepareSynchronization; self.restoreLocalStores = restoreLocalStores
    }
    public func seal() async {
        await recovery.dismissPresentation()
        for adapter in adapters.values { await adapter.seal() }
    }
    public func status() async throws -> CloudSecretsStatus {
        let status = try await recovery.status()
        await noteCloudEpoch(status.epoch)
        return status
    }
    /// The cloud's current epoch (from status, or A's vault notice). While it is
    /// newer than this Mac's key, nothing is sealed (round-6 review R6-2).
    public func noteCloudEpoch(_ epoch: Int) async {
        await (content as? CloudSecretsContent)?.noteCloudEpoch(epoch)
    }
    public func beginSetup() async throws { try await recovery.setup(); try await synchronizeUnlocked() }
    /// Owner's decision (14 Nov): on by default. The first device makes the key with no sheet and no words.
    public func setupSilently() async throws { try await recovery.setupSilently(); try await synchronizeUnlocked() }
    /// Automatic hand-over: answers one request when every check holds (see the coordinator); nil when skipped.
    public func answerAutomatically(id: String) async throws -> String? { try await recovery.answerAutomatically(id: id) }
    /// Review blocker 1: open this Mac's own copy after an interrupted set-up, then synchronise.
    public func reopenOwnCopy() async throws -> Bool {
        guard try await recovery.reopenOwnCopy() else { return false }
        try await synchronizeUnlocked()
        return true
    }
    public func nobodyCanOpen() async -> Bool { await recovery.nobodyCanOpen() }
    public func recoveryWordsExist() async -> Bool? { await recovery.recoveryWordsExist() }
    /// "Start again" (review point 5): a fresh Cloud copy from this Mac; nothing local is deleted.
    public func startAgain() async throws { try await recovery.resetSilently(); try await synchronizeUnlocked() }
    public func waitingRequest() async -> CloudApproval? { await recovery.waitingRequest() }
    /// A lost Mac signed out from another device (design B2/B3): take the new key's copy, or make the due key change.
    /// Either way the saved passwords are then sealed again under the new key by the existing per-generation
    /// "already sent" marks (every record counts as unsent at a new generation), and nothing local is deleted.
    @discardableResult
    public func keyChange() async throws -> CloudRecoveryCoordinator.KeyChange {
        let done = try await recovery.keyChange()
        if done != .nothing { try await synchronizeUnlocked() }
        return done
    }
    /// This Mac holds a key of an older generation than the Cloud's.
    public func keyBehind() async -> Bool { await recovery.keyBehind() }
    /// The passkey spare key (PASSWORDS-2 slice 2).
    public func offerSpareOnce(passkey: (any CloudSecretsPasskeyPort)?) async -> Bool { await recovery.offerSpareOnce(passkey: passkey) }
    /// "Make a passkey spare key" (his press on the Cloud page).
    public func makeSpare(passkey: any CloudSecretsPasskeyPort) async -> CloudRecoveryCoordinator.SpareOutcome { await recovery.makeSpare(passkey: passkey) }
    /// The service says this generation has no spare (and this Mac holds the confirmed key).
    public func spareMissing() async -> Bool { await recovery.spareMissing() }
    /// Who sealed this Mac's copy, and the devices this Mac knows hold the key (names only).
    public func copyFrom() async -> String? { await recovery.copyFrom() }
    public func holdersKnownHere() async -> [String] { await recovery.holdersKnownHere() }
    public func spareCanOpen(passkey: (any CloudSecretsPasskeyPort)?) async -> Bool {
        guard let passkey, await passkey.available() else { return false }
        return await recovery.spareOnFile() == true
    }
    /// Who made this generation's spare and when, from the service's own record (`name` nil = this Mac).
    public func spareMade() async -> (name: String?, at: Int64)? { await recovery.spareMade() }
    /// PASSWORDS-5 point 1: this Mac's open passkey sheet is withdrawn when a fresh status shows a spare of its generation.
    @discardableResult
    public func withdrawSpareSheetIfMade() async -> Bool { await recovery.withdrawSpareSheetIfMade() }
    /// PASSWORDS-5 point 4: a second passkey was made here after this generation's spare existed (said on the page).
    public func spareOrphaned() async -> Bool { await recovery.spareOrphaned() }
    /// Point 4 repair: "Make my spare key again" (his press on the Cloud page).
    public func repairSpare(passkey: any CloudSecretsPasskeyPort) async -> CloudRecoveryCoordinator.SpareRepair { await recovery.repairSpare(passkey: passkey) }
    /// Who last replaced this generation's spare and when (`name` nil = this Mac).
    public func spareReplaced() async -> (name: String?, at: Int64)? { await recovery.spareReplaced() }
    public func openWithSpare(passkey: any CloudSecretsPasskeyPort) async throws {
        try await recovery.openWithSpare(passkey: passkey); try await synchronizeUnlocked()
    }
    /// The owner's stricter setting (see the coordinator). Only the Cloud page's switch changes it.
    public func askOnNewDevice() async -> Bool { await recovery.askOnNewDevice() }
    public func askHint() async -> Bool { await recovery.askHint() }
    public func askState() async -> CloudSecretsAskState { await recovery.askState() }
    /// The requests the page lists for his click (computers only, never a wrongly signed one).
    public func approvalsForPerson() async -> [CloudApproval] { await recovery.approvalsForPerson() }
    @discardableResult
    public func setAskOnNewDevice(_ value: Bool) async throws -> Bool { try await recovery.setAskOnNewDevice(value) }
    /// 15 Nov: "Keep saved passwords and secret files off my phones" (see the coordinator). Only the Cloud page's switch changes it.
    public func phonesOff() async -> Bool { await recovery.phonesOff() }
    @discardableResult
    public func setPhonesOff(_ value: Bool) async throws -> Bool { try await recovery.setPhonesOff(value) }
    public func requestApproval() async throws -> CloudApproval { try await recovery.requestApproval() }
    public func openApproval(id: String) async throws { try await recovery.approve(id: id) }
    public func beginRecovery() async throws { try await recovery.recover(); try await synchronizeUnlocked() }
    public func beginReset() async throws { try await recovery.reset(); await seal(); try await synchronizeUnlocked() }
    /// Unlock and synchronise only when a key was actually installed. A quiet
    /// "still waiting" (leftover envelope) never reaches the local-store switch
    /// or secret-domain registration (round-4 review N1).
    public func receiveApproval() async throws {
        guard try await recovery.receiveApproval() else { return }
        try await synchronizeUnlocked()
    }
    /// Finish a Mac that saved its key but never got the cloud's confirmation.
    @discardableResult
    public func finishPendingAcknowledgement() async throws -> Bool {
        guard try await recovery.confirmPendingAcknowledgement() else { return false }
        try await synchronizeUnlocked()
        return true
    }
    public func protection() async -> CloudSecretsProtection { await recovery.protection() }
    private func synchronizeUnlocked() async throws {
        try await restoreLocalStores()
        // A registers/routes the secret domains after root readiness, not before.
        try await prepareSynchronization()
        // Preserve each current local source in the durable outbox before merging
        // remote secrets. A blocked source never becomes an empty successful save.
        for adapter in adapters.values.sorted(by: { $0.sourceId < $1.sourceId }) {
            if adapter.domain == .aiSubscription {
                do { try await policy.require(.aiSubscription, stage: .capture) }
                catch CloudFailure.gateClosed { continue }
            }
            _ = try await captureChanged(sourceId: adapter.sourceId)
        }
        _ = try await outbox.pull()
        _ = try await outbox.flush()
        for adapter in adapters.values { await settle(adapter) }
    }
    public func exportLogical(source: String) async throws -> [CloudSecretRecord] {
        guard let adapter = adapters[source] else { throw CloudFailure.invalidRequest }
        return try await adapter.exportRecords()
    }
    public func importLogical(_ records: [CloudSecretRecord], conflictPolicy: CloudConflictPolicy) async throws -> CloudVerification {
        // Internal caller only. Journal encrypted operations before any local writer.
        // The tool contribution never exposes this method or accepts logical bytes.
        var work: [(CloudSecretsLogicalAdapter, CloudPreparedImport)] = []
        for (source, rows) in Dictionary(grouping: records, by: \.sourceId).sorted(by: { $0.key < $1.key }) {
            guard let adapter = adapters[source] else { throw CloudFailure.invalidRequest }
            let snapshot = try await adapter.snapshot(records: rows, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: policy.now(), watermarks: [:]))
            let preparation = try await adapter.validateIncoming(snapshot.operations, files: [])
            work.append((adapter, preparation))
        }
        for (adapter, preparation) in work {
            try await policy.require(adapter.domain.purpose, stage: .upload)
            _ = try await outbox.enqueue(preparation.operations, files: [])
        }
        var count = 0
        for (adapter, preparation) in work {
            let receipt = try await adapter.applyPrepared(preparation, origin: .init(deviceId: preparation.operations.first?.originDevice ?? "", sequence: .zero))
            guard try await adapter.verify(receipt).verified else { throw CloudFailure.checksumMismatch }
            count += receipt.counts.records
        }
        return .init(verified: true, counts: .init(domains: work.count, records: count, files: 0, bytes: 0, blocked: 0), reasons: [])
    }
    public func classify(relativePath: String, sourceId: String) async throws -> CloudSecretClassification {
        CloudSecretsPolicy.classify(relativePath: relativePath, sourceId: sourceId)
    }
    public func protectProjectSettings(projectId: String, rootId: String, bytes: Data) async throws -> CloudSecretRecord {
        try await policy.require(.secret, stage: .upload)
        _ = try CloudSecretsCrypto.uuidBytes(projectId); _ = try CloudSecretsCrypto.uuidBytes(rootId)
        let state = await content.state(storageClass: .secrets)
        guard state.available else { throw CloudFailure.secretsLocked }
        let envelope = try await content.seal(bytes, blobId: UUID().uuidString.lowercased(), storageClass: .secrets,
                                             purpose: .secret, epoch: state.epoch, codec: .identity)
        return .init(sourceId: "project/" + projectId, recordId: rootId, domain: CloudSecretsDomain.project.rawValue,
                     payload: .init(try NativeRPCValue.parseJSON(JSONEncoder().encode(envelope))))
    }
    /// Plain-words gaps per source (too large to save in Cloud). Shown with
    /// coverage and in the status tool.
    public func gaps() async -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (id, adapter) in adapters { let words = await adapter.gaps(); if !words.isEmpty { result[id] = words } }
        return result
    }
    /// Plain reasons, with counts, for incoming items closed on this Mac without being applied (records of an
    /// older archive, a removal listed instead of applied). Passed to the page and the status tool like the
    /// gaps (round-8 S-5), so the person is told once; `dismissNotices()` when they have seen them.
    public func notices() async -> [String: Int] {
        var result: [String: Int] = [:]
        for adapter in adapters.values {
            for (reason, count) in await adapter.notices() { result[reason, default: 0] += count }
        }
        return result
    }
    public func dismissNotices() async {
        for adapter in adapters.values { await adapter.clearNotices() }
    }
    /// The sign-out guard's facts (R5); see `CloudRecoveryCoordinator.signOutState()`.
    public func signOutState() async -> CloudSecretsSignOutState { await recovery.signOutState() }
    /// Write "already uploaded" only for records the cloud has read back.
    private func settle(_ adapter: CloudSecretsLogicalAdapter) async {
        var confirmed: Set<String> = []
        for id in await adapter.pendingOperationIds() {
            let receipt = try? await outbox.cloudReceipt(operationId: id)
            if receipt != nil { confirmed.insert(id) }
        }
        if !confirmed.isEmpty { await adapter.confirmed(operationIds: confirmed) }
    }
    /// Store change callbacks feed this one outbox; never a second sender or scheduler.
    public func captureChanged(sourceId: String) async throws -> CloudLocalReceipt {
        guard let adapter = adapters[sourceId] else { throw CloudFailure.invalidRequest }
        let queue = try? await outbox.outboxIdentity()
        await adapter.useOutbox(queue: queue)
        await settle(adapter)
        let snapshot = try await adapter.changedSnapshot(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: policy.now(), watermarks: [:]))
        try await policy.require(adapter.domain.purpose, stage: .upload)
        guard !snapshot.operations.isEmpty else { return .init(operationIds: [], queued: 0, bytes: 0, savedAt: policy.now()) }
        let receipt = try await outbox.enqueue(snapshot.operations, files: [])
        try await adapter.markPublished(snapshot, receipt: receipt)
        await adapter.publishChanged(snapshot)
        return receipt
    }
}
