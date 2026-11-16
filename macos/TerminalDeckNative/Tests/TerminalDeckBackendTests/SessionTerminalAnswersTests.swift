import Foundation
import XCTest
@testable import TerminalDeckBackend

/// 14 Nov (Asad: "crm session says 27m ago but i did not used this session since yesterday"): a terminal attaching
/// after an app start (or a phone opening the session) replays its screen and answers the questions in it; those
/// answers must never count as the person using the session.
final class SessionTerminalAnswersTests: XCTestCase {
    private func typing(_ text: String) -> Bool { BackendPTYManager.isTyping(Data(text.utf8)) }

    func testAnswersThatAreStringsAreNotTyping() {
        XCTAssertFalse(typing("\u{1b}]11;rgb:1e1e/1e1e/1e1e\u{1b}\\"), "its background colour, ended by ST")
        XCTAssertFalse(typing("\u{1b}]10;rgb:ffff/ffff/ffff\u{07}"), "its text colour, ended by BEL")
        XCTAssertFalse(typing("\u{1b}P>|SwiftTerm(1.2)\u{1b}\\"), "its name (XTVERSION)")
        XCTAssertFalse(typing("\u{1b}P1$r0m\u{1b}\\\u{1b}[?1;2c\u{1b}]11;rgb:0/0/0\u{1b}\\"), "several answers at once")
        XCTAssertFalse(typing("\u{1b}]11;rgb:0/0/0"), "an answer cut at the end of a write")
    }

    func testLegacyMouseReportIsNotTyping() {
        XCTAssertFalse(typing("\u{1b}[M !!"), "X10 mouse: button and position as raw bytes")
        XCTAssertFalse(typing("\u{1b}[M#ab\u{1b}[M ab"), "two reports")
    }

    func testRealTypingStillCounts() {
        XCTAssertTrue(typing("\u{1b}]11;rgb:0/0/0\u{1b}\\ls\r"), "typing after an answer")
        XCTAssertTrue(typing("\u{1b}[M !!x"), "a key after a mouse report")
        XCTAssertTrue(typing("\u{1b}[200~pasted\u{1b}[201~"), "a paste")
        XCTAssertTrue(typing("\r"), "Return")
        XCTAssertTrue(typing("\u{1b}[1;5Mx"), "a CSI ending in M with parameters is not a mouse report")
    }
}
