import AppKit
import SwiftUI
import TerminalDeckNativeCore

// MARK: - Paste with no text box to type in

/// The popup's paste door (use-file-drop.ts `onPaste` on the whole popup): a file or a
/// picture on the clipboard is attached to the task. It sits right after the window in
/// the responder chain while the popup is up, so anything that types takes a paste first;
/// with nothing to type in, Edit ▸ Paste (⌘V) reaches it.
@MainActor
final class TaskPasteDoor: NSResponder, NSMenuItemValidation, NativeSessionInputProtected {
    let inputRule = NativeSessionInputRule()
    var acceptsWindowInput: (() -> Bool)?
    var attach: (@MainActor ([URL]) -> Void)?
    var board: NSPasteboard = .general

    @objc func paste(_ sender: Any?) {
        guard inputRule.acceptsFocus, acceptsWindowInput?() != false,
              let files = TaskRichText.RichTextView.files(on: board), !files.isEmpty else { return }
        attach?(files)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        inputRule.acceptsFocus && acceptsWindowInput?() != false && menuItem.action == #selector(paste(_:)) && TaskRichText.RichTextView.hasFiles(on: board)
    }
}

/// Puts the paste door in place while the popup is on screen, and takes it out after.
/// A one-line box (or other plain text) in the popup that is being typed in takes ⌘V
/// for text; with a file or a picture on the clipboard the web attaches it instead, so
/// that ⌘V is caught here first.
struct TaskPasteDoorHost: NSViewRepresentable {
    let attach: @MainActor ([URL]) -> Void
    @Environment(\.nativeSessionInputScope) private var scope
    @Environment(\.nativeScreenActive) private var active
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> DoorView {
        let view = DoorView()
        view.door.acceptsWindowInput = { [weak view] in view?.acceptsFileInput == true }
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DoorView, context: Context) {
        view.door.inputRule.bind(to: scope)
        view.door.inputRule.update(active: scope == nil ? active : true, enabled: enabled)
        view.door.attach = attach
    }

    static func dismantleNSView(_ view: DoorView, coordinator: ()) {
        view.door.inputRule.update(active: false, enabled: false)
        view.uninstall()
    }

    final class DoorView: NSView {
        let door = TaskPasteDoor()
        private weak var host: NSWindow?
        private var monitor: Any?

        var acceptsFileInput: Bool {
            guard door.inputRule.acceptsFocus, let host,
                  !isHiddenOrHasHiddenAncestor else { return false }
            if host.isKeyWindow { return true }
            guard let key = NSApp.keyWindow else { return false }
            return key === host || key.parent === host || key.sheetParent === host
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard let window else { return }
            host = window
            door.nextResponder = window.nextResponder
            window.nextResponder = door
            // The popup is modal over the page, as the web's dialog takes the focus:
            // whatever was being typed in underneath stops taking keys.
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let key = event
                let taken = MainActor.assumeIsolated { self?.take(key) ?? false }
                return taken ? nil : event
            }
        }

        /// ⌘V with a file or picture on the clipboard, typed in a plain box of the popup (or
        /// one of its popovers and sheets): attached, and the box gets nothing.
        func take(_ event: NSEvent) -> Bool {
            guard acceptsFileInput, let host, let window = event.window,
                  window === host || window.parent === host || window.sheetParent === host,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let editor = window.firstResponder as? NSTextView, !(editor is TaskRichText.RichTextView),
                  TaskRichText.RichTextView.hasFiles(on: door.board),
                  let files = TaskRichText.RichTextView.files(on: door.board), !files.isEmpty else { return false }
            door.attach?(files)
            return true
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard let host else { return }
            var responder: NSResponder = host
            while let next = responder.nextResponder {
                if next === door {
                    responder.nextResponder = door.nextResponder
                    break
                }
                responder = next
            }
            door.nextResponder = nil
            self.host = nil
        }
    }
}
