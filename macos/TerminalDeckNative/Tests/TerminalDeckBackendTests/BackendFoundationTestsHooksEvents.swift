import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Foundation: CLI hook payload metadata")
struct BackendFoundationTestsHooksEvents {
    // TS hook-server.test.ts:145
    @Test func realPayloadFieldsExtracted() throws {
        let data = try BackendFoundationTestsSessionsFixtures.json(["session_id": "abc-123", "transcript_path": "/Users/a/.claude/projects/x.jsonl", "cwd": "/Users/a/Projects/terminaldeck", "tool_name": "Edit"])
        let event = BackendSessionHookEvent.parse(provider: "claude", event: "PostToolUse", sessionID: "terminaldeck-session-1", body: Data(data.utf8), environmentHeader: nil, peerPID: 4242)
        #expect(event.cliSessionID == "abc-123"); #expect(event.sessionID == "terminaldeck-session-1"); #expect(event.cwd == "/Users/a/Projects/terminaldeck"); #expect(event.toolName == "Edit")
    }
    // TS hook-server.test.ts:163
    @Test func nonJSONStillReportsEvent() {
        let event = BackendSessionHookEvent.parse(provider: "codex", event: "Stop", sessionID: nil, body: Data("not json".utf8), environmentHeader: nil, peerPID: 4242)
        #expect(event.event == "Stop"); #expect(event.payload == .object([])); #expect(event.cliSessionID == nil)
    }
    // TS hook-server.test.ts:170
    @Test func unsentEnvironmentNeverInvented() {
        let event = BackendSessionHookEvent.parse(provider: "claude", event: "Stop", sessionID: "s-1", body: Data("{}".utf8), environmentHeader: nil, peerPID: 4242)
        #expect(event.agentEnvironment == nil)
    }
}
