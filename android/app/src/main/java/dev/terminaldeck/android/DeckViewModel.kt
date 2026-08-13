package dev.terminaldeck.android

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.terminaldeck.android.crypto.Sealed
import dev.terminaldeck.android.pairing.PairingCode
import dev.terminaldeck.android.pairing.PairingCodes
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.pasteRefusal
import dev.terminaldeck.android.protocol.RemoteSessionView
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.session.RemoteSessionBinding
import dev.terminaldeck.android.transfer.FileUpload
import dev.terminaldeck.android.transfer.PickedFile
import dev.terminaldeck.android.transfer.UploadView
import dev.terminaldeck.android.transfer.shellQuoted
import dev.terminaldeck.android.store.DeviceVault
import dev.terminaldeck.android.store.KeystoreDeviceVault
import dev.terminaldeck.android.transport.DeckTransport
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
 * The one place a frame becomes application state.
 *
 * Everything the UI draws is derived from [uiState], and the only thing that writes it is the
 * collector below. Screens do not talk to the transport; they call the intent methods here. That is
 * not ceremony — the terminal screen has to survive rotation and backgrounding without dropping the
 * session, and a session owned by a composable would not.
 */
class DeckViewModel(
    application: Application,
    private val vault: DeviceVault,
    transportFactory: (CoroutineScope, DeviceVault) -> DeckTransport,
) : AndroidViewModel(application) {

    private val transport: DeckTransport = transportFactory(viewModelScope, vault)

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
    var binding: RemoteSessionBinding? = null
        private set

    private val _screenTick = MutableStateFlow(0L)
    val screenTick: StateFlow<Long> = _screenTick.asStateFlow()

    private var noticeJob: Job? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    init {
        _uiState.update {
            it.copy(
                pairing = vault.pairing()?.let(::PairingView),
                deviceFingerprint = Sealed.fingerprint(vault.identity().publicKey),
            )
        }

        viewModelScope.launch {
            transport.state.collect { next ->
                val wasOnline = _uiState.value.transport.isOnline
                _uiState.update { it.copy(transport = next, pairing = vault.pairing()?.let(::PairingView)) }
                if (!wasOnline && next.isOnline) onReconnected()
                if (wasOnline && !next.isOnline) {
                    // The list is kept — it is the last thing the desktop actually said — but the
                    // statuses in it are now history, and the banner says so rather than the rows
                    // quietly continuing to claim "running".
                    _uiState.update { it.copy(live = false) }
                    // An upload cannot survive the connection carrying it, and a progress bar left
                    // creeping against a socket that will never answer is exactly the lie this
                    // client is written not to tell. The Mac deletes its half-written file when the
                    // socket closes, which is the other end of this.
                    upload?.connectionLost(next.detail)
                }
            }
        }
        viewModelScope.launch { transport.incoming.collect(::onFrame) }

        watchNetwork()
        transport.connect()
    }

    /* ------------------------------------------------------------------- frames -- */

    private fun onFrame(message: ServerMessage) {
        when (message) {
            is ServerMessage.Welcome -> _uiState.update {
                it.copy(
                    sessions = message.sessions.map { session -> session.toView() },
                    deviceName = message.deviceName,
                    capabilities = message.capabilities.toSet(),
                    loaded = message.sessions.isNotEmpty() || it.loaded,
                    live = true,
                )
            }

            is ServerMessage.Sessions -> _uiState.update {
                it.copy(sessions = message.sessions.map { session -> session.toView() }, loaded = true, live = true)
            }

            // Output is routed by id rather than to "the current session" — the desktop is entitled
            // to keep sending for a session we are in the middle of leaving, and feeding those
            // bytes to whatever is on screen now would corrupt a different terminal.
            is ServerMessage.Output -> binding
                ?.takeIf { it.sessionId == message.id }
                ?.feed(message.data)

            is ServerMessage.Exit -> {
                binding?.takeIf { it.sessionId == message.id }?.remoteExited(message.exitCode)
                _uiState.update { state ->
                    state.copy(
                        sessions = state.sessions.map {
                            if (it.id == message.id) it.copy(status = "exited", exitCode = message.exitCode) else it
                        }
                    )
                }
            }

            is ServerMessage.Status -> _uiState.update { state ->
                state.copy(
                    sessions = state.sessions.map {
                        if (it.id == message.id) it.copy(status = message.status) else it
                    }
                )
            }

            // `error` carries no session id, so this cannot be tied to a row. What it can do is
            // stop the terminal screen from silently showing nothing: the common cause is a
            // re-attach after the Mac restarted, where the id the phone remembers no longer names
            // anything.
            is ServerMessage.Error -> {
                notify(message.message.ifEmpty { "The Mac refused that." })
                // A refused request is not going to be followed by a `created`, and a phone that
                // stayed armed would jump into the *next* session it was told about, whoever
                // started it.
                openWhenCreated = false
            }

            is ServerMessage.Attached -> binding?.takeIf { it.sessionId == message.id }?.onAttached()

            // Put in the list here rather than waiting for the `sessions` frame the Mac sends to
            // *other* devices: the phone that asked is told with the whole row, so that the tap
            // which started the session is also the tap that opens it. With two sessions in the
            // same folder there is no way to guess which row is the new one from a plain list.
            is ServerMessage.Created -> {
                _uiState.update { state ->
                    if (state.sessions.any { it.id == message.session.id }) {
                        state
                    } else {
                        state.copy(sessions = state.sessions + message.session.toView(), loaded = true)
                    }
                }
                if (openWhenCreated) {
                    openWhenCreated = false
                    _created.value = message.session.id
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
                upload?.onFrame(message)
            }

            is ServerMessage.Detached,
            is ServerMessage.Pong,
            -> Unit
        }
    }

    /**
     * A connection came up.
     *
     * The session list is asked for again — it is the one piece of state that goes stale while the
     * socket is down — and anything that was on screen is attached again, which is what makes a
     * reconnect land the user back where they were with the scrollback replayed rather than on a
     * frozen screen.
     */
    private fun onReconnected() {
        transport.send(ClientMessage.List)
        binding?.reattach()
    }

    /* ------------------------------------------------------------------ intents -- */

    fun refresh() {
        if (!transport.send(ClientMessage.List)) notify("Not connected.")
    }

    fun reconnect() = transport.resume()

    /** Called when the app returns to the foreground, or the OS says the network is back. */
    fun resume() = transport.resume()

    /**
     * Pair with the Mac in a code.
     *
     * The code is parsed before anything is stored, and stored before anything is sent: a device
     * that has written down which Mac it is talking to can come back to the same one after a crash
     * mid-handshake, and one that has not would have spent a single-use token for nothing.
     */
    fun pair(raw: String) {
        val code = PairingCodes.parse(raw)
        if (code == null) {
            _uiState.update { it.copy(pairingError = "That is not a pairing code.") }
            return
        }
        vault.beginPairing(
            hostId = code.hostId,
            hostStaticPublicKey = code.hostStaticPublicKey,
            relayUrl = code.relayUrl ?: DEFAULT_RELAY,
            pairingToken = code.token,
        )
        _uiState.update {
            it.copy(pairingError = null, pairing = vault.pairing()?.let(::PairingView), sessions = emptyList())
        }
        transport.connect()
    }

    /** Read a code without acting on it, so the pair screen can show what it is about to trust. */
    fun preview(raw: String): PairingCode? = PairingCodes.parse(raw)

    fun clearPairingError() = _uiState.update { it.copy(pairingError = null) }

    fun unpair() {
        closeCurrent()
        transport.disconnect()
        vault.unpair()
        _uiState.update {
            DeckUiState(
                transport = TransportState.Unpaired,
                deviceFingerprint = Sealed.fingerprint(vault.identity().publicKey),
            )
        }
    }

    /**
     * Start a session on the Mac.
     *
     * Only reachable when the desktop advertised [Capability.CREATE] in its `welcome`; the button is
     * absent otherwise. Sending a message the desktop's parser has never heard of would close the
     * socket for `bad-message`, so a hopeful client is a broken one.
     *
     * `folder` is a directory the Mac is **already offering** — the working directory of a session
     * in the list on screen, which is the only honest source this phone has. The Mac refuses
     * anything else rather than quietly starting somewhere else: a New Session that silently began
     * in the wrong project is a command typed into the wrong place. Null means "wherever you would
     * have started one", which is what the desktop's own button does with nothing filled in.
     */
    fun newSession(folder: String? = null) {
        if (!_uiState.value.canCreateSessions) {
            notify("This Mac cannot start sessions from the phone.")
            return
        }
        // Remembered so the `created` that comes back *opens* the session rather than merely adding
        // a row. Cleared on arrival and by a refusal, so a `created` this phone did not ask for
        // never yanks the user into somebody else's session.
        openWhenCreated = true
        val size = binding
        if (!transport.send(ClientMessage.create(folder, size?.measuredCols, size?.measuredRows))) {
            openWhenCreated = false
            notify("Not connected.")
        }
    }

    /** Set between asking for a session and being told about it. See [newSession]. */
    private var openWhenCreated = false

    /**
     * The id of a session the Mac has just started for this phone, for the navigation to consume.
     *
     * A flow rather than a direct `navController.navigate`, for the same reason the pairing link is
     * one: this class must not know what a back stack is, and navigating from inside a frame handler
     * would be a mutation in the middle of the frame that produced it.
     */
    private val _created = MutableStateFlow<String?>(null)
    val created: StateFlow<String?> = _created.asStateFlow()

    fun createdHandled() {
        _created.value = null
    }

    /**
     * Open a session.
     *
     * The `attach` frame is not sent here. It goes out when the view reports its measured size, so
     * that the desktop's replay arrives already the right width — see
     * [RemoteSessionBinding.onSizeChanged].
     */
    fun open(sessionId: String): RemoteSessionBinding {
        val existing = binding
        if (existing != null && existing.sessionId == sessionId) return existing
        existing?.close()

        val created = RemoteSessionBinding(
            sessionId = sessionId,
            transport = transport,
            onScreenUpdate = { _screenTick.update { tick -> tick + 1 } },
            onTitleChange = { _screenTick.update { tick -> tick + 1 } },
            onCopy = ::copyToClipboard,
            onPaste = ::clipboardText,
            onSendFailed = { notify("Not connected — that did not reach the Mac.") },
        )
        binding = created
        return created
    }

    fun closeCurrent() {
        binding?.close()
        binding = null
    }

    /** Type text into the attached session: the key bar, and paste. */
    fun type(text: String) {
        val live = binding ?: return
        if (!transport.send(ClientMessage.Input(live.sessionId, text))) {
            notify("Not connected — that did not reach the Mac.")
        }
    }

    /**
     * Paste the clipboard into the attached session.
     *
     * Through [RemoteSessionBinding.paste], which goes through `TerminalEmulator.paste`, which is
     * where bracketed paste lives: if the program on the Mac asked for it — DECSET 2004, which every
     * shell and every agent CLI sets — the text is wrapped in `ESC[200~`…`ESC[201~` and arrives as
     * **one** paste. Without that a four-line paste submits on its first newline and runs the other
     * three as commands, which is the hazard `composeSend`/`oneLine` guard against on the desktop.
     *
     * An oversized clipboard is refused with both numbers rather than quietly shortened. Silently
     * truncating is the worst available behaviour: the user watches text land, believes all of it
     * did, and the command that runs is not the command they copied.
     */
    fun paste() {
        val text = clipboardText()
        if (text.isNullOrEmpty()) {
            notify("The clipboard is empty.")
            return
        }
        val refusal = pasteRefusal(text)
        if (refusal != null) {
            notify(refusal)
            return
        }
        val live = binding
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
     *
     * [selection] comes from the view, because only the view knows what is selected; the screen
     * comes from the binding, because only the emulator knows what is on it. The choice between them
     * is here, with the rest of the policy.
     */
    fun copy(selection: String?) {
        if (!selection.isNullOrEmpty()) {
            copyToClipboard(selection)
            notify("Copied ${lineCount(selection)} from the selection.")
            return
        }
        val screen = binding?.visibleText()
        if (screen.isNullOrEmpty()) {
            notify("There is nothing to copy yet.")
            return
        }
        copyToClipboard(screen)
        notify("Copied ${lineCount(screen)} from the screen.")
    }

    /** "1 line" / "12 lines", so the confirmation says what landed rather than only that it did. */
    private fun lineCount(text: String): String {
        val lines = text.count { it == '\n' } + 1
        return if (lines == 1) "1 line" else "$lines lines"
    }

    /* ------------------------------------------------------------------- files -- */

    /** The upload in flight, if any. Held here for the same reason [binding] is. */
    private var upload: FileUpload? = null

    /**
     * Send a file the user picked into the session that is open.
     *
     * The picker ran in another process and handed back a `content://` URI — no media permission was
     * requested and none is held; see `MainActivity`. Everything from here is [FileUpload]: chunk,
     * window, digest, and a path back.
     *
     * One at a time, matching the desktop, which holds one open descriptor per phone. A second
     * request while one is running says so rather than replacing it, because replacing the transfer
     * somebody is watching is the worse surprise.
     */
    fun sendFile(file: PickedFile, open: () -> java.io.InputStream) {
        if (!_uiState.value.canSendFiles) {
            notify("This Mac cannot receive files from the phone.")
            return
        }
        val session = binding
        if (session == null) {
            notify("Open a session first — the path is typed into it.")
            return
        }
        if (upload?.view?.isRunning == true) {
            notify("A file is already on its way. Wait for it, or cancel it.")
            return
        }
        val started = FileUpload(
            file = file,
            scope = viewModelScope,
            send = { transport.send(it) },
            open = open,
            onChange = { view -> _uiState.update { it.copy(upload = view) } },
            onLanded = { path ->
                // Typed, not run. The path lands at the prompt as one quoted word and the person
                // decides what to do with it — the same rule the desktop's `composeSend` follows,
                // and the reason there is no trailing carriage return here.
                session.paste(shellQuoted(path))
                notify("Landed at $path — the path is at the prompt.")
            },
        )
        upload = started
        _uiState.update { it.copy(upload = started.view) }
        started.start()
    }

    /**
     * The picker handed back something whose size cannot be learned.
     *
     * Said out loud rather than swallowed: without a size there is no progress bar and no way to
     * refuse an enormous file before it starts, so this refuses to guess. Rare — it means a content
     * provider that does not answer `OpenableColumns` — but a tap that does nothing at all is the
     * failure mode this app is written to avoid.
     */
    fun noteFileUnreadable() {
        notify("Android would not say how big that file is, so it cannot be sent. Try a different app’s copy of it.")
    }

    /** The Cancel button on the progress row, and the only way to stop a stalled upload. */
    fun cancelUpload() {
        upload?.cancel()
    }

    /** Take the finished row off the screen. A result that cannot be dismissed becomes furniture. */
    fun dismissUpload() {
        if (upload?.view?.isRunning == true) upload?.cancel()
        upload = null
        _uiState.update { it.copy(upload = null) }
    }

    private fun copyToClipboard(text: String) {
        val clipboard = getApplication<Application>().getSystemService(ClipboardManager::class.java)
        clipboard?.setPrimaryClip(ClipData.newPlainText("Terminal Deck", text))
        // Android 13 and later shows its own copy confirmation; a second one would be noise.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) notify("Copied.")
    }

    private fun clipboardText(): String? {
        val clipboard = getApplication<Application>().getSystemService(ClipboardManager::class.java)
        return clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(getApplication())?.toString()
    }

    private fun notify(text: String) {
        noticeJob?.cancel()
        _uiState.update { it.copy(notice = text) }
        noticeJob = viewModelScope.launch {
            delay(NOTICE_MS)
            _uiState.update { it.copy(notice = null) }
        }
    }

    /* ------------------------------------------------------------------ network -- */

    /**
     * Reconnect when the OS says there is a network again.
     *
     * Without this the app waits out whatever backoff step it had reached — up to twenty seconds
     * of a dead terminal after the wifi bars are already full, which is how an app earns a
     * reputation for being slow. `registerDefaultNetworkCallback` fires on the handoff between
     * wifi and cellular too, which is the common case on a phone and looks identical to a dead
     * socket from inside.
     */
    private fun watchNetwork() {
        val manager = getApplication<Application>().getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                transport.resume()
            }
        }
        try {
            manager.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (e: SecurityException) {
            // Some OEM builds refuse this without a permission the app does not hold. The app then
            // reconnects on its own schedule and when it is foregrounded, which is slower but not
            // broken — so it is not worth failing to start over.
        }
    }

    override fun onCleared() {
        closeCurrent()
        transport.disconnect()
        networkCallback?.let { callback ->
            getApplication<Application>().getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(callback)
        }
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
                    val vault = KeystoreDeviceVault(application)
                    DeckViewModel(application, vault) { scope, store ->
                        WebSocketDeckTransport(scope = scope, vault = store)
                    }
                }
            }
        }
    }
}

/**
 * What the UI knows.
 *
 * [live] is separate from [transport] on purpose: the session list survives a disconnection because
 * it is the last true thing the desktop said, but every row in it is then a historical claim. The
 * list dims rather than emptying, and nothing in it pretends to be current.
 */
data class DeckUiState(
    val transport: TransportState = TransportState.Offline,
    val pairing: PairingView? = null,
    val deviceFingerprint: String = "",
    val sessions: List<RemoteSessionView> = emptyList(),
    /** What the Mac calls this phone, from `welcome`. Not the Mac's own name — it has none here. */
    val deviceName: String? = null,
    val capabilities: Set<String> = emptySet(),
    val loaded: Boolean = false,
    val live: Boolean = false,
    val notice: String? = null,
    val pairingError: String? = null,
    /** The file on its way to the Mac, if any. Null is the normal state. */
    val upload: UploadView? = null,
) {
    /** The pair screen owns the window until a Mac has admitted this device at least once. */
    val needsPairing: Boolean get() = pairing?.approved != true

    /**
     * A code is stored for a Mac that has not admitted this device yet.
     *
     * Note what this is *not*: evidence that the Mac knows anything about this phone. It becomes
     * true the moment a code is parsed, before a single byte has been sent.
     */
    val hasUnapprovedPairing: Boolean get() = pairing != null && !pairing.approved

    /**
     * The Mac has answered this phone at some point in the past.
     *
     * A credential naming this device can only come out of a `welcome`, which can only come out of
     * a completed sealed handshake — so a non-null [PairingView.deviceName] is the phone's proof
     * that the two ends have ever actually spoken. It says nothing about *now*.
     */
    val macEverAnswered: Boolean get() = pairing?.deviceName != null

    /**
     * Paired, and the Mac said on this attempt that a human still has to approve it.
     *
     * [TransportState.Pending] is the only source, because it is the only state that means the Mac
     * answered — see the note on `scheduleRetry` in `WebSocketDeckTransport`.
     *
     * This is narrow on purpose. The pair screen used to say "Paired with a Mac. Waiting to be let
     * in." on the strength of [hasUnapprovedPairing] alone — true from the instant a code was
     * *parsed* — directly above a card reading "Could not reach that Mac." Both sentences were on
     * screen at once and only the second one was true: the handshake was failing on every attempt,
     * and the header dressed a total failure up as the normal wait for a human. A screen that
     * cannot tell "the Mac is thinking about you" from "nothing has ever answered" hides exactly
     * the class of bug that produced it.
     */
    val awaitingApproval: Boolean get() = hasUnapprovedPairing && transport is TransportState.Pending

    /** Unapproved, and the Mac is not answering right now — whatever it may have done before. */
    val macUnreachable: Boolean get() = hasUnapprovedPairing && transport !is TransportState.Pending

    val canCreateSessions: Boolean get() = live && capabilities.contains(Capability.CREATE)

    /**
     * Whether the Mac will take a file. Absent rather than disabled in the UI when false, for the
     * same reason New Session is: a control that exists only to refuse is a fake feature.
     */
    val canSendFiles: Boolean get() = live && capabilities.contains(Capability.UPLOAD)

    /**
     * Folders this phone may ask for a session in.
     *
     * The working directory of a session the Mac has already listed, and nothing else. The Mac
     * accepts only a folder it is already offering, so a picker built from anything else would be
     * offering choices that fail — and this is the honest source, because every one of them is a row
     * the user can see. Empty is normal on a Mac with nothing running, and the button then starts a
     * session wherever the desktop would have.
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
    constructor(record: dev.terminaldeck.android.store.PairingRecord) : this(
        hostId = record.hostId,
        hostFingerprint = Sealed.fingerprint(record.hostStaticPublicKey),
        relayUrl = record.relayUrl,
        deviceName = record.deviceName,
        approved = record.approved,
    )
}
