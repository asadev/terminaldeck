import AppKit
import SwiftUI
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatRewindForkUITests: XCTestCase {
    private func fixture() -> NativeHootChatModel {
        let turn = "11111111-1111-4111-8111-111111111111"
        let records: [HootChatRecord] = [.text(.user, id: turn, "Make the title shorter."), .text(.textDelta, id: "msg-a", "Here"),
            .init(.message, id: "msg-a", value: .object([.init("text", .string("Here is the shorter title. You can fork this conversation here, or rewind your message to try another direction.")),
                .init("providerMessageId", .string("22222222-2222-4222-8222-222222222222"))])), .init(.completed)]
        let events = records.enumerated().map { index, record in HootChatEvent(conversationID: "scratch", turnID: turn, sequence: index + 1, provider: .claude, record: record) }
        return NativeHootChatModel(fixture: .object([.init("conversationId", .string("scratch")), .init("provider", .string("claude")),
            .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true)), .init("busy", .bool(false)),
            .init("messageActions", .array(BackendChatMessageActions.rows(events, provider: .claude)))]), source: .session("scratch", provider: "claude"))
    }
    func testUserKeepsRewindAndBothSidesKeepForkAfterStreaming() throws {
        let model = fixture()
        let user = try XCTUnwrap(model.rows.first { $0.kind == .user })
        let answer = try XCTUnwrap(model.rows.first { $0.kind == .message })
        XCTAssertTrue(model.messageAction("rewind", row: user))
        XCTAssertFalse(model.messageAction("rewind", row: answer))
        XCTAssertTrue(model.messageAction("fork", row: user))
        XCTAssertTrue(model.messageAction("fork", row: answer), "Final receipt must reach the row created by the first streaming fragment")
        XCTAssertNotEqual(answer.sequence, model.messageActions.last?["sequence"].number.map(Int.init))
    }
    func testCopiedForkPrefixIsNotReportedAsInterrupted() throws {
        let turn = "11111111-1111-4111-8111-111111111111"
        let own = HootChatEvent(conversationID: "fork-prefix", turnID: turn, sequence: 1, provider: .claude, record: .text(.user, id: turn, "copied user message"))
        let state = NativeRPCValue.object([.init("conversationId", .string("fork-prefix")), .init("provider", .string("claude")),
            .init("forkPrefix", .bool(true)), .init("events", .array([own.wireValue])), .init("alive", .bool(true)), .init("busy", .bool(false))])
        let model = NativeHootChatModel(fixture: state, source: .session("fork-prefix", provider: "claude"))
        XCTAssertNil(model.retryRow)
        XCTAssertNil(model.unfinishedTurn)
        let fresh = HootChatEvent(conversationID: "fork-prefix", turnID: "new-own-turn", sequence: 2, provider: .claude, record: .text(.user, id: "new-own-turn", "first new message"))
        model.acceptFixtureUpdate(state.setting("forkPrefix", .bool(false)).setting("reset", .bool(true)).setting("events", .array([own.wireValue, fresh.wireValue])))
        XCTAssertEqual(model.retryRow?.value["text"].string, "first new message")
    }
    func testForkNestedRequestsKeepAuthorityAndHaveSeparateIDs() async throws {
        let parent = NativeRPCContext(caller: .page, ownerID: "fork-owner", origin: URL(string: "https://scratch.invalid"), capabilities: ["session.create"])
        let first = NativeChatForkRequest.child(parent), second = NativeChatForkRequest.child(parent)
        XCTAssertNotEqual(first.requestID, parent.requestID)
        XCTAssertNotEqual(first.requestID, second.requestID)
        XCTAssertEqual(first.caller, parent.caller)
        XCTAssertEqual(first.ownerID, parent.ownerID)
        XCTAssertEqual(first.origin, parent.origin)
        XCTAssertEqual(first.capabilities, parent.capabilities)
        let registry = NativeChannelRegistry()
        try await registry.register("fork:inner", ownerID: "fork-test", policy: { try $0.require("session.create") }) { context, _ in .string(context.ownerID) }
        try await registry.register("fork:outer", ownerID: "fork-test") { context, _ in
            try await registry.invoke("fork:inner", context: NativeChatForkRequest.child(context), arguments: [])
        }
        let result = try await registry.invoke("fork:outer", context: parent, arguments: [])
        XCTAssertEqual(result.string, "fork-owner")
    }
    func testPendingForkActionsWaitForTheProvidersConversationReceipt() throws {
        let model = fixture(), actions = model.messageActions
        let state = NativeRPCValue.object([.init("conversationId", .string(model.conversationID)), .init("provider", .string("claude")),
            .init("forkPrefix", .bool(true)), .init("providerConversationId", .null), .init("reset", .bool(true)),
            .init("events", .array(model.transcriptExportEvents.map(\.wireValue))), .init("messageActions", .array(actions)),
            .init("alive", .bool(true)), .init("busy", .bool(false))])
        model.acceptFixtureUpdate(state)
        let user = try XCTUnwrap(model.rows.first { $0.kind == .user })
        let answer = try XCTUnwrap(model.rows.first { $0.kind == .message })
        XCTAssertFalse(model.messageAction("rewind", row: user))
        XCTAssertFalse(model.messageAction("fork", row: user))
        XCTAssertFalse(model.messageAction("fork", row: answer))
        model.acceptFixtureUpdate(state.setting("forkPrefix", .bool(false)).setting("providerConversationId", .string("confirmed-fork")))
        XCTAssertTrue(model.messageAction("rewind", row: user))
        XCTAssertTrue(model.messageAction("fork", row: answer))
    }
    func testToolRewindReplacesVisibleHistoryAndRestoresTheEditableText() async throws {
        let first = HootChatEvent(conversationID: "rewind-tool", turnID: "first", sequence: 1, provider: .claude, record: .text(.user, id: "first", "keep this"))
        let later = HootChatEvent(conversationID: "rewind-tool", turnID: "later", sequence: 2, provider: .claude, record: .text(.user, id: "later", "edit this"))
        let after = NativeRPCValue.object([.init("conversationId", .string("rewind-tool")), .init("events", .array([first.wireValue])),
            .init("alive", .bool(true)), .init("busy", .bool(false)), .init("hasMore", .bool(false)), .init("cursor", .number(1))])
        let before = after.setting("events", .array([first.wireValue, later.wireValue])).setting("cursor", .number(2))
        let model = NativeHootChatModel(fixture: before, chatInvoke: { channel, _ in
            XCTAssertTrue(channel.hasSuffix(":read"))
            return after.foundation ?? [:]
        }, source: .session("rewind-tool", provider: "claude"))
        try await model.finishRewind("edit this")
        XCTAssertEqual(model.rows.filter { $0.kind == .user }.map { $0.value["text"].string }, ["keep this"])
        XCTAssertEqual(model.composerDraft.text, "edit this")
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative/NativeChatMessageActions.swift")
        XCTAssertTrue(try String(contentsOf: path, encoding: .utf8).contains("model.finishRewind("))
    }
    func testMessageButtonsStayVisibleAndOnlyConfirmationCallsRewind() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TerminalDeckNative/NativeHootChat.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let frame = try XCTUnwrap(text.range(of: "struct HootMessageFrame<"))
        let body = String(text[frame.lowerBound...])
        XCTAssertFalse(body.contains("if hovering || copied"))
        XCTAssertTrue(body.contains("if row.at > 0 && hovering"))
        XCTAssertTrue(body.contains("if let onFork"))
        XCTAssertTrue(body.contains("if let onRewind"))
        XCTAssertTrue(body.contains(#".alert("Rewind to here?""#))
        XCTAssertTrue(body.contains(#"Button("Rewind", role: .destructive) { onRewind?() }"#))
        XCTAssertTrue(text.contains(#"model.messageAction("rewind", row: row)"#))
        XCTAssertTrue(text.contains(#"model.messageAction("fork", row: row)"#))
        XCTAssertTrue(text.contains(#"model.messageAction("fork", row: answer)"#))
    }
    func testLightAndDarkMessageActionsRenderWithoutHover() throws {
        guard let output = ProcessInfo.processInfo.environment["TD_REWIND_RENDER_DIR"] else { throw XCTSkip("Opt-in image capture") }
        let folder = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let model: NativeHootChatModel
            if let live = ProcessInfo.processInfo.environment["TD_REWIND_LIVE_ROOT"],
               let bytes = try? Data(contentsOf: URL(fileURLWithPath: live).appendingPathComponent("backend-claude/proof.json")),
               let proof = try? NativeRPCValue.parseJSON(bytes) {
                model = NativeHootChatModel(fixture: proof["original"], source: .session("scratch-live", provider: "claude"))
            } else { model = fixture() }
            let size = CGSize(width: 980, height: 720)
            let host = NSHostingView(rootView: NativeHootChat(model: model)
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: .init(origin: .init(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
            for _ in 0..<8 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
            XCTAssertFalse(window.isVisible)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("message-actions-\(dark ? "dark" : "light").png"))
            window.contentView = nil; window.close()
        }
    }
}
