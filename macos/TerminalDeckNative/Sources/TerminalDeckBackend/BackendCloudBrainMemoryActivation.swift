import Foundation
import TerminalDeckNativeCore

/// The one enabling step for the memory rows of one signed-in account (findings 10, 15; round 2 M2, M7, M8, M11).
/// Only this step, called by the account wiring with a live signed-in account, switches capture on (M2). Order:
/// capture on → adapters registered → the saved cut finished with its own snapshot id (or the first cut taken) →
/// the reconcile for anything written while capture was off → journal pumps.
/// - A failure before capture is on leaves capture OFF with nothing installed.
/// - A failure after capture is on (for example the network during the first upload) keeps capture on with no gap and
///   is retried within this run with back-off; the staged cut is reused, never copied again (M7).
/// - `stop()` (sign-out, gate closed) is final for this object: every await in `start` is followed by a check, and a
///   late `start` undoes what it did and ends with `CancellationError` (M11).
public actor BackendCloudBrainMemoryActivation {
    private struct SavedCut: Codable { let cut: CloudSnapshotCut; var done: Bool }
    private let store: DeckMemoryStore
    private let deviceId: String
    private let subjectHash: String
    private let stateRoot: URL
    private let rows: [String]
    private var adapters: [BackendCloudBrainMemory] = []
    private var pumps: [BackendCloudBrainMemoryPump] = []
    private var running = false
    private var starting = false
    private var stopped = false
    private let now: @Sendable () -> Int64
    private let retryDelays: [Double]

    public init(store: DeckMemoryStore, deviceId: String, subjectHash: String, stateRoot: URL, rows: [String]) throws {
        try self.init(store: store, deviceId: deviceId, subjectHash: subjectHash, stateRoot: stateRoot, rows: rows,
                      now: { Int64(Date().timeIntervalSince1970 * 1000) }, retryDelays: [5, 30, 120, 600, 1800])
    }
    init(store: DeckMemoryStore, deviceId: String, subjectHash: String, stateRoot: URL, rows: [String],
         now: @escaping @Sendable () -> Int64, retryDelays: [Double] = [5, 30, 120, 600, 1800]) throws {
        guard UUID(uuidString: deviceId) != nil, stateRoot.isFileURL, !rows.isEmpty, Set(rows).count == rows.count,
              rows.allSatisfy({ CloudBrainMemoryFormat.inventoryRows.contains($0) }), retryDelays.allSatisfy({ $0 >= 0 }),
              subjectHash.utf8.count == 64, subjectHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CloudFailure.invalidRequest }
        self.store = store; self.deviceId = deviceId; self.subjectHash = subjectHash; self.stateRoot = stateRoot.standardizedFileURL
        self.rows = rows; self.now = now; self.retryDelays = retryDelays
    }
    private var cutFile: URL { stateRoot.appendingPathComponent("memory-cut.json") }
    private var snapshotRoot: URL { stateRoot.appendingPathComponent("snapshots", isDirectory: true) }
    /// For tests: how many journal pumps run now.
    var pumpCount: Int { pumps.count }

    public func start(outbox: any CloudOutboxPort) async throws {
        guard !stopped else { throw CancellationError() }
        guard !running, !starting else { return }
        starting = true; defer { starting = false }
        // Phase 1: capture. Nothing else happens until it is on.
        do {
            try await store.cloudResumeCapture(stateRoot: stateRoot, rows: rows)
            await store.cloudSetDevice(deviceId)
            try checkLive()
        } catch {
            await undo()
            if stopped { throw CancellationError() }
            throw error
        }
        // Phase 2: capture is on; failures here are retried in this run with back-off and keep capture on (M7).
        var attempt = 0
        while true {
            do {
                try await establish(outbox: outbox)
                return
            } catch {
                if stopped || error is CancellationError { await undo(); throw CancellationError() }
                // 13 Nov blocker: each failed attempt says why, once (the sync core's own line is not repeated).
                CloudSyncDiagnostics.shared.report("first saved copy (memory, attempt \(attempt + 1))", error)
                // M1b limit 3: out of retries, capture must not stay on with nothing draining it. Capture off, gap
                // recorded (the next activation reconciles), error to the caller.
                guard attempt < retryDelays.count else { await undo(); throw error }
                try await sleepChecking(retryDelays[attempt])
                attempt += 1
            }
        }
    }

    private func establish(outbox: any CloudOutboxPort) async throws {
        if adapters.isEmpty {
            let made = try rows.map { try BackendCloudBrainMemory(store: store, deviceId: deviceId, inventoryRow: $0, snapshotRoot: snapshotRoot) }
            for adapter in made { try await outbox.register(adapter: adapter); try checkLive() }
            adapters = made
        }
        var saved = try loadCut()
        // A cut taken in an earlier run means rows may have changed while capture was off (M2): reconcile after it.
        let reconcile = saved != nil
        if saved == nil {
            // Sync trust core review, hand-back 4: a Mac never cuts its baseline before it has taken in what the
            // devices it trusts already saved. With the adapters registered, one pull applies everything available
            // (a release of just-trusted devices runs first in it), so a record Cloud already holds goes out from
            // here marked as a baseline and loses to Cloud's version (rule J) instead of winning by its fresh stamp.
            // No answer from Cloud changes nothing: setup goes on, and the merge still converges.
            _ = try? await outbox.pull(); try checkLive()
            let first = SavedCut(cut: .init(snapshotId: UUID().uuidString.lowercased(), at: now(), watermarks: [:]), done: false)
            try persist(first); saved = first
        }
        if var unfinished = saved, !unfinished.done {
            // Same snapshot id on every retry (SYNC refuses another one meanwhile); one staged copy at most (M7).
            try await store.cloudKeepOnlySnapshot(id: BackendCloudBrainMemoryHash.uuid(unfinished.cut.snapshotId)); try checkLive()
            _ = try await outbox.bootstrap(sources: adapters, cut: unfinished.cut); try checkLive()
            unfinished.done = true; try persist(unfinished)
            // Published: the staged copy is no longer needed, and superseded export parts can go (M7, M10).
            try await store.cloudDiscardSnapshots(); try checkLive()
            try await store.cloudPruneSupersededParts(); try checkLive()
        }
        if reconcile { try await store.cloudPlanReconcile(); try checkLive() }  // R4: full, resume, or tail
        if pumps.isEmpty {
            var started: [BackendCloudBrainMemoryPump] = []
            for adapter in adapters {
                let pump = try BackendCloudBrainMemoryPump(adapter: adapter, outbox: outbox, subjectHash: subjectHash)
                await pump.start(); started.append(pump)
                if stopped { for made in started { await made.stop() }; throw CancellationError() }
            }
            pumps = started
        }
        try checkLive()
        running = true
    }

    /// Final for this object: pumps stopped, capture suspended (TEMP triggers dropped, account database detached).
    public func stop() async {
        stopped = true
        await undo()
    }
    /// After the wiring called `outbox.abandonUnpublishedSetup()`: no saved cut and no staged copy remain, so the next
    /// activation takes a fresh cut. Kept local data (journal, versions) is untouched.
    public func abandonSetup() async throws {
        guard !running, !starting else { throw CloudFailure.unavailable }
        if FileManager.default.fileExists(atPath: cutFile.path) { try FileManager.default.removeItem(at: cutFile) }
        let folder = snapshotRoot
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try await store.cloudDiscardSnapshots()
    }
    private func undo() async {
        for pump in pumps { await pump.stop() }
        pumps = []; running = false
        try? await store.cloudSuspendCapture()
    }
    private func checkLive() throws { if stopped { throw CancellationError() } }
    private func sleepChecking(_ seconds: Double) async throws {
        var left = seconds
        while left > 0 {
            try checkLive()
            let step = min(left, 0.25)
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            left -= step
        }
        try checkLive()
    }
    private func loadCut() throws -> SavedCut? {
        guard FileManager.default.fileExists(atPath: cutFile.path) else { return nil }
        let saved = try JSONDecoder().decode(SavedCut.self, from: Data(contentsOf: cutFile))
        guard UUID(uuidString: saved.cut.snapshotId) != nil else { throw CloudFailure.invalidRequest }
        return saved
    }
    private func persist(_ saved: SavedCut) throws {
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: cutFile, options: .atomic)
        try BackendCloudBrainMemoryHash.synchronize(cutFile)
    }
}
