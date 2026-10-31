import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatTerminalContextTests: XCTestCase {
    func testSelectedOutputIsExactVersionedQuotedContextAndPreservesDraftWithoutProcessAccess() throws {
        func event(_ n: Int, _ record: HootChatRecord) -> HootChatEvent { .init(conversationID: "c", turnID: "t", sequence: n, provider: .codex, record: record) }
        let call = event(1, .init(.toolCall, id: "cmd", value: .object([.init("name", .string("Bash")), .init("input", .object([.init("command", .string("recorded command"))]))])))
        let result = event(2, .init(.toolResult, id: "cmd", value: .object([.init("output", .string("one\n```\nthree\nfour"))])))
        var draft = HootComposerDraft()
        draft.text = "Keep"; draft.add([URL(fileURLWithPath: "/scratch/reference.txt")])
        let entries = NativeChatTerminalContext.entries(rows: HootChatProjection.rows([call, result]), events: [call, result])
        let entry = try XCTUnwrap(entries.first)
        let (text, receipt) = try NativeChatTerminalContext.prepare(entries: entries, request: entry.id, range: "2:3", existingText: draft.text)
        draft.text = text
        XCTAssertTrue(draft.text.hasPrefix("Keep\n\nRecorded command/output context"))
        XCTAssertTrue(draft.text.contains("````text")); XCTAssertTrue(draft.text.contains("```\nthree"))
        XCTAssertEqual(draft.attachments.count, 1)
        XCTAssertEqual(receipt["firstLine"].number, 2); XCTAssertEqual(receipt["lastLine"].number, 3)
        XCTAssertEqual(receipt["deliveryConfirmed"].bool, false)
        XCTAssertEqual(receipt["selectedSHA256"].string, NativeChatTerminalContext.hash("```\nthree"))
        let changed = event(3, .init(.toolResult, id: "cmd", value: .object([.init("output", .string("changed"))])))
        let latest = NativeChatTerminalContext.entries(rows: HootChatProjection.rows([call, result, changed]), events: [call, result, changed])
        XCTAssertThrowsError(try NativeChatTerminalContext.prepare(entries: latest, request: entry.id, range: nil, existingText: draft.text))
        XCTAssertThrowsError(try NativeChatTerminalContext.selection(entry, range: "0:9"))
    }
}
