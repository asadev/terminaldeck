import XCTest
import Foundation
import TerminalDeckNativeCore

/// device-tree.test.ts. Blocked: the five findNodes cases (no Swift findNodes exists).
final class BackendFoundationTestsS6C5DeviceTree: XCTestCase {
    private func s6c5Rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormRect { NormRect(x: x, y: y, width: w, height: h) }

    private func s6c5Settings() -> DeviceNode {
        let image = DeviceNode(ref: "ax:5a", role: "AXImage", frame: s6c5Rect(0.06, 0.455, 0.06, 0.03))
        let general = DeviceNode(ref: "ax:5", role: "AXButton", label: "General", identifier: "com.apple.settings.general",
                                 frame: s6c5Rect(0.04, 0.444, 0.92, 0.062), children: [image])
        let access = DeviceNode(ref: "ax:6", role: "AXButton", label: "Accessibility", identifier: "com.apple.settings.accessibility",
                                frame: s6c5Rect(0.04, 0.506, 0.92, 0.062))
        let hidden = DeviceNode(ref: "ax:7", role: "AXButton", label: "Hidden one", hidden: true, frame: s6c5Rect(0.04, 0.6, 0.92, 0.062))
        let group = DeviceNode(ref: "ax:2", role: "AXGroup", identifier: "com.apple.settings.sidebar.collectionView",
                               frame: s6c5Rect(0, 0, 1, 1), children: [general, access, hidden])
        let heading = DeviceNode(ref: "ax:1", role: "AXHeading", label: "Settings", frame: s6c5Rect(0.04, 0.137, 0.331, 0.049))
        return DeviceNode(ref: "ax:0", role: "AXApplication", label: "Settings", frame: s6c5Rect(0, 0, 1, 1), children: [heading, group])
    }

    func testElementUnderPointIsSmallestNamedNotTheScreen() {
        XCTAssertEqual(DeviceTreeQuery.elementAt(s6c5Settings(), x: 0.5, y: 0.475)?.label, "General")
    }

    func testButtonNotTheUnlabelledPictureInsideIt() {
        XCTAssertEqual(DeviceTreeQuery.elementAt(s6c5Settings(), x: 0.08, y: 0.47)?.label, "General")
    }

    func testFallsBackToSmallestHolderWhenNothingNamedDoes() {
        XCTAssertNotNil(DeviceTreeQuery.elementAt(s6c5Settings(), x: 0.9, y: 0.3)?.ref)
    }

    func testNeverPicksAHiddenElement() {
        XCTAssertNotEqual(DeviceTreeQuery.elementAt(s6c5Settings(), x: 0.5, y: 0.63)?.label, "Hidden one")
    }

    func testReadsAChainThatIsNotATreeWithoutHanging() {
        var node = DeviceNode(ref: "x399")
        for i in stride(from: 398, through: 0, by: -1) { node = DeviceNode(ref: "x\(i)", children: [node]) }
        let loop = DeviceNode(ref: "x", children: [node])
        XCTAssertLessThanOrEqual(DeviceTreeQuery.flatten(loop).count, 202)
    }

    func testSaysRolesTheWayAPersonWould() {
        XCTAssertEqual(DeviceTreeQuery.plainRole("AXButton"), "button")
        XCTAssertEqual(DeviceTreeQuery.plainRole("AXTextField"), "text field")
        XCTAssertEqual(DeviceTreeQuery.plainRole("android.widget.TextView"), "text view")
        XCTAssertEqual(DeviceTreeQuery.plainRole(nil), "")
    }

    func testNamesANodeByItsLabelFirst() {
        XCTAssertEqual(DeviceTreeQuery.nodeName(DeviceNode(ref: "a", label: "Pay", identifier: "pay-button")), "Pay")
        XCTAssertEqual(DeviceTreeQuery.nodeName(DeviceNode(ref: "a", identifier: "pay-button")), "pay-button")
    }

    func testTapsTheMiddleOfAnElement() throws {
        let general = s6c5Settings().children[1].children[0]
        let c = try XCTUnwrap(DeviceTreeQuery.centre(of: general))
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.y, 0.475, accuracy: 1e-9)
        XCTAssertNil(DeviceTreeQuery.centre(of: DeviceNode(ref: "none")))
    }
}
