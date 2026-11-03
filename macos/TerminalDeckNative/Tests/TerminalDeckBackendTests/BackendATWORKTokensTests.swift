import XCTest
@testable import TerminalDeckBackend

/// Transcript strings and a fixed calendar only; no files or real AI calls.
final class BackendATWORKTokensTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TD_ATWORK_FOCUSED"] == "1" else { throw XCTSkip("WIP ATWORK") }
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 4 * 3600)!
        return value
    }
    private var now: Date {
        ISO8601DateFormatter().date(from: "2026-10-10T12:00:00+04:00")!
    }
    private func today(_ lines: [String], provider: String = "claude") throws -> Double? {
        try BackendATWORKTokens.today(lines: lines, provider: provider, now: now, calendar: calendar)
    }

    func testClaudeTodayUsesLocalMidnightAndDeduplicatesStreamingMaxima() throws {
        let lines = [
            #"{"timestamp":"2026-10-09T23:59:59+04:00","type":"assistant","requestId":"old","message":{"id":"old","usage":{"input_tokens":1000,"output_tokens":1000}}}"#,
            #"{"timestamp":"2026-10-10T00:00:00+04:00","type":"assistant","requestId":"new","message":{"id":"new","usage":{"input_tokens":100,"output_tokens":10}}}"#,
            #"{"timestamp":"2026-10-10T00:00:01+04:00","type":"assistant","requestId":"new","message":{"id":"new","usage":{"input_tokens":100,"output_tokens":20}}}"#,
        ]
        XCTAssertEqual(try today(lines), 120)
    }

    func testClaudeRequestStartedYesterdayIsNeverChargedAsLifetimeToday() throws {
        let lines = [
            #"{"timestamp":"2026-10-09T23:59:59+04:00","type":"assistant","requestId":"one","message":{"id":"one","usage":{"input_tokens":100,"output_tokens":10}}}"#,
            #"{"timestamp":"2026-10-10T00:00:01+04:00","type":"assistant","requestId":"one","message":{"id":"one","usage":{"input_tokens":100,"output_tokens":20}}}"#,
        ]
        XCTAssertEqual(try today(lines), 0)
    }

    func testCodexSubtractsBeforeMidnightCumulativeBaseline() throws {
        let lines = [
            #"{"timestamp":"2026-10-09T23:59:59+04:00","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5000}}}}"#,
            #"{"timestamp":"2026-10-10T01:00:00+04:00","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5300}}}}"#,
            #"{"timestamp":"2026-10-10T02:00:00+04:00","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5500}}}}"#,
        ]
        XCTAssertEqual(try today(lines, provider: "codex"), 500)
    }

    func testCodexWithoutBaselineOrNewSessionProofStaysUnavailable() throws {
        let row = #"{"timestamp":"2026-10-10T01:00:00+04:00","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":5300}}}}"#
        XCTAssertNil(try today([row], provider: "codex"))
        let fork = #"{"timestamp":"2026-10-10T00:30:00+04:00","type":"session_meta","payload":{"forked_from_id":"previous"}}"#
        XCTAssertNil(try today([fork, row], provider: "codex"))
        let fresh = #"{"timestamp":"2026-10-10T00:30:00+04:00","type":"session_meta","payload":{"forked_from_id":null}}"#
        XCTAssertEqual(try today([fresh, row], provider: "codex"), 5300)
    }

    func testGeminiDuplicateMessagesCountOnlyLargestTodayValue() throws {
        let lines = [
            #"{"timestamp":"2026-10-09T21:00:00+04:00","type":"gemini","id":"old","tokens":{"total":5000}}"#,
            #"{"timestamp":"2026-10-10T01:00:00+04:00","type":"gemini","id":"new","tokens":{"total":100}}"#,
            #"{"timestamp":"2026-10-10T01:00:01+04:00","type":"gemini","id":"new","tokens":{"total":140}}"#,
        ]
        XCTAssertEqual(try today(lines, provider: "gemini"), 140)
    }

    func testMissingUnsupportedAndFutureUsageDoNotPretendToBeToday() throws {
        XCTAssertNil(try today([]))
        XCTAssertNil(try today(["{}"], provider: "unsupported"))
        let future = #"{"timestamp":"2026-10-11T00:00:00+04:00","type":"assistant","requestId":"future","message":{"id":"future","usage":{"input_tokens":100,"output_tokens":20}}}"#
        XCTAssertEqual(try today([future]), 0)
    }
}
