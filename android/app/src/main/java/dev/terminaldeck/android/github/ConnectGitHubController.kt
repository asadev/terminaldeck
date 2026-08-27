package dev.terminaldeck.android.github

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.GitHubHostWire
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * Connect GitHub on the **machine**, driven from the phone.
 *
 * This is the flip of the old credential proxy. The phone used to hold a GitHub token and answer
 * every machine's git logins; now the machine that holds the repository holds its own login, and this
 * phone only triggers a sign-in, shows the code, and reports the result. Nothing here ever holds a
 * token — the wire that reaches it carries a login name, a URL and a short code, and nothing that
 * grants a push.
 *
 * ## The shape, mirrored from [dev.terminaldeck.android.ServerSettingsController]
 *
 * One per [dev.terminaldeck.android.HostLink], reached over the [Capability.GITHUB] the host
 * advertises. It reads its live capability set through a lambda rather than a snapshot, so a
 * controller created before the welcome draws nothing until the welcome names `github`. Each request
 * carries a client-minted `rid`; [receive] returns true when a frame was one of this section's, so
 * the view model routes only what belongs here. A timer per request means a machine that never
 * answers a connect turns back into a Connect button rather than a spinner that hangs.
 *
 * ## The connect flow, in the frames it sends and hears
 *
 *  1. `github.connect` → the host runs GitHub's device flow and answers `github.state` whose
 *     `github.pending` carries the code and the URL. The section shows "Open <uri>, enter <code>".
 *  2. The person authorizes it in a browser → the host pushes `github.changed` with `connected:true`,
 *     unsolicited. The section becomes "Connected as @login".
 *  3. `github.cancel` drops a sign-in in flight; `github.disconnect` signs the machine out.
 *
 * When `appConfigured` is false the host has no OAuth app to sign in with, so [ConnectGitHubView]
 * carries the failure and the section draws no Connect button — a control that could only ever fail
 * is worse than none.
 */
class ConnectGitHubController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    /** Bumped whenever what is on screen changes, so the view model refolds its state. */
    private val onChange: () -> Unit,
) {
    /** The host's GitHub as last read or pushed. Null means "not read yet". */
    private var host: GitHubHostWire? = null

    /** Sent a read on this connection already — reset by [renew] on each welcome. */
    private var requested = false

    /** A connect/cancel/disconnect is in flight and its answer has not landed. */
    private var busy = false

    /** A request that never got an answer, said as a local sentence rather than left as a spinner. */
    private var localFailure: String? = null

    /** rid → cancel-its-timer, so a landed answer disarms exactly the request it answers. */
    private val pending = HashMap<String, () -> Unit>()
    private var counter = 0

    /** True when the machine on screen advertised that it owns a GitHub login. */
    fun offered(): Boolean = capabilities().contains(Capability.GITHUB)

    /** A snapshot the composable draws from. Null over a machine that does not offer `github`. */
    fun view(): ConnectGitHubView? {
        if (!offered()) return null
        return ConnectGitHubView(host = host, busy = busy, localFailure = localFailure)
    }

    private fun rid(): String {
        counter += 1
        return "gh-$counter"
    }

    /**
     * Ask for the host's GitHub status once, when the screen that shows it opens. A no-op over a
     * machine that does not serve it, and a no-op after the first ask on a connection — the
     * `github.changed` push keeps it fresh without a poll.
     */
    fun ensureRead() {
        if (!offered() || requested || host != null) return
        read()
    }

    /**
     * A new welcome: forget what the last machine said and re-read on the next visit. Called for
     * every welcome, because the machine on the other end can change — a re-pair, a switch.
     */
    fun renew() {
        pending.values.forEach { it() }
        pending.clear()
        host = null
        requested = false
        busy = false
        localFailure = null
        onChange()
    }

    private fun read() {
        if (!offered()) return
        val key = rid()
        if (!send(ClientMessage.GithubRead(key))) return
        requested = true
        // A read that never answered is not an error to show — the screen stays as it was, and the
        // next visit tries again.
        arm(key) { requested = false }
    }

    /** Start a device-flow sign-in on the machine. The code arrives on the `github.state` that answers. */
    fun connect() {
        if (!offered() || busy) return
        val key = rid()
        if (!send(ClientMessage.GithubConnect(key))) return
        busy = true
        localFailure = null
        arm(key) {
            busy = false
            localFailure = "The machine did not answer. Try again."
            onChange()
        }
        onChange()
    }

    /** Cancel a sign-in the machine has in flight. */
    fun cancel() {
        if (!offered()) return
        val key = rid()
        if (!send(ClientMessage.GithubCancel(key))) return
        busy = true
        arm(key) {
            busy = false
            onChange()
        }
        onChange()
    }

    /** Sign the machine out of GitHub. */
    fun disconnect() {
        if (!offered() || busy) return
        val key = rid()
        if (!send(ClientMessage.GithubDisconnect(key))) return
        busy = true
        localFailure = null
        arm(key) {
            busy = false
            onChange()
        }
        onChange()
    }

    private fun arm(rid: String, onTimeout: () -> Unit) {
        val cancel = expiry.after(TIMEOUT_MS) {
            pending.remove(rid)
            onTimeout()
        }
        pending[rid] = cancel
    }

    /** Frames this section asked for, or the unsolicited change push. True when handled. */
    fun receive(message: ServerMessage): Boolean {
        return when (message) {
            is ServerMessage.GithubState -> {
                // Match by rid so a reply that raced a screen this device has left is dropped rather
                // than acted on. An unknown rid is not this section's to claim.
                val cancel = pending.remove(message.rid) ?: return false
                cancel()
                host = message.github
                requested = true
                busy = false
                localFailure = null
                onChange()
                true
            }
            is ServerMessage.GithubChanged -> {
                // Unsolicited — the sign-in completed, or the login moved on another device. It
                // carries no rid, so it is always this section's and always the newest truth.
                host = message.github
                busy = false
                localFailure = null
                onChange()
                true
            }
            else -> false
        }
    }

    fun stop() {
        pending.values.forEach { it() }
        pending.clear()
    }

    companion object {
        /**
         * How long a request waits for its answer.
         *
         * Long, on purpose: a `github.connect` runs an OAuth round trip on a machine that may be a
         * continent away over a relay, and the person then has to open a browser and type a code.
         * This only bounds the *request/answer*, not the sign-in — the code's own expiry, carried on
         * [GitHubHostWire], governs how long there is to type it.
         */
        const val TIMEOUT_MS = 90_000L
    }
}

/**
 * What the Connect-GitHub section draws.
 *
 * [host] null means "reading…"; otherwise it is the machine's own status — connected, a sign-in in
 * flight ([GitHubHostWire.pending]), or a failure. [busy] locks the buttons while a request is in
 * flight. [localFailure] is a sentence this phone wrote because a request went unanswered, kept
 * separate from [GitHubHostWire.failure], which is the machine's own words.
 */
data class ConnectGitHubView(
    val host: GitHubHostWire?,
    val busy: Boolean,
    val localFailure: String?,
)
