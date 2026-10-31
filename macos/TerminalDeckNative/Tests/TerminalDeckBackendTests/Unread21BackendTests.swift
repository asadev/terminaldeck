import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class Unread21BackendTests: XCTestCase, @unchecked Sendable {
    func testReadReceiptPersistsAndAppearsInEverySnapshotIncludingBoundedReads() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unread21-backend-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("chat.json")
        let events = (1...4).map { n in HootChatEvent(conversationID: "c", turnID: "t\(n)", sequence: n,
            provider: .claude, record: .text(n == 1 ? .user : .message, id: "m\(n)", "Message \(n)")) }
        try NativeRPCValue.object([.init("provider", .string("claude")), .init("conversationId", .string("c")),
            .init("events", .array(events.map(\.wireValue)))]).encodedJSON().write(to: file)
        let store = try BackendHootChatStore(file: file)
        let initial = await store.snapshot(limit: 1)
        XCTAssertEqual(initial["events"].elements?.count, 1)
        XCTAssertEqual(initial["unread"]["count"].number, 3)
        try await store.setSeenSequence(2, conversation: "c")
        let restored = try BackendHootChatStore(file: file)
        let read = await restored.snapshot()
        XCTAssertEqual(read["unread"]["seenSequence"].number, 2)
        XCTAssertEqual(read["unread"]["count"].number, 2)
        XCTAssertEqual(read["unread"]["firstSequence"].number, 3)
        try await restored.setSeenSequence(4, conversation: "c")
        let otherWindow = await store.snapshot()
        XCTAssertEqual(otherWindow["unread"]["count"].number, 0)
        do { try await store.setSeenSequence(5, conversation: "c"); XCTFail("Future marker was accepted") } catch {}
        try await store.rebindProvider(.codex)
        let switched = try BackendHootChatStore(file: folder.appendingPathComponent("chat-codex.json"), provider: .codex)
        let switchedRead = await switched.snapshot()
        XCTAssertEqual(switchedRead["unread"]["seenSequence"].number, 4, "The same chat stays read across an AI switch and restart")
        do { try await store.setSeenSequence(1, conversation: "old"); XCTFail("Old conversation was accepted") } catch {}
    }
}
