import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreTestPortSessionsWatchTests: XCTestCase {
    private typealias V = NativeRPCValue
    private func object(_ fields: [(String, V)]) -> V { .object(fields.map { .init($0.0, $0.1) }) }
    private func attach(_ watch: BackendDeckToolsMachinesWatch, _ session: String) async {
        await watch.invoked("machines:attach", [.string("m1"), .string(session), .number(40), .number(5)])
    }
    private func output(_ watch: BackendDeckToolsMachinesWatch, _ session: String, _ text: String) async {
        await watch.pushed("machines:output", object([("machineId", .string("m1")), ("sessionId", .string(session)), ("data", .string(text))]))
    }
    private func message(_ id: String, _ role: String, _ text: String) -> V { object([("id", .string(id)), ("role", .string(role)), ("text", .string(text)), ("at", .number(0))]) }
    private func chat(_ watch: BackendDeckToolsMachinesWatch, run: String, messages: [V], reset: Bool = false) async {
        await watch.pushed("machines:copilot:chat", object([("machineId", .string("m1")), ("chat", object([("run", .string(run)), ("messages", .array(messages)), ("reset", .bool(reset))]))]))
    }
    func testScreenUsesExactAttachedDimensionsAndOutput() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckCoreTestPortSessionsManualClock())
        await attach(watch, "s1"); await output(watch, "s1", "hello from the office\r\n❯ ")
        let screen = await watch.screen("m1", "s1")
        XCTAssertEqual(screen["cols"], .number(40)); XCTAssertEqual(screen["rows"], .number(5))
        XCTAssertEqual(screen["live"], .bool(true)); XCTAssertTrue(screen["text"].string?.contains("hello from the office") == true)
        await watch.dispose()
    }
    func testUnrequestedSessionOutputNeverCreatesScreen() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckCoreTestPortSessionsManualClock())
        await output(watch, "s9", "bytes nobody asked for")
        let screen = await watch.screen("m1", "s9"); XCTAssertEqual(screen, .null)
        await watch.dispose()
    }
    func testDetachedScreenRemainsReadableAndMarkedStale() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckCoreTestPortSessionsManualClock())
        await attach(watch, "s1"); await output(watch, "s1", "still here")
        await watch.invoked("machines:detach", [.string("m1"), .string("s1")])
        let screen = await watch.screen("m1", "s1"), attached = await watch.attached("m1", "s1")
        XCTAssertEqual(screen["live"], .bool(false)); XCTAssertTrue(screen["text"].string?.contains("still here") == true); XCTAssertFalse(attached)
        await watch.dispose()
    }
    func testResizeAndForgetFollowNativeInvocation() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckCoreTestPortSessionsManualClock())
        await attach(watch, "s1")
        await watch.invoked("machines:resize", [.string("m1"), .string("s1"), .number(100), .number(20)])
        let sized = await watch.screen("m1", "s1"); XCTAssertEqual(sized["cols"], .number(100))
        await watch.invoked("machines:forget", [.string("m1")])
        let gone = await watch.screen("m1", "s1"); XCTAssertEqual(gone, .null)
        await watch.dispose()
    }
    func testScreenBoundEvictsLeastRecentlyTouched() async {
        let clock = BackendDeckCoreTestPortSessionsCounter()
        let watch = BackendDeckToolsMachinesWatch(maximumScreens: 2, now: { clock.next() })
        await attach(watch, "a"); await attach(watch, "b"); await output(watch, "a", "a is busy"); await attach(watch, "c")
        let b = await watch.screen("m1", "b"), a = await watch.screen("m1", "a"), c = await watch.screen("m1", "c")
        XCTAssertEqual(b, .null); XCTAssertNotEqual(a, .null); XCTAssertNotEqual(c, .null)
        await watch.dispose()
    }
    func testConversationMergesByIDAndNewRunResetReplacesAll() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckCoreTestPortSessionsManualClock())
        await chat(watch, run: "r1", messages: [message("1", "you", "hi"), message("2", "agent", "hel")], reset: true)
        await chat(watch, run: "r1", messages: [message("2", "agent", "hello")])
        let merged = await watch.conversation("m1")
        XCTAssertEqual(merged["messages"].elements?.map { $0["text"].string }, ["hi", "hello"])
        await chat(watch, run: "r2", messages: [message("9", "you", "new run")], reset: true)
        let reset = await watch.conversation("m1")
        XCTAssertEqual(reset["messages"].elements?.map { $0["id"].string }, ["9"]); XCTAssertEqual(reset["run"], .string("r2"))
        await watch.dispose()
    }
    func testOldRunFrameIsDroppedWithoutChangingCurrentIDs() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckCoreTestPortSessionsManualClock())
        await chat(watch, run: "r2", messages: [message("1", "you", "now")], reset: true)
        await chat(watch, run: "r1", messages: [message("x", "agent", "an answer to something never asked in this run")])
        let state = await watch.conversation("m1")
        XCTAssertEqual(state["messages"].elements?.map { $0["id"].string }, ["1"])
        await watch.dispose()
    }
    func testStatePushIsKeptWhole() async {
        let watch = BackendDeckToolsMachinesWatch(clock: BackendDeckCoreTestPortSessionsManualClock())
        await watch.pushed("machines:copilot:state", object([("machineId", .string("m1")), ("state", .object([.init("desk", .string("running"))]))]))
        let result = await watch.conversation("m1")
        XCTAssertEqual(result["state"], .object([.init("desk", .string("running"))]))
        await watch.dispose()
    }
    func testAnsweredAfterNeedsNewQuestionThenNonemptyAgentLastAndHandlesMissingBaseline() {
        let old = [message("1", "you", "q"), message("2", "agent", "a")]
        XCTAssertFalse(BackendDeckToolsMachinesWatch.answeredAfter(old, since: "2"))
        XCTAssertFalse(BackendDeckToolsMachinesWatch.answeredAfter(old + [message("3", "you", "q2")], since: "2"))
        XCTAssertTrue(BackendDeckToolsMachinesWatch.answeredAfter(old + [message("3", "you", "q2"), message("4", "agent", "a2")], since: "2"))
        XCTAssertTrue(BackendDeckToolsMachinesWatch.answeredAfter([message("5", "you", "q"), message("6", "agent", "a")], since: "gone"))
        XCTAssertFalse(BackendDeckToolsMachinesWatch.answeredAfter([message("5", "you", "q"), message("6", "agent", "   ")], since: nil))
    }
    func testReplySettlesOnlyNewQuestionAndNewAnswerAfterLastUpdate() async {
        let clock=BackendDeckCoreTestPortSessionsManualClock(),watch=BackendDeckToolsMachinesWatch(clock:clock)
        await chat(watch,run:"r1",messages:[message("1","you","old"),message("2","agent","old answer")],reset:true)
        let answered=Task{await watch.replied("m1",since:"2",ceilingMS:10_000,settleMS:1000)}
        await clock.waitForScheduled(1);clock.advance(1500)
        await chat(watch,run:"r1",messages:[message("3","you","new question")])
        await chat(watch,run:"r1",messages:[message("4","agent","the start of")]);await clock.waitForScheduled(2)
        clock.advance(500)
        await chat(watch,run:"r1",messages:[message("4","agent","the start of the new answer")]);await clock.waitForScheduled(3)
        clock.advance(1001)
        let result=await answered.value;XCTAssertTrue(result);XCTAssertEqual(clock.pendingCount,0)
        await watch.dispose()
    }
    func testReplyAnswersFalseAtFakeCeilingWhenNothingArrives() async {
        let clock=BackendDeckCoreTestPortSessionsManualClock(),watch=BackendDeckToolsMachinesWatch(clock:clock)
        let answered=Task{await watch.replied("m1",since:nil,ceilingMS:2000,settleMS:500)}
        await clock.waitForScheduled(1);clock.advance(2001)
        let result=await answered.value;XCTAssertFalse(result)
        await watch.dispose()
    }
    func testFirstReadHearsNextChangeAfterWaiterInstalled() async throws {
        let clock=BackendDeckCoreTestPortSessionsManualClock(),watch=BackendDeckToolsMachinesWatch(clock:clock)
        let changed=Task{try await watch.nextChange("m1",ceilingMS:1000,after:{})}
        await clock.waitForScheduled(1)
        await watch.pushed("machines:copilot:state",object([("machineId",.string("m1")),("state",.object([.init("desk",.string("stopped"))]))]))
        let result=try await changed.value;XCTAssertTrue(result);XCTAssertEqual(clock.pendingCount,0)
        await watch.dispose()
    }
}

final class BackendDeckCoreTestPortSessionsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var current: Double { lock.withLock { value } }
    func next() -> Double { lock.withLock { value += 1; return value } }
}
