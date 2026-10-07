import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeMachinesTestsPanelsMCP: XCTestCase {
    private let path = "/work/app"
    private typealias F = BackendRemoteServeMachinesTestsPanelsMCPFixtures
    private func read(_ rig: BackendRemoteServeMachinesTestsPanelsMCPRig, scope: String? = nil, path: String? = nil, pool: Bool = false) async throws -> NativeRPCValue {
        let panel = await rig.provider(pool: pool); return try await panel.read(.init(path: path ?? self.path, scope: scope, query: nil), .init(caller: .nativeApp, ownerID: "test"))
    }
    private func act(_ rig: BackendRemoteServeMachinesTestsPanelsMCPRig, _ action: String, id: String? = nil, fields: [String: String] = [:], pool: Bool = false) async throws -> NativeRPCValue {
        let panel = await rig.provider(pool: pool), run = try XCTUnwrap(panel.act)
        return try await run(.init(panel: .init(path: path, scope: nil, query: nil), action: action, id: id, fields: fields), .init(caller: .nativeApp, ownerID: "test"))
    }
    private func row(_ payload: NativeRPCValue) throws -> NativeRPCValue { try XCTUnwrap(payload["rows"].elements?.first) }
    func testConfiguredServerShowsCommandScopeAndIdentity() async throws {
        let payload = try await read(.init()); XCTAssertEqual(payload["path"].string, path); XCTAssertEqual(payload["rows"].elements?.count, 1)
        let row = try row(payload); XCTAssertEqual(row["title"].string, "mine"); XCTAssertEqual(row["detail"].string, "npx -y @me/thing"); XCTAssertEqual(row["value"].string, "user · stdio"); XCTAssertEqual(row["id"].string, "user:mine")
    }
    func testReaderReceivesProjectAndReturnsAllScopes() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig([F.server(), F.server(id: "project:shared", name: "shared", scope: "project")])
        let payload = try await read(rig); let seen = await rig.seenPaths
        XCTAssertEqual(seen, [path]); XCTAssertEqual(payload["rows"].elements?.map { $0["value"].string }, ["user · stdio", "project · stdio"])
    }
    func testDisabledReasonReplacesCommandAndTintsWarn() async throws {
        let payload = try await read(.init([F.server(scope: "project", enabled: false, disabled: "Not approved for this project yet.")]))
        XCTAssertEqual(try row(payload)["detail"].string, "Not approved for this project yet."); XCTAssertEqual(try row(payload)["status"].string, "warn")
    }
    func testHTTPURLStaysOnRowDespiteInspectorUnsupportedReason() async throws {
        let payload = try await read(.init([F.server(id: "user:remote", name: "remote", transport: "http", url: "https://example.com/mcp", unsupported: "Claude Code dials HTTP servers itself, so this panel cannot inspect it.")]))
        XCTAssertEqual(try row(payload)["detail"].string, "https://example.com/mcp"); XCTAssertEqual(try row(payload)["value"].string, "user · http")
    }
    func testScopeFilterKeepsSelectedEmptyChipWithReason() async throws {
        let payload = try await read(.init(), scope: "project"); XCTAssertEqual(payload["rows"].elements?.count, 0); XCTAssertTrue(payload["note"].string?.contains("project scope") == true)
        XCTAssertEqual(payload["scopes"].elements?.first { $0["id"].string == "project" }?["on"].bool, true)
    }
    func testConnectedServerIsGreenAndOffersDisconnectEditRemove() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig(); await rig.status("ready")
        let payload = try await read(rig, pool: true); XCTAssertEqual(try row(payload)["status"].string, "ok"); XCTAssertEqual(try row(payload)["actions"].elements?.map { $0["id"].string }, ["disconnect", "edit", "remove"])
    }
    func testFailedServerIsRedAndDisplaysPoolError() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig(); await rig.status("failed", error: "spawn npx ENOENT")
        let payload = try await read(rig, pool: true); XCTAssertEqual(try row(payload)["status"].string, "bad"); XCTAssertEqual(try row(payload)["detail"].string, "spawn npx ENOENT")
    }
    func testNoPoolClaimsNoConnectionStatusButStillOffersEditAndRemove() async throws {
        let payload = try await read(.init()); XCTAssertFalse(try row(payload).has("status")); XCTAssertEqual(try row(payload)["actions"].elements?.map { $0["id"].string }, ["edit", "remove"])
    }
    func testAddUsesNamedScopeAndAddressingProjectFolder() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig([]), payload = try await act(rig, "add", fields: ["name": "files", "command": "npx -y @modelcontextprotocol/server-filesystem", "scope": "project", "env.4": ""])
        let calls = await rig.calls; XCTAssertEqual(calls.count, 1); XCTAssertTrue(calls[0].line.contains("--scope project")); XCTAssertTrue(calls[0].line.contains("mcp add --scope project files --"))
        XCTAssertEqual(calls[0].cwd, URL(fileURLWithPath: path).standardizedFileURL.path); XCTAssertTrue(payload["notice"].string?.contains("files") == true)
    }
    func testAddPassesEnvironmentAsOneDashE() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig([])
        _ = try await act(rig, "add", fields: ["name": "files", "command": "npx -y @me/thing", "scope": "user", "env.4": "API_KEY=fresh"])
        let calls = await rig.calls; XCTAssertTrue(try XCTUnwrap(calls.first).line.contains("-e API_KEY=fresh"))
    }
    func testEmptyAddAsksForCommandOrURLAndDoesNotSpawn() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig([]), payload = try await act(rig, "add", fields: ["name": "files", "scope": "user"])
        let count = await rig.calls.count; XCTAssertEqual(count, 0); XCTAssertEqual(payload["notice"].string, "Give the command that starts the server, or its URL.")
    }
    func testEmptyConfigurationOffersAddNoteAndNoChips() async throws {
        let payload = try await read(.init([]), path: "/work/empty")
        XCTAssertEqual(payload["rows"], .array([])); XCTAssertEqual(payload["note"].string, "No MCP servers are configured for /work/empty.")
        XCTAssertEqual(payload["actions"].elements?.map { $0["id"].string }, ["add"]); XCTAssertFalse(payload.has("scopes"))
    }
    func testEditFormMatchesRowAndShowsKeysButNoSecrets() async throws {
        let payload = try await read(.init()), row = try row(payload)
        let fields = try XCTUnwrap(row["actions"].elements?.first { $0["id"].string == "edit" }?["fields"].elements)
        func field(_ id: String) throws -> NativeRPCValue { try XCTUnwrap(fields.first { $0["id"].string == id }) }
        XCTAssertEqual(try field("command")["value"], row["detail"]); XCTAssertEqual(try field("name")["value"].string, "mine"); XCTAssertEqual(try field("url")["value"].string, ""); XCTAssertEqual(try field("scope")["value"].string, "user")
        XCTAssertEqual(try field("env.4")["label"].string, "API_KEY"); XCTAssertEqual(try field("env.4")["value"].string, "API_KEY=")
        XCTAssertFalse(NativeRPCValue.array(fields).compact.contains("secret-value")); XCTAssertEqual(try field("env.5")["label"].string, "Environment variable"); XCTAssertFalse(try field("env.5").has("value"))
    }
    func testUnchangedEnvironmentKeyKeepsSavedValueThroughRealMergeAndWriter() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig()
        _ = try await act(rig, "edit", id: "user:mine", fields: ["name": "mine", "command": "npx -y @me/thing --verbose", "url": "", "scope": "user", "env.4": "API_KEY="])
        let calls = await rig.calls; guard calls.count == 2 else { XCTFail("Expected the real writer to remove then add; got \(calls.count) calls"); return }
        XCTAssertEqual(calls.map { String($0.line.split(separator: " ")[1]) }, ["remove", "add"])
        XCTAssertTrue(calls[1].line.contains("-e API_KEY=secret-value")); XCTAssertTrue(calls[1].line.contains("-- npx -y @me/thing --verbose"))
    }
    func testClearedEnvironmentBoxDropsVariableThroughRealMergeAndWriter() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig()
        _ = try await act(rig, "edit", id: "user:mine", fields: ["name": "mine", "command": "npx -y @me/thing", "url": "", "scope": "user", "env.4": ""])
        let calls = await rig.calls; guard calls.count == 2 else { XCTFail("Expected the real writer to remove then add; got \(calls.count) calls"); return }
        XCTAssertFalse(calls[1].line.contains("-e ")); XCTAssertFalse(calls[1].line.contains("API_KEY"))
    }
    func testGoneEditRowHasExactRefusalAndNoWrite() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig([]), payload = try await act(rig, "edit", id: "user:mine", fields: ["name": "mine", "command": "npx", "scope": "user"])
        let count = await rig.calls.count; XCTAssertEqual(count, 0); XCTAssertEqual(payload["notice"].string, "That server is not in this configuration any more.")
    }
    func testRemoveUsesServersOwnScope() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig(), payload = try await act(rig, "remove", id: "user:mine")
        let calls = await rig.calls; XCTAssertEqual(try XCTUnwrap(calls.first).line, "mcp remove --scope user mine"); XCTAssertTrue(payload["notice"].string?.contains("mine") == true)
    }
    func testSharedRemoveWarnsAboutProjectConfiguration() async throws {
        let payload = try await read(.init([F.server(id: "project:shared", name: "shared", scope: "project")]))
        let remove = try XCTUnwrap(try row(payload)["actions"].elements?.first { $0["id"].string == "remove" })
        XCTAssertEqual(remove["kind"].string, "destructive"); XCTAssertTrue(remove["confirm"].string?.contains(".mcp.json") == true)
    }
    func testConfigurationReadFailureBecomesNoteAndStillOffersAdd() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig(); await rig.fail(list: "EACCES: permission denied, open /home/me/.claude.json")
        let payload = try await read(rig); XCTAssertEqual(payload["rows"], .array([])); XCTAssertTrue(payload["note"].string?.contains("could not be read") == true); XCTAssertTrue(payload["note"].string?.contains("EACCES") == true)
        XCTAssertEqual(payload["actions"].elements?.map { $0["id"].string }, ["add"])
    }
    func testPoolRejectionBecomesExactNoticeAndRedraw() async throws {
        let rig = BackendRemoteServeMachinesTestsPanelsMCPRig(); await rig.fail(connect: "the transport closed before it spoke")
        let payload = try await act(rig, "connect", id: "user:mine", pool: true); XCTAssertEqual(payload["notice"].string, "the transport closed before it spoke"); XCTAssertEqual(payload["rows"].elements?.count, 1)
    }
    func testUnrecognizedActionDoesNotPretendToWork() async throws {
        let payload = try await act(.init(), "call", id: "user:mine")
        XCTAssertEqual(payload["notice"].string, "That is not something this panel offers."); XCTAssertEqual(payload["rows"].elements?.count, 1)
    }
}

private enum BackendRemoteServeMachinesTestsPanelsMCPFixtures {
    static func server(id: String = "user:mine", name: String = "mine", scope: String = "user", transport: String = "stdio", url: String = "", enabled: Bool = true, disabled: String? = nil, unsupported: String? = nil) -> BackendRemotePanelMCPServer {
        .init(id: id, name: name, scope: scope, transport: transport, commandLine: transport == "stdio" ? BackendMcpClientCommands.quoteArgv(["npx", "-y", "@me/thing"]) : "", url: url, envKeys: ["API_KEY"], enabled: enabled, disabledReason: disabled, unsupported: unsupported)
    }
}
private struct BackendRemoteServeMachinesTestsPanelsMCPError: LocalizedError, Sendable { let message: String; var errorDescription: String? { message } }
private actor BackendRemoteServeMachinesTestsPanelsMCPRig {
    struct Call: Sendable { let file: String, args: [String], cwd: String; var line: String { args.joined(separator: " ") } }
    private var servers: [BackendRemotePanelMCPServer], listError: String?, connectError: String?, state: String?, poolError: String?
    private(set) var seenPaths: [String] = [], calls: [Call] = []
    init(_ servers: [BackendRemotePanelMCPServer] = [BackendRemoteServeMachinesTestsPanelsMCPFixtures.server()]) { self.servers = servers }
    func fail(list: String? = nil, connect: String? = nil) { listError = list; connectError = connect }
    func status(_ state: String, error: String? = nil) { self.state = state; poolError = error }
    func provider(pool: Bool = false) -> BackendRemotePanelProvider {
        BackendRemotePanelMCP.provider(.init(list: { path, _ in try await self.list(path) },
            add: { input, _ in await self.writer().add(input) }, edit: { server, input, _ in try await self.edit(server, input) },
            remove: { server, path, _ in await self.writer().remove(.object([.init("name", .string(server.name)), .init("scope", .string(server.scope)), .init("projectPath", .string(path))])) },
            status: pool ? { @Sendable _ in await self.statusValue() } : nil,
            connect: pool ? { @Sendable _, _ in try await self.connect() } : nil, disconnect: pool ? { @Sendable _, _ in } : nil))
    }
    private func list(_ path: String) throws -> [BackendRemotePanelMCPServer] { seenPaths.append(path); if let listError { throw BackendRemoteServeMachinesTestsPanelsMCPError(message: listError) }; return servers }
    private func statusValue() -> NativeRPCValue? { state.map { .object([.init("state", .string($0)), .init("error", poolError.map(NativeRPCValue.string) ?? .null)]) } }
    private func connect() throws -> NativeRPCValue { if let connectError { throw BackendRemoteServeMachinesTestsPanelsMCPError(message: connectError) }; return .object([.init("state", .string("ready"))]) }
    private func writer() -> BackendMcpClientWriter {
        .init(configuration: .init(home: "/home/me", environment: [:]), loginPath: { "/usr/bin" }, run: { file, args, _, cwd, _ in await self.record(file, args, cwd) })
    }
    private func record(_ file: String, _ args: [String], _ cwd: String) -> BackendGitOutcome {
        calls.append(.init(file: file, args: args, cwd: cwd)); return .init(ok: true, stdout: "", stderr: "", missing: false, exitCode: 0, timedOut: false)
    }
    private func edit(_ server: BackendRemotePanelMCPServer, _ input: NativeRPCValue) async throws -> NativeRPCValue {
        // The real production merge, validator and command writer execute.
        // Only saved configuration lookup and process execution are fake. The
        // complete Writer.edit disk lookup has no injected reader yet.
        let merged = try BackendMcpClientCommands.mergeEnvironment(input["extras"].elements?.compactMap(\.string) ?? [], saved: .object([.init("API_KEY", .string("secret-value"))]))
        let writer = writer()
        let removed = await writer.remove(.object([.init("name", .string(server.name)), .init("scope", .string(server.scope)), .init("projectPath", input["projectPath"])]))
        guard removed["ok"].bool == true else { return removed }
        return await writer.add(input.setting("extras", .array(merged.map(NativeRPCValue.string))))
    }
}
