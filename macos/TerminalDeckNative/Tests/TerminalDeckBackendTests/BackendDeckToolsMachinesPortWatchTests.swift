import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckToolsMachinesPortWatchTests: XCTestCase {
    private let o = BackendDeckToolsMachinesPortObject
    private func output(_ text: String, session: String = "s1") -> NativeRPCValue { o(["machineId": .string("m1"), "sessionId": .string(session), "data": .string(text)]) }
    func testScreenUsesAttachedDimensionsAndIsLive() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckToolsMachinesPortClockFake()); await watch.invoked("machines:attach", [.string("m1"), .string("s1"), .number(40), .number(5)]); await watch.pushed("machines:output", output("hello from the office\r\n❯ "))
        let screen = await watch.screen("m1", "s1"); BackendDeckToolsMachinesPortEqual(screen["cols"], .number(40)); BackendDeckToolsMachinesPortEqual(screen["rows"], .number(5)); BackendDeckToolsMachinesPortEqual(screen["live"], .bool(true)); XCTAssertTrue(screen["text"].string?.contains("hello from the office") == true); await watch.dispose()
    }
    func testUnattachedOutputCreatesNoScreen() async { let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckToolsMachinesPortClockFake()); await watch.pushed("machines:output", output("nobody asked", session: "s9")); let screen = await watch.screen("m1", "s9"); BackendDeckToolsMachinesPortEqual(screen, .null); await watch.dispose() }
    func testScreenFollowsResize() async { let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckToolsMachinesPortClockFake()); await watch.invoked("machines:attach", [.string("m1"), .string("s1"), .number(40), .number(5)]); await watch.invoked("machines:resize", [.string("m1"), .string("s1"), .number(100), .number(20)]); let screen = await watch.screen("m1", "s1"); BackendDeckToolsMachinesPortEqual(screen["cols"], .number(100)); BackendDeckToolsMachinesPortEqual(screen["rows"], .number(20)); await watch.dispose() }
    func testForgettingMachineForgetsAllItsScreens() async { let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckToolsMachinesPortClockFake()); await watch.invoked("machines:attach", [.string("m1"), .string("s1"), .number(40), .number(5)]); await watch.invoked("machines:forget", [.string("m1")]); let screen = await watch.screen("m1", "s1"); BackendDeckToolsMachinesPortEqual(screen, .null); await watch.dispose() }
    func testOldestUntouchedScreenIsEvictedAtBound() async {
        let clock = BackendDeckToolsMachinesPortClockFake(), watch = BackendDeckToolsMachinesWatch(maximumScreens: 2, clock: clock)
        clock.advance(1); await watch.invoked("machines:attach", [.string("m1"), .string("a"), .number(40), .number(5)])
        clock.advance(1); await watch.invoked("machines:attach", [.string("m1"), .string("b"), .number(40), .number(5)])
        clock.advance(1); await watch.pushed("machines:output", output("busy", session: "a"))
        clock.advance(1); await watch.invoked("machines:attach", [.string("m1"), .string("c"), .number(40), .number(5)])
        let b = await watch.screen("m1", "b"), a = await watch.screen("m1", "a"), c = await watch.screen("m1", "c")
        BackendDeckToolsMachinesPortEqual(b, .null); XCTAssertNotEqual(a, .null); XCTAssertNotEqual(c, .null); await watch.dispose()
    }
    func testConversationMergesByIDThenResetReplacesEverything() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckToolsMachinesPortClockFake())
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("1", "you", "hi"), BackendDeckToolsMachinesPortMessage("2", "agent", "hel")], reset: true))
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("2", "agent", "hello")]))
        var state = await watch.conversation("m1"); BackendDeckToolsMachinesPortEqual(state["messages"].elements?.compactMap { $0["text"].string }, ["hi", "hello"])
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("9", "you", "new run")], run: "r2", reset: true))
        state = await watch.conversation("m1"); BackendDeckToolsMachinesPortEqual(state["run"], .string("r2")); BackendDeckToolsMachinesPortEqual(state["messages"].elements?.compactMap { $0["id"].string }, ["9"]); await watch.dispose()
    }
    func testLateOldRunCannotSpliceWrongAnswer() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckToolsMachinesPortClockFake())
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("1", "you", "now")], run: "r2", reset: true))
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("x", "agent", "wrong old answer")], run: "r1"))
        let state = await watch.conversation("m1"); BackendDeckToolsMachinesPortEqual(state["messages"].elements?.compactMap { $0["id"].string }, ["1"]); await watch.dispose()
    }
    func testStatePushIsRetainedAsGiven() async { let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckToolsMachinesPortClockFake()); await watch.pushed("machines:copilot:state", o(["machineId": .string("m1"), "state": o(["desk": .string("running")])])); let state = await watch.conversation("m1"); BackendDeckToolsMachinesPortEqual(state["state"], o(["desk": .string("running")])); await watch.dispose() }
    func testStreamSettleRestartsAndOldAnswerDoesNotSettle() async {
        let clock = BackendDeckToolsMachinesPortClockFake(), watch = BackendDeckToolsMachinesWatch(clock: clock)
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("1", "you", "old"), BackendDeckToolsMachinesPortMessage("2", "agent", "old answer")], reset: true))
        let pending = Task { await watch.replied("m1", since: "2", ceilingMS: 10_000, settleMS: 1_000) }; await clock.whenScheduled(1)
        clock.advance(1_500); BackendDeckToolsMachinesPortEqual(clock.pendingCount(), 1)
        await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("3", "you", "new question"), BackendDeckToolsMachinesPortMessage("4", "agent", "the start of")]))
        clock.advance(500); await watch.pushed("machines:copilot:chat", BackendDeckToolsMachinesPortChat([BackendDeckToolsMachinesPortMessage("4", "agent", "the start of the new answer")]))
        clock.advance(1_001); let answered = await pending.value; XCTAssertTrue(answered); await watch.dispose()
    }
    func testReplyCeilingIsFalseWhenNothingCameBack() async { let clock = BackendDeckToolsMachinesPortClockFake(), watch = BackendDeckToolsMachinesWatch(clock: clock), pending = Task { await watch.replied("m1", since: nil, ceilingMS: 2_000, settleMS: 500) }; await clock.whenScheduled(1); clock.advance(2_001); let answer = await pending.value; XCTAssertFalse(answer); await watch.dispose() }
    func testNextChangeListenerIsInstalledBeforeAfterPush() async throws {
        let clock = BackendDeckToolsMachinesPortClockFake(), watch = BackendDeckToolsMachinesWatch(clock: clock), value = o(["machineId": .string("m1"), "state": o(["desk": .string("stopped")])])
        let changed = try await watch.nextChange("m1", ceilingMS: 1_000) { await watch.pushed("machines:copilot:state", value) }
        XCTAssertTrue(changed); BackendDeckToolsMachinesPortEqual(clock.pendingCount(), 0); await watch.dispose()
    }
    func testAnsweredAfterRequiresNewOursAgentLastAndNonblankText() {
        let old = [BackendDeckToolsMachinesPortMessage("1", "you", "q"), BackendDeckToolsMachinesPortMessage("2", "agent", "a")]
        XCTAssertFalse(BackendDeckToolsMachinesWatch.answeredAfter(old, since: "2"))
        XCTAssertFalse(BackendDeckToolsMachinesWatch.answeredAfter(old + [BackendDeckToolsMachinesPortMessage("3", "you", "q2")], since: "2"))
        XCTAssertTrue(BackendDeckToolsMachinesWatch.answeredAfter(old + [BackendDeckToolsMachinesPortMessage("3", "you", "q2"), BackendDeckToolsMachinesPortMessage("4", "agent", "a2")], since: "2"))
        XCTAssertTrue(BackendDeckToolsMachinesWatch.answeredAfter([BackendDeckToolsMachinesPortMessage("5", "you", "q"), BackendDeckToolsMachinesPortMessage("6", "agent", "a")], since: "gone"))
        XCTAssertFalse(BackendDeckToolsMachinesWatch.answeredAfter([BackendDeckToolsMachinesPortMessage("5", "you", "q"), BackendDeckToolsMachinesPortMessage("6", "agent", "   ")], since: nil))
    }
}
