package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.DevServerReport
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * One project's dev server, per granted folder.
 *
 * The client half of [Capability.DEVSERVER]. `dev.status` asks what a folder's dev server is doing,
 * `dev.start` starts it, and `dev.state` answers both **and arrives unsolicited** every time the
 * state changes after a start — a new progress line, the moment a port accepts, a timeout. So there
 * is no timer here and no "are we there yet" verb: send, draw whatever comes back, and keep drawing
 * whatever arrives next.
 *
 * ## The two rules of `dev.state`, which are the whole of this class
 *
 *  - **Idempotent.** The same state can arrive twice, because a `dev.start` gets the state as its
 *    direct answer *and* as a push. Rows are therefore keyed by folder and assigned, so the
 *    duplicate costs nothing.
 *  - **Replace, do not merge.** The fields are not independent — `port` and `url` exist only on
 *    `ready`, `message` only on `failed` — so folding a new state into an old one leaves a dead
 *    address under a live row. That is the one genuinely wrong thing a client of this frame can
 *    display.
 *
 * A refusal — a folder this device was not granted — comes back as a plain `error`, never as a
 * `dev.state`, because there is no folder state to report about a folder the desktop will not
 * discuss. Which is why the only folders this asks about are ones the machine itself put in
 * `welcome.folders`.
 *
 * One per [HostLink]. [receive] returns true when a frame was one of this section's.
 */
class DevServerController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    private val onChange: () -> Unit,
) {
    /** One report per folder, keyed by the folder exactly as the machine spelled it. */
    private val rows = LinkedHashMap<String, DevServerReport>()

    /** Folders a status has been asked for on this connection, so a revisit does not re-ask. */
    private val asked = HashSet<String>()

    /** The folder whose Start is in flight, so its button locks and a second press cannot fire. */
    private var starting: String? = null

    private var startCancel: (() -> Unit)? = null

    fun offered(): Boolean = capabilities().contains(Capability.DEVSERVER)

    fun view(): DevServerView? {
        if (!offered()) return null
        return DevServerView(rows = rows.toMap(), starting = starting)
    }

    /**
     * Ask about the folders this machine has granted, once per connection.
     *
     * Only folders the machine itself offered: a folder named from anywhere else is one the desktop
     * refuses, and asking would spend a frame to be told off. Called by the screen that draws the
     * rows rather than on every welcome, because a status read touches a `package.json` on somebody
     * else's disk and there is no reason to do it for a screen nobody opened.
     */
    fun ensureRead(folders: List<String>) {
        if (!offered()) return
        for (folder in folders) {
            if (folder.isEmpty() || !asked.add(folder)) continue
            if (!send(ClientMessage.DevStatus(folder))) {
                asked.remove(folder)
                return
            }
        }
    }

    /**
     * Start the dev server for one folder.
     *
     * **This message is the consent, and there is no standing one.** Nothing runs on the desktop
     * because of this feature until it arrives, and it only arrives because a person tapped a row
     * for a folder their desktop has granted them.
     */
    fun start(folder: String) {
        if (!offered() || starting != null || folder.isEmpty()) return
        if (!send(ClientMessage.DevStart(folder))) return
        starting = folder
        startCancel?.invoke()
        startCancel = expiry.after(START_TIMEOUT_MS) {
            startCancel = null
            // The button unlocks; the row keeps whatever state last arrived. A `dev.start` is
            // answered immediately with `starting`, so a silence here is a machine that has gone
            // rather than a server that is slow — and a server that *is* slow keeps pushing.
            if (starting == folder) {
                starting = null
                onChange()
            }
        }
        onChange()
    }

    fun renew() {
        stop()
        rows.clear()
        asked.clear()
        starting = null
        onChange()
    }

    fun receive(message: ServerMessage): Boolean {
        if (message !is ServerMessage.DevState) return false
        val report = message.state
        if (report.folder.isEmpty()) return true
        // Assigned whole, never folded into what was there. See the class header.
        rows[report.folder] = report
        asked.add(report.folder)
        if (starting == report.folder && !report.isBusy) {
            startCancel?.invoke()
            startCancel = null
            starting = null
        }
        onChange()
        return true
    }

    fun stop() {
        startCancel?.invoke()
        startCancel = null
    }

    companion object {
        const val START_TIMEOUT_MS = 30_000L
    }
}

/** What the dev-server section reads: one row per folder a status has arrived for. */
data class DevServerView(
    val rows: Map<String, DevServerReport>,
    val starting: String?,
)
