import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppSessionRowMenuTests: XCTestCase {
    func testPickerSkipsDeadAndBarePaths() {
        XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: ["/Volumes/Gone/x", "/Users/person/Projects/app"], home: "/Users/person", exists: { $0 == "/Users/person/Projects" }), "/Users/person/Projects")
        XCTAssertEqual(BackendAppProjectPicker.startDirectory(projects: ["app", ""], home: "/Users/person", exists: { _ in true }), "/Users/person")
    }
}
