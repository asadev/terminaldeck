import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// mcp-events-server.test.ts: ChatGPT's MCP Events end to end on this Mac — the
/// 2026-07-28 protocol in through the real loopback server and key door, a
/// signed push out. The receiver is the test's post function (the source's
/// liberty is the same: its poster carries the public callback to a local
/// receiver); the clock is the test's.
private let backendDeckCoreTestPortS1ServerCallback = "https://callbacks.example.com/mcp/events"
private let backendDeckCoreTestPortS1ServerSecret = "whsec_" + Data(repeating: 3, count: 32).base64EncodedString()

final class BackendDeckCoreTestPortS1EventsServerTests: BackendDeckCoreTestPortS1EventsCase {

    private func wired() async throws -> (Rig, BackendDeckCoreTestPortS1EventsReceiver, BackendDeckCoreEvents, BackendDeckCoreTestPortSecuritySignal) {
        let r = try await keyRig(at: 1_800_000_000_000), clock = r.clock
        let receiver = BackendDeckCoreTestPortS1EventsReceiver(now: { clock.now() }), changes = BackendDeckCoreTestPortSecuritySignal()
        return (r, receiver, r.attachEvents(receiver: receiver, changes: changes), changes)
    }
    private func delivery(url: String = backendDeckCoreTestPortS1ServerCallback) -> V {
        o([("mode", .string("webhook")), ("url", .string(url)), ("secret", .string(backendDeckCoreTestPortS1ServerSecret))])
    }

    // MARK: the 2026-07-28 era on this server

    func testMcpEventsServerL173() async throws {
        let (r, _, _, _) = try await wired()
        let a = try await r.key("ChatGPT")
        let (status, body) = try await modern(r, a.key, "server/discover", id: 1)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body["result"]["supportedVersions"].elements?.contains(.string("2026-07-28")) == true, body.compact)
        XCTAssertNotNil(body["result"]["capabilities"]["tools"].fields); XCTAssertNotNil(body["result"]["capabilities"]["events"].fields)
        XCTAssertTrue(body["result"]["instructions"].string?.contains("notifications_wait") == true)
        // A 2026-era client names itself on every request, not in an initialize.
        let view = await r.keys.get(id: a.id)
        XCTAssertEqual(view?["lastApp"], .string("openai-mcp 2.0.0"))
        await r.stop()
    }
    func testMcpEventsServerL184() async throws {
        let (r, _, _, _) = try await wired()
        let a = try await r.key("ChatGPT")
        let modernTools = try await modern(r, a.key, "tools/list", id: 1).body["result"]["tools"].elements?.compactMap { $0["name"].string } ?? []
        let initialized = try await legacy(r, a.key, "initialize", o([("protocolVersion", .string("2025-06-18")), ("capabilities", .object([])),
            ("clientInfo", o([("name", .string("claude-ai")), ("version", .string("1"))]))]), id: 2)
        _ = try await r.post(rpc("notifications/initialized", id: .missing), credential: a.key, extra: ["mcp-protocol-version": "2025-06-18"])
        let legacyTools = try await legacy(r, a.key, "tools/list", id: 3)["result"]["tools"].elements?.compactMap { $0["name"].string } ?? []
        XCTAssertEqual(modernTools, legacyTools)
        XCTAssertTrue(modernTools.contains("notifications_wait"))
        // The 2025 era is not shown the events capability: nothing there could use it.
        XCTAssertNotNil(initialized["result"]["capabilities"].fields)
        XCTAssertFalse(initialized["result"]["capabilities"].has("events"))
        await r.stop()
    }
    func testMcpEventsServerL204() async throws {
        let (r, _, _, _) = try await wired()
        let a = try await r.key("Cursor")
        let reply = try await r.post(rpc("initialize", params: o([("protocolVersion", .string("2025-06-18")), ("capabilities", .object([])),
            ("clientInfo", o([("name", .string("cursor")), ("version", .string("1"))]))])), credential: a.key)
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(reply.headers["content-type"]?.hasPrefix("application/json") == true)
        let body = try response(reply)
        XCTAssertEqual(body["result"]["protocolVersion"], .string("2025-06-18"))
        assertValue(body["result"]["capabilities"], o([("tools", .object([]))]))
        await r.stop()
    }
    func testMcpEventsServerL223() async throws {
        let (r, _, _, _) = try await wired()
        let token = r.endpoint.token
        let discover = try await modern(r, token, "server/discover", id: 1)
        XCTAssertNotNil(discover.body["result"]["capabilities"].fields)
        XCTAssertFalse(discover.body["result"]["capabilities"].has("events"))
        let list = try await modern(r, token, "events/list", id: 2)
        XCTAssertEqual(list.body["error"]["code"], .number(-32601))
        await r.stop()
    }
    func testMcpEventsServerL231() async throws {
        let (r, _, _, _) = try await wired()
        let a = try await r.key("App")
        let listen = try await modern(r, a.key, "subscriptions/listen", o([("notifications", o([("toolsListChanged", .bool(true))]))]), id: 1)
        XCTAssertEqual(listen.body["error"]["code"], .number(-32601))
        await r.stop()
    }

    // MARK: a session finishing, pushed to the app that started it

    func testMcpEventsServerL239() async throws {
        let (r, receiver, events, changes) = try await wired()
        let a = try await r.key("ChatGPT"), b = try await r.key("Another ChatGPT")

        let listed = try await modern(r, a.key, "events/list", id: 1)
        XCTAssertTrue(listed.body["result"]["events"].elements?.contains { $0["name"] == .string("session.turn_finished") } == true)

        let started = try await modern(r, a.key, "tools/call", o([("name", .string("sessions_start")), ("arguments", o([("cwd", .string("/work/api"))]))]), id: 2)
        XCTAssertEqual(started.body["error"], .missing)
        let sessionID = try XCTUnwrap(started.body["result"]["structuredContent"]["session"]["id"].string)
        XCTAssertNotEqual(sessionID, "")

        let subscribed = try await modern(r, a.key, "events/subscribe", o([("name", .string("session.turn_finished")), ("arguments", .object([])),
            ("delivery", delivery()), ("cursor", .null), ("ttlMs", .number(3_600_000))]), id: 3)
        XCTAssertEqual(subscribed.body["error"], .missing)
        let subscriptionID = subscribed.body["result"]["id"].string
        XCTAssertEqual(subscribed.body["result"]["cursor"], .null); XCTAssertEqual(subscribed.body["result"]["truncated"], .bool(false))
        // The other app subscribes to the same kind of news, at its own callback.
        let other = try await modern(r, b.key, "events/subscribe", o([("name", .string("session.turn_finished")),
            ("delivery", delivery(url: "https://callbacks.example.com/other"))]), id: 4)
        XCTAssertEqual(other.body["error"], .missing)
        XCTAssertEqual(receiver.posts().map { (try? NativeRPCValue.parseJSON(Data($0.body.utf8)))?["type"].string }, ["verification", "verification"])

        let pushed = changes.value()
        await r.detector.noteStatus(sessionId: sessionID, status: "working")
        await r.detector.noteStatus(sessionId: sessionID, status: "completed")
        await r.detector.awaitIdle()
        await changes.wait(pushed + 1); _ = await events.armed()

        let posts = receiver.posts()
        XCTAssertEqual(posts.count, 3)
        let push = try XCTUnwrap(posts.dropFirst(2).first), payload = try json(push.body)
        XCTAssertEqual(payload["name"], .string("session.turn_finished"))
        XCTAssertEqual(payload["data"]["sessionId"], .string(sessionID)); XCTAssertEqual(payload["data"]["type"], .string("finished"))
        XCTAssertEqual(push.headers["webhook-id"], payload["eventId"].string)
        XCTAssertEqual(push.headers[BackendDeckCoreEvents.subscriptionHeader], subscriptionID)
        XCTAssertNil(BackendDeckCoreEventsWebhook.verify(secret: backendDeckCoreTestPortS1ServerSecret, headers: push.headers, body: push.body, nowSeconds: floor(r.clock.now() / 1_000)))

        // The queue counts it delivered, by the push.
        let queued = await r.hub.list(keyId: a.id)
        XCTAssertEqual(queued.first?["delivery"], .string("delivered"))
        XCTAssertEqual(queued.first?["id"], payload["eventId"]); XCTAssertEqual(queued.first?["via"], .string("event"))
        // And the other app heard nothing about a session that is not its own.
        XCTAssertEqual(receiver.posts().count, 3)
        let theirs = await r.hub.list(keyId: b.id); XCTAssertTrue(theirs.isEmpty)

        // Unsubscribing is idempotent and stops it.
        let unsubscribe = o([("name", .string("session.turn_finished")), ("arguments", .object([])), ("delivery", o([("url", .string(backendDeckCoreTestPortS1ServerCallback))]))])
        let once = try await modern(r, a.key, "events/unsubscribe", unsubscribe, id: 5)
        XCTAssertNotNil(once.body["result"].fields)
        let twice = try await modern(r, a.key, "events/unsubscribe", unsubscribe, id: 6)
        XCTAssertEqual(twice.body["error"], .missing)
        let left = await events.subscriptions(keyId: a.id); XCTAssertTrue(left.isEmpty)
        await r.stop()
    }
    func testMcpEventsServerL296() async throws {
        let (r, receiver, _, _) = try await wired()
        let a = try await r.key("ChatGPT")
        _ = try await r.keys.setNotify(id: a.id, input: o([("mode", .string("off"))]))
        let refused = try await modern(r, a.key, "events/subscribe", o([("name", .string("session.turn_finished")), ("delivery", delivery())]), id: 1)
        XCTAssertEqual(refused.body["error"]["code"], .number(-32012))
        XCTAssertTrue(refused.body["error"]["message"].string?.contains("switched notifications off") == true, refused.body.compact)
        XCTAssertTrue(receiver.posts().isEmpty)
        await r.stop()
    }
}
