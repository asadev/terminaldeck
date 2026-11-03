import XCTest
@testable import TerminalDeckNativeCore

final class ChatTranscriptExportTests: XCTestCase {
    func testExportsWholeJournalAndToolPayloadWithScope() throws {
        let events = (1...80).map { index in HootChatEvent(conversationID: "conversation", turnID: "turn", sequence: index, provider: .codex, record: .text(.user, id: "\(index)", "Message \(index)"), at: 1000) }
        let tool = HootChatEvent(conversationID: "conversation", turnID: "turn", sequence: 81, provider: .codex,
            record: .init(.toolResult, value: .object([.init("output", .string("`````\ncomplete tool output")), .init("path", .string("/scratch/file.txt"))])), at: 1001)
        let text = try ChatTranscriptExport.markdown(events: events + [tool], session: "session", conversation: "conversation")
        XCTAssertTrue(text.contains("Message 1\n"))
        XCTAssertTrue(text.contains("Message 80"))
        XCTAssertTrue(text.contains("complete tool output"))
        XCTAssertTrue(text.contains("Records: 81"))
        XCTAssertTrue(text.contains("file/image/audio bytes are not embedded"))
        XCTAssertTrue(text.contains("``````json"))
    }
}
