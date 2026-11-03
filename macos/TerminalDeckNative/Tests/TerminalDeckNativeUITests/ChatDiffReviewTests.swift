import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatDiffReviewTests: XCTestCase {
    func testHunksRetainLineCoordinatesAndCommentPreservesDraft() async throws {
        let diff = "--- a/file.txt\n+++ b/file.txt\n@@ -12,2 +14,2 @@ title\n same\n-old\n+new\n@@ -20 +22 @@\n-a\n+b"
        let hunks = NativeChatDiffReview.hunks(diff)
        XCTAssertEqual(hunks.count, 2); XCTAssertEqual(hunks[0].oldLine, 12); XCTAssertEqual(hunks[0].newLine, 14)
        XCTAssertEqual(hunks[0].lines, [" same", "-old", "+new"])
        let event = HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: .codex, record: .init(.toolCall, id: "edit", value: .object([.init("name", .string("fileChange")), .init("input", .object([.init("changes", .array([.object([.init("path", .string("file.txt")), .init("diff", .string(diff))])]))]))])))
        let model = NativeHootChatModel(fixture: .object([.init("events", .array([event.wireValue]))]))
        model.composerDraft.text = "Keep"; model.composerDraft.add([URL(fileURLWithPath: "/scratch/ref.txt")])
        let entries = NativeChatDiffReview.entries(model.rows); XCTAssertEqual(entries.count, 2)
        _ = try await model.diffReviewTool("comment", request: entries.first?.id, text: "Explain this hunk")
        XCTAssertTrue(model.composerDraft.text.hasPrefix("Keep\n\nReview recorded diff"))
        XCTAssertTrue(model.composerDraft.text.contains("@@ -12,2 +14,2 @@"))
        XCTAssertEqual(model.composerDraft.attachments.count, 1)
    }
}
