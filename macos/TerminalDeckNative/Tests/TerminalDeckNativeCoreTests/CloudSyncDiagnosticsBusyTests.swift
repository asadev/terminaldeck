import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// Proof 3 (13 Nov), defect 1: "cloud sync: first saved copy (memory, attempt 1) failed: unavailable / this Mac's sync was
/// busy with another step". Busy with this Mac's own step (its first copy) is not a failure: no line, no page reason.
final class CloudSyncDiagnosticsBusyTests: XCTestCase {
  func testBusyIsNoFailureLineAndALaterRealFailureStillIs() {
    let diagnostics = CloudSyncDiagnostics()
    final class Lines: @unchecked Sendable { var all: [String] = []; var clock: Int64 = 1_000_000 }
    let lines = Lines()
    diagnostics.setClock { lines.clock }
    diagnostics.setSink { lines.all.append($0) }
    diagnostics.noteBusy("this Mac's sync was busy with another step")
    XCTAssertEqual(diagnostics.report("first saved copy (memory, attempt 1)", CloudFailure.unavailable), "")
    XCTAssertTrue(lines.all.isEmpty)
    XCTAssertNil(diagnostics.lastReason)
    XCTAssertTrue(diagnostics.lastRefusalWasBusy)
    // The same refusal passing up the wiring writes nothing either.
    diagnostics.noteBusy("the first saved copy is still being made")
    diagnostics.report("Sync now", CloudFailure.unavailable)
    XCTAssertTrue(lines.all.isEmpty)
    // A real failure afterwards is said as before.
    lines.clock += 10_000
    diagnostics.noteRefusal(method: "POST", url: URL(string: "https://cloud.test/v1/changes")!, status: 503, code: nil)
    diagnostics.report("send", CloudFailure.unavailable)
    XCTAssertEqual(lines.all, ["cloud sync: send failed: unavailable / http 503 at POST /v1/changes"])
    XCTAssertFalse(diagnostics.lastRefusalWasBusy)
    // A busy note left behind never swallows a later, different failure.
    diagnostics.noteBusy("this Mac's sync was busy with another step")
    lines.clock += 10_000
    diagnostics.report("pull", CloudFailure.checksumMismatch)
    XCTAssertEqual(lines.all.count, 2)
  }
  func testPreparingSaysOneInformationLineAtStartAndEnd() {
    let diagnostics = CloudSyncDiagnostics()
    final class Lines: @unchecked Sendable { var all: [String] = [] }
    let lines = Lines()
    diagnostics.setSink { lines.all.append($0) }
    diagnostics.info("preparing the first copy: 56500 records")
    XCTAssertEqual(lines.all, ["cloud sync: preparing the first copy: 56500 records"])
    XCTAssertFalse(lines.all[0].contains("failed"))
  }
}
