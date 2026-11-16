import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The one rule for memory files (lane memory-one-rule): newest by revision order in use on both Macs, the other text
/// kept 30 days, removals / moves / archives travel, the Bin, the one-time settling of what earlier builds left, the
/// 30-day sweep and the one count. Real memory stores on scratch folders, two Macs exchanging records through the
/// existing fixture. Written unbuilt; the integrator runs them.
@Suite("Cloud memory — the one rule")
struct CloudMemoryOneRuleTests {
    private static let note = "hoot/notes/a.md"
    private static let head = "---\nid: n-fixture-a\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Note\n"
    private func text(_ f: CloudBrainMemoryFixture, _ path: String) -> String? { try? String(contentsOf: f.root.appendingPathComponent(path), encoding: .utf8) }
    private func exists(_ f: CloudBrainMemoryFixture, _ path: String) -> Bool { FileManager.default.fileExists(atPath: f.root.appendingPathComponent(path).path) }
    private func twins(_ f: CloudBrainMemoryFixture) -> [String] {
        guard let walker = FileManager.default.enumerator(at: f.root, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.contains("-cloud-") }
    }
    /// Everything this Mac's journal would send for `row`, as the pump reads it.
    private func changes(_ f: CloudBrainMemoryFixture, _ row: String) async throws -> [CloudOperation] {
        let adapter = try f.adapter(row)
        var cursor: String?, out: [CloudOperation] = []
        // The pump hands the outbox every journal row; two rows of one record with the same value (the index writes a
        // note's row, then `archiveNow` writes the same `origin_path` again) export the SAME operation twice, which the
        // outbox keeps once (INSERT OR IGNORE). An incoming pack never holds one operation twice, so the same here.
        var seen = Set<String>()
        while let change = try await adapter.localChange(after: cursor) {
            if seen.insert(change.operation.opId).inserted { out.append(change.operation) }
            cursor = change.cursor
        }
        return out
    }
    private func edit(_ f: CloudBrainMemoryFixture, _ path: String, _ text: String) async throws {
        try f.write(path, text)
        try await f.store.cloudCaptureChangedFiles(paths: [path])
    }
    /// Two Macs holding the seeded memory, B joined from A's first copy (rows I01, I05, I06).
    /// `sending`: phase 2 (every Mac understands removal records) unless a test says otherwise.
    private func pair(sending: Bool = true) async throws -> (CloudBrainMemoryFixture, CloudBrainMemoryFixture) {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed()
        try await b.store.start()
        for row in ["I01", "I05", "I06"] {
            try await b.activate(row)
            _ = try await b.apply(try await a.snapshot(row).operations, row: row)
        }
        await a.store.cloudSetDevice(a.deviceId); await b.store.cloudSetDevice(b.deviceId)
        await a.store.cloudSetOneRuleSending(sending); await b.store.cloudSetOneRuleSending(sending)
        // As on his Macs after their reconciles: every file has its "last seen" row (a removal is noticed by it).
        try await a.store.oneRuleFixtureCaptureAll(); try await b.store.oneRuleFixtureCaptureAll()
        return (a, b)
    }
    private func hits(_ f: CloudBrainMemoryFixture, _ words: String) async throws -> Int {
        try await f.store.search(.init(words, mode: .words)).hits.count
    }

    // 1. Two different texts: the newer revision is in use on BOTH, the older is kept, no twin file.
    @Test func twoDifferentTextsTheNewerIsInUseOnBothAndTheOlderIsKept() async throws {
        let (a, b) = try await pair()
        try await edit(a, Self.note, Self.head + "A's edit.\n")
        let fromA = try await changes(a, "I01")
        try await Task.sleep(nanoseconds: 20_000_000)
        try await edit(b, Self.note, Self.head + "B's later edit.\n")
        let fromB = try await changes(b, "I01")
        _ = try await b.apply(fromA, row: "I01")
        _ = try await a.apply(fromB, row: "I01")
        #expect(text(a, Self.note) == Self.head + "B's later edit.\n")
        #expect(text(b, Self.note) == Self.head + "B's later edit.\n")
        #expect(twins(a).isEmpty && twins(b).isEmpty)
        #expect(try await a.store.oneRuleFixtureKeptTexts().contains(Self.head + "A's edit.\n"))
        #expect(try await b.store.oneRuleFixtureKeptTexts().contains(Self.head + "A's edit.\n"))
        await a.close(); await b.close()
    }

    // 1b. An edit this Mac has not made into a revision yet stays in use and the arrival waits, kept; once the edit is
    // a revision, both Macs decide by revision order and end the same.
    @Test func anEditNotSentYetStaysUntilItIsARevisionThenBothMacsAgree() async throws {
        let (a, b) = try await pair()
        try await edit(a, Self.note, Self.head + "A's edit.\n")
        let fromA = try await changes(a, "I01")
        try b.write(Self.note, Self.head + "B's unsent edit.\n")   // not captured yet
        _ = try await b.apply(fromA, row: "I01")
        #expect(text(b, Self.note) == Self.head + "B's unsent edit.\n")
        #expect(twins(b).isEmpty)
        #expect(try await b.store.oneRuleFixtureKeptTexts().contains(Self.head + "A's edit.\n"))
        try await b.store.cloudCaptureChangedFiles(paths: [Self.note])
        let fromB = try await changes(b, "I01")
        _ = try await b.store.cloudOneRuleStep()          // the kept arrival is decided now
        _ = try await a.apply(fromB, row: "I01")
        #expect(text(a, Self.note) == text(b, Self.note))
        await a.close(); await b.close()
    }

    // 3 + 4. Remove: gone from search and reading on both, in the Bin on both; Put back restores it everywhere.
    @Test func removeLeavesBothMacsAndPutBackRestoresItEverywhere() async throws {
        let (a, b) = try await pair()
        #expect(try await hits(b, "retained decision") > 0)
        let binned = try await a.store.memoryRemove(path: Self.note)
        #expect(binned.name == "Note")
        _ = try await b.apply(try await changes(a, "I01"), row: "I01")
        #expect(!exists(a, Self.note) && !exists(b, Self.note))
        #expect(try await hits(a, "retained decision") == 0)
        #expect(try await hits(b, "retained decision") == 0)
        #expect(try await a.store.memoryBin().map(\.path) == [Self.note])
        #expect(try await b.store.memoryBin().map(\.path) == [Self.note])
        try await b.store.memoryPutBack(path: Self.note)
        _ = try await a.apply(try await changes(b, "I01"), row: "I01")
        #expect(text(a, Self.note)?.hasSuffix("A retained decision.\n") == true)
        #expect(text(b, Self.note)?.hasSuffix("A retained decision.\n") == true)
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(try await b.store.memoryBin().isEmpty)
        #expect(try await hits(a, "retained decision") > 0)
        await a.close(); await b.close()
    }

    // 4. Removed on A while B (offline) edits it: the EDIT wins on both Macs, even though the removal is later (phase 2
    // review, blocker 3: a removal wins only over a text it was made on top of; never by time stamp).
    @Test func removedOnAWhileOfflineBEditsTheEditWinsOnBoth() async throws {
        let (a, b) = try await pair()
        try await edit(b, Self.note, Self.head + "B's offline edit.\n")
        let fromB = try await changes(b, "I01")
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try await a.store.memoryRemove(path: Self.note)       // later than B's edit
        let fromA = try await changes(a, "I01")
        _ = try await b.apply(fromA, row: "I01")
        _ = try await a.apply(fromB, row: "I01")
        #expect(text(a, Self.note) == Self.head + "B's offline edit.\n")
        #expect(text(b, Self.note) == Self.head + "B's offline edit.\n")
        #expect(try await b.store.memoryBin().isEmpty)
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(try await hits(a, "offline edit") > 0)
        await a.close(); await b.close()
    }
    @Test func editedOnBAfterARemovedItTheEditWinsOnBoth() async throws {
        let (a, b) = try await pair()
        _ = try await a.store.memoryRemove(path: Self.note)
        let fromA = try await changes(a, "I01")
        try await Task.sleep(nanoseconds: 20_000_000)
        try await edit(b, Self.note, Self.head + "B's later edit.\n")   // B was offline: it never saw the removal
        let fromB = try await changes(b, "I01")
        _ = try await b.apply(fromA, row: "I01")
        _ = try await a.apply(fromB, row: "I01")
        #expect(text(a, Self.note) == Self.head + "B's later edit.\n")
        #expect(text(b, Self.note) == Self.head + "B's later edit.\n")
        #expect(try await a.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }

    // 3. Archive, rename and move travel: the other Mac holds one item, not the old place as well.
    @Test func archivingANoteTravelsAndTheOtherMacListsOneNote() async throws {
        let (a, b) = try await pair()
        let before = try await b.store.oneRuleFixtureNotesInUse()
        _ = try await a.store.archiveNote(id: "n-fixture-a", reason: "archived", replacedBy: nil)
        try await a.store.cloudCaptureChangedFiles(paths: ["archive", "hoot"])
        for row in ["I06", "I05", "I01"] { _ = try await b.apply(try await changes(a, row), row: row) }
        _ = try await b.store.reindex()
        #expect(!exists(b, Self.note))
        #expect(exists(b, "archive/" + Self.note))
        #expect(try await b.store.oneRuleFixtureNotesInUse() == before - 1)
        #expect(try await a.store.oneRuleFixtureNotesInUse() == before - 1)
        // The move is not in the Bin (it lives on in the archive), on either Mac.
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(try await b.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }
    /// Lead's decision 1 (15 Nov): a rename made by hand (Finder) is not a move the app made. The new name travels as a
    /// new file; the old place is "Not on this Mac" here only, and the other Mac keeps it (a wrong "by hand" loses nothing).
    @Test func aRenameMadeByHandIsANewFileAndALocalMarkNeverATravellingMove() async throws {
        let (a, b) = try await pair()
        let renamed = "hoot/notes/a-renamed.md"
        try FileManager.default.moveItem(at: a.root.appendingPathComponent(Self.note), to: a.root.appendingPathComponent(renamed))
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot/notes"])
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        _ = try await b.apply(try await changes(a, "I01"), row: "I01")
        #expect(exists(b, Self.note) && exists(b, renamed))
        #expect(try await a.store.notHere().contains { $0.item.place == Self.note && $0.mark == .notOnThisMac })
        #expect(try await b.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }

    // 2. The existing twins and conflict copies: nothing deleted, every text still somewhere, twice, after a stop.
    // Round 3: a copy edited since it was recorded (or never recorded) is left exactly as it is, and counted.
    @Test func theOneTimeSettlingKeepsEveryTextRunsTwiceAndSurvivesAStop() async throws {
        let (_, b) = try await pair()
        let twin = "hoot/notes/a-cloud-0123456789abcdef.md", twin2 = "hoot/notes/a-cloud-fedcba9876543210.md"
        let edited = "hoot/notes/a-cloud-00112233445566aa.md", unrecorded = "hoot/notes/a-cloud-99887766554433bb.md"
        let conflict = "archive/cloud-conflicts/" + UUID().uuidString.lowercased() + "/" + String(repeating: "a", count: 64) + "/hoot/topics/t.md"
        try b.write(twin, Self.head + "Twin text.\n")
        try b.write(twin2, Self.head + "Second twin text.\n")
        try b.write(edited, Self.head + "Copy as it arrived.\n")
        try b.write(unrecorded, Self.head + "Copy nobody recorded.\n")
        try b.write(conflict, "---\nid: t\ndate: 1970-01-01T00:16:40Z\nseat: hoot\n---\n# Topic\nConflict copy.\n")
        for path in [twin, twin2, edited, conflict] { try await b.store.oneRuleFixtureRecordCopy(path, key: path == conflict ? "file/hoot/topics/t.md" : "file/" + Self.note) }
        try b.write(edited, Self.head + "Copy an AI edited later.\n")   // no longer the recorded version
        let beforeTexts = try await b.store.oneRuleFixtureAllTexts()
        // His copies were placed by an import (their "last seen" rows exist); these hand-made ones are captured once
        // here, as the app's reconcile would, BEFORE the count the settling must not grow.
        try await b.store.cloudCaptureChangedFiles(paths: ["hoot", "archive"])
        let journalBefore = try await b.store.oneRuleFixtureFileJournal()
        // A stop in the middle: the marker is written and the copy is already gone (the step after the keeper copy).
        try await b.store.oneRuleFixtureMark(twin2)
        try await b.store.oneRuleFixtureKeep(twin2)
        try FileManager.default.removeItem(at: b.root.appendingPathComponent(twin2))
        try await b.store.cloudCaptureChangedFiles(paths: ["hoot"])   // the capture must not read it as a removal
        for _ in 0..<12 { _ = try await b.store.cloudOneRuleStep(limit: 1) }
        try await b.store.oneRuleFixtureRestart()   // run it all again
        for _ in 0..<12 { _ = try await b.store.cloudOneRuleStep(limit: 1) }
        #expect(!exists(b, twin) && !exists(b, twin2) && !exists(b, conflict))
        #expect(text(b, edited) == Self.head + "Copy an AI edited later.\n", "an edited copy is left as it is")
        #expect(text(b, unrecorded) == Self.head + "Copy nobody recorded.\n", "a copy with no recorded version is left as it is")
        let after = try await b.store.oneRuleFixtureAllTexts()
        for t in beforeTexts { #expect(after.contains(t)) }   // byte for byte: live or kept
        // Settling sends nothing: both texts were already in the Cloud.
        #expect(try await b.store.oneRuleFixtureFileJournal() <= journalBefore)
        // Round 3: one report, numbers only.
        let report = try await b.store.memoryOneRuleReport()
        #expect(report.leftAsTheyAre == 2)
        #expect(report.copiesSettled >= 2)
        #expect(report.finished && report.safetyCopy != nil && (report.safetyCopyBytes ?? 0) > 0)
        #expect(report.line.contains("left as they are 2"))
        await b.close()
    }

    /// After a compatible Remove, an edit arriving from the other Mac puts the note back in use, and it is no
    /// longer listed in the Bin.
    @Test func aNoteBackInUseIsNeverAlsoInTheBin() async throws {
        let (a, b) = try await pair(sending: false)
        _ = try await a.store.memoryRemove(path: Self.note)
        #expect(try await a.store.memoryBin().map(\.path) == [Self.note])
        try await edit(b, Self.note, Self.head + "B's edit.\n")
        _ = try await a.apply(try await changes(b, "I01"), row: "I01")
        // Delete rule (spec D, J): Remove always queues a travelling Everywhere removal, in the old compatible form
        // while the gate is closed (phase 1's Remove sent nothing). B's edit meets that removal before it is a revision,
        // so it is kept and decided once A's removal has gone out: the edit wins (it was never made on top of the
        // removal) and the note leaves the Bin.
        _ = try await changes(a, "I01")
        _ = try await a.store.cloudOneRuleStep()
        #expect(text(a, Self.note) == Self.head + "B's edit.\n")
        #expect(try await a.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }

    // 5. The 30-day sweep and "Clean up now": kept texts and Bin items go, a text in use never does.
    @Test func theSweepAfter30DaysAndCleanUpNowNeverTouchATextInUse() async throws {
        let (a, b) = try await pair()
        let clock = OneRuleClock(1_800_000_000_000)
        await a.store.cloudSetClock { clock.now }; await b.store.cloudSetClock { clock.now }
        try await edit(a, Self.note, Self.head + "Newer text.\n")
        try await a.store.oneRuleFixtureKeepText(Self.note, Self.head + "Older text.\n")
        _ = try await a.store.memoryRemove(path: "hoot/topics/t.md")
        _ = try await a.store.cloudOneRuleStep()
        // Never deleted in the step that put it in the Bin.
        #expect(try await a.store.oneRuleFixtureKeptTexts().count >= 2)
        clock.advance(days: 31)
        _ = try await a.store.cloudOneRuleStep()
        #expect(try await a.store.oneRuleFixtureKeptTexts().isEmpty)
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(text(a, Self.note) == Self.head + "Newer text.\n")
        // Clean up now: versions kept before it go at once, here and (through the shared setting) on B; the Bin stays.
        try await b.store.oneRuleFixtureKeepText(Self.note, Self.head + "Kept on B.\n")
        _ = try await b.store.memoryRemove(path: "hoot/topics/t.md")
        try await a.store.oneRuleFixtureKeepText(Self.note, Self.head + "Kept on A.\n")
        clock.advance(days: 0, hours: 1)
        #expect(try await a.store.memoryCleanUpCount() == 1)
        _ = try await a.store.memoryCleanUpVersions()
        #expect(try await a.store.memoryVersions(path: Self.note).isEmpty)
        _ = try await b.apply(try await changes(a, "I05"), row: "I05")
        _ = try await b.store.cloudOneRuleStep()
        #expect(try await b.store.memoryVersions(path: Self.note).isEmpty)
        #expect(try await b.store.memoryBin().count == 1)
        #expect(text(a, Self.note) == Self.head + "Newer text.\n")
        await a.close(); await b.close()
    }
    /// Blocker 3: a cleanup time that is not a number, huge, negative or later than the service clock's now is ignored
    /// (no crash, nothing deleted); without the service clock nothing is applied.
    @Test func cleanupTimesThatAreHugeOrInTheFutureAreIgnored() async throws {
        let (a, b) = try await pair()
        try await a.store.oneRuleFixtureKeepText(Self.note, Self.head + "Kept.\n")
        // No service clock yet: nothing applied, and Clean up refuses.
        try await a.store.cloudImportFixtureSet("1", key: DeckMemoryStore.cleanupVersionsKey)
        _ = try await a.store.cloudOneRuleStep()
        #expect(try await a.store.memoryCleanUpCount() == 1)
        await #expect(throws: DeckMemoryError.self) { _ = try await a.store.memoryCleanUpVersions() }
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        await a.store.cloudSetClock { clock.now }
        // The clock is today's: a kept text more than 30 days older than the clock is swept by the daily sweep, rightly.
        let future = String((clock.now ?? 0) + 3_600_000)
        for bad in ["99999999999999999999999", String(Int64.max), String(Int64.max - 10), "-5", "0", "soon", future] {
            try await a.store.cloudImportFixtureSet(bad, key: DeckMemoryStore.cleanupVersionsKey)
            try await a.store.cloudImportFixtureSet(bad, key: DeckMemoryStore.cleanupBinKey)
            _ = try await a.store.cloudOneRuleStep()
            #expect(try await a.store.memoryCleanUpCount() == 1, "\(bad) is ignored")
        }
        #expect(DeckMemoryStore.cloudCleanupBefore(String(Int64.max), serviceNow: Int64.max) == nil)
        #expect(DeckMemoryStore.cloudCleanupBefore("100", serviceNow: 200) == 100 + CloudBootFilesRules.keptFor - 1)
        await a.close(); await b.close()
    }

    // 6. One count: notes in use (not archived, not in the Bin). The page's definition is lane L4's
    // (`BackendCloudNoteIdentity.itemCount`, on lane/mac-next); run on the merged code.
    @Test func theNoteCountIsNotesInUseOnly() async throws {
        let (a, b) = try await pair()
        // The page's number is lane L4's definition (`BackendCloudNoteIdentity.itemCount`: notes in use AND notes put
        // away count as items; replaced copies and Bin items do not). This lane only proves its Bin is not counted.
        let before = try #require(try await a.store.cloudPageRead(withTitles: false).here[.notes])
        #expect(try await a.store.oneRuleFixtureNotesInUse() == 1)
        _ = try await a.store.memoryRemove(path: Self.note)
        let after = try await a.store.cloudPageRead(withTitles: false).here[.notes]
        #expect(after == before - 1)
        #expect(try await a.store.oneRuleFixtureNotesInUse() == 0)
        await a.close(); await b.close()
    }

    /// Blocker 1: a note edited on B after A archived it is never hidden or deleted by A's move.
    @Test func aNoteEditedOnTheOtherMacAfterTheArchiveStaysInUse() async throws {
        let (a, b) = try await pair()
        try await edit(b, Self.note, Self.head + "B's edit after the archive.\n")
        _ = try await changes(b, "I01")
        _ = try await a.store.archiveNote(id: "n-fixture-a", reason: "archived", replacedBy: nil)
        try await a.store.cloudCaptureChangedFiles(paths: ["archive", "hoot"])
        for row in ["I06", "I05", "I01"] { _ = try await b.apply(try await changes(a, row), row: row) }
        for _ in 0..<4 { _ = try await b.store.cloudOneRuleStep() }
        _ = try await b.store.reindex()
        #expect(text(b, Self.note) == Self.head + "B's edit after the archive.\n")
        #expect(try await hits(b, "after the archive") > 0)
        #expect(try await b.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }
    /// Different bytes at a new place do not prove a move or an intended delete. The absent place is device-only.
    @Test func aDifferentTextAtANewPlaceDoesNotTurnAByHandAbsenceIntoATravellingRemoval() async throws {
        let (a, b) = try await pair()
        let renamed = "hoot/notes/a-renamed.md"
        try a.write(renamed, Self.head + "Rewritten while moving.\n")
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot/notes"])
        _ = try await b.apply(try await changes(a, "I01"), row: "I01")
        #expect(exists(b, Self.note))
        #expect(exists(b, renamed))
        #expect(try await a.store.notHere().contains { $0.item.place == Self.note && $0.mark == .notOnThisMac })
        #expect(try await b.store.memoryBin().isEmpty)
        #expect(try await a.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }
    /// Any number of files gone by hand get persistent local marks. Reconcile never replaces them.
    @Test func manyFilesGoneByHandStayGoneHereAndNeverRemoveTheOtherMacsFiles() async throws {
        let (a, b) = try await pair()
        let paths = [Self.note, "hoot/topics/t.md", "hoot/playbook.md"]
        let journal = try await a.store.cloudJournalSize()
        for path in paths { try FileManager.default.removeItem(at: a.root.appendingPathComponent(path)) }
        try await a.store.oneRuleFixtureResolveGoneByHand(paths)
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot"])
        #expect(try await a.store.cloudJournalSize() == journal)
        let marks = try await a.store.notHere()
        #expect(Set(marks.compactMap(\.item.place)) == Set(paths))
        #expect(marks.allSatisfy { $0.mark == .notOnThisMac })
        for _ in 0..<4 { _ = try await a.store.cloudReconcileFiles() }
        #expect(paths.allSatisfy { !exists(a, $0) && exists(b, $0) })
        #expect(try await a.store.cloudJournalSize() == journal)
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(try await b.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }
    /// Item 7: a restore on A reaching B before A's archive removal: the note is in use and indexed on B.
    @Test func aRestoreArrivingBeforeTheArchiveRemovalIsInUseAndIndexed() async throws {
        let (a, b) = try await pair()
        let clock = OneRuleClock(Int64(Date().timeIntervalSince1970 * 1000))
        await a.store.cloudSetClock { clock.now }; await b.store.cloudSetClock { clock.now }
        _ = try await a.store.archiveNote(id: "n-fixture-a", reason: "archived", replacedBy: nil)
        try await a.store.cloudCaptureChangedFiles(paths: ["archive", "hoot"])
        _ = try await a.store.restoreNote(id: "n-fixture-a")
        try await a.store.cloudCaptureChangedFiles(paths: ["archive", "hoot"])
        // Both moves are sent without a delay. Restore ancestry still wins over the earlier archive.
        for _ in 0..<4 { _ = try await a.store.cloudOneRuleStep() }
        for row in ["I01", "I05", "I06"] { _ = try await b.apply(try await changes(a, row), row: row) }
        #expect(exists(b, Self.note))
        #expect(!exists(b, "archive/" + Self.note))
        #expect(try await hits(b, "retained decision") > 0)
        // The archived copy's removal is a MOVE (its text lives on in the restored note): never a Bin item on either Mac.
        #expect(!(try await a.store.memoryBin().map(\.path).contains("archive/" + Self.note)))
        #expect(!(try await b.store.memoryBin().map(\.path).contains("archive/" + Self.note)))
        await a.close(); await b.close()
    }
    /// Older Macs still receive compatible Everywhere deletes while the moves/cleanup switch is off.
    @Test func phaseOneSendsCompatibleEverywhereRemovalButNoMoveOrCleanup() async throws {
        let (a, b) = try await pair(sending: false)
        let clock = OneRuleClock(1_800_000_000_000)
        // Phase 2: an "understands" setting counts only while fresh on the reader's service clock: both Macs share it.
        await a.store.cloudSetClock { clock.now }; await b.store.cloudSetClock { clock.now }
        _ = try await a.store.memoryRemove(path: Self.note)
        _ = try await a.store.archiveNote(id: "n-fixture-old", reason: "archived", replacedBy: nil)
        try await a.store.oneRuleFixtureKeepText("hoot/topics/t.md", "Kept.\n")
        _ = try await a.store.memoryCleanUpVersions()
        _ = try await a.store.cloudOneRuleStep()
        let removals = try await changes(a, "I01").filter { op in
            let part = try? JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload))
            return part.flatMap { Data(base64Encoded: $0.data) }.flatMap(DeckMemoryRemoval.parse) != nil
        }
        #expect(removals.count == 1)
        let markerBytes = try removals.compactMap { op -> Data? in
            let part = try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload))
            return Data(base64Encoded: part.data)
        }
        #expect(markerBytes.allSatisfy { !String(decoding: $0, as: UTF8.self).contains(CloudDeleteTravel.rule) })
        _ = try await b.apply(removals, row: "I01")
        #expect(!exists(b, Self.note))
        let settings = try await changes(a, "I05").compactMap { op -> String? in
            guard let part = try? JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload)), let data = Data(base64Encoded: part.data) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        #expect(!settings.contains { $0.contains("cleanup.") })
        #expect(settings.contains { $0.contains(DeckMemoryStore.understandsPrefix) })
        // Sending switches on by itself once every Mac of the account has said it understands.
        let before = await a.store.oneRuleFixtureSendsByAccount([a.deviceId, b.deviceId])
        #expect(!before)
        _ = try await b.store.cloudOneRuleStep()
        _ = try await a.apply(try await changes(b, "I05"), row: "I05")
        let after = await a.store.oneRuleFixtureSendsByAccount([a.deviceId, b.deviceId])
        #expect(after)
        await a.close(); await b.close()
    }
    // A REAL older build cannot run in this test target: the package compiles one copy of the memory store. The old
    // import path is described in the lane note; the next test proves what that path relies on.

    // 7. An older build: a removal is an ordinary part (same kind, same keys), and its text indexes as a note that is
    // never rewritten (so an older build never sends it back as an edit).
    @Test func anOlderBuildReadsARemovalAsAnOrdinaryUnchangedPart() async throws {
        let (a, b) = try await pair()
        _ = try await a.store.memoryRemove(path: Self.note)
        let ops = try await changes(a, "I01")
        #expect(!ops.isEmpty)
        for op in ops {
            #expect(op.kind == .put)
            let keys = try JSONSerialization.jsonObject(with: CloudWire.canonical(op.payload)) as? [String: Any]
            let fields = Set(keys?.keys.map { $0 } ?? [])
            #expect(fields.isSubset(of: ["format","storeId","inventoryRow","key","version","resourceHash","bytes","index","count","parents","data","stamp","baseline"]))
            _ = try await b.store.cloudValidatePart(op, row: "I01")
        }
        let marker = DeckMemoryRemoval(at: 1, by: a.deviceId, movedTo: nil).text(id: "n-20261114-abcdef", name: "Note")
        let old = try CloudBrainMemoryFixture()
        try old.write("hoot/notes/x.md", marker)
        _ = try await old.store.reindex()
        #expect(text(old, "hoot/notes/x.md") == marker)
        #expect(DeckMemoryRemoval.parse(Data(marker.utf8)) != nil)
        #expect(DeckMemoryRemoval.parse(Data((Self.head + "A note.\n").utf8)) == nil)
        await a.close(); await b.close(); await old.close()
    }

    /// Item 6: the settling makes one safety copy first (memory folder + keeper) and can put the folder back from it.
    @Test func theSettlingMakesASafetyCopyFirstAndItRestores() async throws {
        let (_, b) = try await pair()
        try b.write("hoot/notes/a-cloud-0123456789abcdef.md", Self.head + "Twin text.\n")
        _ = try await b.store.cloudOneRuleStep()
        let copy = try #require(try await b.store.oneRuleFixtureSafetyCopy())
        #expect(FileManager.default.fileExists(atPath: copy + "/memory/" + Self.note))
        #expect(FileManager.default.fileExists(atPath: copy + "/memory/memory.db"))
        try FileManager.default.removeItem(at: b.root.appendingPathComponent(Self.note))
        let written = try await b.store.memoryRestoreSafetyCopy()
        #expect(written >= 1)
        #expect(exists(b, Self.note))
        await b.close()
    }

    // "Is A newer than B" by revision order: a descendant is newer whatever the clocks say.
    @Test func newerIsDecidedByRevisionOrderNotFileDates() async throws {
        let (a, b) = try await pair()
        let first = try #require(try await a.store.memoryCurrentRef(path: Self.note))
        try await edit(a, Self.note, Self.head + "Later.\n")
        _ = try await changes(a, "I01")
        let second = try #require(try await a.store.memoryCurrentRef(path: Self.note))
        // The file's date is set back: the order does not change.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: a.root.appendingPathComponent(Self.note).path)
        #expect(try await a.store.memoryIsNewer(second, than: first) == true)
        #expect(try await a.store.memoryIsNewer(first, than: second) == false)
        await a.close(); await b.close()
    }
}

final class OneRuleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    var now: Int64? { lock.withLock { value } }
    func advance(days: Int64, hours: Int64 = 0, minutes: Int64 = 0) { lock.withLock { value += days * 24 * 3_600_000 + hours * 3_600_000 + minutes * 60_000 } }
}

extension DeckMemoryStore {
    /// Resolve a completed pair of missing looks with the conservative witness answer, without a wall-clock sleep.
    func oneRuleFixtureResolveGoneByHand(_ paths: [String]) throws {
        for path in paths {
            let hash = try db.first("SELECT hash FROM cloud_memory_files WHERE path=?", [.text(path)])?.string(0)
            let now = Date()
            try cloudResolveMemoryGone(path: path, lastHash: hash, lastSeen: now.addingTimeInterval(-60), goneAt: now, answer: .cannotKnow)
        }
    }
    /// Every text the keeper holds for memory (kept versions and the Bin).
    func oneRuleFixtureKeptTexts() throws -> [String] {
        let keeper = try cloudKeeper(), db = try keeper.database()
        let shas = try db.rows("SELECT sha256 FROM versions WHERE kind=? UNION SELECT sha256 FROM bin WHERE kind=?", [.text(Self.oneRuleKind), .text(Self.oneRuleKind)]).map { $0.text(0) }
        return shas.compactMap { keeper.content(kind: Self.oneRuleKind, sha256: $0).flatMap { String(data: $0, encoding: .utf8) } }
    }
    /// Every text in the memory folder plus every kept text.
    func oneRuleFixtureAllTexts() throws -> Set<String> {
        var out = Set(try oneRuleFixtureKeptTexts())
        for path in try cloudScanSourceFiles().paths {
            if let t = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) { out.insert(t) }
        }
        return out
    }
    func oneRuleFixtureNotesInUse() throws -> Int {
        Int(try db.first("SELECT COUNT(*) FROM main.notes WHERE missing = 0 AND archived IS NULL AND COALESCE(type,'') <> 'removed'")?.int(0) ?? 0)
    }
    /// Journal rows for memory FILES (the settling's "sends nothing"; the one "this Mac understands" setting is a row).
    func oneRuleFixtureFileJournal() throws -> Int {
        Int(try db.first("SELECT COUNT(*) FROM cloud_memory_journal WHERE file IS NOT NULL")?.int(0) ?? 0)
    }
    func oneRuleFixtureCaptureAll() throws {
        try cloudMarkFilesDirty()
        while try cloudReconcileFiles(limit: 500) > 0 {}
    }
    func oneRuleFixtureSafetyCopy() throws -> String? { try db.first("SELECT value FROM cloud_memory_control WHERE key='oneRule:safetyCopy'")?.string(0) }
    func oneRuleFixtureSendsByAccount(_ macs: [String]) -> Bool {
        let forced = cloudOneRuleSendingForced
        cloudOneRuleSendingForced = nil; defer { cloudOneRuleSendingForced = forced }
        cloudOneRuleSetAccountMacs(macs)
        // Phase 2 review, blocker 4: the safety copy is made as soon as every Mac understands (the step does this).
        try? cloudPrepareSendingCopy()
        return cloudOneRuleSends()
    }
    /// What an earlier build recorded when it kept a copy beside a file: a version of `key` placed at `path`.
    func oneRuleFixtureRecordCopy(_ path: String, key: String) throws {
        let hash = try cloudHashFile(root.appendingPathComponent(path))
        try db.run("INSERT INTO cloud_memory_versions(store_id,resource_key,revision,content_hash,inventory,body,projection,projected_hash,parents) VALUES (?,?,?,?,'I01',?,?,?,?)",
                   [.text(UUID().uuidString.lowercased()), .text(key), .text(UUID().uuidString.lowercased()), .text(hash), .blob(Data()), .text(path), .text(hash), .blob(Data("[]".utf8))])
    }
    func oneRuleFixtureMark(_ path: String) throws { try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,'1')", [.text("convert:" + path)]) }
    func oneRuleFixtureKeep(_ path: String) throws { try cloudKeepCurrent(path) }
    func oneRuleFixtureKeepText(_ path: String, _ text: String) throws { try cloudKeepText(path: path, content: Data(text.utf8), ref: nil, at: nil, device: nil) }
    /// What a relaunch plus a second run looks like: the in-memory list is gone and the settling starts over.
    func oneRuleFixtureRestart() throws {
        cloudOneRuleList = nil
        try db.run("DELETE FROM cloud_memory_control WHERE key IN ('oneRule:twins','oneRule:archived','oneRule:archivedCursor','oneRule:stubs','oneRule:reported')")
    }
}
