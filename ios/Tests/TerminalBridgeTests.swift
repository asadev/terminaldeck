/**
 * The two directions data moves through the terminal, and the one thing the
 * copy button depends on.
 *
 * `visibleText()` is the fallback behind Copy when nothing is selected, and it
 * reads SwiftTerm's buffer through an API whose row indices are absolute rather
 * than screen-relative. Getting that wrong produces an empty string, which the
 * UI reports as "Nothing to copy" — a button that appears to work and does
 * nothing, which is the failure mode worth a test.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class TerminalBridgeTests: XCTestCase {

    private func bridge() -> TerminalBridge {
        let bridge = TerminalBridge()
        // A terminal at `.zero` has no columns to put anything in. The size the
        // app gives it comes from SwiftUI layout, which does not happen here.
        bridge.view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        bridge.view.layoutIfNeeded()
        return bridge
    }

    func testWhatIsFedIsWhatIsCopied() {
        let bridge = bridge()
        bridge.feed("hello from the desktop\r\n")
        let text = bridge.visibleText()
        XCTAssertTrue(text.contains("hello from the desktop"), "visibleText was: \(text)")
    }

    func testTrailingBlankRowsAreNotCopied() {
        let bridge = bridge()
        bridge.feed("one\r\ntwo\r\n")
        let text = bridge.visibleText()
        // A terminal is 24 rows whether or not anything is on them; pasting
        // twenty empty lines into a message is its own bug report.
        XCTAssertFalse(text.hasSuffix("\n"), "visibleText was: \(text.debugDescription)")
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testAnEmptyTerminalCopiesNothing() {
        XCTAssertEqual(bridge().visibleText(), "")
    }

    func testNoteIsVisiblyNotProgramOutput() {
        let bridge = bridge()
        bridge.note("connection lost")
        XCTAssertTrue(bridge.visibleText().contains("[connection lost]"))
    }

    func testClearResetsRatherThanScrolls() {
        let bridge = bridge()
        bridge.feed("before the re-attach\r\n")
        bridge.clear()
        // A re-attach replays the whole scrollback; anything left behind would
        // be printed twice.
        XCTAssertFalse(bridge.visibleText().contains("before the re-attach"))
    }

    func testNothingIsSelectedUntilSomethingIs() {
        let bridge = bridge()
        bridge.feed("some output\r\n")
        XCTAssertNil(bridge.selectedText())
    }
}
