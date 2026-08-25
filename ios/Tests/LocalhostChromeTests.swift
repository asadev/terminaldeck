/**
 * One chrome under every browser window, and the decisions that make it one.
 *
 * ## Where this started
 *
 * Asad, after the page on this phone had already been changed from a
 * `fullScreenCover` into a push: *"Localhost browsing is still not native on
 * iOS."* He was right twice over, and both halves were the same mistake — the
 * screen had taken over the two pieces of a pushed screen that belong to iOS:
 *
 *  1. **The left edge.** `allowsBackForwardNavigationGestures` handed the
 *     standard back gesture to the web view's own history, so the one gesture
 *     everybody reaches for to leave a pushed screen walked the page's history
 *     instead and the screen never left.
 *  2. **The navigation bar**, hidden so a custom row could carry back, reload,
 *     where-you-are, inspect and Done. The reasoning was sound — a system bar
 *     above that row is 94 points of chrome in two rows with two back buttons
 *     eleven points apart meaning different things — and the price was the whole
 *     platform: no chevron, no standard title, no interactive pop.
 *
 * That was fixed Safari's way: keep the navigation bar, put the browser's
 * controls along the bottom.
 *
 * ## And where it ended up: four windows, one bar and one header
 *
 * A round later he counted the browser windows this app has and found different
 * chromes on each:
 *
 * > *"So top, header and footer, tab bar should be same in all type of browsing
 * > windows, including on this phone, including isolated, including the server."*
 *
 * > *"if it is in this phone, I cannot edit the link and make a change and search
 * > it again."*
 *
 * So the bottom bar written on the phone's page is gone and that screen mounts
 * `BrowserPageBar` — the same view a window on the machine mounts — with the
 * same two rows: the address and Go, then Back · Forward · Reload · Find ·
 * Inspect. Done left the row; it tore the tunnel down, which is a thing you do
 * to the window rather than to the page, so it is `Close this window` behind the
 * `…`.
 *
 * ## And the round after that put the `…` where he asked for it
 *
 * > *"Maybe we can give some better one header also, not only the bottom, so we
 * > can have most of the important controls for the flow, for this kind of things
 * > and whatever we require to get the job done."*
 *
 * The `…` had been made the sixth control in the bottom row, which left the
 * header carrying a chevron, a title and nothing else — the exact opposite of
 * *"not only the bottom"*. It is a trailing item in the system navigation bar
 * now, `BrowserWindowActions`, on all four kinds of window; the row is the five
 * verbs that act on the page; and there is no second door onto the same menu.
 *
 * On a page this phone is holding open it pushes that page's **own** settings
 * screen, the same way a machine window's does — *"all of them should have all
 * the options"* — rather than opening a menu with one item in it.
 *
 * ## Why half of these read the source
 *
 * The same reason `AppearanceTests` reads it, and the reason is worth stating
 * because a source-reading test looks lazy until you try the alternatives. There
 * is nothing to ask at runtime: a `.safeAreaInset` on a screen nobody has
 * navigated to has not run, and SwiftUI exposes no way to interrogate a view's
 * bar from a unit test. The honest runtime answer needs a paired phone, a machine
 * serving a port and a finger — that is `LocalhostUITests` and
 * `BrowserPageBarUITests`, which measure the real bar on a real page and are the
 * *proof*. This file is the **tripwire**: it runs on a laptop with nothing
 * listening, in the suite that always runs, so that putting
 * `.toolbar(.hidden, for: .navigationBar)` back — or growing a second bottom bar
 * of this screen's own, or shuffling the row, or putting the `…` back into it —
 * fails immediately rather than surviving until somebody next has a desktop to
 * test against.
 *
 * `#filePath` is the compile-time location of this file, which gives the
 * checkout; a Simulator process can read the Mac's filesystem, which is how
 * `LiveTransferUITests` already checks uploads that landed on the Mac.
 */

import WebKit
import XCTest
@testable import TerminalDeck

@MainActor
final class LocalhostChromeTests: XCTestCase {

    // MARK: - The gesture

    /**
     * **The left edge belongs to the navigation stack.**
     *
     * This is the one of these that can be asked at runtime, and it is asked of a
     * real `WKWebView` rather than of the source, because what matters is the
     * state of the object the gesture recogniser is installed on.
     *
     * `false` is also `WKWebView`'s default, so this assertion would pass if the
     * line were deleted entirely — and that is fine and deliberate. What must
     * never come back is the `true`, and nothing else here can tell the
     * difference between a default and a decision. The line in `BrowserBridge`
     * is written out explicitly with its reasoning; this makes the value load
     * bearing.
     */
    func testTheWebViewDoesNotTakeTheEdgeSwipe() {
        let bridge = BrowserBridge()
        defer { bridge.tearDown() }

        XCTAssertFalse(bridge.webView.allowsBackForwardNavigationGestures,
                       "the left-edge swipe is how a pushed screen is left on iOS; a web view that "
                       + "takes it makes the one gesture everybody knows do something else")
    }

    /**
     * Forward exists, and it starts off with nowhere to go.
     *
     * It is here because turning the gesture off took it away: that one property
     * buys back on the left edge *and forward on the right*, so replacing only
     * the back half would have left a Back button that strands you — tap it once
     * by accident and the page you were reading is unreachable.
     *
     * The live half of this — a real history walked forwards again — is
     * `BrowserBackTests`, which has a real document to push entries onto.
     */
    func testForwardStartsWithNowhereToGo() {
        let bridge = BrowserBridge()
        defer { bridge.tearDown() }

        XCTAssertFalse(bridge.canGoForward,
                       "a fresh web view has no forward history, and the button must say so by "
                       + "being disabled rather than by doing nothing when pressed")
    }

    // MARK: - The bars

    /// **The navigation bar is not hidden.** The line that hid it is the whole
    /// of what he asked to be undone, so its absence is what is checked — and
    /// checked against real code rather than the prose, because this file talks
    /// about that modifier at length and so does the screen's own header.
    func testTheScreenDoesNotHideTheNavigationBar() throws {
        let source = try Self.browserSource()
        let offenders = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".toolbar(.hidden, for: .navigationBar)") }

        XCTAssertTrue(offenders.isEmpty,
                      "the localhost page is hiding the system navigation bar again — that costs "
                      + "the chevron, the title and the interactive pop, which is exactly what "
                      + "\"still not native\" was about")
        XCTAssertTrue(source.contains(".navigationBarTitleDisplayMode(.inline)"),
                      "the bar is kept, so it has to be told to stay one row high; a large title "
                      + "over a web page is 96 points of nothing")
    }

    /**
     * **The header is the chevron and one line of title, and nothing else.**
     *
     * > *"even if we remove the top header of paperclip and all of this basic
     * > information might not be required from the outside. We can just see and
     * > enter."*
     *
     * What was there was a principal view: the page's name over a mono
     * `http://127.0.0.1:52311/admin  ·  3 connections`. Both halves of that
     * second line are information rather than control — and the address, which is
     * the half worth keeping, is a **field** in the bar now, which is the thing he
     * could not have before.
     *
     * Asserted as the absence of the toolbar slot rather than by looking for the
     * strings, because a principal view is how a screen takes that space and
     * putting one back is the only way this regresses. The address ending up in
     * the bar is asserted separately below.
     */
    func testTheHeaderCarriesNoSecondLine() throws {
        let source = try Self.browserSource()

        XCTAssertFalse(source.contains("ToolbarItem(placement: .principal)"),
                       "the page's header is the system chevron and one line of title on every "
                       + "kind of browser window now — a principal view is this screen taking "
                       + "that space back for a mono address and a connection count")
        XCTAssertFalse(source.contains("connections\""),
                       "the connection count is not a line on the header; the header line ended "
                       + "in that word, and a copy of it left up there is the thing he asked to "
                       + "be removed from the outside of the page")
    }

    /**
     * **The phone's page mounts the one shared bar, and writes none of its own.**
     *
     * The bar it used to write was a system `UIToolbar` — a good bar, and the
     * third different one in this app under a live page. *"top, header and
     * footer, tab bar should be same in all type of browsing windows."*
     *
     * The prefix is asserted as well as the mount, because the prefix is what
     * every control on it is named by: `localhost.back`, `localhost.reload`,
     * `localhost.inspect`. Six suites reach for those names and none of them
     * should have had to change for a bar swap.
     */
    func testThePhonesPageMountsTheSharedBarAndNotOneOfItsOwn() throws {
        let source = try Self.browserSource()

        XCTAssertTrue(source.contains("BrowserPageBar("),
                      "the page on this phone should be wearing the same bar as a window on the "
                      + "machine — that is the whole of \"footer should be same in all type\"")
        XCTAssertTrue(source.contains("id: \"localhost\""),
                      "the bar's prefix is what every control on it is named by, and the names "
                      + "have to survive the swap")
        XCTAssertFalse(source.contains("ToolbarItemGroup(placement: .bottomBar)"),
                       "a second bottom bar written on this screen is how there came to be three "
                       + "different chromes under three kinds of window")
        // The identifier as a string literal, not the word in the prose above it:
        // this screen's header explains where Done went and naming it there is
        // the point of the explanation.
        XCTAssertFalse(source.contains("\"localhost.done\""),
                       "Done left the row — it tore the tunnel down, so it is \"Close this "
                       + "window\" behind the `…`")
        XCTAssertTrue(source.contains("\"localhost.close\""),
                      "and the verb itself is not lost. It is a card on the page's own settings "
                      + "screen for a page with a row on the Browser list, and this menu item for "
                      + "the one route that has no row — a prototype opened from a file")
    }

    /**
     * **The five controls, in one row, in his order — and no sixth.**
     *
     * Read off `BrowserPageBar.verbRow`, which is the one place the row is
     * assembled and the reason every identifier is spelled there rather than
     * inside the helpers it calls: a row whose order is put together somewhere
     * else is a row nobody can pin.
     *
     * The order is asserted as a whole sequence rather than by picking out one
     * end of it. The row he blessed read back, reload, where-you-are, inspect,
     * Done; what the passes since are allowed to have changed is exactly three
     * things — Find joining the page's own history controls, Done leaving for the
     * `…`, and the `…` itself leaving for the header — and a test that only
     * checked one end would let the rest be shuffled.
     *
     * The absence of a sixth entry is half of what this case is for. *"Not only
     * the bottom"* is answered by moving the `…` up, and it would be un-answered
     * the moment somebody put a second copy of it back down here — which is also
     * how one menu ends up with two doors.
     */
    func testTheFiveControlsAreOneRowInHisOrder() throws {
        let source = try Self.barSource()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let opens = try XCTUnwrap(lines.firstIndex { $0.contains("private var verbRow: some View {") },
                                  "the row is not assembled in one place any more")
        /*
         * Fenced on the computed property's own closing brace — the first line
         * that is exactly four spaces and a `}` after it opens. Brace matching
         * would be the precise answer and is not worth the machinery here: this
         * file is one type at one indentation, and without a fence the walk runs
         * on into the helpers below, whose identifiers are the same strings
         * passed through rather than the row's order.
         */
        let closes = try XCTUnwrap(lines[opens...].firstIndex { $0 == "    }" },
                                   "the row's closing brace is not where this walk expects it")

        // `id: "\(id).back"` — the prefix is the screen's, the suffix is the
        // control's, and the suffix is the whole of what this is reading.
        let marker = "id: \"\\(id)."
        var found: [String] = []
        for line in lines[opens..<closes] {
            guard let range = line.range(of: marker) else { continue }
            let rest = line[range.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { continue }
            found.append(String(rest[..<end]))
        }

        XCTAssertEqual(found, ["back", "forward", "reload", "find", "inspect"],
                       "the bar's order changed. Back, Forward and Reload lead — the page's own "
                       + "history first — then Find, then Inspect. The `…` is not one of these: "
                       + "it belongs in the header now")
    }

    /**
     * **The `…` is in the header, it is written once, and it keeps its name.**
     *
     * > *"Maybe we can give some better one header also, not only the bottom, so
     * > we can have most of the important controls for the flow."*
     *
     * Three claims, and each of them is a different way the move could be undone:
     *
     *  1. `BrowserWindowActions` exists in `BrowserChrome` and is the one place
     *     the control is drawn, so the four screens cannot grow four `…` that
     *     drift apart — which is the whole subject of this file;
     *  2. it is named `\(id).settings`, unchanged from when it sat in the bar, so
     *     the six suites that reach for `browser.machine.window.settings` and
     *     `localhost.settings` did not have to move;
     *  3. every screen with a live page places it as a **trailing item in the
     *     navigation bar** — asserted per screen, because a header that carries
     *     it on one kind of window and not another is the drift he counted.
     *
     * The surface viewer reached from Settings is deliberately not in that list:
     * it has no settings screen behind it, and the rule is that the control is
     * drawn only where it opens something.
     */
    func testTheMenuIsAHeaderControlWrittenOnce() throws {
        let chrome = try Self.chromeSource()

        XCTAssertTrue(chrome.contains("struct BrowserWindowActions"),
                      "the header's `…` should be one view in BrowserChrome — four screens each "
                      + "drawing their own is how three chromes happened in the first place")
        XCTAssertTrue(chrome.contains("\"\\(id).settings\""),
                      "the `…` changed places and must not have changed name: six suites reach "
                      + "for browser.machine.window.settings and localhost.settings")

        for (screen, source) in [("the page on this phone", try Self.browserSource()),
                                 ("a window on the machine", try Self.machineWindowSource())] {
            XCTAssertTrue(source.contains("BrowserWindowActions("),
                          "\(screen) should mount the shared header control")
            XCTAssertTrue(source.contains("ToolbarItem(placement: .topBarTrailing)"),
                          "\(screen) should put it in the header, trailing side — \"not only the "
                          + "bottom\" is a sentence about the top of the screen")
        }
    }

    /**
     * **A page on this phone opens the same kind of settings screen a window
     * does.**
     *
     * > *"all of them should have all the options. Should not be that much of
     * > difference in all of them."*
     *
     * For one round the `…` on this screen opened a menu with a single item in
     * it — Close — while a machine window's pushed a whole screen. The screen for
     * a phone page exists: `MachineWindowSettingsView` takes a `phoneTab:` and
     * draws that page's own cards, Close among them. It was reachable only from
     * the row's menu out on the Browser list, which is the *outside* of the
     * window, and his sentence is about the inside.
     *
     * Asserted on the call rather than on the absence of the menu, because the
     * menu is still right for exactly one page — a prototype `ArtifactView`
     * pushes straight at a tunnel, with no row and so no tab id to hand over.
     */
    func testThePhonePagesMenuOpensItsOwnSettings() throws {
        let source = try Self.browserSource()

        XCTAssertTrue(source.contains("phoneTab: tabID"),
                      "the `…` on a page this phone is holding open should push that page's own "
                      + "settings — the same screen a window on the machine pushes, which is what "
                      + "\"all of them should have all the options\" asks for")
        XCTAssertTrue(source.contains("MachineWindowSettingsView("),
                      "and it should be that screen rather than a second one written here")
    }

    // MARK: - The rules the two screens share

    /**
     * **One rule for what a window is called.**
     *
     * The page's own title, its address until it has one, a name until it has
     * even that. It is `MachineWindow.label` with the third case spelled out, and
     * it is one function so that the two screens cannot grow two versions of it —
     * which they had: one fell back to the port, the other to the word *Window*,
     * and a third to the surface's slot name.
     */
    func testAPageIsNamedByItsTitleThenItsAddress() {
        XCTAssertEqual(BrowserChrome.pageTitle(title: "Dashboard",
                                               address: "localhost:3000/admin",
                                               fallback: "localhost:3000"),
                       "Dashboard")
        XCTAssertEqual(BrowserChrome.pageTitle(title: "",
                                               address: "localhost:3000/admin",
                                               fallback: "localhost:3000"),
                       "localhost:3000/admin",
                       "a page that has not named itself is named by where it is — \"Untitled\" "
                       + "tells nobody which of their four windows they are looking at")
        XCTAssertEqual(BrowserChrome.pageTitle(title: "", address: "", fallback: "localhost:3000"),
                       "localhost:3000")
    }

    /**
     * **The address field says the port he chose, not the one this phone picked.**
     *
     * A page on this phone really is at `http://127.0.0.1:52311/admin`, where
     * `52311` is whatever the listener managed to bind. Nobody chose that number
     * and nobody can act on it; what he chose is `3000`.
     *
     * The path, the query and the fragment all have to survive, because the whole
     * reason the field exists is that the interesting part of one of these
     * addresses is the end of it: *"I cannot edit the link and make a change and
     * search it again."*
     */
    func testALoopbackAddressIsSpelledWithTheMachinesPort() {
        XCTAssertEqual(BrowserChrome.shownAddress("http://127.0.0.1:52311/admin", machinePort: 3000),
                       "localhost:3000/admin")
        XCTAssertEqual(BrowserChrome.shownAddress("http://127.0.0.1:52311/", machinePort: 3000),
                       "localhost:3000/")
        XCTAssertEqual(BrowserChrome.shownAddress("http://127.0.0.1:52311/x?a=1#b", machinePort: 5173),
                       "localhost:5173/x?a=1#b",
                       "the end of one of these is the part worth editing, so none of it may be "
                       + "dropped on the way to the field")
    }

    /// Once a page has walked off to a real site, that site's own address is the
    /// honest thing to show — this is a spelling for the tunnel, not a rewrite of
    /// every address the field ever holds.
    func testARealSiteIsShownAsItself() {
        XCTAssertEqual(BrowserChrome.shownAddress("https://www.google.com/search?q=x",
                                                  machinePort: 3000),
                       "https://www.google.com/search?q=x")
        XCTAssertEqual(BrowserChrome.shownAddress("", machinePort: 3000), "")
    }

    /**
     * The spelling has to round-trip: what the field shows must be readable back
     * by the parser every address field in this app shares.
     *
     * This is the assertion that stops the two halves drifting apart. If
     * `shownAddress` ever produced something `LocalhostAddress.classify` did not
     * read as this machine's port, the field would show an address that could not
     * be re-entered — which is worse than showing the raw loopback one, because
     * it looks editable and is not.
     */
    func testWhatTheFieldShowsCanBeTypedBackIn() {
        let shown = BrowserChrome.shownAddress("http://127.0.0.1:52311/admin", machinePort: 3000)
        switch LocalhostAddress.classify(shown) {
        case let .tunnel(port, path):
            XCTAssertEqual(port, 3000)
            XCTAssertEqual(path, "/admin")
        default:
            XCTFail("the field shows \"\(shown)\", which the app's own parser does not read as a "
                    + "port on the machine — so it could not be typed back in")
        }
    }

    // MARK: - Helpers

    /// The phone page's source, from the checkout this test was compiled in.
    private static func browserSource() throws -> String {
        try read("TerminalDeck/Screens/LocalhostBrowser.swift")
    }

    /// The one bar's source.
    private static func barSource() throws -> String {
        try read("TerminalDeck/Screens/BrowserPageBar.swift")
    }

    /// The rules the four kinds of window share, including the header's `…`.
    private static func chromeSource() throws -> String {
        try read("TerminalDeck/Screens/BrowserChrome.swift")
    }

    /// A window on the machine — the other screen that has to wear the same
    /// header, and the one this file did not read until the `…` moved up into it.
    private static func machineWindowSource() throws -> String {
        try read("TerminalDeck/Screens/MachineWindowView.swift")
    }

    private static func read(_ relative: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)   // …/ios/Tests/LocalhostChromeTests.swift
            .deletingLastPathComponent()             // …/ios/Tests
            .deletingLastPathComponent()             // …/ios
            .appendingPathComponent(relative)
        let source = try String(contentsOf: file, encoding: .utf8)
        // A file that could not be found reads as an empty string in some of the
        // obvious spellings of this, and every assertion above then passes for
        // the wrong reason. Cheap to refuse.
        XCTAssertGreaterThan(source.count, 5_000,
                             "read almost nothing at \(file.path) — this walk is measuring nothing")
        return source
    }
}
