import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendHootChatTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("hoot-chat-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<100 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out waiting for Hoot's pipe event")
    }
    func testRealPipesPreserveFinalOutputBeforeExit() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let child = BackendHootChatProcess()
        try child.start(.init(command: "/bin/sh", arguments: ["-c", "printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}'; printf 'diagnostic' >&2"], cwd: root.path, environment: [:]))
        var stdout = Data(), stderr = Data(), exited = false
        for await event in child.output {
            switch event {
            case .stdout(let bytes): XCTAssertFalse(exited); stdout.append(bytes)
            case .stderr(let bytes): XCTAssertFalse(exited); stderr.append(bytes)
            case .exit(let code): exited = true; XCTAssertEqual(code, 0)
            }
        }
        XCTAssertTrue(exited); XCTAssertEqual(String(data: stderr, encoding: .utf8), "diagnostic")
        XCTAssertTrue(String(data: stdout, encoding: .utf8)?.contains("result") == true)
    }
    func testApprovalPreservesOriginalInputAndReplayFails() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.json")
        let store = try BackendHootChatStore(file: file)
        let script = "read first; printf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"cli-session\"}' '{\"type\":\"control_request\",\"request_id\":\"q1\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Write\",\"input\":{\"path\":\"original\"}}}'; read answer; printf '%s' \"$answer\" > answer.json; printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}'; read more"
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", script], cwd: root.path, environment: [:]))
        _ = try await store.say("hello")
        try await wait { await store.snapshot()["pending"].elements?.count == 1 }
        try await store.answer(id: "q1", allowed: true)
        try await wait { await store.isBusy == false }
        let answer = try NativeRPCValue.parseJSON(Data(contentsOf: root.appendingPathComponent("answer.json")))
        XCTAssertEqual(answer["response"]["response"]["updatedInput"]["path"].string, "original")
        do { try await store.answer(id: "q1", allowed: true); XCTFail("Replayed approval was accepted") } catch {}
        await store.stop()
        let reloaded = try BackendHootChatStore(file: file)
        let sessionID = await reloaded.cliSessionID
        XCTAssertEqual(sessionID, "cli-session")
        XCTAssertEqual(reloaded.conversationID, store.conversationID)
    }
    func testConcurrentSendRejectedAndStopClearsPendingState() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"))
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "read first; read second"], cwd: root.path, environment: [:]))
        _ = try await store.say("one")
        do { _ = try await store.say("two"); XCTFail("Concurrent send was accepted") } catch {}
        await store.stop()
        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot["busy"].bool, false); XCTAssertEqual(snapshot["alive"].bool, false)
        XCTAssertTrue(snapshot["pending"].elements?.isEmpty == true)
        let kinds = snapshot["events"].elements?.compactMap { $0["kind"].string }
        XCTAssertTrue(kinds?.contains("interrupted") == true)
    }
    func testPrematureExitAndCorruptHistoryAreVisibleFailures() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"))
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "read first; exit 0"], cwd: root.path, environment: [:]))
        _ = try await store.say("one")
        try await wait { await store.snapshot()["problem"].string != nil }
        let busy = await store.isBusy
        XCTAssertFalse(busy)
        let broken = root.appendingPathComponent("broken.json"); try Data("bad".utf8).write(to: broken)
        XCTAssertThrowsError(try BackendHootChatStore(file: broken))
    }
    func testContextCannotBorrowAnotherAccountAndResumeIsExact() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"))
        try await store.requireContext("account-a:/folder")
        do { try await store.requireContext("account-b:/folder"); XCTFail("Account changed silently") } catch {}
        let args = try BackendHootChatCLI.claudeArguments(sessionID: "exact-id", extra: ["--mcp-config", "private.json", "--strict-mcp-config"])
        XCTAssertEqual(Array(args.suffix(2)), ["--resume", "exact-id"])
        XCTAssertFalse(args.contains("--continue")); XCTAssertFalse(args.contains("--dangerously-skip-permissions"))
        XCTAssertThrowsError(try BackendHootChatCLI.claudeArguments(sessionID: "--last", extra: []))
        let composed = root.appendingPathComponent("hoot.md")
        try Data("Exact Hoot instructions 🦉".utf8).write(to: composed)
        let translated = try BackendHootChatCLI.claudeArguments(sessionID: nil, extra: [BackendCopilotLayer.appendSystemPromptFile, composed.path])
        XCTAssertEqual(Array(translated.suffix(2)), ["--append-system-prompt", "Exact Hoot instructions 🦉"])
        XCTAssertFalse(translated.contains(BackendCopilotLayer.appendSystemPromptFile))
    }
    func testStructuredHandshakeAndActualReapedStop() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"))
        // Echo the initialize ID in a real JSON control response, no agent login.
        let script = "read init; id=$(printf '%s' \"$init\" | /usr/bin/sed -E 's/.*\"request_id\":\"([^\"]*)\".*/\\1/'); printf '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"%s\",\"response\":{}}}\\n' \"$id\"; read more"
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", script], cwd: root.path, environment: [:]))
        try await store.initialize()
        await store.stop()
        let alive = await store.alive; XCTAssertFalse(alive)
        // A fresh attach is possible only after the old child was actually reaped.
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "read first"], cwd: root.path, environment: [:]))
        await store.stop()
    }
    func testMCPReadRequiresBothGrantAndCurrentVisibility() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"))
        let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: root.path,
            driver: BackendCopilotSessionUnavailableDriver(), records: BackendCopilotSessionUnavailableRecords(), chat: store))
        let access = BackendDeckToolsAppAccess(caller: { _ in .init(kind: .key, keyName: "limited") },
            knownFolder: { _, folder in folder }, session: { _, _ in .null }, runnableProject: { _, folder in folder },
            rpc: { _ in .init(caller: .nativeApp, ownerID: "test") }, authorize: { _, _, _, _, _, _ in }, record: { _, _, _, _ in })
        let granted = BackendMCPCallContext(sessionID: "external", machineID: "", projectRoot: nil, attended: true,
            allowedTools: ["hoot.chat.read"], allowedTiers: [.read], cancellation: .init())
        let narrowed = BackendMCPCallContext(sessionID: "external", machineID: "", projectRoot: nil, attended: true,
            allowedTools: [], allowedTiers: [.read], cancellation: .init())
        let tools = try BackendHootChatMCP.definitions(runtime: runtime, access: access, visible: { _ in })
        let read = try XCTUnwrap(tools.first { $0.spec.id == "hoot.chat.read" })
        let reply = try await read.handler(granted, .object([]))
        XCTAssertEqual(reply.structuredContent?["conversationId"].string, store.conversationID)
        do { _ = try await read.handler(narrowed, .object([])); XCTFail("A narrowed key read Hoot") } catch {}
        let revoked = try BackendHootChatMCP.definitions(runtime: runtime, access: access, visible: { _ in
            throw NativeRPCError(code: "access-denied", message: "Hoot grant revoked")
        })
        do { _ = try await revoked[0].handler(granted, .object([])); XCTFail("A revoked key read Hoot") } catch {}
        XCTAssertFalse(tools.contains { $0.spec.id.contains("answer") || $0.spec.id.contains("approve") })
    }
    func testCancelDuringStartupCannotLeaveAChildRunning() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try BackendHootChatStore(file: root.appendingPathComponent("history.json"))
        try await store.attach(.init(command: "/bin/sh", arguments: ["-c", "read init; touch initialized; read more"], cwd: root.path, environment: [:]))
        let startup = Task { try await store.initialize() }
        try await wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("initialized").path) }
        startup.cancel()
        do { try await startup.value; XCTFail("Cancelled startup completed") } catch {}
        try await wait { await store.alive == false }
        await store.stop()
    }
}
