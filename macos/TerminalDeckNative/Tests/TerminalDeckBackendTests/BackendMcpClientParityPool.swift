import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Test func mcpParityDeadlineWorkWinsAndCancelsFakeTimer() async throws {
    let clock = McpParityClock()
    let answer = try await BackendMcpClientDeadline.run(1_000, label: "work", scheduler: clock) { "done" }
    #expect(answer == "done" && clock.pending == 0)
}
@Test func mcpParityDeadlineClockWinsWithExactLabelAndConsumesLateRejection() async throws {
    let clock = McpParityClock(), gate = McpParityGate<String>(), consumed = McpParityGate<Void>()
    let task = Task {
        try await BackendMcpClientDeadline.run(5, label: "Connecting to fake", scheduler: clock) {
            do { return try await gate.wait() }
            catch { await consumed.succeed(()); throw error }
        }
    }
    await clock.whenScheduled(5); clock.advance(5)
    do { _ = try await task.value; Issue.record("A deadline did not reject") }
    catch { #expect(error.localizedDescription == "Connecting to fake timed out after 5ms") }
    await gate.fail(NativeRPCError(code: "fixture", message: "too late")); try await consumed.wait()
    #expect(clock.pending == 0)
}
@Test func mcpParityPoolUnsupportedSpawnAndEnvironmentFailuresNeverRetainAConnection() async throws {
    let transport = McpParityTransport(startError: "spawn npx ENOENT"), factory = McpParityFactory([transport]), clock = McpParityClock()
    let pool = mcpParityPool(factory, clock: clock), server = try mcpParityServer()
    let unsupported = await pool.connect(server.setting("transport", .string("http")).setting("command", .null).setting("url", .string("https://x")).setting("unsupported", .string("stdio only, sorry")))
    #expect(unsupported["state"].string == "failed" && unsupported["error"].string == "stdio only, sorry" && factory.count == 0)
    let failed = await pool.connect(server)
    #expect(failed["state"].string == "failed" && failed["error"].string == "spawn npx ENOENT")
    let failedHeld = await pool.status("user:fake")
    #expect(failedHeld == nil && transport.counts.1 == 1)
    let noEnvFactory = McpParityFactory([McpParityTransport()]), noEnv = mcpParityPool(noEnvFactory, clock: .init(), env: { throw NativeRPCError(code: "fixture", message: "no login shell") })
    let badEnv = await noEnv.connect(server)
    #expect(badEnv["state"].string == "failed" && badEnv["error"].string == "no login shell" && noEnvFactory.count == 0)
}
@Test func mcpParityPoolStartAndInitializeTimeoutsUseManualTimeAndReapTransport() async throws {
    for stage in ["start", "initialize"] {
        let clock = McpParityClock(), gate = McpParityGate<Void>()
        let startGate: McpParityGate<Void>? = stage == "start" ? gate : nil
        var initializeHandler: McpParityTransport.Handler?
        if stage == "initialize" {
            initializeHandler = { @Sendable (method: String, _: NativeRPCValue) async throws -> NativeRPCValue in
                if method == "initialize" { try await gate.wait(); return McpParityTransport.initialize() }
                throw BackendMcpClientRPCFailure(code: -32601, message: "Method not found")
            }
        }
        let transport = McpParityTransport(startGate: startGate, handler: initializeHandler)
        let pool = mcpParityPool(McpParityFactory([transport]), clock: clock, overrides: .object([.init("connectMs", .number(20))]))
        let task = Task { await pool.connect(try! mcpParityServer()) }
        try await transport.started.wait()
        if stage == "initialize" { try await transport.initializeEntered.wait() }
        await clock.whenScheduled(20); clock.advance(20)
        let result = await task.value
        #expect(result["state"].string == "failed" && result["error"].string == "Connecting to fake timed out after 20ms")
        let held = await pool.status("user:fake")
        #expect(held == nil && transport.counts.1 == 1)
        await gate.succeed(())
    }
}
@Test func mcpParityPoolHandshakeMetadataReadyReuseAndIntentionalDisconnect() async throws {
    let caps = NativeRPCValue.object([.init("tools", .object([])), .init("resources", .object([]))])
    let transport = McpParityTransport(capabilities: caps), factory = McpParityFactory([transport]), events = McpParityEvents()
    let pool = mcpParityPool(factory, clock: .init(), events: events), server = try mcpParityServer()
    let first = await pool.connect(server), second = await pool.connect(server)
    #expect(first["state"].string == "ready" && second["state"].string == "ready" && factory.count == 1)
    #expect(first["serverInfo"] == .object([.init("name", .string("fake-server")), .init("version", .string("9.9.9"))]))
    #expect((first["capabilities"].elements ?? []).compactMap(\.string).sorted() == ["resources", "tools"] && first["instructions"].string == "Be careful.")
    #expect((await events.snapshot()).compactMap { $0["state"].string } == ["connecting", "ready"])
    let idle = await pool.disconnect("user:fake")
    #expect(idle?["state"].string == "idle" && transport.counts.1 == 1)
    #expect((await events.snapshot()).compactMap { $0["state"].string } == ["connecting", "ready", "idle"])
    #expect(await pool.disconnect("user:ghost") == nil)
}
@Test func mcpParityPoolUnexpectedExitDropsHandleAndNextCallReconnects() async throws {
    let first = McpParityTransport(), second = McpParityTransport(), factory = McpParityFactory([first, second]), events = McpParityEvents()
    let pool = mcpParityPool(factory, clock: .init(), events: events), server = try mcpParityServer()
    _ = await pool.connect(server); first.die(); await events.whenCount(3)
    #expect((await events.snapshot()).compactMap { $0["state"].string } == ["connecting", "ready", "closed"])
    #expect(await pool.status("user:fake") == nil)
    let again = await pool.connect(server)
    #expect(again["state"].string == "ready" && factory.count == 2)
    await pool.disconnectAll()
}

private func parityInventoryResponse(_ method: String) throws -> NativeRPCValue {
    switch method {
    case "initialize": return McpParityTransport.initialize(.object([.init("tools", .object([])), .init("resources", .object([])), .init("prompts", .object([]))]))
    case "tools/list": return .object([.init("tools", .array([mcpParityTool()]))])
    case "resources/list": return try mcpParityJSON(#"{"resources":[{"uri":"file:///a","name":"a","mimeType":"text/plain"}]}"#)
    case "resources/templates/list": return try mcpParityJSON(#"{"resourceTemplates":[{"uriTemplate":"file:///{p}","name":"t"}]}"#)
    case "prompts/list": return try mcpParityJSON(#"{"prompts":[{"name":"review","arguments":[{"name":"path","required":true}]}]}"#)
    default: throw BackendMcpClientRPCFailure(code: -32601, message: "Method not found: " + method)
    }
}
@Test func mcpParityInventoryCollectsEverySectionWithExactOptionalFieldShapes() async throws {
    let transport = McpParityTransport(handler: { method, _ in try parityInventoryResponse(method) })
    let pool = mcpParityPool(McpParityFactory([transport]), clock: .init())
    let result = await pool.inventory(try mcpParityServer())
    #expect(result["tools"].elements!.map { $0["name"].string! } == ["echo"])
    #expect(result["tools"].elements![0]["inputSchema"]["type"].string == "object")
    #expect(result["resources"].elements![0]["uri"].string == "file:///a")
    #expect(result["resourceTemplates"].elements![0]["uriTemplate"].string == "file:///{p}")
    #expect(result["prompts"].elements![0]["arguments"].elements == [.object([.init("name", .string("path")), .init("description", .null), .init("required", .bool(true))])])
    #expect(result["errors"] == .object([]))
    await pool.disconnectAll()
}
@Test func mcpParityInventorySkipsUnadvertisedAndUnsupportedOptionalSections() async throws {
    let onlyTools = McpParityTransport(handler: { method, _ in method == "initialize" ? McpParityTransport.initialize() : try parityInventoryResponse(method) })
    let toolsPool = mcpParityPool(McpParityFactory([onlyTools]), clock: .init()), tools = await toolsPool.inventory(try mcpParityServer())
    #expect(tools["tools"].elements?.count == 1 && tools["resources"].elements == [] && tools["errors"] == .object([]))
    #expect(!onlyTools.calls.contains { $0.0 == "resources/list" })
    let optional = McpParityTransport(handler: { method, _ in
        if method == "resources/templates/list" { throw BackendMcpClientRPCFailure(code: -32601, message: "Method not found") }
        return try parityInventoryResponse(method)
    })
    let optionalPool = mcpParityPool(McpParityFactory([optional]), clock: .init()), result = await optionalPool.inventory(try mcpParityServer())
    #expect(result["resources"].elements?.count == 1 && result["resourceTemplates"].elements == [] && result["errors"] == .object([]))
    await toolsPool.disconnectAll(); await optionalPool.disconnectAll()
}
@Test func mcpParityInventoryErrorsAndManualTimeoutDoNotLoseHealthySections() async throws {
    let broken = McpParityTransport(handler: { method, _ in
        if method == "resources/list" { throw BackendMcpClientRPCFailure(code: -32603, message: "index corrupt") }
        return try parityInventoryResponse(method)
    })
    let pool = mcpParityPool(McpParityFactory([broken]), clock: .init()), partial = await pool.inventory(try mcpParityServer())
    #expect(partial["tools"].elements?.count == 1 && partial["errors"]["resources"].string == "MCP error -32603: index corrupt")
    let clock = McpParityClock(), gate = McpParityGate<Void>(), entered = McpParityGate<Void>()
    let hanging = McpParityTransport(handler: { method, _ in
        if method == "prompts/list" { await entered.succeed(()); try await gate.wait() }
        return try parityInventoryResponse(method)
    })
    let timed = mcpParityPool(McpParityFactory([hanging]), clock: clock, overrides: .object([.init("listMs", .number(25))]))
    let task = Task { await timed.inventory(try! mcpParityServer()) }
    try await entered.wait(); await clock.whenScheduled(25); clock.advance(25)
    let result = await task.value
    #expect(result["tools"].elements?.count == 1 && result["errors"]["prompts"].string == "Listing prompts timed out after 25ms")
    await gate.succeed(()); await pool.disconnectAll(); await timed.disconnectAll()
}
@Test func mcpParityInventoryFollowsCursorsAndStopsAtTheFirstRepeat() async throws {
    for repeated in [false, true] {
        let transport = McpParityTransport(handler: { method, params in
            if method == "initialize" { return McpParityTransport.initialize() }
            if repeated { return .object([.init("tools", .array([mcpParityTool()])), .init("nextCursor", .string("always-the-same"))]) }
            return params["cursor"].string == nil ? .object([.init("tools", .array([mcpParityTool()])), .init("nextCursor", .string("p2"))]) : .object([.init("tools", .array([mcpParityTool("second")]))])
        })
        let pool = mcpParityPool(McpParityFactory([transport]), clock: .init()), result = await pool.inventory(try mcpParityServer())
        #expect(result["tools"].elements!.map { $0["name"].string! } == (repeated ? ["echo", "echo"] : ["echo", "second"]))
        let pages = transport.calls.filter { $0.0 == "tools/list" }
        #expect(pages.count == 2 && pages[0].1 == .object([]))
        #expect(pages[1].1["cursor"].string == (repeated ? "always-the-same" : "p2"))
        await pool.disconnectAll()
    }
}
@Test func mcpParityInventoryCannotStartReturnsFailedEmptyInventory() async throws {
    let pool = mcpParityPool(McpParityFactory([McpParityTransport(startError: "spawn ENOENT")]), clock: .init())
    let result = await pool.inventory(try mcpParityServer())
    #expect(result["status"]["state"].string == "failed" && result["tools"].elements == [])
}
@Test func mcpParityCallsReturnWholeResultsReadableServerErrorsAndConnectionFailures() async throws {
    let transport = McpParityTransport(handler: { method, _ in
        if method == "initialize" { return McpParityTransport.initialize() }
        if method == "tools/call" { return try mcpParityJSON(#"{"content":[{"type":"text","text":"hello"}]}"#) }
        throw BackendMcpClientRPCFailure(code: -32602, message: "missing message")
    })
    let pool = mcpParityPool(McpParityFactory([transport]), clock: .init()), server = try mcpParityServer()
    let ok = await pool.call(server, method: "tools/call", params: .object([.init("name", .string("echo")), .init("arguments", .object([.init("message", .string("hi"))]))]), label: "Calling echo", tool: true)
    #expect(ok["ok"].bool == true && ok["error"] == .null && (ok["durationMs"].number ?? -1) >= 0)
    #expect(ok["result"] == (try mcpParityJSON(#"{"content":[{"type":"text","text":"hello"}]}"#)))
    let badTransport = McpParityTransport(handler: { method, _ in if method == "initialize" { return McpParityTransport.initialize() }; throw BackendMcpClientRPCFailure(code: -32602, message: "missing message") })
    let bad = mcpParityPool(McpParityFactory([badTransport]), clock: .init())
    let result = await bad.call(server, method: "tools/call", params: .object([]), label: "Calling echo", tool: true)
    #expect(result["ok"].bool == false && result["error"].string == "MCP error -32602: missing message")
    let absent = mcpParityPool(McpParityFactory([McpParityTransport(startError: "spawn ENOENT")]), clock: .init())
    #expect(await absent.call(server, method: "tools/call", params: .object([]), label: "Calling echo", tool: true)["error"].string == "spawn ENOENT")
    await pool.disconnectAll(); await bad.disconnectAll()
}
@Test func mcpParityToolCallTimeoutIsDrivenByTheSameRaceWithAFakeClock() async throws {
    let clock = McpParityClock(), gate = McpParityGate<Void>(), entered = McpParityGate<Void>()
    let transport = McpParityTransport(handler: { method, _ in
        if method == "initialize" { return McpParityTransport.initialize() }
        await entered.succeed(()); try await gate.wait(); return .object([.init("content", .array([]))])
    })
    let pool = mcpParityPool(McpParityFactory([transport]), clock: clock, overrides: .object([.init("callMs", .number(25))]))
    let task = Task { await pool.call(try! mcpParityServer(), method: "tools/call", params: .object([.init("name", .string("echo")), .init("arguments", .object([]))]), label: "Calling echo", tool: true) }
    try await entered.wait(); await clock.whenScheduled(25); clock.advance(25)
    let result = await task.value
    #expect(result["ok"].bool == false && result["error"].string == "Calling echo timed out after 25ms")
    #expect(transport.calls.last?.2 == 25 && transport.calls.last?.3 == "Calling echo")
    await gate.succeed(()); await pool.disconnectAll()
}
@Test func mcpParityTimeoutOverridesMatchEveryDefaultAndInvalidDurationCase() {
    let defaults = BackendMcpClientTimeouts(overrides: .object([.init("connectMs", .missing)]))
    #expect(defaults.connect == 20_000)
    for value in [0.0, -5, Double.nan, Double.infinity] { #expect(BackendMcpClientTimeouts(overrides: .object([.init("listMs", .number(value))])).list == 15_000) }
    #expect(BackendMcpClientTimeouts(overrides: .object([.init("callMs", .number(.nan))])).call == 60_000)
    let changed = BackendMcpClientTimeouts(overrides: .object([.init("closeMs", .number(40))]))
    #expect(changed.connect == 20_000 && changed.list == 15_000 && changed.call == 60_000 && changed.close == 40)
}
@Test func mcpParityConcurrentConnectsAndListingsShareOneProcessAndRetryCleanly() async throws {
    let transport = McpParityTransport(handler: { method, _ in method == "initialize" ? McpParityTransport.initialize() : .object([.init("tools", .array([mcpParityTool()]))]) })
    let factory = McpParityFactory([transport]), pool = mcpParityPool(factory, clock: .init()), server = try mcpParityServer()
    async let a = pool.connect(server), b = pool.connect(server), c = pool.connect(server)
    let statuses = await [a, b, c]
    #expect(statuses.allSatisfy { $0["state"].string == "ready" } && factory.count == 1 && transport.counts.1 == 0)
    async let first = pool.inventory(server), second = pool.inventory(server)
    let inventories = await [first, second]
    #expect(inventories.allSatisfy { $0["tools"].elements?.count == 1 && $0["errors"] == .object([]) } && factory.count == 1)
    #expect(await pool.status("user:fake")?["state"].string == "ready")
    let listingTransport = McpParityTransport(handler: { method, _ in method == "initialize" ? McpParityTransport.initialize() : .object([.init("tools", .array([mcpParityTool()]))]) })
    let listingFactory = McpParityFactory([listingTransport]), listingPool = mcpParityPool(listingFactory, clock: .init())
    async let coldFirst = listingPool.inventory(server), coldSecond = listingPool.inventory(server)
    let cold = await [coldFirst, coldSecond]
    #expect(listingFactory.count == 1 && cold.allSatisfy { $0["tools"].elements?.count == 1 && $0["errors"] == .object([]) })
    let listedStatus = await listingPool.status("user:fake")
    #expect(listingTransport.counts.1 == 0 && listedStatus?["state"].string == "ready")
    let retryFactory = McpParityFactory([McpParityTransport(startError: "spawn ENOENT"), McpParityTransport()]), retry = mcpParityPool(retryFactory, clock: .init())
    #expect(await retry.connect(server)["state"].string == "failed")
    #expect(await retry.connect(server)["state"].string == "ready")
    #expect(await retry.status("user:fake")?["state"].string == "ready")
    await pool.disconnectAll(); await retry.disconnectAll(); await listingPool.disconnectAll()
}
@Test func mcpParityQuitWaitsForPendingEnvironmentThenClosesEveryStartedServer() async throws {
    let env = McpParityGate<String>(), entered = McpParityGate<Void>(), transport = McpParityTransport()
    let pool = mcpParityPool(McpParityFactory([transport]), clock: .init(), env: { await entered.succeed(()); return try await env.wait() })
    let opening = Task { await pool.connect(try! mcpParityServer()) }
    try await entered.wait()
    let quitting = Task { await pool.disconnectAll() }
    await env.succeed("/usr/bin")
    _ = await opening.value; await quitting.value
    let held = await pool.status("user:fake")
    #expect(transport.counts.1 == 1 && held == nil)
    let empty = mcpParityPool(McpParityFactory([]), clock: .init()); await empty.disconnectAll()
    #expect(await empty.status("user:fake") == nil)
}
@Test func mcpParityInventoryServerDeathBeforeListingReturnsInventoryFailure() async throws {
    let transport = McpParityTransport(), events = McpParityEvents(), clock = McpParityClock()
    let pool = BackendMcpClientPool(configuration: .init(home: "/tmp/unused", environment: [:]), loginPath: { "/usr/bin" }, factory: { _, _ in transport }, scheduler: clock, onStatus: { status in
        await events.record(status)
        if status["state"].string == "ready" { transport.die(); await events.whenCount(3) }
    })
    let result = await pool.inventory(try mcpParityServer())
    #expect(result["tools"].elements == [] && result["errors"]["server"].string == "The server exited before it could be listed.")
    #expect(result["status"]["state"].string != "ready")
}
