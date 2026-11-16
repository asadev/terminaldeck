import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 13 Nov blocker (two-Mac proof: nothing synced): memory and file operation ids were made in the version-5 layout, and
/// the sync core packs only version-4 ids, so the first saved copy stopped at its first record (`invalidRequest`)
/// before anything was sent. Every operation an adapter hands the sync core must pass the core's own pack check.
@Suite("Cloud operation ids are packable")
struct CloudOperationIdLayoutTests {
    @Test func everyMemoryRowSnapshotPacks() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        var total = 0
        for row in CloudBrainMemoryFormat.inventoryRows {
            let operations = try await f.snapshot(row).operations
            try CloudSyncPack.validate(operations)
            for op in operations { try CloudSyncBytes.transportID(op.opId); for parent in op.parents { try CloudSyncBytes.transportID(parent) } }
            total += operations.count
        }
        #expect(total > 0)
        await f.close()
    }
    @Test func fileSnapshotPacksAndStillImports() async throws {
        let f = try CloudBrainFilesFixture(); defer { f.close() }
        try f.write("a/notes/two-parts.bin", data: Data(repeating: 7, count: 40 * 1024))
        let a = try f.notes("a", device: f.deviceA), b = try f.notes("b", device: f.deviceB)
        let ops = try await CloudBrainFilesFixture.snapshot(a).operations
        #expect(ops.count == 2)
        try CloudSyncPack.validate(ops)
        // The receiving Mac accepts the new layout.
        _ = try await b.validateIncoming(ops, files: [])
    }
    /// A Mac that ran the broken build kept parts with version-5 ids (they never left it). They are made again.
    @Test func staleVersionFiveMemoryPartsAreMadeAgain() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let cut = UUID().uuidString
        let first = try await f.snapshot("I01", cut: cut).operations
        #expect(!first.isEmpty)
        let aged = try await f.store.cloudFixtureAgePartsToVersionFive()
        #expect(aged == first.count)
        let again = try await f.snapshot("I01", cut: cut).operations
        #expect(again.count == first.count)
        try CloudSyncPack.validate(again)
        #expect(try await f.store.cloudFixtureAgePartsCount() == 0)
        await f.close()
    }
    @Test func operationIdIsVersionFourAndStable() throws {
        let id = BackendCloudBrainMemoryHash.operationId("v\n0\ndevice")
        try CloudSyncBytes.transportID(id)
        #expect(id == BackendCloudBrainMemoryHash.operationId("v\n0\ndevice"))
        #expect(!BackendCloudBrainMemoryHash.isOperationId(BackendCloudBrainMemoryHash.uuid("v\n0\ndevice")))
        try CloudSyncBytes.transportID(DeckMemoryStore.cloudOperationId(version: UUID().uuidString.lowercased(), index: 0, device: UUID().uuidString.lowercased()))
    }
}

extension DeckMemoryStore {
    /// Fixture-only: rewrites every stored part's operation id to the version-5 layout an older build made.
    func cloudFixtureAgePartsToVersionFive() throws -> Int {
        var aged = 0
        for row in try db.rows("SELECT op_id FROM cloud_memory_parts") {
            let id = row.text(0)
            var chars = Array(id); chars[14] = "5"; let old = String(chars)
            try db.run("UPDATE cloud_memory_parts SET op_id=?, operation=CAST(replace(CAST(operation AS TEXT), ?, ?) AS BLOB) WHERE op_id=?", [.text(old), .text(id), .text(old), .text(id)])
            aged += 1
        }
        return aged
    }
    func cloudFixtureAgePartsCount() throws -> Int { Int(try db.first("SELECT COUNT(*) FROM cloud_memory_parts WHERE substr(op_id,15,1)='5'")?.int(0) ?? 0) }
}
