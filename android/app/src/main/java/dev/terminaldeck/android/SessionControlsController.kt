package dev.terminaldeck.android

import dev.terminaldeck.android.credential.Expiry
import dev.terminaldeck.android.protocol.Capability
import dev.terminaldeck.android.protocol.ClientMessage
import dev.terminaldeck.android.protocol.ControlName
import dev.terminaldeck.android.protocol.ControlsReadingWire
import dev.terminaldeck.android.protocol.Protocol
import dev.terminaldeck.android.protocol.ServerMessage
import dev.terminaldeck.android.protocol.SessionControls

/**
 * One session's control cluster on a phone — model, effort, fast mode, permission.
 *
 * Transcribed from `pwa/src/session-controls.ts` and from the same port iOS keeps in
 * `SessionControlsLink.swift`. Nothing new is on the wire: `controls.read` and `controls.apply` have
 * been answered by every desktop since 0.5.0 — the desktop's own remote window sends them — and this
 * client never did, so an Android phone could watch a session and never change what it runs at. This
 * is a client, not a feature.
 *
 * ## What is drawn, and what is deliberately not
 *
 * Nothing until a `controls.reading` lands, and nothing at all over a machine whose welcome did not
 * name [Capability.CONTROLS] — an older desktop gets a terminal that is exactly what it was rather
 * than a button explaining what it lacks. Nothing over a plain shell either: `agent.running` says
 * whether an agent CLI is drawing that session's screen, and a model menu over `/bin/zsh` is the
 * defect the desktop's own cluster withdraws itself for.
 *
 * A control the far end says is barred keeps its chip, and the chip opens onto the far end's own
 * sentence instead of onto rows — never a dead menu.
 *
 * ## Honest in-flight and failed states
 *
 * A press sends the frame and says "Working…" until the machine answers. The ticked row is never the
 * row that was pressed — it is whatever the far end *re-read* after the change settled, which is what
 * makes a failed apply revert by construction. A failure keeps its sentence until the next action; a
 * confirmation clears itself; and a machine that never answers gets the one sentence that does not
 * guess ([NO_ANSWER]), because the command is typed into the far pty before anything comes back.
 *
 * One per [HostLink], like [ServerSettingsController] and [DeviceRosterController], and it follows
 * the session the terminal screen is showing rather than the machine as a whole.
 */
class SessionControlsController(
    private val send: (ClientMessage) -> Boolean,
    private val capabilities: () -> Set<String>,
    private val expiry: Expiry,
    /** Bumped whenever what is on screen changes, so the view model refolds its state. */
    private val onChange: () -> Unit,
) {
    /** The session this cluster is about, or null when none is attached. */
    private var sessionId: String? = null

    /**
     * Which screen currently owns this cluster.
     *
     * A number rather than a boolean, and it is the fix for a bug that only shows up on a device:
     * pushing the conversation over the terminal **disposes the terminal**, and Compose runs the new
     * screen's effects *before* the old screen's `onDispose`. So the terminal's teardown arrived
     * after the chat had already claimed the session and cleared it out from under it — the chat
     * screen then sat on "reading the conversation" forever, and the button that opened it looked
     * dead.
     *
     * [follow] hands out a token and [release] only forgets when the token it is given is still the
     * live one. Which makes the order the two effects run in stop mattering, rather than making this
     * code depend on it.
     */
    private var claim = 0

    /** The whole reading, or null until one has landed. */
    private var reading: ControlsReadingWire? = null

    /** Which control is mid-change, or null. While one is busy the others wait. */
    private var busy: ControlName? = null

    private var notice: ActionNotice? = null

    private class Pending(val kind: Kind, val control: ControlName?, val id: String, val cancel: () -> Unit) {
        enum class Kind { READ, APPLY }
    }

    private val pending = HashMap<String, Pending>()
    private var confirmCancel: (() -> Unit)? = null
    private var settleCancel: (() -> Unit)? = null
    private var counter = 0

    fun offered(): Boolean = capabilities().contains(Capability.CONTROLS)

    /**
     * A snapshot the composable draws from, or null when there is nothing to draw.
     *
     * Null covers all three of the absent cases at once — no capability, no session followed, no
     * reading yet — so the terminal screen has one test for whether the Controls button exists
     * rather than three.
     */
    fun view(): SessionControlsView? {
        if (!offered() || sessionId == null) return null
        /*
         * Nothing at all until a reading has landed, and nothing at all over a plain shell.
         *
         * Three different reasons fold to null and all three mean *absent, not greyed*: the machine
         * never advertised `controls`, no reading has arrived yet, or the session is not running an
         * agent — a model menu over `/bin/zsh` is the defect the desktop's own cluster withdraws
         * itself for. Decided here rather than only at the sheet so that every reader of this view
         * gets the same answer; the sheet keeps its own check because it also has to survive a
         * reading going stale while it is open.
         */
        val held = reading ?: return null
        if (!SessionControls.clusterShown(held)) return null
        return SessionControlsView(reading = held, busy = busy, notice = notice)
    }

    private fun rid(): String {
        counter += 1
        return "ctl-$counter"
    }

    /* ----------------------------------------------------------------- lifecycle -- */

    /** The screen opened a session. Everything held about the last one goes. */
    fun follow(id: String): Int {
        if (sessionId != id) forget()
        sessionId = id
        ask()
        claim += 1
        onChange()
        return claim
    }

    /**
     * The screen closed. Timers stop and nothing stale is left on a cluster that may draw again in a
     * second against a different session.
     */
    /**
     * The screen that held [follow]'s token has gone.
     *
     * Forgets only when nothing has claimed the session since — see [claim]. A screen that hands back
     * a stale token is one whose successor is already on top of it, and tearing down for that is how
     * the conversation lost the session it was opened for.
     */
    fun release(token: Int) {
        if (token == claim) forget()
    }

    fun forget() {
        stop()
        sessionId = null
        reading = null
        busy = null
        notice = null
        onChange()
    }

    /**
     * The socket went.
     *
     * The reading is a claim about *now* and nothing over a dead channel will correct it, so it
     * goes; pending questions drop so a late answer cannot land against a request id minted on the
     * last connection.
     */
    fun dropped() {
        stop()
        reading = null
        busy = null
        onChange()
    }

    /**
     * The session printed something and has gone quiet — the event every chip changes on.
     *
     * The model line, the effort confirmation and the permission footer are all read from what the
     * far pty writes, so a settle after output is the only honest trigger for a re-read. A timer
     * rather than a read per frame: a build scrolling produces thousands, and a read per frame would
     * be a poll wearing a different hat.
     */
    fun noteOutput() {
        if (!offered() || sessionId == null) return
        settleCancel?.invoke()
        settleCancel = expiry.after(SETTLE_MS) {
            settleCancel = null
            ask()
        }
    }

    /* -------------------------------------------------------------------- asking -- */

    private fun ask() {
        val id = sessionId ?: return
        if (!offered()) return
        val requestId = rid()
        if (!send(ClientMessage.ControlsRead(requestId, id))) return
        val cancel = expiry.after(READ_TIMEOUT_MS) {
            // A read nobody answered keeps the previous values — they are still the last thing
            // genuinely read. Before the first answer there is nothing on screen to blank, which is
            // its own honest state.
            pending.remove(requestId)
        }
        pending[requestId] = Pending(Pending.Kind.READ, null, id, cancel)
    }

    fun apply(control: ControlName, value: String) {
        val id = sessionId ?: return
        if (busy != null) return
        val requestId = rid()
        // Bounded before it is spent. The desktop refuses an over-long value by **closing the
        // socket**, so a phone that sent one would lose the connection rather than get a sentence
        // back — and the values this cluster sends are ids off the far end's own catalog, so a
        // string longer than the cap is a bug on this side rather than a person's input.
        val bounded = value.take(Protocol.MAX_CONTROL_VALUE_LENGTH)
        if (!send(ClientMessage.ControlsApply(requestId, id, control, bounded))) {
            say(ActionNotice(false, NOT_CONNECTED))
            onChange()
            return
        }
        busy = control
        notice = null
        confirmCancel?.invoke()
        confirmCancel = null
        val cancel = expiry.after(APPLY_TIMEOUT_MS) {
            if (pending.remove(requestId) == null) return@after
            busy = null
            say(ActionNotice(false, NO_ANSWER))
            // Asked rather than assumed: the change may well have landed, and a fresh reading is the
            // only honest tiebreak.
            ask()
            onChange()
        }
        pending[requestId] = Pending(Pending.Kind.APPLY, control, id, cancel)
        onChange()
    }

    fun dismissNotice() {
        confirmCancel?.invoke()
        confirmCancel = null
        notice = null
        onChange()
    }

    /* ------------------------------------------------------------------- answers -- */

    /** Frames this cluster asked for. True when the frame was claimed. */
    fun receive(message: ServerMessage): Boolean {
        when (message) {
            is ServerMessage.ControlsReading -> {
                val asked = pending[message.rid] ?: return false
                if (asked.kind != Pending.Kind.READ) return false
                settle(message.rid, asked)
                // The session is checked as well as the rid, exactly as the guest checks it, so
                // another session's model can never land on this chip.
                if (message.id != asked.id || message.id != sessionId) return true
                reading = message.reading
                onChange()
                return true
            }

            is ServerMessage.ControlsApplied -> {
                val asked = pending[message.rid] ?: return false
                val control = asked.control
                if (asked.kind != Pending.Kind.APPLY || control == null) return false
                settle(message.rid, asked)
                if (message.id != asked.id || message.id != sessionId) return true
                busy = null
                // The far end's own words, verbatim — never a sentence composed here.
                say(ActionNotice(message.ok, message.message))
                reading = reading?.applying(control, message.reading)
                // A fresh read of the whole cluster: an apply can move more than its own chip
                // (picking a model turns fast mode off), and the answer carried only one reading.
                ask()
                onChange()
                return true
            }

            else -> return false
        }
    }

    private fun settle(requestId: String, asked: Pending) {
        asked.cancel()
        pending.remove(requestId)
    }

    /** A confirmation clears itself; a refusal stays until the next action. */
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

    fun stop() {
        pending.values.forEach { it.cancel() }
        pending.clear()
        confirmCancel?.invoke()
        confirmCancel = null
        settleCancel?.invoke()
        settleCancel = null
    }

    companion object {
        const val READ_TIMEOUT_MS = 20_000L
        const val APPLY_TIMEOUT_MS = 60_000L
        private const val CONFIRM_MS = 4_000L

        /** How long output must be quiet before the cluster re-reads. */
        const val SETTLE_MS = 1_200L

        /**
         * The sentence for an apply nobody answered — word for word the guest's.
         *
         * It does not say "failed": the command is typed before anything comes back, so the session
         * may well have changed, and claiming failure would send someone pressing again at a session
         * that has already moved.
         */
        const val NO_ANSWER =
            "That machine did not answer, so it is not known whether the change was made."

        /** And the one for a press while the socket is down — nothing was sent. */
        const val NOT_CONNECTED = "Not connected right now, so nothing was sent."
    }
}

/**
 * What the controls sheet reads.
 *
 * [reading] null means "nothing has landed yet", which the sheet draws as its own honest empty
 * rather than as four chips reading Unknown.
 */
data class SessionControlsView(
    val reading: ControlsReadingWire?,
    val busy: ControlName?,
    val notice: ActionNotice?,
)
