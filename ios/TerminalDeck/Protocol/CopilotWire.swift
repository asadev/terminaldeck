/**
 * The `copilot` half of the wire language, as this client sees it.
 *
 * A port of §2 of `COPILOT-REMOTE.md`, which settles the frames, the caps and
 * the grant. It lives beside `WireProtocol.swift` under the same rule that file
 * states about itself: it is a **copy** of the desktop's `protocol.ts`, Swift
 * having no way to import TypeScript, and it changes only when that file
 * changes, with the same names and the same values.
 *
 * ## The one property this file exists to preserve
 *
 * **No tool name ever appears in a client frame.** There is no `copilot.tool`
 * verb, no argument object this end can compose, no tool id in anything the
 * `ClientMessage` cases below can carry. The phone sends *prose*; the tool calls
 * are made by a Claude CLI on the desktop, over loopback, holding a bearer token
 * this phone does not have. The design calls this the strongest form of the
 * property the feature needs — *a phone that has not been granted alter must not
 * be able to reach an alter tool by any frame it can construct* — because the
 * set of frames it can construct contains no tool at all.
 *
 * It is also the rule that will come under pressure, because the obvious phone
 * feature is "tap that row to run it again". `CopilotWireTests` pins it: a
 * corpus test over every outbound case asserting that none of them carries a
 * tool id. If a future frame needs one, this comment is where the argument
 * against it is.
 *
 * ## Read is the floor; act is a second switch on top of it
 *
 * `server.ts` refuses every `copilot.*` frame from a device whose grant does not
 * cover it — `read` for the whole surface, `act` additionally for `start`,
 * `say`, `cancel` and `stop`. That refusal is the transport keeping the UI
 * honest rather than the boundary itself (the boundary is `DeckControl.call` on
 * the desktop, where it already is). What it means *here* is that a control this
 * grant does not cover must not be drawn: a button whose only possible outcome
 * is a refusal is the defect `reachable.test.ts` warns about, one level out.
 *
 * ## `alter` is not on this wire, in any spelling
 *
 * Not as a field, not as `false`, not as a case. `copilot-grants.ts` makes the
 * same choice for the file on disk and gives the reason: a stored `"alter":
 * false` reads, to somebody looking at it, like a switch that could be turned
 * on. It cannot be — `REMOTE_GRANTABLE_TIERS` is `['read', 'act']` — and neither
 * this type nor any screen built on it should imply otherwise. What the phone
 * *does* get is `copilot.pending`: it can see that a question is waiting at the
 * desk, with the desktop's own summary and the countdown, and it cannot answer
 * it. See `CopilotQuestion`.
 */

import Foundation

enum Copilot {

    /**
     * The desktop can speak `copilot.*` frames.
     *
     * Advertised in `welcome.capabilities`, like every other name past protocol
     * v1, and read the same way: absent means "this desktop has never heard of
     * the feature", which is every build shipping today including 0.3.0. It is
     * **not** the same question as whether this device may use it — that is the
     * grant, which travels separately, for the reason `folders` travels
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
}

/**
 * What one device may do with the copilot.
 *
 * Two booleans, and deliberately not three. See the file header.
 *
 * `none` is the default for every device, including every device paired before
 * this existed: `CopilotGrants.granted` answers `NO_TIERS` for an unknown device
 * and the store's header explains why it does *not* inherit `folder-grants.ts`'s
 * generous fallback — nobody has ever had remote copilot access, so nobody can
 * lose it.
 */
struct CopilotGrant: Equatable {
    let read: Bool
    let act: Bool

    static let none = CopilotGrant(read: false, act: false)

    /// Whether this phone may see anything at all. `read` is the floor for the
    /// whole surface, so this is also the answer to "is there a screen here".
    var canWatch: Bool { read }

    /**
     * Whether this phone may make the copilot do something.
     *
     * `read && act`, not `act`. A hand-edited `remote-copilot.json` can produce
     * `{read: false, act: true}` — `copilotGrantFrom` keeps whatever is literally
     * `true` for each grantable tier and has no rule tying one to the other — and
     * against a desktop that refuses the whole surface without `read`, drawing a
     * composer for that grant would be drawing a control whose every message
     * comes back `unauthorized`. The floor is a floor.
     */
    var canDirect: Bool { read && act }

    /// True when this device has been granted nothing, which is the case the
    /// screen exists to explain rather than hide.
    var isEmpty: Bool { !read && !act }
}

/**
 * What a `welcome` said about the copilot: whether the machine **has** one, and
 * what this device may do with it.
 *
 * Two questions, and this type exists because the app got them confused once and
 * the confusion is expensive on screen.
 *
 * `welcome.capabilities` is not a reliable answer to the first one. The desktop
 * assembles that list by filtering `CAPABILITIES` — *every extension this build
 * knows how to serve* — against what its injected objects can actually do, and
 * the filter is a separate line of code from the thing it is filtering for. A
 * build where the two have drifted advertises a feature it cannot serve, which
 * is not hypothetical: `ios/Harness/host-standin.ts` sends the whole of
 * `CAPABILITIES` verbatim and implements almost none of it, and an earlier pass
 * over a different feature was reported as verified against the empty screen
 * that produced.
 *
 * `welcome.copilot` **is** a reliable answer, because it is written by the same
 * object that serves the frames: `copilotFrame()` on the desktop returns `{}`
 * when there is no copilot layer and the grant object — *even when it is
 * all-false* — when there is one. A host that has a copilot says so in this
 * field by construction; a host that merely advertises the name cannot.
 *
 * So `stated` is the question "does this machine have a copilot at all", and
 * `grant` is the question "and may I touch it". Keeping them apart is what lets
 * a phone tell *this desktop is too old, update it* from *this desktop has one
 * and you have not been given it, here is where the switch is* — two sentences
 * that send a person to two different places, only one of which exists.
 */
struct CopilotOffer: Equatable {
    /// The `welcome` carried a `copilot` object. See the type's header: this is
    /// the honest signal, and the capability name is not.
    let stated: Bool
    let grant: CopilotGrant

    /// A desktop that said nothing. Every build shipping today.
    static let silent = CopilotOffer(stated: false, grant: .none)
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
     * `{read:false, act:false}` would revoke this phone's own screen on the
     * first state frame from a host that did not repeat it.
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
 * tool composed — never the payload. The screens here draw exactly that and no
 * affordance that implies more is available behind a tap.
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
 * A confirmation waiting **at the desk**, and it is watch-only.
 *
 * A port of `CopilotPendingRow`, whose own header makes the argument this type
 * exists to carry: the alter tier's whole safety property is that a human at the
 * machine says yes, and the party holding the phone is by definition not that
 * human. A phone that could answer its own request holds `alter`, and the grant
 * that withheld it was a ceremony.
 *
 * What it is *for* is the failure the design named: the desktop dialog is on a
 * screen nobody is looking at, and two minutes later it times out in silence.
 * The phone's job is to say **go and look** — with enough to know whether it is
 * worth getting up for (what is being asked, in the desktop's own summary) and
 * how long there is to do it (`expiresAt`).
 *
 * Note what is deliberately not here, because a screen drawn from an earlier
 * draft of this type tried to show both: there is **no tier and no argument
 * list**. The full request — every argument verbatim — lives at the machine
 * where it is answered, which is the same place the decision lives. A phone that
 * showed the arguments would be inviting a judgement it cannot then act on, and
 * relaying the text of what an agent is about to type into somebody's session
 * across a relay to do it.
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

    /// Seconds left, floored at zero. Nil when the desktop sent no expiry, in
    /// which case the screen shows no countdown rather than a made-up one.
    func secondsLeft(now: Date = Date()) -> Int? {
        guard expiresAt > 0 else { return nil }
        return max(0, Int((expiresAt / 1000 - now.timeIntervalSince1970).rounded(.down)))
    }
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
     * The grant, from a `welcome` or from a `copilot.grant`.
     *
     * **Absent is `.none`, and so is malformed.** Both mean the same thing —
     * this device may do nothing — and collapsing them is right here in a way it
     * would be wrong for `folders`, where nil ("the desktop never mentioned
     * folders") and `[]` ("a person granted this device none") lead to different
     * screens. There is no older desktop whose silence about the copilot means
     * anything but no access, because there is no older desktop that had one.
     *
     * Only literal `true` grants, matching `copilotGrantFrom` on the desktop:
     * `"yes"`, `1` and `"true"` are all false. A JSON file a person may edit will
     * eventually contain one of them, and the difference between reading it as
     * an intention and as a mistake is a difference in who gets access.
     */
    static func copilotGrant(_ value: Any?) -> CopilotGrant {
        guard let object = value as? [String: Any] else { return .none }
        return CopilotGrant(read: literalTrue(object["read"]),
                            act: literalTrue(object["act"]))
    }

    /**
     * The whole of what a `welcome` said about the copilot.
     *
     * The grant, plus the one bit the grant cannot carry: whether the field was
     * there at all. See `CopilotOffer` — that bit is the difference between a
     * desktop with a copilot this phone has not been given, and a desktop with
     * no copilot whose capability list says otherwise.
     *
     * Only an object counts as having said something. `"copilot": "yes"` and
     * `"copilot": null` are a host this app does not understand, and the honest
     * reading of not understanding is that nothing was said — the same
     * direction every other refusal in this codec falls in.
     */
    static func copilotOffer(_ value: Any?) -> CopilotOffer {
        guard let object = value as? [String: Any] else { return .silent }
        return CopilotOffer(stated: true, grant: copilotGrant(object))
    }

    /**
     * A JSON `true`, and nothing that merely resembles one.
     *
     * The rest of this codec reads its booleans with `as? Bool == true`, which is
     * right for the fields it reads them for — `replay`, `guessed`, `truncated`,
     * `more` are all the desktop describing something it just sent, and being
     * lenient about a `1` there costs a cosmetic flag at worst. A grant is not
     * that kind of field. It decides whether this phone draws a composer that can
     * spend money on somebody's machine, so it gets the strict read, and the
     * strictness has to be written out because Swift will not do it for free:
     * `JSONSerialization` hands back an `NSNumber` for `1`, and `NSNumber as?
     * Bool` **succeeds** for 0 and 1 through the ObjC bridge. So the lenient
     * spelling would have read `{"read":1}` as a granted device — the exact
     * refusal `copilotGrantFrom` makes on the desktop, silently undone one hop
     * later.
     *
     * The `CFBooleanGetTypeID` comparison is the same one `whole` makes in the
     * other direction, and for the mirrored reason: there, a `true` must not read
     * as the number 1; here, the number 1 must not read as `true`.
     */
    private static func literalTrue(_ value: Any?) -> Bool {
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

    /// One pending confirmation, or nil. `summary` is required for the reason
    /// the type's header gives: a question with nothing to judge is a question
    /// that gets answered without being read, and this end refuses to draw one.
    static func copilotQuestion(_ value: Any?) -> CopilotQuestion? {
        guard let row = value as? [String: Any],
              let id = string(row["id"]), !id.isEmpty,
              let tool = displayLine(row["tool"]),
              let summary = displayLine(row["summary"]) else { return nil }
        return CopilotQuestion(id: id,
                               tool: tool,
                               summary: summary,
                               requestedAt: epoch(row["requestedAt"]),
                               expiresAt: epoch(row["expiresAt"]))
    }

    /// An epoch-millisecond field, or 0 for anything that is not one. Zero reads
    /// as "not said" everywhere it is used, which is why it is not an optional
    /// in the two places it appears — a countdown either has a deadline or draws
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
