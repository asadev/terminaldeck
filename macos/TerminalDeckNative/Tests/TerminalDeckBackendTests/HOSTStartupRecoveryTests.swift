#if TD_HOST_ACCOUNT_BRIDGE && TD_HOST_INTEGRATED
import Foundation
import Darwin
import XCTest
@testable import TerminalDeckBackend

final class HOSTStartupRecoveryTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_WIP"]?.contains("HOST") == true)
        // The intentionally failing baseline is private to this startup lane.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_HOST_STARTUP_REGRESSION"] == "1"
            || ProcessInfo.processInfo.environment["TD_O2_ONLY"] == "HOSTStartupRecovery")
    }
    private func paths() throws -> BackendHOSTPaths {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("tdh-rec-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root, namespace: "agents")
        try paths.prepare()
        return paths
    }
    func testExitingCoreRetriesWithoutSelectingAnotherAccountWriter() async throws {
        let paths = try paths(), held = try BackendHOSTFileLock(paths.directory.appendingPathComponent("owner.lock"))
        defer { withExtendedLifetime(held) {} }
        let calls = HOSTStartupCalls()
        let result = try await BackendHOSTLaunchAgent.retryCoreExit(agents: paths) {
            if calls.next() < 4 { throw BackendHOSTFailure.occupiedHost }
            return "reattached"
        }
        XCTAssertEqual(result, "reattached")
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(try BackendHOSTLaunchAgent.agentsOwnerMayBeHeld(paths))
    }
    func testPermanentOccupiedCoreStopsAfterFourAttemptsAndPreservesAgentsOwner() async throws {
        let paths = try paths(), held = try BackendHOSTFileLock(paths.directory.appendingPathComponent("owner.lock"))
        defer { withExtendedLifetime(held) {} }
        let calls = HOSTStartupCalls()
        do {
            let _: Int = try await BackendHOSTLaunchAgent.retryCoreExit(agents: paths) {
                _ = calls.next(); throw BackendHOSTFailure.occupiedHost
            }
            XCTFail("An occupied host must never be replaced.")
        } catch BackendHOSTFailure.occupiedHost {}
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(try BackendHOSTLaunchAgent.agentsOwnerMayBeHeld(paths))
    }
    func testCancellationPreventsAdditionalCoreAttempts() async throws {
        let paths = try paths(), held = try BackendHOSTFileLock(paths.directory.appendingPathComponent("owner.lock"))
        defer { withExtendedLifetime(held) {} }
        let calls = HOSTStartupCalls()
        let operation = Task {
            try await BackendHOSTLaunchAgent.retryCoreExit(agents: paths) { () async throws -> Int in
                _ = calls.next()
                withUnsafeCurrentTask { $0?.cancel() }
                throw BackendHOSTFailure.occupiedHost
            }
        }
        do { _ = try await operation.value; XCTFail("Cancelled startup must stop.") }
        catch is CancellationError {}
        XCTAssertEqual(calls.count, 1)
    }
    func testMissingAgentsOwnerDoesNotRetryAndProbeCreatesNoLock() async throws {
        let paths = try paths(), calls = HOSTStartupCalls()
        XCTAssertFalse(try BackendHOSTLaunchAgent.agentsOwnerMayBeHeld(paths))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory.appendingPathComponent("owner.lock").path))
        do {
            let _: Int = try await BackendHOSTLaunchAgent.retryCoreExit(agents: paths) {
                _ = calls.next(); throw BackendHOSTFailure.occupiedHost
            }
            XCTFail("Expected the original startup refusal.")
        } catch BackendHOSTFailure.occupiedHost {}
        XCTAssertEqual(calls.count, 1)
    }
    func testOtherFailuresAreNotRetriedAndUnsafeOwnerProbeRefuses() async throws {
        let paths = try paths(), calls = HOSTStartupCalls()
        let target = paths.dataDirectory.appendingPathComponent("unrelated")
        try Data("unchanged".utf8).write(to: target)
        XCTAssertEqual(symlink(target.path, paths.directory.appendingPathComponent("owner.lock").path), 0)
        XCTAssertThrowsError(try BackendHOSTLaunchAgent.agentsOwnerMayBeHeld(paths))
        do {
            let _: Int = try await BackendHOSTLaunchAgent.retryCoreExit(agents: paths) {
                _ = calls.next(); throw BackendHOSTFailure.invalid("Missing helper")
            }
            XCTFail("Expected the original missing-helper failure.")
        } catch BackendHOSTFailure.invalid {}
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
    }
}
private final class HOSTStartupCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}
#endif
