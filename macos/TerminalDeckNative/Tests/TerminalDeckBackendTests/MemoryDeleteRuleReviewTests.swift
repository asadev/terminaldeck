import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// L1 after the independent review (15 Nov): one test per finding the review listed as untested. Each one fails on
/// 824bd036c. Real stores on the approved scratch fixture; written unbuilt, the integrator runs them.
@Suite("Memory delete rule — after the review")
struct MemoryDeleteRuleReviewTests {
    private static let note = "hoot/notes/a.md"
    private func item(_ path: String) -> CloudDeleteItem { .init(id: "memory:" + path, kind: "memory", name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, place: path) }
    private func text(_ f: CloudBrainMemoryFixture, _ path: String = Self.note) -> String? { try? String(contentsOf: f.root.appendingPathComponent(path), encoding: .utf8) }
    private func exists(_ f: CloudBrainMemoryFixture, _ path: String = Self.note) -> Bool { FileManager.default.fileExists(atPath: f.root.appendingPathComponent(path).path) }
    private func actor(_ f: CloudBrainMemoryFixture, by: CloudDeleteBy = .person) -> CloudDeleteActor {
        .init(by: by, mac: f.deviceId, macName: "Mac mini", session: by == .ai ? "Night work" : nil,
              agent: by == .ai ? "Memory" : nil, at: 1_800_000_000_000, group: UUID().uuidString)
    }
    private func changes(_ f: CloudBrainMemoryFixture) async throws -> [CloudOperation] {
        let adapter = try f.adapter("I01")
        var cursor: String?, seen = Set<String>(), result: [CloudOperation] = []
        while let next = try await adapter.localChange(after: cursor) {
            if seen.insert(next.operation.opId).inserted { result.append(next.operation) }
            cursor = next.cursor
        }
        return result
    }
    private func removals(_ ops: [CloudOperation]) throws -> [DeckMemoryRemoval] {
        try ops.compactMap { op in
            let part = try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload))
            return Data(base64Encoded: part.data).flatMap(DeckMemoryRemoval.parse)
        }
    }
    private func pair(open: Bool = true) async throws -> (CloudBrainMemoryFixture, CloudBrainMemoryFixture) {
        let a = try CloudBrainMemoryFixture(), b = try CloudBrainMemoryFixture()
        try await a.seed()
        try await b.store.start()
        for row in ["I01", "I05", "I06"] {
            try await b.activate(row)
            _ = try await b.apply(try await a.snapshot(row).operations, row: row)
        }
        let ids = [a.deviceId, b.deviceId]
        for f in [a, b] {
            await f.store.cloudSetDevice(f.deviceId)
            await f.store.cloudSetClock { 1_800_000_000_000 }
            await f.store.cloudOneRuleSetAccountMacs(ids)
            await f.store.cloudSetOneRuleSending(true)
            if open { try await f.store.memoryRuleGate(ids) }
            try await f.store.oneRuleFixtureCaptureAll()
        }
        return (a, b)
    }

    // Decision 1. A Finder duplicate made earlier (same bytes, same note id), then the original deleted by hand:
    // never a travelling "moved"; a local mark here, the other Mac keeps the note.
    @Test func aHandDeletedNoteWithAnEarlierDuplicateNeverTravelsAsAMove() async throws {
        let (a, b) = try await pair()
        let duplicate = "hoot/notes/a copy.md"
        try a.write(duplicate, try #require(text(a)))
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot/notes"])
        _ = try await b.apply(try await changes(a), row: "I01")
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot/notes"])
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        let ops = try await changes(a)
        #expect(try removals(ops).isEmpty)
        _ = try await b.apply(ops, row: "I01")
        #expect(exists(b) && exists(b, duplicate))
        #expect(try await a.store.notHere().map(\.mark) == [.notOnThisMac])
        await a.close(); await b.close()
    }

    // Final look, must-fix 2. A helper seat folded back on A (the app's own move of its notes, topics and card)
    // arrives on B as moves: nothing is left at the old places and nothing is doubled.
    @Test func aHelperSeatFoldedBackArrivesOnTheOtherMacAsMovesWithoutDuplicates() async throws {
        let (a, b) = try await pair()
        let parent = DeckMemoryOwner.role(project: nil, role: "memory")
        let helper = DeckMemoryOwner.role(project: nil, role: "memory--helper-1")
        _ = try await a.store.ensureOwner(parent, name: "Memory")
        _ = try await a.store.ensureOwner(helper, name: "Helper 1", parent: parent)
        let note = try await a.store.addNote(.init(title: "Fold lesson", body: "Kept when the helper closes.", type: .lesson, stamp: .init(owner: helper)))
        _ = try await a.store.updateTopic(helper, title: "Folding", body: "Half done.", stamp: .init(owner: helper, job: "fold"))
        try await a.store.cloudCaptureChangedFiles(paths: [helper.folder, parent.folder])
        _ = try await b.apply(try await changes(a), row: "I01")
        let walker = FileManager.default.enumerator(at: a.root.appendingPathComponent(helper.folder), includingPropertiesForKeys: nil)
        let oldPaths = (walker?.allObjects ?? []).compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
            .map { String($0.standardizedFileURL.path.dropFirst(a.root.standardizedFileURL.path.count + 1)) }
        #expect(!oldPaths.isEmpty && oldPaths.allSatisfy { exists(b, $0) })
        _ = try await a.store.foldBack(helper, into: parent)
        try await a.store.cloudCaptureChangedFiles(paths: [parent.folder, "archive", helper.folder])
        try await a.store.oneRuleFixtureCaptureAll()
        let ops = try await changes(a), markers = try removals(ops)
        #expect(!markers.isEmpty && markers.allSatisfy { $0.movedTo != nil })
        _ = try await b.apply(ops, row: "I01")
        #expect(oldPaths.allSatisfy { !exists(b, $0) })
        let moved = try #require(try await a.store.note(id: note.id)?.path)
        #expect(exists(b, moved))
        let copies = (FileManager.default.enumerator(at: b.root, includingPropertiesForKeys: nil)?.allObjects ?? []).compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath && !$0.path.contains("/archive/") && ((try? String(contentsOf: $0, encoding: .utf8))?.contains("Kept when the helper closes.") ?? false) }
        #expect(copies.count == 1)
        #expect(try await a.store.notHere().isEmpty)
        await a.close(); await b.close()
    }

    // Decision 2. Badly formed removals arriving in a real sync batch beside an ordinary edit: the batch is applied,
    // the files are left alone, the edit is in use.
    @Test func badlyFormedRemovalsInARealBatchAreKeptAsHistoryAndTheRestOfTheBatchApplies() async throws {
        let (a, b) = try await pair()
        // All four in ONE batch of the files row (I01). A hand-off travels in its own row (I04, not synced by this
        // fixture), so the "moved to outside memory" case uses the shared template card, an I01 file.
        let card = "hoot/card.md", playbook = "hoot/playbook.md", shared = "templates/agent/card.md", topic = "hoot/topics/t.md"
        let before = [Self.note, card, playbook, shared].map { text(b, $0) }
        try await a.store.memoryReviewJournalMarker(Self.note, travel: [CloudDeleteTravel.rule: "2", CloudDeleteTravel.scope: "everywhere",
                                                                        CloudDeleteTravel.by: "person", CloudDeleteTravel.group: UUID().uuidString])
        try await a.store.memoryReviewJournalMarker(card, travel: [CloudDeleteTravel.rule: "1", CloudDeleteTravel.scope: "everywhere",
                                                                   CloudDeleteTravel.by: "person", CloudDeleteTravel.group: "not-a-uuid"])
        try await a.store.memoryReviewJournalMarker(playbook, travel: [CloudDeleteTravel.rule: "1", CloudDeleteTravel.scope: "nowhere",
                                                                       CloudDeleteTravel.by: "robot", CloudDeleteTravel.group: UUID().uuidString])
        try await a.store.memoryReviewJournalMarker(shared, travel: [:], movedTo: "../../outside-memory.md")
        let edited = (text(a, topic) ?? "") + "An ordinary edit in the same batch.\n"
        try a.write(topic, edited)
        try await a.store.cloudCaptureChangedFiles(paths: [topic])
        let ops = try await changes(a)
        #expect(try removals(ops).count == 4)
        _ = try await b.apply(ops, row: "I01")
        #expect([Self.note, card, playbook, shared].map { text(b, $0) } == before)
        #expect(text(b, topic) == edited)
        #expect(try await b.store.memoryBin().isEmpty)
        // The next batch still applies.
        let later = edited + "And a later one.\n"
        try a.write(topic, later)
        try await a.store.cloudCaptureChangedFiles(paths: [topic])
        _ = try await b.apply(try await changes(a), row: "I01")
        #expect(text(b, topic) == later)
        await a.close(); await b.close()
    }

    // Decision 3a. Stopped after the removal was journaled and before the file was deleted; he edits the note before
    // the next pass: his newer text wins, on top of the removal, on both Macs; the other files are still captured.
    @Test func anEditAfterAnInterruptedJournaledRemovalWinsOnEveryMac() async throws {
        let (a, b) = try await pair()
        try await a.store.memoryReviewJournalWithoutUnlink(actor(a).intent(place: Self.note, scope: .everywhere))
        let newer = (text(a) ?? "") + "Written after the delete was queued.\n"
        try a.write(Self.note, newer)
        let topic = "hoot/topics/t.md", topicText = (text(a, topic) ?? "") + "Another file in the same pass.\n"
        try a.write(topic, topicText)
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot"])
        #expect(text(a) == newer)
        #expect(try await a.store.memoryRuleIntentCount() == 0)
        let ops = try await changes(a)
        #expect(try removals(ops).count == 1)
        _ = try await b.apply(ops, row: "I01")
        #expect(text(b) == newer)
        #expect(text(b, topic) == topicText)
        #expect(try await a.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }

    // Decision 3b. A delete refused before its removal was journaled (the state the old deleteItems left after
    // throwing): a later edit of that note is never deleted "anyway".
    @Test func aRefusedDeleteFollowedByAnEditKeepsTheEditAndSendsNoRemoval() async throws {
        let (a, b) = try await pair()
        try await a.store.memoryReviewQueueWithoutJournal(actor(a).intent(place: Self.note, scope: .everywhere))
        let newer = (text(a) ?? "") + "His edit after the error.\n"
        try a.write(Self.note, newer)
        try await a.store.cloudCaptureChangedFiles(paths: [Self.note])
        try await a.store.cloudRetryMemoryIntents()
        #expect(text(a) == newer)
        #expect(try await a.store.memoryRuleIntentCount() == 0)
        let ops = try await changes(a)
        #expect(try removals(ops).isEmpty)
        _ = try await b.apply(ops, row: "I01")
        #expect(text(b) == newer)
        await a.close(); await b.close()
    }

    // Decision 4. An edit still waiting to upload when the file is then deleted by hand still reaches the Cloud.
    @Test func aWaitingEditStillUploadsWhenTheFileIsThenDeletedByHand() async throws {
        let (a, b) = try await pair()
        let last = (text(a) ?? "") + "His last words, written offline.\n"
        try a.write(Self.note, last)
        try await a.store.cloudCaptureChangedFiles(paths: [Self.note])
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        #expect(try await a.store.notHere().map(\.mark) == [.notOnThisMac])
        let ops = try await changes(a)
        #expect(try removals(ops).isEmpty)
        _ = try await b.apply(ops, row: "I01")
        #expect(text(b) == last)
        await a.close(); await b.close()
    }

    // Decision 5. Migration: an old Bin entry for the place whose text differs from the text last seen there (a newer
    // note was written at the old place, then deleted by hand on the old build) becomes a mark, never a removal.
    @Test func migrationTurnsAStaleBinEntryWithOtherTextIntoAMarkNotARemoval() async throws {
        let (a, b) = try await pair(open: false)
        let stale = "hoot/topics/reused-place.md"
        try a.write(stale, "# First\nRemoved in the app weeks ago.\n")
        try await a.store.cloudCaptureChangedFiles(paths: [stale])
        try await a.store.memoryRuleLegacyBin(stale, device: a.deviceId)
        try a.write(stale, "# Second\nA new note at the same place.\n")
        try await a.store.cloudCaptureChangedFiles(paths: [stale])
        _ = try await b.apply(try await changes(a), row: "I01")
        let journal = try await a.store.cloudJournalSize()
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(stale))
        try await a.store.memoryRuleLegacyControl("oneRule:queued:" + stale, value: "1")
        try await a.store.memoryRuleResetMigration()
        #expect(try await a.store.cloudMigrateDeleteRule())
        #expect(try await a.store.notHere().contains { $0.item.place == stale && $0.mark == .notOnThisMac })
        #expect(try await a.store.cloudJournalSize() == journal)
        #expect(try removals(try await changes(a)).isEmpty)
        #expect(text(b, stale) == "# Second\nA new note at the same place.\n")
        await a.close(); await b.close()
    }

    // Decision 6a. An arrival whose predecessor was placed at a different, now "Only on this Mac", place never
    // overwrites that place; the arrival lands at its own place.
    @Test func anArrivalNeverOverwritesAMarkedFileAtThePreviousVersionsPlace() async throws {
        let (a, b) = try await pair()
        let elsewhere = "hoot/notes/elsewhere.md"
        try await b.store.memoryReviewMoveProjection(from: Self.note, to: elsewhere)
        let local = try #require(text(b, elsewhere))
        let newer = (text(a) ?? "") + "A's newer edit.\n"
        try a.write(Self.note, newer)
        try await a.store.cloudCaptureChangedFiles(paths: [Self.note])
        _ = try await b.apply(try await changes(a), row: "I01")
        #expect(text(b, elsewhere) == local)
        #expect(text(b) == newer)
        #expect(try await b.store.notHere().contains { $0.item.place == elsewhere && $0.mark == .onlyOnThisMac })
        await a.close(); await b.close()
    }

    // Decision 6b. A "use this older version" (bring back) arrival at a place that is "Not on this Mac" is kept, not
    // placed; Bring back here then places it.
    @Test func aBringBackArrivalAtANotOnThisMacPlaceIsKeptUntilBroughtBackHere() async throws {
        let (a, b) = try await pair()
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        let older = (text(b) ?? "") + "An older wording he brought back on the MacBook.\n"
        try await b.store.oneRuleFixtureKeepText(Self.note, older)
        try await b.store.memoryUseVersion(path: Self.note, versionId: BackendCloudBrainMemoryHash.bytes(Data(older.utf8)))
        #expect(text(b) == older)
        _ = try await a.apply(try await changes(b), row: "I01")
        #expect(!exists(a))
        #expect(try await a.store.notHere().map(\.mark) == [.notOnThisMac])
        let back = try await a.store.bringBack([item(Self.note)], to: .thisMac)
        #expect(back.count == 1 && text(a) == older)
        await a.close(); await b.close()
    }

    // Decision 10. "Not on this Mac", then removed everywhere from the other Mac: the mark goes (nothing to bring back).
    @Test func aNotOnThisMacMarkGoesWhenAnotherMacRemovesThePlaceEverywhere() async throws {
        let (a, b) = try await pair()
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        _ = try await b.store.deleteItems([item(Self.note)], scope: .everywhere, by: actor(b))
        _ = try await a.apply(try await changes(b), row: "I01")
        #expect(try await a.store.notHere().isEmpty)
        #expect(!exists(a) && !exists(b))
        #expect(try await a.store.bringBack([item(Self.note)], to: .thisMac).isEmpty)
        await a.close(); await b.close()
    }

    // Decision 8a. Put back all continues past an item that cannot come back and names both lists.
    @Test func putBackAllContinuesPastAFailingItemAndNamesWhatDidNotComeBack() async throws {
        let (a, b) = try await pair()
        let paths = [Self.note, "hoot/playbook.md", "hoot/topics/t.md"]
        let group = try await a.store.deleteItems(paths.map(item), scope: .everywhere, by: actor(a, by: .ai))
        try await a.store.memoryReviewDropBinContent(paths[0])
        let result = try await a.store.memoryPutBackGroup(group.id)
        #expect(Set(result.back.compactMap(\.place)) == Set(paths.dropFirst()))
        #expect(result.notBack.compactMap(\.place) == [paths[0]])
        #expect(exists(a, paths[1]) && exists(a, paths[2]) && !exists(a, paths[0]))
        #expect(result.line.contains(result.notBack[0].name))
        await a.close(); await b.close()
    }
    @Test func putBackGroupAnswersWithWhatCameBackWhenSomethingDidNot() async throws {
        let (a, b) = try await pair()
        let paths = [Self.note, "hoot/playbook.md"]
        let group = try await a.store.deleteItems(paths.map(item), scope: .everywhere, by: actor(a, by: .ai))
        try await a.store.memoryReviewDropBinContent(paths[0])
        await #expect(throws: DeckMemoryError.self) { _ = try await a.store.putBackGroup(group.id) }
        #expect(exists(a, paths[1]))
        await a.close(); await b.close()
    }

    // Decision 8b. An item already back in use is never listed in its group.
    @Test func binGroupsNeverListAnItemThatIsAlreadyBack() async throws {
        let (a, b) = try await pair()
        let paths = [Self.note, "hoot/playbook.md"]
        let original = text(a, paths[1])
        let group = try await a.store.deleteItems(paths.map(item), scope: .everywhere, by: actor(a))
        try a.write(paths[1], original ?? "# Playbook\n")
        let listed = try await a.store.binGroups().first { $0.id == group.id }
        #expect(listed?.items.compactMap(\.place) == [Self.note])
        let result = try await a.store.memoryPutBackGroup(group.id)
        #expect(result.back.count == 1 && result.notBack.isEmpty)
        await a.close(); await b.close()
    }

    // Decision 8c. The same place removed twice within 30 days: each group brings back its OWN removed text.
    @Test func putBackAllRestoresItsOwnTextWhenThePlaceWasRemovedTwice() async throws {
        let (a, b) = try await pair()
        let first = try #require(text(a))
        let firstGroup = try await a.store.deleteItems([item(Self.note)], scope: .everywhere, by: actor(a, by: .ai))
        let second = first + "Written again after the first delete.\n"
        try a.write(Self.note, second)
        try await a.store.cloudCaptureChangedFiles(paths: [Self.note])
        let secondGroup = try await a.store.deleteItems([item(Self.note)], scope: .everywhere, by: actor(a, by: .ai))
        let ids = Set(try await a.store.binGroups().map(\.id))
        #expect(ids.contains(firstGroup.id) && ids.contains(secondGroup.id))
        let back = try await a.store.putBackGroup(firstGroup.id)
        #expect(back.count == 1)
        #expect(text(a) == first)
        #expect(try await a.store.oneRuleFixtureKeptTexts().contains(second))
        await a.close(); await b.close()
    }

    // Decision 9a. The witness is asked about the narrowest honest window: from the last time this Mac positively saw
    // the file (here the last full look, after its last capture) to the first look that found it gone.
    @Test func theWitnessIsAskedAboutTheNarrowestHonestWindow() async throws {
        let (a, b) = try await pair()
        let clock = ReviewClock(1_800_000_000_000)
        await a.store.cloudSetClock { clock.now }
        let group = UUID().uuidString
        let witness = RecordingWitness(answer: .ai(session: "Night work", agent: "Memory", command: Date(), group: group))
        let slot = CloudDeleteWitnessSlot()
        #expect(slot.installOnce(witness))
        await a.store.cloudDeleteUseWitness(slot, runStartedAt: 0)
        try await a.store.cloudCaptureChangedFiles(force: true, paths: [Self.note])
        clock.advance(60_000)
        try await a.store.cloudForgetRemovedFiles(prefixes: nil)          // a full look: the file is there
        clock.advance(10_000)
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.cloudForgetRemovedFiles(prefixes: nil)          // first look that finds it gone
        clock.advance(3_000)
        try await a.store.cloudForgetRemovedFiles(prefixes: nil)          // second look: the witness is asked
        for _ in 0..<300 {
            if witness.asked.count == 1, try await a.store.memoryRuleLastHash(Self.note) == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let asked = try #require(witness.asked.first)
        #expect(witness.asked.count == 1)
        #expect(abs(asked.goneAt.timeIntervalSince(asked.lastSeen) - 10) < 0.01)
        let markers = try removals(try await changes(a))
        #expect(markers.count == 1 && markers[0].byAI && markers[0].travel[CloudDeleteTravel.group] == group)
        await a.close(); await b.close()
    }

    // Decision 9b. Part of the window lies before this run of the app started: nobody watched, so it is by hand,
    // without asking.
    @Test func aFileGoneWhileTheAppWasNotRunningCountsAsByHandWithoutAsking() async throws {
        let (a, b) = try await pair()
        let clock = ReviewClock(1_800_000_000_000)
        await a.store.cloudSetClock { clock.now }
        let witness = RecordingWitness(answer: .ai(session: "Night work", agent: nil, command: Date(), group: UUID().uuidString))
        let slot = CloudDeleteWitnessSlot()
        #expect(slot.installOnce(witness))
        try await a.store.cloudCaptureChangedFiles(force: true, paths: [Self.note])
        clock.advance(60_000)
        // The app started again after it last saw the file.
        await a.store.cloudDeleteUseWitness(slot, runStartedAt: 1_800_000_030_000)
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.cloudForgetRemovedFiles(prefixes: [Self.note])
        clock.advance(3_000)
        try await a.store.cloudForgetRemovedFiles(prefixes: [Self.note])
        try await Task.sleep(for: .milliseconds(50))
        #expect(witness.asked.isEmpty)
        #expect(try await a.store.notHere().map(\.mark) == [.notOnThisMac])
        #expect(try removals(try await changes(a)).isEmpty)
        #expect(exists(b))
        await a.close(); await b.close()
    }

    // Decision 11. The service clock was not known at launch: the announcement is written by the next maintenance step.
    @Test func anAnnouncementThatWaitedForTheClockIsWrittenByTheNextStep() async throws {
        let f = try CloudBrainMemoryFixture()
        try await f.seed(); try await f.capture()
        await f.store.cloudSetDevice(f.deviceId)
        let clock = ReviewClock(nil)
        await f.store.cloudSetClock { clock.now }
        #expect(!(try await f.store.cloudFeatureAnnounce(CloudDeleteGate.feature, format: CloudDeleteGate.format, force: true)))
        clock.set(1_800_000_000_000)
        _ = try await f.store.cloudOneRuleStep()
        #expect(try await f.store.setting(CloudDeleteGate.key(device: f.deviceId), owner: nil) == CloudDeleteGate.value(at: 1_800_000_000_000))
        await f.close()
    }
}

private final class ReviewClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64?
    init(_ value: Int64?) { self.value = value }
    var now: Int64? { lock.withLock { value } }
    func set(_ new: Int64) { lock.withLock { value = new } }
    func advance(_ milliseconds: Int64) { lock.withLock { value = (value ?? 0) + milliseconds } }
}

private final class RecordingWitness: CloudDeleteWitness, @unchecked Sendable {
    struct Call { let lastSeen: Date; let goneAt: Date }
    private let lock = NSLock()
    private var calls: [Call] = []
    private let answer: CloudDeleteWitnessAnswer
    init(answer: CloudDeleteWitnessAnswer) { self.answer = answer }
    var asked: [Call] { lock.withLock { calls } }
    func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer {
        lock.withLock { calls.append(.init(lastSeen: lastSeen, goneAt: seenGoneAt)) }
        return answer
    }
}

extension DeckMemoryStore {
    /// A removal marker journaled as this Mac's own, with whatever new-rule fields a test gives it (a later or broken build).
    func memoryReviewJournalMarker(_ path: String, travel: [String: String], movedTo: String? = nil) throws {
        guard let inventory = try cloudFileInventoryRow(path, database: db) else { throw CloudFailure.invalidRequest }
        let origin = try db.first("SELECT store_id,resource_key,version FROM cloud_memory_file_origins WHERE path=?", [.text(path)])
        let store = try origin?.text(0) ?? cloudStoreId()
        let key = origin.map { $0.text(1).hasPrefix("file/") ? $0.text(1) : "file/" + path } ?? "file/" + path
        var removal = DeckMemoryRemoval(at: cloudNowMs(), by: cloudDeviceId ?? "", movedTo: movedTo)
        removal.travel = travel
        let data = Data(removal.text(id: Self.newNoteID(now()), name: "Fixture").utf8), hash = BackendCloudBrainMemoryHash.bytes(data)
        let copy = try cloudVersionsFolder().appendingPathComponent(hash)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: copy, options: .atomic)
        try cloudNoteRemoval(hash: hash, path: path, at: removal.at, movedTo: movedTo)
        try db.run("INSERT INTO cloud_memory_journal(inventory,resource_key,file,hash,base_version,source_store) VALUES (?,?,?,?,?,?)",
                   [.text(inventory), .text(key), .text(copy.path), .text(hash), .optional(origin?.string(2)), .text(store)])
    }
    /// The intent and its Bin copy, as deleteItems writes them first.
    private func memoryReviewQueue(_ intent: CloudDeleteIntent) throws -> Data {
        let path = intent.place, bytes = try Data(contentsOf: DeckMemoryCloudSchema.safePath(path, root: root))
        try CloudDeleteState(memory: db).putIntent(intent)
        let saved = try cloudKeeper().binPut(kind: Self.oneRuleKind, itemKey: Self.oneRuleItemKey(path), name: oneRuleName(path), place: Self.oneRulePlace(path),
                                           path: path, removedAt: intent.at, device: cloudDeviceId ?? "", content: bytes, shown: true, now: cloudNowMs())
        try cloudRememberBin(saved, intent: intent, era: .current)
        return bytes
    }
    /// Stopped after the old deleteItems refused (intent and Bin copy written, nothing journaled).
    func memoryReviewQueueWithoutJournal(_ intent: CloudDeleteIntent) throws { _ = try memoryReviewQueue(intent) }
    /// Stopped after the removal was journaled and before the file was deleted.
    func memoryReviewJournalWithoutUnlink(_ intent: CloudDeleteIntent) throws {
        let bytes = try memoryReviewQueue(intent)
        _ = try cloudJournalRemoval(path: intent.place, lastHash: BackendCloudBrainMemoryHash.bytes(bytes), knownBytes: bytes)
    }
    /// The version at `from` recorded as placed at `to` instead (an earlier copy), and `to` kept Only on this Mac.
    func memoryReviewMoveProjection(from: String, to: String) throws {
        let bytes = try Data(contentsOf: DeckMemoryCloudSchema.safePath(from, root: root))
        let target = try DeckMemoryCloudSchema.safePath(to, root: root)
        try bytes.write(to: target, options: .atomic)
        try db.run("UPDATE cloud_memory_versions SET projection=?,projected_hash=? WHERE projection=?", [.text(to), .text(BackendCloudBrainMemoryHash.bytes(bytes)), .text(from)])
        try CloudDeleteState(memory: db).putMark(.init(place: to, mark: .onlyOnThisMac, at: cloudNowMs()))
    }
    /// The Bin's kept bytes of one item are gone (a damaged keeper), so its Put back must fail.
    func memoryReviewDropBinContent(_ path: String) throws {
        let keeper = try cloudKeeper()
        guard let binned = try keeper.bin(itemKey: Self.oneRuleItemKey(path)) else { throw CloudFailure.invalidRequest }
        try FileManager.default.removeItem(at: keeper.contentURL(kind: binned.kind, sha256: binned.sha256))
    }
}
