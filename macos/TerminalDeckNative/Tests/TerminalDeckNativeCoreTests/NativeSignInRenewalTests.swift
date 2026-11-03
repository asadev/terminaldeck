import XCTest
import Darwin
@testable import TerminalDeckNativeCore

/// Claude Code's sign-in renewal must never be cut by a stop (saba-pc 1 Nov; this Mac 28 Oct).
final class NativeSignInRenewalTests: XCTestCase {
    private var root: URL!
    private var folder: String { root.appendingPathComponent(".claude").path }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("renewal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root.appendingPathComponent(".claude").path, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func hold() throws -> String {
        let lock = (folder as NSString).appendingPathComponent(".oauth_refresh.lock")
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false); return lock
    }

    func testFolderIsClaudesOwnOrTheUsersDotClaude() {
        XCTAssertEqual(NativeSignInRenewal.folder(environment: ["CLAUDE_CONFIG_DIR": "/x/agent", "HOME": "/Users/a"]), "/x/agent")
        XCTAssertEqual(NativeSignInRenewal.folder(environment: ["HOME": "/Users/a"]), "/Users/a/.claude")
        XCTAssertNil(NativeSignInRenewal.folder(environment: ["CLAUDE_CONFIG_DIR": "relative"]))
        XCTAssertEqual(NativeSignInRenewal.folder(command: "/opt/bin/claude", environment: ["HOME": "/Users/a"]), "/Users/a/.claude")
        XCTAssertEqual(NativeSignInRenewal.folder(command: "/usr/bin/node", arguments: ["/lib/@anthropic-ai/claude-code/cli.js"], environment: ["HOME": "/Users/a"]), "/Users/a/.claude")
        XCTAssertNil(NativeSignInRenewal.folder(command: "/opt/bin/codex", arguments: ["exec"], environment: ["HOME": "/Users/a"]))
    }

    func testOnlyAFreshLockCountsAsARenewal() throws {
        XCTAssertFalse(NativeSignInRenewal.inProgress(folder))
        let lock = try hold()
        XCTAssertTrue(NativeSignInRenewal.inProgress(folder))
        // Claude Code treats a lock untouched for 60 s as abandoned; so does the app.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-61)], ofItemAtPath: lock)
        XCTAssertFalse(NativeSignInRenewal.inProgress(folder))
        try FileManager.default.removeItem(atPath: lock)
        try FileManager.default.createDirectory(atPath: folder + ".lock", withIntermediateDirectories: false)
        XCTAssertTrue(NativeSignInRenewal.inProgress(folder + "/"))
        XCTAssertFalse(NativeSignInRenewal.inProgress(nil))
    }

    func testAClaudeChildIsNotStoppedWhileItsRenewalIsHeld() async throws {
        let lock = try hold()
        let child = try NativeChild.start(.init("/bin/sleep", ["30"], input: .pipe))
        child.claudeFolder = folder
        child.terminate(grace: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertTrue(child.isRunning, "stopped during a sign-in renewal")
        try FileManager.default.removeItem(atPath: lock)
        let end = await child.exited()
        XCTAssertEqual(end.signal, SIGTERM)
    }

    func testClaudeIsAskedAloneFirstSoItsKeychainWriterIsNotEndedMidSave() async throws {
        let ready = root.appendingPathComponent("ready").path, mark = root.appendingPathComponent("writer-got-term").path
        // A child of the leader standing in for Claude Code's `security` writer: a group SIGTERM would reach it.
        let script = "(trap 'echo term > \(mark); exit 0' TERM; touch \(ready); while :; do sleep 0.1; done) & wait"
        let child = try NativeChild.start(.init("/bin/sh", ["-c", script], input: .pipe))
        child.claudeFolder = folder
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready) { try await Task.sleep(for: .milliseconds(20)) }
        child.terminate(grace: .milliseconds(300))
        _ = await child.exited()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mark), "the first stop signal reached the whole group")
    }

    func testOtherProgramsKeepTheGroupStop() async throws {
        let child = try NativeChild.start(.init("/bin/sleep", ["30"], input: .pipe))
        let started = Date()
        child.terminate(grace: .milliseconds(200))
        let end = await child.exited()
        XCTAssertEqual(end.signal, SIGTERM); XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
