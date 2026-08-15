package dev.terminaldeck.android

import dev.terminaldeck.android.github.InMemoryGitHubStore
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
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Where this phone may start a session, and where that answer comes from.
 *
 * The bug, in the owner's words: the picker showed **one folder** and there was no way to find out
 * why. The list was assembled here, out of the working directories of whatever sessions the phone
 * could see — so nobody had chosen it, it changed when a project was closed at the desk, and it was
 * not the set the machine would actually have accepted.
 *
 * The machine now decides, per device, and says so twice: in `welcome.folders` and again in a pushed
 * `folders` frame when somebody edits the list. These tests are that pair of frames arriving, plus
 * the three answers being kept apart:
 *
 *  - a **granted list** is the picker, and what is running has no say in it any more;
 *  - an **empty list** is a person having removed every folder, so New Session goes away and a
 *    sentence naming the machine and the screen takes its place;
 *  - **no field at all** is a machine older than the feature, and it keeps every phone paired to one
 *    working exactly as it did — the failure that would be worse than the bug.
 *
 * Driven through a scripted transport, like `MultiHostTest`, because these are questions about which
 * frame lands where rather than about a socket. The double is a second, smaller one rather than that
 * file's: it needs to push a mid-connection frame, which nothing over there does, and sharing it
 * would mean widening a test double for a test that is not about multi-host at all.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class FolderGrantTest {

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

        /**
         * Come up and be let in.
         *
         * `folders = null` is the default and it is doing work: it is what every desktop released
         * before the grant list sends, so unless a test says otherwise this file runs against a
         * machine that never mentions folders.
         */
        fun goLive(
            sessions: List<RemoteSession> = emptyList(),
            folders: List<String>? = null,
            capabilities: List<String> = listOf("create"),
        ) {
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
                    hostPlatform = "darwin",
                    folders = folders,
                )
            )
        }

        /** Somebody edited this device's folders at the desk, with the phone still connected. */
        fun pushFolders(folders: List<String>) {
            _incoming.tryEmit(ServerMessage.Folders(folders))
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
    }

    private lateinit var vault: DeviceVault
    private lateinit var transports: MutableMap<String, ScriptedTransport>
    private lateinit var deck: DeckViewModel

    @Before
    fun setUp() {
        // Unconfined, so a frame has been handled by the time the line that emitted it returns.
        Dispatchers.setMain(UnconfinedTestDispatcher())
        vault = InMemoryDeviceVault()
        transports = mutableMapOf()
        deck = DeckViewModel(
            vault = vault,
            clipboard = FakeClipboard(),
            accounts = InMemoryGitHubStore(),
            network = NetworkWatch.none,
            heartbeat = Heartbeat(scope = CoroutineScope(Dispatchers.Unconfined)),
        ) { _, hostId, store ->
            transports.getOrPut(hostId) { ScriptedTransport(hostId, store) }
        }
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
    }

    private fun code(hostId: String): String {
        val key = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32) { 5 })
        return "terminaldeck://pair#v=1&r=wss://relay.example&h=$hostId&k=$key&t=pair-$hostId"
    }

    private fun session(id: String, cwd: String) =
        RemoteSession(id = id, title = id, cwd = cwd, provider = "claude", status = "running")

    private fun transport(): ScriptedTransport = requireNotNull(transports[MAC])

    private val state get() = deck.uiState.value

    private fun pairAndGoLive(sessions: List<RemoteSession> = emptyList(), folders: List<String>? = null) {
        deck.pair(code(MAC))
        transport().goLive(sessions = sessions, folders = folders)
    }

    /* ------------------------------------------------------- the granted list is the picker -- */

    @Test
    fun `the picker is the list the machine granted, in the order it sent`() {
        pairAndGoLive(folders = listOf("/Users/asad/Projects/site", "/Users/asad/Projects/api"))

        assertEquals(
            listOf("/Users/asad/Projects/site", "/Users/asad/Projects/api"),
            state.startableFolders,
        )
        assertTrue(state.canStartSession)
    }

    /**
     * The defect itself, stated as a test.
     *
     * The old picker *was* the session list wearing a different hat. A machine that has granted one
     * folder while three sessions run elsewhere must offer the one folder — anything else is the
     * picker and the rule disagreeing again, which is what nobody could explain.
     */
    @Test
    fun `what is running has no say once the machine has granted a list`() {
        pairAndGoLive(
            sessions = listOf(
                session("s1", "/Users/asad/Projects/api"),
                session("s2", "/Users/asad/Projects/site"),
                session("s3", "/Users/asad/other"),
            ),
            folders = listOf("/Users/asad/Projects/tools"),
        )

        assertEquals(listOf("/Users/asad/Projects/tools"), state.startableFolders)
        assertEquals("/Users/asad/Projects/tools", state.onlyGrantedFolder)
    }

    @Test
    fun `the menu offers the granted folders and nothing else`() {
        pairAndGoLive(
            sessions = listOf(session("s1", "/Users/asad/other")),
            folders = listOf("/Users/asad/Projects/site", "/Users/asad/Projects/api"),
        )

        assertEquals(
            listOf(
                FolderChoice("/Users/asad/Projects/site", "/Users/asad/Projects/site"),
                FolderChoice("/Users/asad/Projects/api", "/Users/asad/Projects/api"),
            ),
            state.folderChoices,
        )
        // No "where the machine would" row: with a granted list it is the first folder under another
        // name, so it would be one destination drawn twice with the vaguer copy on top.
        assertTrue(state.folderChoices.all { it.isPath })
    }

    @Test
    fun `an older machine keeps its own default at the top of the menu`() {
        pairAndGoLive(sessions = listOf(session("s1", "/Users/asad/Projects/api")))

        assertEquals(
            listOf(
                FolderChoice("Where the Mac would", null),
                FolderChoice("/Users/asad/Projects/api", "/Users/asad/Projects/api"),
            ),
            state.folderChoices,
        )
        // The sentence is not a path and must not be set like one.
        assertFalse(state.folderChoices.first().isPath)
    }

    /* -------------------------------------------------------------- the pushed frame lands -- */

    /**
     * A folder removed at the desk leaves the picker without anybody reconnecting.
     *
     * The rule is already live without this — the machine consults its own list on every `create` —
     * so what would be lost is only honesty: the phone would keep drawing a folder whose one
     * possible outcome is a refusal until the app was quit and reopened.
     */
    @Test
    fun `a pushed folders frame changes the picker on a connection that is already up`() {
        pairAndGoLive(folders = listOf("/Users/asad/Projects/site", "/Users/asad/Projects/api"))

        transport().pushFolders(listOf("/Users/asad/Projects/api"))

        assertEquals(listOf("/Users/asad/Projects/api"), state.startableFolders)
        assertTrue(state.canStartSession)
    }

    @Test
    fun `a pushed frame can grant folders to a phone that had none`() {
        pairAndGoLive(folders = emptyList())
        assertFalse(state.canStartSession)

        transport().pushFolders(listOf("/Users/asad/Projects/api"))

        assertTrue(state.canStartSession)
        assertEquals(listOf("/Users/asad/Projects/api"), state.startableFolders)
    }

    /* ------------------------------------------------------------- empty is its own answer -- */

    @Test
    fun `removing the last folder takes New Session away rather than leaving one that fails`() {
        pairAndGoLive(
            sessions = listOf(session("s1", "/Users/asad/Projects/api")),
            folders = listOf("/Users/asad/Projects/api"),
        )
        assertTrue(state.canStartSession)

        transport().pushFolders(emptyList())

        assertTrue("the machine can still start sessions — it has just been given nowhere", state.canCreateSessions)
        assertFalse("so the button goes, rather than becoming one that is always refused", state.canStartSession)
        assertTrue(state.noFoldersGranted)
        // And emphatically not the old behaviour: a session is running in that folder, and falling
        // back to it here would offer the very folder somebody has just taken away.
        assertEquals(emptyList<String>(), state.startableFolders)
    }

    /** The screen has to explain itself, because the remedy is on a machine that is not in hand. */
    @Test
    fun `the empty state names the machine and where the folders are chosen`() {
        pairAndGoLive(folders = emptyList())

        val sentence = state.noFoldersSentence
        assertTrue(sentence, sentence.contains("Mac"))
        assertTrue(sentence, sentence.contains("Remote access"))
    }

    @Test
    fun `asking anyway is answered here rather than by a round trip that fails`() {
        pairAndGoLive(folders = emptyList())

        deck.newSession(null)

        assertTrue("nothing may be sent", transport().sent.none { it is ClientMessage.Create })
        assertEquals(state.noFoldersSentence, state.notice)
    }

    /* ------------------------------------------------------- an older machine still works -- */

    /**
     * The failure that would be worse than the bug.
     *
     * Two phones were paired before any of this existed. A client that read "no field" as "no
     * folders" would take New Session away from every one of them, and the refusal would appear on a
     * phone while the fix lived on a desktop in another room.
     */
    @Test
    fun `a machine too old to send the field keeps the behaviour it had`() {
        pairAndGoLive(
            sessions = listOf(
                session("s1", "/Users/asad/Projects/api"),
                session("s2", "/Users/asad/Projects/api"),
                session("s3", "/Users/asad/Projects/site"),
            ),
        )

        assertNull(state.grantedFolders)
        assertEquals(
            listOf("/Users/asad/Projects/api", "/Users/asad/Projects/site"),
            state.startableFolders,
        )
        assertTrue(state.canStartSession)
        assertFalse("nothing here was chosen by anybody, so it is not described as a grant", state.noFoldersGranted)
        assertNull(state.onlyGrantedFolder)
    }

    @Test
    fun `an old machine with nothing running still starts a session where it would have`() {
        pairAndGoLive()

        assertTrue(state.canStartSession)
        assertEquals(emptyList<String>(), state.startableFolders)

        deck.newSession(null)

        assertEquals(listOf(ClientMessage.Create()), transport().sent.filterIsInstance<ClientMessage.Create>())
    }

    /**
     * A downgrade is a machine with no opinion again, not a machine that revoked everything.
     *
     * Reachable in the ordinary way: install an older build over a newer one, or roll a release back.
     * Holding the last granted list would leave this phone enforcing a rule the machine has stopped
     * having.
     */
    @Test
    fun `a welcome without the field clears a list an earlier one granted`() {
        pairAndGoLive(folders = listOf("/Users/asad/Projects/api"))
        transport().goLive(sessions = listOf(session("s1", "/Users/asad/Projects/site")))

        assertNull(state.grantedFolders)
        assertEquals(listOf("/Users/asad/Projects/site"), state.startableFolders)
    }

    /* ------------------------------------------------------------------- what is sent out -- */

    @Test
    fun `starting in a granted folder sends that folder`() {
        pairAndGoLive(folders = listOf("/Users/asad/Projects/api", "/Users/asad/Projects/site"))

        deck.newSession("/Users/asad/Projects/site")

        assertEquals(
            listOf(ClientMessage.Create(cwd = "/Users/asad/Projects/site")),
            transport().sent.filterIsInstance<ClientMessage.Create>(),
        )
    }
}
