import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CodexChatDropsTests: XCTestCase, @unchecked Sendable {
  private typealias V = BackendDeckToolsSessionsPortValues
  private func pending() -> NativeRPCValue {
    V.object([("busy", .bool(true)), ("events", .array([])), ("pending", .array([
      V.object([("requestId", .string("request-6")), ("name", .string("mcpServer/elicitation/request")),
        ("input", V.object([("message", .string("Allow this scratch tool?"))]))])
    ]))])
  }
  private func call(_ id: String, _ args: NativeRPCValue, _ rig: BackendDeckToolsSessionsPortRig) async throws -> BackendMCPToolReply {
    let definitions = try BackendDeckToolsSessionsArea.sessionDefinitions(runtime: rig, surface: rig)
    return try await V.handler(id, in: definitions)(V.context(), args)
  }
  func testPendingChatScreenReturnsItsRealRequestWithoutAFalseExit() async throws {
    let rig = BackendDeckToolsSessionsPortRig()
    await rig.setChatSnapshot(pending())
    let reply = try await call("sessions.screen", V.object([("sessionId", .string("s1"))]), rig)
    let value = try XCTUnwrap(reply.structuredContent)
    XCTAssertEqual(value["source"], .string("chat"))
    XCTAssertEqual(value["pending"].elements?.first?["requestId"], .string("request-6"))
    XCTAssertEqual(value["pending"].elements?.first?["input"]["message"], .string("Allow this scratch tool?"))
    XCTAssertTrue(value["screen"].string?.contains("request-6") == true)
    XCTAssertTrue(value["note"].isNullish)
  }
  func testTypedPermissionAnswerIsRefusedBeforeAnyKeyIsWritten() async throws {
    let rig = BackendDeckToolsSessionsPortRig()
    await rig.setChatSnapshot(pending())
    let reply = try await call("sessions.keys", V.object([("sessionId", .string("s1")), ("keys", .array([.string("y"), .string("enter")]))]), rig)
    XCTAssertTrue(reply.isError)
    XCTAssertTrue(V.error(reply).contains("sessions_chat with do: answer"))
    let writes = await rig.captured("write")
    XCTAssertTrue(writes.isEmpty)
  }
  func testInterruptRemainsAvailableWhileAChatAsks() async throws {
    let rig = BackendDeckToolsSessionsPortRig()
    await rig.setChatSnapshot(pending())
    let reply = try await call("sessions.keys", V.object([("sessionId", .string("s1")), ("keys", .array([.string("ctrl-c")]))]), rig)
    XCTAssertFalse(reply.isError)
    let writes = await rig.captured("write")
    XCTAssertEqual(writes.map { $0["data"] }, [.string("\u{03}")])
  }
  func testUnavailableLiveTerminalScreenDoesNotClaimTheProcessEnded() async throws {
    let rig = BackendDeckToolsSessionsPortRig()
    let reply = try await call("sessions.screen", V.object([("sessionId", .string("s1"))]), rig)
    XCTAssertTrue(reply.structuredContent?["note"].string?.contains("does not mean the session has ended") == true)
  }
  func testBlockedWaitIncludesTheChatPermissionRatherThanAnEmptyTerminal() async throws {
    let rig = BackendDeckToolsSessionsPortRig()
    await rig.setChatSnapshot(pending()); await rig.setSignal(status: "input", at: 1)
    let reply = try await call("sessions.wait", V.object([("sessionId", .string("s1"))]), rig)
    XCTAssertEqual(reply.structuredContent?["outcome"], .string("blocked"))
    XCTAssertEqual(reply.structuredContent?["pending"].elements?.first?["requestId"], .string("request-6"))
    XCTAssertFalse(reply.structuredContent?["screen"].string?.isEmpty ?? true)
  }
  func testFinishedChatWaitReportsFinishedWhileTerminalExitStillReportsExited() async throws {
    let rig = BackendDeckToolsSessionsPortRig()
    await rig.setRows([V.row(exit: 0).setting("chat", .bool(true))])
    let reply = try await call("sessions.wait", V.object([("sessionId", .string("s1"))]), rig)
    XCTAssertEqual(reply.structuredContent?["outcome"], .string("finished"))
  }
  func testBoardKeepsChatJobResultAcrossLateStatusAndRestoredRows() {
    let stamp = DeckMemoryStamp(owner: .project("scratch"), project: "scratch")
    var board = DeckMemoryFlowBoard()
    _ = board.sessionSeen(.init(id: "chat", title: "Scratch job", provider: "codex", stamp: stamp, chat: true))
    _ = board.sessionStatus(id: "chat", status: "input")
    let ended = board.sessionExited(id: "chat", code: 0)
    XCTAssertEqual(ended.updates.first { $0.id == "session:chat" }?.doing, "Finished")
    XCTAssertEqual(ended.updates.first { $0.id == "session:chat" }?.waitingForUser, "")
    XCTAssertTrue(board.sessionStatus(id: "chat", status: "completed").updates.isEmpty)
    _ = board.sessionSeen(.init(id: "failed", title: "Failed job", provider: "codex", stamp: stamp, status: "exited", exitCode: 1, chat: true))
    XCTAssertEqual(board.sessions["failed"]?.exitCode, 1)
    XCTAssertEqual(DeckMemoryFlowBoard.doing("exited", exitCode: 1, chat: true), "Failed (code 1)")
    XCTAssertEqual(DeckMemoryFlowBoard.doing("exited", exitCode: 0), "Stopped")
    var restored = DeckMemoryFlowBoard()
    let replay = restored.sessionSeen(.init(id: "chat", title: "Scratch job", provider: "codex", stamp: stamp, status: "exited", exitCode: 0, chat: true))
    XCTAssertEqual(replay.updates.first { $0.id == "session:chat" }?.doing, "Finished")
  }
  func testChatEnterHasTheSameReplyDeadlineAsAChatSend() {
    func deadline(_ method: String) -> Int {
      var request = BackendHOSTProtocol.Request(secret: "scratch", operation: .resource)
      request.resourceMethod = method
      return BackendHOSTClient.replyDeadlineMilliseconds(request)
    }
    XCTAssertEqual(deadline("chats.type"), deadline("chats.say"))
    XCTAssertEqual(deadline("chats.type"), 60_000)
    XCTAssertEqual(deadline("chats.read"), 10_000)
  }
  func testMatchedKeeperWaitsForAChatEnterReplyPastTenSeconds() async throws {
    let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("drops-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = try BackendHOSTPaths(dataDirectory: root)
    _ = try paths.secret(create: true)
    let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
    let server = try BackendHOSTServer(paths: paths, hostVersion: "0.21.0-scratch", manager: manager,
      launch: { _ in throw BackendHOSTFailure.unavailable }, snapshot: { _ in nil }, onIdle: {},
      resource: { method, _ in
        guard method == "chats.type" else { throw BackendHOSTFailure.unavailable }
        try await Task.sleep(for: .seconds(11))
        return try NativeRPCValue.bool(true).encodedJSON()
      })
    defer { server.stopListening() }
    let client = try BackendHOSTClient(paths: paths)
    defer { client.detach() }
    let result = try await client.resource("chats.type", arguments: V.object([("id", .string("scratch")), ("text", .string("\r"))]))
    XCTAssertEqual(result, .bool(true))
    XCTAssertEqual(client.hello.hostVersion, "0.21.0-scratch")
  }

}
