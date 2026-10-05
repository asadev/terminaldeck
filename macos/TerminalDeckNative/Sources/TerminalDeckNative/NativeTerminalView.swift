import AppKit
import SwiftUI
@preconcurrency import SwiftTerm
import TerminalDeckNativeCore

/// The SwiftTerm view a native session draws in, with the parts the web
/// terminal has that SwiftTerm leaves to its host: the session's chords, paste
/// through the app's rules, files dropped from Finder typed as paths, copy on
/// select, and a frozen state once the session has ended.
@MainActor
final class DeckTerminalView: TerminalView {
    /// Who handles what this view cannot do alone (paste, drop, focus).
    weak var host: NativeTerminalSession?
    /// Selecting copies, as General → Copy on select says.
    var copyOnSelect = false
    /// The session has ended: no keystroke goes anywhere, and the caret is gone.
    private(set) var frozen = false

    init(frame: CGRect, font: NSFont) {
        super.init(frame: frame, font: font, options: TerminalOptions(cursorStyle: .blinkBlock, scrollback: 10_000))
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL, .string])
    }

    func freeze(_ on: Bool) {
        guard on != frozen else { return }
        frozen = on
        if on {
            // Hide the caret: a blinking cursor over a dead composer says the keyboard is still connected.
            feed(text: "\u{1b}[?25l")
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
    }

    // MARK: Focus

    override func mouseDown(with event: NSEvent) {
        if !frozen, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { host?.viewDidAppearInWindow() }
    }

    // MARK: Chords

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags
        guard let chord = TerminalChord.from(key: key, command: flags.contains(.command), shift: flags.contains(.shift),
                                             option: flags.contains(.option), control: flags.contains(.control)) else {
            return super.performKeyEquivalent(with: event)
        }
        run(chord)
        return true
    }

    func run(_ chord: TerminalChord) {
        switch chord {
        case .find: findPanel(.showFindPanel)
        case .findNext: findPanel(.next)
        case .findPrevious: findPanel(.previous)
        case .clear: clearScrollback()
        case .copy: copySelection()
        case .paste: paste(self)
        case .selectAll: selectAll(self)
        }
    }

    private func findPanel(_ action: NSFindPanelAction) {
        let item = NSMenuItem()
        item.tag = Int(action.rawValue)
        performFindPanelAction(item)
    }

    /// Put the selection on the clipboard, if there is one — never an empty string,
    /// which would wipe whatever was copied somewhere else.
    func copySelection() {
        guard selection.active else { return }
        let text = selection.getSelectedText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    override func copy(_ sender: Any) {
        copySelection()
    }

    override func paste(_ sender: Any) {
        guard !frozen else { return }
        host?.paste(from: .general)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if copyOnSelect { copySelection() }
    }

    // MARK: Dropping files and text (NSDraggingDestination)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(sender)
    }

    private func dropOperation(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !frozen else { return [] }
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(.URL) || types.contains(.string) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !frozen, let host else { return false }
        let handled = host.drop(from: sender.draggingPasteboard)
        if handled { window?.makeFirstResponder(self) }
        return handled
    }
}

/// The terminal with the pane's padding around it, painted in the terminal's own
/// ground so a pinned scheme has no frame of the app's grey round it.
@MainActor
final class DeckTerminalContainer: NSView {
    let terminal: DeckTerminalView
    /// `.terminal-host`'s padding: 12 above and below, 16 at the sides.
    static let inset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

    init(terminal: DeckTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(terminal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var ground: NSColor = .black {
        didSet { layer?.backgroundColor = ground.cgColor }
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let inset = Self.inset
        let frame = NSRect(x: inset.left, y: inset.top,
                           width: max(0, bounds.width - inset.left - inset.right),
                           height: max(0, bounds.height - inset.top - inset.bottom))
        if terminal.frame != frame { terminal.frame = frame }
        if window != nil { terminal.host?.layoutSettled() }
    }

    override func mouseDown(with event: NSEvent) {
        // A click on the padding focuses the terminal too.
        if !terminal.frozen { window?.makeFirstResponder(terminal) }
    }
}

/// Puts a session's (long-lived) terminal into the SwiftUI screen.
struct NativeTerminalHost: NSViewRepresentable {
    let session: NativeTerminalSession

    func makeNSView(context: Context) -> DeckTerminalContainer {
        session.container
    }

    func updateNSView(_ nsView: DeckTerminalContainer, context: Context) {}

    static func dismantleNSView(_ nsView: DeckTerminalContainer, coordinator: ()) {
        // The terminal lives on with its session (and keeps receiving output), so
        // coming back to it shows it as it was — as the web keeps a hidden one mounted.
    }
}
