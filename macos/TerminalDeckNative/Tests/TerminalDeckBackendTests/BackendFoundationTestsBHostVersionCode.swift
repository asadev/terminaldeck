import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendFoundationTestsBHostVersion: XCTestCase {
    private func update(_ host: String, _ mine: String, command: String = "/home/asad/.local/bin/terminaldeck") -> String? { ServerHostRules.updateAvailable(command: command, version: host, mine: mine) }
    func testBehindNumericOrderingLevelAndAhead() {
        XCTAssertEqual(update("0.10.1", "0.10.3"), "0.10.3")
        XCTAssertEqual(update("0.9.9", "0.10.0"), "0.10.0")
        XCTAssertEqual(update("0.9.1", "0.10.1"), "0.10.1")
        XCTAssertNil(update("0.10.1", "0.9.1")); XCTAssertNil(update("0.10.3", "0.10.3")); XCTAssertNil(update("0.11.0", "0.10.3"))
    }
    func testAbsentHostOddVersionsAndMissingVersionDefaultAreUnknown() {
        XCTAssertNil(update("", "0.10.3", command: "")); XCTAssertNil(update("0.1.0", "0.10.3", command: ""))
        for odd in ["", "unknown", "0.10.1-rc.1", "2026.08.24.1", "v", "0.a.1", "-1.0.0"] { XCTAssertNil(update(odd, "0.10.3"), odd) }
        // Source explicitly maps its missing/null dynamic field case to Swift's
        // nonoptional empty-string default rather than manufacturing a nil ABI.
        XCTAssertNil(update("", "0.10.3"))
    }
    func testLeadingVAndShortVersionArePadded() {
        XCTAssertEqual(update("v0.10.1", "0.10.3"), "0.10.3")
        XCTAssertEqual(update("0.10", "0.10.3"), "0.10.3")
        XCTAssertNil(update("1", "0.10.3"))
    }
}

final class BackendFoundationTestsBShortCodeReading: XCTestCase {
    func testPrintedDigitsAndAllSourceSeparatorSpellings() {
        for source in ["123456", " 123 456 ", "123-456", "123–456", "123\u{00A0}456", "1 2\t3\n4.5,6"] { XCTAssertEqual(PairingCodeParser.normalise(source), "123456", source) }
        XCTAssertEqual(PairingCodeParser.codeLength, 6)
    }
    func testLettersLengthsAndCredentialsCannotBecomeCodes() {
        for source in ["O23456", "12345I", "abcdef", "12345", "1234567", "", "------", "AbCdEfGhIjKl.0123456789abcdef", "123456.789012"] { XCTAssertNil(PairingCodeParser.normalise(source), source) }
    }
    func testHostilePasteBoundAndSixDigitRoundTripVectors() {
        XCTAssertNil(PairingCodeParser.normalise(String(repeating: "1", count: 1_000_000)))
        XCTAssertEqual(PairingCodeParser.normalise("123456" + String(repeating: " ", count: 1000)), "123456")
        for source in ["000000", "123456", "999999", "000007"] { XCTAssertEqual(PairingCodeParser.normalise(source), source) }
    }
}
