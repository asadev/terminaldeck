import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendHootNotchTests: XCTestCase {
    func testNotchReportMatchingAndPlausibility() {
        let raw = #"[{"x":-1512,"width":1512,"height":982,"left":656,"right":656,"top":32}]"#
        let rows = BackendHootNotch.parseScreens(raw), display = CGRect(x: -1512, y: 98, width: 1512, height: 982)
        let notch = BackendHootNotch.notchOf(display, screens: rows)
        XCTAssertEqual(notch?.minX, -1512 + 656); XCTAssertEqual(notch?.width, 200); XCTAssertEqual(notch?.height, 32)
        XCTAssertEqual(BackendHootNotch.notchOf(CGRect(x: -1512, y: 98, width: 1512.8, height: 982.8), screens: rows)?.width, 200)
        XCTAssertNil(BackendHootNotch.notchOf(CGRect(x: 0, y: 0, width: 1512, height: 982), screens: rows))
        for (left, right) in [(756.0, 755.0), (100, 100), (656, 0)] {
            XCTAssertNil(BackendHootNotch.notchOf(display, screens: [.init(x: -1512, width: 1512, height: 982, left: left, right: right, top: 32)]))
        }
    }
    func testDefensiveReportsAndAppKitConversion() {
        for raw in ["", "execution error: -1743", #"{"x":1}"#] { XCTAssertTrue(BackendHootNotch.parseScreens(raw).isEmpty) }
        XCTAssertEqual(BackendHootNotch.parseScreens(#"[null,3,{"x":"left"}]"#), [.init(x: 0, width: 0, height: 0, left: 0, right: 0, top: 0)])
        XCTAssertEqual(BackendHootNotch.appKitFrame(CGRect(x: 426, y: 0, width: 1068, height: 576), primaryTop: 1080), CGRect(x: 426, y: 504, width: 1068, height: 576))
        XCTAssertEqual(BackendHootIslandBounds.clamp(displayWidth: 1920, barHeight: 30, size: CGSize(width: 5000, height: 40)), CGSize(width: 960, height: 180))
    }
    func testCatcherRepeatedHoverWithoutExit() {
        var gate = BackendHootCatcherEntryGate()
        XCTAssertEqual(gate.moved(at: 1000), "enter"); XCTAssertNil(gate.moved(at: 1050))
        XCTAssertEqual(gate.moved(at: 1100), "enter"); XCTAssertEqual(gate.left(), "leave"); XCTAssertNil(gate.left())
        XCTAssertEqual(gate.pressed(button: 0), "press"); XCTAssertNil(gate.pressed(button: 1))
    }
}
