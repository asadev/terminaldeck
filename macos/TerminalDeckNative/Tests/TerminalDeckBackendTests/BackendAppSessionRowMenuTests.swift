import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppSessionRowMenuTests: XCTestCase {
    func testMovesDeleteAndBrowserGates() {
        let own = BackendAppSessionRowMenu.items(.object([.init("window", .string("own")), .init("browser", .bool(true)), .init("close", .bool(true))]))
        XCTAssertEqual(own.compactMap(\.choice), ["promote", "show-window", "dock", "close"])
        XCTAssertFalse(own.contains { $0.browserSubmenu }); XCTAssertEqual(own.last?.label, "Delete")
        let blocked = BackendAppSessionRowMenu.items(.object([.init("promoteBlocked", .string("The strip is full."))]))
        XCTAssertFalse(blocked[0].enabled); XCTAssertEqual(blocked[0].detail, "The strip is full.")
        let promoted = BackendAppSessionRowMenu.items(.object([.init("promoted", .bool(true)), .init("promoteBlocked", .string("The strip is full."))]))
        XCTAssertTrue(promoted[0].enabled)
    }
    func testPickerSkipsDeadAndBarePaths() {
        XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: ["/Volumes/Gone/x", "/Users/person/Projects/app"], home: "/Users/person", exists: { $0 == "/Users/person/Projects" }), "/Users/person/Projects")
        XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: ["app", ""], home: "/Users/person", exists: { _ in true }), "/Users/person")
    }
}
