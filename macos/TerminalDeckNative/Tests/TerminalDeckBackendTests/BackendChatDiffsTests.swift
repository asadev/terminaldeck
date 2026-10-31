import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatDiffsTests: XCTestCase {
    func testPermissionPromptDoesNotDuplicateItsToolDiff() throws {
        let value = try NativeRPCValue.parseJSON(Data(#"{"name":"Edit","input":{"file_path":"/tmp/owned-check.txt","old_string":"alpha","new_string":"beta"}}"#.utf8))
        let records: [HootChatRecord] = [
            .init(.toolCall, id: "tool", value: value),
            .init(.approval, id: "permission", value: value.setting("requestId", .string("permission")))
        ]
        let events = records.enumerated().map {
            HootChatEvent(conversationID: "owned", turnID: "turn", sequence: $0.offset + 1, provider: .claude, record: $0.element)
        }
        let cards = BackendChatDiffs.cards(HootChatProjection.rows(events))
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.rowID, "turn:tool")
        XCTAssertEqual(cards.first?.plus, 1)
        XCTAssertEqual(cards.first?.minus, 1)
    }
}
