package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.ServerSettingKey
import dev.terminaldeck.android.protocol.ServerSettingWire

/** A one-line outcome to show under a request cluster: the machine's own words, and whether it took. */
data class ActionNotice(val ok: Boolean, val text: String)

/**
 * The "This server" section of the phone's Settings, for one machine.
 *
 * Transcribed from `pwa/src/server-settings.ts`, whose header is the design in full. Two settings
 * this machine owns rather than this phone — the coding tool a fresh session starts with, and
 * whether the last layout is restored at launch — reached over the [Capability.SETTINGS] the desktop
 * advertises. Changing one here changes the *server*: the same on every device that reaches it.
 *
 * ## Honest states, the rules the control cluster follows
 *
 * Nothing is drawn until a `settings.state` answers, and nothing at all over a machine whose welcome
 * did not name `settings` — so an older desktop or a guest gets a Settings screen exactly as it was,
 * not a section explaining what it is missing. While an apply is in flight both controls lock and the
 * pressed one reads "Working…". The value shown is always the machine's own re-read from
 * `settings.applied`, never the pressed value, so a refused apply reverts by construction; a refusal
 * keeps the server's own sentence until the next action, a confirmation clears itself, and an apply
 * nobody answered times out into a fresh read.
 *
 * One per [HostLink]. [receive] returns true when a frame was one of this section's, so the view
 * model routes only what belongs here.
 */
class ServerSettingsController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    /** Bumped whenever what is on screen changes, so the view model refolds its state. */
    private val onChange: () -> Unit,
) {
    private var rows: List<ServerSettingWire>? = null

    /** Sent a read on this connection already — reset by [renew] on each welcome. */
    private var requested = false
    private var busy: ServerSettingKey? = null
    private var notice: ActionNotice? = null

    private class Pending(val kind: Kind, val key: ServerSettingKey?, val cancel: () -> Unit) {
        enum class Kind { READ, APPLY }
    }

    private val pending = HashMap<String, Pending>()
    private var confirmCancel: (() -> Unit)? = null
    private var counter = 0

    /** A snapshot the composable draws from. Null rows means "not read yet". */
    fun view(): ServerSettingsView? {
        if (!offered()) return null
        return ServerSettingsView(rows = rows, busy = busy, notice = notice)
    }

    fun offered(): Boolean = capabilities().contains(Capability.SETTINGS)

    private fun rid(): String {
        counter += 1
        return "set-$counter"
    }

    /**
     * Ask for the settings once, when the screen that shows them is opened. A no-op over a machine
     * that does not serve them, and a no-op after the first ask on a connection — the
     * `settings.changed` push keeps the rows fresh without a poll.
     */
    fun ensureRead() {
        if (!offered() || requested || rows != null) return
        ask()
    }

    /**
     * A new welcome: forget what the last machine said and re-read on the next visit. Called for
     * every welcome, because the machine on the other end can change — a re-pair, a switch.
     */
    fun renew() {
        pending.values.forEach { it.cancel() }
        pending.clear()
        confirmCancel?.invoke()
        confirmCancel = null
        rows = null
        requested = false
        busy = null
        notice = null
        onChange()
    }

    private fun ask() {
        if (!offered()) return
        val key = rid()
        if (!send(ClientMessage.SettingsRead(key))) return
        requested = true
        val cancel = expiry.after(READ_TIMEOUT_MS) {
            pending.remove(key)
            // A read that never answered is not an error to show — the screen stays as it was, and
            // the next visit tries again.
            requested = false
        }
        pending[key] = Pending(Pending.Kind.READ, null, cancel)
    }

    fun apply(key: ServerSettingKey, value: String) {
        if (busy != null) return
        val requestId = rid()
        if (!send(ClientMessage.SettingsApply(requestId, key, value))) return
        busy = key
        notice = null
        val cancel = expiry.after(APPLY_TIMEOUT_MS) {
            pending.remove(requestId)
            if (busy != key) return@after
            busy = null
            say(ActionNotice(false, "The server did not answer; nothing was changed."))
            requested = false
            ask()
            onChange()
        }
        pending[requestId] = Pending(Pending.Kind.APPLY, key, cancel)
        onChange()
    }

    private fun settle(requestId: String, asked: Pending) {
        asked.cancel()
        pending.remove(requestId)
    }

    private fun say(next: ActionNotice) {
        notice = next
        confirmCancel?.invoke()
        confirmCancel = null
        // A confirmation clears itself; a refusal stays until the next action.
        if (next.ok) {
            confirmCancel = expiry.after(CONFIRM_MS) {
                confirmCancel = null
                notice = null
                onChange()
            }
        }
    }

    private fun absorb(next: List<ServerSettingWire>) {
        rows = ServerSettingWire.merge(rows, next)
    }

    /** Frames this section asked for, or the unsolicited change push. True when handled. */
    fun receive(message: ServerMessage): Boolean {
        when (message) {
            is ServerMessage.SettingsState -> {
                val asked = pending[message.rid] ?: return false
                if (asked.kind != Pending.Kind.READ) return false
                settle(message.rid, asked)
                // Through merge so a setting this build does not know is dropped rather than drawn,
                // and the two it does keep their canonical order — the additive rule, applied to a
                // fresh state as much as to a push.
                rows = ServerSettingWire.merge(null, message.settings)
                onChange()
                return true
            }
            is ServerMessage.SettingsApplied -> {
                val asked = pending[message.rid] ?: return false
                if (asked.kind != Pending.Kind.APPLY) return false
                settle(message.rid, asked)
                busy = null
                // The server's own sentence, verbatim — never one composed here.
                say(ActionNotice(message.ok, message.message))
                // Settle on the machine's own re-read, whether the apply took or was refused, so a
                // refusal reverts the control by construction.
                absorb(listOf(message.setting))
                onChange()
                return true
            }
            is ServerMessage.SettingsChanged -> {
                absorb(message.settings)
                onChange()
                return true
            }
            else -> return false
        }
    }

    fun stop() {
        pending.values.forEach { it.cancel() }
        pending.clear()
        confirmCancel?.invoke()
        confirmCancel = null
    }

    companion object {
        const val READ_TIMEOUT_MS = 20_000L
        const val APPLY_TIMEOUT_MS = 60_000L
        private const val CONFIRM_MS = 4_000L
    }
}

/** What the Settings composable reads. [rows] null means "reading…"; empty means the machine sent none. */
data class ServerSettingsView(
    val rows: List<ServerSettingWire>?,
    val busy: ServerSettingKey?,
    val notice: ActionNotice?,
)
