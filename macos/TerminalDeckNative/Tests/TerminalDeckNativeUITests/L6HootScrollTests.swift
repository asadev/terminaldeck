import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Hoot's chat (the page and the island share NativeHootChat) opens at the latest message,
/// stays pinned while replies arrive, and leaves a person who scrolled up where they are,
/// with a "New messages" button. Hosted in a real but never-shown window (not ordered on
/// screen, no activation); no app, engine or AI.
@MainActor final class L6HootScrollTests: XCTestCase {
    private static let conversation = "L6-scroll"
    private static func event(_ index: Int, _ text: String? = nil) -> HootChatEvent {
        HootChatEvent(conversationID: conversation, turnID: "turn-\((index + 1) / 2)", sequence: index, provider: .claude,
            record: index % 2 == 1 ? .text(.user, id: "u\(index)", text ?? "Question number \(index)")
                                   : .text(.message, id: "m\(index)", text ?? "Answer number \(index). " + String(repeating: "More detail. ", count: 6)))
    }
    private static func snapshot(_ events: [HootChatEvent], seen: Int? = nil) -> NativeRPCValue {
        .object([.init("conversationId", .string(conversation)), .init("sequence", .number(Double(events.count))),
                 .init("events", .array(events.map(\.wireValue))), .init("unread", .object([.init("seenSequence", .number(Double(seen ?? events.count)))])), .init("ready", .bool(true)),
                 .init("alive", .bool(true)), .init("busy", .bool(false)), .init("pending", .array([]))])
    }
    private func settle(_ host: NSView) {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); host.displayIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
    }
    private func render(_ host: NSView, _ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["HOOTSIM_RENDER_OUTPUT"], path.hasSuffix(".noindex") else { return }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path).appendingPathComponent("L6-HOOT-scroll-\(name).png"))
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    private func atLatest(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        return document.isFlipped ? scroll.contentView.bounds.maxY >= document.bounds.maxY - 60
            : scroll.contentView.bounds.minY <= document.bounds.minY + 60
    }
    private func scroll(_ scroll: NSScrollView, latest: Bool) {
        guard let document = scroll.documentView else { return }
        let high = max(document.bounds.minY, document.bounds.maxY - scroll.contentView.bounds.height)
        let y = latest == document.isFlipped ? high : document.bounds.minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func testLongOffscreenChatOpensAtLatestAndRespectsReading() throws {
        XCTAssertFalse(EngineBridge.shared.isReady)
        NSApplication.shared.setActivationPolicy(.prohibited)
        for dark in [false, true] {
            for compact in [false, true] {
                var history = (1...240).map { Self.event($0) }
                let model = NativeHootChatModel(fixture: Self.snapshot(history))
                let size = compact ? CGSize(width: 480, height: 420) : CGSize(width: 1000, height: 700)
                let host = NSHostingView(rootView: NativeHootChat(model: model, compact: compact)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.agkitOffscreenSolid, true)
                    .frame(width: size.width, height: size.height)
                    .background(compact ? (dark ? Color.black : Color.white) : Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.isReleasedWhenClosed = false
                window.contentView = host   // never ordered on screen
                defer { window.contentView = nil; window.close() }
                settle(host)
                let name = (compact ? "island" : "page") + (dark ? "-dark" : "-light")
                XCTAssertFalse(window.isVisible)
                // Inspect the actual native scroll view. The old model's scroll
                // fields are no longer bound since the shared unread viewport.
                let scrollView = try XCTUnwrap(scrollViews(in: host).max {
                    ($0.documentView?.bounds.height ?? 0) < ($1.documentView?.bounds.height ?? 0)
                })
                XCTAssertTrue(atLatest(scrollView), "\(name): opens at the latest message")
                try render(host, name + "-open")
                // This window is deliberately inactive. A person reading earlier
                // messages keeps that physical position when a new reply arrives.
                scroll(scrollView, latest: false); settle(host)
                XCTAssertFalse(atLatest(scrollView), "\(name): scrolled up")
                let readingPosition = scrollView.contentView.bounds.origin.y
                history.append(Self.event(history.count + 1, "A brand-new question."))
                history.append(Self.event(history.count + 1, "Another reply while reading."))
                model.acceptFixtureUpdate(Self.snapshot(history, seen: history.count - 2)); settle(host)
                XCTAssertFalse(atLatest(scrollView), "\(name): reading position kept")
                XCTAssertEqual(scrollView.contentView.bounds.origin.y, readingPosition, accuracy: 1,
                               "\(name): incoming replies never move the reader")
                try render(host, name + "-reading")
                scroll(scrollView, latest: true); settle(host)
                XCTAssertTrue(atLatest(scrollView), "\(name): latest message remains reachable")

            }
        }
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    /// "Interrupted by a restart · Send again": only the person's last message, only when its turn never finished.
    func testOnlyAnUnfinishedLastMessageOfThePersonIsOfferedAgain() throws {
        func event(_ sequence: Int, _ turn: String, _ kind: HootChatKind, _ value: NativeRPCValue = .object([])) -> HootChatEvent {
            .init(conversationID: "c", turnID: turn, sequence: sequence, provider: .claude, record: .init(kind, id: kind == .message ? "m" + turn : "", value: value), at: Double(sequence))
        }
        let said = { (text: String) in NativeRPCValue.object([.init("text", .string(text)), .init("context", .object([]))]) }
        let finished = [event(1, "t1", .user, said("hi")), event(2, "t1", .message, said("hello")), event(3, "t1", .completed)]
        XCTAssertNil(NativeHootChatModel.unfinishedTurn(finished))
        let cut = finished + [event(4, "t2", .user, said("deploy it")), event(5, "t2", .textDelta, said("On it")), event(6, "t2", .interrupted)]
        XCTAssertEqual(NativeHootChatModel.unfinishedTurn(cut), "t2", "a restart cut the answer off")
        let fromApp = finished + [event(4, "t3", .user, .object([.init("text", .string("task")), .init("context", .object([.init("source", .object([.init("kind", .string("task"))]))]))]))]
        XCTAssertNil(NativeHootChatModel.unfinishedTurn(fromApp), "a message the app sent in is not offered again")
        let background = finished + [event(4, "bg:task:x:1", .user, said("brief"))]
        XCTAssertNil(NativeHootChatModel.unfinishedTurn(background))
    }

    /// Return with an "@…" typed picks the row the list would take; nobody matching → nothing is picked.
    func testReturnWithAnOpenMentionQueryPicksInsteadOfSending() {
        let people = [HootMention(id: "role:shop/ios", kind: .agent, name: "MT Helper"), HootMention(id: "s1", kind: .session, name: "Builder")]
        XCTAssertEqual(DeckMentionQuery.open(before: "ask @MT ", names: { people.map(\.name) }), "MT ")
        // (Which row Return then takes is DeckMentionPicker.firstPick, FORK-L1's, checked in its own tests: it reads the
        // live session rows, which need the app bundle this runner does not have.)
        XCTAssertNil(DeckMentionQuery.open(before: "ask @MT hello there", names: { people.map(\.name) }), "past every name: Return sends")
    }

    /// M25 (11 Oct): after a Stop the handoff panel shows "Try again"; it must never press itself and ask Hoot again.
    /// (The shared retry button presses itself 0.6 s and 2 s after it appears; that was what re-asked Hoot.)
    @MainActor func testAStoppedHandoffIsNeverAskedForAgainByItself() {
        final class Count { var asked = 0 }
        let count = Count(), saved = NativeHandoffActions.ask
        NativeHandoffActions.ask = { _, _, _, _ in count.asked += 1 }
        defer { NativeHandoffActions.ask = saved }
        let model = NativeHandoffModel(owner: .hoot)   // not a picture: its buttons really ask
        model.isOpen = true
        model.phase = .failed("Stopped. Nothing more is written until you ask again.")
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 460, height: 640), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: NativeHandoffPanel(model: model).frame(width: 460, height: 640))
        window.orderFrontRegardless()
        let end = Date().addingTimeInterval(3.5)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        window.orderOut(nil)
        XCTAssertEqual(count.asked, 0, "nothing asks Hoot again until the person presses Try again")
        if case .failed = model.phase {} else { XCTFail("the panel still says it was stopped") }
        // Control (FORK-L3, safe by default): the shared retry button no longer presses itself either;
        // only a call site that says autoRetry: true does, and only on the "lines are back" signal.
        let control = Count()
        let other = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 200, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        other.contentView = NSHostingView(rootView: DeckRetryButton("Try again") { control.asked += 1 }.frame(width: 200, height: 80))
        other.orderFrontRegardless()
        let stop = Date().addingTimeInterval(3.5)
        while Date() < stop { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        other.orderOut(nil)
        XCTAssertEqual(control.asked, 0, "a default DeckRetryButton never presses itself (it used to, which re-asked Hoot)")
    }
}
