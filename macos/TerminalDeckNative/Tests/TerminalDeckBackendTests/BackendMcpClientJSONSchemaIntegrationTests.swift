import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Test func nativeOutputValidatorFactoryAcceptsRealStructuredResult() async throws {
    let transport = BackendMcpClientJSONSchemaFixtureTransport(value: .object([.init("count", .number(3))]))
    let pool = BackendMcpClientJSONSchemaIntegration.pool(configuration: .init(home: "/fixture", environment: [:]), loginPath: { "/usr/bin:/bin" }, transportFactory: { _, _ in transport }, scheduler: McpParityClock())
    let server = BackendMcpClientJSONSchemaFixtureTransport.server
    let inventory = await pool.inventory(server)
    #expect(inventory["status"]["state"].string == "ready")
    let response = await pool.call(server, method: "tools/call", params: .object([.init("name", .string("count")), .init("arguments", .object([]))]), label: "Calling count", tool: true)
    #expect(response["ok"].bool == true)
    #expect(response["result"]["structuredContent"]["count"].number == 3)
    await pool.disconnectAll()
}

@Test func nativeOutputValidatorFactoryPreservesSDKErrorEnvelope() async throws {
    let transport = BackendMcpClientJSONSchemaFixtureTransport(value: .object([.init("count", .string("three"))]))
    let pool = BackendMcpClientJSONSchemaIntegration.pool(configuration: .init(home: "/fixture", environment: [:]), loginPath: { "/usr/bin:/bin" }, transportFactory: { _, _ in transport }, scheduler: McpParityClock())
    let server = BackendMcpClientJSONSchemaFixtureTransport.server
    _ = await pool.inventory(server)
    let response = await pool.call(server, method: "tools/call", params: .object([.init("name", .string("count")), .init("arguments", .object([]))]), label: "Calling count", tool: true)
    #expect(response["ok"].bool == false)
    #expect(response["error"].string == "MCP error -32602: Structured content does not match the tool's output schema: data/count must be integer")
    #expect(response["result"] == .null)
    await pool.disconnectAll()
}

@Test func nativeOutputValidatorFactoryWrapsEvaluationFailures() async throws {
    let schema = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .object([.init("count", .object([.init("$ref", .string("#/$defs/missing"))]))]))])
    do {
        _ = try await BackendMcpClientJSONSchemaOutput().validate(schema: schema, value: .object([.init("count", .number(3))]))
        Issue.record("Unresolved schema reference accepted")
    } catch {
        #expect(error.localizedDescription.hasPrefix("MCP error -32602: Failed to validate structured content: can't resolve reference #/$defs/missing from id "))
    }
}

@Test func nativeOutputSchemaPreparationExposesCompilerFailureForListing() async throws {
    let adapter = BackendMcpClientJSONSchemaOutput()
    let invalid = NativeRPCValue.object([.init("type", .string("object")), .init("properties", .array([]))])
    do { try await adapter.prepare(schema: invalid); Issue.record("Invalid output schema compiled") }
    catch { #expect(!error.localizedDescription.hasPrefix("Failed to validate structured content:")) }
}

private actor BackendMcpClientJSONSchemaFixtureTransport: BackendMcpClientTransport {
    nonisolated var pid: Int? { nil }
    private let value: NativeRPCValue
    private let schema: NativeRPCValue
    private var started = false
    init(value: NativeRPCValue, schema: NativeRPCValue? = nil) {
        self.value = value
        self.schema = schema ?? .object([.init("type", .string("object")), .init("properties", .object([.init("count", .object([.init("type", .string("integer"))]))])), .init("required", .array([.string("count")])), .init("additionalProperties", .bool(false))])
    }
    static var server: NativeRPCValue {
        .object([.init("id", .string("user:schema-fixture")), .init("name", .string("schema-fixture")), .init("scope", .string("user")), .init("transport", .string("stdio")), .init("command", .string("/fixture/mcp")), .init("args", .array([])), .init("env", .object([])), .init("enabled", .bool(true)), .init("unsupported", .null)])
    }
    func start(stderr: @escaping @Sendable (String) -> Void, closed: @escaping @Sendable () -> Void) async throws { started = true }
    func request(_ method: String, params: NativeRPCValue, timeout: Int, label: String) async throws -> NativeRPCValue {
        guard started else { throw BackendMcpClientRPCFailure(code: -32000, message: "Not connected.") }
        switch method {
        case "initialize": return .object([.init("protocolVersion", .string("2025-11-25")), .init("capabilities", .object([.init("tools", .object([]))])), .init("serverInfo", .object([.init("name", .string("fixture")), .init("version", .string("1"))]))])
        case "tools/list":
            return .object([.init("tools", .array([.object([.init("name", .string("count")), .init("inputSchema", .object([.init("type", .string("object"))])), .init("outputSchema", schema)])]))])
        case "tools/call": return .object([.init("content", .array([])), .init("structuredContent", value)])
        default: throw BackendMcpClientRPCFailure(code: -32601, message: "Unknown fixture method.")
        }
    }
    func notify(_ method: String, params: NativeRPCValue) async throws {}
    func close() async { started = false }
}
