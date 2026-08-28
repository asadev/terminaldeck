package dev.terminaldeck.android.hostcontrol

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.HostControlWire
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * Drive this machine's own host — status, restart, stop — from the phone, **over the relay**.
 *
 * ## "The relay is the network." — Asad's rule, pinned
 *
 * A server page reaches one box by two roads: an SSH address it was added with, and the relay it is
 * paired over. Asad's SSH address is a Tailscale name (`imza-pc-wsl`) that drops on its own — and
 * when it does, the SSH survey on the server page reports the box as unreachable while every session
 * on it is still running over the public relay. His rule is that the relay *is* the network, so this
 * controller reaches the box the other way: when the server is a connected machine, its status and
 * its restart/stop go over the relay, independent of the SSH address.
 *
 * ## The shape, mirrored from [dev.terminaldeck.android.github.ConnectGitHubController]
 *
 * One per [dev.terminaldeck.android.HostLink], reached over the [Capability.HOST_CONTROL] the host
 * advertises. It reads its live capability set through a lambda, so a controller created before the
 * welcome draws nothing until the welcome names `host.control`. Each request carries a client-minted
 * `rid`; [receive] returns true when a frame was one of this section's.
 *
 * ## Why restart and stop drop the connection, and there is no push
 *
 * A restart or a stop tears down the very connection the answer travels on. So the host answers
 * `host.state` with a note **first** and acts after — this controller shows that note, and then the
 * connection goes and (for a restart) comes back as a fresh welcome, which [renew] resets. A verb
 * that never got its answer is the ordinary case, not a failure: the host may have dropped the
 * socket *as* it acted, so [localFailure] says "no word came back" rather than "it failed". There is
 * no `host.start` on this wire — a stopped host is not connected over the relay.
 */
class HostControlController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    /** Bumped whenever what is on screen changes, so the view model refolds its state. */
    private val onChange: () -> Unit,
) {
    /** The host as last read, or the answer to a restart/stop. Null means "not read yet". */
    private var host: HostControlWire? = null

    /** Sent a read on this connection already — reset by [renew] on each welcome. */
    private var requested = false

    /** A restart or stop is in flight and its answer has not landed. */
    private var busy = false

    /** A verb whose answer never came, said as a local sentence rather than left as a spinner. */
    private var localFailure: String? = null

    /** rid → cancel-its-timer, so a landed answer disarms exactly the request it answers. */
    private val pending = HashMap<String, () -> Unit>()
    private var counter = 0

    /** True when the machine on screen advertised that it manages its own host from here. */
    fun offered(): Boolean = capabilities().contains(Capability.HOST_CONTROL)

    /** A snapshot the composable draws from. Null over a machine that does not offer `host.control`. */
    fun view(): HostControlView? {
        if (!offered()) return null
        return HostControlView(host = host, busy = busy, localFailure = localFailure)
    }

    private fun rid(): String {
        counter += 1
        return "hc-$counter"
    }

    /**
     * Ask for the host's status once, when the screen opens. A no-op over a machine that does not
     * serve it, and after the first ask on a connection — nothing polls, so the status is read once
     * and re-read on the next welcome, a [refresh], or a verb.
     */
    fun ensureRead() {
        if (!offered() || requested || host != null) return
        read()
    }

    /**
     * A new welcome: forget what the last machine said and re-read on the next visit. Called for
     * every welcome — the machine can change, and a machine that just restarted comes back here.
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
        if (!send(ClientMessage.HostStatus(key))) return
        requested = true
        // A read that never answered is not an error to show — the screen stays as it was.
        arm(key) { requested = false }
    }

    /** Read the host's status again on demand — the pull-to-refresh path. */
    fun refresh() {
        if (!offered() || busy) return
        read()
    }

    /** Restart the host on this machine, over the relay. */
    fun restartHost() {
        if (!offered() || busy) return
        val key = rid()
        if (!send(ClientMessage.HostRestart(key))) return
        busy = true
        localFailure = null
        arm(key) {
            busy = false
            localFailure = NO_WORD_BACK
            onChange()
        }
        onChange()
    }

    /** Stop the host on this machine, over the relay. */
    fun stopHost() {
        if (!offered() || busy) return
        val key = rid()
        if (!send(ClientMessage.HostStop(key))) return
        busy = true
        localFailure = null
        arm(key) {
            busy = false
            localFailure = NO_WORD_BACK
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

    /** Frames this section asked for. True when handled. */
    fun receive(message: ServerMessage): Boolean {
        return when (message) {
            is ServerMessage.HostState -> {
                // Match by rid so a reply that raced a screen this device has left is dropped rather
                // than acted on. An unknown rid is not this section's to claim.
                val cancel = pending.remove(message.rid) ?: return false
                cancel()
                host = message.host
                requested = true
                busy = false
                localFailure = null
                onChange()
                true
            }
            else -> false
        }
    }

    /** Teardown — called when the link goes away, the same name [ConnectGitHubController.stop] uses. */
    fun stop() {
        pending.values.forEach { it() }
        pending.clear()
    }

    companion object {
        /**
         * How long a request waits for its answer. Long, on purpose: a restart shells out to systemd
         * on a machine that may be a continent away over a relay, and the answer races the drop it is
         * about to cause.
         */
        const val TIMEOUT_MS = 30_000L

        private const val NO_WORD_BACK =
            "No word came back before the connection dropped — the host may be on its way back up. Pull down to look again."
    }
}

/**
 * What the "host over the relay" section draws.
 *
 * [host] null means "reaching…"; otherwise it is the machine's own status. [busy] locks the buttons
 * while a restart/stop is in flight. [localFailure] is a sentence this phone wrote because a verb
 * went unanswered — which over the relay usually means the host dropped the socket as it acted, not
 * that it failed.
 */
data class HostControlView(
    val host: HostControlWire?,
    val busy: Boolean,
    val localFailure: String?,
)
