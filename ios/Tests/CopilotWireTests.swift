/**
 * The `copilot` half of the wire, on this end.
 *
 * Seven properties are pinned here, and each one is a way this feature could be
 * confidently wrong on screen — or, in three cases, wrong about a permission —
 * while every other test in the suite passed.
 *
 * **No client frame carries a tool name.** The whole enforcement model rests on
 * it: the phone sends prose, the tool calls are made by a CLI on the desktop
 * holding a bearer token this phone does not have, and so *the set of frames a
 * phone can construct contains no tool at all*. That survives the grant of
 * `alter` unchanged — `copilot.answer` carries an id and a boolean, and the
 * tool, the arguments and the effect were decided on the desktop before anybody
 * was asked. The corpus test at the foot of this file walks every outbound case
 * and asserts none of them can name one, so the day somebody adds `copilot.tool`
 * "just for a re-run button" is the day this fails.
 *
 * **The grant collapses to nothing whenever it is not literally granted.**
 * Absent, malformed, `"true"`, `1`, a bare `true` — all of them are no access.
 * A JSON file a person may edit will eventually contain one of them, and the
 * difference between reading it as an intention and as a mistake is a difference
 * in who can drive an agent that spends money and who can approve its changes.
 *
 * **`alter` now arrives, and `open` decides nothing about it.** The tier is on
 * the wire because the copilot is a separate connection; the connection is what
 * carries the second factor. Both halves are read strictly.
 *
 * **`copilot.grant` carries `link`, not `grant`.** This client read the wrong
 * key for a while against a desktop that has never sent it, which decodes as *no
 * access* for every push — a connection would open and the phone would draw the
 * not-connected screen over it.
 *
 * **A consent question keeps its arguments verbatim and in order.** Foundation's
 * JSON reader loses both; `CopilotArguments` reads the frame a second time to
 * get them back. A consent sheet that reshuffles somebody's arguments is showing
 * them a different question from the one on the Mac.
 *
 * **A chat frame is dropped rather than merged when it belongs to another run.**
 * That is what the `run` field is for, and without it a run that ended while the
 * phone was in a pocket produces one conversation made of two with no seam
 * visible on screen.
 *
 * **The two time formats on one frame are not swapped.** `ActionRow.at` is an
 * ISO string because `copilot-home.ts` writes ISO into the same file;
 * `requestedAt` and `expiresAt` are epoch numbers. Reading either as the other
 * produces a plausible-looking date and a countdown that is wrong by decades.
 */

import XCTest
@testable import TerminalDeck

final class CopilotWireTests: XCTestCase {

    // MARK: - The connection and the grant

    func testAWelcomeCarriesThisDevicesConnection() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
         "sessions":[],"capabilities":["copilot"],
         "copilot":{"linked":true,"open":false,"grant":{"read":true,"act":true,"alter":true}}}
        """#), case let .welcome(_, _, _, _, _, capabilities, _, _, _, connection) = message else {
            return XCTFail("a welcome with a copilot connection should decode")
        }
        XCTAssertTrue(capabilities.contains(Copilot.capability))
        XCTAssertTrue(connection.stated)
        XCTAssertTrue(connection.linked)
        XCTAssertFalse(connection.open, "a welcome never opens the copilot")
        XCTAssertEqual(connection.grant, CopilotGrant(read: true, act: true, alter: true))
        XCTAssertTrue(connection.grant.canWatch)
        XCTAssertTrue(connection.grant.canDirect)
        XCTAssertTrue(connection.grant.canAnswer)
    }

    /**
     * **The capability is not the answer to "does this machine have a copilot".**
     *
     * The desktop builds `welcome.capabilities` by filtering `CAPABILITIES` —
     * *every extension this build knows how to serve* — against what its
     * injected objects can actually do, and the filter is a separate line of
     * code from the list it filters. `ios/Harness/host-standin.ts` skips the
     * filter entirely and sends the list verbatim, which is the shape that got
     * an earlier localhost pass reported as verified against an empty screen.
     *
     * The `copilot` field is the answer, because `copilotFrame()` on the desktop
     * writes it only when a copilot layer exists *and* the device is one of his.
     * So a welcome that names the capability and says nothing in the field has
     * to read as "no copilot here" — which is what drives the fourth pill, and
     * drawing one on the strength of the name alone would be a tab that refuses
     * on every press.
     */
    func testTheCapabilityWithoutTheFieldIsNotACopilot() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
         "sessions":[],"capabilities":["copilot","create","localhost","upload","credential","devserver"]}
        """#), case let .welcome(_, _, _, _, _, capabilities, _, _, _, connection) = message else {
            return XCTFail("the welcome should decode")
        }
        XCTAssertTrue(capabilities.contains(Copilot.capability), "it did advertise it")
        XCTAssertFalse(connection.stated, "and it never showed one")
        XCTAssertEqual(connection, .silent)
    }

    /**
     * **A `copilot` object with no `linked` key still means the copilot is
     * this phone's.**
     *
     * The one boolean on this wire whose absence reads as *yes*, and it is the
     * asymmetry most likely to be tidied away by somebody making the codec
     * consistent. Every other boolean here falls towards *no*, because every
     * other boolean is a grant and a missing grant must never read as a given
     * one. `linked` is not a grant: since 2026-08-19 the object's **presence**
     * is the authorisation — the desktop writes it only for a machine with a
     * copilot and a device approved as one of his — so a forgotten field on the
     * far end must not take the copilot away from a phone that has it. That bug
     * would look exactly like the feature being switched off.
     */
    func testACopilotObjectWithoutLinkedIsStillThisPhonesCopilot() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
         "sessions":[],"capabilities":["copilot"],
         "copilot":{"open":false,"grant":{"read":true,"act":true,"alter":true}}}
        """#), case let .welcome(_, _, _, _, _, _, _, _, _, connection) = message else {
            return XCTFail("the welcome should decode")
        }
        XCTAssertTrue(connection.stated)
        XCTAssertTrue(connection.linked)
    }

    /**
     * **And an explicit `false` does take it away.**
     *
     * The direction the field is actually for. It only ever arrives as a
     * `copilot.grant` push, and it is how a device demoted from *My device* to a
     * guest learns so without waiting for a reconnect — capabilities travel in
     * the `welcome` and nowhere else, so without this frame the phone would keep
     * a Copilot pill that refuses on every press.
     *
     * `0`, `"no"` and `null` are **not** a false. They are a host saying
     * something this build does not understand, and the safe reading of not
     * understanding is to leave a working copilot alone rather than to revoke
     * it — the opposite direction from `literalTrue`, whose whole point is that
     * `1` is not a granted tier.
     */
    func testOnlyALiteralFalseTakesTheCopilotAway() {
        func linked(_ json: String) -> Bool {
            guard case let .ok(message, _) = WireCodec.decode(json),
                  case let .copilotGrant(connection) = message else {
                XCTFail("a copilot.grant should decode: \(json)")
                return false
            }
            return connection.linked
        }

        XCTAssertFalse(linked(#"{"t":"copilot.grant","link":{"linked":false,"open":false}}"#))
        XCTAssertTrue(linked(#"{"t":"copilot.grant","link":{"linked":0,"open":false}}"#),
                      "a number is not a boolean, and guessing here revokes a copilot")
        XCTAssertTrue(linked(#"{"t":"copilot.grant","link":{"linked":"no","open":false}}"#))
        XCTAssertTrue(linked(#"{"t":"copilot.grant","link":{"linked":null,"open":false}}"#))
    }

    /**
     * A desktop that says nothing about the copilot has no copilot for this
     * phone.
     *
     * Two things produce that frame and they are deliberately indistinguishable
     * from here: a build with no copilot in it, and a machine where this device
     * was approved as a **guest**. `server.ts` strips the capability as well as
     * the field for a guest, on the argument that *"a tab that refuses on every
     * press is a worse answer than a client that never knew."*
     *
     * The opposite call to `folders`, one field over, where absent means "this
     * desktop predates per-device folder grants" and empty means "a person
     * granted this device none" — two answers that lead to two screens. Silence
     * here has only one honest reading, and it is *no*.
     */
    func testAWelcomeWithNoCopilotFieldConnectsNothing() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,"sessions":[]}
        """#), case let .welcome(_, _, _, _, _, _, _, _, _, connection) = message else {
            return XCTFail("a welcome without the field should still decode")
        }
        XCTAssertEqual(connection, .silent)
        XCTAssertTrue(connection.grant.isEmpty)
    }

    /// A field this app cannot read is a machine that said nothing, not a
    /// machine that said no. The same direction every other refusal in the codec
    /// falls in, and here it is also the safe one: nothing is drawn.
    func testAMalformedCopilotFieldSaysNothing() {
        for liar in [#""yes""#, "null", "7", #"["read"]"#] {
            guard case let .ok(message, _) = WireCodec.decode(#"""
            {"t":"welcome","protocol":1,"deviceId":"d","deviceName":"iPhone","token":null,
             "sessions":[],"capabilities":["copilot"],"copilot":\#(liar)}
            """#), case let .welcome(_, _, _, _, _, _, _, _, _, connection) = message else {
                return XCTFail("\(liar) should still decode as a welcome")
            }
            XCTAssertEqual(connection, .silent, "\(liar) is not a copilot")
        }
    }

    /**
     * **`copilot.grant` carries `link`.**
     *
     * The frame is `{ t: 'copilot.grant', link: CopilotLinkWire }` — `linked`,
     * `open` and the grant inside it. Reading `grant` off the top level, which
     * is the key an earlier design used, decodes every push as no access at all:
     * the connection would open on the desktop and the phone would draw the
     * empty-grant screen over a copilot that is working.
     */
    func testAPushedGrantIsReadOffTheLinkAndOpensTheConnection() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.grant","link":{"linked":true,"open":true,
         "grant":{"read":true,"act":true,"alter":false}}}
        """#), case let .copilotGrant(connection) = message else {
            return XCTFail("the frame should decode")
        }
        XCTAssertTrue(connection.stated)
        XCTAssertTrue(connection.linked)
        XCTAssertTrue(connection.open)
        XCTAssertEqual(connection.grant, CopilotGrant(read: true, act: true, alter: false))
        XCTAssertFalse(connection.grant.canAnswer, "act is not alter")
    }

    /// The copilot being taken away is the same frame with `linked` false. It is
    /// what a device demoted from *My device* to a guest receives, and it has to
    /// be distinguishable from an empty grant: one means *there is no copilot
    /// here for you* and takes the tab away, the other means *the machine is
    /// refusing* and keeps it, with a sentence saying so.
    func testLosingMyDeviceArrivesAsALinkThatIsNoLongerLinked() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.grant","link":{"linked":false,"open":false,
         "grant":{"read":false,"act":false,"alter":false}}}
        """#), case let .copilotGrant(connection) = message else {
            return XCTFail("the frame should decode")
        }
        XCTAssertFalse(connection.linked)
        XCTAssertFalse(connection.open)
        XCTAssertTrue(connection.grant.isEmpty)
    }

    /// Only a literal `true` grants anything, in any of the three tiers. The
    /// desktop makes the same refusals; this end refuses again rather than
    /// trusting that it did.
    func testOnlyALiteralTrueGrantsAnything() {
        let liars = [#"{"read":"true","act":"yes","alter":"true"}"#,
                     #"{"read":1,"act":1,"alter":1}"#,
                     #"{"read":"","act":"act","alter":"alter"}"#,
                     "true",
                     "null",
                     #"["read"]"#]
        for liar in liars {
            guard case let .ok(message, _) =
                    WireCodec.decode(#"{"t":"copilot.grant","link":{"linked":true,"open":true,"grant":\#(liar)}}"#),
                  case let .copilotGrant(connection) = message else {
                return XCTFail("\(liar) should still decode as a frame")
            }
            XCTAssertEqual(connection.grant, .none, "\(liar) is not a grant")
        }
    }

    /**
     * `open` is read as strictly as the tiers are.
     *
     * It is the gate in front of every other frame on this surface, so a `1` or
     * a `"true"` from a host this build does not understand must not open a
     * connection — the phone would subscribe, be refused, and show an error
     * banner over a screen that looks connected.
     */
    func testOpenIsReadAsStrictlyAsAGrant() {
        for liar in ["1", #""true""#, #""yes""#] {
            guard case let .ok(message, _) = WireCodec.decode(#"""
            {"t":"copilot.grant","link":{"linked":true,"open":\#(liar),"grant":{"read":true}}}
            """#), case let .copilotGrant(connection) = message else {
                return XCTFail("\(liar) should still decode")
            }
            XCTAssertFalse(connection.open, "\(liar) is not an open connection")
        }
    }

    /**
     * `act` without `read` directs nothing.
     *
     * Reachable from a hand-edited store — the desktop keeps whatever is
     * literally `true` per tier and has no rule tying one to the other. Against
     * a desktop that refuses the watching surface without `read`, drawing a
     * composer for that grant would draw a control that can send a message into
     * a screen showing no answer.
     */
    func testActWithoutReadIsNotAUsableGrant() {
        let grant = CopilotGrant(read: false, act: true, alter: false)
        XCTAssertFalse(grant.canWatch)
        XCTAssertFalse(grant.canDirect, "read is the floor for the watching surface")
    }

    /**
     * `canAnswer` is `alter` alone, exactly as the desktop's table spells it.
     *
     * This is the one place the client does *not* add `read` to the test,
     * because `COPILOT_FRAME_TIER` does not: `copilot.answer` needs `alter` and
     * nothing else. Adding a floor here would be this end inventing a rule the
     * far end does not have — and the day somebody granted alter without read,
     * the phone would refuse a frame the desktop would have taken.
     */
    func testAnsweringIsAlterAndNothingElse() {
        XCTAssertTrue(CopilotGrant(read: false, act: false, alter: true).canAnswer)
        XCTAssertFalse(CopilotGrant(read: true, act: true, alter: false).canAnswer)
    }

    // MARK: - The frames that are gone

    /**
     * **`copilot.linked` is not a frame this build knows, and that is the
     * assertion.**
     *
     * It carried the copilot credential — once, because the desktop kept only a
     * scrypt hash — in answer to a `copilot.connect`. Both went on 2026-08-19
     * with the ceremony itself: *"instead of giving mobile app separate
     * connection for copilot just make it like if we are connecting as my device
     * copilot automatically comes."*
     *
     * A vocabulary shrinking is worth pinning as carefully as one growing. This
     * asserts the codec **fails** rather than half-applying: a build that
     * quietly decoded the frame again would be a build that had a credential to
     * store and nowhere to store it, and it would be found by nobody, because
     * the copilot would work anyway. An unknown `t` falls through to the default
     * and is reported, which is the right answer for a host speaking a
     * vocabulary this build does not share.
     */
    func testTheCredentialFrameIsNoLongerPartOfThisWire() {
        guard case .failed = WireCodec.decode(#"""
        {"t":"copilot.linked","credential":"c2VjcmV0LWJ5dGVz",
         "link":{"linked":true,"open":true,"grant":{"read":true,"act":true,"alter":true}}}
        """#) else {
            return XCTFail("copilot.linked is not a frame this client understands")
        }
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
         "grant":{"read":true,"act":true,"alter":true},"available":true,"reason":null}}
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
        XCTAssertEqual(state.grant, CopilotGrant(read: true, act: true, alter: true))
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
        XCTAssertEqual(WireCodec.copilotState(["desk": "running",
                                               "grant": ["read": true, "act": false, "alter": true]])?.grant,
                       CopilotGrant(read: true, act: false, alter: true))
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

    // MARK: - Watching a confirmation

    /**
     * A pending row, spelled as `CopilotPendingRow` spells it.
     *
     * Six fields, and **no tier and no arguments**. Watching a question is not
     * judging it: the arguments of a pending alter call are a settings key and
     * its new value, or a session id and the text about to be typed into it, and
     * a device that cannot answer has no decision to make with them. A device
     * that *can* gets them in full on `copilot.ask`.
     */
    func testAPendingQuestionIsTheDesktopsOwnRow() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.pending","questions":[{"id":"q1","tool":"settings.write",
         "summary":"Change the theme to light","mine":true,
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
        XCTAssertEqual(question?.mine, true)
    }

    /**
     * **`mine` is false unless the desktop literally said true.**
     *
     * It decides whether an Allow button exists. Of the two ways to be wrong,
     * hiding a button that would have worked costs a walk to the desk, and
     * showing one that cannot costs trust in every other button on the screen —
     * so a `1`, a `"true"` and an absent field are all "somebody else's
     * question".
     */
    func testMineIsFalseUnlessItIsLiterallyTrue() {
        for liar in [#""true""#, "1", "null"] {
            guard case let .ok(message, _) = WireCodec.decode(#"""
            {"t":"copilot.pending","questions":[{"id":"q1","tool":"t","summary":"s",
             "requestedAt":1,"expiresAt":2,"mine":\#(liar)}]}
            """#), case let .copilotPending(questions) = message else {
                return XCTFail("\(liar) should still decode")
            }
            XCTAssertEqual(questions.first?.mine, false, "\(liar) does not make it answerable here")
        }
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.pending","questions":[{"id":"q1","tool":"t","summary":"s",
         "requestedAt":1,"expiresAt":2}]}
        """#), case let .copilotPending(questions) = message else {
            return XCTFail("a row with no `mine` should still decode")
        }
        XCTAssertEqual(questions.first?.mine, false, "absent is somebody else's question")
    }

    /**
     * A question with no summary is refused rather than drawn.
     *
     * A prompt that arrives without enough context to judge it is a prompt that
     * gets answered without being read. A card saying only *"something needs
     * you"* trains a person to walk over and click whatever is on screen, which
     * is the reflex Yes this whole design refuses to build.
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
                                       expiresAt: 1_755_400_120_000,
                                       mine: true)
        XCTAssertEqual(question.secondsLeft(now: now), 120)
        XCTAssertEqual(question.secondsLeft(now: now.addingTimeInterval(300)), 0,
                       "a lapsed question counts to zero, never below it")

        let undated = CopilotQuestion(id: "q", tool: "t", summary: "s",
                                      requestedAt: 0, expiresAt: 0, mine: false)
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

    // MARK: - Deciding a confirmation

    /**
     * `copilot.ask` carries everything needed to judge it, **in order**.
     *
     * The order is the assertion that matters. The desktop composes `args` in
     * the tool's own declaration order, which is the order its own dialog shows;
     * `JSONSerialization` hands this end an unordered dictionary, so without the
     * second read in `CopilotArguments` this sheet and that dialog would show the
     * same question in two different shapes — and two renderings of one consent
     * prompt is how somebody approves one thing having read another.
     */
    func testAConsentQuestionKeepsItsArgumentsInTheToolsOwnOrder() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.ask","question":{"id":"q1","tool":"settings.write","tier":"alter",
         "summary":"Change the default agent to codex","origin":"device:d-7",
         "requestedAt":1755400000000,"expiresAt":1755400120000,
         "args":{"key":"defaultProvider","value":"codex","scope":"app","confirm":true}}}
        """#), case let .copilotAsk(question) = message else {
            return XCTFail("an ask should decode")
        }
        XCTAssertEqual(question.id, "q1")
        XCTAssertEqual(question.tool, "settings.write")
        XCTAssertEqual(question.tier, "alter")
        XCTAssertEqual(question.summary, "Change the default agent to codex")
        XCTAssertEqual(question.origin, "device:d-7")
        XCTAssertTrue(question.fromADevice, "this phone's own run asked for it")
        XCTAssertTrue(question.argumentsAreOrdered)
        XCTAssertEqual(question.arguments.map(\.name), ["key", "value", "scope", "confirm"],
                       "the tool's own order, not the dictionary's")
        XCTAssertEqual(question.arguments.map(\.value), ["defaultProvider", "codex", "app", "true"],
                       "verbatim — and a JSON true is `true`, not `1`")
        XCTAssertEqual(question.secondsLeft(now: Date(timeIntervalSince1970: 1_755_400_060)), 60)
    }

    /// A window-origin question is the copilot at the desk, and it must not read
    /// as this phone's own run. They are different things to be approving.
    func testAWindowOriginIsNotThisPhonesRun() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.ask","question":{"id":"q2","tool":"sessions.stop","tier":"alter",
         "summary":"Stop “api”","origin":"window","requestedAt":1,"expiresAt":2,"args":{}}}
        """#), case let .copilotAsk(question) = message else {
            return XCTFail("an ask should decode")
        }
        XCTAssertFalse(question.fromADevice)
        XCTAssertTrue(question.arguments.isEmpty, "a tool with no arguments is a real answer")
    }

    /// An ask with nothing to judge is refused, harder than a watch row is: this
    /// is the sheet with the buttons on it, and a sheet that says *approve this*
    /// with nothing to approve is the reflex-Yes machine.
    func testAnAskWithNothingToJudgeIsRefused() {
        guard case .failed = WireCodec.decode(#"""
        {"t":"copilot.ask","question":{"id":"q1","tool":"settings.write","args":{}}}
        """#) else {
            return XCTFail("an ask with no summary must not draw a consent sheet")
        }
    }

    /**
     * `copilot.settled` says **where** it was answered.
     *
     * The whole reason the frame is not just a dismissal. First answer wins, and
     * the surface that loses the race has to withdraw its sheet saying where it
     * went — a dialog that disappears on its own teaches a person that the app
     * does things behind their back.
     */
    func testASettlementSaysWhereItWasAnswered() {
        guard case let .ok(message, _) = WireCodec.decode(#"""
        {"t":"copilot.settled","settled":{"id":"q1","granted":true,"by":"window","reason":null}}
        """#), case let .copilotSettled(settled) = message else {
            return XCTFail("a settlement should decode")
        }
        XCTAssertTrue(settled.granted)
        XCTAssertTrue(settled.atTheMachine)
        XCTAssertFalse(settled.timedOut)

        guard case let .ok(other, _) = WireCodec.decode(#"""
        {"t":"copilot.settled","settled":{"id":"q2","granted":false,"by":null,"reason":"timeout"}}
        """#), case let .copilotSettled(timeout) = other else {
            return XCTFail("a timeout should decode")
        }
        XCTAssertTrue(timeout.timedOut, "nobody answered — which is a refusal, not an error")
        XCTAssertFalse(timeout.granted)
        XCTAssertEqual(timeout.reason, "timeout")
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
            (.copilotBye, #"{"t":"copilot.bye"}"#),
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
     * The hello, asserted field by field rather than as a string.
     *
     * `JSONSerialization.data(withJSONObject:)` does not promise a key order
     * without `.sortedKeys` and does not deliver one either — this suite has seen
     * the same two-key frame encode both ways round on one machine in one build.
     * It reads as one assertion now and used to be three; the other two were
     * `copilot.connect` and a hello that carried a credential.
     */
    func testTheHelloCarriesExactlyWhatItShould() {
        func fields(_ message: ClientMessage) -> [String: Any] {
            guard let object = try? JSONSerialization.jsonObject(with: Data(WireCodec.encode(message).utf8)),
                  let fields = object as? [String: Any] else { return [:] }
            return fields
        }

        /*
         * **A hello is a verb and nothing else**, and the count is the whole
         * point of the assertion.
         *
         * It used to carry a credential, redeemed from a six-digit code by a
         * `copilot.connect` that is no longer in the vocabulary at all. What
         * authorises the frame now is the device identity this socket proved at
         * pairing time and the kind that device was approved as — neither of
         * which travels in the frame, because the desktop already holds both. A
         * field creeping back in here would be this phone offering a secret
         * nobody asked it for.
         */
        let hello = fields(.copilotHello)
        XCTAssertEqual(hello["t"] as? String, "copilot.hello")
        XCTAssertEqual(hello.count, 1, "a hello is a verb, and carries nothing")
    }

    /**
     * **A refusal travels as a field, never as an absence.**
     *
     * `credential.answer` writes its `remember` only when true, because the
     * desktop reads it as `=== true` and a `false` there would be a field saying
     * nothing. This is the opposite case and the difference is worth the
     * asymmetry: `approved` *is* the decision, and a refusal that travelled as a
     * missing key would be one lenient parser away from being an approval.
     */
    func testAnAnswerCarriesTheDecisionEitherWay() {
        for approved in [true, false] {
            guard let object = try? JSONSerialization.jsonObject(
                    with: Data(WireCodec.encode(.copilotAnswer(id: "q1", approved: approved)).utf8)),
                  let fields = object as? [String: Any] else {
                return XCTFail("it should encode to an object")
            }
            XCTAssertEqual(fields["t"] as? String, "copilot.answer")
            XCTAssertEqual(fields["id"] as? String, "q1")
            XCTAssertEqual(fields["approved"] as? Bool, approved)
            XCTAssertEqual(fields.count, 3, "an answer is a verb, a question and a decision")
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
     * The property that makes the enforcement airtight rather than exhaustive,
     * and the one that had to survive the grant of `alter` intact. A device
     * holding every tier still cannot *name a call*: it can say a sentence, and
     * it can decide about a call the desktop composed. `copilot.answer` carries a
     * question id and a boolean, and the tool, the arguments and the effect were
     * all decided on that machine before anybody was asked anything.
     *
     * Written as a corpus rather than as a rule about types because the failure
     * it guards against is a *new frame* — somebody adding `copilot.tool` for a
     * "tap to re-run that" button, which is the first convenience feature anybody
     * will ask for here and the one that breaks all of it.
     *
     * The same shape as `wire-wording.test.ts` and `reachable.test.ts` on the
     * desktop: a property about text, pinned by walking text.
     */
    func testNoClientFrameCanNameATool() {
        let frames: [ClientMessage] = [
            .copilotHello,
            .copilotBye,
            .copilotAnswer(id: "01J8ZC4T9K5Q2V7XW3NHRF6MBD", approved: true),
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
