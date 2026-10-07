import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppUpdateErrorTests: XCTestCase {
    // This is a cross-platform diagnostic corpus, not Windows-only behavior.
    private let realFailure = "Cannot parse releases feed: Error: Unable to find latest version on GitHub (https://github.com/asadev/terminaldeck/releases/latest), please ensure a production release exists: Error: net::ERR_NETWORK_CHANGED at SimpleURLLoaderWrapper.<anonymous> (node:electron/js2c/browser_init:2:135010) at GitHubProvider.getLatestTagName (C:\\Users\\Asus\\AppData\\Local\\Programs\\Terminal Deck\\resources\\app.asar\\node_modules\\electron-updater\\out\\providers\\GitHubProvider.js:173:55) XML: <?xml version=\"1.0\"?><feed><entry><content>&lt;h3&gt;Install&lt;/h3&gt;"
    func testRealDiagnosticReducesToOneSentence() {
        XCTAssertEqual(BackendAppUpdateError.describe(.string(realFailure)), .init(text: "No connection to the update server.", transient: true))
    }
    func testFeedStackAndFilePathsNeverReachPanelForCapturedFailure() {
        let text = BackendAppUpdateError.describe(.string(realFailure)).text
        for unwanted in ["<", "node_modules", "C:\\"] { XCTAssertFalse(text.contains(unwanted)) }
        XCTAssertNil(text.range(of: #"\.js:\d+"#, options: .regularExpression)); XCTAssertLessThanOrEqual(text.utf16.count, 120)
    }
    func testAllMovingNetworkCodesAreRetryable() {
        for code in BackendAppUpdateError.transientCodes {
            XCTAssertEqual(BackendAppUpdateError.describe(.object([.init("message", .string("wrapped " + code.lowercased()))])), .init(text: "No connection to the update server.", transient: true), code)
        }
    }
    func testRefusedConnectionAndCertificateAreNotTransient() {
        XCTAssertFalse(BackendAppUpdateError.describe(.string("net::ERR_CONNECTION_REFUSED")).transient)
        XCTAssertFalse(BackendAppUpdateError.describe(.string("net::ERR_CERT_DATE_INVALID")).transient)
    }
    func testActionableFailuresUseExactSourceSentences() {
        XCTAssertEqual(BackendAppUpdateError.describe(.string("HTTP 429: API rate limit exceeded")), .init(text: "GitHub is rate-limiting this machine. Try again later.", transient: true))
        XCTAssertEqual(BackendAppUpdateError.describe(.string("ENOSPC: no space left on device")), .init(text: "Not enough disk space for the update.", transient: false))
        XCTAssertEqual(BackendAppUpdateError.describe(.string("EACCES: permission denied")), .init(text: "The app could not write the update.", transient: false))
    }
    func testShortSentenceIsPreserved() {
        XCTAssertEqual(BackendAppUpdateError.describe(.string("The release has no macOS asset.")), .init(text: "The release has no macOS asset.", transient: false))
    }
    func testLongSentenceIsTruncatedAtUTF16Boundary() {
        let text = BackendAppUpdateError.describe(.string(String(repeating: "x", count: 400))).text
        XCTAssertEqual(text, String(repeating: "x", count: 119) + "…")
    }
    func testUnknownThrownValuesAlwaysHaveText() {
        let values: [NativeRPCValue] = [.null, .missing, .string(""), .object([]), .object([.init("message", .string(""))]), .number(0)]
        for raw in values {
            XCTAssertFalse(BackendAppUpdateError.describe(raw).text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertEqual(BackendAppUpdateError.describe(.object([])).text, "The update check failed.")
    }
    func testThrownObjectMessageIsRead() {
        XCTAssertTrue(BackendAppUpdateError.describe(.object([.init("message", .string("net::ERR_NETWORK_CHANGED"))])).transient)
    }
    func testDocumentAndJoinedFramesAreCutBeforeWrapperNormalization() {
        XCTAssertEqual(BackendAppUpdateError.describe(.string("Error: useful cause XML: <?xml version=\"1.0\"?><feed/>\nnext")).text, "useful cause")
        XCTAssertEqual(BackendAppUpdateError.describe(.string("Error: useful cause at worker.run (/private/path.js:1)\nnext")).text, "useful cause")
        XCTAssertEqual(BackendAppUpdateError.describe(.string("<html>oops</html>")).text, "The update check failed.")
    }
    func testNativeURLErrorUsesSameCategoryAndLeavesCertificatePermanent() {
        XCTAssertEqual(BackendAppUpdateError.describe(URLError(.notConnectedToInternet)), .init(text: "No connection to the update server.", transient: true))
        XCTAssertFalse(BackendAppUpdateError.describe(URLError(.serverCertificateHasBadDate)).transient)
    }
}
