import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BrowserRegexLimitTests: XCTestCase {
    func testCoverageBoundsAndSourceCaptures() throws {
        let match = try BackendBrowserScrapingRegex.coverageMatch("of 1,234 results", pattern: #"of ([\d,]+)"#, flags: "i")
        XCTAssertEqual(match?.whole, "of 1,234")
        XCTAssertEqual(match?.group, "1,234")
        let generic = BackendS4AssetsCoverage.statedTotal(text: "of 42 results", pattern: nil, flags: nil)
        XCTAssertEqual(generic["total"].number, 42)
        let large = String(repeating: "a", count: BackendBrowserScrapingRegex.maximumTextBytes + 1)
        XCTAssertThrowsError(try BackendBrowserScrapingRegex.firstCapture(large, pattern: "a", flags: ""))
        XCTAssertThrowsError(try BackendS4AssetsCoverage.exec(large, pattern: "a", flags: ""))
    }

    func testHostilePatternsReturnAndTheNextCallStillWorks() throws {
        let text = String(repeating: "a", count: 8_000) + "!"
        let start = Date()
        // Both paths share the watchdog; repeated calls also exercise VM recovery.
        _ = try? BackendBrowserScrapingRegex.firstCapture(text, pattern: "(a+)+$", flags: "")
        _ = try? BackendS4AssetsCoverage.exec(text, pattern: "(a+)+$", flags: "")
        _ = try? BackendBrowserScrapingRegex.replace(text, pattern: "(a+)+$", replacement: "x", flags: "g")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(try BackendBrowserScrapingRegex.firstCapture("of 42", pattern: #"of (\d+)"#, flags: ""), "42")
        XCTAssertEqual(try BackendBrowserScrapingRegex.replace("/small/", pattern: "small", replacement: "big", flags: "g"), "/big/")
    }
}
