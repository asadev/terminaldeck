import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatModelTimingTests: XCTestCase {
    func testSelectionAckDoesNotBecomeAppliedAndReceiptResetsWithConversation() {
        let queued = NativeChatModelTiming.state(requested: "codex:new", selected: "codex:old", applied: .null, queued: true, saving: false, busy: true)
        XCTAssertEqual(queued["applied"], .null)
        XCTAssertTrue(queued["timing"].string?.contains("current turn ends") == true)
        let saved = NativeChatModelTiming.state(requested: "codex:new", selected: "codex:new", applied: .null, queued: false, saving: false, busy: false)
        XCTAssertEqual(saved["applied"], .null)
        XCTAssertTrue(saved["timing"].string?.contains("not confirmed") == true)
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("one")), .init("appliedModel", .string("codex:old"))]))
        XCTAssertEqual(model.chatAppliedModelReceipt.string, "codex:old")
        model.acceptFixtureUpdate(.object([.init("conversationId", .string("two"))]))
        XCTAssertEqual(model.chatAppliedModelReceipt, .null)
    }
}
