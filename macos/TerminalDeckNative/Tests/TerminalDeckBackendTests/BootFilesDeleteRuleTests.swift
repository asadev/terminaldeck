import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct BootDeleteFixture {
    let files: CloudBootFilesFixture
    let clock = CloudFolderClock()
    init() throws { files = try CloudBootFilesFixture() }
    func close() { files.close() }
    func place(_ mac: String, kind: CloudBootFilesPlaceKind = .project) -> BackendCloudBootFilesPlace {
        kind == .project ? files.project("p", mac + "/app") : files.home(kind, mac + "/app")
    }
    func mac(_ name: String, device: String, kind: CloudBootFilesPlaceKind = .project, announced: Bool = false) async throws -> BackendCloudBootFiles {
        try files.write(name + "/app/README.txt", "ordinary project file, never carried")
        let clock = self.clock
        let made = try BackendCloudBootFiles(deviceId: device, stateRoot: files.url(name + "/cloud/boot-files"), now: { clock.ms })
        await made.setDeleteRuleGate { true }
        await made.setDeleteRuleAnnounced { _ in announced }
        await made.setMacName { _ in "Mac mini" }
        try await made.setPlaces([place(name, kind: kind)])
        return made
    }
    func item(_ relative: String, kind: CloudBootFilesPlaceKind = .project) -> CloudDeleteItem {
        let source = place("a", kind: kind).sourceId
        return .init(id: source + "\n" + relative, kind: "boot", name: (relative as NSString).lastPathComponent)
    }
    func actor(by: CloudDeleteBy = .person) -> CloudDeleteActor {
        .init(by: by, mac: files.deviceA, macName: "Mac mini", session: by == .ai ? "Night work" : nil,
              at: clock.ms, group: UUID().uuidString.lowercased())
    }
    func absentLooks(_ mac: BackendCloudBootFiles) async throws {
        try await mac.refresh(); clock.advance(3_000); try await mac.refresh()
    }
    @discardableResult func send(_ from: BackendCloudBootFiles, to: BackendCloudBootFiles, cursor: inout String?) async throws -> [CloudOperation] {
        let local = try await CloudBootFilesFixture.local(from, after: cursor)
        cursor = local.cursor
        let operations = try await from.travelOperations(local.operations)
        if !operations.isEmpty { try await CloudBootFilesFixture.apply(to, operations, device: files.deviceA) }
        return operations
    }
    func witness(_ answer: CloudDeleteWitnessAnswer, on mac: BackendCloudBootFiles) async -> FilesRuleWitness {
        let witness = FilesRuleWitness(answer), slot = CloudDeleteWitnessSlot()
        #expect(slot.installOnce(witness)); await mac.setDeleteWitness(slot)
        return witness
    }
}

struct BootFilesDeleteRuleTests {
    @Test func byHandIsAMarkAfterTwoLooksThreeSecondsApartAndNeverSent() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA)
        let first = try await CloudBootFilesFixture.local(a)
        let witness = await f.witness(.notAI, on: a)
        try FileManager.default.removeItem(at: f.files.url("a/app/CLAUDE.md"))
        try await a.refresh()
        #expect(await witness.paths.isEmpty)
        f.clock.advance(2_999); try await a.refresh()
        #expect(await witness.paths.isEmpty)
        f.clock.advance(1); try await a.refresh()
        #expect(await witness.paths.count == 1)
        #expect(try await a.notHere().first?.mark == .notOnThisMac)
        #expect(try await CloudBootFilesFixture.local(a, after: first.cursor).operations.isEmpty)
        #expect(try await a.binGroups().isEmpty)
        try await a.refresh()
        #expect(await witness.paths.count == 1)
    }
    @Test func hundredsOfInstructionFilesGoneByHandHaveNoLimitOrQuestion() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        for n in 0..<160 { try f.files.write("a/app/.claude/commands/c\(n).md", "command \(n)") }
        let a = try await f.mac("a", device: f.files.deviceA)
        let before = try await CloudBootFilesFixture.local(a)
        _ = await f.witness(.cannotKnow, on: a)
        for n in 0..<160 { try FileManager.default.removeItem(at: f.files.url("a/app/.claude/commands/c\(n).md")) }
        try await f.absentLooks(a)
        #expect(try await a.notHere().count == 160)
        #expect(try await CloudBootFilesFixture.local(a, after: before.cursor).operations.isEmpty)
        #expect(try await a.binGroups().isEmpty)
    }
    @Test func witnessedAIRemovalTravelsAndAppliesIntoTheKeeperBootBin() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        try f.files.write("a/app/AGENTS.md", "other rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        var cursor: String?
        try await f.send(a, to: b, cursor: &cursor)
        let group = UUID().uuidString.lowercased()
        _ = await f.witness(.ai(session: "Night work", agent: "Reviewer", command: Date(), group: group), on: a)
        for name in ["CLAUDE.md", "AGENTS.md"] { try FileManager.default.removeItem(at: f.files.url("a/app/" + name)) }
        try await f.absentLooks(a)
        let operations = try await f.send(a, to: b, cursor: &cursor)
        #expect(operations.filter { $0.kind == .archive }.count == 2)
        #expect(f.files.text("b/app/CLAUDE.md") == nil && f.files.text("b/app/AGENTS.md") == nil)
        let bin = try #require(try await b.binGroups().first)
        #expect(bin.id == group && bin.by == .ai && bin.agent == "Reviewer" && bin.count == 2)
        #expect(bin.items.allSatisfy { $0.kind == "boot" })
        #expect(try await b.putBackGroup(group).count == 2)
        #expect(f.files.text("b/app/CLAUDE.md") == "rules")
    }
    @Test func aMissingProjectRootNeverCallsTheWitnessOrRemovesItsPrivateCopies() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA)
        let first = try await CloudBootFilesFixture.local(a)
        let witness = await f.witness(.ai(session: "Night", agent: nil, command: Date(), group: UUID().uuidString), on: a)
        try FileManager.default.removeItem(at: f.files.url("a/app")); try await f.absentLooks(a)
        #expect(await witness.paths.isEmpty)
        #expect(try await a.notHere().isEmpty)
        #expect(try await CloudBootFilesFixture.local(a, after: first.cursor).operations.isEmpty)
    }
    @Test func anEmptyProjectRootIsNotADelete() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA)
        let first = try await CloudBootFilesFixture.local(a)
        try FileManager.default.removeItem(at: f.files.url("a/app")); try f.files.folder("a/app")
        try await f.absentLooks(a)
        #expect(try await a.notHere().isEmpty)
        #expect(try await CloudBootFilesFixture.local(a, after: first.cursor).operations.isEmpty)
    }
    @Test func aMissingAIHomeIsNotADeleteAndAnUnmanagedFileNeverTravels() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/AGENTS.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA, kind: .codex)
        let first = try await CloudBootFilesFixture.local(a)
        try FileManager.default.removeItem(at: f.files.url("a/app")); try await f.absentLooks(a)
        #expect(try await a.notHere().isEmpty)
        #expect(try await CloudBootFilesFixture.local(a, after: first.cursor).operations.isEmpty)
        #expect(!first.operations.contains { $0.source.recordId.hasSuffix("README.txt") })
    }
    @Test func cloudScopeKeepsBothFilesAndOnlyExplicitPutInCloudAgainSendsBytes() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        var fromA: String?, fromB: String?
        try await f.send(a, to: b, cursor: &fromA)
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .cloud, by: f.actor())
        try await f.send(a, to: b, cursor: &fromA)
        #expect(f.files.text("a/app/CLAUDE.md") == "rules" && f.files.text("b/app/CLAUDE.md") == "rules")
        #expect(try await a.notHere().first?.mark == .onlyOnThisMac)
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
        let before = try await CloudBootFilesFixture.local(b)
        try f.files.write("b/app/CLAUDE.md", "B's local rules"); try await b.refresh()
        #expect(try await CloudBootFilesFixture.local(b, after: before.cursor).operations.isEmpty)
        _ = try await b.bringBack([f.item("CLAUDE.md")], to: .cloud)
        // B is the verified sender for this half of the exchange.
        let changed = try await CloudBootFilesFixture.local(b, after: fromB)
        fromB = changed.cursor
        let operations = try await b.travelOperationsForTest(changed.operations)
        try await CloudBootFilesFixture.apply(a, operations, device: f.files.deviceB)
        #expect(f.files.text("a/app/CLAUDE.md") == "B's local rules")
        #expect(try await a.notHere().isEmpty)
        #expect(try await b.notHere().isEmpty)
    }
    @Test func anEditWinsAgainstAnArrivingRemovalRegardlessOfDates() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        var cursor: String?
        try await f.send(a, to: b, cursor: &cursor)
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor())
        try f.files.write("b/app/CLAUDE.md", "B's unsent edit")
        try await f.send(a, to: b, cursor: &cursor)
        #expect(f.files.text("b/app/CLAUDE.md") == "B's unsent edit")
        #expect(try await b.binGroups().isEmpty)
    }
    @Test func oldFormatRemovalAppliesAsEverywhereWithTheOlderVersionEra() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        await a.setDeleteRuleGate { false }
        var cursor: String?
        try await f.send(a, to: b, cursor: &cursor)
        await #expect(throws: (any Error).self) { _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .cloud, by: f.actor()) }
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor(by: .ai))
        let operations = try await f.send(a, to: b, cursor: &cursor)
        #expect(!operations.contains(where: CloudFileDeleteRecords.isAbout))
        #expect(f.files.text("b/app/CLAUDE.md") == nil)
        #expect(try await b.binGroups().first?.era == .olderVersion)
    }
    @Test func marksSurviveNewVersionsRestartAndSyncAndBringBackUsesTheNewestBytes() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "one")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        var fromA: String?, fromB: String?
        try await f.send(a, to: b, cursor: &fromA)
        try FileManager.default.removeItem(at: f.files.url("b/app/CLAUDE.md")); try await f.absentLooks(b)
        try f.files.write("a/app/CLAUDE.md", "two"); f.clock.advance(120_000); try await a.refresh()
        try await f.send(a, to: b, cursor: &fromA)
        let reopened = try await f.mac("b", device: f.files.deviceB)
        try await reopened.refresh()
        #expect(f.files.text("b/app/CLAUDE.md") == nil)
        #expect(try await reopened.notHere().count == 1)
        _ = try await reopened.bringBack([f.item("CLAUDE.md")], to: .thisMac)
        #expect(f.files.text("b/app/CLAUDE.md") == "two")
        #expect(try await CloudBootFilesFixture.local(reopened, after: fromB).operations.isEmpty)
    }
    @Test func reappearingOwnEarlierVersionUsesNewestWithoutPublishingARollback() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "old A")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        var fromA: String?, fromB: String?
        try await f.send(a, to: b, cursor: &fromA)
        try FileManager.default.removeItem(at: f.files.url("a/app/CLAUDE.md")); try await f.absentLooks(a)
        f.clock.advance(120_000); try f.files.write("b/app/CLAUDE.md", "new B"); try await b.refresh()
        let changed = try await CloudBootFilesFixture.local(b, after: fromB); fromB = changed.cursor
        try await CloudBootFilesFixture.apply(a, changed.operations, device: f.files.deviceB)
        let before = try await CloudBootFilesFixture.local(a)
        try f.files.write("a/app/CLAUDE.md", "old A"); try await a.refresh()
        #expect(f.files.text("a/app/CLAUDE.md") == "new B")
        #expect(try await a.notHere().isEmpty)
        #expect(try await CloudBootFilesFixture.local(a, after: before.cursor).operations.isEmpty)
    }
    @Test func reappearingUnknownBytesPublishOnTopOfNewest() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "one")
        let a = try await f.mac("a", device: f.files.deviceA)
        let before = try await CloudBootFilesFixture.local(a)
        try FileManager.default.removeItem(at: f.files.url("a/app/CLAUDE.md")); try await f.absentLooks(a)
        try f.files.write("a/app/CLAUDE.md", "new personal rules"); try await a.refresh()
        let changed = try await CloudBootFilesFixture.local(a, after: before.cursor)
        #expect(changed.operations.count == 1 && changed.operations.first?.kind == .put)
        #expect(try await a.notHere().isEmpty)
    }
    @Test func arrivingRemovalWaitsOnlyForItsMissingRootAndAppliesWhenItReturns() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        var cursor: String?
        try await f.send(a, to: b, cursor: &cursor)
        try FileManager.default.moveItem(at: f.files.url("b/app"), to: f.files.url("b/unplugged"))
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor())
        try await f.send(a, to: b, cursor: &cursor)
        #expect(try await b.binGroups().isEmpty)
        try FileManager.default.moveItem(at: f.files.url("b/unplugged"), to: f.files.url("b/app"))
        try await b.refresh()
        #expect(f.files.text("b/app/CLAUDE.md") == nil)
        #expect(try await b.binGroups().first?.count == 1)
    }
    @Test func deletingForGoodUsesTheSameKeeperAndDoesNotTouchLiveFiles() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA)
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor())
        try f.files.write("a/app/CLAUDE.md", "another file here")
        try await a.deleteForGood([f.item("CLAUDE.md")])
        #expect(try await a.binGroups().isEmpty)
        #expect(f.files.text("a/app/CLAUDE.md") == "another file here")
    }
}

extension BackendCloudBootFiles {
    func travelOperationsForTest(_ operations: [CloudOperation]) async throws -> [CloudOperation] { try await travelOperations(operations) }
}

extension BootFilesDeleteRuleTests {
    @Test func cloudScopeKeepsDifferentUnsentInstructionBytesOnEveryDevice() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "Cloud rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        var cursor: String?
        try await f.send(a, to: b, cursor: &cursor)
        try f.files.write("a/app/CLAUDE.md", "A's own rules")
        try f.files.write("b/app/CLAUDE.md", "B's own rules")
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .cloud, by: f.actor())
        let records = try await f.send(a, to: b, cursor: &cursor)
        #expect(records.filter { $0.kind == .put && !CloudFileDeleteRecords.isAbout($0) }.isEmpty)
        #expect(f.files.text("a/app/CLAUDE.md") == "A's own rules")
        #expect(f.files.text("b/app/CLAUDE.md") == "B's own rules")
        #expect(try await b.notHere().first?.mark == .onlyOnThisMac)
        #expect(try await CloudBootFilesFixture.local(b).operations.isEmpty)
    }
    @Test func aPutAndRemovalInOnePackVerifyAgainstTheSameBootKeeper() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        try f.files.write("a/app/CLAUDE.md", "rules")
        let a = try await f.mac("a", device: f.files.deviceA), b = try await f.mac("b", device: f.files.deviceB)
        _ = try await a.deleteItems([f.item("CLAUDE.md")], scope: .everywhere, by: f.actor())
        let raw = try await CloudBootFilesFixture.local(a)
        let operations = try await a.travelOperations(raw.operations)
        let receipt = try await CloudBootFilesFixture.apply(b, operations, device: f.files.deviceA)
        #expect(try await b.verify(receipt).verified)
        #expect(f.files.text("b/app/CLAUDE.md") == nil)
        #expect(try await b.binGroups().first?.count == 1)
    }
}

extension BootFilesDeleteRuleTests {
    @Test func oldBinItemsGroupByMacAndDayBeforeTheNewRule() async throws {
        let f = try BootDeleteFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.files.deviceA)
        try await a.seedOldBootBin(sourceId: f.place("a").sourceId, at: f.clock.ms)
        let groups = try await a.binGroups()
        #expect(groups.count == 1 && groups.first?.count == 2)
        #expect(groups.first?.era == .beforeNewRule)
        #expect(groups.first?.title == CloudDeleteWords.beforeNewRule)
    }
}

extension BackendCloudBootFiles {
    func seedOldBootBin(sourceId: String, at: Int64) throws {
        for name in ["CLAUDE.md", "AGENTS.md"] {
            try keeper().binPut(kind: Self.binKind, itemKey: Self.itemKey(sourceId, name), name: name, place: nil,
                path: Self.deletePlace(sourceId, name), removedAt: at, device: deviceId, content: Data(name.utf8), shown: true, now: at)
        }
    }
}
