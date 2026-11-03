import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatProviderFeaturePolicyTests: XCTestCase {
    func testSessionGrantCannotWidenProviderAccountOrStartAuthentication() throws {
        for caller in [BackendDeckCoreSecurityCaller.Kind.session, .remote, .key] {
            for operation in ["connections/enablePlugin", "connections/installPlugin", "connections/auth", "mcp/auth", "policy/change"] {
                XCTAssertThrowsError(try BackendChatProviderFeaturePolicy.authorize(operation, caller: caller))
            }
            XCTAssertNoThrow(try BackendChatProviderFeaturePolicy.authorize("connections/plugins", caller: caller))
            XCTAssertNoThrow(try BackendChatProviderFeaturePolicy.authorize("goals/set", caller: caller))
        }
        XCTAssertNoThrow(try BackendChatProviderFeaturePolicy.authorize("mcp/auth", caller: .local))
    }
    func testFeatureDoorRejectsArbitraryRPCAndUnboundedPageValues() throws {
        for method in ["config/value/write", "turn/start", "thread/start", "", "voice/events"] {
            if method == "voice/events" {
                XCTAssertThrowsError(try BackendChatProviderFeaturePolicy.validate(method, arguments: .object([.init("cursor", .number(1.5))])))
            } else { XCTAssertThrowsError(try BackendChatProviderFeaturePolicy.validate(method, arguments: .object([]))) }
        }
        for method in BackendChatProviderFeaturePolicy.operations {
            XCTAssertNoThrow(try BackendChatProviderFeaturePolicy.validate(method, arguments: .object([])))
        }
        XCTAssertFalse(BackendChatProviderFeaturePolicy.changes("catalogue/read"))
        XCTAssertTrue(BackendChatProviderFeaturePolicy.changes("side/open"))
        XCTAssertTrue(BackendChatProviderFeaturePolicy.changes("connections/enableApp"))
    }
    func testOldHelperDoesNotAdvertiseProviderFeatureSupport() throws {
        let old = Data(#"{"protocolVersion":2,"hostVersion":"old","hostPID":123,"instance":"00000000-0000-0000-0000-000000000001","chatService":1}"#.utf8)
        let hello = try JSONDecoder().decode(BackendHOSTProtocol.Hello.self, from: old)
        XCTAssertNil(hello.chatFeatures)
        XCTAssertEqual(hello.chatService, 1)
        XCTAssertEqual(Set(BackendChatProviderFeaturePolicy.operations).count, BackendChatProviderFeaturePolicy.operations.count)
        XCTAssertTrue(BackendSessionChats.channels.contains("session:chat:provider"))
    }
    /// U109 (#90): "Fork this conversation" and the worktree buttons reach their handler through the chat area's route list.
    func testForkChatIsOnTheChatAreasRouteList() {
        XCTAssertTrue(BackendSessionChats.channels.contains("session:chat:fork"))
    }
}
