import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatEffectivePolicyTests: XCTestCase {
    func testBypassIsNotSandboxOrTrustEvidenceAndOnlyProviderSessionRecordsCount() {
        let unknown = NativeChatPolicy.state(.object([]), source: nil, choice: .bypass)
        for key in ["sandbox", "approval", "workspaceTrust", "network"] { XCTAssertEqual(unknown["effective"][key], .null) }
        XCTAssertEqual(unknown["appPermissionChoice"].string, "bypass")
        let policy: NativeRPCValue = .object([.init("authority", .string("provider-response")), .init("sandbox", .object([.init("type", .string("workspace-write")), .init("writableRoots", .array([.string("/scratch/project")])), .init("env", .string("not-policy-secret"))])), .init("network", .bool(false))])
        func event(_ kind: HootChatKind) -> HootChatEvent { .init(conversationID: "c", turnID: "t", sequence: 1, provider: .codex, record: .init(kind, value: .object([.init("effectivePolicy", policy)]))) }
        XCTAssertNil(NativeChatPolicy.effective([event(.user)], current: policy).1)
        let (actual, source) = NativeChatPolicy.effective([event(.session)], current: policy)
        let state = NativeChatPolicy.state(actual, source: source, choice: .ask)
        XCTAssertEqual(state["effective"]["sandbox"]["type"].string, "workspace-write")
        XCTAssertEqual(state["effective"]["network"].bool, false)
        XCTAssertFalse(state.compact.contains("not-policy-secret"))
    }
    func testHistoricalPolicyCannotOverrideMissingCurrentProcessReceipt() {
        let old: NativeRPCValue = .object([.init("authority", .string("provider-response")), .init("sandbox", .string("workspace-write"))])
        let event = HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: .codex, record: .init(.session, value: .object([.init("effectivePolicy", old)])))
        let (policy, source) = NativeChatPolicy.effective([event], current: .null)
        let state = NativeChatPolicy.state(policy, source: source, choice: .bypass)
        XCTAssertNil(source)
        XCTAssertEqual(state["effective"]["sandbox"], .null)
        XCTAssertEqual(state["appPermissionChoice"].string, "bypass")
    }

}
