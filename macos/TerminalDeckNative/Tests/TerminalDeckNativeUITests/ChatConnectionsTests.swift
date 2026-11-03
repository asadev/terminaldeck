import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

final class ChatConnectionsTests: XCTestCase {
    func testStatusProjectionDoesNotConflateEnablementOrExposeCredentials() throws {
        let plugins = NativeRPCValue.object([.init("plugins", .array([.object([.init("name", .string("Example")), .init("state", .string("allowed")), .init("secret", .string("private-fixture"))])]))])
        let apps = NativeRPCValue.object([.init("internet", .object([.init("connected", .bool(false))])), .init("keys", .string("private-fixture"))])
        let state = NativeChatConnections.state(plugins: plugins, apps: apps, tools: [.init(id: "one", name: "Tool", enabled: true)])
        XCTAssertEqual(state["inboundAIApps"]["connected"].bool, false)
        XCTAssertEqual(state["chatToolCatalogue"].elements?.first?["enabled"].bool, true)
        XCTAssertTrue(state["providerNativePluginsAndApps"].isNullish)
        XCTAssertFalse(String(decoding: try state.encodedJSON(), as: UTF8.self).contains("private-fixture"))
        XCTAssertEqual(NativeChatConnections.destinations, ["mcp", "plugins", "ai-apps"])
    }
}
