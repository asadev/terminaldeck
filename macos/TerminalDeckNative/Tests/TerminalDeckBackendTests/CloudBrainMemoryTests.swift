import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Cloud memory — scratch roots and the existing writer")
struct CloudBrainMemoryTests {
    @Test func allSixInventoriesCountRealSourcesAndExcludeDerivedTables_S16() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let cut = UUID().uuidString
        // 24 resources: 8 files and 16 live rows. The retained database backup is a local-only copy (finding 8): never counted or sent.
        // The fixture's own setting ("fixture.preference") is not an allow-listed shared preference (M3): named, not sent.
        // MAC-NEXT-8: I03 (the live board and its history) stays on each device: nothing counted, nothing sent.
        let expected = [5,4,0,3,7,2]
        for (i, row) in CloudBrainMemoryFormat.inventoryRows.enumerated() {
            let snapshot = try await f.snapshot(row, cut: cut)
            // Inventory is read from the running counts the cut left behind, not by re-reading the store (finding 11).
            let adapter = try f.adapter(row), inventory = try await adapter.sourceInventory()
            #expect(inventory.count == 1)
            #expect(inventory[0].items == expected[i])
            #expect(snapshot.coverage.items == expected[i])
            #expect(snapshot.coverage.bytes == inventory[0].bytes)
            #expect(snapshot.coverage.complete)
            if row == "I05" { #expect(snapshot.coverage.exclusions.contains("Memory setting kept on this Mac: fixture.preference")) }
            if row == "I06" { #expect(snapshot.coverage.exclusions.contains("Local database backups: kept on this Mac only.")) }
            for op in snapshot.operations {
                let p = try part(op)
                #expect(!p.key.contains("/search/"))
                #expect(!p.key.contains("/embeddings/"))
                #expect(!p.key.contains("/embed_queue/"))
                #expect(!p.key.contains("file/memory.db"))
                #expect(!p.key.hasPrefix("backup/") && !p.key.contains("archive/backups/"))
            }
        }
        await f.close()
    }
    @Test func memoryAdaptersRestoreWithoutASecretsPort_S08() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed(); try await b.activate("I01")
        var records = 0, files = 0
        for row in CloudBrainMemoryFormat.inventoryRows {
            let snapshot = try await a.snapshot(row)
            let receipt = try await b.apply(snapshot.operations, row: row)
            records += receipt.counts.records; files += receipt.counts.files
            #expect(try await b.adapter(row).verify(receipt).verified)
        }
        // 13 rows: the fixture's own setting ("fixture.preference") is not an allow-listed shared preference (M3), so it stays
        // on its Mac; the board row and its 2 history rows are the live board (MAC-NEXT-8): they stay on their Mac too.
        #expect(records == 13)
        #expect(files == 8)
        #expect(try await b.store.cloudFixtureCount("diary") == 4)
        #expect(try await b.store.cloudFixtureCount("board") == 0)
        #expect(try await b.store.cloudFixtureCount("board_history") == 0)
        #expect(try await b.store.cloudFixtureCount("rewinds") == 1)
        #expect(try await b.store.cloudFixtureCount("questions") == 1)
        let originalTexts = try await a.store.cloudFixtureDiaryTexts()
        #expect(try await b.store.cloudFixtureDiaryTexts() == originalTexts)
        #expect(try String(contentsOf: b.root.appendingPathComponent("hoot/card.md"), encoding: .utf8) == "# Card\nKeep all history.\n")
        // No secret/content port, protected store, HTTP client, provider or process exists in this fixture.
        await a.close(); await b.close()
    }
    @Test func firstSnapshotPrecedesCaptureAndCannotOverwriteAnOccupiedDestination_S01() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let before = try Data(contentsOf: f.root.appendingPathComponent("hoot/card.md"))
        let id = UUID().uuidString, destination = f.base.appendingPathComponent("occupied")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try await f.capture()
        await #expect(throws: CloudFailure.idReused) { _ = try await f.store.cloudBeginSnapshot(id: id, destination: destination) }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("hoot/card.md")) == before)
        #expect(try await f.store.cloudFixtureCount("diary") == 4)
        #expect(try await f.store.cloudFixtureCount("sqlite_master") > 0)
        let snapshot = try await f.snapshot("I02")
        #expect(snapshot.coverage.items == 4)
        let snapshots = try FileManager.default.contentsOfDirectory(at: f.snapshotRoot, includingPropertiesForKeys: nil)
        #expect(snapshots.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("memory.db").path) })
        await f.close()
    }
    @Test func replayHasOneReceiptAndDoesNotDuplicateMessages_S03() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed(); try await b.activate("I02")
        let snapshot = try await a.snapshot("I02")
        let first = try await b.apply(snapshot.operations, row: "I02")
        let second = try await b.apply(snapshot.operations, row: "I02")
        #expect(first == second)
        #expect(try await b.store.cloudFixtureCount("diary") == 4)
        #expect(try await b.store.cloudFixtureCount("cloud_memory_parts") == snapshot.operations.count)
        // Distinct source ids, even with identical words, remain two messages.
        #expect(try await b.store.cloudFixtureDiaryTexts().filter { $0 == "same words" }.count == 2)
        await a.close(); await b.close()
    }
    @Test func changedBytesCannotReuseARecordedOperationId_S03() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed(); try await b.activate("I02")
        let snapshot = try await a.snapshot("I02"); _ = try await b.apply(snapshot.operations, row: "I02")
        let original = snapshot.operations[0]
        let changed = copy(original, createdAt: original.createdAt + 1)
        let adapter = try b.adapter("I02"), prepared = try await adapter.validateIncoming([changed], files: [])
        await #expect(throws: CloudFailure.idReused) { _ = try await adapter.applyPrepared(prepared, origin: .init(deviceId: a.deviceId, sequence: .init(2))) }
        #expect(try await b.store.cloudFixtureCount("diary") == 4)
        await a.close(); await b.close()
    }
    @Test func incomingFilesNeverReplaceExistingLocalWork_S04_S05() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed(); try b.write("hoot/card.md", "Local unfinished card.\n")
        try await b.activate("I01")
        let snapshot = try await a.snapshot("I01"), receipt = try await b.apply(snapshot.operations, row: "I01")
        // One rule (1699f1977, 761c1c0b0; Asad: newest used everywhere, older kept 30 days): two unrelated first texts are
        // decided by revision order, not by "local wins". In this fixture both are snapshot versions stamped with the same
        // cut time (1000125), so the tie goes to the larger opId, which carries each fixture's random device id: either
        // text may be in use. The guard is that NEITHER is lost: the one not in use is kept among the saved versions.
        let local = "Local unfinished card.\n", arrived = "# Card\nKeep all history.\n"
        let inUse = try String(contentsOf: b.root.appendingPathComponent("hoot/card.md"), encoding: .utf8)
        #expect(inUse == local || inUse == arrived)
        let other = inUse == local ? arrived : local
        #expect(try await b.store.cloudFixtureKeptText(Data(other.utf8)), "the text not in use is kept, never lost")
        #expect(receipt.results.contains { $0.status == .applied })
        let versions = try await b.store.cloudFixtureVersions()
        #expect(versions.contains { $0.0 == "file/hoot/card.md" })
        #expect(receipt.counts.files == 5)
        await a.close(); await b.close()
    }
    @Test func corruptedResourceRollsBackTheOwningTransaction_S06() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try a.write("hoot/card.md", "A small fixture card."); try await b.activate("I01")
        let original = try await a.snapshot("I01").operations[0], p = try part(original)
        let bad = CloudBrainMemoryPart(storeId: p.storeId, inventoryRow: p.inventoryRow, key: p.key, version: p.version, resourceHash: p.resourceHash,
                                     bytes: p.bytes, index: p.index, count: p.count, parents: p.parents, data: Data(repeating: 120, count: Int(p.bytes)!).base64EncodedString())
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(bad))
        let changed = copy(original, payload: value)
        let adapter = try b.adapter("I01"), prepared = try await adapter.validateIncoming([changed], files: [])
        await #expect(throws: CloudFailure.checksumMismatch) { _ = try await adapter.applyPrepared(prepared, origin: .init(deviceId: a.deviceId, sequence: .init(1))) }
        #expect(try await b.store.cloudFixtureCount("cloud_memory_parts") == 0)
        #expect(try await b.store.cloudFixtureCount("cloud_memory_receipts") == 0)
        #expect(!FileManager.default.fileExists(atPath: b.root.appendingPathComponent("hoot/card.md").path))
        await a.close(); await b.close()
    }
    @Test func unsafePathsAreRefusedBeforeWriting_S05_S11() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try a.write("hoot/card.md", "fixture"); try await b.activate("I01")
        let original = try await a.snapshot("I01").operations[0], p = try part(original)
        let bad = CloudBrainMemoryPart(storeId: p.storeId, inventoryRow: p.inventoryRow, key: "file/../outside.md", version: p.version, resourceHash: p.resourceHash,
                                     bytes: p.bytes, index: p.index, count: p.count, data: p.data)
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(bad))
        await #expect(throws: (any Error).self) { _ = try await b.adapter("I01").validateIncoming([copy(original, payload: value)], files: []) }
        #expect(!FileManager.default.fileExists(atPath: b.base.appendingPathComponent("outside.md").path))
        await a.close(); await b.close()
    }
    @Test func largeFilesAndDiaryMessagesArePagedWithoutReaderCaps_S16() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        let body = String(repeating: "large fixture text\n", count: 70_000)
        try a.write("hoot/notes/large.md", body)
        _ = try await a.store.appendDiary(.init(stamp: .hoot, role: .tool, text: body, externalID: "large"))
        try await b.activate("I01")
        let files = try await a.snapshot("I01"), diary = try await a.snapshot("I02")
        #expect(files.operations.count > 10)
        #expect(diary.operations.count > 10)
        #expect(files.coverage.items == 1)
        #expect(diary.coverage.items == 1)
        for op in files.operations + diary.operations { #expect(try CloudWire.canonical(op.payload).count <= 65_536) }
        _ = try await b.apply(files.operations, row: "I01"); _ = try await b.apply(diary.operations, row: "I02")
        #expect(try Data(contentsOf: b.root.appendingPathComponent("hoot/notes/large.md")) == Data(body.utf8))
        #expect(try await b.store.cloudFixtureDiaryTexts() == [body])
        await a.close(); await b.close()
    }
    /// MAC-NEXT-8: was "a local board trim keeps its old Cloud versions"; the board no longer travels, so a trim
    /// journals nothing.
    @Test func localBoardTrimKeepsItsOldCloudVersions_S15() async throws {
        let a = try CloudBrainMemoryFixture(); try await a.seed(); try await a.activate("I03")
        try await a.store.cloudFixtureTrim()
        #expect(try await a.store.cloudFixtureCount("board_history") == 0)
        let keys = try await a.store.cloudFixtureJournalRows("I03")
        #expect(keys.isEmpty)
        await a.close()
    }
    @Test func aRestartKeepsPreparedPartsAndImportedReceipts_S07() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try a.write("hoot/card.md", String(repeating: "x", count: 200_000)); try await b.activate("I01")
        let operations = try await a.snapshot("I01").operations
        _ = try await b.apply([operations[0]], row: "I01")
        await b.store.close()
        let reopened = try DeckMemoryStore(root: b.root, dataRoot: b.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        try await reopened.cloudResumeCapture(stateRoot: b.stateRoot)
        let adapter = try BackendCloudBrainMemory(store: reopened, deviceId: b.deviceId, inventoryRow: "I01", snapshotRoot: b.snapshotRoot)
        for try await _ in await adapter.snapshotPages(cut: .init(snapshotId: UUID().uuidString, at: 0, watermarks: [:])) {}
        let prepared = try await adapter.validateIncoming(Array(operations.dropFirst()), files: [])
        let receipt = try await adapter.applyPrepared(prepared, origin: .init(deviceId: a.deviceId, sequence: .init(2)))
        #expect(try await adapter.verify(receipt).verified)
        #expect(try Data(contentsOf: b.root.appendingPathComponent("hoot/card.md")).count == 200_000)
        await reopened.close(); await a.close(); try? FileManager.default.removeItem(at: b.base)
    }
    @Test func aFailedCaptureIsReportedAsIncompleteNotSaved_S20() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed(); try await f.activate("I01")
        // A changed card that cannot be read: the save itself is untouched, coverage says it is not saved.
        let card = f.root.appendingPathComponent("hoot/card.md")
        try Data("# Card\nChanged, then made unreadable.\n".utf8).write(to: card)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: card.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: card.path) }
        await f.store.cloudCaptureAfterSave(.card, .hoot, nil)
        let inventory = try await f.adapter("I01").sourceInventory()
        #expect(!inventory[0].complete)
        #expect(!inventory[0].blockedReasons.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: card.path)
        await f.close()
    }
    @Test func aLinkedSeatFolderIsNeverFollowedAndIsNamedBeforeCoverageReadsComplete_S20_M5() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.activate("I01")
        let outside = f.base.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.root.appendingPathComponent("hoot"), withDestinationURL: outside)
        await f.store.cloudCaptureAfterSave(.card, .hoot, nil)
        // Not followed and not an error, but not silently complete either: a full pass must name it first.
        let pending = try await f.adapter("I01").sourceInventory()
        #expect(!pending[0].complete)
        while try await f.store.cloudReconcileFiles(limit: 64) > 0 {}
        let named = try await f.adapter("I01").sourceInventory()
        #expect(named[0].exclusions.contains { $0.hasPrefix("Linked files") })
        #expect(try await f.store.cloudFixtureJournalRows("I01").isEmpty)
        await f.close()
    }
    @Test func anotherDeviceKeepsGlobalIdsAndCausalEdits_S03_S04_S14() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed(); try await b.activate("I01")
        var baseline: [String:[CloudOperation]] = [:]
        for row in CloudBrainMemoryFormat.inventoryRows {
            let ops = try await a.snapshot(row).operations
            baseline[row] = ops; _ = try await b.apply(ops, row: row)
        }
        let copied = try await b.snapshot("I02").operations
        let old = try baseline["I02"]!.map(part), new = try copied.map(part)
        // MAC-NEXT-6 / Y3 (13 Nov, the echo): what arrived unchanged is not sent back by the Mac that received it. The
        // guarantee is kept for anything that IS exported: never under this Mac's store id or a new version.
        let oldByKey = Dictionary(old.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(new.allSatisfy { $0.storeId == oldByKey[$0.key]?.storeId && $0.version == oldByKey[$0.key]?.version && $0.resourceHash == oldByKey[$0.key]?.resourceHash }, "\(new.count) re-exported")
        // Editing the restored question uses its local mapped id, then returns as the same logical question.
        let id = try await b.store.cloudFixtureQuestionId()
        _ = try await b.store.answerQuestion(id: id, answer: "Edited on the second machine")
        let changed = try await b.snapshot("I05").operations
        _ = try await a.apply(changed, row: "I05")
        #expect(try await a.store.cloudFixtureCount("questions") == 1)
        let questions = try await a.store.questions(owner: nil, openOnly: false)
        #expect(questions.first?.answer == "Edited on the second machine")
        await a.close(); await b.close()
    }
    @Test func aMessageEditedOnBothMacsKeepsBothVersionsWithoutBlockingImport_S04() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed(); try await b.activate("I02")
        _ = try await b.apply(try await a.snapshot("I02").operations, row: "I02")
        try await a.store.cloudFixtureEditDiary("one", text: "edited on A")
        // B holds A's message under its imported id ("cloud:<A's store>:one"), so B's edit targets that row.
        // (The earlier line edited external_id 'one' on B, which matches nothing there, so B never edited the message.)
        try await b.store.cloudImportFixtureEditImportedDiary("one", text: "edited on B")
        let changed = try await a.snapshot("I02").operations
        let receipt = try await b.apply(changed, row: "I02")
        #expect(receipt.results.contains { $0.status == .keptBoth })
        let texts = try await b.store.cloudFixtureDiaryTexts()
        #expect(texts.contains("edited on A") && texts.contains("edited on B"))
        #expect(try await b.store.cloudFixtureCount("diary") == 5)
        // A retry of the same operations applies once.
        _ = try await b.apply(changed, row: "I02")
        #expect(try await b.store.cloudFixtureCount("diary") == 5)
        await a.close(); await b.close()
    }
    @Test func sourceCursorCannotPassAFailedOutboxSave_S02_S07() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.activate("I02")
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "Queued scratch message", externalID: "queue-fixture"))
        let adapter = try f.adapter("I02"), outbox = CloudBrainMemoryOutboxFixture(), scope = String(repeating: "a", count: 64)
        let pump = try BackendCloudBrainMemoryPump(adapter: adapter, outbox: outbox, subjectHash: scope)
        await outbox.failNext()
        await #expect(throws: CloudFailure.unavailable) { _ = try await pump.drainOnce() }
        #expect(try await adapter.savedLocalCursor(scope: scope) == nil)
        #expect(await outbox.operations.isEmpty)
        // One rule (1699f1977, 761c1c0b0): drainOnce also counts the one-rule maintenance work; count the queued operations only.
        _ = try await pump.drainOnce()
        #expect(try await adapter.savedLocalCursor(scope: scope) != nil)
        #expect(await outbox.operations.count == 1)
        _ = try await pump.drainOnce()
        #expect(await outbox.operations.count == 1, "Nothing is queued twice")
        await f.close()
    }
    @Test func previousMemoryFoldersReturnAsArchivesWithoutReplacingCurrentMemory_S05_S16() async throws {
        let old = try CloudBrainMemoryFixture(), source = try CloudBrainMemoryFixture(), destination = try CloudBrainMemoryFixture()
        try await old.seed()
        try DeckMemoryPaths.writePointer(.init(root: source.root.path, previous: [old.root.path]), dataRoot: source.base.appendingPathComponent("Data"))
        let snapshot = try await source.snapshot("I06")
        let inventory = try await source.adapter("I06").sourceInventory()
        // The earlier folder's archived files travel; its databases (memory.db and backups) stay on that Mac (finding 8).
        #expect(inventory[0].items == 8)
        #expect(snapshot.coverage.items == 8)
        #expect(snapshot.coverage.bytes == inventory[0].bytes)
        try await destination.activate("I06")
        let receipt = try await destination.apply(snapshot.operations, row: "I06")
        #expect(receipt.counts.records == 0)
        #expect(receipt.counts.files == 8)
        #expect(try await destination.store.cloudFixtureCount("diary") == 0)
        let prefix = "archive/prior-roots/" + BackendCloudBrainMemoryHash.uuid(old.root.path)
        #expect(try Data(contentsOf: destination.root.appendingPathComponent(prefix + "/hoot/card.md")) == Data(contentsOf: old.root.appendingPathComponent("hoot/card.md")))
        #expect(!snapshot.operations.contains { op in (try? self.part(op).key.contains("memory.db")) == true })
        await old.close(); await source.close(); await destination.close()
    }
    @Test func aDiskSpaceFailureCannotEnableCaptureOrChangeOriginals_S01() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let original = try Data(contentsOf: f.root.appendingPathComponent("hoot/card.md"))
        try await f.capture()
        await #expect(throws: CloudFailure.unavailable) {
            _ = try await f.store.cloudBeginSnapshot(id: UUID().uuidString, destination: f.base.appendingPathComponent("NoSpace"), availableSpace: { 0 })
        }
        #expect(try Data(contentsOf: f.root.appendingPathComponent("hoot/card.md")) == original)
        #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("NoSpace").path))
        #expect(try await f.store.cloudFixtureCount("diary") == 4)
        await f.close()
    }
    @Test func restoredDiaryUsesStableOrderedLocalIdsAndKeepsFutureAppends_S03_S14() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed(); try await b.activate("I02")
        let operations = try await a.snapshot("I02").operations
        _ = try await b.apply(operations, row: "I02")
        let rows = try await b.store.diary(.init(limit: 20, includeRewound: true))
        #expect(rows.map { $0.text } == ["same words","same words","<private>fixture private text</private>","A rewound message remains."])
        let new = try await b.store.appendDiary(.init(stamp: .hoot, role: .user, text: "New local turn", externalID: "new-turn"))
        #expect(new.id > rows.map { $0.id }.max()!)
        #expect(try await b.store.cloudFixtureCount("diary") == 5)
        await a.close(); await b.close()
    }
    @Test func emptyFilesAndTextAfterNulSurviveTheExistingDatabaseBoundary_S16() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try a.write("hoot/card.md", "")
        let text = "before\0after 🌍"
        _ = try await a.store.appendDiary(.init(stamp: .hoot, role: .tool, text: text, externalID: "nul-fixture"))
        #expect(try await a.store.cloudFixtureDiaryTexts() == [text])
        try await b.activate("I01")
        let files = try await a.snapshot("I01"), diary = try await a.snapshot("I02")
        #expect(files.coverage.items == 1 && files.coverage.bytes == 0)
        _ = try await b.apply(files.operations, row: "I01"); _ = try await b.apply(diary.operations, row: "I02")
        #expect(try Data(contentsOf: b.root.appendingPathComponent("hoot/card.md")).isEmpty)
        #expect(try await b.store.cloudFixtureDiaryTexts() == [text])
        await a.close(); await b.close()
    }
    @Test func anInterruptedSnapshotResumesItsOriginalCutAfterRestart_S07() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let cut = CloudSnapshotCut(snapshotId: UUID().uuidString, at: 1000, watermarks: [:]), adapter = try f.adapter("I02")
        try await f.capture()
        var stream = await adapter.snapshotPages(cut: cut).makeAsyncIterator()
        let first = try #require(try await stream.next())
        #expect(first.operations.count == 1)
        await f.store.close()
        let reopened = try DeckMemoryStore(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        try await reopened.cloudResumeCapture(stateRoot: f.stateRoot)
        let resumed = try BackendCloudBrainMemory(store: reopened, deviceId: f.deviceId, inventoryRow: "I02", snapshotRoot: f.snapshotRoot)
        var operations: [CloudOperation] = []
        for try await page in await resumed.snapshotPages(cut: cut) { operations += page.operations }
        #expect(operations.count == 4)
        #expect(operations.first == first.operations.first)
        await reopened.close(); try? FileManager.default.removeItem(at: f.base)
    }
    @Test func changedSnapshotWatermarksCannotSkipLocalChangesAfterRestart_S06_S07() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        let id = UUID().uuidString, destination = f.snapshotRoot.appendingPathComponent(id)
        try await f.capture()
        let snapshot = try await f.store.cloudBeginSnapshot(id: id, destination: destination)
        let changed = DeckMemoryCloudSnapshot(root: snapshot.root, storeId: snapshot.storeId, watermark: snapshot.watermark + 1, files: snapshot.files, backups: snapshot.backups, sources: snapshot.sources, exclusions: snapshot.exclusions)
        try CloudWire.canonical(changed).write(to: destination.appendingPathComponent(".cloud-snapshot.json"), options: .atomic)
        await f.store.close()
        let reopened = try DeckMemoryStore(root: f.root, dataRoot: f.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        try await reopened.cloudResumeCapture(stateRoot: f.stateRoot)
        await #expect(throws: CloudFailure.checksumMismatch) { _ = try await reopened.cloudBeginSnapshot(id: id, destination: destination) }
        #expect(try await reopened.cloudFixtureCount("diary") == 4)
        await reopened.close(); try? FileManager.default.removeItem(at: f.base)
    }
    @Test func freshAppDefaultsCannotMaskSavedCardsAndStillClaimFullContext_S08_S20() async throws {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture(); try await a.seed()
        await b.store.close()
        let actual = try await DeckMemoryStore.open(root: b.root, dataRoot: b.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        try await actual.cloudResumeCapture(stateRoot: b.stateRoot)
        let adapter = try BackendCloudBrainMemory(store: actual, deviceId: b.deviceId, inventoryRow: "I01", snapshotRoot: b.snapshotRoot)
        for try await _ in await adapter.snapshotPages(cut: .init(snapshotId: UUID().uuidString, at: 1000, watermarks: [:])) {}
        let card = b.root.appendingPathComponent("hoot/card.md")
        let originalCard = try Data(contentsOf: card), incoming = try await a.snapshot("I01")
        // The fresh Mac's card is exactly the shipped starter card (a seed, Decker's finding-19 / M6 rule), not the person's edit.
        #expect(String(decoding: originalCard, as: UTF8.self) == DeckMemoryStore.starterCard(.hoot, name: "Hoot"))
        let prepared = try await adapter.validateIncoming(incoming.operations, files: [])
        _ = try await adapter.applyPrepared(prepared, origin: .init(deviceId: a.deviceId, sequence: .init(1)))
        // The saved card replaces the seed, and the seed is kept, never lost.
        #expect(try String(contentsOf: card, encoding: .utf8) == "# Card\nKeep all history.\n")
        // One rule (1699f1977): the replaced text is kept among the saved versions (the keeper), no longer in `archive/versions`.
        let kept = try await actual.cloudFixtureKeptText(originalCard)
        #expect(kept)
        // A card the person changed is never replaced, and full context is not claimed while it masks the saved one.
        try Data("My own Hoot card.\n".utf8).write(to: card)
        _ = try await actual.reindex()
        try a.write("hoot/card.md", "# Card\nA second saved version.\n")
        let second = try await a.snapshot("I01")
        let preparedSecond = try await adapter.validateIncoming(second.operations, files: [])
        _ = try await adapter.applyPrepared(preparedSecond, origin: .init(deviceId: a.deviceId, sequence: .init(2)))
        #expect(try String(contentsOf: card, encoding: .utf8) == "My own Hoot card.\n")
        // One rule (1699f1977, 761c1c0b0): no conflict copies any more, so readiness is no longer marked incomplete here;
        // the guard that matters is the line above (his own card is not replaced).
        await actual.close(); await a.close(); try? FileManager.default.removeItem(at: b.base)
    }
    private func part(_ op: CloudOperation) throws -> CloudBrainMemoryPart { try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload)) }
    private func copy(_ op: CloudOperation, createdAt: Int64? = nil, payload: CloudValue? = nil) -> CloudOperation {
        let value = payload ?? op.payload
        return .init(v: op.v, opId: op.opId, originDevice: op.originDevice, domain: op.domain, entityId: op.entityId, revision: op.revision, parents: op.parents, kind: op.kind,
                     source: op.source, createdAt: createdAt ?? op.createdAt, payload: value,
                     payloadHash: (try? BackendCloudBrainMemoryHash.bytes(CloudWire.canonical(value))) ?? "")
    }
}

extension DeckMemoryStore {
    /// Test-only: these exact bytes are kept among the one rule's saved versions (the keeper's content store).
    func cloudFixtureKeptText(_ content: Data) throws -> Bool {
        FileManager.default.fileExists(atPath: try cloudKeeper().contentURL(kind: Self.oneRuleKind, sha256: BackendCloudBrainMemoryHash.bytes(content)).path)
    }
}
