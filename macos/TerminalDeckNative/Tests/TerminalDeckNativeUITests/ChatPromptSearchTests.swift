import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatPromptSearchTests: XCTestCase {
    func testSearchIsScopedAndInsertionKeepsExistingDraftAndFiles() throws {
        let events = [HootChatKind.user, .message, .user].enumerated().map { index, kind in
            HootChatEvent(conversationID: "fixture", turnID: "turn", sequence: index + 1, provider: .codex,
                record: .text(kind, id: "m\(index)", index == 2 ? "Other prompt" : "Needle"))
        }
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("fixture")), .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true))]))
        XCTAssertEqual(model.searchPrompts("NEEDLE").count, 1)
        model.composerDraft.text = "Keep draft"
        model.composerDraft.add([URL(fileURLWithPath: "/scratch/reference.txt")])
        let attachments = model.composerDraft.attachments
        try model.insertPrompt(XCTUnwrap(model.searchPrompts("needle").first?.id))
        XCTAssertEqual(model.composerDraft.text, "Keep draft\n\nNeedle")
        XCTAssertEqual(model.composerDraft.attachments, attachments)
        XCTAssertThrowsError(try model.insertPrompt("another-conversation"))
    }
}
