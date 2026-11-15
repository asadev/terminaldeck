import AppKit
import WebKit
import XCTest
@testable import TerminalDeckNative
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Asad, 31 Oct and 13 Nov 2026: "if I am in any other session … and any session wants to use any simulator or any
/// browser … it takes me to there … makes me stuck there waiting until it finishes". With session A chosen and the
/// person typing in A, every devices and browser tool call made for session B, for Hoot or for a window-less agent
/// leaves the chosen session, the shown page, the key window and the keyboard exactly where they were; B's phone and
/// page are attached and working; A's typed text lands in A. Scratch tabs and windows only: no engine, no real data.
@MainActor
final class BackgroundToolsStayPutTests: XCTestCase {
    private struct Place: Equatable {
        let deviceTab: String?, browserSelected: String?
        let key: ObjectIdentifier?, windows: Int
    }
    /// AppModel cannot start inside this test bundle: a tool path that reached its selectTab, select or window
    /// opening would build it and stop the run. The rest of the person's place is read here.
    private func place() -> Place {
        Place(deviceTab: NativeFIXESDeviceTabs.shared.selectedID, browserSelected: NativeBrowserTabs.shared.selectedID,
              key: NSApp.keyWindow.map(ObjectIdentifier.init), windows: NSApp.windows.filter { $0.isVisible && !($0 is NativeBrowserCaptureWindow) }.count) // a page's off-screen parking window is not his
    }

    /// The person's window: session A's terminal (a text view holding the keyboard) beside session B's page.
    private func personsWindow(showing page: WKWebView?) -> (NSWindow, NSTextView) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let terminalA = NSTextView(frame: NSRect(x: 0, y: 0, width: 450, height: 500))
        content.addSubview(terminalA)
        if let page { page.frame = NSRect(x: 450, y: 0, width: 450, height: 500); content.addSubview(page) }
        window.contentView = content
        window.orderBack(nil)
        XCTAssertTrue(window.makeFirstResponder(terminalA))
        return (window, terminalA)
    }

    private func runtime() -> NativeSafariRuntime {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("td-stay-put-\(UUID().uuidString)")
        return NativeSafariRuntime(tabs: NativeBrowserTabs.shared, bindings: BackendBrowserBindings(), dataRoot: scratch, screenshotDirectory: scratch,
                                   browserData: { _, _ in NSNull() }, authorizePopup: { _, _, _ in }, publish: { _, _ in })
    }

    func testBrowserToolsNeverMoveThePerson() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let savedSelect = tabs.onSelect
        var selected: [String] = []
        tabs.onSelect = { selected.append($0) }
        defer { tabs.onSelect = savedSelect }
        // B's page shown beside A (the split), Hoot's page and a window-less agent's page nobody shows.
        let shownB = tabs.create(isolated: true, show: false), hoot = tabs.create(isolated: true, show: false), agent = tabs.create(isolated: true, show: false)
        defer { for tab in [shownB, hoot, agent] { tabs.close(tab.id) } }
        shownB.ensurePage()
        let page = try XCTUnwrap(shownB.webView)
        let (window, terminalA) = personsWindow(showing: page)
        defer { window.close() }
        let before = place()

        for tab in [shownB, hoot, agent] {
            let ready = await run.readyForInput(tab.id)
            XCTAssertTrue(ready, "the page is ready for real input where it is")
            _ = try? await run.pageCommand(tab.id, operation: "show", arguments: .object([]))
            _ = run.click(tab.id, cssRect: CGRect(x: 10, y: 10, width: 20, height: 20))
            _ = run.hover(tab.id, cssRect: CGRect(x: 10, y: 10, width: 20, height: 20))
            // MAC-NEXT-14: never AppKit keys; the driver types at page level (TypingNeverTouchesHisKeyboardTests).
            XCTAssertFalse(run.focusForTyping(tab.id))
            XCTAssertFalse(run.type(tab.id, plan: .keys(["h", "i"])))
            XCTAssertFalse(run.type(tab.id, plan: .insert("there")))
            XCTAssertFalse(run.press(tab.id, key: BrowserKeySpec.pressable["Enter"]!))
            XCTAssertFalse(run.press(tab.id, chord: try BrowserKeyChord.parse("Shift+Tab")))
            XCTAssertTrue(window.firstResponder === terminalA, "the keyboard stayed in session A")
        }
        // A page nobody shows works in an off-screen window that is never key.
        for tab in [hoot, agent] {
            let parked = try XCTUnwrap(tab.webView?.window)
            XCTAssertTrue(parked is NativeBrowserCaptureWindow)
            XCTAssertFalse(parked.isKeyWindow)
            XCTAssertTrue(parked !== window)
        }
        XCTAssertTrue(shownB.webView?.window === window, "B's page stays where the person put it")
        XCTAssertEqual(selected, [], "no tool call chose a tab")
        XCTAssertEqual(place(), before)
        // What he types next still lands in A.
        terminalA.insertText("ls", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(terminalA.string, "ls")
    }

    func testDeviceToolsNeverMoveThePerson() async throws {
        let row: [String: Any] = ["id": "ios:00000000-0000-0000-0000-000000001313", "platform": "ios", "kind": "simulator",
                                  "state": "ready", "available": true, "name": "iPhone 17 Pro", "runtime": "iOS 27.0"]
        let value = try NativeRPCValue.fromFoundation(row)
        let devices = NativeFIXESDeviceTabs.shared
        let screenID = NativeFIXESDeviceTabs.screenID(row["id"] as! String)
        defer { devices.close(screenID) }
        let (window, terminalA) = personsWindow(showing: nil)
        defer { window.close() }
        // No live session rows: a session object is never made here, so no session service is ever reached.
        let savedSessions = NativeFIXESDeviceMenuServices.liveSessions, savedChoose = NativeFIXESDeviceMenuServices.chooseSession
        var chosen: [String] = []
        NativeFIXESDeviceMenuServices.liveSessions = { [] }
        NativeFIXESDeviceMenuServices.chooseSession = { chosen.append($0) }
        defer { NativeFIXESDeviceMenuServices.liveSessions = savedSessions; NativeFIXESDeviceMenuServices.chooseSession = savedChoose }
        let before = place()

        // simulators_open in a tab and in a window: the tab is added, never chosen; no window opens.
        try await devices.present(value, destination: "tab", sessionID: nil)
        try await devices.present(value, destination: "window", sessionID: nil)
        XCTAssertTrue(devices.has(screenID), "the device is attached in the strip")
        // devices_open_app / simulators_open beside a session that is gone, and beside Hoot (no session row): refused,
        // nothing chosen. (Beside a live session: the presenter passes choosingTheSession false; policy test.)
        for session in ["stay-put-B", "hoot"] {
            do { try await devices.present(value, destination: "beside", sessionID: session); XCTFail("no such session row") } catch {}
        }
        // A window-less agent: no presenter installed, so a refusal and nothing to move.
        do { try await BackendFIXESDevicePresenter().show(value, destination: "beside", sessionID: "stay-put-B"); XCTFail("a window-less engine shows nothing") } catch {}

        XCTAssertEqual(place(), before)
        XCTAssertTrue(window.firstResponder === terminalA)
        XCTAssertEqual(chosen, [], "no tool call chose a session")
    }

    /// Review, 13 Nov: a page handed to the person must be findable. A handover from a session, from Hoot, from a Hoot
    /// task and from a background agent each leaves a raised hand where he looks (the session's row, else Hoot's line);
    /// nothing comes forward by itself; his click opens exactly that page; the waiting AI hears when he opened it and
    /// when he finished; the mark goes when he hands it back.
    func testEveryWaitingPageHasAMarkThatOpensIt() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let savedSelect = tabs.onSelect
        var selected: [String] = []
        tabs.onSelect = { selected.append($0) }
        defer { tabs.onSelect = savedSelect }
        let fromSession = tabs.create(isolated: true, show: false), fromHoot = tabs.create(isolated: true, show: false)
        let fromHootTask = tabs.create(isolated: true, show: false), fromAgent = tabs.create(isolated: true, show: false)
        defer { for tab in [fromSession, fromHoot, fromHootTask, fromAgent] { tabs.close(tab.id) } }
        // Session B has a row; the background agent's session has none; Hoot's and its task's pages belong to no session.
        let bindings = BRBindingView(sessions: [BRBoundSession(sessionId: "stay-put-B", windows: [BRBoundWindow(n: 1, tabId: fromSession.id)]),
                                                BRBoundSession(sessionId: "agent-no-row", windows: [BRBoundWindow(n: 1, tabId: fromAgent.id)])])
        let rows: Set<String> = ["stay-put-B"]
        let (window, terminalA) = personsWindow(showing: nil)
        defer { window.close() }

        for tab in [fromSession, fromHoot, fromHootTask, fromAgent] {
            let call = Task { await run.handOver(tab.id, prompt: "Sign in, please.", windowMs: 20_000) }
            for _ in 0..<300 where tab.handoverWaiter == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(tab.handoverPrompt)
            XCTAssertEqual(selected, [], "the handed page did not come forward by itself")
            XCTAssertTrue(window.firstResponder === terminalA)
            let mark = tab === fromSession ? NativeWaitingPages.page(forSession: "stay-put-B", bindings: bindings)
                                           : NativeWaitingPages.pageForHootLine(sessionRows: rows, bindings: bindings)
            XCTAssertEqual(mark, tab.id, "a mark he can click leads to exactly this page")
            if tab !== fromSession { XCTAssertNil(NativeWaitingPages.page(forSession: "stay-put-B", bindings: bindings)) }
            // His click on the marked row.
            NativeWaitingPages.open(try XCTUnwrap(mark))
            for _ in 0..<300 where !selected.contains(tab.id) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(selected, [tab.id], "his click opened exactly that page")
            selected = []
            // The page reaches his window: the waiting AI is told at once that he opened it.
            let page = try XCTUnwrap(tab.webView)
            window.contentView?.addSubview(page)
            let opened = await call.value
            XCTAssertEqual(opened, "still-waiting")
            XCTAssertTrue(run.handoverOpened(tab.id), "the AI hears he opened it")
            // He finishes: the AI's next call hears it, and the mark goes.
            let next = Task { await run.handOver(tab.id, prompt: "Sign in, please.", windowMs: 20_000) }
            for _ in 0..<300 where tab.handoverWaiter == nil { try await Task.sleep(for: .milliseconds(10)) }
            tab.endHandover("resumed")
            let finished = await next.value
            XCTAssertEqual(finished, "resumed")
            XCTAssertNil(NativeWaitingPages.pageForHootLine(sessionRows: rows, bindings: bindings))
            XCTAssertNil(NativeWaitingPages.page(forSession: "stay-put-B", bindings: bindings))
            page.removeFromSuperview()
        }
    }

    /// MAC-NEXT-13 B1: a waiting page of a chat folded in Archived chats is carried by that group's header, not lost and
    /// not on Hoot's line; one with no row at all stays on Hoot's line.
    func testAFoldedGroupCarriesItsWaitingPage() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let archived = tabs.create(isolated: true, show: false), loose = tabs.create(isolated: true, show: false)
        defer { for tab in [archived, loose] { tabs.close(tab.id) } }
        let bindings = BRBindingView(sessions: [BRBoundSession(sessionId: "archived-chat", windows: [BRBoundWindow(n: 1, tabId: archived.id)])])
        let call = Task { await run.handOver(archived.id, prompt: "Sign in, please.", windowMs: 20_000) }
        for _ in 0..<300 where archived.handoverWaiter == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(NativeWaitingPages.page(forSessions: ["archived-chat"], bindings: bindings), archived.id)
        XCTAssertNil(NativeWaitingPages.pageForHootLine(sessionRows: ["archived-chat"], bindings: bindings))
        XCTAssertEqual(NativeWaitingPages.pageForHootLine(sessionRows: [], bindings: bindings), archived.id, "never nothing")
        XCTAssertNil(NativeWaitingPages.page(forSessions: [], bindings: bindings))
        archived.endHandover("resumed")
        _ = await call.value
        XCTAssertNil(NativeWaitingPages.page(forSessions: ["archived-chat"], bindings: bindings))
    }

    /// Review, 13 Nov: with his cursor in a plain text field (a find box, the address bar, a text field), a tool's
    /// keys into a page give the keyboard back to that FIELD with his cursor where it was; his next keys land there.
    func testTypingInAPageGivesHisTextFieldBackWithHisCursor() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        tab.ensurePage()
        let page = try XCTUnwrap(tab.webView)
        let (window, _) = personsWindow(showing: page)
        defer { window.close() }
        for field in [NSTextField(string: "hello"), NSSearchField(string: "hello"), NSTextField(string: "https://example.com")] {
            field.frame = NSRect(x: 10, y: 450, width: 200, height: 22)
            window.contentView?.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.setSelectedRange(NSRange(location: 2, length: 0))
            XCTAssertFalse(run.type(tab.id, plan: .keys(["x"])), "MAC-NEXT-14: no AppKit keys, the driver types at page level")
            XCTAssertFalse(run.press(tab.id, key: BrowserKeySpec.pressable["Enter"]!))
            let back = try XCTUnwrap(window.firstResponder as? NSTextView, "the field never lost the keyboard")
            XCTAssertTrue(back.isFieldEditor && back.delegate === field)
            XCTAssertEqual(back.selectedRange(), NSRange(location: 2, length: 0), "his cursor is where it was")
            let before = field.stringValue
            back.insertText("Z", replacementRange: back.selectedRange())
            XCTAssertEqual(back.string, String(before.prefix(2)) + "Z" + String(before.dropFirst(2)), "his next key lands in his field, at his cursor")
            field.removeFromSuperview()
        }
    }

    /// Review, 13 Nov: a page parked off screen for a tool is silent until he opens it himself.
    func testAParkedPageIsSilentUntilHeOpensIt() async throws {
        let tabs = NativeBrowserTabs.shared, run = runtime()
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        _ = await run.readyForInput(tab.id)
        let page = try XCTUnwrap(tab.webView)
        XCTAssertTrue(page.window is NativeBrowserCaptureWindow)
        let state = await page.requestMediaPlaybackState()
        XCTAssertNotEqual(state, .playing)
        XCTAssertFalse(tab.shownToPerson, "an AI's background page was never his")
        XCTAssertNotNil(run.parkIdle[tab.id], "the quiet timer runs: after 60 s with no tool call the parking window goes")
        XCTAssertEqual(NativeSafariRuntime.parkIdleSeconds, 60)
        let (window, _) = personsWindow(showing: page)
        defer { window.close() }
        XCTAssertNil(tab.automation.parkingWindow, "his window took the page; the parking window is gone")
        // B3: from now on the page is his; a tool touching it after he left it in another tab never silences it.
        XCTAssertTrue(tab.shownToPerson)
        page.removeFromSuperview()
        _ = await run.readyForInput(tab.id)
        XCTAssertFalse(NativeBackgroundToolsPolicy.silencesParkedPage(shownToPerson: tab.shownToPerson, inWindow: tab.pageInWindow))
    }
}
