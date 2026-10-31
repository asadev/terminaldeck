import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendAppSessionCommandThreadsTests: XCTestCase {
    private let path = ["PATH": "/bin:/usr/bin"]

    /// #64: each slow command held one of the few Swift concurrency threads until it ended, so a handful at once
    /// (an emulator boot, a device list, a sign-in check) stalled every other actor and screens said the engine did not answer.
    func testSlowCommandsLeaveTheEngineThreadsFree() async {
        let executor = BackendAppSessionCommandExecutor(), path = path, count = ProcessInfo.processInfo.activeProcessorCount * 2
        let started = Date()
        let slow = Task {
            await withTaskGroup(of: BackendAppSessionCommandResult.self, returning: [BackendAppSessionCommandResult].self) { group in
                for _ in 0..<count {
                    group.addTask { await executor.run("sleep", arguments: ["3"], environment: path, cwd: "/", timeoutMilliseconds: 20_000) }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        let answered = await Task.detached { Date() }.value
        XCTAssertLessThan(answered.timeIntervalSince(started), 2, "Other work waited for the slow commands to end")
        let results = await slow.value
        XCTAssertEqual(results.count, count)
        XCTAssertTrue(results.allSatisfy(\.ok))
    }

    func testOutputExitCodeAndTimeoutAreStillReported() async {
        let executor = BackendAppSessionCommandExecutor()
        let done = await executor.run("sh", arguments: ["-c", "printf out; printf err >&2; exit 3"], environment: path, cwd: "/", timeoutMilliseconds: 5_000)
        XCTAssertEqual(done.stdout, "out"); XCTAssertEqual(done.stderr, "err"); XCTAssertEqual(done.exitCode, 3); XCTAssertFalse(done.killed)
        let capped = await executor.run("sh", arguments: ["-c", "printf 0123456789"], environment: path, cwd: "/", timeoutMilliseconds: 5_000, maximumBytes: 4)
        XCTAssertEqual(capped.stdout, "0123"); XCTAssertTrue(capped.killed)
        let slow = await executor.run("sleep", arguments: ["10"], environment: path, cwd: "/", timeoutMilliseconds: 200)
        XCTAssertTrue(slow.killed); XCTAssertFalse(slow.ok)
    }
}
