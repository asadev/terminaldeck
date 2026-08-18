/**
 * **Three pills or four**, and the rule that decides — walked over every state a
 * copilot connection can be in.
 *
 * Asad, against 0.4.0 on the phone: *"Actually connecting copilot should be in
 * the settings. So if the copilot is not connecting, this icon should not be
 * inside the pill — then it will be three icon pill. Otherwise if the copilot is
 * connected, then four icon pill, automatically, like that way."*
 *
 * `DeckTabsTests` proves the tab bar asks the right *machine*. This file is
 * about the answer itself, and it is a separate file because the answer has a
 * shape that a couple of spot checks cannot pin: seven states, each of which has
 * to fall on one side of a line, and two of them fall on the side people find
 * surprising. A test that asserted `direct` and `notConnected` — the two obvious
 * ones — would pass while `connecting` was wrong, and `connecting` is the state
 * a phone is in every time its machine goes to sleep.
 *
 * ## What would break without it
 *
 * The pill is `if model.showsCopilotTab` around a whole `NavigationStack` in
 * `DeckTabs`. Get the rule wrong in the *false* direction and somebody's copilot
 * silently loses its pill every time the network blinks, taking the screen they
 * were reading with it. Get it wrong in the *true* direction and there is a
 * fourth pill on a phone that has never connected a copilot, leading to a screen
 * whose only content is an explanation of why it is empty — which is the exact
 * complaint this whole round of review is about.
 */

import XCTest
@testable import TerminalDeck

final class CopilotPillTests: XCTestCase {

    /**
     * Every state, on the side of the line it belongs on.
     *
     * Written as two literal sets over `allCases` rather than as seven
     * assertions, so that a state added later belongs to neither and fails here
     * by name — instead of quietly inheriting whichever branch of the `switch`
     * somebody happened to put it in.
     */
    func testEveryAccessStateIsDecidedAboutOnce() {
        let connected = Set(CopilotAccess.allCases.filter(\.isConnected))
        let not = Set(CopilotAccess.allCases.filter { !$0.isConnected })

        XCTAssertEqual(connected, [.connecting, .notGranted, .watch, .direct])
        XCTAssertEqual(not, [.notOffered, .notConnected, .credentialLost])
        XCTAssertEqual(connected.count + not.count, CopilotAccess.allCases.count)
    }

    /**
     * **The pill follows the authorisation, not the socket.**
     *
     * `connecting` means *this phone holds a working credential and the
     * connection is not up right now* — a machine asleep, a phone on a train, a
     * relay reconnecting. Counting it as disconnected would give the app a tab
     * bar that adds and removes a pill on every network blink, sliding the other
     * three sideways under a thumb that had learned where they are.
     *
     * It is also what the rest of the app does with the same fact: the Sessions
     * and Localhost tabs do not disappear when a machine goes away. They stay,
     * and they say so.
     */
    func testAMachineThatHasGoneAwayKeepsItsPill() {
        XCTAssertTrue(CopilotAccess.connecting.isConnected,
                      "a machine asleep is not a copilot somebody has to reconnect")
    }

    /**
     * Connected with every box unticked is still connected.
     *
     * `notGranted` is a real state — unticking every box at the desk leaves a
     * working credential behind — and the screen behind the pill is the only
     * place that says so and names the switch to tick. Hiding the tab would hide
     * the explanation along with the problem.
     */
    func testConnectedAndGrantedNothingStillGetsAPill() {
        XCTAssertTrue(CopilotAccess.notGranted.isConnected)
    }

    /**
     * A phone that has lost its key gets no pill, even though the machine still
     * lists it.
     *
     * The temptation is to treat `credentialLost` as connected because the
     * *record* is intact. What decides it is the remedy, and the remedy is
     * identical to `notConnected`'s: a fresh six-digit code, minted at the
     * machine, typed into Settings. A pill leading to a screen that can only
     * send somebody to Settings is a pill that costs a tap and gives nothing.
     */
    func testAPhoneThatLostItsKeyGetsNoPill() {
        XCTAssertFalse(CopilotAccess.credentialLost.isConnected)
        XCTAssertFalse(CopilotAccess.notConnected.isConnected)
    }

    /// A machine whose build has no copilot in it gets no pill, which is the
    /// case the old arrangement drew a whole screen for. There is nothing on
    /// that computer to point at and nothing to press here.
    func testAMachineWithoutACopilotGetsNoPill() {
        XCTAssertFalse(CopilotAccess.notOffered.isConnected)
    }
}
