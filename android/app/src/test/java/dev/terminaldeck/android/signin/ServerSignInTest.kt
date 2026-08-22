package dev.terminaldeck.android.signin

import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.crypto.SealedChannel
import dev.terminaldeck.android.crypto.StaticKeyPair
import dev.terminaldeck.android.crypto.respondToHandshake
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ProtocolErrorCode
import dev.terminaldeck.android.protocol.ProtocolJson
import dev.terminaldeck.android.protocol.RelayWire
import dev.terminaldeck.android.protocol.RemoteSession
import dev.terminaldeck.android.protocol.ServerMessage
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.TimeUnit

/**
 * A whole sign-in, on a real socket, through a real sealed channel.
 *
 * `EnrollExchangeTest` proves the frame sequence and cannot prove this: that the four frames
 * actually cross a Noise IK channel this phone opened from nothing but a pasted address, and that
 * what comes back is a credential the server has already accepted a `hello` with. Every one of the
 * failures this feature is most likely to have — a handshake one byte short, a key that does not
 * decrypt, a follow-up hello that never goes — is invisible to a scripted transport and fatal here.
 *
 * The server half is `respondToHandshake` from the crypto tests, which is transcribed from the
 * desktop's own `sealed.ts`; nothing here re-implements the key schedule.
 */
class ServerSignInTest {

    /**
     * A server at the other end of a relay.
     *
     * Answers the handshake with its own static key, then plays whatever script it was given: mint
     * a device and welcome it, or refuse.
     */
    private class FakeServer(
        private val keys: StaticKeyPair,
        /** Null mints and welcomes; non-null refuses with this frame instead. */
        private val refusal: ServerMessage.Error? = null,
        private val credential: String = "dev-9.secret",
    ) : WebSocketListener() {

        private var channel: SealedChannel? = null

        @Volatile
        var enroll: ClientMessage.Enroll? = null
            private set

        @Volatile
        var hello: ClientMessage.Hello? = null
            private set

        /** The key the phone shook hands with — what `enrollDevice` binds the new device row to. */
        @Volatile
        var devicePublicKey: ByteArray? = null
            private set

        @Volatile
        var socket: WebSocket? = null
            private set

        override fun onOpen(webSocket: WebSocket, response: okhttp3.Response) {
            socket = webSocket
        }

        // A half-closed socket keeps MockWebServer's queue busy and its shutdown then throws.
        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
            socket = webSocket
            val live = channel
            if (live == null) {
                val opened = RelayWire.readSealedHandshake(bytes.toByteArray(), RelayWire.HANDSHAKE_OPEN_BYTES)
                val message = (opened as? RelayWire.SealedOpen.Ok)?.message
                    ?: error("the phone's first payload was not a framed handshake: $opened")
                val result = respondToHandshake(keys, message)
                channel = result.channel
                devicePublicKey = result.devicePublicKey
                webSocket.send(RelayWire.withSealedVersion(result.reply).toByteString())
                return
            }

            val text = live.receiveText(bytes.toByteArray())
            when (val parsed = ProtocolJson.decodeFromString(ClientMessage.serializer(), text)) {
                is ClientMessage.Enroll -> {
                    enroll = parsed
                    if (refusal != null) {
                        webSocket.send(live.sendText(encode(refusal)).toByteString())
                        webSocket.close(Protocol.Close.POLICY_VIOLATION, "refused")
                        return
                    }
                    webSocket.send(
                        live.sendText(
                            encode(ServerMessage.Enrolled("dev-9", "Asad's Pixel", credential))
                        ).toByteString()
                    )
                }

                is ClientMessage.Hello -> {
                    hello = parsed
                    webSocket.send(live.sendText(encode(welcome())).toByteString())
                }

                else -> Unit
            }
        }

        private fun encode(message: ServerMessage): String =
            ProtocolJson.encodeToString(ServerMessage.serializer(), message)

        /**
         * The welcome a signed-in device gets: no `token`, because nothing was minted by this hello
         * — the credential came from `enrolled` — and the server's real session list with it.
         */
        private fun welcome() = ServerMessage.Welcome(
            protocol = Protocol.VERSION,
            deviceId = "dev-9",
            deviceName = "Asad's Pixel",
            token = null,
            sessions = listOf(
                RemoteSession(id = "s1", title = "api", cwd = "/srv/api", provider = "claude", status = "running")
            ),
            capabilities = listOf("create", "close"),
            hostKind = "headless",
        )
    }

    private companion object {
        const val HOST = "M9G95TNJT64Q928VW3HVRYDR8J"
    }

    private lateinit var client: OkHttpClient
    private val servers = mutableListOf<MockWebServer>()
    private val fakes = mutableListOf<FakeServer>()

    @Before
    fun setUp() {
        client = OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
    }

    @After
    fun tearDown() {
        for (fake in fakes) runCatching { fake.socket?.cancel() }
        for (server in servers) runCatching { server.shutdown() }
        client.dispatcher.executorService.shutdown()
    }

    /** A server, and the address a person would paste to reach it. */
    private fun server(refusal: ServerMessage.Error? = null): Pair<FakeServer, ServerAddress> {
        val keys = Sealed.generateStatic()
        val fake = FakeServer(keys, refusal).also { fakes += it }
        val mock = MockWebServer().also { servers += it }
        mock.enqueue(MockResponse().withWebSocketUpgrade(fake))
        mock.start()
        val url = mock.url("/")
        return fake to ServerAddress(
            relayUrl = "ws://${url.host}:${url.port}",
            hostId = HOST,
            hostKey = keys.publicKey,
        )
    }

    private fun signIn(
        address: ServerAddress,
        identity: StaticKeyPair,
        method: EnrollMethod = EnrollMethod.Password,
        secret: String = "hunter2",
    ): ServerSignIn.Result = runBlocking {
        ServerSignIn.run(
            ServerSignIn.Request(
                address = address,
                username = "asad",
                secret = secret,
                method = method,
                identity = identity,
                deviceName = "Asad's Pixel",
            ),
            client = client,
            timeoutMs = 15_000,
        )
    }

    /* -------------------------------------------------------------- the whole path -- */

    /**
     * The requirement, end to end: a pasted address and a login become a credential that has already
     * been spent once.
     */
    @Test
    fun `a pasted address and a login come back as a credential the server has already accepted`() {
        val (fake, address) = server()
        val identity = Sealed.generateStatic()

        val result = signIn(address, identity)

        val signedIn = result as? ServerSignIn.Result.SignedIn
            ?: throw AssertionError("expected a sign-in, got $result")
        assertEquals("dev-9.secret", signedIn.credential)
        assertEquals("dev-9", signedIn.deviceId)
        assertEquals("Asad's Pixel", signedIn.deviceName)
        // The server's own facts, out of the welcome the follow-up hello earned — so nothing has to
        // reconnect to learn what this machine can do.
        assertEquals(listOf("create", "close"), signedIn.welcome.capabilities)
        assertEquals("headless", signedIn.welcome.hostKind)
        assertEquals(1, signedIn.welcome.sessions.size)

        // The login really crossed, as a login.
        val enroll = assertNotNull("no enroll reached the server", fake.enroll).let { fake.enroll!! }
        assertEquals("asad", enroll.username)
        assertEquals("hunter2", enroll.secret)
        assertEquals(EnrollMethod.Password, enroll.method)

        // And the credential really came back the other way, on the same socket, in a hello.
        assertEquals("dev-9.secret", fake.hello?.token)
    }

    /**
     * The phone signs in as **itself**, and this is the test that says why it matters.
     *
     * `enrollDevice` writes the handshake's public key into the device row it mints, and
     * `knowsDeviceKey` is what admits this phone on every connection afterwards. Signing in with a
     * throwaway key would mint a device bound to a key this phone then discards — a credential that
     * works on this socket and is refused for ever after, with nothing on either side to explain it.
     */
    @Test
    fun `it shakes hands with this phone's durable key, not a throwaway`() {
        val (fake, address) = server()
        val identity = Sealed.generateStatic()

        signIn(address, identity)

        assertTrue(
            "the server saw a key that is not this phone's",
            identity.publicKey.contentEquals(fake.devicePublicKey),
        )
    }

    @Test
    fun `a private key is sent as a key, newlines and all`() {
        val (fake, address) = server()
        val pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEA\n-----END OPENSSH PRIVATE KEY-----\n"

        signIn(address, Sealed.generateStatic(), method = EnrollMethod.Key, secret = pem)

        assertEquals(EnrollMethod.Key, fake.enroll?.method)
        // Not trimmed and not stripped: a PEM's line breaks are content, and this is the one field
        // in the protocol where they are allowed through for exactly that reason.
        assertEquals(pem, fake.enroll?.secret)
    }

    /* ------------------------------------------------------------------ refusals -- */

    @Test
    fun `a refused login comes back as the server's own sentence`() {
        val refusal = ServerMessage.Error(
            code = ProtocolErrorCode.Unauthorized,
            message = "That sign-in was refused. Check the username, and the password or key, then try again.",
        )
        val (_, address) = server(refusal = refusal)

        val result = signIn(address, Sealed.generateStatic())

        val refused = result as? ServerSignIn.Result.Refused
            ?: throw AssertionError("expected a refusal, got $result")
        assertEquals(refusal.message, refused.sentence)
    }

    @Test
    fun `a server that cannot offer sign-in says so in its own words`() {
        val refusal = ServerMessage.Error(
            code = ProtocolErrorCode.Unavailable,
            message = "Sign-in is not available on this machine. Pair it with a code instead.",
        )
        val (_, address) = server(refusal = refusal)

        val result = signIn(address, Sealed.generateStatic())

        assertEquals(refusal.message, (result as ServerSignIn.Result.Refused).sentence)
    }

    /**
     * An address whose key is not that server's: the login never leaves the phone.
     *
     * This is the whole reason a key travels in an address. The phone knows which machine it is
     * talking to *before* it says anything, so the handshake is Noise IK rather than
     * trust-on-first-use: with the wrong static key the server cannot open the encrypted half of
     * message one, and nothing that follows ever happens. A password typed against a mistyped or
     * substituted address is therefore never sent anywhere — which is the property worth pinning,
     * more than the sentence.
     *
     * And the sentence is [ServerSignIn.NO_ANSWER] rather than something about keys, because that is
     * what is actually knowable here: a failed handshake produces **silence** by design — the far
     * end will not say which check failed — so this is byte-for-byte indistinguishable from a server
     * that is not running. Reporting it as "wrong key" would be a guess dressed as a diagnosis.
     */
    @Test
    fun `a key that is not that server's sends no login anywhere`() {
        val (fake, real) = server()
        val wrong = real.copy(hostKey = Sealed.generateStatic().publicKey)

        val result = signIn(wrong, Sealed.generateStatic())

        assertTrue("expected unreachable, got $result", result is ServerSignIn.Result.Unreachable)
        assertEquals(ServerSignIn.NO_ANSWER, (result as ServerSignIn.Result.Unreachable).sentence)
        // The half that matters: the password never crossed.
        assertEquals(null, fake.enroll)
    }

    /**
     * Nothing at the address at all.
     *
     * The most likely failure in the field, and worded for it: a server that does not serve sign-in
     * refuses the handshake by saying nothing, so silence has to be reported as "not running, or not
     * offering sign-in" rather than as a network problem.
     */
    @Test
    fun `a server that answers nothing is reported as one that may not offer sign-in`() {
        val mock = MockWebServer().also { servers += it }
        // Upgrades the socket and then says nothing at all, which is what the desktop's handshake
        // refusal looks like from here.
        mock.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: okhttp3.Response) {
                webSocket.close(1000, null)
            }
        }))
        mock.start()
        val url = mock.url("/")
        val address = ServerAddress("ws://${url.host}:${url.port}", HOST, ByteArray(32) { 4 })

        val result = signIn(address, Sealed.generateStatic())

        assertEquals(ServerSignIn.NO_ANSWER, (result as ServerSignIn.Result.Unreachable).sentence)
    }

    @Test
    fun `a server that never answers is given up on rather than waited on for ever`() {
        val mock = MockWebServer().also { servers += it }
        mock.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {}))
        mock.start()
        val url = mock.url("/")
        val address = ServerAddress("ws://${url.host}:${url.port}", HOST, ByteArray(32) { 4 })

        val result = runBlocking {
            ServerSignIn.run(
                ServerSignIn.Request(
                    address = address,
                    username = "asad",
                    secret = "hunter2",
                    method = EnrollMethod.Password,
                    identity = Sealed.generateStatic(),
                    deviceName = "Asad's Pixel",
                ),
                client = client,
                timeoutMs = 300,
            )
        }

        assertEquals(ServerSignIn.TOO_SLOW, (result as ServerSignIn.Result.Unreachable).sentence)
    }
}
