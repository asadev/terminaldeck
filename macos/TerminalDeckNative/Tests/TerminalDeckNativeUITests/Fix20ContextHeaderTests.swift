import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class Fix20ContextHeaderTests: XCTestCase {
    func testChatUpdatesReachTheExistingHeaderReadingWithoutATerminalTranscript() throws {
        let state = NativeUsageState(target: .local("scratch"))
        state.acceptChatContext(["contextReading": ["state": "ok", "tokens": 80_000, "window": 828_400,
            "percent": 9.657, "windowBasis": "reported", "reportedAt": 1_000]])
        XCTAssertEqual(state.context?.tokens, 80_000); XCTAssertEqual(state.context?.window, 828_400)
        state.acceptChatContext(["draft": "A partial update"])
        XCTAssertEqual(state.context?.tokens, 80_000)
        state.acceptChatContext(["contextReading": NSNull()])
        XCTAssertNil(state.context, "A cleared chat must not retain another AI's measured window.")
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
