import Foundation
import TerminalDeckNativeCore

/// Moves the owner's durable journal into SYNC's durable outbox; no network, scheduler or second data writer.
public actor BackendCloudBrainMemoryPump {
    private let adapter: BackendCloudBrainMemory
    private let outbox: any CloudOutboxPort
    private let scope: String
    private var task: Task<Void,Never>?
    private var draining = false
    public init(adapter: BackendCloudBrainMemory, outbox: any CloudOutboxPort, subjectHash: String) throws {
        guard subjectHash.utf8.count == 64, subjectHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CloudFailure.invalidRequest }
        self.adapter = adapter; self.outbox = outbox; scope = subjectHash
    }
    /// Advances the source cursor only after all returned operations have a durable LocalReceipt.
    /// Returns operations queued plus maintenance work done (R2), so a caller looping "until 0" runs until idle.
    @discardableResult public func drainOnce(limit: Int = 16) async throws -> Int {
        let step = try await drainStep(limit: limit)
        return step.operations + step.maintenance
    }
    private func drainStep(limit: Int) async throws -> (operations: Int, maintenance: Int) {
        guard !draining else { throw CloudFailure.unavailable }
        draining = true; defer { draining = false }
        guard (1...128).contains(limit) else { throw CloudFailure.invalidRequest }
        // One bounded maintenance step first (heal a dropped capture, advance the reconcile); its failure never stops
        // already-journaled changes from being queued, it is reported instead.
        var maintenance = 0
        do { maintenance = try await adapter.reconcileFiles(limit: 64) } catch { try? await adapter.localPumpProblem(true, scope: scope) }
        // Commit times of what this pump queued earlier (local read of the sync core's receipts, no network).
        maintenance += await recordCommitTimes()
        var cursor = try await adapter.savedLocalCursor(scope: scope), operations: [CloudOperation] = []
        while operations.count < limit, let change = try await adapter.localChange(after: cursor) {
            operations.append(change.operation); cursor = change.cursor
        }
        guard !operations.isEmpty, let cursor else { return (0, maintenance) }
        let receipt = try await outbox.enqueue(operations, files: [])
        guard Set(receipt.operationIds) == Set(operations.map(\.opId)) else { throw CloudFailure.checksumMismatch }
        try await adapter.saveLocalCursor(cursor, scope: scope)
        try await adapter.localPumpProblem(false, scope: scope)
        try? await adapter.rememberQueued(operations.map(\.opId))
        maintenance += await recordCommitTimes()
        return (operations.count, maintenance)
    }
    /// Asks the outbox for the receipts of up to `limit` queued operations, oldest first, and hands the known ones to the
    /// store, which caps this Mac's own versions at their service commit time. Returns how many were recorded.
    private func recordCommitTimes(limit: Int = 32) async -> Int {
        guard let waiting = try? await adapter.waitingReceipts(limit: limit), !waiting.isEmpty else { return 0 }
        var known: [CloudOperationReceipt] = []
        for id in waiting { if let receipt = try? await outbox.cloudReceipt(operationId: id) { known.append(receipt) } }
        guard !known.isEmpty else { return 0 }
        do { try await adapter.recordCommitTimes(known) } catch { return 0 }
        return known.count
    }
    public func start() {
        guard task == nil else { return }
        let notices = adapter.localNotices() // subscribe before the first journal read
        task = Task { await self.run(notices) }
    }
    private func run(_ notices: AsyncStream<DeckMemoryChange>) async {
        var iterator = notices.makeAsyncIterator()
        while !Task.isCancelled {
            // R2: run until idle, including the reconcile, without waiting for unrelated memory changes. A step that only
            // checked rows (nothing queued) waits a short slow tick, so a long pass never crowds out memory itself.
            do {
                while true {
                    let step = try await drainStep(limit: 16)
                    if step.operations == 0, step.maintenance == 0 { break }
                    try Task.checkCancellation()
                    if step.operations == 0 { try await Task.sleep(nanoseconds: 50_000_000) } else { await Task.yield() }
                }
            }
            catch is CancellationError { break }
            catch { try? await adapter.localPumpProblem(true, scope: scope) }
            // No retry loop on a failure. The next owner change, wake or explicit Retry can try again.
            if await iterator.next(isolation: self) == nil { break }
        }
    }
    public func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}

extension BackendCloudBrainMemory {
    func rememberQueued(_ ids: [String]) async throws { try await store.cloudRememberQueued(ids) }
    func waitingReceipts(limit: Int) async throws -> [String] { try await store.cloudWaitingReceipts(limit: limit) }
    /// Records the commit times, then forgets those operations (a receipt read once is final).
    func recordCommitTimes(_ receipts: [CloudOperationReceipt]) async throws {
        try await store.cloudRecordCommitTimes(receipts)
        try await store.cloudForgetReceipts(receipts.map(\.operationId))
    }
}

extension DeckMemoryStore {
    /// Bound on operations waiting for their receipt; the oldest are let go beyond it (their own-version stamp then
    /// stays uncapped by the commit time, which only makes it less precise, never wrong for merging).
    static let cloudReceiptWaitBound = 4096
    func cloudRememberQueued(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction {
            for id in ids { try db.run("INSERT OR IGNORE INTO cloud_memory_receipt_wait(op_id) VALUES (?)", [.text(id)]) }
            try db.run("DELETE FROM cloud_memory_receipt_wait WHERE seq <= (SELECT MAX(seq) FROM cloud_memory_receipt_wait) - ?", [.int(Int64(Self.cloudReceiptWaitBound))])
        }
    }
    func cloudWaitingReceipts(limit: Int) throws -> [String] {
        try db.rows("SELECT op_id FROM cloud_memory_receipt_wait ORDER BY seq LIMIT ?", [.int(Int64(max(1, limit)))]).map { $0.text(0) }
    }
    func cloudForgetReceipts(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.transaction { for id in ids { try db.run("DELETE FROM cloud_memory_receipt_wait WHERE op_id=?", [.text(id)]) } }
    }
    func cloudLocalCursor(scope: String, row: String) throws -> String? {
        try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text("sourceCursor:" + scope + ":" + row)])?.string(0)
    }
    func cloudSaveLocalCursor(_ cursor: String, scope: String, row: String) throws {
        try db.run("INSERT INTO cloud_memory_control(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text("sourceCursor:" + scope + ":" + row),.text(cursor)])
    }
    func cloudPumpProblem(_ failed: Bool, scope: String, row: String) throws {
        let key = "pumpProblem:" + scope + ":" + row
        if failed { try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,'outbox_pending')", [.text(key)]) }
        else { try db.run("DELETE FROM cloud_memory_control WHERE key=?", [.text(key)]) }
    }
}
