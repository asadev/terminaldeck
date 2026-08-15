/**
 * One session's terminal, and the two directions it moves data in.
 *
 * SwiftTerm gives a `TerminalView` — a UIKit view holding a real VT100/xterm
 * emulator, its scrollback, its selection and its keyboard accessory. This class
 * owns one and does nothing else: bytes from the wire go in through `feed`,
 * keystrokes come out through `onInput`, and a layout change comes out through
 * `onResize`.
 *
 * ## Why the view is owned here and not by SwiftUI
 *
 * A `UIViewRepresentable` may have `makeUIView` called again — on a device
 * rotation that changes the size class, when the navigation stack rebuilds the
 * destination, when the model publishes. A terminal recreated at any of those
 * moments loses its scrollback and its cursor position, which looks exactly like
 * the connection having dropped. Holding the view outside the SwiftUI graph and
 * handing the same instance back every time is what makes the scrollback
 * survive; it is the same reason the desktop keeps its xterm instances outside
 * React's tree.
 *
 * ## The reset
 *
 * `clear()` sends RIS (ESC c), a full terminal reset, rather than clearing the
 * screen. Re-attaching to a session gets the whole scrollback again in `replay`
 * frames, and appending that under whatever was already on screen would show
 * every line twice.
 *
 * ## The two surfaces under the terminal
 *
 * The terminal owns both of them, which is the point rather than an accident of
 * where the code went. `KeyboardAccessory` is its `inputAccessoryView` and
 * `KeyGridView` is its `inputView`, so pressing a key in either one is a touch
 * *inside* the terminal — and a selection made with a long press survives being
 * acted on. A control anywhere else does not: SwiftTerm clears its selection on
 * a touch outside itself, which is how this app lost a "Copy Selection" item
 * from the navigation bar. Opening the grid therefore swaps one input view for
 * the other at the same height, and the terminal neither moves nor stops being
 * first responder.
 */

import SwiftTerm
import UIKit

// `@preconcurrency` sits on the conformance, not on the import.
// `TerminalViewDelegate` carries no actor annotations, and this class is
// `@MainActor` because everything it touches — a UIView, the model, the socket —
// is. SwiftTerm calls the delegate from the main thread only; the attribute
// states that rather than dropping the isolation to satisfy the checker.
// Without it this is a warning today and an error in Swift 6 language mode.
@MainActor
final class TerminalBridge: NSObject, @preconcurrency TerminalViewDelegate {

    let view: DeckTerminalView

    /// Bytes the user typed, already UTF-8 decoded. The caller chunks and sends.
    var onInput: ((String) -> Void)?
    /// The terminal measured itself. Fires on every layout, including the first.
    var onResize: ((Int, Int) -> Void)?
    /// The session set its own title through OSC 0/2.
    var onTitle: ((String) -> Void)?

    private(set) var size: TerminalSize?

    private let accessory: KeyboardAccessory
    private let grid: KeyGridView
    private var gestures: TerminalGestures?
    private var keyboardObservers: [NSObjectProtocol] = []

    override init() {
        // A fixed monospaced face rather than the system default: the terminal
        // measures its column count from the advance width, and a font whose
        // metrics change with the user's Dynamic Type setting would change the
        // session's column count when they change their text size.
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view = DeckTerminalView(frame: .zero, font: font)
        // Any width will do for either: a `UIInputView` with `allowsSelfSizing`
        // is laid out by the keyboard system against the real screen, and
        // `UIScreen.main` is both deprecated and wrong on a Mac or a second
        // display.
        accessory = KeyboardAccessory(width: KeyPlan.narrowestPhoneWidth)
        grid = KeyGridView(width: KeyPlan.narrowestPhoneWidth)
        super.init()

        view.terminalDelegate = self
        view.backgroundColor = Palette.terminalBackground
        view.nativeBackgroundColor = Palette.terminalBackground
        view.nativeForegroundColor = Palette.terminalForeground
        view.caretColor = Palette.caret
        // Nothing here is a shell running locally, so there is no bell worth
        // ringing on a phone in someone's pocket.
        view.bellStyle = .none
        view.optionAsMetaKey = true
        // Set on the UIKit view rather than through a SwiftUI modifier, because
        // the modifier would apply to the representable's wrapper and a
        // long-press has to land on the terminal itself — which is what starts
        // the text selection, and therefore the only way a UI test can exercise
        // copying a *selection* rather than the screen.
        view.accessibilityIdentifier = "terminal.view"

        // SwiftTerm builds its own accessory in `init`; this replaces it. See
        // `KeyboardAccessory` for why, and for why arming a modifier there works
        // through the terminal view rather than through the accessory.
        wireKeys()
        view.inputAccessoryView = accessory

        // One finger scrolls, a long press selects. See `TerminalGestures` for
        // what that costs and which of SwiftTerm's own recognisers it displaces.
        let gestures = TerminalGestures(terminal: view)
        gestures.onTapped = { [weak self] in
            // Tapping into the terminal means "I want to type", so a grid
            // standing where the keyboard should be is the wrong answer to it.
            self?.closeGrid()
        }
        self.gestures = gestures

        watchTheKeyboard()
    }

    deinit {
        // Block-based observers outlive their object: NotificationCenter holds
        // one until it is handed back, so a session-per-bridge app would
        // accumulate one dead observer per terminal ever opened.
        for token in keyboardObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// The bar, the grid, and the single place a key press turns into an effect.
    private func wireKeys() {
        accessory.applicationCursor = { [weak self] in
            self?.view.getTerminal().applicationCursor ?? false
        }
        accessory.onBytes = { [weak self] bytes in
            self?.view.send(bytes)
        }
        accessory.onModifier = { [weak self] modifier, armed in
            guard let self else { return }
            switch modifier {
            case .control: view.controlModifier = armed
            case .meta: view.metaModifier = armed
            }
            // The grid draws `alt` and the bar draws `ctrl`; both are the same
            // kind of state and neither may show it while the other does not.
            grid.armed = accessory.armed
        }
        accessory.onCopy = { [weak self] in self?.onCopy?() }
        accessory.onPaste = { [weak self] in self?.onPaste?() }
        accessory.onDismiss = { [weak self] in
            // The grid goes with the keyboard. Dismiss means "give me the screen
            // back", and leaving a grid standing would answer half of that.
            self?.closeGrid()
            self?.blur()
        }
        accessory.onMore = { [weak self] in self?.toggleGrid() }
        // The grid hands its presses back to the bar rather than interpreting
        // them: `copy` in the grid and `copy` on the bar have to be the same
        // act, and a second switch statement is how they stop being.
        grid.onKey = { [weak self] cap in
            guard let self else { return }
            accessory.press(cap)
            grid.armed = accessory.armed
        }
    }

    // MARK: - The grid

    /**
     * Swap the keyboard for the grid, or the grid back for the keyboard.
     *
     * Setting `inputView` and reloading is the whole mechanism, and it is chosen
     * for something more important than the animation: the terminal **stays**
     * first responder, so a selection made with a long press is still there when
     * the grid's `copy` is pressed. Every alternative — a sheet, an overlay, a
     * view pushed up from the bottom — is a touch outside the terminal, and a
     * touch outside the terminal is what destroys a selection here.
     */
    private func toggleGrid() {
        if view.inputView == nil { openGrid() } else { closeGrid() }
    }

    private func openGrid() {
        grid.preferredHeight = keyboardHeight
        grid.armed = accessory.armed
        view.inputView = grid
        accessory.isGridOpen = true
        // The keyboard has to be up for there to be anything to replace. With a
        // hardware keyboard attached the bar is on screen without one, and this
        // is what puts the grid in front of somebody who pressed the button.
        if !view.isFirstResponder { view.becomeFirstResponder() }
        view.reloadInputViews()
    }

    private func closeGrid() {
        guard view.inputView != nil else { return }
        view.inputView = nil
        accessory.isGridOpen = false
        view.reloadInputViews()
    }

    /**
     * How tall the keyboard was, so the grid can be exactly that tall.
     *
     * Measured rather than assumed. There is no constant for it: the keyboard is
     * a different height on every screen size, in landscape, with a third-party
     * keyboard, and with predictive text on or off. The accessory's own height
     * comes off the top because the notification's frame includes it — the bar
     * is part of the keyboard as far as UIKit is concerned — and it stays on
     * screen either way, so counting it twice would push the terminal up by 52
     * points every time the grid opened.
     */
    private var keyboardHeight: CGFloat = KeyGridView.fallbackHeight

    private func watchTheKeyboard() {
        for name in [UIResponder.keyboardDidShowNotification,
                     UIResponder.keyboardDidChangeFrameNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        guard let self,
                              let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
                        else { return }
                        let height = frame.height - KeyboardAccessory.height
                        // A keyboard shorter than the bar above it is a frame
                        // arriving mid-dismissal, not a measurement.
                        guard height > 100 else { return }
                        self.keyboardHeight = height
                    }
                }
            keyboardObservers.append(token)
        }
    }

    /// Raised by the accessory row. Handled by the model, which owns the
    /// pasteboard and the wire, rather than here.
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?

    /// What the user has selected with a long press, or nil when nothing is.
    func selectedText() -> String? {
        view.getSelection()
    }

    /**
     * Drop the selection.
     *
     * Called after a copy, and it is not cosmetic. SwiftTerm keeps a selection
     * alive across new output, so a selection made once and never cleared means
     * every later Copy silently returns the *old* text instead of the screen the
     * user is now looking at — a button that worked the first time and then
     * quietly lied. Clearing also takes the blue handles off the terminal, which
     * is the only visible confirmation that the copy happened at all.
     */
    func clearSelection() {
        view.selectNone()
    }

    /**
     * Paste, the way a terminal pastes.
     *
     * Four things happen here that do not happen when text is simply typed, and
     * every one of them is a bug this app had:
     *
     *  1. **Bracketed paste.** If the program on the far end asked for it —
     *     DECSET 2004, which zsh, bash's readline, and every coding CLI worth
     *     using set — the text is wrapped in `ESC[200~` … `ESC[201~`. Without it
     *     a multi-line paste is indistinguishable from someone typing very fast,
     *     so the first newline **submits the prompt** and the remaining lines
     *     are run as commands. That is the exact hazard `composeSend`/`oneLine`
     *     exist to prevent on the desktop, arriving through a different door.
     *  2. **Newlines become carriage returns.** A terminal's Enter is CR, not
     *     LF; sending LF into a line editor produces a literal newline in the
     *     buffer on some programs and nothing at all on others.
     *  3. **ESC and the C1 range are removed.** A paste is text, not a control
     *     channel, and an escape sequence in a clipboard is how a copied web page
     *     repaints, retitles or re-colours somebody's terminal.
     *  4. **`ESC[201~` inside the text is removed by (3).** Left in, it would
     *     close the bracket early and hand the rest of the paste to the shell as
     *     keystrokes — which is the whole attack bracketed paste defends against,
     *     reintroduced by the code implementing it.
     *
     * The mode is read off *this* terminal's emulator, which has been fed the
     * same byte stream as the Mac's, so it is the far end's real state rather
     * than a guess. Termux's `TerminalEmulator.paste` does exactly this on the
     * Android side; the two clients hand the agent identical bytes.
     */
    func paste(_ text: String) {
        let cleaned = Self.pasteable(text)
        guard !cleaned.isEmpty else { return }
        let bracketed = view.getTerminal().bracketedPasteMode
        if bracketed { view.send(data: EscapeSequences.bracketedPasteStart[0...]) }
        view.send(txt: cleaned)
        if bracketed { view.send(data: EscapeSequences.bracketedPasteEnd[0...]) }
    }

    /**
     * A clipboard string, made safe to type into a terminal.
     *
     * Split out from `paste` and made `static` so it can be tested without a
     * simulator — it is the half of pasting that is a pure function, and it is
     * the half that has the bugs in it.
     */
    static func pasteable(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var index = text.unicodeScalars.startIndex
        let scalars = text.unicodeScalars
        while index < scalars.endIndex {
            let scalar = scalars[index]
            switch scalar.value {
            // CRLF collapses to one CR rather than becoming two Enters.
            case 0x0d:
                out.append("\r")
                let next = scalars.index(after: index)
                index = next < scalars.endIndex && scalars[next].value == 0x0a ? scalars.index(after: next) : next
                continue
            case 0x0a:
                out.append("\r")
            // Tab survives: it is a character people paste on purpose, and the
            // remote line editor is entitled to treat it as completion.
            case 0x09:
                out.append(scalar)
            // Everything else in C0, DEL, and the whole C1 range. U+009B is CSI
            // in eight-bit form, which is an escape sequence without an ESC.
            case 0x00 ... 0x1f, 0x7f ... 0x9f:
                break
            default:
                out.append(scalar)
            }
            index = scalars.index(after: index)
        }
        return String(out)
    }

    /**
     * The visible screen as text.
     *
     * What Copy falls back to when nothing is selected, because selecting text
     * with a fingertip on a phone is genuinely hard and "copy what I am looking
     * at" is what people mean nine times out of ten. Trailing blank lines are
     * dropped: a terminal is 24 rows whether or not anything is on them, and
     * pasting fourteen empty lines into a message is its own bug report.
     */
    func visibleText() -> String {
        let terminal = view.getTerminal()
        let dimensions = terminal.getDims()
        let top = terminal.getTopVisibleRow()
        var lines: [String] = []
        for row in 0 ..< dimensions.rows {
            let text = terminal.getText(start: Position(col: 0, row: top + row),
                                        end: Position(col: dimensions.cols - 1, row: top + row))
            lines.append(text)
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    func feed(_ text: String) {
        view.feed(text: text)
    }

    /// RIS. See the header for why this is a reset and not a clear.
    func clear() {
        view.feed(text: "\u{1b}c")
    }

    /// Show a line the desktop did not send — a connection banner, an error.
    /// Dim and bracketed so it cannot be mistaken for program output.
    func note(_ text: String) {
        view.feed(text: "\r\n\u{1b}[2m[\(text)]\u{1b}[0m\r\n")
    }

    var isFocused: Bool { view.isFirstResponder }

    /// Whether the key grid is standing where the keyboard was. Read by the
    /// tests; nothing in the app asks, because the two controls that change it
    /// both go through this object.
    var isKeyGridOpen: Bool { view.inputView != nil }

    @discardableResult
    func focus() -> Bool { view.becomeFirstResponder() }

    /// Putting the keyboard away takes the grid with it, whichever control asked
    /// — the bar's dismiss button and the toolbar's keyboard toggle are the same
    /// intent, and one of them leaving a grid behind would be a surface with
    /// nothing underneath it.
    @discardableResult
    func blur() -> Bool {
        closeGrid()
        return view.resignFirstResponder()
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Lossy on purpose. A key sequence is always well-formed UTF-8; a paste
        // arriving through the keyboard could in principle not be, and refusing
        // to send anything at all would lose the whole paste rather than one
        // character of it.
        onInput?(String(decoding: data, as: UTF8.self))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        size = TerminalSize(cols: newCols, rows: newRows)
        onResize?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // The desktop already sends `cwd` on the session row; OSC 7 from inside
        // the session would be a second, unsynchronised source for the same
        // string.
    }

    func scrolled(source: TerminalView, position: Double) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // Only http(s). A terminal is a channel a remote process writes to, and
        // handing an arbitrary scheme from it straight to the OS is how a link
        // in some build output becomes an app launch nobody asked for.
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        UIApplication.shared.open(url)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
