import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatArtifactsTests: XCTestCase {
    func testOnlyRealEmittedStructuredResultsAreIndexedAndFollowUpdates() {
        func event(_ n: Int, _ kind: HootChatKind, _ value: NativeRPCValue) -> HootChatEvent { .init(conversationID: "c", turnID: "t", sequence: n, provider: .codex, record: .init(kind, value: value)) }
        let source = NativeRPCValue.object([.init("url", .string("https://example.com/source")), .init("title", .string("Real source"))])
        let first = event(1, .toolResult, .object([.init("sources", .array([source, source]))]))
        let ignored = event(2, .toolCall, .object([.init("path", .string("/unwritten/plan.txt"))]))
        let file = event(3, .toolResult, .object([.init("path", .string("/scratch/result.txt"))]))
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("c")), .init("events", .array([first.wireValue, ignored.wireValue]))]))
        XCTAssertEqual(model.chatArtifacts.count, 1)
        XCTAssertEqual(model.chatArtifacts.count, 1)
        XCTAssertEqual(model.detailRecords("Real source").count, 1)
        XCTAssertTrue(model.chatReviewFindings.isEmpty)
        let revision = model.transcriptRevision
        model.acceptFixtureUpdate(.object([.init("conversationId", .string("c")), .init("sequence", .number(3)), .init("events", .array([file.wireValue]))]))
        let indexed = model.chatArtifacts
        XCTAssertEqual(indexed.count, 2); XCTAssertEqual(indexed.last?.kind, "file")
        XCTAssertGreaterThan(model.transcriptRevision, revision)
        XCTAssertFalse(indexed.contains { $0.destination.contains("unwritten") })
    }
}
