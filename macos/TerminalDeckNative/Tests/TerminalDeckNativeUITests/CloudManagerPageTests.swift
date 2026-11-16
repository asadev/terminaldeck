import AppKit
import SwiftUI
import Testing
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Cloud file manager (owner, 15 Nov, items 26, 27, 30; design section 9). Made-up records and recorded page operations
/// only: no app, account service, keeper, Keychain or real folder is opened.
@MainActor
enum CloudManagerFixture {
    typealias F = BackendCloudContentsFixture
    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let lead = "projects/" + F.project + "/"
    static let files = NativeCloudFileOps(text: { _ in "# Plan for the launch\n\nShip the Mac app on Friday; the phones follow next week." },
        keptText: { _, _ in nil }, useVersion: { _, _ in }, remove: { _, _ in }, putBack: { _ in }, emptyBin: { 0 }, cleanUp: { 0 }, counts: { (0, 0) })

    static func record(_ domain: String, _ source: String, _ record: String, project: String? = nil, minutesAgo: Int64 = 1, now: Int64) -> CloudSyncContents.Item {
        .init(key: .init(domain: domain, sourceId: source, recordId: record, projectId: project),
              changes: [.init(deviceId: F.mac, at: now - minutesAgo * 60_000)], standing: .inCloud)
    }
    static func built(now: Int64) throws -> (model: BackendCloudContents, handles: [String: BackendCloudContentsHandle]) {
        var names = F.names
        names.agents["decker"] = "Decker"
        names.agents["rita"] = "Rita"
        names.notes = [lead + "roles/decker/notes/2026-11-14-plan-for-the-launch-k3m9pq.md": "Plan for the launch",
                       lead + "roles/decker/notes/2026-11-13-design-review-a1b2c3.md": "Design review",
                       lead + "roles/decker/topics/2026-11-10-release-steps-q1q1q1.md": "Release steps",
                       lead + "roles/rita/notes/2026-11-11-review-list-r2r2r2.md": "Review list",
                       lead + "lead/notes/2026-11-12-weekly-plan-z9z9z9.md": "Weekly plan"]
        names.tasks = ["local:launch": "Ship the Mac app", "local:phones": "Ship the phones", "local:site": "New website pictures",
                       "local:loose": "Water the plants"]
        names.passwords = ["github": "GitHub", "openai": "OpenAI", "mini": "Mac mini"]
        let values: [(String, NativeRPCValue)] = [("setting:appearance.theme", .string("dark")), ("setting:appearance.terminalFontSize", .number(13)),
            ("setting:appearance.reduceMotion", .bool(false)), ("preference:theme", .string("system")), ("setting:appearance.fontSize", .number(13)),
            ("preference:notifyOnComplete", .bool(true)), ("setting:notifications.soundName", .string("chime")),
            ("setting:copilot.menuBar", .bool(true)), ("setting:general.autoNameSessions", .bool(true))]
        for (record, value) in values { names.settingValues[record] = BackendCloudManagerSettings.value(recordId: record, value) }
        let memory = ["roles/decker/notes/2026-11-14-plan-for-the-launch-k3m9pq.md", "roles/decker/notes/2026-11-13-design-review-a1b2c3.md",
                      "roles/decker/topics/2026-11-10-release-steps-q1q1q1.md", "roles/decker/card.md", "roles/rita/notes/2026-11-11-review-list-r2r2r2.md",
                      "roles/rita/card.md", "lead/notes/2026-11-12-weekly-plan-z9z9z9.md"]
        var items: [CloudSyncContents.Item] = memory.enumerated().map { index, path in
            record("brain/memory/i01", "memory", "file/" + lead + path, project: F.project, minutesAgo: Int64(5 + index * 37), now: now)
        }
        items += [record("brain/memory/i01", "memory", "file/hoot/card.md", minutesAgo: 400, now: now),
                  record("brain/memory/i02", "memory", "row/diary/1", minutesAgo: 2, now: now),
                  record("brain/memory/i02", "memory", "row/diary/2", minutesAgo: 3, now: now),
                  record(BackendCloudKindsTasks.domain, "task-list", "task:local:launch", project: F.project, now: now),
                  record(BackendCloudKindsTasks.domain, "task-list", "task:local:phones", project: F.project, minutesAgo: 90, now: now),
                  record(BackendCloudKindsTasks.domain, "task-list", "task:local:site", project: F.project, minutesAgo: 600, now: now),
                  record(BackendCloudKindsTasks.domain, "task-list", "task:local:loose", minutesAgo: 3_000, now: now),
                  record(CloudSecretsDomain.apiKey.rawValue, "api-keys", "github", minutesAgo: 900, now: now),
                  record(CloudSecretsDomain.apiKey.rawValue, "api-keys", "openai", minutesAgo: 1_900, now: now),
                  record(CloudSecretsDomain.server.rawValue, "servers", "mini", minutesAgo: 2_900, now: now)]
        items += values.enumerated().map { index, value in
            record(BackendCloudKindsSettings.domain, BackendCloudKindsSettings.sourceID, value.0, minutesAgo: Int64(60 + index * 300), now: now)
        }
        let contents = CloudSyncContents(thisDevice: F.mac, items: items, packs: [], held: [], refused: [])
        return try #require(BackendCloudContentsBuilder.build(contents: contents, snapshot: F.snapshot(now: now), names: names, now: now))
    }
    static func page(groups: [CloudBinGroup] = [], marks: [CloudNotHereItem] = [], ops: NativeCloudDeleteOps? = nil) throws -> NativeCloudContentsModel {
        let now = now, account = NativeCloudAccount()
        account.fixtureSnapshot(F.snapshot(now: now))
        let built = try built(now: now)
        let state = NativeCloudDeleteOps.Read(marks: marks, groups: groups, gateOpen: true)
        let model = NativeCloudContentsModel(account: account, read: { .empty }, files: files, deletions: ops ?? NativeCloudDeleteOps(read: { _ in state }))
        model.deleteGateOpen = true
        model.binGroups = BackendCloudDeletePage.merge(groups)
        model.show(BackendCloudDeletePage.applying(marks, groups: groups, to: built.model), handles: built.handles)
        return model
    }
    static func finish(_ model: NativeCloudContentsModel) async {
        for task in Array(model.pageTasks.values) { await task.value }
    }
    /// `macos/night/codex/cloud-manager-evidence/` of the checkout that runs the test; CLOUD_MANAGER_PICTURES overrides it.
    static func picture(_ model: NativeCloudContentsModel, file: String) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = ProcessInfo.processInfo.environment["CLOUD_MANAGER_PICTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? package.deletingLastPathComponent().appendingPathComponent("night/codex/cloud-manager-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = NSSize(width: 1240, height: 760)
        for dark in [false, true] {
            let view = NativeCloudContentsPage(model: model, live: false).environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height).background(DeckTokens.page)
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.layoutSubtreeIfNeeded()
            let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: image)
            let png = try #require(image.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent(file + "-" + (dark ? "dark" : "light") + ".png"))
            #expect(image.pixelsWide >= Int(size.width))
        }
    }
}

@Suite("The Cloud file manager")
@MainActor
struct CloudManagerPageTests {
    typealias P = CloudManagerFixture
    actor Calls {
        var deleted: [([CloudDeleteItem], CloudDeleteScope)] = []
        func remove(_ items: [CloudDeleteItem], _ scope: CloudDeleteScope) { deleted.append((items, scope)) }
    }
    func ops(_ calls: Calls) -> NativeCloudDeleteOps {
        .init(read: { _ in .init(gateOpen: true) }, delete: { items, scope, actor in
            await calls.remove(items, scope)
            return [.init(id: actor.group, by: actor.by, macName: actor.macName, at: actor.at, items: items)]
        })
    }

    @Test func memoryOpensAtItsTopWithFoldersFirst() throws {
        let page = try P.page()
        page.chooseShelf(kind: .memory)
        #expect(page.listing.folders.map(\.name) == ["Hoot", "Terminal Deck"])
        #expect(page.listing.files.map(\.name) == ["Diary"])
        #expect(page.crumbs.map(\.title) == ["Memory"])
        #expect(BackendCloudManagerTree.count(try #require(page.model), kind: .memory) == 9, "the place's number is what it holds")
    }

    @Test func aDoubleClickGoesInsideAndTheCrumbsAndBackForwardFollow() throws {
        let page = try P.page()
        page.chooseShelf(kind: .memory)
        page.activate(BackendCloudManagerTree.folderId(["Terminal Deck"]))
        page.activate(BackendCloudManagerTree.folderId(["Terminal Deck", "Decker"]))
        #expect(page.crumbs.map(\.title) == ["Memory", "Terminal Deck", "Decker"])
        #expect(page.listing.folders.map(\.name) == ["Notes", "Topics"])
        #expect(page.listing.files.map(\.name) == ["Card · Decker"])
        page.goBack()
        #expect(page.path == ["Terminal Deck"])
        page.goForward()
        #expect(page.path == ["Terminal Deck", "Decker"])
        page.go(to: try #require(page.crumbs.first).place)
        #expect(page.path.isEmpty && page.canGoBack && !page.canGoForward)
    }

    @Test func aClickSelectsShiftTakesARangeAndAFolderStandsForEverythingInside() throws {
        let page = try P.page()
        page.chooseShelf(kind: .memory)
        page.openFolder(["Terminal Deck"])
        let keys = page.rowKeys
        page.click(keys[0])
        #expect(page.soleFolder == ["Terminal Deck", "Decker"] && page.selected == nil, "a click selects, it does not open")
        page.click(keys[1], shift: true)
        #expect(page.folderSelection.count == 2)
        #expect(page.selectedRows.count == 5, "Decker's four and the lead's one, once each")
        page.click(keys[0], command: true)
        #expect(page.folderSelection.count == 1)
    }

    @Test func theTopBarActionsFollowTheSelection() throws {
        let page = try P.page()
        page.chooseShelf(kind: .memory)
        page.openFolder(["Terminal Deck", "Decker", "Notes"])
        let greyed = try #require(page.binChoice(for: page.selectedRows))
        #expect(!greyed.enabled && greyed.scopes == [.cloud, .everywhere], "greyed with nothing selected")
        page.click(try #require(page.rowKeys.first))
        #expect(try #require(page.binChoice(for: page.selectedRows)).enabled)
        page.chooseShelf(kind: .tasks)
        page.openFolder(["Terminal Deck"])
        page.selectAll()
        #expect(try #require(page.binChoice(for: page.selectedRows)).scopes == [.everywhere], "tasks: Everywhere only")
        page.chooseShelf(kind: .settings)
        #expect(page.binChoice(for: []) == nil, "settings: no bin actions at all")
    }

    @Test func aFolderIsOneRemovalWithItsUndo() async throws {
        let calls = Calls(), page = try P.page(ops: ops(calls))
        page.chooseShelf(kind: .memory)
        page.openFolder(["Terminal Deck"])
        page.click(BackendCloudManagerTree.folderId(["Terminal Deck", "Rita"]))
        let gate = CloudFilesUITests.UndoGate()
        page.undoWait = { seconds in #expect(seconds == 10); await gate.wait() }
        page.binRows(page.selectedRows, scope: .everywhere)
        #expect(page.pending.count == 1)
        let waiting = Array(page.pendingTasks.values)
        await gate.open()
        for task in waiting { await task.value }
        let removed = await calls.deleted
        #expect(removed.count == 1 && removed[0].0.count == 2 && removed[0].1 == .everywhere)
    }

    @Test func spaceOpensTheReadingPaneAndAPasswordShowsOnlyAfterShow() async throws {
        let page = try P.page()
        page.chooseShelf(kind: .memory)
        page.openFolder(["Terminal Deck", "Decker", "Notes"])
        page.click(try #require(page.rowKeys.first))
        page.toggleReader()
        #expect(page.selectedItem?.name == "Plan for the launch")
        page.toggleReader()
        #expect(page.selected == nil)
        page.chooseShelf(kind: .passwords)
        page.openFolder(["API keys"])
        let key = try #require(page.listing.files.first)
        var asked = 0
        page.secretReveal = { _ in asked += 1; return "made-up-value" }
        page.activate(key.id)
        #expect(page.revealed == nil && asked == 0, "nothing is read before Show")
        page.reveal(key)
        for _ in 0..<50 where page.revealed == nil { await Task.yield() }
        #expect(page.revealed == NativeCloudRevealed(itemId: key.id, value: "made-up-value"))
        page.click(try #require(page.rowKeys.last))
        page.choose(nil)
        #expect(page.revealed == nil, "gone with the selection")
    }

    /// DESIGN-FIXES CM-1, CM-2, CM-4 (15 Nov): the rules that need no picture.
    @Test func theListShowsOnlyWhatHeMustKnow() throws {
        let page = try P.page()
        page.chooseShelf(kind: .memory)
        page.openFolder(["Terminal Deck", "Decker", "Notes"])
        let normal = try #require(page.listing.files.first)
        #expect(normal.localMark == nil)
        #expect(BackendCloudManagerWords.onColumn(normal) == "", "the On column is empty for an item in its normal state")
        // Not yet on other devices: never in the list (onColumn reads only the mark); written in full in the pane.
        #expect(BackendCloudManagerWords.waitingInFull(["Waiting on Office iMac", "Waiting on MacBook Pro"]) == "Not yet on Office iMac and MacBook Pro")
        #expect(page.listing.files.allSatisfy { $0.localMark != nil || BackendCloudManagerWords.onColumn($0) == "" })
        var missing = normal
        missing.localMark = .notOnThisMac
        #expect(BackendCloudManagerWords.onColumn(missing) == CloudDeleteWords.notOnThisMac)
        missing.localMark = .onlyOnThisMac
        #expect(BackendCloudManagerWords.onColumn(missing) == CloudDeleteWords.onlyOnThisMac)
        // A place with nothing in it shows no number; the left list is as wide as the Settings list.
        #expect(NativeCloudPlaces.shownCount(0) == nil && NativeCloudPlaces.shownCount(nil) == nil)
        #expect(NativeCloudPlaces.shownCount(9) == "9")
        #expect(NativeCloudContentsBrowser.sidebarWidth == 215)
        // CM-5: marked rows put their one action where the bin buttons are; a mixed or normal selection keeps the bins.
        if case .bringBack(let rows) = NativeCloudTopBar.markedAction(selected: 2, missing: [1, 2], local: [Int]()) { #expect(rows == [1, 2]) }
        else { Issue.record("two Not on this Mac rows: Bring back") }
        if case .putInCloudAgain = NativeCloudTopBar.markedAction(selected: 1, missing: [Int](), local: [3]) {} else { Issue.record("Put in Cloud again") }
        if case .bin = NativeCloudTopBar.markedAction(selected: 2, missing: [1], local: [Int]()) {} else { Issue.record("mixed: the bins") }
        if case .bin = NativeCloudTopBar.markedAction(selected: 0, missing: [Int](), local: [Int]()) {} else { Issue.record("nothing: the bins") }
        // A note reads formatted.
        #expect(NativeCloudContentsDetail.readsAsNote(normal))
    }

    @Test func picturesOfTheFileManager() throws {
        let page = try P.page()
        page.chooseShelf(kind: .memory)
        try P.picture(page, file: "memory-top")
        page.openFolder(["Terminal Deck", "Decker"])
        try P.picture(page, file: "two-levels-crumbs")
        page.openFolder(["Terminal Deck", "Decker", "Notes"])
        page.click(try #require(page.rowKeys.first))
        page.click(try #require(page.rowKeys.last), command: true)
        try P.picture(page, file: "selection-actions")
        page.click(try #require(page.rowKeys.first))
        page.toggleReader()
        if let item = page.selectedItem {
            page.opened = NativeCloudOpened(itemId: item.id, versionId: nil, text: "# Plan for the launch\n\nShip the Mac app on Friday; the phones follow next week.")
        }
        try P.picture(page, file: "reading-pane")
        // CM-5: a row that is Not on this Mac, selected: "Bring back" stands where the bin buttons are.
        let first = try #require(page.listing.files.first)
        let marked = try P.page(marks: [CloudNotHereItem(item: try #require(first.deleteItems.first), mark: .notOnThisMac, at: P.now)])
        marked.chooseShelf(kind: .memory)
        marked.openFolder(["Terminal Deck", "Decker", "Notes"])
        marked.click(try #require(marked.rowKeys.first))
        try P.picture(marked, file: "marked-action")
        page.chooseShelf(kind: .tasks)
        page.openFolder(["Terminal Deck"])
        try P.picture(page, file: "tasks-rows")
        page.chooseShelf(kind: .settings)
        page.openFolder(["Appearance"])
        try P.picture(page, file: "settings-rows")
        let item = CloudDeleteItem(id: "memory:notes/old.md", kind: "memory", name: "An old idea", place: "notes/old.md")
        let bin = try P.page(groups: [.init(id: "g1", by: .ai, macName: "Mac mini", session: "Night work", at: P.now - 60_000, items: [item]),
                                      .init(id: "g2", by: .person, macName: "MacBook Pro", at: P.now - 86_400_000, items: [item])])
        bin.chooseShelf(kind: nil)
        try P.picture(bin, file: "bin")
    }
}
