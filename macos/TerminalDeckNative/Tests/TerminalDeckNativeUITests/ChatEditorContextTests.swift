import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class ChatEditorContextTests: XCTestCase {
    func testUnicodeSelectionReceiptAndDraftPreservationRejectStaleBuffers() throws {
        let store = NativeChatEditorContexts()
        store.update(id: "buffer", path: "/scratch/code.swift", text: "a\n🙂beta\nlast", selection: NSRange(location: 3, length: 1), truncated: false)
        let snapshot = try XCTUnwrap(store.snapshots.first), prepared = try snapshot.context("selection")
        XCTAssertTrue(prepared.payload.contains("🙂")); XCTAssertEqual(prepared.receipt["utf8Bytes"].number, 4)
        XCTAssertEqual(prepared.receipt["lineStart"].number, 2); XCTAssertEqual(prepared.receipt["lineEnd"].number, 2)
        XCTAssertEqual(prepared.receipt["contentSHA256"].string?.count, 64)
        let model = NativeHootChatModel(fixture: .object([]))
        XCTAssertTrue(try model.editorContextTool("read", request: nil, mode: nil, revision: nil, store: store)["receipt"].isNullish)
        model.composerDraft.text = "Keep draft"
        model.composerDraft.add([URL(fileURLWithPath: "/scratch/reference.txt")]); let files = model.composerDraft.attachments
        _ = try model.editorContextTool("insert", request: snapshot.id, mode: "selection", revision: snapshot.revision, store: store)
        XCTAssertTrue(model.composerDraft.text.hasPrefix("Keep draft\n\n")); XCTAssertEqual(model.composerDraft.attachments, files)
        XCTAssertEqual(model.chatEditorContextReceipt["deliveryConfirmed"].bool, false)
        store.update(id: "buffer", path: snapshot.path, text: "changed", selection: NSRange(location: 0, length: 1), truncated: true)
        XCTAssertThrowsError(try store.checked(snapshot.id, revision: snapshot.revision))
        XCTAssertEqual(try store.snapshots[0].context("file").receipt["scope"].string, "Displayed file excerpt")
        store.remove(snapshot.id); XCTAssertTrue(store.snapshots.isEmpty)
    }
}
