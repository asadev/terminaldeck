import AppKit
import XCTest
@testable import TerminalDeckNative

@MainActor final class PassiveChatWindowTests: XCTestCase {
    func testCheckPanelCannotTakeTheKeyOrMainWindow() {
        let panel = NativePassiveChatPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 960, height: 680),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.prepareForPassiveCapture()
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllApplications))
        XCTAssertFalse(panel.collectionBehavior.contains(.auxiliary))
        panel.close()
    }
}
