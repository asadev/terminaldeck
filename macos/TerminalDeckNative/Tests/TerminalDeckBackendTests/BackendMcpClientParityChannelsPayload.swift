import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Test func mcpParityChannelRegistrationAndAllBridgeRefusalsMatchSource() async throws {
    let fixture = try McpParityFixture(); defer { fixture.dispose() }
    let runs = McpParityRuns(), service = BackendMcpClientService(writer: fixture.writer(runs)), registry = NativeChannelRegistry()
    _ = try await BackendMcpClientChannels.register(registry: registry, ownerID: "mcp-parity", service: service)
    let expected = ["mcp:add", "mcp:call", "mcp:connect", "mcp:disconnect", "mcp:edit", "mcp:export", "mcp:get-prompt", "mcp:import", "mcp:inventory", "mcp:list", "mcp:read-resource", "mcp:remove", "mcp:store", "mcp:store-install"]
    #expect(await registry.channels() == expected)
    _ = try await BackendMcpClientChannels.register(registry: registry, ownerID: "mcp-parity", service: service)
    #expect(await registry.channels() == expected)
    let inputs: [(String, [NativeRPCValue], String)] = [
        ("mcp:list", [.string("../../etc")], "mcp: a project path must be absolute"),
        ("mcp:connect", [.string("user:definitely-not-configured")], "mcp: no configured server with id user:definitely-not-configured"),
        ("mcp:connect", [.object([.init("command", .string("/bin/sh"))])], "mcp: a server id is required"),
        ("mcp:call", [.string("user:x"), .string("")], "mcp: a tool name is required"),
        ("mcp:read-resource", [.string("user:x"), .number(42)], "mcp: a resource uri is required"),
        ("mcp:get-prompt", [.string("user:x"), .string("")], "mcp: a prompt name is required")
    ]
    for (channel, args, message) in inputs {
        do { _ = try await registry.invoke(channel, context: .init(caller: .nativeApp, ownerID: "mcp-parity"), arguments: args); Issue.record("Malformed invoke accepted: \(channel)") }
        catch { #expect(error.localizedDescription == message) }
    }
    #expect((await runs.snapshot()).isEmpty)
}
@Test func mcpParityPayloadKeepsSmallReplacesOversizedAndReportsUnserializableValues() throws {
    let small = try mcpParityJSON(#"{"content":[{"type":"text","text":"small"}]}"#), unchanged = BackendMcpClientPool.capPayload(small)
    #expect(unchanged.0 == small && unchanged.1 == false)
    let huge = NativeRPCValue.object([.init("content", .array([.object([.init("type", .string("text")), .init("text", .string(String(repeating: "x", count: 600_000)))])]))])
    let capped = BackendMcpClientPool.capPayload(huge)
    #expect(capped.1 == true && capped.0.compact.utf16.count < 600_000)
    #expect(capped.0["preview"].string?.utf16.count == 512 * 1024)
    // NativeRPCValue cannot contain an object identity cycle. Its real codec
    // refusal at the supported nesting boundary exercises the same source
    // circular-result intent: an unserializable payload never escapes the bridge.
    var unencodable = NativeRPCValue.null
    for _ in 0..<65 { unencodable = .array([unencodable]) }
    let refused = BackendMcpClientPool.capPayload(unencodable)
    #expect(refused.1 && refused.0["note"].string == "The result could not be serialised.")
}
