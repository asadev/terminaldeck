import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class BackendOSNotificationClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = 1_800_000_000_000.0
    func now() -> Double { lock.withLock { value } }
    func advance() { lock.withLock { value += 700 } }
}
private actor BackendOSNotificationReaderFixture: BackendOSCommandRunning {
    let rowAfter: Int?, denied: Bool; var reads = 0
    init(rowAfter: Int? = nil, denied: Bool = false) { self.rowAfter = rowAfter; self.denied = denied }
    func count() -> Int { reads }
    func run(command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        reads += 1
        guard command == "/usr/bin/sqlite3", arguments.first == "-readonly", arguments.count == 3 else { throw NativeRPCError.invalidArguments("Fixture must be read-only") }
        return .init(ok: !denied, stdout: rowAfter.map { reads >= $0 ? "2026-10-06 16:00:00\n" : "" } ?? "", stderr: denied ? "permission denied" : "", missing: false, exitCode: denied ? 1 : 0, timedOut: false)
    }
}
final class BackendOSNotificationEvidenceTests: XCTestCase {
    func testSQLScopesOwnBundleCaseInsensitivelyAndUsesAppleEpochSlack() {
        let sql = BackendOSNotificationEvidenceRules.deliverySQL(bundleID: "com.Example.o'hare", sinceMilliseconds: 978_307_202_000)
        XCTAssertTrue(sql.contains("lower(a.identifier) = lower('com.Example.o''hare')"))
        XCTAssertTrue(sql.contains("delivered_date > 1.0")); XCTAssertTrue(sql.hasSuffix("limit 1;"))
    }
    func testPollingWaitsForBannerRemovalRatherThanReportingEarlyAbsence() async throws {
        let clock = BackendOSNotificationClock(), reader = BackendOSNotificationReaderFixture(rowAfter: 10)
        let evidence = BackendOSNotificationEvidence(home: "/fixture-home", runner: reader, bundleIdentifier: { "fixture.app" }, openExternal: { _ in false }, authorize: { _ in }, fileExists: { _ in true }, now: { clock.now() }, pause: { clock.advance() })
        let before = await reader.count(); XCTAssertEqual(before, 0)
        let report = try await evidence.delivery(since: clock.now())
        XCTAssertEqual(report["verdict"].string, "delivered"); let after = await reader.count(); XCTAssertEqual(after, 10)
    }
    func testDeniedStoreIsUnknownAndReadableEmptyStoreIsAbsent() async throws {
        for denied in [false, true] {
            let clock = BackendOSNotificationClock(), reader = BackendOSNotificationReaderFixture(denied: denied)
            let evidence = BackendOSNotificationEvidence(home: "/fixture-home", runner: reader, bundleIdentifier: { "fixture.app" }, openExternal: { _ in false }, authorize: { _ in }, fileExists: { _ in true }, now: { clock.now() }, pause: { clock.advance() })
            let report = try await evidence.delivery(since: clock.now())
            XCTAssertEqual(report["verdict"].string, denied ? "unknown" : "absent")
        }
    }
    func testMissingStoreDoesNotStartCLI() async throws {
        let reader = BackendOSNotificationReaderFixture()
        let evidence = BackendOSNotificationEvidence(home: "/fixture-home", runner: reader, bundleIdentifier: { "fixture.app" }, openExternal: { _ in false }, authorize: { _ in }, fileExists: { _ in false })
        XCTAssertEqual(evidence.support()["deliveryReadable"].bool, false)
        let report = try await evidence.delivery(since: nil); XCTAssertEqual(report["verdict"].string, "unknown")
        let count = await reader.count(); XCTAssertEqual(count, 0)
    }
}
