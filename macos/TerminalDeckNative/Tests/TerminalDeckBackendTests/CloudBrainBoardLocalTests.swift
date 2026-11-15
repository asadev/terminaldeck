import Foundation
import Testing
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// MAC-NEXT-8 (real check 4, 13 Nov): one second after its relaunch the MacBook sent 345 board records: 115 versions of
/// each of 3 board rows it had RECEIVED from the Mac mini (same bytes), under its own device id, each its own branch,
/// so each row held 116 open heads on both Macs. Decker's decision: the live board is this Mac's own state and does not
/// travel (the identity rule for every other kind: CloudBrainIdentityEchoTests).
@Suite("Cloud brain — the live board stays on each device; received versions never go back", .serialized)
struct CloudBrainBoardLocalTests {
    static let otherStore = "bbe61469-0fb5-441c-bdac-2aa9258682c2"
    static let deviceA = "0e4823da-0000-4000-8000-000000000001"

    /// One version of a row as a Mac sends it: chained to the previous version of the same row (single writer).
    private func op(row: String, key: String, body: Data, previous: String?) throws -> (CloudOperation, String) {
        let version = UUID().uuidString.lowercased(), hash = DeckMemoryFiles.hash(body)
        let parents = previous.map { [$0] } ?? []
        let payload = CloudBrainMemoryPart(storeId: Self.otherStore, inventoryRow: row, key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, parents: parents, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        let operation = CloudOperation(v: 1, opId: revision, originDevice: Self.deviceA, domain: CloudBrainMemoryFormat.domain(row),
                                       entityId: BackendCloudBrainMemoryHash.uuid(Self.otherStore + "\n" + key + "\n0"), revision: revision,
                                       parents: parents.map { BackendCloudBrainMemoryHash.uuid($0 + "\n0") }, kind: .put,
                                       source: .init(sourceId: "memory/" + row, recordId: key, offset: 0, rawHash: hash), createdAt: 1,
                                       payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
        return (operation, version)
    }
    /// The Mac mini's live status card of one project, written `count` times (it changes every few seconds there).
    private func boardVersions(_ id: String, count: Int) throws -> [CloudOperation] {
        let t = try DeckMemoryCloudSchema.table("board")
        var previous: String?, all: [CloudOperation] = []
        for n in 0..<count {
            var values = [DeckMemorySQL](repeating: .null, count: t.columns.count)
            func set(_ c: String, _ v: DeckMemorySQL) { values[t.columns.firstIndex(of: c)!] = v }
            set("id", .text(id)); set("kind", .text("project")); set("title", .text("terminal-deck")); set("owner", .text("hoot"))
            set("doing", .text(n % 2 == 0 ? "Working" : "Idle")); set("last_result", .text("")); set("waiting", .text("")); set("proof", .text(""))
            set("updated", .real(1_000_000 + Double(n)))
            let (operation, version) = try op(row: "I03", key: try DeckMemoryCloudSchema.key(t, values), body: try DeckMemoryCloudSchema.encodeRow(t, values), previous: previous)
            all.append(operation); previous = version
        }
        return all
    }
    private func localChanges(_ f: CloudBrainMemoryFixture, _ row: String) async throws -> [CloudOperation] {
        let adapter = try f.adapter(row)
        var cursor: String?, all: [CloudOperation] = []
        while let change = try await adapter.localChange(after: cursor) { all.append(change.operation); cursor = change.cursor }
        return all
    }
    private func settle(_ f: CloudBrainMemoryFixture, full: Bool = true) async throws {
        try await f.store.cloudStartReconcile(full: full)
        var steps = 0
        while try await f.store.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
    }

    @Test func boardStatusWrittenHereProducesZeroOutgoingRecordsAndNoFirstCopy() async throws {
        let a = try CloudBrainMemoryFixture()
        try await a.activate("I03")
        for n in 0..<188 {
            _ = try await a.store.updateBoard(.init(id: "project:terminal-deck", kind: .project, stamp: .hoot, title: "terminal-deck", doing: n % 2 == 0 ? "Working" : "Idle"))
        }
        try await settle(a)
        #expect(try await localChanges(a, "I03").isEmpty, "the live board does not travel")
        #expect(try await a.snapshot("I03").operations.isEmpty, "nor is it in a first copy")
        #expect(try await a.store.cloudInventory(row: "I03").complete)
        await a.close()
    }

    @Test func aBoardRowWrittenManyTimesOnAnotherMacIsIgnoredHereAndNothingGoesBackAlsoAfterARelaunch() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I03"); try await b.activate("I05")
        let versions = try boardVersions("project:terminal-deck", count: 188)
        // As fetched: small packs over the day.
        for start in stride(from: 0, to: versions.count, by: 3) {
            let receipt = try await b.apply(Array(versions[start..<min(start + 3, versions.count)]), row: "I03")
            #expect(receipt.results.allSatisfy { $0.status == .alreadyPresent && $0.reason == DeckMemoryStore.cloudLocalOnlyIgnored })
        }
        #expect(try await b.store.board(.init()).isEmpty, "another Mac's live status is not placed here")
        #expect(try await b.store.cloudWaitingCount() == 0, "nor kept waiting")
        try await settle(b)
        #expect(try await localChanges(b, "I03").isEmpty)
        // What an older build left queued for the board (one journal row per received version) is dropped, not sent.
        try await b.store.cloudFixtureQueueBoardLeftovers(versions)
        #expect(try await localChanges(b, "I03").isEmpty, "leftovers of an older build never go out")
        // Relaunch: a new store object on the same folders, capture resumed, the launch reconcile planned and run.
        await b.store.close()
        let again = try DeckMemoryStore(root: b.root, dataRoot: b.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        try await again.cloudResumeCapture(stateRoot: b.stateRoot)
        try await again.cloudPlanReconcile()
        var steps = 0
        while try await again.cloudMaintenanceStep(limit: 1000) > 0, steps < 40 { steps += 1 }
        let adapter = try BackendCloudBrainMemory(store: again, deviceId: b.deviceId, inventoryRow: "I03", snapshotRoot: b.snapshotRoot)
        #expect(try await adapter.localChange(after: nil) == nil, "zero records after the relaunch")
        await again.close()
        try? FileManager.default.removeItem(at: b.base)
    }

    @Test func aSyncStoreWith116HeadsPerBoardRowKeepsTheNewestAndSendsNothing() throws {
        let root = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("a-sync-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = CloudBrainMemoryFormat.domain("I03"), entity = UUID().uuidString.lowercased()
        // Transport ids as the service hands them out (random v4).
        func record(parents: [String], device: String = Self.deviceA) throws -> CloudOperation {
            let id = UUID().uuidString.lowercased()
            let value = try JSONDecoder().decode(CloudValue.self, from: Data("{\"n\":\"\(id)\"}".utf8))
            return CloudOperation(v: 1, opId: id, originDevice: device, domain: domain, entityId: entity, revision: id, parents: parents, kind: .put,
                                  source: .init(sourceId: "memory/I03", recordId: "row/board/x", offset: 0, rawHash: id), createdAt: 1,
                                  payload: value, payloadHash: CloudSyncBytes.hash(try CloudSyncCanonical.encode(value)))
        }
        let base = try record(parents: [])
        // 115 branches off one base, as the echo left them (all children of the same parent, none of each other).
        let echoes = try (0..<115).map { _ in try record(parents: [base.opId], device: "f465bd62-0000-4000-8000-000000000002") }
        let later = try record(parents: [base.opId])
        do {
            let store = try CloudSyncStore(root: root, subject: CloudUpgradeFromShip0220Tests.subject)
            try store.remember([base])
            // Written as an older build wrote them: every branch its own head.
            for echo in echoes {
                try store.execute("INSERT OR IGNORE INTO records(opId,bytes) VALUES (?,?)", [Data(echo.opId.utf8), try CloudSyncCanonical.encode(echo)])
                try store.indexOperation(echo)
                try store.execute("INSERT OR IGNORE INTO entity_heads(domain,entityId,revision) VALUES (?,?,?)", [Data(domain.utf8), Data(echo.entityId.utf8), Data(echo.opId.utf8)])
            }
            try store.execute("DELETE FROM entity_heads WHERE revision=?", [Data(base.opId.utf8)])
            #expect(try store.headCounts(domain: domain)[entity] == 115)
        }
        // The next launch: one head, the newest; nothing queued to send.
        let reopened = try CloudSyncStore(root: root, subject: CloudUpgradeFromShip0220Tests.subject)
        #expect(try reopened.headCounts(domain: domain)[entity] == 1)
        let newest = try #require(echoes.last)
        #expect(try !reopened.rows("SELECT 1 FROM entity_heads WHERE revision=?", [Data(newest.opId.utf8)]).isEmpty)
        #expect(try reopened.queuedCount() == 0)
        // A later arrival of the same kind (an older build still sending) keeps it at one.
        try reopened.remember([later])
        #expect(try reopened.headCounts(domain: domain)[entity] == 1)
    }
}

extension DeckMemoryStore {
    /// What an older build journaled: one row per version, exactly the received bytes.
    func cloudFixtureQueueBoardLeftovers(_ ops: [CloudOperation]) throws { try cloudFixtureQueueRows(ops) }
    func cloudFixtureQueueRows(_ ops: [CloudOperation]) throws {
        for op in ops {
            let part = try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload))
            guard let body = Data(base64Encoded: part.data) else { continue }
            let (t, values) = try DeckMemoryCloudSchema.decodeRow(body)
            // The row as it stands here (an arrived row keeps its original keys in the journal body).
            try db.run("INSERT INTO cloud_memory_journal(inventory,resource_key,body,hash,base_version) VALUES (?,?,?,'',NULL)",
                       [.text(t.row), .text("row/" + t.name), .blob(try DeckMemoryCloudSchema.encodeRow(t, values))])
        }
    }
}
