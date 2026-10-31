import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatCommandMatrixTests: XCTestCase {
    func testMatrixAndTypedDispatchAgreeAndDoNotTreatAbsolutePathsAsCommands() throws {
        let raw: NativeRPCValue = .array(["model", "compact", "mcp"].map { .object([.init("name", .string($0))]) })
        let offered = HootSlashCommand.offered(raw)
        XCTAssertEqual(try NativeChatCommands.resolve("/model", offered: offered)?.opensInApp, "Chat model picker")
        XCTAssertNil(try NativeChatCommands.resolve("/Users/me/file.txt", offered: offered))
        XCTAssertThrowsError(try NativeChatCommands.resolve("/mcp", offered: offered))
        XCTAssertThrowsError(try NativeChatCommands.resolve("/model arbitrary", offered: offered))
        XCTAssertEqual(try NativeChatCommands.resolve("/compact note", offered: offered)?.name, "compact")
        XCTAssertEqual(NativeChatCommands.wire(reported: raw, provider: "codex", hoot: false)["commands"].elements?.last?["dispatch"].string, "unavailable-in-chat")
        let model = NativeHootChatModel(fixture: .object([.init("commands", raw)]))
        _ = try model.commandsTool("prepare", request: "model", text: nil)
        XCTAssertEqual(model.chatControlTarget, "model")
        _ = try model.commandsTool("prepare", request: "compact", text: "keep scope")
        XCTAssertEqual(model.composerDraft.text, "/compact keep scope")
    }
    /// Review chat-backend #1 / chat-ui #2: only freshly typed text that opens an app control is intercepted.
    func testOnlyOfferedAppControlsAreInterceptedEverythingElseSendsAsPlainText() throws {
        let raw: NativeRPCValue = .array(["model", "compact", "mcp"].map { .object([.init("name", .string($0))]) })
        let offered = HootSlashCommand.offered(raw)
        // No command list reported yet (Gemini, or before the list arrives): nothing is refused.
        for text in ["/tmp is full, please clean it", "/compact", "/model", "/login now"] {
            XCTAssertNil(try NativeChatCommands.appControl(in: text, offered: []), text)
        }
        // A provider command or an unknown name is plain text.
        XCTAssertNil(try NativeChatCommands.appControl(in: "/compact keep scope", offered: offered))
        XCTAssertNil(try NativeChatCommands.appControl(in: "/tmp is full", offered: offered))
        XCTAssertNil(try NativeChatCommands.appControl(in: "/mcp", offered: offered))
        XCTAssertNil(try NativeChatCommands.appControl(in: "hello /model", offered: offered))
        // An offered app control opens; inline arguments are still refused for it.
        XCTAssertEqual(try NativeChatCommands.appControl(in: "/model", offered: offered)?.name, "model")
        XCTAssertThrowsError(try NativeChatCommands.appControl(in: "/model arbitrary", offered: offered))
    }
    /// send() is a no-op in fixture mode, so the queued-text rule is pinned in the source: a queued item
    /// (queuedID != nil) never reaches the command interception.
    func testQueuedMessagesNeverReachSlashInterception() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative/NativeHootChat.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        let guardRange = try XCTUnwrap(source.range(of: "if queuedID == nil {\n            do { if let command = try NativeChatCommands.appControl("))
        let route = try XCTUnwrap(source.range(of: "routeSlashCommand(command); return"))
        XCTAssertLessThan(guardRange.lowerBound, route.lowerBound)
        XCTAssertFalse(source.contains("NativeChatCommands.resolve(saved.text"))
    }
}
