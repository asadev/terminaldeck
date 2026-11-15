import AppKit
import SwiftUI
import Testing
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Scratch values and recorded page operations only. No app, account service, keeper or real folder is opened.
@MainActor
enum CloudBinPageFixture {
    typealias F = BackendCloudContentsFixture
    static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    static let files = NativeCloudFileOps(text: { _ in "# A plan" }, keptText: { _, _ in nil }, useVersion: { _, _ in },
        remove: { _, _ in }, putBack: { _ in }, emptyBin: { 0 }, cleanUp: { 0 }, counts: { (0, 0) })

    static func built(now: Int64) throws -> (model: BackendCloudContents, handles: [String: BackendCloudContentsHandle]) {
        let rows: [(String, String, String, String?)] = [
            ("brain/memory/i01", "memory", "file/notes/plan.md", nil),
            ("brain/memory/i01", "memory", "file/notes/design.md", nil),
            (CloudFolderFormat.domain, "files/I24", "file/folder/Plans/proposal.md", nil),
            (CloudArtifactsFormat.domain, "files/I23", "file/artifacts/site/reports/weekly.html", nil),
            ("projects", "project-list", "project:" + F.project, nil),
            ("agents", "agent-list", "agent:" + F.agent, nil),
            ("tasks", "task-list", "task:local:fixture", nil),
            (CloudBootFilesFormat.domain, "files/I09/project/abc", "file/project/abc/AGENTS.md", F.project)
        ]
        let items = rows.map { row in CloudSyncContents.Item(key: .init(domain: row.0, sourceId: row.1, recordId: row.2, projectId: row.3),
            changes: [.init(deviceId: F.mac, at: now - 60_000)], standing: .inCloud) }
        let records = CloudSyncContents(thisDevice: F.mac, items: items, packs: [], held: [], refused: [])
        var names = F.names
        names.notes = ["notes/plan.md": "Plan for the launch", "notes/design.md": "Design review"]
        names.tasks = ["local:fixture": "Review the launch"]
        return try #require(BackendCloudContentsBuilder.build(contents: records, snapshot: F.snapshot(now: now), names: names, now: now))
    }
    static func page(marks: [CloudNotHereItem] = [], groups: [CloudBinGroup] = [], gate: Bool = true,
                     ops: NativeCloudDeleteOps? = nil) throws -> NativeCloudContentsModel {
        let now = now, account = NativeCloudAccount()
        account.fixtureSnapshot(F.snapshot(now: now))
        let built = try built(now: now)
        let state = NativeCloudDeleteOps.Read(marks: marks, groups: groups, gateOpen: gate)
        let deletes = ops ?? NativeCloudDeleteOps(read: { _ in state })
        let model = NativeCloudContentsModel(account: account, read: { .empty }, files: files, deletions: deletes)
        model.deleteGateOpen = gate
        model.binGroups = BackendCloudDeletePage.merge(groups)
        model.show(BackendCloudDeletePage.applying(marks, groups: groups, to: built.model), handles: built.handles)
        return model
    }
    static func item(_ name: String = "Plan for the launch", id: String = "memory:notes/plan.md", kind: String = "memory") -> CloudDeleteItem {
        .init(id: id, kind: kind, name: name, place: kind == "memory" ? "notes/plan.md" : nil)
    }
    static func group(_ id: String = "routing-group", by: CloudDeleteBy = .ai, count: Int = 214, era: CloudBinEra = .current) -> CloudBinGroup {
        .init(id: id, by: by, macName: by == .ai ? "Mac mini" : "MacBook Pro", session: by == .ai ? "Night work" : nil,
              at: now - (by == .ai ? 60_000 : 86_400_000), items: (0..<count).map { item("Launch note \($0 + 1)", id: "memory:notes/launch-\($0).md") }, era: era)
    }
    static func finish(_ model: NativeCloudContentsModel) async {
        for task in Array(model.pageTasks.values) { await task.value }
    }
    /// The same NSHostingView bitmap mechanism used by the existing Cloud page picture tests.
    static func picture(_ model: NativeCloudContentsModel, file: String, dark: Bool = false) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // `macos/night/codex/delrule-pictures/` of the checkout that runs the test; DELRULE_PICTURES overrides it (the
        // integrator builds in td-mac-next and may point it at the main checkout's folder the lead reads).
        let output = ProcessInfo.processInfo.environment["DELRULE_PICTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? package.deletingLastPathComponent().appendingPathComponent("night/codex/delrule-pictures")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let size = NSSize(width: 1240, height: 860)
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
        try png.write(to: output.appendingPathComponent(file))
        #expect(image.pixelsWide >= Int(size.width))
    }
}

@Suite("The manual Bin and scoped Cloud row controls")
@MainActor
struct CloudBinPageTests {
    typealias P = CloudBinPageFixture
    actor Calls {
        var deleted: [([CloudDeleteItem], CloudDeleteScope, CloudDeleteActor)] = []
        var restored: [CloudBinGroup] = []
        var single: [CloudDeleteItem] = []
        var purged: [[CloudDeleteItem]] = []
        var brought: [([CloudDeleteItem], CloudBringBackDestination)] = []
        func remove(_ items: [CloudDeleteItem], scope: CloudDeleteScope, actor: CloudDeleteActor) { deleted.append((items, scope, actor)) }
        func restore(_ group: CloudBinGroup) { restored.append(group) }
        func restoreOne(_ item: CloudDeleteItem) { single.append(item) }
        func purge(_ items: [CloudDeleteItem]) { purged.append(items) }
        func bring(_ items: [CloudDeleteItem], to: CloudBringBackDestination) { brought.append((items, to)) }
    }
    func ops(_ calls: Calls) -> NativeCloudDeleteOps {
        .init(read: { _ in .init(gateOpen: true) }, delete: { items, scope, actor in
            await calls.remove(items, scope: scope, actor: actor)
            return [.init(id: actor.group, by: actor.by, macName: actor.macName, at: actor.at, items: items)]
        }, bringBack: { items, destination in await calls.bring(items, to: destination); return items },
        putBackGroup: { await calls.restore($0); return nil }, putBackItem: { item, _ in await calls.restoreOne(item) },
        deleteForGood: { await calls.purge($0) })
    }

    @Test func groupsMergeAcrossKindsAndCountEachItemOnce() {
        let at = P.now, memory = P.item(), artifact = P.item("Weekly report", id: "site/report.html", kind: "artifacts")
        let first = CloudBinGroup(id: "one", by: .ai, macName: "Mac mini", session: "Night work", at: at, items: [memory])
        let second = CloudBinGroup(id: "one", by: .ai, macName: "Mac mini", session: "Night work", at: at, items: [artifact, memory])
        let groups = BackendCloudDeletePage.merge([first, second])
        #expect(groups.count == 1 && groups[0].count == 2)
        #expect(Set(groups[0].items.map(\.kind)) == ["memory", "artifacts"])
    }
    @Test func erasNamesAndDatesNeverDisplayRoutingIdentities() {
        for era in [CloudBinEra.current, .olderVersion, .beforeNewRule] {
            let group = P.group("8b156633-04ec-4960-bf8d-dc74802e01ab", count: 2, era: era)
            let line = BackendCloudDeletePage.groupLine(group)
            #expect(!line.contains(group.id))
            #expect(!line.contains(group.items[0].id))
            #expect(line.contains("2 items"))
            switch era {
            case .current: #expect(line.contains("Removed by an AI on Mac mini · Night work"))
            case .olderVersion: #expect(line.contains("Removed on Mac mini (older version)"))
            case .beforeNewRule: #expect(line.contains("Before the new rule"))
            }
        }
    }
    @Test func putBackAllIsOneManualOperationForTheWholeGroup() async throws {
        let calls = Calls(), group = P.group(count: 214)
        let page = try P.page(groups: [group], ops: ops(calls))
        page.putBackGroup(group)
        page.putBackGroup(group) // an in-flight press cannot duplicate the restore
        #expect(page.busyBin.contains(group.id))
        await P.finish(page)
        #expect(await calls.restored == [group])
        #expect(page.busyBin.isEmpty)
    }
    @Test func aRowPutBackAndDeleteForGoodNameOnlyThatItem() async throws {
        let calls = Calls(), group = P.group(count: 3), item = group.items[1]
        let page = try P.page(groups: [group], ops: ops(calls))
        page.putBackBinItem(item, group: group)
        await P.finish(page)
        page.deleteForGood([item])
        await P.finish(page)
        #expect(await calls.single == [item])
        #expect(await calls.purged == [[item]])
    }
    @Test func emptyBinCapturesOnlyTheGroupsShownAtThePress() async throws {
        let calls = Calls(), group = P.group(count: 3)
        let page = try P.page(groups: [group], ops: ops(calls))
        page.startEmptyBin()
        page.binGroups.append(P.group("later", count: 2))
        await P.finish(page)
        #expect(await calls.purged == [group.items])
    }
    @Test func selectedRowsUseOneCallOneActorAndTenSecondsOfUndo() async throws {
        let calls = Calls(), page = try P.page(ops: ops(calls))
        let rows = try #require(page.model?.items(.memory))
        page.selection = Set(rows.map(\.id))
        let gate = CloudFilesUITests.UndoGate()
        page.undoWait = { seconds in #expect(seconds == 10); await gate.wait() }
        page.startDelete(page.deleteSelection(for: rows[0]), scope: .cloud)
        #expect(page.pending.count == 1)
        #expect(await calls.deleted.isEmpty)
        let waiting = Array(page.pendingTasks.values)
        await gate.open()
        for task in waiting { await task.value }
        let removed = await calls.deleted
        #expect(removed.count == 1 && removed[0].0.count == 2 && removed[0].1 == .cloud)
        #expect(removed[0].2.by == .person && UUID(uuidString: removed[0].2.group) != nil)
    }
    @Test func undoCancelsTheEntireSelectedGroup() async throws {
        let calls = Calls(), page = try P.page(ops: ops(calls))
        let rows = try #require(page.model?.items(.memory))
        let gate = CloudFilesUITests.UndoGate()
        page.undoWait = { _ in await gate.wait() }
        page.startDelete(rows, scope: .everywhere)
        let what = try #require(page.pending.keys.first), waiting = Array(page.pendingTasks.values)
        page.undo(what)
        await gate.open()
        for task in waiting { await task.value }
        #expect(await calls.deleted.isEmpty)
        #expect(page.pendingRows.isEmpty)
    }
    @Test func tasksAndAgentsRefuseCloudEvenIfTheGateIsOpen() throws {
        let page = try P.page()
        let tasks = try #require(page.model?.items(.tasks)), agents = try #require(page.model?.items(.agents))
        #expect(!tasks.isEmpty && !agents.isEmpty)
        page.startDelete(tasks, scope: .cloud)
        page.startDelete(agents, scope: .cloud)
        #expect(page.pending.isEmpty)
    }
    @Test func bothMarksKeepTheirNamedRowsAndExplicitDestinations() async throws {
        let calls = Calls()
        let marks = [CloudNotHereItem(item: P.item(), mark: .notOnThisMac, at: P.now),
                     CloudNotHereItem(item: P.item("Saved design", id: "memory:notes/saved.md"), mark: .onlyOnThisMac, at: P.now)]
        let page = try P.page(marks: marks, ops: ops(calls))
        let missing = try #require(page.model?.items(.memory).first { $0.localMark == .notOnThisMac })
        let local = try #require(page.model?.items(.memory).first { $0.localMark == .onlyOnThisMac })
        #expect(NativeCloudContentsRow.presence(missing) == CloudDeleteWords.notOnThisMac)
        #expect(NativeCloudContentsRow.presence(local) == CloudDeleteWords.onlyOnThisMac)
        // Pictures review (15 Nov): the row's end is two lines, the first one state and date together.
        #expect(NativeCloudContentsRow.stateAndDate(missing) == CloudDeleteWords.notOnThisMac + " · " + NativeCloudContentsRow.dateLine(missing))
        page.bringBack([missing], to: .thisMac)
        await P.finish(page)
        page.bringBack([local], to: .cloud)
        await P.finish(page)
        #expect(await calls.brought.map { $0.1 } == [.thisMac, .cloud])
    }
    @Test func folderAndArtifactsAreIndividualRowsWithTheirOwnersPaths() throws {
        let built = try P.built(now: P.now)
        let folder = try #require(built.model.items(.cloudFolder).first), artifact = try #require(built.model.items(.artifacts).first)
        #expect(folder.name == "proposal.md" && folder.deleteItems.first?.id == "Plans/proposal.md")
        #expect(artifact.name == "weekly.html" && artifact.deleteItems.first?.id == "site/reports/weekly.html")
        #expect(folder.canRemove && artifact.canRemove)
    }
    @Test func sealedBinKindsRouteToTheirSourceAndPutBackAloneOnlyWhenWhole() {
        let login = CloudDeleteItem(id: "rec-1", kind: "saved-passwords", name: "Server login", place: "voice")
        let key = CloudDeleteItem(id: "rec-2", kind: "saved-passwords", name: "SSH key", place: "voice")
        #expect(BackendCloudDeletePage.route(login) == "secrets|voice")
        #expect(BackendCloudDeletePage.kind(login) == .passwords)
        let agent = CloudDeleteItem(id: "agent:a1", kind: "agent", name: "Decker", place: nil)
        let group = CloudBinGroup(id: "g", by: .person, macName: "Mac mini", at: P.now, items: [login, key, agent, P.item()])
        #expect(!BackendCloudDeletePage.canPutBackAlone(login, in: group)) // two from one source: Put back all only
        #expect(BackendCloudDeletePage.canPutBackAlone(agent, in: group))  // that owner's whole part of the removal
        #expect(BackendCloudDeletePage.canPutBackAlone(P.item(), in: group)) // memory puts back one file
    }
    @Test func sidecarsNeverBecomeRows() throws {
        let now = P.now
        let items = [CloudFolderFormat.domain, CloudArtifactsFormat.domain, CloudBootFilesFormat.domain].map { domain in
            CloudSyncContents.Item(key: .init(domain: domain, sourceId: "files", recordId: "about/group", projectId: nil),
                                   changes: [.init(deviceId: P.F.mac, at: now)], standing: .inCloud)
        }
        let records = CloudSyncContents(thisDevice: P.F.mac, items: items, packs: [], held: [], refused: [])
        let built = try #require(BackendCloudContentsBuilder.build(contents: records, snapshot: P.F.snapshot(now: now), now: now))
        #expect(built.model.items.isEmpty)
    }
    @Test func binItemsAreAbsentFromTheKindsAndToolWire() throws {
        let group = CloudBinGroup(id: "group", by: .person, macName: "Mac mini", at: P.now, items: [P.item()])
        let page = try P.page(groups: [group])
        #expect(page.model?.items(.memory).contains { $0.name == "Plan for the launch" } == false)
        #expect(page.binGroups.count == 1)
        #expect(page.model?.wireValue()["items"].elements?.contains { $0["name"].string == "Plan for the launch" } == false)
    }
    /// Required review pictures. Written when integration runs this test, never by a lane build or app launch.
    @Test func picturesOfTheTwoButtonsBothMarksAndTheGroupedBin() throws {
        let plain = try P.page()
        let missing = try P.page(marks: [.init(item: P.item(), mark: .notOnThisMac, at: P.now)])
        let local = try P.page(marks: [.init(item: P.item(), mark: .onlyOnThisMac, at: P.now)])
        let bin = try P.page(groups: [P.group(), P.group("person", by: .person, count: 3)])
        bin.chooseShelf(kind: nil)
        for (name, model) in [("your-cloud-list", plain), ("not-on-this-mac", missing), ("only-on-this-mac", local), ("bin-groups", bin)] {
            try P.picture(model, file: name + ".png")
            try P.picture(model, file: name + "-dark.png", dark: true)
        }
    }
}
