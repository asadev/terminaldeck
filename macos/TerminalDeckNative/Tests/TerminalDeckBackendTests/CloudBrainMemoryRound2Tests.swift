import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Review round 2 (M1, M5, M6, M8, M9, M11): memory writes never fail because of Cloud, what never travels is named,
/// a crash or a stop at the wrong moment cannot wedge activation.
@Suite("Cloud memory capture — round 2: never fails a write, names exclusions, survives stops and crashes", .serialized)
struct CloudBrainMemoryRound2Tests {
    @Test func aBrokenCloudDatabaseNeverFailsAMemoryWriteAndCatchesUpAfterHealing_M1() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        // Only I02 is enabled, as in the app (every enabled row is cut together). With all rows captured but only I02
        // cut, the full pass after healing also sent rows of never-exported rows (for example the rewind's marked
        // message, R7), which is not what this test measures.
        try await f.store.cloudResumeCapture(stateRoot: f.stateRoot, rows: ["I02"])
        try await f.activate("I02")
        #expect(try await f.store.cloudFixtureJournalRows("I02").isEmpty)
        // The account folder refuses new files: the side database cannot create its rollback journal.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.stateRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.stateRoot.path) }
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "saved anyway", externalID: "m1-missed"))
        #expect(try await f.store.cloudFixtureDiaryTexts().contains("saved anyway"))
        #expect(!(await f.store.cloudMemoryEnabled))
        #expect(await f.store.cloudCaptureLost)
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        let paused = try await f.adapter("I02").sourceInventory()[0]
        #expect(!paused.complete && !paused.blockedReasons.isEmpty)
        // While broken, further writes keep working and nothing retries capture.
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "still saved", externalID: "m1-second"))
        #expect(try await f.store.cloudFixtureDiaryTexts().contains("still saved"))
        // Healed: triggers come back first, then the reconcile journals exactly the rows that were missed.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.stateRoot.path)
        var steps = 0
        while try await f.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 20 { steps += 1 }
        #expect(await f.store.cloudMemoryEnabled)
        #expect(!(try await f.store.cloudFixtureTempTriggers()).isEmpty)
        #expect(try await f.store.cloudFixtureJournalRows("I02").count == 2)
        await f.close()
    }

    @Test func hiddenFilesAndLinksStayOnThisMacAndNeverAbortTheCut_M5() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        try f.write("hoot/notes/.git/config", "[core]\n")
        try f.write(".obsidian/workspace.json", "{}")
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("hoot/notes/link.md"),
                                                   withDestinationURL: f.root.appendingPathComponent("hoot/notes/a.md"))
        let snapshot = try await f.snapshot("I01")
        let keys = try snapshot.operations.map { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload)).key }
        #expect(!keys.contains { $0.contains("/.") || $0.hasPrefix("file/.") })
        #expect(!keys.contains("file/hoot/notes/link.md"))
        #expect(snapshot.coverage.complete)
        #expect(snapshot.coverage.exclusions.contains { $0.hasPrefix("Hidden files and folders") })
        #expect(snapshot.coverage.exclusions.contains { $0.hasPrefix("Linked files and folders") })
        await f.close()
    }

    @Test func theAppsOwnHelpFilesNeverTravel_M6() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        try await f.store.writeStartHere()
        #expect(FileManager.default.fileExists(atPath: f.root.appendingPathComponent("START-HERE.md").path))
        let snapshot = try await f.snapshot("I01")
        let keys = try snapshot.operations.map { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical($0.payload)).key }
        #expect(!keys.contains("file/START-HERE.md"))
        #expect(!keys.contains("file/CLAUDE.md"))
        #expect(snapshot.coverage.exclusions.contains { $0.hasPrefix("The app's own help files") })
        await f.close()
    }

    @Test func aCrashBetweenPublishingTheCutFolderAndRecordingItsHashIsRecovered_M8() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let outbox = CaptureTestOutbox(); await outbox.failAfterFirstPage()
        let first = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64),
                                                          stateRoot: f.stateRoot, rows: ["I02"], now: { 1000 }, retryDelays: [])
        await #expect(throws: CloudFailure.unavailable) { try await first.start(outbox: outbox) }
        // Out of retries, capture is off (round 3, M1b limit 3); re-attach to plant the crash window:
        // the cut folder with its header is in place, its hash was never recorded.
        try await f.capture()
        try await f.store.cloudFixtureDeleteControl(prefix: "snapshotHash:")
        await f.store.cloudFixtureForgetSnapshots()
        let second = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64),
                                                           stateRoot: f.stateRoot, rows: ["I02"], now: { 1000 }, retryDelays: [])
        try await second.start(outbox: outbox)
        let cuts = await outbox.cuts
        #expect(cuts.count == 2 && cuts[0] == cuts[1])
        await second.stop(); await first.stop(); await f.close()
    }

    @Test func anOutsideEditLooksAtThatFileOnly_M9() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I01")
        try f.write("hoot/notes/outside.md", "# Outside\nEdited by another program.\n")
        let base = f.root.resolvingSymlinksInPath().path
        await f.store.filesChanged([base + "/hoot/notes/outside.md"], rescan: false, base: base)
        #expect(await f.store.cloudFilesExamined == 1)
        #expect(try await f.store.cloudFixtureControl("filesDirty") == nil)
        #expect(try await f.store.cloudFixtureJournalRows("I01").contains("file/hoot/notes/outside.md"))
        await f.close()
    }

    @Test func stoppingWhileTheFirstUploadRunsLeavesNoPumpAndNoCapture_M11() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let outbox = GatedBootstrapOutbox()
        let activation = try BackendCloudBrainMemoryActivation(store: f.store, deviceId: f.deviceId, subjectHash: String(repeating: "f", count: 64),
                                                               stateRoot: f.stateRoot, rows: ["I02"], now: { 1000 }, retryDelays: [])
        let started = Task { try await activation.start(outbox: outbox) }
        var spins = 0
        while await outbox.entered == false, spins < 5000 { spins += 1; try await Task.sleep(nanoseconds: 1_000_000) }
        #expect(await outbox.entered)
        await activation.stop()
        await outbox.release()
        await #expect(throws: CancellationError.self) { try await started.value }
        #expect(await activation.pumpCount == 0)
        #expect(!(await f.store.cloudMemoryEnabled))
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        // A late start on the stopped object is refused; it can never switch capture back on.
        await #expect(throws: CancellationError.self) { try await activation.start(outbox: outbox) }
        #expect(!(await f.store.cloudMemoryEnabled))
        await f.close()
    }
}

/// Fixture-only outbox whose first-setup call waits until the test releases it.
actor GatedBootstrapOutbox: CloudOutboxPort {
    var entered = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    func release() { released = true; waiting?.resume(); waiting = nil }
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        .init(operationIds: operations.map(\.opId), queued: operations.count, bytes: 0, savedAt: 1)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
    func flush() async throws -> [CloudReceipt] { [] }
    func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unsupportedFormat }
    func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
    func register(adapter: any CloudDomainAdapter) async throws {}
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt {
        entered = true
        if !released { await withCheckedContinuation { waiting = $0 } }
        return .init(checkpointId: UUID().uuidString, throughSeq: .zero, verifiedBy: [], published: true)
    }
    func pull() async throws -> [CloudImportReceipt] { [] }
    func setPaused(_ paused: Bool) async throws {}
}
