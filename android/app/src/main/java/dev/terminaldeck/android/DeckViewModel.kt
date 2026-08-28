package dev.terminaldeck.android

import android.app.Application
import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.terminaldeck.android.credential.coroutineExpiry
import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.github.ConnectGitHubController
import dev.terminaldeck.android.github.ConnectGitHubView
import dev.terminaldeck.android.hostcontrol.HostControlController
import dev.terminaldeck.android.hostcontrol.HostControlView
import dev.terminaldeck.android.pairing.PairingCodes
import dev.terminaldeck.android.pairing.Rendezvous
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.HostPlatform
import dev.terminaldeck.android.protocol.HostVersion
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ControlName
import dev.terminaldeck.android.protocol.ServerSettingKey
import dev.terminaldeck.android.protocol.pasteRefusal
import dev.terminaldeck.android.protocol.RemoteSessionView
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.EnrollMethod
import dev.terminaldeck.android.protocol.FileListing
import dev.terminaldeck.android.protocol.FileText
import dev.terminaldeck.android.protocol.PanelData
import dev.terminaldeck.android.protocol.MachineBrowserState
import dev.terminaldeck.android.protocol.MachineShot
import dev.terminaldeck.android.protocol.MachineProfileList
import dev.terminaldeck.android.protocol.RoutineFile
import dev.terminaldeck.android.session.RemoteSessionBinding
import dev.terminaldeck.android.servers.AssetScriptLibrary
import dev.terminaldeck.android.servers.FileServerStore
import dev.terminaldeck.android.servers.InMemoryServerStore
import dev.terminaldeck.android.servers.LoginPhase
import dev.terminaldeck.android.servers.ScriptLibrary
import dev.terminaldeck.android.servers.ServerConnector
import dev.terminaldeck.android.servers.ServerCredentialKind
import dev.terminaldeck.android.servers.SshDialer
import dev.terminaldeck.android.signin.ServerAddress
import dev.terminaldeck.android.signin.ServerSignIn
import dev.terminaldeck.android.store.DeviceVault
import dev.terminaldeck.android.store.KeystoreDeviceVault
import dev.terminaldeck.android.store.KeystoreVaultCipher
import dev.terminaldeck.android.store.PairingRecord
import dev.terminaldeck.android.transfer.FileUpload
import dev.terminaldeck.android.transfer.PickedFile
import dev.terminaldeck.android.transfer.UploadView
import dev.terminaldeck.android.transfer.shellQuoted
import dev.terminaldeck.android.transport.DeckTransport
import dev.terminaldeck.android.transport.Heartbeat
import dev.terminaldeck.android.alerts.AlertGate
import dev.terminaldeck.android.alerts.AlertReason
import dev.terminaldeck.android.alerts.AwayReport
import dev.terminaldeck.android.alerts.SessionAlert
import dev.terminaldeck.android.alerts.SessionAlerts
import dev.terminaldeck.android.transport.TransportState
import dev.terminaldeck.android.tunnel.TunnelController
import dev.terminaldeck.android.tunnel.TunnelView
import dev.terminaldeck.android.transport.WebSocketDeckTransport
import dev.terminaldeck.android.transport.detail
import dev.terminaldeck.android.transport.isOnline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

/**
 * Every machine this phone is paired with, which one is on screen, and the one place a frame
 * becomes application state.
 *
 * The per-machine half of this is now [HostLink] — one per paired machine, each with its own
 * socket, its own sealed channel and its own sessions. What is left here is the collection, the
 * switcher, and the small set of things that are genuinely about the phone rather than about a
 * machine: the device key, the clipboard, the network callback and pairing.
 *
 * ## Pairing ADDS a machine. It never replaces one.
 *
 * The single most important line in the file. The failure to design against is not "multi-host does
 * not work" — it is a phone that pairs with a second machine and silently drops the first, which to
 * the person holding it looks exactly like *my phone forgot my Mac*. So [pair] writes one record
 * into a collection keyed by host id and starts one more socket; the only things that remove a
 * record are the user asking ([forget]) and a machine refusing the credential outright.
 *
 * ## Everything stays connected
 *
 * Not connect-on-switch. Every paired machine holds its socket from launch, which buys two things
 * worth the cost: the switcher shows *live* status for machines that are not on screen — the point
 * of having more than one is knowing which of them is busy — and switching is instant rather than a
 * handshake. The cost is one keepalive per socket, folded into a single app-wide tick so that N
 * machines cost one radio wake-up rather than N. See [Heartbeat].
 *
 * ## The facade
 *
 * Most of [DeckUiState] describes the *selected* machine, because the screens were written against
 * one and none of them should have to learn about the collection to draw a session list. What a
 * screen must never do is hold a [HostLink] across a switch, so nothing hands one out: the state is
 * refolded by [publish] whenever any machine changes, and the terminal screen names its machine in
 * the route rather than assuming the current one.
 */
class DeckViewModel(
    private val vault: DeviceVault,
    private val clipboard: Clipboard,
    private val network: NetworkWatch = NetworkWatch.none,
    /**
     * The app-wide tick. Held here only to realign it once when the app comes back, rather than
     * once per machine — see [resume].
     */
    private val heartbeat: Heartbeat = Heartbeat.shared,
    /**
     * Where six typed digits turn into an address.
     *
     * A parameter rather than a direct call, and it is the only seam this class has for the network:
     * the real one derives a memory-hard seed and opens a WebSocket to the public relay, so a unit
     * test that reached it would dial the internet from whatever machine ran the suite.
     */
    private val lookup: suspend (String, String) -> Rendezvous.Offer? = Rendezvous::lookupAt,
    /**
     * Where a pasted server address and an SSH login turn into a credential.
     *
     * A seam for the same reason [lookup] is one: the real thing opens a WebSocket to a relay and
     * makes a server run an SSH probe, so a unit test that reached it would dial the internet.
     * Everything it needs is in one [ServerSignIn.Request] — including the secret, which lives for
     * the length of the call and is deliberately never a field on this class.
     */
    private val serverSignIn: suspend (ServerSignIn.Request) -> ServerSignIn.Result = ServerSignIn::signIn,
    /**
     * What this phone calls itself when it introduces itself to a server it is signing in to.
     *
     * A parameter rather than a read of `android.os.Build`, because this class is deliberately free
     * of Android — see [Clipboard] and [NetworkWatch] — and because `Build` on the unit-test
     * classpath is a stub whose fields are null. The real one comes from [factory]; the default is
     * the neutral word a server can still show in its device list.
     */
    private val deviceName: String = "Phone",
    /**
     * This app's own build number, for the one comparison [DeckUiState.serverBehindSentence] makes
     * against the machine's `welcome.appVersion`. A plain string so a test can drive both sides of
     * it; the real one is `BuildConfig.VERSION_NAME`, injected by [factory]. Empty is the honest
     * non-answer a build with no stamp gives, and [HostVersion] refuses to compare against it.
     */
    private val clientVersion: String = "",
    /**
     * Put one alert on the lock screen.
     *
     * A lambda rather than a call into `AlertCenter`, for the reason [clipboard] and [network] are
     * seams: this class is deliberately free of Android, and a notification manager reached from
     * here would be a `Context` on the unit-test classpath where every field is a stub. The real one
     * is wired in [factory]; the default does nothing, which is exactly what a test wants unless it
     * says otherwise.
     */
    private val raiseAlert: (SessionAlert) -> Unit = {},
    /**
     * Whether the person has left this *kind* of alert switched on.
     *
     * A seam for the same reason [raiseAlert] is one: the answer lives in `AlertSettings`, which
     * reads a `SharedPreferences` off a `Context` this deliberately Android-free class does not
     * hold. [factory] wires the real read; the default says yes to everything, which is what a test
     * wants and is also the honest default the switches themselves carry. It is consulted here — not
     * only at the point of posting — so the "while you were away" line counts only what a banner
     * would actually have said, the way iOS filters it in the model.
     */
    private val wants: (SessionAlert.Kind) -> Boolean = { true },
    /**
     * Everything that reaches a **bare server** over this phone's own SSH connection: the login,
     * the check, the install, the start, and what a connect would spend.
     *
     * Held here rather than built by the screen so an install survives a rotation — it takes
     * minutes on a server with no Node — and so the one SSH session opened for a card is reused
     * across check, install and start rather than being three handshakes for one visit.
     *
     * The default is the one a unit test wants: an in-memory store, no scripts, and a dialer that
     * refuses rather than one that would open a socket to somebody's real machine from whatever
     * laptop ran `./gradlew test`. [factory] passes the real three.
     */
    val serverConnector: ServerConnector = ServerConnector(
        store = InMemoryServerStore(),
        scripts = ScriptLibrary.none,
        dialer = SshDialer.refusing,
        appVersion = "",
    ),
    private val transportFactory: (CoroutineScope, String, DeviceVault) -> DeckTransport,
) : ViewModel() {

    /**
     * Every paired machine, in the order they were paired.
     *
     * A `LinkedHashMap` because both halves matter: keyed lookup, so a frame can only ever be
     * applied to the machine that sent it, and insertion order, so the switcher never reshuffles
     * itself between one look and the next and has people tapping the row that used to be there.
     */
    private val links = LinkedHashMap<String, HostLink>()

    /**
     * What each machine's sessions were doing last time anybody looked.
     *
     * One detector for every machine rather than one per link, because it is keyed by host id and
     * because it has to survive a link being taken down and brought back: a reconnect is precisely
     * the moment its answer matters, and a detector rebuilt with the link would seed itself from the
     * list that arrived on the new connection and announce nothing.
     */
    private val alerts = SessionAlerts()

    /**
     * Where he is looking, and so whether an alert [SessionAlerts] raised is worth a banner *now*.
     *
     * The half this client was missing: [SessionAlerts] answered "is this worth telling him about"
     * and nothing answered "is he already looking at it". Fed from the scene's foreground and from
     * the terminal screen coming and going — see [enteredForeground], [watchingSession] — and read
     * in [noteAlerts]. Its rule and its tests are in [dev.terminaldeck.android.alerts.AlertGate].
     */
    private val alertGate = AlertGate()

    /**
     * The one line the session list shows after the app has been away, or null.
     *
     * Held rather than derived, because it is about a *moment* — the first list after a connection
     * came back — and nothing in the state that is folded every frame remembers moments.
     */
    private var awayReport: String? = null

    private var selectedHostId: String? = null

    /** Set while the user is adding a machine, so the pair screen shows the field and not a wait. */
    private var addingHost = false

    private var pairingError: String? = null
    /** True while the rendezvous is being asked where a typed code's machine is. */
    private var pairingLookup: Boolean = false

    /**
     * The Add-a-server screen is up, and what it is doing.
     *
     * Held here rather than in the composable so that a sign-in survives a rotation and cannot be
     * started twice by one — a second `enroll` for the same login is a second SSH probe on somebody
     * else's server and an attempt spent against its rate limiter.
     *
     * What is deliberately **not** here is the password or the key. Those live in the screen's own
     * state and in the one call that spends them; a view model that held one would be holding it
     * for as long as the process lives, in a class that is dumped whole into every crash report.
     */
    private var addingServer = false
    private var serverSignInWorking: String? = null
    private var serverSignInError: String? = null
    /**
     * Whether a sign-in is in flight, held separately from the job that is running it.
     *
     * Not `serverSignInJob != null`, and the difference is a real bug rather than a style: a
     * coroutine can finish *before* `launch` returns — an unconfined dispatcher does it every time,
     * and so does any answer that arrives without suspending — and the assignment of the job then
     * lands after the body has already cleared it. The field would be left holding a completed job
     * and every later sign-in would be silently refused, on a phone whose only symptom is a button
     * that has stopped working.
     */
    private var signingIn = false
    private var serverSignInJob: Job? = null

    /**
     * Which server's card started the connect that is in flight, or null.
     *
     * The relay sign-in is one code path with two callers now: a pasted server address typed into
     * the login field, and the Connect on a server this phone has already logged into over SSH.
     * They end differently and must — the first is finished when the machine arrives, and the
     * second has to come back to the card that is still on screen and say so — so the caller is
     * remembered rather than guessed at from the shape of the address.
     */
    private var connectingServerId: String? = null

    /**
     * The name of the machine a card's Connect just produced, while that receipt is on screen.
     *
     * Cleared by leaving the login screen or by disconnecting. Nothing derives it from the machine
     * list: the list has the machine in it from the moment it arrives, and a receipt drawn from
     * that would appear again every time somebody opened the screen.
     */
    private var serverConnectedName: String? = null

    private var notice: String? = null

    private val _uiState = MutableStateFlow(DeckUiState())
    val uiState: StateFlow<DeckUiState> = _uiState.asStateFlow()

    /**
     * The session being displayed, if any.
     *
     * Held outside [DeckUiState] on purpose. A [RemoteSessionBinding] wraps a live emulator whose
     * screen mutates in place; putting it in an immutable state object would invite Compose to
     * treat it as a value and skip recomposition on the basis that the reference has not changed.
     * Redraws come from [screenTick] instead, which is a counter the binding bumps.
     */
    val binding: RemoteSessionBinding? get() = selected?.binding

    private val _screenTick = MutableStateFlow(0L)
    val screenTick: StateFlow<Long> = _screenTick.asStateFlow()

    private var noticeJob: Job? = null
    private var stopWatchingNetwork: (() -> Unit)? = null

    /**
     * Walking the machine's folders, for the folder picker to read.
     *
     * One instance for the whole app rather than one per machine, because the picker is only ever
     * open for the machine on screen and sends every `folders.browse` to that one — [selected]. Its
     * state is a flow of its own rather than a field on [DeckUiState]: this is a screen somebody
     * opens, walks and closes, so it holds its own listing and clears it on the way out rather than
     * riding along on every session frame. The `folders.entries` answer is handed to [receive] from
     * [onFrame]; the screen is [dev.terminaldeck.android.ui.FolderPickerScreen].
     */
    val folderBrowse: FolderBrowseController = FolderBrowseController(
        send = { selected?.transport?.send(it) ?: false },
    )

    init {
        for (record in vault.pairings()) adopt(record)
        selectedHostId = vault.selectedHost()?.takeIf(links::containsKey) ?: links.keys.firstOrNull()
        publish()

        stopWatchingNetwork = network.start { resume() }

        // All of them, not just the one on screen. A switcher that showed "offline" for every
        // machine except the current one would be showing the *app's* state rather than the
        // machines', which is the opposite of why anybody would want more than one.
        for (link in links.values) link.transport.connect()
    }

    /* -------------------------------------------------------------- the collection -- */

    private val selected: HostLink? get() = selectedHostId?.let(links::get) ?: links.values.firstOrNull()

    private fun link(hostId: String?): HostLink? = hostId?.let(links::get)

    /**
     * Wire one stored record up as a live machine.
     *
     * Idempotent by host id, which is what makes pairing again with a machine already in the list an
     * update rather than a second row for one computer.
     */
    private fun adopt(record: PairingRecord): HostLink {
        links[record.hostId]?.let { existing ->
            existing.record = record
            return existing
        }
        val link = HostLink(
            hostId = record.hostId,
            transport = transportFactory(viewModelScope, record.hostId, vault),
            record = record,
        )
        links[record.hostId] = link
        // The two request clusters, one per machine. They read this link's live capability set
        // through a lambda rather than a snapshot, so a cluster created before the welcome draws
        // nothing until the welcome names its capability and lights up the moment it does. Their
        // timers run on the view model's scope and are torn down by [HostLink.stop].
        link.devices = DeviceRosterController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        link.settings = ServerSettingsController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        // The host owns its GitHub login now; this drives it over `github.*`. One per machine, gated
        // on the machine advertising `github`, exactly like the settings cluster above.
        link.github = ConnectGitHubController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        // The host owns its own lifecycle now; this drives it over `host.*` when the machine is
        // connected over the relay. "The relay is the network": a server page reaches the host here
        // when its SSH address is offline. One per machine, gated on the machine advertising
        // `host.control`, exactly like the GitHub cluster above.
        link.hostControl = HostControlController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        link.controls = SessionControlsController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        link.watch = WatchController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            onChange = { publish() },
        )
        link.bar = SessionBarController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        link.localhost = LocalhostController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        link.devServer = DevServerController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        link.tunnels = TunnelController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            scope = viewModelScope,
            onChange = { publish() },
        )
        link.copilot = CopilotController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        link.copilotFiles = CopilotFilesController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            onChange = { publish() },
        )
        link.routines = CopilotRoutinesController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            onChange = { publish() },
        )
        // The "look inside" family: files, git and the four panels. Read-only holders that keep the
        // machine's latest answer as Compose state, so the screen reading one recomposes on the
        // answer without folding every machine's summary for a file's bytes. No `onChange` for that.
        link.filesGit = FilesGitController(send = { link.transport.send(it) })
        link.panels = PanelsController(send = { link.transport.send(it) })
        link.machineBrowser = MachineBrowserController(
            send = { link.transport.send(it) },
            capabilities = { link.capabilities },
            expiry = coroutineExpiry(viewModelScope),
            onChange = { publish() },
        )
        // Collected per machine, with the link captured, so a frame cannot arrive without the
        // answer to "which computer said this" already in hand.
        viewModelScope.launch { link.transport.state.collect { onState(link, it) } }
        viewModelScope.launch { link.transport.incoming.collect { onFrame(link, it) } }
        return link
    }

    /**
     * Show a different machine.
     *
     * Nothing is connected or disconnected here — every machine is already holding its socket, which
     * is the whole reason switching is instant.
     */
    fun select(hostId: String) {
        if (!links.containsKey(hostId) || hostId == selectedHostId) return
        selectedHostId = hostId
        vault.selectHost(hostId)
        addingHost = false
        publish()
    }

    /* ------------------------------------------------------------------- frames -- */

    private fun onState(link: HostLink, next: TransportState) {
        val wasOnline = link.connection.isOnline
        link.connection = next
        // The record can have changed underneath: a `welcome` mints a durable credential and marks
        // the machine approved, both of which are written to the vault by the transport.
        vault.pairing(link.hostId)?.let { link.record = it }

        if (!wasOnline && next.isOnline) onReconnected(link)
        if (wasOnline && !next.isOnline) {
            // The list is kept — it is the last thing the machine actually said — but the statuses
            // in it are now history, and the banner says so rather than the rows quietly continuing
            // to claim "running".
            link.live = false
            // An upload cannot survive the connection carrying it, and a progress bar left creeping
            // against a socket that will never answer is exactly the lie this client is written not
            // to tell. The machine deletes its half-written file when the socket closes.
            link.upload?.connectionLost(next.detail)
            // A reading is a claim about now, and nothing over a dead channel will correct it. The
            // cast stops with it: the host is holding a screencast for a socket that has gone.
            link.controls?.dropped()
            link.bar?.dropped()
            link.watch?.renew()
            link.localhost?.renew()
            link.devServer?.renew()
            link.machineBrowser?.renew()
            // A tunnel cannot survive the connection carrying its bytes, and a page left spinning
            // against a socket that will never answer is exactly the lie this client is written not
            // to tell.
            link.tunnels?.connectionLost(next.detail)
            link.copilot?.dropped()
        }
        publish()
    }

    /**
     * Hand this machine's session list to the detector, and do whatever its answer deserves.
     *
     * A **live** change is raised on the phone: a session stopping and asking for an answer is the
     * reason this app is on a phone at all. A **catch-up** that lands while he is *looking* is a
     * line of text instead — a reconnect he is watching refill, where four banners are worse than a
     * sentence — but a catch-up while the app is *away* still posts, because then a banner is the
     * only way he will hear. Both are also weighed against the two switches and against where he is
     * looking; the body says how.
     *
     * Both paths cost nothing over a machine that changed nothing: the detector answers with an
     * empty list and the away line is left exactly as it was.
     */
    private fun noteAlerts(link: HostLink, reason: AlertReason) {
        val raised = alerts.observe(link.hostId, link.label, link.sessions)
        /*
         * Two filters before anything is said, and both are the fix for *"for every single move it
         * is giving a notification"*. The switches decide what is worth saying at all; the gate
         * drops whatever is about the session on screen — or the one he closed a second ago, whose
         * settle verdict is only now catching up. One `filter`, so the away line below counts
         * exactly what a banner would have.
         */
        val wanted = raised.filter { wants(it.kind) && !alertGate.isBeingWatched(it) }
        if (wanted.isEmpty()) return

        /*
         * A catch-up while the app is *open* is a line of text, not four banners: the reconnect is
         * him watching the list refill and interrupting that is worse than a sentence. A catch-up
         * while the app is *away* still posts — then a banner is the only way he will hear, which is
         * the whole point. A live change always posts. (iOS: `DeckModel.alertsChanged`.)
         */
        if (reason == AlertReason.CatchUp && alertGate.isForeground) {
            awayReport = AwayReport.sentence(wanted)
            return
        }
        for (alert in wanted) raiseAlert(alert)
    }

    /**
     * The app came to the foreground, or went away.
     *
     * Away is the situation the whole feature exists for — the phone in a pocket — so it never
     * suppresses; foreground is what lets [AlertGate.isBeingWatched] quiet a banner over the screen
     * he is on. Driven from the scene's `ON_START`/`ON_STOP`, the bracket iOS reads off
     * `.active`/`.background`.
     */
    fun enteredForeground() {
        alertGate.enteredForeground()
    }

    fun leftForeground() {
        alertGate.leftForeground()
    }

    /**
     * The terminal for a session came on screen, or went off it.
     *
     * Called from the same effect that follows and releases the session's control cluster, because
     * that effect's lifetime *is* "this session's terminal is up" — the two moments the gate's
     * answer changes. A session he is standing in must never buzz about itself; one he just left is
     * given [AlertGate.WATCHED_GRACE_MS] before its changes count as news, because opening a session
     * makes the desktop reclassify it a beat later. Mirrors iOS `DeckModel.watchingSession`.
     */
    fun watchingSession(hostId: String, sessionId: String) {
        alertGate.watching(hostId, sessionId)
    }

    fun stoppedWatchingSession(hostId: String, sessionId: String) {
        alertGate.stoppedWatching(hostId, sessionId)
    }

    /** The away line was read. It says what changed *while you were gone*, so it is said once. */
    fun dismissAwayReport() {
        if (awayReport == null) return
        awayReport = null
        publish()
    }

    private fun onFrame(link: HostLink, message: ServerMessage) {
        when (message) {
            /*
             * Output is routed by machine *and* by id. The machine is the new half and the important
             * one: two computers are entitled to use the same session id, and feeding one's bytes to
             * the other's emulator would be showing somebody another machine's work.
             *
             * It returns before the fold at the bottom, deliberately. Output is by far the chattiest
             * thing on this socket — thousands of frames while a build scrolls — and it changes
             * nothing the screens read: the bytes go into an emulator that redraws off [screenTick].
             * Refolding the collection for each one would rebuild every machine's summary to arrive
             * at a state that compares equal to the one already there.
             */
            is ServerMessage.Output -> {
                link.binding?.takeIf { it.sessionId == message.id }?.feed(message.data)
                // The one thing output changes outside the emulator: the control cluster re-reads
                // once the session has gone quiet, because the model line, the effort confirmation
                // and the permission footer are all read from what the far pty writes. A timer, not
                // a read per frame — see [SessionControlsController.noteOutput].
                link.controls?.noteOutput()
                // The same event moves the context window: it is read from what the far pty writes,
                // and the bar debounces it internally exactly as the cluster does.
                link.bar?.noteOutput()
                return
            }

            is ServerMessage.Detached,
            is ServerMessage.Pong,
            // `enrolled` cannot legitimately arrive here. It is the answer to a sign-in, which
            // happens on its own short socket before any of this exists — see
            // [dev.terminaldeck.android.signin.ServerSignIn] — so one on a machine's durable
            // connection is a frame nobody asked for. Dropped rather than acted on: it carries a
            // credential, and storing one this app did not request would be letting whatever is at
            // the other end of a socket re-key a paired machine.
            is ServerMessage.Enrolled,
            -> return

            is ServerMessage.Welcome -> {
                link.sessions = message.sessions.map { it.toView() }
                link.deviceName = message.deviceName
                link.capabilities = message.capabilities.toSet()
                // The one frame that says what kind of computer this is. Everything the screens
                // print about "the Mac" is really about whatever this resolves to, and an absent
                // field resolves to a neutral word rather than to a guess — see [HostPlatform].
                link.hostPlatform = HostPlatform.fromWire(message.hostPlatform)
                // Where this phone may start a session, decided on the machine the files are on.
                // Assigned straight across, null included: a machine that stops sending the field
                // is a machine that has been downgraded, and holding the old list would leave the
                // picker enforcing a rule that is no longer there.
                link.grantedFolders = message.folders
                // What build the machine is, so the phone can say the one honest thing it has to say
                // when its own build is ahead — see [HostVersion]. Bounded on arrival because it
                // renders on a chip beside terminal output; "" is a machine older than the field.
                link.appVersion = message.appVersion?.take(64).orEmpty()
                link.hostKind = message.hostKind?.take(32)
                link.hostName = message.hostName?.take(64)
                // This phone's own device id here, so the roster can name the row that is the device
                // in your hand and warn that removing it signs *this* phone out.
                link.myDeviceId = message.deviceId
                link.devices?.onWelcome(message.deviceId)
                // A welcome is a fresh connection — possibly to a different machine after a switch or
                // a re-pair — so the request clusters forget what the last one said and re-read on
                // the next visit. The `settings.changed`/`devices.changed` pushes keep them fresh
                // after that first read without a poll.
                link.devices?.renew()
                link.settings?.renew()
                link.github?.renew()
                // The host lifecycle cluster, on the same rule and for a sharper reason: a welcome
                // after a restart is *how* a restarted host reports it is back, so `renew` re-reads
                // its status on the next visit rather than showing the stale "restarting" note.
                link.hostControl?.renew()
                // The controls cluster is about a *session*, so a welcome does not re-read it — the
                // terminal screen calls `follow` and that is the only thing that knows which session
                // is on screen. What a welcome does is drop what the last connection said, for the
                // reason `dropped` gives: a reading is a claim about now.
                link.controls?.dropped()
                link.bar?.dropped()
                link.watch?.renew()
                link.localhost?.renew()
                link.devServer?.renew()
                link.copilot?.renew()
                // The look-inside and browser holders forget the last connection's answers, for the
                // reason the request clusters above do: a welcome may be a different machine after a
                // switch or a re-pair, and the screens re-read on their next appearance.
                link.filesGit?.renew()
                link.panels?.renew()
                link.machineBrowser?.renew()
                link.loaded = message.sessions.isNotEmpty() || link.loaded
                link.live = true
                // The first list after a connection came back. What is in it happened while this
                // phone was not listening, so it is reported as a line rather than as four banners.
                noteAlerts(link, AlertReason.CatchUp)
            }

            // The same list again, because somebody edited it at the desk. Handled identically to
            // the one in `welcome` and on purpose: the reason this frame exists is that a folder
            // removed while the phone sits there connected must leave the picker *now*, and a
            // client that only read the welcome would keep offering it until the app was reopened.
            is ServerMessage.Folders -> link.grantedFolders = message.folders

            is ServerMessage.Sessions -> {
                val wasLive = link.live
                link.sessions = message.sessions.map { it.toView() }
                link.loaded = true
                link.live = true
                // A list on a connection that was already up is news; one that arrives as a machine
                // comes back is a catch-up, and the difference is only in what is *done* with it.
                noteAlerts(link, if (wasLive) AlertReason.Live else AlertReason.CatchUp)
            }

            is ServerMessage.Exit -> {
                link.binding?.takeIf { it.sessionId == message.id }?.remoteExited(message.exitCode)
                link.sessions = link.sessions.map {
                    if (it.id == message.id) it.copy(status = "exited", exitCode = message.exitCode) else it
                }
            }

            is ServerMessage.Status -> {
                link.sessions = link.sessions.map {
                    if (it.id == message.id) it.copy(status = message.status) else it
                }
            }

            // `error` carries no session id, so this cannot be tied to a row. What it can do is stop
            // the terminal screen from silently showing nothing: the common cause is a re-attach
            // after the machine restarted, where the id the phone remembers no longer names
            // anything. Named, because with two machines paired "refused that" does not say which.
            is ServerMessage.Error -> {
                notify(say(link, message.message.ifEmpty { "That was refused." }))
                // A refused request is not going to be followed by a `created`, and a phone that
                // stayed armed would jump into the *next* session it was told about, whoever
                // started it.
                link.openWhenCreated = false
                // There is no `web.failed` — the three ways `web.open` can fail are all things
                // `error` already says — so a refusal has to reach the row that asked, or it sits at
                // "Opening…" forever. A no-op when nothing was opening.
                link.localhost?.failed(message.message.ifEmpty { "That was refused." })
                // And a handover claim or hand-back this phone had in flight: the error frame names no
                // request, so the watcher treats one arriving while exactly one answer was outstanding
                // as that answer's refusal, and draws Try again beside the machine's sentence. A no-op
                // when nothing was outstanding. Mirrors iOS `HostLink` → `WatchLink.wireErrored`.
                link.watch?.wireErrored(message.message)
            }

            is ServerMessage.Attached -> link.binding?.takeIf { it.sessionId == message.id }?.onAttached()

            // Put in the list here rather than waiting for the `sessions` frame the machine sends to
            // *other* devices: the phone that asked is told with the whole row, so that the tap which
            // started the session is also the tap that opens it. With two sessions in the same folder
            // there is no way to guess which row is the new one from a plain list.
            is ServerMessage.Created -> {
                if (link.sessions.none { it.id == message.session.id }) {
                    link.sessions = link.sessions + message.session.toView()
                    link.loaded = true
                }
                if (link.openWhenCreated) {
                    link.openWhenCreated = false
                    _created.value = OpenRequest(link.hostId, message.session.id)
                }
            }

            is ServerMessage.UploadReady,
            is ServerMessage.UploadAck,
            is ServerMessage.UploadDone,
            is ServerMessage.UploadFailed,
            -> {
                // Routed by the upload itself, which is the only thing that knows its own id. An
                // unclaimed frame belongs to one this phone has already forgotten — a cancel that
                // crossed with the last of its slices — and there is nothing to do but not act.
                link.upload?.onFrame(message)
            }

            // The machine ended the session this phone asked it to end. The row is removed here, on
            // the answer, and never on the tap — an optimistic removal over a refusal would leave a
            // live session missing with no way back but a reconnect. If this is the session on
            // screen, the terminal route reads the row's absence and pops itself: the machine noun
            // stays right because the route names its own machine. A refusal is a plain `error`.
            is ServerMessage.Closed -> {
                link.sessions = link.sessions.filter { it.id != message.id }
            }

            // The device roster and the two server-owned settings are request/response clusters with
            // their own `rid` bookkeeping, so the frame is handed to the cluster that asked. It
            // returns whether it claimed the frame; an unclaimed one answers a request this phone has
            // already forgotten — a switch or a reconnect that raced the reply — and there is nothing
            // to do but not act. The cluster publishes for itself; the fold below is harmless twice.
            is ServerMessage.DevicesRows,
            is ServerMessage.DevicesRevoked,
            is ServerMessage.DevicesChanged,
            -> {
                link.devices?.receive(message)
            }

            is ServerMessage.SettingsState,
            is ServerMessage.SettingsApplied,
            is ServerMessage.SettingsChanged,
            -> {
                link.settings?.receive(message)
            }

            // The host's GitHub: the answer to a read/connect/cancel/disconnect, and the unsolicited
            // `github.changed` that turns a shown code into "Connected as @…". Its own `rid`
            // bookkeeping lives in the controller; a frame it does not claim answered a request this
            // phone has already forgotten.
            is ServerMessage.GithubState,
            is ServerMessage.GithubChanged,
            -> {
                link.github?.receive(message)
            }

            // The host's own lifecycle over the relay — the answer to a status/restart/stop. "The
            // relay is the network": this is the status a server page shows when its SSH address is
            // an offline Tailscale name, and the confirmation of a restart/stop it sent over the
            // relay. Its `rid` bookkeeping lives in the controller.
            is ServerMessage.HostState -> {
                link.hostControl?.receive(message)
            }

            is ServerMessage.ControlsReading,
            is ServerMessage.ControlsApplied,
            -> {
                link.controls?.receive(message)
            }

            is ServerMessage.BrowserSurfacesRows -> {
                link.watch?.receive(message)
            }

            // Who holds the login handover on a watched window — an answer to a take/done of ours or an
            // unsolicited push. It changes what the overlay draws (the handover bar), so it does not
            // return early: it falls through to the fold like the strip does.
            is ServerMessage.BrowserHandover -> {
                link.watch?.receive(message)
            }

            /*
             * A screencast frame goes straight to the viewer and returns before the fold, for the
             * reason `output` does: it is the chattiest thing on this socket — one per drawn frame
             * of a live page — and it changes nothing any screen reads off [DeckUiState]. Refolding
             * every machine's summary per frame would rebuild the world to arrive at a state that
             * compares equal to the one already there.
             */
            is ServerMessage.BrowserFrame -> {
                link.watch?.receive(message)
                return
            }

            // The session bar's four capabilities, routed the same way and for the same reason: it
            // keeps its own `rid` bookkeeping, and an unclaimed frame answers a request this phone
            // has already forgotten — a session closed, a switch or a reconnect that raced the reply.
            is ServerMessage.UsageReading,
            is ServerMessage.AccountState,
            is ServerMessage.AccountSwitched,
            is ServerMessage.SessionSent,
            -> {
                link.bar?.receive(message)
            }

            // A login sign-out settling. The controller settles the row and, on success, re-reads the
            // account list so the signed-out login drops out. The machine's own sentence — ok or
            // refusal — is surfaced here as a toast, because the bar itself draws no sentences.
            is ServerMessage.LoginsSignedout -> {
                val claimed = link.bar?.receive(message) == true
                if (claimed && message.message.isNotEmpty()) notify(say(link, message.message))
            }

            is ServerMessage.Ports,
            is ServerMessage.WebOpened,
            -> {
                link.localhost?.receive(message)
            }

            is ServerMessage.DevState -> {
                link.devServer?.receive(message)
            }

            /*
             * The tunnel, which belongs to whatever is showing the page rather than to this fold.
             *
             * `net.data` is the second-chattiest thing on this socket after `output` — every byte of
             * every asset of a page being served through the relay — so it returns before the fold
             * for the reason output does. The tunnel is claimed by a screen through
             * [tunnelController]; over a machine no page is open on there is nothing holding one and
             * the frames are dropped, which is the honest answer to bytes for a stream nobody has.
             */
            is ServerMessage.TunnelOpened,
            is ServerMessage.TunnelClosed,
            is ServerMessage.NetData,
            is ServerMessage.NetAck,
            is ServerMessage.NetClose,
            -> {
                link.tunnels?.receive(message)
                return
            }

            // The copilot's own family. Routed together for the reason the bar's four are: the
            // controller keeps the bookkeeping, and a frame about a run this device no longer has is
            // dropped there rather than in a `when` that would have to know about runs.
            is ServerMessage.CopilotStateFrame,
            is ServerMessage.CopilotChat,
            is ServerMessage.CopilotTool,
            is ServerMessage.CopilotSessionsRows,
            is ServerMessage.CopilotLogRows,
            is ServerMessage.CopilotPendingRows,
            is ServerMessage.CopilotGrant,
            is ServerMessage.CopilotAsk,
            is ServerMessage.CopilotSettled,
            -> {
                link.copilot?.receive(message)
            }

            // The copilot's own files, routed to the controller that owns the Files card and its
            // editor — a `copilot.file.text` for a file this phone has navigated away from is dropped
            // there rather than in a `when` that would have to know which file is open.
            is ServerMessage.CopilotFilesRows,
            is ServerMessage.CopilotFileText,
            -> link.copilotFiles?.receive(message)

            // The routines family, to the controller that owns the Routines screen and its file
            // viewer. `routines.rows` answers run, hold, let-run and delete as well as the listing.
            is ServerMessage.RoutinesRows,
            is RoutineFile,
            -> link.routines?.receive(message)

            // The folder picker's answer — dropped inside the controller when no picker is open.
            is ServerMessage.FolderEntries -> folderBrowse.receive(message)

            // The "look inside" family — files, git status, a file's text and a diff.
            is FileListing,
            is FileText,
            is ServerMessage.GitStateFrame,
            is ServerMessage.GitPatch,
            -> link.filesGit?.receive(message)

            // The four read-only panels — artifacts, store, AI readiness, MCP.
            is PanelData -> link.panels?.receive(message)

            // The machine's own browser: the window list, a screenshot, an inspected element, a
            // recorder's steps and the profile list. A frame about a window this device no longer has
            // open is dropped inside the controller.
            is MachineBrowserState,
            is MachineShot,
            is ServerMessage.BrowserWindowPicked,
            is ServerMessage.BrowserRecordRows,
            is MachineProfileList,
            -> link.machineBrowser?.receive(message)
        }
        publish()
    }

    /**
     * A machine came back.
     *
     * Its session list is asked for again — it is the one piece of state that goes stale while the
     * socket is down — and anything of its that was on screen is attached again, which is what makes
     * a reconnect land the user back where they were with the scrollback replayed rather than on a
     * frozen screen.
     */
    private fun onReconnected(link: HostLink) {
        link.transport.send(ClientMessage.List)
        link.binding?.reattach()
    }

    /** "Studio: …" once there is more than one machine, because otherwise it does not say which. */
    private fun say(link: HostLink, sentence: String): String =
        if (links.size > 1) "${link.label}: $sentence" else sentence

    /* ------------------------------------------------------------------ intents -- */

    fun refresh() {
        val link = selected ?: return
        if (!link.transport.send(ClientMessage.List)) notify("Not connected.")
    }

    /** Retry the machine on screen now, because the user asked. */
    fun reconnect() {
        selected?.transport?.resume()
    }

    /**
     * The app returned to the foreground, or the OS says the network is back.
     *
     * The tick is realigned once, before anything reconnects, so the sockets that come back settle
     * onto one shared beat instead of each machine keeping whatever phase it had. Doing it per
     * transport would be N realignments, each one moving the tick the previous had just set.
     */
    fun resume() {
        heartbeat.realign()
        for (link in links.values) link.transport.resume()
    }

    /**
     * Pair with the machine behind six typed digits, **adding** it.
     *
     * ## Two steps, because a code carries no address
     *
     *  1. **The rendezvous.** [Rendezvous] explains it at length: the code names a slot at the
     *     relay, the machine showing the code is sitting in it, and the channel is Noise IK against a
     *     responder key both ends derive from the code. What comes back is an *address* and nothing
     *     else.
     *  2. **The pairing itself.** With the address in hand this is the path this app has always
     *     taken: dial the machine, run IK against its real key, and say `hello` with the code as the
     *     token. The far end mints a credential, sends it back inside `welcome`, and then refuses the
     *     connection because a human still has to approve the device.
     *
     * The address is stored before anything is sent: a device that has written down which machine it
     * is talking to can come back to the same one after a crash mid-handshake, and one that has not
     * would have spent a single-use token for nothing.
     *
     * Pairing with a machine already in the list replaces *that machine's* record and nothing else —
     * a re-pair after a revoke is a normal thing to do and it must not cost the user their other
     * machines. Every other machine keeps its socket through this; not one of them is touched.
     *
     * ## Why `pairingLookup` goes up before the first suspension
     *
     * The lookup is a memory-hard derivation and a round trip to a relay: about a second between
     * them, and the only thing on screen for all of it is a button. `pairingLookup` drives the
     * spinner on that button, so it is published before the coroutine suspends rather than after.
     */
    fun pair(raw: String) {
        val code = PairingCodes.parse(raw)
        if (code == null) {
            pairingError = "That is not a pairing code. It is six digits, like 123456."
            publish()
            return
        }
        if (pairingLookup) return

        pairingLookup = true
        pairingError = null
        publish()

        viewModelScope.launch {
            val offer = try {
                lookup(code, DEFAULT_RELAY)
            } finally {
                pairingLookup = false
            }
            if (offer == null) {
                pairingError = "No machine is showing that code. Check the digits, and that the code " +
                    "on the other machine has not run out — they last a minute."
                publish()
                return@launch
            }
            adoptPaired(offer, code)
        }
    }

    /** The half of [pair] that runs once an address is in hand. */
    private fun adoptPaired(offer: Rendezvous.Offer, code: String) {
        vault.beginPairing(
            hostId = offer.hostId,
            hostStaticPublicKey = offer.hostKey,
            relayUrl = offer.relayUrl,
            pairingToken = code,
        )
        val record = vault.pairing(offer.hostId) ?: return

        val existing = links[offer.hostId]
        if (existing != null) {
            // The same machine with a new token. Taken down and brought back up so the transport
            // reads the credential that was just written rather than retrying with the one that was
            // refused — and only this machine's link is touched.
            existing.stop()
            existing.record = record
            existing.transport.connect()
        } else {
            adopt(record).transport.connect()
        }

        // The machine that was just paired is the one the user is looking at. Anything else would be
        // a pairing that appears to have done nothing.
        selectedHostId = offer.hostId
        vault.selectHost(offer.hostId)
        addingHost = false
        pairingError = null
        publish()
    }

    fun clearPairingError() {
        pairingError = null
        publish()
    }

    /* ---------------------------------------------------------------- signing in -- */

    /**
     * The user asked to add a **server** — the other kind of machine, and the other ceremony.
     *
     * A device is paired with a code minted by the app at the far end, which presupposes the app is
     * there. A server has nobody sitting at it and nothing to mint anything, so it is reached by an
     * address and a login it already trusts. Two ceremonies, one list of machines, and the screen
     * says which is which. See `SERVERS-DESIGN.md`.
     */
    fun beginAddingServer() {
        addingServer = true
        serverSignInError = null
        serverSignInWorking = null
        serverConnectedName = null
        connectingServerId = null
        serverConnector.resetLogin()
        publish()
    }

    /**
     * Back out of adding a server.
     *
     * The sign-in in flight, if there is one, is cancelled with it. The server may still finish its
     * side — an SSH probe is not something a phone can call back — and that is why the screen says
     * so rather than this pretending it undid anything.
     */
    fun cancelAddingServer() {
        serverSignInJob?.cancel()
        serverSignInJob = null
        signingIn = false
        addingServer = false
        serverSignInError = null
        serverSignInWorking = null
        connectingServerId = null
        serverConnectedName = null
        /*
         * The held SSH connection goes **before** the phase is cleared, and the order is the whole
         * point: `resetLogin` puts the phase back to `Editing`, so reading `Added` off it
         * afterwards finds nothing and the session for the server whose card was open is left
         * open until the process ends. One leaked socket per cancelled login, on somebody else's
         * sshd.
         */
        (serverConnector.state.value.login as? LoginPhase.Added)?.let { serverConnector.release(it.server.id) }
        // And the phase itself, because leaving it on `Added` would reopen the screen on somebody
        // else's receipt the next time they pressed Add a server.
        serverConnector.resetLogin()
        publish()
    }

    /**
     * Sign in to a server: parse the address, spend the login once, keep the credential.
     *
     * The sequence is `enroll` → `enrolled` → `hello` → `welcome` on one socket, driven by
     * [dev.terminaldeck.android.signin.EnrollExchange], and what lands here is the end of it. The
     * three things done on success are the same three [adoptPaired] does, in the same order and for
     * the same reasons — write the record, bring that one machine's link up, and select it, because
     * a sign-in that left the user looking at a different machine would read as having done nothing.
     *
     * ## What is checked here, and why here
     *
     * The username and the secret are bounded against [Protocol]'s enroll caps **before** anything
     * is sent. The server refuses an over-long field by closing the socket, so a phone that sends
     * one spends the connection and gets no sentence back; checked at this moment the person is
     * still looking at the field they can fix.
     *
     * ## The secret
     *
     * It arrives as a parameter, goes into one [ServerSignIn.Request], and is referenced nowhere
     * else. It is not written to the vault, not put in a field, not logged, and not carried into the
     * outcome. After this function returns, the only copy left on the phone is the one in the text
     * field the person typed it into, which the screen clears the moment it succeeds.
     */
    fun signInToServer(rawAddress: String, rawUsername: String, secret: String, method: EnrollMethod) {
        // One at a time. Two `enroll` frames for one login are two SSH probes on somebody else's
        // server and two attempts against its rate limiter — and the second is the one that gets a
        // person locked out of their own machine.
        if (signingIn) return

        val address = when (val parsed = ServerAddress.parse(rawAddress)) {
            is ServerAddress.Companion.Result.Bad -> return failSignIn(parsed.sentence)
            is ServerAddress.Companion.Result.Ok -> parsed.address
        }

        // Trimmed, because a keyboard's trailing space is not part of a username — and the server
        // trims it too, so a client that did not would be checking a different string from the one
        // that gets used.
        val username = rawUsername.trim()
        if (username.isEmpty()) return failSignIn("Type the username you log in to that server with.")
        if (username.length > Protocol.MAX_ENROLL_USERNAME_LENGTH) {
            return failSignIn("That username is too long for a login — ${Protocol.MAX_ENROLL_USERNAME_LENGTH} characters at most.")
        }
        // Refused rather than stripped. A login is not display text, and stripping turns one value
        // into a different, legal-looking one — which is a sign-in attempt as somebody else.
        if (username.any { it.code <= 0x1f || it.code == 0x7f }) {
            return failSignIn("That username has something in it that cannot be part of a login.")
        }
        if (secret.isEmpty()) {
            return failSignIn(
                if (method == EnrollMethod.Password) "Type the password for that login." else "Paste the private key for that login."
            )
        }
        if (Protocol.overBytes(secret, Protocol.MAX_ENROLL_SECRET_BYTES)) {
            return failSignIn("That key is too large to send. A server takes at most ${Protocol.MAX_ENROLL_SECRET_BYTES / 1024} KB.")
        }

        signingIn = true
        serverSignInError = null
        // A real sentence rather than a bare spinner: this is the longest wait in the app — the
        // server runs an SSH probe against its own sshd and then a memory-hard hash — and a spinner
        // with nothing beside it is indistinguishable from one that has stuck.
        serverSignInWorking = "Signing in to ${address.shortId}…"
        publish()

        val job = viewModelScope.launch {
            val result = try {
                serverSignIn(
                    ServerSignIn.Request(
                        address = address,
                        username = username,
                        secret = secret,
                        method = method,
                        // The durable key, not a throwaway: the server binds the device row it mints
                        // to the key that shook hands, and every reconnect afterwards is admitted by
                        // it. See ServerSignIn's header.
                        identity = vault.identity(),
                        deviceName = deviceName,
                    )
                )
            } finally {
                signingIn = false
            }
            when (result) {
                is ServerSignIn.Result.SignedIn -> adoptSignedIn(address, result)
                is ServerSignIn.Result.Refused -> failSignIn(result.sentence)
                is ServerSignIn.Result.Unreachable -> failSignIn(result.sentence)
            }
        }
        // Kept only while it is still running. A job that finished before `launch` returned is
        // nothing to cancel, and storing it would leave a dead handle behind for the next cancel to
        // act on. See [signingIn].
        serverSignInJob = job.takeIf { it.isActive }
    }

    /* ----------------------------------------------------- the SSH way in -- */

    /**
     * Log in to a **bare** server over SSH — the door Android did not have.
     *
     * The other half of the one login screen. A pasted server address goes through
     * [signInToServer], because the block is *for* a machine with no SSH login this phone holds;
     * a hostname or an IP comes here, which is an ordinary SSH login and the only route that can
     * reach a server with nothing installed on it at all.
     *
     * `port` arrives as the string the field holds. Empty means 22 and the field says so; anything
     * that is not a number is refused by the connector with the sentence about ports rather than
     * quietly becoming 22 — a form that silently chooses a port is what told Asad his server was
     * off when it was listening on 2222.
     */
    fun logInToServer(
        address: String,
        port: String,
        username: String,
        secret: String,
        kind: ServerCredentialKind,
    ) {
        if (serverConnector.state.value.isSigningIn) return
        val typedPort = port.trim()
        // `null` is "empty, so 22"; a number that will not parse is handed on as an out-of-range
        // one so the connector answers with the port sentence rather than this deciding for it.
        val realPort = if (typedPort.isEmpty()) null else typedPort.toIntOrNull() ?: 0
        viewModelScope.launch {
            serverConnector.signIn(
                name = address.trim(),
                address = address,
                port = realPort,
                username = username,
                secret = secret,
                kind = kind,
            )
        }
    }

    /** Ask a server what is on it. The card's own Check, and its Look again. */
    fun checkServer(serverId: String) {
        viewModelScope.launch { serverConnector.look(serverId) }
    }

    /** Put the headless host on it, watched, with the server's own output. */
    fun installOnServer(serverId: String) {
        viewModelScope.launch { serverConnector.install(serverId) }
    }

    /**
     * *"If it exists, it brings it up and asks you to connect."*
     *
     * Two verbs joined, because the wait between them has nothing in it for the person to decide.
     * The connect runs only when starting it actually produced something to dial — a host takes a
     * moment to reach its relay, and the card redraws into the refusal when it has not yet.
     */
    fun startAndConnectServer(serverId: String) {
        viewModelScope.launch {
            serverConnector.bringUp(serverId)
            connectToServer(serverId)
        }
    }

    fun stopServer(serverId: String) {
        viewModelScope.launch { serverConnector.stop(serverId) }
    }

    /** Bring the host up without pairing this phone — the lifecycle row's standalone open. */
    fun startServer(serverId: String) {
        viewModelScope.launch { serverConnector.start(serverId) }
    }

    /**
     * Restart the host over SSH against its systemd user unit — his "one button to restart", which
     * also activates a stopped or unitless host. See [ServerConnector.restart].
     */
    fun restartServer(serverId: String) {
        viewModelScope.launch { serverConnector.restart(serverId) }
    }

    /**
     * Connect this phone to the host running on a server it is logged in to.
     *
     * Through the door the app already has: the server address that host prints, spent by
     * [signInToServer] over the relay. Nothing new is invented for it — the host verifies the same
     * SSH login against its own sshd and mints a device credential, exactly as it does for an
     * address somebody pasted.
     */
    fun connectToServer(serverId: String) {
        val ticket = serverConnector.connectTicket(serverId) ?: return
        connectingServerId = serverId
        signInToServer(ticket.address, ticket.username, ticket.secret, ticket.method)
    }

    /** Take the machine away again, and leave the server logged in. */
    fun disconnectServer(serverId: String) {
        serverConnector.server(serverId)?.linkedHostId?.let(::forget)
        serverConnector.markDisconnected(serverId)
        serverConnectedName = null
        publish()
    }

    /** The half of [signInToServer] that runs once a credential is in hand. */
    private fun adoptSignedIn(address: ServerAddress, result: ServerSignIn.Result.SignedIn) {
        vault.signedIn(
            hostId = address.hostId,
            hostStaticPublicKey = address.hostKey,
            relayUrl = address.relayUrl,
            credential = result.credential,
            deviceId = result.deviceId,
            deviceName = result.deviceName,
        )
        val record = vault.pairing(address.hostId) ?: return failSignIn(
            "This phone could not save that server's credential. It has to be signed in to again."
        )

        val existing = links[address.hostId]
        if (existing != null) {
            // The same machine with a new credential. Taken down and brought back up so its socket
            // reads what was just written rather than retrying with whatever it was refused with —
            // and only this machine's link is touched.
            existing.stop()
            existing.record = record
            existing.transport.connect()
        } else {
            adopt(record).transport.connect()
        }

        selectedHostId = address.hostId
        vault.selectHost(address.hostId)
        /*
         * A connect started from a server's card **stays on that card**, and that is the
         * requirement rather than a nicety.
         *
         * *"If it exists, it brings it up and asks you to connect… then you can connect, and
         * disconnect if you want."* Closing the screen at the moment the connect lands would drop
         * somebody on the machines list with no receipt, and take away the Disconnect they were
         * just told about. A pasted address has no card behind it and closes as it always did.
         */
        val fromCard = connectingServerId
        if (fromCard != null) {
            serverConnector.markConnected(fromCard, address.hostId)
            serverConnectedName = record.label
            connectingServerId = null
        } else {
            addingServer = false
        }
        addingHost = false
        serverSignInWorking = null
        serverSignInError = null
        pairingError = null
        notify("Signed in to ${record.label}.")
        publish()
    }

    /** Every way a sign-in ends badly: the screen stays up, holding the sentence and the fields. */
    private fun failSignIn(sentence: String) {
        serverSignInWorking = null
        serverSignInError = sentence
        // The card's Connect is no longer in flight. Left set, the next *successful* sign-in from
        // anywhere would be written down as this server's connect.
        connectingServerId = null
        publish()
    }

    /** The user asked for the pair screen with an empty field, to add another machine. */
    fun beginAddingHost() {
        addingHost = true
        pairingError = null
        publish()
    }

    /**
     * Back out of adding a machine.
     *
     * Also the way out of the pair screen when the machine on screen has not been approved yet and
     * another one has: the selection moves to a machine that actually works, rather than leaving the
     * user on a wait they cannot leave.
     */
    fun cancelAddingHost() {
        addingHost = false
        if (selected?.approved != true) {
            links.values.lastOrNull { it.approved }?.let {
                selectedHostId = it.hostId
                vault.selectHost(it.hostId)
            }
        }
        publish()
    }

    /** Give a machine a name a person can pick out of a list. Null clears it. */
    fun rename(hostId: String, nickname: String?) {
        val link = links[hostId] ?: return
        vault.rename(hostId, nickname)
        vault.pairing(hostId)?.let { link.record = it }
        publish()
    }

    /**
     * Forget one machine.
     *
     * Deliberately not "log out": the device key survives, so pairing with the same machine again
     * does not create a second entry in its device list for one physical phone. Every *other*
     * machine is untouched — that is the whole point, and it is why this takes an id rather than
     * being a global reset.
     *
     * Forgetting the last one is the exception. A public key a machine still lists is a device that
     * machine would let back in without a code, so a phone that has unpaired from *everything*
     * should stop being that device — which is exactly what [DeviceVault.unpairAll] does and why it
     * must not run while any pairing remains.
     */
    fun forget(hostId: String) {
        val link = links.remove(hostId) ?: return
        // Its sessions are not going to change again, and keeping them would make a re-pair look
        // like a machine where everything happened at once.
        alerts.forget(hostId)
        link.stop()
        vault.forget(hostId)
        if (vault.pairings().isEmpty()) vault.unpairAll()

        if (selectedHostId == hostId) {
            selectedHostId = links.keys.firstOrNull()
            vault.selectHost(selectedHostId)
        }
        addingHost = false
        publish()
    }

    /** The machine on screen. What the pair screen's "use a different code" means. */
    fun forgetSelected() {
        selectedHostId?.let(::forget) ?: links.keys.firstOrNull()?.let(::forget)
    }

    /**
     * Start a session on the machine on screen.
     *
     * Only reachable when it advertised [Capability.CREATE] in its `welcome`; the button is absent
     * otherwise. Sending a message the machine's parser has never heard of would close the socket
     * for `bad-message`, so a hopeful client is a broken one.
     *
     * `folder` is one the machine itself offered this device — [DeckUiState.startableFolders], which
     * is that machine's own grant list when it sent one and the old cwd-derived list when it is too
     * old to. Per machine by construction either way: offering a Mac's folder to a Windows PC would
     * be a picker full of choices that fail. Null means "wherever you would have started one".
     */
    fun newSession(folder: String? = null) {
        val link = selected ?: return
        if (!_uiState.value.canCreateSessions) {
            notify("This machine cannot start sessions from the phone.")
            return
        }
        // Somebody chose no folders for this phone, so every `create` it could send is already
        // refused. Said here rather than sent and refused, because the round trip would answer with
        // the same sentence a second later and the screen would flash a button that never worked.
        // The button is absent in this state — see [DeckUiState.canStartSession] — so this is the
        // backstop for a folder list emptied between the draw and the tap.
        if (_uiState.value.noFoldersGranted) {
            notify(_uiState.value.noFoldersSentence)
            return
        }
        // Remembered so the `created` that comes back *opens* the session rather than merely adding
        // a row. Cleared on arrival and by a refusal, so a `created` this phone did not ask for never
        // yanks the user into somebody else's session.
        link.openWhenCreated = true
        val size = link.binding
        if (!link.transport.send(ClientMessage.create(folder, size?.measuredCols, size?.measuredRows))) {
            link.openWhenCreated = false
            notify("Not connected.")
        }
    }

    /**
     * A session a machine has just started for this phone, for the navigation to consume.
     *
     * Carries the machine as well as the session. A session id is unique on the computer that minted
     * it and nothing makes it unique across two of them, so a request with only an id would open
     * whichever machine happened to be on screen — with two paired, a coin flip.
     */
    private val _created = MutableStateFlow<OpenRequest?>(null)
    val created: StateFlow<OpenRequest?> = _created.asStateFlow()

    fun createdHandled() {
        _created.value = null
    }

    /**
     * Open the session a notification tap named — the phone half of tap-to-open.
     *
     * [AlertCenter] wrote the machine and the session onto the notification's intent; nothing read
     * them back until now, so a tap on a "your session needs you" alert only ever brought the app to
     * the front. This is the read, mirroring iOS `NotificationRouter` → `DeckModel.open`.
     *
     * The id is validated the way every id off the back stack is — a notification's tag survives
     * process death and a machine being forgotten, so an id that no longer names anything is a normal
     * thing to arrive with, not a crash. It is funnelled through the same [OpenRequest] the machine's
     * `created` frame uses, so the one navigation effect lands the person on the sessions stack and
     * then the terminal; [open] there selects the machine and attaches, and the route pops itself if
     * the session has since gone.
     */
    fun openFromAlert(hostId: String, sessionId: String) {
        if (hostId.isEmpty() || !Protocol.isValidSessionId(sessionId)) return
        _created.value = OpenRequest(hostId, sessionId)
    }

    /**
     * Open a session on one machine.
     *
     * The `attach` frame is not sent here. It goes out when the view reports its measured size, so
     * that the machine's replay arrives already the right width — see
     * [RemoteSessionBinding.onSizeChanged].
     *
     * Selecting the machine is part of opening it: the screens below this are the facade over the
     * selected machine, and a terminal open on one computer under another one's name is the bug this
     * whole split exists to prevent.
     */
    fun open(hostId: String, sessionId: String): RemoteSessionBinding? {
        val link = links[hostId] ?: return null
        if (selectedHostId != hostId) {
            selectedHostId = hostId
            vault.selectHost(hostId)
            publish()
        }
        val existing = link.binding
        if (existing != null && existing.sessionId == sessionId) return existing
        existing?.close()

        val created = RemoteSessionBinding(
            sessionId = sessionId,
            transport = link.transport,
            onScreenUpdate = { _screenTick.update { tick -> tick + 1 } },
            onTitleChange = { _screenTick.update { tick -> tick + 1 } },
            onCopy = ::copyToClipboard,
            onPaste = clipboard::read,
            onSendFailed = { notify("Not connected — that did not reach ${link.label}.") },
        )
        link.binding = created
        return created
    }

    fun closeSession(hostId: String) {
        links[hostId]?.closeSession()
    }

    /**
     * End a session on the machine on screen, for good.
     *
     * Only reachable when it advertised [Capability.CLOSE]; the ✕ is absent otherwise, and this is
     * confirmed once in the UI before it is called — closing does not come back. The row is not
     * removed here: it goes when the machine answers `closed`, for the reason its handler gives. A
     * refusal arrives as a plain `error` and is shown by the banner.
     */
    fun endSession(sessionId: String) {
        val link = selected ?: return
        if (!_uiState.value.canCloseSessions) {
            notify("This machine cannot close sessions from the phone.")
            return
        }
        if (!link.transport.send(ClientMessage.Close(sessionId))) notify("Not connected.")
    }

    /**
     * Give a session a name of this person's choosing, on the machine on screen.
     *
     * *"for being able to rename sessions."* Only reachable when the machine advertised
     * [Capability.RENAME] — the Rename row is absent otherwise, and this is the backstop for a
     * capability withdrawn between the draw and the tap. The [title] is sent exactly as typed: an
     * **empty** one is not a mistake and is not a cancel — it tells the machine to derive its own
     * name from the folder again, the only way back from a rename. The row is not changed here; it
     * changes when the machine's next `sessions` frame arrives, so every device sees one answer.
     */
    fun renameSession(sessionId: String, title: String) {
        val link = selected ?: return
        if (!_uiState.value.canRenameSessions) {
            notify("This machine cannot rename sessions from the phone.")
            return
        }
        if (!link.transport.send(ClientMessage.Rename(sessionId, title))) notify("Not connected.")
    }

    /* --------------------------------------------------- devices & server settings -- */

    /** Ask for the roster once when the Devices screen opens. The `devices.changed` push keeps it fresh. */
    fun openDevices() {
        selected?.devices?.ensureRead()
    }

    /** The user asked to re-read the roster now. */
    fun refreshDevices() {
        selected?.devices?.refresh()
    }

    /** Remove one device from the machine on screen. Confirmed once in the UI first — it does not come back. */
    fun revokeDevice(deviceId: String) {
        selected?.devices?.revoke(deviceId)
    }

    /** Ask for the machine's two server-owned settings once when the Settings screen opens. */
    fun openServerSettings() {
        selected?.settings?.ensureRead()
    }

    /** Change one of the machine's server-owned settings. The outcome is the machine's own sentence. */
    fun applyServerSetting(key: ServerSettingKey, value: String) {
        selected?.settings?.apply(key, value)
    }

    /**
     * The bar of the machine whose session is on screen, or null.
     *
     * **Not** `firstOrNull { it.bar != null }`: every link is given a controller when it is built, so
     * that expression answers with whichever machine is first in the map — a machine that has been
     * offline for a week on a phone with five paired. Every verb below acts on the session somebody
     * is looking at, and only one cluster is ever following one.
     */
    private fun following(): SessionBarController? =
        links.values.firstOrNull { it.bar?.isFollowing == true }?.bar

    /* ------------------------------------------------------------- the session bar -- */

    /** The ring was pressed. The one reading that boots an agent on the other machine. */
    fun refreshUsage() {
        following()?.refresh()
    }

    /** Sign one login out on the machine of the session on screen. See [SessionBarController.signOut]. */
    fun signOutAccount(accountId: String) {
        following()?.signOut(accountId)
    }

    fun switchAccount(accountId: String) {
        following()?.switchAccount(accountId)
    }

    /* -------------------------------------------------------------- localhost + web -- */

    fun openLocalhost() {
        selected?.localhost?.ensureRead()
    }

    fun refreshPorts() {
        selected?.localhost?.refresh()
    }

    /** Open a listening port on the machine, in that machine's own browser. */
    fun openPort(port: Int) {
        selected?.localhost?.open(port)
    }

    /** Open an address on the machine — what a ready dev server's own url is opened through. */
    fun openOnMachine(url: String) {
        selected?.localhost?.openUrl(url)
    }

    /* ------------------------------------------------------------------ the tunnel -- */

    /**
     * Serve one of the machine's ports **here**, on this phone's own loopback.
     *
     * The other half of [openPort], and the two are different acts rather than two spellings of
     * one: `web.open` puts a tab on the machine's screen, this puts the page in your hand. Both are
     * offered because both are the right answer to different questions — a dev server you want to
     * *look at* and a page you want to *use*.
     */
    fun servePort(port: Int) {
        selected?.tunnels?.open(port)
    }

    /** The page closed. The machine is told, so it is not left holding a socket. */
    fun closeServedPort() {
        selected?.tunnels?.close()
    }

    /* --------------------------------------------------------------- look inside -- */

    /**
     * The selected machine's files/git controller, or null when nothing is selected.
     *
     * Handed to [dev.terminaldeck.android.ui.MachineToolsSection] rather than folded into
     * [DeckUiState], because the four screens behind it read the machine's latest answer as Compose
     * state on the controller and recompose from there — a file's bytes are read by one screen at a
     * time and change nothing any other surface draws. The section re-fetches this on each ui-state
     * change, so a machine switch hands over the new machine's controller by construction.
     */
    fun filesGit(): FilesGitController? = selected?.filesGit

    /** The selected machine's panels controller, or null when nothing is selected. See [filesGit]. */
    fun panels(): PanelsController? = selected?.panels

    /* ---------------------------------------------------------------------- copilot -- */

    /** The tab opened. `hello` and `attach` — both `read`, and neither spends anything. */
    fun openCopilot() {
        selected?.copilot?.open()
    }

    /** The tab closed. Detach, never stop: leaving a screen is not asking for a run to be killed. */
    fun closeCopilot() {
        selected?.copilot?.close()
    }

    /** Start this device's run. The one verb that spends money, and only ever a tap. */
    fun startCopilot() {
        selected?.copilot?.start()
    }

    fun cancelCopilotTurn() {
        selected?.copilot?.cancel()
    }

    fun stopCopilotRun() {
        selected?.copilot?.stopRun()
    }

    /**
     * End this device's run and start a fresh one in the same folder — the copilot's Restart.
     *
     * The copilot has no list, no +, and no per-row Delete, so this is the only way to a clean slate.
     * Mirrors iOS's `restartCopilot` and the desktop's `useCopilot.restart`; the sequencing (stop, then
     * start once the run is confirmed gone) lives in [CopilotController.restart].
     */
    fun restartCopilot() {
        selected?.copilot?.restart()
    }

    /** Show or hide the copilot's scan on that machine's screen — driving mode. */
    fun setCopilotInteractive(on: Boolean) {
        selected?.copilot?.setInteractive(on)
    }

    /** Returns whether the composer may clear its draft. False keeps it in the box. */
    fun sayToCopilot(text: String): Boolean = selected?.copilot?.say(text) ?: false

    fun answerCopilot(approved: Boolean) {
        selected?.copilot?.answer(approved)
    }

    fun readCopilotLog(before: String? = null) {
        selected?.copilot?.readLog(before)
    }

    fun refreshCopilotSessions() {
        selected?.copilot?.refreshSessions()
    }

    fun dismissCopilotNotice() {
        selected?.copilot?.dismissNotice()
    }

    /* ------------------------------------------------------------- the copilot's files -- */

    /** Ask what files the copilot reads — a listing, nothing opened. `read` tier; spends nothing.
     *  Asked by the Files card on the control screen, and again when the capability turns up. */
    fun loadCopilotFiles() {
        selected?.copilotFiles?.loadFiles()
    }

    fun openCopilotFile(id: String) {
        selected?.copilotFiles?.openFile(id)
    }

    fun closeCopilotFile() {
        selected?.copilotFiles?.closeFile()
    }

    /** Returns whether the frame went. False keeps the draft in the box. */
    fun saveCopilotFile(id: String, text: String): Boolean =
        selected?.copilotFiles?.saveFile(id, text) ?: false

    /** Put the instructions this build ships back. Returns whether the frame went. */
    fun restoreCopilotInstructions(): Boolean =
        selected?.copilotFiles?.restoreInstructions() ?: false

    /** Forget one memory, by name. Returns whether the frame went. */
    fun forgetCopilotMemory(name: String): Boolean =
        selected?.copilotFiles?.forgetMemory(name) ?: false

    /* ----------------------------------------------------------------- the routines -- */

    /** Every routine on the machine. The answer to each of the four verbs below as well as itself. */
    fun loadRoutines() {
        selected?.routines?.load()
    }

    /** Run one now. Starts an agent turn on that machine. */
    fun runRoutine(id: String) {
        selected?.routines?.run(id)
    }

    /** Hold one. Its file is not touched. */
    fun holdRoutine(id: String) {
        selected?.routines?.hold(id)
    }

    /** Let one run again. Clears the hold and the failure count with it. */
    fun armRoutine(id: String) {
        selected?.routines?.arm(id)
    }

    /** Delete one. Its file is removed from the machine's disk — the screen confirms first. */
    fun deleteRoutine(id: String) {
        selected?.routines?.delete(id)
    }

    /** Read one routine's file. There is no verb that writes one back. */
    fun openRoutine(id: String) {
        selected?.routines?.openRoutine(id)
    }

    fun closeRoutine() {
        selected?.routines?.closeRoutine()
    }

    fun dismissRoutineNotice() {
        selected?.routines?.dismissNotice()
    }

    /* ---------------------------------------------------------------- the dev server -- */

    /**
     * Ask what each granted folder's dev server is doing.
     *
     * Only the folders the machine itself published — anything else is refused over there, and
     * asking would spend a frame to be told off.
     */
    fun openDevServers() {
        val link = selected ?: return
        link.devServer?.ensureRead(_uiState.value.startableFolders)
    }

    fun startDevServer(folder: String) {
        selected?.devServer?.start(folder)
    }

    /**
     * Copy one thing, from a screen that already knows exactly what it wants copied.
     *
     * Not [copy], which decides between a selection and the visible screen because only the terminal
     * has that choice to make. A chat bubble is one message and the copy button on it means that
     * message, so there is nothing to decide and nothing to fall back to.
     */
    fun copyText(text: String) {
        if (text.isEmpty()) return
        copyToClipboard(text)
        notify("Copied.")
    }

    /* ---------------------------------------------------------------- controls -- */

    /**
     * The terminal screen opened a session — read its control cluster.
     *
     * Called after the attach, because the question it asks is about a session this socket has been
     * told is on screen. A no-op over a machine that does not advertise `controls`, so an older
     * desktop simply never grows the button.
     */
    fun followControls(hostId: String, sessionId: String): SessionClaim {
        val controls = links[hostId]?.controls?.follow(sessionId) ?: 0
        /*
         * The bar follows the same session, from the same call.
         *
         * Two clusters, one screen, one lifetime: both are about *the session on screen*, both are
         * dropped when it closes, and splitting the two calls is how one of them ends up following a
         * session the other has left. Found by looking at a real terminal with no bar over it — the
         * cluster was following and the bar had never been told which session to ask about.
         */
        val bar = links[hostId]?.bar?.follow(sessionId) ?: 0
        return SessionClaim(controls, bar)
    }

    /**
     * A screen that was following a session has gone.
     *
     * The claim it was handed decides whether anything is actually torn down — see
     * [SessionControlsController.release]. Compose runs an incoming screen's effects *before* the
     * outgoing screen's `onDispose`, so a terminal that forgot unconditionally would clear the
     * session the conversation had already claimed, one frame after the conversation opened.
     */
    fun releaseSession(hostId: String, claim: SessionClaim) {
        links[hostId]?.controls?.release(claim.controls)
        links[hostId]?.bar?.release(claim.bar)
    }

    /** Change one control on the session the terminal screen is showing. */
    fun applyControl(hostId: String, control: ControlName, value: String) {
        links[hostId]?.controls?.apply(control, value)
    }

    fun dismissControlsNotice(hostId: String) {
        links[hostId]?.controls?.dismissNotice()
    }

    /* ------------------------------------------------------------------- watch -- */

    /** Ask the machine on screen for its watchable windows, once, when the strip is opened. */
    fun openWatch() {
        selected?.watch?.ensureRead()
    }

    /** The user pulled to refresh the strip. */
    fun refreshWatch() {
        selected?.watch?.refresh()
    }

    /**
     * The viewer's sink for frames of the machine on screen.
     *
     * Handed the controller rather than a copy of it, because the viewer needs the object it can
     * ack and send gestures through — one live cast, one canvas. Null when the machine on screen
     * offers no watching, which is the same test the strip draws off.
     */
    fun watcher(): WatchController? = selected?.watch?.takeIf { it.offered() }

    /* --------------------------------------------------------- machine browser -- */

    /** Ask the machine on screen for its open browser windows, once, when the home opens. */
    fun openMachineBrowser() {
        selected?.machineBrowser?.ensureRead()
    }

    /** The user pulled to refresh the window list. */
    fun refreshMachineBrowser() {
        selected?.machineBrowser?.refresh()
    }

    /** Read the machine's browser profiles — sent on every appearance, because this family has no
     *  push. */
    fun readMachineProfiles() {
        selected?.machineBrowser?.readProfiles()
    }

    /**
     * The controller for the machine on screen, or null when it offers no browser driving.
     *
     * Handed to the driven-window and overlay screens rather than a copy of its state, because they
     * send verbs — go, act, size, bind, screenshot, pick — through the same object whose answers
     * redraw them. The same shape as [watcher], and the same test: null when the machine on screen
     * stopped offering `browser.control`, which is what makes the screen pop rather than draw dead.
     */
    fun machineBrowser(): MachineBrowserController? = selected?.machineBrowser?.takeIf { it.offered() }

    /** Open a window on the machine — the home's `+` sheet. */
    fun openMachineWindow(url: String?, isolated: Boolean, session: String?) {
        selected?.machineBrowser?.openWindow(url, isolated, session)
    }

    /** Attach a window to a session, or detach with a null session — the home's row menu. */
    fun bindMachineWindow(id: String, session: String?) {
        selected?.machineBrowser?.bind(id, session)
    }

    /** Close a window on the machine — the home's swipe and its row menu. */
    fun closeMachineWindow(id: String) {
        selected?.machineBrowser?.act(id, dev.terminaldeck.android.protocol.BrowserWindowAction.Close)
    }

    /** Switch the machine's browser to a profile. */
    fun useMachineProfile(id: String) {
        selected?.machineBrowser?.useProfile(id)
    }

    /** Empty a profile's jar on the machine. */
    fun clearMachineProfile(id: String) {
        selected?.machineBrowser?.clearProfile(id)
    }

    /** Type text into the session open on one machine: the key bar, and paste. */
    fun type(hostId: String, text: String) {
        val link = links[hostId] ?: return
        val live = link.binding ?: return
        if (!link.transport.send(ClientMessage.Input(live.sessionId, text))) {
            notify("Not connected — that did not reach ${link.label}.")
        }
    }

    /**
     * Give the open session a name of this person's choosing — the terminal's Rename row.
     *
     * The session is the one this host has open, exactly as [type] and [paste] read it, because the
     * terminal renames the session it is standing in — by host, resolving the bound session itself,
     * which is why it is not [renameSession] (that one takes an explicit session id from the list).
     * An **empty** [title] is passed through
     * unchanged rather than refused: the machine reads it as *take my name off it* and derives one
     * from the folder again, which the wire's [ClientMessage.Rename] documents and which is the only
     * way back from a rename. Gated up in the UI on [DeckUiState.canRenameSessions], so this is only
     * ever called for a machine that advertised `rename`; a stray call over a machine that did not
     * closes the socket for `bad-message`, so the gate is not optional.
     */
    fun renameForegroundSession(hostId: String, title: String) {
        val link = links[hostId] ?: return
        val live = link.binding ?: return
        if (!link.transport.send(ClientMessage.Rename(live.sessionId, title))) {
            notify("Not connected — the new name did not reach ${link.label}.")
        }
    }

    /**
     * Paste the clipboard into the session open on one machine.
     *
     * Through [RemoteSessionBinding.paste], which goes through `TerminalEmulator.paste`, which is
     * where bracketed paste lives: if the program on the machine asked for it — DECSET 2004, which
     * every shell and every agent CLI sets — the text is wrapped in `ESC[200~`…`ESC[201~` and
     * arrives as **one** paste. Without that a four-line paste submits on its first newline and runs
     * the other three as commands.
     *
     * An oversized clipboard is refused with both numbers rather than quietly shortened. Silently
     * truncating is the worst available behaviour: the user watches text land, believes all of it
     * did, and the command that runs is not the command they copied.
     */
    fun paste(hostId: String) {
        val text = clipboard.read()
        if (text.isNullOrEmpty()) {
            notify("The clipboard is empty.")
            return
        }
        val refusal = pasteRefusal(text)
        if (refusal != null) {
            notify(refusal)
            return
        }
        val live = links[hostId]?.binding
        if (live == null) {
            notify("No session is open.")
            return
        }
        live.paste(text)
    }

    /**
     * Copy out of the terminal: the selection when there is one, the visible screen when there is
     * not.
     *
     * The fallback is the feature rather than a shortcut. Selecting text with a fingertip on a phone
     * is genuinely hard, and "copy what I am looking at" is what people mean nine times out of ten;
     * long-pressing the terminal gives the real selection for the other one. It is deliberately not
     * the whole transcript — two thousand rows on the clipboard ruins whatever it is pasted into.
     */
    fun copy(hostId: String, selection: String?) {
        if (!selection.isNullOrEmpty()) {
            clipboard.write(selection)
            notify("Copied ${lineCount(selection)} from the selection.")
            return
        }
        val screen = links[hostId]?.binding?.visibleText()
        if (screen.isNullOrEmpty()) {
            notify("There is nothing to copy yet.")
            return
        }
        clipboard.write(screen)
        notify("Copied ${lineCount(screen)} from the screen.")
    }

    /**
     * The emulator's own long-press Copy, which this app did not initiate and cannot describe.
     *
     * Android 13 draws its own preview of whatever was copied, so a second confirmation is the same
     * news twice; below that there is nothing at all, and a copy that says nothing feels broken.
     */
    private fun copyToClipboard(text: String) {
        clipboard.write(text)
        if (!clipboard.confirmsItself) notify("Copied.")
    }

    /** "1 line" / "12 lines", so the confirmation says what landed rather than only that it did. */
    private fun lineCount(text: String): String {
        val lines = text.count { it == '\n' } + 1
        return if (lines == 1) "1 line" else "$lines lines"
    }

    /* ------------------------------------------------------------------- files -- */

    /**
     * Send a file the user picked into the session that is open on the machine on screen.
     *
     * The picker ran in another process and handed back a `content://` URI — no media permission was
     * requested and none is held; see `MainActivity`. Everything from here is [FileUpload]: chunk,
     * window, digest, and a path back.
     *
     * One at a time **per machine**, matching the desktop, which holds one open descriptor per
     * phone. A second request while one is running says so rather than replacing it, because
     * replacing the transfer somebody is watching is the worse surprise.
     */
    fun sendFile(file: PickedFile, open: () -> java.io.InputStream) {
        val link = selected ?: return
        if (!_uiState.value.canSendFiles) {
            notify("This machine cannot receive files from the phone.")
            return
        }
        val session = link.binding
        if (session == null) {
            notify("Open a session first — the path is typed into it.")
            return
        }
        if (link.upload?.view?.isRunning == true) {
            notify("A file is already on its way. Wait for it, or cancel it.")
            return
        }
        val started = FileUpload(
            file = file,
            scope = viewModelScope,
            // Read off the link at the moment the transfer starts, and safe to freeze for its
            // duration: an upload only runs while `canSendFiles`, which needs `live`, which needs a
            // `welcome` — so the machine has already said what it is, and it will not change
            // operating system halfway through a photo.
            hostNoun = link.hostPlatform.noun,
            send = { link.transport.send(it) },
            open = open,
            onChange = { publish() },
            onLanded = { path ->
                // Typed, not run. The path lands at the prompt as one quoted word and the person
                // decides what to do with it — the same rule the desktop's `composeSend` follows,
                // and the reason there is no trailing carriage return here.
                session.paste(shellQuoted(path))
                notify("Landed at $path — the path is at the prompt.")
            },
        )
        link.upload = started
        publish()
        started.start()
    }

    /**
     * The picker handed back something whose size cannot be learned.
     *
     * Said out loud rather than swallowed: without a size there is no progress bar and no way to
     * refuse an enormous file before it starts, so this refuses to guess.
     */
    fun noteFileUnreadable() {
        notify("Android would not say how big that file is, so it cannot be sent. Try a different app’s copy of it.")
    }

    /** The Cancel button on the progress row, and the only way to stop a stalled upload. */
    fun cancelUpload() {
        selected?.upload?.cancel()
    }

    /** Take the finished row off the screen. A result that cannot be dismissed becomes furniture. */
    fun dismissUpload() {
        val link = selected ?: return
        if (link.upload?.view?.isRunning == true) link.upload?.cancel()
        link.upload = null
        publish()
    }

    /* ------------------------------------------- GitHub, owned by the machine on screen -- */

    /** Ask for the machine's GitHub status once, when the section that shows it appears. */
    fun openGitHub() {
        selected?.github?.ensureRead()
    }

    /** Start a device-flow sign-in on the machine. The code arrives on its `github.state`. */
    fun connectGitHub() {
        selected?.github?.connect()
    }

    /** Cancel a sign-in the machine has in flight. */
    fun cancelGitHub() {
        selected?.github?.cancel()
    }

    /**
     * Sign the machine out of GitHub.
     *
     * The revocation that works from here: the machine forgets the login it held. It does not revoke
     * the token at GitHub — that is a page on github.com, and claiming otherwise would be a promise
     * this app cannot keep.
     */
    fun disconnectGitHub() {
        selected?.github?.disconnect()
    }

    /* ----------------------------- the host over the relay — "the relay is the network" -- */

    /** Ask for the machine's host status once, when the server page appears. */
    fun openHostControl() {
        selected?.hostControl?.ensureRead()
    }

    /**
     * Restart the machine's host over the relay.
     *
     * "The relay is the network": this reaches the box even when the server's stored SSH address is
     * an offline Tailscale name, because the box is plainly on the relay. The connection drops as the
     * host restarts and comes back on its own — see [HostControlController].
     */
    fun restartHostOverRelay() {
        selected?.hostControl?.restartHost()
    }

    /** Stop the machine's host over the relay. There is no start here — a stopped host is off the relay. */
    fun stopHostOverRelay() {
        selected?.hostControl?.stopHost()
    }

    /* -------------------------------------------------------------------- state -- */

    private fun notify(text: String) {
        noticeJob?.cancel()
        notice = text
        publish()
        noticeJob = viewModelScope.launch {
            delay(NOTICE_MS)
            notice = null
            publish()
        }
    }

    /**
     * Fold every machine into the one picture the screens read.
     *
     * Rebuilt whole rather than patched, because a patch would need to know which fields the change
     * could have touched — and the field it forgot would be the one that went stale.
     */
    private fun publish() {
        val current = selected
        val hosts = links.values.map { it.summary(selected = it.hostId == current?.hostId) }
        _uiState.value = DeckUiState(
            hosts = hosts,
            selectedHostId = current?.hostId,
            transport = current?.connection ?: TransportState.Unpaired,
            pairing = current?.record?.let(::PairingView),
            deviceFingerprint = Sealed.fingerprint(vault.identity().publicKey),
            sessions = current?.sessions ?: emptyList(),
            deviceName = current?.deviceName,
            capabilities = current?.capabilities ?: emptySet(),
            grantedFolders = current?.grantedFolders,
            hostPlatform = current?.hostPlatform ?: HostPlatform.UNKNOWN,
            loaded = current?.loaded ?: false,
            live = current?.live ?: false,
            notice = notice,
            pairingError = pairingError,
            pairingLookup = pairingLookup,
            upload = current?.uploadView,
            addingHost = addingHost,
            clientVersion = clientVersion,
            hostAppVersion = current?.appVersion ?: "",
            hostKind = current?.hostKind,
            devices = current?.devices?.view(),
            serverSettings = current?.settings?.view(),
            github = current?.github?.view(),
            hostControl = current?.hostControl?.view(),
            /*
             * The control cluster of whichever machine has a session on screen — not of the selected
             * one.
             *
             * They are the same machine almost always, and are not the same on a phone with a Mac
             * and a PC where a terminal was opened on one and the switcher then moved to the other.
             * `view()` answers null unless that link is actually following a session, and only one
             * terminal is ever open, so the first non-null is the right one by construction rather
             * than by remembering to keep a second id in step.
             */
            controls = links.values.firstNotNullOfOrNull { it.controls?.view() },
            // The bar and the conversation follow the same rule as the control cluster, and for the
            // same reason: they are about the session on screen, which on a phone with two machines
            // paired need not be the machine the switcher is pointing at.
            bar = following()?.view(),
            watch = current?.watch?.view(),
            machineBrowser = current?.machineBrowser?.view(),
            machineProfiles = current?.machineBrowser?.profilesView(),
            localhost = current?.localhost?.view(),
            devServers = current?.devServer?.view(),
            tunnel = current?.tunnels?.view(),
            copilot = current?.copilot?.view(),
            copilotFiles = current?.copilotFiles?.view(),
            routines = current?.routines?.view(),
            awayReport = awayReport,
            addServer = if (addingServer) {
                AddServerView(
                    working = serverSignInWorking,
                    error = serverSignInError,
                    connected = serverConnectedName,
                )
            } else {
                null
            },
        )
    }

    override fun onCleared() {
        for (link in links.values) link.stop()
        // Every SSH connection this phone was holding for an open server card. Nothing reconnects
        // them and nothing polls them, so the only thing left is to hang up.
        serverConnector.releaseAll()
        stopWatchingNetwork?.invoke()
        stopWatchingNetwork = null
    }

    companion object {
        private const val NOTICE_MS = 3_500L

        /**
         * Where a pairing code with no `r` parameter points.
         *
         * There is no hosted relay yet, so this is deliberately a name that does not resolve rather
         * than a plausible-looking address: a build that silently talked to something because a
         * constant was left pointing at it would be worse than one that fails. Every code the
         * desktop produces today carries its own `r`.
         */
        const val DEFAULT_RELAY = "wss://relay.terminaldeck.dev"

        /**
         * The SSH logins' own wrapping key, deliberately not the pairings' and not GitHub's.
         *
         * `KeystoreVaultCipher` argues the split in full: one alias for two things makes one event
         * out of two, and a phone that loses its pairings must not thereby lose the SSH logins
         * that could put them back — that being the exact sequence this feature exists for.
         */
        const val SERVER_KEY_ALIAS = "terminaldeck.servers.v1"

        /**
         * The application context is taken off whatever `context` is handed in, because everything
         * built here must outlive the activity that created the view model.
         */
        fun factory(context: Context): ViewModelProvider.Factory {
            val application = context.applicationContext as Application
            return viewModelFactory {
                initializer {
                    DeckViewModel(
                        vault = KeystoreDeviceVault(application),
                        /*
                         * The SSH half: a store of its own under its own Keystore alias, the
                         * scripts out of the APK, and the real dialer. Built here because this is
                         * the one place in this class allowed to hold a `Context`, and because
                         * every one of the three is a seam whose default is deliberately inert.
                         */
                        serverConnector = ServerConnector(
                            store = FileServerStore(
                                file = java.io.File(application.filesDir, "servers.bin"),
                                cipher = KeystoreVaultCipher(SERVER_KEY_ALIAS),
                            ),
                            scripts = AssetScriptLibrary(application),
                            dialer = SshDialer.real,
                            // What `ServerScripts.hostPackage` derives the release asset from, so
                            // an install puts on a host this build can actually talk to.
                            appVersion = BuildConfig.VERSION_NAME,
                        ),
                        clipboard = AndroidClipboard(application),
                        network = AndroidNetworkWatch(application),
                        // This app's build, so a phone can say "update this server from a desktop"
                        // only when it is genuinely ahead. `BuildConfig` is enabled for this one read.
                        clientVersion = BuildConfig.VERSION_NAME,
                        // What a server it signs in to will list this phone as. The same string the
                        // transport introduces itself with, read in the one place that is allowed
                        // to touch `android.os.Build`.
                        deviceName = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim(),
                        // The one place a notification is actually posted. Gated inside
                        // `AlertCenter` on the permission and on the two switches, so a build whose
                        // permission was refused raises nothing and says nothing about it.
                        raiseAlert = { dev.terminaldeck.android.alerts.AlertCenter.post(application, it) },
                        // The two switches, read the one place a `Context` is allowed. `post` also
                        // checks them, so a banner never slips a disabled kind; this read is what
                        // keeps the away line from counting one.
                        wants = { dev.terminaldeck.android.alerts.AlertSettings.wants(application, it) },
                    ) { scope, hostId, store ->
                        WebSocketDeckTransport(scope = scope, hostId = hostId, vault = store)
                    }
                }
            }
        }
    }
}

/**
 * What a screen was handed when it started following a session, and hands back when it stops.
 *
 * Two numbers rather than one because the two clusters are independent — a screen may follow one and
 * not the other — and a single token would make releasing one release the other.
 */
data class SessionClaim(val controls: Int, val bar: Int)

/** Which machine, and which of its sessions. See [DeckViewModel.created]. */
data class OpenRequest(val hostId: String, val sessionId: String)

/**
 * What the UI knows.
 *
 * [hosts] is the collection; everything below it describes the **selected** machine, so that a
 * screen written against one computer stays written against one computer.
 *
 * [live] is separate from [transport] on purpose: the session list survives a disconnection because
 * it is the last true thing the machine said, but every row in it is then a historical claim. The
 * list dims rather than emptying, and nothing in it pretends to be current.
 */
data class DeckUiState(
    /** Every paired machine, oldest first. Empty before anything is paired. */
    val hosts: List<HostSummary> = emptyList(),
    val selectedHostId: String? = null,
    val transport: TransportState = TransportState.Unpaired,
    val pairing: PairingView? = null,
    val deviceFingerprint: String = "",
    val sessions: List<RemoteSessionView> = emptyList(),
    /** What the machine calls this phone, from `welcome`. Not the machine's own name. */
    val deviceName: String? = null,
    val capabilities: Set<String> = emptySet(),
    /**
     * The folders the machine on screen has chosen for this phone, or null when it has not said.
     *
     * Read through [startableFolders] and [noFoldersGranted] rather than directly: the null and the
     * empty case mean opposite things and every screen wants one of the two questions answered, not
     * the raw field. See [HostLink.grantedFolders].
     */
    val grantedFolders: List<String>? = null,
    /**
     * What kind of machine the selected one is. [HostPlatform.UNKNOWN] until it says.
     *
     * Read through [machineNoun] rather than branched on: every screen wants the same thing out of
     * it, which is a word to put in a sentence.
     */
    val hostPlatform: HostPlatform = HostPlatform.UNKNOWN,
    val loaded: Boolean = false,
    val live: Boolean = false,
    val notice: String? = null,
    val pairingError: String? = null,
    /**
     * True while six typed digits are being looked up at the rendezvous.
     *
     * A second between the memory-hard derivation and the round trip, with nothing else on screen —
     * so the pair screen's button says so rather than appearing to have stuck.
     */
    val pairingLookup: Boolean = false,
    /** The file on its way to the selected machine, if any. Null is the normal state. */
    val upload: UploadView? = null,
    /** The user asked to add a machine, so the pair screen shows the field rather than a wait. */
    val addingHost: Boolean = false,
    /** This app's own build, for the comparison [serverBehindSentence] makes. */
    val clientVersion: String = "",
    /** What build the machine on screen is running, from `welcome.appVersion`, or "" if it never said. */
    val hostAppVersion: String = "",
    /** `"desktop"` / `"headless"` for the machine on screen, or null. Read through [HostVersion]. */
    val hostKind: String? = null,
    /** The device roster of the machine on screen, or null when it does not serve one. */
    val devices: DeviceRosterView? = null,
    /** The two server-owned settings of the machine on screen, or null when it does not serve them. */
    val serverSettings: ServerSettingsView? = null,
    /**
     * The host's GitHub, as this phone reads it, or null when the machine on screen does not serve
     * `github` — an older host, or a guest. The section the server page mounts,
     * [dev.terminaldeck.android.ui.ConnectGitHubSection], draws off this.
     */
    val github: ConnectGitHubView? = null,
    /**
     * The machine's own host over the relay — status, restart, stop — or null when the machine on
     * screen does not serve `host.control` (an older host, or a guest). "The relay is the network":
     * the section the server page mounts draws off this so restart/stop reach the box even when its
     * SSH address is offline.
     */
    val hostControl: HostControlView? = null,
    /**
     * The control cluster of the session on screen, or null.
     *
     * Null covers three different absences at once — the machine never advertised `controls`, no
     * session is being followed, or nothing has been read yet — and the terminal screen has one test
     * for whether the Controls button exists rather than three.
     */
    val controls: SessionControlsView? = null,
    /** The open session's bar: the two figures and the login it runs as. Null over an older machine. */
    val bar: SessionBarView? = null,
    /** The open session's conversation and composer. Null when this machine serves no transcript. */
    /** What is listening on the machine, and whether a row may be opened over there. */
    val localhost: LocalhostView? = null,
    /** One dev-server row per granted folder a status has arrived for. */
    val devServers: DevServerView? = null,
    /** The page this phone is serving from the machine, or null when none is open. */
    val tunnel: TunnelView? = null,
    /**
     * The machine's copilot, or null when it offers none to this phone.
     *
     * Null is what makes the fourth pill *absent* rather than empty — iOS's own rule for that tab.
     */
    val copilot: CopilotView? = null,
    /**
     * The copilot's own files on the machine, or null when it offers none to this phone.
     *
     * A separate reading from [copilot] on purpose: the Files card waits for its own capability even
     * over a machine whose Copilot conversation is fully alive — see [filesCapability].
     */
    val copilotFiles: CopilotFilesView? = null,
    /** The machine's saved instructions, or null when it serves no routine engine to this phone. */
    val routines: CopilotRoutinesView? = null,
    /**
     * What changed while the app was away, as one line at the top of the session list.
     *
     * The honest half of having no push service: a phone whose process was killed is caught up on
     * the next connection rather than woken, and this is where that catching-up is said.
     */
    val awayReport: String? = null,
    /** The watchable browser windows of the machine on screen, or null when it does not offer any. */
    val watch: WatchView? = null,
    /** The machine's own open browser windows and the sessions one could be bound to, or null when
     *  the machine does not offer its browser for driving. */
    val machineBrowser: MachineBrowserView? = null,
    /** The machine's browser profiles, or null when it does not offer them. */
    val machineProfiles: MachineProfilesUiView? = null,
    /**
     * The Add-a-server screen, or null when it is not up. Null is the normal state.
     *
     * Its own object rather than two loose fields, so that "the screen is showing" and "this is what
     * it is doing" cannot disagree — and so that nothing about it can be read while it is closed.
     */
    val addServer: AddServerView? = null,
) {
    /** The machine on screen, if there is one. */
    val host: HostSummary? get() = hosts.firstOrNull { it.hostId == selectedHostId } ?: hosts.firstOrNull()

    /** What the title bar calls the machine on screen. */
    val hostLabel: String get() = host?.label ?: "not paired"

    /**
     * What every sentence in this app calls the machine on screen.
     *
     * One property so that the answer cannot differ between two screens, and so that the thing that
     * used to be a literal `"Mac"` scattered through a dozen files is now a value with one source.
     * Before a machine has answered it is "desktop": neutral, true of all of them, and — the whole
     * point — never the specific one that made a Windows user read about their Mac.
     */
    val machineNoun: String get() = hostPlatform.noun

    /**
     * The pair screen owns the window.
     *
     * True while the machine on screen has not admitted this device — which covers "nothing is
     * paired at all", because then there is no machine on screen — and while the user is adding
     * another one. Not a navigation destination: an unpaired app has nothing behind the pair screen
     * to go back to, and a back stack entry that leads to an empty session list is a trap.
     */
    val needsPairing: Boolean get() = addingHost || pairing?.approved != true

    /**
     * Whether the pair screen can be left without pairing anything.
     *
     * False when this is the first machine — there is genuinely nowhere to go. True the moment one
     * machine has been let in, because then the pair screen is a thing the user opened rather than
     * the state of the app, and a screen with no way out is how "add a machine" turns into "my phone
     * forgot my Mac".
     */
    val canLeavePairing: Boolean get() = hosts.any { it.approved }

    /** Whether the switcher has a choice to offer. One machine still opens it — that is where the
     *  machine is renamed, forgotten, and another one added — but it does not claim to be a picker. */
    val hasSeveralHosts: Boolean get() = hosts.size > 1

    /**
     * A code is stored for a machine that has not admitted this device yet.
     *
     * Note what this is *not*: evidence that the machine knows anything about this phone. It becomes
     * true the moment a code is parsed, before a single byte has been sent.
     */
    val hasUnapprovedPairing: Boolean get() = pairing != null && !pairing.approved

    /**
     * The machine has answered this phone at some point in the past.
     *
     * A credential naming this device can only come out of a `welcome`, which can only come out of a
     * completed sealed handshake — so a non-null [PairingView.deviceName] is the phone's proof that
     * the two ends have ever actually spoken. It says nothing about *now*.
     */
    val hostEverAnswered: Boolean get() = pairing?.deviceName != null

    /**
     * Paired, and the machine said on this attempt that a human still has to approve it.
     *
     * [TransportState.Pending] is the only source, because it is the only state that means the
     * machine answered — see the note on `scheduleRetry` in `WebSocketDeckTransport`.
     *
     * This is narrow on purpose. The pair screen used to say "Paired with a Mac. Waiting to be let
     * in." on the strength of [hasUnapprovedPairing] alone — true from the instant a code was
     * *parsed* — directly above a card reading "Could not reach that Mac." Both sentences were on
     * screen at once, only the second one was true, and neither had any business calling an
     * unidentified machine a Mac in the first place.
     */
    val awaitingApproval: Boolean get() = hasUnapprovedPairing && transport is TransportState.Pending

    /** Unapproved, and the machine is not answering right now — whatever it may have done before. */
    val hostUnreachable: Boolean get() = hasUnapprovedPairing && transport !is TransportState.Pending

    val canCreateSessions: Boolean get() = live && capabilities.contains(Capability.CREATE)

    /**
     * Whether the machine will let this phone end a session. Absent rather than disabled in the UI
     * when false, the same rule New Session and Send File follow: a ✕ that only ever refuses is a
     * fake control, and closing is the one that is not undoable if it does not.
     */
    val canCloseSessions: Boolean get() = live && capabilities.contains(Capability.CLOSE)

    /**
     * The line that names the machine's build and kind — `version 0.10.0 · server` — or "" for a
     * machine that never reported one, in which case nothing is drawn rather than a blank row.
     */
    val hostVersionLine: String get() = HostVersion.hostVersionLine(hostAppVersion, hostKind)

    /**
     * The one sentence to show when this app is newer than the machine, naming the right kind of
     * box, or null when there is nothing honest to say. Default-closed: shown only when this build is
     * genuinely ahead, with no button under it, because nothing on this wire carries an update verb.
     */
    val serverBehindSentence: String?
        get() = HostVersion.behindSentence(clientVersion, hostAppVersion, hostKind)

    /**
     * Whether to draw the Devices entry: the machine offers the roster **and** is reachable now.
     *
     * Live-gated like New Session and Send File, and for the same reason: these are request/response
     * screens that need a live socket to read anything, so an entry shown over a dropped connection
     * would open onto a spinner that never resolves. It comes back the moment the socket does.
     */
    val devicesOffered: Boolean get() = live && capabilities.contains(Capability.DEVICES)

    /** Whether to draw the "This server" entry: the machine offers the settings and is reachable now. */
    val serverSettingsOffered: Boolean get() = live && capabilities.contains(Capability.SETTINGS)

    /**
     * Whether this machine can list what is listening on it.
     *
     * Gated on [live] like every other offer on this screen: a capability is what the machine said
     * on the connection it currently has, and a row drawn off a dead socket is a tap that cannot
     * land.
     */
    val localhostOffered: Boolean get() = live && capabilities.contains(Capability.LOCALHOST)

    /** Whether a page may be opened on the machine, in that machine's own browser. */
    val webOffered: Boolean get() = live && capabilities.contains(Capability.WEB)

    /** Whether this machine will say what a project's dev server is doing, and start one. */
    val devServerOffered: Boolean get() = live && capabilities.contains(Capability.DEVSERVER)


    /**
     * Whether this machine owns a GitHub login this phone can connect and drive.
     *
     * The gate for the server page's "Connect GitHub" section — the mirror of [serverSettingsOffered].
     * Not gated on [live]: it is a fact about the machine's build, so a page can decide whether to
     * make room for the section even while the socket is down. The section itself, fed by
     * [github], draws nothing until the status has been read.
     */
    val canConnectGitHub: Boolean get() = capabilities.contains(Capability.GITHUB)

    /**
     * Whether this machine holds an agent of its own that this device may drive.
     *
     * The capability alone is not the permission — see [Capability.COPILOT] — so this says only
     * that the tab has something behind it, and the grant decides what the tab may do.
     */
    val copilotOffered: Boolean get() = live && capabilities.contains(Capability.COPILOT)

    /**
     * Whether a session on this machine may be given a name — the Rename row's gate.
     *
     * Its own capability rather than a corner of [canCloseSessions]: a host that hands out shells and
     * will not end one can still let somebody label it. Gated on [live] like every other verb the phone
     * sends, so a row drawn off a dead socket is never a tap that cannot land.
     */
    val canRenameSessions: Boolean get() = live && capabilities.contains(Capability.RENAME)

    /** Whether this machine will list a folder's files and open one — the Files panel's gate. */
    val canReadFiles: Boolean get() = live && capabilities.contains(Capability.FILES)

    /** Whether this machine will report git status and print a diff — the Source-control panel's gate. */
    val canReadGit: Boolean get() = live && capabilities.contains(Capability.GIT)

    /** Whether this machine serves the four read-only panels — artifacts, store, AI readiness, MCP. */
    val canReadPanels: Boolean get() = live && capabilities.contains(Capability.PANELS)

    /**
     * Whether the copilot's own files may be read and edited on this machine.
     *
     * A **separate** gate from [copilotOffered]: every desktop that speaks `copilot` today was built
     * before these frames existed, so the Files card waits for [Capability.COPILOT_FILES] even on a
     * machine whose Copilot tab is fully alive. The name of a phone reading a flag is
     * [filesCapability]; [canEditCopilotFiles] is the same flag under the name the write side reads it.
     */
    val filesCapability: Boolean get() = live && capabilities.contains(Capability.COPILOT_FILES)

    /** The copilot-files gate again, under the name the Save button reads. See [filesCapability]. */
    val canEditCopilotFiles: Boolean get() = filesCapability

    /** Whether this machine holds a routine engine this device may drive — the Routines screen's gate. */
    val canUseRoutines: Boolean get() = live && capabilities.contains(Capability.ROUTINES)

    /** Whether this device may drive the machine's own browser — its windows, its recordings, its shots. */
    val browserControl: Boolean get() = live && capabilities.contains(Capability.BROWSER_CONTROL)

    /** Whether this device may read and switch the machine's browser profiles. */
    val browserProfiles: Boolean get() = live && capabilities.contains(Capability.BROWSER_PROFILES)

    /**
     * Whether this machine will walk its folders so a picker can offer one it cannot see.
     *
     * Its absence has two meanings this phone cannot tell apart and does not need to — an older host,
     * or a device paired as a guest — and both draw the picker without the *Choose a folder* row, which
     * is what the app looked like before this existed.
     */
    val canPickFolders: Boolean get() = live && capabilities.contains(Capability.FOLDER_PICK)

    /**
     * The machine said which folders this phone may use, and the answer was **none**.
     *
     * Its own question rather than `startableFolders.isEmpty()`, because that is true of two
     * opposite situations: this one, where a person removed every folder and nothing will start, and
     * an old machine with nothing running, where a session started with no folder named works
     * perfectly. Answering both with one boolean is how the empty case would come to read as a bug.
     */
    val noFoldersGranted: Boolean get() = grantedFolders?.isEmpty() == true

    /**
     * The one folder this phone was granted, when the machine granted exactly one.
     *
     * Null for every other case, including a single folder arrived at by the old cwd-derived
     * fallback — that one is not a decision anybody made, so it may not be described as one.
     *
     * It exists because one destination is not a choice and must not be drawn as a menu, and because
     * a session that starts somewhere the screen never named is the original complaint in a new
     * costume. The screen starts there on the first tap and says where in a line beside it.
     */
    val onlyGrantedFolder: String? get() = grantedFolders?.singleOrNull()

    /**
     * Whether to draw New Session at all: the machine can start one, **and** has somewhere to put
     * it.
     *
     * Absent rather than disabled when it cannot, which is the same rule [canSendFiles] follows.
     * What replaces it in the empty case is [noFoldersSentence] — a control that only ever refuses
     * is a fake feature, but a screen that says nothing at all is the bug this feature is fixing.
     */
    val canStartSession: Boolean get() = canCreateSessions && !noFoldersGranted

    /**
     * Whether the machine will take a file. Absent rather than disabled in the UI when false, for
     * the same reason New Session is: a control that exists only to refuse is a fake feature.
     */
    val canSendFiles: Boolean get() = live && capabilities.contains(Capability.UPLOAD)

    /**
     * Folders this phone may ask for a session in, **on the machine on screen**.
     *
     * The list that machine chose for this device, when it sent one. Not a list assembled here out
     * of the working directories of the sessions it happens to be showing — which is what this used
     * to be, and which is the bug: nobody chose it, it changed when a project was closed at the
     * desk, it was not the set the machine would actually accept, and from the phone there was
     * nothing to read that explained why it had one folder in it.
     *
     * The fallback is deliberate and is the old behaviour exactly. A machine released before the
     * field sends nothing, and it is still a machine somebody is paired to; taking its New Session
     * button away over a missing field would break a working phone to fix a wording problem. It
     * offers what is running, and — because a machine with an empty list still starts a session
     * wherever it would have — the screen keeps the "where you would" row in that case alone.
     */
    val startableFolders: List<String> get() = grantedFolders ?: sessions.map { it.cwd }.distinct()

    /**
     * What to say when the machine has granted this phone nothing.
     *
     * Both halves earn their place. The first says the *machine* has not shared a folder — nothing
     * is broken, and this app has not lost anything. The second names the screen where that is
     * changed, because the person reading it is holding the one device that cannot fix it, and the
     * picker this replaces explained nothing at all.
     *
     * Worded to match the machine's own refusal — "has no folders chosen for this device. Choose one
     * in its remote access settings" — since the two are read minutes apart by one person, and two
     * vocabularies for one situation read as two different problems.
     */
    val noFoldersSentence: String
        get() = "The $machineNoun has not shared a folder with this phone, so it cannot start a " +
            "session here. Choose one on it, under Settings → Remote access → Folders."

    /**
     * The rows the New Session menu draws, in order.
     *
     * A value rather than a `when` inside the composable, for the same reason the desktop keeps its
     * wiring assertions out of React: what this picker offers is *the* thing that was wrong, and a
     * list built inside a `DropdownMenu` can only be checked by reading it. Here it can be asserted.
     *
     * "Where the machine would" appears only against a machine that never sent a grant list. With a
     * list it would not be a second choice — a `create` naming nothing starts in the first granted
     * folder — so it would be one destination drawn twice, with the copy that hides which folder it
     * is on top. That ambiguity is exactly what the grants exist to remove.
     */
    val folderChoices: List<FolderChoice>
        get() = buildList {
            if (grantedFolders == null) add(FolderChoice("Where the $machineNoun would", null))
            for (folder in startableFolders) add(FolderChoice(folder, folder))
        }
}

/**
 * One row of the New Session menu.
 *
 * [folder] null means "wherever you would have started one", which is the machine's own default and
 * the only honest row to draw against a machine that has not said what it will accept. It doubles as
 * the answer to "is this label a path": a path is set in monospace, because mono is this app's
 * promise that the characters are exact and countable, and a sentence about a Mac is not.
 */
data class FolderChoice(val label: String, val folder: String?) {
    val isPath: Boolean get() = folder != null
}

/**
 * The Add-a-server screen, as the view model sees it.
 *
 * Two nullable sentences and nothing else. Everything the person is typing — the address, the
 * username, and above all the password or key — stays in the screen's own state: a view model that
 * held a password would hold it for the life of the process, in a class that is dumped whole into
 * every crash report.
 *
 * [working] is a sentence rather than a boolean because this is the longest wait in the app and the
 * one place a bare spinner is indistinguishable from a hang. [error] is the server's own words
 * wherever the server gave any.
 */
data class AddServerView(
    val working: String? = null,
    val error: String? = null,
    /**
     * The machine a server card's Connect just produced, while that receipt is on screen.
     *
     * Null on every other path, including a pasted address — that one closes the screen on success
     * and has no card to come back to.
     */
    val connected: String? = null,
) {
    /** Whether something is in flight. The one predicate the screen may disable its button on. */
    val busy: Boolean get() = working != null
}

/** The pairing, as the UI is allowed to see it: no key material, no token. */
data class PairingView(
    val hostId: String,
    val hostFingerprint: String,
    val relayUrl: String,
    val deviceName: String?,
    val approved: Boolean,
) {
    constructor(record: PairingRecord) : this(
        hostId = record.hostId,
        hostFingerprint = Sealed.fingerprint(record.hostStaticPublicKey),
        relayUrl = record.relayUrl,
        deviceName = record.deviceName,
        approved = record.approved,
    )
}
