import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// mcp-events.test.ts: MCP Events held to OpenAI's guide and the draft, on a
/// clock the test moves and a callback the test plays. Waits are signals from
/// the events' own onChange (a delivery attempt finished) followed by one call
/// into the actor, so the work that follows onChange in the same turn is done.
final class BackendDeckCoreTestPortS1EventsTests: BackendDeckCoreTestPortS1EventsCase {
    private typealias W = BackendDeckCoreTestPortS1EventsWorld

    private func params(_ extra: [(String, V)] = [], delivery: [(String, V)] = []) -> V {
        var target = o([("mode", .string("webhook")), ("url", .string(W.urlA)), ("secret", .string(W.secret))])
        for (key, value) in delivery { target = target.setting(key, value) }
        var value = o([("name", .string("session.turn_finished")), ("arguments", .object([])), ("delivery", target), ("cursor", .null)])
        for (key, value2) in extra { value = value.setting(key, value2) }
        return value
    }
    private func news(_ overrides: [(String, V)] = []) -> V {
        var value = o([("id", .string("n-" + String(UUID().uuidString.lowercased().prefix(10)))), ("type", .string("finished")), ("sessionId", .string("started-1")),
            ("sessionName", .string("api")), ("at", .number(1_800_000_000_000)), ("answer", o([("text", .string("Done: the tests pass.")), ("truncated", .bool(false))])),
            ("suggestedTool", .string("sessions_send")), ("note", .string("The session finished its turn."))])
        for (key, override) in overrides { value = value.setting(key, override) }
        return value
    }
    private func refusal(_ work: () async throws -> V, file: StaticString = #filePath, line: UInt = #line) async -> BackendDeckCoreEventsError? {
        do { _ = try await work(); XCTFail("expected a refusal", file: file, line: line); return nil }
        catch let error as BackendDeckCoreEventsError { return error }
        catch { XCTFail("wrong error \(error)", file: file, line: line); return nil }
    }
    private func subscribe(_ h: W.Instance, _ input: V, key: String = "key-a", via: String = "internet") async throws -> V {
        try await h.events.subscribe(keyId: key, via: via, params: input)
    }
    /// offer(), then every delivery it queued has been tried once.
    private func offered(_ h: W.Instance, _ event: V, key: String = "key-a") async -> Int {
        let mark = h.changes.value()
        let count = await h.events.offer(keyId: key, event: event)
        if count > 0 { await h.changes.wait(mark + count); _ = await h.events.armed() }
        return count
    }
    /// clock.advance(ms), then `tries` retries it fired have been tried.
    private func advance(_ w: W, _ h: W.Instance, _ milliseconds: Double, tries: Int) async {
        let mark = h.changes.value()
        w.clock.advance(milliseconds)
        if tries > 0 { await h.changes.wait(mark + tries); _ = await h.events.armed() }
    }
    private func verify(_ secret: String, _ post: BackendDeckCoreTestPortS1EventsReceiver.Post, _ w: W) -> String? {
        BackendDeckCoreEventsWebhook.verify(secret: secret, headers: post.headers, body: post.body, nowSeconds: floor(w.clock.now() / 1_000))
    }

    // MARK: events/list

    func testMcpEventsL184() async {
        let w = W(), h = w.instance()
        let listed = await h.events.list(), entries = listed["events"].elements ?? []
        XCTAssertEqual(entries.map { $0["name"].string }, ["session.turn_finished", "session.needs_input", "session.exited",
            "task.blocked", "task.finished", "task.needs_reply", "task.progress", "task.question", "task.started"])
        for entry in entries {
            XCTAssertEqual(entry["delivery"], .array([.string("webhook")]))
            XCTAssertEqual(entry["inputSchema"]["type"], .string("object"))
            XCTAssertEqual(entry["inputSchema"]["properties"]["sessionId"]["type"], .string("string"))
            XCTAssertEqual(entry["payloadSchema"]["type"], .string("object"))
            let required = entry["payloadSchema"]["required"].elements?.compactMap(\.string) ?? []
            XCTAssertTrue(required.contains("sessionId")); XCTAssertTrue(required.contains("type"))
            XCTAssertNotNil(entry["description"].string)
        }
        await h.events.stop()
    }

    // MARK: events/subscribe: what is refused, with the draft’s codes

    func testMcpEventsL197() async {
        let w = W(), h = w.instance()
        let short = "whsec_" + Data(count: 8).base64EncodedString(), long = "whsec_" + Data(count: 80).base64EncodedString()
        let cases: [(V, Int, V?)] = [
            (params([("name", .string("session.deleted"))]), -32011, o([("kind", .string("event"))])),
            (params([("arguments", o([("project", .string("/work"))]))]), -32602, nil),
            (params(delivery: [("mode", .string("poll"))]), -32014, o([("feature", .string("delivery")), ("value", .string("poll"))])),
            (params(delivery: [("url", .string("http://callbacks.example.com/x"))]), -32602, nil),
            (params(delivery: [("url", .string("https://127.0.0.1/x"))]), -32602, nil),
            (params(delivery: [("url", .string("https://192.168.1.10/x"))]), -32602, nil),
            (params(delivery: [("url", .string("https://printer.local/x"))]), -32602, nil),
            (params(delivery: [("url", .string("https://user:pw@callbacks.example.com/x"))]), -32602, nil),
            (params(delivery: [("secret", .string("not-a-secret"))]), -32602, nil),
            (params(delivery: [("secret", .string(short))]), -32602, nil),
            (params(delivery: [("secret", .string(long))]), -32602, nil)
        ]
        for (input, code, data) in cases {
            let error = await refusal { try await self.subscribe(h, input) }
            XCTAssertEqual(error?.code, code, input.compact)
            for field in data?.fields ?? [] { XCTAssertEqual(error?.data[field.key], field.value, input.compact) }
        }
        XCTAssertTrue(w.receiver.posts().isEmpty)
        let live = await h.events.subscriptions(); XCTAssertTrue(live.isEmpty)
        await h.events.stop()
    }
    func testMcpEventsL221() async {
        let w = W(), h = w.instance()
        w.modes.edit { $0["key-a"] = "off" }
        let off = await refusal { try await self.subscribe(h, self.params()) }
        XCTAssertEqual(off?.code, -32012); XCTAssertTrue(off?.message.contains("switched notifications off") == true, off?.message ?? "")
        let gone = await refusal { try await self.subscribe(h, self.params(), key: "key-gone") }
        XCTAssertEqual(gone?.code, -32012)
        await h.events.stop()
    }
    func testMcpEventsL231() async throws {
        let w = W(), h = w.instance(), maximum = BackendDeckCoreEvents.maximumSubscriptionsPerKey
        for index in 0..<maximum { _ = try await subscribe(h, params([("arguments", o([("sessionId", .string("s-\(index)"))]))])) }
        let full = await refusal { try await self.subscribe(h, self.params([("arguments", self.o([("sessionId", .string("one-more"))]))])) }
        XCTAssertEqual(full?.code, -32013)
        XCTAssertEqual(full?.data["limit"], .string("subscriptions")); XCTAssertEqual(full?.data["max"], .number(Double(maximum)))
        // Another app is not counted against this one.
        let theirs = try await subscribe(h, params(), key: "key-b")
        XCTAssertNotNil(theirs["id"].string)
        await h.events.stop()
    }

    // MARK: events/subscribe: the callback is verified before anything is sent to it

    func testMcpEventsL245() async throws {
        let w = W(), h = w.instance()
        let result = try await subscribe(h, params())
        let id = BackendDeckCoreEvents.subscriptionId(keyId: "key-a", url: W.urlA, name: "session.turn_finished", sessionId: nil)
        assertValue(result, o([("id", .string(id)), ("refreshBefore", .string(iso(w.clock.now() + BackendDeckCoreEvents.maximumTTL))), ("cursor", .null), ("truncated", .bool(false))]))
        let challenge = try XCTUnwrap(w.receiver.verifications().first)
        XCTAssertEqual(challenge.url, W.urlA)
        XCTAssertEqual(challenge.headers[BackendDeckCoreEvents.subscriptionHeader], result["id"].string)
        XCTAssertTrue(challenge.headers["webhook-id"]?.hasPrefix("msg_verification_") == true)
        XCTAssertNil(verify(W.secret, challenge, w))
        let mine = await h.events.subscriptions(keyId: "key-a"); XCTAssertEqual(mine.count, 1)
        await h.events.stop()
    }
    func testMcpEventsL262() async {
        let w = W(), h = w.instance()
        let reasons: [(BackendDeckCoreTestPortS1EventsReceiver.Verification, String)] = [(.wrong, "challenge_failed"), (.status(404), "http_4xx"), (.status(503), "http_5xx"), (.unreachable, "connection_refused")]
        for (verification, reason) in reasons {
            w.receiver.verification = verification
            let error = await refusal { try await self.subscribe(h, self.params()) }
            XCTAssertEqual(error?.code, -32015, reason)
            if let error { assertValue(error.data, o([("reason", .string(reason))])) }
        }
        let live = await h.events.subscriptions(); XCTAssertTrue(live.isEmpty)
        await h.events.stop()
    }

    // MARK: events/subscribe: an idempotent upsert with a lease

    func testMcpEventsL281() async throws {
        let w = W(), h = w.instance()
        let first = try await subscribe(h, params())
        w.clock.advance(60_000)
        let again = try await subscribe(h, params())
        XCTAssertEqual(again["id"], first["id"])
        XCTAssertEqual(again["refreshBefore"], .string(iso(w.clock.now() + BackendDeckCoreEvents.maximumTTL)))
        XCTAssertEqual(w.receiver.verifications().count, 1)
        let other = try await subscribe(h, params([("name", .string("session.needs_input"))]))
        XCTAssertNotEqual(other["id"], first["id"])
        // The same subscription made by another app is that app's own.
        let theirs = try await subscribe(h, params(), key: "key-b")
        XCTAssertNotEqual(theirs["id"], first["id"])
        await h.events.stop()
    }
    func testMcpEventsL296() async throws {
        let w = W(), h = w.instance()
        let short = try await subscribe(h, params([("ttlMs", .number(10))]))
        XCTAssertEqual(short["refreshBefore"], .string(iso(w.clock.now() + BackendDeckCoreEvents.minimumTTL)))
        let forever = try await subscribe(h, params([("name", .string("session.exited")), ("ttlMs", .null)]))
        XCTAssertEqual(forever["refreshBefore"], .string(iso(w.clock.now() + BackendDeckCoreEvents.maximumTTL)))
        let three = try await subscribe(h, params([("name", .string("session.needs_input")), ("ttlMs", .number(3 * 3_600_000))]))
        XCTAssertEqual(three["refreshBefore"], .string(iso(w.clock.now() + 3 * 3_600_000)))

        w.clock.advance(BackendDeckCoreEvents.minimumTTL + 1)
        let count = await h.events.offer(keyId: "key-a", event: news()); XCTAssertEqual(count, 0)
        let left = await h.events.subscriptions(keyId: "key-a")
        XCTAssertEqual(left.map { $0["event"].string }, ["session.exited", "session.needs_input"])
        await h.events.stop()
    }
    func testMcpEventsL310() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        _ = try await subscribe(h, params(delivery: [("secret", .string(W.secret2))]))
        _ = await offered(h, news())
        let during = try XCTUnwrap(w.receiver.deliveries().first)
        XCTAssertEqual(during.headers["webhook-signature"]?.split(separator: " ").count, 2)
        XCTAssertNil(verify(W.secret, during, w)); XCTAssertNil(verify(W.secret2, during, w))

        w.clock.advance(BackendDeckCoreEvents.rotationGrace + 1)
        _ = await offered(h, news())
        let after = try XCTUnwrap(w.receiver.deliveries().dropFirst().first)
        XCTAssertEqual(after.headers["webhook-signature"]?.split(separator: " ").count, 1)
        XCTAssertNil(verify(W.secret2, after, w))
        XCTAssertEqual(verify(W.secret, after, w), "mismatch")
        await h.events.stop()
    }

    // MARK: delivery

    func testMcpEventsL333() async throws {
        let w = W(), h = w.instance()
        let sub = try await subscribe(h, params())
        let event = news()
        let count = await offered(h, event); XCTAssertEqual(count, 1)
        let post = try XCTUnwrap(w.receiver.deliveries().first)
        assertValue(try json(post.body), o([("eventId", event["id"]), ("name", .string("session.turn_finished")),
            ("timestamp", .string(iso(event["at"].number ?? 0))), ("data", event), ("cursor", .null)]))
        XCTAssertEqual(post.headers["webhook-id"], event["id"].string)
        XCTAssertEqual(post.headers[BackendDeckCoreEvents.subscriptionHeader], sub["id"].string)
        XCTAssertNil(verify(W.secret, post, w))
        XCTAssertEqual(w.delivered.get(), [["key-a", event["id"].string ?? ""]])
        let owed = await h.events.owed(), armed = await h.events.armed()
        XCTAssertEqual(owed, 0); XCTAssertFalse(armed)
        await h.events.stop()
    }
    func testMcpEventsL355() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        _ = try await subscribe(h, params([("name", .string("session.needs_input")), ("arguments", o([("sessionId", .string("started-2"))]))]))
        _ = try await subscribe(h, params(delivery: [("url", .string("https://other.example.com/cb"))]), key: "key-b")

        let one = await offered(h, news([("type", .string("needs-input")), ("sessionId", .string("started-1"))]))
        let two = await offered(h, news([("type", .string("needs-input")), ("sessionId", .string("started-2"))]))
        let three = await offered(h, news([("type", .string("exited"))]))
        let four = await offered(h, news([("type", .string("finished"))]))
        XCTAssertEqual([one, two, three, four], [0, 1, 0, 1])
        let urls = w.receiver.deliveries().map(\.url)
        XCTAssertEqual(urls, [W.urlA, W.urlA])
        XCTAssertFalse(urls.contains("https://other.example.com/cb"))
        await h.events.stop()
    }
    func testMcpEventsL371() async throws {
        let w = W(), h = w.instance()
        let chatOne = "https://callbacks.example.com/chat-one", chatTwo = "https://callbacks.example.com/chat-two", catchAll = "https://callbacks.example.com/chat-three"
        _ = try await subscribe(h, params([("arguments", o([("sessionId", .string("started-1"))]))], delivery: [("url", .string(chatOne))]))
        _ = try await subscribe(h, params([("arguments", o([("sessionId", .string("started-2"))]))], delivery: [("url", .string(chatTwo))]))
        _ = try await subscribe(h, params(delivery: [("url", .string(catchAll))]))

        let one = await offered(h, news([("sessionId", .string("started-1"))]))
        let two = await offered(h, news([("sessionId", .string("started-2"))]))
        // A session no chat claimed goes to the catch-all.
        let three = await offered(h, news([("sessionId", .string("started-3"))]))
        XCTAssertEqual([one, two, three], [1, 1, 1])
        XCTAssertEqual(w.receiver.deliveries().map(\.url), [chatOne, chatTwo, catchAll])
        await h.events.stop()
    }
    func testMcpEventsL388() async throws {
        let w = W(), owedIDs = BackendDeckCoreSecurityTestBox<Set<String>>([])
        let h = w.instance(owed: { _, id in owedIDs.get().contains(id) })
        _ = try await subscribe(h, params())
        // Taken by a waiter before the push was offered: nothing is posted
        // (offer() asks the queue before it posts, inside the call).
        _ = await h.events.offer(keyId: "key-a", event: news())
        XCTAssertEqual(w.receiver.deliveries().count, 0)
        let none = await h.events.owed(); XCTAssertEqual(none, 0)

        // Taken by a waiter between the first try and the retry: the retry is not posted.
        w.receiver.statuses = [503]
        let event = news(), id = event["id"].string ?? ""
        owedIDs.edit { _ = $0.insert(id) }
        _ = await offered(h, event)
        XCTAssertEqual(w.receiver.deliveries().count, 1)
        let owing = await h.events.owes(keyId: "key-a", eventId: id); XCTAssertTrue(owing)
        owedIDs.edit { _ = $0.remove(id) }
        w.clock.advance(5_000)
        // Barrier: one more notification the queue has also delivered another way.
        // Its offer runs every due retry before it returns, and by the rule under
        // test posts nothing itself, so whatever the fired retry did is done.
        _ = await h.events.offer(keyId: "key-a", event: news())
        XCTAssertEqual(w.receiver.deliveries().count, 1)
        let still = await h.events.owes(keyId: "key-a", eventId: id), armed = await h.events.armed()
        XCTAssertFalse(still); XCTAssertFalse(armed)
        await h.events.stop()
    }
    func testMcpEventsL414() async throws {
        let w = W(), hubChanges = BackendDeckCoreTestPortSecuritySignal()
        let settings = o([("mode", .string("wait")), ("url", .null), ("secret", .null)])
        let queue = BackendDeckCoreEventsHub(settings: { _ in settings }, clock: w.clock, onChange: { hubChanges.signal() })
        let h = w.instance(owed: { await queue.owes(keyId: $0, id: $1) }, onDelivered: { _ = await queue.deliveredBy(keyId: $0, id: $1, via: "event") })
        let events = h.events
        await queue.setPushing { await events.owes(keyId: $0, eventId: $1) }
        func enqueue(_ event: V) async {
            if await queue.enqueue(keyId: "key-a", event: event) { _ = await events.offer(keyId: "key-a", event: event) }
        }
        _ = try await subscribe(h, params())

        // A waiter already parked takes it; the push stands down.
        let parkedMark = w.clock.scheduled.value()
        let parked = Task { await queue.wait(keyId: "key-a", timeoutMs: 30_000) }
        await w.clock.scheduled.wait(parkedMark + 1)
        let first = news()
        await enqueue(first)
        let taken = await parked.value
        XCTAssertEqual(taken.map { $0["id"] }, [first["id"]])
        XCTAssertEqual(w.receiver.deliveries().count, 0)

        // Nobody waiting: the push is tried, and a waiter arriving while it is
        // still being retried is not handed it as well. The retry's post is held
        // until the queue's own retry (due at the same instant) has run, the order
        // the source's single-threaded clock gives.
        w.receiver.statuses = [503, 200]; w.receiver.hold(delivery: 2)
        let second = news(), firstTry = h.changes.value()
        await enqueue(second)
        await h.changes.wait(firstTry + 1); _ = await events.armed()
        XCTAssertEqual(w.receiver.deliveries().count, 1)
        let lateMark = w.clock.scheduled.value()
        let late = Task { await queue.wait(keyId: "key-a", timeoutMs: 60_000) }
        await w.clock.scheduled.wait(lateMark + 1)
        let hubMark = hubChanges.value(), retryMark = h.changes.value()
        w.clock.advance(5_000)
        await hubChanges.wait(hubMark + 1); await w.receiver.delivered.wait(2)
        w.receiver.release()
        await h.changes.wait(retryMark + 1); _ = await events.armed()
        XCTAssertEqual(w.receiver.deliveries().count, 2)
        let listed = await queue.list(keyId: "key-a"), row = listed.first { $0["id"] == second["id"] }
        XCTAssertEqual(row?["delivery"], .string("delivered")); XCTAssertEqual(row?["via"], .string("event"))
        w.clock.advance(60_000)
        let nothing = await late.value
        XCTAssertTrue(nothing.isEmpty)
        await queue.stop(); await events.stop()
    }
    func testMcpEventsL457() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        let event = news(), mark = h.changes.value()
        let once = await h.events.offer(keyId: "key-a", event: event), twice = await h.events.offer(keyId: "key-a", event: event)
        await h.changes.wait(mark + 1); _ = await h.events.armed()
        let thrice = await h.events.offer(keyId: "key-a", event: event)
        // offer() queues synchronously and posts later, so "posted once" is also
        // read off what each offer queued.
        XCTAssertEqual([once, twice, thrice], [1, 0, 0])
        XCTAssertEqual(w.receiver.deliveries().count, 1)
        await h.events.stop()
    }
    func testMcpEventsL469() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        w.receiver.statuses = [500]
        let start = w.clock.now()
        _ = await offered(h, news())
        for step in [5_000.0, 30_000, 120_000] { await advance(w, h, step, tries: 1) }
        await advance(w, h, 600_000, tries: 0)
        XCTAssertEqual(w.receiver.deliveries().map { $0.at - start }, [0, 5_000, 35_000, 155_000])
        let owed = await h.events.owed(), armed = await h.events.armed()
        XCTAssertEqual(owed, 0); XCTAssertFalse(armed)
        XCTAssertEqual(w.delivered.get(), [])
        let live = await h.events.subscriptions(keyId: "key-a")
        XCTAssertEqual(live.first?["lastDelivery"]["ok"], .bool(false))
        XCTAssertTrue(live.first?["lastDelivery"]["error"].string?.contains("gave up after 4 tries") == true, live.first?["lastDelivery"].compact ?? "")
        await h.events.stop()
    }
    func testMcpEventsL489() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        w.receiver.statuses = [503, 429, 200]
        _ = await offered(h, news())
        await advance(w, h, 5_000, tries: 1)
        await advance(w, h, 30_000, tries: 1)
        await advance(w, h, 600_000, tries: 0)
        XCTAssertEqual(w.receiver.deliveries().count, 3)
        XCTAssertEqual(w.delivered.get().count, 1)
        let armed = await h.events.armed(); XCTAssertFalse(armed)
        await h.events.stop()
    }
    func testMcpEventsL506() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        w.receiver.statuses = [413]
        _ = await offered(h, news())
        await advance(w, h, 600_000, tries: 0)
        XCTAssertEqual(w.receiver.deliveries().count, 1)
        let kept = await h.events.subscriptions(keyId: "key-a"); XCTAssertEqual(kept.count, 1)

        w.receiver.statuses = [410]
        _ = await offered(h, news())
        await advance(w, h, 600_000, tries: 0)
        XCTAssertEqual(w.receiver.deliveries().count, 2)
        let ended = await h.events.subscriptions(keyId: "key-a"); XCTAssertTrue(ended.isEmpty)
        await h.events.stop()
    }

    // MARK: access, rechecked on every delivery

    func testMcpEventsL528() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        w.internet.set(false)
        let off = await offered(h, news()); XCTAssertEqual(off, 0)
        w.internet.set(true)
        let on = await offered(h, news()); XCTAssertEqual(on, 1)
        await h.events.stop()
    }
    func testMcpEventsL537() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params(), via: "this-mac")
        w.internet.set(false)
        let count = await offered(h, news()); XCTAssertEqual(count, 1)
        await h.events.stop()
    }
    func testMcpEventsL544() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        _ = try await subscribe(h, params(), key: "key-b")
        w.receiver.statuses = [500]
        _ = await offered(h, news())
        let owed = await h.events.owed(); XCTAssertEqual(owed, 1)
        w.modes.edit { $0["key-a"] = "off"; $0["key-b"] = nil }
        await h.events.reconcile()
        let live = await h.events.subscriptions(), left = await h.events.owed()
        XCTAssertTrue(live.isEmpty); XCTAssertEqual(left, 0)
        // Nothing is left to retry, so the timer that fires finds nothing to post.
        w.clock.advance(600_000)
        XCTAssertEqual(w.receiver.deliveries().count, 1)
        await h.events.stop()
    }
    func testMcpEventsL562() async throws {
        let w = W(), h = w.instance()
        let sub = try await subscribe(h, params()), id = sub["id"].string ?? ""
        let theirs = await h.events.stopSubscription(keyId: "key-b", id: id), mine = await h.events.stopSubscription(keyId: "key-a", id: id)
        XCTAssertFalse(theirs); XCTAssertTrue(mine)
        let live = await h.events.subscriptions(); XCTAssertTrue(live.isEmpty)
        await h.events.stop()
    }

    // MARK: events/unsubscribe

    func testMcpEventsL572() async throws {
        let w = W(), h = w.instance()
        _ = try await subscribe(h, params())
        let input = o([("name", .string("session.turn_finished")), ("arguments", .object([])), ("delivery", o([("url", .string(W.urlA))]))])
        // Another app cannot unsubscribe this one: its id is not this key's.
        let theirs = try await h.events.unsubscribe(keyId: "key-b", params: input)
        XCTAssertEqual(theirs, .object([]))
        let still = await h.events.subscriptions(keyId: "key-a"); XCTAssertEqual(still.count, 1)
        let once = try await h.events.unsubscribe(keyId: "key-a", params: input), twice = try await h.events.unsubscribe(keyId: "key-a", params: input)
        XCTAssertEqual(once, .object([])); XCTAssertEqual(twice, .object([]))
        let live = await h.events.subscriptions(); XCTAssertTrue(live.isEmpty)
        await h.events.stop()
    }

    // MARK: kept across a restart

    func testMcpEventsL586() async throws {
        let w = W(), dir = try scratch(), first = w.instance(directory: dir)
        _ = try await subscribe(first, params())
        w.receiver.statuses = [500, 200]
        let event = news(), id = event["id"].string ?? ""
        _ = await offered(first, event)
        await first.events.stop()

        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(BackendDeckCoreEvents.fileName).path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let second = w.instance(directory: dir)
        await second.events.load()
        let kept = await second.events.subscriptions(keyId: "key-a"), owed = await second.events.owed()
        XCTAssertEqual(kept.count, 1); XCTAssertEqual(owed, 1)
        await advance(w, second, 5_000, tries: 1)
        XCTAssertEqual(w.receiver.deliveries().map { $0.headers["webhook-id"] }, [id, id])
        XCTAssertEqual(w.delivered.get(), [["key-a", id]])
        let left = await second.events.owed(); XCTAssertEqual(left, 0)
        await second.events.stop()
    }
}
