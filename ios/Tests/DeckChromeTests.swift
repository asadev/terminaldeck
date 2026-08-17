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

    /// The three tabs and the one screen pushed from one of them. All four are
    /// places you are passing through, and he named three of them out loud.
    func testTheBarIsOnEveryTopLevelScreenAndOnMachines() {
        for surface in [DeckSurface.sessions, .localhost, .settings, .machines] {
            XCTAssertTrue(DeckChrome.showsTabBar(on: surface),
                          "\(surface) is one of the screens the bar belongs on")
            XCTAssertEqual(DeckChrome.tabBar(on: surface), .visible)
        }
    }

    /**
     * The two screens the complaint is about.
     *
     * Both are the whole reason you are there rather than somewhere you are
     * passing through, both take the full height of the phone, and on both the
     * bar was sitting over the bottom of the content while offering to take you
     * somewhere else.
     */
    func testTheBarIsHiddenInsideASessionAndInsideAPage() {
        XCTAssertFalse(DeckChrome.showsTabBar(on: .session),
                       "the pill was covering the bottom rows of the terminal")
        XCTAssertFalse(DeckChrome.showsTabBar(on: .localhostPage),
                       "the pill was covering the bottom of the page from the machine")
        XCTAssertEqual(DeckChrome.tabBar(on: .session), .hidden)
        XCTAssertEqual(DeckChrome.tabBar(on: .localhostPage), .hidden)
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

        XCTAssertEqual(shown, [.sessions, .localhost, .settings, .machines])
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
