import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Foundation: transcript usage token parser")
struct BackendFoundationTestsTranscriptsUsageParser {
    private func value(_ object: [String: Any]) throws -> NativeRPCValue {
        try NativeRPCValue.parseJSON(Data(BackendFoundationTestsSessionsFixtures.json(object).utf8))
    }
    // TS transcript.test.ts:486 (parseUsage returns `TokenUsage | null`, transcript.ts:652, so results are read with `?.` as the TS test does)
    @Test func modernUsageShapeReadExactly() throws {
        let parsed = try BackendCostTokens.parse(value(["input_tokens": 2, "output_tokens": 2540, "cache_creation_input_tokens": 21857, "cache_read_input_tokens": 30415, "cache_creation": ["ephemeral_1h_input_tokens": 21857, "ephemeral_5m_input_tokens": 0], "service_tier": "standard", "speed": "standard"]))
        #expect(parsed?.wireValue == .object([.init("input", .number(2)), .init("output", .number(2540)), .init("cacheWrite5m", .number(0)), .init("cacheWrite1h", .number(21857)), .init("cacheRead", .number(30415))]))
    }
    // TS transcript.test.ts:505
    @Test func unexplainedCacheWriteUsesFiveMinuteBucket() throws {
        let parsed = try BackendCostTokens.parse(value(["cache_creation_input_tokens": 1000]))
        #expect(parsed?.cacheWrite5m == 1000); #expect(parsed?.cacheWrite1h == 0)
    }
    // TS transcript.test.ts:513
    @Test func partialBreakdownReconciledWithTotal() throws {
        let parsed = try BackendCostTokens.parse(value(["cache_creation_input_tokens": 1000, "cache_creation": ["ephemeral_1h_input_tokens": 600]]))
        #expect(parsed?.cacheWrite1h == 600); #expect(parsed?.cacheWrite5m == 400); #expect(parsed?.prompt == 1000)
    }
    // TS transcript.test.ts:523
    @Test func excessBreakdownDoesNotInventNegativeTokens() throws {
        let parsed = try BackendCostTokens.parse(value(["cache_creation_input_tokens": 100, "cache_creation": ["ephemeral_1h_input_tokens": 500]]))
        #expect(parsed?.cacheWrite5m == 0); #expect(parsed?.cacheWrite1h == 500)
    }
    // TS transcript.test.ts:532
    @Test func missingFieldsZeroButNonobjectsAbsent() {
        #expect(BackendCostTokens.parse(.object([])) == BackendCostTokens())
        for raw in [NativeRPCValue.null, .string("nope"), .array([.number(1), .number(2)])] {
            let result: BackendCostTokens? = BackendCostTokens.parse(raw)
            #expect(result == nil)
        }
    }
}

@Suite("Foundation: transcript request aggregation")
struct BackendFoundationTestsTranscriptsUsageAggregator {
    private func assistant(_ id: String, model: String = "claude-opus-5", input: Int = 0, output: Int = 0,
                           write1h: Int = 0, read: Int = 0, uuid: String? = nil,
                           timestamp: String = "2026-08-11T11:33:22.579Z", sidechain: Bool = false, speed: String = "standard") throws -> String {
        try BackendFoundationTestsSessionsFixtures.json(["parentUuid": "parent", "isSidechain": sidechain, "type": "assistant", "uuid": uuid ?? id + "-fixture", "requestId": "req_" + id, "timestamp": timestamp, "cwd": "/Users/apple/ClaudeAsad", "sessionId": "sess-1", "message": ["id": id, "model": model, "role": "assistant", "type": "message", "content": [["type": "text", "text": "hi"]], "usage": ["input_tokens": input, "output_tokens": output, "cache_creation_input_tokens": write1h, "cache_read_input_tokens": read, "cache_creation": ["ephemeral_1h_input_tokens": write1h, "ephemeral_5m_input_tokens": 0], "service_tier": "standard", "speed": speed]]])
    }
    private func aggregate(_ lines: [String], filenameID: String = "sess-1") throws -> BackendCostTranscript {
        var result = BackendCostTranscript(path: "/fixture/" + filenameID + ".jsonl", sessionID: filenameID, cwd: "")
        for line in lines { try result.consume(line) }; return result
    }
    // TS transcript.test.ts:658
    @Test func multiblockRequestCountedOnce() throws {
        let lines = try ["a", "b", "c"].map { try assistant("msg_1", input: 2, output: 2540, write1h: 21857, read: 30415, uuid: $0) }, result = try aggregate(lines).summary
        #expect(result["requests"].number == 1); #expect(result["usage"]["output"].number == 2540); #expect(result["usage"]["cacheWrite1h"].number == 21857); #expect(result["usage"]["cacheRead"].number == 30415)
    }
    // TS transcript.test.ts:677
    @Test func distinctRequestsAccumulated() throws {
        let result = try aggregate([assistant("msg_1", output: 1000), assistant("msg_2", output: 1000)]).summary
        #expect(result["requests"].number == 2); #expect(result["usage"]["output"].number == 2000)
    }
    // TS transcript.test.ts:688
    @Test func replayedLinesIdempotent() throws {
        let line = try assistant("msg_1", output: 1000, uuid: "a")
        #expect(try aggregate([line, line]).summary["requests"].number == 1)
    }
    // TS transcript.test.ts:696
    @Test func usageSplitByNormalizedModel() throws {
        let result = try aggregate([assistant("m1", model: "claude-opus-5", output: 1000000), assistant("m2", model: "claude-haiku-4-5-20251001", output: 1000000)]).summary
        #expect(result["models"].elements?.contains(.string("claude-opus-5")) == true); #expect(result["models"].elements?.contains(.string("claude-haiku-4-5")) == true)
        #expect(result["usageByModel"]["claude-opus-5"]["output"].number == 1000000); #expect(result["usageByModel"]["claude-haiku-4-5"]["output"].number == 1000000)
    }
    // TS transcript.test.ts:709
    @Test func latestPromptIsContextNotRunningTotal() throws {
        let result = try aggregate([assistant("m1", output: 10, read: 100000), assistant("m2", output: 10, read: 150000), assistant("m3", output: 10, read: 200000)]).summary
        #expect(result["context"]["tokens"].number == 200000); #expect(result["context"]["window"].number == 1000000); #expect(abs((result["context"]["percent"].number ?? -1) - 20) < 1e-10)
    }
    // TS transcript.test.ts:724
    @Test func fixedFirstPromptProducesBloatWarning() throws {
        let result = try aggregate([assistant("m1", model: "claude-haiku-4-5", output: 10, write1h: 60000), assistant("m2", model: "claude-haiku-4-5", output: 10, read: 65000)]).summary
        #expect(result["preContextTokens"].number == 60000); #expect(result["warnings"].elements?.contains { $0["kind"].string == "pre-context" } == true)
    }
    // TS transcript.test.ts:735 — raw parseEventLine absence is separately recorded; aggregation expectations covered.
    @Test func missingModelTokensKeptInUnknownBucket() throws {
        let line = try BackendFoundationTestsSessionsFixtures.json(["type": "assistant", "uuid": "u1", "timestamp": "2026-08-11T10:00:00.000Z", "isSidechain": false, "message": ["id": "m1", "role": "assistant", "usage": ["input_tokens": 500, "output_tokens": 700]]])
        let result = try aggregate([line]).summary
        #expect(result["usage"]["input"].number == 500); #expect(result["usage"]["output"].number == 700)
        #expect(result["usageByModel"]["unknown"]["output"].number == 700); #expect(result["models"].elements == [.string("unknown")])
    }
    // TS transcript.test.ts:761
    @Test func syntheticModelNeverShown() throws {
        let line = try BackendFoundationTestsSessionsFixtures.json(["type": "assistant", "uuid": "u1", "isSidechain": false, "message": ["id": "m1", "model": "<synthetic>", "role": "assistant", "usage": ["input_tokens": 0, "output_tokens": 0]]])
        #expect(try aggregate([line]).summary["models"].elements == [])
    }
    // TS transcript.test.ts:781
    @Test func fastRequestOwnModelBucket() throws { #expect(try aggregate([assistant("m1", output: 1000000, speed: "fast")]).summary["models"].elements == [.string("claude-opus-5-fast")]) }
    // TS transcript.test.ts:792
    @Test func fastAndStandardBucketsKeptSeparate() throws {
        let result = try aggregate([assistant("m1", output: 1000000), assistant("m2", output: 1000000, speed: "fast")]).summary
        #expect(result["models"].elements?.compactMap(\.string).sorted() == ["claude-opus-5", "claude-opus-5-fast"]); #expect(result["usage"]["output"].number == 2000000)
    }
    // TS transcript.test.ts:803
    @Test func subagentModelCannotChooseMainContextWindow() throws {
        let result = try aggregate([assistant("m1", output: 10, read: 100000), assistant("m2", model: "claude-haiku-4-5", output: 10, read: 20000, sidechain: true)]).summary
        #expect(result["context"]["window"].number == 1000000); #expect(result["context"]["tokens"].number == 100000); #expect(abs((result["context"]["percent"].number ?? -1) - 10) < 1e-10)
        #expect(result["context"]["level"].string == "ok"); #expect(result["warnings"].elements == [])
    }
    // TS transcript.test.ts:827
    @Test func subagentPromptCannotWidenMainContextWindow() throws {
        let result = try aggregate([assistant("m1", model: "claude-haiku-4-5", output: 10, read: 50000), assistant("m2", output: 10, read: 900000, sidechain: true)]).summary
        #expect(result["context"]["window"].number == 200000); #expect(abs((result["context"]["percent"].number ?? -1) - 25) < 1e-10)
    }
    // TS transcript.test.ts:846
    @Test func onlySubagentRequestsKeepUsageWithoutMainContext() throws {
        let result = try aggregate([assistant("m1", output: 10, read: 1000, sidechain: true)]).summary
        #expect(result["context"] == .null); #expect(result["requests"].number == 1); #expect(result["usage"]["output"].number == 10)
    }
    // TS transcript.test.ts:858
    @Test func subagentPromptNeverMasqueradesAsMainContext() throws {
        let result = try aggregate([assistant("m1", output: 10, read: 500000), assistant("m2", output: 10, read: 20000, sidechain: true)]).summary
        #expect(result["context"]["tokens"].number == 500000); #expect(result["sidechainRequests"].number == 1); #expect(result["requests"].number == 2)
    }
    // TS transcript.test.ts:871
    @Test func compactionHighWaterMarkWidensUnderstatedWindow() throws {
        let compact = try BackendFoundationTestsSessionsFixtures.json(["type": "system", "subtype": "compact_boundary", "timestamp": "2026-06-06T13:16:47.913Z", "compactMetadata": ["trigger": "auto", "preTokens": 984388]])
        let result = try aggregate([assistant("m1", model: "claude-haiku-4-5", output: 10, read: 1000), compact, assistant("m2", model: "claude-haiku-4-5", output: 10, read: 50000)]).summary
        #expect(result["compactions"].number == 1); #expect(result["context"]["window"].number == 1000000); #expect(result["context"]["tokens"].number == 50000)
    }
    // TS transcript.test.ts:891
    @Test func sessionIdentityAndActivitySpanRecorded() throws {
        let result = try aggregate([assistant("m1", timestamp: "2026-08-11T10:00:00.000Z"), assistant("m2", timestamp: "2026-08-11T11:00:00.000Z")]).summary
        #expect(result["sessionId"].string == "sess-1"); #expect(result["cwd"].string == "/Users/apple/ClaudeAsad")
        #expect(result["startedAt"].number == 1786442400000); #expect(result["lastActivityAt"].number == 1786446000000)
    }
    // TS transcript.test.ts:904
    @Test func identicalTotalsOnRepeatedReads() throws {
        let result = try aggregate([assistant("m1", model: "claude-sonnet-5", output: 1000000, timestamp: "2026-08-11T10:00:00.000Z")])
        #expect(result.summary == result.summary); #expect(result.summary["usage"]["output"].number == 1000000)
    }
    // TS transcript.test.ts:928
    @Test func emptyBeforeFirstRequest() throws {
        let result = try aggregate([])
        #expect(result.requestCount == 0); #expect(result.summary["context"] == .null); #expect(result.usage == BackendCostTokens()); #expect(result.summary["warnings"].elements == [])
    }
    // TS transcript.test.ts:953 — uses the actual reader's filename fallback rather than a constructed summary id.
    @Test func filenameSuppliesMissingSessionID() async throws {
        let s = try BackendFoundationTestsSessionsScratch(), path = try s.write("cfg/projects/enc/749c33cd-a336.jsonl", ""), result = try await BackendCostTranscript.read(path: path.path, scope: .init(configDirectory: s.root.appendingPathComponent("cfg").path))
        #expect(result.summary["sessionId"].string == "749c33cd-a336")
    }
}
