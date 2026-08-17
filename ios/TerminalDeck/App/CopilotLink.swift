/**
 * One machine's copilot, as this phone sees it.
 *
 * Owned by `HostLink`, one per paired machine, for the same reason everything
 * else under a link is per machine: two Macs are two copilots, with two grants,
 * two action logs and two conversations, and a single app-wide object would be
 * right for whichever machine was greeted last.
 *
 * ## What this phone is talking to
 *
 * Not the copilot's keyboard. A granted phone gets a **run of its own** — same
 * folder, same `CLAUDE.md`, same `memory/`, same `deck-control` server and the
 * same action log as the copilot at the desk, with its own conversation and its
 * own bearer token. `COPILOT-REMOTE.md` §1 argues it at length; the short form
 * is that a shared conversation has no way to tell whose sentence caused which
 * tool call, so every permission check downstream of it would be guessing. Here
 * the caller *is* the token, which cannot be raced.
 *
 * What that costs is a scrollback, and the copilot never had one to lose:
 * `copilot-session.ts` already passes `resume: false`, and its comment says why
 * — *"an assistant that gets more expensive every day it is not restarted is a
 * bill nobody agreed to. Continuity is `memory/`."* By the design's own
 * definition, a run that shares `memory/` **is** the same copilot.
 *
 * ## Subscribed on every welcome, and never unsubscribed
 *
 * `copilot.attach` goes out on each `welcome` — the subscription belongs to the
 * desktop's *connection*, so a reconnect knows nothing about what the last one
 * was watching, exactly like `askDevServers`. It is **not** deferred until the
 * Copilot screen opens, and that is a decision rather than an oversight: half of
 * what this feature is for is telling somebody that a confirmation is waiting at
 * their Mac, and a phone that only learned about one after they went looking
 * would be telling them after they already had.
 *
 * Nothing here sends `copilot.detach`. See the case in `WireProtocol.swift`.
 *
 * ## History survives a drop. Claims about *now* do not.
 *
 * The distinction is the whole of `connectionLost`, and it is the one this app
 * has got wrong before. The conversation and the tool rows are things that
 * **happened** — the words really were said — so they stay on screen with the
 * connection banner over them. The state and the pending questions are claims
 * about the present, with a countdown on one of them, and nothing is going to
 * update either once the socket is gone; a two-minute timer ticking down over a
 * dead channel is precisely the "looks connected when it is not" failure the
 * whole client is built around avoiding. So those are cleared, and they come
 * back on the next `welcome`, which re-subscribes.
 */

import Foundation
import Observation

/// How a `CopilotLink` reaches the socket without reaching `HostLink`'s API.
/// The same one-method shape `TunnelWire` and `UploadWire` use, and satisfied by
/// the same `WireProxy` — one indirection buys back the rule that a view never
/// builds a wire message.
@MainActor
protocol CopilotWire: AnyObject {
    @discardableResult
    func send(_ message: ClientMessage) -> Bool
}

/**
 * One thing in the conversation: something that was said, or something that was
 * done.
 *
 * Interleaved in **one** list rather than split into a chat pane and an activity
 * pane, and this is the design decision the screen is built on. Asad's sentence
 * about the whole feature was *"exactly like you are working now for me — but
 * now you are working in folders and files, I don't know which files where and
 * all that stuff. Here I can actually see it."* Two panes would put the answer
 * in one and the machinery in the other, and the person would have to correlate
 * them by timestamp on a four-inch screen. One list in arrival order is the
 * window into the machinery, and it costs nothing: a tool row is two lines.
 *
 * Ordered by **arrival**, never by timestamp. A chat message can legitimately
 * carry `at: 0` — an undated transcript line — and an action's ISO stamp can
 * fail to parse; sorting on either would file those at the epoch, at the top of
 * the screen, above things that happened this morning. Arrival order on a single
 * FIFO connection is the truth about what this phone was told and when.
 */
enum CopilotEntry: Identifiable, Equatable {
    case message(CopilotChatMessage)
    case action(CopilotAction)

    /// Prefixed, because a chat id and an action id come from two different
    /// generators on the desktop and nothing makes them distinct from each
    /// other. An unprefixed collision would make `ForEach` reuse one row's
    /// identity for the other, which SwiftUI resolves by drawing one of them
    /// twice.
    var id: String {
        switch self {
        case let .message(message): return "m:\(message.id)"
        case let .action(action): return "a:\(action.id)"
        }
    }
}

@MainActor
@Observable
final class CopilotLink {

    /**
     * What this device may do. `.none` until a `welcome` says otherwise, which
     * is the answer for every device that has not been given something on the
     * desktop — the overwhelming majority, by design.
     */
    private(set) var grant: CopilotGrant = .none

    /// Whether the machine's capability list names `copilot`. False against
    /// every desktop shipping today, and a different question from the grant:
    /// one is about the host, the other about this device. **On its own it is
    /// not enough to draw anything** — see `isImplemented`.
    private(set) var isOffered = false

    /**
     * Whether the machine has actually shown a copilot, rather than advertised
     * one.
     *
     * The capability list is assembled on the desktop by filtering
     * `CAPABILITIES` — *every extension this build knows how to serve* — against
     * what its injected objects can do, and the filter is a separate line of
     * code from the list. When those drift, a host advertises a feature it
     * cannot serve: `ios/Harness/host-standin.ts` sends the whole list verbatim
     * and implements almost none of it, and an earlier pass over a different
     * feature was reported as verified against exactly the empty screen that
     * produces.
     *
     * Two things set this, and both come from the code path that *is* the
     * implementation rather than from a name beside it:
     *
     *  - a `welcome` carrying a `copilot` object, which `copilotFrame()` on the
     *    desktop emits only when there is a copilot layer — including when the
     *    grant inside it is all-false, which is the case this whole distinction
     *    exists for;
     *  - any `copilot.*` frame arriving, which no host without one can send.
     *
     * It is deliberately **not** cleared by `connectionLost`. Whether a machine
     * has a copilot is a fact about the build running on it, not about this
     * socket, and clearing it would take the screen away for the three seconds
     * of a reconnect — inside the window `ConnectionGrace` spends deliberately
     * saying nothing, so the feature would vanish with no explanation anywhere
     * on the phone. `forget()` does clear it, because that machine is gone.
     */
    private(set) var isImplemented = false

    /// What the copilot is, or nil when the machine has not said yet — which is
    /// also what it is after a drop. Nil draws "not known", never "stopped".
    private(set) var state: CopilotState?

    /// The conversation and the machinery, in arrival order. See `CopilotEntry`.
    private(set) var timeline: [CopilotEntry] = []

    /// The sessions the copilot started, in the desktop's own order.
    private(set) var sessions: [CopilotSessionRow] = []

    /**
     * Confirmations waiting **at the desk**, watch-only.
     *
     * There is no method on this type that answers one and there must not be.
     * See `CopilotQuestion` for the argument, which is not squeamishness: the
     * alter tier's safety property is *a human at the machine says yes*, and a
     * dialog answered on the device that raised the request is answered by the
     * party being confirmed.
     */
    private(set) var pending: [CopilotQuestion] = []

    /// A page of the action log, oldest first, for the Activity screen. Empty
    /// until that screen asks — the log is a file on the desktop and there is no
    /// reason to pull it down a relay until somebody wants to read it.
    private(set) var log: [CopilotAction] = []
    /// The desktop had more rows than it sent. Drives the "Load older" row, and
    /// nothing else: a button offering to load what does not exist is a button
    /// that reports success having done nothing.
    private(set) var logHasMore = false
    private(set) var isLoadingLog = false

    /**
     * Which run the messages on screen belong to.
     *
     * Tracked separately from `state?.run` because the two can legitimately
     * disagree for one frame — the state and the chat are two frames and one
     * arrives first — and because it is what makes the drop rule below
     * enforceable rather than aspirational.
     */
    private(set) var chatRun: String?

    /// A sentence about something that just went wrong here, handed up so there
    /// is one error surface on the machine rather than two that can disagree
    /// about which is showing.
    var onError: ((String) -> Void)?

    private let wire: CopilotWire

    init(wire: CopilotWire) {
        self.wire = wire
    }

    // MARK: - What may be drawn

    /// Whether there is a copilot screen on this machine at all. A
    /// granted-nothing device still gets the screen, because the screen is where
    /// it is told where to fix that — but a machine that only *advertised* one
    /// does not, because there is nothing on it to point at. See `CopilotAccess`
    /// and `isImplemented`.
    var isAvailable: Bool { isOffered && isImplemented }

    /// What this phone may do, as one value, so no screen has to re-derive it
    /// from two booleans and a capability and get one of the four combinations
    /// wrong.
    var access: CopilotAccess {
        // Both, and neither alone. The capability without the implementation is
        // a host advertising a feature it cannot serve; the implementation
        // without the capability is a host this app has no agreed vocabulary
        // with, and sending it frames on the strength of one field would be
        // guessing. See `isImplemented`.
        guard isAvailable else { return .notOffered }
        if grant.canDirect { return .direct }
        if grant.canWatch { return .watch }
        return .notGranted
    }

    /**
     * How many confirmations are waiting, for a badge.
     *
     * `pending.count` once a `copilot.pending` has been seen, and the state's
     * own number before that. They agree in the steady state — the broker caps
     * itself at three and the frame carries all of them — so this is only about
     * the first seconds of a connection, where the state answers before the
     * questions do and a badge that waited would be a badge that appeared late
     * for exactly the thing it exists to be early about.
     */
    var waitingCount: Int {
        sawPending ? pending.count : (state?.pending ?? 0)
    }

    private var sawPending = false

    /// Whether this phone has a run of its own going. Nil `state` reads as no,
    /// which is the safe way round: it hides Stop rather than offering it
    /// against a run nobody has confirmed exists.
    var hasRun: Bool { state?.run != nil }

    // MARK: - The connection

    /**
     * A `welcome` arrived. Take the grant, and subscribe if it allows.
     *
     * The grant is applied **before** anything is sent, so a device that was
     * revoked while it was away cannot put a frame on the wire that its own
     * screen has already stopped offering. That ordering is free here and is the
     * kind of thing that stops being free once somebody adds a second caller.
     */
    func welcomed(capabilities: Set<String>, offer: CopilotOffer) {
        isOffered = capabilities.contains(Copilot.capability)
        // Latched rather than assigned. A machine that showed a copilot once has
        // one; a later `welcome` that omitted the field would be a host bug, and
        // taking the screen away over it is a worse answer than leaving it up
        // over frames that would refuse themselves anyway.
        if offer.stated { isImplemented = true }
        apply(grant: offer.grant)
        subscribe()
    }

    /**
     * Ask for the stream, and for the two things it does not replay.
     *
     * `copilot.attach` is answered with the state and the conversation.
     * `copilot.sessions` and `copilot.pending` are separate answers, so they are
     * asked for separately — three frames on a connection, once, rather than a
     * timer.
     */
    private func subscribe() {
        guard isOffered, grant.canWatch else { return }
        wire.send(.copilotAttach)
        wire.send(.copilotSessions)
        wire.send(.copilotPending)
    }

    /// Pull-to-refresh, and nothing else. Everything here is pushed while the
    /// socket is up, so a timer would be this app polling a question the desktop
    /// is already answering — his own standing rule about events over polling.
    func refresh() {
        guard isOffered, grant.canWatch else { return }
        wire.send(.copilotState)
        wire.send(.copilotSessions)
        wire.send(.copilotPending)
    }

    /// The socket went. See the header: history stays, claims about now go.
    func connectionLost() {
        state = nil
        pending = []
        sawPending = false
        isLoadingLog = false
    }

    /// The machine is being torn down — unpaired, or re-paired. Everything goes,
    /// including the grant, which belongs to a live connection: remembering one
    /// across a stop would leave a phone drawing a composer for a machine it has
    /// not been readmitted to.
    func forget() {
        grant = .none
        isOffered = false
        // And what this machine turned out to be. Unlike `connectionLost`, which
        // keeps it because a build does not change while a socket blinks, an
        // unpair means the next machine behind this object may be a different
        // one entirely.
        isImplemented = false
        state = nil
        timeline = []
        sessions = []
        pending = []
        sawPending = false
        log = []
        logHasMore = false
        isLoadingLog = false
        chatRun = nil
    }

    // MARK: - Inbound

    /**
     * A `copilot.*` frame arrived, so this machine has a copilot.
     *
     * The second of the two signals `isImplemented` documents, and the reason
     * every inbound path below calls it: no host without a copilot layer can
     * send one of these frames, whatever its capability list claims. In practice
     * the `welcome` has already settled it — both are written by the same object
     * on the desktop — and this is the belt to that pair of braces, which costs
     * one line per frame and closes the case where a host answers the frames
     * while getting its own `welcome` wrong.
     */
    private func implemented() {
        isImplemented = true
    }

    /**
     * A pushed `copilot.grant`.
     *
     * Separate from `apply(grant:)` below only so that arriving as a *frame*
     * confirms the machine has a copilot, while the same grant arriving inside a
     * `welcome` does not — there, the field's presence is what confirms it, and
     * `welcome` carries the grant whether or not there is anything behind it.
     */
    func apply(pushed next: CopilotGrant) {
        implemented()
        apply(grant: next)
    }

    /**
     * The grant changed, from a `welcome` or from a pushed `copilot.grant`.
     *
     * A device that loses `read` loses the screen, so everything the screen was
     * showing is dropped here rather than merely hidden. Leaving it in memory
     * would mean a phone that was re-granted a minute later came back showing a
     * conversation and a set of tool rows from before it was revoked, with
     * nothing having re-checked whether any of it is still true — and, worse, a
     * person believing their revoke had not worked.
     *
     * Nothing is sent. `copilot.detach` needs `read` like every other frame on
     * this surface, so a phone that has just lost it would be answered with an
     * `unauthorized` error banner for trying to be polite.
     */
    func apply(grant next: CopilotGrant) {
        let had = grant
        grant = next
        guard !next.canWatch, had.canWatch else { return }
        state = nil
        timeline = []
        sessions = []
        pending = []
        sawPending = false
        log = []
        logHasMore = false
        chatRun = nil
    }

    func apply(state next: CopilotState) {
        implemented()
        state = next
        // A run that has gone takes its conversation with it. The desktop stops
        // a run whose device has been away past the grace window, and the next
        // thing this phone would otherwise show is a composer under somebody
        // else's answer to a question that is over.
        if next.run == nil && chatRun != nil {
            timeline = timeline.filter { entry in
                if case .message = entry { return false }
                return true
            }
            chatRun = nil
        }
    }

    /**
     * Messages for a run.
     *
     * Three rules, and the middle one is the one with teeth:
     *
     *  - **`reset` adopts.** It means "this is the whole conversation", so it
     *    replaces the messages on screen and takes the frame's run as the run.
     *    It is what `copilot.attach` is answered with, and what a fresh run
     *    sends.
     *  - **A non-reset frame for a run we have no baseline for is dropped.**
     *    Not merged, not adopted. It is a fragment of a conversation whose
     *    beginning this phone never saw, and appending it would draw an agent
     *    apparently answering a question nobody asked — which is exactly what
     *    the `run` field on this frame exists to prevent.
     *  - **Merge by id.** Replace on a match, append otherwise. A streaming
     *    answer arrives as the same id with more text in it each time, which is
     *    what makes it readable rather than a screenful of fragments.
     *
     * Tool rows are untouched by all three. A `reset` is about the conversation;
     * the machinery either side of it happened whatever the chat says.
     */
    func apply(chat run: String, messages: [CopilotChatMessage], reset: Bool) {
        implemented()
        if reset {
            chatRun = run
            timeline = timeline.filter { entry in
                if case .message = entry { return false }
                return true
            }
        } else if chatRun != run {
            return
        }

        for message in messages { merge(message) }
        trim()
    }

    private func merge(_ message: CopilotChatMessage) {
        let entry = CopilotEntry.message(message)
        if let at = timeline.firstIndex(where: { $0.id == entry.id }) {
            timeline[at] = entry
        } else {
            timeline.append(entry)
        }
    }

    /**
     * One tool call, as it happened.
     *
     * Idempotent by id, because the same row can arrive twice: a push while the
     * screen is open, and the same row again in a `copilot.log` page if the two
     * ever overlap. Writing it twice costs nothing; drawing it twice is a phone
     * claiming the copilot did something once more than it did.
     */
    func apply(tool row: CopilotAction) {
        implemented()
        let entry = CopilotEntry.action(row)
        if let at = timeline.firstIndex(where: { $0.id == entry.id }) {
            timeline[at] = entry
        } else {
            timeline.append(entry)
        }
        trim()
    }

    /// The oldest go first. See `Copilot.maxTimelineRows`: the whole history is
    /// still one tap away in Activity, which pages against the file on the
    /// desktop rather than against this array.
    private func trim() {
        guard timeline.count > Copilot.maxTimelineRows else { return }
        timeline.removeFirst(timeline.count - Copilot.maxTimelineRows)
    }

    func apply(sessions rows: [CopilotSessionRow]) {
        implemented()
        sessions = rows
    }

    func apply(pending questions: [CopilotQuestion]) {
        implemented()
        pending = questions
        sawPending = true
    }

    /**
     * A page of the log.
     *
     * Prepended when it was asked for with a `before`, because paging backwards
     * means the older rows go above what is already there. Replaced otherwise,
     * because that is the tail and the tail is the whole answer.
     *
     * Deduplicated by id on the way in rather than trusted: a row can be in both
     * pages if something was written between the two requests, and a log with
     * one entry drawn twice is a log somebody stops believing.
     */
    func apply(log rows: [CopilotAction], more: Bool) {
        implemented()
        isLoadingLog = false
        logHasMore = more
        guard pagingBack else {
            log = rows
            return
        }
        pagingBack = false
        let known = Set(log.map(\.id))
        log = rows.filter { !known.contains($0.id) } + log
    }

    private var pagingBack = false

    // MARK: - Outbound, read tier

    /// Fetch the tail of the action log. Read tier, so a watching phone gets the
    /// whole Activity screen.
    func loadLog() {
        guard grant.canWatch, !isLoadingLog else { return }
        isLoadingLog = true
        pagingBack = false
        guard wire.send(.copilotLog(limit: Copilot.logPage, before: nil)) else {
            isLoadingLog = false
            onError?("Not connected — the activity log was not asked for.")
            return
        }
    }

    /// The page before the oldest row on screen.
    func loadOlder() {
        guard grant.canWatch, !isLoadingLog, logHasMore, let oldest = log.first else { return }
        isLoadingLog = true
        pagingBack = true
        guard wire.send(.copilotLog(limit: Copilot.logPage, before: oldest.id)) else {
            isLoadingLog = false
            pagingBack = false
            onError?("Not connected — nothing older was asked for.")
            return
        }
    }

    // MARK: - Outbound, act tier

    /**
     * Start this phone's own run. **The tap is the consent, and it spends money.**
     *
     * Guarded here as well as by the button being absent, because the two guards
     * answer different failures: the absent button is for the phone whose grant
     * never allowed this, and this one is for the grant that was revoked between
     * the screen being drawn and the finger landing.
     */
    func start() {
        guard grant.canDirect else { return refuse() }
        guard wire.send(.copilotStart) else {
            return onError?("Not connected — the copilot was not asked to start.") ?? ()
        }
    }

    /**
     * Say something to it.
     *
     * Returns the text that could not be sent, so the composer can keep it: a
     * message that vanishes out of a text field because a socket was down is a
     * message somebody has to retype, and they will not know they have to until
     * they notice the answer never came.
     *
     * Over-length is refused with the number rather than truncated. A
     * `copilot.say` is one utterance and half of one is a different question —
     * unlike a paste, which `chunkInput` may legitimately split because a
     * terminal has no notion of a message at all.
     */
    @discardableResult
    func say(_ text: String) -> Bool {
        let trimmed = Self.oneUtterance(text)
        guard !trimmed.isEmpty else { return false }
        guard grant.canDirect else {
            refuse()
            return false
        }
        guard trimmed.utf8.count <= Copilot.maxSayBytes else {
            onError?("That message is \(byteSize(trimmed.utf8.count)). The most the copilot will "
                     + "take at once is \(byteSize(Copilot.maxSayBytes)).")
            return false
        }
        guard wire.send(.copilotSay(text: trimmed)) else {
            onError?("Not connected — that was not sent.")
            return false
        }
        return true
    }

    /**
     * One message, in the only shape the far end will accept.
     *
     * **The desktop refuses a `copilot.say` containing any control byte — and a
     * newline is one.** `parseClientMessage` says why and it is a security check
     * rather than tidiness: the text is written into a pty holding a Claude CLI,
     * so a carriage return inside it would submit early and turn the rest of the
     * message into a *second* prompt, at somebody's expense. The submitting
     * newline is added by the desktop, once, so one frame is at most one prompt.
     *
     * Which means a multi-line message is not a long message — it is a refused
     * one. So it is repaired here, at the keyboard, where the text comes from:
     * every control character becomes a space, and the result is trimmed. That
     * is the opposite of the rule the desktop keeps about its own inputs — *a
     * control byte is refused rather than stripped, since stripping turns a
     * hostile value into a different legal-looking one* — and the difference is
     * whose value it is. Theirs arrives off a network from an unknown party;
     * this one was typed on this device seconds ago by the person reading the
     * screen, and a space is what they meant by a line break in a medium that
     * has no lines.
     *
     * `CopilotView` does the same substitution as the field is typed into, so
     * what is on screen is what will be sent. This one is the guard for the
     * paths that field does not cover: a paste, a dictation, a shortcut.
     */
    static func oneUtterance(_ text: String) -> String {
        let flattened = String(text.unicodeScalars.map { scalar in
            scalar.value <= 0x1f || (scalar.value >= 0x7f && scalar.value <= 0x9f)
                ? " " as Character
                : Character(scalar)
        })
        return flattened.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Interrupt the current turn of this phone's own run.
    func cancel() {
        guard grant.canDirect else { return refuse() }
        guard wire.send(.copilotCancel) else {
            return onError?("Not connected — the copilot was not interrupted.") ?? ()
        }
    }

    /// End this phone's own run. Not the copilot at the desk — runs are keyed by
    /// device, and this frame reaches only the one this phone started.
    func stop() {
        guard grant.canDirect else { return refuse() }
        guard wire.send(.copilotStop) else {
            return onError?("Not connected — the run was not stopped.") ?? ()
        }
    }

    /// The sentence for a control that was drawn under a grant that has since
    /// gone. It names where the fix is, because the grant is per device and it
    /// is edited on the machine — a message that only said "not allowed" would
    /// send somebody hunting on the wrong screen.
    private func refuse() {
        onError?("This phone is not allowed to direct the copilot. That is a switch on the "
                 + "machine, in Settings.")
    }
}

/**
 * The four things this phone can be, with respect to one machine's copilot.
 *
 * One type rather than a capability flag and two booleans at every call site,
 * because there are four states and the screens have to draw four different
 * things — and the failure mode of re-deriving it is drawing the *third* screen
 * for the *fourth* state, which is a phone hiding a feature that a person could
 * have turned on in ten seconds if anything had told them it existed.
 */
enum CopilotAccess: Equatable {
    /// The machine does not speak `copilot.*`. Every desktop shipping today,
    /// including 0.3.0. Nothing is drawn — there is no switch on that machine to
    /// point at, so a screen explaining where to find one would be a screen
    /// sending somebody to look for a control that is not there.
    case notOffered
    /// The machine has a copilot and this device has not been given any of it.
    /// **Drawn, and explained.** This is the one state a person can fix, and
    /// they fix it on the desktop — the same argument `hasNoGrantedFolders`
    /// makes for the New Session button one screen over.
    case notGranted
    /// Watching: what it is doing, what it started, what it was refused. No
    /// composer, no Start — `copilot.say` is `act`, because talking to the
    /// copilot spends money and causes tool calls.
    case watch
    /// Watching, and able to start a run and talk to it.
    case direct
}
