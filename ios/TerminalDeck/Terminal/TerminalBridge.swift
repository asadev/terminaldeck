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

    let view: TerminalView

    /// Bytes the user typed, already UTF-8 decoded. The caller chunks and sends.
    var onInput: ((String) -> Void)?
    /// The terminal measured itself. Fires on every layout, including the first.
    var onResize: ((Int, Int) -> Void)?
    /// The session set its own title through OSC 0/2.
    var onTitle: ((String) -> Void)?

    private(set) var size: TerminalSize?

    override init() {
        // A fixed monospaced face rather than the system default: the terminal
        // measures its column count from the advance width, and a font whose
        // metrics change with the user's Dynamic Type setting would change the
        // session's column count when they change their text size.
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view = TerminalView(frame: .zero, font: font)
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

        // SwiftTerm builds its own accessory in `init`; this replaces it. See
        // `KeyboardAccessory` for why, and for why arming Control there works
        // through the terminal view rather than through the accessory.
        // Any width will do: `UIInputView` with `allowsSelfSizing` is laid out
        // by the keyboard system against the real screen, and `UIScreen.main`
        // is both deprecated and wrong on a Mac or a second display.
        let accessory = KeyboardAccessory(width: 375)
        accessory.applicationCursor = { [weak self] in
            self?.view.getTerminal().applicationCursor ?? false
        }
        accessory.onBytes = { [weak self] bytes in
            self?.view.send(bytes)
        }
        accessory.onControl = { [weak self] armed in
            self?.view.controlModifier = armed
        }
        accessory.onCopy = { [weak self] in self?.onCopy?() }
        accessory.onPaste = { [weak self] in self?.onPaste?() }
        accessory.onDismiss = { [weak self] in self?.blur() }
        view.inputAccessoryView = accessory
    }

    /// Raised by the accessory row. Handled by the model, which owns the
    /// pasteboard and the wire, rather than here.
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?

    /// What the user has selected with a long press, or nil when nothing is.
    func selectedText() -> String? {
        view.getSelection()
    }

    /// Whether a selection is on screen right now. Read by the Copy button so it
    /// can say which of the two things it is about to do before it does it.
    var hasSelection: Bool { view.selectionActive }

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

    @discardableResult
    func focus() -> Bool { view.becomeFirstResponder() }

    @discardableResult
    func blur() -> Bool { view.resignFirstResponder() }

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

/// The terminal's colours. Not in an asset catalog because the terminal is
/// black in both appearances — a light-mode terminal would be a different
/// palette, not a lighter one, and inventing that here would be guessing.
enum Palette {
    static let terminalBackground = UIColor(red: 0.043, green: 0.047, blue: 0.055, alpha: 1)
    static let terminalForeground = UIColor(red: 0.878, green: 0.890, blue: 0.910, alpha: 1)
    static let caret = UIColor(red: 0.20, green: 0.62, blue: 0.95, alpha: 1)
}
