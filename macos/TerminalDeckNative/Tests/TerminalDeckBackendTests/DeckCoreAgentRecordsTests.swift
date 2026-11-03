import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 18 Oct (#151): an AI checking a Codex or Gemini session gets its answer, tokens and progress from the
/// session's own record, not only the raw screen.
final class DeckCoreAgentRecordsTests: XCTestCase {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("td-agent-records-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func line(_ value: NativeRPCValue) throws -> String { String(decoding: try value.encodedJSON(), as: UTF8.self) }
    private func event(_ type: String, _ payload: [NativeRPCValue.Field], at: String = "2026-10-18T08:00:00.000Z") -> NativeRPCValue {
        .object([.init("timestamp", .string(at)), .init("type", .string(type)), .init("payload", .object(payload))])
    }
    private func codexRecord() throws -> (URL, BackendTaskTranscriptTarget) {
        let root = try folder(), sessions = root.appendingPathComponent("sessions/2026/10/18")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let file = sessions.appendingPathComponent("rollout-2026-10-18T08-00-00-codex-thread.jsonl")
        let rows: [NativeRPCValue] = [
            event("event_msg", [.init("type", .string("user_message")), .init("message", .string("Fix the failing test"))]),
            event("response_item", [.init("type", .string("function_call")), .init("name", .string("shell")), .init("call_id", .string("c1"))]),
            event("response_item", [.init("type", .string("custom_tool_call")), .init("name", .string("apply_patch")), .init("call_id", .string("c2"))]),
            event("event_msg", [.init("type", .string("token_count")), .init("info", .object([
                .init("total_token_usage", .object([.init("total_tokens", .number(1234))])),
                .init("last_token_usage", .object([.init("total_tokens", .number(50_000))])),
                .init("model_context_window", .number(200_000))]))]),
            event("event_msg", [.init("type", .string("agent_message")), .init("message", .string("Done: the test passes now."))], at: "2026-10-18T08:01:00.000Z"),
        ]
        try (rows.map(line).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return (file, .init(path: file.path, roots: [root.appendingPathComponent("sessions").path]))
    }
    private func session(_ provider: String) -> NativeRPCValue {
        .object([.init("id", .string("s-" + provider)), .init("provider", .string(provider)), .init("cwd", .string("/tmp")), .init("title", .string("Work"))])
    }

    func testCodexRecordGivesAnswerTokensAndToolTrail() async throws {
        let (_, target) = try codexRecord()
        let record = await BackendDeckCoreAgentRecords.read(session: session("codex"), locate: { _ in target }, windowBytes: 256 * 1024)
        let found = try XCTUnwrap(record)
        XCTAssertEqual(found.messages.compactMap { $0["role"].string }, ["user", "agent"])
        XCTAssertEqual(found.lastAnswer()?["text"].string, "Done: the test passes now.")
        XCTAssertEqual(found.match["basis"].string, "own-record")
        let spend = found.spend(maximumBytes: BackendDeckCoreReports.totalsMaxBytes)
        XCTAssertEqual(spend["totalTokens"].number, 1234)
        XCTAssertEqual(spend["contextPercent"].number, 25)
        XCTAssertEqual(found.toolTrail(windowBytes: 1024 * 1024)?.toolTrail.map(\.name), ["shell", "Edit"], "A patch counts as a file write")
    }

    func testGeminiRecordGivesAnswerTokensAndToolTrail() async throws {
        let root = try folder(), chats = root.appendingPathComponent(".gemini/tmp/project/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        let file = chats.appendingPathComponent("session-2026-10-18T08-00-gem.json")
        let record: NativeRPCValue = .object([.init("sessionId", .string("gem")), .init("messages", .array([
            .object([.init("id", .string("1")), .init("type", .string("user")), .init("content", .string("Add a note")), .init("timestamp", .string("2026-10-18T08:00:00.000Z"))]),
            .object([.init("id", .string("2")), .init("type", .string("gemini")), .init("content", .string("All set.")), .init("timestamp", .string("2026-10-18T08:00:30.000Z")),
                .init("tokens", .object([.init("total", .number(99))])),
                .init("toolCalls", .array([.object([.init("id", .string("t1")), .init("name", .string("write_file")), .init("status", .string("success"))])]))]),
        ]))])
        try record.encodedJSON().write(to: file)
        let target = BackendTaskTranscriptTarget(path: file.path, roots: [root.appendingPathComponent(".gemini/tmp").path])
        let read = await BackendDeckCoreAgentRecords.read(session: session("gemini"), locate: { _ in target }, windowBytes: 256 * 1024)
        let found = try XCTUnwrap(read)
        XCTAssertEqual(found.lastAnswer()?["text"].string, "All set.")
        XCTAssertEqual(found.spend(maximumBytes: BackendDeckCoreReports.totalsMaxBytes)["totalTokens"].number, 99)
        XCTAssertEqual(found.toolTrail(windowBytes: 0)?.toolTrail.map(\.name), ["Write"])
    }

    func testOtherSessionsAndRecordsOutsideTheAccountAreNotRead() async throws {
        let (_, target) = try codexRecord()
        let claude = await BackendDeckCoreAgentRecords.read(session: session("claude"), locate: { _ in target }, windowBytes: 1024)
        XCTAssertNil(claude, "Claude keeps its own transcript matcher")
        let elsewhere = BackendTaskTranscriptTarget(path: target.path, roots: [try folder().path])
        let outside = await BackendDeckCoreAgentRecords.read(session: session("codex"), locate: { _ in elsewhere }, windowBytes: 1024)
        XCTAssertNil(outside)
    }

    func testSessionResultReportsTheCodexAnswerSpendAndProgress() async throws {
        let (_, target) = try codexRecord()
        let surface = AgentRecordReportFake(target: target)
        let report = try await BackendDeckCoreReports.session(surface: surface, session: session("codex"), withChanges: false)
        XCTAssertEqual(report["lastMessage"]["text"].string, "Done: the test passes now.")
        XCTAssertEqual(report["spend"]["totalTokens"].number, 1234)
        XCTAssertEqual(report["transcript"]["basis"].string, "own-record")
        XCTAssertNotEqual(report["progress"]["verdict"].string, "unknown")
        XCTAssertNil(report["transcriptNote"].string)
    }
}

private struct AgentRecordReportFake: BackendDeckCoreReportSurface {
    let target: BackendTaskTranscriptTarget
    func listSessions() -> [NativeRPCValue] { [] }
    func transcriptsIn(cwd: String) async throws -> [NativeRPCValue] { [] }
    func transcriptBytes(path: String) async throws -> Double { XCTFail("A Codex record is not read as a Claude transcript"); return 0 }
    func readTranscriptFrom(path: String, fromByte: Double) async throws -> [NativeRPCValue] { XCTFail("A Codex record is not read as a Claude transcript"); return [] }
    func readToolTrail(path: String, windowBytes: Int) async throws -> BackendDeckCoreReportTrail { throw BackendSessionFailure.missingSession }
    func transcriptTotals(path: String) async throws -> NativeRPCValue? { nil }
    func gitChanges(cwd: String) async throws -> NativeRPCValue { .object([.init("repo", .bool(false))]) }
    func fileModifiedAt(path: String) async throws -> Double? { nil }
    func agentRecord(session: NativeRPCValue, windowBytes: Int) async -> BackendDeckCoreAgentRecord? {
        await BackendDeckCoreAgentRecords.read(session: session, locate: { [target] _ in target }, windowBytes: windowBytes)
    }
}
