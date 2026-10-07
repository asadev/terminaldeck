import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private func mcpPoolFixture() throws -> NativeRPCValue {
    try #require(BackendMcpClientConfiguration.parse(name: "fake", raw: NativeRPCValue.object([.init("command", .string("node"))]), scope: "user", source: "/tmp/test-config", environment: [:]))
}

private final class McpClientFakeTransport: BackendMcpClientTransport, @unchecked Sendable {
    let pid: Int? = 123
    private let lock = NSLock()
    var capabilities: NativeRPCValue = .object([.init("tools", .object([]))])
    var handler: @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue = { _, _ in throw BackendMcpClientRPCFailure(code: -32601, message: "Method not found") }
    var startError: String?
    private var starts = 0, closes = 0, methods: [String] = []
    private var onClose: (@Sendable () -> Void)?
    var counts: (Int, Int) { lock.withLock { (starts, closes) } }
    var seen: [String] { lock.withLock { methods } }
    func start(stderr: @escaping @Sendable (String) -> Void, closed: @escaping @Sendable () -> Void) async throws {
        lock.withLock { starts += 1; onClose = closed }
        if let startError { throw BackendMcpClientValue.error(startError) }
        stderr("server diagnostic")
    }
    func request(_ method: String, params: NativeRPCValue, timeout: Int, label: String) async throws -> NativeRPCValue {
        lock.withLock { methods.append(method) }
        if method == "initialize" { return .object([.init("protocolVersion", .string("2025-06-18")), .init("capabilities", capabilities), .init("serverInfo", .object([.init("name", .string("fake-server")), .init("version", .string("9.9.9"))])), .init("instructions", .string("Be careful."))]) }
        return try await handler(method, params)
    }
    func notify(_ method: String, params: NativeRPCValue) async throws { lock.withLock { methods.append(method) } }
    func close() async { lock.withLock { closes += 1 }; die() }
    func die() { lock.withLock { onClose }?() }
}

private func fakeMcpPool(_ transport: McpClientFakeTransport, timeout: Int = 1000) -> BackendMcpClientPool {
    BackendMcpClientPool(configuration: .init(home: "/tmp/unused", environment: [:]), loginPath: { "/usr/bin" },
        timeouts: .init(overrides: .object([.init("connectMs", .number(Double(timeout))), .init("listMs", .number(Double(timeout))), .init("callMs", .number(Double(timeout)))])), factory: { _, _ in transport })
}

@Test func backendMcpClientTimeoutOverridesIgnoreInvalidDurations() {
    let defaults = BackendMcpClientTimeouts(overrides: .object([.init("connectMs", .missing), .init("listMs", .number(0)), .init("callMs", .number(-1)), .init("closeMs", .number(40))]))
    #expect(defaults.connect == 20_000 && defaults.list == 15_000 && defaults.call == 60_000 && defaults.close == 40)
}

@Test func backendMcpClientPoolSharesConcurrentHandshakeAndClosesOnce() async throws {
    let transport = McpClientFakeTransport(), pool = fakeMcpPool(transport), server = try mcpPoolFixture()
    async let a = pool.connect(server), b = pool.connect(server), c = pool.connect(server)
    let statuses = await [a, b, c]
    #expect(statuses.allSatisfy { $0["state"].string == "ready" })
    #expect(transport.counts.0 == 1)
    #expect(statuses[0]["serverInfo"]["name"].string == "fake-server" && statuses[0]["instructions"].string == "Be careful.")
    let idle = await pool.disconnect("user:fake")
    #expect(idle?["state"].string == "idle" && transport.counts.1 == 1)
    #expect(await pool.status("user:fake") == nil)
    #expect(await pool.disconnect("user:ghost") == nil)
}

@Test func backendMcpClientPoolRefusesUnsupportedAndReapsFailure() async throws {
    let transport = McpClientFakeTransport(), pool = fakeMcpPool(transport), server = try mcpPoolFixture()
    let unsupported = await pool.connect(server.setting("unsupported", .string("cannot inspect HTTP")))
    #expect(unsupported["state"].string == "failed" && transport.counts.0 == 0)
    transport.startError = "spawn node ENOENT"
    let failed = await pool.connect(server)
    #expect(failed["error"].string == "spawn node ENOENT" && transport.counts.1 == 1)
    #expect(await pool.status("user:fake") == nil)
}

@Test func backendMcpClientInventoryKeepsHealthySectionsAndIgnoresOptionalMethod() async throws {
    let transport = McpClientFakeTransport()
    transport.capabilities = .object([.init("tools", .object([])), .init("resources", .object([])), .init("prompts", .object([]))])
    transport.handler = { method, _ in
        if method == "tools/list" { return .object([.init("tools", .array([.object([.init("name", .string("echo")), .init("inputSchema", .object([.init("type", .string("object"))]))])]))]) }
        if method == "resources/list" { throw BackendMcpClientRPCFailure(code: -32603, message: "index corrupt") }
        if method == "prompts/list" { return .object([.init("prompts", .array([.object([.init("name", .string("review")), .init("arguments", .array([.object([.init("name", .string("path")), .init("required", .bool(true))])]))])]))]) }
        throw BackendMcpClientRPCFailure(code: -32601, message: "Method not found")
    }
    let pool = fakeMcpPool(transport), result = await pool.inventory(try mcpPoolFixture())
    #expect(result["tools"].elements?.count == 1 && result["prompts"].elements?.count == 1)
    #expect(result["errors"]["resources"].string?.contains("index corrupt") == true)
    #expect(result["errors"]["resourceTemplates"] == .missing)
    await pool.disconnectAll()
}

@Test func backendMcpClientInventoryRepeatedCursorStopsAfterTwoPages() async throws {
    let transport = McpClientFakeTransport()
    transport.handler = { _, _ in .object([.init("tools", .array([.object([.init("name", .string("echo")), .init("inputSchema", .object([.init("type", .string("object"))]))])])), .init("nextCursor", .string("same"))]) }
    let pool = fakeMcpPool(transport), result = await pool.inventory(try mcpPoolFixture())
    #expect(result["tools"].elements?.count == 2)
    #expect(transport.seen.filter { $0 == "tools/list" }.count == 2)
    #expect(!transport.seen.contains("resources/list"))
    await pool.disconnectAll()
}

@Test func backendMcpClientPoolCallsHaveResultsOrReadableErrors() async throws {
    let transport = McpClientFakeTransport()
    transport.capabilities = .object([.init("tools", .object([])), .init("resources", .object([]))])
    transport.handler = { method, params in
        if method == "tools/call" { return .object([.init("content", .array([.object([.init("type", .string("text")), .init("text", params["arguments"]["message"])])]))]) }
        throw BackendMcpClientRPCFailure(code: -32602, message: "missing uri")
    }
    let pool = fakeMcpPool(transport), server = try mcpPoolFixture()
    let success = await pool.call(server, method: "tools/call", params: .object([.init("arguments", .object([.init("message", .string("hello"))]))]), label: "Calling echo", tool: true)
    #expect(success["ok"].bool == true && success["result"]["content"].elements?.first?["text"].string == "hello")
    let failure = await pool.call(server, method: "resources/read", params: .object([]), label: "Reading missing")
    #expect(failure["ok"].bool == false && failure["error"].string?.contains("missing uri") == true)
    await pool.disconnectAll()
}

@Test func backendMcpClientWallClockDeadlineDoesNotWaitForTheLoser() async throws {
    let transport = McpClientFakeTransport()
    let clock = McpParityClock(), gate = McpParityGate<Void>(), entered = McpParityGate<Void>(), consumed = McpParityGate<Void>()
    transport.handler = { _, _ in await entered.succeed(()); try await gate.wait(); await consumed.succeed(()); return .object([]) }
    let pool = BackendMcpClientPool(configuration: .init(home: "/tmp/unused", environment: [:]), loginPath: { "/usr/bin" },
        timeouts: .init(overrides: .object([.init("callMs", .number(20))])), factory: { _, _ in transport }, scheduler: clock)
    let server = try mcpPoolFixture(), task = Task { await pool.call(server, method: "tools/call", params: .object([]), label: "Calling never", tool: true) }
    try await entered.wait(); await clock.whenScheduled(20); clock.advance(20)
    let result = await task.value
    #expect(result["ok"].bool == false && result["error"].string == "Calling never timed out after 20ms")
    await gate.succeed(()); try await consumed.wait()
    await pool.disconnectAll()
}

@Test func backendMcpClientPayloadCapUsesUTF16Characters() {
    let result = NativeRPCValue.object([.init("text", .string(String(repeating: "😀", count: 300_000)))])
    let (value, truncated) = BackendMcpClientPool.capPayload(result)
    #expect(truncated && value["preview"].string?.utf16.count == 512 * 1024)
    #expect(value["note"].string?.contains("600011 characters") == true)
}

@Test func backendMcpClientChannelsRegisterOnceAndRefuseUnconfiguredCommands() async throws {
    let config = BackendMcpClientConfiguration(home: "/tmp/BackendMcpClient-no-config-" + UUID().uuidString, environment: [:])
    let writer = BackendMcpClientWriter(configuration: config, loginPath: { "/usr/bin" }, run: { _, _, _, _, _ in throw BackendMcpClientValue.error("Unexpected process") })
    let service = BackendMcpClientService(writer: writer), registry = NativeChannelRegistry()
    _ = try await BackendMcpClientChannels.register(registry: registry, ownerID: "mcp-test", service: service)
    _ = try await BackendMcpClientChannels.register(registry: registry, ownerID: "mcp-test", service: service)
    #expect(await registry.channels() == BackendMcpClientChannels.names.sorted())
    let context = NativeRPCContext(caller: .nativeApp, ownerID: "mcp-test")
    do { _ = try await registry.invoke("mcp:connect", context: context, arguments: [.string("user:not-configured")]); Issue.record("Unconfigured server was allowed") }
    catch { #expect(error.localizedDescription.contains("no configured server")) }
    do { _ = try await registry.invoke("mcp:call", context: context, arguments: [.string("user:x"), .string("")]); Issue.record("Empty tool was allowed") }
    catch { #expect(error.localizedDescription == "mcp: a tool name is required") }
    let denied = NativeRPCContext(caller: .page, ownerID: "untrusted", capabilities: ["mcp.read"])
    do { _ = try await registry.invoke("mcp:list", context: denied, arguments: []); Issue.record("Page got owner config") }
    catch { #expect(error.localizedDescription.contains("app-owned caller")) }
}

@Test func backendMcpClientToolSchemasRequireRealValidationAndTaskToolsAreRefused() async throws {
    let transport = McpClientFakeTransport()
    transport.handler = { method, _ in
        if method == "tools/list" {
            let schema = NativeRPCValue.object([.init("type", .string("object"))])
            return .object([.init("tools", .array([
                .object([.init("name", .string("structured")), .init("inputSchema", schema), .init("outputSchema", schema)]),
                .object([.init("name", .string("task")), .init("inputSchema", schema), .init("execution", .object([.init("taskSupport", .string("required"))]))])
            ]))])
        }
        return .object([.init("structuredContent", .object([.init("value", .number(1))]))])
    }
    let pool = fakeMcpPool(transport), server = try mcpPoolFixture()
    _ = await pool.inventory(server)
    let missingValidator = await pool.call(server, method: "tools/call", params: .object([.init("name", .string("structured"))]), label: "Calling structured", tool: true)
    #expect(missingValidator["ok"].bool == false && missingValidator["error"].string == "MCP tool output schema validation is unavailable.")
    let count = transport.seen.count
    let requiredTask = await pool.call(server, method: "tools/call", params: .object([.init("name", .string("task"))]), label: "Calling task", tool: true)
    #expect(requiredTask["ok"].bool == false && requiredTask["error"].string?.contains("requires task-based execution") == true)
    #expect(transport.seen.count == count)
    await pool.disconnectAll()
}

@Test func backendMcpClientPagingHasHardFiftyPageCap() async throws {
    let transport = McpClientFakeTransport()
    transport.handler = { _, params in
        let index = Int(params["cursor"].string ?? "0") ?? 0
        return .object([.init("tools", .array([.object([.init("name", .string("tool\(index)")), .init("inputSchema", .object([.init("type", .string("object"))]))])])), .init("nextCursor", .string(String(index + 1)))])
    }
    let pool = fakeMcpPool(transport), inventory = await pool.inventory(try mcpPoolFixture())
    #expect(inventory["tools"].elements?.count == 50 && transport.seen.filter { $0 == "tools/list" }.count == 50)
    await pool.disconnectAll()
}

@Test func backendMcpClientPoolRefreshesConfigWithoutLosingRuntimeFields() async throws {
    let transport = McpClientFakeTransport(), pool = fakeMcpPool(transport), server = try mcpPoolFixture()
    _ = await pool.connect(server)
    let refreshed = await pool.statuses([server.setting("command", .string("updated-command"))])
    #expect(refreshed[0]["command"].string == "updated-command" && refreshed[0]["state"].string == "ready")
    #expect(refreshed[0]["serverInfo"]["version"].string == "9.9.9")
    await pool.disconnectAll()
}
