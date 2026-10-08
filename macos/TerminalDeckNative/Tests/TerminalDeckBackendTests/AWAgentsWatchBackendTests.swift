import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class AWAgentsWatchBackendTests: XCTestCase {
    private func object(_ json: String) throws -> NativeRPCValue { try .parseJSON(Data(json.utf8)) }
    func testReadableChatAndToolResultsOmitReasoningAndRedactToolSecrets() {
        var tools: [String: String] = [:]
        let line = #"{"type":"assistant","uuid":"a","timestamp":"2026-10-07T20:00:00Z","message":{"id":"m","content":[{"type":"thinking","thinking":"PRIVATE"},{"type":"text","text":"Reading the file."},{"type":"tool_use","id":"use-1","name":"Read","input":{"file_path":"/project/file.swift","token":"PRIVATE"}}]}}"#
        let entries = AWAgentsWatchTranscript.project(line, tools: &tools)
        XCTAssertEqual(entries.map(\.kind), [.message, .tool])
        XCTAssertFalse(entries.map(\.text).joined().contains("PRIVATE"))
        XCTAssertTrue(entries[1].text.contains("[redacted]"))
        let result = AWAgentsWatchTranscript.project(#"{"type":"user","uuid":"r","message":{"content":[{"type":"tool_result","tool_use_id":"use-1","is_error":true,"content":"File missing"}]}}"#, tools: &tools)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.title, "Failed · Read")
        XCTAssertEqual(result.first?.text, "File missing")
        XCTAssertEqual(result.first?.failed, true)
    }
    func testSidechainsSyntheticAndMalformedRecordsNeverAppear() {
        var tools: [String: String] = [:]
        for line in ["not-json", #"{"type":"assistant","uuid":"a","isSidechain":true,"message":{"content":[{"type":"text","text":"hidden"}]}}"#,
                     #"{"type":"assistant","uuid":"b","message":{"model":"<synthetic>","content":[{"type":"text","text":"hidden"}]}}"#] {
            XCTAssertTrue(AWAgentsWatchTranscript.project(line, tools: &tools).isEmpty)
        }
    }
    func testParentAndChildMustBothBeVisibleForHandoff() throws {
        let parent = try object(#"{"id":"local:p","agent":"Planner"}"#)
        let child = try object(#"{"id":"local:c","parentTaskId":"local:p","agent":"Builder","title":"Do the work","createdAt":10}"#)
        XCTAssertTrue(AWAgentsWatchTasks.exchanges(tasks: [child], agents: []).isEmpty)
        let exchange = AWAgentsWatchTasks.exchanges(tasks: [parent, child], agents: [])
        XCTAssertEqual(exchange.count, 1)
        XCTAssertEqual(exchange.first?.speaker, "Planner")
        XCTAssertEqual(exchange.first?.title, "Asked Builder")
    }
    func testLegacyLinkAndRepeatedNotesHaveStableIdentity() throws {
        let parent = try object(#"{"id":"key:p","agent":"Planner"}"#)
        let child = try object(#"{"id":"key:c","keyId":"key","parentExternalTaskId":"p","agent":"Builder","notes":[{"by":"Builder","text":"Done","at":10},{"by":"Builder","text":"Done","at":10}]}"#)
        let one = AWAgentsWatchTasks.exchanges(tasks: [parent, child], agents: [])
        XCTAssertEqual(one.count, 2)
        XCTAssertEqual(one, AWAgentsWatchTasks.exchanges(tasks: [parent, child], agents: []))
    }
    func testReadCannotSelectAnAgentOutsideTheAuthorizedSnapshot() async throws {
        let fake = AWWatchFakeSource(agents: [])
        do {
            _ = try await AWAgentsWatchService(source: fake).invoke("read", arguments: object(#"{"agentID":"private"}"#), caller: .app(.init(caller: .nativeApp, ownerID: "test")))
            XCTFail("Private selection was accepted")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        let reads = await fake.reads
        XCTAssertEqual(reads, 0)
    }
    func testRevocationDuringReadRejectsTheReply() async throws {
        let session = try object(#"{"id":"one","provider":"claude","attention":"working"}"#)
        let agent = AWWatchProjection.inventory(sessions: [session], tasks: [])[0]
        let fake = AWWatchFakeSource(agents: [agent], revokeOnRead: true)
        do {
            _ = try await AWAgentsWatchService(source: fake).invoke("read", arguments: .object([.init("agentID", .string(agent.id))]), caller: .app(.init(caller: .nativeApp, ownerID: "test")))
            XCTFail("Revoked reply was returned")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
    }
    func testUnlinkedSessionNeverReceivesUnrelatedTaskNotes() async throws {
        let session = try object(#"{"id":"one","provider":"claude","attention":"working"}"#)
        let agent = AWWatchProjection.inventory(sessions: [session], tasks: [])[0]
        let task = try object(#"{"id":"local:other","notes":[{"by":"Other","text":"Private task text","at":10}]}"#)
        let fake = AWWatchFakeSource(agents: [agent], tasks: [task])
        let reply = try await AWAgentsWatchService(source: fake).invoke("read", arguments: .object([.init("agentID", .string(agent.id))]), caller: .app(.init(caller: .nativeApp, ownerID: "test")))
        XCTAssertTrue(reply["entries"].elements!.isEmpty)
    }
    func testBoundedReaderUsesScratchFixtureAndIncludesTools() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AW-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        let scope = NativeTranscriptScope(configDirectory: config.path)
        let directory = config.appendingPathComponent("projects/-project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("one.jsonl")
        let text = #"{"type":"assistant","uuid":"m","cwd":"/project","message":{"content":[{"type":"text","text":"Hello"},{"type":"tool_use","id":"use","name":"Bash","input":{"command":"pwd"}}]}}"# + "\n"
        try Data(text.utf8).write(to: path)
        let read = try await AWAgentsWatchTranscript.read(path: path.path, scope: scope)
        XCTAssertEqual(read.entries.count, 2)
        XCTAssertTrue(read.bounded)
    }
    func testHootUsesSharedDeltaProjectionAndKeepsPairedToolResult() throws {
        let values: [HootChatRecord] = [.text(.textDelta, id: "message", "Hello "), .text(.textDelta, id: "message", "there"),
            .text(.message, id: "message", "Hello there!"),
            .init(.toolCall, id: "tool", value: try object(#"{"name":"Read","input":{"file_path":"/project/file"}}"#)),
            .init(.toolResult, id: "tool", value: try object(#"{"output":"Contents","isError":false}"#))]
        let events = values.enumerated().map { index, record in HootChatEvent(conversationID: "conversation", turnID: "turn", sequence: index + 1, provider: .claude, record: record, at: Double(index + 10)) }
        let snapshot = try object(#"{"conversationId":"conversation","provider":"claude","busy":true,"pending":[]}"#).setting("events", .array(events.map(\.wireValue)))
        let projection = try AWAgentsWatchHoot.project(snapshot)
        XCTAssertEqual(projection.agents.count, 1)
        XCTAssertEqual(projection.agents.first?.state, .working)
        XCTAssertEqual(projection.entries.map(\.kind), [.message, .tool, .result])
        XCTAssertEqual(projection.entries.first?.text, "Hello there!")
        XCTAssertEqual(projection.entries.last?.text, "Contents")
        XCTAssertEqual(try AWAgentsWatchHoot.project(snapshot.setting("pending", .array([.object([])]))).agents.first?.state, .waiting)
    }
    func testHootRejectsMixedConversationEvents() throws {
        let event = HootChatEvent(conversationID: "other", turnID: "turn", sequence: 1, provider: .claude, record: .text(.message, "Wrong conversation"))
        let snapshot = try object(#"{"conversationId":"conversation","provider":"claude"}"#).setting("events", .array([event.wireValue]))
        XCTAssertThrowsError(try AWAgentsWatchHoot.project(snapshot))
    }
    func testListCountsDrillIntoTheSameSearchAndState() async throws {
        let sessions = try object(#"[{"id":"a","provider":"claude","attention":"working","title":"Match"},{"id":"b","provider":"claude","attention":"idle","title":"Match"},{"id":"c","provider":"claude","attention":"working","title":"Other"}]"#).elements!
        let fake = AWWatchFakeSource(agents: AWWatchProjection.inventory(sessions: sessions, tasks: []))
        let reply = try await AWAgentsWatchService(source: fake).invoke("list", arguments: object(#"{"query":"Match","state":"working"}"#), caller: .app(.init(caller: .nativeApp, ownerID: "test")))
        XCTAssertEqual(reply["agents"].elements?.count, 1)
        XCTAssertEqual(reply["counts"]["working"].number, 1)
        XCTAssertEqual(reply["counts"]["idle"].number, 1)
        XCTAssertEqual(reply["allTotal"].number, 2)
    }
    func testMachineViewPreservesOfflineStateAndDistinctSessionIdentity() throws {
        let view = try object(#"{"machines":[{"id":"mac","name":"Office"}],"links":[{"id":"mac","state":"offline","sessions":[{"id":"same","provider":"codex","attention":"working"}]}]}"#)
        let projection = AWAgentsWatchMachines.project(view)
        XCTAssertEqual(projection.agents.first?.state, .offline)
        XCTAssertEqual(projection.agents.first?.machineName, "Office")
        XCTAssertNotEqual(projection.agents.first?.id, AWWatchAgent.identity(machine: "", kind: "session", source: "same"))
        XCTAssertEqual(projection.notices.count, 1)
    }
    func testAcceptedToolReceiptClearsAfterResultInsteadOfClaimingStillReading() async throws {
        let activity = AWAgentsWatchActivity()
        let session = try object(#"{"id":"one","provider":"claude","attention":"working"}"#)
        await activity.accept(.init(provider: "claude", event: "PreToolUse", sessionID: "one", cliSessionID: "cli", cwd: "/project", toolName: "Read", receivedAt: Date(), payload: .object([]), agentEnvironment: nil, peerPID: 1))
        let reading = await activity.decorate([session])
        XCTAssertEqual(AWWatchProjection.inventory(sessions: reading, tasks: []).first?.action, "Reading · Read")
        await activity.accept(.init(provider: "claude", event: "PostToolUse", sessionID: "one", cliSessionID: "cli", cwd: "/project", toolName: "Read", receivedAt: Date(), payload: .object([]), agentEnvironment: nil, peerPID: 1))
        let working = await activity.decorate([session])
        XCTAssertEqual(AWWatchProjection.inventory(sessions: working, tasks: []).first?.action, "Working")
    }
}

private actor AWWatchFakeSource: AWAgentsWatchSource {
    let agents: [AWWatchAgent], tasks: [NativeRPCValue]
    let revokeOnRead: Bool
    var revoked = false, reads = 0
    init(agents: [AWWatchAgent], tasks: [NativeRPCValue] = [], revokeOnRead: Bool = false) {
        self.agents = agents; self.tasks = tasks; self.revokeOnRead = revokeOnRead
    }
    func authorize(_ caller: AWWatchCaller, tool: String, arguments: NativeRPCValue) throws {
        if revoked { throw NativeRPCError(code: "access-denied", message: "Caller was revoked") }
    }
    func snapshot(_ caller: AWWatchCaller) -> AWWatchSnapshot { AWWatchSnapshot(agents: agents, tasks: tasks) }
    func conversation(_ agent: AWWatchAgent, caller: AWWatchCaller) -> AWWatchConversation {
        reads += 1
        if revokeOnRead { revoked = true }
        return AWWatchConversation(entries: [])
    }
}
