/**
 * What the phone *does* with the copilot frames, which is a different question
 * from whether it can read them.
 *
 * `CopilotWireTests` covers the wire. This is the layer above it — the one that
 * decides what is on screen and what may be sent — and every case here is a way
 * the feature could be confidently wrong while every frame decoded perfectly.
 *
 * Six properties, in descending order of what they would cost:
 *
 * **The copilot is a separate connection and this phone opens it every time.**
 * `welcome.copilot.open` is always false; a client that treated it as "already
 * in" would send an `attach` that comes back `unauthorized` on every single
 * connection, and the screen would look like a copilot that never answers. So
 * the welcome sends `copilot.hello` and nothing else, and the subscription hangs
 * off the `copilot.grant` that answers it.
 *
 * **The credential is stored the moment it arrives, or it is lost forever.**
 * `copilot.linked` is sent exactly once and no path on the desktop can show it
 * again. A phone that dropped it has to show the Connect screen rather than
 * silently failing every copilot frame.
 *
 * **A phone with no connection draws no controls, and a phone whose connection
 * was taken away stops drawing them without a reconnect.** The desktop is the
 * boundary and always was; this end exists so that a control which can only ever
 * be refused is never drawn in the first place. The guards are in two places on
 * purpose — the button is absent, *and* the method refuses — because those answer
 * two different failures: a grant that never allowed it, and one revoked between
 * the screen being drawn and the finger landing.
 *
 * **A machine that advertises a copilot without having one draws nothing.** The
 * capability list is assembled by a filter that can drift from what it filters;
 * `ios/Harness/host-standin.ts` sends the whole list verbatim. Reading that as
 * "you are not connected" would send somebody to a Mac to mint a code on a build
 * that cannot.
 *
 * **A question that was answered somewhere else does not vanish.** It is kept,
 * with `by`, so the sheet can say where it went — a dialog that disappears on
 * its own teaches a person that the app does things behind their back.
 *
 * **A drop keeps what happened and discards what is claimed.** The conversation
 * and the tool rows are history; the state, the countdowns and the open
 * connection are claims about now, over a socket that is gone.
 */

import XCTest
@testable import TerminalDeck

@MainActor
final class CopilotLinkTests: XCTestCase {

    // MARK: - Doubles

    /// The socket, as this test. `accepts` makes it refuse the way a real
    /// transport does when the connection is down — `Transport.send` never
    /// queues, which is the property the composer's error messages rest on.
    private final class RecordingWire: CopilotWire {
        private(set) var sent: [ClientMessage] = []
        var accepts = true

        @discardableResult
        func send(_ message: ClientMessage) -> Bool {
            guard accepts else { return false }
            sent.append(message)
            return true
        }

        /// Forget what was sent up to here, so an assertion about what one call
        /// put on the wire is not an assertion about the ceremony that preceded
        /// it.
        func clear() {
            sent.removeAll()
        }
    }

    private var wire = RecordingWire()
    private var vault = MemoryCopilotVault()
    private var link = CopilotLink(wire: RecordingWire())
    private var errors: [String] = []

    override func setUp() {
        super.setUp()
        wire = RecordingWire()
        vault = MemoryCopilotVault()
        link = CopilotLink(wire: wire, vault: vault)
        errors = []
        link.onError = { [weak self] sentence in self?.errors.append(sentence) }
    }

    /// A machine that has a copilot, in the state a `welcome` describes it:
    /// `open` is false, always, whatever this device holds.
    private func welcome(linked: Bool = true, read: Bool = false, act: Bool = false,
                         alter: Bool = false, capability: Bool = true) {
        link.welcomed(capabilities: capability ? [Copilot.capability] : [],
                      connection: CopilotConnection(stated: true, linked: linked, open: false,
                                                    grant: CopilotGrant(read: read, act: act,
                                                                        alter: alter)))
    }

    /// And the frame that answers a `copilot.hello`, which is the only thing
    /// that opens a connection.
    private func opened(read: Bool = true, act: Bool = false, alter: Bool = false) {
        link.apply(pushed: CopilotConnection(stated: true, linked: true, open: true,
                                             grant: CopilotGrant(read: read, act: act, alter: alter)))
    }

    /// The whole ceremony, for the tests that are about what happens afterwards.
    private func connected(read: Bool = true, act: Bool = true, alter: Bool = true) {
        vault.storeCopilotCredential("c2VjcmV0")
        welcome(linked: true, read: read, act: act, alter: alter)
        opened(read: read, act: act, alter: alter)
        wire.clear()
    }

    private func message(_ id: String, _ text: String, role: CopilotRole = .agent) -> CopilotChatMessage {
        CopilotChatMessage(id: id, role: role, text: text, at: 0, truncated: false)
    }

    private func action(_ id: String, outcome: String = "ok") -> CopilotAction {
        CopilotAction(id: id, at: nil, tool: "sessions.list", tier: "read", outcome: outcome,
                      detail: "Listed 4 sessions", refusal: nil, deviceId: "d-7")
    }

    private func question(_ id: String, mine: Bool = false) -> CopilotQuestion {
        CopilotQuestion(id: id, tool: "settings.write", summary: "Change the theme to light",
                        requestedAt: 1_755_400_000_000, expiresAt: 1_755_400_120_000, mine: mine)
    }

    private func ask(_ id: String) -> CopilotConsentQuestion {
        CopilotConsentQuestion(id: id, tool: "settings.write", tier: "alter",
                               summary: "Change the theme to light",
                               arguments: [CopilotArgument(name: "key", value: "theme"),
                                           CopilotArgument(name: "value", value: "light")],
                               argumentsAreOrdered: true, origin: "device:d-7",
                               requestedAt: 1_755_400_000_000, expiresAt: 1_755_400_120_000)
    }

    /// A state report, in the desktop's own shape. `desk` is the copilot at the
    /// machine and `run` is this phone's own; they are separate arguments here
    /// because they are separate facts on the wire.
    private func state(desk: String = "running", run: String? = nil,
                       available: Bool = true, pending: Int = 0) -> CopilotState {
        CopilotState(desk: desk, run: run, profile: nil, signedIn: nil, tools: 0, turnTokens: 0,
                     pending: pending, grant: nil, available: available, reason: nil)
    }

    // MARK: - What may be drawn

    /**
     * The eight states, and the order of the ceremony they describe.
     *
     * `CopilotAccess` exists so no screen re-derives this from a capability,
     * two connection facts and three booleans — because the failure mode of
     * re-deriving it is drawing the *third* answer for the *fourth* case, and
     * three of these cases have three different remedies: update that machine,
     * type a code, tick a box.
     */
    func testAccessWalksTheCeremonyInOrder() {
        XCTAssertEqual(link.access, .notOffered, "before any welcome")

        welcome(linked: false)
        XCTAssertEqual(link.access, .notConnected, "a copilot, and this device has no record")

        welcome(linked: true)
        XCTAssertEqual(link.access, .credentialLost,
                       "the machine remembers this device and this phone does not hold the key")

        vault.storeCopilotCredential("c2VjcmV0")
        welcome(linked: true)
        XCTAssertEqual(link.access, .connecting, "the hello is on the wire")

        opened(read: true)
        XCTAssertEqual(link.access, .watch)

        opened(read: true, act: true)
        XCTAssertEqual(link.access, .direct)

        opened(read: false, act: false, alter: false)
        XCTAssertEqual(link.access, .notGranted, "connected, and every box unticked")
    }

    /**
     * **A connected device with no grant is not the same as an unconnected one.**
     *
     * Two states with two different remedies — three checkboxes, or a six-digit
     * code — and a screen that showed the code field to somebody who is already
     * connected would send them to mint a code they do not need. Unticking every
     * box leaves a working credential behind, which is why both states are real.
     */
    func testConnectedAndGivenNothingIsNotTheSameAsNotConnected() {
        vault.storeCopilotCredential("c2VjcmV0")
        welcome(linked: true)
        opened(read: false)
        XCTAssertEqual(link.access, .notGranted)

        link.apply(pushed: CopilotConnection(stated: true, linked: false, open: false, grant: .none))
        XCTAssertEqual(link.access, .notConnected)
    }

    /**
     * **A machine that advertised a copilot but never showed one draws nothing.**
     *
     * The `.notConnected` screen names a control on the desktop, so reading this
     * case as `.notConnected` would send somebody to a Mac to look for one that
     * build does not have. `.notOffered` says the honest thing instead.
     *
     * This is not a hypothetical host. `host-standin.ts` sends the product's
     * whole `CAPABILITIES` list verbatim, and verifying against it is how an
     * earlier feature was reported working against an empty screen.
     */
    func testAnAdvertisedButAbsentCopilotIsNotOffered() {
        link.welcomed(capabilities: [Copilot.capability], connection: .silent)

        XCTAssertEqual(link.access, .notOffered)
        XCTAssertFalse(link.isAvailable)
        XCTAssertTrue(link.isOffered, "it did advertise it — that is the whole point")
        XCTAssertFalse(link.isImplemented)
        XCTAssertTrue(wire.sent.isEmpty, "and nothing is sent to it")
    }

    /// And a frame arriving settles it, whatever the welcome said. No host
    /// without a copilot layer can send one of these.
    func testAFrameProvesTheMachineHasOne() {
        link.welcomed(capabilities: [Copilot.capability], connection: .silent)
        opened(read: true)

        XCTAssertTrue(link.isImplemented)
        XCTAssertEqual(link.access, .watch)
    }

    /// The other way round: a machine that showed a copilot but does not name
    /// the capability is a host this app has no agreed vocabulary with, and
    /// sending it frames on the strength of one field would be guessing.
    func testTheFieldAloneDoesNotOpenTheScreen() {
        vault.storeCopilotCredential("c2VjcmV0")
        welcome(linked: true, read: true, act: true, capability: false)

        XCTAssertEqual(link.access, .notOffered)
        XCTAssertTrue(wire.sent.isEmpty)
    }

    // MARK: - The ceremony

    /**
     * **A welcome sends the credential, and nothing else.**
     *
     * The single most important behaviour in this file. `welcome.copilot.open`
     * is always false — the desktop's own type says so and the stand-in
     * reproduces it — so an `attach` sent here is refused on every connection,
     * and the phone shows an empty conversation under a working socket. The
     * subscription belongs after the hello, not beside it.
     */
    func testAWelcomeSendsHelloAndNotASubscription() {
        vault.storeCopilotCredential("c2VjcmV0")
        welcome(linked: true, read: true, act: true)

        XCTAssertEqual(wire.sent, [.copilotHello(credential: "c2VjcmV0")])
        XCTAssertFalse(link.isOpen)
        XCTAssertEqual(link.access, .connecting)
    }

    /// And the subscription goes out when the connection opens, which is the
    /// only frame that says the ceremony is done.
    func testOpeningTheConnectionSubscribes() {
        vault.storeCopilotCredential("c2VjcmV0")
        welcome(linked: true, read: true)
        wire.clear()

        opened(read: true)

        XCTAssertEqual(wire.sent, [.copilotAttach, .copilotSessions, .copilotPending])
        XCTAssertTrue(link.isOpen)
    }

    /// On **every** reconnect. The desktop's copilot access belongs to the
    /// socket, so a second welcome is a second hello — remembering the first
    /// would be a phone that believes it is in.
    func testEveryReconnectSendsTheCredentialAgain() {
        vault.storeCopilotCredential("c2VjcmV0")
        welcome(linked: true, read: true)
        opened(read: true)
        link.connectionLost()
        wire.clear()

        welcome(linked: true, read: true)
        XCTAssertEqual(wire.sent, [.copilotHello(credential: "c2VjcmV0")])
        XCTAssertFalse(link.isOpen, "a dropped socket is not an open copilot")
    }

    /// A device the machine has never connected sends nothing at all — not even
    /// a hello, which would be a frame with no credential to carry.
    func testAnUnconnectedDeviceSendsNothing() {
        welcome(linked: false)
        link.refresh()
        link.loadLog()

        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertEqual(link.access, .notConnected)
    }

    /**
     * **Redeeming a code stores the credential before anything else.**
     *
     * It is sent exactly once and there is no path on that machine that can show
     * it again, so anything that happens between receiving it and storing it is
     * a connection nobody can ever reopen. Redeeming also opens this socket —
     * the desktop says so, and it is right: the device has just proved it holds
     * a code minted seconds ago, which is a stronger claim than the credential
     * it is being given.
     */
    func testRedeemingACodeStoresTheCredentialAndOpensTheConnection() {
        welcome(linked: false)
        wire.clear()

        XCTAssertTrue(link.connect(code: "481902"))
        XCTAssertEqual(wire.sent, [.copilotConnect(code: "481902")])
        XCTAssertTrue(link.isConnecting)

        link.linked(credential: "c2VjcmV0",
                    connection: CopilotConnection(stated: true, linked: true, open: true,
                                                  grant: CopilotGrant(read: true, act: true,
                                                                      alter: true)))

        XCTAssertEqual(vault.copilotCredential(), "c2VjcmV0", "stored, or it is gone forever")
        XCTAssertFalse(link.isConnecting)
        XCTAssertEqual(link.access, .direct)
        XCTAssertEqual(wire.sent.suffix(3), [.copilotAttach, .copilotSessions, .copilotPending])
    }

    /**
     * **The code is normalised before it is sent.**
     *
     * The desktop hashes the string it is given and strips nothing, exactly as
     * `device-auth.ts` does not, so `481 902` is not a lenient match — it is a
     * wrong code and one of five guesses spent. One place decides what a code
     * looks like and it is the client, because the client is where somebody
     * typed it.
     */
    func testTheCodeIsNormalisedBeforeItGoesOnTheWire() {
        welcome(linked: false)
        wire.clear()

        XCTAssertTrue(link.connect(code: " 481-902 "))
        XCTAssertEqual(wire.sent, [.copilotConnect(code: "481902")])
    }

    /// Anything that is not six digits never reaches the machine, and says so in
    /// a sentence somebody can act on rather than as a refusal from a relay.
    func testSomethingThatIsNotACodeIsRefusedHere() {
        welcome(linked: false)
        wire.clear()

        XCTAssertFalse(link.connect(code: "48190"))
        XCTAssertFalse(link.connect(code: "4819O2"), "a letter is a typo, not an O to fold")
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.allSatisfy { $0.contains("six digits") })
    }

    /// A wrong code comes back as a plain `error` frame, and the spinner has to
    /// stop over it. The sentence is the desktop's and is shown by the one error
    /// surface the machine already has.
    func testAnErrorStopsTheConnectSpinner() {
        welcome(linked: false)
        link.connect(code: "481902")
        XCTAssertTrue(link.isConnecting)

        link.wireErrored()
        XCTAssertFalse(link.isConnecting)
    }

    /**
     * **A disconnect at the desk drops the credential here.**
     *
     * The record is gone, so the secret this phone holds opens nothing —
     * and a secret sitting in a Keychain with no record behind it is one nobody
     * can revoke because nobody knows it is there. The screen goes back to the
     * code field, which is the honest remedy: connecting again is a new code.
     */
    func testADisconnectDropsTheStoredCredential() {
        connected()
        XCTAssertEqual(vault.copilotCredential(), "c2VjcmV0")

        link.apply(pushed: CopilotConnection(stated: true, linked: false, open: false, grant: .none))

        XCTAssertNil(vault.copilotCredential())
        XCTAssertEqual(link.access, .notConnected)
        XCTAssertFalse(link.isOpen)
    }

    /**
     * **Nothing on this phone closes the copilot connection any more.**
     *
     * This case used to be `testClosingItHereSurvivesAReconnect`: it pressed
     * *"Close the copilot here"*, watched a `copilot.bye` go, and proved that a
     * later `welcome` could not helpfully re-open what somebody had just shut.
     * Asad, looking at the item: *"Why do we have Close the copilot here? It
     * doesn't make any sense."* It went, and with it the flag, the wire send and
     * the whole `closed` access state.
     *
     * What replaces it is this, which is the property that actually has to hold
     * afterwards: a connected phone that goes away and comes back is **still
     * connected**, and it re-opens by itself with the credential it holds. There
     * is no state in which somebody has to press something to get their copilot
     * back — which was the other half of what the close button existed to undo.
     *
     * The assertion on `wire.sent` is the important one: exactly one
     * `copilot.hello`, carrying the stored credential, and no `copilot.connect`,
     * because a phone that already holds a key must never ask a person for a
     * code it does not need.
     */
    func testAReconnectReopensTheCopilotWithNoCodeAndNothingToPress() {
        connected()

        link.connectionLost()
        XCTAssertFalse(link.isOpen, "the socket took the copilot connection with it")
        XCTAssertEqual(link.access, .connecting,
                       "authorised, and waiting for the machine — not asking for a code")

        wire.clear()
        welcome(linked: true, read: true, act: true, alter: true)

        XCTAssertEqual(wire.sent, [.copilotHello(credential: "c2VjcmV0")],
                       "it lets itself back in with the key it already has")
    }

    // MARK: - The act tier

    /**
     * Every act verb is refused, in this object, for a phone that may only
     * watch.
     *
     * The button is absent as well — `CopilotView`'s footer draws a sentence
     * rather than a disabled composer — and both guards are wanted. This one
     * answers the case the absent button cannot: a grant revoked between the
     * screen being drawn and the finger landing.
     */
    func testAWatchingPhoneCannotDirectTheCopilot() {
        connected(read: true, act: false, alter: false)

        link.start()
        XCTAssertFalse(link.say("what happened overnight"))
        link.cancel()
        link.stop()

        XCTAssertTrue(wire.sent.isEmpty, "not one of them reached the wire")
        XCTAssertEqual(errors.count, 4)
        for sentence in errors {
            XCTAssertTrue(sentence.contains("Settings"),
                          "a refusal that does not say where the switch is sends somebody hunting")
        }
    }

    func testADirectingPhoneCanSpeak() {
        connected(read: true, act: true, alter: false)

        XCTAssertTrue(link.say("  what happened overnight  "))
        XCTAssertEqual(wire.sent, [.copilotSay(text: "what happened overnight")],
                       "trimmed, because trailing newlines from a keyboard are not the question")
    }

    /**
     * A multi-line message is flattened rather than sent.
     *
     * The desktop refuses a `copilot.say` carrying any control byte, a newline
     * included, because the text lands in a pty holding a Claude CLI where a
     * newline submits — so two lines would be one prompt and one orphan, at
     * somebody's expense.
     */
    func testAMultiLineMessageIsFlattenedBecauseTheDesktopWouldRefuseIt() {
        connected()

        XCTAssertTrue(link.say("what happened\novernight\r\nexactly"))
        XCTAssertEqual(wire.sent, [.copilotSay(text: "what happened overnight  exactly")])
    }

    func testAnEmptyMessageIsNotSentAndIsNotAnError() {
        connected()

        XCTAssertFalse(link.say("   "))
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    /// Over-length is refused with the number rather than cut. A `copilot.say`
    /// is one utterance and half of one is a different question.
    func testAnOversizeMessageIsRefusedRatherThanCut() {
        connected()

        XCTAssertFalse(link.say(String(repeating: "x", count: Copilot.maxSayBytes + 1)))
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertEqual(errors.count, 1)
    }

    /// A message over a dead socket keeps its text and says so. `Transport.send`
    /// refuses rather than queues, and a message that vanished out of a field
    /// would be one somebody has to retype without knowing they have to.
    func testAMessageOverADeadSocketIsReportedRatherThanLost() {
        connected()
        wire.accepts = false

        XCTAssertFalse(link.say("what happened overnight"))
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("Not connected"))
    }

    // MARK: - Confirmations

    /**
     * **A watching phone sees every question and answers only its own.**
     *
     * `mine` is computed on the desktop and never inferred here. A row that is
     * not this device's draws no Allow — one would always be refused, and a
     * control that is always refused is the defect this repository has paid for
     * twice.
     */
    func testPendingRowsCarryWhoMayAnswerThem() {
        connected()
        link.apply(pending: [question("q1", mine: true), question("q2", mine: false)])

        XCTAssertEqual(link.pending.map(\.id), ["q1", "q2"])
        XCTAssertEqual(link.pending.map(\.mine), [true, false])
        XCTAssertEqual(link.answerableCount, 0,
                       "a watch row is not a decision — the full question comes down its own frame")
    }

    /**
     * The full question arrives separately, and only for this device's own run.
     *
     * `mine` says the desktop would accept an answer; it does not say this phone
     * was ever sent the request. There is no replay, so a phone that reconnected
     * mid-question holds an id and not a request — and `CopilotView` draws the
     * Allow button off *having the question*, never off `mine` alone.
     */
    func testAnAskIsWhatMakesAQuestionAnswerable() {
        connected()
        link.apply(pending: [question("q1", mine: true)])
        XCTAssertEqual(link.answerableCount, 0)

        link.apply(ask: ask("q1"))
        XCTAssertEqual(link.answerableCount, 1)
        XCTAssertEqual(link.asked.first?.arguments.map(\.name), ["key", "value"])
    }

    /// Yes and no travel by the same road, and both are refused for a phone that
    /// was not given `alter`. One method rather than two, because the cheapest
    /// way to make refusing harder than accepting is to give one of them a
    /// shorter path than the other.
    func testAnsweringNeedsAlterAndBothAnswersAreTheSameRoad() {
        connected(read: true, act: true, alter: false)
        link.apply(ask: ask("q1"))

        XCTAssertFalse(link.answer("q1", approved: true))
        XCTAssertFalse(link.answer("q1", approved: false))
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertEqual(errors.count, 2)

        connected(read: true, act: true, alter: true)
        XCTAssertTrue(link.answer("q1", approved: false))
        XCTAssertTrue(link.answer("q2", approved: true))
        XCTAssertEqual(wire.sent, [.copilotAnswer(id: "q1", approved: false),
                                   .copilotAnswer(id: "q2", approved: true)])
    }

    /**
     * **A settled question does not vanish.**
     *
     * First answer wins, and the surface that loses the race has to withdraw its
     * sheet *saying where it went*. So the settlement is kept until the person
     * closes the sheet, and closing it is what forgets it — a dialog that
     * disappears on its own teaches somebody that the app does things behind
     * their back.
     */
    func testASettledQuestionIsKeptUntilItIsRead() {
        connected()
        link.apply(pending: [question("q1", mine: true)])
        link.apply(ask: ask("q1"))

        link.apply(settled: CopilotSettlement(id: "q1", granted: true, by: "window", reason: nil))

        XCTAssertEqual(link.settlement(for: "q1")?.by, "window")
        XCTAssertTrue(link.settlement(for: "q1")?.atTheMachine == true)
        XCTAssertTrue(link.pending.isEmpty, "it is no longer waiting")
        XCTAssertEqual(link.answerableCount, 0, "and it is no longer answerable")
        XCTAssertEqual(link.asked.map(\.id), ["q1"], "but the sheet still has something to draw")

        link.dismissSettled("q1")
        XCTAssertNil(link.settlement(for: "q1"))
        XCTAssertTrue(link.asked.isEmpty)
    }

    /// A settlement for a question this phone never saw is ignored rather than
    /// stored. Otherwise a host could grow this map without bound, and every
    /// entry would be a sheet nobody will ever open to clear it.
    func testASettlementForSomethingUnknownIsDropped() {
        connected()
        link.apply(settled: CopilotSettlement(id: "q9", granted: true, by: "window", reason: nil))

        XCTAssertNil(link.settlement(for: "q9"))
    }

    /**
     * A question that leaves the pending list stops being answerable, even
     * without a `copilot.settled`.
     *
     * The desktop sends the list after every answer for exactly this reason — *a
     * client whose answer was too late has to see the question go rather than be
     * left holding a dialog* — and a settlement may never arrive at all for a
     * device that reconnected in between.
     */
    func testAQuestionThatLeavesThePendingListStopsBeingAnswerable() {
        connected()
        link.apply(pending: [question("q1", mine: true)])
        link.apply(ask: ask("q1"))
        XCTAssertEqual(link.answerableCount, 1)

        link.apply(pending: [])
        XCTAssertEqual(link.answerableCount, 0)
        XCTAssertTrue(link.asked.isEmpty)
    }

    /// The badge answers from the state until the questions themselves arrive,
    /// so it is not late for exactly the thing it exists to be early about.
    func testTheWaitingCountAnswersFromTheStateUntilTheQuestionsArrive() {
        connected()
        link.apply(state: state(pending: 2))
        XCTAssertEqual(link.waitingCount, 2)

        link.apply(pending: [question("q1")])
        XCTAssertEqual(link.waitingCount, 1, "once they arrive, they are the answer")
    }

    /**
     * The whole vocabulary, asserted as a set.
     *
     * Fourteen verbs: three that establish the connection, one that answers a
     * confirmation, six that watch and four that act. Written as an assertion
     * about the *whole* list rather than about the absence of one name, because
     * the failure to guard against is a new frame — a "nudge", a snooze, a
     * `copilot.tool` for a re-run button. Any of them fails this the day it is
     * added, which is the point at which somebody has to come and read
     * `COPILOT-REMOTE.md` §2 rather than after it has shipped.
     */
    func testTheVocabularyIsTheseFourteenVerbs() {
        let verbs: [ClientMessage] = [
            .copilotConnect(code: "481902"), .copilotHello(credential: "c"), .copilotBye,
            .copilotAnswer(id: "q1", approved: true),
            .copilotAttach, .copilotDetach, .copilotState, .copilotSessions,
            .copilotLog(limit: Copilot.logPage, before: nil), .copilotPending,
            .copilotStart, .copilotSay(text: "hi"), .copilotCancel, .copilotStop,
        ]
        let names = Set(verbs.compactMap { frame -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(WireCodec.encode(frame).utf8)),
                  let fields = object as? [String: Any] else { return nil }
            return fields["t"] as? String
        })

        XCTAssertEqual(names, ["copilot.connect", "copilot.hello", "copilot.bye", "copilot.answer",
                               "copilot.attach", "copilot.detach", "copilot.state",
                               "copilot.sessions", "copilot.log", "copilot.pending",
                               "copilot.start", "copilot.say", "copilot.cancel", "copilot.stop"],
                       "the copilot vocabulary is these fourteen — a fifteenth that nudges, "
                       + "snoozes or names a tool belongs in COPILOT-REMOTE.md first")
    }

    // MARK: - The conversation

    /**
     * Merge by id: replace on a match, append otherwise.
     *
     * A streaming answer arrives as the same id with more text in it each time,
     * which is what makes it readable rather than a screenful of fragments.
     */
    func testAStreamingAnswerIsReplacedRatherThanRepeated() {
        connected()
        link.apply(chat: "r-1", messages: [message("m1", "Two sessions")], reset: true)
        link.apply(chat: "r-1", messages: [message("m1", "Two sessions finished overnight.")],
                   reset: false)

        XCTAssertEqual(link.timeline.count, 1)
        guard case let .message(only) = link.timeline[0] else { return XCTFail("a message") }
        XCTAssertEqual(only.text, "Two sessions finished overnight.")
    }

    /**
     * A frame for a run this phone has no baseline for is **dropped**.
     *
     * Not merged and not adopted. It is a fragment of a conversation whose
     * beginning was never seen, and appending it draws an agent apparently
     * answering a question nobody asked — which is exactly what the `run` field
     * on the frame exists to prevent.
     */
    func testAFrameFromAnotherRunIsDroppedRatherThanMerged() {
        connected()
        link.apply(chat: "r-1", messages: [message("m1", "first")], reset: true)
        link.apply(chat: "r-2", messages: [message("m9", "someone else's answer")], reset: false)

        XCTAssertEqual(link.timeline.count, 1)
        XCTAssertEqual(link.chatRun, "r-1")
    }

    /// A `reset` adopts the run and replaces the conversation — and leaves the
    /// tool rows alone, because the machinery either side of it happened
    /// whatever the chat says.
    func testAResetReplacesTheConversationAndKeepsTheMachinery() {
        connected()
        link.apply(chat: "r-1", messages: [message("m1", "old")], reset: true)
        link.apply(tool: action("a1"))
        link.apply(chat: "r-2", messages: [message("m2", "new")], reset: true)

        XCTAssertEqual(link.chatRun, "r-2")
        XCTAssertEqual(link.timeline.map(\.id), ["a:a1", "m:m2"])
    }

    /// A tool row that arrives twice — pushed live, then again in a log page —
    /// is drawn once. Drawing it twice is a phone claiming the copilot did
    /// something once more than it did.
    func testARowThatArrivesTwiceIsDrawnOnce() {
        connected()
        link.apply(tool: action("a1"))
        link.apply(tool: action("a1", outcome: "refused"))

        XCTAssertEqual(link.timeline.count, 1)
        guard case let .action(only) = link.timeline[0] else { return XCTFail("an action") }
        XCTAssertEqual(only.outcome, "refused", "and it is the newer copy that stands")
    }

    /// The oldest go first. A copilot working through a long night can push
    /// thousands of rows down one socket, and the whole history is still one tap
    /// away in Activity, which pages against the file rather than this array.
    func testTheTimelineIsBounded() {
        connected()
        for index in 0 ..< (Copilot.maxTimelineRows + 40) { link.apply(tool: action("a\(index)")) }

        XCTAssertEqual(link.timeline.count, Copilot.maxTimelineRows)
        XCTAssertEqual(link.timeline.first?.id, "a:a40")
    }

    /// A run that has gone takes its conversation with it — and leaves the tool
    /// rows, which are history either way.
    func testAStateWithNoRunClearsTheConversation() {
        connected()
        link.apply(chat: "r-1", messages: [message("m1", "hello")], reset: true)
        link.apply(tool: action("a1"))
        link.apply(state: state(desk: "stopped", run: nil))

        XCTAssertEqual(link.timeline.map(\.id), ["a:a1"])
        XCTAssertNil(link.chatRun)
    }

    // MARK: - The log

    /// Paging back prepends, and de-duplicates rather than trusting the two
    /// pages not to overlap. A log with one entry drawn twice is a log somebody
    /// stops believing.
    func testPagingBackPrependsAndDeduplicates() {
        connected()
        link.loadLog()
        link.apply(log: [action("a5"), action("a6")], more: true)

        link.loadOlder()
        XCTAssertEqual(wire.sent.last, .copilotLog(limit: Copilot.logPage, before: "a5"))
        link.apply(log: [action("a3"), action("a4"), action("a5")], more: false)

        XCTAssertEqual(link.log.map(\.id), ["a3", "a4", "a5", "a6"])
        XCTAssertFalse(link.logHasMore)
    }

    /// There is nothing older to ask for until the desktop said there was. A
    /// button offering to load what does not exist is a button that reports
    /// success having done nothing.
    func testNothingOlderIsAskedForWhenThereIsNoMore() {
        connected()
        link.loadLog()
        link.apply(log: [action("a1")], more: false)
        wire.clear()

        link.loadOlder()
        XCTAssertTrue(wire.sent.isEmpty)
    }

    /// And nothing at all is asked for over a connection that is not open. Every
    /// `copilot.*` verb needs the hello first, read tier included, so this would
    /// be a frame whose only possible answer is *this device is not connected*.
    func testTheLogIsNotAskedForBeforeTheConnectionIsOpen() {
        vault.storeCopilotCredential("c2VjcmV0")
        welcome(linked: true, read: true)
        wire.clear()

        link.loadLog()
        link.refresh()
        XCTAssertTrue(wire.sent.isEmpty)
    }

    // MARK: - Losing the connection, and losing the grant

    /**
     * A drop keeps what happened and discards what is claimed.
     *
     * The conversation and the tool rows are things that **happened** — the
     * words really were said — so they stay on screen under the connection
     * banner. The state, the pending questions and any confirmation waiting for
     * an answer are claims about the present, two of them with a countdown, and
     * nothing is going to update any of them once the socket is gone. A
     * two-minute timer ticking over a dead channel is the "looks connected when
     * it is not" failure this whole client is built around avoiding — and an
     * Allow button over it would be offering something the desktop has already
     * refused with `caller-gone`.
     */
    func testADropKeepsTheHistoryAndDiscardsTheClaims() {
        connected()
        link.apply(chat: "r-1", messages: [message("m1", "hello")], reset: true)
        link.apply(tool: action("a1"))
        link.apply(state: state(run: "r-1", pending: 1))
        link.apply(pending: [question("q1", mine: true)])
        link.apply(ask: ask("q1"))

        link.connectionLost()

        XCTAssertEqual(link.timeline.count, 2, "what was said and done still happened")
        XCTAssertNil(link.state)
        XCTAssertTrue(link.pending.isEmpty)
        XCTAssertTrue(link.asked.isEmpty, "no Allow button over a socket that is gone")
        XCTAssertEqual(link.waitingCount, 0, "no badge for a question nothing will update")
        XCTAssertFalse(link.isOpen)
        XCTAssertEqual(link.access, .connecting, "and the screen says so rather than vanishing")
    }

    /**
     * A revoke empties the screen, without a reconnect.
     *
     * Leaving it in memory would mean a phone re-granted a minute later came
     * back showing a conversation and a set of tool rows from before it was
     * revoked, with nothing having re-checked whether any of it is still true —
     * and, worse, a person believing their revoke had not worked.
     */
    func testLosingTheGrantEmptiesTheScreen() {
        connected()
        link.apply(chat: "r-1", messages: [message("m1", "hello")], reset: true)
        link.apply(tool: action("a1"))
        link.apply(pending: [question("q1")])
        wire.clear()

        opened(read: false, act: false, alter: false)

        XCTAssertEqual(link.access, .notGranted)
        XCTAssertTrue(link.timeline.isEmpty)
        XCTAssertTrue(link.pending.isEmpty)
        XCTAssertNil(link.chatRun)
        // Nothing is sent. `copilot.detach` needs `read` like every other frame
        // on this surface, so a phone that has just lost it would be answered
        // with an `unauthorized` banner for trying to be polite.
        XCTAssertTrue(wire.sent.isEmpty)
    }

    /// Forgetting the machine forgets what it was, and the credential with it: a
    /// re-pair mints a **new** device id, so the desktop drops the copilot record
    /// that went with the old one and the secret here opens nothing.
    func testForgettingTheMachineForgetsTheConnectionAndTheCredential() {
        connected()
        link.apply(tool: action("a1"))

        link.forget()

        XCTAssertEqual(link.access, .notOffered)
        XCTAssertFalse(link.isImplemented)
        XCTAssertFalse(link.linked)
        XCTAssertNil(vault.copilotCredential())
        XCTAssertTrue(link.timeline.isEmpty)
    }
}
