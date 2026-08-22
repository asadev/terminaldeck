package dev.terminaldeck.android.signin

import android.util.Log
import dev.terminaldeck.android.crypto.HandshakeInitiator
import dev.terminaldeck.android.crypto.SealedChannel
import dev.terminaldeck.android.crypto.SealedException
import dev.terminaldeck.android.crypto.StaticKeyPair
import dev.terminaldeck.android.protocol.ClientFrames
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.DeviceDescriptor
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.RelayWire
import dev.terminaldeck.android.protocol.ServerFrames
import dev.terminaldeck.android.transport.toHttpish
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeoutOrNull
import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit

/**
 * The one-line install for a bare server, from `HEADLESS.md`.
 *
 * A phone cannot SSH, so it cannot install a host itself the way the desktop clients can — it shows
 * this command for a person to run on the machine, and then sign in. The browser client shows the
 * same line for the same reason; see `INSTALL_COMMAND` in `pwa/src/signin.ts`.
 *
 * Copied rather than derived: the domain is the marketing site's, not the app's `BRAND`, and
 * `HEADLESS.md` is the source that ships it.
 */
const val INSTALL_COMMAND = "curl -fsSL https://terminaldeck.dev/install.sh | sh"

/**
 * One sign-in, on one socket of its own.
 *
 * ## Why this is not the transport
 *
 * [dev.terminaldeck.android.transport.WebSocketDeckTransport] is a socket that is *kept*: it
 * reconnects on a backoff, it survives a phone going into a pocket, and it exists for a machine
 * this app already has a credential for. A sign-in is the opposite of all three. It happens once,
 * it must not be retried on its own — a repeated login is what a rate limiter is for, and spending
 * somebody's attempts without being asked is how a person gets locked out of their own server — and
 * at the moment it runs there is no credential for the transport to hold.
 *
 * So a sign-in opens its own short socket, finishes or fails, and hangs up. What it leaves behind is
 * an ordinary credential in the vault, and from then on the ordinary transport does what it always
 * did. Nothing in the connected path is special-cased for a server that arrived this way, which is
 * the point: a signed-in server is a paired machine, and every screen already knows what one of
 * those is.
 *
 * ## Why the durable device key, and not a throwaway
 *
 * [dev.terminaldeck.android.pairing.Rendezvous] dials with a throwaway pair, because nothing at the
 * far end of a code lookup stores who dialled. Here the opposite is true and it is load bearing:
 * `enrollDevice` on the server writes the **handshake's public key** into the device row it mints,
 * and `knowsDeviceKey` is what admits this phone on every connection afterwards. Signing in with a
 * throwaway would mint a device bound to a key this phone then throws away — a credential that
 * works exactly once, on this socket, and is refused by the same server a second later with nothing
 * on either side to explain it.
 *
 * ## The one door a server has to leave open, and what it looks like when it has not
 *
 * A server refuses the Noise handshake outright from a key it does not know, before any reply
 * exists — `isKnownDevice` in `server.ts`. A phone signing in for the first time is by definition
 * such a key, so this works only because a host that serves sign-in lets an unknown key through the
 * handshake so it can send `enroll`. A host that does not serve sign-in therefore does not refuse
 * with a sentence: it says **nothing at all** and the channel closes. That silence is the single
 * most likely failure here, and [Result.Unreachable] is worded for it rather than for a network.
 */
object ServerSignIn {

    sealed interface Result {

        data class SignedIn(
            val credential: String,
            val deviceId: String,
            val deviceName: String,
            /** The server's own capability list and sessions, from the welcome the hello earned. */
            val welcome: dev.terminaldeck.android.protocol.ServerMessage.Welcome,
        ) : Result

        /** The server answered and said no. Its sentence, not one made up here. */
        data class Refused(val sentence: String) : Result

        /** Nothing usable came back. The address, the network, or a server not serving sign-in. */
        data class Unreachable(val sentence: String) : Result
    }

    /**
     * How long a sign-in may take before it is called a failure.
     *
     * Longer than a pairing lookup, and deliberately: the server runs a real SSH probe against its
     * own sshd and then a memory-hard hash to mint the credential, and `server.ts` re-arms its own
     * no-hello timer around both because they outlast an ordinary greeting. A ceiling below the
     * server's own would report a failure for work that then succeeds, leaving a device row minted
     * on a server the phone believes it never reached.
     */
    const val TIMEOUT_MS = 45_000L

    /**
     * Everything one sign-in needs, in one value.
     *
     * A record rather than six parameters because it is also the seam: `DeckViewModel` takes a
     * `suspend (Request) -> Result` so a test can put a fixture in this object's place, and a
     * six-argument function type at that boundary is one nobody can read at the call site.
     *
     * [secret] is a password or a private-key PEM. It lives for the length of one call: it is put
     * on the wire once, inside the sealed channel, and is referenced nowhere afterwards — not
     * stored, not logged, and deliberately not kept on any view-model field.
     */
    data class Request(
        val address: ServerAddress,
        val username: String,
        val secret: String,
        val method: EnrollMethod,
        /** This phone's durable identity. See the header — a throwaway here mints a dead credential. */
        val identity: StaticKeyPair,
        val deviceName: String,
    )

    /**
     * [run] as a plain `suspend (Request) -> Result`, for a caller that wants a function reference.
     *
     * The same trick, and the same reason, as `Rendezvous.lookupAt`: a method reference to a
     * function with default arguments is not that type, and a lambda in a default parameter is a
     * closure the reader has to open the view model to understand.
     */
    suspend fun signIn(request: Request): Result = run(request)

    /**
     * Sign in to a server and come back with a credential, or with a sentence.
     *
     * `client` is a seam for the tests, exactly as it is on [dev.terminaldeck.android.pairing.Rendezvous.lookup]:
     * a unit test that used the real one would open a socket to the public relay from whatever
     * machine ran the suite.
     */
    suspend fun run(
        request: Request,
        client: OkHttpClient = defaultClient(),
        timeoutMs: Long = TIMEOUT_MS,
    ): Result {
        val address = request.address
        val username = request.username
        val secret = request.secret
        val method = request.method
        val identity = request.identity
        val deviceName = request.deviceName
        val settled = CompletableDeferred<Result>()

        // `okhttp3.Request` spelled out: [Request] in this scope is this object's own, and a socket
        // builder that silently resolved to the wrong one is the kind of collision worth naming.
        val httpRequest = try {
            okhttp3.Request.Builder()
                .url("${address.relayUrl.toHttpish().trimEnd('/')}$GUEST_PATH?host=${address.hostId}")
                .build()
        } catch (e: IllegalArgumentException) {
            return Result.Unreachable(BAD_RELAY)
        }

        val handshake = HandshakeInitiator(identity, address.hostKey)
        var channel: SealedChannel? = null
        var exchange: EnrollExchange? = null

        val socket = client.newWebSocket(httpRequest, object : WebSocketListener() {

            override fun onOpen(webSocket: WebSocket, response: Response) {
                // Message one, binary, with the version byte in front of it. That framing is the
                // difference between a handshake that is byte-perfect and one that is one byte
                // short — see [RelayWire].
                webSocket.send(RelayWire.withSealedVersion(handshake.message).toByteString())
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                val live = channel
                if (live == null) {
                    val opened = RelayWire.readSealedHandshake(
                        bytes.toByteArray(),
                        RelayWire.HANDSHAKE_REPLY_BYTES,
                    )
                    val reply = when (opened) {
                        is RelayWire.SealedOpen.Ok -> opened.message
                        is RelayWire.SealedOpen.Refused -> {
                            val sentence = if (opened.reason is RelayWire.Refusal.WrongVersion) {
                                VERSION_MISMATCH
                            } else {
                                NOT_A_HANDSHAKE
                            }
                            settled.complete(Result.Unreachable(sentence))
                            webSocket.cancel()
                            return
                        }
                    }
                    val established = try {
                        handshake.finish(reply)
                    } catch (e: SealedException) {
                        // The far end does not hold the private half of the key in the address.
                        // Either the address is not this server's, or something else answered for
                        // it — which is the exact attack carrying the key is meant to refuse.
                        settled.complete(Result.Unreachable(WRONG_KEY))
                        webSocket.cancel()
                        return
                    }
                    channel = established

                    // The exchange is built only now: it opens by sending, and there was nothing to
                    // send through until this moment.
                    val driver = EnrollExchange(
                        send = { frame -> writeSealed(webSocket, established, frame, settled) },
                        onOutcome = { outcome -> settled.complete(outcome.asResult()) },
                    )
                    exchange = driver
                    driver.start(
                        EnrollExchange.Input(
                            username = username,
                            secret = secret,
                            method = method,
                            device = DeviceDescriptor(name = deviceName, platform = PLATFORM),
                        )
                    )
                    return
                }

                val text = try {
                    live.receiveText(bytes.toByteArray())
                } catch (e: SealedException) {
                    // A frame that will not open is corruption or an impostor, and the channel's
                    // counters are the only truth about ordering — there is nothing to resynchronise
                    // to, so the sign-in ends here.
                    settled.complete(Result.Unreachable(CHANNEL_BROKEN))
                    webSocket.cancel()
                    return
                }
                when (val parsed = ServerFrames.parse(text)) {
                    is ServerFrames.Result.Bad -> Log.d(TAG, "dropped a frame during sign-in: ${parsed.reason}")
                    is ServerFrames.Result.Ok -> exchange?.receive(parsed.message)
                }
            }

            /**
             * Text frames are refused rather than ignored: everything on this socket is ciphertext,
             * so a text frame means the far end is not a relay carrying a sealed channel.
             */
            override fun onMessage(webSocket: WebSocket, text: String) {
                settled.complete(Result.Unreachable(NOT_A_RELAY))
                webSocket.cancel()
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                webSocket.close(Protocol.Close.NORMAL, null)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                // A refusal arrives as an `error` frame and *then* a close, so by the time this runs
                // the exchange has usually already settled with the server's own words. Completing
                // is a no-op on an already-settled deferred, which is what makes the ordering safe.
                settled.complete(closedResult(channel != null))
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                // The exception's message names hosts and ports and would end up on a screen; it is
                // logged instead. See the same decision in `WebSocketDeckTransport`.
                Log.d(TAG, "sign-in socket failed", t)
                settled.complete(closedResult(channel != null))
            }
        })

        return try {
            withTimeoutOrNull(timeoutMs) { settled.await() } ?: Result.Unreachable(TOO_SLOW)
        } finally {
            socket.cancel()
        }
    }

    /* -------------------------------------------------------------------- plumbing -- */

    private fun writeSealed(
        socket: WebSocket,
        channel: SealedChannel,
        frame: ClientMessage,
        settled: CompletableDeferred<Result>,
    ) {
        try {
            socket.send(channel.sendText(ClientFrames.encode(frame)).toByteString())
        } catch (e: SealedException) {
            settled.complete(Result.Unreachable(CHANNEL_BROKEN))
            socket.cancel()
        }
    }

    private fun EnrollExchange.Outcome.asResult(): Result = when (this) {
        is EnrollExchange.Outcome.SignedIn -> Result.SignedIn(
            credential = credential,
            deviceId = deviceId,
            deviceName = deviceName,
            welcome = welcome,
        )
        is EnrollExchange.Outcome.Refused -> Result.Refused(sentence)
    }

    /**
     * What a socket that closed means, and why the two answers are different.
     *
     * Before the handshake, silence is the shape a server that does not serve sign-in has: it
     * refuses an unknown device key without producing a reply, on purpose, because saying which
     * check failed would hand a hostile relay an oracle. After the handshake it is an ordinary
     * dropped connection, and saying anything about sign-in availability would be a guess.
     */
    private fun closedResult(sealed: Boolean): Result =
        Result.Unreachable(if (sealed) LOST else NO_ANSWER)

    fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build()

    private const val TAG = "TerminalDeck"

    /** The relay's guest endpoint, from `relay/src/rendezvous.ts`. */
    private const val GUEST_PATH = "/v1/join"

    private const val PLATFORM = "android"

    private const val BAD_RELAY = "That relay address cannot be opened. Check the wss:// part of the address."

    /**
     * Silence before the handshake, and why it names three possibilities rather than one.
     *
     * A server refuses a handshake by *saying nothing* — it will not tell a caller which check
     * failed, because that would hand a hostile relay an oracle. So all three of these arrive here
     * identically and this client genuinely cannot tell them apart: nothing is running there, it is
     * running but does not serve sign-in, or the key in the pasted address is not that server's, in
     * which case its own handshake never completes. Naming one of the three would be a guess, and
     * the wrong guess sends somebody to check the wrong thing.
     */
    const val NO_ANSWER =
        "That server did not answer this phone. It may not be running Terminal Deck right now, it " +
            "may not offer sign-in, or the address may not be that server's — check it is up, then " +
            "check you pasted the whole address."

    const val LOST = "The connection to that server dropped part-way through signing in. Try again."

    const val TOO_SLOW =
        "That server did not finish checking the sign-in in time. It may still be working — wait a " +
            "moment before trying again."

    const val WRONG_KEY =
        "That server could not prove it holds the key in that address. Check you pasted the whole " +
            "address, and that it came from the server itself."

    private const val VERSION_MISMATCH =
        "That server and this app speak different sealed-channel versions. Update whichever is older."

    private const val NOT_A_HANDSHAKE =
        "That server's first answer was not a sealed handshake. Check the relay address in what you pasted."

    private const val NOT_A_RELAY = "The relay sent something this app does not understand."

    private const val CHANNEL_BROKEN = "The connection to that server could not be verified."
}
