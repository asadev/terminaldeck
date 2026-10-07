import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct BackendDeckCoreTestPortSecurityConsentFixture: Sendable {
    let broker: BackendDeckCoreSecurityConsentBroker
    let clock: BackendDeckCoreTestPortSecurityClock
    let seen: BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>
    let outcomes: BackendDeckCoreSecurityTestBox<[(String, BackendDeckCoreSecurityConsentOutcome)]>
    let delivered = BackendDeckCoreTestPortSecuritySignal()
    let ended = BackendDeckCoreTestPortSecuritySignal()
    init(delivery: Bool = true, throwsOnDelivery: Bool = false, throwsOnSettlement: Bool = false, timeout: Int = 5, maximumPending: Int = 3) {
        let clock = BackendDeckCoreTestPortSecurityClock(), seen = BackendDeckCoreSecurityTestBox<[BackendDeckCoreSecurityConsentRequest]>([])
        let outcomes = BackendDeckCoreSecurityTestBox<[(String, BackendDeckCoreSecurityConsentOutcome)]>([])
        let delivered = self.delivered, ended = self.ended
        let broker = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: timeout, maximumPending: maximumPending, clock: clock,
            ask: { question in seen.edit { $0.append(question) }; delivered.signal(); if throwsOnDelivery { throw NativeRPCError(code: "window", message: "the window went away mid-send") }; return delivery },
            settled: { id, outcome in outcomes.edit { $0.append((id, outcome)) }; ended.signal(); if throwsOnSettlement { throw NativeRPCError(code: "subscriber", message: "the pane blew up") } })
        self.clock = clock; self.seen = seen; self.outcomes = outcomes; self.broker = broker
    }
    func start(origin: String = "window", cancellation: BackendMCPCancellation? = nil, summary: String = "Change the theme") -> Task<BackendDeckCoreSecurityConsentOutcome, Never> {
        Task { await broker.request(tool: "settings.write", tier: .alter, summary: summary, arguments: .object([]), cancellation: cancellation, origin: origin) }
    }
    func question(_ index: Int = 0) -> BackendDeckCoreSecurityConsentRequest { seen.get()[index] }
}

final class BackendDeckCoreTestPortSecurityConsent: BackendDeckCoreTestPortSecurityCase {
    func testConsentL36() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(delivery: false, timeout: 60_000), at = f.clock.now(), result = await f.start().value
        XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .noApprover); XCTAssertEqual(f.clock.now() - at, 0); XCTAssertEqual(f.clock.pending(), 0)
    }
    func testConsentL47() async { let f = BackendDeckCoreTestPortSecurityConsentFixture(throwsOnDelivery: true), result = await f.start().value; XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .noApprover) }
    func testConsentL60() async { let f = BackendDeckCoreTestPortSecurityConsentFixture(delivery: false); _ = await f.start().value; let list = await f.broker.list(); XCTAssertTrue(list.isEmpty) }
    func testConsentL70() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(); await f.clock.scheduled.wait(1); f.clock.advance(5)
        let result = await call.value; await f.ended.wait(1)
        XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .timeout); XCTAssertFalse(f.outcomes.get()[0].1.granted); XCTAssertEqual(f.outcomes.get()[0].1.reason, .timeout)
    }
    func testConsentL79() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(); await f.clock.scheduled.wait(1); f.clock.advance(5); _ = await call.value
        let accepted = await f.broker.respond(id: f.question().id, approved: true, by: "window"); XCTAssertFalse(accepted)
    }
    func testConsentL91() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), one = f.start(), two = f.start(summary: "Change the sound")
        await f.delivered.wait(2); await f.broker.approverGone(); let a = await one.value, b = await two.value, list = await f.broker.list()
        XCTAssertFalse(a.granted); XCTAssertEqual(a.reason, .approverGone); XCTAssertFalse(b.granted); XCTAssertEqual(b.reason, .approverGone); XCTAssertTrue(list.isEmpty)
    }
    func testConsentL104() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), pending = f.start(); await f.delivered.wait(1); await f.broker.stop()
        let result = await pending.value, later = await f.start().value; XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .shuttingDown); XCTAssertFalse(later.granted); XCTAssertEqual(later.reason, .shuttingDown)
    }
    func testConsentL118() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), cancellation = BackendMCPCancellation(); cancellation.cancel(); let result = await f.start(cancellation: cancellation).value
        XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .callerGone); XCTAssertTrue(f.seen.get().isEmpty)
    }
    func testConsentL132() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), cancellation = BackendMCPCancellation(), call = f.start(cancellation: cancellation)
        await f.delivered.wait(1); XCTAssertEqual(f.seen.get().count, 1); cancellation.cancel()
        let result = await call.value; XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .callerGone)
        let late = await f.broker.respond(id: f.question().id, approved: true, by: "window"); XCTAssertFalse(late)
    }
    func testConsentL152() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(timeout: 60_000), held = (0..<3).map { _ in f.start() }; await f.delivered.wait(3)
        let list = await f.broker.list(); XCTAssertEqual(list.count, 3)
        let refused = await f.start().value; XCTAssertFalse(refused.granted); XCTAssertEqual(refused.reason, .tooManyPending)
        await f.broker.stop(); for call in held { _ = await call.value }
    }
    func testConsentL168() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(); await f.delivered.wait(1)
        let accepted = await f.broker.respond(id: f.question().id, approved: true, by: "window"), result = await call.value
        XCTAssertTrue(accepted); XCTAssertTrue(result.granted); XCTAssertEqual(result.by, "window"); XCTAssertEqual(result.at, f.clock.now())
    }
    func testConsentL177() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(); await f.delivered.wait(1); _ = await f.broker.respond(id: f.question().id, approved: false, by: "window")
        let result = await call.value; XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .declined); XCTAssertEqual(result.by, "window")
    }
    func testConsentL187() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(); await f.delivered.wait(1)
        _ = await f.broker.respond(id: f.question().id, approved: V.missing.bool == true, by: "window")
        let result = await call.value; XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .declined)
    }
    func testConsentL198() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(); await f.delivered.wait(1)
        let first = await f.broker.respond(id: f.question().id, approved: true, by: "window"), second = await f.broker.respond(id: f.question().id, approved: false, by: "window"), outcome = await call.value
        XCTAssertTrue(first); XCTAssertFalse(second); XCTAssertTrue(outcome.granted)
    }
    func testConsentL206() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(throwsOnSettlement: true), call = f.start(); await f.delivered.wait(1)
        _ = await f.broker.respond(id: f.question().id, approved: true, by: "window"); let result = await call.value; await f.ended.wait(1); XCTAssertTrue(result.granted)
    }
    func testConsentL229() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(timeout: 60_000), call = f.start(); await f.delivered.wait(1)
        let list = await f.broker.list(); XCTAssertEqual(list[0].tool, "settings.write"); XCTAssertEqual(list[0].summary, "Change the theme"); XCTAssertGreaterThan(list[0].expiresAt, list[0].requestedAt)
        await f.broker.stop(); _ = await call.value
    }
    func testConsentL263() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(origin: "device:phone-1"); await f.delivered.wait(1)
        let accepted = await f.broker.respond(id: f.question().id, approved: true, by: "device:phone-1"), result = await call.value
        XCTAssertTrue(accepted); XCTAssertTrue(result.granted); XCTAssertEqual(result.by, "device:phone-1")
    }
    func testConsentL270() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(origin: "device:phone-1"); await f.delivered.wait(1)
        let accepted = await f.broker.respond(id: f.question().id, approved: true, by: "window"), result = await call.value
        XCTAssertTrue(accepted); XCTAssertTrue(result.granted); XCTAssertEqual(result.by, "window")
    }
    func testConsentL286() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(origin: "device:phone-1"); await f.delivered.wait(1)
        let other = await f.broker.respond(id: f.question().id, approved: true, by: "device:phone-2"), invented = await f.broker.respond(id: "never-existed", approved: true, by: "device:phone-2"), list = await f.broker.list()
        XCTAssertFalse(other); XCTAssertFalse(invented); XCTAssertEqual(list.count, 1)
        _ = await f.broker.respond(id: f.question().id, approved: false, by: "window"); let result = await call.value; XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .declined)
    }
    func testConsentL299() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(); await f.delivered.wait(1)
        let other = await f.broker.respond(id: f.question().id, approved: true, by: "device:phone-1"); XCTAssertFalse(other)
        _ = await f.broker.respond(id: f.question().id, approved: true, by: "window"); let result = await call.value; XCTAssertTrue(result.granted)
    }
    func testConsentL315() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(); await f.delivered.wait(1); XCTAssertEqual(f.question().origin, "window")
        let other = await f.broker.respond(id: f.question().id, approved: true, by: "device:phone-1"); XCTAssertFalse(other)
        _ = await f.broker.respond(id: f.question().id, approved: true, by: "window"); _ = await call.value
    }
    func testConsentL324() async {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), call = f.start(origin: "device:phone-1"); await f.delivered.wait(1)
        let mine = await f.broker.mayAnswer(id: f.question().id, by: "device:phone-1"), other = await f.broker.mayAnswer(id: f.question().id, by: "device:phone-2"), desktop = await f.broker.mayAnswer(id: f.question().id, by: "window"), stale = await f.broker.mayAnswer(id: "never-existed", by: "window")
        XCTAssertTrue(mine); XCTAssertFalse(other); XCTAssertTrue(desktop); XCTAssertFalse(stale); await f.broker.stop(); _ = await call.value
    }
    func testConsentL347() async throws {
        let f = BackendDeckCoreTestPortSecurityConsentFixture(), mine = f.start(origin: "device:phone-1"), theirs = f.start(); await f.delivered.wait(2); XCTAssertEqual(f.seen.get().count, 2)
        try await f.broker.callerGone("device:phone-1"); let result = await mine.value; XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, .callerGone)
        let list = await f.broker.list(); XCTAssertEqual(list.count, 1); _ = await f.broker.respond(id: list[0].id, approved: true, by: "window"); let allowed = await theirs.value; XCTAssertTrue(allowed.granted)
    }
    func testConsentL370() async { let f = BackendDeckCoreTestPortSecurityConsentFixture(); await assertAsyncError({ try await f.broker.callerGone("window") }, contains: "approverGone") }
}
