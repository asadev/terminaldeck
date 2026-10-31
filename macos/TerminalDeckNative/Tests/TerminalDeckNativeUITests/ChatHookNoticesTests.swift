import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatHookNoticesTests: XCTestCase {
    func testOnlyStructuredHooksBecomeNoticesWithExplicitTrustAndStopReason() {
        func event(_ n: Int, _ value: NativeRPCValue) -> HootChatEvent { .init(conversationID: "c", turnID: "t", sequence: n, provider: .claude, record: .init(.session, value: value)) }
        let warning = event(1, .object([.init("hook", .object([.init("name", .string("PreToolUse")), .init("status", .string("warning")), .init("message", .string("Policy check")), .init("stopReason", .string("Needs review")), .init("trusted", .bool(false))]))]))
        let success = event(2, .object([.init("hook", .object([.init("name", .string("PostToolUse")), .init("status", .string("success")), .init("message", .string("do-not-show-success-stdout"))]))]))
        let unrelated = event(3, .object([.init("text", .string("hook failed in ordinary prose"))]))
        let rows = NativeChatHooks.rows([warning, success, unrelated])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0]["detail"].string?.contains("untrusted") == true)
        XCTAssertTrue(rows[0]["detail"].string?.contains("Needs review") == true)
        XCTAssertFalse(rows[1].compact.contains("do-not-show-success-stdout"))
        XCTAssertTrue(rows[1]["detail"].string?.contains("Trust not reported") == true)
    }
    func testCompletedHookKeepsAnExplicitWarningWithoutSuccessfulStdout() {
        let hook: NativeRPCValue = .object([.init("status", .string("completed")), .init("warning", .string("Check the generated file")), .init("message", .string("successful-output-notice-must-not-replace-warning"))])
        let event = HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: .claude, record: .init(.session, value: .object([.init("hook", hook)])))
        let rows = NativeChatHooks.rows([event])
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0]["detail"].string?.contains("Check the generated file") == true)
        XCTAssertFalse(rows[0].compact.contains("successful-output-notice-must-not-replace-warning"))
    }

}
