import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class Fix29BCProjectionTests: XCTestCase {
    func testContinuationRequiresTheSameDeliveryAndTurnReceipt() {
        let user = HootChatEvent(conversationID: "chat", turnID: "turn", sequence: 1, provider: .claude,
            record: .init(.user, value: .object([.init("text", .string("held")), .init("clientMessageId", .string("delivery"))])))
        func receipt(_ id: String, turn: String) -> HootChatEvent {
            .init(conversationID: "chat", turnID: turn, sequence: 2, provider: .claude,
                record: .init(.session, value: .object([.init("clientMessageId", .string(id)), .init("deliveryConfirmed", .bool(true))])))
        }
        XCTAssertNil(BackendHootChatStore.unanswered([user]))
        XCTAssertNil(BackendHootChatStore.unanswered([user, receipt("another", turn: "turn")]))
        XCTAssertNil(BackendHootChatStore.unanswered([user, receipt("delivery", turn: "another")]))
        XCTAssertEqual(BackendHootChatStore.unanswered([user, receipt("delivery", turn: "turn")])?.text, "held")
        let legacy = HootChatEvent(conversationID: "chat", turnID: "old", sequence: 1, provider: .claude, record: .text(.user, "legacy held"))
        var queued = BackendHootQueuedMessage(id: "old", text: "legacy held", attachments: [], context: .object([]), caller: .local)
        queued.deliveryPending = true
        XCTAssertNil(BackendHootChatStore.unanswered([legacy], uncertain: [queued]))
    }

    func testLegacyUncertainDeliveryStaysHeldAfterQueueRemovalAndAnotherRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fix29-legacy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("chat.json")
        let user = HootChatEvent(conversationID: "legacy", turnID: "uncertain", sequence: 1, provider: .claude,
            record: .text(.user, "legacy held"), at: Date().timeIntervalSince1970 * 1000 - 1000)
        var queued = BackendHootQueuedMessage(id: "legacy-delivery", text: "legacy held", attachments: [], context: .object([]), caller: .local)
        queued.deliveryPending = true
        let saved = NativeRPCValue.object([.init("provider", .string("claude")), .init("conversationId", .string("legacy")),
            .init("events", .array([user.wireValue])), .init("queuedMessages", .array([queued.wire]))])
        try saved.encodedJSON().write(to: file)
        let reopened = try BackendHootChatStore(file: file)
        _ = try await reopened.queueFeature("queue/remove", arguments: .object([.init("id", .string("legacy-delivery"))]))
        let again = try BackendHootChatStore(file: file)
        let continuation = await again.takeContinuation()
        XCTAssertNil(continuation)
        let snapshot = await again.snapshot()
        XCTAssertEqual(snapshot["events"].elements?.first?["value"]["clientMessageId"].string, "legacy-delivery")
        XCTAssertEqual(snapshot["resuming"].bool, false)
    }

    func testPeerReceiptContainsOnlyAcceptanceAndCanonicalIDs() {
        let privateSnapshot = NativeRPCValue.object([.init("events", .array([.string("private history")])),
            .init("pending", .array([.string("private control")])), .init("thoughts", .array([.string("private thought")])),
            .init("conversationId", .string("private-store")), .init("queued", .bool(true))])
        let receipt = BackendSessionDirectory.sayReceipt(privateSnapshot, sessionID: "canonical-app", messageID: "canonical-delivery", canRead: false)
        XCTAssertEqual(receipt, .object([.init("accepted", .bool(true)), .init("sessionId", .string("canonical-app")),
            .init("clientMessageId", .string("canonical-delivery")), .init("queued", .bool(true))]))
        let readable = BackendSessionDirectory.sayReceipt(privateSnapshot, sessionID: "canonical-app", messageID: "canonical-delivery", canRead: true)
        XCTAssertEqual(readable["events"], privateSnapshot["events"])
    }

    func testDirectoryAndTurnIgnoreBackgroundBusyAfterForegroundCompletes() {
        let rows = [HootChatEvent(conversationID: "chat", turnID: "answer", sequence: 1, provider: .claude, record: .text(.user, "question")),
            HootChatEvent(conversationID: "chat", turnID: "answer", sequence: 2, provider: .claude, record: .text(.message, "finished")),
            HootChatEvent(conversationID: "chat", turnID: "answer", sequence: 3, provider: .claude, record: .init(.completed))]
        let child = NativeRPCValue.object([.init("id", .string("watcher")), .init("status", .string("running"))])
        let snapshot = NativeRPCValue.object([.init("alive", .bool(true)), .init("busy", .bool(true)), .init("foreground", .bool(false)),
            .init("answering", .bool(false)), .init("children", .array([child])), .init("events", .array(rows.map(\.wireValue)))])
        XCTAssertEqual(BackendSessionDirectory.status(snapshot), .completed)
        XCTAssertEqual(BackendSessionChats.wire(BackendSessionChats.turn(of: snapshot))["state"].string, "done")
        XCTAssertEqual(snapshot["children"].elements, [child])
        let noTurn = snapshot.setting("events", .array([]))
        XCTAssertEqual(BackendSessionDirectory.status(noTurn), .idle)
        XCTAssertEqual(BackendSessionChats.wire(BackendSessionChats.turn(of: noTurn))["state"].string, "idle")
        let working = snapshot.setting("foreground", .bool(true))
        XCTAssertEqual(BackendSessionDirectory.status(working), .working)
        XCTAssertEqual(BackendSessionChats.wire(BackendSessionChats.turn(of: working))["state"].string, "working")
    }
}
