import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// ai-apps-ipc.test.ts: the settings page's channels, against the real channel
/// registry and a real key store. The app's own window is the native caller
/// with the owner id; any other window is a page under another owner.
private struct BackendDeckCoreTestPortS1AIAppsRig: Sendable {
    static let owner = "owner"
    let keys: BackendDeckCoreSecurityAccessKeys
    let registry: NativeChannelRegistry
    let subscription: NativeRPCSubscription
    let pushes: NativeRPCSubscription
    let pushed: BackendDeckCoreTestPortSecuritySignal
    static func make(directory: URL, keys given: BackendDeckCoreSecurityAccessKeys? = nil, hub: BackendDeckCoreEventsHub? = nil,
                     events: BackendDeckCoreEvents? = nil, channelBridge: String? = nil) async throws -> Self {
        let keys = given ?? BackendDeckCoreSecurityAccessKeys(directory: directory.appendingPathComponent("remote"))
        let registry = NativeChannelRegistry(), pushed = BackendDeckCoreTestPortSecuritySignal()
        let page = BackendDeckCoreEventsAIApps(keys: keys, hub: hub, events: events, port: { 47821 }, movedFrom: { nil },
            relay: { BackendDeckCoreEventsRelayFacts(url: "wss://relay.example", hostId: "K7QZ2M4HXN9PRT3VWB6CJD8FGA", connected: true, reason: nil) },
            folders: { ["/work/api"] }, channelBridge: { channelBridge })
        let pushes = try await registry.subscribe(BackendDeckCoreEventsAIApps.changedChannel, ownerID: owner) { _ in pushed.signal() }
        let subscription = try await page.register(in: registry, ownerID: owner, isApprover: { $0.caller == .nativeApp && $0.ownerID == Self.owner })
        return Self(keys: keys, registry: registry, subscription: subscription, pushes: pushes, pushed: pushed)
    }
    func call(_ channel: String, own: Bool = true, _ arguments: NativeRPCValue...) async throws -> NativeRPCValue {
        let context = own ? NativeRPCContext(caller: .nativeApp, ownerID: Self.owner) : NativeRPCContext(caller: .page, ownerID: "other")
        return try await registry.invoke(channel, context: context, arguments: arguments)
    }
    func close() async { await subscription.cancelAndWait(); await pushes.cancelAndWait() }
}

private struct BackendDeckCoreTestPortS1AIAppsPost: Sendable { let url: String; let id: String }

final class BackendDeckCoreTestPortS1AIAppsTests: BackendDeckCoreTestPortSecurityCase {
    private func create(_ r: BackendDeckCoreTestPortS1AIAppsRig, name: String, level: String) async throws -> (value: V, id: String) {
        let value = try await r.call("ai-apps:create", o([("name", .string(name)), ("level", .string(level))]))
        let id = try XCTUnwrap(value["id"].string, value.compact)
        return (value, id)
    }

    // the AI apps channels
    func testAIAppsIPCL76() async throws {
        let r = try await BackendDeckCoreTestPortS1AIAppsRig.make(directory: try scratch())
        let (made, id) = try await create(r, name: "ChatGPT", level: "full")
        XCTAssertEqual(made["ok"], .bool(true))
        let key = try XCTUnwrap(made["key"].string)
        XCTAssertTrue(key.hasPrefix("ak_"))
        XCTAssertEqual(made["state"]["keys"].elements?.map { $0["id"] }, [.string(id)])
        let state = try await r.call("ai-apps:state")
        XCTAssertFalse(state.compact.contains(key))
        await r.close()
    }
    func testAIAppsIPCL90() async throws {
        let r = try await BackendDeckCoreTestPortS1AIAppsRig.make(directory: try scratch())
        let refused = try await r.call("ai-apps:create", o([("name", .string("")), ("level", .string("look"))]))
        XCTAssertEqual(refused["ok"], .bool(false))
        XCTAssertTrue(refused["message"].string?.contains("name") == true, refused["message"].compact)
        let revoked = try await r.call("ai-apps:revoke", .string("nope"))
        XCTAssertEqual(revoked["ok"], .bool(false))
        await r.close()
    }
    func testAIAppsIPCL98() async throws {
        let r = try await BackendDeckCoreTestPortS1AIAppsRig.make(directory: try scratch())
        let (_, id) = try await create(r, name: "A", level: "look")
        let level = try await r.call("ai-apps:level", .string(id), .string("work"))
        XCTAssertEqual(level["ok"], .bool(true))
        let changed = await r.keys.get(id: id)
        XCTAssertEqual(changed?["level"], .string("work"))
        let internet = try await r.call("ai-apps:internet", .bool(true))
        XCTAssertEqual(internet["ok"], .bool(true))
        XCTAssertEqual(internet["state"]["internet"]["on"], .bool(true))
        let revoked = try await r.call("ai-apps:revoke", .string(id))
        XCTAssertEqual(revoked["ok"], .bool(true))
        let gone = await r.keys.get(id: id)
        XCTAssertNil(gone)
        // create, level, internet and revoke each tell the window.
        await r.pushed.wait(4)
        XCTAssertGreaterThanOrEqual(r.pushed.value(), 4)
        await r.close()
    }
    func testAIAppsIPCL109() async throws {
        let r = try await BackendDeckCoreTestPortS1AIAppsRig.make(directory: try scratch())
        let state = try await r.call("ai-apps:state")
        XCTAssertEqual(state["internet"]["base"], .string("https://relay.example/mcp/K7QZ2M4HXN9PRT3VWB6CJD8FGA"))
        XCTAssertEqual(state["internet"]["relayHost"], .string("relay.example"))
        XCTAssertEqual(state["local"]["url"], .string("http://127.0.0.1:47821/mcp"))
        await r.close()
    }

    // the internet address
    func testAIAppsIPCL119() {
        XCTAssertEqual(BackendDeckCoreEventsAIApps.internetBase(relayUrl: "wss://relay.example", hostId: "HOST"), "https://relay.example/mcp/HOST")
        XCTAssertEqual(BackendDeckCoreEventsAIApps.internetBase(relayUrl: "wss://proxy.example/relay/", hostId: "HOST"), "https://proxy.example/relay/mcp/HOST")
        XCTAssertEqual(BackendDeckCoreEventsAIApps.internetBase(relayUrl: "ws://127.0.0.1:9000", hostId: "HOST"), "http://127.0.0.1:9000/mcp/HOST")
        XCTAssertNil(BackendDeckCoreEventsAIApps.internetBase(relayUrl: "wss://relay.example", hostId: ""))
        XCTAssertNil(BackendDeckCoreEventsAIApps.internetBase(relayUrl: "not a url", hostId: "HOST"))
    }

    // the notification channels
    func testAIAppsIPCL138() async throws {
        let r = try await BackendDeckCoreTestPortS1AIAppsRig.make(directory: try scratch())
        let (_, id) = try await create(r, name: "A", level: "work")
        let set = try await r.call("ai-apps:notify", .string(id), o([("mode", .string("webhook")), ("url", .string("https://hooks.example.com/x"))]))
        XCTAssertEqual(set["ok"], .bool(true))
        let secret = try XCTUnwrap(set["secret"].string, set.compact)
        XCTAssertTrue(secret.hasPrefix("whsec_"))
        XCTAssertFalse(set["state"].compact.contains(secret))
        assertValue(set["state"]["keys"].elements?.first?["notify"] ?? .missing,
                    o([("mode", .string("webhook")), ("url", .string("https://hooks.example.com/x")), ("hasSecret", .bool(true))]))
        let again = try await r.call("ai-apps:notify", .string(id), o([("mode", .string("webhook"))]))
        XCTAssertEqual(again["secret"], .null)
        let rotated = try await r.call("ai-apps:notify-secret", .string(id))
        XCTAssertNotNil(rotated["secret"].string)
        XCTAssertNotEqual(rotated["secret"].string, secret)
        await r.close()
    }
    func testAIAppsIPCL156() async throws {
        let r = try await BackendDeckCoreTestPortS1AIAppsRig.make(directory: try scratch())
        let (_, id) = try await create(r, name: "A", level: "work")
        let refused = try await r.call("ai-apps:notify", .string(id), o([("mode", .string("webhook")), ("url", .string("http://hooks.example.com/x"))]))
        XCTAssertEqual(refused["ok"], .bool(false))
        XCTAssertTrue(refused["message"].string?.contains("https") == true, refused["message"].compact)
        await r.close()
    }
    /// The source's fake notify service becomes the real queue: its settings
    /// read the key store, and its webhook post is a fake answering 204.
    func testAIAppsIPCL167() async throws {
        let directory = try scratch(), keys = BackendDeckCoreSecurityAccessKeys(directory: directory.appendingPathComponent("remote"))
        let clock = BackendDeckCoreTestPortSecurityClock(), changes = BackendDeckCoreTestPortSecuritySignal()
        let posts = BackendDeckCoreSecurityTestBox<[BackendDeckCoreTestPortS1AIAppsPost]>([])
        let hub = BackendDeckCoreEventsHub(settings: { await keys.notifySettings(id: $0) }, clock: clock, post: { url, headers, _ in
            posts.edit { $0.append(BackendDeckCoreTestPortS1AIAppsPost(url: url, id: headers["webhook-id"] ?? "")) }; return 204
        }, onChange: { changes.signal() })
        let r = try await BackendDeckCoreTestPortS1AIAppsRig.make(directory: directory, keys: keys, hub: hub, channelBridge: "/data/notify-channel.mjs")
        let (_, id) = try await create(r, name: "A", level: "work")
        let set = try await r.call("ai-apps:notify", .string(id), o([("mode", .string("webhook")), ("url", .string("https://hooks.example.com/x"))]))
        XCTAssertEqual(set["ok"], .bool(true))
        let queued = await hub.enqueue(keyId: id, event: BackendDeckCoreEventsTestFixture.event("n-1"))
        XCTAssertTrue(queued)
        await changes.wait(2)
        let state = try await r.call("ai-apps:state")
        XCTAssertEqual(state["delivery"][id]["state"], .string("delivered"))
        XCTAssertEqual(state["delivery"][id]["via"], .string("webhook"))
        XCTAssertEqual(state["channelBridge"], .string("/data/notify-channel.mjs"))
        let result = try await r.call("ai-apps:notify-test", .string(id))
        XCTAssertEqual(result["ok"], .bool(true))
        XCTAssertEqual(result["message"], .string("Delivered: the address answered 204."))
        let sent = posts.get()
        XCTAssertEqual(sent.map(\.url), ["https://hooks.example.com/x", "https://hooks.example.com/x"])
        XCTAssertEqual(sent.first?.id, "n-1")
        XCTAssertTrue(sent.last?.id.hasPrefix("test-") == true, sent.last?.id ?? "")
        await hub.stop(); await r.close()
    }
    /// The source's fake subscription list becomes the real events service,
    /// subscribed through its own verification against a fake callback.
    func testAIAppsIPCL188() async throws {
        let directory = try scratch(), keys = BackendDeckCoreSecurityAccessKeys(directory: directory.appendingPathComponent("remote"))
        let clock = BackendDeckCoreTestPortSecurityClock(), receiver = BackendDeckCoreEventsTestReceiver()
        let events = BackendDeckCoreEvents(mode: { await keys.notifySettings(id: $0)?["mode"].string }, internet: { await keys.internet() }, clock: clock,
            post: { url, headers, body in try await receiver.post(url, headers, body) })
        let r = try await BackendDeckCoreTestPortS1AIAppsRig.make(directory: directory, keys: keys, events: events)
        let (_, id) = try await create(r, name: "ChatGPT", level: "work")
        _ = try await events.subscribe(keyId: id, via: "this-mac", params: BackendDeckCoreEventsTestFixture.params(url: "https://callbacks.chatgpt.com/mcp/events/abc"))
        let state = try await r.call("ai-apps:state"), rows = state["subscriptions"][id].elements ?? []
        XCTAssertEqual(rows.count, 1, state["subscriptions"].compact)
        let subscription = try XCTUnwrap(rows.first?["id"].string)
        XCTAssertEqual(rows.first?["event"], .string("session.turn_finished"))
        XCTAssertEqual(rows.first?["host"], .string("callbacks.chatgpt.com"))
        XCTAssertFalse(state.compact.contains("whsec_"))
        let first = try await r.call("ai-apps:events-stop", .string(id), .string(subscription))
        XCTAssertEqual(first["ok"], .bool(true))
        assertValue(first["state"]["subscriptions"], .object([]))
        let again = try await r.call("ai-apps:events-stop", .string(id), .string(subscription))
        XCTAssertEqual(again["ok"], .bool(false))
        XCTAssertEqual(again["message"], .string("That subscription had already ended."))
        let left = await events.subscriptions()
        XCTAssertTrue(left.isEmpty)
        await events.stop(); await r.close()
    }
}
