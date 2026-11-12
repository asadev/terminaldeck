import AppKit
import Observation
import SwiftUI
@preconcurrency import SwiftTerm
import XCTest
@testable import TerminalDeckNative
import TerminalDeckNativeCore

/// Mounts the production server setup shell and its real server delegate. Only
/// its transport is inert; no server, app, provider, session host or hook runs.
@MainActor final class ComposerLeak1112bServerSetupTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        override var isKeyWindow: Bool { keyboardActive }
    }

    @MainActor final class ServerTransport {
        var writes: [(id: String, text: String)] = []
        var calls: [String] = []
        var handlers: [String: ([Any]) -> Void] = [:]
        var holdOpen = false
        var pendingOpen: CheckedContinuation<CodingAIJSON, Never>?
        let shellID = "inert-setup-shell"

        var transport: NativeServerShellTransport {
            .init(invoke: { [self] channel, _ in
                calls.append(channel)
                if channel == "servers:shell:open" {
                    if holdOpen {
                        return await withCheckedContinuation { pendingOpen = $0 }
                    }
                    return CodingAIJSON(["ok": true, "shellId": shellID])
                }
                return CodingAIJSON(["ok": true])
            }, send: { [self] channel, args in
                guard channel == "servers:shell:write", let id = args.first as? String,
                      args.count > 1, let text = args[1] as? String else { return }
                writes.append((id, text))
            }, subscribe: { [self] channel, receive in
                handlers[channel] = receive
                return EngineSubscription { [weak self] in self?.handlers[channel] = nil }
            })
        }

        func finishOpen() {
            holdOpen = false
            let pending = pendingOpen
            pendingOpen = nil
            pending?.resume(returning: CodingAIJSON(["ok": true, "shellId": shellID]))
        }

        func output(_ text: String) {
            handlers["servers:shell:output"]?([["shellId": shellID, "data": text]])
        }
    }

    @MainActor final class SessionInput: TerminalViewDelegate {
        var bytes = [UInt8]()
        var text: String { String(decoding: bytes, as: UTF8.self) }
        nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { bytes += data }
        }
        nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        nonisolated func scrolled(source: TerminalView, position: Double) {}
        nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    @MainActor @Observable final class CachedPages {
        var setupShown = true
        let shell: NativeServerShell
        let selectedSession: DeckTerminalContainer
        let sessionInput = SessionInput()

        init(shell: NativeServerShell) {
            self.shell = shell
            let terminal = DeckTerminalView(frame: .init(x: 0, y: 0, width: 640, height: 240),
                                            font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            terminal.eventDelegate = sessionInput
            selectedSession = DeckTerminalContainer(terminal: terminal)
        }
    }

    private struct CachedSetupAndSession: View {
        @Bindable var pages: CachedPages
        var body: some View {
            ZStack {
                // This is the actual box drawn by NativeServerSetupPanel.
                NativeServerShellBox(shell: pages.shell)
                    .opacity(pages.setupShown ? 1 : 0)
                    .environment(\.nativeScreenActive, pages.setupShown)
                NativeTerminalHost(container: pages.selectedSession)
                    .opacity(pages.setupShown ? 0 : 1)
                    .environment(\.nativeScreenActive, !pages.setupShown)
            }.frame(width: 680, height: 340)
        }
    }

    private func window(_ content: NSView) -> ScratchWindow {
        let window = ScratchWindow(contentRect: .init(x: -30000, y: -30000, width: 680, height: 340),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return window
    }

    private func settle(_ view: NSView) {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func drainTasks() async {
        for _ in 0..<8 { await Task.yield() }
    }

    private func insert(_ text: String, into terminal: TerminalView) {
        terminal.insertText(text, replacementRange: .init(location: NSNotFound, length: 0))
    }

    func testActualSetupTerminalReleasesCachedPageKeyboardAndRejectsLateShellInput() async throws {
        let transport = ServerTransport()
        let shell = NativeServerShell(serverId: "inert-server", transport: transport.transport)
        let pages = CachedPages(shell: shell)
        let host = NSHostingView(rootView: CachedSetupAndSession(pages: pages))
        let window = self.window(host)
        defer { shell.close(); window.contentView = nil; window.close() }
        settle(host)
        shell.open()
        await drainTasks()
        XCTAssertEqual(shell.shellId, transport.shellID)
        XCTAssertTrue(window.firstResponder === shell.view, "The actual setup shell initially owns the keyboard")
        insert("server sign-in", into: shell.view)
        XCTAssertEqual(transport.writes.map(\.text), ["server sign-in"])
        XCTAssertEqual(transport.writes.map(\.id), [transport.shellID])
        transport.writes = []

        pages.setupShown = false
        settle(host)
        let session = pages.selectedSession.terminal
        XCTAssertTrue(window.firstResponder === session, "Selecting a session must recover the real keyboard from server setup")
        XCTAssertFalse(window.firstResponder === shell.view)
        XCTAssertNil(shell.view.window)
        insert("late dictation", into: shell.view)
        shell.view.setMarkedText("late composition", selectedRange: .init(location: 0, length: 0),
                                 replacementRange: .init(location: NSNotFound, length: 0))
        shell.view.unmarkText()
        shell.view.paste(shell.view)
        shell.view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        shell.view.keyDown(with: key)
        XCTAssertTrue(transport.writes.isEmpty, "No late user input may reach the old server shell")
        insert("selected session only", into: session)
        XCTAssertEqual(pages.sessionInput.text, "selected session only")
        XCTAssertEqual(shell.shellId, transport.shellID, "Hiding setup must keep its running shell alive")
        XCTAssertFalse(transport.calls.contains("servers:shell:close"))
        XCTAssertEqual(transport.handlers.count, 2, "Output and exit remain subscribed while setup is hidden")

        // A program's terminal protocol is still live while the page is hidden.
        transport.output("\u{1b}[6n")
        XCTAssertFalse(transport.writes.isEmpty)
        transport.writes = []
        pages.setupShown = true
        settle(host)
        XCTAssertTrue(window.firstResponder === shell.view, "Returning to the still-running setup shell needs no click")
        insert("setup resumes", into: shell.view)
        XCTAssertEqual(transport.writes.map(\.text), ["setup resumes"])
        XCTAssertEqual(pages.sessionInput.text, "selected session only")
    }

    func testDelayedSetupOpenCannotTakeSelectedSessionsKeyboardAfterHide() async {
        let transport = ServerTransport()
        transport.holdOpen = true
        let shell = NativeServerShell(serverId: "inert-server", transport: transport.transport)
        let pages = CachedPages(shell: shell)
        let host = NSHostingView(rootView: CachedSetupAndSession(pages: pages))
        let window = self.window(host)
        defer { transport.finishOpen(); shell.close(); window.contentView = nil; window.close() }
        settle(host)
        shell.open()
        await drainTasks()
        XCTAssertNotNil(transport.pendingOpen)
        XCTAssertTrue(window.firstResponder === shell.view)

        pages.setupShown = false
        settle(host)
        XCTAssertTrue(window.firstResponder === pages.selectedSession.terminal)
        transport.finishOpen()
        await drainTasks()
        settle(host)
        XCTAssertEqual(shell.shellId, transport.shellID)
        XCTAssertTrue(window.firstResponder === pages.selectedSession.terminal,
                      "The real server-open completion must use the slot's hidden-screen guard")
        insert("late setup insertion", into: shell.view)
        insert("session after setup opened", into: pages.selectedSession.terminal)
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(pages.sessionInput.text, "session after setup opened")
        XCTAssertFalse(transport.calls.contains("servers:shell:close"))
    }

    func testActualSetupPasteKeepsBracketedModeButRejectsHiddenAndUnfocusedTargets() async throws {
        let transport = ServerTransport()
        let shell = NativeServerShell(serverId: "inert-server", transport: transport.transport)
        let pages = CachedPages(shell: shell)
        let host = NSHostingView(rootView: CachedSetupAndSession(pages: pages))
        let window = self.window(host)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); shell.close(); window.contentView = nil; window.close() }
        settle(host)
        shell.open()
        await drainTasks()
        let terminal = try XCTUnwrap(shell.view as? NativeServerShellTerminal)
        terminal.feed(text: "\u{1b}[?2004h")
        XCTAssertTrue(terminal.getTerminal().bracketedPasteMode)
        XCTAssertTrue(board.setString("setup\npaste", forType: .string))
        XCTAssertTrue(window.firstResponder === terminal)
        XCTAssertTrue(terminal.paste(from: board))
        XCTAssertEqual(transport.writes.map(\.text), ["\u{1b}[200~setup\rpaste\u{1b}[201~"])
        transport.writes = []

        pages.setupShown = false
        settle(host)
        XCTAssertTrue(window.firstResponder === pages.selectedSession.terminal)
        XCTAssertFalse(terminal.paste(from: board))
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertFalse(transport.calls.contains("servers:shell:close"))
    }

    /// A drop from Finder arrives while Finder is in front: the shown setup shell takes it without the
    /// keyboard or an active window; a hidden setup page refuses it.
    func testSetupShellTakesADropWithoutTheKeyboardAndRefusesItWhileHidden() async throws {
        let transport = ServerTransport()
        let shell = NativeServerShell(serverId: "inert-server", transport: transport.transport)
        let pages = CachedPages(shell: shell)
        let host = NSHostingView(rootView: CachedSetupAndSession(pages: pages))
        let window = self.window(host)
        let board = ComposerLeak1112bDropSweepTests.textBoard("dropped path")
        defer { board.releaseGlobally(); shell.close(); window.contentView = nil; window.close() }
        settle(host)
        shell.open()
        await drainTasks()
        let terminal = try XCTUnwrap(shell.view as? NativeServerShellTerminal)
        window.keyboardActive = false
        window.makeFirstResponder(nil)
        XCTAssertTrue(ComposerLeak1112bDropSweepTests.drop(board, on: terminal, in: window), "The shown shell takes the drop")
        XCTAssertEqual(transport.writes.map(\.text), ["dropped path"])
        transport.writes = []

        pages.setupShown = false
        settle(host)
        XCTAssertFalse(ComposerLeak1112bDropSweepTests.drop(board, on: terminal, in: window), "A hidden setup shell refuses it")
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertTrue(pages.sessionInput.bytes.isEmpty, "Nothing reaches the shown session either")
    }

    func testSetupOpenCompletionPreservesAnotherVisibleField() async {
        let transport = ServerTransport()
        transport.holdOpen = true
        let shell = NativeServerShell(serverId: "inert-server", transport: transport.transport)
        let host = NSHostingView(rootView: NativeServerShellBox(shell: shell).frame(width: 680, height: 300))
        let root = NSView(frame: .init(x: 0, y: 0, width: 680, height: 340))
        host.frame = root.bounds
        root.addSubview(host)
        let field = NSTextView(frame: .init(x: 0, y: 0, width: 220, height: 40))
        root.addSubview(field)
        let window = self.window(root)
        defer { transport.finishOpen(); shell.close(); window.contentView = nil; window.close() }
        settle(root)
        shell.open()
        await drainTasks()
        XCTAssertNotNil(transport.pendingOpen)
        XCTAssertTrue(window.makeFirstResponder(field))
        transport.finishOpen()
        await drainTasks()
        settle(root)

        XCTAssertTrue(window.firstResponder === field, "A delayed setup completion must respect another visible field")
        insert("unfocused setup", into: shell.view)
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testSetupOpenCompletionPreservesAnotherWindowsKeyboard() async {
        let transport = ServerTransport()
        transport.holdOpen = true
        let shell = NativeServerShell(serverId: "inert-server", transport: transport.transport)
        let host = NSHostingView(rootView: NativeServerShellBox(shell: shell).frame(width: 680, height: 300))
        let window = self.window(host)
        let field = NSTextView(frame: .init(x: 0, y: 0, width: 220, height: 40))
        let other = self.window(field)
        defer {
            transport.finishOpen(); shell.close()
            window.contentView = nil; other.contentView = nil
            window.close(); other.close()
        }
        settle(host)
        shell.open()
        await drainTasks()
        XCTAssertNotNil(transport.pendingOpen)
        window.keyboardActive = false
        XCTAssertTrue(other.makeFirstResponder(field))
        transport.finishOpen()
        await drainTasks()
        settle(host)

        XCTAssertTrue(other.firstResponder === field)
        insert("background setup", into: shell.view)
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(shell.shellId, transport.shellID)
    }
}
