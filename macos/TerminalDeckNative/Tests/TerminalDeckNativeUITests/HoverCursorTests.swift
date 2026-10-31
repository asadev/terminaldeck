import XCTest
@testable import TerminalDeckNative

@MainActor
final class HoverCursorTests: XCTestCase {
    func testRemovalWhileHoveredBalancesStackAndIgnoresLateExit() {
        let state = NativeHoverCursorState()
        var depth = 0
        state.hover(true, push: { depth += 1 }, pop: { depth -= 1 })
        state.hover(true, push: { depth += 1 }, pop: { depth -= 1 })
        XCTAssertEqual(depth, 1)
        state.disappear { depth -= 1 }
        state.hover(false, push: { depth += 1 }, pop: { depth -= 1 })
        state.disappear { depth -= 1 }
        XCTAssertEqual(depth, 0)
        state.hover(true, push: { depth += 1 }, pop: { depth -= 1 })
        state.hover(false, push: { depth += 1 }, pop: { depth -= 1 })
        XCTAssertEqual(depth, 0)
    }
}
