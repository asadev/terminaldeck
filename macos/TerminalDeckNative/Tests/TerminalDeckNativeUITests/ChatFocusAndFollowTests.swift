import AppKit
import Observation
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 30 Oct (Asad, install 12: "old problems are back").
/// 1. A message pasted into Hoot was waiting in another chat's box: a chat switched away from stays mounted (transparent,
///    for instant switches) and its box kept the keyboard, so Paste and typing went into a box nobody could see.
/// 2. After sending, the chat did not move up: it scrolled once before the sent message existed and never followed
///    the answer as it streamed in.
@MainActor final class ChatFocusAndFollowTests: XCTestCase {
    @Observable final class TwoChats {
        var hoot = HootComposerDraft(text: "hoot draft")
        var session = HootComposerDraft(text: "session draft")
        var hootShown = false
    }
    /// The main window's cached screens, as ContentView keeps them: both mounted, only one on show.
    private struct Stack: View {
        @Bindable var chats: TwoChats
        var body: some View {
            ZStack {
                HootComposer(draft: $chats.hoot, microphoneAvailable: false, onSend: { _ in }, onStop: {})
                    .opacity(chats.hootShown ? 1 : 0).environment(\.nativeScreenActive, chats.hootShown)
                HootComposer(draft: $chats.session, microphoneAvailable: false, onSend: { _ in }, onStop: {})
                    .opacity(chats.hootShown ? 0 : 1).environment(\.nativeScreenActive, !chats.hootShown)
            }.frame(width: 640, height: 400)
        }
    }
    private func boxes(_ view: NSView) -> [HootComposerTextView] {
        ((view as? HootComposerTextView).map { [$0] } ?? []) + view.subviews.flatMap(boxes)
    }
    private func settle(_ host: NSView) {
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testAHiddenChatsBoxLetsGoOfTheKeyboardAndTakesNoPastedText() throws {
        let chats = TwoChats()
        let host = NSHostingView(rootView: Stack(chats: chats))
        let window = NSWindow(contentRect: .init(x: -30000, y: -30000, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let all = boxes(host)
        let sessionBox = try XCTUnwrap(all.first { $0.string == "session draft" })
        let hootBox = try XCTUnwrap(all.first { $0.string == "hoot draft" })
        XCTAssertFalse(hootBox.acceptsFirstResponder, "A hidden chat's box never takes the keyboard")

        // He is typing in the session chat, then switches to Hoot.
        XCTAssertTrue(window.makeFirstResponder(sessionBox))
        chats.hootShown = true
        settle(host)
        XCTAssertFalse(window.firstResponder === sessionBox, "The hidden session's box let go of the keyboard")
        XCTAssertFalse(sessionBox.acceptsFirstResponder)
        sessionBox.insertText(" pasted", replacementRange: NSRange(location: NSNotFound, length: 0))
        sessionBox.paste(nil)
        XCTAssertEqual(chats.session.text, "session draft", "Nothing typed or pasted lands in a box nobody can see")
        XCTAssertEqual(sessionBox.string, "session draft")

        // Hoot's own box takes it, and only Hoot's draft changes.
        XCTAssertTrue(window.makeFirstResponder(hootBox))
        hootBox.setSelectedRange(NSRange(location: (hootBox.string as NSString).length, length: 0))
        hootBox.insertText(" pasted", replacementRange: hootBox.selectedRange())
        XCTAssertEqual(chats.hoot.text, "hoot draft pasted")
        XCTAssertEqual(chats.session.text, "session draft")

        // Hoot sends (its draft clears); back in the session its own draft is there, untouched.
        chats.hoot = HootComposerDraft()
        chats.hootShown = false
        settle(host)
        XCTAssertFalse(window.firstResponder === hootBox)
        XCTAssertEqual(sessionBox.string, "session draft")
        XCTAssertEqual(chats.session.text, "session draft")
        XCTAssertTrue(sessionBox.acceptsFirstResponder, "The chat on show takes the keyboard again")
    }

    func testSendingAndStreamingFollowTheNewestUnlessThePersonScrolledUp() {
        let view = NativeChatUnreadViewport()
        let messages = [ChatUnreadMessage(id: "m1", sequence: 1)]
        view.appear(); view.active = true
        view.receive(conversation: "c", seen: 1, messages: messages)
        view.geometry(.init(x: 0, y: 700, width: 600, height: 300), bottom: true, contentHeight: 1000)
        XCTAssertTrue(view.following)

        // Content grows below (the sent message, then streamed words): the chat follows it.
        view.position.scrollTo(id: "elsewhere")
        view.geometry(.init(x: 0, y: 700, width: 600, height: 300), bottom: false, contentHeight: 1300)
        XCTAssertEqual(view.position.edge, .bottom, "New content keeps the newest in view")
        XCTAssertFalse(view.showsJumpToLatest)

        // He scrolls up to read: the chat stays where he is and offers the way back.
        view.geometry(.init(x: 0, y: 200, width: 600, height: 300), bottom: false, contentHeight: 1300)
        XCTAssertFalse(view.following)
        XCTAssertTrue(view.showsJumpToLatest)
        view.position.scrollTo(id: "reading")
        view.geometry(.init(x: 0, y: 200, width: 600, height: 300), bottom: false, contentHeight: 1700)
        XCTAssertEqual(view.position.viewID(type: String.self), "reading", "Streaming never yanks a reader down")
        view.receive(conversation: "c", seen: 1, messages: messages)
        XCTAssertEqual(view.position.viewID(type: String.self), "reading")

        // Jump to latest (or sending) brings the newest back and follows again.
        view.jumpToLatest()
        XCTAssertTrue(view.following)
        XCTAssertEqual(view.position.edge, .bottom)
        XCTAssertFalse(view.showsJumpToLatest)

        // Scrolling back down to the bottom by hand also turns following back on.
        view.geometry(.init(x: 0, y: 200, width: 600, height: 300), bottom: false, contentHeight: 1700)
        view.geometry(.init(x: 0, y: 1400, width: 600, height: 300), bottom: true, contentHeight: 1700)
        XCTAssertTrue(view.following)

        // Coming back to a chat with nothing unread opens it at the newest message.
        view.geometry(.init(x: 0, y: 200, width: 600, height: 300), bottom: false, contentHeight: 1700)
        view.position.scrollTo(id: "reading")
        view.returned()
        XCTAssertEqual(view.position.edge, .bottom)
        view.disappear()
    }
}
