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
