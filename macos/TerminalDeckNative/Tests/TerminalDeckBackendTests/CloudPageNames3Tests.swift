import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Page-names 3 (real check 4 of his two Macs on a0b564c2): saved passwords off is one sentence; the page never opens
/// with a count that is not from a current read; the live status board does not travel, so it is never counted; the
/// projects without a folder stay a quiet line with their names.
extension CloudPageNames2Tests {
    private func digits(_ text: String) -> Bool { text.contains { $0.isNumber } }

    // P1. Saved passwords off: no summary row, no "Not saved in this version" block; the section's one sentence only.
    @Test func savedPasswordsOffIsOneSentenceOnly() throws {
        var off = BackendCloudSecretsPage()
        off.standing = .notSetUp
        let page = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 0, automaticTrust: true, passwords: off)))
        let texts = Self.texts(page)
        #expect(page.rows.first { $0.kind == .passwords } == nil)
        #expect(!texts.contains(BackendCloudOverviewWords.passwordsOff))
        #expect(!texts.contains(BackendCloudOverviewWords.title(.passwords)))
        #expect(!texts.contains(BackendCloudOverviewWords.notSavedTitle))
        for line in BackendCloudOverviewWords.notSavedInThisVersion { #expect(!texts.contains(line)) }
        #expect(!texts.contains { $0.localizedCaseInsensitiveContains("saved passwords") })
        #expect(page.standing != .needsYou)
        // The view draws no "Not saved in this version" block any more (the model above cannot see a view's own block).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckNative/NativeCloudOverview.swift"), encoding: .utf8)
        #expect(!view.contains("notSavedTitle"))
        #expect(!view.contains("notSavedInThisVersion"))
        // Set up and protected, the row is back with its own state.
        var on = BackendCloudSecretsPage()
        on.standing = .protected
        let protected = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 0, automaticTrust: true, passwords: on)))
        #expect(protected.rows.first { $0.kind == .passwords } != nil)
    }

    // P2. The first render, before the page's own read: no queue or feed number, "Checking…" instead.
    @Test func theFirstRenderSaysNoNumberThatIsNotFromARead() throws {
        let base = macBook(coverage: macBookCoverage, head: 408, fetched: 407)
        // The snapshot held from an earlier read: 5 changes queued, 1 still to fetch (the Mac mini's first second).
        let stale = CloudAccountSnapshot(phase: base.phase, gate: base.gate, displayName: base.displayName, devices: base.devices,
                                         coverage: base.coverage, waitingRecords: 5, trust: base.trust,
                                         cloudHead: base.cloudHead, fetched: base.fetched)
        var input = macBookInput(held: 0, automaticTrust: true)
        input.snapshot = stale
        input.progressRead = false
        let first = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(first.standing == .checking)
        #expect(first.title == BackendCloudOverviewWords.checking)
        #expect(first.title != BackendCloudOverviewWords.savingAndCatchingUp)
        for line in first.lines { #expect(!digits(line), "\(line)") }
        #expect(!first.lines.contains(BackendCloudOverviewWords.goingUp(5)))
        #expect(!first.lines.contains(BackendCloudOverviewWords.behind(1)))
        for row in first.rows where [.memory, .projects, .bootFiles].contains(row.kind) {
            #expect(row.state == BackendCloudOverviewWords.checking)
            #expect(!digits(row.state))
        }
        // Project folders (14 Nov): nothing about projects without a folder, ever.
        #expect(first.later == nil)
        // Once read, the numbers of that read are said.
        input.progressRead = true
        let read = try #require(BackendCloudOverviewBuilder.build(input))
        #expect(read.lines.contains(BackendCloudOverviewWords.goingUp(5)))
        // And a read that finds nothing waiting is "Up to date"-bound, never busy.
        var level = macBookInput(held: 0, automaticTrust: true)
        level.counts = BackendCloudPageCounts(here: [.notes: 3_525, .diary: 39_994, .topics: 61, .projects: 4, .agents: 77])
        let quiet = try #require(BackendCloudOverviewBuilder.build(level))
        #expect(![.saving, .savingAndCatchingUp, .catchingUp].contains(quiet.standing))
    }

    // P5. The live status board does not travel: no "Board cards" row, no board count, no board in Activity.
    @Test func boardRowsAreNeverListedOrCounted() throws {
        func key(_ table: String, _ id: String) -> CloudSyncContents.Key {
            .init(domain: "brain/memory/i03", sourceId: "memory/I03", recordId: "row/" + table + "/" + id, projectId: nil)
        }
        let note = CloudSyncContents.Key(domain: "brain/memory/i01", sourceId: "memory/I01", recordId: "file/notes/2026-11-13-cloud-check-dtvjwi.md", projectId: nil)
        var items: [CloudSyncContents.Item] = [.init(key: note, changes: [.init(deviceId: Self.mini, at: now - 300_000)], standing: .inCloud, seq: CloudSequence(390))]
        var boardKeys: [CloudSyncContents.Key] = []
        for index in 0..<696 {
            let made = key(index % 2 == 0 ? "board" : "board_history", String(index))
            boardKeys.append(made)
            items.append(.init(key: made, changes: [.init(deviceId: Self.mini, at: now - 200_000)], standing: .inCloud, seq: CloudSequence(400)))
        }
        let contents = CloudSyncContents(thisDevice: Self.book, items: items,
                                         packs: [.init(deviceId: Self.book, at: now - 100_000, arrivedAt: nil, keys: Array(boardKeys.prefix(3)), count: ["brain/memory/i03": 345]),
                                                 .init(deviceId: Self.mini, at: now - 300_000, arrivedAt: now - 290_000, keys: [note], count: ["brain/memory/i01": 1])])
        for counts in [macBookCounts, nil] as [BackendCloudPageCounts?] {
            let window = try #require(BackendCloudContentsBuilder.build(contents: contents, snapshot: macBook(coverage: macBookCoverage),
                                                                        counts: counts, now: now)).model
            let text = window.allText + window.kindLines.values + window.activity.map(\.text)
            #expect(!text.contains { $0.localizedCaseInsensitiveContains("board") })
            #expect(!text.contains { $0.contains("696") || $0.contains("345") })
            #expect(!window.items.contains { $0.name.localizedCaseInsensitiveContains("board") })
            // Integrator: the Mac mini's note pack gives its two usual lines ("sent", then "received ... from"); the board
            // pack (index 0) gives none.
            #expect(window.activity.count == 2)
            #expect(!window.activity.contains { $0.id.hasSuffix("-0") })
            if counts == nil { #expect(window.counts[.memory] == 1) }
        }
    }

    // P6 (project folders, 14 Nov, replaces "a quiet line with names"): the Cloud page shows NO paragraph about folders,
    // neither while four projects wait for the first pass (no folder yet, 293 instruction files waiting) nor once they
    // have just received their folders. Never "needs you" either.
    @Test func theCloudPageSaysNothingAboutFoldersBeforeOrAfterTheyAreMade() throws {
        func folderWords(_ page: BackendCloudOverview) -> [String] {
            Self.texts(page).filter { text in
                ["no folder", "Choose a folder", "choose a folder", "when you choose", "folder you pick", "once their project has a folder",
                 "more than one folder"].contains { text.contains($0) }
            }
        }
        // Waiting for the first pass: the lanes still report four projects without a folder and 293 files for them.
        let waiting = try #require(BackendCloudOverviewBuilder.build(macBookInput(held: 0, automaticTrust: true)))
        #expect(waiting.later == nil)
        #expect(folderWords(waiting).isEmpty, "\(folderWords(waiting))")
        #expect(waiting.waiting.isEmpty)
        #expect(waiting.standing != .needsYou)
        // Just received their folders: nothing left for the lanes to report.
        var placed = macBookInput(held: 0, automaticTrust: true)
        placed.projects = .init()
        placed.bootFiles = .init()
        let after = try #require(BackendCloudOverviewBuilder.build(placed))
        #expect(after.later == nil)
        #expect(folderWords(after).isEmpty, "\(folderWords(after))")
    }
}
