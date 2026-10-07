import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreTestPortSecurityServer: BackendDeckCoreTestPortSecurityCase {
    private func opened(approval: BackendDeckCoreTestPortSecurityRig.Approval = .absent) async throws -> BackendDeckCoreTestPortSecurityDoorFixture {
        let f = try await BackendDeckCoreTestPortSecurityDoorFixture(directory: scratch(), approval: approval)
        f.rig.surface.sessions = [BackendDeckCoreTestPortSecuritySurface.meta("session-1")]; f.rig.surface.statuses = ["session-1": o([("status", .string("working")), ("at", .number(2000))])]
        return f
    }
    private func call(_ f: BackendDeckCoreTestPortSecurityDoorFixture, _ name: String, args: V = .object([]), token: String? = nil) async throws -> V {
        try response(await f.post(rpc("tools/call", params: o([("name", .string(name)), ("arguments", args)])), credential: token ?? f.endpoint.token))["result"]
    }
    private var write: V { o([("scope", .string("settings")), ("patch", o([("appearance.density", .string("compact"))]))]) }
    private func text(_ value: V) -> String { (value["content"].elements ?? []).compactMap { $0["text"].string }.joined() }
    func testServerL210() async throws { let f = try await opened(), current = await f.server.currentEndpoint(); XCTAssertEqual(f.endpoint.url.absoluteString, "http://127.0.0.1:\(f.endpoint.port)/mcp"); XCTAssertGreaterThan(f.endpoint.port, 0); XCTAssertEqual(current?.port, f.endpoint.port); XCTAssertEqual(current?.token, f.endpoint.token); await f.stop() }
    func testServerL216() async throws { let f = try await opened(), first = f.endpoint.token; await f.server.stop(); let next = try await f.server.start(); XCTAssertNotEqual(next.token, first); XCTAssertEqual(first.count, 64); await f.stop() }
    func testServerL225() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: nil); XCTAssertEqual(response.status, 403); await f.stop() }
    func testServerL229() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: String(repeating: "f", count: 64)); XCTAssertEqual(response.status, 403); await f.stop() }
    func testServerL234() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: nil); XCTAssertNotEqual(response.status, 401); XCTAssertNil(response.headers["www-authenticate"]); await f.stop() }
    func testServerL243() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: f.endpoint.token, headers: ["origin": "https://evil.example"]); XCTAssertEqual(response.status, 403); await f.stop() }
    func testServerL252() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: f.endpoint.token, headers: ["host": "attacker.example"]); XCTAssertEqual(response.status, 403); await f.stop() }
    func testServerL259() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: f.endpoint.token, headers: ["host": "attacker.example:\(f.endpoint.port)"]); XCTAssertEqual(response.status, 403); await f.stop() }
    func testServerL268() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: f.endpoint.token, headers: ["host": "127.0.0.1:40404"]); XCTAssertEqual(response.status, 200); await f.stop() }
    func testServerL286() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: f.endpoint.token, path: "/anything-else"); XCTAssertEqual(response.status, 404); await f.stop() }
    func testServerL294() async throws { let f = try await opened(), response = try await f.post(rpc("ping"), credential: f.endpoint.token, method: "GET"); XCTAssertEqual(response.status, 405); await f.stop() }
    func testServerL303() async throws { let f = try await opened(); var h = headers; h["authorization"] = "Bearer " + f.endpoint.token; let response = await f.server.respond(.init(method: "POST", path: "/mcp", headers: h, body: Data("not json at all".utf8))); XCTAssertEqual(response.status, 400); await f.stop() }
    func testServerL315() async throws {
        let f = try await opened(), value = try response(await f.post(rpc("tools/list"), credential: f.endpoint.token)), tools = value["result"]["tools"].elements ?? []
        XCTAssertEqual(tools.compactMap { $0["name"].string }.sorted(), ["alerts_list", "git_diff", "projects_list", "sessions_list", "sessions_result", "sessions_send", "sessions_start", "sessions_stop", "sessions_transcript", "settings_read", "tools_describe"])
        let describe = tools.first { $0["name"].string == "tools_describe" }; XCTAssertTrue(describe?["description"].string?.contains("settings_write —") == true); XCTAssertTrue(describe?["description"].string?.contains("log_note —") == true); XCTAssertEqual(describe?["annotations"]["readOnlyHint"], .bool(true))
        XCTAssertEqual(tools.first { $0["name"].string == "sessions_list" }?["annotations"]["readOnlyHint"], .bool(true)); XCTAssertEqual(tools.first { $0["name"].string == "sessions_start" }?["annotations"]["readOnlyHint"], .bool(false)); await f.stop()
    }
    func testServerL354() async throws {
        let f = try await opened(), described = try await call(f, "tools_describe", args: o([("tools", .array([.string("settings_write")]))])), tool = described["structuredContent"]["tools"].elements?.first
        XCTAssertEqual(tool?["name"], .string("settings_write")); XCTAssertEqual(tool?["inputSchema"]["type"], .string("object")); XCTAssertEqual(tool?["annotations"]["destructiveHint"], .bool(true)); let read = try await call(f, "settings_read"); XCTAssertNotEqual(read["isError"], .bool(true)); await f.stop()
    }
    func testServerL377() async throws {
        let f = try await opened(), result = try await call(f, "sessions_list"), session = result["structuredContent"]["sessions"].elements?.first
        XCTAssertNotEqual(result["isError"], .bool(true)); XCTAssertEqual(session?["id"], .string("session-1")); XCTAssertEqual(session?["status"], .string("working")); XCTAssertEqual(session?["startedByCopilot"], .bool(false))
        let textValue = try json(result["content"].elements?.first?["text"].string ?? "null"); XCTAssertEqual(textValue["count"], .number(1)); await f.stop()
    }
    func testServerL392() async throws { let f = try await opened(), result = try await call(f, "sessions_get", args: o([("sessionId", .string("nope"))])); XCTAssertEqual(result["isError"], .bool(true)); XCTAssertTrue(text(result).contains("not holding a session with id nope")); XCTAssertTrue(text(result).contains("sessions.list")); await f.stop() }
    func testServerL409() async throws { let f = try await opened(), result = try await call(f, "sessions_delete_everything"); XCTAssertEqual(result["isError"], .bool(true)); await f.stop() }
    func testServerL416() async throws { let f = try await opened(), first = try await call(f, "projects_list"), second = try await call(f, "projects_list"); XCTAssertNotEqual(first["isError"], .bool(true)); XCTAssertNotEqual(second["isError"], .bool(true)); await f.stop() }
    func testServerL429() async throws { let f = try await opened(), result = try await call(f, "settings_write", args: write); XCTAssertEqual(result["isError"], .bool(true)); XCTAssertTrue(text(result).contains("no window open")); XCTAssertEqual(f.rig.surface.settings["appearance.density"], .string("comfortable")); await f.stop() }
    func testServerL454() async throws { let f = try await opened(approval: .decline), result = try await call(f, "settings_write", args: write); XCTAssertEqual(result["isError"], .bool(true)); XCTAssertEqual(f.rig.surface.settings["appearance.density"], .string("comfortable")); await f.stop() }
    func testServerL468() async throws { let f = try await opened(approval: .allow), result = try await call(f, "settings_write", args: write); XCTAssertNotEqual(result["isError"], .bool(true)); XCTAssertEqual(f.rig.surface.settings["appearance.density"], .string("compact")); XCTAssertEqual(f.rig.questions.get()[0].summary, "Change settings: appearance.density to \"compact\""); await f.stop() }
    func testServerL483() async throws { let f = try await opened(approval: .allow), result = try await call(f, "settings_write", args: o([("scope", .string("settings")), ("patch", o([("remote.enabled", .bool(true))]))])); XCTAssertEqual(result["isError"], .bool(true)); XCTAssertTrue(f.rig.questions.get().isEmpty); XCTAssertEqual(f.rig.surface.settings["remote.enabled"], .missing); await f.stop() }
    func testServerL498() async throws { let f = try await opened(), result = try await call(f, "sessions_send", args: o([("sessionId", .string("session-1")), ("text", .string("delete the branch"))])); XCTAssertEqual(result["isError"], .bool(true)); XCTAssertTrue(f.rig.surface.writes.isEmpty); await f.stop() }
    func testServerL532() async throws { let f = try await opened(approval: .allow), result = try await call(f, "settings_write", args: write, token: f.endpoint.unattendedToken); XCTAssertEqual(result["isError"], .bool(true)); XCTAssertTrue(f.rig.questions.get().isEmpty); XCTAssertEqual(f.rig.surface.settings["appearance.density"], .string("comfortable")); await f.stop() }
    func testServerL552() async throws { let f = try await opened(approval: .allow), result = try await call(f, "settings_write", args: write, token: f.endpoint.unattendedToken); XCTAssertTrue(text(result).contains("nobody at the machine")); XCTAssertTrue(text(result).contains("Do not retry it")); await f.stop() }
    func testServerL568() async throws { let f = try await opened(); for (name, args) in [("projects_list", V.object([])), ("sessions_list", V.object([])), ("sessions_start", o([("cwd", .string("/work/api"))]))] { let result = try await call(f, name, args: args, token: f.endpoint.unattendedToken); XCTAssertNotEqual(result["isError"], .bool(true)) }; await f.stop() }
    func testServerL580() async throws { let f = try await opened(); XCTAssertNotEqual(f.endpoint.unattendedToken, f.endpoint.token); XCTAssertEqual(f.endpoint.unattendedToken.count, f.endpoint.token.count); await f.stop() }
    func testServerL585() async throws { let f = try await opened(), rejected = try await f.post(rpc("initialize", params: o([("protocolVersion", .string("2025-06-18")), ("capabilities", .object([])), ("clientInfo", o([("name", .string("test")), ("version", .string("1"))]))])), credential: String(repeating: "0", count: 64)); XCTAssertEqual(rejected.status, 403); await f.stop() }
    func testServerL593() async throws {
        let f = try rig(), capture = BackendDeckCoreSecurityTestBox<BackendDeckCoreTestPortSecurityListener?>(nil), created = BackendDeckCoreTestPortSecuritySignal()
        let server = f.server(factory: { handler in let listener = BackendDeckCoreTestPortSecurityListener(paused: true, handler: handler); capture.set(listener); created.signal(); return listener })
        let first = Task { try await server.start() }; await created.wait(1); let listener = try XCTUnwrap(capture.get()); await listener.entered.wait(1)
        let second = Task { try await server.start() }; await listener.release(); let (a, b) = try await (first.value, second.value); XCTAssertEqual(a.port, b.port); let calls = await listener.snapshot(); XCTAssertEqual(calls.requested.count, 1); await server.stop()
    }
    func testServerL609() async throws {
        let f = try await opened(); await f.server.stop(); let current = await f.server.currentEndpoint(); XCTAssertNil(current)
        let body = try rpc("ping").encodedJSON(), h = headers
        await assertAsyncError({ _ = try await f.listener.request(.init(method: "POST", path: "/mcp", headers: h, body: body)) }, code: "connection-refused"); await f.stop()
    }
}
