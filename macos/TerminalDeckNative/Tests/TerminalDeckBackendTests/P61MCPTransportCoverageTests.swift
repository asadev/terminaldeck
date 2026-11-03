import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class P61MCPTransportCoverageTests: XCTestCase {
    func testFastCallsReturnTheirValueAndWaitToolsAreExempt() async {
        let value = await BackendMCPCallBudget.within(1) { 42 }
        XCTAssertEqual(value, 42)
        XCTAssertTrue(BackendMCPCallBudget.exempt(name: "sessions_WAIT", arguments: .null))
        XCTAssertTrue(BackendMCPCallBudget.exempt(name: "tools.call", arguments: .object([.init("name", .string("notifications_wait"))])))
        XCTAssertTrue(!BackendMCPCallBudget.exempt(name: "tasks_get", arguments: .null))
    }

    func testBudgetExpiryAnswersWithoutCancellingTheWork() async {
        let gate = Barrier(), completed = Barrier()
        let answer = await BackendMCPCallBudget.within(0) {
            await gate.wait()
            await completed.release()
            return 7
        }
        XCTAssertTrue(answer == nil)
        await gate.release()
        await completed.wait()
        let pending = BackendMCPCallBudget.stillRunning(tool: "tools.call", arguments: .object([.init("name", .string("tasks_run"))]), startedAt: 123)
        XCTAssertTrue(pending["stillRunning"] == .bool(true))
        XCTAssertTrue(pending["tool"] == .string("tasks_run"))
        XCTAssertTrue(pending["startedAt"] == .number(123))
    }

    func testRelaySelectsTheLastMatchingEventAndRejectsMissingReplies() throws {
        let stream = "data: {\"id\":1,\"result\":\"old\"}\r\n\r\ndata: {\"method\":\"notice\"}\r\n\r\ndata: {\"id\":2,\"result\":\"other\"}\r\n\r\ndata: {\"id\":1,\r\ndata: \"result\":\"new\"}\r\n\r\n"
        let result = try BackendMCPStdioRelay.eventStreamReply(Data(stream.utf8), id: .number(1))
        XCTAssertTrue(result["result"] == .string("new"))
        XCTAssertThrowsError(try BackendMCPStdioRelay.eventStreamReply(Data(stream.utf8), id: .number(3)))
        XCTAssertThrowsError(try BackendMCPStdioRelay.eventStreamReply(Data([0xff]), id: .number(1)))
    }

    func testRelayRefusesNonOwnedTokenBeforeReadingStdin() async {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/p61-relay-" + UUID().uuidString)
        do {
            try await BackendMCPStdioRelay.run(endpoint: URL(string: "http://127.0.0.1:1234/mcp")!,
                tokenFile: root.appendingPathComponent("outside.token"), trustedUserData: root)
            XCTFail("An unowned token was accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("app-owned")) }
    }

    func testHTTPTransportPassesMethodPathHeadersAndBodyAndStops() async throws {
        let transport = BackendMCPHTTPTransport { request, _ in
            .json(.object([.init("method", .string(request.method)), .init("path", .string(request.path)),
                .init("authorization", .string(request.headers["authorization"] ?? "")),
                .init("body", .string(String(decoding: request.body, as: UTF8.self)))]))
        }
        let port = try await transport.start()
        defer { transport.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp?fixture=1")!)
        request.httpMethod = "POST"; request.httpBody = Data("fixture".utf8)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3
        let (body, response) = try await session.data(for: request)
        XCTAssertTrue((response as? HTTPURLResponse)?.statusCode == 200)
        let value = try NativeRPCValue.parseJSON(body)
        XCTAssertTrue(value["method"] == .string("POST"))
        XCTAssertTrue(value["path"] == .string("/mcp?fixture=1"))
        XCTAssertTrue(value["authorization"] == .string("Bearer fixture"))
        XCTAssertTrue(value["body"] == .string("fixture"))
        do { _ = try await transport.start(); XCTFail("A second listener was accepted") } catch {}
    }

    func testHTTPTransportRejectsOversizedBodyWithoutCallingHandler() async throws {
        let transport = BackendMCPHTTPTransport { _, _ in XCTFail("Oversized input reached the tool handler"); return .empty(200) }
        let port = try await transport.start()
        defer { transport.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"; request.httpBody = Data(repeating: 65, count: 256 * 1024 + 1); request.timeoutInterval = 3
        let (_, response) = try await session.data(for: request)
        XCTAssertTrue((response as? HTTPURLResponse)?.statusCode == 413)
    }
}

private actor Barrier {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiting.append($0) } } }
    func release() { open = true; let current = waiting; waiting = []; for waiter in current { waiter.resume() } }
}
