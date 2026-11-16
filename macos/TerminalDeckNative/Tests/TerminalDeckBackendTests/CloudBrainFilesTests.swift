import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud file rows — shared engine statements")
struct CloudBrainFilesTests {
    typealias F = CloudBrainFilesFixture

    @Test func everyByteSurvivesAToBIncludingEmptyAndMultiPartFiles() async throws {
        let f = try F(); defer { f.close() }
        let big = Data((0..<(70 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try f.write("a/notes/one.md", "first\n"); try f.write("a/notes/empty.txt", ""); try f.write("a/notes/deep/big.bin", data: big)
        let a = try f.notes("a", device: f.deviceA), b = try f.notes("b", device: f.deviceB)
        let snapshot = try await F.snapshot(a)
        #expect(snapshot.operations.count == 1 + 1 + 3) // 70 KiB = three 32 KiB parts
        #expect(snapshot.coverage.count == 1 && snapshot.coverage[0].complete && snapshot.coverage[0].items == 3)
        #expect(snapshot.operations.allSatisfy { $0.opId == $0.revision })
        #expect(try snapshot.operations.allSatisfy { try CloudWire.canonical($0.payload).count < 65_536 })
        let receipt = try await F.apply(b, snapshot.operations, device: f.deviceA)
        #expect(receipt.counts.records == 3)
        #expect(try f.read("b/notes/one.md") == Data("first\n".utf8))
        #expect(try f.read("b/notes/empty.txt").isEmpty)
        #expect(try f.read("b/notes/deep/big.bin") == big)
        // Re-snapshotting an unchanged folder yields the identical operation bytes (deduplicated by id).
        let again = try await F.snapshot(a)
        #expect(again.operations == snapshot.operations)
    }

    @Test func aRepeatAppliesOnceAndDifferentBytesForTheSameIdAreRefused_S03() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/notes/n.md", "kept once\n")
        let a = try f.notes("a", device: f.deviceA), b = try f.notes("b", device: f.deviceB)
        let ops = try await F.snapshot(a).operations
        let first = try await F.apply(b, ops, device: f.deviceA)
        let second = try await F.apply(b, ops, device: f.deviceA)
        #expect(first == second)
        #expect(try f.read("b/notes/n.md") == Data("kept once\n".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.url("b/notes").path).filter { !$0.hasPrefix(".") } == ["n.md"])
        await #expect(throws: CloudFailure.idReused) { _ = try await b.validateIncoming([try F.tampered(ops[0])], files: []) }
    }

    @Test func anExistingDifferentFileIsKeptAndTheIncomingVersionRetainedBeside_S05() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/notes/card.md", "from the other Mac\n"); try f.write("b/notes/card.md", "already here\n")
        let a = try f.notes("a", device: f.deviceA), b = try f.notes("b", device: f.deviceB)
        let receipt = try await F.apply(b, try await F.snapshot(a).operations, device: f.deviceA)
        #expect(receipt.results.map { $0.status } == [.keptBoth])
        #expect(try f.read("b/notes/card.md") == Data("already here\n".utf8))
        let conflicts = f.url("b/state/conflicts")
        let kept = try FileManager.default.subpathsOfDirectory(atPath: conflicts.path).filter { $0.hasSuffix("/card.md") }
        #expect(kept.count == 1)
        #expect(try Data(contentsOf: conflicts.appendingPathComponent(kept[0])) == Data("from the other Mac\n".utf8))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: conflicts.path).contains { $0.hasSuffix("provenance.json") })
    }

    @Test func aDamagedPartOrHashAppliesZeroBytes_S06() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/notes/two-parts.bin", data: Data(repeating: 7, count: 40 * 1024))
        let a = try f.notes("a", device: f.deviceA), b = try f.notes("b", device: f.deviceB)
        let ops = try await F.snapshot(a).operations
        #expect(ops.count == 2)
        // Internally consistent but wrong content: the whole-file hash refuses it before anything is placed.
        let damaged = [ops[0], try F.tampered(ops[1])]
        let prepared = try await b.validateIncoming(damaged, files: [])
        await #expect(throws: CloudFailure.checksumMismatch) { _ = try await b.applyPrepared(prepared, origin: .init(deviceId: f.deviceA, sequence: .init(1))) }
        #expect(!f.exists("b/notes/two-parts.bin"))
        #expect(try await b.readiness().verified == false)
        // A payload whose declared hash does not match is refused before staging.
        let wrongHash = CloudOperation(v: 1, opId: ops[0].opId, originDevice: ops[0].originDevice, domain: ops[0].domain, entityId: ops[0].entityId,
                                       revision: ops[0].revision, parents: ops[0].parents, kind: .put, source: ops[0].source, createdAt: ops[0].createdAt,
                                       payload: ops[0].payload, payloadHash: String(repeating: "0", count: 64))
        let other = try f.notes("c", device: f.deviceB)
        await #expect(throws: CloudFailure.checksumMismatch) { _ = try await other.validateIncoming([wrongHash], files: []) }
        #expect(!f.exists("c/notes/two-parts.bin"))
        // A key outside the source's allowed paths cannot place anything.
        let p = try F.part(ops[0])
        let escaped = CloudBrainMemoryPart(storeId: p.storeId, inventoryRow: p.inventoryRow, key: "file/notes/../escape.bin", version: p.version,
                                           resourceHash: p.resourceHash, bytes: p.bytes, index: p.index, count: p.count, parents: p.parents, data: p.data)
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(escaped))
        let escape = CloudOperation(v: 1, opId: ops[0].opId, originDevice: ops[0].originDevice, domain: ops[0].domain,
                                    entityId: BackendCloudBrainMemoryHash.uuid(p.storeId + "\nfile/notes/../escape.bin\n0"), revision: ops[0].revision,
                                    parents: ops[0].parents, kind: .put, source: .init(sourceId: ops[0].source.sourceId, recordId: "file/notes/../escape.bin"),
                                    createdAt: ops[0].createdAt, payload: value, payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
        await #expect(throws: CloudFailure.invalidRequest) { _ = try await other.validateIncoming([escape], files: []) }
    }

    @Test func anOfflineEditSurvivesRestartAndIsSentExactlyOnce_S07() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/notes/plan.md", "v1\n")
        let subject = String(repeating: "ab", count: 32), outbox = CloudBrainMemoryOutboxFixture()
        do {
            let a = try f.notes("a", device: f.deviceA)
            _ = try await F.snapshot(a)
            try f.write("a/notes/plan.md", "v2 written while offline\n")
            #expect(try await a.reconcile().journaled == 1)
        }
        // A new process: same state folder, nothing kept in memory.
        let restarted = try f.notes("a", device: f.deviceA)
        let pump = try BackendCloudBrainFilesPump(engine: restarted, outbox: outbox, subjectHash: subject)
        let sent = try await pump.drainOnce(limit: 128)
        #expect(sent >= 1)
        #expect(try await pump.drainOnce(limit: 128) == 0)
        #expect(try await restarted.reconcile().journaled == 0)
        let ops = Array(await outbox.operations.values)
        let parts = try ops.map { try F.part($0) }
        let latest = try #require(parts.first { Data(base64Encoded: $0.data) == Data("v2 written while offline\n".utf8) })
        #expect(latest.parents.count == 1)
        #expect(Set(ops.map { $0.opId }).count == ops.count)
    }

    @Test func aLocalRemovalBecomesAnArchiveMarkerNotADeletion_S15() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/notes/old.md", "history\n"); try f.write("a/notes/keep.md", "still here\n")
        let a = try f.notes("a", device: f.deviceA), b = try f.notes("b", device: f.deviceB)
        _ = try await F.apply(b, try await F.snapshot(a).operations, device: f.deviceA)
        let (_, cursor) = try await F.local(a)
        try FileManager.default.removeItem(at: f.url("a/notes/old.md"))
        #expect(try await a.reconcile().archived == 1)
        let removal = try await F.local(a, after: cursor).operations
        #expect(removal.map { $0.kind } == [.archive])
        let receipt = try await F.apply(b, removal, device: f.deviceA)
        #expect(receipt.results.first?.reason == "archive_marker_kept")
        #expect(try f.read("b/notes/old.md") == Data("history\n".utf8))
        // An unreadable folder never turns into removals.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.url("a/notes").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url("a/notes").path) }
        #expect(try await a.reconcile().archived == 0)
    }

    @Test func enumerationHasNoCapAndUnreadableOrMissingSourcesStayVisible_S16() async throws {
        let f = try F(); defer { f.close() }
        for i in 0..<10_050 { try f.write("a/notes/many/\(i).md", "x") }
        try f.write("a/notes/" + (0..<40).map { "d\($0)" }.joined(separator: "/") + "/deep.md", "deep")
        let a = try f.notes("a", device: f.deviceA)
        let complete = try await a.sourceInventory()
        #expect(complete[0].items == 10_051 && complete[0].complete)
        try f.write("a/notes/locked/secret.md", "x")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: f.url("a/notes/locked").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.url("a/notes/locked").path) }
        let blocked = try await a.sourceInventory()
        #expect(!blocked[0].complete && !blocked[0].blockedReasons.isEmpty)
        let missing = try f.notes("nowhere/at/all", device: f.deviceA, optional: false)
        let gone = try await missing.sourceInventory()
        #expect(!gone[0].complete && gone[0].items == 0 && !gone[0].blockedReasons.isEmpty)
    }

    @Test func constructionAndInventoryCreateNothing() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/notes/n.md", "x")
        let a = try f.notes("a", device: f.deviceA)
        _ = try await a.sourceInventory()
        #expect(!f.exists("a/state"))
    }
}
