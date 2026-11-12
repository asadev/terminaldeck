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
    // Exercise keyboard ownership without ordering or activating a window on screen.
    final class KeyboardWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
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
        let window = KeyboardWindow(contentRect: .init(x: -30000, y: -30000, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
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
        let view = NativeChatFollowViewport()
        XCTAssertTrue(view.measure(offset: 700, viewport: 300, content: 1000))
        XCTAssertTrue(view.measure(offset: 700, viewport: 300, content: 1300))
        _ = view.measure(offset: 1000, viewport: 300, content: 1300)
        XCTAssertTrue(view.following)
        XCTAssertFalse(view.measure(offset: 200, viewport: 300, content: 1300))
        XCTAssertFalse(view.following)
        XCTAssertFalse(view.measure(offset: 200, viewport: 300, content: 1700))
        view.latest()
        XCTAssertTrue(view.following)
        XCTAssertEqual(view.position.edge, .bottom)
        _ = view.measure(offset: 1400, viewport: 300, content: 1700)
        _ = view.measure(offset: 200, viewport: 300, content: 1700)
        _ = view.measure(offset: 1400, viewport: 300, content: 1700)
        XCTAssertTrue(view.following)
    }
}
