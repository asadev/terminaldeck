package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.RemoteSession
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.store.DeviceVault
import dev.terminaldeck.android.store.InMemoryDeviceVault
import dev.terminaldeck.android.transport.DeckTransport
import dev.terminaldeck.android.transport.Heartbeat
import dev.terminaldeck.android.transport.TransportState
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
 * One phone, several machines.
 *
 * The failure this whole feature has to be designed against is not "multi-host does not work". It is
 * a phone that pairs with a second machine and silently drops the first, because to the person
 * holding it that is indistinguishable from *the app forgot my Mac* — and it is the shape the bug
 * would naturally take, since every one of these types was single-host a day ago.
 *
 * So the first tests are the same test asked several ways: after adding a machine, is the other one
 * still there — in the collection, in the vault, still connected, and after a relaunch.
 *
 * The second half is about **separation**. Two machines' session lists must not merge, and a request
 * must reach the machine it was made on. A bug there is worse than losing a pairing: it types into
 * the wrong computer. The credential half of that separation is proved on a real socket in
 * `HostCredentialTest`; what is proved here is that the collection never crosses the wires.
 *
 * Driven through a scripted transport rather than a socket, for the same reason the iOS tests are:
 * these are questions about which object holds what, and a real relay would only make them slower to
 * ask.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MultiHostTest {

    /* ------------------------------------------------------------------- doubles -- */

    /** A transport whose far end is this test. */
    private class ScriptedTransport(val hostId: String, private val vault: DeviceVault) : DeckTransport {

        private val _state = MutableStateFlow<TransportState>(TransportState.Offline)
        override val state: StateFlow<TransportState> = _state.asStateFlow()

        private val _incoming = MutableSharedFlow<ServerMessage>(replay = 0, extraBufferCapacity = 64)
        override val incoming: Flow<ServerMessage> = _incoming.asSharedFlow()

        var connects = 0
            private set
        var disconnects = 0
            private set
        var resumes = 0
            private set
        val sent = mutableListOf<ClientMessage>()

        override fun connect() {
            connects += 1
            _state.value = TransportState.Connecting
        }

        override fun resume() {
            resumes += 1
        }

        override fun disconnect() {
            disconnects += 1
            _state.value = TransportState.Offline
        }

        override fun send(message: ClientMessage): Boolean {
            sent += message
            return true
        }

        /** Come up, be let in, and say what is running — everything a real `welcome` does. */
        fun goLive(sessions: List<RemoteSession> = emptyList(), capabilities: List<String> = listOf("create")) {
            vault.storeCredential(hostId, "durable.$hostId", "device-$hostId", "Pixel")
            vault.markApproved(hostId)
            _state.value = TransportState.Online("Pixel")
            _incoming.tryEmit(
                ServerMessage.Welcome(
                    protocol = 1,
                    deviceId = "device-$hostId",
                    deviceName = "Pixel",
                    token = null,
                    sessions = sessions,
                    capabilities = capabilities,
                )
            )
        }

        fun drop(detail: String = "Connection lost.") {
            _state.value = TransportState.Waiting(detail, null, 1)
        }
    }

    private class FakeClipboard : Clipboard {
        var contents: String? = null
        override fun read(): String? = contents
        override fun write(text: String) {
            contents = text
        }

        override val confirmsItself: Boolean = false
    }

    /* ------------------------------------------------------------------ fixtures -- */

    private companion object {
        const val MAC = "M9G95TNJT64Q928VW3HVRYDR8J"
        const val PC = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"
    }

    private lateinit var vault: DeviceVault
    private lateinit var transports: MutableMap<String, ScriptedTransport>
    private lateinit var deck: DeckViewModel

    @Before
    fun setUp() {
        // Unconfined: `viewModelScope` collects on the main dispatcher, and this test wants a frame
        // to have been handled by the time the line that produced it returns.
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
        network = NetworkWatch.none,
        // Its own, not the app-wide one: a test that joined the shared tick would leave a timer
        // running in whatever process ran it.
        heartbeat = Heartbeat(scope = CoroutineScope(Dispatchers.Unconfined)),
    ) { _, hostId, store ->
        transports.getOrPut(hostId) { ScriptedTransport(hostId, store) }
    }

    private fun code(hostId: String, token: String = "pair-$hostId"): String {
        val key = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 5 })
        return "terminaldeck://pair#v=1&r=wss://relay.example&h=$hostId&k=$key&t=$token"
    }

    private fun session(id: String, title: String, status: String = "running") =
        RemoteSession(id = id, title = title, cwd = "/Users/asad/$title", provider = "claude", status = status)

    private fun transport(hostId: String): ScriptedTransport = requireNotNull(transports[hostId])

    private val state get() = deck.uiState.value

    private fun host(hostId: String): HostSummary =
        requireNotNull(state.hosts.firstOrNull { it.hostId == hostId }) { "no row for $hostId" }

    /* --------------------------------------------------------------- pairing adds -- */

    /**
     * The requirement, at the level a user would notice it.
     *
     * Not only "the record survives": the first machine must still be **connected**, because a
     * switcher that showed the other machine offline the moment a second was added would be the same
     * bug with a slower reveal.
     */
    @Test
    fun `pairing a second machine leaves the first paired and connected`() {
        deck.pair(code(MAC))
        transport(MAC).goLive(listOf(session("mac-1", "api")))
        assertEquals(1, state.hosts.size)

        deck.pair(code(PC))

        assertEquals(listOf(MAC, PC), state.hosts.map { it.hostId })
        assertNotNull("the first machine must still be in the vault", vault.pairing(MAC))
        assertNotNull(vault.pairing(PC))
        assertEquals(0, transport(MAC).disconnects)
        assertEquals(1, transport(MAC).connects)
        assertTrue("the first machine's socket must still be up", host(MAC).isOnline)
        assertEquals("and it must still know what is running on it", 1, host(MAC).sessionCount)
    }

    /** Both come back on the next launch, which is when the loss would be noticed. */
    @Test
    fun `both machines come back on relaunch`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))

        deck = build()

        assertEquals(listOf(MAC, PC), state.hosts.map { it.hostId })
    }

    /** Anything else would be a pairing that appears to have done nothing. */
    @Test
    fun `the machine just paired is the one on screen`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))

        assertEquals(PC, state.selectedHostId)
        assertEquals(PC, vault.selectedHost())
    }

    /** And the machine on screen is remembered across a relaunch, rather than falling to the oldest. */
    @Test
    fun `the machine on screen survives a relaunch`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))
        deck.select(MAC)

        deck = build()

        assertEquals(MAC, state.selectedHostId)
    }

    /** Re-pairing after a revoke is normal, and must not cost the other machine. */
    @Test
    fun `re-pairing one machine does not duplicate it or touch the other`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))
        transport(PC).goLive(listOf(session("pc-1", "installer")))

        deck.pair(code(MAC, token = "fresh"))

        assertEquals(listOf(MAC, PC), state.hosts.map { it.hostId })
        assertEquals("fresh", vault.pairing(MAC)?.token)
        assertEquals(MAC, state.selectedHostId)
        // The machine being re-paired is taken down and brought back up so its transport reads the
        // token that was just written. The other one is not.
        assertEquals(2, transport(MAC).connects)
        assertEquals(1, transport(MAC).disconnects)
        assertEquals(0, transport(PC).disconnects)
        assertTrue(host(PC).isOnline)
    }

    @Test
    fun `forgetting one machine keeps the other`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))
        transport(MAC).goLive()
        transport(PC).goLive()

        deck.forget(MAC)

        assertEquals(listOf(PC), state.hosts.map { it.hostId })
        assertNull(vault.pairing(MAC))
        assertNotNull(vault.pairing(PC))
        assertEquals(PC, state.selectedHostId)
        assertEquals("the machine that was forgotten is the only socket that closes", 1, transport(MAC).disconnects)
        assertEquals(0, transport(PC).disconnects)
    }

    /**
     * Asking to add a machine does not disturb the ones already paired.
     *
     * The pair screen takes the window — which is why this is worth a test at all: it looks, from the
     * outside, exactly like the app having forgotten everything.
     */
    @Test
    fun `opening the add screen leaves every machine paired and connected`() {
        deck.pair(code(MAC))
        transport(MAC).goLive(listOf(session("mac-1", "api")))

        deck.beginAddingHost()

        assertTrue(state.addingHost)
        assertTrue("the pair screen owns the window", state.needsPairing)
        assertTrue("and it can be left again, because a machine already works", state.canLeavePairing)
        assertEquals(listOf(MAC), state.hosts.map { it.hostId })
        assertTrue(host(MAC).isOnline)

        deck.cancelAddingHost()
        assertFalse(state.addingHost)
        assertFalse(state.needsPairing)
        assertEquals(MAC, state.selectedHostId)
    }

    /** With nothing paired there is genuinely nowhere to go, and the screen must not pretend. */
    @Test
    fun `the first pairing cannot be cancelled`() {
        assertTrue(state.needsPairing)
        assertFalse(state.canLeavePairing)
        assertTrue(state.hosts.isEmpty())
    }

    /* ----------------------------------------------------- everything stays connected -- */

    @Test
    fun `every machine is connected, not just the one on screen`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))

        assertEquals(1, transport(MAC).connects)
        assertEquals(1, transport(PC).connects)

        deck = build()
        assertEquals("a relaunch brings all of them up", 2, transport(MAC).connects)
        assertEquals(2, transport(PC).connects)
    }

    @Test
    fun `a machine that is not on screen still reports its own status`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))
        transport(MAC).goLive(listOf(session("mac-1", "api")))
        transport(PC).goLive()

        // The PC is the one on screen, and shows none of the Mac's sessions.
        assertEquals(PC, state.selectedHostId)
        assertTrue(state.sessions.isEmpty())
        // …while the Mac's row is live and says what is on it.
        assertTrue(host(MAC).isOnline)
        assertEquals(1, host(MAC).sessionCount)

        transport(MAC).drop()
        assertFalse(host(MAC).isOnline)
        assertNull("a count under a dead socket would be the switcher lying", host(MAC).sessionCount)
        assertTrue("the machine on screen is unaffected by the other one dropping", host(PC).isOnline)
    }

    /* --------------------------------------------------------------- separation -- */

    @Test
    fun `session lists do not merge`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))
        transport(MAC).goLive(listOf(session("mac-1", "api"), session("mac-2", "web")))
        transport(PC).goLive(listOf(session("pc-1", "installer")))

        deck.select(MAC)
        assertEquals(listOf("mac-1", "mac-2"), state.sessions.map { it.id })

        deck.select(PC)
        assertEquals(listOf("pc-1"), state.sessions.map { it.id })
    }

    /**
     * A frame from one machine is applied to that machine only, even for an id both could have.
     *
     * Session ids come from each computer's own session layer and nothing makes them unique across
     * two of them, so this is not a contrived collision — it is the normal case for two machines
     * running the same tool.
     */
    @Test
    fun `a status frame lands only on the machine that sent it`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))
        transport(MAC).goLive(listOf(session("shared-id", "api", status = "running")))
        transport(PC).goLive(listOf(session("shared-id", "installer", status = "running")))

        transport(MAC).let { it.goLive(listOf(session("shared-id", "api", status = "waiting"))) }

        assertEquals("waiting", host(MAC).sessions.single().status)
        assertEquals("the other machine's row must not have moved", "running", host(PC).sessions.single().status)
    }

    /** A request goes to the machine on screen and to no other. */
    @Test
    fun `a request reaches only the machine it was made on`() {
        deck.pair(code(MAC))
        deck.pair(code(PC))
        transport(MAC).goLive(listOf(session("mac-1", "api")))
        transport(PC).goLive(listOf(session("pc-1", "installer")))
        val macBefore = transport(MAC).sent.size

        deck.select(PC)
        deck.refresh()
        deck.newSession(folder = "/Users/asad/installer")

        assertTrue(transport(PC).sent.any { it is ClientMessage.List })
        assertTrue(transport(PC).sent.any { it is ClientMessage.Create })
        assertEquals("not one byte of it went to the other computer", macBefore, transport(MAC).sent.size)
    }

    /* ---------------------------------------------------------------- the switcher -- */

    @Test
    fun `the switcher only claims a choice when there is one`() {
        deck.pair(code(MAC))
        assertFalse(state.hasSeveralHosts)
        deck.pair(code(PC))
        assertTrue(state.hasSeveralHosts)
    }

    @Test
    fun `a machine can be named, and the name survives a re-pair`() {
        deck.pair(code(MAC))
        deck.rename(MAC, "Studio")

        assertEquals("Studio", host(MAC).label)
        assertEquals("Studio", vault.pairing(MAC)?.nickname)

        // The moment the user is least pleased to lose a name is the moment they have to pair again.
        deck.pair(code(MAC, token = "fresh"))
        assertEquals("Studio", host(MAC).label)

        deck.rename(MAC, null)
        assertEquals("without one, enough of the id to tell it apart", MAC.take(6), host(MAC).label)
    }

    /** Nothing is paired, so there is no name to show and the screen must not invent one. */
    @Test
    fun `an unpaired phone says so`() {
        assertEquals("not paired", state.hostLabel)
        assertTrue(state.hosts.isEmpty())
    }
}
