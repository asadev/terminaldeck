import AppKit
import Observation
import SwiftUI
@preconcurrency import SwiftTerm
import XCTest
@testable import TerminalDeckNative

/// Uses the real terminal input surface, with inert session sinks in an offscreen window.
/// No app, engine, session host, provider hooks or system clipboard is started or changed.
@MainActor final class ComposerLeak1112Tests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        override var isKeyWindow: Bool { keyboardActive }
    }
    @MainActor @Observable final class Sessions {
        var crmShown = true
        let crm = DeckTerminalContainer(terminal: DeckTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 240), font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        let deck = DeckTerminalContainer(terminal: DeckTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 240), font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
    }
    private struct CachedSessions: View {
        @Bindable var sessions: Sessions
        var body: some View {
            ZStack {
                NativeTerminalHost(container: sessions.crm)
                    .opacity(sessions.crmShown ? 1 : 0).environment(\.nativeScreenActive, sessions.crmShown)
                NativeTerminalHost(container: sessions.deck)
                    .opacity(sessions.crmShown ? 0 : 1).environment(\.nativeScreenActive, !sessions.crmShown)
            }.frame(width: 680, height: 300)
        }
    }
    @MainActor final class Input: TerminalViewDelegate {
        var bytes = [UInt8]()
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) { MainActor.assumeIsolated { bytes += data } }
        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }
    private func settle(_ host: NSView) {
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    private func capture(_ host: NSView, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["COMPOSER_LEAK_PROOF"] else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }
    func testHiddenTerminalCannotKeepFocusOrReceiveDictatedText() throws {
        let sessions = Sessions(), crmInput = Input(), deckInput = Input()
        sessions.crmShown = false
        sessions.crm.terminal.eventDelegate = crmInput
        sessions.deck.terminal.eventDelegate = deckInput
        sessions.crm.terminal.feed(text: "ClaudeCRM — scratch session\r\n❯ ")
        sessions.deck.terminal.feed(text: "Deck Dev — scratch session\r\n❯ ")
        let host = NSHostingView(rootView: CachedSessions(sessions: sessions))
        let window = ScratchWindow(contentRect: .init(x: -30000, y: -30000, width: 680, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let crm = sessions.crm.terminal, deck = sessions.deck.terminal
        XCTAssertTrue(window.makeFirstResponder(deck))
        sessions.crmShown = true
        settle(host)
        let keptFocus = window.firstResponder === deck
        let prompt = "Look for the mobile applications. Just build it and keep it for you."
        // A delayed text-input callback still names the old text client after the tab switch.
        deck.insertText(prompt, replacementRange: .init(location: NSNotFound, length: 0))
        deck.feed(text: deckInput.text)
        // The intended session then receives and submits the same message.
        XCTAssertTrue(window.makeFirstResponder(crm))
        crm.insertText(prompt, replacementRange: .init(location: NSNotFound, length: 0))
        crm.insertText("\r", replacementRange: .init(location: NSNotFound, length: 0))
        crm.feed(text: prompt + "\r\nSubmitted in ClaudeCRM\r\n❯ ")
        XCTAssertEqual(crmInput.text, prompt + "\r")
        settle(host)
        try capture(host, (ProcessInfo.processInfo.environment["COMPOSER_LEAK_PHASE"] ?? "after") + "-crm-submitted")
        sessions.crmShown = false
        settle(host)
        try capture(host, ProcessInfo.processInfo.environment["COMPOSER_LEAK_PHASE"] ?? "after")
        print("COMPOSER-LEAK: hiddenKeptFocus=\(keptFocus) hiddenDeckReceivedBytes=\(deckInput.bytes.count) crmSubmitted=\(crmInput.text.hasSuffix("\r"))")
        XCTAssertFalse(keptFocus, "A cached terminal must drop the keyboard when hidden")
        XCTAssertEqual(deckInput.text, "", "Wispr-style delayed insertion cannot leave the CRM message in Deck Dev")
        XCTAssertTrue(window.makeFirstResponder(deck))
        deck.insertText("Deck only", replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertEqual(deckInput.text, "Deck only")
        XCTAssertEqual(crmInput.text, prompt + "\r")
    }
    @MainActor @Observable final class ComposerKinds {
        var active = true
        var hoot = HootComposerDraft(text: "Hoot own draft")
        var chat = HootComposerDraft(text: "Chat own draft")
        var comment = HootComposerDraft(text: "Task own comment")
        let terminal = Sessions().crm
    }
    private struct AllComposers: View {
        @Bindable var kinds: ComposerKinds
        var body: some View {
            VStack {
                HootComposer(draft: $kinds.hoot, microphoneAvailable: false, onSend: { _ in }, onStop: {})
                HootComposer(draft: $kinds.chat, microphoneAvailable: false, onSend: { _ in }, onStop: {})
                HootComposer(draft: $kinds.comment, microphoneAvailable: false, onSend: { _ in }, onStop: {})
                NativeTerminalHost(container: kinds.terminal).frame(height: 100)
            }
            .frame(width: 680, height: 700)
            .environment(\.nativeScreenActive, kinds.active)
            .opacity(kinds.active ? 1 : 0)
        }
    }
    private func textClients(_ view: NSView) -> [(NSView, any NSTextInputClient)] {
        let children = view.subviews.flatMap(textClients)
        // Use the concrete leaf text clients, rather than a hosting view forwarding to its child.
        if children.isEmpty, let client = view as? any NSTextInputClient { return [(view, client)] }
        return children
    }
    func testEverySessionComposerRefusesTextWhenItsWarmScreenIsHidden() throws {
        let kinds = ComposerKinds(), input = Input()
        kinds.terminal.terminal.eventDelegate = input
        let host = NSHostingView(rootView: AllComposers(kinds: kinds))
        let window = ScratchWindow(contentRect: .init(x: -30000, y: -30000, width: 680, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let clients = textClients(host)
        XCTAssertEqual(clients.count, 4, "Walk Hoot, session Chat, task comments and Terminal; do not assume all input is NSTextView")
        XCTAssertTrue(window.makeFirstResponder(kinds.terminal.terminal))
        kinds.active = false
        settle(host)
        XCTAssertFalse(window.firstResponder === kinds.terminal.terminal)
        for (surface, client) in clients {
            let editor = surface as? NSTextView
            let old = editor?.string
            if let terminal = surface as? DeckTerminalView {
                XCTAssertNil(terminal.window, "A hidden terminal is outside the keyboard's window")
                XCTAssertFalse(terminal.acceptsUserInput)
            } else { XCTAssertFalse(surface.acceptsFirstResponder, "Hidden input: \(type(of: surface))") }
            client.insertText("wrong session", replacementRange: .init(location: NSNotFound, length: 0))
            editor?.paste(nil)
            XCTAssertEqual(editor?.string, old)
        }
        let terminal = kinds.terminal.terminal
        XCTAssertFalse(terminal.acceptsUserInput)
        XCTAssertNil(terminal.window)
        terminal.insertText("wrong session", replacementRange: .init(location: NSNotFound, length: 0))
        terminal.setMarkedText("wrong marked text", selectedRange: .init(location: 0, length: 0), replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertFalse(terminal.hasMarkedText())
        terminal.paste(self)
        terminal.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(input.text, "")
        XCTAssertEqual(kinds.hoot.text, "Hoot own draft")
        XCTAssertEqual(kinds.chat.text, "Chat own draft")
        XCTAssertEqual(kinds.comment.text, "Task own comment")
    }
    func testHiddenSlotsCannotTakeATerminalFromAnotherWindow() throws {
        let container = Sessions().crm
        let active = DeckTerminalSlot(container: container)
        let hidden = DeckTerminalSlot(container: container, active: false)
        let first = ScratchWindow(contentRect: .init(x: -30000, y: -30000, width: 680, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let second = ScratchWindow(contentRect: .init(x: -31000, y: -31000, width: 680, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.contentView = nil; second.contentView = nil; first.close(); second.close() }
        first.contentView = active; second.contentView = hidden
        XCTAssertTrue(container.superview === active)
        XCTAssertTrue(first.makeFirstResponder(container.terminal))
        hidden.setActive(true)
        XCTAssertTrue(container.superview === hidden)
        // Hiding the new window hands the view back to its still-visible original slot.
        hidden.setActive(false)
        XCTAssertTrue(container.superview === active)
        XCTAssertTrue(container.terminal.inputActive)
        active.setActive(false)
        XCTAssertFalse(container.terminal.acceptsUserInput)
        XCTAssertNil(container.terminal.window)
        XCTAssertFalse(first.firstResponder === container.terminal)
        XCTAssertFalse(second.firstResponder === container.terminal)
    }
    func testBackgroundWindowRefusesDictationButExplicitSessionInputStillWorks() {
        let container = Sessions().crm, input = Input()
        let terminal = container.terminal
        terminal.eventDelegate = input
        let window = ScratchWindow(contentRect: .init(x: -30000, y: -30000, width: 680, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = DeckTerminalSlot(container: container)
        defer { window.contentView = nil; window.close() }
        XCTAssertTrue(window.makeFirstResponder(terminal))
        window.keyboardActive = false
        terminal.insertText("wrong window", replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertEqual(input.text, "")
        guard let slot = window.contentView as? DeckTerminalSlot else { return XCTFail("Missing terminal slot") }
        slot.setActive(false)
        slot.setActive(true, focus: false)
        XCTAssertFalse(window.firstResponder === terminal, "Showing a secondary split pane cannot steal the keyboard")
        window.keyboardActive = true
        terminal.insertText("unfocused pane", replacementRange: .init(location: NSNotFound, length: 0))
        XCTAssertEqual(input.text, "", "A visible pane without the keyboard cannot receive late dictation either")
        slot.setActive(false)
        // MCP/agent input is explicitly addressed by session ID, independent of the keyboard.
        terminal.sendExplicitText("explicit target")
        XCTAssertEqual(input.text, "explicit target")
        input.bytes = []
        terminal.feed(text: "\u{1b}[6n")
        XCTAssertFalse(input.bytes.isEmpty, "Background programs still receive their terminal protocol replies")
    }
    func testRestoredDraftAndQueuedMessageRecordsRemainSeparateWithoutTabKeys() throws {
        // Reuse 30389758's existing injection hook. The runner may ignore CFFIXED_USER_HOME;
        // a unique preferences suite keeps this check away from the real app's saved drafts.
        let suiteName = "dev.td.tests.composer-1112." + UUID().uuidString
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let previous = NativeChatOutbox.defaults
        NativeChatOutbox.defaults = suite
        defer {
            NativeChatOutbox.defaults = previous
            suite.removePersistentDomain(forName: suiteName)
        }
        XCTAssertTrue(NativeChatOutbox.sessions.isEmpty)
        let crm = "composer-1112-crm-" + UUID().uuidString
        let deck = "composer-1112-deck-" + UUID().uuidString
        defer { NativeChatOutbox.remove(crm); NativeChatOutbox.remove(deck) }
        let queued = NativeChatOutbox.Entry(id: "crm-message", draft: .init(text: "CRM queued only"), held: true)
        try NativeChatOutbox.save(crm, name: "same folder", entries: [queued], draft: .init(text: "CRM draft only"))
        try NativeChatOutbox.save(deck, name: "same folder", entries: [], draft: .init(text: "Deck draft only"))
        XCTAssertTrue(suite.synchronize())
        NativeChatOutbox.defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        // A fresh preferences reader decodes the saved records; neither has a tab-key fallback.
        XCTAssertEqual(NativeChatOutbox.load(crm)?.draft?.text, "CRM draft only")
        XCTAssertEqual(NativeChatOutbox.load(crm)?.entries.map(\.draft.text), ["CRM queued only"])
        XCTAssertEqual(NativeChatOutbox.load(deck)?.draft?.text, "Deck draft only")
        XCTAssertEqual(NativeChatOutbox.load(deck)?.entries.count, 0)
        XCTAssertNil(NativeChatOutbox.load(crm)?.tabKey)
        XCTAssertNil(NativeChatOutbox.load(deck)?.tabKey)
        try NativeChatOutbox.save(crm, name: "same folder", entries: [], draft: HootComposerDraft())
        XCTAssertNil(NativeChatOutbox.load(crm))
        XCTAssertEqual(NativeChatOutbox.load(deck)?.draft?.text, "Deck draft only")
    }

}
