import XCTest
@testable import TerminalDeckNativeCore

final class ChatReportedUsageTests: XCTestCase {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }
    private func event(_ value: NativeRPCValue, provider: HootChatProvider = .claude, turn: String = "turn", sequence: Int = 1) -> HootChatEvent {
        .init(conversationID: "conversation", turnID: turn, sequence: sequence, provider: provider, record: .init(.completed, value: value), at: Double(sequence * 1000))
    }
    func testClaudeDecoderKeepsReportedCostAndTokenCategories() throws {
        var decoder = HootChatDecoder(provider: .claude)
        let record = try XCTUnwrap(decoder.decode(json(#"{"type":"result","subtype":"success","session_id":"fixture","total_cost_usd":0.0123,"usage":{"input_tokens":12,"output_tokens":3,"cache_read_input_tokens":5,"cache_creation_input_tokens":2}}"#)).last)
        let reading = ChatReportedUsage.latest([event(record.value)])
        XCTAssertEqual(reading["costUSD"].number, 0.0123)
        XCTAssertEqual(reading["inputTokens"].number, 12)
        XCTAssertEqual(reading["outputTokens"].number, 3)
        XCTAssertEqual(reading["cachedInputTokens"].number, 5)
        XCTAssertEqual(reading["cacheWriteTokens"].number, 2)
        XCTAssertTrue(reading["totalTokens"].isNullish, "No total was reported; do not invent one from categories with different cache semantics.")
    }
    func testLatestCumulativeReportReplacesEarlierValuesWithoutSumming() throws {
        let first = event(try json(#"{"costUSD":0.1,"usage":{"input_tokens":10}}"#))
        let second = event(try json(#"{"costUSD":0.2,"usage":{"input_tokens":15}}"#), turn: "second", sequence: 2)
        let reading = ChatReportedUsage.latest([first, first, second])
        XCTAssertEqual(reading["costUSD"].number, 0.2)
        XCTAssertEqual(reading["inputTokens"].number, 15)
        XCTAssertEqual(reading["turnId"].string, "second")
        XCTAssertEqual(reading["reportedAt"].number, 2000)
    }
    func testZeroIsAReadingButMissingInvalidAndNegativeFiguresStayUnknown() throws {
        let zeros = ChatReportedUsage.metrics(try json(#"{"input_tokens":0,"output_tokens":0,"total_tokens":0}"#), cost: .number(0))
        XCTAssertEqual(zeros["costUSD"].number, 0)
        XCTAssertEqual(zeros["inputTokens"].number, 0)
        let invalid = ChatReportedUsage.metrics(try json(#"{"input_tokens":-1,"output_tokens":"2","total_tokens":0.5}"#), cost: .number(-1))
        XCTAssertEqual(invalid, .object([]))
        XCTAssertEqual(ChatReportedUsage.latest([]), .null)
        XCTAssertEqual(ChatReportedUsage.latest([event(.object([]))]), .null)
    }
    func testHandoverKeepsReportProvenanceAndNeverBorrowsOldProviderCost() throws {
        let claude = event(try json(#"{"costUSD":1,"usage":{"input_tokens":10}}"#))
        let codex = HootChatEvent(conversationID: "conversation", turnID: "codex-turn", sequence: 2, provider: .codex,
            record: .init(.session, value: try json(#"{"cliUsage":{"totalTokens":20,"scope":"Conversation total"}}"#)), at: 2000)
        let reading = ChatReportedUsage.latest([claude, codex])
        XCTAssertEqual(reading["provider"].string, "codex")
        XCTAssertEqual(reading["totalTokens"].number, 20)
        XCTAssertTrue(reading["costUSD"].isNullish)
        XCTAssertEqual(reading["scope"].string, "Conversation total")
    }
}
