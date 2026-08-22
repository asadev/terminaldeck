package dev.terminaldeck.android.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * What is listening on the machine, and what one project's dev server is doing.
 *
 * Transcriptions of `LocalPort`, `DEV_SERVER_STATUSES` and `DevServerReport` from
 * `src/main/remote/protocol.ts`. Both are declared there rather than imported from the desktop's own
 * types for the same reason they are declared here: the shape a phone is sent is a contract with
 * three clients in three languages, and a field added to the desktop's own type must not reach the
 * wire by accident.
 */

/** One listening socket on the machine. [guessed] means the desktop inferred the process name. */
@Serializable
data class LocalPort(
    val port: Int,
    val process: String = "",
    val guessed: Boolean = false,
)

/**
 * The five things one project's dev server can be, as one word.
 *
 * They are five and not three because a client has to be able to draw five different things, and two
 * of the pairs are the ones that get collapsed:
 *
 *  - [NoDevScript] is **not** [Idle]. [Idle] means "press this"; this means "there is nothing to
 *    press, and there never will be for this folder, because its `package.json` declares no `dev`,
 *    `start` or `serve`". A client that flattens them draws a button whose only possible outcome is
 *    a refusal.
 *  - [Failed] is **not** [Idle] either. The session that failed is still there with the reason
 *    printed in it, and the useful thing to offer is that session — not a fresh Start button drawn
 *    as though nothing had happened.
 *
 * [Unknown] is not on the wire. It is where `coerceInputValues` folds a status a newer desktop grew,
 * for the reason [ProtocolErrorCode.Unknown] exists: a client that refuses to parse a `dev.state`
 * carrying a sixth word would turn a future desktop's honest answer into a dropped frame.
 */
@Serializable
enum class DevServerStatus {
    @SerialName("no-dev-script")
    NoDevScript,

    @SerialName("idle")
    Idle,

    @SerialName("starting")
    Starting,

    @SerialName("ready")
    Ready,

    @SerialName("failed")
    Failed,

    @SerialName("unknown")
    Unknown,
}

/**
 * One project's dev server, as a client sees it.
 *
 * Which fields are set for which status:
 *
 * | status          | script/command | sessionId | port/url | note | message |
 * |-----------------|----------------|-----------|----------|------|---------|
 * | `no-dev-script` | –              | –         | –        | –    | –       |
 * | `idle`          | ✓              | –         | –        | –    | –       |
 * | `starting`      | ✓              | ✓         | –        | maybe| –       |
 * | `ready`         | ✓              | ✓         | ✓        | –    | –       |
 * | `failed`        | ✓              | maybe     | –        | –    | ✓       |
 *
 * A client must still read defensively — this arrives as JSON — but it may rely on the one rule the
 * desktop enforces and tests: **`port` and `url` appear only on `ready`, and `ready` is only ever
 * sent after something accepted a TCP connection on that port.**
 *
 * **Replace, do not merge.** The fields are not independent — [port] and [url] exist only on
 * [DevServerStatus.Ready], [message] only on [DevServerStatus.Failed] — so folding a new state into
 * an old one leaves a dead address under a live row. That is the one genuinely wrong thing a client
 * of this frame can display, and it is why [DevServerReport] is stored keyed by [folder] and
 * assigned whole.
 */
@Serializable
data class DevServerReport(
    /** The project folder, exactly as the desktop offered it in `welcome.folders`. */
    val folder: String,
    val status: DevServerStatus = DevServerStatus.Unknown,
    /** The `package.json` script that runs it, e.g. `dev`. */
    val script: String? = null,
    /** The command line that will be typed, e.g. `pnpm run dev`. Display it. */
    val command: String? = null,
    /**
     * The session it is running in — a real session in `sessions`, which the client can attach to,
     * read and kill exactly like any other. This is how a failure is investigated and how a dev
     * server is stopped; there is no separate stop verb, because there is no separate kind of
     * process.
     */
    val sessionId: String? = null,
    /** Proven reachable. See the rule above. */
    val port: Int? = null,
    /** `http://localhost:<port>`, ready to open on the machine through `web.open`. */
    val url: String? = null,
    /**
     * The server's own latest output line, while starting.
     *
     * Untrusted display text and the only field here that is: it is bytes a process on the desktop
     * printed. Drawn as text, never as markup, and never parsed — the desktop has already done the
     * only parsing anyone should do with it.
     */
    val note: String? = null,
    /** Why it failed, in a sentence written by the desktop. */
    val message: String? = null,
) {
    /** There is a script to press. [DevServerStatus.NoDevScript] is the state with no button. */
    val canStart: Boolean
        get() = status == DevServerStatus.Idle || status == DevServerStatus.Failed

    /** Something is on its way up, or is up. Neither offers Start. */
    val isBusy: Boolean
        get() = status == DevServerStatus.Starting

    /** The address to open on the machine, present only on a proven-reachable server. */
    val openable: String?
        get() = if (status == DevServerStatus.Ready) url?.takeIf { it.isNotEmpty() } else null
}
