import AppKit
import XCTest
@testable import TerminalDeckNative

@MainActor
final class TerminalCaretCompatibilityTests: XCTestCase {
    func testCaretHidesInPlaceAndReappearsWithoutTreeChanges() throws {
        let view = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let terminal = view.getTerminal()
        view.showCursor(source: terminal)
        let caret = try XCTUnwrap(view.subviews.first { String(describing: type(of: $0)) == "CaretView" })
        let count = view.subviews.count
        view.hideCursor(source: terminal)
        XCTAssertTrue(caret.isHidden)
        XCTAssertTrue(caret.superview === view)
        view.showCursor(source: terminal)
        XCTAssertFalse(caret.isHidden)
        XCTAssertEqual(view.subviews.count, count)
    }
}
