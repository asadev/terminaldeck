import Foundation
import XCTest
@testable import TerminalDeckBackend

/// sec-26 item 2 (a): the keeper is not answering when a Claude saves its renewed login (a keeper restart). The
/// helper tries the save again against the current keeper for about 10 s; if there is still no keeper it answers
/// "locked" (36), so the agent keeps its login in memory instead of a plaintext copy and a failing delete.
final class AccountShimSaveRetryTests: XCTestCase {
    func testASaveIsTriedAgainUntilTheKeeperAnswers() throws {
        var calls = 0, pauses = 0
        let answer = try BackendAccountSecurityShimClient.retrying(BackendAccountSecurityShimClient.writeAttempts, pause: { pauses += 1 }) { () throws -> Int in
            calls += 1
            if calls < 4 { throw BackendAccountFailure("not answering") }
            return 7
        }
        XCTAssertEqual(answer, 7); XCTAssertEqual(calls, 4); XCTAssertEqual(pauses, 3)
        XCTAssertEqual(BackendAccountSecurityShimClient.writeAttempts, 20, "about 10 s at 0.5 s")
        calls = 0
        XCTAssertThrowsError(try BackendAccountSecurityShimClient.retrying(1, pause: {}) { () throws -> Int in calls += 1; throw BackendAccountFailure("x") })
        XCTAssertEqual(calls, 1, "a lookup is asked once")
    }

    func testOnlySavesAndDeletesAreRetriedAndARefusalIsLocked() throws {
        XCTAssertTrue(BackendAccountSecurityShimClient.isWrite(["-i"], input: "add-generic-password -U -a me -s x -X 00"))
        XCTAssertTrue(BackendAccountSecurityShimClient.isWrite(["delete-generic-password", "-s", "x"], input: ""))
        XCTAssertFalse(BackendAccountSecurityShimClient.isWrite(["find-generic-password", "-w", "-s", "x"], input: ""))
        XCTAssertEqual(BackendAccountShimParsing.exitLocked, 36)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend/BackendAccountShimTransport.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("return BackendAccountShimParsing.exitLocked"), "no keeper after the retries: locked, never a plain failure")
    }
}
