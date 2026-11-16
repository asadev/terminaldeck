import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane L3 slice 1: the Cloud folder. Two Macs (two owners, each with its own scratch "home" folder and state) and
/// the records passed between them exactly as the sync core passes them (journal -> validateIncoming -> applyPrepared).
/// Every folder lives under the agreed scratch root and is removed at the end. No real home, account or network.
final class CloudFolderClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_900_000_000_000
    var ms: Int64 { lock.withLock { value } }
    func advance(_ by: Int64) { lock.withLock { value += by } }
}

struct CloudFolderFixture {
    let base: URL
    let deviceA = UUID().uuidString.lowercased()
    let deviceB = UUID().uuidString.lowercased()
    let clock = CloudFolderClock()
    init() throws {
        base = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("folder/f-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    func close() { try? FileManager.default.removeItem(at: base) }
    func folder(_ mac: String) -> URL { base.appendingPathComponent(mac + "/home/Terminal Deck Cloud", isDirectory: true) }
    /// `announced`: whether the OTHER Macs announced the delete rule (review 15 Nov, MUST 4). These fixtures default to
    /// "an older build sent it", so a removal without an about-record is the old-format Everywhere, as before.
    func mac(_ name: String, device: String, understands: Bool = true, read: Bool = true, makeFolder: Bool = true,
             freeDisk: Int64 = 500_000_000_000, announced: Bool = false) async throws -> BackendCloudFolder {
        if makeFolder { try FileManager.default.createDirectory(at: folder(name), withIntermediateDirectories: true) }
        let clock = self.clock
        // The disk's free space is given (a test machine's own disk never decides a test).
        let owner = try BackendCloudFolder(deviceId: device, folder: folder(name), stateRoot: base.appendingPathComponent(name + "/data/cloud-folder"),
                                           everyMacUnderstands: { understands }, freeDisk: { freeDisk }, now: { clock.ms })
        await owner.setDeleteRuleAnnounced { _ in announced }
        if read { try await owner.markCloudRead() }
        return owner
    }
    func write(_ mac: String, _ path: String, _ text: String, modified: Int64? = nil) throws {
        let url = folder(mac).appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let at = modified ?? clock.ms
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(at) / 1000)], ofItemAtPath: url.path)
    }
    func text(_ mac: String, _ path: String) -> String? {
        (try? Data(contentsOf: folder(mac).appendingPathComponent(path))).map { String(decoding: $0, as: UTF8.self) }
    }
    func remove(_ mac: String, _ path: String) throws { try FileManager.default.removeItem(at: folder(mac).appendingPathComponent(path)) }
    /// Two looks 4 s apart: a change that stayed still for the quiet time is recorded.
    func settle(_ owner: BackendCloudFolder) async throws {
        try await owner.look()
        clock.advance(4_000)
        try await owner.look()
    }
    /// Everything `from` journaled since `cursor`, as one pack applied on `to`. Returns the operations passed.
    @discardableResult
    func send(_ from: BackendCloudFolder, device: String, to: BackendCloudFolder, cursor: inout String?) async throws -> [CloudOperation] {
        let engine = try await from.core()
        var operations: [CloudOperation] = []
        while let change = try await engine.localChange(after: cursor) { operations.append(change.operation); cursor = change.cursor }
        guard !operations.isEmpty else { return [] }
        operations = try await from.travelOperations(operations)
        let prepared = try await to.validateIncoming(operations, files: [])
        _ = try await to.applyPrepared(prepared, origin: .init(deviceId: device, sequence: .init(UInt64(clock.ms))))
        return operations
    }
    static func journal(_ owner: BackendCloudFolder) async throws -> [CloudOperation] {
        let engine = try await owner.core()
        var cursor: String?, operations: [CloudOperation] = []
        while let change = try await engine.localChange(after: cursor) { operations.append(change.operation); cursor = change.cursor }
        return operations
    }
}

struct CloudFolderTravelTests {
    @Test func aFileTravelsToTheOtherMac() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "Plans/plan.md", "the plan")
        try await f.settle(a)
        var cursor: String?
        let sent = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(sent.allSatisfy { $0.domain == "cloud-folder" })
        #expect(f.text("b", "Plans/plan.md") == "the plan")
        #expect(try await b.counts().files == 1)
        // Nothing echoes back: B's look records nothing of its own for a file that arrived.
        try await f.settle(b)
        #expect(try await CloudFolderFixture.journal(b).isEmpty)
    }

    @Test func theSameNameOnTwoMacsKeepsBothTheNewerIsUsed() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        let t = f.clock.ms
        try f.write("a", "notes.txt", "from A", modified: t - 60_000)
        try f.write("b", "notes.txt", "from B", modified: t - 30_000)
        try await f.settle(a); try await f.settle(b)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        try await f.settle(a); try await f.settle(b)
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("a", "notes.txt") == "from B")
        #expect(f.text("b", "notes.txt") == "from B")
        // The older one is a version he can open, on both Macs.
        let keptA = try await a.versions(path: "notes.txt"), keptB = try await b.versions(path: "notes.txt")
        #expect(!keptA.isEmpty && !keptB.isEmpty)
        if let version = keptA.first, let url = try await a.openable(path: "notes.txt", sha256: version.sha256) {
            #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "from A")
        } else { Issue.record("A's own version is not kept") }
        #expect(!(try await a.replacedLines(names: [:])).isEmpty)
    }

    @Test func aDeleteGoesToBothBinsAndComesBackWithPutBack() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "keep.md", "stays"); try f.write("a", "gone.md", "goes")
        try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("b", "gone.md") == "goes")
        try await a.storeRemove("gone.md", expecting: BackendCloudBrainMemoryHash.bytes(Data("goes".utf8)))
        try await f.settle(a)
        #expect(try await a.bin().map(\.path) == ["gone.md"])
        let removal = try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(removal.contains { $0.kind == .archive })
        #expect(f.text("b", "gone.md") == nil)
        #expect(f.text("b", "keep.md") == "stays")
        #expect(try await b.bin().map(\.path) == ["gone.md"])
        // Put back on B: it comes back on A too, and leaves both Bins.
        #expect(try await b.putBack(path: "gone.md"))
        try await f.settle(b)
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        #expect(f.text("a", "gone.md") == "goes")
        #expect(try await a.bin().isEmpty)
        #expect(try await b.bin().isEmpty)
    }

    @Test func anEditBeatsARemoval() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "keep.md", "k"); try f.write("a", "doc.md", "v1")
        try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try await a.storeRemove("doc.md", expecting: BackendCloudBrainMemoryHash.bytes(Data("v1".utf8))); try await f.settle(a)
        f.clock.advance(1_000)
        try f.write("b", "doc.md", "v2 edited on B"); try await f.settle(b)
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("b", "doc.md") == "v2 edited on B")
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        #expect(f.text("a", "doc.md") == "v2 edited on B")
    }
}

struct CloudFolderSafetyTests {
    @Test func anEmptiedFolderSendsNothingAndOffersMakeItAgain() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        for name in ["1.md", "2.md", "3.md"] { try f.write("a", name, name) }
        try await f.settle(a)
        let before = try await CloudFolderFixture.journal(a).count
        for name in ["1.md", "2.md", "3.md"] { try f.remove("a", name) }
        try await f.settle(a)
        #expect(try await CloudFolderFixture.journal(a).count == before)
        #expect(try await a.notHere().isEmpty)
        #expect(try await a.waitingAnswer()?.folderMissing == true)
        #expect(f.text("a", "2.md") == nil)
        try await a.makeFolderAgain()
        #expect(f.text("a", "2.md") == "2.md")
        #expect(try await CloudFolderFixture.journal(a).count == before)
    }

    @Test func aMissingFolderSendsNothing() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "x.md", "x"); try await f.settle(a)
        let before = try await CloudFolderFixture.journal(a).count
        try FileManager.default.removeItem(at: f.folder("a"))
        try await f.settle(a); f.clock.advance(4_000); try await a.look()
        #expect(try await CloudFolderFixture.journal(a).count == before)
        #expect(try await a.waitingAnswer()?.folderMissing == true)
    }

    @Test func aLargeExplicitRemovalAppliesWithoutHolding() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        for index in 0..<30 { try f.write("a", "f\(index).md", "file \(index)") }
        try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        let items = (0..<12).map { CloudDeleteItem(id: "f\($0).md", kind: BackendCloudFolder.kind, name: "f\($0).md") }
        let actor = CloudDeleteActor(by: .person, mac: f.deviceA, macName: "Mac mini", at: f.clock.ms, group: UUID().uuidString)
        _ = try await a.deleteItems(items, scope: .everywhere, by: actor)
        let sent = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(sent.filter { $0.kind == .archive }.count == 12)
        #expect(try await b.waitingAnswer() == nil)
        #expect(try await b.bin().count == 12)
        #expect((0..<12).allSatisfy { f.text("b", "f\($0).md") == nil })
    }

    @Test func aFreshMacSendsNothingBeforeItHasReadTheCloud() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let b = try await f.mac("b", device: f.deviceB, read: false)
        try f.write("b", "mine.md", "local")
        try await f.settle(b)
        #expect(try await CloudFolderFixture.journal(b).isEmpty)
        try await b.markCloudRead()
        try await f.settle(b)
        #expect(!(try await CloudFolderFixture.journal(b)).isEmpty)
    }

    @Test func aLinkASecretAndPackagesNeverLeave() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        let outside = f.base.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.folder("a").appendingPathComponent("link.txt"), withDestinationURL: outside)
        for path in [".env", "id_rsa", "api_token.txt", "server.pem", ".hidden/x.md", "node_modules/m/index.js", "DerivedData/a.o", "draft.md~", "ok.md"] {
            try f.write("a", path, "x")
        }
        // A file above the limit (sparse: no real 26 MB written).
        let big = f.folder("a").appendingPathComponent("big.bin")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: 26_000_000); try handle.close()
        try await f.settle(a)
        let keys = Set(try await CloudFolderFixture.journal(a).map(\.source.recordId))
        #expect(keys == ["file/folder/ok.md"])
        let coverage = try await a.coverage()
        #expect(coverage.first?.exclusions.contains(CloudFolderFormat.tooLargeLine(1)) == true)
        // Review 14 Nov (point 8): the files kept back by the never-send list are NAMED on the page.
        let lines = try await a.pageLines()
        #expect(lines.contains(CloudFolderFormat.secretLine(["api_token.txt", "id_rsa", "server.pem"])))
    }

    @Test func anArrivingSecretIsRefusedBeforeAByteIsKept() async throws {
        #expect(CloudFolderRules.refusal(".env") != nil)
        #expect(CloudFolderRules.refusal("keys/credentials.json") != nil)
        #expect(CloudFolderRules.refusal("../x") != nil)
        #expect(CloudFolderRules.refusal("Plans/plan.md") == nil)
    }
}

struct CloudFolderCostTests {
    @Test func anAIRewritingAFileEverySecondIsSentOncePerWindow() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        // 60 rewrites, one a second, with a look after each: never still for 3 s, so nothing is sent meanwhile.
        for second in 0..<60 {
            try f.write("a", "live.md", "version \(second)")
            try await a.look()
            f.clock.advance(1_000)
        }
        #expect(try await CloudFolderFixture.journal(a).isEmpty)
        f.clock.advance(4_000); try await a.look()
        #expect(try await CloudFolderFixture.journal(a).count == 1)
        // It keeps changing after that: at most one more within the next minute.
        for second in 0..<50 {
            try f.write("a", "live.md", "again \(second)", modified: f.clock.ms)
            f.clock.advance(1_000)
            if second % 5 == 4 { f.clock.advance(4_000); try await a.look() }
        }
        #expect(try await CloudFolderFixture.journal(a).count <= 2)
    }

    @Test func deletionRetentionIsThirtyDays() {
        #expect(CloudBinGroup.retentionMilliseconds == 30 * 86_400_000)
        #expect(CloudFolderFormat.quiet == 3_000)
    }
}

/// An older build next to this one: it never announced that it understands Cloud folder records, so this Mac sends
/// none (the gate), and the kind is a domain of its own that an older build keeps waiting, never misreads as memory.
struct CloudFolderOlderBuildTests {
    @Test func withAMacThatDoesNotUnderstandNothingIsSent() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA, understands: false)
        await a.setWhoWaits { ["MacBook Pro"] }
        try f.write("a", "x.md", "x")
        try await f.settle(a)
        #expect(try await CloudFolderFixture.journal(a).isEmpty)
        // Review 14 Nov (point 8): one line names the Mac that keeps it closed.
        #expect(try await a.pageLines().contains(CloudFolderFormat.gateLine(["MacBook Pro"])))
    }
    @Test func anAnnouncementCountsOnlyWhileFreshAndOfThisFormat() {
        let now: Int64 = 1_900_000_000_000
        #expect(DeckMemoryStore.featureFresh("v1:\(now - 1_000)", format: 1, now: now))
        #expect(!DeckMemoryStore.featureFresh("v1:\(now - 4 * 86_400_000)", format: 1, now: now))
        #expect(!DeckMemoryStore.featureFresh("1", format: 1, now: now))
        #expect(!DeckMemoryStore.featureFresh(nil, format: 1, now: now))
        #expect(DeckMemoryStore.featureKey("cloudfolder", device: "ABC") == "onerule.understands.cloudfolder.abc")
    }
    @Test func theKindHasItsOwnDomain() {
        #expect(CloudFolderFormat.domain == "cloud-folder")
        #expect(!CloudBrainFilesFormat.inventoryRows.map(CloudBrainFilesFormat.domain).contains(CloudFolderFormat.domain))
        #expect(BackendCloudContentsBuilder.kindOf(domain: CloudFolderFormat.domain) == .cloudFolder)
    }
}

/// Review 14 Nov (MERGE AFTER FIXES): the five fixes and the smaller ones, each on two scratch Macs.
struct CloudFolderReviewFixTests {
    /// Point 1: B's "Linked" is a link to a folder outside. A file arriving under it writes NOTHING outside the folder.
    @Test func anArrivalUnderALinkedFolderWritesNothingOutside() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        let outside = f.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.folder("b").appendingPathComponent("Linked"), withDestinationURL: outside)
        try f.write("a", "Linked/new.md", "should never land outside")
        try f.write("a", "Linked/Deeper/also.md", "nor this")
        try await f.settle(a)
        var fromA: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try await f.settle(b)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        // The disk helper itself: no write, no folder made, no removal through a link on the way.
        #expect(throws: (any Error).self) { try CloudFolderDisk.write(f.folder("b"), "Linked/x.md", bytes: Data("x".utf8), expecting: nil) }
        #expect(CloudFolderDisk.read(f.folder("b"), "Linked/x.md") == .blocked)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    /// Separate incoming packs use the same exact-version rule, with no per-window removal limit.
    @Test func removalsInSeparatePacksApplyWithoutAQuestion() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        for index in 0..<30 { try f.write("a", "f\(index).md", "file \(index)") }
        try await f.settle(a)
        var cursor: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        for index in 0..<13 {
            try await a.storeRemove("f\(index).md", expecting: BackendCloudBrainMemoryHash.bytes(Data("file \(index)".utf8)))
        }
        let engine = try await a.core()
        var operations: [CloudOperation] = []
        while let change = try await engine.localChange(after: cursor) { operations.append(change.operation); cursor = change.cursor }
        for operation in operations {
            _ = try await b.applyPrepared(try await b.validateIncoming([operation], files: []), origin: .init(deviceId: f.deviceA, sequence: .init(2)))
        }
        #expect(try await b.waitingAnswer() == nil)
        #expect(try await b.bin().count == 13)
    }

    /// Point 3: 200 MB a day per Mac. Past it nothing more is recorded (Sync now too) and the page says so.
    @Test func theDailyBudgetHoldsSendsAndSaysItsLine() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "first.md", "first"); try await f.settle(a)
        let before = try await CloudFolderFixture.journal(a).count
        // Today's sends so far: 10 bytes short of the budget.
        try await a.setControl("daySent", String(CloudFolderFormat.dailySendBytes - 10))
        try f.write("a", "second.md", "more than ten bytes"); try await f.settle(a)
        await a.sendNow()
        #expect(try await CloudFolderFixture.journal(a).count == before)
        #expect(try await a.pageLines().contains(CloudFolderFormat.dayFullLine))
        // The next day it goes.
        f.clock.advance(CloudFolderFormat.day); try await f.settle(a)
        #expect(try await CloudFolderFixture.journal(a).count == before + 1)
    }

    /// Point 3: at most 6 versions of one file a day; the 7th waits until the file has been still for an hour.
    @Test func theSeventhVersionOfAFileWaitsForAnHourOfStillness() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        for version in 0..<6 {
            try f.write("a", "busy.md", "version \(version)"); try await f.settle(a)
            f.clock.advance(11 * 60_000)
        }
        #expect(try await CloudFolderFixture.journal(a).count == 6)
        try f.write("a", "busy.md", "version 6"); try await f.settle(a)
        #expect(try await CloudFolderFixture.journal(a).count == 6)
        #expect(try await a.pageLines().contains(CloudFolderFormat.busyLine(1)))
        f.clock.advance(CloudFolderFormat.stillAfterLimit); try await a.look()
        #expect(try await CloudFolderFixture.journal(a).count == 7)
    }

    /// Point 3: below 3 GB of room left in the account the folder sends nothing, and says so.
    @Test func theLifetimeFloorHoldsSendsAndSaysItsLine() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        await a.setRoomLeft { 2_000_000_000 }
        try f.write("a", "x.md", "x"); try await f.settle(a)
        #expect(try await CloudFolderFixture.journal(a).isEmpty)
        #expect(try await a.pageLines().contains(CloudFolderFormat.roomLowLine))
        await a.setRoomLeft { 9_000_000_000 }
        try await a.look()
        #expect(try await CloudFolderFixture.journal(a).count == 1)
        #expect(!(try await a.pageLines()).contains(CloudFolderFormat.roomLowLine))
    }

    /// Point 3: below 2 GB free on this Mac nothing that arrives is kept or written; it waits, with a line.
    @Test func theFreeDiskFloorHoldsArrivalsAndSaysItsLine() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, freeDisk: 1_000_000_000)
        try f.write("a", "x.md", "x"); try await f.settle(a)
        let operations = try await CloudFolderFixture.journal(a)
        await #expect(throws: CloudRecordRefusal.self) { _ = try await b.validateIncoming(operations, files: []) }
        #expect(f.text("b", "x.md") == nil)
        #expect(try await b.pageLines().contains(CloudFolderFormat.diskLowLine))
    }

    /// Point 3: past 1 GB new and changed files stay here (sparse files: nothing real is written).
    @Test func theOneGigabyteCapHoldsSendsAndSaysItsLine() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        for index in 0..<41 {
            let url = f.folder("a").appendingPathComponent("big\(index).bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url); try handle.truncate(atOffset: 25_000_000); try handle.close()
        }
        try f.write("a", "small.md", "small"); try await f.settle(a)
        #expect(try await CloudFolderFixture.journal(a).isEmpty)
        #expect(try await a.pageLines().contains(CloudFolderFormat.folderFullLine))
    }

    /// Point 3: once a file has arrived and is placed, its part bodies are gone from the receiving Mac.
    @Test func partBodiesAreGoneAfterAssembly() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "doc.md", String(repeating: "words ", count: 20_000)); try await f.settle(a)
        var fromA: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("b", "doc.md")?.count == 120_000)
        #expect(try await b.core().storedPartBytes() == 0)
        // The same pack again is still known (and refused nothing): applying it twice changes nothing.
        let engine = try await a.core()
        var operations: [CloudOperation] = [], cursor: String?
        while let change = try await engine.localChange(after: cursor) { operations.append(change.operation); cursor = change.cursor }
        _ = try await b.applyPrepared(try await b.validateIncoming(operations, files: []), origin: .init(deviceId: f.deviceA, sequence: .init(9)))
        #expect(f.text("b", "doc.md")?.count == 120_000)
    }

    /// Delete rule (section F): a removed Cloud folder file is in the ONE Bin's groups (name, which Mac, when), never a
    /// row of its own under "Cloud folder" any more; the folder's "newer one is in use" lines stay where they are, with
    /// the file they open. Put back all brings the file back.
    @Test func theBinRowsAndTheReplacedLinesAreOnThePage() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: BackendCloudContentsFixture.mac)
        try f.write("a", "keep.md", "k"); try f.write("a", "gone.md", "goes"); try await f.settle(a)
        try await a.storeRemove("gone.md", expecting: BackendCloudBrainMemoryHash.bytes(Data(f.text("a", "gone.md")!.utf8))); try await f.settle(a)
        // The ONE Bin: one group holding the file, by this Mac's person.
        let groups = try await a.binGroups()
        let group = try #require(groups.first { $0.items.contains { $0.id == "gone.md" } })
        #expect(groups.count == 1 && group.count == 1 && group.by == .person)
        #expect(group.items.first?.name == "gone.md" && BackendCloudDeletePage.kind(group.items[0]) == .cloudFolder)
        typealias F = BackendCloudContentsFixture
        let now: Int64 = 1_794_100_000_000
        var names = F.names
        names.folderBin = try await a.bin()
        names.folderReplaced = [CloudVersionReplacedLine(device: "MacBook Pro", name: "notes.txt", project: nil, keptUntil: now, itemId: BackendCloudFolder.kind + ":Plans/notes.txt")]
        names.folderLines = [CloudFolderFormat.dayFullLine]
        let built = try #require(BackendCloudContentsBuilder.build(contents: F.contents(now: now), snapshot: F.snapshot(now: now), names: names, now: now))
        // Not a row under "Cloud folder" or memory: the Bin page draws it from the group above (`NativeCloudBinRows`).
        #expect(!built.model.items(.cloudFolder).contains { $0.name == "gone.md" })
        #expect(!built.model.items(.memory).contains { $0.name == "gone.md" })
        // The replaced lines and the folder's own lines stay above its rows.
        #expect(built.model.folderReplaced.map(\.id) == ["Plans/notes.txt"])
        #expect(built.model.folderLines == [CloudFolderFormat.dayFullLine])
        // Put back all (the group's own action) brings the file back and empties the Bin.
        #expect(try await a.putBackGroup(group.id).map(\.id) == ["gone.md"])
        #expect(f.text("a", "gone.md") == "goes")
        #expect(try await a.binGroups().isEmpty)
    }

    /// Each later by-hand disappearance remains device-only, with no answer path.
    @Test func laterByHandRemovalsStayLocalWithoutAnAnswer() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        for index in 0..<30 { try f.write("a", "f\(index).md", "file \(index)") }
        try await f.settle(a)
        let before = try await CloudFolderFixture.journal(a).count
        for index in 0..<12 { try f.remove("a", "f\(index).md") }
        try await f.settle(a)
        try f.remove("a", "f20.md"); try await f.settle(a)
        #expect(try await a.notHere().count == 13)
        #expect(try await a.waitingAnswer() == nil)
        #expect(try await CloudFolderFixture.journal(a).count == before)
    }

    /// Point 9: "Plan.md" on one Mac and "plan.md" on the other: both files stay; the arrival is kept beside under a
    /// plain new name; nothing is replaced and no removal is sent.
    @Test func namesDifferingOnlyByCapitalsKeepBothFiles() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        await b.setMacName { _ in "Mac mini" }
        try f.write("a", "Plan.md", "from A")
        try f.write("b", "plan.md", "from B")
        try await f.settle(a); try await f.settle(b)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try await f.settle(b)
        let names = try FileManager.default.contentsOfDirectory(atPath: f.folder("b").path)
        let caseBlind = !names.contains("Plan.md") || !names.contains("plan.md")
        #expect(f.text("b", "plan.md") == "from B")
        if caseBlind {
            // The disk takes the two names as one: the arrival is beside it, never over it.
            #expect(f.text("b", "Plan (from Mac mini).md") == "from A")
        }
        let sentByB = try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        #expect(!sentByB.contains { $0.kind == .archive })
        #expect(f.text("a", "Plan.md") == "from A")
    }

    /// Point 7: a file still being written while it is read waits (nothing is recorded from a half-written file).
    @Test func aHalfWrittenFileWaits() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "growing.log", "part one")
        try await a.look(); f.clock.advance(4_000)
        let url = f.folder("a").appendingPathComponent("growing.log")
        await a.setAfterReadForTests { _ in
            if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(" and part two".utf8)); try? handle.close() }
        }
        try await a.look()
        #expect(try await CloudFolderFixture.journal(a).isEmpty)
        await a.setAfterReadForTests(nil)
        f.clock.advance(4_000); try await a.look(); f.clock.advance(4_000); try await a.look()
        let sent = try await CloudFolderFixture.journal(a)
        #expect(sent.count == 1)
    }
}

/// The merge with the status line: the Cloud folder is a kind under "Space used" from the one source, and its
/// question keeps the line from saying "Everything is on your other devices".
struct CloudFolderStatusLineTests {
    @Test func aMissingRootHasAQuietLine() {
        let answer = CloudFolderAnswer(folderMissing: true)
        #expect(BackendCloudFolderWords.waitingAnswer(answer, from: nil) == "Your Cloud folder is not on this Mac")
        #expect(BackendCloudFolderWords.makeItAgain == "Make it again")
    }
}

/// Coordinator, 14 Nov: an arrival written by sync is never captured as a local change. Two Macs, ten watcher passes
/// each way with every journal passed on: the uploads stay at what was really made, and no version list grows.
struct CloudFolderNoEchoTests {
    /// Every version a Mac has journaled: one upload of a file's bytes (its first part, at offset 0, counts it once).
    static func versions(_ owner: BackendCloudFolder) async throws -> Int {
        try await CloudFolderFixture.journal(owner).filter { $0.kind == .put && ($0.source.offset ?? 0) == 0 }.count
    }
    func passes(_ f: CloudFolderFixture, _ a: BackendCloudFolder, _ b: BackendCloudFolder, fromA: inout String?, fromB: inout String?) async throws {
        for _ in 0..<10 {
            try await f.settle(a); try await f.settle(b)
            try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
            try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        }
    }

    @Test func aFileSentOnceStaysSentOnce() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "plan.md", "the plan"); try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("b", "plan.md") == "the plan")
        try await passes(f, a, b, fromA: &fromA, fromB: &fromB)
        #expect(try await Self.versions(a) == 1)
        #expect(try await Self.versions(b) == 0)
        #expect(try await a.versions(path: "plan.md").isEmpty)
        #expect(try await b.versions(path: "plan.md").isEmpty)
    }

    /// The same name made apart on both Macs, the arrived one newer on B: B uses it WITHOUT recording it again.
    @Test func theNewerArrivalIsNeverSentBack() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        let t = f.clock.ms
        try f.write("b", "notes.txt", "from B", modified: t - 60_000)
        try f.write("a", "notes.txt", "from A", modified: t - 30_000)
        try await f.settle(a); try await f.settle(b)
        var fromA: String?, fromB: String?
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("a", "notes.txt") == "from A")
        #expect(f.text("b", "notes.txt") == "from A")
        let keptA = try await a.versions(path: "notes.txt").count, keptB = try await b.versions(path: "notes.txt").count
        try await passes(f, a, b, fromA: &fromA, fromB: &fromB)
        // One version made on each device, by him; nothing more travelled, and nothing new was kept.
        #expect(try await Self.versions(a) == 1)
        #expect(try await Self.versions(b) == 1)
        #expect(try await a.versions(path: "notes.txt").count == keptA)
        #expect(try await b.versions(path: "notes.txt").count == keptB)
        #expect(f.text("a", "notes.txt") == "from A" && f.text("b", "notes.txt") == "from A")
    }
}

/// Coordinator, 14 Nov (last change): his own work set aside by sync is never trimmed, and nothing is swept on a Mac
/// clock that the service has not confirmed.
struct CloudFolderHisWorkTests {
    /// B's edit loses to A's newer one (it never left B), then A saves again on top: B's edit is still kept and opens.
    @Test func anEditThatLostIsStillKeptAfterASecondArrival() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try f.write("a", "plan.md", "v1"); try await f.settle(a)
        var fromA: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        f.clock.advance(60_000)
        let t = f.clock.ms
        try f.write("b", "plan.md", "B's edit", modified: t - 30_000)
        try f.write("a", "plan.md", "A's edit", modified: t - 10_000)
        try await f.settle(a)
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("b", "plan.md") == "A's edit")
        f.clock.advance(120_000)
        try f.write("a", "plan.md", "A's second save"); try await f.settle(a)
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(f.text("b", "plan.md") == "A's second save")
        let kept = try await b.versions(path: "plan.md")
        let mine = try #require(kept.first { $0.sha256 == BackendCloudBrainMemoryHash.bytes(Data("B's edit".utf8)) })
        let url = try #require(try await b.openable(path: "plan.md", sha256: mine.sha256))
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "B's edit")
    }

    /// Put back over a different file of the same name: that file is kept (his), and opens.
    @Test func theFilePutBackDisplacesIsKept() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "keep.md", "k"); try f.write("a", "gone.md", "old text"); try await f.settle(a)
        try await a.storeRemove("gone.md", expecting: BackendCloudBrainMemoryHash.bytes(Data(f.text("a", "gone.md")!.utf8))); try await f.settle(a)
        try f.write("a", "gone.md", "new text written meanwhile")
        #expect(try await a.putBack(path: "gone.md"))
        #expect(f.text("a", "gone.md") == "old text")
        let displaced = try #require(try await a.versions(path: "gone.md").first { $0.sha256 == BackendCloudBrainMemoryHash.bytes(Data("new text written meanwhile".utf8)) })
        let url = try #require(try await a.openable(path: "gone.md", sha256: displaced.sha256))
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == "new text written meanwhile")
    }

    /// No service clock (no outbox here): the daily sweep never runs, however far the Mac's clock moves.
    @Test func nothingIsSweptWhileTheServiceClockIsUnknown() async throws {
        let f = try CloudFolderFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try f.write("a", "keep.md", "k"); try f.write("a", "gone.md", "goes"); try await f.settle(a)
        try await a.storeRemove("gone.md", expecting: BackendCloudBrainMemoryHash.bytes(Data(f.text("a", "gone.md")!.utf8))); try await f.settle(a)
        #expect(try await a.bin().count == 1)
        f.clock.advance(40 * CloudFolderFormat.day)
        #expect(try await a.sweepDaily() == false)
        await a.sendNow()
        #expect(try await a.bin().count == 1)
    }
}
