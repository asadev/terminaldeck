import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class ChatLimitsTests: XCTestCase {
    func testLimitsAreSelectedByProviderAndAccountAndExpiredUsageStaysUnknown() {
        func reading(_ account: String) -> NativeRPCValue { .object([.init("id", .string(account)), .init("account", .object([.init("provider", .string("codex")), .init("id", .string(account))])), .init("window", .string("five-hour")), .init("label", .string("5 hour")), .init("used", .object([.init("kind", .string("reported")), .init("fraction", .number(0.75))])), .init("resets", .object([.init("kind", .string("at")), .init("at", .number(50000))])), .init("observedAt", .number(1000)), .init("reportedAt", .number(1000)), .init("source", .string("codex-rollout"))]) }
        let all = NativeRPCValue.object([.init("readings", .array([reading("selected"), reading("other")]))])
        let selected = NativeChatLimits.selectedReport(all, provider: "codex", profileID: "selected", name: "Selected")
        XCTAssertEqual(selected["readings"].elements?.count, 1)
        let rows = SessionChatUsageSummary.rows(UsageReport.decode(selected.foundation), now: 100000)
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows.first?.percent)
        XCTAssertTrue(rows.first?.reset.contains("reset") == true)
        XCTAssertTrue(NativeChatLimits.selectedReport(all, provider: "claude", profileID: "selected", name: nil)["readings"].elements?.isEmpty == true)
        XCTAssertTrue(NativeChatLimits.selectedReport(all, provider: "codex", profileID: nil, name: nil)["readings"].elements?.isEmpty == true)
    }
}
