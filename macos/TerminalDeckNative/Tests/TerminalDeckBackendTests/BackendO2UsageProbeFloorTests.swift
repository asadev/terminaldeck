import XCTest
@testable import TerminalDeckBackend

/// usage-ipc.ts PROBE_FLOOR_MS (:682, :870-881) and the login memory after a probe (:888-913).
/// The service-level cases (usage-ipc.test.ts:900/:943) are F4's UsageIPC port; these pin the two rules exactly.
final class BackendO2UsageProbeFloorTests: XCTestCase {
    func testFloorIsSixtySecondsAndAPressGoesPastIt() {
        XCTAssertEqual(BackendUsageProbeFloor.milliseconds, 60_000)
        // `Date.now() - (lastProbeAt.get(configDir) ?? 0) < PROBE_FLOOR_MS`, only when not forced.
        XCTAssertFalse(BackendUsageProbeFloor.recentlyRead(lastProbeAt: nil, now: 1_000_000, force: false))
        XCTAssertTrue(BackendUsageProbeFloor.recentlyRead(lastProbeAt: 1_000_000 - 1_000, now: 1_000_000, force: false))
        XCTAssertTrue(BackendUsageProbeFloor.recentlyRead(lastProbeAt: 1_000_000 - 59_999, now: 1_000_000, force: false))
        XCTAssertFalse(BackendUsageProbeFloor.recentlyRead(lastProbeAt: 1_000_000 - 60_000, now: 1_000_000, force: false))
        XCTAssertFalse(BackendUsageProbeFloor.recentlyRead(lastProbeAt: 1_000_000 - 1_000, now: 1_000_000, force: true))
    }
    func testTheFloorAnswerIsTheSourceSentence() {
        XCTAssertEqual(BackendUsageProbeFloor.recentlyReadSentence, "This login was read a moment ago and had nothing to report.")
    }
    func testAReadingForgetsWhatWasRememberedAndOnlyNoLimitsIsWrittenDown() {
        XCTAssertEqual(BackendUsageProbeFloor.memory(after: "ok"), .forget)
        XCTAssertEqual(BackendUsageProbeFloor.memory(after: "no-limits"), .writeNoLimits)
        // `signed-out` is deliberately not written: a person who signs in expects the bar to start working.
        XCTAssertEqual(BackendUsageProbeFloor.memory(after: "signed-out"), .keep)
        XCTAssertEqual(BackendUsageProbeFloor.memory(after: "unreadable"), .keep)
        XCTAssertEqual(BackendUsageProbeFloor.memory(after: "no-binary"), .keep)
    }
}
