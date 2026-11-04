import AppKit
import Observation
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Scripted, never-shown scratch windows. No engine connection, live AI, session host or real defaults.
@MainActor final class ChatUI27Tests: XCTestCase {
    private var savedDefaults: UserDefaults!
    private var suite = ""
    override func setUp() async throws {
        suite = "dev.terminaldeck.chat-ui-27." + UUID().uuidString
        savedDefaults = NativeChatOutbox.defaults
        NativeChatOutbox.defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    override func tearDown() async throws {
        NativeChatOutbox.defaults.removePersistentDomain(forName: suite)
        NativeChatOutbox.defaults = savedDefaults
    }
    private func snapshot(_ id: String, events: [HootChatEvent] = [], busy: Bool = false) -> NativeRPCValue {
        .object([.init("conversationId", .string(id)), .init("sequence", .number(Double(events.last?.sequence ?? 0))),
            .init("events", .array(events.map(\.wireValue))), .init("alive", .bool(true)), .init("busy", .bool(busy))])
    }
    private func model(_ id: String, invoke: NativeHOOTSIMFeedback.Invoke? = nil) -> NativeHootChatModel {
        NativeHootChatModel(fixture: snapshot(id), chatInvoke: invoke, source: .session(id, provider: "codex"))
    }
    @Observable fileprivate final class Seat {
        var selected = 0
        let chats: [NativeHootChatModel]
        init(_ chats: [NativeHootChatModel]) { self.chats = chats }
    }
    private struct ReusedChat: View {
        @Bindable var seat: Seat
        var body: some View {
            // Deliberately reuse this view location, as a split pane or a conversation inspector can.
            NativeHootChat(model: seat.chats[seat.selected])
                .environment(\.agkitOffscreenSolid, true).frame(width: 820, height: 650)
                .background(DeckTokens.chatPage)
        }
    }
    private func boxes(_ view: NSView) -> [HootComposerTextView] {
        ((view as? HootComposerTextView).map { [$0] } ?? []) + view.subviews.flatMap(boxes)
    }
    private func settle(_ host: NSView) {
        for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
    }
    private func window<V: View>(_ content: V, dark: Bool = false) -> (NSWindow, NSHostingView<V>) {
        let host = NSHostingView(rootView: content)
        let panel = NativePassiveChatPanel(contentRect: .init(x: -30000, y: -30000, width: 820, height: 650),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.prepareForPassiveCapture(); panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        panel.contentView = host
        settle(host)
        return (panel, host)
    }
    @discardableResult private func shot(_ host: NSView, _ name: String) throws -> NSBitmapImageRep? {
        guard let path = ProcessInfo.processInfo.environment["CHAT_UI_27_PROOF"], path.hasSuffix(".noindex") else { return nil }
        let out = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.effectiveAppearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
        return bitmap
    }
    func testThreeSessionsAndHootKeepOnlyTheirOwnDraftAndSavedBinding() throws {
        for dark in [false, true] {
            let theme = dark ? "dark" : "light"
            let first = model("scratch-one"), second = model("scratch-two"), third = model("scratch-three")
            let hoot = NativeHootChatModel(fixture: snapshot("scratch-hoot"))
            let seat = Seat([first, second, third, hoot])
            let (panel, host) = window(ReusedChat(seat: seat).environment(\.colorScheme, dark ? .dark : .light), dark: dark)
            defer { panel.contentView = nil; panel.close() }
            let firstBox = try XCTUnwrap(boxes(host).first)
            firstBox.insertText("Only session one", replacementRange: .init(location: 0, length: 0))
            XCTAssertEqual(first.composerDraft.text, "Only session one")
            settle(host); try shot(host, "draft-one-" + theme)
            let delayedBinding = first.ownedComposerBinding
            for index in 1...3 {
                seat.selected = index; settle(host)
                XCTAssertEqual(boxes(host).first?.string, "", "Session \(index + 1) starts with its own empty box")
                XCTAssertEqual(seat.chats[index].composerDraft.text, "")
                // A stale AppKit notification from another box cannot populate the selected session.
                let foreign = NSTextView(); foreign.string = "foreign session's message"
                boxes(host).first?.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: foreign))
                XCTAssertEqual(seat.chats[index].composerDraft.text, "")
                try shot(host, "draft-empty-\(index + 1)-" + theme)
            }
            // A callback captured before switching cannot write through the new view's owner.
            var restored = delayedBinding.wrappedValue; restored.text += " restored"
            delayedBinding.wrappedValue = restored
            XCTAssertEqual(hoot.composerDraft.text, "")
            seat.selected = 0; settle(host)
            XCTAssertEqual(boxes(host).first?.string, "Only session one restored")
            XCTAssertEqual(second.composerDraft.text, "")
            XCTAssertEqual(third.composerDraft.text, "")
            try shot(host, "draft-return-one-" + theme)
            XCTAssertFalse(panel.isVisible)
        }
    }
    func testFailureAfterSwitchingRestoresOnlyTheSendingSession() async throws {
        for dark in [false, true] {
            var attempted = false
            let first = model("scratch-failure") { channel, _ in
                if channel.hasSuffix(":say") {
                    attempted = true
                    try await Task.sleep(for: .milliseconds(120))
                    throw NativeRPCError(code: "scratch-refusal", message: "Scratch send refused")
                }
                return self.snapshot("scratch-failure").foundation!
            }
            let second = model("scratch-other")
            let seat = Seat([first, second])
            let (panel, host) = window(ReusedChat(seat: seat).environment(\.colorScheme, dark ? .dark : .light), dark: dark)
            defer { panel.contentView = nil; panel.close() }
            first.composerDraft.text = "Return only to the sending box"
            first.send()
            seat.selected = 1; settle(host)
            for _ in 0..<100 where first.sending { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(attempted)
            XCTAssertFalse(first.sending)
            XCTAssertEqual(first.composerDraft.text, "Return only to the sending box")
            XCTAssertTrue(first.problem?.contains("Not sent") == true)
            XCTAssertEqual(boxes(host).first?.string, "")
            XCTAssertEqual(second.composerDraft.text, "")
            try shot(host, "failed-send-other-empty-" + (dark ? "dark" : "light"))
            seat.selected = 0; settle(host)
            XCTAssertEqual(boxes(host).first?.string, "Return only to the sending box")
            try shot(host, "failed-send-own-restored-" + (dark ? "dark" : "light"))
        }
    }
    func testSidebarCanObserveTheFirstModelAttachment() {
        let id = "scratch-registry-" + UUID().uuidString
        let changed = expectation(description: "The row sees its chat model attach")
        withObservationTracking { _ = NativeHootChatModel.queueOwner(id) } onChange: { changed.fulfill() }
        let chat = NativeHootChatModel.forSession(id, name: "Codex")
        XCTAssertTrue(NativeHootChatModel.queueOwner(id) === chat)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 0.1), .completed)
    }
    func testOutboxRoundTripsByStableIDInOnlyTheScratchSuite() throws {
        for id in ["scratch-1", "scratch-2", "hoot"] {
            try NativeChatOutbox.save(id, name: id, entries: [], draft: .init(text: "Draft for " + id))
        }
        XCTAssertEqual(Set(NativeChatOutbox.sessions), Set(["scratch-1", "scratch-2", "hoot"]))
        XCTAssertEqual(NativeChatOutbox.load("scratch-1")?.draft?.text, "Draft for scratch-1")
        XCTAssertEqual(NativeChatOutbox.load("scratch-2")?.draft?.text, "Draft for scratch-2")
        XCTAssertEqual(NativeChatOutbox.load("hoot")?.draft?.text, "Draft for hoot")
        XCTAssertNil(NativeChatOutbox.load("scratch-3"))
    }
    func testReusedTerminalSlotShowsTheSelectedSessionsContainer() {
        // A terminal's draft lives in its own terminal buffer. No session model or connection is needed here.
        func container() -> DeckTerminalContainer {
            DeckTerminalContainer(terminal: DeckTerminalView(frame: .init(x: 0, y: 0, width: 400, height: 200), font: .monospacedSystemFont(ofSize: 12, weight: .regular)))
        }
        let one = container(), two = container(), three = container()
        let slot = DeckTerminalSlot(container: one)
        let panel = NSWindow(contentRect: .init(x: -30000, y: -30000, width: 400, height: 240), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.contentView = slot
        defer { panel.contentView = nil; panel.close() }
        for selected in [two, three, one] {
            slot.show(selected)
            XCTAssertTrue(slot.container === selected)
            XCTAssertTrue(selected.superview === slot)
            XCTAssertEqual(slot.subviews.count, 1)
            XCTAssertTrue(slot.subviews.first === selected)
        }
    }
    func testWorkingToolLineRendersInBothThemesAndEndsOnlyAtTurnEnd() async throws {
        let since = Date().timeIntervalSince1970 * 1000 - 134_000
        func event(_ n: Int, _ record: HootChatRecord) -> HootChatEvent {
            .init(conversationID: "scratch-working", turnID: "turn", sequence: n, provider: .codex, record: record, at: since)
        }
        for dark in [false, true] {
            let chat = model("scratch-working")
            let seat = Seat([chat])
            let (panel, host) = window(ReusedChat(seat: seat).environment(\.colorScheme, dark ? .dark : .light), dark: dark)
            defer { panel.contentView = nil; panel.close() }
            var events = [event(1, .text(.user, "Run the scratch command and wait for its result.")),
                event(2, .init(.toolCall, id: "scratch-cmd", value: .object([.init("name", .string("Bash")), .init("input", .object([.init("command", .string("sleep 15"))]))])))]
            chat.acceptFixtureUpdate(snapshot("scratch-working", events: events, busy: true)); settle(host)
            let command = Process(); command.executableURL = URL(fileURLWithPath: "/bin/sleep"); command.arguments = ["15"]
            try command.run()
            XCTAssertTrue(command.isRunning)
            XCTAssertTrue(chat.workingState.active)
            XCTAssertEqual(chat.workingState.detail, "running a command")
            let read = try await chat.featureTool("activity", action: "read", args: .object([]))
            XCTAssertTrue(read["active"].bool == true)
            try shot(host, "working-tool-" + (dark ? "dark" : "light"))
            var capturedMiddle = false
            let middle = Date().addingTimeInterval(7)
            while command.isRunning {
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(chat.workingState.active, "Silence from a running command cannot hide the Working line")
                if !capturedMiddle, Date() >= middle {
                    settle(host)
                    try shot(host, "working-tool-middle-" + (dark ? "dark" : "light"))
                    capturedMiddle = true
                }
            }
            XCTAssertTrue(capturedMiddle)
            events.append(event(3, .init(.toolResult, id: "scratch-cmd")))
            chat.acceptFixtureUpdate(snapshot("scratch-working", events: events, busy: true))
            XCTAssertTrue(chat.workingState.active, "The provider is still answering after the command ended")
            events.append(event(4, .text(.message, "The scratch command finished.")))
            events.append(event(5, .init(.completed)))
            chat.acceptFixtureUpdate(snapshot("scratch-working", events: events)); settle(host)
            XCTAssertFalse(chat.workingState.active)
            try shot(host, "turn-ended-" + (dark ? "dark" : "light"))
            XCTAssertFalse(panel.isVisible)
        }
    }
    func testFullFrameProofHasTheRealParentPageBackground() throws {
        guard ProcessInfo.processInfo.environment["CHAT_UI_27_PROOF"] != nil else { throw XCTSkip("Set the scratch capture folder to render full frames.") }
        for dark in [false, true] {
            let name = dark ? "dark" : "light"
            let chat = model("scratch-full-frame")
            let seat = Seat([chat])
            let (panel, host) = window(ReusedChat(seat: seat).environment(\.colorScheme, dark ? .dark : .light), dark: dark)
            defer { panel.contentView = nil; panel.close() }
            func capture(_ label: String) throws {
                settle(host)
                let bitmap = try XCTUnwrap(try shot(host, "full-frame-" + label + "-" + name))
                XCTAssertEqual(bitmap.pixelsWide, 820)
                XCTAssertEqual(bitmap.pixelsHigh, 650)
                XCTAssertEqual(bitmap.colorAt(x: 0, y: 300)?.alphaComponent, 1)
            }
            chat.composerDraft.text = "Only this session's draft"
            try capture("draft")
            let at = Date().timeIntervalSince1970 * 1000 - 134_000
            func event(_ n: Int, _ record: HootChatRecord) -> HootChatEvent {
                .init(conversationID: "scratch-full-frame", turnID: "turn", sequence: n, provider: .codex, record: record, at: at)
            }
            var events = [event(1, .text(.user, "Run the scratch command and wait for its result.")),
                event(2, .init(.toolCall, id: "cmd", value: .object([.init("name", .string("Bash")), .init("input", .object([.init("command", .string("sleep 15"))]))])))]
            chat.composerDraft.text = ""
            chat.acceptFixtureUpdate(snapshot("scratch-full-frame", events: events, busy: true))
            try capture("working")
            events += [event(3, .init(.toolResult, id: "cmd")), event(4, .text(.message, "The scratch command finished.")), event(5, .init(.completed))]
            chat.acceptFixtureUpdate(snapshot("scratch-full-frame", events: events))
            try capture("ended")
            XCTAssertFalse(panel.isVisible)
        }
    }

}
