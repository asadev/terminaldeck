/**
 * Where the tab bar is, and — the half that is actually a bug report — where it
 * is not.
 *
 * Asad, with the keyboard down inside a session: *"see the pill is still there.
 * So inside the session we don't need the pill. Pill should be on here only on
 * the homepage or machines or settings, but not inside the session and not also
 * inside the localhost page."*
 *
 * That is one sentence naming five screens, and it is the sort of rule that is
 * true on the day it is written and false four screens later, because the way it
 * is enforced is a `.toolbar` modifier on each screen — invisible in review, and
 * checkable otherwise only by launching the app and looking at the bottom sixty
 * points. A screen that quietly kept the bar looks exactly like a screen nobody
 * had thought about.
 *
 * So the decision is `DeckChrome`, and this walks **every** case of `DeckSurface`
 * rather than the two that are interesting today. Adding a surface without
 * deciding about it fails to compile inside `showsTabBar`; adding one and
 * deciding wrongly fails here, by name.
 */

import SwiftUI
import XCTest
@testable import TerminalDeck

final class DeckChromeTests: XCTestCase {

    /// The three tabs that draw a bar, and the one screen pushed from one of
    /// them. All four are places you are passing through, and he named three of
    /// them out loud.
    func testTheBarIsOnEveryTopLevelScreenAndOnMachines() {
        for surface in [DeckSurface.sessions, .localhost, .settings, .machines] {
            XCTAssertTrue(DeckChrome.showsTabBar(on: surface),
                          "\(surface) is one of the screens the bar belongs on")
            XCTAssertEqual(DeckChrome.tabBar(on: surface), .visible)
        }
    }

    /**
     * **How much room a screen under the bar reserves for it.**
     *
     * He photographed the About row on Settings with the pill drawn across the
     * words *"Terminal Deck"*. Every scrolling screen under the bar had the same
     * `.padding(.bottom, 28)` at the end of it, copied into six files, and
     * twenty-eight points is breathing room rather than a bar: the bar's own
     * frame is eighty-three points on an iPhone 17 Pro.
     *
     * The arithmetic is what is pinned here — the measuring is UIKit's and the
     * looking is `TabBarInsetUITests`' — because both wrong answers are bad and
     * only one of them is visible in a screenshot. Reserving nothing puts the
     * last row under the pill; reserving the band a second time on a release
     * that already handed it over leaves a hundred and sixty points of nothing
     * that looks, in a photograph, exactly like a slightly short screen.
     */
    func testAScreenReservesTheDifferenceAndNeverTheBandTwice() {
        // The release that hands the inset over: nothing more is owed.
        XCTAssertEqual(TabBarClearanceMath.spacer(band: 83, alreadyInset: 83), 0,
                       "the scroll view was already inset by the whole bar")
        // The release his phone is running: only the home indicator was given,
        // so the pill's own band is what is missing.
        XCTAssertEqual(TabBarClearanceMath.spacer(band: 83, alreadyInset: 34), 49)
        // A phone with no home indicator, inset by nothing at all.
        XCTAssertEqual(TabBarClearanceMath.spacer(band: 49, alreadyInset: 0), 49)
        // Over-inset is not fixed by taking content away.
        XCTAssertEqual(TabBarClearanceMath.spacer(band: 49, alreadyInset: 120), 0)
        // No bar found — a screen that hides it, or a phone mid-transition. The
        // honest answer is to reserve nothing rather than room for a bar that is
        // not drawn.
        XCTAssertEqual(TabBarClearanceMath.spacer(band: 0, alreadyInset: 0), 0)
        XCTAssertEqual(TabBarClearanceMath.spacer(band: .nan, alreadyInset: 34), 0)
        XCTAssertEqual(TabBarClearanceMath.spacer(band: 83, alreadyInset: .nan), 0)
    }

    /**
     * The three screens the complaint is about.
     *
     * Each is the whole reason you are there rather than somewhere you are
     * passing through, each takes the full height of the phone, and on each the
     * bar was sitting over the bottom of the content while offering to take you
     * somewhere else.
     */
    func testTheBarIsHiddenInsideASessionAndAPage() {
        XCTAssertFalse(DeckChrome.showsTabBar(on: .session),
                       "the pill was covering the bottom rows of the terminal")
        XCTAssertFalse(DeckChrome.showsTabBar(on: .localhostPage),
                       "the pill was covering the bottom of the page from the machine")
        XCTAssertEqual(DeckChrome.tabBar(on: .session), .hidden)
        XCTAssertEqual(DeckChrome.tabBar(on: .localhostPage), .hidden)
    }

    /**
     * **The copilot, whose answer has now been given three times.** It is worth
     * its own case, with the whole history in it, because the middle answer was
     * good and somebody will rediscover it and undo this.
     *
     * *Hidden*, while the copilot was a screen pushed from the session list: it
     * is full height and ends in a composer, and a bar floating over a text
     * field is the pill complaint exactly. The chevron was how you left.
     *
     * *Shown*, when *"a fourth pill, and the copilot goes leftmost"* made it a
     * tab — because a tab that hides its own tab bar has no way out at all.
     * There is no chevron over a tab's root and no gesture that pops one.
     *
     * *Hidden again*, because he supplied the missing way out: *"pill should not
     * be inside the chat box — there should be a back button to go back on
     * home."* The entire case for the bar was that nothing else could leave the
     * screen, and now something can. So the premise fell rather than the
     * judgement being reversed.
     *
     * **And the chat box it was protecting is not on this surface any more.**
     *
     * The tab lands *in a session* now — *"when we land on the copilot page
     * there should be directly a new session started"* — and a session is
     * `.session`, which still hides the bar for exactly the reason it always
     * did. What is left on `.copilot` is a short list of rows with nothing to
     * type into.
     *
     * The bar is back because hiding it made this the one tab in the app you
     * could not leave sideways: the screen walk failed to reach Menu from here,
     * and a person is in the same position with only a chevron that goes back
     * rather than across. `copilot.back` is still drawn and still correct —
     * going back and going across are different acts, and this screen offers
     * both. `CopilotScreensUITests` is where a finger proves the button is there.
     */
    func testTheCopilotKeepsItsBarNowThatNothingTypesOnIt() {
        XCTAssertTrue(DeckChrome.showsTabBar(on: .copilot),
                      "a four-icon pill that vanishes on one of its four cannot be trusted")
        XCTAssertEqual(DeckChrome.tabBar(on: .copilot), .visible)
        // The chat box moved rather than the rule being reversed.
        XCTAssertFalse(DeckChrome.showsTabBar(on: .session),
                       "the pill would be sitting over the composer again")
    }

    /**
     * Every surface has been decided about, and the two answers are exactly the
     * two sets above.
     *
     * The point of walking `allCases` is the surface nobody added to either list
     * — a new screen defaults to whatever `showsTabBar` was written to return
     * for it, and this is what notices.
     */
    func testEverySurfaceIsAccountedFor() {
        let shown = Set(DeckSurface.allCases.filter { DeckChrome.showsTabBar(on: $0) })
        let hidden = Set(DeckSurface.allCases.filter { !DeckChrome.showsTabBar(on: $0) })

        // `.copilot` moved from hidden to shown on 2026-08-25, when the tab
        // started landing in a session: the chat box the old rule protected is
        // on `.session`, and hiding the bar here made this the one tab in the
        // app that could not be left sideways. See `showsTabBar`'s own header.
        XCTAssertEqual(shown, [.sessions, .localhost, .settings, .machines, .copilot])
        XCTAssertEqual(hidden, [.session, .localhostPage])
        XCTAssertEqual(shown.count + hidden.count, DeckSurface.allCases.count)
    }

    /**
     * The rule is not "hide it on anything that was pushed".
     *
     * Machines is pushed — it is a row inside Settings now — and it keeps the
     * bar, because he named it as one of the three places the bar belongs. This
     * case exists because "hidden when pushed" is the obvious simplification and
     * it is wrong, and somebody will reach for it.
     */
    func testAPushedScreenDoesNotAutomaticallyLoseTheBar() {
        XCTAssertTrue(DeckChrome.showsTabBar(on: .machines),
                      "Machines is pushed from Settings and still keeps the bar")
    }
}
