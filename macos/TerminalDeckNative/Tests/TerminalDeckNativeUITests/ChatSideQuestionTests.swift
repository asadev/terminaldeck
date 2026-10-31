import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatSideQuestionTests: XCTestCase {
    func testSeparateQuestionCapturesBoundedContextAndPreservesMainDraft() throws {
        let events = (1...15).map { n in HootChatEvent(conversationID: "main", turnID: "t", sequence: n, provider: .codex, record: .text(.message, String(repeating: "context", count: 200))) }
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("main")), .init("events", .array(events.map(\.wireValue)))]))
        model.composerDraft.text = "Keep main draft"
        model.composerDraft.add([URL(fileURLWithPath: "/scratch/main-reference.txt")])
        let saved = model.composerDraft
        let state = try model.sideTool("prepare", request: nil, text: "Explain this separately")
        XCTAssertEqual(model.composerDraft, saved)
        XCTAssertTrue(state["brief"].string?.contains("Explain this separately") == true)
        XCTAssertLessThanOrEqual(state["capturedSources"]["contextCharacters"].number ?? 9000, 8000)
        XCTAssertEqual(state["capturedSources"]["truncated"].bool, true)
        XCTAssertEqual(state["mainDraftChanged"].bool, false)
        // U126 (#541): a Codex chat's Side question uses its real side conversation; the text no longer says otherwise.
        XCTAssertFalse(state["capability"].string?.contains("not connected") == true)
        XCTAssertTrue(state["capability"].string?.contains("own side conversation") == true)
    }

    /// U126 (#541): Side question (opened by its tool since it left the chat's menu on 20 Oct 2026) asks the provider's
    /// side conversation when the chat's AI has one.
    func testSideQuestionUsesTheRealSideConversationAndShowsItsAnswer() {
        XCTAssertTrue(NativeChatSideQuestion.live(provider: "codex"))
        XCTAssertFalse(NativeChatSideQuestion.live(provider: "claude"))
        XCTAssertFalse(NativeChatSideQuestion.live(provider: nil))
        let events = [HootChatEvent(conversationID: "side", turnID: "s1", sequence: 1, provider: .codex, record: .text(.user, id: "q", "Why the retry?")),
                      HootChatEvent(conversationID: "side", turnID: "s1", sequence: 2, provider: .codex, record: .text(.textDelta, id: "a", "Because the ")),
                      HootChatEvent(conversationID: "side", turnID: "s1", sequence: 3, provider: .codex, record: .text(.textDelta, id: "a", "first call timed out."))]
        let lines = NativeChatSideQuestion.lines(.object([.init("busy", .bool(false)), .init("events", .array(events.map(\.wireValue)))]))
        XCTAssertEqual(lines.map { $0.kind == .user }, [true, false])
        XCTAssertEqual(lines.last?.value["text"].string, "Because the first call timed out.")
    }

    /// U126 (#547): a window ends only a side conversation it opened itself.
    func testClosingAWindowEndsOnlyASideConversationItOpened() {
        var owner = NativeChatSideOwner()
        owner.record("policy/read"); owner.record("side/read"); owner.record("side/send")
        XCTAssertFalse(owner.opened, "reading policy or a side conversation opened elsewhere never makes it this window's")
        owner.record("side/open")
        XCTAssertTrue(owner.opened)
        owner.record("side/close")
        XCTAssertFalse(owner.opened)
    }
}
