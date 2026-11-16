import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor FilesRuleWitness: CloudDeleteWitness {
    let answer: CloudDeleteWitnessAnswer
    private(set) var paths: [URL] = []
    private(set) var times: [(Date, Date)] = []
    init(_ answer: CloudDeleteWitnessAnswer) { self.answer = answer }
    func who(removed path: URL, lastSeen: Date, seenGoneAt: Date) async -> CloudDeleteWitnessAnswer {
        paths.append(path); times.append((lastSeen, seenGoneAt)); return answer
    }
}

struct CloudFolderDeleteRuleTests {
    func actor(_ f: CloudFolderFixture, by: CloudDeleteBy = .person) -> CloudDeleteActor {
        .init(by: by, mac: f.deviceA, macName: "Mac mini", session: by == .ai ? "Night work" : nil,
              agent: by == .ai ? "Reviewer" : nil, at: f.clock.ms, group: UUID().uuidString.lowercased())
    }
    func item(_ path: String) -> CloudDeleteItem { .init(id: path, kind: BackendCloudFolder.kind, name: (path as NSString).lastPathComponent, place: path) }
    func install(_ answer: CloudDeleteWitnessAnswer, on owner: BackendCloudFolder) async -> FilesRuleWitness {
        let witness = FilesRuleWitness(answer), slot = CloudDeleteWitnessSlot()
        #expect(slot.installOnce(witness)); await owner.setDeleteWitness(slot)
        return witness
    }
    @Test func hundredsGoneByHandAreMarksWithNoJournalNoBinAndNoQuestion() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stays.md", "root is here")
        for n in 0..<240 { try f.write("a", "f\(n).md", "\(n)") }
        try await f.settle(a)
        let before = try await CloudFolderFixture.journal(a).count
        let witness = await install(.notAI, on: a)
        for n in 0..<240 { try f.remove("a", "f\(n).md") }
        try await f.settle(a)
        #expect(try await a.notHere().count == 240)
        #expect(try await a.notHere().allSatisfy { $0.mark == .notOnThisMac })
        #expect(try await CloudFolderFixture.journal(a).count == before)
        #expect(try await a.bin().isEmpty)
        #expect(try await a.waitingAnswer() == nil)
        #expect(await witness.paths.count == 240)
        #expect(await witness.times.allSatisfy { $0.0 <= $0.1 })
        await a.sendNow(); try await a.look()
        #expect(await witness.paths.count == 240)
        #expect(f.text("a", "f0.md") == nil)
    }
    @Test func anUnknownWitnessIsLocalAndTheMarkSurvivesRestartAndNewerArrivals() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try f.remove("a", "note.md"); try await f.settle(a)
        f.clock.advance(120_000); try f.write("b", "note.md", "two"); try await f.settle(b)
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        let reopened = try await f.mac("a", device: f.deviceA)
        try await f.settle(reopened); await reopened.sendNow()
        #expect(f.text("a", "note.md") == nil)
        #expect(try await reopened.notHere().map(\.item.id) == ["note.md"])
        _ = try await reopened.bringBack([item("note.md")], to: .thisMac)
        #expect(f.text("a", "note.md") == "two")
        #expect(try await reopened.notHere().isEmpty)
    }
    @Test func emptyMissingOrUnreadableRootCreatesNoMarksAndSendsNothing() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "one.md", "one"); try await f.settle(a)
        let before = try await CloudFolderFixture.journal(a).count
        try f.remove("a", "one.md"); try await f.settle(a)
        #expect(try await a.notHere().isEmpty)
        #expect(try await a.waitingAnswer()?.folderMissing == true)
        try FileManager.default.removeItem(at: f.folder("a")); try await f.settle(a)
        #expect(try await a.notHere().isEmpty)
        // A regular file at the root path is reliably unreadable as a directory, on any test runner uid.
        try Data("not a folder".utf8).write(to: f.folder("a")); try await f.settle(a)
        #expect(try await a.notHere().isEmpty)
        #expect(try await CloudFolderFixture.journal(a).count == before)
    }
    @Test func firstAbsentLookAndEditorRewriteNeverBecomeADelete() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        let witness = await install(.notAI, on: a)
        try f.remove("a", "note.md"); try await a.look()
        #expect(try await a.notHere().isEmpty); #expect(await witness.paths.isEmpty)
        try f.write("a", "note.md", "one"); f.clock.advance(4_000); try await a.look()
        #expect(try await a.notHere().isEmpty); #expect(await witness.paths.isEmpty)
    }
    @Test func witnessedAIUsesEverywhereAndOneGroupForItsWholeCommand() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.setDeleteRuleGate { true }
        try f.write("a", "stay.md", "s")
        for n in 0..<60 { try f.write("a", "f\(n).md", "file \(n)") }
        try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        let group = UUID().uuidString.lowercased()
        _ = await install(.ai(session: "Night work", agent: "Reviewer", command: Date(), group: group), on: a)
        for n in 0..<60 { try f.remove("a", "f\(n).md") }
        try await f.settle(a)
        let operations = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(operations.filter { $0.kind == .archive }.count == 60)
        #expect(operations.filter(CloudFileDeleteRecords.isAbout).count == 60)
        #expect(try await b.bin().count == 60)
        let bin = try #require(try await b.binGroups().first)
        #expect(bin.id == group && bin.by == .ai && bin.session == "Night work" && bin.count == 60)
        #expect(try await b.waitingAnswer() == nil)
        #expect(f.text("b", "f59.md") == nil)
    }
    @Test func cloudScopeKeepsBothDevicesAndPutInCloudAgainPublishesThisDevicesBytes() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.setDeleteRuleGate { true }; await b.setDeleteRuleGate { true }
        try f.write("a", "note.md", "one"); try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        _ = try await a.deleteItems([item("note.md")], scope: .cloud, by: actor(f))
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("a", "note.md") == "one" && f.text("b", "note.md") == "one")
        #expect(try await a.notHere().first?.mark == .onlyOnThisMac)
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
        let before = try await CloudFolderFixture.journal(b).count
        f.clock.advance(120_000); try f.write("b", "note.md", "B's bytes"); try await f.settle(b)
        #expect(try await CloudFolderFixture.journal(b).count == before)
        _ = try await b.bringBack([item("note.md")], to: .cloud)
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        #expect(f.text("a", "note.md") == "B's bytes")
        #expect(try await a.notHere().isEmpty)
        #expect(try await b.notHere().isEmpty)
        #expect(!(try await a.versions(path: "note.md")).isEmpty)
    }
    @Test func closedGateRefusesCloudAndSendsEverywhereInOldForm() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "note.md", "one"); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        await #expect(throws: (any Error).self) { _ = try await a.deleteItems([item("note.md")], scope: .cloud, by: actor(f)) }
        #expect(f.text("a", "note.md") == "one")
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f, by: .ai))
        let operations = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(!operations.contains(where: CloudFileDeleteRecords.isAbout))
        #expect(f.text("b", "note.md") == nil)
        #expect(try await b.binGroups().first?.era == .olderVersion)
    }
    @Test func reappearingEarlierOwnVersionUsesNewestAndUnknownBytesBecomeNewHead() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "old A"); try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try f.remove("a", "note.md"); try await f.settle(a)
        f.clock.advance(120_000); try f.write("b", "note.md", "new B"); try await f.settle(b)
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        let before = try await CloudFolderFixture.journal(a).count
        try f.write("a", "note.md", "old A"); try await f.settle(a)
        #expect(f.text("a", "note.md") == "new B")
        #expect(try await CloudFolderFixture.journal(a).count == before)
        try f.remove("a", "note.md"); try await f.settle(a)
        try f.write("a", "note.md", "brand new", modified: f.clock.ms - 1_000_000)
        try await f.settle(a)
        #expect(f.text("a", "note.md") == "brand new")
        #expect(try await CloudFolderFixture.journal(a).count > before)
        #expect(try await a.notHere().isEmpty)
    }
    @Test func reappearingNewestBytesClearOnlyTheMark() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "s"); try f.write("a", "note.md", "one"); try await f.settle(a)
        let before = try await CloudFolderFixture.journal(a).count
        try f.remove("a", "note.md"); try await f.settle(a)
        try f.write("a", "note.md", "one"); try await f.settle(a)
        #expect(try await a.notHere().isEmpty)
        #expect(try await CloudFolderFixture.journal(a).count == before)
    }
    @Test func explicitIntentAndBinAreDurableBeforeTheFileGoes() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "note.md", "one"); try await f.settle(a)
        let who = actor(f)
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: who)
        #expect(f.text("a", "note.md") == nil)
        #expect(try await a.bin().first?.keptUntil == f.clock.ms + CloudBinGroup.retentionMilliseconds)
        #expect(try await a.pendingDeleteIntent("note.md") == nil)
        let groups = try await a.binGroups()
        #expect(groups.first?.id == who.group)
        #expect(try await a.putBackGroup(who.group).count == 1)
        #expect(f.text("a", "note.md") == "one")
    }
    @Test func migrationMarksOldGoneKeepsHeldAndPreservesOldBinGroups() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "gone.md", "gone"); try f.write("a", "held.md", "keep this"); try f.write("a", "stay.md", "s")
        try await f.settle(a)
        try f.remove("a", "gone.md")
        try await seedMigration(a, at: f.clock.ms)
        try await a.look()
        #expect(f.text("a", "held.md") == "keep this")
        #expect(try await a.notHere().map(\.item.id) == ["gone.md"])
        #expect(try await a.control("deleteRuleMigrated") == "1")
        #expect(try await a.hasLegacyHeldTable() == false)
        #expect(try await a.binGroups().first?.era == .beforeNewRule)
        let before = try await CloudFolderFixture.journal(a).count
        try await a.look()
        #expect(try await CloudFolderFixture.journal(a).count == before)
    }
    @Test func sidecarSurvivesAPackBoundaryAndMalformedNewFieldsAreRefused() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.setDeleteRuleGate { true }
        try f.write("a", "note.md", "one"); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        _ = try await a.deleteItems([item("note.md")], scope: .cloud, by: actor(f))
        let engine = try await a.core()
        var raw: [CloudOperation] = []
        while let change = try await engine.localChange(after: cursor) { raw.append(change.operation); cursor = change.cursor }
        let expanded = try await a.travelOperations(raw)
        #expect(expanded.count == 2)
        for operation in expanded {
            let prepared = try await b.validateIncomingForTest([operation])
            let receipt = try await b.applyPrepared(prepared, origin: .init(deviceId: f.deviceA, sequence: .init(2)))
            #expect(try await b.verify(receipt).verified)
        }
        #expect(f.text("b", "note.md") == "one")
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
        let about = try #require(expanded.first)
        var fields = try CloudFileDeleteRecords.read(about).fields
        fields[CloudDeleteTravel.scope] = "wrong"
        #expect(throws: CloudDeleteRuleError.invalidTravelFields) { _ = try CloudDeleteTravel.read(fields, place: "note.md", mac: f.deviceA, at: f.clock.ms) }
    }
    private func seedMigration(_ owner: BackendCloudFolder, at: Int64) async throws { try await owner.seedLegacyDeleteState(at: at) }
}

// Actor-isolated fixture setup avoids passing SQLite connections out of their owner under Swift 6.
extension BackendCloudFolder {
    func seedLegacyDeleteState(at: Int64) async throws {
        try setControl("deleteRuleMigrated", nil)
        try setControl("deleteMigrationSafety", nil)
        try state().exec("CREATE TABLE IF NOT EXISTS folder_held(path TEXT PRIMARY KEY,version TEXT,parents TEXT,created_at INTEGER,device TEXT,at INTEGER);")
        try state().run("INSERT OR REPLACE INTO folder_gone(path,since) VALUES ('gone.md',?)", [.int(at - 4_000)])
        try state().run("INSERT OR REPLACE INTO folder_held VALUES ('held.md',?,'[]',?,?,?)",
                       [.text(UUID().uuidString), .int(at), .text(deviceId), .int(at)])
        try keeper().binPut(kind: profile.keeperKind, itemKey: itemKey("old.md"), name: "old.md", place: nil, path: "old.md",
            removedAt: at - 10_000, device: deviceId, content: Data("old".utf8), shown: true, now: at - 10_000)
    }
    func hasLegacyHeldTable() throws -> Bool { try state().first("SELECT 1 FROM sqlite_master WHERE type='table' AND name='folder_held'") != nil }
    func pendingDeleteIntent(_ path: String) throws -> CloudDeleteIntent? { try deleteState().intent(at: path) }
    func validateIncomingForTest(_ operations: [CloudOperation]) async throws -> CloudPreparedImport { try await validateIncoming(operations, files: []) }
}

struct CloudArtifactsDeleteRuleTests {
    func item(_ path: String) -> CloudDeleteItem { .init(id: path, kind: CloudFileKind.artifacts.keeperKind, name: (path as NSString).lastPathComponent, place: path) }
    @Test func deletingFromTheProjectOrAgingOutNeverInfersARemoval() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try await a.feed([try f.make("a", "one.md", "one")]); try await f.settle(a)
        let before = try await CloudArtifactsFixture.journal(a).count
        try FileManager.default.removeItem(at: f.project("a").appendingPathComponent("one.md"))
        f.clock.advance(40 * CloudFolderFormat.day); _ = try await a.feed([]); try await f.settle(a)
        #expect(try await a.items().count == 1)
        #expect(try await CloudArtifactsFixture.journal(a).count == before)
    }
    @Test func byHandInsideTheStoreIsAMarkAndFeedNeverRecreatesIt() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try await a.feed([try f.make("a", "stay.md", "stays"), try f.make("a", "gone.md", "gone")]); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        try FileManager.default.removeItem(at: f.store("a").appendingPathComponent("site/gone.md"))
        try await f.settle(a)
        #expect(try await a.notHere().map(\.item.id) == ["site/gone.md"])
        #expect(try await f.send(a, device: f.deviceA, to: b, cursor: &cursor).isEmpty)
        #expect(try await b.items().count == 2)
        f.clock.advance(120_000)
        _ = try await a.feed([try f.make("a", "gone.md", "edited project copy")])
        #expect(!(try await a.items()).contains { $0.path == "site/gone.md" })
        #expect(try await a.bin().isEmpty)
    }
    @Test func deleteFromListIsEverywhereAndGroupsTheDescriptionWithItsArtifact() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.owner.setDeleteRuleGate { true }
        try await a.feed([try f.make("a", "one.md", "one")]); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(try await a.remove(path: "site/one.md"))
        let operations = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(operations.filter { $0.kind == .archive }.count == 2)
        #expect(try await b.items().isEmpty)
        #expect(try await b.binGroups().first?.count == 1)
        let descriptions = operations.filter(CloudFileDeleteRecords.isAbout)
        let groups = try descriptions.map { try CloudFileDeleteRecords.read($0).fields[CloudDeleteTravel.group] }
        #expect(Set(groups).count == 1)
        #expect(FileManager.default.fileExists(atPath: f.project("a").appendingPathComponent("one.md").path))
    }
    @Test func cloudScopePreservesBothStoresIncludingDescriptionsAndExplicitlyRejoins() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.owner.setDeleteRuleGate { true }; await b.owner.setDeleteRuleGate { true }
        try await a.feed([try f.make("a", "one.md", "one")]); try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        let actor = CloudDeleteActor(by: .ai, mac: f.deviceA, macName: "Mac mini", session: "Explicit cloud scope", at: f.clock.ms, group: UUID().uuidString)
        _ = try await a.deleteItems([item("site/one.md")], scope: .cloud, by: actor)
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(try await a.items().count == 1)
        #expect(try await b.items().count == 1)
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
        _ = try await b.bringBack([item("site/one.md")], to: .cloud)
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        #expect(try await a.notHere().isEmpty)
        #expect(try await b.notHere().isEmpty)
        #expect(try await a.items().first?.name == "one.md")
    }
    @Test func aWitnessedStoreRemovalTravelsAsAIWithoutTouchingItsProjectOriginal() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.owner.setDeleteRuleGate { true }
        try await a.feed([try f.make("a", "stay.md", "stays"), try f.make("a", "gone.md", "gone")]); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        let slot = CloudDeleteWitnessSlot(), group = UUID().uuidString
        #expect(slot.installOnce(FilesRuleWitness(.ai(session: "Night", agent: "Reviewer", command: Date(), group: group))))
        await a.owner.setDeleteWitness(slot)
        try FileManager.default.removeItem(at: f.store("a").appendingPathComponent("site/gone.md"))
        try await f.settle(a)
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(!(try await b.items()).contains { $0.path == "site/gone.md" })
        #expect(try await b.binGroups().first?.by == .ai)
        #expect(FileManager.default.fileExists(atPath: f.project("a").appendingPathComponent("gone.md").path))
    }
    @Test func theArtifactProfileRunsTheSameOnceOnlyMigrationWithoutDeletingFiles() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try await a.feed([try f.make("a", "held.md", "keep"), try f.make("a", "stay.md", "stay")]); try await f.settle(a)
        try await a.owner.seedArtifactLegacyState(at: f.clock.ms)
        try await a.owner.look()
        #expect(try await a.owner.control("deleteRuleMigrated") == "1")
        #expect(try await a.owner.hasLegacyHeldTable() == false)
        #expect(try await a.items().count == 2)
        #expect(try await a.notHere().map(\.item.id) == ["site/gone.md"])
        #expect(try await a.owner.control("safetyCopy") != nil)
    }
}

extension BackendCloudFolder {
    func seedArtifactLegacyState(at: Int64) throws {
        try setControl("deleteRuleMigrated", nil)
        try setControl("deleteMigrationSafety", nil)
        try state().exec("CREATE TABLE IF NOT EXISTS folder_held(path TEXT PRIMARY KEY,version TEXT,parents TEXT,created_at INTEGER,device TEXT,at INTEGER);")
        try state().run("INSERT OR REPLACE INTO folder_gone(path,since) VALUES ('site/gone.md',?)", [.int(at - 4_000)])
        try state().run("INSERT OR REPLACE INTO folder_held VALUES ('site/held.md',?,'[]',?,?,?)",
                       [.text(UUID().uuidString), .int(at), .text(deviceId), .int(at)])
    }
}

extension CloudFolderDeleteRuleTests {
    @Test func cloudScopePreservesDifferentUnsentEditsOnBothDevices() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.setDeleteRuleGate { true }
        try f.write("a", "note.md", "Cloud bytes"); try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        try f.write("a", "note.md", "A's unsent bytes")
        try f.write("b", "note.md", "B's unsent bytes")
        _ = try await a.deleteItems([item("note.md")], scope: .cloud, by: actor(f))
        let records = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(records.filter { $0.kind == .put && !CloudFileDeleteRecords.isAbout($0) }.isEmpty)
        #expect(f.text("a", "note.md") == "A's unsent bytes")
        #expect(f.text("b", "note.md") == "B's unsent bytes")
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
        #expect(try await CloudFolderFixture.journal(b).isEmpty)
    }
    @Test func modernMetadataLeavesTheRemovalReadableByTheInstalledDecoder() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        await a.setDeleteRuleGate { true }
        try f.write("a", "note.md", "one"); try await f.settle(a)
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        let raw = try await CloudFolderFixture.journal(a).filter { $0.kind == .archive }
        let records = try await a.travelOperations(raw)
        let marker = try #require(records.last)
        _ = try CloudWire.decode(CloudBrainFilesArchiveMarker.self, from: try CloudWire.canonical(marker.payload),
                                allowedKeys: BackendCloudBrainFiles.markerKeys, maximumBytes: 65_536)
        #expect(records.first?.source.recordId.hasPrefix("about/") == true)
    }
    @Test func aPutAndRemovalInOnePackVerifyAgainstTheKeeper() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await a.setDeleteRuleGate { true }
        try f.write("a", "note.md", "one"); try await f.settle(a)
        _ = try await a.deleteItems([item("note.md")], scope: .everywhere, by: actor(f))
        let raw = try await CloudFolderFixture.journalForTest(a)
        let records = try await a.travelOperations(raw)
        let prepared = try await b.validateIncoming(records, files: [])
        let receipt = try await b.applyPrepared(prepared, origin: .init(deviceId: f.deviceA, sequence: .init(1)))
        #expect(try await b.verify(receipt).verified)
        #expect(f.text("b", "note.md") == nil)
        #expect(try await b.bin().count == 1)
    }
}

extension CloudFolderFixture {
    static func journalForTest(_ owner: BackendCloudFolder) async throws -> [CloudOperation] { try await journal(owner) }
}

extension CloudFolderDeleteRuleTests {
    /// Review 15 Nov (MUST 8): the proof that he pressed Remove on the old build is `folder_confirmed`, exactly what the
    /// old build's storeRemove wrote (it unlinked the file and the next look would have sent it). A Bin entry alone is
    /// not proof: an earlier removal's leftover Bin row at a path now gone by hand stays a local mark.
    @Test func migrationSendsOnlyAnOldRemovePressedOnTheOldBuild() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "stay.md", "stay"); try f.write("a", "intended.md", "intended"); try f.write("a", "byhand.md", "by hand")
        try await f.settle(a)
        try f.remove("a", "intended.md"); try f.remove("a", "byhand.md")
        try await a.seedOldRemovePress(at: f.clock.ms)
        try await a.look()
        let archives = try await CloudFolderFixture.journal(a).filter { $0.kind == .archive }
        #expect(archives.count == 1)
        #expect(archives.first?.source.recordId.hasSuffix("intended.md") == true)
        #expect(try await a.notHere().map(\.item.id) == ["byhand.md"])
        #expect(try await a.bin().contains { $0.path == "intended.md" })
        #expect(f.text("a", "stay.md") == "stay")
    }
    @Test func migrationDoesNothingUntilItsSafetyCopySucceeds() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "gone.md", "gone"); try f.write("a", "held.md", "held"); try f.write("a", "stay.md", "stay")
        try await f.settle(a)
        try await a.seedLegacyDeleteState(at: f.clock.ms)
        try await a.blockMigrationSafety()
        let before = try await CloudFolderFixture.journal(a).count
        // Review 15 Nov (MUST 2): a migration that cannot run yet never stops the look; it is tried at the next one.
        try await a.look()
        #expect(try await a.hasLegacyHeldTable())
        #expect(try await a.control("deleteRuleMigrated") == nil)
        #expect(f.text("a", "held.md") == "held")
        #expect(try await CloudFolderFixture.journal(a).count == before)
    }
}

extension BackendCloudFolder {
    /// The old build's state after his Remove press on "intended.md" (folder_confirmed + folder_gone, file unlinked,
    /// folder_base and the copy unchanged) and a by-hand absence of "byhand.md" that has a leftover Bin row from an
    /// earlier removal at the same path (the old build never wrote a Bin row at press time).
    func seedOldRemovePress(at: Int64) throws {
        try setControl("deleteRuleMigrated", nil); try setControl("deleteMigrationSafety", nil)
        try state().exec("CREATE TABLE IF NOT EXISTS folder_confirmed(path TEXT PRIMARY KEY);")
        try state().run("INSERT OR REPLACE INTO folder_confirmed(path) VALUES ('intended.md')")
        try state().run("INSERT OR REPLACE INTO folder_gone(path,since) VALUES ('intended.md',?)", [.int(at - 4_000)])
        try state().run("INSERT OR REPLACE INTO folder_gone(path,since) VALUES ('byhand.md',?)", [.int(at - 4_000)])
        try keeper().binPut(kind: profile.keeperKind, itemKey: itemKey("byhand.md"), name: "byhand.md", place: nil,
            path: "byhand.md", removedAt: at - 86_400_000, device: deviceId, content: Data("by hand".utf8), shown: true, now: at - 86_400_000)
    }
    func blockMigrationSafety() throws {
        let safety = stateRoot.appendingPathComponent("safety")
        try FileManager.default.moveItem(at: safety, to: stateRoot.appendingPathComponent("earlier-safety"))
        try Data("scratch obstruction".utf8).write(to: safety)
    }
}
