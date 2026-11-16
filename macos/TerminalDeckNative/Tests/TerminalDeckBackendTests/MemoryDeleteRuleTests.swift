import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// L1, unbuilt. Every store, file, database and clock here belongs to the existing approved scratch fixture.
/// The import tests intentionally exercise the real projector, including the integration hook documented in the result.
@Suite("Memory delete rule")
struct MemoryDeleteRuleTests {
    private static let note = "hoot/notes/a.md"
    private func item(_ path: String) -> CloudDeleteItem { .init(id: "memory:" + path, kind: "memory", name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, place: path) }
    private func text(_ f: CloudBrainMemoryFixture, _ path: String = Self.note) -> String? { try? String(contentsOf: f.root.appendingPathComponent(path), encoding: .utf8) }
    private func exists(_ f: CloudBrainMemoryFixture, _ path: String = Self.note) -> Bool { FileManager.default.fileExists(atPath: f.root.appendingPathComponent(path).path) }
    private func actor(_ f: CloudBrainMemoryFixture, by: CloudDeleteBy = .person, group: String = UUID().uuidString) -> CloudDeleteActor {
        .init(by: by, mac: f.deviceId, macName: "Mac mini", session: by == .ai ? "Night work" : nil,
              agent: by == .ai ? "Memory" : nil, at: 1_800_000_000_000, group: group)
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

    @Test func existingAnnouncementWriterDeduplicatesAndForceRenews() async throws {
        let f = try CloudBrainMemoryFixture()
        try await f.seed(); try await f.capture()
        await f.store.cloudSetDevice(f.deviceId)
        await f.store.cloudSetClock { 1_800_000_000_000 }
        #expect(try await f.store.cloudFeatureAnnounce(CloudDeleteGate.feature, format: 1))
        #expect(!(try await f.store.cloudFeatureAnnounce(CloudDeleteGate.feature, format: 1)))
        #expect(try await f.store.cloudFeatureAnnounce(CloudDeleteGate.feature, format: 1, force: true))
        await f.close()
    }

    @Test func aThousandFilesGoneByHandMeanAThousandMarksAndNothingSent() async throws {
        let (a, b) = try await pair()
        let paths = (0..<1_000).map { "hoot/topics/by-hand-\($0).md" }
        for (index, path) in paths.enumerated() { try a.write(path, "# Topic \(index)\nIts own distinct text \(index).\n") }
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot/topics"])
        _ = try await b.apply(try await changes(a), row: "I01")
        let before = try await a.store.oneRuleFixtureFileJournal()
        for path in paths { try FileManager.default.removeItem(at: a.root.appendingPathComponent(path)) }
        try await a.store.oneRuleFixtureResolveGoneByHand(paths)
        try await a.store.oneRuleFixtureCaptureAll()
        let marks = try await a.store.notHere()
        #expect(marks.count == 1_000)
        #expect(marks.allSatisfy { $0.mark == .notOnThisMac })
        #expect(try await a.store.oneRuleFixtureFileJournal() == before)
        #expect(try removals(try await changes(a)).isEmpty)
        #expect(paths.allSatisfy { !exists(a, $0) && exists(b, $0) })
        #expect(try await a.store.memoryBin().isEmpty)
        await a.close(); await b.close()
    }

    @Test func twoLooksAreRequiredBeforeTheUnknownWitnessCanMarkAFile() async throws {
        let (a, b) = try await pair()
        let clock = MemoryDeleteTestClock(1_800_000_000_000)
        await a.store.cloudSetClock { clock.now }
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.cloudForgetRemovedFiles(prefixes: [Self.note])
        #expect(try await a.store.notHere().isEmpty)
        clock.advance(milliseconds: 2_999)
        try await a.store.cloudForgetRemovedFiles(prefixes: [Self.note])
        #expect(try await a.store.notHere().isEmpty)
        clock.advance(milliseconds: 1)
        try await a.store.cloudForgetRemovedFiles(prefixes: [Self.note])
        for _ in 0..<100 {
            if try await a.store.notHere().count == 1 { break }
            await Task.yield()
        }
        #expect(try await a.store.notHere().map(\.mark) == [.notOnThisMac])
        #expect(try removals(try await changes(a)).isEmpty)
        await a.close(); await b.close()
    }

    @Test func aMissingRootIsNeitherMarkedNorSent() async throws {
        let (a, b) = try await pair()
        let moved = a.base.appendingPathComponent("Memory-unplugged")
        try FileManager.default.moveItem(at: a.root, to: moved)
        try await a.store.cloudForgetRemovedFiles(prefixes: nil)
        #expect(try await a.store.notHere().isEmpty)
        #expect(try removals(try await changes(a)).isEmpty)
        try FileManager.default.moveItem(at: moved, to: a.root)
        #expect(exists(a))
        await a.close(); await b.close()
    }

    @Test func affirmativeAIWitnessDeletesEverywhereWithOneAttributedGroup() async throws {
        let (a, b) = try await pair()
        let paths = [Self.note, "hoot/playbook.md", "hoot/topics/t.md"]
        let group = UUID().uuidString
        for path in paths {
            let hash = try await a.store.memoryRuleLastHash(path)
            try FileManager.default.removeItem(at: a.root.appendingPathComponent(path))
            try await a.store.cloudResolveMemoryGone(path: path, lastHash: hash, lastSeen: Date(timeIntervalSince1970: 1_799_999_990),
                                                    goneAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                    answer: .ai(session: "Night work", agent: "Memory", command: Date(), group: group))
        }
        let ops = try await changes(a), markers = try removals(ops)
        #expect(markers.count == paths.count)
        #expect(markers.allSatisfy { $0.byAI && $0.travel[CloudDeleteTravel.scope] == "everywhere" && $0.travel[CloudDeleteTravel.group] == group })
        #expect(markers.allSatisfy { $0.travel[CloudDeleteTravel.session] == "Night work" && $0.travel[CloudDeleteTravel.agent] == "Memory" })
        _ = try await b.apply(ops, row: "I01")
        #expect(paths.allSatisfy { !exists(a, $0) && !exists(b, $0) })
        #expect(try await a.store.binGroups().first?.items.count == 3)
        #expect(try await b.store.binGroups().first?.items.count == 3)
        #expect(try await b.store.notHere().isEmpty)
        await a.close(); await b.close()
    }

    @Test func AIToolsCanDeleteCardsPlaybooksAndTopicsUsingTheSameIntent() async throws {
        let (a, b) = try await pair()
        let paths = ["hoot/card.md", "hoot/playbook.md", "hoot/topics/t.md"]
        let who = actor(a, by: .ai)
        let group = try await a.store.deleteItems(paths.map(item), scope: .everywhere, by: who)
        #expect(group.id == who.group && group.count == 3 && group.by == .ai)
        #expect(try await a.store.memoryRuleIntentCount() == 0)
        _ = try await b.apply(try await changes(a), row: "I01")
        #expect(paths.allSatisfy { !exists(a, $0) && !exists(b, $0) })
        #expect(try await b.store.binGroups().first?.session == "Night work")
        await a.close(); await b.close()
    }

    @Test func cloudScopeKeepsBothCopiesAndExplicitReturnPublishesLocalText() async throws {
        let (a, b) = try await pair()
        let beforeA = text(a), beforeB = text(b)
        _ = try await a.store.deleteItems([item(Self.note)], scope: .cloud, by: actor(a))
        let removed = try await changes(a)
        _ = try await b.apply(removed, row: "I01")
        #expect(text(a) == beforeA && text(b) == beforeB)
        #expect(try await a.store.notHere().map(\.mark) == [.onlyOnThisMac])
        #expect(try await b.store.notHere().map(\.mark) == [.onlyOnThisMac])
        let localA = (beforeA ?? "") + "A's local-only addition.\n"
        let localB = (beforeB ?? "") + "B's local-only addition.\n"
        try a.write(Self.note, localA); try b.write(Self.note, localB)
        _ = try await a.store.reindex(); _ = try await b.store.reindex()
        let journal = try await b.store.oneRuleFixtureFileJournal()
        try await b.store.cloudCaptureChangedFiles(force: true, paths: [Self.note])
        #expect(try await b.store.oneRuleFixtureFileJournal() == journal)
        let cut = try await b.snapshot("I01")
        #expect(try cut.operations.allSatisfy { op in
            let p = try JSONDecoder().decode(CloudBrainMemoryPart.self, from: CloudWire.canonical(op.payload))
            return p.key != "file/" + Self.note
        })
        let restored = try await a.store.bringBack([item(Self.note)], to: .cloud)
        #expect(restored.count == 1)
        _ = try await b.apply(try await changes(a), row: "I01")
        #expect(text(a) == localA && text(b) == localA)
        let marksA = try await a.store.notHere(), marksB = try await b.store.notHere()
        #expect(marksA.isEmpty && marksB.isEmpty)
        #expect(try await b.store.oneRuleFixtureKeptTexts().contains(localB))
        await a.close(); await b.close()
    }

    @Test func aLocalAbsenceSurvivesNewCloudVersionsAndARealStoreReopen() async throws {
        let (a, b) = try await pair()
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        let newer = (text(b) ?? "") + "A newer edit on the other Mac.\n"
        try b.write(Self.note, newer)
        try await b.store.cloudCaptureChangedFiles(paths: [Self.note])
        _ = try await a.apply(try await changes(b), row: "I01")
        #expect(!exists(a))
        await a.store.close()
        let reopened = try DeckMemoryStore(root: a.root, dataRoot: a.base.appendingPathComponent("Data"), embedder: nil, watch: false, now: { Date(timeIntervalSince1970: 1000.125) })
        try await reopened.cloudResumeCapture(stateRoot: a.stateRoot)
        #expect(try await reopened.notHere().map(\.mark) == [.notOnThisMac])
        #expect(!exists(a))
        let back = try await reopened.bringBack([item(Self.note)], to: .thisMac)
        #expect(back.count == 1 && text(a) == newer)
        #expect(try await reopened.notHere().isEmpty)
        await reopened.close(); await a.close(); await b.close()
    }

    @Test func reappearingEarlierBytesDoNotRollBackANewerCloudEdit() async throws {
        let (a, b) = try await pair()
        let earlier = try #require(text(a))
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        let newest = earlier + "Latest on MacBook.\n"
        try b.write(Self.note, newest); try await b.store.cloudCaptureChangedFiles(paths: [Self.note])
        _ = try await a.apply(try await changes(b), row: "I01")
        let journal = try await a.store.oneRuleFixtureFileJournal()
        try a.write(Self.note, earlier)
        try await a.store.cloudCaptureChangedFiles(paths: [Self.note])
        #expect(text(a) == newest)
        #expect(try await a.store.notHere().isEmpty)
        #expect(try await a.store.oneRuleFixtureFileJournal() == journal)
        await a.close(); await b.close()
    }

    @Test func reappearingNewestBytesClearTheMarkWithoutSending() async throws {
        let (a, b) = try await pair()
        let newest = try #require(text(a))
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        let journal = try await a.store.oneRuleFixtureFileJournal()
        try a.write(Self.note, newest)
        try await a.store.cloudCaptureChangedFiles(paths: [Self.note])
        #expect(try await a.store.notHere().isEmpty)
        #expect(try await a.store.oneRuleFixtureFileJournal() == journal)
        await a.close(); await b.close()
    }

    @Test func reappearingNewBytesAreOnTopOfTheNewestCloudVersion() async throws {
        let (a, b) = try await pair()
        let earlier = try #require(text(a))
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        let newest = earlier + "The other Mac's latest.\n"
        try b.write(Self.note, newest); try await b.store.cloudCaptureChangedFiles(paths: [Self.note])
        _ = try await a.apply(try await changes(b), row: "I01")
        let own = earlier + "My new words after putting a file here.\n"
        try a.write(Self.note, own); try await a.store.cloudCaptureChangedFiles(paths: [Self.note])
        #expect(text(a) == own)
        #expect(try await a.store.notHere().isEmpty)
        #expect(try await a.store.oneRuleFixtureKeptTexts().contains(newest))
        _ = try await b.apply(try await changes(a), row: "I01")
        #expect(text(b) == own)
        await a.close(); await b.close()
    }

    @Test func aClosedGateRefusesCloudScopeAndSendsCompatibleEverywhere() async throws {
        let (a, b) = try await pair(open: false)
        #expect(!(await a.store.cloudDeleteRuleIsOpen()))
        let original = text(a)
        await #expect(throws: DeckMemoryError.self) { _ = try await a.store.deleteItems([item(Self.note)], scope: .cloud, by: actor(a)) }
        #expect(text(a) == original)
        #expect(try await a.store.memoryRuleIntentCount() == 0)
        #expect(try await a.store.memoryBin().isEmpty)
        _ = try await a.store.deleteItems([item(Self.note)], scope: .everywhere, by: actor(a, by: .ai))
        let ops = try await changes(a), markers = try removals(ops)
        #expect(markers.count == 1 && markers[0].travel.isEmpty && markers[0].byAI)
        _ = try await b.apply(ops, row: "I01")
        #expect(!exists(b))
        let bin = try await b.store.binGroups()
        #expect(bin.first?.era == .olderVersion)
        #expect(try await b.store.memoryBinText(path: Self.note) == original)
        await a.close(); await b.close()
    }

    @Test func aStaleWitnessCannotDeleteAFileThatHasReturned() async throws {
        let (a, b) = try await pair()
        let hash = try await a.store.memoryRuleLastHash(Self.note)
        let current = try #require(text(a)) + "Returned while the witness was looking.\n"
        try a.write(Self.note, current)
        try await a.store.cloudResolveMemoryGone(path: Self.note, lastHash: hash, lastSeen: Date().addingTimeInterval(-10), goneAt: Date(),
                                                answer: .ai(session: "Night work", agent: nil, command: Date(), group: UUID().uuidString))
        #expect(text(a) == current)
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(try await a.store.notHere().isEmpty)
        await a.close(); await b.close()
    }

    @Test func anInterruptedIntentIsFinishedOnlyAfterItsBytesAreInTheKeeper() async throws {
        let (a, b) = try await pair()
        let original = text(a)
        let intent = actor(a, by: .ai).intent(place: Self.note, scope: .everywhere)
        try await a.store.memoryRulePutIntent(intent)
        try await a.store.cloudRetryMemoryIntents()
        #expect(!exists(a))
        #expect(try await a.store.memoryBinText(path: Self.note) == original)
        #expect(try await a.store.memoryRuleIntentCount() == 0)
        #expect(try removals(try await changes(a)).count == 1)
        await a.close(); await b.close()
    }

    @Test func groupsPutBackTogetherAndDeleteForGoodIsLimitedToSelectedBinRows() async throws {
        let (a, b) = try await pair()
        let paths = [Self.note, "hoot/playbook.md", "hoot/topics/t.md"]
        let group = try await a.store.deleteItems(paths.map(item), scope: .everywhere, by: actor(a))
        #expect(try await a.store.binGroups().map(\.id) == [group.id])
        try await a.store.deleteForGood([item(paths[2])])
        #expect(try await a.store.binGroups().first?.count == 2)
        #expect(try await a.store.memoryBinText(path: paths[2]) == nil)
        let restored = try await a.store.putBackGroup(group.id)
        #expect(restored.count == 2)
        #expect(exists(a, paths[0]) && exists(a, paths[1]) && !exists(a, paths[2]))
        #expect(try await a.store.binGroups().isEmpty)
        await a.close(); await b.close()
    }

    @Test func migrationDistinguishesIntendedQueuedHeldAndGoneWithoutDeletingLiveFiles() async throws {
        let (a, b) = try await pair(open: false)
        let intended = "hoot/topics/queued-intended.md", hand = "hoot/topics/queued-hand.md"
        let waiting = "hoot/topics/waiting-intended.md", gone = "hoot/topics/gone.md"
        for path in [intended, hand, waiting, gone] { try a.write(path, "# " + path + "\nUnique kept words.\n") }
        try await a.store.cloudCaptureChangedFiles(paths: ["hoot/topics"])
        _ = try await b.apply(try await changes(a), row: "I01")
        _ = try await b.store.memoryRemove(path: Self.note)
        let heldOps = try await changes(b)
        try await a.store.memoryRuleStageHeld(heldOps, path: Self.note)
        let heldText = text(a)
        try await a.store.memoryRuleLegacyBin(intended, device: a.deviceId)
        try await a.store.memoryRuleLegacyBin(waiting, device: a.deviceId)
        for path in [intended, hand, waiting, gone] { try FileManager.default.removeItem(at: a.root.appendingPathComponent(path)) }
        try await a.store.memoryRuleLegacyControl("oneRule:queued:" + intended, value: "1")
        try await a.store.memoryRuleLegacyControl("oneRule:queued:" + hand, value: "1")
        try await a.store.memoryRuleLegacyControl("oneRule:removalsWaiting", value: "1")
        try await a.store.memoryRuleLegacyControl("oneRule:massMissing", value: "4")
        try await a.store.memoryRuleResetMigration()
        #expect(try await a.store.cloudMigrateDeleteRule())
        let marks = try await a.store.notHere()
        #expect(Set(marks.compactMap(\.item.place)) == Set([hand, gone]))
        #expect(text(a) == heldText)
        #expect(try await a.store.memoryRuleLegacyStateIsGone())
        let markers = try removals(try await changes(a))
        #expect(markers.count == 2)
        let journal = try await a.store.cloudJournalSize()
        #expect(try await a.store.cloudMigrateDeleteRule())
        #expect(try await a.store.cloudJournalSize() == journal)
        let bins = try await a.store.binGroups()
        #expect(bins.count == 1 && bins[0].era == .beforeNewRule && bins[0].count == 2)
        #expect(try await a.store.memoryRuleSafetyCopyExists())
        await a.close(); await b.close()
    }

    @Test func reappearingOldBytesStayRecognisableAfterTheirLocalByteCacheIsPruned() async throws {
        let (a, b) = try await pair()
        let earlier = try #require(text(a)), oldHash = BackendCloudBrainMemoryHash.bytes(Data(earlier.utf8))
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(Self.note))
        try await a.store.oneRuleFixtureResolveGoneByHand([Self.note])
        let newest = earlier + "The newer edit is still the Cloud head.\n"
        try b.write(Self.note, newest); try await b.store.cloudCaptureChangedFiles(paths: [Self.note])
        _ = try await a.apply(try await changes(b), row: "I01")
        try await a.store.memoryRulePruneOldObservationBytes(hash: oldHash)
        let journal = try await a.store.oneRuleFixtureFileJournal()
        try a.write(Self.note, earlier)
        try await a.store.cloudCaptureChangedFiles(paths: [Self.note])
        #expect(text(a) == newest)
        #expect(try await a.store.oneRuleFixtureFileJournal() == journal)
        await a.close(); await b.close()
    }

    @Test func byHandWitnessNeverTurnsACardAbsenceIntoARemoval() async throws {
        let (a, b) = try await pair()
        let path = "hoot/card.md", hash = try await a.store.memoryRuleLastHash("hoot/card.md")
        try FileManager.default.removeItem(at: a.root.appendingPathComponent(path))
        try await a.store.cloudResolveMemoryGone(path: path, lastHash: hash, lastSeen: Date().addingTimeInterval(-10), goneAt: Date(), answer: .notAI)
        #expect(try await a.store.notHere().map(\.mark) == [.notOnThisMac])
        #expect(try removals(try await changes(a)).isEmpty)
        #expect(exists(b, path))
        await a.close(); await b.close()
    }

    @Test func binGroupsResolveMacNamesFromThePublishedDeviceList() async throws {
        let (a, b) = try await pair()
        var device = CloudDevice(deviceId: a.deviceId, label: "Desk Mac", platform: .macos, appVersion: "fixture", status: .active,
                                 secretsApproved: false, lastSeenAt: 1_800_000_000_000,
                                 signPublicJwk: BackendCloudContentsFixture.key, wrapPublicJwk: BackendCloudContentsFixture.key)
        device.displayName = "Asad's Mac mini"
        try await a.store.cloudDeleteSetDevices([device])
        try await b.store.cloudDeleteSetDevices([device])
        _ = try await a.store.deleteItems([item(Self.note)], scope: .everywhere, by: actor(a, by: .ai))
        _ = try await b.apply(try await changes(a), row: "I01")
        let group = try #require(try await b.store.binGroups().first)
        #expect(group.macName == "Asad's Mac mini")
        #expect(group.title.contains("Asad's Mac mini") && !group.title.contains(a.deviceId))
        #expect(group.session == "Night work" && group.agent == "Memory")
        await a.close(); await b.close()
    }

    @Test func aDisabledFileInventoryCannotTurnARefusedRemovalIntoALocalUnlink() async throws {
        let (a, b) = try await pair()
        let original = text(a)
        try await a.store.cloudResumeCapture(stateRoot: a.stateRoot, rows: ["I05"])
        await #expect(throws: CloudFailure.self) { _ = try await a.store.deleteItems([item(Self.note)], scope: .everywhere, by: actor(a)) }
        #expect(text(a) == original)
        #expect(try await a.store.memoryBin().isEmpty)
        #expect(try await a.store.memoryRuleIntentCount() == 0)
        await a.close(); await b.close()
    }

    @Test func malformedNewMarkerNeverFallsBackToAnEverywhereDelete() throws {
        var marker = DeckMemoryRemoval(at: 1, by: UUID().uuidString, movedTo: nil)
        marker.travel = [CloudDeleteTravel.rule: "9", CloudDeleteTravel.scope: "everywhere"]
        let back = try #require(DeckMemoryRemoval.parse(Data(marker.text(id: "fixture", name: "Fixture").utf8)))
        #expect(throws: CloudDeleteRuleError.self) { _ = try CloudDeleteTravel.read(back.travel, place: Self.note, mac: back.by, at: back.at) }
    }
}

private final class MemoryDeleteTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64) { self.value = value }
    var now: Int64? { lock.withLock { value } }
    func advance(milliseconds: Int64) { lock.withLock { value += milliseconds } }
}

extension DeckMemoryStore {
    func memoryRulePruneOldObservationBytes(hash: String) throws {
        try db.run("DELETE FROM cloud_memory_parts WHERE content_hash=?", [.text(hash)])
        try db.run("DELETE FROM cloud_memory_versions WHERE content_hash=?", [.text(hash)])
        let copy = try cloudVersionsFolder().appendingPathComponent(hash)
        if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
    }
    func memoryRuleGate(_ ids: [String]) throws {
        for id in ids { try setSetting(CloudDeleteGate.value(at: cloudNowMs()), key: CloudDeleteGate.key(device: id), owner: nil) }
    }
    func memoryRuleLastHash(_ path: String) throws -> String? { try db.first("SELECT hash FROM cloud_memory_files WHERE path=?", [.text(path)])?.string(0) }
    func memoryRuleIntentCount() throws -> Int { _ = try CloudDeleteState(memory: db); return Int(try db.first("SELECT COUNT(*) FROM cloud.cloud_delete_intents")?.int(0) ?? 0) }
    func memoryRulePutIntent(_ intent: CloudDeleteIntent) throws { try CloudDeleteState(memory: db).putIntent(intent) }
    func memoryRuleLegacyControl(_ key: String, value: String) throws { try db.run("INSERT OR REPLACE INTO cloud_memory_control(key,value) VALUES (?,?)", [.text(key), .text(value)]) }
    func memoryRuleLegacyBin(_ path: String, device: String) throws {
        let bytes = try Data(contentsOf: DeckMemoryCloudSchema.safePath(path, root: root))
        try cloudKeeper().binPut(kind: Self.oneRuleKind, itemKey: Self.oneRuleItemKey(path), name: oneRuleName(path), place: nil, path: path,
                                 removedAt: cloudNowMs(), device: device, content: bytes, shown: true, now: cloudNowMs())
    }
    func memoryRuleResetMigration() throws {
        try db.run("DELETE FROM cloud_memory_control WHERE key IN (?,?)", [.text(Self.deleteRuleMigrationKey), .text(Self.deleteRuleSafetyKey)])
    }
    func memoryRuleLegacyStateIsGone() throws -> Bool {
        try db.first("SELECT 1 FROM cloud.sqlite_master WHERE name='cloud_memory_held_removals'") == nil
            && db.first("SELECT 1 FROM cloud_memory_control WHERE key LIKE 'oneRule:queued:%' OR key IN ('oneRule:massMissing','oneRule:removalsWaiting')") == nil
    }
    func memoryRuleSafetyCopyExists() throws -> Bool {
        guard let path = try db.first("SELECT value FROM cloud_memory_control WHERE key=?", [.text(Self.deleteRuleSafetyKey)])?.string(0) else { return false }
        return FileManager.default.fileExists(atPath: path + "/memory/memory-cloud.db")
    }
    func memoryRuleStageHeld(_ ops: [CloudOperation], path: String) throws {
        for op in ops {
            let p = try cloudValidatePart(op, row: "I01")
            guard p.key == "file/" + path, let body = Data(base64Encoded: p.data), DeckMemoryRemoval.parse(body) != nil else { continue }
            try db.run("INSERT OR IGNORE INTO cloud_memory_parts(op_id,op_hash,operation,entity_id,parents,store_id,inventory,resource_key,revision,content_hash,part,total,bytes,body) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       [.text(op.opId), .text(DeckMemoryFiles.hash(try CloudWire.canonical(op))), .blob(try CloudWire.canonical(op)), .text(op.entityId),
                        .blob(try CloudWire.canonical(p.parents)), .text(p.storeId), .text(p.inventoryRow), .text(p.key), .text(p.version), .text(p.resourceHash),
                        .int(Int64(p.index)), .int(Int64(p.count)), .int(Int64(p.bytes) ?? 0), .blob(body)])
            _ = try cloudAssemble(p)
            _ = try cloudKeepVersionForOneRule(p)
            try db.exec("CREATE TABLE IF NOT EXISTS cloud.cloud_memory_held_removals(store_id TEXT,resource_key TEXT,revision TEXT,path TEXT,device TEXT)")
            try db.run("INSERT INTO cloud.cloud_memory_held_removals VALUES (?,?,?,?,?)", [.text(p.storeId), .text(p.key), .text(p.version), .text(path), .text(op.originDevice)])
        }
    }
}
