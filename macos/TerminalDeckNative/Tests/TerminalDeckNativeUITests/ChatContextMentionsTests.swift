import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatContextMentionsTests: XCTestCase {
    func testContextInsertionAndRecordedReceiptsNeverClaimDelegation() throws {
        let mention = HootMention(id: "a1", kind: .agent, name: "Builder")
        let event = HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: .codex, record: .init(.user, value: .object([.init("text", .string("Question")), .init("context", .object([.init("mentions", .array([mention.wire]))]))])))
        let model = NativeHootChatModel(fixture: .object([.init("events", .array([event.wireValue])), .init("mentions", .array([mention.wire]))]))
        model.composerDraft.text = "Keep "; model.composerDraft.add([URL(fileURLWithPath: "/scratch/file.txt")])
        _ = try model.mentionsTool("insert", request: mention.marker)
        XCTAssertEqual(model.composerDraft.text, "Keep " + mention.marker)
        XCTAssertEqual(model.composerDraft.attachments.count, 1)
        let receipt = try XCTUnwrap(NativeChatMentions.receipts([event]).first)
        XCTAssertTrue(receipt["detail"].string?.contains("not inferred") == true)
        XCTAssertThrowsError(try model.mentionsTool("insert", request: "missing"))
    }
}
