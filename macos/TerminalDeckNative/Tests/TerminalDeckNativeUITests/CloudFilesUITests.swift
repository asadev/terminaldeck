import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Lane L4, the Cloud page as a file manager: the 10-second Undo line, what waits for it, opening and versions, and
/// pictures of the page (light and dark, normal and narrow). No memory store, window, Keychain or network is used: the
/// page's file actions are recorded instead.
@Suite("Cloud files — the page")
@MainActor
struct CloudFilesUITests {
    typealias F = BackendCloudContentsFixture
    let now = Int64(Date().timeIntervalSince1970 * 1000)

    final class Done: @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        func add(_ call: String) { lock.withLock { calls.append(call) } }
        var all: [String] { lock.withLock { calls } }
    }
    /// `changes`: the switch for changes to memory notes (off in the app until removals travel).
    /// `real`: CLOUD-FILES-4's fixture shaped as his real Macs' records.
    /// `shaped`: the records the page reads, when a test needs them other than the fixture's.
    func page(_ done: Done, changes: Bool = true, real: Bool = false, answer: DeckMemoryAnswer? = nil,
              shaped: ((contents: CloudSyncContents, names: BackendCloudContentsNames)) -> (contents: CloudSyncContents, names: BackendCloudContentsNames) = { $0 })
        throws -> NativeCloudContentsModel {
        let account = NativeCloudAccount()
        account.fixtureSnapshot(F.snapshot(now: now))
        // One rule phase 2: the page's changes are the memory store's own functions (recorded here).
        let ops = NativeCloudFileOps(text: { path in "# Text of \((path as NSString).lastPathComponent)" },
                                     keptText: { item, id in "# Kept " + String(id.prefix(4)) + " of " + (item as NSString).lastPathComponent },
                                     useVersion: { item, version in done.add("use " + item + " <- " + version) },
                                     remove: { path, fromAI in done.add((fromAI ? "remove by AI " : "remove ") + path) },
                                     putBack: { path in done.add("putBack " + path) },
                                     emptyBin: { done.add("emptyBin"); return 1 },
                                     cleanUp: { done.add("cleanUp"); return 3 },
                                     counts: { (bin: 1, kept: 3) })
        let deletes = NativeCloudDeleteOps(read: { _ in .init(gateOpen: changes) }, delete: { items, _, actor in
            for item in items { done.add("remove " + (item.place ?? item.id)) }
            return [.init(id: actor.group, by: actor.by, macName: actor.macName, at: actor.at, items: items)]
        }, putBackGroup: { _ in done.add("putBackAll"); return nil }, deleteForGood: { _ in done.add("emptyBin") })
        // The page re-reads its records after every change (as the app does): the same fixture records, never an empty Cloud.
        let fixture = shaped(real ? F.realData(now: now) : F.fileManager(now: now))
        let records = fixture.contents
        let model = NativeCloudContentsModel(account: account, read: { records }, files: ops, deletions: deletes)
        var names = fixture.names
        names.memoryAnswer = answer
        let built = try #require(BackendCloudContentsBuilder.build(contents: fixture.contents, snapshot: F.snapshot(now: now), names: names,
                                                                  memoryChanges: changes, now: now))
        model.deleteGateOpen = changes
        model.binGroups = [.init(id: "bin", by: .person, macName: "MacBook Pro", at: now,
                                 items: [.init(id: "memory:" + F.Files.plan, kind: "memory", name: "Plan")])]
        model.show(built.model, handles: built.handles)
        model.undoSeconds = 0.2
        return model
    }
    /// CLOUD-FILES-7: every Undo time in this class is held open by a gate the test opens itself, then the test awaits
    /// the waiting changes; no test sleeps a guessed time for an Undo time.
    func gated(_ model: NativeCloudContentsModel) -> UndoGate {
        let gate = UndoGate()
        model.undoWait = { _ in await gate.wait() }
        return gate
    }
    /// Lets the Undo time end now and waits until every change that was waiting has finished (or seen its cancel).
    func finish(_ waiting: [Task<Void, Never>], _ gate: UndoGate) async {
        await gate.open()
        for task in waiting { await task.value }
    }
    func plan(_ model: NativeCloudContentsModel) throws -> BackendCloudContents.Item {
        try #require(model.model?.items(.memory).first { $0.name == "Plan for the launch" })
    }

    @Test func undoWithinTheTimeAndLeavingThePageCancel() async throws {
        let done = Done()
        let model = try page(done)
        let plan = try plan(model)
        let first = gated(model)
        model.startRemove(plan)
        #expect(model.pending[.remove(itemId: plan.id)] == .init(what: .remove(itemId: plan.id), line: BackendCloudFilesWords.removing))
        var waiting = Array(model.pendingTasks.values)
        model.undo(.remove(itemId: plan.id))
        #expect(model.pending.isEmpty)
        model.startRemove(plan)
        waiting += Array(model.pendingTasks.values)
        model.stop() // leaving the page
        await finish(waiting, first)
        #expect(done.all.isEmpty, "nothing was removed: Undo and leaving the page both cancel")
        // Left alone, it goes to the Bin after its time, and only then.
        let second = gated(model)
        model.startRemove(plan)
        let left = Array(model.pendingTasks.values)
        await Task.yield()
        #expect(done.all.isEmpty, "not while the Undo time is open")
        await finish(left, second)
        #expect(done.all.count == 1 && done.all[0].hasPrefix("remove ") && done.all[0].hasSuffix(F.Files.plan))
    }

    @Test func emptyBinIsOneManualPressAndCleanUpKeepsItsUndoTime() async throws {
        let done = Done()
        let model = try page(done)
        model.startEmptyBin()
        for task in Array(model.pageTasks.values) { await task.value }
        #expect(done.all == ["emptyBin"])
        let other = Done()
        let again = try page(other)
        #expect(again.model?.versionsToClean == 3)
        let gate = gated(again)
        again.startCleanUp()
        let cleaning = Array(again.pendingTasks.values)
        #expect(other.all.isEmpty)
        await finish(cleaning, gate)
        #expect(other.all == ["cleanUp"])
    }

    /// B6: a second change within the 10 seconds never cancels the first: each has its own Undo, and both complete.
    @Test func twoWaitingChangesBothCompleteOrEachIsUndone() async throws {
        let done = Done()
        let model = try page(done)
        let plan = try plan(model)
        let handoff = try #require(model.model?.items(.memory).first { $0.name == "Hand-off to design" })
        // CLOUD-FILES-6 (failed once in a full run): the Undo time is held open by a gate the test opens itself, and the
        // test waits for the waiting changes to finish, never for a guessed number of milliseconds.
        let gate = gated(model)
        model.startRemove(plan)
        model.startRemove(handoff)
        model.startCleanUp()
        #expect(model.pending.count == 3)
        let waiting = Array(model.pendingTasks.values)
        model.undo(.cleanUp)
        #expect(model.pending.count == 2)
        #expect(done.all.isEmpty, "nothing happens while the Undo time is open")
        await finish(waiting, gate)
        #expect(done.all.filter { $0.hasPrefix("remove ") }.count == 2)
        #expect(!done.all.contains { $0 == "cleanUp" })
        #expect(model.pending.isEmpty)
    }
    /// Holds every waiting change's Undo time open until `open()`.
    actor UndoGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }

    @Test func closedGateRefusesOnlyCloudAndKeepsEverywhereAvailable() async throws {
        let done = Done()
        let model = try page(done, changes: false)
        let plan = try plan(model)
        #expect(plan.canRemove)
        model.startDelete([plan], scope: .cloud)
        #expect(model.pending.isEmpty)
        let gate = gated(model)
        model.startDelete([plan], scope: .everywhere)
        #expect(model.pending.count == 1)
        await finish(Array(model.pendingTasks.values), gate)
        #expect(done.all == ["remove " + F.Files.plan])
    }

    @Test func oldMissingCountsNeverProduceADeleteQuestion() throws {
        let model = try page(Done(), answer: DeckMemoryAnswer(missing: 62, held: 1, heldFrom: F.pro))
        #expect(model.model?.answerLine == nil)
        #expect(model.model?.missingLine == nil)
    }

    @Test func aRemoteControlPressCannotOperateTheManualBin() async throws {
        let done = Done()
        let model = try page(done)
        let saved = NativeCloudSheetGuard.shared.remote
        defer { NativeCloudSheetGuard.shared.remote = saved }
        NativeCloudSheetGuard.shared.remote = BackendRemoteInputGuard(lastPost: { 1_000_000_000 }, now: { 1_000_000_000 })
        model.startEmptyBin()
        #expect(model.pageTasks.isEmpty)
        #expect(done.all.isEmpty)
    }

    /// The fixture's instruction file as his real records name it: `file/<place>/<path inside the place>`
    /// (`BackendCloudDeletePage.targets` reads its place from that form; the fixture's bare "CLAUDE.md" is an old shape).
    static func realShapedInstructions(_ fixture: (contents: CloudSyncContents, names: BackendCloudContentsNames))
        -> (contents: CloudSyncContents, names: BackendCloudContentsNames) {
        let place = BackendCloudBootFiles.sourceId(kind: .project, identity: F.project)
        let items = fixture.contents.items.map { item -> CloudSyncContents.Item in
            guard item.key.domain == CloudBootFilesFormat.domain, !item.key.recordId.hasPrefix("file/") else { return item }
            let key = CloudSyncContents.Key(domain: item.key.domain, sourceId: "files/I09/" + place,
                                            recordId: "file/" + place + "/" + item.key.recordId, projectId: item.key.projectId)
            return .init(key: key, changes: item.changes, standing: item.standing, reason: item.reason, bytes: item.bytes, seq: item.seq)
        }
        let base = fixture.contents
        return (CloudSyncContents(thisDevice: base.thisDevice, items: items, packs: base.packs, held: base.held, refused: base.refused,
                                  notSent: base.notSent, queued: base.queued), fixture.names)
    }

    @Test func openShowsTheTextAndUseThisVersionMakesItNewest() async throws {
        let done = Done()
        let model = try page(done, shaped: Self.realShapedInstructions)
        let plan = try plan(model)
        model.choose(plan)
        await model.open()
        #expect(model.opened?.text == "# Text of " + (F.Files.plan as NSString).lastPathComponent)
        // One rule phase 2: an earlier version is a kept text; Show reads it from the keeper, Use passes its keeper id.
        let newest = try #require(plan.versions.first)
        model.versionChosen = newest.id
        await model.open()
        #expect(model.opened?.text == "# Kept " + String(F.Kept.plan[2].prefix(4)) + " of " + (F.Files.plan as NSString).lastPathComponent)
        model.useChosenVersion()
        try await Task.sleep(for: .milliseconds(300))
        #expect(done.all == ["use " + F.Files.plan + " <- " + F.Kept.plan[2]])
        // After the page read its records again (with this Mac's own names: the fixture's project has no folder here),
        // the instruction file still has its row: a file whose project folder is not there yet never vanishes.
        #expect(model.reads >= 1)
        #expect(NativePROJLabels.shared.projects.allSatisfy { $0.id != F.project })
        // Instruction files now use the same scoped controls as memory files.
        let claude = try #require(model.model?.items(.instructionFiles).first)
        #expect(claude.name == "Instructions for Claude")
        #expect(claude.canRemove)
        #expect(claude.deleteItems.first?.kind == "boot")
        // A note's own label block is never shown.
        #expect(NativeCloudContentsModel.shownText("---\nid: n-1\nseat: hoot\n---\n# Plan\nWords.\n") == "# Plan\nWords.")
    }

    /// CLOUD-FILES-4: an instruction file whose folder is not on this Mac says so in one plain line (never an empty
    /// area); a long file cut in the middle of a letter still shows its text.
    @Test func instructionFileTextOrOnePlainLine() async throws {
        let model = try page(Done(), changes: false, real: true)
        let codex = try #require(model.model?.items(.instructionFiles).first { $0.name == "Instructions for Codex" })
        #expect(model.localFile(codex) == nil) // the fixture's project has no folder on this Mac
        model.choose(codex)
        await model.open()
        #expect(model.opened?.text == nil)
        #expect(model.opened?.line == NativeCloudContentsModel.textNotHere)
        // "é" is two bytes: cut after its first byte, the read keeps everything before it and says there is more.
        var data = Data(repeating: UInt8(ascii: "a"), count: 9)
        data.append(contentsOf: Array("é".utf8))
        #expect(NativeCloudContentsModel.previewText(data, limit: 10) == String(repeating: "a", count: 9) + "\n…")
        #expect(NativeCloudContentsModel.previewText(Data("short".utf8), limit: 10) == "short")
        #expect(NativeCloudContentsModel.previewText(Data([0x61, 0x00, 0x62]), limit: 10) == nil)
        // The row's state and date are their own lines, in full.
        let defect = try #require(model.model?.items(.memory).first { $0.name == BackendCloudContentsFixture.Real.defectTitle })
        #expect(NativeCloudContentsRow.presence(defect) == "On this Mac")
        #expect(NativeCloudContentsRow.dateLine(defect) == BackendCloudContentsWords.time(defect.changedAt))
        #expect(NativeCloudContentsRow.placeLine(defect) == "Terminal Deck")
    }

    /// Cloud file manager (design section 9): the reading pane is 340 points and never takes the list below its minimum;
    /// a chosen earlier version heads the pane with its own title, Mac and time.
    @Test func detailsWidthAndTheChosenVersionsHeader() throws {
        typealias B = NativeCloudContentsBrowser
        #expect(B.detailWidth(total: 1_180) == 340)
        #expect(B.detailWidth(total: 1_600) == 340, "a fixed reading width, as Finder's")
        #expect(1_180 - B.sidebarWidth - B.detailWidth(total: 1_180) >= B.listMinimum)
        #expect(780 - B.sidebarWidth - B.detailWidth(total: 780) >= B.listMinimum, "the list keeps its minimum when narrow")
        let model = try page(Done(), changes: false, real: true)
        let defect = try #require(model.model?.items(.memory).first { $0.name == BackendCloudContentsFixture.Real.defectTitle })
        let earlier = try #require(defect.versions.first)
        model.choose(defect)
        model.versionChosen = earlier.id
        #expect(model.chosenVersion?.title == BackendCloudContentsFixture.Real.defectOldTitle)
        let line = BackendCloudFilesWords.chosenVersion(earlier)
        #expect(line.hasPrefix("Earlier version from ") && line.hasSuffix(BackendCloudContentsWords.time(earlier.at)))
        #expect(!line.contains(BackendCloudContentsWords.time(defect.changedAt)) || earlier.at == defect.changedAt)
    }

    @Test func picturesOfThePageLightAndDarkNormalAndNarrow() throws {
        let model = try page(Done(), changes: false)
        let plan = try plan(model)
        // CLOUD-FILES-4: the same page on his real kind of data.
        let real = try page(Done(), changes: false, real: true)
        let defect = try #require(real.model?.items(.memory).first { $0.name == BackendCloudContentsFixture.Real.defectTitle })
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Deck Dev/notes/cloud-test-20261112/cloud-view").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sizes: [(String, NSSize)] = [("normal", NSSize(width: 1240, height: 860)), ("narrow", NSSize(width: 820, height: 640))]
        let shots: [(String, () -> Void)] = [
            ("memory-version", {
                model.chooseShelf(kind: .memory)
                model.choose(plan)
                model.versionChosen = plan.versions.first?.id
                model.opened = NativeCloudOpened(itemId: plan.id, versionId: plan.versions.first?.id,
                                                 text: "# Plan for the launch\n\nShip the Mac app on Friday; the phones follow next week.")
            }),
            ("instruction-files", { model.chooseShelf(kind: .instructionFiles); model.choose(model.model?.items(.instructionFiles).first) }),
            // A replaced note with another title, its earlier version chosen ("Earlier: …", its own date).
            ("real-replaced-note", {
                real.chooseShelf(kind: .memory)
                real.choose(defect)
                real.versionChosen = defect.versions.first?.id
                real.opened = NativeCloudOpened(itemId: defect.id, versionId: defect.versions.first?.id,
                                                text: "# " + BackendCloudContentsFixture.Real.defectOldTitle + "\n\nThe sheet's bottom corners are flat.")
            }),
            // CLOUD-FILES-6: the diary as one row that says what it is.
            ("real-diary", {
                real.chooseShelf(kind: .memory)
                let diary = real.model?.items(.memory).first { $0.name == "Diary" }
                real.choose(diary)
                real.opened = diary.map { NativeCloudOpened(itemId: $0.id, versionId: nil, text: nil) }
            }),
            // Instruction files named by what they are; the open one says in one line why its text is not shown.
            ("real-instruction-files", {
                real.chooseShelf(kind: .instructionFiles)
                let journal = real.model?.items(.instructionFiles).first { $0.name == "critic · Journal" }
                real.choose(journal)
                real.opened = journal.map { NativeCloudOpened(itemId: $0.id, versionId: nil, text: nil, line: NativeCloudContentsModel.textNotHere) }
            }),
        ]
        for (name, setUp) in shots {
            setUp()
            let shown = name.hasPrefix("real-") ? real : model
            for (sizeName, size) in sizes {
                for dark in [false, true] {
                    let view = NativeCloudContentsPage(model: shown, live: false).environment(\.colorScheme, dark ? .dark : .light)
                        .frame(width: size.width, height: size.height).background(DeckTokens.page)
                    let host = NSHostingView(rootView: view)
                    host.sizingOptions = []
                    host.frame = NSRect(origin: .zero, size: size)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.layoutSubtreeIfNeeded()
                    let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: image)
                    let png = try #require(image.representation(using: .png, properties: [:]))
                    try png.write(to: folder.appendingPathComponent("cloud-files-\(name)-\(sizeName)-\(dark ? "dark" : "light").png"))
                    #expect(image.pixelsWide >= Int(size.width))
                }
            }
        }
    }
}
