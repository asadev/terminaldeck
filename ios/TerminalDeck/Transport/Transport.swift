/**
 * THE SEAM.
 *
 * Everything above this line — the session list, the terminal, the model — talks
 * to a `Transport` and nothing else. Below it is `LiveTransport`, which drives a
 * `Carrier` (a sealed relay socket, or a direct tailnet socket) and speaks the
 * JSON protocol through it.
 *
 * ## Why the state is not a boolean
 *
 * There is exactly one thing a phone terminal must never do, and it is to look
 * connected when it is not. It gets used to check on something long-running and
 * to stop it when it goes wrong, and a screen of stale output under a blinking
 * cursor is worse than no client at all, because a person will type Ctrl+C into
 * it and walk away believing the job stopped. So every state carries a sentence
 * that is true, `send` refuses rather than buffers when the socket is down, and
 * the terminal is cleared on re-attach instead of leaving old pixels under a new
 * connection.
 *
 * ## Pairing is not in here
 *
 * A transport is handed a credential by a `CredentialStore` and never learns
 * where it came from. What it does own is the moment a credential stops being
 * good: `.needsPairing` is how the pairing screen finds out, because the phone
 * cannot tell the difference between "not approved yet" and "revoked" by looking
 * at a token — only the Mac's answer says which, and only this layer sees it.
 */

import Foundation

enum ConnectionPhase: String, Equatable {
    case offline
    case connecting
    case online
    /// Paired, but a human at the Mac has not approved this device yet. Every
    /// reconnect from here is a poll for that approval.
    case pending
    /// A retry is scheduled. `retryAt` says when.
    case waiting
    /// The credential was refused for good. Only re-pairing fixes this.
    case rejected
    /// The two ends do not speak the same protocol version. Retrying stops.
    case incompatible
}

struct ConnectionState: Equatable {
    var phase: ConnectionPhase
    /// A sentence for the banner. Always present, always true.
    var detail: String
    /// When the next attempt is due, if one is scheduled.
    var retryAt: Date?
    /// Consecutive failed attempts. Shown once it stops looking like a blip.
    var attempts: Int

    /**
     * This device is paired and has not been approved by a human yet.
     *
     * Separate from `phase == .pending`, and the separation is the point.
     * `.pending` means *this attempt reached the Mac and the Mac said "not
     * yet"*. This flag stays true across the attempts in between, including the
     * ones that never reach the Mac at all — which is what lets the app keep
     * showing the approval screen while still saying, in `detail`, that the last
     * attempt failed.
     *
     * Collapsing the two is how a connection failure comes to be rendered as a
     * successful pairing awaiting approval, which is a lie that hides total
     * handshake failure behind a screen that looks like the normal path.
     */
    var awaitingApproval: Bool = false

    /**
     * The far end has been heard from since this side last had cause to doubt it.
     *
     * `.online` means *a `welcome` came through the sealed channel*, which is a
     * fact about the past. This is the fact about the present, and the two come
     * apart in exactly one situation — the one that matters most on a phone.
     *
     * An app that is suspended in a pocket does not run its heartbeat, and iOS
     * does not tell it that a socket died while it was away. So it comes to the
     * foreground still holding `.online` from before the suspension, against a
     * TCP connection a carrier NAT reclaimed twenty minutes ago. Every check that
     * would notice is a timer that has not fired yet: the badge said **Connected**
     * for as long as it took the next ping to go out and its grace to expire.
     *
     * That was observed, not theorised — the relay reported no guest attached for
     * a sustained forty seconds while the app was showing Connected, which is the
     * window this closes. `resume()` clears this and probes immediately; anything
     * arriving through the sealed channel sets it again.
     *
     * It is deliberately *not* folded into `isLive`. The carrier and the session
     * are still there and probably fine; what is not known is whether the far end
     * is still listening, and the honest thing to do about not knowing is to say
     * so — not to tear down a working terminal on a guess.
     */
    var verified: Bool = true

    static let offline = ConnectionState(phase: .offline, detail: "Not connected.", retryAt: nil, attempts: 0)

    /// Whether the terminal may show a live cursor and accept keystrokes.
    var isLive: Bool { phase == .online }

    /// Whether the app is still trying. Drives the spinner, and nothing else —
    /// a spinner next to a state that has given up is its own kind of lie.
    var isTrying: Bool {
        phase == .connecting || phase == .waiting || phase == .pending
    }

    /// Three words at most, for the status pill in the navigation bar.
    var label: String {
        switch phase {
        case .offline: return "Offline"
        case .connecting: return "Connecting"
        // Never the word Connected on an unverified channel. The pill is the one
        // thing on this screen a person reads before deciding whether to trust
        // what is under it, and "Checking" is the truth while a probe is out.
        case .online: return verified ? "Connected" : "Checking"
        case .pending: return "Waiting for approval"
        case .waiting: return "Reconnecting"
        case .rejected: return "Not paired"
        case .incompatible: return "Version mismatch"
        }
    }
}

enum TransportEvent {
    case state(ConnectionState)
    case message(ServerMessage, activity: [String: Double])
    /// A durable credential arrived and has already been persisted. The pairing
    /// token that bought it is now spent and will not work a second time.
    case credential(StoredCredential)
    /**
     * This credential will never work again — it was refused rather than held
     * pending, or the pairing code it came from was not accepted.
     *
     * The store has already been cleared. The app's job is to show the pairing
     * screen with this sentence on it, rather than retrying against a Mac that
     * counts failed attempts and locks the device out.
     */
    case needsPairing(String)
}

@MainActor
protocol Transport: AnyObject {
    var state: ConnectionState { get }
    /// What the far end says it can do beyond protocol v1. Empty against any
    /// desktop shipping today; see `DeckModel.canCreateSessions`.
    var capabilities: Set<String> { get }
    /// Set before `start()`. Called on the main actor, always.
    var onEvent: ((TransportEvent) -> Void)? { get set }

    func start()
    func stop()
    /// Try again now — the OS says the network is back, or the app came
    /// forward. Ignored in the states where retrying cannot help.
    func resume()

    /**
     * Send, or say no.
     *
     * Never queues. A keystroke buffered while the socket is down arrives after
     * the reconnect, out of context, at a prompt that has moved on — and the
     * user saw it echo locally and believed it landed. Refusing lets the caller
     * tell the truth instead.
     */
    @discardableResult
    func send(_ message: ClientMessage) -> Bool
}

/**
 * What to tell the user about a close.
 *
 * `beforeReady` matters more than the code: the same close means different
 * things before and after the far end has authenticated. A carrier that knows
 * why it closed says so itself — the relay carrier knows that a close before the
 * handshake means the Mac is not attached to the relay — and this only fills in
 * the cases where all there is to go on is a number.
 */
func closeReason(_ close: CarrierClose, greeted: Bool) -> String {
    if let detail = close.detail { return detail }
    switch close.code {
    case WireClose.normal, WireClose.goingAway:
        return greeted
            ? "The desktop closed the connection."
            : "The desktop closed the connection before this device was let in."
    case WireClose.protocolError, WireClose.unsupportedData:
        return "The desktop rejected a message from this client."
    case WireClose.policyViolation:
        return "The desktop refused this device."
    case WireClose.messageTooBig:
        return "A message was too large for the desktop to accept."
    case WireClose.tryAgainLater:
        return "The desktop asked this client to try again later."
    case WireClose.internalError:
        return "The desktop hit an internal error."
    default:
        return greeted ? "Connection lost." : "Could not reach the desktop."
    }
}
