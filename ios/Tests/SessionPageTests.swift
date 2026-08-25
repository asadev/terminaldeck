/**
 * The page in a session: the two pure facts the split rests on.
 *
 * Everything else about this feature is a screenshot — whether a page arrives
 * over a terminal, whether folding leaves the cast running — and lives in
 * `SessionPageUITests`. Two things are arithmetic, and both are the kind that
 * fails silently if it is wrong:
 *
 *  1. **The height the canvas reports is a fixed point of the fit.** The black
 *     area under a page is deleted rather than decorated: the canvas says how
 *     tall the picture is and the screen hands it exactly that. If that were not
 *     a fixed point the pane would resize on every frame, the terminal under it
 *     would send a `resize` on every frame with it, and the whole screen would
 *     shimmer. It converges in one step; this pins that it then stays.
 *  2. **The site line names the host and nothing else.** It is the line somebody
 *     reads before typing a password into a page an agent brought them, so a
 *     value that is not a host must not be drawn as if it were one.
 *  3. **The strip's one control says which of four acts it is carrying.**
 *     `SessionPageVerb` had no test at all, which is the wrong way round: it
 *     exists *because* the screen he photographed had a control describing a
 *     state instead of an act, and it needs no simulator to be wrong.
 *  4. **Who a browser window would be taken from.** Attaching moves a window off
 *     whichever session holds it, silently, so the row that offers it has to say
 *     whose it is. Three screens draw that row; `SessionWindowPicker` is the one
 *     place it is decided.
 *  5. **Whether that row exists at all when the machine has no window open.**
 *     This is the one that shipped wrong. Both menus tested the *list*, so on a
 *     machine whose browser was simply closed the `…` opened onto nothing and
 *     the only way to attach a window to a session was to leave for the Browser
 *     tab and make one first — the walk the menus were added to delete. The
 *     machine being drivable is the condition, and no simulator is needed to
 *     say so.
 *  6. **The page on the phone does not move.** A page this phone is drawing
 *     cannot be handed to an agent — it is rendered here, with this app's
 *     cookies. What a session gets is a *second* window on the machine at the
 *     same address, and every string about it has to say that rather than imply
 *     a handover that cannot happen.
 */

import XCTest
@testable import TerminalDeck

final class SessionPageTests: XCTestCase {

    // MARK: - The height the pane is sized to

    /**
     * Handing the fit its own answer back gives the same answer.
     *
     * The sequence a real screen goes through: the stage is given a generous box,
     * the picture is fitted into it width-first, the canvas reports that height,
     * the screen sizes the stage to it — and the next fit has to land in the same
     * place. A 1280×800 page on a 393-point phone is 245.6 points tall, and the
     * second pass must not shave it.
     */
    func testTheReportedHeightIsAFixedPointOfTheFit() {
        let width: CGFloat = 393
        let generous = CGSize(width: width, height: 700)

        let first = WatchMath.fit(frameW: 1280, frameH: 800, in: generous)
        XCTAssertEqual(first.width, width, "a wide page is fitted to the width")

        let second = WatchMath.fit(frameW: 1280, frameH: 800,
                                   in: CGSize(width: width, height: first.height))
        XCTAssertEqual(second.height, first.height, accuracy: 0.5,
                       "sizing the stage to the reported height must not change it")
        XCTAssertEqual(second.width, first.width, accuracy: 0.5,
                       "and must not start letterboxing the sides")

        // A third pass, because a one-step check cannot tell a fixed point from a
        // slow drift.
        let third = WatchMath.fit(frameW: 1280, frameH: 800,
                                  in: CGSize(width: width, height: second.height))
        XCTAssertEqual(third.height, first.height, accuracy: 0.5)
    }

    /**
     * A page taller than it is wide settles against the cap rather than growing.
     *
     * This is the case the cap exists for. The fit is height-limited, so the
     * reported height is whatever box it was given — and if the screen took that
     * as the page's own height with no ceiling, a portrait page would take the
     * whole session screen and the terminal would vanish. Capped, it is a page
     * with its own side bars and a terminal still underneath.
     */
    func testATallPageIsHeightLimitedSoTheCapIsWhatHoldsIt() {
        let box = CGSize(width: 393, height: 440)
        let rect = WatchMath.fit(frameW: 800, frameH: 1280, in: box)
        XCTAssertEqual(rect.height, 440, "a tall page uses every point it is given")
        XCTAssertLessThan(rect.width, box.width, "and letterboxes the sides instead")

        // Handed back its own height, it is unchanged — so a capped pane is stable
        // too, it just does not shrink to the page.
        let again = WatchMath.fit(frameW: 800, frameH: 1280,
                                  in: CGSize(width: box.width, height: rect.height))
        XCTAssertEqual(again.height, rect.height, accuracy: 0.5)
    }

    // MARK: - The line that says where you are

    func testSiteIsTheHostAlone() {
        XCTAssertEqual(MachineBrowserText.site("https://github.com/login?return_to=%2Fsettings"),
                       "github.com")
        XCTAssertEqual(MachineBrowserText.site("http://localhost:5173/deck"), "localhost")
        XCTAssertEqual(MachineBrowserText.site("https://duckduckgo.com/"), "duckduckgo.com")
    }

    /**
     * Anything without a host answers nothing, and the callers draw nothing.
     *
     * A placeholder in the line that says *where you are* reads as a fact, which
     * on this particular line is the difference between checking a site and being
     * reassured about one.
     */
    func testSiteRefusesWhatIsNotAHost() {
        XCTAssertNil(MachineBrowserText.site(""))
        XCTAssertNil(MachineBrowserText.site("about:blank"))
        XCTAssertNil(MachineBrowserText.site("file:///Users/apple/notes.html"))
        XCTAssertNil(MachineBrowserText.site("a window with no page in it yet"))
    }

    // MARK: - The handover bar

    /*
     * *"Claude can ask for the input to put password and put email and then he
     * can continue."* `WatchTests` owns which of the four states this phone
     * believes it is in; these own what the bar does about it, which is the
     * other half and the one where a mistake is visible to a person: a claim
     * button offered to a device that cannot have it is a press that gets
     * refused, and one withheld from the device that could answer is an agent
     * nobody can unblock.
     */

    private func state(asking: Bool = true, mine: Bool = false,
                       taken: Bool? = nil, refusal: String? = nil) -> BrowserHandover {
        BrowserHandover(asking: asking, prompt: "Sign in, then say done.",
                        mine: mine, taken: taken ?? mine, refusal: refusal)
    }

    func testTheClaimIsOfferedToADeviceThatCouldAnswer() {
        XCTAssertEqual(SessionHandover.offer(state()), .claim)
        XCTAssertEqual(SessionHandover.headline(state()), "The agent needs you on this page")
    }

    /// A refusal does not take the way in away — it renames it. This end cannot
    /// know whether the machine's *no* was permanent, and the likeliest one is a
    /// race between the agent's question and the far end being ready to be asked
    /// about it.
    func testARefusedClaimBecomesTryAgainRatherThanNothing() {
        XCTAssertEqual(SessionHandover.offer(state(refusal: "not yet")), .retry)
    }

    /**
     * The second phone: a sentence and nothing to press.
     *
     * Not a disabled button and not a demoted one. The far end refuses a claim
     * on a page that is taken, and the only thing a control here could do is put
     * a second pair of hands into a page somebody is typing a password into —
     * which is what `taken` was added to the frame to prevent. There was a
     * demoted way out while this state was derived rather than told; the field
     * is a fact from the host and needs no hedge.
     */
    func testASecondDeviceIsOfferedNothingOnAPageSomebodyElseHolds() {
        XCTAssertEqual(SessionHandover.offer(state(taken: true)), .elsewhere)
        XCTAssertEqual(SessionHandover.headline(state(taken: true)),
                       "Another device is answering this")
    }

    /// And `taken` outranks a refusal this device is still carrying: once
    /// somebody has the page, *why my last claim failed* is no longer the
    /// interesting fact, and a `Try again` would be a press that cannot succeed.
    func testTakenOutranksAStaleRefusal() {
        XCTAssertEqual(SessionHandover.offer(state(taken: true, refusal: "not yet")), .elsewhere)
    }

    /// Holding the page wins over everything else the state can say — including
    /// a refusal left over from before the grant landed. A device that has it is
    /// never shown a way to take it again.
    func testHoldingThePageOutranksEveryOtherReading() {
        XCTAssertEqual(SessionHandover.offer(state(mine: true, taken: true, refusal: "stale")),
                       .handBack)
        XCTAssertEqual(SessionHandover.headline(state(mine: true)), "You have this page")
    }

    // MARK: - Losing the page

    /**
     * The keyboard has to go when the page stops being this device's, and the
     * shape of *stops being* is the whole reason this is a function.
     *
     * Handing back **ends the question**, so what this screen sees next is not
     * `mine: false` — it is the handover going away. An inline `now.mine ==
     * false` reads nil as *not lost* and leaves the system keyboard up over a
     * page that has just been curtained again: half a phone screen offering to
     * type into something that refuses every keystroke at the source. That is
     * what shipped, and what the harness photographed.
     */
    func testHandingBackCountsAsLosingThePageEvenThoughTheStateVanishes() {
        let held = state(mine: true)
        XCTAssertTrue(SessionHandover.lostThePage(was: held, now: nil),
                      "the question ending is the ordinary way to stop holding the page")
        XCTAssertTrue(SessionHandover.lostThePage(was: held, now: state(taken: true)),
                      "and so is somebody else being given it")
        XCTAssertFalse(SessionHandover.lostThePage(was: held, now: held),
                       "still holding it is not losing it")
        XCTAssertFalse(SessionHandover.lostThePage(was: state(), now: nil),
                       "a question this device never answered was never its page to lose")
    }

    // MARK: - The lock card

    /**
     * The sentence is printed once, and the direction that is *not* visible in a
     * screenshot of this screen is the one that matters more.
     *
     * With a bar above it, the card repeating the agent's sentence verbatim was
     * most of a phone screen spent saying one thing twice. Without a bar — a
     * curtain raised by a password box that nobody was asked about, on a screen
     * that has no bar at all — the card's sentence is the only thing there is,
     * and suppressing it would leave a black rectangle and no explanation.
     */
    func testTheCardSaysTheSentenceOnceAndNeverNotAtAll() {
        let sentence = "Sign in with the account this workspace is billed to."

        let alone = WatchCurtain.card(prompt: sentence, sentenceIsDrawnAbove: false)
        XCTAssertTrue(alone.contains(sentence),
                      "with no bar anywhere, the card is the only explanation there is")

        let withBar = WatchCurtain.card(prompt: sentence, sentenceIsDrawnAbove: true)
        XCTAssertFalse(withBar.contains(sentence), "the bar above is already saying it")
        XCTAssertTrue(withBar.contains(WatchCurtain.shortLine),
                      "but the black rectangle still has to say why it is black")

        // The lock is the part that is true either way: there are no pixels here.
        XCTAssertTrue(alone.hasPrefix(WatchCurtain.lock))
        XCTAssertTrue(withBar.hasPrefix(WatchCurtain.lock))
    }

    // MARK: - The one control on the strip

    /*
     * `SessionPageVerb` decides which of four things the strip's single control
     * is. It shipped with no coverage anywhere, which is backwards for the piece
     * of this feature that exists *because* of a defect somebody photographed:
     *
     * > *"So if we close it, we cannot open it. If I click on it, it is not
     * > opening."*
     *
     * The chevron pointed down and read *fold the page away* over an empty space,
     * because the only fact being read was whether the pane was folded. Three
     * facts decide it. Every combination of them is below — eight rows, because
     * eight is small and the two that matter most, a shown pane over a dead cast
     * and a machine that will never cast, are exactly the ones an example-led
     * test leaves out.
     */

    func testAFoldedPaneOffersTheWayBackUpWheneverThereCouldBeOne() {
        // A picture arriving under a fold: the ordinary unfold.
        XCTAssertEqual(SessionPageVerb.verb(folded: true, showing: true, castable: true), .show)
        // Nothing arriving, but the machine casts — *show* is still the right
        // verb, because showing is also what asks. See `SessionPageView.show()`.
        XCTAssertEqual(SessionPageVerb.verb(folded: true, showing: false, castable: true), .show)
    }

    /**
     * A machine that will not cast anything offers nothing, folded or not.
     *
     * This is the row that stops the dead click: there is nothing to unfold *to*,
     * so a chevron beside the strip would be a control that cannot act, and the
     * sentence drawn under the strip is the whole answer instead.
     */
    func testAMachineThatWillNotCastOffersNoControlAtAll() {
        XCTAssertEqual(SessionPageVerb.verb(folded: true, showing: false, castable: false), .nothing)
        XCTAssertEqual(SessionPageVerb.verb(folded: false, showing: false, castable: false), .nothing)
    }

    /// A picture really arriving is the only state that offers the fold. Not *is
    /// there a row for this window* — that was still true in the photograph, with
    /// nothing underneath it.
    func testOnlyAPictureThatIsArrivingMayBeFoldedAway() {
        XCTAssertEqual(SessionPageVerb.verb(folded: false, showing: true, castable: true), .fold)
        // Showing with no route to a cast is not a state a real machine reaches —
        // a frame cannot arrive over a connection that cannot carry one — but the
        // rule still has to be the honest one: there is a picture, so it folds.
        XCTAssertEqual(SessionPageVerb.verb(folded: false, showing: true, castable: false), .fold)
    }

    /**
     * The screen he photographed: shown, empty, and a machine that could cast.
     *
     * The control has to become *ask for the page again*. Offering the fold here
     * is the defect verbatim — a chevron promising to put away a space that has
     * nothing in it.
     */
    func testAShownPaneWithNothingArrivingAsksForThePageAgain() {
        XCTAssertEqual(SessionPageVerb.verb(folded: false, showing: false, castable: true), .askAgain)
    }

    /// A folded pane is never asked to fold, whatever else is true. Two of the
    /// four acts bring the page back and none of them may be the one that puts it
    /// away — this is the assertion that would have failed against the photograph.
    func testAFoldedPaneIsNeverOfferedTheFold() {
        for showing in [true, false] {
            for castable in [true, false] {
                XCTAssertNotEqual(SessionPageVerb.verb(folded: true,
                                                       showing: showing,
                                                       castable: castable),
                                  .fold,
                                  "folded, showing \(showing), castable \(castable)")
            }
        }
    }

    // MARK: - The window a session would be handed

    /*
     * > *"the ones that more suits outside, like connecting with the browser and
     * > kind of stuff."*
     *
     * Two `…` menus offer this — the session row's on the Sessions tab and the
     * session's own inside the terminal — and neither can be reached without a
     * machine with a browser on it. What *is* pure is the three decisions behind
     * a row, and one of them is a claim about somebody's work: attaching a window
     * **moves** it off whatever session holds it, without asking, so a row that
     * did not say whose it was would be a silent theft.
     */

    private func window(_ id: String, title: String = "Example Domain",
                        session: String? = nil, sessionTitle: String? = nil) -> MachineWindow {
        MachineWindow(id: id, title: title, url: "https://example.com",
                      slot: session == nil ? nil : "B1",
                      session: session, sessionTitle: sessionTitle)
    }

    /// A machine that will not be driven offers nothing, so the section is absent
    /// rather than drawn dead — the rule every menu in this app follows for
    /// something that could only ever be refused.
    func testNothingIsOfferedByAMachineThatWillNotBeDriven() {
        let open = [window("w1"), window("w2")]
        XCTAssertTrue(SessionWindowPicker.attachable(open, canDrive: false).isEmpty)
        XCTAssertEqual(SessionWindowPicker.attachable(open, canDrive: true).count, 2)
    }

    /// Nil is *not asked yet* and reads the same as nothing open, because in both
    /// cases there is nothing honest to put in a menu.
    func testAListThatHasNotLandedYetOffersNothing() {
        XCTAssertTrue(SessionWindowPicker.attachable(nil, canDrive: true).isEmpty)
        XCTAssertTrue(SessionWindowPicker.attachable([], canDrive: true).isEmpty)
    }

    /**
     * A window another session holds is offered, and says whose it is.
     *
     * Both halves matter. It is offered because refusing would leave somebody
     * with a window they can see and cannot have — the rule the Browser tab's own
     * menu already follows, where the row reads *"Attach to another session"*.
     * It says whose because pressing it takes that window off that session with
     * no further question.
     */
    func testAWindowSomebodyElseHoldsIsOfferedAndNamesTheHolder() {
        let held = window("w1", session: "s-other", sessionTitle: "deploy")
        XCTAssertEqual(SessionWindowPicker.row(held, session: "s-mine"),
                       "Example Domain · deploy")
        XCTAssertEqual(SessionWindowPicker.holder(held, session: "s-mine"), "deploy")
        XCTAssertFalse(SessionWindowPicker.holds(held, session: "s-mine"))
    }

    /// The window this session already holds wears the checkmark and is **not**
    /// also labelled with its owner: "· this session" beside a tick is the same
    /// fact said twice.
    func testTheWindowThisSessionHoldsIsTickedAndNotLabelledTwice() {
        let mine = window("w1", session: "s-mine", sessionTitle: "agent")
        XCTAssertTrue(SessionWindowPicker.holds(mine, session: "s-mine"))
        XCTAssertNil(SessionWindowPicker.holder(mine, session: "s-mine"))
        XCTAssertEqual(SessionWindowPicker.row(mine, session: "s-mine"), "Example Domain")
    }

    /// An unbound window is just its name. Nothing is taken from anybody, so
    /// there is nothing to warn about.
    func testAnUnboundWindowIsJustItsName() {
        XCTAssertEqual(SessionWindowPicker.row(window("w1"), session: "s-mine"), "Example Domain")
        XCTAssertNil(SessionWindowPicker.holder(window("w1"), session: "s-mine"))
    }

    /**
     * A window with no page in it yet still gets words.
     *
     * A machine mints a window before it has loaded anything, so `label` really is
     * empty for a second or two — and a menu row with no words on it is a row
     * nobody can decide about, which on this menu means handing an agent the
     * wrong page.
     */
    func testANamelessWindowIsStillSomethingSomebodyCanChoose() {
        let blank = MachineWindow(id: "w9", title: "", url: "")
        XCTAssertEqual(SessionWindowPicker.row(blank, session: "s-mine"),
                       SessionWindowPicker.unnamed)

        let blankAndHeld = MachineWindow(id: "w9", title: "", url: "",
                                         slot: "B2", session: "s-other", sessionTitle: "build")
        XCTAssertEqual(SessionWindowPicker.row(blankAndHeld, session: "s-mine"),
                       "\(SessionWindowPicker.unnamed) · build")
    }

    /// The holder falls back to the session **id** where the machine sent no
    /// title, rather than to nothing: an id is ugly and it is still the thing an
    /// agent's transcript is keyed on. `MachineBrowserText.owner` owns that rule;
    /// this pins that the picker keeps it rather than inventing a second one.
    func testAnUntitledHolderIsNamedByItsIdRatherThanNotAtAll() {
        let held = window("w1", session: "s-other", sessionTitle: nil)
        XCTAssertEqual(SessionWindowPicker.row(held, session: "s-mine"),
                       "Example Domain · s-other")
    }

    // MARK: - The empty machine, which is the ordinary machine

    /**
     * **A machine with no browser window open still offers the section.**
     *
     * This is the assertion that would have failed against what shipped, and it
     * is the whole of the defect in one line. Both menus were written as
     * `if !attachable(...).isEmpty`, which conflates two different facts:
     *
     *  - *this machine will not be driven* — nothing can be offered, correctly;
     *  - *this machine has nothing open right now* — everything can be offered,
     *    because it can be asked to open one.
     *
     * The second is the ordinary state of a laptop and it is the state he was
     * in when he filmed the `…` with nothing under it:
     *
     * > *"here we also don't have anything, like inside here, in the three dots,
     * > we should have the options to click on something… So we can connect the
     * > browser, whichever browser we want to connect into the session."*
     */
    func testTheSectionIsStillDrawnOnAMachineWithNoWindowOpen() {
        XCTAssertTrue(SessionWindowPicker.attachable([], canDrive: true).isEmpty,
                      "nothing is open, so there is nothing to borrow")
        XCTAssertTrue(SessionWindowPicker.showsAttach(canDrive: true),
                      "and the section is drawn anyway, because a window can be opened")
        XCTAssertTrue(SessionWindowPicker.showsAttach(canDrive: false) == false,
                      "a machine that will not be driven refuses every row, so nothing is drawn")
    }

    /**
     * The new window is offered as two rows a person can read, not as a switch.
     *
     * A `Toggle` in a `Menu` closes the menu on the press, so isolation would
     * have cost one opening of the `…` to choose and a second to act. Two named
     * rows are one press either way — and the words are the New window sheet's
     * own words, so the same choice is not described two ways in two places.
     */
    func testTheIsolatedChoiceIsWordsRatherThanAFlag() {
        XCTAssertNotEqual(SessionWindowPicker.openHere, SessionWindowPicker.openIsolated)
        XCTAssertEqual(SessionWindowPicker.openHere, "Open a window for this session")
        XCTAssertTrue(SessionWindowPicker.openIsolated.contains("signed into nothing"),
                      "the row says what it is rather than naming a setting")

        let shared = SessionWindowPicker.meaning(isolated: false, machine: "Air")
        let alone = SessionWindowPicker.meaning(isolated: true, machine: "Air")
        XCTAssertTrue(shared.contains("signed in the way Air is"))
        XCTAssertTrue(alone.contains("signed into nothing"))
        XCTAssertTrue(alone.contains("forgets everything when the window closes"),
                      "the half that decides it is that the partition is thrown away")
    }

    /// And the sentence the phone puts up while the machine works says which
    /// session it is for — a window that opened attached to nothing looks
    /// exactly like one that opened attached to this session.
    func testTheSentenceAfterOpeningNamesTheSessionItIsFor() {
        XCTAssertEqual(SessionWindowPicker.opening(isolated: false, machine: "Air"),
                       "Opening a window on Air and attaching it to this session.")
        XCTAssertTrue(SessionWindowPicker.opening(isolated: true, machine: "Air")
                          .contains("signed into nothing"))
    }

    // MARK: - The pages this phone is already showing

    /*
     * > *"And these three dots, we should have this attachment thing for all of
     * > them, properly working, and the same way on the sessions side also."*
     *
     * The Browser tab's row menu could do this and the sessions side could not,
     * which is the half he was looking at. Two rules decide it and both are
     * about handing an agent the page somebody meant.
     */

    private func page(_ id: String, host: String = "m-1", port: Int = 3000,
                      path: String = "/", title: String = "") -> BrowserTab {
        BrowserTab(id: id, host: host, port: port, path: path, title: title)
    }

    /**
     * A page open against **another** machine is never offered.
     *
     * `BrowserTabs.tabs(on:)` answers for whichever machine is current, and a
     * session screen is opened for a *named* machine — `TerminalScreen.hostID`
     * exists because session ids are not unique across machines. On the frame
     * where those two disagree, an unfiltered list would open another machine's
     * `localhost:3000` on this one and hand it to an agent, which is a different
     * program's page with nothing on screen to say so.
     */
    func testAPageBelongingToAnotherMachineIsNeverOffered() {
        let tabs = [page("t1", host: "m-1"), page("t2", host: "m-2", port: 5173)]
        let mine = SessionWindowPicker.phonePages(tabs, on: "m-1", canDrive: true)
        XCTAssertEqual(mine.map(\.id), ["t1"])

        XCTAssertTrue(SessionWindowPicker.phonePages(tabs, on: "", canDrive: true).isEmpty,
                      "no machine on screen is not a machine to open pages on")
    }

    /// And nothing at all where the machine will not be driven: the open is the
    /// same `browser.window.open` frame that machine refuses at the source.
    func testNoPageIsOfferedByAMachineThatWillNotBeDriven() {
        XCTAssertTrue(SessionWindowPicker.phonePages([page("t1")], on: "m-1", canDrive: false)
                          .isEmpty)
    }

    /**
     * The address is rebuilt from the tab's **current** values, and the port is
     * never the `Int` interpolated.
     *
     * A port dropped straight into a Swift string is formatted with the locale's
     * grouping separator and comes out as `localhost:3,000` — measured, and this
     * is the third copy of the expression in the app to be caught by it. The
     * path is the tab's own because a tab follows its page: somebody who opened
     * `/` and clicked through to `/admin` means `/admin`.
     */
    func testTheAddressCarriesTheCurrentPathAndAnUngroupedPort() {
        XCTAssertEqual(SessionWindowPicker.address(page("t1", port: 3000, path: "/admin")),
                       "http://localhost:3000/admin")
        XCTAssertEqual(SessionWindowPicker.address(page("t1", port: 8080, path: "/")),
                       "http://localhost:8080/")
    }

    /// The row is the page's own name, and a page that has not said its name yet
    /// is its address rather than "Untitled" — which tells nobody which of their
    /// servers they are looking at.
    func testThePhoneRowIsWhateverThePageCallsItself() {
        XCTAssertEqual(SessionWindowPicker.phoneRow(page("t1", title: "Deck admin")), "Deck admin")
        XCTAssertEqual(SessionWindowPicker.phoneRow(page("t1", port: 3000, path: "/")),
                       "localhost:3000")
        XCTAssertEqual(SessionWindowPicker.phoneRow(page("t1", port: 3000, path: "/admin")),
                       "localhost:3000/admin")
    }

    /**
     * Both strings about a phone page say the page here stays.
     *
     * The one thing this feature must never imply. The phone's web view is not
     * reachable by an agent and never will be — it is drawn here, its cookies
     * are this app's. What the session is handed is a second window on the
     * machine, which may not even be signed in the same way. A header reading
     * *attach this page* would be the app claiming a handover that cannot
     * happen, on the one screen where somebody is about to type a password.
     */
    func testEveryStringAboutAPhonePageSaysThePageHereStays() {
        let header = SessionWindowPicker.phoneSection(machine: "Air")
        XCTAssertTrue(header.contains("Open again on Air"))
        XCTAssertTrue(header.contains("the page here stays"))

        let said = SessionWindowPicker.openingPhonePage(page("t1", port: 3000, path: "/admin"),
                                                        machine: "Air")
        XCTAssertTrue(said.contains("localhost:3000"), "which page is being opened")
        XCTAssertTrue(said.contains("Air's browser"), "and where")
        XCTAssertTrue(said.contains("The page open here does not move."),
                      "and the fact the whole wording exists for")
    }
}
