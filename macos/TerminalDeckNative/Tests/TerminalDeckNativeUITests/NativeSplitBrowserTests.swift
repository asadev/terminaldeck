import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Asad, 28 Oct: "in split view i should be able to have browser in other side too, not just 2 sessions".
/// Either side of the split is a session or a native browser tab. Inert effects: no app, engine, page or WebKit.
@MainActor final class NativeSplitBrowserTests: XCTestCase {
    private let a = "11111111-1111-4111-8111-111111111111"
    private let b = "22222222-2222-4222-8222-222222222222"
    /// Browser tab ids are UUIDs too, like local sessions'.
    private let web = "33333333-3333-4333-8333-333333333333"
    private let web2 = "44444444-4444-4444-8444-444444444444"

    private final class Window {
        var browsers: [String] = []
        var shown: String?
        var remembered: Data?
        var openTabs: [TabItem]?
    }

    private func make(_ window: Window, split: Bool = false, sessions: [String]? = nil, remembered: Data? = nil) -> NativeButtonActions {
        let ids = sessions ?? [a, b]
        let model = NativeButtonActions(effects: .init(invoke: { _, _ in NSNull() },
            presentSession: { _ in }, confirm: { _ in true },
            remember: { window.remembered = $0 }, openTabs: { window.openTabs },
            browserTabs: { window.browsers }, shownBrowser: { window.shown }), remembered: remembered)
        model.ingest(SidebarState(groups: [], projects: [SidebarProject(id: "/work", title: "Work", expanded: true,
            sessions: ids.map { SidebarItem(id: $0, title: $0 == a ? "First" : "Second", kind: .session) })], selectedId: ids.first, project: "/work"))
        let layout = split ? WindowLayout(mode: "split", root: .split(id: "divider", horizontal: true, ratio: 0.5,
            first: .leaf(id: "left", tabId: a), second: .leaf(id: "right", tabId: b)), focusedPaneId: "left", primaryPaneId: "left", modeSwitch: true) : nil
        model.ingest(TabsState(tabs: ids.enumerated().map { TabItem(id: $1, title: $1 == a ? "First" : "Second", kind: "session", active: $0 == 0, closable: true) },
            canNewTerminal: true, canNewBrowser: true, layout: layout))
        return model
    }

    private func run(_ model: NativeButtonActions, _ command: PageCommand, file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await model.run(command).value
        XCTAssertTrue(ok, model.problem ?? "refused", file: file, line: line)
    }
    private func tab(in model: NativeButtonActions, pane: String) -> String? {
        model.tabs.layout?.root?.leaves.first { $0.id == pane }?.tabId
    }

    func testABrowserTabChosenWhileSplitFillsTheFocusedPaneAndIsShown() async {
        let window = Window(); window.browsers = [web]
        let model = make(window, split: true)
        await run(model, .focusPane("right"))
        await run(model, .selectTab(web))
        XCTAssertEqual(tab(in: model, pane: "left"), a)
        XCTAssertEqual(tab(in: model, pane: "right"), web)
        XCTAssertEqual(model.tabs.layout?.focusedPaneId, "right")
        XCTAssertEqual(model.sidebar.selectedId, web, "the browser tab is what the window shows")
        XCTAssertTrue(model.isBrowser(web))
        // Chosen again while in a pane: that pane only takes the focus.
        await run(model, .focusPane("left")); await run(model, .selectTab(web))
        XCTAssertEqual(model.tabs.layout?.focusedPaneId, "right")
        XCTAssertEqual(model.tabs.layout?.root?.leaves.map(\.tabId), [a, web])
    }

    func testABrowserTabChosenWithoutTheSplitOnlyShowsIt() async {
        let window = Window(); window.browsers = [web]
        let model = make(window)
        await run(model, .selectTab(web))
        XCTAssertNil(model.tabs.layout?.root)
        XCTAssertEqual(model.sidebar.selectedId, web)
    }

    func testSplitFromABrowserOnShowPutsItFirstAndASessionBesideIt() async {
        let window = Window(); window.browsers = [web]; window.shown = web
        let model = make(window)
        await run(model, .setMode("split"))
        XCTAssertEqual(model.tabs.layout?.root?.leaves.map(\.tabId), [web, a])
        XCTAssertEqual(model.tabs.layout?.focusedPaneId, model.tabs.layout?.root?.leaves.first?.id)
        XCTAssertEqual(model.sidebar.selectedId, web)
    }

    func testSplitFromTheOnlySessionTakesABrowserTabBesideIt() async {
        let window = Window(); window.browsers = [web]
        let model = make(window, sessions: [a])
        await run(model, .setMode("split"))
        XCTAssertEqual(model.tabs.layout?.root?.leaves.map(\.tabId), [a, web])
    }

    func testSplitWithNothingElseOpenFocusesTheEmptyPaneSoTheNextChoiceLandsThere() async {
        let window = Window()
        let model = make(window, sessions: [a])
        await run(model, .setMode("split"))
        let leaves = model.tabs.layout?.root?.leaves ?? []
        XCTAssertEqual(leaves.map(\.tabId), [a, nil])
        XCTAssertEqual(model.tabs.layout?.focusedPaneId, leaves.last?.id)
        window.browsers = [web] // a new browser tab, as the strip's globe makes one
        await run(model, .selectTab(web))
        XCTAssertEqual(model.tabs.layout?.root?.leaves.map(\.tabId), [a, web])
    }

    func testOpenInSplitViewPutsTheTabBesideTheOneOnShow() async {
        let window = Window(); window.browsers = [web]
        let model = make(window)
        await run(model, .splitWith(web))
        XCTAssertEqual(model.tabs.layout?.mode, "split")
        XCTAssertEqual(model.tabs.layout?.root?.leaves.map(\.tabId), [a, web])
        XCTAssertEqual(model.tabs.layout?.focusedPaneId, model.tabs.layout?.root?.leaves.last?.id)
        XCTAssertEqual(model.sidebar.selectedId, web)
    }

    func testOpenInSplitViewWhileSplitGoesBesideTheFocusedPane() async {
        let window = Window(); window.browsers = [web]
        let model = make(window, split: true)
        await run(model, .splitWith(web))
        XCTAssertEqual(model.tabs.layout?.root?.leaves.map(\.tabId), [a, web])
        XCTAssertEqual(model.tabs.layout?.focusedPaneId, "right")
        await run(model, .focusPane("right")); await run(model, .splitWith(b))
        XCTAssertEqual(model.tabs.layout?.root?.leaves.map(\.tabId), [b, web], "beside the focused right pane is the left one")
    }

    func testOpenInSplitViewRefusesATabThatIsGone() async {
        let model = make(Window())
        let ok = await model.run(.splitWith("55555555-5555-4555-8555-555555555555")).value
        XCTAssertFalse(ok); XCTAssertNotNil(model.problem)
    }

    func testClosingTheSplitShowsTheFocusedSideOnItsOwnAndKeepsBothTabs() async {
        let window = Window(); window.browsers = [web]
        let model = make(window, split: true)
        await run(model, .focusPane("right")); await run(model, .selectTab(web))
        await run(model, .setMode("terminal"))
        XCTAssertNil(model.tabs.layout?.root)
        XCTAssertEqual(model.sidebar.selectedId, web)
        XCTAssertEqual(model.tabs.tabs.map(\.id), [a, b])
        // Closing a pane instead: the other side shows on its own.
        window.shown = web
        await run(model, .splitWith(web))
        XCTAssertEqual(model.tabs.layout?.root?.leaves.map(\.tabId), [a, web], "the tab on show splits with the next session"); let left = model.tabs.layout?.root?.leaves.first?.id ?? ""
        await run(model, .closePane(left))
        XCTAssertNil(model.tabs.layout?.root); XCTAssertEqual(model.sidebar.selectedId, web)
    }

    func testAClosedBrowserTabLeavesItsPaneToItsNeighbourOrEmpty() async {
        let window = Window(); window.browsers = [web, web2]
        let model = make(window, split: true)
        await run(model, .focusPane("right")); await run(model, .selectTab(web))
        model.browserClosed(web, next: web2)
        XCTAssertEqual(tab(in: model, pane: "right"), web2)
        XCTAssertEqual(model.sidebar.selectedId, web2)
        window.browsers = []
        model.browserClosed(web2)
        XCTAssertNil(tab(in: model, pane: "right"))
        XCTAssertEqual(model.tabs.layout?.mode, "split", "the split stays")
        XCTAssertFalse(model.isBrowser(web2))
    }

    func testABrowserPageIsNeverInTwoPanes() async {
        let window = Window(); window.browsers = [web]
        let model = make(window, split: true)
        await run(model, .focusPane("right")); await run(model, .selectTab(web)); await run(model, .focusPane("left"))
        // Folding the left session back: its neighbour on the bar is the browser tab, already on the right.
        window.openTabs = [TabItem(id: a, title: "First", kind: "session", closable: true), TabItem(id: web, title: "Page", kind: "browser", closable: true)]
        await run(model, .closeTab(a))
        let shown = model.tabs.layout?.root?.leaves.compactMap(\.tabId) ?? []
        XCTAssertEqual(shown.filter { $0 == web }.count, 1)
        XCTAssertEqual(tab(in: model, pane: "left"), web, "the focused pane keeps it")
    }

    func testTheSplitWithABrowserIsRememberedAcrossARestart() async throws {
        let window = Window(); window.browsers = [web]
        let model = make(window, split: true)
        await run(model, .focusPane("right")); await run(model, .selectTab(web))
        let saved = try XCTUnwrap(window.remembered)
        // After the restart the browser tab is not known yet: the pane still knows it holds a browser, not a session.
        let restoredWindow = Window()
        let restored = NativeButtonActions(effects: .init(invoke: { _, _ in NSNull() }, presentSession: { _ in }, confirm: { _ in true },
            browserTabs: { restoredWindow.browsers }), remembered: saved)
        XCTAssertEqual(restored.tabs.layout?.root?.leaves.map(\.tabId), [a, web])
        XCTAssertEqual(restored.tabs.layout?.mode, "split")
        XCTAssertTrue(restored.isBrowser(web))
        XCTAssertFalse(restored.isBrowser(a))
    }

    func testToolsSeeWhatEachPaneHolds() async throws {
        let window = Window(); window.browsers = [web]
        let model = make(window, split: true)
        await run(model, .focusPane("right")); await run(model, .selectTab(web))
        let summary = model.paneSummary()
        XCTAssertEqual(summary["split"] as? Bool, true)
        let panes = try XCTUnwrap(summary["panes"] as? [[String: Any]])
        XCTAssertEqual(panes.map { $0["kind"] as? String }, ["session", "browser"])
        XCTAssertEqual(panes.map { $0["focused"] as? Bool }, [false, true])
        XCTAssertEqual(try NativeButtonActions.command("split-with", id: web, value: "").name, "split-with")
        XCTAssertTrue(NativeButtonActions.names.contains("split-with"))
    }
}
