import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatMCPStatusTests: XCTestCase {
    func testAppStatusDoesNotImplyProviderConnectionAndSourceChecksRejectWrongProject() throws {
        let row: NativeRPCValue = .object([.init("id", .string("server")), .init("name", .string("Project MCP")), .init("source", .string("/scratch/project/.mcp.json")), .init("scope", .string("project")), .init("enabled", .bool(true)), .init("state", .string("ready")), .init("env", .object([.init("TOKEN", .string("never-export-this"))]))])
        let state = NativeChatMCP.state(app: [row], provider: .null)
        XCTAssertEqual(state["providerSessionConnections"], .null)
        XCTAssertFalse(state.compact.contains("never-export-this"))
        XCTAssertEqual(try NativeChatMCP.selected("server", in: [row]), row)
        XCTAssertThrowsError(try NativeChatMCP.selected("server", in: [row, row]))
        XCTAssertThrowsError(try NativeChatMCP.selected("server", in: [row.setting("scope", .string("local"))]))
        XCTAssertThrowsError(try NativeChatMCP.confirmSource(.object([.init("source", .string("/scratch/other/.mcp.json"))]), expected: row))
    }
}
