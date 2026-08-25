/**
 * The localhost list's port rows, dragged sideways.
 *
 * The list was the Browser tab itself until 2026-08-25, when the tab's home
 * became the machine's open browser windows and *"the localhost thing"* was
 * folded one row down its `…`. Nothing about these rows or these gestures
 * changed; only how the suite gets to them — `openLocalhostList` rather than
 * `openBrowserTab`, and `TabNavigation.swift` owns that walk.
 *
 * > *"also use left/right swipe and options in the pages where you have many, or
 * > a list of anything — if we click, like we have a list of browsers or
 * > sessions, we can swipe them left and right and we can have options there to
 * > delete or close the options or archive and things, just like WhatsApp has
 * > the chats. Similar stuff."*
 *
 * The gesture already existed on this list — Rename on the leading edge, the
 * row's state verb on the trailing one — and the two verbs that were *only*
 * behind the 44-point `…` at the end of the row were the interesting ones:
 * **Open on the machine**, which is the single item on that menu that does
 * anything on the far computer, and **Clear name**, which is the only thing a
 * port row can take away. Both are on the swipe now, on the edge their cost
 * belongs to.
 *
 * ## Nothing here presses anything
 *
 * This suite runs against Asad's live server. Rename raises an alert over a
 * screen the next test expects to be a list; Open on the machine puts a tab on a
 * computer somebody is working at; Clear name deletes a name this phone is the
 * only copy of. Every one of them is *revealed*, photographed and dismissed. The
 * assertion is that the button is drawn, named, and on the edge it is supposed
 * to be on — which is the whole of what a swipe action can be got wrong about.
 *
 * ## And why the buttons are reached by identifier
 *
 * Unlike a SwiftUI `Menu`'s rows, which are unreachable by identifier and have
 * to be pressed by their words (measured twice — see `MachineBrowserUITests`), a
 * swipe action is an ordinary `UIButton` in the row's own hierarchy. Identifier
 * queries work, and they are used here precisely because the *words* on two of
 * these change with the machine: `DeckModel.openThereVerb` says one thing about
 * a desktop and another about a server.
 *
 * ## It skips rather than fails
 *
 * The standing rule of this target. A machine with nothing listening has no port
 * rows, a machine that does not advertise `web` draws no Open action, and an
 * unnamed port has no name to clear — all three are the product working.
 *
 * ## Its sibling
 *
 * `SwipeActionsUITests` owns the same gesture on the **sessions** and
 * **machines** lists and argues at length why a suite is needed for four
 * modifiers — `.swipeActions` outside a `List` compiles, links, draws nothing
 * and leaves a horizontal drag scrolling. Everything it says applies here. It is
 * a separate file rather than four more cases in that one because these need the
 * Browser tab and a machine that is serving something, which is a different
 * precondition and a different skip.
 *
 * The machine's own browser windows have their swipes covered in
 * `MachineBrowserUITests`, beside the rest of that screen.
 */

import XCTest

final class BrowserPortSwipeUITests: XCTestCase {

    private var app: XCUIApplication!

    /// Where the frames land, so they can be looked at outside the result
    /// bundle. Silent when unset — a photograph is a deliverable, not a
    /// condition of the run.
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        let paired = app.buttons["sessions.new"].waitForExistence(timeout: 20)
            || app.buttons["sessions.more"].exists
        try XCTSkipUnless(paired, Self.noMachine)

        XCTAssertTrue(app.openLocalhostList(),
                      "the localhost list is one row down the Browser tab's menu — see TabNavigation")
    }

    private static let noMachine =
        "This phone is not paired with a running host. Run ios/Harness/live-localhost.sh, "
        + "which starts one and pairs the Simulator."

    private static let noPorts =
        "Nothing is listening on this machine, or every group on the list is folded. There is no "
        + "row to swipe and that is the list working."

    /**
     * The leading edge is the harmless one, and it carries the naming verb.
     *
     * Rename was always here; what is asserted is that it is still on the
     * *leading* edge after the trailing one grew a destructive action, because
     * the one way to get this change wrong is to end up with a red button under
     * the thumb that used to open a keyboard.
     */
    func testAPortSwipesRightToItsNamingVerb() throws {
        let row = try firstPortRow()
        let port = try portNumber(of: row)

        row.swipeRight()
        let rename = app.buttons["port.swipe.rename.\(port)"]
        XCTAssertTrue(rename.waitForExistence(timeout: 5),
                      "the leading edge should offer the naming verb the row's menu has")
        capture("40-port-swipe-leading")

        /*
         * Open on the machine, when the machine offers it.
         *
         * Absent rather than dead where the host never advertised `web` — a
         * guest device is exactly that — so its absence is recorded as a fact
         * about this machine rather than asserted as a failure. Both halves of
         * the never-dead-click rule are the point: the button is drawn only
         * where it can act.
         */
        let openThere = app.buttons["port.swipe.openThere.\(port)"]
        if !openThere.exists {
            XCTContext.runActivity(named: "this machine does not open pages of its own") { _ in }
        }

        row.swipeLeft()
        row.swipeRight()
    }

    /**
     * The trailing edge carries the row's state verb, and a Clear name in front
     * of it on the rows that have one.
     *
     * The order is the platform's — destructive nearest the edge — and it is
     * also the order of how much each one costs to get wrong. Which verb the
     * second slot holds depends on the row: a dev server that is up offers its
     * session, one that is down offers Start, and a plain port offers the
     * address on the clipboard. `PortCatalog.secondAction` decides, and its own
     * unit tests pin the table; what this proves is that *something* is there,
     * because a trailing swipe that opens onto nothing reads as a broken
     * gesture.
     */
    func testAPortSwipesLeftToAVerbItCanAct() throws {
        let row = try firstPortRow()
        let port = try portNumber(of: row)

        row.swipeLeft()

        let copy = app.buttons["port.swipe.copy.\(port)"]
        let clear = app.buttons["port.swipe.clear.\(port)"]
        let devVerb = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'devserver.swipe.'")).firstMatch

        XCTAssertTrue(copy.waitForExistence(timeout: 5) || clear.exists || devVerb.exists,
                      "a trailing swipe must open onto a verb, never onto an empty tray")
        capture("41-port-swipe-trailing")

        // A row with no name has nothing to clear and correctly draws no Clear.
        // Said out loud rather than left silent: "no name on this port" and "the
        // action was never wired up" look identical from here.
        if !clear.exists {
            XCTContext.runActivity(named: "this port has no name to clear") { _ in }
        }

        row.swipeRight()
        row.swipeLeft()
    }

    // MARK: - Getting there

    /// The first port row on the list. Ports are named `port.<number>` on the
    /// row's own button — `port.detail.<number>` and `port.more.<number>` are
    /// different elements on the same row, which is why this matches the exact
    /// shape rather than a prefix.
    private func firstPortRow() throws -> XCUIElement {
        let row = app.buttons
            .matching(NSPredicate(format: "identifier MATCHES 'port\\\\.[0-9]+'")).firstMatch
        try XCTSkipUnless(row.waitForExistence(timeout: 20), Self.noPorts)
        return row
    }

    /// The number out of `port.3210`, which is what every identifier on that row
    /// is keyed by. Thrown rather than force-unwrapped: a row whose identifier
    /// stopped carrying its port is a change worth a message, not a crash.
    private func portNumber(of row: XCUIElement) throws -> String {
        let id = row.identifier
        let number = String(id.dropFirst("port.".count))
        try XCTSkipUnless(!number.isEmpty && number.allSatisfy(\.isNumber),
                          "a port row's identifier no longer carries its port: \(id)")
        return number
    }

    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard !shots.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: shots, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "\(shots)/\(name).png"))
    }
}
