import XCTest
@testable import TerminalDeckNativeCore

final class HootFullPageTests: XCTestCase {
    func testFirstOpenIsAFullPageClosableTabWithoutAProcess() {
        let original = TabsState(tabs: [.init(id: "session-1", title: "Work", kind: "session", active: true, closable: true)], canNewTerminal: true, canNewBrowser: true)
        let result = HootReadyDefaults.open(in: original)
        XCTAssertEqual(result.activeID, "hoot"); XCTAssertEqual(result.tabs.count, 2)
        XCTAssertEqual(result.tabs.last?.kind, "hoot"); XCTAssertEqual(result.tabs.last?.closable, true)
        XCTAssertFalse(result.tabs[0].active); XCTAssertTrue(result.canNewBrowser)
        XCTAssertEqual(HootReadyDefaults.open(in: result).tabs.count, 2, "repeat visits reuse one tab")
        let closed = HootReadyDefaults.close(in: result)
        XCTAssertEqual(closed, original, "closing restores the neighbouring session without ending Hoot")
    }
    func testSplitSelectsFocusedPaneAndKeepsTheOtherSession() {
        let layout = WindowLayout(mode: "split", root: .split(id: "root", horizontal: true, ratio: 0.4,
            first: .leaf(id: "left", tabId: "one"), second: .leaf(id: "right", tabId: "two")), focusedPaneId: "right", primaryPaneId: "left", modeSwitch: true)
        let state = TabsState(tabs: [.init(id: "one", title: "One", kind: "session"), .init(id: "two", title: "Two", kind: "session", active: true)], canNewTerminal: true, canNewBrowser: false, layout: layout)
        let opened = HootReadyDefaults.open(in: state)
        XCTAssertEqual(opened.layout?.root?.leaves.map { $0.tabId }, ["one", "hoot"])
        XCTAssertEqual(opened.layout?.focusedPaneId, "right")
        XCTAssertEqual(HootReadyDefaults.close(in: opened).layout?.root?.leaves.map { $0.tabId }, ["one", "two"])
    }
    func testExistingPresentationIDIsReusedAndQuickAccessDoesNotOwnATab() {
        let state = TabsState(tabs: [.init(id: "old-hoot", title: "Nova", kind: "hoot", active: true, closable: true)], canNewTerminal: false, canNewBrowser: false)
        let selected = HootReadyDefaults.open(in: state, title: "Nova")
        XCTAssertEqual(selected.activeID, "old-hoot"); XCTAssertEqual(selected.tabs.count, 1)
        XCTAssertTrue(HootReadyDefaults.close(in: selected).tabs.isEmpty)
        XCTAssertEqual(state.tabs.count, 1, "projection never mutates quick-access or session ownership")
    }
    func testOpeningHootLeavesSwarmAndKeepsSessionTabs() {
        let original = TabsState(tabs: [.init(id: "work", title: "Work", kind: "session", active: true)],
            canNewTerminal: true, canNewBrowser: false, layout: .init(swarm: true))
        let opened = HootReadyDefaults.open(in: original)
        XCTAssertEqual(opened.activeID, "hoot"); XCTAssertEqual(opened.layout?.swarm, false)
        XCTAssertEqual(opened.tabs.map(\.id), ["work", "hoot"])
    }
}
