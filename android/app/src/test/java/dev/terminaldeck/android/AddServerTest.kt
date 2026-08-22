package dev.terminaldeck.android

import dev.terminaldeck.android.github.InMemoryGitHubStore
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.RemoteSession
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.signin.ServerAddress
import dev.terminaldeck.android.signin.ServerSignIn
import dev.terminaldeck.android.store.DeviceVault
import dev.terminaldeck.android.store.InMemoryDeviceVault
import dev.terminaldeck.android.transport.DeckTransport
import dev.terminaldeck.android.transport.Heartbeat
import dev.terminaldeck.android.transport.TransportState
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Adding a server from the phone, at the level a person would notice it.
 *
 * This is the gap 0.10.0 shipped with. Every piece of the wire was built and tested — the frames,
 * the host's probe, the mint, the drivers — and there was no screen on any phone that could reach
 * any of it, so the feature Asad asked for most was, from the phone, absent. What is asked here is
 * therefore not "does the protocol work" (`ServerSignInTest` asks that, on a socket) but the
 * questions a person would ask holding the phone: did my server appear, is it connected, did it
 * cost me the machines I already had, and when it refused me did it say why.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class AddServerTest {

    /** A transport whose far end is this test. Same double `MultiHostTest` drives. */
    private class ScriptedTransport(val hostId: String, private val vault: DeviceVault) : DeckTransport {

        private val _state = MutableStateFlow<TransportState>(TransportState.Offline)
        override val state: StateFlow<TransportState> = _state.asStateFlow()

        private val _incoming = MutableSharedFlow<ServerMessage>(replay = 0, extraBufferCapacity = 64)
        override val incoming: Flow<ServerMessage> = _incoming.asSharedFlow()

        var connects = 0
            private set
        val sent = mutableListOf<ClientMessage>()

        override fun connect() {
            connects += 1
            _state.value = TransportState.Connecting
        }

        override fun resume() = Unit

        override fun disconnect() {
            _state.value = TransportState.Offline
        }

        override fun send(message: ClientMessage): Boolean {
            sent += message
            return true
        }

        /** Come up as a signed-in server does: no minted token, and its sessions with it. */
        fun goLive(sessions: List<RemoteSession> = emptyList()) {
            _state.value = TransportState.Online("Asad's Pixel")
            _incoming.tryEmit(
                ServerMessage.Welcome(
                    protocol = Protocol.VERSION,
                    deviceId = "dev-9",
                    deviceName = "Asad's Pixel",
                    token = null,
                    sessions = sessions,
                    capabilities = listOf("create"),
                    hostKind = "headless",
                )
            )
        }
    }

    private class FakeClipboard : Clipboard {
        override fun read(): String? = null
        override fun write(text: String) = Unit
        override val confirmsItself: Boolean = false
    }

    private companion object {
        const val SERVER = "M9G95TNJT64Q928VW3HVRYDR8J"
        const val MAC = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"
        const val RELAY = "wss://relay.terminaldeck.dev"
        const val PASSWORD = "correct-horse-battery-staple"
    }

    private val serverKey = ByteArray(32) { (it * 3 + 1).toByte() }
    private val address = "td1 $RELAY $SERVER ${ServerAddress.encodeKey(serverKey)}"

    private lateinit var vault: DeviceVault
    private lateinit var transports: MutableMap<String, ScriptedTransport>
    private lateinit var deck: DeckViewModel

    /** Every request the view model made of the sign-in, so the test can read what it sent. */
    private val attempts = mutableListOf<ServerSignIn.Request>()

    /** What the next sign-in answers with. Replaced per test. */
    private var answer: suspend (ServerSignIn.Request) -> ServerSignIn.Result = { signedIn() }

    private fun signedIn(credential: String = "dev-9.secret") = ServerSignIn.Result.SignedIn(
        credential = credential,
        deviceId = "dev-9",
        deviceName = "Asad's Pixel",
        welcome = ServerMessage.Welcome(
            protocol = Protocol.VERSION,
            deviceId = "dev-9",
            deviceName = "Asad's Pixel",
            token = null,
            sessions = emptyList(),
            capabilities = listOf("create"),
            hostKind = "headless",
        ),
    )

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        vault = InMemoryDeviceVault()
        transports = mutableMapOf()
        deck = build()
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun build(): DeckViewModel = DeckViewModel(
        vault = vault,
        clipboard = FakeClipboard(),
        accounts = InMemoryGitHubStore(),
        network = NetworkWatch.none,
        heartbeat = Heartbeat(scope = CoroutineScope(Dispatchers.Unconfined)),
        serverSignIn = { request ->
            attempts += request
            answer(request)
        },
        deviceName = "Asad's Pixel",
    ) { _, hostId, store ->
        transports.getOrPut(hostId) { ScriptedTransport(hostId, store) }
    }

    private val state get() = deck.uiState.value

    private fun transport(hostId: String): ScriptedTransport = requireNotNull(transports[hostId])

    private fun signIn(
        raw: String = address,
        username: String = "asad",
        secret: String = PASSWORD,
        method: EnrollMethod = EnrollMethod.Password,
    ) {
        deck.beginAddingServer()
        deck.signInToServer(raw, username, secret, method)
    }

    /* ------------------------------------------------------------- the screen exists -- */

    /**
     * The entry point has state behind it.
     *
     * Not a formality: the whole defect was a wire with no screen, and a screen the app cannot be
     * asked to show is the same defect one layer up.
     */
    @Test
    fun `the add-a-server screen opens and closes`() {
        assertNull(state.addServer)
        deck.beginAddingServer()
        assertNotNull(state.addServer)
        assertFalse(state.addServer!!.busy)
        deck.cancelAddingServer()
        assertNull(state.addServer)
    }

    /* ------------------------------------------------------------------ the happy path -- */

    @Test
    fun `signing in adds the server, connected and selected, and closes the screen`() {
        signIn()

        assertNull("the screen should close on success", state.addServer)
        assertEquals(SERVER, state.selectedHostId)
        val row = state.hosts.single()
        assertEquals(SERVER, row.hostId)
        assertTrue("a signed-in server is approved on arrival", row.approved)
        assertEquals(1, transport(SERVER).connects)

        // And it behaves like any other machine from here: a welcome lights it up.
        transport(SERVER).goLive(listOf(RemoteSession("s1", "api", "/srv/api", "claude", "running")))
        assertTrue(state.live)
        assertEquals(1, state.sessions.size)
    }

    @Test
    fun `the credential the server minted is what gets stored`() {
        signIn()

        val record = requireNotNull(vault.pairing(SERVER))
        assertEquals("dev-9.secret", record.token)
        assertEquals("dev-9", record.deviceId)
        assertEquals("Asad's Pixel", record.deviceName)
        assertTrue(record.approved)
        assertEquals(RELAY, record.relayUrl)
        assertTrue("the server's key travels with the address", serverKey.contentEquals(record.hostStaticPublicKey))
    }

    /**
     * The password is spent and gone.
     *
     * It goes on the wire once, inside the sealed channel, and is referenced nowhere afterwards.
     * Anything that kept it — a vault field, a view-model field, the published state — would be
     * keeping somebody's actual server password on a phone, for ever, for no purpose.
     */
    @Test
    fun `the password is never stored anywhere this phone can be read from`() {
        signIn()

        for (record in vault.pairings()) {
            assertFalse(record.token?.contains(PASSWORD) == true)
            assertFalse(record.nickname?.contains(PASSWORD) == true)
            assertFalse(record.deviceName?.contains(PASSWORD) == true)
        }
        assertFalse(state.toString().contains(PASSWORD))
    }

    @Test
    fun `the request carries this phone's durable identity and the login as typed`() {
        signIn(username = "  asad  ")

        val request = attempts.single()
        assertEquals(SERVER, request.address.hostId)
        assertEquals(RELAY, request.address.relayUrl)
        // Trimmed, because a phone keyboard's trailing space is not part of a username — and the
        // server trims it too, so a client that did not would check a different string from the one
        // that gets used.
        assertEquals("asad", request.username)
        assertEquals(PASSWORD, request.secret)
        assertEquals("Asad's Pixel", request.deviceName)
        // The durable key. A throwaway here would mint a device row bound to a key this phone then
        // discards — a credential refused for ever after with nothing to explain it.
        assertTrue(vault.identity().publicKey.contentEquals(request.identity.publicKey))
    }

    /**
     * The rule the whole vault is shaped around, asked of the new ceremony.
     *
     * Adding a machine must never remove one. It is the failure that reads as *my phone forgot my
     * Mac*, and a second way of adding a machine is a second way to get it wrong.
     */
    @Test
    fun `signing in to a server does not touch a machine already paired`() {
        vault.beginPairing(MAC, ByteArray(32) { 9 }, RELAY, "482913")
        deck = build()
        transport(MAC).goLive()

        signIn()

        assertEquals(listOf(MAC, SERVER), state.hosts.map { it.hostId })
        assertNotNull("the paired machine is still in the vault", vault.pairing(MAC))
        assertEquals("and its socket was never touched", 1, transport(MAC).connects)
    }

    /** Signing in again to a server already in the list replaces its credential, not its place. */
    @Test
    fun `signing in again re-credentials the same server rather than adding a second row`() {
        signIn()
        deck.rename(SERVER, "Frankfurt box")

        answer = { signedIn(credential = "dev-9.fresh") }
        signIn()

        assertEquals(1, state.hosts.size)
        assertEquals("dev-9.fresh", vault.pairing(SERVER)?.token)
        assertEquals("the name a person gave it survives", "Frankfurt box", vault.pairing(SERVER)?.nickname)
    }

    /* --------------------------------------------------------------------- refusals -- */

    @Test
    fun `a refusal keeps the screen up, in the server's own words, with nothing added`() {
        val sentence = "That sign-in was refused. Check the username, and the password or key, then try again."
        answer = { ServerSignIn.Result.Refused(sentence) }

        signIn()

        val view = requireNotNull(state.addServer)
        assertEquals(sentence, view.error)
        assertFalse("no spinner is left running", view.busy)
        assertTrue(state.hosts.isEmpty())
        assertNull(vault.pairing(SERVER))
    }

    @Test
    fun `an unreachable server keeps the screen up too`() {
        answer = { ServerSignIn.Result.Unreachable(ServerSignIn.NO_ANSWER) }

        signIn()

        assertEquals(ServerSignIn.NO_ANSWER, state.addServer?.error)
        assertTrue(state.hosts.isEmpty())
    }

    /**
     * A bad address is refused here, and no server is dialled.
     *
     * Which is also what makes the error line useful: it names the fact that is missing while the
     * person is still looking at the field, rather than after a round trip that could only ever have
     * failed.
     */
    @Test
    fun `an address that is not one never reaches the network`() {
        signIn(raw = "my server in frankfurt")

        assertTrue(attempts.isEmpty())
        assertTrue(requireNotNull(state.addServer).error!!.contains("host id"))
    }

    @Test
    fun `an empty username or secret is refused before anything is sent`() {
        signIn(username = "   ")
        assertTrue(attempts.isEmpty())
        assertTrue(state.addServer?.error?.contains("username") == true)

        signIn(secret = "")
        assertTrue(attempts.isEmpty())
        assertTrue(state.addServer?.error?.contains("password") == true)
    }

    @Test
    fun `a key too large for the wire is refused before it is sent`() {
        signIn(secret = "x".repeat(Protocol.MAX_ENROLL_SECRET_BYTES + 1), method = EnrollMethod.Key)

        assertTrue(attempts.isEmpty())
        assertTrue(state.addServer?.error?.contains("too large") == true)
    }

    /**
     * One sign-in at a time.
     *
     * Two `enroll` frames for one login are two SSH probes on somebody else's server and two
     * attempts against its rate limiter — and it is the second that locks a person out of their own
     * machine. A double tap must not be able to do that.
     */
    @Test
    fun `a second tap while one is in flight does not start a second sign-in`() {
        val held = CompletableDeferred<ServerSignIn.Result>()
        answer = { held.await() }

        signIn()
        assertTrue("the screen says what it is doing", state.addServer?.busy == true)

        deck.signInToServer(address, "asad", PASSWORD, EnrollMethod.Password)
        assertEquals(1, attempts.size)

        held.complete(signedIn())
        assertNull(state.addServer)
        assertEquals(SERVER, state.selectedHostId)
    }

    @Test
    fun `cancelling while one is in flight closes the screen and stops waiting on it`() {
        val held = CompletableDeferred<ServerSignIn.Result>()
        answer = { held.await() }

        signIn()
        deck.cancelAddingServer()

        assertNull(state.addServer)
        assertTrue(state.hosts.isEmpty())
    }
}
