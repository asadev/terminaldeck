package dev.terminaldeck.android

import android.graphics.Color
import android.os.Bundle
import android.provider.OpenableColumns
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import dev.terminaldeck.android.protocol.HostPlatform
import dev.terminaldeck.android.transfer.PickedFile
import dev.terminaldeck.android.ui.CredentialPromptSheet
import dev.terminaldeck.android.ui.DevicesScreen
import dev.terminaldeck.android.ui.GitHubSheet
import dev.terminaldeck.android.ui.PairingScreen
import dev.terminaldeck.android.ui.ServerSettingsScreen
import dev.terminaldeck.android.ui.SessionListScreen
import dev.terminaldeck.android.ui.TerminalScreen
import dev.terminaldeck.android.ui.theme.TerminalDeckTheme

class MainActivity : ComponentActivity() {

    private var onResumed: (() -> Unit)? = null

    /*
     * There is no pairing-link intent any more, and its absence is the change.
     *
     * `terminaldeck://pair#h=…&k=…&t=…` used to arrive here — from a QR code, from a tap in a
     * message — and be handed to `DeckViewModel.pair`. The QR did not work, and the link was a live
     * bearer token in a string that any app registered for the scheme could have been handed. Both
     * are gone, along with the `<intent-filter>` in AndroidManifest.xml: pairing is six digits
     * somebody reads off the machine and types, and there is no second door.
     */

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Both bars declared dark with a transparent scrim. The default asks the system to pick,
        // and the system picks from the *system* light/dark setting — which on a light phone puts
        // a white navigation bar under a black terminal.
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        setContent {
            TerminalDeckTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    TerminalDeckApp(onRegisterResume = { onResumed = it })
                }
            }
        }
    }

    /**
     * Reconnect when the app comes back.
     *
     * A phone that has been in a pocket has almost certainly lost the socket — the radio slept, the
     * NAT entry was reclaimed, the relay gave up on a peer that stopped answering pings. Waiting
     * out the backoff step at that point means the user watches a dead terminal for up to twenty
     * seconds after unlocking, so the schedule is reset here instead. The transport refuses this in
     * the states where retrying is harmful, so this cannot hammer a Mac that has refused the
     * credential.
     */
    override fun onStart() {
        super.onStart()
        onResumed?.invoke()
    }

}

private const val ROUTE_SESSIONS = "sessions"

/**
 * A terminal route names the machine as well as the session.
 *
 * Session ids are unique on the computer that minted one and nothing makes them unique *across* two
 * of them — they come from each machine's own session layer. A route carrying only an id would
 * attach to whichever machine happened to be on screen when it was popped, which with two paired is
 * a coin flip, and the wrong side of it types into the wrong computer.
 */
private const val ROUTE_TERMINAL = "terminal/{hostId}/{sessionId}"
private const val ARG_HOST_ID = "hostId"
private const val ARG_SESSION_ID = "sessionId"

/**
 * Devices and This-server act on whichever machine is selected — the same machine the session list
 * is showing — so they are plain routes without an id in them. If the selection changes underneath
 * to a machine that does not serve one, the screen reads a null view and pops itself, the same way
 * the terminal route handles a session that has gone.
 */
private const val ROUTE_DEVICES = "devices"
private const val ROUTE_SETTINGS = "server-settings"

@Composable
fun TerminalDeckApp(
    onRegisterResume: (() -> Unit) -> Unit = {},
    viewModel: DeckViewModel = viewModel(factory = DeckViewModel.factory(LocalContext.current)),
) {
    val navController = rememberNavController()
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val screenTick by viewModel.screenTick.collectAsStateWithLifecycle()
    val context = LocalContext.current
    /**
     * Whether the GitHub sheet is up.
     *
     * A flag here rather than a route, for the same reason the credential prompt is not one: it is
     * about the phone rather than about the machine on screen, and it has to be openable from the
     * switcher, which is itself drawn above whatever route is current.
     */
    var github by remember { mutableStateOf(false) }

    onRegisterResume { viewModel.resume() }

    /*
     * Open a session the machine has just started for this phone.
     *
     * In an effect for the same reason the pairing link is: navigating from inside a frame handler
     * would be a mutation in the middle of the frame that produced it, and `popBackStack` done that
     * way has already been seen to leave a black rectangle with no bar on it. Cleared afterwards, so
     * a rotation does not push the same session twice.
     */
    val created by viewModel.created.collectAsStateWithLifecycle()
    LaunchedEffect(created) {
        val request = created ?: return@LaunchedEffect
        navController.navigate("terminal/${request.hostId}/${request.sessionId}")
        viewModel.createdHandled()
    }

    /*
     * Picking a photo, a video or a file — and the permissions this app deliberately does not hold.
     *
     * `PickVisualMedia` is the **system photo picker**. It runs in another process, shows the user
     * their own library, and hands back a URI for exactly what they chose. Because this app never
     * sees the library it needs no `READ_MEDIA_IMAGES` / `READ_MEDIA_VIDEO`, and on API 30–32 the
     * contract falls back to a Play-services-backed picker with the same property. The old route —
     * `ACTION_PICK` plus a storage permission — would put a scary runtime prompt in front of someone
     * for a feature they may never use, and would make this a "reads your photos" app in the store
     * listing. That is not a preference; it is the reason this design was chosen.
     *
     * `OpenDocument` is the storage access framework, which is the same bargain for everything that
     * is not a photo: another process, one URI, no permission.
     *
     * Both are launched here rather than from the view model, because an
     * `ActivityResultLauncher` belongs to a composition, and a view model that owned one would
     * outlive the activity it was registered against.
     */
    val send: (android.net.Uri?) -> Unit = { uri ->
        if (uri != null) {
            val picked = describe(context.contentResolver, uri)
            if (picked == null) {
                // Rare, and worth saying rather than doing nothing: a provider that will not answer
                // `OpenableColumns` is one this app cannot get a size out of, and without a size
                // there is no progress bar and no up-front refusal of an enormous file.
                viewModel.noteFileUnreadable()
            } else {
                viewModel.sendFile(picked) {
                    context.contentResolver.openInputStream(uri)
                        ?: throw java.io.IOException("the picker's URI could not be opened")
                }
            }
        }
    }
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia(), send)
    val documentPicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument(), send)
    /*
     * The credential prompt and the GitHub sheet sit *above* everything else, including the pair
     * screen.
     *
     * Not a navigation destination and not a child of one route, because neither is about the
     * screen underneath. A machine can ask this phone for a login at any moment — while a terminal
     * is open, while the session list is up, or while somebody is on the pair screen adding a
     * second machine — and a `git push` is waiting on the answer. A prompt that could only appear
     * on one route would be a prompt that silently fails to appear on the others.
     */
    Box(modifier = Modifier.fillMaxSize()) {

    /*
     * The pair screen owns the window while the machine on screen has not admitted this device —
     * which covers "nothing is paired at all", because then there is no machine on screen — and
     * while the user is adding another one.
     *
     * Not a navigation destination: an unpaired app has nothing behind the pair screen to go back
     * to, and a back stack entry that leads to an empty session list is a trap. Once one machine has
     * been let in there *is* somewhere to go back to, and that is what `onCancel` is.
     */
    if (state.needsPairing) {
        PairingScreen(
            state = state,
            onPair = viewModel::pair,
            onForget = viewModel::forgetSelected,
            onRetry = viewModel::reconnect,
            onCancel = if (state.canLeavePairing) viewModel::cancelAddingHost else null,
        )
    } else {

    NavHost(navController = navController, startDestination = ROUTE_SESSIONS) {
        composable(ROUTE_SESSIONS) {
            SessionListScreen(
                state = state,
                onOpen = { session ->
                    // The machine travels with the session, taken from the state that produced the
                    // row rather than looked up again later — by then it could be a different one.
                    state.host?.let { host -> navController.navigate("terminal/${host.hostId}/${session.id}") }
                },
                onRefresh = viewModel::refresh,
                onReconnect = viewModel::reconnect,
                onNewSession = viewModel::newSession,
                onSelectHost = viewModel::select,
                onRenameHost = viewModel::rename,
                onForgetHost = viewModel::forget,
                onAddHost = viewModel::beginAddingHost,
                onCloseSession = { session -> viewModel.endSession(session.id) },
                // The read is triggered by the screen itself, keyed on the live connection, so it
                // also re-reads if the socket drops and returns while the screen is open.
                onDevices = { navController.navigate(ROUTE_DEVICES) },
                onServerSettings = { navController.navigate(ROUTE_SETTINGS) },
                gitHubLogin = state.gitHubAccount?.login,
                onGitHub = { github = true },
            )
        }

        composable(ROUTE_DEVICES) {
            // The selected machine's roster. Null when the machine on screen does not serve one —
            // which can happen if the selection changed to an older machine while this was open — so
            // it pops itself rather than showing an empty shell, the terminal route's own rule.
            val view = state.devices
            if (view == null) {
                LaunchedEffect(Unit) { navController.popBackStack() }
                return@composable
            }
            // Read on entry, and again if the socket drops and comes back while this is open — a
            // no-op when the roster is already in hand. See DeviceRosterController.ensureRead.
            LaunchedEffect(state.live) { if (state.live) viewModel.openDevices() }
            DevicesScreen(
                view = view,
                machineLabel = state.hostLabel,
                onBack = { navController.popBackStack() },
                onRefresh = viewModel::refreshDevices,
                onRevoke = viewModel::revokeDevice,
            )
        }

        composable(ROUTE_SETTINGS) {
            val view = state.serverSettings
            if (view == null) {
                LaunchedEffect(Unit) { navController.popBackStack() }
                return@composable
            }
            LaunchedEffect(state.live) { if (state.live) viewModel.openServerSettings() }
            ServerSettingsScreen(
                view = view,
                machineLabel = state.hostLabel,
                onBack = { navController.popBackStack() },
                onApply = viewModel::applyServerSetting,
            )
        }

        composable(
            route = ROUTE_TERMINAL,
            arguments = listOf(
                navArgument(ARG_HOST_ID) { type = NavType.StringType },
                navArgument(ARG_SESSION_ID) { type = NavType.StringType },
            ),
        ) { entry ->
            val hostId = entry.arguments?.getString(ARG_HOST_ID)
            val sessionId = entry.arguments?.getString(ARG_SESSION_ID)
            // Looked up in the machine the route names rather than in whatever is on screen. Those
            // are the same thing by the frame after `open`, and are not on the frame of it.
            val host = state.hosts.firstOrNull { it.hostId == hostId }
            val known = host?.sessions?.firstOrNull { it.id == sessionId }
            val binding = if (hostId != null && sessionId != null) viewModel.open(hostId, sessionId) else null

            /*
             * The noun for *this route's* machine, not for whichever one is selected.
             *
             * The two are the same the moment after a session is opened and are not the same on a
             * phone with a Mac and a PC in its switcher, which is precisely the case that produced
             * the bug this field exists to end. Falls back to the neutral word when the route names
             * a machine that has been forgotten — by then there is nothing left to ask.
             */
            val hostNoun = host?.hostPlatform?.noun ?: HostPlatform.UNKNOWN.noun

            // The route arguments are strings from the back stack, and the back stack survives
            // process death, a machine restart and a machine being forgotten — so an id that no
            // longer names anything is a normal thing to arrive with, not a bug to crash on.
            //
            // The pop happens in an effect rather than inline. Calling `popBackStack` *during*
            // composition is a mutation in the middle of the frame that produced it: the
            // navigation does not take, this composable returns nothing, and what is left on
            // screen is a black rectangle with no bar, no keys and no explanation. That is
            // exactly what happened the first time the Mac was restarted underneath the app.
            if (hostId == null || binding == null || known == null) {
                LaunchedEffect(hostId, sessionId) {
                    hostId?.let(viewModel::closeSession)
                    navController.popBackStack()
                }
                LeavingSession(hostNoun)
                return@composable
            }

            TerminalScreen(
                binding = binding,
                title = known.title,
                subtitle = known.cwd,
                screenTick = screenTick,
                transport = state.transport,
                hostNoun = hostNoun,
                onBack = {
                    viewModel.closeSession(hostId)
                    navController.popBackStack()
                },
                onKey = { text -> viewModel.type(hostId, text) },
                onCopy = { selection -> viewModel.copy(hostId, selection) },
                onPaste = { viewModel.paste(hostId) },
                canSendFiles = state.canSendFiles,
                onSendPhoto = {
                    photoPicker.launch(
                        PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)
                    )
                },
                // Everything, because the point is handing a file to an agent and there is no
                // useful subset of "a file a developer might want on their machine". A filter here
                // would grey out the one thing somebody came to send.
                onSendFile = { documentPicker.launch(arrayOf("*/*")) },
                upload = state.upload,
                onCancelUpload = viewModel::cancelUpload,
                onDismissUpload = viewModel::dismissUpload,
                notice = state.notice,
            )
        }
    }

    } // end of the paired branch; the sheets below are drawn over either one

    /*
     * The one screen that is the entire explanation of the credential proxy.
     *
     * Only ever a request the desktop asked this phone to *prompt* about — a push, against a
     * repository this device has not already approved on that machine. Reads and approved pushes
     * are answered without anything reaching here, which is the policy and is why this is null
     * almost always.
     */
    state.credentialPrompt?.let { question ->
        CredentialPromptSheet(
            question = question,
            account = state.gitHubAccount,
            queued = state.credentialsQueued,
            onApprove = viewModel::approveCredential,
            onDeny = viewModel::denyCredential,
        )
    }

    if (github) {
        GitHubSheet(
            account = state.gitHubAccount,
            phase = state.signInPhase,
            signIn = viewModel.signIn,
            onDisconnect = viewModel::disconnectGitHub,
            onDismiss = { github = false },
        )
    }

    } // end of the Box the sheets are stacked in
}

/**
 * A picked URI's name and size, or null when the provider will not say.
 *
 * `OpenableColumns` is the contract every picker on Android honours, and it is the only way to learn
 * a size without reading the whole stream — which matters here because the size is what the progress
 * bar is a fraction of, and what lets an oversized file be refused before a byte moves.
 *
 * The name is a suggestion and is treated as one: the desktop reduces whatever arrives to a single
 * safe path component and picks the real name. This does not try to sanitise it, because a client that
 * sanitised it would be a second, weaker copy of a rule that already exists on the other end.
 */
private fun describe(resolver: android.content.ContentResolver, uri: android.net.Uri): PickedFile? {
    val projection = arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
    resolver.query(uri, projection, null, null, null)?.use { cursor ->
        if (!cursor.moveToFirst()) return null
        val nameAt = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
        val sizeAt = cursor.getColumnIndex(OpenableColumns.SIZE)
        val name = if (nameAt >= 0 && !cursor.isNull(nameAt)) cursor.getString(nameAt) else null
        val size = if (sizeAt >= 0 && !cursor.isNull(sizeAt)) cursor.getLong(sizeAt) else -1L
        if (size <= 0) return null
        return PickedFile(name = name?.takeIf { it.isNotBlank() } ?: uri.lastPathSegment ?: "file", size = size)
    }
    return null
}

/**
 * The one frame between "that session is gone" and the session list.
 *
 * Says so, rather than showing an empty window: the effect that pops the back stack runs after
 * this composition, and a blank screen in between reads as a crash.
 */
@Composable
private fun LeavingSession(hostNoun: String) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = "That session is no longer on the $hostNoun.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
