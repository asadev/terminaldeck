import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane L3 slice 2: artifacts that travel. Two Macs (two owners, each with its own scratch project folder, store and
/// state) and the records passed between them exactly as the sync core passes them (journal -> validateIncoming ->
/// applyPrepared), as the Cloud folder's tests do. Everything lives under the agreed scratch root and is removed at the
/// end. No real home, project, account or network.
struct CloudArtifactsFixture {
    let base: URL
    let deviceA = UUID().uuidString.lowercased()
    let deviceB = UUID().uuidString.lowercased()
    let clock = CloudFolderClock()
    init() throws {
        base = CloudBrainMemoryFixture.approvedRoot.appendingPathComponent("artifacts/t-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    func close() { try? FileManager.default.removeItem(at: base) }
    /// The project folder "site" on one Mac (its files are only ever read).
    func project(_ mac: String) -> URL { base.appendingPathComponent(mac + "/projects/site", isDirectory: true) }
    func store(_ mac: String) -> URL { base.appendingPathComponent(mac + "/data/cloud/subject/artifacts-files", isDirectory: true) }
    func mac(_ name: String, device: String, understands: Bool = true, read: Bool = true, freeDisk: Int64 = 500_000_000_000,
             announced: Bool = false) async throws -> BackendCloudArtifacts {
        try FileManager.default.createDirectory(at: project(name), withIntermediateDirectories: true)
        let clock = self.clock
        let made = try BackendCloudArtifacts(deviceId: device, store: store(name), stateRoot: base.appendingPathComponent(name + "/data/cloud/subject/artifacts"),
                                             everyMacUnderstands: { understands }, freeDisk: { freeDisk }, now: { clock.ms })
        try await made.prepareStore()
        await made.owner.setDeleteRuleAnnounced { _ in announced }
        if read { try await made.owner.markCloudRead() }
        return made
    }
    /// An artifact a session made in the project folder.
    @discardableResult
    func make(_ mac: String, _ relPath: String, _ text: String, modified: Int64? = nil) throws -> CloudArtifactEntry {
        let url = project(mac).appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        let at = modified ?? clock.ms - 10_000
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(at) / 1000)], ofItemAtPath: url.path)
        return entry(mac, relPath)
    }
    func entry(_ mac: String, _ relPath: String, project: String = "site") -> CloudArtifactEntry {
        CloudArtifactEntry(projectId: project, projectName: "Site", root: self.project(mac).path, relPath: relPath,
                           name: (relPath as NSString).lastPathComponent, madeBy: "Reviewer", createdAt: clock.ms - 60_000)
    }
    /// Two looks 4 s apart: what stayed still for the quiet time is recorded.
    func settle(_ owner: BackendCloudArtifacts) async throws {
        try await owner.owner.look()
        clock.advance(4_000)
        try await owner.owner.look()
    }
    @discardableResult
    func send(_ from: BackendCloudArtifacts, device: String, to: BackendCloudArtifacts, cursor: inout String?) async throws -> [CloudOperation] {
        let engine = try await from.owner.core()
        var operations: [CloudOperation] = []
        while let change = try await engine.localChange(after: cursor) { operations.append(change.operation); cursor = change.cursor }
        guard !operations.isEmpty else { return [] }
        operations = try await from.owner.travelOperations(operations)
        let prepared = try await to.owner.validateIncoming(operations, files: [])
        _ = try await to.owner.applyPrepared(prepared, origin: .init(deviceId: device, sequence: .init(UInt64(clock.ms))))
        return operations
    }
    static func journal(_ owner: BackendCloudArtifacts) async throws -> [CloudOperation] {
        let engine = try await owner.owner.core()
        var cursor: String?, operations: [CloudOperation] = []
        while let change = try await engine.localChange(after: cursor) { operations.append(change.operation); cursor = change.cursor }
        return operations
    }
    /// Uploads of one file's bytes (its first part counts it once).
    static func uploads(_ owner: BackendCloudArtifacts, _ key: String) async throws -> Int {
        try await journal(owner).filter { $0.kind == .put && $0.source.recordId == key && ($0.source.offset ?? 0) == 0 }.count
    }
}

struct CloudArtifactsTravelTests {
    @Test func anArtifactMadeOnOneMacIsOnTheOtherWithItsNameProjectMakerAndDateAndOpens() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        let page = "<html><head><title>Weekly</title></head><body>report</body></html>"
        let made = try f.make("a", "out/report.html", page)
        try await a.feed([made])
        try await f.settle(a)
        var cursor: String?
        let sent = try await f.send(a, device: f.deviceA, to: b, cursor: &cursor)
        #expect(sent.allSatisfy { $0.domain == "artifacts" })
        let arrived = try #require(try await b.items().first { $0.relPath == "out/report.html" })
        #expect(arrived.name == "report.html")
        #expect(arrived.project == "Site")
        #expect(arrived.projectId == "site")
        #expect(arrived.madeBy == "Reviewer")
        #expect(arrived.device == f.deviceA)
        #expect(arrived.type == "Web page")
        #expect(arrived.createdAt == made.createdAt)
        // It opens: the file is in B's store, exactly the bytes made on A; B's project folder is never written.
        #expect(String(decoding: try Data(contentsOf: arrived.url), as: UTF8.self) == page)
        #expect(arrived.url.path.hasPrefix(f.store("b").path + "/"))
        #expect(!FileManager.default.fileExists(atPath: f.project("b").appendingPathComponent("out/report.html").path))
        #expect(try await b.counts().artifacts == 1)
    }

    /// Never sent back: one upload after ten watcher passes on both Macs, with every journal passed on and B's own feed
    /// running each time (B's list does not hold the artifact; its copy is an arrival).
    @Test func anArrivedArtifactIsNeverSentBack() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        let made = try f.make("a", "notes/summary.md", "# Summary")
        var fromA: String?, fromB: String?
        for _ in 0..<10 {
            try await a.feed([made]); try await b.feed([])
            try await f.settle(a); try await f.settle(b)
            try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
            try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        }
        #expect(try await CloudArtifactsFixture.uploads(a, "file/artifacts/site/notes/summary.md") == 1)
        #expect(try await CloudArtifactsFixture.uploads(b, "file/artifacts/site/notes/summary.md") == 0)
        #expect(try await CloudArtifactsFixture.journal(b).isEmpty)
    }

    /// Both Macs have the project (one folder kept in step by git): a file this Mac never copied before only replaces
    /// a newer arrival when it is newer itself.
    @Test func anOlderCopyOfTheSameProjectNeverReplacesANewerArrival() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        let t = f.clock.ms
        try await a.feed([try f.make("a", "plan.md", "newer from A", modified: t - 1_000)])
        try await f.settle(a)
        var fromA: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try await b.feed([try f.make("b", "plan.md", "older on B", modified: t - 600_000)])
        try await f.settle(b)
        #expect(try await CloudArtifactsFixture.journal(b).isEmpty)
        let item = try #require(try await b.items().first { $0.relPath == "plan.md" })
        #expect(String(decoding: try Data(contentsOf: item.url), as: UTF8.self) == "newer from A")
    }
}

struct CloudArtifactsSafetyTests {
    @Test func aRemovalGoesToBothBinsAndPutBackBringsItBackOnBoth() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try await a.feed([try f.make("a", "keep.html", "<p>stays</p>"), try f.make("a", "gone.html", "<p>goes</p>")])
        try await f.settle(a)
        var fromA: String?, fromB: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(try await b.items().count == 2)
        // His Remove on A's page. His project file stays.
        #expect(try await a.remove(path: "site/gone.html"))
        #expect(FileManager.default.fileExists(atPath: f.project("a").appendingPathComponent("gone.html").path))
        try await f.settle(a)
        #expect(try await a.bin().map(\.path) == ["site/gone.html"])
        let removal = try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(removal.contains { $0.kind == .archive })
        #expect(try await b.items().map(\.relPath) == ["keep.html"])
        #expect(try await b.bin().map(\.path) == ["site/gone.html"])
        // Not copied again on A while his file stays as it is.
        try await a.feed([f.entry("a", "gone.html")])
        #expect(try await a.items().map(\.relPath) == ["keep.html"])
        // Put back on B: back on both, out of both Bins.
        #expect(try await b.putBack(path: "site/gone.html"))
        try await f.settle(b)
        try await f.send(b, device: f.deviceB, to: a, cursor: &fromB)
        #expect(Set(try await a.items().map(\.relPath)) == ["keep.html", "gone.html"])
        #expect(try await a.bin().isEmpty)
        #expect(try await b.bin().isEmpty)
    }

    @Test func anEmptiedStoreStaysAbsentUntilMakeItAgain() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try await a.feed(["1.md", "2.md", "3.md"].map { try! f.make("a", $0, $0) })
        try await f.settle(a)
        let before = try await CloudArtifactsFixture.journal(a).count
        for name in try FileManager.default.contentsOfDirectory(atPath: f.store("a").path) {
            try FileManager.default.removeItem(at: f.store("a").appendingPathComponent(name))
        }
        try await f.settle(a)
        #expect(try await CloudArtifactsFixture.journal(a).count == before)
        #expect(try await a.notHere().isEmpty)
        #expect(try await a.owner.waitingAnswer()?.folderMissing == true)
        #expect(try await a.items().isEmpty)
        try await a.owner.makeFolderAgain()
        #expect(try await a.items().count == 3)
    }

    @Test func aMissingStoreSendsNothing() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try await a.feed([try f.make("a", "x.md", "x")]); try await f.settle(a)
        let before = try await CloudArtifactsFixture.journal(a).count
        try FileManager.default.removeItem(at: f.store("a"))
        try await f.settle(a); f.clock.advance(4_000); try await a.owner.look()
        #expect(try await CloudArtifactsFixture.journal(a).count == before)
        #expect(try await a.owner.waitingAnswer()?.folderMissing == true)
    }

    /// A large explicit group has no sending limit or answer step.
    @Test func aBurstOfExplicitRemovalsNeedsNoAnswer() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try await a.feed((0..<30).map { try! f.make("a", "r\($0).md", "report \($0)") })
        try await f.settle(a)
        for index in 0..<12 { #expect(try await a.remove(path: "site/r\(index).md")) }
        try await f.settle(a)
        #expect(try await a.owner.waitingAnswer() == nil)
        #expect(try await a.bin().count == 12)
        #expect(try await CloudArtifactsFixture.journal(a).filter { $0.kind == .archive }.count == 24)
    }

    /// Review 14 Nov: six artifacts he removed on the page (twelve files with their descriptions; the limit is counted
    /// in artifacts) are sent without a second question here, each into the Bin.
    @Test func removingSixArtifactsSendsThemWithoutASecondQuestion() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try await a.feed((0..<30).map { try! f.make("a", "r\($0).md", "report \($0)") })
        try await f.settle(a)
        for index in 0..<6 { #expect(try await a.remove(path: "site/r\(index).md")) }
        try await f.settle(a)
        #expect(try await a.owner.waitingAnswer() == nil)
        #expect(try await CloudArtifactsFixture.journal(a).filter { $0.kind == .archive }.count == 12)
        #expect(try await a.bin().count == 6)
    }

    /// Every arriving removal applies to its exact parent; artifact descriptions are kept in the same Bin.
    @Test func removalsArriveCountedInArtifacts() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try await a.feed((0..<30).map { try! f.make("a", "r\($0).md", "report \($0)") })
        try await f.settle(a)
        var fromA: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(try await b.items().count == 30)
        for index in 0..<6 { #expect(try await a.remove(path: "site/r\(index).md")) }
        try await f.settle(a)
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(try await b.owner.waitingAnswer() == nil)
        #expect(try await b.items().count == 24)
        #expect(try await b.bin().count == 6)
        // Eleven more go immediately too; there is no sending or applying window.
        f.clock.advance(1_000)
        for index in 6..<17 { #expect(try await a.remove(path: "site/r\(index).md")) }
        try await f.settle(a)
        #expect(try await a.owner.waitingAnswer() == nil)
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        #expect(try await b.owner.waitingAnswer() == nil)
        #expect(try await b.items().count == 13)
        #expect(try await b.bin().count == 17)
    }

    /// Review 14 Nov: removing every artifact on the page (the store is then empty) is his own press: not asked again.
    @Test func removingTheLastArtifactsOnThePageIsNotAskedAgain() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try await a.feed(["1.md", "2.md"].map { try! f.make("a", $0, $0) })
        try await f.settle(a)
        #expect(try await a.remove(path: "site/1.md"))
        #expect(try await a.remove(path: "site/2.md"))
        try await f.settle(a)
        #expect(try await a.owner.waitingAnswer() == nil)
        #expect(try await CloudArtifactsFixture.journal(a).filter { $0.kind == .archive }.count == 4)
    }

    @Test func aFreshMacCopiesAndSendsNothingBeforeItHasReadTheCloud() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let b = try await f.mac("b", device: f.deviceB, read: false)
        #expect(try await b.feed([try f.make("b", "mine.md", "local")]) == 0)
        try await f.settle(b)
        #expect(try await CloudArtifactsFixture.journal(b).isEmpty)
        try await b.owner.markCloudRead()
        #expect(try await b.feed([f.entry("b", "mine.md")]) == 1)
        try await f.settle(b)
        #expect(!(try await CloudArtifactsFixture.journal(b)).isEmpty)
    }

    /// Point 3: no write lands outside the store: a walk out of the project, a project name with a slash, an arriving
    /// record for a path outside, and a linked folder inside the store all write nothing outside.
    @Test func aWriteOutsideTheStoreIsImpossible() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        #expect(CloudArtifactsFormat.storePath(projectId: "site", relPath: "../escape.html") == nil)
        #expect(CloudArtifactsFormat.storePath(projectId: "a/b", relPath: "x.html") == nil)
        #expect(CloudArtifactsFormat.storePath(projectId: "..", relPath: "x.html") == nil)
        #expect(CloudArtifactsFormat.storePath(projectId: "site", relPath: "/Users/x/outside.html") == nil)
        #expect(CloudArtifactsFormat.storePath(projectId: "site", relPath: "out/report.html") == "site/out/report.html")
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        let outside = f.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        // B's store holds a link where the project's folder would be.
        try FileManager.default.createSymbolicLink(at: f.store("b").appendingPathComponent("site"), withDestinationURL: outside)
        try await a.feed([try f.make("a", "deep/x.html", "<p>never outside</p>")])
        try await f.settle(a)
        var fromA: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        try await f.settle(b)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        // A source under a linked folder of the project is never read either.
        try FileManager.default.createSymbolicLink(at: f.project("a").appendingPathComponent("linked"), withDestinationURL: outside)
        try Data("secret elsewhere".utf8).write(to: outside.appendingPathComponent("y.html"))
        #expect(try await a.feed([f.entry("a", "linked/y.html")]) == 0)
        // An arriving path that walks out, is hidden or is on the never-send list is refused before a byte is kept.
        for path in ["site/../../x.html", "../x.html", "site/.hidden/x.html", "site/.env", "site/keys/id_rsa"] {
            #expect(CloudFileKind.artifacts.refusal(path) != nil)
        }
    }

    @Test func namesDifferingOnlyByCapitalsKeepBoth() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB)
        try await b.feed([try f.make("b", "Report.md", "B's")]); try await f.settle(b)
        try await a.feed([try f.make("a", "report.md", "A's")]); try await f.settle(a)
        var fromA: String?
        try await f.send(a, device: f.deviceA, to: b, cursor: &fromA)
        let texts = try await b.items().map { String(decoding: try Data(contentsOf: $0.url), as: UTF8.self) }
        #expect(Set(texts) == ["B's", "A's"])
    }
}

struct CloudArtifactsLimitTests {
    @Test func aLargeOneASecretOneAndAnOutsideOneStayOnThisMacEachWithItsLine() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        // 26 MB, sparse (nothing real is written).
        let big = f.project("a").appendingPathComponent("video.mp4")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big); try handle.truncate(atOffset: 26_000_000); try handle.close()
        let entries = [f.entry("a", "video.mp4"),
                       try f.make("a", "deploy-notes.md", "Use Authorization: Bearer abcdefghijklmnop1234 to call it."),
                       try f.make("a", "keys/server.pem", "-----BEGIN PRIVATE KEY-----x-----END PRIVATE KEY-----"),
                       try f.make("a", "page.html", "<script>const token = readToken(); const pic = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'</script>"),
                       CloudArtifactEntry(projectId: "site", projectName: "Site", root: f.project("a").path, relPath: "/tmp/outside.html",
                                          name: "outside.html", madeBy: nil, createdAt: 1)]
        try await a.feed(entries)
        try await f.settle(a)
        // Only the ordinary page travels (code and pictures in a page are not secrets).
        let keys = Set(try await CloudArtifactsFixture.journal(a).map(\.source.recordId))
        #expect(keys == ["file/artifacts/site/page.html", "file/artifacts/site/page.html" + CloudArtifactsFormat.aboutSuffix])
        let lines = try await a.pageLines()
        #expect(lines.contains(CloudArtifactsFormat.tooLargeLine(1)))
        #expect(lines.contains(CloudArtifactsFormat.secretNameLine(["deploy-notes.md", "server.pem"])))
    }

    @Test func theFolderAndArtifactsShareOneDailyBudget() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        let budget = CloudDayBudget(file: f.base.appendingPathComponent("a/data/cloud/subject/file-day-budget.json"))
        await a.owner.setDayBudget(budget)
        // The Cloud folder sent nearly all of today's 200 MB.
        budget.add(CloudFolderFormat.dailySendBytes - 10, day: f.clock.ms / CloudFolderFormat.day)
        try await a.feed([try f.make("a", "x.md", "more than ten bytes")])
        try await f.settle(a); await a.owner.sendNow()
        #expect(try await CloudArtifactsFixture.journal(a).isEmpty)
        #expect(try await a.pageLines().contains(CloudArtifactsFormat.dayFullLine))
        f.clock.advance(CloudFolderFormat.day); try await f.settle(a)
        #expect(!(try await CloudArtifactsFixture.journal(a)).isEmpty)
        #expect(budget.sent(day: f.clock.ms / CloudFolderFormat.day) > 0)
    }

    @Test func theRoomAndDiskFloorsHoldWithTheirLines() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA), b = try await f.mac("b", device: f.deviceB, freeDisk: 1_000_000_000)
        await a.owner.setRoomLeft { 2_000_000_000 }
        try await a.feed([try f.make("a", "x.md", "x")]); try await f.settle(a)
        #expect(try await CloudArtifactsFixture.journal(a).isEmpty)
        #expect(try await a.pageLines().contains(CloudArtifactsFormat.roomLowLine))
        await a.owner.setRoomLeft { 9_000_000_000 }
        try await a.owner.look()
        let operations = try await CloudArtifactsFixture.journal(a)
        #expect(!operations.isEmpty)
        await #expect(throws: CloudRecordRefusal.self) { _ = try await b.owner.validateIncoming(operations, files: []) }
        #expect(try await b.items().isEmpty)
        #expect(try await b.pageLines().contains(CloudArtifactsFormat.diskLowLine))
    }

    @Test func theNumbersAreTheOwnersAndTheSharedOnes() {
        let kind = CloudFileKind.artifacts
        #expect(kind.maximumFileBytes == 25_000_000)
        #expect(kind.maximumFolderBytes == 1_000_000_000)
        #expect(kind.domain == "artifacts")
        #expect(CloudBinGroup.retentionMilliseconds == 30 * 86_400_000)
        #expect(CloudFolderFormat.dailySendBytes == 200_000_000 && CloudFolderFormat.versionsPerDay == 6)
        #expect(CloudFolderFormat.roomFloor == 3_000_000_000 && CloudFolderFormat.diskFloor == 2_000_000_000)
        // The Cloud folder's description is exactly slice 1's.
        #expect(CloudFileKind.cloudFolder.domain == "cloud-folder" && CloudFileKind.cloudFolder.sourceId == "folder")
        #expect(CloudFileKind.cloudFolder.keeperKind == BackendCloudFolder.kind)
    }
}

/// An older build next to this one (cc136e602 or a Mac rolled back to it): it never announces artifacts, so this Mac
/// sends none; the kind is a domain of its own (an older build keeps such a pack waiting; packs are one domain each),
/// and neither kind's owner takes the other's records.
struct CloudArtifactsOlderBuildTests {
    @Test func withAMacThatDoesNotUnderstandNothingIsSentAndTheMacIsNamed() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA, understands: false)
        await a.owner.setWhoWaits { ["MacBook Pro"] }
        try await a.feed([try f.make("a", "x.md", "x")])
        try await f.settle(a)
        #expect(try await CloudArtifactsFixture.journal(a).isEmpty)
        #expect(try await a.pageLines().contains(CloudArtifactsFormat.gateLine(["MacBook Pro"])))
    }
    @Test func eachKindRefusesTheOthersRecords() async throws {
        let f = try CloudArtifactsFixture(); defer { f.close() }
        let a = try await f.mac("a", device: f.deviceA)
        try await a.feed([try f.make("a", "x.md", "x")]); try await f.settle(a)
        let operations = try await CloudArtifactsFixture.journal(a)
        #expect(!operations.isEmpty)
        let folder = try BackendCloudFolder(deviceId: f.deviceB, folder: f.base.appendingPathComponent("b/home/Terminal Deck Cloud"),
                                            stateRoot: f.base.appendingPathComponent("b/data/cloud-folder"), everyMacUnderstands: { true },
                                            freeDisk: { 500_000_000_000 }, now: { f.clock.ms })
        await #expect(throws: CloudRecordRefusal.self) { _ = try await folder.validateIncoming(operations, files: []) }
        #expect(CloudArtifactsFormat.domain == "artifacts")
        #expect(BackendCloudContentsBuilder.kindOf(domain: CloudArtifactsFormat.domain) == .artifacts)
        #expect(BackendCloudOverviewBuilder.inventory(.artifacts) == [CloudArtifactsFormat.inventoryRow])
        #expect(DeckMemoryStore.featureKey(CloudArtifactsFormat.feature, device: "ABC") == "onerule.understands.artifacts.abc")
    }
}
