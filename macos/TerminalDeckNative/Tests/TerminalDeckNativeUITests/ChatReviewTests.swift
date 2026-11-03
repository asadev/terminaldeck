import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class ChatReviewTests: XCTestCase {
    func testOnlySupportedScopesPrepareAndFindingsComeFromEmittedCurrentReview() throws {
        XCTAssertEqual(try NativeChatReview.command(provider: "codex", offered: true, scope: "uncommitted", custom: "", draftEmpty: true), "/review")
        XCTAssertEqual(try NativeChatReview.command(provider: "codex", offered: true, scope: "custom", custom: "Check cancellation", draftEmpty: true), "/review Check cancellation")
        XCTAssertThrowsError(try NativeChatReview.command(provider: "codex", offered: true, scope: "commit", custom: "abc", draftEmpty: true))
        XCTAssertThrowsError(try NativeChatReview.command(provider: "codex", offered: true, scope: "custom", custom: "Check", draftEmpty: false))
        let user = HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: .codex, record: .text(.user, "/review"))
        let findings = HootChatEvent(conversationID: "c", turnID: "t", sequence: 2, provider: .codex, record: .init(.message, value: .object([.init("findings", .array([.object([.init("title", .string("Real finding")), .init("line", .number(1e30)), .init("body", .string("Reported detail"))])]))])))
        XCTAssertEqual(NativeChatReview.findings([user, findings]).first?.recordID, "c:2")
        XCTAssertNil(NativeChatReview.findings([user, findings]).first?.line)
        let next = HootChatEvent(conversationID: "c", turnID: "next", sequence: 3, provider: .codex, record: .text(.user, "/review Check another scope"))
        XCTAssertTrue(NativeChatReview.findings([user, findings, next]).isEmpty)
    }
}
