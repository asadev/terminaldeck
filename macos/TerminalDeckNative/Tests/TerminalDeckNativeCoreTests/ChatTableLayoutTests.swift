import XCTest
@testable import TerminalDeckNativeCore

final class ChatTableLayoutTests: XCTestCase {
    func testThreeColumnsFitNarrowAndWideAndFollowContent() throws {
        for available in [288.0, 360, 760, 1200] {
            let widths = try XCTUnwrap(ChatTableLayout.widths(header: ["Job", "Where", "Rules"], rows: [["Fix", String(repeating: "long description ", count: 8), "Confirmed"]], available: available))
            XCTAssertEqual(widths.reduce(0, +) + 24, available, accuracy: 0.001)
            XCTAssertTrue(widths.allSatisfy { $0 >= 80 })
            if available > 288 { XCTAssertGreaterThan(widths[1], widths[0]) }
        }
    }
    func testSixColumnsStackOnPhoneAndFitWide() throws {
        let header = (1...6).map { "Column \($0)" }
        XCTAssertNil(ChatTableLayout.widths(header: header, rows: [], available: 360))
        let widths = try XCTUnwrap(ChatTableLayout.widths(header: header, rows: [], available: 760))
        XCTAssertEqual(widths.reduce(0, +) + 60, 760, accuracy: 0.001)
    }
    func testInvalidSizesEmptyAndRaggedTablesStayBounded() {
        for width in [0.0, -1, .infinity, .nan] { XCTAssertNil(ChatTableLayout.widths(header: ["A"], rows: [], available: width)) }
        XCTAssertNil(ChatTableLayout.widths(header: [], rows: [], available: 360))
        XCTAssertEqual(ChatTableLayout.widths(header: ["A"], rows: [["1", "2", "3"]], available: 360)?.count, 3)
    }
}
