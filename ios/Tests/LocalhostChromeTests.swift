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
 * now, `BrowserWindowActions`, on all four kinds of window; the row is the
 * verbs that act on the page; and there is no second door onto the same menu.
 *
 * On a page this phone is holding open it pushes that page's **own** settings
 * screen, the same way a machine window's does — *"all of them should have all
 * the options"* — rather than opening a menu with one item in it.
 *
 * ## And the round after that gave the page two things a picture cannot have
 *
 * > *"they can use the the mode currently we have this machine they can just
 * > browse as phone view and it should have all the by the way views also they
 * > can pinch and zoom also they can see all the different dimensions in
 * > responsive views how it will look like in mobile how it will look like on
 * > Windows so they can have different dimensions also in phone just like
 * > MacBook."*
 *
 * > *"you are giving record flow button in the windows side the server side it
 * > and you are not giving that into the if they are browsing locally in this
 * > machine. So there are so many differences if they both are capable for a
 * > feature why don't they both have."*
 *
 * Both land on **this** screen because this screen owns the document, and both
 * are drawn on the shared bar so that a window on the machine shows the same
 * control greyed with one sentence rather than not showing it at all — which is
 * the rule the whole bar is built on.
 *
 * The cases below hold the two claims that are easy to fake and impossible to
 * see in a screenshot: that a chosen width is a width the page is **laid out
 * at** rather than a picture scaled up, and that a recorded flow speaks the same
 * seven words the machine's recorder speaks — down to the sentence — so the two
 * lists do not describe one click in two languages. And one claim that is about
 * a person rather than about code: a menu row is a **name**, never a name with a
 * line of explanation under it.
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
     * **The controls, in one row, in his order — and the `…` not among them.**
     *
     * Read off `BrowserPageBar.verbRow`, which is the one place the row is
     * assembled and the reason every identifier is spelled there rather than
     * inside the helpers it calls: a row whose order is put together somewhere
     * else is a row nobody can pin.
     *
     * The order is asserted as a whole sequence rather than by picking out one
     * end of it. The row he blessed read back, reload, where-you-are, inspect,
     * Done; what the passes since are allowed to have changed is exactly four
     * things — Find joining the page's own history controls, Done leaving for the
     * `…`, the `…` itself leaving for the header, and Size arriving at the end —
     * and a test that only checked one end would let the rest be shuffled.
     *
     * **Size is the sixth and the `…` is still not one of them**, which is the
     * half of this case worth stating plainly, because the two look identical to a
     * count. *"Not only the bottom"* was answered by moving the menu up, and it
     * would be un-answered the moment somebody put a second copy of it back down
     * here — which is also how one menu ends up with two doors. A verb that acts
     * on the **page** is a different thing entirely, and how wide the page is laid
     * out is pressed over and over while comparing one width against another:
     *
     * > *"they can see all the different dimensions in responsive views how it
     * > will look like in mobile how it will look like on Windows."*
     */
    func testTheControlsAreOneRowInHisOrder() throws {
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

        XCTAssertEqual(found, ["back", "forward", "reload", "find", "inspect", "size"],
                       "the bar's order changed. Back, Forward and Reload lead — the page's own "
                       + "history first — then Find, then Inspect, then Size. The `…` is not one "
                       + "of these: it belongs in the header")

        XCTAssertFalse(source.contains("id: \"\\(id).settings\""),
                       "the `…` is back in the bottom row. It is a trailing item in the "
                       + "navigation bar and there is exactly one of it")
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

    // MARK: - Size: pinch, and the other widths

    /**
     * **A page can be pinched even when it says it must not be.**
     *
     * > *"they can pinch and zoom"*
     *
     * `user-scalable=no` is in the default template of every dev server anybody
     * builds against — it is what stops a phone zooming an app-shaped site by
     * accident — and `WKWebView` honours it. On a **browser** that is the wrong
     * default: the entire reason for opening a page here is to examine it, and a
     * page that cannot be zoomed on a six-inch screen cannot be examined.
     *
     * Asked of a real configuration rather than of the source, like the edge-swipe
     * case above and for the same reason: what matters is the state of the object
     * WebKit reads. Unlike that one this value is **not** the platform default, so
     * a deleted line fails here rather than passing quietly.
     */
    func testAPageCanBePinchedWhateverTheSiteSays() {
        let bridge = BrowserBridge()
        defer { bridge.tearDown() }

        XCTAssertTrue(bridge.webView.configuration.ignoresViewportScaleLimits,
                      "the web view is honouring user-scalable=no again — that is on the default "
                      + "template of every dev server, and it makes the page he opened to examine "
                      + "the one page he cannot zoom into")
    }

    /**
     * **Every row is a name, and the pixels are the quiet half beside it.**
     *
     * > *"you are also putting so much of a description under the title of that
     * > thing under the title of the feature instead of just i button or nothing
     * > maybe so they have becomes too big you should compact all the features or
     * > buttons and without losing any of them"*
     *
     * The menu is the list he would have complained about if it had grown a line
     * of explanation under each row, so what a row may contain is asserted rather
     * than left to taste: the device's **name** is a title — two words, no
     * sentence, no newline — and the numbers live in `measure`, which
     * `BrowserPageBar.sizeRow` draws faint on the same line. Splitting them is
     * what lets both claims be checked; a single string carrying both could only
     * ever be checked for length.
     */
    func testEveryRowIsANameAndTheNumbersAreBesideIt() {
        for device in PageDevice.allCases {
            let name = device.name
            XCTAssertFalse(name.isEmpty)
            XCTAssertFalse(name.contains("\n"),
                           "\(name) is two lines. A row is a title — the explanation goes on the ⓘ")
            XCTAssertFalse(name.contains("."),
                           "\(name) is a sentence. A menu row is a name he can point at")
            XCTAssertLessThanOrEqual(name.count, 16,
                                     "\(name) is long enough to be a description of itself")
            XCTAssertFalse(name.contains("×"),
                           "\(name) has swallowed its own measurement — the pixels are the second "
                           + "element of the row, not part of the title")
            guard let size = device.size else { continue }
            XCTAssertEqual(device.measure, "\(Int(size.width)) × \(Int(size.height))",
                           "\(name) does not say what size it is, which is the whole question "
                           + "being asked of this control")
        }
        XCTAssertNil(PageDevice.fit.size,
                     "\"This phone\" must lay nothing out at anything — it is the state in which "
                     + "this feature does not touch the page at all")
        XCTAssertNil(PageDevice.fit.measure,
                     "and it has no measurement to print: this phone is whatever this phone is")
    }

    /**
     * **A size is a width AND a height, and the list is the real set.**
     *
     * > *"when i make other frame like desktop or laptop biew it is trying to fit
     * > inside the same given space a sphone instead of giving me less hieght and
     * > like actual laptop dimension"*
     *
     * > *"and there are very less options for dimensiins too"*
     *
     * Two complaints, one shape. The first one is the reason `size` is a `CGSize`
     * at all — a chosen width with the phone's own height drew a laptop as a tall
     * strip — and the second is why there are seven of them. Both are asserted
     * here rather than left to the menu, because a list that quietly lost a row
     * or a device that quietly became square would still draw and would still
     * photograph.
     */
    func testTheSizesAreRealRectanglesAndThereAreEnoughOfThem() {
        let devices = PageDevice.allCases.filter { $0 != .fit }
        XCTAssertEqual(devices.count, 7,
                       "the list he called too short is small phone, phone, large phone, tablet, "
                       + "tablet landscape, laptop and desktop — seven")

        for device in devices {
            let size = device.size!
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
            XCTAssertNotEqual(size.width, size.height,
                              "\(device.name) is square, which no device is — a size with no "
                              + "shape is the defect this round exists to fix")
        }

        XCTAssertTrue(PageDevice.laptop.size!.width > PageDevice.laptop.size!.height,
                      "a laptop is wider than it is tall. That sentence is the entire feature")
        XCTAssertTrue(PageDevice.phone.size!.height > PageDevice.phone.size!.width,
                      "and a phone is taller than it is wide")
        XCTAssertEqual(PageDevice.laptop.size, CGSize(width: 1280, height: 800))
        XCTAssertEqual(PageDevice.desktop.size, CGSize(width: 1440, height: 900))
    }

    /**
     * **Turning one over lands on a listed row, and never on a second name for a
     * shape that already has one.**
     *
     * The trap this pins is a menu with two ways to reach one rectangle: *Tablet*
     * + *Rotate* drawing the identical frame as *Tablet landscape* while ticking
     * a different row. `PageDevice.turnedTwin` is what prevents it, and the last
     * assertion is the one that would catch somebody adding a landscape row later
     * and forgetting the mapping.
     */
    func testRotatingLandsOnOneRowPerShape() throws {
        XCTAssertEqual(PageSize(.tablet).turnedOver(), PageSize(.tabletLandscape),
                       "a tablet on its side is the row that already says so, not the same row "
                       + "wearing a flag")
        XCTAssertEqual(PageSize(.tabletLandscape).turnedOver(), PageSize(.tablet))

        let turnedPhone = PageSize(.phone).turnedOver()
        XCTAssertEqual(turnedPhone, PageSize(.phone, turned: true))
        XCTAssertEqual(turnedPhone.layout, CGSize(width: 844, height: 390),
                       "and turning one over swaps the rectangle — otherwise Rotate is a tick "
                       + "that does nothing")
        XCTAssertEqual(turnedPhone.turnedOver(), PageSize(.phone),
                       "twice round is where it started")

        XCTAssertEqual(PageSize.fit.turnedOver(), PageSize.fit,
                       "this phone on its side is this phone. The row is not drawn in that state; "
                       + "this is the belt to the menu's braces")
        XCTAssertFalse(PageSize(.fit, turned: true).turned,
                       "and a stored rotation on this phone is refused at the initialiser rather "
                       + "than ignored later, which is one fact instead of two")

        /*
         * Every state a person can reach — every row, and Rotate pressed on each
         * — collapsed to the distinct ones, and then asked whether any two of
         * them draw the same rectangle.
         *
         * The collapse is the half that has to be right. `PageSize(.tablet)`
         * turned over **is** `PageSize(.tabletLandscape)`, so walking both rows
         * naturally meets each shape twice; a naive walk reports that as a
         * duplicate and the test fails on correct code. It did, when this was
         * first written — measured, not imagined. Distinct *states* first, then
         * distinct *shapes*, is the claim: two names for one rectangle is a menu
         * with a state you can reach twice and un-tick neither.
         */
        var states: [PageSize] = []
        for device in PageDevice.allCases where device != .fit {
            for state in [PageSize(device), PageSize(device).turnedOver()]
            where !states.contains(state) {
                states.append(state)
            }
        }
        var seen: [CGSize] = []
        for state in states {
            let layout = try XCTUnwrap(state.layout)
            XCTAssertFalse(seen.contains(layout),
                           "\(state) draws \(layout), which another state already draws")
            seen.append(layout)
        }
        XCTAssertEqual(states.count, 12,
                       "seven rows, and Rotate opens five more — the two tablets rotate into "
                       + "each other rather than into two new ones")
    }

    /**
     * **A laptop frame is laptop shaped, whatever it is drawn inside.**
     *
     * > *"it is trying to fit inside the same given space a sphone instead of
     * > giving me less hieght and like actual laptop dimension"*
     *
     * `PageFit` is the six lines that answer that, so it is tested as arithmetic
     * rather than left to a screenshot. Three claims, and the first is the one
     * that was wrong before: the drawn rectangle has the **device's** aspect
     * ratio and not the phone's. Then it fits inside the space it was given, and
     * it is never blown up past life size.
     *
     * The boxes are two real ones — an iPhone in portrait and the same phone
     * turned — because the old code passed a test like this on one of them by
     * accident: at a box whose ratio happens to be near the device's, keeping the
     * phone's height looks right.
     */
    func testAFrameKeepsTheDevicesProportions() throws {
        let boxes = [CGSize(width: 393, height: 690),   // an iPhone, page area
                     CGSize(width: 852, height: 330),   // the same phone turned
                     CGSize(width: 1024, height: 1180)] // an iPad, which this app runs on

        for box in boxes {
            for device in PageDevice.allCases where device != .fit {
                let fit = try XCTUnwrap(PageFit(PageSize(device), in: box),
                                        "\(device.name) in \(box) produced no fit at all")

                let wanted = device.size!.width / device.size!.height
                let drawn = fit.drawn.width / fit.drawn.height
                XCTAssertEqual(drawn, wanted, accuracy: 0.02,
                               "\(device.name) came out \(fit.drawn) in \(box) — ratio \(drawn) "
                               + "against \(wanted). A frame that borrows the phone's height is "
                               + "the exact defect this round was opened for")

                XCTAssertLessThanOrEqual(fit.drawn.width, box.width,
                                         "\(device.name) is wider than the space it is drawn in")
                XCTAssertLessThanOrEqual(fit.drawn.height, box.height,
                                         "\(device.name) is taller than the space it is drawn in")
                XCTAssertLessThanOrEqual(fit.scale, 1,
                                         "\(device.name) is blown up past life size, which reads "
                                         + "as a small phone being bigger than his")
                XCTAssertGreaterThan(fit.scale, 0)
                XCTAssertEqual(fit.layout, device.size!,
                               "the web view must be laid out at the device's own pixels — that "
                               + "is the half the document can read")
            }
        }
    }

    /**
     * **A laptop leaves ground above and below it; a phone leaves it either
     * side.**
     *
     * The visible half of the same claim, and the one he described: *"giving me
     * less hieght"*. On a phone-shaped space a laptop binds on width and cannot
     * use the height; a phone frame binds on height and cannot use the width. If
     * both ever filled the same rectangle, the frame would have stopped meaning
     * anything again.
     */
    func testALaptopIsShortAndAPhoneIsNarrow() throws {
        let box = CGSize(width: 393, height: 690)

        let laptop = try XCTUnwrap(PageFit(PageSize(.laptop), in: box))
        XCTAssertGreaterThan(laptop.drawn.width, laptop.drawn.height,
                             "a laptop frame that is taller than it is wide is the strip he "
                             + "complained about")
        XCTAssertLessThan(laptop.drawn.height, box.height * 0.6,
                          "and it has to leave real ground above and below it — \"less hieght\" "
                          + "is the phrase, and a frame filling the screen says nothing")

        let phone = try XCTUnwrap(PageFit(PageSize(.phone), in: box))
        XCTAssertGreaterThan(phone.drawn.height, phone.drawn.width)
        XCTAssertLessThan(phone.drawn.width, box.width)

        XCTAssertNil(PageFit(.fit, in: box),
                     "this phone's own size is the one state with no frame at all — nil here is "
                     + "the only place the two are told apart, and a second test of the device "
                     + "somewhere else is how they come to disagree")

        // A box that has not been laid out yet still answers, clamped. Returning
        // nil there would flip the screen from framed to unframed for one pass
        // and back, which is a web view resized twice for nothing.
        XCTAssertNotNil(PageFit(PageSize(.laptop), in: .zero))
    }

    /**
     * **A width is remembered for the site, not for the URL.**
     *
     * *Per page* read literally would be forgotten by the first link, and that is
     * not a hypothetical: everything this feature exists to look at is a dev
     * server, every dev server serves a single-page app, and every route change in
     * one rewrites the URL. It is the same fact `seed` is built around. Keyed on
     * the whole address, the width would drop back to this phone's the moment he
     * tapped *Orders* — in the middle of checking how Orders looks on a laptop.
     *
     * The other half is the tunnel's own port, which must never be part of the
     * key: this phone picks that number at random on every open, so a memory
     * keyed on it would be a memory that never matched twice.
     */
    func testASizeIsRememberedForTheSiteAndSurvivesTheTunnel() throws {
        // Its own suite, so a test run cannot write a width onto the machine it is
        // running from — the arrangement `PortBook` and `BrowserHistory` use.
        let name = "test.pageWidths.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { suite.removePersistentDomain(forName: name) }
        let widths = PageWidths(defaults: suite)

        let admin = PageWidths.site("http://127.0.0.1:52311/admin", machinePort: 3000)
        XCTAssertEqual(admin, "localhost:3000",
                       "a tunnelled page belongs to the port he chose, not to the loopback port "
                       + "this phone bound at random")
        widths.choose(PageSize(.laptop), for: admin)

        let orders = PageWidths.site("http://127.0.0.1:52311/orders?page=2", machinePort: 3000)
        XCTAssertEqual(widths.size(for: orders), PageSize(.laptop),
                       "clicking a link inside the site he is examining must not put the page "
                       + "back to phone size")

        // A second open of the same port through a different listener — the case
        // that decides whether the key was the right one.
        let reopened = PageWidths.site("http://127.0.0.1:61099/admin", machinePort: 3000)
        XCTAssertEqual(widths.size(for: reopened), PageSize(.laptop))

        // And the rotation survives with it. It is packed into the same integer
        // as the device, so a store that dropped it would be a page coming back
        // portrait with the landscape frame he left it in remembered as gone.
        widths.choose(PageSize(.phone, turned: true), for: admin)
        XCTAssertEqual(widths.size(for: reopened), PageSize(.phone, turned: true))
        XCTAssertEqual(PageWidths(defaults: suite).size(for: admin), PageSize(.phone, turned: true),
                       "a size he chose has to survive the app being closed — the store is read "
                       + "whole at launch, so this second instance is that launch")

        XCTAssertEqual(widths.size(for: PageWidths.site("http://127.0.0.1:52311/", machinePort: 5173)),
                       .fit,
                       "and a different port is a different site, which starts where everything "
                       + "starts: this phone's own size")

        XCTAssertEqual(PageWidths.site("https://WWW.Example.com/x", machinePort: 3000),
                       "www.example.com",
                       "a real site is one site however it was typed")
        XCTAssertEqual(PageWidths.site("about:blank", machinePort: 3000), "",
                       "a page that is not anywhere is a page nothing can be remembered about")
    }

    /**
     * **A verb that cannot act on this page is not drawn at all.**
     *
     * The rule used to be the opposite — greyed, in its slot, with the reason on
     * an ⓘ — and it was his, from the round that made every browsing window wear
     * the same six. He reversed it on 2026-08-26 looking at the bar inside a
     * session:
     *
     * > *"if the browsers cannot have this options like find, inspect and size…
     * > it should be first of all possible and useful here also. But if not then
     * > I think here we can just make it more simplified, remove find, inspect
     * > and size."*
     *
     * So there is no `whyNoSize`, no `whyNoFind`, no `whyNoInspect` and no
     * `unavailable` left to write a sentence into, and the ⓘ that carried them
     * went with them — *"this icon is not required here, i information button, it
     * can go."* What this pins is that none of them came back: a bar that grew a
     * reason string again is a bar drawing dead controls again.
     */
    func testAVerbThatCannotActIsNotDrawn() throws {
        let bar = try Self.barSource()
        for gone in ["whyNoSize", "whyNoFind", "whyNoInspect", "var unavailable"] {
            XCTAssertFalse(bar.contains(gone),
                           "\(gone) is back, which means dead controls are back with it")
        }
        XCTAssertFalse(bar.contains("InfoDot"),
                       "the ⓘ carried the sentences behind the greyed verbs and has nothing left "
                       + "to explain")
    }

    /**
     * **The width is real: the view is that wide, and the page is told so.**
     *
     * This is the one claim in the whole feature that is worth a tripwire, because
     * the cheap implementation of it looks identical in a screenshot and answers
     * nothing. A CSS transform scales a phone layout up; the media queries that
     * decide what a responsive page *does* fire off the viewport and never see it.
     *
     * So both halves are pinned. `WebSurface` lays the web view out at the chosen
     * width in points and scales the **view** — which no CSS in the document can
     * read — and `PageViewportScript` writes a viewport for the pages the first
     * half does not reach: one that declares a fixed width of its own, and one
     * that declares none and is laid out by WebKit at 980 whatever size the view
     * is.
     */
    func testTheWidthIsTheViewsAndNotACSSTrick() throws {
        let screen = try Self.browserSource()
        XCTAssertTrue(screen.contains("WebSurface(browser: browser, layout: fit.layout)"),
                      "the surface has to be given a real rectangle. A page scaled instead of "
                      + "laid out is a phone layout in bigger letters, which answers nothing "
                      + "about how the page behaves on a laptop")
        XCTAssertTrue(screen.contains("web.bounds = CGRect(origin: .zero, size: layout)"),
                      "and the web view's own bounds are that rectangle — width and height. The "
                      + "round before this divided the phone's height by the scale, and a laptop "
                      + "came out a tall strip")
        XCTAssertTrue(screen.contains("CGAffineTransform(scaleX: scale, y: scale)"),
                      "the fitting is a UIKit transform on the view — the document cannot read "
                      + "one, which is exactly why it is the honest half")
        XCTAssertFalse(screen.contains("height: box.height / scale"),
                       "the old fitting is back: that line is what drew a 1280-wide column as "
                       + "tall as an iPhone, and it is the defect this round was opened for")

        XCTAssertTrue(PageViewportScript.apply(PageSize(.laptop)).contains("1280"),
                      "the viewport instruction should carry the width itself")
        XCTAssertTrue(PageViewportScript.apply(PageSize(.tablet).turnedOver()).contains("1194"),
                      "and a frame on its side carries the width it actually has")
        XCTAssertTrue(PageViewportScript.apply(.fit).contains("(0)"),
                      "and this phone's own size is the state that clears it")
        XCTAssertFalse(PageViewportScript.source.contains("user-scalable=no"),
                       "a viewport this app writes must never take the pinch away — pinch is "
                       + "half of what this control is for")
        XCTAssertTrue(PageViewportScript.source.contains("width=device-width"),
                      "and going back to this phone has to leave a viewport that is true, "
                      + "because whether WebKit re-reads one on removal is not a thing to bet a "
                      + "screen on")
    }

    // MARK: - The click flow, recorded on this phone

    /**
     * **A flow says where it begins.**
     *
     * `setBrowserViewRecording` on the machine writes a `navigate` step the moment
     * recording starts, with one line of comment: *"a flow that does not say where
     * it starts cannot be replayed."* This side does the same, and it has to do it
     * from the address **this app** knows the view is at — never from anything the
     * page said about itself.
     */
    func testARecordingSaysWhereItBegins() {
        let flow = PhoneClickFlow(now: { 1_000 })
        flow.at(tab: "t1", url: "http://127.0.0.1:52311/admin")
        XCTAssertTrue(flow.steps(tab: "t1").isEmpty,
                      "knowing where the page is is not recording it")

        flow.start(tab: "t1")
        let steps = flow.steps(tab: "t1")
        XCTAssertEqual(steps.count, 1)
        XCTAssertEqual(steps.first?.kind, "navigate")
        XCTAssertEqual(steps.first?.detail, "Go to http://127.0.0.1:52311/admin",
                       "the first row is the machine's own sentence for a navigation — one "
                       + "vocabulary, or the two lists describe the same click in two languages")
        XCTAssertTrue(flow.isRecording(tab: "t1"))
    }

    /**
     * **A password is a step, and never a value.**
     *
     * The step exists because a replay has to know a password was entered; the
     * value never leaves the page, and never reaches the row. Two independent
     * checks, exactly as `parseGuestStep` describes: the page-side script flags
     * the field it knows to be secret, and the element's own `type` attribute
     * catches a payload that arrived with the flag stripped off.
     *
     * The second half is the one worth a test — the first is a script, and a
     * script is what an attacker edits.
     */
    func testAPasswordsValueIsNeverRecordedEvenWithTheFlagStripped() {
        let flow = PhoneClickFlow(now: { 1_000 })
        flow.at(tab: "t1", url: "http://127.0.0.1:52311/login")
        flow.start(tab: "t1")

        // No `secret` flag at all, and a value the page would very much like kept.
        flow.note(Self.step(kind: "type",
                            tag: "input",
                            id: "pass",
                            attributes: ["type": "password", "placeholder": "Password"],
                            extra: ["value": "hunter2-the-real-one"]),
                  url: "http://127.0.0.1:52311/login",
                  tab: "t1")

        let step = flow.steps(tab: "t1").last
        XCTAssertEqual(step?.kind, "type", "the step still happened")
        XCTAssertEqual(step?.detail, "Type the password into \"Password\" (`#pass`)",
                       "and it says so in the machine's own words")
        XCTAssertNil(step?.value,
                     "the value must not be on the row. A field carrying a one-time code in "
                     + "clear is not made safe by being short")
        for row in flow.steps(tab: "t1") {
            XCTAssertFalse((row.detail ?? "").contains("hunter2"))
            XCTAssertFalse((row.value ?? "").contains("hunter2"))
        }
    }

    /// A file input is the same rule and it is the half that gets forgotten: the
    /// value is a path on somebody's own disk and names them before it names
    /// anything else.
    func testAFilePathIsNeverRecordedEither() {
        let flow = PhoneClickFlow(now: { 1_000 })
        flow.at(tab: "t1", url: "http://127.0.0.1:52311/upload")
        flow.start(tab: "t1")
        flow.note(Self.step(kind: "type",
                            tag: "input",
                            id: "cv",
                            attributes: ["type": "file", "aria-label": "Résumé"],
                            extra: ["value": "/Users/asad/Documents/passport.pdf"]),
                  url: "http://127.0.0.1:52311/upload",
                  tab: "t1")

        XCTAssertNil(flow.steps(tab: "t1").last?.value)
        XCTAssertFalse((flow.steps(tab: "t1").last?.detail ?? "").contains("Users"))
    }

    /**
     * **A double-click is one step, and a corrected typo is one step.**
     *
     * Both rules are transcribed from `appendStep` rather than invented, and both
     * are about a *replay*: nobody wants the second half of a double-click, and a
     * replay that used the half-typed value from before the correction would type
     * the typo.
     *
     * The clock is a seam here for the reason the house rule gives about never
     * faking load to test timing — the merge window is 400ms and a test that slept
     * through it would be a test that fails under a fleet.
     */
    func testOneGestureIsOneStep() {
        var clock: Double = 1_000
        let flow = PhoneClickFlow(now: { clock })
        flow.at(tab: "t1", url: "http://127.0.0.1:52311/")
        flow.start(tab: "t1")

        let button = Self.step(kind: "click", tag: "button", id: "submit", text: "Sign in")
        flow.note(button, url: "http://127.0.0.1:52311/", tab: "t1")
        clock += 120
        flow.note(button, url: "http://127.0.0.1:52311/", tab: "t1")
        XCTAssertEqual(flow.steps(tab: "t1").count, 2,
                       "the navigate and one click — two taps 120ms apart on one button is a "
                       + "double-click, not two steps")

        clock += 5_000
        flow.note(button, url: "http://127.0.0.1:52311/", tab: "t1")
        XCTAssertEqual(flow.steps(tab: "t1").count, 3,
                       "and a deliberate second press five seconds later is a second step — a "
                       + "stepper button really is pressed twice")

        let field = { (value: String) in
            Self.step(kind: "type", tag: "input", id: "email",
                      attributes: ["placeholder": "Email"], extra: ["value": value])
        }
        clock += 1_000
        flow.note(field("asad@exampl"), url: "http://127.0.0.1:52311/", tab: "t1")
        clock += 1_000
        flow.note(field("asad@example.com"), url: "http://127.0.0.1:52311/", tab: "t1")
        XCTAssertEqual(flow.steps(tab: "t1").count, 4)
        XCTAssertEqual(flow.steps(tab: "t1").last?.value, "asad@example.com",
                       "tabbing back to fix a typo replaces the step; a replay must not use the "
                       + "half-typed value")
    }

    /**
     * **A flow that runs long keeps its beginning and says it was cut.**
     *
     * Two claims, and the second is the one a silent implementation gets wrong.
     * The cap stops the list growing rather than dropping the oldest steps —
     * *"one missing its beginning cannot be replayed at all, while one missing its
     * end is still a shorter true flow"* — and the cut is drawn as a row of its
     * own, in the `truncated` kind the machine uses, because a list that simply
     * stops reads as *that is all of them*.
     */
    func testAFlowThatRunsLongKeepsItsBeginningAndSaysItWasCut() {
        var clock: Double = 1_000
        let flow = PhoneClickFlow(now: { clock })
        flow.at(tab: "t1", url: "http://127.0.0.1:52311/")
        flow.start(tab: "t1")

        for index in 0 ..< (PhoneClickFlow.maxSteps + 40) {
            clock += 1_000
            flow.note(Self.step(kind: "click", tag: "button", id: "b\(index)", text: "Row \(index)"),
                      url: "http://127.0.0.1:52311/", tab: "t1")
        }

        let steps = flow.steps(tab: "t1")
        XCTAssertEqual(steps.count, PhoneClickFlow.maxSteps + 1,
                       "two hundred steps and one row saying so")
        XCTAssertEqual(steps.first?.kind, "navigate",
                       "the beginning is what a flow cannot be replayed without, so it is the "
                       + "one thing the cap may never drop")
        XCTAssertEqual(steps.last?.kind, "truncated",
                       "the cut is a row in the same vocabulary the machine cuts in — the two "
                       + "lists are drawn by the same rows")
        XCTAssertNotNil(steps.last?.detail)
    }

    /**
     * **Nothing is collected until somebody asks for it, and Clear does not stop
     * it.**
     *
     * The first half is the surveillance rule: a recorder that can be running
     * without being started is not a feature. The second is `browser-view:record-
     * clear`'s own behaviour — clearing is *start again from here*, which is what
     * somebody does after a false start, and it re-seeds the beginning because a
     * flow with no first line cannot be replayed.
     */
    func testNothingIsCollectedUntilItIsStartedAndClearKeepsItRunning() {
        let flow = PhoneClickFlow(now: { 1_000 })
        flow.at(tab: "t1", url: "http://127.0.0.1:52311/")
        flow.note(Self.step(kind: "click", tag: "button", id: "b1", text: "Before"),
                  url: "http://127.0.0.1:52311/", tab: "t1")
        XCTAssertTrue(flow.steps(tab: "t1").isEmpty)
        XCTAssertFalse(flow.isRecording(tab: "t1"))

        flow.start(tab: "t1")
        flow.note(Self.step(kind: "click", tag: "button", id: "b2", text: "After"),
                  url: "http://127.0.0.1:52311/", tab: "t1")
        XCTAssertEqual(flow.steps(tab: "t1").count, 2)

        flow.clear(tab: "t1")
        XCTAssertTrue(flow.isRecording(tab: "t1"), "Clear empties the flow, it does not end it")
        XCTAssertEqual(flow.steps(tab: "t1").map(\.kind), ["navigate"],
                       "and what is left is where the flow now begins")

        flow.stop(tab: "t1")
        XCTAssertFalse(flow.isRecording(tab: "t1"))
        XCTAssertEqual(flow.steps(tab: "t1").count, 1,
                       "stopping keeps the flow — it is the finished thing somebody is about to "
                       + "hand to an agent")

        flow.forget(tab: "t1")
        XCTAssertTrue(flow.steps(tab: "t1").isEmpty)
    }

    /**
     * **The line handed to an agent is one line, and it is the machine's line.**
     *
     * `flowLine` on the desktop, transcribed. Two claims: it is a single line,
     * because Deck types this into a PTY running a coding CLI and a newline in it
     * submits the prompt half-written; and it is built from the **same**
     * sentences the rows are, so the card that sends a phone flow and the panel
     * that sends a machine flow hand an agent the same words about the same
     * click. Three spellings of one flow is how one of them comes to leak a
     * password the other two redact.
     */
    func testTheFlowGoesToAnAgentAsOneLineInTheMachinesWords() {
        let flow = PhoneClickFlow(now: { 1_000 })
        XCTAssertEqual(flow.line(tab: "t1"), "", "nothing recorded is nothing to hand over")

        flow.at(tab: "t1", url: "http://127.0.0.1:52311/login")
        flow.start(tab: "t1")
        flow.note(Self.step(kind: "type", tag: "input", id: "pass",
                            attributes: ["type": "password", "placeholder": "Password"],
                            extra: ["value": "hunter2-the-real-one"]),
                  url: "http://127.0.0.1:52311/login", tab: "t1")
        flow.note(Self.step(kind: "click", tag: "button", id: "submit", text: "Sign in"),
                  url: "http://127.0.0.1:52311/login", tab: "t1")

        let line = flow.line(tab: "t1")
        XCTAssertFalse(line.contains("\n"),
                       "a newline in this submits the prompt as its first line")
        XCTAssertFalse(line.contains("hunter2"),
                       "the redaction has to hold on every route out of this store, not only on "
                       + "the one the list draws")
        XCTAssertTrue(line.hasPrefix("[browser flow: 1) Go to http://127.0.0.1:52311/login;"))
        XCTAssertTrue(line.contains("2) Type the password into \"Password\" (`#pass`)"))
        XCTAssertTrue(line.hasSuffix("3) Click \"Sign in\" (`#submit`)]"))
    }

    /**
     * **The phone speaks the machine's vocabulary, word for word.**
     *
     * The two recorders draw through the same rows, so a `kind` this side sends
     * that the other side does not know — or a sentence phrased differently for
     * the same click — is a list that describes one action in two languages. That
     * is the exact class of difference he has now pointed at twice.
     *
     * The seven words are `StepKind` in `src/main/browser-steps.ts`; the sentences
     * are `describeStep` in the same file.
     */
    func testTheStepsSpeakTheMachinesVocabulary() {
        XCTAssertEqual(PhoneStep.Kind.allCases.map(\.rawValue),
                       ["navigate", "click", "type", "select", "check", "press", "submit"],
                       "an eighth kind on this side is a row the machine's list cannot draw")
        XCTAssertEqual(PhoneClickFlow.notableKeys, ["Enter", "Escape", "Tab"],
                       "logging every keystroke would bury the flow; these three are how a form "
                       + "is submitted, dismissed and moved through")

        var step = PhoneStep(kind: .click, at: 1)
        step.selector = "#submit"
        step.label = "Sign in"
        step.tag = "button"
        XCTAssertEqual(PhoneClickFlow.describe(step), "Click \"Sign in\" (`#submit`)")

        step.kind = .submit
        XCTAssertEqual(PhoneClickFlow.describe(step), "Submit \"Sign in\" (`#submit`)")

        step.kind = .press
        step.key = "Enter"
        XCTAssertEqual(PhoneClickFlow.describe(step), "Press Enter in \"Sign in\" (`#submit`)")

        step.kind = .check
        step.checked = true
        XCTAssertEqual(PhoneClickFlow.describe(step), "Check \"Sign in\" (`#submit`)")
        step.checked = false
        XCTAssertEqual(PhoneClickFlow.describe(step), "Uncheck \"Sign in\" (`#submit`)")

        // An unnamed element is named by its selector alone, never by a guess.
        var bare = PhoneStep(kind: .click, at: 1)
        bare.tag = "div"
        XCTAssertEqual(PhoneClickFlow.describe(bare), "Click <div>",
                       "an element with no selector and no label is described by what it is, "
                       + "never by a guess at what it might be called")
    }

    /**
     * **A field is named by what names it, and a button by what is written on it.**
     *
     * Two rules, and the first exists because both obvious fallbacks were measured
     * wrong on a real page: a capture falls back to an element's live value, which
     * labels the email box with the email address, and a `<select>`'s text content
     * is the concatenation of its own options — the city picker in that probe came
     * back named `DubaiLahore`.
     */
    func testAFieldIsNamedByWhatNamesItAndNotByItsContents() {
        let flow = PhoneClickFlow(now: { 1_000 })
        flow.at(tab: "t1", url: "http://127.0.0.1:52311/")
        flow.start(tab: "t1")

        flow.note(Self.step(kind: "type", tag: "input", id: "email",
                            attributes: ["placeholder": "Email", "value": "asad@example.com"],
                            extra: ["value": "asad@example.com"]),
                  url: "http://127.0.0.1:52311/", tab: "t1")
        XCTAssertEqual(flow.steps(tab: "t1").last?.detail,
                       "Type \"asad@example.com\" into \"Email\" (`#email`)",
                       "the field is named by its placeholder — named by its own value it would "
                       + "read \"into asad@example.com\"")

        flow.note(Self.step(kind: "select", tag: "select", id: "city",
                            attributes: ["name": "city"], text: "DubaiLahore",
                            extra: ["value": "Lahore"]),
                  url: "http://127.0.0.1:52311/", tab: "t1")
        XCTAssertEqual(flow.steps(tab: "t1").last?.detail,
                       "Choose \"Lahore\" in \"city\" (`#city`)",
                       "a picker is not named by the list of things in it")
    }

    /// One payload from the page-side recorder, shaped exactly as
    /// `PhoneRecordScript` sends one. Written here rather than in the script so
    /// that a change to either side has to be made twice on purpose.
    private static func step(kind: String,
                             tag: String,
                             id: String,
                             attributes: [String: Any] = [:],
                             text: String = "",
                             extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "v": 1,
            "kind": kind,
            "target": [
                "v": 1,
                "path": [["tag": tag, "id": id, "idUnique": true,
                          "nthOfType": 1, "ofTypeCount": 1]],
                "text": text,
                "attributes": attributes,
            ] as [String: Any],
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
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
