import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// notify-detect.test.ts: whose notification is whose, through the real
/// control gate. Two AI apps on two keys, the control's own record of who
/// started what and its own action rows for who sent what, statuses fed the
/// way the app feeds them, on a clock the test moves.
///
/// Waits: a `completed` turn builds inside noteStatus, so awaitIdle() covers
/// it; a settle or lag timer fires on the clock, so the test first waits for
/// the build to start (the surface's read) or for the lag pause to be set.
final class BackendDeckCoreTestPortS1NotifyDetectTests: BackendDeckCoreTestPortS1EventsCase {
    private func settled(_ r: Rig, after milliseconds: Double) async {
        let mark = r.builds.value()
        r.clock.advance(milliseconds)
        await r.builds.wait(mark + 1)
        await r.detector.awaitIdle()
    }

    // MARK: two apps, two keys, interleaved

    func testNotifyDetectL158() async throws {
        let r = try await keyRig()
        let a = try await r.key("App A"), b = try await r.key("App B")
        let sA = try await start(r, "/work/api", as: r.caller(a)), sB = try await start(r, "/work/site", as: r.caller(b))

        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sB, status: "working")
        await r.detector.noteStatus(sessionId: sB, status: "input")
        await r.detector.noteStatus(sessionId: sA, status: "completed")
        await r.detector.awaitIdle()

        var ofA = await r.types(a.id), ofB = await r.types(b.id)
        XCTAssertEqual(ofA, [[sA, "finished"]]); XCTAssertEqual(ofB, [[sB, "needs-input"]])
        let questions = await r.hub.list(keyId: b.id), question = try XCTUnwrap(questions.first)
        XCTAssertEqual(question["suggestedTool"], .string("sessions_keys"))
        XCTAssertTrue(question["note"].string?.contains("sessions_keys") == true)

        await r.detector.noteExit(sessionId: sA, exitCode: 1)
        await r.detector.awaitIdle()
        ofA = await r.types(a.id); ofB = await r.types(b.id)
        XCTAssertEqual(ofA, [[sA, "finished"], [sA, "exited"]])
        let rowsA = await r.hub.list(keyId: a.id), exit = try XCTUnwrap(rowsA.dropFirst().first)
        XCTAssertEqual(exit["crashed"], .bool(true)); XCTAssertEqual(exit["exitCode"], .number(1)); XCTAssertEqual(exit["suggestedTool"], .string("sessions_result"))
        XCTAssertEqual(ofB, [[sB, "needs-input"]])
        await r.stop()
    }
    func testNotifyDetectL186() async throws {
        let r = try await keyRig()
        let a = try await r.key("App A"), b = try await r.key("App B", level: "full", askFirst: false)
        let sA = try await start(r, "/work/api", as: r.caller(a))

        // B is let into A's session for one message (Full control, not asking).
        let sent = await send(r, sA, "hello", as: r.caller(b))
        XCTAssertTrue(sent.ok, sent.error ?? "")
        await turn(r, sA)
        var ofB = await r.types(b.id), ofA = await r.types(a.id)
        XCTAssertEqual(ofB, [[sA, "finished"]]); XCTAssertEqual(ofA, [])

        // The next turn has no known trigger, so it is the starter's again.
        await turn(r, sA)
        ofA = await r.types(a.id); ofB = await r.types(b.id)
        XCTAssertEqual(ofA, [[sA, "finished"]]); XCTAssertEqual(ofB.count, 1)
        await r.stop()
    }
    func testNotifyDetectL204() async throws {
        let r = try await keyRig()
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a)), sC = try await start(r, "/work/site")

        // The copilot's own session: its turns and its exit are nobody's news.
        let own = await send(r, sC, "from the copilot")
        XCTAssertTrue(own.ok, own.error ?? "")
        await turn(r, sC)
        await r.detector.noteExit(sessionId: sC, exitCode: 0)
        // A turn the copilot (or the person) triggered in the app's session — the
        // row the dispatcher writes when the owner allows it — is not the app's.
        await r.detector.noteRow(own.row.setting("sessionId", .string(sA)))
        await turn(r, sA)
        await r.detector.awaitIdle()
        let size = await r.hub.size(); XCTAssertEqual(size, 0)
        await r.stop()
    }
    func testNotifyDetectL222() async throws {
        let r = try await keyRig(), settle = BackendDeckCoreEventsDetector.settleMilliseconds
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        let mark = r.enqueued.value()
        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sA, status: "waiting")
        r.clock.advance(settle / 2)
        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sA, status: "waiting")
        r.clock.advance(settle)
        await r.enqueued.wait(mark + 1); await r.detector.awaitIdle()
        let ofA = await r.types(a.id); XCTAssertEqual(ofA, [[sA, "finished"]])
        await r.stop()
    }
    func testNotifyDetectL235() async throws {
        let r = try await keyRig(), settle = BackendDeckCoreEventsDetector.settleMilliseconds
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        let sent = await send(r, sA, "reply OK", as: r.caller(a))
        XCTAssertTrue(sent.ok, sent.error ?? "")
        r.say(sA, "DOT_PUSH_TEST_OK")
        let told = r.enqueued.value()
        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sA, status: "idle")
        r.clock.advance(settle)
        await r.enqueued.wait(told + 1); await r.detector.awaitIdle()
        let first = await r.hub.list(keyId: a.id)
        XCTAssertEqual(first.map { $0["answer"]["text"].string }, ["DOT_PUSH_TEST_OK"])

        // The redraws seen in his queue: 7 s, 17 min, an hour and six hours later,
        // a hook's `completed` among them, the answer unchanged — and one acked.
        _ = await r.hub.ack(keyId: a.id, ids: Array(first.compactMap { $0["id"].string }.prefix(1)))
        for gap in [7_000.0, 17 * 60_000, 60 * 60_000, 6 * 60 * 60_000] as [Double] {
            r.clock.advance(gap)
            await r.detector.noteStatus(sessionId: sA, status: "working")
            if gap == 7_000 {
                // The hook's end of turn reads the transcript again while it lags.
                let pauses = r.pauses.value()
                await r.detector.noteStatus(sessionId: sA, status: "completed")
                await waitOutLag(r, from: pauses, firstStep: settle)
                await r.detector.awaitIdle()
            } else {
                await r.detector.noteStatus(sessionId: sA, status: "idle")
                await settled(r, after: settle)
            }
        }
        let quiet = await r.hub.size(keyId: a.id); XCTAssertEqual(quiet, 0)

        // Something new said is a new turn.
        await turn(r, sA)
        let told2 = await r.hub.size(keyId: a.id); XCTAssertEqual(told2, 1)
        await r.stop()
    }
    func testNotifyDetectL264() async throws {
        let r = try await keyRig(), settle = BackendDeckCoreEventsDetector.settleMilliseconds
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        // No transcript yet; the banner reads as working then calm, four times over.
        r.silence(sA)
        for _ in 0..<4 {
            await r.detector.noteStatus(sessionId: sA, status: "working")
            await r.detector.noteStatus(sessionId: sA, status: "idle")
            await settled(r, after: settle + 6_500)
        }
        let none = await r.hub.size(keyId: a.id); XCTAssertEqual(none, 0)

        // The app's first message is a turn: told, with the answer.
        let sent = await send(r, sA, "hello", as: r.caller(a))
        XCTAssertTrue(sent.ok, sent.error ?? "")
        await turn(r, sA)
        let ofA = await r.types(a.id); XCTAssertEqual(ofA, [[sA, "finished"]])
        let rows = await r.hub.list(keyId: a.id), told = try XCTUnwrap(rows.first)
        XCTAssertNotEqual(told["answer"], .missing)
        await r.stop()
    }
    func testNotifyDetectL285() async throws {
        let r = try await keyRig()
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        r.silence(sA)
        let sent = await send(r, sA, "hello", as: r.caller(a))
        XCTAssertTrue(sent.ok, sent.error ?? "")
        var pauses = r.pauses.value()
        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sA, status: "completed")
        await waitOutLag(r, from: pauses); await r.detector.awaitIdle()
        let told = await r.hub.list(keyId: a.id)
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told.first?["type"], .string("finished")); XCTAssertEqual(told.first?["suggestedTool"], .string("sessions_screen"))
        // The redraw after it has no sender and no transcript: nothing.
        pauses = r.pauses.value()
        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sA, status: "completed")
        await waitOutLag(r, from: pauses); await r.detector.awaitIdle()
        let size = await r.hub.size(keyId: a.id); XCTAssertEqual(size, 1)
        await r.stop()
    }
    func testNotifyDetectL303() async throws {
        let r = try await keyRig(), settle = BackendDeckCoreEventsDetector.settleMilliseconds
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        r.say(sA, "said yesterday, and never told")
        r.clock.advance(24 * 60 * 60_000)
        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sA, status: "idle")
        await settled(r, after: settle)
        let size = await r.hub.size(keyId: a.id); XCTAssertEqual(size, 0)
        await r.stop()
    }
    func testNotifyDetectL315() async throws {
        let r = try await keyRig(), lag = BackendDeckCoreEventsDetector.answerLagMilliseconds
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        r.say(sA, "the answer before")
        r.clock.advance(60_000)
        let sent = await send(r, sA, "go on", as: r.caller(a))
        XCTAssertTrue(sent.ok, sent.error ?? "")
        let pauses = r.pauses.value()
        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sA, status: "completed")
        await r.pauses.wait(pauses + 1)
        // The transcript still ends on the last turn's answer: not told yet, and not told wrong.
        let early = await r.hub.size(keyId: a.id); XCTAssertEqual(early, 0)
        r.say(sA, "the late answer")
        let mark = r.enqueued.value()
        r.clock.advance(lag)
        await r.enqueued.wait(mark + 1); await r.detector.awaitIdle()
        let told = await r.hub.list(keyId: a.id)
        XCTAssertEqual(told.map { $0["answer"]["text"].string }, ["the late answer"])
        await r.stop()
    }
    func testNotifyDetectL333() async throws {
        let r = try await keyRig(), lag = BackendDeckCoreEventsDetector.answerLagMilliseconds
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        r.say(sA, "the answer before")
        r.clock.advance(60_000)
        let sent = await send(r, sA, "go on", as: r.caller(a))
        XCTAssertTrue(sent.ok, sent.error ?? "")
        let pauses = r.pauses.value(), mark = r.enqueued.value()
        await r.detector.noteStatus(sessionId: sA, status: "working")
        await r.detector.noteStatus(sessionId: sA, status: "completed")
        for retry in 1...BackendDeckCoreEventsDetector.answerLagRetries {
            await r.pauses.wait(pauses + retry)
            let size = await r.hub.size(keyId: a.id); XCTAssertEqual(size, 0)
            r.clock.advance(lag)
        }
        await r.enqueued.wait(mark + 1); await r.detector.awaitIdle()
        let told = await r.hub.list(keyId: a.id)
        XCTAssertEqual(told.count, 1)
        XCTAssertEqual(told.first?["type"], .string("finished")); XCTAssertEqual(told.first?["suggestedTool"], .string("sessions_screen"))
        await r.stop()
    }
    func testNotifyDetectL352() async throws {
        let r = try await keyRig(), settle = BackendDeckCoreEventsDetector.settleMilliseconds, disk = try scratch(), keys = r.keys
        let a = try await r.key("App A")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        let first = BackendDeckCoreEventsHub(directory: disk, settings: { await keys.notifySettings(id: $0) }, clock: r.clock)
        let before = r.detector(target: first)
        r.say(sA, "the answer before the restart")
        await before.noteStatus(sessionId: sA, status: "working")
        await before.noteStatus(sessionId: sA, status: "completed")
        await before.awaitIdle()
        let once = await first.size(keyId: a.id); XCTAssertEqual(once, 1)
        let listed = await first.list(keyId: a.id)
        _ = await first.ack(keyId: a.id, ids: listed.compactMap { $0["id"].string })
        await before.stop(); await first.stop()

        // The app comes back; the session redraws on the same last answer.
        let second = BackendDeckCoreEventsHub(directory: disk, settings: { await keys.notifySettings(id: $0) }, clock: r.clock)
        await second.load()
        let after = r.detector(target: second)
        await after.noteStatus(sessionId: sA, status: "working")
        await after.noteStatus(sessionId: sA, status: "idle")
        let mark = r.enqueued.value()
        r.clock.advance(settle)
        await r.enqueued.wait(mark + 1); await after.awaitIdle()
        let again = await second.size(keyId: a.id); XCTAssertEqual(again, 0)
        await after.stop(); await second.stop()
        await r.stop()
    }
    func testNotifyDetectL383() async throws {
        let r = try await keyRig()
        let a = try await r.key("App A")
        _ = try await r.keys.setNotify(id: a.id, input: o([("mode", .string("off"))]))
        let sA = try await start(r, "/work/api", as: r.caller(a))
        await turn(r, sA)
        let size = await r.hub.size(); XCTAssertEqual(size, 0)
        await r.stop()
    }

    // MARK: the tools, over the MCP road, each key blind to the other

    func testNotifyDetectL414() async throws {
        let r = try await keyRig()
        let a = try await r.key("App A"), b = try await r.key("App B")
        let sA = try await start(r, "/work/api", as: r.caller(a))
        let initialized = try await legacy(r, a.key, "initialize", o([("protocolVersion", .string("2025-06-18")), ("capabilities", .object([])),
            ("clientInfo", o([("name", .string("outside-app")), ("version", .string("1"))]))]), id: 1)
        let names = try await legacy(r, a.key, "tools/list", id: 2)["result"]["tools"].elements?.compactMap { $0["name"].string } ?? []
        XCTAssertTrue(names.contains("notifications_wait")); XCTAssertFalse(names.contains("app_where"))
        XCTAssertLessThanOrEqual(names.count, 20)
        // The server's own instructions say the same sentence the setup snippets do.
        XCTAssertTrue(initialized["result"]["instructions"].string?.contains("call notifications_wait instead of polling sessions_wait") == true)

        // Parked in the queue: the wait's own timeout timer is set.
        let parkedMark = r.clock.scheduled.value()
        let waitBody = rpc("tools/call", id: .number(3), params: o([("name", .string("notifications_wait")), ("arguments", o([("timeoutSeconds", .number(5))]))]))
        let waiting = Task { try await r.post(waitBody, credential: a.key) }
        await r.clock.scheduled.wait(parkedMark + 1)
        await turn(r, sA)
        let got = try response(try await waiting.value)["result"]["structuredContent"]
        let notifications = got["notifications"].elements ?? []
        XCTAssertEqual(notifications.map { [$0["sessionId"].string ?? "", $0["type"].string ?? ""] }, [[sA, "finished"]])
        let id = try XCTUnwrap(notifications.first?["id"].string)

        // B cannot see it, and acking it from B changes nothing.
        let listB = try await legacy(r, b.key, "tools/call", o([("name", .string("tools_run")), ("arguments", o([("name", .string("notifications_list"))]))]), id: 4)
        XCTAssertEqual(listB["result"]["structuredContent"]["notifications"], .array([]))
        let ackB = try await legacy(r, b.key, "tools/call", o([("name", .string("tools_run")), ("arguments", o([("name", .string("notifications_ack")),
            ("arguments", o([("ids", .array([.string(id), .string("never")]))]))]))]), id: 5)
        assertValue(ackB["result"]["structuredContent"], o([("acked", .array([])), ("alreadyGone", .array([.string(id), .string("never")]))]))
        let kept = await r.hub.size(keyId: a.id); XCTAssertEqual(kept, 1)

        // A acks it on its next wait, which then times out with nothing — on the
        // test's clock, which is the queue's.
        let nextMark = r.clock.scheduled.value()
        let nextBody = rpc("tools/call", id: .number(6), params: o([("name", .string("notifications_wait")),
            ("arguments", o([("timeoutSeconds", .number(1)), ("ack", .array([.string(id)]))]))]))
        let nextCall = Task { try await r.post(nextBody, credential: a.key) }
        await r.clock.scheduled.wait(nextMark + 1)
        r.clock.advance(1_000)
        let next = try response(try await nextCall.value)["result"]["structuredContent"]
        XCTAssertEqual(next["notifications"], .array([])); XCTAssertEqual(next["timedOut"], .bool(true)); XCTAssertEqual(next["outstanding"], .number(0))
        await r.stop()
    }
    func testNotifyDetectL458() async throws {
        let r = try await keyRig()
        let token = r.endpoint.token
        _ = try await legacy(r, token, "initialize", o([("protocolVersion", .string("2025-06-18")), ("capabilities", .object([])),
            ("clientInfo", o([("name", .string("copilot")), ("version", .string("1"))]))]), id: 1)
        let names = try await legacy(r, token, "tools/list", id: 2)["result"]["tools"].elements?.compactMap { $0["name"].string } ?? []
        XCTAssertFalse(names.isEmpty)
        XCTAssertFalse(names.contains { $0.hasPrefix("notifications_") })
        let refused = try await legacy(r, token, "tools/call", o([("name", .string("notifications_wait")), ("arguments", .object([]))]), id: 3)
        XCTAssertEqual(refused["result"]["isError"], .bool(true))
        await r.stop()
    }
}
