package dev.terminaldeck.android

import android.graphics.Color
import android.graphics.drawable.ColorDrawable
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
import androidx.compose.runtime.mutableIntStateOf
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
import android.net.Uri
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.Badge
import androidx.compose.material3.BadgedBox
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.DisposableEffect
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.navigation
import dev.terminaldeck.android.protocol.BrowserSurfaceWire
import dev.terminaldeck.android.protocol.HostPlatform
import dev.terminaldeck.android.protocol.SessionControls
import dev.terminaldeck.android.ui.MachinesScreen
import dev.terminaldeck.android.ui.SessionControlsSheet
import dev.terminaldeck.android.ui.SettingsScreen
import dev.terminaldeck.android.ui.WatchSurfacesScreen
import dev.terminaldeck.android.ui.WatchViewerScreen
import dev.terminaldeck.android.transfer.PickedFile
import dev.terminaldeck.android.ui.HostStepCard
import dev.terminaldeck.android.ui.AlertsScreen
import dev.terminaldeck.android.ui.CopilotConsentSheet
import dev.terminaldeck.android.ui.CopilotScreen
import dev.terminaldeck.android.ui.CopilotSessionsSheet
import dev.terminaldeck.android.ui.AppearanceScreen
import dev.terminaldeck.android.ui.TerminalSchemeEditorScreen
import dev.terminaldeck.android.ui.TerminalSchemeScreen
import dev.terminaldeck.android.ui.ArchivedSessionsSheet
import dev.terminaldeck.android.ui.LocalhostBrowser
import dev.terminaldeck.android.ui.LocalhostScreen
import dev.terminaldeck.android.ui.SessionChatScreen
import dev.terminaldeck.android.ui.SessionDetailSheet
import dev.terminaldeck.android.ui.CredentialPromptSheet
import dev.terminaldeck.android.ui.DevicesScreen
import dev.terminaldeck.android.ui.GitHubSheet
import dev.terminaldeck.android.ui.PairingScreen
import dev.terminaldeck.android.ui.ServerLoginScreen
import dev.terminaldeck.android.ui.ServerLoginView
import dev.terminaldeck.android.ui.SessionListScreen
import dev.terminaldeck.android.ui.TerminalScreen
import androidx.compose.ui.platform.LocalConfiguration
import dev.terminaldeck.android.alerts.AlertCenter
import dev.terminaldeck.android.ui.theme.AppearanceStore
import dev.terminaldeck.android.ui.theme.DeckTheme
import dev.terminaldeck.android.ui.theme.TerminalDeckTheme
import dev.terminaldeck.android.ui.theme.currentAppearance
import dev.terminaldeck.android.ui.theme.TerminalSchemeStore
import dev.terminaldeck.android.ui.theme.currentTerminalScheme
import dev.terminaldeck.android.ui.theme.installTerminalPalette

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

        /*
         * The appearance is read before anything is drawn, and the window is painted from it.
         *
         * `values/themes.xml` and `values-night/themes.xml` already give the launch frame the right
         * colour *for the system setting*, which is the right answer for everyone who has left this
         * on System. It is the wrong answer for somebody who chose Light on a phone that is dark,
         * and the symptom is a black rectangle for one frame before a white app appears. Repainting
         * the window here closes that gap: this runs before `setContent`, so nothing has been drawn
         * yet and there is nothing to flash.
         */
        /*
         * The notification channels, declared before anything can post to one.
         *
         * On API 26 and up a notification naming a channel that does not exist is **dropped without a
         * word** — no crash, no log a person would see, just an alert that never arrives. Creating
         * one at post time instead would be a race with the very first alert, which is exactly the
         * alert somebody is waiting for. Idempotent, so this costs nothing on every later launch.
         *
         * Found by looking: the two switches on the Alerts screen were drawn, stored and read, and
         * nothing had ever registered a channel for what they gate — which is the "switch wired to
         * nothing" this app's design brief refuses.
         */
        AlertCenter.ensureChannels(this)

        val appearance = AppearanceStore.prime(this)
        val dark = appearance.isDark(resources.configuration)
        window.setBackgroundDrawable(ColorDrawable(deckWindowColor(dark)))

        /*
         * The terminal's palette, installed before the first session can be attached.
         *
         * The vendored emulator holds its colour scheme in process-wide static state and a session
         * copies from it at construction, so this has to happen before any session exists — and
         * again on every appearance *or* scheme change, which is what the effect below does.
         *
         * Both stores are primed first, in this order, because the scheme the terminal draws with
         * may be the reserved "match the app's appearance" choice — which is the default — and
         * resolving that needs the appearance to have been read already.
         */
        TerminalSchemeStore.prime(this)
        installTerminalPalette(TerminalSchemeStore.resolve(dark))

        setContent {
            TerminalDeckTheme {
                /*
                 * The system bars follow the theme, and they are re-declared whenever it changes.
                 *
                 * This used to be one `enableEdgeToEdge` pair in `onCreate` pinned to one
                 * appearance, which was correct for an app that was only ever dark and is a bug for
                 * one that is not: a light app under dark bar styles draws white icons on white.
                 * `enableEdgeToEdge` is idempotent and cheap, so calling it from an effect keyed on
                 * the resolved appearance is the documented way to keep it honest — `auto` picks
                 * the icon colour from the flag it is given rather than from the system setting,
                 * which is the distinction that matters for somebody who has chosen Light on a dark
                 * phone.
                 */
                val nowDark = currentAppearance().isDark(LocalConfiguration.current)
                val scrim = deckWindowColor(nowDark)
                /*
                 * Keyed on the scheme as well as the appearance, and it has to be: editing a
                 * colour changes neither the theme nor the choice, only the twenty-one values
                 * behind it, so an effect keyed on `nowDark` alone would not re-run and the change
                 * would appear on the *next* session rather than on the one being looked at.
                 */
                val terminalScheme = currentTerminalScheme(nowDark)
                DisposableEffect(nowDark, terminalScheme) {
                    enableEdgeToEdge(
                        statusBarStyle = SystemBarStyle.auto(Color.TRANSPARENT, Color.TRANSPARENT) { nowDark },
                        navigationBarStyle = SystemBarStyle.auto(scrim, scrim) { nowDark },
                    )
                    installTerminalPalette(terminalScheme)
                    onDispose { }
                }

                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = DeckTheme.colors.background,
                ) {
                    TerminalDeckApp(onRegisterResume = { onResumed = it })
                }
            }
        }
    }

    /**
     * `--bg-primary` as an `android.graphics` int.
     *
     * The one place in the app outside `ui/theme` that names a colour, and it has to be: the window
     * background is set on a `Window` before any composition exists, so there is no theme to ask.
     * It reads the same two hexes `Ink.background` carries and `PaletteParityTest` checks that they
     * still agree.
     */
    private fun deckWindowColor(dark: Boolean): Int = if (dark) 0xFF191919.toInt() else 0xFFFFFFFF.toInt()

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

/**
 * The two tabs, and why the app has a bottom bar at all.
 *
 * Asad, walking the phone app: *"here we need to give a proper menu. Maybe it's super basic
 * currently. Maybe we can have some tab bar and down here like a pill, something, so it's more easy
 * to use… let's make it proper simple with a bit more options."* Before this the whole Android app
 * was one list and one sheet, and everything that was not a session — the machine you are typing
 * into, the GitHub account, the device roster, the machine's own settings — lived behind a title
 * that had to be tapped to be discovered. Nine items in one sheet is not a menu, it is a drawer.
 *
 * Each tab is a **navigation graph** rather than a destination, which is what gives each one its own
 * back stack: pushing Machines inside Settings, switching to Sessions, opening a terminal and coming
 * back leaves Machines where it was. That is the Android shape of the per-tab `NavigationStack` iOS
 * uses, and `saveState`/`restoreState` on the tab hop is the whole of it.
 *
 * ## Four tabs, and the leftmost comes and goes
 *
 * iOS draws Copilot · Sessions · Localhost · Settings, the first of those only while the machine on
 * screen has a copilot this device may drive. This build draws **Sessions · Localhost · Settings**.
 *
 * Localhost is here now: the port list, the dev servers, and a real tunnel that serves one of the
 * machine's ports on this phone's own loopback at the same number, so a page's own absolute links
 * keep working.
 *
 * **Copilot is here too, and it is conditional.** *"If the copilot is not connecting, this icon
 * should not be inside the pill — then it will be three icon pill. Otherwise if the copilot is
 * connected, then four icon pill, automatically."* `DeckUiState.copilot` is null over a machine that
 * offers none to this phone, and the pill is simply absent — never an empty tab. It is added and
 * removed on the **left**, where the copilot lives, so the three that survive keep their order.
 */
private const val GRAPH_COPILOT = "graph.copilot"
private const val GRAPH_SESSIONS = "graph.sessions"
private const val GRAPH_LOCALHOST = "graph.localhost"
private const val GRAPH_SETTINGS = "graph.settings"

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
 * Everything under Settings acts on whichever machine is selected — the same machine the session
 * list is showing — so these are plain routes without an id in them. If the selection changes
 * underneath to a machine that does not serve one, the screen reads a null view and pops itself, the
 * same way the terminal route handles a session that has gone.
 */
private const val ROUTE_SETTINGS = "settings"
private const val ROUTE_MACHINES = "machines"
private const val ROUTE_DEVICES = "devices"
private const val ROUTE_WATCH = "watch"
private const val ROUTE_ALERTS = "alerts"
private const val ROUTE_APPEARANCE = "appearance"

/**
 * The terminal's colours, and one scheme of them.
 *
 * Nested under `appearance/` rather than sitting beside it, because that is where somebody looks for
 * it and because the back stack then reads the way the screens do: Settings, Appearance, Terminal
 * colours, one scheme.
 */
private const val ROUTE_TERMINAL_SCHEME = "appearance/terminal"
private const val ROUTE_TERMINAL_SCHEME_EDIT = "appearance/terminal/{schemeId}"
private const val ARG_SCHEME_ID = "schemeId"

/** The machine's ports and dev servers, and the page one of them is being served as. */
private const val ROUTE_LOCALHOST = "localhost"
private const val ROUTE_LOCALHOST_PAGE = "localhost/page"

/** The conversation of the session a terminal is showing, as bubbles rather than as a pty. */
private const val ROUTE_CHAT = "chat/{hostId}/{sessionId}"

/** The machine's own agent. The leftmost pill, drawn only while the machine offers one. */
private const val ROUTE_COPILOT = "copilot"

/**
 * One watched surface, full screen.
 *
 * The window name is in the route because it is what the cast is aimed at, and it is URL-encoded on
 * the way in: the front tab is the **empty string**, and a slot name is free text from the machine.
 * A path segment cannot be empty, so [WATCH_FRONT_TAB] stands in for it and is decoded back.
 */
private const val ROUTE_WATCH_VIEW = "watch/{window}"
private const val ARG_WINDOW = "window"
private const val WATCH_FRONT_TAB = "~front"

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

    /**
     * This phone's own names for the machine's ports, and which groups it has folded.
     *
     * A file rather than snapshot state, so [bookRevision] is what a composition keys on: a write to
     * a plain map is invisible to `remember`, and the grouping that reads it would go on showing the
     * old name until something else happened to recompose.
     */
    val portBook = remember { dev.terminaldeck.android.ports.PortBook.on(context) }
    var bookRevision by remember { mutableIntStateOf(0) }

    /**
     * The rows this phone has put away, per machine, and the ones it has pulled to the top.
     *
     * Same shape and same reason as the book above: it is a file, and [shelfRevision] is the thing
     * a composition can watch.
     */
    val shelf = remember { dev.terminaldeck.android.store.SessionShelf.on(context) }
    var shelfRevision by remember { mutableIntStateOf(0) }

    /** The session whose details are up, or null. A sheet rather than a route: it is about a row. */
    var detailFor by remember { mutableStateOf<dev.terminaldeck.android.protocol.RemoteSessionView?>(null) }

    /** Whether the archived list is up. */
    var archivedOpen by remember { mutableStateOf(false) }

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
    LaunchedEffect(created, state.needsPairing) {
        val request = created ?: return@LaunchedEffect
        // The pair screen owns the whole window while this is true, and the graph below is not
        // mounted — so there is nowhere to navigate to yet. The request is kept rather than dropped:
        // this effect keys on the flag as well, and runs again the moment the machine lets the phone
        // back in, which lands the person in the session they asked for.
        if (state.needsPairing) return@LaunchedEffect
        // Onto the sessions tab first, then the terminal, so a session started while somebody was
        // reading Settings lands on the stack it belongs to rather than on top of one.
        navController.navigate(GRAPH_SESSIONS) {
            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
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
            // Always offered from here. This screen owns the window while nothing is paired, so it
            // is the only door a phone with a server and no desktop has.
            onAddServer = viewModel::beginAddingServer,
        )
    } else {

    /*
     * The bottom bar and the two graphs under it.
     *
     * The bar is drawn over the screens a person moves between all day and withdrawn from the two
     * that take the whole window — a terminal and a watched page. That is the rule iOS states in
     * `DeckChrome`, and it is stated here rather than on each screen for the same reason: a screen
     * that hid the bar for itself would be one screen deciding something about the app's chrome.
     */
    val entry by navController.currentBackStackEntryAsState()
    val route = entry?.destination?.route
    // Withdrawn from the three screens that take the whole window: a terminal, a watched page and a
    // page being served from the machine. A pill sitting over the bottom rows of any of them points
    // somewhere else while the thing you are using needs the height.
    val bar = route != ROUTE_TERMINAL && route != ROUTE_WATCH_VIEW &&
        route != ROUTE_LOCALHOST_PAGE && route != ROUTE_CHAT && route != ROUTE_COPILOT
    val onSessions = route == ROUTE_SESSIONS || route == ROUTE_TERMINAL || route == ROUTE_CHAT
    val onLocalhost = route == ROUTE_LOCALHOST || route == ROUTE_LOCALHOST_PAGE
    val onCopilot = route == ROUTE_COPILOT
    /*
     * The pill follows the machine — except while somebody is standing on it.
     *
     * A tab that disappears underneath a thumb is worse than one that stays and explains: a
     * disconnect mid-read would drop the whole graph and land the person on the session list with no
     * idea why. `CopilotScreen` draws its own sentence for every state including the one where the
     * machine has stopped offering it.
     */
    val showCopilot = state.copilot != null || onCopilot

    /** Hop to a tab, keeping what was pushed on the one being left. */
    val showTab: (String) -> Unit = { graph ->
        navController.navigate(graph) {
            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
            launchSingleTop = true
            restoreState = true
        }
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        /*
         * Zero, and the whole app depends on it.
         *
         * The default is `systemBars`, which would hand this Scaffold's content a status-bar
         * inset — and every screen inside already owns its own top inset, either through its own
         * `TopAppBar` or, in the terminal's case, through an explicit `statusBarsPadding()`. Two
         * insets for one status bar is a title drawn a bar's height below the clock. The only
         * inset this level is responsible for is the one under the pill, and the bar consumes that
         * itself.
         */
        contentWindowInsets = WindowInsets(0),
        bottomBar = {
            if (bar) {
                NavigationBar(containerColor = MaterialTheme.colorScheme.surface) {
                    if (showCopilot) {
                        NavigationBarItem(
                            selected = onCopilot,
                            onClick = { showTab(GRAPH_COPILOT) },
                            icon = {
                                /*
                                 * The count of questions waiting on an answer, on the pill.
                                 *
                                 * A question raised while somebody is reading a terminal has a
                                 * two-minute deadline and expires into a **refusal**, and a badge is
                                 * on screen from every tab. Zero draws nothing at all, so there is no
                                 * empty dot on a machine with nothing pending.
                                 */
                                val waiting = state.copilot?.waitingCount ?: 0
                                BadgedBox(
                                    badge = {
                                        if (waiting > 0) {
                                            Badge { Text("$waiting") }
                                        }
                                    }
                                ) {
                                    Icon(Icons.Filled.AutoAwesome, contentDescription = null)
                                }
                            },
                            label = { Text("Copilot") },
                        )
                    }
                    NavigationBarItem(
                        selected = onSessions,
                        onClick = { showTab(GRAPH_SESSIONS) },
                        icon = { Icon(Icons.Filled.Terminal, contentDescription = null) },
                        label = { Text("Sessions") },
                    )
                    NavigationBarItem(
                        selected = onLocalhost,
                        onClick = { showTab(GRAPH_LOCALHOST) },
                        icon = { Icon(Icons.Filled.Public, contentDescription = null) },
                        label = { Text("Localhost") },
                    )
                    NavigationBarItem(
                        selected = !onSessions && !onLocalhost && !onCopilot,
                        onClick = { showTab(GRAPH_SETTINGS) },
                        icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                        label = { Text("Settings") },
                    )
                }
            }
        },
    ) { barPadding ->
    NavHost(
        navController = navController,
        startDestination = GRAPH_SESSIONS,
        // Padded by the bar, and the same amount *consumed* — so the screens inside, which ask for
        // the system bars themselves, are told the bottom one is already handled and do not add a
        // navigation bar's worth of empty space above a bar that is already sitting on it.
        modifier = Modifier.padding(barPadding).consumeWindowInsets(barPadding),
    ) {

    navigation(startDestination = ROUTE_SESSIONS, route = GRAPH_SESSIONS) {
        composable(ROUTE_SESSIONS) {
            val hostId = state.host?.hostId.orEmpty()
            // The shelf is a file, so `shelfRevision` is what a composition can watch: a write to a
            // plain map is invisible to `remember` and the list would go on drawing the row that was
            // just archived until something else happened to recompose.
            val split = remember(state.sessions, hostId, shelfRevision) {
                shelf.split(state.sessions, hostId)
            }
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
                onCloseSession = { session -> viewModel.endSession(session.id) },
                listed = split.listed,
                archived = split.archived,
                isPinned = { session -> shelf.isPinned(hostId, session.id) },
                onArchive = { session ->
                    shelf.setArchived(true, hostId, session.id)
                    shelfRevision += 1
                },
                onPin = { session, on ->
                    shelf.setPinned(on, hostId, session.id)
                    shelfRevision += 1
                },
                onArchivedList = { archivedOpen = true },
                onDetails = { session -> detailFor = session },
                onDismissAwayReport = viewModel::dismissAwayReport,
            )
        }

        composable(
            route = ROUTE_TERMINAL,
            arguments = listOf(
                navArgument(ARG_HOST_ID) { type = NavType.StringType },
                navArgument(ARG_SESSION_ID) { type = NavType.StringType },
            ),
        ) { entry ->
            TerminalRoute(
                entry = entry,
                state = state,
                screenTick = screenTick,
                viewModel = viewModel,
                navController = navController,
                photoPicker = photoPicker,
                documentPicker = documentPicker,
                onDetails = { detailFor = it },
            )
        }

        /*
         * The conversation, as bubbles rather than as a pty.
         *
         * Its own route rather than a mode of the terminal, because the two are different screens
         * with different chrome — one has a key bar and a pty, the other has a composer — and a flag
         * that swapped half a screen would leave the emulator alive underneath something that is not
         * showing it. The route names its machine for the reason the terminal route does.
         */
        composable(
            route = ROUTE_CHAT,
            arguments = listOf(
                navArgument(ARG_HOST_ID) { type = NavType.StringType },
                navArgument(ARG_SESSION_ID) { type = NavType.StringType },
            ),
        ) { entry ->
            val hostId = entry.arguments?.getString(ARG_HOST_ID)
            val sessionId = entry.arguments?.getString(ARG_SESSION_ID)
            val known = state.hosts.firstOrNull { it.hostId == hostId }
                ?.sessions?.firstOrNull { it.id == sessionId }
            // The session went, or the machine was forgotten. The pop is in an effect for the reason
            // the terminal route's is: navigating during composition leaves a black rectangle.
            if (hostId == null || sessionId == null || known == null) {
                LaunchedEffect(hostId, sessionId) { navController.popBackStack() }
                return@composable
            }

            /*
             * **This screen follows the session too, and that is not a duplicate of the terminal's.**
             *
             * Pushing this destination *disposes* the terminal underneath it, and the terminal's own
             * `onDispose` forgets the cluster — so without this, opening the conversation cleared the
             * very session it is about, `state.chat` went null on the next frame, and the route
             * popped itself straight back to the terminal. Which is exactly what it did: the chat
             * button did nothing at all, three times a second, and looked like a dead control.
             *
             * Found by driving it against a live host on 2026-08-22 rather than by reading it, which
             * is the only way this one shows up: every unit test in the suite passes either way.
             */
            DisposableEffect(hostId, sessionId) {
                val claim = viewModel.followControls(hostId, sessionId)
                // Only a screen that is up asks for a transcript: a terminal somebody is typing into
                // must not send a file read across a relay after every burst of output.
                viewModel.chatting(true)
                onDispose {
                    viewModel.chatting(false)
                    viewModel.releaseSession(hostId, claim)
                }
            }

            val chat = state.chat
            if (chat == null) {
                /*
                 * The moment between opening this and the far end answering, said rather than popped.
                 *
                 * It is one frame in the ordinary case — the effect above runs immediately after the
                 * first composition — and it is longer over a relay to a machine on another
                 * continent. Popping instead would be the screen refusing to open for a reason
                 * nobody could see.
                 */
                Waiting("Reading the conversation on the ${state.machineNoun}\u2026")
                return@composable
            }

            SessionChatScreen(
                view = chat,
                title = known.title,
                onBack = { navController.popBackStack() },
                onOpened = {},
                onClosed = {},
                onSend = viewModel::sendMessage,
                onCopy = viewModel::copyText,
                onDismissNotice = viewModel::dismissChatNotice,
            )
        }

    }

    /*
     * The copilot, on its own graph so a session opened from it comes back here.
     *
     * A run that starts a session and a person who taps it are two different stacks: the Sessions tab
     * keeps what was pushed on it, and a terminal opened from the copilot has to come back to the
     * copilot rather than to a list somebody was not reading.
     */
    navigation(startDestination = ROUTE_COPILOT, route = GRAPH_COPILOT) {
        composable(ROUTE_COPILOT) {
            val view = state.copilot
            // The machine stopped offering one — a switch, a downgrade, a revoke. The screen draws
            // its own sentence for that while it is up, and this is the case where it has gone
            // entirely: there is nothing to attach to, so the tab pops rather than draws.
            if (view == null) {
                LaunchedEffect(Unit) { navController.popBackStack() }
                return@composable
            }
            var sessionsOpen by remember { mutableStateOf(false) }
            CopilotScreen(
                view = view,
                machineLabel = state.hostLabel,
                // The pill is not drawn over this screen, so the chevron is the only way out.
                onLeave = { showTab(GRAPH_SESSIONS) },
                onStart = viewModel::startCopilot,
                onCancel = viewModel::cancelCopilotTurn,
                onStopRun = viewModel::stopCopilotRun,
                onSay = viewModel::sayToCopilot,
                onCopy = viewModel::copyText,
                onOpened = viewModel::openCopilot,
                onClosed = viewModel::closeCopilot,
                onSessions = {
                    viewModel.refreshCopilotSessions()
                    sessionsOpen = true
                },
                onLog = { viewModel.readCopilotLog() },
                onDismissNotice = viewModel::dismissCopilotNotice,
            )

            /*
             * The confirmation, above the timeline rather than in it.
             *
             * A question with a two-minute deadline that expires into a refusal is not a row somebody
             * scrolls to. `decidable` is true here because a `copilot.ask` only ever reaches the
             * surface that owns the run that raised it — arriving is itself the permission.
             */
            view.question?.let { question ->
                CopilotConsentSheet(
                    question = question,
                    decidable = view.access.canAct,
                    onAnswer = viewModel::answerCopilot,
                    // Dismissing does not answer it. The machine keeps it until it is answered or it
                    // expires, and a sheet that answered "no" on a swipe would be the reflex refusal
                    // this design refuses as hard as it refuses a reflex yes.
                    onDismiss = { viewModel.dismissCopilotNotice() },
                )
            }

            if (sessionsOpen) {
                CopilotSessionsSheet(
                    sessions = view.sessions,
                    machineLabel = state.hostLabel,
                    onOpen = { sessionId ->
                        sessionsOpen = false
                        state.host?.let { host ->
                            navController.navigate("terminal/${host.hostId}/$sessionId")
                        }
                    },
                    onDismiss = { sessionsOpen = false },
                )
            }
        }

        composable(
            route = ROUTE_TERMINAL,
            arguments = listOf(
                navArgument(ARG_HOST_ID) { type = NavType.StringType },
                navArgument(ARG_SESSION_ID) { type = NavType.StringType },
            ),
        ) { entry ->
            // The same terminal, on this graph's stack. Navigation-Compose has no way to share one
            // destination between two graphs, so the route is declared twice and the screen is one
            // composable called from both — which is the arrangement iOS reaches by giving each
            // `NavigationStack` its own `navigationDestination` for the same case.
            TerminalRoute(
                entry = entry,
                state = state,
                screenTick = screenTick,
                viewModel = viewModel,
                navController = navController,
                photoPicker = photoPicker,
                documentPicker = documentPicker,
                onDetails = { detailFor = it },
            )
        }
    }

    /*
     * Localhost: what the machine is serving, and one of those pages in your hand.
     *
     * Its own graph rather than a destination inside Settings, because the page opens with a **push**
     * from the list — Asad, of the iOS version: *"it should not come like this up. It should just
     * move like this when we click on localhost page… give it a native feel."* A modal rises from the
     * bottom edge because it is an interruption; a page from your own machine is not one, it is where
     * the tap was going.
     */
    navigation(startDestination = ROUTE_LOCALHOST, route = GRAPH_LOCALHOST) {
        composable(ROUTE_LOCALHOST) {
            // Read when the screen opens, and again when a socket that had gone comes back while it
            // is up. A no-op over a machine that never advertised either capability.
            LaunchedEffect(state.live) {
                if (state.live) {
                    viewModel.openLocalhost()
                    viewModel.openDevServers()
                }
            }
            val hostId = state.host?.hostId.orEmpty()
            // Recomputed whenever the ports, the dev servers or this phone's own names move. The
            // grouping is pure — see PortCatalog — so this is a fold over two lists rather than a
            // second source of truth that could disagree with them.
            val sections = remember(state.localhost, state.devServers, hostId, bookRevision) {
                dev.terminaldeck.android.ports.PortCatalog.sections(
                    ports = state.localhost?.ports.orEmpty(),
                    devServers = state.devServers?.rows?.values?.toList().orEmpty(),
                    names = portBook.names(hostId),
                )
            }
            LocalhostScreen(
                view = state.localhost,
                devServers = state.devServers,
                sections = sections,
                machineLabel = state.hostLabel,
                canServeHere = state.localhostOffered,
                live = state.live,
                onRefresh = {
                    viewModel.refreshPorts()
                    viewModel.openDevServers()
                },
                onServeHere = { port ->
                    viewModel.servePort(port)
                    navController.navigate(ROUTE_LOCALHOST_PAGE)
                },
                onOpenOnMachine = viewModel::openPort,
                onStartDevServer = viewModel::startDevServer,
                onOpenSession = { sessionId ->
                    state.host?.let { host ->
                        navController.navigate(GRAPH_SESSIONS) {
                            popUpTo(navController.graph.findStartDestination().id) { saveState = true }
                            launchSingleTop = true
                            restoreState = true
                        }
                        navController.navigate("terminal/${host.hostId}/$sessionId")
                    }
                },
                onCopyAddress = { port -> viewModel.copyText("http://localhost:$port") },
                onRename = { port, name ->
                    portBook.setName(name, hostId, port)
                    // The book is not observable state — it is a file — so the one thing that has to
                    // move is a counter the grouping keys on. A snapshot read inside `remember`
                    // cannot see a write to a map that is not snapshot state.
                    bookRevision += 1
                },
                isFolded = { category -> portBook.isFolded(hostId, category) },
                onFold = { category, folded ->
                    portBook.setFolded(folded, hostId, category)
                    bookRevision += 1
                },
            )
        }

        composable(ROUTE_LOCALHOST_PAGE) {
            /*
             * The page, or nothing.
             *
             * `state.tunnel` is null the instant the tunnel is closed — by the Close button, by the
             * machine, or by the socket dropping — so this route pops itself rather than leaving a
             * rendered page on screen with nothing behind it. That is the whole promise this screen
             * makes, and the pop is in an effect for the reason the terminal route's is: navigating
             * during composition leaves a black rectangle with no bar on it.
             */
            val tunnel = state.tunnel
            if (tunnel == null) {
                LaunchedEffect(Unit) { navController.popBackStack() }
                return@composable
            }
            LocalhostBrowser(
                view = tunnel,
                onClose = {
                    viewModel.closeServedPort()
                    navController.popBackStack()
                },
            )
        }
    }

    navigation(startDestination = ROUTE_SETTINGS, route = GRAPH_SETTINGS) {
        composable(ROUTE_SETTINGS) {
            // The two request clusters are read when the screen that shows them opens, and again if
            // the socket drops and returns while it is open — a no-op once the answer is in hand.
            // See ServerSettingsController.ensureRead and DeviceRosterController.ensureRead.
            LaunchedEffect(state.live) {
                if (state.live) {
                    viewModel.openServerSettings()
                    viewModel.openDevices()
                }
            }
            SettingsScreen(
                state = state,
                onMachines = { navController.navigate(ROUTE_MACHINES) },
                onDevices = { navController.navigate(ROUTE_DEVICES) },
                onWatch = { navController.navigate(ROUTE_WATCH) },
                onGitHub = { github = true },
                onAlerts = { navController.navigate(ROUTE_ALERTS) },
                onAppearance = { navController.navigate(ROUTE_APPEARANCE) },
                onApplyServerSetting = viewModel::applyServerSetting,
            )
        }

        composable(ROUTE_ALERTS) {
            AlertsScreen(onBack = { navController.popBackStack() })
        }

        composable(ROUTE_APPEARANCE) {
            AppearanceScreen(
                onBack = { navController.popBackStack() },
                onTerminalColours = { navController.navigate(ROUTE_TERMINAL_SCHEME) },
            )
        }
        composable(ROUTE_TERMINAL_SCHEME) {
            TerminalSchemeScreen(
                onBack = { navController.popBackStack() },
                // Encoded, because a custom scheme's id is generated here and a built-in's is a
                // slug — but the route is a string and the next id format is not this function's
                // to guarantee.
                onEdit = { id -> navController.navigate("appearance/terminal/" + Uri.encode(id)) },
            )
        }
        composable(
            route = ROUTE_TERMINAL_SCHEME_EDIT,
            arguments = listOf(navArgument(ARG_SCHEME_ID) { type = NavType.StringType }),
        ) { entry ->
            TerminalSchemeEditorScreen(
                schemeId = entry.arguments?.getString(ARG_SCHEME_ID).orEmpty(),
                onBack = { navController.popBackStack() },
            )
        }

        composable(ROUTE_MACHINES) {
            MachinesScreen(
                hosts = state.hosts,
                onBack = { navController.popBackStack() },
                onSelect = viewModel::select,
                onRename = viewModel::rename,
                onForget = viewModel::forget,
                onAddHost = viewModel::beginAddingHost,
                onAddServer = viewModel::beginAddingServer,
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
            LaunchedEffect(state.live) { if (state.live) viewModel.openDevices() }
            DevicesScreen(
                view = view,
                machineLabel = state.hostLabel,
                onBack = { navController.popBackStack() },
                onRefresh = viewModel::refreshDevices,
                onRevoke = viewModel::revokeDevice,
            )
        }

        composable(ROUTE_WATCH) {
            val view = state.watch
            if (view == null) {
                LaunchedEffect(Unit) { navController.popBackStack() }
                return@composable
            }
            LaunchedEffect(state.live) { if (state.live) viewModel.openWatch() }
            WatchSurfacesScreen(
                view = view,
                machineLabel = state.hostLabel,
                onBack = { navController.popBackStack() },
                onRefresh = viewModel::refreshWatch,
                onOpen = { surface ->
                    val slot = surface.window.ifEmpty { WATCH_FRONT_TAB }
                    navController.navigate("watch/" + Uri.encode(slot))
                },
            )
        }

        composable(
            route = ROUTE_WATCH_VIEW,
            arguments = listOf(navArgument(ARG_WINDOW) { type = NavType.StringType }),
        ) { entry ->
            val slot = entry.arguments?.getString(ARG_WINDOW).orEmpty()
            val window = if (slot == WATCH_FRONT_TAB) "" else slot
            // The controller, not a copy of the strip: the viewer needs the object it acks and sends
            // gestures through. Null when the machine on screen stopped offering watching — a switch
            // or a downgrade — and then there is nothing to cast, so it pops rather than draws.
            val watcher = viewModel.watcher()
            val surface = state.watch?.surfaces?.firstOrNull { it.window == window }
            if (watcher == null) {
                LaunchedEffect(Unit) { navController.popBackStack() }
                return@composable
            }
            WatchViewerScreen(
                watch = watcher,
                // A window the strip no longer lists is still watchable — the strip is a list of what
                // is open, and it can move while somebody is looking at one of its pages — so the
                // route's own name is the fallback rather than a pop.
                surface = surface ?: BrowserSurfaceWire(window = window),
                onBack = { navController.popBackStack() },
            )
        }
    }

    }
    }

    } // end of the paired branch; the sheets below are drawn over either one

    /*
     * Adding a server sits above **both** branches, and that placement is the feature.
     *
     * It has to be reachable from the pair screen, because a phone with a server and no desktop
     * never leaves it — and from the session list, because the second machine somebody adds is as
     * likely to be a server as the first. A destination inside the NavHost could only be reached
     * from the second of those; a mode of the pair screen could only be reached from the first.
     *
     * Drawn from the view model's state rather than a local flag so that a sign-in survives a
     * rotation: the wait is seconds long, and a screen that reset half way through it would leave a
     * device row minted on somebody's server that this phone has no credential for.
     */
    state.addServer?.let { adding ->
        /*
         * The connector's own state, collected here rather than folded into [DeckUiState].
         *
         * It carries an install's live output — the installer prints for a minute or two on a
         * server with no Node — and folding that through the state every screen in the app reads
         * would recompose the session list on every chunk of somebody else's `npm install`.
         */
        val servers by viewModel.serverConnector.state.collectAsStateWithLifecycle()
        ServerLoginScreen(
            view = ServerLoginView(
                servers = servers,
                relayBusy = adding.busy,
                relayWorking = adding.working,
                relayError = adding.error,
                connected = adding.connected,
            ),
            onLogIn = viewModel::logInToServer,
            onSignIn = viewModel::signInToServer,
            onCancel = viewModel::cancelAddingServer,
        ) { server ->
            HostStepCard(
                server = server,
                state = servers,
                justLoggedIn = true,
                connecting = adding.busy,
                connectError = adding.error,
                linked = server.linkedHostId?.let { id -> state.hosts.any { it.hostId == id } } == true,
                onCheck = { viewModel.checkServer(server.id) },
                onInstall = { viewModel.installOnServer(server.id) },
                onStartAndConnect = { viewModel.startAndConnectServer(server.id) },
                onConnect = { viewModel.connectToServer(server.id) },
                onStop = { viewModel.stopServer(server.id) },
                onDisconnect = { viewModel.disconnectServer(server.id) },
            )
        }
    }

    /*
     * The one screen that is the entire explanation of the credential proxy.
     *
     * Only ever a request the desktop asked this phone to *prompt* about — a push, against a
     * repository this device has not already approved on that machine. Reads and approved pushes
     * are answered without anything reaching here, which is the policy and is why this is null
     * almost always.
     */
    /*
     * Everything about one session, and the rows this phone has put away.
     *
     * Above the graph rather than inside one, because both are reachable from two places: the detail
     * sheet from a long press on a row **and** from the ⋯ inside the session itself, and the archived
     * list from the list's own ⋯. A destination inside the sessions graph could only be reached from
     * one of those, and a copy in each would be two screens to keep in step.
     */
    detailFor?.let { session ->
        val host = state.host
        // Re-derived here rather than reused from inside the paired branch: these sheets are drawn
        // above *both* branches, and the route is what decides whether Open leads somewhere.
        val onList = navController.currentBackStackEntryAsState().value?.destination?.route == ROUTE_SESSIONS
        // The session ended, or the machine was unpaired out from under this sheet. Both are real
        // sequences; neither is a reason to draw a screen of blanks.
        val live = host?.sessions?.firstOrNull { it.id == session.id }
        if (host == null || live == null) {
            LaunchedEffect(session.id) { detailFor = null }
        } else {
            SessionDetailSheet(
                session = live,
                host = host,
                startableFolders = state.startableFolders,
                canStart = state.canStartSession,
                gitLoginsOffered = state.canAnswerGitLogins,
                gitHubLogin = state.gitHubAccount?.login,
                // Offered only from the list. Raised from inside the session, a button leading to
                // the screen underneath is furniture — so the terminal passes a sheet with no Open.
                onOpen = if (onList) {
                    {
                        detailFor = null
                        navController.navigate("terminal/${host.hostId}/${live.id}")
                    }
                } else {
                    null
                },
                onNewSessionHere = { folder ->
                    detailFor = null
                    viewModel.newSession(folder)
                },
                onCopy = viewModel::copyText,
                onGitHub = {
                    detailFor = null
                    github = true
                },
                onDismiss = { detailFor = null },
            )
        }
    }

    if (archivedOpen) {
        val hostId = state.host?.hostId.orEmpty()
        val away = remember(state.sessions, hostId, shelfRevision) {
            shelf.split(state.sessions, hostId).archived
        }
        ArchivedSessionsSheet(
            sessions = away,
            machine = state.hostLabel,
            onUnarchive = { id ->
                shelf.setArchived(false, hostId, id)
                shelfRevision += 1
            },
            onOpen = { session ->
                archivedOpen = false
                state.host?.let { host ->
                    navController.navigate("terminal/${host.hostId}/${session.id}")
                }
            },
            onDismiss = { archivedOpen = false },
        )
    }

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

/**
 * A screen that has asked and is waiting for the machine to answer.
 *
 * The same shape as [LeavingSession] and a different sentence, because they are different facts: one
 * is *that is gone*, the other is *this has not arrived yet*. A screen that used the first wording
 * for the second would tell somebody their session had ended every time a relay took a moment.
 */
@Composable
private fun Waiting(text: String) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text = text, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/**
 * One open session, on whichever tab's stack it was opened from.
 *
 * Extracted so the same screen can be a destination of the Sessions graph **and** of the Copilot
 * graph. Navigation-Compose has no way to share one destination between two graphs — each declares
 * its own `composable(ROUTE_TERMINAL)` — so the route is declared twice and the screen is one
 * function called from both. That is the arrangement iOS reaches by giving each `NavigationStack`
 * its own `navigationDestination` for the same case, and it matters because a terminal the copilot
 * started has to come back to the copilot rather than to a list nobody was reading.
 */
@Composable
private fun TerminalRoute(
    entry: androidx.navigation.NavBackStackEntry,
    state: DeckUiState,
    screenTick: Long,
    viewModel: DeckViewModel,
    navController: androidx.navigation.NavHostController,
    photoPicker: androidx.activity.compose.ManagedActivityResultLauncher<PickVisualMediaRequest, android.net.Uri?>,
    documentPicker: androidx.activity.compose.ManagedActivityResultLauncher<Array<String>, android.net.Uri?>,
    onDetails: (dev.terminaldeck.android.protocol.RemoteSessionView) -> Unit,
) {

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
            return
        }

        /*
         * The control cluster follows the session, and only while its screen is up.
         *
         * `follow` after the route has resolved a binding, because the question it asks is about
         * a session this socket has been told is on screen; `forget` on the way out, because
         * nothing about a session nobody is looking at is worth holding — a reading from a
         * minute ago is a claim about now that has stopped being true.
         */
        // `sessionId` is non-null past the guard above — `binding` is only built when both ids
        // are — but the compiler cannot carry that through a lambda capture, so it is named once
        // here rather than asserted at the call.
        val liveSession = known.id
        DisposableEffect(hostId, liveSession) {
            val claim = viewModel.followControls(hostId, liveSession)
            onDispose { viewModel.releaseSession(hostId, claim) }
        }
        var controlsOpen by remember(liveSession) { mutableStateOf(false) }

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
            // Absent, not disabled, when this machine does not serve `controls` or this session
            // has no agent drawing it — see [SessionControls.clusterShown].
            hasControls = SessionControls.clusterShown(state.controls?.reading),
            onControls = { controlsOpen = true },
            // Null over a machine that advertises none of usage/account/chat/send, which gets a
            // terminal exactly as it was rather than a bar with nothing in it.
            bar = state.bar,
            onRefreshUsage = viewModel::refreshUsage,
            onSwitchAccount = viewModel::switchAccount,
            onOpenChat = { navController.navigate("chat/$hostId/$liveSession") },
            onDetails = { onDetails(known) },
        )

        if (controlsOpen) {
            state.controls?.let { controls ->
                SessionControlsSheet(
                    view = controls,
                    onApply = { control, value -> viewModel.applyControl(hostId, control, value) },
                    onDismissNotice = { viewModel.dismissControlsNotice(hostId) },
                    onDismiss = { controlsOpen = false },
                )
            }
        }
}
