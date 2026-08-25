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
}
