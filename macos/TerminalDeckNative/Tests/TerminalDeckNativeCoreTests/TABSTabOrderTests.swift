import Foundation
import Testing
@testable import TerminalDeckNativeCore

// TABS: the top strip's tab order (runs with TD_WIP=TABS).
@Suite("Tab order", .enabled(if: ProcessInfo.processInfo.environment["TD_WIP"]?.contains("TABS") == true))
struct TABSTabOrderTests {
    @Test func savedOrderWinsNewTabsGoLastGoneTabsDrop() {
        #expect(TabOrderRules.arranged(["a", "b", "c"], saved: []) == ["a", "b", "c"])
        #expect(TabOrderRules.arranged(["a", "b", "c"], saved: ["c", "a", "b"]) == ["c", "a", "b"])
        #expect(TabOrderRules.arranged(["a", "b", "c", "d"], saved: ["c", "a"]) == ["c", "a", "b", "d"])
        #expect(TabOrderRules.arranged(["a", "c"], saved: ["x", "c", "b", "a", "c"]) == ["c", "a"])
    }

    @Test func movingATabPutsItAtThePlaceAndTheOthersShiftAside() {
        #expect(TabOrderRules.moved(["a", "b", "c", "d"], id: "a", to: 2) == ["b", "c", "a", "d"])
        #expect(TabOrderRules.moved(["a", "b", "c", "d"], id: "d", to: 0) == ["d", "a", "b", "c"])
        #expect(TabOrderRules.moved(["a", "b", "c"], id: "b", to: 1) == ["a", "b", "c"])
        #expect(TabOrderRules.moved(["a", "b", "c"], id: "b", to: 99) == ["a", "c", "b"])
        #expect(TabOrderRules.moved(["a", "b", "c"], id: "b", to: -5) == ["b", "a", "c"])
        #expect(TabOrderRules.moved(["a", "b"], id: "zzz", to: 0) == ["a", "b"])
    }

    @Test func slidingMovesAPlaceOnceItIsHalfwayOver() {
        // Tabs 100 apart: past 50 points it takes the next place, like Chrome.
        #expect(TabOrderRules.targetIndex(start: 1, translation: 40, step: 100, count: 4) == 1)
        #expect(TabOrderRules.targetIndex(start: 1, translation: 60, step: 100, count: 4) == 2)
        #expect(TabOrderRules.targetIndex(start: 1, translation: -160, step: 100, count: 4) == 0)
        #expect(TabOrderRules.targetIndex(start: 2, translation: 900, step: 100, count: 4) == 3)
        #expect(TabOrderRules.targetIndex(start: 2, translation: 30, step: 0, count: 4) == 2)
    }

    @Test func farOutOfTheStripPopsTheTabOut() {
        #expect(!TabOrderRules.popsOut(pointerY: 20, stripHeight: 40))
        #expect(!TabOrderRules.popsOut(pointerY: -30, stripHeight: 40))
        #expect(TabOrderRules.popsOut(pointerY: -80, stripHeight: 40))
        #expect(TabOrderRules.popsOut(pointerY: 120, stripHeight: 40))
    }
}
