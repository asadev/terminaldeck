import Foundation
import XCTest

/// U109 (#548): Remove worktree asks first, like Restore files does. A source guard: the delete call lives only
/// in the confirm, so one click never removes the checkout.
final class ChatSessionExtrasTests: XCTestCase {
    func testRemoveWorktreeAsksBeforeDeleting() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative/NativeChatSessionExtras.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains(#"Button("Remove worktree…") { confirmRemoveWorktree = true }"#))
        let alert = try XCTUnwrap(source.range(of: #".alert("Remove this chat's worktree?", isPresented: $confirmRemoveWorktree)"#))
        let remove = try XCTUnwrap(source.range(of: #""worktree-remove""#))
        XCTAssertGreaterThan(remove.lowerBound, alert.lowerBound)
        XCTAssertEqual(source.components(separatedBy: #""worktree-remove""#).count, 2)
    }
}
