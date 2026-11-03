import XCTest
@testable import TerminalDeckNativeCore

final class Unread21MarkerTests: XCTestCase {
    func testSavedMarkerSurvivesRestartAndNeverMovesBackwards() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unread21-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("seen.json")
        let markers = ChatSeenMarkers(file: file)
        XCTAssertEqual(try markers.sequence(for: "hoot"), 0)
        try markers.advance(8, conversation: "hoot")
        let restored = ChatSeenMarkers(file: file)
        XCTAssertEqual(try restored.sequence(for: "hoot"), 8)
        XCTAssertEqual(try restored.sequence(for: "team"), 0)
        try restored.advance(4, conversation: "hoot")
        XCTAssertEqual(try markers.sequence(for: "hoot"), 8)
        try restored.advance(11, conversation: "team")
        XCTAssertEqual(try markers.sequence(for: "team"), 11)
    }
    func testOwnMessagesAndHiddenStepsNeverBecomeNewAndStreamingIsOneMessage() {
        func event(_ n: Int, _ kind: HootChatKind, _ id: String, turn: String = "t") -> HootChatEvent {
            .init(conversationID: "c", turnID: turn, sequence: n, provider: .claude, record: .text(kind, id: id, "Words"))
        }
        let events = [event(1, .user, "own"), event(2, .message, "first"), event(3, .textDelta, "first"),
            event(4, .toolCall, "tool"), event(5, .message, "hidden", turn: "bg:job"), event(6, .user, "own2"), event(7, .message, "second")]
        let unread = ChatUnreadMessages.summary(events, seen: 0)
        XCTAssertEqual(unread["count"].number, 2)
        XCTAssertEqual(unread["firstMessageId"].string, "t:first")
        XCTAssertEqual(unread["firstSequence"].number, 3)
        XCTAssertEqual(ChatUnreadMessages.summary(events, seen: 3)["count"].number, 1)
    }
    func testAnUpdatedCardIsOneUnreadMessageAtItsOriginalPlace() {
        let routing = NativeRPCValue.object([.init("routing", .object([.init("id", .string("route"))]))])
        let events = [1, 3].map { sequence in HootChatEvent(conversationID: "c", turnID: "t", sequence: sequence,
            provider: .claude, record: .init(.message, id: "update\(sequence)", value: routing)) }
        let messages = ChatUnreadMessages.messages(events)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.id, "t:update1")
        XCTAssertEqual(messages.first?.sequence, 3)
        XCTAssertEqual(ChatUnreadMessages.summary(events, seen: 1)["count"].number, 1)
    }
    func testTaskRepliesAreUnreadInTheirOwnChatWhileHiddenFromHoot() {
        let events = [
            HootChatEvent(conversationID: "c", turnID: "bg:job", sequence: 1, provider: .claude,
                record: .init(.message, id: "brief", value: .object([.init("background", .object([.init("brief", .string("Do the job"))]))]))),
            HootChatEvent(conversationID: "c", turnID: "bg:job", sequence: 2, provider: .claude, record: .text(.message, id: "answer", "Job done"))]
        XCTAssertEqual(ChatUnreadMessages.summary(events, seen: 0)["count"].number, 0)
        let ownChat = ChatUnreadMessages.summary(events, seen: 0, showBackground: true)
        XCTAssertEqual(ownChat["count"].number, 1)
        XCTAssertEqual(ownChat["firstMessageId"].string, "task:job:answer")
    }
    func testThreeSecondExposureRestartsWhenHiddenOrInactive() {
        var visit = ChatUnreadVisit()
        visit.update(active: true, visible: true, now: 0)
        XCTAssertFalse(visit.ready(now: 2.99))
        visit.update(active: false, visible: true, now: 2.99)
        XCTAssertFalse(visit.ready(now: 20))
        visit.update(active: true, visible: true, now: 20)
        XCTAssertFalse(visit.ready(now: 22.99))
        XCTAssertTrue(visit.ready(now: 23))
        visit.update(active: true, visible: false, now: 23)
        XCTAssertFalse(visit.ready(now: 100))
    }
}
