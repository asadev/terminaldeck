/**
 * The session's bar and its conversation, on the wire and in the model.
 *
 * These are the parts of L4 that are wrong *silently*: a fraction lifted out of
 * a record this app does not own, a plan figure that must be the worst window
 * and not the first, an answer matched to the wrong question, and a chat read
 * folded into what is already held. The shapes on screen are checked by looking
 * at them on a simulator; these are the decisions a screenshot cannot show.
 */

import XCTest
@testable import TerminalDeck

final class SessionBarTests: XCTestCase {

    // MARK: - Narrowing

    func testAPlanReportAnswersItsWorstWindowAndNotItsFirst() {
        // A person is limited by whichever window they are nearest the end of.
        // Reading the first would draw a calm ring while the weekly window is
        // what actually stops them working.
        let reading: [String: Any] = [
            "readings": [
                ["window": "session", "used": ["state": "reported", "fraction": 0.12]],
                ["window": "weekly", "used": ["state": "reported", "fraction": 0.85]],
                ["window": "opus", "used": ["state": "not-reported"]],
            ],
        ]
        XCTAssertEqual(WireCodec.planFraction(reading), 0.85)
    }

    func testAReportWithNothingReportedAnswersNothing() {
        /*
         * Not zero. `used` is a union on the wire precisely so nothing can
         * `?? 0` its way past the difference: a ring drawn at 0% reads as *you
         * have used nothing*, which is a claim, while no ring at all is the
         * absence it actually is.
         */
        let reading: [String: Any] = [
            "readings": [["window": "weekly", "used": ["state": "not-reported"]]],
        ]
        XCTAssertNil(WireCodec.planFraction(reading))
        XCTAssertNil(WireCodec.planFraction(["readings": []]))
        XCTAssertNil(WireCodec.planFraction(["nothing": true]))
        XCTAssertNil(WireCodec.planFraction(nil))
    }

    func testAFractionIsBoundedRatherThanTrusted() {
        // A bar drawn from 3.4 is a bar that leaves its own frame, which is the
        // defect he filmed on the desktop one element down.
        XCTAssertEqual(WireCodec.fraction(3.4), 1)
        XCTAssertEqual(WireCodec.fraction(-2), 0)
        XCTAssertNil(WireCodec.fraction(Double.nan))
        XCTAssertNil(WireCodec.fraction("0.5"))
    }

    func testABooleanIsNotAFraction() {
        // `JSONSerialization` hands back `NSNumber` for `true` as well as for
        // every JSON number, so an unguarded reader draws a full ring out of a
        // flag.
        XCTAssertNil(WireCodec.fraction(true))
        XCTAssertNil(WireCodec.fraction(false))
    }

    func testContextIsAPercentageAndAStateSaysWhetherThereIsOne() {
        XCTAssertEqual(WireCodec.contextFraction(["state": "reported", "percent": 4] as [String: Any]), 0.04)
        // `not-reported` is the far end saying there is no figure — a different
        // thing from a figure of zero, and it draws no bar.
        XCTAssertNil(WireCodec.contextFraction(["state": "not-reported", "percent": 0] as [String: Any]))
        XCTAssertNil(WireCodec.contextFraction(["state": "reported"] as [String: Any]))
    }

    func testARefreshCarriesItsReportOneLevelDown() {
        // A `refresh` answers with the outcome *and* the report; a `plan`
        // answers with the report alone. One reader, because inventing a second
        // path is how the two come apart.
        let refresh: [String: Any] = [
            "outcome": "ok",
            "report": ["readings": [["used": ["state": "reported", "fraction": 0.4]]]],
        ]
        XCTAssertEqual(WireCodec.usageFigures(want: .refresh, reading: refresh).plan, 0.4)
        let plain: [String: Any] = ["readings": [["used": ["state": "reported", "fraction": 0.4]]]]
        XCTAssertEqual(WireCodec.usageFigures(want: .plan, reading: plain).plan, 0.4)
    }

    // MARK: - Accounts

    func testAnAccountColourIsACustomPropertyNameOrNothing() {
        /*
         * The string arrives from another machine and its only use here is to
         * pick a colour out of a table. Anything that is not a plain custom
         * property name is dropped and the dot keeps its neutral fill.
         */
        XCTAssertEqual(WireCodec.customProperty("--status-completed"), "--status-completed")
        XCTAssertNil(WireCodec.customProperty("#c96"))
        XCTAssertNil(WireCodec.customProperty("--"))
        XCTAssertNil(WireCodec.customProperty("--a); background: url(x"))
        XCTAssertNil(WireCodec.customProperty(nil))
    }

    func testOneMalformedAccountDoesNotTakeTheListWithIt() {
        let rows: [Any] = [
            ["id": "system", "name": "Default", "provider": "claude", "color": "--accent", "system": true],
            ["name": "no id at all"],
            ["id": "second", "name": "Work", "provider": "claude"],
        ]
        let accounts = WireCodec.accounts(rows)
        XCTAssertEqual(accounts.map(\.id), ["system", "second"])
        XCTAssertTrue(accounts[0].system)
        XCTAssertNil(accounts[1].color)
    }

    func testALoginOfAnotherAgentIsForeignAndOneWithNoAgentIsNot() {
        let claude = WireAccount(id: "a", name: "Default", provider: "claude", color: nil, system: true)
        let codex = WireAccount(id: "b", name: "Default", provider: "codex", color: nil, system: true)
        let unnamed = WireAccount(id: "c", name: "Older", provider: nil, color: nil, system: false)
        XCTAssertTrue(foreignAccount(current: claude, account: codex))
        XCTAssertFalse(foreignAccount(current: claude, account: claude))
        // An older machine that did not name its agent leaves the row pressable
        // rather than dimming it on a guess.
        XCTAssertFalse(foreignAccount(current: claude, account: unnamed))
        XCTAssertFalse(foreignAccount(current: nil, account: codex))
    }

    // MARK: - Frames

    func testTheTwoVerbsEncodeAsTheDesktopParsesThem() {
        XCTAssertEqual(
            WireCodec.encode(.usageRead(rid: "r1", id: "s1", want: .context, force: false)).sortedJSON(),
            #"{"force":false,"id":"s1","rid":"r1","t":"usage.read","want":"context"}"#)
        XCTAssertEqual(
            WireCodec.encode(.accountSwitch(rid: "r2", id: "s1", accountId: "second")).sortedJSON(),
            #"{"accountId":"second","id":"s1","rid":"r2","t":"account.switch"}"#)
    }

    func testAUsageReadingIsNarrowedOnArrival() {
        let raw = #"""
        {"t":"usage.reading","rid":"r1","id":"s1","want":"context",
         "answer":{"reading":{"state":"reported","percent":41.6}}}
        """#
        guard case let .ok(message, _) = WireCodec.decode(raw),
              case let .usageReading(_, _, want, figures) = message else {
            return XCTFail("expected a usage.reading")
        }
        XCTAssertEqual(want, .context)
        XCTAssertEqual(figures.context ?? 0, 0.416, accuracy: 0.0001)
    }

    func testAReadingOfNullIsNoFigureRatherThanZero() {
        let raw = #"{"t":"usage.reading","rid":"r1","id":"s1","want":"plan","answer":{"reading":null}}"#
        guard case let .ok(message, _) = WireCodec.decode(raw),
              case let .usageReading(_, _, _, figures) = message else {
            return XCTFail("expected a usage.reading")
        }
        XCTAssertNil(figures.plan)
    }

    func testAnAccountStateWithNoCurrentIsNotAFailure() {
        let raw = #"""
        {"t":"account.state","rid":"r1","id":"s1","current":null,
         "accounts":[{"id":"system","name":"Default","provider":"claude","color":"--accent","system":true}]}
        """#
        guard case let .ok(message, _) = WireCodec.decode(raw),
              case let .accountState(_, _, current, accounts) = message else {
            return XCTFail("expected an account.state")
        }
        XCTAssertNil(current)
        XCTAssertEqual(accounts.count, 1)
    }

    // MARK: - The model

    @MainActor
    func testNothingIsAskedOfAMachineThatDidNotOfferIt() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [])
        bar.follow("s1")
        XCTAssertTrue(wire.sent.isEmpty)

        bar.welcomed(capabilities: [WireCapability.usage, WireCapability.account])
        bar.follow("s1")
        XCTAssertEqual(wire.sent.count, 3)
    }

    @MainActor
    func testAnAnswerToSomebodyElsesQuestionIsDropped() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.usage])
        bar.follow("s1")
        // A request id this bar never minted — the copilot's, or a stale one
        // from the connection before this.
        let figures = UsageFigures(plan: 0.9, context: nil)
        XCTAssertFalse(bar.receive(.usageReading(rid: "someone-else", id: "s1", want: .plan, figures: figures)))
        XCTAssertNil(bar.plan)
    }

    @MainActor
    func testAnAnswerAboutAnotherSessionIsDropped() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.usage])
        bar.follow("s1")
        guard case let .usageRead(rid, _, want, _) = wire.sent[0] else { return XCTFail("expected a usage.read") }
        // The same request id, a different session: what arrives when a screen
        // has moved on between the question and the answer. A ring from another
        // session is worse than no ring.
        XCTAssertFalse(bar.receive(.usageReading(rid: rid, id: "s2", want: want,
                                                 figures: UsageFigures(plan: nil, context: 0.5))))
        XCTAssertNil(bar.context)
    }

    @MainActor
    func testADroppedSocketTakesTheFigures() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.usage])
        bar.follow("s1")
        guard case let .usageRead(rid, _, _, _) = wire.sent[0] else { return XCTFail("expected a usage.read") }
        _ = bar.receive(.usageReading(rid: rid, id: "s1", want: .context,
                                      figures: UsageFigures(plan: nil, context: 0.5)))

        bar.dropped()
        // A ring is a claim about now and nothing over a dead socket will
        // correct it.
        XCTAssertNil(bar.context)
    }

    /**
     * **Leaving the screen stops the asking and leaves the row alone.**
     *
     * > *"coming back it refreshing the page every time I am coming, it should
     * > stay as it is. If I go back, if I come back, it should not do this
     * > refresh thing, it should stay. The visuals, the UI is refreshing kind of
     * > thing."*
     *
     * `release` used to be `forget`, which nils the three figures — and
     * `SessionBarView` draws nothing at all when all three are nil, so the whole
     * strip above the terminal vanished on the way out and reappeared on the way
     * back in, shoving the emulator up and then down again. The reading is
     * re-asked on `follow` either way; what this stops is the row blinking out
     * of existence in between.
     */
    @MainActor
    func testLeavingAScreenKeepsTheFiguresForThatSession() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.usage])
        bar.follow("s1")
        guard case let .usageRead(rid, _, _, _) = wire.sent[0] else { return XCTFail("expected a usage.read") }
        _ = bar.receive(.usageReading(rid: rid, id: "s1", want: .context,
                                      figures: UsageFigures(plan: nil, context: 0.5)))

        bar.release("s1")

        // Nobody is being followed any more — a session nobody is looking at must
        // not go on being re-read every time it prints.
        XCTAssertNil(bar.sessionID)
        // And the row he comes back to is the row he left.
        XCTAssertEqual(bar.context, 0.5)

        bar.follow("s1")
        XCTAssertEqual(bar.context, 0.5, "returning to the same session must not blank the row first")
    }

    /// A *different* session still gets a clean bar, which is what the rule this
    /// replaces was really about: *"a ring from another session is worse than no
    /// ring."*
    @MainActor
    func testAnotherSessionStillClearsTheFigures() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.usage])
        bar.follow("s1")
        guard case let .usageRead(rid, _, _, _) = wire.sent[0] else { return XCTFail("expected a usage.read") }
        _ = bar.receive(.usageReading(rid: rid, id: "s1", want: .context,
                                      figures: UsageFigures(plan: nil, context: 0.5)))

        bar.release("s1")
        bar.follow("s2")

        XCTAssertNil(bar.context)
    }

    @MainActor
    func testASwitchThatNeverLeftDoesNotLeaveTheBarSpinning() {
        let wire = RecordingWire()
        wire.accepting = false
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.account])
        bar.follow("s1")
        bar.switchTo("second")
        // A spinner nobody is going to stop is worse than a figure that never
        // arrives: the chip would be dimmed and unpressable for the life of the
        // screen.
        XCTAssertFalse(bar.busy)
    }

    // MARK: - Usage, the best version: a figure is drawn only while it is true

    @MainActor
    func testAFigureIsFreshWhenItLandsAndStaleWhenTheSessionWritesAgain() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.usage])
        bar.follow("s1")
        guard case let .usageRead(rid, _, _, _) = wire.sent[0] else { return XCTFail("expected a usage.read") }
        _ = bar.receive(.usageReading(rid: rid, id: "s1", want: .context,
                                      figures: UsageFigures(plan: nil, context: 0.5)))

        // Just landed: genuinely fresh, and drawn.
        XCTAssertEqual(bar.freshContext, 0.5)

        // The session prints — the window is moving, so the reading is behind it
        // and withdrawn, though the raw value is kept for the re-read to replace.
        bar.noteOutput()
        XCTAssertNil(bar.freshContext, "a context read is stale the moment the session writes again")
        XCTAssertEqual(bar.context, 0.5)
    }

    @MainActor
    func testAKeptFigureIsWithheldWhileNobodyFollowsAndReturnsOnComingBack() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.usage])
        bar.follow("s1")
        let planRid = wire.sent.compactMap { message -> String? in
            if case let .usageRead(rid, _, .plan, _) = message { return rid }
            return nil
        }.first
        guard let planRid else { return XCTFail("expected a plan usage.read") }
        _ = bar.receive(.usageReading(rid: planRid, id: "s1", want: .plan,
                                      figures: UsageFigures(plan: 0.7, context: nil)))
        XCTAssertEqual(bar.freshPlan, 0.7)

        // Left the screen: the row is kept (see the release tests) but nothing is
        // being followed, so the figure is not asserted as current.
        bar.release("s1")
        XCTAssertNil(bar.freshPlan, "a figure nobody is following is not a current reading")
        XCTAssertEqual(bar.plan, 0.7, "the raw value is kept for a smooth return")

        // Back on the same session: shown again at once, no round trip to wait on.
        bar.follow("s1")
        XCTAssertEqual(bar.freshPlan, 0.7)
    }

    @MainActor
    func testASwitchWithdrawsBothFiguresUntilTheyAreReadForTheNewLogin() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.usage, WireCapability.account])
        bar.follow("s1")
        // The plan read's own rid — `follow` sends a context read and a plan
        // read, and the receiver matches the answer's `want` to the ask.
        let planRid = wire.sent.compactMap { message -> String? in
            if case let .usageRead(rid, _, .plan, _) = message { return rid }
            return nil
        }.first
        guard let planRid else { return XCTFail("expected a plan usage.read") }
        _ = bar.receive(.usageReading(rid: planRid, id: "s1", want: .plan,
                                      figures: UsageFigures(plan: 0.7, context: nil)))
        XCTAssertEqual(bar.freshPlan, 0.7)

        // A switch replaces the process; the old login's ring must not sit over
        // the new one. Withdrawn on the press, before any answer.
        bar.switchTo("second")
        XCTAssertNil(bar.freshPlan, "the pre-switch usage is not the new login's usage")
    }

    // MARK: - Sign out, from the phone (audit gap 20)

    func testASignOutEncodesAsTheMachineParsesIt() {
        XCTAssertEqual(
            WireCodec.encode(.loginsSignout(rid: "r3", accountId: "second")).sortedJSON(),
            #"{"accountId":"second","rid":"r3","t":"logins.signout"}"#)
    }

    func testASignedOutFrameIsMachineScopedAndCarriesOnlyItsOutcome() {
        let raw = #"{"t":"logins.signedout","rid":"r3","ok":true,"message":"Signed out.","session":null}"#
        guard case let .ok(message, _) = WireCodec.decode(raw),
              case let .loginsSignedout(rid, ok) = message else {
            return XCTFail("expected a logins.signedout")
        }
        XCTAssertEqual(rid, "r3")
        XCTAssertTrue(ok)
    }

    @MainActor
    func testSignOutIsNotSentToAMachineThatDoesNotManageItsLogins() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        // Account switch, but not the machine-scoped logins verbs.
        bar.welcomed(capabilities: [WireCapability.account])
        bar.follow("s1")
        wire.sent.removeAll()
        bar.signOut("second")
        // A frame the far end would refuse is not a frame this bar sends.
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertFalse(bar.busy)
    }

    @MainActor
    func testASignedOutAnswerRereadsTheMachinesOwnList() {
        let wire = RecordingWire()
        let bar = SessionBarLink(wire: wire)
        bar.welcomed(capabilities: [WireCapability.account, WireCapability.logins])
        bar.follow("s1")
        wire.sent.removeAll()

        bar.signOut("second")
        guard case let .loginsSignout(rid, accountId) = wire.sent.last else {
            return XCTFail("expected a logins.signout")
        }
        XCTAssertEqual(accountId, "second")
        XCTAssertTrue(bar.busy)

        _ = bar.receive(.loginsSignedout(rid: rid, ok: true))
        XCTAssertFalse(bar.busy)
        // Whether the login is gone is the machine's own probe, read again rather
        // than assumed from the press — an account.read follows.
        XCTAssertTrue(wire.sent.contains { if case .accountRead = $0 { return true }; return false })
    }

    func testOnlyAgentsWithALogoutCommandCanBeSignedOut() {
        // A port of `hasSignOut` in agent-catalog.ts: Claude and Codex have one,
        // Gemini and a shell do not, and an unknown provider falls to false.
        XCTAssertTrue(SessionBarView.canSignOut(provider: "claude"))
        XCTAssertTrue(SessionBarView.canSignOut(provider: "codex"))
        XCTAssertFalse(SessionBarView.canSignOut(provider: "gemini"))
        XCTAssertFalse(SessionBarView.canSignOut(provider: "shell"))
        XCTAssertFalse(SessionBarView.canSignOut(provider: nil))
    }
}

@MainActor
private final class RecordingWire: CopilotWire {
    var sent: [ClientMessage] = []
    var accepting = true

    @discardableResult
    func send(_ message: ClientMessage) -> Bool {
        guard accepting else { return false }
        sent.append(message)
        return true
    }
}

private extension String {
    /// The same JSON with its keys in order, so a frame can be compared as text
    /// without depending on how a dictionary happened to iterate.
    func sortedJSON() -> String {
        guard let data = data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sorted = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: sorted, encoding: .utf8) else { return self }
        return text
    }
}
