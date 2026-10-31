import XCTest
import SwiftUI
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Hoot's replies render markdown (the sessions' renderer), including a list item that
/// starts with bold: "- **Working:** I'm running…" is a bullet with bold text, not literal stars.
@MainActor final class L6HootMarkdownTests: XCTestCase {
    func testListItemStartingWithBoldIsABulletWithBoldText() throws {
        let blocks = ChatMarkdown.parse("Status:\n\n- **Working:** I'm running the build\n- **Done:** 3 files changed\n\n1. First\n2. Second")
        guard blocks.count == 3, case .list(let ordered, _, let items) = blocks[1] else { return XCTFail("\(blocks)") }
        XCTAssertFalse(ordered)
        XCTAssertEqual(items.count, 2)
        guard case .paragraph(let first) = items[0].first else { return XCTFail("\(items)") }
        XCTAssertEqual(first, "**Working:** I'm running the build")
        let inline = NativeChatMarkdown.inline(first)
        XCTAssertFalse(String(inline.characters).contains("*"), "no literal asterisks")
        XCTAssertTrue(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            && String(inline[$0.range].characters) == "Working:" }, "bold run")
        guard case .list(true, _, let numbered) = blocks[2] else { return XCTFail("numbered list") }
        XCTAssertEqual(numbered.count, 2)
    }
}
