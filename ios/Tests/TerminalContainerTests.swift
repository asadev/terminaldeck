/**
 * The bottom safe area, measured on a real layout rather than reasoned about.
 *
 * Asad, on a session with the keyboard down: *"at the bottom we cannot see some
 * stuff because of the mobile's round corners and the running-agents things —
 * whatever is at the most bottom is less visible. So leave a little space when
 * the keyboard is off."*
 *
 * Every case here builds a real `TerminalContainerView` inside a real
 * `UIViewController` and lets UIKit's layout engine run, because the claim being
 * made is a claim about geometry and arithmetic about a layout is not a layout —
 * the same reason `KeyBarTests` measures the key bar instead of adding up its
 * constants.
 *
 * The safe area is stated through `additionalSafeAreaInsets`, which is how a
 * controller declares one without a window, a scene or a device. 34 points is
 * what every iPhone with a home indicator reports and 0 is what a bezelled one
 * reports; both are here, because a fix that only works on the reviewer's phone
 * is how this bug was shipped in the first place.
 */

import SwiftTerm
import UIKit
import XCTest
@testable import TerminalDeck

@MainActor
final class TerminalContainerTests: XCTestCase {

    /// An iPhone 17's points. Only the height matters to anything below; the
    /// width is here so the terminal has a sane column count while it measures.
    private static let phone = CGSize(width: 402, height: 874)

    /// What a phone with a home indicator puts under the terminal.
    private static let homeIndicator: CGFloat = 34

    /**
     * The windows the cases below are laid out in, kept alive for the length of
     * the test.
     *
     * A `UIWindow` that nothing holds is deallocated at the end of the statement
     * that made it, and its view tree's safe area goes back to zero on the way
     * out — so the measurement would be taken from a hierarchy that had already
     * been torn down. This is not hypothetical tidiness: the first version of
     * this file kept no reference and every case read 0.
     */
    private var windows: [UIWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    /**
     * A container laid out the way SwiftUI lays this one out.
     *
     * **In a real window**, because a safe area is a property of a view tree that
     * is *in* one. A `UIViewController` on its own reports zero no matter what
     * `additionalSafeAreaInsets` says, which is a trap worth naming: the first
     * version of these cases used a bare controller, two of the five went green
     * immediately, and both were green because every number in them was zero.
     *
     * `keyboard` is how much SwiftUI's keyboard avoidance has taken off the
     * bottom — 0 with the keyboard down, and the height of the keyboard plus the
     * key bar with it up. It is expressed as the container's *frame* rather than
     * as a flag because that is literally what happens: keyboard avoidance is a
     * safe-area region SwiftUI resolves before this view exists, and all this
     * view ever sees is a shorter box.
     */
    private func laidOut(bottomSafeArea: CGFloat,
                         keyboard: CGFloat = 0) -> TerminalContainerView {
        let size = Self.phone
        let terminal = DeckTerminalView(frame: .zero,
                                        font: .monospacedSystemFont(ofSize: 12, weight: .regular))
        let container = TerminalContainerView(terminal: terminal)

        let controller = UIViewController()
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 0,
                                                           bottom: bottomSafeArea, right: 0)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        windows.append(window)

        controller.view.addSubview(container)
        container.frame = CGRect(x: 0, y: 0, width: size.width, height: size.height - keyboard)
        window.layoutIfNeeded()
        return container
    }

    // MARK: - Keyboard down

    /**
     * The bug, stated as a test: with the keyboard down the terminal stops short
     * of the bottom of the screen by exactly the home indicator's inset.
     *
     * "Exactly" matters in both directions. Less and the last line is still
     * crossed by the indicator, which is the complaint. More and something has
     * started reserving space for the tab pill again — the pill's band is about
     * seventy points, so a container that gave back that much would pass a
     * one-sided "is there a gap" check while quietly costing four rows of
     * terminal inside a session that is supposed to have no pill at all.
     */
    func testTheTerminalStopsExactlyAtTheHomeIndicator() {
        let container = laidOut(bottomSafeArea: Self.homeIndicator)

        XCTAssertEqual(container.reservedBottom, Self.homeIndicator, accuracy: 0.5,
                       "the container should give back what UIKit says is unsafe, no more")
        XCTAssertEqual(container.terminal.frame.maxY,
                       container.bounds.maxY - Self.homeIndicator, accuracy: 0.5,
                       "the last line has to end above the indicator, not under it")
        XCTAssertEqual(container.terminal.frame.minY, container.bounds.minY, accuracy: 0.5,
                       "and nothing may be taken off the top — the navigation bar already did that")
    }

    /**
     * A phone with no home indicator gives nothing back.
     *
     * The iPhone SE is still supported — the deployment target is iOS 17 and
     * `KeyPlan.narrowestPhoneWidth` is its 375 points — and it has a bezel where
     * the newer phones have an indicator. A hard-coded 34 would have cost it two
     * rows of terminal to avoid something that is not there, which is why
     * nothing in `TerminalContainerView` knows a number.
     */
    func testABezelledPhoneGivesNothingBack() {
        let container = laidOut(bottomSafeArea: 0)

        XCTAssertEqual(container.reservedBottom, 0, accuracy: 0.5)
        XCTAssertEqual(container.terminal.frame.height, container.bounds.height, accuracy: 0.5,
                       "there is no indicator to avoid on this phone")
    }

    // MARK: - Keyboard up

    /**
     * With the keyboard up the inset disappears, and it disappears *because of
     * the geometry* rather than because anything asked about the keyboard.
     *
     * This is the case a flag would get wrong. The keyboard covers the indicator
     * anyway, so an inset held on top of it would push the terminal a further 34
     * points up for nothing — a whole line of output lost for as long as somebody
     * is typing. Here the container's own frame stops above the unsafe region, so
     * UIKit reports no bottom safe area at all and there is nothing to double up
     * with. No state, no ordering, nothing to keep in step.
     */
    func testTheKeyboardAndTheSafeAreaDoNotDoubleUp() {
        // A keyboard plus the key bar on this phone: the exact number does not
        // matter, only that the container no longer reaches the bottom.
        let container = laidOut(bottomSafeArea: Self.homeIndicator, keyboard: 336)

        XCTAssertEqual(container.reservedBottom, 0, accuracy: 0.5,
                       "the keyboard already covers the indicator — inset it again and a line "
                       + "of terminal is wasted the whole time somebody is typing")
        XCTAssertEqual(container.terminal.frame.height, container.bounds.height, accuracy: 0.5,
                       "the terminal fills the space the keyboard left it")
    }

    // MARK: - Why a frame and not a content inset

    /**
     * The emulator is told the smaller size, which is the whole reason this is a
     * frame change and not `contentInset.bottom` on the scroll view.
     *
     * SwiftTerm computes the row count in `processSizeChange` from `bounds.size`.
     * A content inset does not touch bounds, so the session would still believe
     * it had the taller screen: scrollback would *look* fixed, because scrolling
     * to the bottom would rest higher up, and a full-screen program would not —
     * `vim`, `htop` and an agent's status box paint a fixed number of rows from
     * the top, so the top row would go under the navigation bar while the bottom
     * row stayed on the indicator.
     *
     * So the assertion is that the row count actually drops. If somebody
     * "simplifies" this back to a content inset, this is the case that fails.
     */
    func testTheEmulatorIsToldTheShorterScreen() {
        let full = laidOut(bottomSafeArea: 0)
        let inset = laidOut(bottomSafeArea: Self.homeIndicator)

        XCTAssertEqual(inset.terminal.bounds.height,
                       full.terminal.bounds.height - Self.homeIndicator, accuracy: 0.5)
        XCTAssertLessThan(inset.terminal.getTerminal().rows, full.terminal.getTerminal().rows,
                          "the session has fewer rows now — if this is equal the inset went on "
                          + "the content rather than on the frame, and a full-screen program "
                          + "will still draw its last row under the indicator")
    }

    /**
     * Scrolling to the bottom still means the bottom.
     *
     * The failure this guards against is subtle and would look like the fix
     * working: the terminal is inset correctly, and the newest line is then
     * parked *underneath* the inset because the scroll view's resting offset was
     * computed against the old height. What is measured is the relationship that
     * has to hold — the end of the content sits inside the terminal's own visible
     * box — and the terminal's box is now the part of the screen that can be
     * read.
     */
    func testTheNewestLineLandsInsideTheVisibleBox() {
        let container = laidOut(bottomSafeArea: Self.homeIndicator)
        let terminal = container.terminal

        for line in 1 ... 200 {
            terminal.feed(text: "line \(line) · terminal deck\r\n")
        }
        container.layoutIfNeeded()

        let bottomOfContent = terminal.contentSize.height - terminal.contentOffset.y
        XCTAssertLessThanOrEqual(bottomOfContent, terminal.bounds.height + 1,
                                 "the newest line is \(bottomOfContent - terminal.bounds.height) "
                                 + "points below the visible box — following the bottom is "
                                 + "resting against a height the terminal no longer has")
        XCTAssertLessThanOrEqual(terminal.frame.maxY, container.bounds.maxY - Self.homeIndicator + 0.5,
                                 "and the visible box itself is still clear of the indicator")
    }
}
