import Foundation
import XCTest
@testable import TerminalDeckBackend

/// relay-drops (2 Nov): the relay's edge resets our links every 1–3 min. The first redial is immediate (later ones
/// keep the back-off), and each drop names its real reason: a TCP reset, a close by the relay, or missed keepalives.
final class RelayDropReasonTests: XCTestCase {
    func testTheFirstRedialIsImmediateAndLaterOnesBackOff() {
        XCTAssertEqual(BackendRemoteRelayClient.redialDelay(attempt: 1, jitter: 1), 0)
        XCTAssertEqual((2...8).map { BackendRemoteRelayClient.redialDelay(attempt: $0, jitter: 1) }, [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000])
    }

    func testEachDropSaysWhatHappened() {
        XCTAssertEqual(BackendRemoteRelayClient.dropReason(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))), "The relay's connection was reset (TCP reset, NSPOSIXErrorDomain 54).")
        let wrapped = NSError(domain: NSURLErrorDomain, code: -9999, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNRESET))])
        XCTAssertEqual(BackendRemoteRelayClient.dropReason(wrapped), "The relay's connection was reset (TCP reset, NSURLErrorDomain -9999, POSIX 54).")
        XCTAssertEqual(BackendRemoteRelayClient.dropReason(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)), "The relay's connection was reset (network connection lost, NSURLErrorDomain -1005).")
        XCTAssertEqual(BackendRemoteRelayClient.closeReason(code: 1006, reason: nil), "The relay closed the connection (close code 1006).")
        XCTAssertEqual(BackendRemoteRelayClient.closeReason(code: 1001, reason: Data("going away".utf8)), "The relay closed the connection (close code 1001: going away).")
        XCTAssertEqual(BackendRemoteRelayClient.missedKeepalives, "The relay stopped answering (3 missed keepalives).")
        XCTAssertEqual(BackendRemoteRelayClient.dropReason(nil), "The connection to the relay ended.")
        XCTAssertEqual(BackendRemoteRelayClient.textPing, "td-ping")
        XCTAssertEqual(BackendRemoteRelayClient.textPingSeconds, 10)
    }
}
