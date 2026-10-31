import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatDetailTests: XCTestCase {
    func testDetailsUseOnlyEmittedEventsAndKeepNormalFindSeparate() throws {
        let events = [HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: .codex, record: .init(.toolResult, value: .object([.init("output", .string("needle tool result"))])))]
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("c")), .init("events", .array(events.map(\.wireValue)))]))
        let opened = try model.detailTool("open", query: "NEEDLE")
        XCTAssertEqual(opened["mode"].string, "events")
        XCTAssertEqual(opened["matches"].number, 1)
        XCTAssertTrue(opened["selected"]["text"].string?.contains("needle tool result") == true)
        XCTAssertEqual(model.detailRecords("needle").count, 1)
        XCTAssertTrue(model.detailRecords("absent").isEmpty)
        XCTAssertFalse(model.findVisible)
        XCTAssertEqual(try model.detailTool("close")["mode"].string, "normal")
        XCTAssertThrowsError(try model.detailTool("read", recordID: "invented"))
    }
}
