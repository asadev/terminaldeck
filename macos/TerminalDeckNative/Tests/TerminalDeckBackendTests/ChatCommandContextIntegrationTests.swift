import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// F05/F08 use the ordinary Chat codecs, without UI singletons, system services or provider turns.
final class ChatCommandContextIntegrationTests: XCTestCase {
    private func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private func reply(_ id: NativeRPCValue, _ result: NativeRPCValue) -> NativeRPCValue { object([("id", id), ("result", result)]) }
    private func ready(_ provider: HootChatProvider) throws -> BackendHootChatRPC {
        var rpc = BackendHootChatRPC(provider: provider, setup: .init(cwd: "/scratch/project"))
        let hello = try rpc.begin(id: "fixture-hello", resume: nil)
        let capabilities = object([("protocolVersion", .number(1)), ("agentCapabilities", .object([]))])
        let initialized = try rpc.receive(reply(hello["id"], provider == .codex ? .object([]) : capabilities))
        let start = try XCTUnwrap(initialized.send.last)
        let result = provider == .codex
            ? object([("thread", object([("id", .string("fixture-conversation"))])), ("model", .string("fixture-model"))])
            : object([("sessionId", .string("fixture-conversation"))])
        XCTAssertTrue(try rpc.receive(reply(start["id"], result)).ready)
        return rpc
    }
    private func context() throws -> BackendHOOTSIMChatContext {
        let file = try BackendChatReferences.content(path: "Sources/check.swift", kind: "file",
            value: object([("kind", .string("text")), ("text", .string("let fixture = true\n"))]))
        return try BackendHOOTSIMChatContext(wire: object([
            ("mentions", .array([
                object([("id", .string("agent-fixture")), ("kind", .string("agent")), ("name", .string("Builder"))]),
                object([("id", .string("session-fixture")), ("kind", .string("session")), ("name", .string("Other chat"))])])),
            ("source", object([("title", .string("Fixture context"))])), ("files", .array([file]))]))
    }

    func testOrdinaryContextReachesAllThreeProviderUserMessageFormatsWithExactIDsAndFileText() throws {
        let context = try context(), delivered = try context.message("Inspect this context")
        for provider in [HootChatProvider.claude, .codex, .gemini] {
            let request: NativeRPCValue, text: String?
            if provider == .claude {
                request = BackendHootChatCLI.user(delivered)
                text = request["message"]["content"].elements?.first?["text"].string
                XCTAssertEqual(request["type"].string, "user")
            } else {
                var rpc = try ready(provider)
                request = try rpc.user(delivered, attachments: [], id: "fixture-turn", commandText: "Inspect this context")
                let key = provider == .codex ? "input" : "prompt"
                text = request["params"][key].elements?.first?["text"].string
                XCTAssertEqual(request["method"].string, provider == .codex ? "turn/start" : "session/prompt")
                XCTAssertEqual(request["params"][provider == .codex ? "threadId" : "sessionId"].string, "fixture-conversation")
            }
            XCTAssertEqual(text, delivered)
            XCTAssertTrue(text?.contains("agent-fixture") == true)
            XCTAssertTrue(text?.contains("session-fixture") == true)
            XCTAssertTrue(text?.contains("let fixture = true") == true)
            XCTAssertEqual(context.value["mentions"].elements?.count, 2)
            XCTAssertEqual(context.value["files"].elements?.first?["path"].string, "Sources/check.swift")
        }
    }

    func testCodexCompactAndReviewDispatchUseTheTypedCommandRatherThanAppendedContext() throws {
        let context = try context()
        var compact = try ready(.codex)
        let compactRequest = try compact.user(context.message("/compact"), attachments: [], id: "compact", commandText: "/compact")
        XCTAssertEqual(compactRequest["method"].string, "thread/compact/start")
        XCTAssertEqual(compactRequest["params"]["threadId"].string, "fixture-conversation")
        var review = try ready(.codex)
        let reviewRequest = try review.user(context.message("/review keep the scope"), attachments: [], id: "review", commandText: "/review keep the scope")
        XCTAssertEqual(reviewRequest["method"].string, "review/start")
        XCTAssertEqual(reviewRequest["params"]["target"]["type"].string, "custom")
        XCTAssertEqual(reviewRequest["params"]["target"]["instructions"].string, "keep the scope")
    }

    func testCodexPlanCarriesContextButRejectedCommandDoesNotAcquireTheNextTurn() throws {
        let context = try context()
        var plan = try ready(.codex)
        let planned = try plan.user(context.message("/plan inspect the files"), attachments: [], id: "plan", commandText: "/plan inspect the files")
        XCTAssertEqual(planned["params"]["collaborationMode"]["mode"].string, "plan")
        XCTAssertTrue(planned["params"]["input"].elements?.first?["text"].string?.contains("agent-fixture") == true)
        var refused = try ready(.codex)
        XCTAssertThrowsError(try refused.user(context.message("/compact unexpected argument"), attachments: [], id: "refused", commandText: "/compact unexpected argument"))
        let next = try refused.user("ordinary message", attachments: [], id: "next")
        XCTAssertEqual(next["method"].string, "turn/start")
        XCTAssertEqual(next["id"].string, "next")
    }

    func testMentionMetadataCannotAddAuthorityOrSmuggleCredentialFileContext() throws {
        let metadata = object([("id", .string("agent-fixture")), ("kind", .string("agent")), ("name", .string("Builder")), ("permission", .string("allow"))])
        XCTAssertThrowsError(try BackendHOOTSIMChatContext(wire: object([("mentions", .array([metadata]))])))
        XCTAssertThrowsError(try BackendChatReferences.content(path: ".env", kind: "file", value: object([("kind", .string("text")), ("text", .string("fixture-only"))])))
        XCTAssertThrowsError(try BackendHOOTSIMChatContext(wire: object([("files", .array(Array(repeating: object([
            ("kind", .string("file")), ("path", .string("safe.txt")), ("text", .string("fixture-only"))]), count: 9)))])))
    }
}
