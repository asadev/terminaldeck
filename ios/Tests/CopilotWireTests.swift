/**
 * The `copilot` half of the wire, on this end.
 *
 * Five properties are pinned here, and each one is a way this feature could be
 * confidently wrong on screen — or, in two cases, wrong about a permission —
 * while every other test in the suite passed.
 *
 * **No client frame carries a tool name.** The whole enforcement model rests on
 * it: the phone sends prose, the tool calls are made by a CLI on the desktop
 * holding a bearer token this phone does not have, and so *the set of frames a
 * phone can construct contains no tool at all*. Every other design has to
 * enumerate and deny. The corpus test at the foot of this file walks every
 * outbound case and asserts none of them can name one, so the day somebody adds
 * `copilot.tool` "just for a re-run button" is the day this fails.
 *
 * **The grant collapses to nothing whenever it is not literally granted.**
 * Absent, malformed, `"true"`, `1`, a bare `true` — all of them are no access.
 * A JSON file a person may edit will eventually contain one of them, and the
 * difference between reading it as an intention and as a mistake is a difference
 * in who can drive an agent that spends money.
 *
 * **`alter` cannot arrive.** It is not on the wire in any spelling, and a
 * desktop that sent one anyway must not produce a grant that has it. There is no
 * field for it to land in, and this is the test that says so out loud.
 *
 * **A chat frame is dropped rather than merged when it belongs to another run.**
 * That is what the `run` field is for, and without it a run that ended while the
 * phone was in a pocket produces one conversation made of two with no seam
 * visible on screen.
 *
 * **The two time formats on one frame are not swapped.** `ActionRow.at` is an
 * ISO string because `copilot-home.ts` writes ISO into the same file;
 * `ConsentRequest.requestedAt` and `expiresAt` are epoch numbers. Reading either
 * as the other produces a plausible-looking date and a countdown that is wrong
 * by decades.
 */

import XCTest
@testable import TerminalDeck

final class CopilotWireTests: XCTestCase {

    // MARK: - The grant

    func testAWelcomeCarriesTheGrantForThisDevice() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
         "sessions":[],"capabilities":["copilot"],"copilot":{"read":true,"act":true}}
        """#), case let .welcome(_, _, _, _, _, capabilities, _, _, offer) = message else {
            return XCTFail("a welcome with a copilot grant should decode")
        }
        XCTAssertTrue(capabilities.contains(Copilot.capability))
        XCTAssertTrue(offer.stated)
        XCTAssertEqual(offer.grant, CopilotGrant(read: true, act: true))
        XCTAssertTrue(offer.grant.canWatch)
        XCTAssertTrue(offer.grant.canDirect)
    }

    /**
     * **The capability is not the answer to "does this machine have a copilot".**
     *
     * The desktop builds `welcome.capabilities` by filtering `CAPABILITIES` —
     * *every extension this build knows how to serve* — against what its
     * injected objects can actually do, and the filter is a separate line of
     * code from the list it filters. `ios/Harness/host-standin.ts` skips the
     * filter entirely and sends the list verbatim while implementing almost none
     * of it, which is the shape that got an earlier localhost pass reported as
     * verified against an empty screen.
     *
     * The `copilot` field is the answer, because `copilotFrame()` on the desktop
     * writes it only when a copilot layer exists — all-false and absent are
     * different frames there on purpose. So a welcome that names the capability
     * and says nothing in the field is a host advertising something it cannot
     * serve, and the phone has to read it as "no copilot here" rather than as
     * "you have not been given access", which would send somebody to a Mac to
     * look for a switch that is not on it.
     */
    func testTheCapabilityWithoutTheFieldIsNotACopilot() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
         "sessions":[],"capabilities":["copilot","create","localhost","upload","credential","devserver"]}
        """#), case let .welcome(_, _, _, _, _, capabilities, _, _, offer) = message else {
            return XCTFail("the welcome should decode")
        }
        XCTAssertTrue(capabilities.contains(Copilot.capability), "it did advertise it")
        XCTAssertFalse(offer.stated, "and it never showed one")
        XCTAssertEqual(offer.grant, .none)
    }

    /**
     * An all-false field is a machine that **has** a copilot.
     *
     * The whole reason the desktop sends the object rather than omitting it when
     * the grant is empty, and the whole reason this end keeps the two apart. It
     * is the ordinary case — copilot access is off for every device until
     * somebody turns it on — and it is the one state a person can fix, so it has
     * to reach the screen that says where.
     */
    func testAnAllFalseFieldStillMeansTheMachineHasOne() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
         "sessions":[],"capabilities":["copilot"],"copilot":{"read":false,"act":false}}
        """#), case let .welcome(_, _, _, _, _, _, _, _, offer) = message else {
            return XCTFail("the welcome should decode")
        }
        XCTAssertTrue(offer.stated)
        XCTAssertTrue(offer.grant.isEmpty)
    }

    /**
     * A desktop that says nothing about the copilot has granted nothing.
     *
     * The opposite call to `folders`, one field over, where absent means "this
     * desktop predates per-device folder grants" and empty means "a person chose
     * none" — two answers that lead to two screens. There is no such history
     * here: nobody has ever had remote copilot access, so silence has only one
     * honest reading.
     */
    func testAWelcomeWithNoCopilotFieldGrantsNothing() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,"sessions":[]}
        """#), case let .welcome(_, _, _, _, _, _, _, _, offer) = message else {
            return XCTFail("a welcome without the field should still decode")
        }
        XCTAssertEqual(offer, .silent)
        XCTAssertTrue(offer.grant.isEmpty)
    }

    /// A field this app cannot read is a machine that said nothing, not a
    /// machine that said no. The same direction every other refusal in the codec
    /// falls in, and here it is also the safe one: nothing is drawn.
    func testAMalformedCopilotFieldSaysNothing() {
        for liar in [#""yes""#, "null", "7", #"["read"]"#] {
            guard case let .ok(message, _) = WireCodec.decode(#"""
            {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
             "sessions":[],"capabilities":["copilot"],"copilot":\#(liar)}
            """#), case let .welcome(_, _, _, _, _, _, _, _, offer) = message else {
                return XCTFail("\(liar) should still decode as a welcome")
            }
            XCTAssertEqual(offer, .silent, "\(liar) is not a copilot")
        }
    }

    /// Only literal `true` grants. `copilotGrantFrom` on the desktop makes the
    /// same three refusals for the same reason, and this end refuses them again
    /// rather than trusting that it did.
    func testOnlyALiteralTrueGrantsAnything() {
        let liars = [#"{"read":"true","act":"yes"}"#,
                     #"{"read":1,"act":1}"#,
                     #"{"read":"","act":"act"}"#,
                     "true",
                     "null",
                     #"["read"]"#]
        for liar in liars {
            guard case let .ok(message, _) = WireCodec.decode(#"{"t":"copilot.grant","grant":\#(liar)}"#),
                  case let .copilotGrant(grant) = message else {
                return XCTFail("\(liar) should still decode as a frame")
            }
            XCTAssertEqual(grant, .none, "\(liar) is not a grant")
        }
    }

    /**
     * `alter` cannot arrive, however it is spelled.
     *
     * `REMOTE_GRANTABLE_TIERS` is `['read', 'act']`, `set()` clamps it and
     * `load()` scrubs it — and this end has no field for it either, which is the
     * point of the assertion: a desktop that somehow sent one produces a grant
     * with exactly the two booleans in it and nothing else.
     */
    func testAnAlterTierOnTheWireIsNotAGrant() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.grant","grant":{"read":true,"act":false,"alter":true}}
        """#), case let .copilotGrant(grant) = message else {
            return XCTFail("the frame should decode")
        }
        XCTAssertEqual(grant, CopilotGrant(read: true, act: false))
        XCTAssertTrue(grant.canWatch)
        XCTAssertFalse(grant.canDirect, "an alter that arrived anyway must not become act")
    }

    /**
     * `act` without `read` directs nothing.
     *
     * Reachable from a hand-edited `remote-copilot.json` — `copilotGrantFrom`
     * keeps whatever is literally `true` for each grantable tier and has no rule
     * tying one to the other. Against a desktop that refuses the whole surface
     * without `read`, drawing a composer for that grant would draw a control
     * whose every message comes back `unauthorized`.
     */
    func testActWithoutReadIsNotAUsableGrant() {
        let grant = CopilotGrant(read: false, act: true)
        XCTAssertFalse(grant.canWatch)
        XCTAssertFalse(grant.canDirect, "read is the floor for the whole surface")
    }

    // MARK: - State

    /**
     * The whole state frame, spelled as `CopilotStateReport` spells it.
     *
     * Every field name here is copied out of `protocol.ts` rather than out of
     * the prose that specified the feature, and this test is where the two are
     * held together. They were not, once: this client decoded a `status` field
     * against a desktop that sends `desk`, which made `copilotState` return nil
     * for **every real frame** and the whole `copilot.state` message decode as
     * `.failed`. Nothing on the phone said so — the screen simply had no state
     * card, no Start button and no run line, which reads exactly like a copilot
     * that has not answered yet.
     */
    func testTheStateFrameIsTheDesktopsOwnReport() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.state","state":{"desk":"running","run":"01J8ZC4T9K5Q2V7XW3NHRF6MBD",
         "profile":"Work Claude","signedIn":true,"tools":14,"turnTokens":3200,"pending":2,
         "grant":{"read":true,"act":true},"available":true,"reason":null}}
        """#), case let .copilotState(state) = message else {
            return XCTFail("a state frame should decode")
        }
        XCTAssertTrue(state.deskIsRunning)
        XCTAssertEqual(state.run, "01J8ZC4T9K5Q2V7XW3NHRF6MBD")
        XCTAssertTrue(state.hasRun)
        XCTAssertEqual(state.profile, "Work Claude")
        XCTAssertEqual(state.signedIn, true)
        XCTAssertEqual(state.tools, 14)
        XCTAssertEqual(state.turnTokens, 3200)
        XCTAssertEqual(state.pending, 2)
        XCTAssertEqual(state.grant, CopilotGrant(read: true, act: true))
        XCTAssertTrue(state.available)
        XCTAssertNil(state.reason, "a field the machine did not fill must stay absent")
    }

    /**
     * **The desk's copilot and this phone's run are two different things.**
     *
     * The one reading of this frame that a person would act on. `desk` is the
     * conversation somebody is having at the machine; `run` is the only thing
     * this phone can speak to. A screen that drew its Start button off `desk`
     * would offer to start a run that already exists, or refuse to start one
     * because something entirely unrelated is busy at somebody's desk.
     */
    func testTheDeskAndThisPhonesRunAreReadSeparately() {
        guard let running = WireCodec.copilotState(["desk": "running", "run": NSNull()]),
              let stopped = WireCodec.copilotState(["desk": "stopped", "run": "01J8ZC4T9K5Q2V7XW3NHRF6MBD"])
        else { return XCTFail("both should decode") }

        XCTAssertTrue(running.deskIsRunning)
        XCTAssertFalse(running.hasRun, "somebody is at the Mac; this phone still has no run")

        XCTAssertTrue(stopped.deskIsStopped)
        XCTAssertTrue(stopped.hasRun, "and the reverse: a phone's run outlives the desk's")
    }

    /**
     * `signedIn` has three answers, and the third is not "no".
     *
     * Null is *it has not been asked*, which is what the desktop sends before
     * the probe has run. Drawing it as signed out sends somebody to fix an
     * account that is fine.
     */
    func testSignedInIsThreeAnswers() {
        XCTAssertEqual(WireCodec.copilotState(["desk": "running", "signedIn": true])?.signedIn, true)
        XCTAssertEqual(WireCodec.copilotState(["desk": "running", "signedIn": false])?.signedIn, false)
        XCTAssertNil(WireCodec.copilotState(["desk": "running", "signedIn": NSNull()])?.signedIn)
        XCTAssertNil(WireCodec.copilotState(["desk": "running"])?.signedIn)
    }

    /**
     * A host that did not say a run can start has not said one can.
     *
     * `available` and `reason` exist so the phone prints a sentence instead of a
     * Start button that fails, which is the desktop's own argument for putting
     * them on the wire. Defaulting an absent `available` to true would put the
     * button back for exactly the hosts that cannot serve it.
     */
    func testAnAbsentAvailableIsNotAvailable() {
        XCTAssertEqual(WireCodec.copilotState(["desk": "running"])?.available, false)
        XCTAssertEqual(WireCodec.copilotState(["desk": "running", "available": true])?.available, true)
        // And a 1 is not a true, for the same reason it is not one in a grant.
        XCTAssertEqual(WireCodec.copilotState(["desk": "running", "available": 1])?.available, false)

        let refused = WireCodec.copilotState([
            "desk": "stopped", "available": false,
            "reason": "The copilot’s tools are not running on this machine.",
        ])
        XCTAssertEqual(refused?.reason, "The copilot’s tools are not running on this machine.")
    }

    /**
     * The grant repeated on a state frame is optional here, and only here.
     *
     * Everywhere else on this wire an absent grant means no access, which is the
     * safe reading. On this frame it would mean *revoking this phone's own
     * screen* because a host did not repeat a field — so absent has to stay "did
     * not say" when the cost of guessing is taking away a permission nobody
     * touched.
     */
    func testAStateWithNoGrantDoesNotRevokeOne() {
        XCTAssertNil(WireCodec.copilotState(["desk": "running"])?.grant)
        XCTAssertEqual(WireCodec.copilotState(["desk": "running", "grant": ["read": true, "act": false]])?.grant,
                       CopilotGrant(read: true, act: false))
    }

    /**
     * A desk word this build has never heard of is printed, not mapped.
     *
     * The same call `RemoteSession.status` makes: the vocabulary belongs to the
     * desktop and a newer build will one day send a fourth word. Mapping it onto
     * `stopped` would draw a Start button over a copilot that is running.
     */
    func testAnUnknownDeskWordIsNeitherRunningNorStopped() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.state","state":{"desk":"reloading"}}
        """#), case let .copilotState(state) = message else {
            return XCTFail("an unfamiliar desk word should still decode")
        }
        XCTAssertEqual(state.desk, "reloading")
        XCTAssertFalse(state.deskIsRunning)
        XCTAssertFalse(state.deskIsStopped, "an unknown word is not a stopped copilot")
        XCTAssertFalse(state.deskIsStarting)
    }

    /// The one field the frame exists to carry. Without it there is nothing to
    /// draw and a state card would be inventing one.
    func testAStateWithNoDeskIsRefused() {
        guard case .failed = WireCodec.decode(#"{"t":"copilot.state","state":{"run":"r-1"}}"#) else {
            return XCTFail("a state with no desk says nothing and must be refused")
        }
    }

    // MARK: - Chat

    func testAChatFrameCarriesParsedMessages() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.chat","run":"r-1","reset":true,"messages":[
          {"id":"m1","role":"you","text":"what happened overnight","at":1755400000000},
          {"id":"m2","role":"agent","text":"Two sessions finished.","at":1755400001000}]}
        """#), case let .copilotChat(run, messages, reset) = message else {
            return XCTFail("a chat frame should decode")
        }
        XCTAssertEqual(run, "r-1")
        XCTAssertTrue(reset)
        XCTAssertEqual(messages.map(\.id), ["m1", "m2"])
        XCTAssertEqual(messages.first?.role, .you)
        XCTAssertEqual(messages.last?.role, .agent)
        XCTAssertEqual(messages.last?.text, "Two sessions finished.")
    }

    /**
     * A role this build has never heard of is drawn as the agent, never as the
     * person.
     *
     * A bubble on the right of the screen is a claim about who said something. A
     * future role — a tool narration, a system note — must not be able to put
     * words in somebody's mouth, and "agent" is the fallback that cannot.
     */
    func testAnUnknownRoleIsNeverTheUser() {
        guard let message = WireCodec.copilotMessage(["id": "m1", "role": "system", "text": "…"]) else {
            return XCTFail("an unfamiliar role should still decode")
        }
        XCTAssertEqual(message.role, .agent)
    }

    /**
     * The newlines survive, and the control characters do not.
     *
     * An answer to "what happened overnight" is paragraphs, and
     * `WireCodec.displayLine` — which is right for a dev server's status line —
     * would flatten it to one line and cut it at 200 characters. This is the
     * other rule, for the other kind of string, and the two are separate on
     * purpose.
     */
    func testAMessageKeepsItsParagraphsAndLosesItsControlCharacters() {
        guard let message = WireCodec.copilotMessage([
            "id": "m1", "role": "agent", "text": "one\n\ntwo\u{7}\u{1b}three\ttab",
        ]) else {
            return XCTFail("the message should decode")
        }
        XCTAssertEqual(message.text, "one\n\ntwothree\ttab",
                       "newlines and tabs stay; the bell and the escape go")
    }

    /// The cap is enforced on this end too. A cap only the far end applies is
    /// not a cap — the same rule every bound in `Wire` is written under.
    func testAnOversizeMessageIsCutHere() {
        let huge = String(repeating: "x", count: Copilot.maxMessageChars + 500)
        guard let message = WireCodec.copilotMessage(["id": "m1", "role": "agent", "text": huge]) else {
            return XCTFail("the message should decode")
        }
        XCTAssertEqual(message.text.count, Copilot.maxMessageChars)
    }

    func testATruncationFlagSurvives() {
        guard let message = WireCodec.copilotMessage([
            "id": "m1", "role": "agent", "text": "cut", "truncated": true,
        ]) else {
            return XCTFail("the message should decode")
        }
        XCTAssertTrue(message.truncated, "a bubble that was shortened has to be able to say so")
    }

    // MARK: - Tool rows

    /**
     * A tool row, spelled as `CopilotActionRow` spells it — which is **flat**.
     *
     * `deviceId` sits at the top level. It used to be read out of a nested
     * `caller` object, which is the shape of the desktop's *internal* `ActionRow`
     * one layer in, and the field the wire carries was therefore nil on every
     * row — so the Activity screen quietly attributed every phone's action to
     * nobody, in the one place that question can be answered at all.
     */
    func testAToolRowIsFlatAndCarriesWhoAsked() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.tool","row":{"id":"a1","at":"2026-08-17T04:00:00.000Z","tool":"sessions.start",
         "tier":"act","outcome":"ok","detail":"Started a session in ~/Projects/app",
         "refusal":null,"deviceId":"d-7"}}
        """#), case let .copilotTool(row) = message else {
            return XCTFail("a tool row should decode")
        }
        XCTAssertEqual(row.tool, "sessions.start")
        XCTAssertEqual(row.tier, "act")
        XCTAssertEqual(row.outcome, "ok")
        XCTAssertFalse(row.wasRefused)
        XCTAssertEqual(row.deviceId, "d-7")
        XCTAssertNil(row.refusal)
    }

    /**
     * A refusal is a row like any other, and it is the row that carries the most.
     *
     * This is what a permission boundary looks like from the outside: the tool
     * that was refused and the reason in the desktop's own word. A client that
     * dropped these would leave a person watching their copilot go quiet with no
     * way to find out why.
     */
    func testARefusalArrivesAsARowWithItsReason() {
        guard let row = WireCodec.copilotAction([
            "id": "a2", "tool": "settings.write", "tier": "alter", "outcome": "refused",
            "detail": "Would have changed the theme", "refusal": "not-granted",
        ]) else {
            return XCTFail("a refused row should decode")
        }
        XCTAssertTrue(row.wasRefused)
        XCTAssertEqual(row.refusal, "not-granted")
        XCTAssertEqual(row.tier, "alter")
    }

    /**
     * **A null `deviceId` is the person at the machine**, which is a fact rather
     * than an absence.
     *
     * `CopilotActionRow` says so outright, and it is worth a test because the
     * shape invites the opposite reading: everything else optional on this wire
     * means "the desktop did not say". Hedging this one would leave the rows a
     * person most wants attributed — their own — as the only unlabelled ones.
     */
    func testANullDeviceIdIsThePersonAtTheMachine() {
        guard let row = WireCodec.copilotAction([
            "id": "a3", "tool": "sessions.list", "outcome": "ok",
            "detail": "Listed 4 sessions", "deviceId": NSNull(),
        ]) else {
            return XCTFail("the row should decode")
        }
        XCTAssertNil(row.deviceId)
    }

    /// Four fields are what a row exists to say. A row missing its outcome
    /// cannot be coloured, and a row missing its detail is a row about nothing.
    func testARowMissingWhatItExistsToSayIsDropped() {
        XCTAssertNil(WireCodec.copilotAction(["id": "a4", "tool": "x", "detail": "d"]),
                     "no outcome")
        XCTAssertNil(WireCodec.copilotAction(["id": "a4", "outcome": "ok", "detail": "d"]),
                     "no tool")
        XCTAssertNil(WireCodec.copilotAction(["tool": "x", "outcome": "ok", "detail": "d"]),
                     "no id, so nothing can merge or de-duplicate it")
    }

    /**
     * The ISO stamp becomes a time, and a bad one becomes no time at all.
     *
     * Never "now", which would file a row written last night at the top of
     * today. The row still draws — the time is the least of what it carries.
     */
    func testAnIsoStampBecomesEpochMillisecondsAndAnUnparseableOneBecomesNothing() {
        XCTAssertEqual(WireCodec.isoMilliseconds("2026-08-17T04:00:00.000Z"), 1_786_939_200_000)
        // Without fractional seconds, which is what a hand-edited row looks
        // like. Apple's ISO parser is exact rather than lenient, so this is two
        // formatters or it is a silent nil.
        XCTAssertEqual(WireCodec.isoMilliseconds("2026-08-17T04:00:00Z"), 1_786_939_200_000)
        XCTAssertNil(WireCodec.isoMilliseconds("yesterday"))
        XCTAssertNil(WireCodec.isoMilliseconds(1_786_939_200_000),
                     "a number is not this field — the two time formats on this wire are not swappable")
    }

    // MARK: - Pending confirmations

    /**
     * A pending question, spelled as `CopilotPendingRow` spells it.
     *
     * Five fields, and **no tier and no arguments**. An earlier draft of this
     * client decoded both and drew a consent sheet around them; against the real
     * desktop that sheet said "Permission: Not stated" over "With: No arguments"
     * on every question it would ever show, which is a screen inviting a
     * judgement it cannot support. The full request lives at the machine where
     * it is answered — see the type's header, and the sheet now says so.
     */
    func testAPendingQuestionIsTheDesktopsOwnRow() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.pending","questions":[{"id":"q1","tool":"settings.write",
         "summary":"Change the theme to light",
         "requestedAt":1755400000000,"expiresAt":1755400120000}]}
        """#), case let .copilotPending(questions) = message else {
            return XCTFail("a pending frame should decode")
        }
        let question = questions.first
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(question?.tool, "settings.write")
        XCTAssertEqual(question?.summary, "Change the theme to light")
        XCTAssertEqual(question?.requestedAt, 1_755_400_000_000)
        XCTAssertEqual(question?.expiresAt, 1_755_400_120_000)
    }

    /**
     * A question with no summary is refused rather than drawn.
     *
     * This is the assertion that matters most in the file. A prompt that arrives
     * without enough context to judge it is a prompt that gets answered without
     * being read — and while this phone has no answer button, the same principle
     * applies to telling somebody to go and answer it at their Mac. A card
     * saying only *"something needs you"* trains a person to walk over and click
     * whatever is on screen.
     */
    func testAQuestionWithNothingToJudgeIsNotDrawn() {
        XCTAssertNil(WireCodec.copilotQuestion(["id": "q1", "tool": "settings.write"]),
                     "no summary")
        XCTAssertNil(WireCodec.copilotQuestion(["id": "q1", "summary": "Do a thing"]),
                     "no tool")
    }

    /// The countdown is arithmetic on the desktop's own deadline, floored at
    /// zero — never negative, and never invented when the desktop sent none.
    func testTheCountdownIsTheDesktopsDeadlineAndNothingElse() {
        let now = Date(timeIntervalSince1970: 1_755_400_000)
        let question = CopilotQuestion(id: "q", tool: "t", summary: "s",
                                       requestedAt: 1_755_400_000_000,
                                       expiresAt: 1_755_400_120_000)
        XCTAssertEqual(question.secondsLeft(now: now), 120)
        XCTAssertEqual(question.secondsLeft(now: now.addingTimeInterval(300)), 0,
                       "a lapsed question counts to zero, never below it")

        let undated = CopilotQuestion(id: "q", tool: "t", summary: "s",
                                      requestedAt: 0, expiresAt: 0)
        XCTAssertNil(undated.secondsLeft(now: now), "no deadline is drawn when none was sent")
    }

    /// The broker caps itself at three outstanding questions, so more than three
    /// is a frame from something this app does not understand — and these are
    /// drawn as full cards with a deadline on each, so an unbounded list would be
    /// a consent surface people scroll rather than read.
    func testThePendingListIsBounded() {
        let rows = (1 ... 9).map {
            #"{"id":"q\#($0)","tool":"t","summary":"s","requestedAt":1,"expiresAt":2}"#
        }.joined(separator: ",")
        guard case let .ok(message, _) = WireCodec.decode(#"{"t":"copilot.pending","questions":[\#(rows)]}"#),
              case let .copilotPending(questions) = message else {
            return XCTFail("the frame should decode")
        }
        XCTAssertEqual(questions.count, 3)
    }

    // MARK: - Sessions and the log

    func testACopilotSessionCarriesTheTurnThatStartedIt() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.sessions","sessions":[{"id":"01J8ZC4T9K5Q2V7XW3NHRF6MBD","title":"app",
         "cwd":"/Users/a/app","provider":"claude","status":"working","originRunId":"r-1"}]}
        """#), case let .copilotSessions(rows) = message else {
            return XCTFail("a session list should decode")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.session.title, "app")
        XCTAssertEqual(rows.first?.originRunId, "r-1")
    }

    func testALogPageSaysWhetherThereIsMore() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.log","more":true,"rows":[
          {"id":"a1","tool":"sessions.list","outcome":"ok","detail":"Listed 4 sessions"}]}
        """#), case let .copilotLog(rows, more) = message else {
            return XCTFail("a log page should decode")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(more)
    }

    // MARK: - Outbound

    func testEveryVerbEncodesToTheNameTheDesktopParses() {
        let expected: [(ClientMessage, String)] = [
            (.copilotAttach, #"{"t":"copilot.attach"}"#),
            (.copilotDetach, #"{"t":"copilot.detach"}"#),
            (.copilotState, #"{"t":"copilot.state"}"#),
            (.copilotSessions, #"{"t":"copilot.sessions"}"#),
            (.copilotPending, #"{"t":"copilot.pending"}"#),
            (.copilotStart, #"{"t":"copilot.start"}"#),
            (.copilotCancel, #"{"t":"copilot.cancel"}"#),
            (.copilotStop, #"{"t":"copilot.stop"}"#),
        ]
        for (message, wire) in expected {
            XCTAssertEqual(WireCodec.encode(message), wire)
        }
    }

    /**
     * Asserted field by field rather than as one string, unlike the single-key
     * verbs above.
     *
     * `JSONSerialization.data(withJSONObject:options:)` does not promise a key
     * order without `.sortedKeys`, and it does not deliver one either: this
     * frame encoded as `{"t":…,"text":…}` in one run of the suite and
     * `{"text":…,"t":…}` in the next, on the same machine, in the same build.
     * A one-key object cannot show that, which is why the verbs above are
     * compared literally and this is not — and why a literal comparison here
     * would be a test that fails a few percent of the time and gets re-run
     * rather than read.
     */
    func testSayCarriesTheProseAndNothingElse() {
        let encoded = WireCodec.encode(.copilotSay(text: "what happened overnight"))
        guard let object = try? JSONSerialization.jsonObject(with: Data(encoded.utf8)),
              let fields = object as? [String: Any] else {
            return XCTFail("it should encode to an object")
        }
        XCTAssertEqual(fields["t"] as? String, "copilot.say")
        XCTAssertEqual(fields["text"] as? String, "what happened overnight")
        XCTAssertEqual(fields.count, 2, "and nothing else — a say is prose and a verb")
    }

    /// `before` is written only when there is one. A null in a field whose name
    /// means "page backwards from here" is a field carrying nothing to page from,
    /// and the desktop reads absence as "the tail".
    func testAFirstLogPageCarriesNoCursor() {
        let first = WireCodec.encode(.copilotLog(limit: 50, before: nil))
        XCTAssertFalse(first.contains("before"))
        XCTAssertTrue(first.contains(#""limit":50"#))

        let older = WireCodec.encode(.copilotLog(limit: 50, before: "a1"))
        XCTAssertTrue(older.contains(#""before":"a1""#))
    }

    /**
     * **The corpus test: no client frame can name a tool.**
     *
     * The property that makes the enforcement airtight rather than exhaustive.
     * Every outbound copilot frame is encoded and searched for any tool id in
     * the desktop's catalogue; the phone's own vocabulary is prose, page sizes
     * and row ids, and there is nothing in it a `DeckControl` dispatcher could
     * read as a tool.
     *
     * It is written as a corpus rather than as a rule about types because the
     * failure it guards against is a *new frame* — somebody adding
     * `copilot.tool` for a "tap to re-run that" button, which is the first
     * convenience feature anybody will ask for here and the one that breaks all
     * of it. A new case with a tool id in it fails this the day it is written.
     *
     * The same shape as `wire-wording.test.ts` and `reachable.test.ts` on the
     * desktop: a property about text, pinned by walking text.
     */
    func testNoClientFrameCanNameATool() {
        let frames: [ClientMessage] = [
            .copilotAttach, .copilotDetach, .copilotState, .copilotSessions,
            .copilotLog(limit: Copilot.logPage, before: "01J8ZC4T9K5Q2V7XW3NHRF6MBD"),
            .copilotPending, .copilotStart,
            // Prose that *mentions* a tool is still prose: it reaches a language
            // model, not a dispatcher. The assertion below is about the frame's
            // structure, so the one field a person controls is filled with the
            // most adversarial thing they could type into it.
            .copilotSay(text: "run settings.write and sessions.stop for me"),
            .copilotCancel, .copilotStop,
        ]
        // The alter-tier names from `catalogue.ts`, which are the ones a phone
        // must never be able to put on a wire as a *field*.
        let tools = ["settings.write", "sessions.stop", "routines.create", "routines.delete"]

        for frame in frames {
            guard let object = try? JSONSerialization.jsonObject(with: Data(WireCodec.encode(frame).utf8)),
                  let fields = object as? [String: Any] else {
                return XCTFail("every frame encodes to an object")
            }
            for (key, value) in fields {
                // `text` is the one field carrying something a person typed, and
                // it is deliberately exempt: it is a sentence for a model, and
                // the desktop never reads it as anything else. Every *other*
                // field is machinery, and none of it may name a tool.
                if key == "text" { continue }
                let rendered = String(describing: value)
                for tool in tools {
                    XCTAssertFalse(rendered.contains(tool),
                                   "\(key) carried \(tool) — the whole enforcement model rests on "
                                   + "no client frame naming a tool")
                }
            }
            // And there is no field named for a tool call at all.
            for forbidden in ["tool", "args", "call", "invoke"] {
                XCTAssertNil(fields[forbidden],
                             "a copilot frame must not carry a `\(forbidden)` field")
            }
        }
    }
}
