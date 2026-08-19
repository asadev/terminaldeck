/**
 * **Three pills or four**, and the rule that decides — walked over every state a
 * machine's copilot can be in.
 *
 * Asad, against 0.4.0 on the phone: *"Actually connecting copilot should be in
 * the settings. So if the copilot is not connecting, this icon should not be
 * inside the pill — then it will be three icon pill. Otherwise if the copilot is
 * connected, then four icon pill, automatically, like that way."*
 *
 * And a day later, deleting the first half of his own sentence: *"instead of
 * giving mobile app separate connection for copilot just make it like if we are
 * connecting as my device copilot automatically comes, if we connect as guest
 * then copilot don't come — that's all we need to do instead of two different
 * connections."* So there is nothing left in Settings to connect, and
 * *"automatically"* became the whole rule rather than the ending of it: the
 * fourth pill is on a phone he paired as his own and absent on a guest's,
 * decided once at the machine and never afterwards on the phone.
 *
 * `DeckTabsTests` proves the tab bar asks the right *machine*. This file is
 * about the answer itself, and it is a separate file because the answer has a
 * shape that a couple of spot checks cannot pin: every state has to fall on one
 * side of a line, and the one people find surprising is `connecting`, which is
 * the state a phone is in every time its machine goes to sleep.
 *
 * ## What would break without it
 *
 * The pill is `if model.showsCopilotTab` around a whole `NavigationStack` in
 * `DeckTabs`. Get the rule wrong in the *false* direction and somebody's copilot
 * silently loses its pill every time the network blinks, taking the screen they
 * were reading with it. Get it wrong in the *true* direction and there is a
 * fourth pill on a guest's phone, leading to a screen whose only content is an
 * explanation of why it is empty — which is both the complaint that whole round
 * of review was about and, here, a promise about somebody else's copilot that
 * *"the copilot is never shared"* exists to refuse.
 */

import XCTest
@testable import TerminalDeck

final class CopilotPillTests: XCTestCase {

    /**
     * Every state, on the side of the line it belongs on.
     *
     * Written as two literal sets over `allCases` rather than as one assertion
     * per case, so that a state added later belongs to neither and fails here by
     * name — instead of quietly inheriting whichever branch of the `switch`
     * somebody happened to put it in.
     *
     * The `not` set has one member now and used to have three. `notConnected`
     * and `credentialLost` were the two states the six-digit connect ceremony
     * could leave a phone in, and both went with it; what is left on that side
     * of the line is *there is no copilot here for this phone*, which is a guest
     * or a machine whose build has none.
     */
    func testEveryAccessStateIsDecidedAboutOnce() {
        let connected = Set(CopilotAccess.allCases.filter(\.isConnected))
        let not = Set(CopilotAccess.allCases.filter { !$0.isConnected })

        XCTAssertEqual(connected, [.connecting, .notGranted, .watch, .direct])
        XCTAssertEqual(not, [.notOffered])
        XCTAssertEqual(connected.count + not.count, CopilotAccess.allCases.count)
    }

    /**
     * **The pill follows the device, not the socket.**
     *
     * `connecting` means *this phone has a copilot on that machine and the
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
     * Open with an empty grant still gets a pill.
     *
     * `notGranted` should not be reachable at all — a device approved as **My
     * device** is given every tier — so it means the far end has said something
     * this build does not expect. The screen behind the pill is the only place
     * that says so; hiding the tab would hide the explanation along with the
     * problem, and leave somebody with a copilot that is simply missing.
     */
    func testOpenAndGrantedNothingStillGetsAPill() {
        XCTAssertTrue(CopilotAccess.notGranted.isConnected)
    }

    /**
     * **A guest gets no fourth pill, and neither does a machine without a
     * copilot.**
     *
     * One assertion for both, because they are one state: `server.ts` strips the
     * capability *and* the welcome field for a guest rather than merely refusing
     * the verbs — *"a client that is told the capability exists draws the tab,
     * and a tab that refuses on every press is a worse answer than a client that
     * never knew"* — so from this end the two frames are identical.
     *
     * This is the assertion that carries *"if we connect as guest then copilot
     * don't come"*. It is not a nicety: a fourth pill on a guest's phone is a
     * door to somebody else's agent, and the pairing screen promises in his own
     * words that it is never there.
     */
    func testNoCopilotForThisPhoneMeansNoPill() {
        XCTAssertFalse(CopilotAccess.notOffered.isConnected)
    }
}
