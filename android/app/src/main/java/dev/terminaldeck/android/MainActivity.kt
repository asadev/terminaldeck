package dev.terminaldeck.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import dev.terminaldeck.android.ui.PairingScreen
import dev.terminaldeck.android.ui.SessionListScreen
import dev.terminaldeck.android.ui.TerminalScreen
import dev.terminaldeck.android.ui.theme.TerminalDeckTheme
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class MainActivity : ComponentActivity() {

    private var onResumed: (() -> Unit)? = null

    /**
     * A pairing link that has arrived and not yet been acted on.
     *
     * A flow rather than a direct call into the view model, because the view model does not exist
     * when `onCreate` reads the intent — it is created by `viewModel()` inside the composition. The
     * link therefore waits here until something is collecting, which also makes the cold-start and
     * `onNewIntent` paths identical instead of two orderings to get right.
     *
     * Cleared by the collector once it has been handled, so a configuration change does not re-pair
     * with a token that has already been spent.
     */
    private val pairingLink = MutableStateFlow<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Cold start: the app was launched *by* the link.
        pairingLink.value = pairingLinkIn(intent)
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
                    TerminalDeckApp(
                        onRegisterResume = { onResumed = it },
                        pairingLinks = pairingLink,
                        onPairingLinkHandled = { pairingLink.value = null },
                    )
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

    /**
     * A pairing link that arrived while the app was already running.
     *
     * `launchMode="singleTask"` means the existing instance is reused rather than a second one
     * created, so this — not `onCreate` — is where every link after the first lands. `setIntent` is
     * not decoration: without it `getIntent()` keeps answering with the launch intent, so anything
     * that reads it later (a rotation, a restore) would replay the *old* link.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        pairingLinkIn(intent)?.let { pairingLink.value = it }
    }

    /**
     * The link out of an intent, or null.
     *
     * Only `VIEW` intents with data, and only the scheme this app declares. Nothing is validated
     * beyond that here — `PairingCodes.parse` is the one place a code is believed — but a launcher
     * intent must not be mistaken for a pairing attempt, and an intent from some other filter is
     * not this app's business.
     */
    private fun pairingLinkIn(intent: Intent?): String? {
        if (intent?.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        if (!data.scheme.equals(PAIRING_SCHEME, ignoreCase = true)) return null
        return data.toString()
    }

    private companion object {
        /** Matches the `<data android:scheme>` in AndroidManifest.xml. */
        const val PAIRING_SCHEME = "terminaldeck"
    }
}

private const val ROUTE_SESSIONS = "sessions"
private const val ROUTE_TERMINAL = "terminal/{sessionId}"
private const val ARG_SESSION_ID = "sessionId"

@Composable
fun TerminalDeckApp(
    onRegisterResume: (() -> Unit) -> Unit = {},
    /** Pairing links from `terminaldeck://pair…`, cold start and `onNewIntent` alike. */
    pairingLinks: StateFlow<String?> = MutableStateFlow(null),
    onPairingLinkHandled: () -> Unit = {},
    viewModel: DeckViewModel = viewModel(factory = DeckViewModel.factory(LocalContext.current)),
) {
    val navController = rememberNavController()
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val screenTick by viewModel.screenTick.collectAsStateWithLifecycle()
    val link by pairingLinks.collectAsStateWithLifecycle()
    val context = LocalContext.current

    onRegisterResume { viewModel.resume() }

    /*
     * Pair from a link.
     *
     * In an effect rather than inline: `pair` writes state the composition is reading, and calling
     * it during composition is a mutation in the middle of the frame that produced it. Keyed on the
     * link so the same one is not spent twice, and cleared afterwards so a rotation does not replay
     * a token that is already gone.
     */
    LaunchedEffect(link) {
        val raw = link ?: return@LaunchedEffect
        viewModel.pair(raw)
        onPairingLinkHandled()
    }

    /*
     * The camera, and the two-step dance Android requires for it.
     *
     * ZXing's `ScanContract` launches its own capture activity, which needs the permission already
     * granted — so the permission request comes first and the scanner is launched from its result.
     * Asking at startup instead would be a camera prompt in front of someone who may never pair by
     * QR at all, and the typed path exists precisely so the camera stays optional.
     */
    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        result.contents?.let(viewModel::pair)
    }
    val scanOptions = remember {
        ScanOptions()
            .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
            .setPrompt("Point the camera at the code on your Mac")
            .setBeepEnabled(false)
            .setOrientationLocked(false)
    }
    val cameraPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scanner.launch(scanOptions)
    }
    val startScan = {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            scanner.launch(scanOptions)
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    // The pair screen owns the window until a Mac has admitted this device at least once. Not a
    // navigation destination: an unpaired app has nothing behind the pair screen to go back to, and
    // a back stack entry that leads to an empty session list is a trap.
    if (state.needsPairing) {
        PairingScreen(
            state = state,
            onPair = viewModel::pair,
            onScan = startScan,
            onForget = viewModel::unpair,
            onRetry = viewModel::reconnect,
        )
        return
    }

    NavHost(navController = navController, startDestination = ROUTE_SESSIONS) {
        composable(ROUTE_SESSIONS) {
            SessionListScreen(
                state = state,
                onOpen = { session -> navController.navigate("terminal/${session.id}") },
                onRefresh = viewModel::refresh,
                onReconnect = viewModel::reconnect,
                onNewSession = viewModel::newSession,
                onUnpair = viewModel::unpair,
            )
        }

        composable(
            route = ROUTE_TERMINAL,
            arguments = listOf(navArgument(ARG_SESSION_ID) { type = NavType.StringType }),
        ) { entry ->
            val sessionId = entry.arguments?.getString(ARG_SESSION_ID)
            val known = state.sessions.firstOrNull { it.id == sessionId }

            // The route argument is a string from the back stack, and the back stack survives
            // process death and a Mac restart — so an id that no longer names a session in the
            // list is a normal thing to arrive with, not a bug to crash on.
            //
            // The pop happens in an effect rather than inline. Calling `popBackStack` *during*
            // composition is a mutation in the middle of the frame that produced it: the
            // navigation does not take, this composable returns nothing, and what is left on
            // screen is a black rectangle with no bar, no keys and no explanation. That is
            // exactly what happened the first time the Mac was restarted underneath the app.
            if (sessionId == null || known == null) {
                LaunchedEffect(sessionId) {
                    viewModel.closeCurrent()
                    navController.popBackStack()
                }
                LeavingSession()
                return@composable
            }

            val binding = viewModel.open(sessionId)
            TerminalScreen(
                binding = binding,
                title = known.title,
                subtitle = known.cwd,
                screenTick = screenTick,
                transport = state.transport,
                onBack = {
                    viewModel.closeCurrent()
                    navController.popBackStack()
                },
                onKey = viewModel::type,
                onCopy = viewModel::copyScreen,
                onPaste = viewModel::paste,
            )
        }
    }
}

/**
 * The one frame between "that session is gone" and the session list.
 *
 * Says so, rather than showing an empty window: the effect that pops the back stack runs after
 * this composition, and a blank screen in between reads as a crash.
 */
@Composable
private fun LeavingSession() {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = "That session is no longer on the Mac.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}
