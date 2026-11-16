import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Status-line lane (owner, 14 Nov): the main window's ONE Cloud line, its one "Sync now" and the space used per kind.
/// Every state is made from a fixture of what the sync core reports (snapshot + the Cloud page's one summary); nothing
/// here touches the network, a Keychain item or a file.
@Suite("Cloud status line, Sync now and space per kind")
struct CloudStatusLineTests {
    static let gate = CloudGate(features: ["cloud"], storageEntitled: true)
    static let at = Date(timeIntervalSince1970: 1_794_000_000) // a fixed moment

    private func coverage(_ row: String, bytes: Int64 = 10, complete: Bool = true, reasons: [String] = []) -> CloudCoverage {
        CloudCoverage(sourceId: "fixture-" + row, inventoryRow: row, complete: complete, items: 3, bytes: bytes, blockedReasons: reasons)
    }
    private func snapshot(_ phase: CloudAccountSnapshot.Phase = .signedIn, coverage: [CloudCoverage]? = nil, waiting: Int = 0,
                          head: UInt64 = 4, fetched: UInt64 = 4, problem: String? = nil) -> CloudAccountSnapshot {
        CloudAccountSnapshot(phase: phase, gate: Self.gate, displayName: "Fixture person", coverage: coverage ?? [self.coverage("I01")],
                             waitingRecords: waiting, problem: problem, cloudHead: CloudSequence(head), fetched: CloudSequence(fetched))
    }
    /// The engine fixture: the Cloud page's own summary for this snapshot, memory switched on and included.
    private func line(_ snapshot: CloudAccountSnapshot, online: Bool = true, memory: DeckMemoryAnswer? = nil, syncing: Bool = false,
                      extraWaiting: [BackendCloudOverview.Waiting] = [], tasks: Bool = false, savedSignIn: Bool = false) -> BackendCloudStatusLine {
        var input = BackendCloudOverviewInput(snapshot: snapshot, memory: .init(included: true),
                                              bootFiles: extraWaiting.isEmpty ? nil : .init(waiting: extraWaiting))
        if tasks { input.tasks = .init() }
        let overview = BackendCloudOverviewBuilder.build(input)
        return BackendCloudStatusLineBuilder.build(.init(snapshot: snapshot, savedSignIn: savedSignIn, online: online, overview: overview,
                                                         memoryAnswer: memory, syncingNow: syncing, levelAt: Self.at),
                                                   now: Self.at)
    }

    @Test func levelOnlyWhenEveryKindIsLevelAndNothingWaits() {
        let level = line(snapshot())
        #expect(level.kind == .level)
        #expect(level.text.hasPrefix("Everything is on your other devices · "))
        #expect(level.text == BackendCloudStatusLineWords.level(Self.at, now: Self.at))
        #expect(level.canSyncNow)
        // Something queued here is never "everything".
        #expect(line(snapshot(waiting: 12)).text == "Sending 12 changes…")
        #expect(line(snapshot(waiting: 1)).text == "Sending 1 change…")
        // Something still to fetch from the Cloud.
        #expect(line(snapshot(head: 7, fetched: 4)).text == "Getting 3 changes…")
        // Not known yet whether this Mac is level: never "everything".
        let unknown = CloudAccountSnapshot(phase: .signedIn, gate: Self.gate, coverage: [coverage("I01")])
        #expect(line(unknown).kind == .checking)
        // A pass he asked for, with nothing moving: the line says the pass.
        #expect(line(snapshot(), syncing: true).text == "Checking with your Cloud…")
        // Another day: the date is said too; no time known: the words alone.
        let tomorrow = Self.at.addingTimeInterval(86_400 * 2)
        #expect(BackendCloudStatusLineWords.level(Self.at, now: tomorrow).count > BackendCloudStatusLineWords.level(Self.at, now: Self.at).count)
        #expect(BackendCloudStatusLineWords.level(nil) == "Everything is on your other devices")
    }

    @Test func aPartNotAskedInThisPassIsNeverNotComplete() {
        // The "Settings: Not complete" race (14 Nov): a part the sync core has not confirmed in this pass.
        let memoryGap = snapshot(coverage: [coverage("I01", complete: false, reasons: ["Waiting for a verified snapshot."])])
        let shown = line(memoryGap)
        #expect(shown.kind == .checking)
        #expect(shown.text == "Checking…")
        #expect(!shown.text.lowercased().contains("complete"))
        #expect(shown.needs.isEmpty, "a gap of the sync core is never something he must do")
        let settingsGap = snapshot(coverage: [coverage("I01"), coverage(BackendCloudKinds.tasksRow, complete: false)])
        let tasks = line(settingsGap, tasks: true)
        #expect(tasks.kind == .checking)
        #expect(tasks.kind != .level)
    }

    @Test func oldDeleteQuestionsNeverNeedHim() {
        for answer in [DeckMemoryAnswer(missing: 0, held: 214, heldFrom: "MacBook Pro"),
                       DeckMemoryAnswer(missing: 3, held: 0, heldFrom: nil), DeckMemoryAnswer(missing: 1, held: 1, heldFrom: nil)] {
            let shown = line(snapshot(), memory: answer)
            #expect(shown.kind == .level)
            #expect(shown.needs.isEmpty)
        }
        #expect(line(snapshot(), online: false, memory: DeckMemoryAnswer(missing: 1, held: 0, heldFrom: nil)).kind == .offline)
    }

    @Test func anAIGroupIsInformationForTwentyFourHoursAndOpensTheBin() {
        let at = Int64(Self.at.timeIntervalSince1970 * 1000)
        func group(_ count: Int, time: Int64, by: CloudDeleteBy = .ai, era: CloudBinEra = .current) -> CloudBinGroup {
            .init(id: "routing-only", by: by, macName: "Mac mini", session: "Night work", at: time,
                  items: (0..<count).map { .init(id: "\($0)", kind: "memory", name: "Note \($0)") }, era: era)
        }
        let shot = snapshot()
        let overview = BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: shot, memory: .init(included: true)))
        var input = BackendCloudStatusLineInput(snapshot: shot, overview: overview)
        input.binGroups = [group(214, time: at - 60_000)]
        let shown = BackendCloudStatusLineBuilder.build(input, now: Self.at)
        #expect(shown.text == "214 removed by an AI tonight · Bin")
        #expect(shown.opensBin && shown.needs.isEmpty && shown.kind != .needsYou)
        for ignored in [group(20, time: at), group(214, time: at - 86_400_000), group(214, time: at + 1),
                        group(214, time: at, by: .person), group(214, time: at, era: .beforeNewRule)] {
            input.binGroups = [ignored]
            #expect(!BackendCloudStatusLineBuilder.build(input, now: Self.at).opensBin)
        }
    }

    @Test func aDeviceOrASavedPasswordsRequestNeedsHim() {
        let device = BackendCloudOverview.Waiting(id: "device:10000000-0000-4000-8000-00000000000b", text: "x", action: .trust(deviceId: "b"))
        #expect(line(snapshot(), extraWaiting: [device]).text == "Something needs you: a new device to allow")
        let ask = BackendCloudOverview.Waiting(id: "passwords:approval:r1", text: "x", action: .reviewApproval(id: "r1"))
        #expect(line(snapshot(), extraWaiting: [ask]).text == "Something needs you: a device asks for saved passwords")
        #expect(line(snapshot(), extraWaiting: [device, ask]).text == "Something needs you: a new device to allow, and 1 more")
        // No id, code or device name from the record reaches the line.
        #expect(BackendCloudPageWords.isPlain(line(snapshot(), extraWaiting: [device]).text))
    }

    @Test func signedOutOfflineProblemsPausedAndOff() {
        let out = line(CloudAccountSnapshot.signedOut)
        #expect(out.kind == .signedOut && out.text == "Signed out" && !out.canSyncNow)
        #expect(line(snapshot(.needsSignIn)).text == "Signed out")
        #expect(line(snapshot(.needsSignIn), online: false, savedSignIn: true).text == "Waiting for the internet")
        #expect(line(snapshot(.needsSignIn, problem: "No answer."), savedSignIn: true).text == "Can't reach your Cloud right now · it tries again by itself")
        let offline = line(snapshot(), online: false)
        #expect(offline.kind == .offline && offline.text == "Waiting for the internet" && !offline.canSyncNow)
        #expect(line(snapshot(problem: "The service did not answer.")).text == "Can't reach your Cloud right now · Sync now tries again")
        let refused = snapshot(coverage: [coverage("I01", complete: false, reasons: ["3 edits could not be sent and are kept here (refused)"])])
        #expect(line(refused).text == "Some changes were refused · Sync now tries again")
        #expect(line(snapshot(.paused)).text == "Paused on this Mac · Resume in Settings → Cloud")
        let off = BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: snapshot(), memory: .init(included: false)))
        #expect(BackendCloudStatusLineBuilder.build(.init(snapshot: snapshot(), overview: off)).text == "Cloud is off on this Mac")
        // Every state's words are plain (no id, key name, path or sync word).
        for text in [out.text, offline.text, line(snapshot()).text, line(snapshot(waiting: 4)).text] {
            #expect(BackendCloudPageWords.isPlain(text))
        }
    }

    /// Parked memory (14 Nov, the MacBook): "could not be saved on this Mac" said "Some changes were refused" all day,
    /// though the Cloud refused nothing. It is a quiet notice with its count; "refused" stays for the two real refusals.
    @Test func changesNotSavedHereAreAQuietNoticeNeverRefused() {
        let two = line(snapshot(coverage: [coverage("I05", complete: false, reasons: ["2 records could not be applied on this Mac and are kept for retry"])]))
        #expect(two.text == "2 changes could not be saved on this Mac yet · it tries again by itself")
        #expect(two.kind != .needsYou && two.kind != .problem && two.needs.isEmpty && two.canSyncNow)
        #expect(!two.text.contains("refused"))
        let one = line(snapshot(coverage: [coverage("I05", complete: false, reasons: ["1 records could not be applied on this Mac and are kept for retry"])]))
        #expect(one.text == "1 change could not be saved on this Mac yet · it tries again by itself")
        // Two parts that wait: their counts add up.
        let both = line(snapshot(coverage: [coverage("I01", complete: false, reasons: ["1 records could not be applied on this Mac and are kept for retry"]),
                                            coverage("I05", complete: false, reasons: ["2 records could not be applied on this Mac and are kept for retry"])]))
        #expect(both.text == "3 changes could not be saved on this Mac yet · it tries again by itself")
        // The two real refusal sentences still say "refused".
        let sent = line(snapshot(coverage: [coverage("I01", complete: false, reasons: ["3 edits could not be sent and are kept here (refused)"])]))
        #expect(sent.text == "Some changes were refused · Sync now tries again")
        let behind = line(snapshot(coverage: [coverage("I01", complete: false, reasons: ["2 edits wait behind an earlier edit"])]))
        #expect(behind.text == "Some changes were refused · Sync now tries again")
        // A real refusal beside a change not saved here: the refusal is said.
        let mixed = line(snapshot(coverage: [coverage("I01", complete: false, reasons: ["3 edits could not be sent and are kept here (refused)"]),
                                             coverage("I05", complete: false, reasons: ["2 records could not be applied on this Mac and are kept for retry"])]))
        #expect(mixed.text == "Some changes were refused · Sync now tries again")
        #expect(BackendCloudPageWords.isPlain(two.text))
    }

    @Test func noSignedOutFlashWhileASavedSignInIsChecked_fix1() {
        // Right after launch: the account is not read yet, but a sign-in is saved.
        let launch = line(CloudAccountSnapshot.signedOut, savedSignIn: true)
        #expect(launch.kind == .checking && launch.text == "Checking…" && !launch.canSyncNow)
        // Being reached, no failure yet: still checking (never "Can't reach" before a failure, never "Signed out").
        #expect(line(snapshot(.needsSignIn), savedSignIn: true).text == "Checking…")
        // Really no sign-in: "Signed out", and the toolbar's short form says the same.
        let none = line(CloudAccountSnapshot.signedOut)
        #expect(none.text == "Signed out")
        #expect(BackendCloudStatusLineWords.short(none.kind) == "Signed out")
        #expect(BackendCloudStatusLineWords.short(launch.kind) == "Checking…")
    }

    @Test func neverEverythingBeforeTheMemoryQuestionWasRead_fix3() {
        let shot = snapshot()
        let overview = BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: shot, memory: .init(included: true)))
        var input = BackendCloudStatusLineInput(snapshot: shot, overview: overview, levelAt: Self.at)
        input.memoryChecked = false
        #expect(BackendCloudStatusLineBuilder.build(input, now: Self.at).kind == .checking)
        input.memoryChecked = true
        #expect(BackendCloudStatusLineBuilder.build(input, now: Self.at).kind == .level)
    }

    @Test func syncNowPressedTwiceIsOnePass() async throws {
        let gate = BackendCloudSyncNowGate()
        let passes = PassCounter()
        let (release, opened) = AsyncStream<Void>.makeStream() // the first pass holds until `opened` yields
        let pass: @Sendable () async throws -> Void = {
            await passes.add()
            for await _ in release { break }
        }
        async let first: Void = gate.run(pass)
        while !(await gate.isRunning) { await Task.yield() }
        async let second: Void = gate.run(pass)
        while (await gate.joined) < 1 { await Task.yield() }
        opened.yield(())
        opened.finish()
        try await first
        try await second
        #expect(await passes.count == 1)
        #expect(await gate.passes == 1)
        // After it ended, a new press is a new pass.
        try await gate.run({ await passes.add() })
        #expect(await passes.count == 2)
    }

    @Test func spaceAddsUpFromTheOneSource() {
        let shot = snapshot(coverage: [coverage("I01", bytes: 100_000_000), coverage("I02", bytes: 20_000_000),
                                       coverage(CloudBootFilesFormat.inventoryRow, bytes: 2_000_000),
                                       coverage(BackendCloudKinds.tasksRow, bytes: 0)])
        let space = BackendCloudSpace.make(shot, bytesLeft: 9_878_000_000)
        #expect(space.parts.map(\.title) == ["Memory", "Instruction files"], "a kind with nothing is not listed")
        #expect(space.parts.map(\.bytes) == [120_000_000, 2_000_000])
        #expect(space.total == 122_000_000)
        #expect(space.limit == 10_000_000_000)
        #expect(space.line == "Memory " + BackendCloudSpace.size(120_000_000) + " · Instruction files " + BackendCloudSpace.size(2_000_000))
        #expect(space.totalLine == "Total " + BackendCloudSpace.size(122_000_000) + " of " + BackendCloudSpace.size(10_000_000_000))
        // Until the service has said its room: the total alone.
        #expect(BackendCloudSpace.make(shot, bytesLeft: nil).totalLine == "Total " + BackendCloudSpace.size(122_000_000))
        // One source: the pages' counts carry exactly this value, and the tool's wire says the same numbers.
        let counts = BackendCloudPageCounts(space: space)
        #expect(counts.space == BackendCloudSpace.make(shot, bytesLeft: 9_878_000_000))
        #expect(space.wireValue["totalBytes"] == .number(122_000_000))
        #expect(BackendCloudSpace.make(snapshot(coverage: []), bytesLeft: nil).line == nil)
    }
}

private actor PassCounter {
    var count = 0
    func add() { count += 1 }
}
