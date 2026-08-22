package dev.terminaldeck.android

import dev.terminaldeck.android.protocol.HostPlatform
import dev.terminaldeck.android.protocol.RemoteSessionView
import dev.terminaldeck.android.session.RemoteSessionBinding
import dev.terminaldeck.android.store.PairingRecord
import dev.terminaldeck.android.transfer.FileUpload
import dev.terminaldeck.android.transfer.UploadView
import dev.terminaldeck.android.transport.DeckTransport
import dev.terminaldeck.android.transport.TransportState
import dev.terminaldeck.android.transport.isOnline

/**
 * One machine, and everything this phone knows about it.
 *
 * This is the object that used to *be* the view model. Splitting it out is the whole of multi-host:
 * the relay has always been a map of host ids and the protocol has never had an opinion about what
 * a host is — so the only thing that was ever single was the phone's own storage and the phone's own
 * state. There is now one of these per paired machine and [DeckViewModel] holds the collection.
 *
 * This header used to add "a phone genuinely cannot tell a Mac from a Windows PC, because nothing on
 * the wire says". That was true, and it is the sentence that let every screen in this app call every
 * machine a Mac. `welcome.hostPlatform` says now — see [hostPlatform] below.
 *
 * ## What is not shared between machines, and why that is free
 *
 * Everything below the transport. Each link owns its own [DeckTransport], which runs its own Noise
 * IK handshake against that machine's static key and therefore its own sealed channel. Two
 * machines cannot read each other's frames even though one phone is talking to both: the keys were
 * never in the same place to begin with. That isolation costs nothing to keep and would have to be
 * deliberately dismantled to lose, which is why nothing here is a shared anything.
 *
 * What *is* shared is the phone's static identity — one key, so a machine that has approved this
 * phone once has approved this phone — and the keepalive tick, so N sockets cost one radio wake-up
 * rather than N. See `Heartbeat`.
 *
 * ## Plain fields, not flows
 *
 * A link is mutable state read only by [DeckViewModel], which folds every link into one immutable
 * [DeckUiState] whenever anything changes. N flows combined into one would be the same picture
 * arrived at by a harder road, and would make "which machine changed" — the thing the fold needs to
 * know — the one fact that had been thrown away.
 */
class HostLink(
    val hostId: String,
    val transport: DeckTransport,
    record: PairingRecord,
) {

    /** What the vault holds about this machine. Replaced when it is renamed or re-paired. */
    var record: PairingRecord = record

    var connection: TransportState = TransportState.Offline

    /**
     * What is running on this machine.
     *
     * Kept when the socket drops — it is the last true thing the machine said — but [live] goes
     * false with it, which is what turns the rows from claims about now into history.
     */
    var sessions: List<RemoteSessionView> = emptyList()

    /** What this machine calls this phone, from `welcome`. Not the machine's own name. */
    var deviceName: String? = null

    var capabilities: Set<String> = emptySet()

    /**
     * What kind of machine this is, from `welcome.hostPlatform`.
     *
     * [HostPlatform.UNKNOWN] until it says, and [HostPlatform.UNKNOWN] forever against a desktop old
     * enough not to send the field — which is the honest answer for one, and the one thing this must
     * never do is guess [HostPlatform.MAC].
     *
     * Kept when the socket drops, and kept by [stop] too — unlike [sessions], [live] and
     * [capabilities], which are claims about *now* and stop being true the moment the connection
     * does. This is not one of those. A machine does not change operating system between one
     * reconnect and the next, and the sentences that most need the right noun are the ones printed
     * after a connection has gone: "Could not reach that PC", "The PC closed the connection". A
     * field reset on disconnect would make every one of those read "desktop" at exactly the moment
     * it matters.
     */
    var hostPlatform: HostPlatform = HostPlatform.UNKNOWN

    /**
     * The folders this machine has chosen for this phone, or null when it has never said.
     *
     * Null is not an empty list. Null is a machine older than the field — and a machine that cannot
     * start sessions at all — and it means "fall back to what this app did before"; an empty list is
     * a person having removed every folder, which means nothing will start and the screen has to say
     * so. Every screen reads this through [DeckUiState.startableFolders] rather than branching on it
     * twice.
     *
     * Kept when the socket drops, like [sessions], because it is the last true thing the machine
     * said — and cleared by [stop], like [capabilities], because that is a machine being taken down
     * rather than one going quiet, and the next `welcome` is what says whose folders these are.
     */
    var grantedFolders: List<String>? = null

    /** Whether a session list has ever arrived, so an empty list can be told from an unknown one. */
    var loaded: Boolean = false

    var live: Boolean = false

    /** The session open on screen for this machine, if any. */
    var binding: RemoteSessionBinding? = null

    /** The file on its way to this machine, if any. One at a time, matching the desktop. */
    var upload: FileUpload? = null

    /** Set between asking this machine for a session and being told about it. */
    var openWhenCreated: Boolean = false

    /**
     * What build this machine is running, from `welcome.appVersion`, or "" when it never said.
     *
     * Kept through a disconnect and through [stop], like [hostPlatform]: a machine does not change
     * its build between one reconnect and the next, and the one sentence this drives — *update this
     * server from a desktop* — is worth as much after the socket drops as before. "" is the honest
     * non-answer a build older than the field gives; see [dev.terminaldeck.android.protocol
     * .HostVersion], which refuses to compare against it rather than manufacturing a verdict.
     */
    var appVersion: String = ""

    /** `"desktop"` / `"headless"` from `welcome.hostKind`, or null. Read through `HostVersion`. */
    var hostKind: String? = null

    /** What the machine calls itself, from `welcome.hostName`, or null. Display text only. */
    var hostName: String? = null

    /** This phone's own device id on this machine, from `welcome.deviceId`. Names its own roster row. */
    var myDeviceId: String? = null

    /**
     * The device roster of this machine, and the verb that removes a row. Created once per link;
     * draws nothing until the machine advertises [dev.terminaldeck.android.protocol.Capability.DEVICES].
     */
    var devices: DeviceRosterController? = null

    /**
     * The two server-owned settings of this machine. Created once per link; draws nothing until the
     * machine advertises [dev.terminaldeck.android.protocol.Capability.SETTINGS].
     */
    var settings: ServerSettingsController? = null

    /**
     * The control cluster of whichever session this machine has on screen — model, effort, fast
     * mode, permission. Created once per link; follows a session rather than the machine, and draws
     * nothing until the machine advertises [dev.terminaldeck.android.protocol.Capability.CONTROLS].
     */
    var controls: SessionControlsController? = null

    /**
     * The browser windows of this machine that can be watched, and the cast of the one on screen.
     * Created once per link; draws nothing until the machine advertises
     * [dev.terminaldeck.android.protocol.Capability.WATCH], which a host offers to one of the
     * owner's own devices and never to a guest.
     */
    var watch: WatchController? = null

    /**
     * The bar behind one session on this machine: the plan and context figures, the login it runs
     * as, the conversation, and the composer. Four capabilities behind one object, because they are
     * four questions about the same session and every one of them is dropped when another session
     * is opened.
     */
    var bar: SessionBarController? = null

    /** What is listening on this machine, and the verb that opens one of them over there. */
    var localhost: LocalhostController? = null

    /** One dev server per folder this machine has granted this device. */
    var devServer: DevServerController? = null

    /**
     * The tunnel behind whatever page this phone is showing from this machine.
     *
     * Created once per link, like the rest, and holds at most one tunnel: a phone shows one page,
     * and a table of them would be a socket on somebody's machine for every port ever tapped.
     */
    var tunnels: dev.terminaldeck.android.tunnel.TunnelController? = null

    /**
     * The machine's own agent, as this phone drives it. Created once per link; the tab is drawn only
     * when the machine advertises [dev.terminaldeck.android.protocol.Capability.COPILOT] **and** the
     * grant it handed this device is not empty — see
     * [dev.terminaldeck.android.protocol.CopilotAccess].
     */
    var copilot: CopilotController? = null

    /** The user's name for this machine, or enough of its id to tell it apart. */
    val label: String get() = record.label

    val uploadView: UploadView? get() = upload?.view

    /** A machine has admitted this phone at least once. */
    val approved: Boolean get() = record.approved

    fun closeSession() {
        binding?.close()
        binding = null
        // Everything that was about *that* session goes with it. A chip carrying the last session's
        // model, or a ring drawn from the last session's context, is worse than no chip and no ring
        // — it is the one surface that would disagree with the machine about which session is on
        // screen.
        controls?.forget()
        bar?.forget()
    }

    /**
     * Take this machine down without forgetting it.
     *
     * Not a loop over the state's default values by hand: everything that can outlive a socket —
     * the emulator, a transfer in flight — is ended here, because a link that has been stopped is
     * about to be dropped and anything still holding a `TerminalSession` would leak the whole
     * screen of rows with it.
     */
    fun stop() {
        closeSession()
        upload?.cancel("The machine was disconnected.")
        upload = null
        transport.disconnect()
        // The request clusters hold coroutine timers on the view model's scope; a stopped link is
        // about to be dropped, so they are cancelled here rather than left to fire against a socket
        // that will never answer. `appVersion` is deliberately *not* cleared — see its field.
        devices?.stop()
        settings?.stop()
        // The controls cluster holds a settle timer as well as its request timers, and the watcher
        // holds a cast on the machine — a link being taken down must end that cast, or the far end
        // keeps rendering JPEGs for a phone that is no longer listening.
        controls?.stop()
        watch?.stop()
        bar?.forget()
        localhost?.stop()
        devServer?.stop()
        tunnels?.stop()
        copilot?.stop()
        sessions = emptyList()
        live = false
        loaded = false
        capabilities = emptySet()
        grantedFolders = null
        connection = TransportState.Offline
    }

    fun summary(selected: Boolean): HostSummary = HostSummary(
        hostId = hostId,
        label = label,
        nickname = record.nickname,
        relayUrl = record.relayUrl,
        approved = record.approved,
        connection = connection,
        live = live,
        sessions = sessions,
        hostPlatform = hostPlatform,
        appVersion = appVersion,
        hostKind = hostKind,
        selected = selected,
    )
}

/**
 * One row of the switcher.
 *
 * Deliberately not the [HostLink] itself. A screen holding a link across a switch would be holding
 * a machine the user is no longer looking at, and a Compose list keyed on a mutable object does not
 * recompose when its fields change.
 */
data class HostSummary(
    val hostId: String,
    val label: String,
    val nickname: String?,
    val relayUrl: String,
    val approved: Boolean,
    val connection: TransportState,
    val live: Boolean,
    /**
     * What this machine last said it was running.
     *
     * Carried per machine rather than only for the one on screen, because the terminal route names
     * its machine and has to be able to look a session up in *that* one. A route that resolved its
     * session against whatever was on screen would, on the frame after a switch, resolve it against
     * the wrong computer.
     */
    val sessions: List<RemoteSessionView>,
    /**
     * What kind of machine this row is, for the sentences that name one.
     *
     * Per row for the same reason [sessions] is, and the consequence is the same shape of bug: a
     * phone holding a Mac *and* a PC that read the noun off whichever machine happened to be
     * selected would print "That session is no longer on the Mac" about a session that was on the
     * PC — which is the original defect, moved one screen over rather than fixed.
     *
     * [HostPlatform.UNKNOWN] until that machine's own `welcome` says otherwise. Never a guess.
     */
    val hostPlatform: HostPlatform,
    /**
     * What build this machine is running, from its own `welcome.appVersion`, or "" when it never
     * said. Per row for the reason [hostPlatform] is: a phone with a Mac and a PC shows each one's
     * build, and reading it off the selected machine would print one computer's version under
     * another's name.
     */
    val appVersion: String,
    /** `"desktop"` / `"headless"` for this machine, or null. Read through `HostVersion`. */
    val hostKind: String?,
    val selected: Boolean,
) {
    val isOnline: Boolean get() = connection.isOnline

    /**
     * How many sessions to show in the switcher, or null to show none.
     *
     * Only a number the machine is saying right now. A count left over from the last connection,
     * under a dot that is no longer green, would be the switcher getting wrong the one thing it
     * exists to show.
     */
    val sessionCount: Int? get() = if (live) sessions.size else null
}
