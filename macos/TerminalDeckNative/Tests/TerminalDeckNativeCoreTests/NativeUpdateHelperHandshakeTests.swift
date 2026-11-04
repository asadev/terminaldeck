import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class NativeUpdateHelperHandshakeTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-deadline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func helper(_ body: String, in root: URL) throws -> NativeChild {
        let script = root.appendingPathComponent("helper.sh")
        try Data(body.utf8).write(to: script)
        return try NativeChild.start(.init("/bin/bash", [script.path], cwd: root.path, output: .discard, errors: .discard))
    }

    func testEightSecondChecksSucceedWithoutQuittingOnStartupReceipt() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try helper(": > helper-started\nsleep 8\n: > helper-ready\nsleep 30\n", in: root)
        defer { child.terminate() }
        let began = ProcessInfo.processInfo.systemUptime
        try NativeUpdateHelperHandshake.wait(for: child, directory: root, timeout: NativeUpdateHelperHandshake.checkLimit(archiveBytes: 260_000_000))
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - began, 8)
        XCTAssertTrue(child.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("helper-cancelled").path))
    }

    func testFailedCheckRefusesEvenAfterStartupAndReadyReceipts() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try helper(": > helper-started\necho 'archive SHA-256 changed after download' > helper-error\n: > helper-ready\nsleep 30\n", in: root)
        defer { child.terminate() }
        // Let the fixture finish publishing both receipts before observing it.
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("helper-ready").path), ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("helper-ready").path))
        XCTAssertThrowsError(try NativeUpdateHelperHandshake.wait(for: child, directory: root, timeout: 2)) {
            XCTAssertTrue($0.localizedDescription.contains("SHA-256"))
            XCTAssertTrue($0.localizedDescription.contains("still running"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("helper-cancelled").path))
    }

    func testStartupAloneTimesOutAndCancelsWithoutPermissionToInstall() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try helper(": > helper-started\nsleep 30\n", in: root)
        defer { child.terminate() }
        XCTAssertThrowsError(try NativeUpdateHelperHandshake.wait(for: child, directory: root, timeout: 0.2)) {
            XCTAssertTrue($0.localizedDescription.contains("too long"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("helper-cancelled").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("helper-ready").path))
    }

    func testHelperExitRefusesAndLimitScalesWithArchiveSize() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try helper("exit 1\n", in: root)
        XCTAssertThrowsError(try NativeUpdateHelperHandshake.wait(for: child, directory: root, timeout: 2)) {
            XCTAssertTrue($0.localizedDescription.contains("stopped"))
        }
        XCTAssertEqual(NativeUpdateHelperHandshake.checkLimit(archiveBytes: 260_000_000), 120)
        XCTAssertEqual(NativeUpdateHelperHandshake.checkLimit(archiveBytes: 2_147_483_648), 300)
        XCTAssertEqual(NativeUpdateHelperHandshake.checkLimit(archiveBytes: Int64.max), 600)
    }
}
