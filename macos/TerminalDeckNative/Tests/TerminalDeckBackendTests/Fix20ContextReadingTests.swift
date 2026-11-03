import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class Fix20ContextReadingTests: XCTestCase {
    func testReportedChatTokensUseTheCLIsWindowAndKeepTheirOriginalTime() throws {
        let wire = BackendCodexChatCommands.contextReading(tokens: 80_000, window: 828_400, reportedAt: 1_000, sessionID: "thread")
        let reading = try XCTUnwrap(ContextReading.decode(wire.foundation))
        XCTAssertEqual(reading.tokens, 80_000); XCTAssertEqual(reading.window, 828_400)
        XCTAssertEqual(try XCTUnwrap(reading.percent), 80_000.0 / 828_400 * 100, accuracy: 0.0001)
        XCTAssertEqual(reading.reportedAt, 1_000); XCTAssertFalse(reading.inferred)
        XCTAssertTrue(reading.isFresh(now: 1_000)); XCTAssertFalse(reading.isFresh(now: 1_000_000))
    }
    func testMissingMeasurementsStayUnknownAndNeverBecomeZeroPercent() throws {
        XCTAssertTrue(BackendCodexChatCommands.contextReading(tokens: 0, window: 828_400, reportedAt: nil, sessionID: nil).isNullish)
        let wire = BackendCodexChatCommands.contextReading(tokens: 100, window: nil, reportedAt: 1_000, sessionID: "thread")
        let reading = try XCTUnwrap(ContextReading.decode(wire.foundation))
        XCTAssertEqual(reading.tokens, 100); XCTAssertNil(reading.window); XCTAssertNil(reading.percent)
    }
}
