/**
 * Find in a page, from the phone — the driver.
 *
 * The desktop has had this since the browser panel shipped: `FindBar.tsx` and
 * `find-bridge.ts`, a field, a count and two arrows over Chromium's own
 * `findInPage`. The phone had nothing, and the phone is where it matters more
 * for exactly the reason the terminal's find bar exists — see `TerminalFind`,
 * which opens with the same sentence. A dev server's admin page is four screens
 * of thumb scrolling here and one screen on a laptop, and *"where does it say
 * the port"* is a question you answer by searching or not at all.
 *
 * Asad, on the split this whole lane sits under: *"everything the Mac side
 * had."*
 *
 * ## Nothing here touches the wire
 *
 * This is the phone's own browser and this is the phone's own find. No frame, no
 * capability, no host code — `WKWebView` searches a document it already has in
 * its own process, and the Mac is not asked anything. That is the rule the
 * feature was scoped under: *"if it is not related to the folder side or server
 * side then build it, but keep it on the phone side."*
 *
 * ## **It does not inject a search, and that is the whole design**
 *
 * The obvious way to find text in a `WKWebView` is a script: walk the text
 * nodes, wrap the hits in `<mark>`, scroll to one, and unwrap them again on
 * close. Every StackOverflow answer about this says to do that. **It is wrong
 * here, and it is wrong in a way that is invisible until it has already cost
 * somebody an hour.**
 *
 * The premise of this whole screen — read `LocalhostBrowser`'s header — is that
 * the page is *really running*: a real loopback origin, so it gets real cookies,
 * service workers, and the WebSocket a dev server's hot reload rides on.
 * Rewriting the document underneath that is not a cosmetic act. React's
 * reconciler finds nodes it did not create and either throws or blows away the
 * subtree on the next render; a `MutationObserver` — which is what half the
 * live-reload and analytics code on a dev server is built out of — fires for
 * every mark; anything holding a `Node` reference across the unwrap holds a
 * detached one. A find that breaks the page it is searching is worse than no
 * find, because the person is now debugging the wrong thing.
 *
 * So this uses `WKWebView.find(_:configuration:completionHandler:)`, which is
 * WebKit's own find, runs inside the engine, and mutates nothing the document
 * can observe. It arrived in iOS 16 and this app deploys to 17 — see
 * `ios/project.yml`, where the floor is pinned and argued — so there is no
 * availability fence around any of it.
 *
 * ## What WebKit will tell us is one bit, and the bar says only that
 *
 * `WKFindResult` carries `matchFound` and nothing else. There is no ordinal and
 * no total: the count Chromium pushes to `find-bridge.ts` has no equivalent on
 * this side, and `UIFindInteraction` — which does carry `resultCount` — only
 * populates one for the system's own find navigator, which is a different bar
 * from this one.
 *
 * The tempting repair is to count the matches ourselves in JavaScript: read
 * `innerText`, count the occurrences, print a total. **That is an invented
 * number and it is refused.** A count produced by a different algorithm than
 * the one moving the highlight will disagree with it — `innerText` collapses
 * whitespace, drops hidden subtrees and joins across elements where WebKit's
 * find does not — so "3 of 11" would sit next to arrows that visit nine things,
 * and the two would be wrong in a way nobody could act on. A bar that says
 * nothing is honest; a bar that says the wrong number has lied about the one
 * fact it exists to carry.
 *
 * So {@link BrowserFindSession.status} is empty when a match was found — the
 * page itself is the answer, scrolled to and highlighted — and says
 * *"No matches"* when there is none. Two states, both true.
 *
 * ## Typing searches forwards from the top, and the terminal's does the opposite
 *
 * `FindSession` restarts every keystroke **backwards from the bottom**, because
 * on a scrollback the interesting occurrence is the most recent one. A document
 * is the other way round: it has a beginning, the beginning is where a reader
 * starts, and the first match of a term typed into a page is the first one in
 * the page. So ↓ is where the search begins and ↑ walks back towards the top.
 *
 * Both bars point their arrows the way their content runs, which is why the two
 * feel like one app despite starting in opposite directions.
 *
 * What the two share exactly is the restart: **every keystroke clears the
 * selection and searches again from the top**, rather than continuing from the
 * last match. Continuing is right for a settled term and wrong for one being
 * typed — WebKit's find always resumes from the current selection, so somebody
 * typing `header` walks the highlight down the document one letter at a time and
 * ends up wherever the first `h` was.
 *
 * ## Wrapping is on
 *
 * `WKFindConfiguration.wraps`, left at its default and stated anyway. Without it
 * the last match on a page turns ↓ into a control that does nothing, and on a
 * phone there is no status line to explain the difference between *no more
 * matches* and *this button is broken*. With wrapping, every press moves the
 * page, which is its own answer.
 *
 * ## Clearing the highlight is a selection change, not a document change
 *
 * `WKWebView` keeps the found text selected after a find — that highlight is
 * what makes the match visible — and there is no public call to take it back.
 * Leaving it is not an option: a page still wearing a blue band over a word
 * nobody is searching for any more is a claim that a search is running.
 *
 * The one line of JavaScript in this file collapses the document's selection,
 * which is precisely what a tap on the page already does. It reads no content,
 * adds no node, removes none, and changes no attribute, so it is not the
 * injection the section above refuses — the distinction is *the document* versus
 * *the selection over it*, and only the first is something the page's own code
 * can observe. It runs in `WKContentWorld.defaultClient` for the same reason
 * `InspectScript` does: in the page's own world it does not exist.
 */

import Foundation
import Observation
import WebKit

/* -------------------------------------------------------------------------- */
/* The seam                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * What a find bar needs from a page.
 *
 * A protocol rather than a `WKWebView` for the same reason `TerminalSearching`
 * is one: the rules below — what a keystroke restarts, what a stale answer is
 * allowed to overwrite, what closing releases — are worth pinning without a
 * simulator and a live tunnel behind them.
 *
 * Both calls are asynchronous, and that is a real difference from the terminal's
 * seam rather than a style choice. SwiftTerm searches a buffer this process
 * owns and answers on the line; WebKit searches a document in **another
 * process**, so every answer here arrives some frames later — which is the whole
 * reason {@link BrowserFindSession} carries a generation counter.
 */
@MainActor
protocol PageSearching: AnyObject {
    /**
     * Move the page's highlight to the next match, wrapping at the end.
     *
     * `matched` is false only when the term occurs nowhere in the document —
     * with wrapping on there is no "ran off the end" answer to report.
     */
    func find(_ term: String, backwards: Bool, completion: @escaping (Bool) -> Void)

    /**
     * Drop the highlight, and say when the page has actually done it.
     *
     * The completion is not decoration. A restart clears and then searches, and
     * a search that overtook its own clear would resume from the selection that
     * was supposed to be gone — which is the "walks down the document one letter
     * at a time" bug arriving by a different road. `then` is what puts the two
     * in order.
     */
    func clearFind(then: (() -> Void)?)
}

extension PageSearching {
    /// Clear and do not care when. What closing the bar wants.
    func clearFind() { clearFind(then: nil) }
}

/* -------------------------------------------------------------------------- */
/* WebKit's half                                                               */
/* -------------------------------------------------------------------------- */

/**
 * `PageSearching` over a real `WKWebView`.
 *
 * ## Who holds what, and why it is not the sibling's arrangement
 *
 * One rule, applied twice: **a find session never keeps its subject alive.**
 *
 * `FindSession` applies it by holding the terminal weakly, because the terminal
 * belongs to `HostLink` and a machine can be unpaired while its screen is still
 * up. The subject here is the `WKWebView`, which belongs to `BrowserBridge` and
 * is torn down with the screen — so **the weak reference is the one in this
 * adapter**, and every method below tolerates its absence.
 *
 * The adapter itself is the other half and goes the other way. It has no owner
 * but the session — it exists to serve exactly one — so
 * {@link BrowserFindSession} holds it **strongly**, with a plain `let`. Copying
 * the sibling's `weak` here would be the one genuinely broken spelling: nothing
 * else references it, so it would deallocate before the initialiser returned and
 * every search would quietly do nothing.
 */
@MainActor
final class WebViewSearch: PageSearching {

    /// Collapse the document's selection. See the file header for why this is
    /// the one script here and why it is not the injection this file refuses.
    private static let dropSelection = """
    (function () {
      var selection = window.getSelection();
      if (selection) { selection.removeAllRanges(); }
    })();
    """

    /// The same world `BrowserBridge` puts its inspect script in: reachable from
    /// this app, absent from the page.
    private static let world = WKContentWorld.defaultClient

    private weak var webView: WKWebView?

    init(_ webView: WKWebView) {
        self.webView = webView
    }

    func find(_ term: String, backwards: Bool, completion: @escaping (Bool) -> Void) {
        guard let webView else {
            // The screen has gone. Answering "false" would put "No matches" on a
            // bar that is not on screen, which is a lie about a page rather than
            // a silence about a missing one.
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        // Both stated rather than left to their defaults, because both are
        // decisions this file argues for and a missing line is indistinguishable
        // from a line nobody thought about. See the header on wrapping; case
        // insensitivity is the same bargain the terminal's bar makes — somebody
        // typing `header` into a phone keyboard should find `<Header>` without
        // reaching for the shift key.
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(term, configuration: configuration) { result in
            // WebKit answers on the main thread — every `WKWebView` API is
            // main-thread-only and its completions come back the same way — and
            // this is the spelling `BrowserBridge` already uses for the same
            // situation in its KVO blocks and its navigation delegate.
            MainActor.assumeIsolated { completion(result.matchFound) }
        }
    }

    func clearFind(then: (() -> Void)?) {
        guard let webView else { return }
        webView.evaluateJavaScript(Self.dropSelection, in: nil, in: Self.world) { _ in
            MainActor.assumeIsolated { then?() }
        }
        // The result is dropped rather than surfaced, exactly as `BrowserBridge.run`
        // drops its own: the only way this fails is a page mid-navigation, which
        // has no selection to clear and is not a fault anybody can act on.
    }
}

/* -------------------------------------------------------------------------- */
/* The state machine                                                           */
/* -------------------------------------------------------------------------- */

/**
 * The bar's state, and every rule about what a keystroke does.
 *
 * Kept out of the view for the reason `FindSession` is: what happens when the
 * term is emptied, what the counter says with nothing matching, whether closing
 * clears the highlight, and — the one this type has and its sibling does not —
 * whether an answer that arrives after the question changed is allowed to be
 * believed. A `View` can express all of that and can be asked none of it.
 */
@MainActor
@Observable
final class BrowserFindSession {

    /// What the last settled search said. Three cases and no `searching`: an
    /// in-flight search leaves the previous answer standing, because the
    /// alternative is arrows that blink disabled on every keystroke and a
    /// counter that flickers through a state nobody needs to read.
    enum Outcome {
        /// Nothing typed, or the term was emptied.
        case idle
        /// The highlight is on a match.
        case found
        /// The term occurs nowhere in the document.
        case missing
    }

    private(set) var isOpen = false
    private(set) var term = ""
    private(set) var outcome: Outcome = .idle

    /**
     * Strongly held. See {@link WebViewSearch} for why this is the reverse of
     * `FindSession.terminal` and why both are right.
     */
    private let page: PageSearching

    /**
     * Which question the answers coming back are about.
     *
     * Every user action mints a number; every completion checks it against the
     * current one and drops itself if it has been superseded. This is not
     * defensive padding — it is the difference between a correct bar and a
     * wrong one, and it exists because WebKit answers from another process.
     * Type `err`, then `error` a beat later: two searches are in flight, the
     * first one's answer can land second, and without this the bar reports
     * `err`'s result — very possibly *"No matches"* over a page that is plainly
     * highlighting one — as the verdict on `error`.
     *
     * `&+` so a very patient person cannot trap the app on an overflow.
     */
    @ObservationIgnored
    private var generation = 0

    init(page: PageSearching) {
        self.page = page
    }

    /**
     * The everyday one: search the page a `BrowserBridge` is showing.
     *
     * A second designated initialiser rather than a `convenience` one, because
     * there is exactly one stored property and delegating to set it buys
     * nothing — and because the adapter it builds is the thing this object then
     * owns, which reads more plainly as an assignment than as a hand-off.
     */
    init(webView: WKWebView) {
        self.page = WebViewSearch(webView)
    }

    /// Whether anything has been typed. The status and the clear button are
    /// drawn only past this, so an empty bar does not accuse anybody of finding
    /// nothing.
    var hasTerm: Bool { !term.isEmpty }

    /// Whether the arrows can do anything. False before the first answer comes
    /// back, which is a frame or two of a disabled control and is the honest
    /// state — nothing is highlighted yet.
    var hasMatch: Bool { outcome == .found }

    /**
     * What the bar says beside the field.
     *
     * Empty on a match, on purpose and not for lack of trying — see the file
     * header. WebKit hands over one bit and the page itself carries the other
     * half of the answer: the match is scrolled into view with a highlight on
     * it. The only sentence worth printing is the one the page cannot show,
     * which is that there is nothing to show.
     */
    var status: String {
        switch outcome {
        case .idle, .found: return ""
        case .missing: return "No matches"
        }
    }

    /**
     * Open the bar, and pick the old search back up if there is one.
     *
     * The term survives a close — see {@link close} — so re-opening with one
     * already in the field must re-highlight rather than sit there showing a
     * word with nothing marked on the page. A bar whose field disagrees with the
     * document is the same defect as a wrong count, arrived at from the other
     * direction.
     */
    func open() {
        guard !isOpen else { return }
        isOpen = true
        guard hasTerm else { return }
        restart()
    }

    /**
     * The term changed.
     *
     * Clear, then search forwards from the top — in that order and *sequenced*,
     * which is what `clearFind(then:)` exists for. See the header for why every
     * keystroke restarts instead of continuing.
     */
    func type(_ text: String) {
        term = text
        guard !text.isEmpty else {
            // A number minted with nothing to spend it on: it invalidates
            // whatever is still in flight, so an answer about the half-typed
            // term cannot land on an emptied field.
            _ = mint()
            outcome = .idle
            page.clearFind()
            return
        }
        restart()
    }

    /// Towards the end of the document — the direction reading goes, and the
    /// direction a fresh search starts in.
    func next() {
        guard hasTerm else { return }
        run(mint(), backwards: false)
    }

    /// Back towards the top.
    func previous() {
        guard hasTerm else { return }
        run(mint(), backwards: true)
    }

    /**
     * The page underneath changed.
     *
     * Called when the browser navigates or finishes a load, and it re-runs the
     * search rather than dropping it. That is the opposite of what Safari does
     * and it is right *here* specifically: the page this screen exists to look
     * at is a dev server, a dev server reloads itself every time a file is
     * saved, and a find that had to be re-typed after every hot reload would be
     * unusable in the one situation this feature was built for. You were reading
     * a match; after the reload you are reading it again.
     *
     * Nothing happens when the bar is shut, so a page that reloads all afternoon
     * behind a closed bar costs nothing.
     */
    func pageChanged() {
        guard isOpen, hasTerm else { return }
        restart()
    }

    /**
     * Put the bar away, and take the highlight with it.
     *
     * The term is kept, for the reason `FindSession` keeps its own: looking for
     * the same string twice is the common case — you found it, you scrolled, you
     * want it again — and throwing it away charges the second search the same
     * typing as the first. What is dropped is the highlight, because a blue band
     * left on a word after the bar has gone is a search that appears to still be
     * running.
     */
    func close() {
        guard isOpen else { return }
        isOpen = false
        _ = mint()
        outcome = .idle
        page.clearFind()
    }

    // MARK: - Mechanics

    /// Clear the selection, then search from the top of the document. Both
    /// halves carry the same generation, so a restart that has been superseded
    /// stops at the clear rather than issuing a search nobody asked for.
    private func restart() {
        let mine = mint()
        page.clearFind { [weak self] in
            guard let self, mine == self.generation else { return }
            self.run(mine, backwards: false)
        }
    }

    private func run(_ mine: Int, backwards: Bool) {
        page.find(term, backwards: backwards) { [weak self] matched in
            guard let self, mine == self.generation else { return }
            self.outcome = matched ? .found : .missing
        }
    }

    private func mint() -> Int {
        generation &+= 1
        return generation
    }
}
