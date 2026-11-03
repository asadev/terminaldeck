import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// U7 (#1): Stop pressed right after Send never loses the typed message.
@MainActor final class ChatStopKeepsDraftTests: XCTestCase {
    func testStopRightAfterSendPutsTheTypedMessageBack() async throws {
        let state = NativeRPCValue.object([.init("conversationId", .string("stop-test")), .init("provider", .string("codex")),
            .init("model", .string("test")), .init("sequence", .number(0)), .init("events", .array([])),
            .init("alive", .bool(true)), .init("busy", .bool(false))])
        var verbs: [String] = []
        let chat = NativeHootChatModel(fixture: state, chatInvoke: { channel, _ in
            verbs.append(channel)
            return state.foundation ?? [:]
        }, source: .session(UUID().uuidString, provider: "codex"))
        chat.composerDraft.text = "A long message I typed"
        chat.send()
        XCTAssertEqual(chat.composerDraft.text, "")
        chat.stop()
        for _ in 0..<200 where chat.sending || chat.stopping { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(chat.composerDraft.text, "A long message I typed")
        XCTAssertFalse(verbs.contains { $0.hasSuffix(":say") })
        XCTAssertTrue(verbs.contains { $0.hasSuffix(":stop") })
        XCTAssertNil(chat.problem)
    }
}
