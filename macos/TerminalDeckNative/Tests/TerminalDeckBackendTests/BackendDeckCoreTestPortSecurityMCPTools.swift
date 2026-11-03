import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreTestPortSecurityMCPProvider: BackendDeckCoreEventsMCPProvider, @unchecked Sendable {
    var calls: [(String, NativeRPCValue)] = []
    var writeResult: NativeRPCValue = .object([.init("ok", .bool(true)), .init("message", .string("Added github."))])
    static func status(_ patch: NativeRPCValue = .object([])) -> NativeRPCValue {
        BackendDeckCoreTestPortSecurityValue.object([("id", .string("user:github")), ("name", .string("github")), ("scope", .string("user")), ("transport", .string("stdio")), ("command", .string("npx")), ("args", .array([.string("-y"), .string("@modelcontextprotocol/server-github")])), ("env", .object([.init("GITHUB_PERSONAL_ACCESS_TOKEN", .string("ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))])), ("cwd", .null), ("url", .null), ("source", .string("/Users/someone/.claude.json")), ("enabled", .bool(true)), ("disabledReason", .null), ("unsupported", .null), ("state", .string("idle")), ("error", .null), ("serverInfo", .null), ("capabilities", .array([])), ("instructions", .null), ("pid", .null), ("connectedAt", .null), ("stderr", .string(""))]).merging(patch)
    }
    func knownFolder(_ path: String, context: BackendDeckCoreSecurityCallContext) throws -> String {
        guard path == "/work/api" else { throw BackendDeckCoreSecurityRefusal(.notPermitted, "\(path) is not a folder this app has open. Use projects.list to see the folders you can ask about.") }; return path
    }
    func resolveAdd(_ request: NativeRPCValue) throws -> NativeRPCValue { try BackendMcpClientCommands.validateAdd(request) }
    func resolveEdit(_ request: NativeRPCValue) throws -> NativeRPCValue { _ = try BackendMcpClientCommands.validateAdd(request["next"]); return request }
    func resolveRemove(_ request: NativeRPCValue) throws -> NativeRPCValue { try BackendMcpClientCommands.validateRemove(request) }
    func resolveInstall(_ request: NativeRPCValue) throws -> NativeRPCValue { try BackendMcpClientStoreRules.resolveInstall(request) }
    func list(projectPath: String?) async -> [NativeRPCValue] { calls.append(("list", projectPath.map(NativeRPCValue.string) ?? .null)); return [Self.status()] }
    func add(_ request: NativeRPCValue) async -> NativeRPCValue { calls.append(("add", request)); return writeResult }
    func edit(_ request: NativeRPCValue) async -> NativeRPCValue { calls.append(("edit", request)); return writeResult }
    func remove(_ request: NativeRPCValue) async -> NativeRPCValue { calls.append(("remove", request)); return writeResult }
    func inventory(id: String, projectPath: String?) async -> NativeRPCValue {
        .object([.init("serverId", .string(id)), .init("tools", .array([.object([.init("name", .string("search")), .init("title", .null), .init("description", .null), .init("inputSchema", .object([])), .init("outputSchema", .null)])])), .init("resources", .array([])), .init("resourceTemplates", .array([])), .init("prompts", .array([])), .init("errors", .object([])), .init("status", Self.status(.object([.init("state", .string("ready"))])))])
    }
    func disconnect(id: String) async -> NativeRPCValue? { nil }
    func call(id: String, tool: String, arguments: NativeRPCValue, projectPath: String?) async -> NativeRPCValue { .object([.init("ok", .bool(true)), .init("result", .object([.init("content", .array([]))])), .init("error", .null), .init("durationMs", .number(4)), .init("truncated", .bool(false))]) }
    func store(projectPath: String?) async -> NativeRPCValue { .object([.init("rows", .array([])), .init("runtimes", .array([])), .init("writer", .object([.init("found", .bool(true)), .init("path", .string("/bin/claude"))])), .init("environmentSource", .string("login-shell")), .init("projectPath", .string(""))]) }
    func install(_ request: NativeRPCValue) async -> NativeRPCValue { calls.append(("install", request)); return writeResult }
    func toolFile(name: String, scope: String, projectPath: String?) async -> NativeRPCValue? { name == "github" ? .object([.init("name", .string(name)), .init("fileName", .string("github.mcp.json")), .init("text", .string("{\"name\":\"github\"}"))]) : nil }
}

final class BackendDeckCoreTestPortSecurityMCPTools: BackendDeckCoreTestPortSecurityCase {
    private func context() -> BackendDeckCoreSecurityCallContext {
        .init(native: .init(sessionID: "copilot", machineID: "", projectRoot: nil, attended: true, allowedTools: [], allowedTiers: [.read, .act, .alter], cancellation: .init()),
            caller: .local, callID: "row-1", attended: true, granted: nil, sessionLimits: .missing, now: { 1000 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    private func policy(_ id: String, _ provider: BackendDeckCoreTestPortSecurityMCPProvider = .init()) throws -> BackendDeckCoreSecurityToolPolicy { try XCTUnwrap(BackendDeckCoreEventsTools.mcpPolicies(provider: provider).first { $0.tool.id == id }) }
    func testMcpServerToolsL60() {
        let view = BackendDeckCoreEventsTools.serverView(BackendDeckCoreTestPortSecurityMCPProvider.status()), text = view.compact
        XCTAssertEqual(view["envKeys"], .array([.string("GITHUB_PERSONAL_ACCESS_TOKEN")])); XCTAssertFalse(text.contains("ghp_")); XCTAssertFalse(view.has("env"))
    }
    func testMcpServerToolsL68() {
        let view = BackendDeckCoreEventsTools.serverView(BackendDeckCoreTestPortSecurityMCPProvider.status(o([("args", .array([.string("--api-key"), .string("sk-ant-api03-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")])), ("url", .string("https://user:hunter2hunter2@mcp.example.com/sse"))]))), text = view.compact
        XCTAssertFalse(text.contains("sk-ant-api03")); XCTAssertFalse(text.contains("hunter2hunter2")); XCTAssertTrue(text.contains("/Users/someone/.claude.json"))
    }
    func testMcpServerToolsL81() async throws {
        let provider = BackendDeckCoreTestPortSecurityMCPProvider(), p = try policy("mcp.list", provider), context = context()
        _ = try await p.run(o([("projectPath", .string("/work/api"))]), context); XCTAssertEqual(provider.calls[0].0, "list"); XCTAssertEqual(provider.calls[0].1, .string("/work/api"))
        await assertAsyncError({ _ = try await p.run(self.o([("projectPath", .string("/tmp/elsewhere"))]), context) }, contains: "not a folder this app has open")
    }
    func testMcpServerToolsL94() async throws {
        let provider = BackendDeckCoreTestPortSecurityMCPProvider(), p = try policy("mcp.add", provider), context = context(), args = o([("name", .string("github")), ("scope", .string("user")), ("transport", .string("stdio")), ("command", .string("npx -y srv")), ("env", o([("TOKEN", .string("ghp_secret"))]))])
        _ = try await p.run(args, context); XCTAssertEqual(provider.calls[0].0, "add"); XCTAssertEqual(provider.calls[0].1["name"], .string("github")); XCTAssertEqual(provider.calls[0].1["extras"], .array([.string("TOKEN=ghp_secret")]))
        let redacted = try p.redactArgs?(args); XCTAssertFalse(redacted?.compact.contains("ghp_secret") == true); assertValue(redacted?["env"] ?? .null, o([("TOKEN", .string("[redacted]"))]))
        let sentence = try p.summary(args, context); XCTAssertTrue(sentence.contains("given TOKEN")); XCTAssertFalse(sentence.contains("ghp_secret"))
    }
    func testMcpServerToolsL108() throws {
        let p = try policy("mcp.add"), context = context()
        assertError({ try p.precheck?(self.o([("name", .string("--scope")), ("scope", .string("user")), ("transport", .string("stdio")), ("command", .string("x"))]), context) }, contains: "must start with a letter or number")
        assertError({ try p.precheck?(self.o([("name", .string("a")), ("scope", .string("project")), ("transport", .string("stdio")), ("command", .string("x"))]), context) }, contains: "Open a project first")
    }
    func testMcpServerToolsL119() async throws {
        let provider = BackendDeckCoreTestPortSecurityMCPProvider(); provider.writeResult = o([("ok", .bool(false)), ("message", .string("claude is not installed"))]); let p = try policy("mcp.add", provider), context = context()
        await assertAsyncError({ _ = try await p.run(self.o([("name", .string("a")), ("scope", .string("user")), ("transport", .string("stdio")), ("command", .string("x"))]), context) }, contains: "claude is not installed")
    }
    func testMcpServerToolsL127() async throws {
        let provider = BackendDeckCoreTestPortSecurityMCPProvider(), p = try policy("mcp.edit", provider), args = o([("name", .string("github")), ("scope", .string("user")), ("next", o([("transport", .string("stdio")), ("command", .string("npx srv@2")), ("env", o([("TOKEN", .string(""))]))]))])
        _ = try await p.run(args, context()); let request = provider.calls[0].1; XCTAssertEqual(provider.calls[0].0, "edit"); XCTAssertEqual(request["name"], .string("github")); XCTAssertEqual(request["scope"], .string("user")); XCTAssertEqual(request["projectPath"], .null); XCTAssertEqual(request["next"]["name"], .string("github")); XCTAssertEqual(request["next"]["scope"], .string("user")); XCTAssertEqual(request["next"]["command"], .string("npx srv@2")); XCTAssertEqual(request["next"]["extras"], .array([.string("TOKEN=")]))
    }
    func testMcpServerToolsL140() async throws { let provider = BackendDeckCoreTestPortSecurityMCPProvider(), p = try policy("mcp.remove", provider); _ = try await p.run(o([("name", .string("github")), ("scope", .string("local")), ("projectPath", .string("/work/api"))]), context()); XCTAssertEqual(provider.calls[0].0, "remove"); assertValue(provider.calls[0].1, o([("name", .string("github")), ("scope", .string("local")), ("projectPath", .string("/work/api"))])) }
    func testMcpServerToolsL149() async throws { let p = try policy("mcp.connect"), output = try await p.run(o([("serverId", .string("user:github"))]), context()); XCTAssertEqual(output.value["tools"].elements?.count, 1); XCTAssertFalse(output.value.compact.contains("ghp_")) }
    func testMcpServerToolsL157() throws { let p = try policy("mcp.call"); XCTAssertEqual(p.tool.tier, .alter); XCTAssertEqual(try p.summary(o([("serverId", .string("user:github")), ("tool", .string("create_issue")), ("arguments", o([("repo", .string("x")), ("title", .string("y"))]))]), context()), "Call create_issue on the MCP server user:github with repo, title") }
    func testMcpServerToolsL168() throws { let p = try policy("mcp.install"), redacted = try p.redactArgs?(o([("id", .string("github")), ("values", o([("TOKEN", .string("ghp_x"))]))])); assertValue(redacted ?? .null, o([("id", .string("github")), ("values", o([("TOKEN", .string("[redacted]"))]))])) }
    func testMcpServerToolsL173() async throws { let p = try policy("mcp.export"), context = context(), output = try await p.run(o([("name", .string("github")), ("scope", .string("user"))]), context); XCTAssertEqual(output.value["fileName"], .string("github.mcp.json")); await assertAsyncError({ _ = try await p.run(self.o([("name", .string("nope")), ("scope", .string("user"))]), context) }, contains: "not in the configuration") }
    func testMcpServerToolsL180() async throws { let p = try policy("mcp.import"), context = context(); await assertAsyncError({ _ = try await p.run(self.o([("text", .string("not json"))]), context) }, contains: "not a server definition") }
    func testMcpServerToolsL186() { assertValue(BackendDeckCoreEventsTools.redactEnvValues(o([("next", o([("headers", o([("Authorization", .string("Bearer x"))]))]))])), o([("next", o([("headers", o([("Authorization", .string("[redacted]"))]))]))])) }
}
