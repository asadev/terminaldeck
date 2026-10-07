import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// context-window.test.ts: the parts reachable without a running session
/// (usage arithmetic, denominator, bounded tail, outside-store refusal).
/// The end-to-end reader lives inside BackendUsageService.contextWindow and is blocked (NIGHT-REQUESTS).
final class BackendFoundationTestsS6C1ContextWindow: XCTestCase {
    private let at = "2026-08-19T13:48:22.481Z"
    private func turn() -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(at)\",\"message\":{\"model\":\"claude-opus-5\",\"usage\":{\"input_tokens\":2,\"cache_read_input_tokens\":75511,\"cache_creation_input_tokens\":1703}}}"
    }

    func testAddsTheThreeFieldsThatMakeUpAResidentContext() throws {
        let line = try NativeRPCValue.parseJSON(Data(turn().utf8))
        XCTAssertEqual(BackendCostTokens.parse(line["message"]["usage"])?.prompt, 77_216) // parse is optional like transcript.ts:652 parseUsage (S1g)
        XCTAssertEqual(line["message"]["model"].string, "claude-opus-5")
    }

    func testIsOneMillionForTheModelsThisMachineActuallyRuns() {
        // The transcript records the bare id (no [1m] tag); the window comes from the model table.
        let window = BackendCostMath.contextWindow("claude-opus-5")
        XCTAssertEqual(window, 1_000_000)
        XCTAssertEqual(77_216 / window * 100, 7.72, accuracy: 0.01)
        XCTAssertEqual(BackendCostMath.effectiveWindow(model: "claude-opus-5", observed: 77_216), 1_000_000) // basis "model"
    }

    func testBoundedTailNeverReadsAWholeFileAndFindsAnswersBehindAMegabyte() throws {
        let fixture = try BackendFoundationTestsBFixture("s6c1-ctx-tail")
        let root = URL(fileURLWithPath: fixture.root.path).resolvingSymlinksInPath()
        let filler = (("{\"type\":\"user\",\"text\":\"" + String(repeating: "x", count: 4096) + "\"}\n")) 
        let body = turn() + "\n" + String(repeating: filler, count: 300)
        let file = root.appendingPathComponent("a.jsonl"); try body.write(to: file, atomically: true, encoding: .utf8)
        let first = try BackendUsageIO.tail(path: file.path, roots: [root.path], bytes: 256 * 1024)
        XCTAssertLessThanOrEqual(first.0.utf8.count, 256 * 1024)
        XCTAssertFalse(first.0.contains("claude-opus-5"))          // the answer is further back than the first step
        let second = try BackendUsageIO.tail(path: file.path, roots: [root.path], bytes: 8 * 1024 * 1024)
        XCTAssertTrue(second.0.contains("\"cache_read_input_tokens\":75511")) // the widest step reaches it
        XCTAssertLessThanOrEqual(second.0.utf8.count, body.utf8.count)
    }

    func testRefusesATranscriptPathOutsideTheStore() throws {
        let store = try BackendFoundationTestsBFixture("s6c1-ctx-store"), other = try BackendFoundationTestsBFixture("s6c1-ctx-other")
        try other.write("elsewhere.jsonl", turn() + "\n")
        let root = URL(fileURLWithPath: store.root.path).resolvingSymlinksInPath().path
        XCTAssertThrowsError(try BackendUsageIO.tail(path: other.file("elsewhere.jsonl").path, roots: [root], bytes: 1024)) { error in
            XCTAssertEqual((error as? NativeRPCError)?.code, "access-denied")
        }
    }
}
