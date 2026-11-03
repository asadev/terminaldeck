import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class ChatAccountTests: XCTestCase {
    func testSelectedAccountAndAttributedSessionAreDifferentEvidence() {
        let selected = NativeRPCValue.object([.init("provider", .string("codex")), .init("profileId", .string("p")), .init("ready", .bool(true)), .init("accounts", .array([.object([.init("id", .string("p")), .init("name", .string("Example account")), .init("signedIn", .bool(true))])]))])
        XCTAssertEqual(NativeChatAccount.summary(selected, hoot: true, fallback: nil)["signedIn"].bool, true)
        let session = NativeChatAccount.summary(selected, hoot: false, fallback: nil)
        XCTAssertTrue(session["signedIn"].isNullish)
        XCTAssertEqual(session["provider"].string, "codex")
        XCTAssertEqual(NativeChatAccount.focusedProvider("claude"), "claude")
        XCTAssertNil(NativeChatAccount.focusedProvider("invented"))
    }
}
