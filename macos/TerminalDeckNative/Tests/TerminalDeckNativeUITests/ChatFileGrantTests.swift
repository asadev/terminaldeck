import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U11 (#22, #539, #622): an AI allowed into one chat or folder never reaches files or worktrees beyond it.
final class ChatFileGrantTests: XCTestCase {
    func testAttachmentAndLogoFilesMustSitInsideTheCallersGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-file-grant-" + UUID().uuidString + ".noindex")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project"), elsewhere = root.appendingPathComponent("Pictures")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let inside = project.appendingPathComponent("shot.png"), outside = elsewhere.appendingPathComponent("passport.jpg")
        try Data([1]).write(to: inside); try Data([1]).write(to: outside)
        let authority = BackendFilesystemAuthority(scope: { _ in .init(readRoots: [project]) })
        let context = NativeRPCContext(caller: .page, ownerID: "core-call:test", capabilities: ["files.read"])
        let granted = try await NativeGrantedFiles.paths([inside.path], authority: authority, context: context)
        XCTAssertEqual(granted, [inside.path])
        do {
            _ = try await NativeGrantedFiles.paths([inside.path, outside.path], authority: authority, context: context)
            XCTFail("A file outside the caller's folders was accepted.")
        } catch {}
        do {
            _ = try await NativeGrantedFiles.paths([inside.path], authority: nil, context: context)
            XCTFail("Files were accepted without the app's file access.")
        } catch {}
    }

    func testWorktreeActionsReachOnlyTheChatsOwnWorktrees() {
        let own = NativeChatWorktreeLedger.Entry(key: "a", sessionID: "chat-a", parentSessionID: nil, folder: "/w/a", createdAt: 0)
        let child = NativeChatWorktreeLedger.Entry(key: "b", sessionID: "chat-b", parentSessionID: "chat-a", folder: "/w/b", createdAt: 0)
        let other = NativeChatWorktreeLedger.Entry(key: "c", sessionID: "chat-c", parentSessionID: "chat-x", folder: "/w/c", createdAt: 0)
        XCTAssertTrue(NativeChatWorktreeLedger.reachable(own, from: "chat-a"))
        XCTAssertTrue(NativeChatWorktreeLedger.reachable(child, from: "chat-a"))
        XCTAssertFalse(NativeChatWorktreeLedger.reachable(other, from: "chat-a"))
    }
}
