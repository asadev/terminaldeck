import AppKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Actual native model/image/gesture paths with scoped callbacks. No application,
/// window, menu, bridge configuration, device boot, audio, AI or installed data.
@MainActor final class HOOTSIMNativeFlowTests: XCTestCase {
    func testFiveImageChecks() throws { XCTAssertEqual(try HOOTSIMFeedbackChecks.run(), 5) }
    func testSixScreenRPCContracts() async throws {
        let count = try await HOOTSIMFeedbackChecks.runRPCChecks(); XCTAssertEqual(count, 6)
    }
    func testDisconnectedDefaultBridgeRefusesBeforeCapture() async throws {
        let count = try await HOOTSIMFeedbackChecks.runNilBridgeCheck(); XCTAssertEqual(count, 1)
    }

    func testPhoneScreenshotDeliversOriginalPictureAndStructuredSource() async throws {
        let fixture = try Fixture(kind: "screenshot")
        defer { fixture.remove() }
        await fixture.model.screenshot()
        fixture.model.shot?.instruction = "The sign-in button does nothing"
        await fixture.model.sendShot()
        XCTAssertEqual(fixture.delivery.messages.count, 1)
        XCTAssertNil(fixture.model.shot)
        XCTAssertEqual(fixture.delivery.sources[0]["deviceId"].string, "ios:HOOTSIM-STUB")
        XCTAssertEqual(fixture.delivery.sources[0]["sessionId"].string, "HOOTSIM-source-session")
        XCTAssertEqual(fixture.delivery.sources[0]["folder"].string, fixture.folder.path)
        XCTAssertEqual(fixture.delivery.sources[0]["path"].string, fixture.picture.path)
        XCTAssertEqual(fixture.delivery.revisions[0], fixture.model.attachmentRevision)
        XCTAssertTrue(fixture.delivery.messages[0].contains("sign-in button"))
        XCTAssertEqual(try bytes(fixture.delivery.blocks[0][0]), fixture.png)
        XCTAssertEqual(try Data(contentsOf: fixture.picture), fixture.png)
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testPhoneSnipGestureCropsOnlyPictureAndUsesSameHootSender() async throws {
        let fixture = try Fixture(kind: "snip")
        defer { fixture.remove() }
        let tools = NativeSimPanelTools.attach(to: fixture.model, widen: { _ in })
        tools.toggleSnip()
        XCTAssertTrue(tools.snipping)
        tools.snipped(CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        for _ in 0..<100 where tools.snipWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(tools.snipWorking)
        let cut = try XCTUnwrap(fixture.model.shot)
        let originalImage = try XCTUnwrap(fixture.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cut.shot.width, originalImage.width / 2)
        XCTAssertEqual(cut.shot.height, originalImage.height / 2)
        XCTAssertNotEqual(cut.shot.path, fixture.picture.path)
        fixture.model.shot?.instruction = "Fix the marked button"
        await fixture.model.sendShot()
        XCTAssertEqual(fixture.delivery.messages.count, 1)
        XCTAssertEqual(fixture.delivery.sources[0]["path"].string, cut.shot.path)
        XCTAssertEqual(try Data(contentsOf: fixture.picture), fixture.png)
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testPhoneAnnotateDrawsMarkersAndKeepsNoteUntilConfirmedDelivery() async throws {
        let fixture = try Fixture(kind: "annotate")
        defer { fixture.remove() }
        XCTAssertEqual(fixture.model.markers.count, 1)
        let note = fixture.model.note
        await fixture.model.sendRound()
        XCTAssertEqual(fixture.delivery.messages.count, 1)
        XCTAssertTrue(fixture.delivery.messages[0].contains(note))
        XCTAssertTrue(fixture.delivery.messages[0].contains("#1"))
        XCTAssertTrue(fixture.model.markers.isEmpty)
        XCTAssertEqual(fixture.model.note, "")
        let delivered = try bytes(fixture.delivery.blocks[0][0])
        XCTAssertNotEqual(delivered, fixture.png, "The actual marker renderer burns the marker into the picture")
        XCTAssertEqual(fixture.delivery.sources[0]["path"].string, fixture.marked.path)
        XCTAssertEqual(try Data(contentsOf: fixture.picture), fixture.png)
    }

    func testPhoneLateValidationRefusalRetainsMarkersAndNoteWithoutChatFallback() async throws {
        let fixture = try Fixture(kind: "annotate")
        defer { fixture.remove() }
        fixture.delivery.refused = true
        let original = fixture.model.markers
        let note = fixture.model.note
        await fixture.model.sendRound()
        XCTAssertEqual(fixture.model.markers, original)
        XCTAssertEqual(fixture.model.note, note)
        XCTAssertFalse(fixture.model.sendProblem.isEmpty)
        XCTAssertEqual(fixture.delivery.attempts, 1)
        XCTAssertTrue(fixture.delivery.messages.isEmpty)
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testPhonePlainRecordSendsHonestPosterAndKeepsClipOnRefusal() async throws {
        let fixture = try Fixture(kind: "screenshot")
        defer { fixture.remove() }
        let poster = try XCTUnwrap(fixture.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let path = fixture.folder.appendingPathComponent("kept-video.mp4").path
        let info = NativeSimRecordingMedia.Info(width: 240, height: 480, seconds: 3, hasAudio: false)
        let clip = NativeSimRecorder.Clip(path: path, info: info, original: path, originalInfo: info,
            poster: poster, narration: nil, narrated: nil, instruction: "The button never opens")
        let recorder = NativeSimRecorder.fixture(model: fixture.model, clip: clip, settings: fixture.settings)
        fixture.delivery.refused = true
        await recorder.send()
        XCTAssertEqual(recorder.clip?.instruction, clip.instruction)
        XCTAssertEqual(recorder.clip?.path, path)
        XCTAssertFalse(recorder.clip?.problem.isEmpty ?? true)
        fixture.delivery.refused = false
        await recorder.send()
        XCTAssertNil(recorder.clip)
        XCTAssertTrue(fixture.delivery.messages[0].contains("video preview"))
        XCTAssertTrue(fixture.delivery.messages[0].contains(path))
        XCTAssertEqual(fixture.delivery.sources[0]["path"].string, path)
        XCTAssertEqual(fixture.delivery.blocks[0].count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "This test never creates or launches a video recorder")
    }

    func testNarratedRecordKeepsEditedWordsScreenTimesAndOriginalVideoReference() async throws {
        let fixture = try Fixture(kind: "screenshot")
        defer { fixture.remove() }
        var timeline = NarrationTimeline()
        timeline.begin(name: "Sign in", keyframe: fixture.picture.path)
        timeline.heard(final: NarrationWord.spread("Original words", from: 0, to: 1))
        timeline.finish(at: 3)
        timeline.edit(1, text: "The sign-in button does nothing")
        let narration = NativeNarration(fixture: timeline)
        let path = fixture.folder.appendingPathComponent("walkthrough.mp4").path
        let info = NativeSimRecordingMedia.Info(width: 240, height: 480, seconds: 3, hasAudio: true)
        let clip = NativeSimRecorder.Clip(path: path, info: info, original: path, originalInfo: info,
            poster: fixture.image.cgImage(forProposedRect: nil, context: nil, hints: nil), narration: nil, narrated: narration)
        let recorder = NativeSimRecorder.fixture(model: fixture.model, clip: clip, settings: fixture.settings)
        await recorder.send()
        XCTAssertEqual(fixture.delivery.messages.count, 1)
        XCTAssertTrue(fixture.delivery.messages[0].contains("The sign-in button does nothing"))
        XCTAssertFalse(fixture.delivery.messages[0].contains("Original words"))
        XCTAssertTrue(fixture.delivery.messages[0].contains("0:00–0:03"))
        XCTAssertTrue(fixture.delivery.messages[0].contains(fixture.picture.path))
        XCTAssertTrue(fixture.delivery.messages[0].contains(path))
        XCTAssertEqual(fixture.delivery.blocks[0].count, 1)
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testBrowserScreenshotAnnotateAndSnipDeliverActualPixelsAndSource() async throws {
        let fixture = try Fixture(kind: "screenshot")
        defer { fixture.remove() }
        let base = try XCTUnwrap(fixture.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let mark = BrowserAnnotation(n: 1, rect: CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.2),
            element: BrowserAnnotatedElement(role: "button", name: "Sign in"))
        let marked = try XCTUnwrap(NativeBrowserRender.annotated(base, [mark]))
        let snip = try XCTUnwrap(NativeShotCrop.cropped(base, to: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
        for (kind, image) in [("Screenshot", base), ("Annotate", marked), ("Snip", snip)] {
            let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            var submitted: [Any?] = []
            let source = NativeRPCValue.object([.init("kind", .string("browser")), .init("title", .string(kind)),
                .init("url", .string("https://portal.example.test/sign-in")), .init("folder", .string(fixture.folder.path)),
                .init("sessionId", .string("HOOTSIM-source-session")), .init("path", .string(fixture.picture.path)),
                .init("noteCount", .number(1))])
            let blocks = try NativeHOOTSIMFeedback.attachments(images: [png])
            try await NativeHOOTSIMFeedback.send("The sign-in button does nothing", attachments: blocks, source: source,
                invoke: { channel, arguments in
                    XCTAssertEqual(channel, "hoot:chat:say")
                    submitted = arguments; return ["ok": true]
                })
            XCTAssertEqual(submitted[0] as? String, "The sign-in button does nothing")
            let context = try NativeRPCValue.fromFoundation(submitted[2] ?? NSNull())
            XCTAssertEqual(context["source"], try NativeRPCValue.fromFoundation(source.foundation ?? NSNull()))
            let sent = try NativeRPCValue.fromFoundation(submitted[1] ?? NSNull()).requireArray("images")
            XCTAssertEqual(try bytes(sent[0]), png)
        }
        XCTAssertNotEqual(try XCTUnwrap(NSBitmapImageRep(cgImage: marked).representation(using: .png, properties: [:])), fixture.png)
        XCTAssertEqual(snip.width, base.width / 2); XCTAssertEqual(snip.height, base.height / 2)
        XCTAssertEqual(try Data(contentsOf: fixture.picture), fixture.png)
    }

    func testRoutingRevisionStaysAtFirstProposalBeforeLaterReply() throws {
        let conversation = "HOOTSIM-routing-position"
        let routeID = UUID().uuidString
        let initial = NativeRPCValue.object([.init("id", .string(routeID)), .init("status", .string("pending")),
            .init("revision", .string(UUID().uuidString)), .init("target", .object([.init("name", .string("Display target"))]))])
        let settled = initial.setting("status", .string("sent")).setting("revision", .string(UUID().uuidString))
        let events = [
            HootChatEvent(conversationID: conversation, turnID: "first", sequence: 1, provider: .claude,
                record: .text(.message, id: "reply-before", "A display proposal follows.")),
            HootChatEvent(conversationID: conversation, turnID: "first", sequence: 2, provider: .claude,
                record: .init(.message, id: "routing:" + routeID, value: .object([.init("routing", initial)]))),
            HootChatEvent(conversationID: conversation, turnID: "second", sequence: 3, provider: .claude,
                record: .text(.message, id: "reply-after", "A later reply.")),
            HootChatEvent(conversationID: conversation, turnID: "second", sequence: 4, provider: .claude,
                record: .init(.message, id: "routing:" + routeID, value: .object([.init("routing", settled)]))),
        ]
        let model = NativeHootChatModel(fixture: .object([.init("conversationId", .string(conversation)),
            .init("sequence", .number(4)), .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true))]))
        let rows = model.displayRows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].value["text"].string, "A display proposal follows.")
        XCTAssertEqual(rows[1].value["routing"]["status"].string, "sent")
        XCTAssertEqual(rows[2].value["text"].string, "A later reply.")
        XCTAssertEqual(model.currentRoutes.count, 1)
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testOnlyReceiptBoundMemoryPreviewDisplaysAndNewChatClearsIt() throws {
        let fixture = try Fixture(kind: "screenshot")
        defer { fixture.remove() }
        let conversation = "HOOTSIM-preview-" + UUID().uuidString
        let message = "Display picture only"
        let source = NativeRPCValue.object([.init("kind", .string("browser")),
            .init("path", .string("/unapproved/private/source.png")), .init("title", .string("Fixture picture"))])
        let user = HootChatEvent(conversationID: conversation, turnID: "preview-turn", sequence: 1, provider: .claude,
            record: .init(.user, id: "preview-user", value: .object([.init("text", .string(message)),
                .init("attachmentCount", .number(1)), .init("context", .object([.init("source", source)]))])))
        let snapshot = NativeRPCValue.object([.init("conversationId", .string(conversation)), .init("sequence", .number(1)),
            .init("events", .array([user.wireValue])), .init("alive", .bool(true))])
        let row = try XCTUnwrap(HootChatProjection.rows([user]).first)
        let model = NativeHootChatModel(fixture: snapshot)
        XCTAssertNil(model.attachmentPreview(for: row), "An arbitrary source path never authorizes a file read")
        NativeHOOTSIMFeedback.retainPreviews(conversation: conversation, rowIDs: [])
        let blocks = try NativeHOOTSIMFeedback.attachments(images: [fixture.png])
        NativeHOOTSIMFeedback.rememberPreview(receipt: snapshot.foundation ?? [:], message: message, attachments: blocks, source: source)
        XCTAssertNotNil(NativeHOOTSIMFeedback.preview(conversation: conversation, rowID: row.id))
        XCTAssertNil(NativeHOOTSIMFeedback.preview(conversation: conversation, rowID: "different-user"))
        NativeHOOTSIMFeedback.retainPreviews(conversation: "new-chat", rowIDs: [])
        XCTAssertNil(NativeHOOTSIMFeedback.preview(conversation: conversation, rowID: row.id))
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testFailedChatOptionWriteAndFailedReadRestoreLastConfirmedChoices() async throws {
        let options = NativeRPCValue.object([.init("ready", .bool(true)), .init("permissionMode", .string("ask")),
            .init("model", .string("claude:confirmed")), .init("models", .array([.object([
                .init("id", .string("claude:confirmed")), .init("provider", .string("Claude Code")), .init("name", .string("Sample offered model"))])]))])
        let fixture = NativeRPCValue.object([.init("conversationId", .string("HOOTSIM-options-failure")),
            .init("sequence", .number(0)), .init("events", .array([])), .init("alive", .bool(true)), .init("options", options)])
        var calls: [String] = []
        let model = NativeHootChatModel(fixture: fixture, optionsInvoke: { channel, arguments in
            calls.append(arguments.isEmpty ? "read" : "write")
            XCTAssertEqual(channel, "hoot:chat:options")
            throw NativeRPCError(code: "unavailable", message: "Stub write/read failed")
        })
        // The real shared composer mutates its binding before invoking the host.
        model.composerDraft.permissionMode = .changes
        model.changePermission(.changes)
        for _ in 0..<100 where model.changingOptions { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.composerDraft.permissionMode, .ask)
        XCTAssertEqual(model.composerDraft.modelID, "claude:confirmed")
        model.composerDraft.modelID = "claude:unconfirmed"
        model.changeModel("claude:unconfirmed")
        for _ in 0..<100 where model.changingOptions { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.composerDraft.permissionMode, .ask)
        XCTAssertEqual(model.composerDraft.modelID, "claude:confirmed")
        XCTAssertEqual(calls, ["write", "read", "write", "read"])
        XCTAssertNotNil(model.problem)
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testStoppedOrLaterTurnNeverShowsAnOldUnfinishedToolAsActive() throws {
        let conversation = "HOOTSIM-real-status"
        let events = [
            HootChatEvent(conversationID: conversation, turnID: "old-turn", sequence: 1, provider: .claude,
                record: .init(.toolCall, id: "old-tool", value: .object([.init("name", .string("old_tool"))]))),
            HootChatEvent(conversationID: conversation, turnID: "new-turn", sequence: 2, provider: .claude,
                record: .text(.user, id: "new-user", "A new message")),
        ]
        let stopped = NativeHootChatModel(fixture: .object([.init("conversationId", .string(conversation)),
            .init("sequence", .number(2)), .init("events", .array(events.map(\.wireValue))),
            .init("alive", .bool(false)), .init("busy", .bool(false))]))
        XCTAssertNil(stopped.toolStep)
        // R10: an idle, ready Hoot must not claim it is still waking.
        XCTAssertEqual(stopped.status, "Ready")
        XCTAssertEqual(stopped.avatarState, .awake)
        let thinking = NativeHootChatModel(fixture: .object([.init("conversationId", .string(conversation)),
            .init("sequence", .number(2)), .init("events", .array(events.map(\.wireValue))),
            .init("alive", .bool(true)), .init("busy", .bool(true))]))
        XCTAssertNil(thinking.toolStep)
        XCTAssertEqual(thinking.status, "Thinking…") // R11: Reading is reserved for an observed read.
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    private func bytes(_ block: NativeRPCValue) throws -> Data {
        try XCTUnwrap(Data(base64Encoded: block["source"]["data"].string ?? ""))
    }

    @MainActor private final class Delivery {
        var refused = false
        var attempts = 0
        var messages: [String] = []
        var blocks: [[NativeRPCValue]] = []
        var sources: [NativeRPCValue] = []
        var revisions: [String?] = []
        func send(_ text: String, _ images: [NativeRPCValue], _ source: NativeRPCValue, _ revision: String?) async throws {
            attempts += 1
            if refused { throw NativeRPCError(code: "stale-attachment", message: "The source changed while Hoot started.") }
            messages.append(text); blocks.append(images); sources.append(source); revisions.append(revision)
        }
    }

    @MainActor private final class Fixture {
        let folder: URL, picture: URL, marked: URL
        let image: NSImage, png: Data
        let settings: NativeNarrationSettings
        let model = NativeSimulatorModel()
        let delivery = Delivery()
        init(kind: String) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTSIM-native-flow-" + UUID().uuidString + ".noindex")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            picture = folder.appendingPathComponent("screen.png"); marked = folder.appendingPathComponent("marked.png")
            image = NSImage(size: CGSize(width: 240, height: 480), flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                NSColor.systemBlue.setFill(); NSRect(x: 24, y: 120, width: 192, height: 60).fill()
                return true
            }
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let bytes = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                throw NativeRPCError.malformed("PNG fixture unavailable")
            }
            png = bytes; try png.write(to: picture)
            settings = NativeNarrationSettings(defaults: UserDefaults(suiteName: "HOOTSIM-native-flow-" + UUID().uuidString)!)
            let wire = NativeRPCValue.object([.init("kind", .string(kind)), .init("path", .string(picture.path)),
                .init("sessionId", .string("HOOTSIM-source-session")), .init("targetId", .string("hoot")),
                .init("note", .string("Fix the sign-in button")), .init("device", .object([
                    .init("id", .string("ios:HOOTSIM-STUB")), .init("name", .string("Phone stub"))])),
                .init("sessions", .array([.object([.init("id", .string("HOOTSIM-source-session")),
                    .init("label", .string("Scratch session")), .init("cwd", .string(folder.path))])]))])
            model.installHOOTSIMRenderFixture(wire, image: image)
            model.scopedFeedbackValidate = { [weak model] revision in
                guard model?.attachmentRevision == revision else { throw NativeRPCError.invalidArguments("The capture changed.") }
            }
            model.scopedHootSend = delivery.send
            let saved = picture, markedFile = marked, sourcePNG = png, width = cgImage.width, height = cgImage.height
            model.scopedDeviceInvoke = { channel, arguments in
                switch channel {
                case "devices:screenshot": return ["path": saved.path, "width": width, "height": height,
                    "preview": "data:image/png;base64," + sourcePNG.base64EncodedString()]
                case "annotate:save":
                    let prefix = "data:image/png;base64,"
                    guard let encoded = arguments.first as? String, encoded.hasPrefix(prefix),
                          let bytes = Data(base64Encoded: String(encoded.dropFirst(prefix.count))) else {
                        throw NativeRPCError.invalidArguments("Marked picture missing")
                    }
                    try bytes.write(to: markedFile)
                    return ["path": markedFile.path]
                default: throw NativeRPCError(code: "unavailable", message: "Unexpected fixture device operation: " + channel)
                }
            }
        }
        func remove() { try? FileManager.default.removeItem(at: folder) }
    }
}
