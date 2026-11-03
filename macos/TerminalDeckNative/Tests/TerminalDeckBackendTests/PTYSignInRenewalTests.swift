import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ending a terminal (stop, account switch, quit, host swap) never cuts Claude Code's sign-in renewal.
final class PTYSignInRenewalTests: XCTestCase, @unchecked Sendable {
    func testATerminalWaitsForAClaudeRenewalBeforeItsHangUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pty-renewal-\(UUID().uuidString)")
        let config = root.appendingPathComponent("claude-home"), lock = config.appendingPathComponent(".oauth_refresh.lock")
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = DispatchQueue(label: "pty.renewal"), exited = expectation(description: "terminal ended")
        let process = try BackendPTYProcess.spawn(command: "/bin/sleep", args: ["30"], environment: ["CLAUDE_CONFIG_DIR": config.path],
                                                  cwd: root.path, cols: 80, rows: 24, queue: queue)
        queue.sync { process.onExit = { _ in exited.fulfill() }; process.start(); process.terminate() }
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(Darwin.kill(process.pid, 0), 0, "ended during a sign-in renewal")
        try FileManager.default.removeItem(at: lock)
        await fulfillment(of: [exited], timeout: 5)
    }

    /// Post-24 (lane mac-signin-renewal "Left"): the host's drain waits as long as a renewal may hold a stop, so a
    /// swap or quit never gives up early and lets the kernel's hang-up cut it.
    func testTheDrainWaitsOutARenewal() {
        XCTAssertEqual(BackendPTYManager.drainWait(2_000, renewing: false), 2_000)
        XCTAssertEqual(BackendPTYManager.drainWait(-5, renewing: false), 0)
        XCTAssertEqual(BackendPTYManager.drainWait(2_000, renewing: true), Int(NativeSignInRenewal.patience * 1000) + 1_000)
        XCTAssertEqual(BackendPTYManager.drainWait(90_000, renewing: true), 90_000)
    }

    /// Recovery after a host crash freezes and kills a dead host's session: its record now names Claude's folder
    /// (only the path) so the stop waits for a renewal first. Journals written before this still read.
    func testAnOrphanRecordKeepsClaudesFolderAndOldJournalsStillRead() throws {
        let identity = try XCTUnwrap(try BackendHOSTOrphanDarwin.inspect(getpid()))
        let record = BackendHOSTOrphanRecord(sessionID: "s", owner: identity, rootPID: 2, processes: [], renewalFolder: "/x/claude")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual(object["renewalFolder"] as? String, "/x/claude")
        object["renewalFolder"] = nil // a journal written before this change
        let decoded = try JSONDecoder().decode(BackendHOSTOrphanRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.renewalFolder)
        XCTAssertEqual(NativeSignInRenewal.folder(command: "/opt/homebrew/bin/claude", arguments: [], environment: ["CLAUDE_CONFIG_DIR": "/x/claude"]), "/x/claude")
        XCTAssertNil(NativeSignInRenewal.folder(command: "/bin/zsh", arguments: [], environment: ["HOME": "/Users/x"]))
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend/BackendHOSTRuntime.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "renewalFolder: NativeSignInRenewal.folder(command: launch.command").count - 1, 2,
                       "both host launches (sessions and chats) record the folder")
        let command = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend/BackendAppSessionCommand.swift"), encoding: .utf8)
        XCTAssertTrue(command.contains("child.claudeFolder = NativeSignInRenewal.folder(command: executable"), "app session commands stop Claude safely")
    }
}
