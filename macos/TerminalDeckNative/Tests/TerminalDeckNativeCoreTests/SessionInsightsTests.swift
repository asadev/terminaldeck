import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — the Session inspector's formats and transcript choice (mirrors SessionInspector.test.tsx
// and session-transcript.test.ts).

@Suite("Session inspector")
struct SessionInsightsTests {
    @Test func tokenCountsReadLikeThePage() {
        #expect(InsightsFormat.tokens(999) == "999")
        #expect(InsightsFormat.tokens(1500) == "1.5k")
        #expect(InsightsFormat.tokens(2000) == "2k")
        #expect(InsightsFormat.tokens(1_250_000) == "1.25M")
        #expect(InsightsFormat.tokens(3_000_000) == "3M")
        #expect(InsightsFormat.tokens(2_000_000_000) == "2B")
    }

    @Test func durations() {
        #expect(InsightsFormat.duration(0) == "—")
        #expect(InsightsFormat.duration(420) == "420ms")
        #expect(InsightsFormat.duration(4200) == "4.2s")
        #expect(InsightsFormat.duration(42_000) == "42s")
        #expect(InsightsFormat.duration(125_000) == "2m 5s")
        #expect(InsightsFormat.duration(7_260_000) == "2h 1m")
    }

    @Test func namesAndLevels() {
        #expect(InsightsFormat.toolName("mcp__github__create_issue") == "create_issue")
        #expect(InsightsFormat.toolName("Bash") == "Bash")
        #expect(InsightsFormat.modelName("claude-opus-5") == "opus-5")
        #expect(InsightsFormat.modelName("<synthetic>") == "local only")
        #expect(InsightsFormat.level(69) == "ok" && InsightsFormat.level(70) == "warning" && InsightsFormat.level(90) == "critical")
        #expect(InsightsFormat.percent(12.345) == "12.3%")
        #expect(InsightsFormat.percent(.nan) == "—")
    }

    @Test func chartAxisAndDownsampling() {
        #expect(InsightsFormat.axisMax(0) == 0)
        #expect(InsightsFormat.axisMax(4) == 5)
        #expect(InsightsFormat.axisMax(90) == 100)
        #expect(InsightsFormat.axisLabel(50) == "50%")
        #expect(InsightsFormat.axisLabel(2.5) == "2.5%")
        let points = (1...10).map { ContextPoint(index: $0, at: 0, tokens: 0, percent: Double($0 == 4 ? 99 : $0)) }
        let down = InsightsFormat.downsample(points, target: 5)
        #expect(down.count == 5)
        #expect(down.contains { $0.index == 4 })
        #expect(InsightsFormat.downsample(points, target: 20) == points)
    }

    @Test func insightsDecode() throws {
        let raw: [String: Any] = ["sessionId": "abcdef123456", "startedAt": 1, "requests": 3, "durationMs": 5,
                                  "usage": ["input": 10, "output": 20, "cacheRead": 70],
                                  "timeline": [["index": 1, "key": "k", "model": "claude-x", "speed": "fast", "tools": ["Bash", 2]]],
                                  "context": ["tokens": 5, "window": 10, "percent": 50, "remaining": 5, "level": "ok"]]
        let insights = try #require(SessionInsights.decode(raw))
        #expect(insights.usage.prompt == 80 && insights.usage.total == 100)
        #expect(insights.timeline.first?.fast == true && insights.timeline.first?.tools == ["Bash"])
        #expect(insights.context?.percent == 50)
        #expect(SessionInsights.decode(nil) == nil)
    }

    @Test func theSessionsOwnTranscriptIsChosen() {
        let files = [TranscriptFile(path: "/old", sessionId: "o", createdAt: 10, modifiedAt: 50),
                     TranscriptFile(path: "/mine", sessionId: "m", createdAt: 100, modifiedAt: 120),
                     TranscriptFile(path: "/next", sessionId: "n", createdAt: 200, modifiedAt: 210)]
        #expect(TranscriptVerdict.attribute(files, scope: nil) == .choice(path: "/next", sessionId: "n", attribution: "project"))
        #expect(TranscriptVerdict.attribute(files, scope: SessionScope(startedAt: 90, resumed: false, agentSessionId: "o"))
                == .choice(path: "/old", sessionId: "o", attribution: "declared"))
        #expect(TranscriptVerdict.attribute(files, scope: SessionScope(startedAt: 90, resumed: false, agentSessionId: nil), others: [150])
                == .choice(path: "/mine", sessionId: "m", attribution: "session"))
        #expect(TranscriptVerdict.attribute(files, scope: SessionScope(startedAt: 90, resumed: true, agentSessionId: nil))
                == .choice(path: "/old", sessionId: "o", attribution: "resumed"))
        #expect(TranscriptVerdict.attribute(files, scope: SessionScope(startedAt: 90, resumed: false, agentSessionId: nil), others: [95])
                == .ambiguous(candidates: 2, competing: 1))
        #expect(TranscriptVerdict.attribute(files, scope: SessionScope(startedAt: 300, resumed: false, agentSessionId: nil)) == .none)
    }

    @Test func theSourceLineSaysWhichTranscript() {
        #expect(InsightsFormat.source(title: "web", insights: nil, attribution: nil) == "web — from its transcript")
        #expect(InsightsFormat.source(title: nil, insights: nil, attribution: nil) == nil)
    }
}
