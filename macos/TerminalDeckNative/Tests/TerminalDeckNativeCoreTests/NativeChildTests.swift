import XCTest
import Darwin
@testable import TerminalDeckNativeCore

/// The standard child runner: limits that hold for the whole process group.
final class NativeChildTests: XCTestCase {
    private func sh(_ script: String) -> NativeChild.Spec { .init("/bin/sh", ["-c", script]) }

    func testRunsToItsEndWithBothStreamsAndItsInput() async throws {
        let outcome = try await NativeChild.run(sh("cat; echo oops >&2; exit 3"), input: Data("hello".utf8), timeoutMilliseconds: 5_000)
        XCTAssertEqual(outcome.outputText, "hello")
        XCTAssertEqual(outcome.errorsText, "oops\n")
        XCTAssertEqual(outcome.code, 3)
        XCTAssertFalse(outcome.timedOut); XCTAssertFalse(outcome.succeeded)
    }

    func testDeadlineEndsTheWholeGroupNotOnlyTheChild() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("native-child-\(UUID().uuidString)").path
        let started = Date()
        // The grandchild keeps the output pipe open; without the group stop the run would wait for it.
        let outcome = try await NativeChild.run(sh("(sleep 30; touch \(marker)) & sleep 30"), timeoutMilliseconds: 300)
        XCTAssertTrue(outcome.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testOutputCapStopsAFloodingProgram() async throws {
        let outcome = try await NativeChild.run(sh("yes"), timeoutMilliseconds: 10_000, outputLimit: 4_096)
        XCTAssertTrue(outcome.outputLimited); XCTAssertFalse(outcome.timedOut)
        XCTAssertEqual(outcome.output.count, 4_096)
    }

    func testCancellingTheCallerEndsTheProgram() async throws {
        let spec = sh("sleep 30")
        let task = Task { try await NativeChild.run(spec, timeoutMilliseconds: 60_000) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do { _ = try await task.value; XCTFail("A cancelled run throws") } catch is CancellationError {}
    }

    func testBlockingRunAndAMissingProgram() throws {
        let outcome = try NativeChild.runBlocking(.init("/bin/echo", ["one", "two"]), timeoutMilliseconds: 5_000)
        XCTAssertEqual(outcome.outputText, "one two\n"); XCTAssertTrue(outcome.succeeded)
        XCTAssertThrowsError(try NativeChild.runBlocking(.init("/no/such/program"), timeoutMilliseconds: 1_000))
        XCTAssertThrowsError(try NativeChild.runBlocking(.init("relative"), timeoutMilliseconds: 1_000))
    }

    func testLongLivedChildTalksOverPipesAndStopsWithItsGroup() async throws {
        let lines = Lines()
        let child = try NativeChild.start(.init("/bin/cat", input: .pipe, errors: .merged), output: { lines.add($0) })
        try child.write(Data("ping\n".utf8))
        for _ in 0..<50 where lines.text != "ping\n" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(lines.text, "ping\n")
        XCTAssertTrue(child.isRunning)
        child.terminate(grace: .milliseconds(200))
        let end = await child.exited()
        XCTAssertEqual(end.signal, SIGTERM); XCTAssertFalse(child.isRunning)
        XCTAssertThrowsError(try child.write(Data("late".utf8)))
    }

    func testEndAfterMarksTheTerminationTimedOut() throws {
        let child = try NativeChild.start(.init("/bin/sleep", ["30"], output: .discard, errors: .discard))
        child.endAfter(.milliseconds(100), grace: .milliseconds(100))
        let end = child.waitUntilExit()
        XCTAssertTrue(end.timedOut)
    }

    // Devices freeze (26 Oct 2026): an `adb devices` stayed a zombie of the app for hours because its exit notice
    // came before it could be collected and nothing asked again; everything waiting for its end waited forever.
    // Here the kernel's notice is never armed (missed) or arrives early, and the end must still be seen.

    /// Waits for the child to be collected, never longer than `seconds` (a regression fails, it does not hang).
    private func ended(_ child: NativeChild, within seconds: Double) async throws -> NativeChild.Termination? {
        let until = Date().addingTimeInterval(seconds)
        while child.isRunning, Date() < until { try await Task.sleep(for: .milliseconds(20)) }
        guard !child.isRunning else { XCTFail("the child's end was never collected"); return nil }
        return await child.exited()
    }

    func testEndIsSeenWhenTheExitNoticeIsMissedAndItsPipesClose() async throws {
        let child = try NativeChild.start(sh("sleep 0.1; echo done"), exitNotices: false)
        let end = try await ended(child, within: 5)
        XCTAssertEqual(end?.code, 0); XCTAssertEqual(end?.timedOut, false)
    }

    func testEndIsSeenAtTheDeadlineWhenTheExitNoticeIsMissedAndThereAreNoPipes() async throws {
        let child = try NativeChild.start(.init("/bin/sleep", ["0.1"], output: .discard, errors: .discard), exitNotices: false)
        child.endAfter(.milliseconds(300))
        let end = try await ended(child, within: 5)
        XCTAssertEqual(end?.code, 0)
        XCTAssertEqual(end?.timedOut, false, "it had ended; the deadline only collected it")
    }

    func testAnExitNoticeThatComesBeforeTheChildCanBeCollectedIsAskedAgain() async throws {
        let child = try NativeChild.start(.init("/bin/sleep", ["0.3"], output: .discard, errors: .discard), exitNotices: false)
        child.exitNoticed() // early: the child is still running, as when macOS posts the notice before it is waitable
        let end = try await ended(child, within: 5)
        XCTAssertEqual(end?.code, 0); XCTAssertEqual(end?.timedOut, false)
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()
        func add(_ more: Data) { lock.withLock { data.append(more) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }
}
