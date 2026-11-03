import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class McpToolRunnerTests: XCTestCase {
    func testRunnerUsesTheWindowServerAndProjectAndReturnsFailures() async throws {
        let rawServer = try XCTUnwrap(OrderedJSON.parse(
            #"{"id":"user:fixture","name":"fixture","scope":"user","source":"user","transport":"stdio","state":"ready","enabled":true}"#))
        let server = try XCTUnwrap(McpServerStatus.from(rawServer))
        let model = NativeCatalogMcpSettingsModel(server: server, projectPath: "/scratch/project")
        let inventory = McpInventory.from(try XCTUnwrap(OrderedJSON.parse(
            #"{"tools":[{"name":"echo","inputSchema":{"type":"object"}}]}"#)))
        let tool = try XCTUnwrap(inventory.tools.first)
        var calls = 0
        model.invoke = { channel, args in
            calls += 1
            XCTAssertTrue(channel == "mcp:call")
            XCTAssertTrue(args[0] as? String == "user:fixture")
            XCTAssertTrue(args[1] as? String == "echo")
            XCTAssertTrue(OrderedJSON(foundation: args[2]) == .object([.init("text", .string("hello"))]))
            XCTAssertTrue(args[3] as? String == "/scratch/project")
            return .object([.init("ok", .bool(false)), .init("error", .string("Fixture refusal"))])
        }
        let result = await model.callTool(tool, .object([.init("text", .string("hello"))]))
        XCTAssertTrue(!result.ok)
        XCTAssertTrue(calls == 1)
        model.toolOverrides[tool.name] = false
        let disabled = await model.callTool(tool, .object([]))
        XCTAssertFalse(disabled.ok)
        XCTAssertTrue(calls == 1)
    }
}
