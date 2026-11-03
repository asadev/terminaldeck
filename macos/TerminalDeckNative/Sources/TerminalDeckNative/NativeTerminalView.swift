import AppKit
import SwiftUI
@preconcurrency import SwiftTerm
import TerminalDeckNativeCore

/// The SwiftTerm view a native session draws in, with the parts the web
/// terminal has that SwiftTerm leaves to its host: the session's chords, paste
/// through the app's rules, files dropped from Finder typed as paths, copy on
/// select, and a frozen state once the session has ended.
@MainActor
class DeckTerminalView: TerminalView {
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

    /// The scheme's caret and the colour of the text under it, while the session is live.
    var liveCaret: (colour: NSColor, text: NSColor?) = (.controlAccentColor, nil) {
        didSet { if !frozen { showCaret() } }
    }

    /// Frozen: the caret goes (a blinking cursor over a dead composer says the
    /// keyboard is still connected) and the keyboard is let go. A session on
    /// another machine can come back with its link, so this is reversible.
    func freeze(_ on: Bool) {
        guard on != frozen else { return }
        frozen = on
        if on {
            caretColor = .clear
            caretTextColor = nil
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        } else {
            showCaret()
        }
    }

    private func showCaret() {
        caretColor = liveCaret.colour
        caretTextColor = liveCaret.text
    }

    // MARK: The caret stays in the view tree (PERF, round 7)

    /// SwiftTerm shows and hides the caret by adding and removing its caret view.
    /// Agents such as Claude Code hide the cursor at the start of every frame they
    /// draw and show it again at the end, so that was two view-tree changes per
    /// frame, and every one told the SwiftUI window around this terminal that its
    /// layout was stale: the whole window (sidebar, session bar, chips) was measured
    /// again 20–60 times a second while an agent worked, on the main thread that
    /// also draws the terminal and handles typing. The caret is hidden in place
    /// instead; SwiftTerm still adds it the first time and after any removal of its
    /// own (cursor scrolled out of view), and `didAddSubview` shows it again then.
    private func isCaret(_ view: NSView) -> Bool { String(describing: type(of: view)) == "CaretView" }
    private var caretInTree: NSView? { subviews.first(where: isCaret) }

    override func hideCursor(source: Terminal) {
        if isUsingMetalRenderer { super.hideCursor(source: source); return }
        if let caret = caretInTree { caret.isHidden = true; return }
        super.hideCursor(source: source)
    }

    override func showCursor(source: Terminal) {
        if isUsingMetalRenderer { super.showCursor(source: source); return }
        if let caret = caretInTree { caret.isHidden = false; return }
        super.showCursor(source: source)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // SwiftTerm only adds the caret when the cursor is meant to show.
        if isCaret(subview), !isUsingMetalRenderer { subview.isHidden = false }
        // #54: SwiftTerm's own scroll bar is a loose NSScroller that always draws its track: a thin line down the
        // terminal's right edge, right against the phone panel. Like a Mac overlay scroll bar it now shows only
        // while scrolling. Alpha, not isHidden: SwiftTerm keeps the bar's width out of the columns either way.
        if let scroller = subview as? NSScroller { scroller.alphaValue = 0 }
    }

    // MARK: Focus

    override func mouseDown(with event: NSEvent) {
        if !frozen, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { NativeScrollbars.attach(to: self) }
        if window != nil { host?.viewDidAppearInWindow() }
        // Into a window: its tab is the selected one there, so it shows the session (28 Oct, `reconsider`).
        host?.windowChanged()
    }

    // MARK: Chords

    /// Control chords come through here too (AppKit offers ⌃ keys as key equivalents
    /// first), so ⌃F, ⌃⇧K and ⌃⇧C are taken before the program sees them, as on the page.
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

    func makeNSView(context: Context) -> DeckTerminalSlot {
        DeckTerminalSlot(container: session.container)
    }

    func updateNSView(_ nsView: DeckTerminalSlot, context: Context) {}

    static func dismantleNSView(_ nsView: DeckTerminalSlot, coordinator: ()) {
        // The terminal lives on with its session (and keeps receiving output), so
        // coming back to it shows it as it was — as the web keeps a hidden one mounted.
    }
}

/// Where a screen shows a session's terminal. SwiftUI owns this slot, never the terminal: a screen taken down removes
/// its own view, and the one terminal of the session (shown wherever the session is on show) must not go with it
/// (28 Oct: a session moved into a split beside a browser came out blank). A slot in a window takes the terminal; a slot
/// leaving its window with it hands it to the slot that shows that session now.
@MainActor
final class DeckTerminalSlot: NSView {
    private(set) weak var container: DeckTerminalContainer?
    private static let slots = NSHashTable<DeckTerminalSlot>.weakObjects()

    init(container: DeckTerminalContainer) {
        self.container = container
        super.init(frame: .zero)
        Self.slots.add(self)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let container else { return }
        if window != nil {
            take()
        } else if container.superview === self {
            Self.slots.allObjects.last { $0 !== self && $0.container === container && $0.window != nil }?.take()
        }
    }

    private func take() {
        guard let container, container.superview !== self else { return }
        let focused = container.window?.firstResponder === container.terminal
        container.frame = bounds
        container.autoresizingMask = [.width, .height]
        addSubview(container)
        if focused { window?.makeFirstResponder(container.terminal) }
    }
}
