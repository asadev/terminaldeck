import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Import onto a Mac that already holds memory (review findings 14, 16, 17, 18/22, 19, 21). Scratch stores only.
@Suite("Cloud memory import — identical, seeded, conflicting and shared values")
struct CloudBrainMemoryImportTests {
    private func part(_ op: CloudOperation) throws -> CloudBrainMemoryPart {
        try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload))
    }
    private func ops(_ all: [CloudOperation], key: String) -> [CloudOperation] {
        all.filter { (try? part($0).key) == key }
    }
    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func files(under folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    private static let noteA = "---\nid: n-fixture-a\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Note\n"

    @Test func twoMacsWithTheSameShippedFilesExchangeWithoutConflict_14() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        // Both ran the real opening, so both wrote the app's identical template files and starter card.
        try await a.store.start(); try await b.store.start()
        try await b.activate("I01")
        let receipt = try await b.apply(try await a.snapshot("I01").operations, row: "I01")
        #expect(receipt.results.contains { $0.status == .alreadyPresent })
        #expect(!receipt.results.contains { $0.status == .keptBoth })
        let back = try await a.apply(try await b.snapshot("I01").operations, row: "I01")
        #expect(!back.results.contains { $0.status == .keptBoth })
        #expect(files(under: b.root.appendingPathComponent("archive/cloud-conflicts")).isEmpty)
        await a.close(); await b.close()
    }

    @Test func aSavedCardReplacesTheShippedSeedButNeverAPersonsEdit_19() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture(), c = try CloudBrainMemoryFixture()
        try await a.seed() // a real person's card: "# Card\nKeep all history.\n"
        try await b.store.start() // a fresh Mac: the shipped starter card
        let seed = try text(b.root.appendingPathComponent("hoot/card.md"))
        try await b.activate("I01")
        let saved = try await a.snapshot("I01").operations
        _ = try await b.apply(saved, row: "I01")
        #expect(try text(b.root.appendingPathComponent("hoot/card.md")) == "# Card\nKeep all history.\n")
        // The one rule: the replaced seed is a kept version (30 days, in the keeper), not a file in the memory folder.
        #expect(try await b.store.oneRuleFixtureKeptTexts().contains(seed))
        // A card the person changed is never treated as a seed: the two cards are decided by revision order (both
        // first copies carry the fixture's one cut time, so opId picks), and the other one is kept as a version,
        // never as a second live file or a conflict copy.
        try await c.store.start(); try c.write("hoot/card.md", "My own card.\n")
        try await c.activate("I01")
        let receipt = try await c.apply(saved, row: "I01")
        let live = try text(c.root.appendingPathComponent("hoot/card.md"))
        #expect(["My own card.\n", "# Card\nKeep all history.\n"].contains(live))
        #expect(!receipt.results.contains { $0.status == .keptBoth })
        #expect(files(under: c.root.appendingPathComponent("archive/cloud-conflicts")).isEmpty)
        #expect(try await c.store.oneRuleFixtureKeptTexts().contains(live == "My own card.\n" ? "# Card\nKeep all history.\n" : "My own card.\n"))
        await a.close(); await b.close(); await c.close()
    }

    @Test func anInterruptedConflictingNoteImportRetriesOnceWithNoSibling_16() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed()
        try b.write("hoot/notes/a.md", Self.noteA + "B's own different decision.\n")
        _ = try await b.store.reindex()
        try await b.activate("I01")
        let note = try #require(ops(try await a.snapshot("I01").operations, key: "file/hoot/notes/a.md").first)
        // The same operation id with different bytes fails AFTER the sibling note was written and indexed.
        let p = try part(note)
        var altered = try #require(Data(base64Encoded: p.data)); altered[altered.count - 1] ^= 1
        let twinPart = CloudBrainMemoryPart(storeId: p.storeId, inventoryRow: p.inventoryRow, key: p.key, version: p.version, resourceHash: p.resourceHash,
                                            bytes: p.bytes, index: p.index, count: p.count, parents: p.parents, data: altered.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(twinPart))
        let twin = CloudOperation(v: 1, opId: note.opId, originDevice: note.originDevice, domain: note.domain, entityId: note.entityId, revision: note.revision,
                                  parents: note.parents, kind: note.kind, projectId: note.projectId, rootId: note.rootId, source: note.source,
                                  createdAt: note.createdAt, payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
        let interrupted = CloudPreparedImport(preparationId: UUID().uuidString.lowercased(), operations: [note, twin], files: [])
        await #expect(throws: CloudFailure.idReused) {
            _ = try await b.store.cloudApply(interrupted, row: "I01", origin: .init(deviceId: a.deviceId, sequence: .init(1)))
        }
        let receipt = try await b.apply([note], row: "I01")
        // The one rule: no second live copy. Both first copies carry the same cut time, so revision order (opId) picks
        // one; whichever it is, the other text is kept as a version.
        #expect(receipt.results.first?.status == .applied)
        let siblings = files(under: b.root.appendingPathComponent("hoot/notes")).filter { $0.lastPathComponent.contains("-cloud-") }
        #expect(siblings.isEmpty)
        let live = try text(b.root.appendingPathComponent("hoot/notes/a.md")), kept = try await b.store.oneRuleFixtureKeptTexts()
        let other = live.hasSuffix("B's own different decision.\n") ? "A retained decision.\n" : "B's own different decision.\n"
        #expect(kept.contains { $0.hasSuffix(other) })
        await a.close(); await b.close()
    }

    @Test func laterEditsAreTheNewestTextInUseWithNoSiblingAtAll_17() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed()
        try b.write("hoot/notes/a.md", Self.noteA + "B's own different decision.\n")
        _ = try await b.store.reindex()
        try await b.activate("I01")
        _ = try await b.apply(ops(try await a.snapshot("I01").operations, key: "file/hoot/notes/a.md"), row: "I01")
        for edit in ["First remote edit.\n", "Second remote edit.\n"] {
            try a.write("hoot/notes/a.md", Self.noteA + edit)
            let changed = ops(try await a.snapshot("I01").operations, key: "file/hoot/notes/a.md")
            #expect(try changed.allSatisfy { !(try part($0).parents.isEmpty) })
            _ = try await b.apply(changed, row: "I01")
        }
        // The one rule: never a second live copy; every arrived text is kept as a version while B's own unsent edit
        // stays in use (it is decided by revision order once it is a revision).
        let siblings = files(under: b.root.appendingPathComponent("hoot/notes")).filter { $0.lastPathComponent.contains("-cloud-") }
        #expect(siblings.isEmpty)
        // A's edits descend from A's first copy and are newer by revision order than B's first copy: the newest is in
        // use, B's text and the first remote edit are kept as versions.
        let live = try text(b.root.appendingPathComponent("hoot/notes/a.md")), kept = try await b.store.oneRuleFixtureKeptTexts()
        #expect(live.hasSuffix("Second remote edit.\n"))
        #expect(kept.contains { $0.hasSuffix("B's own different decision.\n") })
        await a.close(); await b.close()
    }

    /// Proof 2 (13 Nov) S5: B's edit of a topic it had from A arrived on A as a second live topic
    /// ("project-cloud-<hash>.md" beside "project.md"). A topic is one live file; the other text is kept, not live.
    private static let topicHead = "---\nid: t\ndate: 1970-01-01T00:16:40Z\nseat: hoot\n---\n# Topic\n"
    @Test func aTopicEditedOnTheOtherMacReplacesItAndStaysOneTopic_proof2() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed()
        try await b.store.start()
        try await b.activate("I01")
        _ = try await b.apply(try await a.snapshot("I01").operations, row: "I01")
        let topic = "hoot/topics/t.md"
        try b.write(topic, Self.topicHead + "B's later work.\n")
        _ = try await b.store.reindex()
        let fromB = ops(try await b.snapshot("I01").operations, key: "file/" + topic)
        #expect(!fromB.isEmpty)
        _ = try await a.apply(fromB, row: "I01")
        #expect(files(under: a.root.appendingPathComponent("hoot/topics")).map(\.lastPathComponent) == ["t.md"])
        #expect(try text(a.root.appendingPathComponent(topic)).hasSuffix("B's later work.\n"))
        await a.close(); await b.close()
    }
    @Test func aTopicChangedOnBothMacsKeepsOneLiveTopicAndTheOtherTextAsAVersion_proof2() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed()
        try await b.store.start()
        try await b.activate("I01")
        _ = try await b.apply(try await a.snapshot("I01").operations, row: "I01")
        let topic = "hoot/topics/t.md"
        try b.write(topic, Self.topicHead + "B's change.\n")
        _ = try await b.store.reindex()
        let fromB = ops(try await b.snapshot("I01").operations, key: "file/" + topic)
        // A changed the same topic meanwhile (not in Cloud yet): a real conflict.
        try a.write(topic, Self.topicHead + "A's change.\n")
        let receipt = try await a.apply(fromB, row: "I01")
        #expect(!receipt.results.isEmpty)
        // One live topic, never a "-cloud-" second copy in the topics folder.
        #expect(files(under: a.root.appendingPathComponent("hoot/topics")).map(\.lastPathComponent) == ["t.md"])
        // Both texts are still on this Mac: the live one, and the other as a kept version (the one keeper).
        let live = try text(a.root.appendingPathComponent(topic))
        #expect(live.hasSuffix("A's change.\n") || live.hasSuffix("B's change.\n"))
        let kept = try await a.store.oneRuleFixtureKeptTexts()
        let other = live.hasSuffix("A's change.\n") ? "B's change.\n" : "A's change.\n"
        #expect(kept.contains { $0.hasSuffix(other) })
        #expect(DeckMemoryStore.cloudIsTopicFile(topic))
        #expect(!DeckMemoryStore.cloudIsTopicFile("archive/cloud-conflicts/x/y/hoot/topics/t.md"))
        #expect(!DeckMemoryStore.cloudIsTopicFile("hoot/notes/a.md"))
        await a.close(); await b.close()
    }

    @Test func machineLocalSettingsStayLocalAndNeverBlockReadiness_18() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.store.cloudImportFixtureSet("2026-11-12T08:00:00Z", key: "backup.last")
        try await b.store.cloudImportFixtureSet("2026-11-11T08:00:00Z", key: "backup.last")
        try await b.activate("I05")
        _ = try await b.apply(try await a.snapshot("I05").operations, row: "I05")
        #expect(try await b.store.value("backup.last", owner: nil) == "2026-11-11T08:00:00Z")
        #expect(try await b.store.cloudImportFixtureUnresolved() == 0)
        await a.close(); await b.close()
    }

    @Test func aSharedSettingChangedOnBothMacsConvergesWithHistoryKept_18() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.store.cloudImportFixtureSet("from A", key: "helper.pause-seconds")
        try await b.store.cloudImportFixtureSet("from B", key: "helper.pause-seconds")
        try await b.activate("I05")
        _ = try await b.apply(try await a.snapshot("I05").operations, row: "I05")
        _ = try await a.apply(try await b.snapshot("I05").operations, row: "I05")
        let onA = try await a.store.value("helper.pause-seconds", owner: nil), onB = try await b.store.value("helper.pause-seconds", owner: nil)
        #expect(onA == onB)
        #expect(["from A", "from B"].contains(onA ?? ""))
        #expect(try await a.store.cloudImportFixtureUnresolved() == 0)
        #expect(try await b.store.cloudImportFixtureUnresolved() == 0)
        // The losing value is kept as history, not discarded.
        let keptOnB = try await b.store.cloudImportFixtureHistory(key: "helper.pause-seconds")
        #expect(keptOnB >= 1 || onB == "from A")
        await a.close(); await b.close()
    }

    @Test func aRemovedSharedSettingIsRemovedOnTheOtherMac_22() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.store.cloudImportFixtureSet("keep", key: "tidy.hour")
        try await b.activate("I05")
        _ = try await b.apply(try await a.snapshot("I05").operations, row: "I05")
        #expect(try await b.store.value("tidy.hour", owner: nil) == "keep")
        try await a.store.cloudImportFixtureSet(nil, key: "tidy.hour")
        let adapter = try a.adapter("I05")
        var cursor: String?, changes: [CloudOperation] = []
        while let change = try await adapter.localChange(after: cursor) { changes.append(change.operation); cursor = change.cursor }
        #expect(!changes.isEmpty)
        _ = try await b.apply(changes, row: "I05")
        #expect(try await b.store.value("tidy.hour", owner: nil) == nil)
        await a.close(); await b.close()
    }

    @Test func anIncomingRetainedDatabaseBackupWritesNothingAndDoesNotBlock_21() async throws {
        let b = try CloudBrainMemoryFixture()
        try await b.activate("I06")
        let store = UUID().uuidString.lowercased(), version = UUID().uuidString.lowercased()
        let body = Data("{\"table\":\"meta\"}".utf8), hash = DeckMemoryFiles.hash(body)
        let key = "backup/archive/backups/memory-old.db/row/meta/" + hash
        let payload = CloudBrainMemoryPart(storeId: store, inventoryRow: "I06", key: key, version: version, resourceHash: hash,
                                           bytes: String(body.count), index: 0, count: 1, data: body.base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let revision = BackendCloudBrainMemoryHash.uuid(version + "\n0")
        let op = CloudOperation(v: 1, opId: revision, originDevice: UUID().uuidString.lowercased(), domain: CloudBrainMemoryFormat.domain("I06"),
                                entityId: BackendCloudBrainMemoryHash.uuid(store + "\n" + key + "\n0"), revision: revision, parents: [], kind: .put,
                                source: .init(sourceId: "memory/I06", recordId: key, offset: 0, rawHash: hash), createdAt: 1,
                                payload: value, payloadHash: DeckMemoryFiles.hash(try CloudWire.canonical(value)))
        let receipt = try await b.apply([op], row: "I06")
        #expect(receipt.results.first?.reason == DeckMemoryStore.cloudBackupExcluded)
        #expect(receipt.counts.bytes == 0)
        #expect(!FileManager.default.fileExists(atPath: b.root.appendingPathComponent("archive/cloud-db-rows").path))
        #expect(try await b.store.cloudImportFixtureStagedParts() == 0)
        await b.close()
    }
}

extension DeckMemoryStore {
    func cloudImportFixtureSet(_ value: String?, key: String) throws { try setSetting(value, key: key, owner: nil) }
    func cloudImportFixtureUnresolved() throws -> Int {
        Int(try db.first("SELECT COUNT(*) FROM cloud_memory_versions WHERE resource_key LIKE 'row/%' AND projection IS NULL")?.int(0) ?? 0)
    }
    func cloudImportFixtureHistory(key: String) throws -> Int {
        var count = 0
        for row in try db.rows("SELECT body FROM cloud_memory_versions WHERE resource_key LIKE 'row/settings/%' AND projection=''") {
            if let body = row.data(0), String(decoding: body, as: UTF8.self).contains(key) { count += 1 }
        }
        return count
    }
    /// Edits a message this store received from another device (kept here as "cloud:<origin store>:<id>").
    func cloudImportFixtureEditImportedDiary(_ external: String, text: String) throws {
        try db.run("UPDATE diary SET text=? WHERE external_id LIKE ?", [.text(text),.text("cloud:%:" + external)])
        guard db.changes == 1 else { throw CloudFailure.invalidRequest }
    }
    func cloudImportFixtureStagedParts() throws -> Int { Int(try db.first("SELECT COUNT(*) FROM cloud_memory_parts")?.int(0) ?? 0) }
}
