/**
 * One machine's copilot, as this phone sees it.
 *
 * Owned by `HostLink`, one per paired machine, for the same reason everything
 * else under a link is per machine: two Macs are two copilots, with two
 * connections, two grants, two action logs and two conversations, and a single
 * app-wide object would be right for whichever machine was greeted last.
 *
 * ## The copilot is a **separate connection**, and this object is where that
 * lives on the phone
 *
 * Pairing a device for terminals grants it no copilot reach at all — not a tab,
 * not a frame, not a refusal whose shape it could measure. Somebody at the
 * machine mints a **six-digit connect code**, it is typed in here, and the
 * desktop answers once with a credential this phone stores beside its pairing
 * credential. From then on **every socket sends `copilot.hello` before any other
 * `copilot.*` frame**, on every reconnect, because a session channel does not
 * carry the copilot by existing.
 *
 * That is not ceremony. `COPILOT-REMOTE.md` §4 argues it at length: the second
 * factor behind the `alter` tier was never *being at the desk* — somebody who
 * walks away from an unlocked Mac has taken their geography with them — it was
 * *reaching the dialog required an authorisation the requesting party did not
 * already hold*. The connection is that authorisation, and it is the one thing
 * this phone cannot grant itself.
 *
 * So there are three separate questions here and the screens depend on all
 * three: does the machine **have** a copilot (`isImplemented`), does it hold a
 * record for this device (`linked`), and is **this socket** in (`isOpen`).
 *
 * ## What this phone is talking to
 *
 * Not the copilot's keyboard. A connected phone gets a **run of its own** — same
 * folder, same `CLAUDE.md`, same `memory/`, same `deck-control` server and the
 * same action log as the copilot at the desk, with its own conversation and its
 * own bearer token. §1 argues it; the short form is that a shared conversation
 * has no way to tell whose sentence caused which tool call, so every permission
 * check downstream of it would be guessing. Here the caller *is* the token,
 * which cannot be raced.
 *
 * What that costs is a scrollback, and the copilot never had one to lose:
 * `copilot-session.ts` already passes `resume: false`, and its comment says why
 * — *"an assistant that gets more expensive every day it is not restarted is a
 * bill nobody agreed to. Continuity is `memory/`."* By the design's own
 * definition, a run that shares `memory/` **is** the same copilot.
 *
 * ## Subscribed when the connection opens, and never before
 *
 * `copilot.attach` goes out on `copilot.grant` with `open: true` — never on the
 * `welcome`, because at that moment this socket has not presented anything and
 * every frame would come back `unauthorized`. It is **not** deferred until the
 * Copilot screen opens, and that is a decision rather than an oversight: half of
 * what this feature is for is telling somebody that a confirmation is waiting,
 * and a phone that only learned about one after they went looking would be
 * telling them after they already had.
 *
 * ## History survives a drop. Claims about *now* do not.
 *
 * The distinction is the whole of `connectionLost`, and it is the one this app
 * has got wrong before. The conversation and the tool rows are things that
 * **happened** — the words really were said — so they stay on screen with the
 * connection banner over them. The state, the pending questions and any
 * confirmation waiting for an answer are claims about the present, with a
 * countdown on two of them, and nothing is going to update any of them once the
 * socket is gone; a two-minute timer ticking down over a dead channel is
 * precisely the "looks connected when it is not" failure the whole client is
 * built around avoiding. So those are cleared, and they come back after the next
 * `copilot.hello`.
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
 * Where the copilot credential is kept, from this object's point of view.
 *
 * A second secret, in the Keychain, beside the pairing one and with the same
 * protection class — `COPILOT-REMOTE.md` §8 asks for exactly that and the reason
 * is that the two are worth the same. A copilot credential opens an agent that
 * holds `Write` and `Bash` on somebody's machine; a session credential opens a
 * shell on it. Neither belongs in `UserDefaults`, in a plist, or in an
 * unencrypted backup.
 *
 * A seam rather than a direct `CredentialStore` call for the reason `CopilotWire`
 * is one: this object is exercised with no Keychain, no host and no socket, and
 * the credential path is the one that most needs to be drivable in that state —
 * what it does is decide which of two screens somebody sees.
 *
 * `store(nil)` is a real instruction and not a tidy-up: it is what a
 * `copilot.grant` carrying `linked: false` means. The record on that machine has
 * gone, so the secret this phone is holding opens nothing, and keeping it would
 * leave a live-looking credential in the Keychain with nobody's name against it.
 */
@MainActor
protocol CopilotVault: AnyObject {
    func copilotCredential() -> String?
    func storeCopilotCredential(_ credential: String?)
}

/**
 * The vault a real link uses: two closures onto whichever object owns the
 * machine's stored record.
 *
 * The same shape as `WireProxy` and for the same reason — one indirection buys
 * back the rule that this object never reaches `HostLink`'s API, and the weak
 * captures at the call site are what stop a link and its host holding each other
 * alive forever.
 */
@MainActor
final class CopilotVaultProxy: CopilotVault {
    private let read: () -> String?
    private let write: (String?) -> Void

    init(read: @escaping () -> String?, write: @escaping (String?) -> Void) {
        self.read = read
        self.write = write
    }

    func copilotCredential() -> String? { read() }
    func storeCopilotCredential(_ credential: String?) { write(credential) }
}

/// A vault that remembers nothing, for a link built without one. Not a fallback
/// anything ships with — `HostLink` always passes a real one — but the tests and
/// the previews need a `CopilotLink` that does not reach a Keychain, and a
/// nil-able vault would put a `?` on every call site of the one thing that must
/// not be forgotten.
@MainActor
final class MemoryCopilotVault: CopilotVault {
    private var credential: String?

    init(credential: String? = nil) { self.credential = credential }

    func copilotCredential() -> String? { credential }
    func storeCopilotCredential(_ credential: String?) { self.credential = credential }
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
     * What this device may do once the connection is open. `.none` until a
     * `welcome` or a `copilot.grant` says otherwise, which is the answer for
     * every device nobody has connected — the overwhelming majority, by design.
     */
    private(set) var grant: CopilotGrant = .none

    /// Whether the machine's capability list names `copilot`. A different
    /// question from whether it has one: one is about the host's vocabulary, the
    /// other about its implementation. **On its own it is not enough to draw
    /// anything** — see `isImplemented`.
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
     * and, before this pass, implemented almost none of it — and an earlier pass
     * over a different feature was reported as verified against exactly the
     * empty screen that produces.
     *
     * Two things set this, and both come from the code path that *is* the
     * implementation rather than from a name beside it:
     *
     *  - a `welcome` carrying a `copilot` object, which `copilotFrame()` on the
     *    desktop emits only when there is a copilot layer — including for a
     *    device it has never connected, which is the case this whole distinction
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

    /**
     * That machine holds a copilot record for this device.
     *
     * The difference between *ask somebody for a connect code* and *send the
     * credential you already have*, and a client that could not tell them apart
     * would show the wrong screen on every reconnect. It is a fact about the
     * desktop's store, so it survives a drop for the same reason
     * `isImplemented` does.
     */
    private(set) var linked = false

    /**
     * **This socket** has an open copilot connection.
     *
     * False after every reconnect until `copilot.hello` is answered, and false
     * on every `welcome` by construction. Every `copilot.*` verb below the
     * ceremony is gated on it here as well as on the desktop — not because this
     * end is a boundary, but because a frame whose only possible answer is
     * *this device is not connected to the copilot* is a frame worth not
     * sending.
     */
    private(set) var isOpen = false

    /// A connect code is on the wire and nothing has come back. Drives the
    /// spinner on the Connect screen, and is cleared by the answer, by an error,
    /// or by the socket going — never by a timer, because there is nothing here
    /// a timer would know that the socket does not.
    private(set) var isConnecting = false

    /// A `copilot.hello` is on the wire. Same rules.
    private(set) var isOpening = false

    /*
     * **There is no `isHeldClosed` any more, and this is the note explaining
     * why, so that nobody adds it back by reading the desktop's wire.**
     *
     * There used to be a *"Close the copilot here"* item in this screen's
     * overflow menu. It sent `copilot.bye`, held the connection shut across
     * reconnects so that the next `welcome` could not helpfully re-open it, and
     * had a whole `CopilotAccess` case of its own to draw. Its justification was
     * the shared device: a person putting the phone down where somebody else may
     * pick it up.
     *
     * Asad, looking at it: *"Why do we have Close the copilot here? It doesn't
     * make any sense."* And he is right about a phone specifically. A phone is
     * locked by a face; the thing that keeps somebody else out of this app is
     * the lock screen, not a menu item three taps in that a person would have to
     * remember to press. Meanwhile the item was the only way to reach a state
     * this app then had to explain — a whole screen saying "closed on this
     * phone, and nothing happened at the machine" — which is a screen that only
     * ever existed because of the button above it.
     *
     * What *is* still reachable, because each of these is a different verb and
     * each is real: **Stop this phone's copilot** ends the run that spends money
     * (`stop()`, still in the menu); **Forget this machine** on the Machines
     * screen drops the credential along with everything else; and the connection
     * itself is granted and revoked **at the machine that minted the code**,
     * which is what the connect screen has always said. `copilot.bye` remains in
     * the wire vocabulary — the browser client sends it, and `WireCodec` still
     * pins its encoding — this client simply no longer has a control that means
     * it.
     */

    /// What the copilot is, or nil when the machine has not said yet — which is
    /// also what it is after a drop. Nil draws "not known", never "stopped".
    private(set) var state: CopilotState?

    /// The conversation and the machinery, in arrival order. See `CopilotEntry`.
    private(set) var timeline: [CopilotEntry] = []

    /// The sessions the copilot started, in the desktop's own order.
    private(set) var sessions: [CopilotSessionRow] = []

    /**
     * Confirmations waiting, at the desk and on this phone's own run.
     *
     * Watch rows: the tool, the desktop's sentence, the countdown and `mine`.
     * **No arguments on any of them**, including the ones this device may
     * answer — those arrive separately, in full, as `asked`. A row with
     * `mine: false` is somebody else's question and draws no Allow button; one
     * would always be refused, and the desktop strips their arguments for the
     * same reason.
     */
    private(set) var pending: [CopilotQuestion] = []

    /**
     * Confirmations **this connection may answer**, in full.
     *
     * Separate from `pending` because the two are different acts and one of them
     * is dangerous to get wrong: a pending row says *something needs attention*,
     * these say *decide*. They carry every argument verbatim and they arrive
     * only for this device's own run.
     *
     * Bounded at the broker's own cap. More than three outstanding is a frame
     * from something this app does not understand, and a consent surface that
     * grows without limit is one people scroll rather than read.
     */
    private(set) var asked: [CopilotConsentQuestion] = []

    /**
     * Questions that closed, and where.
     *
     * Kept by id rather than dropped, because a sheet that is open when its
     * question is answered somewhere else must **say so** rather than vanish. A
     * dialog that disappears on its own teaches a person that the app does
     * things behind their back — which is the opposite of what a consent surface
     * is for. The sheet reads this, shows the sentence, and the person closes it
     * themselves.
     */
    private(set) var settlements: [String: CopilotSettlement] = [:]

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
    private let vault: CopilotVault

    init(wire: CopilotWire, vault: CopilotVault) {
        self.wire = wire
        self.vault = vault
    }

    /// A link with nowhere to keep a credential, for the previews and the tests
    /// that are about something else. Written as a convenience initialiser
    /// rather than as a default argument because a default argument is evaluated
    /// in the *caller's* isolation, and `MemoryCopilotVault` is main-actor
    /// isolated like everything else here — so the default form does not
    /// compile, which is the language telling the truth rather than getting in
    /// the way.
    convenience init(wire: CopilotWire) {
        self.init(wire: wire, vault: MemoryCopilotVault())
    }

    // MARK: - What may be drawn

    /// Whether there is a copilot screen on this machine at all. A device that
    /// has not been connected still gets the screen, because the screen is where
    /// it is told how to connect — but a machine that only *advertised* one does
    /// not, because there is nothing on it to point at. See `CopilotAccess` and
    /// `isImplemented`.
    var isAvailable: Bool { isOffered && isImplemented }

    /// Whether this phone is holding a copilot credential for this machine.
    /// Read rather than cached: the Keychain is the truth, and a boolean beside
    /// it is a second truth that can disagree after a write fails.
    var holdsCredential: Bool {
        guard let credential = vault.copilotCredential() else { return false }
        return !credential.isEmpty
    }

    /**
     * What this phone may do, as one value, so no screen has to re-derive it
     * from a capability, two connection facts and three booleans and get one of
     * the combinations wrong.
     *
     * The order of the tests is the order of the ceremony, and each answer is a
     * different sentence with a different remedy — which is the whole reason
     * this is an enum with seven cases rather than a pile of `if`s at each call
     * site. Getting one of them wrong does not draw a slightly different screen;
     * it sends somebody to look for a control on a machine that does not have
     * one.
     */
    var access: CopilotAccess {
        // Both, and neither alone. The capability without the implementation is
        // a host advertising a feature it cannot serve; the implementation
        // without the capability is a host this app has no agreed vocabulary
        // with, and sending it frames on the strength of one field would be
        // guessing. See `isImplemented`.
        guard isAvailable else { return .notOffered }
        // Before anything about grants. A device that has never redeemed a code
        // is refused *every* `copilot.*` frame, read tier included, so a screen
        // that talked about tiers here would be explaining the wrong obstacle.
        guard linked else { return .notConnected }
        /*
         * An open connection is an open connection, whatever the Keychain says.
         *
         * This test is deliberately **above** the credential one, and the order
         * cost a test failure to get right. A socket that has been through
         * `copilot.hello` — or that redeemed a code a second ago — is in, and
         * the desktop will serve it; a phone that then drew the Connect screen
         * because a Keychain write had failed would be offering to redo a
         * ceremony it had just completed, over a working connection, and the
         * code it asked for would be one nobody had minted.
         */
        if isOpen {
            if grant.canDirect { return .direct }
            if grant.canWatch { return .watch }
            return .notGranted
        }
        // Only now. Not holding the credential matters exactly when the phone
        // needs to *use* it, which is when it is not already in.
        guard holdsCredential else { return .credentialLost }
        return .connecting
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

    /// How many of those this phone can actually answer. Drawn differently from
    /// the rest, because *go and look* and *decide now* are two different
    /// errands.
    var answerableCount: Int {
        asked.filter { settlements[$0.id] == nil }.count
    }

    private var sawPending = false

    /// Whether this phone has a run of its own going. Nil `state` reads as no,
    /// which is the safe way round: it hides Stop rather than offering it
    /// against a run nobody has confirmed exists.
    var hasRun: Bool { state?.run != nil }

    // MARK: - The connection

    /**
     * A `welcome` arrived. Take what it said, and open the copilot if this
     * phone can.
     *
     * Nothing is subscribed here. `welcome.copilot.open` is **always** false —
     * the desktop says so in the type and `host-standin.ts` reproduces it — so
     * an `attach` sent from this method would be answered *this device is not
     * connected to the copilot* on every single connection. The subscription
     * hangs off `copilot.grant` with `open: true`, which is the frame that says
     * the ceremony is done.
     */
    func welcomed(capabilities: Set<String>, connection: CopilotConnection) {
        isOffered = capabilities.contains(Copilot.capability)
        // Latched rather than assigned. A machine that showed a copilot once has
        // one; a later `welcome` that omitted the field would be a host bug, and
        // taking the screen away over it is a worse answer than leaving it up
        // over frames that would refuse themselves anyway.
        if connection.stated { isImplemented = true }
        apply(connection: connection)
        openConnection()
    }

    /**
     * Send the stored credential, if there is one and it is wanted.
     *
     * Four guards, and each of them is a frame not worth sending: a host with no
     * copilot, a device with no record, a phone with no credential, and a person
     * who deliberately closed it. `Transport.send` refuses rather than queues
     * when the socket is down, so a failed send is reported rather than
     * remembered — the next `welcome` is the retry, and a welcome is exactly
     * what a recovered socket produces.
     */
    private func openConnection() {
        guard isOffered, isImplemented, linked, !isOpen else { return }
        guard let credential = vault.copilotCredential(), !credential.isEmpty else { return }
        isOpening = true
        guard wire.send(.copilotHello(credential: credential)) else {
            isOpening = false
            return
        }
    }

    /**
     * Redeem a six-digit connect code.
     *
     * **Normalised here, before it goes anywhere**, with the same function the
     * pairing screen uses. The desktop hashes the string it is given and strips
     * nothing — `device-auth.ts` does not either — so a code sent as `481 902`
     * is not a lenient match, it is a wrong code and a wasted one of five
     * guesses. That split is deliberate: one place decides what a code looks
     * like and it is the client, because the client is where somebody typed it.
     *
     * Returns whether the frame went. False is already explained on screen —
     * either by the sentence handed to `onError` or by the field's own "that is
     * not six digits" — so a caller does not have to say anything more.
     */
    @discardableResult
    func connect(code typed: String) -> Bool {
        guard isAvailable else { return false }
        guard let code = PairingCodeParser.normalise(typed) else {
            onError?("That is not a connect code. It is six digits, like 123456.")
            return false
        }
        guard !isConnecting else { return false }
        isConnecting = true
        guard wire.send(.copilotConnect(code: code)) else {
            isConnecting = false
            onError?("Not connected — the code was not sent. Try again when the machine is back.")
            return false
        }
        return true
    }

    /**
     * The desktop answered `copilot.connect`. Store the credential **first**.
     *
     * It is sent exactly once and there is no path on that machine that can show
     * it again, so anything that happens between receiving it and storing it is
     * a connection nobody can ever reopen. Writing it before the state is
     * applied is the cheapest possible ordering guarantee and it costs nothing.
     */
    func linked(credential: String, connection: CopilotConnection) {
        implemented()
        vault.storeCopilotCredential(credential)
        isConnecting = false
        isOpening = false
        // Redeeming opens the connection on this socket as well — the desktop
        // says so and it is right: the device has just proved it holds a code
        // minted at that machine seconds ago, which is a stronger claim than the
        // credential it is being given. So this frame can carry `open: true` and
        // the subscription starts from it.
        apply(connection: connection)
    }

    /**
     * Ask for the stream, and for the two things it does not replay.
     *
     * `copilot.attach` is answered with the state and, when there is a run, the
     * conversation. `copilot.sessions` and `copilot.pending` are separate
     * answers, so they are asked for separately — three frames on a connection,
     * once, rather than a timer.
     */
    private func subscribe() {
        guard isOpen, grant.canWatch else { return }
        wire.send(.copilotAttach)
        wire.send(.copilotSessions)
        wire.send(.copilotPending)
    }

    /// Pull-to-refresh, and nothing else. Everything here is pushed while the
    /// connection is open, so a timer would be this app polling a question the
    /// desktop is already answering — his own standing rule about events over
    /// polling.
    func refresh() {
        guard isOpen, grant.canWatch else { return }
        wire.send(.copilotState)
        wire.send(.copilotSessions)
        wire.send(.copilotPending)
    }

    /**
     * The socket went. See the header: history stays, claims about now go.
     *
     * The copilot connection goes with it, and that is not a tidy-up either —
     * the desktop drops `copilotOpen` when the socket closes, so a phone that
     * kept believing it was in would send its next frame into a refusal. The
     * `copilot.hello` on the next welcome is what puts it back.
     */
    func connectionLost() {
        state = nil
        pending = []
        sawPending = false
        isLoadingLog = false
        closeLocally()
        isConnecting = false
        isOpening = false
    }

    /// Everything that belongs to an open connection rather than to the phone.
    /// Shared by `connectionLost()` and `forget()` so the two cannot drift about
    /// what a closed connection means on screen.
    private func closeLocally() {
        isOpen = false
        isOpening = false
        // The questions especially. A confirmation this phone can no longer
        // answer must not be left on screen with a live countdown and an Allow
        // button under it — the desktop refuses everything this device raised
        // the moment its last connection goes, with `caller-gone`, so the button
        // would be offering something that has already been decided.
        asked = []
        settlements = [:]
    }

    /// The machine is being torn down — unpaired, or re-paired. Everything goes,
    /// including the connection and the credential: a re-pair mints a **new**
    /// device id, so the desktop drops the copilot record with the old one and
    /// the secret this phone is holding opens nothing.
    func forget() {
        grant = .none
        isOffered = false
        // And what this machine turned out to be. Unlike `connectionLost`, which
        // keeps it because a build does not change while a socket blinks, an
        // unpair means the next machine behind this object may be a different
        // one entirely.
        isImplemented = false
        linked = false
        vault.storeCopilotCredential(nil)
        state = nil
        timeline = []
        sessions = []
        pending = []
        sawPending = false
        log = []
        logHasMore = false
        isLoadingLog = false
        chatRun = nil
        closeLocally()
        isConnecting = false
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
     * Separate from `apply(connection:)` only so that arriving as a *frame*
     * confirms the machine has a copilot, while the same object arriving inside
     * a `welcome` does not — there, the field's presence is what confirms it,
     * and `welcome` carries it whether or not this device has ever connected.
     */
    func apply(pushed connection: CopilotConnection) {
        implemented()
        apply(connection: connection)
    }

    /**
     * The connection changed, from a `welcome`, a `copilot.linked` or a pushed
     * `copilot.grant`.
     *
     * Four things can move and each has a consequence:
     *
     *  - **`linked` went false** — somebody disconnected this device at the
     *    machine. The credential this phone holds now opens nothing, so it is
     *    dropped rather than kept: a secret in a Keychain with no record behind
     *    it is a secret nobody can revoke because nobody knows it is there.
     *  - **`open` went true** — the ceremony is done, so subscribe. This is the
     *    only place that happens.
     *  - **`open` went false** — the desktop closed it, or this is a `welcome`.
     *    Anything that needed it goes with it.
     *  - **the grant narrowed past `read`** — the screen empties. Leaving it in
     *    memory would mean a phone re-granted a minute later came back showing a
     *    conversation and tool rows from before, with nothing having re-checked
     *    whether any of it is still true — and, worse, a person believing their
     *    revoke had not worked.
     *
     * Nothing is sent on a narrowing. `copilot.detach` needs `read` like every
     * other frame on this surface, so a phone that has just lost it would be
     * answered with an `unauthorized` banner for trying to be polite.
     */
    func apply(connection: CopilotConnection) {
        let hadWatch = grant.canWatch
        let wasOpen = isOpen
        grant = connection.grant
        linked = connection.linked
        isOpen = connection.open
        if connection.open { isOpening = false }

        if !linked {
            vault.storeCopilotCredential(nil)
        }
        if !connection.open, wasOpen { closeLocally() }
        if connection.open, !wasOpen { subscribe() }
        if !grant.canWatch, hadWatch { clearWatched() }
    }

    /// What a device that may no longer watch must not still be showing.
    private func clearWatched() {
        state = nil
        timeline = []
        sessions = []
        pending = []
        sawPending = false
        asked = []
        settlements = [:]
        log = []
        logHasMore = false
        chatRun = nil
    }

    /**
     * An `error` frame arrived on this machine's socket while a ceremony was in
     * flight.
     *
     * Only the flags are touched, and the sentence is left to the one error
     * surface `HostLink` already owns — two banners that can disagree about
     * which is showing is a defect this app has had once. What this fixes is the
     * spinner: a wrong connect code comes back as a plain `error`, and a Connect
     * screen that went on saying *checking…* over it would be a screen that
     * looks like it is still working.
     *
     * Any error clears them, not only a copilot one, because the wire's error
     * frame carries no correlation id and inventing one here would be guessing.
     * The cost of being wrong is a spinner that stops early on a frame that was
     * about something else, which resolves itself on the next answer.
     */
    func wireErrored() {
        isConnecting = false
        isOpening = false
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
        // A question that is no longer pending is no longer answerable, whatever
        // this phone was told a moment ago. The desktop sends the list after
        // every answer for exactly this reason — *a client whose answer was too
        // late has to see the question go rather than be left holding a dialog*
        // — and a `copilot.settled` may never arrive at all for a device that
        // reconnected in between.
        let live = Set(questions.map(\.id))
        asked.removeAll { !live.contains($0.id) && settlements[$0.id] == nil }
    }

    /**
     * A confirmation this connection may answer.
     *
     * Merged by id rather than appended, because a re-`attach` on a reconnect
     * could in principle bring one back, and a consent sheet drawn twice for one
     * question is two Allow buttons for one decision.
     *
     * Bounded at three, the broker's own cap. Beyond that the newest are kept:
     * an unbounded list is a surface people scroll rather than read, and of the
     * ones to drop the oldest is closest to expiring anyway.
     */
    func apply(ask question: CopilotConsentQuestion) {
        implemented()
        settlements.removeValue(forKey: question.id)
        if let at = asked.firstIndex(where: { $0.id == question.id }) {
            asked[at] = question
        } else {
            asked.append(question)
        }
        if asked.count > 3 { asked.removeFirst(asked.count - 3) }
    }

    /**
     * A question closed, and where.
     *
     * The row is **kept**, not dropped, and that is the whole point of the frame
     * carrying `by`: a sheet that is open when its question is answered at the
     * Mac has to say where it went. `CopilotView` reads `settlement(for:)` and
     * shows the sentence; the person closes the sheet themselves, and closing it
     * is what forgets it.
     */
    func apply(settled: CopilotSettlement) {
        implemented()
        guard asked.contains(where: { $0.id == settled.id }) || pending.contains(where: { $0.id == settled.id })
        else { return }
        settlements[settled.id] = settled
        pending.removeAll { $0.id == settled.id }
    }

    /// Where a question went, for a sheet that is still open over it.
    func settlement(for id: String) -> CopilotSettlement? { settlements[id] }

    /// The person closed the sheet on a settled question. Forgetting it here
    /// rather than on arrival is what let the sheet say where it went.
    func dismissSettled(_ id: String) {
        settlements.removeValue(forKey: id)
        asked.removeAll { $0.id == id }
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
        guard isOpen, grant.canWatch, !isLoadingLog else { return }
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
        guard isOpen, grant.canWatch, !isLoadingLog, logHasMore, let oldest = log.first else { return }
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
     * Returns whether the frame went, so the composer can keep the text when it
     * did not: a message that vanishes out of a text field because a socket was
     * down is a message somebody has to retype, and they will not know they have
     * to until they notice the answer never came.
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

    // MARK: - Outbound, alter tier

    /**
     * Answer a confirmation. **Yes and no travel by the same road.**
     *
     * One method for both, with `approved` as an argument rather than an
     * `allow()` and a `refuse()`, because §4.3 requires refusing to be at least
     * as easy as accepting and the cheapest way to get that wrong is to give one
     * of them a shorter path than the other. Every guard below applies to both
     * answers identically.
     *
     * Guarded on `alter` here as well as by the buttons being absent, for the
     * reason every other verb on this object is: the absent button is for a
     * phone whose grant never allowed this, and this is for a grant taken away
     * between the sheet being drawn and the thumb landing.
     *
     * The **ownership** rule is not checked here and must not be. *A question
     * may only be answered by the surface that owns the run that raised it* is
     * enforced in `ConsentBroker.respond`, with the question, where a second
     * transport cannot arrive without it — and a device that tries anyway gets
     * the same answer a settled question gets, so probing learns nothing. What
     * this end does is not *draw* an Allow on a row it was told is not its own.
     */
    @discardableResult
    func answer(_ id: String, approved: Bool) -> Bool {
        guard grant.canAnswer else {
            onError?("This phone is not allowed to answer the copilot's confirmations. That is a "
                     + "switch on the machine, in Settings, on this phone's own card.")
            return false
        }
        guard wire.send(.copilotAnswer(id: id, approved: approved)) else {
            onError?(approved
                     ? "Not connected — that was not allowed. It is still waiting at the machine."
                     : "Not connected — that was not refused. It is still waiting at the machine.")
            return false
        }
        return true
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
 * The seven things this phone can be, with respect to one machine's copilot.
 *
 * One type rather than a capability flag and five booleans at every call site,
 * because there are seven states and the screens have to draw seven different
 * things — and the failure mode of re-deriving it is drawing the *third* answer
 * for the *fourth* state, which is a phone hiding a feature that a person could
 * have turned on in ten seconds if anything had told them it existed.
 *
 * They are ordered as the ceremony runs: no copilot, no connection, no
 * credential, opening, open-and-empty, watching, directing. Reading the list top
 * to bottom is reading what has to be true before the next line is reachable.
 *
 * There were eight. `closed` — *shut on this phone on purpose, one tap to
 * re-open* — went with the menu item that was the only way to reach it; the
 * removal and the sentence behind it are recorded on `CopilotLink`, where the
 * `isHeldClosed` flag used to be.
 *
 * `CaseIterable` so `CopilotPillTests` can walk all of them rather than the two
 * that are interesting today. A state added later and not thought about is a
 * fourth pill appearing or not appearing for it by accident, which is the whole
 * class of failure this review is about.
 */
enum CopilotAccess: Equatable, CaseIterable {
    /// The machine does not speak `copilot.*`. Nothing is drawn — there is no
    /// switch on that machine to point at, so a screen explaining where to find
    /// one would be a screen sending somebody to look for a control that is not
    /// there.
    case notOffered
    /// The machine has a copilot and this device has never been connected to it.
    /// **Drawn, and explained, with a code field.** This is the state every
    /// paired device starts in and the one a person can fix in thirty seconds:
    /// they mint a code at the machine and type it here.
    case notConnected
    /// The machine holds a record for this device and this phone does not hold
    /// the credential — restored from a backup, or a Keychain item that would
    /// not read. The same code field, and a different sentence: the credential
    /// is sent exactly once and cannot be asked for again, so the remedy is a
    /// **new** code rather than a retry.
    case credentialLost
    /// The credential is on its way, or the socket is down and it cannot be. A
    /// state with nothing to do in it, drawn as such rather than as an empty
    /// screen that looks like a broken one.
    case connecting
    /// Connected, and granted nothing. A real state — unticking every box leaves
    /// a working credential — and it is drawn rather than hidden, because the
    /// remedy is three checkboxes on the machine.
    case notGranted
    /// Watching: what it is doing, what it started, what it was refused. No
    /// composer, no Start — `copilot.say` is `act`, because talking to the
    /// copilot spends money and causes tool calls.
    case watch
    /// Watching, and able to start a run and talk to it. Whether it may also
    /// answer confirmations is `grant.alter`, which is a fourth thing and is
    /// read where the buttons are drawn rather than folded in here: a phone can
    /// hold `act` without `alter`, and that is the ordinary careful setup.
    case direct

    /**
     * **Whether the copilot is connected, in the sense a person means it** —
     * and therefore whether this machine gets a fourth pill in the tab bar.
     *
     * Asad: *"if the copilot is not connecting, this icon should not be inside
     * the pill — then it will be three icon pill. Otherwise if the copilot is
     * connected, then four icon pill, automatically, like that way."* So the bar
     * asks this question of the current machine, and `DeckModel.showsCopilotTab`
     * is where the asking happens.
     *
     * Written as a `switch` over every case rather than as `self != .notConnected
     * && …`, so that a state added later cannot inherit an answer by accident:
     * the compiler makes somebody decide which side of the line it falls on, and
     * "which side of the line" here is a whole pill appearing or not appearing.
     *
     * **Two of the answers are worth arguing about.**
     *
     * `connecting` counts as **connected**, and that is the important one. It
     * means *this phone holds a working credential and the socket is not up
     * right now* — a machine asleep, a phone on a train, a relay reconnecting.
     * The alternative would be a tab bar that adds and removes a pill every time
     * the network blinks, sliding the other three pills sideways under a thumb
     * that had learned where they are. The pill follows **the authorisation, not
     * the socket**, which is also how the Sessions and Localhost tabs behave when
     * a machine goes away: they stay, and they say so.
     *
     * `notGranted` also counts as connected, because it *is*: the credential
     * works and the connection is open, and every box beside it is unticked. The
     * screen behind the pill says exactly that and names the switch to tick.
     * Hiding the tab would hide the only sentence that explains the situation.
     *
     * And `credentialLost` counts as **not** connected, even though the machine
     * still holds a record for this phone, because the remedy is the same one
     * `notConnected` has — a new six-digit code, minted at the machine — and
     * that lives in Settings now.
     */
    var isConnected: Bool {
        switch self {
        case .notOffered, .notConnected, .credentialLost:
            return false
        case .connecting, .notGranted, .watch, .direct:
            return true
        }
    }
}
