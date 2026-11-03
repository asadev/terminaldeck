import Foundation
import CryptoKit
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// HOOTFIX 2026-10-09: a task agent on Codex or Gemini reads its own answer from its own
/// conversation record, exactly like Claude's, and never another session's words.
final class HOOTFIXTaskAgentTranscriptTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTFIXTask-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: NativeTranscriptPaths.canonical(root.path))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func iso(_ ms: Double) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
    private func write(_ url: URL, _ rows: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (rows.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    private func meta(_ provider: String, cwd: String, createdAt: Double, agent: String? = nil, id: String = UUID().uuidString) -> BackendSessionMeta {
        var input = BackendCreateSessionInput(cwd: cwd, cols: 80, rows: 24, provider: provider)
        input.resume = false
        let spec = BackendSpawnSpec(provider: provider, command: "/usr/bin/true", args: [], path: "/usr/bin", agentSessionId: agent)
        var value = BackendSessionMeta(id: id, input: input, spawn: spec, now: Date(timeIntervalSince1970: createdAt / 1000))
        value.agentSessionId = agent
        return value
    }
    /// A Codex rollout exactly where Codex writes it (local-time name, session_meta first).
    private func codexRollout(home: URL, cwd: String, startedAt: Double, id: String, rows: [String]) throws -> URL {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let date = Date(timeIntervalSince1970: startedAt / 1000), c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let name = String(format: "rollout-%04d-%02d-%02dT%02d-%02d-%02d-%@.jsonl", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, id)
        let file = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d/", c.year!, c.month!, c.day!) + name)
        try write(file, [#"{"timestamp":"\#(iso(startedAt))","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"#] + rows)
        return file
    }

    func testCodexTaskAgentAnswerIsReadFromItsOwnRollout() async throws {
        let home = root.appendingPathComponent("codex-home"), cwd = root.appendingPathComponent("project").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let started = (Date().timeIntervalSince1970 - 30).rounded(.down) * 1000, id = UUID().uuidString.lowercased()
        _ = try codexRollout(home: home, cwd: cwd, startedAt: started, id: id, rows: [
            #"{"timestamp":"\#(iso(started + 1000))","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"do the task"}]}}"#,
            #"{"timestamp":"\#(iso(started + 2000))","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"First draft."}]}}"#,
            #"{"timestamp":"\#(iso(started + 3000))","type":"event_msg","payload":{"type":"agent_message","message":"Done: the task is finished."}}"#,
            "not json at all",
        ])
        let session = meta("codex", cwd: cwd, createdAt: started)
        let answers = BackendTaskTranscriptAnswers { meta in
            try BackendTaskAgentTranscripts.target(provider: meta.provider, configDirectory: home.path, cwd: meta.cwd,
                                                   createdAt: meta.createdAt, knownID: meta.agentSessionId)
        }
        let answer = try await answers.latest(session)
        XCTAssertEqual(answer?.text, "Done: the task is finished.")
        XCTAssertEqual(answer?.at ?? 0, started + 3000, accuracy: 1)
    }

    func testGeminiTaskAgentAnswerFollowsRewritesAndRewinds() async throws {
        let home = root.appendingPathComponent("gemini-home"), cwd = root.appendingPathComponent("project").path
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let started = Date().timeIntervalSince1970 * 1000 - 20_000, sid = UUID().uuidString.lowercased()
        let hash = SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = home.appendingPathComponent(".gemini/tmp/project-slug/chats/session-2026-10-09T02-50-\(sid.prefix(8)).jsonl")
        try write(file, [
            #"{"sessionId":"\#(sid)","projectHash":"\#(hash)","startTime":"\#(iso(started + 500))","lastUpdated":"\#(iso(started + 500))","kind":"main"}"#,
            #"{"id":"u1","timestamp":"\#(iso(started + 1000))","type":"user","content":[{"text":"do the task"}]}"#,
            #"{"id":"g1","timestamp":"\#(iso(started + 2000))","type":"gemini","content":"Working on it."}"#,
            #"{"id":"g2","timestamp":"\#(iso(started + 3000))","type":"gemini","content":"Wrong turn."}"#,
            #"{"$rewindTo":"g2"}"#,
            #"{"id":"g3","timestamp":"\#(iso(started + 4000))","type":"gemini","content":[{"text":"thinking","thought":true},{"text":"Finished: "},{"text":"all green."}]}"#,
            #"{"id":"g3","timestamp":"\#(iso(started + 4000))","type":"gemini","content":[{"text":"Finished: "},{"text":"all green."}],"tokens":{"total":9}}"#,
            #"{"$set":{"lastUpdated":"\#(iso(started + 4100))"}}"#,
        ])
        // The system profile's directory IS ~/.gemini; a managed one is GEMINI_CLI_HOME.
        for configDirectory in [home.appendingPathComponent(".gemini").path, home.path] {
            let session = meta("gemini", cwd: cwd, createdAt: started)
            let answers = BackendTaskTranscriptAnswers { meta in
                try BackendTaskAgentTranscripts.target(provider: meta.provider, configDirectory: configDirectory, cwd: meta.cwd,
                                                       createdAt: meta.createdAt, knownID: nil)
            }
            let answer = try await answers.latest(session)
            XCTAssertEqual(answer?.text, "Finished: all green.")
            XCTAssertEqual(answer?.at ?? 0, started + 4000, accuracy: 1)
        }
        // The known conversation ID also finds it; a claimed one never does.
        XCTAssertNotNil(try BackendTaskAgentTranscripts.target(provider: "gemini", configDirectory: home.path, cwd: cwd, createdAt: 0, knownID: sid))
        XCTAssertNil(try BackendTaskAgentTranscripts.target(provider: "gemini", configDirectory: home.path, cwd: cwd, createdAt: started, knownID: nil, claimed: [sid]))
    }

    func testAmbiguousOrForeignRecordsAreNeverAttributed() async throws {
        let home = root.appendingPathComponent("gemini-home"), cwd = root.appendingPathComponent("project").path
        let started = Date().timeIntervalSince1970 * 1000 - 20_000
        let hash = SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
        for index in 0..<2 {
            try write(home.appendingPathComponent(".gemini/tmp/p/chats/session-x-\(index).jsonl"),
                      [#"{"sessionId":"s\#(index)","projectHash":"\#(hash)","startTime":"\#(iso(started + 100))"}"#])
        }
        XCTAssertNil(try BackendTaskAgentTranscripts.target(provider: "gemini", configDirectory: home.path, cwd: cwd, createdAt: started, knownID: nil),
                     "two sessions in one folder: the screen is used, not a guess")
        // Started before this session: another conversation, never this one's answer.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".gemini/tmp/p/chats/session-x-1.jsonl"))
        XCTAssertNil(try BackendTaskAgentTranscripts.target(provider: "gemini", configDirectory: home.path, cwd: cwd, createdAt: started + 60_000, knownID: nil))
        // A target outside the account's own roots is refused when read.
        let outside = root.appendingPathComponent("elsewhere/session-y.jsonl")
        try write(outside, [#"{"id":"g","timestamp":"\#(iso(started))","type":"gemini","content":"leak"}"#])
        XCTAssertThrowsError(try BackendTaskAgentTranscripts.geminiAnswer(.init(path: outside.path, roots: [home.path])))
    }

    func testProductionLocatorRoutesEveryAgentAndKeepsClaude() async throws {
        let cwd = root.appendingPathComponent("project").path, started = (Date().timeIntervalSince1970 - 30).rounded(.down) * 1000
        let codexHome = root.appendingPathComponent("codex"), id = UUID().uuidString.lowercased()
        _ = try codexRollout(home: codexHome, cwd: cwd, startedAt: started, id: id, rows: [
            #"{"timestamp":"\#(iso(started + 1000))","type":"event_msg","payload":{"type":"agent_message","message":"codex says hi"}}"#])
        let codex = meta("codex", cwd: cwd, createdAt: started), claude = meta("claude", cwd: cwd, createdAt: started)
        let claudeTarget = BackendTaskTranscriptTarget(path: "/claude.jsonl", scope: NativeTranscriptScope(configDirectory: root.path))
        let locate = BackendTaskAgentTranscripts.locator(claude: { meta, _ in meta.provider == "claude" ? claudeTarget : nil },
            metadata: { [] }, systemDirectory: { $0 == "codex" ? codexHome.path : "/nonexistent" })
        let found = try await locate(codex)
        XCTAssertEqual(found?.path.hasSuffix("-\(id).jsonl"), true)
        let claudeFound = try await locate(claude)
        XCTAssertEqual(claudeFound?.path, "/claude.jsonl")
        let shell = try await locate(meta("shell", cwd: cwd, createdAt: started))
        XCTAssertNil(shell)
    }

    #if TD_HOST_ACCOUNT_BRIDGE
    /// Session events carry no request: the locator reads accounts under the app owner.
    func testLocatorRunsUnderTheOwnerContextWhenNoRequestExists() async throws {
        let owner = NativeRPCContext(caller: .nativeApp, ownerID: "owner-for-task-reads")
        let locate = BackendTaskAgentTranscripts.locator(claude: { _, _ in
            XCTAssertEqual(try BackendHOSTProfileScope.requireCurrent().ownerID, "owner-for-task-reads"); return nil
        }, metadata: { [] }, systemDirectory: { _ in "/nonexistent" }, ownerContext: { owner })
        _ = try await locate(meta("claude", cwd: root.path, createdAt: 0))
    }
    #endif
}
