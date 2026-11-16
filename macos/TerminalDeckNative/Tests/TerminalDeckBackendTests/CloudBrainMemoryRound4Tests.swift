import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Review round 4 (R6, R7, M1b leftovers).
@Suite("Cloud memory capture — round 4: resumed passes, undone rewinds, write-retry limits", .serialized)
struct CloudBrainMemoryRound4Tests {
    private func reopen(_ f: CloudBrainMemoryFixture) async throws -> DeckMemoryStore {
        try await DeckMemoryStore.open(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
    }

    @Test func aResumedPassStillSendsDiaryRowsWrittenBeforeActivation_R6() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        _ = try await f.snapshot("I02") // capture on; the cut sets the diary's high-water mark
        // Run 1 quits cleanly with a pass unfinished and already past the diary.
        try await f.store.cloudFixtureSetControl("rowsReconcile", "settings:" + String(Int64.min) + ":tail")
        await f.store.close()
        // Run 2: a message is written before the account activates (capture off).
        let store = try await reopen(f)
        _ = try await store.appendDiary(.init(stamp: .hoot, role: .user, text: "written before activation", externalID: "r6-row"))
        try await store.cloudResumeCapture(stateRoot: f.stateRoot)
        try await store.cloudPlanReconcile()
        #expect(try await store.cloudFixtureControl("reconcileMode") == "resume")
        while try await store.cloudReconcileRows(limit: 1000) > 0 {}
        #expect(try await store.cloudFixtureJournalCount(inventory: "I02", containing: "written before activation") == 1)
        await store.close(); try? FileManager.default.removeItem(at: f.base)
    }

    @Test func anUndoneRewindResendsItsConversationsRowsWithTheMarkCleared_R7() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        try await f.store.cloudFixtureExec("UPDATE diary SET conversation='fixture-chat' WHERE external_id='four'")
        _ = try await f.snapshot("I02"); _ = try await f.snapshot("I04")
        await f.store.close() // clean, nothing pending: the next launch runs a tail pass
        let store = try await reopen(f)
        // Undo while capture is off: the diary row no longer carries the rewind id.
        try await store.cloudFixtureExec("UPDATE rewinds SET undone=1000.5 WHERE id=7")
        try await store.cloudFixtureExec("UPDATE diary SET rewound=NULL, rewind_id=NULL WHERE external_id='four'")
        try await store.cloudResumeCapture(stateRoot: f.stateRoot)
        try await store.cloudPlanReconcile()
        #expect(try await store.cloudFixtureControl("reconcileMode") == "tail")
        while try await store.cloudReconcileRows(limit: 1000) > 0 {}
        let rewound = try await store.cloudFixtureJournaledDiaryColumn("rewound", external: "four")
        #expect(rewound.contains(.null))
        await store.close(); try? FileManager.default.removeItem(at: f.base)
    }

    @Test func anUnreadableSideFileIsDetachedBeforeTheTransactionStarts_M1bA() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I02")
        let side = try FileHandle(forWritingTo: f.stateRoot.appendingPathComponent("memory-cloud.db"))
        try side.seek(toOffset: 0); try side.write(contentsOf: Data(repeating: 0x5A, count: 4096)); try side.close()
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "no failed attempt", externalID: "m1b-a"))
        #expect(try await f.store.cloudFixtureDiaryTexts().contains("no failed attempt"))
        // Detached by the check before BEGIN: no statement had to fail and be retried.
        #expect(await f.store.cloudFixtureCaptureRetries() == 0)
        #expect(await f.store.cloudCaptureLost)
        #expect(!(try await f.store.cloudAttached()))
        await f.close()
    }

    @Test func aRestoreThatBringsBackFewerTriggersCountsAsDropped_M1bB() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I02")
        await f.store.cloudFixtureOmitOnRestore(1)
        await #expect(throws: (any Error).self) { try await f.store.cloudFixtureInsertDiaryRaw(text: "duplicate", external: "one") }
        #expect(await f.store.cloudFixtureCaptureLoss() != nil)
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        #expect(!(try await f.store.cloudAttached()))
        await f.close()
    }

    @Test func aSideDatabaseWriteFailureIsNotCountedAsAnUnreadableRow_M1b() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.capture()
        try await f.store.cloudStartReconcile(full: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.stateRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.stateRoot.path) }
        await #expect(throws: (any Error).self) { _ = try await f.store.cloudReconcileRows(limit: 1000) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.stateRoot.path)
        #expect(try await f.store.cloudReconcileSkipped("I02") == 0)
        await f.close()
    }
    @Test func aCrashBeforeTheCursorSaveReplaysTheIdenticalOperations() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I02")
        // Two edits of one message: the second moves the export head past the first.
        try await f.store.cloudFixtureEditDiary("one", text: "first edit")
        try await f.store.cloudFixtureEditDiary("one", text: "second edit")
        let adapter = try f.adapter("I02")
        func readAll() async throws -> [CloudOperation] {
            var cursor: String?, ops: [CloudOperation] = []
            while let change = try await adapter.localChange(after: cursor) { ops.append(change.operation); cursor = change.cursor }
            return ops
        }
        let queued = try await readAll()
        #expect(queued.count >= 2)
        // Crash after queueing, before the cursor was saved: the next run reads the same rows again from the start.
        let again = try await readAll()
        #expect(again == queued)
        await f.close()
    }
    @Test func thePumpRecordsTheServiceCommitTimeOfWhatItQueued() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I02")
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "committed later", externalID: "receipt-row"))
        let outbox = ReceiptOutbox()
        let pump = try BackendCloudBrainMemoryPump(adapter: try f.adapter("I02"), outbox: outbox, subjectHash: String(repeating: "c", count: 64))
        #expect(try await pump.drainOnce() >= 1)
        // One drain: queued, then its receipt read back from the outbox and handed to the store.
        #expect(await outbox.asked.isEmpty == false)
        #expect(try await f.store.cloudWaitingReceipts(limit: 100).isEmpty)
        #expect(try await f.store.cloudFixtureCommittedStamps().contains(1_700_000_000_000))
        await f.close()
    }
}

/// Fixture-only outbox: accepts every operation and answers its receipt with a fixed commit time, from local state.
actor ReceiptOutbox: CloudOutboxPort {
    var queued: Set<String> = []
    var asked: [String] = []
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        for op in operations { queued.insert(op.opId) }
        return .init(operationIds: operations.map { $0.opId }, queued: operations.count, bytes: 0, savedAt: 1)
    }
    func cloudReceipt(operationId: String) async throws -> CloudOperationReceipt? {
        asked.append(operationId)
        guard queued.contains(operationId) else { return nil }
        return .init(operationId: operationId, sequence: CloudSequence(7), committedAt: 1_700_000_000_000)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
    func flush() async throws -> [CloudReceipt] { [] }
    func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unsupportedFormat }
    func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
    func register(adapter: any CloudDomainAdapter) async throws {}
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func pull() async throws -> [CloudImportReceipt] { [] }
    func setPaused(_ paused: Bool) async throws {}
}

extension DeckMemoryStore {
    func cloudFixtureCommittedStamps() throws -> [Int64] {
        try db.rows("SELECT committed_at FROM cloud_memory_stamps WHERE committed_at IS NOT NULL").map { $0.int(0) }
    }
    func cloudFixtureSetControl(_ key: String, _ value: String) throws {
        try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(key), .text(value)])
    }
    func cloudFixtureCaptureRetries() -> Int { db.captureRetries }
    func cloudFixtureOmitOnRestore(_ count: Int) { db.captureRestoreOmitForTesting = count }
    /// One column of every journaled diary body for a message, by its external id.
    func cloudFixtureJournaledDiaryColumn(_ column: String, external: String) throws -> [DeckMemorySQL] {
        let diary = try DeckMemoryCloudSchema.table("diary")
        guard let c = diary.columns.firstIndex(of: column), let e = diary.columns.firstIndex(of: "external_id") else { return [] }
        return try db.rows("SELECT body FROM cloud_memory_journal WHERE inventory='I02' AND body IS NOT NULL").compactMap { row in
            guard let body = row.data(0), let decoded = try? DeckMemoryCloudSchema.decodeRow(body),
                  decoded.0.name == "diary", decoded.1[e] == .text(external) else { return nil }
            return decoded.1[c]
        }
    }
}
