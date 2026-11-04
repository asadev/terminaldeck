import XCTest
@testable import TerminalDeckNativeCore

final class ChatFollowStateTests: XCTestCase {
    func testOpeningAndEveryStreamLayoutKeepFollowing() {
        var state = ChatFollowState()
        XCTAssertTrue(state.measure(offset: 0, viewport: 300, content: 1200))
        _ = state.measure(offset: 900, viewport: 300, content: 1200)
        for height in stride(from: 1210.0, through: 2400.0, by: 10) {
            XCTAssertTrue(state.measure(offset: state.offset, viewport: 300, content: height))
            _ = state.measure(offset: height - 300, viewport: 300, content: height)
            XCTAssertTrue(state.following)
        }
    }
    func testReadingPausesEvenWhenAStreamArrivesInTheSameFrame() {
        var state = ChatFollowState()
        _ = state.measure(offset: 900, viewport: 300, content: 1200)
        XCTAssertFalse(state.measure(offset: 600, viewport: 300, content: 1300, interacting: true))
        XCTAssertFalse(state.following)
        XCTAssertFalse(state.measure(offset: 600, viewport: 300, content: 1800))
        XCTAssertEqual(state.offset, 600)
    }
    func testManualScrollAndSendResumeWithoutASeparateButton() {
        var state = ChatFollowState()
        _ = state.measure(offset: 900, viewport: 300, content: 1200)
        _ = state.measure(offset: 100, viewport: 300, content: 1200)
        XCTAssertFalse(state.following)
        _ = state.measure(offset: 900, viewport: 300, content: 1200)
        XCTAssertTrue(state.following)
        _ = state.measure(offset: 100, viewport: 300, content: 1200)
        state.resume()
        XCTAssertTrue(state.measure(offset: 100, viewport: 300, content: 1400))
    }
    func testComposerResizeAndToolExpansionAndCollapseKeepTheSameEnd() {
        var state = ChatFollowState()
        _ = state.measure(offset: 900, viewport: 300, content: 1200)
        XCTAssertTrue(state.measure(offset: 900, viewport: 180, content: 1200))
        _ = state.measure(offset: 1020, viewport: 180, content: 1200)
        XCTAssertTrue(state.measure(offset: 1020, viewport: 180, content: 1700))
        _ = state.measure(offset: 1520, viewport: 180, content: 1700)
        XCTAssertTrue(state.measure(offset: 1520, viewport: 180, content: 1100))
        XCTAssertEqual(state.maximumOffset, 920)
    }
    func testAnOffsetPastTheEndIsClampedByTheView() {
        var state = ChatFollowState()
        _ = state.measure(offset: 900, viewport: 300, content: 1200)
        XCTAssertTrue(state.measure(offset: 1400, viewport: 300, content: 1200))
        XCTAssertEqual(state.maximumOffset, 900)
    }
    func testShortContentHasNoExtraScrollableSpace() {
        var state = ChatFollowState()
        _ = state.measure(offset: 0, viewport: 700, content: 90)
        XCTAssertEqual(state.maximumOffset, 0)
        XCTAssertTrue(state.atBottom)
    }
}
