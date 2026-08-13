package dev.terminaldeck.android.transport

import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.ServerMessage
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

/**
 * The seam.
 *
 * Everything above this interface — the session list, the terminal, the emulator — is written
 * against these types and never against a socket, a relay or a key. Below it there is one
 * implementation, [WebSocketDeckTransport], and test doubles.
 *
 * The interface is the protocol plus the honest connection state, and nothing else. It does not
 * expose a URL, a token or a handshake, because none of those are decisions the UI gets to make.
 */
interface DeckTransport {

    /** Where the connection actually is. Never optimistic — see [TransportState]. */
    val state: StateFlow<TransportState>

    /**
     * Frames from the desktop, already narrowed by
     * [dev.terminaldeck.android.protocol.ServerFrames.parse].
     *
     * Hot: frames that arrive while nobody is collecting are dropped, which is correct for output
     * because the desktop replays scrollback on attach.
     */
    val incoming: Flow<ServerMessage>

    /** Open the connection and keep it open, retrying on its own schedule. Idempotent. */
    fun connect()

    /**
     * Try again now, because something changed outside: the network came back, or the app returned
     * to the foreground.
     *
     * Distinct from [connect] in what it does to the schedule — it resets the backoff, on the
     * grounds that the pending delay is describing a condition that has already ended. Refused in
     * the states where retrying is actively harmful.
     */
    fun resume()

    /** Stop. The desktop's sessions keep running; this is a window closing. */
    fun disconnect()

    /**
     * Send one frame. Returns false when it did not go.
     *
     * **Never queues.** A keystroke buffered while the socket is down arrives after the reconnect,
     * out of context, at a prompt that has moved on — and the user watched it echo and believed it
     * landed. Refusing is what lets the caller tell the truth instead.
     */
    fun send(message: ClientMessage): Boolean
}

/**
 * Where the connection is, in the only vocabulary the UI is allowed to draw.
 *
 * The states are separate rather than one `Failed(recoverable)` because they call for different
 * words and different behaviour: [Pending] is a person walking to a Mac, [Waiting] is a network,
 * [Rejected] is a credential that will never work again, [Incompatible] is a version. Collapsing
 * them produced a banner that told someone to check their wifi while the real answer was a button
 * on the desk in front of them.
 *
 * There is exactly one state that means the terminal is live, and it is [Online].
 */
sealed interface TransportState {

    /** No pairing on this device yet. The app shows the pair screen, not an error. */
    data object Unpaired : TransportState

    /** Deliberately stopped. */
    data object Offline : TransportState

    /** A socket is being opened, or the handshake has not finished. Not connected. */
    data object Connecting : TransportState

    /**
     * The desktop said `welcome` and admitted this device. The only live state.
     *
     * @param deviceName what the **Mac** calls this phone. `welcome.deviceName` in `protocol.ts` is
     *   the name out of the desktop's trust store — the device's, not the machine's. Version 1
     *   carries no name for the Mac at all, so a client that printed this next to "connected to"
     *   would be showing the user their own phone's name and calling it their computer. Which
     *   machine this is gets said with the host id and the key fingerprint instead, both of which
     *   are actually about the Mac.
     */
    data class Online(val deviceName: String) : TransportState

    /** Paired, but a human at the Mac has not approved this device yet. Reconnects are the poll. */
    data class Pending(val detail: String, val retryAt: Long? = null) : TransportState

    /** A retry is scheduled. [retryAt] is epoch milliseconds. */
    data class Waiting(val detail: String, val retryAt: Long?, val attempts: Int) : TransportState

    /** The credential was refused. Only pairing again fixes this, so retrying stops. */
    data class Rejected(val detail: String) : TransportState

    /** The two ends do not speak the same protocol version. Retrying stops. */
    data class Incompatible(val detail: String) : TransportState
}

/** The one predicate the UI may use to decide whether a terminal is live. */
val TransportState.isOnline: Boolean get() = this is TransportState.Online

/** A sentence for the banner. Always present, always true. */
val TransportState.detail: String
    get() = when (this) {
        is TransportState.Unpaired -> "Not paired with a Mac yet."
        is TransportState.Offline -> "Disconnected."
        is TransportState.Connecting -> "Connecting…"
        is TransportState.Online -> "Connected as $deviceName"
        is TransportState.Pending -> detail
        is TransportState.Waiting -> detail
        is TransportState.Rejected -> detail
        is TransportState.Incompatible -> detail
    }
