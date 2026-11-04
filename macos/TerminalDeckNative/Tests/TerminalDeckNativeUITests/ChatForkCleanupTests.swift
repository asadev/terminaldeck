import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatForkCleanupTests: XCTestCase {
    func testSeedOrEnsureFailureClosesNewSessionBeforeRemovingWorktree() async {
        var steps: [String] = []
        let result = await NativeChatForkCleanup.run(sessionID: "new-session", worktreeKey: "owned-worktree", close: { id in
            steps.append("close:" + id)
        }, remove: { key in
            steps.append("remove:" + key)
            return .object([.init("ok", .bool(true))])
        })
        XCTAssertEqual(steps, ["close:new-session", "remove:owned-worktree"])
        XCTAssertTrue(result.sessionRemoved); XCTAssertTrue(result.worktreeRemoved); XCTAssertTrue(result.errors.isEmpty)
    }
    func testCreationFailureRemovesOnlyNewWorktree() async {
        var removed: [String] = []
        let result = await NativeChatForkCleanup.run(sessionID: nil, worktreeKey: "owned-worktree", close: { _ in XCTFail("Nothing was created") }, remove: { key in
            removed.append(key); return .object([.init("ok", .bool(true))])
        })
        XCTAssertEqual(removed, ["owned-worktree"])
        XCTAssertTrue(result.sessionRemoved && result.worktreeRemoved)
    }
    func testFailedCloseKeepsRunningWorkspaceAndReportsPartialCreation() async {
        let result = await NativeChatForkCleanup.run(sessionID: "new-session", worktreeKey: "owned-worktree", close: { _ in
            throw NativeRPCError(code: "unavailable", message: "The child did not stop")
        }, remove: { _ in XCTFail("Never remove a running child's folder"); return .null })
        XCTAssertFalse(result.sessionRemoved); XCTAssertFalse(result.worktreeRemoved)
        XCTAssertEqual(result.errors.count, 1)
    }
    func testDirtyWorktreeRefusalStaysRecordedForManualCleanup() async {
        let result = await NativeChatForkCleanup.run(sessionID: "new-session", worktreeKey: "owned-worktree", close: { _ in }, remove: { _ in
            .object([.init("ok", .bool(false)), .init("message", .string("Uncommitted changes were kept"))])
        })
        XCTAssertTrue(result.sessionRemoved); XCTAssertFalse(result.worktreeRemoved)
        XCTAssertEqual(result.errors, ["Uncommitted changes were kept"])
    }
}
