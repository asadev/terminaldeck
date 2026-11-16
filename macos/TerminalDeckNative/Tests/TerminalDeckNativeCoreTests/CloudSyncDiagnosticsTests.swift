import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// 13 Nov blocker (two-Mac proof): a failed sync step writes ONE plain line naming the request, status and the
/// service's refusal code, never a query (signed links) or content; the page gets plain words.
final class CloudSyncDiagnosticsTests: XCTestCase {
  func testOneLineNamesRequestStatusAndCodeWithoutQuery() {
    let diagnostics = CloudSyncDiagnostics()
    final class Lines: @unchecked Sendable { var all: [String] = []; var clock: Int64 = 1_000_000 }
    let lines = Lines()
    diagnostics.setClock { lines.clock }
    diagnostics.setSink { lines.all.append($0) }
    diagnostics.noteRefusal(method: "POST", url: URL(string: "https://cloud.test/v1/changes?token=SECRET")!, status: 403, code: "viewer_read_only")
    let detail = CloudErrorDetail(code: "viewer_read_only", message: "x", retryable: false, requestId: "r")
    diagnostics.report("send", CloudFailure.remote(detail))
    XCTAssertEqual(lines.all, ["cloud sync: send failed: remote viewer_read_only / http 403 viewer_read_only at POST /v1/changes"])
    XCTAssertFalse(lines.all[0].contains("SECRET"))
    XCTAssertTrue(diagnostics.lastReason?.contains("view-only") == true)
    // The same failure passing up through the wiring is not repeated.
    diagnostics.report("first saved copy", CloudFailure.unavailable)
    XCTAssertEqual(lines.all.count, 1)
    // A storage link never shows its address.
    lines.clock += 10_000
    diagnostics.noteRefusal(method: "PUT", url: URL(string: "https://bucket.r2.test/obj/abc?X-Amz-Signature=SIG")!, status: 403, code: nil)
    diagnostics.report("first saved copy", CloudFailure.unavailable)
    XCTAssertEqual(lines.all.last, "cloud sync: first saved copy failed: unavailable / http 403 at PUT storage link")
    diagnostics.succeeded()
    XCTAssertNil(diagnostics.lastReason)
  }
}
