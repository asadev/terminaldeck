package dev.terminaldeck.android.protocol

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonClassDiscriminator

/**
 * The two message unions, transcribed from `ClientMessage` and `ServerMessage` in
 * `src/main/remote/protocol.ts`.
 *
 * `t` is the discriminator on the wire, so it is the discriminator here too — declared once on each
 * sealed root rather than as a field on every variant, which is what stops a new variant from being
 * added with the tag spelled wrong.
 */

/** Identity a phone volunteers about itself. Display only — never trusted by the desktop. */
@Serializable
data class DeviceDescriptor(
    val name: String,
    val platform: String,
)

/**
 * Which kind of secret an `enroll` frame is carrying.
 *
 * An enum rather than a string because the desktop's parser narrows it to exactly these two and
 * refuses anything else as `bad-message` — which closes the socket. A typo in a string literal
 * would be a sign-in that fails with an unexplained disconnect; a spelling this type cannot
 * produce is one nobody has to test for.
 *
 * The host chooses nothing from it: it hands the secret to sshd either way. What the value decides
 * is *how* it is offered — as a password, or as a private key.
 */
@Serializable
enum class EnrollMethod {
    @SerialName("password")
    Password,

    @SerialName("key")
    Key,
}

/**
 * A session as it arrives in `welcome` and `sessions`.
 *
 * `status` is free-form on purpose: the status vocabulary belongs to the desktop's session layer,
 * and modelling it as an enum here would turn the desktop adding a state into a phone that cannot
 * parse the list at all.
 */
@Serializable
data class RemoteSession(
    val id: String,
    val title: String,
    val cwd: String,
    val provider: String,
    val status: String,
    val exitCode: Int? = null,
) {
    fun toView(): RemoteSessionView =
        RemoteSessionView(id = id, title = title, cwd = cwd, provider = provider, status = status, exitCode = exitCode)
}

/**
 * The two settings this machine owns rather than each device, on the wire.
 *
 * Transcribed from `SERVER_SETTINGS` / `ServerSettingKey` in `src/main/remote/protocol.ts`. It is a
 * **closed allowlist**, and that is the point rather than a convenience: the desktop's parser
 * narrows `settings.apply.key` to exactly these two, refusing any other as `bad-message`, which is
 * what makes `remote.*` and `advanced.debugMode` unrepresentable here rather than merely rejected. A
 * key this phone cannot even spell is a key it cannot send by accident.
 *
 * The enum order is the order the section draws in and the order [ServerSetting.merge] keeps, so the
 * two rows never reshuffle between one push and the next.
 */
@Serializable
enum class ServerSettingKey {
    @SerialName("agents.defaultProvider")
    DefaultProvider,

    @SerialName("general.restoreSessions")
    RestoreSessions,
}

/**
 * One server-owned setting, on the wire.
 *
 * `value` is stringly, like `controls.apply` over there — `"true"`/`"false"` for the boolean, a
 * provider id for the chooser. `options` is present only for a chooser and holds the provider ids
 * this host can actually start, so the picker offers what will run rather than a fixed set that then
 * fails after the tap. Null and absent are the same fact — no chooser — and `explicitNulls = false`
 * keeps a null off the wire.
 */
@Serializable
data class ServerSettingWire(
    /**
     * The wire key, left a **free string** rather than a [ServerSettingKey] on purpose.
     *
     * Decoding it as the enum would fail the whole `settings.state` frame the day a future desktop
     * adds a third server-owned setting — turning the additive rule this file teaches everywhere else
     * into a phone that cannot read its two known settings because a third one it has never heard of
     * rode along. So an inbound row keeps its raw key and [known] maps it; [merge] drops the ones
     * this build cannot draw. Outbound, `settings.apply` carries a typed [ServerSettingKey] and so
     * cannot name a key the desktop's parser would refuse.
     */
    val key: String,
    val value: String,
    val options: kotlin.collections.List<String>? = null,
) {
    /** The typed key when this build knows it, or null for a setting added after this build. */
    val known: ServerSettingKey? get() = keyOf(key)

    companion object {
        /** Map a wire key onto [ServerSettingKey], or null when this build does not know it. */
        fun keyOf(wire: String): ServerSettingKey? = when (wire) {
            "agents.defaultProvider" -> ServerSettingKey.DefaultProvider
            "general.restoreSessions" -> ServerSettingKey.RestoreSessions
            else -> null
        }

        /**
         * Merge machine-sent rows into a held set, replacing by key and keeping [ServerSettingKey]'s
         * declaration order so the section never reshuffles on a push.
         *
         * A pure function so the one piece of receiving with a decision in it can be tested where a
         * composable cannot. Rows whose key this build does not [known] are dropped here rather than
         * failing the frame — the additive rule the whole protocol is built on.
         */
        fun merge(
            current: kotlin.collections.List<ServerSettingWire>?,
            next: kotlin.collections.List<ServerSettingWire>,
        ): kotlin.collections.List<ServerSettingWire> {
            val byKey = LinkedHashMap<ServerSettingKey, ServerSettingWire>()
            current?.forEach { row -> row.known?.let { byKey[it] = row } }
            next.forEach { row -> row.known?.let { byKey[it] = row } }
            return ServerSettingKey.entries.mapNotNull { byKey[it] }
        }
    }
}

/**
 * One row of the device roster, on the wire.
 *
 * Transcribed from `DeviceRosterRow`. [kind] and [status] are left as free strings rather than
 * enums for the same reason [RemoteSession.status] is: the vocabulary belongs to the desktop's trust
 * store, and modelling a closed set here would turn the desktop adding a state into a phone that
 * cannot parse the roster at all. The two values each has today are read through the predicates
 * below.
 *
 * `addedAt` and `lastSeenAt` are epoch milliseconds; `lastSeenAt` is null until the device has
 * attached at least once. `fingerprint` is the six-group key form a person can read and compare
 * against what the device itself shows, or null for a device paired before it had one.
 */
@Serializable
data class DeviceRosterRow(
    val id: String,
    val name: String,
    val kind: String,
    val status: String,
    val addedAt: Long = 0,
    val lastSeenAt: Long? = null,
    val connected: Boolean = false,
    val fingerprint: String? = null,
) {
    /** Waiting to be approved at the desk — the only thing to do about it is Remove, which denies. */
    val isPending: Boolean get() = status == "pending"

    /** One of the owner's own devices, as opposed to a guest lent a folder. */
    val isMine: Boolean get() = kind == "mine"
}

@OptIn(ExperimentalSerializationApi::class)
@Serializable
@JsonClassDiscriminator("t")
sealed interface ClientMessage {

    /**
     * `protocol` deliberately has no default.
     *
     * [dev.terminaldeck.android.protocol.ProtocolJson] is configured with `encodeDefaults = false`,
     * so a field carrying a default is a field that does not get written to the wire — and the
     * desktop answers a hello without a protocol version by closing the socket. A default here
     * would be a login that fails in production and passes every round-trip test.
     */
    @Serializable
    @SerialName("hello")
    data class Hello(
        val protocol: Int,
        val token: String,
        val device: DeviceDescriptor,
        /**
         * What this phone can do that the desktop would otherwise never ask it about.
         *
         * No default, for the same reason `protocol` has none: `encodeDefaults = false` means a
         * field carrying its default is a field that never reaches the wire, and a desktop that
         * does not see `credential` here will not send `credential.request` — so the approval
         * prompt would simply never appear, on a build whose every round-trip test passed.
         *
         * The list is [Capability.CLAIMED] and nothing else. It is *not* the desktop's own
         * capability list echoed back: everything in that one is something this phone asks for and
         * is gated on the desktop having offered it.
         */
        val capabilities: kotlin.collections.List<String>,
    ) : ClientMessage

    /**
     * Sign in with a login this server already trusts, instead of a pairing code.
     *
     * The other door before a `welcome`, and the whole reason a phone can add a server nobody is
     * sitting at. The host verifies `username` + `secret` against its own sshd on loopback, mints a
     * pre-approved device bound to *this connection's handshake key*, and answers
     * [ServerMessage.Enrolled] with a credential — which this client stores and then presents in an
     * ordinary [Hello] on the same socket. `enroll` never authenticates the socket itself.
     *
     * `protocol` and `capabilities` carry no defaults, for the reason [Hello] states at length:
     * [dev.terminaldeck.android.protocol.ProtocolJson] is configured with `encodeDefaults = false`,
     * so a field holding its default is a field that never reaches the wire — and a host that saw
     * no protocol version here would close the socket.
     *
     * `capabilities` is [Capability.CLAIMED] and is here rather than only on the follow-up hello
     * because the desktop may need it before that hello lands. It grants nothing, exactly as on
     * [Hello].
     *
     * A host too old to know this frame hits its parser's default case, refuses `bad-message` and
     * closes — which [dev.terminaldeck.android.signin.EnrollExchange] reads as "this server is too
     * old for sign-in" rather than as a bad password.
     */
    @Serializable
    @SerialName("enroll")
    data class Enroll(
        val protocol: Int,
        val device: DeviceDescriptor,
        val username: String,
        /** A password or a private-key PEM, depending on [method]. Never stored, never logged. */
        val secret: String,
        val method: EnrollMethod,
        val capabilities: kotlin.collections.List<String>,
    ) : ClientMessage

    @Serializable
    @SerialName("list")
    data object List : ClientMessage

    /**
     * `cols`/`rows` are the phone's viewport, and they travel with the attach so the first screen
     * arrives already the right shape.
     *
     * They are nullable because a client that has not measured its terminal yet must still be able
     * to attach and then resize — but the desktop refuses one without the other, so the pair is
     * built through [attach] rather than by calling the constructor.
     */
    @Serializable
    @SerialName("attach")
    data class Attach(
        val id: String,
        val cols: Int? = null,
        val rows: Int? = null,
    ) : ClientMessage

    @Serializable
    @SerialName("detach")
    data class Detach(val id: String) : ClientMessage

    @Serializable
    @SerialName("input")
    data class Input(val id: String, val data: String) : ClientMessage

    @Serializable
    @SerialName("resize")
    data class Resize(val id: String, val cols: Int, val rows: Int) : ClientMessage

    @Serializable
    @SerialName("ping")
    data object Ping : ClientMessage

    /**
     * Start a session on the desktop.
     *
     * Sent **only** when `welcome.capabilities` contained [Capability.CREATE]; the desktop's parser
     * closes the socket on a verb it has never heard of, so a hopeful button is a broken one.
     *
     * This was `New(title)`, tagged `new`, gated on `session.create` — a shape invented against this
     * repo's own stand-in and never spoken by a real desktop. Three things changed with it and each
     * is a decision rather than a rename:
     *
     *  - **No title.** Every session in this product is named after its folder, by the Mac. A
     *    phone-supplied title would be the one tab in the desktop whose name means something else,
     *    and it would be attacker-chosen display text in the desktop's own chrome for no gain.
     *  - **`cwd` instead.** A folder the desktop is *already offering* — the working directory of a
     *    session in the list on screen. The Mac refuses anything else rather than quietly starting
     *    somewhere else, so this app never invents one: null means "wherever you would have", which
     *    is what the desktop's own button does with nothing filled in.
     *  - **A size.** So the first screen of a new session arrives already the right shape instead of
     *    arriving at 80×24 and reflowing, exactly as it does on `attach`.
     */
    @Serializable
    @SerialName("create")
    data class Create(
        val cwd: String? = null,
        val cols: Int? = null,
        val rows: Int? = null,
    ) : ClientMessage

    /* ---- capability `close`. Never sent unless the desktop offered it. -------------------- */

    /**
     * End a session on the desktop.
     *
     * Sent **only** when `welcome.capabilities` contained [Capability.CLOSE]; the ✕ is absent
     * otherwise, and a client that sent this to a host which never advertised it would be closed for
     * `bad-message`.
     *
     * There is deliberately no reason string and no choice of signal. How a session exits is the
     * desktop's own ✕ behaviour, one behaviour rather than two that can drift, and a reason would be
     * attacker-chosen text about to be printed in the desktop's own chrome for nothing. A refusal —
     * the host cannot close, or this device may not touch that session — comes back as a plain
     * `error`, not a `close.failed`.
     */
    @Serializable
    @SerialName("close")
    data class Close(val id: String) : ClientMessage

    /* ---- capability `upload`. Never sent unless the desktop offered it. ------------------- */

    /**
     * A file is coming. **This message is the consent, and it is this phone's.**
     *
     * Nothing is written to the Mac's disk until this is sent, and it is sent because a person
     * picked something in the system photo picker or the document picker — both of which run in
     * another process, so this app holds no media permission and asks for none. The Mac answers with
     * the path the file will land at *before* any bytes move, and that path is on screen while
     * Cancel still means something.
     *
     * `name` is a suggestion; the Mac reduces it to one path component and picks the real name.
     */
    @Serializable
    @SerialName("upload.begin")
    data class UploadBegin(val id: String, val name: String, val size: Long) : ClientMessage

    /** One slice of the file, base64. Only legal after `upload.ready`. */
    @Serializable
    @SerialName("upload.data")
    data class UploadData(val id: String, val data: String) : ClientMessage

    /**
     * That was all of it, and this is the SHA-256 of everything that was read.
     *
     * The Mac compares it against the digest of everything it wrote and **deletes** the file when
     * they differ. A truncated video with the right name is worse than no video: it surfaces later,
     * somewhere else, as a file nobody can open.
     */
    @Serializable
    @SerialName("upload.end")
    data class UploadEnd(val id: String, val sha256: String) : ClientMessage

    /** Stop, and throw away what has landed. The Cancel button on the progress row. */
    @Serializable
    @SerialName("upload.cancel")
    data class UploadCancel(val id: String) : ClientMessage

    /* ---- capability `credential`. The one exchange that starts over there. ---------------- */

    /**
     * "I heard you, and I am dealing with it."
     *
     * The one frame here that exists purely for a failure mode, and it is the failure mode the
     * whole feature is judged on. Without it a desktop cannot tell a phone that is asleep from a
     * person who is thinking — both are silence — so it would have to wait out the *human*
     * deadline before it could say "your device isn't reachable": a thirty-second stall on a push
     * with nothing on screen, which is how people stop trusting a feature.
     *
     * With it there are two deadlines over there. A few seconds for this, which a live app answers
     * instantly; then, and only then, as long as a person needs to read a prompt and decide.
     *
     * Sent for silent requests too, where it costs nothing — the answer follows it in the same
     * breath — because a client that only acked when it was about to prompt would be one more
     * thing that has to be right.
     */
    @Serializable
    @SerialName("credential.ack")
    data class CredentialAck(val id: String) : ClientMessage

    /**
     * The login, for this one operation.
     *
     * It is used once, in memory, on the machine that asked, and is never written to that
     * machine's disk. There is no cache to expire and nothing to clean up when this phone
     * disconnects.
     *
     * [remember] is the "Always for this repo" button, and it is a **scope, not a stored secret**:
     * it tells that machine it may stop asking about that repository from this device. Every push
     * still comes back here for the credential itself, because the desktop has never held one.
     *
     * It defaults to false so that `encodeDefaults = false` leaves it off the wire entirely unless
     * somebody pressed that button — the desktop reads `remember === true` and nothing else, and a
     * literal `false` on the wire would be a field that says nothing while carrying somebody's
     * consent as its name.
     */
    @Serializable
    @SerialName("credential.answer")
    data class CredentialAnswer(
        val id: String,
        val username: String,
        val password: String,
        val remember: Boolean = false,
    ) : ClientMessage

    /**
     * No.
     *
     * Carries a code rather than a sentence, and the direction is the point: this string is written
     * *here* and read on somebody else's **desktop**, where it is printed into a terminal. The
     * desktop owns the words that appear in its own terminal — it is the side that knows whether
     * the reader is looking at a push or a fetch, and it is the side that must not pipe text chosen
     * by a phone into a PTY. So this end says which of two things happened and the desktop writes
     * the sentence.
     *
     * No default on [reason]: the desktop treats an absent one as `denied`, and defaulting here
     * would mean `encodeDefaults = false` silently turning [CredentialDenial.NoAccount] — which is
     * not a refusal at all — into one.
     */
    @Serializable
    @SerialName("credential.deny")
    data class CredentialDeny(val id: String, val reason: CredentialDenial) : ClientMessage

    /* ---- capability `devices`. The roster, and the one verb that removes a row. ---------- */

    /**
     * List every device signed in on the desktop.
     *
     * Sent only when `welcome.capabilities` named [Capability.DEVICES] — which the desktop puts there
     * for one of the owner's own devices and never a guest, so a phone that sees it is both able to
     * manage the roster and entitled to. [rid] names *this* question so two screens over one machine
     * cannot resolve each other's reads. Answered with `devices.rows`.
     */
    @Serializable
    @SerialName("devices.list")
    data class DevicesList(val rid: String) : ClientMessage

    /**
     * Remove one device from the desktop's roster.
     *
     * Its credential is revoked and its sockets dropped — the same cascade the desktop's own Settings
     * runs. [device] is the id to remove; revoke doubles as deny for a pending row, because there is
     * no approve verb on this wire. Answered with `devices.revoked`, carrying the fresh roster —
     * unless the phone revoked *itself*, in which case the socket simply closes and that is the
     * confirmation.
     */
    @Serializable
    @SerialName("devices.revoke")
    data class DevicesRevoke(val rid: String, val device: String) : ClientMessage

    /* ---- capability `settings`. The two settings the machine owns. ----------------------- */

    /**
     * Read the machine's two server-owned settings.
     *
     * Sent only when `welcome.capabilities` named [Capability.SETTINGS]. [rid] names this read.
     * Answered with `settings.state`, and the `settings.changed` push then keeps the rows fresh
     * without a poll.
     */
    @Serializable
    @SerialName("settings.read")
    data class SettingsRead(val rid: String) : ClientMessage

    /**
     * Change one of the machine's server-owned settings, over there.
     *
     * [key] is narrowed to [ServerSettingKey] by construction, so a frame naming any other key is
     * unrepresentable here rather than merely refused. [value] is stringly, like `controls.apply`:
     * `"true"`/`"false"` for the boolean, a provider id for the chooser. The outcome comes back as
     * `settings.applied`; every other eligible connection hears a `settings.changed`.
     */
    @Serializable
    @SerialName("settings.apply")
    data class SettingsApply(
        val rid: String,
        val key: ServerSettingKey,
        val value: String,
    ) : ClientMessage

    /* ---- capability `controls`. One session's model, effort, fast mode and permission. --- */

    /**
     * Read the control cluster of one session.
     *
     * Sent only when `welcome.capabilities` named [Capability.CONTROLS]. [rid] names *this* question
     * so two screens over one machine cannot resolve each other's reads, and [id] is checked again
     * on the way back — another session's model landing on this chip would be this phone typing a
     * model change at the wrong terminal. Answered with `controls.reading`.
     *
     * Asked on attach and again whenever the session prints and goes quiet: the model line, the
     * effort confirmation and the permission footer are all read from what the far pty writes, so
     * output settling is the event every chip changes on.
     */
    @Serializable
    @SerialName("controls.read")
    data class ControlsRead(val rid: String, val id: String) : ClientMessage

    /**
     * Change one control on one session, over there.
     *
     * [control] is narrowed to [ControlName] by construction, so a frame naming any other control is
     * unrepresentable here rather than merely refused. [value] is stringly — a model alias, an
     * effort id, `"on"`/`"off"`, a permission mode — and comes from [ControlCatalog], which is this
     * app's copy of the desktop's own list, because the value ends up typed at a real `claude`
     * binary. The outcome comes back as `controls.applied`, carrying the far end's **re-read** of
     * that one control rather than the value that was pressed, which is what makes a refused apply
     * revert by construction.
     */
    @Serializable
    @SerialName("controls.apply")
    data class ControlsApply(
        val rid: String,
        val id: String,
        val control: ControlName,
        val value: String,
    ) : ClientMessage

    /* ---- capability `watch`. Watching, and driving, a browser window over there. ---------- */

    /**
     * Start — or renegotiate — the cast of one browser surface to this phone.
     *
     * [window] is `""` for the front tab or a slot name. Idempotent on the host, which is how a
     * rotation renegotiates: the same frame with a new [maxWidth] replaces the running cast rather
     * than starting a second one. Both numbers are clamped into the host's range by
     * [WatchMath.watchWidth] and [WatchMath.watchQuality] before they are sent, so what arrives is
     * what was asked for instead of what the host quietly reduced it to.
     */
    @Serializable
    @SerialName("browser.watch")
    data class BrowserWatch(
        val window: String,
        val maxWidth: Int,
        val quality: Int,
    ) : ClientMessage

    /** Stop the cast of one surface. Sent when the viewer closes — never left running behind a back. */
    @Serializable
    @SerialName("browser.unwatch")
    data class BrowserUnwatch(val window: String) : ClientMessage

    /**
     * Drawn — send the next frame.
     *
     * The one-in-flight backpressure: the host holds one un-acked frame per watcher, so this is sent
     * from the paint callback and never on receipt. Acking early asks a machine for frames faster
     * than a phone can draw them, which spends a radio on pixels that are stale before they land.
     */
    @Serializable
    @SerialName("browser.frame.ack")
    data class BrowserFrameAck(val window: String, val seq: Int) : ClientMessage

    /**
     * One gesture aimed at the frame named by [seq].
     *
     * Exactly one of [mouse], [key], [touch] and [paste] is set, because each rides a different CDP
     * method on the far side and a frame naming two could not have been one gesture. `explicitNulls
     * = false` keeps the other three off the wire entirely rather than as nulls the desktop's parser
     * would have to forgive.
     *
     * [seq] names the frame the coordinates were measured against, so a scroll landing mid-gesture
     * cannot desync the mapping: the host inverts *that* frame's transform, not whatever the page
     * has moved to since.
     */
    @Serializable
    @SerialName("browser.input")
    data class BrowserInput(
        val window: String,
        val seq: Int,
        val mouse: BrowserMouseWire? = null,
        val key: BrowserKeyWire? = null,
        val touch: BrowserTouchWire? = null,
        val paste: String? = null,
    ) : ClientMessage

    /**
     * Ask for the tab strip — every surface this machine says is watchable.
     *
     * Asked once when the screen opens; the unsolicited `browser.surfaces.rows` push keeps it fresh
     * after that without a poll.
     */
    @Serializable
    @SerialName("browser.surfaces")
    data class BrowserSurfaces(val rid: String) : ClientMessage

    /* ---- capability `usage`. The two figures a session's bar draws. ---------------------- */

    /**
     * Read one usage figure for one session.
     *
     * The three [UsageWant]s are not interchangeable and do not cost the same, which is why the
     * question names one rather than a client asking for "usage" and sorting out the answer.
     * [force] is true only for [UsageWant.Refresh], which boots a whole agent on the far machine,
     * and it is therefore only ever sent because a finger pressed the ring.
     *
     * [force] carries no default: `encodeDefaults = false` would drop a literal `false`, and the
     * desktop's parser reads `force === true` and nothing else — so writing it every time is a field
     * that says what it means rather than one that sometimes disappears.
     */
    @Serializable
    @SerialName("usage.read")
    data class UsageRead(
        val rid: String,
        val id: String,
        val want: UsageWant,
        val force: Boolean,
    ) : ClientMessage

    /* ---- capability `account`. Which login a session runs as. ---------------------------- */

    /** Which login this session runs as, and every login the machine has. Answered `account.state`. */
    @Serializable
    @SerialName("account.read")
    data class AccountRead(val rid: String, val id: String) : ClientMessage

    /**
     * Run this session as a different login.
     *
     * The far end decides whether the switch took, and this client never renames a chip on the press
     * — it re-reads. A row of a *different agent* is refused over there with a sentence, and nothing
     * on this bar draws sentences, so such a row is not pressable in the first place; see
     * [foreignAccount].
     */
    @Serializable
    @SerialName("account.switch")
    data class AccountSwitch(
        val rid: String,
        val id: String,
        val accountId: String,
    ) : ClientMessage

    /* ---- capability `send`. A whole message, rather than keystrokes. --------------------- */

    /**
     * Type a whole message at a session as one act.
     *
     * Not [Input]. `input` is bytes at a pty and carries no request id, so nothing can say whether
     * they landed; this is answered with `session.sent`, which is what lets a composer keep the
     * draft on a refusal instead of losing it into a socket. Bounded by the same cap `input` gets,
     * in bytes, because it is the same paste going into the same pty.
     */
    @Serializable
    @SerialName("session.send")
    data class SessionSend(val rid: String, val id: String, val data: String) : ClientMessage

    /* ---- capability `chat`. The conversation, as a chat. --------------------------------- */

    /* ---- capability `web`. A page, opened on the machine. -------------------------------- */

    /**
     * Open this page **on the machine**, in its own browser.
     *
     * A phone cannot serve through a port on somebody else's computer, and the honest version of
     * "drive localhost" is that the page opens *there* and the device that asked is driving rather
     * than viewing. The host refuses anything that is not http(s) and refuses a guest outright; a
     * refusal is a plain `error`, and success is `web.opened`, which is sent only once a tab was
     * actually made.
     */
    @Serializable
    @SerialName("web.open")
    data class WebOpen(val url: String) : ClientMessage

    /* ---- capability `localhost`. What is listening, and a tunnel to one of them. --------- */

    /** What is listening on the machine right now. Answered with `ports`. */
    @Serializable
    @SerialName("ports")
    data object Ports : ClientMessage

    /**
     * Open a tunnel to one port on the machine. Answered `tunnel.opened`, refused `tunnel.closed`.
     *
     * **This message is the consent.** There is no standing permission and no allowlist of ports: a
     * tunnel exists between a tap and the moment the view closes, and `tunnel.close` — from either
     * end — is the whole of the teardown.
     */
    @Serializable
    @SerialName("tunnel.open")
    data class TunnelOpen(val id: String, val port: Int) : ClientMessage

    /** Tear one down. Idempotent over there: closing a tunnel that has gone is not an error. */
    @Serializable
    @SerialName("tunnel.close")
    data class TunnelClose(val id: String) : ClientMessage

    /**
     * A new byte stream inside a tunnel: one browser connection, one [ch].
     *
     * Only legal after `tunnel.opened` has been heard. Opening a tunnel waits on a port scan on the
     * far side, so a client that sent both in one breath would be refused for naming a tunnel that
     * does not exist yet — which is why this client binds its listening socket on the confirmation,
     * not on the request.
     */
    @Serializable
    @SerialName("net.open")
    data class NetOpen(val ch: String, val tunnel: String) : ClientMessage

    /** Bytes for one stream, base64. Bounded by [Protocol.MAX_NET_DATA_CHARS]. */
    @Serializable
    @SerialName("net.data")
    data class NetData(val ch: String, val data: String) : ClientMessage

    /** "I have written this many bytes to my socket." See [Protocol.NET_WINDOW_BYTES]. */
    @Serializable
    @SerialName("net.ack")
    data class NetAck(val ch: String, val bytes: Int) : ClientMessage

    /** One stream is finished. The tunnel outlives it. */
    @Serializable
    @SerialName("net.close")
    data class NetClose(val ch: String) : ClientMessage

    /* ---- capability `devserver`. One project's dev server. ------------------------------- */

    /**
     * What is this project's dev server doing?
     *
     * [folder] is a folder *this client* named and nothing has checked yet — the same rule and the
     * same wording as `create.cwd`, because it is the same question with the same answer. The
     * desktop accepts only a folder it is already offering this device in `welcome.folders`, so the
     * value has an honest source on the phone (a row that is on screen) and naming it grants nothing
     * the device could not already do.
     */
    @Serializable
    @SerialName("dev.status")
    data class DevStatus(val folder: String) : ClientMessage

    /**
     * Start it. **This message is the consent, and there is no standing one.**
     *
     * Nothing runs on the desktop because of this feature until one of these arrives, and one only
     * arrives because a person tapped a row for a folder their desktop has granted them. The command
     * is not on the wire and cannot be: the desktop reads the folder's own `package.json` and runs
     * the script it declares, and a client that could name a command would be a client that could
     * run one.
     */
    @Serializable
    @SerialName("dev.start")
    data class DevStart(val folder: String) : ClientMessage

    /* ---- capability `copilot`. The machine's own agent, driven from here. ---------------- */

    /**
     * Open the copilot on this socket.
     *
     * **It carries nothing.** There was a `copilot.connect` until 2026-08-19 — redeem a six-digit
     * copilot code, receive a credential — and this frame used to present that credential on every
     * socket. Both are gone. The second factor is *having been paired as one of the owner's own
     * devices*, which is decided at the machine, cannot be changed without pairing again, and is what
     * makes it honest for a device to hold `alter` and answer its own confirmations.
     */
    @Serializable
    @SerialName("copilot.hello")
    data object CopilotHello : ClientMessage

    /**
     * Close the copilot connection on this socket, and keep the terminals.
     *
     * Not a disconnect: the record survives, so the next `copilot.hello` works. It is what this
     * client sends when a person leaves the Copilot tab on a device they share.
     */
    @Serializable
    @SerialName("copilot.bye")
    data object CopilotBye : ClientMessage

    /**
     * Watch this device's copilot surface, and replay what exists.
     *
     * Starts nothing and spends nothing, which is why it is the `read` tier. Answered with
     * `copilot.state`, then — if this device already has a run — a `copilot.chat` carrying `reset`.
     */
    @Serializable
    @SerialName("copilot.attach")
    data object CopilotAttach : ClientMessage

    /**
     * Stop the stream. **The run keeps going**, for a grace window, and that is deliberate: a phone
     * that locks its screen in a lift has not asked for its agent to be killed mid-turn.
     */
    @Serializable
    @SerialName("copilot.detach")
    data object CopilotDetach : ClientMessage

    /** Read the state without attaching. Answered with `copilot.state`. */
    @Serializable
    @SerialName("copilot.state")
    data object CopilotState : ClientMessage

    /** The sessions the copilot started, each linked back to the turn that made it. */
    @Serializable
    @SerialName("copilot.sessions")
    data object CopilotSessions : ClientMessage

    /**
     * The tail of the copilot's action log, newest last.
     *
     * [before] pages backwards by row id rather than by index, because the file is appended to while
     * somebody is reading it and an index-based page would skip or repeat rows exactly when the
     * copilot is busiest. [limit] is refused rather than clamped over there — a client asking for a
     * thousand rows has misunderstood the cap, and being silently answered with two hundred while it
     * believes it has the whole log is how a phone draws "that is everything the copilot did today"
     * over a window.
     */
    @Serializable
    @SerialName("copilot.log")
    data class CopilotLog(val limit: Int? = null, val before: String? = null) : ClientMessage

    /** Confirmations waiting at the desk. Watch-only — a row that is not this device's has no buttons. */
    @Serializable
    @SerialName("copilot.pending")
    data object CopilotPending : ClientMessage

    /**
     * Start this device's own run.
     *
     * Deliberately not folded into `copilot.attach`: it spawns an agent process and that spends
     * money, so it is a thing a person taps rather than a side effect of opening a tab. A second one
     * against a live run is answered with the run that already exists rather than a second process.
     */
    @Serializable
    @SerialName("copilot.start")
    data object CopilotStart : ClientMessage

    /** Say something to it. The `act` tier, because talking to an agent *is* acting. */
    @Serializable
    @SerialName("copilot.say")
    data class CopilotSay(val text: String) : ClientMessage

    /** Interrupt the current turn of **this device's own run**, and nothing else. */
    @Serializable
    @SerialName("copilot.cancel")
    data object CopilotCancel : ClientMessage

    /** End this device's own run. */
    @Serializable
    @SerialName("copilot.stop")
    data object CopilotStop : ClientMessage

    /**
     * Answer a confirmation.
     *
     * The `alter` tier, and refused unless this connection owns the run that raised the question.
     * First answer wins; the loser is told where it was answered rather than having its dialog
     * vanish.
     *
     * [approved] carries no default: only a literal boolean is read over there, and a client whose
     * wiring sent nothing must not approve somebody's settings being rewritten.
     */
    @Serializable
    @SerialName("copilot.answer")
    data class CopilotAnswer(val id: String, val approved: Boolean) : ClientMessage

    /* ---- capability `rename`. Never sent unless the machine offered it. ------------------- */

    /**
     * Give a session a name of this person's choosing.
     *
     * An **empty** title is not a mistake and is not refused: it means *take my name off it*, and the
     * machine answers by deriving its own from the folder again — the only way back from a rename, and
     * a phone should not have to know what the machine would have called it to undo one. The answer is
     * the ordinary session list, not a frame of its own.
     */
    @Serializable
    @SerialName("rename")
    data class Rename(val id: String, val title: String) : ClientMessage

    /* ---- capability `folders.pick`. Walking the machine's folders. ----------------------- */

    /**
     * List the sub-folders of [path], so somebody can walk to the one they want.
     *
     * Null means *somewhere sensible*, which the machine answers as the folder this device already
     * works in. The phone deliberately does not guess a starting path — it does not know whether this
     * machine's home is `/Users/apple`, `/root` or `C:\Users\asad`, and a wrong guess opens the picker
     * on an error. Answered with [ServerMessage.FolderEntries].
     */
    @Serializable
    @SerialName("folders.browse")
    data class BrowseFolders(val path: String? = null) : ClientMessage

    /* ---- capabilities `files`, `git`, `panels`. Read-only, all of it. -------------------- */

    /** What is in this folder — files as well as directories. Answered with [FileListing]. */
    @Serializable
    @SerialName("files.list")
    data class FilesList(val path: String) : ClientMessage

    /**
     * One file's bytes, as text, capped. [at]/[max] let a phone read the start of a large file rather
     * than be refused it; the next screen is a second read from the offset the host returned
     * ([FileText.nextOffset]), never a bigger one. Answered with [FileText].
     */
    @Serializable
    @SerialName("files.read")
    data class FilesRead(val path: String, val at: Int? = null, val max: Int? = null) : ClientMessage

    /** What git says about this folder. Both answers — a repository, and a folder that is not one —
     *  are answers. Answered with [ServerMessage.GitStateFrame]. */
    @Serializable
    @SerialName("git.status")
    data class GitStatus(val path: String) : ClientMessage

    /**
     * One file's diff. [file] is a path git itself reported, so it is repository-root-relative.
     *
     * [staged] carries no default so it is always on the wire: the staged and unstaged diffs of one
     * file are two different answers, and a client that let the field go missing would ask for one and
     * not know which it got. Answered with [ServerMessage.GitPatch].
     */
    @Serializable
    @SerialName("git.diff")
    data class GitDiff(val path: String, val file: String, val staged: Boolean) : ClientMessage

    /** One of the four read-only panels. [path] null means *somewhere sensible*, which the host
     *  answers as this device's first granted folder. Answered with [PanelData]. */
    @Serializable
    @SerialName("panel.read")
    data class PanelRead(
        val panel: String,
        val path: String? = null,
        val scope: String? = null,
        val query: String? = null,
    ) : ClientMessage

    /**
     * Do the thing a panel offered.
     *
     * [action] is a string this build never interprets — it came off a [PanelAction] the host itself
     * sent in the last [PanelData], and it goes straight back. That is what lets a panel grow a button
     * with no change here, and it is safe for exactly that reason: the phone can only send an action it
     * was handed. [id] names a row for a row's action and is null for the panel's own; [fields] is one
     * action's form filled in. Answered with a fresh [PanelData].
     */
    @Serializable
    @SerialName("panel.act")
    data class PanelAct(
        val panel: String,
        val action: String,
        val path: String? = null,
        val id: String? = null,
        val scope: String? = null,
        val query: String? = null,
        val fields: Map<String, String>? = null,
    ) : ClientMessage

    /* ---- capability `browser.control`. The machine's own browser. ------------------------ */

    /** What the machine's browser has open, and which sessions could own one. Answered with
     *  [MachineBrowserState]. */
    @Serializable
    @SerialName("browser.windows")
    data object BrowserWindows : ClientMessage

    /**
     * Open one there. [isolated] gives it a partition of its own, thrown away when the window closes.
     *
     * [session] opens it **and attaches it in one move**, which is the honest way to grant *Attach to a
     * session* for a page a phone opened over a tunnel — that page lives in no machine window and has
     * no id to bind, so the same address is re-opened in the machine's own browser and *that* window
     * attached. The host keeps the new id inside itself and does the attach while it still holds it,
     * because picking the new row back out of the list is a race two opens can both lose. Answered with
     * [MachineBrowserState].
     */
    @Serializable
    @SerialName("browser.window.open")
    data class BrowserWindowOpen(
        val url: String? = null,
        val profile: String? = null,
        val isolated: Boolean = false,
        val session: String? = null,
    ) : ClientMessage

    /** Send an open window somewhere. */
    @Serializable
    @SerialName("browser.window.go")
    data class BrowserWindowGo(val id: String, val url: String) : ClientMessage

    /** Back, forward, reload, close, record on or off, share or isolate. The verb is a closed set —
     *  see [BrowserWindowAction] — because the host refuses a word it does not know. */
    @Serializable
    @SerialName("browser.window.act")
    data class BrowserWindowAct(val id: String, val action: BrowserWindowAction) : ClientMessage

    /**
     * Lay that window's page out in a rectangle of this size, in **CSS pixels**.
     *
     * Sent on a change, never on a frame — when a window is first shown in a pane and when that pane's
     * width actually moves — because it is a reconfiguration of the machine's browser, not a per-frame
     * negotiation. Both numbers are clamped host-side rather than refused so a rotation cannot drop the
     * socket; clamp on the way out with [MachineBrowserWire.clampPageWidth]/`clampPageHeight` so what a
     * screen believes it asked for is what the machine was asked for.
     */
    @Serializable
    @SerialName("browser.window.size")
    data class BrowserWindowSize(val id: String, val width: Int, val height: Int) : ClientMessage

    /** Bind a window to a session so the agent in it knows which window is its own. A null [session]
     *  unbinds — the same frame, deliberately: a client that meant to unbind and one whose field went
     *  missing are one message, and unbinding is the harmless half. */
    @Serializable
    @SerialName("browser.window.bind")
    data class BrowserWindowBind(val id: String, val session: String? = null) : ClientMessage

    /** Photograph it. With a [session], the picture is handed to that session rather than coming back
     *  as a [MachineShot]. */
    @Serializable
    @SerialName("browser.window.shot")
    data class BrowserWindowShot(
        val id: String,
        val session: String? = null,
        val note: String? = null,
    ) : ClientMessage

    /** What the recorder has collected on that window so far. Answered with [ServerMessage.BrowserRecordRows]. */
    @Serializable
    @SerialName("browser.window.steps")
    data class BrowserWindowSteps(val id: String) : ClientMessage

    /**
     * What is at one point on that window's page — the tap that says *change this*.
     *
     * [x]/[y] are **document** coordinates: the same space `browser.frame`'s scroll is in, so a viewer
     * turns a tap on a picture into a point on the page by adding the scroll of the frame it drew.
     * [up] is how many ancestors to walk up and is the whole of Wider/Narrower — it **must never
     * exceed** [MachineBrowserWire.MAX_PICK_UP], because the host checks that range in its *parser* and
     * a parse failure closes the socket, so clamp with [MachineBrowserWire.clampPickUp]. Null is zero,
     * the element the point actually hit. Answered with [ServerMessage.BrowserWindowPicked].
     */
    @Serializable
    @SerialName("browser.window.pick")
    data class BrowserWindowPick(
        val id: String,
        val x: Double,
        val y: Double,
        val up: Int? = null,
    ) : ClientMessage

    /* ---- capability `browser.profiles`. The machine's browser profiles. ------------------ */

    /** List the machine's browser profiles and which it is using. No `rid`: all three verbs answer
     *  with the whole [MachineProfileList], which is what lets the screen confirm itself. */
    @Serializable
    @SerialName("browser.profiles")
    data object BrowserProfiles : ClientMessage

    /** Switch the machine's browser to this profile — it decides which jar the **next** page opens into. */
    @Serializable
    @SerialName("browser.profile.use")
    data class BrowserProfileUse(val id: String) : ClientMessage

    /** Empty one profile's jar on the machine. Signs that machine's browser out of everything in it,
     *  and touches nothing this phone holds. */
    @Serializable
    @SerialName("browser.profile.clear")
    data class BrowserProfileClear(val id: String) : ClientMessage

    /* ---- capability `copilot.files`. The copilot's own files. ----------------------------- */

    /** What files are there — a listing, nothing opened. Answered with [ServerMessage.CopilotFilesRows],
     *  which also comes back after every write, restore and delete. */
    @Serializable
    @SerialName("copilot.files")
    data object CopilotFilesList : ClientMessage

    /** One file, whole. Answered with [ServerMessage.CopilotFileText] on **every** branch, refusals
     *  included — silence is not an answer to a box somebody presses Save on. */
    @Serializable
    @SerialName("copilot.file.read")
    data class CopilotFileRead(val id: String) : ClientMessage

    /** Save one file. Only sent for a row whose [CopilotFileRow.writable] is true; the host refuses the
     *  two generated files and anything already too large to have been sent whole. */
    @Serializable
    @SerialName("copilot.file.write")
    data class CopilotFileWrite(val id: String, val text: String) : ClientMessage

    /** Put the instructions this build ships back. [id] is carried even though only `yours` is served,
     *  so the refusal for any other file is a sentence rather than a frame that quietly did nothing. */
    @Serializable
    @SerialName("copilot.file.reset")
    data class CopilotFileReset(val id: String) : ClientMessage

    /** Forget one memory. By **name**, not by id — memory files are the only deletable thing here, and
     *  a delete verb keyed by name means no id can ever be pointed at an unlink. */
    @Serializable
    @SerialName("copilot.memory.delete")
    data class CopilotMemoryDelete(val name: String) : ClientMessage

    /* ---- capability `routines`. The machine's saved instructions. ------------------------- */

    /** Every routine on that machine. Carries nothing — one folder per machine — and it is the answer
     *  to each of the four verbs below as well as to itself. Answered with [ServerMessage.RoutinesRows]. */
    @Serializable
    @SerialName("routines")
    data object Routines : ClientMessage

    /** One routine's file, **to read**. There is no frame that writes one back and this enum must not
     *  grow one — see [RoutinesWire]. Answered with [RoutineFile]. */
    @Serializable
    @SerialName("routine.text")
    data class RoutineText(val id: String) : ClientMessage

    /** Run this one now, whatever its triggers say. **Starts an agent turn on that machine.** The
     *  engine has the last word; a row's [RoutineRow.canRun] covers only the refusals certain before
     *  the press. */
    @Serializable
    @SerialName("routine.run")
    data class RoutineRun(val id: String) : ClientMessage

    /** Hold it. **Its file is not touched** — a hold is engine state beside the file. [reason] is what
     *  a person reads later; null lets the machine write its own rather than leaving a blank. */
    @Serializable
    @SerialName("routine.pause")
    data class RoutinePause(val id: String, val reason: String? = null) : ClientMessage

    /** Let it go again. Clears the hold and the failure count with it. */
    @Serializable
    @SerialName("routine.resume")
    data class RoutineResume(val id: String) : ClientMessage

    /** Delete it. **Its file is removed from disk.** There is no confirmation on the wire — a
     *  confirmation is a thing a person sees, which makes it the screen's rather than the protocol's. */
    @Serializable
    @SerialName("routine.delete")
    data class RoutineDelete(val id: String) : ClientMessage

    companion object {
        /**
         * Attach with a size when there is one, without when there is not.
         *
         * The desktop's parser reads "both or neither, never one" — an attach carrying only `cols`
         * is refused as `bad-message` and closes the socket. Funnelling construction through here
         * means the phone cannot express the refused shape.
         */
        fun attach(id: String, cols: Int?, rows: Int?): Attach =
            if (cols == null || rows == null) {
                Attach(id)
            } else {
                Attach(id, Protocol.clampCols(cols), Protocol.clampRows(rows))
            }

        /**
         * Create with a size when there is one, without when there is not.
         *
         * Same rule as [attach], same reason, and it is easier to get wrong here: every field on
         * `create` is optional, so the shape the desktop refuses — one dimension without the other —
         * is one a caller can express by accident.
         */
        fun create(cwd: String?, cols: Int?, rows: Int?): Create =
            if (cols == null || rows == null) {
                Create(cwd = cwd?.takeIf { it.isNotEmpty() })
            } else {
                Create(
                    cwd = cwd?.takeIf { it.isNotEmpty() },
                    cols = Protocol.clampCols(cols),
                    rows = Protocol.clampRows(rows),
                )
            }
    }
}

@OptIn(ExperimentalSerializationApi::class)
@Serializable
@JsonClassDiscriminator("t")
sealed interface ServerMessage {

    @Serializable
    @SerialName("welcome")
    data class Welcome(
        val protocol: Int,
        val deviceId: String,
        val deviceName: String,
        /**
         * A freshly minted token when this device has just been paired, null when it authenticated
         * with one it already had. Persisting it is the crypto workstream's problem, not this
         * layer's — see `store/DeviceVault.kt`, which persists it behind the Android Keystore.
         */
        val token: String? = null,
        val sessions: kotlin.collections.List<RemoteSession> = emptyList(),
        /**
         * What this desktop can do beyond protocol version 1.
         *
         * Not in `src/main/remote/protocol.ts`, and deliberately additive rather than a version
         * bump: `ProtocolJson` ignores unknown keys, so a desktop that has never heard of the field
         * simply does not send one and this stays empty. The phone then does not offer the feature
         * — which is the point. A client that sent a message type the desktop's `parseClientMessage`
         * has never seen would be closed for `bad-message`, so a capability the desktop did not
         * claim must never be exercised.
         *
         * Known values are in [Capability]. Read that file before adding one: a capability string
         * is a promise about a wire shape, and reusing a name for a different shape is worse than
         * inventing a new one.
         */
        val capabilities: kotlin.collections.List<String> = emptyList(),
        /**
         * What kind of machine this desktop is — `darwin`, `win32`, `linux`.
         *
         * Raw, and mapped to a noun by [HostPlatform] rather than here, because the noun is
         * presentation and the same value has to serve a heading, a button and a sentence.
         *
         * Null is a real answer and not a missing one: like [capabilities] this is additive rather
         * than a version bump, so a desktop that predates the field simply does not send it and
         * `ignoreUnknownKeys` leaves this at its default. A client that reads nothing here must say
         * something neutral — **never "Mac"**, which is the bug the field exists to end. See
         * [HostPlatform].
         */
        val hostPlatform: String? = null,
        /**
         * The folders this device may start a session in, most relevant first.
         *
         * The same array the desktop's own `create` rule enforces against, so a folder in here is
         * one that will start. It exists because the phone used to build its picker out of the
         * working directories of the sessions it could see — a list nobody chose, that changed when
         * a project was closed at the desk, and that the person holding the phone had no way to
         * explain. One folder in the picker and no answer available is the bug being fixed.
         *
         * **Null and empty are different facts and must never be folded together.** Null is a
         * desktop that predates the field — additive, like [capabilities], so `ignoreUnknownKeys`
         * leaves it at this default — and a client reading null keeps doing what it did before.
         * Empty is a person having chosen *no* folders for this device, which is a real state with
         * a real remedy, and showing it as "your desktop is old" would hide the only sentence that
         * explains why nothing starts.
         */
        val folders: kotlin.collections.List<String>? = null,
        /**
         * What build this desktop is running, e.g. `"0.10.0"`. **Absent means older.**
         *
         * Additive and optional like [capabilities] and [hostPlatform], and read defensively: it is
         * display text and nothing else — never an identity, never a thing to act on — bounded on
         * arrival because it renders on a chip beside terminal output. There is deliberately no
         * update verb anywhere on this wire to pair it with; what it buys a client is the one honest
         * sentence it can say when its own build is ahead — *update this server from a desktop*. See
         * [HostVersion].
         */
        val appVersion: String? = null,
        /**
         * Which shell is serving — `"desktop"` or `"headless"`. **Absent, or any other value, means
         * older.**
         *
         * Left a free string rather than an enum so an unrecognised value drops to "no noun" instead
         * of failing the whole `welcome` parse — the same rule [hostPlatform] keeps. Read through
         * [HostVersion.hostKindNoun], which turns `headless` into *server* and `desktop` into
         * *desktop* and anything else into nothing.
         */
        val hostKind: String? = null,
        /**
         * What this machine calls **itself** — its hostname. Display text, never an identity.
         *
         * Optional and additive; a client that reads nothing here keeps whatever name it already had
         * for the machine (the platform noun, or the relay slot).
         */
        val hostName: String? = null,
    ) : ServerMessage

    /**
     * The device that was just signed in, with the credential to reconnect as.
     *
     * The answer to [ClientMessage.Enroll], sent exactly once, pre-authentication, and only ever
     * inside the sealed channel. `credential` is the plaintext bearer secret — unlike a pairing
     * code it is shown to nobody — and the client's job is to store it and immediately say [Hello]
     * with it on the **same socket**. The host does not special-case that hello: the new device row
     * is already approved and already bound to this connection's key, so it comes in through the
     * ordinary door.
     *
     * A refused sign-in is not this frame. It is an ordinary [Error] — `unauthorized` for a bad
     * login or a rate-limited one, collapsed into one sentence on purpose, or `unavailable` when
     * the machine cannot offer sign-in at all.
     */
    @Serializable
    @SerialName("enrolled")
    data class Enrolled(
        val deviceId: String,
        val deviceName: String,
        val credential: String,
    ) : ServerMessage

    @Serializable
    @SerialName("sessions")
    data class Sessions(val sessions: kotlin.collections.List<RemoteSession>) : ServerMessage

    @Serializable
    @SerialName("attached")
    data class Attached(val id: String) : ServerMessage

    @Serializable
    @SerialName("detached")
    data class Detached(val id: String) : ServerMessage

    /** `replay` marks scrollback that arrived before this client did. */
    @Serializable
    @SerialName("output")
    data class Output(
        val id: String,
        val data: String,
        val replay: Boolean = false,
    ) : ServerMessage

    @Serializable
    @SerialName("status")
    data class Status(val id: String, val status: String) : ServerMessage

    @Serializable
    @SerialName("exit")
    data class Exit(val id: String, val exitCode: Int) : ServerMessage

    /**
     * `code` carries a default so that `coerceInputValues` in [ProtocolJson] can map a code this
     * build has never heard of onto [ProtocolErrorCode.Unknown] rather than failing the parse. An
     * unparseable `error` frame is the worst one to drop: it is the desktop explaining why it is
     * about to close the socket.
     */
    @Serializable
    @SerialName("error")
    data class Error(
        val code: ProtocolErrorCode = ProtocolErrorCode.Unknown,
        val message: String = "",
    ) : ServerMessage

    @Serializable
    @SerialName("pong")
    data object Pong : ServerMessage

    /* ---- capability `create` --------------------------------------------------------------- */

    /**
     * The session the Mac just started, for the phone that asked.
     *
     * The whole row rather than an id, so the tap that started a session is also the tap that opens
     * it. Answering with a bare `sessions` list — which is what both stand-in hosts used to do —
     * leaves the phone guessing which row is new, and with two sessions in the same folder there is
     * no way to guess right. Every *other* connected device is told with a plain `sessions`, which
     * every client back to the first one understands.
     */
    @Serializable
    @SerialName("created")
    data class Created(val session: RemoteSession) : ServerMessage

    /* ---- capability `close` --------------------------------------------------------------- */

    /**
     * The desktop ended the session this phone asked it to end.
     *
     * The whole row is not carried — just the id — because the phone already holds the row and this
     * only removes it. It is removed on *this* frame and never on the tap: an optimistic removal over
     * a refusal (a folder taken back, a session that had already exited) would leave a live session
     * missing from the list with no way back but a reconnect. Every other device is told with a plain
     * `sessions`. A refusal is a plain `error`, not a `close.failed`.
     */
    @Serializable
    @SerialName("closed")
    data class Closed(val id: String) : ServerMessage

    /**
     * This device's folder list changed while it was connected.
     *
     * Pushed rather than polled, and the whole list rather than a delta: there is one short list
     * per device, and a client applying deltas would have to be right about every one of them to
     * end up with the set the desktop is actually enforcing.
     *
     * It matters because the list is editable at the desk at any moment. Enforcement is already
     * live without this frame — the desktop consults the list on every `create` — so what it buys
     * is an honest picker: without it, a folder somebody took away five minutes ago is still drawn
     * on the phone, offering a tap whose only possible outcome is a refusal.
     *
     * The default makes an empty list expressible, which is the case that matters most here: it is
     * how "every folder was removed" arrives.
     */
    @Serializable
    @SerialName("folders")
    data class Folders(val folders: kotlin.collections.List<String> = emptyList()) : ServerMessage

    /* ---- capability `upload` --------------------------------------------------------------- */

    /**
     * The file is accepted, and this is where on the Mac it will be.
     *
     * Sent before a single slice is asked for, so the person can read the path while Cancel still
     * means something. That ordering is the difference between a feature and something that writes
     * to your disk and tells you afterwards.
     */
    @Serializable
    @SerialName("upload.ready")
    data class UploadReady(val id: String, val path: String) : ServerMessage

    /**
     * "I have written this many more bytes."
     *
     * From the Mac's own write callback, so it means its kernel has the bytes. This is what the
     * progress bar is drawn from and what re-arms the next read — see [Protocol.UPLOAD_WINDOW_BYTES].
     */
    @Serializable
    @SerialName("upload.ack")
    data class UploadAck(val id: String, val bytes: Int) : ServerMessage

    /**
     * It is on disk, complete, and the digest matched.
     *
     * `path` is repeated rather than remembered from `upload.ready`, because it can legitimately
     * differ: a second file of the same name lands beside the first rather than over it, and *this*
     * is the path the terminal types.
     */
    @Serializable
    @SerialName("upload.done")
    data class UploadDone(
        val id: String,
        val path: String,
        val bytes: Long,
        val sha256: String,
    ) : ServerMessage

    /**
     * There is no file, and `message` says why.
     *
     * One frame for a refusal, a failure mid-write and a cancel, because to this end they are one
     * event. Which of the three it was is in the sentence, not in a code.
     */
    @Serializable
    @SerialName("upload.failed")
    data class UploadFailed(
        val id: String,
        val message: String = "That file did not arrive.",
    ) : ServerMessage

    /* ---- capability `credential` ------------------------------------------------------------ */

    /**
     * Git on that machine needs a login for a repository, and this phone holds it.
     *
     * The only frame in this protocol the desktop sends unprompted as a *question*. Everything else
     * it sends is an answer or an event; this one is waiting on a reply, and the two ways to reply
     * are [ClientMessage.CredentialAnswer] and [ClientMessage.CredentialDeny] — with a
     * [ClientMessage.CredentialAck] first, always, so a live phone can be told from an absent one.
     *
     * [repo] is `owner/name`, or **null** when git gave the desktop no path to derive one from.
     * Null is not a detail to paper over: a prompt that cannot name the repository is a prompt
     * asking somebody to approve "a push, somewhere", and this client says exactly that rather than
     * inventing a name. It happens when the remote is not a two-segment path — a gist, a wiki, a
     * self-hosted layout.
     *
     * [prompt] is the instruction and [operation] is the fact, and they are two fields because they
     * answer two different questions. [operation] says what git is doing, always. [prompt] says
     * whether a person should be asked — false for every read, and false for a write against a
     * repository this device has already approved *on that machine*. **Whether to ask is the
     * desktop's answer, not this one's**: it is the side that knows what this device has approved
     * there, and a phone that second-guessed it would be a second source of truth with no way to
     * reconcile the two.
     *
     * [operation] defaults to [CredentialOperation.Write] rather than being required, and the
     * direction of that default is chosen rather than accidental. `coerceInputValues` folds a
     * missing or unrecognised value onto it, and the desktop's own classifier does the same thing
     * for the same reason: prompting for a fetch costs somebody one tap they did not need, and
     * *not* prompting for a push is the entire feature not working.
     */
    @Serializable
    @SerialName("credential.request")
    data class CredentialRequest(
        val id: String,
        /**
         * The git host — `github.com`, or an enterprise one.
         *
         * Called `host` on the wire and read as `origin` everywhere above this layer, because on
         * this side of the connection "host" already means *the machine this phone is paired with*
         * — and the two are on the same screen at the same time.
         */
        val host: String,
        val repo: String? = null,
        val operation: CredentialOperation = CredentialOperation.Write,
        val prompt: Boolean = false,
    ) : ServerMessage

    /* ---- capability `devices` ------------------------------------------------------------- */

    /** The answer to one `devices.list`, and only ever to one. [rid] is echoed. */
    @Serializable
    @SerialName("devices.rows")
    data class DevicesRows(
        val rid: String,
        val devices: kotlin.collections.List<DeviceRosterRow> = emptyList(),
    ) : ServerMessage

    /**
     * The answer to one `devices.revoke`.
     *
     * [ok] is false when the id named nothing or was already revoked; [message] is a sentence for
     * either outcome, written by the desktop; the fresh roster rides along so the screen redraws
     * without a second ask. Not sent when the phone revoked itself — that socket is already closing.
     */
    @Serializable
    @SerialName("devices.revoked")
    data class DevicesRevoked(
        val rid: String,
        val ok: Boolean = false,
        val message: String = "",
        val devices: kotlin.collections.List<DeviceRosterRow> = emptyList(),
    ) : ServerMessage

    /**
     * The roster moved — a device paired, was approved, or was revoked — pushed without being asked.
     *
     * Sent only to a connection that named [Capability.DEVICES] and whose device is one of the
     * owner's own, so a build that never claimed it never sees the frame.
     */
    @Serializable
    @SerialName("devices.changed")
    data class DevicesChanged(
        val devices: kotlin.collections.List<DeviceRosterRow> = emptyList(),
    ) : ServerMessage

    /* ---- capability `settings` ------------------------------------------------------------ */

    /** The answer to one `settings.read`. [settings] is the whole server-owned set. */
    @Serializable
    @SerialName("settings.state")
    data class SettingsState(
        val rid: String,
        val settings: kotlin.collections.List<ServerSettingWire> = emptyList(),
    ) : ServerMessage

    /**
     * What happened to one `settings.apply`, in the machine's own words.
     *
     * [ok] says whether the write took; [message] is the sentence to show either way — a refused
     * provider id comes back here with `ok=false` and the reason, never a silent swap. [setting] is
     * the row as it stands now, so the pane settles on the machine's truth rather than on what was
     * pressed, and a refused apply reverts by construction.
     */
    @Serializable
    @SerialName("settings.applied")
    data class SettingsApplied(
        val rid: String,
        val ok: Boolean = false,
        val message: String = "",
        val setting: ServerSettingWire,
    ) : ServerMessage

    /** A server-owned setting changed here — pushed, unsolicited, to every device that may hear it. */
    @Serializable
    @SerialName("settings.changed")
    data class SettingsChanged(
        val settings: kotlin.collections.List<ServerSettingWire> = emptyList(),
    ) : ServerMessage

    /* ---- capability `controls` ------------------------------------------------------------- */

    /**
     * The answer to one `controls.read`: the whole cluster, as the far machine read it this instant.
     *
     * [id] is echoed as well as [rid] and both are checked, because a reading is a claim about one
     * session and this screen may have moved to another between the ask and the answer.
     */
    @Serializable
    @SerialName("controls.reading")
    data class ControlsReading(
        val rid: String,
        val id: String,
        val reading: ControlsReadingWire = ControlsReadingWire(),
    ) : ServerMessage

    /**
     * What happened to one `controls.apply`, in the machine's own words.
     *
     * [message] is the sentence to show either way and is never composed on this side. [reading] is
     * the far end's **re-read** of the one control that was pressed, so the row that ticks is the
     * one the session is actually on: a refused apply reverts by construction rather than by this
     * phone remembering to undo something.
     */
    @Serializable
    @SerialName("controls.applied")
    data class ControlsApplied(
        val rid: String,
        val id: String,
        val ok: Boolean = false,
        val message: String = "",
        val reading: ControlReadingWire = ControlReadingWire.EMPTY,
    ) : ServerMessage

    /* ---- capability `watch` ---------------------------------------------------------------- */

    /**
     * One screencast frame of a browser window the machine is holding.
     *
     * Flat on the wire — `t` and the geometry in one object — so it is declared here rather than
     * wrapping a payload type. [data] is a base64 JPEG and the only large field, which is why this
     * is the single frame allowed past [Protocol.MAX_MESSAGE_BYTES]; see [ServerFrames.parse].
     * [w]/[h] are the image's own pixels and [dw]/[dh] the CSS viewport they cover.
     *
     * [masked] is the handover curtain: the pixels never crossed the wire, [data] is empty, and the
     * viewer draws its own lock card under [prompt]. A curtain takes no taps.
     *
     * [seq] is this frame's name. A gesture measured against it is sent with *this* number, and the
     * ack that asks for the next frame carries it too.
     */
    @Serializable
    @SerialName("browser.frame")
    data class BrowserFrame(
        val window: String,
        val seq: Int,
        val w: Int,
        val h: Int,
        val dw: Int = 0,
        val dh: Int = 0,
        val scale: Double = 1.0,
        val offsetTop: Double = 0.0,
        val pageScale: Double = 1.0,
        val scrollX: Double = 0.0,
        val scrollY: Double = 0.0,
        val masked: Boolean = false,
        val prompt: String? = null,
        val data: String = "",
    ) : ServerMessage {

        /** The curtain's sentence, bounded, or the default when the host sent none. */
        val curtain: String
            get() = prompt?.take(Protocol.MAX_WATCH_PROMPT_LENGTH)?.takeIf { it.isNotBlank() }
                ?: DEFAULT_CURTAIN_PROMPT

        /**
         * The decoded JPEG, or null.
         *
         * Null for a masked frame — there are no pixels — and null for a frame whose base64 will not
         * decode, which the painter treats as a frame it could not draw rather than as a reason to
         * stall: a bad frame is still acked, or one of them stops the whole cast.
         */
        fun bytes(): ByteArray? {
            if (masked || data.isEmpty()) return null
            return try {
                java.util.Base64.getDecoder().decode(data)
            } catch (e: IllegalArgumentException) {
                null
            }
        }
    }

    /**
     * The tab strip: every surface this machine says is watchable.
     *
     * Arrives as the answer to one `browser.surfaces` **and** unsolicited when the strip moves, so
     * [rid] is optional and is not matched — the list is the whole truth either way and there is
     * nothing to resolve.
     */
    @Serializable
    @SerialName("browser.surfaces.rows")
    data class BrowserSurfacesRows(
        val rid: String? = null,
        val surfaces: kotlin.collections.List<BrowserSurfaceWire> = emptyList(),
    ) : ServerMessage

    /* ---- capability `usage` ---------------------------------------------------------------- */

    /**
     * One usage figure, or the far end's sentence for why there is none.
     *
     * [want] is echoed because the three readings are not interchangeable and a client that folded
     * them would draw a context bar out of a plan report. [answer] holds the machine's **own**
     * record — see [UsageAnswerWire] — narrowed to figures by [UsageReadings] and never by the
     * serializer.
     */
    @Serializable
    @SerialName("usage.reading")
    data class UsageReading(
        val rid: String,
        val id: String,
        val want: UsageWant,
        val answer: UsageAnswerWire = UsageAnswerWire(),
    ) : ServerMessage

    /* ---- capability `account` -------------------------------------------------------------- */

    /**
     * Which login this session runs as, and every login the machine has.
     *
     * [current] is null when the machine could not say — which draws no chip rather than an empty
     * one. The list is bounded on arrival by [ServerFrames.parse] rather than trusted.
     */
    @Serializable
    @SerialName("account.state")
    data class AccountState(
        val rid: String,
        val id: String,
        val current: AccountWire? = null,
        val accounts: kotlin.collections.List<AccountWire> = emptyList(),
    ) : ServerMessage

    /**
     * What happened to one `account.switch`.
     *
     * [session] is the session the switch landed on, or null. Nothing is renamed on this side from
     * this frame: the chip is re-read, because the far end decides whether the switch took and a
     * chip that renamed itself on the press would be the one surface that disagrees with the
     * machine.
     */
    @Serializable
    @SerialName("account.switched")
    data class AccountSwitched(
        val rid: String,
        val id: String,
        val ok: Boolean = false,
        val message: String = "",
        val session: String? = null,
    ) : ServerMessage

    /* ---- capability `send` ----------------------------------------------------------------- */

    /**
     * Whether a whole message reached the session, and the machine's sentence if it did not.
     *
     * The reason `session.send` exists rather than `input`: a composer can keep its draft on a
     * refusal instead of losing it into a socket that said nothing.
     */
    @Serializable
    @SerialName("session.sent")
    data class SessionSent(
        val rid: String,
        val id: String,
        val ok: Boolean = false,
        val message: String = "",
    ) : ServerMessage

    /* ---- capability `web` ------------------------------------------------------------------ */

    /**
     * The page is open on the machine.
     *
     * Sent only when a tab was actually made, never on the request being received, so the sentence
     * this client draws is about something that happened. A refusal is an ordinary [Error].
     */
    @Serializable
    @SerialName("web.opened")
    data class WebOpened(val url: String) : ServerMessage

    /* ---- capability `localhost` ------------------------------------------------------------ */

    /** What is listening on the machine right now. The answer to one `ports`. */
    @Serializable
    @SerialName("ports")
    data class Ports(val ports: kotlin.collections.List<LocalPort> = emptyList()) : ServerMessage

    /**
     * The tunnel is up: bind a local socket and start opening streams inside it.
     *
     * [port] is echoed because a client may have more than one open and the id alone does not say
     * which page it is serving.
     */
    @Serializable
    @SerialName("tunnel.opened")
    data class TunnelOpened(val id: String, val port: Int) : ServerMessage

    /**
     * There is nothing behind that page any more, and [message] says why in the machine's words.
     *
     * The same frame answers a refusal, a teardown this client asked for and a Stop pressed at the
     * desk, because to this side they are one event. Which of the three it was is in the sentence,
     * not in a code — the only thing that differs is what gets printed.
     */
    @Serializable
    @SerialName("tunnel.closed")
    data class TunnelClosed(val id: String, val message: String = "") : ServerMessage

    /** Bytes for one stream, base64, checked into shape by [ServerFrames.parse]. */
    @Serializable
    @SerialName("net.data")
    data class NetData(val ch: String, val data: String) : ServerMessage

    /** "I have written this many bytes to my socket." The other half of [Protocol.NET_WINDOW_BYTES]. */
    @Serializable
    @SerialName("net.ack")
    data class NetAck(val ch: String, val bytes: Int = 0) : ServerMessage

    /** That stream is finished. The tunnel is not. */
    @Serializable
    @SerialName("net.close")
    data class NetClose(val ch: String) : ServerMessage

    /* ---- capability `devserver` ------------------------------------------------------------ */

    /**
     * One project's dev server, now.
     *
     * The single frame for the whole capability: it answers `dev.status`, it answers `dev.start`,
     * and it arrives **unsolicited** every time the state changes after a start. **Handle it
     * idempotently — the same state can arrive twice**, because a `dev.start` gets the state as its
     * direct answer *and* as a push. **Replace, do not merge**: the fields are not independent, so
     * folding a new state into an old one leaves a dead address under a live row.
     */
    @Serializable
    @SerialName("dev.state")
    data class DevState(val state: DevServerReport) : ServerMessage

    /* ---- capability `copilot` ---------------------------------------------------------------- */

    /** Answer to `copilot.state`, and pushed whenever any of it changes. */
    @Serializable
    @SerialName("copilot.state")
    data class CopilotStateFrame(val state: CopilotStateReport = CopilotStateReport()) : ServerMessage

    /**
     * The conversation, as **parsed messages** and never as terminal bytes.
     *
     * Merge by id: replace a match, append otherwise. [reset] means drop everything held and take
     * this frame as the whole conversation — which is what arrives on a fresh attach and when a run
     * is replaced.
     *
     * [run] rides along so a frame from a previous run is *dropped* rather than merged into the new
     * one. Without it a phone that reconnected after the grace window expired would splice the end of
     * a dead conversation onto the start of a live one, and the person would read an answer to a
     * question they never asked in this run.
     */
    @Serializable
    @SerialName("copilot.chat")
    data class CopilotChat(
        val run: String,
        val messages: kotlin.collections.List<CopilotChatMessage> = emptyList(),
        val reset: Boolean = false,
    ) : ServerMessage

    /**
     * One tool call as it happens, already scrubbed.
     *
     * This is the frame that makes a refusal visible: a call this device's grant did not cover
     * arrives here with `outcome: refused`, in the copilot's own words rather than as silence.
     */
    @Serializable
    @SerialName("copilot.tool")
    data class CopilotTool(val row: CopilotActionRow) : ServerMessage

    /** The sessions the copilot started. */
    @Serializable
    @SerialName("copilot.sessions")
    data class CopilotSessionsRows(
        val sessions: kotlin.collections.List<CopilotSessionRow> = emptyList(),
    ) : ServerMessage

    /**
     * Answer to `copilot.log` only, never pushed — the live view of the log is `copilot.tool`.
     *
     * [more] says the tail was bounded, in the same spirit the desktop's own trail reports its window
     * rather than pretending to be the whole file.
     */
    @Serializable
    @SerialName("copilot.log")
    data class CopilotLogRows(
        val rows: kotlin.collections.List<CopilotActionRow> = emptyList(),
        val more: Boolean = false,
    ) : ServerMessage

    /** Confirmations waiting anywhere. A row that is not this device's is news, not a decision. */
    @Serializable
    @SerialName("copilot.pending")
    data class CopilotPendingRows(
        val questions: kotlin.collections.List<CopilotPendingRow> = emptyList(),
    ) : ServerMessage

    /**
     * This connection's copilot state changed: opened, closed, regranted, or disconnected.
     *
     * Pushed, so a disconnected device's Copilot tab goes away without a reconnect. The *rule* is
     * already live without this frame, because the grant is read per message and per tool call —
     * which is exactly what makes this push honest rather than load bearing.
     */
    @Serializable
    @SerialName("copilot.grant")
    data class CopilotGrant(val link: CopilotLinkWire = CopilotLinkWire()) : ServerMessage

    /**
     * A confirmation **this connection may answer**. Pushed the moment it is raised.
     *
     * Only ever sent to the surface that owns the run that raised it. Everybody else who is watching
     * sees it as a `copilot.pending` row.
     */
    @Serializable
    @SerialName("copilot.ask")
    data class CopilotAsk(val question: CopilotConsentQuestion) : ServerMessage

    /**
     * A confirmation closed, and where it was answered.
     *
     * Pushed to every connection that was told about it, including the one that answered: a dialog
     * that vanishes without saying where the answer came from is the app doing something behind a
     * person's back.
     */
    @Serializable
    @SerialName("copilot.settled")
    data class CopilotSettled(val settled: CopilotSettledRow) : ServerMessage

    /* ---- capability `folders.pick` --------------------------------------------------------- */

    /**
     * One folder's sub-folders, in answer to a [ClientMessage.BrowseFolders].
     *
     * [path] is echoed by the machine rather than remembered here, because two asks can be in flight
     * after a fast double-tap and the second answer must not be drawn under the first heading. [parent]
     * is null at the very top, which is what the "up" row is drawn from — working it out on the phone
     * would mean a phone that knows where the root is on Windows.
     */
    @Serializable
    @SerialName("folders.entries")
    data class FolderEntries(
        val path: String,
        val parent: String? = null,
        val entries: kotlin.collections.List<FolderEntry> = emptyList(),
    ) : ServerMessage

    /* ---- capabilities `files`, `git`, `panels` --------------------------------------------- */
    // `files.rows` decodes to [FileListing], `files.text` to [FileText] and `panel.rows` to
    // [PanelData] — each is its own frame, declared beside its model in FilesGitWire.kt / PanelsWire.kt.

    /**
     * What git said about a folder — the answer to [ClientMessage.GitStatus].
     *
     * A folder that is **not a repository** is a true thing about that folder, not an error: [status]
     * is a [GitState] union, and both of its cases are drawn. [path] travels beside the answer because
     * one connection can have two of these in flight for different folders.
     */
    @Serializable
    @SerialName("git.state")
    data class GitStateFrame(val path: String, val status: GitState) : ServerMessage

    /**
     * One file's diff as git printed it — the answer to [ClientMessage.GitDiff].
     *
     * [patch] is empty when there was nothing to show, which is an **answer** rather than a failure:
     * `readFileDiff` returns `""` rather than throwing, so a tap on a vanished file cannot take the
     * panel down. All four fields travel because the staged and unstaged patches of one file are two
     * different answers and only one belongs on a given screen.
     */
    @Serializable
    @SerialName("git.patch")
    data class GitPatch(
        val path: String,
        val file: String,
        val staged: Boolean = false,
        val patch: String = "",
    ) : ServerMessage

    /* ---- capability `browser.control` ------------------------------------------------------ */
    // `browser.window.rows` decodes to [MachineBrowserState], `browser.shot` to [MachineShot] and
    // `browser.profile.rows` to [MachineProfileList] — declared beside their models in MachineBrowserWire.kt.

    /**
     * One element on a machine window's page — the answer to [ClientMessage.BrowserWindowPick].
     *
     * The wire is flat: the window [id] and the element's facts side by side. [element] groups those
     * facts into the [InspectedElement] a screen draws. Every *failure* comes back as a
     * [MachineBrowserState] with one sentence on it instead — nothing to point at, a page that has
     * scrolled — which is what stops a sheet spinning on a promise that will never be kept.
     */
    @Serializable
    @SerialName("browser.window.picked")
    data class BrowserWindowPicked(
        val id: String,
        val tag: String = "",
        val selector: String = "",
        val label: String = "",
        val labelSource: String = "",
        val url: String = "",
        val rect: PickedRect? = null,
        val depth: Int = 0,
        val maxUp: Int = 0,
    ) : ServerMessage {
        /** The element's facts as one value, for a screen that draws them together. */
        val element: InspectedElement
            get() = InspectedElement(tag, selector, label, labelSource, url, depth, maxUp, rect)
    }

    /** What the recorder collected on one window — the answer to [ClientMessage.BrowserWindowSteps]. */
    @Serializable
    @SerialName("browser.record.rows")
    data class BrowserRecordRows(
        val id: String,
        val steps: kotlin.collections.List<RecordedStep> = emptyList(),
    ) : ServerMessage

    /* ---- capability `copilot.files` -------------------------------------------------------- */

    /**
     * The copilot's files as they are on disk right now.
     *
     * An answer, never a push — sent for [ClientMessage.CopilotFilesList], and again after every write,
     * restore and delete, so a screen that changed something never has to guess what it produced. Read
     * off the disk on every call, because the interesting case is the one where somebody just edited a
     * file at the machine and wants to see it landed.
     */
    @Serializable
    @SerialName("copilot.files.rows")
    data class CopilotFilesRows(
        val files: kotlin.collections.List<CopilotFileRow> = emptyList(),
    ) : ServerMessage

    /**
     * One file's text, or the sentence saying why there is none.
     *
     * [id] is echoed back untouched, so a screen with two reads in flight tells them apart without
     * matching on order. [text] is always present and empty whenever [error] is set — one shape to
     * read, one spelling for *there is nothing*. [error] covers a file not written yet, one the host
     * could not read, and one too large for this wire; none quotes a path.
     */
    @Serializable
    @SerialName("copilot.file.text")
    data class CopilotFileText(
        val id: String,
        val text: String = "",
        val error: String? = null,
    ) : ServerMessage

    /* ---- capability `routines` ------------------------------------------------------------- */
    // `routine.text.rows` decodes to [RoutineFile], declared beside its model in RoutinesWire.kt.

    /**
     * Every routine on that machine, and one line about what just happened.
     *
     * The answer to [ClientMessage.Routines] **and** to each of run, pause, resume and delete — the
     * redraw is the confirmation and [notice] says what the press did, carrying the engine's own
     * sentence when a run refused to start, so *"it did not start"* and *"it did not start because the
     * hourly budget is spent until 14:20"* are not the same answer.
     */
    @Serializable
    @SerialName("routines.rows")
    data class RoutinesRows(
        val routines: kotlin.collections.List<RoutineRow> = emptyList(),
        val notice: String? = null,
    ) : ServerMessage
}

/**
 * What git was doing when it asked for a login.
 *
 * Transcribed from `CREDENTIAL_OPERATIONS`. Two values because there are exactly two answers a
 * person cares about, and the difference between them is the whole of the prompting policy: a fetch
 * or a clone is a **read**, is reversible, and asking about one buys nothing but fatigue; a push is
 * a **write**, is not reversible, and is the moment somebody should get to see whose name goes on
 * the commit.
 *
 * It arrives as a fact, not as an instruction. What this client is asked to *do* is the separate
 * `prompt` flag on the same frame.
 */
@Serializable
enum class CredentialOperation {
    @SerialName("read")
    Read,

    @SerialName("write")
    Write,
}

/**
 * Why this phone would not answer, as a code rather than a sentence.
 *
 * Transcribed from `CREDENTIAL_DENIALS`. See [ClientMessage.CredentialDeny] for why this direction
 * carries a code where `tunnel.closed` carries prose.
 *
 * [NoAccount] is **not a refusal**. It means no GitHub is connected in this app yet, which is a
 * different thing to be told and has a different fix — and the desktop's wording for it points at
 * this phone rather than at the person who pushed.
 */
@Serializable
enum class CredentialDenial {
    @SerialName("denied")
    Denied,

    @SerialName("no-account")
    NoAccount,
}

@Serializable
enum class ProtocolErrorCode {
    @SerialName("bad-message")
    BadMessage,

    @SerialName("unauthenticated")
    Unauthenticated,

    @SerialName("unauthorized")
    Unauthorized,

    @SerialName("unknown-session")
    UnknownSession,

    @SerialName("too-large")
    TooLarge,

    /**
     * The Mac understood, would have been allowed to do it, and could not.
     *
     * A folder deleted since it was listed, a shell that will not spawn. Worth trying again, which
     * is why it is not [Unauthorized]: telling someone "not allowed" when the truth is "it broke"
     * sends them to the pairing screen to fix a missing directory.
     */
    @SerialName("unavailable")
    Unavailable,

    @SerialName("version")
    Version,

    /**
     * Not on the wire.
     *
     * The desktop's union is closed, but a phone that refuses to parse an `error` frame carrying a
     * code it has not heard of turns a future desktop's polite refusal into an unexplained
     * disconnect. `unknownDefault` maps anything unrecognised here instead.
     */
    @SerialName("unknown")
    Unknown,
    ;

    val isFatal: Boolean
        get() = this == Unauthenticated || this == Unauthorized || this == Version
}
