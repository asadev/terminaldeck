import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatToolCardPagingTests: XCTestCase {
    func testLongToolRunKeepsItsOriginalCardAcrossPageBoundaries() throws {
        var events = [HootChatEvent(conversationID: "paged", turnID: "t", sequence: 1, provider: .codex, record: .text(.user, id: "ask", "Check these files"))]
        events += (2...85).map { index in
            .init(conversationID: "paged", turnID: "t", sequence: index, provider: .codex,
                  record: .init(.toolCall, id: "read-\(index)", value: .object([.init("name", .string("Read"))])))
        }
        events.append(.init(conversationID: "paged", turnID: "t", sequence: 86, provider: .codex, record: .text(.message, id: "answer", "All checked.")))
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("paged")),
            .init("events", .array(events.map(\.wireValue))), .init("busy", .bool(false))]))
        let view = NativeChatFollowViewport()
        model.chatViewports[view.id] = view
        let toolID = try XCTUnwrap(try model.toolCardsTool("read", request: nil)["cards"].elements?.first?["id"].string)
        XCTAssertEqual(toolID, model.displayRows.first?.id)
        for count in [1, 60, 120] {
            let replies = HootChatItem.page(model.displayRows, count: count).compactMap { item -> String? in
                if case .reply(let key, _, _, _) = item { return key }; return nil
            }
            XCTAssertEqual(replies, [toolID], "A page must keep the same tool-card and reply identity")
        }
        _ = try model.toolCardsTool("expand", request: toolID, viewID: view.id.uuidString)
        XCTAssertTrue(view.expandedCards.contains(toolID))
        XCTAssertTrue(HootChatItem.page(model.displayRows, count: 0).isEmpty)
    }
}
