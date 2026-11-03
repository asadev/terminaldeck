import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct BackendDeckCoreTestPortSecurityHubFixture: Sendable {
    struct Post: Sendable { let url: String; let headers: [String: String]; let body: String; let at: Double }
    static let secret = "whsec_" + Data(repeating: 7, count: 32).base64EncodedString()
    let clock: BackendDeckCoreTestPortSecurityClock
    let settings: BackendDeckCoreSecurityTestBox<[String: NativeRPCValue]>
    let posts: BackendDeckCoreSecurityTestBox<[Post]>
    let statuses: BackendDeckCoreSecurityTestBox<[Int]>
    let changes: BackendDeckCoreTestPortSecuritySignal
    let hub: BackendDeckCoreEventsHub
    init(directory: URL? = nil, clock: BackendDeckCoreTestPortSecurityClock = .init(1_000_000), webhook: Bool = false, statuses: [Int] = [200], modes: [String: NativeRPCValue]? = nil) {
        let settings = BackendDeckCoreSecurityTestBox(modes ?? ["A": .object([.init("mode", .string(webhook ? "webhook" : "wait")), .init("url", webhook ? .string("https://hooks.example/x") : .null), .init("secret", webhook ? .string(Self.secret) : .null)]), "B": .object([.init("mode", .string("wait")), .init("url", .null), .init("secret", .null)])])
        let posts = BackendDeckCoreSecurityTestBox<[Post]>([]), responses = BackendDeckCoreSecurityTestBox(statuses), changes = BackendDeckCoreTestPortSecuritySignal()
        let hub = BackendDeckCoreEventsHub(directory: directory, settings: { settings.get()[$0] }, clock: clock, post: { url, headers, body in
            posts.edit { $0.append(Post(url: url, headers: headers, body: body, at: clock.now())) }
            let code = responses.get().first ?? 200; responses.edit { if $0.count > 1 { $0.removeFirst() } }; return code
        }, onChange: { changes.signal() })
        self.clock = clock; self.settings = settings; self.posts = posts; self.statuses = responses; self.changes = changes; self.hub = hub
    }
    func event(_ id: String = "n-1", session: String = "s1", at: Double? = nil, type: String = "finished") -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("type", .string(type)), .init("sessionId", .string(session)), .init("sessionName", .string(session)), .init("at", .number(at ?? clock.now())), .init("answer", .object([.init("text", .string("answer " + id)), .init("truncated", .bool(false))])), .init("suggestedTool", .string("sessions_send")), .init("note", .string("finished"))])
    }
}

final class BackendDeckCoreTestPortSecurityHub: BackendDeckCoreTestPortSecurityCase {
    func testNotifyHubL125() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(), a1 = f.event("a1", session: "a-session-1"), b1 = f.event("b1", session: "b-session-1"), a2 = f.event("a2", session: "a-session-2")
        _ = await f.hub.enqueue(keyId: "A", event: a1); _ = await f.hub.enqueue(keyId: "B", event: b1); _ = await f.hub.enqueue(keyId: "A", event: a2)
        let a = await f.hub.list(keyId: "A"), b = await f.hub.list(keyId: "B"), got = await f.hub.wait(keyId: "B", timeoutMs: 1000)
        XCTAssertEqual(a.map { $0["id"].string }, ["a1", "a2"]); XCTAssertEqual(b.map { $0["id"].string }, ["b1"]); XCTAssertEqual(got.map { $0["id"].string }, ["b1"])
        let wrong = await f.hub.ack(keyId: "B", ids: ["a1"]); assertValue(wrong, o([("acked", .array([])), ("alreadyGone", .array([.string("a1")]))])); let still = await f.hub.list(keyId: "A"); XCTAssertEqual(still.map { $0["id"].string }, ["a1", "a2"])
        let unknown = await f.hub.ack(keyId: "B", ids: ["nope"]); assertValue(unknown, o([("acked", .array([])), ("alreadyGone", .array([.string("nope")]))])); await f.hub.stop()
    }
    func testNotifyHubL143() async { let f = BackendDeckCoreTestPortSecurityHubFixture(); f.settings.edit { $0["A"] = .object([.init("mode", .string("off"))]) }; let off = await f.hub.enqueue(keyId: "A", event: f.event()), gone = await f.hub.enqueue(keyId: "Z", event: f.event()), size = await f.hub.size(); XCTAssertFalse(off); XCTAssertFalse(gone); XCTAssertEqual(size, 0); await f.hub.stop() }
    func testNotifyHubL151() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(); _ = await f.hub.enqueue(keyId: "A", event: f.event()); let scheduled = f.clock.scheduled.value()
        let parked = Task { await f.hub.wait(keyId: "B", timeoutMs: 10_000) }; await f.clock.scheduled.wait(scheduled + 1)
        f.settings.edit { $0["A"] = nil; $0["B"] = nil }; await f.hub.reconcile(); let size = await f.hub.size(keyId: "A"), result = await parked.value; XCTAssertEqual(size, 0); XCTAssertTrue(result.isEmpty); await f.hub.stop()
    }
    func testNotifyHubL164() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(), n = f.event(); let parked = Task { await f.hub.wait(keyId: "A", timeoutMs: 30_000) }; await f.clock.scheduled.wait(1)
        _ = await f.hub.enqueue(keyId: "A", event: n); let result = await parked.value, list = await f.hub.list(keyId: "A"); XCTAssertEqual(result.map { $0["id"] }, [n["id"]]); XCTAssertEqual(list[0]["delivery"], .string("delivered")); XCTAssertEqual(list[0]["via"], .string("wait")); await f.hub.stop()
    }
    func testNotifyHubL173() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(), parked = Task { await f.hub.wait(keyId: "A", timeoutMs: 45_000) }; await f.clock.scheduled.wait(1); _ = await f.hub.enqueue(keyId: "B", event: f.event()); f.clock.advance(45_000)
        let result = await parked.value; XCTAssertTrue(result.isEmpty); await f.hub.stop()
    }
    func testNotifyHubL181() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(), cancellation = BackendMCPCancellation(), parked = Task { await f.hub.wait(keyId: "A", timeoutMs: 45_000, cancellation: cancellation) }
        await f.clock.scheduled.wait(1); cancellation.cancel(); let empty = await parked.value; XCTAssertTrue(empty.isEmpty)
        let n = f.event(); _ = await f.hub.enqueue(keyId: "A", event: n); let got = await f.hub.wait(keyId: "A", timeoutMs: 1); XCTAssertEqual(got.map { $0["id"] }, [n["id"]]); await f.hub.stop()
    }
    func testNotifyHubL193() throws {
        let wait = try XCTUnwrap(BackendDeckCoreEventsToolDefinitions.all().first { $0["id"].string == "notifications.wait" }), property = wait["inputSchema"]["properties"]["timeoutSeconds"]["description"].string ?? ""
        XCTAssertTrue(property.contains("max 120") || property.contains("at most 120"))
        let maximumWait = 120_000, relayWait = 150_000; XCTAssertLessThan(maximumWait, relayWait); XCTAssertGreaterThanOrEqual(relayWait - maximumWait, 20_000)
    }
    func testNotifyHubL200() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(), n = f.event(); _ = await f.hub.enqueue(keyId: "A", event: n); let got = await f.hub.wait(keyId: "A", timeoutMs: 1), id = got[0]["id"].string ?? ""
        let first = await f.hub.ack(keyId: "A", ids: [id]), second = await f.hub.ack(keyId: "A", ids: [id]), list = await f.hub.list(keyId: "A")
        assertValue(first, o([("acked", .array([n["id"]])), ("alreadyGone", .array([]))])); assertValue(second, o([("acked", .array([])), ("alreadyGone", .array([n["id"]]))])); XCTAssertTrue(list.isEmpty); await f.hub.stop()
    }
    func testNotifyHubL210() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(); _ = await f.hub.enqueue(keyId: "A", event: f.event()); let first = await f.hub.wait(keyId: "A", timeoutMs: 1); XCTAssertEqual(first.count, 1)
        let scheduled = f.clock.scheduled.value(), second = Task { await f.hub.wait(keyId: "A", timeoutMs: 1) }; await f.clock.scheduled.wait(scheduled + 1); f.clock.advance(1)
        let empty = await second.value, list = await f.hub.list(keyId: "A"); XCTAssertTrue(empty.isEmpty); XCTAssertEqual(list.count, 1); await f.hub.stop()
    }
    func testNotifyHubL221() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(), n = f.event(), id = n["id"].string ?? ""; _ = await f.hub.enqueue(keyId: "A", event: n)
        let wrong = await f.hub.deliveredBy(keyId: "B", id: id, via: "event"), right = await f.hub.deliveredBy(keyId: "A", id: id, via: "event"), twice = await f.hub.deliveredBy(keyId: "A", id: id, via: "event")
        XCTAssertFalse(wrong); XCTAssertTrue(right); XCTAssertFalse(twice); let list = await f.hub.list(keyId: "A"), last = await f.hub.lastDelivery(keyId: "A")
        XCTAssertEqual(list[0]["id"], n["id"]); XCTAssertEqual(list[0]["delivery"], .string("delivered")); XCTAssertEqual(list[0]["via"], .string("event")); XCTAssertEqual(last?["state"], .string("delivered")); XCTAssertEqual(last?["via"], .string("event"))
        let scheduled = f.clock.scheduled.value(), waiting = Task { await f.hub.wait(keyId: "A", timeoutMs: 1) }; await f.clock.scheduled.wait(scheduled + 1); f.clock.advance(1); let empty = await waiting.value, armed = await f.hub.armed(); XCTAssertTrue(empty.isEmpty); XCTAssertFalse(armed); await f.hub.stop()
    }
    func testNotifyHubL238() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(webhook: true, statuses: [503]), start = f.clock.now(); _ = await f.hub.enqueue(keyId: "A", event: f.event()); await f.changes.wait(2)
        for (index, delay) in [5000.0, 30_000, 120_000].enumerated() { f.clock.advance(delay); await f.changes.wait(index + 3) }
        f.clock.advance(600_000 - 155_000); XCTAssertEqual(f.posts.get().map { $0.at - start }, [0, 5000, 35_000, 155_000]); XCTAssertEqual(BackendDeckCoreEventsSupport.retryDelays, [5000, 30_000, 120_000])
        let list = await f.hub.list(keyId: "A"), last = await f.hub.lastDelivery(keyId: "A"); XCTAssertEqual(list[0]["delivery"], .string("undelivered")); XCTAssertEqual(last?["state"], .string("undelivered")); XCTAssertEqual(last?["outstanding"], .number(1)); XCTAssertEqual(f.clock.pending(), 0)
        let fallback = await f.hub.wait(keyId: "A", timeoutMs: 1); XCTAssertEqual(fallback.count, 1); await f.hub.stop()
    }
    func testNotifyHubL266() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(webhook: true, statuses: [500, 204]); _ = await f.hub.enqueue(keyId: "A", event: f.event()); await f.changes.wait(2); f.clock.advance(5000); await f.changes.wait(3); f.clock.advance(600_000)
        XCTAssertEqual(f.posts.get().count, 2); let list = await f.hub.list(keyId: "A"); XCTAssertEqual(list[0]["delivery"], .string("delivered")); XCTAssertEqual(list[0]["via"], .string("webhook")); await f.hub.stop()
    }
    func testNotifyHubL282() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(), initial = await f.hub.armed(); XCTAssertFalse(initial)
        _ = await f.hub.enqueue(keyId: "A", event: f.event("a1")); _ = await f.hub.enqueue(keyId: "A", event: f.event("a2")); _ = await f.hub.enqueue(keyId: "B", event: f.event("b1")); XCTAssertEqual(f.clock.pending(), 1)
        _ = await f.hub.wait(keyId: "A", timeoutMs: 1); _ = await f.hub.wait(keyId: "B", timeoutMs: 1); let armed = await f.hub.armed(); XCTAssertFalse(armed); await f.hub.stop()
    }
    func testNotifyHubL297() async throws {
        let dir = try scratch(), first = BackendDeckCoreTestPortSecurityHubFixture(directory: dir), kept = first.event("kept"), delivered = first.event("delivered")
        _ = await first.hub.enqueue(keyId: "A", event: kept); _ = await first.hub.enqueue(keyId: "B", event: delivered); _ = await first.hub.wait(keyId: "B", timeoutMs: 1); await first.hub.stop()
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(BackendDeckCoreEventsHub.fileName).path)[.posixPermissions] as? NSNumber; XCTAssertEqual(mode?.intValue, 0o600)
        let second = BackendDeckCoreTestPortSecurityHubFixture(directory: dir, clock: first.clock, modes: first.settings.get()); await second.hub.load()
        let a = await second.hub.list(keyId: "A"), b = await second.hub.list(keyId: "B"); XCTAssertEqual(a.map { $0["id"] }, [kept["id"]]); XCTAssertEqual(b[0]["id"], delivered["id"]); XCTAssertEqual(b[0]["delivery"], .string("delivered"))
        let got = await second.hub.wait(keyId: "A", timeoutMs: 1); XCTAssertEqual(got.map { $0["id"] }, [kept["id"]]); await second.hub.stop()
    }
    func testNotifyHubL315() async throws {
        let dir = try scratch(), first = BackendDeckCoreTestPortSecurityHubFixture(directory: dir)
        let one = await first.hub.enqueue(keyId: "A", event: first.event("one", session: "s"), turn: "answer:1:abc"), duplicate = await first.hub.enqueue(keyId: "A", event: first.event("two", session: "s"), turn: "answer:1:abc"), crossKey = await first.hub.enqueue(keyId: "B", event: first.event("three", session: "s"), turn: "answer:1:abc"), fresh = await first.hub.enqueue(keyId: "A", event: first.event("four", session: "s"), turn: "answer:2:def")
        XCTAssertTrue(one); XCTAssertFalse(duplicate); XCTAssertFalse(crossKey); XCTAssertTrue(fresh); let list = await first.hub.list(keyId: "A"); _ = await first.hub.ack(keyId: "A", ids: list.compactMap { $0["id"].string }); await first.hub.stop()
        let second = BackendDeckCoreTestPortSecurityHubFixture(directory: dir, clock: first.clock, modes: first.settings.get()); await second.hub.load(); let repeated = await second.hub.enqueue(keyId: "A", event: second.event(), turn: "answer:1:abc"); XCTAssertFalse(repeated); await second.hub.stop()
        first.clock.advance(BackendDeckCoreEventsHub.maximumAge + 1); let third = BackendDeckCoreTestPortSecurityHubFixture(directory: dir, clock: first.clock, modes: first.settings.get()); await third.hub.load(); let forgotten = await third.hub.enqueue(keyId: "A", event: third.event(at: first.clock.now()), turn: "answer:1:abc"); XCTAssertTrue(forgotten); await third.hub.stop()
    }
    func testNotifyHubL336() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(); for index in 1...205 { _ = await f.hub.enqueue(keyId: "A", event: f.event("n-\(index)")) }
        let count = await f.hub.size(keyId: "A"), list = await f.hub.list(keyId: "A"); XCTAssertEqual(count, 200); XCTAssertNotEqual(list[0]["id"], .string("n-1")); _ = await f.hub.enqueue(keyId: "B", event: f.event("old", at: f.clock.now() - BackendDeckCoreEventsHub.maximumAge - 1)); let old = await f.hub.size(keyId: "B"); XCTAssertEqual(old, 0); await f.hub.stop()
    }
    func testNotifyHubL369() async throws {
        let f = BackendDeckCoreTestPortSecurityHubFixture(webhook: true), n = f.event(); _ = await f.hub.enqueue(keyId: "A", event: n); await f.changes.wait(2)
        let posts = f.posts.get(); XCTAssertEqual(posts.count, 1); let post = posts[0]; XCTAssertNil(BackendDeckCoreEventsWebhook.verify(secret: BackendDeckCoreTestPortSecurityHubFixture.secret, headers: post.headers, body: post.body, nowSeconds: floor(f.clock.now() / 1000)))
        let body = try json(post.body); XCTAssertEqual(body["id"], n["id"]); XCTAssertEqual(body["type"], .string("finished")); XCTAssertEqual(body["sessionId"], n["sessionId"]); XCTAssertEqual(post.headers["webhook-id"], n["id"].string)
        let list = await f.hub.list(keyId: "A"); XCTAssertEqual(list[0]["delivery"], .string("delivered")); XCTAssertEqual(list[0]["via"], .string("webhook")); await f.hub.stop()
    }
    func testNotifyHubL389() async {
        let f = BackendDeckCoreTestPortSecurityHubFixture(webhook: true); _ = await f.hub.enqueue(keyId: "A", event: f.event()); await f.changes.wait(2)
        let post = f.posts.get()[0], stamp = Double(post.headers["webhook-timestamp"] ?? "0") ?? 0, secret = BackendDeckCoreTestPortSecurityHubFixture.secret
        XCTAssertNil(BackendDeckCoreEventsWebhook.verify(secret: secret, headers: post.headers, body: post.body, nowSeconds: stamp))
        XCTAssertEqual(BackendDeckCoreEventsWebhook.verify(secret: BackendDeckCoreEventsTestFixture.otherSecret, headers: post.headers, body: post.body, nowSeconds: stamp), "mismatch")
        XCTAssertEqual(BackendDeckCoreEventsWebhook.verify(secret: secret, headers: post.headers, body: post.body + " ", nowSeconds: stamp), "mismatch")
        XCTAssertEqual(BackendDeckCoreEventsWebhook.verify(secret: secret, headers: post.headers, body: post.body, nowSeconds: stamp + 301), "stale")
        var missing = post.headers; missing["webhook-signature"] = nil; XCTAssertEqual(BackendDeckCoreEventsWebhook.verify(secret: secret, headers: missing, body: post.body, nowSeconds: stamp), "missing"); await f.hub.stop()
    }
    func testNotifyHubL408() async { let f = BackendDeckCoreTestPortSecurityHubFixture(webhook: true, statuses: [500]), result = await f.hub.testWebhook(keyId: "A"), count = await f.hub.size(); XCTAssertEqual(result["ok"], .bool(false)); XCTAssertTrue(result["message"].string?.contains("answered 500") == true); XCTAssertEqual(f.posts.get().count, 1); XCTAssertEqual(count, 0); await f.hub.stop() }
}
