import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// These tests are written for the final combined gate only. They exercise the
/// real security dispatch with synthetic tools; they never invoke a paid CLI.
final class BackendCopilotSessionMCPDoorTests: XCTestCase {
    private func makeServer(_ root: URL) throws -> (BackendDeckCoreSecurityServer, BackendDeckCoreSecurityActionLog) {
        let log = BackendDeckCoreSecurityActionLog(directory: root.appendingPathComponent("copilot-log"))
        let consent = BackendDeckCoreSecurityConsentBroker(ask: { _ in false })
        let read = try BackendMCPTool(id: "sessions.list", wireName: "sessions_list", description: "List sessions", inputSchema: .object([.init("type", .string("object"))]), tier: .read)
        let alter = try BackendMCPTool(id: "settings.write", wireName: "settings_write", description: "Change settings", inputSchema: .object([.init("type", .string("object"))]), tier: .alter)
        let policies: [BackendDeckCoreSecurityToolPolicy] = [
            .init(tool: read, aliases: ["sessions_list_old"], summary: { _, _ in "listed sessions" }, run: { _, _ in .init(value: .object([.init("count", .number(2))]), summary: .object([.init("count", .number(2))])) }),
            .init(tool: alter, summary: { _, _ in "change a setting" }, run: { _, _ in .init(value: .object([.init("changed", .bool(true))])) }),
        ]
        let control = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: policies)
        return (BackendDeckCoreSecurityServer(control: control, ownPorts: BackendDevOwnPorts()), log)
    }
    private func call(_ server: BackendDeckCoreSecurityServer, endpoint: BackendDeckCoreSecurityEndpoint, authorization: String, tool: String) async throws -> BackendDeckCoreSecurityHTTPResponse {
        let body = try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string("tools/call")),
            .init("params", .object([.init("name", .string(tool)), .init("arguments", .object([]))]))]).encodedJSON()
        return await server.respond(.init(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:\(endpoint.port)", "authorization": authorization,
            "content-type": "application/json", "accept": "application/json, text/event-stream"], body: body))
    }
    func testAbsentSecurityServerProducesNoConfigAndMissingTitleRefuses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotSecurity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, _) = try makeServer(root)
        let endpoint = BackendCopilotSessionSecurityEndpoint(server: server)
        let door = try BackendCopilotSessionMCPDoor(endpoint: endpoint, userData: root, titles: { [] })
        let absent = try await door.prepare(); XCTAssertNil(absent)
        _ = try await server.start(port: 0)
        do { _ = try await door.prepare(); XCTFail("Missing live title must refuse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("catalogue title is unavailable")) }
        await door.stop(); await server.stop()
    }
    func testPerRunTokenLivesInAuthoritativeTableIsLocalAndRevokeCancelsIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotSecurity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, log) = try makeServer(root)
        let actual = try await server.start(port: 0)
        let endpoint = BackendCopilotSessionSecurityEndpoint(server: server)
        let titles: [BackendCopilotLayerTool] = [.init(wire: "sessions_list", tier: "read", title: "List sessions"), .init(wire: "settings_write", tier: "alter", title: "Change settings")]
        let door = try BackendCopilotSessionMCPDoor(endpoint: endpoint, userData: root, machineID: "this-mac", titles: { titles })
        let before = await actual.callers.size()
        let preparedA = try await door.prepare(), preparedB = try await door.prepare()
        let a = try XCTUnwrap(preparedA), b = try XCTUnwrap(preparedB)
        XCTAssertNotEqual(a.configPath, b.configPath)
        let aConfig = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: a.configPath)))
        let bConfig = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: b.configPath)))
        let authorization = try XCTUnwrap(aConfig["mcpServers"]["deck-control"]["headers"]["Authorization"].string)
        XCTAssertTrue(authorization != bConfig["mcpServers"]["deck-control"]["headers"]["Authorization"].string)
        let count = await actual.callers.size(); XCTAssertEqual(count, before + 2)
        try await door.bind(a, sessionID: "desk-hoot")
        let matched = await actual.callers.match(authorization: authorization)
        let grant = try XCTUnwrap(matched)
        let caller = await grant.caller(); XCTAssertEqual(caller.kind, .local); XCTAssertEqual(caller.sessionID, "desk-hoot"); XCTAssertEqual(caller.machineID, "this-mac")
        XCTAssertTrue(grant.attended); XCTAssertNil(grant.tools)
        let response = try await call(server, endpoint: actual, authorization: authorization, tool: "sessions_list")
        XCTAssertEqual(response.status, 200)
        let rows = await log.tail()
        let row = try XCTUnwrap(rows.first { $0["action"].string == "tool.sessions.list" })
        XCTAssertEqual(row["outcome"].string, "ok"); XCTAssertEqual(row["tier"].string, "read"); XCTAssertEqual(row["caller"]["kind"].string, "local")
        XCTAssertEqual(row["result"]["count"].number, 2)
        let alias = try await call(server, endpoint: actual, authorization: authorization, tool: "sessions_list_old")
        XCTAssertEqual(alias.status, 200)
        let afterAlias = await log.tail()
        XCTAssertEqual(afterAlias.filter { $0["action"].string == "tool.sessions.list" && $0["outcome"].string == "ok" }.count, 2)
        await door.release(sessionID: "desk-hoot")
        let removed = await actual.callers.match(authorization: authorization); XCTAssertNil(removed)
        XCTAssertTrue(grant.cancellation.isCancelled); XCTAssertFalse(FileManager.default.fileExists(atPath: a.configPath))
        await door.abandon(b); await door.stop(); await server.stop()
    }
    func testAlterDispatchUsesActualConsentGateAndLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendCopilotSecurity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (server, log) = try makeServer(root)
        let actual = try await server.start(port: 0)
        let endpoint = BackendCopilotSessionSecurityEndpoint(server: server)
        let titles: [BackendCopilotLayerTool] = [.init(wire: "sessions_list", tier: "read", title: "List sessions"), .init(wire: "settings_write", tier: "alter", title: "Change settings")]
        let door = try BackendCopilotSessionMCPDoor(endpoint: endpoint, userData: root, titles: { titles })
        let candidate = try await door.prepare()
        let prepared = try XCTUnwrap(candidate)
        try await door.bind(prepared, sessionID: "desk-hoot")
        let config = try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: prepared.configPath)))
        let token = try XCTUnwrap(config["mcpServers"]["deck-control"]["headers"]["Authorization"].string)
        _ = try await call(server, endpoint: actual, authorization: token, tool: "settings_write")
        let rows = await log.tail()
        let row = try XCTUnwrap(rows.first { $0["action"].string == "tool.settings.write" })
        XCTAssertEqual(row["outcome"].string, "refused"); XCTAssertEqual(row["confirmed"]["required"].bool, true); XCTAssertEqual(row["confirmed"]["granted"].bool, false)
        await door.release(sessionID: "desk-hoot"); await door.stop(); await server.stop()
    }
}
