import AppKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Send now never loses or doubles a message. Background controls belong to the Running tray.
@MainActor final class ChatSendNowUITests: XCTestCase {
    private func snapshot(_ events: [HootChatEvent] = [], busy: Bool = false) -> NativeRPCValue {
        .object([.init("conversationId", .string("c")), .init("sequence", .number(Double(events.last?.sequence ?? 0))),
            .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true)), .init("busy", .bool(busy))])
    }
    private func receipt(_ id: String, sequence: Int = 2) -> HootChatEvent {
        .init(conversationID: "c", turnID: "t", sequence: sequence, provider: .claude,
            record: .init(.session, value: .object([.init("clientMessageId", .string(id)), .init("deliveryConfirmed", .bool(true))])))
    }
    private func queued(_ invoke: @escaping NativeHOOTSIMFeedback.Invoke) async throws -> NativeHootChatModel {
        let model = NativeHootChatModel(fixture: snapshot(busy: true), chatInvoke: invoke, source: .session("s", provider: "claude"))
        _ = try await model.queueTool("queue", id: nil, text: "same words", context: .object([]))
        return model
    }
    private func timeout() -> NativeRPCError { .init(code: "x", message: "The private session host connection failed (POSIX status 60).") }

    func testDelayedOriginalSendAfterNegativeReadNeverSendsTwiceAndLaterReceiptClearsIt() async throws {
        var calls = 0, sentID = ""
        let model = try await queued { channel, args in
            if channel.hasSuffix(":steer") { calls += 1; sentID = args.last as? String ?? ""; throw self.timeout() }
            if channel.hasSuffix(":say") { calls += 1 }
            return self.snapshot().foundation!
        }
        let id = try XCTUnwrap(model.queuedMessages.first?.id)
        do { try await model.steerQueued(id); XCTFail("Reply was lost") } catch {}
        XCTAssertEqual(sentID, id)
        XCTAssertTrue(try XCTUnwrap(model.queuedMessages.first).held)
        model.acceptFixtureUpdate(snapshot())
        await Task.yield()
        XCTAssertEqual(calls, 1, "a negative read and idle event cannot resend an in-flight operation")
        model.acceptFixtureUpdate(snapshot([receipt(id)]))
        XCTAssertTrue(model.queuedMessages.isEmpty, "the delayed original operation finally confirms its own ID")
    }

    func testFailedReconciliationReadKeepsHeldTextAndAttachments() async throws {
        let model = try await queued { _, _ in throw self.timeout() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // An actual image block travels with this queued capture.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let path = root.appendingPathComponent("picture.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        let id = try await model.queueCapture(text: "with picture", paths: [path.path], source: .object([]))
        do { try await model.steerQueued(id); XCTFail("Reply was lost") } catch {}
        let kept = try XCTUnwrap(model.queuedMessages.first { $0.id == id })
        XCTAssertTrue(kept.held)
        XCTAssertEqual(kept.draft.text, "with picture")
        XCTAssertEqual(kept.draft.attachments.map(\.url), [path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testAnotherSendersIdenticalTextAndJournalWithoutDeliveryDoNotRemoveTheQueue() async throws {
        let journal = HootChatEvent(conversationID: "c", turnID: "t", sequence: 1, provider: .claude,
            record: .init(.user, value: .object([.init("text", .string("same words"))])))
        let model = try await queued { channel, _ in
            if channel.hasSuffix(":steer") { throw self.timeout() }
            return self.snapshot([journal, self.receipt("another-sender")]).foundation!
        }
        let id = try XCTUnwrap(model.queuedMessages.first?.id)
        do { try await model.steerQueued(id); XCTFail("Reply was lost") } catch {}
        XCTAssertEqual(model.queuedMessages.first?.id, id)
        XCTAssertEqual(model.queuedMessages.first?.held, true)
        XCTAssertFalse(NativeHootChatModel.arrived(id, in: [journal, receipt("another-sender")]))
    }

    func testOldKeeperReplyWithoutEchoStaysHeldAndVisible() async throws {
        var sends = 0
        let model = try await queued { channel, _ in
            if channel.hasSuffix(":steer") || channel.hasSuffix(":say") { sends += 1 }
            return self.snapshot().foundation!
        }
        let id = try XCTUnwrap(model.queuedMessages.first?.id)
        do { try await model.steerQueued(id); XCTFail("Old keeper cannot prove the delivery ID") } catch {}
        model.acceptFixtureUpdate(snapshot())
        await Task.yield()
        XCTAssertEqual(sends, 1)
        let kept = try XCTUnwrap(model.queuedMessages.first)
        XCTAssertTrue(kept.held)
        XCTAssertTrue(kept.problem?.contains("Not sent.") == true)
        XCTAssertTrue(kept.problem?.contains("back in the box") == true)
        let listed = try await model.queueTool("list", id: nil, text: nil, context: .object([]))
        XCTAssertEqual(listed.elements?.first?["id"].string, id, "the existing MCP queue sees the held message too")
    }

    func testNewKeeperReplyEchoRemovesOnlyItsMessage() async throws {
        let model = try await queued { _, args in
            let id = args.last as? String ?? ""
            return self.snapshot([self.receipt(id)], busy: true).foundation!
        }
        let id = try XCTUnwrap(model.queuedMessages.first?.id)
        _ = try await model.queueTool("queue", id: nil, text: "same words", context: .object([]))
        try await model.steerQueued(id)
        XCTAssertEqual(model.queuedMessages.count, 1)
        XCTAssertNotEqual(model.queuedMessages.first?.id, id)
    }

    func testLateReceiptForTheOldContentCannotDiscardAnEditedHeldMessage() async throws {
        let model = try await queued { _, _ in throw self.timeout() }
        let oldID = try XCTUnwrap(model.queuedMessages.first?.id)
        do { try await model.steerQueued(oldID) } catch {}
        model.editQueued(oldID, editing: true)
        model.setQueuedText(oldID, text: "changed message")
        model.acceptFixtureUpdate(snapshot([receipt(oldID)], busy: true))
        XCTAssertEqual(model.queuedMessages.first?.draft.text, "changed message", "a late receipt must preserve the edit in progress")
        model.editQueued(oldID, editing: false)
        let newID = try XCTUnwrap(model.queuedMessages.first?.id)
        XCTAssertNotEqual(newID, oldID)
        model.acceptFixtureUpdate(snapshot([receipt(oldID)], busy: true))
        XCTAssertEqual(model.queuedMessages.first?.id, newID)
        XCTAssertEqual(model.queuedMessages.first?.draft.text, "changed message")
    }

    func testUnchangedEditAndExplicitRetryCannotReleaseAnUnknownOperation() async throws {
        var sends = 0
        let model = try await queued { channel, _ in
            if channel.hasSuffix(":steer") || channel.hasSuffix(":say") { sends += 1; throw self.timeout() }
            return self.snapshot().foundation!
        }
        let id = try XCTUnwrap(model.queuedMessages.first?.id)
        do { try await model.steerQueued(id) } catch {}
        _ = try await model.queueTool("edit", id: id, text: "same words", context: .object([]))
        XCTAssertEqual(model.queuedMessages.first?.id, id, "an unchanged MCP edit must keep the pending operation")
        model.editQueued(id, editing: true)
        model.editQueued(id, editing: false)
        model.acceptFixtureUpdate(snapshot())
        do { try await model.steerQueued(id) } catch {}
        await Task.yield()
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(model.queuedMessages.first?.id, id)
        XCTAssertEqual(model.queuedMessages.first?.held, true)
        XCTAssertEqual(model.queuedMessages.first?.deliveryPending, true)
        XCTAssertTrue(model.queuedMessages.first?.problem?.contains("Not sent.") == true)
        // The outbox carries the pending operation across restart; old saved entries still decode.
        let entry = NativeChatOutbox.Entry(id: id, draft: try XCTUnwrap(model.queuedMessages.first?.draft), context: nil,
            held: true, problem: nil, deliveryPending: true)
        let restored = try JSONDecoder().decode(NativeChatOutbox.Entry.self, from: JSONEncoder().encode(entry))
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.deliveryPending, true)
        var legacy = try NativeRPCValue.parseJSON(JSONEncoder().encode(entry))
        legacy = .object((legacy.fields ?? []).filter { $0.key != "deliveryPending" })
        XCTAssertNil(try JSONDecoder().decode(NativeChatOutbox.Entry.self, from: legacy.encodedJSON()).deliveryPending)
    }

    func testRestartDuringAnUnknownSendEditKeepsTheChangedDraft() throws {
        let id = "old-operation"
        let saved = NativeChatOutbox.Entry(id: id, draft: .init(text: "edited text"), context: nil,
            held: true, problem: "Editing was interrupted. Review before sending after restart.",
            deliveryPending: true, editedPendingDelivery: true)
        let decoded = try JSONDecoder().decode(NativeChatOutbox.Entry.self, from: JSONEncoder().encode(saved))
        let restored = NativeHootChatModel.restoreQueuedMessage(decoded)
        XCTAssertNotEqual(restored.id, id)
        XCTAssertEqual(restored.draft.text, "edited text")
        XCTAssertTrue(restored.held)
        XCTAssertFalse(restored.deliveryPending, "the changed draft has never been attempted")
        XCTAssertFalse(NativeHootChatModel.arrived(restored.id, in: [receipt(id)]))
        var legacy = saved
        legacy.editedPendingDelivery = nil
        let unknown = NativeHootChatModel.restoreQueuedMessage(legacy)
        XCTAssertEqual(unknown.id, id)
        XCTAssertTrue(unknown.held && unknown.deliveryPending)
        XCTAssertTrue(unknown.problem?.contains("Not sent.") == true)
    }

    func testReceiptDuringEnsurePreventsAnotherSay() async throws {
        var queuedID = "", sends = 0
        let model = try await queued { channel, _ in
            if channel.hasSuffix(":say") { sends += 1 }
            return self.snapshot([self.receipt(queuedID)]).foundation!
        }
        queuedID = try XCTUnwrap(model.queuedMessages.first?.id)
        model.acceptFixtureUpdate(snapshot())
        for _ in 0..<100 { if !model.sending { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(model.queuedMessages.isEmpty)
    }

    func testQueuedSayCarriesItsIDWithNewAndOldKeepers() async throws {
        for echoes in [true, false] {
            var sends = 0, sentID = ""
            let model = try await queued { channel, args in
                if channel.hasSuffix(":say") { sends += 1; sentID = args.last as? String ?? "" }
                return self.snapshot(echoes && !sentID.isEmpty ? [self.receipt(sentID)] : []).foundation!
            }
            let id = try XCTUnwrap(model.queuedMessages.first?.id)
            model.acceptFixtureUpdate(snapshot())
            for _ in 0..<100 { if sends > 0 && !model.sending { break }; try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(sentID, id)
            XCTAssertEqual(sends, 1)
            XCTAssertEqual(model.queuedMessages.isEmpty, echoes)
            if !echoes { XCTAssertEqual(model.queuedMessages.first?.held, true) }
        }
    }

    /// Running controls have one owner; queueing keeps the message separate from task state.
    func testRunningTrayKeepsIndependentTasksAndQueuedDrafts() async throws {
        let task = NativeRPCValue.object([.init("id", .string("one")), .init("status", .string("running")),
            .init("canStop", .bool(true)), .init("kind", .string("agent"))])
        let value = snapshot(busy: true).setting("children", .array([task]))
        let model = NativeHootChatModel(fixture: value, chatInvoke: { _, _ in value.foundation! }, source: .session("scratch-running-tray", provider: "codex"))
        model.composerDraft.text = "After this answer"
        model.send()
        XCTAssertEqual(model.queuedMessages.last?.draft.text, "After this answer")
        XCTAssertTrue(model.composerDraft.text.isEmpty)
        let tray = try await model.featureTool("running", action: "open", args: .object([]))
        XCTAssertEqual(tray["count"].number, 1)
        XCTAssertEqual(tray["items"].elements?.first?["id"].string, "one")
        XCTAssertTrue(tray["expanded"].bool == true)
        let details = try await model.agentTreeTool("read", request: nil)
        XCTAssertFalse((details["rows"].elements ?? []).flatMap { $0["actions"].elements ?? [] }.contains { $0["do"].string == "stop" })
        let closed = try await model.featureTool("running", action: "close", args: .object([]))
        XCTAssertEqual(closed["count"].number, 1, "Closing the tray does not stop a task")
        XCTAssertEqual(closed["expanded"].bool, false)
    }

}

/// The chat as Asad sees it while a background task runs and a message waits: both in the conversation.
extension HOOTSIMRenderingTests {
    func testSendNowInlineFrames() async throws {
        guard ProcessInfo.processInfo.environment["HOOTSIM_OFFSCREEN_XCTEST"] == "1" else { throw XCTSkip("Offscreen renders run only on request.") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["HOOTSIM_RENDER_OUTPUT"])
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let events = [
            HootChatEvent(conversationID: "send-now", turnID: "t1", sequence: 1, provider: .claude, record: .text(.user, "Fix the three posters and check the form.")),
            HootChatEvent(conversationID: "send-now", turnID: "t1", sequence: 2, provider: .claude, record: .text(.message, "The form: one question (my pick) or three, and whether to add a consent tick box. Lunaya's form had none.")),
            HootChatEvent(conversationID: "send-now", turnID: "t1", sequence: 3, provider: .claude, record: .init(.completed, value: .object([])))].map(\.wireValue)
        let running = NativeRPCValue.object([.init("id", .string("bg-1")), .init("title", .string("Running cd /tmp/ps && python3 - <<'E' from PIL import Image…")),
            .init("kind", .string("local_bash")), .init("status", .string("running")), .init("canStop", .bool(true))])
        let chat = NativeRPCValue.object([.init("conversationId", .string("send-now")), .init("sequence", .number(3)), .init("events", .array(events)),
            .init("alive", .bool(true)), .init("busy", .bool(true)), .init("children", .array([running])),
            .init("options", .object([.init("ready", .bool(true)), .init("permissionMode", .string("bypass")), .init("model", .string("claude:opus[1m]"))]))])
        for dark in [false, true] {
            let model = NativeHootChatModel(fixture: chat, source: .session("fixture-session", provider: "claude"))
            _ = try? await model.queueTool("queue", id: nil, text: "lets prepare your access first since you can not do some stuff maybe through mcp and system account", context: .object([]))
            try Self.render(NativeHootChat(model: model), size: CGSize(width: 900, height: 620), dark: dark,
                to: output.appendingPathComponent("send-now-inline-\(dark ? "dark" : "light").png"))
        }
    }
}
