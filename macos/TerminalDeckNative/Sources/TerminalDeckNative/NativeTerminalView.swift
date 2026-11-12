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
    /// Warm screens remain mounted. Being in a window does not mean this prompt is on show.
    private(set) var inputActive = true
    private let inputGate = DeckTerminalInputGate()
    private var replyDepth = 0
    private var explicitDepth = 0

    /// Use this owner instead of replacing SwiftTerm's delegate: its closed keyboard methods need the same gate.
    var eventDelegate: (any TerminalViewDelegate)? {
        get { inputGate.target }
        set { inputGate.target = newValue; super.terminalDelegate = inputGate }
    }
    fileprivate func installInputGate() {
        inputGate.view = self
        if terminalDelegate !== inputGate {
            inputGate.target = terminalDelegate
            super.terminalDelegate = inputGate
        }
    }
    fileprivate func forwardInput(_ data: ArraySlice<UInt8>, to receive: (ArraySlice<UInt8>) -> Void) {
        guard replyDepth > 0 || explicitDepth > 0 || acceptsUserInput else { return }
        receive(data)
    }
    /// Program replies use a separate SwiftTerm callback; hiding a screen must not silence its terminal protocol.
    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        installInputGate()
        replyDepth += 1
        defer { replyDepth -= 1 }
        super.send(source: source, data: data)
    }
    /// A user-approved paste/copy can finish after switching away. Its captured session remains the destination.
    func sendExplicitText(_ text: String) {
        installInputGate()
        explicitDepth += 1
        defer { explicitDepth -= 1 }
        super.send(txt: text)
    }

    func setInputActive(_ active: Bool) {
        installInputGate()
        guard inputActive != active else { return }
        inputActive = active
        if !active {
            host?.cancelPendingFocus()
            unmarkText()
            if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
    }

    /// Dictation can finish after a tab/window switch and still name the old text client.
    /// Explicit session-ID sends and terminal protocol replies do not pass through this UI gate.
    var acceptsUserInput: Bool {
        inputActive && !frozen && window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard acceptsUserInput else { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard acceptsUserInput else { return }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    init(frame: CGRect, font: NSFont) {
        super.init(frame: frame, font: font, options: TerminalOptions(cursorStyle: .blinkBlock, scrollback: 10_000))
        registerForDraggedTypes([.fileURL, .URL, .string])
        installInputGate()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL, .URL, .string])
        installInputGate()
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
        if inputActive, !frozen, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        guard inputActive else { return }
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installInputGate()
        if window != nil { NativeScrollbars.attach(to: self) }
        if window != nil { host?.viewDidAppearInWindow() }
        // Into a window: its tab is the selected one there, so it shows the session (28 Oct, `reconsider`).
        host?.windowChanged()
    }

    // MARK: Chords

    /// Control chords come through here too (AppKit offers ⌃ keys as key equivalents
    /// first), so ⌃F, ⌃⇧K and ⌃⇧C are taken before the program sees them, as on the page.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard inputActive, event.window === window else { return false }
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
        guard acceptsUserInput else { return }
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
        guard inputActive, !frozen else { return [] }
        let types = sender.draggingPasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(.URL) || types.contains(.string) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard inputActive, !frozen, let host else { return false }
        let handled = host.drop(from: sender.draggingPasteboard)
        if handled { window?.makeFirstResponder(self) }
        return handled
    }
}

/// One app-owned delegate protects even SwiftTerm methods that are not open to overriding.
@MainActor
private final class DeckTerminalInputGate: TerminalViewDelegate {
    weak var view: DeckTerminalView?
    weak var target: (any TerminalViewDelegate)?
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { view?.forwardInput(data) { target?.send(source: source, data: $0) } }
    }
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { target?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        MainActor.assumeIsolated { target?.setTerminalTitle(source: source, title: title) }
    }
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        MainActor.assumeIsolated { target?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    }
    nonisolated func scrolled(source: TerminalView, position: Double) {
        MainActor.assumeIsolated { target?.scrolled(source: source, position: position) }
    }
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        MainActor.assumeIsolated { target?.requestOpenLink(source: source, link: link, params: params) }
    }
    nonisolated func bell(source: TerminalView) { MainActor.assumeIsolated { target?.bell(source: source) } }
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        MainActor.assumeIsolated { target?.clipboardCopy(source: source, content: content) }
    }
    nonisolated func clipboardRead(source: TerminalView) -> Data? {
        MainActor.assumeIsolated { target?.clipboardRead(source: source) }
    }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { target?.iTermContent(source: source, content: content) }
    }
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        MainActor.assumeIsolated { target?.rangeChanged(source: source, startY: startY, endY: endY) }
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
        if terminal.inputActive, !terminal.frozen { window?.makeFirstResponder(terminal) }
    }
}

/// Puts a session's long-lived terminal into the selected, uncovered SwiftUI screen.
struct NativeTerminalHost: NSViewRepresentable {
    @Environment(\.nativeScreenActive) private var onShow
    @Environment(\.pageWindow) private var pageWindow
    @Environment(\.nativeTerminalSelected) private var layoutSelected
    let container: DeckTerminalContainer

    init(session: NativeTerminalSession) { container = session.container }
    init(container: DeckTerminalContainer) { self.container = container }

    private var selected: Bool {
        if let layoutSelected { return layoutSelected }
        guard let session = container.terminal.host else { return true }
        return pageWindow != nil || AppModel.shared.currentScreen?.id == session.sessionId
    }

    func makeNSView(context: Context) -> DeckTerminalSlot {
        DeckTerminalSlot(container: container, active: onShow, focus: selected)
    }

    func updateNSView(_ nsView: DeckTerminalSlot, context: Context) {
        // A split leaf keeps its AppKit identity when its session changes. Visibility and
        // owner must change together, so a hidden leaf never briefly takes the new terminal.
        nsView.show(container, active: onShow, focus: selected)
    }

    static func dismantleNSView(_ nsView: DeckTerminalSlot, coordinator: ()) {
        nsView.setActive(false)
    }
}

/// SwiftUI owns a slot, while the session owns its terminal. A terminal can have several
/// interested slots, but exactly one may attach it. Only a selected, uncovered slot may
/// ask for the keyboard, and that request survives joining a window or a sheet closing.
@MainActor
final class DeckTerminalSlot: NSView {
    private(set) weak var container: DeckTerminalContainer?
    private static let slots = NSHashTable<DeckTerminalSlot>.weakObjects()
    private(set) var active: Bool
    private(set) var selected: Bool
    private var wantsKeyboard = false
    private var hadKeyboardBeforeRemoval = false
    private var observers: [NSObjectProtocol] = []
    private var scheduledFocus: DispatchWorkItem?

    init(container: DeckTerminalContainer, active: Bool = true, focus: Bool = true) {
        self.container = container
        self.active = active
        selected = focus
        wantsKeyboard = active && focus
        super.init(frame: .zero)
        Self.slots.add(self)
        if !active, container.superview == nil { container.terminal.setInputActive(false) }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification,
                     NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let notifiedWindow = (note.object as? NSWindow).map(ObjectIdentifier.init)
                let notificationName = note.name
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          notifiedWindow == ObjectIdentifier(window) || notificationName == NSApplication.didBecomeActiveNotification else { return }
                    if self.active && self.selected && window.isKeyWindow {
                        self.take(requestKeyboard: true)
                    } else { self.restoreKeyboard() }
                }
            })
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
    isolated deinit {
        scheduledFocus?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
    override var isFlipped: Bool { true }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let container, container.superview === self {
            hadKeyboardBeforeRemoval = window?.firstResponder === container.terminal
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if active { take(requestKeyboard: selected) }
        } else {
            releaseContainer(restoreKeyboard: hadKeyboardBeforeRemoval)
            hadKeyboardBeforeRemoval = false
        }
    }

    override func layout() {
        super.layout()
        restoreKeyboard()
    }

    func setActive(_ next: Bool, focus: Bool = true) {
        guard let container else { return }
        show(container, active: next, focus: focus)
    }

    /// Retains the release line's rebinding, with the same gate as visibility changes.
    func show(_ next: DeckTerminalContainer, active nextActive: Bool? = nil, focus: Bool? = nil) {
        let newActive = nextActive ?? active
        let newSelected = focus ?? selected
        let changedOwner = container !== next
        let lostSelection = selected && !newSelected
        let becameAvailable = newActive && (!active || newSelected && !selected || changedOwner)
        if changedOwner { releaseContainer(restoreKeyboard: true) }
        container = next
        active = newActive
        selected = newSelected
        if !active {
            wantsKeyboard = false
            releaseContainer(restoreKeyboard: true)
        } else if window != nil {
            take(requestKeyboard: selected && becameAvailable)
        } else if becameAvailable && selected {
            wantsKeyboard = true
        }
        if !selected {
            wantsKeyboard = false
            if lostSelection, next.superview === self, window?.firstResponder === next.terminal {
                window?.makeFirstResponder(nil)
                if let window { Self.restoreFocus(in: window, request: false) }
            }
        }
    }

    private func releaseContainer(restoreKeyboard: Bool) {
        scheduledFocus?.cancel()
        scheduledFocus = nil
        guard let container, container.superview === self else { return }
        let oldWindow = window ?? container.window
        let wasFocused = oldWindow?.firstResponder === container.terminal
        container.terminal.setInputActive(false)
        container.removeFromSuperview()
        let candidates = Self.slots.allObjects.filter {
            $0 !== self && $0.active && $0.container === container && $0.window != nil
        }
        let survivor = candidates.first { $0.selected && $0.window?.isKeyWindow == true }
            ?? candidates.first { $0.selected } ?? candidates.first
        survivor?.take(requestKeyboard: restoreKeyboard && (wasFocused || survivor?.selected == true))
        if let oldWindow { Self.restoreFocus(in: oldWindow, request: false) }
    }

    private func take(requestKeyboard: Bool) {
        guard active, let container, let window else { return }
        if let owner = container.superview as? DeckTerminalSlot, owner !== self, owner.active {
            // A background scene can be restored after the person's active window.
            // It must wait until it is key before taking that window's terminal.
            if owner.selected && !selected { return }
            if owner.window?.isKeyWindow == true && !window.isKeyWindow { return }
        }
        if requestKeyboard && selected { wantsKeyboard = true }
        if container.superview !== self {
            let oldWindow = container.window
            let focused = oldWindow?.firstResponder === container.terminal
            container.terminal.setInputActive(false)
            container.removeFromSuperview()
            container.frame = bounds
            container.autoresizingMask = [.width, .height]
            container.terminal.setInputActive(true)
            addSubview(container)
            if focused && selected { wantsKeyboard = true }
        } else {
            container.terminal.setInputActive(true)
        }
        restoreKeyboard()
        // AppKit/SwiftUI may still be attaching the window or returning focus from its
        // cover in this turn. One deferred attempt handles that ordering without polling.
        scheduledFocus?.cancel()
        let task = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.restoreKeyboard() } }
        scheduledFocus = task
        DispatchQueue.main.async(execute: task)
    }

    private func restoreKeyboard() {
        guard wantsKeyboard, active, selected, let window, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              let container, container.superview === self, !container.terminal.frozen else { return }
        let terminal = container.terminal
        if window.firstResponder === terminal { wantsKeyboard = false; return }
        if let current = window.firstResponder as? NSView {
            let staleTerminal = (current as? DeckTerminalView).map { !$0.inputActive || $0.frozen } ?? false
            let hiddenEditor = nativeSessionInputRule(for: current).map { !$0.acceptsFocus } ?? false
            if current.window !== window || current.isHiddenOrHasHiddenAncestor || staleTerminal || hiddenEditor {
                // AppKit may restore a former text client when a sheet closes. A hidden
                // client must not leave the newly selected terminal with a dead keyboard.
                window.makeFirstResponder(nil)
            } else if NativeKeyboardFocus.isTyping(current) {
                return // A different visible field still belongs to the person.
            }
        }
        guard terminal.host?.showsMoveBack != true else { return }
        if window.makeFirstResponder(terminal) { wantsKeyboard = false }
    }

    /// All programmatic focus requests use the same selection/window/sheet checks.
    static func requestFocus(for terminal: DeckTerminalView) {
        guard let slot = terminal.superview?.superview as? DeckTerminalSlot,
              slot.container?.terminal === terminal, slot.active, slot.selected else { return }
        slot.wantsKeyboard = true
        slot.restoreKeyboard()
    }

    /// A cover can relinquish its responder after the slot's visibility update.
    static func restoreFocus(in window: NSWindow, request: Bool = true) {
        for slot in slots.allObjects where slot.window === window && slot.active && slot.selected && slot.container?.superview === slot {
            if request { slot.wantsKeyboard = true }
            slot.restoreKeyboard()
        }
    }
}
