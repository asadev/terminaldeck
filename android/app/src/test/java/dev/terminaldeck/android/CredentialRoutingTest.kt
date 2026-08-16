package dev.terminaldeck.android

import dev.terminaldeck.android.github.GitHubAccount
import dev.terminaldeck.android.github.InMemoryGitHubStore
import dev.terminaldeck.android.pairing.Rendezvous
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.CredentialDenial
import dev.terminaldeck.android.protocol.CredentialOperation
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * A `credential.request` arriving on a socket, and the answer leaving on the *same* one.
 *
 * `CredentialResponderTest` proves the policy against a fake route. This proves the wiring: that
 * the frame reaches the responder at all, that the prompt the screens read is folded out of it with
 * the machine's own name attached, and — the claim that would break silently — that the reply goes
 * back to the machine that asked rather than to whichever machine happens to be on screen.
 *
 * With two machines paired, getting that wrong is a coin flip, and the losing side answers one
 * computer's question on another computer's socket. Nothing about it would look wrong: the prompt
 * appears, the button works, and a push somewhere else hangs until a timer gives up.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class CredentialRoutingTest {

    /** A transport whose far end is this test. */
    private class ScriptedTransport(val hostId: String, private val vault: DeviceVault) : DeckTransport {

        private val _state = MutableStateFlow<TransportState>(TransportState.Offline)
        override val state: StateFlow<TransportState> = _state.asStateFlow()

        private val _incoming = MutableSharedFlow<ServerMessage>(replay = 0, extraBufferCapacity = 64)
        override val incoming: Flow<ServerMessage> = _incoming.asSharedFlow()

        val sent = mutableListOf<ClientMessage>()

        override fun connect() {
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

        fun goLive() {
            vault.storeCredential(hostId, "durable.$hostId", "device-$hostId", "Pixel")
            vault.markApproved(hostId)
            _state.value = TransportState.Online("Pixel")
            _incoming.tryEmit(
                ServerMessage.Welcome(
                    protocol = 1,
                    deviceId = "device-$hostId",
                    deviceName = "Pixel",
                    token = null,
                    sessions = emptyList(),
                    capabilities = listOf("create", "credential"),
                    hostPlatform = "darwin",
                    folders = listOf("/Users/asad/work"),
                )
            )
        }

        fun drop() {
            _state.value = TransportState.Waiting("Reconnecting…", retryAt = null, attempts = 1)
        }

        /** Git over there needs a login. */
        fun ask(
            id: String,
            repo: String? = "asadev/terminaldeck",
            operation: CredentialOperation = CredentialOperation.Write,
            prompt: Boolean = true,
        ) {
            _incoming.tryEmit(
                ServerMessage.CredentialRequest(
                    id = id,
                    host = "github.com",
                    repo = repo,
                    operation = operation,
                    prompt = prompt,
                )
            )
        }

        val credentialFrames: List<ClientMessage>
            get() = sent.filter {
                it is ClientMessage.CredentialAck ||
                    it is ClientMessage.CredentialAnswer ||
                    it is ClientMessage.CredentialDeny
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

    private companion object {
        const val MAC = "M9G95TNJT64Q928VW3HVRYDR8J"
        const val PC = "K3ZQW7BHTM4RN8DXVYP2SJ6LC5"
    }

    private lateinit var vault: DeviceVault
    private lateinit var accounts: InMemoryGitHubStore
    private lateinit var transports: MutableMap<String, ScriptedTransport>
    private lateinit var deck: DeckViewModel

    @Before
    fun setUp() {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        vault = InMemoryDeviceVault()
        accounts = InMemoryGitHubStore()
        accounts.connect("asadev", "gho_secret", GitHubAccount.Source.SignIn)
        transports = mutableMapOf()
        deck = DeckViewModel(
            vault = vault,
            clipboard = FakeClipboard(),
            accounts = accounts,
            network = NetworkWatch.none,
            heartbeat = Heartbeat(scope = CoroutineScope(Dispatchers.Unconfined)),
            lookup = { typed, _ -> rendezvous[typed] },
        ) { _, hostId, store ->
            transports.getOrPut(hostId) { ScriptedTransport(hostId, store) }
        }
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    /**
     * The fake rendezvous: which machine is sitting behind which six digits.
     *
     * A code carries no address any more — the QR and the link that used to carry one are gone — so
     * pairing is two steps, and the first is a lookup at a relay. Stubbing it here is what keeps
     * this test off the network; `RendezvousTest` is where the derivation itself is checked.
     */
    private val rendezvous = mutableMapOf<String, Rendezvous.Offer>()
    private var nextCode = 482_910

    /** A fresh six-digit code for a machine, registered with the fake rendezvous. */
    private fun code(hostId: String): String {
        val digits = (nextCode++).toString().padStart(6, '0')
        rendezvous[digits] = Rendezvous.Offer("wss://relay.example", hostId, ByteArray(32) { 5 })
        return digits
    }

    private fun transport(hostId: String): ScriptedTransport = requireNotNull(transports[hostId])

    private fun pairAndConnect(hostId: String) {
        deck.pair(code(hostId))
        transport(hostId).goLive()
    }

    /* ------------------------------------------------------------------------ */

    @Test
    fun `a push question reaches the screen with the machine that asked named on it`() {
        pairAndConnect(MAC)
        deck.rename(MAC, "Studio")
        transport(MAC).ask("req-1")

        val prompt = deck.uiState.value.credentialPrompt
        assertEquals("req-1", prompt?.id)
        // The line the whole prompt turns on.
        assertEquals("Studio", prompt?.machineName)
        assertEquals("asadev/terminaldeck", prompt?.repo)
        assertEquals("github.com", prompt?.origin)
        // Acknowledged before anything was decided, which is what stops the desktop's short
        // reachability deadline firing on a phone that is right here.
        assertEquals(
            listOf<ClientMessage>(ClientMessage.CredentialAck("req-1")),
            transport(MAC).credentialFrames,
        )
    }

    @Test
    fun `a read never reaches the screen and is answered on its own socket`() {
        pairAndConnect(MAC)
        transport(MAC).ask("req-1", operation = CredentialOperation.Read, prompt = false)

        assertNull(deck.uiState.value.credentialPrompt)
        assertEquals(
            listOf<ClientMessage>(
                ClientMessage.CredentialAck("req-1"),
                ClientMessage.CredentialAnswer("req-1", "asadev", "gho_secret", remember = false),
            ),
            transport(MAC).credentialFrames,
        )
    }

    @Test
    fun `the answer goes back to the machine that asked, not the one on screen`() {
        pairAndConnect(MAC)
        pairAndConnect(PC)
        // Pairing selects the machine just paired, so the PC is what the screens are showing.
        assertEquals(PC, deck.uiState.value.selectedHostId)

        transport(MAC).ask("req-1")
        deck.approveCredential(remember = true)

        assertTrue(
            "the PC asked nothing and must be told nothing",
            transport(PC).credentialFrames.isEmpty(),
        )
        assertEquals(
            listOf<ClientMessage>(
                ClientMessage.CredentialAck("req-1"),
                ClientMessage.CredentialAnswer("req-1", "asadev", "gho_secret", remember = true),
            ),
            transport(MAC).credentialFrames,
        )
    }

    @Test
    fun `denying sends a refusal and clears the screen`() {
        pairAndConnect(MAC)
        transport(MAC).ask("req-1")
        deck.denyCredential()

        assertNull(deck.uiState.value.credentialPrompt)
        assertEquals(
            ClientMessage.CredentialDeny("req-1", CredentialDenial.Denied),
            transport(MAC).credentialFrames.last(),
        )
    }

    @Test
    fun `with no account connected the question is refused rather than drawn`() {
        accounts.disconnect()
        pairAndConnect(MAC)
        transport(MAC).ask("req-1")

        assertNull("nobody can approve with no account to approve with", deck.uiState.value.credentialPrompt)
        assertEquals(
            ClientMessage.CredentialDeny("req-1", CredentialDenial.NoAccount),
            transport(MAC).credentialFrames.last(),
        )
    }

    @Test
    fun `a question whose machine drops off comes off the screen`() {
        pairAndConnect(MAC)
        transport(MAC).ask("req-1")
        assertEquals("req-1", deck.uiState.value.credentialPrompt?.id)

        transport(MAC).drop()

        // The reply has nowhere to go, so three buttons that answer nothing must not stay up.
        assertNull(deck.uiState.value.credentialPrompt)
    }

    @Test
    fun `forgetting a machine takes its question with it`() {
        pairAndConnect(MAC)
        transport(MAC).ask("req-1")
        deck.forget(MAC)

        assertNull(deck.uiState.value.credentialPrompt)
    }

    @Test
    fun `disconnecting GitHub is the revocation that works from here`() {
        pairAndConnect(MAC)
        deck.disconnectGitHub()
        transport(MAC).ask("req-1")

        assertNull(deck.uiState.value.gitHubAccount)
        assertEquals(
            ClientMessage.CredentialDeny("req-1", CredentialDenial.NoAccount),
            transport(MAC).credentialFrames.last(),
        )
    }

    @Test
    fun `the account is on the state the prompt reads`() {
        pairAndConnect(MAC)
        assertEquals("asadev", deck.uiState.value.gitHubAccount?.login)
        // And never the token: nothing on screen has any business holding the bytes that grant a
        // push.
        assertTrue(!deck.uiState.value.gitHubAccount.toString().contains("gho_secret"))
    }
}
