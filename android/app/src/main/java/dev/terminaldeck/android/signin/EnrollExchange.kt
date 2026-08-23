package dev.terminaldeck.android.signin

import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.DeviceDescriptor
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ProtocolErrorCode
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * The client half of `enroll`: four frames in a fixed order, and the two ways it can end.
 *
 * A port of `pwa/src/signin.ts` and of iOS's `SignInLink.swift`, and deliberately the same shape as
 * both — it takes a `send`, it is fed decoded frames, and it settles once. It does not open the
 * socket and does not know how the sealed channel to a first-contact server was established. That
 * is [ServerSignIn]'s problem, and keeping the sequence here, pure and driven, is what lets it be
 * tested against real frames with no socket, no relay and no Android.
 *
 * ## The sequence, which is not negotiable
 *
 * ```
 *   → enroll    protocol, this device, the SSH login
 *   ← enrolled  deviceId, deviceName, credential
 *   → hello     the credential that just arrived, on the SAME socket
 *   ← welcome   admitted; the server's sessions and capabilities come with it
 * ```
 *
 * The follow-up hello is not a formality and is not something a caller may skip in favour of
 * reconnecting later. It is the proof: a credential this phone has stored but never spent is a
 * pairing that *looks* finished on screen and fails the next time the app is opened, which is
 * exactly the class of lie this client is written not to tell. Nothing here reports success until a
 * welcome has come back through it.
 *
 * ## What is dropped rather than acted on
 *
 * Every frame that is not the one this stage is waiting for. Until the welcome lands the socket is
 * **unauthenticated** — the server says so itself, in `server.ts`: "Not authenticated here,
 * deliberately" — so a `sessions` or an `output` arriving mid-sign-in is either a server doing
 * something it should not or something that is not the server. Acting on one would be acting on an
 * unauthenticated socket, so it is dropped and the exchange keeps waiting.
 */
class EnrollExchange(
    private val send: (ClientMessage) -> Unit,
    private val onOutcome: (Outcome) -> Unit,
) {

    /** What a sign-in was, once it is over. */
    sealed interface Outcome {

        /**
         * Signed in, and the credential has already been spent once on the same socket.
         *
         * [welcome] is the one the follow-up hello earned, so the caller can read the server's own
         * facts out of it rather than reconnecting to learn them.
         */
        data class SignedIn(
            /** `<deviceId>.<secret>`. Store it the way a paired machine's credential is stored. */
            val credential: String,
            val deviceId: String,
            /** What the **server** decided to call this phone. Not what this phone calls itself. */
            val deviceName: String,
            val welcome: ServerMessage.Welcome,
        ) : Outcome

        /**
         * The server said no, in its own words where it gave any.
         *
         * A refused login and a rate-limited one collapse to one sentence over there, on purpose,
         * so that the wire cannot be used to tell a bad guess from a lockout. Nothing here tries to
         * take them apart again.
         */
        data class Refused(val sentence: String) : Outcome
    }

    /** What a sign-in needs from the person and from the phone. */
    data class Input(
        val username: String,
        /** A password or a private-key PEM. Held for one exchange and referenced nowhere after. */
        val secret: String,
        val method: EnrollMethod,
        val device: DeviceDescriptor,
    )

    private enum class Stage { Idle, Enrolling, SayingHello, Done }

    private var stage = Stage.Idle
    private var device: DeviceDescriptor? = null
    private var credential = ""
    private var deviceId = ""
    private var deviceName = ""

    /** The frame a sign-in opens with. Exported so a caller holding the socket can send it itself. */
    fun opening(input: Input): ClientMessage = ClientMessage.Enroll(
        protocol = Protocol.VERSION,
        device = input.device,
        username = input.username,
        secret = input.secret,
        method = input.method,
        // The same list `hello` claims, and here for the same reason it is there: the server may
        // need to know what this phone can answer before the follow-up hello lands. It grants
        // nothing — see [Capability.CLAIMED].
        capabilities = Capability.CLAIMED,
    )

    fun start(input: Input) {
        check(stage == Stage.Idle) { "this sign-in has already started" }
        stage = Stage.Enrolling
        device = input.device
        send(opening(input))
    }

    fun receive(message: ServerMessage) {
        if (stage == Stage.Done || stage == Stage.Idle) return

        // A refusal at either step ends it. Before a welcome, an `error` is always about this
        // device — unlike in a live session, where the server spends the same `unauthorized` code
        // on "attach before typing into that".
        if (message is ServerMessage.Error) {
            finish(Outcome.Refused(sentenceFor(message)))
            return
        }

        if (stage == Stage.Enrolling && message is ServerMessage.Enrolled) {
            credential = message.credential
            deviceId = message.deviceId
            deviceName = message.deviceName
            stage = Stage.SayingHello
            // An ordinary hello, on the same socket. The server does not special-case it: the
            // device row is already approved and already bound to this connection's key, so it
            // comes in through the door every reconnect uses.
            send(
                ClientMessage.Hello(
                    protocol = Protocol.VERSION,
                    token = message.credential,
                    // Set by `start` before any frame could arrive; the fallback is defensive and
                    // never taken.
                    device = device ?: DeviceDescriptor(name = message.deviceName, platform = PLATFORM),
                    capabilities = Capability.CLAIMED,
                )
            )
            return
        }

        if (stage == Stage.SayingHello && message is ServerMessage.Welcome) {
            finish(
                Outcome.SignedIn(
                    credential = credential,
                    deviceId = deviceId,
                    deviceName = deviceName,
                    welcome = message,
                )
            )
        }
        // Everything else before the welcome is dropped. See the header.
    }

    /**
     * The socket went before the exchange did.
     *
     * Not a state this can reach on its own — a socket is somebody else's — but it is the most
     * common failure in the field, and an exchange that could not be told about it would leave the
     * screen on a spinner for as long as the app was open.
     */
    fun connectionLost(sentence: String) {
        if (stage == Stage.Done || stage == Stage.Idle) return
        finish(Outcome.Refused(sentence))
    }

    private fun finish(outcome: Outcome) {
        stage = Stage.Done
        onOutcome(outcome)
    }

    /**
     * What to say about a refusal, and the one code that is not about the login at all.
     *
     * `bad-message` from a server means its parser has never heard of `enroll` — it hits
     * `parseClientMessage`'s default case, refuses and closes. That is a server too old for this
     * feature, and reporting it as a bad password would send somebody to change a password that was
     * never wrong. Every other code is the server explaining itself, and its sentence is used as
     * written: `unauthorized` for a refused login, a rate-limited address or a private key that
     * could not be read, and `unavailable` for the four different ways a host that *does* serve
     * sign-in can fail to complete one — its own sshd not answering the loopback probe on the port
     * it dialled, the probe timing out, no room left in the device list, a device row that would
     * not write — plus the one host that serves none at all. Using the sentence as written is what
     * makes that distinction reach anybody: until 2026-08-23 the host sent one sentence for all of
     * them, and a server whose sshd was on port 2222 told its owner for an evening that it had no
     * sign-in feature.
     */
    private fun sentenceFor(message: ServerMessage.Error): String = when (message.code) {
        ProtocolErrorCode.BadMessage -> TOO_OLD
        else -> message.message.ifEmpty { REFUSED }
    }

    companion object {
        /** What this client calls itself. `WebSocketDeckTransport.PLATFORM`; display only. */
        private const val PLATFORM = "android"

        const val TOO_OLD =
            "That server is too old to accept a sign-in from a phone. Update Terminal Deck on it, " +
                "or pair it with a code from a desktop."

        /** Only ever used for a refusal that arrived with no sentence on it, which should not happen. */
        const val REFUSED = "That sign-in was refused."
    }
}
