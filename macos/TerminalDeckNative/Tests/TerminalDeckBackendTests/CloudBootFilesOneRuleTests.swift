import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

extension CloudBootFilesFixture {
    /// A fixed moment in the past (June 2025): every file time in these tests is set from it, never read from the clock.
    static let past: Int64 = 1_750_000_000_000
    /// Writes a file and sets its modification time (ms), so which edit is newer never depends on how fast a test runs.
    func write(_ path: String, _ text: String, at ms: Int64) throws {
        try write(path, text)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(ms) / 1000)], ofItemAtPath: url(path).path)
    }
}

/// A clock the test moves by hand.
final class CloudOneRuleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ start: Int64) { value = start }
    var now: Int64 { lock.withLock { value } }
    func set(_ next: Int64) { lock.withLock { value = next } }
}

@Suite("Cloud one rule: the newest instruction file is used on every Mac, the older one kept 30 days")
struct CloudBootFilesOneRuleTests {
    typealias F = CloudBootFilesFixture
    typealias Rules = CloudBootFilesRules
    static let a = "aaaaaaaa-0000-0000-0000-000000000000", b = "bbbbbbbb-0000-0000-0000-000000000000"

    // MARK: The rule

    @Test func theLaterTimeWinsWhicheverSideItIsOn() {
        let now = F.past + 3_600_000
        #expect(Rules.newest(local: .init(at: F.past + 10, device: Self.a), arrived: .init(at: F.past + 20, device: Self.b), now: now) == .arrived)
        #expect(Rules.newest(local: .init(at: F.past + 20, device: Self.a), arrived: .init(at: F.past + 10, device: Self.b), now: now) == .local)
    }

    @Test func anExactTieGoesToTheLargerDeviceIdTheSameWayOnBothMacs() {
        let now = F.past + 3_600_000
        let onA = Rules.newest(local: .init(at: F.past + 10, device: Self.a), arrived: .init(at: F.past + 10, device: Self.b), now: now)
        let onB = Rules.newest(local: .init(at: F.past + 10, device: Self.b), arrived: .init(at: F.past + 10, device: Self.a), now: now)
        #expect(onA == .arrived && onB == .local)   // Mac B's version ("bbbb…" > "aaaa…") on both
    }

    @Test func aClockAheadOfNowCannotWinByBeingAhead() {
        let now = F.past + 1_000
        #expect(Rules.clamp(F.past + 999_999, agreedAt: F.past, now: now) == now)
        // Ahead by a day versus an edit made just now: both count as "now", so the tie rule decides, not the wrong clock.
        let pick = Rules.newest(local: .init(at: now, device: Self.b), arrived: .init(at: now + 86_400_000, device: Self.a), now: now)
        #expect(pick == .local)
    }

    @Test func aTimeBeforeTheAgreedVersionCountsAsTheAgreedVersionsTime() {
        // When a version is made: a clock far behind cannot make it look older than the version it was made on top of.
        #expect(Rules.clamp(F.past - 50_000, agreedAt: F.past, now: F.past + 1_000) == F.past)
        // A parent stamped in the future by a wrong clock is capped at now, so it is not inherited.
        #expect(Rules.clamp(F.past, agreedAt: F.past + 86_400_000, now: F.past + 1_000) == F.past + 1_000)
    }

    @Test func anEditMadeOfflineEarlierDoesNotWinBecauseItsMacReconnectedLater() {
        // Mac A edited at 10:00 while offline and reconnects at 12:00; Mac B edited at 11:00 and sent it at once.
        let ten = F.past, eleven = F.past + 3_600_000, noon = F.past + 7_200_000
        #expect(Rules.newest(local: .init(at: eleven, device: Self.b), arrived: .init(at: ten, device: Self.a), now: noon) == .local)
        #expect(Rules.newest(local: .init(at: ten, device: Self.a), arrived: .init(at: eleven, device: Self.b), now: noon) == .arrived)
    }

    @Test func ruleJAJoiningMacsFirstCopyLosesToAVersionWithHistory() {
        let now = F.past + 3_600_000
        let pick = Rules.newest(local: .init(at: F.past + 999, device: Self.b, firstCopy: true), arrived: .init(at: F.past, device: Self.a), now: now)
        #expect(pick == .arrived)
        let stays = Rules.newest(local: .init(at: F.past, device: Self.a), arrived: .init(at: F.past + 999, device: Self.b, firstCopy: true), now: now)
        #expect(stays == .local)
    }

    @Test func theStepUsesTheNewestAndASuccessorStillAppliesSilently() {
        // The next version of what this Mac last saw: written, whatever the times.
        #expect(Rules.step(local: "a", copy: "x", base: "a", runs: false, accepted: false, newest: .local) == .write)
        // Both changed: the newer one.
        #expect(Rules.step(local: "b", copy: "x", base: "a", runs: false, accepted: false, newest: .arrived) == .useArrived)
        #expect(Rules.step(local: "b", copy: "x", base: "a", runs: false, accepted: false, newest: .local) == .useLocal)
        // Times not known: both kept, as before. A removal here is not in this slice: unchanged.
        #expect(Rules.step(local: "b", copy: "x", base: "a", runs: false, accepted: false) == .keepBoth)
        #expect(Rules.step(local: nil, copy: "x", base: "a", runs: false, accepted: false, newest: .arrived) == .keepBoth)
    }

    @Test func aRunnableFileWaitsOnlyUnderAskMeForEachNewDevice() {
        // "Ask me for each new device": not accepted, so the newer runnable version waits for Accept.
        #expect(Rules.step(local: "b", copy: "x", base: "a", runs: true, accepted: false, newest: .arrived) == .needsAccept)
        // "Automatically, with my account": accepted by the trust setting, so it is used like any other file.
        #expect(Rules.step(local: "b", copy: "x", base: "a", runs: true, accepted: true, newest: .arrived) == .useArrived)
        // This Mac's own newer runnable file never waits for its own accept.
        #expect(Rules.step(local: "b", copy: "x", base: "a", runs: true, accepted: false, newest: .local) == .useLocal)
    }

    @Test func aWriteLandsOnlyOverTheExactBytesExpected() throws {
        let f = try F(); defer { f.close() }
        try f.write("app/CLAUDE.md", "edited a moment ago\n")
        let expected = BackendCloudBrainMemoryHash.bytes(Data("what this Mac read\n".utf8))
        #expect(throws: BackendCloudBootFilesDisk.Stop.self) {
            try BackendCloudBootFilesDisk.replace(root: f.url("app"), relative: "CLAUDE.md", bytes: Data("newer\n".utf8), expecting: expected)
        }
        #expect(f.text("app/CLAUDE.md") == "edited a moment ago\n")
    }

    // MARK: Two Macs offline

    /// Both Macs agree on v1, both edit while apart, then meet in either order: both end with the newer file, the older
    /// one is kept on each device for 30 days, and only the Mac whose file was replaced gets the line.
    @Test(arguments: [true, false])
    func twoMacsThatBothEditedOfflineEndWithTheNewerFile(olderSendsFirst: Bool) async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "v1\n", at: F.past)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let start = try await F.local(a)
        try await F.apply(b, start.operations, device: f.deviceA)
        let startB = try await F.local(b)
        // Offline: Mac A edits at 10:00, Mac B at 11:00.
        try f.write("a/app/CLAUDE.md", "made on A at ten\n", at: F.past + 600_000)
        try f.write("b/app/CLAUDE.md", "made on B at eleven\n", at: F.past + 4_200_000)
        try await a.refresh()
        try await b.refresh()
        let fromA = try await F.local(a, after: start.cursor), fromB = try await F.local(b, after: startB.cursor)
        #expect(fromA.operations.count == 1 && fromB.operations.count == 1)
        if olderSendsFirst {
            try await F.apply(b, fromA.operations, device: f.deviceA)
            try await F.apply(a, fromB.operations, device: f.deviceB)
        } else {
            try await F.apply(a, fromB.operations, device: f.deviceB)
            try await F.apply(b, fromA.operations, device: f.deviceA)
        }
        #expect(f.text("a/app/CLAUDE.md") == "made on B at eleven\n")
        #expect(f.text("b/app/CLAUDE.md") == "made on B at eleven\n")
        // Nothing waits and nothing is "kept beside" on either Mac.
        let linesA = try await a.items(), linesB = try await b.items()
        #expect(linesA.isEmpty && linesB.isEmpty)
        // Mac A: one line, from Mac B, and its own version kept until 30 days from now.
        let changesA = try await a.changedFromOtherDevices()
        let line = try #require(changesA.first)
        #expect(line.how == "newer" && line.originDevice == f.deviceB)
        let keptA = try await a.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md")
        let mine = try #require(keptA.first { $0.hash == line.previousHash })
        #expect(mine.device == f.deviceA && mine.at == F.past + 600_000)
        #expect(mine.keptUntil >= line.at + Rules.keptFor - 60_000)
        // On disk in the versions place, one copy per content, beside this identity's Cloud folders.
        let content = f.url("a/cloud/archive/versions/instructionFiles/" + mine.hash)
        #expect(try Data(contentsOf: content) == Data("made on A at ten\n".utf8))
        #expect(FileManager.default.fileExists(atPath: f.url("a/cloud/archive/versions/versions.sqlite").path))
        // Mac B: its file was never replaced, so no line; Mac A's older version is kept there too.
        let changesB = try await b.changedFromOtherDevices()
        #expect(!changesB.contains { $0.how == "newer" })
        let keptB = try await b.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md")
        #expect(keptB.contains { $0.hash == BackendCloudBrainMemoryHash.bytes(Data("made on A at ten\n".utf8)) && $0.device == f.deviceA })
        // Settled: one more exchange each way changes nothing.
        try await a.refresh()
        try await b.refresh()
        let echoA = try await F.local(a, after: fromA.cursor), echoB = try await F.local(b, after: fromB.cursor)
        if !echoA.operations.isEmpty { try await F.apply(b, echoA.operations, device: f.deviceA) }
        if !echoB.operations.isEmpty { try await F.apply(a, echoB.operations, device: f.deviceB) }
        #expect(f.text("a/app/CLAUDE.md") == "made on B at eleven\n" && f.text("b/app/CLAUDE.md") == "made on B at eleven\n")
        let afterA = try await a.items(), afterB = try await b.items()
        #expect(afterA.isEmpty && afterB.isEmpty)
    }

    @Test(arguments: [false, true])
    func aNewerRunnableFileWaitsOnlyUnderAskMe(automatic: Bool) async throws {
        let f = try F(); defer { f.close() }
        let skill = ".claude/skills/s/SKILL.md"
        try f.write("a/app/" + skill, "---\nname: s\n---\nOne.\n", at: F.past)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        await b.setAutoAccept(automatic)
        let start = try await F.local(a)
        try await F.apply(b, start.operations, device: f.deviceA)
        let startB = try await F.local(b)
        try f.write("b/app/" + skill, "---\nname: s\n---\nMine.\n", at: F.past + 10_000)
        try await b.refresh()
        _ = try await F.local(b, after: startB.cursor)
        let newer = "---\nname: s\nallowed-tools: Bash\n---\nTheirs.\n"
        try f.write("a/app/" + skill, newer, at: F.past + 20_000)
        try await a.refresh()
        try await F.apply(b, try await F.local(a, after: start.cursor).operations, device: f.deviceA)
        let lines = try await b.items()
        if automatic {
            #expect(f.text("b/app/" + skill) == newer)
            #expect(lines.isEmpty)
        } else {
            #expect(f.text("b/app/" + skill) == "---\nname: s\n---\nMine.\n")
            let waits = try #require(lines.first)
            #expect(lines.count == 1 && waits.canAccept && waits.reasons.contains("newer-version") && waits.reasons.contains("header:allowed-tools"))
        }
    }

    // MARK: Versions kept beside before this build

    @Test func aVersionKeptBesideBeforeThisBuildIsResolvedOnceWithOneLine() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "v1\n", at: F.past)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let start = try await F.local(a)
        try await F.apply(b, start.operations, device: f.deviceA)
        try f.write("b/app/CLAUDE.md", "older on B\n", at: F.past + 10_000)
        try await b.refresh()
        try f.write("a/app/CLAUDE.md", "newer on A\n", at: F.past + 20_000)
        try await a.refresh()
        let edit = try await F.local(a, after: start.cursor)
        // What the build before this one did: the engine kept Mac A's version beside, and lane F listed it.
        let engine = try await b.core()
        let prepared = try await engine.validateIncoming(edit.operations, files: [])
        _ = try await engine.applyPrepared(prepared, origin: .init(deviceId: f.deviceA, sequence: .init(1)))
        let hash = BackendCloudBrainMemoryHash.bytes(Data("newer on A\n".utf8))
        try await b.put(.otherVersion, sourceId: BackendCloudBootFiles.sourceId(kind: .project, identity: "p"), identity: "p", relative: "CLAUDE.md",
                        hash: hash, bytes: 11, origin: f.deviceA, reasons: ["local-differs"], at: F.past + 30_000)
        #expect(f.text("b/app/CLAUDE.md") == "older on B\n")
        // First look of this build: the newer is in use, the older kept, one line, no question.
        try await b.refresh()
        #expect(f.text("b/app/CLAUDE.md") == "newer on A\n")
        let lines = try await b.items()
        #expect(lines.isEmpty)
        let changes = try await b.changedFromOtherDevices()
        #expect(changes.filter { $0.how == "newer" }.count == 1)
        let kept = try await b.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md")
        #expect(kept.contains { $0.hash == BackendCloudBrainMemoryHash.bytes(Data("older on B\n".utf8)) })
        // Once: looking again adds nothing.
        try await b.refresh()
        let again = try await b.changedFromOtherDevices()
        #expect(again.filter { $0.how == "newer" }.count == 1)
    }

    // MARK: The 30-day keeper

    @Test func theKeeperDeletesVersionsOlderThan30DaysAndOnlyThem() throws {
        let f = try F(); defer { f.close() }
        let keeper = BackendCloudVersionKeeper(root: f.url("cloud/archive/versions"))
        let kind = BackendCloudVersionKeeper.instructionFiles
        let day: Int64 = 86_400_000
        try keeper.keep(kind: kind, itemKey: "k1", name: "CLAUDE.md", place: nil, at: F.past, device: Self.a, content: Data("old\n".utf8), now: F.past)
        try keeper.keep(kind: kind, itemKey: "k2", name: "AGENTS.md", place: nil, at: F.past, device: Self.a, content: Data("young\n".utf8), now: F.past + 20 * day)
        // The same content for two items is one file on disk.
        try keeper.keep(kind: kind, itemKey: "k3", name: "GEMINI.md", place: nil, at: F.past, device: Self.a, content: Data("young\n".utf8), now: F.past + 20 * day)
        let old = BackendCloudBrainMemoryHash.bytes(Data("old\n".utf8)), young = BackendCloudBrainMemoryHash.bytes(Data("young\n".utf8))
        #expect(try keeper.sweep(before: F.past + 29 * day) == 0)
        #expect(keeper.content(kind: kind, sha256: old) == Data("old\n".utf8))
        #expect(try keeper.sweep(before: F.past + 30 * day) == 1)
        #expect(keeper.content(kind: kind, sha256: old) == nil)
        #expect(!FileManager.default.fileExists(atPath: keeper.contentURL(kind: kind, sha256: old).path))
        #expect(keeper.content(kind: kind, sha256: young) == Data("young\n".utf8))
        #expect(try keeper.versions(itemKey: "k1").isEmpty && keeper.versions(itemKey: "k2").count == 1)
        #expect(try keeper.sweep(before: F.past + 50 * day) == 2)
        #expect(keeper.content(kind: kind, sha256: young) == nil)
    }

    @Test func theDailySweepRunsAtMostOnceADayOnTheBootFilesClock() async throws {
        let f = try F(); defer { f.close() }
        let clock = CloudOneRuleClock(F.past)
        let day: Int64 = 86_400_000
        let boot = try BackendCloudBootFiles(deviceId: f.deviceA, stateRoot: f.url("m/cloud/boot-files"), now: { clock.now })
        try await boot.setPlaces([])
        // No service clock (no sync core): nothing is ever swept, however far this Mac's clock jumps.
        let sourceIdEarly = BackendCloudBootFiles.sourceId(kind: .project, identity: "early")
        try await boot.keep(Data("early\n".utf8), hash: BackendCloudBrainMemoryHash.bytes(Data("early\n".utf8)), sourceId: sourceIdEarly, relative: "CLAUDE.md",
                            device: f.deviceA, at: F.past)
        clock.set(F.past + 400 * day)
        try await boot.refresh()
        #expect(try await boot.keptVersions(place: .project, identity: "early", relative: "CLAUDE.md").count == 1)
        clock.set(F.past)
        await boot.setSweepOnLocalClock(true)
        let sourceId = BackendCloudBootFiles.sourceId(kind: .project, identity: "p")
        try await boot.keep(Data("kept\n".utf8), hash: BackendCloudBrainMemoryHash.bytes(Data("kept\n".utf8)), sourceId: sourceId, relative: "CLAUDE.md",
                            device: f.deviceA, at: F.past)
        #expect(try await boot.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md").count == 1)
        clock.set(F.past + 29 * day)
        try await boot.refresh()
        #expect(try await boot.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md").count == 1)
        clock.set(F.past + 30 * day)
        try await boot.refresh()
        #expect(try await boot.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md").isEmpty)
    }

    // MARK: Review fixes (14 Nov)

    /// Blocker 1: a version stamped in the future by a clock that runs ahead is not inherited; the newer real edit still
    /// wins on both Macs, by time and not by device order.
    @Test func aParentWithAFutureTimeDoesNotDecideTheNextClash() async throws {
        let f = try F(); defer { f.close() }
        let clockA = CloudOneRuleClock(F.past), clockB = CloudOneRuleClock(F.past)
        try f.folder("a/app"); try f.folder("b/app")
        // Device ids chosen so the device order favours Mac A: only the time can make Mac B win.
        let deviceA = "ffffffff-0000-0000-0000-000000000000", deviceB = "11111111-0000-0000-0000-000000000000"
        let a = try BackendCloudBootFiles(deviceId: deviceA, stateRoot: f.url("a/cloud/boot-files"), now: { clockA.now })
        let b = try BackendCloudBootFiles(deviceId: deviceB, stateRoot: f.url("b/cloud/boot-files"), now: { clockB.now })
        try await a.setPlaces([f.project("p", "a/app")])
        try await b.setPlaces([f.project("p", "b/app")])
        // v1 from a Mac whose clock is a day ahead reaches both.
        let v1 = try F.forged(key: F.prefix(project: "p") + "CLAUDE.md", data: Data("v1\n".utf8), device: Self.a, createdAt: F.past + 86_400_000)
        try await F.apply(a, [v1], device: Self.a)
        try await F.apply(b, [v1], device: Self.a)
        let startA = try await F.local(a), startB = try await F.local(b)
        // Offline: Mac A records its edit at :10, Mac B at :20.
        try f.write("a/app/CLAUDE.md", "edit on A\n", at: F.past + 10_000)
        clockA.set(F.past + 10_000)
        try await a.refresh()
        try f.write("b/app/CLAUDE.md", "edit on B\n", at: F.past + 20_000)
        clockB.set(F.past + 20_000)
        try await b.refresh()
        let fromA = try await F.local(a, after: startA.cursor), fromB = try await F.local(b, after: startB.cursor)
        clockA.set(F.past + 30_000); clockB.set(F.past + 30_000)
        try await F.apply(b, fromA.operations, device: deviceA)
        try await F.apply(a, fromB.operations, device: deviceB)
        #expect(f.text("a/app/CLAUDE.md") == "edit on B\n")
        #expect(f.text("b/app/CLAUDE.md") == "edit on B\n")
        // The file written here never carries a time later than now.
        let written = try FileManager.default.attributesOfItem(atPath: f.url("a/app/CLAUDE.md").path)[.modificationDate] as? Date
        #expect((written?.timeIntervalSince1970 ?? .infinity) * 1000 <= Double(F.past + 30_000))
    }

    /// Blocker 2: a line whose arrived version has no record here is left exactly as it was (its time is never guessed).
    @Test func aKeptBesideLineWithoutTheArrivedVersionsRecordStaysAsItWas() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "theirs\n", at: F.past)
        try f.write("b/app/AGENTS.md", "mine\n", at: F.past)
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        try await F.apply(b, try await F.local(a).operations, device: f.deviceA)
        // A line for AGENTS.md naming bytes this Mac holds only as another path's version: no record of it for AGENTS.md.
        let hash = BackendCloudBrainMemoryHash.bytes(Data("theirs\n".utf8))
        let sourceId = BackendCloudBootFiles.sourceId(kind: .project, identity: "p")
        try await b.put(.otherVersion, sourceId: sourceId, identity: "p", relative: "AGENTS.md", hash: hash, bytes: 7, origin: f.deviceA,
                        reasons: ["local-differs"], at: F.past + 1)
        let before = try await b.items()
        try await b.refresh()
        let after = try await b.items()
        #expect(after == before)
        #expect(f.text("b/app/AGENTS.md") == "mine\n")
    }

    /// Follow-up 3: when first-launch settling keeps THIS Mac's version, it is sent again as the newest, so a Mac that
    /// no longer lists the clash decides it again.
    @Test func settlingAnOldLineInFavourOfThisMacSendsItsVersionAgain() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "v1\n", at: F.past)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let start = try await F.local(a)
        try await F.apply(b, start.operations, device: f.deviceA)
        try f.write("a/app/CLAUDE.md", "older on A\n", at: F.past + 10_000)
        try await a.refresh()
        try f.write("b/app/CLAUDE.md", "newer on B\n", at: F.past + 20_000)
        try await b.refresh()
        let recorded = try await F.local(b)
        let edit = try await F.local(a, after: start.cursor)
        let engine = try await b.core()
        let prepared = try await engine.validateIncoming(edit.operations, files: [])
        _ = try await engine.applyPrepared(prepared, origin: .init(deviceId: f.deviceA, sequence: .init(1)))
        try await b.put(.otherVersion, sourceId: BackendCloudBootFiles.sourceId(kind: .project, identity: "p"), identity: "p", relative: "CLAUDE.md",
                        hash: BackendCloudBrainMemoryHash.bytes(Data("older on A\n".utf8)), bytes: 11, origin: f.deviceA, reasons: ["local-differs"], at: F.past + 30_000)
        try await b.refresh()
        #expect(f.text("b/app/CLAUDE.md") == "newer on B\n")
        let lines = try await b.items()
        #expect(lines.isEmpty)
        let again = try await F.local(b, after: recorded.cursor)
        #expect(again.operations.count == 1)
        let body = try F.body(try #require(again.operations.first))
        #expect(body == "newer on B\n")
        // Mac A, which no longer lists anything, takes it by the same rule.
        try await F.apply(a, again.operations, device: f.deviceB)
        #expect(f.text("a/app/CLAUDE.md") == "newer on B\n")
    }

    /// Follow-up 4: a file replaced twice within the hour is not replaced a third time; both stay, listed as before.
    @Test func aThirdReplacementWithinTheHourIsHeldBack() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "v1\n", at: F.past)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let start = try await F.local(a)
        try await F.apply(b, start.operations, device: f.deviceA)
        let startB = try await F.local(b)
        let sourceId = BackendCloudBootFiles.sourceId(kind: .project, identity: "p")
        for _ in 0..<2 { try await b.applied(sourceId, "CLAUDE.md", hash: String(repeating: "0", count: 64), origin: f.deviceA, how: "newer", replaced: nil) }
        try f.write("b/app/CLAUDE.md", "mine\n", at: F.past + 10_000)
        try await b.refresh()
        _ = try await F.local(b, after: startB.cursor)
        try f.write("a/app/CLAUDE.md", "theirs, newer\n", at: F.past + 20_000)
        try await a.refresh()
        try await F.apply(b, try await F.local(a, after: start.cursor).operations, device: f.deviceA)
        #expect(f.text("b/app/CLAUDE.md") == "mine\n")
        let lines = try await b.items()
        #expect(lines.count == 1 && lines.first?.kind == .otherVersion && lines.first?.reasons == ["local-differs"])
    }

    /// Follow-up 8: this Mac's edit that was not recorded yet wins over an arrival: the OTHER Mac gets the one line and
    /// keeps its own version (it is told by a version made beside its own, not on top of it).
    @Test func anUnrecordedEditThatWinsGivesTheOtherMacTheLine() async throws {
        let f = try F(); defer { f.close() }
        try f.write("a/app/CLAUDE.md", "v1\n", at: F.past)
        try f.folder("b/app")
        let a = try await f.mac("a", device: f.deviceA, places: [f.project("p", "a/app")])
        let b = try await f.mac("b", device: f.deviceB, places: [f.project("p", "b/app")])
        let start = try await F.local(a)
        try await F.apply(b, start.operations, device: f.deviceA)
        let startB = try await F.local(b)
        try f.write("a/app/CLAUDE.md", "older on A\n", at: F.past + 10_000)
        try await a.refresh()
        let edit = try await F.local(a, after: start.cursor)
        // Mac B's edit is in its folder but not recorded when Mac A's arrives (the engine places it straight into the copy).
        try f.write("b/app/CLAUDE.md", "newer on B\n", at: F.past + 20_000)
        let engine = try await b.core()
        let prepared = try await engine.validateIncoming(edit.operations, files: [])
        _ = try await engine.applyPrepared(prepared, origin: .init(deviceId: f.deviceA, sequence: .init(1)))
        try await b.refresh()
        #expect(f.text("b/app/CLAUDE.md") == "newer on B\n")
        let fromB = try await F.local(b, after: startB.cursor)
        #expect(fromB.operations.count == 1)
        try await F.apply(a, fromB.operations, device: f.deviceB)
        #expect(f.text("a/app/CLAUDE.md") == "newer on B\n")
        let changes = try await a.changedFromOtherDevices()
        #expect(changes.first?.how == "newer" && changes.first?.originDevice == f.deviceB)
        let kept = try await a.keptVersions(place: .project, identity: "p", relative: "CLAUDE.md")
        #expect(kept.contains { $0.hash == BackendCloudBrainMemoryHash.bytes(Data("older on A\n".utf8)) && $0.device == f.deviceA })
    }

    // MARK: The line

    @Test func theLineCarriesANameAndADateAndNeverAnIdOrAPath() {
        let until = Int64(Date(timeIntervalSince1970: 1_797_206_400).timeIntervalSince1970 * 1000)   // 14 Dec 2026 00:00 UTC
        let line = CloudVersionReplacedLine(device: "Mac mini", name: CloudVersionReplacedLine.fileName("CLAUDE.md"), project: "iMatch", keptUntil: until,
                                            itemId: "project|p-123|CLAUDE.md|" + String(repeating: "a", count: 64))
        let utc = TimeZone(identifier: "UTC")!
        #expect(line.text(timeZone: utc) == "Mac mini's newer CLAUDE.md (iMatch) is in use; this Mac's version is kept until 14 Dec · Show")
        let bare = CloudVersionReplacedLine(device: "Studio Mac", name: CloudVersionReplacedLine.fileName(".claude/skills/review/SKILL.md"), project: nil,
                                            keptUntil: until, itemId: "x")
        #expect(bare.text(timeZone: utc) == "Studio Mac's newer review skill is in use; this Mac's version is kept until 14 Dec · Show")
        for text in [line.text(timeZone: utc), bare.text(timeZone: utc)] {
            #expect(!text.contains("/") && !text.contains("p-123") && !text.contains("aaaaaaaa") && !text.contains("|"))
        }
        #expect(line.sentence(timeZone: utc) == "Mac mini's newer CLAUDE.md (iMatch) is in use; this Mac's version is kept until 14 Dec")
    }
}
