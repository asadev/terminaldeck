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
 *  3. **The strip's one control says which of three acts it is carrying, and
 *     there is always one.** `SessionPageVerb` had no test at all, which is the
 *     wrong way round: it exists *because* the screen he photographed had a
 *     control describing a state instead of an act. The second review deleted its
 *     fourth act — *draw nothing* — which was how a pane he had folded became one
 *     he could not open: *"I can not open it back once if I close it."*
 *  4. **Every state that is not a picture has a line.** `SessionPageStage`, and
 *     it is the other half of the same complaint. Unfolding onto a cast that had
 *     produced no frame drew four hundred points of `Color.black` over a session
 *     screen whose ground is the terminal's black, which is a press nobody can
 *     see. No simulator can tell you the sentence is missing; this can.
 *  5. **What a window is called.** Two rows both reading `about:blank` is what
 *     made the attach menu unusable — *"another name of the window so why they
 *     are like so much of confusing"*. `WindowNames` is the one rule, and the
 *     numbering only fires where a row would otherwise be identical to another.
 *  6. **Who a browser window would be taken from.** Attaching moves a window off
 *     whichever session holds it, silently, so the row that offers it has to say
 *     whose it is. Three screens draw that row; `SessionWindowPicker` is the one
 *     place it is decided.
 *  7. **Whether that row exists at all when the machine has no window open.**
 *     This is the one that shipped wrong. Both menus tested the *list*, so on a
 *     machine whose browser was simply closed the `…` opened onto nothing and
 *     the only way to attach a window to a session was to leave for the Browser
 *     tab and make one first — the walk the menus were added to delete. The
 *     machine being drivable is the condition, and no simulator is needed to
 *     say so.
 *  8. **The page on the phone does not move.** A page this phone is drawing
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
     * `SessionPageVerb` decides which of three things the strip's single control
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
     *
     * **There were four acts and there are three.** The fourth was *offer
     * nothing*, on a machine that could not cast at all, and the second review
     * is what deleted it — from the other side of the same complaint:
     *
     * > *"browser window when it collapse it is not expanding back I can not open
     * > it back once if I close it inside a session in any session even co-pilot
     * > or any other normal session."*
     *
     * `castable` is `isLive && watch.offered`, and both halves move on their own.
     * A pane folded a second ago on a socket that has since dropped had no
     * control on its strip at all — the way back up simply not drawn — which
     * from the outside is a button that has stopped working. A fold is now always
     * reversible, whatever the machine is doing, because unfolding onto no
     * picture says a line instead of showing a black box.
     */

    func testAFoldedPaneAlwaysOffersTheWayBackUp() {
        // A picture arriving under a fold: the ordinary unfold.
        XCTAssertEqual(SessionPageVerb.verb(folded: true, showing: true, castable: true), .show)
        // Nothing arriving, but the machine casts — *show* is still the right
        // verb, because showing is also what asks. See `SessionPageView.show()`.
        XCTAssertEqual(SessionPageVerb.verb(folded: true, showing: false, castable: true), .show)
    }

    /**
     * **His state, exactly: folded, nothing arriving, nothing castable.**
     *
     * This is the assertion that fails against what he filmed. The strip drew no
     * control at all here, so the pane he had put away could not be brought back
     * until the machine changed its mind — *"I can not open it back once if I
     * close it"*. The old rule read *there is nothing to unfold to*; there is,
     * and it is one line of text saying why there is no picture.
     */
    func testAFoldedPaneOpensEvenOnAMachineThatWillNeverCast() {
        XCTAssertEqual(SessionPageVerb.verb(folded: true, showing: false, castable: false), .show,
                       "a pane he folded has to open again on his next press, whatever the "
                       + "machine is doing — the sentence in it is the answer")
        XCTAssertEqual(SessionPageVerb.verb(folded: true, showing: true, castable: false), .show)
    }

    /**
     * And a pane that is open on a machine that will not cast can be put away.
     *
     * The mirror of the case above, and the reason it is not *ask again*: there
     * is nothing to ask a machine that does not offer the capability, so the one
     * honest act left is closing the sentence. An unfoldable pane and an
     * un-foldable one are the same defect from opposite ends.
     */
    func testAShownPaneIsAlwaysClosableEvenWithNothingToAskFor() {
        XCTAssertEqual(SessionPageVerb.verb(folded: false, showing: false, castable: false), .fold)
    }

    /// A picture really arriving is the ordinary state that offers the fold. Not
    /// *is there a row for this window* — that was still true in the photograph,
    /// with nothing underneath it.
    func testAPictureThatIsArrivingMayBeFoldedAway() {
        XCTAssertEqual(SessionPageVerb.verb(folded: false, showing: true, castable: true), .fold)
        // Showing with no route to a cast is not a state a real machine reaches —
        // a frame cannot arrive over a connection that cannot carry one — but the
        // rule still has to be the honest one: there is something in the pane, so
        // it folds.
        XCTAssertEqual(SessionPageVerb.verb(folded: false, showing: true, castable: false), .fold)
    }

    /**
     * The screen he photographed the first time: shown, empty, and a machine that
     * could cast.
     *
     * The control has to become *ask for the page again*. Offering the fold here
     * is the defect verbatim — a chevron promising to put away a space that has
     * nothing in it.
     */
    func testAShownPaneWithNothingArrivingAsksForThePageAgain() {
        XCTAssertEqual(SessionPageVerb.verb(folded: false, showing: false, castable: true), .askAgain)
    }

    /// A folded pane is never asked to fold, whatever else is true. Two of the
    /// three acts bring the page back and none of them may be the one that puts
    /// it away — this is the assertion that would have failed against the first
    /// photograph.
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

    /// And there is **always** a control. The one state that drew none is the one
    /// he could not get out of; nothing about the machine may take the strip's
    /// only button away again.
    func testTheStripAlwaysCarriesAnAct() {
        for folded in [true, false] {
            for showing in [true, false] {
                for castable in [true, false] {
                    let verb = SessionPageVerb.verb(folded: folded,
                                                    showing: showing,
                                                    castable: castable)
                    XCTAssertTrue([.show, .fold, .askAgain].contains(verb),
                                  "folded \(folded), showing \(showing), castable \(castable)")
                }
            }
        }
    }

    /// The three words are three different words, and the two that are a pair
    /// read as a pair: whatever the last press said, the next one says the
    /// opposite of it rather than a new idea.
    func testEachActSaysSomethingDifferentAndTheFoldPairReadsAsOne() {
        XCTAssertEqual(SessionPageVerb.showLabel, "Show the page")
        XCTAssertEqual(SessionPageVerb.hideLabel, "Hide the page")
        XCTAssertEqual(Set([SessionPageVerb.showLabel,
                            SessionPageVerb.hideLabel,
                            SessionPageVerb.askLabel]).count, 3)
    }

    // MARK: - What the stage says when there is no picture

    /*
     * > *"browser window when it collapse it is not expanding back I can not open
     * > it back once if I close it inside a session in any session even co-pilot
     * > or any other normal session."*
     *
     * A session holding a window on `about:blank`. Unfolding gave the stage its
     * height back and `WatchStage` filled it with `Color.black`, over a session
     * screen whose ground is the terminal theme's — black — under an idle
     * terminal. Four hundred points of black appearing over black, with no words
     * in it, and a blank page never repaints so no frame was coming.
     *
     * `SessionPageStage` is what stops a state from having nothing to say. These
     * are the four lines and the one state that has none.
     */

    func testAPictureIsItsOwnAnswerAndSaysNothing() {
        let stage = SessionPageStage.stage(hasPicture: true, asked: true, live: true, offered: true)
        XCTAssertEqual(stage, .picture)
        XCTAssertNil(stage.line, "the page is on the screen — there is nothing to explain")
    }

    /**
     * **His exact state.** A cast the wire believes is running, and not one
     * frame drawn: the stage says it is asking rather than showing black.
     *
     * `asked` is true and `hasPicture` is false, which is precisely what
     * `isCasting` cannot tell apart — it is set the moment `browser.watch`
     * leaves and says nothing about whether anything came back.
     */
    func testACastWithNoFrameYetSaysItIsAsking() {
        let stage = SessionPageStage.stage(hasPicture: false, asked: true, live: true, offered: true)
        XCTAssertEqual(stage, .asking)
        XCTAssertEqual(stage.line, "Asking for the page…")
    }

    /// A window the machine simply is not casting — ordinary rather than
    /// exceptional: a server mints a window through `openForSession(NO_SESSION)`
    /// and detaches it in the same breath, so it holds no binding row and
    /// `castWindows` cannot see it.
    func testAWindowThatIsNotBeingCastSaysSo() {
        let stage = SessionPageStage.stage(hasPicture: false, asked: false, live: true, offered: true)
        XCTAssertEqual(stage, .notCast)
        XCTAssertEqual(stage.line, "This window is not being cast.")
    }

    /// A machine that never offered the capability. Nothing about this window;
    /// the wire does not carry pictures at all.
    func testAMachineThatDoesNotOfferWatchingSaysThatInstead() {
        let stage = SessionPageStage.stage(hasPicture: false, asked: true, live: true, offered: false)
        XCTAssertEqual(stage, .noWatching)
        XCTAssertEqual(stage.line, "This machine does not offer its browser for watching.")
    }

    /**
     * A dropped socket outranks everything, including a picture.
     *
     * The frame on screen is the last one that arrived and everything on it is as
     * stale as the connection — which on a page somebody is about to type into is
     * worth a line of its own. It is the only reading that is put ahead of
     * `hasPicture`.
     */
    func testALostConnectionIsSaidBeforeAnythingElse() {
        XCTAssertEqual(SessionPageStage.stage(hasPicture: true, asked: true,
                                              live: false, offered: true),
                       .offline)
        XCTAssertEqual(SessionPageStage.offline.line, "Not connected to this machine.")
    }

    /// And no state is left with nothing to draw: every reading is either a page
    /// or a sentence. This is the whole of *"it is not expanding back"* — a press
    /// that lands on a state with neither is a press nobody can see.
    func testEveryStateIsEitherAPictureOrASentence() {
        for hasPicture in [true, false] {
            for asked in [true, false] {
                for live in [true, false] {
                    for offered in [true, false] {
                        let stage = SessionPageStage.stage(hasPicture: hasPicture, asked: asked,
                                                           live: live, offered: offered)
                        if stage == .picture { continue }
                        XCTAssertNotNil(stage.line,
                                        "picture \(hasPicture), asked \(asked), live \(live), "
                                        + "offered \(offered)")
                    }
                }
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
     * machine with a browser on it. What *is* pure is the decisions behind a row,
     * and one of them is a claim about somebody's work: attaching a window
     * **moves** it off whatever session holds it, without asking, so a row that
     * did not say whose it was would be a silent theft.
     */

    private func window(_ id: String, title: String = "Example Domain",
                        session: String? = nil, sessionTitle: String? = nil) -> MachineWindow {
        MachineWindow(id: id, title: title, url: "https://example.com",
                      slot: session == nil ? nil : "B1",
                      session: session, sessionTitle: sessionTitle)
    }

    /// A window with nothing in it: no title, no address. What the machine really
    /// sends for a window it has just minted, and what `about:blank` amounts to.
    private func blank(_ id: String, url: String = "about:blank",
                       session: String? = nil, sessionTitle: String? = nil) -> MachineWindow {
        MachineWindow(id: id, title: "", url: url,
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

    // MARK: - What a window is called

    /**
     * **The two rows that both said `about:blank`.**
     *
     * > *"we have one section saying attach a browser window where we see all the
     * > browser windows with their name… then we see another name of the window
     * > so why they are like so much of confusing saying words why don't we just
     * > simply have the name of the search of browsing windows we can just simply
     * > click on one of them and that's it."*
     *
     * Photographed above that: `about:blank`, `Google`, `about:blank`. Two rows,
     * six identical characters of jargon, and nothing to choose between them —
     * which is what made the list unusable rather than merely ugly. A page's own
     * title is a name; `about:blank` is the browser's word for *nothing*.
     */
    func testAWindowWithNoPageInItIsCalledSomethingAPersonCanPointAt() {
        XCTAssertEqual(WindowNames.name(blank("w1")), "Empty window")
        XCTAssertEqual(WindowNames.name(blank("w2", url: "")), "Empty window")
        XCTAssertEqual(WindowNames.name(blank("w3", url: "ABOUT:BLANK")), "Empty window",
                       "the machine's casing is not a different kind of nothing")
        XCTAssertEqual(WindowNames.name(blank("w4", url: "chrome://newtab/")), "Empty window")
    }

    /// A page that has said its name is called that, and one that has not is
    /// called by its address — which is ugly and is *specific*, which is what a
    /// row in a picker is for. "Untitled" tells nobody which window they are
    /// looking at.
    func testAWindowWithAPageInItKeepsThePagesOwnName() {
        XCTAssertEqual(WindowNames.name(window("w1", title: "Example Domain")), "Example Domain")
        XCTAssertEqual(WindowNames.name(blank("w2", url: "https://github.com/login")),
                       "https://github.com/login")
    }

    /**
     * A prefix test on `about:` would have been the tidy way to write it and is
     * wrong: `about:preferences` is a page somebody deliberately opened, and
     * renaming it *Empty window* would hide a real window inside a name that
     * means *nothing here*.
     */
    func testAnAboutPageThatIsARealPageIsNotCalledEmpty() {
        XCTAssertEqual(WindowNames.name(blank("w1", url: "about:preferences")),
                       "about:preferences")
    }

    /**
     * Two windows with the same name are numbered, in the order the machine lists
     * them — which is the order they are drawn in, because both the menu and the
     * Browser tab draw the one `browser.window.rows` answer.
     *
     * The slot (`B1`) was the other candidate and is worse: it is the name the
     * *agent's* tools use, it exists only for a bound window, and half a list
     * numbered by something he has never seen is not a list he can read.
     */
    func testTwoWindowsWithOneNameAreToldApartByTheirOrder() {
        let windows = [blank("w1"), window("w2"), blank("w3")]
        XCTAssertEqual(WindowNames.name(windows[0], in: windows), "Empty window 1")
        XCTAssertEqual(WindowNames.name(windows[2], in: windows), "Empty window 2")
        XCTAssertEqual(WindowNames.name(windows[1], in: windows), "Example Domain",
                       "a name that appears once is left alone — a number out of nowhere is one "
                       + "more thing to work out")
    }

    // MARK: - The row that offers it

    /**
     * A window another session holds is offered, and says whose it is.
     *
     * Both halves matter. It is offered because refusing would leave somebody
     * with a window they can see and cannot have — the rule the Browser tab's own
     * menu already follows, where the row reads *"Attach to another session"*.
     * It says whose because pressing it takes that window off that session with
     * no further question.
     *
     * It survived the compacting for that reason: two words that are half of the
     * window's identity, not a description of what the row does.
     */
    func testAWindowSomebodyElseHoldsIsOfferedAndNamesTheHolder() {
        let held = window("w1", session: "s-other", sessionTitle: "deploy")
        XCTAssertEqual(SessionWindowPicker.row(held, among: [held], session: "s-mine"),
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
        XCTAssertEqual(SessionWindowPicker.row(mine, among: [mine], session: "s-mine"),
                       "Example Domain")
    }

    /// An unbound window is just its name. Nothing is taken from anybody, so
    /// there is nothing to warn about.
    func testAnUnboundWindowIsJustItsName() {
        let one = window("w1")
        XCTAssertEqual(SessionWindowPicker.row(one, among: [one], session: "s-mine"),
                       "Example Domain")
        XCTAssertNil(SessionWindowPicker.holder(one, session: "s-mine"))
    }

    /**
     * A window with no page in it yet still gets words, and two of them still get
     * different words.
     *
     * A machine mints a window before it has loaded anything, so the label really
     * is empty for a second or two — and a menu row nobody can tell from the row
     * above it is a row nobody can decide about, which on this menu means handing
     * an agent the wrong page.
     */
    func testTwoNamelessWindowsAreTwoThingsSomebodyCanChooseBetween() {
        let rows = [blank("w1"), blank("w2")]
        XCTAssertEqual(SessionWindowPicker.row(rows[0], among: rows, session: "s-mine"),
                       "Empty window 1")
        XCTAssertEqual(SessionWindowPicker.row(rows[1], among: rows, session: "s-mine"),
                       "Empty window 2")

        let alone = [blank("w9")]
        XCTAssertEqual(SessionWindowPicker.row(alone[0], among: alone, session: "s-mine"),
                       "Empty window")
    }

    /**
     * The holder is a distinguisher too, so a window already told apart by the
     * session holding it is not *also* numbered.
     *
     * Numbering is decided against the whole row rather than against the name
     * inside it, which is what keeps *Empty window · deploy* and *Empty window ·
     * build* as two names instead of two names with numbers stapled on.
     */
    func testWindowsAlreadyToldApartByTheirHolderAreNotAlsoNumbered() {
        let rows = [blank("w1", session: "s-a", sessionTitle: "deploy"),
                    blank("w2", session: "s-b", sessionTitle: "build")]
        XCTAssertEqual(SessionWindowPicker.row(rows[0], among: rows, session: "s-mine"),
                       "Empty window · deploy")
        XCTAssertEqual(SessionWindowPicker.row(rows[1], among: rows, session: "s-mine"),
                       "Empty window · build")
    }

    /// And where even the holder is the same, the number goes on the **name**, so
    /// the row still reads as a name followed by whose it is.
    func testTwoBlankWindowsOnOneSessionAreNumberedInsideTheName() {
        let rows = [blank("w1", session: "s-a", sessionTitle: "deploy"),
                    blank("w2", session: "s-a", sessionTitle: "deploy")]
        XCTAssertEqual(SessionWindowPicker.row(rows[0], among: rows, session: "s-mine"),
                       "Empty window 1 · deploy")
        XCTAssertEqual(SessionWindowPicker.row(rows[1], among: rows, session: "s-mine"),
                       "Empty window 2 · deploy")
    }

    /// The holder falls back to the session **id** where the machine sent no
    /// title, rather than to nothing: an id is ugly and it is still the thing an
    /// agent's transcript is keyed on. `MachineBrowserText.owner` owns that rule;
    /// this pins that the picker keeps it rather than inventing a second one.
    func testAnUntitledHolderIsNamedByItsIdRatherThanNotAtAll() {
        let held = window("w1", session: "s-other", sessionTitle: nil)
        XCTAssertEqual(SessionWindowPicker.row(held, among: [held], session: "s-mine"),
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
     * **The row that makes a window is a name, not an explanation of itself.**
     *
     * > *"then we see open window for this session open one signed into nothing
     * > which is so much of confusing i don't understand what is what and what are
     * > the differences."*
     *
     * Two rows arguing about a profile, in a list whose other rows are names.
     * They are one row now, called *New window*, at the end after a divider —
     * the section header already says what pressing a row in it does. The
     * isolated window is not gone from the app: the Browser tab's `+` offers
     * *Machine* and *Isolated* as a two-button picker on the New window sheet,
     * which is where somebody choosing a partition already is.
     */
    func testTheRowThatMakesAWindowIsTwoWords() {
        XCTAssertEqual(SessionWindowPicker.newWindow, "New window")
        XCTAssertFalse(SessionWindowPicker.newWindow.contains("session"),
                       "a row in *Attach a browser window* does not have to say it is for this "
                       + "session — the section it is in says so")
    }

    /**
     * What it means is still written down — on the hint, which is read on
     * request, and in the sentence the phone puts up after the press.
     *
     * Nothing was deleted here. It stopped being drawn on a row.
     */
    func testWhatTheNewWindowRowMeansSurvivesOffTheRow() {
        let meaning = SessionWindowPicker.newWindowMeaning(machine: "Air")
        XCTAssertTrue(meaning.contains("Air's own browser"))
        XCTAssertTrue(meaning.contains("signed in the way Air is"))
    }

    /// And the sentence the phone puts up while the machine works says which
    /// session it is for — a window that opened attached to nothing looks
    /// exactly like one that opened attached to this session.
    func testTheSentenceAfterOpeningNamesTheSessionItIsFor() {
        XCTAssertEqual(SessionWindowPicker.opening(machine: "Air"),
                       "Opening a window on Air and attaching it to this session.")
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
    /// servers they are looking at. A name and nothing else: the header that used
    /// to explain these rows is gone.
    func testThePhoneRowIsWhateverThePageCallsItself() {
        XCTAssertEqual(SessionWindowPicker.phoneRow(page("t1", title: "Deck admin")), "Deck admin")
        XCTAssertEqual(SessionWindowPicker.phoneRow(page("t1", port: 3000, path: "/")),
                       "localhost:3000")
        XCTAssertEqual(SessionWindowPicker.phoneRow(page("t1", port: 3000, path: "/admin")),
                       "localhost:3000/admin")
    }

    /**
     * Both strings about a phone page still say the page here stays.
     *
     * The one thing this feature must never imply. The phone's web view is not
     * reachable by an agent and never will be — it is drawn here, its cookies
     * are this app's. What the session is handed is a second window on the
     * machine, which may not even be signed in the same way. A row reading
     * *attach this page* would be the app claiming a handover that cannot
     * happen, on the one screen where somebody is about to type a password.
     *
     * > *"then we see open again on this specific desktop the page here stays."*
     *
     * That was the **section header**, over two rows, every time the menu opened,
     * and he read it out as one of the things he could not understand. It is on
     * the row's hint now and in the sentence after the press. The fact is kept;
     * the paragraph over the list is not.
     */
    func testEveryStringAboutAPhonePageSaysThePageHereStays() {
        let hint = SessionWindowPicker.phoneMeaning(machine: "Air")
        XCTAssertTrue(hint.contains("Air's browser"), "where the second window opens")
        XCTAssertTrue(hint.contains("The page open here does not move."),
                      "and the fact the whole wording exists for")

        let said = SessionWindowPicker.openingPhonePage(page("t1", port: 3000, path: "/admin"),
                                                        machine: "Air")
        XCTAssertTrue(said.contains("localhost:3000"), "which page is being opened")
        XCTAssertTrue(said.contains("Air's browser"), "and where")
        XCTAssertTrue(said.contains("The page open here does not move."))
    }
}
