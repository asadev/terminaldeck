import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreEventsQueueTests: XCTestCase {
    private func hub(_ clock: BackendDeckCoreEventsTestClock) -> BackendDeckCoreEventsHub {
        BackendDeckCoreEventsHub(settings:{ _ in BackendDeckCoreEventsSupport.object([("mode",.string("wait")),("url",.null),("secret",.null)]) },clock:clock)
    }
    func testQueuesAndAcknowledgementsNeverCrossKeys() async {
        let clock = BackendDeckCoreEventsTestClock(), queue = hub(clock)
        let a = BackendDeckCoreEventsTestFixture.event("a"), b = BackendDeckCoreEventsTestFixture.event("b")
        let addedA = await queue.enqueue(keyId:"A",event:a), addedB = await queue.enqueue(keyId:"B",event:b)
        XCTAssertTrue(addedA); XCTAssertTrue(addedB)
        let listed = await queue.list(keyId:"A"), ack = await queue.ack(keyId:"B",ids:["a","absent"])
        XCTAssertEqual(listed.map { $0["id"].string },["a"])
        XCTAssertEqual(ack["acked"],.array([])); XCTAssertEqual(ack["alreadyGone"],.array([.string("a"),.string("absent")]))
        let size = await queue.size(keyId:"A"); XCTAssertEqual(size,1); await queue.stop()
    }
    func testOffAndMissingKeysKeepNothing() async {
        let queue = BackendDeckCoreEventsHub(settings:{ key in key == "off" ? BackendDeckCoreEventsSupport.object([("mode",.string("off"))]) : nil })
        let off = await queue.enqueue(keyId:"off",event:BackendDeckCoreEventsTestFixture.event()), missing = await queue.enqueue(keyId:"gone",event:BackendDeckCoreEventsTestFixture.event())
        XCTAssertFalse(off); XCTAssertFalse(missing); let size = await queue.size(); XCTAssertEqual(size,0)
    }
    func testDeliveredWaitIsListedUntilAckAndNotGivenTwice() async {
        let clock = BackendDeckCoreEventsTestClock(), queue = hub(clock)
        _ = await queue.enqueue(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("a"))
        let first = await queue.wait(keyId:"A",timeoutMs:1)
        XCTAssertEqual(first.count,1)
        // notify-hub.test.ts: the wait parks (its 10 ms timer set) before the clock moves. Yielding
        // could advance first and leave the wait parked for ever; wait for its timer (the second one
        // set: the miss's retry, then this wait's), then for the fired timeout to settle it.
        let pending = Task { await queue.wait(keyId:"A",timeoutMs:10) }
        await clock.scheduled.wait(2); clock.advance(10); await queue.awaitIdle()
        let second = await pending.value, list = await queue.list(keyId:"A")
        XCTAssertEqual(second.count,0); XCTAssertEqual(list.first?["delivery"].string,"delivered"); XCTAssertEqual(list.first?["via"].string,"wait")
        let ack = await queue.ack(keyId:"A",ids:["a"]), again = await queue.ack(keyId:"A",ids:["a"])
        XCTAssertEqual(ack["acked"],.array([.string("a")])); XCTAssertEqual(again["alreadyGone"],.array([.string("a")]))
        await queue.stop()
    }
    func testParkedWaitReceivesImmediatelyAndCancellationSettles() async {
        let clock = BackendDeckCoreEventsTestClock(), queue = hub(clock), cancellation = BackendMCPCancellation()
        let first = Task { await queue.wait(keyId:"A",timeoutMs:45_000,cancellation:cancellation) }
        // Each wait is parked (its timer set) before it is cancelled or offered one, as in the source;
        // yielding could let the enqueue run first and test a ready take instead of a parked wait.
        await clock.scheduled.wait(1); cancellation.cancel(); let empty = await first.value; XCTAssertTrue(empty.isEmpty)
        let next = Task { await queue.wait(keyId:"A",timeoutMs:45_000) }
        await clock.scheduled.wait(2); _ = await queue.enqueue(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("a"))
        let got = await next.value; XCTAssertEqual(got.first?["id"].string,"a"); await queue.stop()
    }
    func testRetryScheduleHasFourAttemptsAndNoTimerAfterGiveUp() async {
        let clock = BackendDeckCoreEventsTestClock(), receiver = BackendDeckCoreEventsTestReceiver()
        await receiver.setStatuses([503])
        let queue = BackendDeckCoreEventsHub(settings:{ _ in BackendDeckCoreEventsSupport.object([("mode",.string("webhook")),("url",.string(BackendDeckCoreEventsTestFixture.url)),("secret",.string(BackendDeckCoreEventsTestFixture.secret))]) },clock:clock,post:{ url,headers,body in try await receiver.post(url,headers,body).status })
        // notify-hub.test.ts:248-251 settles each post's promise chain before the clock moves
        // (FakeClock.advance awaits flush() after every timer, :51-69). Yielding was a misport:
        // under load a post finished after the next advance and shifted the schedule (3 tries).
        // awaitIdle() awaits the fired timer and the post it starts, so each retry lands on time.
        _ = await queue.enqueue(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("a"))
        await queue.awaitIdle()
        for step in [5_000.0,30_000,120_000] { clock.advance(step); await queue.awaitIdle() }
        let delivered = await receiver.deliveries(), list = await queue.list(keyId:"A"), armed = await queue.armed()
        XCTAssertEqual(delivered.count,4); XCTAssertEqual(list.first?["delivery"].string,"undelivered"); XCTAssertFalse(armed)
        let fallback = await queue.wait(keyId:"A",timeoutMs:1); XCTAssertEqual(fallback.count,1); await queue.stop()
    }
    func testEventDeliveryStopsOtherWaysOut() async {
        let clock = BackendDeckCoreEventsTestClock(), queue = hub(clock)
        _ = await queue.enqueue(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("a"))
        let wrong = await queue.deliveredBy(keyId:"B",id:"a",via:"event"), delivered = await queue.deliveredBy(keyId:"A",id:"a",via:"event")
        XCTAssertFalse(wrong); XCTAssertTrue(delivered)
        let owed = await queue.owes(keyId:"A",id:"a"), armed = await queue.armed(); XCTAssertFalse(owed); XCTAssertFalse(armed)
        await queue.stop()
    }
    func testPerKeyAndAgeCaps() async {
        let clock = BackendDeckCoreEventsTestClock(), queue = hub(clock)
        for index in 0..<205 { _ = await queue.enqueue(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("n\(index)")) }
        _ = await queue.enqueue(keyId:"B",event:BackendDeckCoreEventsTestFixture.event("old",at:clock.now()-BackendDeckCoreEventsHub.maximumAge-1))
        let list = await queue.list(keyId:"A"), b = await queue.size(keyId:"B")
        XCTAssertEqual(list.count,200); XCTAssertEqual(list.first?["id"].string,"n5"); XCTAssertEqual(b,0); await queue.stop()
    }
    func testOneTurnSurvivesAcknowledgementAndRestartIn0600File() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let clock = BackendDeckCoreEventsTestClock(), settings: BackendDeckCoreEventsHub.Settings = { _ in BackendDeckCoreEventsSupport.object([("mode",.string("wait"))]) }
        let first = BackendDeckCoreEventsHub(directory:dir,settings:settings,clock:clock)
        let accepted = await first.enqueue(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("a"),turn:"answer:1:hash")
        XCTAssertTrue(accepted); _ = await first.ack(keyId:"A",ids:["a"]); await first.stop()
        let file = dir.appendingPathComponent(BackendDeckCoreEventsHub.fileName), attributes = try FileManager.default.attributesOfItem(atPath:file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let second = BackendDeckCoreEventsHub(directory:dir,settings:settings,clock:clock); await second.load()
        let repeated = await second.enqueue(keyId:"B",event:BackendDeckCoreEventsTestFixture.event("b"),turn:"answer:1:hash"); XCTAssertFalse(repeated)
        await second.stop()
    }
    func testEmptyQueueCostsNoRetryTimer() async {
        let clock = BackendDeckCoreEventsTestClock(), queue = hub(clock)
        let armed = await queue.armed(); XCTAssertFalse(armed); XCTAssertEqual(clock.pending(),0)
        _ = await queue.enqueue(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("a")); _ = await queue.enqueue(keyId:"B",event:BackendDeckCoreEventsTestFixture.event("b"))
        XCTAssertEqual(clock.pending(),1); await queue.stop(); XCTAssertEqual(clock.pending(),0)
    }
    func testAckIDLimitFiltersNonStringEntries() throws {
        XCTAssertEqual(try BackendDeckCoreEventsTools.ids(BackendDeckCoreEventsSupport.object([("ids",.array([.string("a"),.number(3),.string(""),.string("a")]))]),"ids"),["a","a"])
        XCTAssertThrowsError(try BackendDeckCoreEventsTools.ids(BackendDeckCoreEventsSupport.object([("ids",.array((0..<201).map { .string("n\($0)") }))]),"ids"))
    }
}
