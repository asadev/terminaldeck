import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — the window's arrangement (mirrors pane-tree.test.ts, SplitView.test.tsx, SwarmGrid.test.tsx).

@Suite("Pane layout")
struct PaneLayoutTests {
    @Test func theTabsStateCarriesTheArrangement() throws {
        let json = #"""
        {"tabs":[],"canNewTerminal":true,"canNewBrowser":true,
         "layout":{"mode":"split","swarm":false,"focusedPaneId":"p2","primaryPaneId":"p1","modeSwitch":true,"splitOffer":false,
                   "root":{"type":"split","id":"s1","direction":"vertical","ratio":0.99,
                           "children":[{"type":"leaf","id":"p1","tabId":"a"},{"type":"leaf","id":"p2","tabId":null}]},
                   "swarmSessions":[{"id":"a","title":"web","status":"working"}]}}
        """#
        let state = try JSONDecoder().decode(TabsState.self, from: Data(json.utf8))
        let layout = try #require(state.layout)
        #expect(layout.splitting)
        #expect(layout.primaryPaneId == "p1" && layout.focusedPaneId == "p2")
        guard case .split(let id, let horizontal, let ratio, _, _) = layout.root else {
            Issue.record("expected a split")
            return
        }
        #expect(id == "s1" && !horizontal && ratio == 0.92)
        #expect(layout.root?.leaves.map(\.id) == ["p1", "p2"])
        #expect(layout.root?.leaves.last?.tabId == nil)
        #expect(layout.swarmSessions.first?.title == "web")
        let old = try JSONDecoder().decode(TabsState.self, from: Data(#"{"tabs":[]}"#.utf8))
        #expect(old.layout == nil)
    }

    @Test func ratiosAreClampedAndDividersMeasured() {
        #expect(PaneRules.clamp(.nan) == 0.5)
        #expect(PaneRules.clamp(0.01) == 0.08)
        #expect(PaneRules.clamp(0.5) == 0.5)
        #expect(PaneRules.dividerRatio(size: 1008, offset: 504, dividerPx: 8, minPanePx: 140, fallback: 0.3) == 0.5)
        #expect(PaneRules.dividerRatio(size: 1008, offset: 10, dividerPx: 8, minPanePx: 140, fallback: 0.3) == 0.14)
        #expect(PaneRules.dividerRatio(size: 0, offset: 10, dividerPx: 8, minPanePx: 140, fallback: 0.3) == 0.3)
    }

    @Test func swarmIsAsSquareAsTheWindowAllows() {
        #expect(PaneRules.swarmColumns(count: 1, width: 1000) == 1)
        #expect(PaneRules.swarmColumns(count: 4, width: 2000) == 2)
        #expect(PaneRules.swarmColumns(count: 9, width: 2000) == 3)
        #expect(PaneRules.swarmColumns(count: 9, width: 700) == 2)
        #expect(PaneRules.swarmColumns(count: 5, width: 0) == 3)
        #expect(PaneRules.swarmRows(count: 5, columns: 2) == 3)
        #expect(PaneRules.swarmRows(count: 0, columns: 2) == 0)
    }

    @Test func theModeSwitchSaysWhatAPressDoes() {
        #expect(PaneRules.modeSwitchLabel(split: false, offer: false) == "Split — show two sessions side by side")
        #expect(PaneRules.modeSwitchLabel(split: true, offer: true) == "Split — press to show one session on its own again")
        #expect(PaneRules.modeSwitchLabel(split: false, offer: true).hasSuffix("not installed. Press to install it."))
    }
}
