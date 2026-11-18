import AppKit
import SwiftUI
import WebKit
import XCTest
@preconcurrency import SwiftTerm
@testable import TerminalDeckNative
@testable import TerminalDeckNativeCore
import TerminalDeckBackend

/// MAC-NEXT-14. Asad, 14 Nov 00:59: another session's AI typed `#f5d76e` into a website and it appeared in HIS session's
/// prompt, where his cursor was; and "my messages are going to other sessions too". Real window, real WKWebView, real
/// terminal and text views; the browser tools' own path (BrowserDriverEngine over NativeSafariRuntime).
///
/// Late re-delivery: WebKit answers a key event from its web process later and hands the keys its page did not take
/// back to `NSApp.sendEvent`, and AppKit gives those to the KEY window's first responder. A local event monitor sees
/// every event that reaches the app that way; here it also delivers it to the person's window exactly as AppKit
/// would with his key window, so a leak shows up in his field. Waiting: WebKit's messages are ordered, so after two
/// script round trips every earlier key event has been answered; a further bounded 400 ms real wait covers the
/// app-side re-send (the first test proves this wait catches it).
@MainActor
final class TypingNeverTouchesHisKeyboardTests: XCTestCase {
    /// His window: key, as when he is typing in it.
    final class HisWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }
    @MainActor final class Bytes: TerminalViewDelegate {
        var bytes = [UInt8]()
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) { MainActor.assumeIsolated { bytes += data } }
        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }
    /// Every key event that reaches the app outside his own typing; delivered to his window as AppKit would.
    @MainActor final class AppKeys {
        var seen: [String] = []
        private var token: Any?
        init(deliverTo window: NSWindow) {
            token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak window] event in
                MainActor.assumeIsolated {
                    if event.type == .keyDown { self?.seen.append(event.characters ?? "") }
                    window?.sendEvent(event)
                }
                return nil
            }
        }
        func stop() { if let token { NSEvent.removeMonitor(token) }; token = nil }
    }

    static let page = """
    <!doctype html><meta charset=utf-8><body style="margin:0">
    <input id=i style="width:300px"><br><textarea id=t style="width:300px;height:60px"></textarea>
    <div id=c contenteditable style="width:300px;min-height:30px;border:1px solid"></div>
    <input id=b style="width:300px"><button id=go>Go</button>
    <script>
    // A field that blurs itself after five characters (a code box moving on, a widget closing).
    document.getElementById('b').addEventListener('input', function () { if (this.value.length >= 5) this.blur() });
    </script>
    """
    /// 200 characters: what a step types one key at a time (BrowserStepRules.perKeyLimit), with a colour code, spaces,
    /// accents and an emoji.
    static let text: String = {
        let piece = "#f5d76e Asad é ü 😀 "
        var out = ""
        while out.count < 200 { out += piece }
        return String(out.prefix(200))
    }()

    private func runtime() -> NativeSafariRuntime {
        // The real path: /var is a link to /private/var, and screenshots refuse a linked folder.
        // (Foundation's resolvingSymlinksInPath gives /var back; realpath gives the real /private/var.)
        let temp = realpath(FileManager.default.temporaryDirectory.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? NSTemporaryDirectory()
        let scratch = URL(fileURLWithPath: temp).appendingPathComponent("td-typing-\(UUID().uuidString)")
        return NativeSafariRuntime(tabs: NativeBrowserTabs.shared, bindings: BackendBrowserBindings(), dataRoot: scratch, screenshotDirectory: scratch,
                                   browserData: { _, _ in NSNull() }, authorizePopup: { _, _, _ in }, publish: { _, _ in })
    }

    private func js(_ view: WKWebView, _ script: String) async -> Any? {
        try? await view.evaluateJavaScript(script, in: nil, contentWorld: .page)
    }

    /// Two ordered round trips, then the bounded real wait (see the class comment).
    private func drain(_ view: WKWebView) async {
        _ = await js(view, "1"); _ = await js(view, "2")
        try? await Task.sleep(for: .milliseconds(400))
    }

    private func load(_ tab: NativeBrowserTab) async throws -> WKWebView {
        tab.ensurePage()
        let view = try XCTUnwrap(tab.webView)
        view.loadHTMLString(Self.page, baseURL: URL(string: "https://typing.test/"))
        for _ in 0..<300 {
            if await js(view, "document.readyState === 'complete' && !!document.getElementById('b')") as? Bool == true { return view }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the scratch page did not load"); return view
    }

    private func step(_ engine: BrowserDriverEngine, _ args: [String: Any]) async -> [String: Any] {
        let command = BrowserDriverCommand.decode([["id": UUID().uuidString, "verb": "browser_step", "args": args]])!
        return await engine.answer(command)
    }

    private func hisWindow(page: WKWebView?) -> HisWindow {
        let window = HisWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
        window.contentView = content
        if let page { page.frame = NSRect(x: 500, y: 0, width: 500, height: 500); content.addSubview(page) }
        window.orderBack(nil)
        return window
    }

    private func makeTerminal(in window: NSWindow, frame: NSRect) -> (DeckTerminalView, Bytes, DeckTerminalSlot) {
        let view = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 240), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let bytes = Bytes()
        view.eventDelegate = bytes
        let slot = DeckTerminalSlot(container: DeckTerminalContainer(terminal: view))
        slot.frame = frame
        window.contentView?.addSubview(slot)
        slot.layoutSubtreeIfNeeded()
        return (view, bytes, slot)
    }

    private func key(_ characters: String, _ window: NSWindow, repeat isRepeat: Bool = false, code: UInt16 = 0) -> [NSEvent] {
        [NSEvent.EventType.keyDown, .keyUp].compactMap {
            NSEvent.keyEvent(with: $0, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: code)
        }
    }
    /// His own key, as AppKit delivers a key typed into his key window.
    private func type(_ characters: String, into window: NSWindow, repeat isRepeat: Bool = false) {
        for event in key(characters, window, repeat: isRepeat) { window.sendEvent(event) }
    }

    // MARK: The mechanism, reproduced (the path this commit removed)

    /// The removed path: the page made first responder of his window, AppKit key events sent to it, his keyboard given
    /// back. The page has no focused field, so WebKit hands the keys back to the app, and they land in HIS field.
    func testTheRemovedKeyPathHandedThePagesKeysToHisField() async throws {
        let tab = NativeBrowserTabs.shared.create(isolated: true, show: false)
        defer { NativeBrowserTabs.shared.close(tab.id) }
        let page = try await load(tab)
        let window = hisWindow(page: page)
        defer { window.close() }
        let his = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 500))
        window.contentView?.addSubview(his)
        XCTAssertTrue(window.makeFirstResponder(his))
        let keys = AppKeys(deliverTo: window)
        defer { keys.stop() }
        let previous = window.firstResponder
        window.makeFirstResponder(page)
        for character in "#f5d76e" {
            for event in key(String(character), window) { if event.type == .keyDown { page.keyDown(with: event) } else { page.keyUp(with: event) } }
        }
        window.makeFirstResponder(previous)
        await drain(page)
        // Measured: the first key reaches the page while it still holds the keyboard; every key after it is answered
        // by WebKit after the hand-back, finds no focused page, and comes back.
        XCTAssertTrue(keys.seen.joined().hasSuffix("f5d76e"), "WebKit handed the keys its page did not take back to the app: \(keys.seen)")
        XCTAssertTrue(his.string.hasSuffix("f5d76e"), "and AppKit put them in the person's own field, Asad's report: \(his.string)")
    }

    // MARK: 1 and 5: an AI's typing reaches only its own page

    func testToolTypingReachesOnlyItsPage() async throws {
        for placement in ["beside his session", "parked off screen"] {
            for hisPlace in ["text field", "terminal"] {
                try await typingRound(placement: placement, hisPlace: hisPlace)
            }
        }
    }

    private func typingRound(placement: String, hisPlace: String) async throws {
        let label = "\(placement), his cursor in a \(hisPlace)"
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let page = try await load(tab)
        let window = hisWindow(page: placement == "beside his session" ? page : nil)
        defer { window.close() }
        XCTAssertTrue(NativeBrowserWebView.instancesRespond(to: NativeBrowserWebView.suppressPageFocusSelector),
                      "WebKit still has the switch that keeps a page from taking the keyboard")

        // His place: a text field with half-typed text and his cursor in the middle, or a terminal.
        var field: NSTextField?, terminal: (DeckTerminalView, Bytes, DeckTerminalSlot)?
        if hisPlace == "text field" {
            let made = NSTextField(string: "half typed")
            made.frame = NSRect(x: 10, y: 450, width: 300, height: 22)
            window.contentView?.addSubview(made)
            XCTAssertTrue(window.makeFirstResponder(made))
            (made.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 4, length: 2))
            field = made
        } else {
            let made = makeTerminal(in: window, frame: NSRect(x: 0, y: 0, width: 480, height: 400))
            XCTAssertTrue(window.makeFirstResponder(made.0))
            terminal = made
        }
        let responder = window.firstResponder
        let keys = AppKeys(deliverTo: window)
        defer { keys.stop() }
        run.ownTabID = tab.id
        let engine = BrowserDriverEngine(host: run)
        func hisIsUntouched(_ moment: String) {
            XCTAssertTrue(window.firstResponder === responder, "\(label), \(moment): his keyboard stayed where it was")
            XCTAssertEqual(keys.seen, [], "\(label), \(moment): no key reached the app")
            if let field {
                XCTAssertEqual(field.stringValue, "half typed", "\(label), \(moment): his text")
                XCTAssertEqual((field.currentEditor() as? NSTextView)?.selectedRange(), NSRange(location: 4, length: 2), "\(label), \(moment): his selection")
            }
            if let terminal { XCTAssertEqual(terminal.1.bytes.count, 0, "\(label), \(moment): his session received 0 bytes") }
        }

        // 200 characters into an input, a textarea and a contenteditable, each focused by the step.
        for selector in ["#i", "#t", "#c"] {
            let answer = await step(engine, ["verb": "type", "selector": selector, "value": Self.text])
            XCTAssertNil(answer["error"], "\(label) \(selector): \(answer)")
            await drain(page)
            hisIsUntouched("typing into \(selector)")
        }
        let typed = await js(page, "[i.value, t.value, c.innerText.replace(/\\u00a0/g, ' ')]") as? [String]
        XCTAssertEqual(typed, [Self.text, Self.text, Self.text], "\(label): the page received exactly what was sent")

        // Enter, Tab, the arrows and Backspace, with the page's field focused.
        for name in ["ArrowLeft", "Backspace", "ArrowRight", "ArrowUp", "ArrowDown"] {
            let answer = await step(engine, ["verb": "press", "selector": "#i", "key": name])
            XCTAssertNil(answer["error"], "\(label) \(name): \(answer)")
        }
        _ = await step(engine, ["verb": "press", "selector": "#t", "key": "Enter"])
        _ = await step(engine, ["verb": "press", "selector": "#i", "key": "Tab"])
        await drain(page)
        hisIsUntouched("pressing keys in a focused field")
        let chars = Array(Self.text)
        let afterKeys = await js(page, "[i.value, t.value, document.activeElement && document.activeElement.id]") as? [String]
        XCTAssertEqual(afterKeys, [String(chars[0..<198]) + String(chars[199]), Self.text + "\n", "t"],
                       "\(label): Left, Backspace (one character), Right, Up, Down, Enter in the textarea, Tab to the next field")

        // The same keys with no field focused in the page: they go nowhere, never to him.
        _ = await js(page, "document.activeElement && document.activeElement.blur()")
        for name in ["Enter", "Tab", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Backspace"] {
            let answer = await step(engine, ["verb": "press", "key": name])
            XCTAssertNil(answer["error"], "\(label) unfocused \(name): \(answer)")
        }
        await drain(page)
        hisIsUntouched("pressing keys with nothing focused in the page")

        // A field that blurs itself after five characters: the rest still goes to that field, never anywhere else.
        let answer = await step(engine, ["verb": "type", "selector": "#b", "value": "abcdefghij"])
        XCTAssertNil(answer["error"], "\(label) #b: \(answer)")
        await drain(page)
        hisIsUntouched("typing into a field that blurs itself")
        let blurred = await js(page, "b.value") as? String
        XCTAssertEqual(blurred, "abcdefghij", "\(label): the self-blurring field received exactly what was sent")
        if placement == "parked off screen" {
            XCTAssertTrue(page.window is NativeBrowserCaptureWindow, "the page worked where it was, off screen")
            XCTAssertFalse(page.window?.isKeyWindow ?? true)
        } else {
            XCTAssertTrue(page.window === window, "the page stayed beside his session")
        }
        field?.removeFromSuperview(); terminal?.2.removeFromSuperview()
    }

    // MARK: 2 and Asad's (c): his own keys during a tool's typing all land in his place

    func testHisKeysDuringAToolsTypingAllLandInHisPlace() async throws {
        for hisPlace in ["text field", "terminal"] {
            let tabs = NativeBrowserTabs.shared, run = runtime()
            let tab = tabs.create(isolated: true, show: false)
            defer { tabs.close(tab.id) }
            let page = try await load(tab)
            let window = hisWindow(page: page)
            defer { window.close() }
            var field: NSTextField?, terminal: (DeckTerminalView, Bytes, DeckTerminalSlot)?
            if hisPlace == "text field" {
                let made = NSTextField(string: "")
                made.frame = NSRect(x: 10, y: 450, width: 300, height: 22)
                window.contentView?.addSubview(made)
                XCTAssertTrue(window.makeFirstResponder(made))
                field = made
            } else {
                let made = makeTerminal(in: window, frame: NSRect(x: 0, y: 0, width: 480, height: 400))
                XCTAssertTrue(window.makeFirstResponder(made.0))
                terminal = made
            }
            run.ownTabID = tab.id
            let engine = BrowserDriverEngine(host: run)
            let keys = AppKeys(deliverTo: window)
            defer { keys.stop() }
            let typing = Task { (await self.step(engine, ["verb": "type", "selector": "#t", "value": Self.text]))["error"].map { "\($0)" } }
            var mine = ""
            for index in 0..<40 {
                let letter = String("asad"[String.Index(utf16Offset: index % 4, in: "asad")])
                type(letter, into: window)
                mine += letter
                await Task.yield()
                try await Task.sleep(for: .milliseconds(2))
            }
            let refusal = await typing.value
            XCTAssertNil(refusal, "\(hisPlace): \(refusal ?? "")")
            await drain(page)
            XCTAssertEqual(keys.seen, [], "\(hisPlace): no key of the tool's reached the app")
            if let field { XCTAssertEqual(field.stringValue, mine, "every key he typed landed in his field, and only those") }
            if let terminal { XCTAssertEqual(terminal.1.text, mine, "every key he typed reached his session, and only those") }
            let pageText = await js(page, "t.value") as? String
            XCTAssertEqual(pageText, Self.text, "\(hisPlace): the page received exactly the tool's text, none of his")
        }
    }

    /// The page's own script focusing a field (autofocus, a tool's focus-and-select) never takes his keyboard; his own
    /// click in the page still does.
    func testAPageNeverTakesTheKeyboardButHisClickGivesItToThePage() async throws {
        let tab = NativeBrowserTabs.shared.create(isolated: true, show: false)
        defer { NativeBrowserTabs.shared.close(tab.id) }
        let page = try await load(tab)
        let window = hisWindow(page: page)
        defer { window.close() }
        let (terminalView, bytes, _) = makeTerminal(in: window, frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        for script in ["i.focus()", "t.focus(); t.select()", "c.focus()", "window.focus(); b.focus()"] {
            _ = await js(page, script)
            await drain(page)
            XCTAssertTrue(window.firstResponder === terminalView, "the page's \(script) left his keyboard in his session")
        }
        type("ls", into: window)
        XCTAssertEqual(bytes.text, "ls", "what he types next still lands in his session")
        // His own click in the page (the event AppKit is delivering) gives the page the keyboard.
        let location = page.convert(NSPoint(x: 20, y: page.bounds.height - 10), to: nil)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        // As AppKit's own loop does: the event comes off the queue (it becomes the current event), then is sent.
        NSApp.postEvent(click, atStart: true)
        let delivered = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(), inMode: .default, dequeue: true))
        // His window hands the click it is delivering to the view under it (the scratch window is not really key in a
        // test run, so AppKit would treat it as an activating click; this is the step his key window takes).
        XCTAssertTrue(NSApp.currentEvent === delivered)
        page.mouseDown(with: delivered)
        XCTAssertTrue(window.firstResponder === page, "his click in the page gives it the keyboard")
        // A tool's synthetic click never does.
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        _ = runtime().click(tab.id, cssRect: CGRect(x: 10, y: 10, width: 20, height: 20))
        await drain(page)
        XCTAssertTrue(window.firstResponder === terminalView, "a tool's click left his keyboard in his session")
    }

    // MARK: Asad's (a): his typing reaches only the session he is in

    func testHisTypingReachesOnlyTheSessionHeIsIn() async throws {
        let window = hisWindow(page: nil)
        defer { window.close() }
        let a = makeTerminal(in: window, frame: NSRect(x: 0, y: 0, width: 490, height: 400))
        let b = makeTerminal(in: window, frame: NSRect(x: 510, y: 0, width: 490, height: 400))
        func round(into focused: (DeckTerminalView, Bytes, DeckTerminalSlot), other: (DeckTerminalView, Bytes, DeckTerminalSlot), _ label: String) {
            let before = focused.1.text
            XCTAssertTrue(window.makeFirstResponder(focused.0))
            type("h", into: window); type("i", into: window)
            for _ in 0..<5 { type("x", into: window, repeat: true) }           // a held key
            focused.0.insertText(" dictated", replacementRange: NSRange(location: NSNotFound, length: 0))   // dictation's way in
            focused.0.insertText(" pasted", replacementRange: NSRange(location: NSNotFound, length: 0))     // a paste's text
            // A late dictation callback still naming the other session, and a paste aimed at it, are refused.
            other.0.insertText(" late", replacementRange: NSRange(location: NSNotFound, length: 0))
            other.0.setMarkedText("か", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            other.0.paste(self)
            XCTAssertEqual(focused.1.text, before + "hixxxxx dictated pasted", "\(label): the focused session got everything he typed")
        }
        // Side by side, A focused.
        round(into: a, other: b, "side by side, A")
        XCTAssertEqual(b.1.bytes.count, 0, "B received 0 bytes while he typed in A")
        // He switches to B: nothing typed before the switch shows up there, and A gets nothing more.
        round(into: b, other: a, "side by side, B")
        XCTAssertEqual(b.1.text, "hixxxxx dictated pasted", "B has only what he typed in B")
        XCTAssertEqual(a.1.text, "hixxxxx dictated pasted", "A kept only what he typed in A")
        // A hidden (a warm screen he switched away from) while B is shown and focused.
        a.2.setActive(false)
        XCTAssertFalse(a.0.acceptsUserInput)
        round(into: b, other: a, "A hidden, B")
        XCTAssertEqual(a.1.text, "hixxxxx dictated pasted", "the hidden session received 0 bytes")
        // Back to A: B's text never shows up in A.
        a.2.setActive(true)
        b.2.setActive(false)
        round(into: a, other: b, "B hidden, A")
        XCTAssertEqual(a.1.text, "hixxxxx dictated pastedhixxxxx dictated pasted")
        XCTAssertEqual(b.1.text, "hixxxxx dictated pastedhixxxxx dictated pasted", "B got nothing while hidden")
    }

    // MARK: Asad's (b): each session's text box keeps its own text

    @MainActor @Observable final class TwoBoxes {
        var showingA = true
        var a = HootComposerDraft()
        var b = HootComposerDraft()
    }
    private struct Boxes: View {
        @Bindable var boxes: TwoBoxes
        var body: some View {
            ZStack {
                HootComposer(draft: $boxes.a, ownerID: "session-A", microphoneAvailable: false, onSend: { _ in }, onStop: {})
                    .opacity(boxes.showingA ? 1 : 0).environment(\.nativeScreenActive, boxes.showingA)
                HootComposer(draft: $boxes.b, ownerID: "session-B", microphoneAvailable: false, onSend: { _ in }, onStop: {})
                    .opacity(boxes.showingA ? 0 : 1).environment(\.nativeScreenActive, !boxes.showingA)
            }.frame(width: 680, height: 300)
        }
    }
    @MainActor @Observable final class OneBox {
        var owner = "session-A"
        var drafts = ["session-A": HootComposerDraft(), "session-B": HootComposerDraft()]
    }
    /// One box reused for whichever session is chosen (its draft and owner swap underneath it).
    private struct SharedBox: View {
        @Bindable var box: OneBox
        var body: some View {
            HootComposer(draft: Binding(get: { box.drafts[box.owner] ?? HootComposerDraft() }, set: { box.drafts[box.owner] = $0 }),
                         ownerID: box.owner, microphoneAvailable: false, onSend: { _ in }, onStop: {})
                .frame(width: 680, height: 300).environment(\.nativeScreenActive, true)
        }
    }
    private func settle(_ host: NSView) {
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }
    private func editors(_ view: NSView) -> [HootComposerTextView] {
        (view as? HootComposerTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }

    func testEachSessionsTextBoxKeepsItsOwnText() throws {
        for composing in [false, true] {
            let boxes = TwoBoxes()
            let window = HisWindow(contentRect: NSRect(x: -21_000, y: -21_000, width: 680, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: Boxes(boxes: boxes))
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            settle(host)
            let found = editors(host)
            XCTAssertEqual(found.count, 2)
            guard found.count == 2 else { return }
            let (boxA, boxB) = (found[0], found[1])
            XCTAssertTrue(window.makeFirstResponder(boxA))
            type("h", into: window); type("i", into: window)
            if composing { boxA.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            // He switches to B.
            boxes.showingA = false
            settle(host)
            if window.firstResponder !== boxB { XCTAssertTrue(window.makeFirstResponder(boxB)) }
            settle(host)
            XCTAssertEqual(boxes.b.text, "", "composing \(composing): B's box is empty")
            XCTAssertEqual(boxB.string, "", "composing \(composing): nothing of A's shows in B's box")
            XCTAssertFalse(boxB.hasMarkedText())
            type("y", into: window)
            XCTAssertEqual(boxes.b.text, "y")
            // Back to A: A's text is still there, B's is not.
            boxes.showingA = true
            settle(host)
            XCTAssertTrue(boxes.a.text.hasPrefix("hi"), "composing \(composing): A's text is still in A (\(boxes.a.text))")
            XCTAssertFalse(boxes.a.text.contains("y"))
            XCTAssertEqual(boxes.b.text, "y")
        }

        // One box whose session changes underneath it, mid-composition.
        let box = OneBox()
        let window = HisWindow(contentRect: NSRect(x: -22_000, y: -22_000, width: 680, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SharedBox(box: box))
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let editor = try XCTUnwrap(editors(host).first)
        XCTAssertTrue(window.makeFirstResponder(editor))
        type("h", into: window); type("i", into: window)
        editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        box.owner = "session-B"
        settle(host)
        // The box is rebuilt per session (`.id(ownerID)`): A's editor, with its half-finished character, leaves the
        // window and can take no more keys; B's is a new, empty one.
        let shownB = try XCTUnwrap(editors(host).first)
        XCTAssertNil(editor.window, "A's editor is out of the window")
        XCTAssertEqual(box.drafts["session-B"]?.text, "", "the next session's box starts empty")
        XCTAssertEqual(shownB.string, "", "nothing of A's, not even the half-finished character, shows in B")
        XCTAssertFalse(shownB.hasMarkedText())
        editor.insertText("late", replacementRange: NSRange(location: NSNotFound, length: 0))   // a late callback to A's old editor
        XCTAssertTrue(window.makeFirstResponder(shownB))
        type("b", into: window)
        XCTAssertEqual(box.drafts["session-B"]?.text, "b")
        box.owner = "session-A"
        settle(host)
        XCTAssertEqual(box.drafts["session-A"]?.text, "hi", "A's text is still A's, and nothing of B's")
        XCTAssertEqual(try XCTUnwrap(editors(host).first).string, "hi")
    }

    // MARK: Page questions wait in their tab without taking his window or keyboard

    static let askingPage = """
    <!doctype html><meta charset=utf-8><body style="margin:0">
    <button id=d style="width:200px;height:40px">Ask</button>
    <input id=f type=file style="width:200px">
    <a id=n href="https://typing.test/new" target="_blank" style="display:block;width:200px;height:30px">New window</a>
    <button id=w style="width:200px;height:40px" onclick="window.open('https://typing.test/opened')">Open</button>
    <input id=u style="width:200px"><input id=pw type=password style="width:200px">
    <input id=x style="width:200px"><input id=i style="width:200px"><div id=c contenteditable style="width:200px;min-height:30px"></div>
    <input id=b style="width:200px">
    <script>
    window.r = null;
    document.getElementById('d').addEventListener('click', function () {
      alert('a page alert'); var c = confirm('a page confirm'); var p = prompt('a page prompt', 'default'); window.r = [c, p];
    });
    // A sign-in form that moves the cursor to the password after three characters.
    document.getElementById('u').addEventListener('input', function () { if (this.value.length >= 3) document.getElementById('pw').focus() });
    // A field that throws away whatever is typed.
    document.getElementById('x').addEventListener('input', function () { this.value = '' });
    document.getElementById('b').addEventListener('input', function () { if (this.value.length >= 5) this.blur() });
    window.changes = {};
    ['i', 'b'].forEach(function (id) { document.getElementById(id).addEventListener('change', function () { window.changes[id] = (window.changes[id] || 0) + 1 }) });
    </script>
    """

    private func loadAsking(_ tab: NativeBrowserTab) async throws -> WKWebView {
        tab.ensurePage()
        let view = try XCTUnwrap(tab.webView)
        view.loadHTMLString(Self.askingPage, baseURL: URL(string: "https://typing.test/"))
        for _ in 0..<300 {
            if await js(view, "document.readyState === 'complete' && !!document.getElementById('b')") as? Bool == true { return view }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("the scratch page did not load"); return view
    }

    /// His click in the page, as AppKit's own loop delivers it (see testAPageNeverTakesTheKeyboardButHisClickGivesItToThePage).
    private func hisClick(on page: WKWebView, in window: NSWindow) throws {
        let location = page.convert(NSPoint(x: 400, y: page.bounds.height - 10), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 7, clickCount: 1, pressure: 1))
        NSApp.postEvent(down, atStart: true)
        let delivered = try XCTUnwrap(NSApp.nextEvent(matching: .leftMouseDown, until: Date(), inMode: .default, dequeue: true))
        page.mouseDown(with: delivered)
    }

    /// Questions raised by a tool remain pending, with his keyboard where it was.
    func testAPagesDialogsNeverTakeHisKeyboard() async throws {
        for placement in ["beside his session", "parked off screen"] {
            let tabs = NativeBrowserTabs.shared, run = runtime()
            let tab = tabs.create(isolated: true, show: false)
            defer { tabs.close(tab.id) }
            let page = try await loadAsking(tab)
            let window = hisWindow(page: placement == "beside his session" ? page : nil)
            defer { window.close() }
            let (terminalView, bytes, _) = makeTerminal(in: window, frame: NSRect(x: 0, y: 0, width: 480, height: 400))
            XCTAssertTrue(window.makeFirstResponder(terminalView))
            run.ownTabID = tab.id
            let answer = await step(BrowserDriverEngine(host: run), ["verb": "click", "selector": "#d"])
            let waiting = String(describing: answer).lowercased()
            XCTAssertTrue(waiting.contains("waiting for the person"), "\(answer)")
            XCTAssertEqual(tab.pageRequests.questions.first?.kind, "alert")
            XCTAssertNil(window.attachedSheet)
            XCTAssertTrue(window.firstResponder === terminalView)
            XCTAssertEqual(bytes.bytes.count, 0)
        }
    }

    // MARK: Late questions also wait; starting another tool never cancels them

    /// Late questions from a never-shown page still need the person.
    func testANeverShownPagesLateQuestionIsHeldAndReported() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let page = try await loadAsking(tab)
        _ = await js(page, "setTimeout(function () { alert('Saved!') }, 0)")
        for _ in 0..<300 where tab.pageRequests.questions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(tab.pageRequests.questions.first?.kind, "alert")
        XCTAssertTrue(tab.automation.dialogs.isEmpty)
        XCTAssertEqual(run.takePageNotes(tab.id).last?["answer"] as? String, "waiting for the person")
        XCTAssertFalse(tab.shownToPerson)
    }

    /// A subsequent tool reports waiting and leaves the original question alone.
    func testAToolStartingToDriveDoesNotCancelAHeldQuestion() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let page = try await loadAsking(tab)
        let window = hisWindow(page: page)
        defer { window.close() }
        let (terminalView, _, _) = makeTerminal(in: window, frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        _ = await js(page, "setTimeout(function () { confirm('his question') }, 0)")
        for _ in 0..<300 where tab.pageRequests.questions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        run.ownTabID = tab.id
        let started = ProcessInfo.processInfo.systemUptime
        let answer = await step(BrowserDriverEngine(host: run), ["verb": "click", "selector": "#u"])
        XCTAssertTrue(String(describing: answer).lowercased().contains("waiting for the person"))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 10)
        XCTAssertEqual(tab.pageRequests.questions.first?.kind, "confirm")
        XCTAssertTrue(tab.automation.dialogs.isEmpty)
        XCTAssertNil(window.attachedSheet)
        XCTAssertTrue(window.firstResponder === terminalView)
    }

    /// A tool's file-field click waits quietly for the person to review the chooser.
    func testAToolsClickNeverOpensTheFileChooser() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let page = try await loadAsking(tab)
        let window = hisWindow(page: page)
        defer { window.close() }
        let (terminalView, _, _) = makeTerminal(in: window, frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        run.ownTabID = tab.id
        let answer = await step(BrowserDriverEngine(host: run), ["verb": "click", "selector": "#f"])
        XCTAssertTrue(String(describing: answer).lowercased().contains("waiting for the person"), "\(answer)")
        XCTAssertNil(window.attachedSheet, "no chooser over his window")
        XCTAssertTrue(window.firstResponder === terminalView)
    }

    /// 3. A new window opened by a tool's click (target=_blank, window.open) becomes a background tab: not selected, not
    /// shown, never focusing an address bar; his view and keyboard stay.
    func testAToolsNewWindowOpensInTheBackground() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let page = try await loadAsking(tab)
        let window = hisWindow(page: page)
        defer { window.close() }
        let (terminalView, _, _) = makeTerminal(in: window, frame: NSRect(x: 0, y: 0, width: 480, height: 400))
        XCTAssertTrue(window.makeFirstResponder(terminalView))
        let previousSelect = tabs.onSelect
        var shown: [String] = []
        tabs.onSelect = { shown.append($0) }
        defer { tabs.onSelect = previousSelect }
        let selectedBefore = tabs.selectedID
        let before = Set(tabs.tabs.map(\.id))
        run.ownTabID = tab.id
        let engine = BrowserDriverEngine(host: run)
        for selector in ["#n", "#w"] {
            let answer = await step(engine, ["verb": "click", "selector": selector])
            XCTAssertNil(answer["error"], "\(selector): \(answer)")
        }
        await drain(page)
        let opened = tabs.tabs.filter { !before.contains($0.id) }
        defer { for made in opened { tabs.close(made.id) } }
        XCTAssertEqual(opened.count, 2, "each new window became a tab")
        XCTAssertTrue(opened.allSatisfy(\.openedByPage), "made for the page's own window request (no address-bar focus when it appears)")
        XCTAssertEqual(shown, [], "nothing asked his window to show a tab")
        XCTAssertEqual(tabs.selectedID, selectedBefore, "his chosen tab did not change")
        XCTAssertTrue(window.firstResponder === terminalView, "his keyboard stayed in his session")
        XCTAssertTrue(opened.allSatisfy { $0.automation.toolDriving }, "the tool drives the tabs its click opened")
    }

    /// 4 and 5: the typing fixes, in a real page.
    func testTypingStopsAtASecretFieldAndHoldsWhatWasSent() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let page = try await loadAsking(tab)
        run.ownTabID = tab.id
        let engine = BrowserDriverEngine(host: run)

        // 4. The page moves the cursor from the name to the password after three characters: typing stops there.
        var answer = await step(engine, ["verb": "type", "selector": "#u", "value": "abcdef"])
        XCTAssertTrue((answer["error"] as? String ?? "").contains("secret field"), "\(answer)")
        let fields = await js(page, "[u.value, pw.value]") as? [String]
        XCTAssertEqual(fields, ["abc", ""], "nothing of the AI's text reached the password field")

        // 5. A field that throws away what is typed: the step says so, with what it holds, instead of a silent success.
        answer = await step(engine, ["verb": "type", "selector": "#x", "value": "abc"])
        XCTAssertTrue((answer["error"] as? String ?? "").contains("did not go into"), "\(answer)")

        // 5a. The browser's insert command fails on the focused field: "1234" still ends as "1234", not "4".
        _ = try await page.evaluateJavaScript("window.__keep = Document.prototype.execCommand; Document.prototype.execCommand = function () { return false }; 1",
                                              in: nil, contentWorld: .defaultClient)
        answer = await step(engine, ["verb": "type", "selector": "#i", "value": "1234"])
        XCTAssertNil(answer["error"], "\(answer)")
        let digits = await js(page, "i.value") as? String
        XCTAssertEqual(digits, "1234")

        // 5b. A rich editor that inserts the character itself and answers false: each character once, not twice.
        _ = try await page.evaluateJavaScript("""
            Document.prototype.execCommand = function (command, ui, value) {
              var at = document.activeElement;
              if (command === 'insertText' && at && at.isContentEditable) { at.appendChild(document.createTextNode(value)); return false }
              return window.__keep.call(this, command, ui, value);
            }; 1
            """, in: nil, contentWorld: .defaultClient)
        answer = await step(engine, ["verb": "type", "selector": "#c", "value": "hello"])
        XCTAssertNil(answer["error"], "\(answer)")
        let rich = await js(page, "c.textContent") as? String
        XCTAssertEqual(rich, "hello", "every character once")
        _ = try await page.evaluateJavaScript("Document.prototype.execCommand = window.__keep; 1", in: nil, contentWorld: .defaultClient)

        // 5c. "change" as a person's typing gets it: a self-blurring field when it is left, a field on Enter.
        answer = await step(engine, ["verb": "type", "selector": "#b", "value": "abcdefghij"])
        XCTAssertNil(answer["error"], "\(answer)")
        answer = await step(engine, ["verb": "type", "selector": "#i", "value": "5678"])
        XCTAssertNil(answer["error"], "\(answer)")
        answer = await step(engine, ["verb": "press", "selector": "#i", "key": "Enter"])
        XCTAssertNil(answer["error"], "\(answer)")
        let changes = await js(page, "[b.value, i.value, window.changes.b || 0, window.changes.i || 0]") as? [Any]
        XCTAssertEqual(changes?[0] as? String, "abcdefghij")
        XCTAssertEqual(changes?[1] as? String, "5678")
        XCTAssertGreaterThanOrEqual(changes?[2] as? Int ?? 0, 1, "the self-blurring field fired change")
        XCTAssertGreaterThanOrEqual(changes?[3] as? Int ?? 0, 1, "Enter committed the typed field with change")
    }

    // MARK: MAC-NEXT-15b: secret names, a pre-filled field, date and colour fields, a tool's print

    static let fieldsPage = """
    <!doctype html><meta charset=utf-8><body style="margin:0">
    <input id=pin name="userPin"><input id=otp aria-label="OTP code"><input id=iban placeholder="IBAN"><input id=tok name="api_token">
    <input id=sec name="security_code"><input id=acct placeholder="Account number">
    <input id=sp name="spinner"><input id=op placeholder="Your opinion"><input id=soc2 name="socialite_club">
    <input id=pre value="abc"><input id=d type=date><input id=col type=color><input id=tm type=time>
    <script>
    // A field that already holds the text and ignores typing.
    document.getElementById('pre').addEventListener('input', function () { this.value = 'abc' });
    window.dchanges = 0; document.getElementById('d').addEventListener('change', function () { window.dchanges++ });
    </script>
    """

    /// MAC-NEXT-15c: words that hit ordinary forms no longer block; real secret words (and a label's text) do.
    static let wordsPage = """
    <!doctype html><meta charset=utf-8><body style="margin:0">
    <input id=pc name="pincode"><input id=st name="search_token"><input id=sh placeholder="Social handle">
    <input id=loc aria-label="Pin your location"><input id=pcode name="pin_code"><input id=tk name="token">
    <input id=pin aria-label="PIN"><input id=vc placeholder="Verification code"><input id=pp name="passphrase">
    <input id=tfa name="2FA"><input id=mfa name="mfa_code"><input id=ak name="apiKey"><input id=pk placeholder="Private key">
    <input id=rc name="recovery-code"><input id=otc placeholder="One-time code"><input id=at name="access_token">
    <input id=atm aria-label="ATM PIN"><input id=ac name="auth_code"><input id=sk name="secret_key">
    <label for=lab>Security code</label><input id=lab name="field7">
    <label>Your passphrase <input id=wrap name="field8"></label>
    """

    func testSecretWordsBlockRealSecretsOnly() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        tab.ensurePage()
        let page = try XCTUnwrap(tab.webView)
        page.loadHTMLString(Self.wordsPage, baseURL: URL(string: "https://typing.test/"))
        for _ in 0..<300 {
            if await js(page, "document.readyState === 'complete' && !!document.getElementById('wrap')") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        run.ownTabID = tab.id
        let engine = BrowserDriverEngine(host: run)
        // Ordinary fields (a postal pin code, a search token, a social handle, a map pin) type normally.
        for id in ["pc", "st", "sh", "loc", "pcode", "tk"] {
            let answer = await step(engine, ["verb": "type", "selector": "#\(id)", "value": "hello"])
            XCTAssertNil(answer["error"], "#\(id) is an ordinary field: \(answer)")
        }
        // Real secrets, by name, placeholder, aria-label, <label for> and a wrapping <label>: refused, nothing typed.
        for id in ["pin", "vc", "pp", "tfa", "mfa", "ak", "pk", "rc", "otc", "at", "atm", "ac", "sk", "lab", "wrap"] {
            let answer = await step(engine, ["verb": "type", "selector": "#\(id)", "value": "1234"])
            XCTAssertNotNil(answer["error"], "#\(id) is a secret field: \(answer)")
            let value = await js(page, "document.getElementById('\(id)').value") as? String
            XCTAssertEqual(value, "", "#\(id) got nothing")
        }
    }

    func testSecretNamesPrefilledFieldsDatesAndAToolsPrint() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        tab.ensurePage()
        let page = try XCTUnwrap(tab.webView)
        page.loadHTMLString(Self.fieldsPage, baseURL: URL(string: "https://typing.test/"))
        for _ in 0..<300 {
            if await js(page, "document.readyState === 'complete' && !!document.getElementById('tm')") as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        run.ownTabID = tab.id
        let engine = BrowserDriverEngine(host: run)
        // Secret by their words: refused, nothing typed.
        for id in ["pin", "otp", "iban", "tok", "sec", "acct"] {
            let answer = await step(engine, ["verb": "type", "selector": "#\(id)", "value": "1234"])
            XCTAssertNotNil(answer["error"], "#\(id) is a secret field: \(answer)")
            let value = await js(page, "document.getElementById('\(id)').value") as? String
            XCTAssertEqual(value, "", "#\(id) got nothing")
        }
        // Words, not letters: spinner, opinion and socialite are ordinary fields.
        for id in ["sp", "op", "soc2"] {
            let answer = await step(engine, ["verb": "type", "selector": "#\(id)", "value": "hello"])
            XCTAssertNil(answer["error"], "#\(id) is not secret: \(answer)")
        }
        // A field that already held the text and ignored the typing never passes.
        var answer = await step(engine, ["verb": "type", "selector": "#pre", "value": "abc"])
        XCTAssertTrue((answer["error"] as? String ?? "").contains("did not go into"), "\(answer)")
        // Date, colour and time take their whole value at once, with change.
        for (id, value, expected) in [("d", "2026-11-14", "2026-11-14"), ("col", "#F5D76E", "#f5d76e"), ("tm", "14:30", "14:30")] {
            answer = await step(engine, ["verb": "type", "selector": "#\(id)", "value": value])
            XCTAssertNil(answer["error"], "#\(id): \(answer)")
            let held = await js(page, "document.getElementById('\(id)').value") as? String
            XCTAssertEqual(held, expected)
        }
        let dateChanges = await js(page, "window.dchanges") as? Int
        XCTAssertEqual(dateChanges, 1, "the date field fired change once")

    }

    /// A tool's print: a PDF file, never the print sheet on his window.
    func testAToolsPrintMakesAFileAndNoSheet() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        let page = try await loadAsking(tab)
        let window = hisWindow(page: page)
        defer { window.close() }
        let printed: NativeRPCValue
        do { printed = try await run.pageCommand(tab.id, operation: "print-file", arguments: .object([])) }
        catch { XCTFail("print-file: \(error)"); return }
        let path = try XCTUnwrap(printed["path"].string)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertTrue(bytes.starts(with: Array("%PDF".utf8)), "a PDF file was written")
        XCTAssertNil(window.attachedSheet, "no print sheet on his window")
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: 8: a phone's typing never touches his Mac clipboard

    /// MAC-NEXT-15b: when Apple's Simulator app would copy the simulator's pasteboard to his Mac, a TOOL's text that
    /// needs that pasteboard is refused in words before anything is copied; his clipboard is never read or written.
    func testAToolsPhoneTypingNeverGoesThroughAPasteboardHisMacSees() async throws {
        let platform = BackendAppDevicePlatform(environment: ["PATH": "/usr/bin:/bin"], home: NSTemporaryDirectory())
        let phone = BackendAppDeviceOwnIOS(id: "ios:00000000-0000-0000-0000-000000000000", platform: platform,
                                           engine: BackendAppDeviceEngine(helper: nil, dataFolder: nil), input: BackendAppDeviceDirectInput())
        BackendSimulatorPasteboard.syncOverride = true
        defer { BackendSimulatorPasteboard.syncOverride = nil }
        let before = NSPasteboard.general.changeCount
        // MAC-NEXT-15c: refused by DEFAULT; nothing marks this call (any route other than his own panel typing).
        do {
            try await phone.type("مرحبا é 😀")
            XCTFail("unmarked non-US text must be refused while Simulator syncs the pasteboard")
        } catch {
            XCTAssertEqual(error.localizedDescription, BackendSimulatorPasteboard.toolRefusal)
        }
        XCTAssertEqual(NSPasteboard.general.changeCount, before, "his clipboard was not written")
        // His own panel typing is marked as his and goes on to the simulator's pasteboard path (this test phone does
        // not exist, so that path fails on the device; what matters is that it is not the refusal).
        do {
            try await BackendSimulatorPasteboard.$typingForPerson.withValue(true) { try await phone.type("مرحبا") }
        } catch {
            XCTAssertNotEqual(error.localizedDescription, BackendSimulatorPasteboard.toolRefusal, "his own panel typing is never refused")
        }
        // The panel's channel marks typing as his only when it comes from the app's own window.
        XCTAssertTrue(BackendAppDeviceChannels.fromHisPanel(NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)))
        XCTAssertFalse(BackendAppDeviceChannels.fromHisPanel(NativeRPCContext(caller: .internalEngine, ownerID: BackendCompositionRoot.appOwnerID)))
        XCTAssertFalse(BackendAppDeviceChannels.fromHisPanel(NativeRPCContext(caller: .pairedDevice, ownerID: "phone")))
        let reaches = await BackendAppDeviceOwnIOS.pasteboardReachesTheMac()
        XCTAssertTrue(reaches)
        BackendSimulatorPasteboard.syncOverride = false
        let off = await BackendAppDeviceOwnIOS.pasteboardReachesTheMac()
        XCTAssertFalse(off, "with Simulator's sync off the pasteboard path is safe (his clipboard cannot be reached)")
    }

    // MARK: 9: the app's own session-switch keyboard restore

    /// DeckTerminalSlot.restoreKeyboard: the keyboard goes only to the selected terminal of the key window; a session in
    /// another window, or one he switched away from, never gets it; a field he is typing in keeps it.
    func testSessionSwitchGivesTheKeyboardOnlyToTheSelectedTerminalInTheKeyWindow() throws {
        let window = hisWindow(page: nil)
        defer { window.close() }
        let other = NSWindow(contentRect: NSRect(x: -23_000, y: -23_000, width: 500, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        defer { other.close() }
        func slot(_ selected: Bool, in host: NSWindow, x: CGFloat) -> DeckTerminalSlot {
            let view = DeckTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            let made = DeckTerminalSlot(container: DeckTerminalContainer(terminal: view), active: true, focus: selected)
            made.frame = NSRect(x: x, y: 0, width: 300, height: 300)
            host.contentView?.addSubview(made)
            return made
        }
        func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let a = slot(true, in: window, x: 0), b = slot(false, in: window, x: 320), c = slot(true, in: other, x: 0)
        spin()
        func terminal(_ s: DeckTerminalSlot) -> DeckTerminalView? { s.container?.terminal }
        XCTAssertTrue(window.firstResponder === terminal(a), "the selected session of his key window has the keyboard")
        XCTAssertFalse(other.firstResponder === terminal(c), "a session in a window that is not key never takes it")
        // He switches to B.
        a.show(try XCTUnwrap(a.container), focus: false)
        b.show(try XCTUnwrap(b.container), focus: true)
        spin()
        XCTAssertTrue(window.firstResponder === terminal(b), "the session he switched to has it")
        DeckTerminalSlot.restoreFocus(in: window)
        spin()
        XCTAssertTrue(window.firstResponder === terminal(b), "a restore never hands it back to the session he left")
        DeckTerminalSlot.restoreFocus(in: other)
        spin()
        XCTAssertFalse(other.firstResponder === terminal(c))
        // A field he is typing in keeps his keyboard through a restore.
        let field = NSTextField(string: "")
        field.frame = NSRect(x: 650, y: 450, width: 200, height: 22)
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        DeckTerminalSlot.restoreFocus(in: window)
        spin()
        XCTAssertTrue(field.currentEditor() != nil && window.firstResponder === field.currentEditor(), "his field kept the keyboard")
    }
}
