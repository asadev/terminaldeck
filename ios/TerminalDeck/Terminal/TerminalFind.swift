/**
 * Finding a line in a session's scrollback, from a phone.
 *
 * The desktop has had a search panel since the first week. The phone has had
 * nothing, and the phone is where it matters more: a laptop shows eighty
 * columns and fifty rows at once, and this shows about fifty by thirty-five, so
 * the same agent run that is one screen on a Mac is four screens of thumb
 * scrolling here. "Where did it print the port number" is the question people
 * actually open this app to answer.
 *
 * ## The search is SwiftTerm's, not ours
 *
 * `TerminalView.findNext`, `findPrevious` and `searchMatchSummary` are public
 * in 1.18 and they run against the emulator's own buffer — the real scrollback,
 * with the real line-wrapping, not a copy of the text this app happened to keep.
 * Writing a second search over `visibleText()` would have found only what is on
 * screen, which is the one place you do not need a search.
 *
 * ## The first match is the newest one
 *
 * Typing searches **backwards from the bottom**. On a terminal the interesting
 * occurrence is almost always the most recent one — the last error, the port
 * this run bound to, the file the agent just wrote — and starting at the top of
 * a five-hundred-line scrollback means paging forwards through a build log to
 * reach the thing that just happened. Terminal.app and iTerm both step backwards
 * from the bottom for the same reason.
 *
 * So `↑` walks further back and `↓` comes forwards again, which is also what the
 * two arrows look like they should do against a scrollback that grows downwards.
 * The counter stays counted from the top — "12 of 17" — because that is the
 * number that tells you where you are in the whole buffer.
 *
 * ## Two things this deliberately does not do
 *
 * **It does not highlight every match.** SwiftTerm has exactly one selection and
 * the match *is* that selection, which is what makes the system Copy callout
 * work on a result. Painting the other sixteen would need a second highlight
 * layer inside the library.
 *
 * **It does not search the alternate buffer's history, because there is none.**
 * A full-screen program — vim, htop, less — runs on the alternate buffer, which
 * by definition has no scrollback, so a search there can only match what is on
 * the screen. That is not a limitation this code can lift; it is what the
 * alternate buffer is.
 */

import Foundation
import Observation

/**
 * What a find bar needs from a terminal.
 *
 * A protocol rather than a direct reference to `TerminalBridge` so the state
 * machine below can be driven in a test without a view — and, more usefully,
 * so the same tests can drive it against a **real** bridge with real text fed
 * into it. Both happen in `FindTests`: the fake proves the state machine, the
 * real terminal proves the search actually finds the string.
 */
@MainActor
protocol TerminalSearching: AnyObject {
    /// Later in the buffer. True when something matched.
    @discardableResult
    func findNext(_ term: String) -> Bool
    /// Earlier in the buffer. True when something matched.
    @discardableResult
    func findPrevious(_ term: String) -> Bool
    /// Where the current match sits and how many there are, both counted from
    /// the top of the scrollback. `(0, 0)` when nothing matches.
    func matchSummary(_ term: String) -> (index: Int, total: Int)
    /// Drop the search and its highlight.
    func clearFind()
    /**
     * Keep a highlight alive while output is arriving.
     *
     * SwiftTerm drops the selection on every feed when mouse reporting is
     * allowed, and the match *is* the selection — so without this the highlight
     * you just found vanishes the moment the agent prints its next line, which
     * on a live session is under a second. Held only while the find bar is
     * open, and released when it closes, because mouse reporting is how a
     * finger drives vim and htop and it must come back.
     */
    func holdHighlight(_ hold: Bool)
}

/**
 * The find bar's state, and every rule about what a keystroke does.
 *
 * Kept out of the view so the rules can be tested: what happens when the term
 * is emptied, what the counter says with no matches, whether closing releases
 * the highlight hold. A `View` can express all of that and can be asked none of
 * it.
 */
@MainActor
@Observable
final class FindSession {

    /// The largest number of matches `searchMatchSummary` will count. SwiftTerm's
    /// own default, restated here because the counter has to say `1000+` rather
    /// than a wrong number when a term matches more often than that.
    static let countLimit = 1000

    private(set) var isOpen = false
    private(set) var term = ""
    /// 1-based position of the current match from the top of the scrollback, or
    /// 0 when there is no current match.
    private(set) var index = 0
    private(set) var total = 0

    /**
     * Weak, and every use below tolerates nil.
     *
     * The terminal belongs to the machine, and a machine can be unpaired while
     * this screen is on it — `HostLink.stop` drops every bridge it owns. An
     * `unowned` reference would turn that sequence into a crash the next time a
     * key was pressed in the find bar, which is a real sequence rather than an
     * impossible one.
     */
    @ObservationIgnored
    private weak var terminal: TerminalSearching?

    init(terminal: TerminalSearching) {
        self.terminal = terminal
    }

    /// Whether a term has been typed at all. The counter is drawn only past
    /// this, so an empty bar does not accuse the user of finding nothing.
    var hasTerm: Bool { !term.isEmpty }

    /// What the counter reads. One string rather than three view branches,
    /// because it is the part worth asserting in a test.
    var status: String {
        guard hasTerm else { return "" }
        guard total > 0 else { return "No matches" }
        let counted = total >= Self.countLimit ? "\(Self.countLimit)+" : "\(total)"
        return "\(index) of \(counted)"
    }

    var hasMatches: Bool { total > 0 }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        // Held from the moment the bar opens rather than from the first match:
        // a person types slowly, the session keeps printing, and a highlight
        // that only survives once you have finished typing is one that flickers
        // out under your thumb.
        terminal?.holdHighlight(true)
    }

    /**
     * The term changed.
     *
     * Every keystroke restarts the search from the bottom rather than continuing
     * from the last match. Continuing is what a desktop find bar does with a
     * stable term; with a term that is being *typed* it walks the cursor forward
     * through the buffer one character at a time, so by the time somebody has
     * typed `error` they are somewhere in the middle of the scrollback looking
     * at whichever `e` came first.
     */
    func type(_ text: String) {
        term = text
        guard !text.isEmpty else {
            index = 0
            total = 0
            terminal?.clearFind()
            return
        }
        terminal?.clearFind()
        _ = terminal?.findPrevious(text)
        recount()
    }

    /// Further back in the scrollback — older output.
    func earlier() {
        guard hasTerm else { return }
        _ = terminal?.findPrevious(term)
        recount()
    }

    /// Forwards again — newer output.
    func later() {
        guard hasTerm else { return }
        _ = terminal?.findNext(term)
        recount()
    }

    /**
     * Put the bar away.
     *
     * The term is kept. Re-opening the bar to look for the same string is the
     * common case — you found the port, you scrolled, you want it again — and
     * throwing it away would make the second search cost the same typing as the
     * first. What is dropped is the highlight and the hold, because both belong
     * to a bar that is on screen.
     */
    func close() {
        guard isOpen else { return }
        isOpen = false
        index = 0
        total = 0
        terminal?.clearFind()
        terminal?.holdHighlight(false)
    }

    private func recount() {
        let summary = terminal?.matchSummary(term) ?? (index: 0, total: 0)
        index = summary.index
        total = summary.total
    }
}
