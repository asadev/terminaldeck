package dev.terminaldeck.android

import android.app.Application
import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.terminaldeck.android.credential.CredentialQuestion
import dev.terminaldeck.android.credential.CredentialResponder
import dev.terminaldeck.android.credential.coroutineExpiry
import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.github.GitHubAccount
import dev.terminaldeck.android.github.GitHubAccountStore
import dev.terminaldeck.android.github.GitHubEndpoints
import dev.terminaldeck.android.github.GitHubSignIn
import dev.terminaldeck.android.github.KeystoreGitHubStore
import dev.terminaldeck.android.github.SignInPhase
import dev.terminaldeck.android.github.harnessGitHubEndpoints
import dev.terminaldeck.android.pairing.PairingCodes
import dev.terminaldeck.android.pairing.Rendezvous
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.HostPlatform
import dev.terminaldeck.android.protocol.pasteRefusal
import dev.terminaldeck.android.protocol.RemoteSessionView
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.session.RemoteSessionBinding
import dev.terminaldeck.android.store.DeviceVault
import dev.terminaldeck.android.store.KeystoreDeviceVault
import dev.terminaldeck.android.store.PairingRecord
import dev.terminaldeck.android.transfer.FileUpload
import dev.terminaldeck.android.transfer.PickedFile
import dev.terminaldeck.android.transfer.UploadView
import dev.terminaldeck.android.transfer.shellQuoted
import dev.terminaldeck.android.transport.DeckTransport
import dev.terminaldeck.android.transport.Heartbeat
import dev.terminaldeck.android.transport.TransportState
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
    /**
     * The one GitHub account this phone holds, and the thing that answers with it.
     *
     * Phone-wide rather than per machine, and that is the model rather than a convenience: it is
     * *one person's* GitHub, and every machine they work on asks the same device about it.
     *
     * No default. A default would be [dev.terminaldeck.android.github.InMemoryGitHubStore], which
     * forgets on relaunch — a sign-in that silently stopped surviving the app being closed, in a
     * build whose every test still passed.
     */
    private val accounts: GitHubAccountStore,
    /**
     * Where GitHub is.
     *
     * The real addresses by default. A debug build launched by a test can be pointed at a stand-in
     * instead — see `HarnessEndpoints`, which exists only in the debug source set — so that the
     * approval prompt can be reached without a real token, and without a code path in the shipping
     * app whose job is to fake being signed in.
     */
    private val gitHubEndpoints: GitHubEndpoints = GitHubEndpoints(),
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

    private var selectedHostId: String? = null

    /** Set while the user is adding a machine, so the pair screen shows the field and not a wait. */
    private var addingHost = false

    private var pairingError: String? = null
    /** True while the rendezvous is being asked where a typed code's machine is. */
    private var pairingLookup: Boolean = false

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
     * What answers a machine that asks this phone for a GitHub login.
     *
     * One responder for every machine, not one per link, and that is the point: a person looking at
     * two machines must not be asked two things at once by two objects that do not know about each
     * other. One question is on screen at a time and the rest queue behind it.
     */
    private val credentials = CredentialResponder(
        accounts = accounts,
        expiry = coroutineExpiry(viewModelScope),
        onChange = { publish() },
    )

    /**
     * Getting a token onto this phone: the device flow, or a pasted personal access token.
     *
     * Held here rather than made per screen so that closing the sheet mid-flow and reopening it
     * comes back to the same poll rather than starting a second one against a code GitHub has
     * already issued.
     */
    val signIn: GitHubSignIn = GitHubSignIn(
        accounts = accounts,
        scope = viewModelScope,
        endpoints = gitHubEndpoints,
        onChange = { publish() },
    )

    init {
        // Routed by machine **id** rather than through a captured link, because a machine can be
        // forgotten while its question is on screen — and answering through an object that has been
        // torn down would be answering nobody, quietly.
        credentials.route = { hostId, message -> links[hostId]?.transport?.send(message) }

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
            // A question from a machine whose socket has gone is unanswerable: the reply has
            // nowhere to go. It comes off the screen rather than staying up as three buttons that
            // do nothing, which is the design brief's first rule.
            credentials.machineLost(link.hostId)
            // An upload cannot survive the connection carrying it, and a progress bar left creeping
            // against a socket that will never answer is exactly the lie this client is written not
            // to tell. The machine deletes its half-written file when the socket closes.
            link.upload?.connectionLost(next.detail)
        }
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
                return
            }

            is ServerMessage.Detached,
            is ServerMessage.Pong,
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
                link.loaded = message.sessions.isNotEmpty() || link.loaded
                link.live = true
            }

            // The same list again, because somebody edited it at the desk. Handled identically to
            // the one in `welcome` and on purpose: the reason this frame exists is that a folder
            // removed while the phone sits there connected must leave the picker *now*, and a
            // client that only read the welcome would keep offering it until the app was reopened.
            is ServerMessage.Folders -> link.grantedFolders = message.folders

            is ServerMessage.Sessions -> {
                link.sessions = message.sessions.map { it.toView() }
                link.loaded = true
                link.live = true
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

            /*
             * The one frame the desktop sends as a *question*.
             *
             * Handed to the responder with the machine that asked already attached — its id, so a
             * reply can be routed back to the right socket, and its label, because the third line
             * of the prompt is *which machine asked* and by the time it is drawn this may not be
             * the machine on screen. A phone paired with three machines can be looking at any of
             * them when a fourth thing happens on a fourth.
             *
             * It returns before the fold at the bottom: the responder publishes for itself when
             * what is on screen changes, and a request answered silently — every read — changes
             * nothing a screen reads.
             */
            is ServerMessage.CredentialRequest -> {
                credentials.receive(
                    CredentialQuestion(
                        id = message.id,
                        machineId = link.hostId,
                        machineName = link.label,
                        origin = message.host,
                        repo = message.repo,
                        operation = message.operation,
                        prompt = message.prompt,
                    )
                )
                return
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
        link.stop()
        // Before the vault, because after `stop` there is no socket left to answer on and a prompt
        // still naming this machine would be three buttons with nowhere to send their answer.
        credentials.machineLost(hostId)
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

    /** Type text into the session open on one machine: the key bar, and paste. */
    fun type(hostId: String, text: String) {
        val link = links[hostId] ?: return
        val live = link.binding ?: return
        if (!link.transport.send(ClientMessage.Input(live.sessionId, text))) {
            notify("Not connected — that did not reach ${link.label}.")
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

    /* ------------------------------------------------- GitHub, and what machines ask -- */

    /**
     * Approve the question on screen.
     *
     * [remember] is the "Always for this repo" button. It is a scope rather than a stored secret —
     * that machine may stop asking about that repository from this device, and every push still
     * comes back here for the credential itself.
     */
    fun approveCredential(remember: Boolean) = credentials.approve(remember)

    fun denyCredential() = credentials.deny()

    /**
     * Forget the GitHub account.
     *
     * This *is* the revocation that works from here: with no token on this phone, nothing on it can
     * answer a credential request from any machine. It does not revoke the token at GitHub — that
     * is a page on github.com, and this app claiming to have done it would be a claim it cannot
     * keep.
     */
    fun disconnectGitHub() {
        accounts.disconnect()
        signIn.cancel()
        publish()
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
            gitHubAccount = accounts.account(),
            credentialPrompt = credentials.asking,
            credentialsQueued = credentials.queued,
            signInPhase = signIn.phase,
        )
    }

    override fun onCleared() {
        for (link in links.values) link.stop()
        // Nothing left to answer on, so nothing is left asking. Not a refusal: the desktop settles
        // its own question on its own deadline, and a "no" sent from an app that is being torn down
        // would be a decision nobody made.
        credentials.reset()
        signIn.cancel()
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
         * `context` is the **activity**, not the application, and that is load bearing: the debug
         * harness reads its launch intent through it. The application context is taken from it for
         * everything that must outlive the activity, which is everything else here.
         */
        fun factory(context: Context): ViewModelProvider.Factory {
            val application = context.applicationContext as Application
            val endpoints = harnessGitHubEndpoints(context) ?: GitHubEndpoints()
            return viewModelFactory {
                initializer {
                    DeckViewModel(
                        vault = KeystoreDeviceVault(application),
                        clipboard = AndroidClipboard(application),
                        accounts = KeystoreGitHubStore(application),
                        gitHubEndpoints = endpoints,
                        network = AndroidNetworkWatch(application),
                    ) { scope, hostId, store ->
                        WebSocketDeckTransport(scope = scope, hostId = hostId, vault = store)
                    }
                }
            }
        }
    }
}

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
    /**
     * The GitHub account this phone holds, or null.
     *
     * Phone-wide, not per machine: it is one person's GitHub, and every machine they work on asks
     * this one device about it. Never carries the token — see
     * [dev.terminaldeck.android.github.GitHubAccount].
     */
    val gitHubAccount: GitHubAccount? = null,
    /**
     * The credential question on screen, or null. Null is the normal state.
     *
     * Only ever a request the desktop asked this phone to *prompt* about — a push, against a
     * repository this device has not already approved on that machine. Reads and approved pushes
     * are answered without anything reaching this field.
     */
    val credentialPrompt: CredentialQuestion? = null,
    /** How many questions are behind the one on screen, so the prompt can say there is another. */
    val credentialsQueued: Int = 0,
    /** Where the GitHub sign-in has got to, when a sheet is showing it. */
    val signInPhase: SignInPhase = SignInPhase.Idle,
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
