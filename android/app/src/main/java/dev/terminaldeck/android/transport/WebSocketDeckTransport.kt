package dev.terminaldeck.android.transport

import android.os.Build
import android.util.Log
import dev.terminaldeck.android.crypto.HandshakeInitiator
import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.crypto.SealedChannel
import dev.terminaldeck.android.crypto.SealedException
import dev.terminaldeck.android.protocol.ClientFrames
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.DeviceDescriptor
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ProtocolErrorCode
import dev.terminaldeck.android.protocol.RelayWire
import dev.terminaldeck.android.protocol.ServerFrames
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.store.DeviceVault
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit

/**
 * The real client: a relay socket with a Noise IK channel inside it.
 *
 * ## The shape of a connection
 *
 * ```
 *   GET <relay>/v1/join?host=<26-char host id>        ← the only thing the relay is told
 *   → 81 bytes   [version] e ‖ seal(s)                ← Noise IK message one, behind its version
 *   ← 49 bytes   [version] e ‖ seal(empty)            ← message two
 *   ⇄ sealed frames, each one a protocol.ts JSON message
 * ```
 *
 * Every frame after the handshake is `SealedChannel.send`/`receive`, so the relay carries
 * ciphertext and a length. The 17-byte envelope in `rendezvous.ts` is host-side only — a phone has
 * exactly one channel and is not told its own name — so nothing here writes one.
 *
 * The version byte, though, is not optional and was missing here: `sealed.ts` produces 80 bytes and
 * `relay-wire.ts` frames them to 81 before they cross a relay. A desktop refuses a first payload of
 * the wrong length by closing the channel in silence — deliberately, so a hostile relay gets no
 * oracle — so an 80-byte handshake reached the Mac, was dropped, and looked from here exactly like
 * a Mac that was asleep. [RelayWire] is that framing and the only place it is applied.
 *
 * ## The rule this class exists to obey
 *
 * It must never show a terminal that looks connected when it is not. A phone terminal is used to
 * check on something long-running and to stop it when it goes wrong, and a screen of stale output
 * under a live-looking cursor is worse than no client at all: someone types Ctrl+C into it and
 * walks away believing the job stopped.
 *
 * So [TransportState.Online] is reached at exactly one point — a `welcome` that admitted this
 * device — and [send] refuses rather than buffers whenever the channel is not up.
 *
 * ## Ordering, and why there is a generation counter
 *
 * OkHttp delivers callbacks on its own reader thread while the UI calls [connect], [resume] and
 * [disconnect] from the main one. A socket that is being replaced can still deliver a close after
 * its successor has opened, and acting on it would tear down the live connection. Every listener
 * therefore carries the generation it was created in and does nothing once it is stale.
 */
class WebSocketDeckTransport(
    private val scope: CoroutineScope,
    private val vault: DeviceVault,
    private val deviceName: String = "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
    private val clock: () -> Long = System::currentTimeMillis,
    private val client: OkHttpClient = defaultClient(),
) : DeckTransport {

    private val lock = Any()

    private val _state = MutableStateFlow<TransportState>(TransportState.Offline)
    override val state: StateFlow<TransportState> = _state.asStateFlow()

    private val _incoming = MutableSharedFlow<ServerMessage>(replay = 0, extraBufferCapacity = 512)
    override val incoming: Flow<ServerMessage> = _incoming.asSharedFlow()

    /** Capabilities the desktop advertised in `welcome`. Empty until one arrives. */
    private val _capabilities = MutableStateFlow<Set<String>>(emptySet())
    val capabilities: StateFlow<Set<String>> = _capabilities.asStateFlow()

    private val backoff = Backoff()

    private var socket: WebSocket? = null
    private var generation = 0
    private var initiator: HandshakeInitiator? = null
    private var channel: SealedChannel? = null
    private var greeted = false
    private var stopped = true

    /**
     * The device is paired but not approved, and every reconnect from here is a poll for that
     * approval.
     *
     * Held as its own flag rather than read back off the state, because connecting overwrites the
     * state — which is how the one sentence telling the user to go and press the button gets lost
     * half a second after it appears.
     */
    private var awaitingApproval = false
    private var approvalDetail = "Paired. Approve this device on the Mac, then reconnect."

    /**
     * Whether the Mac has answered *on this attempt*.
     *
     * A frame that parsed is the proof: it arrived through the sealed channel, so whoever sent it
     * holds the Mac's static private key. Reset on every [open].
     *
     * This exists because [awaitingApproval] used to be enough on its own to report
     * [TransportState.Pending] — so once a device was pending, every subsequent failure, including
     * a handshake that never completed, was described with the remembered approval sentence. A
     * client that could not reach the Mac at all therefore said "Paired. Approve this device on the
     * Mac" forever, which is a connection failure wearing the costume of the normal path.
     */
    private var macAnswered = false
    private var macAnsweredLastAttempt = false

    private var retryJob: Job? = null
    private var heartbeatJob: Job? = null
    private var handshakeJob: Job? = null
    private var awaitingPong = false

    /* ------------------------------------------------------------------ public -- */

    override fun connect() {
        synchronized(lock) {
            stopped = false
            open()
        }
    }

    override fun resume() {
        synchronized(lock) {
            if (stopped) return
            when (_state.value) {
                // Retrying a refused credential is not merely useless: `device-auth.ts` locks a
                // device out after five failed attempts, so a phone coming out of a pocket must
                // not spend one.
                is TransportState.Rejected,
                is TransportState.Incompatible,
                is TransportState.Unpaired,
                is TransportState.Online,
                is TransportState.Connecting,
                -> return
                else -> Unit
            }
            backoff.reset()
            open()
        }
    }

    override fun disconnect() {
        synchronized(lock) {
            stopped = true
            awaitingApproval = false
            macAnswered = false
            macAnsweredLastAttempt = false
            clearTimers()
            closeSocket(Protocol.Close.NORMAL, "client closed")
            _state.value = TransportState.Offline
        }
    }

    override fun send(message: ClientMessage): Boolean = synchronized(lock) {
        if (!greeted) return false
        write(ClientFrames.encode(message))
    }

    /* ----------------------------------------------------------------- machinery -- */

    private fun open() {
        clearTimers()
        closeSocket(Protocol.Close.NORMAL, "reconnecting")
        greeted = false
        channel = null
        initiator = null
        macAnswered = false

        val pairing = vault.pairing()
        val token = pairing?.token
        if (pairing == null || token == null) {
            // Not an error and not a retry: there is nothing to connect with, and the app's answer
            // is the pair screen.
            _state.value = TransportState.Unpaired
            return
        }

        // While waiting for approval the reconnects *are* the poll, and flipping the banner to
        // "Connecting…" every few seconds would bury the instruction. That only holds while the Mac
        // is answering, though: if the last attempt reached nothing, "waiting for approval"
        // describes a conversation that is not happening.
        _state.value = if (awaitingApproval && macAnsweredLastAttempt) {
            TransportState.Pending(approvalDetail)
        } else {
            TransportState.Connecting
        }

        val url = "${pairing.relayUrl.trimEnd('/')}$GUEST_PATH?host=${pairing.hostId}"
        val request = try {
            Request.Builder().url(url.toHttpish()).build()
        } catch (e: IllegalArgumentException) {
            scheduleRetry("That relay address cannot be opened.")
            return
        }

        generation += 1
        val listener = RelayListener(
            generation = generation,
            token = token,
            handshake = HandshakeInitiator(vault.identity(), pairing.hostStaticPublicKey),
        )
        initiator = listener.handshake
        socket = client.newWebSocket(request, listener)

        // Nothing else bounds the gap between an open socket and a welcome. A captive portal, a
        // middlebox holding the connection, or a relay that accepted the upgrade for a Mac that is
        // not there all leave the client on "Connecting…" for as long as the platform's own TCP
        // timeout, with no retry in flight.
        handshakeJob = scope.launch {
            delay(HANDSHAKE_TIMEOUT_MS)
            synchronized(lock) {
                if (greeted || stopped) return@launch
                fail("The Mac accepted the connection but never answered.")
            }
        }
    }

    private inner class RelayListener(
        private val generation: Int,
        private val token: String,
        val handshake: HandshakeInitiator,
    ) : WebSocketListener() {

        private fun stale(): Boolean = generation != this@WebSocketDeckTransport.generation

        override fun onOpen(webSocket: WebSocket, response: Response) {
            synchronized(lock) {
                if (stale()) return
                // Message one goes out before anything else, binary, with the version byte in
                // front of it. That framing is applied here and nowhere else.
                webSocket.send(RelayWire.withSealedVersion(handshake.message).toByteString())
            }
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            synchronized(lock) {
                if (stale()) return
                val live = channel
                if (live == null) {
                    finishHandshake(webSocket, bytes.toByteArray())
                    return
                }
                val text = try {
                    live.receiveText(bytes.toByteArray())
                } catch (e: SealedException) {
                    // A frame that does not open is either corruption or something that is not the
                    // Mac. Either way the channel's counters are now the only truth about ordering
                    // and it cannot be resynchronised — so the connection ends.
                    fail("The connection could not be verified.")
                    return
                }
                receive(text)
            }
        }

        /**
         * Text frames are refused rather than ignored.
         *
         * Everything in this transport is ciphertext. A text frame means the far end is not the
         * relay carrying a sealed channel, and reading it would be reading something unauthenticated.
         */
        override fun onMessage(webSocket: WebSocket, text: String) {
            synchronized(lock) {
                if (stale()) return
                fail("The relay sent something this client does not understand.")
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(Protocol.Close.NORMAL, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            synchronized(lock) {
                if (stale()) return
                socket = null
                if (stopped) return
                if (terminal()) return
                scheduleRetry(closeReason(code, greeted))
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            synchronized(lock) {
                if (stale()) return
                socket = null
                if (stopped) return
                if (terminal()) return
                // The exception's message is not shown: it names hosts and ports, and this string
                // ends up on a lock screen. It is logged instead.
                Log.d(TAG, "relay socket failed", t)
                scheduleRetry("Could not reach that Mac. It may be asleep, offline, or the relay is down.")
            }
        }

        private fun finishHandshake(webSocket: WebSocket, framed: ByteArray) {
            // Unwrapped before the cryptography sees it. A version this build does not speak is
            // told apart from a reply that failed its tag: only one of the two is fixed by updating
            // an app, and a client that fed the framed reply straight to `finish` would report the
            // wrong one — 49 bytes read as a 48-byte Noise reply is a length error, which is what
            // "this Mac could not prove who it is" would then have been saying.
            val reply = when (val opened = RelayWire.readSealedHandshake(framed, RelayWire.HANDSHAKE_REPLY_BYTES)) {
                is RelayWire.SealedOpen.Ok -> opened.message
                is RelayWire.SealedOpen.Refused -> {
                    Log.w(TAG, "handshake reply refused: ${opened.reason}")
                    if (opened.reason is RelayWire.Refusal.WrongVersion) {
                        terminate(TransportState.Incompatible(opened.reason.sentence))
                    } else {
                        fail(opened.reason.sentence)
                    }
                    return
                }
            }

            val sealedChannel = try {
                handshake.finish(reply)
            } catch (e: SealedException) {
                // The far end does not hold the Mac's static private key, or the relay bent a byte.
                // Not recoverable by retrying against the same key, but it is also exactly what a
                // Mac that has forgotten this device looks like — so it retries, slowly, rather
                // than sending the user to a pair screen on one bad frame.
                fail("This Mac could not prove who it is.")
                return
            }
            channel = sealedChannel
            write(
                ClientFrames.encode(
                    ClientMessage.Hello(
                        protocol = Protocol.VERSION,
                        token = token,
                        device = DeviceDescriptor(name = deviceName, platform = PLATFORM),
                    )
                )
            )
        }
    }

    /* ------------------------------------------------------------------ protocol -- */

    private fun receive(raw: String) {
        val message = when (val parsed = ServerFrames.parse(raw)) {
            is ServerFrames.Result.Bad -> {
                // Not fatal on its own: a message type added on the desktop side arrives here as
                // garbage until this client is updated, and dropping one frame is better than
                // dropping the session.
                Log.d(TAG, "dropped a frame: ${parsed.reason}")
                return
            }
            is ServerFrames.Result.Ok -> parsed.message
        }

        // A frame that parsed came through the sealed channel, so the far end holds the Mac's
        // static private key. That is the only evidence worth calling "the Mac answered".
        macAnswered = true

        when {
            message is ServerMessage.Welcome -> welcome(message)

            // Only before the handshake has completed is an `error` frame about *this device*. The
            // desktop spends the same `unauthorized` code on in-session refusals — "Attach to that
            // session before typing into it" — which it sends without closing the socket, and
            // reading one of those as "not approved yet" would tear down a working connection and
            // put a pairing instruction over a live session.
            message is ServerMessage.Error && !greeted -> refusal(message)

            message is ServerMessage.Pong -> awaitingPong = false

            else -> emit(message)
        }
    }

    private fun welcome(message: ServerMessage.Welcome) {
        if (message.protocol != Protocol.VERSION) {
            terminate(
                TransportState.Incompatible(
                    "The Mac speaks protocol ${message.protocol} and this app speaks ${Protocol.VERSION}. " +
                        "Update whichever is older."
                )
            )
            return
        }

        // A minted token means the pairing token was just spent. Swap it immediately: the pairing
        // token is single-use and reconnecting with it would be refused and would count against
        // the failed-attempt limiter.
        val minted = message.token
        if (minted != null) vault.storeCredential(minted, message.deviceId, message.deviceName)

        /*
         * A `welcome` is not always an admission.
         *
         * `authenticatorFor` in the desktop's server.ts answers a freshly redeemed pairing token
         * with a welcome that carries the new credential and an empty session list, and then
         * refuses the connection — the credential has to travel or the pairing was for nothing,
         * but a human still has to approve the device. Treating that as "connected" lights the UI
         * up for the half second before the socket closes, which is the exact lie this class is
         * built to avoid.
         *
         * A desktop that both mints and admits in one breath — which the protocol allows, even if
         * today's does not do it — sends sessions with it, and that is read as an admission.
         */
        if (minted != null && message.sessions.isEmpty()) {
            awaitingApproval = true
            _capabilities.value = message.capabilities.toSet()
            emit(message)
            scheduleRetry(approvalDetail)
            return
        }

        greeted = true
        awaitingApproval = false
        vault.markApproved()
        backoff.reset()
        clearHandshakeTimer()
        _capabilities.value = message.capabilities.toSet()
        _state.value = TransportState.Online(message.deviceName)
        startHeartbeat()
        emit(message)
    }

    private fun refusal(message: ServerMessage.Error) {
        val detail = message.message.ifEmpty { null }
        when (message.code) {
            ProtocolErrorCode.Unauthenticated -> {
                // The credential is not good any more. Keeping it would spend attempts against a
                // lockout counter forever; clearing it is what turns the next launch into a pair
                // screen with an explanation.
                vault.clearCredential()
                terminate(TransportState.Rejected(detail ?: "This device is not paired with that Mac any more."))
            }

            ProtocolErrorCode.Unauthorized -> {
                // Paired but not approved. The fix is a person walking to the Mac, so this keeps
                // trying — slowly — rather than declaring failure at someone who is three metres
                // from the button. The backoff doubles as the poll interval.
                awaitingApproval = true
                if (detail != null) approvalDetail = detail
                emit(message)
                closeSocket(Protocol.Close.NORMAL, "awaiting approval")
                scheduleRetry(approvalDetail)
            }

            ProtocolErrorCode.Version ->
                terminate(TransportState.Incompatible(detail ?: "The Mac refused this app's protocol version."))

            else -> emit(message)
        }
    }

    /* -------------------------------------------------------------------- plumbing -- */

    private fun write(json: String): Boolean {
        val live = socket ?: return false
        val sealedChannel = channel ?: return false
        return try {
            live.send(sealedChannel.sendText(json).toByteString())
        } catch (e: SealedException) {
            fail("The connection could not be verified.")
            false
        }
    }

    private fun emit(message: ServerMessage) {
        // `tryEmit` rather than a coroutine: it keeps frames in arrival order, which a queue of
        // launched coroutines only happens to do. A full buffer means the UI has stalled for 512
        // frames, and dropping the oldest output is better than blocking the socket thread.
        if (!_incoming.tryEmit(message)) Log.w(TAG, "dropped a frame: nothing is collecting")
    }

    /** A failure this side detected: close, and schedule the retry here. */
    private fun fail(detail: String) {
        closeSocket(Protocol.Close.PROTOCOL_ERROR, "protocol error")
        scheduleRetry(detail)
    }

    /** A failure retrying cannot fix. */
    private fun terminate(next: TransportState) {
        clearTimers()
        _state.value = next
        closeSocket(Protocol.Close.NORMAL, "closed")
    }

    private fun terminal(): Boolean = _state.value.let {
        it is TransportState.Rejected || it is TransportState.Incompatible || it is TransportState.Unpaired
    }

    private fun scheduleRetry(detail: String) {
        // Every path to a retry comes through here, so this is the one place that can guarantee
        // there is never more than one in flight — two would double the attempts on every round.
        retryJob?.cancel()
        clearHandshakeTimer()
        clearHeartbeat()
        macAnsweredLastAttempt = macAnswered
        val delayMs = backoff.next()
        val retryAt = clock() + delayMs
        /*
         * Which of the two waits this is.
         *
         * [TransportState.Pending] is a claim about the Mac — that it answered and said "not yet" —
         * so it is only made when the Mac did answer on this attempt. When it did not, this is an
         * ordinary [TransportState.Waiting] carrying the real reason the attempt failed. The
         * device is still unapproved either way, and the pair screen keeps the window; what changes
         * is that it now says which of the two is happening instead of always saying the nicer one.
         */
        _state.value = if (awaitingApproval && macAnswered) {
            TransportState.Pending(approvalDetail, retryAt)
        } else {
            TransportState.Waiting(detail, retryAt, backoff.attempts)
        }
        retryJob = scope.launch {
            delay(delayMs)
            synchronized(lock) { if (!stopped) open() }
        }
    }

    /**
     * A ping the desktop has to answer, on top of the relay's own.
     *
     * The relay pings both of its sockets, so a dead TCP connection is noticed there — but "the
     * relay can still reach my socket" is not "the Mac is still there". Only an end-to-end pong
     * proves the far end is alive and still holds the channel.
     */
    private fun startHeartbeat() {
        clearHeartbeat()
        heartbeatJob = scope.launch {
            while (isActive) {
                delay(PING_EVERY_MS - PONG_GRACE_MS)
                synchronized(lock) {
                    awaitingPong = true
                    if (!write(ClientFrames.encode(ClientMessage.Ping))) return@launch
                }
                delay(PONG_GRACE_MS)
                synchronized(lock) {
                    if (awaitingPong) {
                        fail("The connection stopped answering.")
                        return@launch
                    }
                }
            }
        }
    }

    private fun clearHeartbeat() {
        heartbeatJob?.cancel()
        heartbeatJob = null
        awaitingPong = false
    }

    private fun clearHandshakeTimer() {
        handshakeJob?.cancel()
        handshakeJob = null
    }

    private fun clearTimers() {
        retryJob?.cancel()
        retryJob = null
        clearHandshakeTimer()
        clearHeartbeat()
    }

    private fun closeSocket(code: Int, reason: String) {
        val live = socket ?: return
        socket = null
        channel = null
        greeted = false
        // The generation bump is what unhooks the listener: OkHttp has no way to detach one, and a
        // close callback arriving after this would otherwise schedule a second retry.
        generation += 1
        try {
            live.close(code, reason)
        } catch (e: IllegalArgumentException) {
            live.cancel()
        }
    }

    private companion object {
        const val TAG = "TerminalDeck"

        /** The relay's guest endpoint, from `relay/src/rendezvous.ts`. */
        const val GUEST_PATH = "/v1/join"

        const val PLATFORM = "android"

        /** Well under the 30 seconds after which idle NAT entries start being reclaimed. */
        const val PING_EVERY_MS = 25_000L
        const val PONG_GRACE_MS = 10_000L
        const val HANDSHAKE_TIMEOUT_MS = 15_000L

        fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
            // A phone sleeps. Without a ping at the socket layer too, the first thing the user
            // learns about a dead connection is that their keystrokes vanish.
            .pingInterval(20, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .connectTimeout(10, TimeUnit.SECONDS)
            .build()
    }
}

/**
 * OkHttp takes `http`/`https` URLs even for WebSockets and does the upgrade itself.
 *
 * Passing `ws://` to `HttpUrl` throws, which as a crash on a pairing code someone typed is a poor
 * trade for a five-line function.
 */
internal fun String.toHttpish(): String = when {
    startsWith("ws://", ignoreCase = true) -> "http://" + substring(5)
    startsWith("wss://", ignoreCase = true) -> "https://" + substring(6)
    else -> this
}

/**
 * What to tell the user about a close code.
 *
 * `greeted` matters: the same code means different things on either side of the handshake. A close
 * during it is usually the Mac refusing this device; the same code afterwards is usually the
 * network. Transcribed from `pwa/src/connection.ts`.
 */
internal fun closeReason(code: Int, greeted: Boolean): String = when (code) {
    Protocol.Close.NORMAL, Protocol.Close.GOING_AWAY ->
        if (greeted) "The Mac closed the connection." else "The connection closed before the Mac answered."
    Protocol.Close.PROTOCOL_ERROR, Protocol.Close.UNSUPPORTED_DATA -> "The Mac rejected a message from this app."
    Protocol.Close.POLICY_VIOLATION -> "The Mac refused this device."
    Protocol.Close.MESSAGE_TOO_BIG -> "A message was too large for the Mac to accept."
    Protocol.Close.TRY_AGAIN_LATER -> "The Mac asked this app to try again later."
    Protocol.Close.INTERNAL_ERROR -> "The Mac hit an internal error."
    else -> if (greeted) "Connection lost." else "Could not reach that Mac. It may be asleep or offline."
}
