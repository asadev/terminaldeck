import XCTest
@testable import TerminalDeckNativeCore

final class ChatWorkingStateTests: XCTestCase {
    private func event(_ n: Int, _ record: HootChatRecord) -> HootChatEvent {
        .init(conversationID: "scratch", turnID: "turn", sequence: n, provider: .codex, record: record, at: 1_800_000_000_000)
    }
    private func snapshot(_ busy: Bool, children: [NativeRPCValue] = []) -> NativeRPCValue {
        .object([.init("alive", .bool(true)), .init("busy", .bool(busy)), .init("children", .array(children))])
    }
    func testNoActivityIsInferredFromOldUnfinishedText() {
        XCTAssertFalse(ChatWorkingState.read(snapshot(false), events: [event(1, .text(.user, "unfinished"))]).active)
        XCTAssertFalse(ChatWorkingState.read(.object([])).active)
    }
    func testProviderBusyKeepsThinkingAcrossSilenceAndUsesTheEventTime() {
        let events = [event(1, .text(.user, "work"))]
        let first = ChatWorkingState.read(snapshot(true), events: events)
        XCTAssertTrue(first.active)
        XCTAssertEqual(first.detail, "thinking")
        XCTAssertEqual(first.elapsed(at: 1_800_000_134_000), "2m 14s")
        XCTAssertEqual(ChatWorkingState.read(snapshot(true), events: events), first)
    }
    func testCommandAndPartialOutputRemainWorkingUntilTheProviderFinishes() {
        var events = [event(1, .text(.user, "work")), event(2, .init(.toolCall, id: "cmd", value: .object([.init("name", .string("Bash"))])))]
        events.append(event(3, .init(.toolResult, id: "cmd", value: .object([.init("partial", .bool(true))]))))
        XCTAssertEqual(ChatWorkingState.read(snapshot(true), events: events).detail, "running a command")
        events.append(event(4, .init(.toolResult, id: "cmd")))
        XCTAssertTrue(ChatWorkingState.read(snapshot(true), events: events).active, "A tool finishing is not the end of the turn")
        events.append(event(5, .init(.completed)))
        XCTAssertFalse(ChatWorkingState.read(snapshot(false), events: events).active)
    }
    func testStreamingIsReportedAsReplying() {
        XCTAssertEqual(ChatWorkingState.read(snapshot(true), events: [event(1, .text(.textDelta, "word"))]).detail, "replying")
    }
    func testReportedChildrenKeepTheLineUntilTheyReallyFinish() {
        let running = ChatChildTasks.codexAgent("child", status: "running")
        let state = ChatWorkingState.read(snapshot(false, children: [running]))
        XCTAssertTrue(state.active)
        XCTAssertEqual(state.detail, "waiting on an agent")
        XCTAssertNil(state.since, "No invented start time when history is absent")
        XCTAssertFalse(ChatWorkingState.read(snapshot(false, children: [running.setting("status", .string("completed"))])).active)
    }
    func testBackgroundTaskAndApprovalHavePlainLabels() {
        let task = NativeRPCValue.object([.init("status", .string("running")), .init("kind", .string("task"))])
        XCTAssertEqual(ChatWorkingState.read(snapshot(false, children: [task])).detail, "running a background task")
        XCTAssertEqual(ChatWorkingState.read(snapshot(true).setting("pending", .array([.object([])]))).detail, "waiting for you")
    }
    func testDeadOrFinishedChatCannotKeepAnOldChildWorking() {
        let state = snapshot(true, children: [ChatChildTasks.codexAgent("old", status: "running")])
        XCTAssertTrue(ChatWorkingState.isActive(state))
        XCTAssertFalse(ChatWorkingState.isActive(state.setting("alive", .bool(false))))
        XCTAssertFalse(ChatWorkingState.read(state.setting("alive", .bool(false))).active)
        XCTAssertFalse(ChatWorkingState.read(state.setting("readOnly", .bool(true))).active)
    }
    func testClockDoesNotCreateActivityOrNegativeElapsedTime() {
        XCTAssertNil(ChatWorkingState.idle.elapsed(at: 1_800_000_000_000))
        let active = ChatWorkingState.read(snapshot(true), events: [event(1, .text(.user, "work"))])
        XCTAssertEqual(active.elapsed(at: 1_799_999_999_000), "0m 0s")
        XCTAssertEqual(active.wire(at: 1_800_000_134_000)["source"].string, "provider-events")
    }
    func testNewWorkDoesNotBorrowAFinishedTurnsClock() {
        let events = [event(1, .text(.user, "Earlier job")), event(2, .init(.completed))]
        let autonomous = ChatWorkingState.read(snapshot(true), events: events)
        XCTAssertTrue(autonomous.active)
        XCTAssertNil(autonomous.since)
        let child = ChatChildTasks.codexAgent("new-child", status: "running")
        XCTAssertNil(ChatWorkingState.read(snapshot(false, children: [child]), events: events).since)
        // A child explicitly linked to the original turn really is still that turn's work.
        let linked = child.setting("turnId", .string("turn"))
        XCTAssertEqual(ChatWorkingState.read(snapshot(false, children: [linked]), events: events).since, events[0].at)
    }

}
