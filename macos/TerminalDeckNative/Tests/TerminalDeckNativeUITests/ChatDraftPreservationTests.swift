import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatDraftPreservationTests: XCTestCase {
    func testLegacyReplacementOnlyInfersAnAlreadyKnownChat() {
        XCTAssertEqual(NativeButtonActions.replacementMetadata([:], knownChat: true)["chat"] as? Bool, true)
        XCTAssertNil(NativeButtonActions.replacementMetadata([:], knownChat: false)["chat"])
        XCTAssertEqual(NativeButtonActions.replacementMetadata(["chat": false], knownChat: true)["chat"] as? Bool, false)
    }
    private func model() -> NativeHootChatModel {
        NativeHootChatModel(fixture: .object([.init("conversationId", .string(UUID().uuidString)),
            .init("provider", .string("claude")), .init("events", .array([])), .init("alive", .bool(true)),
            .init("busy", .bool(true))]), source: .session(UUID().uuidString, provider: "claude"))
    }
    func testColdBackendKeepsRestoredDraftButLaterExplicitClearWins() {
        let chat = model()
        chat.composerDraft.text = "restored draft"
        chat.composerDraft.insert(.init(id: "check-agent", kind: .agent, name: "Check Agent"))
        chat.composerDraft.add([URL(fileURLWithPath: "/scratch/check-image.png")])
        let saved = chat.composerDraft
        let initial = NativeRPCValue.object([.init("conversationId", .string(chat.conversationID)),
            .init("events", .array([])), .init("alive", .bool(true)), .init("draft", .string("")),
            .init("draftRevision", .number(0))])
        chat.acceptFixtureUpdate(initial)
        XCTAssertEqual(chat.composerDraft, saved)
        chat.acceptFixtureUpdate(initial.setting("draftRevision", .number(1)))
        XCTAssertEqual(chat.composerDraft.text, "")
        XCTAssertEqual(chat.composerDraft.mentions, saved.mentions)
        XCTAssertEqual(chat.composerDraft.attachments, saved.attachments)
    }
    func testStopHoldKeepsSeparateMessagesAndComposer() async throws {
        let chat = model()
        chat.composerDraft.text = "keep my composer"
        _ = try await chat.queueTool("queue", id: nil, text: "first", context: .object([.init("source", .string("first-source"))]))
        _ = try await chat.queueTool("queue", id: nil, text: "second", context: .object([.init("source", .string("second-source"))]))
        let ids = chat.queuedMessages.map(\.id)
        chat.holdQueuedMessages("Stopped")
        XCTAssertEqual(chat.composerDraft.text, "keep my composer")
        XCTAssertEqual(chat.queuedMessages.map(\.id), ids)
        XCTAssertEqual(chat.queuedMessages.map(\.draft.text), ["first", "second"])
        XCTAssertEqual(chat.queuedMessages.map { $0.context?["source"].string }, ["first-source", "second-source"])
        XCTAssertTrue(chat.queuedMessages.allSatisfy(\.held))
    }
    func testProviderHandoverCopiesStructuredDraftAndQueue() async throws {
        let old = model(), next = model()
        let mention = HootMention(id: "agent-check", kind: .agent, name: "Check Agent")
        old.composerDraft.insert(mention)
        old.composerDraft.add([URL(fileURLWithPath: "/scratch/own-check.png")])
        _ = try await old.queueTool("queue", id: nil, text: "keep queued", context: .object([.init("kind", .string("capture"))]))
        next.carryDisplay(from: old)
        XCTAssertEqual(next.composerDraft.mentions, old.composerDraft.mentions)
        XCTAssertEqual(next.composerDraft.attachments, old.composerDraft.attachments)
        XCTAssertEqual(next.queuedMessages.map(\.id), old.queuedMessages.map(\.id))
        XCTAssertEqual(next.queuedMessages.first?.context?["kind"].string, "capture")
        XCTAssertTrue(next.queuedMessages.first?.held == true)
        next.composerDraft.text = "newer draft after handover"
        next.carryDisplay(from: old)
        XCTAssertEqual(next.composerDraft.text, "newer draft after handover", "A later duplicate event cannot replace newer text")
        XCTAssertEqual(next.queuedMessageCount, 1)
    }
    func testOutboxRoundTripPreservesDraftAndTabIdentityWithoutQueue() throws {
        let id = "check-draft-" + UUID().uuidString
        defer { NativeChatOutbox.remove(id) }
        var draft = HootComposerDraft()
        draft.insert(.init(id: "agent-check", kind: .agent, name: "Check Agent"))
        draft.add([URL(fileURLWithPath: "/scratch/own-check.png")])
        try NativeChatOutbox.save(id, name: "check", entries: [], draft: draft, tabKey: "stable-check")
        let saved = try XCTUnwrap(NativeChatOutbox.load(id))
        XCTAssertEqual(saved.draft, draft)
        XCTAssertEqual(saved.tabKey, "stable-check")
        XCTAssertTrue(NativeChatOutbox.sessions.contains(id))
        try NativeChatOutbox.save(id, name: "check", entries: [], draft: HootComposerDraft())
        XCTAssertNil(NativeChatOutbox.load(id))
    }
    /// F50: opening a chat after an app relaunch used to re-save the half-restored state
    /// (text only, empty queue) over the stored queue, mentions and attachments.
    func testRelaunchRestoreKeepsQueueMentionsAndAttachmentsInStorage() async throws {
        let id = "check-relaunch-" + UUID().uuidString.lowercased()
        defer { NativeChatOutbox.remove(id) }
        var draft = HootComposerDraft()
        draft.text = "typed before quit"
        draft.insert(.init(id: "agent-check", kind: .agent, name: "Check Agent"))
        draft.add([URL(fileURLWithPath: "/scratch/relaunch-check.png")])
        var queued = HootComposerDraft(); queued.text = "queued before quit"
        queued.add([URL(fileURLWithPath: "/scratch/queued-check.png")])
        try NativeChatOutbox.save(id, name: "check", entries: [.init(id: "q1", draft: queued, context: nil, held: true, problem: nil)],
                                  draft: draft, tabKey: "stable-check")
        let chat = NativeHootChatModel(source: .session(id, provider: "claude"))
        XCTAssertEqual(chat.composerDraft.text, draft.text)
        XCTAssertEqual(chat.composerDraft.mentions, draft.mentions)
        XCTAssertEqual(chat.composerDraft.attachments, draft.attachments)
        XCTAssertEqual(chat.queuedMessages.map(\.id), ["q1"])
        XCTAssertEqual(chat.queuedMessages.first?.draft.attachments, queued.attachments)
        let stored = try XCTUnwrap(NativeChatOutbox.load(id))
        XCTAssertEqual(stored.entries.map(\.id), ["q1"], "Restoring must not overwrite the saved queue")
        XCTAssertEqual(stored.draft?.mentions, draft.mentions)
        XCTAssertEqual(stored.draft?.attachments, draft.attachments)
        XCTAssertEqual(stored.tabKey, "stable-check")
        chat.composerDraft.text += " and more"
        let edited = try await saved(id) { $0.draft?.text == draft.text + " and more" }
        XCTAssertEqual(edited.draft?.mentions, draft.mentions)
        XCTAssertEqual(edited.entries.map(\.id), ["q1"])
    }
    /// #174: typing saves the draft once it pauses, not on every key press.
    func testTypingSavesTheDraftOnceItPauses() async throws {
        let id = "check-typing-" + UUID().uuidString.lowercased()
        defer { NativeChatOutbox.remove(id) }
        let chat = NativeHootChatModel(source: .session(id, provider: "claude"))
        for character in "typed quickly" { chat.composerDraft.text.append(character) }
        XCTAssertNil(NativeChatOutbox.load(id), "Nothing is saved while the keys are still coming")
        _ = try await saved(id) { $0.draft?.text == "typed quickly" }
    }
    private func saved(_ id: String, _ check: (NativeChatOutbox.Saved) -> Bool) async throws -> NativeChatOutbox.Saved {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if let saved = NativeChatOutbox.load(id), check(saved) { return saved }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(nil as NativeChatOutbox.Saved?, "The draft was not saved")
    }
}
