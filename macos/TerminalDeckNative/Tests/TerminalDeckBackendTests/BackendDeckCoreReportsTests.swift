import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreReportsTests: XCTestCase {
    private func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private func meta(_ id: String, at: Double, provider: String = "claude") -> NativeRPCValue {
        object([("id", .string(id)), ("cwd", .string("/work")), ("createdAt", .number(at)), ("provider", .string(provider)), ("resumed", .bool(false))])
    }
    private func file(_ path: String, at: Double) -> NativeRPCValue {
        object([("path", .string(path)), ("createdAt", .number(at)), ("modifiedAt", .number(at)), ("bytes", .number(1000))])
    }
    func testReadyPromptsDoNotBlockAndDeadProcessesBeatStaleStatus() {
        let quiet = BackendDeckCoreAttention.view(status: "waiting", statusSince: 1000, exitCode: nil, now: 61_000)
        XCTAssertEqual(quiet["attention"], .string("quiet"))
        XCTAssertEqual(quiet["attentionReason"], .string("prompt-ready"))
        XCTAssertEqual(BackendDeckCoreAttention.status(exitCode: 137, live: "working"), "exited")
        let dead = BackendDeckCoreAttention.view(status: "exited", statusSince: nil, exitCode: 137, now: 61_000)
        XCTAssertEqual(dead["attentionForMs"], .null)
        XCTAssertEqual(dead["statusSource"], .string("exit-code"))
    }
    func testUnknownDurationSortsAfterKnownDurationAndClockCannotGoNegative() {
        let unknown = BackendDeckCoreAttention.view(status: "exited", statusSince: nil, exitCode: 0, now: 61_000)
        let known = BackendDeckCoreAttention.view(status: "exited", statusSince: 1000, exitCode: 0, now: 61_000)
        XCTAssertTrue(BackendDeckCoreAttention.precedes(known, unknown))
        XCTAssertEqual(BackendDeckCoreAttention.view(status: "input", statusSince: 90_000, exitCode: nil, now: 61_000)["attentionForMs"], .number(0))
    }
    func testNearbySessionsDoNotClaimTheSameTranscript() {
        let first = meta("one", at: 100_000), second = meta("two", at: 204_000)
        let files = [file("older.jsonl", at: 102_000), file("newer.jsonl", at: 205_000)]
        let a = BackendDeckCoreReports.matchTranscript(session: first, files: files, sessionsInFolder: [first, second])
        let b = BackendDeckCoreReports.matchTranscript(session: second, files: files, sessionsInFolder: [first, second])
        XCTAssertEqual(a["path"], .string("older.jsonl")); XCTAssertEqual(b["path"], .string("newer.jsonl"))
        XCTAssertEqual(a["ambiguous"], .bool(true))
        let shell = BackendDeckCoreReports.matchTranscript(session: meta("shell", at: 205_000, provider: "shell"), files: files, sessionsInFolder: [first, second])
        XCTAssertEqual(shell["path"], .null)
        XCTAssertTrue(shell["note"].string?.contains("writes no transcript") == true)
    }
    func testProgressBoundaryDistinguishesWorkAndFailureFromUnseenResults() {
        func trail(_ name: String, _ count: Int, failed: Bool?) -> BackendCostTranscript {
            var value = BackendCostTranscript(path: "fixture", sessionID: "s", cwd: "/work")
            value.toolTrail = (0..<count).map { BackendCostToolCall(id: String($0), name: name, at: Double($0 * 1000), failed: failed) }
            return value
        }
        XCTAssertEqual(BackendDeckCoreProgress.assess(trail("Bash", 9, failed: nil))["verdict"], .string("ok"))
        let stuck = BackendDeckCoreProgress.assess(trail("Bash", 20, failed: nil))
        XCTAssertEqual(stuck["verdict"], .string("looping")); XCTAssertEqual(stuck["failures"], .number(0))
        XCTAssertTrue(stuck["findings"].elements?.first?["detail"].string?.contains("nearly all") == true)
        XCTAssertEqual(BackendDeckCoreProgress.assess(trail("Edit", 20, failed: false))["verdict"], .string("suspect"))
        XCTAssertEqual(BackendDeckCoreProgress.assess(nil)["verdict"], .string("unknown"))
    }
    func testCompactionDominanceTieUsesFirstSeenFinalCount() {
        var trail = BackendCostTranscript(path: "fixture", sessionID: "s", cwd: "/work")
        trail.toolTrail = ["Read", "Bash", "Bash", "Read", "Read"].enumerated().map {
            BackendCostToolCall(id: String($0.offset), name: $0.element, at: Double($0.offset + 1), failed: nil)
        }
        trail.compactions = [object([("at", .number(4))])]
        let report = BackendDeckCoreProgress.assess(trail)
        XCTAssertTrue(report["findings"].elements?.contains { $0["signal"] == .string("compaction-echo") } == true)
    }
    func testBoundedTrailRetainsAllCallsAndPairsLateResultsWithoutInventingSuccess() throws {
        let lines = (0..<1200).map { index in
            "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"id-\(index)\",\"name\":\"Read\"}]}}"
        } + ["{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"id-0\",\"is_error\":true}]}}"]
        let transcript = try BackendDeckCoreNativeEvidence.parseToolTrail(lines.joined(separator: "\n"), path: "fixture.jsonl")
        XCTAssertEqual(transcript.toolTrail.count, 1200)
        XCTAssertEqual(transcript.toolTrail.first?.failed, true)
        XCTAssertNil(transcript.toolTrail.last?.failed)
    }
    func testImportanceRequiresRealPeersAndNeverInventsDecision() {
        let input = object([("attention", .string("running")), ("attentionReason", .string("output-streaming")), ("totalTokens", .number(3_000_000)), ("changedFiles", .number(0))])
        XCTAssertFalse(BackendDeckCoreImportance.supports("expensive", input: input))
        XCTAssertFalse(BackendDeckCoreImportance.supports("expensive", input: input, fleet: .init(medianTokens: 1_000_000, sample: 4)))
        let peers = BackendDeckCoreFleetContext.make([0, nil, 1_000_000, 1_000_000, 1_000_000, 1_000_000, 3_000_000])
        XCTAssertEqual(peers.sample, 5)
        XCTAssertTrue(BackendDeckCoreImportance.supports("expensive", input: input, fleet: peers))
        XCTAssertFalse(BackendDeckCoreImportance.reasons(input, fleet: peers).contains { $0["why"] == .string("decision") })
    }
    func testHeadlineCountsFailedFinishedSessionsOnce() {
        let totals = object([("sessions", .number(3)), ("blocked", .number(1)), ("failed", .number(1)), ("done", .number(2)), ("running", .number(0)), ("looping", .number(0))])
        XCTAssertEqual(BackendDeckCoreReports.headline(totals), "3 sessions: 1 waiting on you, 1 failed, 1 finished.")
    }
    func testFileExfiltrationRefusesNormalizedCredentialFolders() throws {
        XCTAssertThrowsError(try BackendDeckCoreArguments.sendableFile("/home/person/Downloads/../.ssh/id_ed25519", home: "/home/person"))
        XCTAssertEqual(try BackendDeckCoreArguments.sendableFile("/home/person/Downloads/report.pdf", home: "/home/person"), "/home/person/Downloads/report.pdf")
        XCTAssertThrowsError(try BackendDeckCoreArguments.sendableFile("relative.pdf"))
    }
    func testKeysRejectControlSmugglingAndCapListBeforeWriting() throws {
        XCTAssertEqual(try BackendDeckCoreTyping.resolveKey(.string("Ctrl+C")).bytes, "\u{03}")
        XCTAssertThrowsError(try BackendDeckCoreTyping.resolveKey(.string("\u{03}")))
        XCTAssertThrowsError(try BackendDeckCoreTyping.resolveKeys(.array(Array(repeating: .string("enter"), count: 25))))
        XCTAssertEqual(try BackendDeckCoreTyping.resolveKey(.string("😀")).name, "char:😀")
    }
    func testBriefTitleCannotEscapeSpecsDirectory() {
        XCTAssertEqual(BackendDeckCoreBrief.slugifyTitle("../../etc/passwd"), "etc-passwd")
        XCTAssertEqual(BackendDeckCoreBrief.slugifyTitle(" "), "brief")
        XCTAssertEqual(BackendDeckCoreBrief.stamp(at: 1_787_046_120_000, timeZone: TimeZone(secondsFromGMT: 0)!).count, 13)
        XCTAssertTrue(BackendDeckCoreBrief.deliveryLine("/spec.md").contains("whole brief"))
    }
}
