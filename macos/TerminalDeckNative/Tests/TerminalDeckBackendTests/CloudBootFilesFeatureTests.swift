import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only outbox: counts what an adapter registers and sends. No network, no store.
actor CloudBootFilesOutboxFixture: CloudOutboxPort {
    private(set) var sent: [CloudOperation] = []
    private(set) var adapters = 0
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        guard files.isEmpty else { throw CloudFailure.unsupportedFormat }
        sent += operations
        return .init(operationIds: operations.map { $0.opId }, queued: sent.count, bytes: 0, savedAt: 1)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unsupportedFormat }
    func flush() async throws -> [CloudReceipt] { throw CloudFailure.unsupportedFormat }
    func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unsupportedFormat }
    func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unsupportedFormat }
    func register(adapter: any CloudDomainAdapter) async throws { adapters += 1 }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func pull() async throws -> [CloudImportReceipt] { [] }
    func setPaused(_ paused: Bool) async throws {}
    func count() -> Int { sent.count }
    func domains() -> Set<String> { Set(sent.map { $0.domain }) }
}

@Suite("Cloud boot files: what lane A is handed")
struct CloudBootFilesFeatureTests {
    typealias F = CloudBootFilesFixture

    /// Waits (at most five seconds) for the pump, which runs on its own task.
    func reaches(_ outbox: CloudBootFilesOutboxFixture, _ wanted: Int) async -> Bool {
        for _ in 0..<100 {
            if await outbox.count() == wanted { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await outbox.count() == wanted
    }

    @Test func nothingIsSentUntilStartedAndNothingAfterStopped() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "rules\n")
        let outbox = CloudBootFilesOutboxFixture()
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        // Built and given its places, but not started: it is not part of the sync core and sends nothing.
        try await Task.sleep(for: .milliseconds(200))
        let before = await outbox.count(), joined = await outbox.adapters
        #expect(before == 0 && joined == 0)
        try await a.start(outbox: outbox, subjectHash: String(repeating: "f", count: 64))
        let first = await reaches(outbox, 1)
        #expect(first)
        let registered = await outbox.adapters
        #expect(registered == 1)
        // A second start is the same start.
        try await a.start(outbox: outbox, subjectHash: String(repeating: "f", count: 64))
        let registeredAgain = await outbox.adapters
        #expect(registeredAgain == 1)
        try f.write("a/app/AGENTS.md", "more\n")
        try await a.refresh()
        let second = await reaches(outbox, 2)
        #expect(second)
        let domains = await outbox.domains()
        #expect(domains == ["brain/files/i09"])
        // A place added while running keeps the journal going out.
        try f.write("a/other/CLAUDE.md", "other\n")
        try await a.setPlaces([f.project("p", "a/app"), f.project("q", "a/other")])
        let third = await reaches(outbox, 3)
        #expect(third)
        // Stopped (sign-out, a closed gate): a later change stays on this Mac.
        await a.stop()
        try f.write("a/app/GEMINI.md", "later\n")
        try await a.refresh()
        try await Task.sleep(for: .milliseconds(300))
        let after = await outbox.count()
        #expect(after == 3)
    }

    @Test func theOneToolOnlyListsAndNoToolCanAccept() async throws {
        let contribution = BackendCloudBootFilesFeature.contribution
        #expect(contribution.owner == "F" && contribution.inventoryRows == ["I09"] && contribution.tools.count == 1)
        let tool = try #require(contribution.tools.first)
        #expect(tool.id == "cloud.boot_files" && !tool.mutates && tool.inventoryRows == ["I09"])
        // Accept and keep-mine are never declared as actions (anything listed there could become a tool).
        let declared = contribution.actions
        #expect(declared == ["boot_files.refresh"])
        for name in BackendCloudBootFilesFeature.neverActions {
            #expect(!declared.contains(name), "\(name)")
        }
        #expect(!declared.contains(where: { $0.contains("accept") || $0.contains("keep") }))

        let f = try F(); defer { f.close() }
        let script = ".claude/skills/s/run.sh"
        try f.write("a/app/" + script, "#!/bin/sh\necho secret-marker\n")
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let operations = try await F.snapshot(a).operations
        try await F.apply(b, operations, device: f.deviceA)
        let listed = try await b.tool(arguments: CloudValue(.object([.init("action", .string("list"))])))
        let rows = listed.raw["items"].elements ?? []
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row["kind"].string == "needs-accept" && row["path"].string == script && row["canAccept"].bool == true && row["from"].string == f.deviceA)
        // Paths and reasons only: never a file's text.
        let bytes = try CloudWire.canonical(listed)
        let wire = String(decoding: bytes, as: UTF8.self)
        #expect(!wire.contains("secret-marker"))
        // Nothing but "list": no tool accepts, keeps or writes.
        for action in ["accept", "dismiss", "keep_mine", "write", "refresh"] {
            await #expect(throws: CloudFailure.invalidRequest) {
                _ = try await b.tool(arguments: CloudValue(.object([.init("action", .string(action))])))
            }
        }
        await #expect(throws: CloudFailure.invalidRequest) {
            _ = try await b.tool(arguments: CloudValue(.object([.init("action", .string("list")), .init("id", .string("x"))])))
        }
        #expect(!f.exists("b/app/" + script))
    }
}
