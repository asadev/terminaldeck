import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class ChatLibraryTests: XCTestCase {
    func testResumeNamesExactConversationAndKeepsChatMode() throws {
        let row = NativeRPCValue.object([.init("sessionId", .string("recorded-123")), .init("path", .string("/project/recorded.jsonl"))])
        let input = try NativeChatLibrary.resumeInput(row, cwd: "/project")
        XCTAssertEqual(input["resumeConversationId"].string, "recorded-123")
        XCTAssertEqual(input["provider"].string, "claude")
        XCTAssertEqual(input["chat"].bool, true)
        XCTAssertTrue(NativeChatLibrary.matches(row, query: "RECORDED"))
        XCTAssertFalse(NativeChatLibrary.matches(row, query: "different"))
        XCTAssertThrowsError(try NativeChatLibrary.resumeInput(.object([.init("sessionId", .string("--bad"))]), cwd: "/project"))
    }
}
