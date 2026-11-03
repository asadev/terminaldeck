import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatLongDraftTests: XCTestCase {
    func testExternalRoundTripPreservesAttachmentsAndRefusesStaleDraftAndSymlink() throws {
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string("one"))]))
        model.composerDraft.text = String(repeating: "large prompt\n", count: 500); model.composerDraft.add([URL(fileURLWithPath: "/scratch/ref.txt")])
        _ = try model.longDraftTool("export", text: nil)
        let file = try XCTUnwrap(model.chatDraftEditor.file)
        defer { model.chatDraftEditor.clear() }
        try Data("Edited elsewhere".utf8).write(to: file)
        model.composerDraft.text += "Changed in Chat"
        XCTAssertThrowsError(try model.longDraftTool("import", text: nil))
        XCTAssertTrue(model.composerDraft.text.hasSuffix("Changed in Chat"))
        model.composerDraft = try XCTUnwrap(model.chatDraftEditor.baseline)
        _ = try model.longDraftTool("import", text: nil)
        XCTAssertEqual(model.composerDraft.text, "Edited elsewhere"); XCTAssertEqual(model.composerDraft.attachments.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        _ = try model.longDraftTool("export", text: nil)
        let second = try XCTUnwrap(model.chatDraftEditor.file)
        try FileManager.default.removeItem(at: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: URL(fileURLWithPath: "/dev/null"))
        XCTAssertThrowsError(try model.chatDraftEditor.readExternal())
        model.chatDraftEditor.text = String(repeating: "é", count: 131073)
        XCTAssertThrowsError(try model.chatDraftEditor.checkedText())
    }
}
