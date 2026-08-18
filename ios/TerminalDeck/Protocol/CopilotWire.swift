/**
 * The `copilot` half of the wire language, as this client sees it.
 *
 * A port of §2 of `COPILOT-REMOTE.md`, which settles the frames, the caps, the
 * connection and the grant. It lives beside `WireProtocol.swift` under the same
 * rule that file states about itself: it is a **copy** of the desktop's
 * `protocol.ts`, Swift having no way to import TypeScript, and it changes only
 * when that file changes, with the same names and the same values.
 *
 * ## The one property this file exists to preserve
 *
 * **No tool name ever appears in a client frame.** There is no `copilot.tool`
 * verb, no argument object this end can compose, no tool id in anything the
 * `ClientMessage` cases below can carry. The phone sends *prose*; the tool calls
 * are made by a Claude CLI on the desktop, over loopback, holding a bearer token
 * this phone does not have. The design calls this the strongest form of the
 * property the feature needs, and it survives the grant of `alter` unchanged: a
 * device holding every tier still cannot *name* a call. It can say a sentence,
 * and it can decide about a call the desktop composed — `copilot.answer` carries
 * a question id and a boolean, and the tool, the arguments and the effect were
 * all decided on that machine before anybody was asked anything.
 *
 * It is also the rule that will come under pressure, because the obvious phone
 * feature is "tap that row to run it again". `CopilotWireTests` pins it: a
 * corpus test over every outbound case asserting that none of them carries a
 * tool id. If a future frame needs one, this comment is where the argument
 * against it is.
 *
 * ## The copilot is a **separate connection**, and that is the whole design
 *
 * This is the part that changed on 2026-08-17 and it changed everything else in
 * the file. Copilot access used to be a box ticked beside an already-paired
 * device, carried on the session channel, with `alter` deliberately absent from
 * the wire in any spelling — three independent refusals guarding the tier whose
 * safety property is *a human at the machine says yes*.
 *
 * Asad:
 *
 * > *"Phones will have full control over copilot, same as the actual machine
 * > app. But connecting copilot will be a separate connection than the
 * > sessions."*
 *
 * The property was not abandoned; the second factor moved. It was never really
 * *geography* — somebody who walks away from an unlocked Mac has taken their
 * geography with them — it was *reaching the dialog required an authorisation
 * the requesting party did not already hold.* So the copilot now has its own
 * six-digit code minted at the desktop, its own credential, its own record and
 * its own revoke, and a device paired to run ten terminals has no copilot reach
 * whatsoever until somebody mints a code for it and it is redeemed.
 *
 * Three consequences this file has to get right, each of which is a screen:
 *
 *  - **`linked`** — does that desktop hold a copilot record for this device.
 *    False means *ask the person at the machine for a connect code*; there is no
 *    frame that will work before one is redeemed, read tier included.
 *  - **`open`** — has *this socket* presented the credential. It is false on
 *    every `welcome`, always, and a client that treats it as "already in" sends
 *    frames that are refused. `copilot.hello` opens it, on every reconnect.
 *  - **`grant`** — what the connection may do once open. All three tiers,
 *    `alter` included.
 *
 * ## Read is the floor; act and alter are two more switches on top of it
 *
 * `server.ts` refuses every `copilot.*` frame from a device whose grant does not
 * cover it — `read` for the watching surface, `act` for `start`/`say`/`cancel`/
 * `stop`, `alter` for `answer`. That refusal is the transport keeping the UI
 * honest rather than the boundary itself (the boundary is `DeckControl.call` on
 * the desktop, where it already is). What it means *here* is that a control this
 * grant does not cover must not be drawn: a button whose only possible outcome
 * is a refusal is the defect `reachable.test.ts` warns about, one level out.
 */

import Foundation

enum Copilot {

    /**
     * The desktop can speak `copilot.*` frames.
     *
     * Advertised in `welcome.capabilities`, like every other name past protocol
     * v1, and read the same way: absent means "this desktop has never heard of
     * the feature", which is every build shipping before 0.4. It is **not** the
     * same question as whether this device may use it — that is the connection
     * and the grant, which travel separately, for the reason `folders` travels
     * separately from `create`. One is about the host, the other is about this
     * device, and folding them together is exactly how a phone ends up drawing a
     * control that is always refused.
     */
    static let capability = "copilot"

    /**
     * The largest thing this phone will say to the copilot in one frame.
     *
     * `MAX_COPILOT_SAY_BYTES`, and the same number as `MAX_INPUT_BYTES` on
     * purpose: this is a message, not a file. Unlike a paste there is no
     * chunking — a `copilot.say` is one utterance and half of one is a different
     * question — so a composer that would exceed it says so rather than sending
     * a truncated sentence to an agent that will act on it.
     */
    static let maxSayBytes = 16 * 1024

    /// `MAX_COPILOT_LOG_ROWS`. The desktop clamps `limit` to 1…200; the local
    /// Activity pane's 2,000 is a pane, not a relay.
    static let maxLogRows = 200

    /// How many rows one `copilot.log` asks for. Well inside the cap, because
    /// the screen pages backwards with `before` and a first page that has to be
    /// scrolled past to reach the composer is a first page nobody reads.
    static let logPage = 50

    /**
     * `MAX_COPILOT_MESSAGE_CHARS`, per chat bubble.
     *
     * A message over it arrives **truncated with a flag** rather than chunked —
     * `TranscriptMessage.truncated` sets the precedent, and the reasoning is
     * that a chat bubble is read rather than scrolled. The flag is why
     * `CopilotChatMessage` has a `truncated` field: a bubble that was cut and
     * does not say so is a bubble that misquotes an agent.
     */
    static let maxMessageChars = 8 * 1024

    /**
     * How many rows the timeline keeps in memory.
     *
     * Not a protocol constant — the desktop bounds each frame and says nothing
     * about how many may follow, and a copilot working through a long night can
     * push thousands of `copilot.tool` rows down one socket. The screen is a
     * `LazyVStack`, so drawing is not the cost; holding every row a phone has
     * ever been told about, across a background/foreground cycle, is. The oldest
     * go first and the full history is still one tap away in Activity, which
     * pages against the file on the desktop rather than against this array.
     */
    static let maxTimelineRows = 600

    /**
     * Digits in a connect code. `CODE_LENGTH` in `src/shared/short-code.ts`, and
     * the same six digits the pairing code uses.
     *
     * Deliberately the same format and deliberately **not** the same code: this
     * one is minted by `CopilotLinks.mintCode` and redeemed by
     * `copilot.connect`, and typing a pairing code here would be six digits that
     * hash to nothing. The two screens say which is which; the format is shared
     * because a person should not have to learn a second shape of code for the
     * second thing they connect.
     */
    static let codeLength = 6

    /// `MAX_COPILOT_CREDENTIAL_CHARS`. 32 bytes of base64url is 43 characters;
    /// the ceiling is generous and finite for the reason `device-auth.ts` gives
    /// about its own — a client that forgets to check a value must not be able
    /// to hand a megabyte to a keychain item or to a frame.
    static let maxCredentialChars = 512
}

/**
 * What one connected device may do with the copilot.
 *
 * **Three booleans now, and the third one used to be the mechanism.** `alter`
 * was absent from this type in every spelling, because the tier's safety
 * property was *a human at the machine says yes* and a phone is not that human.
 * That is superseded by the separate connection — see the file header — and the
 * property it protected is now carried by the connection instead. What `alter`
 * decides is **which screen a confirmation is drawn on and whose thumb answers
 * it**; it pre-authorises nothing, because every alter call still raises a
 * question, still expires into a refusal, and still writes a row naming who
 * answered.
 *
 * Independent booleans rather than a ladder, matching `TierGrant` on the desktop
 * and for its reason: a ladder makes the *order* of the tiers a security
 * property, and every existing grant silently widens the day somebody inserts a
 * tier between two others.
 *
 * `none` is the answer for every device with no copilot record — the
 * overwhelming majority, by design, because nobody has ever had remote copilot
 * access and so nobody can lose it.
 */
struct CopilotGrant: Equatable {
    let read: Bool
    let act: Bool
    let alter: Bool

    static let none = CopilotGrant(read: false, act: false, alter: false)

    /// Whether this phone may see anything at all. `read` is the floor for the
    /// watching surface, so this is also the answer to "is there a screen here".
    var canWatch: Bool { read }

    /**
     * Whether this phone may make the copilot do something.
     *
     * `read && act`, not `act`. A hand-edited store can produce
     * `{read: false, act: true}` — the desktop keeps whatever is literally
     * `true` per tier and has no rule tying one to the other — and against a
     * desktop that refuses the watching surface without `read`, drawing a
     * composer for that grant would draw a control that can send a message into
     * a screen that shows no answer. The floor is a floor.
     */
    var canDirect: Bool { read && act }

    /**
     * Whether this phone may answer its own run's confirmations.
     *
     * `alter` alone, exactly as `COPILOT_FRAME_TIER` spells it — this is the one
     * place the client does **not** add `read` to the test, because the desktop
     * does not. In practice the two arrive together: a `copilot.ask` is pushed
     * down a watcher's sink, and there is no watcher without `read` and an
     * `attach`. Writing it as the desktop writes it is what stops this end
     * inventing a rule the far end does not have.
     */
    var canAnswer: Bool { alter }

    /// True when this device has been granted nothing, which is a real state —
    /// a connection whose boxes are all unticked still holds a working
    /// credential — and the one the screen exists to explain rather than hide.
    var isEmpty: Bool { !read && !act && !alter }
}

/**
 * What a `welcome` or a `copilot.grant` said about this device's copilot: does
 * the machine have one, does this device hold a record for it, is *this socket*
 * in, and what may it do.
 *
 * Four facts and not one, because a client has four screens to draw and folding
 * any two of them together makes one of them wrong.
 *
 * `stated` is this end's own bit and is not on the wire. `welcome.capabilities`
 * is not a reliable answer to "does this machine have a copilot": the desktop
 * assembles that list by filtering `CAPABILITIES` — *every extension this build
 * knows how to serve* — against what its injected objects can actually do, and
 * the filter is a separate line of code from the thing it is filtering for. A
 * build where the two have drifted advertises a feature it cannot serve, which
 * is not hypothetical: `ios/Harness/host-standin.ts` sends the whole of
 * `CAPABILITIES` verbatim and implements almost none of it, and an earlier pass
 * over a different feature was reported as verified against the empty screen
 * that produced.
 *
 * The `copilot` **field** is the reliable answer, because it is written by the
 * same object that serves the frames: `copilotFrame()` on the desktop returns
 * `{}` when there is no copilot layer and the object — *even when the device
 * holds nothing* — when there is one. A host that has a copilot says so in this
 * field by construction; a host that merely advertises the name cannot.
 *
 * So `stated` answers *does this machine have a copilot at all*, `linked`
 * answers *and have I been connected to it*, `open` answers *and is this socket
 * in*, and `grant` answers *and what may I do*. Keeping them apart is what lets
 * a phone tell **update that desktop** from **ask for a connect code** from
 * **send your credential** from **somebody unticked your boxes** — four
 * sentences that send a person to four different places, three of which exist.
 */
struct CopilotConnection: Equatable {
    /// The frame carried a `copilot` object. See the type's header: this is the
    /// honest signal, and the capability name is not.
    let stated: Bool
    /// That desktop holds a copilot record for this device. False is *ask for a
    /// connect code*, and it is the state every paired device starts in.
    let linked: Bool
    /**
     * **This socket** has presented the credential.
     *
     * False on every `welcome`, always — that is not a quirk to work around, it
     * is the difference between this design and the per-device grant it
     * replaced. A session channel does not carry the copilot by existing.
     */
    let open: Bool
    let grant: CopilotGrant

    /// A desktop that said nothing. Every build shipping before this feature.
    static let silent = CopilotConnection(stated: false, linked: false, open: false, grant: .none)
}

/**
 * What the copilot is, right now, on one machine. A port of
 * `CopilotStateReport`.
 *
 * ## Two copilots are described here and they are not the same one
 *
 * This is the field of this frame most likely to be read wrongly, so it is
 * named first. `desk` is the copilot **pinned in the sidebar on the machine** —
 * the conversation the person at the keyboard is having, which this phone can
 * watch and can never speak into. `run` is **this device's own run**, which is
 * the only thing the phone can talk to at all.
 *
 * They move independently, and a screen that drew one from the other gets the
 * one control on it that costs money wrong in both directions: a Start button
 * under a run that already exists, or no Start button because something
 * unrelated is busy at somebody's desk. `copilot-runs.ts` reports them
 * separately for exactly this reason and says so in the same words.
 *
 * ## Absent means "the desktop did not say"
 *
 * Every optional field here is a fact about somebody else's machine, and this
 * end prints nothing rather than a plausible default for one it was not told —
 * a pane reading "signed out" for a `signedIn` the desktop never mentioned is
 * inventing the answer to the question the person came to ask.
 */
struct CopilotState: Equatable {
    /**
     * The copilot at the desk: `running` · `starting` · `stopped`, free-form on
     * purpose.
     *
     * The same choice `RemoteSession.status` makes and for the same reason: the
     * vocabulary belongs to the desktop, and a build of it newer than this app
     * will one day send a fourth word. Refusing the frame over that would blank
     * the whole screen; mapping the word onto a neighbour would draw the wrong
     * thing. So an unrecognised word is *printed*, and the three computed
     * properties below all answer false.
     */
    let desk: String

    /// This device's own run, when it has one — the session id of it. Nil means
    /// this phone has not started one, which is the normal state and the state a
    /// `read` grant can never leave.
    let run: String?

    /// The account the copilot runs as, by name, never a credential. Nil when
    /// the desktop did not say.
    let profile: String?

    /// Whether that account is signed in. **Three answers, not two** — nil is
    /// "it has not been asked", which is what the desktop sends before the probe
    /// has run, and drawing it as "signed out" would send somebody to fix an
    /// account that is fine.
    let signedIn: Bool?

    /// How many tools the copilot has, and what the catalogue costs it every
    /// turn. On the wire because this is the one screen where the size of the
    /// thing being spoken to is worth knowing before speaking to it.
    let tools: Int
    let turnTokens: Int

    /**
     * How many confirmations are waiting **at the desk**.
     *
     * A count rather than the questions themselves, because the count is what
     * the row's badge draws and the questions come down their own frame. Zero
     * and absent are the same answer here, unlike `folders`: there is no "has
     * not said" screen to distinguish, and a badge that had to hedge about
     * whether anything was waiting would be a badge nobody trusts.
     */
    let pending: Int

    /**
     * This device's grant, repeated on this frame so that one frame can answer
     * *what may I do*.
     *
     * Optional here and not on the desktop's type, because the difference
     * between a host that sent it and a host that did not is the difference
     * between applying a grant and inventing one: reading an absent field as
     * all-false would revoke this phone's own screen on the first state frame
     * from a host that did not repeat it.
     */
    let grant: CopilotGrant?

    /**
     * Whether a run could start at all — is there a Claude CLI, is it signed in,
     * is the tool endpoint up.
     *
     * **False with a `reason` beats a Start button that fails**, which is the
     * desktop's own sentence about this pair of fields and the reason they are
     * on the wire rather than inferred from `desk`.
     *
     * Absent reads as false. A host that did not answer has not said a run can
     * start, and the honest response to that is a sentence rather than a button
     * — there is nothing to lose, because every desktop that has this feature
     * sends the field.
     */
    let available: Bool

    /// Why not, in the desktop's own words. Printed rather than re-composed:
    /// this end has no idea whether the CLI is missing, the profile is signed
    /// out, or the tool server is down, and guessing at one of the three is how
    /// a phone sends somebody to fix the wrong thing.
    let reason: String?

    var deskIsRunning: Bool { desk == "running" }
    var deskIsStarting: Bool { desk == "starting" }
    /// True only when the desktop actually said `stopped`. An unrecognised word
    /// is not a stopped copilot.
    var deskIsStopped: Bool { desk == "stopped" }

    /// Whether this phone has a run of its own. The only half of this frame the
    /// composer and the Stop verb are allowed to read.
    var hasRun: Bool { run != nil }
}

/// Who said something. Two values, because the desktop's `ChatRole` has two.
enum CopilotRole: Equatable {
    case you
    case agent
}

/**
 * One turn of the conversation, as **parsed text** — never pty bytes.
 *
 * The desktop produces these with the same parser its own chat pane uses
 * (`chat-transcript.ts`), so there is one truth about what was said and no ANSI
 * on a phone. The merge rule travels with the type and is not negotiable:
 * **replace on a matching `id`, append otherwise**, and a frame carrying
 * `reset` means drop everything and take its messages as the whole
 * conversation. An appended-to message arrives again with the same id and more
 * text in it, which is what makes a streaming answer readable rather than a
 * screenful of fragments.
 */
struct CopilotChatMessage: Equatable, Identifiable {
    let id: String
    let role: CopilotRole
    let text: String
    /// Epoch milliseconds of the first line that fed this message, or 0 when the
    /// transcript line carried no date. Zero is drawn as no time rather than as
    /// 1970.
    let at: Double
    /// The desktop cut this at `MAX_COPILOT_MESSAGE_CHARS`. Drawn, because a
    /// bubble that was shortened and does not say so misquotes an agent.
    let truncated: Bool
}

/**
 * One thing the copilot did, already scrubbed.
 *
 * A port of `CopilotActionRow` — a row of `<userData>/copilot-log/actions.jsonl`
 * as `server.ts` rebuilds it for the wire. It arrives two ways and they are the
 * same shape by design: pushed one at a time as `copilot.tool` while it happens,
 * and in pages as `copilot.log` when the Activity screen asks. One type, so a
 * row cannot look different depending on which door it came through.
 *
 * ## There are no arguments on this row, and there is not going to be a way to
 * ask for them
 *
 * The desktop's own type says why, and it is not an oversight to be fixed by a
 * later field: the arguments are scrubbed before the row is written, and *even
 * scrubbed they are the text of what was typed into somebody's sessions*. So a
 * tool row on a phone is what happened and what it was for, in the sentence the
 * tool composed — never the payload. The one place arguments do cross is
 * `CopilotConsentQuestion`, and they cross there because a decision is being
 * asked for and they go only to the device being asked.
 */
struct CopilotAction: Equatable, Identifiable {
    let id: String
    /**
     * When the call *arrived*, in epoch milliseconds.
     *
     * Converted here from the ISO 8601 string the desktop writes, and the
     * conversion is worth naming because this feature carries **two different
     * time representations** and getting them the wrong way round is a silent
     * bug: `CopilotActionRow.at` is a string, because `copilot-home.ts` writes
     * ISO into the same file and one field cannot honestly be two types, while
     * `CopilotPendingRow.requestedAt` and `expiresAt` are epoch numbers. Nil
     * when the string would not parse — the row still draws, without a time,
     * rather than being dropped or given "now".
     */
    let at: Double?
    /// Canonical tool id, dotted: `sessions.start`. Display only. Nothing this
    /// app can send carries one — see the file header.
    let tool: String
    /// The tier the call was judged at, **after** any escalation. `sessions.send`
    /// declares `act` and escalates to `alter` against a session the run did not
    /// start, so this is the field that says which of the two happened.
    let tier: String
    /// `ok` · `refused` · `error`.
    let outcome: String
    /// One line a person can read, written by the tool that ran.
    let detail: String
    /// Why it was refused, when it was: `not-granted`, `declined`, `timeout`,
    /// `caller-gone`… The desktop's `RefusalReason`, printed rather than mapped —
    /// this end does not know which gate produced it and a guess would be a
    /// phone explaining somebody's security model to them incorrectly.
    let refusal: String?
    /**
     * Which device caused it, or nil for the person at the machine.
     *
     * The desktop's type states that meaning outright — *null for the person at
     * the Mac* — so nil is an answer here rather than an absence, unlike most
     * optional fields on this wire. It is also the only place *which of my
     * phones did that* has an answer at all, because a relayed call leaves no
     * other trace.
     */
    let deviceId: String?

    var wasRefused: Bool { outcome == "refused" }
    var failed: Bool { outcome == "error" }
}

/**
 * A confirmation that is waiting, as a device **watches** it.
 *
 * A port of `CopilotPendingRow`. This type used to carry no `mine` and its
 * header said, in those words, that there must never be an Allow or a Refuse on
 * it. That was true while copilot access was a box ticked beside a paired phone.
 * It is not true now that a copilot connection is its own act of authorisation —
 * see `CopilotConnection` and `COPILOT-REMOTE.md` §4.
 *
 * What survives unchanged is the **watching** half, and it is still most of the
 * value: the failure the design named is a desktop dialog on a screen nobody is
 * looking at, timing out in silence two minutes later. A device sees every
 * question, including ones it may not answer, so it can say *go and look*.
 *
 * There is deliberately **no `args` and no tier here**. Watching a question is
 * not judging it, and the arguments of a pending alter call are the most
 * sensitive thing on this surface — a settings key and its new value, a session
 * id and the text about to be typed into it. A device that *can* answer gets
 * them in full on `CopilotConsentQuestion`; a device that cannot has no decision
 * to make with them, and drawing an Allow button over a row that has none would
 * be inviting exactly the reflex Yes this whole design refuses.
 */
struct CopilotQuestion: Equatable, Identifiable {
    let id: String
    let tool: String
    /// One sentence naming what will happen if this is approved, composed by the
    /// tool on the desktop. Never re-composed here — a prompt whose words were
    /// written by the side that draws it is a prompt that can flatter itself.
    let summary: String
    /// Epoch milliseconds.
    let requestedAt: Double
    /**
     * When the question refuses itself, in epoch milliseconds.
     *
     * Two minutes on the desktop, and the phone does **not** get a longer one.
     * The temptation to extend it for "she has to unlock her phone" is refused
     * in the design for a good reason: a longer window is how an approval lands
     * six minutes later from somebody who has forgotten what they were
     * approving, against a turn that has already moved on.
     */
    let expiresAt: Double
    /**
     * May **this** connection answer it?
     *
     * Computed per device on the desktop, never inferred here, and it is the
     * wire half of the rule §4.2 calls non-obvious: *a question may only be
     * answered by the surface that owns the run that raised it, or by the
     * desktop.* Otherwise device A approves device B's action, which is a
     * permission model with a shared password.
     *
     * **A row with `mine: false` draws no Allow button.** One would always be
     * refused, and a control that is always refused is the defect this
     * repository has paid for twice. `false` is also the safe default for a
     * host that did not send the field: hiding a button that would have worked
     * costs a walk to the desk, and showing one that cannot costs trust.
     */
    let mine: Bool

    /// Seconds left, floored at zero. Nil when the desktop sent no expiry, in
    /// which case the screen shows no countdown rather than a made-up one.
    func secondsLeft(now: Date = Date()) -> Int? {
        guard expiresAt > 0 else { return nil }
        return max(0, Int((expiresAt / 1000 - now.timeIntervalSince1970).rounded(.down)))
    }
}

/**
 * A confirmation **this connection may answer**, with everything needed to
 * judge it.
 *
 * A port of `CopilotConsentQuestion`, and a different type from
 * `CopilotQuestion` for the reason the desktop keeps them apart: the two answer
 * different questions and one of them is dangerous to get wrong. A pending row
 * says *something needs attention*; this says *decide*.
 *
 * **A consent prompt without enough context becomes a reflex Yes, and a gate
 * that is always answered yes is worse than no gate at all, because it looks
 * like protection.** So this carries what a person actually needs and the sheet
 * built on it draws all of it:
 *
 *  - **what** — the tool, by its canonical dotted id, and the desktop's own
 *    one-line summary, composed by the code that knows what it will do. Never
 *    re-worded here: a client that wrote its own sentence would be describing an
 *    action it did not implement, and the first time the two drifted somebody
 *    would approve one thing having read another.
 *  - **who** — `origin` is `window` for the copilot at the desk and
 *    `device:<id>` for a connection's own run, so *my phone's copilot asked for
 *    this* and *the Mac's copilot asked for this* never read the same.
 *  - **with what arguments** — every one of them, verbatim, in the order the
 *    tool wrote them. See `CopilotArguments`, which exists because Foundation's
 *    JSON reader loses both the order and the spelling.
 *  - **what happens if nobody answers** — `expiresAt`. It expires into a
 *    **refusal**, so a person who walks away has decided rather than deferred,
 *    and the countdown has to be in front of them.
 */
struct CopilotConsentQuestion: Equatable, Identifiable {
    let id: String
    let tool: String
    /// Always `alter` today. Carried so a client renders the stakes rather than
    /// assuming them, and printed rather than mapped for the same reason
    /// `CopilotAction.tier` is.
    let tier: String
    let summary: String
    /// Every argument, verbatim, in the tool's own order when the frame could be
    /// read in order and sorted by name when it could not. `argumentsAreOrdered`
    /// says which, because *as the tool wrote them* and *by name* are two
    /// different claims and only one is true at a time.
    let arguments: [CopilotArgument]
    let argumentsAreOrdered: Bool
    /// `window`, or `device:<id>` for the connection whose run raised it.
    let origin: String
    let requestedAt: Double
    let expiresAt: Double

    /// True when this device's own run raised it — `origin` names a device
    /// rather than the window. The sheet says *your copilot asked for this*
    /// rather than *the copilot at the machine asked for this*, which are two
    /// different things to be approving.
    var fromADevice: Bool { origin.hasPrefix("device:") }

    /// Seconds left, floored at zero. Nil when the desktop sent no expiry — and
    /// an invented deadline on a consent prompt is the worst possible thing to
    /// invent, so the sheet draws none.
    func secondsLeft(now: Date = Date()) -> Int? {
        guard expiresAt > 0 else { return nil }
        return max(0, Int((expiresAt / 1000 - now.timeIntervalSince1970).rounded(.down)))
    }
}

/**
 * A question closed, and **where** it was answered.
 *
 * A port of `CopilotSettledRow`, pushed to every connection that could see the
 * question including the one that answered it. The `by` field is the whole
 * reason this frame is not just a dismissal: first answer wins, and the surface
 * that loses the race has to withdraw its sheet *saying where it went* rather
 * than having it vanish. **A dialog that disappears on its own teaches a person
 * that the app does things behind their back.**
 */
struct CopilotSettlement: Equatable {
    let id: String
    let granted: Bool
    /// `window`, `device:<id>`, or nil when nobody answered — a timeout, which
    /// is a refusal and is drawn as one.
    let by: String?
    /// The refusal reason when it was refused, in the desktop's own word. Nil
    /// when it was allowed.
    let reason: String?

    /// Answered at the machine rather than on a device. The two must never read
    /// the same on screen — the desktop's own log distinguishes them, and a
    /// phone that said "allowed" without saying where would be hiding the one
    /// fact somebody would want afterwards.
    var atTheMachine: Bool { by == "window" }
    /// Nobody answered and it ran out. Not an error, and worded so it does not
    /// read as one: the copilot was told no, which is the safe answer and the
    /// design's intended one.
    var timedOut: Bool { by == nil }
}

/**
 * A session the copilot started, and the turn that started it.
 *
 * The session half is decoded by `WireCodec.decodeSession`, the same function
 * the ordinary list uses, so a copilot session and a session can never disagree
 * about what a session is. `originRunId` is the link back: *why does this
 * exist* is one tap in either direction, which is the property
 * `COPILOT-DESIGN.md` asks for on the desktop and there is no reason for a phone
 * to have less.
 */
struct CopilotSessionRow: Equatable, Identifiable {
    let session: RemoteSession
    let originRunId: String?

    var id: String { session.id }
}

/* -------------------------------------------------------------------------- */
/* Decoding                                                                    */
/* -------------------------------------------------------------------------- */

/**
 * The copilot frames' half of the codec.
 *
 * An extension of `WireCodec` in a second file rather than a type of its own, so
 * that the narrowing helpers are shared rather than written twice: two
 * definitions of "is this a whole number" is two definitions that will
 * eventually disagree, on a wire where one of them guards a countdown and the
 * other guards a port. The price is that `string` and `whole` over there are
 * internal rather than private — Swift's `private` is file-scoped — which is
 * noted at their declarations.
 */
extension WireCodec {

    /**
     * The grant, from a `welcome`, a `copilot.grant` or a `copilot.state`.
     *
     * **Absent is `.none`, and so is malformed.** Both mean the same thing —
     * this device may do nothing — and collapsing them is right here in a way it
     * would be wrong for `folders`, where nil ("the desktop never mentioned
     * folders") and `[]` ("a person granted this device none") lead to different
     * screens. There is no older desktop whose silence about the copilot means
     * anything but no access, because there is no older desktop that had one.
     *
     * Only literal `true` grants, matching the desktop: `"yes"`, `1` and
     * `"true"` are all false. A JSON file a person may edit will eventually
     * contain one of them, and the difference between reading it as an intention
     * and as a mistake is a difference in who gets access.
     */
    static func copilotGrant(_ value: Any?) -> CopilotGrant {
        guard let object = value as? [String: Any] else { return .none }
        return CopilotGrant(read: literalTrue(object["read"]),
                            act: literalTrue(object["act"]),
                            alter: literalTrue(object["alter"]))
    }

    /**
     * The whole of what a frame said about this device's copilot connection.
     *
     * The grant, the two connection facts, plus the one bit none of them can
     * carry: whether the field was there at all. See `CopilotConnection` — that
     * bit is the difference between a desktop with a copilot this device has not
     * been connected to, and a desktop with no copilot whose capability list
     * says otherwise.
     *
     * Only an object counts as having said something. `"copilot": "yes"` and
     * `"copilot": null` are a host this app does not understand, and the honest
     * reading of not understanding is that nothing was said — the same
     * direction every other refusal in this codec falls in.
     */
    static func copilotConnection(_ value: Any?) -> CopilotConnection {
        guard let object = value as? [String: Any] else { return .silent }
        return CopilotConnection(stated: true,
                                 linked: literalTrue(object["linked"]),
                                 // Read rather than assumed false, even though
                                 // the desktop swears it is false on every
                                 // `welcome`: this same decoder reads the
                                 // `copilot.grant` push, where `open` is the
                                 // whole message. A client that hard-coded the
                                 // welcome's promise here would have to keep a
                                 // second decoder for the frame that matters.
                                 open: literalTrue(object["open"]),
                                 grant: copilotGrant(object["grant"]))
    }

    /**
     * A JSON `true`, and nothing that merely resembles one.
     *
     * The rest of this codec reads its booleans with `as? Bool == true`, which is
     * right for the fields it reads them for — `replay`, `guessed`, `truncated`,
     * `more` are all the desktop describing something it just sent, and being
     * lenient about a `1` there costs a cosmetic flag at worst. A grant is not
     * that kind of field. It decides whether this phone draws a composer that can
     * spend money on somebody's machine, and whether it draws an Allow button, so
     * it gets the strict read — and the strictness has to be written out because
     * Swift will not do it for free: `JSONSerialization` hands back an `NSNumber`
     * for `1`, and `NSNumber as? Bool` **succeeds** for 0 and 1 through the ObjC
     * bridge. So the lenient spelling would have read `{"read":1}` as a granted
     * device — the exact refusal the desktop makes, silently undone one hop
     * later.
     *
     * The `CFBooleanGetTypeID` comparison is the same one `whole` makes in the
     * other direction, and for the mirrored reason: there, a `true` must not read
     * as the number 1; here, the number 1 must not read as `true`.
     */
    static func literalTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return false
        }
        return number.boolValue
    }

    /**
     * The state object off a `copilot.state`.
     *
     * Nil only when there is no `desk`, because that is the one field the frame
     * exists to carry — *is the copilot at the machine up* is the whole of the
     * read tier, and a report that does not answer it is not a report.
     *
     * `grant` is read as an optional, unlike every other use of `copilotGrant`
     * on this wire, and the asymmetry is deliberate: elsewhere absent means "no
     * access", which is the safe reading, but here it would mean *revoking this
     * phone's own screen* on the first state frame from a host that did not
     * repeat the field. Absent has to stay "did not say" when the consequence of
     * getting it wrong is taking a permission away that nobody touched.
     */
    static func copilotState(_ value: Any?) -> CopilotState? {
        guard let object = value as? [String: Any],
              let desk = string(object["desk"]), !desk.isEmpty else { return nil }
        return CopilotState(desk: desk,
                            run: string(object["run"]).flatMap { $0.isEmpty ? nil : $0 },
                            profile: displayLine(object["profile"]),
                            // Three answers. `as? Bool` on an NSNull is nil,
                            // which is the "not asked" the desktop means.
                            signedIn: object["signedIn"] as? Bool,
                            tools: max(0, whole(object["tools"]) ?? 0),
                            turnTokens: max(0, whole(object["turnTokens"]) ?? 0),
                            pending: max(0, whole(object["pending"]) ?? 0),
                            grant: object["grant"] is [String: Any]
                                ? copilotGrant(object["grant"])
                                : nil,
                            // Absent is not available. A Start button drawn over
                            // a host that never said one could start is the
                            // failure `available` exists to prevent.
                            available: literalTrue(object["available"]),
                            reason: displayLine(object["reason"]))
    }

    /**
     * One chat message, or nil.
     *
     * `text` is allowed to be empty and `at` is allowed to be missing, because
     * both are true of a real transcript: an agent's turn can begin as an empty
     * bubble that fills in, and an undated line is what `chat-transcript.ts`
     * reports as `at: 0`. What cannot be missing is the id, which is the whole
     * merge rule.
     *
     * The text is **not** put through `displayLine`. That helper flattens to one
     * line and cuts at 200 characters, which is right for a dev server's status
     * and catastrophic for an answer to "what happened overnight" — the newlines
     * are the paragraphs. Control characters other than newline and tab are
     * still stripped, because a stray carriage return from a progress bar in a
     * transcript renders as gibberish on a phone.
     */
    static func copilotMessage(_ value: Any?) -> CopilotChatMessage? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              let text = string(row["text"]) else { return nil }
        let at = (row["at"] as? NSNumber).map { $0.doubleValue } ?? 0
        return CopilotChatMessage(id: id,
                                  // Anything that is not literally "you" is drawn
                                  // as the agent. A bubble on the right of the
                                  // screen is a claim about who said something,
                                  // and a role this build has never heard of must
                                  // not be able to put words in the person's
                                  // mouth.
                                  role: string(row["role"]) == "you" ? .you : .agent,
                                  text: prose(text),
                                  at: at.isFinite && at > 0 ? at : 0,
                                  truncated: row["truncated"] as? Bool == true)
    }

    /// Several lines of text somebody is about to read. Keeps newlines and tabs,
    /// drops everything else invisible, and bounds the result at the same
    /// `MAX_COPILOT_MESSAGE_CHARS` the desktop cuts at — a cap only the far end
    /// enforces is not a cap.
    static func prose(_ raw: String) -> String {
        let cleaned = String(raw.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t"
                || !(scalar.value <= 0x1f || (scalar.value >= 0x7f && scalar.value <= 0x9f))
        })
        return cleaned.count <= Copilot.maxMessageChars
            ? cleaned
            : String(cleaned.prefix(Copilot.maxMessageChars))
    }

    /**
     * One action-log row, or nil. Exposed for the tests.
     *
     * Four fields are required and the rest are read leniently, and the split is
     * the same one the rest of the codec makes: `id`, `tool`, `outcome` and
     * `detail` are what the row *exists to say*. A row missing `outcome` cannot
     * be drawn at all — the whole screen is colour-coded on whether a call
     * happened, was refused, or broke — and a row with no `detail` is a row
     * about nothing.
     */
    static func copilotAction(_ value: Any?) -> CopilotAction? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              let tool = displayLine(row["tool"]),
              let outcome = string(row["outcome"]), !outcome.isEmpty,
              let detail = displayLine(row["detail"]) else { return nil }
        return CopilotAction(id: id,
                             at: isoMilliseconds(row["at"]),
                             tool: tool,
                             tier: string(row["tier"]) ?? "",
                             outcome: outcome,
                             detail: detail,
                             refusal: displayLine(row["refusal"]),
                             // Flat, not nested. `CopilotActionRow` carries the
                             // device id at the top level and states that null
                             // means the person at the machine; reading it out
                             // of a `caller` object — which is the shape of the
                             // desktop's *internal* `ActionRow`, one layer in —
                             // produced nil for every row and quietly attributed
                             // every phone's action to nobody.
                             deviceId: displayLine(row["deviceId"]))
    }

    /**
     * An ISO 8601 timestamp as epoch milliseconds, or nil.
     *
     * Two formatters because Apple's ISO parser is exact rather than lenient: one
     * configured for fractional seconds refuses a string without them, and the
     * plain one refuses a string with them. The desktop writes
     * `new Date().toISOString()`, which always has milliseconds — but this
     * function also reads rows written by `copilot-home.ts`, and a format that
     * parses only what today's writer happens to emit is a format that breaks on
     * the first row somebody hand-edits.
     */
    static func isoMilliseconds(_ value: Any?) -> Double? {
        guard let text = string(value), !text.isEmpty else { return nil }
        for formatter in [isoWithFraction, isoPlain] {
            if let date = formatter.date(from: text) { return date.timeIntervalSince1970 * 1000 }
        }
        return nil
    }

    // Held rather than built per row: an `ISO8601DateFormatter` is expensive to
    // create and the log screen builds two hundred rows in one pass.
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain = ISO8601DateFormatter()

    /**
     * One pending confirmation, or nil.
     *
     * `summary` is required for the reason the type's header gives: a question
     * with nothing to judge is a question that gets answered without being read,
     * and this end refuses to draw one.
     *
     * `mine` is read strictly and defaults to false. It decides whether an Allow
     * button exists, so a `1` or a `"true"` from a host this app does not
     * understand must not become one — and of the two ways to be wrong, hiding a
     * button that would have worked costs a walk to the desk while showing one
     * that cannot costs trust in every other button on the screen.
     */
    static func copilotQuestion(_ value: Any?) -> CopilotQuestion? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              let tool = displayLine(row["tool"]),
              let summary = displayLine(row["summary"]) else { return nil }
        return CopilotQuestion(id: id,
                               tool: tool,
                               summary: summary,
                               requestedAt: epoch(row["requestedAt"]),
                               expiresAt: epoch(row["expiresAt"]),
                               mine: literalTrue(row["mine"]))
    }

    /**
     * The full question off a `copilot.ask`, or nil.
     *
     * `raw` is the whole frame's text and is not an optimisation: it is how the
     * arguments keep the order the tool wrote them in. Foundation's reader hands
     * back an unordered dictionary, so the object below can say *which*
     * arguments there are and not *in what order*, and a consent screen that
     * shuffles somebody's arguments is showing them a different question from
     * the one on the Mac. See `CopilotArguments`.
     *
     * `summary` and `tool` are required for the same reason they are on the
     * watch row, and harder: this is the sheet with the buttons on it, and a
     * sheet that says *approve this* with nothing to approve is the reflex-Yes
     * machine the design refuses to build.
     */
    static func copilotConsentQuestion(_ value: Any?, raw: String) -> CopilotConsentQuestion? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              let tool = displayLine(row["tool"]),
              let summary = displayLine(row["summary"]) else { return nil }
        let ordered = CopilotArguments.fromAsk(rawFrame: raw)
        return CopilotConsentQuestion(
            id: id,
            tool: tool,
            tier: string(row["tier"]) ?? "",
            summary: summary,
            arguments: ordered ?? CopilotArguments.sorted(row["args"] as? [String: Any] ?? [:]),
            argumentsAreOrdered: ordered != nil,
            // Printed rather than mapped, and empty when the host did not say:
            // the sheet then says "a copilot on that machine" rather than
            // claiming it was this phone's own run, which is the one attribution
            // on the screen somebody would act on.
            origin: string(row["origin"]) ?? "",
            requestedAt: epoch(row["requestedAt"]),
            expiresAt: epoch(row["expiresAt"]))
    }

    /// One settled question, or nil. Only the id is required: a settlement with
    /// no id cannot withdraw anything, and everything else on it is a sentence
    /// rather than a decision.
    static func copilotSettlement(_ value: Any?) -> CopilotSettlement? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty else { return nil }
        return CopilotSettlement(id: id,
                                 granted: literalTrue(row["granted"]),
                                 by: displayLine(row["by"]),
                                 reason: displayLine(row["reason"]))
    }

    /// An epoch-millisecond field, or 0 for anything that is not one. Zero reads
    /// as "not said" everywhere it is used, which is why it is not an optional
    /// in the places it appears — a countdown either has a deadline or draws
    /// nothing.
    private static func epoch(_ value: Any?) -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let at = number.doubleValue
        return at.isFinite && at > 0 ? at : 0
    }

    /// One row of the copilot's own session list, or nil.
    static func copilotSessionRow(_ value: Any?) -> CopilotSessionRow? {
        guard let session = decodeSession(value) else { return nil }
        let row = value as? [String: Any]
        return CopilotSessionRow(session: session,
                                 originRunId: row.flatMap { string($0["originRunId"]) }
                                     .flatMap { $0.isEmpty ? nil : $0 })
    }
}
