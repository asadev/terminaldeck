/**
 * A tunnel the machine never answers about must stop looking like it is working.
 *
 * ## The bug this was written from
 *
 * Driving the phone app from the Simulator against a paired desktop on
 * 2026-08-18, typing a port into the Localhost tab's new address field left the
 * screen on *"Opening port 4398 on the Mac…"* with a spinner, indefinitely. The
 * machine advertised the `localhost` capability, listed no ports at all, and
 * answered the `tunnel.open` frame with **nothing** — neither `tunnel.opened`
 * nor `tunnel.closed`.
 *
 * Every answered outcome was already handled. `tunnel.opened` binds a listener,
 * `tunnel.closed` prints the machine's own sentence, and a dropped socket calls
 * `connectionLost`. Silence was the one case with no exit from it, and silence
 * is exactly what a desktop that has the capability name but not the tunnel hub
 * does with the frame: parses it, drops it.
 *
 * A spinner that spins forever is the single most repeated complaint in the
 * 2026-08-17 review said in a different accent — a control that looks like it is
 * acting and is not. `.ended` already draws a sentence and a Close button; all
 * that was missing was something to decide that the machine is not going to
 * answer.
 *
 * ## Why the timeout is injected rather than waited out
 *
 * Twenty seconds is the shipped deadline and it is four times the longest the
 * far end can honestly take. A test that waited it out would be a twenty-second
 * test; a test that shortened the *shipped* constant would be proving a number
 * nobody ships. So the deadline is a parameter with the real value as its
 * default, the tests pass a small one, and `testTheShippedDeadlineIsTheOneThatShips`
 * pins the default so the seam cannot quietly become the behaviour.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class PortTunnelTests: XCTestCase {

    /// A wire that records and never replies. The whole point: this is the
    /// machine that advertises the capability and does nothing with the frame.
    private final class SilentWire: TunnelWire {
        private(set) var sent: [ClientMessage] = []

        @discardableResult
        func send(_ message: ClientMessage) -> Bool {
            sent.append(message)
            return true
        }
    }

    /// And one that refuses to carry anything, which is the other failure the
    /// first line of `start` is about.
    private final class DeadWire: TunnelWire {
        @discardableResult
        func send(_ message: ClientMessage) -> Bool { false }
    }

    private func detail(_ tunnel: PortTunnel) -> String? {
        if case let .ended(detail) = tunnel.phase { return detail }
        return nil
    }

    private func isOpening(_ tunnel: PortTunnel) -> Bool {
        if case .opening = tunnel.phase { return true }
        return false
    }

    /// The request goes out and the tunnel waits, which is the correct
    /// behaviour and the state the deadline is measured from.
    func testAskingOpensNothingUntilTheMachineAnswers() {
        let wire = SilentWire()
        let tunnel = PortTunnel(port: 3000, wire: wire, openTimeout: 0.05)
        tunnel.start()

        XCTAssertEqual(wire.sent.count, 1)
        XCTAssertTrue(isOpening(tunnel), "nothing is bound until the machine says yes")
    }

    /**
     * Silence ends in a sentence rather than in a spinner.
     *
     * The assertion is on the *text* as well as on the phase, because the phase
     * alone would be satisfied by a tunnel that ended with an empty string —
     * and `LocalhostBrowser` draws that string as the whole explanation. A
     * screen reading "Port 3000 is closed" with nothing underneath it is barely
     * better than the spinner.
     */
    func testAMachineThatNeverAnswersEndsWithSomethingToRead() async throws {
        let wire = SilentWire()
        let tunnel = PortTunnel(port: 3000, wire: wire, openTimeout: 0.05)
        tunnel.start()

        try await Task.sleep(for: .milliseconds(300))

        let sentence = try XCTUnwrap(detail(tunnel), "it should have given up by now")
        XCTAssertTrue(sentence.contains("3000"), "the sentence should name the port: \(sentence)")
        XCTAssertGreaterThan(sentence.split(separator: " ").count, 5,
                             "a sentence, not a code: \(sentence)")
    }

    /**
     * And the machine is told, because from this end the frame was sent.
     *
     * A desktop that was merely slow rather than deaf would otherwise be left
     * holding a tunnel this phone has forgotten about, with no way of
     * discovering that on its own — a socket leak caused by a timeout is a worse
     * bug than the hang it was added to fix.
     */
    func testGivingUpTellsTheMachineToLetGo() async throws {
        let wire = SilentWire()
        let tunnel = PortTunnel(port: 3000, wire: wire, openTimeout: 0.05)
        tunnel.start()

        try await Task.sleep(for: .milliseconds(300))

        let closed = wire.sent.contains { message in
            if case .tunnelClose = message { return true }
            return false
        }
        XCTAssertTrue(closed, "the machine should be told to drop it")
    }

    /**
     * A tunnel the machine *did* answer about is not killed twenty seconds later.
     *
     * The obvious way to write a deadline is a timer that fires and ends the
     * tunnel, and it is wrong in a way that would only show up as pages closing
     * themselves after twenty seconds of reading. Two things stop it — the task
     * is cancelled when the tunnel settles, and it re-checks the phase before
     * acting — and this walks the path where the answer is a **refusal**,
     * because that one ends the tunnel with the machine's own words and a
     * deadline firing afterwards would overwrite them.
     */
    func testAnAnsweredTunnelKeepsTheAnswerItWasGiven() async throws {
        let wire = SilentWire()
        let tunnel = PortTunnel(port: 3000, wire: wire, openTimeout: 0.05)
        tunnel.start()
        tunnel.receive(.tunnelClosed(id: tunnel.id, message: "Nothing is listening on 3000."))

        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(detail(tunnel), "Nothing is listening on 3000.",
                       "the machine's own sentence must survive the deadline passing")
    }

    /// A wire that cannot carry the request fails immediately rather than
    /// waiting out a deadline for an answer to a question nobody was asked.
    func testATunnelThatCouldNotBeAskedFailsAtOnce() {
        let tunnel = PortTunnel(port: 3000, wire: DeadWire(), openTimeout: 60)
        tunnel.start()

        XCTAssertNotNil(detail(tunnel), "there is nothing to wait for")
    }

    /**
     * The default is the shipped number.
     *
     * Every case above passes a small one, which is what makes them tests rather
     * than a twenty-second wait — and it is also how a seam quietly becomes the
     * behaviour: a default of `0.05` would pass all five of them and would close
     * every real page on a slow connection. The far end re-scans the machine's
     * ports and then dials the address with a five-second timeout, so this has
     * to be comfortably more than that.
     */
    func testTheShippedDeadlineIsTheOneThatShips() {
        XCTAssertEqual(PortTunnel.openTimeout, 20)
        XCTAssertGreaterThan(PortTunnel.openTimeout, 5 * 2,
                             "the desktop's own dial timeout is five seconds")
    }
}
