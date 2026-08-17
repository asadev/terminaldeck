/**
 * What the phone *does* with the copilot frames, which is a different question
 * from whether it can read them.
 *
 * `CopilotWireTests` covers the wire. This is the layer above it — the one that
 * decides what is on screen and what may be sent — and every case here is a way
 * the feature could be confidently wrong while every frame decoded perfectly.
 *
 * Five properties, in descending order of what they would cost:
 *
 * **A phone with no grant draws no controls, and a phone whose grant was taken
 * away stops drawing them without a reconnect.** The desktop is the boundary and
 * always was; this end exists so that a control which can only ever be refused
 * is never drawn in the first place. The guards are in two places on purpose —
 * the button is absent, *and* the method refuses — because those answer two
 * different failures: a grant that never allowed it, and a grant revoked between
 * the screen being drawn and the finger landing.
 *
 * **A machine that advertises a copilot without having one draws nothing.** The
 * capability list is assembled by a filter that can drift from what it filters;
 * `ios/Harness/host-standin.ts` sends the whole list and implements almost none
 * of it. Reading that as "you have not been given access" would send somebody to
 * a Mac to look for a switch that is not on it.
 *
 * **`copilot.pending` is watch-only.** There is no method here that answers a
 * question, and the test at the foot of this file asserts that the *whole* set
 * of verbs this phone can send is the ten in the design — so the day somebody
 * adds `copilot.allow` for a notification action, it fails.
 *
 * **A drop keeps what happened and discards what is claimed.** The conversation
 * and the tool rows are history; the state and the countdowns are claims about
 * now, over a socket that is gone.
 *
 * **A chat frame belonging to another run is dropped, not merged.** Without it a
 * run that ended while the phone was in a pocket produces one conversation made
 * of two, with no seam visible on screen.
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
        /// put on the wire is not an assertion about the subscription that
        /// preceded it.
        func clear() {
            sent.removeAll()
        }
    }

    private var wire = RecordingWire()
    private var link = CopilotLink(wire: RecordingWire())
    private var errors: [String] = []

    override func setUp() {
        super.setUp()
        wire = RecordingWire()
        link = CopilotLink(wire: wire)
        errors = []
        link.onError = { [weak self] sentence in self?.errors.append(sentence) }
    }

    /// A machine that has a copilot and has granted this device what is asked
    /// for. `stated: true` is the desktop saying it has one — see `CopilotOffer`.
    private func welcome(read: Bool = false, act: Bool = false, capability: Bool = true) {
        link.welcomed(capabilities: capability ? [Copilot.capability] : [],
                      offer: CopilotOffer(stated: true,
                                          grant: CopilotGrant(read: read, act: act)))
    }

    private func message(_ id: String, _ text: String, role: CopilotRole = .agent) -> CopilotChatMessage {
        CopilotChatMessage(id: id, role: role, text: text, at: 0, truncated: false)
    }

    private func action(_ id: String, outcome: String = "ok") -> CopilotAction {
        CopilotAction(id: id, at: nil, tool: "sessions.list", tier: "read", outcome: outcome,
                      detail: "Listed 4 sessions", refusal: nil, deviceId: "d-7")
    }

    private func question(_ id: String) -> CopilotQuestion {
        CopilotQuestion(id: id, tool: "settings.write", summary: "Change the theme to light",
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
     * The four states, and the fifth that is not one.
     *
     * `CopilotAccess` exists so no screen re-derives this from a capability and
     * two booleans, because the failure mode of re-deriving it is drawing the
     * third answer for the fourth case — a phone hiding a feature somebody could
     * have switched on in ten seconds if anything had told them it was there.
     */
    func testAccessIsTheFourStatesAndNothingInBetween() {
        XCTAssertEqual(link.access, .notOffered, "before any welcome")

        welcome()
        XCTAssertEqual(link.access, .notGranted, "a copilot, and none of it for this phone")

        welcome(read: true)
        XCTAssertEqual(link.access, .watch)

        welcome(read: true, act: true)
        XCTAssertEqual(link.access, .direct)
    }

    /**
     * `act` without `read` is not a usable grant, and this is where that matters.
     *
     * Reachable from a hand-edited `remote-copilot.json`: `copilotGrantFrom`
     * keeps whatever is literally `true` for each grantable tier and has no rule
     * tying one to the other. The desktop refuses the whole surface without
     * `read`, so drawing a composer for it would draw a control whose every
     * message comes back `unauthorized`.
     */
    func testActWithoutReadDrawsNothing() {
        welcome(read: false, act: true)

        XCTAssertEqual(link.access, .notGranted)
        XCTAssertTrue(wire.sent.isEmpty, "and it does not even subscribe")
    }

    /**
     * **A machine that advertised a copilot but never showed one draws nothing.**
     *
     * The `.notGranted` screen names the switch on the desktop, so reading this
     * case as `.notGranted` would send somebody to a Mac to look for a control
     * that build does not have. `.notOffered` says the honest thing instead:
     * that machine is running a version without a copilot in it.
     *
     * This is not a hypothetical host. `host-standin.ts` sends the product's
     * whole `CAPABILITIES` list verbatim and implements none of these frames,
     * and verifying against it is how an earlier feature was reported working
     * against an empty screen.
     */
    func testAnAdvertisedButAbsentCopilotIsNotOffered() {
        link.welcomed(capabilities: [Copilot.capability], offer: .silent)

        XCTAssertEqual(link.access, .notOffered)
        XCTAssertFalse(link.isAvailable)
        XCTAssertTrue(link.isOffered, "it did advertise it — that is the whole point")
        XCTAssertFalse(link.isImplemented)
    }

    /// And a frame arriving settles it, whatever the welcome said. No host
    /// without a copilot layer can send one of these.
    func testAFrameProvesTheMachineHasOne() {
        link.welcomed(capabilities: [Copilot.capability], offer: .silent)
        link.apply(pushed: CopilotGrant(read: true, act: false))

        XCTAssertTrue(link.isImplemented)
        XCTAssertEqual(link.access, .watch)
    }

    /// The other way round: a machine that showed a copilot but does not name
    /// the capability is a host this app has no agreed vocabulary with, and
    /// sending it frames on the strength of one field would be guessing.
    func testTheFieldAloneDoesNotOpenTheScreen() {
        link.welcomed(capabilities: [], offer: CopilotOffer(stated: true,
                                                            grant: CopilotGrant(read: true, act: true)))

        XCTAssertEqual(link.access, .notOffered)
        XCTAssertTrue(wire.sent.isEmpty)
    }

    // MARK: - Subscribing

    /**
     * A watching phone asks for the three things a connection does not replay by
     * itself, and asks on every welcome.
     *
     * The desktop's subscription belongs to the *socket*, so a reconnect knows
     * nothing about what the last one was watching — the same reason
     * `askDevServers` is re-sent rather than remembered.
     */
    func testAWatchingPhoneSubscribesOnEveryWelcome() {
        welcome(read: true)
        XCTAssertEqual(wire.sent, [.copilotAttach, .copilotSessions, .copilotPending])

        welcome(read: true)
        XCTAssertEqual(wire.sent.count, 6, "a second connection subscribes again")
    }

    /// Nothing is sent for a phone that may not watch. A frame that can only be
    /// answered `unauthorized` is a frame worth not sending.
    func testAPhoneWithNoGrantSendsNothing() {
        welcome()
        link.refresh()
        link.loadLog()

        XCTAssertTrue(wire.sent.isEmpty)
    }

    /**
     * Attaching starts nothing.
     *
     * `copilot.start` is deliberately separable from `copilot.attach` because it
     * spends money: a screen that started a second Claude process because
     * somebody looked at it would be a screen with a bill attached to opening
     * it. So even the fullest grant subscribes without starting.
     */
    func testSubscribingNeverStartsARun() {
        welcome(read: true, act: true)

        XCTAssertFalse(wire.sent.contains(.copilotStart))
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
        welcome(read: true)
        wire.clear()

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
        welcome(read: true, act: true)
        wire.clear()

        XCTAssertTrue(link.say("  what happened overnight  "))
        XCTAssertEqual(wire.sent, [.copilotSay(text: "what happened overnight")],
                       "trimmed, because trailing newlines from a keyboard are not the question")
    }

    /**
     * **A newline is a control byte, and the desktop refuses a message carrying
     * one.**
     *
     * `parseClientMessage` states it as a security check rather than a tidiness
     * one: the text lands in a pty holding a Claude CLI, where a newline submits
     * — so half the message would become a turn somebody pays for and the rest
     * would become a second one. A multi-line message is therefore not a longer
     * message, it is a refused one, and this end has to know that before it
     * sends.
     *
     * Repaired rather than refused, and only because of where the text comes
     * from: it was typed on this device by the person looking at the screen, and
     * a space is what they meant by a line break in a medium that has no lines.
     * The same substitution runs as the field is typed into, so what is on
     * screen is what goes.
     */
    func testAMultiLineMessageIsFlattenedBecauseTheDesktopWouldRefuseIt() {
        welcome(read: true, act: true)
        wire.clear()

        XCTAssertTrue(link.say("what happened\novernight\r\nin the app folder\u{7}?"))
        XCTAssertEqual(wire.sent,
                       [.copilotSay(text: "what happened overnight  in the app folder ?")])
    }

    /// And a message that was only control characters is nothing at all — not an
    /// empty frame the desktop will refuse for a second reason.
    func testAMessageOfOnlyControlCharactersIsNotSent() {
        welcome(read: true, act: true)
        wire.clear()

        XCTAssertFalse(link.say("\n\n\t"))
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    /// An empty composer sends nothing and reports nothing. It is not an error,
    /// it is a person who has not typed anything yet.
    func testAnEmptyMessageIsNotSentAndIsNotAnError() {
        welcome(read: true, act: true)
        wire.clear()

        XCTAssertFalse(link.say("   \n  "))
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(errors.isEmpty)
    }

    /**
     * Over-length is refused with the number rather than truncated.
     *
     * A `copilot.say` is one utterance and half of one is a different question —
     * unlike a paste, which `chunkInput` may legitimately split because a
     * terminal has no notion of a message at all. Sending the first 16 KiB of a
     * question to an agent that will act on it is the wrong failure.
     */
    func testAnOversizeMessageIsRefusedRatherThanCut() {
        welcome(read: true, act: true)
        wire.clear()

        XCTAssertFalse(link.say(String(repeating: "x", count: Copilot.maxSayBytes + 1)))
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertEqual(errors.count, 1)
    }

    /**
     * A message that could not be sent is reported and **not** cleared.
     *
     * `say` returns false so the composer keeps the text. A message that
     * vanished out of a field because a socket was down is a message somebody
     * has to retype, and they would not know they had to until the answer never
     * came.
     */
    func testAMessageOverADeadSocketIsReportedRatherThanLost() {
        welcome(read: true, act: true)
        wire.accepts = false

        XCTAssertFalse(link.say("what happened overnight"))
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("not sent"))
    }

    // MARK: - Consent, watched and not answered

    /**
     * **There is no way to answer a question from here.**
     *
     * The alter tier's whole safety property is *a human at the machine says
     * yes*, and a dialog answered on the device that raised the request is
     * answered by the party being confirmed. So the phone sees the summary and
     * the countdown, and the set of verbs it can send contains nothing that
     * settles one.
     *
     * Written as an assertion about the *whole* vocabulary rather than about the
     * absence of one name, because the failure to guard against is a new frame:
     * a notification action, a "nudge", a snooze. Any of them fails this the day
     * it is added, which is the point at which somebody has to come and read
     * §4.5 rather than after it has shipped.
     */
    func testThePhoneCanWatchAQuestionAndHasNoVerbThatAnswersIt() {
        welcome(read: true, act: true)
        link.apply(pending: [question("q1")])

        XCTAssertEqual(link.pending.map(\.id), ["q1"])
        XCTAssertEqual(link.pending.first?.secondsLeft(now: Date(timeIntervalSince1970: 1_755_400_060)),
                       60, "the countdown is the desktop's own deadline")

        // Every verb this phone can send, encoded. The list is exhaustive by
        // construction: a case added to `ClientMessage` that is not here is a
        // case this test cannot see, which is why the count is asserted too.
        let verbs: [ClientMessage] = [
            .copilotAttach, .copilotDetach, .copilotState, .copilotSessions,
            .copilotLog(limit: Copilot.logPage, before: nil), .copilotPending,
            .copilotStart, .copilotSay(text: "hi"), .copilotCancel, .copilotStop,
        ]
        let names = Set(verbs.compactMap { frame -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(WireCodec.encode(frame).utf8)),
                  let fields = object as? [String: Any] else { return nil }
            // Nothing on any of them names a question, either. A frame carrying
            // an `id` would be the shape an answer takes even before it is
            // called one.
            XCTAssertNil(fields["id"])
            return fields["t"] as? String
        })

        XCTAssertEqual(names, ["copilot.attach", "copilot.detach", "copilot.state",
                               "copilot.sessions", "copilot.log", "copilot.pending",
                               "copilot.start", "copilot.say", "copilot.cancel", "copilot.stop"],
                       "the copilot vocabulary is these ten — an eleventh that allows, refuses, "
                       + "nudges or snoozes belongs in COPILOT-REMOTE.md §4.6 first")
    }

    /// The badge answers from the state until the questions themselves arrive,
    /// so it is not late for exactly the thing it exists to be early about.
    func testTheWaitingCountAnswersFromTheStateUntilTheQuestionsArrive() {
        welcome(read: true)
        link.apply(state: state(pending: 2))
        XCTAssertEqual(link.waitingCount, 2)

        link.apply(pending: [question("q1")])
        XCTAssertEqual(link.waitingCount, 1, "once they arrive, they are the answer")
    }

    // MARK: - The conversation

    /**
     * Merge by id: replace on a match, append otherwise.
     *
     * A streaming answer arrives as the same id with more text in it each time,
     * which is what makes it readable rather than a screenful of fragments.
     */
    func testAStreamingAnswerIsReplacedRatherThanRepeated() {
        welcome(read: true, act: true)
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
        welcome(read: true, act: true)
        link.apply(chat: "r-1", messages: [message("m1", "first")], reset: true)
        link.apply(chat: "r-2", messages: [message("m9", "someone else's answer")], reset: false)

        XCTAssertEqual(link.timeline.count, 1)
        XCTAssertEqual(link.chatRun, "r-1")
    }

    /// A `reset` adopts the run and replaces the conversation — and leaves the
    /// tool rows alone, because the machinery either side of it happened
    /// whatever the chat says.
    func testAResetReplacesTheConversationAndKeepsTheMachinery() {
        welcome(read: true, act: true)
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
        welcome(read: true)
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
        welcome(read: true)
        for index in 0 ..< (Copilot.maxTimelineRows + 40) { link.apply(tool: action("a\(index)")) }

        XCTAssertEqual(link.timeline.count, Copilot.maxTimelineRows)
        XCTAssertEqual(link.timeline.first?.id, "a:a40")
    }

    /// A run that has gone takes its conversation with it — and leaves the tool
    /// rows, which are history either way.
    func testAStateWithNoRunClearsTheConversation() {
        welcome(read: true, act: true)
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
        welcome(read: true)
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
        welcome(read: true)
        link.loadLog()
        link.apply(log: [action("a1")], more: false)
        wire.clear()

        link.loadOlder()
        XCTAssertTrue(wire.sent.isEmpty)
    }

    // MARK: - Losing the connection, and losing the grant

    /**
     * A drop keeps what happened and discards what is claimed.
     *
     * The conversation and the tool rows are things that **happened** — the
     * words really were said — so they stay on screen under the connection
     * banner. The state and the pending questions are claims about the present,
     * one of them with a countdown on it, and nothing is going to update either
     * once the socket is gone. A two-minute timer ticking over a dead channel is
     * the "looks connected when it is not" failure this whole client is built
     * around avoiding.
     */
    func testADropKeepsTheHistoryAndDiscardsTheClaims() {
        welcome(read: true, act: true)
        link.apply(chat: "r-1", messages: [message("m1", "hello")], reset: true)
        link.apply(tool: action("a1"))
        link.apply(state: state(run: "r-1", pending: 1))
        link.apply(pending: [question("q1")])

        link.connectionLost()

        XCTAssertEqual(link.timeline.count, 2, "what was said and done still happened")
        XCTAssertNil(link.state)
        XCTAssertTrue(link.pending.isEmpty)
        XCTAssertEqual(link.waitingCount, 0, "no badge for a question nothing will update")
        XCTAssertEqual(link.access, .direct, "and the screen does not vanish for a reconnect")
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
        welcome(read: true, act: true)
        link.apply(chat: "r-1", messages: [message("m1", "hello")], reset: true)
        link.apply(tool: action("a1"))
        link.apply(pending: [question("q1")])
        wire.clear()

        link.apply(pushed: .none)

        XCTAssertEqual(link.access, .notGranted)
        XCTAssertTrue(link.timeline.isEmpty)
        XCTAssertTrue(link.pending.isEmpty)
        XCTAssertNil(link.chatRun)
        // Nothing is sent. `copilot.detach` needs `read` like every other frame
        // on this surface, so a phone that has just lost it would be answered
        // with an `unauthorized` banner for trying to be polite.
        XCTAssertTrue(wire.sent.isEmpty)
    }

    /// Forgetting the machine forgets what it was, too. A permission remembered
    /// across a teardown is a permission this phone would draw controls for
    /// against a machine it has not been readmitted to.
    func testForgettingTheMachineForgetsTheGrantAndTheCopilot() {
        welcome(read: true, act: true)
        link.apply(tool: action("a1"))

        link.forget()

        XCTAssertEqual(link.access, .notOffered)
        XCTAssertFalse(link.isImplemented)
        XCTAssertTrue(link.timeline.isEmpty)
    }
}
