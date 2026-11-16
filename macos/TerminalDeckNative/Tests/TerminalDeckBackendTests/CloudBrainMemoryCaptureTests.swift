import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Review round (12 Nov): capture lives outside memory.db, the cut is bounded, activation survives restarts.
@Suite("Cloud memory capture — outside memory.db, bounded, resumable", .serialized)
struct CloudBrainMemoryCaptureTests {
    @Test func noCloudObjectEverStaysInMemoryDb_finding2() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        try await f.activate("I02")
        #expect(try await f.store.cloudFixtureMainCloudObjects().isEmpty)
        #expect(!(try await f.store.cloudFixtureTempTriggers()).isEmpty)
        // Quit without signing out: TEMP triggers die with the connection; the reopened connection has none until resumed.
        await f.store.close()
        let reopened = try DeckMemoryStore(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        #expect(try await reopened.cloudFixtureTempTriggers().isEmpty)
        #expect(try await reopened.cloudFixtureMainCloudObjects().isEmpty)
        _ = try await reopened.appendDiary(.init(stamp: .hoot, role: .user, text: "after quit", externalID: "after-quit"))
        #expect(try await reopened.cloudFixtureMainCloudObjects().isEmpty)
        await reopened.close()
        // An earlier build's persistent trigger is removed by the launch sweep before memory opens for writing.
        let planted = try DeckMemoryStore(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        try await planted.cloudFixtureExec("CREATE TRIGGER cloud_memory_old AFTER INSERT ON diary BEGIN SELECT 1; END;")
        await planted.close()
        try FileManager.default.removeItem(at: f.base.appendingPathComponent("Data/cloud/memory-capture.json"))
        let opened = try await DeckMemoryStore.open(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        #expect(try await opened.cloudFixtureMainCloudObjects().isEmpty)
        #expect(try await opened.cloudFixtureTempTriggers().isEmpty)
        await opened.close(); try? FileManager.default.removeItem(at: f.base)
    }

    @Test func activationAndDailyBackupLeaveMemoryDbLayoutAloneAndBackupsNeverTravel_finding8() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let before = try await f.store.cloudFixtureMainSchema()
        let snapshot = try await f.snapshot("I06")
        _ = try await f.store.backup()
        #expect(try await f.store.cloudFixtureMainSchema() == before)
        #expect(try await f.store.cloudFixtureMainCloudObjects().isEmpty)
        // backup.last is about this Mac only: never journaled.
        #expect(try await f.store.cloudFixtureJournalCount() == 0)
        for op in snapshot.operations {
            let key = try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload)).key
            #expect(!key.contains("archive/backups/") && !key.hasPrefix("backup/"))
        }
        await f.close()
    }

    @Test func aFailureAfterCaptureKeepsCaptureOnAndReplaysTheSameStagedCutInThisRun_finding10_M7() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        // A stale staged folder from an earlier attempt: at most one staged copy may exist (M7).
        let stale = f.stateRoot.appendingPathComponent("snapshots/stale-cut", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        let outbox = CaptureTestOutbox(); await outbox.failAfterFirstPage()
        let activation = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64),
                                                               stateRoot: f.stateRoot, rows: ["I02"], now: { 1000 }, retryDelays: [0])
        try await activation.start(outbox: outbox)
        let cuts = await outbox.cuts
        // Retried within the run with the same snapshot id; no fresh cut, no relaunch.
        #expect(cuts.count == 2)
        #expect(cuts[0] == cuts[1])
        let pages = await outbox.firstPages
        #expect(pages.count == 2 && pages[0] == pages[1])
        #expect(await f.store.cloudMemoryEnabled)
        // Published: no staged copy is left, the stale one included.
        #expect(!FileManager.default.fileExists(atPath: f.stateRoot.appendingPathComponent("snapshots").path))
        await activation.stop(); await f.close()
    }

    @Test func anOlderLiveLayoutInstallsNothingAndMemoryWritesStillWork_finding13() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        try await f.store.cloudFixtureExec("ALTER TABLE questions DROP COLUMN dismissed")
        await #expect(throws: CloudFailure.unsupportedFormat) { try await f.capture() }
        #expect(!(await f.store.cloudMemoryEnabled))
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        #expect(try await f.store.cloudFixtureControl("captureProblem")?.hasPrefix("schema_mismatch:questions") == true)
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "still saved", externalID: "old-layout"))
        #expect(try await f.store.cloudFixtureCount("diary") == 5)
        #expect(try await f.store.cloudFixtureJournalCount() == 0)
        await f.close()
    }

    @Test func aFirstSetupTakesInWhatCloudHoldsBeforeItCutsItsBaseline_handBack4() async throws {
        // A new Mac must not send its baseline before it has seen what its trusted devices saved: the adapters are
        // registered, ONE pull runs, and only then is the baseline cut and sent.
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let outbox = CaptureTestOutbox()
        let first = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64), stateRoot: f.stateRoot, rows: ["I01", "I05"])
        try await first.start(outbox: outbox)
        let order = await outbox.order
        let pull = try #require(order.firstIndex(of: "pull"))
        let setup = try #require(order.firstIndex(of: "setup"))
        let lastRegister = try #require(order.lastIndex(of: "register"))
        #expect(lastRegister < pull)
        #expect(pull < setup)
        #expect(order.filter({ $0 == "pull" }).count == 1)
        await first.stop()
        // A later start has its baseline already: it neither cuts again nor pulls for it.
        let again = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64), stateRoot: f.stateRoot, rows: ["I01", "I05"])
        try await again.start(outbox: outbox)
        let later = await outbox.order
        #expect(later.filter({ $0 == "pull" }).count == 1)
        #expect(later.filter({ $0 == "setup" }).count == 1)
        await again.stop()
        await f.close()
        // No answer from Cloud at that pull does not stop the setup.
        let g = try CloudBrainMemoryFixture(); try await g.seed()
        let offline = CaptureTestOutbox()
        await offline.setFailPull(true)
        let alone = try BackendCloudBrainMemoryActivation(store: g.store, deviceId: g.deviceId, subjectHash: String(repeating: "f", count: 64), stateRoot: g.stateRoot, rows: ["I01", "I05"])
        try await alone.start(outbox: offline)
        #expect(await offline.cuts.count == 1)
        await alone.stop()
        await g.close()
    }
    @Test func aSetupThatPublishesNoFirstUploadIsFinishedAndNeverRunAgain_feedOnly() async throws {
        // Sync trust core review, hand-back 3: in this version setup sends the baseline as ordinary packs and answers
        // "not published" with an empty id. That is success: memory starts, and the setup is not repeated.
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let outbox = CaptureTestOutbox()
        await outbox.setFeedOnly(true)
        let first = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64), stateRoot: f.stateRoot, rows: ["I01", "I05"])
        try await first.start(outbox: outbox)
        #expect(await outbox.cuts.count == 1)
        #expect(await f.store.cloudMemoryEnabled)
        // A change made after setup travels: capture and the pump are running.
        try await f.store.cloudImportFixtureSet("3", key: "tidy.hour")
        var sent = false
        for _ in 0..<100 where !sent {
            let parts = (try? await outbox.enqueuedParts()) ?? []
            sent = parts.contains(where: { $0.key.hasPrefix("row/settings/") })
            if !sent { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(sent)
        await first.stop()
        // The next start finds the setup finished: no second setup and no retry loop.
        let again = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64), stateRoot: f.stateRoot, rows: ["I01", "I05"])
        try await again.start(outbox: outbox)
        #expect(await outbox.cuts.count == 1)
        await again.stop()
        await f.close()
    }

    @Test func afterARestartCaptureWaitsForActivationWhichCatchesUpWithoutANewCut_finding15_M2() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture(); try await a.seed()
        let outbox = CaptureTestOutbox()
        let first = try BackendCloudBrainMemoryActivation(store: b.store, deviceId: b.deviceId, subjectHash: String(repeating: "f", count: 64), stateRoot: b.stateRoot, rows: ["I01", "I02"])
        try await first.start(outbox: outbox)
        #expect(await outbox.cuts.count == 1)
        await b.store.close() // quit, signed in
        let reopened = try await DeckMemoryStore.open(root: b.root, dataRoot: b.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        // M2: a local file never switches capture on; only the live account's activation does.
        #expect(!(await reopened.cloudMemoryEnabled))
        _ = try await reopened.appendDiary(.init(stamp: .hoot, role: .user, text: "after restart", externalID: "after-restart"))
        try FileManager.default.createDirectory(at: b.root.appendingPathComponent("hoot/notes"), withIntermediateDirectories: true)
        try Data("# Edited after restart\n".utf8).write(to: b.root.appendingPathComponent("hoot/notes/restart.md"))
        let second = try BackendCloudBrainMemoryActivation(store: reopened, deviceId: b.deviceId, subjectHash: String(repeating: "f", count: 64), stateRoot: b.stateRoot, rows: ["I01", "I02"])
        let later = CaptureTestOutbox()
        try await second.start(outbox: later)
        #expect(await later.cuts.isEmpty) // the saved cut is done: the reconcile catches up, no new full copy
        var spins = 0
        while spins < 500 {
            _ = try? await reopened.cloudMaintenanceStep(limit: 1000)
            let parts = try await later.enqueuedParts()
            let file = parts.contains { $0.key == "file/hoot/notes/restart.md" }
            let row = parts.contains { $0.key.hasPrefix("row/diary/") && (Data(base64Encoded: $0.data).map { String(decoding: $0, as: UTF8.self).contains("after restart") } ?? false) }
            if file && row { break }
            spins += 1; try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(spins < 500)
        let incoming = try await a.snapshot("I02").operations
        let adapter = try BackendCloudBrainMemory(store: reopened, deviceId: b.deviceId, inventoryRow: "I02", snapshotRoot: b.snapshotRoot)
        let prepared = try await adapter.validateIncoming(incoming, files: [])
        let receipt = try await adapter.applyPrepared(prepared, origin: .init(deviceId: a.deviceId, sequence: .init(1)))
        #expect(try await adapter.verify(receipt).verified)
        await second.stop(); await reopened.close(); await a.close(); try? FileManager.default.removeItem(at: b.base)
    }

    @Test func aSaveCapturesOnlyItsOwnFolder_finding12() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I01")
        try f.write("hoot/notes/new.md", "# New\nA new note.\n")
        try f.write("roles/other/notes/elsewhere.md", "# Elsewhere\nNot this seat.\n")
        await f.store.cloudCaptureAfterSave(.notes, .hoot, nil)
        let examined = await f.store.cloudFilesExamined
        let hootFiles = try await f.store.cloudSourceFiles(prefixes: ["hoot"]).count, allFiles = try await f.store.cloudSourceFiles().count
        #expect(examined == hootFiles && examined < allFiles)
        let keys = try await f.store.cloudFixtureJournalRows("I01")
        #expect(keys.contains("file/hoot/notes/new.md"))
        #expect(!keys.contains("file/roles/other/notes/elsewhere.md"))
        await f.close()
    }

    @Test func filesTheIndexDoesNotKnowStillTravel_finding20() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        try f.write("hoot/notes/picture.png", "not really a picture")
        try f.write("hoot/topics/t/extra.md", "# Deeper than the index looks\n")
        let snapshot = try await f.snapshot("I01")
        let keys = try snapshot.operations.map { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload)).key }
        #expect(keys.contains("file/hoot/notes/picture.png"))
        #expect(keys.contains("file/hoot/topics/t/extra.md"))
        #expect(snapshot.coverage.items == 7)
        await f.close()
    }

    @Test func aMessageWithANulCharacterSurvivesTheTriggerJournalAndImport_finding6() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.activate("I02"); try await b.activate("I02")
        let text = "before\0after 🌍"
        _ = try await a.store.appendDiary(.init(stamp: .hoot, role: .tool, text: text, externalID: "nul-trigger"))
        let outbox = CloudBrainMemoryOutboxFixture(), scope = String(repeating: "b", count: 64)
        let pump = try BackendCloudBrainMemoryPump(adapter: try a.adapter("I02"), outbox: outbox, subjectHash: scope)
        // One rule (1699f1977, 761c1c0b0): drainOnce also counts the one-rule maintenance work; count the queued operations only.
        _ = try await pump.drainOnce()
        #expect(await outbox.operations.count == 1)
        let operations = Array(await outbox.operations.values)
        _ = try await b.apply(operations, row: "I02")
        #expect(try await b.store.cloudFixtureDiaryTexts() == [text])
        // The pruned journal no longer holds the queued row (finding 8).
        #expect(try await a.store.cloudFixtureJournalRows("I02").count <= 1)
        await a.close(); await b.close()
    }
}

/// Fixture-only outbox for activation: records each cut and the first page's operations; never sends anything.
actor CaptureTestOutbox: CloudOutboxPort {
    var cuts: [String] = []
    var firstPages: [[CloudOperation]] = []
    var enqueued: [CloudOperation] = []
    func enqueuedParts() throws -> [CloudBrainMemoryPart] {
        try enqueued.map { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload)) }
    }
    private var failNext = false
    var failEnqueue = false
    var failEveryBootstrap = false
    /// As the sync core answers in this version: the baseline went out as ordinary packs, nothing was published.
    var feedOnly = false
    func setFeedOnly(_ value: Bool) { feedOnly = value }
    /// The order of the calls that matter for a first setup: "register", "pull", "setup".
    var order: [String] = []
    var failPull = false
    func setFailPull(_ value: Bool) { failPull = value }
    func failAfterFirstPage() { failNext = true }
    func setFailEnqueue(_ value: Bool) { failEnqueue = value }
    func setFailEveryBootstrap(_ value: Bool) { failEveryBootstrap = value }
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        if failEnqueue { throw CloudFailure.unavailable }
        enqueued += operations
        return .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: 0, savedAt: 1)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
    func flush() async throws -> [CloudReceipt] { [] }
    func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unsupportedFormat }
    func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
    func register(adapter: any CloudDomainAdapter) async throws { order.append("register") }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt {
        order.append("setup")
        cuts.append(cut.snapshotId)
        if failEveryBootstrap { throw CloudFailure.unavailable }
        var first: [CloudOperation]?
        for source in sources {
            for try await page in await source.snapshotPages(cut: cut) {
                if first == nil, !page.operations.isEmpty {
                    first = page.operations; firstPages.append(page.operations)
                    if failNext { failNext = false; throw CloudFailure.unavailable }
                }
            }
        }
        if feedOnly { return .init(checkpointId: "", throughSeq: .zero, verifiedBy: [], published: false) }
        return .init(checkpointId: UUID().uuidString, throughSeq: .zero, verifiedBy: [], published: true)
    }
    func pull() async throws -> [CloudImportReceipt] {
        order.append("pull")
        if failPull { throw CloudFailure.unavailable }
        return []
    }
    func setPaused(_ paused: Bool) async throws {}
}

extension DeckMemoryStore {
    func cloudFixtureExec(_ sql: String) throws { try db.exec(sql) }
    func cloudFixtureMainSchema() throws -> [String] { try db.rows("SELECT type||':'||name||':'||COALESCE(sql,'') FROM main.sqlite_master ORDER BY name").map { $0.text(0) } }
    func cloudFixtureControl(_ key: String) throws -> String? { try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(key)])?.string(0) }
}
