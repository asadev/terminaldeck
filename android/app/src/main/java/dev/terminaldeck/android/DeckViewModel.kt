package dev.terminaldeck.android

import android.app.Application
import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.pairing.PairingCode
import dev.terminaldeck.android.pairing.PairingCodes
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
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
    private val network: NetworkWatch = NetworkWatch.none,
    /**
     * The app-wide tick. Held here only to realign it once when the app comes back, rather than
     * once per machine — see [resume].
     */
    private val heartbeat: Heartbeat = Heartbeat.shared,
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
                link.loaded = message.sessions.isNotEmpty() || link.loaded
                link.live = true
            }

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
     * Pair with a machine in a code, **adding** it.
     *
     * The code is parsed before anything is stored, and stored before anything is sent: a device
     * that has written down which machine it is talking to can come back to the same one after a
     * crash mid-handshake, and one that has not would have spent a single-use token for nothing.
     *
     * Pairing with a machine already in the list replaces *that machine's* record and nothing else —
     * a re-pair after a revoke is a normal thing to do and it must not cost the user their other
     * machines. Every other machine keeps its socket through this; not one of them is touched.
     */
    fun pair(raw: String) {
        val code = PairingCodes.parse(raw)
        if (code == null) {
            pairingError = "That is not a pairing code."
            publish()
            return
        }
        vault.beginPairing(
            hostId = code.hostId,
            hostStaticPublicKey = code.hostStaticPublicKey,
            relayUrl = code.relayUrl ?: DEFAULT_RELAY,
            pairingToken = code.token,
        )
        val record = vault.pairing(code.hostId) ?: return

        val existing = links[code.hostId]
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
        selectedHostId = code.hostId
        vault.selectHost(code.hostId)
        addingHost = false
        pairingError = null
        publish()
    }

    /** Read a code without acting on it, so the pair screen can show what it is about to trust. */
    fun preview(raw: String): PairingCode? = PairingCodes.parse(raw)

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
     * `folder` is a directory that machine is **already offering** — the working directory of a
     * session in the list on screen, which is the only honest source this phone has, and which is
     * per machine by construction: offering a Mac's folder to a Windows PC would be a picker full of
     * choices that fail. Null means "wherever you would have started one".
     */
    fun newSession(folder: String? = null) {
        val link = selected ?: return
        if (!_uiState.value.canCreateSessions) {
            notify("This machine cannot start sessions from the phone.")
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
            loaded = current?.loaded ?: false,
            live = current?.live ?: false,
            notice = notice,
            pairingError = pairingError,
            upload = current?.uploadView,
            addingHost = addingHost,
        )
    }

    override fun onCleared() {
        for (link in links.values) link.stop()
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

        fun factory(context: Context): ViewModelProvider.Factory {
            val application = context.applicationContext as Application
            return viewModelFactory {
                initializer {
                    DeckViewModel(
                        vault = KeystoreDeviceVault(application),
                        clipboard = AndroidClipboard(application),
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
    val loaded: Boolean = false,
    val live: Boolean = false,
    val notice: String? = null,
    val pairingError: String? = null,
    /** The file on its way to the selected machine, if any. Null is the normal state. */
    val upload: UploadView? = null,
    /** The user asked to add a machine, so the pair screen shows the field rather than a wait. */
    val addingHost: Boolean = false,
) {
    /** The machine on screen, if there is one. */
    val host: HostSummary? get() = hosts.firstOrNull { it.hostId == selectedHostId } ?: hosts.firstOrNull()

    /** What the title bar calls the machine on screen. */
    val hostLabel: String get() = host?.label ?: "not paired"

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
    val macEverAnswered: Boolean get() = pairing?.deviceName != null

    /**
     * Paired, and the machine said on this attempt that a human still has to approve it.
     *
     * [TransportState.Pending] is the only source, because it is the only state that means the
     * machine answered — see the note on `scheduleRetry` in `WebSocketDeckTransport`.
     *
     * This is narrow on purpose. The pair screen used to say "Paired with a Mac. Waiting to be let
     * in." on the strength of [hasUnapprovedPairing] alone — true from the instant a code was
     * *parsed* — directly above a card reading "Could not reach that Mac." Both sentences were on
     * screen at once and only the second one was true.
     */
    val awaitingApproval: Boolean get() = hasUnapprovedPairing && transport is TransportState.Pending

    /** Unapproved, and the machine is not answering right now — whatever it may have done before. */
    val macUnreachable: Boolean get() = hasUnapprovedPairing && transport !is TransportState.Pending

    val canCreateSessions: Boolean get() = live && capabilities.contains(Capability.CREATE)

    /**
     * Whether the machine will take a file. Absent rather than disabled in the UI when false, for
     * the same reason New Session is: a control that exists only to refuse is a fake feature.
     */
    val canSendFiles: Boolean get() = live && capabilities.contains(Capability.UPLOAD)

    /**
     * Folders this phone may ask for a session in, **on the machine on screen**.
     *
     * The working directory of a session that machine has already listed, and nothing else. It
     * accepts only a folder it is already offering, so a picker built from anything else would be
     * offering choices that fail.
     */
    val startableFolders: List<String> get() = sessions.map { it.cwd }.distinct()
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
