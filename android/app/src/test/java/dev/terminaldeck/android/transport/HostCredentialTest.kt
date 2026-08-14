package dev.terminaldeck.android.transport

import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.crypto.SealedChannel
import dev.terminaldeck.android.crypto.StaticKeyPair
import dev.terminaldeck.android.crypto.respondToHandshake
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.ProtocolJson
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.RelayWire
import dev.terminaldeck.android.protocol.RemoteSession
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.store.DeviceVault
import dev.terminaldeck.android.store.InMemoryDeviceVault
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import okhttp3.OkHttpClient
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.ByteString
import okio.ByteString.Companion.toByteString
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * One socket per machine, and no machine ever spends another one's credential.
 *
 * This is the separation that matters most and the only one a scripted transport cannot prove: the
 * credential is spent inside `hello`, behind a Noise IK handshake, on the wire. So this test puts a
 * real WebSocket at the other end of two real transports, with a real sealed channel over it, and
 * reads the token each machine was actually sent.
 *
 * The failure it exists to catch is a transport that asks the store for "the pairing" rather than
 * for its own — the shape the code had a day ago, when there could only be one — because that
 * version reconnects with whichever machine was paired most recently. On a phone with two machines
 * that is a credential handed to the wrong computer and five failed attempts against a lockout
 * counter on the right one.
 *
 * The host half is `respondToHandshake` from the crypto tests, which is transcribed from the
 * desktop's `sealed.ts`; nothing here re-implements the schedule.
 */
class HostCredentialTest {

    /**
     * A machine at the other end of a relay: completes the handshake with its own static key, then
     * reads one sealed frame and answers it.
     */
    private class FakeHost(
        private val keys: StaticKeyPair,
        /** What this machine mints in `welcome`. Deliberately different per machine. */
        private val mints: String,
    ) : WebSocketListener() {

        private var channel: SealedChannel? = null

        @Volatile
        var hello: ClientMessage.Hello? = null
            private set

        /** Kept so the fixture can drop the socket, which is what lets MockWebServer shut down. */
        @Volatile
        var socket: WebSocket? = null
            private set

        val greeted = CountDownLatch(1)

        override fun onOpen(webSocket: WebSocket, response: okhttp3.Response) {
            socket = webSocket
        }

        /**
         * Answer the close rather than ignoring it.
         *
         * A half-closed WebSocket keeps MockWebServer's dispatcher queue busy, and its `shutdown`
         * then throws "gave up waiting for queue to shut down" — a green test that fails in teardown.
         */
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
                webSocket.send(RelayWire.withSealedVersion(result.reply).toByteString())
                return
            }

            val text = live.receiveText(bytes.toByteArray())
            val parsed = ProtocolJson.decodeFromString(ClientMessage.serializer(), text)
            if (parsed !is ClientMessage.Hello) return
            hello = parsed
            webSocket.send(live.sendText(welcome()).toByteString())
            greeted.countDown()
        }

        /**
         * A `welcome` that both mints and admits.
         *
         * The session list is what makes it an admission rather than the half-welcome a freshly
         * redeemed pairing token gets — see `WebSocketDeckTransport.welcome`.
         */
        private fun welcome(): String = ProtocolJson.encodeToString(
            ServerMessage.serializer(),
            ServerMessage.Welcome(
                protocol = Protocol.VERSION,
                deviceId = "device-for-$mints",
                deviceName = "Pixel",
                token = mints,
                sessions = listOf(
                    RemoteSession(id = "s1", title = "api", cwd = "/tmp", provider = "claude", status = "running")
                ),
                capabilities = listOf("create"),
            ),
        )
    }

    private companion object {
        const val MAC = "M9G95TNJT64Q928VW3HVRYDR8J"
        const val PC = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"
    }

    private lateinit var scope: CoroutineScope
    private lateinit var beat: Heartbeat
    private lateinit var client: OkHttpClient
    private lateinit var vault: DeviceVault
    private val servers = mutableListOf<MockWebServer>()
    private val hosts = mutableListOf<FakeHost>()
    private val transports = mutableListOf<WebSocketDeckTransport>()

    @Before
    fun setUp() {
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        // Not the app-wide tick: a test that joined that would leave a timer in the build.
        beat = Heartbeat(scope = CoroutineScope(SupervisorJob() + Dispatchers.Default))
        client = OkHttpClient.Builder()
            .connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
        vault = InMemoryDeviceVault()
    }

    @After
    fun tearDown() {
        // Disconnecting is also what takes each socket back out of the tick, which is what stops it.
        for (transport in transports) transport.disconnect()
        // `cancel` throws if the exchange has already gone, which is the normal case once the
        // transport has closed cleanly — and a teardown that fails on tidying up is a red test for a
        // green run.
        for (host in hosts) runCatching { host.socket?.cancel() }
        for (server in servers) runCatching { server.shutdown() }
        scope.cancel()
        client.dispatcher.executorService.shutdown()
    }

    /** A machine, its keys, and a relay address pointing at it. */
    private fun host(hostId: String, pairingToken: String, mints: String): FakeHost {
        val keys = Sealed.generateStatic()
        val fake = FakeHost(keys, mints).also { hosts += it }
        val server = MockWebServer().also { servers += it }
        server.enqueue(MockResponse().withWebSocketUpgrade(fake))
        server.start()
        val url = server.url("/")
        vault.beginPairing(
            hostId = hostId,
            hostStaticPublicKey = keys.publicKey,
            relayUrl = "ws://${url.host}:${url.port}",
            pairingToken = pairingToken,
        )
        return fake
    }

    private fun transportFor(hostId: String): WebSocketDeckTransport = WebSocketDeckTransport(
        scope = scope,
        hostId = hostId,
        vault = vault,
        deviceName = "Pixel Test",
        client = client,
        heartbeat = beat,
    ).also { transports += it }

    private fun awaitOnline(transport: WebSocketDeckTransport, what: String) {
        val deadline = System.currentTimeMillis() + 15_000
        while (System.currentTimeMillis() < deadline) {
            when (val state = transport.state.value) {
                is TransportState.Online -> return
                is TransportState.Rejected, is TransportState.Incompatible ->
                    fail("$what refused the connection: $state")
                else -> Thread.sleep(20)
            }
        }
        fail("$what never came online; last state ${transport.state.value}")
    }

    /**
     * The whole point, on a real socket: two machines, two credentials, no crossing.
     */
    @Test
    fun `each machine is sent its own credential and nobody else's`() {
        val mac = host(MAC, pairingToken = "pair-token-mac", mints = "durable.mac")
        val pc = host(PC, pairingToken = "pair-token-pc", mints = "durable.pc")

        val toMac = transportFor(MAC)
        val toPc = transportFor(PC)
        toMac.connect()
        toPc.connect()

        assertTrue("the Mac never saw a hello", mac.greeted.await(15, TimeUnit.SECONDS))
        assertTrue("the PC never saw a hello", pc.greeted.await(15, TimeUnit.SECONDS))
        awaitOnline(toMac, "the Mac")
        awaitOnline(toPc, "the PC")

        assertEquals("pair-token-mac", mac.hello?.token)
        assertEquals("pair-token-pc", pc.hello?.token)
        // Said twice on purpose. The assertion above passes if the two happened to be spent in the
        // right order; this one fails if either machine ever saw the other's secret at all.
        assertFalse("the Mac was handed the PC's credential", mac.hello?.token == "pair-token-pc")
        assertFalse("the PC was handed the Mac's credential", pc.hello?.token == "pair-token-mac")

        // The relay is told which machine to find, and told the right one.
        assertEquals("/v1/join?host=$MAC", servers[0].takeRequest(5, TimeUnit.SECONDS)?.path)
        assertEquals("/v1/join?host=$PC", servers[1].takeRequest(5, TimeUnit.SECONDS)?.path)
    }

    /**
     * And the durable credential each machine mints is written to that machine's record only.
     *
     * A store that took a credential without being told whose it was would be N writers to one
     * drawer, and the bug that must not exist is a write for one machine landing on another — which
     * would leave a phone holding the Mac's credential under the PC's name and unable to reach
     * either.
     */
    @Test
    fun `a minted credential is stored against the machine that minted it`() {
        val mac = host(MAC, pairingToken = "pair-token-mac", mints = "durable.mac")
        val pc = host(PC, pairingToken = "pair-token-pc", mints = "durable.pc")

        val toMac = transportFor(MAC)
        toMac.connect()
        assertTrue(mac.greeted.await(15, TimeUnit.SECONDS))
        awaitOnline(toMac, "the Mac")

        assertEquals("durable.mac", vault.pairing(MAC)?.token)
        assertTrue(vault.pairing(MAC)?.approved == true)
        // The machine that has not connected yet is untouched: still its one-shot pairing token,
        // still unapproved.
        assertEquals("pair-token-pc", vault.pairing(PC)?.token)
        assertFalse(vault.pairing(PC)?.approved == true)
        assertNotNull(pc)

        val toPc = transportFor(PC)
        toPc.connect()
        assertTrue(pc.greeted.await(15, TimeUnit.SECONDS))
        awaitOnline(toPc, "the PC")

        assertEquals("durable.pc", vault.pairing(PC)?.token)
        assertEquals("and the first machine's credential did not move", "durable.mac", vault.pairing(MAC)?.token)
    }
}
