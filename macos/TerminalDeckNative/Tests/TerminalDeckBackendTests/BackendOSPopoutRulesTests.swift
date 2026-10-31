import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSPopoutRulesTests: XCTestCase {
    typealias R = BackendOSPopoutRules.Rect
    let laptop = BackendOSPopoutRules.Display(id: 1, label: "Built-in", bounds: R(x: 0, y: 0, width: 1440, height: 900), workArea: R(x: 0, y: 24, width: 1440, height: 826))
    func testDisconnectedDisplayReturnsReachableTitleBarAndReconnectUsesGeometry() {
        let missing = BackendOSPopoutRules.Placement(key: "tab", bounds: R(x: 3000, y: -900, width: 2400, height: 1300), displayID: 7, fullScreen: false)
        let restored = BackendOSPopoutRules.restored(missing, displays: [laptop], primary: laptop)
        XCTAssertEqual(restored.outcome, "fallback-primary"); XCTAssertTrue(BackendOSPopoutRules.reachable(restored.bounds, on: laptop))
        XCTAssertLessThanOrEqual(restored.bounds.width, laptop.workArea.width)
        let movedID = BackendOSPopoutRules.Placement(key: "tab", bounds: R(x: 100, y: 30, width: 900, height: 640), displayID: 99, fullScreen: false)
        XCTAssertEqual(BackendOSPopoutRules.restored(movedID, displays: [laptop], primary: laptop).outcome, "moved-display")
    }
    func testTinyDisplayWinsOverMinimumWindowSizeAndPointEdgesAreExclusive() {
        let tiny = R(x: -300, y: -200, width: 200, height: 100)
        let fit = BackendOSPopoutRules.fit(R(x: 1000, y: 1000, width: 960, height: 640), into: tiny)
        XCTAssertEqual(fit, tiny)
        XCTAssertNil(BackendOSPopoutRules.displayAt(x: 1440, y: 200, displays: [laptop]))
        XCTAssertNotNil(BackendOSPopoutRules.displayAt(x: 1439, y: 200, displays: [laptop]))
    }
    func testCorruptDuplicateAndUnknownVersionPlacementEntries() {
        let good = BackendOSPopoutRules.Placement(key: "same", bounds: R(x: 20, y: 40, width: 600, height: 400), displayID: 1, fullScreen: true)
        let invalid = NativeRPCValue.object([.init("key", .string("bad")), .init("bounds", R(x: 0, y: 0, width: 0, height: 400).wireValue)])
        let file = NativeRPCValue.object([.init("v", .number(1)), .init("windows", .array([invalid, good.wireValue, good.wireValue]))])
        XCTAssertEqual(BackendOSPopoutRules.readPlacements(file), [good])
        XCTAssertTrue(BackendOSPopoutRules.readPlacements(file.setting("v", .number(2))).isEmpty)
        XCTAssertEqual(BackendOSPopoutRules.readPlacements(BackendOSPopoutRules.file([good])), [good])
    }
    func testExistingCoordinatesRoundTripAndNegativeHalfMatchesJavaScript() {
        let native = R(x: -800, y: 330, width: 700, height: 400)
        let stored = BackendOSPopoutRules.fromAppKit(native, primaryTop: 900)
        XCTAssertEqual(stored.y, 170)
        XCTAssertEqual(BackendOSPopoutRules.toAppKit(stored, primaryTop: 900), native)
        XCTAssertEqual(BackendOSPopoutRules.round(-0.5), 0)
        XCTAssertEqual(BackendOSPopoutRules.Rect.parse(R(x: -0.5, y: -0.5, width: 600, height: 400).wireValue)?.x, 0)
    }
}
