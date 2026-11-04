import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatToolCardControlTests: XCTestCase {
    func testFinishedCardUsesTheViewsFoldAndRejectsLiveOrUnknownCards() throws {
        let events = [HootChatEvent(conversationID: "cards", turnID: "t", sequence: 1, provider: .codex, record: .text(.user, id: "u", "Check a file")),
            .init(conversationID: "cards", turnID: "t", sequence: 2, provider: .codex, record: .init(.toolCall, id: "read", value: .object([.init("name", .string("Read"))])))]
        func snapshot(_ busy: Bool) -> NativeRPCValue { .object([.init("conversationId", .string("cards")), .init("events", .array(events.map(\.wireValue))), .init("busy", .bool(busy))]) }
        let model = NativeHootChatModel(fixture: snapshot(false))
        let view = NativeChatFollowViewport()
        model.chatViewports[view.id] = view
        let card = try XCTUnwrap(try model.toolCardsTool("read", request: nil)["cards"].elements?.first?["id"].string)
        _ = try model.toolCardsTool("expand", request: card, viewID: view.id.uuidString)
        XCTAssertTrue(view.expandedCards.contains(card))
        _ = try model.toolCardsTool("collapse", request: card)
        XCTAssertFalse(view.expandedCards.contains(card))
        XCTAssertThrowsError(try model.toolCardsTool("expand", request: "unknown"))
        XCTAssertThrowsError(try model.toolCardsTool("expand", request: card, viewID: "unknown"))
        model.acceptFixtureUpdate(snapshot(true))
        XCTAssertThrowsError(try model.toolCardsTool("expand", request: card))
        XCTAssertTrue(view.expandedCards.isEmpty)
        XCTAssertTrue(model.composerDraft.text.isEmpty)
    }
}
