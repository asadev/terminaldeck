import Foundation
import XCTest
import Network
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreTestPortSecurityKeyDoor: BackendDeckCoreTestPortSecurityCase {
    private func fixture(approval: BackendDeckCoreTestPortSecurityRig.Approval = .absent, timeout: Int = 120_000, budgets: BackendDeckCoreSecurityBudgets = .init()) async throws -> BackendDeckCoreTestPortSecurityDoorFixture { try await .init(directory: scratch(), approval: approval, timeout: timeout, budgets: budgets) }
    private func key(_ f: BackendDeckCoreTestPortSecurityDoorFixture, level: String = "full", name: String = "ChatGPT", extras: V = .object([])) async throws -> V { try await made(f.keys, name: name, level: level, extras: extras) }
    private func call(_ f: BackendDeckCoreTestPortSecurityDoorFixture, secret: String?, name: String, args: V = .object([]), path: Bool = false) async throws -> V { try response(await f.post(rpc("tools/call", params: o([("name", .string(name)), ("arguments", args)])), credential: secret, pathCredential: path))["result"] }
    private func text(_ value: V) -> String { (value["content"].elements ?? []).compactMap { $0["text"].string }.joined() }
    private var write: V { o([("scope", .string("settings")), ("patch", o([("appearance.density", .string("compact"))]))]) }
    func testKeyDoorL103() async throws {
        let f = try await fixture(), crm = try await made(f.keys, name: "Sales CRM (CRM)", level: "look", extras: o([("askFirst", .bool(true)), ("crmOnly", .bool(true))]))
        let local = await f.door.grant(credential: crm["key"].string, via: "this-mac"); XCTAssertNil(local); _ = try await f.keys.setInternet(.bool(true)); let internet = await f.door.grant(credential: crm["key"].string, via: "internet"); XCTAssertNil(internet)
        let matched = await f.keys.match(crm["key"].string); XCTAssertEqual(matched?["id"], crm["view"]["id"]); XCTAssertEqual(matched?["crmOnly"], .bool(true))
        let ordinary = try await key(f, level: "work"), grant = await f.door.grant(credential: ordinary["key"].string, via: "this-mac"); XCTAssertNotNil(grant); await grant?.done(); await f.stop()
    }
    func testKeyDoorL117() async throws {
        let f = try await fixture(), made = try await key(f, level: "work"), id = try XCTUnwrap(made["view"]["id"].string)
        let wrong = await f.door.grant(credential: "ak_nope", via: "this-mac"), missing = await f.door.grant(credential: nil, via: "this-mac"); XCTAssertNil(wrong); XCTAssertNil(missing)
        let grant = await f.door.grant(credential: made["key"].string, via: "this-mac"); XCTAssertNotNil(grant); await grant?.done(); _ = try await f.keys.revoke(id: id)
        let revoked = await f.door.grant(credential: made["key"].string, via: "this-mac"); XCTAssertNil(revoked); await f.stop()
    }
    func testKeyDoorL128() async throws {
        let f = try await fixture(), made = try await key(f, level: "look"), off = await f.door.grant(credential: made["key"].string, via: "internet"), local = await f.door.grant(credential: made["key"].string, via: "this-mac")
        XCTAssertNil(off); XCTAssertNotNil(local); _ = try await f.keys.setInternet(.bool(true)); let internet = await f.door.grant(credential: made["key"].string, via: "internet"); XCTAssertNotNil(internet); await local?.done(); await internet?.done(); await f.stop()
    }
    func testKeyDoorL136() async throws {
        let f = try await fixture(), made = try await key(f, level: "look"), id = try XCTUnwrap(made["view"]["id"].string), opened = await f.door.grant(credential: made["key"].string, via: "this-mac"), grant = try XCTUnwrap(opened)
        let look = await grant.caller(); XCTAssertEqual(look.tiers, [.read]); _ = try await f.keys.setLevel(id: id, level: .string("full")); let full = await grant.caller(); XCTAssertEqual(full.tiers, [.read, .act, .alter])
        _ = try await f.keys.revoke(id: id); let gone = await grant.caller(); XCTAssertEqual(gone.tiers, []); await grant.done(); await f.stop()
    }
    func testKeyDoorL146() async throws { let f = try await fixture(), made = try await key(f), id = try XCTUnwrap(made["view"]["id"].string), grant = await f.door.grant(credential: made["key"].string, via: "this-mac"); XCTAssertFalse(grant?.cancellation.isCancelled == true); XCTAssertEqual(f.door.inFlightCount(keyID: id), 1); _ = try await f.keys.revoke(id: id); XCTAssertTrue(grant?.cancellation.isCancelled == true); await f.stop() }
    func testKeyDoorL155() async throws { let f = try await fixture(), made = try await key(f); _ = try await f.keys.setInternet(.bool(true)); let local = await f.door.grant(credential: made["key"].string, via: "this-mac"), remote = await f.door.grant(credential: made["key"].string, via: "internet"); _ = try await f.keys.setInternet(.bool(false)); XCTAssertTrue(remote?.cancellation.isCancelled == true); XCTAssertFalse(local?.cancellation.isCancelled == true); await f.stop() }
    func testKeyDoorL165() async throws {
        let f = try await fixture(approval: .hold), made = try await key(f), id = try XCTUnwrap(made["view"]["id"].string), opened = await f.door.grant(credential: made["key"].string, via: "this-mac"), grant = try XCTUnwrap(opened), caller = await grant.caller(), args = write
        let pending = Task { await f.rig.call("settings.write", args, .init(caller: caller, cancellation: grant.cancellation)) }; await f.rig.asked.wait(1)
        let questions = await f.rig.consent.list(); XCTAssertEqual(questions.map(\.origin), ["key:" + id]); _ = try await f.keys.revoke(id: id)
        let result = await pending.value; XCTAssertFalse(result.ok); XCTAssertEqual(result.refusal, .callerGone); XCTAssertEqual(f.rig.surface.settings["appearance.density"], .string("comfortable")); await f.stop()
    }
    func testKeyDoorL183() async throws {
        let f = try await fixture(), made = try await key(f, level: "look"), id = try XCTUnwrap(made["view"]["id"].string)
        let local = await f.door.grant(credential: made["key"].string, via: "this-mac", userAgent: "claude-code/2.1.233 (external, cli)"); await local?.done(); let view = await f.keys.get(id: id); XCTAssertEqual(view?["lastApp"], .string("claude-code/2.1.233"))
        let off = await f.door.grant(credential: made["key"].string, via: "internet"); XCTAssertNil(off); _ = try await f.keys.setInternet(.bool(true))
        let remote = await f.door.grant(credential: made["key"].string, via: "internet", userAgent: "python-httpx/0.27"); await remote?.noteClient("claude-ai 0.1.0"); let after = await f.keys.get(id: id); XCTAssertEqual(after?["lastApp"], .string("claude-ai 0.1.0")); XCTAssertEqual(after?["lastVia"], .string("internet")); await f.stop()
    }
    func testKeyDoorL194() async throws {
        let f = try await fixture(), made = try await key(f, level: "work", name: "Cursor", extras: o([("folders", .array([.string("/work/site")])), ("askFirst", .bool(false))])), id = try XCTUnwrap(made["view"]["id"].string), caller = await f.keys.caller(id: id, nameAtArrival: "old name")
        XCTAssertEqual(caller.kind, .key); XCTAssertEqual(caller.keyID, id); XCTAssertEqual(caller.keyName, "Cursor"); XCTAssertEqual(caller.askFirst, false); XCTAssertEqual(caller.folders, ["/work/site"]); XCTAssertFalse(caller.tasks)
        _ = try await f.keys.setTasks(id: id, on: .bool(true)); let after = await f.keys.caller(id: id, nameAtArrival: "old name"); XCTAssertTrue(after.tasks); await f.stop()
    }
    func testKeyDoorL213() async throws {
        let f = try await fixture(), made = try await key(f, level: "look", name: "Cursor"), id = try XCTUnwrap(made["view"]["id"].string)
        let initialized = try response(await f.post(rpc("initialize", params: o([("protocolVersion", .string("2025-06-18")), ("capabilities", .object([])), ("clientInfo", o([("name", .string("outside-app")), ("version", .string("9.9.9"))]))])), credential: made["key"].string))
        let listed = try response(await f.post(rpc("tools/list"), credential: made["key"].string)), names = listed["result"]["tools"].elements?.compactMap { $0["name"].string } ?? []
        XCTAssertTrue(names.contains("tools_run")); XCTAssertTrue(names.contains("tools_describe")); XCTAssertTrue(names.contains("sessions_list")); let view = await f.keys.get(id: id); XCTAssertEqual(view?["lastApp"], .string("outside-app 9.9.9")); XCTAssertEqual(view?["lastVia"], .string("this-mac")); XCTAssertTrue(initialized["result"]["instructions"].string?.contains("tools_run") == true); XCTAssertTrue(initialized["result"]["instructions"].string?.contains("may only look") == true); await f.stop()
    }
    func testKeyDoorL230() async throws { let f = try await fixture(), made = try await key(f, level: "look", name: "Cursor"), id = try XCTUnwrap(made["view"]["id"].string), result = try await call(f, secret: made["key"].string, name: "sessions_list"); XCTAssertNotEqual(result["isError"], .bool(true)); let rows = await f.rig.log.tail(5), row = try XCTUnwrap(rows.first { $0["tool"] == .string("sessions.list") }); XCTAssertEqual(row["caller"]["kind"], .string("key")); XCTAssertEqual(row["caller"]["keyId"], .string(id)); XCTAssertEqual(row["caller"]["keyName"], .string("Cursor")); XCTAssertTrue(row["detail"].string?.hasPrefix("From “Cursor”:") == true); await f.stop() }
    func testKeyDoorL241() async throws { let f = try await fixture(), made = try await key(f, level: "look"), result = try await call(f, secret: made["key"].string, name: "projects_list", path: true); XCTAssertNotEqual(result["isError"], .bool(true)); await f.stop() }
    func testKeyDoorL249() async throws {
        let f = try await fixture(), made = try await key(f, level: "look"), id = try XCTUnwrap(made["view"]["id"].string)
        let good = try await f.post(rpc("ping"), credential: made["key"].string), wrong = try await f.post(rpc("ping"), credential: "ak_wrong"), tokenPath = try await f.post(rpc("ping"), credential: f.endpoint.token, pathCredential: true); XCTAssertEqual(good.status, 200); XCTAssertEqual(wrong.status, 403); XCTAssertEqual(tokenPath.status, 403)
        _ = try await f.keys.revoke(id: id); let revoked = try await f.post(rpc("ping"), credential: made["key"].string); XCTAssertEqual(revoked.status, 403)
        let fresh = try await key(f, level: "look"), origin = try await f.post(rpc("ping"), credential: fresh["key"].string, headers: ["origin": "https://evil.example"]), rebound = try await f.post(rpc("ping"), credential: fresh["key"].string, headers: ["host": "evil.example"]); XCTAssertEqual(origin.status, 403); XCTAssertEqual(rebound.status, 403); await f.stop()
    }
    func testKeyDoorL263() async throws { let f = try await fixture(), made = try await key(f, level: "look"), result = try await call(f, secret: made["key"].string, name: "tools_run", args: o([("name", .string("settings_write")), ("arguments", write)])); XCTAssertEqual(result["isError"], .bool(true)); XCTAssertTrue(text(result).contains("set to Look only")); XCTAssertTrue(f.rig.questions.get().isEmpty); XCTAssertEqual(f.rig.surface.settings["appearance.density"], .string("comfortable")); await f.stop() }
    func testKeyDoorL277() async throws {
        let f = try await fixture(approval: .hold), made = try await key(f, name: "ChatGPT"), id = try XCTUnwrap(made["view"]["id"].string), args = o([("name", .string("settings_write")), ("arguments", write)]), secret = made["key"].string
        let work = Task { try await self.call(f, secret: secret, name: "tools_run", args: args) }; await f.rig.asked.wait(1); let question = f.rig.questions.get()[0]
        XCTAssertEqual(question.origin, "key:" + id); XCTAssertTrue(question.label?.contains("“ChatGPT”") == true); XCTAssertEqual(question.askedBy, "ChatGPT"); XCTAssertFalse(question.summary.hasPrefix("From"))
        let phone = BackendCopilotRemoteWiring.consentQuestion(question); XCTAssertTrue(phone["summary"].string?.hasPrefix("From “ChatGPT”:") == true)
        XCTAssertLessThanOrEqual(question.expiresAt - question.requestedAt, 45_000)
        let may = await f.rig.consent.mayAnswer(id: question.id, by: "device:phone-1"), accepted = await f.rig.consent.respond(id: question.id, approved: true, by: "device:phone-1"); XCTAssertTrue(may); XCTAssertTrue(accepted)
        let result = try await work.value; XCTAssertNotEqual(result["isError"], .bool(true)); XCTAssertEqual(f.rig.surface.settings["appearance.density"], .string("compact")); await f.stop()
    }
    func testKeyDoorL304() async throws {
        let f = try await fixture(approval: .hold, timeout: 80), made = try await key(f), secret = made["key"].string, args = o([("name", .string("settings_write")), ("arguments", write)])
        let work = Task { try await self.call(f, secret: secret, name: "tools_run", args: args) }; await f.rig.clock.scheduled.wait(1); f.rig.clock.advance(80)
        let result = try await work.value; XCTAssertEqual(result["isError"], .bool(true)); XCTAssertTrue(text(result).contains("nobody answered")); XCTAssertTrue(text(result).contains("Nothing was changed")); XCTAssertEqual(f.rig.surface.settings["appearance.density"], .string("comfortable")); await f.stop()
    }
    func testKeyDoorL318() async throws { let f = try await fixture(), made = try await key(f), result = try await call(f, secret: made["key"].string, name: "tools_run", args: o([("name", .string("settings_write")), ("arguments", write)])); XCTAssertTrue(text(result).contains("nowhere to ask them")); await f.stop() }
    func testKeyDoorL329() async throws { let f = try await fixture(approval: .hold), made = try await key(f, name: "My server", extras: o([("askFirst", .bool(false))])), id = try XCTUnwrap(made["view"]["id"].string), result = try await call(f, secret: made["key"].string, name: "tools_run", args: o([("name", .string("settings_write")), ("arguments", write)])); XCTAssertNotEqual(result["isError"], .bool(true)); XCTAssertTrue(f.rig.questions.get().isEmpty); let rows = await f.rig.log.tail(5), row = try XCTUnwrap(rows.first { $0["tool"] == .string("settings.write") }); XCTAssertEqual(row["confirmed"]["required"], .bool(true)); XCTAssertEqual(row["confirmed"]["granted"], .bool(true)); XCTAssertEqual(row["confirmed"]["by"], .string("standing:key:" + id)); XCTAssertTrue(row["detail"].string?.contains("without asking") == true); XCTAssertFalse(row["detail"].string?.contains("allowed by the person") == true); await f.stop() }
    func testKeyDoorL345() async throws { let f = try await fixture(), made = try await key(f, extras: o([("askFirst", .bool(false))])), result = try await call(f, secret: made["key"].string, name: "tools_run", args: o([("name", .string("settings_write")), ("arguments", o([("scope", .string("settings")), ("patch", o([("remote.enabled", .bool(false))]))]))])); XCTAssertEqual(result["isError"], .bool(true)); XCTAssertEqual(f.rig.surface.settings["remote.enabled"], .missing); await f.stop() }
    func testKeyDoorL357() async throws {
        let f = try await fixture(), made = try await key(f, level: "work", extras: o([("folders", .array([.string("/work/site")]))])), refused = try await call(f, secret: made["key"].string, name: "sessions_start", args: o([("cwd", .string("/work/api"))]))
        XCTAssertEqual(refused["isError"], .bool(true)); XCTAssertTrue(text(refused).contains("may only start sessions in: /work/site")); XCTAssertTrue(f.rig.surface.starts.isEmpty)
        let started = try await call(f, secret: made["key"].string, name: "sessions_start", args: o([("cwd", .string("/work/site"))])); XCTAssertNotEqual(started["isError"], .bool(true)); XCTAssertEqual(f.rig.surface.starts.map { $0["cwd"].string }, ["/work/site"]); await f.stop()
    }
    func testKeyDoorL373() async throws { let f = try await fixture(budgets: .init(all: .init(limit: 3, windowMilliseconds: 60_000))), made = try await key(f, level: "look"); for _ in 0..<3 { _ = try await call(f, secret: made["key"].string, name: "sessions_list") }; let fourth = try await call(f, secret: made["key"].string, name: "sessions_list"); XCTAssertTrue(text(fourth).contains("too many tool calls")); let copilot = await f.rig.call("sessions.list"); XCTAssertTrue(copilot.ok); await f.stop() }
    func testKeyDoorL387() async throws {
        let f = try rig(), world = BackendDeckCoreTestPortSecurityPortWorld(), first = f.server(factory: world.factory)
        let endpoint = try await first.start(preferredPort: 0), wanted = endpoint.port; await first.stop()
        let again = f.server(factory: world.factory), fixed = try await again.start(preferredPort: wanted); XCTAssertEqual(fixed.port, wanted)
        let second = f.server(factory: world.factory), moved = try await second.start(preferredPort: wanted); XCTAssertNotEqual(moved.port, wanted); XCTAssertGreaterThan(moved.port, 0)
        await second.stop(); await again.stop()
    }
}
