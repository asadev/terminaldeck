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
