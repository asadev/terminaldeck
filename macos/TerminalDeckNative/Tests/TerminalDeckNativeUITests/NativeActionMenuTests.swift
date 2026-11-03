import AppKit
import XCTest
@testable import TerminalDeckNative

@MainActor
final class NativeActionMenuTests: XCTestCase {
    func testSlowReadUsesOriginalClickLocation() async {
        var pointer = NSPoint(x: 20, y: 30)
        var shown: NSPoint?
        let task = NativeActionMenu.popUp(location: { pointer }, load: {
            await Task.yield()
            pointer = NSPoint(x: 700, y: 800)
            return []
        }, show: { _, anchor in shown = anchor })
        await task.value
        XCTAssertEqual(shown, NSPoint(x: 20, y: 30))
        XCTAssertNotEqual(shown, pointer)
    }
    func testSharedBuilderKeepsSeparatorsChecksAndActions() {
        var presses = 0
        let menu = NativeActionMenu.make([
            .init(label: "Connected", enabled: true, checked: true, action: { presses += 1 }),
            .init(separator: true, label: "", enabled: false),
            .init(label: "Unavailable", enabled: false, action: { presses += 10 }),
        ])
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertEqual(menu.items[0].state, .on)
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertFalse(menu.items[2].isEnabled)
        (menu.items[0].representedObject as? BindMenuHandler)?.fire()
        XCTAssertEqual(presses, 1)
    }
}
