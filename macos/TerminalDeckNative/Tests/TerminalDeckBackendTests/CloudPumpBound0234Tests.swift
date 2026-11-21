import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Mac 0.23.4 hotfix, faults 1 and 3 (notes/release-20261120/DISK-CLOUD-FOLDER.md): the project-folders pump hands
/// nothing to the upload queue while that queue is full, the disk is low or a Mac of the account has not said it
/// understands project folders; it carries on at the owner's next look.
@Suite("Cloud 0.23.4 — project folders pump bound")
struct CloudPumpBound0234Tests {
    final class Knobs: @unchecked Sendable {
        private let lock = NSLock()
        private var _queued: Int64? = 0, _free: Int64? = 100 << 30, _gate = true
        var queued: Int64? { get { lock.withLock { _queued } } set { lock.withLock { _queued = newValue } } }
        var free: Int64? { get { lock.withLock { _free } } set { lock.withLock { _free = newValue } } }
        var gate: Bool { get { lock.withLock { _gate } } set { lock.withLock { _gate = newValue } } }
    }
    /// The fixture outbox, measuring its queue as the knobs say.
    struct MeasuredOutbox: CloudOutboxPort {
        let base: CloudBrainMemoryOutboxFixture
        let knobs: Knobs
        func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt { try await base.enqueue(operations, files: files) }
        func coverage(sourceId: String) async throws -> CloudCoverage { try await base.coverage(sourceId: sourceId) }
        func flush() async throws -> [CloudReceipt] { try await base.flush() }
        func restoreProgress() async throws -> CloudRestoreProgress { try await base.restoreProgress() }
        func contextReady(projectId: String) async throws -> CloudContextReady { try await base.contextReady(projectId: projectId) }
        func register(adapter: any CloudDomainAdapter) async throws { try await base.register(adapter: adapter) }
        func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { try await base.bootstrap(snapshots) }
        func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { try await base.bootstrap(sources: sources, cut: cut) }
        func pull() async throws -> [CloudImportReceipt] { try await base.pull() }
        func setPaused(_ paused: Bool) async throws { try await base.setPaused(paused) }
        func queuedBytes(domain: String, stopAfter: Int64) async throws -> Int64? { knobs.queued }
    }

    @Test func aFullQueueLowDiskOrClosedGateHoldsAndTheNextLookCarriesOn() async throws {
        let f = try CloudBrainFilesFixture(); defer { f.close() }
        try f.write("a/notes/plan.md", "v1\n")
        let a = try f.notes("a", device: f.deviceA)
        _ = try await CloudBrainFilesFixture.snapshot(a)
        try f.write("a/notes/plan.md", "v2, recorded and waiting in the engine\n")
        #expect(try await a.reconcile().journaled == 1)
        let knobs = Knobs(), fixture = CloudBrainMemoryOutboxFixture()
        let bound = BackendCloudBrainFilesPumpBound(domain: "project-folders", freeDisk: { knobs.free }, gateOpen: { knobs.gate })
        #expect(bound.queuedBytes == 256 * 1024 * 1024 && bound.minimumFreeBytes == 5 * 1024 * 1024 * 1024)
        let pump = try BackendCloudBrainFilesPump(engine: a, outbox: MeasuredOutbox(base: fixture, knobs: knobs),
                                                  subjectHash: String(repeating: "ab", count: 32), bound: bound)
        // Fault 1: the queue already holds 256 MB or more of this kind.
        knobs.queued = 300 * 1024 * 1024
        #expect(try await pump.drainOnce() == 0)
        #expect(await pump.holding)
        // Fault 1: under 5 GB free on the disk.
        knobs.queued = 0; knobs.free = 4 << 30
        #expect(try await pump.drainOnce() == 0)
        // Fault 3: a Mac of the account has not said it understands project folders.
        knobs.free = 100 << 30; knobs.gate = false
        #expect(try await pump.drainOnce() == 0)
        // A queue that cannot be measured holds too.
        knobs.gate = true; knobs.queued = nil
        #expect(try await pump.drainOnce() == 0)
        #expect(await fixture.operations.isEmpty, "nothing was handed over while held")
        // Room again: the owner's next look carries on.
        knobs.queued = 0
        await pump.resumeIfHolding()
        #expect(await pump.holding == false)
        let sent = await fixture.operations.values
        let texts = sent.compactMap { operation in (try? CloudBrainFilesFixture.part(operation)).flatMap { part in Data(base64Encoded: part.data) } }
        #expect(texts.contains(Data("v2, recorded and waiting in the engine\n".utf8)))
    }

    @Test func onlyProjectFoldersAreBoundOtherKindsKeepTheirOwnCaps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudPumpBound0234-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString
        let projects = try BackendCloudFolder(deviceId: id, folder: root.appendingPathComponent("p-root"), stateRoot: root.appendingPathComponent("p-state"),
                                              kind: .projectFolders, roots: CloudFolderRoots(many: [:]), everyMacUnderstands: { false })
        let cloudFolder = try BackendCloudFolder(deviceId: id, folder: root.appendingPathComponent("c-root"), stateRoot: root.appendingPathComponent("c-state"),
                                                 everyMacUnderstands: { true })
        let bound = try #require(await projects.pumpBound())
        #expect(bound.domain == CloudFileKind.projectFolders.domain)
        #expect(CloudSyncStore.releasedOnAcknowledge == [CloudFileKind.projectFolders.domain])
        #expect(await bound.gateOpen() == false, "the pump asks the same every-Mac gate as the look")
        #expect(await cloudFolder.pumpBound() == nil)
    }
}
