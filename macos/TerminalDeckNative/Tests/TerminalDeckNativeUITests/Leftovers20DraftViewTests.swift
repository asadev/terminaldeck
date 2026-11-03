import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class Leftovers20DraftViewTests: XCTestCase {
    func testToolDraftAppearsInComposerAndOrdinaryPushDoesNotOverwriteLocalEditing() {
        let snapshot = NativeRPCValue.object([.init("conversationId", .string("chat")), .init("sequence", .number(0)), .init("events", .array([]))])
        let model = NativeHootChatModel(fixture: snapshot, source: .session("s", provider: "claude"))
        let draft = snapshot.setting("draft", .string("from sessions_send")).setting("draftRevision", .number(1))
        model.acceptFixtureUpdate(draft)
        XCTAssertEqual(model.composerDraft.text, "from sessions_send")
        model.composerDraft.text += " and edited here"
        model.acceptFixtureUpdate(draft)
        XCTAssertEqual(model.composerDraft.text, "from sessions_send and edited here")
        model.acceptFixtureUpdate(draft.setting("draft", .string("")).setting("draftRevision", .number(2)))
        XCTAssertEqual(model.composerDraft.text, "")
        model.acceptFixtureUpdate(draft)
        XCTAssertEqual(model.composerDraft.text, "", "An older push cannot bring a sent draft back")
    }
}
