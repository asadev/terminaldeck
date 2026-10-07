import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// S5 night: TS `parseEventLine` cases. Swift has no separate event parser; the
/// same lines go through `BackendCostTranscript.consume`, which is the only
/// place they are read. TS `SessionAggregator.reset` (transcript.test.ts:943)
/// is skipped: the Swift aggregate is a value type, and a replaced file is read
/// into a brand-new value by `BackendCostTranscript.read`, so it cannot double-count.
@Suite("Foundation S5: transcript event lines")
struct BackendFoundationTestsS5TranscriptEvents {
    private func assistant(_ id: String, input: Int = 0, output: Int = 0, write1h: Int = 0, read: Int = 0,
                           speed: String = "standard", sidechain: Bool = false) throws -> String {
        try BackendFoundationTestsSessionsFixtures.json(["parentUuid": "parent", "isSidechain": sidechain, "type": "assistant",
            "uuid": id + "-fixture", "requestId": "req_" + id, "timestamp": "2026-08-11T11:33:22.579Z", "cwd": "/Users/apple/ClaudeAsad", "sessionId": "sess-1",
            "message": ["id": id, "model": "claude-opus-5", "role": "assistant", "type": "message", "content": [["type": "text", "text": "hi"]],
                "usage": ["input_tokens": input, "output_tokens": output, "cache_creation_input_tokens": write1h, "cache_read_input_tokens": read,
                    "cache_creation": ["ephemeral_1h_input_tokens": write1h, "ephemeral_5m_input_tokens": 0], "service_tier": "standard", "speed": speed]]])
    }
    private func consumed(_ lines: [String]) throws -> BackendCostTranscript {
        var result = BackendCostTranscript(path: "/fixture/sess-1.jsonl", sessionID: "sess-1", cwd: "")
        for line in lines { try result.consume(line) }; return result
    }
    // TS transcript.test.ts:591
    @Test func assistantRequestExtracted() throws {
        let result = try consumed([assistant("msg_1", input: 2, output: 2540, write1h: 21_857, read: 30_415)])
        #expect(result.requestCount == 1)
        #expect(result.requests[0].model == "claude-opus-5")
        #expect(result.requests[0].usage.cacheWrite1h == 21_857)
        #expect(result.sessionID == "sess-1")
        #expect(result.cwd == "/Users/apple/ClaudeAsad")
        #expect(result.startedAt == 1_786_448_002_579)
    }
    // TS transcript.test.ts:604
    @Test func fastRequestsKeepOwnBucket() throws {
        let fast = try consumed([assistant("m", speed: "fast")]), standard = try consumed([assistant("m")])
        #expect(fast.requests[0].speed == "fast"); #expect(fast.requests[0].model.hasSuffix("-fast"))
        #expect(standard.requests[0].speed == "standard"); #expect(!standard.requests[0].model.hasSuffix("-fast"))
    }
    // TS transcript.test.ts:609
    @Test func subagentWorkFlagged() throws {
        let result = try consumed([assistant("m", sidechain: true)])
        #expect(result.requests[0].sidechain == true); #expect(result.summary["sidechainRequests"].number == 1)
    }
    // TS transcript.test.ts:615
    @Test func compactionBoundaryAndTriggeringPromptSize() throws {
        let line = try BackendFoundationTestsSessionsFixtures.json(["type": "system", "subtype": "compact_boundary", "content": "Conversation compacted",
            "timestamp": "2026-06-06T13:16:47.913Z", "uuid": "u1", "compactMetadata": ["trigger": "auto", "preTokens": 984_388, "durationMs": 119_071]])
        let result = try consumed([line])
        #expect(result.compactions.count == 1); #expect(result.compactions[0]["preTokens"].number == 984_388)
        #expect(result.maxMainPrompt == 984_388); #expect(result.requestCount == 0)
    }
    // TS transcript.test.ts:629
    @Test func linesWithoutUsageIgnored() throws {
        let lines = ["", "   ", try BackendFoundationTestsSessionsFixtures.json(["type": "queue-operation", "operation": "enqueue"]),
            try BackendFoundationTestsSessionsFixtures.json(["type": "user", "message": ["role": "user", "content": "hi"]]),
            try BackendFoundationTestsSessionsFixtures.json(["type": "system", "subtype": "api_error"])]
        let result = try consumed(lines)
        #expect(result.requestCount == 0); #expect(result.compactions.isEmpty); #expect(result.startedAt == 0)
    }
    // TS transcript.test.ts:641
    @Test func tornTrailingLineNeverThrows() throws {
        let result = try consumed([try assistant("good", output: 5), "{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"usa", "not json at all", "[1,2,3]"])
        #expect(result.requestCount == 1); #expect(result.usage.output == 5)
    }
}
