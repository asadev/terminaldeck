/**
 * The swipe on a row, on both lists that have rows, driven rather than described.
 *
 * Asad, on 2026-08-24:
 *
 * > *"also use left/right swipe and options in the pages where you have many, or
 * > a list of anything — if we click, like we have a list of browsers or
 * > sessions, we can swipe them left and right and we can have options there to
 * > delete or close the options or archive and things, just like WhatsApp has
 * > the chats. Similar stuff."*
 *
 * ## Why a suite, when the view code is four modifiers
 *
 * Because `.swipeActions` is the modifier in this app with the largest gap
 * between *compiles* and *works*. Outside a `List` it builds, links, draws
 * nothing at all, and leaves a horizontal drag scrolling — which is exactly the
 * state he objected to on the session list: *"swipe currently just opens the
 * session, which tapping already does."* Nothing in a build log says so and the
 * view code reads correctly. The only thing that can tell the two apart is a
 * finger, so these cases assert on **the buttons the gesture revealed** rather
 * than on a screenshot or on the row surviving.
 *
 * The machines list is the newer half and it is the one this suite exists for:
 * it was a `ScrollView` of a `LazyVStack` until the swipes went on, so every one
 * of these assertions was false the day before it was written.
 *
 * ## Nothing here destroys anything, and that is not squeamishness
 *
 * This target runs against Asad's real server. A case that closed a session
 * would kill work in progress on a machine somebody is using, and a case that
 * forgot a machine would unpair the phone the rest of the run needs. So the two
 * destructive verbs are taken as far as their confirmation and then **declined**
 * — which is the more valuable assertion anyway: a Cancel that still fired would
 * pass every test that only checked the alert appeared.
 *
 * `ReviewScreensUITests` has one case that does close a session for real, on
 * purpose, against the disposable stand-in. That is the right place for it and
 * this is not.
 *
 * ## And two cases that are not about swiping at all
 *
 * `testEveryPillIsStillAddressableByItsName`. The tab bar lost its words on the
 * same day these gestures went on — *"only icons are good enough"* — and every
 * case below reaches its list by pressing a pill by name. If that stops working
 * the nine failures underneath it are one failure, said nine times, about the
 * wrong thing. So it is asserted first and separately.
 *
 * `testTheSessionListsPlusAndDotsShareOnePillOnTheRight`, for the same reason
 * with the geometry one level up: every case below stands on the session list,
 * and its navigation bar is a frame claim of exactly the kind this suite is
 * built to make with a finger rather than to read off a placement constant. Its
 * own comment carries what went wrong the round before it was written.
 *
 * ## It skips rather than fails with nothing paired
 *
 * The standing rule of this target. A suite that failed on a laptop with no host
 * running is a suite nobody runs, and every case here needs a machine at the
 * other end — a swipe needs a row and a row needs a pairing.
 *
 *     ios/Harness/run.sh host --approve-after 3000 \
 *         --rendezvous wss://relay.terminaldeck.dev --folders /tmp/td-devdemo &
 *     xcodebuild test -project ios/TerminalDeck.xcodeproj -scheme TerminalDeck \
 *       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
 *       -only-testing:TerminalDeckUITests/SwipeActionsUITests
 */

import XCTest

final class SwipeActionsUITests: XCTestCase {

    private var app: XCUIApplication!

    /// The stand-in's control server, which mints a pairing code on demand. The
    /// same default `SessionDetailUITests` uses, overridable for a run pointed
    /// at a host on another port.
    private var control: URL {
        let where_ = ProcessInfo.processInfo.environment["TD_CONTROL"] ?? "127.0.0.1:8788"
        return URL(string: "http://\(where_)") ?? URL(string: "http://127.0.0.1:8788")!
    }

    /// Where the frames land, so a revealed swipe can be *looked at* rather than
    /// only asserted. Silent when unset — a photograph is a deliverable here,
    /// not a condition of the run. The same `TD_SHOTS` every other suite in this
    /// target reads.
    private var shots: String { ProcessInfo.processInfo.environment["TD_SHOTS"] ?? "" }

    /// Remembered across cases, so a run with nothing listening pays the pairing
    /// timeout once rather than once per case.
    private static var reachable: Bool?

    private static let notRunning =
        "No paired machine. Start ios/Harness/run.sh host --approve-after 3000 "
        + "--rendezvous wss://relay.terminaldeck.dev and run again."

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(Self.reachable == false, Self.notRunning)

        app = XCUIApplication()
        app.launch()

        // A pairing outlives the process, so the common case on a second run is
        // a phone that is already in and has no field to type into.
        if app.reachPairingField(timeout: 5) {
            guard let data = try? Data(contentsOf: control.appendingPathComponent("pair")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["code"] as? String else {
                Self.reachable = false
                throw XCTSkip(Self.notRunning)
            }
            let field = app.textFields["pairing.field"]
            field.tap()
            field.typeText(code)
            let submit = app.buttons["pairing.submit"]
            if submit.exists && submit.isHittable { submit.tap() }
        }

        let connected = waitForConnected(timeout: Self.reachable == nil ? 45 : 15)
        Self.reachable = connected
        try XCTSkipUnless(connected, Self.notRunning)
    }

    // MARK: - The bar the swipes are reached through

    /**
     * Every pill is still addressable by its name, with no name drawn on it.
     *
     * > *"no need to give the titles like Copilot, Browser, Sessions or Terminal
     * > or Menu or things — only icons are good enough."*
     *
     * That was done by taking the `Text` out of each `.tabItem`, which removes
     * the `UITabBarItem`'s `title` — the string VoiceOver reads and the string
     * `TabNavigation.swift` finds a tab by on behalf of twenty-odd cases in this
     * target. What replaces it is an `.accessibilityLabel` inside the item, and
     * the whole risk of that swap is that it is invisible when it fails: the bar
     * looks perfect in a screenshot and every suite that presses a tab dies on
     * the first line with a sentence about the screen it never reached.
     *
     * So this is the guard, and it lives in this suite rather than in a tab suite
     * because every case below reaches its list through one of these pills. It is
     * also the reason it is the *first* case here: if it fails, the nine
     * failures after it are one failure.
     *
     * The copilot is checked only when it is there. *"If the copilot is not
     * connecting, this icon should not be inside the pill — then it will be three
     * icon pill."* A phone paired as a guest has three, which is correct rather
     * than a failure.
     */
    func testEveryPillIsStillAddressableByItsName() throws {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 20), "there should be a tab bar")

        for name in ["Sessions", "Browser", "Menu"] {
            let pill = bar.buttons[name]
            XCTAssertTrue(pill.exists,
                          "\(name) must stay findable by name — its title is gone and only "
                          + "its accessibility label is holding it up")
            XCTAssertTrue(pill.isHittable, "and pressable")
        }
        // Conditional, and asserted rather than skipped over: a Copilot pill that
        // is drawn but nameless is the same defect as a nameless Menu.
        if bar.buttons.count == 4 {
            XCTAssertTrue(bar.buttons["Copilot"].exists,
                          "a fourth pill has to be the copilot, by name")
        }
        capture("00-the-pill")
    }

    /**
     * **The session list's `+` and `…` are one pill on the right, `+` first.**
     *
     * > *"This plus button and three dots thing — which I said it will stay on
     * > left and three dot will be on right — what I meant is they should stay
     * > together like before, but like both will be on right side, one pill. But
     * > inside the pill, three dot will be on right side and plus button will be
     * > on left side."*
     *
     * The second of the two cases in this suite that are not about swiping, and
     * it is here for the same reason the first one is: every case below reaches
     * a row through this screen, so the suite is already standing on it, and a
     * navigation bar is a geometry claim of exactly the kind these cases are
     * built to make with a finger.
     *
     * **Two assertions, and the second is the one that would have caught the
     * mistake.** The round before this read his earlier sentence — *"the plus
     * button should be left and three dots should be on the right side"* — as
     * the two edges of the navigation bar and split the pair into a leading
     * group and a trailing one. An ordering check alone passes against that: a
     * `+` in the far-left corner really is left of a `…` in the far-right one.
     * So the side is asserted as well, against the bar's own midpoint.
     *
     * `MachineBrowserUITests.testThePlusAndTheDotsShareOnePillOnTheRight` is the
     * same pair of claims about the Browser tab, which he named in the same
     * breath. The two screens have to agree, and two cases that can disagree
     * about it are how they came to.
     */
    func testTheSessionListsPlusAndDotsShareOnePillOnTheRight() throws {
        try openTheSessionList()
        let more = app.buttons["sessions.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 20),
                      "the list always draws its overflow, whatever the machine offers")

        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.exists, "there should be a navigation bar to measure against")

        // Absent on a machine that has granted this device no folder, which is a
        // real state and not a failure — `DeckModel.canStartSomewhere`. The
        // overflow above is the part that is always there.
        let plus = app.buttons["sessions.new"]
        guard plus.exists else {
            XCTAssertGreaterThan(more.frame.minX, bar.frame.midX,
                                 "the overflow belongs on the trailing edge on its own too")
            return
        }
        XCTAssertLessThan(plus.frame.minX, more.frame.minX,
                          "inside the pill the plus is on the left and the dots on the right")
        XCTAssertGreaterThan(plus.frame.minX, bar.frame.midX,
                             "both controls belong in one pill on the trailing edge — a plus in the "
                             + "leading corner is the split he asked to have undone")
    }

    // MARK: - The sessions

    /**
     * The trailing swipe on a session: Close, Archive, Details — and Close asks.
     *
     * The order is asserted rather than assumed, because SwiftUI lays a trailing
     * swipe out **from the edge inwards**: the first-declared action is the one
     * drawn furthest right, which is the opposite of how the view body reads and
     * is exactly the kind of thing a reader of that file gets backwards. The
     * outermost action is the one a thumb coming off the screen edge reaches
     * first, so it has to be the one that has to be most deliberate.
     *
     * Close is asserted to *exist* against these hosts because both of them
     * advertise the `close` capability — the stand-in imports `CAPABILITIES`
     * from the desktop's own protocol module — so a swipe with no Close on it
     * here is a capability that stopped being read rather than a host that
     * cannot end a session. Against a machine that withheld it the action is
     * correctly absent, which is a thing no simulator can be pointed at: the
     * unit suite of the same name — `ios/Tests/SwipeActionsTests.swift` — models
     * the machine that says no, and the machine that says yes and then goes
     * offline.
     */
    func testTheTrailingSwipeOnASessionOffersCloseArchiveAndDetails() throws {
        try openTheSessionList()
        let row = firstSessionRow()
        try XCTSkipUnless(row.waitForExistence(timeout: 12),
                          "nothing is running on the machine, so there is no row to swipe")

        app.swipeTrailing(row)

        let close = swipeAction("session.swipe.close.")
        XCTAssertTrue(close.waitForExistence(timeout: 5),
                      "a left swipe should reveal Close, not scroll the list")
        let archive = swipeAction("session.swipe.archive.")
        XCTAssertTrue(archive.exists, "and Archive beside it")
        let details = swipeAction("session.swipe.details.")
        XCTAssertTrue(details.exists, "and the sheet the long press opens")

        XCTAssertGreaterThan(close.frame.minX, archive.frame.minX,
                             "Close is the outermost action, with the reversible one inside it")
        XCTAssertGreaterThan(archive.frame.minX, details.frame.minX,
                             "and the harmless one innermost")
        capture("01-session-trailing")
    }

    /**
     * Close asks, and Cancel means it.
     *
     * *"Close the session (with a confirmation)."* Two claims, and the second is
     * the one worth a case: a confirmation whose Cancel still closed the session
     * would satisfy every test that only checked the alert came up. So the alert
     * is opened, declined, and the row is asserted to still be on the list
     * afterwards — with its id captured first, because "a row exists" is not the
     * same claim as "the row I swiped exists" on a list the machine reorders.
     */
    func testCancellingTheCloseLeavesTheSessionExactlyWhereItWas() throws {
        try openTheSessionList()
        let row = firstSessionRow()
        try XCTSkipUnless(row.waitForExistence(timeout: 12),
                          "nothing is running on the machine, so there is no row to swipe")
        let identifier = row.identifier

        app.swipeTrailing(row)
        let close = swipeAction("session.swipe.close.")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()

        let confirm = app.alerts.firstMatch.buttons["close.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "Close should ask before it does anything")
        capture("02-session-close-confirmation")
        app.alerts.firstMatch.buttons["Cancel"].firstMatch.tap()

        XCTAssertTrue(app.buttons[identifier].waitForExistence(timeout: 10),
                      "declining should leave the session running and listed")
    }

    /// The leading swipe: one action, and it is the harmless one. Pinned and then
    /// unpinned, so the list is left in the state the case found it in — a pin is
    /// stored per machine on this phone and survives the process.
    func testTheLeadingSwipeOnASessionPinsAndUnpinsIt() throws {
        try openTheSessionList()
        let row = firstSessionRow()
        try XCTSkipUnless(row.waitForExistence(timeout: 12),
                          "nothing is running on the machine, so there is no row to swipe")

        app.swipeLeading(row)
        let pin = swipeAction("session.swipe.pin.")
        XCTAssertTrue(pin.waitForExistence(timeout: 5),
                      "a right swipe should reveal Pin, not scroll the list")
        XCTAssertEqual(pin.label, "Pin", "an unpinned row offers the pin")
        capture("03-session-leading")
        pin.tap()

        let pinnedRow = firstSessionRow()
        XCTAssertTrue(pinnedRow.waitForExistence(timeout: 10))
        app.swipeLeading(pinnedRow)
        let unpin = swipeAction("session.swipe.pin.")
        XCTAssertTrue(unpin.waitForExistence(timeout: 5))
        XCTAssertEqual(unpin.label, "Unpin", "and a pinned one offers the undo in the same place")
        unpin.tap()
    }

    // MARK: - The machines

    /**
     * The leading swipe on a machine: rename, and it names the machine.
     *
     * ## Why the two edges are two cases and not one
     *
     * They were one, and it failed — not on the app but on the test. Opening one
     * edge and then the other on the same row needs the first set **closed**
     * first, and closing an open row from XCUITest is its own problem: a drag
     * back the way it came sometimes opens the opposite edge instead, and a tap
     * on the row is the gesture UIKit uses to dismiss a swipe but would select
     * the machine if it ever did not. Neither is the thing under test. `setUp`
     * relaunches the app for every case, which closes any open row for free — so
     * two cases is the arrangement where each gesture is the first thing that
     * happens to a fresh screen.
     *
     * Nothing gates this action, and that is honest rather than lazy: every
     * machine on this list can be renamed, because the label is stored on this
     * phone. Unlike the session's Close there is no capability that could take it
     * away, which is why there is no conditional case beside this one.
     */
    func testTheLeadingSwipeOnAMachineOffersRename() throws {
        try XCTSkipUnless(app.openMachinesTab(), "the machines screen never opened")
        let row = firstMachineRow()
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "a connected phone has at least one machine")
        capture("04-machines-list")

        app.swipeLeading(row)
        let rename = swipeAction("machine.swipe.rename.")
        XCTAssertTrue(rename.waitForExistence(timeout: 5),
                      "a right swipe should reveal Rename, not scroll the list")
        XCTAssertTrue(rename.label.hasPrefix("Rename "),
                      "and name the machine it is about, for a phone paired with three")
        capture("05-machine-leading")
    }

    /**
     * The trailing swipe on a machine: Forget outermost, the machine's own screen
     * inside it.
     *
     * The order is measured rather than assumed, because SwiftUI lays a trailing
     * swipe out from the edge inwards — the first-declared action is drawn
     * furthest right, which is the opposite of how the view body reads. The
     * outermost one is what a thumb coming off the screen edge reaches first, so
     * it has to be the one that has to be most deliberate.
     */
    func testTheTrailingSwipeOnAMachineOffersForgetAndItsOwnScreen() throws {
        try XCTSkipUnless(app.openMachinesTab(), "the machines screen never opened")
        let row = firstMachineRow()
        XCTAssertTrue(row.waitForExistence(timeout: 10),
                      "a connected phone has at least one machine")

        app.swipeTrailing(row)
        let forget = swipeAction("machine.swipe.forget.")
        XCTAssertTrue(forget.waitForExistence(timeout: 5),
                      "a left swipe should reveal Forget, not scroll the list")
        XCTAssertTrue(forget.label.hasPrefix("Forget "),
                      "and name the machine it is about")
        let about = swipeAction("machine.swipe.about.")
        XCTAssertTrue(about.exists, "and the machine's own screen inside it")
        XCTAssertGreaterThan(forget.frame.minX, about.frame.minX,
                             "Forget is the outermost action, with the harmless one inside it")
        capture("06-machine-trailing")
    }

    /**
     * Forget asks — which it did not do until the swipe was built.
     *
     * It was wired straight to `unpair` from the row's `…` menu: one tap and the
     * machine was gone. That was survivable while a menu was the only way to
     * reach it and is not survivable next to a gesture a thumb can finish. Both
     * doors call the row's one `forget` closure, so this case is also what pins
     * that the menu did not keep its old behaviour.
     *
     * Declined, and then the machine is asserted to still be paired — by the
     * connection rather than by the row, because a row is drawn from a list this
     * screen would still hold for a moment after an unpair.
     */
    func testCancellingTheForgetLeavesTheMachinePaired() throws {
        try XCTSkipUnless(app.openMachinesTab(), "the machines screen never opened")
        let row = firstMachineRow()
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        app.swipeTrailing(row)
        let forget = swipeAction("machine.swipe.forget.")
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        forget.tap()

        let confirm = app.alerts.firstMatch.buttons["forget.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "Forget should ask before it unpairs a computer")
        capture("07-machine-forget-confirmation")
        app.alerts.firstMatch.buttons["Cancel"].firstMatch.tap()
        capture("08-machine-after-cancel")

        /*
         * The connection, not the row.
         *
         * A row assertion stood here and it was wrong twice over. It is too weak
         * — a `HostLink` is dropped and the list redrawn on the following frame,
         * so "the row is still there" is briefly true either way — and it is
         * also unstable, because a row that was swiped open when the alert went
         * up is still swiped open underneath it, and most of that row is off the
         * screen. It failed once against an app that had plainly not forgotten
         * anything, which is a test making its own news.
         */
        assertStillPaired()
    }

    /**
     * The same menu item, through the menu, so the two doors cannot drift apart.
     *
     * Two different queries, and neither is a matter of taste. The `…` itself is
     * found by **prefix**, because its identifier carries a host id no test can
     * know. Its rows are then found with `app.buttons[…]`, which is the query
     * `TabNavigation.forgetEveryMachine` has always used for this menu and the
     * one that works: a presented `Menu` puts its rows in a layer of their own,
     * and the narrower `descendants(matching:).matching(identifier:)` form —
     * which is what finds the *swipe* buttons above — has been measured coming
     * back empty against them.
     */
    func testTheMenusForgetAsksTheSameQuestionAsTheSwipe() throws {
        try XCTSkipUnless(app.openMachinesTab(), "the machines screen never opened")
        let menu = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'machine.more.'"))
            .firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()

        let forget = app.buttons["machine.forget"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5), "the row menu should still offer Forget")
        forget.tap()

        let confirm = app.alerts.firstMatch.buttons["forget.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "the menu goes through the same confirmation the swipe does")
        app.alerts.firstMatch.buttons["Cancel"].firstMatch.tap()
        assertStillPaired()
    }

    /**
     * A drag all the way across a machine row does not forget it.
     *
     * This is the defect the codebase keeps finding written as a test:
     * `allowsFullSwipe` defaults to **true**, and with it a drag that carries
     * past the row's edge fires the first action on release without the finger
     * ever landing on a button. On this edge the first action unpairs a computer.
     *
     * The gesture is a press-and-drag from the right edge of the screen to well
     * past its left, which is what a hurried thumb does and what `swipeLeft()`
     * is too short to reproduce.
     *
     * The failure is one-sided on purpose. Only *"the confirmation came up"* is
     * asserted; a drag that turns out to be too slow or too short to have been a
     * full swipe **skips** rather than passes, because a green tick for a
     * gesture that never happened is the shape of test that lets the defect back
     * in. The proof that it happened is the actions being revealed underneath.
     */
    func testAFullDragAcrossAMachineRowRevealsForgetRatherThanFiringIt() throws {
        try XCTSkipUnless(app.openMachinesTab(), "the machines screen never opened")
        let row = firstMachineRow()
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        app.dragAcross(row, from: 0.97, to: -0.5)

        let fired = app.alerts.firstMatch.buttons["forget.confirm"].firstMatch
            .waitForExistence(timeout: 3)
        // Taken down first, so a failure does not leave a modal standing over
        // every case that runs after this one.
        if fired { app.alerts.firstMatch.buttons["Cancel"].firstMatch.tap() }
        XCTAssertFalse(fired, "a full swipe must not be able to reach Forget on its own")
        try XCTSkipUnless(swipeAction("machine.swipe.forget.").exists,
                          "the drag did not reach the actions, so nothing was proved")
        assertStillPaired()
    }

    /**
     * And the same drag on a session row does not close it.
     *
     * The session list has had `allowsFullSwipe: false` on both edges since it
     * became a `List`; this is the regression test for the day somebody removes
     * the argument because "the default is fine".
     */
    func testAFullDragAcrossASessionRowRevealsCloseRatherThanFiringIt() throws {
        try openTheSessionList()
        let row = firstSessionRow()
        try XCTSkipUnless(row.waitForExistence(timeout: 12),
                          "nothing is running on the machine, so there is no row to swipe")

        app.dragAcross(row, from: 0.97, to: -0.5)

        let fired = app.alerts.firstMatch.buttons["close.confirm"].firstMatch
            .waitForExistence(timeout: 3)
        if fired { app.alerts.firstMatch.buttons["Cancel"].firstMatch.tap() }
        XCTAssertFalse(fired, "a full swipe must not be able to reach Close on its own")
        try XCTSkipUnless(swipeAction("session.swipe.close.").exists,
                          "the drag did not reach the actions, so nothing was proved")
    }

    // MARK: - Getting there

    private func openTheSessionList() throws {
        app.openSessionsTab()
        try XCTSkipUnless(app.buttons["sessions.more"].waitForExistence(timeout: 20),
                          "the session list never came up")
    }

    /**
     * A swipe action by the prefix of its identifier.
     *
     * By prefix because every one of these identifiers ends in an id minted by
     * the machine — a session id, a host id — which no test can know. Swipe
     * buttons *are* reachable by identifier, unlike a `Menu`'s rows; the note on
     * `testTheMenusForgetAsksTheSameQuestionAsTheSwipe` has the measurement.
     *
     * `descendants(matching: .any)` rather than `buttons`, for the reason the
     * menu helpers in `TabNavigation.swift` give: a swipe action is presented in
     * a layer of its own and the plain element-type query has been seen to miss
     * it on iOS 26.
     */
    private func swipeAction(_ prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .firstMatch
    }

    /// The first session card. By prefix, and excluding the swipe buttons, which
    /// carry the same session id inside a longer identifier.
    private func firstSessionRow() -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'session.' AND NOT identifier CONTAINS 'swipe'"))
            .firstMatch
    }

    /**
     * The first machine card.
     *
     * A row is `machine.<hostId>`; the other four elements on it are
     * `machine.about.<id>`, `machine.more.<id>` and the two swipe buttons. A host
     * id is upper-case base32 minted at pairing time, so excluding those three
     * lower-case words cannot exclude a real row — which is the reason this is
     * written as an exclusion rather than as a regular expression that would have
     * to encode the id's alphabet.
     */
    private func firstMachineRow() -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: """
                identifier BEGINSWITH 'machine.' \
                AND NOT identifier CONTAINS 'more' \
                AND NOT identifier CONTAINS 'about' \
                AND NOT identifier CONTAINS 'swipe'
                """))
            .firstMatch
    }

    /**
     * A frame, attached to the result bundle and written out beside it.
     *
     * A swipe is the one thing in this app that has to be seen as well as
     * measured: `.swipeActions` outside a `List` compiles and draws nothing, and
     * the assertions above would catch that — but they would not catch a Close
     * that came out in the app's ordinary blue instead of red, which is exactly
     * what happened the first time the session list's was built and was visible
     * only in the first frame the simulator took.
     */
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

    /**
     * Still paired — asked where the answer actually is.
     *
     * **Not on the Machines screen.** The connection element lives in the
     * navigation title of the Sessions and Browser tabs, inside `HostSwitcher`;
     * the Machines screen has a plain title and no pill at all. Waiting for one
     * there simply times out, which is how two cases in this suite failed on
     * their first run while the app was behaving perfectly — the machine was
     * still paired, still connected, and the proof was one tab away.
     *
     * A row on the list is not the proof either: a `HostLink` is dropped and the
     * list redrawn on the next frame, so "the row is still there" is true for a
     * moment either way. The connection is the fact worth asserting.
     */
    private func assertStillPaired() {
        app.openSessionsTab()
        XCTAssertTrue(waitForConnected(timeout: 30),
                      "declining should leave the machine paired and connected, not merely drawn")
    }

    /// The connection element, which every suite in this target waits on to know
    /// a machine is answering. A `UIView` rather than a SwiftUI element on
    /// purpose — see `ConnectionPill` for why that had to be true.
    private func waitForConnected(timeout: TimeInterval) -> Bool {
        let pill = app.descendants(matching: .any).matching(identifier: "connection.pill").firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pill.exists && pill.label.contains("Connected") { return true }
            usleep(500_000)
        }
        return false
    }
}

private extension XCUIApplication {
    /**
     * A press-and-drag across a row — **in the window's coordinates, at the
     * row's height**.
     *
     * Three shapes of this were run before it worked twice in a row, and the two
     * that failed are the reason it is written this way.
     *
     * `XCUIElement.swipeLeft()` and `.swipeRight()` start at the element's own
     * centre, which on a full-width card is far enough in that the gesture is
     * sometimes read as a scroll. `LocalhostGroupingUITests` hit that and
     * open-codes a drag of its own.
     *
     * A drag in the *element's* normalised space fixes that for the session
     * list, where a row is the width of the screen, and quietly does not fix it
     * for the machines: a machine row's tappable body stops where its ⓘ begins,
     * about half way across, so `dx: 0.92` of it is the middle of the screen —
     * a gesture starting nowhere near the trailing edge, which revealed the
     * actions on some runs and scrolled on others. It failed on "a left swipe
     * should reveal Forget" against a screen that swipes correctly under a
     * thumb, which is the worst kind of test.
     *
     * So the horizontal figures are the *window's* and only the height comes
     * from the row. That is what a thumb does — it starts at the edge of the
     * phone, not at the edge of whatever element happens to be under it — and it
     * is identical for both lists. Offsets outside `0...1` are legal and are how
     * the full-swipe cases express a drag that carries past the screen edge.
     */
    func dragAcross(_ row: XCUIElement, from: CGFloat, to: CGFloat) {
        let height = frame.height
        guard height > 0 else { return }
        let y = row.frame.midY / height
        let start = coordinate(withNormalizedOffset: CGVector(dx: from, dy: y))
        let end = coordinate(withNormalizedOffset: CGVector(dx: to, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// From the trailing edge inwards, which is what reveals the destructive
    /// action.
    func swipeTrailing(_ row: XCUIElement) {
        dragAcross(row, from: 0.94, to: 0.08)
    }

    /// And from the leading edge, which reveals the harmless one.
    func swipeLeading(_ row: XCUIElement) {
        dragAcross(row, from: 0.06, to: 0.92)
    }
}
