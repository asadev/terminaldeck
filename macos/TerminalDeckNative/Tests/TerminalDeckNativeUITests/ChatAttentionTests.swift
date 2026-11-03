import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatAttentionTests: XCTestCase {
    private func snapshot(_ sequence: Int, completed: Bool = false, pending: String? = nil) -> NativeRPCValue {
        let event = HootChatEvent(conversationID: "conversation", turnID: "t", sequence: sequence, provider: .codex, record: .init(completed ? .completed : .user))
        return .object([.init("conversationId", .string("conversation")), .init("busy", .bool(!completed)), .init("events", .array([event.wireValue])), .init("pending", .array(pending.map { [.object([.init("requestId", .string($0))])] } ?? []))])
    }
    func testCompletionAndInputUseInjectedSinkOnceWithoutOSDelivery() async {
        var kinds: [String] = []
        let attention = NativeChatAttention { notice in kinds.append(notice.kind); return "accepted by isolated sink" }
        await attention.receive(snapshot(1, completed: true), source: "isolated", complete: true, input: true, visible: false)
        XCTAssertTrue(kinds.isEmpty, "Initial completed history must stay silent")
        await attention.receive(snapshot(2), source: "isolated", complete: true, input: true, visible: false)
        await attention.receive(snapshot(3, completed: true), source: "isolated", complete: true, input: true, visible: false)
        await attention.receive(snapshot(3, completed: true), source: "isolated", complete: true, input: true, visible: false)
        await attention.receive(snapshot(4, pending: "approval"), source: "isolated", complete: true, input: true, visible: false)
        await attention.receive(snapshot(4, pending: "approval"), source: "isolated", complete: true, input: true, visible: false)
        XCTAssertEqual(kinds, ["completed", "input-needed"])
        XCTAssertEqual(attention.last["isolated"], "accepted by isolated sink")
    }
    func testPreferencesVisibilityAndDeferredStartupDoNotReplayCompletionHistory() {
        var paged = NativeChatNoticeTracker()
        let empty: NativeRPCValue = .object([.init("conversationId", .string("conversation")), .init("sequence", .number(100)), .init("events", .array([]))])
        XCTAssertTrue(paged.consume(empty, source: "paged", complete: true, input: true, visible: false).isEmpty)
        XCTAssertTrue(paged.consume(snapshot(90, completed: true), source: "paged", complete: true, input: true, visible: false).isEmpty, "Older pages cannot announce a fresh completion")
        var tracker = NativeChatNoticeTracker()
        tracker.prime(snapshot(1), source: "cold")
        XCTAssertEqual(tracker.consume(snapshot(2, completed: true), source: "cold", complete: true, input: true, visible: false).count, 1)
        XCTAssertTrue(tracker.consume(snapshot(3, pending: "seen"), source: "cold", complete: true, input: true, visible: true).isEmpty)
        XCTAssertTrue(tracker.consume(snapshot(4, completed: true), source: "cold", complete: false, input: false, visible: false).isEmpty)
        XCTAssertTrue(tracker.consume(snapshot(4, completed: true), source: "cold", complete: true, input: true, visible: false).isEmpty)
    }
    private func event(_ sequence: Int, _ kind: HootChatKind, turn: String = "foreground", conversation: String = "conversation", value: NativeRPCValue = .null) -> NativeRPCValue {
        HootChatEvent(conversationID: conversation, turnID: turn, sequence: sequence, provider: .codex, record: .init(kind, value: value)).wireValue
    }
    private func state(_ sequence: Int, _ events: [NativeRPCValue] = [], busy: Bool = true, conversation: String = "conversation") -> NativeRPCValue {
        .object([.init("conversationId", .string(conversation)), .init("sequence", .number(Double(sequence))),
            .init("busy", .bool(busy)), .init("events", .array(events)), .init("pending", .array([]))])
    }
    private func consume(_ tracker: inout NativeChatNoticeTracker, _ snapshot: NativeRPCValue, visible: Bool = false, complete: Bool = true) -> [String] {
        tracker.consume(snapshot, source: "scope", complete: complete, input: true, visible: visible).map(\.kind)
    }
    func testActualRequestIdAndLegacyIdAreDeduplicatedWithActualIdPreferred() {
        var tracker = NativeChatNoticeTracker()
        XCTAssertEqual(consume(&tracker, snapshot(1, pending: "actual")), ["input-needed"])
        XCTAssertTrue(consume(&tracker, snapshot(1, pending: "actual")).isEmpty)
        let legacy = snapshot(2).setting("pending", .array([.object([.init("id", .string("legacy"))])]))
        XCTAssertEqual(consume(&tracker, legacy), ["input-needed"])
        let both = snapshot(3, pending: "actual").setting("pending", .array([.object([.init("requestId", .string("actual")), .init("id", .string("different"))])]))
        XCTAssertTrue(consume(&tracker, both).isEmpty)
    }
    func testActualForegroundCompletionWaitsForIdleWithoutAnotherProviderRecord() {
        var tracker = NativeChatNoticeTracker()
        _ = consume(&tracker, state(1, [event(1, .user)]))
        XCTAssertTrue(consume(&tracker, state(2, [event(2, .completed)])).isEmpty)
        let taskFinished = event(3, .session, value: .object([.init("taskFinished", .string("child"))]))
        XCTAssertTrue(consume(&tracker, state(3, [taskFinished])).isEmpty)
        XCTAssertEqual(consume(&tracker, state(4, busy: false)), ["completed"])
        XCTAssertTrue(consume(&tracker, state(4, busy: false)).isEmpty)
        XCTAssertTrue(consume(&tracker, state(2, [event(2, .completed)], busy: false)).isEmpty, "Older history cannot replay the receipt")
    }
    func testCompletionOwnershipDoesNotCrossNewTurnConversationOrHiddenBackgroundTurn() {
        var tracker = NativeChatNoticeTracker()
        _ = consume(&tracker, state(1, [event(1, .user)]))
        _ = consume(&tracker, state(2, [event(2, .completed)]))
        let started = event(3, .session, turn: "provider:next", value: .object([.init("providerTurnStarted", .object([.init("providerTurnId", .string("next"))]))]))
        _ = consume(&tracker, state(3, [started]))
        XCTAssertTrue(consume(&tracker, state(4, [event(4, .completed)], busy: false)).isEmpty, "Late old turn completion cannot finish the newer provider-owned turn")
        XCTAssertTrue(consume(&tracker, state(5, [event(5, .completed, turn: "bg:task:hidden")], busy: false)).isEmpty)
        XCTAssertTrue(consume(&tracker, state(6, [event(6, .completed, turn: "provider:next", conversation: "foreign")], busy: false)).isEmpty)
        XCTAssertEqual(consume(&tracker, state(7, [event(7, .completed, turn: "provider:next")], busy: false)), ["completed"])
        _ = consume(&tracker, state(8, [event(8, .user, turn: "third")]))
        _ = consume(&tracker, state(9, [event(9, .completed, turn: "third")]))
        XCTAssertTrue(consume(&tracker, state(1, busy: false, conversation: "replacement")).isEmpty)
        XCTAssertTrue(consume(&tracker, state(2, busy: false, conversation: "replacement")).isEmpty)
    }
    func testVisibleDisabledAndInterruptedCompletionsDoNotBecomeDelayedBanners() {
        for suppression in ["visible", "disabled", "interrupted"] {
            var tracker = NativeChatNoticeTracker()
            _ = consume(&tracker, state(1, [event(1, .user)]))
            _ = consume(&tracker, state(2, [event(2, .completed)]), visible: suppression == "visible", complete: suppression != "disabled")
            if suppression == "interrupted" { _ = consume(&tracker, state(3, [event(3, .interrupted)])) }
            XCTAssertTrue(consume(&tracker, state(4, busy: false)).isEmpty, suppression)
        }
    }
    func testReusedProviderRequestIdWithANewHelperNonceNeedsFreshAttention() {
        var tracker = NativeChatNoticeTracker()
        func pending(_ sequence: Int, _ nonce: String) -> NativeRPCValue {
            snapshot(sequence, pending: "same-provider-id").setting("pending", .array([.object([
                .init("requestId", .string("same-provider-id")), .init("approvalNonce", .string(nonce))])]))
        }
        XCTAssertEqual(consume(&tracker, pending(1, "lifetime-one")), ["input-needed"])
        XCTAssertTrue(consume(&tracker, pending(1, "lifetime-one")).isEmpty)
        XCTAssertEqual(consume(&tracker, pending(2, "lifetime-two")), ["input-needed"])
        XCTAssertTrue(consume(&tracker, pending(2, "lifetime-two")).isEmpty)
    }

}
