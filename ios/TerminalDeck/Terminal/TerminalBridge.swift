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
final class TerminalBridge: NSObject, @preconcurrency TerminalViewDelegate, TerminalSearching {

    let view: DeckTerminalView

    /**
     * What SwiftUI actually lays out: the terminal, inside the view that keeps
     * its last line off the home indicator.
     *
     * Owned here rather than built in `TerminalHostView.makeUIView` for the same
     * reason the terminal is — that method may be called again at any moment
     * SwiftUI decides to rebuild the node, and a container built fresh each time
     * would start with no safe-area measurement and lay the terminal out at full
     * height for a frame before UIKit told it otherwise. `TerminalContainerView`
     * holds the argument for the inset itself.
     */
    lazy var container = TerminalContainerView(terminal: view)

    /// Bytes the user typed, already UTF-8 decoded. The caller chunks and sends.
    var onInput: ((String) -> Void)?
    /// The terminal measured itself. Fires on every layout, including the first.
    var onResize: ((Int, Int) -> Void)?
    /// The session set its own title through OSC 0/2.
    var onTitle: ((String) -> Void)?

    private(set) var size: TerminalSize?

    /// The size changed, so the screen can say what it changed to. A pinch has
    /// no other confirmation than the number — see `TerminalScreen.show`.
    var onTextSizeChanged: ((CGFloat) -> Void)?

    /// The terminal was touched. The screen uses it to put the find bar away —
    /// a tap into the terminal destroys the selection SwiftTerm was using as the
    /// match highlight, so a find bar left standing would be counting matches
    /// nobody can see any more.
    var onTapped: (() -> Void)?

    /// The point size the terminal is drawn at. Changed by pinching; see
    /// `TextSize` for why it is a phone-wide setting rather than a per-session
    /// one, and what it costs on the wire.
    private(set) var textSize: CGFloat

    private let accessory: KeyboardAccessory
    private let grid: KeyGridView
    private var gestures: TerminalGestures?
    private var keyboardObservers: [NSObjectProtocol] = []

    override init() {
        // A fixed monospaced face rather than the system default: the terminal
        // measures its column count from the advance width, and a font whose
        // metrics change with the user's Dynamic Type setting would change the
        // session's column count when they change their text size.
        //
        // The *size* is the one the person chose, read here rather than
        // defaulted, so a session opened after the choice comes up already the
        // right size instead of resizing itself a frame later — which the far
        // end would see as a second `resize` and an agent's box would repaint
        // twice for. See `TextSize`.
        textSize = TextSize.stored
        let font = UIFont.monospacedSystemFont(ofSize: textSize, weight: .regular)
        view = DeckTerminalView(frame: .zero, font: font)
        // Any width will do for either: a `UIInputView` with `allowsSelfSizing`
        // is laid out by the keyboard system against the real screen, and
        // `UIScreen.main` is both deprecated and wrong on a Mac or a second
        // display.
        accessory = KeyboardAccessory(width: KeyPlan.narrowestPhoneWidth)
        grid = KeyGridView(width: KeyPlan.narrowestPhoneWidth)
        super.init()

        view.terminalDelegate = self
        applyColors()
        /*
         * The terminal is the one view in this app that has to be *told* the
         * appearance changed. See `applyColors` for why.
         *
         * Registered here rather than inside `DeckTerminalView` because the
         * colours are this object's business and that one's is gestures, and
         * because registering from outside costs nothing: `registerForTraitChanges`
         * is a method on the view, and the view keeps the handler for its own
         * lifetime. `[weak self]` because that handler outlives nothing else —
         * a strong capture would be the bridge holding the view holding the
         * bridge, one leaked terminal per session ever opened.
         */
        view.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: DeckTerminalView, _: UITraitCollection) in
            self?.applyColors()
        }
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
            self?.onTapped?()
        }
        // Pinching is the gesture people already try on a terminal they cannot
        // read. It is two fingers, so it cannot be confused with the one-finger
        // drag that scrolls or the long press that selects.
        gestures.onPinch = { [weak self] scale in
            guard let self else { return }
            setTextSize(TextSize.scaled(pinchStart ?? textSize, by: scale))
        }
        gestures.onPinchBegan = { [weak self] in
            guard let self else { return }
            pinchStart = textSize
        }
        gestures.onPinchEnded = { [weak self] in
            guard let self else { return }
            pinchStart = nil
            TextSize.save(textSize)
        }
        self.gestures = gestures

        watchTheKeyboard()
    }

    /**
     * Paint the terminal in the appearance the view is actually in.
     *
     * Called once at construction and again on every change of the interface
     * style, and the second half is not belt and braces — it is the only reason
     * a light terminal works at all.
     *
     * Every other UIKit view in this app can be handed a `UIColor` built from a
     * `dynamicProvider` and left alone: UIKit keeps the provider and re-resolves
     * it. SwiftTerm does not keep it. `nativeForegroundColor`'s setter runs
     * `newValue.getTerminalColor()` immediately and stores the result as
     * `terminal.foregroundColor`, a 16-bit RGB struct with no notion of a trait
     * collection; `installColors` does the same to the sixteen ANSI values, and
     * the view's own `setupOptions` snapshots the background into
     * `layer.backgroundColor` as a `CGColor`. So a dynamic colour given to the
     * emulator is resolved once, at whatever appearance happened to be current
     * at that instant, and then frozen — which on a phone that starts dark and
     * is switched to light is a light-mode terminal still painting dark-mode
     * text.
     *
     * The resolution is explicit — `resolvedColor(with: view.traitCollection)` —
     * rather than left to the ambient `UITraitCollection.current`. Inside a
     * `draw(_:)` UIKit sets that for you; inside a trait-change handler it is
     * not something to rely on, and the view's own trait collection is the
     * authority either way.
     *
     * `TerminalBridgeTests` drives this with `overrideUserInterfaceStyle` and
     * reads the colour back out of the emulator, because the failure mode here
     * is silent: everything compiles, the chrome changes, and only the rectangle
     * the session is in stays the wrong colour.
     */
    private func applyColors() {
        let traits = view.traitCollection
        let paper = Palette.terminalBackground.resolvedColor(with: traits)
        view.backgroundColor = paper
        view.nativeForegroundColor = Palette.terminalForeground.resolvedColor(with: traits)
        // Set after the foreground because this setter is the one that calls
        // SwiftTerm's `colorsChanged()`, which drops the cached attribute runs
        // and repaints the whole screen. Setting them the other way round
        // repaints with the old ink and waits for the next output to correct it.
        view.nativeBackgroundColor = paper
        view.caretColor = Palette.caret.resolvedColor(with: traits)
        // A selection is blue on this platform, and this app's blue is the
        // icon's. See `Palette.selection` for what the library's default did.
        view.selectedTextBackgroundColor = Palette.selection.resolvedColor(with: traits)
        // The sixteen ANSI colours. Installed rather than left at SwiftTerm's
        // default for two reasons, both in `Ink.ansi`: the library's default is
        // Apple Terminal's set and the desktop renders xterm's, so one session
        // had two colour schemes depending on which screen it was read on; and
        // the light half has to be a different sixteen or an agent's coloured
        // output is invisible on paper.
        view.installColors(Palette.ansi(for: traits.userInterfaceStyle))
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

    /**
     * Everything the terminal is holding, screen and scrollback together.
     *
     * `visibleText()` above is what Copy falls back to and it is deliberately
     * only the screen — copying is usually "give me the thing I am looking at".
     * Sharing is the opposite question: the reason to send a session's output to
     * somebody is almost always the error that has already scrolled off the top,
     * and a share that quietly stopped at the top of the screen would be the
     * wrong half of the story every time.
     *
     * SwiftTerm's own `getBufferAsData` reads the active buffer's lines,
     * right-trimmed, in order — the real buffer rather than anything this app
     * kept a copy of. Trailing blank lines come off for the reason they come off
     * `visibleText`: a terminal is thirty-odd rows whether or not anything is on
     * them.
     */
    func scrollbackText() -> String {
        let data = view.getTerminal().getBufferAsData()
        var lines = String(decoding: data, as: UTF8.self).split(separator: "\n",
                                                                omittingEmptySubsequences: false)
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

    // MARK: - Finding text

    /**
     * `TerminalSearching`, forwarded to SwiftTerm's own search.
     *
     * Thin on purpose. The rules — which direction a keystroke searches in, what
     * the counter says, when the highlight is held — are in `FindSession`, where
     * they can be tested; this is the four calls that reach the emulator.
     */
    @discardableResult
    func findNext(_ term: String) -> Bool {
        view.findNext(term)
    }

    @discardableResult
    func findPrevious(_ term: String) -> Bool {
        view.findPrevious(term)
    }

    func matchSummary(_ term: String) -> (index: Int, total: Int) {
        view.searchMatchSummary(term, limit: FindSession.countLimit)
    }

    func clearFind() {
        view.clearSearch()
    }

    /**
     * Stop output wiping the match.
     *
     * `allowMouseReporting` decides two things inside SwiftTerm, and the second
     * is the one that matters here: whether a feed clears the selection. It
     * does, on every frame of output, and the search result *is* the selection —
     * so on a session that is printing, a match found at 12:00:01 is gone at
     * 12:00:02 and the find bar is left counting something invisible.
     *
     * Turned off only while the find bar is open, and turned back on when it
     * closes, because the same flag is how a finger drives vim and htop. Reading
     * is a mode; it ends.
     */
    func holdHighlight(_ hold: Bool) {
        view.allowMouseReporting = !hold
    }

    // MARK: - Text size

    /// Where a pinch started from, so the gesture scales the size it began with
    /// rather than compounding on itself twenty times a second.
    private var pinchStart: CGFloat?

    /**
     * Draw the terminal at a different size.
     *
     * This is a real change to the session, not a zoom: the column count comes
     * from the width divided by the advance of one character, so a smaller face
     * means more columns, and SwiftTerm reports the new size through the same
     * delegate a rotation goes through — which sends a `resize` and makes the
     * far end reflow. That is the honest behaviour and it is what makes the
     * setting worth having: at 10 point a phone in landscape reaches eighty
     * columns and stops wrapping the agent's tables.
     *
     * A no-op when the size has not changed, and that guard is load bearing:
     * setting `font` at all makes SwiftTerm soft-reset the emulator, which drops
     * application-cursor mode — so an unnecessary set would make the arrow keys
     * send the wrong bytes inside vim until the program repainted.
     */
    func setTextSize(_ size: CGFloat) {
        let clamped = TextSize.clamp(size)
        guard clamped != textSize else { return }
        textSize = clamped
        view.font = UIFont.monospacedSystemFont(ofSize: clamped, weight: .regular)
        // The pinch has no other visible confirmation than the size itself, and
        // the *number* is what tells somebody they have reached the end of the
        // range.
        onTextSizeChanged?(clamped)
    }

    /// Adopt the stored size. Called when a session appears, so a terminal
    /// created before the person changed the setting catches up.
    func applyStoredTextSize() {
        setTextSize(TextSize.stored)
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
