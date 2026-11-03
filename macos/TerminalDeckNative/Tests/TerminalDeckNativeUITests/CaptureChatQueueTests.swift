import AppKit
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@MainActor final class CaptureChatQueueTests: XCTestCase {
    private func model() -> NativeHootChatModel {
        NativeHootChatModel(fixture: .object([.init("conversationId", .string("capture-test")), .init("provider", .string("codex")),
            .init("model", .string("test")), .init("sequence", .number(0)), .init("events", .array([])),
            .init("alive", .bool(true)), .init("busy", .bool(true))]), source: .session(UUID().uuidString, provider: "codex"))
    }
    func testBusyCaptureKeepsImageAndNoteWithoutChangingDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-queue-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let path = root.appendingPathComponent("marked.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        let chat = model(); chat.composerDraft.text = "keep my draft"
        _ = try await chat.queueCapture(text: "marked note", paths: [path.path], source: .object([.init("kind", .string("browser"))]))
        XCTAssertEqual(chat.composerDraft.text, "keep my draft")
        XCTAssertEqual(chat.queuedMessageCount, 1)
        XCTAssertEqual(chat.queuedMessages.first?.draft.text, "marked note")
        XCTAssertEqual(chat.queuedMessages.first?.draft.attachments.map(\.url), [path])
        XCTAssertEqual(chat.queuedMessages.first?.context?["source"]["kind"].string, "browser")
        let context = try XCTUnwrap(chat.queuedMessages.first?.context)
        XCTAssertNoThrow(try BackendHOOTSIMChatContext(wire: context))
        XCTAssertEqual(context["source"]["title"].string, DeckOwner.messageTitle)
    }
    func testCaptureSourceUsesExistingHostSchema() throws {
        let source = try NativeCapturedFeedback.chatSource(.object([
            .init("kind", .string("browser")), .init("title", .string("Paperclip")),
            .init("senderName", .string("check agent")), .init("window", .string("check window")),
            .init("path", .string("/Pictures/Terminal Deck/marked.png"))]))
        XCTAssertNoThrow(try BackendHOOTSIMChatContext(wire: .object([.init("source", source)])))
        XCTAssertEqual(source["title"].string, "Message from check agent - Paperclip")
        XCTAssertTrue(source["senderName"].isNullish)
        XCTAssertEqual(source["path"].string, "/Pictures/Terminal Deck/marked.png")
    }
    func testStoredLegacyCaptureIsNormalizedOnlyAtDelivery() throws {
        let context = NativeRPCValue.object([.init("source", .object([
            .init("kind", .string("browser")), .init("senderName", .string("Asad Iqbal"))]))])
        let delivered = try XCTUnwrap(NativeCapturedFeedback.deliveryContext(context))
        XCTAssertNoThrow(try BackendHOOTSIMChatContext(wire: delivered))
        XCTAssertEqual(context["source"]["senderName"].string, "Asad Iqbal")
        XCTAssertTrue(delivered["source"]["senderName"].isNullish)
    }
    func testStatusBandClipsMessagesButKeepsComposerGlass() {
        let clip = NativeChatMessageClip(bottomHeight: 200, statusHeight: 72)
            .path(in: CGRect(x: 0, y: 0, width: 760, height: 600))
        XCTAssertTrue(clip.contains(CGPoint(x: 380, y: 390)))
        XCTAssertFalse(clip.contains(CGPoint(x: 380, y: 440)))
        XCTAssertTrue(clip.contains(CGPoint(x: 380, y: 520)))
    }
    func testChangedAttachmentScopeRefusesBeforeQueueing() async throws {
        let chat = model()
        do {
            _ = try await chat.queueCapture(text: "note", paths: [], source: .object([]), validate: {
                throw NativeRPCError.invalidArguments("attachment changed")
            })
            XCTFail("Changed capture scope must refuse")
        } catch { XCTAssertTrue(error.localizedDescription.contains("attachment changed")) }
        XCTAssertEqual(chat.queuedMessageCount, 0)
    }
    func testCodexUnsupportedDocumentsNeverEnterCaptureQueue() async {
        let chat = model()
        do {
            _ = try await chat.queueCapture(text: "note", paths: ["/scratch/marked.pdf"], source: .object([]))
            XCTFail("Codex must reject document attachments")
        } catch { XCTAssertEqual(chat.queuedMessageCount, 0) }
    }
    func testCapturePickersPreserveChatTargetsAndOrder() {
        let rows: [[String: Any]] = [["id": "chat", "cwd": "/work", "provider": "codex", "chat": true, "exitCode": NSNull()],
                                   ["id": "terminal", "cwd": "/work", "provider": "claude", "exitCode": NSNull()]]
        let targets = AgentSessions.read(rows)
        XCTAssertEqual(targets.map(\.id), ["chat", "terminal"])
        XCTAssertEqual(targets.map(\.isChat), [true, false])
        let browser = BrowserSessionChoice.read(rows)
        XCTAssertEqual(browser.map(\.id), targets.map(\.id))
        XCTAssertEqual(browser.map(\.isChat), [true, false])
    }
}
