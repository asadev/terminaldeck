import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendHootChatTransportTests: XCTestCase, @unchecked Sendable {
    private func wait(_ check: () async -> Bool) async throws {
        for _ in 0..<100 { if await check() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw NativeRPCError(code: "test-timeout", message: "Hoot transport did not reach the expected state.")
    }
    private func exercise(_ provider: HootChatProvider) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-transport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var source = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { source.deleteLastPathComponent() }
        let fixture = source.appendingPathComponent("hootchat/HootFakeRPC.py")
        let file = root.appendingPathComponent("history.json")
        let setup = BackendHootChatSetup(cwd: root.path, expectedTools: ["deck-control": ["read"]])
        let launch = BackendHootChatLaunch(command: "/usr/bin/python3", arguments: [fixture.path, provider.rawValue], cwd: root.path, environment: [:], setup: setup)
        let store = try BackendHootChatStore(file: file, provider: provider)
        try await store.requireContext("account:" + root.path)
        try await store.attach(launch); try await store.initialize()
        for message in ["first", "second"] {
            _ = try await store.say(message)
            try await wait { await store.snapshot()["pending"].elements?.count == 1 }
            let question = await store.snapshot()["pending"].elements!.first!
            let id = try question["requestId"].requireString("request")
            try await store.answer(id: id, allowed: message == "first")
            do { try await store.answer(id: id, allowed: true); XCTFail("Replayed permission reached the CLI") } catch {}
            try await wait { await store.isBusy == false }
        }
        let snapshot = await store.snapshot(limit: 500)
        let events = try (snapshot["events"].elements ?? []).map(HootChatEvent.init(wire:))
        let rows = HootChatProjection.rows(events)
        XCTAssertEqual(rows.filter { $0.kind == .message || $0.kind == .textDelta }.map { $0.value["text"].string }, ["streamed reply", "streamed reply"])
        XCTAssertEqual(rows.filter { $0.kind == .toolCall }.count, 2)
        XCTAssertTrue(rows.filter { $0.kind == .toolCall }.allSatisfy { $0.value["finished"].bool == true })
        await store.stop()
        let resumed = try BackendHootChatStore(file: file, provider: provider)
        XCTAssertEqual(resumed.conversationID, store.conversationID)
        try await resumed.attach(launch); try await resumed.initialize()
        _ = try await resumed.say("interrupt")
        try await wait {
            let snapshot = await resumed.snapshot()
            return ["message", "textDelta"].contains(snapshot["events"].elements?.last?["kind"].string ?? "")
        }
        try await resumed.interrupt()
        try await wait { await resumed.isBusy == false }
        await resumed.stop()
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        let load = try XCTUnwrap(requests.first { $0["method"].string == (provider == .codex ? "thread/resume" : "session/load") })
        XCTAssertEqual(load["params"][provider == .codex ? "threadId" : "sessionId"].string, "saved-" + provider.rawValue)
        let approvals = requests.filter { $0["method"].isNullish && $0["id"].number == 7 }
        XCTAssertEqual(approvals.count, 2)
        if provider == .codex { XCTAssertEqual(approvals[0]["result"]["decision"].string, "accept"); XCTAssertEqual(approvals[1]["result"]["decision"].string, "decline") }
        else { XCTAssertEqual(approvals[0]["result"]["outcome"]["optionId"].string, "once"); XCTAssertEqual(approvals[1]["result"]["outcome"]["optionId"].string, "deny") }
    }
    func testCodexRealPipesStreamingApprovalsTwoTurnsResumeAndInterrupt() async throws { try await exercise(.codex) }
    func testGeminiRealPipesStreamingApprovalsTwoTurnsResumeAndInterrupt() async throws { try await exercise(.gemini) }
    func testInvalidMCPFormStaysPendingUntilAValidPersonAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-form-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        var source = URL(fileURLWithPath: #filePath); for _ in 0..<4 { source.deleteLastPathComponent() }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"), provider: .codex)
        try await store.attach(.init(command: "/usr/bin/python3", arguments: [source.appendingPathComponent("hootchat/HootFakeRPC.py").path, "codex"],
            cwd: root.path, environment: [:], setup: .init(cwd: root.path)))
        try await store.initialize(); _ = try await store.say("form")
        try await wait { await store.snapshot()["pending"].elements?.count == 1 }
        do { try await store.answer(id: "7", allowed: true, answers: .object([.init("name", .number(5))])); XCTFail("Invalid form reached MCP") } catch {}
        let pending = await store.snapshot()["pending"].elements?.count
        XCTAssertEqual(pending, 1)
        try await store.answer(id: "7", allowed: true, answers: .object([.init("name", .string("Asad"))]))
        try await wait { await store.isBusy == false }
        await store.stop()
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n").map { try NativeRPCValue.parseJSON(Data($0.utf8)) }
        let answers = requests.filter { $0["method"].isNullish && $0["id"].number == 7 }
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers[0]["result"]["content"]["name"].string, "Asad")
    }
}
