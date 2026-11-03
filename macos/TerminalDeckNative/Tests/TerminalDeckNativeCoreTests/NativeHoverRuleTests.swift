import CoreGraphics
import Testing
@testable import TerminalDeckNativeCore

// Asad, 7 Oct: "island is opening itself even when I don't hover". An arrival
// opens the island only when the pointer is on the pill and has just moved there.

@Test func onlyARealPointerMoveOnThePillCountsAsAHover() {
    let pill = CGRect(x: 912, y: 1056, width: 96, height: 24)   // top centre of a 1920x1080 display
    // A real move onto the pill.
    #expect(NativeHoverRule.isRealHover(pointer: CGPoint(x: 960, y: 1070), shape: pill, secondsSincePointerMoved: 0.02))
    // Pressed against the very top edge of the screen still counts.
    #expect(NativeHoverRule.isRealHover(pointer: CGPoint(x: 960, y: 1080), shape: pill, secondsSincePointerMoved: 0.1))
    // A still pointer that the shape was placed under (tracking re-added, space or display change, wake).
    #expect(!NativeHoverRule.isRealHover(pointer: CGPoint(x: 960, y: 1070), shape: pill, secondsSincePointerMoved: 3))
    // An "entered" while the pointer is somewhere else entirely (another display, the Dock).
    #expect(!NativeHoverRule.isRealHover(pointer: CGPoint(x: 960, y: 20), shape: pill, secondsSincePointerMoved: 0.02))
    #expect(!NativeHoverRule.isRealHover(pointer: CGPoint(x: 2500, y: 1070), shape: pill, secondsSincePointerMoved: 0.02))
    // No record of a move.
    #expect(!NativeHoverRule.isRealHover(pointer: CGPoint(x: 960, y: 1070), shape: pill, secondsSincePointerMoved: -1))
}

// native-island.test.tsx: idle sessions give no badge ("1 open", badge 0); only sessions
// waiting for the person count; working shows the spinner, not a number. Asad, 7 Oct:
// the island at rest is plain black.
@Test func theIslandBadgeCountsOnlySessionsWaitingForThePerson() {
    #expect(IslandState.native(sessionStatuses: ["idle", "idle", "completed"], line: "3 open") == IslandState(status: .idle, badge: 0, line: "3 open"))
    #expect(IslandState.native(sessionStatuses: [], line: "Hoot") == IslandState(status: .idle, badge: 0, line: "Hoot"))
    #expect(IslandState.native(sessionStatuses: ["working", "idle"], line: "2 open · 1 working") == IslandState(status: .working, badge: 0, line: "2 open · 1 working"))
    #expect(IslandState.native(sessionStatuses: ["input", "working", "input", "exited"], line: "x") == IslandState(status: .needsYou, badge: 2, line: "x"))
}

// Asad, 7 Oct: "show hoot in island when its connected only".
@Test func theOwlShowsOnlyWhileHootIsConnected() {
    #expect(IslandState.native(sessionStatuses: [], line: "Hoot", hootStatus: "running").hootConnected)
    for status in ["stopped", "starting", "failed", "", nil] as [String?] {
        #expect(!IslandState.native(sessionStatuses: [], line: "Hoot", hootStatus: status).hootConnected)
    }
    // The badge and spinner rule is unchanged by the owl.
    let busy = IslandState.native(sessionStatuses: ["input", "working"], line: "x", hootStatus: "running")
    #expect(busy.status == .needsYou && busy.badge == 1 && busy.hootConnected)
}
