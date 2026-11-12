import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckNative

@MainActor final class ComposerLeak1112bPasteDoorTests: XCTestCase {
    final class ScratchWindow: NSWindow {
        var keyboardActive = true
        override var isKeyWindow: Bool { keyboardActive }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ view: NSView) {
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        }
    }

    func testActualPasteDoorRefusesRetainedHiddenAndBackgroundFilePaste() throws {
        let scope = NativeSessionInputScope()
        var attachments: [[URL]] = []
        let root = TaskPasteDoorHost(attach: { attachments.append($0) })
            .frame(width: 400, height: 180).environment(\.nativeSessionInputScope, scope)
        let host = NSHostingView(rootView: root)
        let window = ScratchWindow(contentRect: NSRect(x: -32000, y: -32000, width: 400, height: 180),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        settle(host)
        let client = try XCTUnwrap(descendants(host).compactMap { $0 as? TaskPasteDoorHost.DoorView }.first)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let file = URL(fileURLWithPath: "/scratch/composer-file-paste-fixture.txt")
        XCTAssertTrue(board.writeObjects([file as NSURL]))
        client.door.board = board
        let menu = NSMenuItem(title: "Paste", action: #selector(TaskPasteDoor.paste(_:)), keyEquivalent: "v")
        XCTAssertTrue(client.door.validateMenuItem(menu))
        client.door.paste(client)
        XCTAssertEqual(attachments, [[file]], "The visible task keeps its existing file-paste capability")
        let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
        host.addSubview(plain)
        XCTAssertTrue(window.makeFirstResponder(plain))
        let commandV = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                      timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                      characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
        XCTAssertTrue(commandV.window === window, "The fixture key event names this exact offscreen task window")
        XCTAssertTrue(client.take(commandV), "Exercise the actual command-V monitor path while the task is shown")
        XCTAssertEqual(attachments, [[file], [file]])
        scope.setActive(false)
        // No view update before this stale responder callback: live scope checks first.
        client.door.paste(client)
        XCTAssertFalse(client.take(commandV))
        XCTAssertFalse(client.door.validateMenuItem(menu))
        XCTAssertEqual(attachments.count, 2)
        settle(host)
        scope.setActive(true)
        settle(host)
        window.keyboardActive = false
        client.door.paste(client)
        XCTAssertFalse(client.take(commandV))
        XCTAssertEqual(attachments.count, 2, "The task's paste door cannot consume another window's paste")
    }
}
