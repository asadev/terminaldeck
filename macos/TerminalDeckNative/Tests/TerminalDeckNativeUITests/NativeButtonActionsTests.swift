import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Inert effects: no app launch, installed data, sessions, network or WebKit page.
@MainActor final class NativeButtonActionsTests: XCTestCase {
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"
    private final class Engine {
        var calls: [(String, [Any?])] = []
        var refuses: Set<String> = []
        var throwsOn: Set<String> = []
        var presented: [String?] = []
        var presentationFails = false
        var confirmations: [CloseConfirmRequest] = []
        var accepts = true
        var forgotten: [String] = []
        var sessions: [[String: Any]] = []
        var reasons: [String: String] = [:]
        func invoke(_ channel: String, _ args: [Any?]) throws -> Any {
            calls.append((channel, args))
            if throwsOn.contains(channel) { throw NSError(domain: "fixture", code: 1) }
            if let why = reasons[channel] { throw NativeRPCError(code: "refused", message: why) }
            if refuses.contains(channel) { return ["ok": false] }
            switch channel {
            case "session:list": return sessions
            case "servers:shell:open": return ["ok": true, "shellId": "private-shell"]
            case "servers:rename": return ["renamed": true]
            case "machines:list": return ["machines": [["id": "other", "name": "Other Mac"]], "links": [
                ["id": "other", "state": "online", "sessions": [["id": "far", "title": "Remote work", "cwd": "/work/remote", "status": "idle"]]]]]
            default: return NSNull()
            }
        }
    }
    func testVerify20FirstToolSelectionReplaysExistingSessions() async {
        let engine = Engine(), model = make(engine)
        let id = "33333333-3333-4333-8333-333333333333"
        engine.sessions = [["id": id, "title": "Created while Hoot was open", "cwd": "/work", "chat": true]]
        model.start()
        await succeeds(model, .select(id))
        XCTAssertEqual(model.sidebar.selectedId, id)
        XCTAssertEqual(model.sidebar.item(id: id)?.title, "Created while Hoot was open")
        await succeeds(model, .select(a))
        XCTAssertEqual(engine.calls.filter { $0.0 == "session:list" }.count, 1)
    }
    func testVerify20AIReplacementKeepsItsPaneAndSelection() async {
        let model = make(), next = "33333333-3333-4333-8333-333333333333"
        model.replaced(a, with: ["id": next, "title": "Same conversation", "cwd": "/work", "chat": true])
        XCTAssertEqual(model.tabs.tabs.count, 2)
        XCTAssertFalse(model.tabs.tabs.contains { $0.id == a })
        XCTAssertEqual(model.sidebar.selectedId, next)
        XCTAssertEqual(model.tabs.layout?.root?.leaves.first { $0.id == "left" }?.tabId, next)
        XCTAssertEqual(model.tabs.layout?.focusedPaneId, "left")
    }
    func testAccountSwitchInPlaceDoesNotCloseTheCurrentTab() {
        let model = make()
        model.replaced(a, with: ["id": a, "title": "Same conversation", "cwd": "/work"])
        XCTAssertEqual(model.tabs.tabs.count, 2)
        XCTAssertTrue(model.tabs.tabs.contains { $0.id == a })
        XCTAssertEqual(model.sidebar.selectedId, a)
    }
    func testVerify20WindowToolRoutesNativePagesAndKeepsSessionButtons() async {
        var selected: [String] = [], fallbackCount = 0
        for id in ["agents", "tasks", a] {
            let task = NativeButtonActions.route(.select(id), nativeSelection: {
                guard ["agents", "tasks"].contains($0) else { return false }
                selected.append($0); return true
            }, fallback: { fallbackCount += 1; return Task { true } })
            let result = await task.value; XCTAssertTrue(result)
        }
        XCTAssertEqual(selected, ["agents", "tasks"])
        XCTAssertEqual(fallbackCount, 1)
    }
    func testVerify20MainNavigationDoesNotNeedOldPageRows() async {
        let model = make()
        for id in ["tasks", "artifacts", "agents-all"] {
            await succeeds(model, .select(id))
            XCTAssertEqual(model.sidebar.selectedId, id)
        }
    }
    func testVerify20BackgroundSheetsFindTheMainWindowWithoutRaisingIt() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let floating = NSWindow(), main = NSWindow()
        floating.isReleasedWhenClosed = false; main.isReleasedWhenClosed = false
        main.identifier = NSUserInterfaceItemIdentifier("main")
        defer { floating.close(); main.close() }
        XCTAssertTrue(NativeButtonPresentation.mainWindow(in: [floating, main]) === main)
        XCTAssertFalse(main.isKeyWindow)
        XCTAssertFalse(main.isVisible)
        XCTAssertNil(NativeButtonPresentation.mainWindow(in: [floating]))
    }
    private func make(_ engine: Engine = Engine()) -> NativeButtonActions {
        let model = NativeButtonActions(effects: .init(invoke: { try engine.invoke($0, $1) },
            presentSession: { path in
                engine.presented.append(path)
                if engine.presentationFails { throw NSError(domain: "fixture", code: 2) }
            }, confirm: { request in engine.confirmations.append(request); return engine.accepts },
            forgotten: { engine.forgotten.append($0) }))
        model.ingest(SidebarState(groups: [SidebarGroup(id: "pages", title: nil, items: [
            SidebarItem(id: "files", title: "Files", kind: .panel), SidebarItem(id: "git", title: "Source control", kind: .panel)])],
            projects: [SidebarProject(id: "/work", title: "Work", expanded: true, sessions: [
                SidebarItem(id: a, title: "First", kind: .session, status: "working"), SidebarItem(id: b, title: "Second", kind: .session)])], selectedId: a, project: "/work"))
        model.ingest(TabsState(tabs: [TabItem(id: a, title: "First", kind: "session", active: true, status: "working", closable: true),
            TabItem(id: b, title: "Second", kind: "session", closable: true)], canNewTerminal: true, canNewBrowser: true,
            layout: WindowLayout(mode: "split", root: .split(id: "divider", horizontal: true, ratio: 0.5,
                first: .leaf(id: "left", tabId: a), second: .leaf(id: "right", tabId: b)), focusedPaneId: "left", primaryPaneId: "left", modeSwitch: true)))
        return model
    }
    private func succeeds(_ model: NativeButtonActions, _ command: PageCommand, file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await model.run(command).value
        XCTAssertTrue(ok, model.problem ?? "refused", file: file, line: line); XCTAssertNil(model.problem, file: file, line: line)
    }
    private func refuses(_ model: NativeButtonActions, _ command: PageCommand, file: StaticString = #filePath, line: UInt = #line) async {
        let before = model.tabs, sidebar = model.sidebar
        let ok = await model.run(command).value
        XCTAssertFalse(ok, file: file, line: line); XCTAssertNotNil(model.problem, file: file, line: line)
        XCTAssertEqual(model.tabs, before, file: file, line: line); XCTAssertEqual(model.sidebar, sidebar, file: file, line: line)
    }

    func testModeSwitchUsesNativeLayoutAndKeepsFocusedSession() async {
        let model = make(); await succeeds(model, .focusPane("right")); await succeeds(model, .setMode("terminal"))
        XCTAssertEqual(model.tabs.activeID, b); XCTAssertNil(model.tabs.layout?.root)
        await succeeds(model, .setMode("split")); XCTAssertEqual(model.tabs.layout?.root?.leaves.count, 2)
    }
    func testModeRefusalIsShown() async { await refuses(make(), .setMode("invalid")) }
    func testDividerUsesNativeLayout() async {
        let model = make(); await succeeds(model, .resizeSplit("divider", ratio: 0.3))
        guard case .split(_, _, let ratio, _, _) = model.tabs.layout?.root else { return XCTFail("No split") }; XCTAssertEqual(ratio, 0.3)
    }
    func testDividerRefusalIsShown() async { await refuses(make(), .resizeSplit("missing", ratio: 0.3)) }
    func testPaneFocusUsesNativeLayoutAndSelection() async {
        let model = make(); await succeeds(model, .focusPane("right")); XCTAssertEqual(model.tabs.layout?.focusedPaneId, "right"); XCTAssertEqual(model.tabs.activeID, b)
    }
    func testPaneFocusRefusalIsShown() async { await refuses(make(), .focusPane("missing")) }
    func testClosePaneKeepsItsSessionRunningAndShowsSurvivor() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .closePane("left"))
        XCTAssertEqual(model.tabs.layout?.mode, "terminal"); XCTAssertEqual(model.tabs.activeID, b); XCTAssertEqual(model.tabs.tabs.count, 2); XCTAssertTrue(engine.calls.isEmpty)
    }
    func testClosePaneRefusalIsShown() async { await refuses(make(), .closePane("missing")) }
    func testNewTerminalTabOpensNativeForm() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .newTerminalTab); XCTAssertEqual(engine.presented.count, 1); XCTAssertTrue(engine.calls.isEmpty)
    }
    func testNewTerminalTabRefusalIsShown() async { let engine = Engine(); engine.presentationFails = true; await refuses(make(engine), .newTerminalTab) }
    func testSelectTabFocusesExistingPane() async {
        let model = make(); await succeeds(model, .selectTab(b)); XCTAssertEqual(model.tabs.activeID, b); XCTAssertEqual(model.tabs.layout?.focusedPaneId, "right")
    }
    func testSelectTabRefusalIsShown() async { await refuses(make(), .selectTab("gone")) }
    func testOtherMacSelectionReadsEngineAndAddsNativeTab() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .selectTab("machine other far"))
        XCTAssertEqual(engine.calls.map { $0.0 }, ["machines:list"]); XCTAssertEqual(model.tabs.activeID, "machine other far")
        XCTAssertEqual(model.sidebar.item(id: "machine other far")?.title, "Remote work")
    }
    func testOtherMacRefusalIsShownAndDoesNotStealFocus() async {
        let engine = Engine(); engine.refuses = ["machines:list"]; await refuses(make(engine), .selectTab("machine other far"))
    }
    func testServerTerminalOpensThroughEngineBeforeAddingTab() async {
        let engine = Engine(), model = make(engine)
        await succeeds(model, .openServerSession(serverId: "box", serverName: "Box", startIn: "/srv/work"))
        XCTAssertEqual(engine.calls.map { $0.0 }, ["servers:shell:open"])
        XCTAssertEqual(engine.calls.first?.1[3] as? String, "/srv/work")
        let tab = model.tabs.tabs.last; XCTAssertEqual(tab?.server?.shellId, "private-shell"); XCTAssertEqual(tab?.server?.serverName, "Box")
        XCTAssertEqual(model.sidebar.item(id: tab?.id ?? "")?.title, "Box")
    }
    func testServerOpenRefusalIsShownAndAddsNothing() async {
        let engine = Engine(); engine.refuses = ["servers:shell:open"]; await refuses(make(engine), .openServerSession(serverId: "box", serverName: "Box", startIn: nil))
    }
    func testServerRenameWaitsForEngineThenRenamesTabs() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .openServerSession(serverId: "box", serverName: "Box", startIn: nil))
        await succeeds(model, .serverRenamed(serverId: "box", name: "New name"))
        XCTAssertEqual(engine.calls.last?.0, "servers:rename"); XCTAssertEqual(model.tabs.tabs.last?.server?.serverName, "New name")
        XCTAssertEqual(model.sidebar.projects.last?.title, "New name")
    }
    func testServerRenameFalseIsShownAndKeepsOldName() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .openServerSession(serverId: "box", serverName: "Box", startIn: nil))
        engine.refuses = ["servers:rename"]; await refuses(model, .serverRenamed(serverId: "box", name: "New name"))
    }
    func testFileLinkSelectsNativeFilesWithItsPath() async {
        let model = make(); await succeeds(model, .openFile("Sources/main.swift")); XCTAssertEqual(model.sidebar.selectedId, "files")
        XCTAssertEqual(model.sidebar.openFile, "Sources/main.swift"); XCTAssertNil(model.tabs.activeID)
    }
    func testFileLinkRefusalIsShown() async { await refuses(make(), .openFile("")) }
    func testGitLinkSelectsNativeGitWithMatchingGroup() async {
        let model = make(); await succeeds(model, .showPanel("git", focus: "staged")); XCTAssertEqual(model.sidebar.selectedId, "git"); XCTAssertEqual(model.sidebar.focus, "staged")
    }
    func testGitLinkRefusalIsShown() async { await refuses(make(), .showPanel("missing", focus: "staged")) }
    func testMainSelectionUsesNativeStore() async {
        let model = make(); await succeeds(model, .select("files")); XCTAssertEqual(model.sidebar.selectedId, "files"); XCTAssertNil(model.tabs.activeID)
    }
    func testMainSelectionRefusalIsShown() async { await refuses(make(), .select("missing")) }
    func testNewSessionUsesNativeForm() async { let engine = Engine(), model = make(engine); await succeeds(model, .newSession); XCTAssertEqual(engine.presented.count, 1) }
    func testNewSessionRefusalIsShown() async { let engine = Engine(); engine.presentationFails = true; await refuses(make(engine), .newSession) }
    func testNewSessionInProjectUsesNativeFormWithFolder() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .newSessionIn("/work")); XCTAssertEqual(engine.presented.first!, "/work")
    }
    func testNewSessionInProjectRefusalIsShown() async { await refuses(make(), .newSessionIn("/gone")) }
    func testDeleteSessionCallsEngineAndThenRemovesRows() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .closeSession(a))
        XCTAssertEqual(engine.calls.map { $0.0 }, ["session:kill"]); XCTAssertEqual(engine.calls.first?.1.first as? String, a)
        XCTAssertNil(model.sidebar.item(id: a)); XCTAssertEqual(engine.forgotten, [a]); XCTAssertEqual(engine.confirmations.first?.status, "working")
    }
    func testDeleteSessionRefusalIsShownAndKeepsRows() async { let engine = Engine(); engine.refuses = ["session:kill"]; await refuses(make(engine), .closeSession(a)) }
    /// U108 #93: the engine's own reason follows the sentence; an unexplained failure keeps the sentence alone.
    func testRefusalCarriesTheEnginesOwnReason() async {
        let engine = Engine(); engine.reasons = ["session:kill": "That session is still saving its work."]
        let model = make(engine); await refuses(model, .closeSession(a))
        XCTAssertEqual(model.problem, "That session could not be deleted. That session is still saving its work.")
        let quiet = Engine(); quiet.throwsOn = ["session:kill"]
        let other = make(quiet); await refuses(other, .closeSession(a))
        XCTAssertEqual(other.problem, "That session could not be deleted.")
    }
    func testCloseTabFoldsBackIntoSidebarWithoutEndingSession() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .closeTab(a))
        XCTAssertTrue(engine.calls.isEmpty); XCTAssertTrue(engine.confirmations.isEmpty); XCTAssertTrue(engine.forgotten.isEmpty)
        XCTAssertEqual(model.tabs.activeID, b); XCTAssertNotNil(model.sidebar.item(id: a))
        await succeeds(model, .select(a)); XCTAssertEqual(model.tabs.activeID, a)
    }
    func testCloseTabRefusalIsShown() async { await refuses(make(), .closeTab("missing")) }
    /// Asad 3 Nov: Hoot stays closed until the person opens it. Closing the last tab leaves the empty pane.
    func testClosingTheLastTabOpensNothingNeverHoot() async {
        let model = make(); await succeeds(model, .closeTab(a)); await succeeds(model, .closeTab(b))
        XCTAssertTrue(model.tabs.tabs.isEmpty); XCTAssertNil(model.tabs.activeID)
        XCTAssertNil(model.sidebar.selectedId); XCTAssertNotEqual(model.sidebar.selectedId, "hoot")
    }
    func testCloseProjectClosesEachSessionThenRemovesProject() async {
        let engine = Engine(), model = make(engine); await succeeds(model, .closeProject("/work"))
        XCTAssertEqual(engine.calls.map { $0.0 }, ["session:kill", "session:kill", "projects:remove"]); XCTAssertTrue(model.sidebar.projects.isEmpty)
        XCTAssertEqual(engine.confirmations.first?.count, 2)
    }
    func testCloseProjectRefusalKeepsUnclosedProject() async { let engine = Engine(); engine.refuses = ["session:kill"]; await refuses(make(engine), .closeProject("/work")) }
    func testProjectToggleUsesNativeStore() async { let model = make(); await succeeds(model, .toggleProject("/work")); XCTAssertFalse(model.sidebar.projects[0].expanded) }
    func testProjectToggleRefusalIsShown() async { await refuses(make(), .toggleProject("/gone")) }
    func testShowSessionsUsesNativeSwarm() async { let model = make(); await succeeds(model, .showSessions); XCTAssertTrue(model.tabs.layout?.swarm == true) }
    func testShowPanelRefusalKeepsSelection() async { await refuses(make(), .showPanel("missing", focus: nil)) }
    func testRapidDividerChangesKeepTheirOrder() async {
        let model = make(), first = model.run(.resizeSplit("divider", ratio: 0.25)), second = model.run(.resizeSplit("divider", ratio: 0.7))
        _ = await first.value; _ = await second.value
        guard case .split(_, _, let ratio, _, _) = model.tabs.layout?.root else { return XCTFail("No split") }; XCTAssertEqual(ratio, 0.7)
    }
    func testServerRenameThrowIsShown() async {
        let engine = Engine(); engine.throwsOn = ["servers:rename"]; await refuses(make(engine), .serverRenamed(serverId: "box", name: "New name"))
    }
    func testNativeNewTabSurvivesStalePage() async {
        let engine = Engine(), model = make(engine), staleTabs = model.tabs, staleSidebar = model.sidebar
        await succeeds(model, .openServerSession(serverId: "box", serverName: "Box", startIn: nil)); let id = model.tabs.activeID
        model.ingest(staleTabs); model.ingest(staleSidebar)
        XCTAssertEqual(model.tabs.activeID, id); XCTAssertNotNil(model.sidebar.item(id: id ?? "")); XCTAssertEqual(model.tabs.tabs.last?.server?.shellId, "private-shell")
    }
    func testCancelledDeleteDoesNotCallEngine() async {
        let engine = Engine(); engine.accepts = false; let model = make(engine), before = model.tabs
        let ok = await model.run(.closeSession(a)).value; XCTAssertFalse(ok); XCTAssertEqual(model.tabs, before); XCTAssertTrue(engine.calls.isEmpty); XCTAssertNil(model.problem)
    }
    func testStalePageCannotUndoNativeSelectionDividerOrClose() async {
        let model = make(), staleTabs = model.tabs, staleSidebar = model.sidebar
        await succeeds(model, .resizeSplit("divider", ratio: 0.3)); await succeeds(model, .closeSession(a)); await succeeds(model, .showPanel("git", focus: "staged"))
        let expected = model.tabs; model.ingest(staleTabs); model.ingest(staleSidebar)
        XCTAssertEqual(model.tabs, expected); XCTAssertNil(model.sidebar.item(id: a)); XCTAssertEqual(model.sidebar.selectedId, "git"); XCTAssertEqual(model.sidebar.focus, "staged")
    }
    func testToolRoutesEveryMovedActionToTheSameCommand() throws {
        for action in NativeButtonActions.names {
            let id = action == "set-mode" ? "split" : "target", value = action == "resize-split" ? "0.3" : "value"
            XCTAssertEqual(try NativeButtonActions.command(action, id: id, value: value).name, action)
        }
        XCTAssertThrowsError(try NativeButtonActions.command("resize-split", id: "divider", value: "NaN"))
        XCTAssertThrowsError(try NativeButtonActions.command("unknown", id: "", value: ""))
    }
    func testSelectSidebarSessionNotOnTopBarFillsFocusedPane() async {
        let model = make(), id = "44444444-4444-4444-8444-444444444444"
        var sidebar = model.sidebar
        sidebar.projects.append(SidebarProject(id: "/other", title: "Other", expanded: true, sessions: [SidebarItem(id: id, title: "Unpromoted", kind: .session)]))
        model.ingest(sidebar)
        await succeeds(model, .select(id)); XCTAssertEqual(model.tabs.activeID, id); XCTAssertEqual(model.sidebar.project, "/other")
        XCTAssertEqual(model.tabs.layout?.root?.leaves.first?.tabId, id)
    }
    func testFoldedTabStaysFoldedAfterStaleSnapshot() async {
        let model = make(), stale = model.tabs; await succeeds(model, .closeTab(a)); model.ingest(stale)
        XCTAssertFalse(model.tabs.tabs.contains(where: { $0.id == a })); XCTAssertNotNil(model.sidebar.item(id: a))
    }
    /// U143 (#611): a session deleted after its tab was folded leaves no folded note in the window's saved memory.
    func testDeletedSessionLeavesNoFoldedNoteBehind() async throws {
        let model = make(); await succeeds(model, .closeTab(a)); await succeeds(model, .closeSession(a))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(model.memory())) as? [String: Any])
        XCTAssertEqual(saved["folded"] as? [String], [])
    }
    func testNativeLayoutAndFoldsSurvivePrivateMemoryRoundTrip() async throws {
        let engine = Engine(), model = make(engine)
        await succeeds(model, .resizeSplit("divider", ratio: 0.3)); await succeeds(model, .toggleProject("/work")); await succeeds(model, .closeTab(a))
        let data = try XCTUnwrap(model.memory())
        let restored = NativeButtonActions(effects: .init(invoke: { try engine.invoke($0, $1) }, presentSession: { _ in }, confirm: { _ in true }), remembered: data)
        restored.ingest(make().tabs); restored.ingest(make().sidebar)
        XCTAssertFalse(restored.tabs.tabs.contains(where: { $0.id == a })); XCTAssertFalse(restored.sidebar.projects[0].expanded)
        XCTAssertEqual(restored.tabs.layout, model.tabs.layout)
    }
    func testNewSessionEventIsKeptWithoutPageSnapshot() async {
        let model = make(); let id = "33333333-3333-4333-8333-333333333333"
        model.created(["id": id, "title": "New work", "projectPath": "/work"])
        await succeeds(model, .selectTab(id)); XCTAssertEqual(model.tabs.activeID, id); XCTAssertEqual(model.sidebar.item(id: id)?.title, "New work")
    }
    private func form(context: NewSessionContext = .init(projectPath: "/work"), effects: NativeNewSessionEffects) -> NativeNewSessionModel {
        let model = NativeNewSessionModel(context: context, effects: effects)
        model.configureRenderFixture(projects: [.init(id: "work", name: "Work", folders: ["/work"], colour: "blue")],
            providers: NewSessionProviders.rows(detected: CodingAIJSON(["claude": true]), added: []))
        model.chosenProvider = "claude"
        return model
    }
    func testButtons21RemoteFormStartsNativelyOnceThenCloses() async {
        var order: [String] = []
        let context = NewSessionContext(projectPath: "/work", machineId: "other", machines: [.init(id: "other", name: "Other", folders: ["/work"])])
        let model = form(context: context, effects: .init(startMachine: { machine, request, project in
            XCTAssertEqual(machine, "other"); XCTAssertEqual(request.cwd, "/work")
            XCTAssertEqual(project, PROJProjects.independentID)
            order.append("created"); return "new"
        }, openedMachine: { _, id, _ in XCTAssertEqual(id, "new"); order.append("opened") },
            dismiss: { order.append("dismissed") }, closed: { order.append("notified") }))
        await model.submitNative(); await model.submitNative()
        XCTAssertEqual(order, ["created", "opened", "dismissed", "notified"])
        XCTAssertEqual(model.createdSessionID, "new"); XCTAssertNil(model.error)
    }
    func testButtons21RemoteRefusalKeepsFormAndDoesNotNotifyPage() async {
        var closed = 0
        let context = NewSessionContext(projectPath: "/work", machineId: "other", machines: [.init(id: "other", name: "Other", folders: ["/work"])])
        let model = form(context: context, effects: .init(startMachine: { _, _, _ in
            throw NativeRPCError(code: "refused", message: "That Mac is not connected.")
        }, openedMachine: { _, _, _ in XCTFail("Must not open") }, dismiss: { closed += 1 }, closed: { closed += 1 }))
        await model.submitNative()
        XCTAssertNil(model.createdSessionID); XCTAssertEqual(closed, 0)
        XCTAssertEqual(model.error, "That Mac is not connected.")
    }
    func testButtons21ServerFormWaitsForShellBeforeOpeningAndClosing() async {
        var order: [String] = []
        let model = form(context: .init(servers: [.init(id: "box", name: "Box")]), effects: .init(invoke: { channel, args in
            XCTAssertEqual(channel, "servers:shell:open"); XCTAssertEqual(args[0] as? String, "box")
            order.append("engine"); return ["ok": true, "shellId": "shell"]
        }, openedServer: { _, _, shell, _, _ in XCTAssertEqual(shell, "shell"); order.append("opened") },
            dismiss: { order.append("dismissed") }, closed: { order.append("notified") }))
        model.selectedServer = "box"
        await model.submitNative()
        XCTAssertEqual(order, ["engine", "opened", "dismissed", "notified"])
        XCTAssertEqual(model.createdSessionID, "shell")
    }
    func testButtons21ServerRefusalAndMissingIDKeepFormOpen() async {
        for reply: [String: Any] in [["ok": false], ["ok": true], ["ok": true, "shellId": ""]] {
            let model = form(context: .init(servers: [.init(id: "box", name: "Box")]), effects: .init(invoke: { _, _ in reply },
                openedServer: { _, _, _, _, _ in XCTFail("Must not open") }, dismiss: { XCTFail("Must not close") }, closed: { XCTFail("Must not notify") }))
            model.selectedServer = "box"; await model.submitNative()
            XCTAssertNil(model.createdSessionID); XCTAssertNotNil(model.error)
        }
    }
    /// U108 #618: the server's own refusal is what the New session window says.
    func testServerRefusalShowsTheServersOwnReason() async {
        let model = form(context: .init(servers: [.init(id: "box", name: "Box")]), effects: .init(invoke: { _, _ in
            ["ok": false, "message": "This server's private key is missing from the vault."] },
            openedServer: { _, _, _, _, _ in XCTFail("Must not open") }, dismiss: { XCTFail("Must not close") }, closed: { XCTFail("Must not notify") }))
        model.selectedServer = "box"; await model.submitNative()
        XCTAssertEqual(model.error, "This server's private key is missing from the vault.")
    }
    func testButtons21RemoveFolderEndsMatchingSessionsBeforeRemovingAndUpdating() async {
        var order: [String] = []
        let model = form(effects: .init(invoke: { channel, args in
            order.append(channel)
            if channel == "session:list" { return [["id": "one", "cwd": "/work"], ["id": "unrelated", "cwd": "/elsewhere"]] }
            if channel == "session:kill" { XCTAssertEqual(args[0] as? String, "one") }
            return true
        }, removedProject: { path, ids in XCTAssertEqual(path, "/work"); XCTAssertEqual(ids, ["one"]); order.append("updated") }))
        await model.removeNative("/work")
        XCTAssertEqual(order, ["session:list", "session:kill", "projects:remove", "updated"])
        XCTAssertTrue(model.projects.isEmpty); XCTAssertNil(model.selectedPath)
    }
    func testButtons21RemoveRefusalKeepsFolderAndStopsBeforeNextCall() async {
        for refused in ["session:list", "session:kill", "projects:remove"] {
            var calls: [String] = []
            let model = form(effects: .init(invoke: { channel, _ in
                calls.append(channel)
                if channel == refused { return false }
                if channel == "session:list" { return [["id": "one", "cwd": "/work"]] }
                return true
            }, removedProject: { _, _ in XCTFail("Must not remove native folder") }))
            await model.removeNative("/work")
            XCTAssertEqual(calls.last, refused); XCTAssertEqual(model.projects.count, 1)
            XCTAssertEqual(model.selectedPath, "/work"); XCTAssertNotNil(model.error)
        }
    }
    func testButtons21CancelClosesNativelyBeforePageNotification() {
        var order: [String] = []
        let model = form(effects: .init(invoke: { _, _ in XCTFail("Cancel must not create a session"); return false },
            dismiss: { order.append("closed") }, closed: { order.append("notified") }))
        model.cancel(); XCTAssertEqual(order, ["closed", "notified"])
    }
    func testButtons21AgentLaunchWritesOnceAndBookkeepingSurvivesStalePage() async throws {
        let engine = Engine(), model = make(engine)
        await succeeds(model, .openServerSession(serverId: "box", serverName: "Box", startIn: nil))
        await succeeds(model, .openServerShell(serverId: "box", agentId: "codex"))
        XCTAssertEqual(engine.calls.map { $0.0 }, ["servers:shell:open", "servers:shell:open", "servers:shell:write"])
        XCTAssertEqual(engine.calls.last?.1[1] as? String, "codex\r")
        let id = try XCTUnwrap(model.tabs.activeID), stale = model.tabs
        try model.serverOpened(id, shell: "replacement")
        model.ingest(stale)
        XCTAssertEqual(model.tabs.tabs.last?.server?.shellId, "replacement")
        try model.serverEnded(id); model.ingest(stale)
        XCTAssertNil(NativeServerShells.shellId(forTab: id))
        XCTAssertNil(model.tabs.tabs.last?.server?.shellId)
        XCTAssertEqual(model.tabs.tabs.last?.status, "exited")
        XCTAssertEqual(model.sidebar.item(id: id)?.status, "exited")
        await succeeds(model, .closeSession(id))
        XCTAssertEqual(engine.calls.count, 3, "Ended shell closes its tab without addressing an old shell")
    }
    func testButtons21AgentWriteRefusalClosesAllocatedShellAndAddsNoTab() async {
        let engine = Engine(), model = make(engine)
        await succeeds(model, .openServerSession(serverId: "box", serverName: "Box", startIn: nil))
        let before = model.tabs
        engine.refuses.insert("servers:shell:write")
        await refuses(model, .openServerShell(serverId: "box", agentId: "codex"))
        XCTAssertEqual(model.tabs, before)
        XCTAssertEqual(engine.calls.suffix(3).map { $0.0 }, ["servers:shell:open", "servers:shell:write", "servers:shell:close"])
    }
    func testButtons21ShellBookkeepingRefusesMissingTabsAndWorksWhenFolded() async throws {
        let model = make()
        XCTAssertThrowsError(try model.serverOpened("missing", shell: "shell"))
        XCTAssertThrowsError(try model.serverEnded("missing"))
        let id = model.adoptServer("box", name: "Box", shell: "shell", folder: nil)
        await succeeds(model, .closeTab(id)); try model.serverEnded(id)
        XCTAssertEqual(model.sidebar.item(id: id)?.status, "exited")
        await succeeds(model, .selectTab(id))
        XCTAssertEqual(model.tabs.tabs.last?.status, "exited")
        XCTAssertNil(model.tabs.tabs.last?.server?.shellId)
    }
    func testButtons21RemoteEntryPointOpensNativeForm() async {
        let engine = Engine(), model = make(engine)
        await succeeds(model, .newSessionIn("machine:other"))
        XCTAssertEqual(engine.presented.first!, "machine:other"); XCTAssertTrue(engine.calls.isEmpty)
    }
    func testButtons21RemoteCreateWaitsForMatchingNewSessionAndStopsWatching() async throws {
        var receive: (@MainActor (MachinesSnapshot) -> Void)?, stopped = false, calls: [String] = []
        func snapshot(_ rows: [[String: Any]]) -> [String: Any] {
            ["links": [["id": "other", "state": "online", "sessions": rows]]]
        }
        let old: [String: Any] = ["id": "old", "cwd": "/work", "provider": "claude"]
        let id = try await NativeMachineSessionStart.create(machine: "other", folder: "/work", provider: "claude", invoke: { channel, args in
            calls.append(channel)
            if channel == "machines:list" { return snapshot([old]) }
            XCTAssertEqual(args[1] as? String, "/work"); XCTAssertEqual(args[2] as? String, "claude")
            receive?(MachinesSnapshot.decode(snapshot([old, ["id": "wrong", "cwd": "/elsewhere", "provider": "claude"]]))!)
            receive?(MachinesSnapshot.decode(snapshot([old, ["id": "new", "cwd": "/work", "provider": "claude", "title": "Remote work"]]))!)
            return true
        }, observe: { receive = $0; return { stopped = true } })
        XCTAssertEqual(id, "new"); XCTAssertTrue(stopped); XCTAssertEqual(calls, ["machines:list", "machines:create"])
    }
    func testButtons21SentRemoteCreateIsNotSuccessWithoutObservedSession() async {
        var stopped = false
        do {
            _ = try await NativeMachineSessionStart.create(machine: "other", folder: "/work", provider: "claude", invoke: { channel, _ in
                if channel == "machines:list" { return ["links": [["id": "other", "state": "online", "sessions": []]]] }
                return true
            }, observe: { _ in { stopped = true } }, timeout: .milliseconds(5))
            XCTFail("Sent is not created")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Check its sessions")) }
        XCTAssertTrue(stopped)
    }

    func testButtons21RemoteCreateRefusalAndDisconnectNeverOpenTab() async {
        for disconnect in [false, true] {
            var receive: (@MainActor (MachinesSnapshot) -> Void)?, stopped = false
            do {
                _ = try await NativeMachineSessionStart.create(machine: "other", folder: "/work", provider: "claude", invoke: { channel, _ in
                    if channel == "machines:list" { return ["links": [["id": "other", "state": "online", "sessions": []]]] }
                    if disconnect { receive?(.empty); return true }
                    return false
                }, observe: { receive = $0; return { stopped = true } }, created: { _ in XCTFail("Must not create a tab") })
                XCTFail("Must refuse")
            } catch { XCTAssertTrue(error.localizedDescription.contains(disconnect ? "disconnected" : "could not start")) }
            XCTAssertTrue(stopped)
        }
    }

}
