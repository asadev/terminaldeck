package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.DeviceRosterRow
import dev.terminaldeck.android.protocol.ServerMessage

/**
 * The device roster of one machine, and the one verb that removes a row.
 *
 * Transcribed from the same request/response shape [ServerSettingsController] follows, against the
 * frames `src/main/remote/protocol.ts` defines for [Capability.DEVICES]. The desktop lists every
 * device signed in there; this asks for that list (`devices.list`), removes one (`devices.revoke`,
 * which doubles as deny for a pending row — there is no approve on the wire), and absorbs the
 * unsolicited `devices.changed` push when the roster moves.
 *
 * The capability is withheld from a guest at the source, so a phone that sees it is entitled to
 * manage the roster; there is no second check here. The section draws nothing over a machine whose
 * welcome did not name it.
 *
 * One per [HostLink]. [receive] returns true when a frame was one of this section's.
 */
class DeviceRosterController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    private val onChange: () -> Unit,
) {
    private var rows: List<DeviceRosterRow>? = null
    private var requested = false

    /** The id of the row being revoked, so its button reads "Removing…" and a second press cannot fire. */
    private var busy: String? = null
    private var notice: ActionNotice? = null

    /**
     * This phone's own device id on this machine, from `welcome.deviceId`.
     *
     * So the roster can mark which row is the device in your hand, and warn that removing it is a
     * sign-out of *this* phone rather than of some other device.
     */
    private var myDeviceId: String? = null

    private class Pending(val kind: Kind, val device: String?, val cancel: () -> Unit) {
        enum class Kind { LIST, REVOKE }
    }

    private val pending = HashMap<String, Pending>()
    private var confirmCancel: (() -> Unit)? = null
    private var counter = 0

    fun offered(): Boolean = capabilities().contains(Capability.DEVICES)

    fun view(): DeviceRosterView? {
        if (!offered()) return null
        return DeviceRosterView(rows = rows, busy = busy, notice = notice, myDeviceId = myDeviceId)
    }

    /** Learn this phone's device id from the welcome, so its own row can be named. */
    fun onWelcome(deviceId: String) {
        myDeviceId = deviceId
    }

    private fun rid(): String {
        counter += 1
        return "dev-$counter"
    }

    /** Ask once when the screen opens; the `devices.changed` push keeps it fresh after. */
    fun ensureRead() {
        if (!offered() || requested || rows != null) return
        ask()
    }

    /** The user pulled to refresh: ask again even if a list has already arrived. */
    fun refresh() {
        if (!offered()) return
        ask()
    }

    fun renew() {
        pending.values.forEach { it.cancel() }
        pending.clear()
        confirmCancel?.invoke()
        confirmCancel = null
        rows = null
        requested = false
        busy = null
        notice = null
        // myDeviceId is set again by the next welcome; leaving the old one for a frame is harmless.
        onChange()
    }

    private fun ask() {
        if (!offered()) return
        val key = rid()
        if (!send(ClientMessage.DevicesList(key))) return
        requested = true
        val cancel = expiry.after(READ_TIMEOUT_MS) {
            pending.remove(key)
            requested = false
        }
        pending[key] = Pending(Pending.Kind.LIST, null, cancel)
    }

    fun revoke(deviceId: String) {
        if (busy != null) return
        val requestId = rid()
        if (!send(ClientMessage.DevicesRevoke(requestId, deviceId))) return
        busy = deviceId
        notice = null
        val cancel = expiry.after(REVOKE_TIMEOUT_MS) {
            pending.remove(requestId)
            if (busy != deviceId) return@after
            busy = null
            // A self-revoke is answered by the socket closing rather than a `devices.revoked`, so a
            // timeout here is the normal, expected outcome for it and is not worth a scary sentence;
            // for any other device a silent timeout is worth saying.
            if (deviceId != myDeviceId) {
                say(ActionNotice(false, "The server did not answer; nothing was changed."))
            }
            onChange()
        }
        pending[requestId] = Pending(Pending.Kind.REVOKE, deviceId, cancel)
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
        if (next.ok) {
            confirmCancel = expiry.after(CONFIRM_MS) {
                confirmCancel = null
                notice = null
                onChange()
            }
        }
    }

    fun receive(message: ServerMessage): Boolean {
        when (message) {
            is ServerMessage.DevicesRows -> {
                val asked = pending[message.rid] ?: return false
                if (asked.kind != Pending.Kind.LIST) return false
                settle(message.rid, asked)
                rows = message.devices.toList()
                onChange()
                return true
            }
            is ServerMessage.DevicesRevoked -> {
                val asked = pending[message.rid] ?: return false
                if (asked.kind != Pending.Kind.REVOKE) return false
                settle(message.rid, asked)
                busy = null
                say(ActionNotice(message.ok, message.message))
                // The fresh roster rides along, so the screen redraws without a second ask.
                rows = message.devices.toList()
                onChange()
                return true
            }
            is ServerMessage.DevicesChanged -> {
                rows = message.devices.toList()
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
        const val REVOKE_TIMEOUT_MS = 30_000L
        private const val CONFIRM_MS = 4_000L
    }
}

/** What the Devices composable reads. [rows] null means "reading…"; empty means no devices. */
data class DeviceRosterView(
    val rows: List<DeviceRosterRow>?,
    val busy: String?,
    val notice: ActionNotice?,
    val myDeviceId: String?,
)
